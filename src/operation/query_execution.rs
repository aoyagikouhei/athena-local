//! GetQueryExecution・GetQueryResults・StopQueryExecution と、その周りの集計。

use axum::body::Bytes;
use axum::response::Response;

use crate::athena::{
    AthenaError, GetQueryExecutionRequest, GetQueryExecutionResponse, GetQueryResultsRequest,
    GetQueryResultsResponse, QueryExecution, QueryExecutionContext, ResultConfiguration,
    Statistics, Status, StopQueryExecutionRequest, StopQueryExecutionResponse,
};
use crate::convert;
use crate::handler::App;
use crate::response::{invalid_request_with_code, ok, parse};
use crate::store::{CancelOutcome, Execution, State};
use crate::trino::Outcome;

const DEFAULT_MAX_RESULTS: usize = 1000;

pub fn get_query_execution(app: &App, body: &Bytes) -> Response {
    let request: GetQueryExecutionRequest = match parse(body) {
        Ok(request) => request,
        Err(response) => return *response,
    };

    let Some(execution) = app.store.get(&request.query_execution_id) else {
        return unknown_execution(&request.query_execution_id);
    };

    ok(&GetQueryExecutionResponse {
        query_execution: to_query_execution(&request.query_execution_id, &execution),
    })
}

pub fn get_query_results(app: &App, body: &Bytes) -> Response {
    let request: GetQueryResultsRequest = match parse(body) {
        Ok(request) => request,
        Err(response) => return *response,
    };

    let Some(execution) = app.store.get(&request.query_execution_id) else {
        return unknown_execution(&request.query_execution_id);
    };
    let Some(outcome) = execution.result else {
        return not_succeeded(execution.state);
    };

    let mut rows = convert::all_rows(&outcome);
    // 先頭の列名行を返すのは DML（SELECT / EXPLAIN）だけ。UTILITY（SHOW / DESCRIBE）では本物は
    // データの 1 行目から返す（2026-09-15〜22 の実測 5 ラウンドの応答を読み直して確認。#60）。
    // 例外は SHOW FUNCTIONS で、UTILITY だが結果ファイルが `<id>.csv` の SELECT の形なので
    // 列名行も返す（2026-09-23 実測。#80）。
    // 結果ファイル（results::to_csv / to_text）は列名行込みの all_rows を使い続けるので、ここで外す。
    if super::classification::statement_type(&execution.query) != "DML"
        && super::classification::substatement_type(&execution.query) != Some("SHOW_FUNCTIONS")
        && !rows.is_empty()
    {
        rows.remove(0);
    }
    let offset = request
        .next_token
        .and_then(|token| token.parse::<usize>().ok())
        .unwrap_or(0)
        .min(rows.len());
    let limit = request
        .max_results
        .map(|max| max.max(1) as usize)
        .unwrap_or(DEFAULT_MAX_RESULTS);
    let end = (offset + limit).min(rows.len());

    ok(&GetQueryResultsResponse {
        result_set: convert::result_set(&outcome, &rows[offset..end]),
        update_count: update_count(&execution.query, &outcome),
        next_token: (end < rows.len()).then(|| end.to_string()),
    })
}

/// 状態は StopQueryExecution の中で同期に CANCELLED にする。
/// 実行中のタスクは次のページ境界で取り消し要求を見て、Trino に DELETE を送る。
pub fn stop_query_execution(app: &App, body: &Bytes) -> Response {
    let request: StopQueryExecutionRequest = match parse(body) {
        Ok(request) => request,
        Err(response) => return *response,
    };

    match app.store.cancel(&request.query_execution_id) {
        CancelOutcome::NotFound => unknown_execution(&request.query_execution_id),
        // 終わったクエリを止めても成功で、何も変わらない（本物と同じ）。
        CancelOutcome::Cancelled | CancelOutcome::AlreadyFinished => {
            ok(&StopQueryExecutionResponse {})
        }
    }
}

/// 結果が無いときの GetQueryResults のエラー。文言とコードは 2026-09-14 に本番 Athena で実測したもの。
fn not_succeeded(state: State) -> Response {
    const INVALID_STATE: &str = "INVALID_QUERY_EXECUTION_STATE";
    match state {
        // 止めたクエリは FAILED と違い「結果が無い」と返る。
        State::Cancelled => invalid_request_with_code("Could not find results", "RESULT_NOT_FOUND"),
        State::Failed => invalid_request_with_code(
            format!(
                "Query did not finish successfully. Final query state: {}",
                state.as_str()
            ),
            INVALID_STATE,
        ),
        _ => invalid_request_with_code(
            format!(
                "Query has not yet finished. Current state: {}",
                state.as_str()
            ),
            INVALID_STATE,
        ),
    }
}

