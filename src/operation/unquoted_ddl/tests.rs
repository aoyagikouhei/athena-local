//! unquoted_ddl.rs のユニットテスト。期待値は本物の実測（2026-09-26。#208、`tools/measure/unquoted-ddl.sh`）の
//! 文言の規則を、実名を伏せた短い名前（`t`・`db`・`cat`・`m`）に当て、位置を手で数え直したもの。

use super::*;

fn rejected(query: &str) -> Option<String> {
    rejection(query)
}

fn nv(position: &str, input: &str) -> Option<String> {
    Some(format!(
        "line {position}: no viable alternative at input '{input}'"
    ))
}

fn mm_expecting(position: &str, input: &str, expecting: &str) -> Option<String> {
    Some(format!(
        "line {position}: mismatched input '{input}'. Expecting: {expecting}"
    ))
}

fn mm_set(position: &str, input: &str, set: &str) -> Option<String> {
    Some(format!(
        "line {position}: mismatched input '{input}' expecting {set}"
    ))
}

fn missing(position: &str, input: &str) -> Option<String> {
    Some(format!("line {position}: missing 'TO' at '{input}'"))
}

#[test]
fn if_exists_の後ろが_add_drop_rename_なら_exists_の_no_viable_alternative() {
    let cases = [
        // 名前の部品数（1〜3）で変わらない（実測。位置も入力も EXISTS までで名前を含まない）。
        (
            "ALTER TABLE IF EXISTS t RENAME TO u",
            nv("1:16", "ALTER TABLE IF EXISTS"),
        ),
        (
            "ALTER TABLE IF EXISTS db.t RENAME TO u",
            nv("1:16", "ALTER TABLE IF EXISTS"),
        ),
        (
            "ALTER TABLE IF EXISTS cat.db.t RENAME TO u",
            nv("1:16", "ALTER TABLE IF EXISTS"),
        ),
        (
            "ALTER TABLE IF EXISTS t ADD COLUMN m int",
            nv("1:16", "ALTER TABLE IF EXISTS"),
        ),
        (
            "ALTER TABLE IF EXISTS t ADD COLUMN IF NOT EXISTS m int",
            nv("1:16", "ALTER TABLE IF EXISTS"),
        ),
        (
            "ALTER TABLE IF EXISTS t DROP COLUMN m",
            nv("1:16", "ALTER TABLE IF EXISTS"),
        ),
        (
            "ALTER TABLE IF EXISTS t DROP COLUMN IF EXISTS m",
            nv("1:16", "ALTER TABLE IF EXISTS"),
        ),
        (
            "ALTER TABLE IF EXISTS t RENAME COLUMN a TO b",
            nv("1:16", "ALTER TABLE IF EXISTS"),
        ),
        // IF EXISTS は引用符の有無によらず同じ規則（quoted_names.rs は IF EXISTS のとき常に None を返す）。
        (
            r#"ALTER TABLE IF EXISTS "t" RENAME TO u"#,
            nv("1:16", "ALTER TABLE IF EXISTS"),
        ),
    ];
    for (query, expected) in cases {
        assert_eq!(rejected(query), expected, "{query:?}");
    }
}

#[test]
fn if_exists_の変種は位置とトリビアの規則を保つ() {
    let cases = [
        (
            "alter table if exists t rename to u",
            nv("1:16", "alter table if exists"),
        ),
        (
            "/* c */ ALTER TABLE IF EXISTS t RENAME TO u",
            nv("1:24", "ALTER TABLE IF EXISTS"),
        ),
        (
            "ALTER TABLE\nIF EXISTS t RENAME TO u",
            nv("2:4", "ALTER TABLE\\nIF EXISTS"),
        ),
        (
            "ALTER TABLE  IF EXISTS t RENAME TO u",
            nv("1:17", "ALTER TABLE  IF EXISTS"),
        ),
        (
            "ALTER TABLE /* c */ IF EXISTS t RENAME TO u",
            nv("1:24", "ALTER TABLE /* c */ IF EXISTS"),
        ),
    ];
    for (query, expected) in cases {
        assert_eq!(rejected(query), expected, "{query:?}");
    }
}

#[test]
fn if_exists_の後ろが_alter_なら_2つ目の_alter_で_trino_形の_4_項目() {
    assert_eq!(
        rejected("ALTER TABLE IF EXISTS t ALTER COLUMN c SET DATA TYPE int"),
        mm_expecting("1:25", "ALTER", "'.', 'ADD', 'DROP', 'RENAME'")
    );
}

#[test]
fn if_exists_の後ろがそれ以外なら_none() {
    for query in [
        "ALTER TABLE IF EXISTS t SET PROPERTIES ('x' = 'y')",
        "ALTER TABLE IF EXISTS t SET AUTHORIZATION alice",
        "ALTER TABLE IF EXISTS t EXECUTE optimize",
        "ALTER TABLE IF EXISTS t COMMENT 'x'",
    ] {
        assert_eq!(rejected(query), None, "{query:?}");
    }
}

