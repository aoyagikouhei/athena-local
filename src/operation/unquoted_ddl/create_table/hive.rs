//! QueryExecutionContext の Catalog が S3 Tables のとき、本物の Athena が Hive の `CREATE TABLE` として読んでから
//! 開始時に弾く `LOCATION` と `EXTERNAL`（2026-09-26 実測 n1〜n32。#229。2026-09-27 実測 s1〜s18。#248）。Trino の文法には
//! どちらも無いので、構文チェックより前に呼ぶ。LOCATION の無い `STORED AS`・`ROW FORMAT`・`CLUSTERED BY`・型付きの
//! `PARTITIONED BY`・未知のキーの `TBLPROPERTIES`（開始して FAILED。#248・#270）と、LOCATION 付きの 3 部の名前の 1 部目
//! （実在しないカタログは Context によらず DATACATALOG_NOT_FOUND）も同じ読み方で取り出す。句や IF NOT EXISTS・
//! 列の並びの有無・バッククォートによらないことは 2026-09-27 実測 t・u・v・w 群（#266）と cl・pr・pn 群（#270）で確かめた。

use athena_sql::{Cursor, skip_leading_trivia};

use crate::failure::Failure;

use super::{ColumnOutcome, column};

/// S3 Tables の Context で LOCATION 付きの Hive の `CREATE TABLE` に本物が返す文言（位置なし）。
const S3_TABLES_LOCATION: &str =
    "Table location can not be specified for tables hosted in S3 table buckets";

/// S3 Tables の Context で LOCATION の無い `CREATE EXTERNAL TABLE` に本物が返す文言（位置なし）。
const S3_TABLES_EXTERNAL: &str = "External keyword not supported for table type ICEBERG";

/// Hive の `CREATE TABLE` として読めた文（`read`）。
struct Hive<'a> {
    external: bool,
    /// 名前の部（書いたとおり）。バッククォートの名前は引用符ごとの 1 部。
    parts: Vec<&'a str>,
    /// 列の並び `(..)` があるか。
    columns: bool,
    /// 型付きの列の並びの `PARTITIONED BY`（Hive の書き方）があるか。Iceberg の書き方（`(n)`・`bucket(4, n)`）は読めない。
    partitioned: bool,
    clustered: bool,
    row_format: bool,
    stored_as: bool,
    location: bool,
    /// `TBLPROPERTIES` のキーと値（引用符の中身）。
    properties: Vec<(&'a str, &'a str)>,
}

/// 本物が S3 Tables で受理した TBLPROPERTIES のキー（大文字小文字によらない。2026-09-27 実測 tp1〜tp3・tp5。#270）。
const ICEBERG_PROPERTY_KEYS: &[&str] = &["table_type", "format", "write_compression"];

/// 本物が Hive の `CREATE TABLE` として読んでから弾く文なら、その文言を返す（S3 Tables の Context でだけ呼ぶ）。
///
/// 名前は無引用の 1〜3 部（3 部は 1 部目が大文字小文字によらず `awsdatacatalog`。実在しないカタログは
/// DATACATALOG_NOT_FOUND が先で（`location_catalog`）、ほかのカタログは測っていない）と、1 部のバッククォート（s11）。
/// LOCATION があれば句によらず Table location（n1〜n5・n20・s1〜s6・s11・s16・u0〜u7）。LOCATION が無ければ
/// `CREATE EXTERNAL TABLE` が句・IF NOT EXISTS・列の並びの有無によらず External の文言（n11・n12・s7〜s10・v0〜v9）。
pub(in crate::operation) fn s3_tables_rejection(query: &str) -> Option<&'static str> {
    let hive = read(query)?;
    match hive.parts.as_slice() {
        [_] | [_, _] => {}
        [catalog, _, _] if catalog.eq_ignore_ascii_case("awsdatacatalog") => {}
        _ => return None,
    }
    if hive.location {
        return Some(S3_TABLES_LOCATION);
    }
    hive.external.then_some(S3_TABLES_EXTERNAL)
}

