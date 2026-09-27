# #260 の docs の下書き（#257 のマージ後に rebase してから当てる）

## CHANGELOGS.md [Unreleased] / Changed（#246 の項目の直後）
- The `AwsDataCatalog` alias now also reaches an unquoted
  `awsdatacatalog.<database>.<table>` in `SELECT` and `INSERT` under an S3 Tables
  context catalog or one that does not exist in Trino, and, under an
  `AwsDataCatalog` or omitted context catalog, a `SELECT` name with one quoted
  part or a four-part column reference
  ([docs](docs/caveats.md#parameters-and-catalog-aliases)).

## docs/configuration.md:37-41（"not rewritten" の約束）
旧: ..., and, under an `AwsDataCatalog` or omitted context catalog, an unquoted
`awsdatacatalog.<database>.<table>` in any case, whose first part is replaced by
the same Trino catalog (see ...).
新: ..., and a qualified name whose first part is an unquoted `awsdatacatalog`
in any case, in the statements and context catalogs real Athena was measured
to run it in, whose first part is replaced by the same Trino catalog (see
[Caveats](caveats.md#parameters-and-catalog-aliases)).

## docs/caveats.md:542-551（Catalog aliases in SQL cover quoted names only）
旧: and where the context catalog is `AwsDataCatalog` or omitted: there an unquoted three-part name ... Other unquoted
  aliases, names with a quoted part or a part count other than three, and
  other context catalogs are sent as written; they have not been measured.
新（置き換え）:
  and where real Athena was measured to read an unquoted `awsdatacatalog` (in
  any case) as the first part of a name as `AwsDataCatalog`. There the name
  gets the Trino catalog of the `AwsDataCatalog` alias (keys compared
  case-insensitively), double-quoted and padded with spaces as above, while
  `Query` stays as sent:
  - under an `AwsDataCatalog` or omitted context catalog, an unquoted
    three-part name in any statement (real Athena ran `SELECT`, `INSERT`, CTAS,
    `CREATE VIEW` and `EXPLAIN`, measured 2026-09-26; other statements such as
    `DELETE`, `DROP VIEW` and the target of `RENAME TO` have not been
    measured), and in `SELECT` also a three-part name with exactly one quoted
    part (`awsdatacatalog."db".t`, `awsdatacatalog.db."t"`) and an unquoted
    four-part column reference (`SELECT awsdatacatalog.db.t.n FROM ...`),
    measured 2026-09-27;
  - under an S3 Tables context catalog, or a context catalog that is neither
    an alias key nor a Trino catalog, an unquoted three-part name in `SELECT`
    and `INSERT` (measured 2026-09-25 and 2026-09-27). The context catalog is
    still sent to Trino as written; Trino resolves fully qualified names
    without it. Whether the catalog exists is asked of Trino only when the SQL
    has such a name.
  Other forms (two quoted parts, a quoted part in a four-part name, other
  statements under those context catalogs), a context catalog that is an alias
  key or a Trino catalog (a federated catalog on real Athena, not measured),
  and other unquoted aliases are sent as written; they have not been measured.

## docs/dev/unmeasured.md:67（置き換え）
- [ ] 無引用の `awsdatacatalog.<db>.<t>` の置換（#246・#260）の周り: 連携カタログの Context での SELECT・INSERT、`AwsDataCatalog` 以外の別名キー（連携カタログの名前）を無引用で書いた形（#260 の o3・o4・o9。連携カタログが無く未測定）、S3 Tables・実在しないカタログの Context の SELECT・INSERT 以外の文と引用符付きの部品、既定の Context の INSERT などの引用符付きの部品、引用符付きが 2 つ・4 部に引用符付きを含む形、既定の Context で測った 5 種（SELECT・INSERT・CTAS・CREATE VIEW・EXPLAIN）以外の文（DELETE・UPDATE・MERGE・DROP VIEW・SHOW CREATE VIEW・`ALTER TABLE ... RENAME TO` の 2 つ目の名前など）。athena-local は測った組だけに `AwsDataCatalog` の別名を当て、ほかは受け取ったまま送る（2026-09-27）

## docs/dev/architecture.md:29（catalog.rs の節の後半を置き換え）
... と、呼び出し側が `UnquotedForms` で渡す形の無引用の `awsdatacatalog` を 1 部目に書いた名前（`ThreeUnquotedParts` は無引用のちょうど 3 部、`WithQuotedPartsOrColumn` はそれに加えて 2 部目か 3 部目の 1 つだけ引用符付きの 3 部と無引用の 4 部。大文字小文字によらない。直前が `.` なら 1 部目でない。キーも大文字小文字によらず `AwsDataCatalog` を引く。#246・#260）。形は `operation/unquoted_alias.rs` が Context の Catalog と文の種類から決める（表はモジュールの先頭のコメント。Trino に無いカタログかは当てる名前が SQL にあるときだけ `context_catalog::missing` で問い合わせる）。
＋ operation/ の一覧に `unquoted_alias.rs` を足す（あれば）

## docs/dev/decisions.md:76 の #246 の項の後に
- → #260 で、本物が実行したと測った組に広げた: S3 Tables・実在しないカタログの Context の SELECT・INSERT の無引用の 3 部（o1・o2・o5、#214）と、既定の Context の SELECT の引用符付きの部品を 1 つ含む 3 部・無引用の 4 部の列の参照（o6〜o8）。範囲は測った形と測った文だけ（ユーザーの判断）で、引用符付きが 2 つの形や、新しい Context のほかの文は今までどおり。判定は `unquoted_alias.rs` の表 1 か所に置き、`catalog.rs` は形（`UnquotedForms`）だけを受け取る。実在しないカタログは #214 と同じく `system.metadata.catalogs` で確かめ、Trino にあるカタログは連携カタログとみなして当てない（連携カタログは未実測）。問い合わせは当てる名前が SQL にあるときだけ（実在しないカタログの Context のほかの SELECT に要求を増やさない）。ヘッダのカタログは受け取ったまま（Trino 482 はセッションのカタログが無くても完全修飾の名前を引く）。（#260、2026-09-27）

## CLAUDE.md:38 の書き換えの条件の一覧
旧: 「Context が AwsDataCatalog か省略のときの無引用の `awsdatacatalog.<DB>.<表>` の 1 部目を同じく当てるもの」
新: 「無引用の `awsdatacatalog` を 1 部目に書いた名前のうち本物が実行したと測った Context と文の組（`operation/unquoted_alias.rs`）の 1 部目を同じく当てるもの」
＋ テストの子モジュールの一覧に `src/catalog.rs`（#260）を足す

## docs/dev/measurements/statements.md
260-measurements-section.md を末尾に足す

### 無引用の `awsdatacatalog.<DB>.<表>` の置換の周り: Context・引用符付きの部品・4 部の列の参照（#260）
- 日付: 2026-09-27（UTC 2026-09-26 21:01）／ issue: #260 ／ スクリプト: `tools/measure/unquoted-ddl.sh`（`ROUND=12`）／ 生データ: `$HOME/athena-unquoted-ddl-measurements/run-20260926-210106`
- 相手: 本物の Athena（`AwsDataCatalog`・Catalog 省略・S3 Tables のカタログ `s3tablescatalog/<bucket>`・実在しないカタログ `nosuchcatalog260`）
- 投げたもの: 9 項目（o0〜o2・o5〜o8・o10・o11）と準備・後始末 2 本。表 `<DB>.<t>`（`n`・`s` の 1 行）を CTAS で作り、全項目で使い回して最後に消した。連携カタログの Context（o3・o4）と `AwsDataCatalog` 以外の別名キー（o9）は、このアカウントに連携カタログが無く未測定
- 返ったもの（すべて SUCCEEDED。Query は送った文のまま（`awsdatacatalog.` は落ちない））:

  | 文 | Context | StatementType / SubstatementType | 返った Context |
  |---|---|---|---|
  | `SELECT 1`（o0。対照） | S3 Tables | DML / SELECT | 送ったまま |
  | `SELECT * FROM awsdatacatalog.<DB>.<t>`（o1） | S3 Tables | DML / SELECT | 送ったまま |
  | `INSERT INTO awsdatacatalog.<DB>.<t> VALUES (2, 'y')`（o2） | S3 Tables | DML / INSERT | 送ったまま |
  | 同じ INSERT（o5） | `Catalog=nosuchcatalog260,Database=<DB>` | DML / INSERT | 送ったまま |
  | `SELECT * FROM awsdatacatalog."<DB>".<t>`（o6）・`awsdatacatalog.<DB>."<t>"`（o7） | `Catalog=AwsDataCatalog` | DML / SELECT | Catalog は小文字の `awsdatacatalog`（#157 と同じ） |
  | `SELECT awsdatacatalog.<DB>.<t>.n FROM awsdatacatalog.<DB>.<t>`（o8。4 部の列の参照） | `Catalog=AwsDataCatalog` | DML / SELECT | 同上 |
  | `SELECT * FROM awsdatacatalog.<DB>.<t>`（o10）・`AWSDATACATALOG.`（o11） | `Database=<DB>` だけ（Catalog 省略） | DML / SELECT | `Database` だけ |

- 採用した判断: 別名置換の無引用の `awsdatacatalog` を、測った Context と文の組に広げる（S3 Tables・Trino に無いカタログの Context の SELECT・INSERT の無引用の 3 部、既定の Context の SELECT の引用符付きの部品と 4 部の列の参照）。実在しないカタログの SELECT は #214 の生データで SUCCEEDED と分かっていたので、このラウンドには入れなかった（decisions.md の #260 の項）
- 備考: 結果ファイルの中身（o8 の列名、o2・o5 で行が入ったか）は保存していない。ほかの文の種類（DELETE・UPDATE・MERGE・DROP VIEW・SHOW CREATE VIEW・`RENAME TO` の 2 つ目の名前。#246 の独立レビュー）も未測定（unmeasured.md）
