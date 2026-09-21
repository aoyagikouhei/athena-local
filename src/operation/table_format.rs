//! DROP TABLE と ALTER TABLE ... ADD COLUMNS の結果ファイルを、対象テーブルの形式
//! （Trino のコネクタ）に応じて書き分ける。
//!
//! Phase 2 では修飾名（`cat.ns.t` や引用符付きのカタログ名）も解析し、対象テーブルの存在も
//! あわせて確かめる。修飾名にカタログ・スキーマが無ければ実行時の既定を当て、それでも
//! カタログかスキーマが決まらなければ判定しない（今までどおりに倒す。issue #39 Phase 2）。
//! Phase 3b は ALTER TABLE ... ADD COLUMNS × Hive を対象に足す（2026-09-21 実測）。

use crate::statement::quote_literal;
use crate::trino::{Cancel, Outcome, Trino};

/// 対象にする文の種類。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum TargetStatement {
    DropTable,
    AlterTableAddColumns,
    /// `ALTER TABLE ... REPLACE COLUMNS`。Hive では ADD COLUMNS と同じ `.metadata` を置き、
    /// Iceberg では本物が実行時に失敗する（2026-09-21 実測）。
    AlterTableReplaceColumns,
}

/// 問い合わせで分かる、対象テーブルの Trino コネクタ。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum TableFormat {
    Hive,
    Iceberg,
}

/// 本物が列なしでも本体・`.metadata` を置く、文の種類とテーブルの形式の組み合わせ
/// （2026-09-20〜21 実測）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum EngineDdl {
    /// DROP TABLE × Iceberg。本体に改行 1 つ、`.metadata` に 41 バイト
    /// （field 1 = Trino のエンジンのクエリ ID、field 2 = `DROP TABLE`）。
    DropTableIceberg,
    /// ALTER TABLE ... ADD COLUMNS / REPLACE COLUMNS × Hive。本体は 0 バイトのまま、
    /// `.metadata` に 38 バイト（field 1 = QueryExecutionId のみ。field 2 の updateType も
    /// field 3 の更新件数も無い。Trino の updateType は `"ADD COLUMN"` で Athena の
    /// `ADD COLUMNS` と綴りが違うので使わない。2026-09-21 実測）。REPLACE COLUMNS の
    /// `.metadata` は ADD COLUMNS と 1 バイトも変わらない（同じ日の実測で中身を突き合わせた）。
    AlterColumnsHive,
}

/// `DROP TABLE` / `ALTER TABLE ... ADD COLUMNS` / `... REPLACE COLUMNS` から取り出した対象。カタログ・スキーマは
/// 修飾名に無ければ既定を当てた後の値（呼び出し元の別名解決前）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct TargetTable {
    pub(super) catalog: String,
    pub(super) schema: String,
    pub(super) table: String,
}

/// この文が対象か。対象は DROP TABLE と、ALTER TABLE の ADD COLUMNS / REPLACE COLUMNS だけ
/// （`substatement_type` の判定をそのまま使い、判定を二重に持たない）。
/// 修飾名でカタログを明示していても対象にする（Phase 2）。
pub(super) fn target_statement(query: &str) -> Option<TargetStatement> {
    match super::classification::substatement_type(query) {
        Some("DROP_TABLE") => Some(TargetStatement::DropTable),
        Some("ALTER_TABLE_ADD_COLUMN") => Some(TargetStatement::AlterTableAddColumns),
        Some("ALTER_TABLE_REPLACE_COLUMN") => Some(TargetStatement::AlterTableReplaceColumns),
        _ => None,
    }
}

/// `target_statement` の種類ごとに、テーブル名の前に来る動詞（`DROP` / `ALTER`）。
fn verb(statement: TargetStatement) -> &'static str {
    match statement {
        TargetStatement::DropTable => "DROP",
        TargetStatement::AlterTableAddColumns | TargetStatement::AlterTableReplaceColumns => {
            "ALTER"
        }
    }
}

