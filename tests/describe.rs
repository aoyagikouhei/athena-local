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
        "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = '{catalog}'), (SELECT count(*) FROM system.jdbc.tables WHERE table_cat = '{catalog}' AND table_schem = '{schema}' AND table_name = '{table}')"
    )
}

fn probe_response(connector_name: &str) -> Value {
    json!({
        "columns": [
            { "name": "_col0", "type": "varchar" },
            { "name": "_col1", "type": "bigint" }
        ],
        "data": [[connector_name, 1]]
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

#[tokio::test]
async fn describe_は_iceberg_なら_update_count_0_で本体も_metadata_も_binary_で先頭がエンジン_id() {
    let (harness, execution) = run_describe("iceberg", true).await;
    let id = execution_id(&execution);
    assert_eq!(update_count_of(&harness, &execution).await, 0);
    // Iceberg の DESCRIBE の行はまだ作り直さず、Trino の 4 列のまま（#173 フェーズ 3 で作り直す）。
    let (status, results) = harness
        .call("GetQueryResults", json!({ "QueryExecutionId": &id }))
        .await;
    assert_eq!(status, 200, "{results}");
    let names: Vec<&str> = results["ResultSet"]["ResultSetMetadata"]["ColumnInfo"]
        .as_array()
        .unwrap()
        .iter()
        .map(|column| column["Name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["Column", "Type", "Extra", "Comment"]);

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(puts[0].content_type.as_deref(), Some("binary/octet-stream"));
    assert_eq!(puts[1].key, format!("athena/{id}.txt.metadata"));
    assert_eq!(puts[1].content_type.as_deref(), Some("binary/octet-stream"));
    assert!(
        hex_of(&puts[1].body).starts_with(&engine_id_field()),
        "{}",
        hex_of(&puts[1].body)
    );
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
    let (harness, execution) = run_describe("iceberg", false).await;
    assert_eq!(update_count_of(&harness, &execution).await, 0);
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

/// 本物の Hive のテーブルの DESCRIBE の列は `col_name`／`data_type`／`comment` の 3 列で、どれも string
/// （Precision・Scale 0、CaseSensitive false。2026-09-17／2026-09-24 実測。#173）。
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
