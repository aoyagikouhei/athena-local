//! `DESCRIBE EXTENDED`／`FORMATTED`（名前だけ。列・PARTITION 指定はフェーズ 4）を本物どおり実行する
//! （2026-09-27 実測。#275）。受け取った文は Trino に送らず、`DESCRIBE <名前>` と（Iceberg の FORMATTED
//! だけ）追加の問い合わせを別に投げて行を組み立てる（D3）。

mod common;

use common::{Harness, execution_id, trino_error};
use serde_json::{Value, json};

/// 形式と存在を 1 つにまとめた問い合わせ（`src/operation/table_format.rs` の `probe_sql` と同じ形。
/// tests/describe.rs の写し）。
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

fn missing_probe_response(connector_name: &str) -> Value {
    json!({
        "columns": [
            { "name": "_col0", "type": "varchar" },
            { "name": "_col1", "type": "varchar" }
        ],
        "data": [[connector_name, null]]
    })
}

fn view_probe_response(connector_name: &str) -> Value {
    json!({
        "columns": [
            { "name": "_col0", "type": "varchar" },
            { "name": "_col1", "type": "varchar" }
        ],
        "data": [[connector_name, "VIEW"]]
    })
}

/// `SHOW TABLES FROM "<catalog>"."<schema>" LIKE ''`（名前空間の有無の確認）。
fn schema_probe_sql(catalog: &str, schema: &str) -> String {
    format!("SHOW TABLES FROM \"{catalog}\".\"{schema}\" LIKE ''")
}

/// Trino の DESCRIBE の応答（`Column`／`Type`／`Extra`／`Comment`）。
fn describe_rows(rows: &[[&str; 4]]) -> Value {
    json!({
        "columns": [
            { "name": "Column", "type": "varchar" },
            { "name": "Type", "type": "varchar" },
            { "name": "Extra", "type": "varchar" },
            { "name": "Comment", "type": "varchar" }
        ],
        "data": rows
    })
}

