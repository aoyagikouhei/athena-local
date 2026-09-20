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
//! 文の種類の判定（`operation/classification.rs`／`results.rs`）が先頭の空白とコメントを読み飛ばすのにも使う
//! 字句処理（`skip_leading_trivia`）をここに置く。

use std::borrow::Cow;
use std::collections::HashMap;

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

/// `'...'` や `"..."` の終わりの次の位置。引用符を 2 つ重ねたものは中身として読む。閉じていなければ末尾。
///
/// `operation/table_format.rs` が DROP TABLE の修飾名の引用符付き識別子を読むのにも再利用する（issue #39 Phase 2）。
pub(crate) fn skip_quoted(bytes: &[u8], start: usize) -> usize {
    let quote = bytes[start];
    let mut i = start + 1;
    while i < bytes.len() {
        if bytes[i] == quote {
            if bytes.get(i + 1) == Some(&quote) {
                i += 2;
                continue;
            }
            return i + 1;
        }
        i += 1;
    }
    bytes.len()
}

/// `--` か `/*` で始まるコメントなら、その終わりの次の位置。閉じていなければ末尾。
///
/// `operation/table_format.rs` が DROP TABLE の修飾名を読むのにも再利用する（issue #39 Phase 2）。
pub(crate) fn comment_end(bytes: &[u8], start: usize) -> Option<usize> {
    let rest = &bytes[start..];
    if rest.starts_with(b"--") {
        let end = rest.iter().position(|&b| b == b'\n').unwrap_or(rest.len());
        Some(start + end)
    } else if rest.starts_with(b"/*") {
        let end = rest[2..]
            .windows(2)
            .position(|pair| pair == b"*/")
            .map_or(rest.len(), |position| position + 4);
        Some(start + end)
    } else {
        None
    }
}

/// 先頭の空白とコメント（`--` と `/* */`）を、交互に現れても全部読み飛ばした残りを返す。
/// 文の種類の判定（`words()`／`ResultFile::of`）が使う。区切りはすべて ASCII なので、
/// バイト単位で走査しても UTF-8 の途中を切らない（区切りに使う文字がどれも ASCII のため）。
///
/// 全部がトリビアだった（コメントだけの文や空白だけの文）ときは空文字列を返す。本物はそういう文を
/// 「先頭のキーワードが無い」として構文エラーにするので、athena-local でも直後の構文チェック
/// （`Trino::syntax_error`）が弾き、分類のこの粗さは観測できる差にならない（2026-09-18 実測）。
///
/// 未閉じの `/*` は `comment_end` と同じく末尾まで飛ばす。本物は未閉じの `/*` をコメントとして
/// 扱わず `line 1:1` でそこの `/` を読むという違いがあるが（2026-09-18 実測）、どちらも構文エラーに
/// なって実行が作られないので、この差も観測できない。
pub(crate) fn skip_leading_trivia(sql: &str) -> &str {
    let bytes = sql.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b' ' | b'\t' | b'\r' | b'\n' => i += 1,
            _ => match comment_end(bytes, i) {
                Some(end) => i = end,
                None => break,
            },
        }
    }
    &sql[i..]
}

/// 空白とコメントを読み飛ばした次の文字が `.` か。
fn next_is_dot(bytes: &[u8], mut i: usize) -> bool {
    while i < bytes.len() {
        match bytes[i] {
            b' ' | b'\t' | b'\r' | b'\n' => i += 1,
            _ => match comment_end(bytes, i) {
                Some(end) => i = end,
                None => return bytes[i] == b'.',
            },
        }
    }
    false
}

/// `"a""b"` の中身 `a"b`。
///
/// `operation/table_format.rs` が DROP TABLE の修飾名の引用符付き識別子を読むのにも再利用する（issue #39 Phase 2）。
pub(crate) fn unquote(identifier: &str) -> String {
    let inner = identifier
        .strip_prefix('"')
        .and_then(|rest| rest.strip_suffix('"'))
        .unwrap_or(identifier);
    inner.replace("\"\"", "\"")
}

/// Trino の名前を引用符で包み、元の識別子より短ければ空白で埋めて同じ文字数にする。
/// Trino の桁位置は文字単位で数えるので、バイト数ではなく文字数で揃える。
fn replacement(identifier: &str, trino: &str) -> String {
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

    #[test]
    fn トリビアが無ければ受け取った_sql_をそのまま返す() {
        assert_eq!(skip_leading_trivia("SELECT 1"), "SELECT 1");
        assert_eq!(skip_leading_trivia("(SELECT 1)"), "(SELECT 1)");
    }

    #[test]
    fn 行コメントを読み飛ばす() {
        assert_eq!(skip_leading_trivia("-- c\nSELECT 1"), "SELECT 1");
        assert_eq!(skip_leading_trivia("--c\nSELECT 1"), "SELECT 1");
    }

    #[test]
    fn ブロックコメントを読み飛ばす() {
        assert_eq!(skip_leading_trivia("/* c */ SELECT 1"), "SELECT 1");
        assert_eq!(skip_leading_trivia("/* c */SELECT 1"), "SELECT 1");
        assert_eq!(skip_leading_trivia("/* a\nb */ SELECT 1"), "SELECT 1");
        assert_eq!(skip_leading_trivia("/*/ x */ SELECT 1"), "SELECT 1");
    }

    #[test]
    fn 空白とコメントを交互に読み飛ばす() {
        assert_eq!(
            skip_leading_trivia("  -- a\n\n /* b */  SELECT 1"),
            "SELECT 1"
        );
        assert_eq!(skip_leading_trivia("-- a\n-- b\nSELECT 1"), "SELECT 1");
    }

    #[test]
    fn コメントだけの文は空文字列になる() {
        assert_eq!(skip_leading_trivia("-- only"), "");
        assert_eq!(skip_leading_trivia("/* only */"), "");
        assert_eq!(skip_leading_trivia("   "), "");
        assert_eq!(skip_leading_trivia(""), "");
        // 未閉じの `/*` も comment_end が末尾まで飛ばすので空文字列になる。
        assert_eq!(skip_leading_trivia("/* c SELECT 1"), "");
    }

    #[test]
    fn 非_ascii_のコメントでもバイト単位の走査が途中を切らない() {
        assert_eq!(skip_leading_trivia("-- あ\nSELECT 1"), "SELECT 1");
    }
}
