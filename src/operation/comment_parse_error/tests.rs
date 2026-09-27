//! `detect` のテスト。実測の結果（`.claude/issue-notes/244.md` の「実測の結果」節、ラウンド 2・3）を
//! 表で焼き込む。`<DB>.<表>` は `db.t`（RENAME 先は `db.t2`）に置き換えている。名前を置き換えても
//! 決め手の位置はすべて名前の**前**（SHOW CREATE TABLE・MSCK REPAIR TABLE・ALTER TABLE の名前の直前まで）
//! なので、DROP COLUMN の ErrorMessage（名前の**後ろ**の `COLUMN` の位置を使う）以外は実測の数値と
//! そのまま一致する。DROP COLUMN は `db.t`・`c`（1 文字の列名）で計算し直した値を使う（コメントに実測値を書く）。
//!
//! 実際の Athena は SHOW CREATE TABLE・DESCRIBE・ALTER の ADD COLUMNS／DROP COLUMN を Iceberg 表で、
//! DESCRIBE をビューで成功させる（s6〜s9・d1・d5・d7〜d9・a3・a14・a17・n12・n13、MSCK は Iceberg で
//! 2/1200 の別の失敗、m2〜m4・m6・r10）。`detect` は表の種類を見ない純粋な字句判定なので、これらと
//! **同じ SQL の形**に対しても `Some` を返す（配線側が `entity_check`／`table_format` の結果と合わせて
//! 使うかどうかを決める。モジュール冒頭のコメント参照）。「detect はテーブルの種類を見ない」で確認する。

use super::*;

fn parse_exception(target: Target, reason: &str) -> ParseError {
    ParseError {
        target,
        reason: reason.to_string(),
        error_message: None,
        category: 1,
        error_type: 1003,
        hive_only: false,
    }
}