async fn values_and_results(harness: &Harness, execution: &Value) -> (Vec<String>, Value) {
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

fn assert_describe_columns(results: &Value) {
    let columns = results["ResultSet"]["ResultSetMetadata"]["ColumnInfo"]
        .as_array()
        .unwrap();
    let names: Vec<&str> = columns
        .iter()
        .map(|column| column["Name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["col_name", "data_type", "comment"], "{results}");
}

/// 本物の e_h（Hive 表、列コメント付き。2026-09-27 実測。describe_detail/tests.rs の `extended` の
/// 期待値と同じ）。
#[tokio::test]
async fn extended_は_hive_表で成功し_db_を落とした_query_を返す() {
    let probe = probe_sql("default_catalog", "db", "h");
    let harness = Harness::builder(describe_rows(&[
        ["n", "integer", "", ""],
        ["s", "varchar", "", "the s column"],
    ]))
    .route(&probe, probe_response("hive"))
    .route(
        "DESCRIBE h",
        describe_rows(&[
            ["n", "integer", "", ""],
            ["s", "varchar", "", "the s column"],
        ]),
    )
    .results_s3()
    .start()
    .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DESCRIBE  EXTENDED db.h",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(execution["QueryExecution"]["Query"], "DESCRIBE EXTENDED h");
    assert_eq!(
        execution["QueryExecution"]["QueryExecutionContext"]["Database"],
        "db"
    );
    assert_eq!(execution["QueryExecution"]["StatementType"], "UTILITY");
    assert_eq!(
        execution["QueryExecution"]["SubstatementType"],
        "DESCRIBE_TABLE"
    );

    assert_eq!(
        harness.trino_sqls(),
        [probe.clone(), probe, "DESCRIBE h".to_string()]
    );
    assert!(harness.syntax_checks().is_empty(), "構文チェックへ進まない");

    let (values, results) = values_and_results(&harness, &execution).await;
    let expected = [
        "n                   \tint                 \t                    ",
        "s                   \tstring              \tthe s column        ",
        "\t \t ",
        "Detailed Table Information\tTable(tableName:h, dbName:db, lastAccessTime:0, retention:0, sd:StorageDescriptor(cols:[FieldSchema(name:n, type:int, comment:null), FieldSchema(name:s, type:string, comment:the s column)], compressed:false, bucketCols:[], sortCols:[], parameters:{}, storedAsSubDirectories:false), partitionKeys:[], tableType:EXTERNAL_TABLE)\t",
    ];
    assert_eq!(values, expected);
    assert_describe_columns(&results);
    assert!(results.get("UpdateCount").is_none(), "{results}");

    let id = execution_id(&execution);
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
    assert_eq!(puts[1].key, format!("athena/{id}.txt.metadata"));
}

/// 本物の f_hp（パーティション付き Hive 表。2026-09-27 実測）。上半分にパーティション列が出ない。
#[tokio::test]
async fn formatted_は_hive_のパーティション付き表でパーティション列を上半分から除く() {
    let probe = probe_sql("default_catalog", "db", "hp");
    let rows = describe_rows(&[
        ["n", "integer", "", ""],
        ["p", "varchar(1)", "partition key", ""],
    ]);
    let harness = Harness::builder(rows.clone())
        .route(&probe, probe_response("hive"))
        .route("DESCRIBE hp", rows)
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DESCRIBE FORMATTED db.hp",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        execution["QueryExecution"]["Query"],
        "DESCRIBE FORMATTED hp"
    );
    assert_eq!(
        harness.trino_sqls(),
        [probe.clone(), probe, "DESCRIBE hp".to_string()]
    );

    let (values, _) = values_and_results(&harness, &execution).await;
    let expected = [
        "# col_name            \tdata_type           \tcomment             ",
        "\t \t ",
        "n                   \tint                 \t                    ",
        "\t \t ",
        "# Partition Information\t \t ",
        "# col_name            \tdata_type           \tcomment             ",
        "\t \t ",
        "p                   \tvarchar(1)          \t                    ",
        "\t \t ",
        "# Detailed Table Information\t \t ",
        "Database:           \tdb                  \t ",
        "LastAccessTime:     \tUNKNOWN             \t ",
        "Protect Mode:       \tNone                \t ",
        "Retention:          \t0                   \t ",
        "Table Type:         \tEXTERNAL_TABLE      \t ",
        "\t \t ",
        "# Storage Information\t \t ",
        "Compressed:         \tNo                  \t ",
        "Bucket Columns:     \t[]                  \t ",
        "Sort Columns:       \t[]                  \t ",
    ];
    assert_eq!(values, expected);
    // 上半分（見出しの直後から最初の空行まで）にパーティション列 `p` が出ない。
    assert!(!values[2].starts_with('p'), "{:?}", values);
}

/// 本物の e_v（ビュー。2026-09-27 実測）。application/octet-stream・UpdateCount 無し・
/// SubstatementType が DESCRIBE_TABLE（無印の DESCRIBE の DescribeView・binary・0 と違う。計画攻撃 A2）。
#[tokio::test]
async fn extended_はビューで成功し_desc_view_にならない() {
    let probe = probe_sql("default_catalog", "db", "v");
    let rows = describe_rows(&[["n", "integer", "", ""], ["s", "varchar(1)", "", ""]]);
    let harness = Harness::builder(rows.clone())
        .route(&probe, view_probe_response("hive"))
        .route("DESCRIBE v", rows)
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DESCRIBE EXTENDED db.v",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        execution["QueryExecution"]["SubstatementType"],
        "DESCRIBE_TABLE"
    );
    assert_eq!(
        harness.trino_sqls(),
        [probe.clone(), probe, "DESCRIBE v".to_string()]
    );

    let (values, results) = values_and_results(&harness, &execution).await;
    let expected = [
        "n                   \tint                 \t                    ",
        "s                   \tvarchar(1)          \t                    ",
        "\t \t ",
        "Detailed Table Information\tTable(tableName:v, dbName:db, lastAccessTime:0, retention:0, sd:StorageDescriptor(cols:[FieldSchema(name:n, type:int, comment:null), FieldSchema(name:s, type:varchar(1), comment:null)], compressed:false, bucketCols:[], sortCols:[], parameters:{}, storedAsSubDirectories:false), partitionKeys:[], tableType:VIRTUAL_VIEW)\t",
    ];
    assert_eq!(values, expected);
    assert!(results.get("UpdateCount").is_none(), "{results}");

    let puts = harness.s3_puts();
    assert_eq!(
        puts[0].content_type.as_deref(),
        Some("application/octet-stream")
    );
    assert_eq!(
        puts[1].content_type.as_deref(),
        Some("application/octet-stream")
    );
}

/// 本物の f_i（Iceberg 表。2026-09-27 実測）。binary/octet-stream・UpdateCount 0、
/// `Name:`・`Location:`・`format`・`write.format.default` の行を持つ。
#[tokio::test]
async fn formatted_は_iceberg_表で成功し_name_と_2_つの_properties_節を持つ() {
    let probe = probe_sql("default_catalog", "db", "t");
    let rows = describe_rows(&[["n", "integer", "", ""], ["p", "varchar", "", ""]]);
    let ddl = "CREATE TABLE default_catalog.db.t (\n   n integer,\n   p varchar\n)\nWITH (\n   format = 'PARQUET',\n   partitioning = ARRAY['p'],\n   location = 's3://bucket/prefix'\n)";
    let properties_sql = "SELECT value FROM \"default_catalog\".\"db\".\"t$properties\" WHERE key = 'write.format.default'";
    let harness = Harness::builder(rows.clone())
        .route(&probe, probe_response("iceberg"))
        .route("DESCRIBE t", rows)
        .route(
            "SHOW CREATE TABLE t",
            json!({ "columns": [{ "name": "Create Table", "type": "varchar" }], "data": [[ddl]] }),
        )
        .route(
            properties_sql,
            json!({ "columns": [{ "name": "value", "type": "varchar" }], "data": [["PARQUET"]] }),
        )
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DESCRIBE FORMATTED db.t",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        harness.trino_sqls(),
        [
            probe.clone(),
            probe,
            "DESCRIBE t".to_string(),
            "SHOW CREATE TABLE t".to_string(),
            properties_sql.to_string(),
        ]
    );

    let (values, results) = values_and_results(&harness, &execution).await;
    let expected = [
        "# Table schema:\t\t".to_string(),
        "# col_name\tdata_type\tcomment".to_string(),
        "n\tint\t".to_string(),
        "p\tstring\t".to_string(),
        "\t\t".to_string(),
        "# Partition spec:\t\t".to_string(),
        "# field_name\tfield_transform\tcolumn_name".to_string(),
        "p\tidentity\tp".to_string(),
        "\t\t".to_string(),
        // 本物の `Name:` は Trino のカタログ名によらず `iceberg`（2026-09-27 実測 f_i）。
        "Name:\ticeberg.db.t\t".to_string(),
        "Location:\ts3://bucket/prefix\t".to_string(),
        "\t\t".to_string(),
        "# Table properties:\t\t".to_string(),
        "# key\tvalue\t".to_string(),
        "format\tPARQUET\t".to_string(),
        "\t\t".to_string(),
        "# Iceberg storage table properties:\t\t".to_string(),
        "# key\tvalue\t".to_string(),
        "write.format.default\tPARQUET\t".to_string(),
    ];
    assert_eq!(values, expected);
    assert_eq!(results["UpdateCount"], 0);

    let id = execution_id(&execution);
    let puts = harness.s3_puts();
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(puts[0].content_type.as_deref(), Some("binary/octet-stream"));
    assert_eq!(puts[1].content_type.as_deref(), Some("binary/octet-stream"));
}

