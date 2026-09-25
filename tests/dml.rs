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
    // Trino は CTAS に件数を付け、列も行も無い DDL には付けない（列も行も無い DDL の代表は
    // `CREATE SCHEMA`。#208 のフェーズ 2 から、無引用の場所の無い `CREATE TABLE` は開始時に
    // 弾かれ Trino に届かなくなるため）。
    let harness = Harness::builder(json!({
        "columns": [{ "name": "rows", "type": "bigint" }],
        "updateType": "CREATE TABLE",
        "updateCount": 0
    }))
    .route("CREATE SCHEMA s", json!({ "columns": [] }))
    .start()
    .await;

    let ctas = harness
        .run_query(json!({ "QueryString": "CREATE TABLE t AS SELECT 1" }))
        .await;
    let create = harness
        .run_query(json!({ "QueryString": "CREATE SCHEMA s" }))
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
    assert!(error["Message"].as_str().unwrap().contains("FAILED"));
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

    let (code, error) = harness.call("CreateWorkGroup", json!({})).await;

    // 本物は __type だけを返す（Message も AthenaErrorCode も無い。2026-09-23 実測。#84）。
    assert_eq!(code, 400);
    assert_eq!(error, json!({ "__type": "UnknownOperationException" }));
}

#[tokio::test]
async fn エラー本文は_type_と_athena_error_code_と_error_code_と_message_の_4_つを持つ() {
    // 2026-09-17 実測: AthenaErrorCode の付くエラーは本物の Athena で常にこの 4 キーだった。
    let harness = Harness::start(json!({ "columns": [], "data": [] })).await;

    let (code, error) = harness
        .call(
            "StopQueryExecution",
            json!({ "QueryExecutionId": "no-such-id" }),
        )
        .await;

    assert_eq!(code, 400);
    let mut keys: Vec<&str> = error
        .as_object()
        .unwrap()
        .keys()
        .map(String::as_str)
        .collect();
    keys.sort();
    assert_eq!(keys, ["AthenaErrorCode", "ErrorCode", "Message", "__type"]);
    assert_eq!(error["ErrorCode"], error["AthenaErrorCode"]);
    assert_eq!(error["AthenaErrorCode"], "QUERY_EXECUTION_NOT_FOUND");
}

#[tokio::test]
async fn 失敗したクエリには_athena_error_が付き_成功したクエリには付かない() {
    // 番号は本番 Athena で実測したもの（TABLE_NOT_FOUND は 1301）。
    let harness =
        Harness::builder(json!({ "columns": [{ "name": "n", "type": "bigint" }], "data": [[1]] }))
            .route(
                "SELECT * FROM no_such",
                trino_error(
                    "TABLE_NOT_FOUND",
                    "line 1:15: Table 'iceberg.x.no_such' does not exist",
                ),
            )
            .start()
            .await;

    let failed = harness
        .run_query(json!({ "QueryString": "SELECT * FROM no_such" }))
        .await;
    let status = &failed["QueryExecution"]["Status"];
    assert_eq!(status["State"], "FAILED");
    assert_eq!(
        status["AthenaError"],
        json!({
            "ErrorCategory": 2,
            "ErrorType": 1301,
            "Retryable": false,
            "ErrorMessage": "TABLE_NOT_FOUND: line 1:15: Table 'iceberg.x.no_such' does not exist"
        })
    );
    assert_eq!(
        status["AthenaError"]["ErrorMessage"],
        status["StateChangeReason"]
    );

    let succeeded = harness
        .run_query(json!({ "QueryString": "SELECT n FROM t" }))
        .await;
    assert!(
        succeeded["QueryExecution"]["Status"]
            .get("AthenaError")
            .is_none()
    );
}

#[tokio::test]
async fn 先頭のコメントを読み飛ばして_statement_type_と_update_count_を決める() {
    // 2026-09-18 実測。先頭のコメントは判定の前に読み飛ばす。
    let harness = Harness::builder(json!({
        "columns": [{ "name": "id", "type": "integer" }],
        "data": [[1]]
    }))
    // 列も行も無い DDL の代表として `CREATE SCHEMA`（#208 のフェーズ 2 から、無引用の場所の無い
    // `CREATE TABLE` は開始時に弾かれ Trino に届かなくなるため）。
    .route("-- c\nCREATE SCHEMA s", json!({ "columns": [] }))
    .start()
    .await;

    let select = harness
        .run_query(json!({ "QueryString": "-- c\nSELECT 1" }))
        .await;
    assert_eq!(select["QueryExecution"]["StatementType"], "DML");

    let create = harness
        .run_query(json!({ "QueryString": "-- c\nCREATE SCHEMA s" }))
        .await;
    assert_eq!(create["QueryExecution"]["StatementType"], "DDL");

    let (status, create_results) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": execution_id(&create) }),
        )
        .await;
    assert_eq!(status, 200);
    // 件数の無い DDL は本物では UpdateCount が null になり SDK からは省いたのと同じに見える。
    assert!(
        create_results.get("UpdateCount").is_none(),
        "{create_results}"
    );
}
