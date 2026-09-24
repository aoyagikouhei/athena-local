//! 結果ファイルの隣に置く付随ファイル `.metadata`（protobuf）。
//! 中身の形式は 2026-09-17 に本番 Athena で実測したもの（生バイト列は src/metadata.rs のユニットテストが固定する）。
//! ここで見るのは「どのキーに、どの順で、どの Content-Type で置くか」と、先頭のクエリ ID の出どころ。
//! 期待値の 16 進は手計算で、内訳をコメントに書く（src/metadata.rs で作ると同語反復になる）。

mod common;

use common::{Harness, TRINO_QUERY_ID, execution_id};
use serde_json::{Value, json};

fn select_response() -> Value {
    json!({
        "columns": [
            { "name": "id", "type": "integer" },
            { "name": "name", "type": "varchar" }
        ],
        "data": [[1, "it's \"x\""], [2, null]]
    })
}

fn show_response() -> Value {
    json!({
        "columns": [{ "name": "table_name", "type": "varchar" }],
        "data": [["orders"], ["users"]]
    })
}

/// DML / CTAS の応答。件数と updateType だけ変える。
fn dml_response(update_type: &str, update_count: i64) -> Value {
    json!({
        "columns": [{ "name": "rows", "type": "bigint" }],
        "data": [[update_count]],
        "updateType": update_type,
        "updateCount": update_count
    })
}

