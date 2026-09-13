use std::fmt;
use std::time::Duration;

use serde::Deserialize;

/// Trino の HTTP プロトコル(`POST /v1/statement` → `nextUri` を辿る)クライアント。
pub struct Trino {
    http: reqwest::Client,
    base_url: String,
    user: String,
}

/// 1 クエリぶんの実行結果。
#[derive(Default)]
pub struct Outcome {
    pub columns: Vec<Column>,
    pub rows: Vec<Vec<serde_json::Value>>,
    /// DML なら更新件数。SELECT では None。
    pub update_count: Option<i64>,
}

pub struct Column {
    pub name: String,
    /// Trino の型名。Athena の ColumnInfo.Type にそのまま載せる。
    pub type_name: String,
    /// 構造化された型（Trino の typeSignature）。複合型の値を Athena の表記にするときに使う。
    pub type_signature: Option<serde_json::Value>,
}

/// クエリの失敗。Trino が返したエラーなら errorName を持つ（接続失敗などは None）。
#[derive(Debug)]
pub struct QueryError {
    pub name: Option<String>,
    pub message: String,
}

/// 503 は「まだ結果が無い」の合図なので、この間隔で追従し直す。
const RETRY_INTERVAL: Duration = Duration::from_millis(50);
const MAX_RETRIES: usize = 200;

impl Trino {
    pub fn new(base_url: &str, user: &str) -> Self {
        Self {
            http: reqwest::Client::new(),
            base_url: base_url.trim_end_matches('/').to_string(),
            user: user.to_string(),
        }
    }

    pub async fn execute(
        &self,
        sql: &str,
        catalog: Option<&str>,
        schema: Option<&str>,
    ) -> Result<Outcome, QueryError> {
        let mut statement = self.start(sql, catalog, schema).await?;
        let mut outcome = Outcome::default();

        loop {
            if let Some(error) = statement.error {
                return Err(error.into_query_error());
            }
            outcome.absorb(&mut statement);

            let Some(next_uri) = statement.next_uri.clone() else {
                return Ok(outcome);
            };
            statement = self.follow(&next_uri).await?;
        }
    }

    async fn start(
        &self,
        sql: &str,
        catalog: Option<&str>,
        schema: Option<&str>,
    ) -> Result<Statement, QueryError> {
        let mut request = self
            .http
            .post(format!("{}/v1/statement", self.base_url))
            .header("X-Trino-User", &self.user);

        // 未指定なら送らない。Trino 側は SQL 内の修飾名で解決する。
        if let Some(catalog) = catalog {
            request = request.header("X-Trino-Catalog", catalog);
        }
        if let Some(schema) = schema {
            request = request.header("X-Trino-Schema", schema);
        }

        let response = request
            .body(sql.to_string())
            .send()
            .await
            .map_err(|e| QueryError::other(format!("trino への接続に失敗しました: {e}")))?;

        parse(response).await
    }

    async fn follow(&self, uri: &str) -> Result<Statement, QueryError> {
        for _ in 0..MAX_RETRIES {
            let response =
                self.http.get(uri).send().await.map_err(|e| {
                    QueryError::other(format!("trino からの取得に失敗しました: {e}"))
                })?;

            // 503 は結果がまだ無いだけなので、同じ URI を叩き直す。
            if response.status() == reqwest::StatusCode::SERVICE_UNAVAILABLE {
                tokio::time::sleep(RETRY_INTERVAL).await;
                continue;
            }

            return parse(response).await;
        }

        Err(QueryError::other(
            "trino が 503 を返し続けました".to_string(),
        ))
    }
}

impl Outcome {
    /// Trino は同じ結果をページごとに分けて返すので、受け取ったぶんを足していく。
    fn absorb(&mut self, statement: &mut Statement) {
        if self.columns.is_empty()
            && let Some(columns) = statement.columns.take()
        {
            self.columns = columns
                .into_iter()
                .map(|column| Column {
                    name: column.name,
                    type_name: column.type_name,
                    type_signature: column.type_signature,
                })
                .collect();
        }

        if let Some(update_count) = statement.update_count {
            self.update_count = Some(update_count);
        }

        // DML の data は更新件数（列名 rows）なので行としては扱わない。
        if statement.update_type.is_none()
            && let Some(data) = statement.data.take()
        {
            self.rows.extend(data);
        }
    }
}

impl QueryError {
    fn other(message: String) -> Self {
        Self {
            name: None,
            message,
        }
    }
}

/// StateChangeReason に載せる形。本物の Athena と同じく `ERROR_NAME: message`。
impl fmt::Display for QueryError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.name {
            Some(name) => write!(f, "{name}: {}", self.message),
            None => f.write_str(&self.message),
        }
    }
}

async fn parse(response: reqwest::Response) -> Result<Statement, QueryError> {
    let status = response.status();
    let body = response
        .text()
        .await
        .map_err(|e| QueryError::other(format!("trino の応答を読めませんでした: {e}")))?;

    if !status.is_success() {
        return Err(QueryError::other(format!(
            "trino が {status} を返しました: {body}"
        )));
    }

    serde_json::from_str(&body)
        .map_err(|e| QueryError::other(format!("trino の応答を解釈できません: {e}: {body}")))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Statement {
    next_uri: Option<String>,
    columns: Option<Vec<StatementColumn>>,
    data: Option<Vec<Vec<serde_json::Value>>>,
    update_type: Option<String>,
    update_count: Option<i64>,
    error: Option<StatementError>,
}

#[derive(Deserialize)]
struct StatementColumn {
    name: String,
    #[serde(rename = "type")]
    type_name: String,
    #[serde(rename = "typeSignature", default)]
    type_signature: Option<serde_json::Value>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StatementError {
    message: String,
    error_name: Option<String>,
}

impl StatementError {
    fn into_query_error(self) -> QueryError {
        QueryError {
            name: self.error_name,
            message: self.message,
        }
    }
}
