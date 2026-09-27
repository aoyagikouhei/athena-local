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
/// 送った文の位置は同じ `line 1:36`（`db.t`・`ns.t` は同じ文字数なので、2 つのクエリで揃う）だが、本物は既定の
/// Context の CTAS だけ、整形し直した文の位置（`line 6:3`）で返した（p1。S3 Tables の名前空間への 2 部の名前は
/// 対象外で送った文の位置のまま。2026-09-27 実測。#272 フェーズ 2）。
#[tokio::test]
async fn エンジンで失敗した_ctas_の理由に置き場所の接尾辞を付ける() {
    let sent_message = "line 1:36: Table 'x.nosuch' does not exist";
    for (query, context, expected_message) in [
        (
            "CREATE TABLE db.t AS SELECT * FROM db.nosuch",
            json!({ "Catalog": "AwsDataCatalog", "Database": "db" }),
            "line 6:3: Table 'x.nosuch' does not exist",
        ),
        (
            "CREATE TABLE ns.t AS SELECT * FROM ns.nosuch",
            json!({ "Catalog": "s3tablescatalog/b", "Database": "ns" }),
            sent_message,
        ),
    ] {
        let harness = Harness::builder(select_response())
            .catalog_map(&[("AwsDataCatalog", "hive"), ("s3tablescatalog/b", "iceberg")])
            .route(query, trino_error("TABLE_NOT_FOUND", sent_message))
            .results_s3()
            .start()
            .await;

        let (status, id) = failed(&harness, query, context).await;
        let reason = format!("TABLE_NOT_FOUND: {expected_message}{}", ctas_suffix(&id));
        assert_eq!(status["StateChangeReason"], reason, "{query}");
        assert_eq!(status["AthenaError"]["ErrorMessage"], reason, "{query}");
        assert_eq!(status["AthenaError"]["ErrorType"], 1301, "{query}");
    }
}

/// S3 Tables の Context の `awsdatacatalog.<DB>.<表>` の CTAS（DB がある）は、開始時に 1 部目を AwsDataCatalog の
/// Trino 名に差し替えて送る（#232）。本物はこの形も整形し直した位置で返した（2026-09-27 実測 #251 の t3）ので、
/// 差し替えた文ではなく受け取った文の名前の形で対象を決め、位置を直す。
#[tokio::test]
async fn s3_tables_の_context_の_awsdatacatalog_の_ctas_も整形後の位置にする() {
    let query = "CREATE TABLE awsdatacatalog.db.t AS SELECT * FROM db.nosuch";
    let sent = r#"CREATE TABLE "hive"        .db.t AS SELECT * FROM db.nosuch"#;
    let harness = Harness::builder(select_response())
        .catalog_map(&[("AwsDataCatalog", "hive"), ("s3tablescatalog/b", "iceberg")])
        .route(
            r#"SHOW TABLES FROM "hive"."db" LIKE ''"#,
            json!({ "columns": [{ "name": "Table", "type": "varchar" }], "data": [] }),
        )
        .route(
            sent,
            trino_error(
                "TABLE_NOT_FOUND",
                "line 1:51: Table 'hive.db.nosuch' does not exist",
            ),
        )
        .results_s3()
        .start()
        .await;

    let (status, id) = failed(
        &harness,
        query,
        json!({ "Catalog": "s3tablescatalog/b", "Database": "ns" }),
    )
    .await;
    assert_eq!(
        status["StateChangeReason"],
        format!(
            "TABLE_NOT_FOUND: line 6:3: Table 'hive.db.nosuch' does not exist{}",
            ctas_suffix(&id)
        )
    );
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
