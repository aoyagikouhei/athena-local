//! DROP TABLE の結果ファイルを、対象テーブルの形式（Trino のコネクタ）に応じて書き分ける。
//!
//! Phase 2 では修飾名（`cat.ns.t` や引用符付きのカタログ名）も解析し、対象テーブルの存在も
//! あわせて確かめる。修飾名にカタログ・スキーマが無ければ実行時の既定を当て、それでも
//! カタログかスキーマが決まらなければ判定しない（今までどおりに倒す。issue #39 Phase 2）。

use crate::statement::quote_literal;
use crate::trino::{Cancel, Outcome, Trino};

/// 対象にする文の種類。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum TargetStatement {
    DropTable,
}

/// 問い合わせで分かる、対象テーブルの Trino コネクタ。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum TableFormat {
    Hive,
    Iceberg,
}

/// 本物が列なしでも本体・`.metadata` を置く、文の種類とテーブルの形式の組み合わせ
/// （2026-09-20 実測）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum EngineDdl {
    /// DROP TABLE × Iceberg。本体に改行 1 つ、`.metadata` に 41 バイト
    /// （field 1 = Trino のエンジンのクエリ ID、field 2 = `DROP TABLE`）。
    DropTableIceberg,
}

/// `DROP TABLE [IF EXISTS] <名前>` から取り出した対象。カタログ・スキーマは
/// 修飾名に無ければ既定を当てた後の値（呼び出し元の別名解決前）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct DropTarget {
    pub(super) catalog: String,
    pub(super) schema: String,
    pub(super) table: String,
}

/// この文が対象か。対象は DROP TABLE だけ（`substatement_type` の判定をそのまま使い、
/// 判定を二重に持たない）。修飾名でカタログを明示していても対象にする（Phase 2）。
pub(super) fn target_statement(query: &str) -> Option<TargetStatement> {
    if super::classification::substatement_type(query) != Some("DROP_TABLE") {
        return None;
    }
    Some(TargetStatement::DropTable)
}

/// `DROP TABLE [IF EXISTS] <名前>` を解析し、カタログ・スキーマに既定値を当てる。
/// 修飾名にあればその値（引用符付きなら中身、無引用なら Trino の規則で小文字）を使い、
/// 無ければ `default_catalog` / `default_schema`（実行時の値。別名解決前）を使う。
/// カタログかスキーマが決まらなければ None（今までどおりに倒す）。
///
/// 字句処理は新しく書かず、`catalog.rs` の `skip_leading_trivia`・`skip_quoted`・`unquote` を再利用する。
pub(super) fn parse_drop_target(
    query: &str,
    default_catalog: Option<&str>,
    default_schema: Option<&str>,
) -> Option<DropTarget> {
    let name = drop_table_name_start(query)?;
    let parts = parse_qualified_name(name)?;

    let (catalog, schema, table) = match <[String; 1]>::try_from(parts.clone()) {
        Ok([table]) => (None, None, table),
        Err(_) => match <[String; 2]>::try_from(parts.clone()) {
            Ok([schema, table]) => (None, Some(schema), table),
            Err(_) => match <[String; 3]>::try_from(parts) {
                Ok([catalog, schema, table]) => (Some(catalog), Some(schema), table),
                Err(_) => return None,
            },
        },
    };

    let catalog = catalog.or_else(|| default_catalog.map(str::to_string))?;
    let schema = schema.or_else(|| default_schema.map(str::to_string))?;
    Some(DropTarget {
        catalog,
        schema,
        table,
    })
}

/// `DROP TABLE` と、あれば `IF EXISTS` を読み飛ばし、名前が始まる位置を返す。
/// 先頭が `DROP TABLE` でなければ None。
fn drop_table_name_start(query: &str) -> Option<&str> {
    let rest = crate::catalog::skip_leading_trivia(query);
    let rest = skip_keyword(rest, "DROP")?;
    let rest = skip_keyword(crate::catalog::skip_leading_trivia(rest), "TABLE")?;
    let rest = crate::catalog::skip_leading_trivia(rest);
    let rest = match skip_keyword(rest, "IF") {
        Some(after_if) => skip_keyword(crate::catalog::skip_leading_trivia(after_if), "EXISTS")?,
        None => rest,
    };
    Some(crate::catalog::skip_leading_trivia(rest))
}

