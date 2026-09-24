//! 実行の前に、対象の文（DROP TABLE・ALTER TABLE・SHOW CREATE TABLE・DESCRIBE・SHOW COLUMNS）のテーブルの形式を Trino に問い合わせる。

use crate::config::{Config, ResultsMode};
use crate::store::Execution;
use crate::trino::{Cancel, Trino};

use super::table_format::{self, EngineDdl};
use super::target_table;

/// 対象の文の種類・テーブルの形式・形式から決まる組み合わせ・`SubstatementType` の上書きを、この順のタプルで返す。
/// 対象の文でなければどれも `None`。形式が分からないとき（問い合わせない設定を含む）は、文の種類だけが `Some`。
pub(super) async fn probe_target_format(
    trino: &Trino,
    config: &Config,
    execution: &Execution,
    raw_catalog: Option<&str>,
    database: Option<&str>,
    cancel: &Cancel,
) -> (
    Option<table_format::TargetStatement>,
    Option<table_format::TableFormat>,
    Option<EngineDdl>,
    Option<&'static str>,
) {
    // 対象の文（DROP TABLE・ALTER TABLE ADD COLUMNS・SHOW CREATE TABLE）なら、実行前に
    // テーブルの形式と存在を Trino に聞く。パラメータ分類のループより前に置く（対象テーブルは実行後に消えるため）。
    // 修飾名にカタログ／スキーマがあればそれを、無ければ実行時の既定（別名解決前の値）を使う。
    // カタログには本体と同じ別名を当ててから問い合わせる（system.metadata.catalogs /
    // system.jdbc.tables は Trino 側の名前でしか引けない。issue #39 Phase 2）。
    // 結果 CSV の S3 書き込みが無効（ResultsMode::None）なら、result_output::write_result が判定結果を
    // 丸ごと捨てるので問い合わせない（Trino へのフル往復が無駄になるだけのレビュー指摘）。
    // ただし判定を GetQueryResults の UpdateCount にも使う文（`table_format::needs_format_for_update_count`）
    // は S3 が無効でも問い合わせる（#160）。形式は SHOW COLUMNS の行の形にも使う（`utility_rows::reshape`。#173）。
    let statement = table_format::target_statement(&execution.query);
    let format = if matches!(config.results, ResultsMode::None)
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
                }
                None => None,
            },
            None => None,
        }
    };
    let engine_ddl = statement
        .zip(format)
        .and_then(|(statement, format)| table_format::engine_ddl(statement, format));
    // 本物はビューへの DESCRIBE と SHOW COLUMNS を `DESC_VIEW` と分類する（2026-09-24 実測 d5。#173）。
    let substatement_type = (format == Some(table_format::TableFormat::View)
        && matches!(
            statement,
            Some(
                table_format::TargetStatement::Describe
                    | table_format::TargetStatement::ShowColumns
            )
        ))
    .then_some("DESC_VIEW");
    (statement, format, engine_ddl, substatement_type)
}
