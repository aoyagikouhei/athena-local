# Result files

The result file `OutputLocation` names and, with `ATHENA_LOCAL_RESULTS=s3`, the files athena-local writes there: the result file itself and its `.metadata` companion.

`GetQueryExecution` returns `ResultConfiguration.OutputLocation` as the full
path of the file Athena would create, whenever the request (or, with
`ATHENA_LOCAL_RESULTS=s3`, the default) gives an output location. A trailing `/`
on the location makes no difference. The file name depends on the statement:

| Statement | `OutputLocation` |
| --- | --- |
| `SELECT` / `WITH` / `VALUES` / `TABLE` / `SHOW FUNCTIONS` | `s3://bucket/prefix/<id>.csv` |
| `UPDATE` / `DELETE` / `MERGE` | `s3://bucket/prefix/<id>.csv` (only the `.metadata` companion is written) |
| `INSERT` | `s3://bucket/prefix/<id>` (only the `.metadata` companion is written) |
| `CREATE TABLE ... AS` followed by `SELECT` / `WITH` / `VALUES` / `TABLE`, with or without parentheses (CTAS) | `s3://bucket/prefix/tables/<id>` (only the `.metadata` companion is written) |
| Other DDL, `SHOW` (except `SHOW FUNCTIONS`), `DESCRIBE`, ... | `s3://bucket/prefix/<id>.txt` |

