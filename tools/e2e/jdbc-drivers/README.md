# issue #111: Athena JDBC 3.x の版ごとの実機検証

公式 Athena JDBC ドライバの複数の版を athena-local につなぎ、次の 2 つを確かめる足場。
本物の AWS は一切使わない（ドライバ jar の取得だけが外に出る。キャッシュ済みなら出ない）。

- (3) 失敗した DDL の `<id>.txt`（athena-local が `FAILED: ` + 理由を置く）をドライバが読みに行かないか
- (6) 旧版（3.0.0〜3.5.0）が athena-local の素の protobuf の `.txt.metadata`（SHOW 系）を読めるか

環境はルートの `compose.yml` の `trino` / `minio` / `minio-init` / `tls-proxy` と `jdbc-client`。
athena-local は dev 内の `0.0.0.0:8087` で待ち、tls-proxy が `dev:8087` で届く（JDBC からは `tls-proxy:8443`、S3 は `tls-proxy:9443`）。
始める前に、同じ compose プロジェクトで別の足場が動いていないかを確かめ、動いていれば何も立てずに止まる。
同時実行は `docs/dev/development.md` の「足場の環境と同時実行」。

## 構成

- `verify.sh` — 版 × ResultFetcher × シナリオのループと後始末、表の出力
- `lib.sh` — compose（`down -v trino minio minio-init tls-proxy` → 同じサービスの `up -d`）、証明書、ドライバの取得、
  athena-local の起動（`0.0.0.0:8087`）、mvn のビルド、JVM 1 回の実行（`timeout` で包む）。
  関数の多くは `tools/measure/jdbc-show-metadata.sh` の複製
- `judge.sh` — JVM 1 回分の判定と、版 × (fetcher, シナリオ) の表
- JVM 側は `tools/compose/jdbc-client/` の `Main.java`（位置引数: fetcher、シナリオ、`OutputLocation`、URL）と
  `FailedDdlScenario.java`（シナリオ `111`）

## 使い方

```bash
tools/dev.sh bash tools/compose/tls/make-cert.sh     # 新しい clone では最初に 1 回（無ければ verify.sh も作る）
tools/dev.sh SKIP_BUILD=1 tools/e2e/jdbc-drivers/verify.sh
tools/dev.sh DRIVER_VERSIONS="3.8.1 0.0.0" SKIP_BUILD=1 tools/e2e/jdbc-drivers/verify.sh   # 対照と「取れない版」だけ
```

前提コマンドは `tools/dev.sh` 経由で動かす（toolbox に全部入っている。`docs/dev/development.md` の「検証の足場（toolbox）」）。
環境変数は上のように `tools/dev.sh` とコマンドの間に並べる。

| 環境変数 | 既定 | 意味 |
|---|---|---|
| `DRIVER_VERSIONS` | `3.8.1 3.5.0 3.4.0 3.3.0 3.2.2 3.1.0 3.0.0` | 流す版。取れない版は SKIP |
| `SKIP_BUILD` | `0` | `1` で `cargo build` を省く |
| `KEEP_UP` | `0` | `1` で終了後に `docker compose down -v <サービス...>` をしない（手動なら `tools/dev.sh docker compose -f compose.yml down -v trino minio minio-init tls-proxy`） |
| `JVM_TIMEOUT` | `300` | JVM 1 回の上限秒。超えたらその回は SKIP（ハング） |

ドライバは `$HOME/.cache/athena-local-jdbc/athena-jdbc-<版>-with-dependencies.jar` に置く（toolbox の HOME は `.toolbox/home` なので
`.toolbox/home/.cache/athena-local-jdbc`）。無ければ
`https://downloads.athena.us-east-1.amazonaws.com/drivers/JDBC/<版>/...` から取り、jar の中に
`META-INF/services/java.sql.Driver` があるかで本物かを確かめる。

## 組み合わせ

| 版 | ResultFetcher | シナリオ |
|---|---|---|
| 3.8.1（対照） | 未指定（auto）・`S3`・`GetQueryResults` | 46・57・111 |
| 3.5.0・3.4.0 | 未指定（auto）・`S3` | 57・111 |
| 3.3.0・3.2.2・3.1.0・3.0.0 | `S3`（auto は 3.4.0 から） | 57・111 |

URL は全版 `jdbc:athena://`（3.1.0 で `awsathena` は非推奨）。出力先は回ごとに
`s3://athena-results/e2e-jdbc111/<版>/<auto|S3|GetQueryResults>/<シナリオ>/` に分ける。

## 判定

状態は PASS / FAIL / SKIP / INFO の 4 つ。SKIP の詳細には未測定の理由を書く。終了コードは FAIL の件数。

- 本体の前に 1 回: athena-local に `SELECT 1` を流して `<id>.csv` を作り、tls-proxy 経由で GET して、
  nginx のログに `GET /e2e-jdbc111/preflight/<id>.csv` の形で出ることを確かめる。出なければ全体を SKIP にして止まる
- 各回: `CONFIG` 行（JVM が実際に使った fetcher・シナリオ・URL・出力先）が要求と違えば FAIL
- `PREFLIGHT failed`（接続か `SELECT 1` の読み取りで失敗）: その回の接頭辞への GET が 1 件以上なら FAIL
  （S3 に届いたが処理できない）、0 件なら SKIP（接続の非互換）
- シナリオ 57: `RESULT SHOW_TABLES(対照)`・`SHOW_SCHEMAS`・`SHOW_COLUMNS` の 3 行がすべて `status=PASS` で PASS。
  準備の `[setup]` の失敗（3.5.0 以下の既知の NoSuchKey。`docs/result-files.md`）は INFO で別に出す
- シナリオ 111: 4 文とも `status=EXPECTED_SQLEXCEPTION` で `msg` に Trino の失敗理由があり、後続の `SELECT 1` が通り、
  `failures=0`、接頭辞の下に `.txt` が 4 件あり（対照。無ければ SKIP）、nginx のログでその接頭辞の下の
  `.txt*`（`.txt.metadata` を含む）への GET が 0 件なら PASS。`GetQueryResults` は S3 を読まないので INFO
- シナリオ 46: `failures=0` かつ終了コード 0 で PASS

証跡は `/tmp/athena-local-issue111-jdbc.XXXXXX/`（toolbox の中でもホストと同じパス）に残る（`<版>/<fetcher>-<シナリオ>.log` が JVM の出力、
`.nginx.log` がその時点の tls-proxy のログ、`summary.txt` が表）。
