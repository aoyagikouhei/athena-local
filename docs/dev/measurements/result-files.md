# 結果ファイル

`OutputLocation` に置かれる結果ファイル（本体）の名前・中身・Content-Type と、失敗・取り消しのときの置かれ方。`.metadata` の中身は [metadata.md](metadata.md)、`EXPLAIN` の行の分け方は [statements.md](statements.md)。書き方は [README.md](README.md)。

対応する利用者向けの章: [docs/result-files.md](../../result-files.md)、[docs/ddl.md](../../ddl.md)、[docs/caveats.md](../../caveats.md)。

## `<id>.txt` の中身（SHOW・DESCRIBE・DDL）

### `.txt` の中身と置かれ方（1 回目）
- 日付: 2026-09-16 ／ issue: #1 ／ スクリプト: `tools/measure/txt-result.sh`（旧 `1-measure-txt.sh`。ノートの表記は `.claude/issue-notes/1-measure-txt.sh`） ／ 生データ: `$HOME/athena-txt-measurements`
- 相手: 本物の Athena
- 投げたもの: `SHOW TABLES`、`SHOW DATABASES`、`SHOW COLUMNS`、`DESCRIBE`、`SHOW CREATE TABLE`、`SHOW PARTITIONS`、`SHOW TBLPROPERTIES`、`EXPLAIN`、`CREATE DATABASE`、`DROP DATABASE`、失敗するクエリ。文ごとに GetQueryExecution、GetQueryResults、`.txt` のバイト列、`.metadata` の有無を保存
- 返ったもの:
  - **`SHOW` が成功したとき**: `.txt` には結果の行だけが入る。行は `\n` で区切られ、**末尾に改行は付かない**。列名の行は入らない。GetQueryResults が返す行と一致した（1 列の例で確認）。
  - **`EXPLAIN`**: `.txt` には計画の本文が入る。`OutputLocation` の拡張子は `.txt` で、`.csv` ではなかった。GetQueryResults の列名は `Query Plan` の 1 列で、`UpdateCount` は返らない。本文の末尾は改行 2 つだった。これは本文そのものの形。
  - **件数の無い DDL**（`CREATE DATABASE`、`DROP DATABASE`）: **0 バイトのファイルが置かれる**。GetQueryResults は列も行も返さず、`UpdateCount` も返らない。
  - **失敗したクエリ**: `SUCCEEDED` でなくても `.txt` は置かれ、中身は `FAILED: ` に続けて `StateChangeReason` と同じ文言が入る。末尾に改行は付かない。
  - **`.txt.metadata`**: 成功した `SHOW` と `EXPLAIN` には置かれた。0 バイトの DDL と、失敗したクエリには置かれなかった。中身は未解析。
- 備考: 1 回目は指定されたデータベースが実在せず、複数列になる文がすべて失敗した。複数列の区切り、NULL・エスケープ、`SHOW COLUMNS` など、テーブルの DDL はこの回では測れていない（4 回目で埋まった）。3 回目では「`SHOW TABLES`、`SHOW DATABASES`、`EXPLAIN` は `.txt` と `.txt.metadata` の両方が置かれ、`CREATE DATABASE` と `DROP DATABASE` は 0 バイトの `.txt` だけで `.metadata` は無い。中身は未取得」まで再現した。

### `.txt` の中身と置かれ方（4 回目。これで揃った）
- 日付: 2026-09-16 ／ issue: #1 ／ スクリプト: `tools/measure/txt-result.sh`（旧 `1-measure-txt.sh`） ／ 生データ: `$HOME/athena-txt-measurements/run-20260916-090202`
- 相手: 本物の Athena
- 投げたもの: 1 回目と同じ文の一覧（実在するデータベース・テーブルで）
- 返ったもの:
  - **中身の作り方**。すべての文で、`.txt` は `GetQueryResults` が返す行を `\n` で連結したものと**バイト単位で一致した**。余分な改行は足されていない。
    - 列名の行は入らない。`SELECT` の CSV と違って先頭に見出しは無い。
    - 末尾に改行は付かない。`EXPLAIN` だけ末尾が改行だが、これは本文そのものが改行で終わるため。連結の規則としては同じ。
    - 列が無い文、つまり `CREATE DATABASE` と `DROP DATABASE` は 0 バイトのファイルになる。
    - **複数列の文でも、`GetQueryResults` の 1 行の Datum は 1 個だった。** `DESCRIBE` は `ColumnInfo` が 3 列、`SHOW TBLPROPERTIES` は 2 列だが、行の中身はタブで連結され、Hive 由来の固定幅の空白詰めが入った 1 つの文字列だった。つまり Athena 側が結合済みの文字列を返している。
    - `EXPLAIN` の `OutputLocation` は `.txt` だった（`ResultFile::of` の現状と一致）。
  - 測った文と結果（すべて成功）:

    | 文 | 行数 | バイト数 | 付随ファイル |
    | --- | --- | --- | --- |
    | SHOW TABLES | 13 | 228 | 312 |
    | SHOW COLUMNS | 8 | 167 | 312 |
    | DESCRIBE | 15 | 795 | 152 |
    | SHOW TBLPROPERTIES | 4 | 90 | 460 |
    | SHOW CREATE TABLE | 22 | 692 | 88 |
    | SHOW PARTITIONS | 66 | 9899 | 312 |
    | SHOW DATABASES | 5 | 93 | 312 |
    | EXPLAIN | 15 | 393 | 79 |
    | CREATE DATABASE | 0 | 0 | 無し |
    | DROP DATABASE | 0 | 0 | 無し |

  - **`.txt.metadata`**。成功した文には置かれ、0 バイトの DDL には置かれない。中身は列情報を持つバイナリで、先頭にクエリ ID、続けてカタログ名と列名と型が入る。解析はしていない。
- 備考: 「付随ファイル」列は `.txt.metadata` のバイト数と読める（ノートに列の定義は無い。「`.txt.metadata` は 0 バイトの DDL には置かれない」と「無し」の行が一致するので、そう判断した）。athena-local は Trino の列が分かれて返り固定幅の空白詰めも入らないので、バイト単位の一致はできない。ユーザー判断でタブ連結にした（設計判断を参照）。

### `.txt` の値に入ったタブ・改行と、コメントの無い列の書き方
- 日付: 2026-09-24（3 回目。2 回目は CREATE が失敗した。備考） ／ issue: #146（バッチは #113） ／ スクリプト: `tools/measure/unmeasured-batch/run.sh`（項目 `r2`。3 回目は `RUN_DIR=run-20260924-004554 ONLY=r2,m5` で同じ run に追記） ／ 生データ: `$HOME/athena-unmeasured-batch-measurements/run-20260924-004554/r2/`
- 相手: 本物の Athena（engine version 3、workgroup `primary`、Catalog `AwsDataCatalog`、Database `<DB>`）
- 投げたもの（`<TAB>`・`<LF>` は文字列リテラルの中に生のタブ・改行を入れたもの）:
  - `CREATE EXTERNAL TABLE <DB>.athena_local_probe_113_r2 (n int COMMENT 'a<TAB>b', m int) LOCATION '<OUTPUT>tables-probe-113-r2/' TBLPROPERTIES ('note'='xa<TAB>b<LF>cy')`（列 `m` はコメント無し）
  - `DESCRIBE <DB>.athena_local_probe_113_r2`
  - `SHOW TBLPROPERTIES <DB>.athena_local_probe_113_r2`
- 返ったもの:

  | 文 | State | StatementType / SubstatementType | 本体 | `.metadata` | Content-Type（本体 / `.metadata`） | `GetQueryResults` |
  | --- | --- | --- | --- | --- | --- | --- |
  | CREATE | SUCCEEDED | DDL / CREATE_TABLE | `<id>.txt` 0B | 無し | binary/octet-stream / - | 列も行も無し、`UpdateCount` 無し |
  | DESCRIBE | SUCCEEDED | UTILITY / DESCRIBE_TABLE | `<id>.txt` 106B | 152B（素の protobuf。field 1 は QueryExecutionId、列は `col_name`・`data_type`・`comment` の 3 つで、どれも `string`・field 9 = 3 だけ） | application/octet-stream / application/octet-stream | 2 行（1 行 1 Datum）、`UpdateCount` 無し |
  | SHOW TBLPROPERTIES | SUCCEEDED | UTILITY / SHOW_TABLE_PROPERTIES | `<id>.txt` 59B | 460B（base64 の不透明な形式。戻すと 345B、先頭 9 バイトは `01 23 a1 d9 80 50 19 8b 77`） | binary/octet-stream / binary/octet-stream | 4 行、`UpdateCount` 0 |

  - DESCRIBE の本体（`od -c`）: `n` + 空白 19 個 + `\t` + `int` + 空白 17 個 + `\t` + `a` + `\n` + `m` + 空白 19 個 + `\t` + `int` + 空白 17 個 + `\t` + 空白 20 個。末尾に改行は無い
    - コメント `a<TAB>b` の列は `a` で行が終わる。タブの後ろの `b` は本体にも `GetQueryResults` の行にも無い。`a` の後ろに空白の詰め物も無い
    - コメントの無い列 `m` の comment 欄は空白 20 個（他の欄と同じ固定幅の詰め物）。`NULL` の文字列も空文字も出ない
  - SHOW TBLPROPERTIES の本体（`od -c`）: `EXTERNAL\tTRUE\ntransient_lastDdlTime\t<10 桁>\nnote\txa\tb\ncy`。値の中のタブと改行はそのまま（エスケープ無し）。末尾に改行は無い
    - `GetQueryResults` の 4 行は `EXTERNAL\tTRUE`、`transient_lastDdlTime\t<10 桁>`、`note\txa\tb`、`cy`。値の中の改行で行が分かれ、`cy` が 1 行になる（本体を `\n` で分けたものと同じ）
- 備考: 2 回目（2026-09-24 09:47 JST、同じ run）は列コメントを `a<TAB>b<LF>c` にしていて、CREATE が FAILED（ErrorCategory 1 / ErrorType 1502、`<id>.txt` 481B application/octet-stream、`.metadata` 無し）。続く DESCRIBE は `StartQueryExecution` が `Entity Not Found (Service: AmazonDataCatalog; Status Code: 400; Error Code: EntityNotFoundException; ...)`、SHOW TBLPROPERTIES は FAILED（ErrorCategory 2 / ErrorType 1301、`<id>.txt` 95B）。理由は Glue の `ValidationException` で、列コメントの制約 `[\u0020-\uD7FF\uE000-\uFFFD\uD800\uDC00-\uDBFF\uDFFF\t]*`（エラー本文のまま）に改行が無い（issue #146 のノートの「実測の経緯」による）。2 回目の `r2-create.*` は 3 回目の同じラベルのファイルで上書きされ、全文は生データに残っていない（上の数値は 2 回目の `summary.txt` から）。そのため列コメントの改行は測れず、改行は TBLPROPERTIES の値で測った

