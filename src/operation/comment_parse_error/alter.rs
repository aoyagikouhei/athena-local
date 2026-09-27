//! `comment_parse_error` の ALTER TABLE 部分（ADD COLUMNS・DROP COLUMN・RENAME TO の判定と、
//! コメント無しの DROP COLUMN の判定）。親モジュールから切り出したもの（挙動を変えない移動。#257）。

use crate::failure::DDL_ENGINE_UNSUPPORTED;

use super::super::classification::substatement_type;
use super::super::target_table::if_follows;
use super::{ParseError, Target, head_reason, position, scan, table_name_reason, valid_name};

pub(super) fn alter(query: &str) -> Option<ParseError> {
    // `ALTER TABLE IF EXISTS ...` は本物が開始時に弾く（今回の対象外。D1）。
    if if_follows(query, "ALTER") {
        return None;
    }
    let (hit, name_start) = scan(query, &["ALTER", "TABLE"])?;
    let hit = hit?;
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
        _ => return None,
    };
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
        hive_only: false,
    })
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

#[cfg(test)]
mod tests;
