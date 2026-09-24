# ロードマップ

本物の Athena と比べて足りない機能を、2026-09-15 から 09-16 にかけての調査結果から整理したもの。優先度の高い順に並べる。着手するときは issue を立て、終わったら利用者向けの docs（対応オペレーションは [api.md](../api.md)、Athena との差分は [caveats.md](../caveats.md)）と CHANGELOG の `[Unreleased]` を更新して、この一覧から消す。

実装の前には、CLAUDE.md の約束どおり本物の Athena で応答を実測し、[measurements/](measurements/README.md) に記録する。測っていない挙動は [unmeasured.md](unmeasured.md) に、決着した設計判断は [decisions.md](decisions.md) に置く。

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

- [ ] [docs/caveats.md](../caveats.md) に回避策を書く。awswrangler は `ctas_approach=False` で使う
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
- `ResultReuseConfiguration` と、`ResultConfiguration` の暗号化の設定は無視している。[docs/caveats.md](../caveats.md) に記載済み。Grafana は `ResultReuseConfiguration` を送ってくる（`api.go:102`、確認済み）

### GetQueryExecution

- [ ] `ExecutionParameters` を返さない
- [ ] `EngineVersion` を返さない
- [ ] `Statistics` のうち `DataManifestLocation`、`QueryPlanningTimeInMillis`、`ServicePreProcessingTimeInMillis`、`ServiceProcessingTimeInMillis`、`ResultReuseInformation`、`DpuCount` を返さない

### GetQueryResults

- [ ] `QueryResultType` の `DATA_MANIFEST` を無視している
- [ ] `ColumnInfo.Nullable` が常に `UNKNOWN`。本物もこれまで `UNKNOWN` しか返していない（NULL 可の列も `UNKNOWN`。NOT NULL 列は本物で作れず測れない。#146、2026-09-24。[unmeasured.md](unmeasured.md) の「測れないもの」）

### エラー応答

- [ ] `InternalServerException` も HTTP 400 で返す
- [ ] `TooManyRequestsException` を返すことがない
- [ ] `InternalServerException` の本文の形（`AthenaErrorCode` の有無）。本物の応答はクライアントから誘発できず測れない（[unmeasured.md](unmeasured.md) の「測れないもの」。パース失敗と必須項目の欠落は #84 で実測して揃えた）

### ドキュメント

- [ ] この節の差分のうち [docs/caveats.md](../caveats.md) に書いていないものを書く

## 4. 当面やらないもの

- dbt-athena への対応：テーブルやスキーマの情報を Glue の API から取るので、Athena の API を増やしても動かない。Glue の代役が別に要る（未再確認）。
- Spark 系：ノートブック、セッション、計算の API。
- 管理系：キャパシティ予約、タグ、データカタログとワークグループの作成・更新・削除。
- 名前付きクエリとプリペアドステートメントの API：調査したクライアントの通常の経路には出てこなかった。
- SigV4 署名の検証。
