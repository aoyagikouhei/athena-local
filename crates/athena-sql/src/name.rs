//! 修飾名の読み取りと引用符の取り外し。

use crate::cursor::Cursor;
use crate::trivia::{skip_quoted, skip_trivia};

/// 修飾名 1 つ。`text`／`start`／`end` は名前の中のトリビアも含む元の SQL での範囲。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QualifiedName<'a> {
    pub text: &'a str,
    pub start: usize,
    pub end: usize,
    pub parts: Vec<NamePart<'a>>,
}

/// 修飾名の名前部分 1 つ（引用符付きなら引用符ごと）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NamePart<'a> {
    pub text: &'a str,
    pub start: usize,
    pub end: usize,
}

impl NamePart<'_> {
    /// 中身。引用符付きなら `unquote`、無引用なら Trino の規則で小文字。
    pub fn value(&self) -> String {
        if self.text.starts_with('"') {
            unquote(self.text)
        } else {
            self.text.to_lowercase()
        }
    }
}

impl QualifiedName<'_> {
    /// 名前部分ごとの中身（`NamePart::value`）の並び。
    pub fn values(&self) -> Vec<String> {
        self.parts.iter().map(NamePart::value).collect()
    }
}

impl<'a> Cursor<'a> {
    /// 修飾名を 1 つ読む。`a`、`a.b`、`"quoted".b`、`cat . ns . t`（ドットの前後に空白やコメント）。名前部分のどれかが読めなければ
    /// （先頭が名前の文字でない、ドットの後ろに名前が無い）None を返し、位置を進めない。最後の名前部分の後ろのトリビアは消費しない。
    ///
    /// `operation/classification.rs` の ALTER TABLE の判定、`operation/completion.rs` の DESCRIBE の対象の範囲、
    /// `operation/target_table.rs` の対象テーブルの解析が使う。`words()` はドットの前後に空白や
    /// コメントを挟んだ修飾名（`cat . ns . t`）を複数の語に数えるため、テーブル名の終わりの位置を
    /// ここで確かめてから、その後ろの語だけを見て判定する（引用符付き識別子の中の空白は #52 から
    /// `words()` も 1 語として読むが、修飾名の分割は残る）。
    ///
    /// 範囲を読む側（ALTER TABLE・DESCRIBE）と値を取り出す側（対象テーブル）は同じこの実装を使う。
    /// 字句処理は増やさず、`skip_quoted`・`skip_trivia` と同じ判定（引用符・コメント・空白）を使い回す。
    pub fn qualified_name(&mut self) -> Option<QualifiedName<'a>> {
        let sql = self.sql;
        let bytes = sql.as_bytes();
        let start = skip_trivia(bytes, self.pos);
        let mut parts = vec![read_name_part(sql, start)?];
        let mut end = parts[0].end;
        loop {
            let after_trivia = skip_trivia(bytes, end);
            if bytes.get(after_trivia) != Some(&b'.') {
                break;
            }
            let part = read_name_part(sql, skip_trivia(bytes, after_trivia + 1))?;
            end = part.end;
            parts.push(part);
        }
        self.pos = end;
        Some(QualifiedName {
            text: &sql[start..end],
            start,
            end,
            parts,
        })
    }
}

/// `start` から名前部分を 1 つ読む。引用符付きなら `skip_quoted` の終わりまで、無引用なら
/// 識別子の文字（英数字・`_`）が続く間。1 バイトも読めなければ None。
fn read_name_part(sql: &str, start: usize) -> Option<NamePart<'_>> {
    let bytes = sql.as_bytes();
    let end = if bytes.get(start) == Some(&b'"') {
        skip_quoted(bytes, start)
    } else {
        let mut i = start;
        while i < bytes.len() && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_') {
            i += 1;
        }
        i
    };
    if end == start {
        return None;
    }
    Some(NamePart {
        text: &sql[start..end],
        start,
        end,
    })
}

