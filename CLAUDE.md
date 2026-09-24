# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 概要

AWS Athena API（`awsJson1.1`）のローカル代役。受け取った SQL を Trino の REST API（`/v1/statement`）で実行し、結果を Athena と同じ形で返す。オプションで結果 CSV を S3 互換ストレージ（MinIO など）に書く。利用者向けの仕様（環境変数、対応オペレーション、Athena との差分）は `docs/` にまとまっていて、README.md は概要とクイックスタートだけ。開発者向けの記録（実測の結果、未実測の一覧、ロードマップ、設計判断）は `docs/dev/` にある（下の「ドキュメントの置き場」）。

## コマンド

既定は toolbox（`tools/dev.sh` 経由。compose.yml の dev サービスの中で動く。docs/dev/development.md）。ホストに rust があればホスト直でも動く（`target/` は toolbox の `.toolbox/target` と別）。

```bash
tools/dev.sh cargo run                             # 実行には到達できる Trino が要る。既定の TRINO_URL は http://trino:8080（先に `docker compose -f compose.yml up -d trino`）
tools/dev.sh cargo test                            # Trino も AWS も要らない（テスト内で偽物を立てる）
tools/dev.sh cargo test --test parameters          # 結合テストを 1 ファイルだけ（tests/<名前>.rs）
tools/dev.sh cargo test --test select ページング      # テスト名の一部で絞る（テスト名は日本語）
tools/dev.sh cargo test --lib config::tests        # src 内のユニットテストだけ
tools/dev.sh cargo fmt --check
tools/dev.sh cargo clippy --all-targets --locked -- -D warnings
tools/dev.sh docker build -t aoyagikouhei/athena-local:dev .
tools/dev.sh tools/e2e/minio/verify.sh             # 検証の足場（tools/e2e）。環境は compose.yml の trino / minio など。同時に流すなら COMPOSE_PROJECT_NAME（docs/dev/development.md）
```

CI（`.github/workflows/ci.yml`）の `check` はホストランナーで直に `fmt --check`、`clippy -D warnings`、`test --locked` を回し、`e2e` は toolbox（`tools/dev.sh`）の中で軽い足場（request-errors、paging-validation）を流す。`v*` タグを push すると `docker.yml` が amd64 / arm64 のイメージを Docker Hub に publish する。リリースの手順（版の書き換えからタグと publish の確認まで）は `.claude/skills/release/SKILL.md`（`/release X.Y.Z`）に従う。

## アーキテクチャ

### リクエストの流れ

