//! エンジンで失敗した CTAS の Trino のエラー位置を、本物が返した位置に写す。
//!
//! 本物の Athena は、エンジン（Trino）で失敗した CTAS のエラーの位置（`line N:M`）を、CTAS を Trino の
//! SqlFormatter で整形し直した文の位置で返した（2026-09-27 実測。#272）。athena-local は Trino に送る SQL を
//! 変えず、Trino が返したメッセージの先頭の `line N:M:` だけを、整形し直した文でのその字句の位置に書き換える。
//!
//! 整形の規則（本物が足すプロパティを 1 つ含む WITH 句が必ず付く、項目が複数なら改行する、括弧の問い合わせ・
//! WITH の CTE は 3 桁字下げる、二項演算は括弧で包む、など）は `docs/dev/measurements/statements.md` の #272 の節。
//! ここでは、測った形（CTAS の WITH のプロパティ・`SELECT <項目>[, ...] [FROM <表> [WHERE <字句> <比較演算子>
//! <字句>]]`、それを括弧で包んだもの、`WITH <名前> AS (...) SELECT * FROM <名前>`）だけを読み、それ以外は
//! すべて `None`（測っていない形は位置を変えない）。

use athena_sql::{Cursor, QualifiedName, skip_trivia};

use super::reported_query::is_aws_data_catalog;

/// 整形後の文でその字句が来る行・桁（1 始まり）と、`full` 内でのその字句の開始バイト位置。
struct Anchor {
    start: usize,
    line: usize,
    column: usize,
}

/// `) AS SELECT ` の直後の桁（トップレベルで項目が 1 つのときの開始桁）。
const TOP_MERGE_COL: usize = 13;
/// 括弧の問い合わせ・WITH の CTE の中身に足す字下げ幅。
const NESTED_INDENT: usize = 3;

/// Trino のエラー `message` の先頭が `line N:M:` で、`sent`（`full` の `offset` バイト目から始まる部分文字列）の
/// その位置が、`full` を測った形の CTAS として整形したときの★の字句（表の名前・項目・WHERE の左の字句・
/// 項目の二項演算子）のどれかの先頭と一致すれば、整形後の行・桁に書き換えた message を返す。読めない・
/// 一致しない・`full` が ASCII でない・`full` の長さが `received`（受け取ったままの文。別名置換の前）と違えば
/// `None`。対象の形（D2）は `received` の CTAS の名前で決める（別名置換で `awsdatacatalog` が引用符付きの
/// Trino 名に変わっていても、実測の対象は受け取った名前の形なので、置換後の `full` では判定しない）。
pub(super) fn remap(
    sent: &str,
    offset: usize,
    full: &str,
    received: &str,
    context_catalog: Option<&str>,
    message: &str,
) -> Option<String> {
    if !full.is_ascii() || full.len() != received.len() {
        return None;
    }
    if !target_shape(context_catalog, &create_table_name(received)?) {
        return None;
    }
    let (line, column, rest) = split_message(message)?;
    let absolute = offset + line_col_to_byte(sent, line, column)?;
    let anchors = parse_ctas(full)?;
    let anchor = anchors
        .into_iter()
        .find(|anchor| anchor.start == absolute)?;
    Some(format!("line {}:{}: {rest}", anchor.line, anchor.column))
}

/// `line N:M: <rest>` を読む。先頭がこの形でなければ None。
fn split_message(message: &str) -> Option<(usize, usize, &str)> {
    let rest = message.strip_prefix("line ")?;
    let (line, rest) = rest.split_once(':')?;
    let (column, rest) = rest.split_once(':')?;
    Some((
        line.parse().ok()?,
        column.parse().ok()?,
        rest.strip_prefix(' ').unwrap_or(rest),
    ))
}

/// 1 始まりの行・桁（ASCII なので桁 = バイト位置）を `sent` 内のバイト位置にする。
fn line_col_to_byte(sent: &str, line: usize, column: usize) -> Option<usize> {
    if line == 0 || column == 0 {
        return None;
    }
    let mut offset = 0;
    for (index, current) in sent.split('\n').enumerate() {
        if index + 1 == line {
            return (column - 1 <= current.len()).then(|| offset + column - 1);
        }
        offset += current.len() + 1;
    }
    None
}

/// `cursor` の今の位置（トリビア未読み飛ばし）の、`full` 内でのバイト位置。
fn pos_in(full: &str, cursor: &Cursor) -> usize {
    full.len() - cursor.rest().len()
}

/// `cursor` の次の字句が始まる、トリビアを読み飛ばした後の `full` 内でのバイト位置。
fn start_of_next(full: &str, cursor: &Cursor) -> usize {
    skip_trivia(full.as_bytes(), pos_in(full, cursor))
}

