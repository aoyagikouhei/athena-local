//! ブロックコメントの位置と、先頭コメントの字句を読む（2026-09-26 実測 ラウンド 2・3。#244）。

/// `pos` から、空白（空白・タブ・CR・LF・VT・FF）と行コメント（`-- ...`）だけを読み飛ばした位置が
/// ブロックコメント（`/*`）の開始なら、その位置を返す（ブロックコメント自体は読み飛ばさない。呼び出し側が
/// 最初のブロックコメントの位置を知るための道具。行コメントは空白と同じに読み飛ばす。2026-09-26 実測 d6）。
pub(super) fn comment_start(query: &str, pos: usize) -> Option<usize> {
    let bytes = query.as_bytes();
    let mut i = pos;
    while i < bytes.len() {
        match bytes[i] {
            b' ' | b'\t' | b'\r' | b'\n' | b'\x0B' | b'\x0C' => i += 1,
            b'-' if bytes.get(i + 1) == Some(&b'-') => {
                i = athena_sql::comment_end(bytes, i).unwrap_or(bytes.len());
            }
            _ => break,
        }
    }
    query[i..].starts_with("/*").then_some(i)
}

/// `pos`（`/` の位置）の行（1 始まり）と列（0 始まり、UTF-16 単位）を、**2 文字以上続く空白**
/// （空白・タブ・CR・LF・VT・FF）を 1 つの空白に畳んだ文で数える（2026-09-26 実測 p1 ほか。ラウンド 3）。
/// 1 文字の空白はそのまま（改行 1 つは行を進める、タブ 1 つは 1 列）。畳んだ空白は改行を含んでいても
/// 行を進めない（`SHOW\n\n/* c */` → 1:5。p6）。文の一番先頭の空白の連続（畳む・畳まないによらず）は
/// 数えずに落ちる（`   /* c */ SHOW ...` → 1:0。p7）。
pub(super) fn position(query: &str, pos: usize) -> (usize, usize) {
    const WS: [char; 6] = [' ', '\t', '\r', '\n', '\u{0B}', '\u{0C}'];
    let prefix = &query[..pos];
    let mut line = 1;
    let mut col = 0;
    let mut chars = prefix.chars().peekable();
    // まだ何も処理していない（先頭の空白の連続の途中の）間だけ true。
    let mut at_start = true;
    while let Some(c) = chars.next() {
        if WS.contains(&c) {
            let mut run_len = 1;
            while chars.peek().is_some_and(|next| WS.contains(next)) {
                chars.next();
                run_len += 1;
            }
            if at_start {
                // 文の一番先頭の空白は落ちる（実測 p7）。
            } else if run_len >= 2 {
                // 2 文字以上は改行を含んでいても 1 つの空白に畳む（行は進めない）。
                col += 1;
            } else if c == '\n' {
                line += 1;
                col = 0;
            } else {
                col += 1;
            }
        } else {
            col += c.len_utf16();
        }
        at_start = false;
    }
    (line, col)
}

