# GetQueryResults

`GetQueryResults` の行（先頭行が列名かデータか）、ページング、`MaxResults`／`NextToken` の検証。失敗したクエリへの `GetQueryResults` は [result-files.md](result-files.md) の「失敗・取り消しのときの結果ファイル」、`EXPLAIN` の行の分け方と `Query Plan` 列の Precision は [statements.md](statements.md)、型違いの `MaxResults` は [errors.md](errors.md)。書き方は [README.md](README.md)。

対応する利用者向けの章: [docs/api.md](../../api.md)、[docs/caveats.md](../../caveats.md) の「Paging」。

## 先頭行

### GetQueryResults の先頭行が列名かデータか（既存の生データの読み直し）
- 日付: 生データは 2026-09-15〜09-22 の過去 5 ラウンド。読み直しの日付はノートに無い（時系列 19:31〜19:33。#57 が 2026-09-22 に #60 を起票しているので 2026-09-22 と推定） ／ issue: #60 ／ スクリプト: 無し（読み直し） ／ 生データ: `~/athena-*-measurements`（過去 5 ラウンド）
- 相手: 本物の Athena（過去ラウンドの生データ。新規ラウンド 0）
- 投げたもの: GetQueryResults 応答 130 件
- 返ったもの: DML（SELECT / EXPLAIN）は先頭行＝列名、UTILITY（SHOW TABLES / DATABASES / COLUMNS / CREATE TABLE / PARTITIONS / TBLPROPERTIES、DESCRIBE）は先頭行＝データで一貫。`.txt` の行数（見出し無し）とも一致
- 備考: 例外として SHOW FUNCTIONS は後に #80 で `.csv`・列名行つきと分かった（#76 の生データ）。`TABLE t` は #65 で DML と分かった

## UTILITY 文の ColumnInfo

### SHOW／DESCRIBE の GetQueryResults の列名と型（既存の生データの読み直し）
- 日付: 2026-09-24（読み直し。生データは 2026-09-23／24） ／ issue: #161（残りは #173） ／ スクリプト: 無し（読み直し） ／ 生データ: `~/athena-content-type-measurements/run-20260923-043027/c*-*.results.json`（#70）、`~/athena-unmeasured-batch-measurements/run-20260924-004554/r4/r4-show-create-view.results-1.json`（#146）、`run-20260924-062232/r5/*-show-create.results-1.json`（#151。Hive 外部・Hive CTAS・Iceberg 素の CREATE）、`run-20260924-095149/u1/u1-*-show-create.results-1.json`（#160。Hive 外部・Iceberg）
- 相手: 本物の Athena（engine version 3、workgroup `primary`）
- 投げたもの: 上のラウンドの `SHOW` 各文・`DESCRIBE`・`EXPLAIN` の GetQueryResults 応答の `ResultSetMetadata.ColumnInfo`
- 返ったもの（`CatalogName` は `hive`、`SchemaName`／`TableName` は空、`Nullable` は `UNKNOWN`、`Scale` は 0。Trino の列は athena-local が Trino 482 で見た値）:

| 文 | Name | Type | Precision | CaseSensitive | Trino の列 |
| --- | --- | --- | --- | --- | --- |
| `SHOW CREATE TABLE`（Hive 外部・Hive CTAS・Iceberg 素の CREATE・Iceberg の 5 本すべて） | `createtab_stmt` | `string` | 0 | false | `Create Table` / varchar |
| `SHOW CREATE VIEW` | `create view` | `varchar` | 0 | false | `Create View` / varchar |
| `SHOW TABLES` | `tab_name` | `string` | 0 | false | `Table` / varchar |
| `SHOW DATABASES` | `database_name` | `string` | 0 | false | `Schema` / varchar |
| `SHOW SCHEMAS`（#173 d3。下の項目） | `database_name` | `string` | 0 | false | `Schema` / varchar |
| `SHOW VIEWS` | `views` | `varchar` | 0 | false | （Trino に無い） |
| `SHOW PARTITIONS` | `partition` | `string` | 0 | false | （Trino に無い） |
| `SHOW TBLPROPERTIES` | `prpt_name`, `prpt_value` | `string` | 0 | false | （Trino に無い） |
| `SHOW COLUMNS` | `field`（1 列） | `string` | 0 | false | `Column`, `Type`, `Extra`, `Comment`（4 列） |
| `DESCRIBE` | `col_name`, `data_type`, `comment`（3 列） | `string` | 0 | false | 同上（4 列） |
| `DESC`（#173 d6。下の項目） | `col_name`, `data_type`, `comment`（3 列） | `string` | 0 | false | 同上（4 列） |
| ビューへの `DESCRIBE`／`SHOW COLUMNS`（#173 d5。下の項目） | `column`, `type`（2 列） | `varchar` | 0 | false | 同上（4 列） |
| `EXPLAIN` | `Query Plan` | `varchar` | 371（計画の文字数） | true | `Query Plan` / varchar（同じ。[statements.md](statements.md)） |

