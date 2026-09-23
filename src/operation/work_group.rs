//! GetWorkGroup・ListWorkGroups。athena-local にワークグループの実体は無く、設定と固定値で答える。

use axum::body::Bytes;
use axum::response::Response;

use crate::athena::{
    EngineVersion, GetWorkGroupRequest, GetWorkGroupResponse, ListWorkGroupsRequest,
    ListWorkGroupsResponse, ResultConfiguration, WorkGroup, WorkGroupConfiguration,
    WorkGroupSummary,
};
use crate::config::ResultsMode;
use crate::handler::App;
use crate::response::{invalid_request_with_code, ok, parse};

use super::validation::paging_violation;

/// ListWorkGroups で MaxResults が無いときのページの大きさ。
/// 本物の既定ページサイズは未実測（測れるだけのワークグループが無い）。
/// botocore の MaxWorkGroupsCount の上限（50）に合わせた。
const LIST_WORK_GROUPS_MAX_RESULTS: i32 = 50;

/// ワークグループの State（2026-09-17 実測。GetWorkGroup と ListWorkGroups で同じ値）。
const WORK_GROUP_STATE: &str = "ENABLED";

/// ワークグループのエンジン（2026-09-17 実測。GetWorkGroup と ListWorkGroups で同じ値）。
fn engine_version() -> EngineVersion {
    EngineVersion {
        selected_engine_version: "AUTO".to_string(),
        effective_engine_version: "Athena engine version 3".to_string(),
    }
}

/// Trino にも Store にも問い合わせない。athena-local にワークグループの実体が無く、
/// 名前だけをそのまま返して、Configuration は固定値にする。本物と違い、存在しない名前でもエラーにしない。
/// Configuration の値は 2026-09-17 に本番 Athena で実測したもの
/// (EnableMinimumEncryptionConfiguration は値が採れず、CreationTime は実体が無いのでどちらも省く)。
/// State と EngineVersion は ListWorkGroups と同じ値なので WORK_GROUP_STATE / engine_version() で共有する。
pub fn get_work_group(app: &App, body: &Bytes) -> Response {
    let request: GetWorkGroupRequest = match parse(body) {
        Ok(request) => request,
        Err(response) => return *response,
    };

    // GetWorkGroup の応答にも StartQueryExecution と同じ既定の出力先を反映する
    // (ATHENA_LOCAL_OUTPUT_LOCATION。README:71、config.rs の S3Settings.default_output_location と同じ値)。
    let output_location = match &app.config.results {
        ResultsMode::S3(settings) => settings.default_output_location.clone(),
        ResultsMode::None => None,
    };

    ok(&GetWorkGroupResponse {
        work_group: WorkGroup {
            name: request.work_group,
            state: WORK_GROUP_STATE.to_string(),
            configuration: WorkGroupConfiguration {
                result_configuration: ResultConfiguration { output_location },
                enforce_work_group_configuration: false,
                publish_cloud_watch_metrics_enabled: false,
                requester_pays_enabled: false,
                engine_version: engine_version(),
            },
        },
    })
}

/// Trino にも Store にも問い合わせない。一覧は Config.work_groups（ATHENA_LOCAL_WORK_GROUPS）
/// をそのまま返す（名前の辞書順に整列済みなのは config.rs の不変条件）。本物と違い、
/// ここに無い名前でも GetWorkGroup は成功する。
/// MaxResults と NextToken の検証は 2026-09-18 に本番 Athena で実測した形に合わせる
/// （枠組みの検証は `validation::paging_violation`。2 件同時の形は #83 で 2026-09-23 に実測）。
pub fn list_work_groups(app: &App, body: &Bytes) -> Response {
    let request: ListWorkGroupsRequest = match parse(body) {
        Ok(request) => request,
        Err(response) => return *response,
    };

    // usize にする前に i32 のまま範囲を見る（-1 のキャストは巨大な値になり、
    // 0 は end == offset で同じ NextToken を返し続けることになる）。
    let limit = request.max_results.unwrap_or(LIST_WORK_GROUPS_MAX_RESULTS);
    if let Some(response) = paging_violation(
        request.next_token.as_deref(),
        limit,
        Some(LIST_WORK_GROUPS_MAX_RESULTS),
    ) {
        return response;
    }
    let limit = limit as usize;

    let names = &app.config.work_groups;
    let offset = match &request.next_token {
        None => 0,
        // 発行するのは 1 <= end < len の 10 進なので、それ以外は本物と同じく弾く
        // （"0"、先頭ゼロ、"+2" も通るが、返すページは正当なので厳密化しない）。
        Some(token) => match token.parse::<usize>().ok().filter(|o| *o < names.len()) {
            Some(offset) => offset,
            None => {
                return invalid_request_with_code(
                    format!("The nextPageToken is malformed: {token}"),
                    "INVALID_INPUT",
                );
            }
        },
    };

    let end = (offset + limit).min(names.len());

    ok(&ListWorkGroupsResponse {
        work_groups: names[offset..end]
            .iter()
            .map(|name| WorkGroupSummary {
                name: name.clone(),
                state: WORK_GROUP_STATE.to_string(),
                description: String::new(),
                engine_version: engine_version(),
            })
            .collect(),
        next_token: (end < names.len()).then(|| end.to_string()),
    })
}
