//! Iceberg のテーブルの DESCRIBE の `# Partition spec:` の下の行を作る（#173）。
//! Trino の DESCRIBE にはパーティションの変換が出ないので、Trino の `SHOW CREATE TABLE` の
//! `partitioning = ARRAY[...]` を読み、本物の `field_name`／`field_transform`／`column_name` にする
//! （2026-09-24 実測 d2・d8）。

use athena_sql::{skip_quoted, unquote};

/// Trino の `SHOW CREATE TABLE` の DDL から `partitioning = ARRAY['s', 'bucket(n, 4)', 'day(ts)']` の
/// 要素（`''` は `'` に戻す）を取り出す。`partitioning` が無ければ空。
/// 文字列リテラルと引用符付きの識別子は `catalog::skip_quoted` で読み飛ばすので、コメントや
/// `location` の中の `partitioning` は読まない。
pub(super) fn parse_partitioning(ddl: &str) -> Vec<String> {
    let bytes = ddl.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            b'\'' | b'"' => index = skip_quoted(bytes, index),
            byte if is_identifier(byte) => {
                let start = index;
                while index < bytes.len() && is_identifier(bytes[index]) {
                    index += 1;
                }
                if &ddl[start..index] == "partitioning"
                    && let Some(elements) = array_elements(&ddl[index..])
                {
                    return elements;
                }
            }
            _ => index += 1,
        }
    }
    Vec::new()
}

fn is_identifier(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_'
}

/// `= ARRAY['a', 'b']` の要素。形が違えば None。
fn array_elements(rest: &str) -> Option<Vec<String>> {
    let rest = rest.trim_start().strip_prefix('=')?.trim_start();
    let rest = rest.strip_prefix("ARRAY")?.trim_start().strip_prefix('[')?;
    let bytes = rest.as_bytes();
    let mut elements = Vec::new();
    let mut index = 0;
    loop {
        while matches!(bytes.get(index), Some(b' ' | b'\n' | b',')) {
            index += 1;
        }
        match bytes.get(index)? {
            b'\'' => {
                let end = skip_quoted(bytes, index);
                elements.push(rest.get(index + 1..end - 1)?.replace("''", "'"));
                index = end;
            }
            b']' => return Some(elements),
            _ => return None,
        }
    }
}

