//! ResultConfiguration.OutputLocation: 結果 CSV を S3 互換ストレージに書き、GetQueryExecution にフルパスを返す。
//! 置き場所・ファイル名・エラーの文言は 2026-09-14 に本番 Athena で実測したもの。

mod common;

use std::time::Duration;

use common::{Harness, S3Put, TRINO_QUERY_ID, execution_id, wait_for};
use serde_json::{Value, json};

fn select_response() -> Value {
    json!({
        "columns": [
            { "name": "id", "type": "integer" },
            { "name": "name", "type": "varchar" }
        ],
        "data": [[1, "it's \"x\""], [2, null]]
    })
}

fn dml_response() -> Value {
    json!({
        "columns": [{ "name": "rows", "type": "bigint" }],
        "data": [[1]],
        "updateType": "INSERT",
        "updateCount": 1
    })
}

fn show_response() -> Value {
    json!({
        "columns": [{ "name": "table_name", "type": "varchar" }],
        "data": [["orders"], ["users"]]
    })
}

fn output_location(execution: &Value) -> &str {
    execution["QueryExecution"]["ResultConfiguration"]["OutputLocation"]
        .as_str()
        .expect("OutputLocation が無い")
}

fn select_with_output(location: &str) -> Value {
    json!({
        "QueryString": "SELECT id, name FROM users",
        "ResultConfiguration": { "OutputLocation": location }
    })
}

#[tokio::test]
async fn select_の結果を_csv_で書き_フルパスを返す() {
    let harness = Harness::builder(select_response())
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(select_with_output("s3://results-bucket/athena/"))
        .await;
    let id = execution_id(&execution);

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        output_location(&execution),
        format!("s3://results-bucket/athena/{id}.csv")
    );
    // 本体の隣に付随ファイル `.csv.metadata` も置く（中身は tests/metadata.rs が見る）。
    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(
        puts[0],
        S3Put {
            bucket: "results-bucket".to_string(),
            key: format!("athena/{id}.csv"),
            body: b"\"id\",\"name\"\n\"1\",\"it's \"\"x\"\"\"\n\"2\",\n".to_vec(),
            content_type: Some("application/octet-stream".to_string()),
            presigned: true,
        }
    );
    assert_eq!(puts[1].key, format!("athena/{id}.csv.metadata"));
}

#[tokio::test]
async fn 書き終わるまで_succeeded_にしない() {
    let harness = Harness::builder(select_response())
        .results_s3()
        .s3_delay(Duration::from_millis(300))
        .start()
        .await;

    let id = harness
        .start_query(select_with_output("s3://results-bucket/athena/"))
        .await;
    wait_for("偽 S3 が PUT を受ける", || {
        harness.s3_puts().len() == 1
    })
    .await;

    // PUT の応答を待っている間は RUNNING のまま。
    assert_eq!(harness.status(&id).await["State"], "RUNNING");

    // 応答が返れば SUCCEEDED になる。
    let execution = harness.wait_until_done(&id).await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
}

#[tokio::test]
async fn 既定の出力先を使い_末尾スラッシュが無くても同じ場所に置く() {
    let harness = Harness::builder(select_response())
        .results_s3()
        .default_output_location("s3://results-bucket/prefix")
        .start()
        .await;

    let execution = harness
        .run_query(json!({ "QueryString": "SELECT id, name FROM users" }))
        .await;
    let id = execution_id(&execution);
    assert_eq!(
        output_location(&execution),
        format!("s3://results-bucket/prefix/{id}.csv")
    );

    // リクエストの値は既定より優先する。prefix が無ければバケット直下。
    let execution = harness
        .run_query(select_with_output("s3://other-bucket"))
        .await;
    let other = execution_id(&execution);

    // 付随ファイルも合わせて 4 件。どのバケットのどのキーに置いたかを順に全件見る
    // （付随ファイルが本体と別のバケットに落ちても気づけるように）。
    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 4, "{puts:?}");
    let places: Vec<(&str, &str)> = puts
        .iter()
        .map(|put| (put.bucket.as_str(), put.key.as_str()))
        .collect();
    assert_eq!(
        places,
        [
            ("results-bucket", format!("prefix/{id}.csv").as_str()),
            (
                "results-bucket",
                format!("prefix/{id}.csv.metadata").as_str()
            ),
            ("other-bucket", format!("{other}.csv").as_str()),
            ("other-bucket", format!("{other}.csv.metadata").as_str()),
        ]
    );
}