/// 大文字小文字を区別せずにキーワードを読み飛ばす。続きが識別子の文字（英数字・`_`）なら
/// 別の語（`TABLES` など）とみなして一致させない。
fn skip_keyword<'a>(input: &'a str, keyword: &str) -> Option<&'a str> {
    if input.len() < keyword.len() || !input.is_char_boundary(keyword.len()) {
        return None;
    }
    let (head, tail) = input.split_at(keyword.len());
    if !head.eq_ignore_ascii_case(keyword) {
        return None;
    }
    if tail.starts_with(|c: char| c.is_ascii_alphanumeric() || c == '_') {
        return None;
    }
    Some(tail)
}

/// `.` で区切られた名前の並びを読む。引用符付きの識別子は中身を、無引用は小文字にして集める。
fn parse_qualified_name(input: &str) -> Option<Vec<String>> {
    let mut parts = Vec::new();
    let mut rest = input;
    loop {
        let (part, after) = read_name_part(rest)?;
        parts.push(part);
        let after_trivia = crate::catalog::skip_leading_trivia(after);
        match after_trivia.strip_prefix('.') {
            Some(next) => rest = crate::catalog::skip_leading_trivia(next),
            None => break,
        }
    }
    Some(parts)
}

/// 名前を 1 つ読む。引用符付きなら `catalog::skip_quoted` で終わりを見つけて中身を返し、
/// 無引用なら英数字と `_` の並びを小文字にして返す。
fn read_name_part(input: &str) -> Option<(String, &str)> {
    if input.starts_with('"') {
        let end = crate::catalog::skip_quoted(input.as_bytes(), 0);
        let quoted = &input[..end];
        Some((crate::catalog::unquote(quoted), &input[end..]))
    } else {
        let end = input
            .as_bytes()
            .iter()
            .position(|b| !(b.is_ascii_alphanumeric() || *b == b'_'))
            .unwrap_or(input.len());
        if end == 0 {
            return None;
        }
        Some((input[..end].to_lowercase(), &input[end..]))
    }
}

/// テーブルの形式と存在を Trino に 1 回の問い合わせで確かめる。失敗・非対応の形式・
/// 対象が存在しないときは None に倒す（`statement::bind` の分類の問い合わせと同型）。
/// カタログ名は呼び出し元が別名解決した後の値を渡すこと（`system.metadata.catalogs` /
/// `system.jdbc.tables` は Trino 側の名前でしか引けない）。
pub(super) async fn probe_format(
    trino: &Trino,
    catalog: &str,
    schema: &str,
    table: &str,
    database: Option<&str>,
    cancel: &Cancel,
) -> Option<TableFormat> {
    let sql = probe_sql(catalog, schema, table);
    let outcome = trino
        .execute(&sql, Some(catalog), database, cancel)
        .await
        .ok()?;
    parse_probe_result(&outcome)
}

/// 形式（`system.metadata.catalogs.connector_name`）と存在（`system.jdbc.tables` の件数）を
/// 1 つの SELECT にまとめる。`system.jdbc.tables` を使うのは `table_cat` / `table_schem` /
/// `table_name` を全部リテラルで書けるため（識別子のクォートを手書きしなくて済む）。
fn probe_sql(catalog: &str, schema: &str, table: &str) -> String {
    let catalog_literal = quote_literal(catalog);
    format!(
        "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = {catalog_literal}), (SELECT count(*) FROM system.jdbc.tables WHERE table_cat = {catalog_literal} AND table_schem = {} AND table_name = {})",
        quote_literal(schema),
        quote_literal(table),
    )
}

/// `probe_sql` の応答から形式を決める。対象が存在しなければ（件数が 0 なら）None
/// （Hive 側と同じ今までどおりの振る舞いに倒す）。hive でも iceberg でもない値も None。
fn parse_probe_result(outcome: &Outcome) -> Option<TableFormat> {
    let row = outcome.rows.first()?;
    let format = row.first()?.as_str();
    let count = row.get(1)?.as_i64()?;
    if count == 0 {
        return None;
    }
    match format? {
        "hive" => Some(TableFormat::Hive),
        "iceberg" => Some(TableFormat::Iceberg),
        _ => None,
    }
}