1. `handler::dispatch` — `POST /` の 1 本だけ。`X-Amz-Target: AmazonAthena.<Operation>` でオペレーションを振り分ける（前置き必須。ヘッダ無し・未対応名は本物と同じ `{"__type":"UnknownOperationException"}` だけの 400。2026-09-23 実測）。SigV4 は検証しない。
2. `operation/` — 6 つのオペレーションの本体。`execution.rs`（`StartQueryExecution` の受付とバックグラウンド実行）、`result_output.rs`（結果ファイル本体と `.metadata` の書き込み）、`query_execution.rs`（`GetQueryExecution`／`GetQueryResults`／`StopQueryExecution`）、`work_group.rs`（`GetWorkGroup`／`ListWorkGroups`）に分かれ、文の種類の判定だけ `classification.rs` に置いて実行系と参照系の両方から呼ぶ。`MaxResults`／`NextToken` の枠組みの検証（API 定義の制約違反を `N validation error(s) detected: ...` の 1 文にまとめる。2026-09-23 実測）は `validation.rs` に置いて `GetQueryResults` と `ListWorkGroups` の両方から呼ぶ。DROP TABLE と ALTER TABLE ... ADD COLUMNS / REPLACE COLUMNS は、対象テーブルの形式によっては本物が列なしでも本体と `.metadata` を置くので、その判定を `table_format.rs`（Trino への形式の問い合わせと組み合わせの決定）と `target_table.rs`（対象の修飾名の解析）に置く。`mod.rs` は `mod` 宣言と 6 関数の再エクスポートだけで、`handler` からの見え方は分割前と変わらない。
   - `execution.rs` の `start_query_execution`: 文脈（カタログ／スキーマ）に既定値を当てる → `OutputLocation` を検証 → `Trino::syntax_error` で構文を確かめる（`PREPARE athena_local_syntax_check FROM\n<sql>` を送り、1 行ずれたエラー位置を元に戻す）→ `Store::submit` → `spawn_query` でバックグラウンド実行して、ID をすぐ返す。
   - `execution.rs` の `spawn_query` → `run`: `ExecutionParameters` の値ごとに `SELECT (<値>)` を Trino に投げて分類し（`statement::bind`）、`EXECUTE IMMEDIATE '<sql>' USING ...` で実行する。包む前に `catalog::alias_qualified_names` で修飾名のカタログに別名を当てる。パラメータが無く、別名に一致する修飾名も無ければ SQL は一切書き換えない（テストで保証している不変条件）。`?` の無い SQL に値が渡されたときのエラーでは、別名を当てただけの SQL で再実行する。
   - `result_output.rs` の `write_result`: 本体（CSV / TXT）を置き、列があれば `.metadata` を置いてから `SUCCEEDED` にする（クライアントは SUCCEEDED を見た直後に S3 を読むため）。本体を置くのは `ResultFile::Csv` で更新件数が無いときと `ResultFile::Text` のときで、取り消されていないときだけ。DML と CTAS は本体を置かず `.metadata` だけを置く。本体の PUT が失敗したら `.metadata` は試みない。
   - `result_output.rs` の `write_failure`: 失敗（`run` が `Err`）したときに、`ResultFile::Text` の文だけ `<id>.txt` に `FAILED: ` + `StateChangeReason` を置く。ただし EXPLAIN（`EXPLAIN ANALYZE` も）は `.txt` の文でも置かない（本物も置かない。2026-09-23 実測。#92）。`.metadata` は置かない。取り消されていれば何も置かない。書けなくても FAILED と理由は Trino のエラーのまま。置き場所と Content-Type は `ResultLocation::failed`（`ResultFile::FailedText`。Content-Type だけ成功時と違う）。
3. `store.rs` — 実行状態をメモリの `HashMap` で持つ。`finish` は終端状態では何もしないので、先に `CANCELLED` になったクエリにあとから届いた結果は捨てられる。
4. `trino.rs` — Trino クライアント。`nextUri` を辿ってページを `Outcome` にまとめる（503 は待って再試行、DML の `data` は行として扱わない）。timestamp の精度を保つため `X-Trino-Client-Capabilities: PARAMETRIC_DATETIME` を必ず付ける。

### 取り消し

`StopQueryExecution` は `Store::cancel` で状態を同期に `CANCELLED` にし、`Cancel`（`AtomicBool`）を立てるだけ。実行中のタスクは `Trino::follow` のページ境界でフラグを見て、`nextUri` に `DELETE` を送る。

### Athena の見え方への変換

