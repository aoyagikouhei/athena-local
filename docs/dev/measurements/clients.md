# クライアント

本物の Athena ではなく、クライアント（AWS CLI、Athena JDBC 3.8.1、Grafana athena-datasource、awswrangler、PyAthena など）の挙動とソース読み。実機で測ったものの多くは athena-local を相手にしているが、記録するのは athena-local の挙動ではなくクライアント側の振る舞い（何を送るか、何を読むか、何で壊れるか）。書き方は [README.md](README.md)。

対応する利用者向けの章: [docs/clients.md](../../clients.md)、[docs/caveats.md](../../caveats.md) の「Clients and transport」。

## AWS CLI（botocore）

### AWS CLI（botocore）が送る ClientRequestToken
- 日付: 2026-09-17 ／ issue: #3 ／ スクリプト: 無し（統括役が Bash で直接）
- 相手: AWS CLI（botocore）。偽の HTTP エンドポイントに CLI を向け、実際に送られたボディを読んだ（本物の Athena ではない）
- 投げたもの: `aws athena start-query-execution` をトークンの有無・長さ・文字種を変えて
- 返ったもの:

  | 送ったもの | 結果 |
  | --- | --- |
  | トークン未指定 | CLI が **UUID v4（36 文字）**を自動で入れる。実ボディ: `{"QueryString": "SELECT 1", "ClientRequestToken": "a3865fbd-8580-4ffb-82a4-4618067fdf10"}` |
  | 空文字・31 文字 | botocore が**クライアント側で拒否**（`ParamValidation ... valid min length: 32`）。ワイヤに乗らない |
  | 32・128・129 文字 | ワイヤに到達。**botocore は上限 128 を検証しない** |
  | 空白・`"`・`\` を含む（32 文字以上） | そのまま到達。正規化されない |
  | 大文字 | そのまま到達。大小の正規化は無い |
  | 非 ASCII（日本語 32 字） | CLI が拒否（`ParamValidation`） |

  含意: SDK / CLI 経由では **32 文字未満は絶対に届かない**。athena-local 側の長さ検証が効くのは **128 超と生 HTTP クライアントだけ**。
- 備考: `aws` は Docker ラッパ（`~/.local/bin/aws` が `docker run ... amazon/aws-cli:latest`）で、`127.0.0.1` も `host.docker.internal` も届かず、ホストの LAN IP が要った。

## boto3 のリトライ

### boto3 がネットワーク断で同じ ClientRequestToken を再送するか（実機検証）
- 日付: 2026-09-23 ／ issue: #94 ／ スクリプト: `tools/e2e/sdk-retry/verify.sh`（`drop_proxy.py` と `check.py`） ／ 生データ: verify.sh が `/tmp/athena-local-issue94-e2e.*` に残す
- 相手: boto3 1.43.100（botocore 1.43.100。リトライは `mode=standard`、`max_attempts=5`）。athena-local の release ビルドと手元の Trino 482（memory コネクタ）。本物の Athena ではない
- 投げたもの: `start_query_execution`（`ClientRequestToken` 無し、INSERT 1 文）を、目印付きの `StartQueryExecution` の応答を最初の 2 回だけ落とす TCP の代理（リクエストは athena-local に届けて処理させ、応答を返さずに接続を閉じる）越しに 1 回呼ぶ。別に、同じトークンの `StartQueryExecution` を 50 スレッドから athena-local に直接同時に送る
- 返ったもの:
  - botocore が `ClientRequestToken` を UUID で補い、接続を 2 回閉じられても 3 回とも同じトークンで再送した（代理のログは drop・drop・relay の 3 行でトークンは同一）。`start_query_execution` は 1.3 秒で 1 つの ID を返し、クエリは SUCCEEDED
  - Trino に届いた構文チェックの `PREPARE` は 3 回（試行ごと。照合は構文チェックの後）、INSERT 本体は 1 回、表の行は 1 行
  - 50 並列: 全部 200、`QueryExecutionId` は 1 つ、所要 0.15 秒、Trino に届いた SELECT は 1 回。対照の違うトークン 2 つは ID が 2 つ
- 備考: 照合を外したビルド（`Store::submit` のトークン検索を常に空にする）で同じ足場を流すと INSERT 3 回・行 3・ID 50 個で 4 項目が FAIL になり、足場が欠陥を検知することを確かめた。結合テスト `tests/idempotency.rs` の `同じトークンを50本同時に送っても_id_は1つで実行は1本になる` が multi_thread ランタイムで同じ性質を固定する

## クライアントのソース読み

### クライアントが GetWorkGroup の応答から読む項目（ソースの読み取り）
- 日付: 2026-09-16 ／ issue: #2 ／ スクリプト: 無し
- 相手: クライアントのソース（awswrangler 3.17.1、Grafana athena-datasource、dbt-athena、botocore の API 定義）。実測ではない
- 投げたもの: ソースの grep と通読
- 返ったもの: 無いと**壊れる**もの:

  | 項目 | 壊れ方 |
  | --- | --- |
  | `WorkGroup`（トップレベル） | awswrangler が直接添字で `KeyError`（`_utils.py:168`）。Grafana が nil 参照で panic（`api.go:314`） |
  | `WorkGroup.Configuration` | 同上。どちらも直接添字・直接参照 |
  | `Configuration.EnforceWorkGroupConfiguration` | awswrangler が直接添字で `KeyError` |
  | `Configuration.EngineVersion.EffectiveEngineVersion` | Grafana が nil 参照で panic |

  壊れないが挙動が変わるもの: `ResultConfiguration.OutputLocation`（無いと awswrangler が実 AWS にバケットを作りに行く）。`EffectiveEngineVersion` の文字列は Grafana の `ResultReuseConfiguration` 付与の判定に使われる（`api.go:363-365`）。Grafana は `/workgroupEngineVersion` リソースエンドポイントからも呼ぶ（クエリ 0 件でも呼ばれる）。dbt-athena は `.get()` 連鎖なので何が欠けても落ちず、読むのは `ResultConfiguration.OutputLocation` と `EnforceWorkGroupConfiguration` だけ。botocore の API 定義では `WorkGroup` の必須は `Name` だけ、エラーは `InternalServerException` と `InvalidRequestException` の 2 つだけ。botocore の `WorkGroupName` は `[a-zA-Z0-9._-]{1,128}`。
  - awswrangler 3.17.1 の実 AWS 発信の経路: `read_sql_query` は既定が `s3_output=None`・`workgroup="primary"` なので必ず `GetWorkGroup` を呼ぶ。`_get_s3_output` は呼び出し側の `s3_output` もワークグループの `OutputLocation` も無いとき `create_athena_bucket()`（`sts.get_account_id()` と S3）を呼ぶ。呼び出し元は `_read.py:602`（`ctas_approach=False`、`if not wg_config.managed_results:` で守られている）と `_read.py:775`（`_unload`、`unload_approach=True`、**守られていない**）の 2 つ。既定の `ctas_approach=True` はこの経路に入らない。`EnforceWorkGroupConfiguration` の真偽は影響しない。
- 備考: 実測ではなくソース読みの事実として残す。

### クライアント側の見出し行の扱い
- 日付: 不明（抽出では直前の #60 の項目と「同上」。そちらは 2026-09-22 と推定） ／ issue: #60 ／ スクリプト: 無し
- 相手: PyAthena / awswrangler のソース（本物の Athena ではない）
- 返ったもの: PyAthena は先頭行の値が列名と一致したときだけ読み飛ばす値ベースの判定で、文の種類は見ない（`result_set.py` の `_is_first_row_column_labels`）。awswrangler は S3 の結果ファイルを読む経路が主で、GetQueryResults の経路は未確認
- 備考: ソースを読んだ観察

## Grafana athena-datasource

### Grafana athena-datasource と athena-local の実機検証
- 日付: 2026-09-18 ／ issue: #9 ／ スクリプト: 無し（scratchpad の `verify9/`。リポジトリには入れていない）
- 相手: athena-local 自身の観測（本物ではない）。Trino 482（`tpch` カタログ）、Grafana 12.3.0 + grafana-athena-datasource 3.3.4。`AWS_` 環境変数 0 個で実 AWS には出ていない
- 投げたもの／返ったもの（Grafana のクライアント挙動として後にも効く観測）:
  - Grafana の `jsonData.endpoint` が Athena のエンドポイント上書きになり、`ListWorkGroups` がこの `endpoint` 宛てに飛ぶ（athena-local を落とした状態で `operation error Athena: ListWorkGroups … Post "http://host.docker.internal:8081/": dial tcp 172.17.0.1:8081: connect: connection refused`）。
  - リソース API は `POST .../resources/workgroups`、本文 `{"region": …}`。設定画面が実際に送る `region` は `"__default"`、`"default"` でも `defaultRegion` に落ちる。
  - 51 件の構成で Grafana のリソース API は 51 件すべてを返し、無限ループしない。届いた `ListWorkGroups` はちょうど 2 回で、本文は 1 回目 `{}`、2 回目 `{"NextToken":"50"}`。**Grafana は `MaxResults` を送らない**（実機で確認）。
  - `jsonData.workgroup` を一覧に無い `nope` にしてもクエリは動く（`GetWorkGroup {"WorkGroup":"nope"}` → `StartQueryExecution`（`ClientRequestToken` は UUID）→ `GetQueryExecution` ×2 → `GetQueryResults`）。
  - Grafana のソース（v3.3.4 `pkg/athena/api/api.go:285-305`）: `ListWorkGroupsInput{NextToken: nextToken}` だけを送り、`if nextToken == nil` でループを抜ける（空文字チェック無し）。**`NextToken` を空文字で返すと無限ループ**、省略か `null` なら 1 回で終わる。`Name` が無いと `*cat.Name` で panic。
  - 一覧は設定画面でだけ呼ばれる（クエリ実行時は `GetWorkGroup`）。保存済みの名前が一覧に無いと候補から消えて入力欄が空表示になるが、クエリは動く。
- 備考: 検証 10 件すべて PASS。本物の実測ではない。awswrangler／dbt-athena／PyAthena は `ListWorkGroups` を呼ばない（ソースで裏取り。awswrangler はテストで `WorkGroups[].Name` を読むだけ）。botocore の `service-2.json`: `MaxWorkGroupsCount` は min 1／max 50、`Token` は min 1／max 1024 で pattern 無し、`paginators-1.json` に `ListWorkGroups` は無い。

## dbt-athena

### dbt-athena 1.11.1 を work_group 付きで athena-local につなぐ
- 日付: 2026-09-23 ／ issue: #111 ／ スクリプト: `tools/e2e/python-clients/verify.sh`（`check_dbt.sh`、`dbt/`） ／ 生データ: verify.sh が `/tmp/athena-local-issue111-py.*` に残す
- 相手: dbt-core 1.12.5 + dbt-athena 1.11.1（dbt-adapters 1.24.5、PyAthena 3.34.0、boto3/botocore 1.43.100、Python 3.14.6）。athena-local の release ビルド（s3 モード、`TRINO_CATALOG_MAP=awsdatacatalog=iceberg,AwsDataCatalog=iceberg`）と手元の Trino 482 + MinIO。本物の Athena ではない
- 投げたもの: profile は `type: athena`、`region_name: us-east-1`、`s3_staging_dir: s3://athena-results/dbt/`、`s3_data_dir: s3://athena-results/dbt-data/`、`database: awsdatacatalog`、`schema: default`、`work_group: wg111`、`threads: 1`（`endpoint_url` は書かず、`AWS_ENDPOINT_URL` と `AWS_ENDPOINT_URL_ATHENA` を X-Amz-Target を記録する中継に、`AWS_ENDPOINT_URL_S3` を MinIO に向けた）。`dbt debug`、`adapter.is_work_group_output_location_enforced()` の値をログに出すマクロを `dbt run-operation check_work_group`、`materialized='table'` の 1 モデルを `dbt run --select m111`
- 返ったもの:

  | コマンド | rc | 中継に届いたもの | 結果 |
  | --- | --- | --- | --- |
  | `dbt debug` | 0 | StartQueryExecution 1、GetQueryExecution 2、GetQueryResults 1 | 接続テスト（`select 1 as id`）が通った |
  | `dbt run-operation check_work_group` | 0 | GetWorkGroup 1（ほかは無し） | ログに `ENFORCED=False` |
  | `dbt run --select m111` | 2 | `AWSGlue.GetDatabases` 1（STS 0、Athena 0） | `An error occurred (UnknownOperationException) when calling the GetDatabases operation:`。スタックは `dbt/task/run.py:1313 before_run` → `runnable.py:883 create_schemas` → `runnable.py:858 list_schemas` → `dbt/adapters/athena/impl.py:1431 list_schemas`。SQL は 1 本も投げずに止まった |

