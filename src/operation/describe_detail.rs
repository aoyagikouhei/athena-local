//! DESCRIBE EXTENDED／FORMATTED の Hive の表・ビューの結果の行を組み立てる（#275 フェーズ 2）。
//! 入力は Trino の `DESCRIBE <名前>` の行（`Column`／`Type`／`Extra`／`Comment`。パーティション列は
//! `Extra` が `partition key`）と、表の情報（DB 名・表名・表かビューか）。出力は本物の行（1 行 = タブを
//! 含む 1 セル）。本物の Thrift（`Table(...)`・`Partition(...)`）と FORMATTED の節・行は、Trino から出せる
//! 値と、実測した Hive 表・パーティション付き Hive 表・ビューのどれでも同じだった値だけを入れ、作り方で
//! 変わる値・取れない値は省く（2026-09-27 実測。#275。詳細は docs/dev/measurements/statements.md の
//! 該当節）。`describe_run::run` から配線する（#275 フェーズ 3・4）。

use serde_json::Value;

use super::type_spelling;
use super::utility_rows::{PARTITION_HEADER, cell, comment_field, describe_hive_rows, pad};

/// 表かビューか。Thrift の `tableType`／FORMATTED の `Table Type` の値を決める。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Kind {
    Table,
    View,
}

impl Kind {
    fn thrift(self) -> &'static str {
        match self {
            Kind::Table => "EXTERNAL_TABLE",
            Kind::View => "VIRTUAL_VIEW",
        }
    }
}

/// EXTENDED・FORMATTED の Thrift／節に載せる表の情報。
pub(super) struct Table<'a> {
    pub(super) db: &'a str,
    pub(super) name: &'a str,
    pub(super) kind: Kind,
}

/// FORMATTED の列指定（p2）の ColumnInfo の列名。11 列（2026-09-27 実測 p2）
pub(super) const COLUMN_INFO_NAMES: [&str; 11] = [
    "col_name",
    "data_type",
    "min",
    "max",
    "num_nulls",
    "distinct_count",
    "avg_col_len",
    "max_col_len",
    "num_trues",
    "num_falses",
    "comment",
];

/// EXTENDED の結果の行（e_h・e_hp・e_v）。
pub(super) fn extended(rows: &[Vec<Value>], table: &Table) -> Vec<String> {
    let mut lines = describe_hive_rows(rows);
    lines.push("\t \t ".to_string());
    lines.push(format!(
        "Detailed Table Information\t{}\t",
        table_thrift(rows, table)
    ));
    lines
}

/// FORMATTED の結果の行（f_h・f_hp・f_v）。
pub(super) fn formatted(rows: &[Vec<Value>], table: &Table) -> Vec<String> {
    let mut lines = formatted_columns_block(rows);
    lines.push("\t \t ".to_string());
    lines.push(heading("# Detailed Table Information"));
    lines.push(kv("Database:", table.db));
    lines.push(kv("LastAccessTime:", "UNKNOWN"));
    lines.push(kv("Protect Mode:", "None"));
    lines.push(kv("Retention:", "0"));
    lines.push(kv("Table Type:", table.kind.thrift()));
    lines.push("\t \t ".to_string());
    lines.push(heading("# Storage Information"));
    lines.push(kv("Compressed:", "No"));
    lines.push(kv("Bucket Columns:", "[]"));
    lines.push(kv("Sort Columns:", "[]"));
    lines
}

/// 列指定 EXTENDED の結果の行（p1）。コメント欄は列コメントによらず `from deserializer`
/// （2026-09-27 実測 p1）
pub(super) fn column_extended(row: &[Value]) -> Vec<String> {
    vec![column_line_with(row, "from deserializer")]
}

