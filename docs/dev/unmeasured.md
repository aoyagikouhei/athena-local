# 未実測の一覧

各 issue の実装で「本物の Athena で測っていない」まま残した挙動。次に本物の Athena を叩ける機会に、まとめて測る。測ったら [measurements/](measurements/README.md) に書いてここから消す（「済み」の節へ移す）。[docs/caveats.md](../caveats.md) の「not measured」も直す。出典は issue #<番号> のノート（git の履歴に残る）。

話題の分け方は [measurements/](measurements/README.md) のファイルと揃えてある。

## 結果ファイル（[measurements/result-files.md](measurements/result-files.md)）

- [ ] `CREATE TABLE` の重複の結果ファイル（Hive テーブルへの `ALTER TABLE` 失敗は #43 で実測済み: `RENAME TO` が理由を `<id>.txt` に書いた。失敗した `EXPLAIN` は #92 で実測済み: 何も置かない）
- [ ] 失敗時の `GetQueryResults` が本物は文ごとに割れる（空の ResultSet／`INVALID_QUERY_EXECUTION_STATE`／`RESULT_NOT_FOUND`）。athena-local は常に `INVALID_QUERY_EXECUTION_STATE`
- [ ] `.txt` の値に区切り文字（タブ）や改行が入るときのエスケープと、NULL の書き方（#1。1 回目で「まだ測れていない」とし、4 回目の記述では触れていない）
- [ ] カタログの既定など、`WITH` 句以外からテーブルの形式が決まる場合の CTAS・INSERT の結果ファイル（#26・#35。Athena では作れなかったので項目にしていない）
- [ ] 失敗した `SHOW FUNCTIONS` が結果ファイルを置くか（#80）
- [ ] `SHOW CREATE VIEW` の Content-Type（#76 のラウンドでは DB にビューが無く SKIPPED）

## `.metadata`（[measurements/metadata.md](measurements/metadata.md)）

- [ ] `.metadata` の `timestamp with time zone`／`time with time zone`／`interval year to month`／`uuid`／`ipaddress` の Precision／Scale／CaseSensitive（field 7／8／10）の有無。**推測で実装している**
- [ ] 更新件数 0 の `UPDATE` / `DELETE` / `MERGE`（`DELETE ... WHERE false` など）で本物が更新件数の field 3 を出すか（athena-local は `18 00` を書く。0 行の `INSERT` は Hive・Iceberg とも `18 00` を書くと実測済み。#35・#91）
- `SHOW` 5 文（`SHOW TABLES` / `DATABASES` / `COLUMNS` / `PARTITIONS` / `TBLPROPERTIES`）の本物の `.txt.metadata` は不透明な形式（base64 で 312 文字）。#24 で解析したが特定できず、AWS 側の仕様が公開されない限り埋まらないので測る対象から外す。athena-local は素の protobuf を置く（[docs/caveats.md](../caveats.md) に記載済み。JDBC が読めるかは下の「実クライアントでの疎通」）
- [ ] 0 行の CTAS（更新件数 0）で本物が field 3 を出すか（#5）
- [ ] 列の field 2 / 3 が本当に SchemaName / TableName か（#5。公開情報でも推測で未観測）
- [ ] 列の Nullable（field 9）の 1（NOT_NULL）と 2（NULLABLE）（#5。観測したのは 3 = UNKNOWN だけ）
- [ ] 空の列名の扱い（#5。本物では観測できない。athena-local はフィールドを出す）

## 文の種類（[measurements/statements.md](measurements/statements.md)）

- [ ] `ALTER TABLE ... REPLACE COLUMN`（単数形）の受理と `SubstatementType`（#43。複数形の `REPLACE COLUMNS` だけ測った）
- [ ] `ALTER TABLE ... DROP PARTITION` × Iceberg（#43）

## ClientRequestToken と保持期限（[measurements/client-request-token.md](measurements/client-request-token.md)）