- 採用: `SHOW CREATE TABLE`／`SHOW CREATE VIEW` の 2 文は `operation::classification::fixed_column` で本物の列名・型に置き換える（#161）。Hive の `SHOW CREATE TABLE` の `.metadata`（`c10-show-create-table.metadata.bytes`、88 バイト）は同じ列（`createtab_stmt`／`string`、7／8／10 無し）で、置き換え後の athena-local の出力とクエリ ID 以外が一致する（tests/show_create.rs で固定）。Iceberg と `SHOW CREATE VIEW` の `.metadata` は不透明なので列は GetQueryResults でしか確かめられない
- 備考: `run-20260924-100851/u1` の `Create Table`／varchar／250／true は `TARGET=local`（athena-local 自身への実行）で、本物の値ではない。残りの `SHOW`／`DESCRIBE` は列数が違う文があるので #173 に分けた。表の `SHOW SCHEMAS`・`DESC`・ビューの 3 行は #173 のラウンド 1（下の「DESCRIBE／SHOW COLUMNS の行の形」）で測った値を、並べて読めるように足した（生データは下の項目のもの）

## DESCRIBE／SHOW COLUMNS の行の形

### DESCRIBE／SHOW COLUMNS の行の形（#173、ラウンド 1・2）
- 日付: 2026-09-24（ラウンド 1 は 20:58〜21:05、ラウンド 2 は 21:21〜21:23） ／ issue: #173 ／ スクリプト: `tools/measure/unmeasured-batch/items-utility-rows.sh`（項目 d1〜d8。d7 は d1 に含む。`run.sh` に登録） ／ 生データ: `~/athena-unmeasured-batch-measurements/run-20260924-115811/{d1..d7}/`（ラウンド 1）、`run-20260924-122125/d8/`（ラウンド 2）。要約は各 run の `summary.txt`
- 相手: 本物の Athena（engine version 3、workgroup `primary`）。StartQueryExecution はラウンド 1 が 43 回（後始末の DROP 7 本を含む）、ラウンド 2 が 6 回で、すべて SUCCEEDED。改行入りの列コメントは Glue が弾く（#146 r2）ので投げていない
- 投げたもの（`<DB>` は実在のデータベース名。テーブル名はすべて `athena_local_probe_173_*` の使い捨て）:
  - d1: Hive 外部テーブル 3 つ。(a) `ctl`: `(n int) PARTITIONED BY (p string)`、(b) `main`: 列名 19／20／21 文字（`c19_…`／`c20_…`／`c21_…`）、型 17 種（`bigint`／`smallint`／`tinyint`／`double`／`float`／`boolean`／`date`／`decimal(10,2)`／`varchar(10)`／`char(36)`／`string`／`timestamp`／`binary`／`array<string>`／`map<string,int>`／`struct<aa:int,b:int>`（20 文字）／`struct<aa:int,bb:int>`（21 文字））、コメント無し／`abc`／20 文字／21 文字、`PARTITIONED BY (p string COMMENT 'pc', q int, p21_… string)`、(c) `nonascii`: ``(`列名` int COMMENT 'コメント', n int)``。それぞれに `DESCRIBE`、(b) に `SHOW COLUMNS FROM`／`IN`、(c) に `SHOW COLUMNS FROM`
  - d2: Iceberg `(n int COMMENT 'abc', s string, ts timestamp, d decimal(10,2), arr array<string>, st struct<a:int>, c21_… bigint) PARTITIONED BY (s, bucket(4, n), day(ts))` に `DESCRIBE`／`SHOW COLUMNS FROM`
  - d3: `SHOW SCHEMAS`／`SHOW DATABASES`、それぞれ素・`LIKE '<DB の先頭 3 文字>*'`・`LIKE '<DB の先頭 3 文字>%'`
  - d4: Iceberg のテーブルを 1 つ作り、`SHOW TABLES`、`SHOW TABLES FROM <DB>`、`SHOW TABLES IN <DB> LIKE '<名前の先頭>*'`、`SHOW TABLES IN <DB> '<名前の先頭>.*'`、`SHOW TABLES IN <DB> '<名前>'`
  - d5: `CREATE VIEW <DB>.<v> AS SELECT 1 AS n, 'a' AS s` に `DESCRIBE`／`SHOW COLUMNS FROM`
  - d6: Hive 外部 `(n int) PARTITIONED BY (p string)` に `DESCRIBE` と `DESC`
  - d8: Iceberg `(n int, s string, ts timestamp, d2 date, ts2 timestamp, t_double double, t_float float, t_boolean boolean, t_binary binary, t_map map<string,int>, big bigint) PARTITIONED BY (year(ts), month(d2), hour(ts2), truncate(3, s))` に `DESCRIBE`／`SHOW COLUMNS FROM`（`hour` は同じ列に `year` があると Iceberg が弾くので別の列 `ts2`）
