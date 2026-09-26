# 未実測の一覧

各 issue の実装で「本物の Athena で測っていない」まま残した挙動。次に本物の Athena を叩ける機会に、まとめて測る。測ったら [measurements/](measurements/README.md) に書いてここから消す（「済み」の節へ移す）。[docs/caveats.md](../caveats.md) の「not measured」も直す。本物の Athena でも観測できない・誘発できないと分かったものは、測る対象から外して末尾の「測れないもの」へ理由つきで移す（[docs/caveats.md](../caveats.md) は「cannot be measured」の趣旨に直す）。出典は issue #<番号> のノート（git の履歴に残る）。

話題の分け方は [measurements/](measurements/README.md) のファイルと揃えてある。

## 結果ファイル（[measurements/result-files.md](measurements/result-files.md)）

- [ ] `SHOW CREATE TABLE`／`SHOW CREATE VIEW` 以外の `SHOW CREATE ...`（`SCHEMA`／`MATERIALIZED VIEW`／`FUNCTION`。Trino にはある）を本物の `StartQueryExecution` が受けるか、受けるなら `.txt` の Content-Type と `.metadata` の形式。athena-local は `.txt` の既定（binary、エンジン ID）に落としている（#151、2026-09-24。`SHOW SESSION`／`STATS` と同じく本物が弾く可能性が高い）
- [ ] Iceberg のテーブルへの `DESCRIBE EXTENDED t`・`DESCRIBE FORMATTED t`・`DESCRIBE t PARTITION (...)`・`DESCRIBE t col` の `UpdateCount`・Content-Type・`.metadata`・行の形（`DESCRIBE t` は Hive で null・application、Iceberg で 0・binary・不透明。#160、2026-09-24）。athena-local は `EXTENDED` などを名前として読むので、どれも Hive 扱い（null・application）。`DESC t` は Hive で `DESCRIBE t` と同じと測った（#173）ので Iceberg でも `DESCRIBE` と同じに扱っていて、Iceberg の `DESC t` そのものは測っていない

- [ ] 複合型の中の varbinary の `[B@<hex>` の数字が、等しいバイト列で同じになるか、実行ごとに変わるか（#146 は `ARRAY[X'0102', X'03']` の違う 2 要素だけ。athena-local はバイト列の FNV-1a で決定的にしている。#149、2026-09-24）

## 文の種類と構文（[measurements/statements.md](measurements/statements.md)）

- [ ] `QueryExecutionContext` の Catalog が S3 Tables（`s3tablescatalog/<bucket>`）のとき、1〜2 部の名前の `DESCRIBE`・`SHOW COLUMNS` を本物がどう扱うか（実在しない表で Entity Not Found か、`Unsupported DDL with 2 catalogs` か）。測ったのは名前の 1 部目に S3 Tables のカタログを書いた形だけ。athena-local は Context から来た別名を種類によらず Trino 側の名前で存在を確かめ、実在しない表なら Entity Not Found にする（#216、2026-09-26）
- [ ] `QueryExecutionContext` の Catalog が S3 Tables 以外の連携カタログのときや、`S3TablesCatalog/<bucket>` のように大文字を含むときの、場所の無い CTAS でない `CREATE TABLE`。#221 で小文字の `s3tablescatalog/<bucket>` なら作られると測った。athena-local は `s3tablescatalog/` で始まるかを大文字小文字を区別せずに見て No location を返さず、それ以外は `AwsDataCatalog` と同じに弾く（2026-09-26）
- [ ] S3 Tables の Context の `Unsupported ddl with 2 catalogs: <文>` で、文の前後のタブ・改行が落ちるか。測ったのは前後の空白だけ（落ちた）。athena-local は空白・タブ・CR・LF を落とす（#224、2026-09-26）
- [ ] 無引用の 3 部の名前の場所の無い `CREATE TABLE` で、1 部目が Trino にだけあるカタログ（`iceberg` など）や、本物に登録された連携カタログのとき（`DATACATALOG_NOT_FOUND` か No location か、S3 Tables の Context で名前空間を見るか）。測ったのは `awsdatacatalog` の大文字小文字違いと実在しないカタログだけ。athena-local は Trino にあれば実在として No location にし、S3 Tables の Context でも名前空間を見ない（#227、2026-09-26）
- [ ] Trino で失敗した CTAS でない `CREATE TABLE`（名前空間が無いなど）に本物が結果ファイル（`<id>.txt`）を置くか。測ったのは S3 Tables の Context の `Cannot find or access the specified table` だけ（置かなかった）。athena-local は Trino のエラーで FAILED になった DDL には `FAILED: <理由>` の `.txt` を置く（#227、2026-09-26）
- [ ] CTAS の 4 部以上で引用符付きの部分がある名前（`a.b."c".d AS SELECT ...`）と、大文字を含む無引用の 4 部以上の CTAS の名前の書き方。#221 で無引用・小文字の 4 部の CTAS が `Invalid table name <名前>` になると測った。athena-local は引用符付きの部分があれば実行し、無引用なら DESCRIBE と同じく小文字でつないで弾く（2026-09-26）
- [ ] `SHOW TABLES IN` の 3 部以上で、2 つ目の `.` の直後が `LIKE` やバッククォートの名前の形（`SHOW TABLES IN a.b.like`・``SHOW TABLES IN a.b.`c` ``）。#212 で直後が無引用の名前なら `mismatched input '.'`、引用符付きなら `extraneous input '.'` と測った。athena-local は `"` で始まらない形をすべて `mismatched input '.'` にする（2026-09-25）

