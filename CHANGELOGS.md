# Changelog

All notable changes to athena-local are recorded here. Versions match the
`aoyagikouhei/athena-local` image tags on Docker Hub.

Behaviour described as "measured" was compared against real Amazon Athena
(engine version 3). The first round was measured on 2026-09-14; entries added
later name the date they were measured on.

## [Unreleased]

### Changed

- `DESCRIBE` on an Iceberg table spells `timestamp with time zone` as `timestamp` and fails on a
  `time` or `uuid` column like real Athena (measured 2026-09-27) ([docs](docs/caveats.md#result-files-and-metadata)).
- `DESCRIBE EXTENDED` / `FORMATTED` (and `DESC`), with or without a column or `PARTITION (...)`,
  now run like real Athena ([docs](docs/ddl.md#describe-extended-and-describe-formatted)).
- Outside an S3 Tables context catalog, Hive's `CREATE TABLE ... LOCATION` is rejected at start
  like real Athena ([docs](docs/caveats.md#plain-create-table)).
- Under an S3 Tables context catalog, a CTAS into a missing namespace fails with real Athena's
  `NOT_FOUND` ([docs](docs/caveats.md#parameters-and-catalog-aliases)).
- Under an S3 Tables context catalog with no `Database`, a one-part `CREATE TABLE` or CTAS fails
  like real Athena when namespace `default` is missing ([docs](docs/caveats.md#plain-create-table)).
- Under an S3 Tables context catalog, a plain `CREATE TABLE` with Hive-only clauses or a
  non-Iceberg `table_type` fails like real Athena ([docs](docs/caveats.md#plain-create-table)).
- Under an S3 Tables context catalog, `CREATE TABLE AwsDataCatalog.<namespace>.<table>` reports
  `Query` and `Database` like real Athena ([docs](docs/caveats.md#plain-create-table)).
- More block-comment positions in `SHOW CREATE TABLE`, `MSCK REPAIR TABLE`, `ALTER TABLE` and
  `DESCRIBE EXTENDED` fail on a Hive table like real Athena ([docs](docs/caveats.md#block-comments-athenas-hive-parser-rejects)).
- The `ParseException` reason reads `<=`, `!=` and an unclosed quote in a leading comment like
  real Athena ([docs](docs/caveats.md#block-comments-athenas-hive-parser-rejects)).
- Under an S3 Tables context catalog, more Hive `CREATE TABLE` forms get real Athena's
  `Table location` / `External keyword` messages ([docs](docs/caveats.md#plain-create-table)).
- A Hive `CREATE TABLE <catalog>.<db>.<table> ... LOCATION` naming a missing catalog is rejected
  with `DATACATALOG_NOT_FOUND` ([docs](docs/caveats.md#plain-create-table)).
- Under an S3 Tables context catalog, `EXTERNAL` or `STORED AS` without `LOCATION` is rejected
  like real Athena in more forms ([docs](docs/caveats.md#plain-create-table)).
- An unquoted `awsdatacatalog.<database>.<table>` in `SELECT`, `INSERT`, CTAS, `CREATE VIEW` and
  `EXPLAIN` runs through the `AwsDataCatalog` alias ([docs](docs/caveats.md#parameters-and-catalog-aliases)).
- The `AwsDataCatalog` alias reaches unquoted `awsdatacatalog.` names under more context catalogs
  and in more `SELECT` name forms ([docs](docs/caveats.md#parameters-and-catalog-aliases)).
- A CTAS into `awsdatacatalog.<database>.<table>` runs through the alias under an S3 Tables context
  catalog too ([docs](docs/caveats.md#parameters-and-catalog-aliases)).
- A CTAS into a missing `awsdatacatalog.<database>` fails like real Athena, after running its
  query part on Trino ([docs](docs/caveats.md#parameters-and-catalog-aliases)).
- Under an S3 Tables context catalog, a one-part `CREATE TABLE <table>` fails like real Athena
  when the context database is not a namespace ([docs](docs/caveats.md#plain-create-table)).
- A `QueryString` holding more than one statement, such as `SELECT 1; -- c`, is rejected at
  `StartQueryExecution` with real Athena's message ([docs](docs/api.md)).
- `DESCRIBE`, `SHOW` and `ALTER` / `DROP TABLE` statements on an unquoted `awsdatacatalog.` name
  now run, and `DESCRIBE` reports `Query` and `Database` like real Athena ([docs](docs/api.md)).
- A block comment before or between the keywords of `SHOW CREATE TABLE`, `MSCK REPAIR TABLE`,
  `ALTER TABLE` or `DESCRIBE` fails like real Athena ([docs](docs/caveats.md#block-comments-athenas-hive-parser-rejects)).
- `ALTER TABLE ... DROP COLUMN` and `RENAME TO` on a Hive or missing table fail with real Athena's
  reason ([docs](docs/caveats.md#alter-table-and-format-dependent-ddl)).
- A statement with a leading or trailing `;`, such as `SELECT 1;`, runs and is normalized like
  real Athena; `;` alone is rejected ([docs](docs/api.md)).
- The `.metadata` of a literals-only `SELECT` starts with the `QueryExecutionId` like real Athena
  ([docs](docs/result-files.md#companion-metadata-files)).
- `DESCRIBE`, `DESC` and `SHOW COLUMNS` check the target table when the context catalog is a
  `TRINO_CATALOG_MAP` alias ([docs](docs/caveats.md#sql-dialect)).
- A context catalog Trino does not have also falls back for plain `CREATE TABLE`, `ADD COLUMN`,
  views and schemas (measured 2026-09-26) ([docs](docs/caveats.md#sql-dialect)).
- Unquoted, Trino-only `ALTER TABLE` spellings such as `IF EXISTS` are rejected at start with real
  Athena's message ([docs](docs/caveats.md#alter-table-and-format-dependent-ddl)).
- A plain, unquoted `CREATE TABLE` whose column list only Trino's grammar accepts is rejected at
  start with real Athena's message ([docs](docs/caveats.md#plain-create-table)).
- A plain `CREATE TABLE` with a double-quoted column or type and four-part names in more forms
  are rejected at start like real Athena (measured 2026-09-26) ([docs](docs/caveats.md#plain-create-table)).
- Under an S3 Tables context catalog, a plain `CREATE TABLE awsdatacatalog.<db>.<t>` gets real
  Athena's `Unsupported ddl with 2 catalogs` (measured 2026-09-26) ([docs](docs/caveats.md#plain-create-table)).
- A plain `CREATE TABLE` naming a missing catalog is rejected with `DATACATALOG_NOT_FOUND`, and a
  missing S3 Tables namespace fails like real Athena (measured 2026-09-26) ([docs](docs/caveats.md#plain-create-table)).
- Under an S3 Tables context catalog, `CREATE TABLE AwsDataCatalog.<namespace>.<t>` creates the
  table like real Athena (measured 2026-09-26) ([docs](docs/caveats.md#plain-create-table)).
- Under an S3 Tables context catalog, Hive's `CREATE TABLE ... LOCATION` and `CREATE EXTERNAL TABLE`
  get real Athena's messages (measured 2026-09-26) ([docs](docs/caveats.md#plain-create-table)).
- `GetQueryResults` returns `SHOW CREATE TABLE` and `SHOW CREATE VIEW` one row per line like real
  Athena (measured 2026-09-16 and 2026-09-24) ([docs](docs/api.md#supported-api)).
- `GetQueryResults` and `.metadata` carry real Athena's columns for `SHOW TABLES`, `SHOW SCHEMAS`,
  `SHOW COLUMNS` and `DESCRIBE` (measured 2026-09-24) ([docs](docs/api.md#supported-api)).
- `DESCRIBE` / `DESC` and `SHOW COLUMNS` return real Athena's padded rows, and `DESC_VIEW` on a
  view (measured 2026-09-24) ([docs](docs/result-files.md), [DDL](docs/ddl.md)).
- `SHOW CREATE TABLE` and `SHOW CREATE VIEW` name their result column like real Athena (measured
  2026-09-23 and 2026-09-24) ([docs](docs/api.md#supported-api)).
- `GetQueryResults` leaves `UpdateCount` out for every `EXPLAIN` like real Athena (measured
  2026-09-16 to 2026-09-23) ([docs](docs/api.md#supported-api)).
- `GetQueryExecution` leaves `QueryExecutionContext.Catalog` / `Database` out when the request did,
  like real Athena (measured 2026-09-24) ([docs](docs/api.md#supported-api)).
- `UpdateCount` of `DESCRIBE` and `SHOW CREATE TABLE` follows the table format like real Athena
  (measured 2026-09-24) ([docs](docs/ddl.md#ddl-that-depends-on-the-target-tables-format)).
- `DESCRIBE` and `SHOW CREATE TABLE` on an Iceberg table write their files like real Athena
  (measured 2026-09-24) ([docs](docs/ddl.md#ddl-that-depends-on-the-target-tables-format)).
- `SHOW CREATE VIEW` writes its files and reports `SubstatementType` like real Athena (measured
  2026-09-24) ([docs](docs/result-files.md#result-files)).
- A `varbinary` inside an `array`, `map` or `row` is rendered as `[B@<hex>` like real Athena
  (measured 2026-09-24) ([docs](docs/caveats.md#value-rendering)).
- A `ClientRequestToken` retry also compares `QueryExecutionContext.Catalog` like real Athena
  (measured 2026-09-24) ([docs](docs/api.md#supported-api)).
- `GetQueryExecution` returns `QueryExecutionContext.Catalog` lower-cased like real Athena
  (measured 2026-09-24) ([docs](docs/api.md#supported-api)).
- A `ClientRequestToken` longer than 128 UTF-8 bytes is rejected with real Athena's message
  (measured 2026-09-24) ([docs](docs/api.md#supported-api)).
- Error responses no longer carry an `x-amzn-errortype` header, like real Athena (measured
  2026-09-17 to 2026-09-24) ([docs](docs/caveats.md#errors-and-request-bodies)).
- `GetWorkGroup` returns `Configuration.EnableMinimumEncryptionConfiguration` as `false`
  (measured 2026-09-23) ([docs](docs/caveats.md#workgroups)).
- A CTAS whose query is `VALUES`, `TABLE` or parenthesised is `CREATE_TABLE_AS_SELECT` like real
  Athena (measured 2026-09-25) ([docs](docs/result-files.md#result-files)).
- A keyword with no space before what follows it (`SELECT(1)`, `SELECT*FROM t`, ...) classifies
  like the spaced form (measured 2026-09-25) ([docs](docs/api.md#supported-api)).
- The retention docs say the one-hour default is shorter than real Athena's (measured 2026-09-24)
  ([docs](docs/caveats.md#query-lifecycle), [docs](docs/configuration.md#configuration)).
- Caveats that said "not measured" cite the 2026-09-24 measurements ([docs](docs/caveats.md#result-files-and-metadata),
  [docs](docs/caveats.md#query-lifecycle), [docs](docs/caveats.md#errors-and-request-bodies)).
- A double-quoted table name in `DESCRIBE`, `SHOW`, `ALTER` / `DROP TABLE` or a plain
  `CREATE TABLE` is rejected with real Athena's message (measured 2026-09-25) ([docs](docs/caveats.md#sql-dialect)).
- A `SELECT` of parenthesised literals or of `- 1` writes its files as `binary/octet-stream` like
  real Athena (measured 2026-09-25) ([docs](docs/result-files.md#result-files)).
- Names of four parts or more, and more double-quoted table names, are rejected with real Athena's
  message (measured 2026-09-25) ([docs](docs/caveats.md#sql-dialect)).
- `StartQueryExecution` checks that the target of `DESCRIBE`, `DESC` and `SHOW COLUMNS` exists and
  runs it on a view (measured 2026-09-25) ([docs](docs/caveats.md#sql-dialect)).
- A context catalog Trino does not have falls back for metadata statements, and `CATALOG_NOT_FOUND`
  has `ErrorType` 1006 (measured 2026-09-25) ([docs](docs/caveats.md#sql-dialect)).
- Too many name parts in `SHOW CREATE TABLE`, `CREATE TABLE` and `SHOW TABLES IN` are rejected
  like real Athena (measured 2026-09-25) ([docs](docs/caveats.md#sql-dialect)).
- A CTAS or `INSERT` that fails on the engine gets real Athena's reason, error position included
  ([docs](docs/caveats.md#failed-queries)).

### Fixed

- A table on a connector other than `hive` or `iceberg` is no longer treated as a Hive table by
  the block-comment and `DROP COLUMN` / `RENAME TO` checks ([docs](docs/caveats.md#block-comments-athenas-hive-parser-rejects)).

## [0.5.0] - 2026-09-23

### Added

- A companion `.metadata` file is written next to the result file, for Athena
  JDBC 3.x (measured 2026-09-17)
  ([docs](docs/result-files.md#companion-metadata-files)).
- A failed DDL, `SHOW`, `DESCRIBE` or `EXPLAIN` writes `FAILED: <reason>` to
  `<id>.txt` (measured 2026-09-17) ([docs](docs/result-files.md#result-files)).
- DDL, `SHOW` and `DESCRIBE` results are written to `<id>.txt` (measured
  2026-09-16) ([docs](docs/result-files.md#result-files)).
- Columns in `<id>.txt` are joined with a tab; Athena's space padding is not
  reproduced.
- A failed `<id>.txt` upload leaves the query `SUCCEEDED` and logs one line,
  unlike the CSV, which still makes the query `FAILED`.
- `GetWorkGroup` is supported, for awswrangler and Grafana; any name is accepted
  (measured 2026-09-17) ([docs](docs/caveats.md#workgroups)).
- `ListWorkGroups` is supported, listing the new `ATHENA_LOCAL_WORK_GROUPS`
  (measured 2026-09-18) ([docs](docs/caveats.md#workgroups)).
- `StartQueryExecution` now keeps the `WorkGroup` it was given, and
  `GetQueryExecution` reports that name instead of always saying `primary`.
- `StartQueryExecution` accepts `ClientRequestToken` and makes retries
  idempotent (measured 2026-09-17) ([docs](docs/api.md#supported-api)).
- A finished query is dropped after the new `ATHENA_LOCAL_RETENTION_SECONDS`
  (default `3600`) ([docs](docs/caveats.md#query-lifecycle)).
- README documents connecting Athena JDBC 3.x through a TLS terminator
  ([docs](docs/clients.md#athena-jdbc-3x-needs-a-tls-terminator-in-front)).
- A one-line warning is printed to stderr at startup when there is no default
  output location ([docs](docs/caveats.md#clients-and-transport)).
- Four more `ALTER TABLE` forms (`REPLACE COLUMNS`, `ADD`/`DROP PARTITION`,
  `RENAME TO`) get a `SubstatementType` (measured 2026-09-21)
  ([docs](docs/caveats.md#alter-table-and-format-dependent-ddl)).

### Changed

- The `Content-Type` of result files and `.metadata` follows the statement as on
  Athena (measured 2026-09-23) ([docs](docs/result-files.md#result-files)).
- README documents where the `Precision` of the `EXPLAIN` result column comes
  from; no behaviour change ([docs](docs/api.md#supported-api)).
- `ALTER TABLE ... DROP COLUMNS` (plural) is no longer classified (measured
  2026-09-21) ([docs](docs/caveats.md#alter-table-and-format-dependent-ddl)).
- New Caveat: a leading `/* ... */` before `SHOW CREATE TABLE` fails on Athena
  only (measured 2026-09-18) ([docs](docs/caveats.md#sql-dialect)).
- The Caveat on Athena's opaque `SHOW` `.metadata` describes the blob (measured
  2026-09-16 to 2026-09-18) ([docs](docs/caveats.md#result-files-and-metadata)).
- A CTAS on an Iceberg table reports `<id>` as its `OutputLocation`, like
  `INSERT`, instead of `tables/<id>` (measured 2026-09-17).
- `<id>.csv` is now uploaded as `application/octet-stream` instead of `text/csv`
  (measured 2026-09-17).
- A result file upload now gives up after 30 seconds instead of waiting for the
  store forever ([docs](docs/result-files.md#result-files)).
- Error bodies use `Message` instead of `message` and add `ErrorCode` (measured
  2026-09-17) ([docs](docs/caveats.md#errors-and-request-bodies)).
- **Breaking:** `StartQueryExecution` requires a 32 to 128 character
  `ClientRequestToken` (measured 2026-09-17)
  ([docs](docs/api.md#supported-api)).
- `DROP TABLE` and `ALTER TABLE ... ADD COLUMNS` write files by table format
  (measured 2026-09-20/21)
  ([docs](docs/ddl.md#ddl-that-depends-on-the-target-tables-format)).
- An unreadable request body fails with Athena's errors (measured 2026-09-23)
  ([docs](docs/caveats.md#errors-and-request-bodies)).
- A bad `X-Amz-Target` answers `UnknownOperationException` (measured 2026-09-23)
  ([docs](docs/caveats.md#errors-and-request-bodies)).

### Fixed

- `EXPLAIN (TYPE VALIDATE)` returns `Valid`, `true` and one empty row, as Athena
  does (measured 2026-09-23) ([docs](docs/api.md#supported-api)).
- A failed `EXPLAIN` no longer writes the `FAILED: ...` file to `<id>.txt`
  (measured 2026-09-23) ([docs](docs/caveats.md#failed-queries)).
- `SHOW FUNCTIONS` writes `<id>.csv` with a header and gets `SubstatementType`
  `SHOW_FUNCTIONS` (measured 2026-09-23)
  ([docs](docs/result-files.md#result-files)).
- `TABLE t` is classified as `DML` / `SELECT`, as on Athena (measured
  2026-09-22) ([docs](docs/api.md#supported-api)).
- `EXPLAIN` results are split into one row per line of the plan (measured
  2026-09-15/16) ([docs](docs/api.md#supported-api)).
- The `<id>.txt` of an `EXPLAIN` starts with the header `Query Plan` (measured
  2026-09-15/16) ([docs](docs/result-files.md#result-files)).
- A malformed environment variable stops the server with the reason as one plain
  line on stderr instead of Rust's `Debug` form.
- A comment between two keywords is read as whitespace when the statement is
  classified (measured 2026-09-22) ([docs](docs/api.md#supported-api)).
- A leading comment is skipped when the statement is classified (measured
  2026-09-18) ([docs](docs/api.md#supported-api)).
- A CTAS always writes to `tables/<id>`, whatever the table format (measured
  2026-09-19) ([docs](docs/caveats.md#result-files-and-metadata)).
- Unmeasured-file-name Caveat removed: `CREATE OR REPLACE TABLE ... AS` fails on
  Athena (measured 2026-09-23) ([docs](docs/caveats.md#sql-dialect)).
- The unmeasured `.metadata` Caveat no longer lists `MERGE` (measured
  2026-09-20) ([docs](docs/result-files.md#companion-metadata-files)).
- `ALTER TABLE` is classified by position, not a text scan, with three more
  values (measured 2026-09-21)
  ([docs](docs/caveats.md#alter-table-and-format-dependent-ddl)).
- `GetQueryResults` has no column-name row for `SHOW` / `DESCRIBE` (measured
  2026-09-15 to 22) ([docs](docs/api.md#supported-api)).
- A query whose leading `(` is followed by whitespace or a newline is classified
  like `(SELECT 1)`.
- `GetQueryResults` validates `MaxResults` and `NextToken` the way Athena does,
  in Athena's order (measured 2026-09-23) ([docs](docs/caveats.md#paging)).
- `ListWorkGroups` reports two paging violations in one message (measured
  2026-09-23) ([docs](docs/caveats.md#paging)).
- `GetQueryResults` paging matches Athena in three more edge cases (measured
  2026-09-23) ([docs](docs/caveats.md#paging)).
- The remaining type mismatches carry Athena's message; a `null` in a list is
  dropped (measured 2026-09-23)
  ([docs](docs/caveats.md#errors-and-request-bodies)).

## [0.4.0] - 2026-09-15

### Added

- `TRINO_CATALOG_MAP` also applies to double-quoted catalogs in qualified names
  in the SQL ([docs](docs/configuration.md#configuration)).

## [0.3.0] - 2026-09-14

### Added

- `StopQueryExecution`. A queued or running query becomes `CANCELLED` at once
  and athena-local sends `DELETE` to Trino's `nextUri`.
- Result files. With `ATHENA_LOCAL_RESULTS=s3`, a successful `SELECT` is written
  as CSV to an S3-compatible store ([docs](docs/result-files.md#result-files)).
- `GetQueryExecution` returns `ResultConfiguration.OutputLocation` as the full
  path of the file Athena would use ([docs](docs/result-files.md#result-files)).
- `GetQueryExecution` returns `SubstatementType` for the statement kinds that
  were measured, and leaves it out for the rest.
- `GetQueryExecution` returns `Status.AthenaError` for `FAILED` queries.
- `Statistics` carries real timings.
- `GetQueryResults` fills `ColumnInfo.Precision`, `Scale`, `CatalogName`,
  `SchemaName` and `TableName` as Athena does.
- Error responses carry `AthenaErrorCode`.

### Changed

These change what 0.2.0 returned. All of them follow measured Athena behaviour.

- A syntax error makes `StartQueryExecution` fail with `InvalidRequestException`
  (`MALFORMED_QUERY`) instead of creating a `FAILED` query.
- `ColumnInfo.Type` is the base type name (`varchar(3)` is `varchar`, `real` is
  `float`), and `CaseSensitive` is true for `varchar` and `char`.
- `GetQueryResults` for DML and CTAS lists the `rows` (`bigint`) column in
  `ColumnInfo`. DDL without a count returns no rows and no columns.
- `GetQueryResults` for `SELECT` and `SHOW` returns `UpdateCount` `0`.
- `StatementType`: `VALUES`, `EXPLAIN` and `VACUUM` are `DML`; `OPTIMIZE` is
  `DDL`.
- An `OutputLocation` that is not `s3://bucket[/prefix]` is rejected with
  `INVALID_INPUT`, even when results are not written.
- Error messages use Athena's wording ([docs](docs/api.md#supported-api)).

### Fixed

- `timestamp` values keep their precision instead of being rounded to
  milliseconds.
- `double` and `real` values use Java's notation (`1.0E20`, `1.0E-7`).
- `varbinary` values are hex (`01 02`) instead of base64.
- Map entries with numeric keys are ordered numerically (`{9=a, 10=b}`).

## [0.2.0] - 2026-09-14

### Added

- `ExecutionParameters`, classified the way Athena does and run as `EXECUTE
  IMMEDIATE ... USING` ([docs](docs/parameters.md#executionparameters)).
- `TRINO_CATALOG_MAP` maps Athena catalog names that Trino cannot have, such as
  `s3tablescatalog/<bucket>`, to a Trino catalog.

### Changed

- `array`, `map` and `row` values use Athena's notation (`[1, 2]`, `{k=1}`,
  `{id=1, name=x}`) instead of JSON.

### Fixed

- `ExecutionParameters: null` is treated as no parameters instead of failing
  with 400.

## [0.1.0] - 2026-09-12

### Added

- First release: an Athena API stand-in that runs SQL on Trino
  (`StartQueryExecution`, `GetQueryExecution`, `GetQueryResults`).
- SQL is passed to Trino unchanged; `QueryExecutionContext` becomes the
  `X-Trino-Catalog` / `X-Trino-Schema` headers.
- `linux/amd64` and `linux/arm64` images published on tag push.

[Unreleased]: https://github.com/aoyagikouhei/athena-local/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/aoyagikouhei/athena-local/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/aoyagikouhei/athena-local/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/aoyagikouhei/athena-local/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/aoyagikouhei/athena-local/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/aoyagikouhei/athena-local/releases/tag/v0.1.0
