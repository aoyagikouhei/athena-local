# #248 計画（quick-implement、変更サイズで外れて計画攻撃と独立レビューを足した）

リポジトリ: /home/aoyagikouhei/git/athena-local（ブランチ main-248、着手前 9e13c23）。

## 実測（本物の Athena、2026-09-27 ROUND=10。Context は s12 以外 Catalog=s3tablescatalog/<bucket>,Database=<ns>、s12 は AwsDataCatalog）
| ID | 文 | 本物 |
|---|---|---|
| s1 | CREATE TABLE t (n int) COMMENT 't comment' LOCATION 'L' | 開始時 MALFORMED_QUERY `Table location can not be specified for tables hosted in S3 table buckets` |
| s2 | CREATE TABLE t (n int) CLUSTERED BY (n) INTO 4 BUCKETS LOCATION 'L' | 同上 |
| s3 | CREATE TABLE t (n int) ROW FORMAT SERDE 'org...OpenCSVSerde' LOCATION 'L' | 同上 |
| s4 | CREATE TABLE t (n int) ROW FORMAT DELIMITED FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n' LOCATION 'L' | 同上 |
| s5 | CREATE TABLE t (n map<string,string>) ROW FORMAT DELIMITED COLLECTION ITEMS TERMINATED BY ',' MAP KEYS TERMINATED BY ':' NULL DEFINED AS 'N' LOCATION 'L' | 同上 |
| s6 | CREATE TABLE t (n int) LOCATION 'L' TBLPROPERTIES ('a'='b', 'c'='d') | 同上 |
| s11 | CREATE TABLE `t` (n int) LOCATION 'L'（バッククォートの 1 部の表名） | 同上 |
| s16 | CREATE TABLE t (n int) STORED AS PARQUET LOCATION 'L' | 同上（今の実装で既に当たる） |
| s7 | CREATE EXTERNAL TABLE ns.t (n int) | 開始時 MALFORMED_QUERY `External keyword not supported for table type ICEBERG` |
| s8 | CREATE EXTERNAL TABLE AwsDataCatalog.db.t (n int) | 同上 |
| s9 | CREATE EXTERNAL TABLE t (n int) STORED AS PARQUET | 同上 |
| s10 | CREATE EXTERNAL TABLE t (n int) TBLPROPERTIES ('a'='b') | 同上 |
| s12 | 既定 Context で CREATE TABLE nosuchcatalog248.db.t (n int) LOCATION 'L' | 開始時 DATACATALOG_NOT_FOUND `Catalog 'nosuchcatalog248' does not exist` |
| s13 | S3 Tables Context で CREATE TABLE hive248.db.t (n int) LOCATION 'L'（#229 の n6 も同じ形で同じ結果） | 同上（`Catalog 'hive248' does not exist`） |
| s14 | 実在する連携カタログの 3 部 + LOCATION | 未測定 |
| s15 | CREATE TABLE t (n int) STORED AS ORC（LOCATION 無し。#229 の n21 は PARQUET で同じ） | 開始でき FAILED、DDL/CREATE_TABLE、ErrorCategory 2・ErrorType 1200、`Iceberg create table statement does not allow STORED AS/BY`、結果ファイル本体・.metadata とも無い |
| s17 | CREATE TABLE t (c row(a int)) LOCATION 'L' | 開始時 MALFORMED_QUERY `line 1:61: mismatched input 'LOCATION'. Expecting: 'COMMENT', 'WITH', <EOF>`（Trino の構文エラーの形） |
| s18 | CREATE TABLE t (c array(row(a int))) LOCATION 'L' | 同上 line 1:68 |
#229 までの実測: n1〜n5（1〜3 部の名前・大文字混じり AwsDataCatalog・EXTERNAL + LOCATION）、n11（EXTERNAL t (n int)）、n12（EXTERNAL awsdatacatalog.db.t (n int)）、n20（ROW FORMAT DELIMITED FIELDS ... STORED AS TEXTFILE LOCATION ... TBLPROPERTIES ('a'='b')）、n7〜n9・n13〜n18・n22（引用符付きの名前・4 部・NOT NULL・引用符付き列名・後ろのごみ・TBLPROPERTIES が LOCATION の前 など）は本物も Trino の構文エラー。

