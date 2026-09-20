//! DROP TABLE の結果ファイルを、対象テーブルの形式（Trino のコネクタ）に応じて書き分ける。
//!
//! Phase 1 の対象は DROP TABLE のみで、かつ修飾名でカタログを明示していない文だけ
//! （既定カタログを使う文。`t` も `ns.t` も既定カタログを使うので対象に含む）。
//! `cat.ns.t` のようにカタログそのものを名指しする文は Phase 2 で対応するので、
//! Phase 1 では判定せず今までどおりに倒す（途中状態が着手前より悪化しないため。issue #39）。

use crate::statement::quote_literal;
use crate::trino::{Cancel, Outcome, Trino};

/// Phase 1 で対象にする文の種類。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum TargetStatement {
    DropTable,
}

/// 問い合わせで分かる、対象テーブルの Trino コネクタ。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum TableFormat {
    Hive,
    Iceberg,
}

/// 本物が列なしでも本体・`.metadata` を置く、文の種類とテーブルの形式の組み合わせ
/// （2026-09-20 実測）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum EngineDdl {
    /// DROP TABLE × Iceberg。本体に改行 1 つ、`.metadata` に 41 バイト
    /// （field 1 = Trino のエンジンのクエリ ID、field 2 = `DROP TABLE`）。
    DropTableIceberg,
}

/// この文が Phase 1 の対象か。対象は DROP TABLE で、かつ修飾名でカタログを
/// 明示していない文だけ（`substatement_type` の判定をそのまま使い、判定を二重に持たない）。
pub(super) fn target_statement(query: &str) -> Option<TargetStatement> {
    if super::classification::substatement_type(query) != Some("DROP_TABLE") {
        return None;
    }
    if has_explicit_catalog(query) {
        return None;
    }
    Some(TargetStatement::DropTable)
}

/// `DROP TABLE [IF EXISTS] <名前>` の `<名前>` がカタログまで指す 3 パート
/// （`cat.ns.t` や `"s3tablescatalog/x".ns.t` のように、ドットが 2 つ以上）か。
/// `ns.t`（2 パート）や `t`（1 パート）は既定カタログを使うだけなので対象に含める。
/// 空白を挟んでドットが続く形までは見ない（Phase 1 は既定カタログの文だけを対象にする
/// 単純な判定。修飾名の厳密な取り出しは Phase 2 の範囲）。
fn has_explicit_catalog(query: &str) -> bool {
    let words = super::classification::words(query);
    let mut index = 2; // words[0] = "DROP", words[1] = "TABLE"
    if words.get(index).map(String::as_str) == Some("IF")
        && words.get(index + 1).map(String::as_str) == Some("EXISTS")
    {
        index += 2;
    }
    words
        .get(index)
        .is_some_and(|name| name.matches('.').count() >= 2)
}

/// テーブルの形式を Trino に問い合わせる。カタログが無ければ問い合わせない。失敗は None に倒す
/// （`statement::bind` の分類の問い合わせと同型: 本体と同じ catalog/database/cancel を使う）。
/// カタログ名は呼び出し元が別名解決した後の値を渡すこと（`system.metadata.catalogs` は
/// Trino 側のカタログ名でしか引けない）。
pub(super) async fn probe_format(
    trino: &Trino,
    catalog: Option<&str>,
    database: Option<&str>,
    cancel: &Cancel,
) -> Option<TableFormat> {
    let catalog = catalog?;
    let sql = format!(
        "SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = {}",
        quote_literal(catalog)
    );
    let outcome = trino
        .execute(&sql, Some(catalog), database, cancel)
        .await
        .ok()?;
    parse_connector_name(&outcome)
}

/// `system.metadata.catalogs.connector_name` の値から形式を決める。
/// hive でも iceberg でもない値・0 行は None（今までどおりに倒す）。
fn parse_connector_name(outcome: &Outcome) -> Option<TableFormat> {
    match outcome.rows.first()?.first()?.as_str()? {
        "hive" => Some(TableFormat::Hive),
        "iceberg" => Some(TableFormat::Iceberg),
        _ => None,
    }
}

