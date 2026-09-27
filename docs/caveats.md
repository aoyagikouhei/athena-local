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
  syntax error follows Trino's grammar. `ALTER TABLE IF EXISTS ...` and the
  other unquoted `ALTER TABLE` spellings Trino accepts but Athena's grammar
  does not are rejected at `StartQueryExecution` with Athena's own message,
  as real Athena does — see
  [`ALTER TABLE` and format-dependent DDL](#alter-table-and-format-dependent-ddl).
  A CTAS with a
  column list, such as `CREATE TABLE t (n) AS VALUES 1`, runs on Trino, while
  Athena accepts the call and then fails the query with `MISSING_COLUMN_NAME:
  line 1:1: Column name not specified at position 1` (measured 2026-09-25).
  Name the columns in the query instead (`AS SELECT 1 AS n`). For an incomplete
  statement (`SELECT * FROM`) Athena answers `Queries of this type are not
  supported`; athena-local returns Trino's syntax error.
- **Iceberg maintenance statements differ.** Athena's `OPTIMIZE ... REWRITE DATA`
  and `VACUUM` do not exist in Trino, which uses `ALTER TABLE ... EXECUTE optimize`
  and `ALTER TABLE ... EXECUTE expire_snapshots` instead. athena-local rejects
  `ALTER TABLE ... EXECUTE ...` at `StartQueryExecution` the same as real
  Athena (see [`ALTER TABLE` and format-dependent DDL](#alter-table-and-format-dependent-ddl)),
  so neither spelling runs Iceberg maintenance through athena-local.
- **A block comment in `SHOW CREATE TABLE`, `MSCK REPAIR TABLE`, `ALTER
  TABLE` and `DESCRIBE` fails the way Athena fails it.** Athena hands these
  statements to its Hive parser, which rejects a `/* ... */` before or between
  the keywords, while Trino accepts a comment anywhere whitespace is allowed.
  athena-local does not send such a statement to Trino and fails it with
  Athena's `ParseException` instead — see
  [Block comments Athena's Hive parser rejects](#block-comments-athenas-hive-parser-rejects).
  A `-- ...` line comment is fine on both. `DROP /* c */ TABLE`,
  `CREATE /* c */ TABLE ... AS SELECT`, `SHOW /* c */ TABLES`, `CREATE` /
  `DROP /* c */ DATABASE`, `SHOW PARTITIONS`, `SHOW TBLPROPERTIES`,
  `SHOW COLUMNS FROM`, `SHOW CREATE VIEW` and `CREATE EXTERNAL TABLE` with the
  same comment succeed on Athena and are sent to Trino as written (measured
  2026-09-22 and 2026-09-24).
- **`StartQueryExecution` checks whether the target of `DESCRIBE`, `DESC` and
  `SHOW COLUMNS FROM` / `IN` exists, right after the syntax check and before
  the quoted-name check below, the same as real Athena does.** It asks Trino
  the same question the table-format probe (below, under
  "`ALTER TABLE` and format-dependent DDL") asks at execution time — one
  query for `connector_name` and `table_type`, with the catalog, schema and
  table lower-cased — so for these three statements the query goes to Trino
  twice.
  A missing table or schema, quoted or not and ASCII or not, answers
  `InvalidRequestException` (`AthenaErrorCode` `INVALID_INPUT`) with Athena's
  Glue message, `Entity Not Found (Service: AmazonDataCatalog; Status Code:
  400; Error Code: EntityNotFoundException; Request ID: <a fresh UUID each
  time>; Proxy: null)`; a three-part name whose catalog does not exist in
  Trino answers `InvalidRequestException` (`AthenaErrorCode`
  `DATACATALOG_NOT_FOUND`), `Catalog '<name>' does not exist`; and a
  **view** runs even with a quoted name, because this check decides before
  the quoted-name check below gets to see it (measured 2026-09-25 across two
  rounds and confirmed against a local Trino; see
  [#207](https://github.com/aoyagikouhei/athena-local/issues/207)). When the
  catalog comes from `QueryExecutionContext` or the default and is a
  `TRINO_CATALOG_MAP` alias (such as `AwsDataCatalog=hive`), the table is
  looked up under the Trino catalog the alias points to. A name of four parts
  or more, a three-part name whose catalog is written as a `TRINO_CATALOG_MAP`
  alias, a Trino error, or a response this check does not recognize are all
  left alone — the check
  only rejects a table it can prove is missing, and everything else runs, or
  falls through to the quoted-name check below, as before.
- **A `QueryExecutionContext.Catalog` that does not exist falls back to the
  default catalog for metadata statements and DDL, as on real Athena.** Real
  Athena resolves `DESCRIBE` / `DESC`, `SHOW COLUMNS`, `SHOW TABLES`,
  `SHOW DATABASES` / `SCHEMAS`, `SHOW CREATE TABLE`, `DROP TABLE`, a plain
  `CREATE TABLE`, `ALTER TABLE ... ADD COLUMNS`, `CREATE VIEW`,
  `SHOW CREATE VIEW`, `DROP VIEW` and `CREATE` / `DROP DATABASE` (or
  `SCHEMA`) in its default catalog when the context catalog does not exist,
  while a query that reads or writes table data (`SELECT * FROM t`,
  `EXPLAIN`, a CTAS, `INSERT`, `DELETE`, `UPDATE`, `MERGE`) fails (measured
  2026-09-25 and 2026-09-26). For those statements athena-local asks Trino
  whether the context catalog exists (one extra query in
  `StartQueryExecution` and again before running, only when the catalog is
  given and is not a `TRINO_CATALOG_MAP` alias) and, if it does not, sends
  the `AwsDataCatalog` alias from `TRINO_CATALOG_MAP` instead, or
  `TRINO_CATALOG` when there is no such alias; the existence check above then
  looks the table up there, so a missing table still answers
  `Entity Not Found`. If neither is set, or Trino cannot answer, the name is
  sent as before. `GetQueryExecution` still returns the catalog as sent,
  lower-cased. Other statements are sent with the missing catalog as before:
  a `SELECT` or `EXPLAIN` fails with `CATALOG_NOT_FOUND` and `ErrorType` 1006
  like real Athena, but Trino words it `Catalog '<name>' not found` where
  Athena says `does not exist`; `DELETE`, `UPDATE` and `MERGE` fail with
  `TABLE_NOT_FOUND` and `ErrorType` 1301 like real Athena; a CTAS fails with
  `CATALOG_NOT_FOUND` (1006) and an `INSERT` with `TABLE_NOT_FOUND` (1301)
  where real Athena answers `ErrorType` 1300 with
  `NOT_FOUND: Session property catalog does not exist: <name>. ...`. Real
  Athena also resolves the Hive DDL spellings (`ALTER TABLE ... ADD` /
  `DROP PARTITION`, `SET TBLPROPERTIES`, `SHOW PARTITIONS`,
  `MSCK REPAIR TABLE`, `SHOW TBLPROPERTIES`, `VACUUM`, `OPTIMIZE`) in its
  default catalog, but Trino rejects those spellings as a syntax error
  whatever the catalog (see [DDL](ddl.md)).
- **A quoted table name is rejected at `StartQueryExecution` before it
  reaches Trino, the same as on real Athena.** `DESCRIBE`, `DESC`,
  `SHOW COLUMNS FROM` / `IN`, `DROP TABLE` (with or without `IF EXISTS`),
  `SHOW CREATE TABLE`, `ALTER TABLE` (whichever spelling reaches Trino — see
  "Six `ALTER TABLE` spellings" below — except `ALTER TABLE IF EXISTS`, which
  is rejected by the unquoted-`ALTER TABLE` check below instead, regardless
  of quoting, because Athena's grammar has no `IF EXISTS` form at all),
  `SHOW TABLES IN` with a one- or two-part name, and a plain `CREATE TABLE`
  (not a CTAS) with a one-, two- or three-part name, `CREATE TABLE IF NOT
  EXISTS` included, all answer `InvalidRequestException` (`AthenaErrorCode`
  `MALFORMED_QUERY`) with no `QueryExecutionId` created, whenever the name
  has a double-quoted part, non-ASCII characters included (measured
  2026-09-25 across four rounds of `StartQueryExecution` calls). The
  message is real Athena's own — `no viable alternative at input '...'` or
  `mismatched input '...' expecting {...}`, depending on which part is
  quoted, or `Queries of this type are not supported` for
  `SHOW CREATE TABLE` — with the position counted in UTF-16 units from the
  first non-whitespace character (a leading comment does count). An
  unquoted or a backquoted name of up to three parts still runs: Trino's
  grammar accepts both, and real Athena accepts the unquoted form too (see
  the backquote item below for the one difference that remains between the
  two engines for a quoted name).
  A name of **four parts or more** is rejected differently, and even when
  every part is unquoted: `DESCRIBE`, `DESC`, `SHOW COLUMNS FROM` / `IN`
  and `SHOW CREATE TABLE` answer `Invalid table name <name>` (each part
  unwrapped if quoted and lower-cased, joined with `.`), checked ahead of
  the `TRINO_CATALOG_MAP` alias case below; `DROP TABLE`, `ALTER TABLE` and
  a plain `CREATE TABLE` follow the three-part message rule above when the
  quoted part falls within the first three parts, and otherwise are
  rejected at the third `.` (`mismatched input '.' expecting {<EOF>,
  'PURGE'}` for `DROP TABLE`, `no viable alternative at input '...'` from
  the start of the statement to that `.` for `ALTER TABLE`, and
  `mismatched input '.' expecting {<EOF>, '(', ...}` for `CREATE TABLE`).
  `SHOW TABLES IN` takes a database, so it is rejected from **three parts**:
  a quoted first or second part follows the one- and two-part rule, and
  otherwise the second `.` answers `mismatched input '.' expecting {<EOF>,
  'LIKE', STRING}` — or `extraneous input '.'` with the same list when the
  part right after it is double-quoted, since Hive reads `"x"` as a string
  (measured 2026-09-25).
  A double-quoted catalog that is a `TRINO_CATALOG_MAP` alias — an S3 Tables
  catalog written `"s3tablescatalog/my-bucket"`, for example — is rejected
  the same way even where the alias would otherwise resolve it: `DESCRIBE`,
  `DESC` and `SHOW COLUMNS` answer `Unsupported DDL with 2 catalogs` (unless
  the name has four parts or more, which the check above catches first), and
  the other statements above follow the general rule (measured 2026-09-25);
  see [`TRINO_CATALOG_MAP`](configuration.md#environment-variables) for what
  the alias covers instead. `CREATE TABLE IF NOT EXISTS` with four parts or
  more follows the same rule as `CREATE TABLE` (measured 2026-09-26). A CTAS
  with four or more unquoted parts answers `Invalid table name <the parts
  joined by .>`, with or without `IF NOT EXISTS` or `WITH (...)` (measured
  2026-09-26; only lower-case names were measured, and athena-local lowers
  the parts as it does for `DESCRIBE`). A CTAS with four parts or more that
  has a quoted part was not measured and still runs here unrejected, and
  for `SHOW TABLES IN` a part after the second `.` that is `LIKE` or
  backquoted was not measured either (athena-local answers `mismatched
  input '.'`). Name the table without quotes, in three parts or fewer, to
  avoid depending on any of this. The
  other statements that can take a quoted name right after the keyword —
  `CREATE TABLE "t" AS SELECT` (a CTAS), `CREATE VIEW "v" AS ...`,
  `SHOW CREATE VIEW "v"` and `DROP VIEW "v"` — succeed on real Athena too,
  quoted or not, and athena-local runs them the same way, as does
  `DESCRIBE` / `SHOW COLUMNS` on a view, quoted name included, because the
  existence check above decides before this check runs. (`OPTIMIZE "t" ...`
  is rejected the same way on real Athena, and athena-local rejects every
  `OPTIMIZE` regardless of quoting because Trino has no such statement.)
- **A backquoted name is one difference #204 did not close.** Real Athena
  accepts a backquoted name (`` DESCRIBE `t` ``, `` DROP TABLE `t` ``,
  `` SHOW CREATE TABLE `t` `` and so on), but Trino's grammar rejects a
  backquote as a syntax error, so athena-local rejects it at the syntax
  check where real Athena would have run the statement (measured
  2026-09-25; out of scope for #204).
- **An unquoted `MSCK REPAIR TABLE t` runs on real Athena** (`SubstatementType`
  `MSCK_REPAIR`), but Trino has no `MSCK` statement at all, so athena-local
  rejects it at the syntax check (measured 2026-09-25; out of scope for
  #204). On an Iceberg table, or with a block comment, Athena fails it, and so
  does athena-local — see
  [Block comments Athena's Hive parser rejects](#block-comments-athenas-hive-parser-rejects).
- **An unquoted `DROP DATABASE IF EXISTS x` runs on real Athena**
  (`SubstatementType` `DROP_DATABASE`), but Trino's grammar has `DROP SCHEMA`
  and no `DROP DATABASE`, so athena-local rejects it at the syntax check
  (measured 2026-09-25; out of scope for #204).
- **A plain, unquoted `CREATE TABLE x (n int)` (not a CTAS) is rejected by
  real Athena at `StartQueryExecution`** with `No location was specified for
  table. An S3 location must be specified`, because an Athena table needs an
  explicit S3 location, while Trino's catalogs can supply one on their own.
  athena-local rejects the same forms real Athena does, with Athena's own
  message — see [Plain `CREATE TABLE`](#plain-create-table).

## Block comments Athena's Hive parser rejects

Real Athena starts these queries and then fails them at run time: the
statement is classified as usual (`StatementType`, `SubstatementType` and a
`<id>.txt` `OutputLocation` are the same as without the comment), but
`Status.State` is `FAILED`. athena-local looks up the table's format in Trino,
does not send the statement itself (nor, for `MSCK`, `ADD COLUMNS`,
`REPLACE COLUMNS`, `CHANGE COLUMN` and `DESCRIBE EXTENDED`, which Trino has no
grammar for, its syntax check), and fails it the same way (measured
2026-09-26 and 2026-09-27):

| Statement | Fails on | Runs on |
| --- | --- | --- |
| `SHOW CREATE TABLE` | a Hive table, a view, a missing table | an Iceberg table |
| `DESCRIBE`, `DESC` | a Hive table | an Iceberg table, a view |
| `MSCK REPAIR TABLE` | a Hive table, a view, a missing table | — (an Iceberg table fails differently, below) |
| `ALTER TABLE ... ADD COLUMNS` | a Hive table, a view, a missing table | — (Athena runs it on an Iceberg table, but Trino has no `ADD COLUMNS`, so athena-local still rejects it at the syntax check) |
| `ALTER TABLE ... DROP COLUMN`, `RENAME TO` | a Hive table, a view, a missing table | an Iceberg table |
| `ALTER TABLE ... REPLACE COLUMNS`, `CHANGE COLUMN` (comment after `ALTER` only) | a Hive table | — (a view, a missing table and an Iceberg table were not measured; Trino has no grammar for these, so athena-local rejects them at the syntax check as before) |

A table whose Trino connector is neither `hive` nor `iceberg` (for example
`memory`) has no Athena counterpart, so athena-local does not check its format
and sends the statement to Trino, as it does when the catalog does not exist
or the lookup fails.

The comment has to come first, or between the keywords, or right before the
table name (`SHOW /* c */ CREATE TABLE t`, `MSCK REPAIR TABLE /* c */ t`,
`/* c */ ALTER TABLE t ADD COLUMNS (c int)`, and so on). Four more positions
were measured on a Hive table only, and fail on a Hive table only: right after
the `.` of an unquoted two-part name in `SHOW CREATE TABLE db./* c */t`, after
the name in `MSCK REPAIR TABLE db.t /* c */`, between the name and
`ADD COLUMNS` in `ALTER TABLE db.t /* c */ ADD COLUMNS (c int)`, and after
`EXTENDED` in `DESCRIBE EXTENDED /* c */ db.t`. A view, a missing table and the
other positions were not measured and are handled as before: sent to Trino as
written, or rejected at the syntax check when Trino has no grammar for the
statement. `ALTER /* c */ TABLE t` with `ADD PARTITION`, `DROP PARTITION` or
`SET TBLPROPERTIES` is not failed either, as it succeeds on Athena (those
spellings are Trino syntax errors anyway — see
[`ALTER TABLE` and format-dependent DDL](#alter-table-and-format-dependent-ddl)).

The failure is `ErrorCategory` 1 / `ErrorType` 1003 with a `ParseException`
reason, and `<id>.txt` holds that reason with no `.metadata`:

| Comment | `StateChangeReason` |
| --- | --- |
| first | `FAILED: ParseException line L:C cannot recognize input near '/' '*' 'c'` |
| after `SHOW` | `FAILED: ParseException line L:C cannot recognize input near 'SHOW' '/' '*' in ddl statement` |
| after `SHOW CREATE` | `FAILED: ParseException line L:C mismatched input '/' expecting TABLE near 'CREATE' in show statement` |
| after `MSCK` / `MSCK REPAIR` | `FAILED: ParseException line L:C missing EOF at '/' near 'MSCK'` / `near 'REPAIR'` |
| before the table name | `FAILED: ParseException line L:C cannot recognize input near '/' '*' 'c' in table name` |
| after `ALTER` | `FAILED: ParseException line 1:0 cannot recognize input near 'ALTER' '/' '*' in alter statement` |
| after `DESCRIBE` / `DESC` | `FAILED: ParseException line 1:0 cannot recognize input near 'DESCRIBE' '/' '*' in describe statement` |
| inside the name (`db./* c */t`) | `FAILED: ParseException line L:C cannot recognize input near 'db' '.' '/' in table name` |
| after the name of `MSCK REPAIR TABLE` | `FAILED: ParseException line L:C missing EOF at '/' near 't'` |
| between the name and `ADD COLUMNS` | `FAILED: ParseException line L:C cannot recognize input near '/' '*' 'c' in alter table statement` |
| after `DESCRIBE EXTENDED` | `FAILED: ParseException line L:C cannot recognize input near '/' '*' 'c' in specifying describe table types` |

The keywords in the message are spelled as written (`near 'show'` for
`show /* c */ create table t`). `'c'` stands for the first token inside the
comment (`abc` for `/* abc */`, `1.5` for `/* 1.5 */`, `'x'` for `/* 'x' */`,
`a` for `/* a.b */`, `*` for `/**/`, `<=` for `/* <= */`, `!=` for `/* != */`,
`|` for `/* || */`, and `a` for `/* 'a */` when no later quote closes the
string; other two-character operators are not measured and read as one
character). `L:C` is the line (from 1) and column
(from 0) of the `/`, counted after every run of two or more whitespace
characters (newlines included) is squeezed into one space: `SHOW\n/* c */` is
`2:0`, but `SHOW\n\n/* c */` and `SHOW  /* c */` are both `1:5`.

Four `ALTER TABLE` actions differ: with `DROP COLUMN`, `RENAME TO`,
`REPLACE COLUMNS` and `CHANGE COLUMN` the failure is `ErrorCategory` 2 /
`ErrorType` 1006, and `AthenaError.ErrorMessage` is not the reason —
`line 1:N: mismatched input 'COLUMN' expecting 'PARTITION'` for `DROP COLUMN`
(`N` counts the comment) and `Query type not supported by DDL engine.` for the
other three. When a Hive table's `DROP COLUMN` is written
`ALTER /* c */ TABLE awsdatacatalog.<database>.<table>`, the message is
`line 1:T: no viable alternative at input 'ALTER /* c */ TABLE awsdatacatalog.<database>.'`
instead (`T` is the column of the table name, counted in the statement as
received), and `GetQueryExecution` returns the `Query` as received, keeping
`awsdatacatalog.` (measured 2026-09-27; without the comment it is dropped, see
[Parameters and catalog aliases](#parameters-and-catalog-aliases)). Other
statements with both a comment and `awsdatacatalog.` were not measured and drop
it as without the comment. `MSCK REPAIR TABLE` on an Iceberg table, with or without a comment, fails with
`Query type not supported by Athena Iceberg at this time` (`ErrorCategory` 2 /
`ErrorType` 1200) and writes no `<id>.txt`.

## `ALTER TABLE` and format-dependent DDL

- **Six `ALTER TABLE` spellings Athena has and Trino does not.** These are
  Athena syntax, not Trino's; Trino's own syntax check rejects them with
  `SYNTAX_ERROR` (returned as `InvalidRequestException` / `AthenaErrorCode`
  `MALFORMED_QUERY`, with no `QueryExecutionId` created) where Athena would
  have run them. Checked against Trino 482 on 2026-09-21:

  | Statement | Trino's syntax check | Trino's own spelling |
  | --- | --- | --- |
  | `ADD COLUMNS (...)` | `mismatched input 'COLUMNS'` | `ADD COLUMN` (singular) |
  | `SET TBLPROPERTIES (...)` | `mismatched input 'TBLPROPERTIES'` | `SET PROPERTIES` |
  | `REPLACE COLUMNS (...)` | `mismatched input 'REPLACE'` | none |
  | `ADD PARTITION (...)` | `mismatched input 'PARTITION'` | none |
  | `DROP PARTITION (...)` | `mismatched input 'PARTITION'` | none |
  | `SET LOCATION '...'` | `mismatched input 'LOCATION'` | none |

  The four rows with no Trino spelling cannot be run through athena-local at
  all — their `SubstatementType` and result-file rows below record what
  Athena does, and are reachable here only if the backend's grammar accepts
  the statement. The two Trino spellings in the last column are rejected at
  `StartQueryExecution` the same as real Athena (see the next item), so the
  `ADD COLUMNS` row under
  [DDL that depends on the target table's format](ddl.md#ddl-that-depends-on-the-target-tables-format)
  cannot be reached through athena-local either: no spelling of that
  statement is accepted by both engines.
- **Unquoted `ALTER TABLE IF EXISTS ...`, and six other Trino-only `ALTER
  TABLE` spellings, are rejected at `StartQueryExecution`.** Real
  Athena's grammar has no `IF EXISTS` clause on `ALTER TABLE` at all, and no
  `RENAME COLUMN`, `SET PROPERTIES` (also covered by the item above),
  `SET AUTHORIZATION`, `EXECUTE`, `ALTER COLUMN` or `DROP COLUMN IF EXISTS`
  either — these are all Trino syntax, not Athena's. athena-local rejects
  every one of them the same way real Athena does, with Athena's own message
  (measured 2026-09-26), regardless of whether the table name is quoted or
  how many parts it has:

  | Form | Message |
  | --- | --- |
  | `ALTER TABLE IF EXISTS t <ADD\|DROP\|RENAME> ...` | `no viable alternative at input 'ALTER TABLE IF EXISTS'` |
  | `ALTER TABLE IF EXISTS t ALTER COLUMN ...` | `mismatched input 'ALTER'. Expecting: '.', 'ADD', 'DROP', 'RENAME'` |
  | `ALTER TABLE t ADD COLUMN ...` | `no viable alternative at input 'ALTER TABLE t ADD COLUMN'` |
  | `ALTER TABLE t RENAME COLUMN a TO b` | `missing 'TO' at 'COLUMN'` |
  | `ALTER TABLE t SET PROPERTIES ...` | `no viable alternative at input 'ALTER TABLE t SET PROPERTIES'` |
  | `ALTER TABLE t SET AUTHORIZATION ...` | `no viable alternative at input 'ALTER TABLE t SET AUTHORIZATION'` |
  | `ALTER TABLE t EXECUTE ...` | `no viable alternative at input 'ALTER TABLE t EXECUTE'` |
  | `ALTER TABLE t ALTER COLUMN ...` | `mismatched input 'ALTER'. Expecting: '.', 'ADD', 'DROP', 'EXECUTE', 'RENAME', 'SET'` |
  | `ALTER TABLE t DROP COLUMN IF EXISTS m` | `mismatched input 'EXISTS' expecting {<EOF>, '.'}` |

  All answer `InvalidRequestException` / `AthenaErrorCode` `MALFORMED_QUERY`
  with no `QueryExecutionId` created, Trino is never sent anything but the
  syntax check, and the position is counted the same way as the quoted-name
  check above (UTF-16 units from the first non-whitespace character, a
  leading comment included). The `Expecting:` list after `IF EXISTS`
  (four entries) is shorter than the one without it (six entries), because
  real Athena's grammar allows fewer follow-on keywords once `IF EXISTS` is
  present. A plain `ALTER TABLE t DROP COLUMN m` (no `IF EXISTS`) is **not**
  rejected — real Athena accepts it too and only fails at run time (measured
  2026-09-26), so athena-local starts it too, and fails it or sends it to
  Trino unchanged depending on the table (see below). Athena's own
  spellings (`ADD COLUMNS`, `SET TBLPROPERTIES`, and so on) are rejected by
  Trino's syntax check instead (the item above).
- **`ALTER TABLE` classification covers nine forms.** `SET TBLPROPERTIES`,
  `ADD COLUMNS`, `DROP COLUMN`, `SET LOCATION`, `REPLACE COLUMNS`,
  `ADD PARTITION`, `DROP PARTITION`, `RENAME TO` and `CHANGE COLUMN` each get
  the `SubstatementType` Athena returns (measured 2026-09-21; `CHANGE COLUMN`,
  `ALTER_TABLE_CHANGE_COLUMN`, 2026-09-27). Note that
  `ALTER_TABLE_REPLACE_COLUMN` is singular although the statement is plural;
  the singular statement `REPLACE COLUMN` is a syntax error on Athena
  (`mismatched input 'REPLACE'`, `MALFORMED_QUERY`, measured 2026-09-24) and is
  left unclassified here.
  Athena returns the `SubstatementType` even when the statement then fails at
  run time, so athena-local classifies these forms regardless of the target's
  format. Any other `ALTER TABLE` form is left unclassified, the same as any
  other statement whose `SubstatementType` was not measured (see
  [Supported API](api.md#supported-api)). Only two of the nine can actually be run
  through athena-local — `DROP COLUMN` and `RENAME TO`, on an Iceberg table
  (see below for the other tables). The other seven are
  rejected at the syntax check or at `StartQueryExecution` (the items above),
  so their classification is what athena-local would answer if the backend's
  grammar accepted the statement — except that `ADD COLUMNS`,
  `REPLACE COLUMNS` and `CHANGE COLUMN` with a block comment where Athena's
  Hive parser rejects it are started and failed with their classification (see
  [Block comments Athena's Hive parser rejects](#block-comments-athenas-hive-parser-rejects)).
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
  limitation of athena-local. athena-local reproduces two of them without
  sending the statement to Trino: `DROP COLUMN` on a Hive table or a missing
  table fails with Athena's `ParseException` (`mismatched input 'COLUMN'
  expecting PARTITION`), and `RENAME TO` fails with `Table cannot be renamed`
  on a Hive table (with a freshly generated `Request ID`) or with
  `SemanticException [Error 10001]: Table not found <database>.<table>` on a
  missing table. Both are `ErrorCategory` 2, `ErrorType` 1006, write the reason
  to `<id>.txt` and no `.metadata`, and `RENAME TO` reports `ErrorMessage`
  `Query type not supported by DDL engine.`. Views, tables whose Trino
  connector is neither `hive` nor `iceberg`, statements containing a
  comment other than the ones in
  [Block comments Athena's Hive parser rejects](#block-comments-athenas-hive-parser-rejects),
  and the other combinations above are still sent to Trino (not measured, or
  not reproduced).
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
  ordinary column-less DDL (empty file, no `.metadata`), or for
  `SHOW CREATE TABLE` and `DESCRIBE` the Hive table's files and no
  `UpdateCount`. See
  [DDL that depends on the target table's format](ddl.md#ddl-that-depends-on-the-target-tables-format)
  for what this changes.

## Plain `CREATE TABLE`

- **A CTAS-less, unquoted `CREATE TABLE` whose column list Trino's grammar
  accepts is rejected at `StartQueryExecution`, with real Athena's own
  message** (measured 2026-09-26), regardless of the table name's part count
  (one to three parts) or whether `IF NOT EXISTS` is present:

  | Form | Message |
  | --- | --- |
  | `CREATE TABLE t (n <type>)`, any single-word type name, existing or not (`int`, `varchar(10)`, `decimal(10,2)`, `array<int>`, `foo`, …), any number of columns | `No location was specified for table. An S3 location must be specified` |
  | `CREATE TABLE t (n <type>) WITH (...)` | `no viable alternative at input '...WITH ('` |
  | `CREATE TABLE t (n int NOT NULL)` | `no viable alternative at input '...NOT'` |
  | `CREATE TABLE t (n <type> <word> ...)` (a Trino-only trailing word right after the type, such as `timestamp(3) with time zone`, `double precision`, `interval day to second`) | `no viable alternative at input '...<word>'` |
  | `CREATE TABLE t (n row(a int))`, `array(row(...))`, `map(varchar, ...)` (any type name followed by `(` whose first token is an identifier) | `no viable alternative at input '...<first word inside the parens>'` |
  | `CREATE TABLE t (LIKE u)` (one-part name) | `No location was specified for table. An S3 location must be specified` |
  | `CREATE TABLE t (LIKE db.u)` (two or more parts, with or without `INCLUDING PROPERTIES`) | `no viable alternative at input '...db.'` |
  | `CREATE TABLE t ("n" int)`, `(n int, "m" int)`, `(n "int")`, `(n row("f" int))` (a double-quoted column name, type name, or first word inside a type's parens — Hive reads `"n"` as a string) | `no viable alternative at input '..."n"'` (measured 2026-09-26) |

  All answer `InvalidRequestException` / `AthenaErrorCode` `MALFORMED_QUERY`
  with no `QueryExecutionId` created, Trino is never sent anything but the
  syntax check, and the position is counted the same way as the quoted-name
  and `ALTER TABLE` checks above. athena-local reads the column list the way
  real Athena's Hive-style grammar does — a column name, a type name (any
  identifier; type names are not distinguished from one another), then either
  a further `(...)` or `<...>` on the type, `COMMENT '...'`, a comma or the
  closing `)` — without validating that the type actually exists. `LIKE` has
  no special handling: it is read as an ordinary column name, so
  `(LIKE u)` is read as a column named `LIKE` of type `u` (giving `No location`)
  and `(LIKE db.u)` hits the `.` that follows the "type" `db` (giving the
  `no viable alternative` message above, at that `.`). A trailing
  `COMMENT '...'` after the column list, on the table itself, is skipped
  either way.
- **With an S3 Tables context catalog, a plain `CREATE TABLE` runs.** When
  `QueryExecutionContext.Catalog` is `s3tablescatalog/<bucket>` (compared
  case-insensitively), real Athena creates the table without a location, so
  athena-local does not answer `No location` and sends it to Trino; the
  `no viable alternative` rows above still apply (`NOT NULL`, `WITH (`, …),
  as they did on real Athena (measured 2026-09-26). Under that context an
  unquoted three-part name whose first part is exactly `awsdatacatalog`
  (lower case) is rejected, as on real Athena, with
  `Unsupported ddl with 2 catalogs: <the statement>` (`ddl` in lower case;
  the statement follows with its leading and trailing whitespace removed,
  comments and line breaks kept), unless a `no viable alternative` row above
  applies first ([#224](https://github.com/aoyagikouhei/athena-local/issues/224),
  measured 2026-09-26). With any other spelling of `awsdatacatalog` as the
  first part (`AwsDataCatalog`, `AWSDATACATALOG`), real Athena ignores the
  first part and creates the table in the S3 Tables namespace named by the
  second part; when that namespace does not exist in the context catalog,
  athena-local starts the query and fails it without sending it to Trino, as
  real Athena does (`Cannot find or access the specified table`,
  `ErrorCategory` 2, `ErrorType` 1100, no result file and no `.metadata`).
  When the namespace exists, athena-local creates the table there, as real
  Athena does: it sends Trino the statement with the first part and its `.`
  replaced by spaces (line breaks kept, so Trino's error positions still match
  the statement you sent). It does the same when
  it cannot tell whether the namespace exists
  ([#227](https://github.com/aoyagikouhei/athena-local/issues/227),
  [#237](https://github.com/aoyagikouhei/athena-local/issues/237), measured
  2026-09-26, and with `IF NOT EXISTS` on 2026-09-27). Whether such a
  statement succeeds or fails, `GetQueryExecution` returns `Query` without
  the first part and its `.` (comments kept), and the context `Database` as
  the namespace written in the statement, as real Athena does
  ([#271](https://github.com/aoyagikouhei/athena-local/issues/271), measured
  2026-09-26 and 2026-09-27; not measured: the `Database` spelling when the
  namespace is written with upper-case letters). An unquoted two-part
  `<namespace>.<table>` whose namespace does not exist in the context catalog
  fails the same way, without being sent to Trino
  ([#231](https://github.com/aoyagikouhei/athena-local/issues/231), measured
  2026-09-26), and so does an unquoted one-part `<table>` when the context
  database does not exist as a namespace in the context catalog
  ([#251](https://github.com/aoyagikouhei/athena-local/issues/251), measured
  2026-09-27). With no context database, real Athena looks for the namespace
  `default` and fails the same way when it does not exist; athena-local asks
  Trino for `default` and does the same
  ([#273](https://github.com/aoyagikouhei/athena-local/issues/273), measured
  2026-09-27). When `default` exists the one-part name is sent as written;
  what real Athena does then has not been measured. Two differences under
  this context catalog are out of scope and stay: a CTAS whose namespace is
  written in backquotes (`` CREATE TABLE `ns`.t AS SELECT ... ``, measured only
  with a namespace that does not exist) is rejected at start by real Athena
  with `Creation of tables using select query uses a different syntax`
  (`MALFORMED_QUERY`), while athena-local sends it to Trino
  ([#293](https://github.com/aoyagikouhei/athena-local/issues/293)); and when
  the query of a CTAS names a table that does not exist, real Athena's
  `TABLE_NOT_FOUND` reason spells the table with its internal name
  (`"awsdatacatalog$iceberg-aws"."catalog:<account>:s3tablescatalog/<bucket>$schema:<ns>".<table>`),
  while athena-local keeps Trino's spelling (`iceberg.<ns>.<table>`)
  ([#294](https://github.com/aoyagikouhei/athena-local/issues/294)).
- **With an S3 Tables context catalog, Hive's `LOCATION` and `EXTERNAL` are
  rejected with real Athena's messages.** Trino's grammar has neither; under
  any other context catalog, see the next entries. When
  `QueryExecutionContext.Catalog` is `s3tablescatalog/<bucket>`, real Athena
  reads the statement as Hive DDL first, and athena-local does the same for the
  forms that were measured, before the syntax check
  ([#229](https://github.com/aoyagikouhei/athena-local/issues/229), measured
  2026-09-26; [#248](https://github.com/aoyagikouhei/athena-local/issues/248),
  measured 2026-09-27):

  | Form | Message |
  | --- | --- |
  | `CREATE [EXTERNAL] TABLE [IF NOT EXISTS] <name> [(<columns>)] [COMMENT '<c>'] [PARTITIONED BY (<columns>)] [CLUSTERED BY (<column>, ...) INTO <n> BUCKETS] [ROW FORMAT SERDE '<class>' \| ROW FORMAT DELIMITED <terminators>] [STORED AS <format>] LOCATION '<path>' [TBLPROPERTIES ('<k>'='<v>', ...)]` | `Table location can not be specified for tables hosted in S3 table buckets` |
  | `CREATE EXTERNAL TABLE [IF NOT EXISTS] <name> [(<columns>)] [<the clauses above, before STORED AS>] [STORED AS <format>] [TBLPROPERTIES ('<k>'='<v>', ...)]` (no `LOCATION`) | `External keyword not supported for table type ICEBERG` |

  Both answer `InvalidRequestException` / `AthenaErrorCode` `MALFORMED_QUERY`
  with no `QueryExecutionId` created, and nothing is sent to Trino. `<name>`
  is an unquoted one- or two-part name, or a three-part one whose first part
  is `awsdatacatalog` in any case; it may also be a one-part name in
  backquotes. The columns are read as in the table above, and
  `<terminators>` is one or more of `FIELDS TERMINATED BY`, `COLLECTION ITEMS
  TERMINATED BY`, `MAP KEYS TERMINATED BY`, `LINES TERMINATED BY` and `NULL
  DEFINED AS`, in that order. The clauses must come in the order shown.
  Real Athena answered Trino's own syntax error (`mismatched input
  'LOCATION'`), which athena-local still returns from its syntax check, when
  the statement is not valid Hive DDL: a double-quoted or four-part name,
  `NOT NULL` or a double-quoted column name, a nested `row(...)` column type,
  anything after the `LOCATION` path, an unquoted or missing path, or
  `TBLPROPERTIES` before `LOCATION`.
  Without `LOCATION` and without `EXTERNAL`, on a one- or two-part name, a
  one-part name in backquotes or a three-part one whose first part is
  `awsdatacatalog` in a case other than all lower case, these forms are
  accepted and fail like real Athena, without being sent to Trino and without
  result files (`ErrorCategory` 2, with or without `IF NOT EXISTS` or
  `COMMENT`, and before the check that the namespace exists; measured
  2026-09-26 and 2026-09-27,
  [#266](https://github.com/aoyagikouhei/athena-local/issues/266),
  [#270](https://github.com/aoyagikouhei/athena-local/issues/270)):

  | Form | Reason | `ErrorType` |
  |---|---|---|
  | `CLUSTERED BY (<columns>) INTO <n> BUCKETS` | `Iceberg create table statement does not allow CLUSTERED BY` | 1200 |
  | `ROW FORMAT SERDE '<class>'` or `ROW FORMAT DELIMITED ...` | `Iceberg create table statement does not allow ROW FORMAT` | 1200 |
  | `STORED AS <format>` | `Iceberg create table statement does not allow STORED AS/BY` | 1200 |
  | `PARTITIONED BY (<column> <type>, ...)` (Hive's typed form) | `Invalid PARTITIONED BY clause in Iceberg create table statement` | 1006 |
  | no column list | `At least one column is required for Iceberg create table statement` | 1006 |
  | a `TBLPROPERTIES` key outside the list below | `Unsupported table property key: <the first such key as written>` | 1200 |

  With more than one of them, the reason is the first row of the table that
  applies, as on real Athena. `TBLPROPERTIES` keys that are not reported
  (in any case): `table_type`, `format`, `write_compression`,
  `vacuum_max_snapshot_age_seconds`, `vacuum_min_snapshots_to_keep`,
  `optimize_rewrite_delete_file_threshold`,
  `write_target_data_file_size_bytes` and `compression_level` (measured), and
  `optimize_rewrite_data_file_threshold`, `vacuum_max_metadata_files_to_keep`
  and `write_data_path_enabled` (documented by AWS for Iceberg tables, not
  measured). These are rejected at start instead (`MALFORMED_QUERY`):
  `'table_type'` other than `ICEBERG` (any case), with `Only ICEBERG table
  format is supported with S3 table buckets`, whatever else the statement
  has; `compression_level` without `write_compression`, with `Compression
  codec must be defined when compression_level property is specified.`; and
  on an all-lower-case `awsdatacatalog.<database>.<table>`, any of the forms
  in the table above, with `Unsupported ddl with 2 catalogs: <the statement>`.
  The forms real Athena accepts (Iceberg's `PARTITIONED BY (<column>)` and
  `PARTITIONED BY (bucket(4, <column>))`, `TBLPROPERTIES` with the keys
  above) do not parse on Trino and still get Trino's syntax error; write them
  with Trino's `WITH (...)` instead. `compression_level` together with
  another failing form was not measured; athena-local rejects it at start the
  same way. Not measured, and still Trino's syntax error: a three-part name
  in another catalog, and Hive clauses not listed above (`WITH
  SERDEPROPERTIES`, `ESCAPED BY`, `SORTED BY`, `STORED AS INPUTFORMAT ...
  OUTPUTFORMAT`, ...).
- **A three-part name whose catalog does not exist is rejected with
  `DATACATALOG_NOT_FOUND` also with `LOCATION`.** Under any context catalog,
  `CREATE [EXTERNAL] TABLE [IF NOT EXISTS] <catalog>.<database>.<table> ...
  LOCATION '<path>'` whose unquoted first part is not `awsdatacatalog` answers
  `Catalog '<the first part as written>' does not exist` when Trino has no
  such catalog, before the syntax check, whatever clauses the statement has
  ([#248](https://github.com/aoyagikouhei/athena-local/issues/248),
  [#266](https://github.com/aoyagikouhei/athena-local/issues/266), measured
  2026-09-27). With a catalog Trino does have (including a
  `TRINO_CATALOG_MAP` alias), the next entry applies.
- **Outside an S3 Tables context catalog, Hive's `LOCATION` is rejected with
  real Athena's messages.** Real Athena reads `CREATE [EXTERNAL] TABLE ...
  LOCATION '<path>'` as Hive DDL first, and athena-local does the same, before
  the syntax check, for an unquoted one- to three-part name with the clauses
  read in the first table of the S3 Tables entry above (same clauses and
  order), answering `InvalidRequestException` /
  `MALFORMED_QUERY` with nothing sent to Trino
  ([#278](https://github.com/aoyagikouhei/athena-local/issues/278), measured
  2026-09-27):

  | Form | Message |
  | --- | --- |
  | no `EXTERNAL`, unless `TBLPROPERTIES` has `'table_type'='ICEBERG'` (key and value in any case), under any context catalog or none | `External keyword required for table type HIVE` |
  | `EXTERNAL`, or `'table_type'='ICEBERG'` without it, on `<catalog>.<database>.<table>` whose first part is not `awsdatacatalog` (in any case), with the context catalog `AwsDataCatalog` (in any case) | `Unsupported ddl with 2 catalogs: <the statement>` |
  | `EXTERNAL` on `awsdatacatalog.<database>.<table>` (all lower case), with another context catalog that is a `TRINO_CATALOG_MAP` key or that Trino has | `Unsupported ddl with 2 catalogs: <the statement>` |

  `<the statement>` is the statement without surrounding whitespace and the
  trailing `;`, comments kept. A first part Trino has no such catalog for is
  rejected with `DATACATALOG_NOT_FOUND` first (the entry above); when Trino
  cannot be asked, the catalog is taken as existing. Everything else still
  gets Trino's syntax error: the statements real Athena accepts (`EXTERNAL`
  on a one- or two-part name or on `AwsDataCatalog` / `awsdatacatalog` under
  the default context catalog, `EXTERNAL` on another catalog with no
  `Catalog` in the context, `'table_type'='ICEBERG'` without `EXTERNAL`),
  which athena-local cannot run on Trino, and the statements real Athena also
  answers with Trino's syntax error (a double-quoted name, `NOT NULL`), where
  the `Expecting:` list after `mismatched input 'EXTERNAL'` differs from real
  Athena's. A name in backquotes or with four parts or more was not measured
  here and is left to the syntax check. Not handled either: `EXTERNAL` on `<catalog>.<table>`, which real
  Athena starts and fails because it reads the catalog as a database, and
  `'table_type'='ICEBERG'` with `STORED AS`, which real Athena starts and
  fails with `Iceberg create table statement does not allow STORED AS/BY`,
  and `EXTERNAL` on a three-part name without `LOCATION`, which real Athena
  rejects at start with `No location was specified for table` (all three
  measured 2026-09-27 and out of scope,
  [#301](https://github.com/aoyagikouhei/athena-local/issues/301)).
  Under a context catalog that does not exist, or with the Iceberg
  `table_type` under a context catalog other than `AwsDataCatalog`, real
  Athena was not measured and athena-local does not reject.
- **A three-part name whose catalog does not exist is rejected with
  `DATACATALOG_NOT_FOUND`.** For an unquoted three-part name that would
  otherwise answer `No location`, under any context catalog, real Athena
  answers `InvalidRequestException` (`AthenaErrorCode`
  `DATACATALOG_NOT_FOUND`), `Catalog '<the first part as written>' does not
  exist`; a `no viable alternative` row above still applies first (measured
  2026-09-26). athena-local treats `awsdatacatalog` (in any case) as existing
  and asks Trino about any other first part, after mapping it through
  `TRINO_CATALOG_MAP` (keys compared case-insensitively), the same way
  `DESCRIBE` does. A catalog Trino has but real Athena would not know (a
  Trino-only catalog, or a federated catalog) was not measured; athena-local
  treats it as existing and answers `No location`
  ([#227](https://github.com/aoyagikouhei/athena-local/issues/227)).
- **Forms not listed above still run on Trino unchanged.** A table name with
  four parts or more and a table name with a quoted part are not rejected
  here — the quoted-name check above rejects them first where it was
  measured. A backquoted column name (`` CREATE TABLE t (`n` int) ``) answers
  `No location` on real Athena (measured 2026-09-26), but Trino's syntax check
  rejects backquotes first here (see the backquote item above).

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
  `"S3TablesCatalog/my-bucket".db.users` (different case) are sent as written,
  except where real Athena itself drops an unquoted `awsdatacatalog.` from
  `DESCRIBE`, `SHOW COLUMNS`, `SHOW CREATE TABLE`, `SHOW TABLES IN`,
  `ALTER TABLE` and `DROP TABLE` (see [Supported API](api.md)), where
  real Athena reads the first part of a CTAS under an S3 Tables context
  catalog as `AwsDataCatalog` (next item), and where real Athena was measured
  to read an unquoted first part `awsdatacatalog` (in any case) as
  `AwsDataCatalog`. There the name gets the Trino catalog of the
  `AwsDataCatalog` alias (keys compared case-insensitively), double-quoted and
  padded with spaces as above, while `Query` stays as sent:
  - under an `AwsDataCatalog` or omitted context catalog, an unquoted
    three-part name (`SELECT * FROM AwsDataCatalog.db.t`) in any statement.
    Real Athena ran such names in `SELECT`, `INSERT`, CTAS, `CREATE VIEW` and
    `EXPLAIN` (measured 2026-09-26); other statements (`DELETE`, `DROP VIEW`,
    the target of `RENAME TO`) have not been measured. In `SELECT` also a
    three-part name with exactly one quoted part (`awsdatacatalog."db".t`,
    `awsdatacatalog.db."t"`) and an unquoted four-part column reference
    (`SELECT awsdatacatalog.db.t.n FROM awsdatacatalog.db.t`), measured
    2026-09-27;
  - under an S3 Tables context catalog, or a context catalog that is neither
    an alias key nor a Trino catalog, an unquoted three-part name in `SELECT`
    and `INSERT` (measured 2026-09-25 and 2026-09-27). The context catalog is
    still sent to Trino as written, since Trino resolves fully qualified names
    without it; whether the catalog exists is asked of Trino only when the SQL
    has such a name.

  Other forms (two quoted parts, a quoted part in a four-part name or in
  `INSERT`, other statements under those context catalogs), a context catalog
  that is an alias key or a Trino catalog (a federated catalog on real Athena,
  not measured), and other unquoted aliases are sent as written; they have not
  been measured and are out of scope
  ([#279](https://github.com/aoyagikouhei/athena-local/issues/279)).
  Real Athena resolves `QueryExecutionContext.Catalog` and `Database`
  case-insensitively (`SHOW TABLES` under `AWSDATACATALOG` and under an
  upper-cased database name both listed the tables, measured 2026-09-24);
  whether it does the same for the catalog of a qualified name in SQL has not
  been measured.
  A name Trino can have, such as `AwsDataCatalog`, needs no alias at all: call
  the Trino catalog `awsdatacatalog` and qualified names resolve, quoted or not,
  since Trino lowercases identifiers. Error messages name the Trino catalog
  (`iceberg.db.users`), and when the Trino name is longer than the Athena name,
  error positions after it shift.
- **A CTAS into `awsdatacatalog.<database>.<table>` fails like Athena when
  the database does not exist.** When `QueryExecutionContext.Catalog` is
  `s3tablescatalog/<bucket>`, real Athena creates
  `CREATE TABLE awsdatacatalog.<database>.<table> AS SELECT ...` in the Glue
  database, not in the S3 Tables namespace as it does for a plain
  `CREATE TABLE` (measured 2026-09-26). For an unquoted three-part CTAS name
  whose first part is `awsdatacatalog` in any case, with or without
  `IF NOT EXISTS`, athena-local asks Trino whether the database exists in the
  Trino catalog of the `AwsDataCatalog` alias (keys compared
  case-insensitively; `awsdatacatalog` when there is no alias). Under an S3
  Tables context catalog it then sends Trino the statement with the first part
  replaced by that catalog, double-quoted and padded with spaces as for quoted
  aliases above, while `Query` stays as sent; under an `AwsDataCatalog` or
  omitted context catalog the alias above already applies. When the database
  does not exist, real Athena starts the query and fails it with
  `Database <database> not found. Please check your query. You may need to
  manually clean the data at location '<output location>tables/<id>' before
  retrying. Athena will not delete data in your account.` (`ErrorCategory` 2,
  `ErrorType` 1301), with the database name in lower case, under both kinds
  of context catalog; athena-local fails it the same way without sending the
  statement to Trino (measured 2026-09-27 under an S3 Tables, an
  `AwsDataCatalog` and an omitted context catalog). Real Athena runs the
  query part on the engine before failing: if that query fails, the query
  fails with the engine's error instead, and otherwise it leaves a
  `tables/<id>.metadata` companion shaped like a successful CTAS's (the
  engine's query ID, `CREATE TABLE`, the number of rows written, 0 with
  `WITH NO DATA`, and a `rows bigint` column), plus a manifest and the data
  files. athena-local does the same by sending Trino the query part after
  `AS` (without a trailing `WITH [NO] DATA`) as written, with the context
  catalog, database and `ExecutionParameters` of the statement, and writing
  the companion from that query's ID and row count; it writes no manifest and
  no data files. A failing query part gets the same sentence and position as
  any CTAS that fails on the engine (see [Failed queries](#failed-queries)).
  Without an output location (results not
  written and no `OutputLocation`), or when Trino cannot tell whether the
  database exists, the statement is sent instead
  ([#232](https://github.com/aoyagikouhei/athena-local/issues/232),
  [#251](https://github.com/aoyagikouhei/athena-local/issues/251)).
- **A CTAS into a missing S3 Tables namespace fails like Athena, with a
  placeholder account ID.** Under an S3 Tables context catalog, a CTAS whose
  target namespace does not exist (the context `Database` for a one-part
  name, the first part of a two-part name) starts and fails on real Athena
  with `NOT_FOUND: Schema catalog:<account ID>:<context catalog>$schema:<namespace>
  not found.` followed by the sentence of any CTAS that fails on the engine
  (see [Failed queries](#failed-queries)), `ErrorCategory` 2, `ErrorType`
  1300, the namespace in lower case, and no result file and no `.metadata`.
  This held with `IF NOT EXISTS`, `WITH NO DATA`, `WITH (...)` table
  properties, a double-quoted namespace and a query part that would fail at
  run time; a query part naming a missing table failed with that table's
  `TABLE_NOT_FOUND` instead (measured 2026-09-27,
  [#273](https://github.com/aoyagikouhei/athena-local/issues/273)).
  athena-local sends the statement to Trino, which checks in the same order,
  and turns Trino's `Schema <namespace> not found` for the target into real
  Athena's reason with the account ID `000000000000` and the context catalog
  as sent. With no context database, real Athena looked for the namespace
  `default`: a one-part CTAS then fails the same way, without being sent to
  Trino, when `default` does not exist, and is sent as written when it
  exists (not measured on real Athena). The `TABLE_NOT_FOUND` message keeps
  Trino's table name, where real Athena names the table by its internal
  Iceberg catalog and namespace.

## Value rendering

- **`varbinary` inside `array` / `map` / `row`.** Top-level `varbinary` values
  are converted from Trino's base64 to Athena's `01 02` form (measured). Inside
  a composite value real Athena instead prints the Java `byte[]` object,
  `[B@2545d692` (`[B@` plus 1 to 8 hex digits; measured 2026-09-24 with
  `ARRAY[X'0102', X'03']`, a `map` and a `row`). The digits do not encode the
  bytes: the two elements measured got unrelated values. Whether two equal byte
  strings get the same digits on Athena, and whether the digits change between
  runs, has not been measured. athena-local matches the shape and prints `[B@`
  plus a 32-bit FNV-1a hash of the bytes in hex, so equal byte strings always
  render the same here. Neither form can be parsed back into the bytes.
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
- **`SHOW` and `DESCRIBE` results differ from Athena's in a few unmeasured
  corners.** Their columns and rows follow Athena (see
  [Supported API](api.md#supported-api) and [Result files](result-files.md)),
  but athena-local builds them from Trino's results, so:
  - Only the type spellings measured on Athena are translated. Any other type
    keeps Trino's spelling, for example `timestamp(3) with time zone` or
    `interval day to second` (not measured).
  - On an Iceberg table, a `struct` with more than one field is written with
    `, ` between the fields, following Iceberg's `map<string, int>`; only a
    single-field `struct<a: int>` was measured.
  - A partition transform other than `identity`, `bucket`, `truncate`,
    `year`, `month`, `day` and `hour` gets no row under `# Partition spec:`.
  - On a view, `SubstatementType` becomes `DESC_VIEW` only when the query
    completes (see [Supported API](api.md#supported-api)).
  - `SHOW SCHEMAS LIKE '<pattern>'` returns Trino's matches; how Athena reads
    the pattern was not measured (on Athena, `LIKE '<prefix>*'` and
    `LIKE '<prefix>%'` with the prefix of an existing database both gave no
    rows, for `SHOW DATABASES` as well).
  The Athena-only `SHOW` statements Trino rejects are covered below.
- **`SHOW` metadata is not the opaque form Athena writes.** For `SHOW TABLES`,
  `SHOW DATABASES`, `SHOW COLUMNS`, `SHOW PARTITIONS`, `SHOW TBLPROPERTIES`,
  `SHOW CREATE VIEW`, `SHOW CREATE TABLE` and `DESCRIBE` on an Iceberg
  table, and `DESCRIBE` / `SHOW COLUMNS` on a view, real Athena writes a base64
  blob that does not decode as protobuf
  (measured 2026-09-16, 2026-09-17, 2026-09-18 and 2026-09-24). The blob is 312
  base64 characters for `SHOW TABLES`, `SHOW DATABASES`, `SHOW COLUMNS`,
  `SHOW PARTITIONS` and `SHOW CREATE VIEW`, 332 for `SHOW CREATE TABLE` on an
  Iceberg table, 440 or 460 for `SHOW TBLPROPERTIES`, 440 for `DESCRIBE` and
  `SHOW COLUMNS` on a view and 568 for `DESCRIBE` on an Iceberg table, decoding to a fixed size whatever the result holds. Only the leading byte
  `0x01` is stable: everything after it differs between measurement rounds and
  sometimes between two statements of the same round, and running the same
  `SHOW TABLES` twice over the same tables yields different bytes. That is
  consistent with an encrypted payload, but **what the format actually is has
  not been identified** and is not reproduced here. The result file itself is
  unaffected — it is the same plain text Athena writes for any other `SHOW`.
  `SHOW CREATE TABLE` and `DESCRIBE` on a Hive table are not affected: they
  write plain protobuf. athena-local writes the same plain protobuf it writes for every
  other statement, so a client that parses it sees the columns instead of
  failing. Athena JDBC 3.8.1 in its default `ResultFetcher=auto` fetches that
  companion file and reads it without an exception: verified for `SHOW TABLES`
  on 2026-09-17, and on 2026-09-22 for `SHOW SCHEMAS` (one column) and
  `SHOW COLUMNS` (Trino's four columns, 205 bytes, observed before
  `SHOW COLUMNS` was reduced to Athena's single column) in the same run, and on
  2026-09-25 for `SHOW CREATE VIEW` and `SHOW CREATE TABLE` on an Iceberg
  table, whose companion (led by Trino's query id) is written as
  `binary/octet-stream` like their `.txt`. The driver
  logs `loaded query result metadata` for each, then still presents the `.txt`
  body as a single `varchar` column named `_col0`, one row per line; with
  `ResultFetcher=S3` it does not fetch the `.txt.metadata` at all, and with
  `ResultFetcher=GetQueryResults` it never touches S3. The other four
  statements cannot reach the file: `SHOW DATABASES`, `SHOW VIEWS`,
  `SHOW PARTITIONS` and `SHOW TBLPROPERTIES` are Athena syntax that Trino's
  grammar lacks, so the syntax check rejects them (`mismatched input
  'DATABASES'` and so on, returned as `InvalidRequestException` before any
  file is written; Trino 482, 2026-09-22 and 2026-09-24, whose expected-token
  list after `SHOW` has no `VIEWS`, `PARTITIONS` or `TBLPROPERTIES`). Write
  `SHOW SCHEMAS` for `SHOW DATABASES` (classified as
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

- **An engine failure of a CTAS or `INSERT` names the result location, and a
  CTAS reports the position in Athena's reformatted statement.** Real Athena
  appends ` You may need to manually clean the data at location '<output
  location>tables/<id>' before retrying. Athena will not delete data in your
  account.` to the reason of a CTAS that fails on the engine, and ` If a data
  manifest file was generated at '<output location><id>-manifest.csv', you may
  need to manually clean the data from locations specified in the manifest.
  Athena will not delete data in your account.` to that of an `INSERT`, after
  a `.` when the engine's message does not end with one (measured 2026-09-25
  and 2026-09-27, [#272](https://github.com/aoyagikouhei/athena-local/issues/272));
  athena-local does the same, for both `StateChangeReason` and
  `AthenaError.ErrorMessage`. Real Athena also reformats a CTAS before running
  it, and the `line N:M` of an analysis error counts in the reformatted text:
  `CREATE TABLE db.t AS SELECT * FROM db.missing` answers `line 6:3`, one line
  more for each `WITH (...)` table property. athena-local moves the position
  to the same place, without changing the statement it sends to Trino, for
  the forms that were measured: under an `AwsDataCatalog` or omitted context
  catalog (or into `awsdatacatalog.<database>.<table>` under an S3 Tables
  context catalog), a `SELECT` of `*`, columns, literals or one binary
  operator, one table in `FROM`, one comparison in `WHERE`, the query in
  parentheses or behind one `WITH` query, with or without `WITH (...)` table
  properties and a trailing `WITH [NO] DATA`. Other forms (joins, `GROUP BY`,
  `ORDER BY`, function calls, ...), a statement with `ExecutionParameters` or
  with non-ASCII characters, and a CTAS into an S3 Tables namespace (where real
  Athena kept the position as sent) keep Trino's position. Real Athena's own
  wording can differ from Trino's (`Column 'x' cannot be resolved or requester
  is not authorized to access requested resources`); athena-local keeps
  Trino's wording (out of scope,
  [#283](https://github.com/aoyagikouhei/athena-local/issues/283)).
- **A failed query writes a result file for more statements than Athena.** On
  Athena it depends on the engine behind the statement: DDL that runs through
  Hive writes `<id>.txt` holding the reason (`SHOW TABLES`, `DROP TABLE` and
  `CREATE DATABASE`, measured 2026-09-17), while statements that run on the
  query engine write no file at all, namely `SELECT`, `INSERT`, `UPDATE`,
  `DELETE` and CTAS (measured 2026-09-17; a CTAS into a missing
  `awsdatacatalog` database is the exception, see
  [Parameters and catalog aliases](#parameters-and-catalog-aliases); and the `INSERT` case again on
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
- **`SHOW COLUMNS` and `DESCRIBE` on a missing table fail in
  `StartQueryExecution`, as on Athena, only when athena-local can prove the
  table is missing.** Athena rejects them in `StartQueryExecution` with
  `InvalidRequestException` (`AthenaErrorCode` `INVALID_INPUT`, message
  `Entity Not Found`) and creates no execution at all (measured 2026-09-17).
  athena-local does the same for a table or schema it can prove is missing
  (see the existence check under [SQL dialect](#sql-dialect)); when that
  check cannot decide — a `TRINO_CATALOG_MAP` alias written as the catalog
  of the name, a default
  catalog that does not exist in Trino (and has no fallback, see
  [SQL dialect](#sql-dialect)), or a Trino error — it accepts the
  call, the query becomes `FAILED`, and it writes `<id>.txt` as described
  above.
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
  sending one shorter than 32 characters, longer than 128 characters or longer
  than 128 UTF-8 bytes, fails with `INVALID_INPUT` (see
  [Supported API](api.md#supported-api)). The lower bound is counted in
  characters and the upper bound in bytes, as real Athena does (measured
  2026-09-24: 20 `あ` was "too short" although it is 60 bytes, and 50 `あ` was
  rejected although it is 50 characters). Which of the two "too long" messages
  real Athena picks for a token that exceeds 128 both in characters and in
  bytes has not been measured; athena-local reports the character limit first.
  A token that passes validation is used verbatim as a map key: case, leading/trailing
  whitespace and non-ASCII characters are all significant. Real Athena does
  not normalize it either: leading/trailing spaces, an upper-cased copy, and a
  `"` or `\` in place of one character each started a new query (measured
  2026-09-24). `Catalog`, `Database` and `OutputLocation` are
  compared as sent, before `TRINO_CATALOG`, `TRINO_SCHEMA` or
  `ATHENA_LOCAL_OUTPUT_LOCATION` fills them in, so a retry that spells out the
  default a first call left out is `IDEMPOTENT_PARAMETER_MISMATCH`. Real Athena
  does the same for `Database` (omitted, then `default`: mismatch, measured
  2026-09-24). For `OutputLocation` it returned the same id when the retry
  spelled out the workgroup's output location, but that was measured only on a
  workgroup that enforces its configuration; a workgroup that does not (the
  shape athena-local presents) has not been measured, so athena-local keeps
  comparing the value as sent. Omitting `Catalog` and then spelling it out has
  not been measured either. `GetQueryExecution` returns `Catalog` lower-cased
  (`AwsDataCatalog`, `AWSDATACATALOG` and a non-existent mixed-case name all
  came back lower-cased, measured 2026-09-24) and `Database` as sent (an
  upper-cased database name stayed upper-cased); the lower-casing is display only, the
  idempotency check and the name sent to Trino use the value as received. A
  `Catalog` or `Database` the request left out is left out of the response too
  (measured 2026-09-24): `TRINO_CATALOG` and `TRINO_SCHEMA` are applied only
  when the query is sent to Trino, not echoed back. How
  real Athena displays an S3 Tables or federated catalog name has not been
  measured (the account had none). The token → id mapping is kept in memory until the
  execution it points at is dropped (`ATHENA_LOCAL_RETENTION_SECONDS`, one
  hour by default), which is shorter than real Athena's: a token resent about
  67 minutes after the query finished still returned the same id (measured
  2026-09-24), and how much longer the real lifetime is has not been measured.
  **Raw HTTP / curl clients must supply their own token** — the AWS CLI and
  SDKs add one automatically, but a request built by hand needs to set
  `ClientRequestToken` itself (measured).
- **Finished queries are dropped after a retention period.** A query that has
  reached `SUCCEEDED`, `FAILED` or `CANCELLED` is kept for
  `ATHENA_LOCAL_RETENTION_SECONDS` (one hour by default) and then dropped,
  together with the `ClientRequestToken` that points at it; queued and running
  queries are never dropped. **This is shorter than real Athena.** About 67
  minutes after a query finished, real Athena still answered
  `GetQueryExecution` with `SUCCEEDED`, accepted `StopQueryExecution` on it and
  returned the same id for the resent token (measured 2026-09-24); AWS
  documents query history as kept for 45 days. The exact lifetime has not been
  measured, and one hour is kept as the default because the memory used by
  finished queries is only bounded by this period (see below); raise
  `ATHENA_LOCAL_RETENTION_SECONDS` when a client needs to read a query back
  later than that. Once a
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
  `tools/e2e/retention/verify.sh`). Over an hour of back-to-back 0.1 MiB results
  (about 35,000 queries), the resident memory at a retention of 1 s stayed
  between 11 and 12 MiB throughout, while the same load at 3600 s reached
  3.1 GiB (measured 2026-09-25). Dropping a query
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
