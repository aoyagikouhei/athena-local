//! hive.rs のユニットテスト。期待値は本物の実測（2026-09-26 n1〜n32。#229、2026-09-27 s1〜s18。#248、
//! `tools/measure/unquoted-ddl.sh`）の形を、実名を伏せた短い名前に当てたもの。

use super::*;

/// 本物は Hive の `CREATE TABLE` として読める文の LOCATION を `Table location can not be specified ...` で弾く。
/// 1〜3 部の名前（3 部は 1 部目が大文字小文字によらず `awsdatacatalog`）・EXTERNAL・IF NOT EXISTS・小文字・
/// コメント・PARTITIONED BY・ROW FORMAT と STORED AS・後ろの TBLPROPERTIES・列の並び無しで同じ
/// （2026-09-26 実測 i14・i15・n1〜n5・n10・n19・n20・n23〜n25・n28・n30・n32。#229）。表の COMMENT・CLUSTERED BY・
/// ROW FORMAT SERDE・DELIMITED の区切りの句・TBLPROPERTIES の 2 組・バッククォートの表名・STORED AS PARQUET でも
/// 同じ（2026-09-27 実測 s1〜s6・s11・s16。#248）。
#[test]
fn hive_の_create_table_の_location_は本物の文言で弾く() {
    for query in [
        "CREATE TABLE awsdatacatalog.db.t (n int) LOCATION 's3://b/p/'",
        "CREATE TABLE t (n int) LOCATION 's3://b/p/'",
        "CREATE TABLE ns.t (n int) LOCATION 's3://b/p/'",
        "CREATE TABLE AwsDataCatalog.db.t (n int) LOCATION 's3://b/p/'",
        "CREATE EXTERNAL TABLE awsdatacatalog.db.t (n int) LOCATION 's3://b/p/'",
        "CREATE EXTERNAL TABLE t (n int) LOCATION 's3://b/p/'",
        "CREATE EXTERNAL TABLE db.t (n int) LOCATION 's3://b/p/'",
        "CREATE TABLE t (n int) PARTITIONED BY (p string) LOCATION 's3://b/p/'",
        "CREATE TABLE t (n int) ROW FORMAT DELIMITED FIELDS TERMINATED BY ',' STORED AS TEXTFILE \
         LOCATION 's3://b/p/' TBLPROPERTIES ('a'='b')",
        "CREATE TABLE IF NOT EXISTS t (n int) LOCATION 's3://b/p/'",
        "create table t (n int) location 's3://b/p/'",
        "CREATE TABLE t (n int) /* c */ LOCATION 's3://b/p/'",
        "CREATE TABLE t LOCATION 's3://b/p/'",
        "  CREATE TABLE t (n int, m array<int>) LOCATION 's3://b/p/'\n",
        "CREATE TABLE t (n int) COMMENT 't comment' LOCATION 's3://b/p/'",
        "CREATE TABLE t (n int) CLUSTERED BY (n) INTO 4 BUCKETS LOCATION 's3://b/p/'",
        "CREATE TABLE t (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde' \
         LOCATION 's3://b/p/'",
        "CREATE TABLE t (n int) ROW FORMAT DELIMITED FIELDS TERMINATED BY ',' \
         LINES TERMINATED BY '\\n' LOCATION 's3://b/p/'",
        "CREATE TABLE t (n map<string,string>) ROW FORMAT DELIMITED COLLECTION ITEMS TERMINATED BY ',' \
         MAP KEYS TERMINATED BY ':' NULL DEFINED AS 'N' LOCATION 's3://b/p/'",
        "CREATE TABLE t (n int) LOCATION 's3://b/p/' TBLPROPERTIES ('a'='b', 'c'='d')",
        "CREATE TABLE `t` (n int) LOCATION 's3://b/p/'",
        "CREATE TABLE t (n int) STORED AS PARQUET LOCATION 's3://b/p/'",
    ] {
        assert_eq!(
            s3_tables_rejection(query),
            Some(S3_TABLES_LOCATION),
            "{query}"
        );
    }
}