/// S3 Tables の Context で、本物が開始してから FAILED にした LOCATION の無い非 EXTERNAL の `CREATE TABLE` の失敗。句が 2 つ
/// 以上あれば CLUSTERED BY > ROW FORMAT > STORED AS > 型付きの PARTITIONED BY > 列の並び無し > 未知のキーの TBLPROPERTIES の順に
/// 1 つを選ぶ（2026-09-26 実測 n21・vc4・w0〜w10・z6〜z17、2026-09-27 実測 s15・cl1・pr1〜pr10・pn1〜pn6・pa4・tp4・tp7。
/// #248・#266・#270）。名前は 1・2 部と、1 部目が `awsdatacatalog` の類でちょうど小文字ではない 3 部。ちょうど小文字の 3 部は
/// 2 catalogs が先（w3）、ほかのカタログの 3 部は測っていないので None。列の並びの無い形は、型付きの PARTITIONED BY と、
/// 未知のキーの TBLPROPERTIES の無い形（句が無い・受理されるキーだけ）を測っていないので None。未知のキーは 1 つだけの形を
/// 測った（理由には書いた綴りのまま出る）。`'table_type'='HIVE'` などの値の違いは測っていないので None。
pub(in crate::operation) fn s3_tables_failure(query: &str) -> Option<Failure> {
    let hive = read(query)?;
    let measured_name = match hive.parts.as_slice() {
        [_] | [_, _] => true,
        [catalog, _, _] => {
            catalog.eq_ignore_ascii_case("awsdatacatalog") && *catalog != "awsdatacatalog"
        }
        _ => false,
    };
    if !measured_name || hive.external || hive.location {
        return None;
    }
    if hive.clustered {
        return Some(Failure::iceberg_does_not_allow("CLUSTERED BY"));
    }
    if hive.row_format {
        return Some(Failure::iceberg_does_not_allow("ROW FORMAT"));
    }
    if hive.stored_as {
        return Some(Failure::iceberg_does_not_allow("STORED AS/BY"));
    }
    if hive.partitioned {
        return hive.columns.then(Failure::invalid_partitioned_by);
    }
    let table_type_iceberg = hive.properties.iter().all(|(key, value)| {
        !key.eq_ignore_ascii_case("table_type") || value.eq_ignore_ascii_case("iceberg")
    });
    let [unknown_key] = hive
        .properties
        .iter()
        .map(|(key, _)| *key)
        .filter(|key| {
            !ICEBERG_PROPERTY_KEYS
                .iter()
                .any(|known| key.eq_ignore_ascii_case(known))
        })
        .collect::<Vec<_>>()[..]
    else {
        return None;
    };
    if !table_type_iceberg {
        return None;
    }
    Some(if hive.columns {
        Failure::unsupported_table_property_key(unknown_key)
    } else {
        Failure::at_least_one_column()
    })
}

/// LOCATION 付きの Hive の `CREATE [EXTERNAL] TABLE <無引用の 3 部> ... LOCATION '..'` の 1 部目（書いたとおり）。
/// `awsdatacatalog` の類は None。本物は 1 部目のカタログが実在しなければ Context によらず開始時に DATACATALOG_NOT_FOUND で
/// 弾いた（2026-09-26 実測 n6・2026-09-27 実測 s12・s13）。EXTERNAL・IF NOT EXISTS・句（1 つ・全部）・列の並びの有無に
/// よらない（2026-09-27 実測 t0〜t10・t0s〜t9s。#266）。
pub(in crate::operation) fn location_catalog(query: &str) -> Option<&str> {
    let hive = read(query)?;
    match hive.parts.as_slice() {
        [catalog, _, _] if hive.location && !catalog.eq_ignore_ascii_case("awsdatacatalog") => {
            Some(catalog)
        }
        _ => None,
    }
}

/// `CREATE [EXTERNAL] TABLE [IF NOT EXISTS] <名前> [(列)] [COMMENT '..'] [PARTITIONED BY (列)]
/// [CLUSTERED BY (列名, ...) INTO <数> BUCKETS] [ROW FORMAT SERDE '..' | ROW FORMAT DELIMITED <区切りの句>...]
/// [STORED AS <語>] [LOCATION '..'] [TBLPROPERTIES ('k'='v', ...)]` を Hive の句の順に読む。引用符付きの名前・列名、
/// NOT NULL、入れ子の型（`row(a int)`。s17・s18）、句の順番の違い、後ろのごみは本物も Trino の構文エラーを返したので
/// None にして構文チェックに任せる。
fn read(query: &str) -> Option<Hive<'_>> {
    let sql = query.trim_start_matches([' ', '\t', '\r', '\n']);
    let mut cursor = Cursor::new(sql);
    if !cursor.keyword("CREATE") {
        return None;
    }
    let external = cursor.keyword("EXTERNAL");
    if !cursor.keyword("TABLE") {
        return None;
    }
    let if_not_exists = cursor.keyword("IF");
    if if_not_exists && !(cursor.keyword("NOT") && cursor.keyword("EXISTS")) {
        return None;
    }
    let backquoted = skip_leading_trivia(cursor.rest()).starts_with('`');
    let parts = if backquoted {
        let start = sql.len() - skip_leading_trivia(cursor.rest()).len();
        if !backquoted_name(&mut cursor) {
            return None;
        }
        vec![&sql[start..sql.len() - cursor.rest().len()]]
    } else {
        let name = cursor.qualified_name()?;
        if name.parts.iter().any(|part| part.text.starts_with('"')) {
            return None;
        }
        name.parts.iter().map(|part| part.text).collect()
    };
    let statement_start = sql.len() - skip_leading_trivia(sql).len();
    let columns = cursor.punct(b'(');
    if columns && !column_list(sql, statement_start, &mut cursor) {
        return None;
    }
    clause(&mut cursor, "COMMENT", string_literal)?;
    let partitioned = clause(&mut cursor, "PARTITIONED", |cursor| {
        cursor.keyword("BY") && cursor.punct(b'(') && column_list(sql, statement_start, cursor)
    })?;
    let clustered = clause(&mut cursor, "CLUSTERED", |cursor| {
        cursor.keyword("BY")
            && cursor.punct(b'(')
            && column_names(cursor)
            && cursor.keyword("INTO")
            && skip_leading_trivia(cursor.rest()).starts_with(|c: char| c.is_ascii_digit())
            && cursor.literal()
            && cursor.keyword("BUCKETS")
    })?;
    let row_format = clause(&mut cursor, "ROW", |cursor| {
        cursor.keyword("FORMAT") && row_format(cursor)
    })?;
    let stored_as = clause(&mut cursor, "STORED", |cursor| {
        cursor.keyword("AS") && cursor.identifier()
    })?;
    let location = clause(&mut cursor, "LOCATION", string_literal)?;
    let properties = if cursor.keyword("TBLPROPERTIES") {
        properties(&mut cursor)?
    } else {
        Vec::new()
    };
    cursor.at_end().then_some(Hive {
        external,
        parts,
        columns,
        partitioned,
        clustered,
        row_format,
        stored_as,
        location,
        properties,
    })
}