#[tokio::test]
async fn dml_と_ctas_は_metadata_だけを置き_ddl_は_0_バイトの_txt_を書く() {
    let harness = Harness::builder(select_response())
        .route("INSERT INTO t VALUES (1)", dml_response())
        .route(
            "UPDATE t SET name = 'x'",
            json!({
                "columns": [{ "name": "rows", "type": "bigint" }],
                "data": [[1]],
                "updateType": "UPDATE",
                "updateCount": 1
            }),
        )
        .route(
            "CREATE TABLE t (i int)",
            json!({ "updateType": "CREATE TABLE" }),
        )
        .route(
            "CREATE TABLE t2 AS SELECT 1",
            json!({
                "columns": [{ "name": "rows", "type": "bigint" }],
                "data": [[1]],
                "updateType": "CREATE TABLE",
                "updateCount": 1
            }),
        )
        .results_s3()
        .default_output_location("s3://results-bucket/athena/")
        .start()
        .await;

    let insert = harness
        .run_query(json!({ "QueryString": "INSERT INTO t VALUES (1)" }))
        .await;
    let create = harness
        .run_query(json!({ "QueryString": "CREATE TABLE t (i int)" }))
        .await;
    let update = harness
        .run_query(json!({ "QueryString": "UPDATE t SET name = 'x'" }))
        .await;
    let ctas = harness
        .run_query(json!({ "QueryString": "CREATE TABLE t2 AS SELECT 1" }))
        .await;

    assert_eq!(insert["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(create["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(ctas["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        output_location(&insert),
        format!("s3://results-bucket/athena/{}", execution_id(&insert))
    );
    assert_eq!(
        output_location(&create),
        format!("s3://results-bucket/athena/{}.txt", execution_id(&create))
    );
    // UPDATE / DELETE / MERGE は名前だけ .csv で、結果は書かない。
    assert_eq!(
        output_location(&update),
        format!("s3://results-bucket/athena/{}.csv", execution_id(&update))
    );
    assert_eq!(
        output_location(&ctas),
        format!("s3://results-bucket/athena/tables/{}", execution_id(&ctas))
    );

    // 列も行も無い DDL（CREATE TABLE t (i int)）だけが 0 バイトの .txt を書く（列が無いので付随ファイルは無し）。
    // DML（INSERT・UPDATE）と CTAS は本体を置かず、付随ファイルだけを 1 件ずつ置く
    // （中身は tests/metadata.rs が見る）。
    let keys: Vec<String> = harness.s3_puts().into_iter().map(|put| put.key).collect();
    assert_eq!(
        keys,
        [
            format!("athena/{}.metadata", execution_id(&insert)),
            format!("athena/{}.txt", execution_id(&create)),
            format!("athena/{}.csv.metadata", execution_id(&update)),
            format!("athena/tables/{}.metadata", execution_id(&ctas)),
        ]
    );
    assert_eq!(
        harness.s3_puts()[1],
        S3Put {
            bucket: "results-bucket".to_string(),
            key: format!("athena/{}.txt", execution_id(&create)),
            body: Vec::new(),
            content_type: Some("binary/octet-stream".to_string()),
            presigned: true,
        }
    );
}

#[tokio::test]
async fn show_の結果を_txt_で書く() {
    let harness = Harness::builder(select_response())
        .route("SHOW TABLES IN db", show_response())
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "SHOW TABLES IN db",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    let id = execution_id(&execution);

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        output_location(&execution),
        format!("s3://results-bucket/athena/{id}.txt")
    );
    // GetQueryResults の行を列名無しでタブ・改行連結したもの（先頭に見出しは無い）。
    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(
        puts[0],
        S3Put {
            bucket: "results-bucket".to_string(),
            key: format!("athena/{id}.txt"),
            body: b"orders\nusers".to_vec(),
            content_type: Some("binary/octet-stream".to_string()),
            presigned: true,
        }
    );
    assert_eq!(puts[1].key, format!("athena/{id}.txt.metadata"));
}

/// SHOW FUNCTIONS の Trino 応答。本物の列（6 列。Deterministic だけ boolean）と、
/// Description が空文字の行（2026-09-23 実測の `approx_distinct` の行）を含める。
fn show_functions_response() -> Value {
    json!({
        "columns": [
            { "name": "Function", "type": "varchar" },
            { "name": "Return Type", "type": "varchar" },
            { "name": "Argument Types", "type": "varchar" },
            { "name": "Function Type", "type": "varchar" },
            { "name": "Deterministic", "type": "boolean" },
            { "name": "Description", "type": "varchar" }
        ],
        "data": [
            ["abs", "bigint", "bigint", "scalar", true, "Absolute value"],
            ["approx_distinct", "bigint", "boolean", "aggregate", true, ""]
        ]
    })
}

/// SHOW FUNCTIONS だけは他の SHOW と違い、本物は `<id>.csv` に見出し行つきの CSV
/// （SELECT と同じ書式。空文字は `""`）を application/octet-stream で置き、`.csv.metadata` の
/// 先頭は SELECT と同じくエンジンのクエリ ID になる（2026-09-23 実測、89,425 バイト・340 バイト。#80）。
#[tokio::test]
async fn show_functions_の結果は_select_と同じ_csv_で書く() {
    let harness = Harness::builder(select_response())
        .route("SHOW FUNCTIONS", show_functions_response())
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "SHOW FUNCTIONS",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    let id = execution_id(&execution);

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        output_location(&execution),
        format!("s3://results-bucket/athena/{id}.csv")
    );
    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(
        puts[0],
        S3Put {
            bucket: "results-bucket".to_string(),
            key: format!("athena/{id}.csv"),
            body: concat!(
                "\"Function\",\"Return Type\",\"Argument Types\",\"Function Type\",\"Deterministic\",\"Description\"\n",
                "\"abs\",\"bigint\",\"bigint\",\"scalar\",\"true\",\"Absolute value\"\n",
                "\"approx_distinct\",\"bigint\",\"boolean\",\"aggregate\",\"true\",\"\"\n",
            )
            .as_bytes()
            .to_vec(),
            content_type: Some("application/octet-stream".to_string()),
            presigned: true,
        }
    );
    assert_eq!(puts[1].key, format!("athena/{id}.csv.metadata"));
    assert_eq!(
        puts[1].content_type.as_deref(),
        Some("application/octet-stream")
    );
    // field 1 はエンジンのクエリ ID（偽 Trino の既定 ID は 27 バイトなので長さ前置は 0x1b）。
    let mut engine_id_field = vec![0x0a, 0x1b];
    engine_id_field.extend_from_slice(TRINO_QUERY_ID.as_bytes());
    assert!(
        puts[1].body.starts_with(&engine_id_field),
        "{:?}",
        puts[1].body
    );
}

/// EXPLAIN（StatementType が DML）の `.txt` は、SHOW / DESCRIBE と違って先頭行に列名
/// `Query Plan` が入り、行数は GetQueryResults の Rows と一致する（2026-09-15／16 の
/// 2 ラウンドの結果ファイルが、列名行込みの全行を `\n` で連結したものとバイト単位で一致。#63）。
/// Trino が 1 行に返す改行入りの全文（末尾 `\n\n`）は、本物と同じく末尾に改行を 1 つ足してから
/// 行に分けるので、ファイルは列名行 + 全文 + `\n` になる（`EXPLAIN SELECT 1` で 393 バイト。#73）。
#[tokio::test]
async fn explain_の結果は_txt_の先頭に列名行を入れて書く() {
    let harness = Harness::builder(select_response())
        .route(
            "EXPLAIN SELECT 1",
            json!({
                "columns": [{ "name": "Query Plan", "type": "varchar(371)", "typeSignature": { "rawType": "varchar", "arguments": [{ "kind": "LONG", "value": 371 }] } }],
                "data": [["Fragment 0 [SINGLE]\n           (1)\n\n"]]
            }),
        )
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "EXPLAIN SELECT 1",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    let id = execution_id(&execution);

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        output_location(&execution),
        format!("s3://results-bucket/athena/{id}.txt")
    );
    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(
        String::from_utf8(puts[0].body.clone()).unwrap(),
        "Query Plan\nFragment 0 [SINGLE]\n           (1)\n\n\n"
    );
    assert_eq!(puts[1].key, format!("athena/{id}.txt.metadata"));
    // `.txt.metadata` の列の Precision（field 7）も本物と同じ varchar(371) の 371（varint f3 02。#68）。
    assert!(
        puts[1].body.windows(3).any(|w| w == [0x38, 0xf3, 0x02]),
        "{:02x?}",
        puts[1].body
    );
}

