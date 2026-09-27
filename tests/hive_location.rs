//! S3 Tables でない Context の LOCATION 付きの Hive の `CREATE TABLE`。本物は Hive の文法で読めた文を開始時に弾いた
//! （2026-09-27 実測 ROUND=21 の r1〜r49、#266 の x・z 群。#278）。
//!
//! - EXTERNAL の無い形は、TBLPROPERTIES の `table_type` が ICEBERG（綴りによらない）でなければ Context によらず
//!   `External keyword required for table type HIVE`。
//! - EXTERNAL の形と、`table_type` が ICEBERG の EXTERNAL の無い形の 3 部の名前は、Context の Catalog が AwsDataCatalog なら
//!   1 部目が `awsdatacatalog` の類でない実在するカタログのとき、Context が実在する別のカタログなら（EXTERNAL の形で）
//!   1 部目がちょうど小文字の `awsdatacatalog` のとき `Unsupported ddl with 2 catalogs: <文>`。
//!
//! どれも Trino の文法に無いので構文チェックも送らない。弾かない形（本物は成功する形・引用符付きの名前・NOT NULL）は
//! 今までどおり構文チェックに回る。

mod common;

use common::Harness;
use serde_json::{Value, json};

const EXTERNAL_REQUIRED: &str = "External keyword required for table type HIVE";

/// カタログの有無の問い合わせ（`src/operation/table_format.rs` の `catalog_exists_sql` と同じ形）。
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

fn select_response() -> Value {
    json!({ "columns": [{ "name": "_col0", "type": "integer" }], "data": [[1]] })
}

/// `glue278` は Trino にあるカタログ、`nosuch278` は無いカタログ、`glue_alias` は `TRINO_CATALOG_MAP` の別名。
async fn harness() -> Harness {
    Harness::builder(select_response())
        .catalog_map(&[("glue_alias", "glue278")])
        .route(
            &catalog_exists_sql("glue278"),
            catalog_exists_response(Some("hive")),
        )
        .route(
            &catalog_exists_sql("nosuch278"),
            catalog_exists_response(None),
        )
        .start()
        .await
}

async fn start(harness: &Harness, query: &str, catalog: Option<&str>) -> (u16, Value) {
    let mut context = json!({ "Database": "db" });
    if let Some(catalog) = catalog {
        context["Catalog"] = json!(catalog);
    }
    harness
        .call(
            "StartQueryExecution",
            json!({ "QueryString": query, "QueryExecutionContext": context }),
        )
        .await
}

async fn assert_rejected(harness: &Harness, query: &str, catalog: Option<&str>, message: &str) {
    let (code, error) = start(harness, query, catalog).await;
    assert_eq!(code, 400, "{query}: {error}");
    assert_eq!(error["__type"], "InvalidRequestException", "{query}");
    assert_eq!(error["AthenaErrorCode"], "MALFORMED_QUERY", "{query}");
    assert_eq!(error["Message"], message, "{query}");
}