/// 本物の e_x・f_x（無い表。2026-09-27 実測）。開始時に FAILED、本体だけ置き `.metadata` は無い。
#[tokio::test]
async fn extended_は無い表を開始時に_failed_にし_本体だけ置く() {
    let probe = probe_sql("default_catalog", "db", "nope");
    let schema_probe = schema_probe_sql("default_catalog", "db");
    let harness = Harness::builder(json!({ "columns": [], "data": [] }))
        .route(&probe, missing_probe_response("hive"))
        .route(&schema_probe, json!({ "columns": [], "data": [] }))
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DESCRIBE EXTENDED db.nope",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "FAILED");
    assert_eq!(
        execution["QueryExecution"]["Status"]["StateChangeReason"],
        "FAILED: SemanticException [Error 10001]: Table not found nope"
    );
    let error = &execution["QueryExecution"]["Status"]["AthenaError"];
    assert_eq!(error["ErrorCategory"], 2);
    assert_eq!(error["ErrorType"], 1006);

    // 開始時に FAILED にするので、probe と schema_probe だけ送り、DESCRIBE も構文チェックも送らない。
    assert_eq!(harness.trino_sqls(), [probe, schema_probe]);
    assert!(harness.syntax_checks().is_empty());

    let id = execution_id(&execution);
    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 1, "{puts:?} (.metadata は無い)");
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(
        String::from_utf8(puts[0].body.clone()).unwrap(),
        "FAILED: SemanticException [Error 10001]: Table not found nope"
    );
}

