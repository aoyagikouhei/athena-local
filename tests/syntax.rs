//! 構文エラーは StartQueryExecution で 400（MALFORMED_QUERY）にして、実行を作らない。
//! 本番 Athena の挙動（2026-09-14 実測）。athena-local は元の SQL を Trino に PREPARE させて確かめる。

mod common;

use common::{Harness, trino_error};
use serde_json::{Value, json};

const EXPECTING: &str = "Expecting: 'ALTER', 'ANALYZE', 'CALL', <query>";

fn select_response() -> Value {
    json!({ "columns": [{ "name": "n", "type": "bigint" }], "data": [[1]] })
}

fn syntax_error(message: &str) -> Value {
    trino_error("SYNTAX_ERROR", message)
}

#[tokio::test]
async fn 構文エラーは開始時に_400_で弾き_本体は_trino_に送らない() {
    // Trino は前置きの 1 行ぶんずれた位置で返す。
    let harness = Harness::builder(select_response())
        .syntax_check_response(
            "SELEC 1",
            syntax_error(&format!("line 2:1: mismatched input 'SELEC'. {EXPECTING}")),
        )
        .start()
        .await;

    let (code, error) = harness
        .call("StartQueryExecution", json!({ "QueryString": "SELEC 1" }))
        .await;

    assert_eq!(code, 400);
    assert_eq!(error["__type"], "InvalidRequestException");
    assert_eq!(error["AthenaErrorCode"], "MALFORMED_QUERY");
    assert_eq!(
        error["message"],
        format!("line 1:1: mismatched input 'SELEC'. {EXPECTING}")
    );
    assert_eq!(harness.syntax_checks(), ["SELEC 1"]);
    assert!(harness.trino_requests().is_empty(), "実行は作らない");
}

#[tokio::test]
async fn 複数行の文でも元の_sql_の行で数える() {
    let sql = "SELECT 1\nFROM WHERE";
    let harness = Harness::builder(select_response())
        .syntax_check_response(sql, syntax_error("line 3:6: mismatched input 'WHERE'"))
        .start()
        .await;

    let (code, error) = harness
        .call("StartQueryExecution", json!({ "QueryString": sql }))
        .await;

    assert_eq!(code, 400);
    assert_eq!(error["message"], "line 2:6: mismatched input 'WHERE'");
}

#[tokio::test]
async fn パラメータ付きでも値を当てる前の_sql_で確かめる() {
    let harness = Harness::builder(select_response())
        .syntax_check_response(
            "SELEC ?",
            syntax_error(&format!("line 2:1: mismatched input 'SELEC'. {EXPECTING}")),
        )
        .start()
        .await;

    let (code, error) = harness
        .call(
            "StartQueryExecution",
            json!({ "QueryString": "SELEC ?", "ExecutionParameters": ["1"] }),
        )
        .await;

    assert_eq!(code, 400);
    assert_eq!(
        error["message"],
        format!("line 1:1: mismatched input 'SELEC'. {EXPECTING}")
    );
    assert_eq!(harness.syntax_checks(), ["SELEC ?"]);
    assert!(harness.trino_requests().is_empty(), "値の分類も走らせない");
}

#[tokio::test]
async fn 構文が正しければ確かめたうえでそのまま実行する() {
    let harness = Harness::start(select_response()).await;

    let execution = harness
        .run_query(json!({ "QueryString": "SELECT n FROM t" }))
        .await;

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(harness.syntax_checks(), ["SELECT n FROM t"]);
    assert_eq!(harness.trino_sqls(), ["SELECT n FROM t"]);
}

#[tokio::test]
async fn 構文エラー以外の失敗は開始時には返さず実行に任せる() {
    // PREPARE を包めない文は Trino が NOT_SUPPORTED を返す。構文は正しいので実行に進む。
    let harness = Harness::builder(select_response())
        .syntax_check_response(
            "PREPARE p FROM SELECT 1",
            trino_error(
                "NOT_SUPPORTED",
                "Invalid statement type for prepared statement: PREPARE",
            ),
        )
        .start()
        .await;

    let (code, started) = harness
        .call(
            "StartQueryExecution",
            json!({ "QueryString": "PREPARE p FROM SELECT 1" }),
        )
        .await;

    assert_eq!(code, 200, "{started}");
    assert!(started["QueryExecutionId"].is_string());
}
