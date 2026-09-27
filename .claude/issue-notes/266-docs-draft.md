# #266 の docs の下書き（先にマージされた #257・#260 の上に rebase してから当てる）

## CHANGELOGS.md [Unreleased] / Changed（#248 の項目 "Under an S3 Tables context catalog, more Hive `CREATE TABLE` forms ..." の直後）
- Under an S3 Tables context catalog, `EXTERNAL` without `LOCATION` is rejected
  with real Athena's message whatever clauses follow, and `STORED AS` without
  `LOCATION` fails like real Athena also on two-part and `AwsDataCatalog`
  names and with `IF NOT EXISTS`, `COMMENT`, `PARTITIONED BY` or
  `TBLPROPERTIES`; a `CREATE TABLE ... LOCATION` into a catalog Trino does not
  have gets `DATACATALOG_NOT_FOUND` also with `EXTERNAL`, `IF NOT EXISTS` or
  other clauses ([docs](docs/caveats.md#plain-create-table)).

## docs/caveats.md:467-468（表の 2 行目）
旧: | `CREATE EXTERNAL TABLE [IF NOT EXISTS] <name> (<columns>) [STORED AS <format>] [TBLPROPERTIES ('<k>'='<v>', ...)]` (no `LOCATION`) | `External keyword not supported for table type ICEBERG` |
新: | `CREATE EXTERNAL TABLE [IF NOT EXISTS] <name> [(<columns>)] [<the clauses above>] [STORED AS <format>] [TBLPROPERTIES ('<k>'='<v>', ...)]` (no `LOCATION`) | `External keyword not supported for table type ICEBERG` |
（表の直後の "with `LOCATION` it may also be a one-part name in backquotes" → "it may also be a one-part name in backquotes"）

## docs/caveats.md:484-493（STORED AS の段落）置き換え
  `CREATE TABLE <name> [(<columns>)] [COMMENT '<c>'] [PARTITIONED BY (<columns>)]
  STORED AS <format> [TBLPROPERTIES (...)]` without `LOCATION`, with or without
  `IF NOT EXISTS`, on a one- or two-part name, a one-part name in backquotes or
  a three-part one whose first part is `AwsDataCatalog` in a case other than
  all lower case, is accepted and fails like real Athena with `Iceberg create
  table statement does not allow STORED AS/BY` (`ErrorCategory` 2, `ErrorType`
  1200), without being sent to Trino and without result files (measured
  2026-09-27, [#266](https://github.com/aoyagikouhei/athena-local/issues/266)).
  With `ROW FORMAT` real Athena answers `does not allow ROW FORMAT` instead,
  and on an all-lower-case `awsdatacatalog.<db>.<table>` it answers
  `Unsupported ddl with 2 catalogs` at start; athena-local still returns
  Trino's syntax error for both
  ([#270](https://github.com/aoyagikouhei/athena-local/issues/270)). With
  `CLUSTERED BY`, or on a three-part name in another catalog, `STORED AS` was
  not measured and still gets Trino's syntax error. So do Hive clauses not
  listed above (`WITH SERDEPROPERTIES`, `ESCAPED BY`, `SORTED BY`, `STORED AS
  INPUTFORMAT ... OUTPUTFORMAT`, ...), which were not measured either.

## docs/caveats.md:494-503（DATACATALOG_NOT_FOUND の段落）置き換え
- **A three-part name whose catalog does not exist is rejected with
  `DATACATALOG_NOT_FOUND` also with `LOCATION`.** Under any context catalog,
  `CREATE [EXTERNAL] TABLE [IF NOT EXISTS] <catalog>.<database>.<table> ...
  LOCATION '<path>'` whose unquoted first part is not `awsdatacatalog` answers
  `Catalog '<the first part as written>' does not exist` when Trino has no such
  catalog, before the syntax check, whatever clauses the statement has
  ([#248](https://github.com/aoyagikouhei/athena-local/issues/248),
  [#266](https://github.com/aoyagikouhei/athena-local/issues/266), measured
  2026-09-27). With a catalog Trino does have (including a `TRINO_CATALOG_MAP`
  alias), the statement still gets Trino's syntax error; under the default
  context catalog real Athena answers `Unsupported ddl with 2 catalogs` for
  `EXTERNAL` and `External keyword required for table type HIVE` without it
  ([#278](https://github.com/aoyagikouhei/athena-local/issues/278)).

## docs/dev/unmeasured.md:19-20（置き換え）
- [ ] Hive の `CREATE TABLE ... LOCATION` で、LAMBDA・FEDERATED 型の連携カタログを 1 部目か Context にした形（#266 は GLUE 型で測った）、実在する別カタログの Context で `AwsDataCatalog.<db>.<t>` に作った表がどちらのカタログに入るか（z3）。athena-local は Trino にカタログがあれば構文チェックに任せる（#266、2026-09-27）
- [ ] S3 Tables の Context の Hive の `CREATE TABLE` で、LOCATION の無い `STORED AS` に `CLUSTERED BY` が付く形・ほかのカタログの 3 部、Iceberg で有効な `TBLPROPERTIES`、上の表に無い Hive の句（`WITH SERDEPROPERTIES`・`ESCAPED BY`・`SORTED BY`・`STORED AS INPUTFORMAT ... OUTPUTFORMAT` など。`read` が読まないので構文チェックに任せる）。athena-local は構文チェックに任せる（#266、2026-09-27）

## docs/dev/measurements/statements.md（#251 の 2 ラウンド目の節の後に新設）
### S3 Tables の Context の Hive の CREATE TABLE の句の組み合わせ・実在しないカタログ・実在する別カタログ（#266）
- 日付: 2026-09-27（UTC 2026-09-26 22:15・22:36）／ issue: #266 ／ スクリプト: `tools/measure/unquoted-ddl.sh`（`ROUND=13`・`ROUND=14`、`CREATE_GLUE_CATALOG=1`）／ 生データ: `$HOME/athena-unquoted-ddl-measurements/run-20260926-221348`・`run-20260926-223637`
- 相手: 本物の Athena（`AwsDataCatalog`・S3 Tables のカタログ `s3tablescatalog/<bucket>`・自分のアカウントの Glue を指す GLUE 型のデータカタログ `<G>`（両ラウンドで作って最後に消した））
- 投げたもの: ROUND=13 が 60 回（t・y・u・v・w・x 群と vc1・vc4）、ROUND=14 が 28 回（z 群と、受理された表の DROP）
- 返ったもの: .claude/issue-notes/266.md の「実測の結果」の表を写す（t0〜t10・t0s〜t9s・y1〜y5・u0〜u7・v0〜v9・vc1・vc4・w0〜w10・x1〜x4・xc・z0〜z17）
- 採用した判断: `hive.rs` の 3 つの判定から #248 で測った形だけに絞った条件を外す（EXTERNAL の句・IF NOT EXISTS・列の並び・バッククォート、STORED AS の名前の形・句、`location_catalog` の EXTERNAL・句）。STORED AS は ROW FORMAT・CLUSTERED BY と組む形とちょうど小文字の `awsdatacatalog` の 3 部を外す（#270・未測定）。既定の Context の Hive の DDL（x3・xc など）は #278、S3 Tables の Context の ROW FORMAT などは #270、CREATE EXTERNAL TABLE の Query のカタログの落ちは #271
- 備考: ノートの表と生データ（`<label>.start.err`・`<label>.execution.json`・`<label>.reason.txt`）を全項目で突き合わせ、食い違いは無かった

## docs/dev/decisions.md（#227 の項の近く。#248 の項が無いので新設）
- S3 Tables の Context の Hive の `CREATE TABLE` の判定（`hive.rs`）は、#248 で測った形だけに絞った条件を #266 の実測で外した。判定に要る句（CLUSTERED BY・ROW FORMAT）だけを `Hive` に持ち、ほかの句は `read` の中で読み分けて捨てる（使わないフィールドを持たない。#270 で要るものを足す）。既定の Context の Hive の DDL は判定も配線も新しいので #278 に分けた（ユーザーの判断。#257 と同じ `start_checks.rs` の先頭を触る）。（#266、2026-09-27）
