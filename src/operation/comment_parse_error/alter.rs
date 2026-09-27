//! `comment_parse_error` の ALTER TABLE 部分（ADD COLUMNS・DROP COLUMN・RENAME TO の判定と、
//! コメント無しの DROP COLUMN の判定）。親モジュールから切り出したもの（挙動を変えない移動。#257）。

use crate::failure::DDL_ENGINE_UNSUPPORTED;

use super::super::classification::substatement_type;
use super::super::reported_query;
use super::super::target_table::if_follows;
use super::{ParseError, Target, head_reason, position, scan, table_name_reason, valid_name};

pub(super) fn alter(query: &str) -> Option<ParseError> {
    // `ALTER TABLE IF EXISTS ...` は本物が開始時に弾く（今回の対象外。D1）。
    if if_follows(query, "ALTER") {
        return None;
    }
    let (hit, name_start) = scan(query, &["ALTER", "TABLE"])?;
    if !valid_name(query, name_start) {
        return None;
    }
    // 動作は `classification::alter_table_action` の値で見るが、ADD は複数形の COLUMNS のときだけ
    // （単数の ADD COLUMN は Trino だけの綴りで対象外。D1）。ADD PARTITION・DROP PARTITION・
    // SET TBLPROPERTIES などは本物で成功する（実測 a8〜a10）ので None。
    let target = match substatement_type(query) {
        Some("ALTER_TABLE_ADD_COLUMN") if adds_columns_plural(query) => Target::AlterAddColumns,
        Some("ALTER_TABLE_DROP_COLUMN") => Target::AlterDropColumn,
        Some("ALTER_TABLE_RENAME") => Target::AlterRename,
        Some("ALTER_TABLE_REPLACE_COLUMN") => Target::AlterReplaceColumns,
        Some("ALTER_TABLE_CHANGE_COLUMN") => Target::AlterChangeColumn,
        _ => return None,
    };

    // r1・r3: REPLACE COLUMNS・CHANGE COLUMN は ALTER の直後のコメント（hit.index == 1）のときだけ
    // 本物が失敗させる（2026-09-27 実測。#257。先頭・TABLE の後のコメントは未実測で None）。
    if matches!(
        target,
        Target::AlterReplaceColumns | Target::AlterChangeColumn
    ) {
        let hit = hit.filter(|hit| hit.index == 1)?;
        let (alter, start) = hit.keyword?;
        let (line, col) = position::position(query, start);
        return Some(ParseError {
            target,
            reason: format!(
                "FAILED: ParseException line {line}:{col} cannot recognize input near '{alter}' '/' '*' in alter statement"
            ),
            error_message: Some(DDL_ENGINE_UNSUPPORTED.to_string()),
            category: 2,
            error_type: 1006,
            hive_only: true,
        });
    }

    let (reason, hive_only) = match hit {
        Some(hit) => {
            let (line, col) = position::position(query, hit.comment_at);
            let reason = match hit.index {
                0 => head_reason(query, hit.comment_at, line, col),
                // ALTER の後ろは、コメントの位置でなく ALTER 自身の位置（実測 1:0。空白 2 つ・改行でも 1:0。D5）。
                1 => {
                    let (alter, start) = hit.keyword?;
                    let (aline, acol) = position::position(query, start);
                    format!(
                        "FAILED: ParseException line {aline}:{acol} cannot recognize input near '{alter}' '/' '*' in alter statement"
                    )
                }
                2 => table_name_reason(query, hit.comment_at, line, col),
                _ => unreachable!("ALTER TABLE のチェックポイントは 3 つ"),
            };
            (reason, false)
        }
        None => {
            // g3: 名前と複数形 ADD COLUMNS の間（Target::AlterAddColumns だけ。2026-09-27 実測。#257）。
            if target != Target::AlterAddColumns {
                return None;
            }
            let comment_at = add_columns_comment(query, name_start)?;
            let (line, col) = position::position(query, comment_at);
            let token = position::leading_token(query, comment_at);
            (
                format!(
                    "FAILED: ParseException line {line}:{col} cannot recognize input near '/' '*' '{token}' in alter table statement"
                ),
                true,
            )
        }
    };
    // RENAME TO・DROP COLUMN だけ category 2・error_type 1006 で、ErrorMessage が reason と別（D4）。
    let (error_message, category, error_type) = match target {
        Target::AlterRename => (Some(DDL_ENGINE_UNSUPPORTED.to_string()), 2, 1006),
        Target::AlterDropColumn => (Some(drop_column_message(query)?), 2, 1006),
        _ => (None, 1, 1003),
    };
    Some(ParseError {
        target,
        reason,
        error_message,
        category,
        error_type,
        hive_only,
    })
}

