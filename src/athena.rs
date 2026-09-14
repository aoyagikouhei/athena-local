//! Athena API(awsJson1.1)のリクエスト/レスポンス形。
//! フィールド名は PascalCase で、SDK が送受信する JSON とそのまま対応する。

use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct StartQueryExecutionRequest {
    pub query_string: String,
    #[serde(default)]
    pub query_execution_context: Option<QueryExecutionContext>,
    /// `?` に位置順で当てる値。未指定と null は空として扱う。
    #[serde(default)]
    pub execution_parameters: Option<Vec<String>>,
    /// OutputLocation だけを使う（暗号化などの設定は受け取って無視する）。
    #[serde(default)]
    pub result_configuration: Option<ResultConfiguration>,
}

#[derive(Deserialize, Serialize, Default)]
#[serde(rename_all = "PascalCase")]
pub struct ResultConfiguration {
    /// リクエストでは `s3://bucket/prefix`、GetQueryExecution ではファイルまでのフルパス。
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_location: Option<String>,
}

#[derive(Deserialize, Serialize, Clone, Default)]
#[serde(rename_all = "PascalCase")]
pub struct QueryExecutionContext {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub database: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub catalog: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct StartQueryExecutionResponse {
    pub query_execution_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct GetQueryExecutionRequest {
    pub query_execution_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct StopQueryExecutionRequest {
    pub query_execution_id: String,
}

/// 本物は空のオブジェクト `{}` を返す。
#[derive(Serialize)]
pub struct StopQueryExecutionResponse {}

#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct GetQueryExecutionResponse {
    pub query_execution: QueryExecution,
}

#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct QueryExecution {
    pub query_execution_id: String,
    pub query: String,
    /// DML / DDL / UTILITY。
    pub statement_type: String,
    /// CREATE_TABLE / INSERT / SHOW_TABLES など。実測していない形の文では省く。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub substatement_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result_configuration: Option<ResultConfiguration>,
    pub query_execution_context: QueryExecutionContext,
    pub status: Status,
    pub statistics: Statistics,
    pub work_group: String,
}

#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct Status {
    pub state: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state_change_reason: Option<String>,
    pub submission_date_time: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completion_date_time: Option<f64>,
}

/// 時間は athena-local で測ったもの。スキャン量は課金の計算に使われると誤解を招くので 0 のまま。
#[derive(Serialize, Default, Debug, PartialEq, Eq)]
#[serde(rename_all = "PascalCase")]
pub struct Statistics {
    pub engine_execution_time_in_millis: i64,
    pub data_scanned_in_bytes: i64,
    pub total_execution_time_in_millis: i64,
    pub query_queue_time_in_millis: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct GetQueryResultsRequest {
    pub query_execution_id: String,
    #[serde(default)]
    pub max_results: Option<i32>,
    #[serde(default)]
    pub next_token: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct GetQueryResultsResponse {
    pub result_set: ResultSet,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub update_count: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub next_token: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct ResultSet {
    pub rows: Vec<Row>,
    pub result_set_metadata: ResultSetMetadata,
}

#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct Row {
    pub data: Vec<Datum>,
}

/// NULL は VarCharValue ごと省略する（本物と同じ）。
#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct Datum {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub var_char_value: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct ResultSetMetadata {
    pub column_info: Vec<ColumnInfo>,
}

#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct ColumnInfo {
    pub name: String,
    pub label: String,
    #[serde(rename = "Type")]
    pub type_name: String,
    pub nullable: String,
    pub case_sensitive: bool,
}
