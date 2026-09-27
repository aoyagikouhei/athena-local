//! 構文エラーは StartQueryExecution で 400（MALFORMED_QUERY）にして、実行を作らない。
//! 本番 Athena の挙動（2026-09-14 実測）。athena-local は元の SQL を Trino に PREPARE させて確かめる。

mod common;

use common::{Harness, trino_error};
use serde_json::{Value, json};

const EXPECTING: &str = "Expecting: 'ALTER', 'ANALYZE', 'CALL', <query>";

fn select_response() -> Value {
    json!({ "columns": [{ "name": "n", "type": "bigint" }], "data": [[1]] })
}

fn syntax_error(message: &str) -> Value {
    trino_error("SYNTAX_ERROR", message)
}

#[tokio::test]
async fn 構文エラーは開始時に_400_で弾き_本体は_trino_に送らない() {
    // Trino は前置きの 1 行ぶんずれた位置で返す。
    let harness = Harness::builder(select_response())
        .syntax_check_response(
            "SELEC 1",
            syntax_error(&format!("line 2:1: mismatched input 'SELEC'. {EXPECTING}")),
        )
        .start()
        .await;

    let (code, error) = harness
        .call("StartQueryExecution", json!({ "QueryString": "SELEC 1" }))
        .await;

    assert_eq!(code, 400);
    assert_eq!(error["__type"], "InvalidRequestException");
    assert_eq!(error["AthenaErrorCode"], "MALFORMED_QUERY");
    assert_eq!(
        error["Message"],
        format!("line 1:1: mismatched input 'SELEC'. {EXPECTING}")
    );
    assert_eq!(harness.syntax_checks(), ["SELEC 1"]);
    assert!(harness.trino_requests().is_empty(), "実行は作らない");
}

#[tokio::test]
async fn 複数行の文でも元の_sql_の行で数える() {
    let sql = "SELECT 1\nFROM WHERE";
    let harness = Harness::builder(select_response())
        .syntax_check_response(sql, syntax_error("line 3:6: mismatched input 'WHERE'"))
        .start()
        .await;

    let (code, error) = harness
        .call("StartQueryExecution", json!({ "QueryString": sql }))
        .await;

    assert_eq!(code, 400);
    assert_eq!(error["Message"], "line 2:6: mismatched input 'WHERE'");
}

#[tokio::test]
async fn パラメータ付きでも値を当てる前の_sql_で確かめる() {
    let harness = Harness::builder(select_response())
        .syntax_check_response(
            "SELEC ?",
            syntax_error(&format!("line 2:1: mismatched input 'SELEC'. {EXPECTING}")),
        )
        .start()
        .await;

    let (code, error) = harness
        .call(
            "StartQueryExecution",
            json!({ "QueryString": "SELEC ?", "ExecutionParameters": ["1"] }),
        )
        .await;

    assert_eq!(code, 400);
    assert_eq!(
        error["Message"],
        format!("line 1:1: mismatched input 'SELEC'. {EXPECTING}")
    );
    assert_eq!(harness.syntax_checks(), ["SELEC ?"]);
    assert!(harness.trino_requests().is_empty(), "値の分類も走らせない");
}

#[tokio::test]
async fn 構文が正しければ確かめたうえでそのまま実行する() {
    let harness = Harness::start(select_response()).await;

    let execution = harness
        .run_query(json!({ "QueryString": "SELECT n FROM t" }))
        .await;

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(harness.syntax_checks(), ["SELECT n FROM t"]);
    assert_eq!(harness.trino_sqls(), ["SELECT n FROM t"]);
}

#[tokio::test]
async fn 構文エラー以外の失敗は開始時には返さず実行に任せる() {
    // PREPARE を包めない文は Trino が NOT_SUPPORTED を返す。構文は正しいので実行に進む。
    let harness = Harness::builder(select_response())
        .syntax_check_response(
            "PREPARE p FROM SELECT 1",
            trino_error(
                "NOT_SUPPORTED",
                "Invalid statement type for prepared statement: PREPARE",
            ),
        )
        .start()
        .await;

    let (code, started) = harness
        .call(
            "StartQueryExecution",
            json!({ "QueryString": "PREPARE p FROM SELECT 1" }),
        )
        .await;

    assert_eq!(code, 200, "{started}");
    assert!(started["QueryExecutionId"].is_string());
}

