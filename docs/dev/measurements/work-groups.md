# ワークグループ

`GetWorkGroup` と `ListWorkGroups`。書き方は [README.md](README.md)。

対応する利用者向けの章: [docs/api.md](../../api.md)、[docs/caveats.md](../../caveats.md) の「Workgroups」。

## GetWorkGroup

### GetWorkGroup の応答の形と値
- 日付: 2026-09-17 ／ issue: #2 ／ スクリプト: `tools/measure/get-work-group.sh`（旧 `2-measure-workgroup.sh`） ／ 生データ: `$HOME/athena-workgroup-measurements/run-20260917-064427`（`summary.txt` は実名を伏せてある）
- 相手: 本物の Athena
- 投げたもの: `GetWorkGroup`（ワークグループ 2 つ、`WORKGROUP` と `WORKGROUP2`。`WORKGROUP2` は出力先設定済みのつもりだったが設定が無かった）。`--debug` の生ログからワイヤ上の応答を抜いた
- 返ったもの: 2 つとも同じ形・同じ値。
  - **`WorkGroup` 直下のキー**: `Configuration`、`CreationTime`、`Name`、`State`。`Description` は**無い**（両方とも）。
  - **`Configuration` 直下のキー**: `EnableMinimumEncryptionConfiguration`、`EnforceWorkGroupConfiguration`、`EngineVersion`、`PublishCloudWatchMetricsEnabled`、`RequesterPaysEnabled`、`ResultConfiguration`。

    | 項目 | 実測値 |
    | --- | --- |
    | `State` | `ENABLED` |
    | `EngineVersion.SelectedEngineVersion` | `AUTO` |
    | `EngineVersion.EffectiveEngineVersion` | `Athena engine version 3` |
    | `Configuration.EnforceWorkGroupConfiguration` | `false` |
    | `Configuration.PublishCloudWatchMetricsEnabled` | `false` |
    | `Configuration.RequesterPaysEnabled` | `false` |
    | `Configuration.EnableMinimumEncryptionConfiguration` | **値は採れていない**（キーの存在だけ確認） |
    | `BytesScannedCutoffPerQuery`／`ExecutionRole`／`AdditionalConfiguration`／`CustomerContentEncryptionConfiguration` | 無し |

  - **`ManagedQueryResultsConfiguration` は存在しなかった。**
  - **`CreationTime` はワイヤ上は数値だった。** 生の応答は `"CreationTime":1.<12 桁>E9` の形で、**epoch 秒の浮動小数点数**。AWS CLI の JSON 出力が文字列に整形して見せていただけだった。既存の `SubmissionDateTime`（`f64`）と同じ表現。
  - **`ResultConfiguration` はキーとして存在するが `OutputLocation` は無い。** 両方のワークグループとも `Configuration.ResultConfiguration` はあり、その中の `OutputLocation` と `EncryptionConfiguration` が無い。つまり本物は**空のオブジェクト `{}` を返している**。
  - **`ListWorkGroups`** は 3 件返った（別 issue の材料）。
- 備考: **実測値は「工場出荷時の既定」とは限らない。** 過去にコンソールから設定を変えていれば、その変更後の値が出る。`EnforceWorkGroupConfiguration = false` と `EngineVersion` は製品共通の既定である可能性が高いが断定はできない（既定のままかカスタマイズ済みか不明）。`summary.txt` で `CreationTime` の仮数部が `<ACCOUNT_ID>` に置換されているのは、マスクが 12 桁の数列を一律に伏せた副作用で、アカウント ID ではない。「出力先が設定されたワークグループの見え方」は測れていない。