/// LOCATION の無い `CREATE EXTERNAL TABLE` は `External keyword not supported ...`。1 部目がちょうど小文字の
/// `awsdatacatalog` の 3 部でも 2 catalogs より先（2026-09-26 実測 n11・n12。#229）。2 部・大文字混じりの
/// `AwsDataCatalog` の 3 部・STORED AS 付き・TBLPROPERTIES 付きでも同じ（2026-09-27 実測 s7〜s10。#248）。
#[test]
fn location_の無い_external_は本物の文言で弾く() {
    for query in [
        "CREATE EXTERNAL TABLE t (n int)",
        "CREATE EXTERNAL TABLE awsdatacatalog.db.t (n int)",
        "CREATE EXTERNAL TABLE ns.t (n int)",
        "CREATE EXTERNAL TABLE AwsDataCatalog.db.t (n int)",
        "CREATE EXTERNAL TABLE t (n int) STORED AS PARQUET",
        "CREATE EXTERNAL TABLE t (n int) TBLPROPERTIES ('a'='b')",
    ] {
        assert_eq!(
            s3_tables_rejection(query),
            Some(S3_TABLES_EXTERNAL),
            "{query}"
        );
    }
}

/// 本物も Hive の構文で読めずに Trino の構文エラーを返した形（引用符付きの名前・4 部・NOT NULL・引用符付きの
/// 列名・後ろのごみ・引用符の無い値・値無し・LOCATION の前の TBLPROPERTIES。n7〜n9・n13〜n18・n22）、
/// 入れ子の型の列（s17・s18）、別の文言か開始して決まる形（実在しないカタログ n6・LOCATION の無い STORED AS
/// n21・列名の location n26・文字列の中の LOCATION n27）と、測っていない形（LOCATION の無い EXTERNAL に COMMENT
/// などが付く形、2 部以上のバッククォートの名前など）は None（今までどおり構文チェックに任せる）。
#[test]
fn hive_の構文で読めない形と測っていない形は判定しない() {
    for query in [
        r#"CREATE TABLE "s3tablescatalog/b".ns.t (n int) LOCATION 's3://b/p/'"#,
        r#"CREATE TABLE "t" (n int) LOCATION 's3://b/p/'"#,
        "CREATE TABLE a.b.c.t (n int) LOCATION 's3://b/p/'",
        "CREATE TABLE t (n int NOT NULL) LOCATION 's3://b/p/'",
        r#"CREATE TABLE t ("n" int) LOCATION 's3://b/p/'"#,
        "CREATE TABLE t (n int) LOCATION 's3://b/p/' garbage",
        "CREATE TABLE t (n int) LOCATION s3path",
        "CREATE TABLE t (n int) LOCATION",
        "CREATE TABLE t (n int) TBLPROPERTIES ('table_type'='ICEBERG') LOCATION 's3://b/p/'",
        "CREATE TABLE nosuch.db.t (n int) LOCATION 's3://b/p/'",
        "CREATE TABLE t (n int) STORED AS PARQUET",
        "CREATE TABLE t (location string)",
        "CREATE TABLE t (n int) COMMENT 'LOCATION'",
        "CREATE TABLE t (n int)",
        "CREATE TABLE t (n int) LOCATION 1",
        "CREATE TABLE IF EXISTS t (n int) LOCATION 's3://b/p/'",
        "CREATE TABLE t (n int) PARTITIONED (p string) LOCATION 's3://b/p/'",
        "CREATE TABLE t (n int) STORED PARQUET LOCATION 's3://b/p/'",
        "CREATE EXTERNAL TABLE nosuch.db.t (n int)",
        "CREATE EXTERNAL TABLE t (n int) COMMENT 'x'",
        "CREATE EXTERNAL TABLE `t` (n int)",
        "CREATE TABLE `ns`.t (n int) LOCATION 's3://b/p/'",
        "CREATE TABLE t (c row(a int)) LOCATION 's3://b/p/'",
        "CREATE TABLE t (c array(row(a int))) LOCATION 's3://b/p/'",
        "CREATE VIEW v AS SELECT 1",
        "CREATE TABLE t AS SELECT 1",
        "SELECT 1",
    ] {
        assert_eq!(s3_tables_rejection(query), None, "{query}");
    }
}

