//! DROP TABLE の結果ファイルを対象テーブルの形式（Trino のコネクタ）で書き分ける（issue #39 Phase 1）。
//! Phase 1 の対象は DROP TABLE のみで、かつ修飾名でカタログを明示していない文だけ。
//! 41 バイトのバイト単位の固定は tests/metadata.rs に集約し、ここでは結合レベル
//! （バイト数・Content-Type・キーの有無）だけを見る（計画レビュー F）。

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

/// テーブルの形式を聞く問い合わせ（`src/operation/table_format.rs` の `probe_format` と同じ形）。
fn probe_sql(catalog: &str) -> String {
    format!("SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = '{catalog}'")
}

fn connector_response(connector_name: &str) -> Value {
    json!({
        "columns": [{ "name": "connector_name", "type": "varchar" }],
        "data": [[connector_name]]
    })
}

fn drop_table_response() -> Value {
    json!({ "updateType": "DROP TABLE" })
}

fn has_call(harness: &Harness, call: &str) -> bool {
    harness.trino_calls().iter().any(|c| c == call)
}

#[tokio::test]
async fn drop_table_は_iceberg_なら改行1つと_41_バイトを書く() {
    let harness = Harness::builder(drop_table_response())
        .route(&probe_sql("default_catalog"), connector_response("iceberg"))
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
        [probe_sql("default_catalog"), "DROP TABLE t".to_string()]
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
async fn 修飾名でカタログを指す文は判定せず今までどおりになる() {
    let harness = Harness::builder(drop_table_response())
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
    // 形式を問い合わせず、本体だけ送る。
    assert_eq!(harness.trino_sqls(), ["DROP TABLE cat.ns.t"]);

    let puts = harness.s3_puts();
    assert_eq!(puts.len(), 1, "{puts:?}",);
    assert_eq!(puts[0].key, format!("athena/{id}.txt"));
    assert_eq!(puts[0].body, Vec::<u8>::new(), "今までどおり 0 バイト");
    assert_eq!(puts[0].content_type.as_deref(), Some("binary/octet-stream"));
}

#[tokio::test]
async fn drop_table_は_hive_なら今までどおり_0_バイトのまま() {
    let harness = Harness::builder(drop_table_response())
        .route(&probe_sql("default_catalog"), connector_response("hive"))
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
async fn 取り消したなら本体も_metadata_も置かない() {
    // 形式の問い合わせ（iceberg と答える）を遅らせ、応答が届く前に止める。
    let harness = Harness::builder(connector_response("iceberg"))
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

    // 遅れて届いた形式の問い合わせの応答（iceberg）を処理しても、
    // 取り消し後は DROP TABLE 本体を Trino に送らず、本体も付随ファイルも置かない。
    tokio::time::sleep(Duration::from_millis(600)).await;
    assert_eq!(harness.status(&id).await["State"], "CANCELLED");
    assert_eq!(harness.trino_sqls(), [probe_sql("default_catalog")]);
    assert!(harness.s3_puts().is_empty(), "{:?}", harness.s3_puts());
}

#[tokio::test]
async fn 取り消し済みなら形式の問い合わせも届かない() {
    // 形式の問い合わせに具体的な route を用意せず、既定の応答（endless）を返させる。
    // nextUri を辿り始めた時点で、形式の問い合わせが Trino に届いたことは確認できる。
    let harness = Harness::builder(json!({
        "columns": [{ "name": "connector_name", "type": "varchar" }]
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
        [probe_sql("default_catalog")],
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
        .route(&probe_sql("iceberg_catalog"), connector_response("iceberg"))
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
        [probe_sql("iceberg_catalog"), "DROP TABLE t".to_string()]
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
