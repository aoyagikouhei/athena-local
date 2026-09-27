//! TRINO_CATALOG_MAP の別名を、SQL の修飾名に書かれたカタログ名にも当てる。
//!
//! S3 Tables のカタログ名 `s3tablescatalog/<bucket>` は `/` を含むので、Trino にはその名前の
//! カタログを作れない（Trino 482 で確認）。ヘッダだけでなく `"s3tablescatalog/<bucket>".db.t` の
//! ような修飾名も通すために、SQL のうち次の条件をすべて満たす部分だけを置き換える。
//!
//! - 二重引用符付きの識別子である。引用符の無い名前は、Trino 側のカタログを同じ名前にすれば通るので対象にしない
//! - 中身が別名マップのキーと完全に一致する（大文字小文字も区別する）
//! - 空白やコメントを挟んでもよいので、後ろに `.` が続く
//!
//! 本物は Context の Catalog が `AwsDataCatalog` か省略のとき、無引用の `awsdatacatalog.<db>.<t>`（大文字小文字に
//! よらない）を SELECT・INSERT・CTAS・CREATE VIEW・EXPLAIN で Glue のカタログとして実行した（2026-09-26 実測 m30〜m41。
//! #246）。この形（無引用の 3 部の名前の 1 部目）に限り、別名マップの `AwsDataCatalog` のキー（大文字小文字によらない）も
//! 当てる。引用符付きの部品を含む名前と 4 部の列の参照（2026-09-27 実測 o6〜o8。#260）まで当てるかは、呼び出し側が
//! Context と文の種類から [`UnquotedForms`] で決める。ほかの別名キーは測っていないので当てない。
//!
//! 文字列リテラルとコメントの中は読み飛ばす。置き換えた名前が短ければ閉じ引用符の後ろを空白で埋め、
//! Trino のエラーに出る桁位置を受け取った SQL と揃える（`"tpch"   .tiny.nation` が通ることを Trino 482 で確認）。
//!
//! 字句の読み飛ばし（`skip_quoted`・`comment_end`・`skip_trivia`）と `unquote` は `athena_sql` のものを使う。

use std::borrow::Cow;
use std::collections::HashMap;

use athena_sql::{Cursor, comment_end, skip_quoted, skip_trivia, unquote};

/// 無引用の `awsdatacatalog`（大文字小文字によらない）を 1 部目に書いた名前のうち、`AwsDataCatalog` の別名を当てる形。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnquotedForms {
    /// 当てない。
    None,
    /// 無引用のちょうど 3 部の名前（#246）。
    ThreeUnquotedParts,
    /// 3 部か 4 部（列の参照）の名前で、2 部目以降に引用符付きの部品を含んでもよい（#260 の o6〜o8）。
    WithQuotedPartsOrColumn,
}

