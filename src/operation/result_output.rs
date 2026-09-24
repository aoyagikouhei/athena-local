//! 結果ファイル本体と `.metadata` の書き込み。

use crate::convert;
use crate::failure::Failure;
use crate::handler::App;
use crate::metadata;
use crate::results::{self, ResultFile, ResultLocation};
use crate::store::Execution;
use crate::trino::Outcome;

use super::table_format::EngineDdl;

/// DROP TABLE × Iceberg など、列が無くても本体・`.metadata` を置く DDL の Content-Type
/// （2026-09-20 実測。本体も `.metadata` も application/octet-stream）。
const ENGINE_DDL_CONTENT_TYPE: &str = crate::content_type::APPLICATION;

/// 本体と付随ファイル `.metadata` の両方を置いてから結果を返す。SUCCEEDED にするのは
/// 書き終わってからにする（クライアントは SUCCEEDED を見た直後に S3 を読みに行く）。
/// .csv（SELECT と SHOW FUNCTIONS）は書けなければ FAILED。.txt（DDL / SHOW など）は書けなくても SUCCEEDED のまま
/// （Trino では既に実行し終えており、本物の Athena も補助ファイルの書き込みでは失敗にしない）。
/// `.metadata` は列がある文に置き、書けなくても SUCCEEDED のまま。
/// DML と CTAS は本体を置かず `.metadata` だけを置く（2026-09-17 実測）。
/// `engine_ddl` が `Some` の文（issue #39）は列が無くても `.metadata` を置き、Content-Type は
/// 本体・付随ファイルとも application/octet-stream にする。本体に改行 1 つを足すのは
/// DROP TABLE × Iceberg だけで、ALTER TABLE ADD COLUMNS × Hive の本体は 0 バイトのまま
/// （2026-09-20／21 実測）。
pub(super) async fn write_result(
    app: &App,
    execution: &Execution,
    id: &str,
    outcome: Outcome,
    engine_ddl: Option<EngineDdl>,
) -> Result<Outcome, Failure> {
    let (Some(writer), Some(location)) = (&app.results, &execution.result_location) else {
        return Ok(outcome);
    };
    // 途中で止められていれば何も書かない（CANCELLED の本物も何も置かない）。
    if execution.cancel.is_requested() {
        return Ok(outcome);
    }

    // 列なしでも本体・`.metadata` を置く DDL（issue #39）は、本体も `.metadata` も
    // `ResultLocation` の既定（0 バイトの DDL の binary）ではなく application で置く。
    let content_type = engine_ddl.is_some().then_some(ENGINE_DDL_CONTENT_TYPE);

    // 本体を書くのは SELECT の結果（.csv、更新件数が無いとき。SHOW FUNCTIONS もこちら。#80）と
    // DDL / SHOW（.txt）だけ。
    // DML / CTAS が置くファイル（manifest や tables/<id>）は作らない。
    let should_write = location.file == ResultFile::Text
        || (location.file == ResultFile::Csv && outcome.update_count.is_none());
    if should_write {
        let body = match location.file {
            ResultFile::Csv => results::to_csv(&outcome),
            // 改行 1 つ（0x0a）。to_text は列の空を見て 0 バイトを返すので使わない。
            // 本体を書くのは DROP TABLE × Iceberg だけで、`.metadata` を置く文のすべてではない
            // （ALTER TABLE ADD COLUMNS × Hive の本体は 0 バイト。2026-09-20 実測）。
            _ if matches!(engine_ddl, Some(EngineDdl::DropTableIceberg)) => vec![b'\n'],
            // 先頭の列名行を入れるのは GetQueryResults と同じく DML（EXPLAIN）だけで、
            // DDL / SHOW / DESCRIBE（UTILITY）には入れない（2026-09-15／16 実測。#60 / #63）。
            _ => results::to_text(
                &outcome,
                super::classification::statement_type(&execution.query) == "DML",
            ),
        };
        match writer.put(location, body, content_type).await {
            Ok(()) => {}
            // 本体が書けなかったら付随ファイルは試みない。
            Err(reason) if location.file == ResultFile::Text => {
                eprintln!("結果ファイル（.txt）の書き込みに失敗しました。無視します: {reason}");
                return Ok(outcome);
            }
            Err(reason) => return Err(Failure::result_write(reason)),
        }
    }

    // 列が無い文（CREATE TABLE、CREATE / DROP DATABASE）には本物も付随ファイルを置かない。
    // DROP TABLE × Iceberg（41 バイト）と ALTER TABLE ADD COLUMNS × Hive（38 バイト）だけは
    // 本物が列なしでも `.metadata` を置く（2026-09-20／21 実測。issue #39）。
    if !outcome.columns.is_empty() || engine_ddl.is_some() {
        // ALTER TABLE の ADD COLUMNS / REPLACE COLUMNS × Hive だけは field 1 に実行 ID だけを置き、field 2（updateType）も
        // field 3（更新件数）も置かない。Trino の updateType は "ADD COLUMN"（Athena の
        // `ADD COLUMNS` と綴りが違う）なので、そのまま使うと誤った field 2 が付く（2026-09-21 実測）。
        let (query_id, update_type, update_count) =
            if engine_ddl == Some(EngineDdl::AlterColumnsHive) {
                (id, None, None)
            } else {
                (
                    metadata_query_id(&execution.query, id, outcome.id.as_deref()),
                    outcome.update_type.as_deref(),
                    outcome.update_count,
                )
            };
        write_metadata(
            writer,
            location,
            query_id,
            update_type,
            update_count,
            &outcome,
            content_type,
        )
        .await;
    }
    Ok(outcome)
}