#[tokio::test]
async fn ブロックコメント付きの_show_create_table_は本物どおり_failed_になる() {
    // 本物は Hive のパーサの ParseException で失敗させる（2026-09-26 実測。#244。tests/comment_parse_error.rs
    // にほかの位置・文・表の形式の組み合わせがある）。構文チェック自体は通るので、開始時の 400 ではなく
    // 開始後の FAILED になる。
    let sql = "/* c */ SHOW CREATE TABLE t";
    let harness = Harness::builder(select_response())
        .route(
            "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = 'default_catalog'), (SELECT table_type FROM system.jdbc.tables WHERE table_cat = 'default_catalog' AND table_schem = 'default_schema' AND table_name = 't')",
            json!({
                "columns": [
                    { "name": "_col0", "type": "varchar" },
                    { "name": "_col1", "type": "varchar" }
                ],
                "data": [["hive", "TABLE"]]
            }),
        )
        .start()
        .await;

    let execution = harness.run_query(json!({ "QueryString": sql })).await;

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "FAILED");
    assert_eq!(
        execution["QueryExecution"]["Status"]["StateChangeReason"],
        "FAILED: ParseException line 1:0 cannot recognize input near '/' '*' 'c'"
    );
    assert_eq!(harness.syntax_checks(), [sql]);
    // 対象の表の形式を確かめる probe だけが飛び、SHOW CREATE TABLE の本体は Trino に送らない。
    let sqls = harness.trino_sqls();
    assert_eq!(sqls.len(), 1, "{sqls:?}");
    assert!(sqls[0].starts_with("SELECT"), "{sqls:?}");
}

/// 本物は引用符付きの名前を取る DESCRIBE などを、Trino が受ける形でも開始時に弾く（2026-09-25 実測。#204）。
/// 文言は本物の Hive 系のパーサのもので、構文チェックを通った後に athena-local が返す。
#[tokio::test]
async fn 引用符付きの名前の_describe_は構文チェックの後に本物の文言で弾き_実行を作らない() {
    let query = r#"DESCRIBE "t""#;
    let harness = Harness::builder(select_response()).start().await;

    let (code, error) = harness
        .call("StartQueryExecution", json!({ "QueryString": query }))
        .await;

    assert_eq!(code, 400, "{error}");
    assert_eq!(error["__type"], "InvalidRequestException");
    assert_eq!(error["AthenaErrorCode"], "MALFORMED_QUERY");
    assert_eq!(
        error["Message"],
        r#"line 1:10: no viable alternative at input 'DESCRIBE "t"'"#
    );
    assert_eq!(harness.syntax_checks(), [query], "構文チェックは先に送る");
    // 存在の問い合わせ（#207）は送るが、応答が問い合わせの形でないので存在は分からず、構文の文言になる。
    assert_eq!(harness.trino_sqls().len(), 1, "探索だけで、実行は作らない");
}

/// Trino が構文エラーにする形は、本物も Trino の文言を返した（`ALTER TABLE "t" ADD COLUMNS`。2026-09-25 実測）。
#[tokio::test]
async fn 引用符付きの名前でも構文エラーなら_trino_の文言を返す() {
    let query = r#"ALTER TABLE "t" ADD COLUMNS (m int)"#;
    let harness = Harness::builder(select_response())
        .syntax_check_response(
            query,
            syntax_error("line 2:21: mismatched input 'COLUMNS'. Expecting: '.', 'ADD'"),
        )
        .start()
        .await;

    let (code, error) = harness
        .call("StartQueryExecution", json!({ "QueryString": query }))
        .await;

    assert_eq!(code, 400, "{error}");
    assert_eq!(
        error["Message"],
        "line 1:21: mismatched input 'COLUMNS'. Expecting: '.', 'ADD'"
    );
}

/// 本物は無引用の `ALTER TABLE IF EXISTS ...` と単数形の `ADD COLUMN` も、Trino が構文として受ける形でも
/// 開始時に弾く（2026-09-26 実測。#208）。文言は quoted_names と同じ出口（`unquoted_ddl::rejection`）から返す。
#[tokio::test]
async fn 無引用の_alter_table_も本物の文言で開始時に弾き_実行を作らない() {
    let harness = Harness::builder(select_response()).start().await;

    for (query, message) in [
        (
            "ALTER TABLE IF EXISTS t RENAME TO u",
            "line 1:16: no viable alternative at input 'ALTER TABLE IF EXISTS'",
        ),
        (
            "ALTER TABLE t ADD COLUMN m int",
            "line 1:19: no viable alternative at input 'ALTER TABLE t ADD COLUMN'",
        ),
    ] {
        let (code, error) = harness
            .call("StartQueryExecution", json!({ "QueryString": query }))
            .await;

        assert_eq!(code, 400, "{query}: {error}");
        assert_eq!(error["__type"], "InvalidRequestException", "{query}");
        assert_eq!(error["AthenaErrorCode"], "MALFORMED_QUERY", "{query}");
        assert_eq!(error["Message"], message, "{query}");
        assert_eq!(harness.syntax_checks().last(), Some(&query.to_string()));
        assert!(
            harness.trino_requests().is_empty(),
            "{query}: 実行は作らない"
        );
    }
}