- `convert/` — Trino の値と型から Athena の `ResultSet` を作る。`result_set.rs`（`Outcome` → `ResultSet` の入口。1 ページ目の先頭行に列名を入れる）、`value_type.rs`（`typeSignature` の解析）、`render.rs`（値をすべて文字列にする。複合型は `typeSignature` を見て Athena の表記（`[1, 2]`、`{k=1}`）にする）、`scalar.rs`（スカラ値の表記。double は Java の `Double.toString`、varbinary は 16 進）、`athena_type.rs`（Trino の型から Athena の型名・Precision・Scale・CaseSensitive を決める）に分かれ、`typeSignature` から生の型名を取る `raw_type` だけ `value_type.rs` に置いてレンダリングと型マッピングの両方から呼ぶ。`mod.rs` は `mod` 宣言と 3 関数の再エクスポートだけで、呼び出し元からの見え方は分割前と変わらない。`GetQueryResults` と結果 CSV（`results::to_csv`）の両方がここを通る。
- 文の種類は先頭のキーワードで判定していて、SQL を読む判定が 3 か所にある。`StatementType`／`SubstatementType` は `operation/classification.rs`（`UpdateCount` は `operation/query_execution.rs` がその `statement_type` を使って決める）、`OutputLocation` のファイル名（`<id>.csv`、`<id>`、`tables/<id>`、`<id>.txt`）は `results::ResultFile::of`、結果ファイルの Content-Type は `content_type.rs`。CTAS の判定（`is_create_table_as`）は前の 2 つで共有している。前の 2 つは SQL を `catalog::words`（内部の `skip_trivia` で空白とコメント（`-- ...`、`/* ... */`）を区切りとして読み飛ばし、大文字の語の並びにする）で分けてから判定するので、先頭のコメントもキーワードの間のコメントも語にならない（本物の Athena も同様。2026-09-18／22 実測）。`catalog::skip_leading_trivia` は ALTER TABLE の対象名の解析（`classification.rs` の `alter_table_action`）などで使う。どこまで読むかは文ごとに違う: `SubstatementType` は 2〜4 語目まで、ALTER TABLE はテーブル名を読み飛ばした後ろのキーワード、CTAS は語の並び全体から `AS SELECT`／`AS WITH`／`AS (` を探し、`ResultFile::of` は `SHOW FUNCTIONS` の 2 語目まで、`content_type.rs` は SELECT の本文がリテラルだけかまで見る。ほかに `result_output.rs` の `metadata_query_id` が先頭 2 語（`DESCRIBE`／`DESC`、`SHOW CREATE`）で `.metadata` の先頭に載せるクエリ ID を選ぶ（`content_type.rs` の `.txt` の判定と対にする）。どれもテーブルの形式は SQL から読み取らない（CTAS は本物と同じくテーブルの形式によらず `tables/<id>`。2026-09-19 実測）。
- `catalog.rs` — `TRINO_CATALOG_MAP` の別名を SQL の修飾名にも当てる。対象は、別名マップのキーと完全一致する二重引用符付き識別子で、空白やコメントを挟んで `.` が続くものだけ。文字列リテラルとコメントは読み飛ばす。置き換えた名前が短ければ空白で埋めて、Trino のエラーの桁位置を受け取った SQL に揃える。構文チェックと `GetQueryExecution` の `Query` は受け取った SQL のまま。
- `metadata.rs` — 結果ファイルの隣に置く `.metadata` の protobuf を組み立てる（公式のスキーマは無く、burtcorp/athena-jdbc の `AthenaMetaDataParser` と同じフィールド番号）。先頭にクエリ ID、DML と CTAS は `updateType` と更新件数、続けて列ごとに `ColumnInfo` と同じ値。列の Precision／Scale／CaseSensitive を出すかどうかは値ではなく型ごとの表で決める（2026-09-17 実測）。S3 も文の分類も知らない。クエリ ID の出どころ（Trino の ID か `QueryExecutionId` か）は `operation/result_output.rs` 側で決める。
- `failure.rs` — Trino のエラー名を `AthenaError` の `ErrorCategory`／`ErrorType` に写す。
- `request.rs` — awsJson1.1 のリクエスト本文の解釈。JSON として読めない・トップレベルが object でない・型違い・必須の欠落を、本物と同じ `SerializationException`（文言は実測した型の組み合わせだけ。未実測は `Message` 無し）と枠組みの検証（`Value null at '<lowerCamel>' ... Member must not be null`）に写す（2026-09-23 実測）。`null` の項目は読む前に消す（本物は無いのと同じに扱う）。
- `response.rs` — awsJson1.1 のエラー形（`__type`、必要なら `AthenaErrorCode`。本物と同じく `x-amzn-errortype` ヘッダは付けない（#145）。`__type` だけの `bare_error`、`SerializationException` の `serialization_error`、枠組みの検証の文言 `validation_errors`）。
- `athena.rs` — リクエスト／レスポンスの型（PascalCase で SDK の JSON と一対一に対応する）。

### テストの足場（`tests/common/mod.rs`）