/// 本物の z3（無い DB。2026-09-27 実測）。返る Database は文中の綴り。
#[tokio::test]
async fn extended_は無い_db_を開始時に_failed_にし_database_を文中の綴りで返す() {
    let probe = probe_sql("default_catalog", "nodb", "h");
    let schema_probe = schema_probe_sql("default_catalog", "nodb");
    let harness = Harness::builder(json!({ "columns": [], "data": [] }))
        .route(&probe, missing_probe_response("hive"))
        .route(
            &schema_probe,
            trino_error("SCHEMA_NOT_FOUND", "Schema 'nodb' does not exist"),
        )
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DESCRIBE EXTENDED nodb.h",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "FAILED");
    assert_eq!(
        execution["QueryExecution"]["Status"]["StateChangeReason"],
        "FAILED: SemanticException [Error 10072]: Database does not exist: nodb"
    );
    assert_eq!(execution["QueryExecution"]["Query"], "DESCRIBE EXTENDED h");
    assert_eq!(
        execution["QueryExecution"]["QueryExecutionContext"]["Database"],
        "nodb"
    );
    assert_eq!(harness.trino_sqls(), [probe, schema_probe]);
}

/// 本物の e_i（Iceberg 表への EXTENDED。2026-09-27 実測）。開始時に FAILED、本体も `.metadata` も無い。
#[tokio::test]
async fn extended_は_iceberg_表を開始時に_failed_にし何も置かない() {
    let probe = probe_sql("default_catalog", "db", "t");
    let harness = Harness::builder(json!({ "columns": [], "data": [] }))
        .route(&probe, probe_response("iceberg"))
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DESCRIBE EXTENDED db.t",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "FAILED");
    assert_eq!(
        execution["QueryExecution"]["Status"]["StateChangeReason"],
        "EXTENDED keyword is not supported for Iceberg tables."
    );
    let error = &execution["QueryExecution"]["Status"]["AthenaError"];
    assert_eq!(error["ErrorCategory"], 2);
    assert_eq!(error["ErrorType"], 1100);

    assert_eq!(harness.trino_sqls(), [probe]);
    assert!(harness.s3_puts().is_empty(), "本体も.metadataも置かない");
}

/// 名前無し（z1）は今どおり、entity_check の Entity Not Found（開始時 400）に任せる。
#[tokio::test]
async fn 名前無しの_describe_extended_は今どおり_entity_not_found_で_400() {
    let probe = probe_sql("default_catalog", "default_schema", "extended");
    let harness = Harness::builder(json!({ "columns": [], "data": [] }))
        .route(&probe, missing_probe_response("hive"))
        .start()
        .await;

    let (code, error) = harness
        .call(
            "StartQueryExecution",
            json!({ "QueryString": "DESCRIBE EXTENDED" }),
        )
        .await;
    assert_eq!(code, 400, "{error}");
    assert_eq!(error["AthenaErrorCode"], "INVALID_INPUT");
    assert!(
        error["Message"]
            .as_str()
            .unwrap()
            .contains("Entity Not Found")
    );
}