/// `quoted_names::rejection` の文言が無引用の ALTER TABLE の文言より先に決まる
/// （`start_checks.rs` の `or_else` の順序。#204 が先、#208 は quoted_names が None のときだけ）。
/// 引用符付きの名前は quoted_names が先に決めるので unquoted_ddl は呼ばれても None を返す。
/// 4 部以上の無引用の名前は、名前の解析だけで両方が別の文言を返しうる実例
/// （quoted_names は 3 つ目の `.` で、unquoted_ddl は ADD COLUMN の位置で。本物も名前を先に読む）。
#[tokio::test]
async fn quoted_names_の文言が無引用の_alter_table_の文言より先に決まる() {
    let harness = Harness::builder(select_response()).start().await;

    for (query, message) in [
        (
            r#"ALTER TABLE "t" ADD COLUMN m int"#,
            r#"line 1:13: no viable alternative at input 'ALTER TABLE "t"'"#.to_string(),
        ),
        (
            "ALTER TABLE a.b.c.d ADD COLUMN m int",
            "line 1:18: no viable alternative at input 'ALTER TABLE a.b.c.'".to_string(),
        ),
    ] {
        let (code, error) = harness
            .call("StartQueryExecution", json!({ "QueryString": query }))
            .await;

        assert_eq!(code, 400, "{query}: {error}");
        assert_eq!(error["Message"], message, "{query}");
        assert!(
            harness.trino_requests().is_empty(),
            "{query}: 実行は作らない"
        );
    }
}

/// 本物は CTAS でない無引用の `CREATE TABLE` も、Trino が構文として受ける形でも開始時に弾く
/// （2026-09-26 実測。#208 のフェーズ 2）。文言は ALTER TABLE と同じ出口（`unquoted_ddl::rejection` から
/// `create_table::rejection`）から返す。
#[tokio::test]
async fn 場所の無い_create_table_も本物の文言で開始時に弾き_実行を作らない() {
    let harness = Harness::builder(select_response()).start().await;

    for (query, message) in [
        (
            "CREATE TABLE t (n int)",
            "No location was specified for table. An S3 location must be specified",
        ),
        (
            "CREATE TABLE t (n int) WITH (format = 'PARQUET')",
            "line 1:29: no viable alternative at input 'CREATE TABLE t (n int) WITH ('",
        ),
        // 末尾の `;` を落とした文で判定する（2026-09-26 実測。#240）。
        (
            "CREATE TABLE t (n int);",
            "No location was specified for table. An S3 location must be specified",
        ),
    ] {
        let (code, error) = harness
            .call("StartQueryExecution", json!({ "QueryString": query }))
            .await;

        assert_eq!(code, 400, "{query}: {error}");
        assert_eq!(error["__type"], "InvalidRequestException", "{query}");
        assert_eq!(error["AthenaErrorCode"], "MALFORMED_QUERY", "{query}");
        assert_eq!(error["Message"], message, "{query}");
        assert_eq!(
            harness.syntax_checks().last(),
            Some(&query.trim_end_matches(';').to_string())
        );
        assert!(
            harness.trino_requests().is_empty(),
            "{query}: 実行は作らない"
        );
    }
}

/// Context の Catalog が S3 Tables のとき、1 部目が `awsdatacatalog` の無引用の 3 部の名前の `CREATE TABLE` は、
/// 本物が前後の空白を落とした文を付けて `Unsupported ddl with 2 catalogs` で弾く。1 部目が引用符付きなら
/// 既定の Context と同じ NV（2026-09-26 実測 i1〜i22。#224）。どれも Trino に問い合わせない。
/// 大文字混じりの `AwsDataCatalog` は名前空間を問い合わせる（tests/create_table_catalog.rs。#227）。
#[tokio::test]
async fn s3_tables_の_context_で_awsdatacatalog_の_3_部の_create_table_は_2_catalogs_で弾く() {
    let harness = Harness::builder(select_response())
        .catalog_map(&[("s3tablescatalog/b", "iceberg")])
        .start()
        .await;

    for (query, message) in [
        (
            "  CREATE TABLE awsdatacatalog.db.t\n(n int)\n",
            "Unsupported ddl with 2 catalogs: CREATE TABLE awsdatacatalog.db.t\n(n int)",
        ),
        (
            r#"CREATE TABLE "awsdatacatalog".db.t (n int)"#,
            r#"line 1:14: no viable alternative at input 'CREATE TABLE "awsdatacatalog"'"#,
        ),
        (
            r#"CREATE TABLE "s3tablescatalog/b".ns.t (n int)"#,
            r#"line 1:14: no viable alternative at input 'CREATE TABLE "s3tablescatalog/b"'"#,
        ),
    ] {
        let (code, error) = harness
            .call(
                "StartQueryExecution",
                json!({
                    "QueryString": query,
                    "QueryExecutionContext": { "Catalog": "s3tablescatalog/b", "Database": "ns" },
                }),
            )
            .await;

        assert_eq!(code, 400, "{query:?}: {error}");
        assert_eq!(error["__type"], "InvalidRequestException", "{query:?}");
        assert_eq!(error["AthenaErrorCode"], "MALFORMED_QUERY", "{query:?}");
        assert_eq!(error["Message"], message, "{query:?}");
        assert!(
            harness.trino_requests().is_empty(),
            "{query:?}: 実行は作らない"
        );
    }
}

