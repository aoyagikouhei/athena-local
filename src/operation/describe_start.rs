//! StartQueryExecution の開始時、名前だけ・列指定・PARTITION 指定の `DESCRIBE`／`FORMATTED` を判定する
//! （#275 フェーズ 3・4）。構文チェック・`entity_check::check`・`quoted_names`・`unquoted_ddl`・
//! `comment_parse_error` の判定より前に呼び、`Some` が返れば残りの判定をすべて飛ばす。

use serde_json::Value;

use crate::catalog::alias_qualified_names;
use crate::failure::Failure;
use crate::handler::App;
use crate::statement::{quote_identifier, quote_literal};
use crate::store::ImmediateFailure;
use crate::trino::Cancel;

use super::context_catalog;
use super::create_table_catalog::schema_missing;
use super::describe_extended::{self, Modifier, Suffix};
use super::entity_check::{self, Probe};
use super::reported_query;
use super::start_checks::Decision;
use super::table_format::{self, TableFormat, TargetStatement};
use super::target_table::{self, TargetTable};
use super::unquoted_alias;
use super::utility_rows::cell;

/// `query` は受け取ったままの文（`single_statement` の後、`;` と前後の空白を落としたもの）。認識できる
/// `DESCRIBE`／`DESC`（`describe_extended::parse`）でなければ `None`（今どおりの経路に委ねる）。名前無しの
/// 修飾子（`DESCRIBE EXTENDED` だけ）は `parse` 自体が `None` を返すので、entity_check の
/// Entity Not Found（z1・z2）に任せる。
pub(super) async fn start(
    app: &App,
    query: &str,
    catalog: Option<&str>,
    database: Option<&str>,
) -> Option<Decision> {
    // 本物で測った Context は `Catalog=AwsDataCatalog` だけ（2026-09-27 実測。#275）。ほかのカタログ
    // （S3 Tables など）の Context は今どおりの経路に任せる。
    if !catalog.is_none_or(reported_query::is_aws_data_catalog) {
        return None;
    }
    describe_extended::parse(query)?;

    let (statement, name_database) = describe_extended::displayed(query, catalog);
    let database = name_database.or_else(|| database.map(str::to_string));
    // `statement`（DB を落とした表示用の文）を読み直す。`describe.name.text` は「Trino に送る名前」に
    // 使うので、落とす前の `query` ではなく落とした後の `statement` から読まないと、開始時に投げる
    // `DESCRIBE <名前>` に DB が残ってしまう（`describe_run::run` は `execution.query`＝`statement` を
    // 読むので、ここでも揃える）。`statement` 自体は最後に `Decision` へ move するので、借用元は別に持つ。
    let statement_for_parse = statement.clone();
    let describe = describe_extended::parse(&statement_for_parse)?;

    let resolved = context_catalog::resolve(&app.trino, &app.config, &statement, catalog).await;
    let raw_catalog = resolved
        .as_deref()
        .or(app.config.default_catalog.as_deref());
    let default_database = database
        .as_deref()
        .or(app.config.default_database.as_deref());
    let target = target_table::parse_target_table(
        &statement,
        TargetStatement::Describe,
        raw_catalog,
        default_database,
    )?;

    let probe = entity_check::probe(
        &app.trino,
        &app.config,
        &target.catalog,
        &target.schema,
        &target.table,
    )
    .await;

    let run = |statement: String, database: Option<String>| Decision {
        statement,
        database,
        immediate_failure: None,
        reported: None,
        describe_extended: true,
    };
    let fail = |statement: String,
                database: Option<String>,
                failure: Failure,
                writes_result_file: bool| Decision {
        statement,
        database,
        immediate_failure: Some(ImmediateFailure {
            failure,
            writes_result_file,
            runs_ctas_query: false,
        }),
        reported: None,
        describe_extended: false,
    };

    match probe {
        // 表かスキーマが無い。名前空間の有無で文言を分ける（無い表・無い DB とも本物は開始して FAILED、
        // 本体だけ置き `.metadata` は置かない。e_x・f_x・z3）。列指定・PARTITION 指定でも同じ判定を使う
        // （本物は列・PARTITION を見る前に名前を先に引くはずなので、名前無しの形と同じ失敗にしてよい）。
        Probe::Missing => {
            let trino_catalog = app.config.trino_catalog(&target.catalog).to_lowercase();
            let sql = table_format::schema_probe_sql(&trino_catalog, &target.schema.to_lowercase());
            let failure = if schema_missing(&app.trino, &sql).await {
                Failure::describe_database_not_found(&target.schema.to_lowercase())
            } else {
                Failure::describe_table_not_found(&target.table.to_lowercase())
            };
            Some(fail(statement, database, failure, true))
        }
        Probe::Table {
            format: Some(TableFormat::Hive),
        } => match (&describe.suffix, describe.modifier) {
            // 修飾子も後ろも無い形は `describe_extended::parse` が対象外にするので実際には来ない。
            (Suffix::None, _) => Some(run(statement, database)),
            // 列指定は修飾子（EXTENDED／FORMATTED）があるときだけ判定する（修飾子無しは Query だけ測定の
            // m8 で今どおり。#275）。
            (Suffix::Column(col), Some(_)) => hive_column_decision(
                app,
                &describe,
                &statement,
                raw_catalog,
                default_database,
                col,
            )
            .await
            .map(|outcome| match outcome {
                Ok(()) => run(statement, database),
                Err(failure) => fail(statement, database, failure, true),
            }),
            // PARTITION 指定も同じく修飾子があるときだけ判定する（修飾子無しは今どおり。#275）。
            (Suffix::Partition(pairs), Some(_)) => hive_partition_decision(
                app,
                &describe,
                &statement,
                raw_catalog,
                default_database,
                &target,
                pairs,
            )
            .await
            .map(|outcome| match outcome {
                Ok(()) => run(statement, database),
                Err(failure) => fail(statement, database, failure, true),
            }),
            (Suffix::Column(_) | Suffix::Partition(_), None) => None,
        },
        // `Probe::Table { format: Some(View) }` は `entity_check::probe` が先に `Probe::View` を返すので
        // 実際には起きない（`table_format::parse_probe_result` は `table_type` が `TABLE` のときしか呼ばれない）。
        // 網羅のためだけに Run 側へ倒す。
        Probe::Table {
            format: Some(TableFormat::View),
        }
        | Probe::View => match describe.suffix {
            Suffix::None => Some(run(statement, database)),
            // ビューへの列・PARTITION 指定は測っていない（今どおり）。
            Suffix::Column(_) | Suffix::Partition(_) => None,
        },
        // Iceberg は FORMATTED だけ本物が実行する（EXTENDED は本物が開始してから FAILED にする。e_i・p6）。
        Probe::Table {
            format: Some(TableFormat::Iceberg),
        } => match (&describe.suffix, describe.modifier) {
            (Suffix::None, Some(Modifier::Extended)) => Some(fail(
                statement,
                database,
                Failure::describe_iceberg_extended(),
                false,
            )),
            (Suffix::None, _) => Some(run(statement, database)),
            // 列指定は修飾子の有無によらず Iceberg では通らないが、文言が違う（p6・p7）。
            (Suffix::Column(_), Some(Modifier::Extended)) => Some(fail(
                statement,
                database,
                Failure::describe_iceberg_extended(),
                false,
            )),
            (Suffix::Column(_), Some(Modifier::Formatted)) => Some(fail(
                statement,
                database,
                Failure::describe_iceberg_formatted_column(),
                false,
            )),
            // 修飾子無しの列指定は列の有無を確かめて実行する（p5。無い列は測っていないので None）。
            (Suffix::Column(col), None) => iceberg_column_exists(
                app,
                &describe,
                &statement,
                raw_catalog,
                default_database,
                col,
            )
            .await
            .then(|| run(statement, database)),
            // 修飾子無しの PARTITION 指定は本物が固定の文言で FAILED にする（p8）。
            (Suffix::Partition(_), None) => Some(fail(
                statement,
                database,
                Failure::describe_iceberg_partition(),
                false,
            )),
            // 修飾子付きの PARTITION 指定は未測定（今どおり）。
            (Suffix::Partition(_), Some(_)) => None,
        },
        // hive でも iceberg でもないコネクタ・カタログが無い・確かめられなかったときは今どおり
        // （構文チェックへ進む。Trino に構文が無いので必ず 400 になる）。
        Probe::Table { format: None } | Probe::NoCatalog | Probe::Unknown => None,
    }
}

