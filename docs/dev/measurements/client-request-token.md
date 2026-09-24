# ClientRequestToken

`StartQueryExecution` の `ClientRequestToken` による冪等性と、トークンの検証。CLI（botocore）がトークンをどう送るかは [clients.md](clients.md)。書き方は [README.md](README.md)。

対応する利用者向けの章: [docs/api.md](../../api.md)、[docs/caveats.md](../../caveats.md) の「Query lifecycle」。

### 冪等性（1 回目）
- 日付: 2026-09-17 ／ issue: #3 ／ スクリプト: `tools/measure/client-request-token.sh`（旧 `3-measure-client-request-token.sh`） ／ 生データ: `$HOME/athena-client-request-token-measurements/run-20260917-083914`（`summary.txt` はマスク済み）
- 相手: 本物の Athena
- 投げたもの: 同じトークン・同じパラメータで `StartQueryExecution` を再送（SUCCEEDED の後、終了後 60 秒、存在しないテーブルへの `SELECT` で FAILED にした後、取り消し後）。トークンを同じにしてパラメータを 1 つずつ変える。構文エラー（`SELEC 1`）の後に同じトークンで正しい SQL
- 返ったもの:
  - 同じトークン・同じパラメータで、次のすべてで同じ `QueryExecutionId` が返った: SUCCEEDED の後（3 回目）、終了後 60 秒たっても（`TTL_WAIT` の既定値の範囲内）、FAILED の後。
  - **パラメータ不一致のエラーの形。** `diff-querystring-changed.wire.txt` の生の応答本文（HTTP 400、`Content-Type: application/x-amz-json-1.1`、`Content-Length: 177`）:

    ```
    {"__type":"InvalidRequestException","AthenaErrorCode":"IDEMPOTENT_PARAMETER_MISMATCH","ErrorCode":"IDEMPOTENT_PARAMETER_MISMATCH","Message":"Idempotent parameters do not match"}
    ```

    (1) メッセージのキーが `Message`（大文字始まり）。(2) `AthenaErrorCode` と同じ値を持つ `ErrorCode` というキーが別に付く。**`x-amzn-errortype` ヘッダは応答ヘッダに無かった。** 応答ヘッダの全体は `Date` / `Content-Type` / `Content-Length` / `Connection` / `x-amzn-RequestId` の 5 つだけ（`diff-database-changed.wire.txt` / `diff-outputlocation-changed.wire.txt` も同じ形）。`QueryString` / `Database` / `OutputLocation` の 3 項目とも、この同じ形のエラーになった。
  - **衝突になる項目とならない項目。**

    | 項目 | 結果 |
    | --- | --- |
    | `QueryString` | 衝突（`IDEMPOTENT_PARAMETER_MISMATCH`） |
    | `QueryExecutionContext`(Database) | 衝突（同上） |
    | `ResultConfiguration`(OutputLocation) | 衝突（同上） |
    | `ExecutionParameters` | **衝突にならなかった。** 値を `["1"]` → `["2"]` に変えても成功し、同じ `QueryExecutionId` が返った |
    | `WorkGroup` | 未測定（`WORKGROUP2` 未設定のため skip） |

  - **構文エラーで弾かれたトークンは消費されない。** 1 回目（`SELEC 1`）は `InvalidRequestException`（Trino/Presto の構文エラーメッセージがそのまま `message` に乗る）。同じトークンで正しい SQL を投げたら成功し、新しい `QueryExecutionId` が返った（1 回目は `QueryExecutionId` を持たないので ID の比較はできないが、2 回目が新規に作られたこと自体は確認できた）。
  - **CLI の自動トークンは UUID v4（36 文字）。** `no-token-cli.auto-token.txt` に記録。
  - **`GetQueryExecution` の応答に `ClientRequestToken` は含まれない。** `idempotent-running-a-state.json` の `QueryExecution` 直下のキー一覧: `EngineVersion`、`Query`、`QueryExecutionContext`、`QueryExecutionId`、`ResultConfiguration`、`ResultReuseConfiguration`、`StatementType`、`Statistics`、`Status`、`SubstatementType`、`WorkGroup`。
