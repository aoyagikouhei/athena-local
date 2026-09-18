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
    assert_eq!(
        puts[1].content_type.as_deref(),
        Some("application/octet-stream")
    );

    // 列 `table_name varchar`。message = 6 + 12 + 12 + 9 + 6 + 2 + 2 + 2 = 51 = 0x33。
    // Precision の ff を含むので、非 UTF-8 の body が偽 S3 を通る証明にもなる。
    assert_eq!(
        hex_of(&puts[1].body),
        hex(&format!(
            "{}
             2233
               0a04 68697665
               220a 7461626c655f6e616d65
               2a0a 7461626c655f6e616d65
               3207 76617263686172
               38ffffffff07 4000 4803 5001",
            engine_id_field()
        ))
    );
    assert!(puts[1].body.contains(&0xff), "{:?}", puts[1].body);
}

#[tokio::test]
async fn describe_の_metadata_は先頭が実行_id_になる() {
    let harness = Harness::builder(select_response())
        .route(
            "DESCRIBE t",
            json!({
                "columns": [
                    { "name": "col_name", "type": "varchar" },
                    { "name": "data_type", "type": "varchar" }
                ],
                "data": [["id", "integer"], ["name", "varchar"]]
            }),
        )
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
    // 列 `col_name varchar` は 6 + 10 + 10 + 9 + 6 + 2 + 2 + 2 = 47 = 0x2f、
    // 列 `data_type varchar` は 6 + 11 + 11 + 9 + 6 + 2 + 2 + 2 = 49 = 0x31。
    assert_eq!(
        hex_of(&puts[1].body),
        hex(&format!(
            "{}
             222f
               0a04 68697665
               2208 636f6c5f6e616d65
               2a08 636f6c5f6e616d65
               3207 76617263686172
               38ffffffff07 4000 4803 5001
             2231
               0a04 68697665
               2209 646174615f74797065
               2a09 646174615f74797065
               3207 76617263686172
               38ffffffff07 4000 4803 5001",
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
    // 列 `Create Table varchar` は 6 + 14 + 14 + 9 + 6 + 2 + 2 + 2 = 55 = 0x37。
    assert_eq!(
        hex_of(&puts[1].body),
        hex(&format!(
            "{}
             2237
               0a04 68697665
               220c 437265617465205461626c65
               2a0c 437265617465205461626c65
               3207 76617263686172
               38ffffffff07 4000 4803 5001",
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
    // `tables/` は Hive の CTAS の実測。Iceberg（`table_type = 'ICEBERG'`）では付かない。
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
        .route(
            "-- c\nDESCRIBE t",
            json!({
                "columns": [
                    { "name": "col_name", "type": "varchar" },
                    { "name": "data_type", "type": "varchar" }
                ],
                "data": [["id", "integer"], ["name", "varchar"]]
            }),
        )
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

    // 列 `col_name varchar` は 6 + 10 + 10 + 9 + 6 + 2 + 2 + 2 = 47 = 0x2f、
    // 列 `data_type varchar` は 6 + 11 + 11 + 9 + 6 + 2 + 2 + 2 = 49 = 0x31。
    assert_eq!(
        hex_of(&puts[1].body),
        hex(&format!(
            "{}
             222f
               0a04 68697665
               2208 636f6c5f6e616d65
               2a08 636f6c5f6e616d65
               3207 76617263686172
               38ffffffff07 4000 4803 5001
             2231
               0a04 68697665
               2209 646174615f74797065
               2a09 646174615f74797065
               3207 76617263686172
               38ffffffff07 4000 4803 5001",
            execution_id_field(&id)
        ))
    );
}