#[test]
fn show_create_table_の_4_つのチェックポイント() {
    for (ids, sql, reason) in [
        // 先頭（s2。s6・s10・s20・s21・s24・s25・s26・s27 も同じ形の一部）。
        (
            "s2",
            "/* c */ SHOW CREATE TABLE db.t",
            "FAILED: ParseException line 1:0 cannot recognize input near '/' '*' 'c'",
        ),
        // 先頭・字句が `abc`（s20）。
        (
            "s20",
            "/* abc */ SHOW CREATE TABLE db.t",
            "FAILED: ParseException line 1:0 cannot recognize input near '/' '*' 'abc'",
        ),
        // 先頭・空のコメント `/**/` は字句が `*`（s21）。
        (
            "s21",
            "/**/ SHOW CREATE TABLE db.t",
            "FAILED: ParseException line 1:0 cannot recognize input near '/' '*' '*'",
        ),
        // 先頭・行コメントの後ろは 2:0（s25）。
        (
            "s25",
            "-- x\n/* c */ SHOW CREATE TABLE db.t",
            "FAILED: ParseException line 2:0 cannot recognize input near '/' '*' 'c'",
        ),
        // 先頭・改行の前は 1:0（s26）。
        (
            "s26",
            "/* c */\nSHOW CREATE TABLE db.t",
            "FAILED: ParseException line 1:0 cannot recognize input near '/' '*' 'c'",
        ),
        // 先頭・コメント 2 つは最初のものだけ（s27 は本来 SHOW の後ろの形なので、コメント 2 つの効果だけを
        // 別に確かめる。字句は 1 つ目の `a`）。
        (
            "s27 相当（コメント2つのうち先頭側）",
            "/* a */ /* b */ SHOW CREATE TABLE db.t",
            "FAILED: ParseException line 1:0 cannot recognize input near '/' '*' 'a'",
        ),
        // SHOW の後（s3。s7・s11 も同じ形）。
        (
            "s3",
            "SHOW /* c */ CREATE TABLE db.t",
            "FAILED: ParseException line 1:5 cannot recognize input near 'SHOW' '/' '*' in ddl statement",
        ),
        // SHOW の後・小文字（s14）。
        (
            "s14",
            "show /* c */ create table db.t",
            "FAILED: ParseException line 1:5 cannot recognize input near 'show' '/' '*' in ddl statement",
        ),
        // SHOW の後・改行は 2:0（s18）。
        (
            "s18",
            "SHOW\n/* c */ CREATE TABLE db.t",
            "FAILED: ParseException line 2:0 cannot recognize input near 'SHOW' '/' '*' in ddl statement",
        ),
        // SHOW の後・タブ 1 つ（p2）。
        (
            "p2",
            "SHOW\t/* c */ CREATE TABLE db.t",
            "FAILED: ParseException line 1:5 cannot recognize input near 'SHOW' '/' '*' in ddl statement",
        ),
        // SHOW の後・改行 2 つは畳んで 1:5（p6）。
        (
            "p6",
            "SHOW\n\n/* c */ CREATE TABLE db.t",
            "FAILED: ParseException line 1:5 cannot recognize input near 'SHOW' '/' '*' in ddl statement",
        ),
        // SHOW の後・タブ 2 つも畳んで 1:5（p11）。
        (
            "p11",
            "SHOW\t\t/* c */ CREATE TABLE db.t",
            "FAILED: ParseException line 1:5 cannot recognize input near 'SHOW' '/' '*' in ddl statement",
        ),
        // CREATE の後（s4。s8・s12・s13 も同じ形）。
        (
            "s4",
            "SHOW CREATE /* c */ TABLE db.t",
            "FAILED: ParseException line 1:12 mismatched input '/' expecting TABLE near 'CREATE' in show statement",
        ),
        // CREATE の後・小文字（s15）。
        (
            "s15",
            "show create /* c */ table db.t",
            "FAILED: ParseException line 1:12 mismatched input '/' expecting TABLE near 'create' in show statement",
        ),
        // CREATE の後・改行は 2:0（s19）。
        (
            "s19",
            "SHOW CREATE\n/* c */ TABLE db.t",
            "FAILED: ParseException line 2:0 mismatched input '/' expecting TABLE near 'CREATE' in show statement",
        ),
        // SHOW と CREATE の間の空白 2 つは畳んで 1:12（p1）。
        (
            "p1",
            "SHOW  CREATE /* c */ TABLE db.t",
            "FAILED: ParseException line 1:12 mismatched input '/' expecting TABLE near 'CREATE' in show statement",
        ),
        // CREATE の後・改行 + 空白 2 つも畳んで 1:12（p5）。
        (
            "p5",
            "SHOW CREATE\n  /* c */ TABLE db.t",
            "FAILED: ParseException line 1:12 mismatched input '/' expecting TABLE near 'CREATE' in show statement",
        ),
        // 名前の直前（TABLE の後。s5。s9・d10 も同じ形）。
        (
            "s5",
            "SHOW CREATE TABLE /* c */ db.t",
            "FAILED: ParseException line 1:18 cannot recognize input near '/' '*' 'c' in table name",
        ),
        // 名前の直前・字句が `1`（c11）。
        (
            "c11",
            "SHOW CREATE TABLE /* 1 */ db.t",
            "FAILED: ParseException line 1:18 cannot recognize input near '/' '*' '1' in table name",
        ),
        // 名前の直前・空白 2 つは畳んで 1:18（p4）。
        (
            "p4",
            "SHOW CREATE TABLE  /* c */ db.t",
            "FAILED: ParseException line 1:18 cannot recognize input near '/' '*' 'c' in table name",
        ),
        // 全部の間が空白 2 つでも同じ 1:18（p8）。
        (
            "p8",
            "SHOW  CREATE  TABLE  /* c */ db.t",
            "FAILED: ParseException line 1:18 cannot recognize input near '/' '*' 'c' in table name",
        ),
    ] {
        assert_eq!(
            detect(sql),
            Some(parse_exception(Target::ShowCreateTable, reason)),
            "{ids}: {sql}"
        );
    }
}

#[test]
fn describe_と_desc_の_2_つのチェックポイント() {
    for (ids, sql, reason) in [
        // 先頭（d4）。
        (
            "d4",
            "/* c */ DESCRIBE db.t",
            "FAILED: ParseException line 1:0 cannot recognize input near '/' '*' 'c'",
        ),
        // DESCRIBE の後・小文字（d2。d1・d7 も同じ形）。
        (
            "d2",
            "describe /* c */ db.t",
            "FAILED: ParseException line 1:0 cannot recognize input near 'describe' '/' '*' in describe statement",
        ),
        // DESC の後（d3。d8 も同じ形）。
        (
            "d3",
            "DESC /* c */ db.t",
            "FAILED: ParseException line 1:0 cannot recognize input near 'DESC' '/' '*' in describe statement",
        ),
    ] {
        assert_eq!(
            detect(sql),
            Some(parse_exception(Target::Describe, reason)),
            "{ids}: {sql}"
        );
    }
}

