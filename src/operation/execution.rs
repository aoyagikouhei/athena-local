//! StartQueryExecution の受付、Trino での実行、結果ファイルと `.metadata` の書き込み。

use axum::body::Bytes;
use axum::response::Response;
use uuid::Uuid;

use crate::athena::{
    QueryExecutionContext, ResultConfiguration, StartQueryExecutionRequest,
    StartQueryExecutionResponse,
};
use crate::catalog::alias_qualified_names;
use crate::config::{Config, DEFAULT_WORK_GROUP, ResultsMode};
use crate::convert;
use crate::failure::Failure;
use crate::handler::App;
use crate::metadata;
use crate::response::{invalid_request_with_code, ok, parse};
use crate::results::{self, ResultFile, ResultLocation};
use crate::statement;
use crate::store::{Execution, Fingerprint, Submission, SubmitOutcome};
use crate::trino::{Outcome, QueryError, Trino};

use super::table_format::{self, EngineDdl};

/// DROP TABLE × Iceberg など、列が無くても本体・`.metadata` を置く DDL の Content-Type
/// （2026-09-20 実測。本体も `.metadata` も application/octet-stream）。
const ENGINE_DDL_CONTENT_TYPE: &str = "application/octet-stream";

/// OutputLocation も既定も無いときの本物の文言（2026-09-14 実測。"for  your" の空白 2 つも本物のまま）。
const NO_OUTPUT_LOCATION: &str = "No output location provided. You did not provide an output location for  your query results. Either specify an S3 bucket location or enable Athena managed query results in your workgroup settings.";

/// 同じ ClientRequestToken の再送で衝突したときの文言（2026-09-17 実測）。
const IDEMPOTENT_MISMATCH: &str = "Idempotent parameters do not match";

/// ClientRequestToken が無い（キーが無い）ときの文言（2026-09-17、4 回目の実測）。
const TOKEN_MISSING: &str = "clientRequestToken is null or empty";

/// ClientRequestToken が 32 文字未満（空文字を含む）のときの文言（2026-09-17、3 回目の実測）。
const TOKEN_TOO_SHORT: &str = "1 validation error detected: Value at 'clientRequestToken' failed to satisfy constraint: Member must have length greater than or equal to 32";

/// ClientRequestToken が 128 文字を超えるときの文言（2026-09-17、3 回目の実測）。
const TOKEN_TOO_LONG: &str = "1 validation error detected: Value at 'clientRequestToken' failed to satisfy constraint: Member must have length less than or equal to 128";

pub async fn start_query_execution(app: &App, body: &Bytes) -> Response {
    let request: StartQueryExecutionRequest = match parse(body) {
        Ok(request) => request,
        Err(response) => return *response,
    };
    let token = match client_request_token(&request) {
        Ok(token) => token,
        Err(response) => return *response,
    };

    let context = request.query_execution_context.unwrap_or_default();
    let (catalog, database, fingerprint) = context_defaults(
        app,
        context,
        &request.query_string,
        &request.result_configuration,
    );
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

    // 本物は構文エラーを StartQueryExecution で弾き、実行を作らない（ExecutionParameters があっても元の SQL で数える）。
    // 文言は Trino のもの、コードは 2026-09-14 に実測した MALFORMED_QUERY。
    if let Some(message) = app.trino.syntax_error(&request.query_string).await {
        return invalid_request_with_code(message, "MALFORMED_QUERY");
    }

    let work_group = request
        .work_group
        .unwrap_or_else(|| DEFAULT_WORK_GROUP.to_string());

    let outcome = app.store.submit(
        &id,
        Submission {
            query: request.query_string,
            execution_parameters: request.execution_parameters.unwrap_or_default(),
            catalog,
            database,
            result_location,
            work_group,
            token,
            fingerprint,
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

/// ClientRequestToken を検証する（2026-09-17 実測、判断 2・11）。本物と同じく必須で、
/// 長さは 32 以上 128 以下。文字数は chars().count()（本物がバイトか文字かは ASCII でしか
/// 測っていない。README 参照）。
fn client_request_token(request: &StartQueryExecutionRequest) -> Result<String, Box<Response>> {
    let Some(token) = request.client_request_token.clone() else {
        return Err(Box::new(invalid_request_with_code(
            TOKEN_MISSING,
            "INVALID_INPUT",
        )));
    };

    let length = token.chars().count();
    if length < 32 {
        return Err(Box::new(invalid_request_with_code(
            TOKEN_TOO_SHORT,
            "INVALID_INPUT",
        )));
    }
    if length > 128 {
        return Err(Box::new(invalid_request_with_code(
            TOKEN_TOO_LONG,
            "INVALID_INPUT",
        )));
    }

    Ok(token)
}

/// QueryExecutionContext の既定値と、冪等化用のフィンガープリント（既定を当てる前の生の値）を組む。
fn context_defaults(
    app: &App,
    context: QueryExecutionContext,
    query_string: &str,
    result_configuration: &Option<ResultConfiguration>,
) -> (Option<String>, Option<String>, Fingerprint) {
    let fingerprint = Fingerprint {
        query: query_string.to_string(),
        database: context.database.clone(),
        output_location: result_configuration
            .as_ref()
            .and_then(|configuration| configuration.output_location.clone()),
    };
    let catalog = context
        .catalog
        .or_else(|| app.config.default_catalog.clone());
    let database = context
        .database
        .or_else(|| app.config.default_database.clone());
    (catalog, database, fingerprint)
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
            None => {
                return Err(Box::new(invalid_request_with_code(
                    NO_OUTPUT_LOCATION,
                    "INVALID_INPUT",
                )));
            }
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
            Ok((outcome, engine_ddl)) => {
                write_result(&app, &execution, &id, outcome, engine_ddl).await
            }
            Err(error) => {
                let failure = Failure::from_query_error(&error);
                // FAILED にする前に置く（クライアントは FAILED を見た直後に S3 を読みに行く）。
                write_failure(&app, &execution, &failure).await;
                Err(failure)
            }
        };
        // 途中で止められていれば CANCELLED が先に書かれているので、finish は何もしない。
        app.store.finish(&id, outcome);
    });
}

