//! 本物の Hive のパーサが、SHOW CREATE TABLE・DESCRIBE／DESC・MSCK REPAIR TABLE・ALTER TABLE の
//! キーワードの間や名前の直前のブロックコメントで失敗させる ParseException を判定する
//! （2026-09-26 実測 ラウンド 2・3。#244）。#242 の `reported_query::describe_parse_error` を置き換える
//! 広い版。配線は `comment_parse_check.rs`（構文チェックの前の `pre_syntax_check_failure` と後の `comment_parse_error_failure`）。
//!
//! ここは**純粋な字句判定**だけを持つ: 対象の表が Iceberg かどうか・実在するかどうかは見ない。本物は
//! 表が Iceberg なら SHOW CREATE TABLE・DESCRIBE・ALTER の ADD COLUMNS／DROP COLUMN は成功させ、MSCK は
//! ブロックコメントの有無によらず別の失敗（2/1200）にする（D2・D3。2026-09-26 実測）。この判定は `detect`
//! の外（呼び出し側が `entity_check`／`table_format` の結果と合わせて、`detect` の結果を使うかどうかを
//! 決める）。そのため `detect` はブロックコメントの位置が本物の Hive パーサを落とす形と一致すれば、対象の
//! 表の種類によらず同じ `ParseError` を返す（後述のテストの「detect はテーブルの種類を見ない」参照）。

mod alter;
mod position;

use crate::failure::{Failure, SYSTEM, USER};

use alter::alter;
pub(in crate::operation) use alter::plain_drop_column;

/// 本物の Hive のパーサがブロックコメントで失敗させる文の種類。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Target {
    ShowCreateTable,
    Describe,
    MsckRepair,
    AlterAddColumns,
    AlterDropColumn,
    AlterRename,
}

/// 開始後に FAILED にする失敗の中身（`Failure` への変換は下の `From`）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ParseError {
    pub target: Target,
    /// StateChangeReason（`FAILED: ParseException ...`）。
    pub reason: String,
    /// AthenaError.ErrorMessage。`None` は `reason` と同じ（本物のほとんどの形。D4）。
    pub error_message: Option<String>,
    pub category: i32,
    pub error_type: i32,
}

/// `query` は StartQueryExecution の単一の文（前後の空白と `;` は落としてある）。対象の文で、
/// ブロックコメントが決め手の位置（先頭・キーワードの間・名前の直前）にあれば、本物の Hive の
/// パーサの ParseException を返す。決め手の位置より後ろ（名前の中・名前の後ろ・句の中）にしか
/// ブロックコメントが無ければ None（未実測。D1）。複数あれば最初のものだけを見る。
pub(super) fn detect(query: &str) -> Option<ParseError> {
    show_create_table(query)
        .or_else(|| describe(query))
        .or_else(|| msck_repair(query))
        .or_else(|| alter(query))
}

/// キーワード列の前後のどこかで見つかったブロックコメント。
struct Hit<'a> {
    /// 0 = 先頭、i = `keywords[i - 1]` の後ろ。
    index: usize,
    /// `/` の位置（元の SQL でのバイト位置）。
    comment_at: usize,
    /// 直前のキーワードの綴りと開始位置（先頭なら `None`）。
    keyword: Option<(&'a str, usize)>,
}

/// キーワード列 `keywords` の前後のどこかにブロックコメントがあれば、その `Hit` と、名前が始まる位置
/// （最後のキーワードの直後）を返す。キーワードが 1 つでも一致しなければ（この文の型でなければ）None。
/// ブロックコメントは `position::comment_start` で見つける（空白・行コメントだけ読み飛ばし、ブロック
/// コメント自体は読み飛ばさない）ので、`Cursor::keyword`（トリビアを丸ごと読み飛ばす）より先に確かめる。
fn scan<'a>(query: &'a str, keywords: &[&str]) -> Option<(Hit<'a>, usize)> {
    let mut cursor = athena_sql::Cursor::new(query);
    let mut hit = position::comment_start(query, 0).map(|comment_at| Hit {
        index: 0,
        comment_at,
        keyword: None,
    });
    for (i, keyword) in keywords.iter().enumerate() {
        if !cursor.keyword(keyword) {
            return None;
        }
        let end = query.len() - cursor.rest().len();
        if hit.is_none()
            && let Some(comment_at) = position::comment_start(query, end)
        {
            hit = Some(Hit {
                index: i + 1,
                comment_at,
                keyword: Some((&query[end - keyword.len()..end], end - keyword.len())),
            });
        }
    }
    let name_start = query.len() - cursor.rest().len();
    hit.map(|hit| (hit, name_start))
}

/// 名前が読めて、引用符付きの部品を含まず 4 部未満なら OK（開始時の判定 `quoted_names`／`unquoted_ddl` に
/// 任せる形は対象外。D1）。
fn valid_name(query: &str, start: usize) -> bool {
    let Some(name) = athena_sql::Cursor::new(&query[start..]).qualified_name() else {
        return false;
    };
    name.parts.len() < 4 && !name.parts.iter().any(|part| part.text.starts_with('"'))
}

