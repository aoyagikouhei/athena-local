//! Trino の型から Athena の型名・Precision・Scale・CaseSensitive を決める。

use crate::athena::ColumnInfo;

/// ColumnInfo の Type / Precision / Scale / CaseSensitive（2026-09-14 に本番 Athena で実測）。
struct AthenaType {
    name: String,
    precision: i64,
    scale: i64,
    case_sensitive: bool,
}

/// 上限の無い varchar の長さ（Trino も Athena も同じ値）。
const UNBOUNDED_VARCHAR: i64 = 2_147_483_647;

/// Trino の typeSignature から Athena の型の見え方を作る。無ければ型名の文字列から基底名だけを取る。
fn athena_type(column: &crate::trino::Column) -> AthenaType {
    let signature = column.type_signature.as_ref();
    let raw_type = super::value_type::raw_type(signature)
        .map(str::to_string)
        .unwrap_or_else(|| base_type_name(&column.type_name));
    // 引数の数値（varchar(3) の 3、decimal(10, 2) の 10 と 2）。
    let argument = |index: usize| {
        signature?
            .get("arguments")?
            .get(index)?
            .get("value")?
            .as_i64()
    };

    let (name, precision, scale, case_sensitive) = match raw_type.as_str() {
        "tinyint" => (raw_type.as_str(), 3, 0, false),
        "smallint" => (raw_type.as_str(), 5, 0, false),
        "integer" => (raw_type.as_str(), 10, 0, false),
        "bigint" => (raw_type.as_str(), 19, 0, false),
        // Athena は real を float と呼び、精度は double と同じ 17 を返す。
        "real" => ("float", 17, 0, false),
        "double" => (raw_type.as_str(), 17, 0, false),
        "decimal" => (
            raw_type.as_str(),
            argument(0).unwrap_or(0),
            argument(1).unwrap_or(0),
            false,
        ),
        "varchar" => (
            raw_type.as_str(),
            argument(0).unwrap_or(UNBOUNDED_VARCHAR),
            0,
            true,
        ),
        "char" => (raw_type.as_str(), argument(0).unwrap_or(1), 0, true),
        "varbinary" => (raw_type.as_str(), 1_073_741_824, 0, false),
        // 日時は実際の精度によらず 3。
        "timestamp" | "timestamp with time zone" | "time" | "time with time zone" => {
            (raw_type.as_str(), 3, 0, false)
        }
        _ => (raw_type.as_str(), 0, 0, false),
    };

    AthenaType {
        name: name.to_string(),
        precision,
        scale,
        case_sensitive,
    }
}

/// `decimal(10, 2)` → `decimal`、`timestamp(3) with time zone` → `timestamp with time zone`、
/// `INTERVAL DAY TO SECOND` → `interval day to second`。括弧の中を落として小文字にする。
fn base_type_name(type_name: &str) -> String {
    let mut depth = 0;
    let mut base = String::new();
    for c in type_name.chars() {
        match c {
            '(' => depth += 1,
            ')' => depth -= 1,
            _ if depth == 0 => base.push(c),
            _ => {}
        }
    }
    base.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}