## 文ごとの置かれ方の一覧

### 結果ファイルと `.metadata` の置かれ方・Content-Type
- 日付: 2026-09-17 ／ issue: #5 ／ スクリプト: `tools/measure/result-metadata.sh`（旧 `5-measure-metadata.sh`） ／ 生データ: `$HOME/athena-metadata-measurements/run-20260917-175312`
- 相手: 本物の Athena
- 投げたもの: 下表の文。本体と `.metadata` を head-object / 取得
- 返ったもの:

  | 文 | 本体 | `.metadata` | 本体の Content-Type | `.metadata` の Content-Type |
  | --- | --- | --- | --- | --- |
  | SELECT（型網羅 22 列） | `.csv` 301B | 710B | application/octet-stream | application/octet-stream |
  | SELECT（7 列） | `.csv` 100B | 244B | application/octet-stream | 同 |
  | SELECT * FROM 実テーブル LIMIT 1 | `.csv` 421B | 451B | 同 | 同 |
  | `SELECT 1 AS i WHERE false`（0 行） | `.csv` 4B（`"i"\n`） | 60B | 同 | 同 |
  | `SELECT 1`（列名なし） | `.csv` 12B | 81B | **binary/octet-stream** | **binary/octet-stream** |
  | 失敗した SELECT | 無し | 無し | - | - |
  | SHOW TABLES | `.txt` 228B | 312B（base64 の暗号化系） | binary/octet-stream | binary/octet-stream |
  | DESCRIBE | `.txt` 795B | 152B | application/octet-stream | application/octet-stream |
  | CTAS（Iceberg） | **無し**（OutputLocation は `<prefix><id>`。`tables/` は付かなかった） | `<id>.metadata` 81B | - | application/octet-stream |
  | INSERT | 無し（OutputLocation は `<prefix><id>`） | `<id>.metadata` 75B | - | application/octet-stream |
  | UPDATE | 無し（OutputLocation は `<id>.csv`） | `<id>.csv.metadata` 75B | - | application/octet-stream |
  | DELETE | 無し | `<id>.csv.metadata` 75B | - | application/octet-stream |
  | DROP TABLE | `.txt` 1B | 41B | application/octet-stream | application/octet-stream |

  - 型網羅 SELECT の `.csv` 本体は athena-local の `to_csv` の実測（2026-09-14）と同じ形だった。
- 備考: **CTAS（Iceberg）の OutputLocation が `<prefix><id>`（`tables/` 無し）という行は、後の実測（#26、2026-09-19）で覆った**。CLAUDE.md の現在の記述は「CTAS は本物と同じくテーブルの形式によらず `tables/<id>`。2026-09-19 実測」。当時は #12 として起票し、athena-local は `tables/<id>.metadata` のまま固定した。`.csv` 本体の Content-Type が `application/octet-stream` だったこと（6 件中 5 件）は、athena-local が 0.3.0 から使っていた未実測の `text/csv` を覆した（判断 5）。DROP TABLE の本体 1B と `.metadata` 41B は #1 の実測と一致。テーブルの形式（DROP TABLE の対象）はノートに書かれていない。

## INSERT・UPDATE・DELETE・MERGE の結果ファイルとマニフェスト

### INSERT とその対照の結果ファイル（OutputLocation・本体・.metadata・マニフェスト）
- 日付: 2026-09-20 ／ issue: #35 ／ スクリプト: `tools/measure/insert-location.sh`（旧 `35-measure-insert-location.sh`） ／ 生データ: `~/athena-insert-measurements/run-20260920-182735/`（#41 のノートが参照しているパス。#35 本文には無い）
- 相手: 本物の Athena（engine version 3）
- 投げたもの: 下表の 11 項目（1 ラウンド、全項目測れた）。`table_format` は `SHOW CREATE TABLE` による裏取り
- 返ったもの:

| | 文 | table_format | 本物の OutputLocation | 本体 | `.metadata` | マニフェスト |
|---|---|---|---|---|---|---|
| a | `INSERT INTO <hive> VALUES` | hive | **`<id>`** | 無し | 75B | **`<id>-manifest.csv` 155B** |
| b | `INSERT INTO <iceberg> VALUES` | iceberg | **`<id>`** | 無し | 75B | 無し |
| c | 0 行の `INSERT`（更新件数 0） | hive | **`<id>`** | 無し | 75B | 無し |
| d | 型が合わない `INSERT`（FAILED） | hive | `<id>` | 無し | 無し | 無し |
| e | `UPDATE <iceberg>` | iceberg | `<id>.csv` | 無し | 75B | 無し |
| f | `DELETE FROM <iceberg>` | iceberg | `<id>.csv` | 無し | 75B | 無し |
| g | `MERGE INTO <iceberg>` | iceberg | `<id>.csv` | 無し | 74B | 無し |
| h | `SELECT 1 AS n`（対照） | - | `<id>.csv` | 8B | 73B | 無し |
| i | CTAS（対照） | hive | `tables/<id>` | 無し | 81B | `tables/<id>-manifest.csv` |
| prep-i | Iceberg の CTAS（対照） | iceberg | `tables/<id>` | 無し | 81B | 無し |
| probe | `SHOW TABLES`（対照） | - | `<id>.txt` | 228B | 312B | 無し |

  - INSERT はテーブルの形式でも更新件数でも `<id>` のまま。対照（SELECT・CTAS・SHOW）も README に書いた値どおり
  - マニフェストが置かれるのは Hive のテーブルに行を書いた文だけ。Iceberg の INSERT・UPDATE / DELETE / MERGE・0 行の INSERT・失敗した INSERT には置かれない。失敗した INSERT の `StateChangeReason` はマニフェストのパスに言及するが、そのキーは実在しなかった
  - MERGE の `<id>.csv` を初めて実測した（それまでは UPDATE / DELETE からの類推）
  - 失敗した INSERT が本体も `.metadata` も置かないことを、2026-09-17 に続いて再確認
  - `SELECT 1 AS n` の本体と `.metadata` は `binary/octet-stream`（5.md の「`SELECT 1` だけ binary 系」という観測に `AS` 付きも含まれる）
- 備考: 2026-09-17 の 1 ラウンドで採られた値のうち、CTAS は #26 で覆ったが INSERT は覆らなかった（ノートの記述）。MERGE の 74B と UPDATE/DELETE の 75B の 1 バイト差は #41 で field 2 の文字列長の違いと判明。Iceberg × 0 行の INSERT は #91（2026-09-23）で実測し、Hive の c と同じ（`<id>`、本体無し、`.metadata` 75 バイトで更新件数 `18 00`、マニフェスト無し）。Hive × 1 行のマニフェストは #91 で再現。`SELECT 1 AS n` が binary なのは #70 の規則（リテラルだけの SELECT は binary）で説明される

### INSERT の結果ファイル（Iceberg / Hive × 0 行 / 1 行）
- 日付: 2026-09-23（12:14〜12:17、ユーザーが実行） ／ issue: #91 ／ スクリプト: `tools/measure/iceberg-zero-row-insert.sh`（旧 `91-measure-iceberg-zero-insert.sh`） ／ 生データ: `run-20260923-121426`
- 相手: 本物の Athena（1 ラウンド、StartQueryExecution 11 回）
- 投げたもの: a Iceberg × 0 行、b Iceberg × 1 行、c Hive × 0 行（対照）、d Hive × 1 行
- 返ったもの:
  - 争点 a（Iceberg × 0 行）は `<id>`・本体無し・`.metadata` 75 バイト（`INSERT` と `18 00`）・マニフェスト無しで、対照 c（Hive × 0 行）と先頭のクエリ ID 以外一致
  - b（Iceberg × 1 行）と d（Hive × 1 行）は `18 01`。d だけ `<id>-manifest.csv` が付く（#35 の再現）
- 備考: 2026-09-20 の c の生データ（#35）を読み直して Hive × 0 行の `18 00` も確認（当時はバイト数しか見ていなかった）。結果は推定どおりでコード変更なし

**同じ話題の実測の並び: INSERT の OutputLocation**

- 2026-09-17（#5、上の「文ごとの置かれ方の一覧」）: `<prefix><id>`
- 2026-09-18（#17、[statements.md](statements.md) の「先頭コメント付きの文ごとの見え方」）: `<id>`
- 2026-09-20（#35）: Hive・Iceberg・0 行・失敗とも `<id>`
- 2026-09-23（#91）: Iceberg・Hive × 0 行・1 行とも `<id>`
- 採用: `<id>`。4 回とも食い違いは無い。同じ 2026-09-17 のラウンドの CTAS が #26 で覆ったので #35 で測り直し、INSERT は覆らなかった（#35）。

## CTAS の OutputLocation

### Iceberg の CTAS の OutputLocation（#5 の実測を根拠にした判定）
- 日付: 2026-09-17（根拠の実測の日付。#12 自身は実測していない。日付は #26 のノートの「2026-09-17 の実測（issue #5 のノート 76 行目、#12 のノート）」から） ／ issue: #12（実測は #5） ／ スクリプト: `tools/measure/result-metadata.sh`（旧 `5-measure-metadata.sh`）（#26 のノートによる。#12 には書いていない）
- 相手: 本物の Athena（#5 の実測）
- 投げたもの: `CREATE TABLE ... WITH (table_type = 'ICEBERG') AS SELECT ...`（CTAS）
- 返ったもの: Iceberg の CTAS は `OutputLocation` が `<id>`（`tables/` が付かない）。それ以外の CTAS は `tables/<id>`
- 備考: **#26 の 2026-09-19 の実測で覆った**（本物は Iceberg でも `tables/<id>`。2026-09-19 ユーザーの判断で今日の実測を採り、`is_iceberg_table` ごと消して CTAS は常に `tables/<id>`）。#12 で入れた判定（`ResultFile::of` が Iceberg の CTAS だけ `Manifest` を返す）は現在は無い。#17 の 2026-09-18 の実測でも Iceberg CTAS は `<id>` と出ている（#17 の抽出を参照）。

### CTAS の OutputLocation とテーブル形式の判定
- 日付: 2026-09-19 ／ issue: #26 ／ スクリプト: `tools/measure/ctas-iceberg-detection.sh`（旧 `26-measure-iceberg-detection.sh`）
- 相手: 本物の Athena（engine version 3、workgroup `primary`）
- 投げたもの: 下の表の SQL（CTAS 6 通り）。`table_format` は `SHOW CREATE TABLE` による裏取り
- 返ったもの:

| | SQL | table_format | 本物の OutputLocation | 当時の athena-local |
|---|---|---|---|---|
| A | 素の CTAS | hive | `tables/<id>` | `tables/<id>` |
| B | `AS SELECT 1 AS i -- table_type = 'ICEBERG'` | hive | `tables/<id>` | `<id>` |
| C | `AS SELECT 'table_type=''ICEBERG''' AS s` | hive | `tables/<id>` | `<id>` |
| D | `WITH (table_type = 'ICEBERG')` | **iceberg** | **`tables/<id>`** | `<id>` |
| E | `WITH (table_type /* c */ = 'ICEBERG')` | **iceberg** | **`tables/<id>`** | `tables/<id>` |
| F | `WHERE t.table_type = 'ICEBERG'`（WITH 句の外） | hive | `tables/<id>` | `<id>` |

付随ファイルはどれも `tables/<id>.metadata`（81 バイト）で、本体は置かれない。

- 備考: 6 項目すべて測れた（1 ラウンド）。**D が 2026-09-17 の実測（issue #5 のノート 76 行目、#12 のノート。「Iceberg の CTAS は `<id>`」）と食い違う。** 投げた SQL の形は `tools/measure/result-metadata.sh`（旧 `5-measure-metadata.sh:252`） と同一（`location` を結果プレフィックス配下に指定、`is_external = false`）で、ワークグループもエンジン版も同じ。原因は特定できていない。2026-09-19 ユーザーの判断: **今日の実測を採る**（`is_iceberg_table` ごと消して CTAS は常に `tables/<id>`）。#17 の 2026-09-18 の実測でも Iceberg CTAS は `<id>` と出ているが、このノートはそれに触れていない（抽出者の注記）。

**食い違い: Iceberg の CTAS の OutputLocation**

- 2026-09-17（#5 の「文ごとの置かれ方の一覧」の CTAS（Iceberg）の行、#6 の「実在テーブルへの失敗と取り消し」の probe-ctas、それを根拠にした #12）: `<prefix><id>`（`tables/` 無し）、`.metadata` は `<id>.metadata`
- 2026-09-18（#17、[statements.md](statements.md) の「先頭コメント付きの文ごとの見え方」）: `<id>`（拡張子なし）
- 2026-09-19（#26）: `WITH (table_type = 'ICEBERG')` の D・E とも `tables/<id>`（`SHOW CREATE TABLE` で iceberg と裏取り）。投げた SQL の形・ワークグループ・エンジン版は 2026-09-17 と同じで、原因は特定できていない
- 2026-09-20（#35 の prep-i）: Iceberg の CTAS は `tables/<id>`
- 2026-09-23（#93 の対照）: 素の CTAS は `tables/<id>`
- 採用: Iceberg でも `tables/<id>`。2026-09-19 のユーザーの判断で当日の実測を採った（#26）。2026-09-18 の `<id>` には #26 のノートは触れていない。

## DROP TABLE の結果ファイル

### テーブルの DDL の `.txt`（`PROBE_DDL=1` で追加実測）
- 日付: 2026-09-16 ／ issue: #1 ／ スクリプト: `tools/measure/txt-result.sh`（旧 `1-measure-txt.sh`）（`PROBE_DDL=1`） ／ 生データ: `$HOME/athena-txt-measurements/run-20260916-090202`（4 回目と同じ置き場と読める。ノートに別記は無い）
- 相手: 本物の Athena
- 投げたもの: `CREATE TABLE`、`DROP TABLE`、`ALTER TABLE`
- 返ったもの:
  - `CREATE TABLE`：0 バイト。`.metadata` は無し。データベースの作成と同じ。
  - `DROP TABLE`：**1 バイトで、中身は改行 1 つだけ**。`GetQueryResults` は列を 0 個返すのに、空の値を持つ行を 2 つ返した。連結の規則は今回も成り立ち、空の行 2 つを改行で繋ぐと改行 1 つになる。`.metadata` は 41 バイトで置かれ、中身はクエリ ID と `DROP TABLE` の文字列だった。
  - `ALTER TABLE`：プロパティ名が不正で `FAILED` になり、成功時の中身は測れていない。
- 備考: テーブルの形式はノートに書かれていない。当時の athena-local は `DROP TABLE` を 0 バイトにし、差分を README の Caveats に書いた。現在の CLAUDE.md では DROP TABLE と ALTER TABLE ... ADD/REPLACE COLUMNS は「対象テーブルの形式によっては本物が列なしでも本体と `.metadata` を置く」扱いで `table_format.rs` が判定しており、後の issue で形式ごとに測り直されて扱いが変わっている（どの issue かはこのノートからは分からない）。

### DROP TABLE の結果ファイル（後始末の 3 本で副次的に観測）
- 日付: 2026-09-20 ／ issue: #35 ／ スクリプト: `tools/measure/insert-location.sh`（旧 `35-measure-insert-location.sh`）（後始末の部分）
- 相手: 本物の Athena
- 投げたもの: 後始末の `DROP TABLE` 3 本
- 返ったもの: Hive のテーブルは本体 0 バイト・`.metadata` 無し、Iceberg のテーブルは本体 1 バイト・`.metadata` 41 バイト
- 備考: 5.md が 2026-09-17 に記録した「1B / 41B」は Iceberg のときの値だったことになる。#39 に起票し、#39 の 3 ラウンドで確定

### DROP TABLE の結果ファイル（テーブルの形式別）
- 日付: 2026-09-20（ラウンド 1: 19:54-20:02、ラウンド 2: 20:19-20:32 で確定、ラウンド 3: 22:03-22:2x でも再現） ／ issue: #39 ／ スクリプト: ラウンド 1・2 は `tools/measure/drop-table-format.sh`（旧 `39-measure-drop-table-format.sh`。抽出には名前が無い。git の履歴（dd45049・2926545、2026-09-20「DROP TABLE の結果ファイルを対照つきで測るスクリプトを足す」ほか）から特定）。ラウンド 3 は `tools/measure/alter-substatement.sh`（旧 `39-measure-alter-substatement.sh`）
- 相手: 本物の Athena（engine version 3）
- 投げたもの: 形式だけを変えた対を同じラウンドに入れて `DROP TABLE`（CTAS で作ったテーブル / 素の CREATE で作ったテーブル）、対象が存在しない `DROP TABLE IF EXISTS`。`table_format` は `SHOW CREATE TABLE` で裏取り
- 返ったもの:

| 消したテーブル | 本体 | 本体 CT | `.metadata` |
|---|---|---|---|
| hive（CTAS 作成 / 素の CREATE 作成のどちらも） | 0B | binary | 無し |
| **iceberg（同上）** | **1B = 改行 1 つ** | **application** | **41B** |
| **対象が存在しない `IF EXISTS`** | **0B** | **binary** | **無し** |

  - 作り方（CTAS か素の CREATE か）では変わらない
  - 対象が存在しないときは形式を持ちようがないので Hive 側と同じ（ラウンド 3 の `g`）。athena-local がカタログ単位で判定すると食い違う唯一のケース
  - 1 バイトの正体は改行 1 つ（`0a`）。`1.md` の 2026-09-16 の記録を形式の裏取り付きで再現。過去 3 ラウンドと整合
  - 41B の中身: `0a 1b` + エンジンのクエリ ID 27 バイト + `12 0a` + `DROP TABLE`
- 備考: ラウンド 1 は 16 項目中 11 項目（`a` の Hive の素の `CREATE TABLE` が `No location was specified for table` で開始失敗し、`c1`/`d1`/`g` が SKIP。`c2` は `Unsupported table property key: comment` で FAILED）。ラウンド 2 で `a` を `CREATE EXTERNAL TABLE ... LOCATION`、`c2` を `vacuum_max_snapshot_age_seconds` に差し替えて全 16 項目

**食い違い: DROP TABLE の本体と `.metadata`**

- 2026-09-16（#1、上の「テーブルの DDL の `.txt`」）: 本体 1 バイト（改行 1 つ）・`.metadata` 41 バイト。テーブルの形式は記録なし
- 2026-09-17（#5、「文ごとの置かれ方の一覧」）: `.txt` 1B・`.metadata` 41B・application。形式は記録なし
- 2026-09-17（#6、「実在テーブルへの失敗と取り消し」の後始末）: `.txt` 1B・41B。未作成テーブルへの `DROP TABLE IF EXISTS` は 0B・`.metadata` 無し
- 2026-09-20（#35、後始末の 3 本）: Hive は 0 バイト・無し、Iceberg は 1 バイト・41 バイト
- 2026-09-20（#39、3 ラウンド）: 形式で割れる（上の表）
- 採用: テーブルの形式で割れる（#39、2026-09-20）。それまでの「1B / 41B」は Iceberg のときの値だった（#35）。athena-local が README に書くだけにせず Trino に形式を問い合わせて合わせるのは 2026-09-20 のユーザーの選択（#39）。

## ALTER TABLE の結果ファイル

### ALTER TABLE の結果ファイルと SubstatementType
- 日付: 2026-09-20（ラウンド 2 で `ADD COLUMNS` と `SET TBLPROPERTIES`、ラウンド 3 で残り。ノートの節見出しは「ラウンド 3 で確定」、「実測の結果（2026-09-20〜21）」） ／ issue: #39 ／ スクリプト: `tools/measure/alter-substatement.sh`（旧 `39-measure-alter-substatement.sh`）（ラウンド 3、18 項目すべて測れた）
- 相手: 本物の Athena
- 投げたもの: 下表の ALTER TABLE（全項目で `SubstatementType` と `StatementType` を記録）
- 返ったもの（「本体 / `.metadata` / 本体 CT」の順）:

| 文 | hive | iceberg | 本物の `SubstatementType` |
|---|---|---|---|
| `SET TBLPROPERTIES ('comment' = '...add column...')` | 0B / 無し / binary | FAILED（`comment` 不可） | **`ALTER_TABLE_PROPERTIES`** |
| **`ADD COLUMNS (m int)`** | 0B / **38B** / **application** | 0B / 無し / binary | `ALTER_TABLE_ADD_COLUMN` |
| `DROP COLUMN` | FAILED（Hive の制約） | 0B / 無し / binary | **`ALTER_TABLE_DROP_COLUMN`** |
| `SET LOCATION` | 0B / 無し / binary | （Hive のみ測定） | **`ALTER_TABLE_SET_LOCATION`** |
| `IF EXISTS ... ADD COLUMNS` | START_FAILED | START_FAILED | - |
| `RENAME COLUMN` | START_FAILED | START_FAILED | - |

  - `.metadata` を置く ALTER は `ADD COLUMNS` × Hive だけ。38B の中身は `0a 24` + `QueryExecutionId`（UUID 36 バイト）のみ。field 2 も 3 も列も無い
  - `ALTER TABLE IF EXISTS` と `RENAME COLUMN` は Athena に構文が無い（`mismatched input`。MALFORMED_QUERY）。両形式で同じ結果
  - 差は「Iceberg かどうか」では決まらない。`DROP TABLE` は Iceberg 側が置き、`ADD COLUMNS` は Hive 側が置く。中身の形も違う（41B はエンジン ID + `DROP TABLE`、38B は `QueryExecutionId` のみ）
  - 本体の Content-Type と `.metadata` の有無が完全に相関する。成功した文で本体が `application/octet-stream` なのは `b1`（ADD COLUMNS × Hive）と `f`/`h2`（DROP × Iceberg）だけで、その 3 つだけが `.metadata` を持つ（5.md:53 の「`UpdateCount` を返さない文が素の protobuf を持つ」と同じ切り口）
  - 当時の athena-local は `SET TBLPROPERTIES` に `ALTER_TABLE_ADD_COLUMN` を返しており誤りと確定。`ALTER_TABLE_PROPERTIES`・`ALTER_TABLE_DROP_COLUMN`・`ALTER_TABLE_SET_LOCATION` を返していなかった