/// EXTERNAL の無い LOCATION は、名前の部の数・句・Context によらず External（2026-09-27 実測 r2・r28・r30〜r37・r39・r40・r46、
/// #266 の xc・x1・x4・z5）。
#[tokio::test]
async fn external_の無い_location_は_context_によらず_external_keyword_required_で弾く() {
    let harness = harness().await;
    for (query, catalog) in [
        (
            "CREATE TABLE AwsDataCatalog.db.t (n int) LOCATION 's3://b/p/'",
            Some("AwsDataCatalog"),
        ),
        (
            "CREATE TABLE t (n int) LOCATION 's3://b/p/'",
            Some("AwsDataCatalog"),
        ),
        (
            "CREATE TABLE IF NOT EXISTS db.t (n int) COMMENT 'c' PARTITIONED BY (p int) \
             CLUSTERED BY (n) INTO 4 BUCKETS ROW FORMAT SERDE 'x' LOCATION 's3://b/p/' \
             TBLPROPERTIES ('a278'='b')",
            Some("AwsDataCatalog"),
        ),
        (
            "create table db.t (n int) location 's3://b/p/'",
            Some("AwsDataCatalog"),
        ),
        (
            "CREATE TABLE db.t (n int) LOCATION 's3://b/p/' TBLPROPERTIES ('table_type'='HIVE')",
            Some("AwsDataCatalog"),
        ),
        // 実在する別のカタログの 3 部も、table_type が ICEBERG でなければ 2 catalogs より External が先（x1・x4）
        (
            "CREATE TABLE glue278.db.t (n int) STORED AS PARQUET LOCATION 's3://b/p/'",
            Some("AwsDataCatalog"),
        ),
        // Catalog の省略（r28）と、Context が実在する別のカタログ（z5）
        (
            "CREATE TABLE AwsDataCatalog.db.t (n int) LOCATION 's3://b/p/'",
            None,
        ),
        (
            "CREATE TABLE glue278.db.t (n int) LOCATION 's3://b/p/'",
            Some("glue278"),
        ),
    ] {
        assert_rejected(&harness, query, catalog, EXTERNAL_REQUIRED).await;
    }
    assert!(harness.syntax_checks().is_empty(), "構文チェックを送らない");
}

/// 既定の Context で 1 部目が実在する別のカタログなら、EXTERNAL の形は句・大小文字・コメント・列の並びの有無によらず、
/// EXTERNAL の無い形は table_type が ICEBERG のとき 2 catalogs。`<文>` は前後の空白と末尾の `;` を落とし、コメントは残す
/// （2026-09-27 実測 r1・r3〜r9・r13〜r18・r20・r22・r48）。
#[tokio::test]
async fn 既定の_context_の実在する別カタログの_3_部は_2_catalogs_で弾く() {
    let harness = harness().await;
    for (query, catalog) in [
        (
            "CREATE EXTERNAL TABLE glue278.db.t (n int) LOCATION 's3://b/p/'",
            "AwsDataCatalog",
        ),
        (
            "CREATE EXTERNAL TABLE IF NOT EXISTS glue278.db.t (n int) COMMENT 'c' \
             PARTITIONED BY (p int) ROW FORMAT SERDE 'x' STORED AS PARQUET LOCATION 's3://b/p/' \
             TBLPROPERTIES ('a278'='b')",
            "awsdatacatalog",
        ),
        (
            "create external table GLUE278.nosuchdb278.t (n int) location 's3://b/p/'",
            "AwsDataCatalog",
        ),
        (
            "-- c\nCREATE EXTERNAL TABLE /* c */ glue278 /* c */ .db.t (n int) LOCATION 's3://b/p/'",
            "AwsDataCatalog",
        ),
        (
            "CREATE EXTERNAL TABLE glue278.db.t LOCATION 's3://b/p/' TBLPROPERTIES ('a278'='b')",
            "AwsDataCatalog",
        ),
        (
            "CREATE EXTERNAL TABLE glue_alias.db.t (n int) LOCATION 's3://b/p/'",
            "AwsDataCatalog",
        ),
        (
            "CREATE TABLE glue278.db.t (n int) LOCATION 's3://b/p/' \
             TBLPROPERTIES ('table_type'='ICEBERG')",
            "AwsDataCatalog",
        ),
    ] {
        let message = format!("Unsupported ddl with 2 catalogs: {query}");
        assert_rejected(&harness, query, Some(catalog), &message).await;
    }

    let query = "CREATE EXTERNAL TABLE glue278.db.t (n int) LOCATION 's3://b/p/'";
    assert_rejected(
        &harness,
        &format!("  \t\n{query};\n\t  \n"),
        Some("AwsDataCatalog"),
        &format!("Unsupported ddl with 2 catalogs: {query}"),
    )
    .await;
    assert!(harness.syntax_checks().is_empty(), "構文チェックを送らない");
}

