//! 空白・コメント・引用符の読み飛ばし。

/// `'...'` や `"..."` の終わりの次の位置。引用符を 2 つ重ねたものは中身として読む。閉じていなければ末尾。
///
/// 修飾名の引用符付き識別子（`name.rs`）や識別子・文字列リテラル（`cursor.rs`）を読むのにも再利用する（issue #39 Phase 2）。
pub fn skip_quoted(bytes: &[u8], start: usize) -> usize {
    let quote = bytes[start];
    let mut i = start + 1;
    while i < bytes.len() {
        if bytes[i] == quote {
            if bytes.get(i + 1) == Some(&quote) {
                i += 2;
                continue;
            }
            return i + 1;
        }
        i += 1;
    }
    bytes.len()
}

/// 識別子の文字（ASCII の英数字と `_`）か。`Cursor` のキーワード・識別子の境界、修飾名の無引用の名前部分、
/// `words` の語の境目が共有する（同じ規則の別定義は作らない。#200）。
pub(crate) fn is_identifier_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_'
}

/// `--` か `/*` で始まるコメントなら、その終わりの次の位置。閉じていなければ末尾。
///
/// 修飾名（`name.rs`）と `Cursor` のトリビアの読み飛ばしにも再利用する（issue #39 Phase 2）。
pub fn comment_end(bytes: &[u8], start: usize) -> Option<usize> {
    let rest = &bytes[start..];
    if rest.starts_with(b"--") {
        let end = rest.iter().position(|&b| b == b'\n').unwrap_or(rest.len());
        Some(start + end)
    } else if rest.starts_with(b"/*") {
        let end = rest[2..]
            .windows(2)
            .position(|pair| pair == b"*/")
            .map_or(rest.len(), |position| position + 4);
        Some(start + end)
    } else {
        None
    }
}

/// 先頭の空白とコメント（`--` と `/* */`）を、交互に現れても全部読み飛ばした残りを返す。
/// 文の種類の判定（`words()`／`ResultFile::of`）が使う。区切りはすべて ASCII なので、
/// バイト単位で走査しても UTF-8 の途中を切らない（区切りに使う文字がどれも ASCII のため）。
///
/// 全部がトリビアだった（コメントだけの文や空白だけの文）ときは空文字列を返す。本物はそういう文を
/// 「先頭のキーワードが無い」として構文エラーにするので、athena-local でも直後の構文チェック
/// （`Trino::syntax_error`）が弾き、分類のこの粗さは観測できる差にならない（2026-09-18 実測）。
///
/// 未閉じの `/*` は `comment_end` と同じく末尾まで飛ばす。本物は未閉じの `/*` をコメントとして
/// 扱わず `line 1:1` でそこの `/` を読むという違いがあるが（2026-09-18 実測）、どちらも構文エラーに
/// なって実行が作られないので、この差も観測できない。
pub fn skip_leading_trivia(sql: &str) -> &str {
    &sql[skip_trivia(sql.as_bytes(), 0)..]
}

/// 空白とコメントを読み飛ばした位置を返す。`skip_leading_trivia` は文字列を返すが、
/// ここでは呼び出し元がバイト位置を持ち回るのでバイト位置で返す。
pub fn skip_trivia(bytes: &[u8], mut i: usize) -> usize {
    while i < bytes.len() {
        match bytes[i] {
            b' ' | b'\t' | b'\r' | b'\n' => i += 1,
            _ => match comment_end(bytes, i) {
                Some(end) => i = end,
                None => break,
            },
        }
    }
    i
}

