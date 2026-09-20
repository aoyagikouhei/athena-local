//! DROP TABLE と ALTER TABLE ... ADD COLUMNS の結果ファイルを対象テーブルの形式
//! （Trino のコネクタ）で書き分ける（issue #39）。
//! Phase 2 では修飾名（`cat.ns.t` や引用符付きのカタログ名）も解析し、対象テーブルの存在も
//! あわせて確かめる。Phase 3b は ALTER TABLE ... ADD COLUMNS × Hive を対象に足す
//! （2026-09-21 実測）。41 バイト／38 バイトのバイト単位の固定は tests/metadata.rs に集約し、
//! ここでは結合レベル（バイト数・Content-Type・キーの有無）だけを見る（計画レビュー F）。

mod common;

use common::{Harness, execution_id};
use serde_json::{Value, json};
use std::time::Duration;

fn select_response() -> Value {
    json!({
        "columns": [{ "name": "n", "type": "bigint" }],
        "data": [[1]]
    })
}

/// 形式と存在を 1 つにまとめた問い合わせ（`src/operation/table_format.rs` の `probe_sql` と同じ形）。
fn probe_sql(catalog: &str, schema: &str, table: &str) -> String {
    format!(
        "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = '{catalog}'), (SELECT count(*) FROM system.jdbc.tables WHERE table_cat = '{catalog}' AND table_schem = '{schema}' AND table_name = '{table}')"
    )
}

/// 対象が存在し、形式が `connector_name` である応答。
fn probe_response(connector_name: &str) -> Value {
    json!({
        "columns": [
            { "name": "_col0", "type": "varchar" },
            { "name": "_col1", "type": "bigint" }
        ],
        "data": [[connector_name, 1]]
    })
}

/// 対象が存在しない（カタログはあるが件数が 0）応答。
fn probe_response_missing() -> Value {
    json!({
        "columns": [
            { "name": "_col0", "type": "varchar" },
            { "name": "_col1", "type": "bigint" }
        ],
        "data": [["iceberg", 0]]
    })
}

fn drop_table_response() -> Value {
    json!({ "updateType": "DROP TABLE" })
}

/// Trino の updateType は `"ADD COLUMN"`（Athena の `ADD COLUMNS` とは綴りが違う。2026-09-21 実測）。
fn alter_add_columns_response() -> Value {
    json!({ "updateType": "ADD COLUMN" })
}

fn has_call(harness: &Harness, call: &str) -> bool {
    harness.trino_calls().iter().any(|c| c == call)
}

