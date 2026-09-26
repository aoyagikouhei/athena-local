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
//! 文字列リテラルとコメントの中は読み飛ばす。置き換えた名前が短ければ閉じ引用符の後ろを空白で埋め、
//! Trino のエラーに出る桁位置を受け取った SQL と揃える（`"tpch"   .tiny.nation` が通ることを Trino 482 で確認）。
//!
//! 字句の読み飛ばし（`skip_quoted`・`comment_end`・`skip_trivia`）と `unquote` は `athena_sql` のものを使う。

use std::borrow::Cow;
use std::collections::HashMap;

use athena_sql::{comment_end, skip_quoted, skip_trivia, unquote};

/// 修飾名のカタログに別名を当てた SQL。置き換える箇所が無ければ受け取った SQL をそのまま返す。
pub fn alias_qualified_names<'a>(sql: &'a str, aliases: &HashMap<String, String>) -> Cow<'a, str> {
    // 区切りに使う文字はどれも ASCII なので、バイト単位で走査しても UTF-8 の途中で切ることはない。
    let bytes = sql.as_bytes();
    let mut rewritten: Option<String> = None;
    let mut copied = 0;
    let mut i = 0;

    while i < bytes.len() {
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
            _ => comment_end(bytes, i).unwrap_or(i + 1),
        };
    }

    match rewritten {
        Some(mut out) => {
            out.push_str(&sql[copied..]);
            Cow::Owned(out)
        }
        None => Cow::Borrowed(sql),
    }
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
        alias_qualified_names(sql, &aliases(&[(S3_TABLES, "iceberg")])).into_owned()
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
            alias_qualified_names(sql, &map),
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
    fn 引用符の無い名前と大文字小文字の違う名前は置き換えない() {
        let map = aliases(&[("AwsDataCatalog", "hive"), (S3_TABLES, "iceberg")]);
        for sql in [
            "SELECT * FROM AwsDataCatalog.db.users",
            r#"SELECT * FROM "S3TablesCatalog/my-bucket".db.users"#,
            r#"SELECT * FROM "awsdatacatalog".db.users"#,
        ] {
            assert_eq!(alias_qualified_names(sql, &map), sql);
        }
    }

    #[test]
    fn 別名の方が長ければ空白で埋めずに置き換える() {
        let map = aliases(&[("a", "iceberg")]);
        assert_eq!(
            alias_qualified_names(r#"SELECT * FROM "a".db.t"#, &map),
            r#"SELECT * FROM "iceberg".db.t"#
        );
    }

    #[test]
    fn 識別子の二重の引用符は中身として比べて別名では二重にする() {
        let map = aliases(&[("a\"b", "c\"d")]);
        assert_eq!(
            alias_qualified_names(r#"SELECT * FROM "a""b".db.t"#, &map),
            r#"SELECT * FROM "c""d".db.t"#
        );
    }

    #[test]
    fn 桁は文字数で揃える() {
        let map = aliases(&[("カタログ/x", "t")]);
        let sql = r#"SELECT * FROM "カタログ/x".db.t"#;
        let aliased = alias_qualified_names(sql, &map);

        assert_eq!(aliased, r#"SELECT * FROM "t"     .db.t"#);
        assert_eq!(aliased.chars().count(), sql.chars().count());
    }

    #[test]
    fn 置き換える箇所が無ければ受け取った_sql_を借りたまま返す() {
        let sql = r#"SELECT * FROM "s3tablescatalog/my-bucket".db.users"#;
        assert!(matches!(
            alias_qualified_names(sql, &HashMap::new()),
            Cow::Borrowed(_)
        ));
        assert!(matches!(
            alias_qualified_names("SELECT * FROM users", &aliases(&[(S3_TABLES, "iceberg")])),
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
