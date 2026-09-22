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

### Athena JDBC 3.x needs a TLS terminator in front

The Athena JDBC driver 3.x refuses a plain-HTTP endpoint. `AthenaEndpoint` and
`S3Endpoint` go through
`com.amazon.athena.jdbc.support.EndpointHelper.constructEndpointUri`, which
prepends `https://` when the scheme is missing and throws
`IllegalArgumentException` —
`The Athena endpoint "http://localhost:8084" is not an HTTPS endpoint` — for any
other scheme. No property turns that off (disassembled from 3.8.1, 2026-09-17).
athena-local serves plain HTTP only (see Caveats), so terminate TLS in front of
it and in front of the S3-compatible store, and let the driver talk to the
terminator.

Make a self-signed certificate. The names the driver connects to must all be in
`subjectAltName`, or the JVM rejects the handshake:

```bash
mkdir -p tls && openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout tls/server.key -out tls/server.crt \
  -subj "/CN=athena-local" \
  -addext "subjectAltName=DNS:localhost,DNS:*.localhost,DNS:athena-local,DNS:minio,IP:127.0.0.1"
```

`tls/nginx.conf` — 8443 terminates for athena-local, 9443 for MinIO:

```nginx
events {}

http {
  # Result files can be large, and SigV4 signs the Host header, so pass the
  # Host the client signed through unchanged and do not buffer the body.
  client_max_body_size 0;
  proxy_request_buffering off;
  proxy_http_version 1.1;
  proxy_set_header Host $http_host;

  server {
    listen 8443 ssl;
    server_name _;
    ssl_certificate     /etc/nginx/tls/server.crt;
    ssl_certificate_key /etc/nginx/tls/server.key;

    location / {
      proxy_pass http://athena-local:8080;
      proxy_read_timeout 300s;
    }
  }

  server {
    listen 9443 ssl;
    server_name _;
    ssl_certificate     /etc/nginx/tls/server.crt;
    ssl_certificate_key /etc/nginx/tls/server.key;

    location / {
      proxy_pass http://minio:9000;
      proxy_read_timeout 300s;
    }
  }
}
```

Add it to the compose file above, next to the `minio` service the driver
reads the result files from:

```yaml
  tls-proxy:
    image: nginx:1.27.0
    ports:
      - "8443:8443"   # -> athena-local:8080
      - "9443:9443"   # -> minio:9000
    volumes:
      - ./tls/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./tls/server.crt:/etc/nginx/tls/server.crt:ro
      - ./tls/server.key:/etc/nginx/tls/server.key:ro
    depends_on:
      - athena-local
      - minio
```

Then make the JVM that runs the driver trust the certificate — import it into
the JDK's `cacerts` (the default password is `changeit`):

```bash
keytool -importcert -noprompt -alias athena-local \
  -file tls/server.crt -cacerts -storepass changeit
```

and point the driver at the terminator:

```java
Properties props = new Properties();
props.setProperty("Region", "ap-northeast-1");
props.setProperty("AthenaEndpoint", "https://localhost:8443");
props.setProperty("S3Endpoint", "https://localhost:9443");
props.setProperty("OutputLocation", "s3://results/athena/");
props.setProperty("User", "minioadmin");      // any credentials work
props.setProperty("Password", "minioadmin");
props.setProperty("Catalog", "iceberg");
props.setProperty("Database", "my_schema");
```

If the driver's S3 client addresses the bucket in virtual-host style
(`results.localhost`), that name has to resolve and be covered by the
certificate, and MinIO needs `MINIO_DOMAIN` set to the same domain.

This was the setup used to verify athena-local against Athena JDBC 3.8.1
(2026-09-17): nginx 1.27.0, a self-signed certificate in the JDK's `cacerts`,
and all three `ResultFetcher` modes (`auto`, `S3`, `GetQueryResults`) connected
and ran without an exception.

