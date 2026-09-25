//! quoted_names.rs のユニットテスト。期待値は本物の実測（2026-09-25。#204 のラウンド 1・2、
//! `tools/measure/quoted-names.sh`）の文言の規則を、実名を伏せた名前（`db`・`t`・`nope`）に当てたもの。

use super::*;

const S3_TABLES: &str = "s3tablescatalog/b";

fn rejected(query: &str) -> Option<String> {
    rejection(query, |catalog| catalog == S3_TABLES)
}

fn nv(position: &str, input: &str) -> Option<String> {
    Some(format!(
        "line {position}: no viable alternative at input '{input}'"
    ))
}

fn mm(position: &str, input: &str) -> Option<String> {
    Some(format!(
        "line {position}: mismatched input '{input}' expecting {EXPECTING}"
    ))
}

#[test]
fn describe_と_desc_は引用符付きの部分の番号で文言が変わる() {
    let cases = [
        // 最初の部分が引用符付き: 文の最初の語から最初の部分の終わりまで。
        (r#"DESCRIBE "t""#, nv("1:10", r#"DESCRIBE "t""#)),
        (r#"DESCRIBE"t""#, nv("1:9", r#"DESCRIBE"t""#)),
        (r#"DESCRIBE "T""#, nv("1:10", r#"DESCRIBE "T""#)),
        (r#"DESCRIBE "db"."t""#, nv("1:10", r#"DESCRIBE "db""#)),
        (r#"DESCRIBE "db".t"#, nv("1:10", r#"DESCRIBE "db""#)),
        (
            r#"DESCRIBE "AwsDataCatalog".db.t"#,
            nv("1:10", r#"DESCRIBE "AwsDataCatalog""#),
        ),
        (
            r#"DESCRIBE "awsdatacatalog"."db"."t""#,
            nv("1:10", r#"DESCRIBE "awsdatacatalog""#),
        ),
        (r#"DESCRIBE "a""b""#, nv("1:10", r#"DESCRIBE "a""b""#)),
        // 2 番目の部分が引用符付き: 名前の始まりから 2 番目の部分の終わりまで。
        (r#"DESCRIBE db."t""#, nv("1:13", r#"db."t""#)),
        (
            r#"DESCRIBE awsdatacatalog."db".t"#,
            nv("1:25", r#"awsdatacatalog."db""#),
        ),
        // 3 番目の部分だけ引用符付き: mismatched input。
        (r#"DESCRIBE awsdatacatalog.db."t""#, mm("1:28", r#""t""#)),
        (r#"DESC "t""#, nv("1:6", r#"DESC "t""#)),
        (r#"DESC "db"."t""#, nv("1:6", r#"DESC "db""#)),
        (r#"DESC db."t""#, nv("1:9", r#"db."t""#)),
        (r#"DESC awsdatacatalog.db."t""#, mm("1:24", r#""t""#)),
    ];
    for (query, expected) in cases {
        assert_eq!(rejected(query), expected, "{query:?}");
    }
}

#[test]
fn show_columns_と_drop_table_は最初の部分が引用符付きなら_mismatched_input() {
    let cases = [
        (r#"SHOW COLUMNS FROM "t""#, mm("1:19", r#""t""#)),
        (r#"SHOW COLUMNS IN "t""#, mm("1:17", r#""t""#)),
        (r#"SHOW COLUMNS FROM "db"."t""#, mm("1:19", r#""db""#)),
        (r#"SHOW COLUMNS FROM db."t""#, nv("1:22", r#"db."t""#)),
        (
            r#"SHOW COLUMNS FROM awsdatacatalog."db".t"#,
            nv("1:34", r#"awsdatacatalog."db""#),
        ),
        (
            r#"SHOW COLUMNS FROM awsdatacatalog.db."t""#,
            mm("1:37", r#""t""#),
        ),
        (r#"DROP TABLE "nope""#, mm("1:12", r#""nope""#)),
        (r#"DROP TABLE IF EXISTS "nope""#, mm("1:22", r#""nope""#)),
        (r#"DROP TABLE "db".nope"#, mm("1:12", r#""db""#)),
        (r#"DROP TABLE db."nope""#, nv("1:15", r#"db."nope""#)),
        (
            r#"DROP TABLE awsdatacatalog."db".nope"#,
            nv("1:27", r#"awsdatacatalog."db""#),
        ),
        (
            r#"DROP TABLE awsdatacatalog.db."nope""#,
            mm("1:30", r#""nope""#),
        ),
        (r#"drop table "nope""#, mm("1:12", r#""nope""#)),
        (r#"DROP TABLE  "nope""#, mm("1:13", r#""nope""#)),
        // S3 Tables のカタログでも DROP は一般の規則どおり（別名の文言にはならない）。
        (
            r#"DROP TABLE "s3tablescatalog/b".ns.nope"#,
            mm("1:12", r#""s3tablescatalog/b""#),
        ),
        (
            r#"DROP TABLE IF EXISTS "s3tablescatalog/b".ns.nope"#,
            mm("1:22", r#""s3tablescatalog/b""#),
        ),
    ];
    for (query, expected) in cases {
        assert_eq!(rejected(query), expected, "{query:?}");
    }
}

#[test]
fn show_create_table_はどこかが引用符付きなら位置の無い文言() {
    for query in [
        r#"SHOW CREATE TABLE "t""#,
        r#"SHOW CREATE TABLE"t""#,
        r#"SHOW CREATE TABLE "t" "#,
        r#"SHOW CREATE TABLE db."t""#,
        r#"SHOW CREATE TABLE awsdatacatalog.db."t""#,
        r#"SHOW CREATE TABLE "s3tablescatalog/b".ns.t"#,
    ] {
        assert_eq!(
            rejected(query).as_deref(),
            Some("Queries of this type are not supported"),
            "{query:?}"
        );
    }
}

#[test]
fn describe_と_show_columns_は_s3_tables_のカタログなら_2_catalogs() {
    for query in [
        r#"DESCRIBE "s3tablescatalog/b".ns.t"#,
        r#"DESCRIBE "s3tablescatalog/b"."ns"."t""#,
        r#"DESC "s3tablescatalog/b".ns.t"#,
        r#"SHOW COLUMNS FROM "s3tablescatalog/b".ns.t"#,
    ] {
        assert_eq!(
            rejected(query).as_deref(),
            Some("Unsupported DDL with 2 catalogs"),
            "{query:?}"
        );
    }
    // 別名でなければ一般の規則。
    assert_eq!(
        rejection(r#"DESCRIBE "s3tablescatalog/b".ns.t"#, |_| false),
        nv("1:10", r#"DESCRIBE "s3tablescatalog/b""#)
    );
}

#[test]
fn alter_table_は文の最初の語から引用符付きの部分の終わりまで() {
    let cases = [
        (
            r#"ALTER TABLE "nope" RENAME TO x"#,
            nv("1:13", r#"ALTER TABLE "nope""#),
        ),
        (
            r#"ALTER TABLE "nope" DROP COLUMN m"#,
            nv("1:13", r#"ALTER TABLE "nope""#),
        ),
        (
            r#"ALTER TABLE "db".nope RENAME TO x"#,
            nv("1:13", r#"ALTER TABLE "db""#),
        ),
        (
            r#"ALTER TABLE "awsdatacatalog".db.nope RENAME TO x"#,
            nv("1:13", r#"ALTER TABLE "awsdatacatalog""#),
        ),
        (
            r#"ALTER TABLE db."nope" DROP COLUMN m"#,
            nv("1:16", r#"ALTER TABLE db."nope""#),
        ),
        (
            r#"ALTER TABLE awsdatacatalog.db."nope" RENAME TO x"#,
            nv("1:31", r#"ALTER TABLE awsdatacatalog.db."nope""#),
        ),
        (
            r#"ALTER TABLE "s3tablescatalog/b".ns.nope RENAME TO x"#,
            nv("1:13", r#"ALTER TABLE "s3tablescatalog/b""#),
        ),
        // 3 部の名前で 2 番目だけ引用符付きは実測していないので弾かない。IF EXISTS は本物が別の文言で弾く。
        (r#"ALTER TABLE awsdatacatalog."db".nope RENAME TO x"#, None),
        (r#"ALTER TABLE IF EXISTS "nope" RENAME TO x"#, None),
    ];
    for (query, expected) in cases {
        assert_eq!(rejected(query), expected, "{query:?}");
    }
}

#[test]
fn show_tables_in_と_ctas_でない_create_table_は_1_部の引用符付きの名前だけ弾く() {
    let cases = [
        (r#"SHOW TABLES IN "db""#, mm("1:16", r#""db""#)),
        (
            r#"CREATE TABLE "nope3" (n int)"#,
            nv("1:14", r#"CREATE TABLE "nope3""#),
        ),
        (r#"SHOW TABLES IN "cat"."db""#, None),
        (r#"CREATE TABLE db."nope3" (n int)"#, None),
        // CTAS は本物も引用符付きの名前で成功する（2026-09-25 実測。#200）。
        (r#"CREATE TABLE "t" AS SELECT 1"#, None),
        (r#"CREATE TABLE IF NOT EXISTS "t" (n int)"#, None),
    ];
    for (query, expected) in cases {
        assert_eq!(rejected(query), expected, "{query:?}");
    }
}

#[test]
fn 位置は先頭の空白を除き_utf_16_の単位で数え_input_の制御文字はバックスラッシュで書く() {
    let cases = [
        (r#"describe "t""#, nv("1:10", r#"describe "t""#)),
        (r#"DESCRIBE  "t""#, nv("1:11", r#"DESCRIBE  "t""#)),
        (r#"  DESCRIBE "t""#, nv("1:10", r#"DESCRIBE "t""#)),
        ("\t\r\n\nDESCRIBE \"t\"", nv("1:10", r#"DESCRIBE "t""#)),
        (r#"/* c */ DESCRIBE "t""#, nv("1:18", r#"DESCRIBE "t""#)),
        ("-- c\nDESCRIBE \"t\"", nv("2:10", r#"DESCRIBE "t""#)),
        ("/* a\nb */ DESCRIBE \"t\"", nv("2:15", r#"DESCRIBE "t""#)),
        ("DESCRIBE\n\"t\"", nv("2:1", r#"DESCRIBE\n"t""#)),
        ("DESCRIBE\t\"t\"", nv("1:10", r#"DESCRIBE\t"t""#)),
        ("DESCRIBE\r\n\"t\"", nv("2:1", r#"DESCRIBE\r\n"t""#)),
        (r#"/* あ */ DESCRIBE "t""#, nv("1:18", r#"DESCRIBE "t""#)),
        (r#"/* 😀 */ DESCRIBE "t""#, nv("1:19", r#"DESCRIBE "t""#)),
        ("\nDROP TABLE \"nope\"", mm("1:12", r#""nope""#)),
        ("DROP TABLE\n\"nope\"", mm("2:1", r#""nope""#)),
    ];
    for (query, expected) in cases {
        assert_eq!(rejected(query), expected, "{query:?}");
    }
}

#[test]
fn 本物が通す形と実測していない形は弾かない() {
    for query in [
        "DESCRIBE t",
        "DESCRIBE db.t",
        "DESCRIBE awsdatacatalog.db.t",
        "SHOW CREATE TABLE t",
        "SHOW COLUMNS FROM t",
        "DROP TABLE IF EXISTS t",
        "ALTER TABLE t RENAME TO u",
        "SHOW TABLES IN db",
        r#"SHOW CREATE VIEW "v""#,
        r#"DROP VIEW "v""#,
        r#"CREATE VIEW "v" AS SELECT 1"#,
        r#"SELECT * FROM "t""#,
        r#"INSERT INTO "t" VALUES (1)"#,
        // 引用符付きの部分に非 ASCII がある DESCRIBE は、本物が構文の文言でなく Entity Not Found を返した。
        r#"DESCRIBE "日本""#,
        // 4 部以上は実測していない。
        r#"DESCRIBE "a".b.c.d"#,
        "",
        "DESCRIBE",
    ] {
        assert_eq!(rejected(query), None, "{query:?}");
    }
}

#[test]
fn expecting_は実測の一覧をそのまま持つ() {
    assert!(EXPECTING.starts_with("{'SELECT', 'FROM', 'ADD', 'AS', 'ALL', "));
    assert!(EXPECTING.ends_with(", IDENTIFIER, BACKQUOTED_IDENTIFIER}"));
}