/// 先頭のチェックポイント（0）の文言（4 つの文で共通）。
fn head_reason(query: &str, comment_at: usize, line: usize, col: usize) -> String {
    let token = position::leading_token(query, comment_at);
    format!(
        "FAILED: ParseException line {line}:{col} cannot recognize input near '/' '*' '{token}'"
    )
}

/// 名前の直前のチェックポイント（SHOW CREATE TABLE・MSCK REPAIR TABLE・ALTER TABLE の `TABLE` の後ろ）の文言。
fn table_name_reason(query: &str, comment_at: usize, line: usize, col: usize) -> String {
    let token = position::leading_token(query, comment_at);
    format!(
        "FAILED: ParseException line {line}:{col} cannot recognize input near '/' '*' '{token}' in table name"
    )
}

fn show_create_table(query: &str) -> Option<ParseError> {
    let (hit, name_start) = scan(query, &["SHOW", "CREATE", "TABLE"])?;
    if !valid_name(query, name_start) {
        return None;
    }
    let (line, col) = position::position(query, hit.comment_at);
    let reason = match hit.index {
        0 => head_reason(query, hit.comment_at, line, col),
        1 => {
            let (show, _) = hit.keyword?;
            format!(
                "FAILED: ParseException line {line}:{col} cannot recognize input near '{show}' '/' '*' in ddl statement"
            )
        }
        2 => {
            let (create, _) = hit.keyword?;
            format!(
                "FAILED: ParseException line {line}:{col} mismatched input '/' expecting TABLE near '{create}' in show statement"
            )
        }
        3 => table_name_reason(query, hit.comment_at, line, col),
        _ => unreachable!("SHOW CREATE TABLE のチェックポイントは 4 つ"),
    };
    Some(ParseError {
        target: Target::ShowCreateTable,
        reason,
        error_message: None,
        category: 1,
        error_type: 1003,
    })
}

/// `DESCRIBE` と `DESC` の両方を試す（`target_table::keywords` と同じ規則）。DESCRIBE の直後のケースは
/// 2026-09-22 に本番 Athena で最初に実測し（`DESCRIBE /* c */ t`）、DB を落とした後に同じ形になる
/// `DESCRIBE <db>./* c */<t>` を 2026-09-26 に m10 で確かめた（#242）。
fn describe(query: &str) -> Option<ParseError> {
    let (hit, name_start) = scan(query, &["DESCRIBE"]).or_else(|| scan(query, &["DESC"]))?;
    if !valid_name(query, name_start) {
        return None;
    }
    let (line, col) = position::position(query, hit.comment_at);
    let reason = match hit.index {
        0 => head_reason(query, hit.comment_at, line, col),
        // DESCRIBE・DESC の後ろは、コメントの位置でなく DESCRIBE・DESC 自身の位置（実測 1:0。D5）。
        1 => {
            let (keyword, start) = hit.keyword?;
            let (kline, kcol) = position::position(query, start);
            format!(
                "FAILED: ParseException line {kline}:{kcol} cannot recognize input near '{keyword}' '/' '*' in describe statement"
            )
        }
        _ => unreachable!("DESCRIBE のチェックポイントは 2 つ"),
    };
    Some(ParseError {
        target: Target::Describe,
        reason,
        error_message: None,
        category: 1,
        error_type: 1003,
    })
}

fn msck_repair(query: &str) -> Option<ParseError> {
    let (hit, name_start) = scan(query, &["MSCK", "REPAIR", "TABLE"])?;
    if !valid_name(query, name_start) {
        return None;
    }
    let (line, col) = position::position(query, hit.comment_at);
    let reason = match hit.index {
        0 => head_reason(query, hit.comment_at, line, col),
        1 | 2 => {
            let (keyword, _) = hit.keyword?;
            format!("FAILED: ParseException line {line}:{col} missing EOF at '/' near '{keyword}'")
        }
        3 => table_name_reason(query, hit.comment_at, line, col),
        _ => unreachable!("MSCK REPAIR TABLE のチェックポイントは 4 つ"),
    };
    Some(ParseError {
        target: Target::MsckRepair,
        reason,
        error_message: None,
        category: 1,
        error_type: 1003,
    })
}

/// `.txt` の理由・AthenaError の中身を `ParseError` からそのまま作る（1 か所にまとめる。配線側は
/// `.into()` を呼ぶだけにする）。`category` は `ParseError` の `1`／`2` を `Failure` の `SYSTEM`／`USER` に当てる
/// （同じ数値だが名前を持つ定数を経由する）。
impl From<ParseError> for Failure {
    fn from(error: ParseError) -> Self {
        Self {
            reason: error.reason,
            error_message: error.error_message,
            category: match error.category {
                2 => USER,
                _ => SYSTEM,
            },
            error_type: error.error_type,
            retryable: false,
        }
    }
}

#[cfg(test)]
mod tests;
