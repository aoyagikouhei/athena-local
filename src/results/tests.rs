//! results.rs のユニットテスト（結合テストは tests/results.rs）。

use serde_json::Value;

use super::*;
use crate::trino::Column;

fn column(name: &str, type_name: &str, signature: &str) -> Column {
    Column {
        name: name.to_string(),
        type_name: type_name.to_string(),
        type_signature: Some(serde_json::from_str(signature).expect("型が JSON でない")),
    }
}

fn scalar(raw_type: &str) -> String {
    format!(r#"{{"rawType":"{raw_type}","arguments":[]}}"#)
}

fn csv(outcome: &Outcome) -> String {
    String::from_utf8(to_csv(outcome)).expect("UTF-8 でない")
}

fn text(outcome: &Outcome) -> String {
    String::from_utf8(to_text(outcome, false)).expect("UTF-8 でない")
}

/// 本番 Athena に投げたクエリ（抜粋）:
///   SELECT 1 AS i, 1.5 AS d, 'it''s' AS s, 'a"b' AS q, 'x' || chr(10) || 'y' AS nl,
///          CAST(NULL AS varchar) AS n, '' AS empty, true AS b, ARRAY[1,2] AS a, ...
/// to_csv と to_text の両方で、複合型を含む値の表記を確かめるのに使う。
fn 全型を含む_outcome() -> Outcome {
    let integer = scalar("integer");
    let varchar = scalar("varchar");
    let array_integer =
        format!(r#"{{"rawType":"array","arguments":[{{"kind":"TYPE","value":{integer}}}]}}"#);
    let array_varchar =
        format!(r#"{{"rawType":"array","arguments":[{{"kind":"TYPE","value":{varchar}}}]}}"#);
    let map_varchar_integer = format!(
        r#"{{"rawType":"map","arguments":[{{"kind":"TYPE","value":{varchar}}},{{"kind":"TYPE","value":{integer}}}]}}"#
    );
    let map_integer_varchar = format!(
        r#"{{"rawType":"map","arguments":[{{"kind":"TYPE","value":{integer}}},{{"kind":"TYPE","value":{varchar}}}]}}"#
    );
    let row = r#"{"rawType":"row","arguments":[
        {"kind":"NAMED_TYPE","value":{"fieldName":{"name":"id"},"typeSignature":{"rawType":"integer","arguments":[]}}},
        {"kind":"NAMED_TYPE","value":{"fieldName":{"name":"name"},"typeSignature":{"rawType":"varchar","arguments":[]}}}]}"#;

    Outcome {
        columns: vec![
            column("i", "integer", &integer),
            column("d", "double", &scalar("double")),
            column("s", "varchar(4)", &varchar),
            column("q", "varchar(3)", &varchar),
            column("nl", "varchar", &varchar),
            column("n", "varchar", &varchar),
            column("empty", "varchar(0)", &varchar),
            column("b", "boolean", &scalar("boolean")),
            column("a", "array(integer)", &array_integer),
            column("sa", "array(varchar(4))", &array_varchar),
            column("m", "map(varchar(1), integer)", &map_varchar_integer),
            column("mk", "map(integer, varchar(1))", &map_integer_varchar),
            column("dt", "date", &scalar("date")),
            column("ts", "timestamp(3)", &scalar("timestamp")),
            column("vb", "varbinary", &scalar("varbinary")),
            column("r", "row(id integer, name varchar)", row),
            column("ja", "varchar(3)", &varchar),
        ],
        rows: vec![
            serde_json::from_str::<Vec<Value>>(
                r#"[1, 1.5, "it's", "a\"b", "x\ny", null, "", true, [1, 2], ["p, q", null],
                    {"k": 1}, {"10": "b", "9": "a"}, "2020-01-01", "2020-01-01 12:34:56.789",
                    "AQI=", [1, "x"], "日本語"]"#,
            )
            .expect("行が JSON でない"),
        ],
        ..Outcome::default()
    }
}

