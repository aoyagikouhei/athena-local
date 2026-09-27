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

/// 本物は Context の Catalog が AwsDataCatalog か省略の SELECT で、部品に引用符付きを含む名前と 4 部の列の参照も
/// 送ったまま SUCCEEDED にした（2026-09-27 実測 o6〜o8・o10。#260）。INSERT の引用符付きの部品は測っていないので送ったまま。
#[tokio::test]
async fn aws_data_catalog_の_context_の_select_は引用符付きの部品と_4_部の列の参照にも別名を当てる()
{
    for (query, sent) in [
        (
            "SELECT * FROM awsdatacatalog.\"db\".t",
            "SELECT * FROM \"hive\"        .\"db\".t",
        ),
        (
            "SELECT * FROM awsdatacatalog.db.\"t\"",
            "SELECT * FROM \"hive\"        .db.\"t\"",
        ),
        (
            "SELECT awsdatacatalog.db.t.n FROM awsdatacatalog.db.t",
            "SELECT \"hive\"        .db.t.n FROM \"hive\"        .db.t",
        ),
        (
            "INSERT INTO awsdatacatalog.\"db\".t VALUES (1)",
            "INSERT INTO awsdatacatalog.\"db\".t VALUES (1)",
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

            assert_eq!(harness.trino_sqls(), [sent], "{query} {context}");
            assert_eq!(execution["QueryExecution"]["Query"], query);
        }
    }
}

/// カタログの有無の問い合わせ（`src/operation/table_format.rs` の `catalog_exists_sql` と同じ形。
/// ずれればルートに当たらずテストが落ちる）。
fn catalog_exists_sql(catalog: &str) -> String {
    format!(
        "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = '{catalog}')"
    )
}

fn catalog_exists_response(connector_name: Option<&str>) -> serde_json::Value {
    json!({
        "columns": [{ "name": "_col0", "type": "varchar" }],
        "data": [[connector_name]]
    })
}

const SELECT_UNQUOTED: (&str, &str) = (
    "SELECT * FROM awsdatacatalog.db.t",
    "SELECT * FROM \"hive\"        .db.t",
);
const INSERT_UNQUOTED: (&str, &str) = (
    "INSERT INTO AwsDataCatalog.db.t VALUES (2, 'y')",
    "INSERT INTO \"hive\"        .db.t VALUES (2, 'y')",
);

/// 本物は S3 Tables の Context でも、無引用の `awsdatacatalog.<db>.<t>` の SELECT・INSERT を Glue の表として
/// SUCCEEDED にした（2026-09-27 実測 o1・o2。#260）。Query は受け取ったまま返す。
#[tokio::test]
async fn s3_tables_の_context_の_select_と_insert_は無引用の_awsdatacatalog_に別名を当てて送る() {
    for (query, sent) in [SELECT_UNQUOTED, INSERT_UNQUOTED] {
        let harness = Harness::builder(select_response())
            .catalog_map(&[("AwsDataCatalog", "hive"), (S3_TABLES_CATALOG, "iceberg")])
            .start()
            .await;

        let execution = harness
            .run_query(json!({
                "QueryString": query,
                "QueryExecutionContext": { "Catalog": S3_TABLES_CATALOG, "Database": "ns" }
            }))
            .await;

        assert_eq!(
            execution["QueryExecution"]["Status"]["State"], "SUCCEEDED",
            "{query}: {execution}"
        );
        assert_eq!(harness.trino_sqls(), [sent], "{query}");
        assert_eq!(execution["QueryExecution"]["Query"], query);
    }
}

/// S3 Tables の Context のほかの文と、引用符付きの部品を含む名前は測っていないので、今までどおり送る。
#[tokio::test]
async fn s3_tables_の_context_のほかの文と引用符付きの部品は無引用の_awsdatacatalog_をそのまま送る()
{
    for query in [
        "EXPLAIN SELECT * FROM awsdatacatalog.db.t",
        "SELECT * FROM awsdatacatalog.\"db\".t",
    ] {
        let harness = Harness::builder(select_response())
            .catalog_map(&[("AwsDataCatalog", "hive"), (S3_TABLES_CATALOG, "iceberg")])
            .start()
            .await;

        harness
            .run_query(json!({
                "QueryString": query,
                "QueryExecutionContext": { "Catalog": S3_TABLES_CATALOG, "Database": "ns" }
            }))
            .await;

        assert_eq!(harness.trino_sqls(), [query], "{query}");
    }
}

