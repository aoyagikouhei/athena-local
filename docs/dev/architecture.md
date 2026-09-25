# アーキテクチャ

athena-local の内部の詳しい地図。CLAUDE.md にはモジュールの 1 行の地図と不変条件だけを置き、ここに関数・判定の細部と由来（実測日・issue 番号）を書く（#190）。コードを変えて記述が古くなったら、ここを直す。

## crate の構成

- ルートの `Cargo.toml` は athena-local（lib と bin）の package で、workspace のルートを兼ねる。`default-members` に内部 crate も入れているので、`cargo fmt`／`clippy`／`test` は引数なしで両方に効く（#193）。
- `crates/athena-sql` — SQL の字句処理と文の頭・句の認識を置く内部 crate（`publish = false`、依存なし）。athena-local からパスで依存する。#193 の時点では中身が無く、字句処理は #194 で `catalog.rs` から移す（段階は親 #192）。規則は [decisions.md](decisions.md) の「SQL の内部 crate（athena-sql）」。

## リクエストの流れ

1. `handler::dispatch` — `POST /` の 1 本だけ。`X-Amz-Target: AmazonAthena.<Operation>` でオペレーションを振り分ける（前置き必須。ヘッダ無し・未対応名は本物と同じ `{"__type":"UnknownOperationException"}` だけの 400。2026-09-23 実測）。SigV4 は検証しない。
2. `operation/` — 6 つのオペレーションの本体。`execution.rs`（`StartQueryExecution` の受付とバックグラウンド実行）、`format_probe.rs`（実行の前に対象の文のテーブルの形式を問い合わせる `probe_target_format`）、`completion.rs`（`run` の完了後の後処理: EXPLAIN の行分け、Iceberg のパーティション行の問い合わせ、UpdateCount の決定）、`result_output.rs`（結果ファイル本体と `.metadata` の書き込み）、`query_execution.rs`（`GetQueryExecution`／`GetQueryResults`／`StopQueryExecution`）、`work_group.rs`（`GetWorkGroup`／`ListWorkGroups`）に分かれ、文の種類の判定だけ `classification.rs` に置いて実行系と参照系の両方から呼ぶ。`MaxResults`／`NextToken` の枠組みの検証（API 定義の制約違反を `N validation error(s) detected: ...` の 1 文にまとめる。2026-09-23 実測）は `validation.rs` に置いて `GetQueryResults` と `ListWorkGroups` の両方から呼ぶ。DROP TABLE と ALTER TABLE ... ADD COLUMNS / REPLACE COLUMNS は、対象テーブルの形式によっては本物が列なしでも本体と `.metadata` を置くので、その判定を `table_format.rs`（Trino への形式の問い合わせと組み合わせの決定）と `target_table.rs`（対象の修飾名の解析）に置く。`SHOW COLUMNS`／`DESCRIBE`／`DESC` は本物と列数・行の形が違うので、`utility_rows.rs` が完了時（`completion::split_explain_rows` の直後）に `Outcome` の列と行を本物の形（Hive は 20 文字の左詰め、Iceberg は見出し行群、ビューは `column`／`type` の 2 列）に作り直し、型の綴りは `type_spelling.rs`（実測した綴りだけ写す）、Iceberg の `# Partition spec:` の行は `iceberg_partitions.rs`（Trino の `SHOW CREATE TABLE` の `partitioning` を読む）に置く（#173）。列名だけ違う文は `classification.rs` の `fixed_column`。`mod.rs` は `mod` 宣言と 6 関数の再エクスポートだけで、`handler` からの見え方は分割前と変わらない。
   - `execution.rs` の `start_query_execution`: 文脈（カタログ／スキーマ）に既定値を当てる → `OutputLocation` を検証 → `Trino::syntax_error` で構文を確かめる（`PREPARE athena_local_syntax_check FROM\n<sql>` を送り、1 行ずれたエラー位置を元に戻す）→ `Store::submit` → `spawn_query` でバックグラウンド実行して、ID をすぐ返す。
   - `execution.rs` の `spawn_query` → `run`: `ExecutionParameters` の値ごとに `SELECT (<値>)` を Trino に投げて分類し（`statement::bind`）、`EXECUTE IMMEDIATE '<sql>' USING ...` で実行する。包む前に `catalog::alias_qualified_names` で修飾名のカタログに別名を当てる。パラメータが無く、別名に一致する修飾名も無ければ SQL は一切書き換えない（テストで保証している不変条件）。`?` の無い SQL に値が渡されたときのエラーでは、別名を当てただけの SQL で再実行する。
   - `result_output.rs` の `write_result`: 本体（CSV / TXT）を置き、列があれば `.metadata` を置いてから `SUCCEEDED` にする（クライアントは SUCCEEDED を見た直後に S3 を読むため）。本体を置くのは `ResultFile::Csv` で更新件数が無いときと `ResultFile::Text` のときで、取り消されていないときだけ。DML と CTAS は本体を置かず `.metadata` だけを置く。本体の PUT が失敗したら `.metadata` は試みない。
   - `result_output.rs` の `write_failure`: 失敗（`run` が `Err`）したときに、`ResultFile::Text` の文だけ `<id>.txt` に `FAILED: ` + `StateChangeReason` を置く。ただし EXPLAIN（`EXPLAIN ANALYZE` も）は `.txt` の文でも置かない（本物も置かない。2026-09-23 実測。#92）。`.metadata` は置かない。取り消されていれば何も置かない。書けなくても FAILED と理由は Trino のエラーのまま。置き場所と Content-Type は `ResultLocation::failed`（`ResultFile::FailedText`。Content-Type だけ成功時と違う）。
