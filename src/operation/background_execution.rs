//! 受け付けた実行をバックグラウンドで Trino に送り、結果を Store に反映する。

use crate::catalog::alias_qualified_names;
use crate::config::Config;
use crate::failure::Failure;
use crate::handler::App;
use crate::statement;
use crate::store::Execution;
use crate::trino::{Outcome, QueryError, Trino};

use super::completion;
use super::context_catalog;
use super::format_probe;
use super::result_output;
use super::table_format::{self, FormatOverride};

/// 本物と同じく実行はバックグラウンドで進み、状態はポーリングで見る。
pub(super) fn spawn_query(app: App, id: String) {
    tokio::spawn(async move {
        let Some(execution) = app.store.get(&id) else {
            return;
        };
        // 投入直後に止められていれば Trino には何も送らない。
        if !app.store.mark_running(&id) {
            return;
        }
        // 開始時点で FAILED と決まっていれば Trino に送らない。本物は Glue で表が引けない失敗には結果ファイルも
        // `.metadata` も置かず（#227）、Hive の ParseException には理由の `.txt` だけを置いた（#242）。
        // Glue に無い DB への CTAS だけは、本物は問い合わせ部分をエンジンで実行してから失敗し、行数とエンジンの
        // クエリ ID の `.metadata` を置いた。問い合わせが失敗すればそのエラーで終え、何も置かなかった（2026-09-27 実測
        // r4・t1〜t15。#251）。
        if let Some(immediate) = &execution.immediate_failure {
            if immediate.runs_ctas_query {
                match ctas_rows(&app.trino, &app.config, &execution).await {
                    Ok(Some((engine_id, rows))) => {
                        result_output::write_ctas_metadata(&app, &execution, &engine_id, rows)
                            .await;
                    }
                    Ok(None) => {}
                    Err(error) => {
                        app.store
                            .finish(&id, Err(Failure::from_query_error(&error)));
                        return;
                    }
                }
            }
            if immediate.writes_result_file {
                result_output::write_failure(&app, &execution, &immediate.failure).await;
            }
            app.store.finish(&id, Err(immediate.failure.clone()));
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

/// CTAS の問い合わせ部分（`ctas_query::query_part`）を、本体と同じ Context・別名置換・パラメータで Trino に投げ、
/// エンジンのクエリ ID と行数（`WITH NO DATA` は 0。t9）を返す。count(*) で包むと使わない列の計算が省かれ、実行中の
/// 失敗（t2 の `CAST`）を見逃すので、包まずに行を数える。切り出せないときは None（`.metadata` を置かない）。
async fn ctas_rows(
    trino: &Trino,
    config: &Config,
    execution: &Execution,
) -> Result<Option<(String, i64)>, QueryError> {
    let resolved = context_catalog::resolve(
        trino,
        config,
        &execution.query,
        execution.catalog.as_deref(),
    )
    .await;
    let catalog = resolved
        .as_deref()
        .or(config.default_catalog.as_deref())
        .map(|catalog| config.trino_catalog(catalog));
    let database = execution
        .database
        .as_deref()
        .or(config.default_database.as_deref());
    let query = aliased_query(config, execution);
    let Some(part) = super::ctas_query::query_part(&query) else {
        return Ok(None);
    };
    let bound = bind_parameters(trino, execution, catalog, database).await;
    let outcome = execute_bound(
        trino,
        &query[part.range],
        &bound,
        catalog,
        database,
        &execution.cancel,
    )
    .await?;
    let rows = if part.no_data {
        0
    } else {
        outcome.rows.len() as i64
    };
    Ok(outcome.id.map(|id| (id, rows)))
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

    let bound = bind_parameters(trino, execution, catalog, database).await;
    let query = aliased_query(config, execution);
    let outcome = execute_bound(trino, &query, &bound, catalog, database, cancel).await?;
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

/// 分類も本体と同じカタログ・スキーマで問い合わせ、関数の解決先を揃える。
async fn bind_parameters(
    trino: &Trino,
    execution: &Execution,
    catalog: Option<&str>,
    database: Option<&str>,
) -> Vec<String> {
    let mut bound = Vec::with_capacity(execution.execution_parameters.len());
    for value in &execution.execution_parameters {
        let probe = trino
            .execute(
                &statement::probe_sql(value),
                catalog,
                database,
                &execution.cancel,
            )
            .await;
        bound.push(statement::bind(value, &probe));
    }
    bound
}

/// 修飾名のカタログにもヘッダと同じ別名を当てる。EXECUTE IMMEDIATE で文字列リテラルに包む前に当てるので、
/// 包んだ後の引用符の二重化を考えなくてよい。構文チェックと GetQueryExecution の Query は受け取った SQL のまま。
/// 無引用の `awsdatacatalog.<db>.<t>` は、本物が実行した Context（AwsDataCatalog か省略）でだけ当てる（#246）。
fn aliased_query<'a>(config: &Config, execution: &'a Execution) -> std::borrow::Cow<'a, str> {
    let aws_data_catalog_context = execution
        .catalog
        .as_deref()
        .is_none_or(super::reported_query::is_aws_data_catalog);
    alias_qualified_names(
        &execution.query,
        &config.catalog_map,
        aws_data_catalog_context,
    )
}

/// 値を当てて EXECUTE IMMEDIATE で包んで投げ、パラメータを使わない文だと言われたら包まずに投げ直す。
async fn execute_bound(
    trino: &Trino,
    query: &str,
    bound: &[String],
    catalog: Option<&str>,
    database: Option<&str>,
    cancel: &crate::trino::Cancel,
) -> Result<Outcome, QueryError> {
    let sql = statement::to_trino_sql(query, bound);
    match trino.execute(&sql, catalog, database, cancel).await {
        Err(error) if statement::is_unused_parameters(&error) => {
            trino.execute(query, catalog, database, cancel).await
        }
        result => result,
    }
}
