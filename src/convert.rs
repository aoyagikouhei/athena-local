//! Trino の結果を Athena の ResultSet に写す。

use std::cmp::Ordering;

use serde_json::Value;

use crate::athena::{ColumnInfo, Datum, ResultSet, ResultSetMetadata, Row};
use crate::trino::Outcome;

/// SELECT の 1 ページ目の先頭行は列名（本物の Athena と同じ）。
/// ページングできるよう、ヘッダ行込みの一覧をまとめて作る。
pub fn all_rows(outcome: &Outcome) -> Vec<Vec<Option<String>>> {
    if outcome.update_count.is_some() {
        // DML は行を返さず UpdateCount だけ。
        return Vec::new();
    }

    let header = outcome
        .columns
        .iter()
        .map(|column| Some(column.name.clone()))
        .collect();

    let mut rows = vec![header];
    rows.extend(outcome.rows.iter().map(|row| {
        row.iter()
            .enumerate()
            .map(|(index, value)| {
                let signature = outcome
                    .columns
                    .get(index)
                    .and_then(|column| column.type_signature.as_ref());
                to_var_char_value(value, signature)
            })
            .collect()
    }));

    rows
}

pub fn result_set(outcome: &Outcome, rows: &[Vec<Option<String>>]) -> ResultSet {
    // DML の列（Trino が返す rows 列）は本物の Athena には無いので載せない。
    let columns = match outcome.update_count {
        Some(_) => Vec::new(),
        None => outcome.columns.iter().map(to_column_info).collect(),
    };

    ResultSet {
        rows: rows.iter().map(|row| to_row(row)).collect(),
        result_set_metadata: ResultSetMetadata {
            column_info: columns,
        },
    }
}

/// Athena は値をすべて文字列で返す。NULL は Datum ごと空にする。
/// 複合型は JSON ではなく Athena の表記（`[1, 2]` / `{k=1}` / `{id=1, name=x}`）にする。
fn to_var_char_value(value: &Value, signature: Option<&Value>) -> Option<String> {
    match value {
        Value::Null => None,
        Value::String(text) if raw_type(signature) == Some("varbinary") => Some(varbinary(text)),
        Value::String(text) => Some(text.clone()),
        Value::Bool(flag) => Some(flag.to_string()),
        Value::Number(number) => Some(number.to_string()),
        other => Some(match signature.and_then(ValueType::parse) {
            Some(value_type) => render(other, &value_type),
            // row も array も JSON 配列で届くので、型が分からなければ見分けられない。
            None => other.to_string(),
        }),
    }
}

fn raw_type(signature: Option<&Value>) -> Option<&str> {
    signature?.get("rawType")?.as_str()
}

/// 値の表記を決めるのに要る範囲の型。Trino の typeSignature から読む。
enum ValueType {
    Array(Box<ValueType>),
    /// キーの並べ方と値の型。キーは JSON のオブジェクトキー（文字列）で届く。
    Map(KeyOrder, Box<ValueType>),
    /// フィールド名と型。無名 row のフィールド名は None。
    Row(Vec<(Option<String>, ValueType)>),
    /// Trino は base64 で返す。Athena は 16 進を空白で区切って返す。
    Varbinary,
    Scalar,
}

/// map のキーの並べ方。Athena は数値のキーを数値の順に並べる（`{9=a, 10=b}`）。
enum KeyOrder {
    Numeric,
    Text,
}

impl ValueType {
    /// 読めない形なら None（呼び出し側は JSON のまま返す）。
    fn parse(signature: &Value) -> Option<Self> {
        let arguments = signature.get("arguments").and_then(Value::as_array);
        let argument = |index: usize| arguments?.get(index);

        match signature.get("rawType")?.as_str()? {
            "array" => Some(Self::Array(Box::new(type_argument(argument(0)?)?))),
            "map" => Some(Self::Map(
                key_order(argument(0)?),
                Box::new(type_argument(argument(1)?)?),
            )),
            "varbinary" => Some(Self::Varbinary),
            "row" => arguments?
                .iter()
                .map(named_argument)
                .collect::<Option<Vec<_>>>()
                .map(Self::Row),
            _ => Some(Self::Scalar),
        }
    }
}