#[tokio::test]
async fn drop_table_は_iceberg_なら改行1つと_41_バイトを書く() {
    let harness = Harness::builder(drop_table_response())
        .route(
            &probe_sql("default_catalog", "default_schema", "t"),
            probe_response("iceberg"),
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
    // 形式の問い合わせを本体より先に送る。
    assert_eq!(
        harness.trino_sqls(),
        [
            probe_sql("default_catalog", "default_schema", "t"),
            "DROP TABLE t".to_string()
        ]
    );

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(puts[0].body, vec![0x0a], "本体は改行 1 つ");
    assert_eq!(
        puts[0].content_type.as_deref(),
        Some("application/octet-stream")
    );
    assert_eq!(puts[1].key, format!("athena/{id}.txt.metadata"));
    assert_eq!(puts[1].body.len(), 41, "{:?}", puts[1].body);
    assert_eq!(
        puts[1].content_type.as_deref(),
        Some("application/octet-stream")
    );
}

#[tokio::test]
async fn 対象外の文では形式を問い合わせない() {
    let harness = Harness::builder(select_response())
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "SELECT 1",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(harness.trino_sqls(), ["SELECT 1"]);
}

#[tokio::test]
async fn 修飾名でカタログを指す文も形式を問い合わせて判定する() {
    let harness = Harness::builder(drop_table_response())
        .route(&probe_sql("cat", "ns", "t"), probe_response("iceberg"))
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DROP TABLE cat.ns.t",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    let id = execution_id(&execution);

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    // 修飾名で明示したカタログ・スキーマを使って問い合わせる（セッションの既定は使わない）。
    assert_eq!(
        harness.trino_sqls(),
        [
            probe_sql("cat", "ns", "t"),
            "DROP TABLE cat.ns.t".to_string()
        ]
    );

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(puts[0].body, vec![0x0a]);
    assert_eq!(puts[1].key, format!("athena/{id}.txt.metadata"));
    assert_eq!(puts[1].body.len(), 41);
}

#[tokio::test]
async fn 引用符付きのカタログ名にも別名を当てて問い合わせる() {
    const S3_TABLES: &str = "s3tablescatalog/my-bucket";
    let harness = Harness::builder(drop_table_response())
        .catalog_map(&[(S3_TABLES, "iceberg_catalog")])
        .route(
            &probe_sql("iceberg_catalog", "ns", "t"),
            probe_response("iceberg"),
        )
        .results_s3()
        .start()
        .await;

    let query = format!("DROP TABLE \"{S3_TABLES}\".ns.t");
    let execution = harness
        .run_query(json!({
            "QueryString": query,
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    let id = execution_id(&execution);

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    // 問い合わせは、修飾名から取り出したカタログに別名を当てた（Trino 側の）名前で送る。
    // 本体は catalog.rs の alias_qualified_names が別名で書き換えたもの（既存の振る舞い）。
    // パディングは catalog::replacement が決める（元の引用符付き識別子 27 文字 -
    // 別名を引用符で包んだ "iceberg_catalog" 17 文字 = 空白 10 個。他のテストと同じく完全一致で見る）。
    let sqls = harness.trino_sqls();
    assert_eq!(sqls[0], probe_sql("iceberg_catalog", "ns", "t"));
    assert_eq!(sqls[1], "DROP TABLE \"iceberg_catalog\"          .ns.t");

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(puts[0].body, vec![0x0a]);
    assert_eq!(puts[1].key, format!("athena/{id}.txt.metadata"));
    assert_eq!(puts[1].body.len(), 41);
}

#[tokio::test]
async fn drop_table_は_hive_なら今までどおり_0_バイトのまま() {
    let harness = Harness::builder(drop_table_response())
        .route(
            &probe_sql("default_catalog", "default_schema", "t"),
            probe_response("hive"),
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
    assert_eq!(puts.len(), 1, "{puts:?}");
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(puts[0].body, Vec::<u8>::new());
    assert_eq!(puts[0].content_type.as_deref(), Some("binary/octet-stream"));
}

#[tokio::test]
async fn 存在しないテーブルの_drop_table_if_existsは_iceberg_でも今までどおり_0_バイトのまま() {
    // カタログは iceberg だが対象テーブルが無い（件数 0）。Hive 側と同じ今までどおりの振る舞いに倒す。
    let harness = Harness::builder(drop_table_response())
        .route(
            &probe_sql("default_catalog", "default_schema", "t"),
            probe_response_missing(),
        )
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DROP TABLE IF EXISTS t",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    let id = execution_id(&execution);

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 1, "{puts:?}",);
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(
        puts[0].body,
        Vec::<u8>::new(),
        "対象が無いので今までどおり 0 バイト"
    );
    assert_eq!(puts[0].content_type.as_deref(), Some("binary/octet-stream"));
}

#[tokio::test]
async fn 取り消したなら本体も_metadata_も置かない() {
    // 形式の問い合わせ（iceberg かつ存在すると答える）を遅らせ、応答が届く前に止める。
    let harness = Harness::builder(probe_response("iceberg"))
        .results_s3()
        .statement_delay(Duration::from_millis(200))
        .start()
        .await;

    let id = harness
        .start_query(json!({
            "QueryString": "DROP TABLE t",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    common::wait_for("Trino が形式の問い合わせを受ける", || {
        harness.trino_requests().len() == 1
    })
    .await;

    let (code, _) = harness
        .call("StopQueryExecution", json!({ "QueryExecutionId": id }))
        .await;
    assert_eq!(code, 200);
    assert_eq!(harness.status(&id).await["State"], "CANCELLED");

    // 遅れて届いた形式の問い合わせの応答（iceberg・存在する）を処理しても、
    // 取り消し後は DROP TABLE 本体を Trino に送らず、本体も付随ファイルも置かない。
    tokio::time::sleep(Duration::from_millis(600)).await;
    assert_eq!(harness.status(&id).await["State"], "CANCELLED");
    assert_eq!(
        harness.trino_sqls(),
        [probe_sql("default_catalog", "default_schema", "t")]
    );
    assert!(harness.s3_puts().is_empty(), "{:?}", harness.s3_puts());
}

#[tokio::test]
async fn 取り消し済みなら形式の問い合わせも届かない() {
    // 形式の問い合わせに具体的な route を用意せず、既定の応答（endless）を返させる。
    // nextUri を辿り始めた時点で、形式の問い合わせが Trino に届いたことは確認できる。
    let harness = Harness::builder(json!({
        "columns": [
            { "name": "_col0", "type": "varchar" },
            { "name": "_col1", "type": "bigint" }
        ]
    }))
    .endless()
    .results_s3()
    .start()
    .await;

    let id = harness
        .start_query(json!({
            "QueryString": "DROP TABLE t",
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    common::wait_for(
        "形式の問い合わせが nextUri を辿り始める",
        || has_call(&harness, "GET /next"),
    )
    .await;

    let (code, _) = harness
        .call("StopQueryExecution", json!({ "QueryExecutionId": id }))
        .await;
    assert_eq!(code, 200);

    common::wait_for("Trino に DELETE が届く", || {
        has_call(&harness, "DELETE /next")
    })
    .await;

    // DELETE のあとは、続きのページも DROP TABLE 本体も届かない
    // （`Trino::execute` が `cancel` を先頭で見て HTTP を出さないため。同じ `cancel` を probe にも渡している）。
    let calls_before = harness.trino_calls().len();
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(harness.trino_calls().len(), calls_before, "続きを辿らない");
    assert_eq!(
        harness.trino_sqls(),
        [probe_sql("default_catalog", "default_schema", "t")],
        "DROP TABLE 本体は届かない"
    );
    assert_eq!(harness.status(&id).await["State"], "CANCELLED");
    assert!(harness.s3_puts().is_empty(), "{:?}", harness.s3_puts());
}

#[tokio::test]
async fn 別名を当てたカタログ名で形式を問い合わせる() {
    const S3_TABLES: &str = "s3tablescatalog/my-bucket";
    let harness = Harness::builder(drop_table_response())
        .catalog_map(&[(S3_TABLES, "iceberg_catalog")])
        .route(
            &probe_sql("iceberg_catalog", "default_schema", "t"),
            probe_response("iceberg"),
        )
        .results_s3()
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": "DROP TABLE t",
            "QueryExecutionContext": { "Catalog": S3_TABLES },
            "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
        }))
        .await;
    let id = execution_id(&execution);

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    // 問い合わせは別名解決後（Trino 側）のカタログ名で送る。
    assert_eq!(
        harness.trino_sqls(),
        [
            probe_sql("iceberg_catalog", "default_schema", "t"),
            "DROP TABLE t".to_string()
        ]
    );
    for request in harness.trino_requests() {
        assert_eq!(request.catalog.as_deref(), Some("iceberg_catalog"));
    }

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(puts[0].body, vec![0x0a]);
    assert_eq!(puts[1].key, format!("athena/{id}.txt.metadata"));
    assert_eq!(puts[1].body.len(), 41);
}

#[tokio::test]
async fn alter_table_add_columns_は_hive_なら本体_0_バイトのまま_metadataを_38_バイト書く() {
    // 2026-09-21 実測（issue #39 Phase 3b）。DROP TABLE × Iceberg（41 バイト・改行 1 つ）とは
    // 向きも中身の形も違う: ADD COLUMNS は Hive 側が対象で、本体は 0 バイトのまま。
    let harness = Harness::builder(alter_add_columns_response())
        .route(
            &probe_sql("default_catalog", "default_schema", "t"),
            probe_response("hive"),
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
    // 形式の問い合わせを本体より先に送る。
    assert_eq!(
        harness.trino_sqls(),
        [
            probe_sql("default_catalog", "default_schema", "t"),
            "ALTER TABLE t ADD COLUMNS (m int)".to_string()
        ]
    );

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 2, "{puts:?}");
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(puts[0].body, Vec::<u8>::new(), "本体は 0 バイトのまま");
    assert_eq!(
        puts[0].content_type.as_deref(),
        Some("application/octet-stream")
    );
    assert_eq!(puts[1].key, format!("athena/{id}.txt.metadata"));
    assert_eq!(puts[1].body.len(), 38, "{:?}", puts[1].body);
    assert_eq!(
        puts[1].content_type.as_deref(),
        Some("application/octet-stream")
    );
}

#[tokio::test]
async fn alter_table_add_columns_は_iceberg_なら今までどおり_0_バイトのまま_metadataも置かない() {
    let harness = Harness::builder(alter_add_columns_response())
        .route(
            &probe_sql("default_catalog", "default_schema", "t"),
            probe_response("iceberg"),
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
    assert_eq!(puts.len(), 1, "{puts:?}");
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(puts[0].body, Vec::<u8>::new());
    assert_eq!(puts[0].content_type.as_deref(), Some("binary/octet-stream"));
}

#[tokio::test]
async fn 結果_s3_が無効なら_drop_table_でも形式を問い合わせない() {
    // results_s3() を呼ばないので ATHENA_LOCAL_RESULTS=none 相当（Harness の既定）。
    // write_result は app.results が None なら判定結果を丸ごと捨てるので、probe_format を
    // 呼ぶだけ Trino へのフル往復が無駄になる（レビュー指摘）。
    let harness = Harness::builder(drop_table_response()).start().await;

    let execution = harness
        .run_query(json!({ "QueryString": "DROP TABLE t" }))
        .await;

    assert_eq!(execution["QueryExecution"]["Status"]["State"], "SUCCEEDED");
    assert_eq!(harness.trino_sqls(), ["DROP TABLE t".to_string()]);
}

#[tokio::test]
async fn add_columns_以外の_alter_table_は形式を問い合わせない() {
    // SET TBLPROPERTIES・DROP COLUMN・SET LOCATION は本物も列なしの本体・.metadata を
    // 置かない（2026-09-21 実測）ので、classification.rs の時点で対象外になり probe も飛ばない。
    for query in [
        "ALTER TABLE t SET TBLPROPERTIES ('comment' = 'remember to add column for region')",
        "ALTER TABLE t DROP COLUMN c",
        "ALTER TABLE t SET LOCATION 's3://bucket/path/'",
    ] {
        let harness = Harness::builder(json!({ "updateType": "ALTER TABLE" }))
            .results_s3()
            .start()
            .await;

        let execution = harness
            .run_query(json!({
                "QueryString": query,
                "ResultConfiguration": { "OutputLocation": "s3://results-bucket/athena/" }
            }))
            .await;

        assert_eq!(
            execution["QueryExecution"]["Status"]["State"], "SUCCEEDED",
            "{query:?}"
        );
        assert_eq!(harness.trino_sqls(), [query.to_string()], "{query:?}");

        let puts = harness.s3_puts();
        assert_eq!(puts.len(), 1, "形式を問い合わせていない: {puts:?}");
        assert_eq!(puts[0].content_type.as_deref(), Some("binary/octet-stream"));
    }
}
