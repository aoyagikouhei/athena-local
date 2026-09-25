//! 本物の Athena が StartQueryExecution の時点で弾く、無引用の `ALTER TABLE` と、CTAS でない無引用の
//! `CREATE TABLE`（`create_table` サブモジュール）の文言（2026-09-26 実測。#208）。

mod create_table;

use athena_sql::{Cursor, skip_leading_trivia};

use super::quoted_names::{escape, no_viable_alternative, position};
use super::target_table::{if_follows, table_name_start};

/// 本物が開始時に弾く無引用の `ALTER TABLE`・CTAS でない無引用の `CREATE TABLE` なら、その文言を返す。
/// 構文チェックの後、`quoted_names::rejection` の後で呼ぶ（引用符付きの名前の文言が先。実測
/// alt-addcol-q。#204 の順序を保つ）。`ALTER TABLE` でなければ `create_table::rejection` に回す（#208）。
///
/// `ALTER TABLE IF EXISTS <名前>` の後ろは、続く語が `ADD`・`DROP`・`RENAME` なら
/// `no viable alternative at input 'ALTER TABLE IF EXISTS'`（R-A1）、`ALTER`（`ALTER COLUMN`）なら
/// Trino 形の `mismatched input 'ALTER'. Expecting: '.', 'ADD', 'DROP', 'RENAME'`（R-A2）。それ以外は
/// 実測していない（Trino 自身が構文エラーにする形なので、実際にはここへ届かない）ので None にする。
///
/// `IF EXISTS` が無ければ、`ADD COLUMN`（単数。R-B1）・`RENAME COLUMN`・`SET PROPERTIES`・
/// `SET AUTHORIZATION`・`EXECUTE`・`ALTER COLUMN`・`DROP COLUMN IF EXISTS`（以上 R-B2）を弾く
/// （設計判断 D2・D5）。名前が引用符付きなら、`IF EXISTS` が無い限り `quoted_names::rejection` が必ず
/// 先に弾くので、ここでは None にする（無引用の名前だけを見る。#204 の粒度）。
pub(super) fn rejection(query: &str) -> Option<String> {
    // 本物は先頭の空白・タブ・改行を数えずに位置を出す（先頭のコメントは数える。quoted_names.rs と同じ）。
    let sql = query.trim_start_matches([' ', '\t', '\r', '\n']);
    let Some(rest) = table_name_start(sql, &["ALTER", "TABLE"]) else {
        return create_table::rejection(query);
    };
    let mut cursor = Cursor::new(rest);
    let name = cursor.qualified_name()?;
    let statement_start = sql.len() - skip_leading_trivia(sql).len();

    if if_follows(sql, "ALTER") {
        return if_exists_rejection(sql, statement_start, &mut cursor);
    }
    if name.parts.iter().any(|part| part.text.starts_with('"')) {
        return None;
    }
    no_if_exists_rejection(sql, statement_start, &mut cursor)
}

/// `ALTER TABLE IF EXISTS <名前>` の後ろ（R-A1・R-A2）。`cursor` は名前の直後の位置。
fn if_exists_rejection(sql: &str, statement_start: usize, cursor: &mut Cursor) -> Option<String> {
    let (exists_start, exists_end) = exists_span(sql);
    if cursor.keyword("ADD") || cursor.keyword("DROP") || cursor.keyword("RENAME") {
        return Some(no_viable_alternative(
            sql,
            exists_start,
            &sql[statement_start..exists_end],
        ));
    }
    let (start, end) = keyword_span(sql, cursor, "ALTER")?;
    Some(mismatched_expecting(
        sql,
        start,
        &sql[start..end],
        "'.', 'ADD', 'DROP', 'RENAME'",
    ))
}

