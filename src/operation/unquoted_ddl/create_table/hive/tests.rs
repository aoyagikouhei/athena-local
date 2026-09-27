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
/// 句（COMMENT・PARTITIONED BY・CLUSTERED BY・ROW FORMAT）とその組み合わせ・IF NOT EXISTS・列の並び無し・
/// バッククォートの名前でも同じ（2026-09-27 実測 v0〜v9。#266）。
#[test]
fn location_の無い_external_は本物の文言で弾く() {
    for query in [
        "CREATE EXTERNAL TABLE t (n int)",
        "CREATE EXTERNAL TABLE awsdatacatalog.db.t (n int)",
        "CREATE EXTERNAL TABLE ns.t (n int)",
        "CREATE EXTERNAL TABLE AwsDataCatalog.db.t (n int)",
        "CREATE EXTERNAL TABLE t (n int) STORED AS PARQUET",
        "CREATE EXTERNAL TABLE t (n int) TBLPROPERTIES ('a'='b')",
        "CREATE EXTERNAL TABLE t (n int) COMMENT 'x'",
        "CREATE EXTERNAL TABLE t (n int) PARTITIONED BY (p string)",
        "CREATE EXTERNAL TABLE t (n int) CLUSTERED BY (n) INTO 4 BUCKETS",
        "CREATE EXTERNAL TABLE t (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe'",
        "CREATE EXTERNAL TABLE t (n int) ROW FORMAT DELIMITED FIELDS TERMINATED BY ','",
        "CREATE EXTERNAL TABLE t (n int) COMMENT 'x' PARTITIONED BY (p string) STORED AS PARQUET",
        "CREATE EXTERNAL TABLE IF NOT EXISTS t (n int)",
        "CREATE EXTERNAL TABLE t TBLPROPERTIES ('a'='b')",
        "CREATE EXTERNAL TABLE `t` (n int)",
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
/// n21・列名の location n26・文字列の中の LOCATION n27）と、測っていない形（2 部以上のバッククォートの名前など）は
/// None（今までどおり構文チェックに任せる）。
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

/// `s3_tables_failure` の理由と ErrorType。
fn failure(query: &str) -> Option<(String, i32)> {
    s3_tables_failure(query).map(|failure| (failure.reason, failure.error_type))
}

const STORED_AS: &str = "Iceberg create table statement does not allow STORED AS/BY";
const ROW_FORMAT: &str = "Iceberg create table statement does not allow ROW FORMAT";
const CLUSTERED_BY: &str = "Iceberg create table statement does not allow CLUSTERED BY";
const PARTITIONED_BY: &str = "Invalid PARTITIONED BY clause in Iceberg create table statement";
const NO_COLUMN: &str = "At least one column is required for Iceberg create table statement";
const SERDE: &str = "ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'";

/// LOCATION の無い `CREATE TABLE <名前> [(列)] STORED AS <語>` は、本物は開始してから FAILED にした（2026-09-26 実測
/// n21・2026-09-27 実測 s15。#248）。2 部・大文字混じりの `AwsDataCatalog` の 3 部・IF NOT EXISTS・COMMENT・
/// PARTITIONED BY・TBLPROPERTIES・バッククォート・列の並び無しでも同じ（2026-09-27 実測 w0〜w2・w4〜w6・w8〜w10。#266）。
#[test]
fn location_の無い_stored_as_は開始して失敗させる() {
    for query in [
        "CREATE TABLE t (n int) STORED AS PARQUET",
        "CREATE TABLE t (n int) STORED AS ORC",
        "  create table t (n int, m array<int>) stored as orc\n",
        "CREATE TABLE IF NOT EXISTS t (n int) STORED AS PARQUET",
        "CREATE TABLE ns.t (n int) STORED AS PARQUET",
        "CREATE TABLE AwsDataCatalog.ns.t (n int) STORED AS PARQUET",
        "CREATE TABLE `t` (n int) STORED AS PARQUET",
        "CREATE TABLE t STORED AS PARQUET",
        "CREATE TABLE t (n int) COMMENT 'x' STORED AS PARQUET",
        "CREATE TABLE t (n int) PARTITIONED BY (p string) STORED AS PARQUET",
        "CREATE TABLE t (n int) STORED AS PARQUET TBLPROPERTIES ('a'='b')",
    ] {
        assert_eq!(
            failure(query),
            Some((STORED_AS.to_string(), 1200)),
            "{query}"
        );
    }
}

/// ROW FORMAT（SERDE・DELIMITED）・CLUSTERED BY・型付きの PARTITIONED BY・未知のキー 1 つの TBLPROPERTIES も、本物は開始して
/// FAILED にした。名前の形（2 部・`AwsDataCatalog` の 3 部・バッククォート）・IF NOT EXISTS・COMMENT・列の並び無しによらない
/// （2026-09-26 実測 vc4・z6〜z17、2026-09-27 実測 cl1・pn1〜pn5・pa4。#270）。
#[test]
fn location_の無い_hive_の句は句ごとの文言で開始して失敗させる() {
    let row_format = Some((ROW_FORMAT.to_string(), 1200));
    let clustered = Some((CLUSTERED_BY.to_string(), 1200));
    let partitioned = Some((PARTITIONED_BY.to_string(), 1006));
    let unknown_key = Some(("Unsupported table property key: a270".to_string(), 1200));
    for (query, expected) in [
        (format!("CREATE TABLE t (n int) {SERDE}"), &row_format),
        (
            "CREATE TABLE t (n int) ROW FORMAT DELIMITED FIELDS TERMINATED BY ','".to_string(),
            &row_format,
        ),
        (
            format!("CREATE TABLE t (n int) COMMENT 't comment' {SERDE}"),
            &row_format,
        ),
        (format!("CREATE TABLE ns.t (n int) {SERDE}"), &row_format),
        (
            format!("CREATE TABLE IF NOT EXISTS t (n int) {SERDE}"),
            &row_format,
        ),
        (
            format!("CREATE TABLE AwsDataCatalog.ns.t (n int) {SERDE}"),
            &row_format,
        ),
        (format!("CREATE TABLE t {SERDE}"), &row_format),
        (format!("CREATE TABLE `t` (n int) {SERDE}"), &row_format),
        (
            "CREATE TABLE t (n int) CLUSTERED BY (n) INTO 4 BUCKETS".to_string(),
            &clustered,
        ),
        (
            "CREATE TABLE AwsDataCatalog.ns.t (n int) CLUSTERED BY (n) INTO 4 BUCKETS".to_string(),
            &clustered,
        ),
        (
            "CREATE TABLE t CLUSTERED BY (n) INTO 4 BUCKETS".to_string(),
            &clustered,
        ),
        (
            "CREATE TABLE t (n int) PARTITIONED BY (p int)".to_string(),
            &partitioned,
        ),
        (
            "CREATE TABLE t (n int) PARTITIONED BY (n int)".to_string(),
            &partitioned,
        ),
        (
            "CREATE TABLE ns.t (n int) PARTITIONED BY (p int)".to_string(),
            &partitioned,
        ),
        (
            "CREATE TABLE `t` (n int) PARTITIONED BY (p int)".to_string(),
            &partitioned,
        ),
        (
            "CREATE TABLE t (n int) COMMENT 't comment' PARTITIONED BY (p int)".to_string(),
            &partitioned,
        ),
        (
            "CREATE TABLE t (n int) TBLPROPERTIES ('a270'='b')".to_string(),
            &unknown_key,
        ),
        (
            "CREATE TABLE IF NOT EXISTS t (n int) TBLPROPERTIES ('a270'='b')".to_string(),
            &unknown_key,
        ),
        (
            "CREATE TABLE t (n int) TBLPROPERTIES ('table_type'='ICEBERG', 'a270'='b')".to_string(),
            &unknown_key,
        ),
        (
            "CREATE TABLE t (n int) TBLPROPERTIES ('a270'='b', 'table_type'='ICEBERG')".to_string(),
            &unknown_key,
        ),
        (
            "CREATE TABLE t TBLPROPERTIES ('a270'='b')".to_string(),
            &Some((NO_COLUMN.to_string(), 1006)),
        ),
    ] {
        assert_eq!(&failure(&query), expected, "{query}");
    }
}

/// 句が 2 つ以上あれば CLUSTERED BY > ROW FORMAT > STORED AS > 型付きの PARTITIONED BY > 未知のキーの TBLPROPERTIES の順に
/// 1 つを選ぶ（2026-09-26 実測 w7・w8・z10、2026-09-27 実測 pr1〜pr9。5 句の 10 対すべて。#270）。
#[test]
fn 句が複数あれば実測の優先順で_1_つ選ぶ() {
    for (clauses, expected) in [
        (
            format!("CLUSTERED BY (n) INTO 4 BUCKETS {SERDE}"),
            CLUSTERED_BY,
        ),
        (
            "CLUSTERED BY (n) INTO 4 BUCKETS STORED AS PARQUET".to_string(),
            CLUSTERED_BY,
        ),
        (
            "PARTITIONED BY (p int) CLUSTERED BY (n) INTO 4 BUCKETS".to_string(),
            CLUSTERED_BY,
        ),
        (
            "CLUSTERED BY (n) INTO 4 BUCKETS TBLPROPERTIES ('a270'='b')".to_string(),
            CLUSTERED_BY,
        ),
        (format!("PARTITIONED BY (p int) {SERDE}"), ROW_FORMAT),
        (format!("{SERDE} STORED AS TEXTFILE"), ROW_FORMAT),
        (format!("{SERDE} TBLPROPERTIES ('a270'='b')"), ROW_FORMAT),
        (
            format!("{SERDE} TBLPROPERTIES ('table_type'='ICEBERG')"),
            ROW_FORMAT,
        ),
        (
            "PARTITIONED BY (p int) STORED AS PARQUET".to_string(),
            STORED_AS,
        ),
        (
            "STORED AS PARQUET TBLPROPERTIES ('a270'='b')".to_string(),
            STORED_AS,
        ),
        (
            "PARTITIONED BY (p int) TBLPROPERTIES ('a270'='b')".to_string(),
            PARTITIONED_BY,
        ),
        (
            format!(
                "PARTITIONED BY (p int) CLUSTERED BY (n) INTO 4 BUCKETS {SERDE} STORED AS PARQUET TBLPROPERTIES ('a270'='b')"
            ),
            CLUSTERED_BY,
        ),
    ] {
        let query = format!("CREATE TABLE t (n int) {clauses}");
        assert_eq!(
            failure(&query).map(|(reason, _)| reason).as_deref(),
            Some(expected),
            "{query}"
        );
    }
}

/// 列の並びが無ければ、型付きの PARTITIONED BY の後で `At least one column ...`（句が無い・受理されるキーだけ・COMMENT だけ
/// でも。2026-09-27 実測 pn6・c1〜c4）。未知のキーは最初の 1 つを書いた綴りのまま出す（k6〜k8）。#270。
#[test]
fn 列の並び無しと未知のキーは本物の順と綴りで失敗させる() {
    for (query, reason) in [
        ("CREATE TABLE t", NO_COLUMN),
        (
            "CREATE TABLE t TBLPROPERTIES ('table_type'='ICEBERG')",
            NO_COLUMN,
        ),
        ("CREATE TABLE t COMMENT 't comment'", NO_COLUMN),
        ("CREATE TABLE t PARTITIONED BY (p int)", PARTITIONED_BY),
        (
            "CREATE TABLE t (n int) TBLPROPERTIES ('classification'='csv')",
            "Unsupported table property key: classification",
        ),
        (
            "CREATE TABLE t (n int) TBLPROPERTIES ('a270x'='b', 'a270y'='c')",
            "Unsupported table property key: a270x",
        ),
        (
            "CREATE TABLE t (n int) TBLPROPERTIES ('format'='parquet', 'A270'='b')",
            "Unsupported table property key: A270",
        ),
    ] {
        assert_eq!(
            failure(query).map(|(reason, _)| reason).as_deref(),
            Some(reason),
            "{query}"
        );
    }
}

/// 失敗させない形。LOCATION・EXTERNAL は開始時の判定（`s3_tables_rejection`）、ちょうど小文字の `awsdatacatalog` の 3 部は
/// 2 catalogs（w3・a1〜a4）、本物が受理した形（Iceberg の書き方の PARTITIONED BY・受理されるキー・COMMENT だけ。cl0・vc1・
/// pa1〜pa3・tp1〜tp5・k1〜k4）と、文書にあるが測っていないキーは Trino の構文チェックに任せる。ほかのカタログの 3 部は測っていない。
#[test]
fn 失敗させない形と測っていない形は判定しない() {
    for query in [
        "CREATE TABLE t (n int) STORED AS PARQUET LOCATION 's3://b/p/'",
        "CREATE EXTERNAL TABLE t (n int) STORED AS PARQUET",
        "CREATE EXTERNAL TABLE t (n int) ROW FORMAT SERDE 'x'",
        "CREATE TABLE awsdatacatalog.ns.t (n int) STORED AS PARQUET",
        "CREATE TABLE hive.ns.t (n int) STORED AS PARQUET",
        "CREATE TABLE hive.ns.t (n int) ROW FORMAT SERDE 'x'",
        "CREATE TABLE t (n int)",
        "CREATE TABLE t (n int) COMMENT 't comment'",
        "CREATE TABLE t (n int) PARTITIONED BY (n)",
        "CREATE TABLE t (n int, s string) PARTITIONED BY (bucket(4, n))",
        "CREATE TABLE t (n int) TBLPROPERTIES ('table_type'='ICEBERG')",
        "CREATE TABLE t (n int) TBLPROPERTIES ('TABLE_TYPE'='ICEBERG')",
        "CREATE TABLE t (n int) TBLPROPERTIES ('format'='parquet')",
        "CREATE TABLE t (n int) TBLPROPERTIES ('write_compression'='zstd')",
        "CREATE TABLE t (n int) TBLPROPERTIES ('vacuum_max_snapshot_age_seconds'='432000')",
        "CREATE TABLE t (n int) TBLPROPERTIES ('vacuum_min_snapshots_to_keep'='1')",
        "CREATE TABLE t (n int) TBLPROPERTIES ('optimize_rewrite_delete_file_threshold'='2')",
        "CREATE TABLE t (n int) TBLPROPERTIES ('write_target_data_file_size_bytes'='536870912')",
        "CREATE TABLE t (n int) TBLPROPERTIES ('optimize_rewrite_data_file_threshold'='5')",
        "CREATE TABLE t (n int) TBLPROPERTIES ('vacuum_max_metadata_files_to_keep'='100')",
        "CREATE TABLE t (n int) TBLPROPERTIES ('write_data_path_enabled'='true')",
    ] {
        assert_eq!(failure(query), None, "{query}");
    }
}

/// `table_type` が `ICEBERG` 以外なら、本物は句・列の並び・ちょうど小文字の `awsdatacatalog` の 3 部によらず開始時に
/// `Only ICEBERG ...` で弾いた（2026-09-27 実測 tp6・v1〜v6・a5・m7）。`write_compression` の無い `compression_level` は
/// `Compression codec must be defined ...`（k5）。#270。
#[test]
fn table_type_が_iceberg_以外と_compression_level_だけは開始時に弾く() {
    let only_iceberg = Some("Only ICEBERG table format is supported with S3 table buckets");
    for query in [
        "CREATE TABLE t (n int) TBLPROPERTIES ('table_type'='HIVE')",
        "CREATE TABLE t (n int) TBLPROPERTIES ('table_type'='hive')",
        "CREATE TABLE t (n int) TBLPROPERTIES ('table_type'='DELTA')",
        "CREATE TABLE t (n int) ROW FORMAT SERDE 'x' TBLPROPERTIES ('table_type'='HIVE')",
        "CREATE TABLE t (n int) PARTITIONED BY (p int) TBLPROPERTIES ('table_type'='HIVE')",
        "CREATE TABLE t (n int) TBLPROPERTIES ('table_type'='HIVE', 'a270'='b')",
        "CREATE TABLE t TBLPROPERTIES ('table_type'='HIVE')",
        "CREATE TABLE awsdatacatalog.ns.t (n int) TBLPROPERTIES ('table_type'='HIVE')",
        "CREATE TABLE nope.t (n int) TBLPROPERTIES ('table_type'='HIVE')",
    ] {
        assert_eq!(s3_tables_rejection(query), only_iceberg, "{query}");
    }
    assert_eq!(
        s3_tables_rejection("CREATE TABLE t (n int) TBLPROPERTIES ('compression_level'='3')"),
        Some("Compression codec must be defined when compression_level property is specified.")
    );
    for query in [
        "CREATE TABLE t (n int) TBLPROPERTIES ('table_type'='ICEBERG')",
        "CREATE TABLE t (n int) TBLPROPERTIES ('table_type'='iceberg')",
        "CREATE TABLE t (n int) TBLPROPERTIES ('write_compression'='zstd', 'compression_level'='3')",
    ] {
        assert_eq!(s3_tables_rejection(query), None, "{query}");
    }
}

/// 1 部目がちょうど小文字の `awsdatacatalog` の 3 部の STORED AS は、本物は開始時に `Unsupported ddl with 2 catalogs: <文>`
/// （前後の空白を落とした文）で弾いた（2026-09-26 実測 w3。#270）。大文字混じりの綴り・LOCATION・EXTERNAL・2 部は対象外。
#[test]
fn 小文字の_awsdatacatalog_の_3_部の_stored_as_は_2_catalogs_で弾く() {
    assert_eq!(
        s3_tables_two_catalogs("  CREATE TABLE awsdatacatalog.ns.t (n int) STORED AS PARQUET\n")
            .as_deref(),
        Some(
            "Unsupported ddl with 2 catalogs: CREATE TABLE awsdatacatalog.ns.t (n int) STORED AS PARQUET"
        )
    );
    for query in [
        "CREATE TABLE AwsDataCatalog.ns.t (n int) STORED AS PARQUET",
        "CREATE TABLE awsdatacatalog.ns.t (n int) STORED AS PARQUET LOCATION 's3://b/p/'",
        "CREATE EXTERNAL TABLE awsdatacatalog.ns.t (n int) STORED AS PARQUET",
        "CREATE TABLE ns.t (n int) STORED AS PARQUET",
        "CREATE TABLE awsdatacatalog.ns.t (n int)",
    ] {
        assert_eq!(s3_tables_two_catalogs(query), None, "{query}");
    }
}

/// LOCATION 付きの Hive の `CREATE TABLE` の無引用の 3 部の名前の 1 部目（`awsdatacatalog` の類を除く）。本物は
/// 実在しないカタログなら Context によらず `DATACATALOG_NOT_FOUND` で弾いた（2026-09-26 実測 n6・2026-09-27 実測
/// s12・s13。#248）。EXTERNAL・IF NOT EXISTS・句（1 つ・全部）・列の並び無しでも同じ（2026-09-27 実測 t0〜t10・
/// t0s〜t9s。#266）。
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
            Some("nosuch"),
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
            Some("nosuch"),
        ),
        (
            "CREATE TABLE nosuch.db.t (n int) COMMENT 'c' LOCATION 's3://b/p/'",
            Some("nosuch"),
        ),
        (
            "CREATE TABLE nosuch.db.t (n int) STORED AS PARQUET LOCATION 's3://b/p/'",
            Some("nosuch"),
        ),
        (
            "CREATE TABLE nosuch.db.t (n int) LOCATION 's3://b/p/' TBLPROPERTIES ('a'='b')",
            Some("nosuch"),
        ),
        (
            "CREATE TABLE nosuch.db.t LOCATION 's3://b/p/'",
            Some("nosuch"),
        ),
        (
            "CREATE EXTERNAL TABLE IF NOT EXISTS nosuch.db.t (n int) COMMENT 'c' PARTITIONED BY (p string) \
             CLUSTERED BY (n) INTO 4 BUCKETS ROW FORMAT SERDE 'x' STORED AS PARQUET LOCATION 's3://b/p/' \
             TBLPROPERTIES ('a'='b')",
            Some("nosuch"),
        ),
    ] {
        assert_eq!(location_catalog(query), catalog, "{query}");
    }
}