- 備考: 「実行中」と「CANCELLED の後」はこの回では測れていない（`LONG_QUERY_SQL`＝`UNNEST(sequence(1, 5000))` 同士の CROSS JOIN、2500 万行が速すぎて、2 回目が届く前・取り消す前に `SUCCEEDED` になった）。2 回目の補助実測で埋まった。トークン無し・長さ境界は実測ホストに `python3 + botocore` が無く skip（3・4 回目で埋まった）。構文エラーの本文のキーが本当に小文字 `message` だったのかはノートからは断定できない（他の生本文はすべて `Message`。この 1 行はワイヤ本文の引用ではなく説明文）。

### 冪等性（2 回目・補助）
- 日付: 2026-09-17 ／ issue: #3 ／ スクリプト: `tools/measure/client-request-token-extra.sh`（旧 `3-measure-client-request-token-extra.sh`） ／ 生データ: `$HOME/athena-client-request-token-measurements/run-20260917-090119-extra`（`summary.txt` はマスク済み）
- 相手: 本物の Athena
- 投げたもの: 重くした `LONG_QUERY_SQL` で実行中の再送、`stop-query-execution` で取り消して `CANCELLED` を確認してからの再送、実在する別ワークグループ（`WORKGROUP2`）に変えての再送
- 返ったもの:
  - **実行中の再送。** 2 回目を投げた直後に 1 回目の State を確認したところ `RUNNING` だった。その状態で同じトークンで呼んでも同じ `QueryExecutionId` が返った。
  - **CANCELLED の後の再送。** 同じ `QueryExecutionId` が返った。
  - **WorkGroup を変えたときの衝突。** 成功し、同じ `QueryExecutionId` が返った。**衝突にならなかった**（`ExecutionParameters` と同じ扱い）。
  - トークンが消費される条件（summary.txt 末尾の表を転記したもの。CANCELLED と実行中は 2 回目の結果で埋めた版）:

    | 状況 | 同じ ID が返るか | 新しい実行が作られるか | エラー |
    | --- | --- | --- | --- |
    | 実行中 | 同じ（2回目の補助実測で確認。下記参照） | いいえ | - |
    | SUCCEEDED の後 | 同じ | いいえ | - |
    | 構文エラーで弾かれた後 | 比較不可(1回目にIDが無い) | はい | - |
    | FAILED の後 | 同じ | いいえ | - |
    | CANCELLED の後 | 同じ（2回目の補助実測で確認。下記参照） | いいえ | - |

- 備考: この回の生 HTTP 6 件は、ホストの `uv` が astral の uv ではなくユーザー独自のコマンドで、AWS に届く前に落ちていた（未測定）。スクリプトの実行系検出を「実際に `import botocore` できるか」で確かめる方式に直した。

### トークン無し・空文字・長さの境界（3・4 回目・生 HTTP）
- 日付: 2026-09-17 ／ issue: #3 ／ スクリプト: `tools/measure/client-request-token-extra.sh`（旧 `3-measure-client-request-token-extra.sh`）（`ONLY_RAW=1`）、`tools/measure/raw-client-request-token.py`（旧 `3-measure-raw-token.py`） ／ 生データ: 3 回目 `$HOME/athena-client-request-token-measurements/run-20260917-091659-extra`、4 回目 `$HOME/athena-client-request-token-measurements/run-20260917-093400-extra`
- 相手: 本物の Athena（SigV4 を自前署名した生 HTTP）
- 投げたもの: `ClientRequestToken` キー無し、空文字、31・32・128・129 文字（ASCII。UUID を連結して切り詰めたもの）
- 返ったもの:
  - **トークン無し（キーそのものが無い）。** HTTP 400。生の本文（`raw-token-omit.json` の `body`、4 回目）:

    ```
    {"__type":"InvalidRequestException","AthenaErrorCode":"INVALID_INPUT","ErrorCode":"INVALID_INPUT","Message":"clientRequestToken is null or empty"}
    ```

  - **空文字・31 文字**（一字一句同じ。`0` と `31` を区別しない）:

    ```
    {"__type":"InvalidRequestException","AthenaErrorCode":"INVALID_INPUT","ErrorCode":"INVALID_INPUT","Message":"1 validation error detected: Value at 'clientRequestToken' failed to satisfy constraint: Member must have length greater than or equal to 32"}
    ```

  - **129 文字**:

    ```
    {"__type":"InvalidRequestException","AthenaErrorCode":"INVALID_INPUT","ErrorCode":"INVALID_INPUT","Message":"1 validation error detected: Value at 'clientRequestToken' failed to satisfy constraint: Member must have length less than or equal to 128"}
    ```

  - **32 文字・128 文字はどちらも 200 で成功。** `QueryExecutionId` が返る。
  - **応答ヘッダに `x-amzn-errortype` は無い。** ヘッダの全体は `Connection` / `Content-Length` / `Content-Type` / `Date` / `x-amzn-RequestId` の 5 つだけ。