## GetQueryResults（[measurements/query-results.md](measurements/query-results.md)）

- [ ] Iceberg のテーブルの `DESCRIBE` で、フィールドが 2 つ以上の `struct` の区切り。測ったのは 1 フィールドの `struct<a: int>` だけ。athena-local は `map<string, int>` に倣って `, ` でつなぐ（#173、2026-09-24）
- [ ] Iceberg のパーティション変換のうち、`identity`／`bucket`／`truncate`／`year`／`month`／`day`／`hour` 以外（`void` など）の `# Partition spec:` の下の行。athena-local は行を出さない（#173、2026-09-24）
- [ ] Hive のテーブルの `DESCRIBE`／`SHOW COLUMNS` の 20 文字の詰めで、非 BMP 文字（絵文字など、UTF-16 で 2 単位）を 1 文字と数えるか。測ったのは BMP の `列名`・`コメント` だけ（文字数で数えた）。athena-local は Unicode のスカラ値の数で数える（#173、2026-09-24）
- [ ] `SHOW SCHEMAS LIKE`／`SHOW DATABASES LIKE` のパターンの意味。実在するデータベース名の先頭 3 文字に `*` を付けても `%` を付けても 0 行だった（#173、2026-09-24）。athena-local は Trino の `LIKE` のまま
- [ ] Hive・Iceberg の `DESCRIBE` で測っていない型（`timestamp with time zone`、`time`、`interval`、`json`、`uuid` など）の綴り。athena-local は Trino の綴りのまま（#173、2026-09-24）

## `.metadata`（[measurements/metadata.md](measurements/metadata.md)）

- `SHOW` 5 文（`SHOW TABLES` / `DATABASES` / `COLUMNS` / `PARTITIONS` / `TBLPROPERTIES`）と `SHOW CREATE VIEW`、Iceberg のテーブルへの `SHOW CREATE TABLE`・`DESCRIBE`、ビューへの `DESCRIBE`／`SHOW COLUMNS` の本物の `.txt.metadata` は不透明な形式（base64 で 312 文字。`TBLPROPERTIES` は 460、Iceberg の `SHOW CREATE TABLE` は 332、Iceberg の `DESCRIBE` は 568、ビューは 440。ビューは #173）。#24 で解析したが特定できず、AWS 側の仕様が公開されない限り埋まらないので測る対象から外す。athena-local は素の protobuf を置く（[docs/caveats.md](../caveats.md) に記載済み。JDBC が読めるかは下の「実クライアントでの疎通」）

## ClientRequestToken と保持期限（[measurements/client-request-token.md](measurements/client-request-token.md)）

