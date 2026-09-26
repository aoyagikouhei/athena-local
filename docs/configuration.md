# Configuration

Environment variables athena-local reads at startup, and how catalog aliases work.

| Variable | Default | Description |
| --- | --- | --- |
| `ATHENA_LOCAL_BIND` | `0.0.0.0:8080` | Listen address |
| `TRINO_URL` | `http://trino:8080` | Trino to execute SQL on |
| `TRINO_USER` | `athena-local` | Value of the `X-Trino-User` header |
| `TRINO_CATALOG` | *(none)* | Default catalog sent to Trino when the request has no `QueryExecutionContext.Catalog`, and for metadata statements and DDL whose `QueryExecutionContext.Catalog` does not exist in Trino when `TRINO_CATALOG_MAP` has no `AwsDataCatalog` alias (see [Caveats](caveats.md#sql-dialect)). Not echoed by `GetQueryExecution` (see [Supported API](api.md#supported-api)) |
| `TRINO_SCHEMA` | *(none)* | Default schema sent to Trino when the request has no `QueryExecutionContext.Database`. Not echoed by `GetQueryExecution` |
| `TRINO_CATALOG_MAP` | *(none)* | Catalog aliases: `<athena name>=<trino name>`, comma separated. A malformed value stops the server at startup. The `AwsDataCatalog` alias (matched regardless of case) also stands in for a `QueryExecutionContext.Catalog` that does not exist in Trino, for metadata statements and DDL (see [Caveats](caveats.md#sql-dialect)) |
| `ATHENA_LOCAL_RETENTION_SECONDS` | `3600` | How long a finished query (`SUCCEEDED` / `FAILED` / `CANCELLED`) and its `ClientRequestToken` are kept, in seconds. Queued and running queries are never dropped. The default is shorter than real Athena, which still knew a query and its token 67 minutes after completion (measured 2026-09-24; see [Query lifecycle](caveats.md#query-lifecycle)). A value that is not a positive integer stops the server at startup. There is no "keep forever" value, so use a large number instead |
| `ATHENA_LOCAL_RESULTS` | `none` | `s3` writes results to `OutputLocation`: a `SELECT` and `SHOW FUNCTIONS` as CSV, DDL, other `SHOW`, `DESCRIBE` and `EXPLAIN` as text, and only a `.metadata` companion for `INSERT` / `UPDATE` / `DELETE` / `MERGE` and CTAS (see [Result files](result-files.md#result-files)). `none` writes nothing |
| `ATHENA_LOCAL_WORK_GROUPS` | `primary` | Workgroup names that `ListWorkGroups` returns, comma separated. `GetWorkGroup` still accepts any name, listed or not. An empty entry stops the server at startup |
| `ATHENA_LOCAL_OUTPUT_LOCATION` | *(none)* | With `s3`: `s3://bucket/prefix` used when the request has no `ResultConfiguration.OutputLocation` (stands in for the workgroup default). `GetWorkGroup` also reports it as `Configuration.ResultConfiguration.OutputLocation`. When no default output location is set, athena-local prints a one-line warning at startup and keeps running (see the [awswrangler Caveat](caveats.md#clients-and-transport)) |
| `AWS_ENDPOINT_URL_S3` | *(none)* | With `s3`: the S3-compatible store, `http://` only. Falls back to `AWS_ENDPOINT_URL` |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | *(none)* | With `s3`: credentials for the store |
| `AWS_REGION` | `us-east-1` | With `s3`: region used for signing |

With `ATHENA_LOCAL_RESULTS=s3`, a missing endpoint or credential, an `https://`
endpoint, or a malformed `ATHENA_LOCAL_OUTPUT_LOCATION` stops the server at
startup. In every case where a malformed variable stops the server, the reason
is printed as one plain line on stderr. The store itself is not contacted until
a query finishes, so the bucket may be created after athena-local starts.

Catalog and schema are passed to Trino as `X-Trino-Catalog` / `X-Trino-Schema`
headers. **Without `ExecutionParameters` the SQL string is not rewritten**, except
for catalog aliases in qualified names (below) and, as on real Athena, a `;`
around the statement and the whitespace before and after it, which are removed,
and an unquoted `awsdatacatalog.` or database in the name of `DESCRIBE` and a
few other statements, which is dropped (see [Supported API](api.md)), and,
under an S3 Tables context catalog, the first part of a plain
`CREATE TABLE AwsDataCatalog.<namespace>.<table>`, which is blanked out (see
[Caveats](caveats.md#plain-create-table)), and, under an S3 Tables context
catalog, the first part of a CTAS into `awsdatacatalog.<database>.<table>`,
which is replaced by the Trino catalog of the `AwsDataCatalog` alias (see
[Caveats](caveats.md#parameters-and-catalog-aliases)). Unqualified table names with the
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

This alias resolution runs for statements such as `SELECT`; `DESCRIBE`,
`DROP TABLE` and the other statements listed in
[Caveats](caveats.md#sql-dialect) reject a double-quoted alias before it
would be applied, the same way real Athena rejects those statements'
double-quoted names outright.
