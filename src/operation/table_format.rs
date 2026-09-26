//! DROP TABLE と ALTER TABLE ... ADD COLUMNS と SHOW CREATE TABLE と DESCRIBE の結果ファイル（と
//! SHOW CREATE TABLE / DESCRIBE の UpdateCount）を、対象テーブルの形式（Trino のコネクタ）に応じて書き分ける。
//! Phase 3b は ALTER TABLE ... ADD COLUMNS × Hive を対象に足す（2026-09-21 実測）。
//! #151 は SHOW CREATE TABLE × Iceberg を対象に足す（2026-09-24 実測）。
//! #160 は DESCRIBE × Iceberg を対象に足す（2026-09-24 実測。SHOW CREATE TABLE と同じ割れ方）。
//! #173 は対象がビューかどうかも同じ問い合わせで確かめる（2026-09-24 実測 d5）。

use crate::statement::{quote_identifier, quote_literal};
use crate::trino::{Cancel, Outcome, Trino};

/// 対象にする文の種類。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum TargetStatement {
    DropTable,
    AlterTableAddColumns,
    /// `ALTER TABLE ... REPLACE COLUMNS`。Hive では ADD COLUMNS と同じ `.metadata` を置き、
    /// Iceberg では本物が実行時に失敗する（2026-09-21 実測）。
    AlterTableReplaceColumns,
    /// `SHOW CREATE TABLE`。Iceberg だけ本体・`.metadata` を binary/octet-stream で置く
    /// （2026-09-24 実測。#151）。
    ShowCreateTable,
    /// `DESCRIBE`。Iceberg だけ本体・`.metadata` を binary/octet-stream で置き、UpdateCount を 0 にする
    /// （2026-09-24 実測。#160）。`DESC` も同じ（2026-09-24 実測。#173 d6）。
    Describe,
    /// `SHOW COLUMNS FROM`／`IN`。形式は結果ファイルの書き方ではなく行の形（Hive は列名を 20 桁に左詰め、
    /// Iceberg は詰めない）に使う（2026-09-16／2026-09-24 実測。#173）。
    ShowColumns,
}

/// 問い合わせで分かる、対象テーブルの Trino コネクタ。対象がビューなら、コネクタによらず `View`
/// （本物は Hive のカタログのビューも Iceberg のカタログのビューも同じ形で返す。2026-09-24 実測 d5。#173）。
/// ビューを別の戻り値（`(TableFormat, bool)` など）にせず形式の 1 つとして持つのは、呼び出し元
/// （`run` の `iceberg_partition_specs` の条件、`utility_rows::reshape` の形式ごとの分岐）が
/// `== Some(TableFormat::Iceberg)` で比べていて、ビューが自然に Iceberg の腕から外れるため。
/// `format_override` の網羅 match には腕が増えるが、ビューを足し忘れた組み合わせはコンパイラが検出する。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum TableFormat {
    Hive,
    Iceberg,
    View,
}

/// テーブルの形式で本体・`.metadata` の書き方を上書きする、文の種類とテーブルの形式の組み合わせ
/// （2026-09-20〜24 実測）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum FormatOverride {
    /// DROP TABLE × Iceberg。本体に改行 1 つ、`.metadata` に 41 バイト
    /// （field 1 = Trino のエンジンのクエリ ID、field 2 = `DROP TABLE`）。
    DropTableIceberg,
    /// ALTER TABLE ... ADD COLUMNS / REPLACE COLUMNS × Hive。本体は 0 バイトのまま、
    /// `.metadata` に 38 バイト（field 1 = QueryExecutionId のみ。field 2 の updateType も
    /// field 3 の更新件数も無い。Trino の updateType は `"ADD COLUMN"` で Athena の
    /// `ADD COLUMNS` と綴りが違うので使わない。2026-09-21 実測）。REPLACE COLUMNS の
    /// `.metadata` は ADD COLUMNS と 1 バイトも変わらない（同じ日の実測で中身を突き合わせた）。
    AlterColumnsHive,
    /// SHOW CREATE TABLE × Iceberg。本体は Trino の DDL 文をそのまま、`.metadata` は素の
    /// protobuf だが、Content-Type は本体・`.metadata` とも binary/octet-stream にし、先頭
    /// （field 1）はエンジン（Trino）のクエリ ID にする（本物の `.metadata` は不透明で先頭 ID を
    /// 観測できないため、EXPLAIN に倣う。2026-09-24 実測。#151）。
    ShowCreateTableIceberg,
    /// DESCRIBE × Iceberg。SHOW CREATE TABLE × Iceberg と同じ扱い（本体・`.metadata` とも binary/octet-stream、
    /// 先頭はエンジン ID、UpdateCount は 0。2026-09-24 実測。#160）。
    DescribeIceberg,
    /// DESCRIBE × ビュー。DESCRIBE × Iceberg と同じ扱い（本体・`.metadata` とも binary/octet-stream、
    /// 先頭はエンジン ID、UpdateCount は 0。本物の `.metadata` は 440 バイトの不透明な形式。2026-09-24 実測 d5。#173）。
    DescribeView,
}

