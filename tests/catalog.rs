//! TRINO_CATALOG_MAP: Trino では付けられないカタログ名（S3 Tables の `s3tablescatalog/<bucket>`）を
//! 別名に差し替えて送る。GetQueryExecution には受け取った名前を小文字にして返す（本物と同じ）。

mod common;

use common::{Harness, trino_error};
use serde_json::json;

const S3_TABLES_CATALOG: &str = "s3tablescatalog/example-bucket";

fn select_response() -> serde_json::Value {
    json!({
        "columns": [{ "name": "v", "type": "integer" }],
        "data": [[1]]
    })
}

#[tokio::test]
async fn 別名のカタログは差し替えて送り_実行情報には受け取った名前を返す() {
    let harness = Harness::builder(select_response())
        .catalog_map(&[(S3_TABLES_CATALOG, "iceberg")])
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "SELECT ? AS v FROM users",
            "ExecutionParameters": ["1"],
            "QueryExecutionContext": { "Catalog": S3_TABLES_CATALOG, "Database": "my_schema" }
        }))
        .await;

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");

    // 本体だけでなく、パラメータ分類の問い合わせも差し替えた名前で送る。
    let requests = harness.trino_requests();
    assert_eq!(requests.len(), 2, "分類 1 回 + 本体 1 回");
    for request in requests {
        assert_eq!(
            request.catalog.as_deref(),
            Some("iceberg"),
            "{}",
            request.sql
        );
        assert_eq!(
            request.schema.as_deref(),
            Some("my_schema"),
            "{}",
            request.sql
        );
    }

    assert_eq!(
        execution["QueryExecution"]["QueryExecutionContext"]["Catalog"],
        S3_TABLES_CATALOG
    );
}

/// 本物は GetQueryExecution の Catalog を小文字にして返す（`AWSDATACATALOG`・`aWSdATAcATALOG`・
/// 実在しない混在ケースの名前まで。2026-09-24 実測、#157）。Database は送ったまま（大文字の DB 名は
/// 大文字のまま返った）。小文字化は表示だけで、Trino には受け取った名前のまま送る。
#[tokio::test]
async fn 実行情報の_catalog_は小文字で返し_database_は受け取ったまま返す() {
    let harness = Harness::start(select_response()).await;

    let execution = harness
        .run_query(json!({
            "QueryString": "SELECT 1 AS v",
            "QueryExecutionContext": { "Catalog": "AwsDataCatalog", "Database": "MY_Schema" }
        }))
        .await;

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        execution["QueryExecution"]["QueryExecutionContext"]["Catalog"],
        "awsdatacatalog"
    );
    assert_eq!(
        execution["QueryExecution"]["QueryExecutionContext"]["Database"],
        "MY_Schema"
    );
    for request in harness.trino_requests() {
        assert_eq!(
            request.catalog.as_deref(),
            Some("AwsDataCatalog"),
            "{}",
            request.sql
        );
        assert_eq!(
            request.schema.as_deref(),
            Some("MY_Schema"),
            "{}",
            request.sql
        );
    }
}

/// 本物は省略した Catalog／Database を GetQueryExecution に返さない（キー無し。2026-09-24 実測、#167）。
/// 既定（TRINO_CATALOG／TRINO_SCHEMA）は Trino に送るときだけ当てる。
#[tokio::test]
async fn 省略した_catalog_と_database_は既定を_trino_に送るだけで実行情報には返さない() {
    let harness = Harness::start(select_response()).await;

    let execution = harness
        .run_query(json!({ "QueryString": "SELECT 1 AS v" }))
        .await;

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    let context = &execution["QueryExecution"]["QueryExecutionContext"];
    assert!(context.get("Catalog").is_none(), "{context}");
    assert!(context.get("Database").is_none(), "{context}");
    for request in harness.trino_requests() {
        assert_eq!(request.catalog.as_deref(), Some("default_catalog"));
        assert_eq!(request.schema.as_deref(), Some("default_schema"));
    }
}

#[tokio::test]
async fn 別名に無いカタログと既定のカタログはそのまま送る() {
    let harness = Harness::builder(select_response())
        .catalog_map(&[(S3_TABLES_CATALOG, "iceberg")])
        .start()
        .await;

    let hive = harness
        .run_query(json!({
            "QueryString": "SELECT 1",
            "QueryExecutionContext": { "Catalog": "hive" }
        }))
        .await;
    harness
        .run_query(json!({ "QueryString": "SELECT 2" }))
        .await;

    let catalogs: Vec<_> = harness
        .trino_requests()
        .into_iter()
        .map(|request| request.catalog)
        .collect();
    assert_eq!(
        catalogs,
        [
            Some("hive".to_string()),
            Some("default_catalog".to_string())
        ]
    );
    assert_eq!(
        hive["QueryExecution"]["QueryExecutionContext"]["Catalog"],
        "hive"
    );
}

