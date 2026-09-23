# `.metadata` の中身

結果ファイルの隣に置かれる `.metadata`（`<id>.csv.metadata`、`<id>.txt.metadata`、`<id>.metadata`、`tables/<id>.metadata`）の中身。どの文で置かれるかと Content-Type は [result-files.md](result-files.md)。書き方は [README.md](README.md)。

対応する利用者向けの章: [docs/result-files.md](../../result-files.md) の「Companion `.metadata` files」、[docs/caveats.md](../../caveats.md) の「Result files and `.metadata`」。

## protobuf のフィールド

### `.txt.metadata` の復号（#1 の生データから）
- 日付: 2026-09-17（採取は #1 の 2026-09-16） ／ issue: #5 ／ スクリプト: 無し（統括役が復号器 `pbdecode.py` で復号。採取は #1 の `tools/measure/txt-result.sh`（旧 `1-measure-txt.sh`）） ／ 生データ: `$HOME/athena-txt-measurements`
- 相手: 本物の Athena
- 投げたもの: #1 で採取した `.txt.metadata` を protobuf として復号
- 返ったもの: 形式は 2 系統に割れた。
  1. **素の protobuf**：DESCRIBE（152B）、EXPLAIN（79B）、SHOW CREATE TABLE（88B）、DROP TABLE（41B）。`GetQueryResults` が `UpdateCount` を返さない文と一致する。
     - field 1（string）: クエリ ID。DESCRIBE と SHOW CREATE TABLE は Athena の `QueryExecutionId`（UUID）。EXPLAIN と DROP TABLE はエンジンの ID（`20260916_000544_00027_jemvf` の形。Trino のクエリ ID と同じ形）。
     - field 2（string）: DROP TABLE だけ `DROP TABLE` の文字列。他の文には無い。
     - field 4（message、repeated）: 列ごとに 1 つ。`ColumnInfo` と一対一。
       - 1 CatalogName（`hive`）、4 Name、5 Label、6 Type、7 Precision（varint）、8 Scale（varint）、9 Nullable（varint、UNKNOWN が 3）、10 CaseSensitive（varint、true が 1）
       - 2 と 3 は観測されていない。`SchemaName` と `TableName` が空のためと推定。
       - `string` 型の列は 7・8・10 が無い（Precision 0、Scale 0、CaseSensitive false）。`varchar` 型の列は 7=371、8=0、10=1 が入る。Scale 0 が明示されているので、proto3 の既定値省略ではなく、フィールドの有無で表している（未設定なら省く）。
  2. **base64 の暗号化らしきバイト列**：SHOW TABLES / SHOW COLUMNS / SHOW DATABASES / SHOW PARTITIONS（312B）、SHOW TBLPROPERTIES（460B）。`UpdateCount` が 0 で返る文と一致する。base64 を戻すと 232B（460B は 344B）で、先頭 9 バイト `01 5a 91 c8 3d 79 26 4b cd` が全部で共通、残りは乱数に見える。復号できないので再現しない。
- 備考: 公開情報（burtcorp/athena-jdbc の `AthenaMetaDataParser.java`、iconara の gist）も同じフィールド番号（top 4 = 列、列内 1/4/5/6/7/8/9/10）と Nullable（1 NOT_NULL / 2 NULLABLE / 3 UNKNOWN、1 と 2 は未観測）を記録している。field 2 / 3 = SchemaName / TableName は推測で未観測。パーサは top の field 1 を読み飛ばす。公式の `.proto` は無い。

