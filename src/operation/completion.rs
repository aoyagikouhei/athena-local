//! run の完了後の後処理（Iceberg のパーティション取得・EXPLAIN の行分割・UpdateCount の決定）。

use crate::catalog::alias_qualified_names;
use crate::config::Config;
use crate::trino::{Cancel, Outcome, Trino};

use super::table_format::FormatOverride;

/// Iceberg のテーブルの DESCRIBE の対象を Trino の `SHOW CREATE TABLE` で引き、`partitioning` の要素を返す
/// （2026-09-24 実測 d2・d8。#173）。名前は元の SQL の範囲をそのまま使い、本体と同じく別名を当てて
/// 同じカタログ・スキーマで投げる（引用符と別名の解決を本体と揃える）。失敗や値が取れないときは空
/// （DESCRIBE 自体は成功のまま）。ビューは形式の問い合わせで `View` になるので、ここには来ない。
pub(super) async fn iceberg_partition_specs(
    trino: &Trino,
    config: &Config,
    query: &str,
    catalog: Option<&str>,
    database: Option<&str>,
    cancel: &Cancel,
) -> Vec<String> {
    let Some(name) = describe_target_name(query) else {
        return Vec::new();
    };
    let sql = format!("SHOW CREATE TABLE {name}");
    let sql = alias_qualified_names(&sql, &config.catalog_map);
    let Ok(outcome) = trino.execute(&sql, catalog, database, cancel).await else {
        return Vec::new();
    };
    match outcome.rows.first().and_then(|row| row.first()) {
        Some(serde_json::Value::String(ddl)) => super::iceberg_partitions::parse_partitioning(ddl),
        _ => Vec::new(),
    }
}

/// DESCRIBE の対象の名前の、元の SQL での範囲。`iceberg_partition_specs` が Trino に投げる名前。
pub(super) fn describe_target_name(query: &str) -> Option<&str> {
    let after = athena_sql::skip_keyword(query, "DESCRIBE")
        .or_else(|| athena_sql::skip_keyword(query, "DESC"))?;
    let start = after.len() - athena_sql::skip_leading_trivia(after).len();
    let end = athena_sql::skip_qualified_name(after, start);
    Some(&after[start..end])
}

/// EXPLAIN の結果を本物と同じくプランの行ごとに分ける。Trino は `Query Plan` 列の 1 行に改行入りの
/// 全文（末尾は `\n\n`）を返すが、本物の Athena は全文の末尾に改行を 1 つ足してから `\n` で分けた
/// 行を返す（`EXPLAIN SELECT 1` の Rows は列名行 + 非空 11 行 + 空行 3 行の 15 行、`.txt` は
/// 列名行 + 全文 + `\n` の 393 バイト。2026-09-15／16 の 4 ラウンドで実測。#73）。
/// 分けた行を実行結果として持ち回るので、GetQueryResults と `.txt` の行数が揃う。
/// 同じ規則が、改行で終わらないプラン（`FORMAT JSON`／`TYPE IO`。末尾に空行 1 つ）、`\n` 1 つで
/// 終わる `FORMAT GRAPHVIZ`（空行 2 つ）、`ANALYZE`／`TYPE DISTRIBUTED`（空行 3 つ）と、boolean の
/// `true` を返す `TYPE VALIDATE`（`true` + 空行）にも当たる（2026-09-23 に 8 形を同じラウンドで実測。#92）。
pub(super) fn split_explain_rows(query: &str, mut outcome: Outcome) -> Outcome {
    if super::classification::substatement_type(query) != Some("EXPLAIN") {
        return outcome;
    }
    let rows = std::mem::take(&mut outcome.rows);
    outcome.rows = rows
        .into_iter()
        .flat_map(|row| {
            let text = match row.first() {
                Some(serde_json::Value::String(text)) => text.clone(),
                Some(serde_json::Value::Bool(flag)) => flag.to_string(),
                _ => return vec![row],
            };
            text.split('\n')
                .chain(std::iter::once(""))
                .map(|line| vec![serde_json::Value::from(line)])
                .collect()
        })
        .collect();
    outcome
}

/// SHOW CREATE TABLE／SHOW CREATE VIEW の結果を本物と同じく本体の行ごとに分ける。Trino は全文を改行入りの
/// 1 値で返すが、本物の GetQueryResults は `\n` で分けた行を返す（行数は本体の行数と同じで、EXPLAIN と
/// 違って末尾に空行を足さない。Hive・Iceberg・ビューの 6 本で実測。2026-09-16・2026-09-24。#181）。
/// `.txt` は行を `\n` でつなぐので、分けても本体のバイト列は変わらない。
pub(super) fn split_show_create_rows(query: &str, mut outcome: Outcome) -> Outcome {
    if !matches!(
        super::classification::substatement_type(query),
        Some("SHOW_CREATE_TABLE" | "SHOW_CREATE_VIEW")
    ) {
        return outcome;
    }
    let rows = std::mem::take(&mut outcome.rows);
    outcome.rows = rows
        .into_iter()
        .flat_map(|row| match row.first() {
            Some(serde_json::Value::String(text)) => text
                .split('\n')
                .map(|line| vec![serde_json::Value::from(line)])
                .collect(),
            _ => vec![row],
        })
        .collect();
    outcome
}

