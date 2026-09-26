//! TRINO_CATALOG_MAP の別名を、SQL の修飾名に書かれたカタログ名にも当てる。
//!
//! S3 Tables のカタログ名 `s3tablescatalog/<bucket>` は `/` を含むので、Trino にはその名前の
//! カタログを作れない（Trino 482 で確認）。ヘッダだけでなく `"s3tablescatalog/<bucket>".db.t` の
//! ような修飾名も通すために、SQL のうち次の条件をすべて満たす部分だけを置き換える。
//!
//! - 二重引用符付きの識別子である。引用符の無い名前は、Trino 側のカタログを同じ名前にすれば通るので対象にしない
//! - 中身が別名マップのキーと完全に一致する（大文字小文字も区別する）
//! - 空白やコメントを挟んでもよいので、後ろに `.` が続く
//!
//! 本物は Context の Catalog が `AwsDataCatalog` か省略のとき、無引用の `awsdatacatalog.<db>.<t>`（大文字小文字に
//! よらない）を SELECT・INSERT・CTAS・CREATE VIEW・EXPLAIN で Glue のカタログとして実行した（2026-09-26 実測 m30〜m41。
//! #246）。この形（無引用の 3 部の名前の 1 部目）に限り、別名マップの `AwsDataCatalog` のキー（大文字小文字によらない）も
//! 当てる。ほかの別名キーと、ほかの Context は測っていないので当てない。
//!
//! 文字列リテラルとコメントの中は読み飛ばす。置き換えた名前が短ければ閉じ引用符の後ろを空白で埋め、
//! Trino のエラーに出る桁位置を受け取った SQL と揃える（`"tpch"   .tiny.nation` が通ることを Trino 482 で確認）。
//!
//! 字句の読み飛ばし（`skip_quoted`・`comment_end`・`skip_trivia`）と `unquote` は `athena_sql` のものを使う。

use std::borrow::Cow;
use std::collections::HashMap;

use athena_sql::{Cursor, comment_end, skip_quoted, skip_trivia, unquote};

/// 修飾名のカタログに別名を当てた SQL。置き換える箇所が無ければ受け取った SQL をそのまま返す。
/// `aws_data_catalog_context` は Context の Catalog が `AwsDataCatalog` か省略のときに真にし、無引用の
/// `awsdatacatalog.<db>.<t>` にも `AwsDataCatalog` の別名を当てる。
pub fn alias_qualified_names<'a>(
    sql: &'a str,
    aliases: &HashMap<String, String>,
    aws_data_catalog_context: bool,
) -> Cow<'a, str> {
    // 区切りに使う文字はどれも ASCII なので、バイト単位で走査しても UTF-8 の途中で切ることはない。
    let bytes = sql.as_bytes();
    let unquoted_alias = aliases
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case("awsdatacatalog"))
        .map(|(_, trino)| trino)
        .filter(|_| aws_data_catalog_context);
    let mut rewritten: Option<String> = None;
    let mut copied = 0;
    let mut i = 0;
    // 空白とコメントを除いた直前の文字が `.` か（無引用の名前が修飾名の 1 部目かどうか）。
    let mut after_dot = false;

    while i < bytes.len() {
        let start = i;
        i = match bytes[i] {
            b'\'' => skip_quoted(bytes, i),
            b'"' => {
                let end = skip_quoted(bytes, i);
                let identifier = &sql[i..end];
                if let Some(trino) = aliases.get(&unquote(identifier))
                    && next_is_dot(bytes, end)
                {
                    let out = rewritten.get_or_insert_with(|| String::with_capacity(sql.len()));
                    out.push_str(&sql[copied..i]);
                    out.push_str(&replacement(identifier, trino));
                    copied = end;
                }
                end
            }
            _ => match comment_end(bytes, i) {
                Some(end) => end,
                None => match word_end(sql, i) {
                    Some(end) => {
                        if let Some(trino) = unquoted_alias
                            && !after_dot
                            && is_unquoted_aws_data_catalog(sql, i, end)
                        {
                            let out =
                                rewritten.get_or_insert_with(|| String::with_capacity(sql.len()));
                            out.push_str(&sql[copied..i]);
                            out.push_str(&replacement(&sql[i..end], trino));
                            copied = end;
                        }
                        end
                    }
                    None => i + 1,
                },
            },
        };
        if skip_trivia(bytes, start) == start {
            after_dot = bytes[start] == b'.';
        }
    }

    match rewritten {
        Some(mut out) => {
            out.push_str(&sql[copied..]);
            Cow::Owned(out)
        }
        None => Cow::Borrowed(sql),
    }
}

