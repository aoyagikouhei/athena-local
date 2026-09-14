//! Athena API のディスパッチ。awsJson1.1 なので POST / の 1 本で、
//! X-Amz-Target ヘッダでオペレーションを見分ける。SigV4 署名は検証しない。

use std::sync::Arc;

use axum::body::Bytes;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;

use crate::config::Config;
use crate::operation;
use crate::response::invalid_request;
use crate::results::ResultWriter;
use crate::store::Store;
use crate::trino::Trino;

const TARGET_PREFIX: &str = "AmazonAthena.";

#[derive(Clone)]
pub struct App {
    pub store: Store,
    pub trino: Arc<Trino>,
    pub config: Arc<Config>,
    /// ATHENA_LOCAL_RESULTS=s3 のときだけある。
    pub results: Option<Arc<ResultWriter>>,
}

pub(crate) async fn dispatch(State(app): State<App>, headers: HeaderMap, body: Bytes) -> Response {
    let Some(operation) = operation_name(&headers) else {
        return invalid_request("X-Amz-Target がありません");
    };

    match operation.as_str() {
        "StartQueryExecution" => operation::start_query_execution(&app, &body),
        "GetQueryExecution" => operation::get_query_execution(&app, &body),
        "GetQueryResults" => operation::get_query_results(&app, &body),
        "StopQueryExecution" => operation::stop_query_execution(&app, &body),
        other => invalid_request(format!("未対応のオペレーションです: {other}")),
    }
}

fn operation_name(headers: &HeaderMap) -> Option<String> {
    let target = headers.get("x-amz-target")?.to_str().ok()?;
    Some(target.trim_start_matches(TARGET_PREFIX).to_string())
}
