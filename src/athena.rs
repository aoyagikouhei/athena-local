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
    /// 省略時は config.rs の DEFAULT_WORK_GROUP を既定にする。
    #[serde(default)]
    pub work_group: Option<String>,
    /// 本物と同じく必須（省略は INVALID_INPUT。2026-09-17 実測）。`Option` なのは、
    /// serde の欠落エラーではなく operation.rs が実測した文言で自前のエラーを返すため。
    #[serde(default)]
    pub client_request_token: Option<String>,
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
    /// FAILED のときだけ。CANCELLED には付かない（本物と同じ）。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub athena_error: Option<AthenaError>,
}

#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct AthenaError {
    /// 1 = SYSTEM、2 = USER、3 = OTHER。
    pub error_category: i32,
    pub error_type: i32,
    pub retryable: bool,
    pub error_message: String,
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
    /// Athena の型名（精度などの引数を付けない基底名。real は float）。
    #[serde(rename = "Type")]
    pub type_name: String,
    pub nullable: String,
    pub case_sensitive: bool,
    /// 本物は常に "hive"。
    pub catalog_name: String,
    /// 本物は常に空。
    pub schema_name: String,
    /// 本物は常に空。
    pub table_name: String,
    pub precision: i64,
    pub scale: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct GetWorkGroupRequest {
    pub work_group: String,
}

#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct GetWorkGroupResponse {
    pub work_group: WorkGroup,
}

#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct WorkGroup {
    pub name: String,
    pub state: String,
    pub configuration: WorkGroupConfiguration,
}

/// athena-local にワークグループの実体は無く、値は operation.rs で実測して直書きする。
#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct WorkGroupConfiguration {
    /// 出力先が無くても本物はキーごと省かず空のオブジェクトを返す。そのため Option にしない。
    pub result_configuration: ResultConfiguration,
    pub enforce_work_group_configuration: bool,
    pub publish_cloud_watch_metrics_enabled: bool,
    pub requester_pays_enabled: bool,
    pub engine_version: EngineVersion,
}

#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct EngineVersion {
    pub selected_engine_version: String,
    pub effective_engine_version: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "PascalCase")]
pub struct ListWorkGroupsRequest {
    #[serde(default)]
    pub max_results: Option<i32>,
    #[serde(default)]
    pub next_token: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct ListWorkGroupsResponse {
    pub work_groups: Vec<WorkGroupSummary>,
    /// 続きが無いときはキーごと省く。空文字で返すと Grafana の athena-datasource が
    /// 無限ループする（nextToken == nil だけを終わりの合図にしている）。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub next_token: Option<String>,
}

/// GetWorkGroup と違い Configuration は無く、Description が付く。
/// CreationTime / IdentityCenterApplicationArn と、ワイヤ上だけにある
/// EngineVersion.Category は返さない（実体が無い、または SDK のモデルに無い）。
#[derive(Serialize)]
#[serde(rename_all = "PascalCase")]
pub struct WorkGroupSummary {
    pub name: String,
    pub state: String,
    /// athena-local に説明の実体が無いので常に空文字。本物も説明の無いワークグループは
    /// ListWorkGroups で "" を返し、GetWorkGroup ではキーごと無い（2026-09-17／09-18 実測）。
    pub description: String,
    pub engine_version: EngineVersion,
}