/// 引用符（`'` と `"`）とコメントの外にある `;` で区切った片。`;` 自体は含めず、空の片も残す
/// （`"a;"` は `["a", ""]`）。片は元の SQL の部分文字列なので、位置を失わない。
pub fn statements(sql: &str) -> Vec<&str> {
    let bytes = sql.as_bytes();
    let mut pieces = Vec::new();
    let (mut start, mut i) = (0, 0);
    while i < bytes.len() {
        match bytes[i] {
            b'\'' | b'"' => i = skip_quoted(bytes, i),
            b';' => {
                pieces.push(&sql[start..i]);
                i += 1;
                start = i;
            }
            _ => i = comment_end(bytes, i).unwrap_or(i + 1),
        }
    }
    pieces.push(&sql[start..]);
    pieces
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn statements_は引用符とコメントの外の_セミコロンだけで区切る() {
        assert_eq!(statements("SELECT 1"), ["SELECT 1"]);
        assert_eq!(statements("SELECT 1;"), ["SELECT 1", ""]);
        assert_eq!(statements("a; -- c"), ["a", " -- c"]);
        assert_eq!(statements("a;;b"), ["a", "", "b"]);
        assert_eq!(statements("SELECT 'a;b'; x"), ["SELECT 'a;b'", " x"]);
        assert_eq!(statements(r#"SELECT 1 AS "a;b""#), [r#"SELECT 1 AS "a;b""#]);
        assert_eq!(
            statements("SELECT 1 -- a;b\n;x"),
            ["SELECT 1 -- a;b\n", "x"]
        );
        assert_eq!(statements("SELECT 1 /* a;b */"), ["SELECT 1 /* a;b */"]);
        // 閉じていない引用符・コメントは末尾まで中身として読む。
        assert_eq!(statements("SELECT 'a; b"), ["SELECT 'a; b"]);
        assert_eq!(statements("SELECT /* a; b"), ["SELECT /* a; b"]);
    }

    #[test]
    fn トリビアが無ければ受け取った_sql_をそのまま返す() {
        assert_eq!(skip_leading_trivia("SELECT 1"), "SELECT 1");
        assert_eq!(skip_leading_trivia("(SELECT 1)"), "(SELECT 1)");
    }

    #[test]
    fn 行コメントを読み飛ばす() {
        assert_eq!(skip_leading_trivia("-- c\nSELECT 1"), "SELECT 1");
        assert_eq!(skip_leading_trivia("--c\nSELECT 1"), "SELECT 1");
    }

    #[test]
    fn ブロックコメントを読み飛ばす() {
        assert_eq!(skip_leading_trivia("/* c */ SELECT 1"), "SELECT 1");
        assert_eq!(skip_leading_trivia("/* c */SELECT 1"), "SELECT 1");
        assert_eq!(skip_leading_trivia("/* a\nb */ SELECT 1"), "SELECT 1");
        assert_eq!(skip_leading_trivia("/*/ x */ SELECT 1"), "SELECT 1");
    }

    #[test]
    fn 空白とコメントを交互に読み飛ばす() {
        assert_eq!(
            skip_leading_trivia("  -- a\n\n /* b */  SELECT 1"),
            "SELECT 1"
        );
        assert_eq!(skip_leading_trivia("-- a\n-- b\nSELECT 1"), "SELECT 1");
    }

    #[test]
    fn コメントだけの文は空文字列になる() {
        assert_eq!(skip_leading_trivia("-- only"), "");
        assert_eq!(skip_leading_trivia("/* only */"), "");
        assert_eq!(skip_leading_trivia("   "), "");
        assert_eq!(skip_leading_trivia(""), "");
        // 未閉じの `/*` も comment_end が末尾まで飛ばすので空文字列になる。
        assert_eq!(skip_leading_trivia("/* c SELECT 1"), "");
    }

    #[test]
    fn 非_ascii_のコメントでもバイト単位の走査が途中を切らない() {
        assert_eq!(skip_leading_trivia("-- あ\nSELECT 1"), "SELECT 1");
    }

    #[test]
    fn skip_quoted_は重ねた引用符を中身として読み閉じていなければ末尾を返す() {
        assert_eq!(skip_quoted(b"'it''s' x", 0), "'it''s'".len());
        assert_eq!(skip_quoted(br#""a""b" x"#, 0), r#""a""b""#.len());
        // 開いた引用符と違う種類の引用符は閉じにならない。
        assert_eq!(skip_quoted(br#"'a"b' x"#, 0), r#"'a"b'"#.len());
        assert_eq!(skip_quoted(b"'abc", 0), "'abc".len());
    }

    #[test]
    fn comment_end_は行コメントを改行の手前までブロックコメントを閉じの後ろまでとし閉じていなければ末尾まで()
     {
        assert_eq!(comment_end(b"--c\nx", 0), Some("--c".len()));
        assert_eq!(comment_end(b"/**/x", 0), Some("/**/".len()));
        // 開きの `/*` の `*` を閉じの `*/` に数えない。
        assert_eq!(comment_end(b"/*/ x */", 0), Some("/*/ x */".len()));
        assert_eq!(comment_end(b"/* x", 0), Some("/* x".len()));
        assert_eq!(comment_end(b"-x", 0), None);
    }
}