3. `store.rs` — 実行状態をメモリの `HashMap` で持つ。`finish` は終端状態では何もしないので、先に `CANCELLED` になったクエリにあとから届いた結果は捨てられる。
4. `trino.rs` — Trino クライアント。`nextUri` を辿ってページを `Outcome` にまとめる（503 は待って再試行、DML の `data` は行として扱わない）。timestamp の精度を保つため `X-Trino-Client-Capabilities: PARAMETRIC_DATETIME` を必ず付ける。

## 取り消し

`StopQueryExecution` は `Store::cancel` で状態を同期に `CANCELLED` にし、`Cancel`（`AtomicBool`）を立てるだけ。実行中のタスクは `Trino::follow` のページ境界でフラグを見て、`nextUri` に `DELETE` を送る。

## Athena の見え方への変換

- `convert/` — Trino の値と型から Athena の `ResultSet` を作る。`result_set.rs`（`Outcome` → `ResultSet` の入口。1 ページ目の先頭行に列名を入れる）、`value_type.rs`（`typeSignature` の解析）、`render.rs`（値をすべて文字列にする。複合型は `typeSignature` を見て Athena の表記（`[1, 2]`、`{k=1}`）にする）、`scalar.rs`（スカラ値の表記。double は Java の `Double.toString`、varbinary は 16 進）、`athena_type.rs`（Trino の型から Athena の型名・Precision・Scale・CaseSensitive を決める）に分かれ、`typeSignature` から生の型名を取る `raw_type` だけ `value_type.rs` に置いてレンダリングと型マッピングの両方から呼ぶ。`mod.rs` は `mod` 宣言と 3 関数の再エクスポートだけで、呼び出し元からの見え方は分割前と変わらない。`GetQueryResults` と結果 CSV（`results::to_csv`）の両方がここを通る。
- 文の種類は先頭のキーワードで判定していて、SQL を読む判定が 3 か所にある。`StatementType`／`SubstatementType` は `operation/classification.rs`（`UpdateCount` は `operation/completion.rs` の `update_count` が完了時に `statement_type`・`content_type::carries_execution_id`・形式の判定から決めて `Store` に持たせ、`GetQueryResults` は読むだけ。#160）、`OutputLocation` のファイル名（`<id>.csv`、`<id>`、`tables/<id>`、`<id>.txt`）は `results::ResultFile::of`、結果ファイルの Content-Type は `content_type.rs`。CTAS の判定（`is_create_table_as`）は前の 2 つで共有している。前の 2 つは SQL を `catalog::words`（内部の `skip_trivia` で空白とコメント（`-- ...`、`/* ... */`）を区切りとして読み飛ばし、大文字の語の並びにする）で分けてから判定するので、先頭のコメントもキーワードの間のコメントも語にならない（本物の Athena も同様。2026-09-18／22 実測）。`catalog::skip_leading_trivia` は ALTER TABLE の対象名の解析（`classification.rs` の `alter_table_action`）などで使う。どこまで読むかは文ごとに違う: `SubstatementType` は 2〜4 語目まで、ALTER TABLE はテーブル名を読み飛ばした後ろのキーワード、CTAS は語の並び全体から `AS SELECT`／`AS WITH`／`AS (` を探し、`ResultFile::of` は `SHOW FUNCTIONS` の 2 語目まで、`content_type.rs` は SELECT の本文がリテラルだけかまで見る。ほかに `result_output.rs` の `metadata_query_id` が先頭 2 語（`DESCRIBE`／`DESC`、`SHOW CREATE`）で `.metadata` の先頭に載せるクエリ ID を選ぶ（`content_type.rs` の `.txt` の判定と対にする）。どれもテーブルの形式は SQL から読み取らない（CTAS は本物と同じくテーブルの形式によらず `tables/<id>`。2026-09-19 実測）。
- `catalog.rs` — `TRINO_CATALOG_MAP` の別名を SQL の修飾名にも当てる。対象は、別名マップのキーと完全一致する二重引用符付き識別子で、空白やコメントを挟んで `.` が続くものだけ。文字列リテラルとコメントは読み飛ばす。置き換えた名前が短ければ空白で埋めて、Trino のエラーの桁位置を受け取った SQL に揃える。構文チェックと `GetQueryExecution` の `Query` は受け取った SQL のまま。
- `metadata.rs` — 結果ファイルの隣に置く `.metadata` の protobuf を組み立てる（公式のスキーマは無く、burtcorp/athena-jdbc の `AthenaMetaDataParser` と同じフィールド番号）。先頭にクエリ ID、DML と CTAS は `updateType` と更新件数、続けて列ごとに `ColumnInfo` と同じ値。列の Precision／Scale／CaseSensitive を出すかどうかは値ではなく型ごとの表で決める（2026-09-17 実測）。S3 も文の分類も知らない。クエリ ID の出どころ（Trino の ID か `QueryExecutionId` か）は `operation/result_output.rs` 側で決める。
- `failure.rs` — Trino のエラー名を `AthenaError` の `ErrorCategory`／`ErrorType` に写す。
- `request.rs` — awsJson1.1 のリクエスト本文の解釈。JSON として読めない・トップレベルが object でない・型違い・必須の欠落を、本物と同じ `SerializationException`（文言は実測した型の組み合わせだけ。未実測は `Message` 無し）と枠組みの検証（`Value null at '<lowerCamel>' ... Member must not be null`）に写す（2026-09-23 実測）。`null` の項目は読む前に消す（本物は無いのと同じに扱う）。
- `response.rs` — awsJson1.1 のエラー形（`__type`、必要なら `AthenaErrorCode`。本物と同じく `x-amzn-errortype` ヘッダは付けない（#145）。`__type` だけの `bare_error`、`SerializationException` の `serialization_error`、枠組みの検証の文言 `validation_errors`）。
- `athena.rs` — リクエスト／レスポンスの型（PascalCase で SDK の JSON と一対一に対応する）。