/// 本体と付随ファイル `.metadata` の両方を置いてから結果を返す。SUCCEEDED にするのは
/// 書き終わってからにする（クライアントは SUCCEEDED を見た直後に S3 を読みに行く）。
/// .csv（SELECT）は書けなければ FAILED。.txt（DDL / SHOW など）は書けなくても SUCCEEDED のまま
/// （Trino では既に実行し終えており、本物の Athena も補助ファイルの書き込みでは失敗にしない）。
/// `.metadata` は列がある文に置き、書けなくても SUCCEEDED のまま。
/// DML と CTAS は本体を置かず `.metadata` だけを置く（2026-09-17 実測）。
/// `engine_ddl` が `Some` の文（DROP TABLE × Iceberg。issue #39）は列が無くても本体に改行 1 つ、
/// `.metadata` を置き、どちらも Content-Type は application/octet-stream にする（2026-09-20 実測）。
async fn write_result(
    app: &App,
    execution: &Execution,
    id: &str,
    outcome: Outcome,
    engine_ddl: Option<EngineDdl>,
) -> Result<Outcome, Failure> {
    let (Some(writer), Some(location)) = (&app.results, &execution.result_location) else {
        return Ok(outcome);
    };
    // 途中で止められていれば何も書かない（CANCELLED の本物も何も置かない）。
    if execution.cancel.is_requested() {
        return Ok(outcome);
    }

    // 本体を書くのは SELECT の結果（.csv、更新件数が無いとき）と DDL / SHOW（.txt）だけ。
    // DML / CTAS が置くファイル（manifest や tables/<id>）は作らない。
    let should_write = location.file == ResultFile::Text
        || (location.file == ResultFile::Csv && outcome.update_count.is_none());
    if should_write {
        let body = match location.file {
            ResultFile::Csv => results::to_csv(&outcome),
            // 改行 1 つ（0x0a）。to_text は列の空を見て 0 バイトを返すので使わない。
            // 本体を書くのは DROP TABLE × Iceberg だけで、`.metadata` を置く文のすべてではない
            // （ALTER TABLE ADD COLUMNS × Hive の本体は 0 バイト。2026-09-20 実測）。
            _ if matches!(engine_ddl, Some(EngineDdl::DropTableIceberg)) => vec![b'\n'],
            _ => results::to_text(&outcome),
        };
        let content_type = engine_ddl.is_some().then_some(ENGINE_DDL_CONTENT_TYPE);
        match writer.put(location, body, content_type).await {
            Ok(()) => {}
            // 本体が書けなかったら付随ファイルは試みない。
            Err(reason) if location.file == ResultFile::Text => {
                eprintln!("結果ファイル（.txt）の書き込みに失敗しました。無視します: {reason}");
                return Ok(outcome);
            }
            Err(reason) => return Err(Failure::result_write(reason)),
        }
    }

    // 列が無い文（CREATE TABLE、CREATE / DROP DATABASE）には本物も付随ファイルを置かない。
    // DROP TABLE × Iceberg だけは本物が列なしの 41 バイトを置く（2026-09-20 実測。issue #39）。
    if !outcome.columns.is_empty() || engine_ddl.is_some() {
        write_metadata(writer, location, &execution.query, id, &outcome).await;
    }
    Ok(outcome)
}

