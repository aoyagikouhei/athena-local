//! SQL の先頭のキーワードから StatementType / SubstatementType を判定する。

/// 空白とコメントを区切りにした大文字の語の並び（`athena_sql::words`）から、先頭の `(` を取り除いたもの。
/// 先頭のコメント（2026-09-18 実測）もキーワードの間のコメント（2026-09-22 実測。#52）も語にならない。
/// `(` だけの語（`( SELECT` のように直後に空白や改行があるとき）は取り除くと空になるので落とし、
/// `(SELECT` と同じ判定にする（#64 のレビューで見つかった。本物も `( SELECT 1 )` と改行を挟んだ形を
/// DML / SELECT にする。2026-09-24 実測。#146）。
pub(super) fn words(query: &str) -> Vec<String> {
    athena_sql::words(query)
        .into_iter()
        .map(|word| word.trim_start_matches('(').to_string())
        .filter(|word| !word.is_empty())
        .collect()
}

/// 本物の StatementType（2026-09-14 実測）。EXPLAIN と VACUUM は DML、OPTIMIZE は DDL。
/// `TABLE t`（`SELECT * FROM t` の短縮形）も本物は受け付けて DML（2026-09-22 実測。#65）。
/// 先頭のコメントは `words()` が読み飛ばして判定する（2026-09-18 実測）。
pub(super) fn statement_type(query: &str) -> &'static str {
    let words = words(query);
    match words.first().map(String::as_str).unwrap_or_default() {
        "SELECT" | "WITH" | "VALUES" | "TABLE" | "INSERT" | "UPDATE" | "DELETE" | "MERGE"
        | "EXPLAIN" | "VACUUM" => "DML",
        "CREATE" | "DROP" | "ALTER" | "OPTIMIZE" => "DDL",
        _ => "UTILITY",
    }
}

/// 本物の SubstatementType（2026-09-14 実測）。実測していない形の文は None にして項目ごと省く。
/// 先頭のコメントは `words()` が読み飛ばして判定する（2026-09-18 実測）。
/// Trino の書き方しか無い同義の文（CREATE SCHEMA、SHOW SCHEMAS、ADD COLUMN）は、Athena の同義の文に寄せる。
pub(super) fn substatement_type(query: &str) -> Option<&'static str> {
    let words = words(query);
    let word = |index: usize| words.get(index).map(String::as_str).unwrap_or_default();

    Some(match word(0) {
        // `TABLE t` も本物は SELECT（2026-09-22 実測。#65）。
        "SELECT" | "WITH" | "VALUES" | "TABLE" => "SELECT",
        "INSERT" => "INSERT",
        "UPDATE" => "UPDATE",
        "DELETE" => "DELETE",
        "MERGE" => "MERGE",
        "EXPLAIN" => "EXPLAIN",
        // 本物は `DESC t` も `DESCRIBE t` と同じ種類・列・行で返す（2026-09-23／24 実測。#70 f1-desc・#173 d6）。
        "DESCRIBE" | "DESC" => "DESCRIBE_TABLE",
        "VACUUM" => "VACUUM_TABLE",
        // Athena の OPTIMIZE は CTAS と同じ種類になる。
        "OPTIMIZE" => "CREATE_TABLE_AS_SELECT",
        "SHOW" => match (word(1), word(2)) {
            ("TABLES", _) => "SHOW_TABLES",
            ("DATABASES" | "SCHEMAS", _) => "SHOW_DATABASES",
            ("COLUMNS", _) => "SHOW_COLUMNS",
            ("CREATE", "TABLE") => "SHOW_CREATE_TABLE",
            // 2026-09-24 実測（#146・#151）。StatementType は他の SHOW と同じ UTILITY。
            ("CREATE", "VIEW") => "SHOW_CREATE_VIEW",
            // 2026-09-23 実測（#80）。StatementType は他の SHOW と同じ UTILITY。
            ("FUNCTIONS", _) => "SHOW_FUNCTIONS",
            _ => return None,
        },
        "CREATE" => {
            let object = if word(1) == "OR" { word(3) } else { word(1) };
            match object {
                "DATABASE" | "SCHEMA" => "CREATE_DATABASE",
                "TABLE" if crate::results::is_create_table_as(&words) => "CREATE_TABLE_AS_SELECT",
                "TABLE" => "CREATE_TABLE",
                "VIEW" => "CREATE_VIEW",
                _ => return None,
            }
        }
        "DROP" => match word(1) {
            "TABLE" => "DROP_TABLE",
            "VIEW" => "DROP_VIEW",
            "DATABASE" | "SCHEMA" => "DROP_DATABASE",
            _ => return None,
        },
        // テーブル名は固定位置ではなく `athena_sql::Cursor::qualified_name` で読み飛ばしてから、
        // その後ろのキーワードで判定する（2026-09-21 実測で見つかった退行の修正。
        // `word(3)`／`word(4)` の固定位置だと、引用符付きテーブル名や修飾名が空白・コメントを
        // 挟むと語数がずれて None に落ちていた。`ALTER TABLE IF EXISTS ...` と
        // `RENAME COLUMN` は本物の Athena に構文が無い（mismatched input）ので、テーブル名の
        // 位置に "IF" や "RENAME" 相当の語しか無く変わらず None になる）。
        "ALTER" if word(1) == "TABLE" => alter_table_action(query)?,
        _ => return None,
    })
}