/// `"a""b"` の中身 `a"b`。
///
/// 修飾名の引用符付き識別子の中身（`NamePart::value`）を取り出すのにも再利用する（issue #39 Phase 2）。
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
    fn qualified_name_は無引用の単純な名前を読み飛ばす() {
        assert_eq!(Cursor::new("t").qualified_name().map(|n| n.end), Some(1));
        assert_eq!(
            Cursor::new("t ADD COLUMNS").qualified_name().map(|n| n.end),
            Some(1)
        );
    }

    #[test]
    fn qualified_name_はドットで繋いだ修飾名を読み飛ばす() {
        assert_eq!(
            Cursor::new("cat.ns.t").qualified_name().map(|n| n.end),
            Some("cat.ns.t".len())
        );
        assert_eq!(
            Cursor::new("cat.ns.t ADD").qualified_name().map(|n| n.end),
            Some("cat.ns.t".len())
        );
    }

    #[test]
    fn qualified_name_は引用符付きの識別子を読み飛ばす() {
        let sql = r#""my table".ns.t"#;
        assert_eq!(
            Cursor::new(sql).qualified_name().map(|n| n.end),
            Some(sql.len())
        );
    }

    #[test]
    fn qualified_name_はドットの前後の空白やコメントを読み飛ばす() {
        assert_eq!(
            Cursor::new("cat . ns . t").qualified_name().map(|n| n.end),
            Some("cat . ns . t".len())
        );
        assert_eq!(
            Cursor::new("cat /* c */ . ns")
                .qualified_name()
                .map(|n| n.end),
            Some("cat /* c */ . ns".len())
        );
        assert_eq!(
            Cursor::new("cat -- c\n. ns")
                .qualified_name()
                .map(|n| n.end),
            Some("cat -- c\n. ns".len())
        );
    }

    #[test]
    fn qualified_name_はドットが続かなければ後ろのトリビアを消費せずに止まる() {
        // 名前の後ろにコメントがあっても、続きがドットでなければコメントは読み飛ばした
        // 位置に含めない（呼び出し元の次の読み取り（`Cursor::keyword` など）が読み飛ばす）。
        assert_eq!(
            Cursor::new("t -- comment\nADD COLUMN")
                .qualified_name()
                .map(|n| n.end),
            Some(1)
        );
    }

    #[test]
    fn qualified_name_は途中の位置からも読める() {
        let mut cursor = Cursor::new("ALTER TABLE cat.ns.t ADD COLUMNS");
        assert!(cursor.keyword("ALTER"));
        assert!(cursor.keyword("TABLE"));
        assert_eq!(
            cursor.qualified_name().map(|n| n.end),
            Some("ALTER TABLE cat.ns.t".len())
        );
    }

    #[test]
    fn qualified_name_は空の名前部分があれば_none_を返し位置を進めない() {
        for sql in [
            ".t", "cat..t", "cat. .t", "cat.", "(t)", "", "日本", " cat..t",
        ] {
            let mut cursor = Cursor::new(sql);
            assert_eq!(cursor.qualified_name(), None, "{sql:?}");
            // 失敗したときは先頭のトリビアも読み飛ばさない。
            assert_eq!(cursor.rest(), sql, "{sql:?}");
        }
    }

    #[test]
    fn qualified_name_は引用符付きの中身と無引用の小文字を値として返す() {
        let name = Cursor::new(r#"CAT."My ""T""""#).qualified_name().unwrap();
        assert_eq!(name.values(), ["cat", r#"My "T""#]);

        // 範囲（`text`・`start`・`end`）はドットの前後のトリビアを含む元の文字列。
        let sql = r#""s3tablescatalog/b" . ns . t"#;
        let name = Cursor::new(sql).qualified_name().unwrap();
        assert_eq!(name.values(), ["s3tablescatalog/b", "ns", "t"]);
        assert_eq!(name.text, sql);
        assert_eq!((name.start, name.end), (0, sql.len()));

        // 最後の名前部分の後ろのトリビアは消費しない。
        let mut cursor = Cursor::new("t -- comment\nADD COLUMN");
        assert_eq!(cursor.qualified_name().map(|n| n.end), Some(1));
        assert_eq!(cursor.rest(), " -- comment\nADD COLUMN");
    }

    #[test]
    fn unquote_は両端の引用符を外し重ねた引用符を戻す() {
        assert_eq!(unquote(r#""a""b""#), r#"a"b"#);
        assert_eq!(unquote("abc"), "abc");
        // 閉じていなければ外さない。
        assert_eq!(unquote(r#""abc"#), r#""abc"#);
    }
}
