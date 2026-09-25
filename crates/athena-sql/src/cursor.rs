//! 受け取った SQL を先頭から読み進める Cursor（キーワード・リテラル・識別子・記号の読み取り。修飾名は `name.rs`）。

use crate::trivia::{is_identifier_byte, skip_leading_trivia, skip_quoted, skip_trivia};

/// 受け取った SQL の上を先頭から読み進める位置。読む系のメソッドは、先頭の空白とコメントを読み飛ばし、
/// 一致したときだけ位置を進め、後ろのトリビアは消費しない（呼び出し元が次の読み取りで読み飛ばす）。
#[derive(Debug)]
pub struct Cursor<'a> {
    pub(crate) sql: &'a str,
    pub(crate) pos: usize,
}

impl<'a> Cursor<'a> {
    pub fn new(sql: &'a str) -> Self {
        Self { sql, pos: 0 }
    }

    /// 今の位置から末尾まで（トリビアを読み飛ばさない）。
    pub fn rest(&self) -> &'a str {
        &self.sql[self.pos..]
    }

    /// 先頭の空白・コメントを読み飛ばしてからキーワードを 1 語ぶん読み飛ばす。大文字小文字は
    /// 区別せず、続きが識別子の文字（英数字・`_`）なら別の語（`COLUMN` に対する `COLUMNS` など）
    /// とみなして一致させない。続きが `(` や文字列リテラルの `'` など識別子でない文字なら
    /// 空白が無くても一致させる（`TBLPROPERTIES(...)` のような書き方。3 本目のレビューで実測）。
    ///
    /// `operation/classification.rs` の ALTER TABLE の判定（`COLUMN` と `COLUMNS` を分ける）と、
    /// `operation/target_table.rs` の DROP TABLE / ALTER TABLE の対象テーブルの解析
    /// （`TABLE` と `TABLES` を分ける）が再利用する。もとは 2 ファイルに同名で別定義があり、
    /// トリビアを内側で読み飛ばすか呼び出し元に任せるかだけが違っていた（issue #49 で内側に寄せて統合）。
    pub fn keyword(&mut self, keyword: &str) -> bool {
        let start = skip_trivia(self.sql.as_bytes(), self.pos);
        let rest = &self.sql[start..];
        // 長さが足りないときと、キーワードの長さの位置が多バイト文字の途中のときは None になる。
        let Some(head) = rest.get(..keyword.len()) else {
            return false;
        };
        if !head.eq_ignore_ascii_case(keyword) {
            return false;
        }
        if rest
            .as_bytes()
            .get(keyword.len())
            .is_some_and(|&byte| is_identifier_byte(byte))
        {
            return false;
        }
        self.pos = start + keyword.len();
        true
    }

    /// リテラルを 1 つ読む（`-` を付けてもよい数、`'...'`、TRUE／FALSE）。文字列は `skip_quoted` で読む
    /// （`'a''b'` も 1 つ。中の `--` はコメントではない）。閉じていない `'...` は末尾まで読んで受理する
    /// （その文は構文チェックが 400 にして実行を作らないので、判定の結果は捨てられる）。
    /// TRUE／FALSE は `keyword` で読み、キーワードの境界の規則を 2 本目にしない。
    pub fn literal(&mut self) -> bool {
        let start = skip_trivia(self.sql.as_bytes(), self.pos);
        if let Some(end) = literal_end(self.sql, start) {
            self.pos = end;
            return true;
        }
        self.keyword("TRUE") || self.keyword("FALSE")
    }

    /// 識別子を 1 つ読む。無引用（英字か `_` で始まり、英数字と `_` が続く）か、
    /// `"..."`（`""` の重ねも 1 つ。閉じていなければ末尾まで。`literal` の `'...'` と同じ扱い）。
    /// 数字で始まる無引用は読まない（修飾名の `NamePart` は数字で始まってもよいのと違う）。
    pub fn identifier(&mut self) -> bool {
        let bytes = self.sql.as_bytes();
        let start = skip_trivia(bytes, self.pos);
        let rest = &self.sql[start..];
        let end = if rest.starts_with('"') {
            skip_quoted(bytes, start)
        } else if rest.starts_with(|c: char| c.is_ascii_alphabetic() || c == '_') {
            rest.bytes()
                .position(|byte| !is_identifier_byte(byte))
                .map_or(self.sql.len(), |len| start + len)
        } else {
            return false;
        };
        self.pos = end;
        true
    }

    /// 先頭の空白・コメントを読み飛ばした位置のバイトが `symbol`（ASCII の記号）なら、それを読む。
    pub fn punct(&mut self, symbol: u8) -> bool {
        let start = skip_trivia(self.sql.as_bytes(), self.pos);
        if self.sql.as_bytes().get(start) != Some(&symbol) {
            return false;
        }
        self.pos = start + 1;
        true
    }

    /// 今の位置から末尾まで空白とコメントしか無いか（`;` は末尾とみなさない）。
    pub fn at_end(&self) -> bool {
        skip_leading_trivia(self.rest()).is_empty()
    }
}