- [ ] トークン対応表と実行情報の本物の正確な保持期間（67 分を超えることまでは実測。#147（2026-09-24）: 完了直後の再送も、完了から約 67 分後の再送も同じ ID で、その時点の `GetQueryExecution` は SUCCEEDED のまま見つかり、`StopQueryExecution` も成功した。既定の 1 時間は athena-local 独自の値で、本物より短い）
- [ ] 期限切れのトークンを再送すると本物で新しい ID になるか、期限切れの ID の `GetQueryExecution` が `QUERY_EXECUTION_NOT_FOUND` か、`StopQueryExecution` が 400 か（#147 は完了から約 67 分後に投げたが期限切れにならず、測れなかった）
- [ ] `GetQueryExecution` が S3 Tables（`s3tablescatalog/<bucket>`）や連携カタログの `Catalog` をどう返すか（`AwsDataCatalog` と実在しない名前は小文字で返った。#157、2026-09-24。アカウントに他のカタログが無く測れていない）
- [ ] SQL の修飾名のカタログ（`"AwsDataCatalog".db.t` など）を本物が大文字小文字を区別せずに解決するか（`QueryExecutionContext` の Catalog／Database は区別しない。#157、2026-09-24）
- [ ] `Catalog` の「省略」と「既定と同じ値（`AwsDataCatalog`）の明示」を本物が別物として扱うか。#146 は値の違い（大文字小文字・実在しない名前）だけを測った。athena-local は `Database` に倣って別物（衝突）にしている（#150、2026-09-24）
- [ ] 出力先を強制しない（`EnforceWorkGroupConfiguration: false`）ワークグループで、`OutputLocation` の「省略」と「既定と同じ値の明示」を本物が別物として扱うか。#146（2026-09-24）は強制するワークグループでしか測れず、そこでは同じ `QueryExecutionId` が返った（`Database` の省略と `default` の明示は衝突）
- [ ] トークンの長さが文字数でもバイト数でも 128 を超えるとき（非 ASCII で 129 文字以上）、本物の文言が枠組みの検証（`Member must have length less than or equal to 128`）と `clientRequestToken exceeds maximum allowed length 128` のどちらか。#147（2026-09-24）は `あ`×50（50 文字・150 バイト）と ASCII 129 文字しか測っていない。athena-local は枠組みの検証（文字数）を先に置く（#153）
- 32 文字未満かつ 128 バイト超の組は測る対象から外す。UTF-8 は 1 文字が最大 4 バイトなので 31 文字は最大 124 バイトで、その組は作れない（#153、2026-09-24）

## ワークグループ（[measurements/work-groups.md](measurements/work-groups.md)）

- [ ] `ListWorkGroups` の順序が名前順であること（3 件だけの根拠のまま。作成・削除を伴うので #113 では測らない）

## エラー応答（[measurements/errors.md](measurements/errors.md)）

- [ ] `QUEUED` のクエリへの `GetQueryResults` の文言（`RUNNING` のときの `Query has not yet finished. Current state: RUNNING` だけ実測。athena-local は `Current state: QUEUED` を返す。#102）。#146（2026-09-24）で軽い `SELECT` を 5 本続けて投げたが、キューの待ちが 47〜86 ミリ秒で、直後の `GetQueryExecution` はどれも SUCCEEDED だった（[measurements/query-results.md](measurements/query-results.md)）。捉えるには同時実行の上限まで詰めるなど別の手が要る

## 実クライアントでの疎通（[measurements/clients.md](measurements/clients.md)）

- [ ] Athena JDBC 3.0.0〜3.3.0 が素の protobuf の `.txt.metadata` を解けるか（#111 で測ったのは auto のある 3.4.0・3.5.0 だけ。3.3.0 以下は auto が無く、`ResultFetcher=S3` は `.txt.metadata` を取りに行かない。既定の経路 GetQueryResultsStream は athena-local が持たないので手元では測れない）

## Trino（[measurements/trino.md](measurements/trino.md)）

