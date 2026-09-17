//! ListWorkGroups。一覧の中身は ATHENA_LOCAL_WORK_GROUPS（Harness では work_groups）から作る。
//! State / EngineVersion / Description とページングのエラーは 2026-09-17／09-18 に本番 Athena で実測したもの。

mod common;

use common::Harness;
use serde_json::{Value, json};

fn empty_response() -> Value {
    json!({ "columns": [], "data": [] })
}

/// 応答の WorkGroups を Vec にして返す。
fn names(body: &Value) -> Vec<String> {
    body["WorkGroups"]
        .as_array()
        .expect("WorkGroups が無い")
        .iter()
        .map(|group| group["Name"].as_str().expect("Name が無い").to_string())
        .collect()
}

#[tokio::test]
async fn 設定が無ければ_primary_の_1_件を返す() {
    let harness = Harness::start(empty_response()).await;

    let (status, body) = harness.call("ListWorkGroups", json!({})).await;

    assert_eq!(status, 200);
    assert_eq!(names(&body), ["primary"]);
    assert!(
        body.get("NextToken").is_none(),
        "1 ページに収まるときはキーごと省く（空文字だと Grafana が無限ループする）"
    );
}

#[tokio::test]
async fn 設定した名前をその順に返す() {
    let harness = Harness::builder(empty_response())
        .work_groups(&["ad-hoc", "etl", "primary"])
        .start()
        .await;

    let (status, body) = harness.call("ListWorkGroups", json!({})).await;

    assert_eq!(status, 200);
    assert_eq!(names(&body), ["ad-hoc", "etl", "primary"]);
}

#[tokio::test]
async fn summary_の項目は_name_state_description_engine_version_の_4_つ() {
    let harness = Harness::start(empty_response()).await;

    let (_, body) = harness.call("ListWorkGroups", json!({})).await;

    let summary = &body["WorkGroups"][0];
    let mut keys: Vec<&str> = summary
        .as_object()
        .expect("要素がオブジェクトでない")
        .keys()
        .map(String::as_str)
        .collect();
    keys.sort();
    // CreationTime / IdentityCenterApplicationArn / EngineVersion.Category は返さない。
    assert_eq!(keys, ["Description", "EngineVersion", "Name", "State"]);
    assert_eq!(
        summary["Description"], "",
        "本物も説明の無いワークグループは空文字を返す（2026-09-18 実測）"
    );
    assert_eq!(summary["State"], "ENABLED");
    assert_eq!(summary["EngineVersion"]["SelectedEngineVersion"], "AUTO");
    assert_eq!(
        summary["EngineVersion"]["EffectiveEngineVersion"],
        "Athena engine version 3"
    );
}

#[tokio::test]
async fn state_と_engine_version_は_get_work_group_と同じ値を返す() {
    let harness = Harness::start(empty_response()).await;

    let (_, listed) = harness.call("ListWorkGroups", json!({})).await;
    let (_, fetched) = harness
        .call("GetWorkGroup", json!({ "WorkGroup": "primary" }))
        .await;

    let summary = &listed["WorkGroups"][0];
    let work_group = &fetched["WorkGroup"];
    assert_eq!(summary["State"], work_group["State"]);
    assert_eq!(
        summary["EngineVersion"],
        work_group["Configuration"]["EngineVersion"]
    );
}

#[tokio::test]
async fn max_results_でページングされ_next_token_を辿ると続きが取れる() {
    let harness = Harness::builder(empty_response())
        .work_groups(&["a", "b", "c", "d", "e"])
        .start()
        .await;

    let (_, first) = harness
        .call("ListWorkGroups", json!({ "MaxResults": 2 }))
        .await;
    assert_eq!(names(&first), ["a", "b"]);
    assert_eq!(first["NextToken"], "2", "次のページの先頭の位置");

    let (_, second) = harness
        .call(
            "ListWorkGroups",
            json!({ "MaxResults": 2, "NextToken": "2" }),
        )
        .await;
    assert_eq!(names(&second), ["c", "d"]);
    assert_eq!(second["NextToken"], "4");

    let (_, third) = harness
        .call(
            "ListWorkGroups",
            json!({ "MaxResults": 2, "NextToken": "4" }),
        )
        .await;
    assert_eq!(names(&third), ["e"]);
    assert!(third.get("NextToken").is_none(), "最終ページには付かない");
}