/// `DESCRIBE <名前>` を開始時に投げて行を得る（`describe_run::run` と同じ別名の当て方）。失敗すれば
/// `None`（呼び出し側が今どおりに倒す）。
async fn describe_rows(
    app: &App,
    statement: &str,
    name: &str,
    raw_catalog: Option<&str>,
    database: Option<&str>,
) -> Option<Vec<Vec<Value>>> {
    let forms = unquoted_alias::forms(&app.trino, &app.config, statement, raw_catalog).await;
    let plain = format!("DESCRIBE {name}");
    let sql = alias_qualified_names(&plain, &app.config.catalog_map, forms);
    let catalog = raw_catalog.map(|catalog| app.config.trino_catalog(catalog));
    let outcome = app
        .trino
        .execute(&sql, catalog, database, &Cancel::default())
        .await
        .ok()?;
    Some(outcome.rows)
}

/// Hive 表への列指定（p1・p2・z4）。`Ok(())` は実行する、`Err` は開始時の失敗にする文言、`None` は
/// 判定できなかった（今どおり）。パーティション列が 1 つでもあれば対象外（測ったのは非パーティションの
/// H だけ）。
async fn hive_column_decision(
    app: &App,
    describe: &describe_extended::Describe<'_>,
    statement: &str,
    raw_catalog: Option<&str>,
    database: Option<&str>,
    col: &str,
) -> Option<Result<(), Failure>> {
    let rows = describe_rows(app, statement, describe.name.text, raw_catalog, database).await?;
    if rows.iter().any(|row| cell(row, 2) == "partition key") {
        return None;
    }
    let names: Vec<String> = rows.iter().map(|row| cell(row, 0).to_string()).collect();
    if names.iter().any(|name| name.eq_ignore_ascii_case(col)) {
        Some(Ok(()))
    } else {
        Some(Err(Failure::describe_column_not_found(col, &names)))
    }
}

