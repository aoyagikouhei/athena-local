//! create_table.rs のユニットテスト。期待値は本物の実測（2026-09-26。#208、`tools/measure/unquoted-ddl.sh`）の
//! 文言の規則を、実名を伏せた短い名前（`t`・`db`・`cat`・`u`・`n`・`m`・`a`・`b`）に当て、位置を手で数え直したもの。

use super::*;

fn rejected(query: &str) -> Option<String> {
    rejection(query, false)
}

fn nv(position: &str, input: &str) -> Option<String> {
    Some(format!(
        "line {position}: no viable alternative at input '{input}'"
    ))
}

fn no_location() -> Option<String> {
    Some(NO_LOCATION.to_string())
}

/// R-C1: CTAS でない場所の無い `CREATE TABLE` は型名を区別せず No location（D7）。
/// 数字の括弧・角括弧の入れ子・複数列・列と表の COMMENT・複数部の名前・IF NOT EXISTS・小文字・
/// 先頭コメント・LIKE の 1 部の名前でも同じ。
#[test]
fn 場所の無い_create_table_は型名によらず_no_location_を返す() {
    for query in [
        "CREATE TABLE t (n int)",
        "CREATE TABLE t (n integer)",
        "CREATE TABLE t (n varchar)",
        "CREATE TABLE t (n varchar(10))",
        "CREATE TABLE t (n timestamp(3))",
        "CREATE TABLE t (n decimal(10,2))",
        "CREATE TABLE t (n varchar(10, 2))",
        "CREATE TABLE t (n array<int>)",
        "CREATE TABLE t (n map<string,int>)",
        "CREATE TABLE t (n array<array<int>>)",
        "CREATE TABLE t (n foo)",
        "CREATE TABLE t (n INT)",
        "CREATE TABLE t (n int, m bigint, s string)",
        "CREATE TABLE t (n int) COMMENT 'x'",
        "CREATE TABLE t (n int COMMENT 'x')",
        "CREATE TABLE db.t (n int)",
        "CREATE TABLE cat.db.t (n int)",
        "CREATE TABLE IF NOT EXISTS t (n int)",
        "create table t (n int)",
        "/* c */ CREATE TABLE t (n int)",
        "CREATE TABLE t (LIKE u)",
    ] {
        assert_eq!(rejected(query), no_location(), "{query}");
    }
}

/// R-C1 の一般化: 型の後ろに語が続く形（`with`・`precision`・`day`）は、型名を区別せずその語の NV（D7）。
#[test]
fn 型の後ろに語が続けばその語の_no_viable_alternative() {
    for (query, expected) in [
        (
            "CREATE TABLE t (n timestamp(3) with time zone)",
            nv("1:32", "CREATE TABLE t (n timestamp(3) with"),
        ),
        (
            "CREATE TABLE t (n double precision)",
            nv("1:26", "CREATE TABLE t (n double precision"),
        ),
        (
            "CREATE TABLE t (n interval day to second)",
            nv("1:28", "CREATE TABLE t (n interval day"),
        ),
    ] {
        assert_eq!(rejected(query), expected, "{query}");
    }
}

/// `LIKE` は専用の分岐を置かず、ただの列の名前として読む（D7）。1 部の名前は No location（上のテスト）、
/// 2 部以上は型（1 部目）の後ろの最初の `.` で NV（`INCLUDING PROPERTIES` が続いても、2 列目でも同じ）。
#[test]
fn like_は列の名前として読み_2_部以上の名前は最初の_ドットで_no_viable_alternative() {
    for (query, expected) in [
        (
            "CREATE TABLE t (LIKE db.u)",
            nv("1:24", "CREATE TABLE t (LIKE db."),
        ),
        (
            "CREATE TABLE t (LIKE cat.db.u)",
            nv("1:25", "CREATE TABLE t (LIKE cat."),
        ),
        (
            "CREATE TABLE t (LIKE db.u INCLUDING PROPERTIES)",
            nv("1:24", "CREATE TABLE t (LIKE db."),
        ),
        (
            "CREATE TABLE t (n int, LIKE db.u)",
            nv("1:31", "CREATE TABLE t (n int, LIKE db."),
        ),
    ] {
        assert_eq!(rejected(query), expected, "{query}");
    }
}

