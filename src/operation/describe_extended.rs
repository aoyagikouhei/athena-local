//! `DESCRIBE`／`DESC` の `EXTENDED`／`FORMATTED` と、列名・`PARTITION` 指定の認識、Trino に送る文の組み立て、
//! GetQueryExecution の `Query`／Context の Database の組み直し（2026-09-27 実測。#275）。
//!
//! フェーズ 3（#275）で `start_checks.rs`・`background_execution.rs` から呼ぶまで、ここの関数はどこからも
//! 呼ばない（純関数のみ）。
//!
//! 文の認識は字句処理を新しく書かず `athena_sql::Cursor` を再利用する。二重引用符とバッククォートの部品を
//! 含む名前は対象外（今までどおりの経路に任せ、`None` を返す）。
#![allow(dead_code)] // フェーズ 3（#275）で配線するまで

use super::reported_query;

/// `DESCRIBE`／`DESC` の直後に付く修飾子。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Modifier {
    Extended,
    Formatted,
}

/// 名前の後ろ（`DESCRIBE <名前>` の続き）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Suffix {
    /// 何も無い。
    None,
    /// 列名 1 つ（小文字にしたもの。Hive の列名は小文字）。
    Column(String),
    /// `PARTITION (<key>='<value>', ...)`。キーは小文字、値は `''` を `'` に戻したもの。
    Partition(Vec<(String, String)>),
}

/// 名前の部品 1 つ。`text` は元の綴りそのまま（バッククォート付きならバッククォートを含む）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Part<'a> {
    pub(super) text: &'a str,
    pub(super) start: usize,
}

/// `parse` が読んだ名前（`start`／`end`／各部品の `start` は `query` の中の絶対位置）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Name<'a> {
    pub(super) text: &'a str,
    pub(super) start: usize,
    pub(super) end: usize,
    pub(super) parts: Vec<Part<'a>>,
}

/// `parse` が認識した `DESCRIBE`／`DESC` の文。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Describe<'a> {
    pub(super) modifier: Option<Modifier>,
    pub(super) name: Name<'a>,
    pub(super) suffix: Suffix,
}

/// `DESCRIBE`／`DESC`（大文字小文字を無視）に続く任意の `EXTENDED`／`FORMATTED`、名前（1〜3 部。4 部以上と
/// 二重引用符の部品を含む名前は対象外）、その後ろの (a) 何も無い (b) 列名 1 つ (c) `PARTITION (...)` を読む。
/// 名前が無ければ None（名前無しの `DESCRIBE EXTENDED` は entity_check の Entity Not Found に任せる。
/// 本物の z1・z2）。修飾子も後ろ（列・PARTITION）も無ければ None（今の DESCRIBE の経路。この関数の対象外）。
pub(super) fn parse(query: &str) -> Option<Describe<'_>> {
    let mut cursor = athena_sql::Cursor::new(query);
    if !(cursor.keyword("DESCRIBE") || cursor.keyword("DESC")) {
        return None;
    }
    let modifier = if cursor.keyword("EXTENDED") {
        Some(Modifier::Extended)
    } else if cursor.keyword("FORMATTED") {
        Some(Modifier::Formatted)
    } else {
        None
    };
    let name = read_name(&mut cursor)?;
    let suffix = read_suffix(&mut cursor, query)?;
    if modifier.is_none() && suffix == Suffix::None {
        return None;
    }
    Some(Describe {
        modifier,
        name,
        suffix,
    })
}

/// Trino に送る文。名前の元の綴り（`describe.name.text`）をそのまま使い、修飾子・列・PARTITION は
/// 付けない（D3。別のクエリとして投げるので、受け取った文は書き換えない）。
pub(super) fn trino_statement(describe: &Describe) -> String {
    format!("DESCRIBE {}", describe.name.text)
}

/// GetQueryExecution の `Query`（`awsdatacatalog.` と DB を落とし、キーワード間のちょうど空白 2 つを
/// 1 つに畳んだ文）と、Context の Database にする修飾の DB（qe1〜qe9・qf1〜qf9 実測）。DB は、名前が 1 部
/// （無修飾）のときと、Context の Catalog が `AwsDataCatalog`（大文字小文字によらない）でも省略でもないとき
/// （既存の `drop_catalog`・`drop_database` と同じ条件）は落とさず None（呼び出し側が Context の Database を
/// そのまま使う）。空白の畳みは DB を落とすかによらず当てる。
pub(super) fn displayed(query: &str, context_catalog: Option<&str>) -> (String, Option<String>) {
    let dropped = context_catalog
        .is_none_or(reported_query::is_aws_data_catalog)
        .then(|| drop_via_first_part(query))
        .flatten();
    let (query, database) = match dropped {
        Some(rewritten) => (rewritten.query, Some(rewritten.database)),
        None => (query.to_string(), None),
    };
    (collapse_double_space_between_keywords(&query), database)
}

/// `DESCRIBE`／`DESC` に `EXTENDED`／`FORMATTED` を挟んでもよいキーワードの並びの候補。修飾子付きを先に
/// 置く（`parse_target_table` と同じ順序。#275）。名前無しの修飾子（`DESCRIBE EXTENDED` だけ）はどの候補でも
/// 名前が読めず `drop_first_part` が None を返すので、ここでは影響しない。
const KEYWORD_COMBOS: &[&[&str]] = &[
    &["DESCRIBE", "EXTENDED"],
    &["DESCRIBE", "FORMATTED"],
    &["DESC", "EXTENDED"],
    &["DESC", "FORMATTED"],
    &["DESCRIBE"],
    &["DESC"],
];