- 返ったもの（どの文も `Data` は 1 行 1 個。`.txt` は GetQueryResults の値を `\n` でつないだものとバイト単位で同じ、末尾改行なし。行の中の `\t` はタブ）:
  - **Hive の DESCRIBE の詰め方**（d1・d6）: ColumnInfo は `col_name`／`data_type`／`comment`（string、0、false）。各行は `<列名>\t<型>\t<コメント>` で、3 つのどれも 20 文字未満なら右を空白で 20 文字に詰め、20 文字以上はそのまま（`c20_…` は詰め無し、`c21_…` は切らない、`struct<aa:int,bb:int>`（21 文字）もそのまま、コメント `cmt21_…` もそのまま）。空のコメントは空白 20 個、`abc` は `abc` + 空白 17 個、`pc` は `pc` + 空白 18 個。末尾にタブは無い。幅は文字数（`列名` + 空白 18 個、`コメント` + 空白 16 個。本体 137 バイトで検算）。UpdateCount は無し、Content-Type は application、`.metadata` は 152 バイトの素の protobuf
  - **Hive のパーティション**（d1・d6）: パーティション列は上半分にも普通の列として出て、その後に `\t \t `、`# Partition Information\t \t `、`# col_name            \tdata_type           \tcomment             `（`# col_name` + 空白 12 個）、`\t \t ` の 4 行、続けてパーティション列をもう一度同じ形で並べる。`ctl` は 7 行 291 バイト、`main` は 34 行 1997 バイト。パーティションの無いテーブル（`nonascii`）は見出し行群が無い
  - **Hive の型の綴り**（d1）と、同じ型の Trino 482 の綴り（手元で確認）:

| Athena（Hive の DESCRIBE） | Trino の DESCRIBE |
| --- | --- |
| `int` | `integer` |
| `bigint`／`smallint`／`tinyint`／`double`／`boolean`／`date` | 同じ |
| `float` | `real` |
| `decimal(10,2)` | `decimal(10,2)` |
| `varchar(10)` | `varchar(10)` |
| `char(36)` | `char(36)` |
| `string` | `varchar` |
| `timestamp` | `timestamp(3)` |
| `binary` | `varbinary` |
| `array<string>` | `array(varchar)` |
| `map<string,int>` | `map(varchar, integer)` |
| `struct<aa:int,b:int>` | `row("aa" integer, "b" integer)` |

  - **SHOW COLUMNS**（d1・d2・d8）: ColumnInfo は `field`（string、0、false）の 1 列。行は列名 1 つ。Hive は DESCRIBE の列名と同じ詰め方（`c19_…` + 空白 1 個、`c20_…`・`c21_…` はそのまま、`列名` + 空白 18 個）で、パーティション列も含む（`main` は 27 行 = DESCRIBE の上半分と同じ）。`FROM` と `IN` は同じ結果。Iceberg は詰めない（d2 は 7 行 37 バイト、d8 は 11 行 59 バイト）。UpdateCount 0、Content-Type は binary、`.metadata` は 312 バイトの不透明な形式
  - **Iceberg の DESCRIBE**（d2・d8）: ColumnInfo は Hive と同じ 3 列。詰めない。行は `# Table schema:\t\t`、`# col_name\tdata_type\tcomment`、列ごとに `<列名>\t<型>\t<コメント>`（コメント無しは末尾が `\t`。d2 の `n\tint\tabc`、`s\tstring\t`）、`\t\t`、`# Partition spec:\t\t`、`# field_name\tfield_transform\tcolumn_name`、パーティションごとに 1 行。d2 は 15 行 278 バイト、d8 は 20 行 343 バイト。UpdateCount 0、Content-Type は binary、`.metadata` は 568 バイトの不透明な形式
  - **Iceberg の型の綴り**（d2・d8）: `int`（Trino `integer`）、`string`（`varchar`）、`timestamp`（`timestamp(6)`）、`decimal(10, 2)`（`decimal(10,2)`。**カンマの後に空白**）、`array<string>`（`array(varchar)`）、`struct<a: int>`（`row("a" integer)`。**コロンの後に空白**）、`map<string, int>`（`map(varchar, integer)`。**カンマの後に空白**）、`bigint`・`date`・`double`・`boolean`（同じ）、`float`（`real`）、`binary`（`varbinary`）
  - **Iceberg のパーティション行**（d2・d8。7 種）: `s\tidentity\ts`、`n_bucket\tbucket[4]\tn`、`ts_day\tday\tts`、`ts_year\tyear\tts`、`d2_month\tmonth\td2`、`ts2_hour\thour\tts2`、`s_trunc\ttruncate[3]\ts`。field_name は identity なら列名そのもの、ほかは `<列名>_<bucket|trunc|year|month|day|hour>`
  - **ビュー**（d5）: `DESCRIBE` も `SHOW COLUMNS FROM` も SubstatementType は **`DESC_VIEW`**。ColumnInfo は `column`／`type`（どちらも varchar、Precision 0、CaseSensitive false）の 2 列。行は `n\tinteger`、`s\tvarchar(1)`（Trino の綴り、詰め無し）、22 バイト。UpdateCount 0、Content-Type は binary、`.metadata` は 440 バイトの不透明な形式
  - **DESC**（d6）: `DESC t` は `DESCRIBE t` と同じ（SubstatementType `DESCRIBE_TABLE`、7 行 291 バイト、application、`.metadata` 152 バイト、UpdateCount 無し。行も一致）
  - **SHOW SCHEMAS**（d3）: 本物も受ける。SubstatementType `SHOW_DATABASES`、ColumnInfo は `database_name`（string、0、false）、`SHOW DATABASES` と同じ 5 行 93 バイト、素の名前（詰め無し）。`LIKE '…*'`／`LIKE '…%'` は `SHOW SCHEMAS`・`SHOW DATABASES` とも 0 行・0 バイト（ColumnInfo は付く、UpdateCount 0）
  - **SHOW TABLES**（d4）: `FROM <DB>`（14 行）、`IN <DB> LIKE '…*'`（1 行）、`IN <DB> '….*'`（1 行）、`IN <DB> '<名前>'`（1 行）はどれも `tab_name`（string、0、false）で、行は素の名前（詰め無し）
- 備考: 採用（2026-09-24、統括役とユーザーの判断 D1〜D3・D10・D11）: 詰め方・見出し行群・型の綴り・パーティション行・ビューの 2 列と `DESC_VIEW`・`DESC` をそのまま再現する。`SHOW SCHEMAS LIKE` の `*`／`%` が 0 行になった理由（パターンの意味）は分からず、未実測に残す。Iceberg の `struct` の複数フィールドの区切り、その他の変換、非 BMP 文字の幅も [../unmeasured.md](../unmeasured.md) に残す。#146 r2 のコメント `a\tb` → `a` は、詰めた後に先頭のタブまでを取ったものと読める（d1 の `abc` + 空白 17 個と両立する）

