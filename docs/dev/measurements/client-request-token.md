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
