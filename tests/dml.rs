//! DML の更新件数、失敗の伝わり方、未対応リクエストの扱いを確認する。

mod common;

use common::{Harness, execution_id, trino_error};
use serde_json::json;

#[tokio::test]
async fn dml_は行を返さず_update_count_を返す() {
    // Trino は DML でも rows 列 + 件数を返す。それは行として扱わない。
    let harness = Harness::start(json!({
        "columns": [{ "name": "rows", "type": "bigint" }],
        "data": [[3]],
        "updateType": "INSERT",
        "updateCount": 3
    }))
    .await;

    let execution = harness
        .run_query(json!({ "QueryString": "INSERT INTO users VALUES (1)" }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(execution["QueryExecution"]["StatementType"], "DML");

    let (status, results) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": execution_id(&execution) }),
        )
        .await;

    assert_eq!(status, 200);
    assert_eq!(results["UpdateCount"], 3);
    assert!(results["ResultSet"]["Rows"].as_array().unwrap().is_empty());
    // 本物の Athena も DML では rows (bigint) の列情報を返す（Hive 形式と Iceberg で実測）。
    let columns = results["ResultSet"]["ResultSetMetadata"]["ColumnInfo"]
        .as_array()
        .unwrap();
    assert_eq!(columns.len(), 1);
    assert_eq!(columns[0]["Name"], "rows");
    assert_eq!(columns[0]["Type"], "bigint");
}

#[tokio::test]
async fn ddl_は_statement_type_が_ddl_になり_件数の無い_ddl_は_update_count_を省く() {
    // Trino は CTAS に件数を付け、ただの CREATE TABLE には付けない。
    let harness = Harness::builder(json!({
        "columns": [{ "name": "rows", "type": "bigint" }],
        "updateType": "CREATE TABLE",
        "updateCount": 0
    }))
    .route(
        "CREATE TABLE t (i int)",
        json!({ "columns": [], "updateType": "CREATE TABLE" }),
    )
    .start()
    .await;

    let ctas = harness
        .run_query(json!({ "QueryString": "CREATE TABLE t AS SELECT 1" }))
        .await;
    let create = harness
        .run_query(json!({ "QueryString": "CREATE TABLE t (i int)" }))
        .await;
    assert_eq!(ctas["QueryExecution"]["StatementType"], "DDL");
    assert_eq!(create["QueryExecution"]["StatementType"], "DDL");

    let results = |execution: &serde_json::Value| {
        harness.call(
            "GetQueryResults",
            json!({ "QueryExecutionId": execution_id(execution) }),
        )
    };

    // CTAS は Trino の件数をそのまま載せる（本物も件数を返す）。
    let (status, ctas_results) = results(&ctas).await;
    assert_eq!(status, 200);
    assert_eq!(ctas_results["UpdateCount"], 0);

    // 本物は件数の無い DDL の UpdateCount を null で返す。SDK から見て同じなので項目ごと省く。
    let (status, create_results) = results(&create).await;
    assert_eq!(status, 200);
    assert!(
        create_results.get("UpdateCount").is_none(),
        "{create_results}"
    );
    // 列も行も返さない（本物の Rows と ColumnInfo は空）。
    assert_eq!(
        create_results["ResultSet"],
        json!({ "Rows": [], "ResultSetMetadata": { "ColumnInfo": [] } })
    );
}

#[tokio::test]
async fn trino_のエラーは_failed_と理由になる() {
    let harness = Harness::start(json!({
        "error": {
            "message": "line 1:15: Table 'iceberg.x.no_such' does not exist",
            "errorName": "TABLE_NOT_FOUND"
        }
    }))
    .await;

    let execution = harness
        .run_query(json!({ "QueryString": "SELECT * FROM no_such" }))
        .await;
    let status = &execution["QueryExecution"]["Status"];

    assert_eq!(status["State"], "FAILED");
    let reason = status["StateChangeReason"].as_str().unwrap();
    assert!(reason.contains("TABLE_NOT_FOUND"), "理由: {reason}");

    // 失敗したクエリの結果取得はエラーになる。
    let (code, error) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": execution_id(&execution) }),
        )
        .await;

    assert_eq!(code, 400);
    assert_eq!(error["__type"], "InvalidRequestException");
    assert!(error["message"].as_str().unwrap().contains("FAILED"));
}

#[tokio::test]
async fn 偽_trino_は_sql_ごとに応答を変えられる() {
    // 後続のテストが「分類用の問い合わせ」と「本体」を別々に演じさせる前提の確認。
    let harness = Harness::builder(json!({ "columns": [], "data": [] }))
        .route(
            "SELECT * FROM no_such",
            trino_error("TABLE_NOT_FOUND", "Table 'no_such' does not exist"),
        )
        .start()
        .await;

    let failed = harness
        .run_query(json!({ "QueryString": "SELECT * FROM no_such" }))
        .await;
    let succeeded = harness
        .run_query(json!({ "QueryString": "SELECT 1" }))
        .await;

    assert_eq!(failed["QueryExecution"]["Status"]["State"], "FAILED");
    assert_eq!(succeeded["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(harness.trino_sqls(), ["SELECT * FROM no_such", "SELECT 1"]);
}

#[tokio::test]
async fn 知らない実行_id_はエラーになる() {
    let harness = Harness::start(json!({ "columns": [], "data": [] })).await;

    let (code, error) = harness
        .call(
            "GetQueryExecution",
            json!({ "QueryExecutionId": "unknown" }),
        )
        .await;

    assert_eq!(code, 400);
    assert_eq!(error["__type"], "InvalidRequestException");
}

#[tokio::test]
async fn 未対応のオペレーションはエラーになる() {
    let harness = Harness::start(json!({ "columns": [], "data": [] })).await;

    let (code, error) = harness.call("ListWorkGroups", json!({})).await;

    assert_eq!(code, 400);
    assert_eq!(error["__type"], "InvalidRequestException");
    assert!(
        error["message"]
            .as_str()
            .unwrap()
            .contains("ListWorkGroups")
    );
}
