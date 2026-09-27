//! StartQueryExecution の開始時、名前だけの `DESCRIBE EXTENDED`／`FORMATTED`（列・PARTITION 指定は
//! フェーズ 4）を判定する（#275 フェーズ 3）。構文チェック・`entity_check::check`・`quoted_names`・
//! `unquoted_ddl`・`comment_parse_error` の判定より前に呼び、`Some` が返れば残りの判定をすべて飛ばす。

use crate::failure::Failure;
use crate::handler::App;
use crate::store::ImmediateFailure;

use super::context_catalog;
use super::create_table_catalog::schema_missing;
use super::describe_extended::{self, Suffix};
use super::entity_check::{self, Probe};
use super::reported_query;
use super::start_checks::Decision;
use super::table_format::{self, TableFormat, TargetStatement};
use super::target_table;

/// `query` は受け取ったままの文（`single_statement` の後、`;` と前後の空白を落としたもの）。名前だけの
/// 修飾子付き `DESCRIBE`／`DESC`（`describe_extended::parse` が `Suffix::None` で返すもの）でなければ
/// `None`（今どおりの経路に委ねる）。名前無しの修飾子（`DESCRIBE EXTENDED` だけ）は `parse` 自体が
/// `None` を返すので、entity_check の Entity Not Found（z1・z2）に任せる。
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
    let describe = describe_extended::parse(query)?;
    if describe.suffix != Suffix::None {
        // 列・PARTITION 指定はフェーズ 4（今どおり構文チェックへ進む）。
        return None;
    }

    let (statement, name_database) = describe_extended::displayed(query, catalog);
    let database = name_database.or_else(|| database.map(str::to_string));

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

    match probe {
        // `Probe::Table { format: Some(View) }` は `entity_check::probe` が先に `Probe::View` を返すので
        // 実際には起きない（`table_format::parse_probe_result` は `table_type` が `TABLE` のときしか呼ばれない）。
        // 網羅のためだけに Run 側へ倒す。
        Probe::Table {
            format: Some(TableFormat::Hive | TableFormat::View),
        }
        | Probe::View => Some(run(statement, database)),
        // Iceberg は FORMATTED だけ本物が実行する（EXTENDED は本物が開始してから FAILED にする。e_i・p6）。
        Probe::Table {
            format: Some(TableFormat::Iceberg),
        } => match describe.modifier {
            Some(describe_extended::Modifier::Extended) => Some(Decision {
                statement,
                database,
                immediate_failure: Some(ImmediateFailure {
                    failure: Failure::describe_iceberg_extended(),
                    writes_result_file: false,
                    runs_ctas_query: false,
                }),
                reported: None,
                describe_extended: false,
            }),
            _ => Some(run(statement, database)),
        },
        // 表かスキーマが無い。名前空間の有無で文言を分ける（無い表・無い DB とも本物は開始して FAILED、
        // 本体だけ置き `.metadata` は置かない。e_x・f_x・z3）。
        Probe::Missing => {
            let trino_catalog = app.config.trino_catalog(&target.catalog).to_lowercase();
            let sql = table_format::schema_probe_sql(&trino_catalog, &target.schema.to_lowercase());
            let failure = if schema_missing(&app.trino, &sql).await {
                Failure::describe_database_not_found(&target.schema.to_lowercase())
            } else {
                Failure::describe_table_not_found(&target.table.to_lowercase())
            };
            Some(Decision {
                statement,
                database,
                immediate_failure: Some(ImmediateFailure {
                    failure,
                    writes_result_file: true,
                    runs_ctas_query: false,
                }),
                reported: None,
                describe_extended: false,
            })
        }
        // hive でも iceberg でもないコネクタ・カタログが無い・確かめられなかったときは今どおり
        // （構文チェックへ進む。Trino に構文が無いので必ず 400 になる）。
        Probe::Table { format: None } | Probe::NoCatalog | Probe::Unknown => None,
    }
}
