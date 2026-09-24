# Caveats

Known differences between athena-local and real Athena, grouped by topic.

## SQL dialect

- **SQL dialect drift.** Athena engine v3 is based on a fixed Trino version. A
  local Trino is usually newer, so SQL can pass here and fail on Athena. This
  server executes what it is given; it does not validate Athena compatibility.
- **DDL differs.** Iceberg table DDL is written differently by Athena
  (`table_type='ICEBERG'`) and Trino (`WITH (format = ...)`). Keep DDL out of the
  code paths you want to share.
- **Decimal literals.** Athena types `1.5` as `double`; Trino types it as
  `decimal(2,1)`, and Trino has no session property to change that. So
  `SELECT 0.1 + 0.2` reads `0.30000000000000004` on Athena and `0.3` here, and
  `ColumnInfo.Type` differs. Put the type into the literal — `1.5E0` for a
  `double`, `DECIMAL '1.5'` for a `decimal` — and both engines agree.
- **Syntax differs.** Trino-only syntax such as `CREATE OR REPLACE TABLE` passes
  here but is a syntax error on Athena (`CREATE OR REPLACE TABLE ... AS SELECT`
  answers `InvalidRequestException` with `line 1:19: mismatched input 'TABLE'.
  Expecting: 'MATERIALIZED', 'MULTI', 'PROTECTED', 'VIEW'` and
  `AthenaErrorCode` `MALFORMED_QUERY` before anything runs, with or without an
  Iceberg `WITH` clause, measured 2026-09-23), and the `Expecting:` list in a
  syntax error follows Trino's grammar. `ALTER TABLE IF EXISTS ...` and
  `ALTER TABLE ... RENAME COLUMN ... TO ...` are the same: Trino runs both, but
  Athena's grammar has no such form and answers `mismatched input` before the
  statement starts (measured 2026-09-21), so athena-local executes them on
  Trino where Athena would have rejected the call outright. For an incomplete
  statement (`SELECT * FROM`) Athena answers `Queries of this type are not
  supported`; athena-local returns Trino's syntax error.
- **Iceberg maintenance statements differ.** Athena's `OPTIMIZE ... REWRITE DATA`
  and `VACUUM` do not exist in Trino, which uses `ALTER TABLE ... EXECUTE optimize`
  and `ALTER TABLE ... EXECUTE expire_snapshots` instead.
- **A block comment before `SHOW CREATE TABLE` can succeed here but fails on
  Athena.** `StatementType`/`SubstatementType`/`OutputLocation` are classified
  correctly either way (comments are skipped for classification), but Athena's
  parser for this statement rejects a leading `/* ... */` at execution time
  (measured 2026-09-18): the query fails with `FAILED: ParseException line 1:0
  cannot recognize input near '/' '*' 'c'` and `ErrorCategory` 1 /
  `ErrorType` 1003. A leading `-- ...` line comment is fine on both. The same
  happens with a block comment between the keywords: `SHOW /* c */ CREATE
  TABLE t` and `SHOW CREATE /* c */ TABLE t` are classified as
  `SHOW_CREATE_TABLE` but fail with a `ParseException` (`ErrorCategory` 1 /
  `ErrorType` 1003), and `ALTER /* c */ TABLE t ADD COLUMNS (c int)` against
  a table that does not exist fails with `ParseException line 1:0 cannot
  recognize input near 'ALTER' '/' '*'` where the uncommented statement fails
  with `Table not found`; the same statement against an existing Iceberg
  table succeeds, and `ALTER -- c\nTABLE ...` is fine on both (measured
  2026-09-22). `DROP /* c */ TABLE`, `CREATE /* c */ TABLE ... AS SELECT`,
  `SHOW /* c */ TABLES` and `CREATE` / `DROP /* c */ DATABASE` all succeed on
  Athena. Since athena-local sends the SQL to Trino unmodified, and Trino
  accepts a comment anywhere whitespace is allowed, every block-comment form
  can succeed here where it would fail on real Athena. Two more statements
  fail on Athena with a block comment after the verb: `DESCRIBE /* c */ t`
  (`ParseException line 1:0 cannot recognize input near 'DESCRIBE' '/' '*' in
  describe statement`) and `MSCK REPAIR /* c */ TABLE t` (`ParseException line
  1:12 missing EOF at '/' near 'REPAIR'`), both `ErrorCategory` 1 /
  `ErrorType` 1003 with the reason written to `<id>.txt`; `SHOW PARTITIONS`,
  `SHOW TBLPROPERTIES`, `SHOW COLUMNS FROM`, `SHOW CREATE VIEW` and
  `CREATE EXTERNAL TABLE` with the same comment succeed (measured 2026-09-24).

