//! 本物の Hive のパーサがブロックコメントで失敗させる文を、開始時に判定して `ImmediateFailure`・`Failure` にする
//! 配線（#244）。文言と位置は `comment_parse_error::detect`、表の種類は `entity_check::probe` で決める。

use crate::config::Config;
use crate::failure::Failure;
use crate::store::ImmediateFailure;
use crate::trino::Trino;

use super::classification;
use super::comment_parse_error;
use super::context_catalog;
use super::entity_check::{self, Probe};
use super::table_format::TargetStatement;
use super::target_table;

/// 構文チェックの前の判定: `query` が `MSCK REPAIR TABLE` か、`comment_parse_error::detect` が
/// `AlterAddColumns`（`ALTER TABLE ... ADD COLUMNS` の複数形にブロックコメントが決め手の位置にある形）を
/// 返すときだけ対象の存在を確かめる。対象が Iceberg 表なら、ブロックコメントの有無・位置によらず本物は
/// 別の失敗（`Failure::msck_iceberg`）で FAILED にする。Hive・ビュー・無い表は、ブロックコメントが決め手の
/// 位置にあるとき（`detect` が Some）だけ、その ParseException で FAILED にする。名前が引用符付きの部品を
/// 含むか 4 部以上・カタログが無い・問い合わせが失敗したとき（`Probe::NoCatalog`・`Probe::Unknown`）は
/// 何もせず、今までどおり構文チェックへ進む（2026-09-26 実測。#244）。問い合わせが増えるのは MSCK と、
/// コメント入りの ADD COLUMNS のときだけ（design-checklist #39）。
pub(super) async fn pre_syntax_check_failure(
    trino: &Trino,
    config: &Config,
    query: &str,
    catalog: Option<&str>,
    database: Option<&str>,
) -> Option<ImmediateFailure> {
    use comment_parse_error::Target;

    let is_msck = classification::substatement_type(query) == Some("MSCK_REPAIR");
    let comment = comment_parse_error::detect(query);
    let add_columns_comment = comment
        .clone()
        .filter(|error| !is_msck && error.target == Target::AlterAddColumns);
    if !is_msck && add_columns_comment.is_none() {
        return None;
    }

    let resolved = context_catalog::resolve(trino, config, query, catalog).await;
    let raw_catalog = resolved.as_deref().or(config.default_catalog.as_deref());
    let default_database = database.or(config.default_database.as_deref());

    let target = if is_msck {
        target_table::parse_msck_target(query, raw_catalog, default_database)?
    } else {
        target_table::parse_target_table(
            query,
            TargetStatement::AlterTableAddColumns,
            raw_catalog,
            default_database,
        )?
    };

    let probe = entity_check::probe(
        trino,
        config,
        &target.catalog,
        &target.schema,
        &target.table,
    )
    .await;

    if is_msck && matches!(probe, Probe::Table { iceberg: true }) {
        return Some(ImmediateFailure {
            failure: Failure::msck_iceberg(),
            writes_result_file: false,
        });
    }

    let comment = if is_msck {
        comment.filter(|error| error.target == Target::MsckRepair)
    } else {
        add_columns_comment
    }?;

    match probe {
        Probe::Missing | Probe::View | Probe::Table { iceberg: false } => Some(ImmediateFailure {
            failure: comment.into(),
            writes_result_file: true,
        }),
        Probe::Table { iceberg: true } | Probe::NoCatalog | Probe::Unknown => None,
    }
}

/// 構文チェックの後の判定: `comment_parse_error::detect` が対象にした文で、本物が実際に FAILED にするか。DESCRIBE は
/// 開始時の `check`（`entity_check::check` の結果）をそのまま使い（呼び出し側で先に bool にする。
/// `Check::Reject` の `Box<Response>` を async の境界越しに借用すると `dispatch` が `Handler` を実装
/// できなくなる）、SHOW CREATE TABLE・ALTER TABLE の RENAME TO・DROP COLUMN は名前を読み直して
/// `entity_check::probe` をもう 1 回だけ投げる（問い合わせが増えるのはブロックコメントが決め手の位置に
/// あるときだけ。design-checklist #39）。
pub(super) async fn comment_parse_error_failure(
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
