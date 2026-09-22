//! 終端状態の実行情報が保持期限で捨てられ、捨てた後は未知の ID と同じ応答になることを確認する。
//! 期限を短くしたテストでは run_query を使わない（400 の本文を終わった実行として返してしまう）。

mod common;

use std::time::{Duration, Instant};

use common::{Harness, wait_for};
use serde_json::{Value, json};

fn select_response() -> Value {
    json!({ "columns": [{ "name": "n", "type": "bigint" }], "data": [[1]] })
}

/// 期限切れを待ち切る上限。回数ではなく経過時間で諦める。
/// 負荷でバックグラウンドの実行が遅れても待ち切るための上限で、成功時には使い切らない（#61）。
const GONE_DEADLINE: Duration = Duration::from_secs(30);

/// 期限切れで GetQueryExecution が 400 になるまで待ち、その本文を返す。
/// GetQueryExecution を叩くこと自体が Store のロック → 掃除を駆動する（定期タスクは無い）。
/// 諦めるときは、次に落ちたときに原因を切り分けられるよう、待った時間と最後の応答を添える。
async fn wait_until_gone(harness: &Harness, id: &str) -> Value {
    let started = Instant::now();
    loop {
        let (status, body) = harness
            .call("GetQueryExecution", json!({ "QueryExecutionId": id }))
            .await;
        if status == 400 {
            return body;
        }
        let elapsed = started.elapsed();
        if elapsed >= GONE_DEADLINE {
            panic!("保持期限を過ぎても消えない（{elapsed:?} 待った。最後の応答: {status} {body}）");
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
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

#[tokio::test]
async fn 実行の完了が遅れても保持期限切れまで待ち切る() {
    // 負荷でバックグラウンドの実行が遅れると、20 ms × 100 回（約 2 秒）の待ちでは期限切れを
    // 見られずに落ちた（#61）。偽 Trino の応答を旧予算より長い 3 秒遅らせ、完了（3 秒）＋
    // 保持期限（200 ms）まで待ち切れることを固定する。
    let harness = Harness::builder(select_response())
        .retention(Duration::from_millis(200))
        .statement_delay(Duration::from_secs(3))
        .start()
        .await;
    let started = Instant::now();
    let id = harness
        .start_query(json!({ "QueryString": "SELECT n FROM t" }))
        .await;

    let error = wait_until_gone(&harness, &id).await;

    assert_eq!(error["AthenaErrorCode"], "QUERY_EXECUTION_NOT_FOUND");
    // 遅延の前に失敗して捨てられただけでも 400 になる。本当に完了まで待ち切ったことを固定する。
    assert!(
        started.elapsed() >= Duration::from_secs(3),
        "完了を待たずに消えた: {:?}",
        started.elapsed()
    );
}
