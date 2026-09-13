//! Trino の結果を Athena の ResultSet に写す。

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

/// 値の表記を決めるのに要る範囲の型。Trino の typeSignature から読む。
enum ValueType {
    Array(Box<ValueType>),
    /// 値の型。キーは JSON のオブジェクトキー（文字列）で届くので型は要らない。
    Map(Box<ValueType>),
    /// フィールド名と型。無名 row のフィールド名は None。
    Row(Vec<(Option<String>, ValueType)>),
    Scalar,
}

impl ValueType {
    /// 読めない形なら None（呼び出し側は JSON のまま返す）。
    fn parse(signature: &Value) -> Option<Self> {
        let arguments = signature.get("arguments").and_then(Value::as_array);
        let argument = |index: usize| arguments?.get(index);

        match signature.get("rawType")?.as_str()? {
            "array" => Some(Self::Array(Box::new(type_argument(argument(0)?)?))),
            "map" => Some(Self::Map(Box::new(type_argument(argument(1)?)?))),
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
        (_, Value::String(text)) => text.clone(),
        (ValueType::Array(element), Value::Array(items)) => {
            format!("[{}]", join(items.iter().map(|item| render(item, element))))
        }
        // serde_json の Map はキー昇順に並ぶ（preserve_order は無効）。Athena の実測と同じ並び。
        (ValueType::Map(element), Value::Object(entries)) => format!(
            "{{{}}}",
            join(
                entries
                    .iter()
                    .map(|(key, item)| format!("{key}={}", render(item, element)))
            )
        ),
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
