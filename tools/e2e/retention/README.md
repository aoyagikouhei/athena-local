# 保持期限とメモリの実機検証（#111 の項目 (5)）

`ATHENA_LOCAL_RETENTION_SECONDS` で終わった実行情報（結果の全行を含む）を捨てると、長く流したときの
athena-local の VmRSS が頭打ちになるかを確かめる。同じ負荷を保持 3600 秒（対照）と保持 1 秒で
`DURATION` 秒ずつ流して比べる。本物の AWS は使わない。

```bash
SKIP_BUILD=1 tools/e2e/retention/verify.sh                   # 既定（240 秒 × 2、約 10 分）
SKIP_BUILD=1 DURATION=3600 tools/e2e/retention/verify.sh     # 数時間の推移を見るとき
```

- compose は `../sdk-retry/docker-compose.yml`（Trino 482 + memory、8095、`athena-local-issue94-e2e`）を流用する。
  sdk-retry の `verify.sh` とは同時に流せない。athena-local はホストの release バイナリを 127.0.0.1:8101 で起動する。
- 負荷（`load.py`）: 逐次 1 本で Start → GetQueryExecution を 0.1 秒ごと → GetQueryResults 1 ページ。
  SQL は `SELECT x, lpad(cast(x AS varchar), 1000, 'x') AS pad FROM UNNEST(sequence(1, 2000)) AS t(x)`（約 2.2MiB/件）。
  5 秒ごとに `/proc/<pid>/status` の VmRSS/VmHWM と完了数を CSV に書く。最初の `WARMUP` 秒は判定から外す。
- 証跡: `/tmp/athena-local-issue111-retention.*`（`load-{high,low}.csv`、`.csv.json`、ログ、`summary.txt`）。

## 判定（`load.py --judge`。「伸び」は暖機後から最終までの VmRSS、前半・後半は暖機後の時間を 2 等分）

| 記号 | 条件 | 既定の閾値（環境変数） | 満たさないとき |
|---|---|---|---|
| (a) | 対照の伸び ≥ 100MiB かつ 後半の伸び ≥ 前半の 0.5 倍 | `JUDGE_GROWTH_MIN_MIB=100`、`JUDGE_SECOND_HALF_MIN_RATIO=0.5` | SKIP（対照不成立） |
| (b) | 保持 1 秒の伸び ≤ 対照の伸びの 1/4 | `JUDGE_GROWTH_MAX_RATIO=0.25` | FAIL |
| (c) | 保持 1 秒の後半の伸び < 前半の 0.5 倍 または ≤ 16MiB（「後半 < 前半」だけだと対照側でも通る。red で観測） | `JUDGE_SECOND_HALF_MAX_RATIO=0.5`、`JUDGE_FLAT_MAX_MIB=16` | FAIL |
| (d) | 最初の ID の GetQueryExecution が保持 1 秒で 400 `QUERY_EXECUTION_NOT_FOUND`、対照で 200 | — | FAIL（負荷の量によらないので対照不成立でも判定する） |
| (e) | 完了数の比（1 秒 / 対照）が 0.7〜1.3 | `JUDGE_DONE_RATIO_MIN=0.7`、`JUDGE_DONE_RATIO_MAX=1.3` | SKIP（対照不成立） |

対照不成立のとき (b)(c) は INFO で値だけ出す。`/proc` を読めなければ全体が SKIP、athena-local が起動しない・
1 件も SUCCEEDED にならなければ FAIL。`verify.sh` の終了コードは FAIL の件数。
`DURATION` を縮めるときは `JUDGE_GROWTH_MIN_MIB` も比例して下げる。

負荷は約 7 件/秒・1 件約 2MiB なので、対照（保持 3600 秒）側は 240 秒で約 3GiB 伸びる。`DURATION=3600` のように長く流すなら、`ROWS` を下げるか、対照側を短くしないとメモリを使い切る（2026-09-23 の実測）。
