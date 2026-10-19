# `ExecutionParameters`

How athena-local classifies and binds the values of `ExecutionParameters`, following what real Athena does.

Real Athena does not bind parameter values verbatim. Measured against Athena
(2026-09-14), each value is classified:

| Value | Treated as | Example → result of `SELECT ? AS v` |
| --- | --- | --- |
| Parses as an expression without column references | the expression | `'abc'` → `abc`, `1 + 1` → `2`, `DATE '2020-01-01'`, `NULL`, `now()` |
| Does not parse | a string literal | `abc def`, `it's`, `123e4567-e89b-12d3-a456-426614174000` |
| Contains an identifier | a string literal | `abc`, `x + 1`, `t.x` (even if a column `x` exists) |
| Parses but fails analysis | the expression (the query fails) | `nosuchfunc(1)`, `1 OR 1=1` |
| Looks like text but parses as arithmetic | the expression | `11111111-2222-3333-4444-555555555555` → `-555544454443` (`bigint`), `12e45678-1234-4123-8123-123456789012` → `Infinity` (`double`) (measured 2026-10-19) |

athena-local reproduces this by asking Trino to run `SELECT (<value>)` for each
value: `SYNTAX_ERROR` or `COLUMN_NOT_FOUND` (or a result with more than one
column) makes it a quoted string literal, anything else is used as-is. The query
is then sent as `EXECUTE IMMEDIATE '<sql>' USING <values>` (Trino 418+), so `?`
inside string literals and comments is left alone. `GetQueryExecution` returns
the SQL as sent, apart from a `;` around the statement and the whitespace before
and after it, which are removed as on real Athena ([Supported API](api.md)), and
`StatementType` is derived from it.

A wrong number of values fails with `INVALID_PARAMETER_USAGE`, except that — like
Athena — values passed to SQL without any `?` are ignored.

Messages above were measured against Athena (2026-09-14; the two arithmetic
examples and `abc`, `1abc`, `123`, `'quoted'`, `1 + 1`, `NULL` again on 2026-10-19).

**Pass text values in single quotes.** A value such as a UUID is a string only
while it does not parse as an expression. A UUID made of digits only (fixed
test ids like `11111111-2222-...`) is bound as a `bigint` subtraction, and one
whose groups all read as numbers (`12e45678-...`) as a `double`, on real Athena
and here alike, so `WHERE id = ?` fails with `TYPE_MISMATCH`. Passing `'<uuid>'`
(single quotes, with any `'` inside doubled) is always a `varchar`.