#[test]
fn add_column_単数は_column_の_no_viable_alternative() {
    let cases = [
        (
            "ALTER TABLE t ADD COLUMN m int",
            nv("1:19", "ALTER TABLE t ADD COLUMN"),
        ),
        (
            "ALTER TABLE db.t ADD COLUMN m int",
            nv("1:22", "ALTER TABLE db.t ADD COLUMN"),
        ),
        (
            "ALTER TABLE cat.db.t ADD COLUMN m int",
            nv("1:26", "ALTER TABLE cat.db.t ADD COLUMN"),
        ),
        (
            "alter table t add column m int",
            nv("1:19", "alter table t add column"),
        ),
        (
            "/* c */ ALTER TABLE t ADD COLUMN m int",
            nv("1:27", "ALTER TABLE t ADD COLUMN"),
        ),
        (
            "ALTER TABLE t ADD\nCOLUMN m int",
            nv("2:1", "ALTER TABLE t ADD\\nCOLUMN"),
        ),
        (
            "ALTER TABLE t ADD /* c */ COLUMN m int",
            nv("1:27", "ALTER TABLE t ADD /* c */ COLUMN"),
        ),
        (
            "ALTER TABLE t ADD  COLUMN m int",
            nv("1:20", "ALTER TABLE t ADD  COLUMN"),
        ),
        // 続く書き方（IF NOT EXISTS・COMMENT・型）は COLUMN の位置に影響しない。
        (
            "ALTER TABLE t ADD COLUMN IF NOT EXISTS m int",
            nv("1:19", "ALTER TABLE t ADD COLUMN"),
        ),
        (
            "ALTER TABLE t ADD COLUMN m int COMMENT 'x'",
            nv("1:19", "ALTER TABLE t ADD COLUMN"),
        ),
        (
            "ALTER TABLE t ADD COLUMN m varchar",
            nv("1:19", "ALTER TABLE t ADD COLUMN"),
        ),
    ];
    for (query, expected) in cases {
        assert_eq!(rejected(query), expected, "{query:?}");
    }
}

#[test]
fn add_columns_複数形は_column_に一致せず_none() {
    assert_eq!(rejected("ALTER TABLE t ADD COLUMNS (c varchar)"), None);
}

#[test]
fn rename_column_は_missing_to_at_column() {
    assert_eq!(
        rejected("ALTER TABLE t RENAME COLUMN a TO b"),
        missing("1:22", "COLUMN")
    );
}

#[test]
fn rename_to_は_none() {
    assert_eq!(rejected("ALTER TABLE t RENAME TO u"), None);
}

#[test]
fn set_properties_と_set_authorization_は_no_viable_alternative() {
    assert_eq!(
        rejected("ALTER TABLE t SET PROPERTIES ('x' = 'y')"),
        nv("1:19", "ALTER TABLE t SET PROPERTIES")
    );
    assert_eq!(
        rejected("ALTER TABLE t SET AUTHORIZATION alice"),
        nv("1:19", "ALTER TABLE t SET AUTHORIZATION")
    );
}

#[test]
fn set_それ以外は_none() {
    for query in [
        "ALTER TABLE t SET TBLPROPERTIES ('x' = 'y')",
        "ALTER TABLE t SET LOCATION 'x'",
    ] {
        assert_eq!(rejected(query), None, "{query:?}");
    }
}

#[test]
fn execute_は_no_viable_alternative() {
    assert_eq!(
        rejected("ALTER TABLE t EXECUTE optimize"),
        nv("1:15", "ALTER TABLE t EXECUTE")
    );
}

#[test]
fn alter_column_は_2つ目の_alter_で_trino_形の_6_項目() {
    assert_eq!(
        rejected("ALTER TABLE t ALTER COLUMN c SET DATA TYPE int"),
        mm_expecting(
            "1:15",
            "ALTER",
            "'.', 'ADD', 'DROP', 'EXECUTE', 'RENAME', 'SET'"
        )
    );
}

#[test]
fn drop_column_if_exists_は_exists_の_mismatched() {
    assert_eq!(
        rejected("ALTER TABLE t DROP COLUMN IF EXISTS m"),
        mm_set("1:30", "EXISTS", "{<EOF>, '.'}")
    );
}

#[test]
fn drop_column_は_if_exists_が無ければ弾かない() {
    // 対照（b19）: 本物は開始でき、実行時に FAILED になる。
    assert_eq!(rejected("ALTER TABLE t DROP COLUMN m"), None);
}

#[test]
fn alter_table_以外や名前が読めない形や_if_だけの形は_none() {
    for query in [
        "SELECT 1",
        "CREATE TABLE t (n int)",
        "ALTER TABLE .t RENAME TO u",
        "",
        "ALTER TABLE",
        // `IF` の直後に `EXISTS` が無ければ `table_name_start` ごと None になる。
        "ALTER TABLE IF t RENAME TO u",
    ] {
        assert_eq!(rejected(query), None, "{query:?}");
    }
}

#[test]
fn 引用符付きの名前は_if_exists_が無ければ_quoted_names_の担当なので_none() {
    for query in [
        r#"ALTER TABLE "t" ADD COLUMN m int"#,
        r#"ALTER TABLE "db"."t" ADD COLUMN m int"#,
        r#"ALTER TABLE db."t" ADD COLUMN m int"#,
    ] {
        assert_eq!(rejected(query), None, "{query:?}");
    }
}