## テストの足場（`tests/common/mod.rs`）

`Harness` が偽 Trino、（`results_s3()` を呼べば）偽 S3、本物の `athena_local::router` を同じプロセスの `127.0.0.1:0` に立てる。`Harness::builder(<既定の応答>)` のあと、`.route(sql, 応答)`（SQL ごとの応答）、`.next_page`、`.endless()`（終わらないクエリ）、`.statement_delay`、`.syntax_check_response`、`.catalog_map` などで偽 Trino の振る舞いを決める。検証には `trino_requests()`／`trino_sqls()`（実行された SQL とヘッダ）、`syntax_checks()`（PREPARE で届いた SQL。`trino_requests` には入らない）、`trino_calls()`（`nextUri` への GET／DELETE）、`s3_puts()`（body はバイト列。`.metadata` の protobuf を見るため）を使う。偽 Trino は、応答に `id` が無ければ既定のクエリ ID `TRINO_QUERY_ID` を補う（`.metadata` の先頭に入るため）。

- 偽 Trino は、PREPARE の前置きを `src/trino.rs` と同じ定数 `SYNTAX_CHECK_PREFIX` で見分けている。前置きを変えるときは両方を直す。
- テストバイナリごとに `common` を取り込むので、使われないヘルパが出る。そのため `#![allow(dead_code)]` を付けている。
- `config.rs` のテストは本物の環境変数を触らない（テストが並列に走るため）。`parse_results` に環境変数を読むクロージャを渡して差し替える。
- ユニットテストはインラインの `#[cfg(test)] mod tests` に置く。例外は本体とテストを合わせて 400 行を超えたファイルで、テストを子モジュール `<name>/tests.rs`（`mod.rs` 無し）に出している: `src/results.rs`（#75）と、`src/operation/` の `classification.rs`・`target_table.rs`・`table_format.rs`（#162）。