- 備考: 3 回目は `raw-token-omit` だけ `URLError(gaierror(-2, 'Name or service not known'))`（名前解決の一時的な失敗）で届かず、他 5 件は届いた。4 回目は `URLError` のリトライ（2 秒 × 3 回）を入れ、6 件すべて届いた（`"attempts": 1`）。文字数はすべて ASCII で測ったので、バイト数か文字数かは未測定。

### トークンの正規化（前後空白・`"`・`\`・大文字）（生 HTTP）
- 日付: 2026-09-24 ／ issue: #147（バッチは #113） ／ スクリプト: `tools/measure/unmeasured-batch/run.sh`（項目 `t2`）、`tools/measure/unmeasured-batch/raw.py`（`run_t2`） ／ 生データ: `$HOME/athena-unmeasured-batch-measurements/run-20260924-024654/t2/`
- 相手: 本物の Athena（SigV4 を botocore の `SigV4Auth` で署名した生 HTTP、`http.client`。workgroup は付けない＝`primary`）
- 投げたもの: 6 本とも同じ `QueryString` `SELECT 1`・Catalog `AwsDataCatalog`・Database `<DB>`・OutputLocation `<OUTPUT>` で、`ClientRequestToken` だけを変える。本文は ensure_ascii の JSON
  - `t2-base`: 基準（16 進小文字 40 文字）
  - `t2-space`: 基準の前後に半角空白を 1 つずつ（42 文字）
  - `t2-quote`: 基準の 21 文字目（0 始まりで 20）を `"` に置き換え（ワイヤ上は `\"`、復号後 40 文字）
  - `t2-backslash`: 同じ位置を `\` に置き換え（ワイヤ上は `\\`、復号後 40 文字）
  - `t2-upper`: 基準を大文字にしたもの（40 文字）
  - `t2-control`: 基準をそのまま再送（対照。最後に送った）
- 返ったもの:
  - 6 本とも HTTP 200、本文は `{"QueryExecutionId":"<id>"}` だけ（`Content-Length: 59`）。応答ヘッダは `Date` / `Content-Type`（`application/x-amz-json-1.1`） / `Content-Length` / `Connection` / `x-amzn-RequestId` の 5 つ
  - `t2-space`・`t2-quote`・`t2-backslash`・`t2-upper` の 4 本は、基準とも互いとも違う `QueryExecutionId`（4 本とも新しい実行）
  - `t2-control` は `t2-base` と同じ `QueryExecutionId`
- 備考: 本物はトークンを正規化しない（前後の空白を落とさず、大文字小文字を区別し、`"`・`\` も復号後の 1 文字としてそのまま扱う）。4 変種はどれも `IDEMPOTENT_PARAMETER_MISMATCH` にならず別トークンとして受理された

