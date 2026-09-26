# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 概要

AWS Athena API（`awsJson1.1`）のローカル代役。受け取った SQL を Trino の REST API（`/v1/statement`）で実行し、結果を Athena と同じ形で返す。オプションで結果 CSV を S3 互換ストレージ（MinIO など）に書く。利用者向けの仕様（環境変数、対応オペレーション、Athena との差分）は `docs/` にまとまっていて、README.md は概要とクイックスタートだけ。開発者向けの記録（内部の詳しい地図、実測の結果、未実測の一覧、ロードマップ、設計判断）は `docs/dev/` にある（下の「ドキュメントの置き場」）。

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

CI（`.github/workflows/ci.yml`）の中身とリリース（`v*` タグで `docker.yml` が Docker Hub に publish）は docs/dev/development.md。リリースの手順は `.claude/skills/release/SKILL.md`（`/release X.Y.Z`）に従う。

## アーキテクチャ

関数・判定の細部と由来は **docs/dev/architecture.md**（モジュールの中に手を入れる前に該当の節を読む）。ここには地図と不変条件だけを置く。

- `handler.rs` — `POST /` の 1 本だけ。`X-Amz-Target: AmazonAthena.<Operation>` で振り分ける。SigV4 は検証しない。
- `operation/` — 6 つのオペレーションの本体（`execution.rs`・`query_execution.rs`・`work_group.rs`）と、実行の前後の処理（`format_probe.rs`・`completion.rs`・`result_output.rs`・`utility_rows.rs` など）、文の種類の判定（`classification.rs`）、`MaxResults`／`NextToken` の検証（`validation.rs`）。`mod.rs` は `mod` 宣言と再エクスポートだけ。
- `store.rs`（実行状態をメモリの `HashMap` で持つ）、`trino.rs`（Trino クライアント）、`convert/`（Trino の値と型 → Athena の `ResultSet`）、`catalog.rs`（`TRINO_CATALOG_MAP` の別名を修飾名に当てる置換）、`metadata.rs`（`.metadata` の protobuf）、`results.rs`（結果ファイルの名前と CSV）、`content_type.rs`、`failure.rs`（Trino のエラー → `AthenaError`）、`request.rs`／`response.rs`（awsJson1.1 の本文とエラーの形）、`athena.rs`（リクエスト／レスポンスの型）、`config.rs`。
- `crates/athena-sql` — SQL の字句処理と文の認識を置く内部 crate（workspace の member。`publish = false`、版は追わない。規則は decisions.md の「SQL の内部 crate（athena-sql）」）。ルートの `Cargo.toml` が workspace を兼ね、`default-members` で上のコマンドが crate にも効く。

壊すと事故になる不変条件:

- 書き換えの条件（パラメータ、`TRINO_CATALOG_MAP` の別名に一致する修飾名、文の前後の空白と `;`、DESCRIBE などの `awsdatacatalog.` と表への DESCRIBE の DB、S3 Tables の Context の `CREATE TABLE AwsDataCatalog.<名前空間>.<表>` の 1 部目を空白にするもの、S3 Tables の Context の CTAS の `awsdatacatalog.<DB>.<表>` の 1 部目を `AwsDataCatalog` の Trino 名にするもの）のどれにも当たらなければ、Trino に送る SQL は受け取った SQL と 1 文字も違わない（テストで保証）。条件を足したら、この一覧と `docs/configuration.md` の "not rewritten" の約束も直す。
- 構文チェックは `PREPARE athena_local_syntax_check FROM\n<sql>` で、Trino のエラー位置を 1 行戻す。前置きを変えるときは `src/trino.rs` と偽 Trino（`tests/common/mod.rs`）の `SYNTAX_CHECK_PREFIX` を両方直す。
- 結果ファイル（本体、次に `.metadata`）を置いてから `SUCCEEDED` にする（クライアントは SUCCEEDED を見た直後に S3 を読む）。
- `Store::finish` は終端状態では何もしない（先に `CANCELLED` になったクエリにあとから届いた結果は捨てる）。取り消しは `Store::cancel` で同期に `CANCELLED` にし、実行中のタスクがページ境界でフラグを見て `nextUri` に `DELETE` を送る。
- Trino への要求には `X-Trino-Client-Capabilities: PARAMETRIC_DATETIME` を必ず付ける（timestamp の精度）。
- 文の種類は先頭のキーワードで判定し、SQL を読む判定が複数の場所にある（`classification.rs`、`results::ResultFile::of`、`content_type.rs` など）。判定を変えるときは docs/dev/architecture.md の「Athena の見え方への変換」で、対にする判定を確かめる。