/// 失敗の理由を結果ファイルに置く。中身は `FAILED: ` + StateChangeReason で末尾に改行は付けない
/// （本物は StateChangeReason そのものを置き、その文言自体が `FAILED: ` で始まる。2026-09-17 実測）。
/// 置くのは `<id>.txt` の文（DDL / SHOW など）だけで、`.metadata` は置かない（実測）。
/// 書けなくても FAILED と StateChangeReason は Trino のエラーのまま（`.txt` / `.metadata` と同じ扱い）。
/// `.csv` の PUT が失敗して FAILED になる経路（`write_result`）はここを通らない。
async fn write_failure(app: &App, execution: &Execution, failure: &Failure) {
    let (Some(writer), Some(location)) = (&app.results, &execution.result_location) else {
        return;
    };
    // 途中で止められていれば何も書かない（write_result と同じ。CANCELLED の本物も何も置かない）。
    if execution.cancel.is_requested() {
        return;
    }
    let Some(location) = location.failed() else {
        return;
    };

    let body = format!("FAILED: {}", failure.reason).into_bytes();
    if let Err(reason) = writer.put(&location, body, None).await {
        eprintln!("失敗の理由のファイル（.txt）の書き込みに失敗しました。無視します: {reason}");
    }
}

/// 付随ファイル `.metadata` を組み立てて置く。書けなくても実行は成功のまま（補助ファイルなので握りつぶす）。
async fn write_metadata(
    writer: &results::ResultWriter,
    location: &ResultLocation,
    query: &str,
    id: &str,
    outcome: &Outcome,
) {
    let body = metadata::to_metadata(
        metadata_query_id(query, id, outcome.id.as_deref()),
        outcome.update_type.as_deref(),
        // update_count（SELECT を Some(0) にする関数）は使わない。本物は SELECT に field 3 を置かない。
        outcome.update_count,
        &convert::column_infos(outcome),
    );
    if let Err(reason) = writer.put(&location.metadata(), body, None).await {
        eprintln!("付随ファイル（.metadata）の書き込みに失敗しました。無視します: {reason}");
    }
}

/// `.metadata` の先頭（field 1）に載せるクエリ ID。2026-09-17 実測では DESCRIBE と
/// SHOW CREATE TABLE だけが QueryExecutionId で、SELECT・DML・CTAS・EXPLAIN・DROP TABLE は
/// エンジン（Trino）のクエリ ID だった。
fn metadata_query_id<'a>(
    query: &str,
    execution_id: &'a str,
    engine_id: Option<&'a str>,
) -> &'a str {
    let words = super::classification::words(query);
    let word = |index: usize| words.get(index).map(String::as_str).unwrap_or_default();

    match (word(0), word(1)) {
        ("DESCRIBE" | "DESC", _) | ("SHOW", "CREATE") => execution_id,
        _ => engine_id.unwrap_or(execution_id),
    }
}

/// 値を分類して EXECUTE IMMEDIATE で包んで実行する。
/// パラメータが無ければ分類は走らず、SQL は修飾名に別名を当てただけで送られる（to_trino_sql が判断する）。
/// 戻り値の `Option<EngineDdl>` は、実行前にテーブルの形式を問い合わせて分かった、
/// 列が無くても本体・`.metadata` を置くべき文（issue #39 Phase 1: DROP TABLE × Iceberg）。
async fn run(
    trino: &Trino,
    config: &Config,
    execution: &Execution,
) -> Result<(Outcome, Option<EngineDdl>), QueryError> {
    // Trino に送るのは別名を当てた名前。実行情報には受け取った名前が残る。
    let catalog = execution
        .catalog
        .as_deref()
        .map(|catalog| config.trino_catalog(catalog));
    let database = execution.database.as_deref();
    // 分類の問い合わせにも本体にも同じ取り消し要求を渡す。
    let cancel = &execution.cancel;

    // 対象の文（Phase 1 は既定カタログの DROP TABLE だけ）なら、実行前にテーブルの形式を
    // Trino に聞く。パラメータ分類のループより前に置く（対象テーブルは実行後に消えるため）。
    // カタログは本体・分類の問い合わせと同じ、別名解決後の値を使う。
    let engine_ddl = match table_format::target_statement(&execution.query) {
        Some(statement) => table_format::probe_format(trino, catalog, database, cancel)
            .await
            .and_then(|format| table_format::engine_ddl(statement, format)),
        None => None,
    };

    // 分類も本体と同じカタログ・スキーマで問い合わせ、関数の解決先を揃える。
    let mut bound = Vec::with_capacity(execution.execution_parameters.len());
    for value in &execution.execution_parameters {
        let probe = trino
            .execute(&statement::probe_sql(value), catalog, database, cancel)
            .await;
        bound.push(statement::bind(value, &probe));
    }

    // 修飾名のカタログにもヘッダと同じ別名を当てる。EXECUTE IMMEDIATE で文字列リテラルに包む前に当てるので、
    // 包んだ後の引用符の二重化を考えなくてよい。構文チェックと GetQueryExecution の Query は受け取った SQL のまま。
    let query = alias_qualified_names(&execution.query, &config.catalog_map);
    let sql = statement::to_trino_sql(&query, &bound);
    let outcome = match trino.execute(&sql, catalog, database, cancel).await {
        Err(error) if statement::is_unused_parameters(&error) => {
            trino.execute(&query, catalog, database, cancel).await
        }
        result => result,
    }?;
    Ok((outcome, engine_ddl))
}
