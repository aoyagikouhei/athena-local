//! SHOW COLUMNS／DESCRIBE の Trino の結果を、本物の列と 1 値の行に作り直す（#173）。
//! 本物はこれらの文を Trino と違う列数・行の形で返すので、`classification::fixed_column` の
//! 列名の差し替えだけでは揃わない。完了時に `Outcome` の列と行を作り直し、GetQueryResults・
//! `.txt`・`.metadata` に同じ値を渡す（`completion::split_explain_rows` と同じ置き場）。
//! DESCRIBE は Hive のテーブル（と形式が判定できないとき）と Iceberg のテーブルで行の形が違う。
//! ビューへの DESCRIBE と SHOW COLUMNS は、カタログの形式によらず同じ別の形になる。

use serde_json::Value;

use super::iceberg_partitions::partition_row;
use super::table_format::TableFormat;
use super::type_spelling;
use crate::athena::ColumnInfo;
use crate::trino::{Column, Outcome};

/// Hive のテーブルの SHOW COLUMNS／DESCRIBE で列名・型・コメントを左詰めする桁数（2026-09-16／24 実測。#173）。
const HIVE_WIDTH: usize = 20;

/// Hive のテーブルの DESCRIBE で、パーティション列があるときに上半分の後ろに置く見出し行群
/// （2026-09-16／24 実測。#173 d1・d6）。
const PARTITION_HEADER: [&str; 4] = [
    "\t \t ",
    "# Partition Information\t \t ",
    "# col_name            \tdata_type           \tcomment             ",
    "\t \t ",
];

/// SHOW COLUMNS なら、列を本物の `field`／string の 1 列に、行を列名 1 つずつの行に作り直す
/// （2026-09-16／2026-09-24 実測。#173）。Hive のテーブル（と形式が判定できないとき）の DESCRIBE なら、
/// 列を `col_name`／`data_type`／`comment` の string の 3 列に、行を 3 つをタブでつないだ 1 値の行に
/// 作り直す（2026-09-24 実測。#173）。Iceberg のテーブルの DESCRIBE も同じ 3 列にし、行は詰めずに
/// `partitions`（Trino の `SHOW CREATE TABLE` の `partitioning` の要素）からパーティション行を足す
/// （2026-09-24 実測 d2・d8）。ビューへの DESCRIBE と SHOW COLUMNS は、どちらも列を `column`／`type` の
/// varchar の 2 列に、行を `<列名>\t<Trino の型>`（詰め無し）の 1 値の行に作り直す（2026-09-24 実測 d5）。
/// `update_count`・`id`・`update_type` は触らない。ほかの文はそのまま返す。
pub(super) fn reshape(
    query: &str,
    outcome: Outcome,
    format: Option<TableFormat>,
    partitions: &[String],
) -> Outcome {
    match super::classification::substatement_type(query) {
        Some("SHOW_COLUMNS" | "DESCRIBE_TABLE") if format == Some(TableFormat::View) => {
            let rows = outcome
                .rows
                .iter()
                .map(|row| format!("{}\t{}", cell(row, 0), cell(row, 1)))
                .collect();
            replace(outcome, &[("column", "varchar"), ("type", "varchar")], rows)
        }
        Some("SHOW_COLUMNS") => {
            let rows = show_columns_rows(&outcome.rows, format);
            replace(outcome, &[("field", "string")], rows)
        }
        Some("DESCRIBE_TABLE") => {
            let rows = if format == Some(TableFormat::Iceberg) {
                describe_iceberg_rows(&outcome.rows, partitions)
            } else {
                describe_hive_rows(&outcome.rows)
            };
            replace(
                outcome,
                &[
                    ("col_name", "string"),
                    ("data_type", "string"),
                    ("comment", "string"),
                ],
                rows,
            )
        }
        _ => outcome,
    }
}