### `.metadata` の top-level のフィールド
- 日付: 2026-09-17 ／ issue: #5 ／ スクリプト: `tools/measure/result-metadata.sh`（旧 `5-measure-metadata.sh`） ／ 生データ: `$HOME/athena-metadata-measurements/run-20260917-175312`
- 相手: 本物の Athena
- 投げたもの: 上表の `.metadata` を復号
- 返ったもの:
  - field 1（string）: **SELECT・CTAS・INSERT・UPDATE・DELETE・DROP TABLE・EXPLAIN はエンジン ID**（`20260917_085344_00007_k6s5b` の形。Trino のクエリ ID と同じ形）。**DESCRIBE と SHOW CREATE TABLE は QueryExecutionId**。例外: `SELECT 1` だけ QueryExecutionId で、field 2 が空文字、field 3 が 0 だった（Content-Type も binary 系。エンジンを通らない特別扱いらしい。athena-local では再現しない）。
  - field 2（string）: **Trino の `updateType` と同じ文字列**。CTAS `CREATE TABLE`、INSERT `INSERT`、UPDATE `UPDATE`、DELETE `DELETE`、DROP TABLE `DROP TABLE`。SELECT / DESCRIBE / EXPLAIN / SHOW CREATE TABLE には無い。
  - field 3（varint）: **更新件数**。CTAS 1、INSERT 1、UPDATE 2、DELETE 2。`GetQueryResults` の `UpdateCount` と一致。SELECT（UpdateCount 0）には無い。DROP TABLE にも無い。
  - field 4（message、repeated）: 列。DML と CTAS は `rows bigint`（7=19、8=0、9=3、10=0）が 1 列。DROP TABLE は列なし。
  - 列の field 2 / 3（SchemaName / TableName）は実テーブルの SELECT でも無い（`ColumnInfo` も空）。
- 備考: EXPLAIN の field 1 は #1 の生データの復号（上の節）による。

### UPDATE / DELETE / MERGE の `.metadata` のバイト列（#35 の生データの読み直し）
- 日付: 2026-09-20（生データの採取日。読み直しも同日のノート） ／ issue: #41（実測は #35） ／ スクリプト: 無し（#35 の `tools/measure/insert-location.sh`（旧 `35-measure-insert-location.sh`） の生データ） ／ 生データ: `~/athena-insert-measurements/run-20260920-182735/` の `e`・`f`・`g`
- 相手: 本物の Athena（#35 のラウンドの生データを `od` で読んだ。新しい実測はしていない）
- 投げたもの: `UPDATE` / `DELETE` / `MERGE`（いずれも Iceberg。#35 の e・f・g）
- 返ったもの:

| ラベル | 文 | field 2 | 全体 |
|---|---|---|---|
| e | `UPDATE` | `12 06 "UPDATE"` | 75B |
| f | `DELETE` | `12 06 "DELETE"` | 75B |
| g | `MERGE` | `12 05 "MERGE"` | 74B |

  - #35 の実測表の MERGE だけ 74B の 1 バイト差は、field 2 の文字列長の違い
  - field 2 より後ろは 3 本ともバイト単位で同じ: `18 01` 更新件数 1、`22 22` で列 1 件の `rows bigint`、`38 13` precision 19、`40 00` scale 0、`48 03` nullable UNKNOWN、`50 00` caseSensitive 0
  - field 1 は 27 バイトのエンジンのクエリ ID で 3 本とも同じ長さ（5.md の「top-level のフィールド」の記録と整合）
  - テストの期待値は生データ g の field 2 以降とバイト単位で一致（`12054d45524745 1801` + `COLUMN_ROWS_BIGINT`）
- 備考: 当時「Trino が MERGE に `updateType: "MERGE"` を返すか」は未検証だった → #56（手元の Trino 482）で `updateType=MERGE`、count=2、field 3 より後ろが本物の `rows bigint` 列と同じバイト列、`.metadata` 74 バイトと確認済み

## 列の Precision／Scale／CaseSensitive（型ごと）

