//! SQL の先頭のキーワードから StatementType / SubstatementType を判定する。

/// 先頭の空白とコメントを読み飛ばしてから大文字にした単語の並びにする（2026-09-18 実測）。
pub(super) fn words(query: &str) -> Vec<String> {
    crate::catalog::skip_leading_trivia(query)
        .split_whitespace()
        .map(|word| word.trim_start_matches('(').to_uppercase())
        .collect()
}

/// 本物の StatementType（2026-09-14 実測）。EXPLAIN と VACUUM は DML、OPTIMIZE は DDL。
/// 先頭のコメントは `words()` が読み飛ばして判定する（2026-09-18 実測）。
pub(super) fn statement_type(query: &str) -> &'static str {
    let words = words(query);
    match words.first().map(String::as_str).unwrap_or_default() {
        "SELECT" | "WITH" | "VALUES" | "INSERT" | "UPDATE" | "DELETE" | "MERGE" | "EXPLAIN"
        | "VACUUM" => "DML",
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
        "SELECT" | "WITH" | "VALUES" => "SELECT",
        "INSERT" => "INSERT",
        "UPDATE" => "UPDATE",
        "DELETE" => "DELETE",
        "MERGE" => "MERGE",
        "EXPLAIN" => "EXPLAIN",
        "DESCRIBE" => "DESCRIBE_TABLE",
        "VACUUM" => "VACUUM_TABLE",
        // Athena の OPTIMIZE は CTAS と同じ種類になる。
        "OPTIMIZE" => "CREATE_TABLE_AS_SELECT",
        "SHOW" => match (word(1), word(2)) {
            ("TABLES", _) => "SHOW_TABLES",
            ("DATABASES" | "SCHEMAS", _) => "SHOW_DATABASES",
            ("COLUMNS", _) => "SHOW_COLUMNS",
            ("CREATE", "TABLE") => "SHOW_CREATE_TABLE",
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
        // テーブル名は固定位置ではなく `catalog::skip_qualified_name` で読み飛ばしてから、
        // その後ろのキーワードで判定する（2026-09-21 実測で見つかった退行の修正。
        // `word(3)`／`word(4)` の固定位置だと、引用符付きテーブル名や修飾名が空白・コメントを
        // 挟むと語数がずれて None に落ちていた。`ALTER TABLE IF EXISTS ...` と
        // `RENAME COLUMN` は本物の Athena に構文が無い（mismatched input）ので、テーブル名の
        // 位置に "IF" や "RENAME" 相当の語しか無く変わらず None になる）。
        "ALTER" if word(1) == "TABLE" => alter_table_action(query)?,
        _ => return None,
    })
}