## 変更
1. `src/operation/unquoted_ddl/create_table/hive.rs`
   - 今の `s3_tables_rejection` の手続きを、Hive の句の順に各句を 0/1 回読む解析 `read(query) -> Option<Hive>` に作り直す:
     `CREATE [EXTERNAL] TABLE [IF NOT EXISTS] <名前> [(列)] [COMMENT '..'] [PARTITIONED BY (列)] [CLUSTERED BY (識別子, ...) INTO <数> BUCKETS]
      [ROW FORMAT (SERDE '..' | DELIMITED [FIELDS TERMINATED BY '..'] [COLLECTION ITEMS TERMINATED BY '..'] [MAP KEYS TERMINATED BY '..'] [LINES TERMINATED BY '..'] [NULL DEFINED AS '..'])]
      [STORED AS <語>] [LOCATION '..'] [TBLPROPERTIES ('k'='v' [, 'k'='v']...)] <終わり>`
     名前は今の `qualified_name`（`"` 付きは None）に加え、1 部のバッククォートの名前 `` `t` `` を読む（athena-sql の qualified_name はバッククォートを読まないので hive.rs の中で `` ` `` から次の `` ` `` まで）。
     `Hive` は external・if_not_exists・名前の部（無引用 1〜3 部、1 部のバッククォート）・columns・どの句があったか（bool）を持つ。
   - `s3_tables_rejection(query) -> Option<&'static str>`（S3 Tables の Context でだけ呼ばれる。今と同じ）:
     名前が 1 部・2 部・3 部（1 部目が大文字小文字によらず awsdatacatalog）でなければ None。LOCATION があれば Table location。
     LOCATION が無く EXTERNAL・列あり・句が STORED AS と TBLPROPERTIES だけ（どちらも任意）なら External keyword（バッククォートの名前は None）。
   - 新 `s3_tables_stored_as(query) -> bool`: EXTERNAL でない・IF NOT EXISTS 無し・無引用の 1 部の名前・列あり・句が STORED AS だけ（LOCATION 無し）。
   - 新 `location_catalog(query) -> Option<&str>`: EXTERNAL でない・LOCATION あり・無引用の 3 部で 1 部目が awsdatacatalog（大文字小文字によらず）でないとき、書いたとおりの 1 部目。
2. `src/operation/create_table_catalog.rs`: `check` の「1 部目が awsdatacatalog でなければ Trino にカタログを問い合わせ、無いと確かめられたら DATACATALOG_NOT_FOUND」の部分を
   `catalog_rejection(trino, config, catalog) -> Option<Box<Response>>` に切り出し、`check` と新しい `location_catalog_rejection(trino, config, query)` から使う。
3. `src/operation/start_checks.rs` の `decide` の先頭:
   - Context によらず `create_table_catalog::location_catalog_rejection` が Some ならそれで弾く（s12・s13・n6）。`s3_tables_rejection` より前。カタログがある・確かめられないなら今までどおり（S3 Tables なら s3_tables_rejection は 3 部で 1 部目が awsdatacatalog でなければ None なので Trino の構文エラー、s14 は未測定のまま）。
   - S3 Tables の Context で `s3_tables_stored_as` が真なら、`pre_syntax_check_failure` の代わりに `ImmediateFailure { failure: Failure::iceberg_stored_as(), writes_result_file: false }`（構文チェックを飛ばす。`pre_syntax_check_failure` が Some のときと同じ経路）。
4. `src/failure.rs`: `Failure::iceberg_stored_as()`（USER=2・1200・`Iceberg create table statement does not allow STORED AS/BY`、error_message None。`msck_iceberg` と同じ形）。
5. s17・s18 は `column` が `row(` を Unmeasured にして今も None → Trino の構文チェックの文言になる。コード変更なし（compose の Trino で文言を確かめてテストか docs に残す）。

## テスト
- hive.rs のユニットテスト: s1〜s11・s16 の形を Some に、今の None の表から s1〜s6・s11 に当たる行（COMMENT・SERDE・TBLPROPERTIES 2 組・EXTERNAL の 2 部・大文字 3 部・EXTERNAL + STORED AS）を移す。s3_tables_stored_as・location_catalog の真偽表。
- tests/syntax.rs・tests/create_table_catalog.rs に結合テスト: s12（既定 Context）・s13（S3 Tables）で DATACATALOG_NOT_FOUND と構文チェックを送らないこと、カタログがあれば今までどおり、s15 で開始 → FAILED（2/1200、結果ファイル無し、Trino に送らない）。

## 既存関数の本文

### src/operation/unquoted_ddl/create_table/hive.rs:24-100（今の s3_tables_rejection）
```rust
pub(in crate::operation) fn s3_tables_rejection(query: &str) -> Option<&'static str> {
    let sql = query.trim_start_matches([' ', '\t', '\r', '\n']);
    let mut cursor = Cursor::new(sql);
    if !cursor.keyword("CREATE") { return None; }
    let external = cursor.keyword("EXTERNAL");
    if !cursor.keyword("TABLE")
        || (cursor.keyword("IF") && !(cursor.keyword("NOT") && cursor.keyword("EXISTS"))) { return None; }
    let name = cursor.qualified_name()?;
    let external_measured = match name.parts.as_slice() {
        parts if parts.iter().any(|part| part.text.starts_with('"')) => return None,
        [_] => true,
        [_, _] => false,
        [catalog, _, _] if catalog.text.eq_ignore_ascii_case("awsdatacatalog") => catalog.text == "awsdatacatalog",
        _ => return None,
    };
    let statement_start = sql.len() - skip_leading_trivia(sql).len();
    let columns = cursor.punct(b'(');
    if columns && !column_list(sql, statement_start, &mut cursor) { return None; }
    if external && columns && cursor.at_end() { return external_measured.then_some(S3_TABLES_EXTERNAL); }
    if cursor.keyword("PARTITIONED") && !(cursor.keyword("BY") && cursor.punct(b'(') && column_list(sql, statement_start, &mut cursor)) { return None; }
    if cursor.keyword("ROW") && !(["FORMAT", "DELIMITED", "FIELDS", "TERMINATED", "BY"].iter().all(|k| cursor.keyword(k)) && string_literal(&mut cursor)) { return None; }
    if cursor.keyword("STORED") && !(cursor.keyword("AS") && cursor.identifier()) { return None; }
    if !(cursor.keyword("LOCATION") && string_literal(&mut cursor)) { return None; }
    if cursor.keyword("TBLPROPERTIES") && !(cursor.punct(b'(') && string_literal(&mut cursor) && cursor.punct(b'=') && string_literal(&mut cursor) && cursor.punct(b')')) { return None; }
    cursor.at_end().then_some(S3_TABLES_LOCATION)
}
fn column_list(sql, statement_start, cursor) -> bool { loop { match column(..) { Next => {}, EndOfColumns => return true, Rejected(_) | Unmeasured => return false } } }
fn string_literal(cursor) -> bool { skip_leading_trivia(cursor.rest()).starts_with('\'') && cursor.literal() }
```
（`column` は src/operation/unquoted_ddl/create_table.rs:136。列名 → 型名 → 型引数。`row(a int)` のように型名の直後の `(` の中が識別子なら NV の Rejected、`(10,2)` の数字は読み飛ばす、`<...>` は許された文字だけ読み飛ばす）