`Harness` が偽 Trino、（`results_s3()` を呼べば）偽 S3、本物の `athena_local::router` を同じプロセスの `127.0.0.1:0` に立てる。`Harness::builder(<既定の応答>)` のあと、`.route(sql, 応答)`（SQL ごとの応答）、`.next_page`、`.endless()`（終わらないクエリ）、`.statement_delay`、`.syntax_check_response`、`.catalog_map` などで偽 Trino の振る舞いを決める。検証には `trino_requests()`／`trino_sqls()`（実行された SQL とヘッダ）、`syntax_checks()`（PREPARE で届いた SQL。`trino_requests` には入らない）、`trino_calls()`（`nextUri` への GET／DELETE）、`s3_puts()`（body はバイト列。`.metadata` の protobuf を見るため）を使う。偽 Trino は、応答に `id` が無ければ既定のクエリ ID `TRINO_QUERY_ID` を補う（`.metadata` の先頭に入るため）。

- 偽 Trino は、PREPARE の前置きを `src/trino.rs` と同じ定数 `SYNTAX_CHECK_PREFIX` で見分けている。前置きを変えるときは両方を直す。
- テストバイナリごとに `common` を取り込むので、使われないヘルパが出る。そのため `#![allow(dead_code)]` を付けている。
- `config.rs` のテストは本物の環境変数を触らない（テストが並列に走るため）。`parse_results` に環境変数を読むクロージャを渡して差し替える。
- ユニットテストはインラインの `#[cfg(test)] mod tests` に置く。例外は `src/results.rs` だけで、本体が 400 行を超えないようにテストを子モジュール `src/results/tests.rs`（`mod.rs` 無し）に出している（#75）。

## ドキュメントの置き場

| 置き場 | 書くこと | 言語 |
|---|---|---|
| `README.md` | 概要、クイックスタート、docs へのリンク | 英語 |
| `docs/*.md` | athena-local の現在の挙動（利用者向け） | 英語 |
| `docs/dev/measurements/` | 本物の Athena などで測った事実。日付・issue・スクリプトのパス・投げたもの・返ったもの。上書きせず、食い違いは両方を残して採用した判断を書く | 日本語 |
| `docs/dev/unmeasured.md` | 未実測の一覧。測ったら measurements に書いてここから消す | 日本語 |
| `docs/dev/roadmap.md` | 未実装機能と優先度、クライアント調査 | 日本語 |
| `docs/dev/decisions.md` | 決着済みの設計判断（この CLAUDE.md にある約束は重ねない） | 日本語 |
| `docs/dev/development.md` | ビルド・テスト・リリース | 日本語 |
| `CHANGELOGS.md` | 版の間で何が変わったか。1 項目 1〜2 行 | 英語 |
| `tools/measure/`、`tools/e2e/`、`tools/toolbox/`、`tools/dev.sh`、`compose.yml`、`tools/compose/` | 本物の Athena に投げる実測スクリプト、compose の実機検証の足場、足場を動かす toolbox のイメージと呼び口（dev サービス）、足場の環境（trino / minio などのサービス）とその付属物（カタログ、tls、jdbc-client） | — |

- 作業中のノート（`.claude/issue-notes/<番号>.md` と、その issue の足場）は、いま進めている issue のぶんだけを置く。**新しい issue に着手したら、ブランチを切った直後に過去の issue のノートを `git rm -r .claude/issue-notes` で全部消してから進める**（Skill が新しいノートを書く前に消す。古いノートには後で覆った事実が残っていて、正のドキュメントより先に読まれると誤った前提で開発が進むため。#98・#100）。過去のノートは git の履歴にある。
- ノートに書いた実測の結果表は `docs/dev/measurements/` へ、後の開発でも効く設計判断は `docs/dev/decisions.md` へ、残った未実測は `docs/dev/unmeasured.md` へ、その issue の PR をマージする前に写す。ノートは PR に残してよいが、正はつねに docs/dev 側で、ノートの記述と食い違ったら docs/dev を信じる。
- 実測スクリプトは issue 番号の接頭辞を付けず、内容で名前を付けて `tools/measure/` に置き、先頭のコメントに issue 番号を書く。