/// `keyword` で始まる句を 1 つ読む。無ければ Some(false)、`keyword` の後ろを `rest` で読めなければ None。
fn clause(
    cursor: &mut Cursor,
    keyword: &str,
    rest: impl FnOnce(&mut Cursor) -> bool,
) -> Option<bool> {
    if !cursor.keyword(keyword) {
        return Some(false);
    }
    rest(cursor).then_some(true)
}

/// 1 部のバッククォートの名前（中は無引用の識別子の文字だけ。s11）。
fn backquoted_name(cursor: &mut Cursor) -> bool {
    cursor.punct(b'`')
        && cursor
            .rest()
            .starts_with(|c: char| c.is_ascii_alphabetic() || c == '_')
        && cursor.identifier()
        && cursor.rest().starts_with('`')
        && cursor.punct(b'`')
}

/// `ROW FORMAT` の後ろ。`SERDE '..'`（s3）か、`DELIMITED` と区切りの句 1 つ以上（Hive の順。n20・s4・s5）。
fn row_format(cursor: &mut Cursor) -> bool {
    if cursor.keyword("SERDE") {
        return string_literal(cursor);
    }
    if !cursor.keyword("DELIMITED") {
        return false;
    }
    let mut any = false;
    for keywords in [
        &["FIELDS", "TERMINATED", "BY"][..],
        &["COLLECTION", "ITEMS", "TERMINATED", "BY"],
        &["MAP", "KEYS", "TERMINATED", "BY"],
        &["LINES", "TERMINATED", "BY"],
        &["NULL", "DEFINED", "AS"],
    ] {
        if cursor.keyword(keywords[0]) {
            if !(keywords[1..].iter().all(|keyword| cursor.keyword(keyword))
                && string_literal(cursor))
            {
                return false;
            }
            any = true;
        }
    }
    any
}

/// `(` の直後から無引用の列名の並びを `)` の直後まで読む（`CLUSTERED BY`。s2）。
fn column_names(cursor: &mut Cursor) -> bool {
    loop {
        if skip_leading_trivia(cursor.rest()).starts_with('"') || !cursor.identifier() {
            return false;
        }
        if !cursor.punct(b',') {
            return cursor.punct(b')');
        }
    }
}

/// `TBLPROPERTIES` の後ろの `('k'='v', ...)`（1 組 n20・2 組 s6）のキーと値。読めなければ None。
fn properties<'a>(cursor: &mut Cursor<'a>) -> Option<Vec<(&'a str, &'a str)>> {
    if !cursor.punct(b'(') {
        return None;
    }
    let mut properties = Vec::new();
    loop {
        let key = string_content(cursor)?;
        if !cursor.punct(b'=') {
            return None;
        }
        properties.push((key, string_content(cursor)?));
        if !cursor.punct(b',') {
            return cursor.punct(b')').then_some(properties);
        }
    }
}

/// `'...'` を 1 つ読み、引用符の中身（`''` はそのまま）を返す。
fn string_content<'a>(cursor: &mut Cursor<'a>) -> Option<&'a str> {
    let literal = skip_leading_trivia(cursor.rest());
    if !string_literal(cursor) {
        return None;
    }
    let literal = &literal[..literal.len() - cursor.rest().len()];
    Some(&literal[1..literal.len() - 1])
}

/// `(` の直後から列の並びを `)` の直後まで読む。文言が決まる形・実測していない形なら false。
fn column_list(sql: &str, statement_start: usize, cursor: &mut Cursor) -> bool {
    loop {
        match column(sql, statement_start, cursor) {
            ColumnOutcome::Next => {}
            ColumnOutcome::EndOfColumns => return true,
            ColumnOutcome::Rejected(_) | ColumnOutcome::Unmeasured => return false,
        }
    }
}

/// `'...'` を 1 つ読む（数・TRUE／FALSE は読まない）。
fn string_literal(cursor: &mut Cursor) -> bool {
    skip_leading_trivia(cursor.rest()).starts_with('\'') && cursor.literal()
}

#[cfg(test)]
mod tests;
