# Trino

**本物の Athena ではない。** 手元の Trino（482、一部 483）で測ったもの。athena-local が Trino に何を投げられるか、Trino が何を返すかの前提として残す。本物の Athena の値と比べるときは、対応する本物側の実測を各ファイルで見る。書き方は [README.md](README.md)。

## テーブルの形式と updateType

### テーブル形式の問い合わせ手段と updateType（Trino 側）
- 日付: 2026-09-20 ／ issue: #39 ／ スクリプト: `tools/e2e/trino-probe/probe.sh`（旧 `39-trino-probe/probe.sh`）
- 相手: 手元の Trino 482（`trinodb/trino:482`、足場 `tools/e2e/trino-probe/`（旧 `39-trino-probe/`））
- 投げたもの: `SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = '<カタログ名>'`、`DROP TABLE`、`ALTER TABLE ... ADD COLUMN`。ほかの手段（`SHOW CATALOGS`・`SHOW CREATE TABLE`・`information_schema.tables`・`$properties`・`system.metadata.table_properties`）も比較
- 返ったもの:
  - `connector_name` が `hive` / `iceberg` を返す。Trino の Hive コネクタと Iceberg コネクタは別カタログとしてしか共存できず、1 つのカタログに両形式が混在することは構造上あり得ない
  - ほかの手段は、読めないか、テーブル名と存在確認が要るか、本文の解析が要るかで、いずれも `connector_name` に劣る
  - `updateType`: `DROP TABLE` に `"DROP TABLE"`（本物の 41B の field 2 と同じ文字列）、`ALTER TABLE ... ADD COLUMN` に `"ADD COLUMN"`（Athena の `ADD COLUMNS` と綴りが違うが 38B には field 2 が無いので影響なし）。Hive と Iceberg で Trino の応答は完全に同一で、応答そのものからは形式を読み取れない
- 備考: 本物の Athena ではない

### Trino のバージョン差
- 日付: 2026-09-21 ／ issue: #39 ／ スクリプト: `tools/e2e/trino-probe/`（旧 `39-trino-probe/`） の compose（probe）
- 相手: 手元の Trino 482 / 483（`tools/e2e/trino-probe/`（旧 `39-trino-probe`） の compose を `${TRINO_TAG:-482}` で差し替え）
- 返ったもの:

| 確認項目 | Trino 482 | Trino 483 |
|---|---|---|
| `system.metadata.catalogs` の `connector_name` | `hive` / `iceberg`（小文字） | **同じ** |
| probe（形式 + 存在の 1 クエリ）: 存在する Hive | `[["hive", 1]]` | **同じ** |
| probe: 存在しない Iceberg | `[["iceberg", 0]]` | **同じ** |
| `DROP TABLE` の `updateType` | `DROP TABLE` | **同じ** |
| `ALTER ... ADD COLUMN` の `updateType` | `ADD COLUMN` | **同じ** |

- 備考: それより古いバージョンは確かめていない（`fs.local.enabled` が 482 で正式名になった等の設定差があり、`./catalog-legacy` を用意する途中で止めた）

### MERGE の updateType と `.metadata`
- 日付: 不明（ノートに日付が無い。時系列は 19:00〜19:07。#49（2026-09-22 17:2x）で 17 項目だった verify.sh が 19 項目になっているので 2026-09-22 と推定） ／ issue: #56 ／ スクリプト: `tools/e2e/minio/verify.sh`（旧 `39-e2e/verify.sh`）（ケース 9 を追加）
- 相手: 手元の Trino 482 + MinIO（`tools/e2e/minio/`（旧 `39-e2e/`） の足場、athena-local 経由）
- 投げたもの: Iceberg のテーブルへの `MERGE`
- 返ったもの: `updateType=MERGE`、count=2、field 3 より後ろが本物の Athena の `rows bigint` 列と同じバイト列。`.metadata` は 74 バイト。verify.sh 全 19 項目 PASS
- 備考: 本物の Athena ではなく Trino 相手。#41 が未検証として残した「Trino が MERGE に `updateType: "MERGE"` を返すか」を解消

### 同じ INSERT の Trino の応答
- 日付: 2026-09-23（待ち時間） ／ issue: #91 ／ スクリプト: 無し
- 相手: 手元の Trino 482
- 返ったもの: 同じ INSERT が `updateCount=0`・列 `rows` で返る

## Athena の綴りを Trino が受け付けるか

### Trino が Athena の ALTER の綴りを受け付けるか
- 日付: 2026-09-21 ／ issue: #43 ／ スクリプト: 無し（`PREPARE athena_local_syntax_check FROM\n<sql>` を投げた）
- 相手: 手元の Trino 482（`tools/e2e/trino-probe/docker-compose.yml`（旧 `39-trino-probe/docker-compose.yml`））
- 返ったもの:

| 文 | Trino 482 | athena-local 経由で到達 |
| --- | --- | --- |
| `ADD PARTITION` / `DROP PARTITION` | `SYNTAX_ERROR: mismatched input 'PARTITION'` | ✗ |
| `REPLACE COLUMNS` | `SYNTAX_ERROR: mismatched input 'REPLACE'` | ✗ |
| `SET LOCATION` | `SYNTAX_ERROR: mismatched input 'LOCATION'` | ✗ |
| `RENAME TO` / `DROP COLUMN` / `ADD COLUMN` | 構文エラーなし | ✓ |

  - `SET TBLPROPERTIES` は Trino の `SET PROPERTIES` と書けば実行できるが、分類のキーワードが Athena の綴りなので `SubstatementType` は付かない
- 備考: 本物の Athena ではない。到達可能性は README の表・Caveats・CHANGELOG の 3 箇所に明記した

### 同じ 11 通りの SQL を Trino が受け付けるか
- 日付: 不明（実測待ちの間） ／ issue: #52 ／ スクリプト: 無し
- 相手: 手元の Trino 482
- 返ったもの: 同じ 11 通りの SQL が受け付けられる
- 備考: 手元の Trino も本物も通す形なので、README の Caveat に本物だけが弾く形（SHOW CREATE TABLE・Hive 側の ALTER）を追記した

### 待ち時間の手元確認
- 日付: 2026-09-23（06:51〜06:52） ／ issue: #76 ／ スクリプト: 無し
- 相手: 手元の Trino 482（18 形の PREPARE）
- 返ったもの: ノートに結果の詳細なし（`SELECT 1;` を Trino が弾くことはここから）
- 備考: 推定を含む

### 同じ文の Trino の挙動
- 日付: 2026-09-23（待ち時間） ／ issue: #93 ／ スクリプト: 無し
- 相手: 手元の Trino 482
- 返ったもの: Iceberg は新規・置換とも通り、Hive は `This connector does not support replacing tables` で失敗
- 備考: 本物ではない

## EXPLAIN の列の型と末尾の改行

### Trino の EXPLAIN 列の型
- 日付: 不明（抽出では直前の #68 の項目と「同上」。そちらは 2026-09-22 と推定） ／ issue: #68 ／ スクリプト: 無し
- 相手: 手元の Trino 482（athena-local 経由の GetQueryResults も確認）
- 返ったもの: Trino 482 は `EXPLAIN` の列を `varchar(400)`（typeSignature の arguments に 400、非 ASCII を含む文では文字数）と型付けし、athena-local 経由の GetQueryResults も Precision 400 を返した。上限無し varchar の `CAST('abc' AS varchar)` は 2147483647 のまま
- 備考: 本物ではない。手元の Trino のプランは本物と同じ文字数ではない（400 と 371）

### Trino の EXPLAIN 変種の末尾の改行数
- 日付: 2026-09-23（待ち時間） ／ issue: #92 ／ スクリプト: 無し
- 相手: 手元の Trino 482
- 返ったもの: JSON / IO は 0、GRAPHVIZ は 1、ほかは 2、VALIDATE は boolean
- 備考: 本物の末尾の空行数は Trino の改行数 + 1（`split_explain_rows` の規則「全文 + `\n` を `\n` で分ける」と一致）。この +1 の対応は数値からの読み取り

## athena-local の実機確認の備考に残っていた Trino の観測

以下は athena-local 自身の実機確認（measurements には入れない）の備考に書かれていた、Trino 482 についての観測。文言は抽出ファイルのまま写した。

### `sequence` の要素数の上限と、長く走るクエリの作り方
- 日付: 2026-09-17 ／ issue: #3・#4 ／ スクリプト: 無し
- 相手: 手元の Trino 482（`trinodb/trino:482`。athena-local の実機確認の中での観測）
- 返ったもの:
  - #3: Trino 482 の `sequence` は 1 万要素を超えると `INVALID_FUNCTION_ARGUMENT: result of sequence function must not have more than 10000 entries` で即座に FAILED。RUNNING を捕まえるには `sequence(1,10000) × sequence(1,10000) × sequence(1,5)` の 3 元 CROSS JOIN（RUNNING 継続 ≈17.7 秒）が使えた。`× sequence(1,50)` は 120 秒経っても終わらなかった。
  - #4: 長いクエリは `sequence(1,10000) × sequence(1,10000) × sequence(1,5)` の 3 段 CROSS JOIN で約 21 秒（#3 では ≈17.7 秒）。

### `memory` コネクタは UPDATE／DELETE／MERGE を持たない
- 日付: 2026-09-17 ／ issue: #5 ／ スクリプト: 無し
- 相手: 手元の Trino 482（`memory` カタログ。athena-local の実機確認の中での観測）
- 返ったもの: `memory` コネクタは UPDATE / DELETE / MERGE を持たない（`This connector does not support updates`）。