#[test]
fn 実測した_csv_と同じバイト列になる() {
    // 入力は同じ値を Trino が返す形、期待値は Athena が置いた <id>.csv そのもの。
    let outcome = 全型を含む_outcome();

    assert_eq!(
        csv(&outcome),
        "\"i\",\"d\",\"s\",\"q\",\"nl\",\"n\",\"empty\",\"b\",\"a\",\"sa\",\"m\",\"mk\",\"dt\",\"ts\",\"vb\",\"r\",\"ja\"\n\
         \"1\",\"1.5\",\"it's\",\"a\"\"b\",\"x\ny\",,\"\",\"true\",\"[1, 2]\",\"[p, q, null]\",\"{k=1}\",\
         \"{9=a, 10=b}\",\"2020-01-01\",\"2020-01-01 12:34:56.789\",\"01 02\",\"{id=1, name=x}\",\"日本語\"\n"
    );
}

#[test]
fn to_text_は複合型を含め_to_csv_と同じ表記で_引用符もヘッダも無い() {
    // csv の引用符・エスケープ・列名行を取り除いた形と一致するはず。
    let outcome = 全型を含む_outcome();

    assert_eq!(
        text(&outcome),
        "1\t1.5\tit's\ta\"b\tx\ny\t\t\ttrue\t[1, 2]\t[p, q, null]\t{k=1}\t{9=a, 10=b}\t\
         2020-01-01\t2020-01-01 12:34:56.789\t01 02\t{id=1, name=x}\t日本語"
    );
}

#[test]
fn to_text_は複数行をタブと改行で連結し_末尾に改行を付けない() {
    let outcome = Outcome {
        columns: vec![
            column("i", "integer", &scalar("integer")),
            column("s", "varchar", &scalar("varchar")),
        ],
        rows: vec![
            vec![Value::from(1), Value::from("a")],
            vec![Value::from(2), Value::from("b")],
        ],
        ..Outcome::default()
    };

    let result = text(&outcome);
    assert_eq!(result, "1\ta\n2\tb");
    assert!(
        !result.ends_with('\n'),
        "末尾に改行が付いている: {result:?}"
    );
}

#[test]
fn to_text_は見出し無しなら列名の行を入れない() {
    let outcome = Outcome {
        columns: vec![column("x", "integer", &scalar("integer"))],
        rows: vec![vec![Value::from(1)]],
        ..Outcome::default()
    };

    assert_eq!(text(&outcome), "1");
}

#[test]
fn to_text_は見出しありなら列名の行を先頭に入れる() {
    // EXPLAIN の .txt（2026-09-15／16 実測）。末尾の空行は空のまま残り、末尾に改行は付けない。
    let outcome = Outcome {
        columns: vec![column("Query Plan", "varchar", &scalar("varchar"))],
        rows: vec![
            vec![Value::from("Fragment 0 [SINGLE]")],
            vec![Value::from("")],
            vec![Value::from("")],
        ],
        ..Outcome::default()
    };

    assert_eq!(
        String::from_utf8(to_text(&outcome, true)).expect("UTF-8 でない"),
        "Query Plan\nFragment 0 [SINGLE]\n\n"
    );
}

#[test]
fn to_text_は_null_を空文字にする() {
    let outcome = Outcome {
        columns: vec![
            column("a", "integer", &scalar("integer")),
            column("b", "integer", &scalar("integer")),
            column("c", "integer", &scalar("integer")),
        ],
        rows: vec![vec![Value::from(1), Value::Null, Value::from(3)]],
        ..Outcome::default()
    };

    assert_eq!(text(&outcome), "1\t\t3");
}

#[test]
fn to_text_は行が無ければ空になる() {
    // CREATE TABLE や CREATE DATABASE のように列が無い DDL。
    let ddl = Outcome::default();
    assert_eq!(to_text(&ddl, false), Vec::<u8>::new());

    // DML / CTAS は update_count がある。
    let dml = Outcome {
        update_count: Some(1),
        ..Outcome::default()
    };
    assert_eq!(to_text(&dml, false), Vec::<u8>::new());
}

#[test]
fn 行が無くても列名行は書く() {
    let outcome = Outcome {
        columns: vec![column("x", "integer", &scalar("integer"))],
        ..Outcome::default()
    };
    assert_eq!(csv(&outcome), "\"x\"\n");
}

