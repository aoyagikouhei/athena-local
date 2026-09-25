# Supported API

The Athena operations athena-local answers, and the Athena behaviour it reproduces for them.

| Operation | Notes |
| --- | --- |
| `StartQueryExecution` | Returns an id immediately; the query runs in the background. `ExecutionParameters` are supported (see [`ExecutionParameters`](parameters.md)). `ClientRequestToken` is required and makes retries idempotent (see below) |
| `GetQueryExecution` | `QUEUED` → `RUNNING` → `SUCCEEDED` / `FAILED` / `CANCELLED`. Trino errors land in `Status.StateChangeReason`. `WorkGroup` is the name `StartQueryExecution` was given, or `primary` when it was omitted. `QueryExecutionContext.Catalog` is returned lower-cased and `Database` as sent, and a value the request left out is left out of the response (the `TRINO_CATALOG` / `TRINO_SCHEMA` defaults are not echoed), as real Athena does (measured 2026-09-24; see [Caveats](caveats.md#query-lifecycle)) |
| `GetQueryResults` | Paginated with `MaxResults` / `NextToken` (1..1000, default 1000 rows including the header row). Out-of-range `MaxResults` and malformed `NextToken` fail the way Athena does (see [Caveats](caveats.md#paging)) |
| `StopQueryExecution` | Marks a queued or running query `CANCELLED` immediately and sends `DELETE` to Trino's `nextUri`. Stopping a finished query succeeds and changes nothing |
| `GetWorkGroup` | Accepts any workgroup name and returns the same configuration for all of them. `Configuration.ResultConfiguration.OutputLocation` reflects `ATHENA_LOCAL_OUTPUT_LOCATION` when it is set with `ATHENA_LOCAL_RESULTS=s3`. `Configuration.ResultConfiguration` is always present, and is `{}` otherwise (with `ATHENA_LOCAL_RESULTS=none` the variable is ignored) |
| `ListWorkGroups` | Lists the names from `ATHENA_LOCAL_WORK_GROUPS` (just `primary` when unset) in name order, with the same `State` and `EngineVersion` as `GetWorkGroup`. Paginated with `MaxResults` / `NextToken`; out-of-range `MaxResults` and malformed `NextToken` fail the way Athena does |

Behaviour that matches real Athena:

- The first row of the first page of a `SELECT` or `EXPLAIN` result (`StatementType`
  `DML`) holds the column names. `TABLE t`, Trino's shorthand for
  `SELECT * FROM t`, is accepted by Athena and counts as `DML` / `SELECT` too
  (measured 2026-09-22). `SHOW ...` and `DESCRIBE` (`UTILITY`) start with
  the first data row instead, as on Athena (`SHOW TABLES`, `SHOW DATABASES`,
  `SHOW COLUMNS`, `SHOW CREATE TABLE`, `SHOW PARTITIONS`, `SHOW TBLPROPERTIES`
  and `DESCRIBE`, measured 2026-09-15 to 2026-09-22). `SHOW FUNCTIONS` is the
  one `UTILITY` statement whose result starts with the column names, as on
  Athena (measured 2026-09-23). Athena JDBC skips the
  header row only for `DML`, so it used to show the column name as the first
  row of a `SHOW` result with `ResultFetcher=GetQueryResults`.
- Values are returned as strings (`Datum.VarCharValue`); NULL omits the field.
- Timestamps keep their precision (`2020-01-01 12:34:56.789123` for
  `timestamp(6)`, no fraction for `timestamp(0)`), as Athena does.
- `ColumnInfo` looks like Athena's: `Type` is the base name (`varchar`, `decimal`,
  `array`, `timestamp`, and `float` for `real`); `Precision` / `Scale` carry the
  `decimal` digits and the `varchar` / `char` length, and Athena's fixed values for
  other types (`tinyint` 3, `smallint` 5, `integer` 10, `bigint` 19, `double` and
  `float` 17, `timestamp` and `time` 3, `varbinary` 1073741824, 0 otherwise); `CaseSensitive` is true for `varchar` and
  `char`; `CatalogName` is `hive` with empty `SchemaName` / `TableName`.
- `SHOW CREATE TABLE` reports its one column as `createtab_stmt` of type
  `string` (on a Hive and on an Iceberg table alike) and `SHOW CREATE VIEW` as
  `create view` of type `varchar`, both with `Precision` 0 and `CaseSensitive`
  false, as real Athena does (measured 2026-09-23 and 2026-09-24), instead of
  Trino's `Create Table` / `Create View` `varchar`. The `.metadata` companion
  carries the same column, so the companion of `SHOW CREATE TABLE` on a Hive
  table is byte-for-byte Athena's 88-byte file apart from the query id.
  `SHOW TABLES` reports `tab_name`, `SHOW SCHEMAS` `database_name`,
  `SHOW COLUMNS` the single column `field` and `DESCRIBE` / `DESC` the three
  columns `col_name` / `data_type` / `comment`, all `string` with `Precision` 0
  and `CaseSensitive` false, in `GetQueryResults` and in the `.metadata`
  companion alike (measured 2026-09-23 and 2026-09-24).
- `SHOW COLUMNS` and `DESCRIBE` return Athena's rows rather than Trino's four
  columns: one value per row, which for `DESCRIBE` is the column name, type and
  comment joined with tabs. On a Hive table (or when the format cannot be
  determined) each field is padded with spaces to 20 characters and types use
  Hive's spelling (`int`, `string`, `array<string>`), with a
  `# Partition Information` block after the columns when the table is
  partitioned; on an Iceberg table nothing is padded and `DESCRIBE` lists
  `# Table schema:` and `# Partition spec:` sections in Iceberg's spelling. On
  a view both statements return Athena's two `varchar` columns `column` /
  `type` with `name<TAB>type` rows (measured 2026-09-24). See
  [Result files](result-files.md) for the exact rows and
  [Caveats](caveats.md#result-files-and-metadata) for what still differs.
- The `Query Plan` column of `EXPLAIN` is typed `varchar(<length of the plan
  text>)` by the engine: 371 for `EXPLAIN SELECT 1` on Athena engine version 3
  (measured 2026-09-15 and 2026-09-16), 400 for the same statement on Trino 482,
  counted in characters. athena-local passes Trino's length through as
  `Precision`, so the number differs from Athena's only because the plan text
  differs between the engines.
- `EXPLAIN` returns one row per line of the plan. Trino returns the whole plan
  as a single `Query Plan` value with embedded newlines (ending in `\n\n`);
  Athena appends one newline to that text and splits it on `\n`, so
  `EXPLAIN SELECT 1` gives the header row, 11 plan lines and 3 empty rows, 15
  rows in all (measured 2026-09-15 and 2026-09-16, four runs). athena-local
  splits the same way, for `GetQueryResults` and for the `<id>.txt` file. The
  same rule holds for every `EXPLAIN` form measured on 2026-09-23 in one round:
  `(FORMAT JSON)` and `(TYPE IO)`, whose plan text ends without a newline, end
  in one empty row; `(FORMAT GRAPHVIZ)` ends in two; `(TYPE DISTRIBUTED)`,
  `ANALYZE` and `ANALYZE VERBOSE` end in three like the plain form; and
  `(TYPE VALIDATE)`, whose single `boolean` value Athena renders as `true`,
  gives `Valid`, `true` and one empty row. `EXPLAIN ANALYZE` keeps the
  `SubstatementType` `EXPLAIN`.
- `SHOW CREATE TABLE` and `SHOW CREATE VIEW` return one row per line of the
  statement. Trino returns the whole text as a single value with embedded
  newlines; Athena returns as many rows as the `<id>.txt` file has lines, with
  no trailing empty row (measured 2026-09-16 and 2026-09-24 on Hive and Iceberg
  tables and on a view). The `<id>.txt` file is unchanged by the split.
- `double` and `real` values use Java's notation: `1.5`, `0.30000000000000004`,
  `1.0E20`, `1.0E-7`.
- `array`, `map` and `row` values use Athena's notation rather than JSON:
  `[1, 2, 3]`, `[a, null]`, `[[1], [2, 3]]`, `{k=1}`, `{id=1, name=x}`, and
  `{1, x}` for an unnamed row. Strings inside are not quoted, exactly as in Athena
  (so `ARRAY['a, b']` reads `[a, b]`). The column's `typeSignature` from Trino
  tells a row from an array; without it the value falls back to JSON.
- DML (`INSERT` / `UPDATE` / `DELETE` / `MERGE`) and CTAS return no rows, set
  `UpdateCount`, and list a `rows` (`bigint`) column in `ColumnInfo`. DDL without a
  count returns neither rows nor columns. Measured on Hive-format and Iceberg tables.
- `SELECT` and `SHOW` return `UpdateCount` `0`; DDL and `EXPLAIN` (every
  variant, `EXPLAIN ANALYZE` included; measured 2026-09-16 to 2026-09-23) leave
  it out (Athena sends `null`, which SDKs read the same way). `DESCRIBE` and `SHOW CREATE TABLE`
  follow the target table's format: on a Hive table (or when the format cannot
  be determined) they leave `UpdateCount` out, on an Iceberg table they return
  `0` (measured 2026-09-24; see
  [DDL that depends on the target table's format](ddl.md#ddl-that-depends-on-the-target-tables-format)).
- Every statement that has columns gets a companion `.metadata` file next to its
  result file with `ATHENA_LOCAL_RESULTS=s3`, the protobuf sidecar Athena JDBC
  3.x reads by default. See [Result files](result-files.md).
- `GetQueryResults` on a query without results returns `InvalidRequestException`
  with Athena's message and `AthenaErrorCode`:

  | State | Message | `AthenaErrorCode` |
  | --- | --- | --- |
  | `QUEUED` / `RUNNING` | `Query has not yet finished. Current state: <state>` (`RUNNING` measured; `QUEUED` while still queued) | `INVALID_QUERY_EXECUTION_STATE` |
  | `FAILED` | `Query did not finish successfully. Final query state: FAILED` | `INVALID_QUERY_EXECUTION_STATE` (see [Caveats](caveats.md#failed-queries)) |
  | `CANCELLED` | `Could not find results` | `RESULT_NOT_FOUND` |

  An unknown id returns `QueryExecution <id> was not found` (`QUERY_EXECUTION_NOT_FOUND`).
- A stopped query reports `StateChangeReason` `Query cancelled by user`.
- A syntax error makes `StartQueryExecution` fail with `InvalidRequestException`
  (`AthenaErrorCode` `MALFORMED_QUERY`) instead of creating a `FAILED` query, as
  Athena does. The message is Trino's, with positions counted in the original SQL
  (also when `ExecutionParameters` are given). athena-local asks Trino to `PREPARE`
  the statement first, which parses without executing and adds one round trip
  (about 10–20 ms). Right after that check, for `DESCRIBE`, `DESC` and
  `SHOW COLUMNS FROM` / `IN`, `StartQueryExecution` also checks whether the
  target exists, the same way real Athena does: a table or schema it can
  prove is missing answers `InvalidRequestException` / `AthenaErrorCode`
  `INVALID_INPUT` with Athena's `Entity Not Found` message, and a three-part
  name whose catalog does not exist in Trino answers
  `InvalidRequestException` / `AthenaErrorCode` `DATACATALOG_NOT_FOUND`; a
  view runs even with a quoted name. Then `StartQueryExecution` rejects
  `DESCRIBE`, `DESC`, `SHOW COLUMNS`, `DROP TABLE`, `SHOW CREATE TABLE`,
  `ALTER TABLE`, `SHOW TABLES IN` and a plain `CREATE TABLE` whose table name
  has a double-quoted part, with `InvalidRequestException` /
  `AthenaErrorCode` `MALFORMED_QUERY` and real Athena's own message, the same
  way real Athena does; no `QueryExecutionId` is created for either check.
  See [Caveats](caveats.md#sql-dialect) for exactly which forms and the
  message rules.
- `StatementType` and `SubstatementType` follow Athena: `SELECT` / `WITH` /
  `VALUES` / `TABLE` are `DML` / `SELECT`, `EXPLAIN` is `DML` / `EXPLAIN`, `SHOW TABLES` is
  `UTILITY` / `SHOW_TABLES`, `SHOW FUNCTIONS` is `UTILITY` / `SHOW_FUNCTIONS`
  (measured 2026-09-23), `CREATE TABLE ... AS SELECT` is `DDL` /
  `CREATE_TABLE_AS_SELECT` (so are `AS VALUES`, `AS TABLE` and a
  parenthesised query such as `AS (VALUES 1)` or `AS(SELECT 1)`, measured
  2026-09-25), and so on. Trino spellings map to Athena's
  (`CREATE SCHEMA` is `CREATE_DATABASE`, `SHOW SCHEMAS` is `SHOW_DATABASES`;
  Athena accepts `SHOW SCHEMAS` too and classifies it the same way, measured
  2026-09-24). `DESC` is `UTILITY` / `DESCRIBE_TABLE` like `DESCRIBE`.
  `DESCRIBE` and `SHOW COLUMNS` on a view are `UTILITY` / `DESC_VIEW`, as on
  Athena (measured 2026-09-24); athena-local knows the target is a view only
  once the query has run, so the value is decided when the query completes
  and `GetQueryExecution` reports `DESCRIBE_TABLE` or `SHOW_COLUMNS` until then.
  `VACUUM` is `DML` and `OPTIMIZE` is `DDL`.
  Statements whose `SubstatementType` was not measured leave the field out.
  Leading whitespace and comments (`-- ...`, `/* ... */`, possibly interleaved)
  are skipped before the classification keyword is read, the same way Athena
  does (measured 2026-09-18), and a comment between keywords
  (`DROP /* c */ TABLE t`, `CREATE TABLE t AS -- c\nSELECT 1`) counts as
  whitespace, also the same way Athena does (measured 2026-09-22); this also
  decides the `OutputLocation` file name and, for `DESCRIBE` /
  `SHOW CREATE TABLE`, whether the `.metadata` file's leading query ID is the
  `QueryExecutionId` or Trino's own ID. A keyword with no space before what
  follows it (`SELECT(1)`, `SELECT'a'`, `SELECT*FROM t`,
  `CREATE TABLE"t" AS SELECT ...`) classifies the same as the spaced form too
  (measured 2026-09-25); see [Caveats](caveats.md#sql-dialect) for the quoted
  table-name forms that real Athena and athena-local both reject before
  running, whether or not there is a space before the quote.
- A `FAILED` query carries `Status.AthenaError` with the same `ErrorMessage` as
  `StateChangeReason`. Trino's user errors are `ErrorCategory` 2 with the
  `ErrorType` Athena uses for that error name (measured: `TABLE_NOT_FOUND` and
  `SCHEMA_NOT_FOUND` 1301, `COLUMN_NOT_FOUND` 1006, `TYPE_MISMATCH` 1002,
  `FUNCTION_NOT_FOUND` 1303, `DIVISION_BY_ZERO` 1001, `INVALID_CAST_ARGUMENT` 1100,
  `NOT_SUPPORTED` 1200, and a few more), 1000 for names not measured, and
  `Retryable` false. Other Trino errors are category 1 with `ErrorType` 200.
  athena-local's own failures are category 1 and retryable: Trino unreachable is
  100, a failed result upload is 401. Cancelled queries have no `AthenaError`.
- `Statistics` holds timings measured by athena-local: `QueryQueueTimeInMillis`
  (submitted until sent to Trino), `EngineExecutionTimeInMillis` (from then until
  finished, including parameter classification and the result upload) and
  `TotalExecutionTimeInMillis` (their sum). `DataScannedInBytes` is always 0.
- A `StartQueryExecution` retry with the same `ClientRequestToken` returns the
  same `QueryExecutionId` no matter what state the first query is in (queued,
  running, `SUCCEEDED`, `FAILED` or `CANCELLED`), and does not run the query
  again. A retry whose `QueryString`, `QueryExecutionContext.Catalog`,
  `QueryExecutionContext.Database` or `ResultConfiguration.OutputLocation`
  differs from the first call instead fails with `InvalidRequestException` /
  `AthenaErrorCode` and `ErrorCode` `IDEMPOTENT_PARAMETER_MISMATCH` and
  `Message` `Idempotent parameters do not match`. `Catalog` is compared as
  sent, so a copy that differs only in case (`AWSDATACATALOG`) is a mismatch
  too. `ExecutionParameters` and `WorkGroup` are not compared. Measured
  2026-09-17 (`Catalog` on 2026-09-24).
- `ClientRequestToken` is required. Omitting it (no key at all) fails with
  `InvalidRequestException` / `AthenaErrorCode` and `ErrorCode` `INVALID_INPUT`
  and `Message` `clientRequestToken is null or empty`. Its length must be
  between 32 and 128 characters (an empty string gets the "too short" message,
  not the "missing" one); outside that range the same error shape is used with
  `Message` `1 validation error detected: Value at 'clientRequestToken' failed
  to satisfy constraint: Member must have length greater than or equal to 32`
  (or `less than or equal to 128`). A token of at most 128 characters that is
  longer than 128 UTF-8 bytes is rejected too, with `Message`
  `clientRequestToken exceeds maximum allowed length 128` (no `1 validation
  error detected:` prefix). Measured 2026-09-17 and 2026-09-24.

Not implemented: every other operation, SigV4 verification, creating, updating
and deleting workgroups (`GetWorkGroup` and `ListWorkGroups` are supported),
enforcing workgroup settings such as scan limits, result reuse, and encryption
settings.
Query state is kept in memory, so it is lost when the container restarts. A
finished query is also dropped once `ATHENA_LOCAL_RETENTION_SECONDS` has
passed; see [Caveats](caveats.md#query-lifecycle).
