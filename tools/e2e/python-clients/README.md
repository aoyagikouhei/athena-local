# issue #111: Python クライアントの実機検証の足場

awswrangler 3.17.1・PyAthena 3.36.0・dbt-athena 1.11.1 を、athena-local の release バイナリと
本物の Trino（`trinodb/trino:482`）・S3 互換ストレージ（MinIO）に向けて動かす足場。本物の AWS は一切使わない。

## 構成

- 環境はルートの `compose.yml` の `trino`（カタログは `tools/compose/catalog/`）、`minio`、
  バケット `athena-results` を作る使い捨てコンテナ `minio-init`
- `setup-venvs.sh` — venv を 2 つ作る（`$HOME/.cache/athena-local-111/venv-wr` と `venv-dbt`。toolbox の HOME は `.toolbox/home` なので
  `.toolbox/home/.cache/athena-local-111` の下。
  dbt-athena 1.11.1 は `pyathena<3.35` を要求するので分ける）。`requirements-wr.txt`／`requirements-dbt.txt`
- `verify.sh` — 起動から判定、後始末までを 1 本でやる。終了コードは FAIL の件数
- `env.sh` — クライアントに渡す AWS 系の環境変数（`endpoint_url` は渡さず `AWS_ENDPOINT_URL*` で向ける）
- `common.py` — 結果行の出力、中継のログと MinIO の trace の区間読み、漏れの canary
- `check_awswrangler.py`・`check_pyathena.py`・`check_dbt.sh`（と `dbt/`）— クライアントごとの確認

## 使っているサービス・イメージ

| サービス | イメージ | 足場からの宛先 |
|---|---|---|
| Trino（`trino`） | `trinodb/trino:482` | `trino:8080` |
| MinIO（`minio`） | `docker.io/pgsty/silo:latest` | `minio:9000`（S3 API） |
| MinIO 初期化（`minio-init`） | `docker.io/pgsty/mc:latest` | 無し（使い捨て） |
| trace | toolbox の `mc`（バックグラウンドプロセス。#129） | `minio:9000` |
| athena-local（s3 モード） | `$CARGO_TARGET_DIR`（`tools/dev.sh` では `.toolbox/target`）の release/athena-local | dev 内の `127.0.0.1:8098` |
| athena-local（none モード） | 同上 | dev 内の `127.0.0.1:8099` |
| 中継（`../sdk-retry/drop_proxy.py`、`DROP_COUNT=0`） | toolbox の `python3` | dev 内の `127.0.0.1:8102` → `8098` |

同時実行は `docs/dev/development.md` の「足場の環境と同時実行」。

認証情報はローカル専用のダミー（`minioadmin` / `minioadmin`）。

## 実行方法

```bash
tools/dev.sh tools/e2e/python-clients/setup-venvs.sh          # 初回だけ（数分）
tools/dev.sh SKIP_BUILD=1 tools/e2e/python-clients/verify.sh  # release バイナリがあれば SKIP_BUILD=1
```

前提コマンドは `tools/dev.sh` 経由で動かす（toolbox に全部入っている。`docs/dev/development.md` の「検証の足場（toolbox）」）。

内部でやっていること:

1. 前提（コマンド、venv、release バイナリ）と、同じ compose プロジェクトで別の足場が動いていないかを確かめる。動いていれば止まる
2. `docker compose -f compose.yml down -v trino minio minio-init` → 同じサービスの `up -d`、Trino に `hive.default`・`iceberg.default` を作る
3. athena-local を s3 モード（8098）と none モード（8099）で起動し、s3 側の手前に中継を置く。
   中継は 1 リクエスト 1 行で `X-Amz-Target`（STS・S3 は `-`）をログに残す
4. toolbox 内で MinIO の `mc admin trace --json` をバックグラウンドで流し、既知のオブジェクトの GET が trace に出ることを確かめる
5. canary: boto3 の STS と Glue が中継に届いて athena-local が 4xx を返すこと、S3 の client が MinIO を指すこと
   （本物の AWS に漏れない証拠。summary の冒頭に「漏れ: 無し（canary で確認）」と出る）
6. check を逐次に流す（awswrangler → PyAthena → dbt）。中継のログと trace は check ごとに開始時の行数を控え、
   それより後だけを数える
7. 結果を `PASS / FAIL / SKIP / INFO` で表示し、athena-local・中継・trace を止めて、使ったサービスだけ `docker compose down -v` する（dev は残す）

## 環境変数

`tools/dev.sh KEEP_UP=1 tools/e2e/python-clients/verify.sh` のように、`tools/dev.sh` とコマンドの間に並べる。

- `KEEP_UP=1` — `docker compose down -v` をしない（手動なら `tools/dev.sh docker compose -f compose.yml down -v trino minio minio-init`）
- `SKIP_BUILD=1` — `cargo build` をしない
- `VENV_ROOT` — venv の置き場（既定 `$HOME/.cache/athena-local-111`。toolbox では `.toolbox/home/.cache/athena-local-111`）

証跡（athena-local・中継のログ、check ごとの出力、dbt の JSON ログと生成した `profiles.yml`、`pip freeze`）は
`/tmp/athena-local-issue111-py.*`（toolbox の中でもホストと同じパス）に残る。