#[test]
fn 置き場所は_prefix_の末尾スラッシュの有無によらない() {
    for output_location in ["s3://bucket/a/b/", "s3://bucket/a/b"] {
        let location = ResultLocation::new(output_location, "id", "SELECT 1").unwrap();
        assert_eq!(location.bucket, "bucket");
        assert_eq!(location.key, "a/b/id.csv");
        assert_eq!(location.uri(), "s3://bucket/a/b/id.csv");
    }
    for output_location in ["s3://bucket", "s3://bucket/"] {
        let location = ResultLocation::new(output_location, "id", "SELECT 1").unwrap();
        assert_eq!(location.uri(), "s3://bucket/id.csv");
    }
}

fn location(query: &str) -> ResultLocation {
    ResultLocation::new("s3://bucket/p/", "id", query).unwrap()
}

#[test]
fn ファイル名は文の種類で変わる() {
    let uri = |query| location(query).uri();
    assert_eq!(uri("SELECT 1"), "s3://bucket/p/id.csv");
    assert_eq!(uri("INSERT INTO t VALUES (1)"), "s3://bucket/p/id");
    assert_eq!(uri("CREATE TABLE t AS SELECT 1"), "s3://bucket/p/tables/id");
    assert_eq!(uri("SHOW TABLES"), "s3://bucket/p/id.txt");
}

#[test]
fn 付随ファイルのキーは本体のキーに_metadata_を足したもの() {
    let key = |query| location(query).metadata().key;
    assert_eq!(key("SELECT 1"), "p/id.csv.metadata");
    assert_eq!(key("SHOW TABLES"), "p/id.txt.metadata");
    assert_eq!(key("INSERT INTO t VALUES (1)"), "p/id.metadata");
    // `tables/` は CTAS の実測（テーブルの形式によらない）。
    assert_eq!(key("CREATE TABLE t AS SELECT 1"), "p/tables/id.metadata");
}

/// 本体の Content-Type は文の形で決まり（2026-09-23 実測）、`.metadata` はそれを引き継ぐ。
/// INSERT と CTAS は本体を書かないが `.metadata` は書くので、その値が実際に届く
/// （本物は application。2026-09-17／18 実測）。
#[test]
fn 付随ファイルの_content_type_は本体と同じ() {
    for (query, expected) in [
        ("SELECT 1", "binary/octet-stream"),
        ("SELECT 1 + 1", "application/octet-stream"),
        ("SHOW TABLES", "binary/octet-stream"),
        ("DESCRIBE t", "application/octet-stream"),
        ("INSERT INTO t VALUES (1)", "application/octet-stream"),
        ("CREATE TABLE t AS SELECT 1", "application/octet-stream"),
    ] {
        let body = location(query);
        assert_eq!(body.content_type, expected, "{query}");
        assert_eq!(body.metadata().content_type, expected, "{query}");
    }
}

#[test]
fn 失敗ファイルの置き場所は_txt_の文だけにあり_キーは成功時と同じ() {
    let show = location("SHOW TABLES");
    let failed = show.failed().expect("txt の文には置き場所がある");
    assert_eq!(failed.bucket, show.bucket);
    assert_eq!(failed.key, show.key);
    assert_eq!(failed.file, ResultFile::FailedText);

    // `.csv` / `<id>` / `tables/<id>` の文は本物も失敗時に何も置かない。
    for query in [
        "SELECT 1",
        "INSERT INTO t VALUES (1)",
        "CREATE TABLE t AS SELECT 1",
    ] {
        assert_eq!(location(query).failed(), None, "{query}");
    }
}

/// 成功した `.txt` は文の形で binary にも application にもなるが、失敗の理由の `.txt` は
/// どちらの文でも application（2026-09-17 実測）。
#[test]
fn 失敗ファイルの_content_type_は文の形によらず_application() {
    for query in ["SHOW TABLES", "DESCRIBE t"] {
        let failed = location(query).failed().unwrap();
        assert_eq!(failed.content_type, "application/octet-stream", "{query}");
    }
    assert_eq!(location("SHOW TABLES").content_type, "binary/octet-stream");
}

