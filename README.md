# athena-local

A local stand-in for the AWS Athena API. It speaks the Athena wire protocol
(`awsJson1.1`) and executes the SQL it receives on [Trino](https://trino.io/).

Point the `endpoint_url` of any AWS SDK at this server and your Athena code runs
locally — no AWS account, no cost. Result files are optional: add an
S3-compatible store such as MinIO and the CSV lands in `OutputLocation` too.

```
your app ──(aws-sdk-athena / awsJson1.1)──> athena-local ──(REST /v1/statement)──> Trino
```

## Usage

```yaml
services:
  athena-local:
    image: aoyagikouhei/athena-local:0.4.0
    environment:
      TRINO_URL: http://trino:8080
      # Defaults used when the request has no QueryExecutionContext.
      TRINO_CATALOG: iceberg
      TRINO_SCHEMA: my_schema
      # Optional: Athena catalog names Trino cannot have (see Configuration).
      # TRINO_CATALOG_MAP: s3tablescatalog/my-bucket=iceberg
      # Optional: write result CSVs to MinIO (see Result files).
      # ATHENA_LOCAL_RESULTS: s3
      # AWS_ENDPOINT_URL_S3: http://minio:9000
      # AWS_ACCESS_KEY_ID: minioadmin
      # AWS_SECRET_ACCESS_KEY: minioadmin
    ports:
      - "8084:8080"
    depends_on:
      - trino
```

Then tell your client to use it:

```rust
// aws-sdk-athena
let config = aws_sdk_athena::config::Builder::from(&aws_config)
    .endpoint_url("http://athena-local:8080")
    .build();
```

```bash
# aws cli
aws athena start-query-execution \
  --endpoint-url http://localhost:8084 --region ap-northeast-1 \
  --query-string 'SELECT * FROM users' \
  --query-execution-context Database=my_schema,Catalog=iceberg
```

Any credentials work; requests are not verified.

> Note: a service name containing an underscore (`athena_local`) is rejected by
> botocore with `Invalid endpoint`. Use a hyphen.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `ATHENA_LOCAL_BIND` | `0.0.0.0:8080` | Listen address |
| `TRINO_URL` | `http://trino:8080` | Trino to execute SQL on |
| `TRINO_USER` | `athena-local` | Value of the `X-Trino-User` header |
| `TRINO_CATALOG` | *(none)* | Default catalog when the request has no `QueryExecutionContext.Catalog` |
| `TRINO_SCHEMA` | *(none)* | Default schema when the request has no `QueryExecutionContext.Database` |
| `TRINO_CATALOG_MAP` | *(none)* | Catalog aliases: `<athena name>=<trino name>`, comma separated. A malformed value stops the server at startup |
| `ATHENA_LOCAL_RESULTS` | `none` | `s3` writes results to `OutputLocation`: a `SELECT` as CSV, DDL and `SHOW` as text. `none` writes nothing |
| `ATHENA_LOCAL_OUTPUT_LOCATION` | *(none)* | With `s3`: `s3://bucket/prefix` used when the request has no `ResultConfiguration.OutputLocation` (stands in for the workgroup default). `GetWorkGroup` also reports it as `Configuration.ResultConfiguration.OutputLocation` |
| `AWS_ENDPOINT_URL_S3` | *(none)* | With `s3`: the S3-compatible store, `http://` only. Falls back to `AWS_ENDPOINT_URL` |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | *(none)* | With `s3`: credentials for the store |
| `AWS_REGION` | `us-east-1` | With `s3`: region used for signing |

With `ATHENA_LOCAL_RESULTS=s3`, a missing endpoint or credential, an `https://`
endpoint, or a malformed `ATHENA_LOCAL_OUTPUT_LOCATION` stops the server at
startup. The store itself is not contacted until a query finishes, so the
bucket may be created after athena-local starts.

Catalog and schema are passed to Trino as `X-Trino-Catalog` / `X-Trino-Schema`
headers. **Without `ExecutionParameters` the SQL string is not rewritten**, except
for catalog aliases in qualified names (below). Unqualified table names with the
context carrying the catalog and database remain the most portable form.

Some Athena catalog names cannot exist in Trino. Reading S3 Tables through Athena
always uses `s3tablescatalog/<bucket>`, and a Trino catalog name cannot contain
`/`. Map such names to a Trino catalog instead of changing your code:

```yaml
TRINO_CATALOG_MAP: s3tablescatalog/my-bucket=iceberg,AwsDataCatalog=hive
```

The alias is applied to the catalog header and to qualified names in the SQL. A
double-quoted identifier that equals an alias and is followed by `.` is replaced
with the Trino name, padded with spaces so that error positions still point at
the same place in your SQL:

```sql
-- sent by the client
SELECT * FROM "s3tablescatalog/my-bucket".db.users
-- executed by Trino
SELECT * FROM "iceberg"                  .db.users
```

String literals and comments are left alone. `GetQueryExecution` reports the
query and the catalog name the request used.

## Supported API

| Operation | Notes |
| --- | --- |
| `StartQueryExecution` | Returns an id immediately; the query runs in the background. `ExecutionParameters` are supported (see below). `ClientRequestToken` makes retries idempotent (see below) |
| `GetQueryExecution` | `QUEUED` → `RUNNING` → `SUCCEEDED` / `FAILED` / `CANCELLED`. Trino errors land in `Status.StateChangeReason` |
| `GetQueryResults` | Paginated with `MaxResults` / `NextToken` |
| `StopQueryExecution` | Marks a queued or running query `CANCELLED` immediately and sends `DELETE` to Trino's `nextUri`. Stopping a finished query succeeds and changes nothing |
| `GetWorkGroup` | Accepts any workgroup name and returns the same configuration for all of them. `Configuration.ResultConfiguration.OutputLocation` reflects `ATHENA_LOCAL_OUTPUT_LOCATION` when it is set |

Behaviour that matches real Athena:

- The first row of the first page of a `SELECT` result holds the column names.
- Values are returned as strings (`Datum.VarCharValue`); NULL omits the field.
- Timestamps keep their precision (`2020-01-01 12:34:56.789123` for
  `timestamp(6)`, no fraction for `timestamp(0)`), as Athena does.
- `ColumnInfo` looks like Athena's: `Type` is the base name (`varchar`, `decimal`,
  `array`, `timestamp`, and `float` for `real`); `Precision` / `Scale` carry the
  `decimal` digits and the `varchar` / `char` length, and Athena's fixed values for
  other types (`integer` 10, `bigint` 19, `double` and `float` 17, `timestamp` 3,
  `varbinary` 1073741824, 0 otherwise); `CaseSensitive` is true for `varchar` and
  `char`; `CatalogName` is `hive` with empty `SchemaName` / `TableName`.
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
- `SELECT` and `SHOW` return `UpdateCount` `0`; DDL leaves it out (Athena sends
  `null`, which SDKs read the same way).
