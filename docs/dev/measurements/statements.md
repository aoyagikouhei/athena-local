# 文の種類

`StatementType`／`SubstatementType` の判定（先頭のコメント、キーワードの間のコメント、個別の文）、本物だけが実行時に弾く形、`EXPLAIN` の行の分け方と変種、`CREATE OR REPLACE TABLE ... AS`、CTAS の `AS` の後ろ（括弧・`VALUES`・`TABLE`）。書き方は [README.md](README.md)。

対応する利用者向けの章: [docs/api.md](../../api.md)、[docs/caveats.md](../../caveats.md) の「SQL dialect」と「`ALTER TABLE` and format-dependent DDL」。

## 先頭のコメント

### 先頭コメントと文の種類の判定（決め手、C 群）
- 日付: 2026-09-18 09:06 ／ issue: #17 ／ スクリプト: `tools/measure/leading-comment.sh`（旧 `17-measure-leading-comment.sh`）（33 項目。`PROBE_DDL=1`。`CREATE/DROP DATABASE athena_local_probe_17` と Iceberg テーブル 2 件を作って消す） ／ 生データ: `$HOME/athena-comment-measurements/run-20260918-090622`
- 相手: 本物の Athena
- 投げたもの: 下の表の SQL
- 返ったもの:

| SQL | StatementType | Substatement | ファイル |
|---|---|---|---|
| `-- SELECT\nSHOW TABLES` | **UTILITY** | SHOW_TABLES | `.txt` |
| `/* SELECT */ SHOW TABLES` | **UTILITY** | SHOW_TABLES | `.txt` |
| `/* SHOW TABLES */ SELECT 1` | **DML** | SELECT | `.csv` |

- 備考: **分岐 A で確定: 本物は先頭のコメントを飛ばして文の種類を判定する。** コメントの中のキーワードは読まれない。行コメントもブロックコメントも同じ。33 項目すべて測れた（未測定 0、再試行 0）。
- 備考（追記）: #5 のノートの記述（`5.md:407`「先頭がコメントの文も本物なら `.csv` になるはず」）は athena-local 相手の観測と推測で本物の実測ではないと、#17 が 2026-09-18 に判定した。そのためこのラウンドから測った。

### 先頭コメント付きの文ごとの見え方（A・B・F 群）
- 日付: 2026-09-18 ／ issue: #17 ／ スクリプト: `tools/measure/leading-comment.sh`（旧 `17-measure-leading-comment.sh`） ／ 生データ: `$HOME/athena-comment-measurements/run-20260918-090622`
- 相手: 本物の Athena
- 投げたもの: 下の表の SQL（`.metadata` の ID 列は `.metadata` の先頭 field 1 の形（trino / uuid）だけ）
- 返ったもの:

| SQL | StatementType | Substatement | ファイル | UpdateCount | `.metadata` の ID |
|---|---|---|---|---|---|
| `-- c\nSELECT 1` / `/* c */ SELECT 1` | DML | SELECT | `.csv` | 0 | uuid |
| `-- c\nSHOW TABLES` / `/* c */ SHOW TABLES` | UTILITY | SHOW_TABLES | `.txt` | 0 | （protobuf でない。下記） |
| `-- c\nDESCRIBE t` | UTILITY | DESCRIBE_TABLE | `.txt` | 省く | **uuid** |
| `-- c\nSHOW CREATE TABLE t` | UTILITY | SHOW_CREATE_TABLE | `.txt` | 省く | **uuid** |
| `-- c\nEXPLAIN SELECT 1` | DML | EXPLAIN | `.txt` | 省く | trino |
| `-- c\nCREATE DATABASE ...` / `/* c */ ...` | DDL | CREATE_DATABASE | `.txt` | **省く** | （`.metadata` 無し） |
| `-- c\nDROP DATABASE ...` / `/* c */ ...` | DDL | DROP_DATABASE | `.txt` | **省く** | （`.metadata` 無し） |
| `-- c\n<Iceberg CTAS>` / `/* c */ <CTAS>` | DDL | CREATE_TABLE_AS_SELECT | `<id>`（拡張子なし） | 1 | trino |
| `-- c\nINSERT INTO ...` | DML | INSERT | `<id>` | 1 | trino |
| `DROP TABLE ...`（コメント無し） | DDL | DROP_TABLE | `.txt` | 省く | trino |

- 備考: コメント付き `DESCRIBE` と `SHOW CREATE TABLE` の `.metadata` の先頭は `uuid`（= `QueryExecutionId`）。当時の athena-local は `word(0) == "--"` になるので `engine_id`（trino）を入れており本物とずれていた（読み飛ばしを入れて一致させた）。**Iceberg CTAS の `<id>`（拡張子なし）は、#26 の 2026-09-19 の実測（Iceberg でも `tables/<id>`）で覆っている。** ただし #26 のノートは覆った相手として 2026-09-17 の実測（#5、#12）だけを挙げており、この 2026-09-18 の実測にも `<id>` と出ていることには触れていない（抽出者の注記。判断に迷った点）。INSERT の `<id>` も #26 は「2026-09-17 実測、今回測っていない（#35 に起票）」とするが、ここでも 2026-09-18 に `<id>` と出ている。

### 空白・連続・境界（D 群）
- 日付: 2026-09-18 ／ issue: #17 ／ スクリプト: `tools/measure/leading-comment.sh`（旧 `17-measure-leading-comment.sh`） ／ 生データ: `$HOME/athena-comment-measurements/run-20260918-090622`
- 相手: 本物の Athena
- 投げたもの: `-- c\n\n   SELECT 1`／`-- a\n-- b\nSELECT 1`／`-- a\n/* b */ SELECT 1`／`--c\nSELECT 1`／`/* c */SELECT 1`／`/* a\nb */ SELECT 1`／`   SELECT 1`／`SELECT 1 -- c`
- 返ったもの: **すべて DML / SELECT / `.csv`**
- 備考: 空行・連続・混在・区切りの空白の有無・コメント内の改行のどれも飛ばす。末尾のコメントは判定に影響しない。

### 失敗系（E 群）
- 日付: 2026-09-18 ／ issue: #17 ／ スクリプト: `tools/measure/leading-comment.sh`（旧 `17-measure-leading-comment.sh`） ／ 生データ: `$HOME/athena-comment-measurements/run-20260918-090622`
- 相手: 本物の Athena
- 投げたもの／返ったもの:

| SQL | 結果 |
|---|---|
| `-- only` | `InvalidRequestException` / `line 1:8: mismatched input '<EOF>'`（`-- only` は 7 文字。**コメントを飛ばした先**の位置） |
| `/* only */` | `InvalidRequestException` / `line 1:11: mismatched input '<EOF>'`（同上） |
| `/* c SELECT 1`（未閉じ） | `InvalidRequestException` / `line 1:1: mismatched input '/'`。**本物は未閉じをコメントとして扱わない** |
| `''`（空文字列） | CLI が送信前に拒否（`ParamValidation`。ワイヤに乗らない） |

- 備考: athena-local はこれらを `Trino::syntax_error` の `PREPARE` で弾く（文言は Trino のもの。README に既記）。未閉じの扱いの差（athena-local の `comment_end` は末尾まで飛ばす）は、どちらも構文エラーになって実行が作られないので観測できる差にならない。

## キーワードの間のコメント

### キーワード間のコメントの扱い
- 日付: 不明（ノートに日付が無い。時系列は実測 18:08〜18:16。#49 が 2026-09-22 17:2x に起票しているので 2026-09-22 と推定） ／ issue: #52 ／ スクリプト: `tools/measure/keyword-comment.sh`（旧 `52-measure-keyword-comment.sh`。抽出には名前が無い。git の履歴（f5454f9、2026-09-22「issue #52 の実測スクリプトを置く」）から特定）
- 相手: 本物の Athena（ユーザー実行、1 ラウンド、29 項目）
- 投げたもの: 動詞と `TABLE` の間やキーワード間に `/* c */`・`-- c` を挟んだ文（CTAS、`SHOW CREATE TABLE`、`ALTER TABLE` など）
- 返ったもの:
  - 本物はキーワード間の `/* c */`・`-- c` を空白として分類する
  - CTAS は成功・失敗とも `tables/<id>`
  - `SHOW /* c */ CREATE TABLE`・`SHOW CREATE /* c */ TABLE`・存在しないテーブルへの `ALTER /* c */ TABLE` は分類は付くが実行は ParseException
  - Iceberg への `ALTER /* c */ TABLE` は成功
- 備考: 「存在しないテーブルへの ALTER」が Hive 側と読めるかはノートからは曖昧（README の Caveat に「本物だけが弾く形（SHOW CREATE TABLE・Hive 側の ALTER）」と書いたとある）

### キーワードの間のブロックコメント（DESCRIBE・SHOW 4 文・MSCK REPAIR TABLE・CREATE EXTERNAL TABLE）
- 日付: 2026-09-24 ／ issue: #146（バッチは #113） ／ スクリプト: `tools/measure/unmeasured-batch/run.sh`（項目 `x1`） ／ 生データ: `$HOME/athena-unmeasured-batch-measurements/run-20260924-004554/x1/`
- 相手: 本物の Athena（engine version 3、workgroup `primary`、Catalog `AwsDataCatalog`、Database `<DB>`）
- 投げたもの: フィクスチャの Hive テーブル `t` = `CREATE EXTERNAL TABLE <DB>.athena_local_probe_113_x1 (n int) PARTITIONED BY (p string) LOCATION '<OUTPUT>tables-probe-113-x1/'` とビュー `v` = `CREATE VIEW <DB>.athena_local_probe_113_x1_view AS SELECT 1 AS n`（どちらも SUCCEEDED）。下表の 7 文を、コメント無しの対照と `/* c */` 入りで 1 本ずつ。`CREATE EXTERNAL TABLE` は別名の新しいテーブル（`..._x1_ext`・`..._x1_ext_c`、`LOCATION` も別）
- 返ったもの:

  | コメント入りの文 | 対照（コメント無し） | コメント入り |
  | --- | --- | --- |
  | `DESCRIBE /* c */ t` | SUCCEEDED、UTILITY / DESCRIBE_TABLE、本体 291B・`.metadata` 152B、application | **FAILED**、UTILITY / DESCRIBE_TABLE、`FAILED: ParseException line 1:0 cannot recognize input near 'DESCRIBE' '/' '*' in describe statement`、ErrorCategory 1 / ErrorType 1003。`<id>.txt` 100B（`StateChangeReason` と同じ文言、application）、`.metadata` 無し。`GetQueryResults` は 200 で `ResultSetMetadata: null` |
  | `SHOW PARTITIONS /* c */ t` | SUCCEEDED、UTILITY / SHOW_PARTITIONS、本体 0B（パーティション無し）・`.metadata` 312B、binary | SUCCEEDED、同じ |
  | `SHOW TBLPROPERTIES /* c */ t` | SUCCEEDED、UTILITY / SHOW_TABLE_PROPERTIES、本体 46B・`.metadata` 460B、binary | SUCCEEDED、同じ（本体の中身も同じ） |
  | `SHOW COLUMNS FROM /* c */ t` | SUCCEEDED、UTILITY / SHOW_COLUMNS、本体 41B・`.metadata` 312B、binary | SUCCEEDED、同じ（本体の中身も同じ） |
  | `MSCK REPAIR /* c */ TABLE t` | SUCCEEDED、DDL / MSCK_REPAIR、本体 55B（`Tables missing on filesystem:\tathena_local_probe_113_x1`）・`.metadata` 38B（`0a 24` + QueryExecutionId だけ）、application | **FAILED**、DDL / MSCK_REPAIR、`FAILED: ParseException line 1:12 missing EOF at '/' near 'REPAIR'`、ErrorCategory 1 / ErrorType 1003。`<id>.txt` 65B（`StateChangeReason` と同じ文言、application）、`.metadata` 無し |
  | `SHOW CREATE /* c */ VIEW v` | SUCCEEDED、UTILITY / SHOW_CREATE_VIEW、本体 69B・`.metadata` 312B、binary | SUCCEEDED、同じ（本体の中身も同じ） |
  | `CREATE EXTERNAL /* c */ TABLE ... (n int) LOCATION '...'` | SUCCEEDED、DDL / CREATE_TABLE、本体 0B、`.metadata` 無し、binary | SUCCEEDED、同じ |

  - 「application」「binary」は本体と `.metadata` の Content-Type（置かれたものはどちらも同じ値）
  - コメント入りで FAILED になった 2 本も、`StatementType`／`SubstatementType`／OutputLocation（`<id>.txt`）はコメント無しと同じに返る
  - `MSCK REPAIR TABLE`（対照）の `GetQueryResults` は 1 行（本体と同じ文字列）を返すが、`ColumnInfo` は空で `UpdateCount` も無い