pub(super) fn to_column_info(column: &crate::trino::Column) -> ColumnInfo {
    let athena_type = athena_type(column);
    ColumnInfo {
        name: column.name.clone(),
        label: column.name.clone(),
        type_name: athena_type.name,
        nullable: "UNKNOWN".to_string(),
        case_sensitive: athena_type.case_sensitive,
        catalog_name: "hive".to_string(),
        schema_name: String::new(),
        table_name: String::new(),
        precision: athena_type.precision,
        scale: athena_type.scale,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::Value;

    use super::*;

    /// Trino 482 が返す typeSignature を組み立てる（引数は LONG のものだけ）。
    fn column_with(type_name: &str, raw_type: &str, arguments: &[i64]) -> crate::trino::Column {
        let arguments: Vec<Value> = arguments
            .iter()
            .map(|value| serde_json::json!({ "kind": "LONG", "value": value }))
            .collect();
        crate::trino::Column {
            name: "c".to_string(),
            type_name: type_name.to_string(),
            type_signature: Some(
                serde_json::json!({ "rawType": raw_type, "arguments": arguments }),
            ),
        }
    }

    #[test]
    fn 列情報の型は_athena_の実測と同じになる() {
        // 左は Trino 482 の type と typeSignature、右は同じ値の本番 Athena の ColumnInfo。
        for (type_name, raw_type, arguments, expected) in [
            ("tinyint", "tinyint", &[][..], ("tinyint", 3, 0, false)),
            ("smallint", "smallint", &[], ("smallint", 5, 0, false)),
            ("integer", "integer", &[], ("integer", 10, 0, false)),
            ("bigint", "bigint", &[], ("bigint", 19, 0, false)),
            ("real", "real", &[], ("float", 17, 0, false)),
            ("double", "double", &[], ("double", 17, 0, false)),
            (
                "decimal(10, 2)",
                "decimal",
                &[10, 2],
                ("decimal", 10, 2, false),
            ),
            (
                "decimal(38, 0)",
                "decimal",
                &[38, 0],
                ("decimal", 38, 0, false),
            ),
            ("varchar(3)", "varchar", &[3], ("varchar", 3, 0, true)),
            (
                "varchar",
                "varchar",
                &[2147483647],
                ("varchar", 2147483647, 0, true),
            ),
            ("char(5)", "char", &[5], ("char", 5, 0, true)),
            ("boolean", "boolean", &[], ("boolean", 0, 0, false)),
            ("date", "date", &[], ("date", 0, 0, false)),
            (
                "timestamp(0)",
                "timestamp",
                &[0],
                ("timestamp", 3, 0, false),
            ),
            (
                "timestamp(6)",
                "timestamp",
                &[6],
                ("timestamp", 3, 0, false),
            ),
            (
                "timestamp(3) with time zone",
                "timestamp with time zone",
                &[3],
                ("timestamp with time zone", 3, 0, false),
            ),
            ("time(3)", "time", &[3], ("time", 3, 0, false)),
            (
                "varbinary",
                "varbinary",
                &[],
                ("varbinary", 1073741824, 0, false),
            ),
            ("uuid", "uuid", &[], ("uuid", 0, 0, false)),
            ("json", "json", &[], ("json", 0, 0, false)),
            (
                "INTERVAL DAY TO SECOND",
                "interval day to second",
                &[],
                ("interval day to second", 0, 0, false),
            ),
            (
                "INTERVAL YEAR TO MONTH",
                "interval year to month",
                &[],
                ("interval year to month", 0, 0, false),
            ),
            ("ipaddress", "ipaddress", &[], ("ipaddress", 0, 0, false)),
        ] {
            let info = to_column_info(&column_with(type_name, raw_type, arguments));
            assert_eq!(
                (
                    info.type_name.as_str(),
                    info.precision,
                    info.scale,
                    info.case_sensitive
                ),
                expected,
                "{type_name}"
            );
            assert_eq!(
                (
                    info.catalog_name.as_str(),
                    info.schema_name.as_str(),
                    info.table_name.as_str()
                ),
                ("hive", "", "")
            );
        }
    }

    #[test]
    fn 複合型の列は基底名だけになる() {
        // array / map / row の引数は TYPE / NAMED_TYPE で、数値ではない。
        for (type_name, raw_type) in [
            ("array(integer)", "array"),
            ("map(varchar(1), integer)", "map"),
            ("row(id integer, name varchar)", "row"),
        ] {
            let column = crate::trino::Column {
                name: "c".to_string(),
                type_name: type_name.to_string(),
                type_signature: Some(
                    serde_json::json!({ "rawType": raw_type, "arguments": [{ "kind": "TYPE", "value": {} }] }),
                ),
            };
            let info = to_column_info(&column);
            assert_eq!(
                (info.type_name.as_str(), info.precision, info.scale),
                (raw_type, 0, 0)
            );
        }
    }

    #[test]
    fn 型情報が無ければ型名の文字列から基底名を取る() {
        for (type_name, expected) in [
            ("decimal(10, 2)", "decimal"),
            ("array(timestamp(6))", "array"),
            ("timestamp(3) with time zone", "timestamp with time zone"),
            ("INTERVAL DAY TO SECOND", "interval day to second"),
            ("uuid", "uuid"),
        ] {
            assert_eq!(base_type_name(type_name), expected, "{type_name}");
        }

        let column = crate::trino::Column {
            name: "c".to_string(),
            type_name: "varchar".to_string(),
            type_signature: None,
        };
        let info = to_column_info(&column);
        assert_eq!(
            (info.type_name.as_str(), info.precision, info.case_sensitive),
            ("varchar", 2147483647, true)
        );
    }
}
