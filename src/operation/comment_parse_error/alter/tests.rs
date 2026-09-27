//! `alter`（ADD COLUMNS・DROP COLUMN・RENAME TO）のテスト。親の `comment_parse_error::tests` から
//! 切り出したもの（挙動を変えない移動。#257）。値の出どころは `comment_parse_error/tests.rs` のモジュール冒頭コメント参照。

use super::super::*;

/// `comment_parse_error::tests::parse_exception` と同じ内容(複製。#257 フェーズ 0 の一致台帳)。
fn parse_exception(target: Target, reason: &str) -> ParseError {
    ParseError {
        target,
        reason: reason.to_string(),
        error_message: None,
        category: 1,
        error_type: 1003,
    }
}

fn rename_error(reason: &str) -> ParseError {
    ParseError {
        target: Target::AlterRename,
        reason: reason.to_string(),
        error_message: Some("Query type not supported by DDL engine.".to_string()),
        category: 2,
        error_type: 1006,
    }
}

fn drop_column_error(reason: &str, message: &str) -> ParseError {
    ParseError {
        target: Target::AlterDropColumn,
        reason: reason.to_string(),
        error_message: Some(message.to_string()),
        category: 2,
        error_type: 1006,
    }
}

#[test]
fn alter_table_add_columns_の_3_つのチェックポイント() {
    for (ids, sql, reason) in [
        // 先頭（a12。n10 も同じ形）。
        (
            "a12",
            "/* c */ ALTER TABLE db.t ADD COLUMNS (c int)",
            "FAILED: ParseException line 1:0 cannot recognize input near '/' '*' 'c'",
        ),
        // ALTER の後（a2。a3・a4・a14 も同じ形）。
        (
            "a2",
            "ALTER /* c */ TABLE db.t ADD COLUMNS (c int)",
            "FAILED: ParseException line 1:0 cannot recognize input near 'ALTER' '/' '*' in alter statement",
        ),
        // ALTER の後・小文字（a5）。
        (
            "a5",
            "alter /* c */ table db.t add columns (c int)",
            "FAILED: ParseException line 1:0 cannot recognize input near 'alter' '/' '*' in alter statement",
        ),
        // ALTER の後・空白 2 つでも 1:0 のまま（a6。「ALTER 自身の位置」であってコメントの位置ではない）。
        (
            "a6",
            "ALTER  /* c */ TABLE db.t ADD COLUMNS (c int)",
            "FAILED: ParseException line 1:0 cannot recognize input near 'ALTER' '/' '*' in alter statement",
        ),
        // ALTER の後・改行でも 1:0 のまま（a7。D5 の要）。
        (
            "a7",
            "ALTER\n/* c */ TABLE db.t ADD COLUMNS (c int)",
            "FAILED: ParseException line 1:0 cannot recognize input near 'ALTER' '/' '*' in alter statement",
        ),
        // 名前の直前（TABLE の後。a13。n11・n13・p9・p10 も同じ形）。
        (
            "a13",
            "ALTER TABLE /* c */ db.t ADD COLUMNS (c int)",
            "FAILED: ParseException line 1:12 cannot recognize input near '/' '*' 'c' in table name",
        ),
        // TABLE の後・ALTER と TABLE の間に空白 2 つがあっても 1:12（p10）。
        (
            "p10",
            "ALTER  TABLE /* c */ db.t ADD COLUMNS (c int)",
            "FAILED: ParseException line 1:12 cannot recognize input near '/' '*' 'c' in table name",
        ),
    ] {
        assert_eq!(
            detect(sql),
            Some(parse_exception(Target::AlterAddColumns, reason)),
            "{ids}: {sql}"
        );
    }
}