/// リテラルか修飾名を 1 つ読み、`full` 内での開始・終わりのバイト位置を返す。
fn parse_token(cursor: &mut Cursor, full: &str) -> Option<(usize, usize)> {
    let start = start_of_next(full, cursor);
    if cursor.literal() {
        return Some((start, pos_in(full, cursor)));
    }
    cursor.qualified_name().map(|name| (name.start, name.end))
}

/// `AS <別名>` があれば読む。`AS` はあるのに別名が読めなければ偽（測っていない形）。
fn skip_optional_alias(cursor: &mut Cursor) -> bool {
    !cursor.keyword("AS") || cursor.identifier()
}

/// 単一バイトの記号が `symbol` とちょうど一致すれば読む（`try_skip_symbol` の 1 文字版）。
fn skip_symbol(cursor: &mut Cursor, full: &str, symbol: &str) -> bool {
    let start = start_of_next(full, cursor);
    full.as_bytes().get(start..start + symbol.len()) == Some(symbol.as_bytes())
        && symbol.bytes().all(|byte| cursor.punct(byte))
}

/// 比較演算子（`<>`・`!=`・`<=`・`>=`・`=`・`<`・`>`）を 1 つ読む。
fn skip_comparison_operator(cursor: &mut Cursor, full: &str) -> bool {
    ["<>", "!=", "<=", ">="]
        .into_iter()
        .any(|symbol| skip_symbol(cursor, full, symbol))
        || cursor.punct(b'=')
        || cursor.punct(b'<')
        || cursor.punct(b'>')
}

/// 項目の中の二項演算子（`+`・`-`・`*`・`/`）があれば読み、`full` 内での演算子の開始位置を返す。
fn skip_binary_operator(cursor: &mut Cursor, full: &str) -> Option<usize> {
    let start = start_of_next(full, cursor);
    let byte = *full.as_bytes().get(start)?;
    (matches!(byte, b'+' | b'-' | b'*' | b'/') && cursor.punct(byte)).then_some(start)
}

/// 項目 1 つの、`full` 内での開始位置と、二項演算子があればその開始位置・左オペランドの文字数（ASCII なので
/// バイト数 = 文字数）。
struct Item {
    start: usize,
    operator: Option<(usize, usize)>,
}

/// `*`・修飾名・リテラル・`<字句> <二項演算子> <字句>`（どれも `AS <別名>` 付きも可）を 1 つ読む。
fn parse_item(cursor: &mut Cursor, full: &str) -> Option<Item> {
    let start = start_of_next(full, cursor);
    if cursor.punct(b'*') {
        return Some(Item {
            start,
            operator: None,
        });
    }
    let (left_start, left_end) = parse_token(cursor, full)?;
    let operator = skip_binary_operator(cursor, full).map(|op| (op, left_end - left_start));
    if operator.is_some() {
        parse_token(cursor, full)?;
    }
    skip_optional_alias(cursor).then_some(Item {
        start: left_start,
        operator,
    })
}

/// `SELECT` の後ろ（`SELECT` 自体は呼び出し側が読む）の項目の並びと、任意の `FROM <表> [WHERE ...]`。
struct Core {
    items: Vec<Item>,
    from: Option<usize>,
    where_left: Option<usize>,
}

fn parse_core(cursor: &mut Cursor, full: &str) -> Option<Core> {
    let mut items = vec![parse_item(cursor, full)?];
    while cursor.punct(b',') {
        items.push(parse_item(cursor, full)?);
    }
    let mut from = None;
    let mut where_left = None;
    if cursor.keyword("FROM") {
        from = Some(cursor.qualified_name()?.start);
        if cursor.keyword("WHERE") {
            let (left, _) = parse_token(cursor, full)?;
            if !skip_comparison_operator(cursor, full) {
                return None;
            }
            parse_token(cursor, full)?;
            where_left = Some(left);
        }
    }
    Some(Core {
        items,
        from,
        where_left,
    })
}

/// `core` の項目・表・WHERE の左の字句に、整形後の行・桁を当てて `anchors` に積む。`select_line` は `SELECT` が
/// 乗る行（項目が 1 つならその項目も同じ行）、`merge_col` はそのときの項目の開始桁、`indent` は項目が複数の
/// ときと表・WHERE の行の字下げ幅。
fn place_core(
    core: &Core,
    select_line: usize,
    merge_col: usize,
    indent: usize,
    anchors: &mut Vec<Anchor>,
) {
    let single = core.items.len() == 1;
    let item_col = indent + 3;
    let mut line = select_line;
    for (index, item) in core.items.iter().enumerate() {
        let (item_line, column) = if single {
            (select_line, merge_col)
        } else {
            (select_line + 1 + index, item_col)
        };
        // 二項演算子の項目は `(<左> <演算子> <右>)` と括弧で包まれるので、左の字句は 1 桁右。
        anchors.push(Anchor {
            start: item.start,
            line: item_line,
            column: column + usize::from(item.operator.is_some()),
        });
        if let Some((operator, left_len)) = item.operator {
            anchors.push(Anchor {
                start: operator,
                line: item_line,
                column: column + 1 + left_len + 1,
            });
        }
        line = item_line;
    }
    if let Some(table) = core.from {
        line += 2;
        anchors.push(Anchor {
            start: table,
            line,
            column: indent + 3,
        });
        if let Some(where_left) = core.where_left {
            line += 1;
            anchors.push(Anchor {
                start: where_left,
                line,
                column: indent + 8,
            });
        }
    }
}

