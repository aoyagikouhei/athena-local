//! コメント無しの ALTER TABLE の DROP COLUMN・RENAME TO を、本物の Athena と同じく開始後の FAILED にする（#256）。
//! 本物は Hive 表と無い表でこの 2 つを実行時に失敗させ、Iceberg 表では成功させる（2026-09-20・09-21・09-25 実測。
//! #39 d1・#43 b1・#204 alt-rename-u・#217 n22）。ビューは測っていないので今までどおり Trino に送る。
//! ブロックコメントの入った形は tests/comment_parse_error.rs（#244）。

mod common;

use common::Harness;
use serde_json::{Value, json};

const DEFAULT_CATALOG: &str = "default_catalog";
const DEFAULT_SCHEMA: &str = "default_schema";
const DDL_ENGINE: &str = "Query type not supported by DDL engine.";

fn select_response() -> Value {
    json!({ "columns": [{ "name": "n", "type": "bigint" }], "data": [[1]] })
}

/// 形式と存在を 1 つにまとめた問い合わせ（`src/operation/table_format.rs` の `probe_sql` と同じ形。
/// tests/comment_parse_error.rs の写し）。
fn probe_sql(catalog: &str, schema: &str, table: &str) -> String {
    format!(
        "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = '{catalog}'), (SELECT table_type FROM system.jdbc.tables WHERE table_cat = '{catalog}' AND table_schem = '{schema}' AND table_name = '{table}')"
    )
}

fn probe_response(connector_name: &str, table_type: &str) -> Value {
    json!({
        "columns": [
            { "name": "_col0", "type": "varchar" },
            { "name": "_col1", "type": "varchar" }
        ],
        "data": [[connector_name, table_type]]
    })
}

/// 対象が存在しない（カタログはあるが `table_type` が null）応答（tests/comment_parse_error.rs の写し）。
fn probe_response_missing() -> Value {
    json!({
        "columns": [
            { "name": "_col0", "type": "varchar" },
            { "name": "_col1", "type": "varchar" }
        ],
        "data": [["hive", null]]
    })
}

/// `sql` を結果の置き場つきで流し、FAILED の中身を確かめて StateChangeReason を返す。`.txt` に理由だけを置き、
/// `.metadata` は置かず（#39 d1・#43 b1 の ls）、Trino に ALTER の文を送らないことも確かめる。
async fn assert_failed(sql: &str, table: &str, response: Value, error_message: &str) -> String {
    let harness = Harness::builder(select_response())
        .route(&probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, table), response)
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": sql,
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await["QueryExecution"]
        .clone();
    let id = execution["QueryExecutionId"].as_str().expect("ID");

    assert_eq!(execution["Status"]["State"], "FAILED", "{sql}: {execution}");
    assert_eq!(execution["Query"], sql, "{sql}");
    assert_eq!(execution["StatementType"], "DDL", "{sql}");
    let error = &execution["Status"]["AthenaError"];
    assert_eq!(error["ErrorCategory"], 2, "{sql}");
    assert_eq!(error["ErrorType"], 1006, "{sql}");
    assert_eq!(error["Retryable"], false, "{sql}");
    assert_eq!(error["ErrorMessage"], error_message, "{sql}");
    let reason = execution["Status"]["StateChangeReason"]
        .as_str()
        .expect("StateChangeReason")
        .to_string();

    let puts: Vec<_> = harness
        .s3_puts()
        .into_iter()
        .filter(|put| put.key.contains(id))
        .collect();
    assert_eq!(puts.len(), 1, "{sql}: .txt だけ置き .metadata は置かない");
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(puts[0].body, reason.as_bytes(), "{sql}");

    assert!(
        harness.trino_sqls().iter().all(|s| !s.starts_with("ALTER")),
        "{sql}: Trino に ALTER の文を送らない: {:?}",
        harness.trino_sqls()
    );
    reason
}

#[tokio::test]
async fn drop_column_は_hive_表と無い表で本物どおり_parse_exception_の_failed_になる() {
    for (name, response) in [
        ("t", probe_response("hive", "TABLE")),
        ("nope", probe_response_missing()),
    ] {
        // `COLUMN` の 0 始まりの位置が StateChangeReason、+ 1 が ErrorMessage（#39 d1 の 58・59）。
        let sql = format!("ALTER TABLE {name} DROP COLUMN n");
        let column = sql.find("COLUMN").expect("COLUMN");
        let reason = assert_failed(
            &sql,
            name,
            response,
            &format!(
                "line 1:{}: mismatched input 'COLUMN' expecting 'PARTITION'",
                column + 1
            ),
        )
        .await;
        assert_eq!(
            reason,
            format!(
                "FAILED: ParseException line 1:{column} mismatched input 'COLUMN' expecting PARTITION near 'DROP' in drop partition statement"
            )
        );
    }
}

