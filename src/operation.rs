//! Athena のオペレーション。実行は Trino に委ね、状態は Store に持つ。

use axum::body::Bytes;
use axum::response::Response;
use uuid::Uuid;

use crate::athena::{
    GetQueryExecutionRequest, GetQueryExecutionResponse, GetQueryResultsRequest,
    GetQueryResultsResponse, QueryExecution, QueryExecutionContext, ResultConfiguration,
    StartQueryExecutionRequest, StartQueryExecutionResponse, Statistics, Status,
    StopQueryExecutionRequest, StopQueryExecutionResponse,
};
use crate::config::{Config, ResultsMode};
use crate::convert;
use crate::handler::App;
use crate::response::{invalid_request, invalid_request_with_code, ok, parse};
use crate::results::{self, ResultFile, ResultLocation};
use crate::statement;
use crate::store::{CancelOutcome, Execution, State};
use crate::trino::{Outcome, QueryError, Trino};

const DEFAULT_MAX_RESULTS: usize = 1000;

/// OutputLocation も既定も無いときの本物の文言（未実測）。
const NO_OUTPUT_LOCATION: &str = "No output location provided. An output location is required either through the Workgroup result configuration setting or as an API input.";

pub fn start_query_execution(app: &App, body: &Bytes) -> Response {
    let request: StartQueryExecutionRequest = match parse(body) {
        Ok(request) => request,
        Err(response) => return *response,
    };

    let context = request.query_execution_context.unwrap_or_default();
    let catalog = context
        .catalog
        .or_else(|| app.config.default_catalog.clone());
    let database = context
        .database
        .or_else(|| app.config.default_database.clone());

    let id = Uuid::new_v4().to_string();
    let result_location = match result_location(
        app,
        request.result_configuration,
        &request.query_string,
        &id,
    ) {
        Ok(location) => location,
        Err(response) => return *response,
    };

    app.store.submit(
        &id,
        &request.query_string,
        request.execution_parameters.unwrap_or_default(),
        catalog,
        database,
        result_location,
    );
    spawn_query(app.clone(), id.clone());

    ok(&StartQueryExecutionResponse {
        query_execution_id: id,
    })
}

/// OutputLocation から結果の置き場所を決める。本物と同じく s3:// の形でない値は受け付けない
/// （結果を書かないモードでも同じ）。書くモードでは、OutputLocation も既定も無ければ受け付けない。
fn result_location(
    app: &App,
    configuration: Option<ResultConfiguration>,
    query: &str,
    id: &str,
) -> Result<Option<ResultLocation>, Box<Response>> {
    let requested = configuration.and_then(|configuration| configuration.output_location);
    let output_location = match (requested, &app.config.results) {
        (Some(location), _) => location,
        (None, ResultsMode::S3(settings)) => match &settings.default_output_location {
            Some(location) => location.clone(),
            None => return Err(Box::new(invalid_request(NO_OUTPUT_LOCATION))),
        },
        (None, ResultsMode::None) => return Ok(None),
    };

    // 文言とコードは 2026-09-14 に本番 Athena で実測したもの。
    ResultLocation::new(&output_location, id, ResultFile::of(query))
        .map(Some)
        .ok_or_else(|| {
            Box::new(invalid_request_with_code(
                "outputLocation is not a valid S3 path.",
                "INVALID_INPUT",
            ))
        })
}

/// 本物と同じく実行はバックグラウンドで進み、状態はポーリングで見る。
fn spawn_query(app: App, id: String) {
    tokio::spawn(async move {
        let Some(execution) = app.store.get(&id) else {
            return;
        };
        // 投入直後に止められていれば Trino には何も送らない。
        if !app.store.mark_running(&id) {
            return;
        }

        let outcome = match run(&app.trino, &app.config, &execution).await {
            Ok(outcome) => write_result(&app, &execution, outcome).await,
            Err(error) => Err(error.to_string()),
        };
        // 途中で止められていれば CANCELLED が先に書かれているので、finish は何もしない。
        app.store.finish(&id, outcome);
    });
}

/// 結果 CSV を置いてから結果を返す。SUCCEEDED にするのは書き終わってからにする
/// （クライアントは SUCCEEDED を見た直後に S3 を読みに行く）。書けなければ FAILED。
async fn write_result(
    app: &App,
    execution: &Execution,
    outcome: Outcome,
) -> Result<Outcome, String> {
    let (Some(writer), Some(location)) = (&app.results, &execution.result_location) else {
        return Ok(outcome);
    };
    // 置くのは SELECT の結果だけ。DML / DDL が置くファイル（manifest や .txt）は作らない。
    // 途中で止められていれば書かない（CANCELLED の本物も何も置かない）。
    if location.file != ResultFile::Csv
        || outcome.update_count.is_some()
        || execution.cancel.is_requested()
    {
        return Ok(outcome);
    }

    writer.put(location, results::to_csv(&outcome)).await?;
    Ok(outcome)
}

/// 値を分類して EXECUTE IMMEDIATE で包んで実行する。
/// パラメータが無ければ分類は走らず、SQL はそのまま送られる（to_trino_sql が判断する）。
async fn run(trino: &Trino, config: &Config, execution: &Execution) -> Result<Outcome, QueryError> {
    // Trino に送るのは別名を当てた名前。実行情報には受け取った名前が残る。
    let catalog = execution
        .catalog
        .as_deref()
        .map(|catalog| config.trino_catalog(catalog));
    let database = execution.database.as_deref();
    // 分類の問い合わせにも本体にも同じ取り消し要求を渡す。
    let cancel = &execution.cancel;

    // 分類も本体と同じカタログ・スキーマで問い合わせ、関数の解決先を揃える。
    let mut bound = Vec::with_capacity(execution.execution_parameters.len());
    for value in &execution.execution_parameters {
        let probe = trino
            .execute(&statement::probe_sql(value), catalog, database, cancel)
            .await;
        bound.push(statement::bind(value, &probe));
    }

    let sql = statement::to_trino_sql(&execution.query, &bound);
    match trino.execute(&sql, catalog, database, cancel).await {
        Err(error) if statement::is_unused_parameters(&error) => {
            trino
                .execute(&execution.query, catalog, database, cancel)
                .await
        }
        result => result,
    }
}

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

    let rows = convert::all_rows(&outcome);
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
        update_count: outcome.update_count,
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
        statement_type: statement_type(&execution.query).to_string(),
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
        },
        statistics: Statistics::default(),
        work_group: "primary".to_string(),
    }
}

fn statement_type(query: &str) -> &'static str {
    let head = query
        .split_whitespace()
        .next()
        .unwrap_or_default()
        .to_uppercase();

    match head.as_str() {
        "SELECT" | "WITH" | "INSERT" | "UPDATE" | "DELETE" | "MERGE" => "DML",
        "CREATE" | "DROP" | "ALTER" => "DDL",
        _ => "UTILITY",
    }
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
    fn statement_type_は先頭のキーワードで決まる() {
        assert_eq!(statement_type("SELECT 1"), "DML");
        assert_eq!(statement_type("  insert into t values (1)"), "DML");
        assert_eq!(statement_type("MERGE INTO t USING s ON x"), "DML");
        assert_eq!(statement_type("CREATE TABLE t AS SELECT 1"), "DDL");
        assert_eq!(statement_type("DROP TABLE t"), "DDL");
        assert_eq!(statement_type("SET SESSION x = 1"), "UTILITY");
        assert_eq!(statement_type(""), "UTILITY");
    }
}