#[test]
fn s3_の形でない出力先は受け付けない() {
    for output_location in [
        "https://example.com/x/",
        "s3://",
        "s3:///prefix",
        "bucket/prefix",
        "",
    ] {
        assert!(
            !is_valid_output_location(output_location),
            "通ってしまった: {output_location:?}"
        );
    }
    assert!(is_valid_output_location("s3://bucket"));
}

#[test]
fn 文の先頭で置くファイルの種類を決める() {
    for (query, file) in [
        ("SELECT 1", ResultFile::Csv),
        ("  with t AS (SELECT 1) SELECT * FROM t", ResultFile::Csv),
        ("(SELECT 1) UNION (SELECT 2)", ResultFile::Csv),
        // `(` の直後に空白や改行があっても同じ（#64 のレビューで見つかった）。
        ("( SELECT 1 ) UNION ( SELECT 2 )", ResultFile::Csv),
        (
            "(\n  SELECT 1\n) UNION ALL (\n  SELECT 2\n)",
            ResultFile::Csv,
        ),
        ("VALUES 1", ResultFile::Csv),
        // `TABLE t` も SELECT と同じ `<id>.csv`（2026-09-22 実測。#65）。
        ("TABLE t", ResultFile::Csv),
        ("-- c\ntable db.t LIMIT 1", ResultFile::Csv),
        ("INSERT INTO t VALUES (1)", ResultFile::Manifest),
        // UPDATE / DELETE / MERGE は INSERT と違い .csv になる（Iceberg のテーブルで実測。
        // UPDATE と DELETE は 2026-09-17、MERGE は 2026-09-20。#35）。
        ("update t SET a = 1", ResultFile::Csv),
        ("DELETE FROM t", ResultFile::Csv),
        ("MERGE INTO t USING s ON t.id = s.id", ResultFile::Csv),
        ("DESCRIBE t", ResultFile::Text),
        ("VACUUM t", ResultFile::Csv),
        ("OPTIMIZE t REWRITE DATA USING BIN_PACK", ResultFile::Table),
        ("CREATE TABLE c AS SELECT 1 AS i", ResultFile::Table),
        (
            "CREATE TABLE db.c WITH (format = 'PARQUET') AS SELECT 1 AS i",
            ResultFile::Table,
        ),
        ("create or replace table c as (select 1)", ResultFile::Table),
        ("CREATE TABLE t (i int)", ResultFile::Text),
        ("CREATE DATABASE IF NOT EXISTS db", ResultFile::Text),
        ("CREATE VIEW v AS SELECT 1", ResultFile::Text),
        ("DROP TABLE t", ResultFile::Text),
        ("SHOW TABLES IN db", ResultFile::Text),
        ("", ResultFile::Text),
        // 先頭のコメントは読み飛ばして判定する（2026-09-18 実測）。
        ("-- c\nSELECT 1", ResultFile::Csv),
        ("/* c */ SHOW TABLES", ResultFile::Text),
        ("-- c\nCREATE TABLE c AS SELECT 1 AS i", ResultFile::Table),
        (
            "-- c\nCREATE TABLE c WITH (table_type = 'ICEBERG') AS SELECT 1 AS i",
            ResultFile::Table,
        ),
    ] {
        assert_eq!(ResultFile::of(query), file, "{query:?}");
    }
}

#[test]
fn キーワードの間のコメントは空白として読んで判定する() {
    // 本物はキーワードとキーワードの間のコメントを空白として扱い、`CREATE /* c */ TABLE ... AS`
    // も `CREATE TABLE ... AS /* c */ SELECT` も `tables/<id>` に置いた（2026-09-22 実測。#52。
    // 成功する Iceberg の CTAS と、存在しないテーブルを読んで失敗する CTAS の両方で同じ）。
    for (query, file) in [
        ("CREATE /* c */ TABLE c AS SELECT 1 AS i", ResultFile::Table),
        ("CREATE -- c\nTABLE c AS SELECT 1 AS i", ResultFile::Table),
        ("CREATE TABLE /* c */ c AS SELECT 1 AS i", ResultFile::Table),
        ("CREATE TABLE c /* c */ AS SELECT 1 AS i", ResultFile::Table),
        ("CREATE TABLE c AS /* c */ SELECT 1 AS i", ResultFile::Table),
        ("CREATE TABLE c AS -- c\nSELECT 1 AS i", ResultFile::Table),
        ("CREATE/* c */TABLE c AS SELECT 1 AS i", ResultFile::Table),
        ("CREATE /* c */ TABLE t (i int)", ResultFile::Text),
        ("DROP /* c */ TABLE t", ResultFile::Text),
        ("SELECT /* c */ 1", ResultFile::Csv),
        ("INSERT /* c */ INTO t VALUES (1)", ResultFile::Manifest),
        // 文字列リテラルの中の `--` や `/*` はコメントではない（計画攻撃で見つかった退行。
        // S3 Express のバケット名 `a--b--x-s3` を external_location に書いた 1 行の CTAS）。
        (
            "CREATE TABLE t WITH (external_location = 's3://a--b--x-s3/p/') AS SELECT 1",
            ResultFile::Table,
        ),
        (
            "CREATE TABLE t WITH (external_location = 's3://b/*/') AS SELECT 1",
            ResultFile::Table,
        ),
    ] {
        assert_eq!(ResultFile::of(query), file, "{query:?}");
    }
}

