//! リクエスト本文の解釈の失敗（型違い・必須の欠落・壊れた JSON）とディスパッチの失敗が、
//! 本物の Athena と同じ応答になることを確認する（2026-09-23 実測。#84）。

mod common;

use common::Harness;
use serde_json::{Value, json};

const HEADERS: &[(&str, &str)] = &[
    ("X-Amz-Target", "AmazonAthena.ListWorkGroups"),
    ("Content-Type", "application/x-amz-json-1.1"),
];

fn keys(body: &Value) -> Vec<&str> {
    let mut keys: Vec<&str> = body
        .as_object()
        .expect("本文が object でない")
        .keys()
        .map(String::as_str)
        .collect();
    keys.sort();
    keys
}

/// 本物の SerializationException は AthenaErrorCode を持たず、Message は入力の形によって有無が分かれる。
fn assert_serialization(status: u16, body: &Value, message: Option<&str>, label: &str) {
    assert_eq!(status, 400, "{label}");
    assert_eq!(body["__type"], "SerializationException", "{label}");
    match message {
        Some(message) => {
            assert_eq!(keys(body), ["Message", "__type"], "{label}");
            assert_eq!(body["Message"], message, "{label}");
        }
        None => assert_eq!(keys(body), ["__type"], "{label}"),
    }
}

/// 必須の項目の欠落は枠組みの検証（lowerCamel の項目名）。
fn assert_missing(status: u16, body: &Value, field: &str, label: &str) {
    assert_eq!(status, 400, "{label}");
    assert_eq!(body["__type"], "InvalidRequestException", "{label}");
    assert_eq!(body["AthenaErrorCode"], "INVALID_INPUT", "{label}");
    assert_eq!(body["ErrorCode"], "INVALID_INPUT", "{label}");
    assert_eq!(
        body["Message"],
        format!(
            "1 validation error detected: Value null at '{field}' failed to satisfy constraint: Member must not be null"
        ),
        "{label}"
    );
}

#[tokio::test]
async fn 型違いは_serialization_exception_になり文言は型の組み合わせで決まる() {
    let harness = Harness::start(json!({ "columns": [], "data": [] })).await;

    for (operation, body, message) in [
        (
            "ListWorkGroups",
            json!({ "MaxResults": "1" }),
            "STRING_VALUE can not be converted to an Integer",
        ),
        (
            "ListWorkGroups",
            json!({ "MaxResults": true }),
            "TRUE_VALUE can not be converted to an Integer",
        ),
        (
            "ListWorkGroups",
            json!({ "MaxResults": [1] }),
            "Start of list found where not expected",
        ),
        (
            "ListWorkGroups",
            json!({ "MaxResults": { "a": 1 } }),
            "Start of structure or map found where not expected.",
        ),
        (
            "ListWorkGroups",
            json!({ "NextToken": 1 }),
            "NUMBER_VALUE can not be converted to a String",
        ),
        (
            "ListWorkGroups",
            json!({ "NextToken": true }),
            "TRUE_VALUE can not be converted to a String",
        ),
        (
            "GetQueryExecution",
            json!({ "QueryExecutionId": ["x"] }),
            "Start of list found where not expected",
        ),
        (
            "StartQueryExecution",
            json!({ "QueryString": "SELECT", "ExecutionParameters": [1] }),
            "NUMBER_VALUE can not be converted to a String",
        ),
        (
            "StartQueryExecution",
            json!({ "QueryString": "SELECT", "ExecutionParameters": "x" }),
            "Expected list or null",
        ),
        (
            "StartQueryExecution",
            json!({ "QueryString": "SELECT", "ResultConfiguration": "x" }),
            "Expected null",
        ),
    ] {
        let label = format!("{operation} {body}");
        let (status, error) = harness.call(operation, body).await;
        assert_serialization(status, &error, Some(message), &label);
    }
}