/// `reported_query::drop_first_part` を再利用して `awsdatacatalog.` と DB を落とす（バッククォートを
/// 含まない名前だけ。`drop_first_part` の中の `athena_sql::Cursor::qualified_name` がバッククォートを
/// 読めないため、3 部・2 部のどちらも一致しなければ None）。3 部で `awsdatacatalog` を落とした後、その結果に
/// 対してさらに 2 部の DB 落としを試す（`start_checks.rs` の `drop_catalog` → `drop_database` と同じ 2 段）。
fn drop_via_first_part(query: &str) -> Option<reported_query::Rewritten> {
    let after_catalog = KEYWORD_COMBOS.iter().find_map(|keywords| {
        reported_query::drop_first_part(query, keywords, 3, reported_query::is_aws_data_catalog)
    });
    let query_after_catalog = match after_catalog {
        Some((query, _, _)) => query,
        None => query.to_string(),
    };
    let (query, database, _) = KEYWORD_COMBOS.iter().find_map(|keywords| {
        reported_query::drop_first_part(&query_after_catalog, keywords, 2, |_| true)
    })?;
    Some(reported_query::Rewritten { query, database })
}

/// `DESCRIBE`／`DESC` と `EXTENDED`／`FORMATTED` の間がちょうど半角空白 2 つなら 1 つに畳む（D9。
/// qe6・qf6 実測）。空白 3 つ以上・タブ・改行はそのまま（未測定）。修飾子が無ければ何もしない。
fn collapse_double_space_between_keywords(query: &str) -> String {
    let mut cursor = athena_sql::Cursor::new(query);
    if !(cursor.keyword("DESCRIBE") || cursor.keyword("DESC")) {
        return query.to_string();
    }
    let after_first = query.len() - cursor.rest().len();
    if !(cursor.keyword("EXTENDED") || cursor.keyword("FORMATTED")) {
        return query.to_string();
    }
    let second_start = athena_sql::skip_trivia(query.as_bytes(), after_first);
    if &query[after_first..second_start] == "  " {
        format!("{} {}", &query[..after_first], &query[second_start..])
    } else {
        query.to_string()
    }
}

/// 名前を 1 つ読む（`athena_sql::Cursor::qualified_name`）。1〜3 部で、二重引用符の部品を含まないときだけ `Some`。
/// バッククォートの名前は `qualified_name` が読めず None になる（今の athena-local はバッククォートの名前を
/// 文の種類によらず構文チェックで弾く。docs/caveats.md の #204 の差。本物の qe10 は SUCCEEDED だが、この差は
/// #204 の残りとして扱う）。
fn read_name<'a>(cursor: &mut athena_sql::Cursor<'a>) -> Option<Name<'a>> {
    let qn = cursor.qualified_name()?;
    if qn.parts.len() > 3 || qn.parts.iter().any(|part| part.text.starts_with('"')) {
        return None;
    }
    Some(Name {
        text: qn.text,
        start: qn.start,
        end: qn.end,
        parts: qn
            .parts
            .iter()
            .map(|part| Part {
                text: part.text,
                start: part.start,
            })
            .collect(),
    })
}

/// 名前の後ろ（`DESCRIBE <名前>` の続き）を読む。(a) 何も無い (b) 列名 1 つ（無引用の識別子。小文字にする）
/// (c) `PARTITION (<key>='<value>', ...)`（キーは小文字、値は `''` を `'` に戻す）。それ以外は None。
fn read_suffix<'a>(cursor: &mut athena_sql::Cursor<'a>, query: &'a str) -> Option<Suffix> {
    if cursor.at_end() {
        return Some(Suffix::None);
    }
    if cursor.keyword("PARTITION") {
        if !cursor.punct(b'(') {
            return None;
        }
        let mut pairs = Vec::new();
        loop {
            let key = read_plain_identifier(cursor, query)?;
            if !cursor.punct(b'=') {
                return None;
            }
            let value = read_string_literal_value(cursor, query)?;
            pairs.push((key.to_lowercase(), value));
            if cursor.punct(b',') {
                continue;
            }
            break;
        }
        if !(cursor.punct(b')') && cursor.at_end()) {
            return None;
        }
        return Some(Suffix::Partition(pairs));
    }
    let key = read_plain_identifier(cursor, query)?;
    if !cursor.at_end() {
        return None;
    }
    Some(Suffix::Column(key.to_lowercase()))
}

/// 無引用の識別子を 1 つ読む（二重引用符なら None）。
fn read_plain_identifier<'a>(
    cursor: &mut athena_sql::Cursor<'a>,
    query: &'a str,
) -> Option<&'a str> {
    let start = query.len() - athena_sql::skip_leading_trivia(cursor.rest()).len();
    if query.as_bytes().get(start) == Some(&b'"') {
        return None;
    }
    if !cursor.identifier() {
        return None;
    }
    let end = query.len() - cursor.rest().len();
    Some(&query[start..end])
}

/// `'...'` の文字列リテラルを読み、中身（`''` を `'` に戻したもの）を返す。数・TRUE／FALSE は対象外
/// （呼び出し元が値を文字列だけに絞る。`p=1` は None になる。#275 の z4 相当・実測 p6〜p8）。
fn read_string_literal_value(cursor: &mut athena_sql::Cursor, query: &str) -> Option<String> {
    let start = query.len() - athena_sql::skip_leading_trivia(cursor.rest()).len();
    if query.as_bytes().get(start) != Some(&b'\'') {
        return None;
    }
    if !cursor.literal() {
        return None;
    }
    let end = query.len() - cursor.rest().len();
    let text = &query[start..end];
    Some(text[1..text.len() - 1].replace("''", "'"))
}

#[cfg(test)]
mod tests;