/// 失敗したときに差分が読めるよう、比較は 16 進文字列どうしでする。
fn hex_of(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// 期待値の 16 進から空白と改行を落とす。
fn hex(text: &str) -> String {
    text.chars().filter(|c| !c.is_whitespace()).collect()
}

/// top の field 1（クエリ ID）。偽 Trino の既定 ID は 27 バイトなので長さ前置は 1b。
fn engine_id_field() -> String {
    format!("0a1b{}", hex_of(TRINO_QUERY_ID.as_bytes()))
}

/// top の field 1 に実行 ID（UUID）が入る形。36 バイトなので長さ前置は 24。
fn execution_id_field(id: &str) -> String {
    assert_eq!(id.len(), 36, "実行 ID が UUID の形でない: {id}");
    format!("0a24{}", hex_of(id.as_bytes()))
}

/// 列 `id integer`。message = CatalogName 6 + Name 4 + Label 4 + Type 9
/// + 7 の 2 + 8 の 2 + 9 の 2 + 10 の 2 = 31 = 0x1f。
const COLUMN_ID_INTEGER: &str = "221f
     0a04 68697665
     2202 6964
     2a02 6964
     3207 696e7465676572
     380a 4000 4803 5000";

/// 列 `name varchar`。typeSignature が無いので Precision は上限無しの 2147483647
/// （varint は ff ff ff ff 07 の 5 バイト）、CaseSensitive は 1。
/// message = 6 + 6 + 6 + 9 + 6 + 2 + 2 + 2 = 39 = 0x27。
const COLUMN_NAME_VARCHAR: &str = "2227
     0a04 68697665
     2204 6e616d65
     2a04 6e616d65
     3207 76617263686172
     38ffffffff07 4000 4803 5001";

/// 列 `rows bigint`（DML / CTAS が返す唯一の列）。Precision 19 = 0x13、Scale 0、CaseSensitive 0。
/// message = 6 + 6 + 6 + 8 + 2 + 2 + 2 + 2 = 34 = 0x22。
const COLUMN_ROWS_BIGINT: &str = "2222
     0a04 68697665
     2204 726f7773
     2a04 726f7773
     3206 626967696e74
     3813 4000 4803 5000";

/// Trino の DESCRIBE の応答（`Column`／`Type`／`Extra`／`Comment` の 4 列）。
fn describe_response() -> Value {
    json!({
        "columns": [
            { "name": "Column", "type": "varchar" },
            { "name": "Type", "type": "varchar" },
            { "name": "Extra", "type": "varchar" },
            { "name": "Comment", "type": "varchar" }
        ],
        "data": [["id", "integer", "", ""], ["name", "varchar", "", ""]]
    })
}

/// Hive のテーブルの DESCRIBE の列部分（`col_name`／`data_type`／`comment` の 3 列、どれも string で
/// Precision・Scale は省き CaseSensitive も省く）。出典: src/metadata.rs の
/// `実測した_describe_の_metadata_と同じバイト列になる`（run-20260917-175312/describe.metadata.bytes、
/// 2026-09-17 実測の 152 バイト）の先頭 ID より後ろと同じ 16 進。
/// message = 6 + 10 + 10 + 8 + 2 = 36 = 0x24、6 + 11 + 11 + 8 + 2 = 38 = 0x26、6 + 9 + 9 + 8 + 2 = 34 = 0x22。
const DESCRIBE_HIVE_COLUMNS: &str = "2224
     0a04 68697665
     2208 636f6c5f6e616d65
     2a08 636f6c5f6e616d65
     3206 737472696e67
     4803
   2226
     0a04 68697665
     2209 646174615f74797065
     2a09 646174615f74797065
     3206 737472696e67
     4803
   2222
     0a04 68697665
     2207 636f6d6d656e74
     2a07 636f6d6d656e74
     3206 737472696e67
     4803";

#[tokio::test]
async fn select_は_csv_の隣に_csv_metadata_を置く() {
    let harness = Harness::builder(select_response())
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "SELECT id, name FROM users",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    let id = execution_id(&execution);

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    // 本体を置いてから付随ファイルを置く。
    assert_eq!(puts[0].key, format!("athena/{id}.csv"));
    assert_eq!(puts[1].key, format!("athena/{id}.csv.metadata"));
    // 付随ファイルは本体と同じバケットに置く。
    assert_eq!(puts[1].bucket, "results-bucket");
    // 本体も付随ファイルも application/octet-stream（2026-09-17 実測）。
    assert_eq!(
        puts[0].content_type.as_deref(),
        Some("application/octet-stream")
    );
    assert_eq!(
        puts[1].content_type.as_deref(),
        Some("application/octet-stream")
    );

    // SELECT の field 1 はエンジン（Trino）のクエリ ID。field 2 / 3 は無い。
    assert_eq!(
        hex_of(&puts[1].body),
        hex(&format!(
            "{}{COLUMN_ID_INTEGER}{COLUMN_NAME_VARCHAR}",
            engine_id_field()
        ))
    );
}

#[tokio::test]
async fn show_は_txt_の隣に_txt_metadata_を置く() {
    let harness = Harness::builder(select_response())
        .route("SHOW TABLES IN db", show_response())
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "SHOW TABLES IN db",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    let id = execution_id(&execution);

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(puts[1].key, format!("athena/{id}.txt.metadata"));
    // SHOW TABLES の `.metadata` は本体と同じ binary/octet-stream（2026-09-23 実測）。
    assert_eq!(puts[1].content_type.as_deref(), Some("binary/octet-stream"));

    // 列は Trino の `table_name varchar` ではなく本物と同じ `tab_name string`（2026-09-23／24 実測。#173）。
    // string は Precision・Scale・CaseSensitive（7／8／10）を出さない（src/metadata.rs の `optional_fields`）。
    // message = 6 + 10 + 10 + 8 + 2 = 36 = 0x24。
    assert_eq!(
        hex_of(&puts[1].body),
        hex(&format!(
            "{}
             2224
               0a04 68697665
               2208 7461625f6e616d65
               2a08 7461625f6e616d65
               3206 737472696e67
               4803",
            engine_id_field()
        ))
    );
}

#[tokio::test]
async fn describe_の_metadata_は先頭が実行_id_になる() {
    let harness = Harness::builder(select_response())
        .route("DESCRIBE t", describe_response())
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DESCRIBE t",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    let id = execution_id(&execution);

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(puts[1].key, format!("athena/{id}.txt.metadata"));

    // DESCRIBE と SHOW CREATE TABLE だけ field 1 が QueryExecutionId（2026-09-17 実測）。
    // 列は本物の 3 列 string（#173）。実測の 152 バイトと先頭 ID 以外で一致する。
    assert_eq!(
        hex_of(&puts[1].body),
        hex(&format!(
            "{}{DESCRIBE_HIVE_COLUMNS}",
            execution_id_field(&id)
        ))
    );
}

#[tokio::test]
async fn show_create_table_の_metadata_も先頭が実行_id_になる() {
    let harness = Harness::builder(select_response())
        .route(
            "SHOW CREATE TABLE t",
            json!({
                "columns": [{ "name": "Create Table", "type": "varchar" }],
                "data": [["CREATE TABLE t (id integer)"]]
            }),
        )
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "SHOW CREATE TABLE t",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    let id = execution_id(&execution);

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(puts[1].key, format!("athena/{id}.txt.metadata"));

    // DESCRIBE と並んで field 1 が QueryExecutionId になるもう 1 つの文（2026-09-17 実測）。
    // 列は Trino の `Create Table varchar` ではなく本物の `createtab_stmt string`（7／8／10 は出ない）で、
    // 6 + 16 + 16 + 8 + 2 = 48 = 0x30。本物の 88 バイトと同じ形（2026-09-23 実測。#161）。
    assert_eq!(
        hex_of(&puts[1].body),
        hex(&format!(
            "{}
             2230
               0a04 68697665
               220e 6372656174657461625f73746d74
               2a0e 6372656174657461625f73746d74
               3206 737472696e67
               4803",
            execution_id_field(&id)
        ))
    );
}

#[tokio::test]
async fn update_は本体を置かず_csv_metadata_だけを置く() {
    let harness = Harness::builder(select_response())
        .route("UPDATE t SET name = 'x'", dml_response("UPDATE", 2))
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "UPDATE t SET name = 'x'",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    let id = execution_id(&execution);

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 1, "{puts:?}");
    assert_eq!(puts[0].key, format!("athena/{id}.csv.metadata"));
    assert_eq!(
        puts[0].content_type.as_deref(),
        Some("application/octet-stream")
    );

    // field 2 は Trino の updateType（`UPDATE` は 6 バイト）、field 3 は更新件数 2。
    assert_eq!(
        hex_of(&puts[0].body),
        hex(&format!(
            "{} 1206 555044415445 1802 {COLUMN_ROWS_BIGINT}",
            engine_id_field()
        ))
    );
}