/// 形式が hive でも iceberg でもないコネクタは今どおり構文チェックへ進む（Trino に構文が無いので
/// 400 になる。偽 Trino は構文チェックを通すので、`syntax_checks()` に文が入ることで確かめる）。
#[tokio::test]
async fn 形式がhiveでもicebergでもないコネクタは今どおり構文チェックへ進む() {
    let probe = probe_sql("default_catalog", "db", "t");
    let harness = Harness::builder(json!({ "columns": [], "data": [] }))
        .route(&probe, probe_response("memory"))
        .start()
        .await;

    let (code, _) = harness
        .call(
            "StartQueryExecution",
            json!({ "QueryString": "DESCRIBE EXTENDED db.t" }),
        )
        .await;
    assert_eq!(code, 200);
    assert_eq!(harness.syntax_checks(), ["DESCRIBE EXTENDED db.t"]);
}

/// 本物で測った Context は `Catalog=AwsDataCatalog` だけなので、ほかのカタログの Context では今どおり
/// 構文チェックへ進む（偽 Trino は構文チェックを通すので、`syntax_checks()` に文が入ることで確かめる）。
/// Hive 表の probe の応答を置いても、新しい経路には入らない。
#[tokio::test]
async fn context_の_catalog_が_awsdatacatalog_でも省略でもなければ今どおり構文チェックへ進む() {
    let probe = probe_sql("other", "db", "h");
    let harness = Harness::builder(json!({ "columns": [], "data": [] }))
        .catalog_map(&[("other", "other")])
        .route(&probe, probe_response("hive"))
        .start()
        .await;

    let (code, _) = harness
        .call(
            "StartQueryExecution",
            json!({
                "QueryString": "DESCRIBE EXTENDED db.h",
                "QueryExecutionContext": { "Catalog": "other" }
            }),
        )
        .await;
    assert_eq!(code, 200);
    assert_eq!(harness.syntax_checks(), ["DESCRIBE EXTENDED db.h"]);
}

// ==== フェーズ 4: 列指定・PARTITION 指定（#275） ====

/// 本物の p1（2026-09-27 実測）。列指定 EXTENDED は 1 行、コメント欄は `from deserializer`。
#[tokio::test]
async fn extended_は_hive_の列指定で成功し_from_deserializer_を返す() {
    let probe = probe_sql("default_catalog", "db", "h");
    let rows = describe_rows(&[["n", "integer", "", ""], ["s", "varchar", "", "note"]]);
    let harness = Harness::builder(rows.clone())
        .route(&probe, probe_response("hive"))
        .route("DESCRIBE h", rows)
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DESCRIBE EXTENDED db.h n",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        execution["QueryExecution"]["Query"],
        "DESCRIBE EXTENDED h n"
    );
    // 開始時に列を確かめる DESCRIBE と、実行時の DESCRIBE で 2 回送る。
    assert_eq!(
        harness.trino_sqls(),
        [
            probe.clone(),
            "DESCRIBE h".to_string(),
            probe,
            "DESCRIBE h".to_string()
        ]
    );

    let (values, results) = values_and_results(&harness, &execution).await;
    assert_eq!(
        values,
        ["n                   \tint                 \tfrom deserializer   "]
    );
    // EXTENDED の列指定は FORMATTED（p2）と違い 3 列のまま（describe_run.rs の formatted_column）。
    assert_describe_columns(&results);
}

/// 本物の p2（2026-09-27 実測）。列指定 FORMATTED の ColumnInfo は 11 列。
#[tokio::test]
async fn formatted_は_hive_の列指定で成功し_11_列の_columninfo_を返す() {
    let probe = probe_sql("default_catalog", "db", "h");
    let rows = describe_rows(&[["n", "integer", "", ""]]);
    let harness = Harness::builder(rows.clone())
        .route(&probe, probe_response("hive"))
        .route("DESCRIBE h", rows)
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DESCRIBE FORMATTED db.h n",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");

    let (values, results) = values_and_results(&harness, &execution).await;
    let columns = results["ResultSet"]["ResultSetMetadata"]["ColumnInfo"]
        .as_array()
        .unwrap();
    assert_eq!(columns.len(), 11, "{results}");
    for column in columns {
        assert_eq!(column["Type"], "string");
    }
    assert_eq!(values.len(), 3, "{values:?}");

    let id = execution_id(&execution);
    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(puts[1].key, format!("athena/{id}.txt.metadata"));
}