- 備考: #17・#52 の `SHOW CREATE TABLE`（`/* c */ SHOW CREATE TABLE`・`SHOW CREATE /* c */ TABLE` が ParseException、ErrorCategory 1 / ErrorType 1003）と同じ形の失敗が `DESCRIBE` と `MSCK REPAIR TABLE` にもあった。一方 `SHOW CREATE /* c */ VIEW` は成功し、#52 の `SHOW CREATE /* c */ TABLE` と割れた。`summary.txt` の `x1-show-partitions-comment` の行で QueryExecutionId の一部が `<ACCOUNT_ID>` になっているのは、12 桁の数字を一律に伏せるマスクの副作用（アカウント ID ではない）

## 本物だけが実行時に弾く形（`/* c */ SHOW CREATE TABLE`）

### 範囲外の発見（同じラウンド）
- 日付: 2026-09-18 ／ issue: #17 ／ スクリプト: `tools/measure/leading-comment.sh`（旧 `17-measure-leading-comment.sh`） ／ 生データ: `$HOME/athena-comment-measurements/run-20260918-090622`
- 相手: 本物の Athena
- 投げたもの／返ったもの:
  - `/* c */ SHOW CREATE TABLE t` は本物では **FAILED**（`ParseException line 1:0 cannot recognize input near '/' '*' 'c'`、ErrorCategory 1 / ErrorType 1003）。ただし `StatementType`／`SubstatementType`／`OutputLocation` は `UTILITY`／`SHOW_CREATE_TABLE`／`.txt` と**正しく返る**。分類はコメントを飛ばすが、`SHOW CREATE TABLE` の実行パーサ（Hive 系）がブロックコメントを受け付けない。行コメント版は成功する（→ #27）。
  - `SHOW TABLES` の `.metadata`（312 バイト）は **protobuf ではない**（先頭が `41 57 71 43 2f`＝`AWqC/`…）。`DESCRIBE` は `0a 24` + UUID で正しく protobuf。コメントの有無で変わらない（→ #24）。
  - `SELECT` の `.csv` の Content-Type が `binary/octet-stream` だった（athena-local は `application/octet-stream`）。#1 のノートにある既知の揺れ（実測のたびに binary と application に割れ、多数派を採ると決めてある）。
- 備考: 無し

### `/* c */ SHOW CREATE TABLE` の本物の挙動（#17 の実測を出典にしたもの）
- 日付: 2026-09-18（#17 の実測。#27 自身は本物を測っていない） ／ issue: #27（実測は #17） ／ スクリプト: `tools/measure/leading-comment.sh`（旧 `17-measure-leading-comment.sh`）（#17 のもの）
- 相手: 本物の Athena（#17 の実測 `b-block-show-create`）
- 投げたもの: `/* c */ SHOW CREATE TABLE t`
- 返ったもの: #27 のノートには文言が書いていない（「実測したエラー文言」を README に足したとだけある）。#17 のノートでは FAILED（`ParseException line 1:0 cannot recognize input near '/' '*' 'c'`、ErrorCategory 1 / ErrorType 1003）、分類は `UTILITY`／`SHOW_CREATE_TABLE`／`.txt` と正しく返る、行コメント版は成功する
- 備考: 出典は #17 の 2026-09-18 実測。

## 個別の文の分類

### `TABLE t` 文の分類と結果ファイル
- 日付: 2026-09-22（生データのディレクトリ名から。時系列は 21:02〜21:07） ／ issue: #65 ／ スクリプト: `tools/measure/table-statement.sh`（旧 `65-measure-table-statement.sh`。抽出には名前が無い。git の履歴（7a10a19、2026-09-22「issue #65 の実測スクリプトを置く」）から特定） ／ 生データ: `~/athena-table-statement-measurements/run-20260922-210254`
- 相手: 本物の Athena（1 ラウンド、7 項目すべて）
- 投げたもの: `TABLE t`・小文字・`(TABLE t)`・先頭コメント付き・`LIMIT 1` 付き・存在しないテーブル
- 返ったもの: 本物はすべて受け付け、StatementType `DML`／SubstatementType `SELECT`／`<id>.csv`／`.metadata` あり／`GetQueryResults` の 1 行目は列名行（本体の先頭行と一致）。存在しないテーブルは FAILED でも `DML`／`SELECT`／`.csv`
- 備考: 範囲外の発見として、`SELECT 1` の `.csv`／`.metadata` と `SHOW TABLES` の `.metadata` の Content-Type が `binary/octet-stream` で、README と `ResultFile::content_type`（2026-09-17 実測の `application/octet-stream`）と食い違う → #70 に起票（#70 で規則を実測して直した）

### 括弧で始まる SELECT の分類（#76 の生データの読み直し）
- 日付: 2026-09-23（生データ `run-20260923-065415`） ／ issue: #113（実測は #76） ／ スクリプト: 無し（#76 のラウンドの生データ） ／ 生データ: `~/athena-content-type-measurements/run-20260923-065415/g10-parenthesized.*`
- 相手: 本物の Athena（#76 の生データ）
- 投げたもの: `(SELECT 1)`（括弧の直後にスペース無し）
- 返ったもの: `g10-parenthesized.execution.json` で `StatementType: DML`／`SubstatementType: SELECT`。括弧で始まっても通常の `SELECT` と同じに分類される
- 備考: `docs/dev/unmeasured.md` の「`ExecutionParameters`」節にあった「括弧で始まるクエリを本物がどう分類するか」を、#113 でこの生データを読み直して埋めた。前後にスペースを挟んだ `( SELECT 1 )` はこの生データには無く、#113 のバッチで別途測る（本物での実行は #146）。

### 空白・改行を挟んだ括弧で始まる SELECT の分類
- 日付: 2026-09-24 ／ issue: #146（バッチは #113） ／ スクリプト: `tools/measure/unmeasured-batch/run.sh`（項目 `p1`） ／ 生データ: `$HOME/athena-unmeasured-batch-measurements/run-20260924-004554/p1/`
- 相手: 本物の Athena（engine version 3、workgroup `primary`、Catalog `AwsDataCatalog`、Database `<DB>`）
- 投げたもの: 対照 `(SELECT 1)`、`( SELECT 1 )`、`(` + 改行 + `SELECT 1` + 改行 + `)`
- 返ったもの: 3 本とも同じ。SUCCEEDED、`StatementType: DML`／`SubstatementType: SELECT`、`<id>.csv` 12B（`"_col0"\n"1"\n`）、`<id>.csv.metadata` 68B（field 1 はエンジン ID、列 `_col0` `integer` で 7 = 10・8 = 0・9 = 3・10 = 0）、Content-Type は本体・`.metadata` とも application/octet-stream。`GetQueryResults` は列名行 `_col0` と `1` の 2 行
  - 3 本の `.metadata` は field 1（エンジン ID）を除いてバイト単位で同じ
- 備考: 対照は上の #76 の `g10-parenthesized`（`DML`／`SELECT`）の再現

### SHOW FUNCTIONS の結果ファイル（#76 の生データの読み直し）
- 日付: 2026-09-23（生データ `run-20260923-065415`） ／ issue: #80（実測は #76） ／ スクリプト: 無し（#76 のラウンドの生データ） ／ 生データ: `~/athena-content-type-measurements/run-20260923-065415/h1-show-functions.*`
- 相手: 本物の Athena（#76 の生データ）
- 投げたもの: `SHOW FUNCTIONS`
- 返ったもの: `<id>.csv`（CSV の書式: 引用・空文字 `""`・末尾改行）、`.metadata` の先頭 ID は Trino の ID、GetQueryResults は列名行つき、SubstatementType `SHOW_FUNCTIONS`
- 備考: 無し

## ALTER TABLE の変種

`ALTER TABLE` の変種ごとの `SubstatementType`、受理と構文エラー（`ALTER TABLE IF EXISTS`、`RENAME COLUMN`、`DROP COLUMNS` の複数形）は、結果ファイルと同じ表で測ったので [result-files.md](result-files.md) の「ALTER TABLE の結果ファイル」に置いた。Trino がどの綴りを受け付けるかは [trino.md](trino.md)。

## EXPLAIN

### EXPLAIN の `.txt` の中身（過去の生データの再構成）
- 日付: 生データは `run-01-20260915`・`run-20260916-094100`。読み直しの日付はノートに無い（#60 の後。2026-09-22 と推定） ／ issue: #63 ／ スクリプト: 無し（読み直し） ／ 生データ: `~/athena-txt-measurements/run-01-20260915`・`run-20260916-094100` の `explain.bytes`
- 相手: 本物の Athena（過去 2 ラウンドの生データ）
- 投げたもの: `EXPLAIN SELECT 1`（#68 のノートによる）
- 返ったもの: 「列名行込みの全行を `\n` で連結・末尾改行なし」で再構成すると 393 バイトが一致（本物は `.txt` の先頭に列名の見出し行 `Query Plan` を入れる）
- 備考: 行の分け方（プランを行ごとに Rows に分ける）は後に #73 で本物に合わせた。393 バイトは #73 でも一致を確認

### EXPLAIN の Query Plan 列の Precision 371 の由来（過去の生データの読み直し）
- 日付: 生データは過去 2 ラウンド（`~/athena-txt-measurements` の `explain.results.json`。#63 が挙げるディレクトリ名から 2026-09-15・16 と推定）。読み直しの日付はノートに無い（#63 の後。2026-09-22 と推定） ／ issue: #68 ／ スクリプト: 無し ／ 生データ: 過去 2 ラウンドの `explain.results.json`
- 相手: 本物の Athena（過去 2 ラウンドの生データ。新規ラウンド 0）
- 投げたもの: `EXPLAIN SELECT 1`（2 ラウンドとも同じ）
- 返ったもの: 非空 11 行の文字数 359 + 行間の改行 10 + 末尾の `\n\n` 2 = 371 で、Trino のプラン全文の形（末尾 `\n\n`）と一致。本物の 371 はエンジンが `varchar(<プランの文字数>)` と型付けした結果
- 備考: issue の「athena-local は 2147483647 になる」はテストの偽 Trino（typeSignature 無し）の応答から出た誤り（athena-local は既に同じ仕組みで通していた）

### EXPLAIN の Rows の分け方と `.txt`（過去の生データの読み直し）
- 日付: 読み直しの日付はノートに無い（時系列 06:00〜06:05。#70（2026-09-23 03:41〜）と #75（06:15）の間なので 2026-09-23 と推定）。生データは過去 4 ラウンド ／ issue: #73 ／ スクリプト: 無し ／ 生データ: `~/athena-txt-measurements/*/explain.results.json`・`explain.od.txt`
- 相手: 本物の Athena（過去 4 ラウンドの生データ）
- 投げたもの: `EXPLAIN SELECT 1`（#68 のノートによる）
- 返ったもの: `Rows` 15 行と `.txt` 393 バイトの両方が「プラン全文 + `\n` を `\n` で分ける」で一致。issue が未確定としていた 2 つの規則（split の後に 1 行足す／末尾に `\n` を足してから split）は常に同じ結果になるので 1 種類の EXPLAIN で決まる
- 備考: 変種（FORMAT JSON / TYPE IO / ANALYZE など）は #92 で実測

### EXPLAIN の変種の Rows と `.txt`、失敗時の結果ファイル
- 日付: 2026-09-23（13:27〜13:30、ユーザーが実行） ／ issue: #92 ／ スクリプト: `tools/measure/explain-variants.sh`（旧 `92-measure-explain-variants.sh`） ／ 生データ: `run-20260923-132753`
- 相手: 本物の Athena（1 ラウンド、StartQueryExecution 11 回）
- 投げたもの: 文字列のプラン 7 形（text / DISTRIBUTED / ANALYZE / ANALYZE VERBOSE / FORMAT JSON / TYPE IO / GRAPHVIZ）、`TYPE VALIDATE`、失敗する `EXPLAIN` と `EXPLAIN ANALYZE`
- 返ったもの:
  - 文字列のプラン 7 形はすべて現状の規則と一致。末尾の空行: JSON / IO は 1、GRAPHVIZ は 2、text / DISTRIBUTED / ANALYZE / ANALYZE VERBOSE は 3。`.txt` は Rows を `\n` で連結したものと全件バイト一致
  - `TYPE VALIDATE` は boolean の `true` にも空行が付く（Rows 3 行・`.txt` 11 バイト）
  - 失敗した `EXPLAIN` と `EXPLAIN ANALYZE` は本体も `.metadata` も無し（404、ErrorType 1301）
  - `EXPLAIN ANALYZE` の SubstatementType は `EXPLAIN`、列は varchar(2147483647)