/// この文が対象か。対象は DROP TABLE と、ALTER TABLE の ADD COLUMNS / REPLACE COLUMNS と、SHOW CREATE TABLE と DESCRIBE と
/// SHOW COLUMNS だけ
/// （`substatement_type` の判定をそのまま使い、判定を二重に持たない）。
/// 修飾名でカタログを明示していても対象にする（Phase 2）。
pub(super) fn target_statement(query: &str) -> Option<TargetStatement> {
    match super::classification::substatement_type(query) {
        Some("DROP_TABLE") => Some(TargetStatement::DropTable),
        Some("ALTER_TABLE_ADD_COLUMN") => Some(TargetStatement::AlterTableAddColumns),
        Some("ALTER_TABLE_REPLACE_COLUMN") => Some(TargetStatement::AlterTableReplaceColumns),
        Some("SHOW_CREATE_TABLE") => Some(TargetStatement::ShowCreateTable),
        Some("DESCRIBE_TABLE") => Some(TargetStatement::Describe),
        Some("SHOW_COLUMNS") => Some(TargetStatement::ShowColumns),
        _ => None,
    }
}

/// 形式の判定を GetQueryResults の UpdateCount にも使う文か。結果ファイルを書かない設定でも
/// 問い合わせる根拠になる（#160）。DROP TABLE と ALTER TABLE は結果ファイルにしか効かない。
/// SHOW COLUMNS は UpdateCount ではなく行の形（Hive は 20 桁詰め、Iceberg は詰めない）に使う（#173）。
pub(super) fn needs_format_for_update_count(statement: TargetStatement) -> bool {
    matches!(
        statement,
        TargetStatement::ShowCreateTable | TargetStatement::Describe | TargetStatement::ShowColumns
    )
}

/// テーブルの形式と存在を Trino に 1 回の問い合わせで確かめる。失敗・非対応の形式・
/// 対象が存在しないときは None に倒す（`statement::bind` の分類の問い合わせと同型）。
/// カタログ名は呼び出し元が別名解決した後の値を渡すこと（`system.metadata.catalogs` /
/// `system.jdbc.tables` は Trino 側の名前でしか引けない）。
pub(super) async fn probe_format(
    trino: &Trino,
    catalog: &str,
    schema: &str,
    table: &str,
    database: Option<&str>,
    cancel: &Cancel,
) -> Option<TableFormat> {
    let sql = probe_sql(catalog, schema, table);
    let outcome = trino
        .execute(&sql, Some(catalog), database, cancel)
        .await
        .ok()?;
    parse_probe_result(&outcome)
}

/// 形式（`system.metadata.catalogs.connector_name`）と存在・ビューかどうか（`system.jdbc.tables` の
/// `table_type`。無ければ null、テーブルは `TABLE`、ビューは `VIEW`）を 1 つの SELECT にまとめる。
/// `system.jdbc.tables` を使うのは `table_cat` / `table_schem` / `table_name` を全部リテラルで書けるため
/// （識別子のクォートを手書きしなくて済む）。
pub(super) fn probe_sql(catalog: &str, schema: &str, table: &str) -> String {
    format!(
        "SELECT ({}), (SELECT table_type FROM system.jdbc.tables WHERE table_cat = {} AND table_schem = {} AND table_name = {})",
        connector_name_sql(catalog),
        quote_literal(catalog),
        quote_literal(schema),
        quote_literal(table),
    )
}