### トークン長の単位（マルチバイト）（生 HTTP）
- 日付: 2026-09-24 ／ issue: #147（バッチは #113） ／ スクリプト: `tools/measure/unmeasured-batch/run.sh`（項目 `t3`）、`tools/measure/unmeasured-batch/raw.py`（`run_t3`） ／ 生データ: `$HOME/athena-unmeasured-batch-measurements/run-20260924-024654/t3/`
- 相手: 本物の Athena（生 HTTP。t2 と同じ）
- 投げたもの: 6 本とも `SELECT 1`・Catalog `AwsDataCatalog`・Database `<DB>`・OutputLocation `<OUTPUT>`。トークンだけ変える。本文は ensure_ascii の JSON なので `あ` はワイヤ上 `あ`（6 バイト）で、復号後は 1 文字・UTF-8 で 3 バイト
  - `t3-mb20`: `あ`×20（20 文字・UTF-8 60 バイト）
  - `t3-mb50`: `あ`×50（50 文字・UTF-8 150 バイト）
  - `t3-ascii31`・`t3-ascii32`・`t3-ascii128`・`t3-ascii129`: 16 進小文字の ASCII（文字数＝バイト数）
- 返ったもの（応答ヘッダは 6 本とも `Date` / `Content-Type` / `Content-Length` / `Connection` / `x-amzn-RequestId` の 5 つで、`x-amzn-errortype` は無い。400 の本文のキーは `__type`・`AthenaErrorCode`・`ErrorCode`・`Message` の 4 つ）:

  | ケース | 文字数 | UTF-8 バイト数 | HTTP | 生の本文 |
  | --- | --- | --- | --- | --- |
  | `t3-mb20` | 20 | 60 | 400（`Content-Length: 251`） | `{"__type":"InvalidRequestException","AthenaErrorCode":"INVALID_INPUT","ErrorCode":"INVALID_INPUT","Message":"1 validation error detected: Value at 'clientRequestToken' failed to satisfy constraint: Member must have length greater than or equal to 32"}` |
  | `t3-mb50` | 50 | 150 | 400（`Content-Length: 164`） | `{"__type":"InvalidRequestException","AthenaErrorCode":"INVALID_INPUT","ErrorCode":"INVALID_INPUT","Message":"clientRequestToken exceeds maximum allowed length 128"}` |
  | `t3-ascii31` | 31 | 31 | 400（`Content-Length: 251`） | `t3-mb20` と一字一句同じ |
  | `t3-ascii32` | 32 | 32 | 200 | `{"QueryExecutionId":"<id>"}` |
  | `t3-ascii128` | 128 | 128 | 200 | `{"QueryExecutionId":"<id>"}` |
  | `t3-ascii129` | 129 | 129 | 400（`Content-Length: 249`） | `{"__type":"InvalidRequestException","AthenaErrorCode":"INVALID_INPUT","ErrorCode":"INVALID_INPUT","Message":"1 validation error detected: Value at 'clientRequestToken' failed to satisfy constraint: Member must have length less than or equal to 128"}` |

- 備考:
  - **下限は文字数と読める。** `t3-mb20` は UTF-8 で 60 バイト（ワイヤ上の `\u` 表記でも 120 バイト）と 32 以上なのに、ASCII 31 文字と同じ「greater than or equal to 32」で拒否された。32 未満になるのは文字数（20）だけ（`あ` は UTF-16 でも 1 単位なので、文字数と UTF-16 の単位数はこの測定では区別できない）
  - **上限はバイト数と読める。** `t3-mb50` は 50 文字で 128 以下なのに拒否された。128 を超えるのはバイト数の側（UTF-8 150。ワイヤ上の表記なら 300）。ただし送った本文は `あ` に逃がしてあるので、UTF-8 のバイト数とワイヤ上の表記の長さのどちらで数えたかはこの測定では区別できない
  - **上限を超えたときの `Message` が 2 通りある。** ASCII 129 文字は枠組みの検証の文言（`1 validation error detected: ... less than or equal to 128`）、マルチバイト 50 文字は別の文言 `clientRequestToken exceeds maximum allowed length 128`（`1 validation error detected:` の前置きも `Value at` も無い）。`__type`・`AthenaErrorCode`・`ErrorCode` は同じ。文字数で 128 を超えないがバイト数で超えるトークンは、枠組みの検証（文字数）を通った後の別の検査で弾かれている、と読める
  - 文字数で 128 を超え、かつバイト数でも超える非 ASCII のトークン（どちらの文言が先か）と、文字数 32 未満・バイト数 128 超の組は測っていない

