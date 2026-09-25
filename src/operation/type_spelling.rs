//! Trino の型の綴りを、本物の Athena が DESCRIBE に出す型の綴り（Hive のテーブルと Iceberg のテーブルで違う）に
//! 写す（#173）。写すのは実測した綴りだけ（2026-09-24 実測 d1・d2・d8。Trino 482 の綴りは同じ日に手元で確認）。
//! 測っていない型（`interval …`、`time`、`json`、`uuid`、`timestamp(3) with time zone` など）は
//! Trino の綴りのまま返す。

/// Trino の型の綴りを Hive のテーブルの表記にする。`array`・`map`・`row` は中の型も写し、区切りは空白無しの
/// `,`・`:`（`map<string,int>`、`struct<aa:int,b:int>`。2026-09-24 実測 d1）。
pub(super) fn hive(trino: &str) -> String {
    spell(trino, ",", ":")
}

/// Trino の型の綴りを Iceberg のテーブルの表記にする。区切りは空白付きの `, `・`: `
/// （`decimal(10, 2)`、`map<string, int>`、`struct<a: int>`。2026-09-24 実測 d2・d8）。
/// 複数フィールドの `row` の区切りは未実測（#173）で、`map` に倣って `, ` にしている。
pub(super) fn iceberg(trino: &str) -> String {
    spell(trino, ", ", ": ")
}

/// `hive`／`iceberg` の本体。`comma` は `decimal`・`map`・`struct` の引数の区切り、`colon` は `struct` の
/// フィールド名と型の区切り。`decimal(p,s)` は Hive では Trino と同じ綴り（`decimal(10,2)`）になる。
fn spell(trino: &str, comma: &str, colon: &str) -> String {
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
    let spell = |inner: &str| spell(inner, comma, colon);
    match (name, arguments.as_slice()) {
        ("timestamp", [_]) => "timestamp".to_string(),
        ("decimal", [precision, scale]) => format!("decimal({precision}{comma}{scale})"),
        ("array", [element]) => format!("array<{}>", spell(element)),
        ("map", [key, value]) => format!("map<{}{comma}{}>", spell(key), spell(value)),
        ("row", fields) => struct_type(fields, comma, colon).unwrap_or_else(|| trino.to_string()),
        // `varchar(n)`・`char(n)` は Hive の本物も同じ綴り。測っていない型もそのまま。
        _ => trino.to_string(),
    }
}

/// `row("a" T, "b" U)` のフィールドを `struct<a:T',b:U'>`（Hive）／`struct<a: T', b: U'>`（Iceberg）にする。
/// 名前の無いフィールドがあれば（`row(integer)`。測っていない）None。
fn struct_type(fields: &[&str], comma: &str, colon: &str) -> Option<String> {
    let fields = fields
        .iter()
        .map(|field| {
            if !field.starts_with('"') {
                return None;
            }
            let end = athena_sql::skip_quoted(field.as_bytes(), 0);
            let name = athena_sql::unquote(&field[..end]);
            Some(format!(
                "{name}{colon}{}",
                spell(field[end..].trim(), comma, colon)
            ))
        })
        .collect::<Option<Vec<_>>>()?;
    Some(format!("struct<{}>", fields.join(comma)))
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
                index = athena_sql::skip_quoted(bytes, index);
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
    fn hive_は実測した_17_種を本物の綴りに写す() {
        for (trino, hive_spelling) in [
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
            assert_eq!(hive(trino), hive_spelling, "{trino}");
        }
    }

    #[test]
    fn hive_は_timestamp_の精度によらず_timestamp_にする() {
        for trino in ["timestamp(0)", "timestamp(6)", "timestamp(9)"] {
            assert_eq!(hive(trino), "timestamp", "{trino}");
        }
    }

    #[test]
    fn hive_は入れ子を_2_段まで写す() {
        for (trino, hive_spelling) in [
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
            assert_eq!(hive(trino), hive_spelling, "{trino}");
        }
    }

    /// フィールド名の二重引用符は外す。名前の中の `,`・`(`・`""` も読み違えない。
    #[test]
    fn hive_は_row_のフィールド名の引用符を外す() {
        assert_eq!(
            hive(r#"row("a,b" integer, "c(""d" varchar)"#),
            r#"struct<a,b:int,c("d:string>"#
        );
    }

    /// 測っていない型は Trino の綴りのまま。名前の無いフィールドの row も同じ。
    #[test]
    fn hive_は測っていない型を_trino_の綴りのまま返す() {
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
            assert_eq!(hive(trino), trino, "{trino}");
        }
        // 入れ子の中でも測っていない型はそのまま。
        assert_eq!(hive("array(json)"), "array<json>");
        assert_eq!(hive("array(row(integer))"), "array<row(integer)>");
    }

    /// 本物の d2・d8（Iceberg、2026-09-24 実測）の 13 種。左は Trino 482 の DESCRIBE の `Type`。
    /// 採取元: run-20260924-115811/d2/d2-describe.results-1.json、run-20260924-122125/d8/d8-describe.results-1.json。
    #[test]
    fn iceberg_は実測した_13_種を本物の綴りに写す() {
        for (trino, iceberg_spelling) in [
            ("integer", "int"),
            ("varchar", "string"),
            ("timestamp(6)", "timestamp"),
            ("decimal(10,2)", "decimal(10, 2)"),
            ("array(varchar)", "array<string>"),
            (r#"row("a" integer)"#, "struct<a: int>"),
            ("bigint", "bigint"),
            ("date", "date"),
            ("double", "double"),
            ("real", "float"),
            ("boolean", "boolean"),
            ("varbinary", "binary"),
            ("map(varchar, integer)", "map<string, int>"),
        ] {
            assert_eq!(iceberg(trino), iceberg_spelling, "{trino}");
        }
    }

    /// 入れ子も写す。複数フィールドの `row` の区切りは未実測で、`map` に倣って `, `。
    #[test]
    fn iceberg_は入れ子を空白付きの区切りで写す() {
        for (trino, iceberg_spelling) in [
            ("array(array(integer))", "array<array<int>>"),
            ("map(varchar, array(real))", "map<string, array<float>>"),
            (
                r#"row("a" row("b" varchar, "c" decimal(10,2)), "d" map(integer, varbinary))"#,
                "struct<a: struct<b: string, c: decimal(10, 2)>, d: map<int, binary>>",
            ),
        ] {
            assert_eq!(iceberg(trino), iceberg_spelling, "{trino}");
        }
    }

    #[test]
    fn iceberg_は測っていない型を_trino_の綴りのまま返す() {
        for trino in [
            "uuid",
            "time(6)",
            "timestamp(6) with time zone",
            "row(integer)",
        ] {
            assert_eq!(iceberg(trino), trino, "{trino}");
        }
        assert_eq!(iceberg("array(uuid)"), "array<uuid>");
    }
}
