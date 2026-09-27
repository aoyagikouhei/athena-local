//! 無引用の `awsdatacatalog` を 1 部目に書いた名前に `AwsDataCatalog` の別名を当てる形（`catalog::UnquotedForms`）を、
//! Context の Catalog と文の種類から決める。本物が Glue のカタログとして実行したと測った組だけに当てる。
//!
//! - 省略・`AwsDataCatalog`: SELECT は引用符付きの部品と 4 部の列の参照まで（2026-09-27 実測 o6〜o8・o10・o11。#260）、
//!   ほかの文は無引用の 3 部（2026-09-26 実測 m30〜m41。#246）
//! - S3 Tables: SELECT・INSERT の無引用の 3 部（2026-09-27 実測 o1・o2。#260）
//! - Trino に無く別名のキーでもないカタログ: SELECT・INSERT の無引用の 3 部（2026-09-25 実測 #214、2026-09-27 実測 o5。#260）。
//!   Trino はセッションのカタログが無くても完全修飾の名前を引くので、ヘッダは受け取った名前のまま
//! - ほかの文、別名のキー、Trino にあるカタログ（連携カタログとみなす）は測っていないので当てない

use std::borrow::Cow;
use std::collections::HashMap;

use crate::catalog::{UnquotedForms, alias_qualified_names};
use crate::config::Config;
use crate::trino::Trino;

use super::classification::substatement_type;
use super::context_catalog::missing;
use super::reported_query::is_aws_data_catalog;
use super::table_format::catalog_exists_sql;

/// `query` に当てる形。Context の Catalog が Trino に無いかは、当てる名前が `query` にあるときだけ問い合わせる
/// （実在しないカタログの Context のほかの SELECT に問い合わせを増やさない）。
pub(super) async fn forms(
    trino: &Trino,
    config: &Config,
    query: &str,
    catalog: Option<&str>,
) -> UnquotedForms {
    match by_context(substatement_type(query), catalog, &config.catalog_map) {
        Decision::Forms(forms) => forms,
        Decision::IfMissing(catalog) => {
            let forms = UnquotedForms::ThreeUnquotedParts;
            // Trino はカタログを小文字で持つ（`context_catalog::resolve` と同じ）。
            if matches!(
                alias_qualified_names(query, &config.catalog_map, forms),
                Cow::Owned(_)
            ) && missing(trino, &catalog_exists_sql(&catalog.to_lowercase())).await
            {
                forms
            } else {
                UnquotedForms::None
            }
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Decision<'a> {
    Forms(UnquotedForms),
    /// Context の Catalog が Trino に無ければ無引用の 3 部を当てる。
    IfMissing(&'a str),
}

fn by_context<'a>(
    kind: Option<&str>,
    catalog: Option<&'a str>,
    catalog_map: &HashMap<String, String>,
) -> Decision<'a> {
    let select = kind == Some("SELECT");
    let select_or_insert = select || kind == Some("INSERT");
    match catalog {
        None if select => Decision::Forms(UnquotedForms::WithQuotedPartsOrColumn),
        None => Decision::Forms(UnquotedForms::ThreeUnquotedParts),
        Some(catalog) if is_aws_data_catalog(catalog) => Decision::Forms(if select {
            UnquotedForms::WithQuotedPartsOrColumn
        } else {
            UnquotedForms::ThreeUnquotedParts
        }),
        Some(_) if !select_or_insert => Decision::Forms(UnquotedForms::None),
        // S3 Tables のカタログは別名のキーでもあるので、キーの判定より先に見る。
        Some(catalog) if catalog.to_ascii_lowercase().starts_with("s3tablescatalog/") => {
            Decision::Forms(UnquotedForms::ThreeUnquotedParts)
        }
        // 別名のキーの照合は `context_catalog::resolve` と同じく大文字小文字を区別する。
        Some(catalog) if catalog_map.contains_key(catalog) => Decision::Forms(UnquotedForms::None),
        Some(catalog) => Decision::IfMissing(catalog),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decide<'a>(query: &str, catalog: Option<&'a str>) -> Decision<'a> {
        let map = HashMap::from([
            ("AwsDataCatalog".to_string(), "hive".to_string()),
            ("s3tablescatalog/b".to_string(), "iceberg".to_string()),
            ("Federated".to_string(), "pg".to_string()),
        ]);
        by_context(substatement_type(query), catalog, &map)
    }

    const SELECT: &str = "SELECT * FROM awsdatacatalog.db.t";
    const INSERT: &str = "INSERT INTO awsdatacatalog.db.t VALUES (1)";
    const EXPLAIN: &str = "EXPLAIN SELECT * FROM awsdatacatalog.db.t";

    #[test]
    fn 省略と_aws_data_catalog_の_context_は_select_だけ引用符付きと_4_部まで当てる() {
        for catalog in [None, Some("AwsDataCatalog"), Some("awsdatacatalog")] {
            assert_eq!(
                decide(SELECT, catalog),
                Decision::Forms(UnquotedForms::WithQuotedPartsOrColumn)
            );
            assert_eq!(
                decide("WITH x AS (SELECT 1) SELECT * FROM x", catalog),
                Decision::Forms(UnquotedForms::WithQuotedPartsOrColumn)
            );
            for query in [INSERT, EXPLAIN, "CREATE VIEW v AS SELECT 1"] {
                assert_eq!(
                    decide(query, catalog),
                    Decision::Forms(UnquotedForms::ThreeUnquotedParts)
                );
            }
        }
    }

    #[test]
    fn s3_tables_の_context_は_select_と_insert_だけ無引用の_3_部を当てる() {
        for catalog in ["s3tablescatalog/b", "S3TablesCatalog/other"] {
            for query in [SELECT, INSERT] {
                assert_eq!(
                    decide(query, Some(catalog)),
                    Decision::Forms(UnquotedForms::ThreeUnquotedParts)
                );
            }
            assert_eq!(
                decide(EXPLAIN, Some(catalog)),
                Decision::Forms(UnquotedForms::None)
            );
        }
    }

    #[test]
    fn ほかのカタログの_context_は別名のキーなら当てず_そうでなければ_trino_の有無で決める() {
        for query in [SELECT, INSERT] {
            assert_eq!(
                decide(query, Some("Federated")),
                Decision::Forms(UnquotedForms::None)
            );
            assert_eq!(
                decide(query, Some("nosuchcatalog")),
                Decision::IfMissing("nosuchcatalog")
            );
        }
        for catalog in ["Federated", "nosuchcatalog"] {
            assert_eq!(
                decide(EXPLAIN, Some(catalog)),
                Decision::Forms(UnquotedForms::None)
            );
        }
    }
}
