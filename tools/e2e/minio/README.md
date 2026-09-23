# issue #39 Step 9: 実機検証の足場

ルートの `compose.yml` の Trino と MinIO を使い、本物の Trino
（`trinodb/trino:482`）と本物の S3 互換ストレージ（MinIO）を相手に athena-local を動かして、
DROP TABLE の結果ファイルがテーブルの形式（Hive / Iceberg）で変わることを確かめるための足場。
本物の AWS は一切使わない。

## 構成

- 環境はルートの `compose.yml` の `trino`（Hive カタログ・Iceberg カタログ。カタログは `tools/compose/catalog/`）、`minio`、
  バケットを作る使い捨てコンテナ `minio-init`
- `verify.sh` — 起動からケースの判定、後始末までを 1 本でやるスクリプト
- `cases-dml-retention.sh` — ケース 10〜12・14（issue #111）の関数。`verify.sh` が `source` する（単独では実行しない）
- `lib.sh` — ケースが共有するヘルパ（結果表、Trino への直接アクセス、athena-local の起動と API 呼び出し、MinIO 側の検証。issue #116）。`verify.sh` が `source` する（単独では実行しない）

## 使っているサービス・イメージ

| サービス | イメージ | 足場からの宛先 |
|---|---|---|
| Trino（`trino`） | `trinodb/trino:482` | `trino:8080` |
| MinIO（`minio`） | `quay.io/minio/minio:latest` | `minio:9000`（S3 API） |
| MinIO 初期化（`minio-init`） | `quay.io/minio/mc:latest` | 無し（使い捨て） |
| athena-local | （docker イメージは使わず `cargo build --release` の実行バイナリ。`$CARGO_TARGET_DIR`（`tools/dev.sh` では `.toolbox/target`）の release/athena-local） | dev 内の `127.0.0.1:8087` |

同時実行は `docs/dev/development.md` の「足場の環境と同時実行」。

MinIO のイメージは 2024 年以降 `minio/minio` / `minio/mc`（Docker Hub）が
`pull access denied` になり、`quay.io/minio/minio` / `quay.io/minio/mc` に移っている
（2026-09-21 実測）。

認証情報はローカル専用のダミー（`minioadmin` / `minioadmin`）。本物の AWS の認証情報は登場しない。

## 前提コマンド

`tools/dev.sh` 経由で動かす（toolbox に全部入っている。`docs/dev/development.md` の「検証の足場（toolbox）」）。

S3 側の確認（`.txt` や `.metadata` のバイト数・Content-Type・中身）は、toolbox に入っている `mc` で
`minio:9000` を直接見る（`mc alias set local http://minio:9000 ...`。ホストの aws は使わない。#129）。

## 実行方法

```bash
tools/dev.sh tools/e2e/minio/verify.sh
```

**JDBC ドライバからの検証（issue #46）は `../../measure/jdbc-metadata.sh` が一本でやる**
（証明書・公式ドライバの取得・compose・athena-local の起動・4 ケース × `ResultFetcher` 2 通り・
S3 に置かれた `.metadata` の回収まで）。
**SHOW 文の `.txt.metadata` の検証（issue #57）は `../../measure/jdbc-show-metadata.sh`**（同じ足場。
`Main.java` の 2 つ目の引数 `57` で SHOW のシナリオに切り替え、`ResultFetcher` 3 通りで行数を突き合わせる）。
`verify.sh` は athena-local を dev 内の `127.0.0.1:8087` で待たせるので
tls-proxy など他のコンテナからは届かず、JDBC の検証には使えない（JDBC は `0.0.0.0` で待たせる jdbc-drivers の足場と上の 2 本）。

内部でやっていること:

0. **JDBC の検証をするときだけ**: `tools/dev.sh bash tools/compose/tls/make-cert.sh` で自己署名証明書を作る。
   **秘密鍵はリポジトリに入れない**ので、`tools/compose/tls/server.key` と `server.crt` は手元で作る
   （`verify.sh` だけなら要らない。JDBC ドライバが平文 HTTP を拒むための TLS 終端に使う）
1. `docker compose -f compose.yml down -v trino minio minio-init` → `up -d trino minio minio-init` で Trino・MinIO を作り直し、
   バケット `athena-results` を用意する
2. Trino に直接（athena-local を経由せず）`iceberg.default` / `hive.default` スキーマと、
   DROP TABLE 対象の 2 テーブル（Iceberg 側・Hive 側それぞれ 1 つ、`CREATE TABLE ... AS SELECT`）を作る
