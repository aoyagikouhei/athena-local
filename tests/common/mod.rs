//! テスト用の足場。Trino と S3 の偽物と athena-local 本体を同一プロセスで立てる。
//!
//! テストバイナリごとにこのモジュールが取り込まれるため、使われないヘルパが
//! 必ず出る（例: dml.rs は trino_requests を使わない）。
#![allow(dead_code)]

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use athena_local::config::{Config, ResultsMode, S3Settings};
use axum::Router;
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::routing::{get, post, put};
use serde_json::{Value, json};
use tokio::net::TcpListener;
use uuid::Uuid;

/// Trino が受け取ったリクエスト。ヘッダの受け渡しを検証するために記録する。
#[derive(Clone, Debug, PartialEq)]
pub struct TrinoRequest {
    pub sql: String,
    pub catalog: Option<String>,
    pub schema: Option<String>,
    pub client_capabilities: Option<String>,
}

/// athena-local が構文を確かめるときに付ける前置き（src/trino.rs と同じ）。
const SYNTAX_CHECK_PREFIX: &str = "PREPARE athena_local_syntax_check FROM\n";

/// 終わらないクエリの 1 ページごとの待ち時間。無遅延だと実行側が偽 Trino を全速で叩き続ける。
const ENDLESS_PAGE_INTERVAL: Duration = Duration::from_millis(20);

/// Trino の偽物。SQL が routes に一致すればその応答を、
/// しなければ 1 ページ目と（あれば）2 ページ目の応答を固定で返す。
#[derive(Clone)]
struct FakeTrino {
    first: Value,
    next: Option<Value>,
    routes: Arc<HashMap<String, Value>>,
    requests: Arc<Mutex<Vec<TrinoRequest>>>,
    /// nextUri を返し続ける（終わらないクエリ）。
    endless: bool,
    /// 実際に立てたポートを指す nextUri。立てるときに決まる。
    next_uri: String,
    /// POST /v1/statement の応答を返すまでの待ち時間。
    statement_delay: Option<Duration>,
    /// nextUri への GET / DELETE を届いた順に `GET /next` の形で残す。
    calls: Arc<Mutex<Vec<String>>>,
    /// 構文の確認（PREPARE）で届いた元の SQL → 返す応答。無ければ成功を返す。
    syntax_checks: Arc<HashMap<String, Value>>,
    /// 構文の確認で届いた元の SQL を届いた順に。
    checked: Arc<Mutex<Vec<String>>>,
}

/// 偽 S3 が受けた PUT。
#[derive(Clone, Debug, PartialEq)]
pub struct S3Put {
    pub bucket: String,
    /// パーセントエンコードを戻したキー。
    pub key: String,
    pub body: String,
    pub content_type: Option<String>,
    /// 署名付き URL（クエリ文字列の X-Amz-Signature）で来たか。署名の中身は見ない。
    pub presigned: bool,
}

/// S3 の偽物。`PUT /{bucket}/{key}` を記録して、決めたステータスを返すだけ。
#[derive(Clone)]
struct FakeS3 {
    status: StatusCode,
    /// 受けたことを記録してから応答するまでの待ち時間。
    delay: Option<Duration>,
    puts: Arc<Mutex<Vec<S3Put>>>,
}

/// 立てた偽 Trino と athena-local のセット。
pub struct Harness {
    pub athena_url: String,
    requests: Arc<Mutex<Vec<TrinoRequest>>>,
    calls: Arc<Mutex<Vec<String>>>,
    puts: Arc<Mutex<Vec<S3Put>>>,
    checked: Arc<Mutex<Vec<String>>>,
}

/// 偽 Trino の応答を組み立ててから立てる。
pub struct HarnessBuilder {
    first: Value,
    next: Option<Value>,
    routes: HashMap<String, Value>,
    catalog_map: HashMap<String, String>,
    endless: bool,
    statement_delay: Option<Duration>,
    /// Some なら ATHENA_LOCAL_RESULTS=s3 にして偽 S3 を立てる。
    s3: Option<S3Options>,
    syntax_checks: HashMap<String, Value>,
}

struct S3Options {
    default_output_location: Option<String>,
    status: StatusCode,
    delay: Option<Duration>,
}

impl HarnessBuilder {
    /// この SQL の構文の確認（PREPARE）に返す応答。message は Trino と同じく前置きの分だけ行がずれた位置で書く。
    pub fn syntax_check_response(mut self, sql: &str, response: Value) -> Self {
        self.syntax_checks.insert(sql.to_string(), response);
        self
    }

