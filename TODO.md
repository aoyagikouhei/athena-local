# TODO

本物の Athena と比べて足りない機能を、2026-09-15 から 09-16 にかけての調査結果から整理したもの。優先度の高い順に並べる。着手するときは issue を立て、終わったら README（Supported API / Caveats）と CHANGELOG の `[Unreleased]` を更新して、この一覧から消す。

実装の前には、CLAUDE.md の約束どおり本物の Athena で応答を実測する。

## 調べ方と確度

- API 定義は botocore 1.43.94 同梱の `athena/2017-05-18/service-2.json` を使った。オペレーションは 70 あり、athena-local が実装しているのは 4 つ。
- クライアントはソースを読んだ。PyAthena 3.36.0、awswrangler 3.17.1、dbt-athena 1.11.1、Grafana athena-datasource 3.3.4、aws-sdk-athena 1.97.0（Rust）、botocore 1.43.94。
- Athena JDBC 3.8.1 はソースが非公開なので、ドキュメントと jar の定数プールを調べただけ。
- 「確認済み」は該当行を読み直したもの。「未再確認」は調査で行番号付きで報告されたが、読み直していないもの。

## 1. 場面によって必要になるもの

### ListDatabases、ListTableMetadata、GetTableMetadata

- [ ] 実装する
- 使うクライアント
  - PyAthena の SQLAlchemy 方言：スキーマ、テーブル、列の取得に使う（`pyathena/sqlalchemy/base.py:254`、`270-275`、`285-307`、確認済み）。テーブルが無いときはエラーコード `MetadataException` を期待する。テーブルとビューは `TableType` の `EXTERNAL_TABLE` などと `VIRTUAL_VIEW` で見分ける。ビューの定義は `SHOW CREATE VIEW` の SQL で取る（`base.py:342`、確認済み）。
  - Grafana のクエリエディタ（`api.go` のクライアント定義 27-32 行、確認済み）。
  - JDBC のテーブル一覧（jar の調査とリリースノートのみ）。
- メモ：Trino に `SHOW` や `information_schema` の別のクエリを投げれば組み立てられ、SQL の本文を書き換えない方針と両立する。`TableType` やパラメータの値は実測する。

### ListDataCatalogs

- [ ] 実装する
- 使うクライアント：Grafana の設定画面（`api.go:241` の `DataCatalogs`、確認済み）。こちらも `NextToken` を辿る。JDBC も参照する（jar の調査のみ）。
- メモ：カタログ名は `TRINO_CATALOG_MAP` の別名に関わるので、ワークグループの一覧（#9 で対応済み）とは別に扱う。

### GetDataCatalog

- [ ] 実装する
- 使うクライアント：dbt-athena が `awsdatacatalog` 以外のカタログを使うとき（未再確認）。

### DataManifestLocation、マニフェスト、UNLOAD

- [ ] README に回避策を書く。awswrangler は `ctas_approach=False` で使う
- [ ] 必要になったら実装を検討する
- 使うクライアント
  - awswrangler の既定の `read_sql_query`（`ctas_approach=True`、`athena/_read.py:954`、確認済み）。`Statistics.DataManifestLocation` が無いと、エラーにならずに空の DataFrame を返す（`_read.py:150-151`、確認済み）。
  - PyAthena の `unload=True`：場所が無いと `ProgrammingError`（`pyathena/result_set.py:657-659`、確認済み）。
  - awswrangler の `unload_approach=True`（未再確認）。
- メモ：awswrangler の CTAS 方式は、Athena の書き方の CTAS（`external_location`、`format = 'PARQUET'`）を投げ（`athena/_utils.py:842-863`、確認済み）、一時テーブルを Glue の API で消す（`athena/_read.py:709`、確認済み）。Athena の API だけでは完結しない。

### ListQueryExecutions、BatchGetQueryExecution

- [ ] 実装する
- 使うクライアント
  - PyAthena のクエリキャッシュ：`cache_size` か `cache_expiration_time` を指定したとき（`pyathena/common.py:532-573`、`604-608`、確認済み）。
  - awswrangler の `athena_cache_settings`（未再確認）。

### GetQueryRuntimeStatistics

- [ ] 必要になったら検討する
- 使うクライアント：調査した範囲では見つからなかった。