/// 本物は実在しないカタログの Context でも、無引用の `awsdatacatalog.<db>.<t>` の SELECT（2026-09-25 実測 #214）と
/// INSERT（2026-09-27 実測 o5。#260）を SUCCEEDED にした。Trino に無いことを確かめてから別名を当て、ヘッダのカタログは
/// 受け取ったまま送る（Trino はセッションのカタログが無くても完全修飾の名前を引く）。
#[tokio::test]
async fn 実在しないカタログの_context_の_select_と_insert_は無引用の_awsdatacatalog_に別名を当てて送る()
 {
    for (query, sent) in [SELECT_UNQUOTED, INSERT_UNQUOTED] {
        let harness = Harness::builder(select_response())
            .catalog_map(&[("AwsDataCatalog", "hive")])
            .route(
                &catalog_exists_sql("nosuchcatalog260"),
                catalog_exists_response(None),
            )
            .start()
            .await;

        let execution = harness
            .run_query(json!({
                "QueryString": query,
                "QueryExecutionContext": { "Catalog": "NoSuchCatalog260", "Database": "db" }
            }))
            .await;

        assert_eq!(
            execution["QueryExecution"]["Status"]["State"], "SUCCEEDED",
            "{query}: {execution}"
        );
        let requests = harness.trino_requests();
        assert_eq!(
            requests.iter().map(|r| r.sql.as_str()).collect::<Vec<_>>(),
            [catalog_exists_sql("nosuchcatalog260").as_str(), sent],
            "{query}"
        );
        assert_eq!(requests[1].catalog.as_deref(), Some("NoSuchCatalog260"));
        assert_eq!(execution["QueryExecution"]["Query"], query);
    }
}

/// 連携カタログの Context は測っていないので、Trino にあるカタログ（連携カタログとみなす）と別名のキーの Context では
/// 今までどおり送る。別名のキーは Trino に問い合わせない。
#[tokio::test]
async fn trino_にあるカタログと別名のキーの_context_では無引用の_awsdatacatalog_をそのまま送る() {
    let (query, _) = SELECT_UNQUOTED;
    let harness = Harness::builder(select_response())
        .catalog_map(&[("AwsDataCatalog", "hive"), ("Federated", "pg")])
        .route(
            &catalog_exists_sql("postgres"),
            catalog_exists_response(Some("postgresql")),
        )
        .start()
        .await;

    for catalog in ["postgres", "Federated"] {
        harness
            .run_query(json!({
                "QueryString": query,
                "QueryExecutionContext": { "Catalog": catalog, "Database": "db" }
            }))
            .await;
    }

    assert_eq!(
        harness.trino_sqls(),
        [catalog_exists_sql("postgres").as_str(), query, query]
    );
}

/// 実在しないカタログの Context のほかの文は測っていないので、有無を問い合わせずに今までどおり送る。
#[tokio::test]
async fn 実在しないカタログの_context_のほかの文は問い合わせずに無引用の_awsdatacatalog_をそのまま送る()
 {
    let query = "EXPLAIN SELECT * FROM awsdatacatalog.db.t";
    let harness = Harness::builder(select_response())
        .catalog_map(&[("AwsDataCatalog", "hive")])
        .route(
            &catalog_exists_sql("nosuchcatalog260"),
            catalog_exists_response(None),
        )
        .start()
        .await;

    harness
        .run_query(json!({
            "QueryString": query,
            "QueryExecutionContext": { "Catalog": "nosuchcatalog260", "Database": "db" }
        }))
        .await;

    assert_eq!(harness.trino_sqls(), [query]);
}