- 備考: 残りの ALTER の亜種（REPLACE COLUMNS・ADD/DROP PARTITION・RENAME TO・SET LOCATION × Iceberg・DROP COLUMNS）は #43 で実測

### ALTER TABLE の亜種 × テーブル形式
- 日付: 2026-09-21（1 ラウンド、全 21 項目） ／ issue: #43 ／ スクリプト: `tools/measure/alter-variants.sh`（旧 `43-measure-alter-variants.sh`） ／ 生データ: `$HOME/athena-alter-variants-measurements/run-20260921-181952/`
- 相手: 本物の Athena
- 投げたもの: 下表の ALTER TABLE を Hive / Iceberg それぞれに。対照 5 件（`probe` の `SHOW TABLES`、`ctl-select`、`f1` の `ADD COLUMNS` × Hive、`f2` の `ADD COLUMNS` × Iceberg、`e1` の `SET LOCATION` × Hive）
- 返ったもの:

| 文 | Hive | Iceberg | `SubstatementType` |
| --- | --- | --- | --- |
| `REPLACE COLUMNS` | 成功・本体 0B・**`.metadata` 38B** | FAILED | `ALTER_TABLE_REPLACE_COLUMN`（単数形） |
| `ADD PARTITION` | 成功・本体 0B・無し | FAILED | `ALTER_TABLE_ADD_PARTITION` |
| `DROP PARTITION` | 成功・本体 0B・無し | — | `ALTER_TABLE_DROP_PARTITION` |
| `RENAME TO` | FAILED（Glue が `Table cannot be renamed`） | 成功・本体 0B・無し | `ALTER_TABLE_RENAME` |
| `SET LOCATION` | 成功（既測の再現） | FAILED | `ALTER_TABLE_SET_LOCATION` |
| `DROP COLUMNS`（複数形） | `StartQueryExecution` が構文エラー | 同左 | 返らない |

  - 対照 5 件（`SHOW TABLES` 228B/312B・`ctl-select` 8B/73B・`ADD COLUMNS` × Hive 38B・× Iceberg 無し・`SET LOCATION` × Hive）はすべて既測値と一致
  - 失敗しても `SubstatementType` は返る。Iceberg の失敗 3 件はすべて `Query type not supported by Athena Iceberg at this time`
  - `REPLACE COLUMNS` × Hive の `.metadata` は `ADD COLUMNS` × Hive と同一の形（`0a 24` + 36 文字の UUID）。16 進を突き合わせて確認
  - `DROP COLUMNS`（複数形）は `mismatched input 'COLUMNS'. Expecting: '.', 'DROP'` / `MALFORMED_QUERY`。`ADD` は複数形を受けるので単複の扱いは対称ではない
  - `b1`（`RENAME TO` × Hive）は FAILED なのに本体 376B を置いた。既存の Caveat「Hive 経由の DDL は `<id>.txt` に理由を書き、Iceberg の `ALTER TABLE` は何も書かない」（2026-09-16／17 実測）の再現
- 備考: 無し

### `ALTER TABLE ... REPLACE COLUMN`（単数形）
- 日付: 2026-09-24 ／ issue: #146（バッチは #113） ／ スクリプト: `tools/measure/unmeasured-batch/run.sh`（項目 `s1`） ／ 生データ: `$HOME/athena-unmeasured-batch-measurements/run-20260924-004554/s1/`
- 相手: 本物の Athena（engine version 3、workgroup `primary`、Catalog `AwsDataCatalog`、Database `<DB>`）
- 投げたもの: フィクスチャ `CREATE EXTERNAL TABLE <DB>.athena_local_probe_113_s1 (n int, s string) LOCATION '<OUTPUT>tables-probe-113-s1/'`、単数形 `ALTER TABLE <DB>.athena_local_probe_113_s1 REPLACE COLUMN (n int, s string)`、対照の複数形 `ALTER TABLE <DB>.athena_local_probe_113_s1 REPLACE COLUMNS (n int, s string)`
- 返ったもの:

  | 文 | 結果 | StatementType / SubstatementType | 本体 | `.metadata` | Content-Type（本体 / `.metadata`） |
  | --- | --- | --- | --- | --- | --- |
  | フィクスチャ | SUCCEEDED | DDL / CREATE_TABLE | `<id>.txt` 0B | 無し | binary/octet-stream / - |
  | `REPLACE COLUMN`（単数形） | `StartQueryExecution` が `InvalidRequestException`: `line 1:52: mismatched input 'REPLACE'. Expecting: '.', 'ADD', 'DROP', 'EXECUTE', 'RENAME', 'SET'`、`AthenaErrorCode` `MALFORMED_QUERY`。実行は作られない | 返らない | - | - | - |
  | `REPLACE COLUMNS`（複数形） | SUCCEEDED | DDL / ALTER_TABLE_REPLACE_COLUMN | `<id>.txt` 0B | 38B（`0a 24` + QueryExecutionId の 36 文字だけ） | application/octet-stream / application/octet-stream |

- 備考: 対照は #43 の `REPLACE COLUMNS` × Hive（本体 0B・`.metadata` 38B）の再現。桁位置 `1:52` は実名のテーブル名の長さで決まる

### `ALTER TABLE ... DROP PARTITION` × Iceberg
- 日付: 2026-09-24 ／ issue: #146（バッチは #113） ／ スクリプト: `tools/measure/unmeasured-batch/run.sh`（項目 `s2`） ／ 生データ: `$HOME/athena-unmeasured-batch-measurements/run-20260924-004554/s2/`
- 相手: 本物の Athena（engine version 3、workgroup `primary`、Catalog `AwsDataCatalog`、Database `<DB>`）
- 投げたもの:
  - Iceberg: フィクスチャ `CREATE TABLE <DB>.athena_local_probe_113_s2_ice WITH (table_type = 'ICEBERG', partitioning = ARRAY['p'], location = '<OUTPUT>tables-probe-113-s2-ice/', is_external = false) AS SELECT 1 AS n, 'a' AS p`、`ALTER TABLE <DB>.athena_local_probe_113_s2_ice DROP PARTITION (p = 'a')`
  - 対照の Hive: フィクスチャ `CREATE EXTERNAL TABLE <DB>.athena_local_probe_113_s2_hive (n int) PARTITIONED BY (p string) LOCATION '<OUTPUT>tables-probe-113-s2-hive/'`、`ALTER TABLE <DB>.athena_local_probe_113_s2_hive ADD PARTITION (p = 'a') LOCATION '<OUTPUT>tables-probe-113-s2-hive/p=a/'`、`ALTER TABLE <DB>.athena_local_probe_113_s2_hive DROP PARTITION (p = 'a')`
- 返ったもの:

  | 文 | State | StatementType / SubstatementType | OutputLocation | 本体 | `.metadata` | `GetQueryResults` |
  | --- | --- | --- | --- | --- | --- | --- |
  | Iceberg のフィクスチャ（CTAS） | SUCCEEDED | DDL / CREATE_TABLE_AS_SELECT | `tables/<id>` | 無し | 81B（application/octet-stream） | `UpdateCount` 1 |
  | **`DROP PARTITION` × Iceberg** | **FAILED** | DDL / ALTER_TABLE_DROP_PARTITION | `<id>.txt` | **無し**（`<id>.txt` も `.txt.metadata` も `aws s3 ls` が rc=1） | 無し | 400 `RESULT_NOT_FOUND`（`Could not find results`） |
  | Hive のフィクスチャ | SUCCEEDED | DDL / CREATE_TABLE | `<id>.txt` | 0B（binary/octet-stream） | 無し | 列も行も無し |
  | `ADD PARTITION` × Hive | SUCCEEDED | DDL / ALTER_TABLE_ADD_PARTITION | `<id>.txt` | 0B（binary/octet-stream） | 無し | 列も行も無し |
  | `DROP PARTITION` × Hive | SUCCEEDED | DDL / ALTER_TABLE_DROP_PARTITION | `<id>.txt` | 0B（binary/octet-stream） | 無し | 列も行も無し |

  - `DROP PARTITION` × Iceberg の `StateChangeReason` は `Query type not supported by Athena Iceberg at this time`、`AthenaError` は ErrorCategory 2 / ErrorType 1200 / Retryable false で、`ErrorMessage` は `StateChangeReason` と同じ
- 備考: 上の #43 の表で「—」（測っていない）だった `DROP PARTITION` × Iceberg の欄が埋まった。構文としては受け付けられて実行時に失敗し、`SubstatementType` は返る。文言と ErrorType は #43 の Iceberg の失敗 3 件（`REPLACE COLUMNS`・`ADD PARTITION`・`SET LOCATION`）と同じ。何も置かず `RESULT_NOT_FOUND` なのは #6 の Iceberg の `ALTER TABLE` の失敗と同じ。Hive の 2 本は #43 の `ADD PARTITION`／`DROP PARTITION` × Hive の再現

## 失敗・取り消しのときの結果ファイル

`GetQueryResults` の応答も含む。

### 失敗したクエリの `.txt`
- 日付: 2026-09-16 ／ issue: #1 ／ スクリプト: `tools/measure/txt-result.sh`（旧 `1-measure-txt.sh`） ／ 生データ: `$HOME/athena-txt-measurements/run-20260916-090202`
- 相手: 本物の Athena
- 投げたもの: 失敗する `SHOW TABLES`、失敗する `ALTER TABLE`（プロパティ名が不正）
- 返ったもの:
  - 失敗した `SHOW TABLES`：`FAILED: ` に続けて `StateChangeReason` と同じ文言が入った `.txt` が置かれた。`.metadata` は無し。
  - 失敗した `ALTER TABLE`：`.txt` 自体が置かれなかった。`HeadObject` が 404 を返し、`GetQueryResults` も `RESULT_NOT_FOUND` だった。