#[tokio::test]
async fn txt_の書き込みに失敗しても_succeeded_のままになる() {
    let harness = Harness::builder(select_response())
        .route(
            "CREATE TABLE t (i int)",
            json!({ "updateType": "CREATE TABLE" }),
        )
        .results_s3()
        .s3_status(500)
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "CREATE TABLE t (i int)",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert!(
        execution["QueryExecution"]["Status"]
            .get("StateChangeReason")
            .is_none(),
        "{execution}"
    );
    assert_eq!(harness.s3_puts().len(), 1, "書き込みは試みる");

    let (code, results) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": execution_id(&execution) }),
        )
        .await;
    assert_eq!(code, 200, "{results}");
}

#[tokio::test]
async fn 書き込みに失敗すると_failed_になり理由が残る() {
    let harness = Harness::builder(select_response())
        .results_s3()
        .s3_status(500)
        .start()
        .await;

    let execution = harness
        .run_query(select_with_output("s3://results-bucket/athena/"))
        .await;
    let status = &execution["QueryExecution"]["Status"];

    assert_eq!(status["State"], "FAILED");
    let reason = status["StateChangeReason"].as_str().unwrap();
    assert!(
        reason.contains("s3://results-bucket/athena/") && reason.contains("500"),
        "理由: {reason}"
    );
    assert_eq!(
        harness.s3_puts().len(),
        1,
        "再試行せず、.metadata も試みない"
    );
    // 本物には無い失敗なので、エラー一覧の「Failed to write query results to Amazon S3」を当てる。
    assert_eq!(status["AthenaError"]["ErrorCategory"], 1);
    assert_eq!(status["AthenaError"]["ErrorType"], 401);
    assert_eq!(status["AthenaError"]["Retryable"], true);

    let (code, _) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": execution_id(&execution) }),
        )
        .await;
    assert_eq!(code, 400);
}