## ページングと MaxResults／NextToken の検証

### GetQueryResults のページング引数の検証（順序と文言）
- 日付: 2026-09-23（ラウンド 1 09:54 は全項目未測定、ラウンド 2 09:55 で 22 項目、ラウンド 3 10:21 で 31 項目） ／ issue: #83 ／ スクリプト: `tools/measure/raw-get-query-results.py`（旧 `83-measure-raw-get-query-results.py`）（AWS CLI は `MaxResults=0` や空の `NextToken` を送信前に弾くため生 HTTP） ／ 生データ: `$HOME/athena-get-query-results-measurements/raw-20260923-095406`（1）、`raw-20260923-095502`（2）、`raw-20260923-102134`（3。1〜22 は 2 と同一）
- 相手: 本物の Athena（生 HTTP、SigV4 自前署名）
- 投げたもの: クエリ 3 本（5 行・1500 行の `UNNEST(sequence(...))` と存在しないテーブルの SELECT）に対し、`MaxResults`／`NextToken` の各組み合わせで GetQueryResults。ListWorkGroups の 2 件同時も 1 件
- 返ったもの: すべてのエラーは HTTP 400／`InvalidRequestException`／`x-amzn-errortype` ヘッダ無し／`AthenaErrorCode` と `ErrorCode` が同じ値。検証の順序は **枠組みの検証 → ID の存在 → MaxResults の上限 → クエリの状態 → NextToken の形**

| 順 | 条件 | AthenaErrorCode | Message | 根拠のケース |
| --- | --- | --- | --- | --- |
| 1 | `NextToken` 空文字、`MaxResults` < 1（両方なら nextToken → maxResults の順で 1 文） | `INVALID_INPUT` | `N validation error(s) detected: <制約>; <制約>` | 5, 6, 7, 12, 13, 14, 16, 18, 20, 27 |
| 2 | ID が実在しない | `QUERY_EXECUTION_NOT_FOUND` | `QueryExecution <id> was not found` | 17, 19, **23**（1001 と同時でも NOT_FOUND） |
| 3 | `MaxResults` > 1000 | `INVALID_INPUT` | `MaxResults is more than maximum allowed length 1000` | 4, 15, **26**（FAILED のクエリでも上限のエラー） |
| 4 | 結果が無い（FAILED 等） | `INVALID_QUERY_EXECUTION_STATE` | `Query did not finish successfully. Final query state: FAILED` | 24, **25**（不正なトークンと同時でも状態のエラー） |
| 5 | `NextToken` が不正 | `INVALID_INPUT` | `Malformed nextPageToken <受け取った値>` | 8, 9 |

  - 制約の文言（ListWorkGroups の #9 実測と同文）: `Value at 'maxResults' failed to satisfy constraint: Member must have value greater than or equal to 1`、`Value at 'nextToken' failed to satisfy constraint: Member must have length greater than or equal to 1`
  - 2 件同時: `2 validation errors detected: <nextToken の制約>; <maxResults の制約>`（ケース 12、31: ListWorkGroups でも同じ形）
  - `MaxResults` 1001 と `NextToken` 空文字の同時は空文字のエラーだけ（13）。上限超過は枠組みの検証ではない
- 備考: 無し

### GetQueryResults の正常系
- 日付: 2026-09-23（同上） ／ issue: #83 ／ スクリプト: `tools/measure/raw-get-query-results.py`（旧 `83-measure-raw-get-query-results.py`）
- 相手: 本物の Athena
- 返ったもの:
  - `MaxResults` 1000 は通る（3）
  - `MaxResults` 無しの既定は列名行込みで 1000 行（28: 1500 行のクエリで 1000 行 + NextToken、29 も同じ、30: 2 ページ目は 501 行で NextToken 無し）。athena-local の既定 1000 と数え方（列名行込み）は一致
  - `NextToken` は長さ 100 の base64 らしい不透明な文字列。正しいトークンで 2 ページ目が取れ、`MaxResults` 1 なら 2 ページ目にも付く（10, 11）
  - `UpdateCount` は SELECT でも `0`（1〜3）
  - ワイヤ上の `ResultSet` には SDK のモデルに無い `ColumnInfos`・`ResultRows` も入っている（`case-28.json`。SDK が落とすので対応しない）
