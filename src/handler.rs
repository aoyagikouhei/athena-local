//! Athena API のディスパッチ。awsJson1.1 なので POST / の 1 本で、
//! X-Amz-Target ヘッダでオペレーションを見分ける。SigV4 署名は検証しない。

use std::sync::Arc;

use axum::body::Bytes;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Response;

use crate::config::Config;
use crate::operation;
use crate::response::bare_error;
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

/// ヘッダが無い・前置き `AmazonAthena.` が無い・名前が違う（大文字小文字を含む）は、本物と同じく
/// すべて `{"__type":"UnknownOperationException"}` だけの 400（2026-09-23 実測。Message 無し）。
pub(crate) async fn dispatch(State(app): State<App>, headers: HeaderMap, body: Bytes) -> Response {
    let Some(operation) = operation_name(&headers) else {
        return unknown_operation();
    };

    match operation.as_str() {
        "StartQueryExecution" => operation::start_query_execution(&app, &body).await,
        "GetQueryExecution" => operation::get_query_execution(&app, &body),
        "GetQueryResults" => operation::get_query_results(&app, &body),
        "StopQueryExecution" => operation::stop_query_execution(&app, &body),
        "GetWorkGroup" => operation::get_work_group(&app, &body),
        "ListWorkGroups" => operation::list_work_groups(&app, &body),
        _ => unknown_operation(),
    }
}

fn unknown_operation() -> Response {
    bare_error("UnknownOperationException")
}

/// 前置きは必須（本物は `ListWorkGroups` だけの値も弾く。2026-09-23 実測）。
fn operation_name(headers: &HeaderMap) -> Option<String> {
    let target = headers.get("x-amz-target")?.to_str().ok()?;
    Some(target.strip_prefix(TARGET_PREFIX)?.to_string())
}
