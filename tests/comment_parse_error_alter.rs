//! 構文チェックの後・前の判定（本物の Hive のパーサがブロックコメントで返す ParseException を FAILED にする。
//! #244）のうち、ALTER TABLE（ADD COLUMNS・DROP COLUMN・RENAME TO）の結合テスト。`tests/comment_parse_error.rs`
//! から切り出したもの（挙動を変えない移動。#257）。

mod common;

use common::Harness;
use serde_json::{Value, json};

const DEFAULT_CATALOG: &str = "default_catalog";
const DEFAULT_SCHEMA: &str = "default_schema";

fn select_response() -> Value {
    json!({ "columns": [{ "name": "n", "type": "bigint" }], "data": [[1]] })
}

/// 形式と存在を 1 つにまとめた問い合わせ（`src/operation/table_format.rs` の `probe_sql` と同じ形。
/// tests/comment_parse_error.rs の写し。#257 フェーズ 0 の一致台帳）。
fn probe_sql(catalog: &str, schema: &str, table: &str) -> String {
    format!(
        "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = '{catalog}'), (SELECT table_type FROM system.jdbc.tables WHERE table_cat = '{catalog}' AND table_schem = '{schema}' AND table_name = '{table}')"
    )
}

fn probe_response(connector_name: &str, table_type: &str) -> Value {
    json!({
        "columns": [
            { "name": "_col0", "type": "varchar" },
            { "name": "_col1", "type": "varchar" }
        ],
        "data": [[connector_name, table_type]]
    })
}

/// 対象が存在しない（カタログはあるが `table_type` が null）応答（tests/comment_parse_error.rs の写し）。
fn probe_response_missing() -> Value {
    json!({
        "columns": [
            { "name": "_col0", "type": "varchar" },
            { "name": "_col1", "type": "varchar" }
        ],
        "data": [["hive", null]]
    })
}

#[tokio::test]
async fn alter_table_rename_to_のブロックコメントは_hive_無い表で本物どおり_failed_になる() {
    const REASON: &str = "FAILED: ParseException line 1:0 cannot recognize input near 'ALTER' '/' '*' in alter statement";
    const MESSAGE: &str = "Query type not supported by DDL engine.";
    for (name, response) in [
        ("t", probe_response("hive", "TABLE")),
        ("nope", probe_response_missing()),
    ] {
        let sql = format!("ALTER /* c */ TABLE {name} RENAME TO u");
        let harness = Harness::builder(select_response())
            .route(&probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, name), response)
            .start()
            .await;

        let execution =
            harness.run_query(json!({ "QueryString": sql })).await["QueryExecution"].clone();

        assert_eq!(
            execution["Status"]["State"], "FAILED",
            "{name}: {execution}"
        );
        assert_eq!(execution["Status"]["StateChangeReason"], REASON, "{name}");
        assert_eq!(
            execution["Status"]["AthenaError"]["ErrorCategory"], 2,
            "{name}"
        );
        assert_eq!(
            execution["Status"]["AthenaError"]["ErrorType"], 1006,
            "{name}"
        );
        assert_eq!(
            execution["Status"]["AthenaError"]["ErrorMessage"], MESSAGE,
            "{name}"
        );
        assert!(
            harness.trino_sqls().iter().all(|s| !s.starts_with("ALTER")),
            "{name}: Trino に ALTER の文を送らない"
        );
    }
}

#[tokio::test]
async fn alter_table_drop_column_のブロックコメントは_hive_なら本物どおり_failed_になる() {
    let sql = "ALTER /* c */ TABLE t DROP COLUMN n";
    let harness = Harness::builder(select_response())
        .route(
            &probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, "t"),
            probe_response("hive", "TABLE"),
        )
        .start()
        .await;

    let execution =
        harness.run_query(json!({ "QueryString": sql })).await["QueryExecution"].clone();

    assert_eq!(execution["Status"]["State"], "FAILED", "{execution}");
    assert_eq!(
        execution["Status"]["StateChangeReason"],
        "FAILED: ParseException line 1:0 cannot recognize input near 'ALTER' '/' '*' in alter statement"
    );
    assert_eq!(execution["Status"]["AthenaError"]["ErrorCategory"], 2);
    assert_eq!(execution["Status"]["AthenaError"]["ErrorType"], 1006);
    assert_eq!(
        execution["Status"]["AthenaError"]["ErrorMessage"],
        "line 1:28: mismatched input 'COLUMN' expecting 'PARTITION'"
    );
}

#[tokio::test]
async fn alter_table_のブロックコメントは_iceberg_表なら成功して_trino_に送る() {
    for sql in [
        "ALTER /* c */ TABLE t RENAME TO u",
        "ALTER /* c */ TABLE t DROP COLUMN n",
    ] {
        let harness = Harness::builder(select_response())
            .route(
                &probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, "t"),
                probe_response("iceberg", "TABLE"),
            )
            .start()
            .await;

        let execution =
            harness.run_query(json!({ "QueryString": sql })).await["QueryExecution"].clone();

        assert_eq!(
            execution["Status"]["State"], "SUCCEEDED",
            "{sql}: {execution}"
        );
        assert!(
            harness.trino_sqls().iter().any(|s| s == sql),
            "{sql}: Iceberg 表なら Trino に送る"
        );
    }
}