- 備考: 無し

### #83 で未実測だった 3 点（ページング検証）
- 日付: 不明（ノートに日付が無い。時系列は実測 11:25（1 ラウンド目）・11:29（2 ラウンド目）。#83（2026-09-23 10:37 出荷）の直後なので 2026-09-23 と推定） ／ issue: #85 ／ スクリプト: `tools/measure/raw-paging-leftovers.py`（旧 `85-measure-raw-paging-leftovers.py`。抽出には名前が無い。git の履歴（d8bb536・c68685b、2026-09-23）から特定）
- 相手: 本物の Athena
- 投げたもの: ListWorkGroups の上限と空文字の同時、RUNNING／CANCELLED のクエリへの不正な `NextToken`、0 行の結果への `NextToken`、トークン発行の規則を見るための重いクエリ
- 返ったもの（ノートに書いてある範囲）:
  - 1 ラウンド目: 13 項目 + 未測定 10（重いクエリが `sequence` の 5 万件制限で FAILED）。ここから「枠組みの上限 100000」と「0 行の UTILITY のトークン無視」を実装
  - 2 ラウンド目: 33 項目すべて（RUNNING／CANCELLED とトークン発行の規則）。ここから「満杯のページにトークン」を実装
- 備考: ノートは値の全表を持たず、実装の要点だけを書いている。「枠組みの上限 100000」が何の上限か（`MaxResults` の API 定義の上限と読めるが）、RUNNING／CANCELLED の順序の結論、「満杯のページにトークン」の正確な規則（`end - offset == limit` のとき発行）はノートの自己レビューの分岐（`Some(_) if rows.is_empty()`／`filter(<= len)`／`end - offset == limit`）から読み取るしかない。詳細は README／CHANGELOG と生データを参照する必要がある

## QUEUED のクエリへの GetQueryResults

### QUEUED を捉えようとした 5 本（捉えられず）
- 日付: 2026-09-24 ／ issue: #146（バッチは #113。未実測にしたのは #102） ／ スクリプト: `tools/measure/unmeasured-batch/run.sh`（項目 `e1`） ／ 生データ: `$HOME/athena-unmeasured-batch-measurements/run-20260924-004554/e1/`
- 相手: 本物の Athena（engine version 3、workgroup `primary`、Catalog `AwsDataCatalog`、Database `<DB>`）
- 投げたもの: `SELECT 1`〜`SELECT 5` を新しいトークンで続けて 5 本 `StartQueryExecution`。5 本を投げ終えてから、1 本ずつ `GetQueryExecution` と `GetQueryResults` を 1 回ずつ
- 返ったもの: 5 本とも、その `GetQueryExecution` の State が SUCCEEDED で、`GetQueryResults` も成功（列名行 `_col0` と値の 2 行、`UpdateCount` 0）。QUEUED は 1 本も見えなかった

  | 文 | `QueryQueueTimeInMillis` | `TotalExecutionTimeInMillis` | SubmissionDateTime（UTC） |
  | --- | --- | --- | --- |
  | `SELECT 1` | 47 | 283 | 00:55:16.370 |
  | `SELECT 2` | 75 | 303 | 00:55:17.101 |
  | `SELECT 3` | 86 | 340 | 00:55:17.838 |
  | `SELECT 4` | 78 | 319 | 00:55:18.562 |
  | `SELECT 5` | 80 | 318 | 00:55:19.313 |

- 備考: キューの待ちは 100 ミリ秒未満で、投げてから CLI で状態を見に行くまでの間（1 本目は 5 本を投げ終えた後）に終わっている。`Query has not yet finished. Current state: QUEUED` の文言は測れていない
