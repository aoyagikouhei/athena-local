//! 失敗したクエリにも結果ファイル `<id>.txt` を置く。
//! 置く文の種類・中身・Content-Type は 2026-09-17 に本番 Athena で実測したもの。

mod common;

use std::time::Duration;

use common::{Harness, S3Put, execution_id, trino_error, wait_for};
use serde_json::{Value, json};

/// Trino が返すエラーの message。非 ASCII・`"`・改行・タブを含む厄介な入力。
const MESSAGE: &str =
    "line 1:1: スキーマ \"no_such\"db\" が見つかりません\n(ヒント: タブ\tと改行を含む)";

fn with_output(sql: &str) -> Value {
    json!({
        "QueryString": sql,
        "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
    })
}

#[tokio::test]
async fn 失敗した_show_は_failed_の理由を_txt_に置く() {
    let harness = Harness::builder(trino_error("SCHEMA_NOT_FOUND", MESSAGE))
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(with_output("SHOW TABLES IN no_such"))
        .await;
    let id = execution_id(&execution);
    let status = &execution["QueryExecution"]["Status"];

    assert_eq!(status["State"], "FAILED");
    // StateChangeReason には `FAILED: ` が付かない。付けるのはファイルの中身だけ。
    assert_eq!(
        status["StateChangeReason"],
        format!("SCHEMA_NOT_FOUND: {MESSAGE}")
    );

    // 本体だけを置き、付随ファイル `.metadata` は置かない（2026-09-17 実測）。
    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 1, "{puts:?}");
    assert_eq!(
        puts[0],
        S3Put {
            bucket: "results-bucket".to_string(),
            key: format!("athena/{id}.txt"),
            body: format!("FAILED: SCHEMA_NOT_FOUND: {MESSAGE}").into_bytes(),
            // 成功した `.txt` の binary/octet-stream と違う（2026-09-17 実測）。
            content_type: Some("application/octet-stream".to_string()),
            presigned: true,
        }
    );
    assert!(
        !puts[0].body.ends_with(b"\n"),
        "末尾に改行が付いている: {:?}",
        puts[0].body
    );
}

#[tokio::test]
async fn 失敗の理由のファイルを書き終わるまで_failed_にしない() {
    let harness = Harness::builder(trino_error("SCHEMA_NOT_FOUND", "no_such が見つかりません"))
        .results_s3()
        .s3_delay(Duration::from_millis(300))
        .start()
        .await;

    let id = harness
        .start_query(with_output("SHOW TABLES IN no_such"))
        .await;
    wait_for("偽 S3 が PUT を受ける", || {
        harness.s3_puts().len() == 1
    })
    .await;

    // PUT の応答を待っている間は RUNNING のまま（クライアントは FAILED を見た直後に S3 を読む）。
    assert_eq!(harness.status(&id).await["State"], "RUNNING");

    // 応答が返れば FAILED になる。
    for _ in 0..100 {
        if harness.status(&id).await["State"] != "RUNNING" {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(harness.status(&id).await["State"], "FAILED");
}

#[tokio::test]
async fn 失敗した_select_と_insert_は何も置かない() {
    let harness = Harness::builder(json!({ "columns": [{ "name": "n", "type": "bigint" }] }))
        .route(
            "SELECT * FROM no_such",
            trino_error(
                "TABLE_NOT_FOUND",
                "line 1:15: Table 'no_such' does not exist",
            ),
        )
        .route(
            "INSERT INTO t VALUES (1)",
            trino_error("TABLE_NOT_FOUND", "line 1:13: Table 't' does not exist"),
        )
        .results_s3()
        .start()
        .await;

    for sql in ["SELECT * FROM no_such", "INSERT INTO t VALUES (1)"] {
        let execution = harness.run_query(with_output(sql)).await;
        assert_eq!(
            execution["QueryExecution"]["Status"]["State"], "FAILED",
            "{sql}"
        );
    }

    // `.csv`（SELECT）と `<id>`（INSERT）の文は、本物も失敗時に何も置かない（2026-09-17 実測）。
    assert!(harness.s3_puts().is_empty(), "{:?}", harness.s3_puts());
}

#[tokio::test]
async fn 失敗の理由のファイルが書けなくても_failed_の理由は変わらない() {
    let harness = Harness::builder(trino_error("SCHEMA_NOT_FOUND", "no_such が見つかりません"))
        .results_s3()
        .s3_status(500)
        .start()
        .await;

    let execution = harness
        .run_query(with_output("SHOW TABLES IN no_such"))
        .await;
    let status = &execution["QueryExecution"]["Status"];

    assert_eq!(status["State"], "FAILED");
    let reason = status["StateChangeReason"].as_str().expect("理由が無い");
    assert_eq!(reason, "SCHEMA_NOT_FOUND: no_such が見つかりません");
    assert!(
        !reason.contains("S3") && !reason.contains("500"),
        "理由: {reason}"
    );
    // 理由が Trino のままなので AthenaError も Trino 由来（書き込み失敗の 401 ではない）。
    assert_eq!(status["AthenaError"]["ErrorCategory"], 2);
    assert_eq!(status["AthenaError"]["ErrorType"], 1301);
    assert_eq!(harness.s3_puts().len(), 1, "書き込みは試みる");
}
