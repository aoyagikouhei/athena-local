//! classification.rs のユニットテスト。

use super::*;

#[test]
fn statement_type_は先頭のキーワードで決まる() {
    assert_eq!(statement_type("SELECT 1"), "DML");
    assert_eq!(statement_type("  insert into t values (1)"), "DML");
    assert_eq!(statement_type("MERGE INTO t USING s ON x"), "DML");
    assert_eq!(statement_type("CREATE TABLE t AS SELECT 1"), "DDL");
    assert_eq!(statement_type("DROP TABLE t"), "DDL");
    assert_eq!(statement_type("SET SESSION x = 1"), "UTILITY");
    assert_eq!(statement_type("VALUES 1"), "DML");
    assert_eq!(statement_type("DESCRIBE t"), "UTILITY");
    assert_eq!(statement_type("EXPLAIN SELECT 1"), "DML");
    assert_eq!(statement_type("VACUUM t"), "DML");
    assert_eq!(
        statement_type("OPTIMIZE t REWRITE DATA USING BIN_PACK"),
        "DDL"
    );
    assert_eq!(statement_type("SHOW TABLES"), "UTILITY");
    // `TABLE t`（`SELECT * FROM t` の短縮形）も本物は DML（2026-09-22 実測。#65）。
    assert_eq!(statement_type("TABLE t"), "DML");
    assert_eq!(statement_type("table db.t"), "DML");
    assert_eq!(statement_type("(TABLE t)"), "DML");
    assert_eq!(statement_type("-- c\nTABLE t"), "DML");
    // 先頭のコメントは読み飛ばして判定する（2026-09-18 実測）。
    assert_eq!(statement_type("-- c\nSELECT 1"), "DML");
    assert_eq!(statement_type("/* c */ SHOW TABLES"), "UTILITY");
    // `(` の直後に空白や改行があっても、`(SELECT` と同じく括弧を飛ばして判定する
    // （#64 のレビューで見つかった。空の語が先頭に残って UTILITY に落ちていた）。本物も DML（2026-09-24 実測。#146）。
    assert_eq!(statement_type("( SELECT 1 )"), "DML");
    assert_eq!(
        statement_type("(\n  SELECT 1\n)\nUNION ALL\n(\n  SELECT 2\n)"),
        "DML"
    );
}