/// 文の種類とテーブルの形式の組み合わせから、本物が列なしでも本体・`.metadata` を置く DDL を決める。
pub(super) fn engine_ddl(statement: TargetStatement, format: TableFormat) -> Option<EngineDdl> {
    match (statement, format) {
        (TargetStatement::DropTable, TableFormat::Iceberg) => Some(EngineDdl::DropTableIceberg),
        (TargetStatement::DropTable, TableFormat::Hive) => None,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::Value;

    use super::*;

    #[test]
    fn target_statement_は_drop_table_だけを対象にする() {
        assert_eq!(
            target_statement("DROP TABLE t"),
            Some(TargetStatement::DropTable)
        );
        assert_eq!(
            target_statement("DROP TABLE IF EXISTS t"),
            Some(TargetStatement::DropTable)
        );
        for query in [
            "SELECT 1",
            "CREATE TABLE t (i int)",
            "DROP VIEW v",
            "DROP DATABASE db",
        ] {
            assert_eq!(target_statement(query), None, "{query:?}");
        }
    }

    #[test]
    fn target_statement_は_2_パートの名前を既定カタログの文として対象にする() {
        // `ns.t` はカタログを名指ししておらず、`t` と同じ既定カタログを使うだけ。
        assert_eq!(
            target_statement("DROP TABLE ns.t"),
            Some(TargetStatement::DropTable)
        );
        assert_eq!(
            target_statement("DROP TABLE IF EXISTS ns.t"),
            Some(TargetStatement::DropTable)
        );
    }

    #[test]
    fn engine_ddl_は_drop_table_と_iceberg_の組み合わせだけ_some() {
        assert_eq!(
            engine_ddl(TargetStatement::DropTable, TableFormat::Iceberg),
            Some(EngineDdl::DropTableIceberg)
        );
        assert_eq!(
            engine_ddl(TargetStatement::DropTable, TableFormat::Hive),
            None
        );
    }

    #[tokio::test]
    async fn 形式の問い合わせが失敗すれば今までどおりに倒す() {
        // 127.0.0.1:1 には何も listen していないので接続に失敗する。
        let trino = Trino::new("http://127.0.0.1:1", "test");
        let cancel = Cancel::default();
        assert_eq!(
            probe_format(&trino, "cat", "ns", "t", None, &cancel).await,
            None
        );
    }

    #[test]
    fn parse_drop_target_は修飾名の無い名前に既定のカタログとスキーマを当てる() {
        assert_eq!(
            parse_drop_target("DROP TABLE t", Some("cat"), Some("ns")),
            Some(DropTarget {
                catalog: "cat".to_string(),
                schema: "ns".to_string(),
                table: "t".to_string(),
            })
        );
    }

    #[test]
    fn parse_drop_target_は_2_パートの名前にスキーマを当て既定のカタログを使う() {
        assert_eq!(
            parse_drop_target("DROP TABLE ns.t", Some("cat"), Some("default_ns")),
            Some(DropTarget {
                catalog: "cat".to_string(),
                schema: "ns".to_string(),
                table: "t".to_string(),
            })
        );
    }

    #[test]
    fn parse_drop_target_は_3_パートの名前でカタログとスキーマをそのまま使う() {
        assert_eq!(
            parse_drop_target(
                "DROP TABLE cat.ns.t",
                Some("default_cat"),
                Some("default_ns")
            ),
            Some(DropTarget {
                catalog: "cat".to_string(),
                schema: "ns".to_string(),
                table: "t".to_string(),
            })
        );
    }

    #[test]
    fn parse_drop_target_は引用符付きの第_1_パートを中身のまま使う() {
        assert_eq!(
            parse_drop_target(r#"DROP TABLE "s3tablescatalog/my-bucket".ns.t"#, None, None),
            Some(DropTarget {
                catalog: "s3tablescatalog/my-bucket".to_string(),
                schema: "ns".to_string(),
                table: "t".to_string(),
            })
        );
    }

    #[test]
    fn parse_drop_target_は_if_exists_を読み飛ばす() {
        assert_eq!(
            parse_drop_target("DROP TABLE IF EXISTS cat.ns.t", None, None),
            Some(DropTarget {
                catalog: "cat".to_string(),
                schema: "ns".to_string(),
                table: "t".to_string(),
            })
        );
    }

    #[test]
    fn parse_drop_target_はコメントを読み飛ばす() {
        assert_eq!(
            parse_drop_target("DROP TABLE /* c */ cat.ns.t", None, None),
            Some(DropTarget {
                catalog: "cat".to_string(),
                schema: "ns".to_string(),
                table: "t".to_string(),
            })
        );
    }

    #[test]
    fn parse_drop_target_は引用符の無い名前を小文字にする() {
        assert_eq!(
            parse_drop_target("DROP TABLE CAT.NS.T", None, None),
            Some(DropTarget {
                catalog: "cat".to_string(),
                schema: "ns".to_string(),
                table: "t".to_string(),
            })
        );
    }

    #[test]
    fn parse_drop_target_はカタログもスキーマも決まらなければ_none() {
        assert_eq!(parse_drop_target("DROP TABLE t", None, None), None);
    }

    #[test]
    fn parse_drop_target_はカタログが決まらなければ_none() {
        assert_eq!(
            parse_drop_target("DROP TABLE ns.t", None, Some("ignored")),
            None
        );
    }

    #[test]
    fn parse_drop_target_はスキーマが決まらなければ_none() {
        assert_eq!(parse_drop_target("DROP TABLE t", Some("cat"), None), None);
    }

    #[test]
    fn target_statement_は修飾名でカタログを指す文も対象にする() {
        for query in [
            "DROP TABLE cat.ns.t",
            "DROP TABLE \"s3tablescatalog/my-bucket\".ns.t",
            "DROP TABLE IF EXISTS cat.ns.t",
        ] {
            assert_eq!(
                target_statement(query),
                Some(TargetStatement::DropTable),
                "{query:?}"
            );
        }
    }

    #[test]
    fn probe_sql_はカタログ_スキーマ_テーブル名を全部リテラルで埋め込む() {
        assert_eq!(
            probe_sql("cat", "ns", "t"),
            "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = 'cat'), (SELECT count(*) FROM system.jdbc.tables WHERE table_cat = 'cat' AND table_schem = 'ns' AND table_name = 't')"
        );
    }

    #[test]
    fn probe_sql_は単一引用符を含む名前を_quote_literal_で埋め込む() {
        assert_eq!(
            probe_sql("it's", "ns", "t"),
            "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = 'it''s'), (SELECT count(*) FROM system.jdbc.tables WHERE table_cat = 'it''s' AND table_schem = 'ns' AND table_name = 't')"
        );
    }

    fn outcome_with_probe_result(format: Option<&str>, count: i64) -> Outcome {
        Outcome {
            rows: vec![vec![
                format.map_or(Value::Null, |f| Value::String(f.to_string())),
                Value::from(count),
            ]],
            ..Outcome::default()
        }
    }

    #[test]
    fn parse_probe_result_は形式と件数がそろえば形式を返す() {
        assert_eq!(
            parse_probe_result(&outcome_with_probe_result(Some("hive"), 1)),
            Some(TableFormat::Hive)
        );
        assert_eq!(
            parse_probe_result(&outcome_with_probe_result(Some("iceberg"), 3)),
            Some(TableFormat::Iceberg)
        );
    }

    #[test]
    fn parse_probe_result_は件数が_0_なら形式が読めても_none() {
        assert_eq!(
            parse_probe_result(&outcome_with_probe_result(Some("iceberg"), 0)),
            None
        );
    }

    #[test]
    fn parse_probe_result_はカタログが無ければ_none() {
        assert_eq!(
            parse_probe_result(&outcome_with_probe_result(None, 0)),
            None
        );
    }

    #[test]
    fn parse_probe_result_は_hive_でも_iceberg_でもない形式は判定しない() {
        assert_eq!(
            parse_probe_result(&outcome_with_probe_result(Some("delta_lake"), 5)),
            None
        );
    }
}
