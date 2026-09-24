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

/// Trino の `SHOW CREATE TABLE` の応答（列名は `Create Table`）。
fn show_create_table_response() -> Value {
    json!({
        "columns": [{ "name": "Create Table", "type": "varchar" }],
        "data": [["CREATE TABLE db.t (\n   n integer\n)"]]
    })
}

/// 形式と存在を 1 つにまとめた問い合わせ（`src/operation/table_format.rs` の `probe_sql` と同じ形。
/// tests/table_format.rs の写し。ずれればルートに当たらず Iceberg のテストが落ちる）。
fn probe_sql(catalog: &str, schema: &str, table: &str) -> String {
    format!(
        "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = '{catalog}'), (SELECT count(*) FROM system.jdbc.tables WHERE table_cat = '{catalog}' AND table_schem = '{schema}' AND table_name = '{table}')"
    )
}

/// 対象が存在し、形式が `connector_name` である応答。
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

/// `SHOW CREATE TABLE t` を、形式の問い合わせが `connector_name` を返す偽 Trino で実行する。
async fn run_show_create_table(connector_name: &str) -> (Harness, Value) {
    let harness = Harness::builder(select_response())
        .route(
            &probe_sql("default_catalog", "default_schema", "t"),
            probe_response(connector_name),
        )
        .route("SHOW CREATE TABLE t", show_create_table_response())
        .results_s3()
        .start()
        .await;
    let execution = harness
        .run_query(json!({
            "QueryString": "SHOW CREATE TABLE t",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    (harness, execution)
}

#[tokio::test]
async fn show_create_table_は_iceberg_なら本体も_metadata_も_binary_で先頭がエンジン_id() {
    let (harness, execution) = run_show_create_table("iceberg").await;
    let id = execution_id(&execution);
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        execution["QueryExecution"]["SubstatementType"],
        "SHOW_CREATE_TABLE"
    );
    // 形式の問い合わせを本体より先に送る。
    assert_eq!(
        harness.trino_sqls(),
        [
            probe_sql("default_catalog", "default_schema", "t"),
            "SHOW CREATE TABLE t".to_string()
        ]
    );

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    // 2026-09-24 実測: Iceberg のテーブルでは本体も `.metadata` も binary/octet-stream。
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(puts[0].content_type.as_deref(), Some("binary/octet-stream"));
    // 本体は Trino の DDL 文のまま（DROP TABLE × Iceberg の改行 1 つにはならない）。
    assert!(
        puts[0].body.starts_with(b"CREATE TABLE db.t ("),
        "{:?}",
        String::from_utf8_lossy(&puts[0].body)
    );
    assert_eq!(puts[1].key, format!("athena/{id}.txt.metadata"));
    assert_eq!(puts[1].content_type.as_deref(), Some("binary/octet-stream"));
    // 本物の `.metadata` は不透明で先頭 ID は観測できないので、`SHOW CREATE VIEW` と同じくエンジン ID。
    assert!(
        hex_of(&puts[1].body).starts_with(&engine_id_field()),
        "{}",
        hex_of(&puts[1].body)
    );
}

#[tokio::test]
async fn show_create_table_は_hive_なら今までどおり_application_で先頭が実行_id() {
    let (harness, execution) = run_show_create_table("hive").await;
    let id = execution_id(&execution);
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        harness.trino_sqls(),
        [
            probe_sql("default_catalog", "default_schema", "t"),
            "SHOW CREATE TABLE t".to_string()
        ]
    );

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    // 2026-09-24 実測: Hive のテーブルでは本体も `.metadata` も application/octet-stream、
    // `.metadata` は素の protobuf で先頭は QueryExecutionId（36 バイトなので長さ前置は 24）。
    assert_eq!(
        puts[0].content_type.as_deref(),
        Some("application/octet-stream")
    );
    assert!(puts[0].body.starts_with(b"CREATE TABLE db.t ("));
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
