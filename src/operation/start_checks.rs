//! StartQueryExecution の開始時の判定。受け取った文から、実行に使う文・Database・開始時の失敗・
//! GetQueryExecution に返す表示用の値を決め、本物が開始時に弾く文を弾く。

use axum::response::Response;

use crate::handler::App;
use crate::response::invalid_request_with_code;
use crate::results::ResultLocation;
use crate::store::{ImmediateFailure, Reported};

use super::comment_parse_check::{comment_parse_error_failure, pre_syntax_check_failure};
use super::comment_parse_error;
use super::context_catalog;
use super::create_table_catalog;
use super::entity_check::{self, Check};
use super::quoted_names;
use super::reported_query;
use super::unquoted_ddl;

/// 開始時の判定の結果。`Submission` にそのまま渡す。
pub(super) struct Decision {
    /// 実行に使う文（受け取った文から修飾を落としたり、1 部目を差し替えたりしたもの）。
    pub(super) statement: String,
    pub(super) database: Option<String>,
    pub(super) immediate_failure: Option<ImmediateFailure>,
    pub(super) reported: Option<Reported>,
}

/// `query` は `single_statement` が返した受け取った文、`catalog`・`database` は Context に既定値を当てたもの。
/// 本物が開始時に弾く文なら、その応答を `Err` で返す。
pub(super) async fn decide(
    app: &App,
    query: String,
    catalog: Option<&str>,
    database: Option<String>,
    result_location: Option<&ResultLocation>,
) -> Result<Decision, Box<Response>> {
    // S3 Tables のカタログは `s3tablescatalog/<バケット>` の形で見分ける（大文字小文字は区別しない。#157）。
    let s3_tables =
        catalog.is_some_and(|catalog| catalog.to_ascii_lowercase().starts_with("s3tablescatalog/"));
    // S3 Tables の Context では、本物は Hive の CREATE TABLE として読める文の LOCATION・EXTERNAL を開始時に弾く。
    // Trino には両方とも無いので構文チェックより前に見る（2026-09-26 実測 n1〜n32。#229）。
    if s3_tables && let Some(message) = unquoted_ddl::s3_tables_rejection(&query) {
        return Err(Box::new(invalid_request_with_code(
            message,
            "MALFORMED_QUERY",
        )));
    }
    // 構文チェックの前の判定: Trino に文が無い MSCK REPAIR TABLE・ALTER TABLE ... ADD COLUMNS（複数形）は
    // 構文チェックへ進むと必ず構文エラーになる。対象の表の形式やブロックコメントの位置で本物が実際に
    // 何で FAILED にするかが変わるので、構文チェックの前に確かめておく（2026-09-26 実測。#244）。
    let pre_syntax_check_failure = pre_syntax_check_failure(
        &app.trino,
        &app.config,
        &query,
        catalog,
        database.as_deref(),
    )
    .await;
    // 本物は構文エラーを StartQueryExecution で弾き、実行を作らない（ExecutionParameters があっても元の SQL で数える）。
    // 文言は Trino のもの、コードは 2026-09-14 に実測した MALFORMED_QUERY。
    if pre_syntax_check_failure.is_none()
        && let Some(message) = app.trino.syntax_error(&query).await
    {
        return Err(Box::new(invalid_request_with_code(
            message,
            "MALFORMED_QUERY",
        )));
    }
    // 本物は DESCRIBE・SHOW COLUMNS などの `awsdatacatalog.` を落とし、Context の Database を修飾の DB にする
    // （2026-09-26 実測。#242）。落とした文を開始時の確認・実行・`Query` に使い、構文と開始時の文言の判定は
    // 受け取った文で行う（文言の位置と input は受け取った文で実測している）。
    let sent_database = database.clone();
    let (statement, database) = match reported_query::drop_catalog(&query, catalog) {
        Some(rewritten) => (rewritten.query, Some(rewritten.database)),
        None => (query.clone(), database),
    };
    // 本物は DESCRIBE・SHOW COLUMNS の対象の存在を開始時に確かめ、無ければ弾き、ビューなら引用符付きの
    // 名前でも実行する（2026-09-25 実測。#207）。Context の Catalog が実在しなければ、既定のカタログで確かめる（#214）。
    let resolved = context_catalog::resolve(&app.trino, &app.config, &statement, catalog).await;
    let check = entity_check::check(
        &app.trino,
        &app.config,
        &statement,
        resolved.as_deref(),
        database.as_deref(),
    )
    .await;
    if let Check::Reject(response) = check {
        return Err(response);
    }
    // 本物は表への DESCRIBE・DESC の Query から DB も落とし、ビューはカタログも落とさずに返した（2026-09-26
    // 実測 m1〜m13・m11・m37。#242）。ビューは実行だけカタログを落とした文で行う。
    let mut reported = None;
    let (mut statement, database) = match check {
        Check::Table { .. } => match reported_query::drop_database(&statement, catalog) {
            Some(rewritten) => (rewritten.query, Some(rewritten.database)),
            None => (statement, database),
        },
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
    let mut immediate_failure = pre_syntax_check_failure;
    if !matches!(check, Check::Run)
        && let Some(message) = quoted_names::rejection(&query, |catalog| {
            app.config.catalog_map.contains_key(catalog)
        })
        .or_else(|| unquoted_ddl::rejection(&query, s3_tables))
    {
        // No location になった無引用の 3 部の名前は、1 部目のカタログしだいで本物は別の文言で弾くか、開始して
        // FAILED にする（#227）。
        let outcome = if message == unquoted_ddl::NO_LOCATION {
            create_table_catalog::check(&app.trino, &app.config, &query, catalog).await
        } else {
            create_table_catalog::Outcome::Continue
        };
        match outcome {
            create_table_catalog::Outcome::Reject(response) => return Err(response),
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
                return Err(Box::new(invalid_request_with_code(
                    message,
                    "MALFORMED_QUERY",
                )));
            }
        }
    } else if s3_tables
        && let Some(failure) = create_table_catalog::two_part_failure(
            &app.trino,
            &app.config,
            &query,
            catalog.unwrap_or_default(),
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
        let location = result_location.map(ResultLocation::uri);
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

    Ok(Decision {
        statement,
        database,
        immediate_failure,
        reported,
    })
}
