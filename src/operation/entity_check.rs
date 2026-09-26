//! 本物の Athena が StartQueryExecution の時点で Glue に問い合わせる、DESCRIBE・DESC・SHOW COLUMNS の
//! 対象の存在の確認（#207）。形式の問い合わせ（`table_format::probe_sql`）と同じ SQL を開始前にも投げる。
//! 応答の解釈（`probe`）は `execution.rs` のブロックコメントの ParseException の判定（#244）も、
//! SHOW CREATE TABLE・ALTER TABLE の対象を確かめるのに共有する。

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
    /// `iceberg` は `probe` の結果（追加の問い合わせはしない）。Iceberg 表への DESCRIBE の直後のブロックコメントは
    /// 本物が成功させる（`execution.rs` のブロックコメントの判定の対象外にする。2026-09-26 実測 d1。#244）。
    Table { iceberg: bool },
    /// 対象外の文・確かめられなかった。`quoted_names` に進む（今までどおり）。
    Continue,
}

/// `probe` の結果。
pub(super) enum Probe {
    /// カタログが無い。
    NoCatalog,
    /// テーブル（かスキーマ）が無い。
    Missing,
    /// ビュー。
    View,
    /// 表。`iceberg` はコネクタ名（`probe_sql` の `_col0`）が `iceberg` かどうか。
    Table { iceberg: bool },
    /// 問い合わせが失敗した・応答の形が違う（偽 Trino が本体の応答を返すときも）。
    Unknown,
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
    // 既定は実行時（`background_execution::run`）と同じく当てる。
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
    match probe(
        trino,
        config,
        &target.catalog,
        &target.schema,
        &target.table,
    )
    .await
    {
        // カタログが無い。本物の文言を測ったのは名前にカタログを書いた形だけ（W1 の nocat）。
        Probe::NoCatalog if names_catalog(query, statement) => {
            Check::Reject(Box::new(invalid_request_with_code(
                format!("Catalog '{}' does not exist", target.catalog),
                "DATACATALOG_NOT_FOUND",
            )))
        }
        Probe::NoCatalog => Check::Continue,
        // テーブル（かスキーマ）が無い。Request ID は本物も毎回違う（2026-09-25 実測 W5）。
        Probe::Missing => Check::Reject(Box::new(invalid_request_with_code(
            format!(
                "Entity Not Found (Service: AmazonDataCatalog; Status Code: 400; Error Code: EntityNotFoundException; Request ID: {}; Proxy: null)",
                Uuid::new_v4()
            ),
            "INVALID_INPUT",
        ))),
        Probe::View => Check::Run,
        Probe::Table { iceberg } => Check::Table { iceberg },
        Probe::Unknown => Check::Continue,
    }
}

/// テーブルの形式と存在を `table_format::probe_sql` で確かめる（`table_format::probe_format` と違い、対象が
/// ビューかどうかも読み分ける）。本物は大文字の名前でも実在のテーブルを見つける（2026-09-25 実測 W1）。
/// Trino はカタログ・スキーマ・テーブルを小文字で持ち、引用符付きの名前も大文字小文字を区別せずに引くので、
/// どれも小文字にして引く。カタログは本体と同じ別名を当てた Trino 側の名前。
pub(super) async fn probe(
    trino: &Trino,
    config: &Config,
    catalog: &str,
    schema: &str,
    table: &str,
) -> Probe {
    let trino_catalog = config.trino_catalog(catalog).to_lowercase();
    let sql = table_format::probe_sql(
        &trino_catalog,
        &schema.to_lowercase(),
        &table.to_lowercase(),
    );
    // system.* を修飾名で引くので、セッションのカタログ・スキーマは付けない（無いカタログでも問い合わせが通る）。
    let Ok(outcome) = trino.execute(&sql, None, None, &Cancel::default()).await else {
        return Probe::Unknown;
    };
    let columns: Vec<&str> = outcome.columns.iter().map(|c| c.name.as_str()).collect();
    let [row] = outcome.rows.as_slice() else {
        return Probe::Unknown;
    };
    if columns != ["_col0", "_col1"] || row.len() != 2 {
        return Probe::Unknown;
    }
    match (row[0].is_null(), row[1].as_str()) {
        (true, _) => Probe::NoCatalog,
        (false, None) if row[1].is_null() => Probe::Missing,
        (false, Some("VIEW")) => Probe::View,
        (false, Some("TABLE")) => table_probe(&row[0]),
        _ => Probe::Unknown,
    }
}

/// `row[1]` が `TABLE`（表）だったときの `Probe`。`row[0]`（`probe_sql` の `_col0`、コネクタ名）が
/// `"iceberg"` かどうかを `Probe::Table` に持たせる。
fn table_probe(connector: &serde_json::Value) -> Probe {
    Probe::Table {
        iceberg: connector.as_str() == Some("iceberg"),
    }
}

/// 名前にカタログまで書いてあるか（3 部の名前）。既定を渡さずに読めるのは 3 部のときだけ。
fn names_catalog(query: &str, statement: TargetStatement) -> bool {
    target_table::parse_target_table(query, statement, None, Some("")).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn table_probe_は_コネクタ名が_iceberg_かどうかで_iceberg_を決める() {
        assert!(matches!(
            table_probe(&json!("iceberg")),
            Probe::Table { iceberg: true }
        ));
        assert!(matches!(
            table_probe(&json!("hive")),
            Probe::Table { iceberg: false }
        ));
    }
}
