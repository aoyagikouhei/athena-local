//! SELECT の結果が Athena の形（先頭に列名行・値は文字列）で返ることを確認する。

mod common;

use common::{Harness, execution_id};
use serde_json::json;

/// Trino の 1 ページ応答。
fn select_response() -> serde_json::Value {
    json!({
        "columns": [
            { "name": "id", "type": "uuid" },
            { "name": "name", "type": "varchar" }
        ],
        "data": [
            ["11111111-2222-3333-4444-555555555555", "山田 太郎"],
            ["66666666-7777-8888-9999-000000000000", null]
        ]
    })
}

#[tokio::test]
async fn 先頭行に列名が入り値は文字列で返る() {
    let harness = Harness::start(select_response()).await;
    let execution = harness
        .run_query(json!({ "QueryString": "SELECT id, name FROM users" }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");

    let (status, results) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": execution_id(&execution) }),
        )
        .await;
    assert_eq!(status, 200);

    let rows = results["ResultSet"]["Rows"].as_array().unwrap();
    assert_eq!(rows.len(), 3, "列名行 + データ 2 行");
    assert_eq!(rows[0]["Data"][0]["VarCharValue"], "id");
    assert_eq!(rows[0]["Data"][1]["VarCharValue"], "name");
    assert_eq!(rows[1]["Data"][1]["VarCharValue"], "山田 太郎");

    // NULL は VarCharValue ごと省略される。
    assert!(rows[2]["Data"][1].get("VarCharValue").is_none());

    // 型は Trino の型名をそのまま載せる。
    let columns = results["ResultSet"]["ResultSetMetadata"]["ColumnInfo"]
        .as_array()
        .unwrap();
    assert_eq!(columns[0]["Name"], "id");
    assert_eq!(columns[0]["Type"], "uuid");

    // SELECT では UpdateCount を返さない。
    assert!(results.get("UpdateCount").is_none());
}

#[tokio::test]
async fn カタログとスキーマはヘッダで渡り_sql_は書き換えられない() {
    let harness = Harness::start(select_response()).await;
    harness
        .run_query(json!({
            "QueryString": "SELECT id, name FROM users",
            "QueryExecutionContext": { "Catalog": "iceberg", "Database": "duck_sample" }
        }))
        .await;

    let requests = harness.trino_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].sql, "SELECT id, name FROM users");
    assert_eq!(requests[0].catalog.as_deref(), Some("iceberg"));
    assert_eq!(requests[0].schema.as_deref(), Some("duck_sample"));
}

#[tokio::test]
async fn 文脈が無いときは設定の既定を使う() {
    let harness = Harness::start(select_response()).await;
    harness
        .run_query(json!({ "QueryString": "SELECT 1" }))
        .await;

    let requests = harness.trino_requests();
    assert_eq!(requests[0].catalog.as_deref(), Some("default_catalog"));
    assert_eq!(requests[0].schema.as_deref(), Some("default_schema"));
}

#[tokio::test]
async fn max_results_でページングされ_next_token_で続きが取れる() {
    let harness = Harness::start(select_response()).await;
    let execution = harness
        .run_query(json!({ "QueryString": "SELECT id, name FROM users" }))
        .await;
    let id = execution_id(&execution);

    let (_, first) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": id, "MaxResults": 2 }),
        )
        .await;
    assert_eq!(first["ResultSet"]["Rows"].as_array().unwrap().len(), 2);
    let token = first["NextToken"].as_str().expect("NextToken が無い");

    let (_, second) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": id, "MaxResults": 2, "NextToken": token }),
        )
        .await;
    assert_eq!(second["ResultSet"]["Rows"].as_array().unwrap().len(), 1);
    assert!(second.get("NextToken").is_none(), "最終ページには付かない");
}

#[tokio::test]
async fn trino_が複数ページで返しても全行そろう() {
    let first = json!({
        "columns": [{ "name": "n", "type": "bigint" }],
        "data": [[1], [2]]
    });
    let next = json!({ "data": [[3]] });
    let harness = Harness::start_with_pages(first, next).await;

    let execution = harness
        .run_query(json!({ "QueryString": "SELECT n FROM t" }))
        .await;
    let (_, results) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": execution_id(&execution) }),
        )
        .await;

    let rows = results["ResultSet"]["Rows"].as_array().unwrap();
    assert_eq!(rows.len(), 4, "列名行 + データ 3 行");
    assert_eq!(rows[3]["Data"][0]["VarCharValue"], "3");
}
