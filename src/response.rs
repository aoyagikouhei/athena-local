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
pub fn error(code: &str, message: impl Into<String>) -> Response {
    let body = json!({ "__type": code, "message": message.into() });
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