/// 本物の p5（2026-09-27 実測）。修飾子無しの Iceberg への列指定は成功する。
#[tokio::test]
async fn describe_は_iceberg_の列指定で成功し_binary_で_update_count_が_0() {
    let probe = probe_sql("default_catalog", "db", "i");
    let rows = describe_rows(&[["n", "integer", "", ""]]);
    let harness = Harness::builder(rows.clone())
        .route(&probe, probe_response("iceberg"))
        .route("DESCRIBE i", rows)
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DESCRIBE db.i n",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    let (values, results) = values_and_results(&harness, &execution).await;
    assert_eq!(values, ["n\tint\t"]);
    assert_eq!(results["UpdateCount"], 0);
    let puts = harness.s3_puts();
    assert_eq!(puts[0].content_type.as_deref(), Some("binary/octet-stream"));
}

/// パーティション付き Hive 表の `"<t>$partitions"` の確認 SQL。
fn partitions_sql(catalog: &str, schema: &str, table: &str, key: &str, value: &str) -> String {
    format!(
        "SELECT 1 FROM \"{catalog}\".\"{schema}\".\"{table}$partitions\" WHERE \"{key}\" = '{value}'"
    )
}

/// 本物の p3（2026-09-27 実測）。PARTITION 指定 EXTENDED は `$partitions` で存在を確かめて実行する。
#[tokio::test]
async fn extended_は_hive_の_partition_指定で存在を確かめて成功する() {
    let probe = probe_sql("default_catalog", "db", "hp");
    let rows = describe_rows(&[
        ["n", "integer", "", ""],
        ["p", "varchar(1)", "partition key", ""],
    ]);
    let partitions = partitions_sql("default_catalog", "db", "hp", "p", "x");
    let harness = Harness::builder(rows.clone())
        .route(&probe, probe_response("hive"))
        .route("DESCRIBE hp", rows)
        .route(
            &partitions,
            json!({ "columns": [{ "name": "_col0", "type": "integer" }], "data": [[1]] }),
        )
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DESCRIBE EXTENDED db.hp PARTITION (p='x')",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(
        execution["QueryExecution"]["Query"],
        "DESCRIBE EXTENDED hp PARTITION (p='x')"
    );
    assert!(
        harness.trino_sqls().contains(&partitions),
        "{:?}",
        harness.trino_sqls()
    );

    let (values, _) = values_and_results(&harness, &execution).await;
    assert!(
        values
            .last()
            .unwrap()
            .starts_with("Detailed Partition Information\t"),
        "{values:?}"
    );
}

/// 本物の p4（2026-09-27 実測）。PARTITION 指定 FORMATTED も同じく確かめて実行する。
#[tokio::test]
async fn formatted_は_hive_の_partition_指定で存在を確かめて成功する() {
    let probe = probe_sql("default_catalog", "db", "hp");
    let rows = describe_rows(&[
        ["n", "integer", "", ""],
        ["p", "varchar(1)", "partition key", ""],
    ]);
    let partitions = partitions_sql("default_catalog", "db", "hp", "p", "x");
    let harness = Harness::builder(rows.clone())
        .route(&probe, probe_response("hive"))
        .route("DESCRIBE hp", rows)
        .route(
            &partitions,
            json!({ "columns": [{ "name": "_col0", "type": "integer" }], "data": [[1]] }),
        )
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DESCRIBE FORMATTED db.hp PARTITION (p='x')",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    let (values, _) = values_and_results(&harness, &execution).await;
    assert!(
        values
            .iter()
            .any(|line| line.starts_with("Partition Value:")),
        "{values:?}"
    );
}

/// 独立レビュー: Context の Database を大文字混在にしても、`$partitions` の存在確認は小文字のカタログ・
/// スキーマで投げる（`entity_check::probe`・`Probe::Missing` の腕と同じ規則。名前に DB を書かない
/// （Context の Database だけで決まる）形なので、`target.schema` は `default_schema` から来た大文字混在の
/// まま渡る）。
#[tokio::test]
async fn extended_は_partition_指定で_context_の_database_を小文字にしてから確かめる() {
    let probe = probe_sql("default_catalog", "db", "hp");
    let rows = describe_rows(&[
        ["n", "integer", "", ""],
        ["p", "varchar(1)", "partition key", ""],
    ]);
    let partitions = partitions_sql("default_catalog", "db", "hp", "p", "x");
    let harness = Harness::builder(rows.clone())
        .route(&probe, probe_response("hive"))
        .route("DESCRIBE hp", rows)
        .route(
            &partitions,
            json!({ "columns": [{ "name": "_col0", "type": "integer" }], "data": [[1]] }),
        )
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DESCRIBE EXTENDED hp PARTITION (p='x')",
            "QueryExecutionContext": { "Database": "Db" },
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert!(
        harness.trino_sqls().contains(&partitions),
        "小文字のカタログ・スキーマで確かめていない: {:?}",
        harness.trino_sqls()
    );
}