/// GetQueryResults の UpdateCount。本物は SELECT と SHOW でも 0 を返し、DDL では null を返す
/// （2026-09-14 実測。SDK から見て null と省略は同じなので、DDL は省く）。DML と CTAS は Trino が返す
/// 件数をそのまま載せる。DESCRIBE と SHOW CREATE TABLE は Hive のテーブル（と判定できないとき。`DESC` も）では
/// null、Iceberg のテーブルでは 0（2026-09-24 実測。#160）。EXPLAIN は 8 変種とも null（2026-09-16〜23 実測。#169）。
/// null になる文は `.txt` を application で置く文と同じ述語 `content_type::plain_text_statement` で選ぶ
/// （本物でも UpdateCount の有無と Content-Type は一致している）。
pub(super) fn update_count(
    query: &str,
    outcome: &Outcome,
    format_override: Option<FormatOverride>,
) -> Option<i64> {
    if let Some(count) = outcome.update_count {
        return Some(count);
    }
    if super::classification::statement_type(query) == "DDL" {
        return None;
    }
    let iceberg = matches!(
        format_override,
        Some(
            FormatOverride::ShowCreateTableIceberg
                | FormatOverride::DescribeIceberg
                | FormatOverride::DescribeView
        )
    );
    if crate::content_type::plain_text_statement(query) && !iceberg {
        return None;
    }
    Some(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn update_count_は件数が無ければ_ddl_以外で_0_になる() {
        let counted = Outcome {
            update_count: Some(3),
            ..Outcome::default()
        };
        assert_eq!(
            update_count("INSERT INTO t VALUES (1)", &counted, None),
            Some(3)
        );
        assert_eq!(
            update_count("CREATE TABLE c AS SELECT 1", &counted, None),
            Some(3)
        );

        let uncounted = Outcome::default();
        assert_eq!(update_count("SELECT 1", &uncounted, None), Some(0));
        assert_eq!(update_count("SHOW TABLES", &uncounted, None), Some(0));
        assert_eq!(
            update_count("CREATE TABLE t (i int)", &uncounted, None),
            None
        );
        assert_eq!(update_count("DROP TABLE t", &uncounted, None), None);
    }

    /// 2026-09-24 実測（#160）: Hive の DESCRIBE と SHOW CREATE TABLE は null、Iceberg なら 0。
    #[test]
    fn update_count_は_describe_と_hive_の_show_create_table_で省き_iceberg_なら_0() {
        let uncounted = Outcome::default();
        assert_eq!(update_count("DESCRIBE t", &uncounted, None), None);
        assert_eq!(update_count("DESC t", &uncounted, None), None);
        assert_eq!(
            update_count(
                "DESCRIBE t",
                &uncounted,
                Some(FormatOverride::DescribeIceberg)
            ),
            Some(0)
        );
        // ビューへの DESCRIBE も 0（2026-09-24 実測 d5。#173）。
        assert_eq!(
            update_count("DESCRIBE v", &uncounted, Some(FormatOverride::DescribeView)),
            Some(0)
        );
        assert_eq!(update_count("SHOW CREATE TABLE t", &uncounted, None), None);
        // EXPLAIN は DML 扱いだが、本物は 8 変種とも UpdateCount を返さない（2026-09-16〜23 実測。#169）。
        assert_eq!(update_count("EXPLAIN SELECT 1", &uncounted, None), None);
        assert_eq!(
            update_count("EXPLAIN ANALYZE VERBOSE SELECT 1", &uncounted, None),
            None
        );
        assert_eq!(
            update_count("EXPLAIN (TYPE VALIDATE) SELECT 1", &uncounted, None),
            None
        );
        assert_eq!(
            update_count(
                "SHOW CREATE TABLE t",
                &uncounted,
                Some(FormatOverride::ShowCreateTableIceberg)
            ),
            Some(0)
        );
    }

    fn plan(rows: Vec<Vec<serde_json::Value>>) -> Outcome {
        Outcome {
            rows,
            ..Outcome::default()
        }
    }

    #[test]
    fn explain_は全文の末尾に改行を足してから行に分ける() {
        let outcome = split_explain_rows(
            "EXPLAIN SELECT 1",
            plan(vec![vec![serde_json::Value::from(
                "Fragment 0\n    (1)\n\n",
            )]]),
        );
        assert_eq!(
            outcome.rows,
            [["Fragment 0"], ["    (1)"], [""], [""], [""]]
                .map(|row| row.map(serde_json::Value::from))
        );
    }

    #[test]
    fn explain_でない文と文字列でない値は分けない() {
        let select = split_explain_rows(
            "SELECT 'a\nb'",
            plan(vec![vec![serde_json::Value::from("a\nb")]]),
        );
        assert_eq!(select.rows, [[serde_json::Value::from("a\nb")]]);

        let null = split_explain_rows(
            "EXPLAIN SELECT 1",
            plan(vec![vec![serde_json::Value::Null]]),
        );
        assert_eq!(null.rows, [[serde_json::Value::Null]]);
    }

    #[test]
    fn explain_の真偽値の結果は文字列にしてから同じ規則で分ける() {
        // `EXPLAIN (TYPE VALIDATE)` の boolean の `true` も、本物は `true` + `\n` を分けた
        // `true`・空行の 2 行にする（2026-09-23 実測。#92）。
        let outcome = split_explain_rows(
            "EXPLAIN (TYPE VALIDATE) SELECT 1",
            plan(vec![vec![serde_json::Value::Bool(true)]]),
        );
        assert_eq!(
            outcome.rows,
            [["true"], [""]].map(|row| row.map(serde_json::Value::from))
        );
    }
}