#[tokio::test]
async fn rename_to_は_hive_表なら_glue_の_table_cannot_be_renamed_で_failed_になる() {
    let reason = assert_failed(
        "ALTER TABLE t RENAME TO u",
        "t",
        probe_response("hive", "TABLE"),
        DDL_ENGINE,
    )
    .await;
    // Request ID は本物では毎回違う UUID（#43 b1・#217 n22）。
    let prefix = "FAILED: Execution Error, return code 1 from org.apache.hadoop.hive.ql.exec.DDLTask. Unable to alter table. Unable to change partition or table: com.amazonaws.services.datacatalog.model.InvalidInputException: Table cannot be renamed (Service: AmazonDataCatalog; Status Code: 400; Error Code: InvalidInputException; Request ID: ";
    let request_id = reason
        .strip_prefix(prefix)
        .and_then(|rest| rest.strip_suffix("; Proxy: null)"))
        .unwrap_or_else(|| panic!("文言の形が違う: {reason}"));
    assert!(
        uuid::Uuid::parse_str(request_id).is_ok_and(|id| id.hyphenated().to_string() == request_id),
        "Request ID が UUID の形でない: {request_id}"
    );
}

#[tokio::test]
async fn rename_to_は無い表なら_table_not_found_で_failed_になる() {
    let reason = assert_failed(
        "ALTER TABLE nope RENAME TO u",
        "nope",
        probe_response_missing(),
        DDL_ENGINE,
    )
    .await;
    assert_eq!(
        reason,
        format!("FAILED: SemanticException [Error 10001]: Table not found {DEFAULT_SCHEMA}.nope")
    );
}

#[tokio::test]
async fn iceberg_表とビューと_hive_でも_iceberg_でもないコネクタの表は今までどおり_trino_に送る() {
    // Iceberg 表は本物も成功する（#39・#43・#244 a17）。ビューはコメント無しの形を測っていない。
    for (sql, response) in [
        (
            "ALTER TABLE t DROP COLUMN n",
            probe_response("iceberg", "TABLE"),
        ),
        (
            "ALTER TABLE t RENAME TO u",
            probe_response("iceberg", "TABLE"),
        ),
        (
            "ALTER TABLE t DROP COLUMN n",
            probe_response("hive", "VIEW"),
        ),
        ("ALTER TABLE t RENAME TO u", probe_response("hive", "VIEW")),
        // hive でも iceberg でもないコネクタの表は形式を判定しない（decisions.md の #39。#264）。
        (
            "ALTER TABLE t DROP COLUMN n",
            probe_response("memory", "TABLE"),
        ),
        (
            "ALTER TABLE t RENAME TO u",
            probe_response("memory", "TABLE"),
        ),
    ] {
        let harness = Harness::builder(select_response())
            .route(&probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, "t"), response)
            .start()
            .await;

        let execution =
            harness.run_query(json!({ "QueryString": sql })).await["QueryExecution"].clone();

        assert_eq!(
            execution["Status"]["State"], "SUCCEEDED",
            "{sql}: {execution}"
        );
        assert!(
            harness.trino_sqls().iter().any(|s| s == sql),
            "{sql}: Trino に送る: {:?}",
            harness.trino_sqls()
        );
    }
}

#[tokio::test]
async fn 名前の後ろにコメントがある形は測っていないので今までどおり_trino_に送る() {
    for sql in [
        "ALTER TABLE t /* c */ DROP COLUMN n",
        "ALTER TABLE t DROP COLUMN n -- c",
        "ALTER TABLE t RENAME /* c */ TO u",
    ] {
        let harness = Harness::builder(select_response())
            .route(
                &probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, "t"),
                probe_response("hive", "TABLE"),
            )
            .start()
            .await;

        let execution =
            harness.run_query(json!({ "QueryString": sql })).await["QueryExecution"].clone();

        assert_eq!(
            execution["Status"]["State"], "SUCCEEDED",
            "{sql}: {execution}"
        );
        assert!(
            harness.trino_sqls().iter().any(|s| s == sql),
            "{sql}: Trino に送る: {:?}",
            harness.trino_sqls()
        );
    }
}
