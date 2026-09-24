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
