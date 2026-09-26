//! StartQueryExecution の受付、Trino での実行。

use axum::body::Bytes;
use axum::response::Response;
use uuid::Uuid;

use crate::athena::{
    QueryExecutionContext, ResultConfiguration, StartQueryExecutionRequest,
    StartQueryExecutionResponse,
};
use crate::catalog::alias_qualified_names;
use crate::config::{Config, DEFAULT_WORK_GROUP, ResultsMode};
use crate::failure::Failure;
use crate::handler::App;
use crate::request::parse;
use crate::response::{invalid_request_with_code, ok};
use crate::results::ResultLocation;
use crate::statement;
use crate::store::{Execution, Fingerprint, Submission, SubmitOutcome};
use crate::trino::{Outcome, QueryError, Trino};

use super::completion;
use super::context_catalog;
use super::entity_check::{self, Check};
use super::format_probe;
use super::quoted_names;
use super::result_output;
use super::table_format::{self, FormatOverride};
use super::unquoted_ddl;

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
/// ClientRequestToken が 128 文字以下なのに UTF-8 で 128 バイトを超えるときの文言（2026-09-24 実測、#153）。
/// 枠組みの検証（文字数）を通った後の別の検査なので、前置きが無い。
const TOKEN_TOO_MANY_BYTES: &str = "clientRequestToken exceeds maximum allowed length 128";

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
    // 本物は DESCRIBE・SHOW COLUMNS の対象の存在を開始時に確かめ、無ければ弾き、ビューなら引用符付きの
    // 名前でも実行する（2026-09-25 実測。#207）。Context の Catalog が実在しなければ、既定のカタログで確かめる（#214）。
    let resolved = context_catalog::resolve(
        &app.trino,
        &app.config,
        &request.query_string,
        catalog.as_deref(),
    )
    .await;
    let check = entity_check::check(
        &app.trino,
        &app.config,
        &request.query_string,
        resolved.as_deref(),
        database.as_deref(),
    )
    .await;
    if let Check::Reject(response) = check {
        return *response;
    }
    // Trino は受けるが本物は開始時に弾く、引用符付きの名前を取る DDL 系の文（2026-09-25 実測。#204）と、
    // 無引用の ALTER TABLE の文（IF EXISTS・ADD COLUMN 単数・Trino だけにある形。2026-09-26 実測。#208）。
    // 本物も Trino が構文エラーにする形では Trino の文言を返したので、構文チェックの後に見る。
    // 引用符付きの名前の文言を先に試す（quoted_names が None を返すのは無引用のときと ALTER TABLE IF
    // EXISTS のときだけで、後者は unquoted_ddl が引き取る）。
    if !matches!(check, Check::Run)
        && let Some(message) = quoted_names::rejection(&request.query_string, |catalog| {
            app.config.catalog_map.contains_key(catalog)
        })
        .or_else(|| {
            // S3 Tables のカタログは `s3tablescatalog/<バケット>` の形で見分ける（大文字小文字は区別しない。#157）。
            let s3_tables = catalog.as_deref().is_some_and(|catalog| {
                catalog.to_ascii_lowercase().starts_with("s3tablescatalog/")
            });
            unquoted_ddl::rejection(&request.query_string, s3_tables)
        })
    {
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
/// 長さは 32 文字以上 128 文字以下（枠組みの検証。文字数は chars().count()）、さらに UTF-8 で
/// 128 バイト以下（別の検査。2026-09-24 実測、#153。`あ`×50 は 50 文字なのに拒否された）。
/// 文字数でもバイト数でも 128 を超えるときにどちらの文言が先かは測っていないので、
/// 枠組みの検証を先に置く（docs/dev/unmeasured.md）。
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
    if token.len() > 128 {
        return Err(Box::new(invalid_request_with_code(
            TOKEN_TOO_MANY_BYTES,
            "INVALID_INPUT",
        )));
    }

    Ok(token)
}

