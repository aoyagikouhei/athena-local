//! 名前だけの修飾子付き `DESCRIBE EXTENDED`／`FORMATTED`（#275）の実行。受け取った文は Trino に送らず、
//! `DESCRIBE <名前>` と（Iceberg の FORMATTED だけ）`SHOW CREATE TABLE`・`"<t>$properties"` を別のクエリとして
//! 投げ、`describe_detail`・`describe_detail_iceberg` で本物の行を組む（D3・D7）。`background_execution::run` が
//! 形式の問い合わせの後に呼ぶ。

use crate::catalog::{UnquotedForms, alias_qualified_names};
use crate::config::Config;
use crate::statement::quote_identifier;
use crate::store::Execution;
use crate::trino::{Cancel, Outcome, QueryError, Trino};

use super::describe_detail;
use super::describe_detail_iceberg;
use super::describe_extended::{self, Modifier};
use super::iceberg_partitions;
use super::table_format::{TableFormat, TargetStatement};
use super::target_table;
use super::unquoted_alias;
use super::utility_rows;

/// 名前だけの修飾子付き DESCRIBE（#275）の実行本体。`DESCRIBE <名前>` を、本体と同じ別名の当て方
/// （`aliased_query` と同じ `unquoted_alias::forms`）で送り、Hive・ビューは `describe_detail`、
/// Iceberg の FORMATTED は `SHOW CREATE TABLE`・`"<t>$properties"` を別に投げて `describe_detail_iceberg`
/// で行を組む（D3・D7）。組んだ行は `utility_rows::replace` で `col_name`／`data_type`／`comment` の
/// 3 列に差し替える（`utility_rows::reshape` の代わり）。
#[allow(clippy::too_many_arguments)]
pub(super) async fn run(
    trino: &Trino,
    config: &Config,
    execution: &Execution,
    describe: &describe_extended::Describe<'_>,
    catalog: Option<&str>,
    database: Option<&str>,
    format: Option<TableFormat>,
    raw_catalog: Option<&str>,
    cancel: &Cancel,
) -> Result<Outcome, QueryError> {
    let forms = unquoted_alias::forms(
        trino,
        config,
        &execution.query,
        execution.catalog.as_deref(),
    )
    .await;
    let sql = describe_extended::trino_statement(describe);
    let sql = alias_qualified_names(&sql, &config.catalog_map, forms);
    let outcome = trino.execute(&sql, catalog, database, cancel).await?;

    // Thrift の `dbName`／`tableName`（FORMATTED の `Database:`／`Table:`）に使う、実行に使った
    // Database と表の名前（名前の DB があればそれ、無ければ Context の Database か既定）。
    let target = target_table::parse_target_table(
        &execution.query,
        TargetStatement::Describe,
        raw_catalog,
        database,
    );
    let (db, table_name) = match target {
        Some(target) => (target.schema, target.table),
        None => (
            database.unwrap_or_default().to_string(),
            describe.name.text.to_string(),
        ),
    };

    let rows = if format == Some(TableFormat::Iceberg) {
        // EXTENDED は開始時に FAILED にしているので、ここに来るのは FORMATTED だけ。
        let ddl =
            iceberg_show_create_ddl(trino, config, catalog, database, cancel, describe.name.text)
                .await;
        let partitions = ddl
            .as_deref()
            .map(iceberg_partitions::parse_partitioning)
            .unwrap_or_default();
        let location = ddl
            .as_deref()
            .and_then(|ddl| iceberg_partitions::parse_string_property(ddl, "location"));
        let table_format_value = ddl
            .as_deref()
            .and_then(|ddl| iceberg_partitions::parse_string_property(ddl, "format"));
        let write_format_default = iceberg_write_format_default(
            trino,
            config,
            catalog,
            database,
            cancel,
            &db,
            &table_name,
        )
        .await;
        // 本物の `Name:` は Context のカタログ（AwsDataCatalog）でも Trino の内部の名前でもなく `iceberg`
        // だった（2026-09-27 実測 f_i）。測った値をそのまま使う。
        let name = format!("iceberg.{db}.{table_name}");
        describe_detail_iceberg::formatted(
            &outcome.rows,
            &partitions,
            &name,
            location.as_deref(),
            table_format_value.as_deref(),
            write_format_default.as_deref(),
        )
    } else {
        let kind = if format == Some(TableFormat::View) {
            describe_detail::Kind::View
        } else {
            describe_detail::Kind::Table
        };
        let table = describe_detail::Table {
            db: &db,
            name: &table_name,
            kind,
        };
        match describe.modifier.unwrap_or(Modifier::Extended) {
            Modifier::Extended => describe_detail::extended(&outcome.rows, &table),
            Modifier::Formatted => describe_detail::formatted(&outcome.rows, &table),
        }
    };

    Ok(utility_rows::replace(
        outcome,
        &[
            ("col_name", "string"),
            ("data_type", "string"),
            ("comment", "string"),
        ],
        rows,
    ))
}

/// Iceberg の FORMATTED のための `SHOW CREATE TABLE <名前>` の DDL。`completion::iceberg_partition_specs`
/// と同じ投げ方（無引用の `awsdatacatalog.` は開始時の表示で落としてあるので見ない。#173・#275）。
/// 失敗すれば None（パーティション・location・format の行を省く。DESCRIBE 自体は成功のまま）。
async fn iceberg_show_create_ddl(
    trino: &Trino,
    config: &Config,
    catalog: Option<&str>,
    database: Option<&str>,
    cancel: &Cancel,
    name: &str,
) -> Option<String> {
    let sql = format!("SHOW CREATE TABLE {name}");
    let sql = alias_qualified_names(&sql, &config.catalog_map, UnquotedForms::None);
    let outcome = trino.execute(&sql, catalog, database, cancel).await.ok()?;
    match outcome.rows.first()?.first()? {
        serde_json::Value::String(ddl) => Some(ddl.clone()),
        _ => None,
    }
}

/// `"<表>$properties"` の `write.format.default`（Iceberg の FORMATTED。D7）。失敗・無ければ None
/// （行を省く）。
async fn iceberg_write_format_default(
    trino: &Trino,
    config: &Config,
    catalog: Option<&str>,
    database: Option<&str>,
    cancel: &Cancel,
    db: &str,
    table: &str,
) -> Option<String> {
    let sql = format!(
        "SELECT value FROM {}.{}.{} WHERE key = 'write.format.default'",
        quote_identifier(catalog?),
        quote_identifier(db),
        quote_identifier(&format!("{table}$properties")),
    );
    let sql = alias_qualified_names(&sql, &config.catalog_map, UnquotedForms::None);
    let outcome = trino.execute(&sql, catalog, database, cancel).await.ok()?;
    match outcome.rows.first()?.first()? {
        serde_json::Value::String(value) => Some(value.clone()),
        _ => None,
    }
}
