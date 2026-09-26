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
        if let Some(immediate) = &execution.immediate_failure {
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
