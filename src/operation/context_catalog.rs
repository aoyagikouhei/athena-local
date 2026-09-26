//! QueryExecutionContext の Catalog が Trino に実在しないときに、メタデータの文だけ既定のカタログへ差し替える（#214）。
//! 本物は実在しない Catalog でも DESCRIBE・SHOW 系・DROP TABLE、CTAS でない CREATE TABLE・ALTER TABLE・ビューと
//! データベースの DDL を既定の AwsDataCatalog で解決して成功させ、表を読む SELECT・EXPLAIN・CTAS・INSERT・
//! DELETE・UPDATE・MERGE は失敗させた（2026-09-25／26 実測。#212 Y3・#214・#217）。

use std::collections::HashMap;

use crate::config::Config;
use crate::trino::{Cancel, Trino};

use super::classification::substatement_type;
use super::table_format::catalog_exists_sql;

/// 本物が実在しない Catalog でも既定のカタログで成功させた文（2026-09-25 実測 #214、2026-09-26 実測 #217）。
/// SHOW TBLPROPERTIES・SHOW VIEWS・SHOW PARTITIONS・MSCK REPAIR TABLE・ALTER TABLE の ADD/DROP PARTITION・
/// SET TBLPROPERTIES・VACUUM も成功したが、Trino に無い構文で athena-local からは届かないので載せない。
/// OPTIMIZE も成功したが、分類が CTAS と同じ（本物は CTAS を失敗させた）ので載せない。SHOW FUNCTIONS は
/// Trino が実在しないカタログでも成功させるので要らない。INSERT（1300）と DELETE・UPDATE・MERGE（1301）は本物も失敗させた。
const RESOLVED_STATEMENTS: &[&str] = &[
    "DESCRIBE_TABLE",
    "SHOW_COLUMNS",
    "SHOW_TABLES",
    "SHOW_DATABASES",
    "SHOW_CREATE_TABLE",
    "DROP_TABLE",
    "CREATE_TABLE",
    "ALTER_TABLE_ADD_COLUMN",
    "CREATE_VIEW",
    "SHOW_CREATE_VIEW",
    "DROP_VIEW",
    "CREATE_DATABASE",
    "DROP_DATABASE",
];

/// Trino に送るカタログの元になる名前を返す。差し替えたときは Trino 側の名前（別名の値か、`TRINO_CATALOG` に
/// 別名を当てたもの）を返す。別名のキーを返すと、呼び出し側の「別名なら存在を問い合わせない」
/// （`entity_check`）に当たってしまう。差し替えないときは受け取った名前のまま。省略なら None
/// （既定は呼び出し側が今までどおり当てる）。開始時（`entity_check` の前）と実行時（`run`）の両方で呼ぶ。
pub(super) async fn resolve(
    trino: &Trino,
    config: &Config,
    query: &str,
    catalog: Option<&str>,
) -> Option<String> {
    let catalog = catalog?;
    let unchanged = Some(catalog.to_string());
    if !substatement_type(query).is_some_and(|kind| RESOLVED_STATEMENTS.contains(&kind))
        || config.catalog_map.contains_key(catalog)
    {
        return unchanged;
    }
    // Trino はカタログを小文字で持つ（#207 の存在の確認と同じ）。
    if !missing(trino, &catalog_exists_sql(&catalog.to_lowercase())).await {
        return unchanged;
    }
    fallback(&config.catalog_map, config.default_catalog.as_deref())
        .map(str::to_string)
        .or(unchanged)
}

/// 有無の問い合わせ（`table_format::catalog_exists_sql`・`schema_exists_sql`）で、無いと確かめられたときだけ真。
/// 問い合わせの失敗・応答の形が違う（偽 Trino が本体の応答を返すときも）・あるなら偽（呼び出し側は今までどおりに倒す）。
pub(super) async fn missing(trino: &Trino, sql: &str) -> bool {
    // system.* を修飾名で引くので、セッションのカタログ・スキーマは付けない。
    let Ok(outcome) = trino.execute(sql, None, None, &Cancel::default()).await else {
        return false;
    };
    let columns: Vec<&str> = outcome.columns.iter().map(|c| c.name.as_str()).collect();
    matches!(
        (columns.as_slice(), outcome.rows.as_slice()),
        (["_col0"], [row]) if row.len() == 1 && row[0].is_null()
    )
}

/// 差し替え先（Trino 側の名前）。`TRINO_CATALOG_MAP` の `AwsDataCatalog` の別名、無ければ `TRINO_CATALOG` に
/// 別名を当てたもの。キーは大文字小文字を区別せずに比べる（本物は Catalog の大文字小文字を区別しない。#157）。
fn fallback<'a>(
    catalog_map: &'a HashMap<String, String>,
    default_catalog: Option<&'a str>,
) -> Option<&'a str> {
    catalog_map
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case("AwsDataCatalog"))
        .map(|(_, trino)| trino.as_str())
        .or_else(|| default_catalog.map(|name| catalog_map.get(name).map_or(name, String::as_str)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(key, value)| (key.to_string(), value.to_string()))
            .collect()
    }

    #[test]
    fn 差し替え先は_awsdatacatalog_の別名_既定_無しの順() {
        let aliased = map(&[("s3tablescatalog/b", "s3t"), ("awsdatacatalog", "hive")]);
        assert_eq!(fallback(&aliased, Some("iceberg")), Some("hive"));
        assert_eq!(fallback(&map(&[]), Some("iceberg")), Some("iceberg"));
        assert_eq!(fallback(&map(&[]), None), None);
    }

    #[test]
    fn 既定が別名のキーなら_trino_側の名前にする() {
        let aliased = map(&[("Default", "memory")]);
        assert_eq!(fallback(&aliased, Some("Default")), Some("memory"));
    }
}
