//! QueryExecutionContext の Catalog が S3 Tables のとき、本物の Athena が Hive の `CREATE TABLE` として読んでから
//! 開始時に弾く `LOCATION` と `EXTERNAL`（2026-09-26 実測 n1〜n32。#229）。Trino の文法にはどちらも無いので、
//! 構文チェックより前に呼ぶ。

use athena_sql::{Cursor, skip_leading_trivia};

use super::{ColumnOutcome, column};

/// S3 Tables の Context で LOCATION 付きの Hive の `CREATE TABLE` に本物が返す文言（位置なし）。
const S3_TABLES_LOCATION: &str =
    "Table location can not be specified for tables hosted in S3 table buckets";

/// S3 Tables の Context で LOCATION の無い `CREATE EXTERNAL TABLE` に本物が返す文言（位置なし）。
const S3_TABLES_EXTERNAL: &str = "External keyword not supported for table type ICEBERG";

/// 本物が Hive の `CREATE TABLE` として読んでから弾く文なら、その文言を返す。
///
/// 読むのは実測した形だけ: `CREATE [EXTERNAL] TABLE [IF NOT EXISTS] <名前> [(列)] [PARTITIONED BY (列)]
/// [ROW FORMAT DELIMITED FIELDS TERMINATED BY '...'] [STORED AS <語>] LOCATION '...' [TBLPROPERTIES ('k'='v')]`。
/// 名前は無引用の 1〜3 部（3 部は 1 部目が大文字小文字によらず `awsdatacatalog`。実在しないカタログは
/// DATACATALOG_NOT_FOUND が先で、ほかのカタログは測っていない）。LOCATION が無ければ、句の無い
/// `CREATE EXTERNAL TABLE <名前> (列)` の測った名前だけ External の文言。引用符付きの名前・列名、NOT NULL、
/// 句の順番の違い、後ろのごみは本物も Trino の構文エラーを返したので None にして構文チェックに任せる。
pub(in crate::operation) fn s3_tables_rejection(query: &str) -> Option<&'static str> {
    let sql = query.trim_start_matches([' ', '\t', '\r', '\n']);
    let mut cursor = Cursor::new(sql);
    if !cursor.keyword("CREATE") {
        return None;
    }
    let external = cursor.keyword("EXTERNAL");
    if !cursor.keyword("TABLE")
        || (cursor.keyword("IF") && !(cursor.keyword("NOT") && cursor.keyword("EXISTS")))
    {
        return None;
    }
    let name = cursor.qualified_name()?;
    // LOCATION の無い EXTERNAL を測ったのは 1 部（n11）と、1 部目がちょうど小文字の `awsdatacatalog` の 3 部（n12）
    // だけ。LOCATION 付きは 1〜3 部・大文字混じりの `AwsDataCatalog` まで測った（n1〜n5）。
    let external_measured = match name.parts.as_slice() {
        parts if parts.iter().any(|part| part.text.starts_with('"')) => return None,
        [_] => true,
        [_, _] => false,
        [catalog, _, _] if catalog.text.eq_ignore_ascii_case("awsdatacatalog") => {
            catalog.text == "awsdatacatalog"
        }
        _ => return None,
    };
    let statement_start = sql.len() - skip_leading_trivia(sql).len();
    let columns = cursor.punct(b'(');
    if columns && !column_list(sql, statement_start, &mut cursor) {
        return None;
    }
    if external && columns && cursor.at_end() {
        return external_measured.then_some(S3_TABLES_EXTERNAL);
    }
    if cursor.keyword("PARTITIONED")
        && !(cursor.keyword("BY")
            && cursor.punct(b'(')
            && column_list(sql, statement_start, &mut cursor))
    {
        return None;
    }
    if cursor.keyword("ROW")
        && !(["FORMAT", "DELIMITED", "FIELDS", "TERMINATED", "BY"]
            .iter()
            .all(|keyword| cursor.keyword(keyword))
            && string_literal(&mut cursor))
    {
        return None;
    }
    if cursor.keyword("STORED") && !(cursor.keyword("AS") && cursor.identifier()) {
        return None;
    }
    if !(cursor.keyword("LOCATION") && string_literal(&mut cursor)) {
        return None;
    }
    if cursor.keyword("TBLPROPERTIES")
        && !(cursor.punct(b'(')
            && string_literal(&mut cursor)
            && cursor.punct(b'=')
            && string_literal(&mut cursor)
            && cursor.punct(b')'))
    {
        return None;
    }
    cursor.at_end().then_some(S3_TABLES_LOCATION)
}

