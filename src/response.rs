//! awsJson1.1 のレスポンス組み立て。

use axum::body::Bytes;
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::json;

const CONTENT_TYPE: &str = "application/x-amz-json-1.1";

pub fn ok<T: Serialize>(body: &T) -> Response {
    match serde_json::to_vec(body) {
        Ok(payload) => (
            StatusCode::OK,
            [(header::CONTENT_TYPE, CONTENT_TYPE)],
            payload,
        )
            .into_response(),
        Err(e) => error("InternalServerException", format!("応答を作れません: {e}")),
    }
}

/// SDK は __type（または x-amzn-errortype）でエラーの種類を判別する。
///
/// 本文のキーは `Message`（M が大文字。2026-09-17 実測）。この経路（パース失敗・
/// 未対応オペレーション・InternalServerException など AthenaErrorCode が無いもの）の
/// 本物の応答は未実測なので、`ErrorCode` は付けない（推測で埋めない）。
pub fn error(code: &str, message: impl Into<String>) -> Response {
    error_body(code, json!({ "__type": code, "Message": message.into() }))
}

/// 本物の InvalidRequestException は、より細かい理由を AthenaErrorCode に載せる。
///
/// 本文は `{"__type","AthenaErrorCode","ErrorCode","Message"}` の 4 キー（2026-09-17
/// 実測。`ErrorCode` は `AthenaErrorCode` と同じ値で別に付く）。
pub fn invalid_request_with_code(message: impl Into<String>, athena_error_code: &str) -> Response {
    let code = "InvalidRequestException";
    error_body(
        code,
        json!({
            "__type": code,
            "AthenaErrorCode": athena_error_code,
            "ErrorCode": athena_error_code,
            "Message": message.into(),
        }),
    )
}

fn error_body(code: &str, body: serde_json::Value) -> Response {
    let mut response = (
        StatusCode::BAD_REQUEST,
        [(header::CONTENT_TYPE, CONTENT_TYPE)],
        serde_json::to_vec(&body).unwrap_or_default(),
    )
        .into_response();

    if let Ok(value) = HeaderValue::from_str(code) {
        response.headers_mut().insert("x-amzn-errortype", value);
    }

    response
}

pub fn invalid_request(message: impl Into<String>) -> Response {
    error("InvalidRequestException", message)
}

/// Response は大きいので Box で返す（clippy::result_large_err）。
pub fn parse<T: DeserializeOwned>(body: &Bytes) -> Result<T, Box<Response>> {
    serde_json::from_slice(body)
        .map_err(|e| Box::new(invalid_request(format!("リクエストを解釈できません: {e}"))))
}
