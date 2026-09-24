//! `DROP TABLE` / `ALTER TABLE ... ADD COLUMNS` / `SHOW CREATE TABLE` / `DESCRIBE` の対象テーブルの修飾名解析。
//!
//! Phase 2 では修飾名（`cat.ns.t` や引用符付きのカタログ名）も解析し、対象テーブルの存在も
//! あわせて確かめる。修飾名にカタログ・スキーマが無ければ実行時の既定を当て、それでも
//! カタログかスキーマが決まらなければ判定しない（今までどおりに倒す。issue #39 Phase 2）。

use super::table_format::TargetStatement;

/// `DROP TABLE` / `ALTER TABLE ... ADD COLUMNS` / `... REPLACE COLUMNS` / `SHOW CREATE TABLE` / `DESCRIBE` から
/// 取り出した対象。カタログ・スキーマは修飾名に無ければ既定を当てた後の値（呼び出し元の別名解決前）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct TargetTable {
    pub(super) catalog: String,
    pub(super) schema: String,
    pub(super) table: String,
}

/// `target_statement` の種類ごとに、名前の前に来るキーワードの並び（`DROP TABLE` / `ALTER TABLE` /
/// `SHOW CREATE TABLE` / `DESCRIBE`）。DESCRIBE だけ `TABLE` を挟まない（#160）。
fn keywords(statement: TargetStatement) -> &'static [&'static str] {
    match statement {
        TargetStatement::DropTable => &["DROP", "TABLE"],
        TargetStatement::AlterTableAddColumns | TargetStatement::AlterTableReplaceColumns => {
            &["ALTER", "TABLE"]
        }
        TargetStatement::ShowCreateTable => &["SHOW", "CREATE", "TABLE"],
        TargetStatement::Describe => &["DESCRIBE"],
    }
}

/// `DROP TABLE [IF EXISTS] <名前>` / `ALTER TABLE [IF EXISTS] <名前> ADD COLUMNS ...` /
/// `SHOW CREATE TABLE <名前>` / `DESCRIBE <名前>` を解析し、カタログ・スキーマに既定値を当てる。
/// 名前の後ろ（`DESCRIBE t PARTITION (...)` の PARTITION 以降など）は読まない。修飾名にあればその値（引用符付きなら中身、無引用なら
/// Trino の規則で小文字）を使い、無ければ `default_catalog` / `default_schema`（実行時の値。
/// 別名解決前）を使う。カタログかスキーマが決まらなければ None（今までどおりに倒す）。
///
/// 字句処理は新しく書かず、`catalog.rs` の `skip_keyword`・`skip_leading_trivia`・`skip_quoted`・`unquote`
/// を再利用する。
pub(super) fn parse_target_table(
    query: &str,
    statement: TargetStatement,
    default_catalog: Option<&str>,
    default_schema: Option<&str>,
) -> Option<TargetTable> {
    let name = table_name_start(query, keywords(statement))?;
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

/// `<キーワードの並び>` と、あれば `IF EXISTS` を読み飛ばし、名前が始まる位置を返す。
/// 先頭が `<キーワードの並び>` でなければ None。並びは `keywords` が返す。
///
/// `catalog::skip_keyword` が先頭のトリビアを自分で読み飛ばすので、キーワードの手前では
/// 読み飛ばさない。**最後の 1 回だけは残す**: `parse_qualified_name` はトリビアを読み飛ばさず、
/// 先頭が空白やコメントのままだと `read_name_part` が名前を 1 文字も読めずに None を返す。
fn table_name_start<'a>(query: &'a str, keywords: &[&str]) -> Option<&'a str> {
    let mut rest = query;
    for keyword in keywords {
        rest = crate::catalog::skip_keyword(rest, keyword)?;
    }
    let rest = match crate::catalog::skip_keyword(rest, "IF") {
        Some(after_if) => crate::catalog::skip_keyword(after_if, "EXISTS")?,
        None => rest,
    };
    Some(crate::catalog::skip_leading_trivia(rest))
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

