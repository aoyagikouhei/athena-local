//! table_format.rs のユニットテスト（結合テストは tests/table_format.rs）。

use serde_json::Value;

use super::*;

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
fn target_statement_は_alter_table_add_columns_も対象にする() {
    // classification.rs が返す ALTER_TABLE_ADD_COLUMN をそのまま使う（判定を二重に持たない）。
    for query in [
        "ALTER TABLE t ADD COLUMNS (m int)",
        "ALTER TABLE t ADD COLUMN m int",
    ] {
        assert_eq!(
            target_statement(query),
            Some(TargetStatement::AlterTableAddColumns),
            "{query:?}"
        );
    }
}

#[test]
fn target_statement_は_alter_table_replace_columns_も対象にする() {
    // REPLACE COLUMNS × Hive は ADD COLUMNS × Hive と同じ 38 バイトの .metadata を置く
    // （2026-09-21 実測。保存した中身を ADD COLUMNS のものと突き合わせて確かめた）ので、
    // 形式の問い合わせが要る。
    assert_eq!(
        target_statement("ALTER TABLE t REPLACE COLUMNS (n int, s string)"),
        Some(TargetStatement::AlterTableReplaceColumns)
    );
}

#[test]
fn target_statement_は_add_columns_以外の_alter_table_を対象外にする() {
    // SET TBLPROPERTIES / DROP COLUMN / SET LOCATION / ADD PARTITION / DROP PARTITION は
    // 本物も列なしの本体・.metadata を置かない（2026-09-21 実測）。IF EXISTS と
    // RENAME COLUMN は Athena に構文が無いので classification.rs の時点で None になる。
    // RENAME TO は分類はされる（ALTER_TABLE_RENAME）が、.metadata は置かない。
    for query in [
        "ALTER TABLE t SET TBLPROPERTIES ('comment' = 'remember to add column for region')",
        "ALTER TABLE t DROP COLUMN c",
        "ALTER TABLE t SET LOCATION 's3://bucket/path/'",
        "ALTER TABLE t ADD PARTITION (p = 'v')",
        "ALTER TABLE t DROP PARTITION (p = 'v')",
        "ALTER TABLE IF EXISTS t ADD COLUMNS (m int)",
        "ALTER TABLE t RENAME COLUMN a TO b",
        "ALTER TABLE t RENAME TO u",
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
fn format_override_は_drop_table_と_iceberg_の組み合わせだけ_some() {
    assert_eq!(
        format_override(TargetStatement::DropTable, TableFormat::Iceberg),
        Some(FormatOverride::DropTableIceberg)
    );
    assert_eq!(
        format_override(TargetStatement::DropTable, TableFormat::Hive),
        None
    );
}

#[test]
fn format_override_は_列を変える_alter_table_と_hive_の組み合わせだけ_some() {
    // ADD COLUMNS と REPLACE COLUMNS は Hive で同じ .metadata を置く（2026-09-21 実測）。
    for statement in [
        TargetStatement::AlterTableAddColumns,
        TargetStatement::AlterTableReplaceColumns,
    ] {
        assert_eq!(
            format_override(statement, TableFormat::Hive),
            Some(FormatOverride::AlterColumnsHive),
            "{statement:?}"
        );
        assert_eq!(
            format_override(statement, TableFormat::Iceberg),
            None,
            "{statement:?}"
        );
    }
}

#[test]
fn target_statement_は_show_create_table_も対象にし_show_create_view_は対象外にする() {
    // 本物は SHOW CREATE TABLE の結果ファイルをテーブルの形式で書き分ける（2026-09-24 実測。#151）。
    // SHOW CREATE VIEW は形式によらず binary なので問い合わせない。
    assert_eq!(
        target_statement("SHOW CREATE TABLE t"),
        Some(TargetStatement::ShowCreateTable)
    );
    for query in ["SHOW CREATE VIEW v", "SHOW TABLES"] {
        assert_eq!(target_statement(query), None, "{query:?}");
    }
}

#[test]
fn format_override_は_show_create_table_と_iceberg_の組み合わせだけ_some() {
    // Iceberg は本体・`.metadata` とも binary、Hive は今までどおり application（2026-09-24 実測。#151）。
    assert_eq!(
        format_override(TargetStatement::ShowCreateTable, TableFormat::Iceberg),
        Some(FormatOverride::ShowCreateTableIceberg)
    );
    assert_eq!(
        format_override(TargetStatement::ShowCreateTable, TableFormat::Hive),
        None
    );
}

#[test]
fn show_columns_は対象にし_書き方は上書きせず_s3_が無効でも形式を問い合わせる() {
    // 形式は行の形（Hive は 20 桁に左詰め、Iceberg は詰めない）に使う（#173）。
    assert_eq!(
        target_statement("SHOW COLUMNS FROM t"),
        Some(TargetStatement::ShowColumns)
    );
    for format in [TableFormat::Hive, TableFormat::Iceberg, TableFormat::View] {
        assert_eq!(
            format_override(TargetStatement::ShowColumns, format),
            None,
            "{format:?}"
        );
    }
    assert!(needs_format_for_update_count(TargetStatement::ShowColumns));
}

#[tokio::test]
async fn 形式の問い合わせが失敗すれば今までどおりに倒す() {
    // 127.0.0.1:1 には何も listen していないので接続に失敗する。
    let trino = Trino::new("http://127.0.0.1:1", "test");
    let cancel = Cancel::default();
    assert_eq!(
        probe_format(&trino, "cat", "ns", "t", None, &cancel).await,
        None
    );
}

#[test]
fn target_statement_は修飾名でカタログを指す文も対象にする() {
    for query in [
        "DROP TABLE cat.ns.t",
        "DROP TABLE \"s3tablescatalog/my-bucket\".ns.t",
        "DROP TABLE IF EXISTS cat.ns.t",
    ] {
        assert_eq!(
            target_statement(query),
            Some(TargetStatement::DropTable),
            "{query:?}"
        );
    }
}

#[test]
fn probe_sql_はカタログ_スキーマ_テーブル名を全部リテラルで埋め込む() {
    assert_eq!(
        probe_sql("cat", "ns", "t"),
        "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = 'cat'), (SELECT table_type FROM system.jdbc.tables WHERE table_cat = 'cat' AND table_schem = 'ns' AND table_name = 't')"
    );
}

#[test]
fn probe_sql_は単一引用符を含む名前を_quote_literal_で埋め込む() {
    assert_eq!(
        probe_sql("it's", "ns", "t"),
        "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = 'it''s'), (SELECT table_type FROM system.jdbc.tables WHERE table_cat = 'it''s' AND table_schem = 'ns' AND table_name = 't')"
    );
}

fn outcome_with_probe_result(format: Option<&str>, table_type: Option<&str>) -> Outcome {
    let text = |value: Option<&str>| value.map_or(Value::Null, Value::from);
    Outcome {
        rows: vec![vec![text(format), text(table_type)]],
        ..Outcome::default()
    }
}

#[test]
fn parse_probe_result_は形式とテーブルがそろえば形式を返す() {
    assert_eq!(
        parse_probe_result(&outcome_with_probe_result(Some("hive"), Some("TABLE"))),
        Some(TableFormat::Hive)
    );
    assert_eq!(
        parse_probe_result(&outcome_with_probe_result(Some("iceberg"), Some("TABLE"))),
        Some(TableFormat::Iceberg)
    );
}

#[test]
fn parse_probe_result_はビューならカタログの形式によらず_view() {
    // 本物は Hive のカタログのビューも Iceberg のカタログのビューも同じ形で返す（2026-09-24 実測 d5。#173）。
    for format in ["hive", "iceberg"] {
        assert_eq!(
            parse_probe_result(&outcome_with_probe_result(Some(format), Some("VIEW"))),
            Some(TableFormat::View),
            "{format}"
        );
    }
}

#[test]
fn parse_probe_result_は対象が無ければ形式が読めても_none() {
    assert_eq!(
        parse_probe_result(&outcome_with_probe_result(Some("iceberg"), None)),
        None
    );
}

#[test]
fn parse_probe_result_はカタログが無ければ_none() {
    assert_eq!(
        parse_probe_result(&outcome_with_probe_result(None, None)),
        None
    );
}

#[test]
fn parse_probe_result_は_hive_でも_iceberg_でもない形式は判定しない() {
    for table_type in ["TABLE", "VIEW"] {
        assert_eq!(
            parse_probe_result(&outcome_with_probe_result(
                Some("delta_lake"),
                Some(table_type)
            )),
            None,
            "{table_type}"
        );
    }
}

#[test]
fn format_override_は_describe_とビューの組み合わせを_describe_view_にし_ほかの文は上書きしない() {
    // DESCRIBE × ビューは DESCRIBE × Iceberg と同じ扱い（binary、先頭はエンジン ID、UpdateCount 0。
    // 2026-09-24 実測 d5。#173）。ほかの文はビューに対して Trino で失敗するので Hive と同じく None。
    assert_eq!(
        format_override(TargetStatement::Describe, TableFormat::View),
        Some(FormatOverride::DescribeView)
    );
    for statement in [
        TargetStatement::DropTable,
        TargetStatement::AlterTableAddColumns,
        TargetStatement::AlterTableReplaceColumns,
        TargetStatement::ShowCreateTable,
        TargetStatement::ShowColumns,
    ] {
        assert_eq!(
            format_override(statement, TableFormat::View),
            None,
            "{statement:?}"
        );
    }
}