/// `i` から始まる無引用の識別子の終わり。`i` が空白や識別子の始まりでない文字なら None。
/// 走査は非 ASCII の文字の途中にも来るので、文字の境目でなければ切り出さない。
fn word_end(sql: &str, i: usize) -> Option<usize> {
    if !sql.is_char_boundary(i) || skip_trivia(sql.as_bytes(), i) != i {
        return None;
    }
    let mut cursor = Cursor::new(&sql[i..]);
    cursor.identifier().then(|| sql.len() - cursor.rest().len())
}

/// `sql[i..end]` が `awsdatacatalog`（大文字小文字によらない）で、そこから無引用のちょうど 3 部の名前が続くか。
fn is_unquoted_aws_data_catalog(sql: &str, i: usize, end: usize) -> bool {
    sql[i..end].eq_ignore_ascii_case("awsdatacatalog")
        && Cursor::new(&sql[i..]).qualified_name().is_some_and(|name| {
            name.parts.len() == 3 && name.parts.iter().all(|part| !part.text.starts_with('"'))
        })
}

/// 空白とコメントを読み飛ばした次の文字が `.` か。
fn next_is_dot(bytes: &[u8], i: usize) -> bool {
    matches!(bytes.get(skip_trivia(bytes, i)), Some(&b'.'))
}

/// Trino の名前を引用符で包み、元の識別子より短ければ空白で埋めて同じ文字数にする。
/// Trino の桁位置は文字単位で数えるので、バイト数ではなく文字数で揃える。
pub(crate) fn replacement(identifier: &str, trino: &str) -> String {
    let mut quoted = format!("\"{}\"", trino.replace('"', "\"\""));
    let padding = identifier
        .chars()
        .count()
        .saturating_sub(quoted.chars().count());
    quoted.push_str(&" ".repeat(padding));
    quoted
}

#[cfg(test)]
mod tests {
    use super::*;

    const S3_TABLES: &str = "s3tablescatalog/my-bucket";

