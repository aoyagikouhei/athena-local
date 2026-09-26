//! 本物の Athena が StartQueryExecution の時点で Glue に問い合わせる、DESCRIBE・DESC・SHOW COLUMNS の
//! 対象の存在の確認（#207）。形式の問い合わせ（`table_format::probe_sql`）と同じ SQL を開始前にも投げる。

use axum::response::Response;
use uuid::Uuid;

use crate::config::Config;
use crate::response::invalid_request_with_code;
use crate::trino::{Cancel, Trino};

use super::table_format::{self, TargetStatement};
use super::target_table;

/// 存在を確かめた結果、開始時にどうするか。
pub(super) enum Check {
    /// 本物は開始時に弾く（テーブルかカタログが無い）。
    Reject(Box<Response>),
    /// ビュー。本物は引用符付きの名前でも実行するので、`quoted_names` を見ずに実行する（2026-09-25 実測 W4）。
    Run,
    /// 表。`quoted_names` に進む（Continue と同じ）。表への DESCRIBE の Query から修飾を落とすのに使う（#242）。
    Table,
    /// 対象外の文・確かめられなかった。`quoted_names` に進む（今までどおり）。
    Continue,
}

/// 本物の判定の順序は、4 部以上の名前 → S3 Tables の別名 → カタログの有無 → テーブルの有無 → ビュー →
/// 引用符付きの名前（2026-09-25 実測）。4 部以上は `parse_target_table` が None を返し、名前に書いた別名は
/// 問い合わせずに `quoted_names` に任せるので、この順序になる。存在は、無いと分かったときだけ弾く。探索が失敗したり
/// 応答の形が違ったりしたら（偽 Trino が本体の応答を返すときも）Continue に倒す。
pub(super) async fn check(
    trino: &Trino,
    config: &Config,
    query: &str,
    catalog: Option<&str>,
    database: Option<&str>,
) -> Check {
    let Some(statement @ (TargetStatement::Describe | TargetStatement::ShowColumns)) =
        table_format::target_statement(query)
    else {
        return Check::Continue;
    };
    // 既定は実行時（`execution::run`）と同じく当てる。
    let raw_catalog = catalog.or(config.default_catalog.as_deref());
    let database = database.or(config.default_database.as_deref());
    let Some(target) = target_table::parse_target_table(query, statement, raw_catalog, database)
    else {
        return Check::Continue;
    };
    // 名前に書いた別名だけ `quoted_names` の `2 catalogs` に任せる。Context や既定から来た別名は、本物の
    // AwsDataCatalog と同じく存在を確かめる（#216）。
    if config.catalog_map.contains_key(&target.catalog) && names_catalog(query, statement) {
        return Check::Continue;
    }
    // 本物は大文字の名前でも実在のテーブルを見つける（2026-09-25 実測 W1）。Trino はカタログ・スキーマ・
    // テーブルを小文字で持ち、引用符付きの名前も大文字小文字を区別せずに引くので、どれも小文字にして引く。
    // カタログは本体と同じ別名を当てた Trino 側の名前。
    let trino_catalog = config.trino_catalog(&target.catalog).to_lowercase();
    let sql = table_format::probe_sql(
        &trino_catalog,
        &target.schema.to_lowercase(),
        &target.table.to_lowercase(),
    );
    // system.* を修飾名で引くので、セッションのカタログ・スキーマは付けない（無いカタログでも問い合わせが通る）。
    let Ok(outcome) = trino.execute(&sql, None, None, &Cancel::default()).await else {
        return Check::Continue;
    };
    let columns: Vec<&str> = outcome.columns.iter().map(|c| c.name.as_str()).collect();
    let [row] = outcome.rows.as_slice() else {
        return Check::Continue;
    };
    if columns != ["_col0", "_col1"] || row.len() != 2 {
        return Check::Continue;
    }
    match (row[0].is_null(), row[1].as_str()) {
        // カタログが無い。本物の文言を測ったのは名前にカタログを書いた形だけ（W1 の nocat）。
        (true, _) if names_catalog(query, statement) => {
            Check::Reject(Box::new(invalid_request_with_code(
                format!("Catalog '{}' does not exist", target.catalog),
                "DATACATALOG_NOT_FOUND",
            )))
        }
        (true, _) => Check::Continue,
        // テーブル（かスキーマ）が無い。Request ID は本物も毎回違う（2026-09-25 実測 W5）。
        (false, None) if row[1].is_null() => Check::Reject(Box::new(invalid_request_with_code(
            format!(
                "Entity Not Found (Service: AmazonDataCatalog; Status Code: 400; Error Code: EntityNotFoundException; Request ID: {}; Proxy: null)",
                Uuid::new_v4()
            ),
            "INVALID_INPUT",
        ))),
        (false, Some("VIEW")) => Check::Run,
        (false, Some("TABLE")) => Check::Table,
        _ => Check::Continue,
    }
}

/// 名前にカタログまで書いてあるか（3 部の名前）。既定を渡さずに読めるのは 3 部のときだけ。
fn names_catalog(query: &str, statement: TargetStatement) -> bool {
    target_table::parse_target_table(query, statement, None, Some("")).is_some()
}
