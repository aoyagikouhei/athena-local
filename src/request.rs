//! awsJson1.1 のリクエスト本文の解釈。本物は本文の異常を `SerializationException` にし、
//! 必須の項目の欠落は枠組みの検証（`InvalidRequestException` / `INVALID_INPUT`）にする
//! （2026-09-23 に生 HTTP で 46 通りを実測。#84）。
//!
//! 3 段で読む: (1) JSON として読めなければ `Message` 無しの `SerializationException`
//! (2) トップレベルが配列なら `Start of list found where not expected`、object 以外のスカラは `Message` 無し
//! (3) object の `null` の項目を消してから型に読み、serde のエラー文で型違いと欠落を見分ける。
//! 文言は実測した組み合わせだけ出し、未実測の組み合わせは `Message` 無しにする（推測で埋めない）。

use axum::body::Bytes;
use axum::response::Response;
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::response::{invalid_request_with_code, serialization_error, validation_errors};

/// 本物は `null` の項目を無いものとして扱う（任意なら無いのと同じ、必須なら欠落の検証。2026-09-23 実測）。
/// serde は必須の `String` に `null` を型違いとして弾くので、読む前に消す。入れ子の object にも当てる。
fn strip_nulls(value: Value) -> Value {
    match value {
        Value::Object(map) => Value::Object(
            map.into_iter()
                .filter(|(_, v)| !v.is_null())
                .map(|(k, v)| (k, strip_nulls(v)))
                .collect(),
        ),
        other => other,
    }
}

