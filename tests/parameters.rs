//! ExecutionParameters: 値を式か文字列かに分類し、EXECUTE IMMEDIATE で Trino に渡す。
//! 分類の規則と Trino のエラー名は 2026-09-14 に本番 Athena と Trino 482 で実測したもの。

mod common;

use common::{Harness, execution_id, trino_error, trino_single_value};
use serde_json::json;

fn select_response() -> serde_json::Value {
    json!({
        "columns": [{ "name": "v", "type": "varchar" }],
        "data": [["ok"]]
    })
}

#[tokio::test]
async fn 値は式か文字列かに分類されて_execute_immediate_で包まれる() {
    let harness = Harness::builder(select_response())
        .route(
            "SELECT (abc)",
            trino_error(
                "COLUMN_NOT_FOUND",
                "line 1:9: Column 'abc' cannot be resolved",
            ),
        )
        .route(
            "SELECT (abc def)",
            trino_error("SYNTAX_ERROR", "line 1:13: mismatched input 'def'"),
        )
        .route("SELECT (1 + 1)", trino_single_value("integer", json!(2)))
        .route(
            "SELECT ('it''s')",
            trino_single_value("varchar(4)", json!("it's")),
        )
        .start()
        .await;

    let query = "SELECT * FROM t WHERE a = ? AND b = ? AND c = ? AND d = ?";
    let execution = harness
        .run_query(json!({
            "QueryString": query,
            "ExecutionParameters": ["abc", "abc def", "1 + 1", "'it''s'"],
            "QueryExecutionContext": { "Catalog": "iceberg", "Database": "my_schema" }
        }))
        .await;

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        harness.trino_sqls(),
        [
            "SELECT (abc)",
            "SELECT (abc def)",
            "SELECT (1 + 1)",
            "SELECT ('it''s')",
            "EXECUTE IMMEDIATE 'SELECT * FROM t WHERE a = ? AND b = ? AND c = ? AND d = ?' \
             USING 'abc', 'abc def', 1 + 1, 'it''s'",
        ]
    );

    // 分類の問い合わせも本体と同じカタログ・スキーマで投げる（関数の解決先を揃える）。
    for request in harness.trino_requests() {
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

    // GetQueryExecution は元の SQL を返し、ExecutionParameters は返さない（本物と同じ）。
    let query_execution = &execution["QueryExecution"];
    assert_eq!(query_execution["Query"], query);
    assert_eq!(query_execution["StatementType"], "DML");
    assert!(query_execution.get("ExecutionParameters").is_none());

    let (_, results) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": execution_id(&execution) }),
        )
        .await;
    assert_eq!(
        results["ResultSet"]["Rows"][1]["Data"][0]["VarCharValue"],
        "ok"
    );
}

