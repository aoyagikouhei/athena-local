//! 無引用の 3 部の名前の場所の無い `CREATE TABLE` で、本物は名前の 1 部目のカタログが実在しなければ、Context によらず
//! 開始時に `DATACATALOG_NOT_FOUND`（`Catalog '<書いたとおり>' does not exist`）で弾いた（2026-09-26 実測 i3・j5・j6・
//! j10・j14。#227）。athena-local は `awsdatacatalog`（大文字小文字によらず）を実在とし、それ以外は `DESCRIBE` と同じく
//! Trino にカタログがあるかを問い合わせる。確かめられなければ今までどおり No location。

mod common;

use common::{Harness, trino_error};
use serde_json::{Value, json};

const NO_LOCATION: &str = "No location was specified for table. An S3 location must be specified";

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

fn select_response() -> Value {
    json!({ "columns": [{ "name": "_col0", "type": "integer" }], "data": [[1]] })
}

async fn start(harness: &Harness, query: &str, catalog: Option<&str>) -> (u16, Value) {
    let mut request = json!({ "QueryString": query });
    if let Some(catalog) = catalog {
        request["QueryExecutionContext"] = json!({ "Catalog": catalog, "Database": "ns" });
    }
    harness.call("StartQueryExecution", request).await
}

#[tokio::test]
async fn 実在しないカタログの_3_部は_context_によらず_datacatalog_not_found_で弾く() {
    let harness = Harness::builder(select_response())
        .catalog_map(&[("s3tablescatalog/b", "iceberg")])
        .route(
            &catalog_exists_sql("nosuchcatalog"),
            catalog_exists_response(None),
        )
        .start()
        .await;

    for (query, catalog) in [
        ("CREATE TABLE nosuchcatalog.db.t (n int)", None),
        (
            "CREATE TABLE NoSuchCatalog.db.t (n int)",
            Some("s3tablescatalog/b"),
        ),
        (
            "/* c */ CREATE TABLE IF NOT EXISTS NOSUCHCATALOG.ns.t (n int)",
            Some("s3tablescatalog/b"),
        ),
    ] {
        let (code, error) = start(&harness, query, catalog).await;
        let written = query.split('.').next().unwrap().rsplit(' ').next().unwrap();
        assert_eq!(code, 400, "{query}: {error}");
        assert_eq!(error["__type"], "InvalidRequestException", "{query}");
        assert_eq!(error["AthenaErrorCode"], "DATACATALOG_NOT_FOUND", "{query}");
        assert_eq!(
            error["Message"],
            format!("Catalog '{written}' does not exist"),
            "{query}"
        );
    }
    // 問い合わせだけで、本体は送らない。
    assert_eq!(
        harness.trino_sqls(),
        vec![catalog_exists_sql("nosuchcatalog"); 3]
    );
}

#[tokio::test]
async fn trino_にあるカタログの_3_部は_no_location_のまま() {
    let harness = Harness::builder(select_response())
        .route(
            &catalog_exists_sql("iceberg"),
            catalog_exists_response(Some("iceberg")),
        )
        .start()
        .await;

    let (code, error) = start(&harness, "CREATE TABLE iceberg.db.t (n int)", None).await;
    assert_eq!(code, 400, "{error}");
    assert_eq!(error["AthenaErrorCode"], "MALFORMED_QUERY");
    assert_eq!(error["Message"], NO_LOCATION);
    assert_eq!(harness.trino_sqls(), [catalog_exists_sql("iceberg")]);
}

/// 問い合わせが失敗したときと、応答の形が違うとき（偽 Trino の既定の応答）は、今までどおり No location。
#[tokio::test]
async fn カタログの問い合わせが確かめられなければ_no_location_のまま() {
    let harness = Harness::builder(select_response())
        .route(
            &catalog_exists_sql("broken"),
            trino_error("GENERIC_INTERNAL_ERROR", "boom"),
        )
        .start()
        .await;

    for query in [
        "CREATE TABLE broken.db.t (n int)",
        "CREATE TABLE othershape.db.t (n int)",
    ] {
        let (code, error) = start(&harness, query, None).await;
        assert_eq!(code, 400, "{query}: {error}");
        assert_eq!(error["AthenaErrorCode"], "MALFORMED_QUERY", "{query}");
        assert_eq!(error["Message"], NO_LOCATION, "{query}");
    }
}

/// `awsdatacatalog` は本物に必ずあるので問い合わせない（小文字ちょうどは既定の Context なら No location、S3 Tables の
/// Context なら 2 catalogs が先に決まる）。
#[tokio::test]
async fn awsdatacatalog_は大文字小文字によらず問い合わせずに_no_location_のまま() {
    let harness = Harness::start(select_response()).await;

    for query in [
        "CREATE TABLE awsdatacatalog.db.t (n int)",
        "CREATE TABLE AwsDataCatalog.db.t (n int)",
        "CREATE TABLE AWSDATACATALOG.db.t (n int)",
    ] {
        let (code, error) = start(&harness, query, None).await;
        assert_eq!(code, 400, "{query}: {error}");
        assert_eq!(error["Message"], NO_LOCATION, "{query}");
    }
    assert!(harness.trino_requests().is_empty(), "問い合わせない");
}

/// 文言が No location でない形（NV・4 部以上・引用符付き）と 1〜2 部の名前では、カタログを問い合わせない。
#[tokio::test]
async fn no_location_にならない形と_1_2_部の名前はカタログを問い合わせない() {
    let harness = Harness::start(select_response()).await;

    for query in [
        "CREATE TABLE nosuchcatalog.db.t (n int NOT NULL)",
        "CREATE TABLE nosuchcatalog.db.t.u (n int)",
        r#"CREATE TABLE "nosuchcatalog".db.t (n int)"#,
        "CREATE TABLE db.t (n int)",
        "CREATE TABLE t (n int)",
    ] {
        let (code, error) = start(&harness, query, None).await;
        assert_eq!(code, 400, "{query}: {error}");
        assert_ne!(error["AthenaErrorCode"], "DATACATALOG_NOT_FOUND", "{query}");
    }
    assert!(harness.trino_requests().is_empty(), "問い合わせない");
}

/// `TRINO_CATALOG_MAP` のキーは、SQL に書いた 1 部目と大文字小文字によらず当て、Trino 側の名前で問い合わせる。
#[tokio::test]
async fn 別名のキーは大文字小文字によらず当てて_trino_側の名前を問い合わせる() {
    let harness = Harness::builder(select_response())
        .catalog_map(&[("SalesFederation", "pg")])
        .route(
            &catalog_exists_sql("pg"),
            catalog_exists_response(Some("postgresql")),
        )
        .start()
        .await;

    let (code, error) = start(&harness, "CREATE TABLE salesfederation.db.t (n int)", None).await;
    assert_eq!(code, 400, "{error}");
    assert_eq!(error["Message"], NO_LOCATION);
    assert_eq!(harness.trino_sqls(), [catalog_exists_sql("pg")]);
}
