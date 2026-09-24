# Clients

Notes on running specific Athena clients against athena-local: which parts of
the API or the result files they depend on, and how to connect them.

## Athena JDBC 3.x needs a TLS terminator in front

The Athena JDBC driver 3.x refuses a plain-HTTP endpoint. `AthenaEndpoint` and
`S3Endpoint` go through
`com.amazon.athena.jdbc.support.EndpointHelper.constructEndpointUri`, which
prepends `https://` when the scheme is missing and throws
`IllegalArgumentException` —
`The Athena endpoint "http://localhost:8084" is not an HTTPS endpoint` — for any
other scheme. No property turns that off (disassembled from 3.8.1, 2026-09-17).
athena-local serves plain HTTP only (see [Caveats](caveats.md#clients-and-transport)), so terminate TLS in front of
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

Add it to the compose file in the [README](../README.md#usage), next to the `minio` service the driver
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

## PyAthena

PyAthena's pandas and arrow cursors read the result file rather than
`GetQueryResults`, so DDL, `SHOW` and `DESCRIBE` need `ATHENA_LOCAL_RESULTS=s3`,
which writes their `<id>.txt` (`<id>.csv` for `SHOW FUNCTIONS`; see
[Result files](result-files.md#result-files)).
The pandas and arrow cursors read that file even for DDL. For `DROP TABLE` on
an Iceberg table the file is a single newline, the same as Athena writes, and
pandas raises `EmptyDataError` on it, which PyAthena 3.36.0 reports as
`OperationalError`, against Athena itself as well (measured 2026-09-25; the
default cursor and `DROP TABLE` on a Hive table, whose file is empty, raise
nothing). Run DDL with the default cursor.

## dbt-athena

dbt-athena 1.11.1 runs `dbt debug` and `dbt run-operation` against
athena-local, including `work_group` in the profile: the adapter's
`is_work_group_output_location_enforced()` calls `GetWorkGroup` and reads
`EnforceWorkGroupConfiguration=false`. `dbt run` does not get that far on
athena-local alone: before running any SQL it lists schemas through AWS Glue
(`GetDatabases`), which athena-local does not provide, so it stops with
`UnknownOperationException` (whether STS would be needed later was not
reached).

Even with Glue answered elsewhere, the `table`, `incremental`, `snapshot` and
`seed` materializations would stop at their `CREATE TABLE ... AS`: dbt-athena
puts Athena's own table properties (`table_type=...`, `is_external=...`) in
its `WITH (...)`, athena-local passes SQL through unchanged, and Trino fails
the query with `INVALID_TABLE_PROPERTY: ... table property 'table_type' does
not exist` on both Hive and Iceberg catalogs (Trino 482, 2026-09-25). The
`view` materialization's `create or replace view ... as` runs. `dbt run`
against real Glue and STS with only Athena pointed at athena-local was not
tried.

For `EXPLAIN` and `SHOW FUNCTIONS`, dbt-athena returns the column-name row
(`Query Plan`, or the `SHOW FUNCTIONS` header) as the first data row. Its
cursor drops the first row of the first page only for statements other than
`DDL`, `UTILITY` and `EXPLAIN`, while Athena puts the column names first for
these two statements. athena-local returns the same rows, so dbt-athena sees
the same result against real Athena (dbt-athena 1.11.1 source, 2026-09-25).

Point it at athena-local with environment variables rather than
`endpoint_url` in the profile. The profile's `endpoint_url` only reaches the
client that runs queries; the adapter's other clients (`GetWorkGroup`, Glue,
STS, S3) ignore it. Set `AWS_ENDPOINT_URL_ATHENA` to athena-local,
`AWS_ENDPOINT_URL_S3` to your S3-compatible storage, and `AWS_ENDPOINT_URL`
to a local address as well, so that Glue and STS calls fail locally instead
of reaching AWS.

## awswrangler and Grafana

Both call `GetWorkGroup` before a query and read fields out of the response
without checking that they are there, so they depend on
[`GetWorkGroup`](api.md#supported-api) being supported.