/// `start` から始まるリテラル（`'...'`、数、`-` を付けた数）の終わりの次の位置。TRUE／FALSE はここでは読まない。
fn literal_end(sql: &str, start: usize) -> Option<usize> {
    let bytes = sql.as_bytes();
    match bytes.get(start)? {
        b'\'' => Some(skip_quoted(bytes, start)),
        b'0'..=b'9' => number_end(sql, start),
        // `-` は数に直接続くときだけ（`SELECT -1` 実測。`- 1` は測っていない）。
        b'-' => number_end(sql, start + 1),
        _ => None,
    }
}

/// `start` から始まる数のリテラルの終わりの次の位置。
/// `1`、`1.5`、`1.5E0`（`e` でもよく、指数に符号を付けてもよい）。直後に識別子の文字や `.` が
/// 続くもの（`1.5.2`、`1E0x`）と、`.` や `E` の後に数字が無いもの（`1.`、`1E`）は数のリテラルとして
/// 読まない。
fn number_end(sql: &str, start: usize) -> Option<usize> {
    let input = &sql[start..];
    let digits = |s: &str| s.len() - s.trim_start_matches(|c: char| c.is_ascii_digit()).len();
    let mut end = digits(input);
    if end == 0 {
        return None;
    }
    if let Some(fraction) = input[end..].strip_prefix('.') {
        let count = digits(fraction);
        if count == 0 {
            return None;
        }
        end += 1 + count;
    }
    if let Some(exponent) = input[end..].strip_prefix(['E', 'e']) {
        let unsigned = exponent.strip_prefix(['+', '-']).unwrap_or(exponent);
        let count = digits(unsigned);
        if count == 0 {
            return None;
        }
        end += 1 + (exponent.len() - unsigned.len()) + count;
    }
    if input[end..].starts_with(|c: char| c.is_ascii_alphanumeric() || c == '_' || c == '.') {
        return None;
    }
    Some(start + end)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keyword_は大文字小文字を無視し続きが識別子の文字なら一致させない() {
        // 続きが識別子でない文字（括弧・引用符・コメント）か末尾なら、空白が無くても一致する。
        for (sql, keyword, rest) in [
            ("column(c int)", "COLUMN", "(c int)"),
            (r#"Table"t""#, "TABLE", r#""t""#),
            ("TABLE'x'", "TABLE", "'x'"),
            ("TABLE/* c */", "TABLE", "/* c */"),
            ("TABLE-- c", "TABLE", "-- c"),
            ("table", "TABLE", ""),
        ] {
            let mut cursor = Cursor::new(sql);
            assert!(cursor.keyword(keyword), "{sql}");
            assert_eq!(cursor.rest(), rest, "{sql}");
        }
        // 続きが識別子の文字なら別の語。長さが足りなくても一致しない。どれも位置を進めない。
        for (sql, keyword) in [
            ("COLUMNS (c int)", "COLUMN"),
            ("TABLE_X t", "TABLE"),
            ("TABLE1 t", "TABLE"),
            ("TAB", "TABLE"),
        ] {
            let mut cursor = Cursor::new(sql);
            assert!(!cursor.keyword(keyword), "{sql}");
            assert_eq!(cursor.rest(), sql, "{sql}");
        }
    }

    #[test]
    fn keyword_は先頭のトリビアを読み飛ばし後ろのトリビアは読まず一致しなければ進めない() {
        let mut cursor = Cursor::new("  /* a */ -- b\n ALTER /* c */ TABLE t");
        assert!(cursor.keyword("ALTER"));
        assert_eq!(cursor.rest(), " /* c */ TABLE t");
        // 一致しなければ先頭のトリビアも読み飛ばさない。
        assert!(!cursor.keyword("COLUMN"));
        assert_eq!(cursor.rest(), " /* c */ TABLE t");
        assert!(cursor.keyword("TABLE"));
        assert_eq!(cursor.rest(), " t");
    }

    #[test]
    fn keyword_は多バイト文字の途中で一致させず先頭の括弧を剥がさない() {
        for (sql, keyword) in [
            ("日本", "IF"),
            ("日本", "TABLE"),
            (r#""日本語""#, "IF"),
            ("(SELECT 1)", "SELECT"),
        ] {
            let mut cursor = Cursor::new(sql);
            assert!(!cursor.keyword(keyword), "{sql}");
            assert_eq!(cursor.rest(), sql, "{sql}");
        }
    }

    #[test]
    fn literal_は数と文字列と真偽値を読み形の崩れた数を読まない() {
        for (sql, rest) in [
            ("1", ""),
            ("1.5", ""),
            ("1.5E0", ""),
            ("1e0", ""),
            ("1E+1", ""),
            ("2.5e-1", ""),
            ("-1", ""),
            ("'a''b'", ""),
            ("TRUE", ""),
            ("false", ""),
            // 先頭のトリビアは読み飛ばし、後ろのトリビアは消費しない。
            ("/* c */ 1 , 2", " , 2"),
        ] {
            let mut cursor = Cursor::new(sql);
            assert!(cursor.literal(), "{sql}");
            assert_eq!(cursor.rest(), rest, "{sql}");
        }
        // `.` や `E` の後に数字が無い、`-` と数の間に空白がある、数の直後に識別子の文字や `.` が続く、
        // TRUE／FALSE の後ろに識別子の文字が続く、リテラルでない語。どれも位置を進めない。
        for sql in [
            "1.", "1E", "1E+", "-", "- 1", "1.5.2", "1E0x", "trueish", "NULL",
        ] {
            let mut cursor = Cursor::new(sql);
            assert!(!cursor.literal(), "{sql}");
            assert_eq!(cursor.rest(), sql, "{sql}");
        }
    }

    #[test]
    fn identifier_は英字か下線で始まる無引用と引用符付きを読む() {
        for (sql, rest) in [
            ("i", ""),
            ("_x", ""),
            (r#""a b""#, ""),
            (r#""a""b""#, ""),
            (" i2 , j", " , j"),
        ] {
            let mut cursor = Cursor::new(sql);
            assert!(cursor.identifier(), "{sql}");
            assert_eq!(cursor.rest(), rest, "{sql}");
        }
        // 数字で始まる無引用、文字列リテラル、記号は識別子として読まない。
        for sql in ["1x", "'x'", "("] {
            let mut cursor = Cursor::new(sql);
            assert!(!cursor.identifier(), "{sql}");
            assert_eq!(cursor.rest(), sql, "{sql}");
        }
    }

    #[test]
    fn punct_と_at_end_は先頭のトリビアを読み飛ばす() {
        let mut cursor = Cursor::new("  ,x");
        assert!(cursor.punct(b','));
        assert_eq!(cursor.rest(), "x");
        assert!(!cursor.at_end());
        // 一致しなければ位置を進めない。
        assert!(!cursor.punct(b','));
        assert_eq!(cursor.rest(), "x");

        let mut cursor = Cursor::new("/* c */,");
        assert!(cursor.punct(b','));
        assert!(cursor.at_end());

        // 末尾のトリビアは末尾とみなし、`;` は末尾とみなさない。
        assert!(Cursor::new("").at_end());
        assert!(Cursor::new("-- c\n").at_end());
        assert!(!Cursor::new(";").at_end());
        assert!(!Cursor::new(" ; -- c").at_end());
    }
}
