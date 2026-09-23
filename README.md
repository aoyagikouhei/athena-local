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
      # Optional: Athena catalog names Trino cannot have (see docs/configuration.md).
      # TRINO_CATALOG_MAP: s3tablescatalog/my-bucket=iceberg
      # Optional: write result CSVs to MinIO (see docs/result-files.md).
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

## Documentation

- [docs/configuration.md](docs/configuration.md) — environment variables and catalog aliases
- [docs/api.md](docs/api.md) — supported operations and the Athena behaviour they reproduce
- [docs/result-files.md](docs/result-files.md) — result files and `.metadata` companions written to `OutputLocation`
- [docs/ddl.md](docs/ddl.md) — DDL whose result files depend on the target table's format
- [docs/parameters.md](docs/parameters.md) — how `ExecutionParameters` values are classified and bound
- [docs/caveats.md](docs/caveats.md) — known differences from real Athena
- [docs/clients.md](docs/clients.md) — notes for specific clients (Athena JDBC 3.x behind a TLS terminator)
- [docs/dev/development.md](docs/dev/development.md) — building, testing and releasing (for contributors, in Japanese)