3. `cargo build --release --locked` を実行し、`$CARGO_TARGET_DIR`（`tools/dev.sh` では `.toolbox/target`）の release/athena-local を起動する
   （Trino・MinIO にはサービス名の `trino:8080` / `minio:9000` で繋ぐ）
4. Athena API（`POST /` に `X-Amz-Target: AmazonAthena.StartQueryExecution` など）を叩いてケース 1〜5 を実行し、
   結果ファイルを `mc` 経由で取得してバイト数・Content-Type・中身を確かめる
5. ケース 14 の前に athena-local を `ATHENA_LOCAL_RETENTION_SECONDS=1` で再起動する（ログは `athena-local-retention.log`）
6. 結果を PASS / FAIL / SKIP の表にして表示する
7. athena-local プロセスを止め、使ったサービスだけ `docker compose down -v trino minio minio-init` で後始末する（`trap` で必ず実行される。dev は残す）

終了コードは結果表の FAIL の件数（issue #111。SKIP は数えない）。起動の失敗などで途中で止まったときは 1。

## 環境変数

`tools/dev.sh KEEP_UP=1 tools/e2e/minio/verify.sh` のように、`tools/dev.sh` とコマンドの間に並べる。

- `KEEP_UP=1` — テスト後に `docker compose down -v` をせず環境を残す（デバッグ用。次に流した足場の開始時に消える）。
  手動で後始末するときは下の「後始末を手動でやりたいとき」
- `SKIP_BUILD=1` — `cargo build` を省略し、既存の `$CARGO_TARGET_DIR`（`tools/dev.sh` では `.toolbox/target`）の release/athena-local をそのまま使う
  （他エージェントが同じ置き場を使っていて自分ではビルドしたくないときなど）

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
| 6前 | `ALTER TABLE ... ADD COLUMNS`（Athena の綴り） | Trino の構文エラーで `StartQueryExecution` が弾く |
| 6 | `ALTER TABLE ... ADD COLUMN`（Hive） | `<id>.txt` が 0 バイト、Content-Type `application/octet-stream`、`.metadata` が 38 バイト |
| 7 | `ALTER TABLE ... ADD COLUMN`（Iceberg） | `<id>.txt` が 0 バイト、`.metadata` 無し |
| 8 | `ALTER TABLE ... SET PROPERTIES`（Iceberg） | 対象外の ALTER が巻き込まれていないこと。`<id>.txt` が 0 バイト、`.metadata` 無し |
| 9 | `MERGE INTO ... USING (VALUES ...)`（Iceberg。issue #56） | `<id>.csv` は置かれず、`<id>.csv.metadata` の field 2 が `MERGE`、field 3 が 2、以降が本物の Athena の `rows bigint` 列とバイト単位で同じ（Trino 482 で 2026-09-22 実測） |
| 10 | `UPDATE ... SET s = 'z' WHERE n = 1`（Iceberg。issue #111） | ケース 9 と同じ形で、field 2 が `UPDATE`、field 3 が 1（結果の詳細に `.metadata` のバイト数も出す） |
| 11 | `DELETE FROM ... WHERE n = 2`（Iceberg。issue #111） | ケース 9 と同じ形で、field 2 が `DELETE`、field 3 が 1 |
| 12 | `UPDATE`（Hive。非 ACID。issue #111） | Trino が拒否して FAILED。`<id>.csv` も `<id>.csv.metadata` も置かれない（SUCCEEDED なら FAIL） |
| 14 | 保持期限 1 秒で再起動して `SELECT 1 AS n`（issue #111） | SUCCEEDED の 2.5 秒後の `GetQueryExecution` が 400 `QUERY_EXECUTION_NOT_FOUND`、その後も `<id>.csv` と `<id>.csv.metadata` が残る。400 にならなければ FAIL（保持期限の破棄の退行） |

ケース 3 が FAIL の場合は「Phase 1 時点では失敗が想定どおり」という注記を結果表に自動で足す
（スクリプトは止めずに続ける）。

## 後始末を手動でやりたいとき

```bash
tools/dev.sh docker compose -f compose.yml down -v trino minio minio-init   # リポジトリのルートで
```

`verify.sh` は正常終了・異常終了のどちらでも `trap` で後始末するので、通常は何もしなくてよい。