- `GetQueryResults` on a query without results returns `InvalidRequestException`
  with Athena's message and `AthenaErrorCode`:

  | State | Message | `AthenaErrorCode` |
  | --- | --- | --- |
  | `QUEUED` / `RUNNING` | `Query has not yet finished. Current state: RUNNING` | `INVALID_QUERY_EXECUTION_STATE` |
  | `FAILED` | `Query did not finish successfully. Final query state: FAILED` | `INVALID_QUERY_EXECUTION_STATE` |
  | `CANCELLED` | `Could not find results` | `RESULT_NOT_FOUND` |

  An unknown id returns `QueryExecution <id> was not found` (`QUERY_EXECUTION_NOT_FOUND`).
- A stopped query reports `StateChangeReason` `Query cancelled by user`.
- A syntax error makes `StartQueryExecution` fail with `InvalidRequestException`
  (`AthenaErrorCode` `MALFORMED_QUERY`) instead of creating a `FAILED` query, as
  Athena does. The message is Trino's, with positions counted in the original SQL
  (also when `ExecutionParameters` are given). athena-local asks Trino to `PREPARE`
  the statement first, which parses without executing and adds one round trip
  (about 10–20 ms).
- `StatementType` and `SubstatementType` follow Athena: `SELECT` / `WITH` /
  `VALUES` are `DML` / `SELECT`, `EXPLAIN` is `DML` / `EXPLAIN`, `SHOW TABLES` is
  `UTILITY` / `SHOW_TABLES`, `CREATE TABLE ... AS SELECT` is `DDL` /
  `CREATE_TABLE_AS_SELECT`, and so on. Trino spellings map to Athena's
  (`CREATE SCHEMA` is `CREATE_DATABASE`, `SHOW SCHEMAS` is `SHOW_DATABASES`).
  Statements whose `SubstatementType` was not measured leave the field out.
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
  again. A retry whose `QueryString`, `QueryExecutionContext.Database` or
  `ResultConfiguration.OutputLocation` differs from the first call instead fails
  with `InvalidRequestException` / `AthenaErrorCode` and `ErrorCode`
  `IDEMPOTENT_PARAMETER_MISMATCH` and `Message`
  `Idempotent parameters do not match`. `ExecutionParameters` and `WorkGroup` are
  not compared. `Catalog` has not been measured. Measured 2026-09-17.

