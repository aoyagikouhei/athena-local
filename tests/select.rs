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

    // 型は Athena と同じ見え方にする（基底名・Precision・CaseSensitive。2026-09-14 実測）。
    let columns = results["ResultSet"]["ResultSetMetadata"]["ColumnInfo"]
        .as_array()
        .unwrap();
    assert_eq!(columns[0]["Name"], "id");
    assert_eq!(columns[0]["Type"], "uuid");
    assert_eq!(columns[1]["Type"], "varchar");
    assert_eq!(columns[1]["Precision"], 2147483647);
    assert_eq!(columns[1]["CaseSensitive"], true);
    assert_eq!(columns[1]["CatalogName"], "hive");
    assert_eq!(columns[1]["SchemaName"], "");

    // 本物は SELECT でも UpdateCount に 0 を入れて返す（2026-09-14 実測）。
    assert_eq!(results["UpdateCount"], 0);
}

#[tokio::test]
async fn カタログとスキーマはヘッダで渡り_sql_は書き換えられない() {
    let harness = Harness::start(select_response()).await;
    harness
        .run_query(json!({
            "QueryString": "SELECT id, name FROM users",
            "QueryExecutionContext": { "Catalog": "iceberg", "Database": "my_schema" }
        }))
        .await;

    let requests = harness.trino_requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].sql, "SELECT id, name FROM users");
    assert_eq!(requests[0].catalog.as_deref(), Some("iceberg"));
    assert_eq!(requests[0].schema.as_deref(), Some("my_schema"));
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

/// MaxResults が 1 未満のときの本物の文言（2026-09-23 実測。ListWorkGroups と同文）。
const MAX_RESULTS_TOO_SMALL: &str = "1 validation error detected: Value at 'maxResults' failed to satisfy constraint: Member must have value greater than or equal to 1";
/// MaxResults が 1000 を超えたときの本物の文言（2026-09-23 実測。ListWorkGroups の上限超過とは形が違う）。
const MAX_RESULTS_TOO_LARGE: &str = "MaxResults is more than maximum allowed length 1000";
/// NextToken が空文字のときの本物の文言（2026-09-23 実測。ListWorkGroups と同文）。
const NEXT_TOKEN_EMPTY: &str = "1 validation error detected: Value at 'nextToken' failed to satisfy constraint: Member must have length greater than or equal to 1";
/// 実在しない QueryExecutionId（形は正しい UUID）。
const MISSING_ID: &str = "00000000-0000-4000-8000-000000000083";

fn assert_invalid_input(status: u16, error: &serde_json::Value, message: &str, label: &str) {
    assert_eq!(status, 400, "{label}");
    assert_eq!(error["__type"], "InvalidRequestException", "{label}");
    assert_eq!(error["AthenaErrorCode"], "INVALID_INPUT", "{label}");
    assert_eq!(error["ErrorCode"], "INVALID_INPUT", "{label}");
    assert_eq!(error["Message"], message, "{label}");
}

#[tokio::test]
async fn max_results_が範囲外ならエラーにする() {
    let harness = Harness::start(select_response()).await;
    let execution = harness
        .run_query(json!({ "QueryString": "SELECT id, name FROM users" }))
        .await;
    let id = execution_id(&execution);

    for (max_results, message) in [
        (0, MAX_RESULTS_TOO_SMALL),
        (-1, MAX_RESULTS_TOO_SMALL),
        (1001, MAX_RESULTS_TOO_LARGE),
    ] {
        let (status, error) = harness
            .call(
                "GetQueryResults",
                json!({ "QueryExecutionId": id, "MaxResults": max_results }),
            )
            .await;
        assert_invalid_input(
            status,
            &error,
            message,
            &format!("MaxResults={max_results}"),
        );
    }

    // 上限ちょうどは通る。
    let (status, results) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": id, "MaxResults": 1000 }),
        )
        .await;
    assert_eq!(status, 200);
    assert_eq!(results["ResultSet"]["Rows"].as_array().unwrap().len(), 3);

    // 下限の検証は ID の存在確認より先、上限は存在確認より後（2026-09-23 実測）。
    let (status, error) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": MISSING_ID, "MaxResults": 0 }),
        )
        .await;
    assert_invalid_input(status, &error, MAX_RESULTS_TOO_SMALL, "実在しない ID と 0");
    let (status, error) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": MISSING_ID, "MaxResults": 1001 }),
        )
        .await;
    assert_eq!(status, 400, "実在しない ID と 1001");
    assert_eq!(error["AthenaErrorCode"], "QUERY_EXECUTION_NOT_FOUND");
}