/// 列を `columns`（名前と型の対）の列（Precision・Scale 0、CaseSensitive false）に、行を 1 値の行に置き換える。
/// ビューの varchar も 0/false なので（2026-09-24 実測 d5）、`athena_type` の表（varchar は 2147483647/true）
/// ではなくここで決めた ColumnInfo を `athena_columns` に置く。
fn replace(mut outcome: Outcome, columns: &[(&str, &str)], rows: Vec<String>) -> Outcome {
    outcome.rows = rows
        .into_iter()
        .map(|text| vec![Value::from(text)])
        .collect();
    outcome.columns = columns
        .iter()
        .map(|(name, type_name)| Column {
            name: name.to_string(),
            type_name: type_name.to_string(),
            type_signature: None,
        })
        .collect();
    outcome.athena_columns = Some(
        columns
            .iter()
            .map(|(name, type_name)| ColumnInfo {
                name: name.to_string(),
                label: name.to_string(),
                type_name: type_name.to_string(),
                nullable: "UNKNOWN".to_string(),
                case_sensitive: false,
                catalog_name: "hive".to_string(),
                schema_name: String::new(),
                table_name: String::new(),
                precision: 0,
                scale: 0,
            })
            .collect(),
    );
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

/// Trino の DESCRIBE（`Column`／`Type`／`Extra`／`Comment` の 4 列）を、本物の Hive のテーブルの行
/// （`<列名>\t<型>\t<コメント>`、どれも 20 桁に左詰め）にする。パーティション列（`Extra` が
/// `partition key`）は上半分にも普通の列として出し、1 つでもあれば見出し行群の後ろにもう一度並べる
/// （2026-09-24 実測。#173 d1・d6）。
fn describe_hive_rows(rows: &[Vec<Value>]) -> Vec<String> {
    let line = |row: &Vec<Value>| {
        format!(
            "{}\t{}\t{}",
            pad(cell(row, 0)),
            pad(&type_spelling::hive(cell(row, 1))),
            comment_field(cell(row, 3))
        )
    };
    let mut lines: Vec<String> = rows.iter().map(line).collect();
    let partitions: Vec<String> = rows
        .iter()
        .filter(|row| cell(row, 2) == "partition key")
        .map(line)
        .collect();
    if !partitions.is_empty() {
        lines.extend(PARTITION_HEADER.map(str::to_string));
        lines.extend(partitions);
    }
    lines
}

/// Trino の DESCRIBE（4 列）と `partitioning` の要素を、本物の Iceberg のテーブルの行にする
/// （2026-09-24 実測 d2・d8。#173）。詰めない。
/// 型は `type_spelling::iceberg`、コメントはそのまま（無ければ空）。パーティションの行は
/// `iceberg_partitions::partition_row` が写せるものだけ（パーティションが無ければ見出しまで）。
fn describe_iceberg_rows(rows: &[Vec<Value>], partitions: &[String]) -> Vec<String> {
    let mut lines = vec![
        "# Table schema:\t\t".to_string(),
        "# col_name\tdata_type\tcomment".to_string(),
    ];
    lines.extend(rows.iter().map(|row| {
        format!(
            "{}\t{}\t{}",
            cell(row, 0),
            type_spelling::iceberg(cell(row, 1)),
            cell(row, 3)
        )
    }));
    lines.extend(
        [
            "\t\t",
            "# Partition spec:\t\t",
            "# field_name\tfield_transform\tcolumn_name",
        ]
        .map(str::to_string),
    );
    lines.extend(partitions.iter().filter_map(|spec| {
        let (field_name, transform, column) = partition_row(spec)?;
        Some(format!("{field_name}\t{transform}\t{column}"))
    }));
    lines
}

/// DESCRIBE のコメント欄。20 桁に詰めてから先頭のタブまでを取る（空なら空白 20 個、`abc` は `abc` + 空白 17 個、
/// `a\tb` は `a`。2026-09-24 実測 d1・#146）。改行入りのコメントは本物に存在しないので何もしない。
fn comment_field(comment: &str) -> String {
    let padded = pad(comment);
    match padded.split_once('\t') {
        Some((head, _)) => head.to_string(),
        None => padded,
    }
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
mod tests;