- 備考: 無し

### EXPLAIN の変種の `UpdateCount`（#92 の生データの読み直し）
- 日付: 2026-09-24（読み直し。元の実測は 2026-09-23、#92） ／ issue: #169 ／ スクリプト: 無し（`$HOME/athena-explain-variants-measurements/run-20260923-132753/e1〜e8.results.json` と `probe-show-tables.results.json` を読んだ） ／ 生データ: 同左
- 相手: 本物の Athena（#92 のラウンド）
- 投げたもの: #92 の 8 変種（`EXPLAIN SELECT 1`、`(FORMAT JSON)`、`(TYPE IO)`、`EXPLAIN ANALYZE`、`(TYPE DISTRIBUTED)`、`(TYPE VALIDATE)`、`(FORMAT GRAPHVIZ)`、`EXPLAIN ANALYZE VERBOSE`）と対照の `SHOW TABLES`
- 返ったもの: `GetQueryResults` の `UpdateCount` は 8 変種とも `null`（CLI の応答でキーはあり値が null）。対照の `SHOW TABLES` は `0`。#1（2026-09-15／16 の 4 ラウンド）・#17（2026-09-18）・#70／#76（2026-09-23）の `EXPLAIN SELECT 1` も `null`
- 備考: `EXPLAIN` は StatementType が DML だが、`UpdateCount` は無し（`.txt` が application の群と同じ）。athena-local は DML 扱いで 0 にしていたのを #169 で省くようにした

**食い違い: `.txt` の列名の見出し行（EXPLAIN）**

- 2026-09-16（#1 の 4 回目、[result-files.md](result-files.md) の「`.txt` の中身と置かれ方（4 回目。これで揃った）」）: 「列名の行は入らない」。すべての文で `.txt` は `GetQueryResults` の行の連結とバイト一致とし、EXPLAIN は 393 バイト
- 2026-09-22（#63、過去の生データの再構成）: EXPLAIN の `.txt` は先頭に列名の見出し行 `Query Plan` を入れる（列名行込みで 393 バイトが一致）
- 採用: #63。見出しが入らないのは UTILITY／DDL で、EXPLAIN（DML）は入る（#60 の分け方に揃える #63 の判断）。393 バイトは #73 でも一致。

## CREATE OR REPLACE TABLE ... AS

### CREATE OR REPLACE TABLE ... AS SELECT
- 日付: 2026-09-23（2 回目 13:56〜13:59、ユーザーが実行。1 回目 `run-20260923-134733` は preflight で 404 になって止まった（スクリプトのバグで、本物の挙動の追加項目ではない）） ／ issue: #93 ／ スクリプト: `tools/measure/create-or-replace-table-as.sh`（旧 `93-measure-create-or-replace.sh`） ／ 生データ: `run-20260923-135634`
- 相手: 本物の Athena（StartQueryExecution 8 回）
- 投げたもの: Hive・Iceberg への `CREATE OR REPLACE TABLE ... AS SELECT`、対照の素の CTAS
- 返ったもの:
  - Hive・Iceberg とも `CREATE OR REPLACE TABLE ... AS SELECT` は StartQueryExecution で `InvalidRequestException`（`line 1:19: mismatched input 'TABLE'. Expecting: 'MATERIALIZED', 'MULTI', 'PROTECTED', 'VIEW'`、`AthenaErrorCode: MALFORMED_QUERY`）
  - 対照の素の CTAS は `tables/<id>`・`.metadata` 81 バイト・マニフェストあり・`CREATE_TABLE_AS_SELECT`（#26／#35 の再現）
- 備考: 本物は受け付けないので、結果ファイル名は存在しない

### `CREATE OR REPLACE TABLE ... AS` のファイル名（後日の追記）
- 日付: 2026-09-23 ／ issue: #26（実測は #93） ／ スクリプト: 無し（#26 のノートには書いていない）
- 相手: 本物の Athena（#93 で実測）
- 投げたもの: `CREATE OR REPLACE TABLE ... AS`（Trino だけの構文）
- 返ったもの: 本物は構文エラー（`mismatched input 'TABLE'`）で受け付けないので、ファイル名は存在しない
- 備考: #26 の「未実測のまま残るもの」に取り消し線で追記されたもの。詳細は #93 のノート。

## CTAS の `AS` の後ろ（括弧・`VALUES`・`TABLE`）

### 括弧付きのクエリ・`VALUES`・`TABLE` を持つ CTAS
- 日付: 2026-09-25（13:51〜13:59 JST、ユーザーが実行） ／ issue: #199 ／ スクリプト: `tools/measure/ctas-parenthesized-query.sh` ／ 生データ: `$HOME/athena-ctas-parenthesized-measurements/run-20260925-045112`
- 相手: 本物の Athena（StartQueryExecution 28 回。DDL は下の 9 テーブルの CTAS と DROP だけ）
- 投げたもの（`t` = `<DB>.athena_local_probe_199_<項目>`、Hive の既定。WITH も LOCATION も無し）: c0 `CREATE TABLE t AS SELECT 1 AS n`、c1 `AS (SELECT 1 AS n)`、c2 `AS(SELECT 1 AS n)`（空白なし）、v1 `AS (VALUES 1)`、v2 `CREATE TABLE t (n) AS (VALUES 1)`、v3 `AS VALUES 1`、v4 `CREATE TABLE t (n) AS VALUES 1`、t1 `AS (TABLE <c0>)`、t2 `AS TABLE <c0>`
- 返ったもの:

  | 項目 | State | StatementType / SubstatementType | OutputLocation | `.metadata` | `<id>` を含む key |
  |---|---|---|---|---|---|
  | c0・c1・c2・t1・t2 | SUCCEEDED | DDL / CREATE_TABLE_AS_SELECT | `<OUTPUT>tables/<id>` | 81B application/octet-stream（update_count 1） | 4 件（`tables/<id>.metadata`、`tables/<id>-manifest.csv`、`tables/<id>/<データ>`、`<id>/`） |
  | v1・v2・v3・v4 | FAILED | DDL / CREATE_TABLE_AS_SELECT | `<OUTPUT>tables/<id>` | 無し | 0 件 |

  - v1〜v4 の StateChangeReason は 4 件とも `MISSING_COLUMN_NAME: line 1:1: Column name not specified at position 1. You may need to manually clean the data at location '<OUTPUT>tables/<id>' before retrying. Athena will not delete data in your account.`（ErrorCategory 2、ErrorType 1100、Retryable false）。列の別名（`(n)`）を付けた v2・v4 も同じ文言
  - c0・c1・c2・t1・t2 は SHOW CREATE TABLE でテーブルができていることと Hive であることを確かめた
- 備考: 本物は `AS` の後ろの括弧の有無・`AS(` と続けた形・`SELECT`／`VALUES`／`TABLE` のどれでも、失敗しても CTAS として分類し `tables/<id>` にする。athena-local は `AS (VALUES` / `AS (TABLE` をファイル名だけ CTAS、`AS VALUES` / `AS TABLE` / `AS(SELECT` を両方とも CTAS でない扱いにしていたので、#199 で `is_create_table_as` を本物に揃えた。手元の Trino 482（memory カタログ）は v1・v3 を同じ `Column name not specified at position 1` で弾き、v2・v4 は通した（v2・v4 は athena-local では成功し、本物では失敗する）

## キーワードの直後に空白が無い形（`SELECT(1)` など）

Content-Type と `.metadata` を含む置き場所は本項が主で、[result-files.md](result-files.md) の「Content-Type」からここへリンクしている。

### 決め手: 空白の有無で分類が一致する（H1）
- 日付: 2026-09-25（06:08 UTC、run-20260925-055931） ／ issue: #200 ／ スクリプト: `tools/measure/keyword-boundary.sh` ／ 生データ: `$HOME/athena-keyword-boundary-measurements/run-20260925-055931`
- 相手: 本物の Athena（StartQueryExecution 44 本、ラウンド 1、`PROBE_DDL=1`。DDL は `athena_local_probe_200*` の Hive・CTAS 2・VIEW 2・Iceberg を作って消した）
- 投げたもの: キーワードの直後に空白の無い形と、対応する空白ありの対照（`SELECT(1)` / `SELECT (1)` など）
- 返ったもの:

  | 対（空白なし／空白あり） | State | StatementType／SubstatementType | 置き場所 | 本体 Content-Type | `.metadata`（クエリ ID の出どころ） | 行数 |
  |---|---|---|---|---|---|---|
  | `SELECT(1)` ／ `SELECT (1)` | SUCCEEDED | DML／SELECT | `.csv` | binary | binary（QueryExecutionId） | |
  | `SELECT'a'` ／ `SELECT 'a'` | 同 | DML／SELECT | `.csv` | binary | binary（QueryExecutionId） | |
  | `SELECT*FROM (VALUES 1)` ／ 空白あり | 同 | DML／SELECT | `.csv` | application | application（エンジン ID） | |
  | `SELECT"x" FROM (VALUES 1) AS t(x)` ／ 空白あり | 同 | DML／SELECT | `.csv` | application | application（エンジン ID） | |
  | `WITH"w" AS (SELECT 1 AS x) SELECT x FROM "w"` ／ 空白あり | 同 | DML／SELECT | `.csv` | application | application（エンジン ID） | |
  | `VALUES(1)` ／ `VALUES (1)` | 同 | DML／SELECT | `.csv` | application | application（エンジン ID） | |
  | `EXPLAIN(TYPE IO) SELECT 1` ／ 空白あり | 同 | DML／EXPLAIN | `.txt` | application | application（エンジン ID） | 12（行分割あり） |
  | `EXPLAIN(SELECT 1)` ／ 空白あり | 同 | DML／EXPLAIN | `.txt` | application | application（エンジン ID） | 本物 15（手元の Trino 482 は 16。プランの文面が版で違うだけで、行分割の規則の差ではない） |
  | `CREATE TABLE"c1" AS SELECT 1 AS x` ／ 空白あり | 同 | DDL／CREATE_TABLE_AS_SELECT | `tables/<id>` | — | application（エンジン ID） | |
  | `CREATE VIEW"v1" AS SELECT 1 AS x` ／ 空白あり | 同 | DDL／CREATE_VIEW | `.txt` 0B | binary | 無し | |
  | `SHOW CREATE VIEW"v1"` ／ 空白あり | 同 | UTILITY／SHOW_CREATE_VIEW | `.txt` | binary | binary 312B（不透明な形式） | 2 |
  | `DROP VIEW"v1"` ／ 空白あり | 同 | DDL／DROP_VIEW | `.txt` 0B | binary | 無し | |