/// 本物の z4（2026-09-27 実測）。無い列は 1/1003、`.txt` あり・`.metadata` 無し。
#[tokio::test]
async fn extended_は無い列を開始時に_failed_にする() {
    let probe = probe_sql("default_catalog", "db", "h");
    let rows = describe_rows(&[["n", "integer", "", ""], ["s", "varchar", "", ""]]);
    let harness = Harness::builder(rows.clone())
        .route(&probe, probe_response("hive"))
        .route("DESCRIBE h", rows)
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DESCRIBE EXTENDED db.h nocol",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "FAILED");
    assert_eq!(
        execution["QueryExecution"]["Status"]["StateChangeReason"],
        "FAILED: Execution Error, return code 1 from org.apache.hadoop.hive.ql.exec.DDLTask. cannot find field nocol from [0:n, 1:s]"
    );
    let error = &execution["QueryExecution"]["Status"]["AthenaError"];
    assert_eq!(error["ErrorCategory"], 1);
    assert_eq!(error["ErrorType"], 1003);

    let id = execution_id(&execution);
    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 1, "{puts:?} (.metadata は無い)");
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
}

/// 本物の z5（2026-09-27 実測）。無いパーティション値は 2/1006。
#[tokio::test]
async fn extended_は無いパーティション値を開始時に_failed_にする() {
    let probe = probe_sql("default_catalog", "db", "hp");
    let rows = describe_rows(&[
        ["n", "integer", "", ""],
        ["p", "varchar(1)", "partition key", ""],
    ]);
    let partitions = partitions_sql("default_catalog", "db", "hp", "p", "nope");
    let harness = Harness::builder(rows.clone())
        .route(&probe, probe_response("hive"))
        .route("DESCRIBE hp", rows)
        .route(
            &partitions,
            json!({ "columns": [{ "name": "_col0", "type": "integer" }], "data": [] }),
        )
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DESCRIBE EXTENDED db.hp PARTITION (p='nope')",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "FAILED");
    assert_eq!(
        execution["QueryExecution"]["Status"]["StateChangeReason"],
        "FAILED: SemanticException [Error 10006]: Partition not found {p=nope}"
    );
    let error = &execution["QueryExecution"]["Status"]["AthenaError"];
    assert_eq!(error["ErrorCategory"], 2);
    assert_eq!(error["ErrorType"], 1006);
}

/// 本物の p6（2026-09-27 実測）。Iceberg への EXTENDED 列指定は 2/1100、ファイル無し。
#[tokio::test]
async fn extended_は_iceberg_の列指定を開始時に_failed_にし何も置かない() {
    let probe = probe_sql("default_catalog", "db", "i");
    let harness = Harness::builder(json!({ "columns": [], "data": [] }))
        .route(&probe, probe_response("iceberg"))
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DESCRIBE EXTENDED db.i n",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "FAILED");
    let error = &execution["QueryExecution"]["Status"]["AthenaError"];
    assert_eq!(error["ErrorCategory"], 2);
    assert_eq!(error["ErrorType"], 1100);
    assert_eq!(harness.trino_sqls(), [probe]);
    assert!(harness.s3_puts().is_empty());
}

/// 本物の p7（2026-09-27 実測）。Iceberg への FORMATTED 列指定は 2/1100。
#[tokio::test]
async fn formatted_は_iceberg_の列指定を開始時に_failed_にする() {
    let probe = probe_sql("default_catalog", "db", "i");
    let harness = Harness::builder(json!({ "columns": [], "data": [] }))
        .route(&probe, probe_response("iceberg"))
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DESCRIBE FORMATTED db.i n",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "FAILED");
    assert_eq!(
        execution["QueryExecution"]["Status"]["StateChangeReason"],
        "FORMATTED keyword is not supported for Iceberg table columns."
    );
    assert!(harness.s3_puts().is_empty());
}

