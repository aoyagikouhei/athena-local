//! 結果 CSV を S3 互換ストレージ（MinIO など）の OutputLocation に書く。
//! 置き場所・ファイル名・CSV の書式は 2026-09-14 に本番 Athena で実測したもの。

use std::time::Duration;

use reqwest::Url;
use reqwest::header::CONTENT_TYPE;
use rusty_s3::{Bucket, Credentials, S3Action, UrlStyle};

use crate::config::S3Settings;
use crate::content_type;
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
    /// それ以外の DDL と SHOW など。`<id>.txt`。SHOW FUNCTIONS だけは Csv（2026-09-23 実測。#80）。
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
    /// 2 語目まで見るのは CTAS（`is_create_table_as`）と `SHOW FUNCTIONS` だけ。
    pub fn of(query: &str) -> Self {
        let words = crate::catalog::words(query);
        // 先頭の `(` は取り除いて判定する。`( SELECT` のように `(` だけの語が先頭に来たら、
        // その次の語で判定する（`operation/classification.rs` の `words` と同じ扱い。#64）。
        let first = words
            .iter()
            .map(|word| word.trim_start_matches('('))
            .find(|word| !word.is_empty())
            .unwrap_or_default();

        match first {
            "SELECT" | "WITH" | "VALUES" | "TABLE" | "UPDATE" | "DELETE" | "MERGE" | "VACUUM" => {
                Self::Csv
            }
            "INSERT" => Self::Manifest,
            // Athena の OPTIMIZE は CTAS と同じ扱い（Trino には無い文なので実行はできない）。
            "OPTIMIZE" => Self::Table,
            // CTAS はテーブルの形式によらず `tables/<id>`。本物の Iceberg テーブルの CTAS も
            // そうだった（2026-09-19 実測。#26）。SQL の本文から形式を読み取ることはしない。
            "CREATE" if is_create_table_as(&words) => Self::Table,
            // SHOW FUNCTIONS だけは他の SHOW と違い、本物も `<id>.csv` に見出し行つきの CSV を置く
            // （2026-09-23 実測。#80）。
            "SHOW" if words.get(1).map(String::as_str) == Some("FUNCTIONS") => Self::Csv,
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
    /// PUT に付ける Content-Type（`content_type::of`）。文の形で決まり、`.metadata` にも同じ値を使う。
    pub content_type: &'static str,
}

impl ResultLocation {
    /// OutputLocation（`s3://bucket/prefix`）と実行 ID から、本物と同じ置き場所を作る。
    /// ファイル名は文の先頭のキーワード（`ResultFile::of`）で、Content-Type は文の形
    /// （`content_type::of`）で決める。prefix の末尾 `/` の有無は同じ場所になる。
    /// s3:// の形でなければ None。
    pub fn new(output_location: &str, id: &str, query: &str) -> Option<Self> {
        let (bucket, prefix) = split_output_location(output_location)?;
        let file = ResultFile::of(query);
        Some(Self {
            bucket: bucket.to_string(),
            key: format!("{prefix}{}", file.path(id)),
            file,
            content_type: content_type::of(file, query),
        })
    }

    /// 結果ファイルの隣に置く付随ファイル `<結果ファイル名>.metadata` の置き場所。
    /// Content-Type は本体と同じ（2026-09-23 実測。36 項目すべて一致）。
    pub fn metadata(&self) -> Self {
        Self {
            bucket: self.bucket.clone(),
            key: format!("{}.metadata", self.key),
            file: ResultFile::Metadata,
            content_type: self.content_type,
        }
    }

    /// 失敗したときに結果ファイルを置く場所。`<id>.txt` の文だけ Some
    /// （`.csv` / `<id>` / `tables/<id>` の文は本物も何も置かない。2026-09-17 実測）。
    /// キーは成功時と同じで、Content-Type は文の形によらず application
    /// （失敗した SHOW TABLES / DROP TABLE / CREATE DATABASE の 3 件とも。2026-09-17 実測）。
    pub fn failed(&self) -> Option<Self> {
        (self.file == ResultFile::Text).then(|| Self {
            bucket: self.bucket.clone(),
            key: self.key.clone(),
            file: ResultFile::FailedText,
            content_type: content_type::APPLICATION,
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

/// 本物と同じ書式: GetQueryResults の行を `\t` で連結し、`\n` でつなぐ。
/// 先頭の列名行を入れるかどうかは `with_header` で呼び出し元（文の種類を知る側）が決める。
/// DDL / SHOW / DESCRIBE（UTILITY）は入れず、EXPLAIN（DML）は入れる（本物の `.txt` の先頭行が
/// `Query Plan` で、行数が GetQueryResults の Rows と一致する。2026-09-15／16 実測。#63）。
/// NULL は空文字（CSV と違い引用符は付けない）。末尾に改行は付けない。行が無ければ空。
/// 値の表記（複合型・double・varbinary など）は to_csv と同じ。
pub fn to_text(outcome: &Outcome, with_header: bool) -> Vec<u8> {
    convert::all_rows(outcome)
        .into_iter()
        .skip(if with_header { 0 } else { 1 })
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
    /// `content_type` を渡せば `location.content_type` を上書きする（DROP TABLE × Iceberg など、
    /// 文の形だけでは決まらず対象テーブルの形式で変わる Content-Type のため。issue #39）。
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
            .header(CONTENT_TYPE, content_type.unwrap_or(location.content_type))
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
mod tests;
