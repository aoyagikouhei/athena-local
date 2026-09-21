//! `DROP TABLE` / `ALTER TABLE ... ADD COLUMNS` の対象テーブルの修飾名解析。
//!
//! Phase 2 では修飾名（`cat.ns.t` や引用符付きのカタログ名）も解析し、対象テーブルの存在も
//! あわせて確かめる。修飾名にカタログ・スキーマが無ければ実行時の既定を当て、それでも
//! カタログかスキーマが決まらなければ判定しない（今までどおりに倒す。issue #39 Phase 2）。

use super::table_format::TargetStatement;

/// `DROP TABLE` / `ALTER TABLE ... ADD COLUMNS` / `... REPLACE COLUMNS` から取り出した対象。カタログ・スキーマは
/// 修飾名に無ければ既定を当てた後の値（呼び出し元の別名解決前）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct TargetTable {
    pub(super) catalog: String,
    pub(super) schema: String,
    pub(super) table: String,
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
}
