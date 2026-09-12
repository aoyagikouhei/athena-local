//! Trino の結果を Athena の ResultSet に写す。

use serde_json::Value;

use crate::athena::{ColumnInfo, Datum, ResultSet, ResultSetMetadata, Row};
use crate::trino::Outcome;

/// SELECT の 1 ページ目の先頭行は列名（本物の Athena と同じ）。
/// ページングできるよう、ヘッダ行込みの一覧をまとめて作る。
pub fn all_rows(outcome: &Outcome) -> Vec<Vec<Option<String>>> {
    if outcome.update_count.is_some() {
        // DML は行を返さず UpdateCount だけ。
        return Vec::new();
    }

    let header = outcome
        .columns
        .iter()
        .map(|column| Some(column.name.clone()))
        .collect();

    let mut rows = vec![header];
    rows.extend(
        outcome
            .rows
            .iter()
            .map(|row| row.iter().map(to_var_char_value).collect()),
    );

    rows
}

pub fn result_set(outcome: &Outcome, rows: &[Vec<Option<String>>]) -> ResultSet {
    // DML の列（Trino が返す rows 列）は本物の Athena には無いので載せない。
    let columns = match outcome.update_count {
        Some(_) => Vec::new(),
        None => outcome.columns.iter().map(to_column_info).collect(),
    };

    ResultSet {
        rows: rows.iter().map(|row| to_row(row)).collect(),
        result_set_metadata: ResultSetMetadata {
            column_info: columns,
        },
    }
}

/// Athena は値をすべて文字列で返す。NULL は Datum ごと空にする。
fn to_var_char_value(value: &Value) -> Option<String> {
    match value {
        Value::Null => None,
        Value::String(text) => Some(text.clone()),
        Value::Bool(flag) => Some(flag.to_string()),
        Value::Number(number) => Some(number.to_string()),
        other => Some(other.to_string()),
    }
}

fn to_row(values: &[Option<String>]) -> Row {
    Row {
        data: values
            .iter()
            .map(|value| Datum {
                var_char_value: value.clone(),
            })
            .collect(),
    }
}

fn to_column_info(column: &crate::trino::Column) -> ColumnInfo {
    ColumnInfo {
        name: column.name.clone(),
        label: column.name.clone(),
        type_name: column.type_name.clone(),
        nullable: "UNKNOWN".to_string(),
        case_sensitive: false,
    }
}
