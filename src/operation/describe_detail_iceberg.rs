//! DESCRIBE FORMATTED の Iceberg の表の結果の行を組み立てる（#275 フェーズ 2）。
//! 既存の `utility_rows::describe_iceberg_rows` の行の後ろに、`Name:`・`Location:`・
//! `# Table properties:`・`# Iceberg storage table properties:` を足す（2026-09-27 実測 f_i）。
//! 取れない値（`location`・`format`・`write.format.default`）の行は省く（D1・D7）。
//! フェーズ 3（#275）で `background_execution::run` から配線するまで、まだどこからも呼ばない。
#![allow(dead_code)] // フェーズ 3（#275）で配線するまで

use serde_json::Value;

use super::type_spelling;
use super::utility_rows::{cell, describe_iceberg_rows};

/// Iceberg の DESCRIBE FORMATTED（f_i）。`name` は `Name:` に出す名前（`iceberg.<DB>.<t>` の形）、
/// `location` は Trino の `SHOW CREATE TABLE` の `location`、`format` は同じ `format`、
/// `write_format_default` は `"<t>$properties"` の `write.format.default`。
pub(super) fn formatted(
    rows: &[Vec<Value>],
    partitions: &[String],
    name: &str,
    location: Option<&str>,
    format: Option<&str>,
    write_format_default: Option<&str>,
) -> Vec<String> {
    let mut lines = describe_iceberg_rows(rows, partitions);
    lines.push("\t\t".to_string());
    lines.push(format!("Name:\t{name}\t"));
    if let Some(location) = location {
        lines.push(format!("Location:\t{location}\t"));
    }
    lines.push("\t\t".to_string());
    lines.push("# Table properties:\t\t".to_string());
    lines.push("# key\tvalue\t".to_string());
    if let Some(format) = format {
        lines.push(format!("format\t{format}\t"));
    }
    lines.push("\t\t".to_string());
    lines.push("# Iceberg storage table properties:\t\t".to_string());
    lines.push("# key\tvalue\t".to_string());
    if let Some(value) = write_format_default {
        lines.push(format!("write.format.default\t{value}\t"));
    }
    lines
}

/// Iceberg の列指定（p5）。詰めない。型は `type_spelling::iceberg`、コメントはそのまま
/// （2026-09-27 実測 p5）。
pub(super) fn column(row: &[Value]) -> Vec<String> {
    vec![format!(
        "{}\t{}\t{}",
        cell(row, 0),
        type_spelling::iceberg(cell(row, 1)),
        cell(row, 3)
    )]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(name: &str, type_name: &str, comment: &str) -> Vec<Value> {
        [name, type_name, "", comment].map(Value::from).into()
    }

    /// 本物の f_i（location・format・write.format.default とも取れる場合。2026-09-27 実測）と一致する。
    #[test]
    fn formatted_は_name_location_と_2_つの_properties_節を持つ() {
        let rows = [row("n", "integer", ""), row("p", "varchar", "")];
        let partitions = ["p".to_string()];
        let expected = [
            "# Table schema:\t\t",
            "# col_name\tdata_type\tcomment",
            "n\tint\t",
            "p\tstring\t",
            "\t\t",
            "# Partition spec:\t\t",
            "# field_name\tfield_transform\tcolumn_name",
            "p\tidentity\tp",
            "\t\t",
            "Name:\ticeberg.db.t\t",
            "Location:\ts3://bucket/prefix\t",
            "\t\t",
            "# Table properties:\t\t",
            "# key\tvalue\t",
            "format\tPARQUET\t",
            "\t\t",
            "# Iceberg storage table properties:\t\t",
            "# key\tvalue\t",
            "write.format.default\tPARQUET\t",
        ];
        assert_eq!(
            formatted(
                &rows,
                &partitions,
                "iceberg.db.t",
                Some("s3://bucket/prefix"),
                Some("PARQUET"),
                Some("PARQUET"),
            ),
            expected
        );
    }

    /// `location` が取れなければ `Location:` の行を省く。
    #[test]
    fn formatted_は_location_が無ければ行を省く() {
        let rows = [row("n", "integer", "")];
        let out = formatted(
            &rows,
            &[],
            "iceberg.db.t",
            None,
            Some("PARQUET"),
            Some("PARQUET"),
        );
        assert!(!out.iter().any(|line| line.starts_with("Location:")));
        assert!(out.iter().any(|line| line == "Name:\ticeberg.db.t\t"));
    }

    /// `"<t>$properties"` に `write.format.default` が無ければ、その行だけ省き見出しは残す。
    #[test]
    fn formatted_は_properties_に無ければ_write_format_default_の行だけ省く() {
        let rows = [row("n", "integer", "")];
        let out = formatted(&rows, &[], "iceberg.db.t", None, Some("PARQUET"), None);
        assert!(
            out.iter()
                .any(|line| line == "# Iceberg storage table properties:\t\t")
        );
        assert!(
            !out.iter()
                .any(|line| line.starts_with("write.format.default"))
        );
    }

    /// 本物の p5（2026-09-27 実測）と一致する。
    #[test]
    fn column_は_1_行() {
        let r = row("n", "integer", "");
        assert_eq!(column(&r), ["n\tint\t"]);
    }

    /// 列コメントはそのまま出す。
    #[test]
    fn column_は列コメントをそのまま出す() {
        let r = row("n", "integer", "note");
        assert_eq!(column(&r), ["n\tint\tnote"]);
    }
}
