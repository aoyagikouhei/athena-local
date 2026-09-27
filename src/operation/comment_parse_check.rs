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
use super::reported_query;
use super::table_format::{TableFormat, TargetStatement};
use super::target_table;

/// 構文チェックの前の判定: `query` が `MSCK REPAIR TABLE` か、`comment_parse_error::detect` が
/// `AlterAddColumns`（`ALTER TABLE ... ADD COLUMNS` の複数形にブロックコメントが決め手の位置にある形）・
/// `AlterReplaceColumns`・`AlterChangeColumn`（ALTER の直後のコメント。r1・r3）・`Describe` の
/// `hive_only` なチェックポイント（`DESCRIBE EXTENDED` の `EXTENDED` の直後。de1）のどれかを返すときだけ
/// 対象の存在を確かめる（Trino にこれらの構文が無く、構文チェックへ進むと必ず構文エラーになるため。
/// 2026-09-27 実測。#257）。対象が Iceberg 表なら、ブロックコメントの有無・位置によらず本物は
/// 別の失敗（`Failure::msck_iceberg`）で FAILED にする（MSCK だけ）。Hive・ビュー・無い表は、ブロックコメントが決め手の
/// 位置にあるとき（`detect` が Some）だけ、その ParseException で FAILED にする。名前が引用符付きの部品を
/// 含むか 4 部以上・カタログが無い・問い合わせが失敗したとき（`Probe::NoCatalog`・`Probe::Unknown`）は
/// 何もせず、今までどおり構文チェックへ進む（2026-09-26 実測。#244）。問い合わせが増えるのは MSCK と、
/// コメント入りの ADD COLUMNS・REPLACE COLUMNS・CHANGE COLUMN・DESCRIBE EXTENDED のときだけ（design-checklist #39）。
pub(super) async fn pre_syntax_check_failure(
    trino: &Trino,
    config: &Config,
    query: &str,
    catalog: Option<&str>,
    database: Option<&str>,
) -> Option<ImmediateFailure> {
    use comment_parse_error::Target;

    // 本物は ALTER TABLE の名前の 1 部目の `awsdatacatalog.` を Context のカタログとして落とす（2026-09-26 実測 m33。
    // #242）。構文チェックの後の判定と同じく、落とした後の文と修飾の DB で確かめる。MSCK REPAIR TABLE の
    // `awsdatacatalog.` は測っていないので落とさない（名前のカタログとして引き、無ければ今までどおり）。
    let rewritten = reported_query::drop_catalog(query, catalog);
    let (query, database) = match &rewritten {
        Some(rewritten) => (rewritten.query.as_str(), Some(rewritten.database.as_str())),
        None => (query, database),
    };
    let is_msck = classification::substatement_type(query) == Some("MSCK_REPAIR");
    let comment = comment_parse_error::detect(query);
    // MSCK 以外で構文チェックの前に判定するのは、Trino に構文が無い ALTER TABLE の ADD COLUMNS（複数形）・
    // REPLACE COLUMNS・CHANGE COLUMN と、DESCRIBE EXTENDED（`EXTENDED` の直後のコメントだけ。`hive_only`
    // で見分ける。DESCRIBE の他のチェックポイントは Trino がそのまま構文チェックを通すので、構文チェックの
    // 後（`comment_parse_error_failure`）で判定する）だけ（2026-09-27 実測。#257）。
    let pre_check_comment = comment.clone().filter(|error| {
        !is_msck
            && (matches!(
                error.target,
                Target::AlterAddColumns | Target::AlterReplaceColumns | Target::AlterChangeColumn
            ) || (error.target == Target::Describe && error.hive_only))
    });
    if !is_msck && pre_check_comment.is_none() {
        return None;
    }

    let resolved = context_catalog::resolve(trino, config, query, catalog).await;
    let raw_catalog = resolved.as_deref().or(config.default_catalog.as_deref());
    let default_database = database.or(config.default_database.as_deref());

    let target = if is_msck {
        target_table::parse_msck_target(query, raw_catalog, default_database)?
    } else if pre_check_comment
        .as_ref()
        .is_some_and(|error| error.target == Target::Describe)
    {
        target_table::parse_describe_extended_target(query, raw_catalog, default_database)?
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

    if is_msck
        && matches!(
            probe,
            Probe::Table {
                format: Some(TableFormat::Iceberg)
            }
        )
    {
        return Some(ImmediateFailure {
            failure: Failure::msck_iceberg(),
            writes_result_file: false,
            runs_ctas_query: false,
        });
    }

    let comment = if is_msck {
        comment.filter(|error| error.target == Target::MsckRepair)
    } else {
        pre_check_comment
    }?;

    // `comment.hive_only` が true なチェックポイント（#257 の g1 など）は、ビュー・無い表を今までどおり
    // Trino に送る（Hive 表だけ本物どおり失敗）。#244 の既存のチェックポイントは hive_only が false で
    // ビュー・無い表でも今までどおり失敗する。
    let ok = match probe {
        Probe::Table {
            format: Some(TableFormat::Hive),
        } => true,
        Probe::Missing | Probe::View => !comment.hive_only,
        Probe::Table { .. } | Probe::NoCatalog | Probe::Unknown => false,
    };
    ok.then(|| ImmediateFailure {
        failure: comment.into(),
        writes_result_file: true,
        runs_ctas_query: false,
    })
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
            let probe = entity_check::probe(
                trino,
                config,
                &target.catalog,
                &target.schema,
                &target.table,
            )
            .await;
            // `parse_error.hive_only` は #257 の g1 のような新しいチェックポイントだけ true
            // （ビュー・無い表は今までどおり Trino に送る）。#244 の既存のチェックポイントは false のまま。
            let ok = match probe {
                Probe::Table {
                    format: Some(TableFormat::Hive),
                } => true,
                Probe::Missing | Probe::View => !parse_error.hive_only,
                Probe::Table { .. } | Probe::NoCatalog | Probe::Unknown => false,
            };
            ok.then(|| parse_error.into())
        }
        // REPLACE COLUMNS・CHANGE COLUMN は Trino に構文が無く、構文チェックの前（`pre_syntax_check_failure`）
        // だけで判定する（r1・r3。#257）。このパスは Trino が構文を通した文だけが届くので、実際には来ない。
        Target::MsckRepair
        | Target::AlterAddColumns
        | Target::AlterReplaceColumns
        | Target::AlterChangeColumn => None,
    }
}