/// LOCATION の無い `CREATE TABLE <1 部> (列) STORED AS <語>` は、本物は開始してから FAILED にした（2026-09-26 実測
/// n21・2026-09-27 実測 s15。#248）。
#[test]
fn location_の無い_stored_as_は開始して失敗させる() {
    for query in [
        "CREATE TABLE t (n int) STORED AS PARQUET",
        "CREATE TABLE t (n int) STORED AS ORC",
        "  create table t (n int, m array<int>) stored as orc\n",
    ] {
        assert!(s3_tables_stored_as(query), "{query}");
    }
    for query in [
        "CREATE TABLE t (n int) STORED AS PARQUET LOCATION 's3://b/p/'",
        "CREATE EXTERNAL TABLE t (n int) STORED AS PARQUET",
        "CREATE TABLE IF NOT EXISTS t (n int) STORED AS PARQUET",
        "CREATE TABLE ns.t (n int) STORED AS PARQUET",
        "CREATE TABLE `t` (n int) STORED AS PARQUET",
        "CREATE TABLE t STORED AS PARQUET",
        "CREATE TABLE t (n int) COMMENT 'x' STORED AS PARQUET",
        "CREATE TABLE t (n int) STORED AS PARQUET TBLPROPERTIES ('a'='b')",
        "CREATE TABLE t (n int)",
    ] {
        assert!(!s3_tables_stored_as(query), "{query}");
    }
}

/// LOCATION 付きの Hive の `CREATE TABLE` の無引用の 3 部の名前の 1 部目（`awsdatacatalog` の類を除く）。本物は
/// 実在しないカタログなら Context によらず `DATACATALOG_NOT_FOUND` で弾いた（2026-09-26 実測 n6・2026-09-27 実測
/// s12・s13。#248）。測ったのは `(列) LOCATION '..'` だけの形で、EXTERNAL・IF NOT EXISTS・ほかの句・列の並び無しは None。
#[test]
fn location_付きの_3_部の名前の_1_部目を返す() {
    for (query, catalog) in [
        (
            "CREATE TABLE nosuch.db.t (n int) LOCATION 's3://b/p/'",
            Some("nosuch"),
        ),
        (
            "CREATE TABLE Hive248.db.t (n int) LOCATION 's3://b/p/'",
            Some("Hive248"),
        ),
        (
            "CREATE TABLE awsdatacatalog.db.t (n int) LOCATION 's3://b/p/'",
            None,
        ),
        (
            "CREATE TABLE AwsDataCatalog.db.t (n int) LOCATION 's3://b/p/'",
            None,
        ),
        ("CREATE TABLE nosuch.db.t (n int)", None),
        ("CREATE TABLE db.t (n int) LOCATION 's3://b/p/'", None),
        (
            "CREATE EXTERNAL TABLE nosuch.db.t (n int) LOCATION 's3://b/p/'",
            None,
        ),
        (
            r#"CREATE TABLE "nosuch".db.t (n int) LOCATION 's3://b/p/'"#,
            None,
        ),
        (
            "CREATE TABLE nosuch.db.t (n int NOT NULL) LOCATION 's3://b/p/'",
            None,
        ),
        (
            "CREATE TABLE nosuch.db.t (n int) LOCATION 's3://b/p/' garbage",
            None,
        ),
        (
            "CREATE TABLE IF NOT EXISTS nosuch.db.t (n int) LOCATION 's3://b/p/'",
            None,
        ),
        (
            "CREATE TABLE nosuch.db.t (n int) COMMENT 'c' LOCATION 's3://b/p/'",
            None,
        ),
        (
            "CREATE TABLE nosuch.db.t (n int) STORED AS PARQUET LOCATION 's3://b/p/'",
            None,
        ),
        (
            "CREATE TABLE nosuch.db.t (n int) LOCATION 's3://b/p/' TBLPROPERTIES ('a'='b')",
            None,
        ),
        ("CREATE TABLE nosuch.db.t LOCATION 's3://b/p/'", None),
    ] {
        assert_eq!(location_catalog(query), catalog, "{query}");
    }
}
