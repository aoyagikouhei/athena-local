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
  `<id>.metadata` for `INSERT`, and `tables/<id>.metadata` for a CTAS. It is written for every statement that has columns,
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
- README documents how to connect Athena JDBC 3.x. The driver refuses a
  plain-HTTP `AthenaEndpoint` or `S3Endpoint`
  (`EndpointHelper.constructEndpointUri` accepts `https` only, and no property
  disables it; disassembled from 3.8.1), so the new section shows a minimal
  nginx TLS terminator for athena-local and the S3-compatible store, how to
  make a self-signed certificate the JVM accepts, and the `keytool` import and
  driver properties that go with it. The Caveats entry "Plain HTTP only" points
  at it. This is the setup athena-local was verified against JDBC 3.8.1 with on
  2026-09-17. Documentation only; no behaviour change.
- A one-line warning is printed to stderr at startup when there is no default
  output location, telling you that awswrangler may create a bucket on real
  AWS and pointing at the README Caveat. It appears with
  `ATHENA_LOCAL_RESULTS=none` as well as with `s3` and no
  `ATHENA_LOCAL_OUTPUT_LOCATION`, because `GetWorkGroup` reports no
  `OutputLocation` in either case, which is what sends awswrangler down its
  `create_athena_bucket()` fallback. The server still starts, and the outgoing
  calls are still not blocked.
- `ALTER TABLE ... REPLACE COLUMNS`, `... ADD PARTITION`, `... DROP PARTITION`
  and `... RENAME TO` now get the `SubstatementType` real Athena returns:
  `ALTER_TABLE_REPLACE_COLUMN` (singular, although the statement is plural),
  `ALTER_TABLE_ADD_PARTITION`, `ALTER_TABLE_DROP_PARTITION` and
  `ALTER_TABLE_RENAME`. Athena returns the field even for the combinations it
  then fails at run time (`REPLACE COLUMNS`, `ADD PARTITION` and `SET LOCATION`
  on an Iceberg table; `RENAME TO` on a Hive table), so the classification does
  not depend on the target table's format. `REPLACE COLUMNS` on a Hive table
  also writes the same 38-byte `.metadata` as `ADD COLUMNS` does — byte for
  byte the same content apart from the id — so it now takes the same format
  probe. Measured against Athena on 2026-09-21. Of the four, only `RENAME TO`
  can be run through athena-local: Trino's grammar has no `REPLACE COLUMNS`,
  `ADD PARTITION` or `DROP PARTITION`, so those three are rejected at the
  syntax check before an execution is created (checked against Trino 482 on
  2026-09-21). Their classification is what athena-local would answer if the
  backend's grammar accepted the statement, and a new Caveat lists every
  `ALTER TABLE` spelling Trino rejects.

### Changed