/// QueryExecutionContext の Catalog / Database（受け取ったまま）と、冪等化用のフィンガープリント（同じく生の値）を組む。
fn context_defaults(
    context: QueryExecutionContext,
    query_string: &str,
    result_configuration: &Option<ResultConfiguration>,
) -> (Option<String>, Option<String>, Fingerprint) {
    let fingerprint = Fingerprint {
        query: query_string.to_string(),
        catalog: context.catalog.clone(),
        database: context.database.clone(),
        output_location: result_configuration
            .as_ref()
            .and_then(|configuration| configuration.output_location.clone()),
    };
    // 既定（TRINO_CATALOG / TRINO_SCHEMA）はここでは当てない。本物は省略した Catalog / Database を
    // GetQueryExecution に返さない（キー無し。2026-09-24 実測、#167）ので、実行情報には受け取った値だけを
    // 残し、既定は Trino に送るとき（`run`）に当てる。
    (context.catalog, context.database, fingerprint)
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
    ResultLocation::new(&output_location, id, query)
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
            Ok((outcome, format_override, substatement_type)) => {
                // UpdateCount は形式の判定を使うので、判定が手元にあるここで決めて Store に渡す（#160）。
                // SubstatementType の上書き（ビューの `DESC_VIEW`）も同じく形式の判定から決まる（#173）。
                let update_count =
                    completion::update_count(&execution.query, &outcome, format_override);
                result_output::write_result(&app, &execution, &id, outcome, format_override)
                    .await
                    .map(|outcome| (outcome, update_count, substatement_type))
            }
            Err(error) => {
                let failure = Failure::from_query_error(&error);
                // FAILED にする前に置く（クライアントは FAILED を見た直後に S3 を読みに行く）。
                result_output::write_failure(&app, &execution, &failure).await;
                Err(failure)
            }
        };
        // 途中で止められていれば CANCELLED が先に書かれているので、finish は何もしない。
        app.store.finish(&id, outcome);
    });
}

/// 値を分類して EXECUTE IMMEDIATE で包んで実行する。
/// パラメータが無ければ分類は走らず、SQL は修飾名に別名を当てただけで送られる（to_trino_sql が判断する）。
/// 戻り値の `Option<FormatOverride>` は、実行前にテーブルの形式を問い合わせて分かった、本体・`.metadata` の
/// 書き方を上書きする文（issue #39。DROP TABLE × Iceberg、ALTER TABLE ADD COLUMNS × Hive、
/// SHOW CREATE TABLE × Iceberg（#151））。戻り値の `Option<&'static str>` は、完了後の GetQueryExecution が
/// SQL だけで決まる分類の代わりに返す SubstatementType（ビューへの DESCRIBE／SHOW COLUMNS の `DESC_VIEW`。#173）。
async fn run(
    trino: &Trino,
    config: &Config,
    execution: &Execution,
) -> Result<(Outcome, Option<FormatOverride>, Option<&'static str>), QueryError> {
    // 省略した Catalog / Database にはここで既定を当てる（実行情報には残さない。#167）。
    // Trino に送るのは別名を当てた名前。実行情報には受け取った名前が残る。
    // 実在しない Catalog は、メタデータの文だけ既定のカタログに差し替える（#214）。
    let resolved = context_catalog::resolve(
        trino,
        config,
        &execution.query,
        execution.catalog.as_deref(),
    )
    .await;
    let raw_catalog = resolved.as_deref().or(config.default_catalog.as_deref());
    let catalog = raw_catalog.map(|catalog| config.trino_catalog(catalog));
    let database = execution
        .database
        .as_deref()
        .or(config.default_database.as_deref());
    // 分類の問い合わせにも本体にも同じ取り消し要求を渡す。
    let cancel = &execution.cancel;

    let (statement, format, format_override, substatement_type) =
        format_probe::probe_target_format(trino, config, execution, raw_catalog, database, cancel)
            .await;

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
    let outcome = completion::split_explain_rows(&execution.query, outcome);
    let outcome = completion::split_show_create_rows(&execution.query, outcome);
    // Iceberg のテーブルの DESCRIBE だけ、パーティション行のために `SHOW CREATE TABLE` を別に投げる（#173）。
    let partitions = if statement == Some(table_format::TargetStatement::Describe)
        && format == Some(table_format::TableFormat::Iceberg)
    {
        completion::iceberg_partition_specs(
            trino,
            config,
            &execution.query,
            catalog,
            database,
            cancel,
        )
        .await
    } else {
        Vec::new()
    };
    let outcome = super::utility_rows::reshape(&execution.query, outcome, format, &partitions);
    Ok((outcome, format_override, substatement_type))
}