#[tokio::test]
async fn 不正な_next_token_はエラーにする() {
    let harness = Harness::start(select_response()).await;
    let execution = harness
        .run_query(json!({ "QueryString": "SELECT id, name FROM users" }))
        .await;
    let id = execution_id(&execution);

    // 発行するのは 1 <= end <= 3 の 10 進（3 は満杯の次の空のページ）なので、それ以外は弾く（文言は 2026-09-23 実測。
    // ListWorkGroups の `The nextPageToken is malformed: ...` とは違う）。
    for token in ["abc", "999", "4"] {
        let (status, error) = harness
            .call(
                "GetQueryResults",
                json!({ "QueryExecutionId": id, "NextToken": token }),
            )
            .await;
        assert_invalid_input(
            status,
            &error,
            &format!("Malformed nextPageToken {token}"),
            &format!("NextToken={token:?}"),
        );
    }

    // 空文字だけは枠組みの長さの制約のエラーになる。
    let (status, error) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": id, "NextToken": "" }),
        )
        .await;
    assert_invalid_input(status, &error, NEXT_TOKEN_EMPTY, "空文字");

    // 空文字と下限未満が同時なら nextToken → maxResults の順で 1 文にまとまる。
    // 上限超過は枠組みの検証ではないので、空文字と同時なら空文字だけが出る。
    let (status, error) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": id, "MaxResults": 0, "NextToken": "" }),
        )
        .await;
    assert_invalid_input(
        status,
        &error,
        "2 validation errors detected: Value at 'nextToken' failed to satisfy constraint: Member must have length greater than or equal to 1; Value at 'maxResults' failed to satisfy constraint: Member must have value greater than or equal to 1",
        "0 と空文字",
    );
    let (status, error) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": id, "MaxResults": 1001, "NextToken": "" }),
        )
        .await;
    assert_invalid_input(status, &error, NEXT_TOKEN_EMPTY, "1001 と空文字");

    // 上限はトークンの形より先に見る。
    let (status, error) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": id, "MaxResults": 1001, "NextToken": "abc" }),
        )
        .await;
    assert_invalid_input(status, &error, MAX_RESULTS_TOO_LARGE, "1001 と abc");

    // 空文字は ID の存在確認より先、不正な形は存在確認より後。
    let (status, error) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": MISSING_ID, "NextToken": "" }),
        )
        .await;
    assert_invalid_input(status, &error, NEXT_TOKEN_EMPTY, "実在しない ID と空文字");
    let (status, error) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": MISSING_ID, "NextToken": "abc" }),
        )
        .await;
    assert_eq!(status, 400, "実在しない ID と abc");
    assert_eq!(error["AthenaErrorCode"], "QUERY_EXECUTION_NOT_FOUND");
}

#[tokio::test]
async fn max_results_が枠組みの上限を超えると_1000_の文言より先に枠組みの検証になる() {
    // 2026-09-23 実測（#85）: 本物の枠組みの上限は 100000 で、それを超えると 1000 の本体の文言ではなく
    // `Member must have value less than or equal to 100000` になる。
    let harness = Harness::start(select_response()).await;
    let execution = harness
        .run_query(json!({ "QueryString": "SELECT id, name FROM users" }))
        .await;

    let (status, error) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": execution_id(&execution), "MaxResults": 100_001 }),
        )
        .await;
    assert_invalid_input(
        status,
        &error,
        "1 validation error detected: Value at 'maxResults' failed to satisfy constraint: Member must have value less than or equal to 100000",
        "100001",
    );
}

