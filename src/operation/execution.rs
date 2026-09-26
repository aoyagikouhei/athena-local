//! StartQueryExecution の受付、Trino での実行。

use axum::body::Bytes;
use axum::response::Response;
use uuid::Uuid;

use crate::athena::{StartQueryExecutionRequest, StartQueryExecutionResponse};
use crate::config::{Config, DEFAULT_WORK_GROUP};
use crate::failure::Failure;
use crate::handler::App;
use crate::request::parse;
use crate::response::{invalid_request_with_code, ok};
use crate::results::ResultLocation;
use crate::store::{ImmediateFailure, Reported, Submission, SubmitOutcome};
use crate::trino::Trino;

use super::background_execution::spawn_query;
use super::comment_parse_error;
use super::context_catalog;
use super::create_table_catalog;
use super::entity_check::{self, Check, Probe};
use super::quoted_names;
use super::reported_query;
use super::start_request::{
    client_request_token, context_defaults, result_location, single_statement,
};
use super::table_format::TargetStatement;
use super::target_table;
use super::unquoted_ddl;

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
    // S3 Tables のカタログは `s3tablescatalog/<バケット>` の形で見分ける（大文字小文字は区別しない。#157）。
    let s3_tables = catalog
        .as_deref()
        .is_some_and(|catalog| catalog.to_ascii_lowercase().starts_with("s3tablescatalog/"));
    // S3 Tables の Context では、本物は Hive の CREATE TABLE として読める文の LOCATION・EXTERNAL を開始時に弾く。
    // Trino には両方とも無いので構文チェックより前に見る（2026-09-26 実測 n1〜n32。#229）。
    if s3_tables && let Some(message) = unquoted_ddl::s3_tables_rejection(&query) {
        return invalid_request_with_code(message, "MALFORMED_QUERY");
    }
    // 本物は構文エラーを StartQueryExecution で弾き、実行を作らない（ExecutionParameters があっても元の SQL で数える）。
    // 文言は Trino のもの、コードは 2026-09-14 に実測した MALFORMED_QUERY。
    if let Some(message) = app.trino.syntax_error(&query).await {
        return invalid_request_with_code(message, "MALFORMED_QUERY");
    }
    // 本物は DESCRIBE・SHOW COLUMNS などの `awsdatacatalog.` を落とし、Context の Database を修飾の DB にする
    // （2026-09-26 実測。#242）。落とした文を開始時の確認・実行・`Query` に使い、構文と開始時の文言の判定は
    // 受け取った文で行う（文言の位置と input は受け取った文で実測している）。
    let sent_database = database.clone();
    let (statement, database) = match reported_query::drop_catalog(&query, catalog.as_deref()) {
        Some(rewritten) => (rewritten.query, Some(rewritten.database)),
        None => (query.clone(), database),
    };
    // 本物は DESCRIBE・SHOW COLUMNS の対象の存在を開始時に確かめ、無ければ弾き、ビューなら引用符付きの
    // 名前でも実行する（2026-09-25 実測。#207）。Context の Catalog が実在しなければ、既定のカタログで確かめる（#214）。
    let resolved =
        context_catalog::resolve(&app.trino, &app.config, &statement, catalog.as_deref()).await;
    let check = entity_check::check(
        &app.trino,
        &app.config,
        &statement,
        resolved.as_deref(),
        database.as_deref(),
    )
    .await;
    if let Check::Reject(response) = check {
        return *response;
    }
    // 本物は表への DESCRIBE・DESC の Query から DB も落とし、ビューはカタログも落とさずに返した（2026-09-26
    // 実測 m1〜m13・m11・m37。#242）。ビューは実行だけカタログを落とした文で行う。
    let mut reported = None;
    let (mut statement, database) = match check {
        Check::Table { .. } => {
            match reported_query::drop_database(&statement, catalog.as_deref()) {
                Some(rewritten) => (rewritten.query, Some(rewritten.database)),
                None => (statement, database),
            }
        }
        Check::Run if statement != query => {
            reported = Some(Reported {
                query: query.clone(),
                database: sent_database,
            });
            (statement, database)
        }
        _ => (statement, database),
    };
    // Trino は受けるが本物は開始時に弾く、引用符付きの名前を取る DDL 系の文（2026-09-25 実測。#204）と、
    // 無引用の ALTER TABLE の文（IF EXISTS・ADD COLUMN 単数・Trino だけにある形。2026-09-26 実測。#208）。
    // 本物も Trino が構文エラーにする形では Trino の文言を返したので、構文チェックの後に見る。
    // 引用符付きの名前の文言を先に試す（quoted_names が None を返すのは無引用のときと ALTER TABLE IF
    // EXISTS のときだけで、後者は unquoted_ddl が引き取る）。
    let mut immediate_failure = None;
    if !matches!(check, Check::Run)
        && let Some(message) = quoted_names::rejection(&query, |catalog| {
            app.config.catalog_map.contains_key(catalog)
        })
        .or_else(|| unquoted_ddl::rejection(&query, s3_tables))
    {
        // No location になった無引用の 3 部の名前は、1 部目のカタログしだいで本物は別の文言で弾くか、開始して
        // FAILED にする（#227）。
        let outcome = if message == unquoted_ddl::NO_LOCATION {
            create_table_catalog::check(&app.trino, &app.config, &query, catalog.as_deref()).await
        } else {
            create_table_catalog::Outcome::Continue
        };
        match outcome {
            create_table_catalog::Outcome::Reject(response) => return *response,
            create_table_catalog::Outcome::FailAtRuntime(failure) => {
                immediate_failure = Some(ImmediateFailure {
                    failure,
                    writes_result_file: false,
                });
            }
            // 本物は 1 部目を無視して名前空間に作り、Query は受け取ったまま返した（2026-09-26 実測 j1・j4。#237）。
            create_table_catalog::Outcome::Rewrite(rewritten) => {
                reported = Some(Reported {
                    query: query.clone(),
                    database: database.clone(),
                });
                statement = rewritten;
            }
            create_table_catalog::Outcome::Continue => {
                return invalid_request_with_code(message, "MALFORMED_QUERY");
            }
        }
    } else if s3_tables
        && let Some(failure) = create_table_catalog::two_part_failure(
            &app.trino,
            &app.config,
            &query,
            catalog.as_deref().unwrap_or_default(),
        )
        .await
    {
        // S3 Tables の Context の無引用の 2 部の名前は、本物は名前空間が無ければ 3 部と同じく開始して FAILED にした
        // （2026-09-26 実測 i2・j12。#231）。
        immediate_failure = Some(ImmediateFailure {
            failure,
            writes_result_file: false,
        });
    } else if s3_tables {
        // S3 Tables の Context の CTAS は、1 部目が `awsdatacatalog` の類なら本物は 2 部目を Glue の DB として引いた
        // （2026-09-26 実測 i12・j13。#232）。DB が無ければ開始して FAILED（`.metadata` は中身が未実測なので置かない）、
        // あれば 1 部目を AwsDataCatalog の Trino 名にして送り、Query は受け取ったまま返す。
        let location = result_location.as_ref().map(ResultLocation::uri);
        match create_table_catalog::ctas(&app.trino, &app.config, &query, location.as_deref()).await
        {
            create_table_catalog::Outcome::FailAtRuntime(failure) => {
                immediate_failure = Some(ImmediateFailure {
                    failure,
                    writes_result_file: false,
                });
            }
            create_table_catalog::Outcome::Rewrite(rewritten) => {
                reported = Some(Reported {
                    query: query.clone(),
                    database: database.clone(),
                });
                statement = rewritten;
            }
            _ => {}
        }
    }

    // 本物の Hive のパーサは、SHOW CREATE TABLE・DESCRIBE・ALTER TABLE のキーワードの間や
    // 名前の直前のブロックコメントで ParseException を返す。対象の表の形式で本物が実際に失敗させるかが
    // 変わる（2026-09-26 実測。#244）。MSCK REPAIR TABLE・ALTER TABLE ... ADD COLUMNS はここでは判定しない
    // （Trino に文が無く構文チェックで弾かれるので、構文チェックの前で扱う）。
    // `check`（`Check::Reject(Box<Response>)` を含む）を async の境界（`.await`）越しに借用すると、
    // `axum::body::Body` が `Sync` でないせいで `dispatch` が `Handler` を実装できなくなる。判定だけ先に
    // bool にして渡す。
    let describe_table_hive = matches!(check, Check::Table { iceberg: false });
    if let Some(parse_error) = comment_parse_error::detect(&statement)
        && let Some(failure) = comment_parse_error_failure(
            &app.trino,
            &app.config,
            &statement,
            describe_table_hive,
            resolved.as_deref(),
            database.as_deref(),
            parse_error,
        )
        .await
    {
        immediate_failure = Some(ImmediateFailure {
            failure,
            writes_result_file: true,
        });
    }

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

