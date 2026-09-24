# エラー応答

リクエスト本文を解釈できないとき（`SerializationException`）、必須項目の欠落（枠組みの検証）、未対応のオペレーション（`UnknownOperationException`）の応答の形。オペレーションごとのエラーは各ファイルにある（`IDEMPOTENT_PARAMETER_MISMATCH` とトークンの検証は [client-request-token.md](client-request-token.md)、`WorkGroup is not found.` と `ListWorkGroups` の検証は [work-groups.md](work-groups.md)、`GetQueryResults` の検証は [query-results.md](query-results.md)）。`x-amzn-errortype` ヘッダが本物の応答に無いことは、それぞれの実測に書いてある。書き方は [README.md](README.md)。

対応する利用者向けの章: [docs/caveats.md](../../caveats.md) の「Errors and request bodies」。

## リクエスト本文の解釈とディスパッチ

### 既に実測済みだった事実（引き継ぎ）
- 日付: #9 は 2026-09-18、#83 は 2026-09-23 ／ issue: #84（実測は #9・#83） ／ スクリプト: 無し ／ 生データ: #9 `raw-20260918-052722`、#83 `raw-20260923-102134`
- 相手: 本物の Athena
- 返ったもの:

| 入力 | 本物の応答 | 出典 |
| --- | --- | --- |
| `ListWorkGroups` に `{"MaxResults": "1"}` | 400／`SerializationException`／`AthenaErrorCode` 無し／`STRING_VALUE can not be converted to an Integer` | #9 `raw-20260918-052722` ケース 5 |
| `GetQueryResults` に `{"QueryExecutionId": <実在>, "MaxResults": "1"}` | 同上（同じ形・同じ文言） | #83 `raw-20260923-102134` ケース 21 |
| `GetQueryResults` に `{"MaxResults": 1}`（`QueryExecutionId` 無し） | 400／`InvalidRequestException`／`INVALID_INPUT`／`1 validation error detected: Value null at 'queryExecutionId' failed to satisfy constraint: Member must not be null`（必須キーの欠落は枠組みの検証で、SerializationException ではない） | #83 ケース 22 |
| 生 HTTP の `StartQueryExecution` に `ClientRequestToken` 無し | 400／`InvalidRequestException`／`INVALID_INPUT`／`clientRequestToken is null or empty` | #83 1 ラウンド目 |

### リクエスト本文の解釈の失敗とディスパッチ
- 日付: 2026-09-23（10:50、1 ラウンド、46 項目すべて） ／ issue: #84 ／ スクリプト: `tools/measure/raw-parse-errors.py`（旧 `84-measure-raw-parse-errors.py`） ／ 生データ: `$HOME/athena-parse-errors-measurements/raw-20260923-105053`
- 相手: 本物の Athena（生 HTTP、SigV4 自前署名、`http.client`。クエリは 1 本も流さない）
- 投げたもの: 型違い・必須欠落・本文の異常・未知のキー・`null`・範囲外の整数、`X-Amz-Target` と `Content-Type` の省略・差し替え
- 返ったもの: すべて `x-amzn-errortype` ヘッダ無し・`x-amzn-requestid` あり。`SerializationException` は `AthenaErrorCode`／`ErrorCode` 無しで、`Message` は入力の形によって有る場合と無い場合がある

型違い → `SerializationException`（400）。文言は JSON の型 × 目的の型で決まる:

| JSON の値 | 目的が Integer | 目的が String | 目的が配列 | 目的が構造体 | 根拠 |
| --- | --- | --- | --- | --- | --- |
| 文字列 | `STRING_VALUE can not be converted to an Integer` | （正常） | `Expected list or null` | `Expected null` | 1, 2, 32, 34, 36 |
| 整数 | （正常） | `NUMBER_VALUE can not be converted to a String` | 未実測 | 未実測 | 9, 22, 29, 30, 33, 35（配列の要素でも同じ） |
| `true` | `TRUE_VALUE can not be converted to an Integer` | `TRUE_VALUE can not be converted to a String` | 未実測 | 未実測 | 3, 10, 23（`false` は未実測） |
| 小数 `1.5` | **200（1 に切り捨て）** | 未実測 | 未実測 | 未実測 | 4 |
| 配列 | `Start of list found where not expected` | 同左 | （正常） | 同左 | 6, 12, 25, 37 |
| オブジェクト | `Start of structure or map found where not expected.`（末尾にピリオド） | 同左 | 未実測 | （正常） | 7, 13, 26 |
| `null` | 無いのと同じ（200） | 任意なら無いのと同じ、必須なら欠落と同じ枠組みの検証 | 未実測 | 未実測 | 5, 11, 24 |
| Integer の範囲外 `99999999999` | `InvalidRequestException`／`INVALID_INPUT`／上限の検証（`less than or equal to 50`） | | | | 8 |

  - 必須キーの欠落（`{}`）は枠組みの検証: `1 validation error detected: Value null at '<lowerCamel>' failed to satisfy constraint: Member must not be null`（`queryExecutionId`・`workGroup`・`queryString` で実測。27, 31, 38）
  - 未知のキーは無視される（14, 28）
  - 型違いは枠組みの検証より先（15: `MaxResults: "1"` と空文字の同時 → 型違い。32: 型違いと必須欠落の同時 → 型違い）
  - 本文そのものの異常 → `SerializationException`、`Message` 無し（`{"__type":"SerializationException"}` だけ）: `{`（16）・空（17）・`null`（18）・`"x"`（20）・末尾カンマ（21）。例外は本文が配列 `[]`（19）で `Start of list found where not expected`
  - ディスパッチ: 未対応のオペレーション（39）・前置き無しの未対応名（40）・前置き無しの実在する名前 `ListWorkGroups`（41）・`X-Amz-Target` 無し（42）・小文字（43）はすべて 400／`{"__type":"UnknownOperationException"}`（`Message` 無し）
  - `Content-Type: application/json`（44）は 200 で `{Output, Version}` という別の形、`Content-Type` 無し（45）と `application/x-amz-json-1.0`（46）は 404 で XML `<UnknownOperationException/>`
  - ClientRequestToken の検査は parse の後（ケース 38 は `queryString` の欠落が先）
