//! SHOW COLUMNS／DESCRIBE の Trino の結果を、本物の列と 1 値の行に作り直す（#173）。
//! 本物はこれらの文を Trino と違う列数・行の形で返すので、`classification::fixed_column` の
//! 列名の差し替えだけでは揃わない。完了時に `Outcome` の列と行を作り直し、GetQueryResults・
//! `.txt`・`.metadata` に同じ値を渡す（`execution::split_explain_rows` と同じ置き場）。
//! このフェーズで作り直すのは SHOW COLUMNS だけ（DESCRIBE は後のフェーズ）。

use serde_json::Value;

use super::table_format::TableFormat;
use crate::athena::ColumnInfo;
use crate::trino::{Column, Outcome};

/// Hive のテーブルの SHOW COLUMNS で列名を左詰めする桁数（2026-09-16 実測。#173）。
const HIVE_WIDTH: usize = 20;

/// SHOW COLUMNS なら、列を本物の `field`／string の 1 列に、行を列名 1 つずつの行に作り直す
/// （2026-09-16／2026-09-24 実測。#173）。`update_count`・`id`・`update_type` は触らない。
/// ほかの文はそのまま返す。
pub(super) fn reshape(query: &str, mut outcome: Outcome, format: Option<TableFormat>) -> Outcome {
    if super::classification::substatement_type(query) != Some("SHOW_COLUMNS") {
        return outcome;
    }
    outcome.rows = show_columns_rows(&outcome.rows, format)
        .into_iter()
        .map(|text| vec![Value::from(text)])
        .collect();
    outcome.columns = vec![Column {
        name: "field".to_string(),
        type_name: "string".to_string(),
        type_signature: None,
    }];
    outcome.athena_columns = Some(vec![ColumnInfo {
        name: "field".to_string(),
        label: "field".to_string(),
        type_name: "string".to_string(),
        nullable: "UNKNOWN".to_string(),
        case_sensitive: false,
        catalog_name: "hive".to_string(),
        schema_name: String::new(),
        table_name: String::new(),
        precision: 0,
        scale: 0,
    }]);
    outcome
}

/// Trino の SHOW COLUMNS（`Column`／`Type`／`Extra`／`Comment` の 4 列）の `Column` だけを取り、
/// Hive のテーブル（と形式が判定できないとき）は 20 桁に左詰めし、Iceberg のテーブルは詰めない。
fn show_columns_rows(rows: &[Vec<Value>], format: Option<TableFormat>) -> Vec<String> {
    rows.iter()
        .map(|row| {
            let name = cell(row, 0);
            if format == Some(TableFormat::Iceberg) {
                name.to_string()
            } else {
                pad(name)
            }
        })
        .collect()
}

/// 20 桁に満たなければ右を空白で埋める。20 桁以上はそのまま（切らない）。幅は文字数で数える。
fn pad(text: &str) -> String {
    let width = text.chars().count();
    if width < HIVE_WIDTH {
        format!("{text}{}", " ".repeat(HIVE_WIDTH - width))
    } else {
        text.to_string()
    }
}

/// 行の `index` 番目の文字列。文字列でない値（null）や欠けている値は空文字にする。
fn cell(row: &[Value], index: usize) -> &str {
    match row.get(index) {
        Some(Value::String(text)) => text,
        _ => "",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Trino の SHOW COLUMNS の 1 行（4 列）。
    fn trino_row(name: &str) -> Vec<Value> {
        vec![
            Value::from(name),
            Value::from("integer"),
            Value::from(""),
            Value::from(""),
        ]
    }

    #[test]
    fn pad_は_20_桁に満たない名前だけ右を空白で埋める() {
        let nineteen = "a".repeat(19);
        let twenty = "a".repeat(20);
        let twenty_one = "a".repeat(21);
        assert_eq!(pad(&nineteen), format!("{nineteen} "));
        assert_eq!(pad(&twenty), twenty);
        assert_eq!(pad(&twenty_one), twenty_one);
        assert_eq!(pad("n"), format!("n{}", " ".repeat(19)));
    }

    #[test]
    fn show_columns_rows_は_hive_と判定できないときは詰め_iceberg_は詰めない() {
        let rows = [trino_row("n"), trino_row("p")];
        let padded = [
            format!("n{}", " ".repeat(19)),
            format!("p{}", " ".repeat(19)),
        ];
        assert_eq!(show_columns_rows(&rows, Some(TableFormat::Hive)), padded);
        assert_eq!(show_columns_rows(&rows, None), padded);
        assert_eq!(
            show_columns_rows(&rows, Some(TableFormat::Iceberg)),
            ["n", "p"]
        );
    }

    #[test]
    fn cell_は文字列でない値と欠けている値を空にする() {
        let row = [Value::from("n"), Value::Null];
        assert_eq!(cell(&row, 0), "n");
        assert_eq!(cell(&row, 1), "");
        assert_eq!(cell(&row, 2), "");
        assert_eq!(
            show_columns_rows(&[vec![Value::Null]], Some(TableFormat::Iceberg)),
            [""]
        );
    }

    fn trino_show_columns() -> Outcome {
        Outcome {
            columns: ["Column", "Type", "Extra", "Comment"]
                .map(|name| Column {
                    name: name.to_string(),
                    type_name: "varchar".to_string(),
                    type_signature: None,
                })
                .into(),
            rows: vec![trino_row("n")],
            update_count: None,
            id: Some("engine".to_string()),
            update_type: None,
            athena_columns: None,
        }
    }

    #[test]
    fn reshape_は_show_columns_を_field_の_1_列と_1_値の行に作り直す() {
        let outcome = reshape(
            "SHOW COLUMNS FROM t",
            trino_show_columns(),
            Some(TableFormat::Hive),
        );

        assert_eq!(outcome.columns.len(), 1);
        assert_eq!(outcome.columns[0].name, "field");
        assert_eq!(outcome.columns[0].type_name, "string");
        assert!(outcome.columns[0].type_signature.is_none());
        assert_eq!(
            outcome.rows,
            [[Value::from(format!("n{}", " ".repeat(19)))]]
        );

        let infos = outcome.athena_columns.expect("作り直した ColumnInfo");
        assert_eq!(infos.len(), 1);
        let info = &infos[0];
        assert_eq!(info.name, "field");
        assert_eq!(info.label, "field");
        assert_eq!(info.type_name, "string");
        assert_eq!(info.precision, 0);
        assert_eq!(info.scale, 0);
        assert!(!info.case_sensitive);
        assert_eq!(info.catalog_name, "hive");
        assert_eq!(info.schema_name, "");
        assert_eq!(info.table_name, "");
        assert_eq!(info.nullable, "UNKNOWN");
        // 実行の ID は触らない。
        assert_eq!(outcome.id.as_deref(), Some("engine"));
    }

    #[test]
    fn reshape_は_show_columns_以外の文をそのまま返す() {
        let outcome = reshape("DESCRIBE t", trino_show_columns(), Some(TableFormat::Hive));
        assert_eq!(outcome.columns.len(), 4);
        assert_eq!(outcome.rows, [trino_row("n")]);
        assert!(outcome.athena_columns.is_none());
    }
}