### src/operation/start_checks.rs:34-70（decide の先頭）
```rust
pub(super) async fn decide(app: &App, query: String, catalog: Option<&str>, database: Option<String>, result_location: Option<&ResultLocation>) -> Result<Decision, Box<Response>> {
    let s3_tables = catalog.is_some_and(|catalog| catalog.to_ascii_lowercase().starts_with("s3tablescatalog/"));
    if s3_tables && let Some(message) = unquoted_ddl::s3_tables_rejection(&query) {
        return Err(Box::new(invalid_request_with_code(message, "MALFORMED_QUERY")));
    }
    let pre_syntax_check_failure = pre_syntax_check_failure(&app.trino, &app.config, &query, catalog, database.as_deref()).await;
    if pre_syntax_check_failure.is_none() && let Some(message) = app.trino.syntax_error(&query).await {
        return Err(Box::new(invalid_request_with_code(message, "MALFORMED_QUERY")));
    }
    ...（drop_catalog → context_catalog::resolve → entity_check::check → Check::Reject なら Err）
    let mut immediate_failure = pre_syntax_check_failure;
    if !matches!(check, Check::Run)
        && let Some(message) = quoted_names::rejection(&query, ...).or_else(|| unquoted_ddl::rejection(&query, s3_tables))
    {
        // message == NO_LOCATION なら create_table_catalog::check(...)（Reject / FailAtRuntime / Rewrite / Continue→ MALFORMED_QUERY で弾く）
    } else if s3_tables && let Some(failure) = create_table_catalog::two_part_failure(...).await {
        immediate_failure = Some(ImmediateFailure { failure, writes_result_file: false });
    } else if s3_tables { /* CTAS */ }
    ...（comment_parse_error::detect / plain_alter_failure が Some なら immediate_failure を上書き、writes_result_file: true）
}
```

### src/operation/create_table_catalog.rs:40-70（check）
```rust
pub(super) async fn check(trino: &Trino, config: &Config, query: &str, context_catalog: Option<&str>) -> Outcome {
    let Some((catalog, namespace, first_part)) = three_part_name(query) else { return Outcome::Continue; };
    if !catalog.eq_ignore_ascii_case("awsdatacatalog") {
        let sql = catalog_exists_sql(&trino_catalog(config, catalog).to_lowercase());
        return if missing(trino, &sql).await {
            Outcome::Reject(Box::new(invalid_request_with_code(format!("Catalog '{catalog}' does not exist"), "DATACATALOG_NOT_FOUND")))
        } else { Outcome::Continue };
    }
    ...（S3 Tables の名前空間）
}
// trino_catalog: TRINO_CATALOG_MAP のキーを大文字小文字によらず当てる。当たらなければ書いたとおり。
// context_catalog::missing(trino, sql): SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = '<c>') が 1 行 NULL のときだけ真。失敗は偽。
```

### src/failure.rs:92-101
```rust
pub fn msck_iceberg() -> Self {
    Self { reason: "Query type not supported by Athena Iceberg at this time".to_string(), error_message: None, category: USER, error_type: 1200, retryable: false }
}
```

## design-checklist の該当行
- SQL 本文に書いた無引用の名前で `TRINO_CATALOG_MAP` などの設定のキーを引くとき、大文字小文字の照合を決めたか（後段と同じ文で読む）
- 「athena-local からは届かないので載せない」と除外していた一覧に、今回の変更で届くようになる文が無いか grep したか（構文チェックの前に横取りする文が、実在しない Context のカタログの解決から漏れる）
- 「未実測なので弾かない（実行する）」に倒す条件が、実測済みの形まで巻き込んでいないか。条件を実測した表と 1 行ずつ突き合わせ、未実測の部分だけを外したか