#[tokio::test]
async fn merge_の_metadata_は_update_と同じ形で_update_type_の長さだけが違う() {
    // 2026-09-20 実測（#41）。本物の Athena が Iceberg のテーブルへの MERGE に置いた
    // `.csv.metadata` は 74 バイトで、同じラウンドの UPDATE / DELETE の 75 バイトとの差は
    // field 2 の文字列長だけだった（`MERGE` は 5 バイト、`UPDATE` と `DELETE` は 6 バイト）。
    // field 2 より後ろは 3 本ともバイト単位で同じで、下の期待値はその実測値そのもの
    // （実測で投げたのは `MERGE INTO <表> AS t USING (VALUES ...) AS u(n, s) ON t.n = u.n
    // WHEN NOT MATCHED THEN INSERT ...`。ここでは偽 Trino に届けばよいので短くしてある）。
    let sql = "MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN UPDATE SET name = 'x'";
    let harness = Harness::builder(select_response())
        .route(sql, dml_response("MERGE", 1))
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": sql,
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    let id = execution_id(&execution);

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 1, "{puts:?}");
    assert_eq!(puts[0].key, format!("athena/{id}.csv.metadata"));

    // field 2 は Trino の updateType（`MERGE` は 5 バイト）、field 3 は更新件数 1。
    assert_eq!(
        hex_of(&puts[0].body),
        hex(&format!(
            "{} 1205 4d45524745 1801 {COLUMN_ROWS_BIGINT}",
            engine_id_field()
        ))
    );
}