- 備考: `dbt run-operation` は Glue も STS も呼ばず、`is_work_group_output_location_enforced()` の中で GetWorkGroup を 1 回だけ呼んだ（athena-local は `EnforceWorkGroupConfiguration=false` を返すので値は偽）。`dbt run` は Glue の `GetDatabases`（スキーマの一覧）が最初の壁で、CTAS の方言（`table_type`/`is_external`）までは届かない。Glue・STS の代役は範囲外（#111 の設計判断）。dbt-athena の impl が作る client は profile の `endpoint_url` を使わないので、`AWS_ENDPOINT_URL*` で向けないと本物の AWS に出る（`AWS_ENDPOINT_URL` を中継に向けた状態で Glue が中継に届いたことで確かめた）

## awswrangler

### awswrangler 3.17.1 の read_sql_query(ctas_approach=False)
- 日付: 2026-09-23 ／ issue: #111 ／ スクリプト: `tools/e2e/python-clients/verify.sh`（`check_awswrangler.py`） ／ 生データ: verify.sh が `/tmp/athena-local-issue111-py.*` に残す
- 相手: awswrangler 3.17.1（pandas 3.0.6、boto3/botocore 1.43.100、Python 3.14.6）。athena-local の release ビルド 2 本（s3 モードは `ATHENA_LOCAL_OUTPUT_LOCATION=s3://athena-results/py/`、none モード）と手元の Trino 482 + MinIO。本物の Athena ではない
- 投げたもの: `wr.config` は空のまま、`AWS_ENDPOINT_URL` と `AWS_ENDPOINT_URL_ATHENA` を X-Amz-Target を記録する中継（s3 モードの手前）に、`AWS_ENDPOINT_URL_S3` を MinIO に向けた。`read_sql_query("SELECT 1 AS n, 'a' AS s", database="default", ctas_approach=False)` を、F1 `s3_output`・`workgroup` とも未指定、F2 `workgroup="wg111"`、F3 F1 と同じで `AWS_ENDPOINT_URL_ATHENA` だけ none モードの athena-local に向けて（STS は中継のまま）
- 返ったもの:

  | 回 | 結果 | 中継に届いたもの |
  | --- | --- | --- |
  | F1 | 例外なし、DataFrame `[[1, 'a']]` | GetWorkGroup 1、StartQueryExecution、GetQueryExecution、GetQueryResults。STS 0 |
  | F2 | 同上 | 同上 |
  | F3 | `ResponseParserError: Unable to parse response (not well-formed (invalid token): line 1, column 0), invalid XML received.` | STS（X-Amz-Target 無し）1 だけ |

