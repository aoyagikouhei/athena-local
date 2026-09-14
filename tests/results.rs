//! ResultConfiguration.OutputLocation: 結果 CSV を S3 互換ストレージに書き、GetQueryExecution にフルパスを返す。
//! 置き場所・ファイル名・エラーの文言は 2026-09-14 に本番 Athena で実測したもの。

mod common;

use std::time::Duration;

use common::{Harness, S3Put, execution_id, wait_for};
use serde_json::{Value, json};

fn select_response() -> Value {
    json!({
        "columns": [
            { "name": "id", "type": "integer" },
            { "name": "name", "type": "varchar" }
        ],
        "data": [[1, "it's \"x\""], [2, null]]
    })
}

fn dml_response() -> Value {
    json!({
        "columns": [{ "name": "rows", "type": "bigint" }],
        "data": [[1]],
        "updateType": "INSERT",
        "updateCount": 1
    })
}

fn output_location(execution: &Value) -> &str {
    execution["QueryExecution"]["ResultConfiguration"]["OutputLocation"]
        .as_str()
        .expect("OutputLocation が無い")
}

fn select_with_output(location: &str) -> Value {
    json!({
        "QueryString": "SELECT id, name FROM users",
        "ResultConfiguration": { "OutputLocation": location }
    })
}

#[tokio::test]
async fn select_の結果を_csv_で書き_フルパスを返す() {
    let harness = Harness::builder(select_response())
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(select_with_output("s3://results-bucket/athena/"))
        .await;
    let id = execution_id(&execution);

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        output_location(&execution),
        format!("s3://results-bucket/athena/{id}.csv")
    );
    assert_eq!(
        harness.s3_puts(),
        [S3Put {
            bucket: "results-bucket".to_string(),
            key: format!("athena/{id}.csv"),
            body: "\"id\",\"name\"\n\"1\",\"it's \"\"x\"\"\"\n\"2\",\n".to_string(),
            content_type: Some("text/csv".to_string()),
            presigned: true,
        }]
    );
}