#[tokio::test]
async fn drop_table_は_iceberg_なら_41_バイトの_metadata_を置く() {
    // 2026-09-20 実測（issue #39）。field 1 はエンジン（Trino）のクエリ ID、
    // field 2 は Trino の updateType（`DROP TABLE` は 10 バイト）。列が無いので field 4 は無い
    // （41 = field1 29 バイト + field2 12 バイト）。結合レベルのバイト数・Content-Type・
    // キーの有無は tests/table_format.rs（計画レビュー F）。
    let harness = Harness::builder(json!({ "updateType": "DROP TABLE" }))
        .route(
            "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = 'default_catalog'), (SELECT count(*) FROM system.jdbc.tables WHERE table_cat = 'default_catalog' AND table_schem = 'default_schema' AND table_name = 't')",
            json!({
                "columns": [
                    { "name": "_col0", "type": "varchar" },
                    { "name": "_col1", "type": "bigint" }
                ],
                "data": [["iceberg", 1]]
            }),
        )
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DROP TABLE t",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    let id = execution_id(&execution);

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(puts[1].key, format!("athena/{id}.txt.metadata"));

    assert_eq!(
        hex_of(&puts[1].body),
        hex(&format!("{} 120a 44524f50205441424c45", engine_id_field()))
    );
}

#[tokio::test]
async fn alter_table_add_columns_は_hive_なら_38_バイトの_metadata_を置く() {
    // 2026-09-21 実測（issue #39 Phase 3b）。field 1 は実行 ID（QueryExecutionId）のみ。
    // field 2（updateType）も field 3（更新件数）も無い。Trino の updateType は "ADD COLUMN"
    // （Athena の `ADD COLUMNS` と綴りが違う）なので使わない。列も無いので field 4 も無い
    // （38 = field1 のみ）。41 バイト（DROP TABLE × Iceberg）と違い field 2 が丸ごと無い。
    // 結合レベルのバイト数・Content-Type・キーの有無は tests/table_format.rs（計画レビュー F）。
    let harness = Harness::builder(json!({ "updateType": "ADD COLUMN" }))
        .route(
            "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = 'default_catalog'), (SELECT count(*) FROM system.jdbc.tables WHERE table_cat = 'default_catalog' AND table_schem = 'default_schema' AND table_name = 't')",
            json!({
                "columns": [
                    { "name": "_col0", "type": "varchar" },
                    { "name": "_col1", "type": "bigint" }
                ],
                "data": [["hive", 1]]
            }),
        )
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "ALTER TABLE t ADD COLUMNS (m int)",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    let id = execution_id(&execution);

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(puts[1].key, format!("athena/{id}.txt.metadata"));

    // field 1（実行 ID）だけの 38 バイト。field 2 も field 3 も丸ごと無い。
    assert_eq!(hex_of(&puts[1].body), execution_id_field(&id));
}

#[tokio::test]
async fn insert_と_ctas_は_metadata_だけを置く() {
    let harness = Harness::builder(select_response())
        .route("INSERT INTO t VALUES (1)", dml_response("INSERT", 1))
        .route(
            "CREATE TABLE t2 AS SELECT 1",
            dml_response("CREATE TABLE", 1),
        )
        .results_s3()
        .default_output_location("s3://results-bucket/athena/")
        .start()
        .await;

    let insert = harness
        .run_query(json!({ "QueryString": "INSERT INTO t VALUES (1)" }))
        .await;
    let ctas = harness
        .run_query(json!({ "QueryString": "CREATE TABLE t2 AS SELECT 1" }))
        .await;

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    // INSERT の本体は拡張子なしの `<id>`、CTAS は `tables/<id>`。
    // `tables/` はテーブルの形式によらない（Iceberg の CTAS も同じ。2026-09-19 実測）。
    assert_eq!(
        puts[0].key,
        format!("athena/{}.metadata", execution_id(&insert))
    );
    assert_eq!(
        puts[1].key,
        format!("athena/tables/{}.metadata", execution_id(&ctas))
    );

    // field 2 は Trino の updateType そのまま（`INSERT` は 6 バイト、`CREATE TABLE` は 12 バイト）。
    assert_eq!(
        hex_of(&puts[0].body),
        hex(&format!(
            "{} 1206 494e53455254 1801 {COLUMN_ROWS_BIGINT}",
            engine_id_field()
        ))
    );
    assert_eq!(
        hex_of(&puts[1].body),
        hex(&format!(
            "{} 120c 435245415445205441424c45 1801 {COLUMN_ROWS_BIGINT}",
            engine_id_field()
        ))
    );
}