/// Context の Catalog が S3 Tables なら、本物は Hive の `CREATE TABLE` の `LOCATION` と、LOCATION の無い `EXTERNAL` を
/// 開始時に本物の文言で弾く。Trino の文法にはどちらも無いので構文チェックも送らない。既定の Context では同じ文を
/// 今までどおり構文チェックに回し、Trino の文言を返す（2026-09-26 実測 n1〜n32。#229）。
#[tokio::test]
async fn s3_tables_の_context_では_hive_の_location_と_external_を構文チェックの前に弾く() {
    const LOCATION: &str = "CREATE TABLE awsdatacatalog.db.t (n int) LOCATION 's3://b/p/'";
    const EXTERNAL: &str = "CREATE EXTERNAL TABLE t (n int)";
    const TRINO_MESSAGE: &str =
        "line 1:43: mismatched input 'LOCATION'. Expecting: 'COMMENT', 'WITH', <EOF>";
    let harness = Harness::builder(select_response())
        .catalog_map(&[("s3tablescatalog/b", "iceberg")])
        .syntax_check_response(LOCATION, syntax_error(TRINO_MESSAGE))
        .start()
        .await;

    for (query, message) in [
        (
            LOCATION,
            "Table location can not be specified for tables hosted in S3 table buckets",
        ),
        (
            EXTERNAL,
            "External keyword not supported for table type ICEBERG",
        ),
        // 句・バッククォートが付いても同じ（2026-09-27 実測 v1・v9。#266）
        (
            "CREATE EXTERNAL TABLE t (n int) COMMENT 'x' ROW FORMAT DELIMITED FIELDS TERMINATED BY ','",
            "External keyword not supported for table type ICEBERG",
        ),
        (
            "CREATE EXTERNAL TABLE `t` (n int)",
            "External keyword not supported for table type ICEBERG",
        ),
    ] {
        let (code, error) = harness
            .call(
                "StartQueryExecution",
                json!({
                    "QueryString": query,
                    "QueryExecutionContext": { "Catalog": "S3TablesCatalog/b", "Database": "ns" },
                }),
            )
            .await;

        assert_eq!(code, 400, "{query}: {error}");
        assert_eq!(error["__type"], "InvalidRequestException", "{query}");
        assert_eq!(error["AthenaErrorCode"], "MALFORMED_QUERY", "{query}");
        assert_eq!(error["Message"], message, "{query}");
    }
    assert!(harness.syntax_checks().is_empty(), "構文チェックを送らない");
    assert!(harness.trino_requests().is_empty(), "実行は作らない");

    let (code, error) = harness
        .call(
            "StartQueryExecution",
            json!({
                "QueryString": LOCATION,
                "QueryExecutionContext": { "Catalog": "AwsDataCatalog", "Database": "db" },
            }),
        )
        .await;
    assert_eq!(code, 400, "{error}");
    assert_eq!(error["Message"], TRINO_MESSAGE);
    assert_eq!(harness.syntax_checks(), [LOCATION]);
}

