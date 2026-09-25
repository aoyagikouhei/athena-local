//! 空白とコメント、識別子の文字と記号の境目で切った語の並び。

use crate::trivia::{comment_end, is_identifier_byte, skip_quoted, skip_trivia};

/// 空白とコメントを区切りにして、大文字にした語の並びにする。文の種類の判定
/// （`operation/classification.rs` の `words()` と `results::ResultFile::of`）が使う。
/// キーワードの間のコメント（`DROP /* c */ TABLE`、`CREATE TABLE t AS -- c\nSELECT 1`）は、
/// 本物と同じく空白として扱う（2026-09-22 実測。#52。`split_whitespace` だと `/*` や `c` が
/// 語に数えられて `word(1)` がずれ、SubstatementType が省かれ CTAS の置き場所が変わっていた）。
///
/// 引用符の中（`'...'`／`"..."`）は `skip_quoted` で語の一部として飛ばし、その中の `--` や `/*` を
/// コメントと読まない。S3 Express のバケット名（`a--b--x-s3`）を `external_location` に書いた
/// 1 行の CTAS で、`--` から文末までが消えて `AS SELECT` を見失う退行を計画攻撃が見つけた。
/// `alias_qualified_names` と同じく、引用符 → コメント → その他の順で見る。
///
/// 識別子の文字（ASCII の英数字と `_`）と ASCII の記号（引用符の区間を含む）の境目でも切る
/// （`SELECT(1)` → `SELECT`・`(`・`1`・`)`、`TABLE"t"AS` → `TABLE`・`"T"`・`AS`）。本物はキーワードの直後に
/// 空白が無くても空白ありの形と同じに分類する（2026-09-25 実測。#200）。境目の規則は `Cursor::keyword` と同じ
/// 識別子の文字の判定を使う。制御文字や非 ASCII の文字（`U+3000` など）は境目にしない（Trino がそれらを
/// 構文エラーにするので分類まで届かず、境目にすると理由なく値が動く）。
pub fn words(sql: &str) -> Vec<String> {
    words_iter(sql).map(|word| word.upper).collect()
}

/// `words` の語 1 つ。`upper` は大文字にした語、`start`／`end` は元の SQL でのバイト範囲。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Word {
    pub upper: String,
    pub start: usize,
    pub end: usize,
}

/// `words_iter` が返す語の並び。
#[derive(Debug)]
pub struct Words<'a> {
    sql: &'a str,
    pos: usize,
}

/// `words` の語を先頭から順に返す。読む深さは呼び出し側が `take(n)` などで選ぶ。
/// 語の切り方は `words` と同じ（引用符は語の一部、`(` は取り除かない）で、`words` はこれを集めたもの。
pub fn words_iter(sql: &str) -> Words<'_> {
    Words { sql, pos: 0 }
}

impl Iterator for Words<'_> {
    type Item = Word;

    fn next(&mut self) -> Option<Word> {
        let bytes = self.sql.as_bytes();
        while self.pos < bytes.len() {
            self.pos = skip_trivia(bytes, self.pos);
            let start = self.pos;
            let mut previous = None;
            // 引用符 → コメント → その他の順で見る（引用符の中の `--` や `/*` をコメントと読まない）。
            while self.pos < bytes.len() {
                let byte = bytes[self.pos];
                if matches!(byte, b' ' | b'\t' | b'\r' | b'\n') {
                    break;
                }
                let class = Class::of(byte);
                if previous.is_some_and(|previous: Class| previous.splits_from(class)) {
                    break;
                }
                previous = Some(class);
                match byte {
                    b'\'' | b'"' => self.pos = skip_quoted(bytes, self.pos),
                    _ => match comment_end(bytes, self.pos) {
                        Some(_) => break,
                        None => self.pos += 1,
                    },
                }
            }
            if self.pos > start {
                return Some(Word {
                    upper: self.sql[start..self.pos].to_uppercase(),
                    start,
                    end: self.pos,
                });
            }
        }
        None
    }
}

/// 語の中の 1 バイトの種類。識別子の文字と記号の境目だけで語を切る。
#[derive(Clone, Copy, PartialEq, Eq)]
enum Class {
    Identifier,
    Punctuation,
    Other,
}

impl Class {
    fn of(byte: u8) -> Self {
        if is_identifier_byte(byte) {
            Self::Identifier
        } else if byte.is_ascii_punctuation() {
            Self::Punctuation
        } else {
            Self::Other
        }
    }

