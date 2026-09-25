//! QueryExecutionContext の Catalog が Trino に実在しないとき、本物はメタデータの文（DESCRIBE・SHOW COLUMNS・
//! SHOW TABLES・SHOW DATABASES・SHOW CREATE TABLE・DROP TABLE）と DDL・ビューの文だけ既定のカタログで解決して
//! 成功させ、表を読む SELECT などは CATALOG_NOT_FOUND で失敗させた（2026-09-25／26 実測。#212 Y3・#214・#217）。
//! athena-local はそれらの文のときだけカタログの有無を Trino に問い合わせ、無ければ `TRINO_CATALOG_MAP` の
//! `AwsDataCatalog` の別名（無ければ `TRINO_CATALOG`）に差し替えて送る。

mod common;

use common::{Harness, TrinoRequest, trino_error};
use serde_json::{Value, json};

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

/// カタログの有無の問い合わせ（`src/operation/table_format.rs` の `catalog_exists_sql` と同じ形。
/// ずれればルートに当たらずテストが落ちる）。
fn catalog_exists_sql(catalog: &str) -> String {
    format!(
        "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = '{catalog}')"
    )
}

fn catalog_exists_response(connector_name: Option<&str>) -> Value {
    json!({
        "columns": [{ "name": "_col0", "type": "varchar" }],
        "data": [[connector_name]]
    })
}

/// 形式と存在の問い合わせ（tests/entity_check.rs の写し）。
fn probe_sql(catalog: &str, schema: &str, table: &str) -> String {
    format!(
        "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = '{catalog}'), (SELECT table_type FROM system.jdbc.tables WHERE table_cat = '{catalog}' AND table_schem = '{schema}' AND table_name = '{table}')"
    )
}

fn probe_response(connector_name: Option<&str>, table_type: Option<&str>) -> Value {
    json!({
        "columns": [
            { "name": "_col0", "type": "varchar" },
            { "name": "_col1", "type": "varchar" }
        ],
        "data": [[connector_name, table_type]]
    })
}

fn request(query: &str, catalog: &str) -> Value {
    json!({
        "QueryString": query,
        "QueryExecutionContext": { "Catalog": catalog, "Database": "db" }
    })
}

/// 受け取った SQL（本体）を Trino に送ったときのカタログ。
fn body_catalogs(requests: &[TrinoRequest], query: &str) -> Vec<Option<String>> {
    requests
        .iter()
        .filter(|request| request.sql == query)
        .map(|request| request.catalog.clone())
        .collect()
}

#[tokio::test]
async fn 実在しないカタログのメタデータの文は_awsdatacatalog_の別名で送り_実行情報には受け取った名前を返す()
 {
    let harness = Harness::builder(describe_response())
        .catalog_map(&[("AwsDataCatalog", "hive")])
        // 大文字混じりの名前も小文字で問い合わせる（Trino はカタログを小文字で持つ）。
        .route(
            &catalog_exists_sql("nosuchcat"),
            catalog_exists_response(None),
        )
        .route(
            &probe_sql("hive", "db", "t"),
            probe_response(Some("hive"), Some("TABLE")),
        )
        .start()
        .await;

    for query in [
        "DESCRIBE t",
        "SHOW COLUMNS FROM t",
        "SHOW TABLES",
        "SHOW SCHEMAS",
        "SHOW CREATE TABLE t",
        "DROP TABLE IF EXISTS t",
    ] {
        let execution = harness.run_query(request(query, "NoSuchCat")).await;
        assert_eq!(
            execution["QueryExecution"]["QueryExecutionContext"]["Catalog"], "nosuchcat",
            "{query}"
        );
        assert_eq!(
            body_catalogs(&harness.trino_requests(), query),
            [Some("hive".to_string())],
            "{query}"
        );
    }
}

/// #217 の実測（2026-09-26）: 本物は実在しない Context のカタログでも CTAS でない CREATE TABLE・ALTER TABLE ADD COLUMNS・
/// CREATE VIEW・SHOW CREATE VIEW・DROP VIEW・CREATE/DROP DATABASE（SCHEMA）を既定のカタログで成功させ、INSERT は
/// 1300、DELETE・UPDATE・MERGE は 1301 で失敗させた。Trino の構文で書ける形だけ確かめる。
#[tokio::test]
async fn 実在しないカタログの_ddl_とビューの文は差し替え_insert_と_delete_は差し替えない() {
    let harness = Harness::builder(describe_response())
        .catalog_map(&[("AwsDataCatalog", "hive")])
        .route(
            &catalog_exists_sql("nosuchcat"),
            catalog_exists_response(None),
        )
        .start()
        .await;

    for (query, sent) in [
        ("CREATE TABLE c (n integer)", "hive"),
        ("ALTER TABLE t ADD COLUMNS (c varchar)", "hive"),
        ("CREATE VIEW v AS SELECT n FROM t", "hive"),
        ("SHOW CREATE VIEW v", "hive"),
        ("DROP VIEW IF EXISTS v", "hive"),
        ("CREATE SCHEMA IF NOT EXISTS s", "hive"),
        ("DROP SCHEMA IF EXISTS s", "hive"),
        ("INSERT INTO t SELECT 1", "nosuchcat"),
        ("DELETE FROM t WHERE n = 1", "nosuchcat"),
    ] {
        harness.run_query(request(query, "nosuchcat")).await;
        assert_eq!(
            body_catalogs(&harness.trino_requests(), query),
            [Some(sent.to_string())],
            "{query}"
        );
    }
}

