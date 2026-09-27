//! utility_rows.rs のユニットテスト（結合テストは tests/describe.rs）。

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

#[test]
fn reshape_はビューへの_describe_と_show_columns_を_column_と_type_の_varchar_の_2_列にする() {
    // 本物はビューへの DESCRIBE と SHOW COLUMNS を同じ形で返す（2026-09-24 実測 d5。#173）。
    // 型は Trino の綴りのまま、詰めない。コメントは出さない。
    let trino_view = || Outcome {
        rows: vec![
            describe_row("n", "integer", "", "abc"),
            describe_row("s", "varchar(1)", "", ""),
        ],
        ..trino_show_columns()
    };
    for query in ["DESCRIBE v", "DESC v", "SHOW COLUMNS FROM v"] {
        let outcome = reshape(query, trino_view(), Some(TableFormat::View), &[]);
        let columns: Vec<(&str, &str)> = outcome
            .columns
            .iter()
            .map(|c| (c.name.as_str(), c.type_name.as_str()))
            .collect();
        assert_eq!(
            columns,
            [("column", "varchar"), ("type", "varchar")],
            "{query}"
        );
        assert_eq!(
            outcome.rows,
            [[Value::from("n\tinteger")], [Value::from("s\tvarchar(1)")]],
            "{query}"
        );
        let infos = outcome.athena_columns.expect("作り直した ColumnInfo");
        let names: Vec<&str> = infos.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, ["column", "type"], "{query}");
        for info in &infos {
            assert_eq!(info.label, info.name);
            assert_eq!(info.type_name, "varchar");
            assert_eq!((info.precision, info.scale), (0, 0));
            assert!(!info.case_sensitive);
            assert_eq!(info.catalog_name, "hive");
            assert_eq!(info.nullable, "UNKNOWN");
        }
        assert_eq!(outcome.id.as_deref(), Some("engine"));
    }
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

/// 本物が DESCRIBE で失敗にしたのは最上位の `time`・`uuid` の列（2026-09-27 実測 dci_time・dci_uuid。#307）。
/// 成功した timestamp with time zone（dci_tstz）と、測っていない入れ子・`time with time zone` は当てない。
#[test]
fn has_unsupported_iceberg_column_は最上位の_time_と_uuid_だけを見る() {
    let row = |column_type: &str| {
        vec![
            Value::from("c"),
            Value::from(column_type),
            Value::from(""),
            Value::from(""),
        ]
    };
    for column_type in ["time(6)", "time(3)", "uuid"] {
        assert!(
            has_unsupported_iceberg_column(&[trino_row("n"), row(column_type)]),
            "{column_type}"
        );
    }
    for column_type in [
        "timestamp(6) with time zone",
        "timestamp(6)",
        "time(6) with time zone",
        "array(uuid)",
        r#"row("a" time(6))"#,
        "varchar",
    ] {
        assert!(
            !has_unsupported_iceberg_column(&[trino_row("n"), row(column_type)]),
            "{column_type}"
        );
    }
    assert!(!has_unsupported_iceberg_column(&[]));
}
