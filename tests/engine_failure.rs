//! エンジン（Trino）で失敗した CTAS・INSERT の理由に、本物は結果の置き場所を示す文を付けた（CTAS は
//! `You may need to manually clean the data at location '<OutputLocation>tables/<id>' ...`、INSERT は
//! `If a data manifest file was generated at '<OutputLocation><id>-manifest.csv', ...`。2026-09-27 実測 p・w・t・f・i 群。#272）。
//! エンジンの文言が `.` で終わらなければ `.` を足してから付ける。SELECT などほかの文には付けない。

mod common;

use common::{Harness, trino_error};
use serde_json::{Value, json};

fn select_response() -> Value {
    json!({ "columns": [{ "name": "n", "type": "integer" }], "data": [[1]] })
}

const OUTPUT: &str = "s3://results-bucket/athena/";

async fn failed(harness: &Harness, query: &str, context: Value) -> (Value, String) {
    let execution = harness
        .run_query(json!({
            "QueryString": query,
            "QueryExecutionContext": context,
            "ResultConfiguration": { "OutputLocation": OUTPUT }
        }))
        .await;
    let execution = &execution["QueryExecution"];
    assert_eq!(
        execution["Status"]["State"], "FAILED",
        "{query}: {execution}"
    );
    let id = execution["QueryExecutionId"].as_str().unwrap().to_string();
    (execution["Status"].clone(), id)
}

fn ctas_suffix(id: &str) -> String {
    format!(
        ". You may need to manually clean the data at location '{OUTPUT}tables/{id}' before retrying. \
         Athena will not delete data in your account."
    )
}

/// 既定の Context と S3 Tables の Context の CTAS（本体を Trino に送る経路）。StateChangeReason と ErrorMessage は同じ文字列。
#[tokio::test]
async fn エンジンで失敗した_ctas_の理由に置き場所の接尾辞を付ける() {
    for (query, context) in [
        (
            "CREATE TABLE db.t AS SELECT * FROM db.nosuch",
            json!({ "Catalog": "AwsDataCatalog", "Database": "db" }),
        ),
        (
            "CREATE TABLE ns.t AS SELECT * FROM ns.nosuch",
            json!({ "Catalog": "s3tablescatalog/b", "Database": "ns" }),
        ),
    ] {
        let message = "line 1:36: Table 'x.nosuch' does not exist";
        let harness = Harness::builder(select_response())
            .catalog_map(&[("AwsDataCatalog", "hive"), ("s3tablescatalog/b", "iceberg")])
            .route(query, trino_error("TABLE_NOT_FOUND", message))
            .results_s3()
            .start()
            .await;

        let (status, id) = failed(&harness, query, context).await;
        let reason = format!("TABLE_NOT_FOUND: {message}{}", ctas_suffix(&id));
        assert_eq!(status["StateChangeReason"], reason, "{query}");
        assert_eq!(status["AthenaError"]["ErrorMessage"], reason, "{query}");
        assert_eq!(status["AthenaError"]["ErrorType"], 1301, "{query}");
    }
}

#[tokio::test]
async fn エンジンで失敗した_insert_の理由に_manifest_の接尾辞を付ける() {
    let query = "INSERT INTO db.t SELECT nosuch FROM db.src";
    let message = "line 1:25: Column 'nosuch' cannot be resolved";
    let harness = Harness::builder(select_response())
        .route(query, trino_error("COLUMN_NOT_FOUND", message))
        .results_s3()
        .start()
        .await;

    let (status, id) = failed(&harness, query, json!({ "Database": "db" })).await;
    assert_eq!(
        status["StateChangeReason"],
        format!(
            "COLUMN_NOT_FOUND: {message}. If a data manifest file was generated at '{OUTPUT}{id}-manifest.csv', \
             you may need to manually clean the data from locations specified in the manifest. \
             Athena will not delete data in your account."
        )
    );
}

/// SELECT の失敗には付けない（本物の SELECT の失敗の理由は Trino の文言のまま）。
#[tokio::test]
async fn エンジンで失敗した_select_の理由には接尾辞を付けない() {
    let query = "SELECT * FROM db.nosuch";
    let message = "line 1:15: Table 'x.nosuch' does not exist";
    let harness = Harness::builder(select_response())
        .route(query, trino_error("TABLE_NOT_FOUND", message))
        .results_s3()
        .start()
        .await;

    let (status, _) = failed(&harness, query, json!({ "Database": "db" })).await;
    assert_eq!(
        status["StateChangeReason"],
        format!("TABLE_NOT_FOUND: {message}")
    );
}
