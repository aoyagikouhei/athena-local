//! ページング引数（MaxResults / NextToken）の枠組みの検証。GetQueryResults と ListWorkGroups の両方から呼ぶ。
//!
//! 本物は API 定義の制約違反（MaxResults の下限・上限、NextToken の最短長）をオペレーションの
//! 本体より先に見て、違反を `N validation error(s) detected: <制約>; <制約>` の 1 文にまとめて返す
//! （ListWorkGroups は 2026-09-18、GetQueryResults は 2026-09-23 実測。2 件同時の順序は nextToken →
//! maxResults で、どちらのオペレーションでも同じ。2026-09-23 実測）。ID の存在確認やクエリの状態より
//! 先なので、呼び出し元は `parse` の直後にこれを通す。

use axum::response::Response;

use crate::response::{invalid_request_with_code, validation_errors};

/// MaxResults が 1 未満のときの制約の文言（2026-09-18・09-23 実測）。
const MAX_RESULTS_TOO_SMALL: &str = "Value at 'maxResults' failed to satisfy constraint: Member must have value greater than or equal to 1";

/// NextToken が空文字のときの制約の文言（2026-09-18・09-23 実測。不正な文字列とは違うエラーになる）。
const NEXT_TOKEN_EMPTY: &str = "Value at 'nextToken' failed to satisfy constraint: Member must have length greater than or equal to 1";

/// MaxResults が API 定義の上限を超えたときの制約の文言（ListWorkGroups の 50 で 2026-09-18 実測）。
fn max_results_too_large(upper: i64) -> String {
    format!(
        "Value at 'maxResults' failed to satisfy constraint: Member must have value less than or equal to {upper}"
    )
}

/// 枠組みの検証。違反があれば INVALID_INPUT の応答を返す。
///
/// `upper` は API 定義（枠組み）の MaxResults の上限（ListWorkGroups は 50、GetQueryResults は 100000）。
/// GetQueryResults の 1000 は枠組みの検証ではなく本体が別の文言で弾く
/// （2026-09-23 実測: 1001 と空文字の同時は空文字のエラーだけ、100001 は枠組みの文言になる）。
/// 上限超過と空文字の同時は nextToken → maxResults の順で 1 文にまとまる（ListWorkGroups の 51 で 2026-09-23 実測。#85）。
pub(super) fn paging_violation(
    next_token: Option<&str>,
    max_results: i64,
    upper: Option<i64>,
) -> Option<Response> {
    let mut violations = Vec::new();
    if next_token == Some("") {
        violations.push(NEXT_TOKEN_EMPTY.to_string());
    }
    if max_results < 1 {
        violations.push(MAX_RESULTS_TOO_SMALL.to_string());
    } else if let Some(upper) = upper
        && max_results > upper
    {
        violations.push(max_results_too_large(upper));
    }
    if violations.is_empty() {
        return None;
    }
    Some(invalid_request_with_code(
        validation_errors(&violations),
        "INVALID_INPUT",
    ))
}
