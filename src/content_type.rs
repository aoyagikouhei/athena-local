//! 結果ファイル本体と `.metadata` に付ける Content-Type。本物の Athena は
//! `binary/octet-stream` と `application/octet-stream` を文の形で使い分ける
//! （2026-09-23 に 36 項目を対照つきで実測。issue #70。同日に 18 項目を足して裏取り。#76）。ファイル名（`ResultFile::of`）は
//! 先頭のキーワードだけで決まるが、Content-Type は SELECT の本文（リテラルだけか）まで見るので、
//! 判定をここに分けて置く。`.metadata` は本体と同じ値（36 項目すべて一致。例外は 140 MB の
//! マルチパート本体だけで、athena-local は単一の PUT しかしない）。

use crate::catalog::{skip_keyword, skip_leading_trivia, skip_quoted, words};
use crate::results::ResultFile;

/// 本物がエンジンの計画を通さずに置くファイルの値（実測ではどれも `QueryPlanningTimeInMillis` が
/// 無かった）: リテラルだけの SELECT、SHOW（SHOW CREATE TABLE を除く）、0 バイトの DDL。
pub(crate) const BINARY: &str = "binary/octet-stream";
/// それ以外: 式を含む SELECT、DESCRIBE、EXPLAIN、SHOW CREATE TABLE、SHOW FUNCTIONS（`.csv`）、DML と CTAS の `.metadata`、
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

/// `.txt` の文。DESCRIBE（`DESC` も）・EXPLAIN・SHOW CREATE TABLE だけが application で、
/// 残りの SHOW（TABLES・DATABASES・COLUMNS・TBLPROPERTIES・VIEWS・PARTITIONS）と 0 バイトの DDL は
/// binary（2026-09-23 実測）。`("DESCRIBE" | "DESC", _) | ("SHOW", "CREATE")` の組は
/// `operation/result_output.rs` の `metadata_query_id`（`.metadata` に QueryExecutionId を載せる文）と
/// 同じで、片方を変えたら両方を変える（こちらは `EXPLAIN` も application に入れる
/// 点と、語の分割に `catalog::words` を使う点が違う）。`SHOW CREATE VIEW` は未測定で（測る DB に
/// ビューが無かった）、`SHOW CREATE TABLE` の判定に揃えている。`SHOW FUNCTIONS` は `.txt` ではなく
/// `.csv`（`ResultFile::Csv`）なのでここには届かず、SELECT と同じ判定で application になる
/// （2026-09-23 実測。#80）。`SHOW SESSION` と `SHOW STATS` は
/// 本物が StartQueryExecution で構文エラーにするので、値は無い（2026-09-23 実測。#76）。
fn text_content_type(query: &str) -> &'static str {
    let words = words(query);
    let word = |index: usize| words.get(index).map(String::as_str).unwrap_or_default();
    match (word(0), word(1)) {
        ("DESCRIBE" | "DESC" | "EXPLAIN", _) | ("SHOW", "CREATE") => APPLICATION,
        _ => BINARY,
    }
}