/// 本物の p8（2026-09-27 実測）。Iceberg への PARTITION 指定は 2/1100。
#[tokio::test]
async fn describe_は_iceberg_の_partition_指定を開始時に_failed_にする() {
    let probe = probe_sql("default_catalog", "db", "i");
    let harness = Harness::builder(json!({ "columns": [], "data": [] }))
        .route(&probe, probe_response("iceberg"))
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DESCRIBE db.i PARTITION (p='x')",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "FAILED");
    assert_eq!(
        execution["QueryExecution"]["Status"]["StateChangeReason"],
        "PARTITION keyword is not supported for Iceberg tables."
    );
    assert!(harness.s3_puts().is_empty());
}

/// パーティション付き Hive 表への列指定は今どおり（測っていない。構文チェックへ進む）。
#[tokio::test]
async fn extended_はパーティション付き_hive_への列指定は今どおり構文チェックへ進む() {
    let probe = probe_sql("default_catalog", "db", "hp");
    let rows = describe_rows(&[
        ["n", "integer", "", ""],
        ["p", "varchar(1)", "partition key", ""],
    ]);
    let harness = Harness::builder(rows.clone())
        .route(&probe, probe_response("hive"))
        .route("DESCRIBE hp", rows)
        .start()
        .await;

    let (code, _) = harness
        .call(
            "StartQueryExecution",
            json!({ "QueryString": "DESCRIBE EXTENDED db.hp n" }),
        )
        .await;
    assert_eq!(code, 200);
    assert_eq!(harness.syntax_checks(), ["DESCRIBE EXTENDED db.hp n"]);
}

/// ビューへの列指定は今どおり（測っていない。構文チェックへ進む）。
#[tokio::test]
async fn extended_はビューへの列指定は今どおり構文チェックへ進む() {
    let probe = probe_sql("default_catalog", "db", "v");
    let harness = Harness::builder(json!({ "columns": [], "data": [] }))
        .route(&probe, view_probe_response("hive"))
        .start()
        .await;

    let (code, _) = harness
        .call(
            "StartQueryExecution",
            json!({ "QueryString": "DESCRIBE EXTENDED db.v n" }),
        )
        .await;
    assert_eq!(code, 200);
    assert_eq!(harness.syntax_checks(), ["DESCRIBE EXTENDED db.v n"]);
}

/// キーが 2 つの PARTITION 指定は今どおり（測っていない。構文チェックへ進む）。
#[tokio::test]
async fn extended_はキーが_2_つの_partition_指定は今どおり構文チェックへ進む() {
    let probe = probe_sql("default_catalog", "db", "hp");
    let harness = Harness::builder(json!({ "columns": [], "data": [] }))
        .route(&probe, probe_response("hive"))
        .start()
        .await;

    let (code, _) = harness
        .call(
            "StartQueryExecution",
            json!({ "QueryString": "DESCRIBE EXTENDED db.hp PARTITION (p='x', q='y')" }),
        )
        .await;
    assert_eq!(code, 200);
    assert_eq!(
        harness.syntax_checks(),
        ["DESCRIBE EXTENDED db.hp PARTITION (p='x', q='y')"]
    );
}

/// 修飾子無しの Hive への列指定は今どおり（測っていない。Query だけ測定の m8。構文チェックへ進む）。
#[tokio::test]
async fn describe_は修飾子無しの_hive_への列指定は今どおり構文チェックへ進む() {
    let probe = probe_sql("default_catalog", "db", "h");
    let harness = Harness::builder(json!({ "columns": [], "data": [] }))
        .route(&probe, probe_response("hive"))
        .start()
        .await;

    let (code, _) = harness
        .call(
            "StartQueryExecution",
            json!({ "QueryString": "DESCRIBE db.h n" }),
        )
        .await;
    assert_eq!(code, 200);
    assert_eq!(harness.syntax_checks(), ["DESCRIBE db.h n"]);
}
