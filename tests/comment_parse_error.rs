//! 構文チェックの後の判定（本物の Hive のパーサがブロックコメントで返す ParseException を開始後の FAILED にする。
//! #244）。対象は SHOW CREATE TABLE・DESCRIBE・ALTER TABLE の RENAME TO・DROP COLUMN で、対象の表の形式
//! （Hive・Iceberg・ビュー・無い表）で本物が実際に失敗させるかが変わる。DESCRIBE の Hive 表・Iceberg 表は
//! tests/reported_query.rs にある（#242 の拡張）。ここでは DESC・先頭コメント・ビューを足す。

mod common;

use common::Harness;
use serde_json::{Value, json};

const DEFAULT_CATALOG: &str = "default_catalog";
const DEFAULT_SCHEMA: &str = "default_schema";

fn select_response() -> Value {
    json!({ "columns": [{ "name": "n", "type": "bigint" }], "data": [[1]] })
}

/// 形式と存在を 1 つにまとめた問い合わせ（`src/operation/table_format.rs` の `probe_sql` と同じ形。
/// tests/table_format.rs・tests/reported_query.rs の写し）。
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

/// 対象が存在しない（カタログはあるが `table_type` が null）応答（tests/table_format.rs の写し）。
fn probe_response_missing() -> Value {
    json!({
        "columns": [
            { "name": "_col0", "type": "varchar" },
            { "name": "_col1", "type": "varchar" }
        ],
        "data": [["hive", null]]
    })
}

/// カタログが無い（`_col0` が null）応答。
fn probe_response_no_catalog() -> Value {
    json!({
        "columns": [
            { "name": "_col0", "type": "varchar" },
            { "name": "_col1", "type": "varchar" }
        ],
        "data": [[null, null]]
    })
}

fn create_table_response() -> Value {
    json!({
        "columns": [{ "name": "Create Table", "type": "varchar" }],
        "data": [["CREATE TABLE t (id integer)"]]
    })
}

#[tokio::test]
async fn show_create_table_のブロックコメントは_hive_ビュー_無い表で本物どおり_failed_になる() {
    const REASON: &str = "FAILED: ParseException line 1:5 cannot recognize input near 'SHOW' '/' '*' in ddl statement";
    for (name, response) in [
        ("t", probe_response("hive", "TABLE")),
        ("v", probe_response("hive", "VIEW")),
        ("nope", probe_response_missing()),
    ] {
        let sql = format!("SHOW /* c */ CREATE TABLE {name}");
        let harness = Harness::builder(select_response())
            .route(&probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, name), response)
            .results_s3()
            .start()
            .await;

        let execution = harness
            .run_query(json!({
                "QueryString": sql,
                "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
            }))
            .await["QueryExecution"]
            .clone();
        let id = execution["QueryExecutionId"].as_str().expect("ID");

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
        assert_eq!(
            execution["Status"]["AthenaError"]["ErrorMessage"], REASON,
            "{name}"
        );
        assert_eq!(execution["StatementType"], "UTILITY", "{name}");
        assert_eq!(execution["SubstatementType"], "SHOW_CREATE_TABLE", "{name}");

        let puts: Vec<_> = harness
            .s3_puts()
            .into_iter()
            .filter(|put| put.key.contains(id))
            .collect();
        assert_eq!(puts.len(), 1, "{name}: .txt だけ置き .metadata は置かない");
        assert_eq!(puts[0].key, format!("athena/{id}.txt"));
        assert_eq!(puts[0].body, REASON.as_bytes());

        assert!(
            harness.trino_sqls().iter().all(|s| !s.starts_with("SHOW")),
            "{name}: Trino に SHOW の文を送らない: {:?}",
            harness.trino_sqls()
        );

        let (code, error) = harness
            .call("GetQueryResults", json!({ "QueryExecutionId": id }))
            .await;
        assert_eq!(code, 400, "{name}: {error}");
        assert_eq!(
            error["AthenaErrorCode"], "INVALID_QUERY_EXECUTION_STATE",
            "{name}"
        );
        assert_eq!(
            error["Message"], "Query did not finish successfully. Final query state: FAILED",
            "{name}"
        );
    }
}

#[tokio::test]
async fn show_create_table_のブロックコメントは_iceberg_表なら成功して_trino_に送る() {
    let sql = "SHOW /* c */ CREATE TABLE t";
    let harness = Harness::builder(select_response())
        .route(
            &probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, "t"),
            probe_response("iceberg", "TABLE"),
        )
        .route(sql, create_table_response())
        .start()
        .await;

    let execution =
        harness.run_query(json!({ "QueryString": sql })).await["QueryExecution"].clone();

    assert_eq!(execution["Status"]["State"], "SUCCEEDED", "{execution}");
    assert!(
        harness.trino_sqls().iter().any(|s| s == sql),
        "Iceberg 表なら Trino に送る: {:?}",
        harness.trino_sqls()
    );
}