fn to_query_execution(id: &str, execution: &Execution) -> QueryExecution {
    QueryExecution {
        query_execution_id: id.to_string(),
        query: execution.query.clone(),
        statement_type: super::classification::statement_type(&execution.query).to_string(),
        substatement_type: super::classification::substatement_type(&execution.query)
            .map(str::to_string),
        result_configuration: execution.result_location.as_ref().map(|location| {
            ResultConfiguration {
                output_location: Some(location.uri()),
            }
        }),
        query_execution_context: QueryExecutionContext {
            database: execution.database.clone(),
            catalog: execution.catalog.clone(),
        },
        status: Status {
            state: execution.state.as_str().to_string(),
            state_change_reason: execution.state_change_reason.clone(),
            submission_date_time: execution.submitted_at,
            completion_date_time: execution.completed_at,
            athena_error: execution.failure.as_ref().map(|failure| AthenaError {
                error_category: failure.category,
                error_type: failure.error_type,
                retryable: failure.retryable,
                error_message: failure.reason.clone(),
            }),
        },
        statistics: statistics(
            execution.submitted_at,
            execution.started_at,
            execution.completed_at,
        ),
        work_group: execution.work_group.clone(),
    }
}

/// 投入 → 実行開始 → 完了の時刻から時間を出す。まだ来ていない区切りの時間は 0。
/// 実行時間には、パラメータの分類の問い合わせと結果ファイルと `.metadata` と失敗の理由の書き込みも入る
/// （どれも外を待つ時間）。
/// ミリ秒に丸めてから引くので、待ち時間 + 実行時間 = 全体 が必ず成り立つ。
fn statistics(submitted_at: f64, started_at: Option<f64>, completed_at: Option<f64>) -> Statistics {
    let millis = |seconds: f64| (seconds * 1000.0).round() as i64;
    let submitted = millis(submitted_at);
    let started = started_at.map(millis);
    let completed = completed_at.map(millis);

    Statistics {
        // 実行に進まずに止められたら、止めた時点までが待ち時間。
        query_queue_time_in_millis: started.or(completed).map_or(0, |end| end - submitted),
        engine_execution_time_in_millis: match (started, completed) {
            (Some(started), Some(completed)) => completed - started,
            _ => 0,
        },
        total_execution_time_in_millis: completed.map_or(0, |completed| completed - submitted),
        data_scanned_in_bytes: 0,
    }
}

/// GetQueryResults の UpdateCount。本物は SELECT と SHOW でも 0 を返し、DDL では null を返す
/// （2026-09-14 実測。SDK から見て null と省略は同じなので、DDL は省く）。
/// DML と CTAS は Trino が返す件数をそのまま載せる。
fn update_count(query: &str, outcome: &Outcome) -> Option<i64> {
    outcome
        .update_count
        .or_else(|| (super::classification::statement_type(query) != "DDL").then_some(0))
}

fn unknown_execution(id: &str) -> Response {
    invalid_request_with_code(
        format!("QueryExecution {id} was not found"),
        "QUERY_EXECUTION_NOT_FOUND",
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 統計は待ち時間と実行時間に分かれ足すと全体になる() {
        assert_eq!(
            statistics(10.0, Some(10.25), Some(11.0)),
            Statistics {
                query_queue_time_in_millis: 250,
                engine_execution_time_in_millis: 750,
                total_execution_time_in_millis: 1000,
                data_scanned_in_bytes: 0,
            }
        );
    }

    #[test]
    fn 実行に進まずに止められたら全体が待ち時間になる() {
        assert_eq!(
            statistics(10.0, None, Some(10.5)),
            Statistics {
                query_queue_time_in_millis: 500,
                engine_execution_time_in_millis: 0,
                total_execution_time_in_millis: 500,
                data_scanned_in_bytes: 0,
            }
        );
    }

    #[test]
    fn まだ来ていない区切りの時間は_0() {
        assert_eq!(statistics(10.0, None, None), Statistics::default());
        assert_eq!(
            statistics(10.0, Some(10.1), None),
            Statistics {
                query_queue_time_in_millis: 100,
                ..Statistics::default()
            }
        );
    }

    #[test]
    fn update_count_は件数が無ければ_ddl_以外で_0_になる() {
        let counted = Outcome {
            update_count: Some(3),
            ..Outcome::default()
        };
        assert_eq!(update_count("INSERT INTO t VALUES (1)", &counted), Some(3));
        assert_eq!(
            update_count("CREATE TABLE c AS SELECT 1", &counted),
            Some(3)
        );

        let uncounted = Outcome::default();
        assert_eq!(update_count("SELECT 1", &uncounted), Some(0));
        assert_eq!(update_count("SHOW TABLES", &uncounted), Some(0));
        assert_eq!(update_count("CREATE TABLE t (i int)", &uncounted), None);
        assert_eq!(update_count("DROP TABLE t", &uncounted), None);
    }
}
