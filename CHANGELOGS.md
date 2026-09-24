# Changelog

All notable changes to athena-local are recorded here. Versions match the
`aoyagikouhei/athena-local` image tags on Docker Hub.

Behaviour described as "measured" was compared against real Amazon Athena
(engine version 3). The first round was measured on 2026-09-14; entries added
later name the date they were measured on.

## [Unreleased]

### Changed

- `SHOW CREATE VIEW` writes its `.txt` and `.metadata` as `binary/octet-stream`
  with the engine's query id at the head of the `.metadata`, and reports
  `SubstatementType` `SHOW_CREATE_VIEW`, as real Athena does (measured
  2026-09-24) ([docs](docs/result-files.md#result-files)).
- `SHOW CREATE TABLE` on an Iceberg table writes its `.txt` and `.metadata` as
  `binary/octet-stream` with the engine's query id at the head of the
  `.metadata`, as real Athena does (measured 2026-09-24)
  ([docs](docs/ddl.md#ddl-that-depends-on-the-target-tables-format)).
- A `varbinary` inside an `array`, `map` or `row` is rendered as `[B@<hex>`,
  the shape real Athena prints (measured 2026-09-24), instead of the top-level
  `01 02` hex form ([docs](docs/caveats.md#value-rendering)).
- A `StartQueryExecution` retry with the same `ClientRequestToken` now also
  compares `QueryExecutionContext.Catalog`, as real Athena does (measured
  2026-09-24) ([docs](docs/api.md#supported-api)).
- Error responses no longer carry an `x-amzn-errortype` header, matching
  real Athena (measured 2026-09-17 to 2026-09-24); the error type is in the
  body's `__type` as before ([docs](docs/caveats.md#errors-and-request-bodies)).
- `GetWorkGroup` returns `Configuration.EnableMinimumEncryptionConfiguration`
  as `false` (measured 2026-09-23) ([docs](docs/caveats.md#workgroups)).
- Caveats that said "not measured" now cite the 2026-09-24 measurements
  ([docs](docs/caveats.md#result-files-and-metadata)).
- The caveats on `ClientRequestToken` normalization, on real Athena's
  retention period and on `ErrorCode` for syntax errors cite the 2026-09-24
  measurements too
  ([docs](docs/caveats.md#query-lifecycle),
  [docs](docs/caveats.md#errors-and-request-bodies)).

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