`DROP TABLE` and `ALTER TABLE ... ADD COLUMNS` keep the `<id>.txt` name above;
see [DDL that depends on the target table's format](ddl.md#ddl-that-depends-on-the-target-tables-format)
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

`SHOW FUNCTIONS` is the one `SHOW` statement that writes this CSV, header line
included, rather than `<id>.txt` (measured 2026-09-23: 89,425 bytes for the
whole function list, with a `""` field for an empty description).

DDL, the other `SHOW` statements, `DESCRIBE` and `EXPLAIN` write `<id>.txt` the same way (measured
2026-09-16). The file holds the rows `GetQueryResults` returns, joined with `\n`:

- No header line for DDL, `SHOW` and `DESCRIBE`, unlike the CSV, and no trailing
  newline. `EXPLAIN` is `DML`, and its file starts with the header line
  `Query Plan` just as its `GetQueryResults` does (measured 2026-09-15 and
  2026-09-16). Because the plan is split into rows with one newline appended
  (see [Supported API](api.md#supported-api)), the file is the header line, the plan text as Trino returns it
  and a final `\n`: 393 bytes for `EXPLAIN SELECT 1` on Athena.
- A statement that returns no rows writes an empty file, `CREATE SCHEMA` for
  example.
- Columns are joined with a tab. `DESCRIBE` / `DESC` and `SHOW COLUMNS`
  have a single value per row, built the way Athena builds it, so the file is
  byte for byte Athena's for the tables measured (2026-09-24), padding
  included:
  - `SHOW COLUMNS` on a Hive table: one column name per row, padded with
    spaces on the right to 20 characters (width counted in characters, not
    bytes); a name of 20 characters or more is left as it is, never cut.
    Partition columns are listed too. On an Iceberg table the names are not
    padded.
  - `DESCRIBE` on a Hive table: `<name>\t<type>\t<comment>`, each field padded
    the same way. A missing comment becomes 20 spaces, and a comment is cut at
    its first tab after padding. Types use Hive's spelling: `integer` is
    `int`, `real` `float`, `varchar` `string`, `varbinary` `binary`,
    `timestamp(3)` `timestamp`, `array(varchar)` `array<string>`,
    `map(varchar, integer)` `map<string,int>`, `row("a" integer)`
    `struct<a:int>`; `varchar(n)`, `char(n)`, `decimal(p,s)`, `bigint`,
    `smallint`, `tinyint`, `double`, `boolean` and `date` are unchanged. When
    the table has partition columns, they appear among the columns and again
    after the four rows `\t \t `, `# Partition Information\t \t `,
    `# col_name            \tdata_type           \tcomment             ` and
    `\t \t `.
  - `DESCRIBE` on an Iceberg table: nothing is padded. The rows are
    `# Table schema:\t\t`, `# col_name\tdata_type\tcomment`, one
    `<name>\t<type>\t<comment>` per column (an empty comment leaves the
    trailing tab), `\t\t`, `# Partition spec:\t\t`,
    `# field_name\tfield_transform\tcolumn_name` and one
    `<field_name>\t<transform>\t<column>` per partition field, for example
    `s\tidentity\ts`, `n_bucket\tbucket[4]\tn`, `s_trunc\ttruncate[3]\ts` and
    `ts_day\tday\tts` (`year`, `month` and `hour` name the field the same
    way). Types use Iceberg's spelling: `int`, `string`, `float`, `binary`,
    `timestamp`, `decimal(10, 2)`, `array<string>`, `map<string, int>`,
    `struct<a: int>`. athena-local reads the partition fields from Trino's
    `SHOW CREATE TABLE` of the target, which it sends as an extra query; if
    that query fails, the rows stop after the `# field_name` heading.
  - `DESCRIBE` and `SHOW COLUMNS` on a view: `<name>\t<type>` with Trino's
    type spelling (`n\tinteger`, `s\tvarchar(1)`), not padded, which is what
    Athena returns as well.
- On an Iceberg table, `DROP TABLE` writes a single newline on Athena, which
  returns two empty rows for zero columns; athena-local matches it there
  (measured 2026-09-20 and 2026-09-21, reproduced across three rounds). On a
  Hive table, or with `IF EXISTS` on a missing target, both write an empty file.
See
  [DDL that depends on the target table's format](ddl.md#ddl-that-depends-on-the-target-tables-format).

The object is uploaded with a presigned `PUT` (path-style), so any
S3-compatible store works; it is not retried, and a `PUT` that gets no response
within 30 seconds is given up on so the query still reaches a final state
(the limit is fixed and has no environment variable).

The `Content-Type` of the upload follows Athena, which uses
`binary/octet-stream` for the files it writes without planning the query and
`application/octet-stream` for everything else (36 statements measured
2026-09-23 with controls, then 18 more the same day, issues #70 and #76, with
the same statement giving the same value across rounds and days). The
`.metadata` companion gets the same Content-Type as its result file; the one
exception seen is the multipart upload described at the end of this section,
which athena-local never produces.

| Statement | Content-Type |
| --- | --- |
| `SELECT` of literals only: `SELECT 1`, `SELECT 1, 2`, `SELECT 'a'`, `SELECT 1.5`, `SELECT -1`, `SELECT - 1`, `SELECT 1.5E0`, `SELECT true`, `SELECT 1, 'a'`, `SELECT 1 AS i`, `SELECT 1 AS "x"`, `SELECT 1 i`, `SELECT 1 AS i, 2 AS j`, `select 1`, a literal in parentheses (`SELECT (1)`, `SELECT ((1))`, `SELECT (1) AS x`, `SELECT ('a')`, `SELECT (-1)`, `SELECT (1), 2`), with or without comments | `binary/octet-stream` |
| Any other `SELECT`: an expression (`SELECT 1 + 1`, `SELECT (1 + 1)`, `SELECT 'a' \|\| 'b'`), a sign outside parentheses (`SELECT -(1)`) or a `+` sign (`SELECT +1`), a `CAST`, `NULL` (also `(NULL)`), a row (`SELECT (1, 2)`), a typed literal (`DATE '2020-01-01'`), `ARRAY[1]`, a `WHERE`, a `LIMIT`, a `FROM`, `(SELECT 1)`, `VALUES 1`, `UNION`, or a table | `application/octet-stream` |
| `SHOW TABLES`, `SHOW DATABASES`, `SHOW COLUMNS`, `SHOW TBLPROPERTIES`, `SHOW VIEWS`, `SHOW PARTITIONS`, `SHOW CREATE VIEW`, `SHOW CREATE TABLE` on an Iceberg table (see [DDL](ddl.md#ddl-that-depends-on-the-target-tables-format)) | `binary/octet-stream` |
| `DESCRIBE` and `SHOW CREATE TABLE` on a Hive table (an Iceberg table gets `binary/octet-stream`; see [DDL](ddl.md#ddl-that-depends-on-the-target-tables-format)), `DESC`, `EXPLAIN`, `SHOW FUNCTIONS` (the `<id>.csv` above) | `application/octet-stream` |
| Column-less DDL (`CREATE DATABASE`, `DROP DATABASE`, ...) | `binary/octet-stream` |
| `INSERT`, `UPDATE`, `DELETE`, `MERGE`, CTAS (`.metadata` only) | `application/octet-stream` |

athena-local recognises a literals-only `SELECT` as a comma-separated list of
numbers (an optional `-` before the digits, an optional fraction and
an optional exponent), single-quoted strings and `true`/`false`, each
optionally wrapped in any number of balanced parentheses and
optionally followed by an alias (with or without `AS`, unquoted or
double-quoted), with nothing after it but whitespace and comments; keyword
case does not matter. The forms measured are the ones in the table (the
parenthesised ones and `SELECT - 1` on 2026-09-25, issue #205); the only
generalisations are combining them, a lowercase `e` or a signed exponent
(`SELECT -1.5e-1 x`), more than two pairs of parentheses, a comment between
`-` and the digits, and keyword case.
Everything else is sent as `application/octet-stream`, the value Athena gave
every measured `SELECT` that is not literals only. Two measured forms cannot be
compared: Athena writes `SELECT 1;` as `binary/octet-stream`, but Trino
rejects the trailing `;`, so athena-local fails it at the syntax check; and
Athena rejects `SHOW SESSION` and `SHOW STATS FOR t` at `StartQueryExecution`
(`InvalidRequestException`, `no viable alternative`), while Trino runs them, so
athena-local writes their `<id>.txt` with the `binary/octet-stream` default.
`SHOW CREATE VIEW` is `binary/octet-stream` for both the `.txt` and its
`.metadata`, with `SubstatementType` `SHOW_CREATE_VIEW`, unlike
`SHOW CREATE TABLE` on a Hive table (measured 2026-09-24, also with a `/* c */` between
`CREATE` and `VIEW`); its real `.metadata` is one of the opaque ones (see
[Caveats](caveats.md#result-files-and-metadata)).
`SHOW FUNCTIONS` writes `<id>.csv` with a header
row, as `application/octet-stream`, with `SubstatementType` `SHOW_FUNCTIONS`
and with the engine's query id at the head of its `.metadata`, all as measured
on 2026-09-23; a failed `SHOW FUNCTIONS` writes no result file, as on Athena
(measured 2026-09-24) and as for every other `<id>.csv` statement.
Two DDL combinations depend on the target table's format instead: `DROP TABLE`
on an Iceberg table and `ALTER TABLE ... ADD COLUMNS` on a Hive table send
their `<id>.txt` and `.metadata` as `application/octet-stream` (measured
2026-09-20/21; see
[DDL that depends on the target table's format](ddl.md#ddl-that-depends-on-the-target-tables-format)).
The one exception to "the companion matches its result file": Athena uploads a
large result in parts and that object comes back as `binary/octet-stream` with
an `application/octet-stream` companion. A 98.9 MB result was still a single
upload with `application/octet-stream`, and a 142.9 MB one was multipart
(measured 2026-09-23 with results generated from `UNNEST(sequence(...))`, and
a 140 MB table scan on 2026-09-22), so the switch lies between those sizes;
athena-local always uploads in one `PUT`.

A failed CSV upload makes the query `FAILED` with the store's response in
`StateChangeReason`. A failed `<id>.txt` or `.metadata` upload leaves the query
`SUCCEEDED` and logs one line instead: the statement has already run on Trino,
and DDL cannot be undone. When the result file itself fails to upload, no
companion file is attempted.

A failed query writes a result file too, but only for the statements whose
result file is `<id>.txt` (DDL, `SHOW` other than `SHOW FUNCTIONS`, `DESCRIBE`; not `EXPLAIN`), so a client that
reads the result file can see why it failed. The file holds `FAILED: ` followed
by `StateChangeReason`, with no trailing newline, and is sent as
`application/octet-stream` whatever the statement (a successful `SHOW TABLES`
gets `binary/octet-stream`); no `.metadata` companion is written. `SELECT`, DML, CTAS and
`EXPLAIN` (plain or `ANALYZE`, measured 2026-09-23) write nothing, and neither does a cancelled query. The upload happens before the query
becomes `FAILED`, so a client may read the file as soon as it sees that state;
an upload that fails logs one line and leaves the state and the reason
unchanged. Athena writes such a file for fewer statements; see [Caveats](caveats.md#failed-queries).

An `OutputLocation` that is not `s3://bucket[/prefix]` is rejected in either
mode with `outputLocation is not a valid S3 path.` (`INVALID_INPUT`), as Athena
does. With `ATHENA_LOCAL_RESULTS=s3` and no location at all,
`StartQueryExecution` fails with Athena's `No output location provided. ...`
message (`INVALID_INPUT`).


## Companion `.metadata` files

With `ATHENA_LOCAL_RESULTS=s3`, a companion file named after the result file
plus `.metadata` is written next to it, as Athena does (measured 2026-09-17):
`<id>.csv.metadata`, `<id>.txt.metadata`, `<id>.metadata` for `INSERT`, and
`tables/<id>.metadata` for a CTAS whatever the table format (measured 2026-09-19). It is uploaded with
the same `Content-Type` as its result file (see
[Result files](#result-files)). Athena JDBC 3.x is
the client that needs it: its default `ResultFetcher=auto` reads the result and
the metadata straight
from S3 instead of calling `GetQueryResults`, and versions before 3.5.1 fail
with `NoSuchKey` when a DDL statement has no metadata file. athena-local writes
no companion file for most column-less DDL either, so those statements still
fail on versions before 3.5.1: against athena-local, `CREATE TABLE` (a form
athena-local now rejects up front, see
[Caveats](caveats.md#plain-create-table)) raised `NoSuchKey` on 3.4.0 and
3.5.0 with the default `ResultFetcher` (the statement itself had run), while with `ResultFetcher=S3` no version fetched the metadata
of a DDL or `SHOW` and nothing failed (measured 2026-09-23). 3.8.1 logs the
missing file (a 404) at INFO level and carries on (measured 2026-09-17). The
`SHOW` statements, whose companion file athena-local does write, ran without
error on every version from 3.0.0 to 3.8.1; 3.4.0, 3.5.0 and 3.8.1 with the
default fetcher also loaded that companion file, while older versions were only
run with `ResultFetcher=S3`, which never fetches it (measured 2026-09-23). Two
combinations are the exception
and do get a companion file that carries no columns at all; see
[DDL that depends on the target table's format](ddl.md#ddl-that-depends-on-the-target-tables-format)
for what the driver does with those. PyAthena, awswrangler and dbt-athena do
not read it.

The file is written for every statement that has columns: `SELECT` (also when
it returns no rows), `SHOW` / `DESCRIBE` / `EXPLAIN`, DML (`INSERT` / `UPDATE`
/ `DELETE` / `MERGE`) and CTAS. DML and CTAS write the companion file only and
no result file of their own, as on Athena. DDL without columns
(`CREATE DATABASE`, `DROP DATABASE`, `CREATE TABLE`), a failed query and a
cancelled query write no companion file, also as on Athena — except the two
combinations described under
[DDL that depends on the target table's format](ddl.md#ddl-that-depends-on-the-target-tables-format).
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
  `Scale`, `Nullable`, `CaseSensitive`. For `SHOW CREATE TABLE` that is
  Athena's own column `createtab_stmt` / `string` rather than Trino's, so on a
  Hive table the file is Athena's 88 bytes apart from the query id (measured
  2026-09-23; see [Supported API](api.md#supported-api)). Likewise `DESCRIBE`
  carries Athena's three `string` columns `col_name` / `data_type` /
  `comment`, so on a Hive table its file is Athena's 152 bytes apart from the
  query id (measured 2026-09-24).

The query id follows Athena's own split: `SELECT`, DML, CTAS, `EXPLAIN` and the
`SHOW` statements (including `SHOW CREATE VIEW`) carry the engine's query id
(Trino's here, Athena's engine id there), while `DESCRIBE`,
`SHOW CREATE TABLE` on a Hive table and a `SELECT` of literals only (the forms
written as `binary/octet-stream` under [Result files](#result-files), such as
`SELECT 1` or `SELECT (1)`; measured 2026-09-23 and 2026-09-25) carry the
`QueryExecutionId` (on an Iceberg table `DESCRIBE` and `SHOW CREATE TABLE` use
the engine id; see below).
For the `SHOW` statements whose real companion file is opaque (see [Caveats](caveats.md#result-files-and-metadata))
Athena's own choice cannot be observed, so athena-local uses the engine id there
by analogy with `EXPLAIN`. The statements under
[DDL that depends on the target table's format](ddl.md#ddl-that-depends-on-the-target-tables-format)
follow the same split: `DROP TABLE` on an Iceberg table carries the engine's
query id, like `EXPLAIN`, while `ALTER TABLE ... ADD COLUMNS` on a Hive table
carries the `QueryExecutionId`, like `DESCRIBE` (measured 2026-09-21);
`SHOW CREATE TABLE` and `DESCRIBE` on an Iceberg table, whose real companions are opaque, use
the engine id like the opaque `SHOW` statements.