- 備考: #6 に記録。#1 の実装では失敗時には書かなかった（判断 2）。現在の CLAUDE.md の `write_failure`（`ResultFile::Text` の文だけ `FAILED: ` + 理由を書く）は後の issue（#6 と思われる）でこの実測に合わせたもの。

### 失敗・取り消し時に本物が置く結果ファイル（1 回目、PROBE_DDL 無し）
- 日付: 2026-09-17 ／ issue: #6 ／ スクリプト: `tools/measure/failed-query-results.sh`（旧 `6-measure-failed.sh`）（`PROBE_DDL` 無し。実名は書かない） ／ 生データ: `$HOME/athena-failed-measurements/run-20260917-212623`
- 相手: 本物の Athena
- 投げたもの: 下の表の「文」の列
- 返ったもの:

| ラベル | 文 | State | 本体 | `.metadata` | Content-Type | `GetQueryResults` |
| --- | --- | --- | --- | --- | --- | --- |
| failed-show-tables | `SHOW TABLES IN <無い DB>` | FAILED | `.txt` 91B | 無し | **application/octet-stream**（成功時の `.txt` は binary/octet-stream） | 成功（`ResultSet` は空。`.results.json` 参照） |
| failed-show-columns | `SHOW COLUMNS IN <無いテーブル>` | **START_FAILED** | - | - | - | `StartQueryExecution` が `InvalidRequestException` / `INVALID_INPUT` 「Entity Not Found」。実行が作られない |
| failed-describe | `DESCRIBE <無いテーブル>` | **START_FAILED** | - | - | - | 同上 |
| failed-select-analysis | `SELECT * FROM <無いテーブル>` | FAILED | 無し（HeadObject 404） | 無し | - | `INVALID_QUERY_EXECUTION_STATE` |
| failed-select-runtime | `SELECT 1/0` | FAILED | 無し | 無し | - | 同上 |
| failed-select-runtime-2 | `SELECT CAST('abc' AS integer)` | FAILED | 無し | 無し | - | 同上 |
| failed-syntax | `SELECT FROM` | START_FAILED | - | - | - | `MALFORMED_QUERY`「Queries of this type are not supported」 |
| failed-drop-table | `DROP TABLE <無いテーブル>` | FAILED | `.txt` 98B | 無し | application/octet-stream | 成功 |
| failed-create-database | `CREATE DATABASE <既存 DB>` | FAILED | `.txt` 120B | 無し | application/octet-stream | 成功 |
| failed-insert-no-table | `INSERT INTO <無いテーブル>` | FAILED | 無し（`<id>` も `<id>.metadata` も無し） | 無し | - | `INVALID_QUERY_EXECUTION_STATE` |
| failed-update-no-table | `UPDATE <無いテーブル>` | FAILED | 無し | 無し | - | 同上 |
| failed-delete-no-table | `DELETE FROM <無いテーブル>` | FAILED | 無し | 無し | - | 同上 |
| failed-ctas-no-func | CTAS（無い関数） | FAILED | 無し | 無し | - | 同上 |
| cancelled-select | 長い SELECT を RUNNING で停止 | CANCELLED | 無し（404） | 無し | - | `RESULT_NOT_FOUND` |
| stopped-after-succeeded(-after-stop) | `SELECT 1 AS i` の成功後に停止 | SUCCEEDED | `.csv` 8B のまま | 73B のまま | binary/octet-stream | 成功。止めても消えない |

- 備考: `SHOW COLUMNS` / `DESCRIBE` の対象不在で本物は `StartQueryExecution` が `INVALID_INPUT` になる（athena-local は FAILED になり `<id>.txt` を置く。README Caveats に書く判断）。本物は失敗した Hive 経由 DDL でも `GetQueryResults` が 200 で `ResultSetMetadata: null` の空 `ResultSet` を返す（athena-local は `INVALID_QUERY_EXECUTION_STATE`）。取り消しの長い SELECT は `tools/measure/client-request-token-extra.sh`（旧 `3-measure-client-request-token-extra.sh:118`） の `LONG_QUERY_SQL`（30000×30000 の `UNNEST(sequence)` CROSS JOIN。5000×5000 は速すぎて取り消せなかった）を使った。それまで README の「a cancelled query write nothing, also as on Athena」は未実測のまま書かれていたが、ここで実測された。

### 失敗した `.txt` の中身（1 回目のラウンドから）
- 日付: 2026-09-17 ／ issue: #6 ／ スクリプト: `tools/measure/failed-query-results.sh`（旧 `6-measure-failed.sh`） ／ 生データ: `$HOME/athena-failed-measurements/run-20260917-212623`
- 相手: 本物の Athena
- 投げたもの: 上の表の failed-show-tables / failed-drop-table / failed-create-database
- 返ったもの（`od -c`。末尾に改行は無い）:
  - SHOW TABLES: `FAILED: SemanticException [Error 10072]: Database does not exist: no_such_db_athena_local_6`（91B）
  - DROP TABLE: `FAILED: SemanticException [Error 10001]: Table not found <db>.no_such_table_athena_local_6`（98B）
  - CREATE DATABASE: `FAILED: Execution Error, return code 1 from org.apache.hadoop.hive.ql.exec.DDLTask. Database <db> already exists`（120B）
  - **3 件とも `StateChangeReason` とバイト単位で同一**。`StateChangeReason` 自体が `FAILED: ` で始まる（Hive 経由の DDL の文言）。`AthenaError.ErrorMessage` は別の文字列（`com.facebook.presto.spi.PrestoException: Database ... not found. (Service: AmazonDataCatalog; ...)`、ErrorCategory 1、ErrorType 1502）。
  - エンジン経由（SELECT / DML / CTAS）の `StateChangeReason` は `ERROR_NAME: message`（`TABLE_NOT_FOUND: line 1:15: Table '...' does not exist`、`DIVISION_BY_ZERO: Division by zero`、`INVALID_CAST_ARGUMENT: Cannot cast 'abc' to INT`）で `FAILED: ` は付かず、ファイルも置かれない。`AthenaError.ErrorMessage` は `StateChangeReason` と同じ。
- 備考: ノートが読み取った規則: 本物は Hive 経由で実行する DDL（SHOW TABLES / DROP TABLE / CREATE DATABASE。#1 の実測から SHOW 系全般）が失敗すると `<id>.txt` に `StateChangeReason` をそのまま置き、エンジン（Presto/Trino）経由の文（SELECT / INSERT / UPDATE / DELETE / CTAS、#1 の Iceberg の ALTER TABLE）が失敗すると何も置かない。athena-local はすべて Trino 経由なので `StateChangeReason` は常に `ERROR_NAME: message` の形。issue 本文の「`FAILED: ` に続けて `StateChangeReason`」は、`StateChangeReason` に `FAILED: ` が含まれていることを見落としていた表現とノートは判定している。#1 のノートには `FAILED: ` の後ろの生文字列・失敗時の Content-Type・`HeadObject` 404 の文言は記録されていなかった（ここで初めて測った）。

### 実在テーブルへの失敗と取り消し（追加実測、PROBE_DDL=1）
- 日付: 2026-09-17 ／ issue: #6 ／ スクリプト: `tools/measure/failed-query-results.sh`（旧 `6-measure-failed.sh`）（`PROBE_DDL=1`） ／ 生データ: `run-20260917-214013`（1 回目と同じ `$HOME/athena-failed-measurements/` 配下と思われるが、ノートには `run-20260917-214013` とだけ書いてある）
- 相手: 本物の Athena
- 投げたもの: 下の表の「文」の列。常時ケース 15 件も再実行し、1 回目と完全に同じだった
- 返ったもの:

| ラベル | 文 | State | 本体 | `.metadata` | `GetQueryResults` | 備考 |
| --- | --- | --- | --- | --- | --- | --- |
| probe-ctas | Iceberg の CTAS（成功） | SUCCEEDED | 無し | `<id>.metadata` 81B | 成功 | #5 と同じ |
| failed-alter-table | `ALTER TABLE <Iceberg> SET TBLPROPERTIES ('comment'='probe')` | FAILED | **無し（404）** | 無し | **`RESULT_NOT_FOUND`** | `StateChangeReason` は `Unsupported table property key: comment`（`FAILED: ` もエラー名も無し。ErrorType 1200）。#1 の再現 |
| failed-create-table-exists | `CREATE TABLE <既存> (i int)` | START_FAILED | - | - | `MALFORMED_QUERY`「No location was specified for table」 | SQL に LOCATION が無く、重複のケースとしては**未実測のまま** |
| failed-insert-type | `INSERT INTO <Iceberg> VALUES ('abc')` | FAILED | 無し（`<id>` も `<id>.metadata` も無し） | 無し | `INVALID_QUERY_EXECUTION_STATE` | `TYPE_MISMATCH: Insert query has mismatched column types ... If a data manifest file was generated at '<prefix><id>-manifest.csv' ...` |
| failed-update-no-column | `UPDATE <Iceberg> SET no_such_col = 9` | FAILED | 無し | 無し | 同上 | `COLUMN_NOT_FOUND: line 1:46: The UPDATE SET target column no_such_col doesn't exist` |
| failed-delete-no-column | `DELETE FROM <Iceberg> WHERE no_such_col = 1` | FAILED | 無し | 無し | 同上 | |
| cancelled-insert | 長い INSERT を RUNNING で停止 | CANCELLED | 無し | 無し | `RESULT_NOT_FOUND` | `Query cancelled by user` |
| cancelled-ctas | 長い Iceberg CTAS を RUNNING で停止 | CANCELLED | 無し | 無し | `RESULT_NOT_FOUND` | 置き場所 `tables-probe-6-cancel/` に断片は無し。ただし後始末の `DROP TABLE IF EXISTS` が 1B の `.txt` + 41B の `.metadata` を置いた（未作成テーブルへの同文は 0B・`.metadata` 無し）ので、テーブルのエントリ自体は作られていた |
| cleanup-cancel-ctas / drop-probe | `DROP TABLE` | SUCCEEDED | `.txt` 1B | 41B | 成功 | #1・#5 と同じ |

- 備考: 取り消しは INSERT / CTAS でも何も置かれない。本物の `GetQueryResults` は FAILED でも文ごとに割れる（Hive 経由の DDL は 200 で空の `ResultSet`、エンジン経由の SELECT / DML / CTAS は `INVALID_QUERY_EXECUTION_STATE`、Iceberg の ALTER TABLE は `RESULT_NOT_FOUND`）。athena-local は常に `INVALID_QUERY_EXECUTION_STATE`（範囲外で Caveats に 1 行）。probe-ctas の「Iceberg の CTAS は本体無し・`<id>.metadata`」は #5（2026-09-17）と同じ結果だが、CTAS のファイル名（`<id>` か `tables/<id>` か）は #26（2026-09-19）の実測で「Iceberg でも `tables/<id>`」に覆っている。この表の `<id>.metadata` の記述もその覆った側の観測である（抽出者の注記）。