/// S3 Tables の Context の LOCATION の無い `CREATE TABLE <1 部> (列) STORED AS <語>` は、本物は開始してから FAILED に
/// した。結果ファイルの本体も `.metadata` も置かない（2026-09-26 実測 n21・2026-09-27 実測 s15。#248）。Trino の文法に
/// STORED AS は無いので、構文チェックも本体も送らない。
#[tokio::test]
async fn s3_tables_の_context_の_location_の無い_stored_as_は開始して_failed_にする() {
    let harness = Harness::builder(select_response())
        .catalog_map(&[("s3tablescatalog/b", "iceberg")])
        .results_s3()
        .start()
        .await;

    for query in [
        "CREATE TABLE t (n int) STORED AS PARQUET",
        "CREATE TABLE t (n int) STORED AS ORC",
        // 2 部・`AwsDataCatalog` の 3 部・IF NOT EXISTS・句・列の並び無しでも同じ（2026-09-27 実測 w1・w2・w4・w5・w10。#266）
        "CREATE TABLE ns.t (n int) STORED AS PARQUET",
        "CREATE TABLE AwsDataCatalog.ns.t (n int) STORED AS PARQUET",
        "CREATE TABLE IF NOT EXISTS t (n int) COMMENT 'x' STORED AS PARQUET",
        "CREATE TABLE t STORED AS PARQUET",
    ] {
        let execution = harness
            .run_query(json!({
                "QueryString": query,
                "QueryExecutionContext": { "Catalog": "s3tablescatalog/b", "Database": "ns" },
                "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
            }))
            .await;
        let execution = &execution["QueryExecution"];
        let status = &execution["Status"];
        let reason = "Iceberg create table statement does not allow STORED AS/BY";
        assert_eq!(status["State"], "FAILED", "{query}: {execution}");
        assert_eq!(status["StateChangeReason"], reason);
        assert_eq!(
            status["AthenaError"],
            json!({
                "ErrorCategory": 2,
                "ErrorType": 1200,
                "Retryable": false,
                "ErrorMessage": reason
            })
        );
        assert_eq!(execution["StatementType"], "DDL");
        assert_eq!(execution["SubstatementType"], "CREATE_TABLE");
        // `AwsDataCatalog` の 3 部は、本物は Query から 1 部目を落とした（2026-09-26 実測 w2 の生データ。#271）。
        assert_eq!(execution["Query"], query.replace("AwsDataCatalog.", ""));
    }
    assert!(harness.syntax_checks().is_empty(), "構文チェックを送らない");
    assert!(harness.trino_requests().is_empty(), "本体を送らない");
    assert!(harness.s3_puts().is_empty(), "{:?}", harness.s3_puts());
}

/// 1 部目がちょうど小文字の `awsdatacatalog` の 3 部の STORED AS は、本物は開始時に 2 catalogs で弾いた（2026-09-26 実測
/// w3。#270）。Trino には STORED AS が無いので、構文チェックより前に弾く。
#[tokio::test]
async fn s3_tables_の_context_の小文字の_awsdatacatalog_の_3_部の_stored_as_は開始時に_2_catalogs_で弾く()
 {
    let harness = Harness::builder(select_response())
        .catalog_map(&[("s3tablescatalog/b", "iceberg")])
        .start()
        .await;
    let query = "CREATE TABLE awsdatacatalog.ns.t (n int) STORED AS PARQUET";
    let (status, body) = harness
        .call(
            "StartQueryExecution",
            json!({
                "QueryString": format!(" {query} "),
                "QueryExecutionContext": { "Catalog": "s3tablescatalog/b", "Database": "ns" }
            }),
        )
        .await;
    assert_eq!(status, 400, "{body}");
    assert_eq!(body["AthenaErrorCode"], "MALFORMED_QUERY");
    assert_eq!(
        body["Message"],
        format!("Unsupported ddl with 2 catalogs: {query}")
    );
    assert!(harness.syntax_checks().is_empty(), "構文チェックを送らない");
}

/// S3 Tables の Context の `table_type` が ICEBERG 以外（句・ちょうど小文字の `awsdatacatalog` の 3 部によらない）と、
/// `write_compression` の無い `compression_level` と、ちょうど小文字の `awsdatacatalog` の 3 部の Hive の句は、本物は開始時に
/// 弾いた（2026-09-27 実測 tp6・v1〜v6・a1〜a5・k5。#270）。どれも Trino に無い句なので構文チェックより前に弾く。
#[tokio::test]
async fn s3_tables_の_context_の_table_type_と_compression_level_と小文字の_3_部の句は開始時に弾く()
{
    let harness = Harness::builder(select_response())
        .catalog_map(&[("s3tablescatalog/b", "iceberg")])
        .start()
        .await;
    let only_iceberg = "Only ICEBERG table format is supported with S3 table buckets";
    let serde = "ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'";
    for (query, message) in [
        (
            "CREATE TABLE t (n int) TBLPROPERTIES ('table_type'='hive')".to_string(),
            only_iceberg.to_string(),
        ),
        (
            format!("CREATE TABLE t (n int) {serde} TBLPROPERTIES ('table_type'='HIVE')"),
            only_iceberg.to_string(),
        ),
        (
            "CREATE TABLE awsdatacatalog.ns.t (n int) TBLPROPERTIES ('table_type'='HIVE')"
                .to_string(),
            only_iceberg.to_string(),
        ),
        (
            "CREATE TABLE t (n int) TBLPROPERTIES ('compression_level'='3')".to_string(),
            "Compression codec must be defined when compression_level property is specified."
                .to_string(),
        ),
        (
            format!("CREATE TABLE awsdatacatalog.ns.t (n int) {serde}"),
            format!(
                "Unsupported ddl with 2 catalogs: CREATE TABLE awsdatacatalog.ns.t (n int) {serde}"
            ),
        ),
    ] {
        let (status, body) = harness
            .call(
                "StartQueryExecution",
                json!({
                    "QueryString": query,
                    "QueryExecutionContext": { "Catalog": "s3tablescatalog/b", "Database": "ns" }
                }),
            )
            .await;
        assert_eq!(status, 400, "{query}: {body}");
        assert_eq!(body["AthenaErrorCode"], "MALFORMED_QUERY", "{query}");
        assert_eq!(body["Message"], message, "{query}");
    }
    assert!(harness.syntax_checks().is_empty(), "構文チェックを送らない");
}

