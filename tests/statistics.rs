//! Statistics: 投入・実行開始・完了の時刻から時間を出す。スキャン量は 0 のまま。

mod common;

use std::time::Duration;

use common::{Harness, wait_for};
use serde_json::{Value, json};

/// (待ち時間, 実行時間, 全体)。
fn timings(statistics: &Value) -> (i64, i64, i64) {
    let millis = |name: &str| {
        statistics[name]
            .as_i64()
            .unwrap_or_else(|| panic!("{name} が無い: {statistics}"))
    };
    (
        millis("QueryQueueTimeInMillis"),
        millis("EngineExecutionTimeInMillis"),
        millis("TotalExecutionTimeInMillis"),
    )
}

#[tokio::test]
async fn 終わったクエリは_trino_を待った時間が実行時間に入り足すと全体になる() {
    let harness = Harness::builder(json!({
        "columns": [{ "name": "n", "type": "bigint" }],
        "data": [[1]]
    }))
    .statement_delay(Duration::from_millis(100))
    .start()
    .await;

    let execution = harness
        .run_query(json!({ "QueryString": "SELECT n FROM t" }))
        .await;
    let statistics = &execution["QueryExecution"]["Statistics"];
    let (queue, engine, total) = timings(statistics);

    assert!(engine >= 100, "{statistics}");
    assert!(queue >= 0, "{statistics}");
    assert_eq!(total, queue + engine, "{statistics}");
    assert_eq!(statistics["DataScannedInBytes"], 0);
}

#[tokio::test]
async fn 止めたクエリは止めた時点までの時間が入る() {
    let harness = Harness::builder(json!({ "columns": [{ "name": "n", "type": "bigint" }] }))
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
    tokio::time::sleep(Duration::from_millis(50)).await;

    harness
        .call("StopQueryExecution", json!({ "QueryExecutionId": id }))
        .await;
    let (_, execution) = harness
        .call("GetQueryExecution", json!({ "QueryExecutionId": id }))
        .await;
    let statistics = &execution["QueryExecution"]["Statistics"];
    let (queue, engine, total) = timings(statistics);

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "CANCELLED");
    assert!(engine >= 50, "{statistics}");
    assert_eq!(total, queue + engine, "{statistics}");
}