#[tokio::test]
async fn 書くモードで出力先も既定も無ければ受け付けない() {
    let harness = Harness::builder(select_response())
        .results_s3()
        .start()
        .await;

    let (code, error) = harness
        .call(
            "StartQueryExecution",
            json!({ "QueryString": "SELECT id, name FROM users" }),
        )
        .await;

    assert_eq!(code, 400);
    assert_eq!(error["__type"], "InvalidRequestException");
    assert_eq!(
        error["Message"],
        "No output location provided. You did not provide an output location for  your query results. Either specify an S3 bucket location or enable Athena managed query results in your workgroup settings."
    );
    assert_eq!(error["AthenaErrorCode"], "INVALID_INPUT");
    assert!(harness.trino_requests().is_empty(), "Trino には送らない");
}

#[tokio::test]
async fn s3_の形でない出力先はどちらのモードでも受け付けない() {
    for harness in [
        Harness::start(select_response()).await,
        Harness::builder(select_response())
            .results_s3()
            .start()
            .await,
    ] {
        let (code, error) = harness
            .call(
                "StartQueryExecution",
                select_with_output("https://example.com/x/"),
            )
            .await;

        assert_eq!(code, 400);
        assert_eq!(error["Message"], "outputLocation is not a valid S3 path.");
        assert_eq!(error["AthenaErrorCode"], "INVALID_INPUT");
        assert!(harness.trino_requests().is_empty());
    }
}