- [ ] Trino 470・400 のすべての値と、440 の存在するテーブルへの probe（D1・D2）と `updateType`（#111 の足場で 480・475 は測れたが、470 はローカル FS の設定名が無く、400 は cgroup v2 で JVM が落ち、440 は file メタストアに書けなかった）
- [ ] 複数の文（`Only one sql statement is allowed`）と、`ClientRequestToken`・`OutputLocation` の検証との順番、`ExecutionParameters` 付きのとき、バッククォートの中の `;`、閉じていない引用符・コメントの中の `;`。#228 で測ったのは構文エラー・存在の確認・No location・NV・2 catalogs より先であることと、`'`・`"`・`--`・`/* */` の中の `;` が区切りにならないことだけ。athena-local はトークンと OutputLocation の後・構文チェックの前に、受け取った SQL（パラメータを当てる前）で数え、閉じていない引用符・コメントは末尾までを中身とする（2026-09-26）

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
- 失敗時の `GetQueryResults` が本物は文ごとに割れるか（空の ResultSet／`INVALID_QUERY_EXECUTION_STATE`／`RESULT_NOT_FOUND`）→ 既に #6（2026-09-17）で実測済みだった（[measurements/result-files.md](measurements/result-files.md) の「失敗・取り消し時に本物が置く結果ファイル」）。`docs/caveats.md` の「Failed queries」にも反映済み。この一覧への「済み」への移動だけが漏れていたので #113（2026-09-24）で消す
- `ListWorkGroups` で `MaxResults` と `NextToken` が両方不正なときの順序（#9）→ #83（`2 validation errors detected: ...` の 1 文）
- `SHOW` 5 文それぞれを JDBC で読ませた場合（#24）→ #57（JDBC 経由で athena-local に届く `SHOW` は 3 文で、どれも例外なく読む。[measurements/clients.md](measurements/clients.md)）
- INSERT の `<id>` の再実測（#26）→ #35
- `CREATE OR REPLACE TABLE ... AS` のファイル名（#26・#35）→ #93（本物は構文エラーで受け付けない）
- Iceberg のテーブルへの 0 行の `INSERT`（#35）→ #91
- `ALTER TABLE` の他の組み合わせ（`DROP COLUMN`・`RENAME`・`SET LOCATION` × Iceberg など。#39）→ #43
- 列 0 個の `.metadata` を Athena JDBC が読めるか（#39）→ #46
- Trino が `MERGE` に `updateType: "MERGE"` を返すか（#41）→ #56（[measurements/trino.md](measurements/trino.md)）
- 本物が動詞と `TABLE` の間のコメントをどう扱うか（#49）→ #52
- #70 で未測定だった形（`DESC`、`SELECT` の変種、`SHOW FUNCTIONS`／`SESSION`／`STATS`、28.9 MB より上のマルチパートの境界）→ #76。`SHOW SESSION`・`SHOW STATS` は本物が `StartQueryExecution` で拒否した。`DESC` とマルチパートの境界の値は #76 の抽出には無く、[docs/result-files.md](../result-files.md) の表と記述による。`SHOW CREATE VIEW` は #146・#151 で測った（下の行）
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
- 暗号化系の `SHOW` に素の protobuf の `.txt.metadata` を返して Athena JDBC 3.5.1 未満が壊れないか（#5）→ #111（`.txt.metadata` を読み込む auto のある 3.4.0・3.5.0 は例外なく読んだ。3.4.0・3.5.0 の auto で準備の `CREATE TABLE` が既知の NoSuchKey。3.0.0〜3.3.0 は下の「実クライアントでの疎通」に残す。[measurements/clients.md](measurements/clients.md)）
- 長時間運用でメモリが頭打ちになるか（保持期限による破棄の実効性）→ #121（2026-09-25。1 時間ずつ流し、保持 1 秒の RSS は最後まで 11〜12MiB、保持 3600 秒は 3.1GiB。[measurements/client-request-token.md](measurements/client-request-token.md)）。それ以前は #111（2026-09-23。同じ負荷を 240 秒ずつ流し、保持 1 秒の VmRSS の暖機後の伸びは 17.9MiB（後半 3.1MiB）、保持 3600 秒は 3267.9MiB。最初の ID は 1 秒側で 400。足場は `tools/e2e/retention/verify.sh`。docs/caveats.md の Query lifecycle に書いた。数時間の推移は #121）
- `CREATE TABLE` の重複の結果ファイル（#6）→ #146（2026-09-24。Hive の外部テーブルの 2 回目は FAILED で理由を `<id>.txt` に置き `.metadata` 無し、Iceberg の CTAS の 2 回目は何も置かない。[measurements/result-files.md](measurements/result-files.md)）
- `.txt` の値に区切り文字（タブ）や改行が入るときのエスケープと、NULL の書き方（#1）→ #146（2026-09-24、3 回目。エスケープは無くタブも改行もそのまま。`GetQueryResults` は値の中の改行で行が分かれる。コメントの無い列は `DESCRIBE` で空白 20 個。列コメントの改行は Glue が受け付けず測れない）
- 失敗した `SHOW FUNCTIONS` が結果ファイルを置くか（#80）→ #146（2026-09-24。`<id>.csv` も `.metadata` も置かない）
- `SHOW CREATE VIEW` の Content-Type（#76）→ #146（2026-09-24。本体・`.metadata` とも binary/octet-stream で、`.metadata` は 312B の不透明な形式。対照の Iceberg の `SHOW CREATE TABLE` が既存の記録と食い違ったので「結果ファイル」に残し、#151 で決着）
- `SHOW CREATE TABLE` の Content-Type・`.metadata` の形式がテーブルの形式で割れるか（#146）→ #151（2026-09-24。同じラウンドで Hive／Iceberg × 素の CREATE／CTAS の 4 組を測り、形式で割れると決着。[measurements/result-files.md](measurements/result-files.md) の「`SHOW CREATE TABLE` の Content-Type はテーブルの形式で割れる」）
- `.metadata` の `timestamp with time zone`／`time with time zone`／`interval year to month`／`uuid`／`ipaddress` の field 7／8／10 の有無（#5）→ #146（2026-09-24。推測で実装していたとおり: 前 2 つは 7／8／10 あり、`interval year to month` は 10 だけ、`uuid`・`ipaddress` は 3 つとも無し。[measurements/metadata.md](measurements/metadata.md)）
- 更新件数 0 の `UPDATE` / `DELETE` / `MERGE` で本物が field 3 を出すか（#35・#91）→ #146（2026-09-24。3 文とも `18 00` を書く）
- 0 行の CTAS（更新件数 0）で本物が field 3 を出すか（#5）→ #146（2026-09-24。`18 00` を書く）
- `ALTER TABLE ... REPLACE COLUMN`（単数形）の受理と `SubstatementType`（#43）→ #146（2026-09-24。`StartQueryExecution` が `mismatched input 'REPLACE'` の `MALFORMED_QUERY` で受け付けない。[measurements/result-files.md](measurements/result-files.md)）
- `ALTER TABLE ... DROP PARTITION` × Iceberg（#43）→ #146（2026-09-24。FAILED `Query type not supported by Athena Iceberg at this time`、`SubstatementType` は `ALTER_TABLE_DROP_PARTITION`、何も置かず `GetQueryResults` は `RESULT_NOT_FOUND`）
- `Catalog` の差が冪等性の衝突（`IDEMPOTENT_PARAMETER_MISMATCH`）になるか（#3）→ #146（2026-09-24。大文字小文字だけの違いも実在しない名前も衝突。[measurements/client-request-token.md](measurements/client-request-token.md)）
- 同じトークンの再送で `OutputLocation` が不正な値、または `QueryString` が構文エラーのとき、トークンの照合と検証のどちらが先か（#102）→ #146（2026-09-24。どちらも検証のエラーが先）
- `Database`／`OutputLocation` の「省略」と「既定と同じ値の明示」を本物が別物として扱うか → #146（2026-09-24。`Database` は別物（衝突）。`OutputLocation` は出力先を強制するワークグループで同じ ID が返った。強制しないワークグループは上の「ClientRequestToken と保持期限」に残した）
- 出力先が設定されたワークグループの `GetWorkGroup` の `ResultConfiguration` の形 → #146（2026-09-24。`{"OutputLocation": "s3://.../"}` だけ。[measurements/work-groups.md](measurements/work-groups.md)）
- 空白入りの括弧で始まるクエリ（`( SELECT 1 )`）を本物がどう分類するか（#113）→ #146（2026-09-24。`( SELECT 1 )`・改行入りとも `DML`／`SELECT`。[measurements/statements.md](measurements/statements.md)）
- 本物がトークンを正規化するか（前後の空白、`"`、`\`、大文字小文字） → #147（2026-09-24。正規化しない。4 変種とも別の新しい ID、そのままの再送だけ同じ ID。[measurements/client-request-token.md](measurements/client-request-token.md)）
- トークン長の制約（32〜128）がバイト数か文字数か → #147（2026-09-24。`あ`×20（60B）は「greater than or equal to 32」で拒否、`あ`×50（150B）は別の文言 `clientRequestToken exceeds maximum allowed length 128` で拒否。下限は文字数、上限はバイト数と読める。athena-local は #153 で上限にバイト数の検査を足した。両方で超える組は上の「ClientRequestToken と保持期限」に残した）
- トークンの検証と他の検証エラー（`OutputLocation` の不正・構文エラー）の優先順位 → #147（2026-09-24。長さの足りないトークンはどちらよりも先。#146 の `OutputLocation` → 構文と合わせて、トークン → `OutputLocation` → 構文）
- 構文エラー（`MALFORMED_QUERY`）の本文に `ErrorCode` キーが付くか（#3）→ #147（2026-09-24。`ErrorCode` `MALFORMED_QUERY` が付き、キーは `__type`・`AthenaErrorCode`・`ErrorCode`・`Message` の 4 つ。`x-amzn-errortype` ヘッダは無い。[measurements/errors.md](measurements/errors.md)）
- ビューへの `DESCRIBE` の `UpdateCount`・Content-Type・`.metadata`（#160）→ #173（2026-09-24。`SHOW COLUMNS` も含め SubstatementType `DESC_VIEW`、`column`／`type` の varchar 2 列、UpdateCount 0、binary、`.metadata` は 440B の不透明な形式。[measurements/query-results.md](measurements/query-results.md) の「DESCRIBE／SHOW COLUMNS の行の形」）
- Hive のテーブルへの `DESC t`（#160）→ #173（2026-09-24。`DESCRIBE t` と同じ。同じ項目）
- 本物の Athena + PyAthena の `PandasCursor` で Iceberg の `DROP TABLE` を読むと `EmptyDataError` になるか（#111 の人間検証）→ #119（2026-09-25。本物でも `OperationalError: No columns to parse from file`。素の `Cursor` と Hive の `DROP TABLE` は例外なし。[measurements/clients.md](measurements/clients.md)）
- `SHOW CREATE TABLE"t"`（`TABLE` と引用符付きの名前の間に空白が無い形）を本物が受けるか、受けるなら分類と Content-Type（#151）→ #200（2026-09-25。本物は空白の有無によらず `StartQueryExecution` の時点で `InvalidRequestException` にする（実行は作られない）。athena-local は Trino が受けるので実行し、空白ありの形と同じ `UTILITY`／`SHOW_CREATE_TABLE`／application を返す。同じラウンドで、キーワードの直後に空白の無い他の形（`SELECT(1)` など）も空白ありの形と同じに分類することを確かめた。[measurements/statements.md](measurements/statements.md) の「キーワードの直後に空白が無い形」）

## 測れないもの

本物の Athena でも観測できない・誘発できないと分かった項目。測る対象から外す（#112）。理由が崩れたら（新しいアカウントを用意した、Athena が空の列名を通すようになった、など）上の一覧に戻す。

- カタログの既定など、`WITH` 句以外からテーブルの形式が決まる場合の CTAS・INSERT の結果ファイル（#26・#35）。Athena のテーブルの形式は文の `WITH` 句（`table_type` など）で決まり、カタログの既定で形式が決まるテーブルを Athena では作れない。athena-local は Trino のカタログの connector から形式を決めるので、[docs/caveats.md](../caveats.md) の「Table format is detected per Trino catalog」にある差分はこの理由で埋まらない
- `.metadata` の空の列名の扱い（#5）。本物では空の列名の列を作れないので観測できない。athena-local は空の列名でも列の field を出す
- `AthenaErrorCode` の無い経路のうち `InternalServerException` の本文の形。本物ではサーバ側の障害でしか出ず、クライアントから誘発できない（パース失敗と未対応オペレーションは #84 で実測: `SerializationException`・`UnknownOperationException` はどちらも `AthenaErrorCode` 無し）。athena-local は `AthenaErrorCode` も `ErrorCode` も付けずに返す（[docs/caveats.md](../caveats.md) の「Error body key casing」）
- `GetWorkGroup` の実測値（`EnforceWorkGroupConfiguration=false` 等）が工場出荷時の既定か、コンソールで変えた後の値か。測ったアカウントの `primary` は過去に設定を変えた可能性があり、新しいアカウントを作らないと区別できない（[measurements/work-groups.md](measurements/work-groups.md) の備考）
- 列の field 2 / 3（SchemaName / TableName）が本物で出るか（#5）。実テーブルの `SELECT` でも出ないこと（`ColumnInfo` も空）は観測済み（[measurements/metadata.md](measurements/metadata.md)）だが、出す条件があるかどうかまでは本物では観測できない（判断: #113、2026-09-24）
- `ListWorkGroups` の `MaxResults` 未指定時の既定ページサイズ（athena-local は 50）。51 個のワークグループを用意しないと境界が見えず、実アカウントに 51 件のワークグループを作ることになるのでユーザー判断で測らない（#113、2026-09-24）
- 列の Nullable（field 9）の 1（NOT_NULL）と 2（NULLABLE）（#5）。本物では NOT NULL 列の Iceberg テーブルを DDL で作れない（Hive 風の `TBLPROPERTIES ('table_type'='ICEBERG')` も `WITH (...)` の綴りも `StartQueryExecution` が `MALFORMED_QUERY`）。NULL 可の列も 3（UNKNOWN）で、これまで観測したのは 3 だけ（#146、2026-09-24。[measurements/metadata.md](measurements/metadata.md)）