#[tokio::test]
async fn パラメータ付きの_dml_は元の_sql_で種別が決まり更新件数が返る() {
    // EXECUTE IMMEDIATE 配下の INSERT も Trino は素の INSERT と同じ応答を返す（482 で確認）。
    let harness = Harness::builder(json!({
        "columns": [{ "name": "rows", "type": "bigint" }],
        "data": [[1]],
        "updateType": "INSERT",
        "updateCount": 1
    }))
    .route("SELECT (5)", trino_single_value("integer", json!(5)))
    .start()
    .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "INSERT INTO t VALUES (?)",
            "ExecutionParameters": ["5"]
        }))
        .await;

    assert_eq!(execution["QueryExecution"]["StatementType"], "DML");
    assert_eq!(
        harness.trino_sqls().last().unwrap(),
        "EXECUTE IMMEDIATE 'INSERT INTO t VALUES (?)' USING 5"
    );

    let (_, results) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": execution_id(&execution) }),
        )
        .await;
    assert_eq!(results["UpdateCount"], 1);
    assert!(results["ResultSet"]["Rows"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn 括弧を抜けて列が増える値は文字列になる() {
    let harness = Harness::builder(select_response())
        .route(
            "SELECT (1) , (2)",
            json!({
                "columns": [
                    { "name": "_col0", "type": "integer" },
                    { "name": "_col1", "type": "integer" }
                ],
                "data": [[1, 2]]
            }),
        )
        .start()
        .await;

    harness
        .run_query(json!({
            "QueryString": "SELECT ? AS v",
            "ExecutionParameters": ["1) , (2"]
        }))
        .await;

    assert_eq!(
        harness.trino_sqls().last().unwrap(),
        "EXECUTE IMMEDIATE 'SELECT ? AS v' USING '1) , (2'"
    );
}

#[tokio::test]
async fn 意味エラーの値は文字列にならず本体の失敗になる() {
    let error = trino_error(
        "FUNCTION_NOT_FOUND",
        "line 1:9: Function 'nosuchfunc' not registered",
    );
    let harness = Harness::builder(select_response())
        .route("SELECT (nosuchfunc(1))", error.clone())
        .route(
            "EXECUTE IMMEDIATE 'SELECT ? AS v' USING nosuchfunc(1)",
            error,
        )
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "SELECT ? AS v",
            "ExecutionParameters": ["nosuchfunc(1)"]
        }))
        .await;

    let status = &execution["QueryExecution"]["Status"];
    assert_eq!(status["State"], "FAILED");
    let reason = status["StateChangeReason"].as_str().unwrap();
    assert!(reason.starts_with("FUNCTION_NOT_FOUND: "), "理由: {reason}");
}

#[tokio::test]
async fn プレースホルダの無い_sql_に渡した値は捨てて実行し直す() {
    // Athena は ? が 0 個なら余剰パラメータを黙って無視する。Trino は拒否するので素の SQL で投げ直す。
    let harness = Harness::builder(trino_single_value("integer", json!(1)))
        .route(
            "EXECUTE IMMEDIATE 'SELECT 1' USING 1",
            trino_error(
                "INVALID_PARAMETER_USAGE",
                "line 1:20: Incorrect number of parameters: expected 0 but found 1",
            ),
        )
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "SELECT 1",
            "ExecutionParameters": ["1"]
        }))
        .await;

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        harness.trino_sqls(),
        [
            "SELECT (1)",
            "EXECUTE IMMEDIATE 'SELECT 1' USING 1",
            "SELECT 1"
        ]
    );
}

#[tokio::test]
async fn パラメータの数が合わなければ_failed_になり投げ直さない() {
    let harness = Harness::builder(trino_single_value("integer", json!(1)))
        .route(
            "EXECUTE IMMEDIATE 'SELECT ? AS a' USING 1, 2",
            trino_error(
                "INVALID_PARAMETER_USAGE",
                "line 1:20: Incorrect number of parameters: expected 1 but found 2",
            ),
        )
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "SELECT ? AS a",
            "ExecutionParameters": ["1", "2"]
        }))
        .await;

    let status = &execution["QueryExecution"]["Status"];
    assert_eq!(status["State"], "FAILED");
    assert!(
        status["StateChangeReason"]
            .as_str()
            .unwrap()
            .contains("expected 1 but found 2")
    );
    assert_eq!(harness.trino_sqls().len(), 3, "分類 2 回 + 本体 1 回");
}

#[tokio::test]
async fn パラメータが_null_なら無いものとして扱う() {
    // AWS SDK は未指定を送らないが、手書きのクライアントは null を送ることがある。
    let harness = Harness::start(select_response()).await;

    let execution = harness
        .run_query(json!({
            "QueryString": "SELECT 1 AS v",
            "ExecutionParameters": null
        }))
        .await;

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(harness.trino_sqls(), ["SELECT 1 AS v"]);
}

#[tokio::test]
async fn 空のパラメータなら分類もせず_sql_をそのまま送る() {
    let harness = Harness::start(select_response()).await;

    harness
        .run_query(json!({
            "QueryString": "SELECT ? AS v",
            "ExecutionParameters": []
        }))
        .await;

    assert_eq!(harness.trino_sqls(), ["SELECT ? AS v"]);
}
