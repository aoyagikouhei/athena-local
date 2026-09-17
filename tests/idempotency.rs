//! ClientRequestToken による StartQueryExecution の冪等化。
//! 同じトークン・同じパラメータの再送は先行クエリの状態に関係なく同じ ID を返し、
//! パラメータが違えば IDEMPOTENT_PARAMETER_MISMATCH になる（2026-09-17 実測）。

mod common;

use common::Harness;
use serde_json::{Value, json};

fn select_response() -> Value {
    json!({ "columns": [{ "name": "n", "type": "bigint" }], "data": [[1]] })
}

/// テストごとに別の値にする 32 文字以上の固定トークン。
fn token(name: &str) -> String {
    format!("token-{name}-0123456789abcdef0123456789")
}

#[tokio::test]
async fn 同じトークンで2回呼ぶと同じ_id_が返り_trino_への本体は1回になる() {
    let harness = Harness::start(select_response()).await;
    let body = json!({
        "QueryString": "SELECT 1",
        "ClientRequestToken": token("dup"),
    });

    let id1 = harness.start_query(body.clone()).await;
    let id2 = harness.start_query(body).await;

    assert_eq!(id1, id2);
    assert_eq!(harness.trino_sqls().len(), 1, "本体は1回だけ");
    // 照合は構文チェックの後なので、2回目も PREPARE は届く。
    assert_eq!(harness.syntax_checks().len(), 2);
}

#[tokio::test]
async fn 同時に2回呼んでも実行は1本だけになる() {
    let harness = Harness::start(select_response()).await;
    let body = json!({
        "QueryString": "SELECT 1",
        "ClientRequestToken": token("concurrent"),
    });

    let (result1, result2) = tokio::join!(
        harness.call("StartQueryExecution", body.clone()),
        harness.call("StartQueryExecution", body),
    );

    let (status1, response1) = result1;
    let (status2, response2) = result2;
    assert_eq!(status1, 200, "{response1}");
    assert_eq!(status2, 200, "{response2}");
    assert_eq!(response1["QueryExecutionId"], response2["QueryExecutionId"]);
    assert_eq!(harness.trino_sqls().len(), 1);
}

#[tokio::test]
async fn 同じトークンでクエリを変えると_idempotent_parameter_mismatch_になる() {
    let harness = Harness::start(select_response()).await;
    let same_token = token("mismatch-query");

    let (status1, _) = harness
        .call(
            "StartQueryExecution",
            json!({ "QueryString": "SELECT 1", "ClientRequestToken": same_token }),
        )
        .await;
    assert_eq!(status1, 200);

    let (status2, error) = harness
        .call(
            "StartQueryExecution",
            json!({ "QueryString": "SELECT 2", "ClientRequestToken": same_token }),
        )
        .await;

    assert_eq!(status2, 400);
    assert_eq!(error["__type"], "InvalidRequestException");
    assert_eq!(error["AthenaErrorCode"], "IDEMPOTENT_PARAMETER_MISMATCH");
    assert_eq!(error["ErrorCode"], "IDEMPOTENT_PARAMETER_MISMATCH");
    assert_eq!(error["Message"], "Idempotent parameters do not match");
    assert_eq!(harness.trino_sqls().len(), 1, "2回目は実行を作らない");
}

#[tokio::test]
async fn 同じトークンで_database_か_output_location_を変えても衝突になる() {
    for (name, first, second) in [
        (
            "database",
            json!({
                "QueryString": "SELECT 1",
                "QueryExecutionContext": { "Database": "db1" },
            }),
            json!({
                "QueryString": "SELECT 1",
                "QueryExecutionContext": { "Database": "db2" },
            }),
        ),
        (
            "output_location",
            json!({
                "QueryString": "SELECT 1",
                "ResultConfiguration": { "OutputLocation": "s3://b/x/" },
            }),
            json!({
                "QueryString": "SELECT 1",
                "ResultConfiguration": { "OutputLocation": "s3://b/y/" },
            }),
        ),
        // 既定を当てる前の生の値で比べるので、省略と明示は別物（本物の扱いは未実測）。
        (
            "database_omitted_then_given",
            json!({ "QueryString": "SELECT 1" }),
            json!({
                "QueryString": "SELECT 1",
                "QueryExecutionContext": { "Database": "db1" },
            }),
        ),
    ] {
        let harness = Harness::start(select_response()).await;
        let same_token = token(name);
        let mut first = first;
        let mut second = second;
        first["ClientRequestToken"] = json!(same_token);
        second["ClientRequestToken"] = json!(same_token);

        let (status1, _) = harness.call("StartQueryExecution", first).await;
        assert_eq!(status1, 200, "{name}");

        let (status2, error) = harness.call("StartQueryExecution", second).await;
        assert_eq!(status2, 400, "{name}");
        assert_eq!(
            error["AthenaErrorCode"], "IDEMPOTENT_PARAMETER_MISMATCH",
            "{name}"
        );
    }
}

