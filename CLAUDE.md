# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 概要

AWS Athena API（`awsJson1.1`）のローカル代役。受け取った SQL を Trino の REST API（`/v1/statement`）で実行し、結果を Athena と同じ形で返す。オプションで結果 CSV を S3 互換ストレージ（MinIO など）に書く。利用者向けの仕様（環境変数、対応オペレーション、Athena との差分）は README.md にまとまっている。

## コマンド

```bash
cargo run                                          # 実行には到達できる Trino（TRINO_URL）が要る
cargo test                                         # Trino も AWS も要らない（テスト内で偽物を立てる）
cargo test --test parameters                       # 結合テストを 1 ファイルだけ（tests/<名前>.rs）
cargo test --test select ページング                  # テスト名の一部で絞る（テスト名は日本語）
cargo test --lib config::tests                     # src 内のユニットテストだけ
cargo fmt --check
cargo clippy --all-targets --locked -- -D warnings
docker build -t aoyagikouhei/athena-local:dev .
```

CI（`.github/workflows/ci.yml`）は `fmt --check`、`clippy -D warnings`、`test --locked` を回す。`v*` タグを push すると `docker.yml` が amd64 / arm64 のイメージを Docker Hub に publish する。

## アーキテクチャ

### リクエストの流れ

1. `handler::dispatch` — `POST /` の 1 本だけ。`X-Amz-Target: AmazonAthena.<Operation>` でオペレーションを振り分ける。SigV4 は検証しない。
2. `operation/` — 6 つのオペレーションの本体。`execution.rs`（`StartQueryExecution` の受付とバックグラウンド実行）、`result_output.rs`（結果ファイル本体と `.metadata` の書き込み）、`query_execution.rs`（`GetQueryExecution`／`GetQueryResults`／`StopQueryExecution`）、`work_group.rs`（`GetWorkGroup`／`ListWorkGroups`）に分かれ、文の種類の判定だけ `classification.rs` に置いて実行系と参照系の両方から呼ぶ。`MaxResults`／`NextToken` の枠組みの検証（API 定義の制約違反を `N validation error(s) detected: ...` の 1 文にまとめる。2026-09-23 実測）は `validation.rs` に置いて `GetQueryResults` と `ListWorkGroups` の両方から呼ぶ。DROP TABLE と ALTER TABLE ... ADD COLUMNS / REPLACE COLUMNS は、対象テーブルの形式によっては本物が列なしでも本体と `.metadata` を置くので、その判定を `table_format.rs`（Trino への形式の問い合わせと組み合わせの決定）と `target_table.rs`（対象の修飾名の解析）に置く。`mod.rs` は `mod` 宣言と 6 関数の再エクスポートだけで、`handler` からの見え方は分割前と変わらない。
   - `execution.rs` の `start_query_execution`: 文脈（カタログ／スキーマ）に既定値を当てる → `OutputLocation` を検証 → `Trino::syntax_error` で構文を確かめる（`PREPARE athena_local_syntax_check FROM\n<sql>` を送り、1 行ずれたエラー位置を元に戻す）→ `Store::submit` → `spawn_query` でバックグラウンド実行して、ID をすぐ返す。
   - `execution.rs` の `spawn_query` → `run`: `ExecutionParameters` の値ごとに `SELECT (<値>)` を Trino に投げて分類し（`statement::bind`）、`EXECUTE IMMEDIATE '<sql>' USING ...` で実行する。包む前に `catalog::alias_qualified_names` で修飾名のカタログに別名を当てる。パラメータが無く、別名に一致する修飾名も無ければ SQL は一切書き換えない（テストで保証している不変条件）。`?` の無い SQL に値が渡されたときのエラーでは、別名を当てただけの SQL で再実行する。
   - `result_output.rs` の `write_result`: 本体（CSV / TXT）を置き、列があれば `.metadata` を置いてから `SUCCEEDED` にする（クライアントは SUCCEEDED を見た直後に S3 を読むため）。本体を置くのは `ResultFile::Csv` で更新件数が無いときと `ResultFile::Text` のときで、取り消されていないときだけ。DML と CTAS は本体を置かず `.metadata` だけを置く。本体の PUT が失敗したら `.metadata` は試みない。
   - `result_output.rs` の `write_failure`: 失敗（`run` が `Err`）したときに、`ResultFile::Text` の文だけ `<id>.txt` に `FAILED: ` + `StateChangeReason` を置く。`.metadata` は置かない。取り消されていれば何も置かない。書けなくても FAILED と理由は Trino のエラーのまま。置き場所と Content-Type は `ResultLocation::failed`（`ResultFile::FailedText`。Content-Type だけ成功時と違う）。