## 開発上の約束

- **本物の Athena に合わせることが目的**。文言、エラーコード、型の見え方、ファイル名などは本番 Athena で実測した値に合わせ、コメントに「2026-09-14 実測」のように書いてある。実測していない振る舞いは推測で埋めない。項目を省く（例: `substatement_type` が `None`）か、`docs/caveats.md` に「not measured」と書いて `docs/dev/unmeasured.md` に載せる。測ったら `docs/dev/measurements/` に記録し、unmeasured から消す。
- **SQL の本文は書き換えない。** 必要なら全体を包む（`EXECUTE IMMEDIATE`）か、別のクエリを投げる（構文チェックの `PREPARE`、パラメータ分類の `SELECT (<値>)`）。Athena と Trino の書き方の違い（小数リテラルの型、DDL、`OPTIMIZE` / `VACUUM`）は変換せず、`docs/caveats.md` に回避策を書く。例外は `TRINO_CATALOG_MAP` の別名を引用符付きの修飾名に当てる置換（`catalog.rs`）だけ。Trino には `/` を含むカタログ名を作れず、S3 Tables の修飾名はほかに通す方法が無いので、汎用ツールとして入れた（2026-09-15）。この置換の条件は広げない。引用符の無い名前や大文字小文字の違う名前は、Trino 側のカタログ名を合わせる回避策を `docs/configuration.md` と `docs/caveats.md` に書いてある。
- 挙動を変えたら `docs/`（対応オペレーションは `api.md`、Athena との差分は `caveats.md`、結果ファイルは `result-files.md` など）と CHANGELOGS.md の `[Unreleased]` も更新する。CHANGELOG は 1 項目 1〜2 行の箇条書きで、挙動の説明は書かずに docs の節へリンクする。CHANGELOG のバージョンは Docker Hub のイメージタグと一致させ、README の compose 例のタグも合わせる。
- コメント、テスト名（日本語の文）、エラーメッセージ、コミットメッセージ（「〜する」で終わる一行）、PR の本文は日本語。README・`docs/*.md`・CHANGELOG は英語、`docs/dev/` は日本語。
- **ユーザーへの返答は常に日本語で書く。** 途中の状況報告、質問、最終報告、コマンドの説明もすべて日本語。英語は README・`docs/*.md`・CHANGELOG の本文とコード中の識別子だけ。
- 大きな `Response` を `Result` で返すときは `Box<Response>` にする（`clippy::result_large_err` 対策）。
- HTTP クライアントは TLS 無しでビルドしている（`reqwest` は `default-features = false`）。Trino にも S3 にも `http://` だけでつなぐ。
- Rust edition 2024（let chains を使っている）。Docker のビルドイメージは `rust:1.98`。toolbox（`tools/toolbox/Dockerfile`）も同じタグ。変えるときは両方。
- **検証の足場（`tools/e2e`）はホストで直接叩かず `tools/dev.sh` 経由で toolbox の中で動かす**。
  ホストの PATH にある同名の別物（Docker で包んだ `aws`、snap 製の `jq`、astral でない `uv`）を踏んで回避策を積み上げた経緯があり
  （2026-09-16〜23）、足場が動く場所をコンテナに固定した（#127）。足場は `aws` を使わない（S3 の確認は toolbox の `mc` で
  `minio:9000` を直接見る。#129）。実測（`tools/measure`）も `tools/dev.sh` 経由で動かす（awscli v2 を toolbox に入れた。#129）。
  資格情報はホストのシェルで export した `AWS_*` を渡す（`~/.aws` も読める）。生データはホストの `~/athena-*-measurements`。
  人間が対話で本物の AWS に投げる `aws` はホストのまま。toolbox の HOME と cargo の成果物は
  リポジトリの `.toolbox/` の下で、ホストの `target/` とは混ぜない（足場は `BINARY` 変数で `CARGO_TARGET_DIR` に追随する）。詳細は `docs/dev/development.md`。