/// 列指定 FORMATTED の結果の行（p2）。ColumnInfo は `COLUMN_INFO_NAMES` の 11 列
/// （2026-09-27 実測 p2）
pub(super) fn column_formatted(row: &[Value]) -> Vec<String> {
    // 先頭の見出しだけ `# ` 付き（`# col_name`。それも 20 桁詰めの外。2026-09-27 実測 p2）。
    let mut header: Vec<String> = COLUMN_INFO_NAMES.iter().map(|name| pad(name)).collect();
    header[0] = format!("# {}", header[0]);
    let blank = format!("\t{}", vec![" "; COLUMN_INFO_NAMES.len() - 1].join("\t"));
    let data = format!(
        "{}\t{}\t{}\t{}",
        pad(cell(row, 0)),
        pad(&type_spelling::hive(cell(row, 1))),
        vec![pad(""); COLUMN_INFO_NAMES.len() - 3].join("\t"),
        pad("from deserializer")
    );
    vec![header.join("\t"), blank, data]
}

/// PARTITION 指定 EXTENDED の結果の行（p3）。`values` は PARTITION の `(キー, 値)` の並び。
pub(super) fn partition_extended(
    rows: &[Vec<Value>],
    table: &Table,
    values: &[(String, String)],
) -> Vec<String> {
    let mut lines = describe_hive_rows(rows);
    lines.push("\t \t ".to_string());
    lines.push(format!(
        "Detailed Partition Information\t{}\t",
        partition_thrift(rows, table, values)
    ));
    lines
}

/// PARTITION 指定 FORMATTED の結果の行（p4）。`Detailed Partition Information` は
/// `Partition Value:`・`Database:`・`Table:`・`LastAccessTime:`・`Protect Mode:` だけを残す
/// （`CreateTime:`・`Location:`・`Partition Parameters:` の節は省く。2026-09-27 実測 p4）。
pub(super) fn partition_formatted(
    rows: &[Vec<Value>],
    table: &Table,
    values: &[(String, String)],
) -> Vec<String> {
    let mut lines = formatted_columns_block(rows);
    lines.push("\t \t ".to_string());
    lines.push(heading("# Detailed Partition Information"));
    lines.push(kv("Partition Value:", &format!("[{}]", value_list(values))));
    lines.push(kv("Database:", table.db));
    lines.push(kv("Table:", table.name));
    lines.push(kv("LastAccessTime:", "UNKNOWN"));
    lines.push(kv("Protect Mode:", "None"));
    lines.push("\t \t ".to_string());
    lines.push(heading("# Storage Information"));
    lines.push(kv("Compressed:", "No"));
    lines.push(kv("Bucket Columns:", "[]"));
    lines.push(kv("Sort Columns:", "[]"));
    lines
}

/// 見出しの行（`# ...\t \t `。2026-09-27 実測）。
fn heading(text: &str) -> String {
    format!("{text}\t \t ")
}

/// 見出し語欄・値欄とも 20 桁詰め、3 欄目は空白 1 個（2026-09-27 実測）。
fn kv(label: &str, value: &str) -> String {
    format!("{}\t{}\t ", pad(label), pad(value))
}

/// FORMATTED の列の行（20 桁詰め。パーティション列は上半分に出さない。見出し・空行の後に列、
/// パーティション付きなら `PARTITION_HEADER` の塊とパーティション列を続ける。2026-09-27 実測 f_h・f_hp）。
fn formatted_columns_block(rows: &[Vec<Value>]) -> Vec<String> {
    let mut lines = vec![
        PARTITION_HEADER[2].to_string(),
        PARTITION_HEADER[0].to_string(),
    ];
    lines.extend(
        rows.iter()
            .filter(|row| cell(row, 2) != "partition key")
            .map(|row| column_line(row)),
    );
    let partitions: Vec<String> = rows
        .iter()
        .filter(|row| cell(row, 2) == "partition key")
        .map(|row| column_line(row))
        .collect();
    if !partitions.is_empty() {
        lines.extend(PARTITION_HEADER.map(str::to_string));
        lines.extend(partitions);
    }
    lines
}

/// DESCRIBE の 1 行を、本物の Hive の行（`<列名>\t<型>\t<コメント>`、20 桁詰め）にする
/// （`utility_rows::describe_hive_rows` の内側の行の組み立てと同じ規則）。
fn column_line(row: &[Value]) -> String {
    format!(
        "{}\t{}\t{}",
        pad(cell(row, 0)),
        pad(&type_spelling::hive(cell(row, 1))),
        comment_field(cell(row, 3))
    )
}

