//! StartQueryExecution の受付値（ClientRequestToken・Context・OutputLocation・文）の検証と正規化。

use axum::response::Response;

use crate::athena::{QueryExecutionContext, ResultConfiguration, StartQueryExecutionRequest};
use crate::config::ResultsMode;
use crate::handler::App;
use crate::response::invalid_request_with_code;
use crate::results::ResultLocation;
use crate::store::Fingerprint;

/// OutputLocation も既定も無いときの本物の文言（2026-09-14 実測。"for  your" の空白 2 つも本物のまま）。
const NO_OUTPUT_LOCATION: &str = "No output location provided. You did not provide an output location for  your query results. Either specify an S3 bucket location or enable Athena managed query results in your workgroup settings.";

/// ClientRequestToken が無い（キーが無い）ときの文言（2026-09-17、4 回目の実測）。
const TOKEN_MISSING: &str = "clientRequestToken is null or empty";

/// ClientRequestToken が 32 文字未満（空文字を含む）のときの文言（2026-09-17、3 回目の実測）。
const TOKEN_TOO_SHORT: &str = "1 validation error detected: Value at 'clientRequestToken' failed to satisfy constraint: Member must have length greater than or equal to 32";

/// ClientRequestToken が 128 文字を超えるときの文言（2026-09-17、3 回目の実測）。
const TOKEN_TOO_LONG: &str = "1 validation error detected: Value at 'clientRequestToken' failed to satisfy constraint: Member must have length less than or equal to 128";

/// ClientRequestToken が 128 文字以下なのに UTF-8 で 128 バイトを超えるときの文言（2026-09-24 実測、#153）。
/// 枠組みの検証（文字数）を通った後の別の検査なので、前置きが無い。
const TOKEN_TOO_MANY_BYTES: &str = "clientRequestToken exceeds maximum allowed length 128";

/// 本物が実行する文。引用符とコメントの外の `;` で区切り、空白だけでない片（コメントだけの片も数える）が
/// ちょうど 1 つなら、その片の前後の空白を落とした文を構文チェック・開始時の判定・実行・`Query` に使う
/// （`;` の無い文も前後の空白が落ちる）。2 つ以上なら `Only one sql statement is allowed`（#228）、`;` が
/// あって 1 つも無ければ `Empty sql statement` で、構文エラー・DESCRIBE の存在確認・No location・NV より先に
/// 弾く。どちらも文言の後ろは受け取った文の末尾の空白だけを落としたもの（先頭の空白は残る）
/// （2026-09-26 実測。#228・#240）。`;` の無い空白だけの文は測っていないので受け取ったまま返す。
pub(super) fn single_statement(sql: &str) -> Result<&str, String> {
    const WHITESPACE: [char; 4] = [' ', '\t', '\r', '\n'];
    let pieces = athena_sql::statements(sql);
    let separated = pieces.len() > 1;
    let mut statements = pieces
        .into_iter()
        .map(|piece| piece.trim_matches(WHITESPACE))
        .filter(|piece| !piece.is_empty());
    let got = sql.trim_end_matches(WHITESPACE);
    match (statements.next(), statements.next()) {
        (Some(statement), None) => Ok(statement),
        (Some(_), Some(_)) => Err(format!("Only one sql statement is allowed. Got: {got}")),
        (None, _) if separated => Err(format!("Empty sql statement: {got}")),
        (None, _) => Ok(sql),
    }
}

/// ClientRequestToken を検証する（2026-09-17 実測、判断 2・11）。本物と同じく必須で、
/// 長さは 32 文字以上 128 文字以下（枠組みの検証。文字数は chars().count()）、さらに UTF-8 で
/// 128 バイト以下（別の検査。2026-09-24 実測、#153。`あ`×50 は 50 文字なのに拒否された）。
/// 文字数でもバイト数でも 128 を超えるときにどちらの文言が先かは測っていないので、
/// 枠組みの検証を先に置く（docs/dev/unmeasured.md）。
pub(super) fn client_request_token(
    request: &StartQueryExecutionRequest,
) -> Result<String, Box<Response>> {
    let Some(token) = request.client_request_token.clone() else {
        return Err(Box::new(invalid_request_with_code(
            TOKEN_MISSING,
            "INVALID_INPUT",
        )));
    };

    let length = token.chars().count();
    if length < 32 {
        return Err(Box::new(invalid_request_with_code(
            TOKEN_TOO_SHORT,
            "INVALID_INPUT",
        )));
    }
    if length > 128 {
        return Err(Box::new(invalid_request_with_code(
            TOKEN_TOO_LONG,
            "INVALID_INPUT",
        )));
    }
    if token.len() > 128 {
        return Err(Box::new(invalid_request_with_code(
            TOKEN_TOO_MANY_BYTES,
            "INVALID_INPUT",
        )));
    }

    Ok(token)
}

/// QueryExecutionContext の Catalog / Database（受け取ったまま）と、冪等化用のフィンガープリント（同じく生の値）を組む。
pub(super) fn context_defaults(
    context: QueryExecutionContext,
    query_string: &str,
    result_configuration: &Option<ResultConfiguration>,
) -> (Option<String>, Option<String>, Fingerprint) {
    let fingerprint = Fingerprint {
        query: query_string.to_string(),
        catalog: context.catalog.clone(),
        database: context.database.clone(),
        output_location: result_configuration
            .as_ref()
            .and_then(|configuration| configuration.output_location.clone()),
    };
    // 既定（TRINO_CATALOG / TRINO_SCHEMA）はここでは当てない。本物は省略した Catalog / Database を
    // GetQueryExecution に返さない（キー無し。2026-09-24 実測、#167）ので、実行情報には受け取った値だけを
    // 残し、既定は Trino に送るとき（`run`）に当てる。
    (context.catalog, context.database, fingerprint)
}

/// OutputLocation から結果の置き場所を決める。本物と同じく s3:// の形でない値は受け付けない
/// （結果を書かないモードでも同じ）。書くモードでは、OutputLocation も既定も無ければ受け付けない。
pub(super) fn result_location(
    app: &App,
    configuration: Option<ResultConfiguration>,
    query: &str,
    id: &str,
) -> Result<Option<ResultLocation>, Box<Response>> {
    let requested = configuration.and_then(|configuration| configuration.output_location);
    let output_location = match (requested, &app.config.results) {
        (Some(location), _) => location,
        (None, ResultsMode::S3(settings)) => match &settings.default_output_location {
            Some(location) => location.clone(),
            None => {
                return Err(Box::new(invalid_request_with_code(
                    NO_OUTPUT_LOCATION,
                    "INVALID_INPUT",
                )));
            }
        },
        (None, ResultsMode::None) => return Ok(None),
    };

    // 文言とコードは 2026-09-14 に本番 Athena で実測したもの。
    ResultLocation::new(&output_location, id, query)
        .map(Some)
        .ok_or_else(|| {
            Box::new(invalid_request_with_code(
                "outputLocation is not a valid S3 path.",
                "INVALID_INPUT",
            ))
        })
}
