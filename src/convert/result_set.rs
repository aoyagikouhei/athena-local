//! Outcome から Athena の ResultSet を組み立てる入口。行と列情報の両方をここから配る。

use crate::athena::{ColumnInfo, Datum, ResultSet, ResultSetMetadata, Row};
use crate::trino::Outcome;

/// SELECT の 1 ページ目の先頭行は列名（本物の Athena と同じ）。
/// ページングできるよう、ヘッダ行込みの一覧をまとめて作る。
pub fn all_rows(outcome: &Outcome) -> Vec<Vec<Option<String>>> {
    // DML と CTAS は行を返さず UpdateCount だけ。列の無い DDL（Trino は columns: [] を返す）も行を返さない。
    if outcome.update_count.is_some() || outcome.columns.is_empty() {
        return Vec::new();
    }

    let header = outcome
        .columns
        .iter()
        .map(|column| Some(column.name.clone()))
        .collect();

    let mut rows = vec![header];
    rows.extend(outcome.rows.iter().map(|row| {
        row.iter()
            .enumerate()
            .map(|(index, value)| {
                let signature = outcome
                    .columns
                    .get(index)
                    .and_then(|column| column.type_signature.as_ref());
                super::render::to_var_char_value(value, signature)
            })
            .collect()
    }));

    rows
}

pub fn result_set(
    outcome: &Outcome,
    rows: &[Vec<Option<String>>],
    fixed_column: Option<(&str, &str)>,
) -> ResultSet {
    // DML と CTAS でも Trino の列（rows bigint）をそのまま載せる。本物の Athena も同じ列を返す
    // （Hive 形式と Iceberg の INSERT / UPDATE / MERGE / DELETE / CTAS で 2026-09-14 に実測）。
    ResultSet {
        rows: rows.iter().map(|row| to_row(row)).collect(),
        result_set_metadata: ResultSetMetadata {
            column_info: column_infos(outcome, fixed_column),
        },
    }
}

/// Trino の列から Athena の ColumnInfo を作る唯一の入口。
/// GetQueryResults の ResultSetMetadata も結果の `.metadata` もここを通す。
/// `fixed_column` は本物が Trino の列によらず固定の列名・型で返す文（SHOW CREATE TABLE / VIEW）の
/// 列名と型名で、あれば全列をその名前・型に置き換え、Precision・Scale は 0、CaseSensitive は false にする
/// （`operation::classification::fixed_column`。2026-09-23／24 実測。#161）。
/// 完了時に列を作り直した文（SHOW COLUMNS など）は `outcome.athena_columns` を優先し、
/// `fixed_column` も当てない（`operation::utility_rows::reshape`。#173）。
pub fn column_infos(outcome: &Outcome, fixed_column: Option<(&str, &str)>) -> Vec<ColumnInfo> {
    if let Some(columns) = &outcome.athena_columns {
        return columns.clone();
    }
    outcome
        .columns
        .iter()
        .map(|column| {
            let mut info = super::athena_type::to_column_info(column);
            if let Some((name, type_name)) = fixed_column {
                info.name = name.to_string();
                info.label = name.to_string();
                info.type_name = type_name.to_string();
                info.precision = 0;
                info.scale = 0;
                info.case_sensitive = false;
            }
            info
        })
        .collect()
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

#[cfg(test)]
mod tests {
    use serde_json::Value;

    use super::*;

    const INTEGER: &str = r#"{"rawType":"integer","arguments":[]}"#;

    fn array_of(element: &str) -> String {
        format!(r#"{{"rawType":"array","arguments":[{{"kind":"TYPE","value":{element}}}]}}"#)
    }

    #[test]
    fn 列ごとに自分の型で書く() {
        use crate::trino::Column;

        let signature = |text: &str| Some(serde_json::from_str(text).unwrap());
        let outcome = Outcome {
            columns: vec![
                Column {
                    name: "name".to_string(),
                    type_name: "varchar".to_string(),
                    type_signature: signature(
                        r#"{"rawType":"varchar","arguments":[{"kind":"LONG","value":2147483647}]}"#,
                    ),
                },
                Column {
                    name: "counts".to_string(),
                    type_name: "array(integer)".to_string(),
                    type_signature: signature(&array_of(INTEGER)),
                },
            ],
            rows: vec![vec![
                Value::from("x"),
                serde_json::from_str("[1,2]").unwrap(),
            ]],
            ..Outcome::default()
        };

        assert_eq!(
            all_rows(&outcome),
            [
                [Some("name".to_string()), Some("counts".to_string())],
                [Some("x".to_string()), Some("[1, 2]".to_string())],
            ]
        );
    }

    #[test]
    fn 固定の列名と型があれば_trino_の列をその名前と型に置き換える() {
        use crate::trino::Column;

        // SHOW CREATE TABLE の Trino の列（`Create Table` varchar）は本物では `createtab_stmt` string、
        // Precision 0、CaseSensitive false（2026-09-23 実測。#161）。
        let outcome = Outcome {
            columns: vec![Column {
                name: "Create Table".to_string(),
                type_name: "varchar".to_string(),
                type_signature: None,
            }],
            ..Outcome::default()
        };

        let fixed = column_infos(&outcome, Some(("createtab_stmt", "string")));
        assert_eq!(fixed.len(), 1);
        assert_eq!(fixed[0].name, "createtab_stmt");
        assert_eq!(fixed[0].label, "createtab_stmt");
        assert_eq!(fixed[0].type_name, "string");
        assert_eq!(fixed[0].precision, 0);
        assert!(!fixed[0].case_sensitive);

        let plain = column_infos(&outcome, None);
        assert_eq!(plain[0].name, "Create Table");
        assert_eq!(plain[0].type_name, "varchar");
        assert!(plain[0].case_sensitive);
    }

    #[test]
    fn 作り直した列情報があれば_trino_の列と固定の列より優先する() {
        use crate::trino::Column;

        // SHOW COLUMNS は完了時に `field`／string の 1 列へ作り直す（#173）。
        let mut outcome = Outcome {
            columns: vec![Column {
                name: "Column".to_string(),
                type_name: "varchar".to_string(),
                type_signature: None,
            }],
            ..Outcome::default()
        };
        let mut field = super::super::athena_type::to_column_info(&outcome.columns[0]);
        field.name = "field".to_string();
        field.type_name = "string".to_string();
        outcome.athena_columns = Some(vec![field]);

        let infos = column_infos(&outcome, Some(("createtab_stmt", "string")));
        assert_eq!(infos.len(), 1);
        assert_eq!(infos[0].name, "field");
        // 作り直した値をそのまま使い、固定の列の Precision 0 などを当てない。
        assert_eq!(infos[0].label, "Column");
        assert!(infos[0].case_sensitive);

        outcome.athena_columns = None;
        assert_eq!(column_infos(&outcome, None)[0].name, "Column");
    }

    #[test]
    fn 列の無い結果は列名行も作らない() {
        // Trino は CREATE TABLE / DROP TABLE に columns: [] を返す。本物の Athena の Rows は空。
        assert!(all_rows(&Outcome::default()).is_empty());
    }
}
