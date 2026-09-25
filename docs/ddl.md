# DDL that depends on the target table's format

How `DROP TABLE`, `ALTER TABLE ... ADD COLUMNS` / `REPLACE COLUMNS`, `SHOW CREATE TABLE`, `DESCRIBE` and `SHOW COLUMNS` write their result files depending on the target table's format, and how athena-local detects that format.

`DROP TABLE` and `ALTER TABLE ... ADD COLUMNS` write a different `<id>.txt`
and `.metadata` companion depending on whether the Trino catalog holding the
target table uses the `hive` or the `iceberg` connector (measured against
Athena on 2026-09-20 and 2026-09-21, reproduced across three rounds).
`SHOW CREATE TABLE` splits the same way (measured 2026-09-24, a Hive and an
Iceberg table in the same round, each created both without and with a CTAS):

| Statement | Target format | `<id>.txt` | Content-Type | `.metadata` |
| --- | --- | --- | --- | --- |
| `DROP TABLE` | Iceberg | a single newline (1 byte) | `application/octet-stream` | 41 bytes: the engine's query id (field 1), then `DROP TABLE` (field 2) |
| `DROP TABLE` | Hive, or `IF EXISTS` on a missing target | empty | `binary/octet-stream` | none |
| `ALTER TABLE ... ADD COLUMNS` | Hive | empty | `application/octet-stream` | 38 bytes: `QueryExecutionId` only (field 1); no `updateType`, count or columns |
| `ALTER TABLE ... ADD COLUMNS` | Iceberg | empty | `binary/octet-stream` | none |
| `ALTER TABLE ... REPLACE COLUMNS` | Hive | empty | `application/octet-stream` | 38 bytes, byte for byte the same as the `ADD COLUMNS` row (measured 2026-09-21) |
| `ALTER TABLE ... REPLACE COLUMNS` | Iceberg | Athena itself fails the query | — | — |
| `SHOW CREATE TABLE` | Hive | the DDL text | `application/octet-stream` | plain protobuf with the `QueryExecutionId` at its head |
| `SHOW CREATE TABLE` | Iceberg | the DDL text (here, Trino's `SHOW CREATE TABLE` output) | `binary/octet-stream` | Athena writes an opaque blob (see [Caveats](caveats.md#result-files-and-metadata)); athena-local writes plain protobuf with the engine's query id at its head |
| `DESCRIBE` | Hive | the column list, padded to 20 characters in Hive's type spelling | `application/octet-stream` | plain protobuf with the `QueryExecutionId` at its head |
| `DESCRIBE` | Iceberg | the column list and partition spec, unpadded in Iceberg's type spelling | `binary/octet-stream` | Athena writes an opaque blob; athena-local writes plain protobuf with the engine's query id at its head (measured 2026-09-24) |
| `DESCRIBE` / `SHOW COLUMNS` | a view | `<name>\t<type>` per column, unpadded in Trino's type spelling | `binary/octet-stream` | Athena writes an opaque blob; athena-local writes plain protobuf with the engine's query id at its head (measured 2026-09-24) |

`DESC` behaves exactly like `DESCRIBE` (measured 2026-09-24). The rows are
spelled out under [Result files](result-files.md). `SHOW COLUMNS` keeps
`binary/octet-stream` and an `UpdateCount` of `0` on every format; only its
rows depend on the format (padded on a Hive table, unpadded on an Iceberg
table).

`SHOW CREATE TABLE` and `DESCRIBE` also split their `UpdateCount` by format:
a Hive table leaves it out, an Iceberg table and a view return `0` (measured
2026-09-24; see [Supported API](api.md#supported-api)). `DESCRIBE` and
`SHOW COLUMNS` on a view also get the `SubstatementType` `DESC_VIEW` and
Athena's two `varchar` columns `column` / `type`.

The 41-byte and 38-byte companions carry no `ColumnInfo` at all, which is
outside what a `.metadata` file is otherwise for. Athena JDBC 3.8.1 reads them
without an exception: in its default `ResultFetcher=auto`, and again with
`ResultFetcher=S3`, it logged `loaded query result metadata` for both files and
returned from `execute()` normally. The same run covered a `DROP TABLE` that
writes no companion at all (the driver logs `does not have query result
metadata` and carries on) and a `SELECT` for regression (verified against
athena-local on 2026-09-21 with
`tools/measure/jdbc-metadata.sh`).

Write `ADD COLUMN` (singular) to reach the `ADD COLUMNS` row from
athena-local: Trino's grammar rejects Athena's `ADD COLUMNS` at the syntax
check. That singular spelling is only a way to drive athena-local, not SQL
that also runs unchanged on real Athena: Athena's own grammar rejects
`ADD COLUMN` (singular) at `StartQueryExecution` too (see
[Caveats](caveats.md#alter-table-and-format-dependent-ddl)). `REPLACE COLUMNS`
has no Trino spelling at all, so that row cannot be
reached through athena-local; it is listed because the classification and the
format probe follow Athena for it. See [Caveats](caveats.md#alter-table-and-format-dependent-ddl) for every spelling
Trino rejects.

Every other `ALTER TABLE` form that gets a `SubstatementType` (`SET
TBLPROPERTIES`, `DROP COLUMN`, `SET LOCATION`, `ADD PARTITION`,
`DROP PARTITION`, `RENAME TO`) behaves on Athena like ordinary column-less
DDL: an empty `<id>.txt`, `binary/octet-stream`, and no `.metadata`. All six
were measured on 2026-09-21 on whichever table format Athena accepts them on
(see [Caveats](caveats.md#alter-table-and-format-dependent-ddl) for the combinations Athena itself rejects). Of the
six, only `DROP COLUMN` and `RENAME TO` can be run through athena-local; the
rest are rejected at the syntax check, so their rows describe Athena alone.

Only the statements in the table above (`DESC` included) trigger the format
probe below; no other statement sends it. `DROP TABLE` and `ALTER TABLE` send
it only with `ATHENA_LOCAL_RESULTS=s3` (with `none` there is no result file
for it to change), while `SHOW CREATE TABLE`, `DESCRIBE` and `SHOW COLUMNS`
send it with `none` too, because their `UpdateCount` or rows depend on the
answer. For a matching statement, athena-local
sends the format probe as a single query, asking which connector backs the
target's catalog and whether the target exists:

```sql
SELECT
  (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = '<catalog>'),
  (SELECT table_type FROM system.jdbc.tables
   WHERE table_cat = '<catalog>' AND table_schem = '<schema>' AND table_name = '<table>')
```

For `DESCRIBE` and `SHOW COLUMNS` the probe also reads the target's
`table_type`, so that a view is told apart from a table in any catalog. For
`DESCRIBE` on an Iceberg table athena-local then sends Trino's
`SHOW CREATE TABLE` for the same name to read the partition spec (see
[Result files](result-files.md) for what happens when it fails).

The catalog, schema and table name come from a qualified name in the SQL when
`DROP TABLE`, `ALTER TABLE ... ADD COLUMNS`, `SHOW CREATE TABLE`, `DESCRIBE`
or `SHOW COLUMNS FROM` / `IN` gives one (`t`, `ns.t` or
`cat.ns.t`, with a leading `IF EXISTS` skipped for `DROP TABLE`;
`ALTER TABLE IF EXISTS ...` gets no `SubstatementType` and runs as ordinary
column-less DDL without the probe). Because `StartQueryExecution` rejects a
double-quoted part in the name of any of these statements up front, before
this analysis runs (see [Caveats](caveats.md#sql-dialect)), the name it sees
in practice is unquoted; a handful of quoted forms Caveats lists as
unmeasured still reach this analysis with a quoted part, and a quoted S3
Tables catalog alias (`"s3tablescatalog/my-bucket"`) never does, because it
is one of the rejected forms. Whichever part
a qualified name does not give falls back to `QueryExecutionContext` /
`TRINO_CATALOG` / `TRINO_SCHEMA`. A catalog taken from the SQL is translated
through `TRINO_CATALOG_MAP` before the format probe is sent, the same as the
catalog used to run the statement itself.

athena-local falls back to ordinary column-less DDL (empty file, no
`.metadata`) when any of these hold:

- the qualified name has more than three parts;
- the catalog or schema still cannot be resolved;
- the format probe fails;
- the connector is neither `hive` nor `iceberg`;
- for `DROP TABLE` only, the target does not exist. (For
  `ALTER TABLE ... ADD COLUMNS`, Trino itself errors out on a missing target
  before athena-local would reach this fallback.)

`SHOW CREATE TABLE` and `DESCRIBE` never fall back to an empty file: in these
cases they get the Hive row (`application/octet-stream`, the `QueryExecutionId`
at the head of the `.metadata`, no `UpdateCount`), which differs from Athena
when the target is an Iceberg table or a view. The rows of `DESCRIBE` and
`SHOW COLUMNS` fall back to the Hive shape as well (padded to 20 characters,
Hive's type spelling, a `# Partition Information` block for partition
columns). `DESCRIBE EXTENDED` and `DESCRIBE FORMATTED` are read with `EXTENDED` /
`FORMATTED` as the table name, so they always get the Hive row (how Athena
treats them on an Iceberg table has not been measured).

A view is detected by its `table_type`, whichever connector backs its
catalog, and gets the view row of the table above. Trino's
`SHOW CREATE TABLE` fails on a view (write `SHOW CREATE VIEW`), but
`DESCRIBE` and `SHOW COLUMNS` on it succeed.

For `DROP TABLE`, that last fallback happens to match what real Athena does
for `DROP TABLE IF EXISTS` on a missing table too (measured 2026-09-21). See
[Caveats](caveats.md#alter-table-and-format-dependent-ddl) for the limits of this detection.