/// array / map の引数 `{"kind": "TYPE", "value": <typeSignature>}`。
/// 形が違えば value が型として読めず None になるので、kind は見ない。
fn type_argument(argument: &Value) -> Option<ValueType> {
    ValueType::parse(argument.get("value")?)
}

/// map のキーの型から並べ方を決める。読めなければ文字列の順。
fn key_order(argument: &Value) -> KeyOrder {
    let raw_type = argument
        .get("value")
        .and_then(|value| value.get("rawType"))
        .and_then(Value::as_str);

    match raw_type {
        Some("tinyint" | "smallint" | "integer" | "bigint" | "real" | "double" | "decimal") => {
            KeyOrder::Numeric
        }
        _ => KeyOrder::Text,
    }
}

/// row の引数 `{"kind": "NAMED_TYPE", "value": {"fieldName": {"name": ..}, "typeSignature": ..}}`。
/// 無名 row では fieldName が省かれる。
fn named_argument(argument: &Value) -> Option<(Option<String>, ValueType)> {
    let value = argument.get("value")?;
    let name = value
        .get("fieldName")
        .and_then(|field| field.get("name"))
        .and_then(Value::as_str)
        .map(str::to_string);

    Some((name, ValueType::parse(value.get("typeSignature")?)?))
}

/// 複合型の中身を Athena の表記にする。中の文字列はクオートせず、NULL は `null` と書く。
fn render(value: &Value, value_type: &ValueType) -> String {
    match (value_type, value) {
        (_, Value::Null) => "null".to_string(),
        (ValueType::Varbinary, Value::String(text)) => varbinary(text),
        (_, Value::String(text)) => text.clone(),
        (ValueType::Array(element), Value::Array(items)) => {
            format!("[{}]", join(items.iter().map(|item| render(item, element))))
        }
        // serde_json の Map はキーの文字列順に並ぶ（preserve_order は無効）。
        // 文字列のキーはそのまま、数値のキーは数値の順に並べ直す。どちらも Athena の実測と同じ並び。
        (ValueType::Map(order, element), Value::Object(entries)) => {
            let mut entries: Vec<_> = entries.iter().collect();
            if let KeyOrder::Numeric = order {
                entries.sort_by(|(a, _), (b, _)| compare_numbers(a, b));
            }
            format!(
                "{{{}}}",
                join(
                    entries
                        .into_iter()
                        .map(|(key, item)| format!("{key}={}", render(item, element)))
                )
            )
        }
        (ValueType::Row(fields), Value::Array(items)) if fields.len() == items.len() => format!(
            "{{{}}}",
            join(
                fields
                    .iter()
                    .zip(items)
                    .map(|((name, field_type), item)| match name {
                        Some(name) => format!("{name}={}", render(item, field_type)),
                        None => render(item, field_type),
                    })
            )
        ),
        // 数値・真偽値と、型と値の形が合わないもの。
        (_, other) => other.to_string(),
    }
}

/// 数値として読めるキーを数値の順に。整数は精度を落とさないよう i128 で比べる。
/// 読めないキーは後ろに文字列の順で置く（全順序にしておかないと sort が壊れる）。
fn compare_numbers(a: &str, b: &str) -> Ordering {
    if let (Ok(x), Ok(y)) = (a.parse::<i128>(), b.parse::<i128>()) {
        return x.cmp(&y);
    }
    match (a.parse::<f64>(), b.parse::<f64>()) {
        (Ok(x), Ok(y)) => x.total_cmp(&y).then_with(|| a.cmp(b)),
        (Ok(_), Err(_)) => Ordering::Less,
        (Err(_), Ok(_)) => Ordering::Greater,
        (Err(_), Err(_)) => a.cmp(b),
    }
}

