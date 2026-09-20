//! Trino の typeSignature を読んで、値をどう書くかを決める型の表現。

use serde_json::Value;

pub(super) fn raw_type(signature: Option<&Value>) -> Option<&str> {
    signature?.get("rawType")?.as_str()
}

/// 値の表記を決めるのに要る範囲の型。Trino の typeSignature から読む。
pub(super) enum ValueType {
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
pub(super) enum KeyOrder {
    Numeric,
    Text,
}

impl ValueType {
    /// 読めない形なら None（呼び出し側は JSON のまま返す）。
    pub(super) fn parse(signature: &Value) -> Option<Self> {
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