### Result files

`GetQueryExecution` returns `ResultConfiguration.OutputLocation` as the full
path of the file Athena would create, whenever the request (or, with
`ATHENA_LOCAL_RESULTS=s3`, the default) gives an output location. A trailing `/`
on the location makes no difference. The file name depends on the statement:

| Statement | `OutputLocation` |
| --- | --- |
| `SELECT` / `WITH` / `VALUES` | `s3://bucket/prefix/<id>.csv` |
| `UPDATE` / `DELETE` / `MERGE` | `s3://bucket/prefix/<id>.csv` (nothing is written) |
| `INSERT` | `s3://bucket/prefix/<id>` |
| `CREATE TABLE ... AS SELECT` | `s3://bucket/prefix/tables/<id>` |
| Other DDL, `SHOW`, `DESCRIBE`, ... | `s3://bucket/prefix/<id>.txt` |

With `ATHENA_LOCAL_RESULTS=s3`, a successful `SELECT` writes the CSV there
before the query becomes `SUCCEEDED`, so a client may read it as soon as it sees
that state. The format matches Athena byte for byte:

```
"i","s","q","n","empty","a","vb"
"1","it's","a""b",,"","[1, 2]","01 02"
```

- Every non-NULL value is quoted, including the header; `"` is doubled.
- NULL is an empty field; an empty string is `""`.
- Lines end with `\n` (also the last one); newlines inside values stay inside
  the quotes. UTF-8 without a BOM.
- Values use the same notation as `GetQueryResults`.
- A query with no rows writes just the header line.

DDL, `SHOW` and `DESCRIBE` write `<id>.txt` the same way (measured 2026-09-16).
The file holds the rows `GetQueryResults` returns, joined with `\n`:

- No header line, unlike the CSV, and no trailing newline.
- A statement that returns no rows writes an empty file, `CREATE TABLE` for
  example.
- Columns are joined with a tab. Athena itself returns one already joined,
  space-padded string per row; Trino returns the columns separately, so the
  padding is not reproduced.
- `DROP TABLE` writes a single newline on Athena, which returns two empty rows
  for zero columns. athena-local writes an empty file.

The object is uploaded with a presigned `PUT` (path-style), so any
S3-compatible store works; it is not retried. A failed CSV upload makes the
query `FAILED` with the store's response in `StateChangeReason`. A failed
`<id>.txt` upload leaves the query `SUCCEEDED` and logs one line instead: the
statement has already run on Trino, and DDL cannot be undone.