The 3.x driver is not on Maven Central — the similarly named
`com.amazonaws:athena-jdbc` published there is the Athena Federated Query
connector and ships no `java.sql.Driver`. AWS serves the real one at
`https://downloads.athena.us-east-1.amazonaws.com/drivers/JDBC/<version>/athena-jdbc-<version>-with-dependencies.jar`
(checked for 3.8.1 on 2026-09-21). When the driver runs in a container and
MinIO is another container, two more things have to line up, both measured on
2026-09-21: `MINIO_DOMAIN` has to equal the S3 endpoint's host name, since the
driver addresses the bucket in virtual-host style and MinIO otherwise answers
`NoSuchBucket`; and that host name has to be in the container's `/etc/hosts`,
because the AWS SDK bundled in the driver raises `UnknownHostException` for a
name that Docker's embedded resolver serves (`search .`, `ndots:0`) even though
`getent hosts` and `java.net.InetAddress.getByName` both resolve it.

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `ATHENA_LOCAL_BIND` | `0.0.0.0:8080` | Listen address |
| `TRINO_URL` | `http://trino:8080` | Trino to execute SQL on |
| `TRINO_USER` | `athena-local` | Value of the `X-Trino-User` header |
| `TRINO_CATALOG` | *(none)* | Default catalog when the request has no `QueryExecutionContext.Catalog` |
| `TRINO_SCHEMA` | *(none)* | Default schema when the request has no `QueryExecutionContext.Database` |
| `TRINO_CATALOG_MAP` | *(none)* | Catalog aliases: `<athena name>=<trino name>`, comma separated. A malformed value stops the server at startup |
| `ATHENA_LOCAL_RETENTION_SECONDS` | `3600` | How long a finished query (`SUCCEEDED` / `FAILED` / `CANCELLED`) and its `ClientRequestToken` are kept, in seconds. Queued and running queries are never dropped. A value that is not a positive integer stops the server at startup |
| `ATHENA_LOCAL_RESULTS` | `none` | `s3` writes results to `OutputLocation`: a `SELECT` as CSV, DDL and `SHOW` as text. `none` writes nothing |
| `ATHENA_LOCAL_WORK_GROUPS` | `primary` | Workgroup names that `ListWorkGroups` returns, comma separated. `GetWorkGroup` still accepts any name, listed or not. An empty entry stops the server at startup |
| `ATHENA_LOCAL_OUTPUT_LOCATION` | *(none)* | With `s3`: `s3://bucket/prefix` used when the request has no `ResultConfiguration.OutputLocation` (stands in for the workgroup default). `GetWorkGroup` also reports it as `Configuration.ResultConfiguration.OutputLocation`. When no default output location is set, athena-local prints a one-line warning at startup and keeps running (see the awswrangler Caveat) |
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
| `StartQueryExecution` | Returns an id immediately; the query runs in the background. `ExecutionParameters` are supported (see below). `ClientRequestToken` is required and makes retries idempotent (see below) |
| `GetQueryExecution` | `QUEUED` → `RUNNING` → `SUCCEEDED` / `FAILED` / `CANCELLED`. Trino errors land in `Status.StateChangeReason` |
| `GetQueryResults` | Paginated with `MaxResults` / `NextToken` |
| `StopQueryExecution` | Marks a queued or running query `CANCELLED` immediately and sends `DELETE` to Trino's `nextUri`. Stopping a finished query succeeds and changes nothing |
| `GetWorkGroup` | Accepts any workgroup name and returns the same configuration for all of them. `Configuration.ResultConfiguration.OutputLocation` reflects `ATHENA_LOCAL_OUTPUT_LOCATION` when it is set |
| `ListWorkGroups` | Lists the names from `ATHENA_LOCAL_WORK_GROUPS` (just `primary` when unset) in name order, with the same `State` and `EngineVersion` as `GetWorkGroup`. Paginated with `MaxResults` / `NextToken`; out-of-range `MaxResults` and malformed `NextToken` fail the way Athena does |

Behaviour that matches real Athena:

- The first row of the first page of a `SELECT` or `EXPLAIN` result (`StatementType`
  `DML`) holds the column names. `TABLE t`, Trino's shorthand for
  `SELECT * FROM t`, is accepted by Athena and counts as `DML` / `SELECT` too
  (measured 2026-09-22). `SHOW ...` and `DESCRIBE` (`UTILITY`) start with
  the first data row instead, as on Athena (`SHOW TABLES`, `SHOW DATABASES`,
  `SHOW COLUMNS`, `SHOW CREATE TABLE`, `SHOW PARTITIONS`, `SHOW TBLPROPERTIES`
  and `DESCRIBE`, measured 2026-09-15 to 2026-09-22). Athena JDBC skips the
  header row only for `DML`, so it used to show the column name as the first
  row of a `SHOW` result with `ResultFetcher=GetQueryResults`.
- Values are returned as strings (`Datum.VarCharValue`); NULL omits the field.
- Timestamps keep their precision (`2020-01-01 12:34:56.789123` for
  `timestamp(6)`, no fraction for `timestamp(0)`), as Athena does.
