//! `DROP TABLE` / `ALTER TABLE ... ADD COLUMNS` / `SHOW CREATE TABLE` / `DESCRIBE` の対象テーブルの修飾名解析。
//!
//! Phase 2 では修飾名（`cat.ns.t` や引用符付きのカタログ名）も解析し、対象テーブルの存在も
//! あわせて確かめる。修飾名にカタログ・スキーマが無ければ実行時の既定を当て、それでも
//! カタログかスキーマが決まらなければ判定しない（今までどおりに倒す。issue #39 Phase 2）。

use super::table_format::TargetStatement;

/// `DROP TABLE` / `ALTER TABLE ... ADD COLUMNS` / `... REPLACE COLUMNS` / `SHOW CREATE TABLE` / `DESCRIBE` から
/// 取り出した対象。カタログ・スキーマは修飾名に無ければ既定を当てた後の値（呼び出し元の別名解決前）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct TargetTable {
    pub(super) catalog: String,
    pub(super) schema: String,
    pub(super) table: String,
}

/// `target_statement` の種類ごとに、名前の前に来るキーワードの並びの候補（`DROP TABLE` / `ALTER TABLE` /
/// `SHOW CREATE TABLE` / `DESCRIBE` / `SHOW COLUMNS FROM`・`IN`）。DESCRIBE だけ `TABLE` を挟まない（#160）。
/// 候補が複数あるのは SHOW COLUMNS（`FROM` でも `IN` でも同じ結果）と DESCRIBE（`DESC` も同じ結果）（#173）。
fn keywords(statement: TargetStatement) -> &'static [&'static [&'static str]] {
    match statement {
        TargetStatement::DropTable => &[&["DROP", "TABLE"]],
        TargetStatement::AlterTableAddColumns | TargetStatement::AlterTableReplaceColumns => {
            &[&["ALTER", "TABLE"]]
        }
        TargetStatement::ShowCreateTable => &[&["SHOW", "CREATE", "TABLE"]],
        TargetStatement::Describe => &[&["DESCRIBE"], &["DESC"]],
        TargetStatement::ShowColumns => &[&["SHOW", "COLUMNS", "FROM"], &["SHOW", "COLUMNS", "IN"]],
    }
}

/// `DROP TABLE [IF EXISTS] <名前>` / `ALTER TABLE [IF EXISTS] <名前> ADD COLUMNS ...` /
/// `SHOW CREATE TABLE <名前>` / `DESCRIBE <名前>` / `SHOW COLUMNS {FROM|IN} <名前>` を解析し、カタログ・スキーマに既定値を当てる。
/// 名前の後ろ（`DESCRIBE t PARTITION (...)` の PARTITION 以降など）は読まない。修飾名にあればその値（引用符付きなら中身、無引用なら
/// Trino の規則で小文字）を使い、無ければ `default_catalog` / `default_schema`（実行時の値。
/// 別名解決前）を使う。カタログかスキーマが決まらなければ None（今までどおりに倒す）。
///
/// 字句処理は新しく書かず、`athena_sql` の `skip_keyword`・`skip_leading_trivia`・`skip_quoted`・`unquote`
/// を再利用する。
pub(super) fn parse_target_table(
    query: &str,
    statement: TargetStatement,
    default_catalog: Option<&str>,
    default_schema: Option<&str>,
) -> Option<TargetTable> {
    let name = keywords(statement)
        .iter()
        .find_map(|keywords| table_name_start(query, keywords))?;
    let parts = parse_qualified_name(name)?;

    let (catalog, schema, table) = match <[String; 1]>::try_from(parts.clone()) {
        Ok([table]) => (None, None, table),
        Err(_) => match <[String; 2]>::try_from(parts.clone()) {
            Ok([schema, table]) => (None, Some(schema), table),
            Err(_) => match <[String; 3]>::try_from(parts) {
                Ok([catalog, schema, table]) => (Some(catalog), Some(schema), table),
                Err(_) => return None,
            },
        },
    };

    let catalog = catalog.or_else(|| default_catalog.map(str::to_string))?;
    let schema = schema.or_else(|| default_schema.map(str::to_string))?;
    Some(TargetTable {
        catalog,
        schema,
        table,
    })
}

/// `<キーワードの並び>` と、あれば `IF EXISTS` を読み飛ばし、名前が始まる位置を返す。
/// 先頭が `<キーワードの並び>` でなければ None。並びは `keywords` が返す候補の 1 つ。
///
/// `athena_sql::skip_keyword` が先頭のトリビアを自分で読み飛ばすので、キーワードの手前では
/// 読み飛ばさない。**最後の 1 回だけは残す**: `parse_qualified_name` はトリビアを読み飛ばさず、
/// 先頭が空白やコメントのままだと `read_name_part` が名前を 1 文字も読めずに None を返す。
fn table_name_start<'a>(query: &'a str, keywords: &[&str]) -> Option<&'a str> {
    let mut rest = query;
    for keyword in keywords {
        rest = athena_sql::skip_keyword(rest, keyword)?;
    }
    let rest = match athena_sql::skip_keyword(rest, "IF") {
        Some(after_if) => athena_sql::skip_keyword(after_if, "EXISTS")?,
        None => rest,
    };
    Some(athena_sql::skip_leading_trivia(rest))
}

/// `.` で区切られた名前の並びを読む。引用符付きの識別子は中身を、無引用は小文字にして集める。
fn parse_qualified_name(input: &str) -> Option<Vec<String>> {
    let mut parts = Vec::new();
    let mut rest = input;
    loop {
        let (part, after) = read_name_part(rest)?;
        parts.push(part);
        let after_trivia = athena_sql::skip_leading_trivia(after);
        match after_trivia.strip_prefix('.') {
            Some(next) => rest = athena_sql::skip_leading_trivia(next),
            None => break,
        }
    }
    Some(parts)
}

/// 名前を 1 つ読む。引用符付きなら `athena_sql::skip_quoted` で終わりを見つけて中身を返し、
/// 無引用なら英数字と `_` の並びを小文字にして返す。
fn read_name_part(input: &str) -> Option<(String, &str)> {
    if input.starts_with('"') {
        let end = athena_sql::skip_quoted(input.as_bytes(), 0);
        let quoted = &input[..end];
        Some((athena_sql::unquote(quoted), &input[end..]))
    } else {
        let end = input
            .as_bytes()
            .iter()
            .position(|b| !(b.is_ascii_alphanumeric() || *b == b'_'))
            .unwrap_or(input.len());
        if end == 0 {
            return None;
        }
        Some((input[..end].to_lowercase(), &input[end..]))
    }
}

#[cfg(test)]
mod tests;