### Catalog だけを変えた再送（大文字小文字の違いと実在しない名前）
- 日付: 2026-09-24 ／ issue: #146（バッチは #113） ／ スクリプト: `tools/measure/unmeasured-batch/run.sh`（項目 `t1`） ／ 生データ: `$HOME/athena-unmeasured-batch-measurements/run-20260924-004554/t1/`
- 相手: 本物の Athena（engine version 3、workgroup `primary`）
- 投げたもの: 同じトークン・同じ `SELECT 1 AS t1_probe`・同じ Database `<DB>`・同じ OutputLocation `<OUTPUT>` で、`QueryExecutionContext.Catalog` だけを 1 本目 `AwsDataCatalog`、2 本目 `AWSDATACATALOG`、3 本目 `athena_local_probe_113_no_such_catalog`
- 返ったもの:
  - 1 本目: SUCCEEDED。`GetQueryExecution` の `QueryExecutionContext.Catalog` は `awsdatacatalog`（小文字で返る）。`<id>.csv` 15B・`<id>.csv.metadata` 87B（binary/octet-stream。field 1 は QueryExecutionId、field 2 は空文字、field 3 は 0。リテラルだけの SELECT の既知の形）
  - 2 本目（大文字小文字だけの違い）: `InvalidRequestException`: `Idempotent parameters do not match`、`AthenaErrorCode` `IDEMPOTENT_PARAMETER_MISMATCH`。ID は返らない
  - 3 本目（実在しない Catalog）: 2 本目と同じ
- 備考: `Catalog` も冪等性の照合に入る。大文字小文字だけの違いも衝突になる（1 本目の Catalog は小文字にして返されるが、照合はそれとは別）

### 同じトークンの再送で OutputLocation が不正・QueryString が構文エラーのとき
- 日付: 2026-09-24 ／ issue: #146（バッチは #113。未実測にしたのは #102） ／ スクリプト: `tools/measure/unmeasured-batch/run.sh`（項目 `t5`） ／ 生データ: `$HOME/athena-unmeasured-batch-measurements/run-20260924-004554/t5/`
- 相手: 本物の Athena（engine version 3、workgroup `primary`、Catalog `AwsDataCatalog`、Database `<DB>`）
- 投げたもの: 同じトークンで 3 本。1 本目 `SELECT 1 AS t5_probe`（OutputLocation `<OUTPUT>`）、2 本目は同じ SQL で OutputLocation だけ `not-a-valid-s3-path`、3 本目は OutputLocation `<OUTPUT>` のまま SQL だけ `SELEC 1`
- 返ったもの:
  - 1 本目: SUCCEEDED（`<id>.csv` 15B・`.metadata` 87B、binary/octet-stream）
  - 2 本目: `InvalidRequestException`: `outputLocation is not a valid S3 path.`、`AthenaErrorCode` `INVALID_INPUT`
  - 3 本目: `InvalidRequestException`: `line 1:1: mismatched input 'SELEC'. Expecting: 'ALTER', 'ANALYZE', 'CALL', 'COMMENT', 'COMMIT', 'CREATE', 'DEALLOCATE', 'DELETE', 'DENY', 'DESC', 'DESCRIBE', 'DROP', 'EXECUTE', 'EXPLAIN', 'GRANT', 'INSERT', 'MERGE', 'PREPARE', 'REFRESH', 'RESET', 'REVOKE', 'ROLLBACK', 'SET', 'SHOW', 'START', 'TRUNCATE', 'UNLOAD', 'UPDATE', 'USE', <query>`、`AthenaErrorCode` `MALFORMED_QUERY`
- 備考: どちらも `IDEMPOTENT_PARAMETER_MISMATCH` ではなく検証のエラー。OutputLocation の検証と構文チェックはトークンの照合より先