/// `column_line` のコメント欄を固定の文字列に差し替えたもの（p1 の `from deserializer`。`column_extended` 用）。
fn column_line_with(row: &[Value], comment: &str) -> String {
    format!(
        "{}\t{}\t{}",
        pad(cell(row, 0)),
        pad(&type_spelling::hive(cell(row, 1))),
        pad(comment)
    )
}

/// `values:[x]`／`Partition Value: [x]` の中身。複数値の区切りは未実測で、Java の `List.toString`
/// に倣い `, ` にしている。
fn value_list(values: &[(String, String)]) -> String {
    values
        .iter()
        .map(|(_, value)| value.as_str())
        .collect::<Vec<_>>()
        .join(", ")
}

/// Table(...) の Thrift の 1 行。表の種類によらず同じだった対だけ残す（2026-09-27 実測 e_h・e_hp・e_v。
/// 省くのは owner・createTime・location・inputFormat・outputFormat・numBuckets・serdeInfo・skewedInfo・
/// 表の parameters・viewOriginalText・viewExpandedText）。
fn table_thrift(rows: &[Vec<Value>], table: &Table) -> String {
    let cols = field_schemas(rows);
    let partition_keys: Vec<&Vec<Value>> = rows
        .iter()
        .filter(|row| cell(row, 2) == "partition key")
        .collect();
    let partition_keys = field_schemas_of(partition_keys.into_iter());
    format!(
        "Table(tableName:{}, dbName:{}, lastAccessTime:0, retention:0, \
         sd:StorageDescriptor(cols:[{cols}], compressed:false, bucketCols:[], sortCols:[], \
         parameters:{{}}, storedAsSubDirectories:false), partitionKeys:[{partition_keys}], \
         tableType:{})",
        table.name,
        table.db,
        table.kind.thrift()
    )
}

/// Partition(...) の Thrift の 1 行。同じく残せる対だけ（2026-09-27 実測 p3）。
/// `sd.cols` のコメント欄は、パーティション列以外は空なら `comment:`（値が無ければ空文字。
/// 表の EXTENDED の `comment:null` と違う。生データどおり）、パーティション列は空なら
/// `comment:null`（生データどおり。#275 のノート参照。表の種類・作り方が増えたら要再確認）。
fn partition_thrift(rows: &[Vec<Value>], table: &Table, values: &[(String, String)]) -> String {
    let cols = rows
        .iter()
        .map(|row| {
            let comment = cell(row, 3);
            let comment = if !comment.is_empty() {
                comment.to_string()
            } else if cell(row, 2) == "partition key" {
                "null".to_string()
            } else {
                String::new()
            };
            format!(
                "FieldSchema(name:{}, type:{}, comment:{comment})",
                cell(row, 0),
                type_spelling::hive(cell(row, 1))
            )
        })
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "Partition(values:[{}], dbName:{}, tableName:{}, lastAccessTime:0, \
         sd:StorageDescriptor(cols:[{cols}], compressed:false, bucketCols:[], sortCols:[], \
         parameters:{{}}, storedAsSubDirectories:false))",
        value_list(values),
        table.db,
        table.name
    )
}

/// `rows` の全列を `FieldSchema(name:.., type:.., comment:..)` にし、`, ` で結ぶ
/// （コメント無しは `comment:null`。表レベルの Thrift の規則。2026-09-27 実測 e_h・e_hp・e_v）。
fn field_schemas(rows: &[Vec<Value>]) -> String {
    field_schemas_of(rows.iter())
}

fn field_schemas_of<'a>(rows: impl Iterator<Item = &'a Vec<Value>>) -> String {
    rows.map(|row| {
        let comment = cell(row, 3);
        let comment = if comment.is_empty() {
            "null".to_string()
        } else {
            comment.to_string()
        };
        format!(
            "FieldSchema(name:{}, type:{}, comment:{comment})",
            cell(row, 0),
            type_spelling::hive(cell(row, 1))
        )
    })
    .collect::<Vec<_>>()
    .join(", ")
}

#[cfg(test)]
mod tests;