An `OutputLocation` that is not `s3://bucket[/prefix]` is rejected in either
mode with `outputLocation is not a valid S3 path.` (`INVALID_INPUT`), as Athena
does. With `ATHENA_LOCAL_RESULTS=s3` and no location at all,
`StartQueryExecution` fails with Athena's `No output location provided. ...`
message (`INVALID_INPUT`).

### `ExecutionParameters`

Real Athena does not bind parameter values verbatim. Measured against Athena
(2026-09-14), each value is classified:

| Value | Treated as | Example → result of `SELECT ? AS v` |
| --- | --- | --- |
| Parses as an expression without column references | the expression | `'abc'` → `abc`, `1 + 1` → `2`, `DATE '2020-01-01'`, `NULL`, `now()` |
| Does not parse | a string literal | `abc def`, `it's`, `123e4567-e89b-12d3-a456-426614174000` |
| Contains an identifier | a string literal | `abc`, `x + 1`, `t.x` (even if a column `x` exists) |
| Parses but fails analysis | the expression (the query fails) | `nosuchfunc(1)`, `1 OR 1=1` |

athena-local reproduces this by asking Trino to run `SELECT (<value>)` for each
value: `SYNTAX_ERROR` or `COLUMN_NOT_FOUND` (or a result with more than one
column) makes it a quoted string literal, anything else is used as-is. The query
is then sent as `EXECUTE IMMEDIATE '<sql>' USING <values>` (Trino 418+), so `?`
inside string literals and comments is left alone. `GetQueryExecution` returns
the original SQL, and `StatementType` is derived from it.

A wrong number of values fails with `INVALID_PARAMETER_USAGE`, except that — like
Athena — values passed to SQL without any `?` are ignored.

Messages above were measured against Athena (2026-09-14).

Not implemented: every other operation, SigV4 verification, creating, listing,
updating and deleting workgroups (`GetWorkGroup` itself is supported), enforcing
workgroup settings such as scan limits, result reuse, and encryption settings.
Query state is kept in memory, so it is lost when the container restarts.

## Caveats

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
- **Parameter classification is an approximation.** It follows the measured rules
  above, but a value that closes the parenthesis and still yields one column
  (for example `1) FROM t WHERE (1`) is passed through as an expression, and a
  value ending in a line comment (`1 -- x`) becomes a string literal because the
  comment swallows the closing parenthesis. How Athena classifies those, or a
  bare `?`, has not been measured. Each parameter costs one extra round trip to
  Trino.
- **`varbinary` inside `array` / `map` / `row`.** Top-level `varbinary` values
  are converted from Trino's base64 to Athena's `01 02` form (measured). The same
  form is used inside composite values, which was not measured.
- **Map key order.** Map entries are printed in ascending key order: numerically
  for numeric key types (`{9=a, 10=b}`), as strings otherwise (`{j=2, k=1}`).
  Both were measured against Athena; other key types were not.
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
- **Syntax differs.** Trino-only syntax such as `CREATE OR REPLACE TABLE` passes
  here but is a syntax error on Athena, and the `Expecting:` list in a syntax
  error follows Trino's grammar. For an incomplete statement (`SELECT * FROM`)
  Athena answers `Queries of this type are not supported`; athena-local returns
  Trino's syntax error.
- **Iceberg maintenance statements differ.** Athena's `OPTIMIZE ... REWRITE DATA`
  and `VACUUM` do not exist in Trino, which uses `ALTER TABLE ... EXECUTE optimize`
  and `ALTER TABLE ... EXECUTE expire_snapshots` instead.
- **Cancellation is checked between pages.** A stopped query is `CANCELLED`
  at once, but the `DELETE` reaches Trino only when the current long poll to
  `nextUri` returns (about a second at most).
- **Companion files are not written.** Athena writes `<id>.csv.metadata` next to
  a result and a manifest for DML and CTAS. athena-local writes neither;
  `OutputLocation` still names the file Athena would use.
