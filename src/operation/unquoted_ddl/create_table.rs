//! 本物の Athena が StartQueryExecution の時点で弾く、CTAS でない無引用の `CREATE TABLE` の文言
//! （2026-09-26 実測。#208）。

use athena_sql::{Cursor, QualifiedName, skip_leading_trivia};

use super::super::classification::substatement_type;
use super::super::target_table::table_name_start;
use super::{end_of, no_viable_alternative, start_of};

mod hive;

pub(in crate::operation) use hive::s3_tables_rejection;

/// 場所を指定しない `CREATE TABLE` に本物が返す固定文言（位置なし）。
pub(in crate::operation) const NO_LOCATION: &str =
    "No location was specified for table. An S3 location must be specified";

/// S3 Tables の Context で別カタログの名前の `CREATE TABLE` に本物が返す文言の前半（`ddl` は小文字。DESCRIBE の
/// `Unsupported DDL with 2 catalogs` とは綴りが違う）。後ろに `: <文>` が付く（2026-09-26 実測。#224）。
const TWO_CATALOGS: &str = "Unsupported ddl with 2 catalogs";

/// 本物が開始時に弾く、CTAS でない無引用の `CREATE TABLE` なら、その文言を返す。
/// `unquoted_ddl::rejection` から、ALTER TABLE でなければ呼ばれる。
///
/// `substatement_type` が `CREATE_TABLE`（CTAS・CREATE VIEW・`CREATE OR REPLACE TABLE` を除く）で、
/// 名前が `CREATE TABLE` か `CREATE TABLE IF NOT EXISTS` の直後にあり、4 部未満かつ引用符付きの部分が
/// 無いときだけ、列の並びを読む（名前が引用符付きか 4 部以上なら `quoted_names` の担当か未実測）。
///
/// `s3_tables` は QueryExecutionContext の Catalog が S3 Tables か。S3 Tables は場所を要らないので、本物は
/// 1〜2 部の名前の場所の無い形を作り、No location にしない（列の並びと `WITH (` の NV は同じ。2026-09-26 実測
/// h1〜h7。#221）。1 部目が `awsdatacatalog` の 3 部は `Unsupported ddl with 2 catalogs: <文>`（#224）。
pub(super) fn rejection(query: &str, s3_tables: bool) -> Option<String> {
    if substatement_type(query) != Some("CREATE_TABLE") {
        return None;
    }
    let sql = query.trim_start_matches([' ', '\t', '\r', '\n']);
    let (name, mut cursor) = table_name(sql)?;
    if name.parts.len() >= 4 || name.parts.iter().any(|part| part.text.starts_with('"')) {
        return None;
    }
    if !cursor.punct(b'(') {
        return None;
    }
    let statement_start = sql.len() - skip_leading_trivia(sql).len();
    let message = columns(sql, statement_start, &mut cursor)?;
    if !s3_tables || message != NO_LOCATION {
        return Some(message);
    }
    // 無引用の 3 部の名前は S3 Tables の Context でも別のカタログを指す（S3 Tables のカタログ名は `/` を含み引用符が
    // 要る）。本物は 1 部目がちょうど小文字の `awsdatacatalog` のときだけ、前後の空白を落とした文を付けて
    // `Unsupported ddl with 2 catalogs` で弾いた。大文字混じりの `AwsDataCatalog` は開始して FAILED、実在しない
    // カタログは DATACATALOG_NOT_FOUND だったが、どちらも No location のまま弾く（2026-09-26 実測 i1〜i22。#224）。
    match name.parts.as_slice() {
        [catalog, _, _] if catalog.text == "awsdatacatalog" => Some(format!(
            "{TWO_CATALOGS}: {}",
            sql.trim_end_matches([' ', '\t', '\r', '\n'])
        )),
        [_, _, _] => Some(message),
        _ => None,
    }
}

/// `rejection` が No location を返す文の、無引用の 3 部の名前の 1 部目と 2 部目（書いたとおり）。
/// 3 部でないか引用符付きの部分があれば None。名前は `rejection` と同じ `table_name` で読む（#227）。
pub(in crate::operation) fn three_part_name(query: &str) -> Option<(&str, &str)> {
    let sql = query.trim_start_matches([' ', '\t', '\r', '\n']);
    match table_name(sql)?.0.parts.as_slice() {
        [catalog, namespace, _]
            if ![catalog, namespace]
                .iter()
                .any(|part| part.text.starts_with('"')) =>
        {
            Some((catalog.text, namespace.text))
        }
        _ => None,
    }
}