- 備考: 未実測の組み合わせの一部は #87 で実測した。`x-amzn-errortype` ヘッダは #2・#3・#9（[client-request-token.md](client-request-token.md)、[work-groups.md](work-groups.md)）でも一貫して応答に付かなかった。この #84 を含め 4 ラウンドとも同じ結果（athena-local は付け続けている。差分は #145）

### #84 で未実測だった型違いなどの組み合わせ
- 日付: 不明（ノートに日付が無い。時系列は実測 11:44（資格情報の期限切れで 59〜61 だけ）・11:47（全部）。#84（2026-09-23 11:09 出荷）の後なので 2026-09-23 と推定） ／ issue: #87 ／ スクリプト: `tools/measure/raw-parse-errors.py`（旧 `84-measure-raw-parse-errors.py` に 15 項目を足したもの。git の履歴（7836738、2026-09-23「実測スクリプトに #84 で未実測のまま残した型の組み合わせを足す」）と合う）
- 相手: 本物の Athena
- 投げたもの: 15 項目（#84 の未実測の組み合わせ）
- 返ったもの（ノートに書いてある範囲）: 実装した `type_mismatch` の腕から、次の組み合わせに本物が文言を返すと読める: `false`（`FALSE_VALUE`）、floating point → `NUMBER_VALUE`（小数 → String）、整数／真偽値 → 配列、map → 配列、整数／真偽値 → 構造体。小数 → Integer は `type_mismatch` が None を返す腕として固定（応答の形はノートに無い）。`strip_nulls` に配列の腕を足した（配列の要素の `null` の扱い）
  - 生データ `raw-20260923-114710/summary.txt`（11:47 の全項目ラウンドと見られる）の「ケース 55」（`StartQueryExecution` に `{"QueryString": "SELECT", "ExecutionParameters": [null], ...}`）: `__type: InvalidRequestException`／`AthenaErrorCode: MALFORMED_QUERY`／`ErrorCode: MALFORMED_QUERY`（`AthenaErrorCode` と同値）／`Message: line 1:7: mismatched input '<EOF>'. Expecting: '*', 'ALL', 'DISTINCT', <expression>`。`x-amzn-errortype` ヘッダ無し。`MALFORMED_QUERY` の本文にも `ErrorCode` キーが付くことをこのケースで確認できる
- 備考: 実際の文言・ステータスはノートに無い。README／CHANGELOG と生データを見る必要がある。タイトルの「揃えなかった 2 点」（#84 の小数の切り捨てと配列 → 入れ子の構造体）が今回揃えたのか揃えないままかはノートから判断できない。ケース 55 の `ErrorCode` の値はノートに転記されていなかったので、#113（2026-09-24）で生データを読み直して補った（転記漏れの補完で、新しい実測ではない）

### 参考（範囲外の同ラウンドの観測）
- 日付: 2026-09-23 ／ issue: #83 ／ スクリプト: 無し
- 相手: 本物の Athena
- 返ったもの:
  - `MaxResults` `"1"`（文字列）: `SerializationException`、`AthenaErrorCode` 無し、`STRING_VALUE can not be converted to an Integer`（21）
  - `QueryExecutionId` 無し: `INVALID_INPUT`、`1 validation error detected: Value null at 'queryExecutionId' failed to satisfy constraint: Member must not be null`（22）
  - 生 HTTP の `StartQueryExecution` は `ClientRequestToken` 無しで `clientRequestToken is null or empty`（1 ラウンド目。#84 の表では 400／`InvalidRequestException`／`INVALID_INPUT`）
- 備考: #84 で扱った