### `CREATE TABLE` の重複（Hive の外部テーブルと Iceberg の CTAS）
- 日付: 2026-09-24 ／ issue: #146（バッチは #113） ／ スクリプト: `tools/measure/unmeasured-batch/run.sh`（項目 `r1`） ／ 生データ: `$HOME/athena-unmeasured-batch-measurements/run-20260924-004554/r1/`
- 相手: 本物の Athena（engine version 3、workgroup `primary`、Catalog `AwsDataCatalog`、Database `<DB>`）
- 投げたもの: 同じ文を 2 回ずつ
  - Hive: `CREATE EXTERNAL TABLE <DB>.athena_local_probe_113_r1_hive (n int) LOCATION '<OUTPUT>tables-probe-113-r1-hive/'`
  - Iceberg: `CREATE TABLE <DB>.athena_local_probe_113_r1_ice WITH (table_type = 'ICEBERG', location = '<OUTPUT>tables-probe-113-r1-ice/', is_external = false) AS SELECT 1 AS n`
- 返ったもの:

  | 文 | State | StatementType / SubstatementType | OutputLocation | 本体 | `.metadata` | Content-Type（本体 / `.metadata`） | `GetQueryResults` |
  | --- | --- | --- | --- | --- | --- | --- | --- |
  | Hive 1 回目 | SUCCEEDED | DDL / CREATE_TABLE | `<id>.txt` | 0B | 無し | binary/octet-stream / - | 列も行も無し、`UpdateCount` 無し |
  | **Hive 2 回目** | **FAILED** | DDL / CREATE_TABLE | `<id>.txt` | **166B** | 無し | application/octet-stream / - | 200、`ResultSetMetadata: null`・`UpdateCount: null` |
  | Iceberg 1 回目 | SUCCEEDED | DDL / CREATE_TABLE_AS_SELECT | `tables/<id>` | 無し | 81B（エンジン ID、`CREATE TABLE`、件数 1、`rows bigint`） | - / application/octet-stream | `UpdateCount` 1 |
  | **Iceberg 2 回目** | **FAILED** | DDL / CREATE_TABLE_AS_SELECT | `tables/<id>` | **無し** | **無し** | - | 400 `INVALID_QUERY_EXECUTION_STATE`（`Query did not finish successfully. Final query state: FAILED`） |

  - Hive 2 回目: `StateChangeReason` は `FAILED: Execution Error, return code 1 from org.apache.hadoop.hive.ql.exec.DDLTask. AlreadyExistsException(message:Table athena_local_probe_113_r1_hive already exist)`。本体 166B はこの文言とバイト単位で同じ（末尾に改行は無い）。`AthenaError` は ErrorCategory 2 / ErrorType 1006 / Retryable false、`ErrorMessage` は別の文字列 `Table athena_local_probe_113_r1_hive already exists.`
  - Iceberg 2 回目: `StateChangeReason` は `TABLE_ALREADY_EXISTS: line 1:1: Destination table 'awsdatacatalog.<DB>.athena_local_probe_113_r1_ice' already exists. You may need to manually clean the data at location '<OUTPUT>tables/<id>' before retrying. Athena will not delete data in your account.`。`AthenaError` は ErrorCategory 2 / ErrorType 1110 / Retryable false で、`ErrorMessage` は `StateChangeReason` と同じ
- 備考: 割れ方は #6 の規則（Hive 経由の DDL は失敗の理由を `<id>.txt` に置き、エンジン経由の文は何も置かない。`GetQueryResults` も Hive 経由は 200 の空の `ResultSet`、エンジン経由は `INVALID_QUERY_EXECUTION_STATE`）と同じ。#6 で「未実測のまま」とした `CREATE TABLE` の重複（`failed-create-table-exists` は `LOCATION` が無く START_FAILED だった）がこれで埋まった

### 失敗した `SHOW FUNCTIONS` の結果ファイル
- 日付: 2026-09-24 ／ issue: #146（バッチは #113。未実測にしたのは #80） ／ スクリプト: `tools/measure/unmeasured-batch/run.sh`（項目 `r3`） ／ 生データ: `$HOME/athena-unmeasured-batch-measurements/run-20260924-004554/r3/`
- 相手: 本物の Athena（engine version 3、workgroup `primary`、Catalog `AwsDataCatalog`、Database `<DB>`）
- 投げたもの: 対照 `SHOW FUNCTIONS`、失敗させる `SHOW FUNCTIONS LIKE 'x' ESCAPE 'ab'`
- 返ったもの:
  - 対照: SUCCEEDED、UTILITY / SHOW_FUNCTIONS、`<id>.csv` 89425B（見出し行 `"Function","Return Type","Argument Types","Function Type","Deterministic","Description"` つきの CSV）、`<id>.csv.metadata` 340B（field 1 はエンジン ID。列は 6 つで、`Function`・`Return Type`・`Argument Types`・`Function Type`・`Description` が `varchar`（7 Precision は 31・28・78・9・205、8 = 0、10 = 1）、`Deterministic` が `boolean`（7・8 無し、10 = 0）。9 はどれも 3）。Content-Type は本体・`.metadata` とも application/octet-stream。`GetQueryResults` は列名行込みで 896 行、`NextToken` 無し、`UpdateCount` 0
  - 失敗: **FAILED**、UTILITY / SHOW_FUNCTIONS、OutputLocation は `<id>.csv`。`StateChangeReason` は `INVALID_FUNCTION_ARGUMENT: Escape string must be a single character`、`AthenaError` は ErrorCategory 2 / ErrorType 1106 / Retryable false（`ErrorMessage` は `StateChangeReason` と同じ）。**`<id>.csv` も `<id>.csv.metadata` も無い**（`aws s3 ls` がどちらも rc=1）。`GetQueryResults` は 400 `INVALID_QUERY_EXECUTION_STATE`（`Query did not finish successfully. Final query state: FAILED`）
- 備考: 実行時に失敗した `SELECT`（#6 の `failed-select-runtime` など）と同じく何も置かない。対照は #76 の `h1-show-functions`（[statements.md](statements.md) の「SHOW FUNCTIONS の結果ファイル」）の再現

## Content-Type

### `.txt` の Content-Type
- 日付: 2026-09-16 ／ issue: #1 ／ スクリプト: `tools/measure/txt-result.sh`（旧 `1-measure-txt.sh`）。Content-Type の取得は `tools/measure/txt-result-content-type.sh`（旧 `1-measure-content-type.sh`。抽出には無い。スクリプト冒頭の「issue #1 で作成」「txt-result.sh の出力をそのまま使う」から） ／ 生データ: `$HOME/athena-txt-measurements/run-20260916-090202`
- 相手: 本物の Athena
- 投げたもの: 上と同じ文。`.txt` の Content-Type を見た
- 返ったもの: 本物は `.txt` に文字列型を付けていない。すべて octet-stream で、次の 2 種類に割れた。

  | 値 | 当てはまった文 |
  | --- | --- |
  | `binary/octet-stream` | SHOW TABLES、SHOW COLUMNS、SHOW TBLPROPERTIES、SHOW PARTITIONS、SHOW DATABASES、CREATE DATABASE、DROP DATABASE |
  | `application/octet-stream` | DESCRIBE、EXPLAIN、SHOW CREATE TABLE |

  この割れ方は `GetQueryResults` の `UpdateCount` の有無と一致している。`UpdateCount` が返らない 3 つが `application/octet-stream` で、`0` で返るその他が `binary/octet-stream` だった。理由は測れていない。
- 備考: athena-local は多数派の `binary/octet-stream` を送り、割れていた事実と理由が未実測であることを README に書いた。`text/csv`（`.csv`）はこの時点で実測していない（0.3.0 からの値）と自己レビューで明記。1 回目の本文では「`EXPLAIN` の `UpdateCount` は返らない」「`CREATE DATABASE`／`DROP DATABASE` も `UpdateCount` は返らない」と書いてあり、4 回目の「`0` で返るその他」に CREATE/DROP DATABASE が入るのと食い違う。ノートにはこの食い違いの説明は無い。

### 既存の生データの集計（ラウンド 0）
- 日付: 2026-09-23（03:44〜03:50） ／ issue: #70 ／ スクリプト: 無し
- 相手: 本物の Athena（既存 16 ラウンド・約 140 件の head-object）
- 返ったもの: 同じ SQL は常に同じ値。条件は決まらなかった

### 結果ファイルの Content-Type の規則
- 日付: 2026-09-23（ラウンド 2、04:30〜04:39。ラウンド 1 は 04:20 に能力チェックの `list-work-groups --max-items 1` を CLI が拒否して中止、本物への呼び出し 1 回） ／ issue: #70 ／ スクリプト: `tools/measure/content-type-rules.sh`（旧 `70-measure-content-type.sh`）（コミット f5d07fe・3a19123） ／ 生データ: `~/athena-content-type-measurements/run-20260923-043027`
- 相手: 本物の Athena（StartQueryExecution 36 本、36 項目すべて SUCCEEDED・未測定 0）
- 投げたもの: 下表の SQL。スキャンは `SELECT 1 FROM <db>.<t> LIMIT 1` の 1 件だけ。d 系が最大 300 万行（28.9 MB）を S3 に書く
- 返ったもの:

| 対象 | binary/octet-stream | application/octet-stream |
|---|---|---|
| `.csv`（SELECT の本体） | リテラルだけの SELECT: `SELECT 1`、`SELECT 1, 2`、`SELECT 'a'`、`SELECT 1.5`、`SELECT 1 AS i`、`SELECT true`、`SELECT 1, 'a'`、`SELECT 23807 AS fresh`（初めて流す SQL の 1 回目から binary。キャッシュではない）。過去の実測で `-- c\nSELECT 1`、`/* c */ SELECT 1`、`SELECT /* c */ 1`、`SELECT 1 -- c` も binary | それ以外: `SELECT 1 AS i WHERE false`、`SELECT 1 WHERE true`、`SELECT CAST(1.5 AS DOUBLE)`、`SELECT CAST(1 AS BIGINT)`、`SELECT NULL`、`SELECT 1 + 1`、`SELECT * FROM (VALUES 1)`、`SELECT 1 UNION ALL SELECT 2`、`SELECT 1 FROM t LIMIT 1`、`UNNEST(sequence(...))` の 1〜300 万行。過去の実測で `SELECT 1 AS i, 'abc' AS s, CAST(1.5 AS DOUBLE) AS d`、`SELECT * FROM t LIMIT 1`、`TABLE t LIMIT 1` |
| `.txt`（本体） | `SHOW TABLES`（0 行でも）、`SHOW DATABASES`、`SHOW COLUMNS`、`SHOW TBLPROPERTIES`、`SHOW VIEWS`、`SHOW PARTITIONS`。過去の実測で 0 バイトの DDL（`CREATE DATABASE`、`DROP DATABASE`、Hive の `DROP TABLE`、Iceberg の `ALTER TABLE ADD COLUMNS`） | `DESCRIBE`、`EXPLAIN`、`SHOW CREATE TABLE`（SHOW の中で唯一の例外）。過去の実測で Iceberg の `DROP TABLE`（1 バイト）、Hive の `ALTER TABLE ADD COLUMNS`、FAILED の本文 |
| `.metadata` | 本体と常に同じ | 本体と常に同じ。例外は 140 MB のマルチパート本体（本体 binary、`.metadata` application。2026-09-22 実測） |

  - binary の項目はどれも `QueryPlanningTimeInMillis` が無く、application の項目は `DESCRIBE`・`SHOW CREATE TABLE` を除き必ずある。本物は定数だけの SELECT と SHOW 系（`SHOW CREATE TABLE` を除く）をエンジンの計画を通さずに書いていると読める（機構の推測。規則そのものは実測）
  - サイズは 300 万行・28.9 MB まで単一 PUT の application。マルチパート（binary）の境界は未測定
  - 2026-09-17 の「`.csv` は application（6 件中 5 件）」の少数派の 1 件は `SELECT 1` で、多数決で丸めていた。`.txt` の「多数派を採る」（2026-09-16）も同じ