/// base64 を 16 進に。読めなければ受け取ったまま返す。
fn varbinary(text: &str) -> String {
    match decode_base64(text) {
        Some(bytes) => bytes
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<Vec<_>>()
            .join(" "),
        None => text.to_string(),
    }
}

/// 標準の base64（`+` `/`、`=` 埋め）。依存を足すほどではないので自前で読む。
fn decode_base64(text: &str) -> Option<Vec<u8>> {
    let text = text.trim_end_matches('=');
    let mut bytes = Vec::with_capacity(text.len() * 3 / 4);
    let mut buffer = 0u32;
    let mut bits = 0;

    for c in text.bytes() {
        let value = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        };
        buffer = (buffer << 6) | u32::from(value);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            bytes.push((buffer >> bits) as u8);
            buffer &= (1 << bits) - 1;
        }
    }

    Some(bytes)
}

fn join(parts: impl Iterator<Item = String>) -> String {
    parts.collect::<Vec<_>>().join(", ")
}

fn to_row(values: &[Option<String>]) -> Row {
    Row {
        data: values
            .iter()
            .map(|value| Datum {
                var_char_value: value.clone(),
            })
            .collect(),
    }
}

fn to_column_info(column: &crate::trino::Column) -> ColumnInfo {
    ColumnInfo {
        name: column.name.clone(),
        label: column.name.clone(),
        type_name: column.type_name.clone(),
        nullable: "UNKNOWN".to_string(),
        case_sensitive: false,
    }
}

#[cfg(test)]
mod tests {
    //! 入力（data と typeSignature）は Trino 482 の応答、期待値は本番 Athena の
    //! VarCharValue を、どちらも 2026-09-14 に採取したものをそのまま使う。
    //! data は JSON 文字列から読み、Trino が送ってくるキーの並びのまま渡す。

    use super::*;

    fn format(data: &str, signature: &str) -> Option<String> {
        let value: Value = serde_json::from_str(data).expect("data が JSON でない");
        let signature: Value = serde_json::from_str(signature).expect("型が JSON でない");
        to_var_char_value(&value, Some(&signature))
    }

    const INTEGER: &str = r#"{"rawType":"integer","arguments":[]}"#;

    fn array_of(element: &str) -> String {
        format!(r#"{{"rawType":"array","arguments":[{{"kind":"TYPE","value":{element}}}]}}"#)
    }

    #[test]
    fn 配列は区切りに空白が入る() {
        assert_eq!(
            format("[1,2,3]", &array_of(INTEGER)),
            Some("[1, 2, 3]".into())
        );
    }

    #[test]
    fn 配列の文字列はクオートせず_null_は_null_と書く() {
        let varchar_1 = r#"{"rawType":"varchar","arguments":[{"kind":"LONG","value":1}]}"#;
        assert_eq!(
            format(r#"["a",null]"#, &array_of(varchar_1)),
            Some("[a, null]".into())
        );
    }

    #[test]
    fn 空配列() {
        let bigint = r#"{"rawType":"bigint","arguments":[]}"#;
        assert_eq!(format("[]", &array_of(bigint)), Some("[]".into()));
    }

    #[test]
    fn 入れ子の配列() {
        assert_eq!(
            format("[[1],[2,3]]", &array_of(&array_of(INTEGER))),
            Some("[[1], [2, 3]]".into())
        );
    }

    #[test]
    fn map_はキー昇順で_key_value_と書く() {
        // Trino は k, j の順で返すが、Athena は {j=2, k=1} を返した。
        let signature = r#"{"rawType":"map","arguments":[
            {"kind":"TYPE","value":{"rawType":"varchar","arguments":[{"kind":"LONG","value":1}]}},
            {"kind":"TYPE","value":{"rawType":"integer","arguments":[]}}]}"#;
        assert_eq!(
            format(r#"{"k":1,"j":2}"#, signature),
            Some("{j=2, k=1}".into())
        );
    }

    #[test]
    fn 数値キーの_map() {
        let signature = r#"{"rawType":"map","arguments":[
            {"kind":"TYPE","value":{"rawType":"integer","arguments":[]}},
            {"kind":"TYPE","value":{"rawType":"varchar","arguments":[{"kind":"LONG","value":1}]}}]}"#;
        assert_eq!(format(r#"{"1":"v"}"#, signature), Some("{1=v}".into()));
    }

    #[test]
    fn 数値キーの_map_は数値の順に並べる() {
        // Trino からは JSON のキー（文字列）で届くので、そのままだと "10" が先になる。
        let signature = r#"{"rawType":"map","arguments":[
            {"kind":"TYPE","value":{"rawType":"integer","arguments":[]}},
            {"kind":"TYPE","value":{"rawType":"varchar","arguments":[{"kind":"LONG","value":1}]}}]}"#;
        assert_eq!(
            format(r#"{"10":"b","9":"a"}"#, signature),
            Some("{9=a, 10=b}".into())
        );
    }