#[tokio::test]
async fn alter_table_add_columns_複数形_のブロックコメントは_hive_無い表で本物どおり_failed_になり構文チェックへ進まない()
 {
    const REASON: &str = "FAILED: ParseException line 1:0 cannot recognize input near 'ALTER' '/' '*' in alter statement";
    for (name, response) in [
        ("t", probe_response("hive", "TABLE")),
        ("nope", probe_response_missing()),
    ] {
        let sql = format!("ALTER /* c */ TABLE {name} ADD COLUMNS (c int)");
        let harness = Harness::builder(select_response())
            .route(&probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, name), response)
            .start()
            .await;

        let execution =
            harness.run_query(json!({ "QueryString": sql })).await["QueryExecution"].clone();

        assert_eq!(
            execution["Status"]["State"], "FAILED",
            "{name}: {execution}"
        );
        assert_eq!(execution["Status"]["StateChangeReason"], REASON, "{name}");
        assert_eq!(
            execution["Status"]["AthenaError"]["ErrorCategory"], 1,
            "{name}"
        );
        assert_eq!(
            execution["Status"]["AthenaError"]["ErrorType"], 1003,
            "{name}"
        );
        assert_eq!(execution["StatementType"], "DDL", "{name}");
        assert_eq!(
            execution["SubstatementType"], "ALTER_TABLE_ADD_COLUMN",
            "{name}"
        );

        assert!(
            !harness.syntax_checks().contains(&sql),
            "{name}: 構文チェックへ進まない: {:?}",
            harness.syntax_checks()
        );
    }
}

#[tokio::test]
async fn alter_table_add_columns_複数形_は_iceberg_表なら今までどおり構文チェックへ進む() {
    let sql = "ALTER /* c */ TABLE t ADD COLUMNS (c int)";
    let harness = Harness::builder(select_response())
        .route(
            &probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, "t"),
            probe_response("iceberg", "TABLE"),
        )
        .start()
        .await;

    harness
        .call("StartQueryExecution", json!({ "QueryString": sql }))
        .await;

    assert!(
        harness.syntax_checks().contains(&sql.to_string()),
        "Iceberg 表なら構文チェックへ進む: {:?}",
        harness.syntax_checks()
    );
}

#[tokio::test]
async fn alter_table_add_columns_複数形_はコメントが無ければ_probe_を投げずに構文チェックへ進む() {
    let sql = "ALTER TABLE t ADD COLUMNS (c int)";
    let harness = Harness::builder(select_response()).start().await;

    harness
        .call("StartQueryExecution", json!({ "QueryString": sql }))
        .await;

    assert!(
        harness.syntax_checks().contains(&sql.to_string()),
        "コメントが無ければ構文チェックへ進む: {:?}",
        harness.syntax_checks()
    );
    // 実行そのもの（今までどおり Trino に送る文）は数に入れない。probe（存在の確認）だけ送っていないことを見る。
    assert!(
        !harness
            .trino_sqls()
            .contains(&probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, "t")),
        "コメントが無ければ probe を投げない: {:?}",
        harness.trino_sqls()
    );
}

/// 本物は ALTER TABLE の名前の 1 部目の `awsdatacatalog.` を Context のカタログとして落とす（2026-09-26 実測 m33。
/// #242）。構文チェックの前の判定も、落とした後の名前（`db.t`）で表を確かめる。落とさずに `awsdatacatalog` を
/// Trino のカタログとして引くと、カタログが無いと判定して今までどおり構文エラーになってしまう（#244 の最終パス）。
#[tokio::test]
async fn alter_table_add_columns_複数形_のブロックコメントは名前の_awsdatacatalog_を落として表を確かめる()
 {
    let sql = "ALTER /* c */ TABLE awsdatacatalog.db.t ADD COLUMNS (c int)";
    let harness = Harness::builder(select_response())
        .catalog_map(&[("AwsDataCatalog", "hive")])
        .route(
            &probe_sql("hive", "db", "t"),
            probe_response("hive", "TABLE"),
        )
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": sql,
            "QueryExecutionContext": { "Catalog": "AwsDataCatalog", "Database": "other" }
        }))
        .await["QueryExecution"]
        .clone();

    assert_eq!(execution["Status"]["State"], "FAILED", "{execution}");
    assert_eq!(
        execution["Status"]["StateChangeReason"],
        "FAILED: ParseException line 1:0 cannot recognize input near 'ALTER' '/' '*' in alter statement"
    );
    assert!(
        !harness.syntax_checks().contains(&sql.to_string()),
        "構文チェックへ進まない: {:?}",
        harness.syntax_checks()
    );
}