## テスト

結合テストは `tests/common/mod.rs` の `Harness`（偽 Trino・偽 S3・本物の `athena_local::router` を同じプロセスに立てる）を使う。ヘルパの一覧は docs/dev/architecture.md の「テストの足場」。

- `config.rs` のテストは本物の環境変数を触らない（テストが並列に走るため）。`parse_results` に環境変数を読むクロージャを渡して差し替える。
- ユニットテストはインラインの `#[cfg(test)] mod tests` に置く。例外は本体とテストを合わせて 400 行を超えたファイルで、テストを子モジュール `<name>/tests.rs`（`mod.rs` 無し）に出している: `src/results.rs`（#75）と、`src/operation/` の `classification.rs`・`target_table.rs`・`table_format.rs`（#162）。

## ドキュメントの置き場

| 置き場 | 書くこと | 言語 |
|---|---|---|
| `README.md` | 概要、クイックスタート、docs へのリンク | 英語 |
| `docs/*.md` | athena-local の現在の挙動（利用者向け） | 英語 |
| `docs/dev/architecture.md` | 内部の詳しい地図（モジュール・関数・判定の細部と由来） | 日本語 |
| `docs/dev/measurements/` | 本物の Athena などで測った事実。日付・issue・スクリプトのパス・投げたもの・返ったもの。上書きせず、食い違いは両方を残して採用した判断を書く | 日本語 |
| `docs/dev/unmeasured.md` | 未実測の一覧。測ったら measurements に書いてここから消す | 日本語 |
| `docs/dev/roadmap.md` | 未実装機能と優先度、クライアント調査 | 日本語 |
| `docs/dev/decisions.md` | 決着済みの設計判断（この CLAUDE.md にある約束は重ねない） | 日本語 |
| `docs/dev/development.md` | ビルド・テスト・CI・リリース・toolbox | 日本語 |
| `CHANGELOGS.md` | 版の間で何が変わったか。1 項目 1〜2 行 | 英語 |
| `tools/measure/`、`tools/e2e/`、`tools/toolbox/`、`tools/dev.sh`、`compose.yml`、`tools/compose/` | 本物の Athena に投げる実測スクリプト、compose の実機検証の足場、足場を動かす toolbox のイメージと呼び口（dev サービス）、足場の環境（trino / minio などのサービス）とその付属物（カタログ、tls、jdbc-client） | — |

- **この CLAUDE.md には、毎回の作業で要る規則と不変条件だけを書く。** モジュールの細部は docs/dev/architecture.md、決着した判断とその理由は decisions.md、手順は development.md に書き、ここには重ねない（#190）。
- 作業中のノート（`.claude/issue-notes/<番号>.md` と、その issue の足場）は、いま進めている issue のぶんだけを置く。**新しい issue に着手したら、ブランチを切った直後に過去の issue のノートを `git rm -r .claude/issue-notes` で全部消してから進める**（Skill が新しいノートを書く前に消す。理由は decisions.md。過去のノートは git の履歴にある）。
- ノートに書いた実測の結果表は `docs/dev/measurements/` へ、後の開発でも効く設計判断は `docs/dev/decisions.md` へ、残った未実測は `docs/dev/unmeasured.md` へ、その issue の PR をマージする前に写す。ノートは PR に残してよいが、正はつねに docs/dev 側で、ノートの記述と食い違ったら docs/dev を信じる。
- 実測スクリプトは issue 番号の接頭辞を付けず、内容で名前を付けて `tools/measure/` に置き、先頭のコメントに issue 番号を書く。

