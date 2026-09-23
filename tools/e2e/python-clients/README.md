# issue #111: Python クライアントの実機検証の足場

awswrangler 3.17.1・PyAthena 3.36.0・dbt-athena 1.11.1 を、athena-local の release バイナリと
本物の Trino（`trinodb/trino:482`）・S3 互換ストレージ（MinIO）に向けて動かす足場。本物の AWS は一切使わない。

## 構成

- `docker-compose.yml` — Trino（カタログは `../minio/catalog` を読み取り専用でマウント）、MinIO、
  バケット `athena-results` を作る使い捨てコンテナ（`minio-init`）。プロジェクト名 `athena-local-issue111-py`
- `setup-venvs.sh` — venv を 2 つ作る（`$HOME/.cache/athena-local-111/venv-wr` と `venv-dbt`。
  dbt-athena 1.11.1 は `pyathena<3.35` を要求するので分ける）。`requirements-wr.txt`／`requirements-dbt.txt`
- `verify.sh` — 起動から判定、後始末までを 1 本でやる。終了コードは FAIL の件数
- `env.sh` — クライアントに渡す AWS 系の環境変数（`endpoint_url` は渡さず `AWS_ENDPOINT_URL*` で向ける）
- `common.py` — 結果行の出力、中継のログと MinIO の trace の区間読み、漏れの canary
- `check_awswrangler.py`・`check_pyathena.py`・`check_dbt.sh`（と `dbt/`）— クライアントごとの確認

## 使っているポート・イメージ

| サービス | イメージ | ポート（ホスト側） |
|---|---|---|
| Trino | `trinodb/trino:482` | `8097` |
| MinIO | `quay.io/minio/minio:latest` | `9006`（S3 API） |
| MinIO 初期化・trace | `quay.io/minio/mc:latest` | 無し（使い捨て） |
| athena-local（s3 モード） | `target/release/athena-local` | `8098` |
| athena-local（none モード） | 同上 | `8099` |
| 中継（`../sdk-retry/drop_proxy.py`、`DROP_COUNT=0`） | システムの `python3` | `8102` → `8098` |

認証情報はローカル専用のダミー（`minioadmin` / `minioadmin`）。

## 実行方法

```bash
tools/e2e/python-clients/setup-venvs.sh          # 初回だけ（数分）
SKIP_BUILD=1 tools/e2e/python-clients/verify.sh  # release バイナリがあれば SKIP_BUILD=1
```

内部でやっていること:

1. 前提（コマンド、venv、release バイナリ、ポートの空き）を確かめる。使用中のポートがあれば止まる
2. `docker compose up -d`、Trino に `hive.default`・`iceberg.default` を作る
3. athena-local を s3 モード（8098）と none モード（8099）で起動し、s3 側の手前に中継を置く。
   中継は 1 リクエスト 1 行で `X-Amz-Target`（STS・S3 は `-`）をログに残す
4. MinIO の `mc admin trace --json` を流すコンテナを立て、既知のオブジェクトの GET が trace に出ることを確かめる
5. canary: boto3 の STS と Glue が中継に届いて athena-local が 4xx を返すこと、S3 の client が MinIO を指すこと
   （本物の AWS に漏れない証拠。summary の冒頭に「漏れ: 無し（canary で確認）」と出る）
6. check を逐次に流す（awswrangler → PyAthena → dbt）。中継のログと trace は check ごとに開始時の行数を控え、
   それより後だけを数える
7. 結果を `PASS / FAIL / SKIP / INFO` で表示し、athena-local・中継・trace を止めて `docker compose down -v` する

## 環境変数

- `KEEP_UP=1` — `docker compose down -v` をしない（手動なら `docker compose -f tools/e2e/python-clients/docker-compose.yml down -v`）
- `SKIP_BUILD=1` — `cargo build` をしない
- `VENV_ROOT` — venv の置き場（既定 `$HOME/.cache/athena-local-111`）

証跡（athena-local・中継のログ、check ごとの出力、dbt の JSON ログと生成した `profiles.yml`、`pip freeze`）は
`/tmp/athena-local-issue111-py.*` に残る。
