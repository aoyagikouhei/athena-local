//! キーワードの照合。#195 で文の頭・句を読む Cursor をここに足す。

use crate::trivia::skip_leading_trivia;

/// 先頭の空白・コメントを読み飛ばしてからキーワードを 1 語ぶん読み飛ばす。大文字小文字は
/// 区別せず、続きが識別子の文字（英数字・`_`）なら別の語（`COLUMN` に対する `COLUMNS` など）
/// とみなして一致させない。続きが `(` や文字列リテラルの `'` など識別子でない文字なら
/// 空白が無くても一致させる（`TBLPROPERTIES(...)` のような書き方。3 本目のレビューで実測）。
///
/// `operation/classification.rs` の ALTER TABLE の判定（`COLUMN` と `COLUMNS` を分ける）と、
/// `operation/target_table.rs` の DROP TABLE / ALTER TABLE の対象テーブルの解析
/// （`TABLE` と `TABLES` を分ける）が再利用する。もとは 2 ファイルに同名で別定義があり、
/// トリビアを内側で読み飛ばすか呼び出し元に任せるかだけが違っていた（issue #49 で内側に寄せて統合）。
pub fn skip_keyword<'a>(input: &'a str, keyword: &str) -> Option<&'a str> {
    let trimmed = skip_leading_trivia(input);
    if trimmed.len() < keyword.len() || !trimmed.is_char_boundary(keyword.len()) {
        return None;
    }
    let (head, tail) = trimmed.split_at(keyword.len());
    if !head.eq_ignore_ascii_case(keyword) {
        return None;
    }
    if tail.starts_with(|c: char| c.is_ascii_alphanumeric() || c == '_') {
        return None;
    }
    Some(tail)
}
