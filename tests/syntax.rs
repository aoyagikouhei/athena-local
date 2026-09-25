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
        error["Message"],
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
    assert_eq!(error["Message"], "line 2:6: mismatched input 'WHERE'");
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
        error["Message"],
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

#[tokio::test]
async fn ブロックコメント付きの_show_create_table_も本物と違いそのまま通る() {
    // 本物は分類だけ正しく返し、実行時に ParseException で弾く（2026-09-18 実測）。
    // athena-local は受け取った SQL をそのまま Trino に投げるので成功する。
    // docs/caveats.md の SQL dialect に書いてある差を、SQL を書き換えないことで固定する。
    let sql = "/* c */ SHOW CREATE TABLE t";
    let harness = Harness::builder(select_response())
        .route(
            sql,
            json!({
                "columns": [{ "name": "Create Table", "type": "varchar" }],
                "data": [["CREATE TABLE t (id integer)"]]
            }),
        )
        .start()
        .await;

    let execution = harness.run_query(json!({ "QueryString": sql })).await;

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(harness.syntax_checks(), [sql]);
    // 形式の問い合わせ（#160 で S3 無効でも飛ぶ）が 1 本前に入るが、本体は受け取った SQL のまま。
    let sqls = harness.trino_sqls();
    assert_eq!(sqls.len(), 2, "{sqls:?}");
    assert_eq!(sqls.last().map(String::as_str), Some(sql));
}

/// 本物は引用符付きの名前を取る DESCRIBE などを、Trino が受ける形でも開始時に弾く（2026-09-25 実測。#204）。
/// 文言は本物の Hive 系のパーサのもので、構文チェックを通った後に athena-local が返す。
#[tokio::test]
async fn 引用符付きの名前の_describe_は構文チェックの後に本物の文言で弾き_実行を作らない() {
    let query = r#"DESCRIBE "t""#;
    let harness = Harness::builder(select_response()).start().await;

    let (code, error) = harness
        .call("StartQueryExecution", json!({ "QueryString": query }))
        .await;

    assert_eq!(code, 400, "{error}");
    assert_eq!(error["__type"], "InvalidRequestException");
    assert_eq!(error["AthenaErrorCode"], "MALFORMED_QUERY");
    assert_eq!(
        error["Message"],
        r#"line 1:10: no viable alternative at input 'DESCRIBE "t"'"#
    );
    assert_eq!(harness.syntax_checks(), [query], "構文チェックは先に送る");
    // 存在の問い合わせ（#207）は送るが、応答が問い合わせの形でないので存在は分からず、構文の文言になる。
    assert_eq!(harness.trino_sqls().len(), 1, "探索だけで、実行は作らない");
}

/// Trino が構文エラーにする形は、本物も Trino の文言を返した（`ALTER TABLE "t" ADD COLUMNS`。2026-09-25 実測）。
#[tokio::test]
async fn 引用符付きの名前でも構文エラーなら_trino_の文言を返す() {
    let query = r#"ALTER TABLE "t" ADD COLUMNS (m int)"#;
    let harness = Harness::builder(select_response())
        .syntax_check_response(
            query,
            syntax_error("line 2:21: mismatched input 'COLUMNS'. Expecting: '.', 'ADD'"),
        )
        .start()
        .await;

    let (code, error) = harness
        .call("StartQueryExecution", json!({ "QueryString": query }))
        .await;

    assert_eq!(code, 400, "{error}");
    assert_eq!(
        error["Message"],
        "line 1:21: mismatched input 'COLUMNS'. Expecting: '.', 'ADD'"
    );
}

