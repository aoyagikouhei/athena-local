//! 本物の Athena は、一部の文で GetQueryExecution の `Query` と Context の Database を組み直す（2026-09-26 実測
//! ROUND=8。#242）。DESCRIBE・DESC・SHOW COLUMNS・SHOW CREATE TABLE・SHOW TABLES IN・ALTER TABLE・DROP TABLE は
//! 名前の 1 部目の `awsdatacatalog.` を落として Context のカタログとして扱い、Context の Database を修飾の DB にする。
//! SELECT・INSERT・CTAS・CREATE VIEW・EXPLAIN は送ったまま。

mod common;

use common::Harness;
use serde_json::{Value, json};

fn select_response() -> Value {
    json!({ "columns": [{ "name": "n", "type": "bigint" }], "data": [[1]] })
}

/// 形式と存在を 1 つにまとめた問い合わせ（`src/operation/table_format.rs` の `probe_sql` と同じ形。
/// tests/entity_check.rs の写し。ずれればルートに当たらずテストが落ちる）。
fn probe_sql(catalog: &str, schema: &str, table: &str) -> String {
    format!(
        "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = '{catalog}'), (SELECT table_type FROM system.jdbc.tables WHERE table_cat = '{catalog}' AND table_schem = '{schema}' AND table_name = '{table}')"
    )
}

fn probe_response(table_type: &str) -> Value {
    json!({
        "columns": [
            { "name": "_col0", "type": "varchar" },
            { "name": "_col1", "type": "varchar" }
        ],
        "data": [["hive", table_type]]
    })
}

/// Context が `AwsDataCatalog`（別名 hive）・`db` の harness。db.t・db2.t2 は表。
async fn harness() -> Harness {
    Harness::builder(select_response())
        .catalog_map(&[("AwsDataCatalog", "hive")])
        .route(&probe_sql("hive", "db", "t"), probe_response("TABLE"))
        .route(&probe_sql("hive", "db2", "t2"), probe_response("TABLE"))
        .start()
        .await
}

async fn run(harness: &Harness, query: &str, context: Value) -> Value {
    harness
        .run_query(json!({ "QueryString": query, "QueryExecutionContext": context }))
        .await["QueryExecution"]
        .clone()
}

fn context() -> Value {
    json!({ "Catalog": "AwsDataCatalog", "Database": "db" })
}

#[tokio::test]
async fn awsdatacatalog_のカタログ部分を落とした文を実行し_query_と_database_に返す() {
    let harness = harness().await;
    for (query, statement, database) in [
        (
            "SHOW COLUMNS FROM awsdatacatalog.db.t",
            "SHOW COLUMNS FROM db.t",
            "db",
        ),
        (
            "SHOW COLUMNS FROM AwsDataCatalog.db.t",
            "SHOW COLUMNS FROM db.t",
            "db",
        ),
        (
            "SHOW COLUMNS IN awsdatacatalog.db.t",
            "SHOW COLUMNS IN db.t",
            "db",
        ),
        (
            "SHOW COLUMNS FROM awsdatacatalog.db2.t2",
            "SHOW COLUMNS FROM db2.t2",
            "db2",
        ),
        (
            "SHOW CREATE TABLE awsdatacatalog.db.t",
            "SHOW CREATE TABLE db.t",
            "db",
        ),
        (
            "SHOW CREATE TABLE awsdatacatalog . db . t",
            "SHOW CREATE TABLE db . t",
            "db",
        ),
        (
            "SHOW TABLES IN awsdatacatalog.db",
            "SHOW TABLES IN db",
            "db",
        ),
        (
            "SHOW TABLES IN AwsDataCatalog.db2",
            "SHOW TABLES IN db2",
            "db2",
        ),
        (
            "DROP TABLE IF EXISTS awsdatacatalog.db.nope",
            "DROP TABLE IF EXISTS db.nope",
            "db",
        ),
        (
            "ALTER TABLE awsdatacatalog.db2.t2 ADD COLUMNS (m int)",
            "ALTER TABLE db2.t2 ADD COLUMNS (m int)",
            "db2",
        ),
    ] {
        let execution = run(&harness, query, context()).await;
        assert_eq!(
            execution["Status"]["State"], "SUCCEEDED",
            "{query}: {execution}"
        );
        assert_eq!(execution["Query"], statement, "{query}");
        assert_eq!(
            execution["QueryExecutionContext"]["Database"], database,
            "{query}"
        );
        let sent = harness.trino_requests().pop().expect("実行した");
        assert_eq!(sent.sql, statement, "{query}");
        assert_eq!(sent.schema.as_deref(), Some(database), "{query}");
    }
}

/// 今まではカタログ `awsdatacatalog` が Trino に無く、開始時に DATACATALOG_NOT_FOUND で弾いていた。
#[tokio::test]
async fn awsdatacatalog_の_3_部の_describe_も開始時の確認を通る() {
    let harness = harness().await;
    for query in [
        "DESCRIBE awsdatacatalog.db2.t2",
        "DESCRIBE AwsDataCatalog.db2.t2",
        "DESC awsdatacatalog.db2.t2",
    ] {
        let execution = run(&harness, query, context()).await;
        assert_eq!(
            execution["Status"]["State"], "SUCCEEDED",
            "{query}: {execution}"
        );
        assert_eq!(
            execution["QueryExecutionContext"]["Database"], "db2",
            "{query}"
        );
    }
    assert!(
        harness
            .trino_sqls()
            .contains(&probe_sql("hive", "db2", "t2")),
        "修飾の DB で存在を確かめる"
    );
}

#[tokio::test]
async fn カタログ部分を落とさない文と形は受け取ったまま送る() {
    let harness = harness().await;
    for (query, context) in [
        ("SELECT * FROM awsdatacatalog.db.t", context()),
        ("INSERT INTO awsdatacatalog.db.t VALUES (1)", context()),
        (
            "CREATE TABLE awsdatacatalog.db.t3 AS SELECT 1 AS n",
            context(),
        ),
        (
            "CREATE VIEW awsdatacatalog.db.v AS SELECT 1 AS n",
            context(),
        ),
        ("EXPLAIN SELECT * FROM awsdatacatalog.db.t", context()),
        // Context の Catalog が AwsDataCatalog 以外（測っていない）。
        (
            "SHOW TABLES IN awsdatacatalog.db",
            json!({ "Catalog": "other", "Database": "db" }),
        ),
        // 1 部目が awsdatacatalog でない。
        ("SHOW TABLES IN db", context()),
    ] {
        let execution = run(&harness, query, context).await;
        assert_eq!(execution["Query"], query, "{query}");
        assert_eq!(
            execution["QueryExecutionContext"]["Database"], "db",
            "{query}"
        );
        assert_eq!(harness.trino_sqls().last(), Some(&query.to_string()));
    }
}

/// 4 部以上の名前は本物が名前の形だけで弾く（`Invalid table name`。2026-09-25 実測）。カタログを落として
/// 3 部にすると、この判定を素通りする。
#[tokio::test]
async fn 四部の名前はカタログを落とさず_invalid_table_name_で弾く() {
    let harness = harness().await;
    let (code, error) = harness
        .call(
            "StartQueryExecution",
            json!({ "QueryString": "DESCRIBE awsdatacatalog.db.t.n", "QueryExecutionContext": context() }),
        )
        .await;
    assert_eq!(code, 400, "{error}");
    assert_eq!(error["Message"], "Invalid table name awsdatacatalog.db.t.n");
}
