//! スカラ値の表記。double は Java の Double.toString、varbinary は 16 進。

/// 整数はそのまま、浮動小数点数（double / real）は Java の Double.toString と同じ表記にする。
/// Athena の実測: `1.0E20`、`1.0E-7`、`0.30000000000000004`、`1.5`。
/// NaN と Infinity は Trino が文字列で送ってくるので、ここには来ない。
pub(super) fn number_text(number: &serde_json::Number) -> String {
    match number.as_f64() {
        Some(value) if !(number.is_i64() || number.is_u64()) => java_double(value),
        _ => number.to_string(),
    }
}

/// Java の Double.toString: 1e-3 <= |x| < 1e7 は小数表記（小数部は最低 1 桁）、
/// それ以外は `d.dddE<指数>`（指数に + は付けない）。桁は往復できる最短の桁で、Rust の `{:e}` と同じ。
fn java_double(value: f64) -> String {
    if value.is_nan() {
        return "NaN".to_string();
    }
    if value.is_infinite() {
        return if value > 0.0 { "Infinity" } else { "-Infinity" }.to_string();
    }
    let sign = if value.is_sign_negative() { "-" } else { "" };
    if value == 0.0 {
        return format!("{sign}0.0");
    }

    let magnitude = value.abs();
    // 例: 3.0000000000000004e-1 → 桁 "30000000000000004"、指数 -1。
    let scientific = format!("{magnitude:e}");
    let (mantissa, exponent) = scientific
        .split_once('e')
        .expect("{:e} の表記には e が入る");
    let exponent: i32 = exponent.parse().expect("{:e} の指数は整数");
    let digits: String = mantissa.chars().filter(|c| *c != '.').collect();

    let text = if (1e-3..1e7).contains(&magnitude) {
        if exponent >= 0 {
            let point = exponent as usize + 1;
            let padded = format!("{digits:0<point$}");
            let (integer, fraction) = padded.split_at(point);
            format!(
                "{integer}.{}",
                if fraction.is_empty() { "0" } else { fraction }
            )
        } else {
            format!("0.{}{digits}", "0".repeat((-exponent - 1) as usize))
        }
    } else {
        let (first, rest) = digits.split_at(1);
        format!(
            "{first}.{}E{exponent}",
            if rest.is_empty() { "0" } else { rest }
        )
    };

    format!("{sign}{text}")
}

/// base64 を 16 進に。読めなければ受け取ったまま返す。
pub(super) fn varbinary(text: &str) -> String {
    match decode_base64(text) {
        Some(bytes) => bytes
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<Vec<_>>()
            .join(" "),
        None => text.to_string(),
    }
}

/// 複合型（array / map / row）の中の varbinary。本物は `[B@` + 16 進 1〜8 桁（Java の `byte[]` の
/// `toString()` の形）を返し、数字は中身を表さない（2026-09-24 実測: `ARRAY[X'0102', X'03']` の 2 要素は
/// 無関係な値。#146・#149）。等しいバイト列が同じ値になるか、実行ごとに変わるかは未実測。athena-local は
/// 形だけ揃え、値はバイト列の FNV-1a 32 ビットにして決定的にする（同じバイト列は同じ値）。
/// base64 として読めなければ受け取ったまま返す（トップレベルと同じ）。
pub(super) fn nested_varbinary(text: &str) -> String {
    match decode_base64(text) {
        Some(bytes) => format!("[B@{:x}", fnv1a_32(&bytes)),
        None => text.to_string(),
    }
}

/// FNV-1a（32 ビット）。依存を足さず、Rust の版で変わらないハッシュにするため自前で持つ。
fn fnv1a_32(bytes: &[u8]) -> u32 {
    bytes.iter().fold(0x811c_9dc5_u32, |hash, byte| {
        (hash ^ u32::from(*byte)).wrapping_mul(0x0100_0193)
    })
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