3. `store.rs` — 実行状態をメモリの `HashMap` で持つ。`finish` は終端状態では何もしないので、先に `CANCELLED` になったクエリにあとから届いた結果は捨てられる。
4. `trino.rs` — Trino クライアント。`nextUri` を辿ってページを `Outcome` にまとめる（503 は待って再試行、DML の `data` は行として扱わない）。timestamp の精度を保つため `X-Trino-Client-Capabilities: PARAMETRIC_DATETIME` を必ず付ける。

### 取り消し

`StopQueryExecution` は `Store::cancel` で状態を同期に `CANCELLED` にし、`Cancel`（`AtomicBool`）を立てるだけ。実行中のタスクは `Trino::follow` のページ境界でフラグを見て、`nextUri` に `DELETE` を送る。

### Athena の見え方への変換

- `convert/` — Trino の値と型から Athena の `ResultSet` を作る。`result_set.rs`（`Outcome` → `ResultSet` の入口。1 ページ目の先頭行に列名を入れる）、`value_type.rs`（`typeSignature` の解析）、`render.rs`（値をすべて文字列にする。複合型は `typeSignature` を見て Athena の表記（`[1, 2]`、`{k=1}`）にする）、`scalar.rs`（スカラ値の表記。double は Java の `Double.toString`、varbinary は 16 進）、`athena_type.rs`（Trino の型から Athena の型名・Precision・Scale・CaseSensitive を決める）に分かれ、`typeSignature` から生の型名を取る `raw_type` だけ `value_type.rs` に置いてレンダリングと型マッピングの両方から呼ぶ。`mod.rs` は `mod` 宣言と 3 関数の再エクスポートだけで、呼び出し元からの見え方は分割前と変わらない。`GetQueryResults` と結果 CSV（`results::to_csv`）の両方がここを通る。
- 文の種類は先頭のキーワードで判定していて、判定が 2 か所にある。`StatementType`／`SubstatementType` は `operation/classification.rs`（`UpdateCount` は `operation/query_execution.rs` がその `statement_type` を使って決める）、`OutputLocation` のファイル名（`<id>.csv`、`<id>`、`tables/<id>`、`<id>.txt`）は `results::ResultFile::of`。CTAS の判定（`is_create_table_as`）は両者で共有している。どちらも先頭の空白とコメント（`-- ...`、`/* ... */`）は `catalog::skip_leading_trivia` で読み飛ばしてから判定する（本物の Athena も同様。2026-09-18 実測）。どちらも見るのは先頭のキーワードだけで、SQL の残りは読まない（CTAS は本物と同じくテーブルの形式によらず `tables/<id>`。2026-09-19 実測）。
- `catalog.rs` — `TRINO_CATALOG_MAP` の別名を SQL の修飾名にも当てる。対象は、別名マップのキーと完全一致する二重引用符付き識別子で、空白やコメントを挟んで `.` が続くものだけ。文字列リテラルとコメントは読み飛ばす。置き換えた名前が短ければ空白で埋めて、Trino のエラーの桁位置を受け取った SQL に揃える。構文チェックと `GetQueryExecution` の `Query` は受け取った SQL のまま。
- `metadata.rs` — 結果ファイルの隣に置く `.metadata` の protobuf を組み立てる（公式のスキーマは無く、burtcorp/athena-jdbc の `AthenaMetaDataParser` と同じフィールド番号）。先頭にクエリ ID、DML と CTAS は `updateType` と更新件数、続けて列ごとに `ColumnInfo` と同じ値。列の Precision／Scale／CaseSensitive を出すかどうかは値ではなく型ごとの表で決める（2026-09-17 実測）。S3 も文の分類も知らない。クエリ ID の出どころ（Trino の ID か `QueryExecutionId` か）は `operation/result_output.rs` 側で決める。
- `failure.rs` — Trino のエラー名を `AthenaError` の `ErrorCategory`／`ErrorType` に写す。
- `response.rs` — awsJson1.1 のエラー形（`__type` と `x-amzn-errortype` ヘッダ、必要なら `AthenaErrorCode`）。
- `athena.rs` — リクエスト／レスポンスの型（PascalCase で SDK の JSON と一対一に対応する）。

### テストの足場（`tests/common/mod.rs`）