#[tokio::test]
async fn max_results_を省くと_50_件ずつ返す() {
    // 本物の既定ページサイズは未実測。botocore の上限に合わせた 50 を固定する。
    let names_51: Vec<String> = (1..=51).map(|n| format!("wg-{n:02}")).collect();
    let harness = Harness::builder(empty_response())
        .work_groups(&names_51.iter().map(String::as_str).collect::<Vec<_>>())
        .start()
        .await;

    let (status, first) = harness.call("ListWorkGroups", json!({})).await;

    assert_eq!(status, 200);
    assert_eq!(names(&first), names_51[..50]);
    assert_eq!(first["NextToken"], "50");

    let (_, second) = harness
        .call("ListWorkGroups", json!({ "NextToken": "50" }))
        .await;
    assert_eq!(names(&second), names_51[50..]);
    assert!(second.get("NextToken").is_none());
}

#[tokio::test]
async fn max_results_が範囲外ならエラーにする() {
    // 2026-09-18 実測（51 は CLI、0 と -1 は生 HTTP）。
    const TOO_SMALL: &str = "1 validation error detected: Value at 'maxResults' failed to satisfy constraint: Member must have value greater than or equal to 1";
    const TOO_LARGE: &str = "1 validation error detected: Value at 'maxResults' failed to satisfy constraint: Member must have value less than or equal to 50";

    let harness = Harness::start(empty_response()).await;

    for (max_results, message) in [(0, TOO_SMALL), (-1, TOO_SMALL), (51, TOO_LARGE)] {
        let (status, error) = harness
            .call("ListWorkGroups", json!({ "MaxResults": max_results }))
            .await;

        assert_eq!(status, 400, "MaxResults={max_results}");
        assert_eq!(error["__type"], "InvalidRequestException");
        assert_eq!(error["AthenaErrorCode"], "INVALID_INPUT");
        assert_eq!(error["ErrorCode"], "INVALID_INPUT");
        assert_eq!(error["Message"], message);
        let mut keys: Vec<&str> = error
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        keys.sort();
        assert_eq!(keys, ["AthenaErrorCode", "ErrorCode", "Message", "__type"]);
    }

    // 上限ちょうどは通る。
    let (status, _) = harness
        .call("ListWorkGroups", json!({ "MaxResults": 50 }))
        .await;
    assert_eq!(status, 200);
}

#[tokio::test]
async fn 不正な_next_token_はエラーにする() {
    // 2026-09-18 実測。本物は受け取ったトークンをそのまま文言の末尾に付ける。
    const EMPTY: &str = "1 validation error detected: Value at 'nextToken' failed to satisfy constraint: Member must have length greater than or equal to 1";

    let harness = Harness::builder(empty_response())
        .work_groups(&["a", "b", "c", "d", "e"])
        .start()
        .await;

    for token in ["abc", "999", "5"] {
        let (status, error) = harness
            .call("ListWorkGroups", json!({ "NextToken": token }))
            .await;

        assert_eq!(status, 400, "NextToken={token:?}");
        assert_eq!(error["__type"], "InvalidRequestException");
        assert_eq!(error["AthenaErrorCode"], "INVALID_INPUT");
        assert_eq!(
            error["Message"],
            format!("The nextPageToken is malformed: {token}")
        );
    }

    // 空文字だけは長さの制約のエラーになる。
    let (status, error) = harness
        .call("ListWorkGroups", json!({ "NextToken": "" }))
        .await;
    assert_eq!(status, 400);
    assert_eq!(error["__type"], "InvalidRequestException");
    assert_eq!(error["AthenaErrorCode"], "INVALID_INPUT");
    assert_eq!(error["Message"], EMPTY);
}

#[tokio::test]
async fn trino_には一切問い合わせない() {
    let harness = Harness::start(empty_response()).await;

    harness.call("ListWorkGroups", json!({})).await;

    assert!(harness.trino_requests().is_empty());
}