/// `SELECT` の後ろが、リテラル（`-` を付けてもよい整数・小数・指数つきの数、`'...'`、TRUE／FALSE）に
/// 任意で別名（`AS` の有無を問わず、無引用か `"..."` の識別子）の付いたものを `,` で並べただけで
/// 終わる文。実測した形は `SELECT 1`、`SELECT 1, 2`、`SELECT 'a'`、`SELECT 1.5`、`SELECT 1 AS i`、
/// `SELECT true`、`SELECT 1, 'a'`、`SELECT 23807 AS fresh`（#70）、`SELECT 1 AS i, 2 AS j`、`select 1`、
/// `SELECT -1`、`SELECT 1.5E0`、`SELECT 1 AS "x"`、`SELECT 1 i`（#76）と、先頭・キーワードの間・末尾に
/// コメントを置いたもの。一般化は「別名・符号・指数の組み合わせ」「小文字の `e` と符号つきの指数」
/// 「キーワードの大文字小文字」だけ。測って application だった形（`LIMIT`、`DATE '...'` のような
/// 型付きリテラル、式、`ARRAY[1]`、`(SELECT 1)`、`VALUES 1`）と測っていない形は false にして
/// application に落とす（本物が binary にする形を取りこぼす向きにだけ外れる）。
fn is_literal_only_select(query: &str) -> bool {
    let Some(mut rest) = skip_keyword(query, "SELECT") else {
        return false;
    };
    loop {
        let Some(after_literal) = skip_literal(skip_leading_trivia(rest)) else {
            return false;
        };
        rest = skip_leading_trivia(after_literal);
        let after_as = skip_keyword(rest, "AS");
        match skip_identifier(skip_leading_trivia(after_as.unwrap_or(rest))) {
            Some(after_alias) => rest = skip_leading_trivia(after_alias),
            // `AS` の後ろに識別子が無ければ受理しない。`AS` が無ければ別名は任意。
            None if after_as.is_some() => return false,
            None => {}
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
        // `-` は数に直接続くときだけ（`SELECT -1` 実測。`- 1` は測っていない）。
        b'-' => skip_number(&input[1..]),
        _ => skip_keyword(input, "TRUE").or_else(|| skip_keyword(input, "FALSE")),
    }
}

/// `1`、`1.5`、`1.5E0`（`e` でもよく、指数に符号を付けてもよい）。直後に識別子の文字や `.` が
/// 続くもの（`1.5.2`、`1E0x`）と、`.` や `E` の後に数字が無いもの（`1.`、`1E`）は数のリテラルとして
/// 読まない。
fn skip_number(input: &str) -> Option<&str> {
    let digits = |s: &str| s.len() - s.trim_start_matches(|c: char| c.is_ascii_digit()).len();
    let mut end = digits(input);
    if end == 0 {
        return None;
    }
    if let Some(fraction) = input[end..].strip_prefix('.') {
        let count = digits(fraction);
        if count == 0 {
            return None;
        }
        end += 1 + count;
    }
    if let Some(exponent) = input[end..].strip_prefix(['E', 'e']) {
        let unsigned = exponent.strip_prefix(['+', '-']).unwrap_or(exponent);
        let count = digits(unsigned);
        if count == 0 {
            return None;
        }
        end += 1 + (exponent.len() - unsigned.len()) + count;
    }
    let rest = &input[end..];
    if rest.starts_with(|c: char| c.is_ascii_alphanumeric() || c == '_' || c == '.') {
        return None;
    }
    Some(rest)
}

/// 識別子を 1 つ読み飛ばした残り。無引用（英字か `_` で始まり、英数字と `_` が続く）か、
/// `"..."`（`""` の重ねも 1 つ。閉じていなければ末尾まで。`skip_literal` の `'...'` と同じ扱い）。
fn skip_identifier(input: &str) -> Option<&str> {
    if input.starts_with('"') {
        return Some(&input[skip_quoted(input.as_bytes(), 0)..]);
    }
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
            // 2026-09-23 実測の追加分（#76）。`SELECT 1 AS i, 2 AS j` と `select 1` は #70 で
            // 一般化していた形の裏取り、残りは #70 が application に落としていた形。
            "SELECT 1 AS i, 2 AS j",
            "select 1",
            "SELECT -1",
            "SELECT 1.5E0",
            "SELECT 1 AS \"x\"",
            "SELECT 1 i",
            // 一般化: 別名の組み合わせ、大文字小文字、空白なし、引用符の重ね、符号と指数の組み合わせ。
            "select 1 as i",
            "SELECT/* c */1,'a''b'",
            "SELECT FALSE, 'it''s'",
            "SELECT -1.5, 1e0, 1E+1, 2.5e-1 AS \"a\"\"b\", 3 c",
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
            "(SELECT 1)",
            // 本物は binary（2026-09-23 実測）だが、Trino が末尾の `;` を構文エラーにするので
            // athena-local では構文チェックで FAILED になり、ここには届かない。判定は変えない。
            "SELECT 1;",
            // 途中で終わる・数の形が崩れているもの。パーサの拒否の分岐を 1 つずつ踏む。
            "SELECT",
            "SELECT 1,",
            "SELECT 1.",
            "SELECT 1E",
            "SELECT 1E+",
            "SELECT -",
            "SELECT - 1",
            "SELECT 1 AS",
            "SELECT 1 AS 'x'",
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
    fn show_functions_は_csv_として_application() {
        // 本物は `<id>.csv` に application で書く（2026-09-23 実測。#76／#80）。
        // ファイル名が Csv なので `.txt` の判定には届かず、SELECT と同じ判定で application になる。
        for query in ["SHOW FUNCTIONS", "SHOW /* c */ FUNCTIONS"] {
            assert_eq!(ResultFile::of(query), ResultFile::Csv, "{query:?}");
            assert_eq!(csv(query), APPLICATION, "{query:?}");
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
