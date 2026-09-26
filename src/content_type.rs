//! 結果ファイル本体と `.metadata` に付ける Content-Type。本物の Athena は
//! `binary/octet-stream` と `application/octet-stream` を文の形で使い分ける
//! （2026-09-23 に 36 項目を対照つきで実測。issue #70。同日に 18 項目を足して裏取り。#76）。ファイル名（`ResultFile::of`）は
//! 先頭のキーワードだけで決まるが、Content-Type は SELECT の本文（リテラルだけか）まで見るので、
//! 判定をここに分けて置く。`.metadata` は本体と同じ値（36 項目すべて一致。例外は 140 MB の
//! マルチパート本体だけで、athena-local は単一の PUT しかしない）。

use athena_sql::{Cursor, words_iter};

use crate::results::ResultFile;

/// 本物がエンジンの計画を通さずに置くファイルの値（実測ではどれも `QueryPlanningTimeInMillis` が
/// 無かった）: リテラルだけの SELECT、SHOW（SHOW CREATE TABLE を除く。SHOW CREATE VIEW はこちら。
/// 2026-09-24 実測。#146・#151）、0 バイトの DDL。
pub(crate) const BINARY: &str = "binary/octet-stream";
/// それ以外: 式を含む SELECT、DESCRIBE、EXPLAIN、SHOW CREATE TABLE、SHOW FUNCTIONS（`.csv`）、DML と CTAS の `.metadata`、
/// 失敗の理由の `.txt`（2026-09-17 実測）、DROP TABLE × Iceberg など列なしでも `.metadata` を置く DDL
/// （2026-09-20／21 実測。issue #39）。
pub(crate) const APPLICATION: &str = "application/octet-stream";

/// 本体に付ける Content-Type。`ResultLocation::new` が保持し、`.metadata` にも同じ値を使う。
pub(crate) fn of(file: ResultFile, query: &str) -> &'static str {
    match file {
        ResultFile::Csv if is_literal_only_select(query) => BINARY,
        ResultFile::Csv => APPLICATION,
        ResultFile::Text => text_content_type(query),
        // 本体は書かず `.metadata` だけを置く文（INSERT と CTAS）。本物の `.metadata` は application
        // （2026-09-17／18 実測）。本体を書かないからといって到達しない値ではなく、
        // `ResultLocation::metadata` が引き継いで `.metadata` の実値になる（#70 の計画レビュー）。
        ResultFile::Manifest | ResultFile::Table => APPLICATION,
        ResultFile::Metadata | ResultFile::FailedText => {
            unreachable!("付随ファイルと失敗ファイルの Content-Type は ResultLocation が決める")
        }
    }
}

/// `.txt` の文。DESCRIBE（`DESC` も）・EXPLAIN・SHOW CREATE TABLE だけが application で、
/// 残りの SHOW（TABLES・DATABASES・COLUMNS・TBLPROPERTIES・VIEWS・PARTITIONS・CREATE VIEW）と
/// 0 バイトの DDL は binary（2026-09-23／24 実測）。DESCRIBE と SHOW CREATE TABLE の組は
/// `carries_execution_id`（`.metadata` に QueryExecutionId を載せる文）で、こちらは `EXPLAIN` も
/// application に入れる点が違う。`SHOW FUNCTIONS` は `.txt` ではなく
/// `.csv`（`ResultFile::Csv`）なのでここには届かず、SELECT と同じ判定で application になる
/// （2026-09-23 実測。#80）。`SHOW SESSION` と `SHOW STATS` は
/// 本物が StartQueryExecution で構文エラーにするので、値は無い（2026-09-23 実測。#76）。
/// `SHOW CREATE TABLE` の判定は SQL だけで決まる Hive の値で、Iceberg のテーブルなら本物は binary なので、
/// 形式の問い合わせの後に `operation/result_output.rs` が上書きする（2026-09-24 実測。#151）。
fn text_content_type(query: &str) -> &'static str {
    if plain_text_statement(query) {
        APPLICATION
    } else {
        BINARY
    }
}

