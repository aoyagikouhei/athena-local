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

use super::result_output;
use super::table_format::{self, EngineDdl};
use super::target_table;

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
            Ok((outcome, engine_ddl)) => {
                // UpdateCount は形式の判定を使うので、判定が手元にあるここで決めて Store に渡す（#160）。
                let update_count = update_count(&execution.query, &outcome, engine_ddl);
                result_output::write_result(&app, &execution, &id, outcome, engine_ddl)
                    .await
                    .map(|outcome| (outcome, update_count))
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
/// 戻り値の `Option<EngineDdl>` は、実行前にテーブルの形式を問い合わせて分かった、本体・`.metadata` の
/// 書き方を上書きする文（issue #39。DROP TABLE × Iceberg、ALTER TABLE ADD COLUMNS × Hive、
/// SHOW CREATE TABLE × Iceberg（#151））。
async fn run(
    trino: &Trino,
    config: &Config,
    execution: &Execution,
) -> Result<(Outcome, Option<EngineDdl>), QueryError> {
    // 省略した Catalog / Database にはここで既定を当てる（実行情報には残さない。#167）。
    // Trino に送るのは別名を当てた名前。実行情報には受け取った名前が残る。
    let raw_catalog = execution
        .catalog
        .as_deref()
        .or(config.default_catalog.as_deref());
    let catalog = raw_catalog.map(|catalog| config.trino_catalog(catalog));
    let database = execution
        .database
        .as_deref()
        .or(config.default_database.as_deref());
    // 分類の問い合わせにも本体にも同じ取り消し要求を渡す。
    let cancel = &execution.cancel;

    // 対象の文（DROP TABLE・ALTER TABLE ADD COLUMNS・SHOW CREATE TABLE）なら、実行前に
    // テーブルの形式と存在を Trino に聞く。パラメータ分類のループより前に置く（対象テーブルは実行後に消えるため）。
    // 修飾名にカタログ／スキーマがあればそれを、無ければ実行時の既定（別名解決前の値）を使う。
    // カタログには本体と同じ別名を当ててから問い合わせる（system.metadata.catalogs /
    // system.jdbc.tables は Trino 側の名前でしか引けない。issue #39 Phase 2）。
    // 結果 CSV の S3 書き込みが無効（ResultsMode::None）なら、result_output::write_result が判定結果を
    // 丸ごと捨てるので問い合わせない（Trino へのフル往復が無駄になるだけのレビュー指摘）。
    // ただし判定を GetQueryResults の UpdateCount にも使う文（`table_format::needs_format_for_update_count`）
    // は S3 が無効でも問い合わせる（#160）。
    let statement = table_format::target_statement(&execution.query);
    let engine_ddl = if matches!(config.results, ResultsMode::None)
        && !statement.is_some_and(table_format::needs_format_for_update_count)
    {
        None
    } else {
        match statement {
            Some(statement) => match target_table::parse_target_table(
                &execution.query,
                statement,
                raw_catalog,
                database,
            ) {
                Some(target) => {
                    let target_catalog = config.trino_catalog(&target.catalog);
                    table_format::probe_format(
                        trino,
                        target_catalog,
                        &target.schema,
                        &target.table,
                        database,
                        cancel,
                    )
                    .await
                    .and_then(|format| table_format::engine_ddl(statement, format))
                }
                None => None,
            },
            None => None,
        }
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
    let outcome = split_explain_rows(&execution.query, outcome);
    Ok((outcome, engine_ddl))
}

/// EXPLAIN の結果を本物と同じくプランの行ごとに分ける。Trino は `Query Plan` 列の 1 行に改行入りの
/// 全文（末尾は `\n\n`）を返すが、本物の Athena は全文の末尾に改行を 1 つ足してから `\n` で分けた
/// 行を返す（`EXPLAIN SELECT 1` の Rows は列名行 + 非空 11 行 + 空行 3 行の 15 行、`.txt` は
/// 列名行 + 全文 + `\n` の 393 バイト。2026-09-15／16 の 4 ラウンドで実測。#73）。
/// 分けた行を実行結果として持ち回るので、GetQueryResults と `.txt` の行数が揃う。
/// 同じ規則が、改行で終わらないプラン（`FORMAT JSON`／`TYPE IO`。末尾に空行 1 つ）、`\n` 1 つで
/// 終わる `FORMAT GRAPHVIZ`（空行 2 つ）、`ANALYZE`／`TYPE DISTRIBUTED`（空行 3 つ）と、boolean の
/// `true` を返す `TYPE VALIDATE`（`true` + 空行）にも当たる（2026-09-23 に 8 形を同じラウンドで実測。#92）。
fn split_explain_rows(query: &str, mut outcome: Outcome) -> Outcome {
    if super::classification::substatement_type(query) != Some("EXPLAIN") {
        return outcome;
    }
    let rows = std::mem::take(&mut outcome.rows);
    outcome.rows = rows
        .into_iter()
        .flat_map(|row| {
            let text = match row.first() {
                Some(serde_json::Value::String(text)) => text.clone(),
                Some(serde_json::Value::Bool(flag)) => flag.to_string(),
                _ => return vec![row],
            };
            text.split('\n')
                .chain(std::iter::once(""))
                .map(|line| vec![serde_json::Value::from(line)])
                .collect()
        })
        .collect();
    outcome
}

/// GetQueryResults の UpdateCount。本物は SELECT と SHOW でも 0 を返し、DDL では null を返す
/// （2026-09-14 実測。SDK から見て null と省略は同じなので、DDL は省く）。DML と CTAS は Trino が返す
/// 件数をそのまま載せる。DESCRIBE と SHOW CREATE TABLE は Hive のテーブル（と判定できないとき。`DESC` も）では
/// null、Iceberg のテーブルでは 0（2026-09-24 実測。#160）。EXPLAIN は 8 変種とも null（2026-09-16〜23 実測。#169）。
/// null になる文は `.txt` を application で置く文と同じ述語 `content_type::plain_text_statement` で選ぶ
/// （本物でも UpdateCount の有無と Content-Type は一致している）。
fn update_count(query: &str, outcome: &Outcome, engine_ddl: Option<EngineDdl>) -> Option<i64> {
    if let Some(count) = outcome.update_count {
        return Some(count);
    }
    if super::classification::statement_type(query) == "DDL" {
        return None;
    }
    let iceberg = matches!(
        engine_ddl,
        Some(EngineDdl::ShowCreateTableIceberg | EngineDdl::DescribeIceberg)
    );
    if crate::content_type::plain_text_statement(query) && !iceberg {
        return None;
    }
    Some(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn update_count_は件数が無ければ_ddl_以外で_0_になる() {
        let counted = Outcome {
            update_count: Some(3),
            ..Outcome::default()
        };
        assert_eq!(
            update_count("INSERT INTO t VALUES (1)", &counted, None),
            Some(3)
        );
        assert_eq!(
            update_count("CREATE TABLE c AS SELECT 1", &counted, None),
            Some(3)
        );

        let uncounted = Outcome::default();
        assert_eq!(update_count("SELECT 1", &uncounted, None), Some(0));
        assert_eq!(update_count("SHOW TABLES", &uncounted, None), Some(0));
        assert_eq!(
            update_count("CREATE TABLE t (i int)", &uncounted, None),
            None
        );
        assert_eq!(update_count("DROP TABLE t", &uncounted, None), None);
    }

    /// 2026-09-24 実測（#160）: Hive の DESCRIBE と SHOW CREATE TABLE は null、Iceberg なら 0。
    #[test]
    fn update_count_は_describe_と_hive_の_show_create_table_で省き_iceberg_なら_0() {
        let uncounted = Outcome::default();
        assert_eq!(update_count("DESCRIBE t", &uncounted, None), None);
        assert_eq!(update_count("DESC t", &uncounted, None), None);
        assert_eq!(
            update_count("DESCRIBE t", &uncounted, Some(EngineDdl::DescribeIceberg)),
            Some(0)
        );
        assert_eq!(update_count("SHOW CREATE TABLE t", &uncounted, None), None);
        // EXPLAIN は DML 扱いだが、本物は 8 変種とも UpdateCount を返さない（2026-09-16〜23 実測。#169）。
        assert_eq!(update_count("EXPLAIN SELECT 1", &uncounted, None), None);
        assert_eq!(
            update_count("EXPLAIN ANALYZE VERBOSE SELECT 1", &uncounted, None),
            None
        );
        assert_eq!(
            update_count("EXPLAIN (TYPE VALIDATE) SELECT 1", &uncounted, None),
            None
        );
        assert_eq!(
            update_count(
                "SHOW CREATE TABLE t",
                &uncounted,
                Some(EngineDdl::ShowCreateTableIceberg)
            ),
            Some(0)
        );
    }

    fn plan(rows: Vec<Vec<serde_json::Value>>) -> Outcome {
        Outcome {
            rows,
            ..Outcome::default()
        }
    }

    #[test]
    fn explain_は全文の末尾に改行を足してから行に分ける() {
        let outcome = split_explain_rows(
            "EXPLAIN SELECT 1",
            plan(vec![vec![serde_json::Value::from(
                "Fragment 0\n    (1)\n\n",
            )]]),
        );
        assert_eq!(
            outcome.rows,
            [["Fragment 0"], ["    (1)"], [""], [""], [""]]
                .map(|row| row.map(serde_json::Value::from))
        );
    }

    #[test]
    fn explain_でない文と文字列でない値は分けない() {
        let select = split_explain_rows(
            "SELECT 'a\nb'",
            plan(vec![vec![serde_json::Value::from("a\nb")]]),
        );
        assert_eq!(select.rows, [[serde_json::Value::from("a\nb")]]);

        let null = split_explain_rows(
            "EXPLAIN SELECT 1",
            plan(vec![vec![serde_json::Value::Null]]),
        );
        assert_eq!(null.rows, [[serde_json::Value::Null]]);
    }

    #[test]
    fn explain_の真偽値の結果は文字列にしてから同じ規則で分ける() {
        // `EXPLAIN (TYPE VALIDATE)` の boolean の `true` も、本物は `true` + `\n` を分けた
        // `true`・空行の 2 行にする（2026-09-23 実測。#92）。
        let outcome = split_explain_rows(
            "EXPLAIN (TYPE VALIDATE) SELECT 1",
            plan(vec![vec![serde_json::Value::Bool(true)]]),
        );
        assert_eq!(
            outcome.rows,
            [["true"], [""]].map(|row| row.map(serde_json::Value::from))
        );
    }
}