#[tokio::test]
async fn 未実測の組み合わせは_message_を付けない() {
    // false・小数・オブジェクト → 配列は本物で測っていないので、文言を推測せず __type だけ返す。
    let harness = Harness::start(json!({ "columns": [], "data": [] })).await;

    for (operation, body) in [
        ("ListWorkGroups", json!({ "MaxResults": false })),
        ("ListWorkGroups", json!({ "MaxResults": 1.5 })),
        (
            "StartQueryExecution",
            json!({ "QueryString": "SELECT", "ExecutionParameters": {} }),
        ),
    ] {
        let label = format!("{operation} {body}");
        let (status, error) = harness.call(operation, body).await;
        assert_serialization(status, &error, None, &label);
    }
}

#[tokio::test]
async fn 必須の項目の欠落と_null_は枠組みの検証になる() {
    let harness = Harness::start(json!({ "columns": [], "data": [] })).await;

    let (status, error) = harness.call("GetQueryExecution", json!({})).await;
    assert_missing(status, &error, "queryExecutionId", "GetQueryExecution {}");
    let (status, error) = harness
        .call("GetQueryExecution", json!({ "QueryExecutionId": null }))
        .await;
    assert_missing(status, &error, "queryExecutionId", "GetQueryExecution null");
    let (status, error) = harness.call("GetWorkGroup", json!({})).await;
    assert_missing(status, &error, "workGroup", "GetWorkGroup {}");
    // ClientRequestToken の検査より QueryString の欠落が先。
    let (status, error) = harness.call_raw("StartQueryExecution", json!({})).await;
    assert_missing(status, &error, "queryString", "StartQueryExecution {}");
}

#[tokio::test]
async fn 本文そのものの異常は_message_無しの_serialization_exception_になる() {
    let harness = Harness::start(json!({ "columns": [], "data": [] })).await;

    for body in ["{", "", "null", "\"x\"", "{\"MaxResults\": 1,}"] {
        let (status, error) = harness.post(HEADERS, body.as_bytes()).await;
        assert_serialization(status, &error, None, &format!("本文 {body:?}"));
    }
    // 本文が配列のときだけ文言が付く。
    let (status, error) = harness.post(HEADERS, b"[]").await;
    assert_serialization(
        status,
        &error,
        Some("Start of list found where not expected"),
        "本文 []",
    );
}

#[tokio::test]
async fn null_の項目と未知のキーは無いのと同じ() {
    let harness = Harness::start(json!({ "columns": [], "data": [] })).await;

    let (status, body) = harness
        .call(
            "ListWorkGroups",
            json!({ "MaxResults": null, "NextToken": null, "Foo": 1 }),
        )
        .await;
    assert_eq!(status, 200);
    assert!(body.get("WorkGroups").is_some());
}

#[tokio::test]
async fn integer_の範囲外は上限の検証になる() {
    let harness = Harness::start(json!({ "columns": [], "data": [] })).await;

    let (status, error) = harness
        .call("ListWorkGroups", json!({ "MaxResults": 99999999999_i64 }))
        .await;
    assert_eq!(status, 400);
    assert_eq!(error["__type"], "InvalidRequestException");
    assert_eq!(error["AthenaErrorCode"], "INVALID_INPUT");
    assert_eq!(
        error["Message"],
        "1 validation error detected: Value at 'maxResults' failed to satisfy constraint: Member must have value less than or equal to 50"
    );
}

#[tokio::test]
async fn 型違いは枠組みの検証より先() {
    let harness = Harness::start(json!({ "columns": [], "data": [] })).await;

    let (status, error) = harness
        .call(
            "ListWorkGroups",
            json!({ "MaxResults": "1", "NextToken": "" }),
        )
        .await;
    assert_serialization(
        status,
        &error,
        Some("STRING_VALUE can not be converted to an Integer"),
        "型違いと空文字",
    );
    let (status, error) = harness
        .call("GetQueryResults", json!({ "MaxResults": "1" }))
        .await;
    assert_serialization(
        status,
        &error,
        Some("STRING_VALUE can not be converted to an Integer"),
        "型違いと必須の欠落",
    );
}