- The `Content-Type` of the result file and its `.metadata` companion now
  follows the statement the way Athena does, instead of a fixed value per file
  name. A `SELECT` of literals only (`SELECT 1`, `SELECT 1 AS i, 'a'`, the
  connection check most JDBC drivers send) and `SHOW TABLES` / `DATABASES` /
  `COLUMNS` / `TBLPROPERTIES` / `VIEWS` / `PARTITIONS` are uploaded as
  `binary/octet-stream`; `DESCRIBE`, `EXPLAIN` and `SHOW CREATE TABLE` as
  `application/octet-stream`; every other `SELECT` keeps
  `application/octet-stream` and column-less DDL keeps `binary/octet-stream`.
  The `.metadata` companion always gets the same value as its result file, so
  the companion of a `SHOW TABLES` changes to `binary/octet-stream`. The
  earlier values had been the majority of a few measurements (five of six
  `.csv` files; the sixth was `SELECT 1`); this one comes from 36 statements
  measured with controls on 2026-09-23 (issue #70), plus 18 more the same
  day (issue #76): a literals-only `SELECT` also covers `SELECT -1`,
  `SELECT 1.5E0`, a double-quoted alias (`SELECT 1 AS "x"`) and a bare alias
  (`SELECT 1 i`), all `binary/octet-stream` on Athena; `DESC`, `SELECT 1 AS
  i, 2 AS j` and lowercase `select 1` confirmed the values already assumed;
  `LIMIT`, `DATE '...'`, `'a' || 'b'`, `ARRAY[1]`, `(SELECT 1)` and `VALUES 1`
  are `application/octet-stream` as before; and `SHOW FUNCTIONS` is
  `application/octet-stream` (Athena writes it as a `<id>.csv`, which is #80).
  Athena rejects `SHOW SESSION` and `SHOW STATS` outright, and a 98.9 MB
  result is still one upload while 142.9 MB is multipart. `SELECT` forms not
  measured are sent as `application/octet-stream` and `SHOW CREATE VIEW`
  follows `SHOW CREATE TABLE`; see README.
- README documents where the `Precision` of the `EXPLAIN` result column comes
  from: the engine types `Query Plan` as `varchar(<length of the plan text>)`,
  371 for `EXPLAIN SELECT 1` on Athena (measured 2026-09-15 and 2026-09-16) and
  400 on Trino 482, and athena-local already passes Trino's length through. The
  fake Trino in the tests now sends the same `varchar(371)` type signature, so
  the tests pin that `GetQueryResults` and `.txt.metadata` report it. No change
  in behaviour.
- `ALTER TABLE ... DROP COLUMNS` (plural) is no longer classified. Athena takes
  the plural `COLUMNS` after `ADD` but only the singular `COLUMN` after `DROP`,
  and rejects the plural form in `StartQueryExecution` with `mismatched input
  'COLUMNS'. Expecting: '.', 'DROP'` (`AthenaErrorCode` `MALFORMED_QUERY`).
  athena-local used to answer `ALTER_TABLE_DROP_COLUMN` for it. Trino's grammar
  rejects the statement at the syntax check either way, so no reachable
  behaviour changed. Measured against Athena on 2026-09-21.
- A new Caveat records that a leading `/* ... */` before `SHOW CREATE TABLE`
  can succeed here while real Athena rejects it at execution time with
  `FAILED: ParseException line 1:0 cannot recognize input near '/' '*' 'c'`
  and `ErrorCategory` 1 / `ErrorType` 1003, even though
  `StatementType`, `SubstatementType` and `OutputLocation` come back correctly
  on both sides; a leading `-- ...` line comment works on both. athena-local
  sends the SQL to Trino unmodified, so nothing rejects the block-comment form
  here. Whether other statements that Athena parses the same way behave alike
  is not measured. No behaviour changed. Measured against Athena on
  2026-09-18.
- The Caveat about the opaque `.metadata` Athena writes for `SHOW TABLES`,
  `SHOW DATABASES`, `SHOW COLUMNS`, `SHOW PARTITIONS` and `SHOW TBLPROPERTIES`
  now records what the blob looks like — a fixed 233 bytes (345 for
  `SHOW TBLPROPERTIES`) behind base64, a leading `0x01`, and different bytes
  every run — states that the format itself remains unidentified, and notes
  that `SHOW CREATE TABLE` and the result file itself are unaffected and that
  Athena JDBC 3.8.1 reads athena-local's plain protobuf for those statements
  without an exception. No behaviour changed. Measured against Athena on
  2026-09-16, 2026-09-17 and 2026-09-18.
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
- `DROP TABLE` and `ALTER TABLE ... ADD COLUMNS` now write a result file and a
  `.metadata` companion that depend on the target table's format on Trino
  (Hive or Iceberg), instead of always writing an empty `<id>.txt` and no
  companion. A `DROP TABLE` on an Iceberg table now writes a single newline to
  `<id>.txt` and a 41-byte `.metadata` (the engine's query id, then
  `DROP TABLE`), both as `application/octet-stream`; on a Hive-format table,
  or when the target does not exist, it keeps the old behaviour (empty file,
  no companion, `binary/octet-stream`) — which matches Athena there too. An
  `ALTER TABLE ... ADD COLUMNS` on a Hive table now writes a 38-byte
  `.metadata` (`QueryExecutionId` only) as `application/octet-stream`, while
  `<id>.txt` stays empty; the same statement on an Iceberg table keeps the old
  behaviour. The format and the target's existence are read with a single
  query per matching statement (`system.metadata.catalogs.connector_name` and
  a `system.jdbc.tables` count), so no other query pays an extra round trip.
  Both statements resolve the catalog, schema and table the same way: from a
  qualified name in the SQL when it gives one, falling back to
  `QueryExecutionContext` / `TRINO_CATALOG` / `TRINO_SCHEMA` otherwise, with a
  catalog taken from the SQL translated through `TRINO_CATALOG_MAP` first,
  same as for the statement itself. When neither catalog nor schema can be
  resolved, the probe query fails, the connector is neither `hive` nor
  `iceberg`, or the target does not exist, athena-local falls back to the old
  behaviour; for `DROP TABLE`, the missing-target case happens to match what
  real Athena does for `DROP TABLE IF EXISTS` on a missing table too. Because
  Trino keeps Hive and Iceberg tables in separate catalogs while Athena mixes
  both in one `AwsDataCatalog`, this reproduces Athena only when your Trino
  catalog for a given Athena table uses the matching connector; see the new
  Caveat. Measured against Athena on 2026-09-20 and 2026-09-21, reproduced
  across three rounds.
- A request body that cannot be read now fails the way Athena's does
  (measured 2026-09-23 with 46 malformed requests). A member of the wrong
  JSON type is a `SerializationException` without `AthenaErrorCode`, with
  Athena's message for that combination (`STRING_VALUE can not be converted
  to an Integer` and the like); a body that is not JSON is a
  `SerializationException` with no `Message`; a required member that is
  missing or `null` is `InvalidRequestException` / `INVALID_INPUT` with
  Athena's `Value null at 'queryExecutionId' ... Member must not be null`
  message; an optional member set to `null` is treated as absent. All of
  these used to be `InvalidRequestException` with a Japanese message and no
  `AthenaErrorCode`. `MaxResults` is now read as a 64-bit integer so a value
  beyond the 32-bit range reaches the upper-bound validation like on Athena.
  See the new Caveat for the combinations that were not measured and the
  two known differences.
- An unsupported operation, a missing `X-Amz-Target` header, or a target
  without the `AmazonAthena.` prefix now answers
  `{"__type":"UnknownOperationException"}` with no `Message`, as Athena does
  (measured 2026-09-23). It used to be `InvalidRequestException` with a
  Japanese message, and a target without the prefix used to be accepted.

### Fixed

- `EXPLAIN (TYPE VALIDATE)` now returns `Valid`, `true` and one empty row, and
  writes `Valid\ntrue\n` to `<id>.txt`, as Athena does: the single `boolean`
  value goes through the same split as a plan text (append one newline, split
  on `\n`). It used to return the header and `true` only. The rule was measured
  on 2026-09-23 for eight `EXPLAIN` forms in one round (`FORMAT JSON`,
  `TYPE IO`, `FORMAT GRAPHVIZ`, `TYPE DISTRIBUTED`, `ANALYZE`,
  `ANALYZE VERBOSE`, `TYPE VALIDATE` and the plain form); the text plans all
  matched the existing behaviour, so the Caveat that the split had been
  measured on one plan shape is gone.
- A failed `EXPLAIN` no longer writes the `FAILED: ...` file to `<id>.txt`:
  Athena writes neither the file nor the `.metadata` companion for a failed
  `EXPLAIN` or `EXPLAIN ANALYZE` (measured 2026-09-23 on a missing table).
- `SHOW FUNCTIONS` now writes its result as `<id>.csv`, a header-line CSV in
  the `SELECT` format sent as `application/octet-stream`, and `GetQueryResults`
  returns the column-name row first, as on Athena (measured 2026-09-23). Its
  `.csv.metadata` companion starts with the engine's query id, like `SELECT`,
  and `GetQueryExecution` now reports `SubstatementType` `SHOW_FUNCTIONS`
  (it used to be left out). It used to write `<id>.txt` without a header line
  like the other `SHOW` statements. A failed `SHOW FUNCTIONS` writes no result
  file, like the other `<id>.csv` statements; Athena's behaviour there was not
  measured.
- `TABLE t` (Trino's shorthand for `SELECT * FROM t`) is now classified as
  `DML` / `SELECT`, as on Athena (measured 2026-09-22), so `GetQueryResults`
  returns the column-name row first and `GetQueryExecution` reports
  `StatementType` `DML` and `SubstatementType` `SELECT`. It used to be
  `UTILITY` with no `SubstatementType`, and the header row was dropped from
  `GetQueryResults` while the `<id>.csv` result file kept it, so the API and
  the file differed by one row.
- `EXPLAIN` results are split into one row per line of the plan, as on Athena
  (measured 2026-09-15 and 2026-09-16: `EXPLAIN SELECT 1` returns the header
  row, 11 plan lines and 3 empty rows, and its `<id>.txt` is 393 bytes). Trino
  returns the whole plan as one `Query Plan` value with embedded newlines, and
  athena-local used to pass that single row through, so `GetQueryResults`
  returned 2 rows and the `<id>.txt` file lacked the final newline. The plan
  text now gets one newline appended and is split on `\n`, for both the API
  and the file.
- The `<id>.txt` result file of an `EXPLAIN` now starts with the header line
  `Query Plan`, as on Athena (measured 2026-09-15 and 2026-09-16, where the
  file has exactly the rows `GetQueryResults` returns, header included). It used
  to drop the first row like the `<id>.txt` of a DDL, `SHOW` or `DESCRIBE`,
  which have no header line, so a client reading the file straight from S3
  (Athena JDBC with `ResultFetcher=auto` or `S3`) saw one line fewer than on
  Athena. The header line follows `StatementType`: only `DML` gets it, the same
  split `GetQueryResults` uses.
- A malformed environment variable (`TRINO_CATALOG_MAP`,
  `ATHENA_LOCAL_RETENTION_SECONDS`, `ATHENA_LOCAL_WORK_GROUPS`,
  `ATHENA_LOCAL_RESULTS` and the S3 settings) now stops the server with the
  reason printed as one plain line on stderr. It used to be printed in Rust's
  `Debug` form, wrapped in `Error: "..."` with the inner quotes escaped.
- A comment between two keywords (`DROP /* c */ TABLE t`,
  `ALTER -- c\nTABLE t ADD COLUMNS (c int)`, `CREATE /* c */ TABLE t AS
  SELECT 1`, `CREATE TABLE t AS /* c */ SELECT 1`, `SHOW /* c */ TABLES`) is
  now read as whitespace when the statement is classified, matching Athena
  (measured 2026-09-22). It used to be read as words of its own, so
  `SubstatementType` was left out for those statements and a CTAS with such a
  comment wrote its result to `<id>.txt` instead of `tables/<id>`. Only the
  classification and the `OutputLocation` file name change; the SQL sent to
  Trino is still untouched.
- `StatementType`, `SubstatementType`, `UpdateCount` and `OutputLocation` are
  now classified correctly for a SQL statement that starts with a comment
  (`-- ...` or `/* ... */`, possibly with more whitespace and comments after
  it): the leading comment is skipped before the classification keyword is
  read, matching Athena, instead of being read as the first word and always
  falling into `UTILITY` / `<id>.txt`. This also fixes the leading query ID of
  the `.metadata` companion file for a commented `DESCRIBE` or
  `SHOW CREATE TABLE`, which must be the `QueryExecutionId` rather than
  Trino's own query ID. Measured against Athena on 2026-09-18.
- `CREATE TABLE ... AS SELECT` now always writes to `tables/<id>`. It used to
  write to `<id>` when the text `table_type = 'ICEBERG'` appeared anywhere in
  the statement, which also caught the text inside a comment, inside a string
  literal, or outside the `WITH` clause. Athena writes `tables/<id>` for all of
  those, and for a real Iceberg CTAS as well, so the table format is no longer
  read out of the SQL at all. Measured against Athena on 2026-09-19, with
  `SHOW CREATE TABLE` confirming the table format; this supersedes the
  2026-09-17 round, which had recorded `<id>` for an Iceberg CTAS. `INSERT`
  keeps writing `<id>`: the same 2026-09-17 round had recorded that value too,
  and measuring it again on 2026-09-20 reproduced it, with controls in the same
  round for a Hive table, an Iceberg table and an `INSERT` that inserts no
  row. The combination that round had left out, an `INSERT` into an Iceberg
  table that inserts no row, was measured on 2026-09-23 beside the other three
  and writes the same `<id>`: no result body, a `.metadata` companion carrying
  an update count of `0`, and no manifest.
- The Caveat about unmeasured file names is gone: `CREATE OR REPLACE TABLE
  ... AS SELECT`, the one statement it listed, turned out to be a syntax error
  on Athena (`line 1:19: mismatched input 'TABLE'. Expecting: 'MATERIALIZED',
  'MULTI', 'PROTECTED', 'VIEW'`, measured 2026-09-23 with and without an
  Iceberg `WITH` clause), so no Athena file name exists for it. athena-local
  still lets Trino run it and keeps naming the result `tables/<id>`; the
  message is now quoted under "Syntax differs".
- The Caveat about unmeasured `.metadata` details no longer lists `MERGE`. The
  companion file Athena writes for a `MERGE` was measured on 2026-09-20 and
  differs from the one for an `UPDATE` or a `DELETE` only in the length of the
  `updateType` string, 74 bytes against 75; every byte after it was identical,
  down to the single `rows bigint` column with `Precision` 19. athena-local
  passes Trino's `updateType` straight through, so no behaviour changed. That
  pass-through was then checked against Trino 482 on 2026-09-22: Trino reports
  `MERGE` for a `MERGE`, and the companion file athena-local wrote matched
  Athena's own byte for byte after the query id.
- `SubstatementType` for `ALTER TABLE` is classified correctly instead of by a
  full-text scan for the words `ADD` and a word starting with `COLUMN`
  anywhere in the statement, which wrongly returned `ALTER_TABLE_ADD_COLUMN`
  for, for example, `ALTER TABLE t SET TBLPROPERTIES ('comment' = 'remember
  to add column for region')`. The `ALTER` arm is now position-fixed like the
  existing `CREATE` / `DROP` arms, and now also returns three measured values
  it left out before: `ALTER_TABLE_PROPERTIES` (`SET TBLPROPERTIES`),
  `ALTER_TABLE_DROP_COLUMN` (`DROP COLUMN`) and `ALTER_TABLE_SET_LOCATION`
  (`SET LOCATION`). `ALTER TABLE IF EXISTS ...` and `RENAME COLUMN` are left
  unclassified: Athena has no such syntax and answers `mismatched input`
  before the statement runs, even though Trino accepts both (see the new
  Caveat). Measured against Athena on 2026-09-21.
- `GetQueryResults` no longer puts the column names in the first row of a
  `SHOW ...` or `DESCRIBE` result. Athena does that only for `StatementType`
  `DML` (`SELECT`, `EXPLAIN`); for `UTILITY` statements the first row is the
  first data row (`SHOW TABLES`, `SHOW DATABASES`, `SHOW COLUMNS`, `SHOW
  CREATE TABLE`, `SHOW PARTITIONS`, `SHOW TBLPROPERTIES` and `DESCRIBE`,
  measured 2026-09-15 to 2026-09-22). Athena JDBC skips the header row only
  for `DML`, so with `ResultFetcher=GetQueryResults` a `SHOW` result had one
  extra row whose value was the column name. `MaxResults` / `NextToken` now
  count data rows only for those statements. The `<id>.txt` result file is
  unchanged (it never had a header line).
- A query whose leading `(` is followed by whitespace or a newline (`( SELECT
  1 ) UNION ALL ( SELECT 2 )`, the shape most formatters emit) is now
  classified like `(SELECT 1)`: `StatementType` is `DML` and the result file
  is `<id>.csv`. The lone `(` used to leave an empty first word, so the
  statement fell through to `UTILITY` and `<id>.txt`, and with the fix above
  `GetQueryResults` would have dropped its first data row instead of the
  header. Found in review of the fix above; Athena's own classification of
  a parenthesised query has not been measured separately.
- `GetQueryResults` now validates `MaxResults` and `NextToken` the way Athena
  does, in Athena's order (measured 2026-09-23). A `MaxResults` below 1, an
  empty `NextToken` and a malformed `NextToken` fail with HTTP 400,
  `InvalidRequestException` and `AthenaErrorCode: INVALID_INPUT` instead of
  being silently clamped to 1 or to the first row, and `MaxResults` above
  1000 fails with `MaxResults is more than maximum allowed length 1000`
  instead of being accepted. Two framework violations at once are reported
  in one `2 validation errors detected: ...` message, `nextToken` first. The
  checks run in Athena's order: framework validation, then the query id,
  then the upper bound, then the query state, then the token. The default
  page size (1000 rows including the header row) is unchanged and matches
  Athena.
- `ListWorkGroups` reports an empty `NextToken` and a `MaxResults` below 1
  sent together as one `2 validation errors detected: ...` message like
  Athena (measured 2026-09-23); it used to report only the `MaxResults`
  violation.
- `GetQueryResults` paging now follows three more Athena behaviours
  measured on 2026-09-23. A full page (exactly `MaxResults` rows) always
  carries a `NextToken`, and the following call returns zero rows without a
  token; athena-local used to omit the token as soon as the last row had
  been sent. A result with no rows at all ignores `NextToken` instead of
  rejecting it as malformed. A `MaxResults` above 100000 fails with the
  framework's `Member must have value less than or equal to 100000` instead
  of the `maximum allowed length 1000` message. `RUNNING` and `CANCELLED`
  queries were also measured and already matched (the state wins over a
  malformed token), as did `ListWorkGroups` with an out-of-range
  `MaxResults` and an empty `NextToken` sent together.
- The remaining type-mismatch combinations were measured on 2026-09-23 and
  now carry Athena's message instead of none: `false` is `FALSE_VALUE can
  not be converted to an Integer` / `a String`, a decimal where a string is
  expected is `NUMBER_VALUE can not be converted to a String`, a number or
  boolean where a list is expected is `Expected list or null`, an object
  where a list is expected is `Start of structure or map found where not
  expected.`, and a number or boolean where a structure is expected is
  `Expected null`. A `null` element inside a list is dropped instead of
  being rejected, as Athena accepts it. A decimal `MaxResults` stays a
  `SerializationException` without `Message` (Athena truncates it).

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
