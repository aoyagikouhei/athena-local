//! 値を Athena の VarCharValue の表記にする。複合型（array / map / row）は再帰で組み立てる。

use std::cmp::Ordering;

use serde_json::Value;

use super::value_type::{KeyOrder, ValueType};

/// Athena は値をすべて文字列で返す。NULL は Datum ごと空にする。
/// 複合型は JSON ではなく Athena の表記（`[1, 2]` / `{k=1}` / `{id=1, name=x}`）にする。
pub(super) fn to_var_char_value(value: &Value, signature: Option<&Value>) -> Option<String> {
    match value {
        Value::Null => None,
        Value::String(text) if super::value_type::raw_type(signature) == Some("varbinary") => {
            Some(super::scalar::varbinary(text))
        }
        Value::String(text) => Some(text.clone()),
        Value::Bool(flag) => Some(flag.to_string()),
        Value::Number(number) => Some(super::scalar::number_text(number)),
        other => Some(match signature.and_then(ValueType::parse) {
            Some(value_type) => render(other, &value_type),
            // row も array も JSON 配列で届くので、型が分からなければ見分けられない。
            None => other.to_string(),
        }),
    }
}

/// 複合型の中身を Athena の表記にする。中の文字列はクオートせず、NULL は `null` と書く。
fn render(value: &Value, value_type: &ValueType) -> String {
    match (value_type, value) {
        (_, Value::Null) => "null".to_string(),
        (ValueType::Varbinary, Value::String(text)) => super::scalar::varbinary(text),
        (_, Value::String(text)) => text.clone(),
        (_, Value::Number(number)) => super::scalar::number_text(number),
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

fn join(parts: impl Iterator<Item = String>) -> String {
    parts.collect::<Vec<_>>().join(", ")
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
    fn 浮動小数点数は_java_の表記にする() {
        let double = r#"{"rawType":"double","arguments":[]}"#;
        for (data, expected) in [
            // Trino 482 が送ってくる JSON と、同じ値の Athena の表記（上 3 つは実測）。
            ("1e+20", "1.0E20"),
            ("1e-07", "1.0E-7"),
            ("0.30000000000000004", "0.30000000000000004"),
            // 以下は Java の Double.toString の規則から。
            ("1.5", "1.5"),
            ("100.0", "100.0"),
            ("1234567.0", "1234567.0"),
            ("1e7", "1.0E7"),
            ("12345678.9", "1.23456789E7"),
            ("0.001", "0.001"),
            ("0.0001", "1.0E-4"),
            ("-2.5e-10", "-2.5E-10"),
            ("0.0", "0.0"),
            ("-0.0", "-0.0"),
        ] {
            assert_eq!(format(data, double), Some(expected.into()), "{data}");
        }
    }

    #[test]
    fn 整数は桁を変えない() {
        let bigint = r#"{"rawType":"bigint","arguments":[]}"#;
        assert_eq!(
            format("9223372036854775807", bigint),
            Some("9223372036854775807".into())
        );
        assert_eq!(format("-1", bigint), Some("-1".into()));
    }

    #[test]
    fn 配列の中の浮動小数点数も_java_の表記にする() {
        let double = r#"{"rawType":"double","arguments":[]}"#;
        assert_eq!(
            format("[1e+20,0.5]", &array_of(double)),
            Some("[1.0E20, 0.5]".into())
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