- [ ] `Catalog` の差が冪等性の衝突（`IDEMPOTENT_PARAMETER_MISMATCH`）になるか（`WorkGroup` は実測済み）
- [ ] 本物がトークンを正規化するか（前後の空白、`"`、`\`、大文字小文字）
- [ ] トークン長の制約（32〜128）がバイト数か文字数か（ASCII でしか測っていない）
- [ ] トークンの検証と他の検証エラー（`OutputLocation` 無し等）の優先順位
- [ ] 同じトークンの再送で `OutputLocation` が不正な値、または `QueryString` が構文エラーのとき、トークンの照合（`IDEMPOTENT_PARAMETER_MISMATCH`）と検証のどちらが先か（athena-local は `OutputLocation` の検証と構文チェックの後、`Store::submit` で照合する。#102）
- [ ] トークン対応表と実行情報の本物の保持期間（60 秒を超えることまでは実測。既定の 1 時間は athena-local 独自の値）
- [ ] 期限切れのトークンを再送すると本物で新しい ID になるか、期限切れの ID の `GetQueryExecution` が `QUERY_EXECUTION_NOT_FOUND` か、`StopQueryExecution` が 400 か
- [ ] `Database`／`OutputLocation` の「省略」と「既定と同じ値の明示」を本物が別物として扱うか

## ワークグループ（[measurements/work-groups.md](measurements/work-groups.md)）

- [ ] `Configuration.EnableMinimumEncryptionConfiguration` の値（キーの存在だけ確認）
- [ ] 出力先が設定されたワークグループの `GetWorkGroup` の `ResultConfiguration` の形
- [ ] `GetWorkGroup` の実測値（`EnforceWorkGroupConfiguration=false` 等）が工場出荷時の既定か、コンソールで変えた後の値か
- [ ] `ListWorkGroups` の `MaxResults` 未指定時の既定ページサイズ（athena-local は 50）
- [ ] `ListWorkGroups` の順序が名前順であること（3 件だけの根拠）

## エラー応答（[measurements/errors.md](measurements/errors.md)）

- [ ] `QUEUED` のクエリへの `GetQueryResults` の文言（`RUNNING` のときの `Query has not yet finished. Current state: RUNNING` だけ実測。athena-local は `Current state: QUEUED` を返す。#102）
- [ ] `x-amzn-errortype` ヘッダ。#2、#3、#9 の実測で本物の応答に見つからなかったが、athena-local は送り続けている
- [ ] `AthenaErrorCode` の無い経路のうち `InternalServerException` の本文の形（パース失敗と未対応オペレーションは #84 で実測: `SerializationException`・`UnknownOperationException` はどちらも `AthenaErrorCode` 無し）
- [ ] 構文エラー（`MALFORMED_QUERY`）など、冪等性の衝突とトークンの検証以外の `AthenaErrorCode` 付きエラーの本文に `ErrorCode` キーが付くか（#3。`ErrorCode` 付きの形を確かめたのはこの 2 つと、#83 の `GetQueryResults` の検証エラー）

## 実クライアントでの疎通（[measurements/clients.md](measurements/clients.md)）


## `ExecutionParameters`（本物で測った記録はまだ無い）

- [ ] 括弧で始まるクエリ（`( SELECT 1 )`）を本物がどう分類するか。athena-local は式として通す（CHANGELOG の Unreleased / Fixed の項目。レビューで見つけた）

## Trino（[measurements/trino.md](measurements/trino.md)）

- [ ] Trino 470 以前の `updateType` と 400 以前の値（#111 の足場で 480・475 は測れたが、470 はローカル FS の設定名が無く、400 は cgroup v2 で JVM が落ち、440 は file メタストアに書けず `updateType` だけ残った）

## 済み

その後の issue で測ったもの。結果は measurements にある。

- `.csv` と `.metadata` の Content-Type が実測のたびに割れる件（下の元の文言）→ #70（2026-09-23）で規則を実測した。割れていたのは SQL の違い（リテラルだけの `SELECT` と `SHOW` 系は binary）。#76 で形を足した（[measurements/result-files.md](measurements/result-files.md)）
  - 元の文言: `.csv` と `.metadata` の Content-Type が実測のたびに `binary/octet-stream` と `application/octet-stream` に割れる（#1・#17）。athena-local は多数派の `application/` 固定。`.txt` の側は #39 で決着した（`.metadata` を置く文だけ `application/`、それ以外は `binary/`。docs/result-files.md に表あり）
- `.txt` の Content-Type が `binary/octet-stream` と `application/octet-stream` に割れる理由（#1）→ #70
- `.csv` の `text/csv` が未実測だった件（#1）→ #5（2026-09-17）で application が多数派と測り、#70 で規則にした
- `.txt.metadata` の中身の解析（#1）→ #5（[measurements/metadata.md](measurements/metadata.md)）
- `ALTER TABLE` が成功したときの `.txt` の中身（#1）→ #39・#43（[measurements/result-files.md](measurements/result-files.md)）
- `MERGE` の `.metadata`（#5）→ #35 で置き場所、#41 でバイト列（74 バイト、field 2 が `MERGE`）
- 失敗した `EXPLAIN` の結果ファイル（#6）→ #92（本体も `.metadata` も無し）
- Hive テーブルへの `ALTER TABLE` の失敗（#6）→ #43（`RENAME TO` が理由を `<id>.txt` に書いた）
- `ListWorkGroups` で `MaxResults` と `NextToken` が両方不正なときの順序（#9）→ #83（`2 validation errors detected: ...` の 1 文）
- `SHOW` 5 文それぞれを JDBC で読ませた場合（#24）→ #57（JDBC 経由で athena-local に届く `SHOW` は 3 文で、どれも例外なく読む。[measurements/clients.md](measurements/clients.md)）
- INSERT の `<id>` の再実測（#26）→ #35
- `CREATE OR REPLACE TABLE ... AS` のファイル名（#26・#35）→ #93（本物は構文エラーで受け付けない）
- Iceberg のテーブルへの 0 行の `INSERT`（#35）→ #91
- `ALTER TABLE` の他の組み合わせ（`DROP COLUMN`・`RENAME`・`SET LOCATION` × Iceberg など。#39）→ #43
- 列 0 個の `.metadata` を Athena JDBC が読めるか（#39）→ #46
- Trino が `MERGE` に `updateType: "MERGE"` を返すか（#41）→ #56（[measurements/trino.md](measurements/trino.md)）
- 本物が動詞と `TABLE` の間のコメントをどう扱うか（#49）→ #52
- #70 で未測定だった形（`DESC`、`SELECT` の変種、`SHOW FUNCTIONS`／`SESSION`／`STATS`、28.9 MB より上のマルチパートの境界）→ #76。`SHOW SESSION`・`SHOW STATS` は本物が `StartQueryExecution` で拒否した。`DESC` とマルチパートの境界の値は #76 の抽出には無く、[docs/result-files.md](../result-files.md) の表と記述による。`SHOW CREATE VIEW` は上の「結果ファイル」に残した
- 末尾が改行で終わらない `EXPLAIN (FORMAT JSON)`／`EXPLAIN (TYPE IO)` の行数と `EXPLAIN ANALYZE`（#73）→ #92
- `GetQueryResults` のページング検証の 3 点（`ListWorkGroups` の上限と空文字の同時、RUNNING／CANCELLED のクエリへの不正な `NextToken`、0 行の結果への `NextToken`。#83）→ #85
- リクエスト本文の型違いなどの未実測の組み合わせ（#84）→ #87
- Trino 482 より古いバージョンの `system.metadata.catalogs` の `connector_name` などの値（#39）→ #111（2026-09-23。480・475 は 482 と同じ。440 は `connector_name` が同じで、`updateType` は書き込みができず未測定。470・400 は手元で起動できず未測定。足場は `tools/e2e/trino-probe/versions.sh`。[measurements/trino.md](measurements/trino.md)）
- `ATHENA_LOCAL_RESULTS=s3` と保持期限の組み合わせ → #111（保持期限 1 秒で捨てた後、`GetQueryExecution` は 400 `QUERY_EXECUTION_NOT_FOUND` で、`<id>.csv` と `<id>.csv.metadata` は MinIO に残る。足場は `tools/e2e/minio/verify.sh` のケース 14。docs/caveats.md の Query lifecycle に書いた）
- `UPDATE` / `DELETE` の athena-local での実機確認（#5）→ #111（Trino 482 + MinIO。updateType と件数がそのまま `.metadata` に入り 75 バイト、Hive への `UPDATE` は FAILED で何も置かない。[measurements/trino.md](measurements/trino.md)）
- dbt-athena で `work_group` を設定して 1 回通す（#2）→ #111（2026-09-23。`dbt debug` と `dbt run-operation` の `is_work_group_output_location_enforced()` は通り、GetWorkGroup は `ENFORCED=False`。`dbt run` は Glue の `GetDatabases` で止まる。[measurements/clients.md](measurements/clients.md)）
- awswrangler の `read_sql_query(ctas_approach=False)` が `GetWorkGroup` の応答で例外にならないこと（#2）→ #111（2026-09-23。workgroup 既定・`wg111` とも `[[1, 'a']]`、STS は呼ばない。[measurements/clients.md](measurements/clients.md)）
- PyAthena・awswrangler で退行が無いこと（#5）→ #111（2026-09-23。型の行の行数と int・varchar は 3 通りで一致、DDL・SHOW・DESCRIBE・INSERT・CTAS も例外なし。例外は PyAthena の PandasCursor で Iceberg の DROP TABLE を読んだときの `EmptyDataError`（本物と同じ改行 1 個による。Hive の DROP TABLE は読める）。[measurements/clients.md](measurements/clients.md)）
- awswrangler が `GetQueryResults` を読む経路で先頭行をどう扱うか（#60）→ #111（2026-09-23。値を見ずに 1 行目を落とすが、athena-local の列名行が落ちるだけで 1500 行・1 行とも欠けない。[measurements/clients.md](measurements/clients.md)）
- 失敗した DDL の `<id>.txt` を結果ファイルを読むクライアント（PyAthena、JDBC 3.x）が読んでも壊れないこと（#6）→ #111（2026-09-23。JDBC 3.0.0〜3.8.1 も PyAthena 3.36.0 の PandasCursor・Cursor も FAILED を見て例外を投げ、`<id>.txt` も `.txt.metadata` も取りに行かなかった。[measurements/clients.md](measurements/clients.md)。足場は `tools/e2e/jdbc-drivers/` と `tools/e2e/python-clients/`）
- 暗号化系の `SHOW` に素の protobuf の `.txt.metadata` を返して Athena JDBC 3.5.1 未満が壊れないか（#5）→ #111（3.0.0〜3.5.0 のどれも SHOW 3 文を例外なく読んだ。3.4.0・3.5.0 の auto で準備の `CREATE TABLE` が既知の NoSuchKey。[measurements/clients.md](measurements/clients.md)）
- 長時間運用でメモリが頭打ちになるか（保持期限による破棄の実効性）→ #111（2026-09-23。同じ負荷を 240 秒ずつ流し、保持 1 秒の VmRSS の暖機後の伸びは 17.9MiB（後半 3.1MiB）、保持 3600 秒は 3267.9MiB。最初の ID は 1 秒側で 400。足場は `tools/e2e/retention/verify.sh`。docs/caveats.md の Query lifecycle に書いた。数時間の推移は #121）