- 備考: 空白の有無で全項目が一致した（決め手）。athena-local はこの実測を受けて `athena_sql::words` の語の境目を識別子の文字と ASCII の記号の境目にも広げ、空白の無い形を空白ありの形と同じに分類するようにした（2c7a329）。`SELECT (1)`（括弧付きリテラル）が本物で binary・athena-local が application になる差は語の境界と無関係な既存の差で、[#205](https://github.com/aoyagikouhei/athena-local/issues/205) に起票し、#205 で測り直して揃えた（[result-files.md](result-files.md) の「括弧付きのリテラルと符号の後ろの空白の Content-Type」）。

### 引用符付きの名前は空白の有無によらず開始時に弾かれる（DESCRIBE・DESC・SHOW CREATE TABLE・ALTER TABLE ... ADD COLUMNS・DROP TABLE・OPTIMIZE）
- 日付: 2026-09-25（同じラウンド、run-20260925-055931） ／ issue: #200 ／ スクリプト: `tools/measure/keyword-boundary.sh` ／ 生データ: `$HOME/athena-keyword-boundary-measurements/run-20260925-055931`
- 相手: 本物の Athena（同じ 44 本の一部）
- 投げたもの: 上の 6 種の引用符付き名前（空白あり・空白なし両方）と、無引用の対照
- 返ったもの（`StartQueryExecution` の `InvalidRequestException`。実行は作られない）:

  | 形（空白なし・空白ありの両方） | 理由 | 対照（無引用） |
  |---|---|---|
  | `DESCRIBE"t"`・`DESC"t"` | `no viable alternative at input 'DESCRIBE"…"'` | `DESCRIBE t` は UTILITY／DESCRIBE_TABLE、application、`.metadata` は QueryExecutionId、3 行 |
  | `SHOW CREATE TABLE"t"` | `Queries of this type are not supported` | 無引用は SHOW_CREATE_TABLE、application（Hive）、QueryExecutionId、21 行 |
  | `ALTER TABLE"t" ADD COLUMNS (m1 int)` | `mismatched input 'COLUMNS'. Expecting: '.', 'ADD'`（Trino の文法で読まれている） | 無引用は ALTER_TABLE_ADD_COLUMN |
  | `DROP TABLE"t"` | `mismatched input '"…_t"' expecting {'SELECT', 'FROM', …}` | 無引用（`IF EXISTS`）は DROP_TABLE |
  | `OPTIMIZE"t" REWRITE DATA USING BIN_PACK` | `mismatched input 'OPTIMIZE'. Expecting: 'ALTER', …`（Trino の文法で読まれている） | 無引用の `OPTIMIZE` は今回測っていない（Trino に無く athena-local では実行できないので起票しない） |

- 備考: `StartQueryExecution` の時点で実行が作られないので、分類そのものは観測できない。athena-local は SQL を書き換えず・独自に弾かない方針のため、Trino が受ける `OPTIMIZE` 以外の 5 形を実行してしまう（空白ありの形と同じ値を返す。`OPTIMIZE` は Trino に無く、athena-local も構文チェックで弾く。2026-09-25 手元の Trino 482 で確認）。差は [docs/caveats.md](../../caveats.md) の「SQL dialect」に記載し、athena-local 側を本物に揃える対応は [#204](https://github.com/aoyagikouhei/athena-local/issues/204) に起票した。

### 引用符付きの名前を取る DDL 系の文言の規則（#204、ラウンド 1・2）
- 日付: 2026-09-25 07:54 UTC（ラウンド 1） ／ issue: #204 ／ スクリプト: `tools/measure/quoted-names.sh`（`ROUND=1` が既定） ／ 生データ: `$HOME/athena-quoted-names-measurements/run-20260925-075408`
- 日付: 2026-09-25 08:35 UTC（ラウンド 2、未実測の形だけを追加で流した） ／ issue: #204 ／ スクリプト: 同上（`ROUND=2`） ／ 生データ: `$HOME/athena-quoted-names-measurements/run-20260925-083528`
- 相手: 本物の Athena（S3 Tables のカタログを含む構成）
- 投げたもの: 上の #200 の実測を受けて対象を広げた `StartQueryExecution` 群。ラウンド 1 は 72 本（DESCRIBE・DESC・SHOW CREATE TABLE・SHOW COLUMNS FROM／IN・DROP TABLE［IF EXISTS］・ALTER TABLE の各種操作・MSCK REPAIR TABLE と、無引用・バッククォート・引用符付きの対照。S3 Tables のカタログ名 `"s3tablescatalog/<bucket>".<ns>.<t>` を含む）。ラウンド 2 は 55 本（ラウンド 1 で未実測のまま残った形: 名前の部品数と引用符の位置の組み合わせ、`SHOW TABLES IN`、CTAS でない `CREATE TABLE`、`ALTER TABLE IF EXISTS`、`DROP DATABASE IF EXISTS`、非 ASCII の名前への `DESCRIBE`、S3 Tables の対照 `SELECT`）
- 返ったもの（`StartQueryExecution` の `InvalidRequestException`。実行は作られない。DDL の後始末はいずれも SUCCEEDED、ラウンド 2 の `CREATE TABLE` 2 本も開始時に弾かれて何も作られなかった）:

  **決め手 1: 引用符付きの部分を 1 つでも含む名前は開始時に弾かれる。無引用・バッククォートは通る**

  | 文 | 通った（SUCCEEDED／対象が無く FAILED） | 開始時に弾かれた |
  |---|---|---|
  | `DESCRIBE` | `t`・`db.t`・`awsdatacatalog.db.t`・`` `t` ``・`` `db`.`t` `` | `"t"`・`"T"`・`"db"."t"`・`db."t"`・`"db".t`・`"AwsDataCatalog".db.t`・`"awsdatacatalog"."db"."t"` |
  | `DESC` | `t`・`` `t` `` | `"t"`・`"db"."t"`・`db."t"`・`"db".t` |
  | `SHOW CREATE TABLE` | `DESCRIBE` と同じ 5 形 | `DESCRIBE` と同じ 7 形 |
  | `SHOW COLUMNS FROM`／`IN` | `t`・`` `t` `` | `"t"`・`"db"."t"`・`db."t"`・`"db".t`、`IN "t"` |
  | `DROP TABLE`（実在しない名前） | `nope`・`` `nope` ``（FAILED、対象なし）、`IF EXISTS nope`（SUCCEEDED） | `"nope"`・`"db"."nope"`・`db."nope"`・`"db".nope`・`IF EXISTS "nope"` |
  | `ALTER TABLE "nope" ...` | — | `ADD COLUMNS`・`SET TBLPROPERTIES`（どちらも Trino の文言。Trino も同じく弾く）、`ADD COLUMN`・`DROP COLUMN`・`RENAME TO`（Hive 系の文言） |
  | `ALTER TABLE nope ...`（無引用） | `ADD COLUMNS`・`DROP COLUMN`・`RENAME TO`・`SET TBLPROPERTIES`（FAILED、対象なし） | `ADD COLUMN`（単数）: `line 1:45: no viable alternative at input 'ALTER TABLE <nope> ADD COLUMN'`（範囲外。下の「範囲外の発見」参照） |
  | `MSCK REPAIR TABLE` | `t`（SUCCEEDED、MSCK_REPAIR。範囲外） | `"t"`（Trino の文言 `mismatched input 'MSCK'`。Trino に MSCK が無い） |
  | S3 Tables `"s3tablescatalog/<b>".<ns>.<t>` | — | DESCRIBE: `Unsupported DDL with 2 catalogs`／SHOW CREATE TABLE: `Queries of this type are not supported`／`DROP TABLE IF EXISTS "<cat>".<ns>.nope_204`: `line 1:22: mismatched input '"<cat>"' expecting {…}` |

  S3 Tables の対照 `SELECT * FROM "<cat>".<ns>.<t> LIMIT 1` は 2 ラウンドとも `SCHEMA_NOT_FOUND`（名前空間の指定の綴り違いとみられ、アカウント固有の事情）。上の 3 つの拒否は名前空間を解決する前の開始時点なので、この結論には影響しないと判断した。

  **決め手 2: 文言の規則（Trino が構文として受ける文だけ。Trino が弾く文は Trino の文言がそのまま出る＝判定の順は「構文チェック → この拒否」）**

  | 文 | 名前の最初の部分が引用符付き | 最初の部分が無引用で後ろが引用符付き（`db."t"`） |
  |---|---|---|
  | `DESCRIBE`・`DESC`・`ALTER TABLE`（Trino が受ける操作） | `line L:C: no viable alternative at input '<文の最初の語 … 最初の引用符付きの部分の終わり>'`（例 `'DESCRIBE "t"'`・`'ALTER TABLE "nope"'`） | `line L:C: no viable alternative at input '<名前の始まり … 引用符付きの部分の終わり>'`（例 `'db."t"'`。ALTER は未実測） |
  | `SHOW COLUMNS FROM`／`IN`・`DROP TABLE［IF EXISTS］` | `line L:C: mismatched input '<最初の部分>' expecting {…}`（一覧は 5 件とも同一、#200 の DROP とも同一） | 同上の no viable alternative |
  | `SHOW CREATE TABLE` | `Queries of this type are not supported`（位置なし。末尾の空白があっても同じ） | 同じ |
  | `DESCRIBE` の S3 Tables（最初の部分が別カタログ） | `Unsupported DDL with 2 catalogs`（位置なし） | — |

  位置 C は引用符付きの部分の開始位置 + 1（1 文字目が 1）。先頭の空白は数えない（`  DESCRIBE "t"` → `1:10`）、先頭のコメントは数える（`/* c */ DESCRIBE "t"` → `1:18`。input にはコメントを含めない）、改行の後は `line 2:1`（`DESCRIBE\n"t"`）。空白 2 つはそのまま数え input にも残る。小文字のキーワードも同じ規則で input は元の綴り。input の中の改行は文字どおりの `\n`（バックスラッシュと n）で出る。

  **ラウンド 2: 名前の部品数（k）と引用符付きの部分の番号（q）ごとの文言**

  | 文 | q=1（k=1〜3） | q=2（k=2・3） | q=3（k=3） |
  |---|---|---|---|
  | `DESCRIBE`・`DESC` | NV(文の最初の語 … p1 の終わり) | NV(名前の始まり … p2 の終わり)（例 `'awsdatacatalog."db"'`） | MM(p3)（例 `mismatched input '"t"' expecting {…}`） |
  | `SHOW COLUMNS FROM`／`IN`・`DROP TABLE［IF EXISTS］` | MM(p1) | NV(名前の始まり … p2 の終わり) | MM(p3) |
  | `ALTER TABLE`（Trino が受ける操作） | NV(文の最初の語 … p1 の終わり) | NV(文の最初の語 … p2 の終わり)（k=2 だけ実測。k=3 の q=2 は未実測） | NV(文の最初の語 … p3 の終わり) |
  | `SHOW CREATE TABLE` | `Queries of this type are not supported` | 同じ | 同じ |
  | `DESCRIBE`・`DESC`・`SHOW COLUMNS` の最初の部分が S3 Tables のカタログ | `Unsupported DDL with 2 catalogs`（全部引用符付き・存在しない表でも同じ） | | |
  | `DROP`・`ALTER`・`SHOW CREATE` の最初の部分が S3 Tables のカタログ | 上の一般の規則どおり（MM／NV／定数） | | |

  NV = `line L:C: no viable alternative at input '…'`、MM = `line L:C: mismatched input '…' expecting {…}`（一覧は全部同一、md5 一致）。C は対象の部分の開始位置 + 1。

  位置の追加の規則（ラウンド 2 で判明）: 先頭のタブ・LF・CRLF・連続 LF も数えない（すべて `1:10`）。行コメント `-- c\n` の後は `line 2:10`、改行入りのブロックコメントの後は `line 2:15`。列は **UTF-16 の単位**（`/* あ */` の後は 18、`/* 😀 */` の後は 19）。区切りのタブは `1:10` で input に `\t`、区切りの CRLF は `line 2:1` で input に `\r\n`（どちらもバックスラッシュ表記。ラウンド 1 の想定を覆した）。

  ほかにラウンド 2 で確定したこと:
  - `ALTER TABLE IF EXISTS` は引用符の有無によらず `line 1:16: no viable alternative at input 'ALTER TABLE IF EXISTS'`（無引用でも本物は弾く。athena-local は Trino が受けるので実行する。範囲外の差として [docs/caveats.md](../../caveats.md) に記載）
  - `DESCRIBE EXTENDED`／`FORMATTED "t"` は Trino と同じ文言（`mismatched input '"t"'. Expecting: '.', <EOF>`）で、athena-local も今すでに同じ
  - `SHOW TABLES IN "db"` は MM(p1)、`CREATE TABLE "x" (n int)` は NV(文の最初の語 … p1)。どちらも Trino は構文として受けるので、この判定を足さなければ athena-local が実行してしまうところだった（採用: 両方とも「一致条件と文言」の表に追加）。`DROP DATABASE IF EXISTS "x"` は Trino も同じ文言で弾くので、判定を足さなくても差は無い
  - `DESCRIBE "日本"`（存在しない非 ASCII の名前）は `Entity Not Found (Service: AmazonDataCatalog; … Request ID: <毎回違う>)`。構文の文言にならず、再現できない Request ID を含むので athena-local では再現しない（弾かない＝実行する）

- 備考: 範囲外（本物だけ受ける／本物だけ弾く。無引用）: 無引用の `ALTER TABLE t ADD COLUMN m int`（Trino の綴り、単数）は本物が開始時に弾く（`no viable alternative at input 'ALTER TABLE t ADD COLUMN'`）。バッククォートの名前（`` DESCRIBE `t` `` など）は本物が受けるが Trino の構文エラーで athena-local は弾く。無引用の `MSCK REPAIR TABLE t` は本物が受ける（`MSCK_REPAIR`）が Trino に構文が無く athena-local は弾く。無引用の `DROP DATABASE` は本物が受ける（`DROP_DATABASE`）が Trino には `DROP SCHEMA` しか無く athena-local は弾く。無引用の素の `CREATE TABLE x (n int)` は本物が `No location was specified for table. An S3 location must be specified` で開始時に弾くが、athena-local は Trino が作ってしまう。これら 5 つはいずれも #204 の対象（引用符付きの名前）の外なので直さず、[docs/caveats.md](../../caveats.md) に記載した。

### 引用符付きの名前と存在の確認（#207、ラウンド 3・4）
- 日付: 2026-09-25（ラウンド 3） ／ issue: #207 ／ スクリプト: `tools/measure/quoted-names.sh`（`ROUND=3`） ／ 生データ: `$HOME/athena-quoted-names-measurements/run-20260925-104713`
- 日付: 2026-09-25（ラウンド 4） ／ issue: #207 ／ スクリプト: 同上（`ROUND=4`） ／ 生データ: `$HOME/athena-quoted-names-measurements/run-20260925-111003`
- 相手: 本物の Athena（S3 Tables のカタログを含む構成）
- 投げたもの: #204 のラウンド 1・2 で未実測のまま残った形。ラウンド 3（72 本、V1〜V7）は 3 部の `ALTER TABLE` 名で 2 番目だけ引用符付き、4 部以上の名前（DESCRIBE・DROP・ALTER）、`SHOW TABLES IN`／CTAS でない `CREATE TABLE` の 2 部以上、`CREATE TABLE IF NOT EXISTS` に引用符付きの名前、DROP・ALTER・SHOW CREATE TABLE・SHOW TABLES IN・CREATE TABLE の引用符付きの部分に非 ASCII を含む形（存在する名前・存在しない名前の両方）。ラウンド 4（41 本、W1〜W5）は DESCRIBE・DESC・SHOW COLUMNS の対象の存在の確認（テーブル不在・スキーマ不在・カタログ不在・大文字の名前・ビュー・存在する非 ASCII 名）と、S3 Tables の対照 `SELECT` を通した状態での DESCRIBE・SHOW CREATE TABLE・DROP・SHOW COLUMNS の再確認
- 返ったもの:

  **4 部以上の名前（V2・W2・W3）**

  | 文 | 結果 |
  |---|---|
  | `DESCRIBE`・`DESC`・`SHOW COLUMNS FROM`／`IN` | 引用符の有無・位置によらず `Invalid table name <各部の値を . でつないだもの>`（`MALFORMED_QUERY`）。各部は無引用なら小文字、引用符付きなら中身（`""` → `"`、`"x.y"` → `x.y`）。1 部目が S3 Tables の別名（`"s3tablescatalog/<bucket>"`）でもこちらが先に決まる |
  | `DROP TABLE`（`IF EXISTS` も）・`ALTER TABLE` | 引用符付きの部分が 1〜3 部目にあれば 3 部の名前と同じ規則（DROP は `mismatched input`、ALTER は `no viable alternative`）。無引用、または引用符付きの部分が 4 部目以降だけなら、3 つ目の `.` の位置で弾かれる: DROP は `line L:C: mismatched input '.' expecting {<EOF>, 'PURGE'}`、ALTER は `line L:C: no viable alternative at input '<文の最初の語から 3 つ目の . まで>'` |
  | `SHOW CREATE TABLE`・`SHOW TABLES IN`・`CREATE TABLE` | 未実測のまま |

  **3 部の名前で 2 番目だけ引用符付き（V1）**

  `ALTER TABLE awsdatacatalog."db".nope RENAME TO x` は `no viable alternative at input 'ALTER TABLE awsdatacatalog."db"'`。3 部の一般の規則（NV(文の最初の語 … 引用符付きの部分)）と同じで、2 番目を除外していた #204 の判定は誤りだったと判明した。

  **`SHOW TABLES IN`／CTAS でない `CREATE TABLE` の 2 部以上（V3）**

  | 文 | 結果 |
  |---|---|
  | `SHOW TABLES IN "cat"."db"`・`"cat".db`・`cat."db"` | 最初の引用符付きの部分で `mismatched input`（1 部と同じ規則） |
  | `CREATE TABLE "db"."nope3" (n int)`・`db."nope3"`・`awsdatacatalog."db".nope3` | 文の最初の語から最初の引用符付きの部分まで `no viable alternative` |
  | `CREATE TABLE IF NOT EXISTS "t" (n int)` | `line 1:28: no viable alternative at input 'CREATE TABLE IF NOT EXISTS "t"'`（input は `CREATE TABLE IF NOT EXISTS` を含む文の最初から） |
  | `SHOW TABLES IN a.b."c"`（3 部） | 未実測のまま |

  **非 ASCII の名前（V5・V6）**

  `DROP TABLE "日本"`・`ALTER TABLE "日本" RENAME TO x`・`SHOW CREATE TABLE "日本"`・`SHOW TABLES IN "日本"`・`CREATE TABLE "日本" (n int)` はいずれも実在しない名前でも一般の規則どおり（構文の文言）だった。存在する非 ASCII 名（`t_日本`）への `DESCRIBE "t_日本"`・`DESCRIBE db."t_日本"`・`SHOW COLUMNS FROM "t_日本"` も同じく構文の文言（`no viable alternative`／`mismatched input`）。`DESCRIBE "日本"`（実在しない非 ASCII 名）だけは下の「存在の確認」が先に決め、`Entity Not Found` になる。**非 ASCII かどうかではなく対象の存在の有無が `Entity Not Found` と構文の文言を分けていたと判明した**（#204 のユーザーの判断 D2 が前提にしていた「非 ASCII は弾かない」を撤回。下の「覆した事前判断」を参照）。

  **DESCRIBE・DESC・SHOW COLUMNS の存在の確認（Glue、開始時。W1・W4・W5）**

  | 対象 | `StartQueryExecution` の応答 |
  |---|---|
  | テーブル不在（1〜3 部、無引用・引用符付き・非 ASCII） | `InvalidRequestException` / `INVALID_INPUT`: `Entity Not Found (Service: AmazonDataCatalog; Status Code: 400; Error Code: EntityNotFoundException; Request ID: <毎回違う UUID>; Proxy: null)` |
  | スキーマ不在 | 同上 |
  | 文脈の Database 不在（既定のスキーマを省略） | 同上 |
  | カタログ不在（名前に 3 部まで書いた形、例 `<存在しないカタログ>.<db>.t`） | `InvalidRequestException` / `DATACATALOG_NOT_FOUND`: `Catalog '<name>' does not exist` |
  | 大文字の無引用（`T`・`<DB>.T`、実在は小文字） | `SUCCEEDED`（本物は大文字でも実在のテーブルを見つける） |
  | ビュー（`DESCRIBE v`・`DESCRIBE "v"`・`SHOW COLUMNS FROM v`・`SHOW COLUMNS FROM "v"`） | すべて `SUCCEEDED`（`DESC_VIEW`）。**引用符付きの名前の構文の文言が出るのはテーブルだけ** |
  | S3 Tables（対照 `SELECT` が通る状態。W4） | DESCRIBE・DESC・SHOW COLUMNS・実在しないテーブルへの DESCRIBE はいずれも `Unsupported DDL with 2 catalogs`、SHOW CREATE TABLE は `not supported`、DROP は 1 部目で `mismatched input`、ALTER は `no viable alternative`（ラウンド 1・2 と同じ） |

  判定の順序（DESCRIBE・SHOW COLUMNS）: 構文エラー（Trino）→ 4 部以上 → S3 Tables の別名 → カタログ不在 → テーブル不在 → ビューなら実行 → テーブルで引用符付きなら構文の文言。

  **`ALTER TABLE IF EXISTS "t"`（ラウンド 2 の `u2-ifq` を読み直し）**

  無引用の `ALTER TABLE IF EXISTS t ...` と同じ文言（`line 1:16: no viable alternative at input 'ALTER TABLE IF EXISTS'`）で弾かれており、引用符の有無を問わない。#204 で「範囲外」と記載済みの差と同じなので、athena-local 側は変えていない。

- 備考: S3 Tables への対照 `SELECT * FROM "<cat>".<ns>.<t> LIMIT 1` はラウンド 1・2 とも `SCHEMA_NOT_FOUND` で失敗していた（アカウント固有の名前空間の指定の綴り違いとみられる）。ラウンド 4 では名前空間の指定を直して対照 `SELECT` を通した状態で DESCRIBE・SHOW CREATE TABLE・DROP・SHOW COLUMNS の拒否を測り直し、ラウンド 1・2 と同じ結果を確認した。athena-local はこの実測を受けて `quoted_names.rs` の一致条件を広げ（4 部以上、3 部の 2 番目、`SHOW TABLES IN`／`CREATE TABLE` の 2 部以上、`CREATE TABLE IF NOT EXISTS`）、非 ASCII の除外を撤回し、新モジュール `entity_check.rs` で DESCRIBE・SHOW COLUMNS の存在の確認を実装した（[docs/caveats.md](../../caveats.md) の「SQL dialect」に記載）。

### #207 で残った名前の形（#212、ラウンド 5）
- 日付: 2026-09-25（ラウンド 5） ／ issue: #212 ／ スクリプト: `tools/measure/quoted-names.sh`（`ROUND=5`） ／ 生データ: `$HOME/athena-quoted-names-measurements/run-20260925-122837`
- 相手: 本物の Athena（`AwsDataCatalog`。S3 Tables は使っていない）
- 投げたもの: 32 本（Y1〜Y4）。Y1 は 4 部以上の `SHOW CREATE TABLE`（実在の表）・`SHOW TABLES IN`・CTAS でない `CREATE TABLE`（実在しない表）を、無引用・2 部目だけ引用符付き・4 部目だけ引用符付き・5 部で。Y2 は `SHOW TABLES IN` の 3 部を、無引用と 1・2・3 部目だけ引用符付きで。Y3 は `QueryExecutionContext` の Catalog を実在しない `nocatalog_212`（1 本だけ `NoCatalog_212`）にした `SELECT 1`・`DESCRIBE`・`SHOW COLUMNS`。Y4 は 4 部の `DESCRIBE`・`SHOW COLUMNS` で引用符付きの部分が大文字の形
- 過去のラウンドの読み直し: ラウンド 1〜4 の生データ（4 ラウンド・計 260 行）には、今回の形の答えは無かった（`w2-mixedcase` は無引用の大文字だけ）
- 返ったもの（位置は伏せる前の実名での値。athena-local のテストでは名前を短くして数え直している）:

  | 文 | 結果（すべて `InvalidRequestException` / `MALFORMED_QUERY`。Y3 を除く） |
  |---|---|
  | `SHOW CREATE TABLE` の 4 部以上（無引用・`"db"`・`"n"`・5 部） | 引用符の有無・位置によらず `Invalid table name <各部を . でつないだもの>`（DESCRIBE と同じ） |
  | `SHOW TABLES IN awsdatacatalog.<db>.x.n`・`...x."n"`（4 部） | 2 つ目の `.` の位置で `line L:C: mismatched input '.' expecting {<EOF>, 'LIKE', STRING}` |
  | `SHOW TABLES IN awsdatacatalog."<db>".x.n`（4 部） | 2 部目で `mismatched input '"<db>"' expecting {…}`（1・2 部と同じ規則・同じ一覧） |
  | `SHOW TABLES IN awsdatacatalog.<db>.x`（3 部・無引用） | 2 つ目の `.` で `mismatched input '.' expecting {<EOF>, 'LIKE', STRING}` |
  | `SHOW TABLES IN awsdatacatalog.<db>."x"`（3 部・3 部目が引用符付き） | 2 つ目の `.` で **`extraneous input '.'`** `expecting {<EOF>, 'LIKE', STRING}`（Hive では `"x"` は文字列なので、`.` を読み飛ばせば `LIKE` の無いパターンとして読めるため） |
  | `SHOW TABLES IN "awsdatacatalog".<db>.x`・`awsdatacatalog."<db>".x`（3 部） | 最初の引用符付きの部分で `mismatched input`（1・2 部と同じ規則） |
  | `CREATE TABLE awsdatacatalog.<db>.<t>.n (n int)`・`...<t>."n"`・`...<t>.n.m` | 3 つ目の `.` の位置で `line L:C: mismatched input '.' expecting {<EOF>, '(', 'SELECT', 'FROM', 'AS', 'ROW', 'WITH', 'VALUES', 'TABLE', 'INSERT', 'MAP', 'COMMENT', 'REDUCE', 'TBLPROPERTIES', 'SKEWED', 'STORED', 'LOCATION', 'CLUSTERED', 'PARTITIONED'}` |
  | `CREATE TABLE awsdatacatalog."<db>".<t>.n (n int)` | `line 1:29: no viable alternative at input 'CREATE TABLE awsdatacatalog."<db>"'`（3 部と同じ規則） |
  | 4 部の `DESCRIBE`・`SHOW COLUMNS FROM` で引用符付きの大文字（`"<T>"`・`"AwsDataCatalog"`・`"N"`・`"<DB>"`） | `Invalid table name` の名前は**小文字**（`awsdatacatalog.<db>.<t>.n`） |
  | Y3: Context の Catalog が実在しない `SELECT 1`・`DESCRIBE t`・`DESCRIBE <db>.t`・`DESCRIBE awsdatacatalog.<db>.t`・`SHOW COLUMNS FROM t`・`<db>.t`、Catalog を `NoCatalog_212` にした `DESCRIBE t` | すべて **`SUCCEEDED`**（`DESCRIBE_TABLE`・`SHOW_COLUMNS`）。`GetQueryExecution` の `QueryExecutionContext.Catalog` は `nocatalog_212`（大文字混じりで送っても小文字） |
  | Y3: 同じ Context で `DESCRIBE <t>_nope`（実在しない表） | `INVALID_INPUT`: `Entity Not Found (...)`（既定のカタログで存在を確かめている） |
  | Y3: 同じ Context で `DESCRIBE "t"` | `line 1:10: no viable alternative at input 'DESCRIBE "t"'`（ふだんの引用符付きの規則） |

- 採用した判断:
  - #207 の表の「各部は無引用なら小文字、引用符付きなら中身」は、引用符付きの大文字を測っていなかった。今回、引用符付きも小文字になると分かったので、athena-local は各部の中身を小文字にしてつなぐ。`""` → `"`・`"x.y"` → `x.y`（W2）はこれと矛盾しない。
  - `CREATE TABLE` の 4 部以上で引用符付きの部分が 1・3 部目にある形は測っていないが、3 部の名前では 1〜3 部目のどれも測ってあり（V3）、4 部の 2 部目（Y1）が 3 部と同じ文言だったので、4 部目より前で文言が決まる（パーサが 4 部目を読む前に止まる）と判断し、3 部と同じ規則を当てる。DROP・ALTER（#207）と同じ扱い。`SHOW TABLES IN` の 1・2 部目も同じ理由で当てる。
  - Y3 は開始時に弾かれないので、athena-local の `entity_check.rs`（カタログが無いと分かっても名前にカタログを書いていなければ弾かない）は変えない。ただし athena-local はそのあと Trino に実在しないカタログで実行して FAILED になり、本物（既定のカタログで解決して SUCCEEDED）と差がある。この差は範囲外として別の issue で扱う。
- 備考: CTAS の 4 部以上、引用符付きの部分が 3 部目までに無い `CREATE TABLE IF NOT EXISTS` の 4 部以上、`SHOW TABLES IN` の 2 つ目の `.` の直後が `LIKE` やバッククォートの形は測っていない。athena-local は前の 2 つを弾かず（今までどおり実行）、後ろ 2 つは直後が `"` で始まらない形として `mismatched input` にしている（[docs/dev/unmeasured.md](../unmeasured.md)）。

### 実在しない QueryExecutionContext の Catalog と文の種類（#214）
- 日付: 2026-09-25 ／ issue: #214 ／ スクリプト: `tools/measure/context-catalog.sh` ／ 生データ: `$HOME/athena-context-catalog-measurements/run-20260925-131314`
- 相手: 本物の Athena（`AwsDataCatalog`）
- 投げたもの: 27 本。Context の Catalog を実在しない `nocatalog_214`、Database を実在の DB にして（NC）、表を読む SELECT（1・2・3 部）、実在しない表・DB の SELECT、SHOW TABLES・SHOW DATABASES・SHOW CREATE TABLE・SHOW TBLPROPERTIES・SHOW VIEWS、EXPLAIN、CTAS → INSERT → DROP、実在しない表の DROP、Database を省いた Context の DESCRIBE・SELECT、`AWSDATACATALOG` の SELECT。対照は `AwsDataCatalog` の Context
- 返ったもの:

  | 文（NC） | 結果 |
  |---|---|
  | `SHOW TABLES`・`SHOW DATABASES`・`SHOW CREATE TABLE t`・`SHOW TBLPROPERTIES t`・`SHOW VIEWS`・`DROP TABLE IF EXISTS <c>`・`DROP TABLE IF EXISTS <nope>`、Database を省いた Context の `DESCRIBE <db>.t` | `SUCCEEDED`（既定のカタログで解決。GetQueryResults の ColumnInfo の CatalogName は `hive`）。#212 Y3 の `DESCRIBE`・`SHOW COLUMNS` も同じ |
  | `SELECT * FROM t`・`<db>.t`・`<nope>`・`<nodb>.t`、Database を省いた Context の `SELECT * FROM <db>.t` | `FAILED`、ErrorCategory 2、ErrorType 1006、`CATALOG_NOT_FOUND: line 1:15: Catalog 'nocatalog_214' does not exist`（表・DB の有無より先）。`SELECT * FROM t` だけ AthenaError.ErrorMessage が空（StateChangeReason には同じ文言） |
  | `EXPLAIN SELECT * FROM t` | `FAILED`、2 / 1006、`CATALOG_NOT_FOUND: line 1:23: ...` |
  | `CREATE TABLE <c> AS SELECT 1 AS n` | `FAILED`、2 / 1300、`NOT_FOUND: Session property catalog does not exist: nocatalog_214. You may need to manually clean the data at location '<OUTPUT>tables/<uuid>' before retrying. Athena will not delete data in your account.` |
  | `SELECT * FROM awsdatacatalog.<db>.t` | `SUCCEEDED` |
  | 対照（OK）: `SELECT * FROM <nope>`／`<nodb>.t` | `TABLE_NOT_FOUND: line 1:15: Table 'awsdatacatalog.<db>.<nope>' does not exist`／`SCHEMA_NOT_FOUND: line 1:15: Schema '<nodb>' does not exist`（どちらも 1301） |
  | `AWSDATACATALOG` の `SELECT * FROM t` | `SUCCEEDED` |

  GetQueryExecution の Catalog はどれも送った名前の小文字、Database を省けばキー無し（#157・#167 と同じ）。
- 手元の Trino 482（compose）で同じ Context: `SELECT * FROM t`・`EXPLAIN`・`SHOW TABLES`・`DESCRIBE t`・CTAS はどれも `CATALOG_NOT_FOUND`（USER_ERROR）`Catalog 'nocatalog_214' not found`（位置は SELECT が 1:15、EXPLAIN が 1:23、SHOW TABLES・DESCRIBE・CTAS は 1:1、SHOW SCHEMAS は位置なし）。`SELECT 1` と `DROP TABLE IF EXISTS <nope>` は成功した。
- 採用した判断: メタデータの文（本物が成功した文のうち Trino にもあるもの）だけ、実在しない Context のカタログを `TRINO_CATALOG_MAP` の `AwsDataCatalog` の別名（無ければ `TRINO_CATALOG`）に差し替える（[decisions.md](../decisions.md)）。表を読む文は差し替えず、`CATALOG_NOT_FOUND` を ErrorType 1006 にする。文言（`not found` ↔ `does not exist`）と CTAS の 1300 は変換しない。
- 備考: `INSERT INTO <c> SELECT 2` は、前の CTAS が失敗して表が無かったため `Table <c> not found in database <db>`（1301）になり、カタログの扱いは測れていない。

### 実在しない QueryExecutionContext の Catalog と文の種類の残り（#217）
- 日付: 2026-09-26（UTC 2026-09-25 19:11）／ issue: #217 ／ スクリプト: `tools/measure/context-catalog-statements.sh` ／ 生データ: `$HOME/athena-context-catalog-measurements/run-20260925-190731`
- 相手: 本物の Athena（`AwsDataCatalog`）
- 投げたもの: 75 本。Context の Catalog を実在しない `nocatalog_217`、Database を実在の DB にして（NC）、準備した Hive 表・Hive のパーティション表・Iceberg 表・ビューに対して下の文を投げた。NC が失敗した文は同じ文を `AwsDataCatalog` の Context（OK）で対照に投げ、NC が成功した文は効果が既定のカタログに出たかを OK の読み取り（SHOW TABLES・SHOW DATABASES・DESCRIBE・SHOW PARTITIONS・SHOW TBLPROPERTIES）で裏取りした
- 返ったもの:

  | 文（NC） | SubstatementType | 結果 |
  |---|---|---|
  | `INSERT INTO t SELECT ...`・`INSERT INTO <db>.t SELECT ...`・`INSERT INTO t VALUES (...)` | `INSERT` | `FAILED`、ErrorCategory 2、ErrorType 1300、`NOT_FOUND: Session property catalog does not exist: nocatalog_217. If a data manifest file was generated at '<OUTPUT><uuid>-manifest.csv', you may need to manually clean the data from locations specified in the manifest. Athena will not delete data in your account.`。OK の対照は成功 |
  | `DELETE`・`UPDATE`・`MERGE`（Iceberg 表） | `DELETE`・`UPDATE`・`MERGE` | `FAILED`、2 / 1301、`TABLE_NOT_FOUND: line 1:1: Table 'nocatalog_217.<db>.<t>' does not exist`。OK の対照は成功 |
  | `CREATE EXTERNAL TABLE ... LOCATION ...`・`CREATE TABLE ... LOCATION ... TBLPROPERTIES ('table_type'='ICEBERG')` | `CREATE_TABLE` | `SUCCEEDED`。既定のカタログの DB に表ができた |
  | `ALTER TABLE t ADD COLUMNS (c string)`（Hive・Iceberg） | `ALTER_TABLE_ADD_COLUMN` | `SUCCEEDED`。既定のカタログの表に列が増えた |
  | `ALTER TABLE t SET TBLPROPERTIES (...)` | `ALTER_TABLE_PROPERTIES` | `SUCCEEDED`（SHOW TBLPROPERTIES に出た） |
  | `ALTER TABLE tp ADD PARTITION (...)`・`DROP PARTITION (...)`・`SHOW PARTITIONS tp`・`MSCK REPAIR TABLE tp` | `ALTER_TABLE_ADD_PARTITION`・`ALTER_TABLE_DROP_PARTITION`・`SHOW_PARTITIONS`・`MSCK_REPAIR` | `SUCCEEDED`（パーティションが増えて消えた） |
  | `CREATE VIEW v AS SELECT 1 AS n`・`CREATE VIEW v AS SELECT n FROM t`（表を参照する） | `CREATE_VIEW` | `SUCCEEDED`。既定のカタログの DB にビューができた |
  | `SHOW CREATE VIEW v` | `SHOW_CREATE_VIEW` | `SUCCEEDED`（ColumnInfo の CatalogName は `hive`） |
  | `DESCRIBE v`・`SHOW COLUMNS IN v`（ビュー） | `DESC_VIEW` | `SUCCEEDED` |
  | `DROP VIEW IF EXISTS v`（実在のビュー・NC で作ったビュー） | `DROP_VIEW` | `SUCCEEDED`。既定のカタログからビューが消えた |
  | `CREATE DATABASE IF NOT EXISTS d`・`DROP DATABASE IF EXISTS d`、`CREATE SCHEMA ...`・`DROP SCHEMA ...` | `CREATE_DATABASE`・`DROP_DATABASE` | `SUCCEEDED`。既定のカタログに DB ができて消えた |
  | `SHOW FUNCTIONS` | `SHOW_FUNCTIONS` | `SUCCEEDED` |
  | `OPTIMIZE ti REWRITE DATA USING BIN_PACK`・`VACUUM ti` | `CREATE_TABLE_AS_SELECT`・`VACUUM_TABLE` | `SUCCEEDED` |
  | `SHOW TBLPROPERTIES ti`・`SHOW CREATE TABLE ti`（Iceberg） | `SHOW_TABLE_PROPERTIES`・`SHOW_CREATE_TABLE` | `SUCCEEDED` |
  | `DROP TABLE IF EXISTS <実在の外部表>` | `DROP_TABLE` | `SUCCEEDED`。既定のカタログから表が消えた |
  | `ALTER TABLE t RENAME TO t2` | `ALTER_TABLE_RENAME` | `FAILED`、1006、`Query type not supported by DDL engine.`。OK の対照も同じなので、カタログとは関係ない |

- 手元の Trino 482（compose）で同じ Context（`X-Trino-Catalog: nocatalog_217`）: `CREATE VIEW`・`CREATE SCHEMA`・`CREATE TABLE c (n int)` は `Catalog 'nocatalog_217' not found`、`SHOW CREATE VIEW v` は `View 'nocatalog_217.<s>.v' does not exist`、`ALTER TABLE t ADD COLUMN`・`INSERT`・`DELETE`・`RENAME TO` は `Table 'nocatalog_217.<s>.t' does not exist` で失敗した。`DROP VIEW IF EXISTS v`・`DROP SCHEMA IF EXISTS s` は成功するが、既定のカタログのものは消えない。`SHOW FUNCTIONS` は成功した。Hive の書き方（`CREATE EXTERNAL TABLE`・`LOCATION` 付きの `CREATE TABLE`・`ADD COLUMNS`・`SET TBLPROPERTIES`・`ADD`／`DROP PARTITION`・`SHOW PARTITIONS`・`MSCK`・`CREATE`／`DROP DATABASE`・`OPTIMIZE`・`VACUUM`）はカタログにかかわらず構文エラー
- 採用した判断: 本物が既定のカタログで成功させ、Trino の構文でも書ける文の種類（`CREATE_TABLE`・`ALTER_TABLE_ADD_COLUMN`・`CREATE_VIEW`・`SHOW_CREATE_VIEW`・`DROP_VIEW`・`CREATE_DATABASE`・`DROP_DATABASE`）を `RESOLVED_STATEMENTS` に足した（[decisions.md](../decisions.md)）。INSERT・DELETE・UPDATE・MERGE は差し替えない。INSERT の本物の 1300 と Trino の 1301 の差は変換しない
- 備考: 裏取りの `SELECT count(*)` は、スクリプトが見出し行を値として読んだため summary では `count(*)=c` と出た（生データの 2 行目は `1`）。INSERT の 3 本は NC が失敗したので件数の裏取りはしていない

### 本物が開始時に弾く無引用の DDL（#208）
- 日付: 2026-09-26（UTC 2026-09-25 20:30）／ issue: #208 ／ スクリプト: `tools/measure/unquoted-ddl.sh` ／ 生データ: `$HOME/athena-unquoted-ddl-measurements/run-20260925-203037`
- 相手: 本物の Athena（`AwsDataCatalog`）
- 投げたもの: 61 項目（S3 Tables を Context にした C20 は `S3TABLES_*` 未設定で未測定）。`ALTER TABLE IF EXISTS` に続く操作 11 種と位置の規則（小文字・先頭コメント・改行・空白 2 つ・途中のコメント・名前の部品数）、名前の後ろの `ADD COLUMN`（単数）の位置の規則と Trino にだけある他の ALTER 7 種、CTAS でない場所の無い `CREATE TABLE` の書き方 23 種。ALTER は実在しない名前に投げ（`ADD COLUMN` の 1 本だけ実在する表）、CREATE は作られたらその場で消す作りにした（作られたものは無かった）。手元の Trino 482 の構文チェック（`PREPARE ... FROM`）に同じ形を通し、athena-local の判定まで届くかも確かめた
- 返ったもの（開始時に弾かれた 59 本はすべて `InvalidRequestException`・AthenaErrorCode `MALFORMED_QUERY`）。NV(x) は `line L:C: no viable alternative at input '<文の最初の語 … x の終わり>'` で、位置は x の先頭（先頭の空白は数えず、先頭のコメントは数える）、input は元の綴りのまま（小文字・途中のコメント・連続した空白を保ち、改行は `\n`）:

  | 文 | 本物 | Trino 482 |
  |---|---|---|
  | `ALTER TABLE IF EXISTS <名前>` + `RENAME TO`・`ADD COLUMN`（`IF NOT EXISTS` も）・`DROP COLUMN`（`IF EXISTS` も）・`RENAME COLUMN` | NV(EXISTS)。1〜3 部の名前、`alter table if exists`（input も小文字）、`/* c */` の後（1:24）、`ALTER TABLE` の後の改行（`line 2:4`、input `ALTER TABLE\nIF EXISTS`）、空白 2 つ（1:19）、`ALTER TABLE /* c */ IF EXISTS`（input にコメントを含む）で同じ規則 | 受理 |
  | `ALTER TABLE IF EXISTS <名前> ALTER COLUMN m SET DATA TYPE bigint` | `line L:C: mismatched input 'ALTER'. Expecting: '.', 'ADD', 'DROP', 'RENAME'`（位置は 2 つ目の ALTER） | 受理 |
  | `ALTER TABLE IF EXISTS <名前>` + `ADD COLUMNS (m int)` | `mismatched input 'COLUMNS'. Expecting: '.', 'ADD'` | 同じ文言の構文エラー |
  | `ALTER TABLE IF EXISTS <名前>` + `SET PROPERTIES`・`SET TBLPROPERTIES`・`EXECUTE` | `mismatched input 'SET'`（`'EXECUTE'`）`. Expecting: '.', 'ADD', 'DROP', 'RENAME'` | 構文エラー（Expecting に `'ALTER'` が入る） |
  | `ALTER TABLE <名前> ADD COLUMN m int` | NV(COLUMN)。1〜3 部の名前、実在する表、小文字、先頭のコメント、`ADD` の後の改行（`line 2:1`）、`ADD /* c */ COLUMN`、空白 2 つ、`IF NOT EXISTS`・`COMMENT 'x'`・`varchar` で同じ規則 | 受理 |
  | `ALTER TABLE <名前> RENAME COLUMN a TO b` | `line L:C: missing 'TO' at 'COLUMN'`（位置は COLUMN） | 受理 |
  | `ALTER TABLE <名前> SET PROPERTIES x = 1` | NV(PROPERTIES) | 受理 |
  | `ALTER TABLE <名前> EXECUTE optimize` | NV(EXECUTE) | 受理 |
  | `ALTER TABLE <名前> ALTER COLUMN m SET DATA TYPE bigint` | `line L:C: mismatched input 'ALTER'. Expecting: '.', 'ADD', 'DROP', 'EXECUTE', 'RENAME', 'SET'`（位置は 2 つ目の ALTER） | 受理 |
  | `ALTER TABLE <名前> DROP COLUMN IF EXISTS m` | `line L:C: mismatched input 'EXISTS' expecting {<EOF>, '.'}`（位置は EXISTS） | 受理 |
  | `ALTER TABLE <名前> SET AUTHORIZATION someone` | NV(AUTHORIZATION) | 受理 |
  | `ALTER TABLE <名前> DROP COLUMN m`（対照） | 開始でき、`FAILED`（`ParseException line 1:50 mismatched input 'COLUMN' expecting PARTITION near 'DROP' in drop partition statement`） | 受理 |
  | `CREATE TABLE <名前> (n int)` と、型を `integer`・`varchar`・`varchar(10)`・`timestamp(3)`・`double`・`decimal(10,2)`・`date`・`boolean`・`string`・`array<int>` にしたもの、列と表の `COMMENT 'x'`、`create table`、先頭のコメント、3 部の名前 | `No location was specified for table. An S3 location must be specified`（位置なし） | 受理 |
  | `CREATE TABLE <名前> (n int) WITH (...)`（`format`・`location`・`partitioned_by`・`table_type`） | NV(`WITH` の後の `(`) | 受理 |
  | `CREATE TABLE <名前> (n int NOT NULL)` | NV(NOT) | 受理 |
  | `CREATE TABLE <名前> (n row(a int))`・`(n array(int))`・`(n int, m map(varchar, int))` | NV(括弧の中の最初の語: `a`・`int`・`varchar`) | 受理 |
  | `CREATE TABLE <名前> (LIKE <db>.<t>)` | NV(`.`) | 受理 |
  | `CREATE TABLE <名前> (n int) LOCATION '...'` | `External keyword required for table type HIVE` | 構文エラー（`LOCATION`） |

- ラウンド 2（2026-09-26、UTC 21:55、`ROUND=2`、生データ `$HOME/athena-unquoted-ddl-measurements/run-20260925-215519`。48 本すべて開始時に `MALFORMED_QUERY`）: ラウンド 1 の一般化を確かめるため、型名・`LIKE`・Trino の型の中身・Trino 形の文言の綴りを測った。手元の Trino 482 は `struct<a:int,b:string>` だけを構文エラーにし、ほかはすべて受理した

  | 文 | 本物 |
  |---|---|
  | `CREATE TABLE <名前> (n <型>)`、型は `bigint`・`tinyint`・`smallint`・`real`・`float`・`char(3)`・`varbinary`・`binary`・`uuid`・`json`・`ipaddress`・存在しない `foo`・`timestamp`・`time`・`time(3)`・`decimal`・`struct<a:int,b:string>`・`map<string,int>`・`array<array<int>>`・`INT`・`varchar(10, 2)`、および複数列 `(n int, m bigint, s string)` | `No location ...`（型名は構文の段階で見ていない） |
  | 型の後ろに語が続く `timestamp(3) with time zone`・`double precision`・`interval day to second` | NV(その語: `with`・`precision`・`day`) |
  | `(LIKE <1 部の名前>)`（実在する表・しない表） | `No location ...`（`LIKE` を列の名前、名前を型として読む） |
  | `(LIKE <db>.<t> INCLUDING PROPERTIES)`・`(LIKE awsdatacatalog.<db>.<t>)`・`(n int, LIKE <db>.<t>)` | NV(最初の `.`) |
  | `row(a int, b varchar)`・`array(row(a int))`・`map(varchar, array(int))`・`ROW(a int)`・`row( a int)`・2 列目の `row(a int)` | NV(括弧の中の最初の語: `a`・`row`・`varchar`・`a`・`a`・`a`) |
  | `(n int NOT NULL, m int)` | NV(NOT) |
  | `(n int) COMMENT 'x' WITH (...)`・`CREATE TABLE IF NOT EXISTS <名前> (n int) WITH (...)`・2 部の名前 + `WITH`・`)` の後の改行 + `WITH` | NV(`WITH` の後の `(`)（改行の後は `line 2:6`） |
  | `alter table <名前> alter column ...`・`alter table if exists <名前> alter column ...` | `mismatched input 'alter'. Expecting: ...`（原文の小文字のまま。Expecting の一覧はラウンド 1 と同じ） |
  | `ALTER TABLE <db>.<名前> ALTER COLUMN ...` | 位置は 2 つ目の ALTER（2 部の名前でも同じ規則） |
  | `ALTER TABLE <名前> RENAME  COLUMN a TO b`（空白 2 つ）・`alter table <名前> rename column a to b` | `missing 'TO' at 'COLUMN'`（位置は COLUMN）・`missing 'TO' at 'column'` |
  | `alter table <名前> drop column if exists m` | `mismatched input 'exists' expecting {<EOF>, '.'}` |
  | `/* c */ ALTER TABLE <名前> SET PROPERTIES x = 1` | NV(PROPERTIES)（位置は先頭のコメントを数え、input は含めない） |

- 採用した判断: Trino 482 が受理する形のうち、上の 2 つの表で文言が決まったものを athena-local も開始時に同じ文言で弾く（[decisions.md](../decisions.md)）。CREATE TABLE は「列の名前 → 型（識別子。後ろに数字だけの括弧か `<...>`）→ `COMMENT` か `,` か `)`」を Hive の読み方として一般化し、型の後ろの語は NV(その語)、`.` は NV(`.`)、`型名(` の中の最初の語は NV(その語) で弾く（`LIKE` はこの規則に含まれる）。Trino が構文エラーにする形は今までどおり Trino の文言を返す
- 備考: 既知の実測（`ALTER TABLE IF EXISTS <t> RENAME TO <t2>` の `line 1:16`、`ALTER TABLE IF EXISTS <db>.<t> ADD COLUMNS` の Trino 形、`ALTER TABLE <t> ADD COLUMN` の NV(COLUMN)、場所の無い `CREATE TABLE` の `No location`）と食い違いは無かった

### #208 で残った CREATE TABLE の形（#221）
- 日付: 2026-09-26（UTC 2026-09-25 23:36）／ issue: #221 ／ スクリプト: `tools/measure/unquoted-ddl.sh`（`ROUND=3`）／ 生データ: `$HOME/athena-unquoted-ddl-measurements/run-20260925-233600`
- 相手: 本物の Athena（`AwsDataCatalog` と、S3 Tables のカタログ `s3tablescatalog/<bucket>`）
- 投げたもの: 29 項目。H 群（Context を `Catalog=s3tablescatalog/<bucket>,Database=<ns>` にした CTAS でない `CREATE TABLE` 9 本と疎通の `SELECT 1`、対照として既定の Context の同じ文 1 本）、Q 群（列名・型名が引用符付きの `CREATE TABLE` 8 本と対照 1 本）、P 群（4 部以上の `CREATE TABLE IF NOT EXISTS` と CTAS 8 本と対照 1 本）。作られた表はその場で消した（後始末の残りは無い）。手元の Trino（compose の trino）の構文チェックにも同じ形を通した
- 返ったもの（開始時に弾かれたものはすべて `InvalidRequestException`・AthenaErrorCode `MALFORMED_QUERY`。NV の書き方は上の #208 と同じ）:

  | 文 | 本物 | 手元の Trino |
  |---|---|---|
  | S3 Tables の Context で `CREATE TABLE <t> (n int)`・`IF NOT EXISTS`・`TBLPROPERTIES ('table_type' = 'iceberg')`・`<ns>.<t>`・`(n string)` | 開始でき、`SUCCEEDED`（DDL / CREATE_TABLE）。表が作られた | — |
  | S3 Tables の Context で `(n int NOT NULL)`・`(n int) WITH (format = 'PARQUET')` | NV(NOT)・NV(`WITH` の後の `(`)（既定の Context と同じ） | — |
  | S3 Tables の Context で `CREATE TABLE awsdatacatalog.<db>.<t> (n int)` | `Unsupported ddl with 2 catalogs: CREATE TABLE awsdatacatalog.<db>.<t> (n int)`（`ddl` は小文字、後ろに文が付く） | — |
  | 既定の Context で `CREATE TABLE <t> (n int)`（対照 2 本） | `No location ...` | 受理 |
  | `CREATE TABLE <t> ("n" int)`・`("n" int NOT NULL)`・`IF NOT EXISTS <t> ("n" int)` | NV(`"n"`)（input は `"n"` の終わりまで） | 受理 |
  | `CREATE TABLE <t> (n int, "m" int)` | NV(`"m"`) | 受理 |
  | `CREATE TABLE <t> (n row("f" int))` | NV(`"f"`) | 受理 |
  | `CREATE TABLE <t> (n "int")` | NV(`"int"`) | 受理 |
  | ``CREATE TABLE <t> (`n` int)`` | `No location ...` | 構文エラー（バッククォート） |
  | `CREATE TABLE <t> (n struct<"f":int>)` | `line 1:54: mismatched input '<'. Expecting: ')', ','`（Trino 形） | 同じ文言の構文エラー |
  | `CREATE TABLE awsdatacatalog.<db>.<t>.n (n int)`（対照。#212 と同じ） | 3 つ目の `.` で `mismatched input '.' expecting {<EOF>, '(', 'SELECT', …}` | 受理（実行時に `Too many dots in table name`） |
  | `CREATE TABLE IF NOT EXISTS` + `awsdatacatalog.<db>.<t>.n`・`x.y.<t>.n`・`awsdatacatalog.<db>.<t>.n.m`・`awsdatacatalog.<db>.<t>."n"` | 対照と同じ（3 つ目の `.`、同じ一覧） | 受理（実行時に `Too many dots in table name`） |
  | CTAS `CREATE TABLE awsdatacatalog.<db>.<t>.n AS SELECT 1 AS n`・`IF NOT EXISTS` 付き・`WITH (format = 'PARQUET')` 付き | `Invalid table name awsdatacatalog.<db>.<t>.n`（位置なし） | 受理（実行時に `Too many dots in table name`） |
  | `CREATE TABLE IF NOT EXISTS <t> (n int)`（対照） | `No location ...` | 受理 |

- 採用した判断: S3 Tables の Context（`s3tablescatalog/` で始まる Catalog）では No location だけを返さず、NV は既定の Context と同じに弾く。引用符付きの列名・型名・型名の括弧の中の最初の語は NV(その語) で弾く。`IF NOT EXISTS` の 4 部以上は `IF NOT EXISTS` の無い形と同じ規則で弾き、4 部以上の無引用の CTAS は `Invalid table name` で弾く（名前は DESCRIBE の規則に合わせて小文字でつなぐ。測ったのは小文字の名前だけ）。別カタログの名前の `Unsupported ddl with 2 catalogs` は周辺が未実測なので #224 に分けた。`struct<"f":int>` は手元の Trino が同じ文言で先に弾くので手を入れない。バッククォートの列名は Trino の構文チェックが先に弾く既知の差（#204）のまま
- 備考: #208・#212 の実測（場所の無い形の `No location`、4 部の CTAS でない `CREATE TABLE` の 3 つ目の `.`）と食い違いは無かった

### S3 Tables の Context で別カタログの名前の CREATE TABLE（#224）
- 日付: 2026-09-26（UTC 2026-09-26 00:40）／ issue: #224 ／ スクリプト: `tools/measure/unquoted-ddl.sh`（`ROUND=4`）／ 生データ: `$HOME/athena-unquoted-ddl-measurements/run-20260926-004013`
- 相手: 本物の Athena（`AwsDataCatalog` と、S3 Tables のカタログ `s3tablescatalog/<bucket>`）
- 投げたもの: 23 項目（疎通の `SELECT 1` と `CREATE TABLE` 22 本）。Context はとくに書かない限り `Catalog=s3tablescatalog/<bucket>,Database=<ns>`。作られた表（i12 の CTAS だけ）はその場で消した（後始末の残りは無い）
- 返ったもの（開始時に弾かれたものはすべて `InvalidRequestException`。AthenaErrorCode は書いたもの以外 `MALFORMED_QUERY`）:

  | 文 | 本物 |
  |---|---|
  | `CREATE TABLE awsdatacatalog.<db>.<t> (n int)`（i1。#221 の h8 の再現）・`create table ...`（i5）・`CREATE TABLE IF NOT EXISTS awsdatacatalog...`（i11） | `Unsupported ddl with 2 catalogs: <文>`（文は投げたとおり） |
  | `/* c */ CREATE TABLE awsdatacatalog...`（i6）・`-- c` の行の後に文（i7）・名前の後で改行した複数行（i8） | 同じ。コメントと改行は文言の後ろにそのまま残る |
  | `  CREATE  TABLE<TAB>awsdatacatalog... (n int)  `（i9。前後に空白 2 つ） | 同じ。前後の空白は落ち、中の空白 2 つとタブは残る |
  | `CREATE TABLE awsdatacatalog.<db>.<t> (n int); -- c`（i10） | `Only one sql statement is allowed. Got: <文>`（#228） |
  | `(n int NOT NULL)`（i13）・`("n" int)`（i16）・`(n int) WITH (format = 'PARQUET')`（i21） | NV(NOT)・NV(`"n"`)・NV(`WITH` の後の `(`)。2 catalogs より先 |
  | `... (n int) LOCATION 's3://...'`（i14）・`CREATE EXTERNAL TABLE ... LOCATION ...`（i15） | `Table location can not be specified for tables hosted in S3 table buckets`（#229） |
  | `CREATE TABLE AwsDataCatalog.<db>.<t> (n int)`（i4。大文字混じり） | 開始でき、FAILED（ErrorCategory 2・ErrorType 1100、`Cannot find or access the specified table`）（#227） |
  | `CREATE TABLE nosuchcatalog224.<db>.<t> (n int)`（i3） | `DATACATALOG_NOT_FOUND`、`Catalog 'nosuchcatalog224' does not exist`（#227） |
  | `CREATE TABLE <db>.<t> (n int)`（i2。2 部で 1 部目が AwsDataCatalog の DB） | 開始でき、FAILED（i4 と同じ文言） |
  | `CREATE TABLE awsdatacatalog.<db>.<t> AS SELECT 1 AS n`（i12。CTAS） | 開始でき、SUCCEEDED（DDL / CREATE_TABLE_AS_SELECT） |
  | `CREATE TABLE "awsdatacatalog".<db>.<t> (n int)`（i17）・`CREATE TABLE "<S3 Tables のカタログ>".<ns>.<t> (n int)`（i19、既定の Context の i20 も） | `line 1:14: no viable alternative at input 'CREATE TABLE "<1 部目>"'`（既定の Context の引用符付きの名前と同じ） |
  | 既定の Context で `CREATE TABLE awsdatacatalog.<db>.<t> (n int)`（i18）・`IF NOT EXISTS` 付き（i22） | `No location ...` |

- 採用した判断: S3 Tables の Context で、無引用の 3 部の名前の 1 部目がちょうど小文字の `awsdatacatalog` で、列の並びの判定が No location になるときだけ、`Unsupported ddl with 2 catalogs: <前後の空白（空白・タブ・改行）を落とした文>` で弾く。NV は今までどおり先に返す。大文字混じりの `AwsDataCatalog` と実在しないカタログは No location のまま据え置き（人間の判断。#227）。末尾の `;` と LOCATION は Trino の構文チェックが先に弾く形で、#228・#229 に分けた
- 備考: #221 の h8 と食い違いは無かった。前後の空白を落とす文字の範囲は、測ったのが空白だけなので、athena-local は先頭の判定と同じ空白・タブ・CR・LF にした

### S3 Tables の Context と既定の Context で、カタログ名の大文字小文字と実在しないカタログの CREATE TABLE（#227）
- 日付: 2026-09-26（UTC 2026-09-26 01:25）／ issue: #227 ／ スクリプト: `tools/measure/unquoted-ddl.sh`（`ROUND=5`）／ 生データ: `$HOME/athena-unquoted-ddl-measurements/run-20260926-012516`（#224 の `run-20260926-004013` の i2〜i4 と合わせて読む）
- 相手: 本物の Athena（`AwsDataCatalog` と、S3 Tables のカタログ `s3tablescatalog/<bucket>`）
- 投げたもの: 17 項目（S3 Tables の Context の疎通 `SELECT 1` と `CREATE TABLE` 13 本、既定の Context の `CREATE TABLE` 3 本）。FAILED の項目は結果ファイルの本体と `.metadata` の有無も取得した。作られた表（j1・j4・j11）はその場で消した（後始末の残りは無い）
- 返ったもの（開始時に弾かれたものは `InvalidRequestException`）:

  | 文（Context は書いたもの以外 `Catalog=s3tablescatalog/<bucket>,Database=<ns>`） | 本物 |
  |---|---|
  | `CREATE TABLE AwsDataCatalog.<ns>.<t> (n int)`（j1）・`AWSDATACATALOG.<ns>.<t>`（j4）・対照の 2 部 `<ns>.<t>`（j11） | 開始でき、SUCCEEDED（DDL / CREATE_TABLE）。S3 Tables の名前空間 `<ns>` に作られた（1 部目は無視される） |
  | `CREATE TABLE AwsDataCatalog.<db>.<t> (n int)`（j2。i4 の再現）・`AWSDATACATALOG.<db>.<t>`（j3）・`IF NOT EXISTS AwsDataCatalog.<db>.<t>`（j9）・2 部の `<db>.<t>`（j12。i2 の再現） | 開始でき、FAILED（StateChangeReason・ErrorMessage `Cannot find or access the specified table`、ErrorCategory 2・ErrorType 1100・Retryable false、DDL / CREATE_TABLE）。結果ファイルの本体も `.metadata` も無かった（どちらも 404） |
  | `CREATE TABLE nosuchcatalog227.<ns>.<t> (n int)`（j5）・`NoSuchCatalog227.<db>.<t>`（j6）・`IF NOT EXISTS nosuchcatalog227.<db>.<t>`（j10） | `DATACATALOG_NOT_FOUND`、`Catalog '<書いたとおり>' does not exist`（j6 は `NoSuchCatalog227` のまま） |
  | `CREATE TABLE nosuchcatalog227.<db>.<t> (n int NOT NULL)`（j7）・`AwsDataCatalog.<db>.<t> (n int NOT NULL)`（j8） | NV(NOT)（`MALFORMED_QUERY`。カタログの判定より先） |
  | `CREATE TABLE AwsDataCatalog.<ns>.<t> AS SELECT 1 AS n`（j13。CTAS） | 開始でき、FAILED（2/1301、`Database <ns> not found. Please check your query. You may need to manually clean the data at location '<OUTPUT>tables/<id>' before retrying. Athena will not delete data in your account.`）。`.metadata` だけ 81 バイト置かれた（#232） |
  | 既定の Context で `CREATE TABLE nosuchcatalog227.<db>.<t> (n int)`（j14） | `DATACATALOG_NOT_FOUND`、`Catalog 'nosuchcatalog227' does not exist` |
  | 既定の Context で `CREATE TABLE AwsDataCatalog.<db>.<t> (n int)`（j15）・`AWSDATACATALOG.<db>.<t>`（j16） | `No location ...` |

- 採用した判断: 無引用の 3 部の名前で No location になる形は、1 部目のカタログが無ければ Context によらず `DATACATALOG_NOT_FOUND`（実在は `DESCRIBE` と同じく Trino に問い合わせ、`awsdatacatalog` は大文字小文字によらず実在）。S3 Tables の Context で 1 部目が小文字ちょうどでない `awsdatacatalog` なら、2 部目の名前空間が無ければ Trino に送らずに本物と同じ FAILED（ファイルも置かない）、あれば No location のまま（本物は作るが、SQL の書き換えが要る。ユーザーの判断）。2 部の `<db>.<t>` は #231、CTAS は #232
- 備考: #224 の i2・i4 と食い違いは無かった。仮説（大文字混じりの 1 部目は無視され、2 部目が S3 Tables の名前空間として引かれる）は j1・j4 と j2・j3 の対で確かめた

