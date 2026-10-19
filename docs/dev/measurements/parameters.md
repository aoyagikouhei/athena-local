# `ExecutionParameters`

`StartQueryExecution` の `ExecutionParameters` の値を本物の Athena がどう分類するか（式のまま当てるか、文字列リテラルにするか）の記録。利用者向けの章は [parameters.md](../../parameters.md)。

2026-09-14 の最初のラウンド（コミット 2218655。`'abc'`・`1 + 1`・`DATE '2020-01-01'`・`NULL`・`now()`・`abc def`・`it's`・`123e4567-e89b-12d3-a456-426614174000`・`abc`・`x + 1`・`t.x`・`nosuchfunc(1)`・`1 OR 1=1`）は生データを残していない。[parameters.md](../../parameters.md) の表の出典はそのラウンドで、このファイルの記録はその後に測り直したものだけ。

## 値の分類

### 式として読める値（全桁数字の UUID など）は式のまま当たる
- 日付: 2026-10-19 ／ issue: 無し（別リポジトリの Rails アプリの利用者からの報告） ／ スクリプト: 無し（ホストの `aws` で下のループを手で流した） ／ 生データ: 無し（GetQueryResults の出力をそのまま下に書いた）
- 相手: 本物の Athena（engine version 3、Catalog `AwsDataCatalog`、Database は実在するもの。workgroup は省略）
- 投げたもの: 値ごとに `SELECT ? AS v, typeof(?) AS t` に同じ値を 2 回渡した 9 本と、`WHERE` の 2 本。`U1` は `11111111-2222-3333-4444-555555555555`（全桁数字）、`U2` は `a1111111-2222-3333-4444-555555555555`（英字始まり）、`U3` は `12e45678-1234-4123-8123-123456789012`（各グループが数値として読める形）

  ```bash
  for v in "$U1" "$U2" "$U3" 123 "'quoted'" abc 1abc "1 + 1" NULL; do
    aws athena start-query-execution --query-string "SELECT ? AS v, typeof(?) AS t" \
      --query-execution-context "Database=$DB" --result-configuration "OutputLocation=$OUTPUT" \
      --execution-parameters "$v" "$v"
  done
  # where-in / where-eq
  aws athena start-query-execution --query-string "SELECT count(*) AS n FROM (VALUES ('$U1'), ('$U2')) AS t(u) WHERE u IN (?, ?)" ... --execution-parameters "$U1" "$U2"
  aws athena start-query-execution --query-string "SELECT count(*) AS n FROM (VALUES ('$U1')) AS t(u) WHERE u = ?" ... --execution-parameters "$U1"
  ```

- 返ったもの（`GetQueryResults` の `ColumnInfo[].Type` と 2 行目の値。1 行目は列名行 `v`・`t`）:

  | 値 | State | `v` の型 | `v` の値 | `typeof(?)` |
  |---|---|---|---|---|
  | `11111111-2222-3333-4444-555555555555` | SUCCEEDED | bigint | `-555544454443` | `bigint` |
  | `a1111111-2222-3333-4444-555555555555` | SUCCEEDED | varchar | そのままの文字列 | `varchar(36)` |
  | `12e45678-1234-4123-8123-123456789012` | SUCCEEDED | double | `Infinity` | `double` |
  | `123` | SUCCEEDED | integer | `123` | `integer` |
  | `'quoted'` | SUCCEEDED | varchar | `quoted` | `varchar(6)` |
  | `abc` | SUCCEEDED | varchar | `abc` | `varchar(3)` |
  | `1abc` | SUCCEEDED | varchar | `1abc` | `varchar(4)` |
  | `1 + 1` | SUCCEEDED | integer | `2` | `integer` |
  | `NULL` | SUCCEEDED | unknown | （セル無し） | `unknown` |

  `WHERE` の 2 本はどちらも FAILED（`AthenaError` は `ErrorCategory` 2・`ErrorType` 1002・`Retryable` false。`StateChangeReason` と `ErrorMessage` は同じ文）:

  | 文 | `StateChangeReason` |
  |---|---|
  | `... WHERE u IN (?, ?)` に `U1`・`U2` | `TYPE_MISMATCH: line 1:139: IN value and list items must be the same type or coercible to a common type. Cannot find common type between varchar(36) and bigint, all types (without duplicates): [varchar(36), bigint]` |
  | `... WHERE u = ?` に `U1` | `TYPE_MISMATCH: line 1:93: Cannot apply operator: varchar(36) = bigint` |

  FAILED のクエリへの `GetQueryResults` は `InvalidRequestException`（`Query did not finish successfully.Final query state: FAILED`、AthenaErrorCode `INVALID_QUERY_EXECUTION_STATE`）。
- 備考: 2026-09-14 のラウンドの規則（式として読めて列参照を含まなければ式のまま、そうでなければ文字列リテラル）と食い違いは無い。全桁数字の UUID は `11111111 - 2222 - ...` の引き算、`12e45678-...` は `12e45678 - 1234 - ...` の浮動小数の引き算として評価され、英字始まり・`abc`・`1abc`（数字始まりの識別子）は文字列になる。athena-local 0.6.0 は同じ 11 本で同じ型・値・State を返していた（利用者の報告。athena-local 自身の観測なので値は書かない）ので、実装は変えていない。報告の発端は Rails アプリの seed の固定 UUID（全桁数字）で、本物でも同じく FAILED になる。回避策は値を `'...'` で囲んで渡すこと（[parameters.md](../../parameters.md)）
