//! CTAS の問い合わせ部分（`AS` の後ろ）の範囲。本物は Glue に無い DB への CTAS でも問い合わせをエンジンで実行してから
//! 失敗し、書いた行数を `.metadata` に置いた（2026-09-27 実測 r4・t6〜t15。#251）。athena-local はこの範囲を受け取った文
//! から切り出してそのまま Trino に投げ、行数とエンジンのクエリ ID を得る（文字は 1 つも変えない）。

use std::ops::Range;

use athena_sql::{Word, words_iter};

/// CTAS の問い合わせ部分。
#[derive(Debug, PartialEq, Eq)]
pub(super) struct QueryPart {
    /// `AS` の次の語の先頭から、問い合わせの最後の語の末尾まで（末尾の `WITH [NO] DATA` と後ろのコメントは含めない）。
    pub(super) range: Range<usize>,
    /// 末尾が `WITH NO DATA` か（本物は行を書かず、`.metadata` の件数は 0。t9）。
    pub(super) no_data: bool,
    /// 範囲より前（`WITH (prop = ?)` など）にある `?` の個数。ExecutionParameters はその数だけ読み飛ばして当てる。
    pub(super) leading_parameters: usize,
}

/// `CREATE [OR REPLACE] TABLE ... AS [(...] SELECT | WITH | VALUES | TABLE ...` の問い合わせ部分。`AS` の見つけ方は
/// `results::is_create_table_as` と同じ（`AS` の次の語から先頭の `(` を外して、4 つの語のどれかで始まるか）。
/// `WITH (format = ...) AS SELECT`・`AS (SELECT ...)`・`AS WITH c AS (...) SELECT` は、どれも最初に当たる `AS` の後ろ
/// （t8・t13・t14）。
pub(super) fn query_part(sql: &str) -> Option<QueryPart> {
    let words: Vec<Word> = words_iter(sql).collect();
    let table = match words.get(1).map(|word| word.upper.as_str()) {
        Some("OR") => 3,
        _ => 1,
    };
    if words.first()?.upper != "CREATE" || words.get(table)?.upper != "TABLE" {
        return None;
    }
    let at = (table + 1..words.len())
        .find(|&i| words[i].upper == "AS" && starts_query(&words[i + 1..]))?;
    let upper: Vec<&str> = words.iter().map(|word| word.upper.as_str()).collect();
    let (last, no_data) = match upper.as_slice() {
        [.., "WITH", "NO", "DATA"] => (words.len() - 3, true),
        [.., "WITH", "DATA"] => (words.len() - 2, false),
        _ => (words.len(), false),
    };
    (last > at + 1).then(|| QueryPart {
        range: words[at + 1].start..words[last - 1].end,
        no_data,
        leading_parameters: upper[..at]
            .iter()
            .filter(|word| !word.starts_with(['\'', '"']))
            .map(|word| word.matches('?').count())
            .sum(),
    })
}

/// 語の並びが問い合わせの始まりか（先頭の `(` だけの語は飛ばし、語の先頭の `(` は外して見る）。
fn starts_query(rest: &[Word]) -> bool {
    rest.iter()
        .map(|word| word.upper.trim_start_matches('('))
        .find(|upper| !upper.is_empty())
        .is_some_and(|upper| {
            ["SELECT", "WITH", "VALUES", "TABLE"]
                .iter()
                .any(|head| upper.starts_with(head))
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn part(sql: &str) -> Option<(&str, bool)> {
        query_part(sql).map(|part| (&sql[part.range], part.no_data))
    }

    #[test]
    fn as_の後ろの問い合わせ部分を受け取ったまま切り出す() {
        for (sql, expected) in [
            ("CREATE TABLE db.t AS SELECT 1 AS n", "SELECT 1 AS n"),
            (
                "CREATE TABLE db.t WITH (format = 'PARQUET') AS SELECT 1 AS n",
                "SELECT 1 AS n",
            ),
            ("CREATE TABLE db.t AS (SELECT 1 AS n)", "(SELECT 1 AS n)"),
            ("CREATE TABLE db.t AS(SELECT 1 AS n)", "(SELECT 1 AS n)"),
            (
                "CREATE TABLE db.t AS WITH c AS (SELECT 1 AS n) SELECT n FROM c",
                "WITH c AS (SELECT 1 AS n) SELECT n FROM c",
            ),
            (
                "create table if not exists db.t as\n  select 'AS' as \"as\" -- c\n",
                "select 'AS' as \"as\"",
            ),
            (
                "CREATE TABLE db.t /* AS */ AS /* c */ SELECT ? AS n",
                "SELECT ? AS n",
            ),
            ("CREATE OR REPLACE TABLE db.t AS VALUES (1)", "VALUES (1)"),
            (
                "CREATE TABLE db.t WITH (location = 's3://a--b/AS/') AS SELECT 1",
                "SELECT 1",
            ),
        ] {
            assert_eq!(part(sql), Some((expected, false)), "{sql}");
        }
    }

    /// 末尾の `WITH NO DATA` は範囲から外し、件数 0 の印を立てる。`WITH DATA` も範囲から外す。
    #[test]
    fn 末尾の_with_no_data_は範囲から外す() {
        assert_eq!(
            part("CREATE TABLE db.t AS SELECT 1 AS n WITH NO DATA"),
            Some(("SELECT 1 AS n", true))
        );
        assert_eq!(
            part("CREATE TABLE db.t AS SELECT 1 AS n with data"),
            Some(("SELECT 1 AS n", false))
        );
    }

    /// 範囲より前の `?` を数える。記号が続くと 1 語（`?,`）になるので語の中の `?` を数え、引用符で始まる語（文字列や
    /// 引用符付きの名前）の中は数えない。
    #[test]
    fn 範囲より前の_placeholder_を数える() {
        for (sql, expected) in [
            ("CREATE TABLE db.t AS SELECT ? AS n", 0),
            (
                "CREATE TABLE db.t WITH (format = ?, location = '?') AS SELECT ? AS n",
                1,
            ),
        ] {
            assert_eq!(
                query_part(sql).map(|part| part.leading_parameters),
                Some(expected),
                "{sql}"
            );
        }
    }

    #[test]
    fn ctas_でなければ切り出さない() {
        for sql in [
            "CREATE TABLE db.t (n int)",
            "CREATE VIEW v AS SELECT 1",
            "INSERT INTO t SELECT 1",
            "CREATE TABLE db.t AS",
            "CREATE TABLE db.t AS WITH NO DATA",
        ] {
            assert_eq!(part(sql), None, "{sql}");
        }
    }
}
