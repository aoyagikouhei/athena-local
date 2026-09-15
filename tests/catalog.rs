//! TRINO_CATALOG_MAP: Trino では付けられないカタログ名（S3 Tables の `s3tablescatalog/<bucket>`）を
//! 別名に差し替えて送る。GetQueryExecution には受け取った名前をそのまま返す。

mod common;

use common::{Harness, trino_error};
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

/// `"s3tablescatalog/example-bucket"` を `"iceberg"` に置き換え、同じ文字数になるよう空白で埋めたもの。
fn aliased_catalog() -> String {
    let original = format!("\"{S3_TABLES_CATALOG}\"");
    format!(
        "\"iceberg\"{}",
        " ".repeat(original.len() - "\"iceberg\"".len())
    )
}

#[tokio::test]
async fn 修飾名のカタログは別名にして送り_構文チェックと実行情報は受け取った_sql_のまま() {
    let harness = Harness::builder(select_response())
        .catalog_map(&[(S3_TABLES_CATALOG, "iceberg")])
        .start()
        .await;
    let query = format!(r#"SELECT v FROM "{S3_TABLES_CATALOG}".my_schema.users"#);

    let execution = harness.run_query(json!({ "QueryString": query })).await;

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        harness.trino_sqls(),
        [format!(
            "SELECT v FROM {}.my_schema.users",
            aliased_catalog()
        )]
    );
    assert_eq!(harness.syntax_checks(), [query.as_str()]);
    assert_eq!(execution["QueryExecution"]["Query"], query);
}

#[tokio::test]
async fn パラメータ付きでも別名を当ててから包み_投げ直す_sql_にも当てる() {
    let aliased = format!("SELECT v FROM {}.my_schema.users", aliased_catalog());
    let wrapped = format!("EXECUTE IMMEDIATE '{aliased}' USING 1");
    let harness = Harness::builder(select_response())
        .catalog_map(&[(S3_TABLES_CATALOG, "iceberg")])
        .route(
            &wrapped,
            trino_error(
                "INVALID_PARAMETER_USAGE",
                "line 1:20: Incorrect number of parameters: expected 0 but found 1",
            ),
        )
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": format!(r#"SELECT v FROM "{S3_TABLES_CATALOG}".my_schema.users"#),
            "ExecutionParameters": ["1"]
        }))
        .await;

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        harness.trino_sqls(),
        ["SELECT (1)".to_string(), wrapped, aliased],
        "分類 1 回 + 包んだ本体 + 値を捨てて投げ直した本体"
    );
}