    /// 結果 CSV を偽 S3 に書かせる（ATHENA_LOCAL_RESULTS=s3）。
    pub fn results_s3(mut self) -> Self {
        self.s3 = Some(S3Options {
            default_output_location: None,
            status: StatusCode::OK,
            delay: None,
        });
        self
    }

    /// ATHENA_LOCAL_OUTPUT_LOCATION にあたる既定。results_s3 のあとに呼ぶ。
    pub fn default_output_location(mut self, location: &str) -> Self {
        self.s3_options().default_output_location = Some(location.to_string());
        self
    }

    /// 偽 S3 が PUT に返すステータス。results_s3 のあとに呼ぶ。
    pub fn s3_status(mut self, status: u16) -> Self {
        self.s3_options().status = StatusCode::from_u16(status).expect("ステータスでない");
        self
    }

    /// 偽 S3 が PUT を受けてから応答するまで待たせる。results_s3 のあとに呼ぶ。
    pub fn s3_delay(mut self, delay: Duration) -> Self {
        self.s3_options().delay = Some(delay);
        self
    }

    fn s3_options(&mut self) -> &mut S3Options {
        self.s3.as_mut().expect("先に results_s3 を呼ぶ")
    }

    /// 最初の応答に nextUri を付け、以降も nextUri だけを返し続ける（止めるまで終わらない）。
    pub fn endless(mut self) -> Self {
        self.endless = true;
        self
    }

    /// POST /v1/statement を受けてから応答するまで待たせる。受けたことは待つ前に記録する。
    pub fn statement_delay(mut self, delay: Duration) -> Self {
        self.statement_delay = Some(delay);
        self
    }

    /// nextUri を辿らせる 2 ページ目の応答。
    pub fn next_page(mut self, next: Value) -> Self {
        self.next = Some(next);
        self
    }

    /// この SQL を受けたときだけ返す応答（単一ページ）。
    pub fn route(mut self, sql: &str, response: Value) -> Self {
        self.routes.insert(sql.to_string(), response);
        self
    }

    /// athena-local の TRINO_CATALOG_MAP にあたる別名。
    pub fn catalog_map(mut self, pairs: &[(&str, &str)]) -> Self {
        self.catalog_map = pairs
            .iter()
            .map(|(from, to)| (from.to_string(), to.to_string()))
            .collect();
        self
    }

    pub async fn start(self) -> Harness {
        let requests = Arc::new(Mutex::new(Vec::new()));
        let calls = Arc::new(Mutex::new(Vec::new()));
        let checked = Arc::new(Mutex::new(Vec::new()));
        let trino_addr = spawn_trino(FakeTrino {
            first: self.first,
            next: self.next,
            routes: Arc::new(self.routes),
            requests: requests.clone(),
            endless: self.endless,
            next_uri: String::new(),
            statement_delay: self.statement_delay,
            calls: calls.clone(),
            syntax_checks: Arc::new(self.syntax_checks),
            checked: checked.clone(),
        })
        .await;

        let puts = Arc::new(Mutex::new(Vec::new()));
        let results = match self.s3 {
            Some(options) => {
                let s3_addr = spawn(fake_s3(FakeS3 {
                    status: options.status,
                    delay: options.delay,
                    puts: puts.clone(),
                }))
                .await;
                ResultsMode::S3(S3Settings {
                    endpoint: reqwest::Url::parse(&format!("http://{s3_addr}")).unwrap(),
                    access_key_id: "test-key".to_string(),
                    secret_access_key: "test-secret".to_string(),
                    region: "us-east-1".to_string(),
                    default_output_location: options.default_output_location,
                })
            }
            None => ResultsMode::None,
        };

        let config = Config {
            bind_address: "127.0.0.1:0".to_string(),
            trino_url: format!("http://{trino_addr}"),
            trino_user: "test".to_string(),
            default_catalog: Some("default_catalog".to_string()),
            default_database: Some("default_schema".to_string()),
            catalog_map: self.catalog_map,
            results,
        };
        let athena_addr = spawn(athena_local::router(config)).await;

        Harness {
            athena_url: format!("http://{athena_addr}/"),
            requests,
            calls,
            puts,
            checked,
        }
    }
}

impl Harness {
    /// 既定の応答を決めて組み立てを始める。
    pub fn builder(response: Value) -> HarnessBuilder {
        HarnessBuilder {
            first: response,
            next: None,
            routes: HashMap::new(),
            catalog_map: HashMap::new(),
            endless: false,
            statement_delay: None,
            s3: None,
            syntax_checks: HashMap::new(),
        }
    }