/// 構文チェックの後の判定: `comment_parse_error::detect` が対象にした文で、本物が実際に FAILED にするか。DESCRIBE は
/// 開始時の `check`（`entity_check::check` の結果）をそのまま使い（呼び出し側で先に bool にする。
/// `Check::Reject` の `Box<Response>` を async の境界越しに借用すると `dispatch` が `Handler` を実装
/// できなくなる）、SHOW CREATE TABLE・ALTER TABLE の RENAME TO・DROP COLUMN は名前を読み直して
/// `entity_check::probe` をもう 1 回だけ投げる（問い合わせが増えるのはブロックコメントが決め手の位置に
/// あるときだけ。design-checklist #39）。
async fn comment_parse_error_failure(
    trino: &Trino,
    config: &Config,
    statement: &str,
    describe_table_hive: bool,
    resolved: Option<&str>,
    database: Option<&str>,
    parse_error: comment_parse_error::ParseError,
) -> Option<Failure> {
    use comment_parse_error::Target;

    match parse_error.target {
        Target::Describe => describe_table_hive.then(|| parse_error.into()),
        Target::ShowCreateTable | Target::AlterDropColumn | Target::AlterRename => {
            // ALTER の 3 動作は名前の前のキーワードが同じ `ALTER TABLE` なので、`target_table` の読み方は
            // ADD COLUMNS と共有する（`table_format::TargetStatement` に RENAME TO・DROP COLUMN 用の腕は無い）。
            let target_statement = if parse_error.target == Target::ShowCreateTable {
                TargetStatement::ShowCreateTable
            } else {
                TargetStatement::AlterTableAddColumns
            };
            let raw_catalog = resolved.or(config.default_catalog.as_deref());
            let default_database = database.or(config.default_database.as_deref());
            let target = target_table::parse_target_table(
                statement,
                target_statement,
                raw_catalog,
                default_database,
            )?;
            match entity_check::probe(
                trino,
                config,
                &target.catalog,
                &target.schema,
                &target.table,
            )
            .await
            {
                Probe::Missing | Probe::View | Probe::Table { iceberg: false } => {
                    Some(parse_error.into())
                }
                Probe::Table { iceberg: true } | Probe::NoCatalog | Probe::Unknown => None,
            }
        }
        Target::MsckRepair | Target::AlterAddColumns => None,
    }
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