#[tokio::test]
async fn 書き終わるまで_succeeded_にしない() {
    let harness = Harness::builder(select_response())
        .results_s3()
        .s3_delay(Duration::from_millis(300))
        .start()
        .await;

    let id = harness
        .start_query(select_with_output("s3://results-bucket/athena/"))
        .await;
    wait_for("偽 S3 が PUT を受ける", || {
        harness.s3_puts().len() == 1
    })
    .await;

    // PUT の応答を待っている間は RUNNING のまま。
    assert_eq!(harness.status(&id).await["State"], "RUNNING");

    // 応答が返れば SUCCEEDED になる。
    for _ in 0..100 {
        if harness.status(&id).await["State"] != "RUNNING" {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(harness.status(&id).await["State"], "SUCCEEDED");
}

#[tokio::test]
async fn 既定の出力先を使い_末尾スラッシュが無くても同じ場所に置く() {
    let harness = Harness::builder(select_response())
        .results_s3()
        .default_output_location("s3://results-bucket/prefix")
        .start()
        .await;

    let execution = harness
        .run_query(json!({ "QueryString": "SELECT id, name FROM users" }))
        .await;
    let id = execution_id(&execution);
    assert_eq!(
        output_location(&execution),
        format!("s3://results-bucket/prefix/{id}.csv")
    );

    // リクエストの値は既定より優先する。prefix が無ければバケット直下。
    let execution = harness
        .run_query(select_with_output("s3://other-bucket"))
        .await;
    let other = execution_id(&execution);

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2);
    assert_eq!(
        (puts[0].bucket.as_str(), puts[0].key.as_str()),
        ("results-bucket", format!("prefix/{id}.csv").as_str())
    );
    assert_eq!(
        (puts[1].bucket.as_str(), puts[1].key.as_str()),
        ("other-bucket", format!("{other}.csv").as_str())
    );
}

#[tokio::test]
async fn dml_と_ddl_は何も書かず_ファイル名だけ本物に合わせて返す() {
    let harness = Harness::builder(select_response())
        .route("INSERT INTO t VALUES (1)", dml_response())
        .route(
            "CREATE TABLE t (i int)",
            json!({ "updateType": "CREATE TABLE" }),
        )
        .results_s3()
        .default_output_location("s3://results-bucket/athena/")
        .start()
        .await;

    let insert = harness
        .run_query(json!({ "QueryString": "INSERT INTO t VALUES (1)" }))
        .await;
    let create = harness
        .run_query(json!({ "QueryString": "CREATE TABLE t (i int)" }))
        .await;

    assert_eq!(insert["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(create["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        output_location(&insert),
        format!("s3://results-bucket/athena/{}", execution_id(&insert))
    );
    assert_eq!(
        output_location(&create),
        format!("s3://results-bucket/athena/{}.txt", execution_id(&create))
    );
    assert!(harness.s3_puts().is_empty());
}

#[tokio::test]
async fn 書き込みに失敗すると_failed_になり理由が残る() {
    let harness = Harness::builder(select_response())
        .results_s3()
        .s3_status(500)
        .start()
        .await;

    let execution = harness
        .run_query(select_with_output("s3://results-bucket/athena/"))
        .await;
    let status = &execution["QueryExecution"]["Status"];

    assert_eq!(status["State"], "FAILED");
    let reason = status["StateChangeReason"].as_str().unwrap();
    assert!(
        reason.contains("s3://results-bucket/athena/") && reason.contains("500"),
        "理由: {reason}"
    );
    assert_eq!(harness.s3_puts().len(), 1, "再試行しない");

    let (code, _) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": execution_id(&execution) }),
        )
        .await;
    assert_eq!(code, 400);
}

#[tokio::test]
async fn 書くモードで出力先も既定も無ければ受け付けない() {
    let harness = Harness::builder(select_response())
        .results_s3()
        .start()
        .await;

    let (code, error) = harness
        .call(
            "StartQueryExecution",
            json!({ "QueryString": "SELECT id, name FROM users" }),
        )
        .await;

    assert_eq!(code, 400);
    assert_eq!(error["__type"], "InvalidRequestException");
    assert_eq!(
        error["message"],
        "No output location provided. You did not provide an output location for  your query results. Either specify an S3 bucket location or enable Athena managed query results in your workgroup settings."
    );
    assert_eq!(error["AthenaErrorCode"], "INVALID_INPUT");
    assert!(harness.trino_requests().is_empty(), "Trino には送らない");
}

#[tokio::test]
async fn s3_の形でない出力先はどちらのモードでも受け付けない() {
    for harness in [
        Harness::start(select_response()).await,
        Harness::builder(select_response())
            .results_s3()
            .start()
            .await,
    ] {
        let (code, error) = harness
            .call(
                "StartQueryExecution",
                select_with_output("https://example.com/x/"),
            )
            .await;

        assert_eq!(code, 400);
        assert_eq!(error["message"], "outputLocation is not a valid S3 path.");
        assert_eq!(error["AthenaErrorCode"], "INVALID_INPUT");
        assert!(harness.trino_requests().is_empty());
    }
}

#[tokio::test]
async fn 書かないモードでもフルパスは返し_出力先が無ければ項目ごと省く() {
    let harness = Harness::start(select_response()).await;

    let with_output = harness
        .run_query(select_with_output("s3://results-bucket/athena"))
        .await;
    assert_eq!(
        with_output["QueryExecution"]["Status"]["State"],
        "SUCCEEDED"
    );
    assert_eq!(
        output_location(&with_output),
        format!(
            "s3://results-bucket/athena/{}.csv",
            execution_id(&with_output)
        )
    );

    let without = harness
        .run_query(json!({ "QueryString": "SELECT id, name FROM users" }))
        .await;
    assert_eq!(without["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert!(
        without["QueryExecution"]
            .get("ResultConfiguration")
            .is_none()
    );
}