#[tokio::test]
async fn 書かないモードでもフルパスは返し_出力先が無ければ項目ごと省く() {
    let harness = Harness::start(select_response()).await;

    let with_output = harness
        .run_query(select_with_output("s3://results-bucket/athena"))
        .await;
    assert_eq!(
        with_output["QueryExecution"]["Status"]["State"],
        "SUCCEEDED"
    );
    assert_eq!(
        output_location(&with_output),
        format!(
            "s3://results-bucket/athena/{}.csv",
            execution_id(&with_output)
        )
    );

    let without = harness
        .run_query(json!({ "QueryString": "SELECT id, name FROM users" }))
        .await;
    assert_eq!(without["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert!(
        without["QueryExecution"]
            .get("ResultConfiguration")
            .is_none()
    );
}

#[tokio::test]
async fn 応答しない_s3_には_put_を諦めて_failed_になる() {
    // 偽 S3 は 5 秒黙るが、PUT は 100ms で諦める。タイムアウトが無いとクエリは RUNNING のまま残る。
    let harness = Harness::builder(select_response())
        .results_s3()
        .s3_delay(Duration::from_secs(5))
        .s3_put_timeout(Duration::from_millis(100))
        .start()
        .await;

    let execution = harness
        .run_query(select_with_output("s3://results-bucket/athena/"))
        .await;
    let status = &execution["QueryExecution"]["Status"];

    assert_eq!(status["State"], "FAILED");
    let reason = status["StateChangeReason"].as_str().unwrap();
    assert!(
        reason.contains("s3://results-bucket/athena/")
            && reason.contains("結果を書き込めませんでした"),
        "理由: {reason}"
    );
    assert_eq!(
        harness.s3_puts().len(),
        1,
        "再試行せず、.metadata も試みない"
    );
}

#[tokio::test]
async fn 先頭のコメントを読み飛ばして_output_location_を決める() {
    // 2026-09-18 実測。先頭のコメントは判定の前に読み飛ばす。
    let harness = Harness::builder(select_response())
        .route(
            "-- c\nCREATE TABLE t2 AS SELECT 1",
            json!({
                "columns": [{ "name": "rows", "type": "bigint" }],
                "updateType": "CREATE TABLE",
                "updateCount": 1
            }),
        )
        .results_s3()
        .start()
        .await;

    let select = harness
        .run_query(json!({
            "QueryString": "-- c\nSELECT id, name FROM users",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(
        output_location(&select),
        format!("s3://results-bucket/athena/{}.csv", execution_id(&select))
    );

    let ctas = harness
        .run_query(json!({
            "QueryString": "-- c\nCREATE TABLE t2 AS SELECT 1",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(
        output_location(&ctas),
        format!("s3://results-bucket/athena/tables/{}", execution_id(&ctas))
    );
}

/// リテラルだけの SELECT は本物が `.csv` も `.metadata` も binary/octet-stream で置く
/// （2026-09-23 実測。`SELECT 1`・`SELECT 1, 2`・`SELECT 'a'`・`SELECT 1.5`・`SELECT 1 AS i`・
/// `SELECT true`・`SELECT 1, 'a'` の 7 形と、初めて流す `SELECT <乱数> AS fresh` の 1 回目から）。
/// 式・CAST・NULL・WHERE・テーブル参照のある SELECT（`SELECT id, name FROM users` など）は
/// application のままで、`select_の結果を_csv_で書き_フルパスを返す` が固定している。
#[tokio::test]
async fn リテラルだけの_select_は_csv_と_metadata_を_binary_で書く() {
    for sql in ["SELECT 1", "SELECT 1 AS i, 'a'"] {
        let harness = Harness::builder(select_response())
            .route(
                sql,
                json!({
                    "columns": [{ "name": "_col0", "type": "integer" }],
                    "data": [[1]]
                }),
            )
            .results_s3()
            .start()
            .await;

        let execution = harness
            .run_query(json!({
                "QueryString": sql,
                "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
            }))
            .await;
        let id = execution_id(&execution);

        assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
        let puts = harness.s3_puts();
        assert_eq!(puts.len(), 2, "{sql}: {puts:?}");
        assert_eq!(puts[0].key, format!("athena/{id}.csv"), "{sql}");
        assert_eq!(
            puts[0].content_type.as_deref(),
            Some("binary/octet-stream"),
            "{sql}"
        );
        assert_eq!(puts[1].key, format!("athena/{id}.csv.metadata"), "{sql}");
        assert_eq!(
            puts[1].content_type.as_deref(),
            Some("binary/octet-stream"),
            "{sql}"
        );
    }
}

/// `.txt` の文のうち DESCRIBE・EXPLAIN・SHOW CREATE TABLE は本物が本体も `.metadata` も
/// application/octet-stream で置く（2026-09-23 実測）。SHOW TABLES など残りの SHOW と
/// 0 バイトの DDL は binary のままで、`show_の結果を_txt_で書く` と
/// `dml_と_ctas_は_metadata_だけを置き_ddl_は_0_バイトの_txt_を書く` が固定している。
#[tokio::test]
async fn describe_と_explain_は_txt_と_metadata_を_application_で書く() {
    for sql in [
        "DESCRIBE users",
        "EXPLAIN SELECT 1",
        "SHOW CREATE TABLE users",
    ] {
        let harness = Harness::builder(select_response())
            .route(sql, show_response())
            .results_s3()
            .start()
            .await;

        let execution = harness
            .run_query(json!({
                "QueryString": sql,
                "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
            }))
            .await;
        let id = execution_id(&execution);

        assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
        let puts = harness.s3_puts();
        assert_eq!(puts.len(), 2, "{sql}: {puts:?}");
        assert_eq!(puts[0].key, format!("athena/{id}.txt"), "{sql}");
        assert_eq!(
            puts[0].content_type.as_deref(),
            Some("application/octet-stream"),
            "{sql}"
        );
        assert_eq!(puts[1].key, format!("athena/{id}.txt.metadata"), "{sql}");
        assert_eq!(
            puts[1].content_type.as_deref(),
            Some("application/octet-stream"),
            "{sql}"
        );
    }
}