/// `.txt` を application/octet-stream で置く文（DESCRIBE・DESC・SHOW CREATE TABLE・EXPLAIN）。本物ではこの群が
/// そのまま「GetQueryResults の UpdateCount を返さない文」でもある（2026-09-16〜24 実測。SHOW 系と DDL は 0 か
/// 無し、SELECT は 0。#160、#169）ので、`operation/completion.rs` の `update_count` も同じ述語で選ぶ。
/// Iceberg のテーブルへの DESCRIBE / SHOW CREATE TABLE だけは本物が binary・0 で、形式の問い合わせの後に上書きする。
pub(crate) fn plain_text_statement(query: &str) -> bool {
    carries_execution_id(query)
        || words_iter(query)
            .next()
            .is_some_and(|word| word.upper == "EXPLAIN")
}

/// 本物が `.metadata` を素の protobuf で置き、先頭（field 1）に QueryExecutionId を載せる文:
/// DESCRIBE（`DESC` も）と SHOW CREATE TABLE（2026-09-17 実測）。同じ文が本体と `.metadata` を
/// application で置く（2026-09-23 実測）ので、Content-Type の判定と `.metadata` のクエリ ID の
/// 選択（`operation/result_output.rs` の `metadata_query_id`）はこの述語を共有する（#151）。
/// `SHOW CREATE` は 3 語目が `TABLE` のときだけで、`SHOW CREATE VIEW` は本物が不透明な `.metadata` を
/// binary で置く（2026-09-24 実測。#146・#151）ので入れない。`SHOW CREATE SCHEMA` などほかの
/// `SHOW CREATE ...` は Athena の構文に無く未実測で、`.txt` の既定（binary）に落ちる。
/// 語は `athena_sql::words_iter` で先頭の 3 語だけ読むので、先頭やキーワードの間のコメントは語にならない。
pub(crate) fn carries_execution_id(query: &str) -> bool {
    let words: Vec<String> = words_iter(query).take(3).map(|word| word.upper).collect();
    let word = |index: usize| words.get(index).map(String::as_str).unwrap_or_default();
    matches!(
        (word(0), word(1), word(2)),
        ("DESCRIBE" | "DESC", _, _) | ("SHOW", "CREATE", "TABLE")
    )
}