/// `WITH (<k> = <v>, ...)` の利用者のプロパティの個数（無ければ 0）。読めない形は None。
fn count_properties(cursor: &mut Cursor) -> Option<usize> {
    if !cursor.keyword("WITH") {
        return Some(0);
    }
    if !cursor.punct(b'(') {
        return None;
    }
    let mut count = 0;
    loop {
        if !(cursor.identifier() && cursor.punct(b'=') && cursor.literal()) {
            return None;
        }
        count += 1;
        if !cursor.punct(b',') {
            break;
        }
    }
    cursor.punct(b')').then_some(count)
}

/// 末尾の `WITH [NO] DATA`（あれば読む。無くても真）。
fn skip_trailing_data_clause(cursor: &mut Cursor) -> bool {
    !cursor.keyword("WITH")
        || cursor.keyword("DATA")
        || (cursor.keyword("NO") && cursor.keyword("DATA"))
}

/// Context の Catalog と CTAS の名前の形が、本物が整形した対象か（D2）。
fn target_shape(context_catalog: Option<&str>, name: &QualifiedName) -> bool {
    let parts = name.parts.len();
    let first_is_awsdatacatalog = name.parts.first().is_some_and(|part| {
        !part.text.starts_with('"') && part.text.eq_ignore_ascii_case("awsdatacatalog")
    });
    match context_catalog {
        Some(catalog) if catalog.to_ascii_lowercase().starts_with("s3tablescatalog/") => {
            parts == 3 && first_is_awsdatacatalog
        }
        None => parts <= 2 || (parts == 3 && first_is_awsdatacatalog),
        Some(catalog) if is_aws_data_catalog(catalog) => {
            parts <= 2 || (parts == 3 && first_is_awsdatacatalog)
        }
        _ => false,
    }
}

/// `CREATE TABLE [IF NOT EXISTS] <名前>` の `<名前>`（`target_shape` に渡すためだけに読む）。
fn create_table_name(text: &str) -> Option<QualifiedName<'_>> {
    let mut cursor = Cursor::new(text);
    if !(cursor.keyword("CREATE") && cursor.keyword("TABLE")) {
        return None;
    }
    if cursor.keyword("IF") && !(cursor.keyword("NOT") && cursor.keyword("EXISTS")) {
        return None;
    }
    cursor.qualified_name()
}

/// `full` を測った形の CTAS として読み、★の字句の整形後の行・桁の表を返す。対象の形かどうかは呼び出し側
/// （`remap`）がすでに `received` の名前で確かめている。読めない形なら None。
fn parse_ctas(full: &str) -> Option<Vec<Anchor>> {
    let mut cursor = Cursor::new(full);
    if !(cursor.keyword("CREATE") && cursor.keyword("TABLE")) {
        return None;
    }
    if cursor.keyword("IF") && !(cursor.keyword("NOT") && cursor.keyword("EXISTS")) {
        return None;
    }
    cursor.qualified_name()?;
    let user_props = count_properties(&mut cursor)?;
    if !cursor.keyword("AS") {
        return None;
    }
    let closing_line = 4 + user_props;

    let mut anchors = Vec::new();
    if cursor.keyword("SELECT") {
        let core = parse_core(&mut cursor, full)?;
        place_core(&core, closing_line, TOP_MERGE_COL, 0, &mut anchors);
    } else if cursor.punct(b'(') {
        if !cursor.keyword("SELECT") {
            return None;
        }
        let core = parse_core(&mut cursor, full)?;
        if !cursor.punct(b')') {
            return None;
        }
        place_core(
            &core,
            closing_line + 1,
            NESTED_INDENT + 8,
            NESTED_INDENT,
            &mut anchors,
        );
    } else if cursor.keyword("WITH") {
        let cte_name = cursor.qualified_name()?;
        if !(cursor.keyword("AS") && cursor.punct(b'(') && cursor.keyword("SELECT")) {
            return None;
        }
        let inner = parse_core(&mut cursor, full)?;
        if !(cursor.punct(b')')
            && cursor.keyword("SELECT")
            && cursor.punct(b'*')
            && cursor.keyword("FROM"))
        {
            return None;
        }
        if cursor.qualified_name()?.values() != cte_name.values() {
            return None;
        }
        place_core(
            &inner,
            closing_line + 2,
            NESTED_INDENT + 8,
            NESTED_INDENT,
            &mut anchors,
        );
    } else {
        return None;
    }

    (skip_trailing_data_clause(&mut cursor) && cursor.at_end()).then_some(anchors)
}

#[cfg(test)]
mod tests;
