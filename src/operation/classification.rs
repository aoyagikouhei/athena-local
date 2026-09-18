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
        "ALTER"
            if word(1) == "TABLE"
                && words.iter().any(|w| w == "ADD")
                && words.iter().any(|w| w.starts_with("COLUMN")) =>
        {
            "ALTER_TABLE_ADD_COLUMN"
        }
        _ => return None,
    })
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
            "ALTER TABLE t RENAME TO u",
            "CALL x()",
            "SET SESSION a = 1",
            "",
        ] {
            assert_eq!(substatement_type(query), None, "{query:?}");
        }
        assert_eq!(statement_type(""), "UTILITY");
    }
}
