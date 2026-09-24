//! SHOW COLUMNS／DESCRIBE の Trino の結果を、本物の列と 1 値の行に作り直す（#173）。
//! 本物はこれらの文を Trino と違う列数・行の形で返すので、`classification::fixed_column` の
//! 列名の差し替えだけでは揃わない。完了時に `Outcome` の列と行を作り直し、GetQueryResults・
//! `.txt`・`.metadata` に同じ値を渡す（`execution::split_explain_rows` と同じ置き場）。
//! DESCRIBE は Hive のテーブル（と形式が判定できないとき）と Iceberg のテーブルで行の形が違う。

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
/// （2026-09-24 実測 d2・d8）。`update_count`・`id`・`update_type` は触らない。ほかの文はそのまま返す。
pub(super) fn reshape(
    query: &str,
    outcome: Outcome,
    format: Option<TableFormat>,
    partitions: &[String],
) -> Outcome {
    match super::classification::substatement_type(query) {
        Some("SHOW_COLUMNS") => {
            let rows = show_columns_rows(&outcome.rows, format);
            replace(outcome, &["field"], rows)
        }
        Some("DESCRIBE_TABLE") => {
            let rows = if format == Some(TableFormat::Iceberg) {
                describe_iceberg_rows(&outcome.rows, partitions)
            } else {
                describe_hive_rows(&outcome.rows)
            };
            replace(outcome, &["col_name", "data_type", "comment"], rows)
        }
        _ => outcome,
    }
}