/// `ALTER TABLE` の後ろのテーブル名を `catalog::skip_qualified_name` で読み飛ばし、
/// その後ろのキーワードを 1 つずつ読み進めて ADD／DROP／REPLACE／RENAME／SET を判定する。
/// 本物が実行時に失敗する組み合わせ（REPLACE COLUMNS・ADD PARTITION × Iceberg、
/// RENAME TO × Hive）でも SubstatementType は同じ値で返るので、成否では分けない（2026-09-21 実測）。
/// `ALTER`／`TABLE` のキーワード自体は呼び出し元の `word(0)`／`word(1)` の guard で確定している。
///
/// キーワードの一致は `split_whitespace` の完全一致ではなく `skip_keyword` で確かめる。
/// そうしないと `TBLPROPERTIES('comment' = 'x')` のようにキーワードの直後に空白なしで
/// `(` や文字列リテラルが続く書き方を判定できない（3 本目のレビューで実測）。
fn alter_table_action(query: &str) -> Option<&'static str> {
    let after_alter = skip_keyword(query, "ALTER")?;
    let after_table = skip_keyword(after_alter, "TABLE")?;
    let name_start = after_table.len() - crate::catalog::skip_leading_trivia(after_table).len();
    let name_end = crate::catalog::skip_qualified_name(after_table, name_start);
    let rest = &after_table[name_end..];

    if let Some(after_add) = skip_keyword(rest, "ADD") {
        if skip_columns_keyword(after_add).is_some() {
            return Some("ALTER_TABLE_ADD_COLUMN");
        }
        return skip_keyword(after_add, "PARTITION").map(|_| "ALTER_TABLE_ADD_PARTITION");
    }
    if let Some(after_drop) = skip_keyword(rest, "DROP") {
        // DROP が受けるのは単数形の COLUMN だけ。複数形は本物が
        // `mismatched input 'COLUMNS'. Expecting: '.', 'DROP'` で弾く（2026-09-21 実測）ので、
        // ADD と違って `skip_columns_keyword` は使わない。
        if skip_keyword(after_drop, "COLUMN").is_some() {
            return Some("ALTER_TABLE_DROP_COLUMN");
        }
        return skip_keyword(after_drop, "PARTITION").map(|_| "ALTER_TABLE_DROP_PARTITION");
    }
    // REPLACE の値だけ単数形の COLUMN で終わる（2026-09-21 実測）。受けるのは本物に構文がある
    // 複数形の COLUMNS だけで、単数形は測っていないので分類しない。
    if let Some(after_replace) = skip_keyword(rest, "REPLACE") {
        return skip_keyword(after_replace, "COLUMNS").map(|_| "ALTER_TABLE_REPLACE_COLUMN");
    }
    // RENAME TO だけ分類する。RENAME COLUMN は本物に構文が無い（2026-09-21 実測）ので、
    // `TO` を要求すればそのまま None に落ちる。
    if let Some(after_rename) = skip_keyword(rest, "RENAME") {
        return skip_keyword(after_rename, "TO").map(|_| "ALTER_TABLE_RENAME");
    }
    if let Some(after_set) = skip_keyword(rest, "SET") {
        if skip_keyword(after_set, "TBLPROPERTIES").is_some() {
            return Some("ALTER_TABLE_PROPERTIES");
        }
        if skip_keyword(after_set, "LOCATION").is_some() {
            return Some("ALTER_TABLE_SET_LOCATION");
        }
    }
    None
}

/// `COLUMN` と `COLUMNS` の両方を受け付ける（`ADD` だけが使う。`DROP` は本物が単数形しか
/// 受けないので使わない）。長い方から試す
/// （先に `COLUMN` を試すと `COLUMNS` の `S` が識別子の文字として境界チェックに引っかかり None になる）。
fn skip_columns_keyword(input: &str) -> Option<&str> {
    skip_keyword(input, "COLUMNS").or_else(|| skip_keyword(input, "COLUMN"))
}