/// R-C4（D7 で一般化）: `型名(` の中の最初の語が識別子なら、型名によらずその語の NV。
/// `row`・`array`（入れ子）・`map`・大文字・余分な空白・2 列目・`row`／`array`／`map` 以外の型名（`varchar`）でも同じ。
#[test]
fn 型名の括弧の中の識別子は型名によらずその語の_no_viable_alternative() {
    for (query, expected) in [
        (
            "CREATE TABLE t (n row(a int, b varchar))",
            nv("1:23", "CREATE TABLE t (n row(a"),
        ),
        (
            "CREATE TABLE t (n array(row(a int)))",
            nv("1:25", "CREATE TABLE t (n array(row"),
        ),
        (
            "CREATE TABLE t (n map(varchar, array(int)))",
            nv("1:23", "CREATE TABLE t (n map(varchar"),
        ),
        (
            "CREATE TABLE t (n ROW(a int))",
            nv("1:23", "CREATE TABLE t (n ROW(a"),
        ),
        (
            "CREATE TABLE t (n row( a int))",
            nv("1:24", "CREATE TABLE t (n row( a"),
        ),
        (
            "CREATE TABLE t (m int, n row(a int))",
            nv("1:30", "CREATE TABLE t (m int, n row(a"),
        ),
        // `row`／`array`／`map` 以外の型名でも同じ規則（型名は構文で区別されないので一般化。D7）。
        // ミューテーション (b)（数字ガードを外す）はこのテストで検知する。
        (
            "CREATE TABLE t (n varchar(x))",
            nv("1:27", "CREATE TABLE t (n varchar(x"),
        ),
    ] {
        assert_eq!(rejected(query), expected, "{query}");
    }
}

/// R-C3: 型の後ろの `NOT`（`NOT NULL`）は NV(NOT)。2 列目があっても同じ位置。
#[test]
fn not_null_は_not_の_no_viable_alternative() {
    for (query, expected) in [
        (
            "CREATE TABLE t (n int NOT NULL)",
            nv("1:23", "CREATE TABLE t (n int NOT"),
        ),
        (
            "CREATE TABLE t (n int NOT NULL, m int)",
            nv("1:23", "CREATE TABLE t (n int NOT"),
        ),
    ] {
        assert_eq!(rejected(query), expected, "{query}");
    }
}

/// R-C2: 列の並びの後ろの `WITH (` は NV(`(`)。表の `COMMENT`・`IF NOT EXISTS`・2 部の名前・改行を挟んでも同じ規則
/// （改行の後は `line 2:6`）。
#[test]
fn with_の開き括弧は_no_viable_alternative() {
    for (query, expected) in [
        (
            "CREATE TABLE t (n int) WITH (format = 'PARQUET')",
            nv("1:29", "CREATE TABLE t (n int) WITH ("),
        ),
        (
            "CREATE TABLE t (n int) COMMENT 'x' WITH (format = 'PARQUET')",
            nv("1:41", "CREATE TABLE t (n int) COMMENT 'x' WITH ("),
        ),
        (
            "CREATE TABLE IF NOT EXISTS t (n int) WITH (format = 'PARQUET')",
            nv("1:43", "CREATE TABLE IF NOT EXISTS t (n int) WITH ("),
        ),
        (
            "CREATE TABLE db.t (n int) WITH (format = 'PARQUET')",
            nv("1:32", "CREATE TABLE db.t (n int) WITH ("),
        ),
        (
            "CREATE TABLE t (n int)\nWITH (format = 'PARQUET')",
            nv("2:6", "CREATE TABLE t (n int)\\nWITH ("),
        ),
    ] {
        assert_eq!(rejected(query), expected, "{query}");
    }
}

/// CTAS・`CREATE OR REPLACE TABLE`（AS が無くても名前の並びで外れる）・4 部以上の名前・
/// 引用符付きの部分（1 部目・2 部目のどちらでも）は None（quoted_names の担当か未実測）。
#[test]
fn ctas_や_create_or_replace_や_4_部以上や引用符付きの名前は_none() {
    for query in [
        "CREATE TABLE t AS SELECT 1",
        "CREATE OR REPLACE TABLE t (n int)",
        "CREATE TABLE a.b.c.d (n int)",
        r#"CREATE TABLE "t" (n int)"#,
        r#"CREATE TABLE db."t" (n int)"#,
    ] {
        assert_eq!(rejected(query), None, "{query}");
    }
}

/// 列 0 個は None（未実測）。
#[test]
fn 列が_0_個なら_none() {
    assert_eq!(rejected("CREATE TABLE t ()"), None);
}