/// 列を `names` の string の列（Precision・Scale 0、CaseSensitive false）に、行を 1 値の行に置き換える。
fn replace(mut outcome: Outcome, names: &[&str], rows: Vec<String>) -> Outcome {
    outcome.rows = rows
        .into_iter()
        .map(|text| vec![Value::from(text)])
        .collect();
    outcome.columns = names
        .iter()
        .map(|name| Column {
            name: name.to_string(),
            type_name: "string".to_string(),
            type_signature: None,
        })
        .collect();
    outcome.athena_columns = Some(
        names
            .iter()
            .map(|name| ColumnInfo {
                name: name.to_string(),
                label: name.to_string(),
                type_name: "string".to_string(),
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
            &[],
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
    fn reshape_は_show_columns_と_describe_以外の文をそのまま返す() {
        let outcome = reshape(
            "SELECT 1",
            trino_show_columns(),
            Some(TableFormat::Hive),
            &[],
        );
        assert_eq!(outcome.columns.len(), 4);
        assert_eq!(outcome.rows, [trino_row("n")]);
        assert!(outcome.athena_columns.is_none());
    }

    /// Trino の DESCRIBE の 1 行（`Column`／`Type`／`Extra`／`Comment`）。
    fn describe_row(name: &str, type_name: &str, extra: &str, comment: &str) -> Vec<Value> {
        [name, type_name, extra, comment].map(Value::from).into()
    }

    /// 本物の d1-main（Hive、型 17 種・列名 19／20／21 文字・コメント 4 種・パーティション列 3 つ）の
    /// DESCRIBE の 34 行を、Trino 482 の DESCRIBE の形の入力から組む。
    /// 採取元: ~/athena-unmeasured-batch-measurements/run-20260924-115811/d1/d1-main-describe.results-1.json
    /// （2026-09-24 実測。#173）。
    #[test]
    fn describe_hive_rows_は本物の_d1_main_の_34_行と一致する() {
        let rows = [
            describe_row("c19_aaaaaaaaaaaaaaa", "integer", "", ""),
            describe_row("c20_aaaaaaaaaaaaaaaa", "integer", "", ""),
            describe_row("c21_aaaaaaaaaaaaaaaaa", "integer", "", ""),
            describe_row("t_bigint", "bigint", "", ""),
            describe_row("t_smallint", "smallint", "", ""),
            describe_row("t_tinyint", "tinyint", "", ""),
            describe_row("t_double", "double", "", ""),
            describe_row("t_float", "real", "", ""),
            describe_row("t_boolean", "boolean", "", ""),
            describe_row("t_date", "date", "", ""),
            describe_row("t_decimal", "decimal(10,2)", "", ""),
            describe_row("t_varchar", "varchar(10)", "", ""),
            describe_row("t_char", "char(36)", "", ""),
            describe_row("t_string", "varchar", "", ""),
            describe_row("t_timestamp", "timestamp(3)", "", ""),
            describe_row("t_binary", "varbinary", "", ""),
            describe_row("t_array", "array(varchar)", "", ""),
            describe_row("t_map", "map(varchar, integer)", "", ""),
            describe_row("t_struct20", r#"row("aa" integer, "b" integer)"#, "", ""),
            describe_row("t_struct21", r#"row("aa" integer, "bb" integer)"#, "", ""),
            describe_row("m_none", "integer", "", ""),
            describe_row("m_abc", "integer", "", "abc"),
            describe_row("m_c20", "integer", "", "cmt20_bbbbbbbbbbbbbb"),
            describe_row("m_c21", "integer", "", "cmt21_bbbbbbbbbbbbbbb"),
            describe_row("p", "varchar", "partition key", "pc"),
            describe_row("q", "integer", "partition key", ""),
            describe_row("p21_aaaaaaaaaaaaaaaaa", "varchar", "partition key", ""),
        ];
        let expected = [
            "c19_aaaaaaaaaaaaaaa \tint                 \t                    ",
            "c20_aaaaaaaaaaaaaaaa\tint                 \t                    ",
            "c21_aaaaaaaaaaaaaaaaa\tint                 \t                    ",
            "t_bigint            \tbigint              \t                    ",
            "t_smallint          \tsmallint            \t                    ",
            "t_tinyint           \ttinyint             \t                    ",
            "t_double            \tdouble              \t                    ",
            "t_float             \tfloat               \t                    ",
            "t_boolean           \tboolean             \t                    ",
            "t_date              \tdate                \t                    ",
            "t_decimal           \tdecimal(10,2)       \t                    ",
            "t_varchar           \tvarchar(10)         \t                    ",
            "t_char              \tchar(36)            \t                    ",
            "t_string            \tstring              \t                    ",
            "t_timestamp         \ttimestamp           \t                    ",
            "t_binary            \tbinary              \t                    ",
            "t_array             \tarray<string>       \t                    ",
            "t_map               \tmap<string,int>     \t                    ",
            "t_struct20          \tstruct<aa:int,b:int>\t                    ",
            "t_struct21          \tstruct<aa:int,bb:int>\t                    ",
            "m_none              \tint                 \t                    ",
            "m_abc               \tint                 \tabc                 ",
            "m_c20               \tint                 \tcmt20_bbbbbbbbbbbbbb",
            "m_c21               \tint                 \tcmt21_bbbbbbbbbbbbbbb",
            "p                   \tstring              \tpc                  ",
            "q                   \tint                 \t                    ",
            "p21_aaaaaaaaaaaaaaaaa\tstring              \t                    ",
            "\t \t ",
            "# Partition Information\t \t ",
            "# col_name            \tdata_type           \tcomment             ",
            "\t \t ",
            "p                   \tstring              \tpc                  ",
            "q                   \tint                 \t                    ",
            "p21_aaaaaaaaaaaaaaaaa\tstring              \t                    ",
        ];
        let actual = describe_hive_rows(&rows);
        assert_eq!(actual.len(), expected.len());
        for (index, (actual, expected)) in actual.iter().zip(expected).enumerate() {
            assert_eq!(actual, expected, "{} 行目", index + 1);
        }
    }

    /// 幅は文字数で数える（`列名` は空白 18 個、`コメント` は空白 16 個。本体 137 バイトで検算。
    /// 採取元: run-20260924-115811/d1/d1-nonascii-describe.results-1.json。2026-09-24 実測）。
    /// パーティション列が無ければ見出し行群は付かない。
    #[test]
    fn describe_hive_rows_は非_ascii_の名前とコメントを文字数で詰め_パーティションが無ければ見出しを付けない()
     {
        let rows = [
            describe_row("列名", "integer", "", "コメント"),
            describe_row("n", "integer", "", ""),
        ];
        assert_eq!(
            describe_hive_rows(&rows),
            [
                "列名                  \tint                 \tコメント                ",
                "n                   \tint                 \t                    ",
            ]
        );
    }

    /// コメントは 20 桁に詰めてから、先頭のタブまでを取る（2026-09-24 実測 d1、#146 の `a\tb` → `a`）。
    #[test]
    fn comment_field_は空なら空白_20_個で_詰めた後の先頭のタブまでを取る() {
        assert_eq!(comment_field(""), " ".repeat(20));
        assert_eq!(comment_field("abc"), format!("abc{}", " ".repeat(17)));
        assert_eq!(comment_field("a\tb"), "a");
    }

    #[test]
    fn reshape_は_hive_と判定できないときの_describe_を_3_列と_1_値の行に作り直し_iceberg_は素通しする()
     {
        let trino_describe = || Outcome {
            rows: vec![describe_row("n", "integer", "", "")],
            ..trino_show_columns()
        };
        let row = format!(
            "n{}\tint{}\t{}",
            " ".repeat(19),
            " ".repeat(17),
            " ".repeat(20)
        );
        for format in [Some(TableFormat::Hive), None] {
            let outcome = reshape("DESCRIBE t", trino_describe(), format, &[]);
            let names: Vec<&str> = outcome.columns.iter().map(|c| c.name.as_str()).collect();
            assert_eq!(names, ["col_name", "data_type", "comment"], "{format:?}");
            assert!(
                outcome
                    .columns
                    .iter()
                    .all(|c| c.type_name == "string" && c.type_signature.is_none())
            );
            assert_eq!(outcome.rows, [[Value::from(row.clone())]], "{format:?}");
            let infos = outcome.athena_columns.expect("作り直した ColumnInfo");
            let names: Vec<&str> = infos.iter().map(|c| c.name.as_str()).collect();
            assert_eq!(names, ["col_name", "data_type", "comment"]);
            for info in &infos {
                assert_eq!(info.label, info.name);
                assert_eq!(info.type_name, "string");
                assert_eq!((info.precision, info.scale), (0, 0));
                assert!(!info.case_sensitive);
                assert_eq!(info.catalog_name, "hive");
                assert_eq!(info.nullable, "UNKNOWN");
            }
            assert_eq!(outcome.id.as_deref(), Some("engine"));
        }

        // Iceberg の DESCRIBE も同じ 3 列にし、行は詰めない（2026-09-24 実測 d2。#173）。
        let outcome = reshape(
            "DESCRIBE t",
            trino_describe(),
            Some(TableFormat::Iceberg),
            &["n".to_string()],
        );
        let names: Vec<&str> = outcome.columns.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, ["col_name", "data_type", "comment"]);
        let rows: Vec<Value> = [
            "# Table schema:\t\t",
            "# col_name\tdata_type\tcomment",
            "n\tint\t",
            "\t\t",
            "# Partition spec:\t\t",
            "# field_name\tfield_transform\tcolumn_name",
            "n\tidentity\tn",
        ]
        .map(Value::from)
        .into();
        assert_eq!(
            outcome.rows,
            rows.into_iter().map(|row| vec![row]).collect::<Vec<_>>()
        );
        assert_eq!(outcome.athena_columns.map(|infos| infos.len()), Some(3));
    }

    /// 本物の d8（Iceberg、型 11 種・変換 4 種）の DESCRIBE の 20 行を、Trino 482 の DESCRIBE の形の入力と
    /// `SHOW CREATE TABLE` の `partitioning` の要素から組む。
    /// 採取元: ~/athena-unmeasured-batch-measurements/run-20260924-122125/d8/d8-describe.results-1.json
    /// （2026-09-24 実測。#173）。
    #[test]
    fn describe_iceberg_rows_は本物の_d8_の_20_行と一致する() {
        let rows = [
            describe_row("n", "integer", "", ""),
            describe_row("s", "varchar", "", ""),
            describe_row("ts", "timestamp(6)", "", ""),
            describe_row("d2", "date", "", ""),
            describe_row("ts2", "timestamp(6)", "", ""),
            describe_row("t_double", "double", "", ""),
            describe_row("t_float", "real", "", ""),
            describe_row("t_boolean", "boolean", "", ""),
            describe_row("t_binary", "varbinary", "", ""),
            describe_row("t_map", "map(varchar, integer)", "", ""),
            describe_row("big", "bigint", "", ""),
        ];
        let partitions = ["year(ts)", "month(d2)", "hour(ts2)", "truncate(s, 3)"].map(String::from);
        let expected = [
            "# Table schema:\t\t",
            "# col_name\tdata_type\tcomment",
            "n\tint\t",
            "s\tstring\t",
            "ts\ttimestamp\t",
            "d2\tdate\t",
            "ts2\ttimestamp\t",
            "t_double\tdouble\t",
            "t_float\tfloat\t",
            "t_boolean\tboolean\t",
            "t_binary\tbinary\t",
            "t_map\tmap<string, int>\t",
            "big\tbigint\t",
            "\t\t",
            "# Partition spec:\t\t",
            "# field_name\tfield_transform\tcolumn_name",
            "ts_year\tyear\tts",
            "d2_month\tmonth\td2",
            "ts2_hour\thour\tts2",
            "s_trunc\ttruncate[3]\ts",
        ];
        let actual = describe_iceberg_rows(&rows, &partitions);
        assert_eq!(actual.len(), expected.len());
        for (index, (actual, expected)) in actual.iter().zip(expected).enumerate() {
            assert_eq!(actual, expected, "{} 行目", index + 1);
        }
    }

    /// コメントは詰めずにそのまま、パーティションが無ければ見出しまで、測っていない変換の行は出さない。
    #[test]
    fn describe_iceberg_rows_はコメントをそのまま置き_パーティションが無ければ見出しまで() {
        let rows = [
            describe_row("n", "integer", "", "abc"),
            describe_row("s", "varchar", "", ""),
        ];
        let head = [
            "# Table schema:\t\t",
            "# col_name\tdata_type\tcomment",
            "n\tint\tabc",
            "s\tstring\t",
            "\t\t",
            "# Partition spec:\t\t",
            "# field_name\tfield_transform\tcolumn_name",
        ];
        assert_eq!(describe_iceberg_rows(&rows, &[]), head);
        assert_eq!(describe_iceberg_rows(&rows, &["void(s)".to_string()]), head);
    }
}