#[tokio::test]
async fn show_create_table_のブロックコメントは先頭でも名前の直前でも_failed_になる() {
    for (sql, reason) in [
        (
            "/* c */ SHOW CREATE TABLE t",
            "FAILED: ParseException line 1:0 cannot recognize input near '/' '*' 'c'",
        ),
        (
            "SHOW CREATE TABLE /* c */ t",
            "FAILED: ParseException line 1:18 cannot recognize input near '/' '*' 'c' in table name",
        ),
    ] {
        let harness = Harness::builder(select_response())
            .route(
                &probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, "t"),
                probe_response("hive", "TABLE"),
            )
            .start()
            .await;

        let execution =
            harness.run_query(json!({ "QueryString": sql })).await["QueryExecution"].clone();

        assert_eq!(execution["Status"]["State"], "FAILED", "{sql}: {execution}");
        assert_eq!(execution["Status"]["StateChangeReason"], reason, "{sql}");
    }
}

/// DESCRIBE の Hive 表・Iceberg 表（先頭以外の形）は tests/reported_query.rs にある（#242 の拡張）。
/// ここでは DESC・先頭コメントを足す。
#[tokio::test]
async fn describe_のブロックコメントは_desc_でも先頭でも本物どおり_failed_になる() {
    for (sql, reason) in [
        (
            "DESC /* c */ t",
            "FAILED: ParseException line 1:0 cannot recognize input near 'DESC' '/' '*' in describe statement",
        ),
        (
            "/* c */ DESCRIBE t",
            "FAILED: ParseException line 1:0 cannot recognize input near '/' '*' 'c'",
        ),
    ] {
        let harness = Harness::builder(select_response())
            .route(
                &probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, "t"),
                probe_response("hive", "TABLE"),
            )
            .start()
            .await;

        let execution =
            harness.run_query(json!({ "QueryString": sql })).await["QueryExecution"].clone();

        assert_eq!(execution["Status"]["State"], "FAILED", "{sql}: {execution}");
        assert_eq!(execution["Status"]["StateChangeReason"], reason, "{sql}");
    }
}

#[tokio::test]
async fn describe_のブロックコメントはビューなら成功して_trino_に送る() {
    let sql = "DESCRIBE /* c */ v";
    let harness = Harness::builder(select_response())
        .route(
            &probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, "v"),
            probe_response("hive", "VIEW"),
        )
        .start()
        .await;

    let execution =
        harness.run_query(json!({ "QueryString": sql })).await["QueryExecution"].clone();

    assert_eq!(execution["Status"]["State"], "SUCCEEDED", "{execution}");
    assert!(
        harness.trino_sqls().iter().any(|s| s == sql),
        "ビューなら Trino に送る: {:?}",
        harness.trino_sqls()
    );
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

/// probe の `_col0` が null（カタログが無い）なら介入せず今までどおり送る。
#[tokio::test]
async fn probe_でカタログが無ければ介入せず今までどおり送る() {
    let sql = "SHOW /* c */ CREATE TABLE t";
    let harness = Harness::builder(select_response())
        .route(
            &probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, "t"),
            probe_response_no_catalog(),
        )
        .route(sql, create_table_response())
        .start()
        .await;

    let execution =
        harness.run_query(json!({ "QueryString": sql })).await["QueryExecution"].clone();

    assert_eq!(execution["Status"]["State"], "SUCCEEDED", "{execution}");
    assert!(
        harness.trino_sqls().iter().any(|s| s == sql),
        "介入せず Trino に送る: {:?}",
        harness.trino_sqls()
    );
}

// 構文チェックの前の判定（MSCK REPAIR TABLE・ALTER TABLE ... ADD COLUMNS は Trino に文が無く、構文チェックへ
// 進むと必ず 400 になるので、対象の存在を先に確かめる。#244）。

/// カタログの有無の問い合わせ（`src/operation/table_format.rs` の `catalog_exists_sql` と同じ形。
/// tests/context_catalog.rs の写し）。
fn catalog_exists_sql(catalog: &str) -> String {
    format!(
        "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = '{catalog}')"
    )
}

fn catalog_exists_response(connector_name: Option<&str>) -> Value {
    json!({
        "columns": [{ "name": "_col0", "type": "varchar" }],
        "data": [[connector_name]]
    })
}