#[test]
fn alter_table_rename_to_は_category_2_error_type_1006_で_error_message_が固定文言() {
    for (ids, sql, reason) in [
        // 先頭（n3）。
        (
            "n3",
            "/* c */ ALTER TABLE db.t RENAME TO db.t2",
            "FAILED: ParseException line 1:0 cannot recognize input near '/' '*' 'c'",
        ),
        // ALTER の後（a11・n1・n2 も同じ形）。
        (
            "a11",
            "ALTER /* c */ TABLE db.t RENAME TO db.t2",
            "FAILED: ParseException line 1:0 cannot recognize input near 'ALTER' '/' '*' in alter statement",
        ),
        // 名前の直前（n4）。
        (
            "n4",
            "ALTER TABLE /* c */ db.t RENAME TO db.t2",
            "FAILED: ParseException line 1:12 cannot recognize input near '/' '*' 'c' in table name",
        ),
    ] {
        assert_eq!(detect(sql), Some(rename_error(reason)), "{ids}: {sql}");
    }
}

#[test]
fn alter_table_drop_column_は_category_2_error_type_1006_で_error_message_に_column_の位置() {
    // ErrorMessage の `line 1:31` は `db.t`・`DROP COLUMN c`（1 文字の列名）で計算し直した値
    // （実測は n5・n9・n6・n7 で `line 1:64`〜`1:70`。名前の長さが違うだけで式は同じ。
    // `.claude/issue-notes/244.md` の D5・「実測の結果」節参照）。
    for (ids, sql, reason, message) in [
        // 先頭（n5）。
        (
            "n5",
            "/* c */ ALTER TABLE db.t DROP COLUMN c",
            "FAILED: ParseException line 1:0 cannot recognize input near '/' '*' 'c'",
            "line 1:31: mismatched input 'COLUMN' expecting 'PARTITION'",
        ),
        // ALTER の後・空白 2 つでも 1:0（n9 と同じ形。実測 n9 は `line 1:70`＝この置き換えでは 31）。
        (
            "n9",
            "ALTER  /* c */ TABLE db.t DROP COLUMN c",
            "FAILED: ParseException line 1:0 cannot recognize input near 'ALTER' '/' '*' in alter statement",
            "line 1:31: mismatched input 'COLUMN' expecting 'PARTITION'",
        ),
        // 名前の直前（n6）。
        (
            "n6",
            "ALTER TABLE /* c */ db.t DROP COLUMN c",
            "FAILED: ParseException line 1:12 cannot recognize input near '/' '*' 'c' in table name",
            "line 1:31: mismatched input 'COLUMN' expecting 'PARTITION'",
        ),
        // ALTER の後・小文字（n7 と同じ形。実測 n7 は `line 1:64`＝この置き換えでは 31、
        // `column` も書いた綴りのまま小文字）。
        (
            "n7",
            "alter /* c */ table db.t drop column n",
            "FAILED: ParseException line 1:0 cannot recognize input near 'alter' '/' '*' in alter statement",
            "line 1:31: mismatched input 'column' expecting 'PARTITION'",
        ),
    ] {
        assert_eq!(
            detect(sql),
            Some(drop_column_error(reason, message)),
            "{ids}: {sql}"
        );
    }
}

#[test]
fn 対象外の_alter_の動作は_none_に固定する() {
    for (ids, sql) in [
        // ADD PARTITION・DROP PARTITION・SET TBLPROPERTIES は本物で成功する（実測 a8〜a10）。
        ("a8", "ALTER /* c */ TABLE db.t ADD PARTITION (p='x')"),
        ("a9", "ALTER /* c */ TABLE db.t DROP PARTITION (p='x')"),
        (
            "a10",
            "ALTER /* c */ TABLE db.t SET TBLPROPERTIES ('k'='v')",
        ),
        // 単数形の `ADD COLUMN` は Trino だけの綴りで、本物は開始時に弾く（D1。未実測）。
        (
            "単数の ADD COLUMN（未実測。D1 の設計判断）",
            "ALTER /* c */ TABLE db.t ADD COLUMN (c int)",
        ),
        // `IF EXISTS` を含む ALTER は本物が開始時に弾く（未実測。D1）。
        (
            "IF EXISTS を含む ALTER（未実測。D1 の設計判断）",
            "ALTER /* c */ TABLE IF EXISTS db.t ADD COLUMNS (c int)",
        ),
    ] {
        assert_eq!(detect(sql), None, "{ids}: {sql}");
    }
}