#[test]
fn substatement_type_は実測した文の種類を返す() {
    for (query, expected) in [
        ("SELECT 1", "SELECT"),
        ("WITH x AS (SELECT 1 AS n) SELECT * FROM x", "SELECT"),
        ("VALUES 1", "SELECT"),
        ("INSERT INTO t SELECT 'a', 1", "INSERT"),
        ("UPDATE t SET a = 1", "UPDATE"),
        ("DELETE FROM t", "DELETE"),
        ("MERGE INTO t USING s ON t.id = s.id", "MERGE"),
        ("EXPLAIN SELECT 1", "EXPLAIN"),
        ("DESCRIBE t", "DESCRIBE_TABLE"),
        // 本物は `DESC t` を `DESCRIBE t` と同じ種類で返す（2026-09-23／24 実測。#70 f1-desc・#173 d6）。
        ("DESC t", "DESCRIBE_TABLE"),
        ("desc /* c */ t", "DESCRIBE_TABLE"),
        ("VACUUM t", "VACUUM_TABLE"),
        (
            "OPTIMIZE t REWRITE DATA USING BIN_PACK",
            "CREATE_TABLE_AS_SELECT",
        ),
        ("SHOW TABLES IN db", "SHOW_TABLES"),
        ("SHOW DATABASES LIKE 'x'", "SHOW_DATABASES"),
        ("SHOW SCHEMAS", "SHOW_DATABASES"),
        ("SHOW COLUMNS IN db.t", "SHOW_COLUMNS"),
        ("SHOW CREATE TABLE t", "SHOW_CREATE_TABLE"),
        // 2026-09-24 実測（#146・#151）。StatementType は他の SHOW と同じ UTILITY。
        ("SHOW CREATE VIEW v", "SHOW_CREATE_VIEW"),
        ("show create view v", "SHOW_CREATE_VIEW"),
        ("-- c\nSHOW CREATE VIEW v", "SHOW_CREATE_VIEW"),
        // 2026-09-23 実測（#80）。
        ("SHOW FUNCTIONS", "SHOW_FUNCTIONS"),
        ("show /* c */ functions", "SHOW_FUNCTIONS"),
        ("CREATE DATABASE IF NOT EXISTS db", "CREATE_DATABASE"),
        ("CREATE SCHEMA IF NOT EXISTS db", "CREATE_DATABASE"),
        ("CREATE TABLE t (id string)", "CREATE_TABLE"),
        (
            "CREATE TABLE c WITH (table_type = 'ICEBERG') AS SELECT * FROM t",
            "CREATE_TABLE_AS_SELECT",
        ),
        ("CREATE VIEW v AS SELECT 1 AS n", "CREATE_VIEW"),
        ("CREATE OR REPLACE VIEW v AS SELECT 1 AS n", "CREATE_VIEW"),
        ("DROP TABLE IF EXISTS t", "DROP_TABLE"),
        ("DROP VIEW IF EXISTS v", "DROP_VIEW"),
        ("DROP DATABASE IF EXISTS db CASCADE", "DROP_DATABASE"),
        (
            "ALTER TABLE t ADD COLUMNS (c string)",
            "ALTER_TABLE_ADD_COLUMN",
        ),
        (
            "ALTER TABLE t ADD COLUMN c varchar",
            "ALTER_TABLE_ADD_COLUMN",
        ),
        // TBLPROPERTIES の値に add と column という語が含まれても
        // ALTER_TABLE_PROPERTIES になる（全文走査ではなく位置固定で判定する。2026-09-21 実測）。
        (
            "ALTER TABLE t SET TBLPROPERTIES ('comment' = 'remember to add column for region')",
            "ALTER_TABLE_PROPERTIES",
        ),
        ("ALTER TABLE t DROP COLUMN c", "ALTER_TABLE_DROP_COLUMN"),
        (
            "ALTER TABLE t SET LOCATION 's3://bucket/path/'",
            "ALTER_TABLE_SET_LOCATION",
        ),
        // 残りの亜種（2026-09-21 実測）。REPLACE の値だけ単数形の COLUMN で終わる。
        // 本物が実行時に失敗する組み合わせ（REPLACE COLUMNS・ADD PARTITION × Iceberg、
        // RENAME TO × Hive）でも、SubstatementType は同じ値で返る。
        (
            "ALTER TABLE t REPLACE COLUMNS (n int, s string)",
            "ALTER_TABLE_REPLACE_COLUMN",
        ),
        (
            "ALTER TABLE t ADD PARTITION (p = 'v')",
            "ALTER_TABLE_ADD_PARTITION",
        ),
        (
            "ALTER TABLE t DROP PARTITION (p = 'v')",
            "ALTER_TABLE_DROP_PARTITION",
        ),
        ("ALTER TABLE t RENAME TO u", "ALTER_TABLE_RENAME"),
        // 先頭のコメントは読み飛ばして判定する（2026-09-18 実測）。
        ("-- c\nSELECT 1", "SELECT"),
        // `TABLE t` は本物も SELECT（2026-09-22 実測。#65）。
        ("TABLE t", "SELECT"),
        ("(TABLE t) LIMIT 1", "SELECT"),
        // 2 語目以降も読み飛ばした後の並びから取る（`.metadata` のクエリ ID を選ぶ
        // `content_type::carries_execution_id` も同じ形の入力で守っている）。
        ("-- c\nSHOW CREATE TABLE t", "SHOW_CREATE_TABLE"),
    ] {
        assert_eq!(substatement_type(query), Some(expected), "{query:?}");
    }

    // 実測していない形は省く。
    for query in [
        // RENAME COLUMN と IF EXISTS は本物の Athena に構文が無い（mismatched input。2026-09-21 実測）。
        "ALTER TABLE t RENAME COLUMN a TO b",
        "ALTER TABLE IF EXISTS t ADD COLUMNS (m int)",
        // DROP が受けるのは単数形の COLUMN だけ（複数形は mismatched input 'COLUMNS'.
        // Expecting: '.', 'DROP' で StartQueryExecution ごと弾かれる。2026-09-21 実測）。
        // ADD は複数形の COLUMNS を受けるので、単複の扱いは対称ではない。
        "ALTER TABLE t DROP COLUMNS c",
        "CALL x()",
        "SET SESSION a = 1",
        "",
    ] {
        assert_eq!(substatement_type(query), None, "{query:?}");
    }
    assert_eq!(statement_type(""), "UTILITY");
}