/// 名前空間が無くても、句の失敗が先（2026-09-27 実測 m1〜m6。#270）。名前空間は問い合わせない。句が無ければ今までどおり
/// 名前空間を確かめて `Cannot find or access the specified table`（m0。#231）。
#[tokio::test]
async fn s3_tables_の_context_で名前空間が無くても_hive_の句の失敗が先() {
    let harness = Harness::builder(select_response())
        .catalog_map(&[("s3tablescatalog/b", "iceberg")])
        .results_s3()
        .start()
        .await;
    for (query, reason) in [
        (
            "CREATE TABLE nope.t (n int) ROW FORMAT SERDE 'x'",
            "Iceberg create table statement does not allow ROW FORMAT",
        ),
        (
            "CREATE TABLE nope.t (n int) PARTITIONED BY (p int)",
            "Invalid PARTITIONED BY clause in Iceberg create table statement",
        ),
        (
            "CREATE TABLE AwsDataCatalog.nope.t (n int) TBLPROPERTIES ('a270'='b')",
            "Unsupported table property key: a270",
        ),
    ] {
        let execution = harness
            .run_query(json!({
                "QueryString": query,
                "QueryExecutionContext": { "Catalog": "s3tablescatalog/b", "Database": "ns" },
                "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
            }))
            .await;
        let execution = &execution["QueryExecution"];
        assert_eq!(
            execution["Status"]["State"], "FAILED",
            "{query}: {execution}"
        );
        assert_eq!(execution["Status"]["StateChangeReason"], reason, "{query}");
    }
    assert!(
        harness.trino_requests().is_empty(),
        "名前空間も本体も問い合わせない"
    );
}

