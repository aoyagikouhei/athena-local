//! テストの待ちヘルパ（`wait_for`／`run_query`）が、回数ではなく経過時間で諦めることを確認する。
//! #61 で `wait_until_gone` が 20 ms × 100 回（約 2 秒）の待ちで落ちたのと同じ形で、
//! 負荷でバックグラウンドの実行が遅れても待ち切れることを固定する（#67）。

mod common;

use std::time::{Duration, Instant};

use common::{Harness, wait_for};
use serde_json::json;

#[tokio::test]
async fn wait_for_は_2_秒を超えても条件が成り立つまで待つ() {
    // 旧実装（10 ms × 200 回）は約 2 秒で諦める。それより長い 2.5 秒後に成り立つ条件を待ち切る。
    let started = Instant::now();
    wait_for("2.5 秒後に成り立つ条件", || {
        started.elapsed() >= Duration::from_millis(2500)
    })
    .await;
    assert!(started.elapsed() >= Duration::from_millis(2500));
}

#[tokio::test]
async fn run_query_は実行の完了が_2_秒を超えても待ち切る() {
    // 旧実装（20 ms × 100 回）は約 2 秒で「クエリが終わらない」と落ちる。偽 Trino の応答を 3 秒遅らせ、
    // 完了まで待ち切って SUCCEEDED を返すことを固定する。
    let harness =
        Harness::builder(json!({ "columns": [{ "name": "n", "type": "bigint" }], "data": [[1]] }))
            .statement_delay(Duration::from_secs(3))
            .start()
            .await;
    let started = Instant::now();

    let execution = harness
        .run_query(json!({ "QueryString": "SELECT n FROM t" }))
        .await;

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert!(
        started.elapsed() >= Duration::from_secs(3),
        "完了を待たずに返った: {:?}",
        started.elapsed()
    );
}
