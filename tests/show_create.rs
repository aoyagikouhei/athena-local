//! `SHOW CREATE VIEW` と `SHOW CREATE TABLE` の結果ファイル（本体と `.metadata`）と分類（issue #151）。
//! 本物は `SHOW CREATE VIEW` と Iceberg のテーブルへの `SHOW CREATE TABLE` を binary/octet-stream で置き、
//! `.metadata` は不透明な形式（2026-09-24 実測）。Hive のテーブルへの `SHOW CREATE TABLE` だけが
//! application/octet-stream で、`.metadata` は素の protobuf（先頭は QueryExecutionId）。
//! Content-Type と `.metadata` の先頭のクエリ ID と `SubstatementType` を 1 本で見るのでここに置く
//! （バイト単位の固定は tests/metadata.rs、DROP / ALTER × 形式は tests/table_format.rs）。

mod common;

use common::{Harness, TRINO_QUERY_ID, execution_id};
use serde_json::{Value, json};

fn select_response() -> Value {
    json!({
        "columns": [{ "name": "n", "type": "integer" }],
        "data": [[1]]
    })
}

/// Trino の `SHOW CREATE VIEW` の応答（列名は `Create View`）。
fn show_create_view_response() -> Value {
    json!({
        "columns": [{ "name": "Create View", "type": "varchar" }],
        "data": [["CREATE VIEW db.v AS\nSELECT 1 n"]]
    })
}

fn hex_of(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// `.metadata` の field 1 が偽 Trino のクエリ ID（27 バイトなので長さ前置は 1b）で始まる形。
fn engine_id_field() -> String {
    format!("0a1b{}", hex_of(TRINO_QUERY_ID.as_bytes()))
}

#[tokio::test]
async fn show_create_view_は本体も_metadata_も_binary_で先頭がエンジン_id() {
    let harness = Harness::builder(select_response())
        .route("SHOW CREATE VIEW v", show_create_view_response())
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "SHOW CREATE VIEW v",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    let id = execution_id(&execution);
    // 2026-09-24 実測: UTILITY / SHOW_CREATE_VIEW。
    assert_eq!(execution["QueryExecution"]["StatementType"], "UTILITY");
    assert_eq!(
        execution["QueryExecution"]["SubstatementType"],
        "SHOW_CREATE_VIEW"
    );

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(puts[0].content_type.as_deref(), Some("binary/octet-stream"));
    assert!(
        puts[0].body.starts_with(b"CREATE VIEW db.v AS"),
        "{:?}",
        String::from_utf8_lossy(&puts[0].body)
    );
    assert_eq!(puts[1].key, format!("athena/{id}.txt.metadata"));
    assert_eq!(puts[1].content_type.as_deref(), Some("binary/octet-stream"));
    // 本物の `.metadata` は不透明で先頭 ID は観測できないので、`SHOW TABLES` や EXPLAIN と同じく
    // エンジン ID を置く（docs/result-files.md の既存方針）。
    assert!(
        hex_of(&puts[1].body).starts_with(&engine_id_field()),
        "{}",
        hex_of(&puts[1].body)
    );
}