## `ALTER TABLE` and format-dependent DDL

- **Six `ALTER TABLE` spellings Athena has and Trino does not.** These are
  Athena syntax, not Trino's, so athena-local rejects them at the syntax check
  with `SYNTAX_ERROR` (returned as `InvalidRequestException` /
  `AthenaErrorCode` `MALFORMED_QUERY`, with no `QueryExecutionId` created)
  where Athena would have run them. Checked against Trino 482 on 2026-09-21:

  | Statement | Trino's syntax check | Trino's own spelling |
  | --- | --- | --- |
  | `ADD COLUMNS (...)` | `mismatched input 'COLUMNS'` | `ADD COLUMN` (singular) |
  | `SET TBLPROPERTIES (...)` | `mismatched input 'TBLPROPERTIES'` | `SET PROPERTIES` |
  | `REPLACE COLUMNS (...)` | `mismatched input 'REPLACE'` | none |
  | `ADD PARTITION (...)` | `mismatched input 'PARTITION'` | none |
  | `DROP PARTITION (...)` | `mismatched input 'PARTITION'` | none |
  | `SET LOCATION '...'` | `mismatched input 'LOCATION'` | none |

  Write Trino's spelling where the last column gives one to reach the behaviour
  described under
  [DDL that depends on the target table's format](ddl.md#ddl-that-depends-on-the-target-tables-format);
  classification accepts either spelling, so a statement written as
  `ADD COLUMN` still gets the `ADD COLUMNS` `SubstatementType` (verified
  against Trino 482 and MinIO on 2026-09-21). The four with no Trino spelling
  cannot be run through athena-local at all — their `SubstatementType` and
  result-file rows below record what Athena does, and are reachable here only
  if the backend's grammar accepts the statement.
- **`ALTER TABLE` classification covers eight forms.** `SET TBLPROPERTIES`,
  `ADD COLUMNS`, `DROP COLUMN`, `SET LOCATION`, `REPLACE COLUMNS`,
  `ADD PARTITION`, `DROP PARTITION` and `RENAME TO` each get the
  `SubstatementType` Athena returns (measured 2026-09-21). Note that
  `ALTER_TABLE_REPLACE_COLUMN` is singular although the statement is plural;
  the singular statement `REPLACE COLUMN` is a syntax error on Athena
  (`mismatched input 'REPLACE'`, `MALFORMED_QUERY`, measured 2026-09-24) and is
  left unclassified here.
  Athena returns the `SubstatementType` even when the statement then fails at
  run time, so athena-local classifies these forms regardless of the target's
  format. Any other `ALTER TABLE` form is left unclassified, the same as any
  other statement whose `SubstatementType` was not measured (see
  [Supported API](api.md#supported-api)). Only three of the eight can actually be run
  through athena-local — `ADD COLUMNS` (written as Trino's `ADD COLUMN`),
  `DROP COLUMN` and `RENAME TO`. The other five are rejected at the syntax
  check, so their classification is what athena-local would answer if the
  backend's grammar accepted the statement; `SET TBLPROPERTIES` in particular
  stays unclassified when written in Trino's `SET PROPERTIES` spelling, because
  the classification keyword is the Athena one.
- **`DROP COLUMNS` (plural) is a syntax error on Athena.** `ADD` takes the
  plural `COLUMNS`, but `DROP` takes only the singular `COLUMN`: Athena rejects
  `DROP COLUMNS` in `StartQueryExecution` with `mismatched input 'COLUMNS'.
  Expecting: '.', 'DROP'` (`AthenaErrorCode` `MALFORMED_QUERY`, measured
  2026-09-21). athena-local leaves it unclassified to match; Trino's grammar
  rejects it at the syntax check in any case.
- **Several `ALTER TABLE` combinations fail on Athena itself.** `DROP COLUMN` on
  a Hive table, and `SET TBLPROPERTIES` setting `comment` on an Iceberg table,
  are rejected by Athena's Hive/Iceberg backend. So are `REPLACE COLUMNS`,
  `ADD PARTITION`, `DROP PARTITION` and `SET LOCATION` on an Iceberg table, all
  four with `Query type not supported by Athena Iceberg at this time`, and
  `RENAME TO` on a Hive table, where Glue answers `Table cannot be renamed`
  (measured 2026-09-21; `DROP PARTITION` on 2026-09-24). They fail before
  athena-local's own format-dependent behaviour would matter — not a
  limitation of athena-local.
- **`ADD PARTITION` and `DROP PARTITION` succeed on a partitioned Hive table
  only.** On an Iceberg table Athena accepts the statements but fails both at
  run time (see above); no other partition layout was measured.
- **Table format is detected per Trino catalog.** Real Athena keeps Hive and
  Iceberg tables side by side in one `AwsDataCatalog`; Trino can only put them
  in separate catalogs, so athena-local's detection follows your Trino catalog
  configuration instead: it agrees with Athena only when the Trino catalog
  behind a given Athena table uses the connector Athena would expect. A Trino
  deployment that mixes both formats behind a single catalog, or a
  `TRINO_CATALOG_MAP` alias that points an Athena catalog at the wrong
  connector, gets the files of the catalog's connector instead (an Iceberg
  table in a `hive` catalog is treated as Hive, and the other way round).
  A connector that is neither `hive` nor `iceberg`, a `DROP TABLE IF EXISTS`
  on a missing target, and the other fallback cases listed on the DDL page get
  ordinary column-less DDL (empty file, no `.metadata`). See
  [DDL that depends on the target table's format](ddl.md#ddl-that-depends-on-the-target-tables-format)
  for what this changes.

## Parameters and catalog aliases

- **Parameter classification is an approximation.** It follows the measured rules
  in [`ExecutionParameters`](parameters.md), but a value that closes the parenthesis and still yields one column
  (for example `1) FROM t WHERE (1`) is passed through as an expression, and a
  value ending in a line comment (`1 -- x`) becomes a string literal because the
  comment swallows the closing parenthesis. How Athena classifies those, or a
  bare `?`, has not been measured. Each parameter costs one extra round trip to
  Trino.
- **Catalog aliases in SQL cover quoted names only.** A qualified name is rewritten
  only when its catalog is a double-quoted identifier that equals an alias
  exactly, including case. `AwsDataCatalog.db.users` (unquoted) and
  `"S3TablesCatalog/my-bucket".db.users` (different case) are sent as written.
  Whether Athena treats catalog names case-insensitively has not been measured.
  A name Trino can have, such as `AwsDataCatalog`, needs no alias at all: call
  the Trino catalog `awsdatacatalog` and qualified names resolve, quoted or not,
  since Trino lowercases identifiers. Error messages name the Trino catalog
  (`iceberg.db.users`), and when the Trino name is longer than the Athena name,
  error positions after it shift.

## Value rendering

- **`varbinary` inside `array` / `map` / `row`.** Top-level `varbinary` values
  are converted from Trino's base64 to Athena's `01 02` form (measured). The same
  form is used inside composite values, which was not measured.
- **Map key order.** Map entries are printed in ascending key order: numerically
  for numeric key types (`{9=a, 10=b}`), as strings otherwise (`{j=2, k=1}`).
  Both were measured against Athena; other key types were not.

## Result files and `.metadata`

- **Manifests are not written.** Athena writes a manifest next to the result
  when a statement writes rows into a Hive table: `<id>-manifest.csv` for an
  `INSERT` and `tables/<id>-manifest.csv` for a CTAS (measured 2026-09-20, with
  `SHOW CREATE TABLE` confirming the table format). It writes none for the same
  two statements on an Iceberg table, none for `UPDATE` / `DELETE` / `MERGE`,
  none for an `INSERT` that inserts no row (into a Hive table, measured
  2026-09-20, or into an Iceberg table, measured 2026-09-23), and none for a
  failed `INSERT` —
  although the failure message names the manifest path it would have used.
  athena-local writes no manifest at all; `OutputLocation` still names the
  result file Athena would use. The `.metadata` companion is written (see
  [Result files](result-files.md)).
- **`SHOW` metadata is not the opaque form Athena writes.** For `SHOW TABLES`,
  `SHOW DATABASES`, `SHOW COLUMNS`, `SHOW PARTITIONS` and `SHOW TBLPROPERTIES`,
  real Athena writes a base64 blob that does not decode as protobuf (measured
  2026-09-16, 2026-09-17 and 2026-09-18). The blob is 312 base64 characters for
  the first four statements and 460 for `SHOW TBLPROPERTIES`, decoding to a
  fixed 233 and 345 bytes whatever the result holds. Only the leading byte
  `0x01` is stable: everything after it differs between measurement rounds and
  sometimes between two statements of the same round, and running the same
  `SHOW TABLES` twice over the same tables yields different bytes. That is
  consistent with an encrypted payload, but **what the format actually is has
  not been identified** and is not reproduced here. The result file itself is
  unaffected — it is the same plain text Athena writes for any other `SHOW`.
  `SHOW CREATE TABLE` is not affected either: it writes plain protobuf, like
  `DESCRIBE`. athena-local writes the same plain protobuf it writes for every
  other statement, so a client that parses it sees the columns instead of
  failing. Athena JDBC 3.8.1 in its default `ResultFetcher=auto` fetches that
  companion file and reads it without an exception: verified for `SHOW TABLES`
  on 2026-09-17, and on 2026-09-22 for `SHOW SCHEMAS` (one column) and
  `SHOW COLUMNS` (Trino's four columns, 205 bytes) in the same run. The driver
  logs `loaded query result metadata` for each, then still presents the `.txt`
  body as a single `varchar` column named `_col0`, one row per line; with
  `ResultFetcher=S3` it does not fetch the `.txt.metadata` at all, and with
  `ResultFetcher=GetQueryResults` it never touches S3. The other three
  statements cannot reach the file: `SHOW DATABASES`, `SHOW PARTITIONS` and
  `SHOW TBLPROPERTIES` are Athena syntax that Trino's grammar lacks, so the
  syntax check rejects them (`mismatched input 'DATABASES'` and so on, returned
  as `InvalidRequestException` before any file is written; Trino 482,
  2026-09-22). Write `SHOW SCHEMAS` for `SHOW DATABASES` (classified as
  `SHOW_DATABASES`, see [Supported API](api.md#supported-api)) and `SELECT * FROM "<table>$partitions"` for
  `SHOW PARTITIONS`; `SHOW TBLPROPERTIES` has no Trino spelling
  (`SHOW CREATE TABLE` includes the properties).
- **Zero update counts and less common column types in `.metadata`.** The
  update count of an `INSERT` that inserts no row is written as `0`
  (`18 00`), which is what Athena writes for a Hive table (measured
  2026-09-20) and for an Iceberg table (measured 2026-09-23), each beside a
  one-row `INSERT` in the same round whose file differed in that byte only.
  An `UPDATE`, `DELETE` or `MERGE` that changes no rows
  (`DELETE ... WHERE false`) is written with `0` too, as Athena does on an
  Iceberg table (measured 2026-09-24). Columns of type
  `timestamp with time zone` and `time with time zone` are written like
  `timestamp` / `time`, `interval year to month` like
  `interval day to second`, and `uuid` and `ipaddress` without Precision,
  Scale or CaseSensitive, all as Athena writes them (measured 2026-09-24).
- **A missing bucket fails a query whose result is a CSV.** Athena reported
  `SUCCEEDED` for a `SELECT` whose output bucket did not exist (measured).
  athena-local makes a `SELECT` (or `SHOW FUNCTIONS`) `FAILED` so the mistake
  shows up locally. A statement that writes only a `<id>.txt` or only a
  `.metadata` companion (DDL, other `SHOW`, DML, CTAS) stays `SUCCEEDED` and
  logs one line (see [Result files](result-files.md#result-files)).
- **`CREATE OR REPLACE TABLE ... AS` has no Athena file name.** Athena rejects
  the statement as a syntax error before it starts (see "Syntax differs"), so
  there is nothing to match; athena-local, which lets Trino run it, names its
  result `tables/<id>` by the CTAS rule below (on Trino 482 the Iceberg
  connector runs it and the Hive connector fails with `This connector does not
  support replacing tables`). A CTAS always gets `tables/<id>`: Athena used that name for an Iceberg CTAS
  too, both for `WITH (table_type = 'ICEBERG')` and for the Hive default
  (measured 2026-09-19, with `SHOW CREATE TABLE` confirming the table really was
  Iceberg). An earlier round had recorded `<id>` for the same statement
  (2026-09-17); the later measurement is the one reproduced here. `INSERT`
  keeps `<id>`, and that value was measured again on 2026-09-20 with controls in
  the same round: an `INSERT` into a Hive table, one into an Iceberg table and
  one that inserts no row all wrote `<id>`, while the `SELECT`, CTAS and
  `SHOW TABLES` measured beside them wrote `<id>.csv`, `tables/<id>` and
  `<id>.txt` as before. `MERGE` was measured for the first time in that round
  and writes `<id>.csv`, like `UPDATE` and `DELETE`. The one combination that
  round had left out, an `INSERT` into an Iceberg table that inserts no row,
  was measured on 2026-09-23 beside the other three combinations of table
  format and row count: `<id>`, no result body, a 75-byte `.metadata` carrying
  `INSERT` and an update count of `0`, and no manifest, exactly like the Hive
  one.

## Failed queries

- **A failed query writes a result file for more statements than Athena.** On
  Athena it depends on the engine behind the statement: DDL that runs through
  Hive writes `<id>.txt` holding the reason (`SHOW TABLES`, `DROP TABLE` and
  `CREATE DATABASE`, measured 2026-09-17), while statements that run on the
  query engine write no file at all, namely `SELECT`, `INSERT`, `UPDATE`,
  `DELETE` and CTAS (measured 2026-09-17, and the `INSERT` case again on
  2026-09-20: a type-mismatched `INSERT` left neither the result file nor the
  `.metadata` companion) and `ALTER TABLE` on an Iceberg table
  (measured 2026-09-16 and 2026-09-17, and again on 2026-09-21: a failed
  `RENAME TO` on a Hive table wrote its reason to `<id>.txt`, while failed
  `REPLACE COLUMNS`, `ADD PARTITION` and `SET LOCATION` on an Iceberg table
  wrote no file at all). athena-local runs everything through
  Trino and cannot tell the two apart, so it writes the file for every statement
  whose result file is `<id>.txt` except `EXPLAIN`, which runs on the query
  engine on Athena too and left neither the file nor the `.metadata` companion
  when it failed (`EXPLAIN` and `EXPLAIN ANALYZE` on a missing table, measured
  2026-09-23).
- **The failed result file does not match `StateChangeReason`.** On Athena the
  file is `StateChangeReason` byte for byte, and that text starts with
  `FAILED: ` because it comes from Hive (`FAILED: SemanticException
  [Error 10001]: Table not found ...`, measured 2026-09-17). athena-local's
  reason comes from Trino instead (`TABLE_NOT_FOUND: line 1:15: ...`), so it
  prefixes `FAILED: ` to mark the file as a failure, which makes the file longer
  than `StateChangeReason` by exactly that prefix.
- **`SHOW COLUMNS` and `DESCRIBE` on a missing table fail later than on Athena.**
  Athena rejects them in `StartQueryExecution` with `InvalidRequestException`
  (`AthenaErrorCode` `INVALID_INPUT`, message `Entity Not Found`) and creates no
  execution at all (measured 2026-09-17). athena-local accepts the call, the
  query becomes `FAILED`, and it writes `<id>.txt` as described above.
- **`GetQueryResults` on a failed query always fails.** On Athena the answer
  depends on the statement: DDL that runs through Hive returns HTTP 200 with an
  empty `ResultSet` whose `ResultSetMetadata` is null, `SELECT`, DML and CTAS
  return `INVALID_QUERY_EXECUTION_STATE`, and `ALTER TABLE` on an Iceberg table
  returns `RESULT_NOT_FOUND` (measured 2026-09-17). athena-local always returns
  `INVALID_QUERY_EXECUTION_STATE`.

## Query lifecycle

- **Cancellation is checked between pages.** A stopped query is `CANCELLED`
  at once, but the `DELETE` reaches Trino only when the current long poll to
  `nextUri` returns (about a second at most).
- **`ClientRequestToken` is required and not normalized.** Omitting it, or
  sending one shorter than 32 or longer than 128 characters, fails with
  `INVALID_INPUT` (see [Supported API](api.md#supported-api)); the length is counted with
  `chars().count()`, which was only measured with ASCII input, so whether real
  Athena counts bytes or characters for non-ASCII tokens is unknown. A token
  that passes validation is used verbatim as a map key: case, leading/trailing
  whitespace and non-ASCII characters are all significant. Real Athena does
  not normalize it either: leading/trailing spaces, an upper-cased copy, and a
  `"` or `\` in place of one character each started a new query (measured
  2026-09-24). `Database` and `OutputLocation` are
  compared as sent, before `TRINO_SCHEMA` or `ATHENA_LOCAL_OUTPUT_LOCATION`
  fills them in, so a retry that spells out the default a first call left out
  is `IDEMPOTENT_PARAMETER_MISMATCH`; whether real Athena does the same has
  not been measured. The token → id mapping is kept in memory until the
  execution it points at is dropped (`ATHENA_LOCAL_RETENTION_SECONDS`), and
  real Athena's token lifetime beyond 67 minutes (2026-09-24) has not
  been measured.
  **Raw HTTP / curl clients must supply their own token** — the AWS CLI and
  SDKs add one automatically, but a request built by hand needs to set
  `ClientRequestToken` itself (measured).
- **Finished queries are dropped after a retention period.** A query that has
  reached `SUCCEEDED`, `FAILED` or `CANCELLED` is kept for
  `ATHENA_LOCAL_RETENTION_SECONDS` (one hour by default) and then dropped,
  together with the `ClientRequestToken` that points at it; queued and running
  queries are never dropped. Real Athena's retention period has not been
  measured beyond 67 minutes (2026-09-24), so one hour is
  athena-local's own number. Once a
  query is dropped, `GetQueryExecution`, `GetQueryResults` and
  `StopQueryExecution` treat its id like an unknown one and fail with
  `QUERY_EXECUTION_NOT_FOUND`; what real Athena returns for an expired id has
  not been measured. The period counts from completion and reading the query
  does not extend it, so a client that pages through `GetQueryResults` for
  longer than the period loses the rest of the result. `StopQueryExecution`
  therefore changes from succeeding on a finished query to failing once the
  period has passed. Resending the same `ClientRequestToken` after that starts
  a new query with a new `QueryExecutionId`, so an `INSERT` or CTAS retried
  after the period runs again; how real Athena treats an expired token has not
  been measured. Dropping happens whenever an API call touches the store, not
  on a timer, so nothing is swept while the server is idle; memory stays
  bounded by the queries that finished within the period: a 240-second run of
  back-to-back 2 MiB results at a retention of 1 s grew by only 18 MiB after
  warm-up, while the same load at 3600 s kept growing (measured 2026-09-23 with
  `tools/e2e/retention/verify.sh`). Dropping a query
  does not touch its result files: with `ATHENA_LOCAL_RESULTS=s3`, the
  `<id>.csv` and `<id>.csv.metadata` stay in the output location after
  `GetQueryExecution` has started failing with `QUERY_EXECUTION_NOT_FOUND`
  (checked against MinIO, 2026-09-23).

## Paging

- **`GetQueryResults` paging validates its arguments the way Athena does,
  in Athena's order.** Measured 2026-09-23: the framework checks come first
  (an empty `NextToken` and a `MaxResults` below 1 fail with
  `INVALID_INPUT` and `1 validation error detected: ...`; both at once give
  `2 validation errors detected: ...` listing `nextToken` before
  `maxResults`; a `MaxResults` above 100000 is caught here too, with
  `Member must have value less than or equal to 100000`), then the query id
  must exist (`QUERY_EXECUTION_NOT_FOUND`), then `MaxResults` above 1000
  fails with `MaxResults is more than maximum allowed length 1000`, then the
  query must have finished successfully (`RUNNING`, `FAILED` and `CANCELLED`
  all win over a malformed token), and only then is a malformed `NextToken`
  rejected with `Malformed nextPageToken <token>`. The page size defaults to
  1000 rows counting the header row, as on Athena. A page that is full
  (exactly `MaxResults` rows) always carries a `NextToken`, even when
  nothing is left, and the next call then returns zero rows and no token;
  this is how Athena behaves for a result of 6 rows fetched 6 or 3 at a time
  and for a header-only result fetched 1 at a time. A result with no rows
  at all (a `SHOW` that matched nothing) ignores `NextToken` and answers
  200 with zero rows, as Athena does. `NextToken` is the offset of the next
  page as a decimal string rather than Athena's opaque token, so the
  malformed-token check accepts any string that parses as an offset inside
  the result or just past its end (`0`, a leading zero or a `+` sign
  included) and rejects everything else. All of this was measured on
  2026-09-23.
- **`ListWorkGroups` paging differs from Athena in two ways.** The default page
  size is 50, the largest `MaxResults` Athena accepts; Athena's own default was
  not measured. `NextToken` is the offset of the next page as a decimal string
  rather than an opaque token. Errors match: `MaxResults` outside 1..50 and a
  malformed or empty `NextToken` fail with HTTP 400, `InvalidRequestException`,
  `AthenaErrorCode: INVALID_INPUT` and Athena's messages (measured 2026-09-18);
  an empty `NextToken` together with a `MaxResults` below 1 gives the same
  combined `2 validation errors detected: ...` message as `GetQueryResults`
  (measured 2026-09-23), and so does an empty `NextToken` together with a
  `MaxResults` above 50; a `MaxResults` out of range together with a
  malformed `NextToken` reports only the `MaxResults` violation (measured
  2026-09-23). When the list fits in one page the `NextToken` key is
  omitted, never `""`: Grafana loops until the token is absent.

## Workgroups

- **Any workgroup name is accepted.** `GetWorkGroup` never fails because of the
  name: it echoes the name back and returns the same `Configuration` every time,
  because athena-local has no workgroups to look up. Real Athena answers a name
  that does not exist with HTTP 400, `InvalidRequestException`, the message
  `WorkGroup is not found.` and `AthenaErrorCode: INVALID_INPUT`;
  `StartQueryExecution` fails the same way (measured 2026-09-17). Per-workgroup
  settings are not reproduced.
- **`GetWorkGroup` omits some fields Athena returns.** `CreationTime` is left
  out because athena-local has no workgroup that was ever created, so any value
  would be invented. No client reads it (measured 2026-09-17).
  `Configuration.QuerySchedulingType` (`DEFAULT` on the wire) and
  `EngineVersion.Category` (`Presto` on the wire) are not in the SDK model, so
  no client can read them; neither is returned (measured 2026-09-23).
  `Configuration.EnableMinimumEncryptionConfiguration` is returned as `false`,
  the value Athena returned (measured 2026-09-23).
- **`ListWorkGroups` lists a fixed set of names.** The list comes from
  `ATHENA_LOCAL_WORK_GROUPS`, not from workgroups anyone created, and it is
  sorted by name like Athena's (measured with 3 workgroups, 2026-09-18). It
  does not restrict anything: `GetWorkGroup` succeeds for a name that is not
  listed, and `StartQueryExecution` without a `WorkGroup` still records
  `primary` even when `primary` is not listed. Grafana's data source settings
  read this list to fill the workgroup dropdown and read nothing but the names.
- **`ListWorkGroups` entries are smaller than Athena's.** `Description` is
  always `""`, which is what Athena returns for a workgroup without a
  description (`GetWorkGroup` omits the key for the same workgroup; both
  measured 2026-09-18). `CreationTime` is left out for the reason above.
  `IdentityCenterApplicationArn` was absent from the measured response, and
  `EngineVersion.Category` (`Presto` on the wire) is not in the SDK model, so
  no client can read it; neither is returned.

## Clients and transport

- **awswrangler reaches real AWS when no output location is set.** If neither
  the call nor `ATHENA_LOCAL_OUTPUT_LOCATION` supplies one, awswrangler resolves
  the location itself: it calls STS and creates a bucket named
  `aws-athena-query-results-{account}-{region}`, its own documented fallback.
  Those calls go to real AWS unless `AWS_ENDPOINT_URL` covers every service, not
  just Athena. Set `ATHENA_LOCAL_OUTPUT_LOCATION` to keep the run local.
  athena-local warns about this once at startup whenever it has no default
  output location to report, which includes every `ATHENA_LOCAL_RESULTS=none`
  run, because `GetWorkGroup` then leaves `OutputLocation` out either way. The
  warning goes to stderr and does not stop the server; athena-local still does
  not block the outgoing calls, since that would mean answering unlike real
  Athena.
- **Plain HTTP only.** The clients are built without TLS, for both Trino and
  the S3-compatible store, and the server itself speaks plain HTTP. To reach an
  HTTPS endpoint, add the `rustls` feature to `reqwest` in `Cargo.toml` (and CA
  certificates to the image). A client that refuses plain HTTP needs a TLS
  terminator in front instead; Athena JDBC 3.x is one, and [Clients](clients.md) has a worked
  nginx example.

## Errors and request bodies

- **Error body key casing.** Error responses use `Message` (capital M), and an
  error that carries `AthenaErrorCode` also carries `ErrorCode` with the same
  value; both match real Athena (measured for `IDEMPOTENT_PARAMETER_MISMATCH`
  and `WorkGroup is not found.`, and on 2026-09-24 for a syntax error's
  `MALFORMED_QUERY`). Errors without an `AthenaErrorCode`
  (`SerializationException`, `InternalServerException`) carry neither
  `AthenaErrorCode` nor `ErrorCode`, as measured for `SerializationException`
  on 2026-09-23; `InternalServerException` cannot be measured, because only a
  failure inside Athena produces it and no request provokes one. The AWS SDKs
  read both `message` and `Message` (botocore and smithy-rs each check the two
  spellings explicitly), so the casing does not affect ordinary clients.
- **Request bodies fail the way Athena's do.** Measured 2026-09-23 with 46
  malformed requests. A value of the wrong JSON type fails with HTTP 400 and
  `__type: SerializationException` (no `AthenaErrorCode`), and the `Message`
  is the one Athena gives for that combination: `STRING_VALUE can not be
  converted to an Integer`, `NUMBER_VALUE can not be converted to a String`,
  `TRUE_VALUE can not be converted to an Integer` / `a String`, `Start of
  list found where not expected`, `Start of structure or map found where
  not expected.`, `Expected list or null` (a string for `ExecutionParameters`)
  and `Expected null` (a string for `ResultConfiguration`); `FALSE_VALUE`,
  a decimal as `NUMBER_VALUE`, and an integer or `true` where a list
  (`Expected list or null`) or a structure (`Expected null`) is expected
  were measured in a second round (2026-09-23); `false` or a decimal in
  those two positions was not, and gets no `Message`. A body that is
  not JSON at all (truncated, empty, `null`, a bare string, a trailing comma)
  is a `SerializationException` with no `Message` key, and a body that is a
  JSON array gets `Start of list found where not expected`. A required
  member that is missing or `null` fails with `InvalidRequestException`,
  `AthenaErrorCode: INVALID_INPUT` and `1 validation error detected: Value
  null at 'queryExecutionId' failed to satisfy constraint: Member must not
  be null` (the member name in lowerCamel), an optional member that is
  `null` is treated as absent, unknown members are ignored, and a
  `MaxResults` beyond the 32-bit range falls through to the usual
  upper-bound validation (one beyond the 64-bit signed range was not
  measured, and gets a `SerializationException` with no `Message`). A `null` inside a list (`"ExecutionParameters":
  [null]`) is dropped, as Athena accepts it. Two known differences: Athena
  truncates a decimal `MaxResults` such as `1.5` to `1`, and athena-local
  rejects it with a `SerializationException` that has no `Message`; and a JSON array for a nested structure
  (`"QueryExecutionContext": []`, or `["s3://b/"]` for `ResultConfiguration`)
  is read positionally as that structure, where Athena answers `Start of
  list found where not expected`. A request whose
  `X-Amz-Target` is missing, lacks the
  `AmazonAthena.` prefix, or names an unsupported or differently cased
  operation is `{"__type":"UnknownOperationException"}` with no `Message`,
  as on Athena. The `Content-Type` header is not checked (Athena answers a
  wrong one with a different protocol's response).