/// Iceberg 表への修飾子無しの列指定（p5）。列があれば true。
async fn iceberg_column_exists(
    app: &App,
    describe: &describe_extended::Describe<'_>,
    statement: &str,
    raw_catalog: Option<&str>,
    database: Option<&str>,
    col: &str,
) -> bool {
    describe_rows(app, statement, describe.name.text, raw_catalog, database)
        .await
        .is_some_and(|rows| {
            rows.iter()
                .any(|row| cell(row, 0).eq_ignore_ascii_case(col))
        })
}

/// Hive 表への PARTITION 指定（p3・p4・z5）。キーがちょうど 1 つで、それが表のパーティション列のときだけ
/// `"<t>$partitions"` で値の有無を確かめる。それ以外（キー 2 つ以上・パーティション列でないキー）は
/// `None`（今どおり）。
async fn hive_partition_decision(
    app: &App,
    describe: &describe_extended::Describe<'_>,
    statement: &str,
    raw_catalog: Option<&str>,
    database: Option<&str>,
    target: &TargetTable,
    pairs: &[(String, String)],
) -> Option<Result<(), Failure>> {
    let [(key, value)] = pairs else {
        return None;
    };
    let rows = describe_rows(app, statement, describe.name.text, raw_catalog, database).await?;
    let is_partition_column = rows
        .iter()
        .any(|row| cell(row, 2) == "partition key" && cell(row, 0).eq_ignore_ascii_case(key));
    if !is_partition_column {
        return None;
    }

    let trino_catalog = raw_catalog.map(|catalog| app.config.trino_catalog(catalog));
    let sql = format!(
        "SELECT 1 FROM {}.{}.{} WHERE {} = {}",
        quote_identifier(trino_catalog.unwrap_or_default()),
        quote_identifier(&target.schema),
        quote_identifier(&format!("{}$partitions", target.table)),
        quote_identifier(key),
        quote_literal(value),
    );
    let outcome = app
        .trino
        .execute(&sql, trino_catalog, database, &Cancel::default())
        .await
        .ok()?;
    if outcome.rows.is_empty() {
        Some(Err(Failure::describe_partition_not_found(key, value)))
    } else {
        Some(Ok(()))
    }
}