- 備考: GetWorkGroup の `OutputLocation`（s3 モードの athena-local が返す）を出力先に使い、`create_athena_bucket()`（STS と S3）に入らなかった。F3 はワークグループに `OutputLocation` が無いので `create_athena_bucket()` が STS の `GetCallerIdentity` を呼んだ（`AWS_ENDPOINT_URL` を手元に向けていなければ本物の STS に出る。`docs/caveats.md` の出力先の注意と同じ経路）。[ソース読みの項目](#クライアントが-getworkgroup-の応答から読む項目ソースの読み取り)の `_read.py:602` の経路を実機で確かめた

### awswrangler が GetQueryResults を読む経路の先頭行
- 日付: 2026-09-23 ／ issue: #111 ／ スクリプト: `tools/e2e/python-clients/verify.sh`（`check_awswrangler.py none`） ／ 生データ: verify.sh が `/tmp/athena-local-issue111-py.*` に残す
- 相手: awswrangler 3.17.1。athena-local の release ビルド（none モード）と手元の Trino 482。MinIO へのアクセスは `mc admin trace --json` で記録。本物の Athena ではない
- 投げたもの: boto3 で `OutputLocation` を付けずに `SELECT x FROM UNNEST(sequence(1, 1500)) AS t(x)` と `SELECT 'c' AS c` を開始し、SUCCEEDED の後に `wr.athena.get_query_results(<id>)`（`StatementType` が DML で `OutputLocation` が無いので `_fetch_api_result` に入る）
- 返ったもの:

  | クエリ | 行数 | 先頭 | 末尾 | S3 への GET |
  | --- | --- | --- | --- | --- |
  | 1500 行 | 1500 | 1 | 1500 | 0 |
  | 1 行 | 1 | c | c | 0 |

- 備考: awswrangler は 1 ページ目の先頭行を値を見ずに落とす（`_read.py:357`、`:383`）。athena-local は SELECT（DML）の 1 ページ目の先頭に列名行を入れるので、落ちるのは列名行で、ページ境界（1000 行）をまたいでも実データは欠けない。[クライアント側の見出し行の扱い](#クライアント側の見出し行の扱い)（#60）の「awswrangler は GetQueryResults の経路は未確認」をこれで埋めた

### PyAthena 3.36.0・awswrangler 3.17.1 の回帰確認
- 日付: 2026-09-23 ／ issue: #111 ／ スクリプト: `tools/e2e/python-clients/verify.sh`（`check_pyathena.py`、`check_awswrangler.py s3`） ／ 生データ: verify.sh が `/tmp/athena-local-issue111-py.*` に残す
- 相手: PyAthena 3.36.0（`pyathena[pandas]`、pandas 3.0.6）、awswrangler 3.17.1。athena-local の release ビルド（s3 モード、`TRINO_CATALOG_MAP=awsdatacatalog=iceberg,AwsDataCatalog=iceberg`）と手元の Trino 482 + MinIO。本物の Athena ではない
- 投げたもの: 型の行 2 行（int、bigint、double、decimal(10,2)、varchar（`,` `"` 改行 タブ 非 ASCII）、boolean、date、timestamp(3)、array、map、NULL）を PyAthena の既定 `Cursor` と `PandasCursor`、awswrangler の `read_sql_query(ctas_approach=False)` で。続けて Iceberg のテーブルに `CREATE TABLE`、`INSERT`、`SHOW TABLES IN iceberg.default`、`DESCRIBE`、CTAS、`DROP TABLE`、`DROP TABLE IF EXISTS`（CTAS 先）をそれぞれで。PyAthena の 2 つのカーソルでは Hive のテーブルの `CREATE TABLE` と `DROP TABLE` も
- 返ったもの:
  - 型の行: 3 通りとも 2 行で、int 列 `1, 2` と varchar 列 `a,b"c<改行>d<タブ>é日本`、`plain` が一致した。表記（1 行目）:

    | 読み方 | 1 行目 |
    | --- | --- |
    | PyAthena Cursor | `[1, 10, 1.5, Decimal('1.25'), 'a,b"c\nd\té日本', True, datetime.date(2026, 9, 23), datetime.datetime(2026, 9, 23, 12, 34, 56, 789000), [1, 2], {'k': '1'}, None]` |
    | PyAthena PandasCursor | `[1, 10, 1.5, Decimal('1.25'), 'a,b"c\nd\té日本', True, Timestamp('2026-09-23 00:00:00'), Timestamp('2026-09-23 12:34:56.789000'), '[1, 2]', '{k=1}', nan]` |
    | awswrangler | `[1, 10, 1.5, Decimal('1.25'), 'a,b"c\nd\té日本', True, datetime.date(2026, 9, 23), Timestamp('2026-09-23 12:34:56.789000'), '[1, 2]', '{k=1}', <NA>]`（dtypes `Int32, Int64, float64, object, string, boolean, object, datetime64[us], object, object, string`） |

  - 文ごと:

    | 文 | PyAthena Cursor | PyAthena PandasCursor | awswrangler |
    | --- | --- | --- | --- |
    | CREATE TABLE | 例外なし（0 行） | 例外なし（0 行） | 例外なし（空の DataFrame） |
    | INSERT | 例外なし（0 行） | 例外なし（0 行） | 例外なし（空） |
    | SHOW TABLES | 例外なし（1 行） | 例外なし（1 行） | 例外なし（空） |
    | DESCRIBE | 例外なし（2 行） | 例外なし（2 行） | 例外なし（空） |
    | CTAS | 例外なし（0 行） | 例外なし（0 行） | 例外なし（空） |
    | DROP TABLE（Iceberg） | 例外なし（0 行） | `OperationalError: No columns to parse from file` | 例外なし（空） |
    | DROP TABLE IF EXISTS（Iceberg の CTAS 先） | 例外なし（0 行） | `OperationalError: No columns to parse from file` | 例外なし（空） |
    | DROP TABLE（Hive） | 例外なし（0 行） | 例外なし（0 行） | （投げていない） |

- 備考: PandasCursor の DROP TABLE の例外は、Iceberg の DROP TABLE の `<id>.txt` が改行 1 個（1 バイト、列 0 個）であることによる。PyAthena の `pandas/result_set.py` の `_read_csv` は長さ 0 のときだけ空の DataFrame を返し、1 バイトだと `names=[]` のまま `pd.read_csv` に渡して pandas の `EmptyDataError` になる。本物も Iceberg の DROP TABLE に改行 1 個を置く（[result-files.md](result-files.md)、2026-09-20・21）ので本物でも同じになる見込み（推測。本物 + PyAthena では未実測）。Hive の DROP TABLE（0 バイトの `.txt`）は PandasCursor でも例外なく 0 行で読めたので、足場は Iceberg の 2 行を INFO（athena-local のずれではない）にし、Hive の DROP TABLE を合否に使う（統括役の判断、2026-09-23）。awswrangler は `ctas_approach=False` で出力先が `.csv` でない文（DDL・SHOW・DESCRIBE）を読まず空の DataFrame を返す。値の表記（date・timestamp・array・map・NULL）は読み方ごとに違うが、突き合わせたのは int と varchar だけ

## PyAthena

### 失敗した DDL の <id>.txt を PyAthena が読むか
- 日付: 2026-09-23 ／ issue: #111 ／ スクリプト: `tools/e2e/python-clients/verify.sh`（`check_pyathena.py`） ／ 生データ: verify.sh が `/tmp/athena-local-issue111-py.*` に残す
- 相手: PyAthena 3.36.0（pandas 3.0.6）。athena-local の release ビルド（s3 モード）と手元の Trino 482 + MinIO。MinIO へのアクセスは `mc admin trace --json` で記録。本物の Athena ではない
- 投げたもの: `DROP TABLE iceberg.default.nope_<run>` と `SHOW COLUMNS FROM hive.default.nope_<run>`（どちらも無いテーブル）を `PandasCursor` と既定 `Cursor` で。続けて `PandasCursor` で `SELECT 1 AS n`
- 返ったもの:

  | 文 | カーソル | 例外 | `<id>.txt` | `<id>.txt*` への GET/HEAD |
  | --- | --- | --- | --- | --- |
  | DROP TABLE（Iceberg） | PandasCursor | `OperationalError: TABLE_NOT_FOUND: line 1:1: Table 'iceberg.default.nope_<run>' does not exist` | あり | 0 |
  | DROP TABLE（Iceberg） | Cursor | 同上 | あり | 0 |
  | SHOW COLUMNS（Hive） | PandasCursor | `OperationalError: TABLE_NOT_FOUND: line 1:1: Table 'hive.default.nope_<run>' does not exist` | あり | 0 |
  | SHOW COLUMNS（Hive） | Cursor | 同上 | あり | 0 |

  後続の `SELECT 1 AS n` は `[[1]]`。
- 備考: PyAthena は `FAILED` を見た時点で `StateChangeReason` を `OperationalError` にし（`cursor.py:155-166`、`pandas/cursor.py:218-240`）、athena-local が置いた `FAILED: ` の `<id>.txt` も `.txt.metadata` も読みに行かない（trace の区間に GET・HEAD とも 0）。`cursor.query_id` は FAILED でも取れる

## Athena JDBC 3.8.1

### Athena JDBC 3.8.1 の読み方
- 日付: 2026-09-17 ／ issue: #5 ／ スクリプト: 無し（scratchpad の `e2e/Jdbc.java` / `jdbc.sh`）
- 相手: Athena JDBC 3.8.1（`eclipse-temurin:21-jdk`、TLS 経由で athena-local と MinIO へ）。本物の Athena ではない
- 投げたもの: `Jdbc.java` の 10 文 + 接続テスト。`ResultFetcher` を `auto`（既定）/ `S3` / `GetQueryResults` の 3 モードで
- 返ったもの: 3 モードとも例外は 1 件も出なかった（`NoSuchKey`、`Range Not Satisfiable` を含めてドライバの例外は 0）。

  | モード | 接続テスト | 10 文の結果 | `.metadata` の GET（nginx のアクセスログ） |
  | --- | --- | --- | --- |
  | `auto`（既定、`ResultFetcher` 未指定） | 通った | 例外 0。SELECT 2 列 1 行 / 0 行 SELECT 0 行 / SHOW TABLES 1 列 0 行 / DESCRIBE 1 列 1 行 / INSERT・CTAS updateCount=1 / CREATE・DROP updateCount=0 | **11 件**（200 が 8 件、404 が 3 件） |
  | `S3` | 通った | `auto` と同じ | **5 件**（すべて 200。`.txt.metadata` は 1 件も引かなかった） |
  | `GetQueryResults` | 通った | 例外 0。SHOW TABLES が 1 列 1 行で先頭行が `Table`、DESCRIBE が 1 列 2 行で先頭行が `Column` | **0 件**（S3 を一切読まない） |

  - `auto` では `<id>.csv.metadata`、`<id>.txt.metadata`、`<id>.metadata`（INSERT）、`tables/<id>.metadata`（CTAS）の 4 形すべてに GET が来た。ドライバのログに `S3MetadataFetcher … loaded query result metadata from "s3://results/athena/<id>.csv.metadata"`。
  - `auto` の 404 3 件は `.metadata` を置かない文（`CREATE TABLE t5`、`DROP TABLE t5c`、`DROP TABLE t5`）への `.txt.metadata` の GET。ドライバは `does not have query result metadata` と INFO で書いて既定のプレーンテキスト metadata で続行し、例外にしなかった。3.8.1 では `.metadata` の欠落は致命ではない。
  - 416（Range Not Satisfiable）が `auto` と `S3` で 1 件ずつ。いずれも 0 バイトの `SHOW TABLES` の `.txt` 本体への Range GET。ドライバは `output location … was empty` と書いて 0 行として扱った。
  - ドライバのログの grep: `metadata` 43 行、`Range` 9 行、`NoSuchKey` 0 行、`416` 0 行。
  - **JDBC 3.8.1 は `http://` の endpoint を受け付けない。** `com.amazon.athena.jdbc.support.EndpointHelper.constructEndpointUri` がスキーマ無しなら `https://` を足し、`https` 以外なら `The Athena endpoint "http://localhost:8084" is not an HTTPS endpoint` で `IllegalArgumentException`（3.8.1 の逆アセンブルで確認。無効化するプロパティは見つからなかった）。nginx で TLS を終端した。
  - JDBC 3.8.1 の `ConnectionTest` は `-- Athena JDBC driver connection test\nSELECT 1` を投げる。
- 備考: 「GetQueryResults モードだけ UTILITY の見出し行がデータ行に見える」（SHOW TABLES の先頭行が `Table`、DESCRIBE の先頭行が `Column`）は athena-local の `convert.rs` の作りによる当時の観測。公開情報として JDBC 3.x のリリースノート: 3.5.1 で「DDL query metadata の NoSuchKeyFound を修正」、3.3.0 で「0 バイトオブジェクトの Range Not Satisfiable を修正」、3.1.0 で「precision / scale が無ければ 0 にする」。

### Athena JDBC 3.x を athena-local につなぐための TLS 終端
- 日付: 2026-09-17（#5 の実機検証。#18 はその足場から引いた） ／ issue: #18 ／ スクリプト: 無し（#5 の実機検証の足場が scratchpad に残っており、`nginx.conf`／keytool／JDBC プロパティを逐語で引いた。JDBC プロパティは #5 の `Jdbc.java` から）
- 相手: Athena JDBC 3.x（#5 の実機検証では 3.8.1）＋ athena-local（本物ではない）。README の nginx 設定の検証は `nginx:1.27.0` の `nginx -t`
- 投げたもの: README に載せた nginx 設定を `nginx -t` に通し、openssl で生成した証明書と鍵で起動
- 返ったもの: `nginx -t` ok、生成した証明書と鍵でそのまま起動できた。openssl の生成コマンドは #5 の記録に無く、自分で走らせて SAN を確認した。nginx.conf から `ssl_certificate_key` の行を消すと `nginx -t` が `[emerg] no "ssl_certificate_key" is defined` で落ちる
- 備考: JDBC 3.x をつなぐには TLS 終端が要る（タイトルの主張。根拠は #5 の実機検証で、このノートには詳細なし）。nginx では `proxy_set_header Host $http_host`（SigV4 が Host を署名する）と `client_max_body_size 0` が要る（同じ足場から）。

### 列 0 個の `.metadata` を Athena JDBC が読めるか
- 日付: 2026-09-21 ／ issue: #39（実測は #46） ／ スクリプト: 無し
- 相手: Athena JDBC 3.8.1（#46 で実施）
- 備考: 当時は「ドライバが手に入らない」で未確認（Maven Central の `com.amazonaws:athena-jdbc` は Athena Federated Query の JDBC コネクタで `java.sql.Driver` が無く `No suitable driver found for jdbc:awsathena://`、Maven Central に「3.x」表記のバージョンは無い（calver の `2024.8.1`〜`2026.33.1` のみ）、委譲先が試した AWS の S3 直配布 URL 2 パターンは 404）。#46 で入手経路（`https://downloads.athena.us-east-1.amazonaws.com/drivers/JDBC/3.8.1/athena-jdbc-3.8.1-with-dependencies.jar`）が解け、41B・38B とも例外なく読むと確認。詳細は #46

### 列 0 個の `.metadata` を Athena JDBC 3.8.1 が読むか
- 日付: 2026-09-21（4 ラウンド、21:31-21:52） ／ issue: #46 ／ スクリプト: `tools/measure/jdbc-metadata.sh`（旧 `46-verify-jdbc-metadata.sh`）（#39 のノートが参照する名前）。足場は `tools/e2e/minio/`（旧 `39-e2e/`）（`docker-compose.yml`・`pom.xml`・`Main.java`）
- 相手: Athena JDBC 3.8.1（athena-local + nginx の TLS 終端 + MinIO 相手）
- 投げたもの: 下表の 4 ケースを `ResultFetcher` の既定（auto）と `S3` 明示の両方で
- 返ったもの:

| # | 文 | `.metadata` | ドライバのログ | 結果 |
|---|---|---|---|---|
| 1 | `DROP TABLE`（Iceberg） | 41 バイト（列 0 個） | `loaded query result metadata from "...txt.metadata"` | 例外なし。`hasResultSet=false updateCount=0` |
| 2 | `ALTER TABLE ... ADD COLUMN`（Hive） | 38 バイト（列 0 個） | `loaded query result metadata from "...txt.metadata"` | 例外なし。`hasResultSet=false updateCount=0` |
| 3 | `DROP TABLE`（Hive。対照） | 無し | `does not have query result metadata` | 例外なし（`5.md` の先行知見と一致） |
| 4 | `SELECT 1 AS n`（回帰） | 81 バイト | `loaded ...csv.metadata` | `columnCount=1`、`rows=1` |

  - auto と S3 明示のどちらも `failures=0`。nginx のアクセスログで `.metadata` への GET が 13 件（ドライバが S3 を直接読んだ）
  - 41 バイト: `0a 1b` + Trino のクエリ ID 27 バイト、`12 0a` + `DROP TABLE`。`ColumnInfo` は 0 個
  - 38 バイト: `0a 24` + `QueryExecutionId` の UUID 36 バイト。それだけ。`ColumnInfo` は 0 個
  - 結論: 列 0 個の `.metadata` を Athena JDBC 3.8.1 は例外なく読む。#39 の実装を見直す必要は無い
- 備考: `.metadata` を置かないとき（404 を INFO で流して続行）は `5.md` の先行知見

### Athena JDBC ドライバの入手と、コンテナ相手に必要な条件
- 日付: 2026-09-21 ／ issue: #46 ／ スクリプト: 無し
- 相手: Athena JDBC 3.8.1（配布元の確認と実行環境）
- 返ったもの:
  - `https://downloads.athena.us-east-1.amazonaws.com/drivers/JDBC/3.8.1/athena-jdbc-3.8.1-with-dependencies.jar` が HTTP 200、43,763,083 バイト。`META-INF/services/java.sql.Driver` = `com.amazon.athena.jdbc.AthenaDriver`、`com/amazon/athena/jdbc/support/EndpointHelper.class` あり
  - Maven Central の `com.amazonaws:athena-jdbc`（calver）は Athena Federated Query の JDBC コネクタで `java.sql.Driver` を持たず `No suitable driver found`
  - ラウンドの経緯（条件を 1 つずつ変えた対照）:

| ラウンド | 変えた条件 | 結果 |
|---|---|---|
| 1 | 初回 | `No suitable driver found`。ドライバ jar を `target/dependency/` に置けなかった（maven コンテナが root で作るのでホストから書けない） |
| 2 | jar をコンテナに直接マウント | 接続まで進み `UnknownHostException: tls-proxy`。`getent hosts` も `java.net.InetAddress` も解決できるのに、ドライバが内包する AWS SDK だけが失敗 |
| 3 | `/etc/hosts` に IP を固定 | `NoSuchBucketException`。ドライバの S3 クライアントが virtual-hosted style（`athena-results.tls-proxy`）でアクセス |
| 4 | MinIO に `MINIO_DOMAIN: tls-proxy` | 全ケース PASS |

  - `MINIO_DOMAIN` が要る（ドライバの S3 クライアントは virtual-hosted style でバケットを指す）
  - コンテナ内では `/etc/hosts` に固定が要る（ドライバが内包する AWS SDK は、Docker の埋め込みリゾルバ（`/etc/resolv.conf` の `search .`、`ndots:0`）が返す名前を `UnknownHostException` にする）
  - ドライバは `jdbc:awsathena://` を deprecated と警告する（`jdbc:athena://` を推奨）
  - 非標準ポート（8443）の `AthenaEndpoint` では streaming endpoint を自動構築しない（警告 1 行。動作に支障なし）
- 備考: 必須 2 条件は、1 条件だけ外したラウンドで落ちることを確かめてある（`MINIO_DOMAIN` 無し → `NoSuchBucketException`、`/etc/hosts` 固定無し → `UnknownHostException`）

### SHOW 系の `.txt.metadata` を Athena JDBC 3.8.1 が読むか
- 日付: 2026-09-22（2 ラウンド） ／ issue: #57 ／ スクリプト: `tools/measure/jdbc-show-metadata.sh`（旧 `57-verify-jdbc-show-metadata.sh`。抽出には名前が無い。git の履歴（1707a5c、2026-09-22）から特定）。足場は `tools/e2e/minio/`（旧 `39-e2e/`）
- 相手: Athena JDBC 3.8.1（athena-local 相手。足場は `tools/e2e/minio/jdbc-client/src/main/java/local/athenajdbccheck/Main.java`（旧 `39-e2e/jdbc-client/Main.java`））
- 投げたもの: 下表の文を `ResultFetcher` の auto・S3 明示・GetQueryResults の 3 モードで
- 返ったもの:

| 文 | `.txt.metadata` | auto | S3 明示 | GetQueryResults |
|---|---|---|---|---|
| `SHOW TABLES ... LIKE`（対照） | 72 バイト（`Table` 1 列） | `loaded query result metadata`、1 行 | 取りに行かない、1 行 | S3 を読まない、2 行（先頭が `Table`） |
| `SHOW SCHEMAS` | 74 バイト（`Schema` 1 列） | 同上、2 行 | 同上、2 行 | 3 行（先頭が `Schema`） |
| `SHOW COLUMNS FROM t` | 205 バイト（Trino の 4 列） | 同上、2 行 | 同上、2 行 | 3 行（先頭が `Column`） |
| `SHOW DATABASES`（原文） | 無し | `mismatched input 'DATABASES'`（400。`QueryExecutionId` なし） | 同左 | 同左 |
| `SHOW PARTITIONS t`（原文） | 無し | `mismatched input 'PARTITIONS'` | 同左 | 同左 |
| `SHOW TBLPROPERTIES t`（原文） | 無し | `mismatched input 'TBLPROPERTIES'` | 同左 | 同左 |
| `SELECT * FROM "t$partitions"`（対照） | `.csv.metadata` 64 バイト | 2 行 | 2 行 | 2 行 |

  - 3 モードとも `failures=0`。nginx のアクセスログで `.metadata` への GET は 10 件（auto 7 件、S3 明示 3 件、GetQueryResults 0 件）
  - 結論: JDBC 経由で athena-local に届く SHOW は 3 文（`SHOW TABLES` / `SHOW SCHEMAS` / `SHOW COLUMNS`）で、その `.txt.metadata`（素の protobuf）を既定の auto で読み込み例外を出さない。残る `SHOW DATABASES` / `SHOW PARTITIONS` / `SHOW TBLPROPERTIES` は Trino の文法に無く構文チェックで弾かれる
  - auto はログに `loaded query result metadata from ".../<id>.txt.metadata"` を残すが、`ResultSetMetaData` は `_col0:varchar` の 1 列で、`.txt` の 1 行を 1 値として返す（`SHOW COLUMNS` の 4 列はタブ区切りの 1 文字列になる）。metadata の列情報は列の見え方に使っていない
  - S3 を明示すると `.txt.metadata` を取りに行かない（`.csv.metadata` と INSERT の `.metadata` は取る）。理由はドライバのソースが非公開なので分からない
  - GetQueryResults は SHOW（UTILITY）で見出し行をデータとして返す（`SELECT` では読み飛ばす）
  - 余分な `.csv.metadata` 3 個は、ドライバが接続時に流す接続テストの `SELECT`
- 備考: GetQueryResults 列の「SHOW で +1 行」は当時の athena-local が UTILITY にも列名行を返していたため（#5 の「気づいたこと」4 と同じ観察）。#60 で本物（UTILITY は先頭行＝データ）に合わせて直したので、この +1 行は覆った（athena-local 側の当時の挙動）