#[tokio::test]
async fn 行の無い_utility_の結果は_next_token_を無視する() {
    // 2026-09-23 実測（#85）: 0 行の SHOW に不正なトークンを渡しても 200 で 0 行（トークンは見ない）。
    // 列名行だけの DML は行が 1 つあるので、不正なトークンは Malformed になる（同じ実測）。
    let harness = Harness::builder(select_response())
        .route(
            "SHOW DATABASES LIKE 'no_such'",
            json!({ "columns": [{ "name": "Database", "type": "varchar" }], "data": [] }),
        )
        .route(
            "SELECT 1 AS n WHERE false",
            json!({ "columns": [{ "name": "n", "type": "integer" }], "data": [] }),
        )
        .start()
        .await;

    let execution = harness
        .run_query(json!({ "QueryString": "SHOW DATABASES LIKE 'no_such'" }))
        .await;
    for token in ["not-a-token", "1"] {
        let (status, body) = harness
            .call(
                "GetQueryResults",
                json!({ "QueryExecutionId": execution_id(&execution), "NextToken": token }),
            )
            .await;
        assert_eq!(status, 200, "SHOW NextToken={token:?}");
        assert_eq!(body["ResultSet"]["Rows"].as_array().unwrap().len(), 0);
        assert!(body.get("NextToken").is_none());
    }

    let execution = harness
        .run_query(json!({ "QueryString": "SELECT 1 AS n WHERE false" }))
        .await;
    let (status, error) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": execution_id(&execution), "NextToken": "abc" }),
        )
        .await;
    assert_invalid_input(
        status,
        &error,
        "Malformed nextPageToken abc",
        "列名行だけの DML",
    );
}

#[tokio::test]
async fn next_token_はページが満杯なら残りが無くても付き_次のページは空になる() {
    // 2026-09-23 実測（#85）: 6 行を MaxResults=6 で取ると 6 行 + NextToken、次は 0 行でトークン無し。
    // 3 ずつでも 2 ページ目（3 行）にトークンが付き 3 ページ目が空。4 ずつなら 2 ページ目（2 行）で終わる。
    // 列名行だけの結果も MaxResults=1 で 1 行 + トークン、次は 0 行。
    let harness = Harness::builder(select_response())
        .route(
            "SELECT 1 AS n WHERE false",
            json!({ "columns": [{ "name": "n", "type": "integer" }], "data": [] }),
        )
        .start()
        .await;
    let execution = harness
        .run_query(json!({ "QueryString": "SELECT id, name FROM users" }))
        .await;
    let id = execution_id(&execution);

    // 3 行（列名行 + 2）を 3 で: 満杯なのでトークンが付き、次は空。
    let (_, first) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": id, "MaxResults": 3 }),
        )
        .await;
    assert_eq!(first["ResultSet"]["Rows"].as_array().unwrap().len(), 3);
    let token = first["NextToken"]
        .as_str()
        .expect("満杯なら NextToken が付く");
    let (status, second) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": id, "MaxResults": 3, "NextToken": token }),
        )
        .await;
    assert_eq!(status, 200);
    assert_eq!(second["ResultSet"]["Rows"].as_array().unwrap().len(), 0);
    assert!(second.get("NextToken").is_none(), "空のページには付かない");

    // 3 行を 1000（既定）で: 満杯ではないので付かない。
    let (_, all) = harness
        .call("GetQueryResults", json!({ "QueryExecutionId": id }))
        .await;
    assert_eq!(all["ResultSet"]["Rows"].as_array().unwrap().len(), 3);
    assert!(all.get("NextToken").is_none());

    // 列名行だけの DML を 1 で: 1 行 + トークン、次は空。
    let execution = harness
        .run_query(json!({ "QueryString": "SELECT 1 AS n WHERE false" }))
        .await;
    let id = execution_id(&execution);
    let (_, first) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": id, "MaxResults": 1 }),
        )
        .await;
    assert_eq!(first["ResultSet"]["Rows"].as_array().unwrap().len(), 1);
    let token = first["NextToken"]
        .as_str()
        .expect("列名行だけでも満杯なら付く");
    let (_, second) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": id, "MaxResults": 1, "NextToken": token }),
        )
        .await;
    assert_eq!(second["ResultSet"]["Rows"].as_array().unwrap().len(), 0);
    assert!(second.get("NextToken").is_none());
}

#[tokio::test]
async fn 結果の無いクエリでも_max_results_の上限は先に見る() {
    // 2026-09-23 実測: 上限超過はクエリの状態より先、トークンの形は状態より後。
    let harness = Harness::start(common::trino_error(
        "TABLE_NOT_FOUND",
        "line 1:15: Table 'no_such' does not exist",
    ))
    .await;
    let execution = harness
        .run_query(json!({ "QueryString": "SELECT * FROM no_such" }))
        .await;
    let id = execution_id(&execution);
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "FAILED");

    let (status, error) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": id, "MaxResults": 1001 }),
        )
        .await;
    assert_invalid_input(status, &error, MAX_RESULTS_TOO_LARGE, "FAILED と 1001");

    let (status, error) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": id, "NextToken": "" }),
        )
        .await;
    assert_invalid_input(status, &error, NEXT_TOKEN_EMPTY, "FAILED と空文字");

    let (status, error) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": id, "NextToken": "abc" }),
        )
        .await;
    assert_eq!(status, 400, "FAILED と abc");
    assert_eq!(error["AthenaErrorCode"], "INVALID_QUERY_EXECUTION_STATE");
    assert_eq!(
        error["Message"],
        "Query did not finish successfully. Final query state: FAILED"
    );
}

