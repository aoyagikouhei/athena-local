//! SQL の字句処理と、athena-local が必要とする文の頭・句の認識を置く内部 crate（#192）。
//!
//! 完全なパーサは目指さず、SQL が正しいかどうかも判定しない。トークンと句は元の SQL での位置を持ち、
//! 書き換えは範囲の差し替えだけにする。規則と理由は docs/dev/decisions.md の「SQL の内部 crate（athena-sql）」。
//! 今あるのは #194 で athena-local の `src/catalog.rs` から中身を変えずに移した字句処理の道具で、
//! athena-local は `athena_sql::foo()` で呼ぶ。doc の中のパスは athena-local の `src/` からの相対。

/// `'...'` や `"..."` の終わりの次の位置。引用符を 2 つ重ねたものは中身として読む。閉じていなければ末尾。
///
/// `operation/target_table.rs` が DROP TABLE の修飾名の引用符付き識別子を読むのにも再利用する（issue #39 Phase 2）。
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

/// `--` か `/*` で始まるコメントなら、その終わりの次の位置。閉じていなければ末尾。
///
/// `operation/target_table.rs` が DROP TABLE の修飾名を読むのにも再利用する（issue #39 Phase 2）。
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
    let bytes = sql.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b' ' | b'\t' | b'\r' | b'\n' => i += 1,
            _ => match comment_end(bytes, i) {
                Some(end) => i = end,
                None => break,
            },
        }
    }
    &sql[i..]
}

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
pub fn words(sql: &str) -> Vec<String> {
    let bytes = sql.as_bytes();
    let mut words = Vec::new();
    let mut i = 0;
    while i < bytes.len() {
        i = skip_trivia(bytes, i);
        let start = i;
        while i < bytes.len() {
            match bytes[i] {
                b' ' | b'\t' | b'\r' | b'\n' => break,
                b'\'' | b'"' => i = skip_quoted(bytes, i),
                _ => match comment_end(bytes, i) {
                    Some(_) => break,
                    None => i += 1,
                },
            }
        }
        if i > start {
            words.push(sql[start..i].to_uppercase());
        }
    }
    words
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
        // コメントでない `/` や `-` は語の一部のまま。
        assert_eq!(words("SELECT a/b, a-b"), ["SELECT", "A/B,", "A-B"]);
        // `(` は取り除かない（`(SELECT` のまま。呼び出し元が要るときだけ取り除く）。
        assert_eq!(words("(SELECT 1)"), ["(SELECT", "1)"]);
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
