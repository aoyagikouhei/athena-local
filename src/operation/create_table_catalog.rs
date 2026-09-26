//! 無引用の 3 部の名前の場所の無い `CREATE TABLE` を、名前の 1 部目のカタログで分ける（#227）。
//! 本物は 1 部目のカタログが実在しなければ、Context によらず開始時に `DATACATALOG_NOT_FOUND`
//! （`Catalog '<書いたとおり>' does not exist`）で弾いた。NV はそれより先（2026-09-26 実測 i3・j5〜j7・j10・j14）。

use axum::response::Response;

use crate::config::Config;
use crate::response::invalid_request_with_code;
use crate::trino::Trino;

use super::context_catalog::catalog_missing;
use super::unquoted_ddl::three_part_name;

/// 開始時にどうするか。
pub(super) enum Outcome {
    /// 今までどおり（呼び出し側は No location で弾く）。
    Continue,
    /// 本物は開始時に弾く（1 部目のカタログが無い）。
    Reject(Box<Response>),
}

/// `unquoted_ddl::rejection` が No location を返した文についてだけ呼ぶ。1 部目が `awsdatacatalog`（本物に必ずある。
/// 大文字小文字によらない）なら問い合わせない。それ以外は `DESCRIBE`（`entity_check`）と同じく Trino にカタログが
/// あるかを問い合わせ、無いと確かめられたときだけ弾く。Trino にだけあるカタログ（本物は未実測）は実在として扱う。
pub(super) async fn check(trino: &Trino, config: &Config, query: &str) -> Outcome {
    let Some((catalog, _)) = three_part_name(query) else {
        return Outcome::Continue;
    };
    if catalog.eq_ignore_ascii_case("awsdatacatalog")
        || !catalog_missing(trino, &trino_catalog(config, catalog).to_lowercase()).await
    {
        return Outcome::Continue;
    }
    Outcome::Reject(Box::new(invalid_request_with_code(
        format!("Catalog '{catalog}' does not exist"),
        "DATACATALOG_NOT_FOUND",
    )))
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