/// `SELECT` の後ろが、リテラル（`-` を付けてもよい整数・小数・指数つきの数、`'...'`、TRUE／FALSE）に
/// 任意で別名（`AS` の有無を問わず、無引用か `"..."` の識別子）の付いたものを `,` で並べただけで
/// 終わる文。実測した形は `SELECT 1`、`SELECT 1, 2`、`SELECT 'a'`、`SELECT 1.5`、`SELECT 1 AS i`、
/// `SELECT true`、`SELECT 1, 'a'`、`SELECT 23807 AS fresh`（#70）、`SELECT 1 AS i, 2 AS j`、`select 1`、
/// `SELECT -1`、`SELECT 1.5E0`、`SELECT 1 AS "x"`、`SELECT 1 i`（#76）と、先頭・キーワードの間・末尾に
/// コメントを置いたもの。リテラルは括弧で包んでもよく（`SELECT (1)`、`SELECT ((1))`、`SELECT (1) AS x`、
/// `SELECT ('a')`、`SELECT (-1)`、`SELECT (/* c */ 1)` など）、`-` と数の間に空白があってもよい（`SELECT - 1`）
/// （2026-09-25 実測。#205）。括弧の外の符号（`-(1)`、`- (1)`）と `+1` は本物も式として application にする。
/// 一般化は「別名・符号・指数・括弧の組み合わせ」「3 重以上の括弧」「小文字の `e` と符号つきの指数」「`-` と数の間のコメント」
/// 「キーワードの大文字小文字」だけ。測って application だった形（`LIMIT`、`DATE '...'` のような
/// 型付きリテラル、式、`ARRAY[1]`、`(SELECT 1)`、`VALUES 1`、`(1, 2)`、`(NULL)`）と測っていない形は false にして
/// application に落とす（本物が binary にする形を取りこぼす向きにだけ外れる）。
/// 本物は同じ文の `.metadata` の先頭（field 1）に QueryExecutionId を載せる（2026-09-23／25 実測。#210）ので、
/// `operation/result_output.rs` の `metadata_query_id` もこの述語を使う。
pub(crate) fn is_literal_only_select(query: &str) -> bool {
    let mut cursor = Cursor::new(query);
    if !cursor.keyword("SELECT") {
        return false;
    }
    loop {
        // リテラルを包む括弧は何重でもよく、閉じる数が開く数と同じときだけ受理する。
        let mut open = 0;
        while cursor.punct(b'(') {
            open += 1;
        }
        if !cursor.literal() || !(0..open).all(|_| cursor.punct(b')')) {
            return false;
        }
        let has_as = cursor.keyword("AS");
        // `AS` の後ろに識別子が無ければ受理しない。`AS` が無ければ別名は任意。
        if !cursor.identifier() && has_as {
            return false;
        }
        if !cursor.punct(b',') {
            return cursor.at_end();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn csv(query: &str) -> &'static str {
        of(ResultFile::Csv, query)
    }

    #[test]
    fn リテラルだけの_select_は_binary() {
        for query in [
            // 2026-09-23 実測の 8 形（`23807` は初めて流す SQL の 1 回目）。
            "SELECT 1",
            "SELECT 1, 2",
            "SELECT 'a'",
            "SELECT 1.5",
            "SELECT 1 AS i",
            "SELECT true",
            "SELECT 1, 'a'",
            "SELECT 23807 AS fresh",
            // コメント付き（2026-09-18／22 実測）。
            "-- c\nSELECT 1",
            "/* c */ SELECT 1",
            "SELECT /* c */ 1",
            "SELECT 1 -- c",
            // 2026-09-23 実測の追加分（#76）。`SELECT 1 AS i, 2 AS j` と `select 1` は #70 で
            // 一般化していた形の裏取り、残りは #70 が application に落としていた形。
            "SELECT 1 AS i, 2 AS j",
            "select 1",
            "SELECT -1",
            "SELECT 1.5E0",
            "SELECT 1 AS \"x\"",
            "SELECT 1 i",
            // 一般化: 別名の組み合わせ、大文字小文字、空白なし、引用符の重ね、符号と指数の組み合わせ。
            "select 1 as i",
            "SELECT/* c */1,'a''b'",
            "SELECT FALSE, 'it''s'",
            "SELECT -1.5, 1e0, 1E+1, 2.5e-1 AS \"a\"\"b\", 3 c",
            // 括弧で包んだリテラルと、符号と数字の間に空白のある数（2026-09-25 実測。#205）。
            "SELECT (1)",
            "SELECT ((1))",
            "SELECT (1), 2",
            "SELECT 1, (2)",
            "SELECT (1) AS x",
            "SELECT (1) x",
            "SELECT (1) AS \"x\"",
            "SELECT ('a')",
            "SELECT (-1)",
            "SELECT (1.5)",
            "SELECT (1.5E0)",
            "SELECT (true)",
            "SELECT ( 1 )",
            "SELECT (/* c */ 1)",
            "SELECT ('a') AS s, (2) AS t",
            "SELECT - 1",
            // 一般化: 括弧の中の符号の空白、空白なしの括弧、`-` と数字の間のコメント。
            "SELECT (- 1)",
            "SELECT(('a''b'))AS s",
            "SELECT -/* c */1",
        ] {
            assert_eq!(csv(query), BINARY, "{query:?}");
        }
    }

    #[test]
    fn リテラル以外を含む_select_は_application() {
        for query in [
            // 2026-09-23 実測の application（過去の実測を含む）。
            "SELECT 1 AS i WHERE false",
            "SELECT 1 WHERE true",
            "SELECT CAST(1.5 AS DOUBLE)",
            "SELECT CAST(1 AS BIGINT)",
            "SELECT NULL",
            "SELECT 1 + 1",
            "SELECT * FROM (VALUES 1)",
            "SELECT 1 UNION ALL SELECT 2",
            "SELECT 1 FROM t LIMIT 1",
            "SELECT 1 AS i, 'abc' AS s, CAST(1.5 AS DOUBLE) AS d",
            "SELECT id, name FROM users",
            "(SELECT 1)",
            // 本物は binary（2026-09-23 実測）だが、StartQueryExecution の入口で `;` を落とした文を判定に渡す
            // （#240）ので、`;` 付きの文はここに届かない。判定は変えない。
            "SELECT 1;",
            // 途中で終わる・数の形が崩れているもの。パーサの拒否の分岐を 1 つずつ踏む。
            "SELECT",
            "SELECT 1,",
            "SELECT 1.",
            "SELECT 1E",
            "SELECT 1E+",
            "SELECT -",
            "SELECT - -1",
            // 括弧が式・行・NULL・CAST を包むもの、符号が括弧の外にあるもの、`+` の付いた数（2026-09-25 実測。#205）。
            "SELECT -(1)",
            "SELECT - (1)",
            "SELECT -(-1)",
            "SELECT +1",
            "SELECT (1 + 1)",
            "SELECT (1) + 1",
            "SELECT (1, 2)",
            "SELECT (NULL)",
            "SELECT (CAST(1 AS BIGINT))",
            // 括弧の数が合わないもの（Trino が構文エラーにするので判定の結果は捨てられるが、binary にはしない）。
            "SELECT ((1)",
            "SELECT (1))",
            "SELECT (1 AS x)",
            "SELECT 1 AS",
            "SELECT 1 AS 'x'",
            "SELECT trueish",
        ] {
            assert_eq!(csv(query), APPLICATION, "{query:?}");
        }
    }

    #[test]
    fn txt_は_show_と_ddl_が_binary_で_describe_explain_show_create_table_が_application() {
        let txt = |query| of(ResultFile::Text, query);
        for query in [
            "SHOW TABLES IN db",
            "SHOW DATABASES",
            "SHOW COLUMNS IN t",
            "SHOW TBLPROPERTIES t",
            "SHOW VIEWS IN db",
            "SHOW PARTITIONS t",
            "SHOW /* c */ TABLES",
            // SHOW CREATE VIEW は SHOW CREATE TABLE と違って binary（2026-09-24 実測。#146・#151）。
            // 3 語目まで見るので、コメントや先頭の行コメントを挟んでも TABLE と取り違えない。
            "SHOW CREATE VIEW v",
            "show create view v",
            "SHOW CREATE /* c */ VIEW v",
            "-- c\nSHOW CREATE VIEW v",
            "CREATE DATABASE d",
            "DROP TABLE t",
            "ALTER TABLE t ADD COLUMNS (m int)",
        ] {
            assert_eq!(txt(query), BINARY, "{query:?}");
        }
        for query in [
            "DESCRIBE t",
            "-- c\nDESCRIBE t",
            "DESC t",
            "EXPLAIN SELECT 1",
            "SHOW CREATE TABLE t",
            "show create table t",
        ] {
            assert_eq!(txt(query), APPLICATION, "{query:?}");
        }
    }

    #[test]
    fn show_functions_は_csv_として_application() {
        // 本物は `<id>.csv` に application で書く（2026-09-23 実測。#76／#80）。
        // ファイル名が Csv なので `.txt` の判定には届かず、SELECT と同じ判定で application になる。
        for query in ["SHOW FUNCTIONS", "SHOW /* c */ FUNCTIONS"] {
            assert_eq!(ResultFile::of(query), ResultFile::Csv, "{query:?}");
            assert_eq!(csv(query), APPLICATION, "{query:?}");
        }
    }

    #[test]
    fn 本体を書かない_insert_と_ctas_は_metadata_の値として_application() {
        assert_eq!(
            of(ResultFile::Manifest, "INSERT INTO t VALUES (1)"),
            APPLICATION
        );
        assert_eq!(
            of(ResultFile::Table, "CREATE TABLE t AS SELECT 1"),
            APPLICATION
        );
    }

    /// #195 の固定表 (3)（入力表から 51 件）。
    /// 期待値は着手前のコード（76e66f8 + P1a）に `195-verify/golden.sh` を流した出力を写した。推測で書いていない。
    #[test]
    fn content_type_は_crate_の_api_に寄せる前と同じ値を返す() {
        let cases: &[(&str, &str, bool, bool)] = &[
            // コメント（c1・c3・c4・c5・c7・c8・c9・c10・c11・c12・c13）
            ("/* c */SELECT 1", BINARY, false, false),
            ("SELECT--c\n1", BINARY, false, false),
            ("--c\r\nSELECT 1", BINARY, false, false),
            ("/* a */ /* b */ DESCRIBE t", APPLICATION, true, true),
            ("DESC/* c */t", APPLICATION, true, true),
            ("SHOW -- c\nCREATE /* d */ TABLE t", APPLICATION, true, true),
            (
                "CREATE TABLE t AS -- c\n(SELECT 1)",
                APPLICATION,
                false,
                false,
            ),
            ("EXPLAIN /* c */ SELECT 1", APPLICATION, true, false),
            ("/* c DESCRIBE t", BINARY, false, false),
            ("SELECT 1 /* c", BINARY, false, false),
            ("SELECT '--' AS \"/*\"", BINARY, false, false),
            // 引用符付き識別子（q5・q8）
            // #200 で空白ありの形と同じ値に揃えた。
            ("SHOW CREATE TABLE\"t\"", APPLICATION, true, true),
            ("SELECT 1 AS \"a b\"", BINARY, false, false),
            // 大文字小文字（k1・k2・k3・k4・k7）
            ("sElEcT 1", BINARY, false, false),
            ("Describe T", APPLICATION, true, true),
            ("Show Create Table T", APPLICATION, true, true),
            ("eXpLaIn SELECT 1", APPLICATION, true, false),
            ("show functions", APPLICATION, false, false),
            // 空白（w1・w2・w3・w4・w5・w6・w8・w10・w12・w13）
            ("SELECT\t1", BINARY, false, false),
            ("DESCRIBE\r\nt", APPLICATION, true, true),
            ("SHOW  CREATE   TABLE t", APPLICATION, true, true),
            ("\n\tSELECT 1", BINARY, false, false),
            // w5・w6・w8 は #200 で空白ありの形と同じ値に揃えた（2026-09-25 実測）。
            // w5 は #205 で括弧付きのリテラルを受理して本物と同じ binary にした。
            ("SELECT(1)", BINARY, false, false),
            ("SELECT'a'", BINARY, false, false),
            ("EXPLAIN(TYPE IO) SELECT 1", APPLICATION, true, false),
            ("SELECT\x0B1", BINARY, false, false),
            ("SELECT\u{3000}1", BINARY, false, false),
            ("SELECT\u{00A0}1", BINARY, false, false),
            // `(` の変種（p1・p4・p6・p7・p8・p9・p11・p17）
            ("(SELECT 1)", APPLICATION, false, false),
            ("(VALUES 1)", APPLICATION, false, false),
            ("(EXPLAIN SELECT 1)", BINARY, false, false),
            ("(DESCRIBE t)", BINARY, false, false),
            ("( SHOW FUNCTIONS )", BINARY, false, false),
            ("(SHOW FUNCTIONS)", BINARY, false, false),
            ("CREATE TABLE t AS (VALUES 1)", APPLICATION, false, false),
            // p17 は #199 で CTAS に揃え、本物の `.metadata` と同じ application にした（2026-09-25 実測）。
            ("CREATE TABLE t AS(SELECT 1)", APPLICATION, false, false),
            // 空・トリビアだけ・多バイト（e1・e3・e5・e6・e7・e10・e11）
            ("", BINARY, false, false),
            ("-- only", BINARY, false, false),
            ("/* unclosed", BINARY, false, false),
            ("日本語", BINARY, false, false),
            ("SELECT '日本語'", BINARY, false, false),
            ("-- あ\nDESCRIBE t", APPLICATION, true, true),
            ("SELECT 1 AS 日本", APPLICATION, false, false),
            // `;` 付き（s1・s2・s3・s4・s5）
            ("SELECT 1;", APPLICATION, false, false),
            ("DESCRIBE t;", APPLICATION, true, true),
            ("SHOW CREATE TABLE t;", APPLICATION, true, true),
            ("EXPLAIN SELECT 1;", APPLICATION, true, false),
            ("CREATE TABLE t AS SELECT 1;", APPLICATION, false, false),
            // SHOW（h1・h3・h5）
            ("SHOW CREATE VIEW v", BINARY, false, false),
            ("SHOW TABLES", BINARY, false, false),
            ("SHOW COLUMNS FROM t", BINARY, false, false),
        ];
        for &(query, content_type, plain, carries) in cases {
            assert_eq!(
                (
                    of(ResultFile::of(query), query),
                    plain_text_statement(query),
                    carries_execution_id(query)
                ),
                (content_type, plain, carries),
                "{query:?}"
            );
        }
    }
}