#[tokio::test]
async fn msck_repair_table_のブロックコメントは_hive_無い表_ビューで本物どおり_failed_になり構文チェックへ進まない()
 {
    const REASON: &str = "FAILED: ParseException line 1:12 missing EOF at '/' near 'REPAIR'";
    for (name, response) in [
        ("t", probe_response("hive", "TABLE")),
        ("nope", probe_response_missing()),
        ("v", probe_response("hive", "VIEW")),
    ] {
        let sql = format!("MSCK REPAIR /* c */ TABLE {name}");
        let harness = Harness::builder(select_response())
            .route(&probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, name), response)
            .results_s3()
            .start()
            .await;

        let execution = harness
            .run_query(json!({
                "QueryString": sql,
                "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
            }))
            .await["QueryExecution"]
            .clone();
        let id = execution["QueryExecutionId"].as_str().expect("ID");

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
        assert_eq!(
            execution["Status"]["AthenaError"]["ErrorMessage"], REASON,
            "{name}"
        );
        assert_eq!(execution["StatementType"], "DDL", "{name}");
        assert_eq!(execution["SubstatementType"], "MSCK_REPAIR", "{name}");

        let puts: Vec<_> = harness
            .s3_puts()
            .into_iter()
            .filter(|put| put.key.contains(id))
            .collect();
        assert_eq!(puts.len(), 1, "{name}: .txt だけ置き .metadata は置かない");
        assert_eq!(puts[0].key, format!("athena/{id}.txt"));
        assert_eq!(puts[0].body, REASON.as_bytes());

        assert!(
            !harness.syntax_checks().contains(&sql),
            "{name}: 構文チェックへ進まない: {:?}",
            harness.syntax_checks()
        );
    }
}

#[tokio::test]
async fn msck_repair_table_は_iceberg_表ならコメントの有無によらず別の失敗になり_s3_に何も置かない()
{
    for sql in ["MSCK REPAIR TABLE t", "/* c */ MSCK REPAIR TABLE t"] {
        let harness = Harness::builder(select_response())
            .route(
                &probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, "t"),
                probe_response("iceberg", "TABLE"),
            )
            .results_s3()
            .start()
            .await;

        let execution = harness
            .run_query(json!({
                "QueryString": sql,
                "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
            }))
            .await["QueryExecution"]
            .clone();
        let id = execution["QueryExecutionId"].as_str().expect("ID");

        assert_eq!(execution["Status"]["State"], "FAILED", "{sql}: {execution}");
        assert_eq!(
            execution["Status"]["StateChangeReason"],
            "Query type not supported by Athena Iceberg at this time",
            "{sql}"
        );
        assert_eq!(
            execution["Status"]["AthenaError"]["ErrorCategory"], 2,
            "{sql}"
        );
        assert_eq!(
            execution["Status"]["AthenaError"]["ErrorType"], 1200,
            "{sql}"
        );
        assert_eq!(execution["StatementType"], "DDL", "{sql}");
        assert_eq!(execution["SubstatementType"], "MSCK_REPAIR", "{sql}");

        let puts: Vec<_> = harness
            .s3_puts()
            .into_iter()
            .filter(|put| put.key.contains(id))
            .collect();
        assert!(puts.is_empty(), "{sql}: S3 に何も置かない: {puts:?}");

        assert!(
            !harness.syntax_checks().contains(&sql.to_string()),
            "{sql}: 構文チェックへ進まない"
        );
    }
}

#[tokio::test]
async fn msck_repair_table_は_hive_でコメントが無ければ今までどおり構文チェックへ進む() {
    let sql = "MSCK REPAIR TABLE t";
    let harness = Harness::builder(select_response())
        .route(
            &probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, "t"),
            probe_response("hive", "TABLE"),
        )
        .start()
        .await;

    harness
        .call("StartQueryExecution", json!({ "QueryString": sql }))
        .await;

    assert!(
        harness.syntax_checks().contains(&sql.to_string()),
        "コメントが無ければ構文チェックへ進む: {:?}",
        harness.syntax_checks()
    );
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

#[tokio::test]
async fn msck_repair_table_は_context_のカタログが実在しなければ既定のカタログで解決する() {
    let sql = "MSCK REPAIR TABLE t";
    let harness = Harness::builder(select_response())
        .catalog_map(&[("AwsDataCatalog", "hive")])
        .route(
            &catalog_exists_sql("nosuchcat"),
            catalog_exists_response(None),
        )
        .route(
            &probe_sql("hive", DEFAULT_SCHEMA, "t"),
            probe_response("iceberg", "TABLE"),
        )
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": sql,
            "QueryExecutionContext": { "Catalog": "nosuchcat" },
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await["QueryExecution"]
        .clone();

    assert_eq!(execution["Status"]["State"], "FAILED", "{execution}");
    assert_eq!(
        execution["Status"]["StateChangeReason"],
        "Query type not supported by Athena Iceberg at this time"
    );
}
