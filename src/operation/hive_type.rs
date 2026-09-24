//! Trino の型の綴りを、本物の Athena が Hive のテーブルの DESCRIBE に出す型の綴りに写す（#173）。
//! 写すのは実測した綴りだけ（2026-09-24 実測 d1。Trino 482 の綴りは同じ日に手元で確認）。
//! 測っていない型（`interval …`、`time`、`json`、`uuid`、`timestamp(3) with time zone` など）は
//! Trino の綴りのまま返す。

/// Trino の型の綴りを Hive の表記にする。`array`・`map`・`row` は中の型も写し、区切りは空白無しの
/// `,`・`:`（`map<string,int>`、`struct<aa:int,b:int>`。2026-09-24 実測）。
pub(super) fn hive_type(trino: &str) -> String {
    let Some((name, arguments)) = split_parameters(trino) else {
        return match trino {
            "integer" => "int",
            "real" => "float",
            "varchar" => "string",
            "varbinary" => "binary",
            _ => trino,
        }
        .to_string();
    };
    match (name, arguments.as_slice()) {
        ("timestamp", [_]) => "timestamp".to_string(),
        ("array", [element]) => format!("array<{}>", hive_type(element)),
        ("map", [key, value]) => format!("map<{},{}>", hive_type(key), hive_type(value)),
        ("row", fields) => struct_type(fields).unwrap_or_else(|| trino.to_string()),
        // `varchar(n)`・`char(n)`・`decimal(p,s)` は本物も同じ綴り。測っていない型もそのまま。
        _ => trino.to_string(),
    }
}

/// `row("a" T, "b" U)` のフィールドを `struct<a:T',b:U'>` にする。名前の無いフィールドがあれば
/// （`row(integer)`。測っていない）None。
fn struct_type(fields: &[&str]) -> Option<String> {
    let fields = fields
        .iter()
        .map(|field| {
            if !field.starts_with('"') {
                return None;
            }
            let end = crate::catalog::skip_quoted(field.as_bytes(), 0);
            let name = crate::catalog::unquote(&field[..end]);
            Some(format!("{name}:{}", hive_type(field[end..].trim())))
        })
        .collect::<Option<Vec<_>>>()?;
    Some(format!("struct<{}>", fields.join(",")))
}

/// `name(a, b)` を名前と、括弧の深さ 0 の `,` で分けた引数に分ける。二重引用符の中の `,`・括弧は数えない。
/// 閉じ括弧が末尾でなければ（`timestamp(3) with time zone` など）、括弧が無いときと同じく None。
fn split_parameters(trino: &str) -> Option<(&str, Vec<&str>)> {
    let open = trino.find('(')?;
    let bytes = trino.as_bytes();
    let mut arguments = Vec::new();
    let mut depth = 0;
    let mut start = open + 1;
    let mut index = open + 1;
    while index < bytes.len() {
        match bytes[index] {
            b'"' => {
                index = crate::catalog::skip_quoted(bytes, index);
                continue;
            }
            b'(' => depth += 1,
            b')' if depth == 0 => {
                if index + 1 != bytes.len() {
                    return None;
                }
                arguments.push(trino[start..index].trim());
                return Some((&trino[..open], arguments));
            }
            b')' => depth -= 1,
            b',' if depth == 0 => {
                arguments.push(trino[start..index].trim());
                start = index + 1;
            }
            _ => {}
        }
        index += 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 本物の d1（Hive、2026-09-24 実測）の 17 種。左は Trino 482 の DESCRIBE の `Type`。
    #[test]
    fn hive_type_は実測した_17_種を本物の綴りに写す() {
        for (trino, hive) in [
            ("integer", "int"),
            ("bigint", "bigint"),
            ("smallint", "smallint"),
            ("tinyint", "tinyint"),
            ("double", "double"),
            ("real", "float"),
            ("boolean", "boolean"),
            ("date", "date"),
            ("decimal(10,2)", "decimal(10,2)"),
            ("varchar(10)", "varchar(10)"),
            ("char(36)", "char(36)"),
            ("varchar", "string"),
            ("timestamp(3)", "timestamp"),
            ("varbinary", "binary"),
            ("array(varchar)", "array<string>"),
            ("map(varchar, integer)", "map<string,int>"),
            (r#"row("aa" integer, "b" integer)"#, "struct<aa:int,b:int>"),
        ] {
            assert_eq!(hive_type(trino), hive, "{trino}");
        }
    }

    #[test]
    fn hive_type_は_timestamp_の精度によらず_timestamp_にする() {
        for trino in ["timestamp(0)", "timestamp(6)", "timestamp(9)"] {
            assert_eq!(hive_type(trino), "timestamp", "{trino}");
        }
    }

    #[test]
    fn hive_type_は入れ子を_2_段まで写す() {
        for (trino, hive) in [
            ("array(array(integer))", "array<array<int>>"),
            ("map(varchar, array(real))", "map<string,array<float>>"),
            (
                r#"row("a" row("b" varchar, "c" decimal(10,2)), "d" map(integer, varbinary))"#,
                "struct<a:struct<b:string,c:decimal(10,2)>,d:map<int,binary>>",
            ),
            (
                r#"array(row("x" timestamp(3)))"#,
                "array<struct<x:timestamp>>",
            ),
        ] {
            assert_eq!(hive_type(trino), hive, "{trino}");
        }
    }

    /// フィールド名の二重引用符は外す。名前の中の `,`・`(`・`""` も読み違えない。
    #[test]
    fn hive_type_は_row_のフィールド名の引用符を外す() {
        assert_eq!(
            hive_type(r#"row("a,b" integer, "c(""d" varchar)"#),
            r#"struct<a,b:int,c("d:string>"#
        );
    }

    /// 測っていない型は Trino の綴りのまま。名前の無いフィールドの row も同じ。
    #[test]
    fn hive_type_は測っていない型を_trino_の綴りのまま返す() {
        for trino in [
            "interval day to second",
            "interval year to month",
            "time(3)",
            "json",
            "uuid",
            "ipaddress",
            "timestamp(3) with time zone",
            "row(integer)",
            "row(integer, varchar)",
        ] {
            assert_eq!(hive_type(trino), trino, "{trino}");
        }
        // 入れ子の中でも測っていない型はそのまま。
        assert_eq!(hive_type("array(json)"), "array<json>");
        assert_eq!(hive_type("array(row(integer))"), "array<row(integer)>");
    }
}