- **A failed query writes nothing.** On Athena it depends on the statement: a
  failed `SHOW` writes `<id>.txt` holding `FAILED: ` and the reason, while a
  failed `ALTER TABLE` writes no file at all (measured 2026-09-16).
  athena-local writes nothing in either case.
- **A missing bucket fails the query.** Athena reported `SUCCEEDED` for a
  `SELECT` whose output bucket did not exist (measured). athena-local makes it
  `FAILED` so the mistake shows up locally.
- **Unmeasured file names.** The file name for `CREATE OR REPLACE TABLE ... AS`
  (Trino only) follows the measured rule for CTAS but was not measured.
- **Any workgroup name is accepted.** `GetWorkGroup` never fails because of the
  name: it echoes the name back and returns the same `Configuration` every time,
  because athena-local has no workgroups to look up. Real Athena answers a name
  that does not exist with HTTP 400, `InvalidRequestException`, the message
  `WorkGroup is not found.` and `AthenaErrorCode: INVALID_INPUT`;
  `StartQueryExecution` fails the same way (measured 2026-09-17). Per-workgroup
  settings are not reproduced.
- **awswrangler reaches real AWS when no output location is set.** If neither
  the call nor `ATHENA_LOCAL_OUTPUT_LOCATION` supplies one, awswrangler resolves
  the location itself: it calls STS and creates a bucket named
  `aws-athena-query-results-{account}-{region}`, its own documented fallback.
  Those calls go to real AWS unless `AWS_ENDPOINT_URL` covers every service, not
  just Athena. Set `ATHENA_LOCAL_OUTPUT_LOCATION` to keep the run local.
- **`GetWorkGroup` omits two fields Athena returns.** `CreationTime` is left out
  because athena-local has no workgroup that was ever created, so any value
  would be invented; `EnableMinimumEncryptionConfiguration` is left out because
  its value was not measured. No client reads either one (measured 2026-09-17).
- **Plain HTTP only.** The clients are built without TLS, for both Trino and
  the S3-compatible store. To reach an HTTPS endpoint, add the `rustls` feature
  to `reqwest` in `Cargo.toml` (and CA certificates to the image).
- **`ClientRequestToken` is not normalized or length-checked.** The value is
  used verbatim as a map key: case, leading/trailing whitespace and non-ASCII
  characters are all significant, and no minimum or maximum length is enforced.
  Whether real Athena normalizes it has not been measured. The token → id
  mapping is kept in memory for the life of the process (see #4) and its
  lifetime beyond 60 seconds has not been measured.
- **Error body key casing.** Error responses use `Message` (capital M), and an
  error that carries `AthenaErrorCode` also carries `ErrorCode` with the same
  value; both match real Athena (measured for `IDEMPOTENT_PARAMETER_MISMATCH`
  and `WorkGroup is not found.`). Errors without an `AthenaErrorCode` (a
  request that fails to parse, an unsupported operation,
  `InternalServerException`) keep only `Message`; whether real Athena adds
  `ErrorCode` there too has not been measured.

## Development

```bash
cargo run                 # needs a reachable Trino (TRINO_URL)
cargo test                # no Trino needed: the tests start a fake one
cargo clippy --all-targets -- -D warnings
docker build -t aoyagikouhei/athena-local:dev .
```

The test suite drives the real router against a fake Trino and a fake S3
in-process, so it covers the Athena wire shapes (header row, `UpdateCount`, pagination, error
mapping), parameter classification, and the fact that SQL without parameters is
passed through unchanged apart from catalog aliases. CI runs `fmt`,
`clippy` and `test` on every push and pull request.

Tagging a commit as `v*` publishes `linux/amd64` and `linux/arm64` images to
Docker Hub via GitHub Actions (`DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` secrets).
Each architecture is built on a native runner and the results are merged into a
single manifest, so no QEMU emulation is involved.
