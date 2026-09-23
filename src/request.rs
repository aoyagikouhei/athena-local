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
        // 配列の要素の null も本物は受け付けて先へ進む（2026-09-23 実測。#87）。
        Value::Array(items) => Value::Array(
            items
                .into_iter()
                .filter(|v| !v.is_null())
                .map(strip_nulls)
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

/// 型違いの文言（2026-09-23 に 2 ラウンドで実測した組み合わせ。#84・#87）。未実測なら `None`。
///
/// `found` は serde の `invalid type: <found>, expected <expected>` の `<found>`
/// （`string "…"`／`integer `…``／`floating point `…``／`boolean `true``／`sequence`／`map` など）、
/// `expected` は `<expected>`（`i64`／`a string`／`a sequence`／`struct ResultConfiguration` など）。
/// 本物の文言は JSON の値の種類（`STRING_VALUE`／`NUMBER_VALUE`／`TRUE_VALUE`／`FALSE_VALUE`／配列／オブジェクト）と
/// 目的の型（Integer／String／配列／構造体）で決まる。小数 → Integer だけは本物が切り捨てて通すので揃えず `None`。
fn type_mismatch(found: &str, expected: &str) -> Option<String> {
    const LIST: &str = "Start of list found where not expected";
    const MAP: &str = "Start of structure or map found where not expected.";
    let scalar = if found.starts_with("string ") {
        Some("STRING_VALUE")
    } else if found.starts_with("integer ") || found.starts_with("floating point ") {
        Some("NUMBER_VALUE")
    } else if found == "boolean `true`" {
        Some("TRUE_VALUE")
    } else if found == "boolean `false`" {
        Some("FALSE_VALUE")
    } else {
        None
    };
    let integer = expected.starts_with('i') || expected.starts_with('u');
    if integer || expected == "a string" {
        let target = if integer { "an Integer" } else { "a String" };
        return match found {
            "sequence" => Some(LIST.to_string()),
            "map" => Some(MAP.to_string()),
            // 小数 → Integer は本物が切り捨てて通す（揃えない）。文字列 → String は正常なので来ない。
            _ if integer && found.starts_with("floating point ") => None,
            _ => scalar.map(|value| format!("{value} can not be converted to {target}")),
        };
    }
    if expected == "a sequence" {
        return match found {
            "map" => Some(MAP.to_string()),
            _ => scalar.map(|_| "Expected list or null".to_string()),
        };
    }
    if expected.starts_with("struct ") {
        // 配列 → 構造体は serde の derive が位置順に読んで通すので、ここには来ない。
        return scalar.map(|_| "Expected null".to_string());
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
            // 2026-09-23 の 2 ラウンド目（#87）で測った組み合わせ。
            (
                r#"{"QueryExecutionId":"x","MaxResults":false}"#,
                "FALSE_VALUE can not be converted to an Integer",
            ),
            (
                r#"{"QueryExecutionId":false}"#,
                "FALSE_VALUE can not be converted to a String",
            ),
            (
                r#"{"QueryExecutionId":1.5}"#,
                "NUMBER_VALUE can not be converted to a String",
            ),
            (
                r#"{"QueryExecutionId":"x","Parameters":1}"#,
                "Expected list or null",
            ),
            (
                r#"{"QueryExecutionId":"x","Parameters":true}"#,
                "Expected list or null",
            ),
            (
                r#"{"QueryExecutionId":"x","Parameters":{}}"#,
                "Start of structure or map found where not expected.",
            ),
            (
                r#"{"QueryExecutionId":"x","Parameters":[["a"]]}"#,
                "Start of list found where not expected",
            ),
            (
                r#"{"QueryExecutionId":"x","ResultConfiguration":1}"#,
                "Expected null",
            ),
            (
                r#"{"QueryExecutionId":"x","ResultConfiguration":true}"#,
                "Expected null",
            ),
            (
                r#"{"QueryExecutionId":"x","ResultConfiguration":{"OutputLocation":1}}"#,
                "NUMBER_VALUE can not be converted to a String",
            ),
        ] {
            assert_eq!(failure(body).await, serialization(Some(message)), "{body}");
        }
    }

    #[tokio::test]
    async fn 未実測の組み合わせと本文の異常は_message_無し() {
        for body in [
            // 小数 → Integer は本物が切り捨てて通す（揃えない）ので、文言は出さない。
            r#"{"QueryExecutionId":"x","MaxResults":1.5}"#,
            r#"{"QueryExecutionId":"x","Small":300}"#, // invalid value（範囲外）
            "{",
            "",
            "null",
            "\"x\"",
            "1",
            "true",
            r#"{"QueryExecutionId":"x",}"#,
            r#"{"QueryExecutionId":"x"} {}"#, // 末尾にゴミ
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
    fn null_は入れ子でも配列の要素でも無いのと同じで未知のキーは無視する() {
        let body = r#"{"QueryExecutionId":"x","MaxResults":null,"ResultConfiguration":{"OutputLocation":null},"Parameters":["a",null],"Foo":1}"#;
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
        assert_eq!(request.parameters.unwrap(), ["a"]);
        assert!(request.small.is_none());
    }
}
