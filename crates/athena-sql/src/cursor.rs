//! 受け取った SQL を先頭から読み進める Cursor（キーワードの照合。修飾名・リテラル・識別子は #195 の後続フェーズで足す）。

use crate::trivia::skip_trivia;

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
        if rest[keyword.len()..].starts_with(|c: char| c.is_ascii_alphanumeric() || c == '_') {
            return false;
        }
        self.pos = start + keyword.len();
        true
    }
}

/// `Cursor::keyword` の上の橋渡し。athena-local の呼び出し元が全部 `Cursor` に寄ったら消す（#195 フェーズ 4）。
pub fn skip_keyword<'a>(input: &'a str, keyword: &str) -> Option<&'a str> {
    let mut cursor = Cursor::new(input);
    cursor.keyword(keyword).then(|| cursor.rest())
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
}