## 開発上の約束

- **本物の Athena に合わせることが目的**。文言、エラーコード、型の見え方、ファイル名などは本番 Athena で実測した値に合わせ、コメントに「2026-09-14 実測」のように書いてある。実測していない振る舞いは推測で埋めない。項目を省く（例: `substatement_type` が `None`）か、`docs/caveats.md` に「not measured」と書いて `docs/dev/unmeasured.md` に載せる。測ったら `docs/dev/measurements/` に記録し、unmeasured から消す。設計・範囲の選択肢を人間に示すときは、実測に近い方を推奨にする（規模・issue の範囲・別 issue に分けられることは推奨を下げる理由にせず、コストとして添える。#242）。
- **SQL の本文を書き換えるのは、本物の Athena がそう扱うと実測した場合だけ**（理由と経緯は decisions.md の「SQL の字句処理と文の分類」）。Athena と Trino の書き方の違い（小数リテラルの型、DDL、`OPTIMIZE` / `VACUUM`）を Trino で通すための変換はせず、`docs/caveats.md` に回避策を書く（手元で通って本物で落ちる SQL を作らない）。書き換えは `athena-sql` が持つ元の SQL の位置（バイト範囲）の差し替えだけにし、触らない部分は 1 文字も変えず、Trino のエラーの位置を受け取った SQL に戻せるようにする。書き換えた SQL は実行の中だけに置き、`Store` の `Query` は受け取ったままにする（例外は、本物の `Query` がそうなっている、文の前後の空白と `;` を落とす入口の正規化（#240）と、DESCRIBE などの修飾を落とす書き換え（#242）だけ）。全体を包む（`EXECUTE IMMEDIATE`）か別のクエリを投げる（構文チェックの `PREPARE`、パラメータ分類の `SELECT (<値>)`）で足りるなら書き換えない。
- 挙動を変えたら `docs/`（対応オペレーションは `api.md`、Athena との差分は `caveats.md`、結果ファイルは `result-files.md` など）と CHANGELOGS.md の `[Unreleased]` も更新する。CHANGELOG は 1 項目 1〜2 行の箇条書きで、挙動の説明は書かずに docs の節へリンクする。CHANGELOG のバージョンは Docker Hub のイメージタグと一致させ、README の compose 例のタグも合わせる。
- コメント、テスト名（日本語の文）、エラーメッセージ、コミットメッセージ（「〜する」で終わる一行）、PR の本文は日本語。README・`docs/*.md`・CHANGELOG は英語、`docs/dev/` は日本語。
- **ユーザーへの返答は常に日本語で書く。** 途中の状況報告、質問、最終報告、コマンドの説明もすべて日本語。英語は README・`docs/*.md`・CHANGELOG の本文とコード中の識別子だけ。
- 大きな `Response` を `Result` で返すときは `Box<Response>` にする（`clippy::result_large_err` 対策）。
- HTTP クライアントは TLS 無しでビルドしている（`reqwest` は `default-features = false`）。Trino にも S3 にも `http://` だけでつなぐ。
- Rust edition 2024（let chains を使っている）。Docker のビルドイメージは `rust:1.98`。toolbox（`tools/toolbox/Dockerfile`）も同じタグ。変えるときは両方。
- **検証の足場（`tools/e2e`）と実測（`tools/measure`）はホストで直接叩かず `tools/dev.sh` 経由で toolbox の中で動かす**（ホストの PATH の同名の別物を踏まないため。経緯は decisions.md、使い方は development.md）。足場は `aws` を使わず、S3 は toolbox の `mc` で `minio:9000` を直接見る。資格情報はホストのシェルで export した `AWS_*` を渡す（`~/.aws` も読める）。生データはホストの `~/athena-*-measurements`。人間が対話で本物の AWS に投げる `aws` はホストのまま。
