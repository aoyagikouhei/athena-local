//! GetWorkGroup と、StartQueryExecution/GetQueryExecution への WorkGroup の受け渡し。
//! Configuration の値は 2026-09-17 に本番 Athena で実測したもの（EnableMinimumEncryptionConfiguration は 2026-09-23 実測）。

mod common;

use common::Harness;
use serde_json::{Value, json};

fn empty_response() -> Value {
    json!({ "columns": [], "data": [] })
}

fn select_response() -> Value {
    json!({
        "columns": [{ "name": "n", "type": "bigint" }],
        "data": [[1]]
    })
}

/// 名前によらず共通の Configuration（実測値）。
fn configuration() -> Value {
    json!({
        "EnableMinimumEncryptionConfiguration": false,
        "EnforceWorkGroupConfiguration": false,
        "PublishCloudWatchMetricsEnabled": false,
        "RequesterPaysEnabled": false,
        "ResultConfiguration": {},
        "EngineVersion": {
            "SelectedEngineVersion": "AUTO",
            "EffectiveEngineVersion": "Athena engine version 3"
        }
    })
}

#[tokio::test]
async fn primary_の設定を返す() {
    let harness = Harness::start(empty_response()).await;

    let (status, body) = harness
        .call("GetWorkGroup", json!({ "WorkGroup": "primary" }))
        .await;

    assert_eq!(status, 200);
    assert_eq!(body["WorkGroup"]["Name"], "primary");
    assert_eq!(body["WorkGroup"]["State"], "ENABLED");
    assert_eq!(body["WorkGroup"]["Configuration"], configuration());
}

#[tokio::test]
async fn 任意の名前でも同じ設定を返す_本物と違い名前でエラーにしない() {
    let harness = Harness::start(empty_response()).await;

    let (status, body) = harness
        .call("GetWorkGroup", json!({ "WorkGroup": "no-such-workgroup" }))
        .await;

    assert_eq!(status, 200);
    assert_eq!(body["WorkGroup"]["Name"], "no-such-workgroup");
    assert_eq!(body["WorkGroup"]["Configuration"], configuration());
}

#[tokio::test]
async fn output_location_が設定されていれば反映する() {
    let harness = Harness::builder(empty_response())
        .results_s3()
        .default_output_location("s3://results-bucket/athena/")
        .start()
        .await;

    let (status, body) = harness
        .call("GetWorkGroup", json!({ "WorkGroup": "primary" }))
        .await;

    assert_eq!(status, 200);
    assert_eq!(
        body["WorkGroup"]["Configuration"]["ResultConfiguration"]["OutputLocation"],
        "s3://results-bucket/athena/"
    );
}

#[tokio::test]
async fn output_location_が無ければ_result_configuration_は空になる() {
    // S3 を使わない構成。
    let without_s3 = Harness::start(empty_response()).await;
    let (_, body) = without_s3
        .call("GetWorkGroup", json!({ "WorkGroup": "primary" }))
        .await;
    assert_eq!(
        body["WorkGroup"]["Configuration"]["ResultConfiguration"],
        json!({}),
        "キーが消えると Null になり食い違う"
    );

    // S3 は使うが既定の OutputLocation が無い構成。
    let with_s3_no_default = Harness::builder(empty_response())
        .results_s3()
        .start()
        .await;
    let (_, body) = with_s3_no_default
        .call("GetWorkGroup", json!({ "WorkGroup": "primary" }))
        .await;
    assert_eq!(
        body["WorkGroup"]["Configuration"]["ResultConfiguration"],
        json!({}),
        "キーが消えると Null になり食い違う"
    );
}

#[tokio::test]
async fn trino_には一切問い合わせない() {
    let harness = Harness::start(empty_response()).await;

    harness
        .call("GetWorkGroup", json!({ "WorkGroup": "primary" }))
        .await;

    assert!(harness.trino_requests().is_empty());
}

#[tokio::test]
async fn start_query_execution_で指定した_work_group_を_get_query_execution_が返す() {
    let harness = Harness::start(select_response()).await;

    let execution = harness
        .run_query(json!({ "QueryString": "SELECT 1", "WorkGroup": "etl" }))
        .await;

    assert_eq!(execution["QueryExecution"]["WorkGroup"], "etl");
}

#[tokio::test]
async fn work_group_を省くと_primary_になる() {
    let harness = Harness::start(select_response()).await;

    let execution = harness
        .run_query(json!({ "QueryString": "SELECT 1" }))
        .await;

    assert_eq!(execution["QueryExecution"]["WorkGroup"], "primary");
}