    /// 単一ページの応答を返す Trino を立てる。
    pub async fn start(response: Value) -> Self {
        Self::builder(response).start().await
    }

    /// nextUri を辿らせる（2 ページ）Trino を立てる。
    pub async fn start_with_pages(first: Value, next: Value) -> Self {
        Self::builder(first).next_page(next).start().await
    }

    /// Trino が受け取ったリクエスト。
    pub fn trino_requests(&self) -> Vec<TrinoRequest> {
        self.requests.lock().expect("poisoned").clone()
    }

    /// Trino が受け取った SQL だけを順に並べたもの。
    pub fn trino_sqls(&self) -> Vec<String> {
        self.trino_requests()
            .into_iter()
            .map(|request| request.sql)
            .collect()
    }

    /// nextUri への GET / DELETE（`GET /next` / `DELETE /next`）を届いた順に。
    pub fn trino_calls(&self) -> Vec<String> {
        self.calls.lock().expect("poisoned").clone()
    }

    /// 構文の確認（PREPARE）で Trino に届いた元の SQL を届いた順に。trino_requests には入らない。
    pub fn syntax_checks(&self) -> Vec<String> {
        self.checked.lock().expect("poisoned").clone()
    }

    /// 偽 S3 が受けた PUT を届いた順に。
    pub fn s3_puts(&self) -> Vec<S3Put> {
        self.puts.lock().expect("poisoned").clone()
    }

    /// Athena のオペレーションを 1 つ呼ぶ。SDK と同じく、StartQueryExecution で
    /// ClientRequestToken を指定しなければ、呼び出しごとに UUID を入れてから送る。
    /// トークンを付けずに送りたいテストは call_raw を使う。
    pub async fn call(&self, operation: &str, mut body: Value) -> (u16, Value) {
        if operation == "StartQueryExecution"
            && let Some(object) = body.as_object_mut()
            && !object.contains_key("ClientRequestToken")
        {
            object.insert(
                "ClientRequestToken".to_string(),
                Value::String(Uuid::new_v4().to_string()),
            );
        }

        self.call_raw(operation, body).await
    }

    /// call からトークンの自動挿入を除いたもの。トークン無しの挙動を確かめるテスト用。
    pub async fn call_raw(&self, operation: &str, body: Value) -> (u16, Value) {
        let response = reqwest::Client::new()
            .post(&self.athena_url)
            .header("X-Amz-Target", format!("AmazonAthena.{operation}"))
            .header("Content-Type", "application/x-amz-json-1.1")
            .body(body.to_string())
            .send()
            .await
            .expect("athena-local に繋がらない");

        let status = response.status().as_u16();
        let payload: Value = response.json().await.unwrap_or(Value::Null);

        (status, payload)
    }

    /// クエリを投げて実行 ID を返す（終わるのは待たない）。
    pub async fn start_query(&self, request: Value) -> String {
        let (status, started) = self.call("StartQueryExecution", request).await;
        assert_eq!(status, 200, "StartQueryExecution が失敗した: {started}");

        started["QueryExecutionId"]
            .as_str()
            .expect("QueryExecutionId が無い")
            .to_string()
    }

    /// GetQueryExecution の QueryExecution.Status。
    pub async fn status(&self, id: &str) -> Value {
        let (_, execution) = self
            .call("GetQueryExecution", json!({ "QueryExecutionId": id }))
            .await;
        execution["QueryExecution"]["Status"].clone()
    }

