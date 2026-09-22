//! 結果ファイル本体と `.metadata` に付ける Content-Type。本物の Athena は
//! `binary/octet-stream` と `application/octet-stream` を文の形で使い分ける
//! （2026-09-23 に 36 項目を対照つきで実測。issue #70）。ファイル名（`ResultFile::of`）は
//! 先頭のキーワードだけで決まるが、Content-Type は SELECT の本文（リテラルだけか）まで見るので、
//! 判定をここに分けて置く。`.metadata` は本体と同じ値（36 項目すべて一致。例外は 140 MB の
//! マルチパート本体だけで、athena-local は単一の PUT しかしない）。

use crate::catalog::{skip_keyword, skip_leading_trivia, skip_quoted, words};
use crate::results::ResultFile;

/// 本物がエンジンの計画を通さずに置くファイルの値（実測ではどれも `QueryPlanningTimeInMillis` が
/// 無かった）: リテラルだけの SELECT、SHOW（SHOW CREATE TABLE を除く）、0 バイトの DDL。
pub(crate) const BINARY: &str = "binary/octet-stream";
/// それ以外: 式を含む SELECT、DESCRIBE、EXPLAIN、SHOW CREATE TABLE、DML と CTAS の `.metadata`、
/// 失敗の理由の `.txt`（2026-09-17 実測）、DROP TABLE × Iceberg など列なしでも `.metadata` を置く DDL
/// （2026-09-20／21 実測。issue #39）。
pub(crate) const APPLICATION: &str = "application/octet-stream";

/// 本体に付ける Content-Type。`ResultLocation::new` が保持し、`.metadata` にも同じ値を使う。
pub(crate) fn of(file: ResultFile, query: &str) -> &'static str {
    match file {
        ResultFile::Csv if is_literal_only_select(query) => BINARY,
        ResultFile::Csv => APPLICATION,
        ResultFile::Text => text_content_type(query),
        // 本体は書かず `.metadata` だけを置く文（INSERT と CTAS）。本物の `.metadata` は application
        // （2026-09-17／18 実測）。本体を書かないからといって到達しない値ではなく、
        // `ResultLocation::metadata` が引き継いで `.metadata` の実値になる（#70 の計画レビュー）。
        ResultFile::Manifest | ResultFile::Table => APPLICATION,
        ResultFile::Metadata | ResultFile::FailedText => {
            unreachable!("付随ファイルと失敗ファイルの Content-Type は ResultLocation が決める")
        }
    }
}

/// `.txt` の文。DESCRIBE・EXPLAIN・SHOW CREATE TABLE だけが application で、残りの SHOW
/// （TABLES・DATABASES・COLUMNS・TBLPROPERTIES・VIEWS・PARTITIONS）と 0 バイトの DDL は binary
/// （2026-09-23 実測）。`("DESCRIBE" | "DESC", _) | ("SHOW", "CREATE")` の組は
/// `operation/result_output.rs` の `metadata_query_id` と同じで、片方を変えたら両方を変える。
/// `DESC` と `SHOW CREATE VIEW` は未測定で、その判定に揃えている（#76）。
fn text_content_type(query: &str) -> &'static str {
    let words = words(query);
    let word = |index: usize| words.get(index).map(String::as_str).unwrap_or_default();
    match (word(0), word(1)) {
        ("DESCRIBE" | "DESC" | "EXPLAIN", _) | ("SHOW", "CREATE") => APPLICATION,
        _ => BINARY,
    }
}

/// `SELECT` の後ろが、リテラル（符号なしの整数か小数・`'...'`・TRUE／FALSE）に任意で
/// `AS <無引用の識別子>` の付いたものを `,` で並べただけで終わる文。実測した形は
/// `SELECT 1`、`SELECT 1, 2`、`SELECT 'a'`、`SELECT 1.5`、`SELECT 1 AS i`、`SELECT true`、
/// `SELECT 1, 'a'`、`SELECT 23807 AS fresh` と、先頭・キーワードの間・末尾にコメントを置いたもの。
/// 一般化は「複数列と別名の組み合わせ」と「キーワードの大文字小文字」だけ。測っていない形
/// （`SELECT -1`、`SELECT 1;`、`SELECT 1 LIMIT 1`、`DATE '...'` のような型付きリテラル、式、
/// 引用符付きの別名、裸の別名、`(SELECT 1)`、`VALUES 1`）は false にして application に落とす
/// （これまでの値。本物が binary にする形を取りこぼす向きにだけ外れる。#76）。
fn is_literal_only_select(query: &str) -> bool {
    let Some(mut rest) = skip_keyword(query, "SELECT") else {
        return false;
    };
    loop {
        let Some(after_literal) = skip_literal(skip_leading_trivia(rest)) else {
            return false;
        };
        rest = skip_leading_trivia(after_literal);
        if let Some(after_as) = skip_keyword(rest, "AS") {
            let Some(after_alias) = skip_identifier(skip_leading_trivia(after_as)) else {
                return false;
            };
            rest = skip_leading_trivia(after_alias);
        }
        match rest.strip_prefix(',') {
            Some(next) => rest = next,
            None => return rest.is_empty(),
        }
    }
}