    fn aliases(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(from, to)| (from.to_string(), to.to_string()))
            .collect()
    }

    fn alias(sql: &str) -> String {
        alias_qualified_names(sql, &aliases(&[(S3_TABLES, "iceberg")]), true).into_owned()
    }

    #[test]
    fn 引用符付きのカタログ名を別名にして桁を空白で揃える() {
        let sql = r#"SELECT * FROM "s3tablescatalog/my-bucket".db.users WHERE id = 1"#;
        let aliased = alias(sql);

        assert_eq!(
            aliased,
            r#"SELECT * FROM "iceberg"                  .db.users WHERE id = 1"#
        );
        assert_eq!(aliased.chars().count(), sql.chars().count());
    }

    #[test]
    fn 修飾名がいくつあってもそれぞれ置き換える() {
        let map = aliases(&[
            ("s3tablescatalog/a", "iceberg_a"),
            ("s3tablescatalog/b", "iceberg_b"),
        ]);
        let sql = r#"SELECT * FROM "s3tablescatalog/a".ns.t JOIN "s3tablescatalog/b"."ns"."u" USING (id)"#;

        assert_eq!(
            alias_qualified_names(sql, &map, true),
            r#"SELECT * FROM "iceberg_a"        .ns.t JOIN "iceberg_b"        ."ns"."u" USING (id)"#
        );
    }

    #[test]
    fn 空白や改行やコメントを挟んで続く点でも置き換える() {
        assert_eq!(
            alias("SELECT * FROM \"s3tablescatalog/my-bucket\" \n\t. db.users"),
            "SELECT * FROM \"iceberg\"                   \n\t. db.users"
        );
        assert_eq!(
            alias(r#"SELECT * FROM "s3tablescatalog/my-bucket" /* c */ .db.users"#),
            r#"SELECT * FROM "iceberg"                   /* c */ .db.users"#
        );
        assert_eq!(
            alias("SELECT * FROM \"s3tablescatalog/my-bucket\" -- c\n.db.users"),
            "SELECT * FROM \"iceberg\"                   -- c\n.db.users"
        );
    }

    #[test]
    fn 後ろに点が続かなければ置き換えない() {
        for sql in [
            r#"SELECT 1 AS "s3tablescatalog/my-bucket""#,
            r#"SHOW SCHEMAS FROM "s3tablescatalog/my-bucket""#,
            r#"SELECT "s3tablescatalog/my-bucket" , x FROM t"#,
            r#"SELECT * FROM "s3tablescatalog/my-bucket" /* . */ -- .
"#,
        ] {
            assert_eq!(alias(sql), sql);
        }
    }

    #[test]
    fn 文字列リテラルとコメントの中は置き換えない() {
        for sql in [
            r#"SELECT '"s3tablescatalog/my-bucket".db.users'"#,
            r#"SELECT 'it''s "s3tablescatalog/my-bucket".db.users'"#,
            "SELECT 1 -- \"s3tablescatalog/my-bucket\".db.users",
            "SELECT 1 /* \"s3tablescatalog/my-bucket\".db.users */",
            "SELECT 1 /* * / \"s3tablescatalog/my-bucket\".db.users */",
            // `/*` の `*` を閉じの `*/` の一部として読まない。
            "SELECT 1 /*/ \"s3tablescatalog/my-bucket\".db.users */",
        ] {
            assert_eq!(alias(sql), sql);
        }
    }

    #[test]
    fn リテラルやコメントが閉じた後ろは置き換える() {
        assert_eq!(
            alias("SELECT 'a''b', 1 -- x\n, 2 /* y */ FROM \"s3tablescatalog/my-bucket\".db.t"),
            "SELECT 'a''b', 1 -- x\n, 2 /* y */ FROM \"iceberg\"                  .db.t"
        );
        // 閉じた直後に空白が無くても、次の識別子を読み飛ばさない。
        assert_eq!(
            alias("SELECT * FROM/* y */\"s3tablescatalog/my-bucket\".db.t"),
            "SELECT * FROM/* y */\"iceberg\"                  .db.t"
        );
        assert_eq!(
            alias("SELECT 'x'\"s3tablescatalog/my-bucket\".db.t"),
            "SELECT 'x'\"iceberg\"                  .db.t"
        );
        // 識別子の中の単一引用符は文字列の始まりではない。
        assert_eq!(
            alias(r#"SELECT "it's" FROM "s3tablescatalog/my-bucket".db.t"#),
            r#"SELECT "it's" FROM "iceberg"                  .db.t"#
        );
    }

    #[test]
    fn 引用符付きの名前は大文字小文字が違えば置き換えない() {
        let map = aliases(&[("AwsDataCatalog", "hive"), (S3_TABLES, "iceberg")]);
        for sql in [
            r#"SELECT * FROM "S3TablesCatalog/my-bucket".db.users"#,
            r#"SELECT * FROM "awsdatacatalog".db.users"#,
        ] {
            assert_eq!(alias_qualified_names(sql, &map, true), sql);
        }
    }

    fn alias_unquoted(sql: &str) -> String {
        let map = aliases(&[("AwsDataCatalog", "hive"), (S3_TABLES, "iceberg")]);
        alias_qualified_names(sql, &map, true).into_owned()
    }

    #[test]
    fn aws_data_catalog_の_context_では無引用の_awsdatacatalog_を大文字小文字によらず置き換える() {
        for (sql, expected) in [
            (
                "SELECT * FROM awsdatacatalog.db.t",
                "SELECT * FROM \"hive\"        .db.t",
            ),
            (
                "INSERT INTO AwsDataCatalog.db.t VALUES (1)",
                "INSERT INTO \"hive\"        .db.t VALUES (1)",
            ),
            (
                "SELECT * FROM awsdatacatalog /* c */ . db . t JOIN AWSDATACATALOG.db.u USING (id)",
                "SELECT * FROM \"hive\"         /* c */ . db . t JOIN \"hive\"        .db.u USING (id)",
            ),
        ] {
            assert_eq!(alias_unquoted(sql), expected);
            assert_eq!(alias_unquoted(sql).chars().count(), sql.chars().count());
        }
    }

    #[test]
    fn 無引用の_awsdatacatalog_は測った形でなければ置き換えない() {
        for sql in [
            // 3 部でない
            "SELECT awsdatacatalog.c FROM t awsdatacatalog",
            "SELECT * FROM awsdatacatalog.db.t.c",
            // 1 部目でない
            "SELECT * FROM x.awsdatacatalog.db.t",
            "SELECT * FROM x . awsdatacatalog.db.t",
            // 名前の一部
            "SELECT * FROM xawsdatacatalog.db.t",
            "SELECT * FROM awsdatacatalog_x.db.t",
            // 引用符付きの部品を含む
            "SELECT * FROM awsdatacatalog.\"db\".t",
            // リテラルとコメントの中
            "SELECT 'awsdatacatalog.db.t'",
            "SELECT 1 -- awsdatacatalog.db.t",
        ] {
            assert_eq!(alias_unquoted(sql), sql);
        }
    }

    #[test]
    fn 無引用の位置に非_ascii_の文字があっても止まらずに後ろを置き換える() {
        assert_eq!(
            alias_unquoted("SELECT 1 AS 列 FROM awsdatacatalog.db.t"),
            "SELECT 1 AS 列 FROM \"hive\"        .db.t"
        );
    }

    #[test]
    fn aws_data_catalog_の_context_でなければ無引用の名前は置き換えない() {
        let map = aliases(&[("AwsDataCatalog", "hive")]);
        let sql = "SELECT * FROM awsdatacatalog.db.t";
        assert_eq!(alias_qualified_names(sql, &map, false), sql);
    }

    #[test]
    fn 別名の方が長ければ空白で埋めずに置き換える() {
        let map = aliases(&[("a", "iceberg")]);
        assert_eq!(
            alias_qualified_names(r#"SELECT * FROM "a".db.t"#, &map, true),
            r#"SELECT * FROM "iceberg".db.t"#
        );
    }

    #[test]
    fn 識別子の二重の引用符は中身として比べて別名では二重にする() {
        let map = aliases(&[("a\"b", "c\"d")]);
        assert_eq!(
            alias_qualified_names(r#"SELECT * FROM "a""b".db.t"#, &map, true),
            r#"SELECT * FROM "c""d".db.t"#
        );
    }

    #[test]
    fn 桁は文字数で揃える() {
        let map = aliases(&[("カタログ/x", "t")]);
        let sql = r#"SELECT * FROM "カタログ/x".db.t"#;
        let aliased = alias_qualified_names(sql, &map, true);

        assert_eq!(aliased, r#"SELECT * FROM "t"     .db.t"#);
        assert_eq!(aliased.chars().count(), sql.chars().count());
    }

    #[test]
    fn 置き換える箇所が無ければ受け取った_sql_を借りたまま返す() {
        let sql = r#"SELECT * FROM "s3tablescatalog/my-bucket".db.users"#;
        assert!(matches!(
            alias_qualified_names(sql, &HashMap::new(), true),
            Cow::Borrowed(_)
        ));
        assert!(matches!(
            alias_qualified_names(
                "SELECT * FROM users",
                &aliases(&[(S3_TABLES, "iceberg")]),
                true
            ),
            Cow::Borrowed(_)
        ));
    }

    #[test]
    fn 閉じていない引用符やコメントでも止まらない() {
        for sql in [
            r#"SELECT "s3tablescatalog/my-bucket"#,
            "SELECT 's3tablescatalog/my-bucket",
            "SELECT 1 /* \"s3tablescatalog/my-bucket\".x",
            "SELECT \"s3tablescatalog/my-bucket\" --",
        ] {
            assert_eq!(alias(sql), sql);
        }
    }
}
