//! テスト用の足場。Trino の偽物と athena-local 本体を同一プロセスで立てる。
//!
//! テストバイナリごとにこのモジュールが取り込まれるため、使われないヘルパが
//! 必ず出る（例: dml.rs は trino_requests を使わない）。
#![allow(dead_code)]

use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use athena_local::config::Config;
use axum::Router;
use axum::extract::State;
use axum::http::HeaderMap;
use axum::routing::{get, post};
use serde_json::{Value, json};
use tokio::net::TcpListener;

/// Trino が受け取ったリクエスト。ヘッダの受け渡しを検証するために記録する。
#[derive(Clone, Debug, PartialEq)]
pub struct TrinoRequest {
    pub sql: String,
    pub catalog: Option<String>,
    pub schema: Option<String>,
}

/// Trino の偽物。1 ページ目と（あれば）2 ページ目の応答を固定で返す。
#[derive(Clone)]
struct FakeTrino {
    first: Value,
    next: Option<Value>,
    requests: Arc<Mutex<Vec<TrinoRequest>>>,
}

/// 立てた偽 Trino と athena-local のセット。
pub struct Harness {
    pub athena_url: String,
    requests: Arc<Mutex<Vec<TrinoRequest>>>,
}

impl Harness {
    /// 単一ページの応答を返す Trino を立てる。
    pub async fn start(response: Value) -> Self {
        Self::start_with_pages(response, None).await
    }

    /// nextUri を辿らせる（2 ページ）Trino を立てる。
    pub async fn start_with_pages(first: Value, next: Option<Value>) -> Self {
        let requests = Arc::new(Mutex::new(Vec::new()));
        let trino_addr = spawn_trino(FakeTrino {
            first,
            next,
            requests: requests.clone(),
        })
        .await;

        let config = Config {
            bind_address: "127.0.0.1:0".to_string(),
            trino_url: format!("http://{trino_addr}"),
            trino_user: "test".to_string(),
            default_catalog: Some("default_catalog".to_string()),
            default_database: Some("default_schema".to_string()),
        };
        let athena_addr = spawn(athena_local::router(config)).await;

        Self {
            athena_url: format!("http://{athena_addr}/"),
            requests,
        }
    }

    /// Trino が受け取ったリクエスト。
    pub fn trino_requests(&self) -> Vec<TrinoRequest> {
        self.requests.lock().expect("poisoned").clone()
    }

    /// Athena のオペレーションを 1 つ呼ぶ。
    pub async fn call(&self, operation: &str, body: Value) -> (u16, Value) {
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

    /// クエリを投げ、QUEUED / RUNNING を抜けるまで待って最後の GetQueryExecution を返す。
    pub async fn run_query(&self, request: Value) -> Value {
        let (status, started) = self.call("StartQueryExecution", request).await;
        assert_eq!(status, 200, "StartQueryExecution が失敗した: {started}");

        let id = started["QueryExecutionId"]
            .as_str()
            .expect("QueryExecutionId が無い")
            .to_string();

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

/// QueryExecution から実行 ID を取り出す。
pub fn execution_id(execution: &Value) -> String {
    execution["QueryExecution"]["QueryExecutionId"]
        .as_str()
        .expect("QueryExecutionId が無い")
        .to_string()
}

/// nextUri は実際に立てたポートを指す必要があるので、bind してから応答に埋め込む。
async fn spawn_trino(mut fake: FakeTrino) -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind できない");
    let addr = listener.local_addr().expect("アドレスが取れない");

    if fake.next.is_some() {
        fake.first["nextUri"] = json!(format!("http://{addr}/next"));
    }

    let router = Router::new()
        .route("/v1/statement", post(statement))
        .route("/next", get(next_page))
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

    fake.requests.lock().expect("poisoned").push(TrinoRequest {
        sql,
        catalog: header("x-trino-catalog"),
        schema: header("x-trino-schema"),
    });

    axum::Json(fake.first.clone())
}

async fn next_page(State(fake): State<FakeTrino>) -> axum::Json<Value> {
    axum::Json(fake.next.clone().unwrap_or(Value::Null))
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