/// ROW FORMAT・CLUSTERED BY・型付きの PARTITIONED BY・未知のキーの TBLPROPERTIES・列の並び無しも、本物は開始してから
/// 句ごとの文言で FAILED にし、結果ファイルを置かなかった（2026-09-26 実測 vc4・z6・z12・z13・z15〜z17、2026-09-27 実測
/// pn6・pr3。#270）。Trino には無い句なので構文チェックも本体も送らない。`AwsDataCatalog` の 3 部は Query から 1 部目を
/// 落とす（#271）。
#[tokio::test]
async fn s3_tables_の_context_の_location_の無い_hive_の句は句ごとの文言で開始して_failed_にする() {
    let harness = Harness::builder(select_response())
        .catalog_map(&[("s3tablescatalog/b", "iceberg")])
        .results_s3()
        .start()
        .await;

    let row_format = (
        "Iceberg create table statement does not allow ROW FORMAT",
        1200,
    );
    let clustered = (
        "Iceberg create table statement does not allow CLUSTERED BY",
        1200,
    );
    let partitioned = (
        "Invalid PARTITIONED BY clause in Iceberg create table statement",
        1006,
    );
    let unknown_key = ("Unsupported table property key: a270", 1200);
    let no_column = (
        "At least one column is required for Iceberg create table statement",
        1006,
    );
    let serde = "ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'";
    for (query, (reason, error_type)) in [
        (format!("CREATE TABLE t (n int) {serde}"), row_format),
        (
            "CREATE TABLE t (n int) ROW FORMAT DELIMITED FIELDS TERMINATED BY ','".to_string(),
            row_format,
        ),
        (format!("CREATE TABLE t {serde}"), row_format),
        (
            format!("CREATE TABLE AwsDataCatalog.ns.t (n int) {serde}"),
            row_format,
        ),
        (
            "CREATE TABLE t (n int) CLUSTERED BY (n) INTO 4 BUCKETS".to_string(),
            clustered,
        ),
        (
            format!("CREATE TABLE t (n int) CLUSTERED BY (n) INTO 4 BUCKETS {serde}"),
            clustered,
        ),
        (
            "CREATE TABLE t (n int) PARTITIONED BY (p int)".to_string(),
            partitioned,
        ),
        (
            "CREATE TABLE t (n int) TBLPROPERTIES ('a270'='b')".to_string(),
            unknown_key,
        ),
        (
            "CREATE TABLE t TBLPROPERTIES ('a270'='b')".to_string(),
            no_column,
        ),
    ] {
        let execution = harness
            .run_query(json!({
                "QueryString": query,
                "QueryExecutionContext": { "Catalog": "s3tablescatalog/b", "Database": "ns" },
                "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
            }))
            .await;
        let execution = &execution["QueryExecution"];
        let status = &execution["Status"];
        assert_eq!(status["State"], "FAILED", "{query}: {execution}");
        assert_eq!(status["StateChangeReason"], reason, "{query}");
        assert_eq!(
            status["AthenaError"],
            json!({
                "ErrorCategory": 2,
                "ErrorType": error_type,
                "Retryable": false,
                "ErrorMessage": reason
            }),
            "{query}"
        );
        assert_eq!(execution["StatementType"], "DDL");
        assert_eq!(execution["SubstatementType"], "CREATE_TABLE");
        assert_eq!(execution["Query"], query.replace("AwsDataCatalog.", ""));
        assert_eq!(execution["QueryExecutionContext"]["Database"], "ns");
    }
    assert!(harness.syntax_checks().is_empty(), "構文チェックを送らない");
    assert!(harness.trino_requests().is_empty(), "本体を送らない");
    assert!(harness.s3_puts().is_empty(), "{:?}", harness.s3_puts());
}

/// Context の Catalog が S3 Tables（`s3tablescatalog/<バケット>`。大文字小文字は区別しない）なら、本物は場所の無い
/// `CREATE TABLE` を作るので弾かずに実行する。列の `NOT NULL` の NV は同じく弾く（2026-09-26 実測 h1〜h7。#221）。
#[tokio::test]
async fn s3_tables_の_context_では場所の無い_create_table_を弾かずに実行する() {
    let harness = Harness::builder(select_response())
        .catalog_map(&[("s3tablescatalog/b", "iceberg")])
        .start()
        .await;

    for catalog in ["s3tablescatalog/b", "S3TablesCatalog/b"] {
        let (code, body) = harness
            .call(
                "StartQueryExecution",
                json!({
                    "QueryString": "CREATE TABLE t (n int)",
                    "QueryExecutionContext": { "Catalog": catalog },
                }),
            )
            .await;
        assert_eq!(code, 200, "{catalog}: {body}");
    }

    let (code, error) = harness
        .call(
            "StartQueryExecution",
            json!({
                "QueryString": "CREATE TABLE t (n int NOT NULL)",
                "QueryExecutionContext": { "Catalog": "s3tablescatalog/b" },
            }),
        )
        .await;
    assert_eq!(code, 400, "{error}");
    assert_eq!(
        error["Message"],
        "line 1:23: no viable alternative at input 'CREATE TABLE t (n int NOT'"
    );
}

/// 本物は引用符とコメントの外の `;` で区切り、空白だけでない片が 2 つ以上あれば、構文エラー・DESCRIBE の
/// 存在確認・No location・NV より先に弾く。`Got:` の後ろは受け取った文の末尾の空白だけを落としたもの
/// （2026-09-26 実測。#228）。
#[tokio::test]
async fn 引用符とコメントの外の_セミコロンの後ろに文かコメントがあれば構文チェックより先に弾く() {
    let harness = Harness::builder(select_response()).start().await;

    for (sql, got) in [
        ("SELECT 1; -- c", "SELECT 1; -- c"),
        ("SELECT 1; /* c */", "SELECT 1; /* c */"),
        ("SELECT 1;\n-- c", "SELECT 1;\n-- c"),
        ("SELECT 1;SELECT 2", "SELECT 1;SELECT 2"),
        ("SELECT 'a;b'; -- c", "SELECT 'a;b'; -- c"),
        ("  SELECT  1; -- c  ", "  SELECT  1; -- c"),
        ("SELECT 1\n; -- c\n", "SELECT 1\n; -- c"),
        ("SELEC 1; -- c", "SELEC 1; -- c"),
        ("DESCRIBE t; -- c", "DESCRIBE t; -- c"),
        (
            "CREATE TABLE t (n int NOT NULL); -- c",
            "CREATE TABLE t (n int NOT NULL); -- c",
        ),
    ] {
        let (code, error) = harness
            .call("StartQueryExecution", json!({ "QueryString": sql }))
            .await;
        assert_eq!(code, 400, "{sql:?}: {error}");
        assert_eq!(error["AthenaErrorCode"], "MALFORMED_QUERY", "{sql:?}");
        assert_eq!(
            error["Message"],
            format!("Only one sql statement is allowed. Got: {got}"),
            "{sql:?}"
        );
    }
    assert!(harness.syntax_checks().is_empty(), "構文チェックより先");
    assert!(harness.trino_requests().is_empty(), "実行は作らない");
}