/// コメント無しの `ALTER TABLE ... DROP COLUMN`・`RENAME TO` を、本物は Hive 表と無い表で開始後に FAILED にする
/// （2026-09-20 実測 #39 d1・09-21 #43 b1・09-25 #204 alt-rename-u・#217 n22。#256）。DROP COLUMN は Hive のパーサの
/// ParseException、RENAME TO は Hive 表なら Glue の `Table cannot be renamed`、無い表なら `Table not found`。
/// Iceberg 表は本物も成功する。ビュー・コメントのある形（`comment_parse_error::detect` が拾わない位置のもの）は
/// 測っていないので、カタログが無い・問い合わせが失敗したときと同じく None（今までどおり Trino へ）。
/// hive でも iceberg でもないコネクタ（memory など）の表も、形式を判定しないので None（#39。#264）。
/// 問い合わせが増えるのはこの 2 つの文のときだけ（design-checklist #39）。
pub(super) async fn plain_alter_failure(
    trino: &Trino,
    config: &Config,
    statement: &str,
    resolved: Option<&str>,
    database: Option<&str>,
) -> Option<Failure> {
    let rename = match classification::substatement_type(statement) {
        Some("ALTER_TABLE_DROP_COLUMN") => false,
        Some("ALTER_TABLE_RENAME") => true,
        _ => return None,
    };
    if has_comment(statement) {
        return None;
    }
    let raw_catalog = resolved.or(config.default_catalog.as_deref());
    let default_database = database.or(config.default_database.as_deref());
    // ALTER の名前の前のキーワードは ADD COLUMNS と同じ `ALTER TABLE`（`comment_parse_error_failure` と同じ）。
    let target = target_table::parse_target_table(
        statement,
        TargetStatement::AlterTableAddColumns,
        raw_catalog,
        default_database,
    )?;
    let probe = entity_check::probe(
        trino,
        config,
        &target.catalog,
        &target.schema,
        &target.table,
    )
    .await;
    match (probe, rename) {
        (
            Probe::Missing
            | Probe::Table {
                format: Some(TableFormat::Hive),
            },
            false,
        ) => comment_parse_error::plain_drop_column(statement).map(Into::into),
        (
            Probe::Table {
                format: Some(TableFormat::Hive),
            },
            true,
        ) => Some(Failure::rename_hive_table()),
        // 実測は小文字の名前だけ。Glue は名前を小文字で持つので小文字にする（大文字の名前は未実測）。
        (Probe::Missing, true) => Some(Failure::rename_table_not_found(
            &target.schema.to_lowercase(),
            &target.table.to_lowercase(),
        )),
        (Probe::View | Probe::Table { .. } | Probe::NoCatalog | Probe::Unknown, _) => None,
    }
}

/// 引用符（`'`・`"`。`athena_sql::statements` と同じ）の外にコメント（`/* */`・`--`）が 1 つでもあるか。
fn has_comment(statement: &str) -> bool {
    let bytes = statement.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'\'' | b'"' => i = athena_sql::skip_quoted(bytes, i),
            _ if athena_sql::comment_end(bytes, i).is_some() => return true,
            _ => i += 1,
        }
    }
    false
}
