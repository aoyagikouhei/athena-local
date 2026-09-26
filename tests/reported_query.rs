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

/// 対象が存在し、形式が iceberg の表である応答（`tests/table_format.rs` の `probe_response(connector_name)` と同じ形）。
fn probe_response_iceberg() -> Value {
    json!({
        "columns": [
            { "name": "_col0", "type": "varchar" },
            { "name": "_col1", "type": "varchar" }
        ],
        "data": [["iceberg", "TABLE"]]
    })
}

/// Context が `AwsDataCatalog`（別名 hive）・`db` の harness。db.t・db2.t2 は表、db.v はビュー。
async fn harness() -> Harness {
    builder().start().await
}

fn builder() -> common::HarnessBuilder {
    Harness::builder(select_response())
        .catalog_map(&[("AwsDataCatalog", "hive")])
        .route(&probe_sql("hive", "db", "t"), probe_response("TABLE"))
        .route(&probe_sql("hive", "db2", "t2"), probe_response("TABLE"))
        .route(&probe_sql("hive", "db", "v"), probe_response("VIEW"))
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

/// 本物は表への DESCRIBE・DESC の Query から修飾（カタログ・DB）を落とし、Context の Database を修飾の DB
/// （文中の綴り）にする。Context と違う DB・Context に Database が無い形も同じ（2026-09-26 実測 m1〜m13）。
/// 今まで 3 部の形はカタログ `awsdatacatalog` が Trino に無く、開始時に DATACATALOG_NOT_FOUND で弾いていた。
#[tokio::test]
async fn 表への_describe_は修飾を落とした文を実行し_query_と_database_に返す() {
    let harness = harness().await;
    for (query, context, statement, database) in [
        ("DESCRIBE db.t", context(), "DESCRIBE t", "db"),
        ("DESCRIBE db2.t2", context(), "DESCRIBE t2", "db2"),
        ("DESC db2.t2", context(), "DESC t2", "db2"),
        (
            "DESCRIBE db.t",
            json!({ "Catalog": "AwsDataCatalog" }),
            "DESCRIBE t",
            "db",
        ),
        (
            "DESCRIBE db.t",
            json!({ "Catalog": "AwsDataCatalog", "Database": "db2" }),
            "DESCRIBE t",
            "db",
        ),
        ("DESCRIBE db . t", context(), "DESCRIBE t", "db"),
        ("DESCRIBE DB2.t2", context(), "DESCRIBE t2", "DB2"),
        (
            "DESCRIBE awsdatacatalog.db2.t2",
            context(),
            "DESCRIBE t2",
            "db2",
        ),
        (
            "DESCRIBE AwsDataCatalog.db2.t2",
            context(),
            "DESCRIBE t2",
            "db2",
        ),
        ("DESC awsdatacatalog.db2.t2", context(), "DESC t2", "db2"),
    ] {
        let execution = run(&harness, query, context).await;
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

/// ビューは修飾が残る（DESCRIBE は m11、SHOW COLUMNS の 3 部は m37）。SHOW COLUMNS の 3 部は Trino では
/// カタログを落とした文で実行し、GetQueryExecution には受け取った文と Database を返す。
#[tokio::test]
async fn ビューは修飾を残した_query_を返す() {
    let harness = harness().await;
    for (query, sent) in [
        ("DESCRIBE db.v", "DESCRIBE db.v"),
        (
            "SHOW COLUMNS FROM awsdatacatalog.db.v",
            "SHOW COLUMNS FROM db.v",
        ),
    ] {
        let execution = run(&harness, query, context()).await;
        assert_eq!(
            execution["Status"]["State"], "SUCCEEDED",
            "{query}: {execution}"
        );
        assert_eq!(execution["Query"], query, "{query}");
        assert_eq!(
            execution["QueryExecutionContext"]["Database"], "db",
            "{query}"
        );
        assert_eq!(harness.trino_sqls().last(), Some(&sent.to_string()));
    }
}

/// Context の Catalog が実在しない（本物は修飾を残す。#212・#214 の実測）と 1 部の名前は変えない。実在しない
/// Catalog は既定のカタログ（AwsDataCatalog の別名）に差し替えて表と確かめる（#214）ので、Context の条件だけが
/// 書き換えを止める。
#[tokio::test]
async fn 修飾を落とさない_describe_は受け取ったまま送る() {
    let harness = builder()
        .route(
            "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = 'nocatalog')",
            json!({ "columns": [{ "name": "_col0", "type": "varchar" }], "data": [[null]] }),
        )
        .start()
        .await;
    for (query, context) in [
        (
            "DESCRIBE db.t",
            json!({ "Catalog": "nocatalog", "Database": "db" }),
        ),
        ("DESCRIBE t", context()),
    ] {
        let execution = run(&harness, query, context).await;
        assert_eq!(
            execution["Status"]["State"], "SUCCEEDED",
            "{query}: {execution}"
        );
        assert_eq!(execution["Query"], query, "{query}");
        assert_eq!(
            execution["QueryExecutionContext"]["Database"], "db",
            "{query}"
        );
    }
    assert!(
        harness.trino_sqls().contains(&probe_sql("hive", "db", "t")),
        "既定のカタログで表と確かめた"
    );
}

/// 本物は DESCRIBE の直後のブロックコメントを Hive の ParseException で FAILED にし、StateChangeReason と同じ
/// 文言の `.txt` を置いて `.metadata` は置かない（`DESCRIBE /* c */ t` は 2026-09-22 実測、DB を落とした後に
/// 同じ形になる `DESCRIBE <db>./* c */<t>` は 2026-09-26 実測 m10）。Trino には送らない。
#[tokio::test]
async fn describe_の直後のブロックコメントは本物と同じ_parse_exception_で失敗する() {
    const REASON: &str = "FAILED: ParseException line 1:0 cannot recognize input near 'DESCRIBE' '/' '*' in describe statement";
    let harness = builder().results_s3().start().await;
    for (query, statement) in [
        ("DESCRIBE /* c */ t", "DESCRIBE /* c */ t"),
        ("DESCRIBE db./* c */t", "DESCRIBE /* c */t"),
    ] {
        let execution = harness
            .run_query(json!({
                "QueryString": query,
                "QueryExecutionContext": context(),
                "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
            }))
            .await["QueryExecution"]
            .clone();
        let id = execution["QueryExecutionId"].as_str().expect("ID");
        assert_eq!(
            execution["Status"]["State"], "FAILED",
            "{query}: {execution}"
        );
        assert_eq!(execution["Query"], statement, "{query}");
        assert_eq!(execution["Status"]["StateChangeReason"], REASON, "{query}");
        assert_eq!(execution["Status"]["AthenaError"]["ErrorCategory"], 1);
        assert_eq!(execution["Status"]["AthenaError"]["ErrorType"], 1003);
        assert_eq!(execution["Status"]["AthenaError"]["ErrorMessage"], REASON);
        let puts: Vec<_> = harness
            .s3_puts()
            .into_iter()
            .filter(|put| put.key.contains(id))
            .collect();
        assert_eq!(puts.len(), 1, "{query}: .txt だけ置き .metadata は置かない");
        assert_eq!(puts[0].key, format!("athena/{id}.txt"));
        assert_eq!(puts[0].body, REASON.as_bytes());
    }
    assert!(
        harness
            .trino_sqls()
            .iter()
            .all(|sql| !sql.starts_with("DESCRIBE")),
        "Trino には送らない"
    );

    // 行コメントは本物で失敗するか測っていないので、今までどおり実行する。
    let execution = harness
        .run_query(json!({
            "QueryString": "DESCRIBE -- c\nt",
            "QueryExecutionContext": context(),
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await["QueryExecution"]
        .clone();
    assert_eq!(execution["Status"]["State"], "SUCCEEDED", "{execution}");
}

/// 本物は Iceberg 表への `DESCRIBE` の直後のブロックコメントを ParseException にせず成功させた
/// （2026-09-26 実測 d1。#244）。Hive・無い表・ビューだけ弾き、Iceberg 表は Trino に送って実行する。
#[tokio::test]
async fn describe_の直後のブロックコメントは_iceberg_表なら成功して_trino_に送る() {
    let harness = builder()
        .route(&probe_sql("hive", "db", "i"), probe_response_iceberg())
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DESCRIBE /* c */ i",
            "QueryExecutionContext": context(),
        }))
        .await["QueryExecution"]
        .clone();

    assert_eq!(execution["Status"]["State"], "SUCCEEDED", "{execution}");
    assert!(
        harness
            .trino_sqls()
            .iter()
            .any(|sql| sql.starts_with("DESCRIBE")),
        "Iceberg 表なら Trino に DESCRIBE を送る: {:?}",
        harness.trino_sqls()
    );
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
