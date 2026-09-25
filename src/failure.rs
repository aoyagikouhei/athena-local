//! FAILED になったクエリの理由。StateChangeReason と、GetQueryExecution の Status.AthenaError に使う。
//! Trino のエラー名と ErrorType の対応は、2026-09-14 に本番 Athena で実測したもの。

use crate::trino::QueryError;

/// AthenaError.ErrorCategory。
pub const SYSTEM: i32 = 1;
pub const USER: i32 = 2;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Failure {
    /// StateChangeReason と AthenaError.ErrorMessage（本物は同じ文字列を入れる）。
    pub reason: String,
    pub category: i32,
    pub error_type: i32,
    pub retryable: bool,
}

impl Failure {
    /// Trino が返したエラー、または Trino に届かなかったときのエラー。
    pub fn from_query_error(error: &QueryError) -> Self {
        let reason = error.to_string();
        let Some(name) = error.name.as_deref() else {
            // Trino に届かない・応答が読めないなど athena-local 側の失敗。本物に対応する事象は無いので
            // 「Internal service error」を当て、再試行で通りうるものとして返す。
            return Self {
                reason,
                category: SYSTEM,
                error_type: 100,
                retryable: true,
            };
        };

        // Trino は必ず errorType を付ける。無ければユーザーのエラーとして扱う。
        let category = match error.error_type.as_deref() {
            None | Some("USER_ERROR") => USER,
            Some(_) => SYSTEM,
        };
        let error_type = measured_error_type(name).unwrap_or(match category {
            // 実測していない名前は、Athena のエラー一覧の汎用の番号を当てる。
            USER => 1000, // User error
            _ => 200,     // Query engine had an internal error
        });

        Self {
            reason,
            category,
            error_type,
            // 実測したユーザーのエラーはすべて false。システムのエラーは実測していないので同じく false。
            retryable: false,
        }
    }

    /// 結果 CSV を置けなかった。本物は書き込みで FAILED にならないので、一覧の
    /// 「Failed to write query results to Amazon S3」を当て、再試行で通りうるものとして返す。
    pub fn result_write(reason: String) -> Self {
        Self {
            reason,
            category: SYSTEM,
            error_type: 401,
            retryable: true,
        }
    }
}

/// 実測した Trino のエラー名 → ErrorType。
fn measured_error_type(name: &str) -> Option<i32> {
    Some(match name {
        "DIVISION_BY_ZERO" => 1001,
        "TYPE_MISMATCH" => 1002,
        // 本物は構文エラーを StartQueryExecution で弾くので FAILED にはならない。
        // 一覧の「Syntax error」で、列が見つからないときと同じ番号。
        "SYNTAX_ERROR" | "COLUMN_NOT_FOUND" => 1006,
        // 本物は Context の Catalog が無いとき、表を読む SELECT・EXPLAIN をこの番号で失敗させた（2026-09-25 実測。#214）。
        "CATALOG_NOT_FOUND" => 1006,
        "INVALID_CAST_ARGUMENT" | "NUMERIC_VALUE_OUT_OF_RANGE" | "INVALID_PARAMETER_USAGE" => 1100,
        "INVALID_FUNCTION_ARGUMENT" => 1106,
        // 本物は Iceberg のテーブルを二重に作ると 1110 を返した（メッセージは Athena 独自）。
        "TABLE_ALREADY_EXISTS" => 1110,
        "NOT_SUPPORTED" => 1200,
        "TABLE_NOT_FOUND" | "SCHEMA_NOT_FOUND" => 1301,
        "FUNCTION_NOT_FOUND" => 1303,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn trino_error(name: &str, error_type: &str) -> QueryError {
        QueryError {
            name: Some(name.to_string()),
            message: "message".to_string(),
            error_type: Some(error_type.to_string()),
        }
    }

    #[test]
    fn 実測したエラー名はその_error_type_になる() {
        for (name, expected) in [
            ("COLUMN_NOT_FOUND", 1006),
            ("CATALOG_NOT_FOUND", 1006),
            ("TABLE_NOT_FOUND", 1301),
            ("SCHEMA_NOT_FOUND", 1301),
            ("FUNCTION_NOT_FOUND", 1303),
            ("TYPE_MISMATCH", 1002),
            ("INVALID_FUNCTION_ARGUMENT", 1106),
            ("DIVISION_BY_ZERO", 1001),
            ("INVALID_CAST_ARGUMENT", 1100),
            ("NUMERIC_VALUE_OUT_OF_RANGE", 1100),
            ("INVALID_PARAMETER_USAGE", 1100),
            ("NOT_SUPPORTED", 1200),
            ("TABLE_ALREADY_EXISTS", 1110),
        ] {
            let failure = Failure::from_query_error(&trino_error(name, "USER_ERROR"));
            assert_eq!(
                (failure.category, failure.error_type, failure.retryable),
                (USER, expected, false),
                "{name}"
            );
        }
    }

    #[test]
    fn 理由は_error_name_と_message_をつないだもの() {
        let failure = Failure::from_query_error(&trino_error("TABLE_NOT_FOUND", "USER_ERROR"));
        assert_eq!(failure.reason, "TABLE_NOT_FOUND: message");
    }

    #[test]
    fn 実測していない名前は汎用の番号になる() {
        let user = Failure::from_query_error(&trino_error("MISSING_COLUMN_ALIASES", "USER_ERROR"));
        assert_eq!(
            (user.category, user.error_type, user.retryable),
            (USER, 1000, false)
        );

        let system =
            Failure::from_query_error(&trino_error("GENERIC_INTERNAL_ERROR", "INTERNAL_ERROR"));
        assert_eq!(
            (system.category, system.error_type, system.retryable),
            (SYSTEM, 200, false)
        );
    }

    #[test]
    fn athena_local_側の失敗はシステムのエラーで再試行できる() {
        let unreachable = Failure::from_query_error(&QueryError {
            name: None,
            message: "trino への接続に失敗しました".to_string(),
            error_type: None,
        });
        assert_eq!(
            (
                unreachable.category,
                unreachable.error_type,
                unreachable.retryable
            ),
            (SYSTEM, 100, true)
        );

        let write = Failure::result_write("書けませんでした".to_string());
        assert_eq!(
            (write.category, write.error_type, write.retryable),
            (SYSTEM, 401, true)
        );
        assert_eq!(write.reason, "書けませんでした");
    }
}
