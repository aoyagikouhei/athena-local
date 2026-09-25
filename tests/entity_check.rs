//! DESCRIBE・DESC・SHOW COLUMNS の対象の存在を、本物と同じく StartQueryExecution の時点で確かめる（#207）。
//! 本物は Glue に問い合わせ、テーブルが無ければ Entity Not Found、カタログが無ければ DATACATALOG_NOT_FOUND で
//! 開始時に弾き、ビューなら引用符付きの名前でも実行する（2026-09-25 実測。ラウンド 3・4）。
//! athena-local は形式の問い合わせと同じ `probe_sql` を開始前にも投げて決める。

mod common;

use common::{Harness, trino_error};
use serde_json::{Value, json};

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
/// tests/describe.rs・tests/table_format.rs の写し。ずれればルートに当たらずテストが落ちる）。
fn probe_sql(catalog: &str, schema: &str, table: &str) -> String {
    format!(
        "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = '{catalog}'), (SELECT table_type FROM system.jdbc.tables WHERE table_cat = '{catalog}' AND table_schem = '{schema}' AND table_name = '{table}')"
    )
}

fn probe_response(connector_name: Option<&str>, table_type: Option<&str>) -> Value {
    json!({
        "columns": [
            { "name": "_col0", "type": "varchar" },
            { "name": "_col1", "type": "varchar" }
        ],
        "data": [[connector_name, table_type]]
    })
}

const ENTITY_NOT_FOUND_PREFIX: &str = "Entity Not Found (Service: AmazonDataCatalog; Status Code: 400; Error Code: EntityNotFoundException; Request ID: ";

/// Entity Not Found の Request ID（毎回違う UUID）を取り出す。形が違えば落とす。
fn request_id(message: &Value) -> String {
    let message = message.as_str().expect("Message は文字列");
    let id = message
        .strip_prefix(ENTITY_NOT_FOUND_PREFIX)
        .and_then(|rest| rest.strip_suffix("; Proxy: null)"))
        .unwrap_or_else(|| panic!("Entity Not Found の形でない: {message}"));
    assert!(
        uuid::Uuid::parse_str(id).is_ok(),
        "Request ID が UUID でない: {id}"
    );
    id.to_string()
}

async fn start(harness: &Harness, query: &str) -> (u16, Value) {
    harness
        .call("StartQueryExecution", json!({ "QueryString": query }))
        .await
}

#[tokio::test]
async fn 実在しないテーブルへの_describe_は開始時に_entity_not_found_で弾き_実行を作らない() {
    let probe = probe_sql("default_catalog", "default_schema", "nope");
    let harness = Harness::builder(describe_response())
        .route(&probe, probe_response(Some("hive"), None))
        .start()
        .await;

    for query in ["DESCRIBE nope", r#"DESCRIBE "nope""#, "DESC nope"] {
        let (code, error) = start(&harness, query).await;
        assert_eq!(code, 400, "{query}: {error}");
        assert_eq!(error["__type"], "InvalidRequestException");
        assert_eq!(error["AthenaErrorCode"], "INVALID_INPUT");
        request_id(&error["Message"]);
    }
    assert_eq!(
        harness.trino_sqls(),
        [probe.clone(), probe.clone(), probe],
        "探索だけを送り、本体は送らない"
    );
}

#[tokio::test]
async fn entity_not_found_の_request_id_は毎回違う() {
    let harness = Harness::builder(describe_response())
        .route(
            &probe_sql("default_catalog", "default_schema", "nope"),
            probe_response(Some("hive"), None),
        )
        .start()
        .await;

    let (_, first) = start(&harness, "DESCRIBE nope").await;
    let (_, second) = start(&harness, "DESCRIBE nope").await;
    assert_ne!(
        request_id(&first["Message"]),
        request_id(&second["Message"])
    );
}

#[tokio::test]
async fn show_columns_は修飾名のスキーマで存在を確かめる() {
    let probe = probe_sql("default_catalog", "db", "nope");
    let harness = Harness::builder(describe_response())
        .route(&probe, probe_response(Some("hive"), None))
        .start()
        .await;

    for query in [
        "SHOW COLUMNS FROM db.nope",
        r#"SHOW COLUMNS IN "db"."nope""#,
    ] {
        let (code, error) = start(&harness, query).await;
        assert_eq!(code, 400, "{query}: {error}");
        assert_eq!(error["AthenaErrorCode"], "INVALID_INPUT");
    }
}