`Harness` が偽 Trino、（`results_s3()` を呼べば）偽 S3、本物の `athena_local::router` を同じプロセスの `127.0.0.1:0` に立てる。`Harness::builder(<既定の応答>)` のあと、`.route(sql, 応答)`（SQL ごとの応答）、`.next_page`、`.endless()`（終わらないクエリ）、`.statement_delay`、`.syntax_check_response`、`.catalog_map` などで偽 Trino の振る舞いを決める。検証には `trino_requests()`／`trino_sqls()`（実行された SQL とヘッダ）、`syntax_checks()`（PREPARE で届いた SQL。`trino_requests` には入らない）、`trino_calls()`（`nextUri` への GET／DELETE）、`s3_puts()`（body はバイト列。`.metadata` の protobuf を見るため）を使う。偽 Trino は、応答に `id` が無ければ既定のクエリ ID `TRINO_QUERY_ID` を補う（`.metadata` の先頭に入るため）。

- 偽 Trino は、PREPARE の前置きを `src/trino.rs` と同じ定数 `SYNTAX_CHECK_PREFIX` で見分けている。前置きを変えるときは両方を直す。
- テストバイナリごとに `common` を取り込むので、使われないヘルパが出る。そのため `#![allow(dead_code)]` を付けている。
- `config.rs` のテストは本物の環境変数を触らない（テストが並列に走るため）。`parse_results` に環境変数を読むクロージャを渡して差し替える。
- ユニットテストはインラインの `#[cfg(test)] mod tests` に置く。例外は `src/results.rs` だけで、本体が 400 行を超えないようにテストを子モジュール `src/results/tests.rs`（`mod.rs` 無し）に出している（#75）。

## 開発上の約束

- **本物の Athena に合わせることが目的**。文言、エラーコード、型の見え方、ファイル名などは本番 Athena で実測した値に合わせ、コメントに「2026-09-14 実測」のように書いてある。実測していない振る舞いは推測で埋めない。項目を省く（例: `substatement_type` が `None`）か、README の Caveats に「未実測」と書く。
- **SQL の本文は書き換えない。** 必要なら全体を包む（`EXECUTE IMMEDIATE`）か、別のクエリを投げる（構文チェックの `PREPARE`、パラメータ分類の `SELECT (<値>)`）。Athena と Trino の書き方の違い（小数リテラルの型、DDL、`OPTIMIZE` / `VACUUM`）は変換せず、README の Caveats に回避策を書く。例外は `TRINO_CATALOG_MAP` の別名を引用符付きの修飾名に当てる置換（`catalog.rs`）だけ。Trino には `/` を含むカタログ名を作れず、S3 Tables の修飾名はほかに通す方法が無いので、汎用ツールとして入れた（2026-09-15）。この置換の条件は広げない。引用符の無い名前や大文字小文字の違う名前は、Trino 側のカタログ名を合わせる回避策を README に書いてある。
- 挙動を変えたら README.md（Supported API／Caveats）と CHANGELOGS.md の `[Unreleased]` も更新する。CHANGELOG のバージョンは Docker Hub のイメージタグと一致させ、README の compose 例のタグも合わせる。
- コメント、テスト名（日本語の文）、エラーメッセージ、コミットメッセージ（「〜する」で終わる一行）、PR の本文は日本語。README と CHANGELOG は英語。
- **ユーザーへの返答は常に日本語で書く。** 途中の状況報告、質問、最終報告、コマンドの説明もすべて日本語。英語は README・CHANGELOG の本文とコード中の識別子だけ。
- 大きな `Response` を `Result` で返すときは `Box<Response>` にする（`clippy::result_large_err` 対策）。
- HTTP クライアントは TLS 無しでビルドしている（`reqwest` は `default-features = false`）。Trino にも S3 にも `http://` だけでつなぐ。
- Rust edition 2024（let chains を使っている）。Docker のビルドイメージは `rust:1.98`。
- **ローカルの `aws` コマンドは Docker のラッパのことがある。** マウントされるのは実行時のカレントディレクトリだけで、
  絶対パスへの書き出しはコンテナの中に消えるうえ終了コードは 0 になる。取得は `aws s3 cp <src> -` で標準出力に流し、
  リダイレクトはシェルが行う（2026-09-16 に実測スクリプトで、2026-09-21 に実機検証で踏んだ）。
  同じ理由で compose のネットワークにも入れないので、compose 内のサービス（MinIO など）を触るときは
  `--network` を付けた使い捨てコンテナから叩く（`.claude/issue-notes/39-e2e/verify.sh`）。