- `ColumnInfo` looks like Athena's: `Type` is the base name (`varchar`, `decimal`,
  `array`, `timestamp`, and `float` for `real`); `Precision` / `Scale` carry the
  `decimal` digits and the `varchar` / `char` length, and Athena's fixed values for
  other types (`integer` 10, `bigint` 19, `double` and `float` 17, `timestamp` 3,
  `varbinary` 1073741824, 0 otherwise); `CaseSensitive` is true for `varchar` and
  `char`; `CatalogName` is `hive` with empty `SchemaName` / `TableName`.
- The `Query Plan` column of `EXPLAIN` is typed `varchar(<length of the plan
  text>)` by the engine: 371 for `EXPLAIN SELECT 1` on Athena engine version 3
  (measured 2026-09-15 and 2026-09-16), 400 for the same statement on Trino 482,
  counted in characters. athena-local passes Trino's length through as
  `Precision`, so the number differs from Athena's only because the plan text
  differs between the engines.
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
- Every statement that has columns gets a companion `.metadata` file next to its
  result file with `ATHENA_LOCAL_RESULTS=s3`, the protobuf sidecar Athena JDBC
  3.x reads by default. See Result files below.
- `GetQueryResults` on a query without results returns `InvalidRequestException`
  with Athena's message and `AthenaErrorCode`:

  | State | Message | `AthenaErrorCode` |
  | --- | --- | --- |
  | `QUEUED` / `RUNNING` | `Query has not yet finished. Current state: RUNNING` | `INVALID_QUERY_EXECUTION_STATE` |
  | `FAILED` | `Query did not finish successfully. Final query state: FAILED` | `INVALID_QUERY_EXECUTION_STATE` (see Caveats) |
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
  `VALUES` / `TABLE` are `DML` / `SELECT`, `EXPLAIN` is `DML` / `EXPLAIN`, `SHOW TABLES` is
  `UTILITY` / `SHOW_TABLES`, `CREATE TABLE ... AS SELECT` is `DDL` /
  `CREATE_TABLE_AS_SELECT`, and so on. Trino spellings map to Athena's
  (`CREATE SCHEMA` is `CREATE_DATABASE`, `SHOW SCHEMAS` is `SHOW_DATABASES`).
  Statements whose `SubstatementType` was not measured leave the field out.
  Leading whitespace and comments (`-- ...`, `/* ... */`, possibly interleaved)
  are skipped before the classification keyword is read, the same way Athena
  does (measured 2026-09-18), and a comment between keywords
  (`DROP /* c */ TABLE t`, `CREATE TABLE t AS -- c\nSELECT 1`) counts as
  whitespace, also the same way Athena does (measured 2026-09-22); this also
  decides the `OutputLocation` file name and, for `DESCRIBE` /
  `SHOW CREATE TABLE`, whether the `.metadata` file's leading query ID is the
  `QueryExecutionId` or Trino's own ID.
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
- `ClientRequestToken` is required. Omitting it (no key at all) fails with
  `InvalidRequestException` / `AthenaErrorCode` and `ErrorCode` `INVALID_INPUT`
  and `Message` `clientRequestToken is null or empty`. Its length must be
  between 32 and 128 characters (an empty string gets the "too short" message,
  not the "missing" one); outside that range the same error shape is used with
  `Message` `1 validation error detected: Value at 'clientRequestToken' failed
  to satisfy constraint: Member must have length greater than or equal to 32`
  (or `less than or equal to 128`). Measured 2026-09-17.

### Result files

`GetQueryExecution` returns `ResultConfiguration.OutputLocation` as the full
path of the file Athena would create, whenever the request (or, with
`ATHENA_LOCAL_RESULTS=s3`, the default) gives an output location. A trailing `/`
on the location makes no difference. The file name depends on the statement:

| Statement | `OutputLocation` |
| --- | --- |
| `SELECT` / `WITH` / `VALUES` / `TABLE` | `s3://bucket/prefix/<id>.csv` |
| `UPDATE` / `DELETE` / `MERGE` | `s3://bucket/prefix/<id>.csv` (only the `.metadata` companion is written) |
| `INSERT` | `s3://bucket/prefix/<id>` (only the `.metadata` companion is written) |
| `CREATE TABLE ... AS SELECT` | `s3://bucket/prefix/tables/<id>` (only the `.metadata` companion is written) |
| Other DDL, `SHOW`, `DESCRIBE`, ... | `s3://bucket/prefix/<id>.txt` |