#[tokio::test]
async fn 配列の列は_athena_の表記で返る() {
    // 利用側が "[1, 2, 3]" を ", " で分割して読んでも値が化けないこと。
    let harness = Harness::start(json!({
        "columns": [{
            "name": "counts",
            "type": "array(bigint)",
            "typeSignature": {
                "rawType": "array",
                "arguments": [{ "kind": "TYPE", "value": { "rawType": "bigint", "arguments": [] } }]
            }
        }],
        "data": [[[1, 2, 3]], [null]]
    }))
    .await;

    let execution = harness
        .run_query(json!({ "QueryString": "SELECT counts FROM t" }))
        .await;
    let (_, results) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": execution_id(&execution) }),
        )
        .await;

    let rows = results["ResultSet"]["Rows"].as_array().unwrap();
    assert_eq!(rows[1]["Data"][0]["VarCharValue"], "[1, 2, 3]");
    assert!(rows[2]["Data"][0].get("VarCharValue").is_none());
    assert_eq!(
        results["ResultSet"]["ResultSetMetadata"]["ColumnInfo"][0]["Type"],
        "array"
    );
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

#[tokio::test]
async fn 日時を精度どおりに受け取るよう_trino_に伝える() {
    // 伝えないと Trino は timestamp を小数 3 桁に丸める。
    let harness = Harness::start(select_response()).await;
    harness
        .run_query(json!({ "QueryString": "SELECT 1" }))
        .await;

    assert_eq!(
        harness.trino_requests()[0].client_capabilities.as_deref(),
        Some("PARAMETRIC_DATETIME")
    );
}

/// SHOW / DESCRIBE の Trino 応答（列 1 つ、データ 2 行）。
fn show_response() -> serde_json::Value {
    json!({
        "columns": [{ "name": "table_name", "type": "varchar" }],
        "data": [["orders"], ["users"]]
    })
}

#[tokio::test]
async fn show_と_describe_の結果には列名行が入らない() {
    // 本物は UTILITY（SHOW TABLES / SHOW DATABASES / SHOW COLUMNS / SHOW CREATE TABLE /
    // SHOW PARTITIONS / SHOW TBLPROPERTIES / DESCRIBE）で先頭行に列名を入れない
    // （2026-09-15〜22 の実測 5 ラウンドの GetQueryResults 応答を読み直して確認。#60）。
    let harness = Harness::builder(show_response())
        .route("DESCRIBE t", show_response())
        .start()
        .await;

    for query in ["SHOW TABLES IN db", "DESCRIBE t"] {
        let execution = harness.run_query(json!({ "QueryString": query })).await;
        let id = execution_id(&execution);
        let (status, results) = harness
            .call("GetQueryResults", json!({ "QueryExecutionId": id }))
            .await;
        assert_eq!(status, 200, "{query}");

        let rows = results["ResultSet"]["Rows"].as_array().unwrap();
        assert_eq!(rows.len(), 2, "{query}: データ 2 行だけ（列名行は無い）");
        assert_eq!(rows[0]["Data"][0]["VarCharValue"], "orders", "{query}");
        assert_eq!(rows[1]["Data"][0]["VarCharValue"], "users", "{query}");
        // 列の情報は変わらず載る。
        assert_eq!(
            results["ResultSet"]["ResultSetMetadata"]["ColumnInfo"][0]["Name"], "table_name",
            "{query}"
        );

        // ページングも列名行を数えない。1 件目はデータの 1 行目。
        let (_, page) = harness
            .call(
                "GetQueryResults",
                json!({ "QueryExecutionId": id, "MaxResults": 1 }),
            )
            .await;
        let rows = page["ResultSet"]["Rows"].as_array().unwrap();
        assert_eq!(rows.len(), 1, "{query}");
        assert_eq!(rows[0]["Data"][0]["VarCharValue"], "orders", "{query}");
        assert_eq!(page["NextToken"], "1", "{query}");
    }
}