/// 0 行の INSERT でも本物は `<id>` に本体を置かず、`.metadata` に更新件数 0 を `18 00` として書く
/// （Hive のテーブルは 2026-09-20、Iceberg のテーブルは 2026-09-23 に実測。同じラウンドの 1 行の
/// INSERT と比べて、違うのはその 1 バイトだけ）。athena-local はテーブルの形式を見ないので、
/// 1 本のテストが両方の形式を固定する。
#[tokio::test]
async fn 行の無い_insert_も_metadata_だけを置き_更新件数_0_を書く() {
    let harness = Harness::builder(select_response())
        .route(
            "INSERT INTO t SELECT 1 WHERE false",
            dml_response("INSERT", 0),
        )
        .results_s3()
        .default_output_location("s3://results-bucket/athena/")
        .start()
        .await;

    let insert = harness
        .run_query(json!({ "QueryString": "INSERT INTO t SELECT 1 WHERE false" }))
        .await;

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 1, "{puts:?}");
    assert_eq!(
        puts[0].key,
        format!("athena/{}.metadata", execution_id(&insert))
    );
    assert_eq!(
        hex_of(&puts[0].body),
        hex(&format!(
            "{} 1206 494e53455254 1800 {COLUMN_ROWS_BIGINT}",
            engine_id_field()
        ))
    );
}

#[tokio::test]
async fn metadata_の書き込みに失敗しても_succeeded_のまま() {
    let harness = Harness::builder(select_response())
        .route("UPDATE t SET name = 'x'", dml_response("UPDATE", 2))
        .results_s3()
        .s3_status(500)
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "UPDATE t SET name = 'x'",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;

    // 付随ファイルは補助なので、書けなくても実行は成功のまま（.txt と同じ扱い）。
    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert!(
        execution["QueryExecution"]["Status"]
            .get("StateChangeReason")
            .is_none(),
        "{execution}"
    );
    assert_eq!(harness.s3_puts().len(), 1, "書き込みは試みる");
}

#[tokio::test]
async fn txt_の書き込みに失敗したら_metadata_は試みない() {
    let harness = Harness::builder(select_response())
        .route("SHOW TABLES IN db", show_response())
        .results_s3()
        .s3_status(500)
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "SHOW TABLES IN db",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    let puts = harness.s3_puts();
    assert_eq!(
        puts.len(),
        1,
        "本体が失敗したら付随ファイルは試みない: {puts:?}"
    );
    assert!(puts[0].key.ends_with(".txt"), "{}", puts[0].key);
}

#[tokio::test]
async fn _0_行の_select_でも_metadata_を置く() {
    let harness = Harness::builder(json!({
        "columns": [
            { "name": "id", "type": "integer" },
            { "name": "name", "type": "varchar" }
        ],
        "data": []
    }))
    .results_s3()
    .start()
    .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "SELECT id, name FROM users",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    let id = execution_id(&execution);

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(puts[0].key, format!("athena/{id}.csv"));
    // 本体は見出しだけ。
    assert_eq!(puts[0].body, b"\"id\",\"name\"\n".to_vec());
    assert_eq!(puts[1].key, format!("athena/{id}.csv.metadata"));
    assert_eq!(
        hex_of(&puts[1].body),
        hex(&format!(
            "{}{COLUMN_ID_INTEGER}{COLUMN_NAME_VARCHAR}",
            engine_id_field()
        ))
    );
}

#[tokio::test]
async fn 先頭のコメントを読み飛ばして_metadata_のクエリ_id_の出どころを決める() {
    // 2026-09-18 実測。DESCRIBE は先頭コメントの有無によらず QueryExecutionId が先頭に来る。
    let harness = Harness::builder(select_response())
        .route("-- c\nDESCRIBE t", describe_response())
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "-- c\nDESCRIBE t",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    let id = execution_id(&execution);

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(puts[1].key, format!("athena/{id}.txt.metadata"));

    assert_eq!(
        hex_of(&puts[1].body),
        hex(&format!(
            "{}{DESCRIBE_HIVE_COLUMNS}",
            execution_id_field(&id)
        ))
    );
}
