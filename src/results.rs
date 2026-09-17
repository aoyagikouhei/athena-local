//! 結果 CSV を S3 互換ストレージ（MinIO など）の OutputLocation に書く。
//! 置き場所・ファイル名・CSV の書式は 2026-09-14 に本番 Athena で実測したもの。

use std::time::Duration;

use reqwest::Url;
use reqwest::header::CONTENT_TYPE;
use rusty_s3::{Bucket, Credentials, S3Action, UrlStyle};

use crate::config::S3Settings;
use crate::convert;
use crate::trino::Outcome;

/// 署名付き URL の有効期限。作ってすぐ使うので短くてよい。
const SIGNATURE_EXPIRY: Duration = Duration::from_secs(60);

/// 本物の Athena が OutputLocation に置くファイルの種類。文の先頭で決まる。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResultFile {
    /// SELECT など。`<id>.csv` に結果を書く。UPDATE / DELETE / MERGE も名前はこれだが、結果は書かない
    /// （本物も `.csv.metadata` だけを置く）。
    Csv,
    /// INSERT。`<id>`（拡張子なし）。
    Manifest,
    /// CREATE TABLE AS SELECT。`tables/<id>`。
    Table,
    /// それ以外の DDL と SHOW など。`<id>.txt`。
    Text,
}

impl ResultFile {
    /// 先頭のキーワードで分ける。StatementType と同じく、先頭のコメントは考慮しない。
    pub fn of(query: &str) -> Self {
        let words: Vec<String> = query
            .split_whitespace()
            .map(|word| word.to_uppercase())
            .collect();
        let word = |index: usize| words.get(index).map(String::as_str).unwrap_or_default();

        match word(0).trim_start_matches('(') {
            "SELECT" | "WITH" | "VALUES" | "TABLE" | "UPDATE" | "DELETE" | "MERGE" | "VACUUM" => {
                Self::Csv
            }
            "INSERT" => Self::Manifest,
            // Athena の OPTIMIZE は CTAS と同じ扱い（Trino には無い文なので実行はできない）。
            "OPTIMIZE" => Self::Table,
            "CREATE" if is_create_table_as(&words) => Self::Table,
            _ => Self::Text,
        }
    }

    fn path(self, id: &str) -> String {
        match self {
            Self::Csv => format!("{id}.csv"),
            Self::Manifest => id.to_string(),
            Self::Table => format!("tables/{id}"),
            Self::Text => format!("{id}.txt"),
        }
    }

    /// PUT に付ける Content-Type。Text は 2026-09-16 実測（本物は octet-stream で、
    /// binary と application に割れていた。多数派を採る）。Csv は 0.3.0 からの値で実測していない。
    /// Manifest と Table は athena-local が書き込まないので、網羅のためだけの値。
    fn content_type(self) -> &'static str {
        match self {
            Self::Csv => "text/csv",
            Self::Text | Self::Manifest | Self::Table => "binary/octet-stream",
        }
    }
}

/// `CREATE [OR REPLACE] TABLE ... AS SELECT | WITH | (`。words は大文字にした単語の並び。
pub(crate) fn is_create_table_as(words: &[String]) -> bool {
    let rest = match words.get(1).map(String::as_str) {
        Some("OR") => &words[words.len().min(3)..],
        _ => &words[words.len().min(1)..],
    };
    if rest.first().map(String::as_str) != Some("TABLE") {
        return false;
    }

    rest.windows(2).any(|pair| {
        pair[0] == "AS"
            && (pair[1].starts_with("SELECT")
                || pair[1].starts_with("WITH")
                || pair[1].starts_with('('))
    })
}

/// 1 実行ぶんの置き場所。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResultLocation {
    pub bucket: String,
    pub key: String,
    pub file: ResultFile,
}

impl ResultLocation {
    /// OutputLocation（`s3://bucket/prefix`）と実行 ID から、本物と同じ置き場所を作る。
    /// prefix の末尾 `/` の有無は同じ場所になる。s3:// の形でなければ None。
    pub fn new(output_location: &str, id: &str, file: ResultFile) -> Option<Self> {
        let (bucket, prefix) = split_output_location(output_location)?;
        Some(Self {
            bucket: bucket.to_string(),
            key: format!("{prefix}{}", file.path(id)),
            file,
        })
    }

    /// GetQueryExecution の ResultConfiguration.OutputLocation に返すフルパス。
    pub fn uri(&self) -> String {
        format!("s3://{}/{}", self.bucket, self.key)
    }
}

/// OutputLocation として受け付ける形か。
pub fn is_valid_output_location(output_location: &str) -> bool {
    split_output_location(output_location).is_some()
}

/// `s3://bucket/prefix` を bucket と、末尾 `/` 付きの prefix（無ければ空）に分ける。
fn split_output_location(output_location: &str) -> Option<(&str, String)> {
    let rest = output_location.strip_prefix("s3://")?;
    let (bucket, prefix) = rest.split_once('/').unwrap_or((rest, ""));
    if bucket.is_empty() {
        return None;
    }

    let prefix = prefix.trim_end_matches('/');
    Some((
        bucket,
        match prefix {
            "" => String::new(),
            prefix => format!("{prefix}/"),
        },
    ))
}