/// `"s3tablescatalog/example-bucket"` を `"iceberg"` に置き換え、同じ文字数になるよう空白で埋めたもの。
fn aliased_catalog() -> String {
    let original = format!("\"{S3_TABLES_CATALOG}\"");
    format!(
        "\"iceberg\"{}",
        " ".repeat(original.len() - "\"iceberg\"".len())
    )
}

#[tokio::test]
async fn 修飾名のカタログは別名にして送り_構文チェックと実行情報は受け取った_sql_のまま() {
    let harness = Harness::builder(select_response())
        .catalog_map(&[(S3_TABLES_CATALOG, "iceberg")])
        .start()
        .await;
    let query = format!(r#"SELECT v FROM "{S3_TABLES_CATALOG}".my_schema.users"#);

    let execution = harness.run_query(json!({ "QueryString": query })).await;

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        harness.trino_sqls(),
        [format!(
            "SELECT v FROM {}.my_schema.users",
            aliased_catalog()
        )]
    );
    assert_eq!(harness.syntax_checks(), [query.as_str()]);
    assert_eq!(execution["QueryExecution"]["Query"], query);
}

#[tokio::test]
async fn パラメータ付きでも別名を当ててから包み_投げ直す_sql_にも当てる() {
    let aliased = format!("SELECT v FROM {}.my_schema.users", aliased_catalog());
    let wrapped = format!("EXECUTE IMMEDIATE '{aliased}' USING 1");
    let harness = Harness::builder(select_response())
        .catalog_map(&[(S3_TABLES_CATALOG, "iceberg")])
        .route(
            &wrapped,
            trino_error(
                "INVALID_PARAMETER_USAGE",
                "line 1:20: Incorrect number of parameters: expected 0 but found 1",
            ),
        )
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": format!(r#"SELECT v FROM "{S3_TABLES_CATALOG}".my_schema.users"#),
            "ExecutionParameters": ["1"]
        }))
        .await;

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        harness.trino_sqls(),
        ["SELECT (1)".to_string(), wrapped, aliased],
        "分類 1 回 + 包んだ本体 + 値を捨てて投げ直した本体"
    );
}

/// 本物は Context の Catalog が AwsDataCatalog のとき、無引用の `awsdatacatalog.<db>.<t>` を送ったまま
/// SUCCEEDED にした（2026-09-26 実測 m30〜m41。#246）。Trino には AwsDataCatalog の別名を当てて送り、Query は受け取ったまま返す。
#[tokio::test]
async fn aws_data_catalog_の_context_では無引用の_awsdatacatalog_に別名を当てて送る() {
    for (query, sent) in [
        (
            "SELECT * FROM awsdatacatalog.db.t",
            "SELECT * FROM \"hive\"        .db.t",
        ),
        (
            "SELECT * FROM AwsDataCatalog.db.t",
            "SELECT * FROM \"hive\"        .db.t",
        ),
        (
            "INSERT INTO awsdatacatalog.db.t VALUES (1)",
            "INSERT INTO \"hive\"        .db.t VALUES (1)",
        ),
        (
            "CREATE TABLE awsdatacatalog.db.t AS SELECT 1 AS n",
            "CREATE TABLE \"hive\"        .db.t AS SELECT 1 AS n",
        ),
        (
            "CREATE VIEW awsdatacatalog.db.v AS SELECT 1 AS n",
            "CREATE VIEW \"hive\"        .db.v AS SELECT 1 AS n",
        ),
        (
            "EXPLAIN SELECT * FROM awsdatacatalog.db.t",
            "EXPLAIN SELECT * FROM \"hive\"        .db.t",
        ),
    ] {
        for context in [
            json!({ "Catalog": "AwsDataCatalog", "Database": "db" }),
            json!({ "Database": "db" }),
        ] {
            let harness = Harness::builder(select_response())
                .catalog_map(&[("AwsDataCatalog", "hive")])
                .start()
                .await;

            let execution = harness
                .run_query(json!({ "QueryString": query, "QueryExecutionContext": context }))
                .await;

            assert_eq!(
                execution["QueryExecution"]["Status"]["State"], "SUCCEEDED",
                "{query} {context}: {execution}"
            );
            assert_eq!(harness.trino_sqls(), [sent], "{query} {context}");
            assert_eq!(harness.syntax_checks(), [query], "{query} {context}");
            assert_eq!(execution["QueryExecution"]["Query"], query);
        }
    }
}

/// S3 Tables の Context での無引用の `awsdatacatalog.<db>.<t>` の SELECT は測っていないので、今までどおり送る。
#[tokio::test]
async fn aws_data_catalog_でない_context_では無引用の_awsdatacatalog_をそのまま送る() {
    let harness = Harness::builder(select_response())
        .catalog_map(&[("AwsDataCatalog", "hive"), (S3_TABLES_CATALOG, "iceberg")])
        .start()
        .await;
    let query = "SELECT * FROM awsdatacatalog.db.t";

    let execution = harness
        .run_query(json!({
            "QueryString": query,
            "QueryExecutionContext": { "Catalog": S3_TABLES_CATALOG, "Database": "ns" }
        }))
        .await;

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(harness.trino_sqls(), [query]);
}