    /// クエリを投げ、QUEUED / RUNNING を抜けるまで待って最後の GetQueryExecution を返す。
    pub async fn run_query(&self, request: Value) -> Value {
        let id = self.start_query(request).await;

        for _ in 0..100 {
            let (_, execution) = self
                .call("GetQueryExecution", json!({ "QueryExecutionId": id }))
                .await;
            let state = execution["QueryExecution"]["Status"]["State"]
                .as_str()
                .unwrap_or_default();

            if state != "QUEUED" && state != "RUNNING" {
                return execution;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }

        panic!("クエリが終わらない");
    }
}

/// 条件が成り立つまで待つ。成り立たなければ what を添えて落ちる。
pub async fn wait_for(what: &str, mut check: impl FnMut() -> bool) {
    for _ in 0..200 {
        if check() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("待っても起きなかった: {what}");
}

/// QueryExecution から実行 ID を取り出す。
pub fn execution_id(execution: &Value) -> String {
    execution["QueryExecution"]["QueryExecutionId"]
        .as_str()
        .expect("QueryExecutionId が無い")
        .to_string()
}

/// Trino のエラー応答（Trino 482 の実物から必要な項目だけ抜いた形）。
pub fn trino_error(error_name: &str, message: &str) -> Value {
    json!({
        "error": {
            "message": message,
            "errorName": error_name,
            "errorType": "USER_ERROR"
        }
    })
}

/// 1 列 1 行の成功応答。
pub fn trino_single_value(type_name: &str, value: Value) -> Value {
    json!({
        "columns": [{ "name": "_col0", "type": type_name }],
        "data": [[value]]
    })
}

/// nextUri は実際に立てたポートを指す必要があるので、bind してから応答に埋め込む。
async fn spawn_trino(mut fake: FakeTrino) -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind できない");
    let addr = listener.local_addr().expect("アドレスが取れない");

    if fake.next.is_some() || fake.endless {
        fake.next_uri = format!("http://{addr}/next");
        fake.first["nextUri"] = json!(fake.next_uri);
    }

    let router = Router::new()
        .route("/v1/statement", post(statement))
        .route("/next", get(next_page).delete(cancel_statement))
        .with_state(fake);

    tokio::spawn(async move {
        axum::serve(listener, router).await.expect("serve が落ちた");
    });

    addr
}

async fn statement(
    State(fake): State<FakeTrino>,
    headers: HeaderMap,
    sql: String,
) -> axum::Json<Value> {
    let header = |name: &str| {
        headers
            .get(name)
            .and_then(|value| value.to_str().ok())
            .map(str::to_string)
    };

    // 構文の確認は本体の実行とは別に記録し、遅らせもしない。
    if let Some(original) = sql.strip_prefix(SYNTAX_CHECK_PREFIX) {
        fake.checked
            .lock()
            .expect("poisoned")
            .push(original.to_string());
        return axum::Json(
            fake.syntax_checks
                .get(original)
                .cloned()
                .unwrap_or_else(|| json!({ "updateType": "PREPARE" })),
        );
    }

    let response = fake
        .routes
        .get(&sql)
        .cloned()
        .unwrap_or_else(|| fake.first.clone());

    fake.requests.lock().expect("poisoned").push(TrinoRequest {
        sql,
        catalog: header("x-trino-catalog"),
        schema: header("x-trino-schema"),
        client_capabilities: header("x-trino-client-capabilities"),
    });

    if let Some(delay) = fake.statement_delay {
        tokio::time::sleep(delay).await;
    }

    axum::Json(response)
}

async fn next_page(State(fake): State<FakeTrino>) -> axum::Json<Value> {
    fake.calls
        .lock()
        .expect("poisoned")
        .push("GET /next".to_string());

    if fake.endless {
        tokio::time::sleep(ENDLESS_PAGE_INTERVAL).await;
        return axum::Json(json!({ "nextUri": fake.next_uri }));
    }
    axum::Json(fake.next.clone().unwrap_or(Value::Null))
}

/// Trino はクエリの取り消しに 204 を返す。
async fn cancel_statement(State(fake): State<FakeTrino>) -> StatusCode {
    fake.calls
        .lock()
        .expect("poisoned")
        .push("DELETE /next".to_string());
    StatusCode::NO_CONTENT
}

fn fake_s3(fake: FakeS3) -> Router {
    Router::new()
        .route("/{bucket}/{*key}", put(put_object))
        .with_state(fake)
}

async fn put_object(
    State(fake): State<FakeS3>,
    Path((bucket, key)): Path<(String, String)>,
    Query(query): Query<HashMap<String, String>>,
    headers: HeaderMap,
    body: String,
) -> (StatusCode, &'static str) {
    fake.puts.lock().expect("poisoned").push(S3Put {
        bucket,
        key,
        body,
        content_type: headers
            .get("content-type")
            .and_then(|value| value.to_str().ok())
            .map(str::to_string),
        presigned: query.contains_key("X-Amz-Signature"),
    });

    if let Some(delay) = fake.delay {
        tokio::time::sleep(delay).await;
    }

    if fake.status.is_success() {
        (fake.status, "")
    } else {
        (
            fake.status,
            "<Error><Code>InternalError</Code><Message>fake failure</Message></Error>",
        )
    }
}

async fn spawn(router: Router) -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind できない");
    let addr = listener.local_addr().expect("アドレスが取れない");

    tokio::spawn(async move {
        axum::serve(listener, router).await.expect("serve が落ちた");
    });

    addr
}