/// 本物と同じ書式: 列名行を含め、NULL 以外の値はすべて `"` で囲む（中の `"` は二重にする）。
/// NULL は空、行末は `\n`（最終行にも付ける）、BOM は付けない。値の表記は GetQueryResults と同じ。
pub fn to_csv(outcome: &Outcome) -> Vec<u8> {
    let mut csv = String::new();

    for row in convert::all_rows(outcome) {
        let cells: Vec<String> = row
            .iter()
            .map(|cell| match cell {
                Some(value) => format!("\"{}\"", value.replace('"', "\"\"")),
                None => String::new(),
            })
            .collect();
        csv.push_str(&cells.join(","));
        csv.push('\n');
    }

    csv.into_bytes()
}

/// 本物と同じ書式: GetQueryResults の行（先頭の列名行は除く）を `\t` で連結し、`\n` でつなぐ。
/// NULL は空文字（CSV と違い引用符は付けない）。末尾に改行は付けない。行が無ければ空。
/// 値の表記（複合型・double・varbinary など）は to_csv と同じ。
pub fn to_text(outcome: &Outcome) -> Vec<u8> {
    convert::all_rows(outcome)
        .into_iter()
        .skip(1)
        .map(|row| {
            row.into_iter()
                .map(|cell| cell.unwrap_or_default())
                .collect::<Vec<String>>()
                .join("\t")
        })
        .collect::<Vec<String>>()
        .join("\n")
        .into_bytes()
}

/// S3 互換ストレージへの PUT。署名は rusty-s3 で URL に載せ、送るのは TLS なしの reqwest。
pub struct ResultWriter {
    http: reqwest::Client,
    endpoint: Url,
    credentials: Credentials,
    region: String,
}

impl ResultWriter {
    pub fn new(settings: &S3Settings) -> Self {
        Self {
            http: reqwest::Client::new(),
            endpoint: settings.endpoint.clone(),
            credentials: Credentials::new(
                settings.access_key_id.clone(),
                settings.secret_access_key.clone(),
            ),
            region: settings.region.clone(),
        }
    }

    /// 失敗の理由はそのまま StateChangeReason に載る。再試行はしない（ローカルでは即座に分かる方がよい）。
    pub async fn put(&self, location: &ResultLocation, body: Vec<u8>) -> Result<(), String> {
        let uri = location.uri();
        let bucket = Bucket::new(
            self.endpoint.clone(),
            UrlStyle::Path,
            location.bucket.clone(),
            self.region.clone(),
        )
        .map_err(|e| format!("結果の置き場所を組み立てられません: {uri}: {e}"))?;
        let url = bucket
            .put_object(Some(&self.credentials), &location.key)
            .sign(SIGNATURE_EXPIRY);

        let response = self
            .http
            .put(url)
            .header(CONTENT_TYPE, location.file.content_type())
            .body(body)
            .send()
            .await
            .map_err(|e| format!("結果を書き込めませんでした: {uri}: {e}"))?;

        let status = response.status();
        if status.is_success() {
            return Ok(());
        }
        let detail = response.text().await.unwrap_or_default();
        Err(format!(
            "結果を書き込めませんでした: {uri}: S3 が {status} を返しました: {detail}"
        ))
    }
}

#[cfg(test)]
mod tests {
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
        String::from_utf8(to_text(outcome)).expect("UTF-8 でない")
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
    fn to_text_は列名の行を入れない() {
        let outcome = Outcome {
            columns: vec![column("x", "integer", &scalar("integer"))],
            rows: vec![vec![Value::from(1)]],
            ..Outcome::default()
        };

        assert_eq!(text(&outcome), "1");
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
        assert_eq!(to_text(&ddl), Vec::<u8>::new());

        // DML / CTAS は update_count がある。
        let dml = Outcome {
            update_count: Some(1),
            ..Outcome::default()
        };
        assert_eq!(to_text(&dml), Vec::<u8>::new());
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
            let location = ResultLocation::new(output_location, "id", ResultFile::Csv).unwrap();
            assert_eq!(location.bucket, "bucket");
            assert_eq!(location.key, "a/b/id.csv");
            assert_eq!(location.uri(), "s3://bucket/a/b/id.csv");
        }
        for output_location in ["s3://bucket", "s3://bucket/"] {
            let location = ResultLocation::new(output_location, "id", ResultFile::Csv).unwrap();
            assert_eq!(location.uri(), "s3://bucket/id.csv");
        }
    }

    #[test]
    fn ファイル名は文の種類で変わる() {
        let uri = |file| {
            ResultLocation::new("s3://bucket/p/", "id", file)
                .unwrap()
                .uri()
        };
        assert_eq!(uri(ResultFile::Csv), "s3://bucket/p/id.csv");
        assert_eq!(uri(ResultFile::Manifest), "s3://bucket/p/id");
        assert_eq!(uri(ResultFile::Table), "s3://bucket/p/tables/id");
        assert_eq!(uri(ResultFile::Text), "s3://bucket/p/id.txt");
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
            ("VALUES 1", ResultFile::Csv),
            ("INSERT INTO t VALUES (1)", ResultFile::Manifest),
            // UPDATE / DELETE / MERGE は INSERT と違い .csv になる（Iceberg で実測）。
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
        ] {
            assert_eq!(ResultFile::of(query), file, "{query:?}");
        }
    }
}
