//! 無引用の 3 部の名前の場所の無い `CREATE TABLE` を、名前の 1 部目のカタログで分ける（#227）。
//! 本物は 1 部目のカタログが実在しなければ、Context によらず開始時に `DATACATALOG_NOT_FOUND`
//! （`Catalog '<書いたとおり>' does not exist`）で弾いた。NV はそれより先（2026-09-26 実測 i3・j5〜j7・j10・j14）。
//! S3 Tables の Context で 1 部目が小文字ちょうどでない `awsdatacatalog`（`AwsDataCatalog` など）なら、1 部目を無視して
//! 2 部目を S3 Tables の名前空間として作り、名前空間が無ければ開始して FAILED にした（j1〜j4・j9）。
//! 名前空間があれば、1 部目を空白にした文を Trino に送る（j1・j4。#237）。
//! S3 Tables の Context の無引用の 2 部の名前も、1 部目の名前空間が無ければ同じ FAILED にした（i2・j12。#231）。
//! S3 Tables の Context の CTAS は逆に、1 部目が `awsdatacatalog` の類なら 2 部目を Glue の DB として引いた（i12・j13。#232）。

use std::ops::Range;

use axum::response::Response;

use crate::catalog::replacement;
use crate::config::Config;
use crate::failure::Failure;
use crate::response::invalid_request_with_code;
use crate::trino::{Cancel, Trino};

use super::classification::substatement_type;
use super::context_catalog::missing;
use super::table_format::{catalog_exists_sql, schema_probe_sql};
use super::target_table::if_follows;
use super::unquoted_ddl::{three_part_name, two_part_namespace};

/// 開始時にどうするか。
pub(super) enum Outcome {
    /// 今までどおり（呼び出し側は No location で弾く）。
    Continue,
    /// 本物は開始時に弾く（1 部目のカタログが無い）。
    Reject(Box<Response>),
    /// 開始は受け、Trino に送らずにこの失敗で終える（S3 Tables の名前空間が無い）。
    FailAtRuntime(Failure),
    /// 開始は受け、この文を Trino に送る（S3 Tables の名前空間がある。1 部目を空白にした文）。
    Rewrite(String),
}

/// `unquoted_ddl::rejection` が No location を返した文についてだけ呼ぶ。`context_catalog` は QueryExecutionContext の
/// Catalog（受け取ったまま）。1 部目が `awsdatacatalog`（本物に必ずある。大文字小文字によらない）ならカタログは
/// 問い合わせない。それ以外は `DESCRIBE`（`entity_check`）と同じく Trino にカタログがあるかを問い合わせ、無いと
/// 確かめられたときだけ弾く。Trino にだけあるカタログ（本物は未実測）は実在として扱い、名前空間も見ない。
pub(super) async fn check(
    trino: &Trino,
    config: &Config,
    query: &str,
    context_catalog: Option<&str>,
) -> Outcome {
    let Some((catalog, namespace, first_part)) = three_part_name(query) else {
        return Outcome::Continue;
    };
    if !catalog.eq_ignore_ascii_case("awsdatacatalog") {
        let sql = catalog_exists_sql(&trino_catalog(config, catalog).to_lowercase());
        return if missing(trino, &sql).await {
            Outcome::Reject(Box::new(invalid_request_with_code(
                format!("Catalog '{catalog}' does not exist"),
                "DATACATALOG_NOT_FOUND",
            )))
        } else {
            Outcome::Continue
        };
    }
    // S3 Tables の Context でだけ、本物は 2 部目を Context のカタログの名前空間として引いた（小文字ちょうどの
    // `awsdatacatalog` は 2 catalogs が先に決まるのでここへ来ない）。無いと確かめられたときだけ FAILED にし、
    // あれば（本物は作る）1 部目を空白にして Trino に送る。確かめられないときも 2 部の名前（#231）と同じく送る。
    let Some(s3_tables) = context_catalog
        .filter(|catalog| catalog.to_ascii_lowercase().starts_with("s3tablescatalog/"))
    else {
        return Outcome::Continue;
    };
    if namespace_missing(trino, config, s3_tables, namespace).await {
        Outcome::FailAtRuntime(Failure::cannot_find_table())
    } else {
        Outcome::Rewrite(blank_out(query, first_part))
    }
}