/// `QueryExecutionId` → `queryExecutionId`（本物の枠組みの検証は lowerCamel で項目名を出す）。
fn lower_camel(field: &str) -> String {
    let mut chars = field.chars();
    match chars.next() {
        Some(first) => first.to_lowercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// 型違いの文言（2026-09-23 実測の組み合わせだけ）。未実測なら `None`。
///
/// `found` は serde の `invalid type: <found>, expected <expected>` の `<found>`
/// （`string "…"`／`integer `…``／`boolean `true``／`sequence`／`map` など）、`expected` は `<expected>`
/// （`i64`／`a string`／`a sequence`／`struct ResultConfiguration` など）。
fn type_mismatch(found: &str, expected: &str) -> Option<String> {
    let integer = expected.starts_with('i') || expected.starts_with('u');
    let string = expected == "a string";
    if integer || string {
        let target = if integer { "an Integer" } else { "a String" };
        let value = if found == "sequence" {
            return Some("Start of list found where not expected".to_string());
        } else if found == "map" {
            return Some("Start of structure or map found where not expected.".to_string());
        } else if found.starts_with("string ") && integer {
            "STRING_VALUE"
        } else if found.starts_with("integer ") && string {
            "NUMBER_VALUE"
        } else if found == "boolean `true`" {
            "TRUE_VALUE"
        } else {
            return None;
        };
        return Some(format!("{value} can not be converted to {target}"));
    }
    if found.starts_with("string ") {
        if expected == "a sequence" {
            return Some("Expected list or null".to_string());
        }
        if expected.starts_with("struct ") {
            return Some("Expected null".to_string());
        }
    }
    None
}

/// `from_value` の失敗を本物の応答に写す。
fn deserialize_error(error: &serde_json::Error) -> Response {
    let text = error.to_string();
    if let Some(field) = text
        .strip_prefix("missing field `")
        .and_then(|rest| rest.strip_suffix('`'))
    {
        return invalid_request_with_code(
            validation_errors(&[format!(
                "Value null at '{}' failed to satisfy constraint: Member must not be null",
                lower_camel(field)
            )]),
            "INVALID_INPUT",
        );
    }
    let message = text
        .strip_prefix("invalid type: ")
        .and_then(|rest| rest.split_once(", expected "))
        .and_then(|(found, expected)| type_mismatch(found, expected));
    serialization_error(message)
}

/// Response は大きいので Box で返す（clippy::result_large_err）。
pub fn parse<T: DeserializeOwned>(body: &Bytes) -> Result<T, Box<Response>> {
    let value: Value = match serde_json::from_slice(body) {
        Ok(value) => value,
        Err(_) => return Err(Box::new(serialization_error(None))),
    };
    let value = match value {
        Value::Object(_) => strip_nulls(value),
        Value::Array(_) => {
            return Err(Box::new(serialization_error(Some(
                "Start of list found where not expected".to_string(),
            ))));
        }
        _ => return Err(Box::new(serialization_error(None))),
    };
    serde_json::from_value(value).map_err(|e| Box::new(deserialize_error(&e)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;

    #[derive(Deserialize)]
    #[serde(rename_all = "PascalCase")]
    struct Nested {
        #[serde(default)]
        output_location: Option<String>,
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "PascalCase")]
    struct Request {
        query_execution_id: String,
        #[serde(default)]
        max_results: Option<i64>,
        #[serde(default)]
        parameters: Option<Vec<String>>,
        #[serde(default)]
        result_configuration: Option<Nested>,
        #[serde(default)]
        small: Option<u8>,
    }

    async fn body_of(response: Response) -> Value {
        let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }

    async fn failure(body: &str) -> Value {
        match parse::<Request>(&Bytes::from(body.to_string())) {
            Ok(_) => panic!("成功してしまった: {body}"),
            Err(error) => body_of(*error).await,
        }
    }

    fn serialization(message: Option<&str>) -> Value {
        match message {
            Some(message) => {
                serde_json::json!({ "__type": "SerializationException", "Message": message })
            }
            None => serde_json::json!({ "__type": "SerializationException" }),
        }
    }

    #[tokio::test]
    async fn 実測した組み合わせの文言を出す() {
        for (body, message) in [
            (
                r#"{"QueryExecutionId":"x","MaxResults":"1"}"#,
                "STRING_VALUE can not be converted to an Integer",
            ),
            (
                r#"{"QueryExecutionId":"x","MaxResults":true}"#,
                "TRUE_VALUE can not be converted to an Integer",
            ),
            (
                r#"{"QueryExecutionId":"x","MaxResults":[1]}"#,
                "Start of list found where not expected",
            ),
            (
                r#"{"QueryExecutionId":"x","MaxResults":{"a":1}}"#,
                "Start of structure or map found where not expected.",
            ),
            (
                r#"{"QueryExecutionId":1}"#,
                "NUMBER_VALUE can not be converted to a String",
            ),
            (
                r#"{"QueryExecutionId":true}"#,
                "TRUE_VALUE can not be converted to a String",
            ),
            (
                r#"{"QueryExecutionId":["x"]}"#,
                "Start of list found where not expected",
            ),
            (
                r#"{"QueryExecutionId":{"a":1}}"#,
                "Start of structure or map found where not expected.",
            ),
            (
                r#"{"QueryExecutionId":"x","Parameters":[1]}"#,
                "NUMBER_VALUE can not be converted to a String",
            ),
            (
                r#"{"QueryExecutionId":"x","Parameters":"x"}"#,
                "Expected list or null",
            ),
            (
                r#"{"QueryExecutionId":"x","ResultConfiguration":"x"}"#,
                "Expected null",
            ),
            ("[]", "Start of list found where not expected"),
        ] {
            assert_eq!(failure(body).await, serialization(Some(message)), "{body}");
        }
    }

    #[tokio::test]
    async fn 未実測の組み合わせと本文の異常は_message_無し() {
        for body in [
            r#"{"QueryExecutionId":"x","MaxResults":false}"#,
            r#"{"QueryExecutionId":"x","MaxResults":1.5}"#,
            r#"{"QueryExecutionId":"x","Parameters":{}}"#,
            r#"{"QueryExecutionId":"x","Parameters":1}"#,
            r#"{"QueryExecutionId":"x","ResultConfiguration":1}"#,
            r#"{"QueryExecutionId":"x","Small":300}"#, // invalid value（範囲外）
            "{",
            "",
            "null",
            "\"x\"",
            "1",
            r#"{"QueryExecutionId":"x",}"#,
        ] {
            assert_eq!(failure(body).await, serialization(None), "{body}");
        }
    }

    #[tokio::test]
    async fn 必須の欠落と_null_は_lower_camel_の項目名で枠組みの検証になる() {
        for body in ["{}", r#"{"QueryExecutionId":null}"#] {
            let error = failure(body).await;
            assert_eq!(error["__type"], "InvalidRequestException", "{body}");
            assert_eq!(error["AthenaErrorCode"], "INVALID_INPUT", "{body}");
            assert_eq!(
                error["Message"],
                "1 validation error detected: Value null at 'queryExecutionId' failed to satisfy constraint: Member must not be null",
                "{body}"
            );
        }
    }

    #[test]
    fn null_は入れ子でも無いのと同じで未知のキーは無視する() {
        let body = r#"{"QueryExecutionId":"x","MaxResults":null,"ResultConfiguration":{"OutputLocation":null},"Foo":1}"#;
        let request = match parse::<Request>(&Bytes::from(body)) {
            Ok(request) => request,
            Err(_) => panic!("失敗した"),
        };
        assert_eq!(request.query_execution_id, "x");
        assert_eq!(request.max_results, None);
        assert!(
            request
                .result_configuration
                .unwrap()
                .output_location
                .is_none()
        );
        assert!(request.parameters.is_none());
        assert!(request.small.is_none());
    }
}