## 2. 実装済みオペレーションの細かい差分

### StartQueryExecution

- [ ] API 定義の制約を検査していない。`QueryString` の長さ、`ExecutionParameters` の最少 1 件、ID の形など。本物のエラーは未実測
- `ResultReuseConfiguration` と、`ResultConfiguration` の暗号化の設定は無視している。README に記載済み。Grafana は `ResultReuseConfiguration` を送ってくる（`api.go:102`、確認済み）

### GetQueryExecution

- [ ] `ExecutionParameters` を返さない
- [ ] `EngineVersion` を返さない
- [ ] `Statistics` のうち `DataManifestLocation`、`QueryPlanningTimeInMillis`、`ServicePreProcessingTimeInMillis`、`ServiceProcessingTimeInMillis`、`ResultReuseInformation`、`DpuCount` を返さない

### GetQueryResults

- [ ] `QueryResultType` の `DATA_MANIFEST` を無視している
- [ ] `ColumnInfo.Nullable` が常に `UNKNOWN`。本物の値は未実測

### エラー応答

- [ ] `InternalServerException` も HTTP 400 で返す
- [ ] `TooManyRequestsException` を返すことがない
- [ ] `InternalServerException` の本文の形（`AthenaErrorCode` の有無）。本物の応答は未実測（パース失敗と必須項目の欠落は #84 で実測して揃えた）

### ドキュメント

- [ ] この節の差分のうち README に書いていないものを Caveats に書く

## 3. 未実測の一覧

各 issue の実装で「本物の Athena で測っていない」まま残した挙動。次に本物の Athena を叩ける機会に、まとめて測る。測ったら README の Caveats の「未実測」を書き換え、ここから消す。出典は issue #<番号> のノート（git の履歴に残る）。

### 結果ファイル（#1、#5、#6、#39、#43）

- [ ] `.csv` と `.metadata` の Content-Type が実測のたびに `binary/octet-stream` と `application/octet-stream` に割れる（#1・#17）。athena-local は多数派の `application/` 固定。`.txt` の側は #39 で決着した（`.metadata` を置く文だけ `application/`、それ以外は `binary/`。README に表あり）
- [ ] `CREATE TABLE` の重複の結果ファイル（Hive テーブルへの `ALTER TABLE` 失敗は #43 で実測済み: `RENAME TO` が理由を `<id>.txt` に書いた。失敗した `EXPLAIN` は #92 で実測済み: 何も置かない）
- [ ] `.metadata` の `timestamp with time zone`／`time with time zone`／`interval year to month`／`uuid`／`ipaddress` の Precision／Scale／CaseSensitive（field 7／8／10）の有無。**推測で実装している**
- [ ] 更新件数 0 の `UPDATE` / `DELETE` / `MERGE`（`DELETE ... WHERE false` など）で本物が更新件数の field 3 を出すか（athena-local は `18 00` を書く。0 行の `INSERT` は Hive・Iceberg とも `18 00` を書くと実測済み。#35・#91）
- `SHOW` 5 文（`SHOW TABLES` / `DATABASES` / `COLUMNS` / `PARTITIONS` / `TBLPROPERTIES`）の本物の `.txt.metadata` は不透明な形式（base64 で 312 文字）。#24 で解析したが特定できず、AWS 側の仕様が公開されない限り埋まらないので測る対象から外す。athena-local は素の protobuf を置く（README の Caveats に記載済み。JDBC が読めるかは下の「実クライアントでの疎通」）
- [ ] 失敗時の `GetQueryResults` が本物は文ごとに割れる（空の ResultSet／`INVALID_QUERY_EXECUTION_STATE`／`RESULT_NOT_FOUND`）。athena-local は常に `INVALID_QUERY_EXECUTION_STATE`

### ClientRequestToken と保持期限（#3、#4）

