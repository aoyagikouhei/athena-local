//! `DESCRIBE` の結果ファイルと `UpdateCount` は対象テーブルの形式で割れる（issue #160）。
//! 本物は Hive のテーブルへの `DESCRIBE` を application/octet-stream・素の protobuf（先頭は
//! QueryExecutionId）・`UpdateCount` 無しで置き、Iceberg のテーブルへの `DESCRIBE` は
//! binary/octet-stream・不透明な形式・`UpdateCount` 0（2026-09-24 実測。`SHOW CREATE TABLE` と同じ割れ方）。

mod common;

use common::{Harness, TRINO_QUERY_ID, execution_id};
use serde_json::{Value, json};

fn hex_of(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Trino の `DESCRIBE` の応答。
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

/// 形式と存在を 1 つにまとめた問い合わせ（`src/operation/table_format.rs` の `probe_sql` と同じ形。
/// tests/table_format.rs の写し。ずれればルートに当たらず Iceberg のテストが落ちる）。
fn probe_sql(catalog: &str, schema: &str, table: &str) -> String {
    format!(
        "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = '{catalog}'), (SELECT table_type FROM system.jdbc.tables WHERE table_cat = '{catalog}' AND table_schem = '{schema}' AND table_name = '{table}')"
    )
}

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

/// `DESCRIBE t` を、形式の問い合わせが `connector_name` を返す偽 Trino で実行する。
async fn run_describe(connector_name: &str, s3: bool) -> (Harness, Value) {
    run_describe_query("DESCRIBE t", connector_name, s3, describe_response()).await
}

/// `query`（`DESCRIBE t` か `DESC t`）を、形式の問い合わせが `connector_name` を返し、本体が
/// `response` を返す偽 Trino で実行する。
async fn run_describe_query(
    query: &str,
    connector_name: &str,
    s3: bool,
    response: Value,
) -> (Harness, Value) {
    let mut builder = Harness::builder(response.clone())
        .route(
            &probe_sql("default_catalog", "default_schema", "t"),
            probe_response(connector_name),
        )
        .route(query, response);
    if s3 {
        builder = builder.results_s3();
    }
    let harness = builder.start().await;
    let execution = harness
        .run_query(json!({
            "QueryString": query,
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        harness.trino_sqls(),
        [
            probe_sql("default_catalog", "default_schema", "t"),
            query.to_string()
        ]
    );
    (harness, execution)
}

async fn update_count_of(harness: &Harness, execution: &Value) -> Value {
    let (status, results) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": execution_id(execution) }),
        )
        .await;
    assert_eq!(status, 200, "{results}");
    results.get("UpdateCount").cloned().unwrap_or(Value::Null)
}

/// Trino の `SHOW CREATE TABLE` の応答（1 行 1 値の `Create Table`）。
fn show_create_response(ddl: &str) -> Value {
    json!({
        "columns": [{ "name": "Create Table", "type": "varchar" }],
        "data": [[ddl]]
    })
}

/// パーティションの無い Iceberg のテーブルの `SHOW CREATE TABLE`（Trino 482 の形）。
const UNPARTITIONED_DDL: &str = "CREATE TABLE default_catalog.default_schema.t (\n   n integer\n)\nWITH (\n   format = 'PARQUET',\n   format_version = 2,\n   location = 's3://warehouse/t'\n)";

/// Iceberg のテーブルへの `query` を、本体が `response`、`SHOW CREATE TABLE t` が `show_create` を返す
/// 偽 Trino で実行する。形式の問い合わせ・本体・`SHOW CREATE TABLE` の順に届く。
async fn run_iceberg_describe(
    query: &str,
    s3: bool,
    response: Value,
    show_create: Value,
) -> (Harness, Value) {
    let mut builder = Harness::builder(response.clone())
        .route(
            &probe_sql("default_catalog", "default_schema", "t"),
            probe_response("iceberg"),
        )
        .route(query, response)
        .route("SHOW CREATE TABLE t", show_create);
    if s3 {
        builder = builder.results_s3();
    }
    let harness = builder.start().await;
    let execution = harness
        .run_query(json!({
            "QueryString": query,
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        harness.trino_sqls(),
        [
            probe_sql("default_catalog", "default_schema", "t"),
            query.to_string(),
            "SHOW CREATE TABLE t".to_string()
        ]
    );
    (harness, execution)
}

/// `(n integer)` のパーティションの無い Iceberg のテーブルの本物の 6 行（2026-09-24 実測。#160 u1・#173 d2）。
fn unpartitioned_iceberg_rows() -> Vec<String> {
    [
        "# Table schema:\t\t",
        "# col_name\tdata_type\tcomment",
        "n\tint\t",
        "\t\t",
        "# Partition spec:\t\t",
        "# field_name\tfield_transform\tcolumn_name",
    ]
    .map(String::from)
    .into()
}

#[tokio::test]
async fn describe_は_iceberg_なら_update_count_0_で本体も_metadata_も_binary_で先頭がエンジン_id() {
    let (harness, execution) = run_iceberg_describe(
        "DESCRIBE t",
        true,
        describe_response(),
        show_create_response(UNPARTITIONED_DDL),
    )
    .await;
    let id = execution_id(&execution);
    assert_eq!(update_count_of(&harness, &execution).await, 0);
    // Iceberg の DESCRIBE も本物の 3 列と、詰めない 6 行にする（2026-09-24 実測。#160 u1・#173 d2）。
    let (values, results) = show_columns_results(&harness, &execution).await;
    assert_describe_columns(&results);
    let expected = unpartitioned_iceberg_rows();
    assert_eq!(values, expected);

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(puts[0].content_type.as_deref(), Some("binary/octet-stream"));
    // 本物の本体は 117 バイト（#160 u1）。
    assert_eq!(puts[0].body.len(), 117);
    assert_eq!(
        String::from_utf8(puts[0].body.clone()).unwrap(),
        expected.join("\n")
    );
    assert_eq!(puts[1].key, format!("athena/{id}.txt.metadata"));
    assert_eq!(puts[1].content_type.as_deref(), Some("binary/octet-stream"));
    assert!(
        hex_of(&puts[1].body).starts_with(&engine_id_field()),
        "{}",
        hex_of(&puts[1].body)
    );
}

/// 本物の d2 のテーブル（列 7 つ・パーティション `s`・`bucket(4, n)`・`day(ts)`）の Trino 482 の DESCRIBE。
fn d2_describe_response() -> Value {
    json!({
        "columns": [
            { "name": "Column", "type": "varchar" },
            { "name": "Type", "type": "varchar" },
            { "name": "Extra", "type": "varchar" },
            { "name": "Comment", "type": "varchar" }
        ],
        "data": [
            ["n", "integer", "", "abc"],
            ["s", "varchar", "", ""],
            ["ts", "timestamp(6)", "", ""],
            ["d", "decimal(10,2)", "", ""],
            ["arr", "array(varchar)", "", ""],
            ["st", "row(\"a\" integer)", "", ""],
            ["c21_aaaaaaaaaaaaaaaaa", "bigint", "", ""]
        ]
    })
}

/// d2 のテーブルの Trino 482 の `SHOW CREATE TABLE`。
fn d2_ddl(name: &str) -> String {
    format!(
        "CREATE TABLE {name} (\n   n integer COMMENT 'abc',\n   s varchar,\n   ts timestamp(6),\n   d decimal(10, 2),\n   arr array(varchar),\n   st ROW(a integer),\n   c21_aaaaaaaaaaaaaaaaa bigint\n)\nWITH (\n   format = 'PARQUET',\n   partitioning = ARRAY['s','bucket(n, 4)','day(ts)']\n)"
    )
}

/// 本物の d2 の DESCRIBE の 15 行。
/// 採取元: ~/athena-unmeasured-batch-measurements/run-20260924-115811/d2/d2-describe.results-1.json
/// （2026-09-24 実測。#173）。
fn d2_rows() -> Vec<String> {
    [
        "# Table schema:\t\t",
        "# col_name\tdata_type\tcomment",
        "n\tint\tabc",
        "s\tstring\t",
        "ts\ttimestamp\t",
        "d\tdecimal(10, 2)\t",
        "arr\tarray<string>\t",
        "st\tstruct<a: int>\t",
        "c21_aaaaaaaaaaaaaaaaa\tbigint\t",
        "\t\t",
        "# Partition spec:\t\t",
        "# field_name\tfield_transform\tcolumn_name",
        "s\tidentity\ts",
        "n_bucket\tbucket[4]\tn",
        "ts_day\tday\tts",
    ]
    .map(String::from)
    .into()
}

#[tokio::test]
async fn describe_は_iceberg_のパーティション付きのテーブルで本物の_d2_の_15_行を返す() {
    let (harness, execution) = run_iceberg_describe(
        "DESCRIBE t",
        true,
        d2_describe_response(),
        show_create_response(&d2_ddl("iceberg.default_schema.t")),
    )
    .await;
    let id = execution_id(&execution);
    let (values, results) = show_columns_results(&harness, &execution).await;
    assert_eq!(values, d2_rows());
    assert_describe_columns(&results);
    assert_eq!(results["UpdateCount"], 0);

    let puts = harness.s3_puts();
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(
        String::from_utf8(puts[0].body.clone()).unwrap(),
        d2_rows().join("\n")
    );
}

/// Iceberg のテーブルで Trino の `SHOW CREATE TABLE` が失敗しても、DESCRIBE 自体は成功のままで
/// パーティション行を出さない（ビューは形式の問い合わせの `table_type` で見分けて `SHOW CREATE TABLE` を
/// 投げないので、ここには来ない。#173 フェーズ 4）。
#[tokio::test]
async fn describe_は_show_create_table_が失敗しても成功のままでパーティション行を出さない() {
    let (harness, execution) = run_iceberg_describe(
        "DESCRIBE t",
        true,
        describe_response(),
        common::trino_error(
            "NOT_SUPPORTED",
            "Relation 'default_catalog.default_schema.t' is a view, not a table",
        ),
    )
    .await;
    let (values, results) = show_columns_results(&harness, &execution).await;
    assert_eq!(values, unpartitioned_iceberg_rows());
    assert_describe_columns(&results);
}

/// `DESC t` も `DESCRIBE t` と同じく `SHOW CREATE TABLE t` を問い合わせてパーティション行を足す。
#[tokio::test]
async fn desc_は_iceberg_でも_describe_と同じ行を返す() {
    let (harness, execution) = run_iceberg_describe(
        "DESC t",
        true,
        d2_describe_response(),
        show_create_response(&d2_ddl("iceberg.default_schema.t")),
    )
    .await;
    let (values, results) = show_columns_results(&harness, &execution).await;
    assert_eq!(values, d2_rows());
    assert_describe_columns(&results);
}

/// `SHOW CREATE TABLE` は元の SQL の名前をそのまま使い、本体と同じく引用符付きの修飾名に別名を当てる
/// （`catalog::alias_qualified_names` の空白詰めのまま）。
#[tokio::test]
async fn describe_は_iceberg_の引用符付きの修飾名にも別名を当てて_show_create_table_を問い合わせる()
{
    const S3_TABLES: &str = "s3tablescatalog/b";
    // 元の引用符付き識別子 19 文字 - 別名を引用符で包んだ "iceberg" 9 文字 = 空白 10 個。
    let aliased = format!("\"iceberg\"{}.ns.t", " ".repeat(10));
    let query = format!("DESCRIBE \"{S3_TABLES}\".ns.t");
    let body = format!("DESCRIBE {aliased}");
    let show_create = format!("SHOW CREATE TABLE {aliased}");
    let harness = Harness::builder(d2_describe_response())
        .catalog_map(&[(S3_TABLES, "iceberg")])
        .route(&probe_sql("iceberg", "ns", "t"), probe_response("iceberg"))
        .route(&body, d2_describe_response())
        .route(&show_create, show_create_response(&d2_ddl("iceberg.ns.t")))
        .start()
        .await;
    let execution = harness
        .run_query(json!({
            "QueryString": query,
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        harness.trino_sqls(),
        [probe_sql("iceberg", "ns", "t"), body, show_create]
    );
    let (values, _) = show_columns_results(&harness, &execution).await;
    assert_eq!(values, d2_rows());
}

#[tokio::test]
async fn describe_は_hive_なら今までどおり_update_count_無しで_application_で先頭が実行_id() {
    let (harness, execution) = run_describe("hive", true).await;
    let id = execution_id(&execution);
    assert_eq!(update_count_of(&harness, &execution).await, Value::Null);

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(
        puts[0].content_type.as_deref(),
        Some("application/octet-stream")
    );
    assert_eq!(
        puts[1].content_type.as_deref(),
        Some("application/octet-stream")
    );
    assert!(
        hex_of(&puts[1].body).starts_with(&format!("0a24{}", hex_of(id.as_bytes()))),
        "{}",
        hex_of(&puts[1].body)
    );
}

/// UpdateCount が判定を使うので、結果ファイルを書かない none でも DESCRIBE は形式を問い合わせる。
#[tokio::test]
async fn 結果_s3_が無効でも_describe_は形式を問い合わせ_iceberg_なら_update_count_が_0() {
    let (harness, execution) = run_iceberg_describe(
        "DESCRIBE t",
        false,
        d2_describe_response(),
        show_create_response(&d2_ddl("iceberg.default_schema.t")),
    )
    .await;
    assert_eq!(update_count_of(&harness, &execution).await, 0);
    // 行の形にも形式と `SHOW CREATE TABLE` を使うので、S3 が無効でも Iceberg の形になる。
    let (values, _) = show_columns_results(&harness, &execution).await;
    assert_eq!(values, d2_rows());
    assert!(harness.s3_puts().is_empty());
}

/// `SHOW COLUMNS FROM t` を、形式の問い合わせが `connector_name` を返す偽 Trino で実行する。
/// Trino の `SHOW COLUMNS` は `DESCRIBE` と同じ 4 列（`Column`／`Type`／`Extra`／`Comment`）を返す。
async fn run_show_columns(connector_name: &str, s3: bool, response: Value) -> (Harness, Value) {
    let mut builder = Harness::builder(response.clone())
        .route(
            &probe_sql("default_catalog", "default_schema", "t"),
            probe_response(connector_name),
        )
        .route("SHOW COLUMNS FROM t", response);
    if s3 {
        builder = builder.results_s3();
    }
    let harness = builder.start().await;
    let execution = harness
        .run_query(json!({
            "QueryString": "SHOW COLUMNS FROM t",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        harness.trino_sqls(),
        [
            probe_sql("default_catalog", "default_schema", "t"),
            "SHOW COLUMNS FROM t".to_string()
        ]
    );
    (harness, execution)
}

/// GetQueryResults の各行の値（1 行 1 値であることも確かめる）と、応答全体。
async fn show_columns_results(harness: &Harness, execution: &Value) -> (Vec<String>, Value) {
    let (status, results) = harness
        .call(
            "GetQueryResults",
            json!({ "QueryExecutionId": execution_id(execution) }),
        )
        .await;
    assert_eq!(status, 200, "{results}");
    let values = results["ResultSet"]["Rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| {
            let data = row["Data"].as_array().unwrap();
            assert_eq!(data.len(), 1, "1 行 1 値: {row}");
            data[0]["VarCharValue"].as_str().unwrap().to_string()
        })
        .collect();
    (values, results)
}

/// 本物の SHOW COLUMNS の列は `field`／string の 1 列（Precision・Scale 0、CaseSensitive false。
/// 2026-09-16／2026-09-24 実測。#173）。
fn assert_field_column(results: &Value) {
    let columns = results["ResultSet"]["ResultSetMetadata"]["ColumnInfo"]
        .as_array()
        .unwrap();
    assert_eq!(columns.len(), 1, "{results}");
    assert_eq!(columns[0]["Name"], "field");
    assert_eq!(columns[0]["Label"], "field");
    assert_eq!(columns[0]["Type"], "string");
    assert_eq!(columns[0]["Precision"], 0);
    assert_eq!(columns[0]["Scale"], 0);
    assert_eq!(columns[0]["CaseSensitive"], false);
}

#[tokio::test]
async fn show_columns_は_hive_なら_field_の_1_列で列名を_20_桁に左詰めする() {
    let (harness, execution) = run_show_columns("hive", true, describe_response()).await;
    let id = execution_id(&execution);
    let (values, results) = show_columns_results(&harness, &execution).await;

    // 4 列の応答の `Column` だけを使い、20 桁に満たない名前は右を空白で埋める（2026-09-16 実測）。
    let padded = format!("n{}", " ".repeat(19));
    assert_eq!(values, std::slice::from_ref(&padded));
    assert_field_column(&results);
    assert_eq!(results["UpdateCount"], 0);

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(puts[0].content_type.as_deref(), Some("binary/octet-stream"));
    assert_eq!(String::from_utf8(puts[0].body.clone()).unwrap(), padded);
}

#[tokio::test]
async fn show_columns_は_iceberg_なら列名を詰めない() {
    let (harness, execution) = run_show_columns("iceberg", true, describe_response()).await;
    let (values, results) = show_columns_results(&harness, &execution).await;

    // Iceberg のテーブルは詰めない（2026-09-24 実測。#173）。
    assert_eq!(values, ["n"]);
    assert_field_column(&results);
    assert_eq!(results["UpdateCount"], 0);

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(puts[0].content_type.as_deref(), Some("binary/octet-stream"));
    assert_eq!(puts[0].body, b"n");
}

/// 行の形に形式が要るので、結果ファイルを書かない none でも SHOW COLUMNS は形式を問い合わせる。
#[tokio::test]
async fn 結果_s3_が無効でも_show_columns_は形式を問い合わせ_iceberg_なら詰めない() {
    let (harness, execution) = run_show_columns("iceberg", false, describe_response()).await;
    let (values, _) = show_columns_results(&harness, &execution).await;
    assert_eq!(values, ["n"]);
    assert!(harness.s3_puts().is_empty());
}

#[tokio::test]
async fn show_columns_は_20_文字以上の列名を詰めずに_txt_では行を改行でつなぐ() {
    // 20 桁ちょうど・それを超える名前はそのまま（2026-09-16 実測。#173）。
    let twenty = "abcdefghijklmnopqrst";
    let twenty_one = "abcdefghijklmnopqrstu";
    let mut response = describe_response();
    response["data"] = json!([
        ["n", "integer", "", ""],
        [twenty, "varchar", "", ""],
        [twenty_one, "varchar", "", ""]
    ]);
    let (harness, execution) = run_show_columns("hive", true, response).await;
    let (values, _) = show_columns_results(&harness, &execution).await;

    let expected = [
        format!("n{}", " ".repeat(19)),
        twenty.to_string(),
        twenty_one.to_string(),
    ];
    assert_eq!(values, expected);
    let puts = harness.s3_puts();
    assert_eq!(
        String::from_utf8(puts[0].body.clone()).unwrap(),
        expected.join("\n")
    );
}

/// Trino の DESCRIBE の応答で、`n` にコメント `abc`、パーティション列 `p` を持つ Hive のテーブル。
fn partitioned_describe_response() -> Value {
    json!({
        "columns": [
            { "name": "Column", "type": "varchar" },
            { "name": "Type", "type": "varchar" },
            { "name": "Extra", "type": "varchar" },
            { "name": "Comment", "type": "varchar" }
        ],
        "data": [
            ["n", "integer", "", "abc"],
            ["p", "varchar", "partition key", ""]
        ]
    })
}

/// `partitioned_describe_response` に対する本物の形の行（2026-09-24 実測 d1・d6。#173）。
/// 列名・型・コメントを 20 桁に左詰めし、パーティション列は上半分と見出し行群の下の両方に出る。
fn partitioned_describe_rows() -> Vec<String> {
    let p = format!(
        "p{}\tstring{}\t{}",
        " ".repeat(19),
        " ".repeat(14),
        " ".repeat(20)
    );
    vec![
        format!(
            "n{}\tint{}\tabc{}",
            " ".repeat(19),
            " ".repeat(17),
            " ".repeat(17)
        ),
        p.clone(),
        "\t \t ".to_string(),
        "# Partition Information\t \t ".to_string(),
        format!(
            "# col_name{}\tdata_type{}\tcomment{}",
            " ".repeat(12),
            " ".repeat(11),
            " ".repeat(13)
        ),
        "\t \t ".to_string(),
        p,
    ]
}

/// 本物の DESCRIBE の列は Hive・Iceberg のテーブルとも `col_name`／`data_type`／`comment` の 3 列で、どれも string
/// （Precision・Scale 0、CaseSensitive false。2026-09-17／2026-09-24 実測 d1・d2。#173）。
fn assert_describe_columns(results: &Value) {
    let columns = results["ResultSet"]["ResultSetMetadata"]["ColumnInfo"]
        .as_array()
        .unwrap();
    let names: Vec<&str> = columns
        .iter()
        .map(|column| column["Name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["col_name", "data_type", "comment"], "{results}");
    for column in columns {
        assert_eq!(column["Label"], column["Name"]);
        assert_eq!(column["Type"], "string");
        assert_eq!(column["Precision"], 0);
        assert_eq!(column["Scale"], 0);
        assert_eq!(column["CaseSensitive"], false);
    }
}

#[tokio::test]
async fn describe_は_hive_のパーティション付きのテーブルで本物の_3_列と見出し行群を返す() {
    let (harness, execution) =
        run_describe_query("DESCRIBE t", "hive", true, partitioned_describe_response()).await;
    let id = execution_id(&execution);
    let (values, results) = show_columns_results(&harness, &execution).await;

    let expected = partitioned_describe_rows();
    assert_eq!(values, expected);
    assert_describe_columns(&results);
    assert!(results.get("UpdateCount").is_none(), "{results}");

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(
        puts[0].content_type.as_deref(),
        Some("application/octet-stream")
    );
    assert_eq!(
        String::from_utf8(puts[0].body.clone()).unwrap(),
        expected.join("\n")
    );
}

/// 本物は `DESC t` を `DESCRIBE t` と同じ種類・列・行で返す（2026-09-23／24 実測。#70 f1-desc・#173 d6）。
#[tokio::test]
async fn desc_は_describe_と同じく形式を問い合わせて同じ行を返し_describe_table_になる() {
    let (harness, execution) =
        run_describe_query("DESC t", "hive", true, partitioned_describe_response()).await;
    assert_eq!(execution["QueryExecution"]["StatementType"], "UTILITY");
    assert_eq!(
        execution["QueryExecution"]["SubstatementType"],
        "DESCRIBE_TABLE"
    );
    let (values, results) = show_columns_results(&harness, &execution).await;
    assert_eq!(values, partitioned_describe_rows());
    assert_describe_columns(&results);
    assert!(results.get("UpdateCount").is_none(), "{results}");
}

/// ビュー `CREATE VIEW v AS SELECT 1 AS n, 'a' AS s` への Trino の `DESCRIBE`／`SHOW COLUMNS`（4 列）。
fn view_describe_response() -> Value {
    json!({
        "columns": [
            { "name": "Column", "type": "varchar" },
            { "name": "Type", "type": "varchar" },
            { "name": "Extra", "type": "varchar" },
            { "name": "Comment", "type": "varchar" }
        ],
        "data": [
            ["n", "integer", "", ""],
            ["s", "varchar(1)", "", ""]
        ]
    })
}

/// 対象がビューで、カタログの形式が `connector_name` である形式の問い合わせの応答。
fn view_probe_response(connector_name: &str) -> Value {
    json!({
        "columns": [
            { "name": "_col0", "type": "varchar" },
            { "name": "_col1", "type": "varchar" }
        ],
        "data": [[connector_name, "VIEW"]]
    })
}

/// ビュー `v` への `query` を、形式の問い合わせが `connector_name` とビューを返す偽 Trino で実行する。
/// ビューには `SHOW CREATE TABLE` を投げない（形式の問い合わせ・本体の 2 本だけ）。
async fn run_view(query: &str, connector_name: &str) -> (Harness, Value) {
    let harness = Harness::builder(view_describe_response())
        .route(
            &probe_sql("default_catalog", "default_schema", "v"),
            view_probe_response(connector_name),
        )
        .route(query, view_describe_response())
        .results_s3()
        .start()
        .await;
    let execution = harness
        .run_query(json!({
            "QueryString": query,
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        harness.trino_sqls(),
        [
            probe_sql("default_catalog", "default_schema", "v"),
            query.to_string()
        ]
    );
    (harness, execution)
}

/// 本物のビューへの DESCRIBE／SHOW COLUMNS の形（2026-09-24 実測 d5。#173）。
/// 採取元: ~/athena-unmeasured-batch-measurements/run-20260924-115811/d5/d5-describe.results-1.json と
/// d5-show-columns.results-1.json。列は `column`／`type` の varchar（Precision・Scale 0、CaseSensitive false）、
/// 行は 1 値で `<列名>\t<Trino の型>`（詰め無し）、`.txt` は 22 バイトの binary、`.metadata` も binary で
/// 先頭はエンジン ID、UpdateCount 0、完了後の SubstatementType は `DESC_VIEW`。
async fn assert_view_result(harness: &Harness, execution: &Value) {
    let id = execution_id(execution);
    assert_eq!(execution["QueryExecution"]["StatementType"], "UTILITY");
    assert_eq!(execution["QueryExecution"]["SubstatementType"], "DESC_VIEW");

    let (values, results) = show_columns_results(harness, execution).await;
    let expected = ["n\tinteger", "s\tvarchar(1)"];
    assert_eq!(values, expected);
    assert_eq!(results["UpdateCount"], 0);
    let columns = results["ResultSet"]["ResultSetMetadata"]["ColumnInfo"]
        .as_array()
        .unwrap();
    let names: Vec<&str> = columns
        .iter()
        .map(|column| column["Name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["column", "type"], "{results}");
    for column in columns {
        assert_eq!(column["Label"], column["Name"]);
        assert_eq!(column["Type"], "varchar");
        assert_eq!(column["Precision"], 0);
        assert_eq!(column["Scale"], 0);
        assert_eq!(column["CaseSensitive"], false);
        assert_eq!(column["Nullable"], "UNKNOWN");
        assert_eq!(column["CatalogName"], "hive");
    }

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(puts[0].content_type.as_deref(), Some("binary/octet-stream"));
    assert_eq!(puts[0].body.len(), 22);
    assert_eq!(
        String::from_utf8(puts[0].body.clone()).unwrap(),
        expected.join("\n")
    );
    assert_eq!(puts[1].key, format!("athena/{id}.txt.metadata"));
    assert_eq!(puts[1].content_type.as_deref(), Some("binary/octet-stream"));
    assert!(
        hex_of(&puts[1].body).starts_with(&engine_id_field()),
        "{}",
        hex_of(&puts[1].body)
    );
}

#[tokio::test]
async fn describe_は_hive_カタログのビューなら_column_と_type_の_2_列で_desc_view_になる() {
    let (harness, execution) = run_view("DESCRIBE v", "hive").await;
    assert_view_result(&harness, &execution).await;
}

#[tokio::test]
async fn show_columns_もビューなら_describe_と同じ形で_desc_view_になる() {
    let (harness, execution) = run_view("SHOW COLUMNS FROM v", "hive").await;
    assert_view_result(&harness, &execution).await;
}

/// 本物は Iceberg のカタログ（Glue）のビューも同じ形で返す。athena-local はカタログの形式によらず
/// `table_type` で見分け、`SHOW CREATE TABLE` も投げない（`run_view` が確かめる）。
#[tokio::test]
async fn describe_は_iceberg_カタログのビューでも同じ形で_show_create_table_を投げない() {
    let (harness, execution) = run_view("DESCRIBE v", "iceberg").await;
    assert_view_result(&harness, &execution).await;
}

#[tokio::test]
async fn desc_もビューなら_describe_と同じ形で_desc_view_になる() {
    let (harness, execution) = run_view("DESC v", "hive").await;
    assert_view_result(&harness, &execution).await;
}

/// `DESC_VIEW` は完了時に形式の問い合わせから決まるので、完了前（RUNNING）は SQL だけで決まる
/// `DESCRIBE_TABLE` のまま（docs/caveats.md）。
#[tokio::test]
async fn ビューへの_describe_も完了前は_describe_table_のまま() {
    let harness = Harness::builder(view_describe_response())
        .endless()
        .route(
            &probe_sql("default_catalog", "default_schema", "v"),
            view_probe_response("hive"),
        )
        .start()
        .await;
    let id = harness
        .start_query(json!({
            "QueryString": "DESCRIBE v",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    common::wait_for("本体の nextUri を辿り始める", || {
        harness.trino_calls().iter().any(|call| call == "GET /next")
    })
    .await;

    let (status, execution) = harness
        .call("GetQueryExecution", json!({ "QueryExecutionId": id }))
        .await;
    assert_eq!(status, 200, "{execution}");
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "RUNNING");
    assert_eq!(
        execution["QueryExecution"]["SubstatementType"],
        "DESCRIBE_TABLE"
    );

    let (status, _) = harness
        .call("StopQueryExecution", json!({ "QueryExecutionId": id }))
        .await;
    assert_eq!(status, 200);
}