/// 空白だけの片（`;;`、`; ;`、末尾の空白・改行・CRLF）と、文字列・引用符付きの名前・コメントの中の `;` は
/// 本物では複数の文にならない（2026-09-26 実測。#228）。構文チェックには `;` と前後の空白を落とした文を送る（#240）。
#[tokio::test]
async fn 空白だけの片や引用符とコメントの中の_セミコロンは複数の文に数えない() {
    let harness = Harness::builder(select_response()).start().await;
    let sqls = [
        "SELECT 1;;",
        "SELECT 1; ;",
        "SELECT 1;\r\n",
        "-- c\nSELECT 1;",
        "SELECT 1 -- c\n;",
        "SELECT 'a;b'",
        "SELECT 1 AS \"a;b\"",
        "SELECT 1 -- a;b",
        "SELECT 1 /* a;b */",
    ];

    for sql in sqls {
        let (code, body) = harness
            .call("StartQueryExecution", json!({ "QueryString": sql }))
            .await;
        assert_eq!(code, 200, "{sql:?}: {body}");
    }
    assert_eq!(
        harness.syntax_checks(),
        [
            "SELECT 1",
            "SELECT 1",
            "SELECT 1",
            "-- c\nSELECT 1",
            "SELECT 1 -- c",
            "SELECT 'a;b'",
            "SELECT 1 AS \"a;b\"",
            "SELECT 1 -- a;b",
            "SELECT 1 /* a;b */",
        ]
    );
}

/// 本物は `;` で区切った片のうち空白だけでない 1 つを、前後の空白を落として文にし、GetQueryExecution の
/// Query・構文エラー・実行はその文で決まる。`;` の無い文でも前後の空白は落ちる（2026-09-26 実測。#240）。
#[tokio::test]
async fn 末尾と先頭の_セミコロンと前後の空白を落とした文を構文チェックと実行と_query_に使う() {
    let harness = Harness::builder(select_response()).start().await;
    let cases = [
        ("SELECT 1;", "SELECT 1"),
        ("SELECT 1;;", "SELECT 1"),
        ("  SELECT 1  ;  ", "SELECT 1"),
        (";SELECT 1", "SELECT 1"),
        ("SELECT 1\t;", "SELECT 1"),
        ("SELECT 1  ", "SELECT 1"),
        ("\n\nSELECT 1\n", "SELECT 1"),
        ("-- c\nSELECT\n  1 ;\n", "-- c\nSELECT\n  1"),
    ];

    for (sql, statement) in cases {
        let execution = harness.run_query(json!({ "QueryString": sql })).await;
        assert_eq!(execution["QueryExecution"]["Query"], statement, "{sql:?}");
    }
    let statements: Vec<&str> = cases.iter().map(|(_, statement)| *statement).collect();
    assert_eq!(harness.syntax_checks(), statements);
    assert_eq!(harness.trino_sqls(), statements);
}

/// 本物は空白だけでない片が無い `;` だけの文を開始時に弾く（2026-09-26 実測。#240）。
#[tokio::test]
async fn セミコロンだけの文は_empty_sql_statement_で弾き構文チェックも実行もしない() {
    let harness = Harness::builder(select_response()).start().await;

    let (code, error) = harness
        .call("StartQueryExecution", json!({ "QueryString": ";" }))
        .await;

    assert_eq!(code, 400, "{error}");
    assert_eq!(error["__type"], "InvalidRequestException");
    assert_eq!(error["AthenaErrorCode"], "MALFORMED_QUERY");
    assert_eq!(error["Message"], "Empty sql statement: ;");
    assert!(harness.syntax_checks().is_empty());
    assert!(harness.trino_requests().is_empty());

    // `;` の無い空白だけの文は測っていないので、今までどおり受け取ったまま構文チェックに回す。
    harness
        .call("StartQueryExecution", json!({ "QueryString": "   " }))
        .await;
    assert_eq!(harness.syntax_checks(), ["   "]);
}
