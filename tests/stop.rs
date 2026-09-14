//! StopQueryExecution と、結果が無いときの GetQueryResults のエラー。
//! 文言と AthenaErrorCode は 2026-09-14 に本番 Athena で実測したもの。

mod common;

use std::time::Duration;

use common::{Harness, wait_for};
use serde_json::{Value, json};

fn first_page() -> Value {
    json!({ "columns": [{ "name": "n", "type": "bigint" }] })
}

fn has_call(harness: &Harness, call: &str) -> bool {
    harness.trino_calls().iter().any(|c| c == call)
}

async fn stop(harness: &Harness, id: &str) -> (u16, Value) {
    harness
        .call("StopQueryExecution", json!({ "QueryExecutionId": id }))
        .await
}

#[tokio::test]
async fn 実行中に止めるとすぐ_cancelled_になり_trino_に_delete_が届く() {
    let harness = Harness::builder(first_page()).endless().start().await;
    let id = harness
        .start_query(json!({ "QueryString": "SELECT count(*) FROM big" }))
        .await;
    wait_for("nextUri を辿り始める", || {
        has_call(&harness, "GET /next")
    })
    .await;

    let (code, body) = stop(&harness, &id).await;
    assert_eq!(code, 200);
    assert_eq!(body, json!({}));

    // ポーリングせずに見る。状態は StopQueryExecution の中で書かれている。
    let status = harness.status(&id).await;
    assert_eq!(status["State"], "CANCELLED");
    assert_eq!(status["StateChangeReason"], "Query cancelled by user");
    assert!(status.get("CompletionDateTime").is_some());
    assert!(
        status.get("AthenaError").is_none(),
        "本物も CANCELLED には付けない"
    );

    wait_for("Trino に DELETE が届く", || {
        has_call(&harness, "DELETE /next")
    })
    .await;

    // DELETE を送ったあとは nextUri を辿らない。
    let calls = harness.trino_calls().len();
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(harness.trino_calls().len(), calls);
    assert_eq!(
        harness.trino_calls().last().map(String::as_str),
        Some("DELETE /next")
    );

    // もう一度止めても成功で、何も変わらない。
    let (code, _) = stop(&harness, &id).await;
    assert_eq!(code, 200);
    assert_eq!(harness.status(&id).await["State"], "CANCELLED");
}

#[tokio::test]
async fn 最初の応答を待っている間に止めても_応答が来たら_delete_を送り続きは辿らない() {
    let harness = Harness::builder(first_page())
        .endless()
        .statement_delay(Duration::from_millis(300))
        .start()
        .await;
    let id = harness
        .start_query(json!({ "QueryString": "SELECT count(*) FROM big" }))
        .await;
    wait_for("Trino がクエリを受ける", || {
        harness.trino_requests().len() == 1
    })
    .await;

    let (code, _) = stop(&harness, &id).await;
    assert_eq!(code, 200);
    assert_eq!(harness.status(&id).await["State"], "CANCELLED");

    wait_for("Trino に DELETE が届く", || {
        has_call(&harness, "DELETE /next")
    })
    .await;
    assert_eq!(harness.trino_calls(), ["DELETE /next"]);
}

#[tokio::test]
async fn 終わったクエリを止めても_200_で状態も結果も変わらない() {
    let harness = Harness::start(json!({
        "columns": [{ "name": "n", "type": "bigint" }],
        "data": [[1]]
    }))
    .await;
    let execution = harness
        .run_query(json!({ "QueryString": "SELECT n FROM t" }))
        .await;
    let id = common::execution_id(&execution);

    let (code, body) = stop(&harness, &id).await;
    assert_eq!(code, 200);
    assert_eq!(body, json!({}));

    assert_eq!(harness.status(&id).await["State"], "SUCCEEDED");
    let (code, _) = harness
        .call("GetQueryResults", json!({ "QueryExecutionId": id }))
        .await;
    assert_eq!(code, 200);
    assert!(harness.trino_calls().is_empty(), "DELETE は送らない");
}

#[tokio::test]
async fn 知らない_id_は止められない() {
    let harness = Harness::start(first_page()).await;

    let (code, error) = stop(&harness, "no-such-id").await;

    assert_eq!(code, 400);
    assert_eq!(error["__type"], "InvalidRequestException");
    assert_eq!(error["message"], "QueryExecution no-such-id was not found");
    assert_eq!(error["AthenaErrorCode"], "QUERY_EXECUTION_NOT_FOUND");
}

#[tokio::test]
async fn 結果取得のエラーは実行中と止めたあとで文言が変わる() {
    let harness = Harness::builder(first_page()).endless().start().await;
    let id = harness
        .start_query(json!({ "QueryString": "SELECT count(*) FROM big" }))
        .await;
    wait_for("nextUri を辿り始める", || {
        has_call(&harness, "GET /next")
    })
    .await;

    let (code, running) = harness
        .call("GetQueryResults", json!({ "QueryExecutionId": id }))
        .await;
    assert_eq!(code, 400);
    assert_eq!(
        running["message"],
        "Query has not yet finished. Current state: RUNNING"
    );
    assert_eq!(running["AthenaErrorCode"], "INVALID_QUERY_EXECUTION_STATE");

    stop(&harness, &id).await;

    let (code, cancelled) = harness
        .call("GetQueryResults", json!({ "QueryExecutionId": id }))
        .await;
    assert_eq!(code, 400);
    assert_eq!(cancelled["__type"], "InvalidRequestException");
    assert_eq!(cancelled["message"], "Could not find results");
    assert_eq!(cancelled["AthenaErrorCode"], "RESULT_NOT_FOUND");
}

#[tokio::test]
async fn 失敗したクエリの結果取得は最終状態を返し理由は載せない() {
    let harness = Harness::start(common::trino_error(
        "TABLE_NOT_FOUND",
        "line 1:15: Table 'no_such' does not exist",
    ))
    .await;
    let execution = harness
        .run_query(json!({ "QueryString": "SELECT * FROM no_such" }))
        .await;

    let (code, error) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": common::execution_id(&execution) }),
        )
        .await;

    assert_eq!(code, 400);
    assert_eq!(
        error["message"],
        "Query did not finish successfully. Final query state: FAILED"
    );
    assert_eq!(error["AthenaErrorCode"], "INVALID_QUERY_EXECUTION_STATE");
}
