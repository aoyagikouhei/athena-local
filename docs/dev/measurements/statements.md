# 文の種類

`StatementType`／`SubstatementType` の判定（先頭のコメント、キーワードの間のコメント、個別の文）、本物だけが実行時に弾く形、`EXPLAIN` の行の分け方と変種、`CREATE OR REPLACE TABLE ... AS`。書き方は [README.md](README.md)。

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