### 存在しないワークグループのエラー
- 日付: 2026-09-17 ／ issue: #2 ／ スクリプト: `tools/measure/get-work-group.sh`（旧 `2-measure-workgroup.sh`） ／ 生データ: `$HOME/athena-workgroup-measurements/run-20260917-064427`
- 相手: 本物の Athena
- 投げたもの: 存在しないワークグループ名で `GetWorkGroup`。同じく `StartQueryExecution` に存在しないワークグループを渡す
- 返ったもの:

  | 項目 | 実測値 |
  | --- | --- |
  | HTTP ステータス | 400 |
  | `__type` | `InvalidRequestException` |
  | `message` | `WorkGroup is not found.` |
  | `AthenaErrorCode` | `INVALID_INPUT` |
  | `x-amzn-errortype` ヘッダ | 採取できず（botocore のログから抜けなかった） |

  `StartQueryExecution` に存在しないワークグループを渡した場合も同じ `InvalidRequestException` / `WorkGroup is not found.`。
- 備考: athena-local は任意の名前を受け付けてエラーにしない（判断 2）。この実測値は README の Caveats に「本物との差分」として書いた。

## ListWorkGroups

### #2 の生ログから読み直した ListWorkGroups と GetWorkGroup の食い違い
- 日付: 2026-09-18（読み直した日。元のログは #2 の 2026-09-17 の実測） ／ issue: #9 ／ スクリプト: 無し（#2 の `tools/measure/get-work-group.sh`（旧 `2-measure-workgroup.sh`） の生ログを python で再確認） ／ 生データ: `$HOME/athena-workgroup-measurements/run-20260917-064427`
- 相手: 本物の Athena
- 投げたもの: 同じワークグループへの `GetWorkGroup` と `ListWorkGroups`
- 返ったもの:
  - `GetWorkGroup` のキーは `Configuration`／`CreationTime`／`Name`／`State` で `Description` 無し。同じ名前の要素が `ListWorkGroups` では `Description: ""`（空文字）。つまり説明の無いワークグループは、`GetWorkGroup` ではキーが無く、`ListWorkGroups` では空文字。
  - 一覧の並びは 3 件とも名前の辞書順と一致し、`CreationTime` 昇順とは一致しなかった（3 件なので弱い根拠）。
  - 3 件とも `State: ENABLED`、`EngineVersion` は `AUTO`／`Athena engine version 3`（`GetWorkGroup` と同じ）。
- 備考: 説明が非空のワークグループの `GetWorkGroup` はこの時点で未実測 → 下の実測で埋まった。

### ListWorkGroups の応答・ページング・エラー（CLI）
- 日付: 2026-09-18 ／ issue: #9 ／ スクリプト: `tools/measure/list-work-groups.sh`（旧 `9-measure-list-work-groups.sh`）（`tools/measure/get-work-group.sh`（旧 `2-measure-workgroup.sh`） と同じ安全策。クエリは流さない） ／ 生データ: `$HOME/athena-list-work-groups-measurements/run-20260918-051509`
- 相手: 本物の Athena（ワークグループ 3 件）
- 投げたもの: 素の応答、`--max-results 1` での `NextToken` の形と辿った結果、`--max-results` 50／51／0、不正な `NextToken`、同じワークグループでの `GetWorkGroup` と `ListWorkGroups` の `Description`、一覧の順序
- 返ったもの:

| 項目 | 実測値 |
| --- | --- |
| 応答直下のキー | `WorkGroups` のみ（3 件では `NextToken` 無し） |
| 各要素のキー | `CreationTime`／`Description`／`EngineVersion`／`Name`／`State`（`IdentityCenterApplicationArn` 無し） |
| `State` | 3 件とも `ENABLED` |
| `EngineVersion` | `SelectedEngineVersion: AUTO`、`EffectiveEngineVersion: Athena engine version 3`。**ワイヤ上はさらに `Category: "Presto"` があり、CLI（botocore のモデルに無い）が落としている** |
| `Description` | 3 件ともキーあり。2 件が非空、1 件が空文字 |
| `CreationTime` | ワイヤ上は epoch 秒の浮動小数点数（`1.<12 桁>E9`。`GetWorkGroup` と同じ） |
| 順序 | 名前の辞書順と一致。`CreationTime` 昇順とは不一致（昇順に並べると逆順になった） |
| `MaxResults: 1` | 1 件ずつ 3 ページ。`NextToken` は 120 文字の標準 base64（`+`／`/`／`=` を含む）。辿った並びは素の応答と一致し、最終ページに `NextToken` は無い |
| `MaxResults: 50` | 成功。3 件、`NextToken` 無し |
| `MaxResults: 51` | HTTP 400／`__type: InvalidRequestException`／`AthenaErrorCode: INVALID_INPUT`（`ErrorCode` も同値）／`Message: 1 validation error detected: Value at 'maxResults' failed to satisfy constraint: Member must have value less than or equal to 50` |
| `MaxResults: 0` | **未実測。** CLI 側の検証（`valid min value: 1`）で止まり HTTP が飛ばなかった。生 HTTP で測り直す（下） |
| 不正な `NextToken`（`athena-local-invalid-next-token-probe`） | HTTP 400／`InvalidRequestException`／`INVALID_INPUT`／`Message: The nextPageToken is malformed: athena-local-invalid-next-token-probe`（**受け取ったトークンをそのまま末尾に付ける**） |
| 正しいトークンの末尾 1 文字を変えたもの | 同じ形（`The nextPageToken is malformed: <トークン>`） |
| `Description` の食い違い | **食い違わない。** 説明が非空のワークグループでは `GetWorkGroup` にも `Description` キーがあり値も一致（キーは `Configuration`／`CreationTime`／`Description`／`Name`／`State`）。issue 2 の生ログと合わせると、**説明が空のときは `GetWorkGroup` はキーを省き、`ListWorkGroups` は空文字を返す** |
| `x-amzn-errortype` ヘッダ | 採取できず（#2 と同じ。生 HTTP でも無かった） |

- 備考: 順序が名前順なのは 3 件だけの根拠（ノートの「未検証の前提 4」）。

### ListWorkGroups の生 HTTP（下限・空トークン・型違い）
- 日付: 2026-09-18 ／ issue: #9 ／ スクリプト: `tools/measure/raw-list-work-groups.py`（旧 `9-measure-raw-list-work-groups.py`）（SigV4 自前署名） ／ 生データ: `raw-20260918-052722`（ノートにはこの名前だけ）
- 相手: 本物の Athena
- 投げたもの: 下の表の本文
- 返ったもの:

| 送った本文 | 実測値 |
| --- | --- |
| `{"MaxResults": 0}`、`{"MaxResults": -1}` | 400／`InvalidRequestException`／`INVALID_INPUT`／`Message: 1 validation error detected: Value at 'maxResults' failed to satisfy constraint: Member must have value greater than or equal to 1` |
| `{"NextToken": ""}`、`{"MaxResults": 1, "NextToken": ""}` | 400／`InvalidRequestException`／`INVALID_INPUT`／`Message: 1 validation error detected: Value at 'nextToken' failed to satisfy constraint: Member must have length greater than or equal to 1` |
| `{"MaxResults": "1"}`（型違い） | 400／`__type: SerializationException`／`AthenaErrorCode` 無し／`Message: STRING_VALUE can not be converted to an Integer`。athena-local は `parse` が `InvalidRequestException` にする（全オペレーション共通の経路、`src/response.rs:26-28` で未実測と断っている）。**今回は変えない**（別 issue の材料） |
| `{}` | 200、3 件、`NextToken` 無し |

- 備考: 型違いの `SerializationException` は当時「今回は変えない」とした。CLAUDE.md の現状（`request.rs` が `SerializationException` に写す、2026-09-23 実測）から見ると、後の issue で対応済み（抽出者の注記。このノートには書いていない）。`x-amzn-errortype` ヘッダは生 HTTP でも採取できなかった。

**食い違いに見えたもの: 説明の無いワークグループの `Description`**

- 2026-09-17（#2、上の「GetWorkGroup の応答の形と値」）: `GetWorkGroup` に `Description` キーが無い
- 2026-09-18（#9、#2 の生ログの読み直し）: 同じ名前の `ListWorkGroups` の要素は `Description: ""`
- 2026-09-18（#9、CLI）: 説明が非空なら `GetWorkGroup` にもキーがあり値も一致
- 結論: 食い違いではない。説明が空のとき `GetWorkGroup` はキーを省き、`ListWorkGroups` は空文字を返す（#9）。