#[cfg(test)]
mod tests {
    use super::*;

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

    /// DESCRIBE は `TABLE` を挟まない（#160）。コメントは `skip_leading_trivia` が読み飛ばす。
    #[test]
    fn parse_target_table_は_describe_の直後の名前を読む() {
        for query in ["DESCRIBE t", "DESCRIBE /* c */ t"] {
            assert_eq!(
                parse_target_table(query, TargetStatement::Describe, Some("cat"), Some("ns")),
                Some(TargetTable {
                    catalog: "cat".to_string(),
                    schema: "ns".to_string(),
                    table: "t".to_string(),
                }),
                "{query}"
            );
        }
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
        // REPLACE COLUMNS でも `keywords` は `["ALTER"]` なので、名前の位置は ADD COLUMNS と変わらない。
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
    fn parse_target_table_は_show_create_table_の名前も読む() {
        // `SHOW CREATE` の 2 語を読み飛ばしてから `TABLE` を読む（#151）。語の間のコメントも区切りとして読み飛ばす。
        for (query, expected) in [
            ("SHOW CREATE TABLE t", 既定付き("t")),
            (
                "SHOW CREATE TABLE ns.t",
                Some(TargetTable {
                    catalog: "cat".to_string(),
                    schema: "ns".to_string(),
                    table: "t".to_string(),
                }),
            ),
            (
                "SHOW CREATE TABLE other.ns2.t",
                Some(TargetTable {
                    catalog: "other".to_string(),
                    schema: "ns2".to_string(),
                    table: "t".to_string(),
                }),
            ),
            (
                r#"SHOW CREATE TABLE "s3tablescatalog/my-bucket".ns.t"#,
                Some(TargetTable {
                    catalog: "s3tablescatalog/my-bucket".to_string(),
                    schema: "ns".to_string(),
                    table: "t".to_string(),
                }),
            ),
            ("SHOW /* c */ CREATE TABLE t", 既定付き("t")),
            ("SHOW CREATE -- c\nTABLE t", 既定付き("t")),
            // 無引用の大文字は Trino の規則で小文字にする。
            ("show create table T", 既定付き("t")),
        ] {
            assert_eq!(
                parse_target_table(
                    query,
                    TargetStatement::ShowCreateTable,
                    Some("cat"),
                    Some("ns")
                ),
                expected,
                "{query:?}"
            );
        }
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
        // ここでは `table_name_start` の IF EXISTS の読み飛ばしがキーワードの並び
        // （DROP / ALTER / SHOW CREATE）によらず共通のコードで効いていることを固定する。
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

    /// 既定のカタログ（`cat`）・スキーマ（`ns`）を当てた後の期待値。
    fn 既定付き(table: &str) -> Option<TargetTable> {
        Some(TargetTable {
            catalog: "cat".to_string(),
            schema: "ns".to_string(),
            table: table.to_string(),
        })
    }

    // 以下の 3 つは、issue #49 で `skip_keyword` を `catalog.rs` へ統合する前に、着手前の挙動を
    // 境界入力で固定したもの。統合は挙動を変えないので red が成立しない。代わりにこれらが
    // 「統合の前後で結果が変わらない」ことの網になる。期待値は推測ではなく、着手前のコードに
    // 一時テストを足して実際に流した出力をそのまま写した。

    #[test]
    fn parse_target_table_はトリビアが何個どこに挟まっても同じ結果になる() {
        // `skip_keyword` を「呼び出し元が先にトリビアを読み飛ばす」形から「内部で読み飛ばす」形に
        // 寄せても結果が変わらないことを、トリビアの現れうる位置すべてで固定する。
        for (query, statement, expected) in [
            ("  DROP TABLE t", TargetStatement::DropTable, 既定付き("t")),
            (
                "-- c\nDROP TABLE t",
                TargetStatement::DropTable,
                既定付き("t"),
            ),
            (
                "/* c */ DROP TABLE t",
                TargetStatement::DropTable,
                既定付き("t"),
            ),
            ("DROP  TABLE t", TargetStatement::DropTable, 既定付き("t")),
            (
                "DROP -- c\nTABLE t",
                TargetStatement::DropTable,
                既定付き("t"),
            ),
            (
                "DROP /* c */ TABLE t",
                TargetStatement::DropTable,
                既定付き("t"),
            ),
            (
                "DROP TABLE IF /* c */ EXISTS t",
                TargetStatement::DropTable,
                既定付き("t"),
            ),
            (
                "DROP TABLE IF EXISTS -- c\nt",
                TargetStatement::DropTable,
                既定付き("t"),
            ),
            // トリビアを 2 つ重ねる。`skip_leading_trivia` は空白とコメントを続けて読み飛ばすので、
            // 呼び出し元と関数の内側のどちらで読み飛ばしても同じ位置で止まる。
            (
                "DROP /* a */ -- b\nTABLE t",
                TargetStatement::DropTable,
                既定付き("t"),
            ),
            (
                "/* a */ /* b */ DROP TABLE t",
                TargetStatement::DropTable,
                既定付き("t"),
            ),
            // キーワードの直後にコメントが続き、空白が 1 つも無い形。
            (
                "DROP TABLE/* c */t",
                TargetStatement::DropTable,
                既定付き("t"),
            ),
            (
                "ALTER /* c */ TABLE /* d */ t ADD COLUMNS (c int)",
                TargetStatement::AlterTableAddColumns,
                既定付き("t"),
            ),
        ] {
            assert_eq!(
                parse_target_table(query, statement, Some("cat"), Some("ns")),
                expected,
                "{query:?}"
            );
        }
    }

    #[test]
    fn parse_target_table_はキーワードの直後が識別子の文字かどうかで一致を決める() {
        for (query, expected) in [
            // 続きが英数字・`_` なら別の語とみなして一致させない。
            ("DROP TABLES t", None),
            ("DROPTABLE t", None),
            ("DROP TABLE_X t", None),
            // 続きが識別子の文字でなければ、空白が無くても一致する。
            (r#"DROP TABLE"my table""#, 既定付き("my table")),
            (r#"DROP TABLE IF EXISTS"t""#, 既定付き("t")),
            // `IF` の直後が `X`（識別子の文字）なので `IF EXISTS` としては読まれず、
            // `IFX` がテーブル名になる（その後ろの ` t` は見ない）。
            ("DROP TABLE IFX t", 既定付き("ifx")),
            // `IF` は読めるが `EXISTS` が無いので、`table_name_start` ごと None に倒れる。
            ("DROP TABLE IF t", None),
        ] {
            assert_eq!(
                parse_target_table(query, TargetStatement::DropTable, Some("cat"), Some("ns")),
                expected,
                "{query:?}"
            );
        }
    }

    #[test]
    fn parse_target_table_は大文字小文字を無視し多バイト文字と短い入力でも破綻しない() {
        for (query, expected) in [
            ("drop table t", 既定付き("t")),
            ("DrOp TaBlE iF eXiStS t", 既定付き("t")),
            // `TABLE` の後ろが多バイト文字の引用符付き識別子のとき、`IF` の一致判定が
            // `is_char_boundary` で弾かれる（`"` の次のバイトが `日` の途中）。
            // 弾かれた結果 `IF EXISTS` 無しとして読み進み、名前として解析される。
            (r#"DROP TABLE "日本語""#, 既定付き("日本語")),
            // キーワードより短い入力・空の入力でも panic せずに None を返す。
            ("DR", None),
            ("", None),
            ("DROP", None),
            // `DROP TABLE` は読めるが名前が空なので None。
            ("DROP TABLE", None),
        ] {
            assert_eq!(
                parse_target_table(query, TargetStatement::DropTable, Some("cat"), Some("ns")),
                expected,
                "{query:?}"
            );
        }
    }
}
