//! ExecutionParameters を Trino が実行できる SQL に組み立てる。
//!
//! Athena は値ごとに「式として読めて列参照を含まなければそのまま、そうでなければ
//! 文字列リテラル」に分類する（2026-09-14 に本番で実測）。Rust 側で SQL を解析する
//! 代わりに、分類は Trino に `SELECT (<値>)` を投げた結果で決める。

use crate::trino::{Outcome, QueryError};

/// 値を分類するための問い合わせ。
/// 括弧で包まないと `abc def` が `abc AS def`（別名付きの列）として通ってしまう。
pub fn probe_sql(value: &str) -> String {
    format!("SELECT ({value})")
}

/// 分類の問い合わせ結果から、USING に載せる形を決める。
///
/// - 構文エラー・列参照（識別子）→ 文字列リテラル
/// - 成功しても列が 1 つでない（`1) , (2` のように括弧を抜けた）→ 文字列リテラル
/// - それ以外（成功、未知の関数・型不一致などの意味エラー）→ そのまま。
///   意味エラーは本体の実行で同じく失敗し、本物と同じく FAILED になる。
pub fn bind(value: &str, probe: &Result<Outcome, QueryError>) -> String {
    let is_text = match probe {
        Ok(outcome) => outcome.columns.len() != 1,
        Err(error) => matches!(
            error.name.as_deref(),
            Some("SYNTAX_ERROR" | "COLUMN_NOT_FOUND")
        ),
    };

    if is_text {
        quote_literal(value)
    } else {
        value.to_string()
    }
}

/// SQL の文字列リテラルにする。
pub fn quote_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

/// パラメータがあれば `EXECUTE IMMEDIATE` で包む。無ければ SQL をそのまま返す。
/// `?` の位置は Trino のパーサが解決するので、リテラルやコメント中の `?` は置換されない。
pub fn to_trino_sql(query: &str, parameters: &[String]) -> String {
    if parameters.is_empty() {
        return query.to_string();
    }

    format!(
        "EXECUTE IMMEDIATE {} USING {}",
        quote_literal(query),
        parameters.join(", ")
    )
}

/// `?` の無い SQL に値を渡したときのエラーか。Athena はこの場合だけ値を黙って捨てる。
pub fn is_unused_parameters(error: &QueryError) -> bool {
    error.name.as_deref() == Some("INVALID_PARAMETER_USAGE")
        && error.message.contains("expected 0 but found")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::trino::Column;

    fn succeeded(column_count: usize) -> Result<Outcome, QueryError> {
        Ok(Outcome {
            columns: (0..column_count)
                .map(|i| Column {
                    name: format!("_col{i}"),
                    type_name: "integer".to_string(),
                    type_signature: None,
                })
                .collect(),
            ..Outcome::default()
        })
    }

    fn failed(name: &str, message: &str) -> Result<Outcome, QueryError> {
        Err(QueryError {
            name: Some(name.to_string()),
            error_type: None,
            message: message.to_string(),
        })
    }

    #[test]
    fn 分類の問い合わせは値を括弧で包む() {
        assert_eq!(probe_sql("abc def"), "SELECT (abc def)");
    }

    #[test]
    fn 構文エラーと列参照の値は文字列になる() {
        assert_eq!(
            bind("abc def", &failed("SYNTAX_ERROR", "mismatched input")),
            "'abc def'"
        );
        assert_eq!(
            bind("abc", &failed("COLUMN_NOT_FOUND", "Column 'abc'")),
            "'abc'"
        );
        assert_eq!(
            bind("it's", &failed("SYNTAX_ERROR", "mismatched input")),
            "'it''s'"
        );
    }

    #[test]
    fn 式として読める値はそのまま載る() {
        assert_eq!(bind("1 + 1", &succeeded(1)), "1 + 1");
        assert_eq!(bind("'it''s'", &succeeded(1)), "'it''s'");
    }

    #[test]
    fn 意味エラーの値は文字列にせずそのまま載る() {
        // 本体の実行で同じエラーになり FAILED になる（本物と同じ）。
        assert_eq!(
            bind(
                "nosuchfunc(1)",
                &failed("FUNCTION_NOT_FOUND", "not registered")
            ),
            "nosuchfunc(1)"
        );
        assert_eq!(
            bind(
                "1 OR 1=1",
                &failed("TYPE_MISMATCH", "must evaluate to a boolean")
            ),
            "1 OR 1=1"
        );
    }

    #[test]
    fn 接続失敗など_error_name_の無い失敗はそのまま載る() {
        let probe = Err(QueryError {
            name: None,
            error_type: None,
            message: "trino への接続に失敗しました".to_string(),
        });
        assert_eq!(bind("1", &probe), "1");
    }

    #[test]
    fn 括弧を抜けて列が増える値は文字列になる() {
        assert_eq!(bind("1) , (2", &succeeded(2)), "'1) , (2'");
    }

    #[test]
    fn 文字列リテラルは単一引用符を二重にして包む() {
        assert_eq!(quote_literal("abc"), "'abc'");
        assert_eq!(quote_literal("it's"), "'it''s'");
        assert_eq!(quote_literal(""), "''");
    }

    #[test]
    fn パラメータが無ければ_sql_はそのまま() {
        assert_eq!(to_trino_sql("SELECT ?", &[]), "SELECT ?");
    }

    #[test]
    fn パラメータがあれば_execute_immediate_で包む() {
        assert_eq!(
            to_trino_sql(
                "SELECT * FROM t WHERE a = ? AND b = ?",
                &["'x'".to_string(), "1".to_string()]
            ),
            "EXECUTE IMMEDIATE 'SELECT * FROM t WHERE a = ? AND b = ?' USING 'x', 1"
        );
    }

    #[test]
    fn 元の_sql_の単一引用符は二重になり改行とコメントは残る() {
        assert_eq!(
            to_trino_sql(
                "SELECT *\nFROM t -- ?\nWHERE c = 'it''s' AND d = ?",
                &["1".to_string()]
            ),
            "EXECUTE IMMEDIATE 'SELECT *\nFROM t -- ?\nWHERE c = ''it''''s'' AND d = ?' USING 1"
        );
    }

    #[test]
    fn 余剰パラメータのエラーだけを見分ける() {
        let unused = QueryError {
            name: Some("INVALID_PARAMETER_USAGE".to_string()),
            error_type: None,
            message: "line 1:20: Incorrect number of parameters: expected 0 but found 1"
                .to_string(),
        };
        let mismatch = QueryError {
            name: Some("INVALID_PARAMETER_USAGE".to_string()),
            error_type: None,
            message: "line 1:20: Incorrect number of parameters: expected 1 but found 2"
                .to_string(),
        };
        let other = QueryError {
            name: Some("SYNTAX_ERROR".to_string()),
            error_type: None,
            message: "expected 0 but found 1".to_string(),
        };

        assert!(is_unused_parameters(&unused));
        assert!(!is_unused_parameters(&mismatch));
        assert!(!is_unused_parameters(&other));
    }
}
