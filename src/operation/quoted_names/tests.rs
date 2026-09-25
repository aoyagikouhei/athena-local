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
        // 3 部の名前で 2 番目が引用符付きでも同じ規則（2026-09-25 実測 V1。#207）。
        (
            r#"ALTER TABLE awsdatacatalog."db".nope RENAME TO x"#,
            nv("1:28", r#"ALTER TABLE awsdatacatalog."db""#),
        ),
        (
            r#"ALTER TABLE awsdatacatalog."db"."nope" DROP COLUMN m"#,
            nv("1:28", r#"ALTER TABLE awsdatacatalog."db""#),
        ),
        // IF EXISTS は本物が引用符の有無によらず別の文言で弾く（範囲外の差）。
        (r#"ALTER TABLE IF EXISTS "nope" RENAME TO x"#, None),
    ];
    for (query, expected) in cases {
        assert_eq!(rejected(query), expected, "{query:?}");
    }
}

#[test]
fn show_tables_in_と_ctas_でない_create_table_は最初の引用符付きの部分で弾く() {
    let cases = [
        (r#"SHOW TABLES IN "db""#, mm("1:16", r#""db""#)),
        // 2 部は最初の引用符付きの部分で mismatched input（2026-09-25 実測 V3。#207）。
        (r#"SHOW TABLES IN "cat"."db""#, mm("1:16", r#""cat""#)),
        (r#"SHOW TABLES IN "cat".db"#, mm("1:16", r#""cat""#)),
        (r#"SHOW TABLES IN cat."db""#, mm("1:20", r#""db""#)),
        (
            r#"CREATE TABLE "nope3" (n int)"#,
            nv("1:14", r#"CREATE TABLE "nope3""#),
        ),
        // 2・3 部も文の最初の語から最初の引用符付きの部分まで（2026-09-25 実測 V3。#207）。
        (
            r#"CREATE TABLE "db"."nope3" (n int)"#,
            nv("1:14", r#"CREATE TABLE "db""#),
        ),
        (
            r#"CREATE TABLE db."nope3" (n int)"#,
            nv("1:17", r#"CREATE TABLE db."nope3""#),
        ),
        (
            r#"CREATE TABLE awsdatacatalog."db".nope3 (n int)"#,
            nv("1:29", r#"CREATE TABLE awsdatacatalog."db""#),
        ),
        // IF NOT EXISTS も文の最初の語から（2026-09-25 実測 V3。#207）。
        (
            r#"CREATE TABLE IF NOT EXISTS "t" (n int)"#,
            nv("1:28", r#"CREATE TABLE IF NOT EXISTS "t""#),
        ),
        (r#"CREATE TABLE IF NOT EXISTS t (n int)"#, None),
        // CTAS は本物も引用符付きの名前で成功する（2026-09-25 実測。#200）。
        (r#"CREATE TABLE "t" AS SELECT 1"#, None),
        (r#"CREATE TABLE IF NOT EXISTS "t" AS SELECT 1"#, None),
    ];
    for (query, expected) in cases {
        assert_eq!(rejected(query), expected, "{query:?}");
    }
}

#[test]
fn describe_と_show_columns_と_show_create_table_は_4_部以上なら引用符によらず_invalid_table_name()
{
    let invalid = |name: &str| Some(format!("Invalid table name {name}"));
    let cases = [
        // 2026-09-25 実測 V2・W2（#207）・Y4（#212）。各部は引用符を外した中身を小文字にする。
        (
            "DESCRIBE awsdatacatalog.db.t.n",
            invalid("awsdatacatalog.db.t.n"),
        ),
        (
            r#"DESCRIBE "awsdatacatalog".db.t.n"#,
            invalid("awsdatacatalog.db.t.n"),
        ),
        (
            r#"DESCRIBE awsdatacatalog.db.t."n""#,
            invalid("awsdatacatalog.db.t.n"),
        ),
        (
            "DESCRIBE AwsDataCatalog.db.t.N",
            invalid("awsdatacatalog.db.t.n"),
        ),
        (
            r#"DESCRIBE awsdatacatalog."db"."a""b".n"#,
            invalid(r#"awsdatacatalog.db.a"b.n"#),
        ),
        (
            r#"DESCRIBE awsdatacatalog.db."x.y".n"#,
            invalid("awsdatacatalog.db.x.y.n"),
        ),
        (
            "DESCRIBE awsdatacatalog.db.t.n.m",
            invalid("awsdatacatalog.db.t.n.m"),
        ),
        (
            "DESC awsdatacatalog.db.t.n",
            invalid("awsdatacatalog.db.t.n"),
        ),
        (
            "SHOW COLUMNS FROM awsdatacatalog.db.t.n",
            invalid("awsdatacatalog.db.t.n"),
        ),
        (
            r#"SHOW COLUMNS IN "awsdatacatalog".db.t.n"#,
            invalid("awsdatacatalog.db.t.n"),
        ),
        // S3 Tables の別名より先に判定する。
        (
            r#"DESCRIBE "s3tablescatalog/b".ns.t.n"#,
            invalid("s3tablescatalog/b.ns.t.n"),
        ),
        // 引用符付きの大文字も小文字になる（2026-09-25 実測 Y4。#212）。
        (
            r#"DESCRIBE awsdatacatalog.db."T".n"#,
            invalid("awsdatacatalog.db.t.n"),
        ),
        (
            r#"DESCRIBE "AwsDataCatalog".db.t.n"#,
            invalid("awsdatacatalog.db.t.n"),
        ),
        (
            r#"DESCRIBE awsdatacatalog."DB".t."N""#,
            invalid("awsdatacatalog.db.t.n"),
        ),
        (
            r#"SHOW COLUMNS FROM awsdatacatalog.db."T".n"#,
            invalid("awsdatacatalog.db.t.n"),
        ),
        // SHOW CREATE TABLE も同じ（2026-09-25 実測 Y1。#212）。
        (
            "SHOW CREATE TABLE awsdatacatalog.db.t.n",
            invalid("awsdatacatalog.db.t.n"),
        ),
        (
            r#"SHOW CREATE TABLE awsdatacatalog."db".t.n"#,
            invalid("awsdatacatalog.db.t.n"),
        ),
        (
            r#"SHOW CREATE TABLE awsdatacatalog.db.t."n""#,
            invalid("awsdatacatalog.db.t.n"),
        ),
        (
            "SHOW CREATE TABLE awsdatacatalog.db.t.n.m",
            invalid("awsdatacatalog.db.t.n.m"),
        ),
    ];
    for (query, expected) in cases {
        assert_eq!(rejected(query), expected, "{query:?}");
    }
}

#[test]
fn drop_table_と_alter_table_は_4_部以上なら引用符の位置で規則が分かれる() {
    let dot = |position: &str| {
        Some(format!(
            "line {position}: mismatched input '.' expecting {{<EOF>, 'PURGE'}}"
        ))
    };
    let cases = [
        // 引用符付きの部分が 1〜3 部目なら 3 部の規則（2026-09-25 実測 V2。#207）。
        (
            r#"DROP TABLE "awsdatacatalog".db.nope.n"#,
            mm("1:12", r#""awsdatacatalog""#),
        ),
        (
            r#"DROP TABLE awsdatacatalog."db".nope.n"#,
            nv("1:27", r#"awsdatacatalog."db""#),
        ),
        (
            r#"DROP TABLE awsdatacatalog.db."nope".n"#,
            mm("1:30", r#""nope""#),
        ),
        (
            r#"ALTER TABLE "awsdatacatalog".db.nope.n RENAME TO x"#,
            nv("1:13", r#"ALTER TABLE "awsdatacatalog""#),
        ),
        (
            r#"ALTER TABLE awsdatacatalog."db".nope.n RENAME TO x"#,
            nv("1:28", r#"ALTER TABLE awsdatacatalog."db""#),
        ),
        // 無引用か 4 部目以降だけなら 3 つ目の `.` の位置（2026-09-25 実測 V2・W3。#207）。
        ("DROP TABLE awsdatacatalog.db.nope.n", dot("1:34")),
        (r#"DROP TABLE awsdatacatalog.db.nope."n""#, dot("1:34")),
        ("DROP TABLE awsdatacatalog.db.nope.n.m", dot("1:34")),
        ("DROP TABLE IF EXISTS awsdatacatalog.db.nope.n", dot("1:44")),
        ("DROP TABLE a . b . c . d", dot("1:22")),
        (
            "ALTER TABLE awsdatacatalog.db.nope.n RENAME TO x",
            nv("1:35", "ALTER TABLE awsdatacatalog.db.nope."),
        ),
        (
            r#"ALTER TABLE awsdatacatalog.db.nope."n" RENAME TO x"#,
            nv("1:35", "ALTER TABLE awsdatacatalog.db.nope."),
        ),
        (
            "ALTER TABLE awsdatacatalog.db.nope.n.m RENAME TO x",
            nv("1:35", "ALTER TABLE awsdatacatalog.db.nope."),
        ),
    ];
    for (query, expected) in cases {
        assert_eq!(rejected(query), expected, "{query:?}");
    }
}

#[test]
fn show_tables_in_の_3_部以上は_2_つ目の_点_で弾く() {
    let dot = |position: &str, kind: &str| {
        Some(format!(
            "line {position}: {kind} input '.' expecting {{<EOF>, 'LIKE', STRING}}"
        ))
    };
    let cases = [
        // 引用符付きの部分が 1・2 部目なら 1・2 部と同じ規則（2026-09-25 実測 Y1・Y2。#212）。
        (
            r#"SHOW TABLES IN "awsdatacatalog".db.x"#,
            mm("1:16", r#""awsdatacatalog""#),
        ),
        (
            r#"SHOW TABLES IN awsdatacatalog."db".x"#,
            mm("1:31", r#""db""#),
        ),
        (
            r#"SHOW TABLES IN awsdatacatalog."db".x.n"#,
            mm("1:31", r#""db""#),
        ),
        // そうでなければ 2 つ目の `.`。直後が引用符付きなら extraneous（2026-09-25 実測 Y1・Y2。#212）。
        (
            "SHOW TABLES IN awsdatacatalog.db.x",
            dot("1:33", "mismatched"),
        ),
        (
            r#"SHOW TABLES IN awsdatacatalog.db."x""#,
            dot("1:33", "extraneous"),
        ),
        (
            "SHOW TABLES IN awsdatacatalog.db.x.n",
            dot("1:33", "mismatched"),
        ),
        (
            r#"SHOW TABLES IN awsdatacatalog.db.x."n""#,
            dot("1:33", "mismatched"),
        ),
        ("SHOW TABLES IN a . b . c", dot("1:22", "mismatched")),
    ];
    for (query, expected) in cases {
        assert_eq!(rejected(query), expected, "{query:?}");
    }
}

#[test]
fn ctas_でない_create_table_の_4_部以上は引用符が無ければ_3_つ目の_点_で弾く() {
    let dot = |position: &str| {
        Some(format!(
            "line {position}: mismatched input '.' expecting {{<EOF>, '(', 'SELECT', 'FROM', 'AS', 'ROW', 'WITH', 'VALUES', 'TABLE', 'INSERT', 'MAP', 'COMMENT', 'REDUCE', 'TBLPROPERTIES', 'SKEWED', 'STORED', 'LOCATION', 'CLUSTERED', 'PARTITIONED'}}"
        ))
    };
    let cases = [
        // 2026-09-25 実測 Y1（#212）。引用符付きの部分が 3 部目までにあれば 3 部と同じ規則。
        (
            r#"CREATE TABLE awsdatacatalog."db".nope3.n (n int)"#,
            nv("1:29", r#"CREATE TABLE awsdatacatalog."db""#),
        ),
        (
            "CREATE TABLE awsdatacatalog.db.nope3.n (n int)",
            dot("1:37"),
        ),
        (
            r#"CREATE TABLE awsdatacatalog.db.nope3."n" (n int)"#,
            dot("1:37"),
        ),
        (
            "CREATE TABLE awsdatacatalog.db.nope3.n.m (n int)",
            dot("1:37"),
        ),
        // IF NOT EXISTS も引用符付きの部分が 3 部目までにあれば、4 部目を読む前に文言が決まるので 3 部と同じ規則。
        (
            r#"CREATE TABLE IF NOT EXISTS a."b".c.d (n int)"#,
            nv("1:30", r#"CREATE TABLE IF NOT EXISTS a."b""#),
        ),
        // IF NOT EXISTS の 3 つ目の `.` と CTAS の 4 部以上は実測していない。
        ("CREATE TABLE IF NOT EXISTS a.b.c.d (n int)", None),
        (r#"CREATE TABLE IF NOT EXISTS a.b.c."d" (n int)"#, None),
        ("CREATE TABLE a.b.c.d AS SELECT 1", None),
    ];
    for (query, expected) in cases {
        assert_eq!(rejected(query), expected, "{query:?}");
    }
}

#[test]
fn 非_ascii_の名前も一般の規則で弾く() {
    // 2026-09-25 実測 V5・V6（#207）。DESCRIBE・SHOW COLUMNS は実在するテーブルなら構文の文言（実在しなければ
    // 先に entity_check が Entity Not Found にする）、ほかの文は実在しない "日本" でも構文の文言だった。
    let cases = [
        (r#"DESCRIBE "t_日本""#, nv("1:10", r#"DESCRIBE "t_日本""#)),
        (r#"DESCRIBE db."t_日本""#, nv("1:13", r#"db."t_日本""#)),
        (r#"SHOW COLUMNS FROM "t_日本""#, mm("1:19", r#""t_日本""#)),
        (r#"DROP TABLE "日本""#, mm("1:12", r#""日本""#)),
        (
            r#"ALTER TABLE "日本" RENAME TO x"#,
            nv("1:13", r#"ALTER TABLE "日本""#),
        ),
        (
            r#"SHOW CREATE TABLE "日本""#,
            Some("Queries of this type are not supported".to_string()),
        ),
        (r#"SHOW TABLES IN "日本""#, mm("1:16", r#""日本""#)),
        (
            r#"CREATE TABLE "日本" (n int)"#,
            nv("1:14", r#"CREATE TABLE "日本""#),
        ),
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