/// `DROP TABLE [IF EXISTS] <名前>` / `ALTER TABLE [IF EXISTS] <名前> ADD COLUMNS ...` を解析し、
/// カタログ・スキーマに既定値を当てる。修飾名にあればその値（引用符付きなら中身、無引用なら
/// Trino の規則で小文字）を使い、無ければ `default_catalog` / `default_schema`（実行時の値。
/// 別名解決前）を使う。カタログかスキーマが決まらなければ None（今までどおりに倒す）。
///
/// 字句処理は新しく書かず、`catalog.rs` の `skip_leading_trivia`・`skip_quoted`・`unquote` を再利用する。
pub(super) fn parse_target_table(
    query: &str,
    statement: TargetStatement,
    default_catalog: Option<&str>,
    default_schema: Option<&str>,
) -> Option<TargetTable> {
    let name = table_name_start(query, verb(statement))?;
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
    Some(TargetTable {
        catalog,
        schema,
        table,
    })
}

/// `<動詞> TABLE` と、あれば `IF EXISTS` を読み飛ばし、名前が始まる位置を返す。
/// 先頭が `<動詞> TABLE` でなければ None。`<動詞>` は `DROP` か `ALTER`。
fn table_name_start<'a>(query: &'a str, verb: &str) -> Option<&'a str> {
    let rest = crate::catalog::skip_leading_trivia(query);
    let rest = skip_keyword(rest, verb)?;
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
        (
            TargetStatement::AlterTableAddColumns | TargetStatement::AlterTableReplaceColumns,
            TableFormat::Hive,
        ) => Some(EngineDdl::AlterColumnsHive),
        (
            TargetStatement::AlterTableAddColumns | TargetStatement::AlterTableReplaceColumns,
            TableFormat::Iceberg,
        ) => None,
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
    fn target_statement_は_alter_table_add_columns_も対象にする() {
        // classification.rs が返す ALTER_TABLE_ADD_COLUMN をそのまま使う（判定を二重に持たない）。
        for query in [
            "ALTER TABLE t ADD COLUMNS (m int)",
            "ALTER TABLE t ADD COLUMN m int",
        ] {
            assert_eq!(
                target_statement(query),
                Some(TargetStatement::AlterTableAddColumns),
                "{query:?}"
            );
        }
    }

    #[test]
    fn target_statement_は_alter_table_replace_columns_も対象にする() {
        // REPLACE COLUMNS × Hive は ADD COLUMNS × Hive と同じ 38 バイトの .metadata を置く
        // （2026-09-21 実測。保存した中身を ADD COLUMNS のものと突き合わせて確かめた）ので、
        // 形式の問い合わせが要る。
        assert_eq!(
            target_statement("ALTER TABLE t REPLACE COLUMNS (n int, s string)"),
            Some(TargetStatement::AlterTableReplaceColumns)
        );
    }

    #[test]
    fn target_statement_は_add_columns_以外の_alter_table_を対象外にする() {
        // SET TBLPROPERTIES / DROP COLUMN / SET LOCATION / ADD PARTITION / DROP PARTITION は
        // 本物も列なしの本体・.metadata を置かない（2026-09-21 実測）。IF EXISTS と
        // RENAME COLUMN は Athena に構文が無いので classification.rs の時点で None になる。
        // RENAME TO は分類はされる（ALTER_TABLE_RENAME）が、.metadata は置かない。
        for query in [
            "ALTER TABLE t SET TBLPROPERTIES ('comment' = 'remember to add column for region')",
            "ALTER TABLE t DROP COLUMN c",
            "ALTER TABLE t SET LOCATION 's3://bucket/path/'",
            "ALTER TABLE t ADD PARTITION (p = 'v')",
            "ALTER TABLE t DROP PARTITION (p = 'v')",
            "ALTER TABLE IF EXISTS t ADD COLUMNS (m int)",
            "ALTER TABLE t RENAME COLUMN a TO b",
            "ALTER TABLE t RENAME TO u",
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

    #[test]
    fn engine_ddl_は_列を変える_alter_table_と_hive_の組み合わせだけ_some() {
        // ADD COLUMNS と REPLACE COLUMNS は Hive で同じ .metadata を置く（2026-09-21 実測）。
        for statement in [
            TargetStatement::AlterTableAddColumns,
            TargetStatement::AlterTableReplaceColumns,
        ] {
            assert_eq!(
                engine_ddl(statement, TableFormat::Hive),
                Some(EngineDdl::AlterColumnsHive),
                "{statement:?}"
            );
            assert_eq!(
                engine_ddl(statement, TableFormat::Iceberg),
                None,
                "{statement:?}"
            );
        }
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
    fn parse_target_table_は修飾名の無い名前に既定のカタログとスキーマを当てる() {
        assert_eq!(
            parse_target_table(
                "DROP TABLE t",
                TargetStatement::DropTable,
                Some("cat"),
                Some("ns")
            ),
            Some(TargetTable {
                catalog: "cat".to_string(),
                schema: "ns".to_string(),
                table: "t".to_string(),
            })
        );
    }

    #[test]
    fn parse_target_table_は_2_パートの名前にスキーマを当て既定のカタログを使う() {
        assert_eq!(
            parse_target_table(
                "DROP TABLE ns.t",
                TargetStatement::DropTable,
                Some("cat"),
                Some("default_ns")
            ),
            Some(TargetTable {
                catalog: "cat".to_string(),
                schema: "ns".to_string(),
                table: "t".to_string(),
            })
        );
    }

    #[test]
    fn parse_target_table_は_3_パートの名前でカタログとスキーマをそのまま使う() {
        assert_eq!(
            parse_target_table(
                "DROP TABLE cat.ns.t",
                TargetStatement::DropTable,
                Some("default_cat"),
                Some("default_ns")
            ),
            Some(TargetTable {
                catalog: "cat".to_string(),
                schema: "ns".to_string(),
                table: "t".to_string(),
            })
        );
    }

    #[test]
    fn parse_target_table_は引用符付きの第_1_パートを中身のまま使う() {
        assert_eq!(
            parse_target_table(
                r#"DROP TABLE "s3tablescatalog/my-bucket".ns.t"#,
                TargetStatement::DropTable,
                None,
                None
            ),
            Some(TargetTable {
                catalog: "s3tablescatalog/my-bucket".to_string(),
                schema: "ns".to_string(),
                table: "t".to_string(),
            })
        );
    }

    #[test]
    fn parse_target_table_は_if_exists_を読み飛ばす() {
        assert_eq!(
            parse_target_table(
                "DROP TABLE IF EXISTS cat.ns.t",
                TargetStatement::DropTable,
                None,
                None
            ),
            Some(TargetTable {
                catalog: "cat".to_string(),
                schema: "ns".to_string(),
                table: "t".to_string(),
            })
        );
    }

    #[test]
    fn parse_target_table_はコメントを読み飛ばす() {
        assert_eq!(
            parse_target_table(
                "DROP TABLE /* c */ cat.ns.t",
                TargetStatement::DropTable,
                None,
                None
            ),
            Some(TargetTable {
                catalog: "cat".to_string(),
                schema: "ns".to_string(),
                table: "t".to_string(),
            })
        );
    }

    #[test]
    fn parse_target_table_は引用符の無い名前を小文字にする() {
        assert_eq!(
            parse_target_table(
                "DROP TABLE CAT.NS.T",
                TargetStatement::DropTable,
                None,
                None
            ),
            Some(TargetTable {
                catalog: "cat".to_string(),
                schema: "ns".to_string(),
                table: "t".to_string(),
            })
        );
    }

    #[test]
    fn parse_target_table_はカタログもスキーマも決まらなければ_none() {
        assert_eq!(
            parse_target_table("DROP TABLE t", TargetStatement::DropTable, None, None),
            None
        );
    }

    #[test]
    fn parse_target_table_はカタログが決まらなければ_none() {
        assert_eq!(
            parse_target_table(
                "DROP TABLE ns.t",
                TargetStatement::DropTable,
                None,
                Some("ignored")
            ),
            None
        );
    }

    #[test]
    fn parse_target_table_はスキーマが決まらなければ_none() {
        assert_eq!(
            parse_target_table(
                "DROP TABLE t",
                TargetStatement::DropTable,
                Some("cat"),
                None
            ),
            None
        );
    }

    #[test]
    fn parse_target_table_は_alter_table_replace_columns_の名前も読む() {
        // REPLACE COLUMNS でも `verb` は ALTER なので、名前の位置は ADD COLUMNS と変わらない。
        assert_eq!(
            parse_target_table(
                r#"ALTER TABLE cat."my ns".t REPLACE COLUMNS (n int, s string)"#,
                TargetStatement::AlterTableReplaceColumns,
                Some("default_cat"),
                Some("default_ns")
            ),
            Some(TargetTable {
                catalog: "cat".to_string(),
                schema: "my ns".to_string(),
                table: "t".to_string(),
            })
        );
        assert_eq!(
            parse_target_table(
                "ALTER TABLE t REPLACE COLUMNS (n int)",
                TargetStatement::AlterTableReplaceColumns,
                Some("cat"),
                Some("ns")
            ),
            Some(TargetTable {
                catalog: "cat".to_string(),
                schema: "ns".to_string(),
                table: "t".to_string(),
            })
        );
    }

    #[test]
    fn parse_target_table_は_alter_table_add_columns_の名前も読む() {
        // ADD COLUMNS 以降は見ない（名前の直後で止める）。
        assert_eq!(
            parse_target_table(
                "ALTER TABLE cat.ns.t ADD COLUMNS (m int)",
                TargetStatement::AlterTableAddColumns,
                Some("default_cat"),
                Some("default_ns")
            ),
            Some(TargetTable {
                catalog: "cat".to_string(),
                schema: "ns".to_string(),
                table: "t".to_string(),
            })
        );
        assert_eq!(
            parse_target_table(
                "ALTER TABLE t ADD COLUMNS (m int)",
                TargetStatement::AlterTableAddColumns,
                Some("cat"),
                Some("ns")
            ),
            Some(TargetTable {
                catalog: "cat".to_string(),
                schema: "ns".to_string(),
                table: "t".to_string(),
            })
        );
    }

    #[test]
    fn parse_qualified_name_と_catalog_skip_qualified_name_は同じ書き方を受け付ける() {
        // 名前を「取り出す」parse_qualified_name（ここ）と「読み飛ばす」
        // catalog::skip_qualified_name（classification.rs の ALTER TABLE 判定が使う）は
        // 用途が違うので実装は別だが、受け付ける書き方（引用符・ドット・空白・コメント）は
        // 揃っていることをここで固定する（issue #39 レビュー指摘）。
        for input in [
            "t",
            "cat.ns.t",
            "cat . ns . t",
            "cat /* c */ . ns . t",
            "cat -- c\n. ns . t",
            r#""my table".ns.t"#,
        ] {
            let parts = parse_qualified_name(input).expect("parse_qualified_name");
            assert!(!parts.is_empty(), "{input:?}");
            assert_eq!(
                crate::catalog::skip_qualified_name(input, 0),
                input.len(),
                "{input:?}"
            );
        }
    }

    #[test]
    fn parse_target_table_は_alter_table_でも_if_exists_を読み飛ばす() {
        // 本物の Athena には `ALTER TABLE IF EXISTS` の構文が無く、classification.rs の時点で
        // target_statement は None に落ちる（この文が実際に parse_target_table まで届くことは無い）。
        // ここでは `table_name_start` の IF EXISTS の読み飛ばしが動詞（DROP / ALTER）によらず
        // 共通のコードで効いていることを固定する。
        assert_eq!(
            parse_target_table(
                "ALTER TABLE IF EXISTS cat.ns.t ADD COLUMNS (m int)",
                TargetStatement::AlterTableAddColumns,
                None,
                None
            ),
            Some(TargetTable {
                catalog: "cat".to_string(),
                schema: "ns".to_string(),
                table: "t".to_string(),
            })
        );
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