- [ ] `Catalog` の差が冪等性の衝突（`IDEMPOTENT_PARAMETER_MISMATCH`）になるか（`WorkGroup` は実測済み）
- [ ] 本物がトークンを正規化するか（前後の空白、`"`、`\`、大文字小文字）
- [ ] トークン長の制約（32〜128）がバイト数か文字数か（ASCII でしか測っていない）
- [ ] トークンの検証と他の検証エラー（`OutputLocation` 無し等）の優先順位
- [ ] トークン対応表と実行情報の本物の保持期間（60 秒を超えることまでは実測。既定の 1 時間は athena-local 独自の値）
- [ ] 期限切れのトークンを再送すると本物で新しい ID になるか、期限切れの ID の `GetQueryExecution` が `QUERY_EXECUTION_NOT_FOUND` か、`StopQueryExecution` が 400 か
- [ ] `Database`／`OutputLocation` の「省略」と「既定と同じ値の明示」を本物が別物として扱うか

### ワークグループ（#2、#9）

- [ ] `Configuration.EnableMinimumEncryptionConfiguration` の値（キーの存在だけ確認）
- [ ] 出力先が設定されたワークグループの `GetWorkGroup` の `ResultConfiguration` の形
- [ ] `GetWorkGroup` の実測値（`EnforceWorkGroupConfiguration=false` 等）が工場出荷時の既定か、コンソールで変えた後の値か
- [ ] `ListWorkGroups` の `MaxResults` 未指定時の既定ページサイズ（athena-local は 50）
- [ ] `ListWorkGroups` の順序が名前順であること（3 件だけの根拠）

### エラー応答

- [ ] `x-amzn-errortype` ヘッダ。#2、#3、#9 の実測で本物の応答に見つからなかったが、athena-local は送り続けている
- [ ] `AthenaErrorCode` の無い経路のうち `InternalServerException` の本文の形（パース失敗と未対応オペレーションは #84 で実測: `SerializationException`・`UnknownOperationException` はどちらも `AthenaErrorCode` 無し）

### 実クライアントでの疎通

- [ ] dbt-athena で `work_group` を設定して 1 回通す（#2 の人間検証リスト。Grafana は #9 で実施済み）
- [ ] awswrangler の `read_sql_query(ctas_approach=False)` を athena-local + Trino + MinIO で流し、`GetWorkGroup` の応答で例外にならないこと（#2 の人間検証リスト）
- [ ] 実 SDK でネットワーク断からのリトライを誘発し、同じ `ClientRequestToken` が再送されて `INSERT` が 2 回実行されないこと。同じトークンの高多重度の同時送信も（#3 の人間検証リスト。結合テストは 2 並列まで。#94）
- [ ] 失敗した DDL の `<id>.txt`（`FAILED: ` + 理由）を結果ファイルを読むクライアント（PyAthena、JDBC 3.x）が読んでも壊れないこと（#6 の人間検証リスト。どれも FAILED を先に見る想定）
- [ ] `ATHENA_LOCAL_RESULTS=s3` と保持期限の組み合わせ（捨てた後も結果 CSV は残る想定だが未確認）
- [ ] 長時間運用でメモリが実際に頭打ちになるか（保持期限による破棄の実効性）

## 4. 当面やらないもの

- dbt-athena への対応：テーブルやスキーマの情報を Glue の API から取るので、Athena の API を増やしても動かない。Glue の代役が別に要る（未再確認）。
- Spark 系：ノートブック、セッション、計算の API。
- 管理系：キャパシティ予約、タグ、データカタログとワークグループの作成・更新・削除。
- 名前付きクエリとプリペアドステートメントの API：調査したクライアントの通常の経路には出てこなかった。
- SigV4 署名の検証。

## 設計メモ：状態の保存先

- 当面はメモリ上の `Store` のままにする。状態の出入口は `Store` の公開メソッドにまとまり、呼び出しは `operation` モジュールだけなので、あとから保存先を差し替えやすい。
- DB を入れても、保持期限による破棄は別に必要になる。
- SQLite を検討する目安は次の二つ。
  - 再起動をまたいでクエリの履歴を残したくなったとき。
  - 名前付きクエリ、プリペアドステートメント、データカタログのように、作成・更新・削除する API を増やすとき。
- DuckDB は状態の保存には向かない。分析向けの列指向 DB で、Rust から使うと C++ の本体ごとビルドすることになり、2 アーキテクチャのイメージビルドも重くなる。
- 永続化するなら、次の前提を見直す。
  - `Store` の「本物の永続性は模さない」という方針。
  - Docker イメージが、書き込み無しで nobody ユーザーとして動く前提。
  - 再起動で途中になった実行の扱い。
