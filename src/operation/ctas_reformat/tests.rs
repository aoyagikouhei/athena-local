use super::*;

/// `full` 内で `needle` が最初に現れる位置の 1 始まりの行・桁から、`line N:M: <tail>` の形の message を作る
/// （手で桁を数えず `find` で数える）。
fn message_at(full: &str, needle: &str, tail: &str) -> String {
    let byte = full
        .find(needle)
        .unwrap_or_else(|| panic!("{needle} が無い: {full}"));
    let mut line = 1;
    let mut column = 1;
    for &b in &full.as_bytes()[..byte] {
        if b == b'\n' {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    format!("line {line}:{column}: {tail}")
}

/// `run()` の経路（`sent` == `full` == `received`、`offset` == 0、別名置換は起きていない）を模したときの結果。
fn run_remap(full: &str, message: &str) -> Option<String> {
    remap(full, 0, full, full, None, message)
}

const TABLE_NOT_FOUND: &str = "Table 'db.nosuch' does not exist";
const COLUMN_NOT_FOUND: &str = "Column 'nosuch272' cannot be resolved";

/// 上の表の各 ID（受け取った文と Trino の message → 直した message）。位置以外は変えない。
#[test]
fn 表の各項目の位置を整形後の行桁に直す() {
    for (id, full, needle, tail, want_line, want_column) in [
        (
            "p1",
            "CREATE TABLE db.t AS SELECT * FROM db.nosuch",
            "db.nosuch",
            TABLE_NOT_FOUND,
            6,
            3,
        ),
        (
            "p2",
            "CREATE TABLE db.t AS SELECT nosuch272 FROM db.src",
            "nosuch272",
            COLUMN_NOT_FOUND,
            4,
            13,
        ),
        (
            "p3",
            "CREATE TABLE db.t AS SELECT n, s, nosuch272 FROM db.src",
            "nosuch272",
            COLUMN_NOT_FOUND,
            7,
            3,
        ),
        (
            "p4",
            "CREATE TABLE db.t AS\nSELECT n\nFROM db.src\nWHERE nosuch272 = 1",
            "nosuch272",
            COLUMN_NOT_FOUND,
            7,
            8,
        ),
        (
            "p6",
            "CREATE TABLE db.t AS (SELECT * FROM db.nosuch)",
            "db.nosuch",
            TABLE_NOT_FOUND,
            7,
            6,
        ),
        (
            "p7",
            "CREATE TABLE db.t AS WITH c AS (SELECT * FROM db.nosuch) SELECT * FROM c",
            "db.nosuch",
            TABLE_NOT_FOUND,
            8,
            6,
        ),
        (
            "p8",
            "CREATE TABLE db.t WITH (format = 'PARQUET') AS SELECT * FROM db.nosuch",
            "db.nosuch",
            TABLE_NOT_FOUND,
            7,
            3,
        ),
        (
            "p9",
            "CREATE TABLE db.t WITH (format = 'PARQUET', write_compression = 'SNAPPY') AS SELECT * FROM db.nosuch",
            "db.nosuch",
            TABLE_NOT_FOUND,
            8,
            3,
        ),
        (
            "p12",
            "CREATE TABLE db.t AS SELECT 1 + 'a' AS n",
            "+",
            "Cannot apply operator: integer + varchar(1)",
            4,
            16,
        ),
        (
            "w2",
            "CREATE TABLE db.t AS SELECT * FROM db.nosuch WITH NO DATA",
            "db.nosuch",
            TABLE_NOT_FOUND,
            6,
            3,
        ),
        (
            "w3",
            "CREATE TABLE db.t AS SELECT nosuch272 FROM db.src WITH NO DATA",
            "nosuch272",
            COLUMN_NOT_FOUND,
            4,
            13,
        ),
    ] {
        let message = message_at(full, needle, tail);
        assert_eq!(
            run_remap(full, &message),
            Some(format!("line {want_line}:{want_column}: {tail}")),
            "{id}: {full}"
        );
    }
}

/// 二項演算子の項目は整形で `(<左> <演算子> <右>)` と括弧で包まれるので、左の字句は括弧の分だけ右にずれる
/// （本物で測ったのは演算子の位置 p12 だけ。括弧が付く規則は p12 の位置から決まる）。
#[test]
fn 二項演算子の左の字句は括弧の分だけ右の桁にする() {
    let full = "CREATE TABLE db.t AS SELECT nosuch272 + 1 AS n";
    let message = message_at(full, "nosuch272", COLUMN_NOT_FOUND);
    assert_eq!(
        run_remap(full, &message),
        Some(format!("line 4:14: {COLUMN_NOT_FOUND}"))
    );
}

/// `IF NOT EXISTS`・先頭のコメント・`AS` の後ろの余分な空白は位置に効かない（p1 と同じ位置）。
#[test]
fn if_not_exists_と先頭コメントと余分な空白は位置に効かない() {
    for full in [
        "CREATE TABLE IF NOT EXISTS db.t AS SELECT * FROM db.nosuch",
        "/* c */ CREATE TABLE db.t AS SELECT * FROM db.nosuch",
        "CREATE TABLE db.t AS    SELECT * FROM db.nosuch",
    ] {
        let message = message_at(full, "db.nosuch", TABLE_NOT_FOUND);
        assert_eq!(
            run_remap(full, &message),
            Some(format!("line 6:3: {TABLE_NOT_FOUND}")),
            "{full}"
        );
    }
}

/// `ctas_rows` の経路（`sent` が `AS` の後ろの問い合わせ部分だけで、`offset` を足す）でも p1 と同じ位置になる。
#[test]
fn ctas_rows_の経路は_offset_を足して整形後の位置にする() {
    let full = "CREATE TABLE db.t AS SELECT * FROM db.nosuch";
    let offset = full.find("SELECT").unwrap();
    let sent = &full[offset..];
    let message = message_at(sent, "db.nosuch", TABLE_NOT_FOUND);
    assert_eq!(
        remap(sent, offset, full, full, None, &message),
        Some(format!("line 6:3: {TABLE_NOT_FOUND}"))
    );
}

/// 別名置換（#246・#260）で CTAS 自身の名前の `awsdatacatalog` が引用符付きの Trino 名に変わっても（文字数は
/// 変わらない）、対象の形は受け取ったまま（`received`）の名前で決めるので、位置は直る。
#[test]
fn 別名置換で名前が引用符付きに変わっても受け取った名前の形で対象を決める() {
    let received = "CREATE TABLE awsdatacatalog.missing.t AS SELECT * FROM db.nosuch";
    let aliased = crate::catalog::replacement("awsdatacatalog", "hive");
    let full = received.replacen("awsdatacatalog", &aliased, 1);
    assert_eq!(full.len(), received.len(), "別名置換は文字数を保つ");
    let message = message_at(&full, "db.nosuch", TABLE_NOT_FOUND);
    assert_eq!(
        remap(&full, 0, &full, received, Some("AwsDataCatalog"), &message),
        Some(format!("line 6:3: {TABLE_NOT_FOUND}"))
    );

    // 別名置換で長さそのものが変われば対象外（測っていない。#272 D6）。
    let longer = format!("{full} ");
    assert_eq!(
        remap(
            &longer,
            0,
            &longer,
            received,
            Some("AwsDataCatalog"),
            &message
        ),
        None
    );
}

/// 境界の外（JOIN・GROUP BY・ORDER BY・関数呼び出し・複数項目の一部が関数・WHERE の AND・非 ASCII・
/// message が `line` で始まらない）は None。
#[test]
fn 境界の外の形は_none() {
    let table_message = message_at(
        "CREATE TABLE db.t AS SELECT * FROM db.nosuch",
        "db.nosuch",
        TABLE_NOT_FOUND,
    );
    for full in [
        "CREATE TABLE db.t AS SELECT * FROM db.a JOIN db.b ON db.a.x = db.b.x",
        "CREATE TABLE db.t AS SELECT a, count(*) FROM db.t2 GROUP BY a",
        "CREATE TABLE db.t AS SELECT * FROM db.t2 ORDER BY 1",
        "CREATE TABLE db.t AS SELECT a, count(*) AS c FROM db.t2",
        "CREATE TABLE db.t AS SELECT * FROM db.t2 WHERE a = 1 AND b = 2",
    ] {
        // 位置はどれも `db.nosuch` を含まないので、message はそのまま使う（構造自体が読めず None になる）。
        assert_eq!(run_remap(full, &table_message), None, "{full}");
    }

    // 非 ASCII を含む文は読まない（Trino の桁が文字単位かバイト単位か未確認）。
    let non_ascii = "CREATE TABLE db.t AS SELECT * FROM db.nosuch -- 日本語";
    let message = message_at(non_ascii, "db.nosuch", TABLE_NOT_FOUND);
    assert_eq!(run_remap(non_ascii, &message), None);

    // 位置が★の字句以外（CTAS の名前そのもの）を指す。
    let full = "CREATE TABLE db.t AS SELECT * FROM db.nosuch";
    let message = message_at(full, "db.t", TABLE_NOT_FOUND);
    assert_eq!(run_remap(full, &message), None);

    // message が `line` で始まらない。
    assert_eq!(run_remap(full, TABLE_NOT_FOUND), None);
}

/// 対象の判定: Context の Catalog と CTAS の名前の形。
#[test]
fn 対象の判定は_context_の_catalog_と名前の形で決まる() {
    let table_message = |full: &str| message_at(full, "db.nosuch", TABLE_NOT_FOUND);

    // 省略（既定）の Context: 1 部・3 部（1 部目が awsdatacatalog）は対象、ほかのカタログの 3 部は対象外。
    let one_part = "CREATE TABLE t AS SELECT * FROM db.nosuch";
    assert_eq!(
        run_remap(one_part, &table_message(one_part)),
        Some(format!("line 6:3: {TABLE_NOT_FOUND}"))
    );
    let aws_three_part = "CREATE TABLE awsdatacatalog.db.t AS SELECT * FROM db.nosuch";
    assert_eq!(
        run_remap(aws_three_part, &table_message(aws_three_part)),
        Some(format!("line 6:3: {TABLE_NOT_FOUND}"))
    );
    let hive_three_part = "CREATE TABLE hive.db.t AS SELECT * FROM db.nosuch";
    assert_eq!(
        run_remap(hive_three_part, &table_message(hive_three_part)),
        None,
        "ほかのカタログの 3 部（hive.db.t）は直さない"
    );

    // S3 Tables の Context: 1 部目が awsdatacatalog の 3 部だけが対象、2 部の名前空間は対象外。
    let s3_tables = Some("s3tablescatalog/bucket");
    assert_eq!(
        remap(
            aws_three_part,
            0,
            aws_three_part,
            aws_three_part,
            s3_tables,
            &table_message(aws_three_part)
        ),
        Some(format!("line 6:3: {TABLE_NOT_FOUND}"))
    );
    let two_part = "CREATE TABLE ns.t AS SELECT * FROM db.nosuch";
    assert_eq!(
        remap(
            two_part,
            0,
            two_part,
            two_part,
            s3_tables,
            &table_message(two_part)
        ),
        None,
        "S3 Tables の名前空間の 2 部は直さない"
    );

    // ほかの Context（AwsDataCatalog でも S3 Tables でもない）は対象外。
    let two_part_default = "CREATE TABLE db.t AS SELECT * FROM db.nosuch";
    assert_eq!(
        remap(
            two_part_default,
            0,
            two_part_default,
            two_part_default,
            Some("hive"),
            &table_message(two_part_default)
        ),
        None
    );

    // パラメータの有無はこの関数の対象外（`background_execution.rs` の呼び出し側の判定）だが、
    // 長さの一致は `remap` 自身が見る。
    assert_eq!(
        remap(
            one_part,
            0,
            one_part,
            "違う長さの文",
            None,
            &table_message(one_part)
        ),
        None,
        "受け取った文と長さが違えば対象外"
    );
}
