//! StartQueryExecution の受付、Trino での実行。

use axum::body::Bytes;
use axum::response::Response;
use uuid::Uuid;

use crate::athena::{StartQueryExecutionRequest, StartQueryExecutionResponse};
use crate::config::DEFAULT_WORK_GROUP;
use crate::handler::App;
use crate::request::parse;
use crate::response::{invalid_request_with_code, ok};
use crate::store::{Submission, SubmitOutcome};

use super::background_execution::spawn_query;
use super::start_checks::{Decision, decide};
use super::start_request::{
    client_request_token, context_defaults, result_location, single_statement,
};

/// 同じ ClientRequestToken の再送で衝突したときの文言（2026-09-17 実測）。
const IDEMPOTENT_MISMATCH: &str = "Idempotent parameters do not match";

pub async fn start_query_execution(app: &App, body: &Bytes) -> Response {
    let request: StartQueryExecutionRequest = match parse(body) {
        Ok(request) => request,
        Err(response) => return *response,
    };
    // 検証の順は本物と同じトークン → OutputLocation → 構文（2026-09-24 実測）。
    let token = match client_request_token(&request) {
        Ok(token) => token,
        Err(response) => return *response,
    };

    let context = request.query_execution_context.unwrap_or_default();
    let (catalog, database, fingerprint) = context_defaults(
        context,
        &request.query_string,
        &request.result_configuration,
    );
    // 冪等の比較は受け取ったままの文、それ以外は `;` と前後の空白を落とした文で行う（2026-09-26 実測。#240）。
    let statement = single_statement(&request.query_string);
    let id = Uuid::new_v4().to_string();
    let result_location = match result_location(
        app,
        request.result_configuration,
        statement.as_deref().unwrap_or(&request.query_string),
        &id,
    ) {
        Ok(location) => location,
        Err(response) => return *response,
    };

    // 複数の文と空の文は構文エラーより先に弾く（2026-09-26 実測。#228・#240）。トークン・OutputLocation との順は
    // 測っていない。
    let query = match statement {
        Ok(statement) => statement.to_string(),
        Err(message) => return invalid_request_with_code(message, "MALFORMED_QUERY"),
    };
    let Decision {
        statement,
        database,
        immediate_failure,
        reported,
    } = match decide(
        app,
        query,
        catalog.as_deref(),
        database,
        result_location.as_ref(),
    )
    .await
    {
        Ok(decision) => decision,
        Err(response) => return *response,
    };

    let work_group = request
        .work_group
        .unwrap_or_else(|| DEFAULT_WORK_GROUP.to_string());

    let outcome = app.store.submit(
        &id,
        Submission {
            query: statement,
            execution_parameters: request.execution_parameters.unwrap_or_default(),
            catalog,
            database,
            result_location,
            work_group,
            token,
            fingerprint,
            immediate_failure,
            reported,
        },
    );

    submit_response(app, id, outcome)
}

/// submit の結果を応答に変換する。Created のときだけ実行を始める。
/// Existing で spawn_query を呼んでも mark_running の「QUEUED からだけ進める」ガードが
/// 二重実行を弾く（ミューテーション確認で実測）が、既存の実行に手を触れないのが本物の意味。
fn submit_response(app: &App, id: String, outcome: SubmitOutcome) -> Response {
    match outcome {
        SubmitOutcome::Created => {
            spawn_query(app.clone(), id.clone());
            ok(&StartQueryExecutionResponse {
                query_execution_id: id,
            })
        }
        SubmitOutcome::Existing(existing) => ok(&StartQueryExecutionResponse {
            query_execution_id: existing,
        }),
        SubmitOutcome::Conflict => {
            invalid_request_with_code(IDEMPOTENT_MISMATCH, "IDEMPOTENT_PARAMETER_MISMATCH")
        }
    }
}
