//! 終端状態の実行情報が保持期限で捨てられ、捨てた後は未知の ID と同じ応答になることを確認する。
//! 期限を短くしたテストでは run_query を使わない（400 の本文を終わった実行として返してしまう）。

mod common;

use std::time::Duration;

use common::{Harness, wait_for};
use serde_json::{Value, json};

fn select_response() -> Value {
    json!({ "columns": [{ "name": "n", "type": "bigint" }], "data": [[1]] })
}

/// 期限切れで GetQueryExecution が 400 になるまで待ち、その本文を返す。
/// GetQueryExecution を叩くこと自体が Store のロック → 掃除を駆動する（定期タスクは無い）。
async fn wait_until_gone(harness: &Harness, id: &str) -> Value {
    for _ in 0..100 {
        let (status, body) = harness
            .call("GetQueryExecution", json!({ "QueryExecutionId": id }))
            .await;
        if status == 400 {
            return body;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("保持期限を過ぎても消えない");
}

/// テストごとに別の値にする 32 文字以上の固定トークン。
fn token(name: &str) -> String {
    format!("token-{name}-0123456789abcdef0123456789")
}

#[tokio::test]
async fn 終わったクエリは保持期限を過ぎると知らない_id_と同じ_400_になる() {
    let harness = Harness::builder(select_response())
        .retention(Duration::from_millis(200))
        .start()
        .await;
    let id = harness
        .start_query(json!({ "QueryString": "SELECT n FROM t" }))
        .await;

    let error = wait_until_gone(&harness, &id).await;

    let mut keys: Vec<&str> = error
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    keys.sort();
    assert_eq!(keys, ["AthenaErrorCode", "ErrorCode", "Message", "__type"]);
    assert_eq!(error["__type"], "InvalidRequestException");
    assert_eq!(error["ErrorCode"], error["AthenaErrorCode"]);
    assert_eq!(error["AthenaErrorCode"], "QUERY_EXECUTION_NOT_FOUND");
    assert_eq!(
        error["Message"],
        format!("QueryExecution {id} was not found")
    );

    let (status, error) = harness
        .call("GetQueryResults", json!({ "QueryExecutionId": id }))
        .await;
    assert_eq!(status, 400);
    assert_eq!(error["AthenaErrorCode"], "QUERY_EXECUTION_NOT_FOUND");

    // 終わったクエリへの StopQueryExecution は 200 だが、捨てた後は 400 に変わる。
    let (status, error) = harness
        .call("StopQueryExecution", json!({ "QueryExecutionId": id }))
        .await;
    assert_eq!(status, 400);
    assert_eq!(error["AthenaErrorCode"], "QUERY_EXECUTION_NOT_FOUND");
}

#[tokio::test]
async fn 実行中のクエリは保持期限を過ぎても消えない() {
    let harness = Harness::builder(json!({ "columns": [{ "name": "n", "type": "bigint" }] }))
        .retention(Duration::from_millis(200))
        .endless()
        .start()
        .await;
    let id = harness
        .start_query(json!({ "QueryString": "SELECT count(*) FROM big" }))
        .await;
    wait_for("nextUri を辿り始める", || {
        !harness.trino_calls().is_empty()
    })
    .await;

    tokio::time::sleep(Duration::from_millis(500)).await;

    let (status, execution) = harness
        .call("GetQueryExecution", json!({ "QueryExecutionId": id }))
        .await;
    assert_eq!(status, 200);
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "RUNNING");

    let (status, _) = harness
        .call("StopQueryExecution", json!({ "QueryExecutionId": id }))
        .await;
    assert_eq!(status, 200);
}

#[tokio::test]
async fn 保持期限を過ぎたあとに同じトークンを再送すると新しい_id_になる() {
    let harness = Harness::builder(select_response())
        .retention(Duration::from_millis(200))
        .start()
        .await;
    let body = json!({
        "QueryString": "SELECT 1",
        "ClientRequestToken": token("expired"),
    });

    let id = harness.start_query(body.clone()).await;
    wait_until_gone(&harness, &id).await;

    let (status, started) = harness.call("StartQueryExecution", body).await;
    assert_eq!(status, 200);
    assert_ne!(started["QueryExecutionId"], Value::String(id));
}