/// 列名・型名・型名の括弧の中の最初の語が引用符付きなら、その語の NV（input は文の最初の語から引用符付きの語の
/// 終わりまで）。2 列目・IF NOT EXISTS・後ろの NOT NULL でも同じ（2026-09-26 実測 q1〜q3・q5・q6・q8。#221）。
#[test]
fn 列名や型名や型名の括弧の中が引用符付きならその語の_no_viable_alternative() {
    for (query, expected) in [
        (
            r#"CREATE TABLE t ("n" int)"#,
            nv("1:17", r#"CREATE TABLE t ("n""#),
        ),
        (
            r#"CREATE TABLE t (n int, "m" int)"#,
            nv("1:24", r#"CREATE TABLE t (n int, "m""#),
        ),
        (
            r#"CREATE TABLE t ("n" int NOT NULL)"#,
            nv("1:17", r#"CREATE TABLE t ("n""#),
        ),
        (
            r#"CREATE TABLE IF NOT EXISTS t ("n" int)"#,
            nv("1:31", r#"CREATE TABLE IF NOT EXISTS t ("n""#),
        ),
        (
            r#"CREATE TABLE t (n row("f" int))"#,
            nv("1:23", r#"CREATE TABLE t (n row("f""#),
        ),
        (
            r#"CREATE TABLE t (n "int")"#,
            nv("1:19", r#"CREATE TABLE t (n "int""#),
        ),
    ] {
        assert_eq!(rejected(query), expected, "{query}");
    }
}

/// QueryExecutionContext の Catalog が S3 Tables なら、場所の無い CREATE TABLE は本物が作るので No location に
/// しない。列の NOT NULL・WITH ( の NV は既定の Context と同じ（2026-09-26 実測 h1〜h7。#221）。
#[test]
fn s3_tables_の_context_では_no_location_を返さず_no_viable_alternative_は返す() {
    for (query, expected) in [
        ("CREATE TABLE t (n int)", None),
        ("CREATE TABLE IF NOT EXISTS t (n int)", None),
        ("CREATE TABLE ns.t (n int)", None),
        ("CREATE TABLE t (n string)", None),
        (
            "CREATE TABLE awsdatacatalog.db.t (n int)",
            two_catalogs("CREATE TABLE awsdatacatalog.db.t (n int)"),
        ),
        (
            "CREATE TABLE t (n int NOT NULL)",
            nv("1:23", "CREATE TABLE t (n int NOT"),
        ),
        (
            "CREATE TABLE t (n int) WITH (format = 'PARQUET')",
            nv("1:29", "CREATE TABLE t (n int) WITH ("),
        ),
    ] {
        assert_eq!(rejection(query, true), expected, "{query}");
    }
}

fn two_catalogs(statement: &str) -> Option<String> {
    Some(format!("Unsupported ddl with 2 catalogs: {statement}"))
}

/// S3 Tables の Context で 1 部目がちょうど小文字の `awsdatacatalog` の 3 部の名前なら、No location の代わりに
/// `Unsupported ddl with 2 catalogs: <文>`。文は前後の空白を落とし、コメント・改行・中の空白はそのまま。
/// NV は先に出る。大文字混じりの `AwsDataCatalog`（本物は開始して FAILED）と実在しないカタログ（本物は
/// DATACATALOG_NOT_FOUND）は No location のまま（2026-09-26 実測 i1〜i22。#224）。
#[test]
fn s3_tables_の_context_で_awsdatacatalog_の_3_部は_2_catalogs_に文を付けて返す() {
    for (query, expected) in [
        (
            "create table awsdatacatalog.db.t (n int)",
            two_catalogs("create table awsdatacatalog.db.t (n int)"),
        ),
        (
            "CREATE TABLE IF NOT EXISTS awsdatacatalog.db.t (n int)",
            two_catalogs("CREATE TABLE IF NOT EXISTS awsdatacatalog.db.t (n int)"),
        ),
        (
            "/* c */ CREATE TABLE awsdatacatalog.db.t (n int)",
            two_catalogs("/* c */ CREATE TABLE awsdatacatalog.db.t (n int)"),
        ),
        (
            "-- c\nCREATE TABLE awsdatacatalog.db.t (n int)",
            two_catalogs("-- c\nCREATE TABLE awsdatacatalog.db.t (n int)"),
        ),
        (
            "CREATE TABLE awsdatacatalog.db.t\n(\n  n int\n)",
            two_catalogs("CREATE TABLE awsdatacatalog.db.t\n(\n  n int\n)"),
        ),
        (
            "  CREATE  TABLE\tawsdatacatalog.db.t (n int)  \n",
            two_catalogs("CREATE  TABLE\tawsdatacatalog.db.t (n int)"),
        ),
        (
            "CREATE TABLE awsdatacatalog.db.t (n int NOT NULL)",
            nv("1:41", "CREATE TABLE awsdatacatalog.db.t (n int NOT"),
        ),
        (
            r#"CREATE TABLE awsdatacatalog.db.t ("n" int)"#,
            nv("1:35", r#"CREATE TABLE awsdatacatalog.db.t ("n""#),
        ),
        (
            "CREATE TABLE awsdatacatalog.db.t (n int) WITH (format = 'PARQUET')",
            nv("1:47", "CREATE TABLE awsdatacatalog.db.t (n int) WITH ("),
        ),
        ("CREATE TABLE AwsDataCatalog.db.t (n int)", no_location()),
        ("CREATE TABLE nosuchcatalog.db.t (n int)", no_location()),
    ] {
        assert_eq!(rejection(query, true), expected, "{query:?}");
    }
    // 既定の Context では No location のまま（i18・i22）。
    assert_eq!(
        rejected("CREATE TABLE awsdatacatalog.db.t (n int)"),
        no_location()
    );
}

/// `WITH` の後が `(` でない形と、`)` の後の未知の後置き（`LOCATION '...'` など）は None
/// （Trino 自身が構文エラーにする形なので、実際には athena-local の構文チェックで先に弾かれる）。
#[test]
fn with_の後が開き括弧でないか_未知の後置きなら_none() {
    for query in [
        "CREATE TABLE t (n int) WITH format = 'PARQUET'",
        "CREATE TABLE t (n int) LOCATION 'x'",
    ] {
        assert_eq!(rejected(query), None, "{query}");
    }
}

/// CREATE TABLE でない文（SELECT・ALTER TABLE・CREATE VIEW）は None。
#[test]
fn create_table_でない文は_none() {
    for query in [
        "SELECT 1",
        "ALTER TABLE t ADD COLUMN m int",
        "CREATE VIEW v AS SELECT 1",
    ] {
        assert_eq!(rejected(query), None, "{query}");
    }
}

/// `three_part_name` は `rejection` と同じ読み方で名前を取る。No location になる無引用の 3 部の名前では、Context に
/// よらず必ず 1 部目と 2 部目を書いたとおりに返し、1〜2 部と引用符付きの部分がある名前では None（#227）。
#[test]
fn three_part_name_は_no_location_になる_3_部の名前で必ず_1_部目と_2_部目を返す() {
    for (query, expected) in [
        ("CREATE TABLE NoSuch.db.t (n int)", ("NoSuch", "db")),
        (
            "CREATE TABLE IF NOT EXISTS AwsDataCatalog.Ns.t (n int)",
            ("AwsDataCatalog", "Ns"),
        ),
        (
            "/* c */\n  create table cat . ns . t (n int)",
            ("cat", "ns"),
        ),
        (
            "CREATE TABLE iceberg.db.t (n array<int>, m string)",
            ("iceberg", "db"),
        ),
    ] {
        for s3_tables in [false, true] {
            assert_eq!(rejection(query, s3_tables), no_location(), "{query}");
        }
        let (catalog, namespace, first_part) = three_part_name(query).expect(query);
        assert_eq!((catalog, namespace), expected, "{query}");
        assert_eq!(
            &query[first_part.start..first_part.start + catalog.len()],
            catalog
        );
        assert_eq!(
            &query[first_part.end..first_part.end + namespace.len()],
            namespace
        );
    }
    for query in [
        "CREATE TABLE t (n int)",
        "CREATE TABLE db.t (n int)",
        r#"CREATE TABLE "cat".db.t (n int)"#,
        r#"CREATE TABLE cat."db".t (n int)"#,
        "CREATE TABLE AS SELECT 1",
    ] {
        assert_eq!(three_part_name(query), None, "{query}");
    }
}

/// `two_part_namespace` は S3 Tables でない Context で No location になる無引用の 2 部の名前の 1 部目を書いたとおりに
/// 返し（S3 Tables の Context では `rejection` が弾かない）、NV になる形・1 部・3 部・引用符付きの名前では None（#231）。
#[test]
fn two_part_namespace_は_no_location_になる_2_部の名前の_1_部目を返す() {
    for (query, expected) in [
        ("CREATE TABLE Ns.t (n int)", "Ns"),
        ("CREATE TABLE IF NOT EXISTS ns.t (n int)", "ns"),
        ("/* c */\n  create table db . t (n int) COMMENT 'c'", "db"),
    ] {
        assert_eq!(rejection(query, true), None, "{query}");
        assert_eq!(two_part_namespace(query), Some(expected), "{query}");
    }
    for query in [
        "CREATE TABLE t (n int)",
        "CREATE TABLE cat.db.t (n int)",
        r#"CREATE TABLE "db".t (n int)"#,
        r#"CREATE TABLE db."t" (n int)"#,
        "CREATE TABLE db.t (n int NOT NULL)",
        "CREATE TABLE db.t (n int) WITH (format = 'PARQUET')",
        "CREATE TABLE db.t AS SELECT 1",
    ] {
        assert_eq!(two_part_namespace(query), None, "{query}");
    }
}