/// 先頭の空白・コメントを読み飛ばしてからキーワードを 1 語ぶん読み飛ばす。大文字小文字は
/// 区別せず、続きが識別子の文字（英数字・`_`）なら別の語（`COLUMN` に対する `COLUMNS` など）
/// とみなして一致させない。続きが `(` や文字列リテラルの `'` など識別子でない文字なら
/// 空白が無くても一致させる（`TBLPROPERTIES(...)` のような書き方。3 本目のレビューで実測）。
fn skip_keyword<'a>(input: &'a str, keyword: &str) -> Option<&'a str> {
    let trimmed = crate::catalog::skip_leading_trivia(input);
    if trimmed.len() < keyword.len() || !trimmed.is_char_boundary(keyword.len()) {
        return None;
    }
    let (head, tail) = trimmed.split_at(keyword.len());
    if !head.eq_ignore_ascii_case(keyword) {
        return None;
    }
    if tail.starts_with(|c: char| c.is_ascii_alphanumeric() || c == '_') {
        return None;
    }
    Some(tail)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn statement_type_は先頭のキーワードで決まる() {
        assert_eq!(statement_type("SELECT 1"), "DML");
        assert_eq!(statement_type("  insert into t values (1)"), "DML");
        assert_eq!(statement_type("MERGE INTO t USING s ON x"), "DML");
        assert_eq!(statement_type("CREATE TABLE t AS SELECT 1"), "DDL");
        assert_eq!(statement_type("DROP TABLE t"), "DDL");
        assert_eq!(statement_type("SET SESSION x = 1"), "UTILITY");
        assert_eq!(statement_type("VALUES 1"), "DML");
        assert_eq!(statement_type("DESCRIBE t"), "UTILITY");
        assert_eq!(statement_type("EXPLAIN SELECT 1"), "DML");
        assert_eq!(statement_type("VACUUM t"), "DML");
        assert_eq!(
            statement_type("OPTIMIZE t REWRITE DATA USING BIN_PACK"),
            "DDL"
        );
        assert_eq!(statement_type("SHOW TABLES"), "UTILITY");
        // 先頭のコメントは読み飛ばして判定する（2026-09-18 実測）。
        assert_eq!(statement_type("-- c\nSELECT 1"), "DML");
        assert_eq!(statement_type("/* c */ SHOW TABLES"), "UTILITY");
    }

    #[test]
    fn substatement_type_は実測した文の種類を返す() {
        for (query, expected) in [
            ("SELECT 1", "SELECT"),
            ("WITH x AS (SELECT 1 AS n) SELECT * FROM x", "SELECT"),
            ("VALUES 1", "SELECT"),
            ("INSERT INTO t SELECT 'a', 1", "INSERT"),
            ("UPDATE t SET a = 1", "UPDATE"),
            ("DELETE FROM t", "DELETE"),
            ("MERGE INTO t USING s ON t.id = s.id", "MERGE"),
            ("EXPLAIN SELECT 1", "EXPLAIN"),
            ("DESCRIBE t", "DESCRIBE_TABLE"),
            ("VACUUM t", "VACUUM_TABLE"),
            (
                "OPTIMIZE t REWRITE DATA USING BIN_PACK",
                "CREATE_TABLE_AS_SELECT",
            ),
            ("SHOW TABLES IN db", "SHOW_TABLES"),
            ("SHOW DATABASES LIKE 'x'", "SHOW_DATABASES"),
            ("SHOW SCHEMAS", "SHOW_DATABASES"),
            ("SHOW COLUMNS IN db.t", "SHOW_COLUMNS"),
            ("SHOW CREATE TABLE t", "SHOW_CREATE_TABLE"),
            ("CREATE DATABASE IF NOT EXISTS db", "CREATE_DATABASE"),
            ("CREATE SCHEMA IF NOT EXISTS db", "CREATE_DATABASE"),
            ("CREATE TABLE t (id string)", "CREATE_TABLE"),
            (
                "CREATE TABLE c WITH (table_type = 'ICEBERG') AS SELECT * FROM t",
                "CREATE_TABLE_AS_SELECT",
            ),
            ("CREATE VIEW v AS SELECT 1 AS n", "CREATE_VIEW"),
            ("CREATE OR REPLACE VIEW v AS SELECT 1 AS n", "CREATE_VIEW"),
            ("DROP TABLE IF EXISTS t", "DROP_TABLE"),
            ("DROP VIEW IF EXISTS v", "DROP_VIEW"),
            ("DROP DATABASE IF EXISTS db CASCADE", "DROP_DATABASE"),
            (
                "ALTER TABLE t ADD COLUMNS (c string)",
                "ALTER_TABLE_ADD_COLUMN",
            ),
            (
                "ALTER TABLE t ADD COLUMN c varchar",
                "ALTER_TABLE_ADD_COLUMN",
            ),
            // TBLPROPERTIES の値に add と column という語が含まれても
            // ALTER_TABLE_PROPERTIES になる（全文走査ではなく位置固定で判定する。2026-09-21 実測）。
            (
                "ALTER TABLE t SET TBLPROPERTIES ('comment' = 'remember to add column for region')",
                "ALTER_TABLE_PROPERTIES",
            ),
            ("ALTER TABLE t DROP COLUMN c", "ALTER_TABLE_DROP_COLUMN"),
            (
                "ALTER TABLE t SET LOCATION 's3://bucket/path/'",
                "ALTER_TABLE_SET_LOCATION",
            ),
            // 残りの亜種（2026-09-21 実測）。REPLACE の値だけ単数形の COLUMN で終わる。
            // 本物が実行時に失敗する組み合わせ（REPLACE COLUMNS・ADD PARTITION × Iceberg、
            // RENAME TO × Hive）でも、SubstatementType は同じ値で返る。
            (
                "ALTER TABLE t REPLACE COLUMNS (n int, s string)",
                "ALTER_TABLE_REPLACE_COLUMN",
            ),
            (
                "ALTER TABLE t ADD PARTITION (p = 'v')",
                "ALTER_TABLE_ADD_PARTITION",
            ),
            (
                "ALTER TABLE t DROP PARTITION (p = 'v')",
                "ALTER_TABLE_DROP_PARTITION",
            ),
            ("ALTER TABLE t RENAME TO u", "ALTER_TABLE_RENAME"),
            // 先頭のコメントは読み飛ばして判定する（2026-09-18 実測）。
            ("-- c\nSELECT 1", "SELECT"),
            // 2 語目以降も読み飛ばした後の並びから取る。`metadata_query_id` の
            // `("SHOW", "CREATE")` の分岐も同じ `words()` を使うので、ここで一緒に守る。
            ("-- c\nSHOW CREATE TABLE t", "SHOW_CREATE_TABLE"),
        ] {
            assert_eq!(substatement_type(query), Some(expected), "{query:?}");
        }

        // 実測していない形は省く。
        for query in [
            "SHOW FUNCTIONS",
            // RENAME COLUMN と IF EXISTS は本物の Athena に構文が無い（mismatched input。2026-09-21 実測）。
            "ALTER TABLE t RENAME COLUMN a TO b",
            "ALTER TABLE IF EXISTS t ADD COLUMNS (m int)",
            // DROP が受けるのは単数形の COLUMN だけ（複数形は mismatched input 'COLUMNS'.
            // Expecting: '.', 'DROP' で StartQueryExecution ごと弾かれる。2026-09-21 実測）。
            // ADD は複数形の COLUMNS を受けるので、単複の扱いは対称ではない。
            "ALTER TABLE t DROP COLUMNS c",
            "CALL x()",
            "SET SESSION a = 1",
            "",
        ] {
            assert_eq!(substatement_type(query), None, "{query:?}");
        }
        assert_eq!(statement_type(""), "UTILITY");
    }

    #[test]
    fn substatement_type_は_alter_table_の判定でテーブル名の後ろのトリビアを跨いでも正しく分類する()
    {
        // word(3)/word(4) の固定位置ではなく、テーブル名を読み飛ばした後ろの語で判定することを
        // 固定する（2026-09-21 実測、2 本のレビューが独立に確認した退行）。
        for (query, expected) in [
            (
                r#"ALTER TABLE "my table" ADD COLUMNS (c string)"#,
                "ALTER_TABLE_ADD_COLUMN",
            ),
            (
                "ALTER TABLE cat . ns . t ADD COLUMNS (m int)",
                "ALTER_TABLE_ADD_COLUMN",
            ),
            (
                "ALTER TABLE t -- comment\nADD COLUMN c int",
                "ALTER_TABLE_ADD_COLUMN",
            ),
        ] {
            assert_eq!(substatement_type(query), Some(expected), "{query:?}");
        }

        // 誤判定が復活していないことも合わせて固定する（全文走査に戻すと TBLPROPERTIES の
        // 値の中の "add column" で誤判定する。Phase 3a の主題）。
        for (query, expected) in [
            (
                r#"ALTER TABLE "my table" SET TBLPROPERTIES ('comment' = 'remember to add column for region')"#,
                "ALTER_TABLE_PROPERTIES",
            ),
            (
                "ALTER TABLE cat . ns . t SET TBLPROPERTIES ('comment' = 'add column')",
                "ALTER_TABLE_PROPERTIES",
            ),
        ] {
            assert_eq!(substatement_type(query), Some(expected), "{query:?}");
        }

        // DROP TABLE は影響を受けない。
        assert_eq!(
            substatement_type(r#"DROP TABLE "my table""#),
            Some("DROP_TABLE")
        );

        // 本物の Athena に構文が無い形は変わらず None。
        for query in [
            "ALTER TABLE IF EXISTS t ADD COLUMNS (m int)",
            "ALTER TABLE t RENAME COLUMN a TO b",
        ] {
            assert_eq!(substatement_type(query), None, "{query:?}");
        }
    }

    #[test]
    fn substatement_type_は_alter_table_のキーワードの直後に空白が無くても分類する() {
        // `SET TBLPROPERTIES('comment' = 'x')` のように、キーワードの直後に `(` や
        // 文字列リテラルが続く空白無しの書き方（3 本目のレビューが実測で確認）。
        for (query, expected) in [
            (
                "ALTER TABLE t SET TBLPROPERTIES('comment' = 'x')",
                "ALTER_TABLE_PROPERTIES",
            ),
            (
                "ALTER TABLE t SET LOCATION's3://bucket/path/'",
                "ALTER_TABLE_SET_LOCATION",
            ),
            ("ALTER TABLE t ADD COLUMNS(m int)", "ALTER_TABLE_ADD_COLUMN"),
        ] {
            assert_eq!(substatement_type(query), Some(expected), "{query:?}");
        }
    }

    // 以下の 3 つは、issue #49 で `skip_keyword` を `catalog.rs` へ統合する前に、着手前の挙動を
    // 境界入力で固定したもの。統合は挙動を変えないので red が成立しない。代わりにこれらが
    // 「統合の前後で結果が変わらない」ことの網になる。期待値は推測ではなく、着手前のコードに
    // 一時テストを足して実際に流した出力をそのまま写した。

    #[test]
    fn substatement_type_はトリビアが何個どこに挟まっても同じ結果になる() {
        for (query, expected) in [
            (
                "  ALTER TABLE t ADD COLUMNS (c int)",
                Some("ALTER_TABLE_ADD_COLUMN"),
            ),
            (
                "-- c\nALTER TABLE t ADD COLUMNS (c int)",
                Some("ALTER_TABLE_ADD_COLUMN"),
            ),
            // トリビアを 2 つ重ねる。
            (
                "ALTER TABLE t /* a */ -- b\nADD COLUMNS (c int)",
                Some("ALTER_TABLE_ADD_COLUMN"),
            ),
            (
                "ALTER TABLE t ADD /* c */ COLUMNS (c int)",
                Some("ALTER_TABLE_ADD_COLUMN"),
            ),
            (
                "ALTER TABLE t SET /* c */ TBLPROPERTIES ('a' = 'b')",
                Some("ALTER_TABLE_PROPERTIES"),
            ),
            // `ALTER` と `TABLE` の間のコメントだけは `alter_table_action` に届かない。
            // `words()` が `split_whitespace` で語を数えるので `word(1)` が `/*` になり、
            // 呼び出し元（`substatement_type`）の guard の時点で None に落ちるため
            // （`skip_keyword` の手前の話で、統合しても変わらない）。
            ("ALTER /* c */ TABLE t ADD COLUMNS (c int)", None),
        ] {
            assert_eq!(substatement_type(query), expected, "{query:?}");
        }
    }

    #[test]
    fn substatement_type_はキーワードの直後が識別子の文字かどうかで一致を決める() {
        for (query, expected) in [
            // 続きが英数字・`_` なら別の語とみなして一致させない。
            ("ALTER TABLE t ADDX COLUMNS (c int)", None),
            ("ALTER TABLE t ADD COLUMNS_X (c int)", None),
            ("ALTER TABLE t SET TBLPROPERTIESX ('a' = 'b')", None),
            // 続きが識別子の文字でなければ、空白が無くても一致する。
            (
                r#"ALTER TABLE t ADD COLUMN"c" int"#,
                Some("ALTER_TABLE_ADD_COLUMN"),
            ),
            (
                "ALTER TABLE t DROP COLUMN(c)",
                Some("ALTER_TABLE_DROP_COLUMN"),
            ),
        ] {
            assert_eq!(substatement_type(query), expected, "{query:?}");
        }
    }

    #[test]
    fn substatement_type_は大文字小文字を無視し多バイト文字と短い入力でも破綻しない() {
        for (query, expected) in [
            (
                "alter table t add columns (c int)",
                Some("ALTER_TABLE_ADD_COLUMN"),
            ),
            (
                "AlTeR TaBlE t sEt TbLpRoPeRtIeS ('a' = 'b')",
                Some("ALTER_TABLE_PROPERTIES"),
            ),
            // 多バイト文字の引用符付きテーブル名を `skip_qualified_name` で読み飛ばしてから、
            // その後ろのキーワードで判定する。
            (
                r#"ALTER TABLE "日本語" ADD COLUMNS (c int)"#,
                Some("ALTER_TABLE_ADD_COLUMN"),
            ),
            // テーブル名の後ろに何も無い／テーブル名すら無い入力でも panic せずに None を返す。
            ("ALTER TABLE t", None),
            ("ALTER TABLE", None),
        ] {
            assert_eq!(substatement_type(query), expected, "{query:?}");
        }
    }
}