/// S3 Tables の Context（呼び出し側が確かめる）の CTAS で、無引用の 3 部の名前の 1 部目が `awsdatacatalog`（大文字小文字に
/// よらない）なら、本物は 2 部目を Glue の DB として引いた（2026-09-26 実測 i12 は小文字で作られ、j13 は `AwsDataCatalog`
/// で DB が無く FAILED）。DB は `TRINO_CATALOG_MAP` の `AwsDataCatalog` の Trino 名で確かめ、無いと確かめられて結果の
/// 置き場所（`location`）があれば本物と同じ理由の失敗、それ以外は 1 部目を Trino 名に差し替えた文を返す。Trino 名が
/// `awsdatacatalog` のままなら差し替えない。`IF NOT EXISTS` は未実測なので見ない。
pub(super) async fn ctas(
    trino: &Trino,
    config: &Config,
    query: &str,
    location: Option<&str>,
) -> Outcome {
    if substatement_type(query) != Some("CREATE_TABLE_AS_SELECT") || if_follows(query, "CREATE") {
        return Outcome::Continue;
    }
    let Some((catalog, database, first_part)) = three_part_name(query) else {
        return Outcome::Continue;
    };
    if !catalog.eq_ignore_ascii_case("awsdatacatalog") {
        return Outcome::Continue;
    }
    let trino_name = trino_catalog(config, "AwsDataCatalog");
    let sql = schema_probe_sql(&trino_name.to_lowercase(), &database.to_lowercase());
    if let Some(location) = location
        && schema_missing(trino, &sql).await
    {
        return Outcome::FailAtRuntime(Failure::database_not_found(database, location));
    }
    if trino_name.eq_ignore_ascii_case("awsdatacatalog") {
        return Outcome::Continue;
    }
    let end = first_part.start + catalog.len();
    Outcome::Rewrite(format!(
        "{}{}{}",
        &query[..first_part.start],
        replacement(catalog, trino_name),
        &query[end..]
    ))
}

/// `query` の `range` の各文字を空白にする（改行は残す）。文字数と行を保つので、Trino のエラー位置は受け取った
/// 文の位置のまま（`catalog.rs` の別名置換と同じく桁は文字数で揃える）。
fn blank_out(query: &str, range: Range<usize>) -> String {
    let blanks: String = query[range.clone()]
        .chars()
        .map(|c| if matches!(c, '\n' | '\r') { c } else { ' ' })
        .collect();
    format!("{}{blanks}{}", &query[..range.start], &query[range.end..])
}

/// S3 Tables の Context（`s3_tables` は受け取ったままの Catalog）で `unquoted_ddl::rejection` が弾かない、無引用の
/// 2 部の名前の場所の無い `CREATE TABLE`（本物は作る）。1 部目の名前空間が無いと確かめられたときだけ、Trino に
/// 送らずに終える失敗を返す。あれば（確かめられなければ）None で、今までどおり Trino に送る。
pub(super) async fn two_part_failure(
    trino: &Trino,
    config: &Config,
    query: &str,
    s3_tables: &str,
) -> Option<Failure> {
    let namespace = two_part_namespace(query)?;
    namespace_missing(trino, config, s3_tables, namespace)
        .await
        .then(Failure::cannot_find_table)
}

/// S3 Tables のカタログ（受け取ったまま）に名前空間が無いと確かめられたときだけ真。どちらも小文字にして引く
/// （Trino は小文字で持つ）。
async fn namespace_missing(
    trino: &Trino,
    config: &Config,
    s3_tables: &str,
    namespace: &str,
) -> bool {
    let sql = schema_probe_sql(
        &config.trino_catalog(s3_tables).to_lowercase(),
        &namespace.to_lowercase(),
    );
    schema_missing(trino, &sql).await
}

/// `schema_probe_sql` が `SCHEMA_NOT_FOUND` で失敗したときだけ真。成功（ある）とほかの失敗（確かめられない）は偽で、
/// 呼び出し側は今までどおりに倒す。修飾名で引くので、セッションのカタログ・スキーマは付けない。
async fn schema_missing(trino: &Trino, sql: &str) -> bool {
    matches!(
        trino.execute(sql, None, None, &Cancel::default()).await,
        Err(error) if error.name.as_deref() == Some("SCHEMA_NOT_FOUND")
    )
}

/// SQL に書いた無引用の 1 部目の Trino 側の名前。無引用の名前は大文字小文字を区別しないので、`TRINO_CATALOG_MAP`
/// のキーも大文字小文字によらず当てる（`config.trino_catalog` は区別する）。当たらなければ書いたとおり。
fn trino_catalog<'a>(config: &'a Config, catalog: &'a str) -> &'a str {
    config
        .catalog_map
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case(catalog))
        .map_or(catalog, |(_, trino)| trino.as_str())
}