#[tokio::test]
async fn show_functions_の結果には_utility_でも列名行が入る() {
    // 本物は SHOW FUNCTIONS だけ、UTILITY（SubstatementType SHOW_FUNCTIONS）なのに SELECT と
    // 同じく先頭行に列名を返す（2026-09-23 実測の GetQueryResults 応答。#80）。
    let harness = Harness::builder(show_response())
        .route(
            "SHOW FUNCTIONS",
            json!({
                "columns": [
                    { "name": "Function", "type": "varchar" },
                    { "name": "Deterministic", "type": "boolean" }
                ],
                "data": [["abs", true], ["zip_with", false]]
            }),
        )
        .start()
        .await;

    let execution = harness
        .run_query(json!({ "QueryString": "SHOW FUNCTIONS" }))
        .await;
    assert_eq!(execution["QueryExecution"]["StatementType"], "UTILITY");
    assert_eq!(
        execution["QueryExecution"]["SubstatementType"],
        "SHOW_FUNCTIONS"
    );
    let id = execution_id(&execution);
    let (status, results) = harness
        .call("GetQueryResults", json!({ "QueryExecutionId": id }))
        .await;
    assert_eq!(status, 200);

    let rows = results["ResultSet"]["Rows"].as_array().unwrap();
    assert_eq!(rows.len(), 3, "列名行 + データ 2 行");
    assert_eq!(rows[0]["Data"][0]["VarCharValue"], "Function");
    assert_eq!(rows[0]["Data"][1]["VarCharValue"], "Deterministic");
    assert_eq!(rows[1]["Data"][0]["VarCharValue"], "abs");
    assert_eq!(rows[1]["Data"][1]["VarCharValue"], "true");
    assert_eq!(rows[2]["Data"][0]["VarCharValue"], "zip_with");

    // ページングも列名行を数える（SELECT と同じ）。1 件目は列名行。
    let (_, page) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": id, "MaxResults": 1 }),
        )
        .await;
    let rows = page["ResultSet"]["Rows"].as_array().unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["Data"][0]["VarCharValue"], "Function");
    assert_eq!(page["NextToken"], "1");
}

#[tokio::test]
async fn explain_の結果には_select_と同じく列名行が入る() {
    // EXPLAIN は StatementType が DML で、本物は SELECT と同じく先頭行に列名を入れる
    // （2026-09-15〜18 実測。#60）。Trino は `Query Plan` 列の 1 行に改行入りの全文（末尾 `\n\n`）を
    // 返すが、本物はその全文の末尾に改行を 1 つ足してから `\n` で分けた行を返す（`EXPLAIN SELECT 1` は
    // 列名行 + 非空 11 行 + 空行 3 行の 15 行。2026-09-15／16 の 4 ラウンドで実測。#73）。
    let harness = Harness::start(json!({
        "columns": [{ "name": "Query Plan", "type": "varchar(371)", "typeSignature": { "rawType": "varchar", "arguments": [{ "kind": "LONG", "value": 371 }] } }],
        "data": [["Fragment 0 [SINGLE]\n    Output layout: [expr]\n\n"]]
    }))
    .await;
    let execution = harness
        .run_query(json!({ "QueryString": "EXPLAIN SELECT 1" }))
        .await;
    let (_, results) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": execution_id(&execution) }),
        )
        .await;

    let rows = results["ResultSet"]["Rows"].as_array().unwrap();
    let values: Vec<_> = rows
        .iter()
        .map(|row| row["Data"][0]["VarCharValue"].as_str().unwrap())
        .collect();
    assert_eq!(
        values,
        [
            "Query Plan",
            "Fragment 0 [SINGLE]",
            "    Output layout: [expr]",
            "",
            "",
            "",
        ],
        "列名行 + プランの行ごとに 1 行 + 末尾の空行（全文の末尾 `\\n\\n` の 2 行 + 足した 1 行）"
    );

    // 列は本物と同じく varchar(<プラン本文の文字数>)。本物の EXPLAIN SELECT 1 は varchar(371)
    // （2026-09-15／16 実測）で、Trino も同じ仕組みでプランの文字数を型に入れる（Trino 482 は
    // 同じ文で varchar(400)）。athena-local はその長さを Precision にそのまま通す（#68）。
    let column = &results["ResultSet"]["ResultSetMetadata"]["ColumnInfo"][0];
    assert_eq!(column["Type"], "varchar");
    assert_eq!(column["Precision"], 371);
    assert_eq!(column["CaseSensitive"], true);
}