- 備考: 2026-09-16／17 の「多数派を採る」固定値（`.csv`／`.metadata` は application、`.txt` は binary）を覆した。140 MB のマルチパートの 2026-09-22 実測の出典はノートに無い。未測定だった形の一部は #76 で測り、`SELECT -1`・`SELECT 1.5E0`・裸の別名 `SELECT 1 i` など 4 形が binary と分かって判定を広げた（詳細は #76 の生データ。`SELECT 1;` は本物 binary だが Trino が弾くので判定を変えない）。`SHOW FUNCTIONS` は #80 で `.csv` に

### #70 で未測定だった形の Content-Type
- 日付: 2026-09-23（ラウンド 1、06:54〜07:08） ／ issue: #76 ／ スクリプト: `tools/measure/content-type-rules.sh`（旧 `70-measure-content-type.sh` への追記。抽出には名前が無い。git の履歴（e20dcff、2026-09-23「issue #76 の実測項目を #70 の Content-Type スクリプトに足す」）から特定） ／ 生データ: `~/athena-content-type-measurements/run-20260923-065415`。summary は issue のコメント https://github.com/aoyagikouhei/athena-local/issues/76#issuecomment-5785068087
- 相手: 本物の Athena（StartQueryExecution 57 本、SUCCEEDED 54・START_FAILED 2・SKIPPED 1。57 項目、未測定 3）
- 投げたもの: `DESC`、`SHOW CREATE VIEW`、SELECT の変種、`SHOW FUNCTIONS`/`SESSION`/`STATS`、マルチパートの境界など（#70 の未測定の形）
- 返ったもの（ノートに書いてある範囲）:
  - A〜E の 36 項目は #70 と完全一致
  - `SHOW SESSION`・`SHOW STATS` は Athena が拒否（START_FAILED）
  - `SHOW CREATE VIEW` は SKIPPED（DB にビューが無い）
  - 実測で binary だった 4 形の判定を広げた（ミューテーションの記録から、符号付き `SELECT -1`・指数 `SELECT 1.5E0`・裸の別名 `SELECT 1 i` が含まれる。自己レビューの分岐には引用符付き識別子もある）
  - `SELECT 1;` は本物 binary（Trino が弾くので判定は変えない）
  - `SHOW FUNCTIONS` は Content-Type を合わせた。本物は `<id>.csv`・見出し行つき・SubstatementType `SHOW_FUNCTIONS`（#80 で対応）
- 備考: 各形の値の全表はノートに無く、生データと issue コメントにある。どの 4 形が binary だったかはノートから完全には読み取れない（上の推定を参照）

### `SHOW CREATE VIEW` の Content-Type（対照は Iceberg のテーブルへの `SHOW CREATE TABLE`）
- 日付: 2026-09-24 ／ issue: #146（バッチは #113。未実測にしたのは #76） ／ スクリプト: `tools/measure/unmeasured-batch/run.sh`（項目 `r4`） ／ 生データ: `$HOME/athena-unmeasured-batch-measurements/run-20260924-004554/r4/`
- 相手: 本物の Athena（engine version 3、workgroup `primary`、Catalog `AwsDataCatalog`、Database `<DB>`）
- 投げたもの: `CREATE VIEW <DB>.athena_local_probe_113_r4_view AS SELECT 1 AS n`、`SHOW CREATE VIEW <DB>.athena_local_probe_113_r4_view`。対照に `CREATE TABLE <DB>.athena_local_probe_113_r4_table WITH (table_type = 'ICEBERG', location = '<OUTPUT>tables-probe-113-r4/', is_external = false) AS SELECT 1 AS n`、`SHOW CREATE TABLE <DB>.athena_local_probe_113_r4_table`
- 返ったもの:

  | 文 | State | StatementType / SubstatementType | 本体 | `.metadata` | Content-Type（本体 / `.metadata`） | `GetQueryResults` |
  | --- | --- | --- | --- | --- | --- | --- |
  | CREATE VIEW | SUCCEEDED | DDL / CREATE_VIEW | `<id>.txt` 0B | 無し | binary/octet-stream / - | 列も行も無し、`UpdateCount` 無し |
  | **SHOW CREATE VIEW** | SUCCEEDED | UTILITY / SHOW_CREATE_VIEW | `<id>.txt` 69B | **312B の base64 の不透明な形式**（戻すと 233B、先頭 9 バイト `01 23 a1 d9 80 50 19 8b 77`） | **binary/octet-stream / binary/octet-stream** | 2 行、列 `create view`（`varchar`、Precision 0、CaseSensitive false）、`UpdateCount` 0 |
  | CTAS（Iceberg） | SUCCEEDED | DDL / CREATE_TABLE_AS_SELECT | 無し（`tables/<id>`） | 81B | - / application/octet-stream | `UpdateCount` 1 |
  | **SHOW CREATE TABLE（Iceberg）** | SUCCEEDED | UTILITY / SHOW_CREATE_TABLE | `<id>.txt` 268B | **332B の base64 の不透明な形式**（戻すと 249B、先頭 9 バイトは上と同じ） | **binary/octet-stream / binary/octet-stream** | 9 行、列 `createtab_stmt`（`string`）、`UpdateCount` 0 |

  - SHOW CREATE VIEW の本体: `CREATE VIEW <DB>.athena_local_probe_113_r4_view AS\nSELECT 1 n`（末尾に改行は無い。69B は実名での長さ）
  - SHOW CREATE TABLE の本体は 9 行: `CREATE TABLE <DB>.athena_local_probe_113_r4_table (`、`  n int)`、`LOCATION '<OUTPUT>tables-probe-113-r4'`、`TBLPROPERTIES (`、`  'table_type'='iceberg',`、`  'compression_level'='3',`、`  'format'='PARQUET',`、`  'write_compression'='ZSTD'`、`);`（末尾に改行は無い。`LOCATION` の末尾の `/` は落ちている）
  - どちらの SHOW CREATE も `Statistics` に `QueryPlanningTimeInMillis` が無い
- 備考: 同じ run の x1（[statements.md](statements.md) の「キーワードの間のブロックコメント（DESCRIBE・SHOW 4 文・MSCK REPAIR TABLE・CREATE EXTERNAL TABLE）」）でも、別のビューへの `SHOW CREATE VIEW` が本体 69B・`.metadata` 312B・binary で同じだった。**対照の `SHOW CREATE TABLE` は、既存の記録と食い違う**: #1（2026-09-16、上の「`.txt` の Content-Type」と「`.txt` の中身と置かれ方（4 回目）」）は本体 application・`.metadata` 88B の素の protobuf・`UpdateCount` 無し、#70（2026-09-23、上の「結果ファイルの Content-Type の規則」）は application。今回は Iceberg のテーブルで binary・不透明な形式・`UpdateCount` 0。#1・#70 の対象テーブルの形式はこのファイルに記録が無い。どちらを採るか（テーブルの形式で割れるのか）は未決（→ 下の「`SHOW CREATE TABLE` の Content-Type はテーブルの形式で割れる」で決着。#151）

### `SHOW CREATE TABLE` の Content-Type はテーブルの形式で割れる（Hive／Iceberg × 素の CREATE／CTAS の対照）
- 日付: 2026-09-24 ／ issue: #151 ／ スクリプト: `tools/measure/unmeasured-batch/run.sh`（項目 `r4` と `r5`。`ONLY=r4,r5`） ／ 生データ: `$HOME/athena-unmeasured-batch-measurements/run-20260924-062232/{r4,r5}/`
- 相手: 本物の Athena（engine version 3、workgroup `primary`、Catalog `AwsDataCatalog`、Database `<DB>`）。上の #146 の r4 と同じ条件
- 投げたもの: 同じラウンドに、形式（Hive／Iceberg）と作り方（素の CREATE／CTAS）を 1 つずつ変えた 4 テーブルへの `SHOW CREATE TABLE` と、r4 の `SHOW CREATE VIEW`。Hive 外部テーブルは `CREATE EXTERNAL TABLE <DB>.<t> (n int) LOCATION '<OUTPUT>tables-probe-151-r5-hive-ext/'`、Hive CTAS は `CREATE TABLE <DB>.<t> AS SELECT 1 AS n`、Iceberg の素の CREATE は `CREATE TABLE <DB>.<t> (n int) LOCATION '<OUTPUT>tables-probe-151-r5-ice-plain/' TBLPROPERTIES ('table_type'='ICEBERG')`、Iceberg CTAS は r4 と同じ。形式は `SHOW CREATE TABLE` の本文（Hive は `ROW FORMAT SERDE`／`STORED AS`、Iceberg は `'table_type'='iceberg'`）で裏取り
- 返ったもの（18 文すべて SUCCEEDED。後始末の DROP 5 本も SUCCEEDED）:

  | 文 | 対象 | SubstatementType | 本体 | `.metadata` | Content-Type（本体 / `.metadata`） | `UpdateCount` |
  | --- | --- | --- | --- | --- | --- | --- |
  | SHOW CREATE VIEW | ビュー（`CREATE VIEW ... AS SELECT 1 AS n`） | SHOW_CREATE_VIEW | `<id>.txt` 69B | 312B の不透明な形式 | binary / binary | 0 |
  | SHOW CREATE TABLE | Hive 外部テーブル（素の CREATE） | SHOW_CREATE_TABLE | 447B | 88B の素の protobuf（先頭 `0a 24` + QueryExecutionId） | application / application | 無し（null） |
  | SHOW CREATE TABLE | Hive CTAS | SHOW_CREATE_TABLE | 710B | 88B の素の protobuf | application / application | 無し（null） |
  | SHOW CREATE TABLE | Iceberg 素の CREATE | SHOW_CREATE_TABLE | 233B | 332B の不透明な形式 | binary / binary | 0 |
  | SHOW CREATE TABLE | Iceberg CTAS（r4） | SHOW_CREATE_TABLE | 268B | 332B の不透明な形式 | binary / binary | 0 |