/// 文の種類とテーブルの形式の組み合わせから、本物が列なしでも本体・`.metadata` を置く DDL を決める。
pub(super) fn engine_ddl(statement: TargetStatement, format: TableFormat) -> Option<EngineDdl> {
    match (statement, format) {
        (TargetStatement::DropTable, TableFormat::Iceberg) => Some(EngineDdl::DropTableIceberg),
        (TargetStatement::DropTable, TableFormat::Hive) => None,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::Value;

    use super::*;

    fn outcome_with_connector(value: &str) -> Outcome {
        Outcome {
            rows: vec![vec![Value::String(value.to_string())]],
            ..Outcome::default()
        }
    }

    #[test]
    fn connector_name_から形式を読む() {
        assert_eq!(
            parse_connector_name(&outcome_with_connector("hive")),
            Some(TableFormat::Hive)
        );
        assert_eq!(
            parse_connector_name(&outcome_with_connector("iceberg")),
            Some(TableFormat::Iceberg)
        );
    }

    #[test]
    fn hive_でも_iceberg_でもない形式は判定しない() {
        assert_eq!(
            parse_connector_name(&outcome_with_connector("delta_lake")),
            None
        );
        // 0 行（テーブルもカタログも無い、または応答の形が崩れている）。
        assert_eq!(parse_connector_name(&Outcome::default()), None);
    }

    #[test]
    fn target_statement_は_drop_table_だけを対象にする() {
        assert_eq!(
            target_statement("DROP TABLE t"),
            Some(TargetStatement::DropTable)
        );
        assert_eq!(
            target_statement("DROP TABLE IF EXISTS t"),
            Some(TargetStatement::DropTable)
        );
        for query in [
            "SELECT 1",
            "CREATE TABLE t (i int)",
            "DROP VIEW v",
            "DROP DATABASE db",
        ] {
            assert_eq!(target_statement(query), None, "{query:?}");
        }
    }

    #[test]
    fn target_statement_は修飾名でカタログを指す文を対象にしない() {
        // 3 パート（カタログを名指し）は Phase 2 の範囲。今回は判定しない。
        for query in [
            "DROP TABLE cat.ns.t",
            "DROP TABLE \"s3tablescatalog/my-bucket\".ns.t",
            "DROP TABLE IF EXISTS cat.ns.t",
        ] {
            assert_eq!(target_statement(query), None, "{query:?}");
        }
    }

    #[test]
    fn target_statement_は_2_パートの名前を既定カタログの文として対象にする() {
        // `ns.t` はカタログを名指ししておらず、`t` と同じ既定カタログを使うだけ。
        assert_eq!(
            target_statement("DROP TABLE ns.t"),
            Some(TargetStatement::DropTable)
        );
        assert_eq!(
            target_statement("DROP TABLE IF EXISTS ns.t"),
            Some(TargetStatement::DropTable)
        );
    }

    #[test]
    fn engine_ddl_は_drop_table_と_iceberg_の組み合わせだけ_some() {
        assert_eq!(
            engine_ddl(TargetStatement::DropTable, TableFormat::Iceberg),
            Some(EngineDdl::DropTableIceberg)
        );
        assert_eq!(
            engine_ddl(TargetStatement::DropTable, TableFormat::Hive),
            None
        );
    }

    #[tokio::test]
    async fn カタログが無ければ形式を問い合わせない() {
        // 接続先が無効でも、catalog が None ならネットワークに出ずに None を返す。
        let trino = Trino::new("http://127.0.0.1:1", "test");
        let cancel = Cancel::default();
        assert_eq!(probe_format(&trino, None, None, &cancel).await, None);
    }

    #[tokio::test]
    async fn 形式の問い合わせが失敗すれば今までどおりに倒す() {
        // 127.0.0.1:1 には何も listen していないので接続に失敗する。
        let trino = Trino::new("http://127.0.0.1:1", "test");
        let cancel = Cancel::default();
        assert_eq!(probe_format(&trino, Some("cat"), None, &cancel).await, None);
    }
}