/// S3 Tables でない Context なら `rejection` が No location を返す文の、無引用の 2 部の名前の 1 部目（書いたとおり）。
/// S3 Tables の Context では `rejection` が弾かず、本物は 1 部目の名前空間に作る（#231）。
pub(in crate::operation) fn two_part_namespace(query: &str) -> Option<&str> {
    if rejection(query, false)? != NO_LOCATION {
        return None;
    }
    let sql = query.trim_start_matches([' ', '\t', '\r', '\n']);
    match table_name(sql)?.0.parts.as_slice() {
        [namespace, _] => Some(namespace.text),
        _ => None,
    }
}

/// `CREATE TABLE` か `CREATE TABLE IF NOT EXISTS` の直後の名前と、名前の直後の位置の cursor。
fn table_name(sql: &str) -> Option<(QualifiedName<'_>, Cursor<'_>)> {
    let rest = table_name_start(sql, &["CREATE", "TABLE"])
        .or_else(|| table_name_start(sql, &["CREATE", "TABLE", "IF", "NOT", "EXISTS"]))?;
    let mut cursor = Cursor::new(rest);
    let name = cursor.qualified_name()?;
    Some((name, cursor))
}

/// 列 1 つを処理した結果。
enum ColumnOutcome {
    /// `,` を読んだ。次の列へ。
    Next,
    /// `)` を読んだ。列の並びの終わり（cursor はその直後）。
    EndOfColumns,
    /// 文言が決まった。
    Rejected(String),
    /// 実測していない形（呼び出し元は None のまま返す）。
    Unmeasured,
}

/// `(` の直後から列の並びを読み、最初に文言が決まったところで返す。読み切れなければ（列 0 個を含む）None。
fn columns(sql: &str, statement_start: usize, cursor: &mut Cursor) -> Option<String> {
    loop {
        match column(sql, statement_start, cursor) {
            ColumnOutcome::Next => {}
            ColumnOutcome::EndOfColumns => return after_columns(sql, statement_start, cursor),
            ColumnOutcome::Rejected(message) => return Some(message),
            ColumnOutcome::Unmeasured => return None,
        }
    }
}

/// 列名（`LIKE` もただの列の名前として読む）→ 型 → 型の後ろ、の順に読む。
fn column(sql: &str, statement_start: usize, cursor: &mut Cursor) -> ColumnOutcome {
    // 列名、型名の順。
    if let Some(outcome) = word(sql, statement_start, cursor) {
        return outcome;
    }
    if let Some(outcome) = word(sql, statement_start, cursor) {
        return outcome;
    }
    match type_arguments(sql, statement_start, cursor) {
        Some(outcome) => outcome,
        None => after_type(sql, statement_start, cursor),
    }
}

/// 型名の後ろの `(...)`／`<...>`。無ければ触れずに None（呼び出し元は型の後ろの語へ進む）。
/// 読み飛ばせた（`(...)` が数字だけ、`<...>` が許された文字だけ）ときも None（cursor は進める）。
/// R-C4 の NV か実測していない形で止まるときは Some を返す（cursor は進めない）。
fn type_arguments(sql: &str, statement_start: usize, cursor: &mut Cursor) -> Option<ColumnOutcome> {
    if cursor.punct(b'(') {
        return parenthesized_type_arguments(sql, statement_start, cursor);
    }
    if skip_leading_trivia(cursor.rest()).starts_with('<') {
        return angle_bracket_arguments(cursor);
    }
    None
}

/// `型名(` の中。最初のトークンが数字なら `)` まで数字・`,`・空白だけを読み飛ばす（他の文字 → 実測していない形）。
/// 識別子なら R-C4 の NV。
fn parenthesized_type_arguments(
    sql: &str,
    statement_start: usize,
    cursor: &mut Cursor,
) -> Option<ColumnOutcome> {
    let inner = cursor.rest();
    let first_is_digit = skip_leading_trivia(inner)
        .as_bytes()
        .first()
        .is_some_and(u8::is_ascii_digit);
    if first_is_digit {
        return match skip_numeric_arguments(inner) {
            Some(rest) => {
                *cursor = Cursor::new(rest);
                None
            }
            None => Some(ColumnOutcome::Unmeasured),
        };
    }
    // 引用符付きの語（`row("f" int)`）も同じ NV（2026-09-26 実測 q6。#221）。
    Some(match identifier_span(sql, inner) {
        Some((start, end)) => ColumnOutcome::Rejected(no_viable_alternative(
            sql,
            start,
            &sql[statement_start..end],
        )),
        None => ColumnOutcome::Unmeasured,
    })
}

/// `型名<` の中。深さを数えて対応する `>` まで読み飛ばす。中身が識別子の文字・数字・`,`・`:`・`<`・`>`・
/// 空白だけなら読み飛ばして続ける、他の文字が混じっていれば実測していない形。
fn angle_bracket_arguments(cursor: &mut Cursor) -> Option<ColumnOutcome> {
    let after_open = &skip_leading_trivia(cursor.rest())[1..];
    match skip_angle_brackets(after_open) {
        Some(rest) => {
            *cursor = Cursor::new(rest);
            None
        }
        None => Some(ColumnOutcome::Unmeasured),
    }
}