/// 名前と複数形 `ADD COLUMNS` の間にブロックコメントがあれば、その位置（`/` の位置）を返す（g3。
/// 2026-09-27 実測。#257）。単数の `ADD COLUMN`・ほかの動作は呼び出し側（`alter` の `target` の判定）が
/// 先に弾く。
fn add_columns_comment(query: &str, name_start: usize) -> Option<usize> {
    let mut cursor = athena_sql::Cursor::new(&query[name_start..]);
    let name = cursor.qualified_name()?;
    let comment_at = position::comment_start(query, name_start + name.end)?;
    (cursor.keyword("ADD") && cursor.keyword("COLUMNS")).then_some(comment_at)
}

/// `ADD` の直後が複数形の `COLUMNS` か（単数形の `ADD COLUMN` は Trino だけの綴りで対象外。D1）。
fn adds_columns_plural(query: &str) -> bool {
    let mut cursor = athena_sql::Cursor::new(query);
    cursor.keyword("ALTER")
        && cursor.keyword("TABLE")
        && cursor.qualified_name().is_some()
        && cursor.keyword("ADD")
        && cursor.keyword("COLUMNS")
}

/// `DROP COLUMN` の `COLUMN` の位置から、AthenaError.ErrorMessage を作る（2026-09-26 実測 n7・n9。ラウンド 3）。
/// 位置は畳んだ文で数えた行と列 + 1（`quoted_names::position` と同じ UTF-16 の数え方に + 1 を重ねる。D5）。
fn drop_column_message(query: &str) -> Option<String> {
    let (_, column, line, col) = drop_column_keywords(query)?;
    Some(drop_column_error_message(column, line, col))
}

fn drop_column_error_message(column: &str, line: usize, col: usize) -> String {
    format!(
        "line {line}:{}: mismatched input '{column}' expecting 'PARTITION'",
        col + 1
    )
}

/// `ALTER TABLE <名前> DROP COLUMN` の `DROP` と `COLUMN` の綴り（書いたまま）と、`COLUMN` の行と列。
fn drop_column_keywords(query: &str) -> Option<(&str, &str, usize, usize)> {
    let mut cursor = athena_sql::Cursor::new(query);
    if !(cursor.keyword("ALTER") && cursor.keyword("TABLE")) {
        return None;
    }
    cursor.qualified_name()?;
    if !cursor.keyword("DROP") {
        return None;
    }
    let drop_end = query.len() - cursor.rest().len();
    let drop = &query[drop_end - "DROP".len()..drop_end];
    if !cursor.keyword("COLUMN") {
        return None;
    }
    let end = query.len() - cursor.rest().len();
    let start = end - "COLUMN".len();
    let (line, col) = position::position(query, start);
    Some((drop, &query[start..end], line, col))
}

/// コメント無しの `ALTER TABLE <名前> DROP COLUMN` を本物の Hive のパーサが落とす ParseException（2026-09-20 実測
/// #39 d1。#256）。StateChangeReason は `COLUMN` の 0 始まりの位置、ErrorMessage はブロックコメントの形と同じ
/// + 1 の位置。対象の表が Hive 表か無い表かは呼び出し側（`comment_parse_check::plain_alter_failure`）が見る。
pub(in crate::operation) fn plain_drop_column(query: &str) -> Option<ParseError> {
    let (drop, column, line, col) = drop_column_keywords(query)?;
    Some(ParseError {
        target: Target::AlterDropColumn,
        reason: format!(
            "FAILED: ParseException line {line}:{col} mismatched input '{column}' expecting PARTITION near '{drop}' in drop partition statement"
        ),
        error_message: Some(drop_column_error_message(column, line, col)),
        category: 2,
        error_type: 1006,
        hive_only: false,
    })
}

/// pos1: 受け取った文（`awsdatacatalog.` を落とす前）が「ALTER の直後のブロックコメント
/// （`hit.index == 1`）・DROP COLUMN・無引用ちょうど 3 部の名前・1 部目が `awsdatacatalog`
/// （大文字小文字によらない）」の形なら、本物の AthenaError.ErrorMessage を作る。位置は表名の
/// 1 文字目の 0 始まり（`+1` しない）、input は文頭から表名の直前までを書いたままの綴り
/// （2026-09-27 実測 pos1。#257）。対象が Hive 表かどうかは呼び出し側（`start_checks.rs`）が見る。
pub(in crate::operation) fn awsdatacatalog_drop_column_error_message(
    query: &str,
) -> Option<String> {
    if substatement_type(query) != Some("ALTER_TABLE_DROP_COLUMN") {
        return None;
    }
    let (hit, name_start) = scan(query, &["ALTER", "TABLE"])?;
    let _hit = hit.filter(|hit| hit.index == 1)?;
    let name = athena_sql::Cursor::new(&query[name_start..]).qualified_name()?;
    let [catalog, _db, table] = name.parts.as_slice() else {
        return None;
    };
    if name.parts.iter().any(|part| part.text.starts_with('"'))
        || !reported_query::is_aws_data_catalog(catalog.text)
    {
        return None;
    }
    let table_start = name_start + table.start;
    let (line, col) = position::position(query, table_start);
    Some(format!(
        "line {line}:{col}: no viable alternative at input '{}'",
        &query[..table_start]
    ))
}

#[cfg(test)]
mod tests;
