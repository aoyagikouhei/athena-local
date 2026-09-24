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
        "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = '{catalog}'), (SELECT table_type FROM system.jdbc.tables WHERE table_cat = '{catalog}' AND table_schem = '{schema}' AND table_name = '{table}')"
    )
}

/// 対象が存在し、形式が `connector_name` である応答。
fn probe_response(connector_name: &str) -> Value {
    json!({
        "columns": [
            { "name": "_col0", "type": "varchar" },
            { "name": "_col1", "type": "varchar" }
        ],
        "data": [[connector_name, "TABLE"]]
    })
}

/// `.metadata` の field 1 が偽 Trino のクエリ ID（27 バイトなので長さ前置は 1b）で始まる形。
fn engine_id_field() -> String {
    format!("0a1b{}", hex_of(TRINO_QUERY_ID.as_bytes()))
}

/// 本物が SHOW CREATE TABLE / VIEW に返す固定の列（Precision 0、CaseSensitive false。2026-09-23／24 実測）。
fn fixed_column(name: &str, type_name: &str) -> Value {
    json!({
        "CatalogName": "hive", "SchemaName": "", "TableName": "",
        "Name": name, "Label": name, "Type": type_name,
        "Precision": 0, "Scale": 0, "Nullable": "UNKNOWN", "CaseSensitive": false
    })
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
    // 列は Trino の `Create View`／varchar ではなく本物の `create view`／varchar（Precision 0、
    // CaseSensitive false。2026-09-24 実測。#161）。
    let (_, results) = harness
        .call("GetQueryResults", json!({ "QueryExecutionId": id }))
        .await;
    assert_eq!(
        results["ResultSet"]["ResultSetMetadata"]["ColumnInfo"],
        json!([fixed_column("create view", "varchar")]),
        "{results}"
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
    // Iceberg のテーブルへの SHOW CREATE TABLE は本物が UpdateCount 0 を返す（2026-09-24 実測。#160）。
    let (_, results) = harness
        .call("GetQueryResults", json!({ "QueryExecutionId": id }))
        .await;
    assert_eq!(results["UpdateCount"], 0);
    // 列は Iceberg でも Hive と同じ `createtab_stmt`／string（2026-09-24 実測。#161）。
    assert_eq!(
        results["ResultSet"]["ResultSetMetadata"]["ColumnInfo"],
        json!([fixed_column("createtab_stmt", "string")]),
        "{results}"
    );
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
    // Hive のテーブルへの SHOW CREATE TABLE は本物が UpdateCount を返さない（null。2026-09-24 実測。#160）。
    let (_, results) = harness
        .call("GetQueryResults", json!({ "QueryExecutionId": id }))
        .await;
    assert!(
        results.get("UpdateCount").is_none(),
        "UpdateCount は省く: {results}"
    );
    // 列は Trino の `Create Table`／varchar ではなく本物の `createtab_stmt`／string（2026-09-23 実測。#161）。
    assert_eq!(
        results["ResultSet"]["ResultSetMetadata"]["ColumnInfo"],
        json!([fixed_column("createtab_stmt", "string")]),
        "{results}"
    );
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
    // 本物の 88 バイトと同じ列（`createtab_stmt`／string は 7／8／10 を出さない）。
    // 採取元: ~/athena-content-type-measurements/run-20260923-043027/c10-show-create-table.metadata.bytes
    // （2026-09-23 実測。#161）。先頭の QueryExecutionId だけが実行ごとに変わる。
    assert_eq!(
        hex_of(&puts[1].body),
        format!(
            "0a24{}22300a0468697665220e6372656174657461625f73746d742a0e6372656174657461625f73746d743206737472696e674803",
            hex_of(id.as_bytes())
        )
    );
}

/// UpdateCount が形式の問い合わせの結果を使うようになったので、結果ファイルを書かない
/// `ATHENA_LOCAL_RESULTS=none` でも SHOW CREATE TABLE は形式を問い合わせる（#160。#39 の
/// 「S3 が無効なら問い合わせない」は DROP TABLE / ALTER TABLE にだけ残る）。
#[tokio::test]
async fn 結果_s3_が無効でも_show_create_table_は形式を問い合わせ_iceberg_なら_update_count_が_0() {
    let harness = Harness::builder(select_response())
        .route(
            &probe_sql("default_catalog", "default_schema", "t"),
            probe_response("iceberg"),
        )
        .route("SHOW CREATE TABLE t", show_create_table_response())
        .start()
        .await;
    let execution = harness
        .run_query(json!({ "QueryString": "SHOW CREATE TABLE t" }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        harness.trino_sqls(),
        [
            probe_sql("default_catalog", "default_schema", "t"),
            "SHOW CREATE TABLE t".to_string()
        ]
    );

    let (_, results) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": execution_id(&execution) }),
        )
        .await;
    assert_eq!(results["UpdateCount"], 0);
    assert!(harness.s3_puts().is_empty());
}
