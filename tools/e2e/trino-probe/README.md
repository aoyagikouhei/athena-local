# trino-probe: Trino 単体の応答を直接確かめる足場

athena-local を通さず、手元の Trino（Hive / Iceberg カタログ、ローカルファイルのメタストア）の
`/v1/statement` を直接叩いて、athena-local が前提にしている値（`system.metadata.catalogs` の
`connector_name`、`probe_sql` の結果、DDL の `updateType`）を確かめる。MinIO も本物の AWS も使わない。

## 構成

- `docker-compose.yml` — Trino 1 台。`TRINO_TAG`（既定 `482`）、`TRINO_PORT`（既定 `8090`）、
  `CATALOG_DIR`（既定 `./catalog`）で差し替えられる。コンテナ名は `athena-local-issue39-trino`
- `catalog/` — `fs.local.enabled=true`（482 以降の名前）
- `catalog-legacy/` — `fs.native-local.enabled=true`（古い版の名前）
- `catalog-nofsflag/` — ファイルシステムの有効化行が無い（さらに古い版）
- `probe.sh` — 起動済みの Trino に一連の SQL を投げ、生の応答を `$OUT_DIR/<ラベル>.<ページ>.json` に残す（#39）
- `versions.sh` — 版ごとに compose を立て直して `probe.sh` を流し、値を表にする（#111）

## versions.sh

```bash
tools/e2e/trino-probe/versions.sh                     # 既定の 480 475 470 440 400
TRINO_TAGS=482 tools/e2e/trino-probe/versions.sh      # 対照（docs/dev/measurements/trino.md の #39 の表と完全一致で PASS）
```

- 版ごとに `catalog` → `catalog-legacy` → `catalog-nofsflag` の順に起動し、`SHOW SCHEMAS FROM hive` と
  `SHOW SCHEMAS FROM iceberg` が `error` 無しで返った構成を採用する。3 つとも通らなければ SKIP
- `/v1/info` の `nodeVersion` がタグと違えば FAIL（`TRINO_TAG` が compose に届かず 482 が走る事故を防ぐ）
- 旧版の値は INFO として記録し、482 と違う列を詳細に出す。終了コードは FAIL の件数
- 環境変数: `TRINO_TAGS`、`TRINO_PORT`（既定 `8104`。compose の既定 `8090` は request-errors と重なる）、
  `START_TIMEOUT`（既定 120 秒）、`PULL_TIMEOUT`（既定 600 秒）、`KEEP_UP=1`（最後の版を残す）
- 証跡は `/tmp/athena-local-issue111-trino.XXXXXX`（版ごとの試行の起動ログ・生の JSON・`summary.md`）
- 同じコンテナ名を使うので、`probe.sh` を手で流している最中には走らせない（既にコンテナがあれば止まる）
- probe.sh の準備（スキーマ・対照テーブル）が `error` になった版は、詳細に「準備の失敗」を出す（D1・D2・C1・C2 の値が Trino の違いではなく準備の失敗で変わるため）
- 版ごとに `docker compose down -v` する（`probe.sh` の C 節は `IF NOT EXISTS` 無しで CREATE するため）
- 前提コマンド: docker、docker compose、curl、jq、python3（`probe.sh` が使う）、ss