/// `ALTER TABLE <名前>`（`IF EXISTS` 無し）の後ろ（R-B1・R-B2）。`cursor` は名前の直後の位置。
fn no_if_exists_rejection(
    sql: &str,
    statement_start: usize,
    cursor: &mut Cursor,
) -> Option<String> {
    if cursor.keyword("ADD") {
        let (start, end) = keyword_span(sql, cursor, "COLUMN")?;
        return Some(no_viable_alternative(
            sql,
            start,
            &sql[statement_start..end],
        ));
    }
    if cursor.keyword("DROP") {
        // `DROP COLUMN m`（IF EXISTS 無し）は本物も実行できる（対照 b19）ので弾かない。
        if cursor.keyword("COLUMN") && cursor.keyword("IF") {
            let (start, end) = keyword_span(sql, cursor, "EXISTS")?;
            return Some(mismatched_set(sql, start, &sql[start..end], "{<EOF>, '.'}"));
        }
        return None;
    }
    if cursor.keyword("RENAME") {
        let (start, end) = keyword_span(sql, cursor, "COLUMN")?;
        return Some(missing_to(sql, start, &sql[start..end]));
    }
    if cursor.keyword("SET") {
        let (start, end) = keyword_span(sql, cursor, "PROPERTIES")
            .or_else(|| keyword_span(sql, cursor, "AUTHORIZATION"))?;
        return Some(no_viable_alternative(
            sql,
            start,
            &sql[statement_start..end],
        ));
    }
    if let Some((start, end)) = keyword_span(sql, cursor, "EXECUTE") {
        return Some(no_viable_alternative(
            sql,
            start,
            &sql[statement_start..end],
        ));
    }
    let (start, end) = keyword_span(sql, cursor, "ALTER")?;
    Some(mismatched_expecting(
        sql,
        start,
        &sql[start..end],
        "'.', 'ADD', 'DROP', 'EXECUTE', 'RENAME', 'SET'",
    ))
}

/// `ALTER TABLE IF EXISTS` の `EXISTS` の範囲。呼び出し元が `if_follows` を確かめた後だけ呼ぶ
/// （`table_name_start` がすでに `IF` の後ろに `EXISTS` が続くことを確かめている）。
fn exists_span(sql: &str) -> (usize, usize) {
    let mut cursor = Cursor::new(sql);
    cursor.keyword("ALTER");
    cursor.keyword("TABLE");
    cursor.keyword("IF");
    let start = start_of(sql, cursor.rest());
    cursor.keyword("EXISTS");
    (start, end_of(sql, cursor.rest()))
}

/// `keyword` を読めれば、その範囲（先頭の空白・コメントを含まない）を返す。読めなければ位置を進めない。
fn keyword_span(sql: &str, cursor: &mut Cursor, keyword: &str) -> Option<(usize, usize)> {
    let start = start_of(sql, cursor.rest());
    cursor
        .keyword(keyword)
        .then(|| (start, end_of(sql, cursor.rest())))
}

/// `rest`（`Cursor::rest` の戻り値）の先頭の空白・コメントを読み飛ばした位置。
fn start_of(sql: &str, rest: &str) -> usize {
    sql.len() - skip_leading_trivia(rest).len()
}

/// `rest`（`Cursor::rest` の戻り値）が指す、直前の読み取りの終わりの位置。
fn end_of(sql: &str, rest: &str) -> usize {
    sql.len() - rest.len()
}

/// Trino 形の `mismatched input '...'. Expecting: ...`（大文字の Expecting、コロン付き。
/// `ALTER COLUMN` の R-A2・R-B2 で使う）。
fn mismatched_expecting(sql: &str, at: usize, input: &str, expecting: &str) -> String {
    let (line, column) = position(sql, at);
    format!(
        "line {line}:{column}: mismatched input '{}'. Expecting: {expecting}",
        escape(input)
    )
}

/// Trino 形の `mismatched input '...' expecting {...}`（小文字の expecting、集合。
/// `DROP COLUMN IF EXISTS` の R-B2 で使う）。
fn mismatched_set(sql: &str, at: usize, input: &str, set: &str) -> String {
    let (line, column) = position(sql, at);
    format!(
        "line {line}:{column}: mismatched input '{}' expecting {set}",
        escape(input)
    )
}

/// Trino 形の `missing 'TO' at '...'`（`RENAME COLUMN` の R-B2 で使う）。
fn missing_to(sql: &str, at: usize, input: &str) -> String {
    let (line, column) = position(sql, at);
    format!("line {line}:{column}: missing 'TO' at '{}'", escape(input))
}

#[cfg(test)]
mod tests;