/// 型の後ろ: `COMMENT '...'` を読み飛ばし、`,` → 次の列、`)` → 列の終わり、識別子 → NV(その語)、
/// `.` → NV(`.`)、それ以外 → 実測していない形。
fn after_type(sql: &str, statement_start: usize, cursor: &mut Cursor) -> ColumnOutcome {
    skip_comment_clause(cursor);
    if cursor.punct(b',') {
        return ColumnOutcome::Next;
    }
    if cursor.punct(b')') {
        return ColumnOutcome::EndOfColumns;
    }
    let rest = cursor.rest();
    if skip_leading_trivia(rest).starts_with('.') {
        let start = start_of(sql, rest);
        return ColumnOutcome::Rejected(no_viable_alternative(
            sql,
            start,
            &sql[statement_start..start + 1],
        ));
    }
    match identifier_span(sql, rest) {
        Some((start, end)) => ColumnOutcome::Rejected(no_viable_alternative(
            sql,
            start,
            &sql[statement_start..end],
        )),
        None => ColumnOutcome::Unmeasured,
    }
}

/// `)`（列の並びの終わり）の後ろ: 任意の `COMMENT '...'` を読み飛ばし、そのあと終わり（空白・コメントのみ）
/// なら No location、`WITH (` なら NV(`(`)、それ以外は None。
fn after_columns(sql: &str, statement_start: usize, cursor: &mut Cursor) -> Option<String> {
    skip_comment_clause(cursor);
    if cursor.at_end() {
        return Some(NO_LOCATION.to_string());
    }
    if cursor.keyword("WITH") {
        let rest = cursor.rest();
        if skip_leading_trivia(rest).starts_with('(') {
            let start = start_of(sql, rest);
            return Some(no_viable_alternative(
                sql,
                start,
                &sql[statement_start..start + 1],
            ));
        }
    }
    None
}

/// 列名か型名を 1 語読む。無引用の識別子なら読んで None。引用符付きなら、文の最初の語からその語の終わりまでの
/// NV（Hive では文字列。2026-09-26 実測 q1〜q3・q5・q8。#221）。識別子でなければ実測していない形。
fn word(sql: &str, statement_start: usize, cursor: &mut Cursor) -> Option<ColumnOutcome> {
    let rest = cursor.rest();
    if skip_leading_trivia(rest).starts_with('"') {
        return Some(match identifier_span(sql, rest) {
            Some((start, end)) => ColumnOutcome::Rejected(no_viable_alternative(
                sql,
                start,
                &sql[statement_start..end],
            )),
            None => ColumnOutcome::Unmeasured,
        });
    }
    (!cursor.identifier()).then_some(ColumnOutcome::Unmeasured)
}

/// 任意の `COMMENT '...'` を読み飛ばす（無ければ何もしない）。
fn skip_comment_clause(cursor: &mut Cursor) {
    if cursor.keyword("COMMENT") {
        cursor.literal();
    }
}

/// `rest`（`sql` の一部）の先頭のトークンが識別子なら、その範囲（トリビアを除く）を返す。
fn identifier_span(sql: &str, rest: &str) -> Option<(usize, usize)> {
    let mut probe = Cursor::new(rest);
    if !probe.identifier() {
        return None;
    }
    Some((start_of(sql, rest), end_of(sql, probe.rest())))
}

/// `(` の直後の文字列から、数字・`,`・空白だけを読み飛ばして `)` の直後を返す。他の文字が混じっていれば None。
fn skip_numeric_arguments(inner: &str) -> Option<&str> {
    let bytes = inner.as_bytes();
    let mut i = 0;
    loop {
        match bytes.get(i)? {
            b')' => return Some(&inner[i + 1..]),
            b'0'..=b'9' | b',' | b' ' | b'\t' | b'\r' | b'\n' => i += 1,
            _ => return None,
        }
    }
}

/// `<` の直後の文字列から、深さを数えて対応する `>` の直後を返す。中身が識別子の文字・数字・`,`・`:`・
/// `<`・`>`・空白だけなら Some、他の文字が混じっていれば None。
fn skip_angle_brackets(after_open: &str) -> Option<&str> {
    let bytes = after_open.as_bytes();
    let mut depth = 1i32;
    let mut i = 0usize;
    loop {
        match *bytes.get(i)? {
            b'<' => depth += 1,
            b'>' => {
                depth -= 1;
                if depth == 0 {
                    return Some(&after_open[i + 1..]);
                }
            }
            b',' | b':' | b' ' | b'\t' | b'\r' | b'\n' => {}
            byte if byte.is_ascii_alphanumeric() || byte == b'_' => {}
            _ => return None,
        }
        i += 1;
    }
}

#[cfg(test)]
mod tests;