/// Context が実在する別のカタログなら、EXTERNAL の形の 1 部目がちょうど小文字の `awsdatacatalog` のときだけ 2 catalogs
/// （2026-09-27 実測 r29）。`AwsDataCatalog`・Context のカタログ自身は本物は成功した（#266 の z2〜z4）。実在しない Context は
/// 測っていないので弾かない。
#[tokio::test]
async fn 実在する別カタログの_context_ではちょうど小文字の_awsdatacatalog_だけ_2_catalogs_で弾く() {
    let harness = harness().await;
    const LOWER: &str = "CREATE EXTERNAL TABLE awsdatacatalog.db.t (n int) LOCATION 's3://b/p/'";
    for catalog in ["glue278", "glue_alias"] {
        assert_rejected(
            &harness,
            LOWER,
            Some(catalog),
            &format!("Unsupported ddl with 2 catalogs: {LOWER}"),
        )
        .await;
    }
    assert!(harness.syntax_checks().is_empty(), "構文チェックを送らない");

    for (query, catalog) in [
        (
            "CREATE EXTERNAL TABLE AwsDataCatalog.db.t (n int) LOCATION 's3://b/p/'",
            "glue278",
        ),
        (
            "CREATE EXTERNAL TABLE glue278.db.t (n int) LOCATION 's3://b/p/'",
            "glue278",
        ),
        (LOWER, "nosuch278"),
    ] {
        start(&harness, query, Some(catalog)).await;
    }
    assert_eq!(harness.syntax_checks().len(), 3, "構文チェックに任せる");
}

/// 本物が成功した形（既定の Context の `awsdatacatalog` の類・1〜2 部、Catalog の省略の r27、table_type が ICEBERG の
/// EXTERNAL の無い形）と、Hive の文法で読めない形（引用符付きの名前 r10〜r12・NOT NULL r19・r38）と、既定の Context で
/// 測っていない名前は弾かずに構文チェックに任せる。
#[tokio::test]
async fn 本物が成功する形と_hive_の文法で読めない形は構文チェックに任せる() {
    let harness = harness().await;
    let queries = [
        (
            "CREATE EXTERNAL TABLE AwsDataCatalog.db.t (n int) LOCATION 's3://b/p/'",
            Some("AwsDataCatalog"),
        ),
        (
            "CREATE EXTERNAL TABLE awsdatacatalog.db.t (n int) LOCATION 's3://b/p/'",
            Some("AwsDataCatalog"),
        ),
        (
            "CREATE EXTERNAL TABLE db.t (n int) LOCATION 's3://b/p/'",
            Some("AwsDataCatalog"),
        ),
        (
            "CREATE EXTERNAL TABLE glue278.db.t (n int) LOCATION 's3://b/p/'",
            None,
        ),
        (
            "CREATE TABLE db.t (n int) LOCATION 's3://b/p/' TBLPROPERTIES ('table_type'='ICEBERG')",
            Some("AwsDataCatalog"),
        ),
        (
            "CREATE TABLE db.t (n int) LOCATION 's3://b/p/' \
             TBLPROPERTIES ('format'='parquet', 'TABLE_TYPE' = 'iceberg')",
            Some("AwsDataCatalog"),
        ),
        (
            "CREATE EXTERNAL TABLE \"glue278\".db.t (n int) LOCATION 's3://b/p/'",
            Some("AwsDataCatalog"),
        ),
        (
            "CREATE EXTERNAL TABLE glue278.db.t (n int NOT NULL) LOCATION 's3://b/p/'",
            Some("AwsDataCatalog"),
        ),
        (
            "CREATE TABLE db.t (n int NOT NULL) LOCATION 's3://b/p/'",
            Some("AwsDataCatalog"),
        ),
        // 既定の Context で測っていない名前（4 部・バッククォート）は今までどおり
        (
            "CREATE TABLE awsdatacatalog.db.t.n (n int) LOCATION 's3://b/p/'",
            Some("AwsDataCatalog"),
        ),
        (
            "CREATE TABLE `t` (n int) LOCATION 's3://b/p/'",
            Some("AwsDataCatalog"),
        ),
    ];
    for (query, catalog) in queries {
        start(&harness, query, catalog).await;
    }
    assert_eq!(
        harness.syntax_checks(),
        queries.map(|(query, _)| query.to_string())
    );
}