/// 本物が Trino の列名・型によらず固定の列で返す文の、列名と Athena の型名。GetQueryResults の
/// `ColumnInfo` と `.metadata` の両方に使う。`SHOW CREATE TABLE` は Hive／Iceberg とも
/// `createtab_stmt`／`string`（2026-09-23／24 実測。#161）、`SHOW CREATE VIEW` は `create view`／`varchar`
/// （2026-09-24 実測）。どちらも Precision・Scale は 0、CaseSensitive は false で、Trino の varchar の
/// 見え方とは違う。`SHOW TABLES` は `tab_name`／`string`（2026-09-23／24 実測。#173）、`SHOW SCHEMAS`
/// （`SHOW_DATABASES`）は `database_name`／`string`（2026-09-24 実測。#173）。
/// 列数か行の形が違う文（SHOW COLUMNS、DESCRIBE）は `utility_rows::reshape` が完了時に作り直す（#173）。
pub(super) fn fixed_column(query: &str) -> Option<(&'static str, &'static str)> {
    match substatement_type(query)? {
        "SHOW_CREATE_TABLE" => Some(("createtab_stmt", "string")),
        "SHOW_CREATE_VIEW" => Some(("create view", "varchar")),
        "SHOW_TABLES" => Some(("tab_name", "string")),
        // `SHOW SCHEMAS` も本物は `SHOW DATABASES` と同じ列（2026-09-24 実測 d3。#173）。
        "SHOW_DATABASES" => Some(("database_name", "string")),
        _ => None,
    }
}

/// `ALTER TABLE` の後ろのテーブル名を `athena_sql::Cursor::qualified_name` で読み飛ばし、
/// その後ろのキーワードを 1 つずつ読み進めて ADD／DROP／REPLACE／RENAME／SET を判定する。
/// 本物が実行時に失敗する組み合わせ（REPLACE COLUMNS・ADD PARTITION × Iceberg、
/// RENAME TO × Hive）でも SubstatementType は同じ値で返るので、成否では分けない（2026-09-21 実測）。
/// `ALTER`／`TABLE` のキーワード自体は呼び出し元の `word(0)`／`word(1)` の guard で確定している。
///
/// キーワードの一致は `words()` の語の完全一致ではなく `athena_sql::Cursor::keyword` で確かめる。
/// そうしないと `TBLPROPERTIES('comment' = 'x')` のようにキーワードの直後に空白なしで
/// `(` や文字列リテラルが続く書き方を判定できない（3 本目のレビューで実測）。
fn alter_table_action(query: &str) -> Option<&'static str> {
    let mut cursor = athena_sql::Cursor::new(query);
    if !(cursor.keyword("ALTER") && cursor.keyword("TABLE")) {
        return None;
    }
    cursor.qualified_name()?;

    if cursor.keyword("ADD") {
        if skip_columns_keyword(&mut cursor) {
            return Some("ALTER_TABLE_ADD_COLUMN");
        }
        return cursor
            .keyword("PARTITION")
            .then_some("ALTER_TABLE_ADD_PARTITION");
    }
    if cursor.keyword("DROP") {
        // DROP が受けるのは単数形の COLUMN だけ。複数形は本物が
        // `mismatched input 'COLUMNS'. Expecting: '.', 'DROP'` で弾く（2026-09-21 実測）ので、
        // ADD と違って `skip_columns_keyword` は使わない。
        if cursor.keyword("COLUMN") {
            return Some("ALTER_TABLE_DROP_COLUMN");
        }
        return cursor
            .keyword("PARTITION")
            .then_some("ALTER_TABLE_DROP_PARTITION");
    }
    // REPLACE の値だけ単数形の COLUMN で終わる（2026-09-21 実測）。受けるのは本物に構文がある
    // 複数形の COLUMNS だけで、単数形の `REPLACE COLUMN` は本物が StartQueryExecution で
    // `mismatched input 'REPLACE'` の構文エラーにする（2026-09-24 実測。#146）ので分類しない。
    if cursor.keyword("REPLACE") {
        return cursor
            .keyword("COLUMNS")
            .then_some("ALTER_TABLE_REPLACE_COLUMN");
    }
    // RENAME TO だけ分類する。RENAME COLUMN は本物に構文が無い（2026-09-21 実測）ので、
    // `TO` を要求すればそのまま None に落ちる。
    if cursor.keyword("RENAME") {
        return cursor.keyword("TO").then_some("ALTER_TABLE_RENAME");
    }
    if cursor.keyword("SET") {
        if cursor.keyword("TBLPROPERTIES") {
            return Some("ALTER_TABLE_PROPERTIES");
        }
        if cursor.keyword("LOCATION") {
            return Some("ALTER_TABLE_SET_LOCATION");
        }
    }
    None
}

/// `COLUMN` と `COLUMNS` の両方を受け付ける（`ADD` だけが使う。`DROP` は本物が単数形しか
/// 受けないので使わない）。長い方から試す
/// （先に `COLUMN` を試すと `COLUMNS` の `S` が識別子の文字として境界チェックに引っかかり None になる）。
fn skip_columns_keyword(cursor: &mut athena_sql::Cursor) -> bool {
    cursor.keyword("COLUMNS") || cursor.keyword("COLUMN")
}

#[cfg(test)]
mod tests;
