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