### 不正な OutputLocation と構文エラーが同時のとき
- 日付: 2026-09-24 ／ issue: #146（バッチは #113。`t4` のうち AWS CLI で送れる組） ／ スクリプト: `tools/measure/unmeasured-batch/run.sh`（項目 `t4c`） ／ 生データ: `$HOME/athena-unmeasured-batch-measurements/run-20260924-004554/t4c/`
- 相手: 本物の Athena（engine version 3、workgroup `primary`、Catalog `AwsDataCatalog`、Database `<DB>`）
- 投げたもの: 新しいトークン（UUID）で `SELEC 1`、OutputLocation `not-a-valid-s3-path`
- 返ったもの: `InvalidRequestException`: `outputLocation is not a valid S3 path.`、`AthenaErrorCode` `INVALID_INPUT`
- 備考: OutputLocation の検証が構文チェックより先。長さの足りないトークンが絡む組（`t4` の残り）は AWS CLI が送信前に弾くので生 HTTP で測る（#147）

### 長さの足りないトークンと他の検証エラーが同時のとき（生 HTTP）
- 日付: 2026-09-24 ／ issue: #147（バッチは #113。`t4` のうち AWS CLI では送れない組） ／ スクリプト: `tools/measure/unmeasured-batch/run.sh`（項目 `t4`）、`tools/measure/unmeasured-batch/raw.py`（`run_t4`） ／ 生データ: `$HOME/athena-unmeasured-batch-measurements/run-20260924-024654/t4/`
- 相手: 本物の Athena（生 HTTP。Catalog `AwsDataCatalog`、Database `<DB>`、workgroup は付けない＝`primary`）
- 投げたもの: 短いトークン（16 進小文字 10 文字。3 本で同じもの）と有効なトークン（16 進小文字 40 文字。2 本で同じもの）で 5 本

  | ケース | トークン | OutputLocation | QueryString |
  | --- | --- | --- | --- |
  | `t4-token-output` | 10 文字 | `s3://` | `SELECT 1` |
  | `t4-token-syntax` | 10 文字 | `<OUTPUT>` | `SELEC 1` |
  | `t4-token-only` | 10 文字 | `<OUTPUT>` | `SELECT 1` |
  | `t4-output-only` | 40 文字 | `s3://` | `SELECT 1` |
  | `t4-syntax-only` | 40 文字 | `<OUTPUT>` | `SELEC 1` |

- 返ったもの（5 本とも HTTP 400、`__type` `InvalidRequestException`、本文のキーは `__type`・`AthenaErrorCode`・`ErrorCode`・`Message` の 4 つで `ErrorCode` は `AthenaErrorCode` と同じ値。応答ヘッダは `Date` / `Content-Type` / `Content-Length` / `Connection` / `x-amzn-RequestId` の 5 つで、`x-amzn-errortype` は無い）:

  | ケース | `AthenaErrorCode` | `Message` |
  | --- | --- | --- |
  | `t4-token-output` | `INVALID_INPUT` | `1 validation error detected: Value at 'clientRequestToken' failed to satisfy constraint: Member must have length greater than or equal to 32` |
  | `t4-token-syntax` | `INVALID_INPUT` | 同上 |
  | `t4-token-only` | `INVALID_INPUT` | 同上 |
  | `t4-output-only` | `INVALID_INPUT` | `outputLocation is not a valid S3 path.` |
  | `t4-syntax-only` | `MALFORMED_QUERY` | `line 1:1: mismatched input 'SELEC'. Expecting: 'ALTER', 'ANALYZE', 'CALL', 'COMMENT', 'COMMIT', 'CREATE', 'DEALLOCATE', 'DELETE', 'DENY', 'DESC', 'DESCRIBE', 'DROP', 'EXECUTE', 'EXPLAIN', 'GRANT', 'INSERT', 'MERGE', 'PREPARE', 'REFRESH', 'RESET', 'REVOKE', 'ROLLBACK', 'SET', 'SHOW', 'START', 'TRUNCATE', 'UNLOAD', 'UPDATE', 'USE', <query>` |

- 備考: トークンの長さの検証は `OutputLocation` の検証とも構文チェックとも先。上の「不正な OutputLocation と構文エラーが同時のとき」（#146、`OutputLocation` が構文より先）と合わせて、順序はトークンの長さ → `OutputLocation` → 構文。`t4-output-only` と `t4-syntax-only` は同じトークンで `OutputLocation` と `QueryString` が違うが、2 本目も `IDEMPOTENT_PARAMETER_MISMATCH` ではなく構文エラーになった（1 本目が検証で弾かれ、トークンが消費されていない。1 回目の「構文エラーで弾かれたトークンは消費されない」と同じ向き）