    #[test]
    fn 数値として比べるときも読めないキーは後ろに文字列の順で置く() {
        let mut keys = vec!["x", "10", "-1.5", "9", "a"];
        keys.sort_by(|a, b| compare_numbers(a, b));
        assert_eq!(keys, ["-1.5", "9", "10", "a", "x"]);
    }

    #[test]
    fn varbinary_は_16_進を空白で区切る() {
        let varbinary = r#"{"rawType":"varbinary","arguments":[]}"#;
        // X'0102'。Trino は base64 の "AQI=" で返す。
        assert_eq!(format(r#""AQI=""#, varbinary), Some("01 02".into()));
        // 英字は小文字（Trino の表記。実測したのは数字だけ）。
        assert_eq!(format(r#""/+8=""#, varbinary), Some("ff ef".into()));
        assert_eq!(format(r#""""#, varbinary), Some("".into()));
        // base64 として読めなければそのまま返す。
        assert_eq!(
            format(r#""not base64!""#, varbinary),
            Some("not base64!".into())
        );
    }

    #[test]
    fn 配列の中の_varbinary_も_16_進にする() {
        let varbinary = r#"{"rawType":"varbinary","arguments":[]}"#;
        assert_eq!(
            format(r#"["AQI=",null]"#, &array_of(varbinary)),
            Some("[01 02, null]".into())
        );
    }

    #[test]
    fn 名前付き_row_は_name_value_と書く() {
        let signature = r#"{"rawType":"row","arguments":[
            {"kind":"NAMED_TYPE","value":{"fieldName":{"name":"id"},"typeSignature":{"rawType":"integer","arguments":[]}}},
            {"kind":"NAMED_TYPE","value":{"fieldName":{"name":"name"},"typeSignature":{"rawType":"varchar","arguments":[{"kind":"LONG","value":2147483647}]}}}]}"#;
        assert_eq!(
            format(r#"[1,"x"]"#, signature),
            Some("{id=1, name=x}".into())
        );
    }

    #[test]
    fn 無名_row_は値だけを波括弧に並べる() {
        let signature = r#"{"rawType":"row","arguments":[
            {"kind":"NAMED_TYPE","value":{"typeSignature":{"rawType":"integer","arguments":[]}}},
            {"kind":"NAMED_TYPE","value":{"typeSignature":{"rawType":"varchar","arguments":[{"kind":"LONG","value":1}]}}}]}"#;
        assert_eq!(format(r#"[1,"x"]"#, signature), Some("{1, x}".into()));
    }

    #[test]
    fn row_の配列() {
        let row = r#"{"rawType":"row","arguments":[
            {"kind":"NAMED_TYPE","value":{"fieldName":{"name":"n"},"typeSignature":{"rawType":"integer","arguments":[]}}}]}"#;
        assert_eq!(format("[[1]]", &array_of(row)), Some("[{n=1}]".into()));
    }

    #[test]
    fn 配列の_decimal_真偽値_日付_時刻() {
        let decimal = r#"{"rawType":"decimal","arguments":[{"kind":"LONG","value":3},{"kind":"LONG","value":2}]}"#;
        let boolean = r#"{"rawType":"boolean","arguments":[]}"#;
        let date = r#"{"rawType":"date","arguments":[]}"#;
        let timestamp = r#"{"rawType":"timestamp","arguments":[]}"#;

        assert_eq!(
            format(r#"["1.50"]"#, &array_of(decimal)),
            Some("[1.50]".into())
        );
        assert_eq!(
            format("[true,false]", &array_of(boolean)),
            Some("[true, false]".into())
        );
        assert_eq!(
            format(r#"["2020-01-01"]"#, &array_of(date)),
            Some("[2020-01-01]".into())
        );
        assert_eq!(
            format(r#"["2020-01-01 12:34:56.789"]"#, &array_of(timestamp)),
            Some("[2020-01-01 12:34:56.789]".into())
        );
    }

    #[test]
    fn map_の値が複合型なら値の型で書く() {
        // 期待値は実測ではなく、上で実測した配列と map の規則を組み合わせたもの。
        let signature = r#"{"rawType":"map","arguments":[
            {"kind":"TYPE","value":{"rawType":"varchar","arguments":[{"kind":"LONG","value":1}]}},
            {"kind":"TYPE","value":{"rawType":"array","arguments":[{"kind":"TYPE","value":{"rawType":"integer","arguments":[]}}]}}]}"#;
        assert_eq!(
            format(r#"{"k":[1,2]}"#, signature),
            Some("{k=[1, 2]}".into())
        );
    }

    #[test]
    fn 列ごとに自分の型で書く() {
        use crate::trino::Column;

        let signature = |text: &str| Some(serde_json::from_str(text).unwrap());
        let outcome = Outcome {
            columns: vec![
                Column {
                    name: "name".to_string(),
                    type_name: "varchar".to_string(),
                    type_signature: signature(
                        r#"{"rawType":"varchar","arguments":[{"kind":"LONG","value":2147483647}]}"#,
                    ),
                },
                Column {
                    name: "counts".to_string(),
                    type_name: "array(integer)".to_string(),
                    type_signature: signature(&array_of(INTEGER)),
                },
            ],
            rows: vec![vec![
                Value::from("x"),
                serde_json::from_str("[1,2]").unwrap(),
            ]],
            update_count: None,
        };

        assert_eq!(
            all_rows(&outcome),
            [
                [Some("name".to_string()), Some("counts".to_string())],
                [Some("x".to_string()), Some("[1, 2]".to_string())],
            ]
        );
    }

    #[test]
    fn 型情報が無ければ_json_のまま返す() {
        let value: Value = serde_json::from_str("[1,2]").unwrap();
        assert_eq!(to_var_char_value(&value, None), Some("[1,2]".into()));
    }

    #[test]
    fn 型情報が読めなければ_json_のまま返す() {
        // array なのに要素型が無い。
        assert_eq!(
            format("[1,2]", r#"{"rawType":"array","arguments":[]}"#),
            Some("[1,2]".into())
        );
    }

    #[test]
    fn 型と値の形が合わない部分は_json_のまま返す() {
        // row のフィールド数と値の数が違う。
        let signature = r#"{"rawType":"row","arguments":[
            {"kind":"NAMED_TYPE","value":{"fieldName":{"name":"id"},"typeSignature":{"rawType":"integer","arguments":[]}}}]}"#;
        assert_eq!(format(r#"[1,"x"]"#, signature), Some(r#"[1,"x"]"#.into()));
    }

    #[test]
    fn トップレベルのスカラは型があっても変わらない() {
        let varchar = r#"{"rawType":"varchar","arguments":[{"kind":"LONG","value":5}]}"#;
        assert_eq!(format(r#""plain""#, varchar), Some("plain".into()));
        assert_eq!(format("null", &array_of(INTEGER)), None);
        assert_eq!(format("1.5", INTEGER), Some("1.5".into()));
    }
}