/// リテラルを 1 つ読み飛ばした残り。文字列は `skip_quoted` で読む（`'a''b'` も 1 つ。中の `--` は
/// コメントではない）。閉じていない `'...` は末尾まで読んで受理するが、その文は構文チェック
/// （`Trino::syntax_error`）が先に弾くのでここには届かない。
fn skip_literal(input: &str) -> Option<&str> {
    match input.as_bytes().first()? {
        b'\'' => Some(&input[skip_quoted(input.as_bytes(), 0)..]),
        b'0'..=b'9' => skip_number(input),
        _ => skip_keyword(input, "TRUE").or_else(|| skip_keyword(input, "FALSE")),
    }
}

/// `1` か `1.5`。直後に識別子の文字や `.` が続くもの（`1e0`、`1.5.2`）と、`.` の後に数字が
/// 無いもの（`1.`）は数のリテラルとして読まない。
fn skip_number(input: &str) -> Option<&str> {
    let digits = |s: &str| s.len() - s.trim_start_matches(|c: char| c.is_ascii_digit()).len();
    let mut end = digits(input);
    if let Some(fraction) = input[end..].strip_prefix('.') {
        let count = digits(fraction);
        if count == 0 {
            return None;
        }
        end += 1 + count;
    }
    let rest = &input[end..];
    if rest.starts_with(|c: char| c.is_ascii_alphanumeric() || c == '_' || c == '.') {
        return None;
    }
    Some(rest)
}

/// 無引用の識別子（英字か `_` で始まり、英数字と `_` が続く）を 1 つ読み飛ばした残り。
fn skip_identifier(input: &str) -> Option<&str> {
    if !input.starts_with(|c: char| c.is_ascii_alphabetic() || c == '_') {
        return None;
    }
    let end = input
        .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
        .unwrap_or(input.len());
    Some(&input[end..])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn csv(query: &str) -> &'static str {
        of(ResultFile::Csv, query)
    }

    #[test]
    fn リテラルだけの_select_は_binary() {
        for query in [
            // 2026-09-23 実測の 8 形（`23807` は初めて流す SQL の 1 回目）。
            "SELECT 1",
            "SELECT 1, 2",
            "SELECT 'a'",
            "SELECT 1.5",
            "SELECT 1 AS i",
            "SELECT true",
            "SELECT 1, 'a'",
            "SELECT 23807 AS fresh",
            // コメント付き（2026-09-18／22 実測）。
            "-- c\nSELECT 1",
            "/* c */ SELECT 1",
            "SELECT /* c */ 1",
            "SELECT 1 -- c",
            // 一般化: 複数列と別名の組み合わせ、大文字小文字、空白なし、引用符の重ね。
            "SELECT 1 AS i, 2 AS j",
            "select 1 as i",
            "SELECT/* c */1,'a''b'",
            "SELECT FALSE, 'it''s'",
        ] {
            assert_eq!(csv(query), BINARY, "{query:?}");
        }
    }

    #[test]
    fn リテラル以外を含む_select_は_application() {
        for query in [
            // 2026-09-23 実測の application（過去の実測を含む）。
            "SELECT 1 AS i WHERE false",
            "SELECT 1 WHERE true",
            "SELECT CAST(1.5 AS DOUBLE)",
            "SELECT CAST(1 AS BIGINT)",
            "SELECT NULL",
            "SELECT 1 + 1",
            "SELECT * FROM (VALUES 1)",
            "SELECT 1 UNION ALL SELECT 2",
            "SELECT 1 FROM t LIMIT 1",
            "SELECT 1 AS i, 'abc' AS s, CAST(1.5 AS DOUBLE) AS d",
            "SELECT id, name FROM users",
            // 未測定で application に落とす形。パーサの拒否の分岐を 1 つずつ踏む（#76 で測ったら直す）。
            "SELECT -1",
            "SELECT 1;",
            "SELECT 1 i",
            "SELECT 1 AS \"x\"",
            "SELECT 1.5E0",
            "(SELECT 1)",
            // 途中で終わる・数の形が崩れているもの。
            "SELECT",
            "SELECT 1,",
            "SELECT 1.",
            "SELECT 1 AS",
            "SELECT trueish",
        ] {
            assert_eq!(csv(query), APPLICATION, "{query:?}");
        }
    }

    #[test]
    fn txt_は_show_と_ddl_が_binary_で_describe_explain_show_create_が_application() {
        let txt = |query| of(ResultFile::Text, query);
        for query in [
            "SHOW TABLES IN db",
            "SHOW DATABASES",
            "SHOW COLUMNS IN t",
            "SHOW TBLPROPERTIES t",
            "SHOW VIEWS IN db",
            "SHOW PARTITIONS t",
            "SHOW /* c */ TABLES",
            "CREATE DATABASE d",
            "DROP TABLE t",
            "ALTER TABLE t ADD COLUMNS (m int)",
        ] {
            assert_eq!(txt(query), BINARY, "{query:?}");
        }
        for query in [
            "DESCRIBE t",
            "-- c\nDESCRIBE t",
            "DESC t",
            "EXPLAIN SELECT 1",
            "SHOW CREATE TABLE t",
            "show create table t",
        ] {
            assert_eq!(txt(query), APPLICATION, "{query:?}");
        }
    }

    #[test]
    fn 本体を書かない_insert_と_ctas_は_metadata_の値として_application() {
        assert_eq!(
            of(ResultFile::Manifest, "INSERT INTO t VALUES (1)"),
            APPLICATION
        );
        assert_eq!(
            of(ResultFile::Table, "CREATE TABLE t AS SELECT 1"),
            APPLICATION
        );
    }
}
