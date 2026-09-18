# Changelog

All notable changes to athena-local are recorded here. Versions match the
`aoyagikouhei/athena-local` image tags on Docker Hub.

Behaviour described as "measured" was compared against real Amazon Athena
(engine version 3). The first round was measured on 2026-09-14; entries added
later name the date they were measured on.

## [Unreleased]

### Added

- A companion `.metadata` file is written next to the result file with
  `ATHENA_LOCAL_RESULTS=s3`, so Athena JDBC 3.x works with its default
  `ResultFetcher=auto`, which reads the result and the metadata straight from
  S3 rather than calling `GetQueryResults` (versions before 3.5.1 fail with
  `NoSuchKey` when a DDL statement has no metadata file; athena-local writes
  none for column-less DDL either, so those statements still fail there, while
  3.8.1 logs the 404 at INFO level and carries on, measured 2026-09-17). The
  names follow the result file: `<id>.csv.metadata`, `<id>.txt.metadata`,
  `<id>.metadata` for `INSERT` and an Iceberg CTAS, and `tables/<id>.metadata`
  for a Hive CTAS. It is written for every statement that has columns,
  including a `SELECT` returning
  no rows; DML and CTAS write the companion file only, and DDL without columns,
  failed queries and cancelled queries write no companion file. The content is
  the protobuf Athena writes: the query id, the `updateType` and update count
  for DML and CTAS, and one message per column with the same values as the
  `ColumnInfo` of `GetQueryResults`. A failed upload leaves the query
  `SUCCEEDED` and logs one line, like `<id>.txt`. Measured against Athena on
  2026-09-17.
- A failed query now writes its result file too, for the statements whose
  result file is `<id>.txt` (DDL, `SHOW`, `DESCRIBE`, `EXPLAIN`), so a client
  that reads the result file rather than `GetQueryResults` can see why it
  failed. It holds `FAILED: ` followed by `StateChangeReason`, with no trailing
  newline, and is sent as `application/octet-stream`; no `.metadata` companion
  is written. `SELECT`, DML and CTAS write nothing, and neither does a
  cancelled query. The upload happens before the query becomes `FAILED`, and an
  upload that fails logs one line and leaves the state and the reason
  unchanged. Measured against Athena on 2026-09-17; Athena writes the file for
  fewer statements, see Caveats.
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
- `ListWorkGroups` is supported, so the workgroup dropdown in Grafana's data
  source settings can be filled in. The names come from the new
  `ATHENA_LOCAL_WORK_GROUPS` variable (comma separated, `primary` when unset)
  and are returned in name order with the same `State` and `EngineVersion` as
  `GetWorkGroup`. `MaxResults` / `NextToken` paging is supported; `MaxResults`
  outside 1..50 and a malformed or empty `NextToken` fail with the messages
  Athena returns. `Description` is always `""`, and `CreationTime` is left out;
  see Caveats. Measured against Athena on 2026-09-18.
- `StartQueryExecution` now keeps the `WorkGroup` it was given, and
  `GetQueryExecution` reports that name instead of always saying `primary`.
  Omitting it still means `primary`.
- `StartQueryExecution` accepts `ClientRequestToken` and makes retries
  idempotent: a retry with the same token returns the same `QueryExecutionId`
  regardless of the first query's state, and does not run the query again. A
  retry whose `QueryString`, `QueryExecutionContext.Database` or
  `ResultConfiguration.OutputLocation` differs instead fails with
  `IDEMPOTENT_PARAMETER_MISMATCH`. `ExecutionParameters` and `WorkGroup` are not
  compared. The token is not normalized. Measured against Athena on 2026-09-17.
