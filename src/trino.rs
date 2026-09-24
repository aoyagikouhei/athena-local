use std::fmt;
use std::sync::atomic::{AtomicBool, Ordering};
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
    /// Trino のクエリ ID。`.metadata` の先頭に載せる。
    pub id: Option<String>,
    /// Trino の updateType。DML と DDL で入る。
    pub update_type: Option<String>,
    /// 完了時に作り直した文（SHOW COLUMNS など）の ColumnInfo。`convert::column_infos` が
    /// Trino の列より優先する（#173）。Trino から受け取った結果では None。
    pub athena_columns: Option<Vec<crate::athena::ColumnInfo>>,
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
    /// Trino の errorType（USER_ERROR / INTERNAL_ERROR / INSUFFICIENT_RESOURCES / EXTERNAL）。接続失敗などは None。
    pub error_type: Option<String>,
}

/// 実行の取り消し要求。StopQueryExecution が立て、nextUri を辿る側がページ境界で見る。
#[derive(Default, Debug)]
pub struct Cancel(AtomicBool);

impl Cancel {
    pub fn request(&self) {
        self.0.store(true, Ordering::SeqCst);
    }

    pub fn is_requested(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

/// 構文だけを確かめるときに元の SQL の前に付ける。PREPARE は SQL を読むだけで実行しない。
/// 改行で区切るので、エラーの位置は行番号が 1 つずれるだけになる。
const SYNTAX_CHECK_PREFIX: &str = "PREPARE athena_local_syntax_check FROM\n";

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
        cancel: &Cancel,
    ) -> Result<Outcome, QueryError> {
        // 分類の問い合わせの途中で止められたら、残りは Trino に送らない。
        if cancel.is_requested() {
            return Err(QueryError::cancelled());
        }

        let mut statement = self.start(sql, catalog, schema).await?;
        let mut outcome = Outcome::default();

        loop {
            if let Some(error) = statement.error {
                return Err(error.into_query_error());
            }
            outcome.absorb(&mut statement);

            let Some(next_uri) = statement.next_uri.take() else {
                return Ok(outcome);
            };
            statement = self.follow(&next_uri, cancel).await?;
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
            .header("X-Trino-User", &self.user)
            // 付けないと Trino は timestamp を小数 3 桁に丸めて返す（timestamp(6) の .789123 が .789、
            // timestamp(0) が .000 になる）。Athena は精度どおりに返す（2026-09-14 実測）。
            .header("X-Trino-Client-Capabilities", "PARAMETRIC_DATETIME");

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

    async fn follow(&self, uri: &str, cancel: &Cancel) -> Result<Statement, QueryError> {
        for _ in 0..MAX_RETRIES {
            // 取り消しはページ境界（503 の待ち直しを含む）で見る。進行中の long-poll は打ち切らない。
            if cancel.is_requested() {
                self.abort(uri).await;
                return Err(QueryError::cancelled());
            }

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

    /// 構文エラーなら、元の SQL の位置で数えたメッセージを返す。
    /// 構文エラー以外の失敗（Trino に届かない、PREPARE できない文など）は None にして、実行に任せる。
    pub async fn syntax_error(&self, sql: &str) -> Option<String> {
        let never = Cancel::default();
        let mut statement = self
            .start(&format!("{SYNTAX_CHECK_PREFIX}{sql}"), None, None)
            .await
            .ok()?;

        loop {
            if let Some(error) = statement.error.take() {
                return (error.error_name.as_deref() == Some("SYNTAX_ERROR"))
                    .then(|| unshift_line(&error.message));
            }
            let next_uri = statement.next_uri.take()?;
            statement = self.follow(&next_uri, &never).await.ok()?;
        }
    }

    /// Trino の取り消しは nextUri（どのページのものでもよい）への DELETE。
    /// 状態は StopQueryExecution が先に CANCELLED にしているので、届かなくても結果は見ない。
    async fn abort(&self, uri: &str) {
        let _ = self.http.delete(uri).send().await;
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

        if let Some(id) = statement.id.take() {
            self.id = Some(id);
        }

        // 下の data の判定がまだ statement.update_type を見るので、take() せずに写す。
        if statement.update_type.is_some() {
            self.update_type = statement.update_type.clone();
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
            error_type: None,
        }
    }

    /// 取り消されて途中でやめた。状態は先に CANCELLED で確定しているので、この値は表に出ない。
    fn cancelled() -> Self {
        Self::other("取り消されました".to_string())
    }
}

/// SYNTAX_CHECK_PREFIX で 1 行ずれた `line N:` を元の行番号に戻す。
fn unshift_line(message: &str) -> String {
    let shifted = message
        .strip_prefix("line ")
        .and_then(|rest| rest.split_once(':'))
        .and_then(|(line, rest)| Some((line.parse::<u32>().ok()?, rest)));

    match shifted {
        Some((line, rest)) if line > 1 => format!("line {}:{rest}", line - 1),
        _ => message.to_string(),
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
    id: Option<String>,
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
    error_type: Option<String>,
}

impl StatementError {
    fn into_query_error(self) -> QueryError {
        QueryError {
            name: self.error_name,
            message: self.message,
            error_type: self.error_type,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 構文を確かめたときの行番号を元の_sql_の行に戻す() {
        assert_eq!(
            unshift_line("line 2:1: mismatched input 'SELEC'. Expecting: 'ALTER'"),
            "line 1:1: mismatched input 'SELEC'. Expecting: 'ALTER'"
        );
        assert_eq!(
            unshift_line("line 3:6: mismatched input 'WHERE'"),
            "line 2:6: mismatched input 'WHERE'"
        );
        // 位置の無いメッセージや 1 行目（前置きの中）はそのまま。
        assert_eq!(unshift_line("Division by zero"), "Division by zero");
        assert_eq!(unshift_line("line 1:9: x"), "line 1:9: x");
    }

    #[test]
    fn trino_の_id_と_updatetype_を_outcome_に写す() {
        // Trino が UPDATE に返すページ。更新件数は data（列 rows）にも載るが行としては扱わない。
        let mut statement: Statement = serde_json::from_str(
            r#"{
                "id": "20260917_000000_00000_local",
                "updateType": "UPDATE",
                "updateCount": 3,
                "columns": [{"name": "rows", "type": "bigint"}],
                "data": [[3]]
            }"#,
        )
        .expect("Statement を読めない");

        let mut outcome = Outcome::default();
        outcome.absorb(&mut statement);

        assert_eq!(outcome.id.as_deref(), Some("20260917_000000_00000_local"));
        assert_eq!(outcome.update_type.as_deref(), Some("UPDATE"));
        assert_eq!(outcome.update_count, Some(3));
        assert_eq!(outcome.columns.len(), 1);
        assert!(
            outcome.rows.is_empty(),
            "updateType のある data を行にしている: {:?}",
            outcome.rows
        );
    }
}