#[test]
fn describe_の後ろは_describe_自身の位置で_コメントの位置ではない() {
    // ALTER と同じく「後ろ」のチェックポイントは固定位置（D5）。ここでは空白 2 つを挟んでも
    // DESCRIBE 自身は先頭（0）のままであることを確かめる（本物は DESCRIBE の後ろに空白を測っていないが、
    // ALTER の a6・a7 と同じ規則で近似する。D5）。
    assert_eq!(
        detect("DESCRIBE  /* c */ db.t"),
        Some(parse_exception(
            Target::Describe,
            "FAILED: ParseException line 1:0 cannot recognize input near 'DESCRIBE' '/' '*' in describe statement"
        ))
    );
}

#[test]
fn msck_repair_table_の_4_つのチェックポイント() {
    for (ids, sql, reason) in [
        // 先頭（r4。m2 も同じ形）。
        (
            "r4",
            "/* c */ MSCK REPAIR TABLE db.t",
            "FAILED: ParseException line 1:0 cannot recognize input near '/' '*' 'c'",
        ),
        // MSCK の後（r3。m3 も同じ形）。
        (
            "r3",
            "MSCK /* c */ REPAIR TABLE db.t",
            "FAILED: ParseException line 1:5 missing EOF at '/' near 'MSCK'",
        ),
        // REPAIR の後（r2。m6・r9・r10 も同じ形）。
        (
            "r2",
            "MSCK REPAIR /* c */ TABLE db.t",
            "FAILED: ParseException line 1:12 missing EOF at '/' near 'REPAIR'",
        ),
        // REPAIR の後・小文字（r6）。
        (
            "r6",
            "msck repair /* c */ table db.t",
            "FAILED: ParseException line 1:12 missing EOF at '/' near 'repair'",
        ),
        // REPAIR の後・空白 2 つは畳んで 1:12（r7）。
        (
            "r7",
            "MSCK REPAIR  /* c */ TABLE db.t",
            "FAILED: ParseException line 1:12 missing EOF at '/' near 'REPAIR'",
        ),
        // REPAIR の後・改行は 2:0（r8）。
        (
            "r8",
            "MSCK REPAIR\n/* c */ TABLE db.t",
            "FAILED: ParseException line 2:0 missing EOF at '/' near 'REPAIR'",
        ),
        // MSCK と REPAIR の間の空白 2 つも、REPAIR の後ろの位置には影響しない（p3）。
        (
            "p3",
            "MSCK  REPAIR /* c */ TABLE db.t",
            "FAILED: ParseException line 1:12 missing EOF at '/' near 'REPAIR'",
        ),
        // 名前の直前（TABLE の後。r5。m4 も同じ形）。
        (
            "r5",
            "MSCK REPAIR TABLE /* c */ db.t",
            "FAILED: ParseException line 1:18 cannot recognize input near '/' '*' 'c' in table name",
        ),
    ] {
        assert_eq!(
            detect(sql),
            Some(parse_exception(Target::MsckRepair, reason)),
            "{ids}: {sql}"
        );
    }
}

#[test]
fn 名前が引用符付きの部品を含むか_4_部以上なら_none() {
    for (ids, sql) in [
        (
            "SHOW CREATE TABLE・引用符付き（未実測。D1）",
            r#"/* c */ SHOW CREATE TABLE "db".t"#,
        ),
        (
            "SHOW CREATE TABLE・4 部（未実測。D1）",
            "SHOW CREATE TABLE /* c */ a.b.c.d",
        ),
        (
            "ALTER TABLE・引用符付き（未実測。D1）",
            r#"ALTER /* c */ TABLE "db".t ADD COLUMNS (c int)"#,
        ),
        (
            "ALTER TABLE・4 部（未実測。D1）",
            "ALTER TABLE /* c */ a.b.c.d ADD COLUMNS (c int)",
        ),
    ] {
        assert_eq!(detect(sql), None, "{ids}: {sql}");
    }
}

#[test]
fn 決め手の位置より後ろにしかブロックコメントが無ければ_none() {
    for (ids, sql) in [
        (
            "SHOW CREATE TABLE・名前の後ろ（未実測。D1）",
            "SHOW CREATE TABLE db.t /* c */",
        ),
        (
            "ALTER TABLE・名前と ADD の間（未実測。D1）",
            "ALTER TABLE db.t /* c */ ADD COLUMNS (c int)",
        ),
    ] {
        assert_eq!(detect(sql), None, "{ids}: {sql}");
    }
}