`DROP TABLE` and `ALTER TABLE ... ADD COLUMNS` keep the `<id>.txt` name above;
see [DDL that depends on the target table's format](#ddl-that-depends-on-the-target-tables-format)
for the cases where their content, Content-Type and `.metadata` differ from
ordinary column-less DDL.

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

DDL, `SHOW`, `DESCRIBE` and `EXPLAIN` write `<id>.txt` the same way (measured
2026-09-16). The file holds the rows `GetQueryResults` returns, joined with `\n`:

- No header line for DDL, `SHOW` and `DESCRIBE`, unlike the CSV, and no trailing
  newline. `EXPLAIN` is `DML`, and its file starts with the header line
  `Query Plan` just as its `GetQueryResults` does (measured 2026-09-15 and
  2026-09-16); the blank lines Trino puts at the end of a plan stay in the file
  as empty lines.
- A statement that returns no rows writes an empty file, `CREATE TABLE` for
  example.
- Columns are joined with a tab. Athena itself returns one already joined,
  space-padded string per row; Trino returns the columns separately, so the
  padding is not reproduced.
- On an Iceberg table, `DROP TABLE` writes a single newline on Athena, which
  returns two empty rows for zero columns; athena-local matches it there
  (measured 2026-09-20 and 2026-09-21, reproduced across three rounds). On a
  Hive table, or when the target does not exist, both write an empty file. See
  [DDL that depends on the target table's format](#ddl-that-depends-on-the-target-tables-format).

The object is uploaded with a presigned `PUT` (path-style), so any
S3-compatible store works; it is not retried, and a `PUT` that gets no response
within 30 seconds is given up on so the query still reaches a final state
(the limit is fixed and has no environment variable). `<id>.csv` and the `.metadata`
companions are sent as `application/octet-stream` and `<id>.txt` as
`binary/octet-stream`, as Athena does (measured 2026-09-17), except for two
combinations: `DROP TABLE` on an Iceberg table and
`ALTER TABLE ... ADD COLUMNS` on a Hive table send their `<id>.txt` as
`application/octet-stream` too, the same Content-Type as their `.metadata`
companion (measured 2026-09-20/21; see
[DDL that depends on the target table's format](#ddl-that-depends-on-the-target-tables-format)).
A failed CSV upload makes the query `FAILED` with the store's response in
`StateChangeReason`. A failed `<id>.txt` or `.metadata` upload leaves the query
`SUCCEEDED` and logs one line instead: the statement has already run on Trino,
and DDL cannot be undone. When the result file itself fails to upload, no
companion file is attempted.

A failed query writes a result file too, but only for the statements whose
result file is `<id>.txt` (DDL, `SHOW`, `DESCRIBE`, `EXPLAIN`), so a client that
reads the result file can see why it failed. The file holds `FAILED: ` followed
by `StateChangeReason`, with no trailing newline, and is sent as
`application/octet-stream` rather than the `binary/octet-stream` of a successful
`<id>.txt`; no `.metadata` companion is written. `SELECT`, DML and CTAS write
nothing, and neither does a cancelled query. The upload happens before the query
becomes `FAILED`, so a client may read the file as soon as it sees that state;
an upload that fails logs one line and leaves the state and the reason
unchanged. Athena writes such a file for fewer statements; see Caveats.

An `OutputLocation` that is not `s3://bucket[/prefix]` is rejected in either
mode with `outputLocation is not a valid S3 path.` (`INVALID_INPUT`), as Athena
does. With `ATHENA_LOCAL_RESULTS=s3` and no location at all,
`StartQueryExecution` fails with Athena's `No output location provided. ...`
message (`INVALID_INPUT`).

### Companion `.metadata` files

With `ATHENA_LOCAL_RESULTS=s3`, a companion file named after the result file
plus `.metadata` is written next to it, as Athena does (measured 2026-09-17):
`<id>.csv.metadata`, `<id>.txt.metadata`, `<id>.metadata` for `INSERT` and an
Iceberg CTAS, and `tables/<id>.metadata` for a Hive CTAS. Athena JDBC 3.x is
the client that needs it: its default `ResultFetcher=auto` reads the result and
the metadata straight
from S3 instead of calling `GetQueryResults`, and versions before 3.5.1 fail
with `NoSuchKey` when a DDL statement has no metadata file. athena-local writes
no companion file for most column-less DDL either, so those statements still
fail on versions before 3.5.1; 3.8.1 logs the missing file (a 404) at INFO
level and carries on (measured 2026-09-17). Two combinations are the exception
and do get a companion file that carries no columns at all; see
[DDL that depends on the target table's format](#ddl-that-depends-on-the-target-tables-format)
for what the driver does with those. PyAthena, awswrangler and dbt-athena do
not read it.

The file is written for every statement that has columns: `SELECT` (also when
it returns no rows), `SHOW` / `DESCRIBE` / `EXPLAIN`, DML (`INSERT` / `UPDATE`
/ `DELETE` / `MERGE`) and CTAS. DML and CTAS write the companion file only and
no result file of their own, as on Athena. DDL without columns
(`CREATE DATABASE`, `DROP DATABASE`, `CREATE TABLE`), a failed query and a
cancelled query write no companion file, also as on Athena — except the two
combinations described under
[DDL that depends on the target table's format](#ddl-that-depends-on-the-target-tables-format).
A failed statement may still write its own `<id>.txt` (see Result files
above).

The content is protobuf. There is no official schema; the field numbers are the
ones [burtcorp/athena-jdbc's `AthenaMetaDataParser`](https://github.com/burtcorp/athena-jdbc/blob/master/src/main/java/io/burt/athena/result/AthenaMetaDataParser.java)
reads:

- the query id first, and for DML and CTAS the Trino `updateType` (`INSERT`,
  `UPDATE`, `DELETE`, `MERGE`, `CREATE TABLE`) and the update count. Athena's
  own companion file for a `MERGE` differs from the one for an `UPDATE` or a
  `DELETE` only in the length of that string: 74 bytes against 75, with every
  byte after the `updateType` identical, down to the single `rows bigint`
  column (measured 2026-09-20). Trino itself reports `MERGE` as the
  `updateType` of a `MERGE`, so the string athena-local passes through is the
  one Athena writes (checked against Trino 482 on 2026-09-22, where every byte
  after the query id matched Athena's own file);
- then one message per column carrying the same values as the `ColumnInfo` of
  `GetQueryResults`: `CatalogName`, `Name`, `Label`, `Type`, `Precision`,
  `Scale`, `Nullable`, `CaseSensitive`.

The query id follows Athena's own split: `SELECT`, DML, CTAS, `EXPLAIN` and the
`SHOW` statements carry the engine's query id (Trino's here, Athena's engine id
there), while `DESCRIBE` and `SHOW CREATE TABLE` carry the `QueryExecutionId`.
For the `SHOW` statements whose real companion file is opaque (see Caveats)
Athena's own choice cannot be observed, so athena-local uses the engine id there
by analogy with `EXPLAIN`. The two statements under
[DDL that depends on the target table's format](#ddl-that-depends-on-the-target-tables-format)
follow the same split: `DROP TABLE` on an Iceberg table carries the engine's
query id, like `EXPLAIN`, while `ALTER TABLE ... ADD COLUMNS` on a Hive table
carries the `QueryExecutionId`, like `DESCRIBE` (measured 2026-09-21).

### DDL that depends on the target table's format

`DROP TABLE` and `ALTER TABLE ... ADD COLUMNS` write a different `<id>.txt`
and `.metadata` companion depending on whether the Trino catalog holding the
target table uses the `hive` or the `iceberg` connector (measured against
Athena on 2026-09-20 and 2026-09-21, reproduced across three rounds):

| Statement | Target format | `<id>.txt` | Content-Type | `.metadata` |
| --- | --- | --- | --- | --- |
| `DROP TABLE` | Iceberg | a single newline (1 byte) | `application/octet-stream` | 41 bytes: the engine's query id (field 1), then `DROP TABLE` (field 2) |
| `DROP TABLE` | Hive, or the target does not exist | empty | `binary/octet-stream` | none |
| `ALTER TABLE ... ADD COLUMNS` | Hive | empty | `application/octet-stream` | 38 bytes: `QueryExecutionId` only (field 1); no `updateType`, count or columns |
| `ALTER TABLE ... ADD COLUMNS` | Iceberg | empty | `binary/octet-stream` | none |
| `ALTER TABLE ... REPLACE COLUMNS` | Hive | empty | `application/octet-stream` | 38 bytes, byte for byte the same as the `ADD COLUMNS` row (measured 2026-09-21) |
| `ALTER TABLE ... REPLACE COLUMNS` | Iceberg | Athena itself fails the query | — | — |

The 41-byte and 38-byte companions carry no `ColumnInfo` at all, which is
outside what a `.metadata` file is otherwise for. Athena JDBC 3.8.1 reads them
without an exception: in its default `ResultFetcher=auto`, and again with
`ResultFetcher=S3`, it logged `loaded query result metadata` for both files and
returned from `execute()` normally. The same run covered a `DROP TABLE` that
writes no companion at all (the driver logs `does not have query result
metadata` and carries on) and a `SELECT` for regression (verified against
athena-local on 2026-09-21 with
`.claude/issue-notes/46-verify-jdbc-metadata.sh`).

Write `ADD COLUMN` (singular) to reach the `ADD COLUMNS` row from
athena-local: Trino's grammar rejects Athena's `ADD COLUMNS` at the syntax
check. `REPLACE COLUMNS` has no Trino spelling at all, so that row cannot be
reached through athena-local; it is listed because the classification and the
format probe follow Athena for it. See [Caveats](#caveats) for every spelling
Trino rejects.

Every other `ALTER TABLE` form that gets a `SubstatementType` (`SET
TBLPROPERTIES`, `DROP COLUMN`, `SET LOCATION`, `ADD PARTITION`,
`DROP PARTITION`, `RENAME TO`) behaves on Athena like ordinary column-less
DDL: an empty `<id>.txt`, `binary/octet-stream`, and no `.metadata`. All six
were measured on 2026-09-21 on whichever table format Athena accepts them on
(see [Caveats](#caveats) for the combinations Athena itself rejects). Of the
six, only `DROP COLUMN` and `RENAME TO` can be run through athena-local; the
rest are rejected at the syntax check, so their rows describe Athena alone.

Only these three statements trigger the format probe below; no other statement
pays an extra round trip to Trino. For a matching statement, athena-local
sends the format probe as a single query, asking which connector backs the
target's catalog and whether the target exists:

```sql
SELECT
  (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = '<catalog>'),
  (SELECT count(*) FROM system.jdbc.tables
   WHERE table_cat = '<catalog>' AND table_schem = '<schema>' AND table_name = '<table>')
```

The catalog, schema and table name come from a qualified name in the SQL when
`DROP TABLE` or `ALTER TABLE ... ADD COLUMNS` gives one (`t`, `ns.t` or
`cat.ns.t`, quoted or not, with a leading `IF EXISTS` skipped). Whichever part
a qualified name does not give falls back to `QueryExecutionContext` /
`TRINO_CATALOG` / `TRINO_SCHEMA`. A catalog taken from the SQL is translated
through `TRINO_CATALOG_MAP` before the format probe is sent, the same as the
catalog used to run the statement itself.

athena-local falls back to ordinary column-less DDL (empty file, no
`.metadata`) when any of these hold:

- the catalog or schema still cannot be resolved;
- the format probe fails;
- the connector is neither `hive` nor `iceberg`;
- for `DROP TABLE` only, the target does not exist. (For
  `ALTER TABLE ... ADD COLUMNS`, Trino itself errors out on a missing target
  before athena-local would reach this fallback.)

For `DROP TABLE`, that last fallback happens to match what real Athena does
for `DROP TABLE IF EXISTS` on a missing table too (measured 2026-09-21). See
Caveats for the limits of this detection.

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

Not implemented: every other operation, SigV4 verification, creating, updating
and deleting workgroups (`GetWorkGroup` and `ListWorkGroups` are supported),
enforcing workgroup settings such as scan limits, result reuse, and encryption
settings.
Query state is kept in memory, so it is lost when the container restarts. A
finished query is also dropped once `ATHENA_LOCAL_RETENTION_SECONDS` has
passed; see Caveats.

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
  error follows Trino's grammar. `ALTER TABLE IF EXISTS ...` and
  `ALTER TABLE ... RENAME COLUMN ... TO ...` are the same: Trino runs both, but
  Athena's grammar has no such form and answers `mismatched input` before the
  statement starts (measured 2026-09-21), so athena-local executes them on
  Trino where Athena would have rejected the call outright. For an incomplete
  statement (`SELECT * FROM`) Athena answers `Queries of this type are not
  supported`; athena-local returns Trino's syntax error.
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
  [DDL that depends on the target table's format](#ddl-that-depends-on-the-target-tables-format);
  classification accepts either spelling, so a statement written as
  `ADD COLUMN` still gets the `ADD COLUMNS` `SubstatementType` (verified
  against Trino 482 and MinIO on 2026-09-21). The four with no Trino spelling
  cannot be run through athena-local at all — their `SubstatementType` and
  result-file rows below record what Athena does, and are reachable here only
  if the backend's grammar accepts the statement.
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
  can succeed here where it would fail on real Athena. Whether other
  statements that Athena parses the same way reject a block comment as well
  is not measured.
- **Cancellation is checked between pages.** A stopped query is `CANCELLED`
  at once, but the `DELETE` reaches Trino only when the current long poll to
  `nextUri` returns (about a second at most).
- **Manifests are not written.** Athena writes a manifest next to the result
  when a statement writes rows into a Hive table: `<id>-manifest.csv` for an
  `INSERT` and `tables/<id>-manifest.csv` for a CTAS (measured 2026-09-20, with
  `SHOW CREATE TABLE` confirming the table format). It writes none for the same
  two statements on an Iceberg table, none for `UPDATE` / `DELETE` / `MERGE`,
  none for an `INSERT` that inserts no row, and none for a failed `INSERT` —
  although the failure message names the manifest path it would have used.
  athena-local writes no manifest at all; `OutputLocation` still names the
  result file Athena would use. The `.metadata` companion is written (see
  Result files above).
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
  `SHOW_DATABASES`, see above) and `SELECT * FROM "<table>$partitions"` for
  `SHOW PARTITIONS`; `SHOW TBLPROPERTIES` has no Trino spelling
  (`SHOW CREATE TABLE` includes the properties).
- **Table format is detected per Trino catalog.** Real Athena keeps Hive and
  Iceberg tables side by side in one `AwsDataCatalog`; Trino can only put them
  in separate catalogs, so athena-local's detection follows your Trino catalog
  configuration instead: it agrees with Athena only when the Trino catalog
  behind a given Athena table uses the connector Athena would expect. A Trino
  deployment that mixes both formats behind a single catalog, or a
  `TRINO_CATALOG_MAP` alias that points an Athena catalog at the wrong
  connector, falls back to ordinary column-less DDL (empty file, no
  `.metadata`) instead of matching Athena. See
  [DDL that depends on the target table's format](#ddl-that-depends-on-the-target-tables-format)
  for what this changes.
- **`ALTER TABLE` classification covers eight forms.** `SET TBLPROPERTIES`,
  `ADD COLUMNS`, `DROP COLUMN`, `SET LOCATION`, `REPLACE COLUMNS`,
  `ADD PARTITION`, `DROP PARTITION` and `RENAME TO` each get the
  `SubstatementType` Athena returns (measured 2026-09-21). Note that
  `ALTER_TABLE_REPLACE_COLUMN` is singular although the statement is plural.
  Athena returns the `SubstatementType` even when the statement then fails at
  run time, so athena-local classifies these forms regardless of the target's
  format. Any other `ALTER TABLE` form is left unclassified, the same as any
  other statement whose `SubstatementType` was not measured (see
  [Supported API](#supported-api)). Only three of the eight can actually be run
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
  `ADD PARTITION` and `SET LOCATION` on an Iceberg table, all three with
  `Query type not supported by Athena Iceberg at this time`, and `RENAME TO` on
  a Hive table, where Glue answers `Table cannot be renamed` (measured
  2026-09-21). They fail before athena-local's own format-dependent behaviour
  would matter — not a limitation of athena-local.
- **`ADD PARTITION` and `DROP PARTITION` were measured on a partitioned Hive
  table only.** Athena has no such syntax for Iceberg (see above), so the
  Iceberg side of those two rows cannot exist; no other partition layout was
  measured.
- **Unmeasured `.metadata` details.** The update count of a DML statement that
  changes no rows (`DELETE ... WHERE false`) was not measured; athena-local
  writes `0`. Columns of type `timestamp with time zone`, `time with time zone`
  and `interval year to month` were not measured and are written like
  `timestamp` / `time` and `interval day to second`.
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
  whose result file is `<id>.txt`. A failed `EXPLAIN` was not measured.
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
- **A missing bucket fails the query.** Athena reported `SUCCEEDED` for a
  `SELECT` whose output bucket did not exist (measured). athena-local makes it
  `FAILED` so the mistake shows up locally.
- **Unmeasured file names.** The file name for `CREATE OR REPLACE TABLE ... AS`
  (Trino only) follows the measured rule for CTAS but was not measured.
  A CTAS always gets `tables/<id>`: Athena used that name for an Iceberg CTAS
  too, both for `WITH (table_type = 'ICEBERG')` and for the Hive default
  (measured 2026-09-19, with `SHOW CREATE TABLE` confirming the table really was
  Iceberg). An earlier round had recorded `<id>` for the same statement
  (2026-09-17); the later measurement is the one reproduced here. `INSERT`
  keeps `<id>`, and that value was measured again on 2026-09-20 with controls in
  the same round: an `INSERT` into a Hive table, one into an Iceberg table and
  one that inserts no row all wrote `<id>`, while the `SELECT`, CTAS and
  `SHOW TABLES` measured beside them wrote `<id>.csv`, `tables/<id>` and
  `<id>.txt` as before. `MERGE` was measured for the first time in that round
  and writes `<id>.csv`, like `UPDATE` and `DELETE`.
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
  athena-local warns about this once at startup whenever it has no default
  output location to report, which includes every `ATHENA_LOCAL_RESULTS=none`
  run, because `GetWorkGroup` then leaves `OutputLocation` out either way. The
  warning goes to stderr and does not stop the server; athena-local still does
  not block the outgoing calls, since that would mean answering unlike real
  Athena.
- **`GetWorkGroup` omits two fields Athena returns.** `CreationTime` is left out
  because athena-local has no workgroup that was ever created, so any value
  would be invented; `EnableMinimumEncryptionConfiguration` is left out because
  its value was not measured. No client reads either one (measured 2026-09-17).
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
- **`ListWorkGroups` paging differs from Athena in two ways.** The default page
  size is 50, the largest `MaxResults` Athena accepts; Athena's own default was
  not measured. `NextToken` is the offset of the next page as a decimal string
  rather than an opaque token. Errors match: `MaxResults` outside 1..50 and a
  malformed or empty `NextToken` fail with HTTP 400, `InvalidRequestException`,
  `AthenaErrorCode: INVALID_INPUT` and Athena's messages (measured 2026-09-18).
  When the list fits in one page the `NextToken` key is omitted, never `""`:
  Grafana loops until the token is absent.
- **Plain HTTP only.** The clients are built without TLS, for both Trino and
  the S3-compatible store, and the server itself speaks plain HTTP. To reach an
  HTTPS endpoint, add the `rustls` feature to `reqwest` in `Cargo.toml` (and CA
  certificates to the image). A client that refuses plain HTTP needs a TLS
  terminator in front instead; Athena JDBC 3.x is one, and Usage has a worked
  nginx example.
- **`ClientRequestToken` is required and not normalized.** Omitting it, or
  sending one shorter than 32 or longer than 128 characters, fails with
  `INVALID_INPUT` (see Supported API above); the length is counted with
  `chars().count()`, which was only measured with ASCII input, so whether real
  Athena counts bytes or characters for non-ASCII tokens is unknown. A token
  that passes validation is used verbatim as a map key: case, leading/trailing
  whitespace and non-ASCII characters are all significant. Whether real Athena
  normalizes it has not been measured. `Database` and `OutputLocation` are
  compared as sent, before `TRINO_SCHEMA` or `ATHENA_LOCAL_OUTPUT_LOCATION`
  fills them in, so a retry that spells out the default a first call left out
  is `IDEMPOTENT_PARAMETER_MISMATCH`; whether real Athena does the same has
  not been measured. The token → id mapping is kept in memory until the
  execution it points at is dropped (`ATHENA_LOCAL_RETENTION_SECONDS`), and
  real Athena's token lifetime beyond 60 seconds has not been measured.
  **Raw HTTP / curl clients must supply their own token** — the AWS CLI and
  SDKs add one automatically, but a request built by hand needs to set
  `ClientRequestToken` itself (measured).
- **Finished queries are dropped after a retention period.** A query that has
  reached `SUCCEEDED`, `FAILED` or `CANCELLED` is kept for
  `ATHENA_LOCAL_RETENTION_SECONDS` (one hour by default) and then dropped,
  together with the `ClientRequestToken` that points at it; queued and running
  queries are never dropped. Real Athena's retention period has not been
  measured beyond 60 seconds, so one hour is athena-local's own number. Once a
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
  on a timer, so nothing is swept while the server is idle; memory is still
  bounded by the queries that finished within the period.
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
