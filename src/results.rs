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
    /// （本物も `.csv.metadata` だけを置く。UPDATE と DELETE は 2026-09-17 実測、
    /// MERGE は 2026-09-20 実測。#35）。
    Csv,
    /// INSERT。`<id>`（拡張子なし）。テーブルの形式でも更新件数でも変わらない
    /// （Hive と Iceberg のテーブルへの INSERT、1 行も入らない INSERT のどれも `<id>` だった。
    /// 2026-09-17 実測、2026-09-20 に対照つきで再実測して再現。#35）。
    Manifest,
    /// CREATE TABLE AS SELECT。`tables/<id>`（2026-09-14 実測）。
    /// テーブルの形式では変わらない（Iceberg の CTAS も `tables/<id>`。2026-09-19 実測）。
    Table,
    /// それ以外の DDL と SHOW など。`<id>.txt`。
    Text,
    /// 結果ファイルの隣に置く付随ファイル `<結果ファイル名>.metadata`。
    /// `of` は返さない（文の種類では決まらない）。キーは `ResultLocation::metadata` だけが作る。
    Metadata,
    /// 失敗した文に置く `<id>.txt`。パスは Text と同じで Content-Type だけが違う（2026-09-17 実測）。
    /// `of` は返さない（文の種類では決まらない）。キーは `ResultLocation::failed` だけが作る。
    FailedText,
}

impl ResultFile {
    /// 先頭のキーワードで分ける。StatementType と同じく、先頭の空白とコメントは読み飛ばし
    /// （2026-09-18 実測）、キーワードの間のコメントも空白として読んでから判定する
    /// （2026-09-22 実測。#52）。文の種類だけで決まり、SQL の残りは見ない。
    pub fn of(query: &str) -> Self {
        let words = crate::catalog::words(query);
        let word = |index: usize| words.get(index).map(String::as_str).unwrap_or_default();

        match word(0).trim_start_matches('(') {
            "SELECT" | "WITH" | "VALUES" | "TABLE" | "UPDATE" | "DELETE" | "MERGE" | "VACUUM" => {
                Self::Csv
            }
            "INSERT" => Self::Manifest,
            // Athena の OPTIMIZE は CTAS と同じ扱い（Trino には無い文なので実行はできない）。
            "OPTIMIZE" => Self::Table,
            // CTAS はテーブルの形式によらず `tables/<id>`。本物の Iceberg テーブルの CTAS も
            // そうだった（2026-09-19 実測。#26）。SQL の本文から形式を読み取ることはしない。
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
            Self::Metadata => unreachable!("付随ファイルのキーは ResultLocation::metadata が作る"),
            Self::FailedText => unreachable!("失敗したときのキーは ResultLocation::failed が作る"),
        }
    }

    /// PUT に付ける Content-Type。Text は 2026-09-16 実測（本物は octet-stream で、
    /// binary と application に割れていた。多数派を採る）。Csv と Metadata は 2026-09-17 実測
    /// （6 件中 5 件が application/octet-stream。Csv の `text/csv` は 0.3.0 からの未実測の値だった）。
    /// Manifest と Table は athena-local が本体を書き込まないので、網羅のためだけの値。
    /// FailedText は 2026-09-17 実測（失敗した SHOW TABLES / DROP TABLE / CREATE DATABASE の
    /// 3 件とも application/octet-stream で、成功した `.txt` とは違った）。
    fn content_type(self) -> &'static str {
        match self {
            Self::Csv | Self::Metadata | Self::FailedText => "application/octet-stream",
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

    /// 結果ファイルの隣に置く付随ファイル `<結果ファイル名>.metadata` の置き場所。
    pub fn metadata(&self) -> Self {
        Self {
            bucket: self.bucket.clone(),
            key: format!("{}.metadata", self.key),
            file: ResultFile::Metadata,
        }
    }

    /// 失敗したときに結果ファイルを置く場所。`<id>.txt` の文だけ Some
    /// （`.csv` / `<id>` / `tables/<id>` の文は本物も何も置かない。2026-09-17 実測）。
    /// キーは成功時と同じ。
    pub fn failed(&self) -> Option<Self> {
        (self.file == ResultFile::Text).then(|| Self {
            bucket: self.bucket.clone(),
            key: self.key.clone(),
            file: ResultFile::FailedText,
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
            // タイムアウトが無いと、応答しない S3 への PUT が返らずクエリが終端状態にならない。
            http: reqwest::Client::builder()
                .timeout(settings.put_timeout)
                .build()
                .expect("HTTP クライアントを作れません"),
            endpoint: settings.endpoint.clone(),
            credentials: Credentials::new(
                settings.access_key_id.clone(),
                settings.secret_access_key.clone(),
            ),
            region: settings.region.clone(),
        }
    }

    /// 失敗の理由はそのまま StateChangeReason に載る。再試行はしない（ローカルでは即座に分かる方がよい）。
    /// `content_type` を渡せば `location.file` の既定を上書きする（DROP TABLE × Iceberg など、
    /// 文の種類だけでは決まらない Content-Type のため。issue #39）。
    pub async fn put(
        &self,
        location: &ResultLocation,
        body: Vec<u8>,
        content_type: Option<&str>,
    ) -> Result<(), String> {
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
            .header(
                CONTENT_TYPE,
                content_type.unwrap_or_else(|| location.file.content_type()),
            )
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
    fn 付随ファイルのキーは本体のキーに_metadata_を足したもの() {
        let key = |file| {
            ResultLocation::new("s3://bucket/p/", "id", file)
                .unwrap()
                .metadata()
                .key
        };
        assert_eq!(key(ResultFile::Csv), "p/id.csv.metadata");
        assert_eq!(key(ResultFile::Text), "p/id.txt.metadata");
        assert_eq!(key(ResultFile::Manifest), "p/id.metadata");
        // `tables/` は CTAS の実測（テーブルの形式によらない）。
        assert_eq!(key(ResultFile::Table), "p/tables/id.metadata");
    }

    #[test]
    fn 失敗ファイルの置き場所は_txt_の文だけにあり_キーは成功時と同じ() {
        let location = ResultLocation::new("s3://bucket/p/", "id", ResultFile::Text).unwrap();
        let failed = location.failed().expect("txt の文には置き場所がある");
        assert_eq!(failed.bucket, location.bucket);
        assert_eq!(failed.key, location.key);
        assert_eq!(failed.file, ResultFile::FailedText);

        // `.csv` / `<id>` / `tables/<id>` の文は本物も失敗時に何も置かない。
        for file in [ResultFile::Csv, ResultFile::Manifest, ResultFile::Table] {
            let location = ResultLocation::new("s3://bucket/p/", "id", file).unwrap();
            assert_eq!(location.failed(), None, "{file:?}");
        }
    }

    #[test]
    fn 失敗ファイルの_content_type_は成功時の_txt_と違う() {
        assert_eq!(
            ResultFile::FailedText.content_type(),
            "application/octet-stream"
        );
        assert_eq!(ResultFile::Text.content_type(), "binary/octet-stream");
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
}