/// カタログの有無だけを確かめる（`context_catalog::resolve`。#214）。無ければ `_col0` が null の 1 行。
pub(super) fn catalog_exists_sql(catalog: &str) -> String {
    format!("SELECT ({})", connector_name_sql(catalog))
}

/// 名前空間（スキーマ）の有無だけを確かめる（`create_table_catalog`。#227）。無ければ Trino が `SCHEMA_NOT_FOUND` で
/// 失敗し、あれば 0 行で成功する（`LIKE ''` で表を列挙しない）。一覧（`system.jdbc.schemas`・`SHOW SCHEMAS`）は
/// file メタストアの compose の Trino で `CREATE SCHEMA` した名前空間を返さなかったので使わず、名前空間を直接引く。
pub(super) fn schema_probe_sql(catalog: &str, schema: &str) -> String {
    format!(
        "SHOW TABLES FROM {}.{} LIKE ''",
        quote_identifier(catalog),
        quote_identifier(schema),
    )
}

fn connector_name_sql(catalog: &str) -> String {
    format!(
        "SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = {}",
        quote_literal(catalog)
    )
}

/// `probe_sql` の応答から形式を決める。対象が存在しなければ（`table_type` が null なら）None
/// （Hive 側と同じ今までどおりの振る舞いに倒す）。hive でも iceberg でもない値も None。
/// `table_type` が `VIEW` なら（hive と iceberg のカタログのうち）`View`。
fn parse_probe_result(outcome: &Outcome) -> Option<TableFormat> {
    let row = outcome.rows.first()?;
    let format = match row.first()?.as_str()? {
        "hive" => TableFormat::Hive,
        "iceberg" => TableFormat::Iceberg,
        _ => return None,
    };
    match row.get(1)?.as_str()? {
        "VIEW" => Some(TableFormat::View),
        _ => Some(format),
    }
}

/// 文の種類とテーブルの形式の組み合わせから、本体・`.metadata` の書き方を上書きする文を決める。
/// DROP TABLE・ALTER TABLE・SHOW CREATE TABLE × ビューは Trino で失敗するので、Hive と同じく上書きしない。
pub(super) fn format_override(
    statement: TargetStatement,
    format: TableFormat,
) -> Option<FormatOverride> {
    match (statement, format) {
        (TargetStatement::DropTable, TableFormat::Iceberg) => {
            Some(FormatOverride::DropTableIceberg)
        }
        (TargetStatement::DropTable, TableFormat::Hive | TableFormat::View) => None,
        (
            TargetStatement::AlterTableAddColumns | TargetStatement::AlterTableReplaceColumns,
            TableFormat::Hive,
        ) => Some(FormatOverride::AlterColumnsHive),
        (
            TargetStatement::AlterTableAddColumns | TargetStatement::AlterTableReplaceColumns,
            TableFormat::Iceberg | TableFormat::View,
        ) => None,
        (TargetStatement::ShowCreateTable, TableFormat::Iceberg) => {
            Some(FormatOverride::ShowCreateTableIceberg)
        }
        (TargetStatement::ShowCreateTable, TableFormat::Hive | TableFormat::View) => None,
        (TargetStatement::Describe, TableFormat::Iceberg) => Some(FormatOverride::DescribeIceberg),
        (TargetStatement::Describe, TableFormat::View) => Some(FormatOverride::DescribeView),
        (TargetStatement::Describe, TableFormat::Hive) => None,
        // 本物は Hive でも Iceberg でも `.txt` を binary で置き、UpdateCount は 0（2026-09-24 実測。#173）。
        // どちらも SQL だけで決まる既定のままなので、書き方を上書きしない。
        (TargetStatement::ShowColumns, _) => None,
    }
}

#[cfg(test)]
mod tests;
