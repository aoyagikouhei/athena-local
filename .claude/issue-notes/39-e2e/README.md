# issue #39 Step 9: 実機検証の足場

`.claude/issue-notes/39-trino-probe/` の Trino 構成に MinIO を足し、本物の Trino
（`trinodb/trino:482`）と本物の S3 互換ストレージ（MinIO）を相手に athena-local を動かして、
DROP TABLE の結果ファイルがテーブルの形式（Hive / Iceberg）で変わることを確かめるための足場。
本物の AWS は一切使わない。

## 構成

- `docker-compose.yml` — Trino（Hive カタログ・Iceberg カタログ）と MinIO、バケットを作る
  使い捨てコンテナ（`minio-init`）
- `catalog/hive.properties` / `catalog/iceberg.properties` — `39-trino-probe` からコピーしたもの
- `verify.sh` — 起動からケース 1〜5 の判定、後始末までを 1 本でやるスクリプト

## 使っているポート・イメージ

| サービス | イメージ | ポート（ホスト側） |
|---|---|---|
| Trino | `trinodb/trino:482` | `8092`（`/v1/statement` 用。`39-trino-probe` は `8090`） |
| MinIO | `quay.io/minio/minio:latest` | `9002`（S3 API）／`9003`（コンソール） |
| MinIO 初期化 | `quay.io/minio/mc:latest` | 無し（使い捨て） |
| athena-local | （docker イメージは使わず `cargo build --release` の実行バイナリ） | `8087` |

MinIO のイメージは 2024 年以降 `minio/minio` / `minio/mc`（Docker Hub）が
`pull access denied` になり、`quay.io/minio/minio` / `quay.io/minio/mc` に移っている
（2026-09-21 実測）。

認証情報はローカル専用のダミー（`minioadmin` / `minioadmin`）。本物の AWS の認証情報は登場しない。

## 前提コマンド

`docker` / `docker compose` / `curl` / `jq` / `uuidgen` / `od` / `cargo`。

S3 側の確認（`.txt` や `.metadata` のバイト数・Content-Type・中身）は **aws cli を使わず**、
compose と同じ Docker ネットワークに繋いだ `minio/mc` の使い捨てコンテナで行う。
このマシンの `aws` コマンドは `docker run amazon/aws-cli` を呼ぶラッパーで、
`--network` を指定しないためホストにマップしたポート（`127.0.0.1:9002` など）に届かず
`Connection refused` になることを確認した（2026-09-21 実測）。同じ理由で他の環境でも
host 経由の aws cli は当てにしないほうがよい。

## 実行方法

```bash
cd .claude/issue-notes/39-e2e
./verify.sh
```

内部でやっていること:

0. **JDBC の検証をするときだけ**: `bash tls/make-cert.sh` で自己署名証明書を作る。
   **秘密鍵はリポジトリに入れない**ので、`tls/server.key` と `tls/server.crt` は手元で作る
   （`verify.sh` だけなら要らない。JDBC ドライバが平文 HTTP を拒むための TLS 終端に使う）
1. `docker compose up -d` で Trino・MinIO を起動し、バケット `athena-results` を用意する
2. Trino に直接（athena-local を経由せず）`iceberg.default` / `hive.default` スキーマと、
   DROP TABLE 対象の 2 テーブル（Iceberg 側・Hive 側それぞれ 1 つ、`CREATE TABLE ... AS SELECT`）を作る
3. `cargo build --release --locked` を実行し、`target/release/athena-local` をホスト上で起動する
   （Trino・MinIO ともホストにマップしたポート `127.0.0.1:8092` / `127.0.0.1:9002` に繋ぐ）
4. Athena API（`POST /` に `X-Amz-Target: AmazonAthena.StartQueryExecution` など）を叩いてケース 1〜5 を実行し、
   結果ファイルを `minio/mc` 経由で取得してバイト数・Content-Type・中身を確かめる
5. 結果を PASS / FAIL / SKIP の表にして表示する
6. athena-local プロセスを止め、`docker compose down -v` で後始末する（`trap` で必ず実行される）

## 環境変数

- `KEEP_UP=1` — テスト後に `docker compose down -v` をせず環境を残す（デバッグ用）。
  手動で後始末するときは `docker compose -f .claude/issue-notes/39-e2e/docker-compose.yml down -v`
- `SKIP_BUILD=1` — `cargo build` を省略し、既存の `target/release/athena-local` をそのまま使う
  （他エージェントが `target/` を使っていて自分ではビルドしたくないときなど）

証跡（athena-local のログ、取得した結果ファイルの実体と `od -An -tx1c` の出力）は
`mktemp -d` で作った一時ディレクトリに残る。パスは実行時のログと結果表の後に出力される。

## ケース

| # | 内容 | 期待 |
|---|---|---|
| 1 | `DROP TABLE`（Iceberg） | `<id>.txt` が 1 バイト（改行 1 つ）、Content-Type `application/octet-stream`、`.metadata` が 41 バイト |
| 2 | `DROP TABLE`（Hive） | `<id>.txt` が 0 バイト、Content-Type `binary/octet-stream`、`.metadata` 無し |
| 3 | `DROP TABLE IF EXISTS`（存在しない・Iceberg） | `<id>.txt` が 0 バイト、`.metadata` 無し（Phase 2 で対象テーブルの存在確認が入って初めて通る想定） |
| 4 | `CREATE TABLE`（Iceberg、素の CREATE） | 回帰確認。0 バイト・`.metadata` 無しのまま |
| 5 | `SELECT 1 AS n` | 回帰確認。`<id>.csv` が置かれる |

ケース 3 が FAIL の場合は「Phase 1 時点では失敗が想定どおり」という注記を結果表に自動で足す
（スクリプトは止めずに続ける）。

## 後始末を手動でやりたいとき

```bash
docker compose -f .claude/issue-notes/39-e2e/docker-compose.yml down -v
```

`verify.sh` は正常終了・異常終了のどちらでも `trap` で後始末するので、通常は何もしなくてよい。