### 列の field 7 / 8 / 10 の有無（型ごと）
- 日付: 2026-09-17 ／ issue: #5 ／ スクリプト: `tools/measure/result-metadata.sh`（旧 `5-measure-metadata.sh`） ／ 生データ: `$HOME/athena-metadata-measurements/run-20260917-175312`（`select-types` の 710B など）
- 相手: 本物の Athena
- 投げたもの: 型網羅 SELECT（22 列）などの `.metadata` を復号
- 返ったもの: 値が 0 でも出す。有無は値ではなく型で決まる（仮説 F は外れ）。

  | 型（Athena の Type） | 7 Precision | 8 Scale | 10 CaseSensitive |
  | --- | --- | --- | --- |
  | tinyint 3 / smallint 5 / integer 10 / bigint 19 / double 17 / float 17 / decimal(p,s) / varchar(n) / char(n) / varbinary 1073741824 / timestamp 3 / time 3 | 出す | 出す（0 でも） | 出す（varchar と char だけ 1、他は 0） |
  | boolean | 無し | 無し | 出す（0） |
  | date | 無し | **出す（0）** | 出す（0） |
  | interval day to second | 無し | 無し | 出す（0） |
  | array / map / row / json | 無し | 無し | 無し |
  | string（Hive の DESCRIBE） | 無し | 無し | 無し |

  - 9 Nullable は常に出す（3 = UNKNOWN）。1 CatalogName `hive`、4 Name、5 Label（= Name）、6 Type は常に出す。
  - この出し分けは Trino JDBC の `ColumnInfo.setTypeInfo` の型ごとの設定（date は scale だけ、boolean / interval は displaySize だけ、複合型は何も設定しない）と同じ形。Athena が JDBC 相当の列情報を直列化していると見える。
- 備考: 未実測の型（`timestamp with time zone`、`time with time zone`、`interval year to month`、`uuid`、`ipaddress` など）は、前者 2 つを timestamp / time と同じ扱い、`interval year to month` を `interval day to second` と同じ扱い、その他を「無し / 無し / 無し」にした（推測。README に未実測と書く）。

## SHOW 系の不透明な形式

### SHOW 系の `.metadata` の形式の解析（保存済みの実測バイト列から）
- 日付: 解析は日付の記載なし（時刻 21:17〜21:25 のみ）。元データは #1（2026-09-16）・#5（2026-09-17）・#17（2026-09-18）の実測 ／ issue: #24 ／ スクリプト: `tools/measure/opaque-metadata-form.sh`（旧 `24-verify-metadata-form.sh`）（README の数値を保存済みの実測バイト列から再導出する） ／ 生データ: `$HOME/athena-txt-measurements` ほか
- 相手: 本物の Athena（生データは `$HOME` に残っていた #1・#5・#17 の実測バイト列。AWS には触れずに解析）
- 投げたもの: —（既存の実測の再解析）
- 返ったもの:

| 問い | 答え |
| --- | --- |
| この形式が何か | **特定できず**。312 文字の base64（`SHOW TBLPROPERTIES` だけ 460）で、戻すと結果の中身によらず 233 バイト（同 345）固定。先頭バイト `0x01` だけが全ラウンドで一定で、それ以降はラウンドをまたぐと変わり、同じラウンドの中でも割れることがある（2026-09-17 の 2 件）。同じ表を返す `SHOW TABLES` を 2 回実行してもバイト列が変わる。S3 のオブジェクトメタデータに手がかりは無い（`ServerSideEncryption: AES256` = SSE-S3 のみで、クライアント側暗号化のヘッダは無い）。暗号化らしいという以上は言えない |
| `SHOW` 系すべてか `SHOW TABLES` だけか | `SHOW TABLES` / `SHOW DATABASES` / `SHOW COLUMNS` / `SHOW PARTITIONS` / `SHOW TBLPROPERTIES` の 5 文（#5 が 2026-09-16 の生データで確認済み）。**`SHOW CREATE TABLE` は例外で素の protobuf**（`DESCRIBE` と同じ）。結果本体の `.txt` は平文 |
| クライアントが読めているか | #5 の実機検証（2026-09-17）で、Athena JDBC 3.8.1 の既定 `ResultFetcher=auto` が athena-local の `SHOW TABLES` の `.txt.metadata` を実際に GET し、素の protobuf を例外なく読んだ |

- 備考: 「クライアントが読めているか」の行は本物ではなく athena-local 相手の JDBC 3.8.1 の観測（本物の不透明な形式を JDBC が読めるかではない）。`.metadata` の Content-Type が `binary/octet-stream` に割れる件は、同じラウンドで protobuf の `SELECT 1`（`select-nocolname`）も `binary` だったので、#1 で既知の揺れであって `SHOW` 固有ではない。README に書きすぎていた 2 文（「先頭 9 バイトはラウンド内で共通」「JDBC が 3 モードすべてで metadata を読んだ」）を実測の範囲に戻した。
