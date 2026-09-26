## 何を直したか
S3 Tables の Context の Hive の `CREATE TABLE` の残りと、LOCATION 付きの実在しないカタログを、#248 の実測（2026-09-27 ROUND=10、s1〜s18）どおりにした。
- S3 Tables の Context の `Table location can not be specified ...` を、表の `COMMENT`・`CLUSTERED BY ... INTO <n> BUCKETS`・`ROW FORMAT SERDE`・`DELIMITED` の区切りの句（FIELDS／COLLECTION ITEMS／MAP KEYS／LINES／NULL DEFINED AS）・`TBLPROPERTIES` の 2 組以上・1 部のバッククォートの表名にも当てる（s1〜s6・s11・s16）
- LOCATION の無い `CREATE EXTERNAL TABLE` の `External keyword not supported ...` を、2 部・`AwsDataCatalog` の 3 部・`STORED AS` 付き・`TBLPROPERTIES` 付きにも当てる（s7〜s10）
- S3 Tables の Context の LOCATION の無い `CREATE TABLE <t> (列) STORED AS <語>` を、Trino に送らずに開始して FAILED にする（ErrorCategory 2・ErrorType 1200、`Iceberg create table statement does not allow STORED AS/BY`、結果ファイル無し。n21・s15）
- Context によらず、LOCATION 付きの無引用の 3 部の名前の 1 部目のカタログが Trino に無ければ、構文チェックの前に `DATACATALOG_NOT_FOUND`（`Catalog '<書いたとおり>' does not exist`）で弾く（n6・s12・s13）
- 入れ子の型の列（`row(a int)`。s17・s18）は本物も Trino の形の構文エラーだったので、今までどおり構文チェックに任せる（compose の Trino で同じ形の文言になることを足場の L10 で確かめた）

Closes #248

## なぜ壊れていたか
#229 は `hive.rs` の `s3_tables_rejection` で測った句（PARTITIONED BY・FIELDS だけの DELIMITED・STORED AS・TBLPROPERTIES 1 組）と名前（EXTERNAL は 1 部と小文字の `awsdatacatalog` の 3 部）だけを読み、ほかは Trino の構文チェックに任せていた。n6（実在しないカタログ）と n21（STORED AS）は、構文チェックの前に非同期の問い合わせや開始して FAILED にする経路が要るので範囲外にしていた。判定を Hive の句の順に 0〜1 回ずつ読む `read` に作り直し、同じ読み方から `s3_tables_stored_as`・`location_catalog` を取り出した。カタログの問い合わせは `create_table_catalog::check` の部分を `catalog_rejection` に切り出して共有した。

## 再現テスト
- `tools/dev.sh cargo test --lib hive`（`src/operation/unquoted_ddl/create_table/hive/tests.rs`。s1〜s11・s16・s15・n6 系の形を足し、直す前は 4 件が落ちた）
- `tools/dev.sh cargo test --test create_table_catalog location_付き`・`tools/dev.sh cargo test --test syntax stored_as`（直す前は 2 件が落ちた）

## 検証
- `tools/dev.sh cargo fmt --check`・`tools/dev.sh cargo clippy --all-targets --locked -- -D warnings`・`tools/dev.sh cargo test`（585 passed）
- ミューテーション: `start_checks.rs` のカタログの弾きを無効にする → s12・s13 の結合テストが落ちた。EXTERNAL の `!hive.other_clauses` を外す → 未実測の形のテストが落ちた。STORED AS の `other_clauses` を外す → STORED AS のテストが落ちた
- 実機の足場: `tools/dev.sh tools/e2e/s3-tables-location/verify.sh` に L9〜L12（COMMENT 付き・row 型の列・既定の Context の実在しないカタログ・STORED AS の FAILED）を足し、PASS=16 FAIL=0

## 利用者から見える挙動の変更
あり。`docs/caveats.md`（Plain `CREATE TABLE` の節の S3 Tables の項と、実在しないカタログの項）・CHANGELOGS.md の `[Unreleased]` を直した。実測の記録は `docs/dev/measurements/statements.md` に、内部の地図は `docs/dev/architecture.md` に写した。`hive.rs` が 400 行を超えたので、テストを `hive/tests.rs` に出した（CLAUDE.md の一覧にも足した）。
未実測（連携カタログ・Trino にだけあるカタログの 3 部 + LOCATION（s14）、句の組み合わせ、EXTERNAL に COMMENT などが付く形、STORED AS の 2〜3 部の名前など）は `docs/dev/unmeasured.md` に載せ、<出口の issue 番号> に追記した。
quick-implement のゲートでは変更サイズ（見込み 80〜130 行 → 実際は本番 <n> 行・4 ファイル）が外れた。層として計画攻撃（指摘 <n> 件・採用 <m> 件）と、止めない独立レビューを足した。

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01WpZCp9jjLn9SG6ye1kPRfh