- A finished query is dropped after a retention period, so a long-running
  server no longer keeps every execution, result set and `ClientRequestToken`
  in memory forever. A query that has reached `SUCCEEDED`, `FAILED` or
  `CANCELLED` is kept for `ATHENA_LOCAL_RETENTION_SECONDS` after it finished
  and is then dropped together with the token that points at it; queued and
  running queries are never dropped. Once a query is dropped,
  `GetQueryExecution`, `GetQueryResults` and `StopQueryExecution` treat its id
  like an unknown one and fail with `QUERY_EXECUTION_NOT_FOUND`
  (`StopQueryExecution` still succeeds on a finished query until the period
  passes, and fails after it), and resending the same `ClientRequestToken`
  starts a new query with a new `QueryExecutionId`, so an `INSERT` or CTAS
  retried after the period runs again. The period counts from completion and
  is not extended by reading the query. Dropping happens whenever
  an API call touches the store, not on a timer, so nothing is swept while the
  server is idle. New setting: `ATHENA_LOCAL_RETENTION_SECONDS` (default
  `3600`, one hour); a value that is not a positive integer stops the server at
  startup, and there is no "keep forever" value, so use a large number instead.
  Real Athena's retention period has not been measured; 3600 is athena-local's
  own number.

### Changed

- A CTAS on an Iceberg table now reports `s3://bucket/prefix/<id>` as its
  `OutputLocation`, like `INSERT`, instead of
  `s3://bucket/prefix/tables/<id>`, and its `.metadata` companion moves with
  it. Athena adds the `tables/` part for Hive tables only: the same CTAS with
  `table_type = 'ICEBERG'` came back without it (measured 2026-09-17). A
  statement counts as Iceberg when `table_type = 'ICEBERG'` appears in it,
  ignoring case and spacing; see Caveats for what that misses.
- `<id>.csv` is now uploaded as `application/octet-stream` instead of
  `text/csv`. Athena sends `application/octet-stream` for it (measured on
  2026-09-17 in five of six result files); `text/csv` had been athena-local's
  own unmeasured guess since 0.3.0. `<id>.txt` keeps `binary/octet-stream`, and
  the new `.metadata` companions are `application/octet-stream` too.
- A result file upload now gives up after 30 seconds instead of waiting for
  the store forever. An S3-compatible store that accepts the connection but
  never answers used to leave the query `RUNNING` until the TCP timeout, which
  also held back queries on their way to `FAILED`. The timeout applies to every
  result file (`<id>.csv`, `<id>.txt`, the `.metadata` companions and the
  failure `<id>.txt`), is fixed and has no environment variable, and a `PUT`
  that hits it is treated like any other failed upload: the CSV makes the query
  `FAILED`, while `<id>.txt` and `.metadata` leave it `SUCCEEDED` with one log
  line. Athena has no matching behaviour, so the limit is athena-local's own.
- Error response bodies now use `Message` (capital M) instead of `message`,
  and an error that carries `AthenaErrorCode` now also carries `ErrorCode`
  with the same value. Real Athena always returns this shape (measured for
  `IDEMPOTENT_PARAMETER_MISMATCH` and `WorkGroup is not found.`), so this is
  a bug fix, not a behaviour change from athena-local's point of view. The AWS
  SDKs read both `message` and `Message` (botocore and smithy-rs each check
  the two spellings explicitly), so this does not affect ordinary clients. Errors without an `AthenaErrorCode` (a request that fails to
  parse, an unsupported operation, `InternalServerException`) keep only
  `Message`; whether real Athena adds `ErrorCode` there too has not been
  measured. Measured against Athena on 2026-09-17.
- **Breaking:** `StartQueryExecution` now requires `ClientRequestToken`; a
  request without one fails with `INVALID_INPUT`, and the length must be
  between 32 and 128 characters. This does not affect the AWS CLI or SDKs,
  which already add a token automatically; a raw HTTP client now needs to add
  one itself. Measured against Athena on 2026-09-17.

### Fixed

- `StatementType`, `SubstatementType`, `UpdateCount` and `OutputLocation` are
  now classified correctly for a SQL statement that starts with a comment
  (`-- ...` or `/* ... */`, possibly with more whitespace and comments after
  it): the leading comment is skipped before the classification keyword is
  read, matching Athena, instead of being read as the first word and always
  falling into `UTILITY` / `<id>.txt`. This also fixes the leading query ID of
  the `.metadata` companion file for a commented `DESCRIBE` or
  `SHOW CREATE TABLE`, which must be the `QueryExecutionId` rather than
  Trino's own query ID. Measured against Athena on 2026-09-18.

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