/// `(` の直後から列の並びを `)` の直後まで読む。文言が決まる形・実測していない形なら false。
fn column_list(sql: &str, statement_start: usize, cursor: &mut Cursor) -> bool {
    loop {
        match column(sql, statement_start, cursor) {
            ColumnOutcome::Next => {}
            ColumnOutcome::EndOfColumns => return true,
            ColumnOutcome::Rejected(_) | ColumnOutcome::Unmeasured => return false,
        }
    }
}

/// `'...'` を 1 つ読む（数・TRUE／FALSE は読まない）。
fn string_literal(cursor: &mut Cursor) -> bool {
    skip_leading_trivia(cursor.rest()).starts_with('\'') && cursor.literal()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 本物は Hive の `CREATE TABLE` として読める文の LOCATION を `Table location can not be specified ...` で弾く。
    /// 1〜3 部の名前（3 部は 1 部目が大文字小文字によらず `awsdatacatalog`）・EXTERNAL・IF NOT EXISTS・小文字・
    /// コメント・PARTITIONED BY・ROW FORMAT と STORED AS・後ろの TBLPROPERTIES・列の並び無しで同じ
    /// （2026-09-26 実測 i14・i15・n1〜n5・n10・n19・n20・n23〜n25・n28・n30・n32。#229）。
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
        ] {
            assert_eq!(
                s3_tables_rejection(query),
                Some(S3_TABLES_LOCATION),
                "{query}"
            );
        }
    }

    /// LOCATION の無い `CREATE EXTERNAL TABLE` は `External keyword not supported ...`。1 部目がちょうど小文字の
    /// `awsdatacatalog` の 3 部でも 2 catalogs より先（2026-09-26 実測 n11・n12。#229）。
    #[test]
    fn location_の無い_external_は本物の文言で弾く() {
        for query in [
            "CREATE EXTERNAL TABLE t (n int)",
            "CREATE EXTERNAL TABLE awsdatacatalog.db.t (n int)",
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
    /// 別の文言か開始して決まる形（実在しないカタログ n6・LOCATION の無い STORED AS n21・列名の location n26・
    /// 文字列の中の LOCATION n27）と、測っていない形（LOCATION の無い EXTERNAL の 2 部・大文字混じりの 3 部、
    /// TBLPROPERTIES の 2 組、表の COMMENT など）は None（今までどおり構文チェックに任せる）。
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
            "CREATE TABLE t (n int) COMMENT 'x' LOCATION 's3://b/p/'",
            "CREATE TABLE t (n int) LOCATION 's3://b/p/' TBLPROPERTIES ('a'='b', 'c'='d')",
            "CREATE TABLE IF EXISTS t (n int) LOCATION 's3://b/p/'",
            "CREATE TABLE t (n int) PARTITIONED (p string) LOCATION 's3://b/p/'",
            "CREATE TABLE t (n int) ROW FORMAT SERDE 'x' LOCATION 's3://b/p/'",
            "CREATE TABLE t (n int) STORED PARQUET LOCATION 's3://b/p/'",
            "CREATE EXTERNAL TABLE t (n int) STORED AS PARQUET",
            "CREATE EXTERNAL TABLE nosuch.db.t (n int)",
            "CREATE EXTERNAL TABLE db.t (n int)",
            "CREATE EXTERNAL TABLE AwsDataCatalog.db.t (n int)",
            "CREATE VIEW v AS SELECT 1",
            "CREATE TABLE t AS SELECT 1",
            "SELECT 1",
        ] {
            assert_eq!(s3_tables_rejection(query), None, "{query}");
        }
    }
}