/// `/*` の直後（`comment_start` が返した位置）から、Hive の字句規則で最初の字句を読む
/// （2026-09-26 実測 s20〜s27・c1〜c13。ラウンド 2・3）。コメントの閉じ `*/` を越えて読んでよい。
/// 測っていない字句（`<=` などの 2 文字の記号、引用符の中のエスケープ）は同じ規則で近似する（D5）。
pub(super) fn leading_token(query: &str, comment_at: usize) -> &str {
    let bytes = query.as_bytes();
    let mut i = comment_at + 2; // "/*" の直後。
    while i < bytes.len() {
        match bytes[i] {
            b' ' | b'\t' | b'\r' | b'\n' | b'\x0B' | b'\x0C' => i += 1,
            byte if byte >= 0x80 => {
                // 非 ASCII の 1 文字ぶん（UTF-8 の続きバイトも含む）飛ばす。
                i += query[i..].chars().next().map_or(1, char::len_utf8);
            }
            _ => break,
        }
    }
    let start = i;
    if start >= bytes.len() {
        return "";
    }
    match bytes[start] {
        b'\'' | b'"' => &query[start..athena_sql::skip_quoted(bytes, start)],
        byte if byte.is_ascii_alphanumeric() || byte == b'_' => {
            let mut end = start;
            while end < bytes.len() && (bytes[end].is_ascii_alphanumeric() || bytes[end] == b'_') {
                end += 1;
            }
            // 数字だけの並びに `.` と数字が続けば小数まで（`1.5`。c12）。
            if bytes[start..end].iter().all(u8::is_ascii_digit)
                && bytes.get(end) == Some(&b'.')
                && bytes.get(end + 1).is_some_and(u8::is_ascii_digit)
            {
                end += 1;
                while end < bytes.len() && bytes[end].is_ascii_digit() {
                    end += 1;
                }
            }
            &query[start..end]
        }
        // それ以外（非 ASCII はここに来ない）は 1 文字（`,`・`)`・`+`・`*` など）。
        _ => &query[start..start + 1],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn comment_start_は空白と行コメントを読み飛ばしブロックコメントの開始だけ返す() {
        assert_eq!(comment_start("/* c */ t", 0), Some(0));
        assert_eq!(comment_start("SHOW /* c */", 4), Some(5));
        assert_eq!(comment_start("SHOW\n\n/* c */", 4), Some(6));
        assert_eq!(comment_start("SHOW -- c\n/* x */", 4), Some(10));
        // ブロックコメントでなければ None（実際のキーワード・名前などが続く）。
        assert_eq!(comment_start("SHOW CREATE", 4), None);
        assert_eq!(comment_start("", 0), None);
    }

    #[test]
    fn position_は_2文字以上の空白を畳んで行と列を数える() {
        for (query, at, expected) in [
            ("", 0, (1, 0)),
            ("SHOW  CREATE /*", "SHOW  CREATE ".len(), (1, 12)),
            ("SHOW\t\t/*", "SHOW\t\t".len(), (1, 5)),
            ("SHOW\n\n/*", "SHOW\n\n".len(), (1, 5)),
            ("SHOW CREATE\n  /*", "SHOW CREATE\n  ".len(), (1, 12)),
            ("SHOW\n/*", "SHOW\n".len(), (2, 0)),
            ("MSCK REPAIR  /*", "MSCK REPAIR  ".len(), (1, 12)),
            (
                "SHOW CREATE TABLE  /*",
                "SHOW CREATE TABLE  ".len(),
                (1, 18),
            ),
            ("ALTER TABLE  /*", "ALTER TABLE  ".len(), (1, 12)),
            // 単独の空白はそのまま数える。
            ("SHOW /*", "SHOW ".len(), (1, 5)),
            // 文の一番先頭の空白は、畳む・畳まないによらず落ちる（p7）。
            ("   /*", "   ".len(), (1, 0)),
            ("\n/*", "\n".len(), (1, 0)),
        ] {
            assert_eq!(position(query, at), expected, "{query:?}@{at}");
        }
    }

    #[test]
    fn leading_token_は_hive_の字句規則で最初の字句を読む() {
        for (comment, expected) in [
            ("/* c */", "c"),
            ("/* abc */", "abc"),
            ("/**/", "*"),
            ("/*c*/", "c"),
            ("/* a b */", "a"),
            ("/* , */", ","),
            ("/* 1 */", "1"),
            ("/* 1.5 */", "1.5"),
            ("/* 1a */", "1a"),
            ("/* _a1 */", "_a1"),
            ("/* a.b */", "a"),
            ("/* a-b */", "a"),
            ("/*+ x */", "+"),
            ("/* あ */", "*"),
            ("/*\nc */", "c"),
            ("/* 'x' */", "'x'"),
            ("/* \"q\" */", "\"q\""),
            ("/* ) */", ")"),
        ] {
            assert_eq!(leading_token(comment, 0), expected, "{comment}");
        }
        // 空のコメント（閉じ記号すら無い）は空文字列。
        assert_eq!(leading_token("/*", 0), "");
    }
}
