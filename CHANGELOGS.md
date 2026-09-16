# Changelog

All notable changes to athena-local are recorded here. Versions match the
`aoyagikouhei/athena-local` image tags on Docker Hub.

Behaviour described as "measured" was compared against real Amazon Athena
(engine version 3). The first round was measured on 2026-09-14; entries added
later name the date they were measured on.

## [Unreleased]

### Added

- DDL, `SHOW` and `DESCRIBE` results are written to `<id>.txt` with
  `ATHENA_LOCAL_RESULTS=s3`, so clients that read the result file rather than
  `GetQueryResults` work. PyAthena's pandas and arrow cursors are the ones that
  need it. The file holds the rows `GetQueryResults` returns, joined with `\n`,
  with no header line and no trailing newline; a statement that returns no rows
  writes an empty file. Measured against Athena on 2026-09-16.
- Columns in `<id>.txt` are joined with a tab. Athena returns one already
  joined, space-padded string per row, which Trino's separate columns cannot
  reproduce, so the padding is left out.
- A failed `<id>.txt` upload leaves the query `SUCCEEDED` and logs one line,
  unlike the CSV, which still makes the query `FAILED`. The statement has
  already run on Trino by then, and DDL cannot be undone.
- `GetWorkGroup` is supported, so awswrangler and Grafana can run queries at
  all: both call it before a query and read fields out of the response without
  checking that they are there. Any workgroup name is accepted and echoed back,
  and the configuration is the same for every name, since athena-local has no
  workgroups. `Configuration.ResultConfiguration` is always present, holding
  `OutputLocation` when `ATHENA_LOCAL_OUTPUT_LOCATION` is set and `{}` when it
  is not. `CreationTime` and `EnableMinimumEncryptionConfiguration` are left
  out; see Caveats. Measured against Athena on 2026-09-17.
- `StartQueryExecution` now keeps the `WorkGroup` it was given, and
  `GetQueryExecution` reports that name instead of always saying `primary`.
  Omitting it still means `primary`.

## [0.4.0] - 2026-09-15

### Added

- `TRINO_CATALOG_MAP` also applies to qualified names in the SQL. A double-quoted
  catalog that equals an alias and is followed by `.`, such as
  `"s3tablescatalog/my-bucket".db.users`, is replaced with the Trino catalog and
  padded with spaces so that error positions still match the submitted SQL.
  String literals and comments are not touched, the syntax check still sees the
  submitted SQL, and `GetQueryExecution` still returns it. Unquoted names are not
  rewritten.

## [0.3.0] - 2026-09-14

### Added

- `StopQueryExecution`. A queued or running query becomes `CANCELLED` at once
  (`StateChangeReason`: `Query cancelled by user`) and athena-local sends `DELETE`
  to Trino's `nextUri`. Stopping a finished query succeeds and changes nothing.
- Result files. With `ATHENA_LOCAL_RESULTS=s3`, a successful `SELECT` is written as
  CSV to `<OutputLocation><id>.csv` on an S3-compatible store (for example MinIO)
  before the query becomes `SUCCEEDED`. The CSV matches Athena byte for byte.
  New settings: `ATHENA_LOCAL_RESULTS`, `ATHENA_LOCAL_OUTPUT_LOCATION`,
  `AWS_ENDPOINT_URL_S3` (or `AWS_ENDPOINT_URL`), `AWS_ACCESS_KEY_ID`,
  `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`. Writing is off by default.
- `GetQueryExecution` returns `ResultConfiguration.OutputLocation` as the full
  path of the file Athena would use (`<id>.csv` for `SELECT` / `UPDATE` /
  `DELETE` / `MERGE`, `<id>` for `INSERT`, `tables/<id>` for CTAS, `<id>.txt`
  for other DDL and `SHOW` / `DESCRIBE` / `EXPLAIN`).
- `GetQueryExecution` returns `SubstatementType` (`SELECT`, `INSERT`,
  `CREATE_TABLE_AS_SELECT`, `SHOW_TABLES`, ...) for the statement kinds that were
  measured, and leaves it out for the rest.
- `GetQueryExecution` returns `Status.AthenaError` for `FAILED` queries, with the
  `ErrorCategory` / `ErrorType` Athena uses for each measured Trino error name.
- `Statistics` carries real timings: `QueryQueueTimeInMillis`,
  `EngineExecutionTimeInMillis` and `TotalExecutionTimeInMillis`.
- `GetQueryResults` fills `ColumnInfo.Precision`, `Scale`, `CatalogName`,
  `SchemaName` and `TableName` as Athena does.
- Error responses carry `AthenaErrorCode`.

### Changed

These change what 0.2.0 returned. All of them follow measured Athena behaviour.

- A syntax error makes `StartQueryExecution` fail with `InvalidRequestException`
  (`MALFORMED_QUERY`) instead of creating a `FAILED` query. athena-local asks
  Trino to `PREPARE` the statement first, which adds one round trip (about
  10–30 ms).
- `ColumnInfo.Type` is the base type name: `varchar(3)` is `varchar`,
  `decimal(10, 2)` is `decimal`, `array(bigint)` is `array`, and `real` is
  `float`. `CaseSensitive` is true for `varchar` and `char`.
- `GetQueryResults` for DML and CTAS lists the `rows` (`bigint`) column in
  `ColumnInfo`. DDL without a count returns no rows and no columns.
- `GetQueryResults` for `SELECT` and `SHOW` returns `UpdateCount` `0`.
- `StatementType`: `VALUES`, `EXPLAIN` and `VACUUM` are `DML`; `OPTIMIZE` is `DDL`.
- An `OutputLocation` that is not `s3://bucket[/prefix]` is rejected with
  `outputLocation is not a valid S3 path.` (`INVALID_INPUT`), even when results
  are not written. 0.2.0 accepted and ignored it.
- Error messages use Athena's wording: `QueryExecution <id> was not found`,
  `Query has not yet finished. Current state: RUNNING`,
  `Query did not finish successfully. Final query state: FAILED`, and
  `Could not find results` for a cancelled query.

### Fixed

- `timestamp` values keep their precision (`timestamp(6)` returns six fractional
  digits, `timestamp(0)` none). Trino rounded them to milliseconds because
  athena-local did not send `X-Trino-Client-Capabilities: PARAMETRIC_DATETIME`.
- `double` and `real` values use Java's notation (`1.0E20`, `1.0E-7`).
- `varbinary` values are hex (`01 02`) instead of base64.
- Map entries with numeric keys are ordered numerically (`{9=a, 10=b}`).

## [0.2.0] - 2026-09-14

### Added

- `ExecutionParameters`. Each value is classified the way Athena does (an
  expression without column references is used as-is, anything else becomes a
  string literal) and the query runs as `EXECUTE IMMEDIATE ... USING`. Values
  passed to SQL without `?` are ignored, as in Athena.
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

- First release: a local stand-in for the Athena API (`awsJson1.1`) that runs SQL
  on Trino. Supports `StartQueryExecution`, `GetQueryExecution` and
  `GetQueryResults`, with the header row on the first page of a `SELECT`,
  `UpdateCount` for DML, and `MaxResults` / `NextToken` pagination.
- SQL is passed to Trino unchanged; `QueryExecutionContext` becomes the
  `X-Trino-Catalog` / `X-Trino-Schema` headers.
- `linux/amd64` and `linux/arm64` images published on tag push.

[Unreleased]: https://github.com/aoyagikouhei/athena-local/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/aoyagikouhei/athena-local/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/aoyagikouhei/athena-local/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/aoyagikouhei/athena-local/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/aoyagikouhei/athena-local/releases/tag/v0.1.0