#[tokio::test]
async fn 別名が無ければ_trino_catalog_の既定で送る() {
    let harness = Harness::builder(describe_response())
        .route(
            &catalog_exists_sql("nosuchcat"),
            catalog_exists_response(None),
        )
        .start()
        .await;

    harness.run_query(request("SHOW TABLES", "nosuchcat")).await;

    assert_eq!(
        body_catalogs(&harness.trino_requests(), "SHOW TABLES"),
        [Some("default_catalog".to_string())]
    );
}

#[tokio::test]
async fn 実在するカタログと問い合わせが失敗したとき_応答の形が違うときはそのまま送る() {
    let harness = Harness::builder(describe_response())
        .catalog_map(&[("AwsDataCatalog", "hive")])
        .route(
            &catalog_exists_sql("iceberg"),
            catalog_exists_response(Some("iceberg")),
        )
        .route(
            &catalog_exists_sql("broken"),
            trino_error("PERMISSION_DENIED", "Access Denied"),
        )
        .route(&catalog_exists_sql("odd"), describe_response())
        .start()
        .await;

    harness.run_query(request("SHOW TABLES", "iceberg")).await;
    harness.run_query(request("SHOW SCHEMAS", "broken")).await;
    harness
        .run_query(request("SHOW CREATE TABLE t", "odd"))
        .await;

    let requests = harness.trino_requests();
    assert_eq!(
        body_catalogs(&requests, "SHOW TABLES"),
        [Some("iceberg".to_string())]
    );
    assert_eq!(
        body_catalogs(&requests, "SHOW SCHEMAS"),
        [Some("broken".to_string())]
    );
    assert_eq!(
        body_catalogs(&requests, "SHOW CREATE TABLE t"),
        [Some("odd".to_string())]
    );
}

/// 本物は表を読む SELECT を CATALOG_NOT_FOUND で失敗させた（2026-09-25 実測）。差し替えず、問い合わせもしない。
#[tokio::test]
async fn select_は実在しないカタログでも差し替えず問い合わせない() {
    let harness = Harness::builder(describe_response())
        .catalog_map(&[("AwsDataCatalog", "hive")])
        .route(
            &catalog_exists_sql("nosuchcat"),
            catalog_exists_response(None),
        )
        .start()
        .await;

    harness
        .run_query(request("SELECT * FROM t", "nosuchcat"))
        .await;

    let requests = harness.trino_requests();
    assert_eq!(
        requests.iter().map(|r| r.sql.as_str()).collect::<Vec<_>>(),
        ["SELECT * FROM t"]
    );
    assert_eq!(requests[0].catalog.as_deref(), Some("nosuchcat"));
}

#[tokio::test]
async fn 別名そのものと省略したカタログは問い合わせない() {
    let harness = Harness::builder(describe_response())
        .catalog_map(&[("AwsDataCatalog", "hive")])
        .start()
        .await;

    harness
        .run_query(request("SHOW TABLES", "AwsDataCatalog"))
        .await;
    harness
        .run_query(json!({ "QueryString": "SHOW SCHEMAS" }))
        .await;

    assert_eq!(harness.trino_sqls(), ["SHOW TABLES", "SHOW SCHEMAS"]);
}

/// 本物は実在しない Context のカタログでも、実在しない表の DESCRIBE を既定のカタログで確かめて開始時に弾いた
/// （2026-09-25 実測 #212 Y3）。
#[tokio::test]
async fn 実在しないカタログでも実在しない表の_describe_は開始時に_entity_not_found_で弾く() {
    let harness = Harness::builder(describe_response())
        .catalog_map(&[("AwsDataCatalog", "hive")])
        .route(
            &catalog_exists_sql("nosuchcat"),
            catalog_exists_response(None),
        )
        .route(
            &probe_sql("hive", "db", "nope"),
            probe_response(Some("hive"), None),
        )
        .start()
        .await;

    let (code, error) = harness
        .call("StartQueryExecution", request("DESCRIBE nope", "nosuchcat"))
        .await;

    assert_eq!(code, 400, "{error}");
    assert_eq!(error["AthenaErrorCode"], "INVALID_INPUT");
    assert!(
        error["Message"]
            .as_str()
            .is_some_and(|message| message.starts_with("Entity Not Found (")),
        "{error}"
    );
}