#[tokio::test]
async fn 同じトークンで_execution_parameters_か_work_group_を変えても同じ_id_が返る() {
    // ExecutionParameters: SELECT (<値>) の分類に .route() が要る。
    let harness = Harness::builder(select_response())
        .route(
            "SELECT (1)",
            common::trino_single_value("integer", json!(1)),
        )
        .route(
            "SELECT (2)",
            common::trino_single_value("integer", json!(2)),
        )
        .start()
        .await;
    let same_token = token("execution-parameters");

    let id1 = harness
        .start_query(json!({
            "QueryString": "SELECT ? AS v",
            "ExecutionParameters": ["1"],
            "ClientRequestToken": same_token,
        }))
        .await;
    let id2 = harness
        .start_query(json!({
            "QueryString": "SELECT ? AS v",
            "ExecutionParameters": ["2"],
            "ClientRequestToken": same_token,
        }))
        .await;

    assert_eq!(id1, id2);

    // WorkGroup: primary → 別名でも同じ id。
    let harness2 = Harness::start(select_response()).await;
    let wg_token = token("work-group");

    let wg_id1 = harness2
        .start_query(json!({
            "QueryString": "SELECT 1",
            "WorkGroup": "primary",
            "ClientRequestToken": wg_token,
        }))
        .await;
    let wg_id2 = harness2
        .start_query(json!({
            "QueryString": "SELECT 1",
            "WorkGroup": "other",
            "ClientRequestToken": wg_token,
        }))
        .await;

    assert_eq!(wg_id1, wg_id2);
}

#[tokio::test]
async fn トークンの表記の違いは正規化しない() {
    // 128 は長さ検証の上限（このテストの主眼は正規化の有無で、長さ検証は別テストで固定する）。
    let long_a = "a".repeat(128);
    let long_b = "b".repeat(128);
    let cases: Vec<(&str, String, String)> = vec![
        (
            "大文字小文字",
            token("case-lower"),
            token("case-lower").to_uppercase(),
        ),
        ("前後の空白", token("space"), format!(" {}", token("space"))),
        (
            "非ascii",
            format!("{}日本語", token("nonascii1")),
            format!("{}にほんご", token("nonascii2")),
        ),
        ("極端に長い", long_a, long_b),
    ];

    for (name, a, b) in cases {
        let harness = Harness::start(select_response()).await;

        let id_a1 = harness
            .start_query(json!({ "QueryString": "SELECT 1", "ClientRequestToken": a }))
            .await;
        let id_a2 = harness
            .start_query(json!({ "QueryString": "SELECT 1", "ClientRequestToken": a }))
            .await;
        assert_eq!(id_a1, id_a2, "{name}: 同じ文字列なら同じ id");

        let id_b1 = harness
            .start_query(json!({ "QueryString": "SELECT 1", "ClientRequestToken": b }))
            .await;
        assert_ne!(id_a1, id_b1, "{name}: 違う文字列なら別の id");
    }
}

/// 判断 2（4 回目の実測）。call_raw で送らないと Harness::call が UUID を自動で入れてしまう。
#[tokio::test]
async fn トークンが無ければ_invalid_input_になる() {
    let harness = Harness::start(select_response()).await;

    let (status, error) = harness
        .call_raw("StartQueryExecution", json!({ "QueryString": "SELECT 1" }))
        .await;

    assert_eq!(status, 400);
    assert_eq!(error["__type"], "InvalidRequestException");
    assert_eq!(error["AthenaErrorCode"], "INVALID_INPUT");
    assert_eq!(error["ErrorCode"], "INVALID_INPUT");
    assert_eq!(error["Message"], "clientRequestToken is null or empty");
    // 検証はクエリの処理より前に行われる。
    assert!(harness.trino_requests().is_empty());
    assert!(harness.syntax_checks().is_empty());
}

/// 判断 11（3 回目の実測）。32 未満（空文字含む）と 128 超は 400、32 と 128 は成功。
#[tokio::test]
async fn トークンの長さは_32_以上_128_以下() {
    const TOO_SHORT: &str = "1 validation error detected: Value at 'clientRequestToken' failed to satisfy constraint: Member must have length greater than or equal to 32";
    const TOO_LONG: &str = "1 validation error detected: Value at 'clientRequestToken' failed to satisfy constraint: Member must have length less than or equal to 128";

    for (name, len, expected_message) in [
        ("空文字", 0usize, Some(TOO_SHORT)),
        ("31文字", 31, Some(TOO_SHORT)),
        ("32文字", 32, None),
        ("128文字", 128, None),
        ("129文字", 129, Some(TOO_LONG)),
    ] {
        let harness = Harness::start(select_response()).await;
        let value = "a".repeat(len);

        let (status, body) = harness
            .call(
                "StartQueryExecution",
                json!({ "QueryString": "SELECT 1", "ClientRequestToken": value }),
            )
            .await;

        match expected_message {
            None => assert_eq!(status, 200, "{name}: {body}"),
            Some(message) => {
                assert_eq!(status, 400, "{name}: {body}");
                assert_eq!(body["__type"], "InvalidRequestException", "{name}");
                assert_eq!(body["AthenaErrorCode"], "INVALID_INPUT", "{name}");
                assert_eq!(body["ErrorCode"], "INVALID_INPUT", "{name}");
                assert_eq!(body["Message"], message, "{name}");
            }
        }
    }
}