    fn splits_from(self, next: Self) -> bool {
        matches!(
            (self, next),
            (Self::Identifier, Self::Punctuation) | (Self::Punctuation, Self::Identifier)
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_は空白とコメントの両方を区切りにして大文字の語にする() {
        assert_eq!(words("DROP TABLE t"), ["DROP", "TABLE", "T"]);
        // キーワードの間のコメントは空白と同じ区切り（本物と同じ。2026-09-22 実測）。
        assert_eq!(words("DROP /* c */ TABLE t"), ["DROP", "TABLE", "T"]);
        assert_eq!(words("DROP -- c\nTABLE t"), ["DROP", "TABLE", "T"]);
        // 空白を挟まずに語に接していても区切りになる。
        assert_eq!(words("DROP/* c */TABLE t"), ["DROP", "TABLE", "T"]);
        assert_eq!(words("SELECT 1--c\n2"), ["SELECT", "1", "2"]);
        // 先頭と末尾のトリビアは語にならない。
        assert_eq!(words("  /* a */ SELECT 1 -- c"), ["SELECT", "1"]);
        // コメントでない `/` や `-` も記号として識別子の文字から切り離す。
        assert_eq!(
            words("SELECT a/b, a-b"),
            ["SELECT", "A", "/", "B", ",", "A", "-", "B"]
        );
        // `(` は取り除かない（`(` だけの語になる。呼び出し元が要るときだけ取り除く）。
        assert_eq!(words("(SELECT 1)"), ["(", "SELECT", "1", ")"]);
        // 多バイト文字を含む語でも途中を切らない。
        assert_eq!(
            words("SELECT '日本語' /* あ */ x"),
            ["SELECT", "'日本語'", "X"]
        );
    }

    #[test]
    fn words_は引用符の中のコメント記号をコメントと読まない() {
        // S3 Express のバケット名は `--` を含む。1 行の CTAS でここから文末が消えると
        // `AS SELECT` を見失う（計画攻撃で見つかった退行）。
        assert_eq!(
            words("SELECT 's3://a--b--x-s3/p/' AS x"),
            ["SELECT", "'S3://A--B--X-S3/P/'", "AS", "X"]
        );
        assert_eq!(words("SELECT '/*' AS x"), ["SELECT", "'/*'", "AS", "X"]);
        assert_eq!(
            words(r#"SELECT "a--b" FROM t"#),
            ["SELECT", "\"A--B\"", "FROM", "T"]
        );
        // 引用符の中の空白も語を切らない。重ねた引用符は中身として読む。
        assert_eq!(words("SELECT 'a b' x"), ["SELECT", "'A B'", "X"]);
        assert_eq!(
            words("SELECT 'it''s -- x' y"),
            ["SELECT", "'IT''S -- X'", "Y"]
        );
        // 閉じていない引用符は末尾まで 1 語。
        assert_eq!(words("SELECT 'a -- b"), ["SELECT", "'A -- B"]);
    }

    #[test]
    fn words_は識別子の文字と_ascii_の記号の境目でも語を切る() {
        // キーワードの直後に空白なしで `(`・引用符・`*` が続いても、キーワードは 1 語になる。
        // 本物は空白ありの形と同じに分類する（2026-09-25 実測。#200）。
        assert_eq!(words("SELECT(1)"), ["SELECT", "(", "1", ")"]);
        assert_eq!(words("SELECT'a'"), ["SELECT", "'A'"]);
        assert_eq!(words("SELECT*FROM t"), ["SELECT", "*", "FROM", "T"]);
        assert_eq!(
            words("SHOW CREATE TABLE\"t\""),
            ["SHOW", "CREATE", "TABLE", "\"T\""]
        );
        // 引用符の区間の後ろに識別子の文字が続いても切る。記号どうしは切らない。
        assert_eq!(
            words("CREATE TABLE\"t\"AS((SELECT 1))"),
            ["CREATE", "TABLE", "\"T\"", "AS", "((", "SELECT", "1", "))"]
        );
        // 識別子の文字は ASCII の英数字と `_`。
        assert_eq!(words("A_B(1)"), ["A_B", "(", "1", ")"]);
        assert_eq!(words("T1\"x\""), ["T1", "\"X\""]);
        // 空白でも ASCII の記号でもない文字（制御文字・非 ASCII の空白）は境目にしない。
        // Trino はこれらを構文エラーにするので、分類まで届かない（2026-09-25 手元で確認。#200）。
        assert_eq!(words("SELECT\x0B1"), ["SELECT\x0B1"]);
        assert_eq!(words("SELECT\u{3000}1"), ["SELECT\u{3000}1"]);
    }

    #[test]
    fn words_はコメントだけの文や未閉じのコメントで空か途中までになる() {
        assert!(words("").is_empty());
        assert!(words("   ").is_empty());
        assert!(words("/* only */").is_empty());
        assert!(words("-- only").is_empty());
        // 未閉じの `/*` は comment_end と同じく末尾まで飛ばす。
        assert_eq!(words("SELECT /* c"), ["SELECT"]);
        assert_eq!(words("SELECT/* c"), ["SELECT"]);
    }

    #[test]
    fn words_iter_は_words_と同じ語を元の_sql_での範囲つきで返す() {
        for sql in [
            "SELECT '日本語' /* あ */ x",
            "SELECT 's3://a--b--x-s3/p/' AS x",
            "SELECT /* c",
            "(SELECT 1)",
            "CREATE TABLE\"t\"AS(SELECT '日本' x)",
        ] {
            assert_eq!(
                words_iter(sql).map(|word| word.upper).collect::<Vec<_>>(),
                words(sql),
                "{sql}"
            );
            for word in words_iter(sql) {
                assert_eq!(
                    sql[word.start..word.end].to_uppercase(),
                    word.upper,
                    "{sql}"
                );
            }
        }
        // 範囲はバイト単位で、多バイト文字の後ろの語も元の SQL の位置を指す。
        assert_eq!(
            words_iter("SELECT '日本語' /* あ */ x").collect::<Vec<_>>(),
            [
                Word {
                    upper: "SELECT".to_string(),
                    start: 0,
                    end: 6
                },
                Word {
                    upper: "'日本語'".to_string(),
                    start: 7,
                    end: 18
                },
                Word {
                    upper: "X".to_string(),
                    start: 29,
                    end: 30
                },
            ]
        );
        // `(` は取り除かず、識別子の文字との境目で切った範囲を返す。
        assert_eq!(
            words_iter("(SELECT 1)").take(2).collect::<Vec<_>>(),
            [
                Word {
                    upper: "(".to_string(),
                    start: 0,
                    end: 1
                },
                Word {
                    upper: "SELECT".to_string(),
                    start: 1,
                    end: 7
                },
            ]
        );
        // `take(1)` は先頭の語だけを読む。
        assert_eq!(
            words_iter("  /* a */ SELECT 1 -- c")
                .take(1)
                .map(|word| word.upper)
                .collect::<Vec<_>>(),
            ["SELECT"]
        );
    }
}