/// 失敗の理由を結果ファイルに置く。中身は `FAILED: ` + StateChangeReason で末尾に改行は付けない
/// （本物は StateChangeReason そのものを置き、その文言自体が `FAILED: ` で始まる。2026-09-17 実測）。
/// 置くのは `<id>.txt` の文（DDL / SHOW など）だけで、`.metadata` は置かない（実測）。
/// `.txt` の文でも EXPLAIN は置かない（本物はクエリエンジンで動く文に失敗時のファイルを置かない。2026-09-23 実測。#92）。
/// `<id>.csv` の SHOW FUNCTIONS が失敗しても、他の `.csv` の文と同じく置かない（本物も `<id>.csv` も `.metadata` も置かない。2026-09-24 実測。#80・#146）。
/// 書けなくても FAILED と StateChangeReason は Trino のエラーのまま（`.txt` / `.metadata` と同じ扱い）。
/// `.csv` の PUT が失敗して FAILED になる経路（`write_result`）はここを通らない。
pub(super) async fn write_failure(app: &App, execution: &Execution, failure: &Failure) {
    let (Some(writer), Some(location)) = (&app.results, &execution.result_location) else {
        return;
    };
    // 途中で止められていれば何も書かない（write_result と同じ。CANCELLED の本物も何も置かない）。
    if execution.cancel.is_requested() {
        return;
    }
    // EXPLAIN は `.txt` の文だが、クエリエンジンで動くので本物は失敗時に本体も `.metadata` も
    // 置かない（`EXPLAIN` と `EXPLAIN ANALYZE` を 2026-09-23 に実測。#92）。
    if super::classification::substatement_type(&execution.query) == Some("EXPLAIN") {
        return;
    }
    let Some(location) = location.failed() else {
        return;
    };

    let body = format!("FAILED: {}", failure.reason).into_bytes();
    if let Err(reason) = writer.put(&location, body, None).await {
        eprintln!("失敗の理由のファイル（.txt）の書き込みに失敗しました。無視します: {reason}");
    }
}

/// 付随ファイル `.metadata` を組み立てて置く。書けなくても実行は成功のまま（補助ファイルなので握りつぶす）。
/// `query_id` / `update_type` / `update_count` は呼び出し元（`write_result`）が文の種類に応じて
/// 決めた値（ALTER TABLE ADD COLUMNS × Hive だけは実行 ID・None・None に上書きされている）。
/// `content_type` は本体と同じ上書き（列なしでも `.metadata` を置く DDL だけ `Some`）。
/// 上書きが無ければ本体と同じ既定の値になる（`ResultLocation::metadata`）。
async fn write_metadata(
    writer: &results::ResultWriter,
    location: &ResultLocation,
    query_id: &str,
    update_type: Option<&str>,
    update_count: Option<i64>,
    outcome: &Outcome,
    content_type: Option<&str>,
) {
    let body = metadata::to_metadata(
        query_id,
        update_type,
        update_count,
        &convert::column_infos(outcome),
    );
    if let Err(reason) = writer.put(&location.metadata(), body, content_type).await {
        eprintln!("付随ファイル（.metadata）の書き込みに失敗しました。無視します: {reason}");
    }
}

/// `.metadata` の先頭（field 1）に載せるクエリ ID。2026-09-17 実測では DESCRIBE と
/// SHOW CREATE TABLE だけが QueryExecutionId で、SELECT・DML・CTAS・EXPLAIN・DROP TABLE は
/// エンジン（Trino）のクエリ ID だった。SHOW FUNCTIONS もエンジンのクエリ ID（2026-09-23 実測。#80）。
fn metadata_query_id<'a>(
    query: &str,
    execution_id: &'a str,
    engine_id: Option<&'a str>,
) -> &'a str {
    let words = super::classification::words(query);
    let word = |index: usize| words.get(index).map(String::as_str).unwrap_or_default();

    match (word(0), word(1)) {
        ("DESCRIBE" | "DESC", _) | ("SHOW", "CREATE") => execution_id,
        _ => engine_id.unwrap_or(execution_id),
    }
}