### Database・OutputLocation の「省略」と「既定と同じ値の明示」
- 日付: 2026-09-24 ／ issue: #146（バッチは #113） ／ スクリプト: `tools/measure/unmeasured-batch/run.sh`（項目 `t8`） ／ 生データ: `$HOME/athena-unmeasured-batch-measurements/run-20260924-004554/t8/`
- 相手: 本物の Athena（engine version 3、workgroup `<WORKGROUP2>`。出力先 `<OUTPUT>` が設定され `EnforceWorkGroupConfiguration: true`。[work-groups.md](work-groups.md) の「出力先が設定されたワークグループの GetWorkGroup」）
- 投げたもの: 2 組。どちらも 1 本目と 2 本目は同じトークン
  - (a) `SELECT 1 AS t8_probe`。1 本目は Catalog `AwsDataCatalog` だけで Database を省略、2 本目は Database `default` を明示（OutputLocation はどちらも `<OUTPUT>`）
  - (b) `SELECT 2 AS t8_probe`。Catalog `AwsDataCatalog`・Database `<DB>`。1 本目は OutputLocation を省略、2 本目は `<OUTPUT>`（ワークグループの出力先と同じ値）を明示
- 返ったもの:
  - (a) 1 本目 SUCCEEDED（`QueryExecutionContext` は `{"Catalog": "awsdatacatalog"}` だけで `Database` は無い）。2 本目は `InvalidRequestException`: `Idempotent parameters do not match`、`IDEMPOTENT_PARAMETER_MISMATCH`
  - (b) 1 本目 SUCCEEDED（OutputLocation は `<OUTPUT><id>.csv`）。**2 本目も成功し、1 本目と同じ `QueryExecutionId`** が返った
  - 成功した 3 本の結果ファイルは `<id>.csv` 15B・`.metadata` 87B（binary/octet-stream）
- 備考: Database は省略と `default` の明示を別物として扱う。OutputLocation の (b) は、ワークグループが出力先を強制する（リクエストの OutputLocation が使われない）条件でしか測っていない。強制しないワークグループで省略と明示を同じに扱うかは生データに無い

### 保持期限: 完了直後の再送（段階 A）
- 日付: 2026-09-24 ／ issue: #147（バッチは #113） ／ スクリプト: `tools/measure/unmeasured-batch/run.sh`（項目 `t6`。本体は `tools/measure/unmeasured-batch/items-retention.sh` の `retention_phase_a`） ／ 生データ: `$HOME/athena-unmeasured-batch-measurements/run-20260924-024654/retention/`（`t6-first.*`・`t6-immediate-reuse.*`・`state.env`）
- 相手: 本物の Athena（AWS CLI。engine version 3、workgroup `primary`、Catalog `AwsDataCatalog`、Database `<DB>`、OutputLocation `<OUTPUT>`）
- 投げたもの: 新しいトークン（UUID 形式の 36 文字）で `SELECT 1 AS t6_probe` を投げて SUCCEEDED まで待ち、結果と結果ファイルを確かめた直後に、同じトークン・同じ引数で再送
- 返ったもの:
  - 1 本目: SUCCEEDED（`SubmissionDateTime` 2026-09-24T02:47:03.208Z、`CompletionDateTime` 02:47:03.546Z）。`StatementType` `DML`、`SubstatementType` `SELECT`。`<id>.csv` 15B・`<id>.csv.metadata` 87B
  - 再送: 1 本目と同じ `QueryExecutionId`。その `GetQueryExecution` は 1 本目と同じ内容（`SubmissionDateTime`・`CompletionDateTime`・`Statistics` とも同じ）で、新しい実行は作られていない
  - 再送の `t6-immediate-reuse.start.json` の mtime は 11:47:12 JST（02:47:12 UTC）で、1 本目の完了から約 9 秒後。段階 A の終了時刻は 02:47:16 UTC（`state.env` の締切 03:52:16 UTC ＝ 終了 + 65 分、`state.env` の mtime 11:47:16 JST）
