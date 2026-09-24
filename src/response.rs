//! awsJson1.1 のレスポンス組み立て。

use axum::http::{HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use serde::Serialize;
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
/// 本文のキーは `Message`（M が大文字。2026-09-17 実測）。AthenaErrorCode の無い本物のエラー
/// （`SerializationException`・`UnknownOperationException`。2026-09-23 実測）は `ErrorCode` も
/// 持たないので付けない。`InternalServerException` の本物の形は未実測。
pub fn error(code: &str, message: impl Into<String>) -> Response {
    error_body(code, json!({ "__type": code, "Message": message.into() }))
}

/// `__type` だけの本文（本物の `UnknownOperationException` と、本文が壊れているときの
/// `SerializationException` はこの形。2026-09-23 実測）。
pub fn bare_error(code: &str) -> Response {
    error_body(code, json!({ "__type": code }))
}

/// 本文の解釈に失敗したときの本物の応答（2026-09-23 実測）。AthenaErrorCode は無く、
/// `Message` は入力の形によって有無が分かれる（実測していない組み合わせは付けない）。
pub fn serialization_error(message: Option<String>) -> Response {
    let code = "SerializationException";
    match message {
        Some(message) => error(code, message),
        None => bare_error(code),
    }
}

/// 枠組みの検証（API 定義の制約違反）の文言。件数を先頭に置き、複数なら `; ` で並べる
/// （1 件は 2026-09-18、2 件は 2026-09-23 実測。`errors` と複数形になる）。
pub fn validation_errors(violations: &[String]) -> String {
    let noun = if violations.len() == 1 {
        "error"
    } else {
        "errors"
    };
    format!(
        "{} validation {noun} detected: {}",
        violations.len(),
        violations.join("; ")
    )
}

/// 本物の InvalidRequestException は、より細かい理由を AthenaErrorCode に載せる。
///
/// 本文は `{"__type","AthenaErrorCode","ErrorCode","Message"}` の 4 キー（2026-09-17
/// 実測。`ErrorCode` は `AthenaErrorCode` と同じ値で別に付く。構文エラーの `MALFORMED_QUERY`
/// でも同じ形。2026-09-24 実測）。
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