/// 本物は無引用の `ALTER TABLE IF EXISTS ...` と単数形の `ADD COLUMN` も、Trino が構文として受ける形でも
/// 開始時に弾く（2026-09-26 実測。#208）。文言は quoted_names と同じ出口（`unquoted_ddl::rejection`）から返す。
#[tokio::test]
async fn 無引用の_alter_table_も本物の文言で開始時に弾き_実行を作らない() {
    let harness = Harness::builder(select_response()).start().await;

    for (query, message) in [
        (
            "ALTER TABLE IF EXISTS t RENAME TO u",
            "line 1:16: no viable alternative at input 'ALTER TABLE IF EXISTS'",
        ),
        (
            "ALTER TABLE t ADD COLUMN m int",
            "line 1:19: no viable alternative at input 'ALTER TABLE t ADD COLUMN'",
        ),
    ] {
        let (code, error) = harness
            .call("StartQueryExecution", json!({ "QueryString": query }))
            .await;

        assert_eq!(code, 400, "{query}: {error}");
        assert_eq!(error["__type"], "InvalidRequestException", "{query}");
        assert_eq!(error["AthenaErrorCode"], "MALFORMED_QUERY", "{query}");
        assert_eq!(error["Message"], message, "{query}");
        assert_eq!(harness.syntax_checks().last(), Some(&query.to_string()));
        assert!(
            harness.trino_requests().is_empty(),
            "{query}: 実行は作らない"
        );
    }
}

/// `quoted_names::rejection` の文言が無引用の ALTER TABLE の文言より先に決まる
/// （`execution.rs` の `or_else` の順序。#204 が先、#208 は quoted_names が None のときだけ）。
/// 引用符付きの名前は quoted_names が先に決めるので unquoted_ddl は呼ばれても None を返す。
/// 4 部以上の無引用の名前は、名前の解析だけで両方が別の文言を返しうる実例
/// （quoted_names は 3 つ目の `.` で、unquoted_ddl は ADD COLUMN の位置で。本物も名前を先に読む）。
#[tokio::test]
async fn quoted_names_の文言が無引用の_alter_table_の文言より先に決まる() {
    let harness = Harness::builder(select_response()).start().await;

    for (query, message) in [
        (
            r#"ALTER TABLE "t" ADD COLUMN m int"#,
            r#"line 1:13: no viable alternative at input 'ALTER TABLE "t"'"#.to_string(),
        ),
        (
            "ALTER TABLE a.b.c.d ADD COLUMN m int",
            "line 1:18: no viable alternative at input 'ALTER TABLE a.b.c.'".to_string(),
        ),
    ] {
        let (code, error) = harness
            .call("StartQueryExecution", json!({ "QueryString": query }))
            .await;

        assert_eq!(code, 400, "{query}: {error}");
        assert_eq!(error["Message"], message, "{query}");
        assert!(
            harness.trino_requests().is_empty(),
            "{query}: 実行は作らない"
        );
    }
}

/// 本物は CTAS でない無引用の `CREATE TABLE` も、Trino が構文として受ける形でも開始時に弾く
/// （2026-09-26 実測。#208 のフェーズ 2）。文言は ALTER TABLE と同じ出口（`unquoted_ddl::rejection` から
/// `create_table::rejection`）から返す。
#[tokio::test]
async fn 場所の無い_create_table_も本物の文言で開始時に弾き_実行を作らない() {
    let harness = Harness::builder(select_response()).start().await;

    for (query, message) in [
        (
            "CREATE TABLE t (n int)",
            "No location was specified for table. An S3 location must be specified",
        ),
        (
            "CREATE TABLE t (n int) WITH (format = 'PARQUET')",
            "line 1:29: no viable alternative at input 'CREATE TABLE t (n int) WITH ('",
        ),
    ] {
        let (code, error) = harness
            .call("StartQueryExecution", json!({ "QueryString": query }))
            .await;

        assert_eq!(code, 400, "{query}: {error}");
        assert_eq!(error["__type"], "InvalidRequestException", "{query}");
        assert_eq!(error["AthenaErrorCode"], "MALFORMED_QUERY", "{query}");
        assert_eq!(error["Message"], message, "{query}");
        assert_eq!(harness.syntax_checks().last(), Some(&query.to_string()));
        assert!(
            harness.trino_requests().is_empty(),
            "{query}: 実行は作らない"
        );
    }
}