#[test]
fn substatement_type_は_alter_table_の判定でテーブル名の後ろのトリビアを跨いでも正しく分類する() {
    // word(3)/word(4) の固定位置ではなく、テーブル名を読み飛ばした後ろの語で判定することを
    // 固定する（2026-09-21 実測、2 本のレビューが独立に確認した退行）。
    for (query, expected) in [
        (
            r#"ALTER TABLE "my table" ADD COLUMNS (c string)"#,
            "ALTER_TABLE_ADD_COLUMN",
        ),
        (
            "ALTER TABLE cat . ns . t ADD COLUMNS (m int)",
            "ALTER_TABLE_ADD_COLUMN",
        ),
        (
            "ALTER TABLE t -- comment\nADD COLUMN c int",
            "ALTER_TABLE_ADD_COLUMN",
        ),
    ] {
        assert_eq!(substatement_type(query), Some(expected), "{query:?}");
    }

    // 誤判定が復活していないことも合わせて固定する（全文走査に戻すと TBLPROPERTIES の
    // 値の中の "add column" で誤判定する。Phase 3a の主題）。
    for (query, expected) in [
        (
            r#"ALTER TABLE "my table" SET TBLPROPERTIES ('comment' = 'remember to add column for region')"#,
            "ALTER_TABLE_PROPERTIES",
        ),
        (
            "ALTER TABLE cat . ns . t SET TBLPROPERTIES ('comment' = 'add column')",
            "ALTER_TABLE_PROPERTIES",
        ),
    ] {
        assert_eq!(substatement_type(query), Some(expected), "{query:?}");
    }

    // DROP TABLE は影響を受けない。
    assert_eq!(
        substatement_type(r#"DROP TABLE "my table""#),
        Some("DROP_TABLE")
    );

    // 本物の Athena に構文が無い形は変わらず None。
    for query in [
        "ALTER TABLE IF EXISTS t ADD COLUMNS (m int)",
        "ALTER TABLE t RENAME COLUMN a TO b",
    ] {
        assert_eq!(substatement_type(query), None, "{query:?}");
    }
}

#[test]
fn substatement_type_は_alter_table_のキーワードの直後に空白が無くても分類する() {
    // `SET TBLPROPERTIES('comment' = 'x')` のように、キーワードの直後に `(` や
    // 文字列リテラルが続く空白無しの書き方（3 本目のレビューが実測で確認）。
    for (query, expected) in [
        (
            "ALTER TABLE t SET TBLPROPERTIES('comment' = 'x')",
            "ALTER_TABLE_PROPERTIES",
        ),
        (
            "ALTER TABLE t SET LOCATION's3://bucket/path/'",
            "ALTER_TABLE_SET_LOCATION",
        ),
        ("ALTER TABLE t ADD COLUMNS(m int)", "ALTER_TABLE_ADD_COLUMN"),
    ] {
        assert_eq!(substatement_type(query), Some(expected), "{query:?}");
    }
}

// 以下の 3 つは、issue #49 で `skip_keyword` を `catalog.rs` へ統合する前に、着手前の挙動を
// 境界入力で固定したもの。統合は挙動を変えないので red が成立しない。代わりにこれらが
// 「統合の前後で結果が変わらない」ことの網になる。期待値は推測ではなく、着手前のコードに
// 一時テストを足して実際に流した出力をそのまま写した。

#[test]
fn substatement_type_はトリビアが何個どこに挟まっても同じ結果になる() {
    for (query, expected) in [
        (
            "  ALTER TABLE t ADD COLUMNS (c int)",
            Some("ALTER_TABLE_ADD_COLUMN"),
        ),
        (
            "-- c\nALTER TABLE t ADD COLUMNS (c int)",
            Some("ALTER_TABLE_ADD_COLUMN"),
        ),
        // トリビアを 2 つ重ねる。
        (
            "ALTER TABLE t /* a */ -- b\nADD COLUMNS (c int)",
            Some("ALTER_TABLE_ADD_COLUMN"),
        ),
        (
            "ALTER TABLE t ADD /* c */ COLUMNS (c int)",
            Some("ALTER_TABLE_ADD_COLUMN"),
        ),
        (
            "ALTER TABLE t SET /* c */ TBLPROPERTIES ('a' = 'b')",
            Some("ALTER_TABLE_PROPERTIES"),
        ),
        // `ALTER` と `TABLE` の間のコメントも空白として読む（#49 の時点では `words()` が
        // `split_whitespace` で語を数えて `word(1)` が `/*` になり None だった。#52 で
        // 本物を実測し、コメントを空白として分類することを確かめて直した。2026-09-22 実測）。
        (
            "ALTER /* c */ TABLE t ADD COLUMNS (c int)",
            Some("ALTER_TABLE_ADD_COLUMN"),
        ),
    ] {
        assert_eq!(substatement_type(query), expected, "{query:?}");
    }
}

#[test]
fn substatement_type_はキーワードの間のコメントを空白として読む() {
    // 本物はキーワードとキーワードの間のコメント（`/* c */` も `-- c` も）を空白として扱い、
    // 先頭のコメントと同じく分類には影響しない（2026-09-22 実測。#52）。
    // `SHOW /* c */ CREATE TABLE` と `SHOW CREATE /* c */ TABLE` は本物では実行が
    // ParseException で失敗するが、SubstatementType は SHOW_CREATE_TABLE と分類された。
    for (query, expected) in [
        ("DROP /* c */ TABLE t", "DROP_TABLE"),
        ("DROP -- c\nTABLE t", "DROP_TABLE"),
        ("DROP TABLE /* c */ IF EXISTS t", "DROP_TABLE"),
        ("DROP /* c */ VIEW v", "DROP_VIEW"),
        ("DROP /* c */ DATABASE IF EXISTS db", "DROP_DATABASE"),
        (
            "ALTER -- c\nTABLE t ADD COLUMNS (c int)",
            "ALTER_TABLE_ADD_COLUMN",
        ),
        (
            "CREATE /* c */ TABLE t AS SELECT 1",
            "CREATE_TABLE_AS_SELECT",
        ),
        ("CREATE -- c\nTABLE t AS SELECT 1", "CREATE_TABLE_AS_SELECT"),
        (
            "CREATE TABLE t AS /* c */ SELECT 1",
            "CREATE_TABLE_AS_SELECT",
        ),
        (
            "CREATE TABLE t /* c */ AS SELECT 1",
            "CREATE_TABLE_AS_SELECT",
        ),
        ("CREATE /* c */ TABLE t (n int)", "CREATE_TABLE"),
        (
            "CREATE /* c */ DATABASE IF NOT EXISTS db",
            "CREATE_DATABASE",
        ),
        (
            "CREATE OR /* c */ REPLACE VIEW v AS SELECT 1",
            "CREATE_VIEW",
        ),
        // 文字列リテラルの中の `--` はコメントではない（計画攻撃で見つかった退行。
        // S3 Express のバケット名を 1 行の CTAS に書いた形）。
        (
            "CREATE TABLE t WITH (external_location = 's3://a--b--x-s3/p/') AS SELECT 1",
            "CREATE_TABLE_AS_SELECT",
        ),
        ("SHOW /* c */ TABLES", "SHOW_TABLES"),
        ("SHOW /* c */ CREATE TABLE t", "SHOW_CREATE_TABLE"),
        ("SHOW CREATE /* c */ TABLE t", "SHOW_CREATE_TABLE"),
        // `SHOW CREATE /* c */ VIEW` は本物でも成功する（2026-09-24 実測。#146）。
        ("SHOW CREATE /* c */ VIEW v", "SHOW_CREATE_VIEW"),
        // 空白を挟まずにコメントが語に接していても区切りになる。
        ("DROP/* c */TABLE t", "DROP_TABLE"),
    ] {
        assert_eq!(substatement_type(query), Some(expected), "{query:?}");
    }
    // 先頭の語だけで決まる文は変わらない。
    assert_eq!(statement_type("CREATE /* c */ TABLE t AS SELECT 1"), "DDL");
    assert_eq!(substatement_type("SELECT /* c */ 1"), Some("SELECT"));
}

#[test]
fn substatement_type_はキーワードの直後が識別子の文字かどうかで一致を決める() {
    for (query, expected) in [
        // 続きが英数字・`_` なら別の語とみなして一致させない。
        ("ALTER TABLE t ADDX COLUMNS (c int)", None),
        ("ALTER TABLE t ADD COLUMNS_X (c int)", None),
        ("ALTER TABLE t SET TBLPROPERTIESX ('a' = 'b')", None),
        // 続きが識別子の文字でなければ、空白が無くても一致する。
        (
            r#"ALTER TABLE t ADD COLUMN"c" int"#,
            Some("ALTER_TABLE_ADD_COLUMN"),
        ),
        (
            "ALTER TABLE t DROP COLUMN(c)",
            Some("ALTER_TABLE_DROP_COLUMN"),
        ),
    ] {
        assert_eq!(substatement_type(query), expected, "{query:?}");
    }
}

#[test]
fn substatement_type_は大文字小文字を無視し多バイト文字と短い入力でも破綻しない() {
    for (query, expected) in [
        (
            "alter table t add columns (c int)",
            Some("ALTER_TABLE_ADD_COLUMN"),
        ),
        (
            "AlTeR TaBlE t sEt TbLpRoPeRtIeS ('a' = 'b')",
            Some("ALTER_TABLE_PROPERTIES"),
        ),
        // 多バイト文字の引用符付きテーブル名を `skip_qualified_name` で読み飛ばしてから、
        // その後ろのキーワードで判定する。
        (
            r#"ALTER TABLE "日本語" ADD COLUMNS (c int)"#,
            Some("ALTER_TABLE_ADD_COLUMN"),
        ),
        // テーブル名の後ろに何も無い／テーブル名すら無い入力でも panic せずに None を返す。
        ("ALTER TABLE t", None),
        ("ALTER TABLE", None),
    ] {
        assert_eq!(substatement_type(query), expected, "{query:?}");
    }
}
