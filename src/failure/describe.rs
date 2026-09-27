//! `DESCRIBE EXTENDED`／`FORMATTED` と、列・PARTITION を指定した `DESCRIBE` に本物が返した失敗の文言
//! （2026-09-27 実測。#275）。StateChangeReason と AthenaError.ErrorMessage は同じ文字列だった。

use super::{Failure, SYSTEM, USER};

impl Failure {
    /// 無い表（e_x・f_x。EXTENDED でも FORMATTED でも同じ）。名前は DB を付けない表の名前だけ。
    pub fn describe_table_not_found(table: &str) -> Self {
        Self::describe(
            format!("FAILED: SemanticException [Error 10001]: Table not found {table}"),
            USER,
            1006,
        )
    }

    /// 無い DB（z3）。
    pub fn describe_database_not_found(database: &str) -> Self {
        Self::describe(
            format!("FAILED: SemanticException [Error 10072]: Database does not exist: {database}"),
            USER,
            1006,
        )
    }

    /// 無い列（z4）。`columns` は表の列の並び（本物は `[0:n, 1:s]` と 0 から番号を付けた）。本物だけ
    /// ErrorCategory が 1（SYSTEM）・ErrorType が 1003 だった。
    pub fn describe_column_not_found(column: &str, columns: &[String]) -> Self {
        let listed = columns
            .iter()
            .enumerate()
            .map(|(index, name)| format!("{index}:{name}"))
            .collect::<Vec<_>>()
            .join(", ");
        Self::describe(
            format!(
                "FAILED: Execution Error, return code 1 from org.apache.hadoop.hive.ql.exec.DDLTask. cannot find field {column} from [{listed}]"
            ),
            SYSTEM,
            1003,
        )
    }

    /// 無いパーティション（z5。測ったのはキーが 1 つの形だけ）。
    pub fn describe_partition_not_found(key: &str, value: &str) -> Self {
        Self::describe(
            format!(
                "FAILED: SemanticException [Error 10006]: Partition not found {{{key}={value}}}"
            ),
            USER,
            1006,
        )
    }

    /// Iceberg 表への `DESCRIBE EXTENDED`（列指定も同じ。e_i・p6）。本体も `.metadata` も置かない。
    pub fn describe_iceberg_extended() -> Self {
        Self::describe(
            "EXTENDED keyword is not supported for Iceberg tables.".to_string(),
            USER,
            1100,
        )
    }

    /// Iceberg 表の列への `DESCRIBE FORMATTED`（p7）。
    pub fn describe_iceberg_formatted_column() -> Self {
        Self::describe(
            "FORMATTED keyword is not supported for Iceberg table columns.".to_string(),
            USER,
            1100,
        )
    }

    /// Iceberg 表への PARTITION 指定の `DESCRIBE`（p8）。
    pub fn describe_iceberg_partition() -> Self {
        Self::describe(
            "PARTITION keyword is not supported for Iceberg tables.".to_string(),
            USER,
            1100,
        )
    }

    fn describe(reason: String, category: i32, error_type: i32) -> Self {
        Self {
            reason,
            error_message: None,
            category,
            error_type,
            retryable: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn 無い列の文言は表の列を_0_から番号を付けて並べ_カテゴリは_system_で_1003() {
        let failure =
            Failure::describe_column_not_found("nocol", &["n".to_string(), "s".to_string()]);
        assert_eq!(
            failure.reason,
            "FAILED: Execution Error, return code 1 from org.apache.hadoop.hive.ql.exec.DDLTask. cannot find field nocol from [0:n, 1:s]"
        );
        assert_eq!((failure.category, failure.error_type), (SYSTEM, 1003));
    }

    #[test]
    fn 無いパーティションの文言はキーと値を波括弧で囲む() {
        let failure = Failure::describe_partition_not_found("p", "nope");
        assert_eq!(
            failure.reason,
            "FAILED: SemanticException [Error 10006]: Partition not found {p=nope}"
        );
        assert_eq!((failure.category, failure.error_type), (USER, 1006));
    }
}