#[test]
fn show_create_table_は無引用ちょうど_2_部の名前の_ドット直後のコメントで_hive_only_の印付きで_some()
 {
    for (ids, sql, reason) in [
        (
            "g1",
            "SHOW CREATE TABLE db./* c */t",
            "FAILED: ParseException line 1:21 cannot recognize input near 'db' '.' '/' in table name",
        ),
        // 大文字の DB の綴りも書いたまま（2026-09-27 実測 g1 の綴りの規則。#257）。
        (
            "g1・大文字の綴り",
            "SHOW CREATE TABLE MyDb./* c */t",
            "FAILED: ParseException line 1:23 cannot recognize input near 'MyDb' '.' '/' in table name",
        ),
    ] {
        assert_eq!(
            detect(sql),
            Some(ParseError {
                target: Target::ShowCreateTable,
                reason: reason.to_string(),
                error_message: None,
                category: 1,
                error_type: 1003,
                hive_only: true,
            }),
            "{ids}: {sql}"
        );
    }
}

#[test]
fn show_create_table_の_2_部の名前の_ドット直後のコメントは対象を絞り_ほかは_none() {
    for (ids, sql) in [
        ("3 部（未実測）", "SHOW CREATE TABLE a./* c */b.c"),
        (
            "引用符付きの部品（未実測）",
            r#"SHOW CREATE TABLE "db"./* c */t"#,
        ),
        // `.` の前にコメントがあるとき（`.` の直後ではない。未実測）。
        (
            ".の前のコメント（未実測）",
            "SHOW CREATE TABLE db /* c */.t",
        ),
        // 1 部の名前の後ろ（`.` が無い。決め手の位置より後ろと同じ扱い。未実測）。
        ("1 部の名前の後ろ（未実測）", "SHOW CREATE TABLE t/* c */"),
    ] {
        assert_eq!(detect(sql), None, "{ids}: {sql}");
    }
}

#[test]
fn 行コメントは空白と同じに読み飛ばしブロックコメントが無ければ_none() {
    // d6: 行コメントだけで、ブロックコメントが無ければ本物は成功する。
    assert_eq!(detect("DESCRIBE -- c\ndb.t"), None);
    assert_eq!(detect("MSCK REPAIR TABLE -- c\ndb.t"), None);
}

#[test]
fn コメントが無ければ_none() {
    // 素朴な基準（r1・a1・s1 相当）。
    assert_eq!(detect("SHOW CREATE TABLE db.t"), None);
    assert_eq!(detect("DESCRIBE db.t"), None);
    assert_eq!(detect("MSCK REPAIR TABLE db.t"), None);
    assert_eq!(detect("ALTER TABLE db.t ADD COLUMNS (c int)"), None);
}

#[test]
fn detect_はテーブルの種類を見ないので_iceberg_やビューで実際には成功する形にも_some_を返す() {
    // 本物は SHOW CREATE TABLE・DESCRIBE・ALTER の ADD COLUMNS／DROP COLUMN を Iceberg 表で、
    // DESCRIBE をビューで成功させる（s6〜s9・d1・d5・d7〜d9・a3・a14・a17・n12・n13）。ここで使う SQL は
    // s3・d2・a2 と同じ形（表の種類は `detect` の外で決まるため、文字列としては区別できない）。
    // MSCK は Iceberg で 2/1200 の別の失敗になる（m2〜m4・m6・r10）が、これも `detect` の外の判断で、
    // `detect` 自体は同じ ParseException を返す。
    assert_eq!(
        detect("SHOW /* c */ CREATE TABLE db.t"),
        Some(parse_exception(
            Target::ShowCreateTable,
            "FAILED: ParseException line 1:5 cannot recognize input near 'SHOW' '/' '*' in ddl statement"
        )),
        "s6〜s9 と同じ形"
    );
    assert_eq!(
        detect("describe /* c */ db.t"),
        Some(parse_exception(
            Target::Describe,
            "FAILED: ParseException line 1:0 cannot recognize input near 'describe' '/' '*' in describe statement"
        )),
        "d1・d5・d7〜d9 と同じ形"
    );
    assert_eq!(
        detect("ALTER /* c */ TABLE db.t ADD COLUMNS (c int)"),
        Some(parse_exception(
            Target::AlterAddColumns,
            "FAILED: ParseException line 1:0 cannot recognize input near 'ALTER' '/' '*' in alter statement"
        )),
        "a3・a14・n12・n13 と同じ形"
    );
    assert_eq!(
        detect("MSCK /* c */ REPAIR TABLE db.t"),
        Some(parse_exception(
            Target::MsckRepair,
            "FAILED: ParseException line 1:5 missing EOF at '/' near 'MSCK'"
        )),
        "m2〜m4・m6・r10 と同じ形"
    );
}