- 採用: **テーブルの形式で割れる。** 作り方（素の CREATE／CTAS）では変わらない。#1（2026-09-16）・#17・#52・#70・#76 の Hive の外部テーブルの記録（application・素の protobuf 88B・`UpdateCount` 無し）と、#146（2026-09-24）の Iceberg の記録（binary・不透明な形式・`UpdateCount` 0）はどちらも正しく、食い違いの原因は対象テーブルの形式。#1・#70 の対象は生データの本文（`ROW FORMAT SERDE ...ParquetHiveSerDe`）から Hive と裏付けられる（`$HOME/athena-txt-measurements/run-20260916-090202/show-create-table.*`、`$HOME/athena-content-type-measurements/run-20260923-043027/c10-show-create-table.*`）
- 備考: Iceberg の `SHOW CREATE TABLE` と `SHOW CREATE VIEW` は `Statistics` に `QueryPlanningTimeInMillis` が無く、`SHOW TABLES` などと同じエンジン側の経路に見える（機構の推測）。Hive の `SHOW CREATE TABLE` の `UpdateCount` が無い（null）のは `DESCRIBE` と同じで、athena-local は DDL 以外を 0 にしているので Hive のこの 2 文ではずれる（#151 で起票）

**食い違い: 結果ファイルの Content-Type**

- 2026-09-16（#1、上の「`.txt` の Content-Type」）: `.txt` が `binary/octet-stream` と `application/octet-stream` に割れた。`UpdateCount` の有無と一致
- 2026-09-17（#5、「文ごとの置かれ方の一覧」）: `.csv` は 6 件中 5 件が application、`SELECT 1` だけ binary。`.metadata` は 12 件中 10 件が application（件数は #5 の設計判断の記述から）
- 2026-09-18（#17、[statements.md](statements.md) の「範囲外の発見」）: `SELECT` の `.csv` が binary
- #24（再解析。日付の記載なし）: 同じラウンドの `SELECT 1`（select-nocolname）の `.metadata` も binary（[metadata.md](metadata.md)）
- 2026-09-22（#65、[statements.md](statements.md) の「`TABLE t` 文の分類と結果ファイル」の備考）: `SELECT 1` の `.csv`／`.metadata` と `SHOW TABLES` の `.metadata` が binary
- 2026-09-23（#70・#76）: 同じ SQL は常に同じ値。割れていたのは SQL の違いで、規則は上の表
- 採用: #70 の規則（2026-09-23）。#1（2026-09-16）と #5（2026-09-17、ユーザーの判断 5）の「多数派を採る」固定値を置き換えた。未測定の形を application に落とすのは #70 でのユーザーの選択。

**食い違い: CREATE DATABASE／DROP DATABASE の UpdateCount**

- 2026-09-16（#1 の 1 回目、上の「`.txt` の中身と置かれ方（1 回目）」）: `UpdateCount` は返らない
- 2026-09-16（#1 の 4 回目、上の「`.txt` の Content-Type」）: 「`0` で返るその他」に CREATE DATABASE／DROP DATABASE が入る
- 2026-09-18（#17、[statements.md](statements.md) の「先頭コメント付きの文ごとの見え方」）: CREATE DATABASE／DROP DATABASE とも `UpdateCount` を省く
- 採用: 判断の記録は無い（#1 のノートにこの食い違いの説明は無い）。

### UTILITY 文の `UpdateCount` と結果ファイルはテーブルの形式で割れる（DESCRIBE・SHOW COLUMNS・SHOW TBLPROPERTIES・SHOW CREATE TABLE × Hive／Iceberg）
- 日付: 2026-09-24 ／ issue: #160 ／ スクリプト: `tools/measure/unmeasured-batch/run.sh`（項目 `u1`。本体は `tools/measure/unmeasured-batch/items-update-count.sh`） ／ 生データ: `$HOME/athena-unmeasured-batch-measurements/run-20260924-095149/u1/`
- 相手: 本物の Athena（engine version 3、workgroup `primary`、Catalog `AwsDataCatalog`、Database `<DB>`）
- 投げたもの: 同じラウンドに Hive の外部テーブル（`CREATE EXTERNAL TABLE <DB>.<t> (n int) LOCATION '<OUTPUT>tables-probe-160-u1-hive-ext/'`）と Iceberg の素の CREATE（`CREATE TABLE <DB>.<t> (n int) LOCATION '<OUTPUT>tables-probe-160-u1-ice-plain/' TBLPROPERTIES ('table_type'='ICEBERG')`）を作り、両方に `DESCRIBE`・`SHOW COLUMNS FROM`・`SHOW TBLPROPERTIES`・`SHOW CREATE TABLE` を投げた（r5 と同じ作り方と後始末）
- 返ったもの（16 文すべて SUCCEEDED。`GetQueryResults` の `UpdateCount` は CLI の応答でキーはあり `null`）:

  | 文 | 対象 | SubstatementType | 本体 | `.metadata` | Content-Type（本体 / `.metadata`） | `UpdateCount` |
  | --- | --- | --- | --- | --- | --- | --- |
  | DESCRIBE | Hive 外部テーブル | DESCRIBE_TABLE | `<id>.txt` 62B | 152B の素の protobuf（先頭 `0a 24` + QueryExecutionId） | application / application | 無し（null） |
  | DESCRIBE | Iceberg | DESCRIBE_TABLE | `<id>.txt` 117B | **568B の base64 の不透明な形式**（先頭 `AR4A…`） | **binary / binary** | **0** |
  | SHOW COLUMNS | Hive 外部テーブル | SHOW_COLUMNS | 20B | 312B の不透明な形式 | binary / binary | 0 |
  | SHOW COLUMNS | Iceberg | SHOW_COLUMNS | 1B | 312B の不透明な形式 | binary / binary | 0 |
  | SHOW TBLPROPERTIES | Hive 外部テーブル | SHOW_TABLE_PROPERTIES | 46B | 460B の不透明な形式 | binary / binary | 0 |
  | SHOW TBLPROPERTIES | Iceberg | SHOW_TABLE_PROPERTIES | 22B | 440B の不透明な形式 | binary / binary | 0 |
  | SHOW CREATE TABLE（対照） | Hive 外部テーブル | SHOW_CREATE_TABLE | 447B | 88B の素の protobuf | application / application | 無し（null） |
  | SHOW CREATE TABLE（対照） | Iceberg | SHOW_CREATE_TABLE | 233B | 332B の不透明な形式 | binary / binary | 0 |

- 採用: **`DESCRIBE` も `SHOW CREATE TABLE` と同じくテーブルの形式で割れる**（Hive は null・application・素の protobuf、Iceberg は 0・binary・不透明）。`SHOW COLUMNS`／`SHOW TBLPROPERTIES` は形式によらず 0・binary。「`UpdateCount` が無い ＝ application ＝ 素の protobuf」の相関はこの 16 文でも崩れない。athena-local は #160 で `DESCRIBE` にも形式の問い合わせを使い、`UpdateCount` を完了時に決めるようにした
- 備考: `DESC`、`DESCRIBE EXTENDED`／`FORMATTED`、`DESCRIBE t PARTITION (...)`／列指定、ビューへの `DESCRIBE` は測っていない（[../unmeasured.md](../unmeasured.md)）

### キーワードの直後に空白が無い形の Content-Type（詳細は statements.md）
- 空白の有無で置き場所・Content-Type・`.metadata` が一致することを 2026-09-25 に実測した（issue #200）。表は分類が主題のため [statements.md](statements.md) の「キーワードの直後に空白が無い形（`SELECT(1)` など）」に置いてある
- 同じラウンドで分かった、語の境界と無関係な既存の差: `SELECT (1)`（括弧付きリテラル）は本物で binary、athena-local は application（[#205](https://github.com/aoyagikouhei/athena-local/issues/205)、[docs/result-files.md](../../result-files.md) に記載済み）

## 値の表記

`GetQueryResults` と `.csv` の本体に出る値の文字列。

### 複合型の中の `varbinary`
- 日付: 2026-09-24 ／ issue: #146（バッチは #113） ／ スクリプト: `tools/measure/unmeasured-batch/run.sh`（項目 `x2`） ／ 生データ: `$HOME/athena-unmeasured-batch-measurements/run-20260924-004554/x2/`
- 相手: 本物の Athena（engine version 3、workgroup `primary`、Catalog `AwsDataCatalog`、Database `<DB>`）
- 投げたもの: 対照 `SELECT X'0102' AS v`、`SELECT ARRAY[X'0102', X'03'] AS v`、`SELECT MAP(ARRAY['k'], ARRAY[X'0102']) AS v`、`SELECT CAST(ROW(X'0102') AS ROW(b varbinary)) AS v`
- 返ったもの: 4 本とも SUCCEEDED、DML / SELECT、`<id>.csv`、Content-Type は本体・`.metadata` とも application/octet-stream

  | 文 | `GetQueryResults` の値 | `.csv` の本体 | `ColumnInfo.Type` | `.csv.metadata` |
  | --- | --- | --- | --- | --- |
  | `X'0102'`（対照） | `01 02` | `"v"\n"01 02"\n`（12B） | `varbinary`（Precision 1073741824） | 66B（7 = 1073741824、8 = 0、9 = 3、10 = 0） |
  | `ARRAY[X'0102', X'03']` | `[[B@2545d692, [B@2635f945]` | `"v"\n"[[B@2545d692, [B@2635f945]"\n`（33B） | `array` | 52B（9 = 3 だけ） |
  | `MAP(ARRAY['k'], ARRAY[X'0102'])` | `{k=[B@783cdbdf}` | `"v"\n"{k=[B@783cdbdf}"\n`（22B） | `map` | 50B（9 = 3 だけ） |
  | `CAST(ROW(X'0102') AS ROW(b varbinary))` | `{b=[B@4930b8c}` | `"v"\n"{b=[B@4930b8c}"\n`（21B） | `row` | 50B（9 = 3 だけ） |

  - 複合型の中の `varbinary` は 16 進（`01 02`）にならず、`[B@` に 16 進の数字が続く文字列（Java の `byte[]` の `toString()` の形）で出た。本体と `GetQueryResults` の値は同じ文字列
- 備考: `[B@` の後ろの数字が実行ごとに変わるかは、同じ SQL を 2 回流していないので生データに無い
