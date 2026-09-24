//! `DESCRIBE` の結果ファイルと `UpdateCount` は対象テーブルの形式で割れる（issue #160）。
//! 本物は Hive のテーブルへの `DESCRIBE` を application/octet-stream・素の protobuf（先頭は
//! QueryExecutionId）・`UpdateCount` 無しで置き、Iceberg のテーブルへの `DESCRIBE` は
//! binary/octet-stream・不透明な形式・`UpdateCount` 0（2026-09-24 実測。`SHOW CREATE TABLE` と同じ割れ方）。

mod common;

use common::{Harness, TRINO_QUERY_ID, execution_id};
use serde_json::{Value, json};

fn hex_of(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Trino の `DESCRIBE` の応答。
fn describe_response() -> Value {
    json!({
        "columns": [
            { "name": "Column", "type": "varchar" },
            { "name": "Type", "type": "varchar" },
            { "name": "Extra", "type": "varchar" },
            { "name": "Comment", "type": "varchar" }
        ],
        "data": [["n", "integer", "", ""]]
    })
}

/// 形式と存在を 1 つにまとめた問い合わせ（`src/operation/table_format.rs` の `probe_sql` と同じ形。
/// tests/table_format.rs の写し。ずれればルートに当たらず Iceberg のテストが落ちる）。
fn probe_sql(catalog: &str, schema: &str, table: &str) -> String {
    format!(
        "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = '{catalog}'), (SELECT count(*) FROM system.jdbc.tables WHERE table_cat = '{catalog}' AND table_schem = '{schema}' AND table_name = '{table}')"
    )
}

fn probe_response(connector_name: &str) -> Value {
    json!({
        "columns": [
            { "name": "_col0", "type": "varchar" },
            { "name": "_col1", "type": "bigint" }
        ],
        "data": [[connector_name, 1]]
    })
}

/// `.metadata` の field 1 が偽 Trino のクエリ ID（27 バイトなので長さ前置は 1b）で始まる形。
fn engine_id_field() -> String {
    format!("0a1b{}", hex_of(TRINO_QUERY_ID.as_bytes()))
}

/// `DESCRIBE t` を、形式の問い合わせが `connector_name` を返す偽 Trino で実行する。
async fn run_describe(connector_name: &str, s3: bool) -> (Harness, Value) {
    let mut builder = Harness::builder(describe_response())
        .route(
            &probe_sql("default_catalog", "default_schema", "t"),
            probe_response(connector_name),
        )
        .route("DESCRIBE t", describe_response());
    if s3 {
        builder = builder.results_s3();
    }
    let harness = builder.start().await;
    let execution = harness
        .run_query(json!({
            "QueryString": "DESCRIBE t",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        harness.trino_sqls(),
        [
            probe_sql("default_catalog", "default_schema", "t"),
            "DESCRIBE t".to_string()
        ]
    );
    (harness, execution)
}

async fn update_count_of(harness: &Harness, execution: &Value) -> Value {
    let (status, results) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": execution_id(execution) }),
        )
        .await;
    assert_eq!(status, 200, "{results}");
    results.get("UpdateCount").cloned().unwrap_or(Value::Null)
}

#[tokio::test]
async fn describe_は_iceberg_なら_update_count_0_で本体も_metadata_も_binary_で先頭がエンジン_id() {
    let (harness, execution) = run_describe("iceberg", true).await;
    let id = execution_id(&execution);
    assert_eq!(update_count_of(&harness, &execution).await, 0);

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(puts[0].content_type.as_deref(), Some("binary/octet-stream"));
    assert_eq!(puts[1].key, format!("athena/{id}.txt.metadata"));
    assert_eq!(puts[1].content_type.as_deref(), Some("binary/octet-stream"));
    assert!(
        hex_of(&puts[1].body).starts_with(&engine_id_field()),
        "{}",
        hex_of(&puts[1].body)
    );
}

#[tokio::test]
async fn describe_は_hive_なら今までどおり_update_count_無しで_application_で先頭が実行_id() {
    let (harness, execution) = run_describe("hive", true).await;
    let id = execution_id(&execution);
    assert_eq!(update_count_of(&harness, &execution).await, Value::Null);

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(
        puts[0].content_type.as_deref(),
        Some("application/octet-stream")
    );
    assert_eq!(
        puts[1].content_type.as_deref(),
        Some("application/octet-stream")
    );
    assert!(
        hex_of(&puts[1].body).starts_with(&format!("0a24{}", hex_of(id.as_bytes()))),
        "{}",
        hex_of(&puts[1].body)
    );
}

/// UpdateCount が判定を使うので、結果ファイルを書かない none でも DESCRIBE は形式を問い合わせる。
#[tokio::test]
async fn 結果_s3_が無効でも_describe_は形式を問い合わせ_iceberg_なら_update_count_が_0() {
    let (harness, execution) = run_describe("iceberg", false).await;
    assert_eq!(update_count_of(&harness, &execution).await, 0);
    assert!(harness.s3_puts().is_empty());
}