/// Trino のパーティションの綴り 1 つを、本物の行の (`field_name`, `field_transform`, `column_name`) にする。
/// 実測した 7 種だけ写す（2026-09-24 実測 d2・d8）: 列そのまま → identity、`bucket(col, N)` → `col_bucket`／
/// `bucket[N]`、`truncate(col, W)` → `col_trunc`／`truncate[W]`、`year`／`month`／`day`／`hour(col)` →
/// `col_<変換>`／`<変換>`。Trino は引数を列が先に綴る（本物の `bucket(4, n)` は Trino では `bucket(n, 4)`）。
/// 引用符付きの列名は引用符を外す。ほかの変換（`void` など）は未実測なので None（行を出さない）。
pub(super) fn partition_row(spec: &str) -> Option<(String, String, String)> {
    if spec.starts_with('"') || !spec.contains('(') {
        let column = unquote(spec);
        return Some((column.clone(), "identity".to_string(), column));
    }
    let (transform, arguments) = spec.strip_suffix(')')?.split_once('(')?;
    let (field_name, field_transform, column) = match transform {
        "bucket" | "truncate" => {
            let (column, width) = arguments.rsplit_once(',')?;
            let suffix = if transform == "bucket" {
                "bucket"
            } else {
                "trunc"
            };
            (suffix, format!("{transform}[{}]", width.trim()), column)
        }
        "year" | "month" | "day" | "hour" => (transform, transform.to_string(), arguments),
        _ => return None,
    };
    let column = unquote(column.trim());
    Some((format!("{column}_{field_name}"), field_transform, column))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Trino 482 の Iceberg のテーブルの `SHOW CREATE TABLE` の形。
    fn ddl(with: &str) -> String {
        format!(
            "CREATE TABLE iceberg.ns.t (\n   n integer COMMENT 'partitioning = ARRAY[''x'']',\n   s varchar\n)\nWITH (\n{with}\n)"
        )
    }

    #[test]
    fn parse_partitioning_は_partitioning_が無ければ空() {
        assert!(
            parse_partitioning(&ddl(
                "   format = 'PARQUET',\n   location = 's3://b/partitioning'"
            ))
            .is_empty()
        );
        assert!(parse_partitioning(&ddl("   partitioning = ARRAY[]")).is_empty());
    }

    #[test]
    fn parse_partitioning_は_1_つの要素を取り出す() {
        assert_eq!(
            parse_partitioning(&ddl("   format = 'PARQUET',\n   partitioning = ARRAY['s']")),
            ["s"]
        );
    }

    #[test]
    fn parse_partitioning_は複数の要素を順に取り出す() {
        for array in [
            "ARRAY['s','bucket(n, 4)','day(ts)']",
            "ARRAY['s', 'bucket(n, 4)', 'day(ts)']",
        ] {
            let with = format!(
                "   format = 'PARQUET',\n   partitioning = {array},\n   sorted_by = ARRAY['n']"
            );
            assert_eq!(
                parse_partitioning(&ddl(&with)),
                ["s", "bucket(n, 4)", "day(ts)"],
                "{array}"
            );
        }
    }

    /// 文字列の中の `''` は `'` に戻し、引用符付きの列名の `"` はそのまま残す（`partition_row` が外す）。
    #[test]
    fn parse_partitioning_は_二重の単引用符を戻し引用符付きの列名を残す() {
        assert_eq!(
            parse_partitioning(&ddl(
                "   partitioning = ARRAY['\"it''s\"','bucket(\"a,b\", 8)']"
            )),
            ["\"it's\"", "bucket(\"a,b\", 8)"]
        );
    }

    #[test]
    fn parse_partitioning_は_with_より前の引用符付き識別子の中の単引用符に惑わされない() {
        // 列名 `"it's"` の `'` を文字列リテラルの始まりと読むと、`ARRAY['s'` までを 1 つのリテラルと
        // 取り違える。二重引用符の中は `skip_quoted` で丸ごと読み飛ばす。
        assert_eq!(
            parse_partitioning(
                "CREATE TABLE iceberg.ns.t (\n   \"it's\" integer,\n   s varchar\n)\nWITH (\n   partitioning = ARRAY['s']\n)"
            ),
            ["s"]
        );
    }

    fn row(field_name: &str, transform: &str, column: &str) -> Option<(String, String, String)> {
        Some((
            field_name.to_string(),
            transform.to_string(),
            column.to_string(),
        ))
    }

    /// 本物の d2・d8（2026-09-24 実測）の 7 種。左は Trino の `partitioning` の綴り（引数は列が先）。
    #[test]
    fn partition_row_は実測した_7_種の変換を本物の行にする() {
        for (spec, expected) in [
            ("s", row("s", "identity", "s")),
            ("bucket(n, 4)", row("n_bucket", "bucket[4]", "n")),
            ("truncate(s, 3)", row("s_trunc", "truncate[3]", "s")),
            ("year(ts)", row("ts_year", "year", "ts")),
            ("month(d2)", row("d2_month", "month", "d2")),
            ("day(ts)", row("ts_day", "day", "ts")),
            ("hour(ts2)", row("ts2_hour", "hour", "ts2")),
        ] {
            assert_eq!(partition_row(spec), expected, "{spec}");
        }
    }

    #[test]
    fn partition_row_は引用符付きの列名の引用符を外す() {
        assert_eq!(partition_row("\"it's\""), row("it's", "identity", "it's"));
        assert_eq!(
            partition_row("bucket(\"a,b\", 8)"),
            row("a,b_bucket", "bucket[8]", "a,b")
        );
        assert_eq!(partition_row("day(\"T\")"), row("T_day", "day", "T"));
    }

    /// 測っていない変換（`void` など）は行を出さない。
    #[test]
    fn partition_row_は測っていない変換を_none_にする() {
        for spec in ["void(s)", "bucket(n)", "unknown(s, 1)"] {
            assert_eq!(partition_row(spec), None, "{spec}");
        }
    }
}