#[test]
fn ctas_は_iceberg_でも_tables_を付ける() {
    // 2026-09-19 実測。本物の Iceberg テーブル（`SHOW CREATE TABLE` で
    // `'table_type'='iceberg'` を確認）の CTAS も `tables/<id>` だった。
    for query in [
        "CREATE TABLE c AS SELECT 1 AS i",
        "CREATE TABLE c WITH (format = 'PARQUET') AS SELECT 1 AS i",
        "CREATE TABLE c WITH (table_type = 'ICEBERG') AS SELECT 1 AS i",
        "CREATE TABLE c WITH (table_type='ICEBERG',location='s3://b/p') AS SELECT 1 AS i",
        "create or replace table c with (table_type = 'iceberg') as (select 1)",
        // table_type='ICEBERG' がコメント・文字列リテラル・WITH 句の外にある CTAS も、
        // 本物は Hive のまま `tables/<id>` に置いた（2026-09-19 実測。#26）。
        "CREATE TABLE c AS SELECT 1 AS i -- table_type = 'ICEBERG'",
        "/* table_type = 'ICEBERG' */ CREATE TABLE c AS SELECT 1 AS i",
        "CREATE TABLE c AS SELECT 'table_type=''ICEBERG''' AS s",
        "CREATE TABLE c AS SELECT * FROM t WHERE t.table_type = 'ICEBERG'",
    ] {
        assert_eq!(ResultFile::of(query), ResultFile::Table, "{query:?}");
    }
    // CTAS でなければ table_type があっても .txt のまま。
    assert_eq!(
        ResultFile::of("CREATE TABLE c (i int) WITH (table_type = 'ICEBERG')"),
        ResultFile::Text
    );
}

#[test]
fn insert_はテーブルの形式でも更新件数でも_拡張子なしの_id_のまま() {
    // 2026-09-20 実測（#35）。Hive のテーブルへの INSERT、本物の Iceberg テーブル
    // （`SHOW CREATE TABLE` で `'table_type'='iceberg'` を確認）への INSERT、1 行も
    // 入らない INSERT、型が合わずに FAILED になる INSERT のどれも `<prefix><id>` だった。
    // 同じラウンドで測った SELECT（`<id>.csv`）・CTAS（`tables/<id>`）・SHOW（`<id>.txt`）とも
    // 食い違っていない。これは 2026-09-17 の 1 ラウンドで採った値の再実測で、同じラウンドの
    // CTAS は #26 で覆ったが、INSERT は再現した。だからテーブルの形式を SQL から読み取る
    // 判定を足してはいけない（#26 で一度入れて消した）。
    for query in [
        "INSERT INTO hive_table VALUES (2, 'y')",
        "INSERT INTO iceberg_table VALUES (2, 'y')",
        "INSERT INTO t SELECT * FROM (VALUES (3, 'z')) AS s(n, v) WHERE s.n < 0",
        "insert into t values ('not_an_int', 'y')",
        "-- table_type = 'ICEBERG'\nINSERT INTO t VALUES (1)",
    ] {
        assert_eq!(ResultFile::of(query), ResultFile::Manifest, "{query:?}");
    }
}
