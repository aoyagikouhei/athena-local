//! TRINO_CATALOG_MAP: Trino では付けられないカタログ名（S3 Tables の `s3tablescatalog/<bucket>`）を
//! 別名に差し替えて送る。GetQueryExecution には受け取った名前をそのまま返す。

mod common;

use common::Harness;
use serde_json::json;

const S3_TABLES_CATALOG: &str = "s3tablescatalog/example-bucket";

fn select_response() -> serde_json::Value {
    json!({
        "columns": [{ "name": "v", "type": "integer" }],
        "data": [[1]]
    })
}

#[tokio::test]
async fn 別名のカタログは差し替えて送り_実行情報には受け取った名前を返す() {
    let harness = Harness::builder(select_response())
        .catalog_map(&[(S3_TABLES_CATALOG, "iceberg")])
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "SELECT ? AS v FROM users",
            "ExecutionParameters": ["1"],
            "QueryExecutionContext": { "Catalog": S3_TABLES_CATALOG, "Database": "my_schema" }
        }))
        .await;

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");

    // 本体だけでなく、パラメータ分類の問い合わせも差し替えた名前で送る。
    let requests = harness.trino_requests();
    assert_eq!(requests.len(), 2, "分類 1 回 + 本体 1 回");
    for request in requests {
        assert_eq!(
            request.catalog.as_deref(),
            Some("iceberg"),
            "{}",
            request.sql
        );
        assert_eq!(
            request.schema.as_deref(),
            Some("my_schema"),
            "{}",
            request.sql
        );
    }

    assert_eq!(
        execution["QueryExecution"]["QueryExecutionContext"]["Catalog"],
        S3_TABLES_CATALOG
    );
}

#[tokio::test]
async fn 別名に無いカタログと既定のカタログはそのまま送る() {
    let harness = Harness::builder(select_response())
        .catalog_map(&[(S3_TABLES_CATALOG, "iceberg")])
        .start()
        .await;

    let hive = harness
        .run_query(json!({
            "QueryString": "SELECT 1",
            "QueryExecutionContext": { "Catalog": "hive" }
        }))
        .await;
    harness
        .run_query(json!({ "QueryString": "SELECT 2" }))
        .await;

    let catalogs: Vec<_> = harness
        .trino_requests()
        .into_iter()
        .map(|request| request.catalog)
        .collect();
    assert_eq!(
        catalogs,
        [
            Some("hive".to_string()),
            Some("default_catalog".to_string())
        ]
    );
    assert_eq!(
        hive["QueryExecution"]["QueryExecutionContext"]["Catalog"],
        "hive"
    );
}