- 備考: 段階 A は段階 B（65 分以上あとの再送・`GetQueryExecution`・`StopQueryExecution`）の対照。直後の再送が同じ ID になることは 1 回目（2026-09-17、60 秒後まで）と同じ。段階 B は下の節（#147 の 2 回目）

### 保持期限: 65 分後の再送・GetQueryExecution・StopQueryExecution（段階 B）
- 日付: 2026-09-24 ／ issue: #147（バッチは #113） ／ スクリプト: `tools/measure/unmeasured-batch/run.sh`（項目 `t7`、`RUN_DIR=<段階 A の run> ONLY=t7`。本体は `tools/measure/unmeasured-batch/items-retention.sh` の `retention_phase_b`） ／ 生データ: `$HOME/athena-unmeasured-batch-measurements/run-20260924-024654/retention/`（`t7-reuse-after-wait.*`・`t7-get.json`・`t7-stop.json`・`state.env`）
- 相手: 本物の Athena（AWS CLI。engine version 3、workgroup `primary`、Catalog `AwsDataCatalog`、Database `<DB>`、OutputLocation `<OUTPUT>`）
- 投げたもの: 段階 A（上の節）の `state.env` にある同じトークン（UUID 形式の 36 文字）・同じ `SELECT 1 AS t6_probe`・同じ引数で、締切（段階 A の終了 + 65 分 = 03:52:16 UTC）を過ぎてから次の 3 つを順に
  1. `StartQueryExecution` の再送（`t7-reuse-after-wait`）
  2. 段階 A の ID への `GetQueryExecution`（`t7-get.json`）
  3. 同じ ID への `StopQueryExecution`（`t7-stop.json`）
- いつ投げたか（ファイルの mtime。端末の時計は `started_at` の中身 02:46:54 UTC と mtime 11:46:54 JST が一致することで確かめた）: 再送の `t7-reuse-after-wait.start.err` が 12:54:21 JST（03:54:21 UTC）、`start.json` が 12:54:22 JST、`t7-get.json` が 12:54:29 JST、`t7-stop.json` が 12:54:29 JST。段階 A の 1 本目の `CompletionDateTime` 02:47:03.546Z から再送まで **約 67 分 18 秒**
- 返ったもの:
  - 再送: **段階 A と同じ `QueryExecutionId`**。続く `GetQueryExecution`（`t7-reuse-after-wait.execution.json`）は SUCCEEDED で、`SubmissionDateTime` 02:47:03.208Z・`CompletionDateTime` 02:47:03.546Z・`TotalExecutionTimeInMillis` 338 は段階 A と同じ（新しい実行は作られていない）。結果ファイルの一覧（`t7-reuse-after-wait.ls.txt`）も段階 A の `<id>.csv` 15B・`<id>.csv.metadata` 87B（どちらも 02:47:04 の時刻）だけ
  - `GetQueryExecution`: 成功（`t7-get.err` は空）。`QueryExecution` 直下のキーは `EngineVersion`、`Query`、`QueryExecutionContext`、`QueryExecutionId`、`ResultConfiguration`、`ResultReuseConfiguration`、`StatementType`、`Statistics`、`Status`、`SubstatementType`、`WorkGroup`。State は `SUCCEEDED`
  - `StopQueryExecution`（終端状態の ID）: 成功（`t7-stop.err` は空、終了コード 0 で summary は「成功」）。`t7-stop.json` は 0 バイト（AWS CLI は空の応答では何も出力しないので、ワイヤ上の本文が `{}` だったかはこの保存物からは分からない）
- 備考: 本物のトークンの窓と実行情報の保持は 65 分（実際は約 67 分）より長い。正確な期限はこの測定では分からない。期限切れのトークン・ID の挙動（新しい ID になるか、`QUERY_EXECUTION_NOT_FOUND` か、`StopQueryExecution` が 400 か）は、期限切れの状態を作れなかったので測れていない。依頼時の要約では経過を「約 72 分」としていたが、上の mtime から約 67 分に直した（2026-09-24、フェーズ 2 の転記）