/// 本物は大文字の名前でも実在のテーブルを見つける（2026-09-25 実測 W1）。Trino のカタログは小文字で持つので、
/// 引用符付きの大文字も小文字にして引く。実在するテーブルなので #204 の構文の文言になる。
#[tokio::test]
async fn 引用符付きの大文字の名前は小文字にして存在を確かめる() {
    let probe = probe_sql("default_catalog", "default_schema", "t");
    let harness = Harness::builder(describe_response())
        .route(&probe, probe_response(Some("hive"), Some("TABLE")))
        .start()
        .await;

    let (code, error) = start(&harness, r#"DESCRIBE "T""#).await;

    assert_eq!(code, 400, "{error}");
    assert_eq!(error["AthenaErrorCode"], "MALFORMED_QUERY");
    assert_eq!(
        error["Message"],
        r#"line 1:10: no viable alternative at input 'DESCRIBE "T"'"#
    );
    assert_eq!(harness.trino_sqls(), [probe]);
}

#[tokio::test]
async fn 名前に書いたカタログが無ければ_datacatalog_not_found_で弾く() {
    let probe = probe_sql("nocat", "db", "t");
    let harness = Harness::builder(describe_response())
        .route(&probe, probe_response(None, None))
        .start()
        .await;

    for query in ["DESCRIBE nocat.db.t", "SHOW COLUMNS FROM nocat.db.t"] {
        let (code, error) = start(&harness, query).await;
        assert_eq!(code, 400, "{query}: {error}");
        assert_eq!(error["__type"], "InvalidRequestException");
        assert_eq!(error["AthenaErrorCode"], "DATACATALOG_NOT_FOUND");
        assert_eq!(error["Message"], "Catalog 'nocat' does not exist");
    }
}

/// 名前にカタログを書かず、既定のカタログが Trino に無いときの本物の文言は測っていないので、今までどおり実行する。
#[tokio::test]
async fn 既定のカタログが無いときは今までどおり実行する() {
    let probe = probe_sql("default_catalog", "default_schema", "t");
    let harness = Harness::builder(describe_response())
        .route(&probe, probe_response(None, None))
        .start()
        .await;

    let (code, body) = start(&harness, "DESCRIBE t").await;

    assert_eq!(code, 200, "{body}");
}

/// 本物はビューなら引用符付きの名前でも実行する（2026-09-25 実測 W4。SubstatementType は DESC_VIEW）。
#[tokio::test]
async fn ビューは引用符付きの名前でも弾かずに実行する() {
    let probe = probe_sql("default_catalog", "default_schema", "v");
    let harness = Harness::builder(describe_response())
        .route(&probe, probe_response(Some("hive"), Some("VIEW")))
        .start()
        .await;

    for query in [r#"DESCRIBE "v""#, r#"SHOW COLUMNS FROM "v""#] {
        let (code, body) = start(&harness, query).await;
        assert_eq!(code, 200, "{query}: {body}");
    }
}

/// 本物は S3 Tables の別名のカタログなら、存在によらず `Unsupported DDL with 2 catalogs` を返した。
/// 4 部以上の名前はそれより先に `Invalid table name`。どちらも存在を問い合わせない。
#[tokio::test]
async fn 別名のカタログと_4_部以上の名前は存在を問い合わせない() {
    let harness = Harness::builder(describe_response())
        .catalog_map(&[("s3tablescatalog/b", "s3t")])
        .start()
        .await;

    let (code, error) = start(&harness, r#"DESCRIBE "s3tablescatalog/b".ns.nope"#).await;
    assert_eq!(code, 400, "{error}");
    assert_eq!(error["Message"], "Unsupported DDL with 2 catalogs");

    let (code, error) = start(&harness, "DESCRIBE a.b.c.d").await;
    assert_eq!(code, 400, "{error}");
    assert_eq!(error["Message"], "Invalid table name a.b.c.d");

    assert!(harness.trino_requests().is_empty(), "探索も本体も送らない");
}

/// 探索が失敗したら（Trino に届かない・権限が無いなど）存在は分からないので、今までどおりに倒す:
/// 無引用なら実行し、引用符付きなら #204 の構文の文言。
#[tokio::test]
async fn 存在を確かめられなければ今までどおりに倒す() {
    let harness = Harness::builder(describe_response())
        .route(
            &probe_sql("default_catalog", "default_schema", "t"),
            trino_error("PERMISSION_DENIED", "Access Denied"),
        )
        .start()
        .await;

    let (code, body) = start(&harness, "DESCRIBE t").await;
    assert_eq!(code, 200, "{body}");

    let (code, error) = start(&harness, r#"DESCRIBE "t""#).await;
    assert_eq!(code, 400, "{error}");
    assert_eq!(error["AthenaErrorCode"], "MALFORMED_QUERY");
}

/// 探索の応答が形式の問い合わせの形（`_col0`・`_col1` の 2 列 1 行）でなければ、存在は分からないものとして扱う。
#[tokio::test]
async fn 探索の応答の形が違えば存在は分からないものとして扱う() {
    // 探索のルートを登録しないので、偽 Trino は本体の応答を返す。2 列目が null なので、形を確かめずに
    // 読むと「テーブルが無い」と取り違える。
    let harness = Harness::builder(json!({
        "columns": [
            { "name": "Column", "type": "varchar" },
            { "name": "Type", "type": "varchar" }
        ],
        "data": [["n", null]]
    }))
    .start()
    .await;

    let (code, body) = start(&harness, "DESCRIBE t").await;

    assert_eq!(code, 200, "{body}");
}