/// 修飾名のカタログに別名を当てた SQL。置き換える箇所が無ければ受け取った SQL をそのまま返す。
/// `unquoted` は無引用の `awsdatacatalog` にも `AwsDataCatalog` の別名を当てる形。
pub fn alias_qualified_names<'a>(
    sql: &'a str,
    aliases: &HashMap<String, String>,
    unquoted: UnquotedForms,
) -> Cow<'a, str> {
    // 区切りに使う文字はどれも ASCII なので、バイト単位で走査しても UTF-8 の途中で切ることはない。
    let bytes = sql.as_bytes();
    let unquoted_alias = aliases
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case("awsdatacatalog"))
        .map(|(_, trino)| trino)
        .filter(|_| unquoted != UnquotedForms::None);
    let mut rewritten: Option<String> = None;
    let mut copied = 0;
    let mut i = 0;
    // 空白とコメントを除いた直前の文字が `.` か（無引用の名前が修飾名の 1 部目かどうか）。
    let mut after_dot = false;

    while i < bytes.len() {
        let start = i;
        i = match bytes[i] {
            b'\'' => skip_quoted(bytes, i),
            b'"' => {
                let end = skip_quoted(bytes, i);
                let identifier = &sql[i..end];
                if let Some(trino) = aliases.get(&unquote(identifier))
                    && next_is_dot(bytes, end)
                {
                    let out = rewritten.get_or_insert_with(|| String::with_capacity(sql.len()));
                    out.push_str(&sql[copied..i]);
                    out.push_str(&replacement(identifier, trino));
                    copied = end;
                }
                end
            }
            _ => match comment_end(bytes, i) {
                Some(end) => end,
                None => match word_end(sql, i) {
                    Some(end) => {
                        if let Some(trino) = unquoted_alias
                            && !after_dot
                            && is_unquoted_aws_data_catalog(sql, i, end, unquoted)
                        {
                            let out =
                                rewritten.get_or_insert_with(|| String::with_capacity(sql.len()));
                            out.push_str(&sql[copied..i]);
                            out.push_str(&replacement(&sql[i..end], trino));
                            copied = end;
                        }
                        end
                    }
                    None => i + 1,
                },
            },
        };
        if skip_trivia(bytes, start) == start {
            after_dot = bytes[start] == b'.';
        }
    }

    match rewritten {
        Some(mut out) => {
            out.push_str(&sql[copied..]);
            Cow::Owned(out)
        }
        None => Cow::Borrowed(sql),
    }
}

/// `i` から始まる無引用の識別子の終わり。`i` が空白や識別子の始まりでない文字なら None。
/// 走査は非 ASCII の文字の途中にも来るので、文字の境目でなければ切り出さない。
fn word_end(sql: &str, i: usize) -> Option<usize> {
    if !sql.is_char_boundary(i) || skip_trivia(sql.as_bytes(), i) != i {
        return None;
    }
    let mut cursor = Cursor::new(&sql[i..]);
    cursor.identifier().then(|| sql.len() - cursor.rest().len())
}

/// `sql[i..end]` が `awsdatacatalog`（大文字小文字によらない）で、そこから `forms` の形の名前が続くか。
fn is_unquoted_aws_data_catalog(sql: &str, i: usize, end: usize, forms: UnquotedForms) -> bool {
    sql[i..end].eq_ignore_ascii_case("awsdatacatalog")
        && Cursor::new(&sql[i..])
            .qualified_name()
            .is_some_and(|name| match forms {
                UnquotedForms::None => false,
                UnquotedForms::ThreeUnquotedParts => {
                    name.parts.len() == 3
                        && name.parts.iter().all(|part| !part.text.starts_with('"'))
                }
                // 測った並びだけ: 無引用の 3 部、2 部目か 3 部目の 1 つだけ引用符付き（o6・o7）、無引用の 4 部（o8）。
                UnquotedForms::WithQuotedPartsOrColumn => {
                    let quoted: Vec<bool> = name
                        .parts
                        .iter()
                        .map(|part| part.text.starts_with('"'))
                        .collect();
                    matches!(
                        quoted.as_slice(),
                        [false, false, false]
                            | [false, true, false]
                            | [false, false, true]
                            | [false, false, false, false]
                    )
                }
            })
}

/// 空白とコメントを読み飛ばした次の文字が `.` か。
fn next_is_dot(bytes: &[u8], i: usize) -> bool {
    matches!(bytes.get(skip_trivia(bytes, i)), Some(&b'.'))
}

/// Trino の名前を引用符で包み、元の識別子より短ければ空白で埋めて同じ文字数にする。
/// Trino の桁位置は文字単位で数えるので、バイト数ではなく文字数で揃える。
pub(crate) fn replacement(identifier: &str, trino: &str) -> String {
    let mut quoted = format!("\"{}\"", trino.replace('"', "\"\""));
    let padding = identifier
        .chars()
        .count()
        .saturating_sub(quoted.chars().count());
    quoted.push_str(&" ".repeat(padding));
    quoted
}

#[cfg(test)]
mod tests;
