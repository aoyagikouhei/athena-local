//! 修飾名の読み飛ばしと引用符の取り外し。

use crate::trivia::{skip_quoted, skip_trivia};

/// 修飾名を 1 つ読み飛ばして、その後ろの位置を返す。`a`、`a.b`、`a.b.c`、
/// `"quoted name".b` のように、ドットの前後に空白やコメントを挟んだ形も読み飛ばす。
///
/// `operation/classification.rs` の ALTER TABLE の判定が使う。`words()` はドットの前後に空白や
/// コメントを挟んだ修飾名（`cat . ns . t`）を複数の語に数えるため、テーブル名の終わりの位置を
/// ここで確かめてから、その後ろの語だけを見て判定する（引用符付き識別子の中の空白は #52 から
/// `words()` も 1 語として読むが、修飾名の分割は残る）。
///
/// `operation/target_table.rs::parse_qualified_name` は名前の中身を取り出す関数で、
/// こちらは中身を見ずに位置だけを進める（用途が違うので無理に共通化しない。issue #44）。
/// 字句処理は増やさず、`skip_quoted`・`comment_end`・`skip_leading_trivia` と同じ判定
/// （引用符・コメント・空白）を使い回す。
pub fn skip_qualified_name(sql: &str, start: usize) -> usize {
    let bytes = sql.as_bytes();
    let mut i = skip_name_part(bytes, start);
    loop {
        let after_trivia = skip_trivia(bytes, i);
        if after_trivia < bytes.len() && bytes[after_trivia] == b'.' {
            i = skip_name_part(bytes, skip_trivia(bytes, after_trivia + 1));
        } else {
            return i;
        }
    }
}

/// 名前を 1 つ読み飛ばした位置。引用符付きなら `skip_quoted` の終わりまで、無引用なら
/// 識別子の文字（英数字・`_`）が続く間読み進めた位置まで。
fn skip_name_part(bytes: &[u8], start: usize) -> usize {
    if bytes.get(start) == Some(&b'"') {
        skip_quoted(bytes, start)
    } else {
        let mut i = start;
        while i < bytes.len() && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_') {
            i += 1;
        }
        i
    }
}

/// `"a""b"` の中身 `a"b`。
///
/// `operation/target_table.rs` が DROP TABLE の修飾名の引用符付き識別子を読むのにも再利用する（issue #39 Phase 2）。
pub fn unquote(identifier: &str) -> String {
    let inner = identifier
        .strip_prefix('"')
        .and_then(|rest| rest.strip_suffix('"'))
        .unwrap_or(identifier);
    inner.replace("\"\"", "\"")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skip_qualified_name_は無引用の単純な名前を読み飛ばす() {
        assert_eq!(skip_qualified_name("t", 0), 1);
        assert_eq!(skip_qualified_name("t ADD COLUMNS", 0), 1);
    }

    #[test]
    fn skip_qualified_name_はドットで繋いだ修飾名を読み飛ばす() {
        assert_eq!(skip_qualified_name("cat.ns.t", 0), "cat.ns.t".len());
        assert_eq!(skip_qualified_name("cat.ns.t ADD", 0), "cat.ns.t".len());
    }

    #[test]
    fn skip_qualified_name_は引用符付きの識別子を読み飛ばす() {
        let sql = r#""my table".ns.t"#;
        assert_eq!(skip_qualified_name(sql, 0), sql.len());
    }

    #[test]
    fn skip_qualified_name_はドットの前後の空白やコメントを読み飛ばす() {
        assert_eq!(skip_qualified_name("cat . ns . t", 0), "cat . ns . t".len());
        assert_eq!(
            skip_qualified_name("cat /* c */ . ns", 0),
            "cat /* c */ . ns".len()
        );
        assert_eq!(
            skip_qualified_name("cat -- c\n. ns", 0),
            "cat -- c\n. ns".len()
        );
    }

    #[test]
    fn skip_qualified_name_はドットが続かなければ後ろのトリビアを消費せずに止まる() {
        // 名前の後ろにコメントがあっても、続きがドットでなければコメントは読み飛ばした
        // 位置に含めない（呼び出し元が改めて skip_leading_trivia できるようにする）。
        assert_eq!(skip_qualified_name("t -- comment\nADD COLUMN", 0), 1);
    }

    #[test]
    fn skip_qualified_name_は途中の位置からも読める() {
        let sql = "ALTER TABLE cat.ns.t ADD COLUMNS";
        let start = "ALTER TABLE ".len();
        assert_eq!(
            skip_qualified_name(sql, start),
            "ALTER TABLE cat.ns.t".len()
        );
    }
}
