# athena-local

A local stand-in for the AWS Athena API. It speaks the Athena wire protocol
(`awsJson1.1`) and executes the SQL it receives on [Trino](https://trino.io/).

Point the `endpoint_url` of any AWS SDK at this server and your Athena code runs
locally — no AWS account, no S3 result bucket, no cost.

```
your app ──(aws-sdk-athena / awsJson1.1)──> athena-local ──(REST /v1/statement)──> Trino
```

## Usage

```yaml
services:
  athena-local:
    image: aoyagikouhei/athena-local:0.2.0
    environment:
      TRINO_URL: http://trino:8080
      # Defaults used when the request has no QueryExecutionContext.
      TRINO_CATALOG: iceberg
      TRINO_SCHEMA: my_schema
      # Optional: Athena catalog names Trino cannot have (see Configuration).
      # TRINO_CATALOG_MAP: s3tablescatalog/my-bucket=iceberg
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

Catalog and schema are passed to Trino as `X-Trino-Catalog` / `X-Trino-Schema`
headers. **Without `ExecutionParameters` the SQL string is never rewritten**, so
write unqualified table names and let the context carry the catalog and database —
that way the same SQL works against real Athena.

Some Athena catalog names cannot exist in Trino. Reading S3 Tables through Athena
always uses `s3tablescatalog/<bucket>`, and a Trino catalog name cannot contain
`/`. Map such names to a Trino catalog instead of changing your code:

```yaml
TRINO_CATALOG_MAP: s3tablescatalog/my-bucket=iceberg,AwsDataCatalog=hive
```

The alias is applied to the name Trino receives only; `GetQueryExecution` reports
the catalog name the request used.

## Supported API

| Operation | Notes |
| --- | --- |
| `StartQueryExecution` | Returns an id immediately; the query runs in the background. `ExecutionParameters` are supported (see below) |
| `GetQueryExecution` | `QUEUED` → `RUNNING` → `SUCCEEDED` / `FAILED`. Trino errors land in `Status.StateChangeReason` |
| `GetQueryResults` | Paginated with `MaxResults` / `NextToken` |

Behaviour that matches real Athena:

- The first row of the first page of a `SELECT` result holds the column names.
- Values are returned as strings (`Datum.VarCharValue`); NULL omits the field.
- `array`, `map` and `row` values use Athena's notation rather than JSON:
  `[1, 2, 3]`, `[a, null]`, `[[1], [2, 3]]`, `{k=1}`, `{id=1, name=x}`, and
  `{1, x}` for an unnamed row. Strings inside are not quoted, exactly as in Athena
  (so `ARRAY['a, b']` reads `[a, b]`). The column's `typeSignature` from Trino
  tells a row from an array; without it the value falls back to JSON.
- DML (`INSERT` / `UPDATE` / `DELETE` / `MERGE`) returns no rows and sets `UpdateCount`.
- Failed queries make `GetQueryResults` return `InvalidRequestException`.

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

Not implemented: every other operation, SigV4 verification, workgroups, result
reuse, writing results to S3 (`ResultConfiguration.OutputLocation` is accepted
and ignored), and the statistics fields (always zero). Query state is kept in
memory, so it is lost when the container restarts.

## Caveats

- **SQL dialect drift.** Athena engine v3 is based on a fixed Trino version. A
  local Trino is usually newer, so SQL can pass here and fail on Athena. This
  server executes what it is given; it does not validate Athena compatibility.
- **DDL differs.** Iceberg table DDL is written differently by Athena
  (`table_type='ICEBERG'`) and Trino (`WITH (format = ...)`). Keep DDL out of the
  code paths you want to share.
- **Decimal literals.** Athena types `1.5` as `double`; Trino types it as
  `decimal(2,1)`, and Trino has no session property to change that.
- **Parameter classification is an approximation.** It follows the measured rules
  above, but a value that closes the parenthesis and still yields one column
  (for example `1) FROM t WHERE (1`) is passed through as an expression, and
  each parameter costs one extra round trip to Trino.
- **Map key order.** Map entries are printed in ascending key order, compared as
  strings. That matched Athena for the keys we measured; other key sets (for
  example numeric keys `9` and `10`) were not verified.
- **Catalog aliases cover the context only.** `TRINO_CATALOG_MAP` rewrites the
  `X-Trino-Catalog` header, not the SQL, so a fully qualified name such as
  `"s3tablescatalog/my-bucket".db.users` still fails. Rely on
  `QueryExecutionContext` instead.
- **Plain HTTP only.** The client is built without TLS. To reach an HTTPS Trino,
  add the `rustls` feature to `reqwest` in `Cargo.toml`.

## Development

```bash
cargo run                 # needs a reachable Trino (TRINO_URL)
cargo test                # no Trino needed: the tests start a fake one
cargo clippy --all-targets -- -D warnings
docker build -t aoyagikouhei/athena-local:dev .
```

The test suite drives the real router against a fake Trino in-process, so it
covers the Athena wire shapes (header row, `UpdateCount`, pagination, error
mapping), parameter classification, and the fact that SQL without parameters is
passed through unchanged. CI runs `fmt`,
`clippy` and `test` on every push and pull request.

Tagging a commit as `v*` publishes `linux/amd64` and `linux/arm64` images to
Docker Hub via GitHub Actions (`DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` secrets).
Each architecture is built on a native runner and the results are merged into a
single manifest, so no QEMU emulation is involved.
