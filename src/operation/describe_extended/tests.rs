//! describe_extended.rs のユニットテスト。

use super::*;

fn some(query: &str) -> Describe<'_> {
    parse(query).unwrap_or_else(|| panic!("parse({query:?}) は Some を返すはず"))
}

fn part_texts<'a>(name: &Name<'a>) -> Vec<&'a str> {
    name.parts.iter().map(|part| part.text).collect()
}

// ---- 認識（parse） ----

#[test]
fn 修飾子と名前だけの形を認識する() {
    for (query, modifier) in [
        ("DESCRIBE EXTENDED db.t", Modifier::Extended),
        ("DESCRIBE FORMATTED db.t", Modifier::Formatted),
        ("DESC EXTENDED t", Modifier::Extended),
        ("describe formatted db.t", Modifier::Formatted),
    ] {
        let describe = some(query);
        assert_eq!(describe.modifier, Some(modifier), "{query}");
        assert_eq!(describe.suffix, Suffix::None, "{query}");
    }
    // 名前の部品も確かめる。
    assert_eq!(
        part_texts(&some("DESCRIBE EXTENDED db.t").name),
        ["db", "t"]
    );
    assert_eq!(part_texts(&some("DESC EXTENDED t").name), ["t"]);
}

#[test]
fn 修飾子の後ろの列名_1_つを認識する() {
    for (query, modifier) in [
        ("DESCRIBE EXTENDED db.t n", Some(Modifier::Extended)),
        ("DESCRIBE FORMATTED db.t n", Some(Modifier::Formatted)),
        ("DESCRIBE db.t n", None),
    ] {
        let describe = some(query);
        assert_eq!(describe.modifier, modifier, "{query}");
        assert_eq!(describe.suffix, Suffix::Column("n".to_string()), "{query}");
        assert_eq!(part_texts(&describe.name), ["db", "t"], "{query}");
    }
}

#[test]
fn 修飾子の後ろの_partition_を認識する() {
    let describe = some("DESCRIBE EXTENDED db.t PARTITION (p='x')");
    assert_eq!(describe.modifier, Some(Modifier::Extended));
    assert_eq!(
        describe.suffix,
        Suffix::Partition(vec![("p".to_string(), "x".to_string())])
    );
}

#[test]
fn 修飾子無しでも_partition_を認識し複数の対と引用符の重ねを戻す() {
    let describe = some("DESCRIBE db.t PARTITION (p = 'it''s', q='y')");
    assert_eq!(describe.modifier, None);
    assert_eq!(
        describe.suffix,
        Suffix::Partition(vec![
            ("p".to_string(), "it's".to_string()),
            ("q".to_string(), "y".to_string()),
        ])
    );
}

#[test]
fn 三部の名前で_1_部目が_awsdatacatalog_でも認識する() {
    let describe = some("DESCRIBE EXTENDED awsdatacatalog.db.t");
    assert_eq!(part_texts(&describe.name), ["awsdatacatalog", "db", "t"]);
}

#[test]
fn バッククォートを含む名前は今の経路に任せて_none() {
    // 今の athena-local はバッククォートの名前を文の種類によらず構文チェックで弾く（caveats の #204 の差）。
    assert_eq!(parse("DESCRIBE EXTENDED db.`t`"), None);
    assert_eq!(parse("DESCRIBE EXTENDED `t`"), None);
}

#[test]
fn 対象外の形は_none_を返す() {
    for query in [
        "DESCRIBE EXTENDED",                      // 名前無し（z1・z2）
        "DESCRIBE FORMATTED",                     // 名前無し
        "DESCRIBE db.t",                          // 修飾子も後ろも無い
        "DESCRIBE EXTENDED a.b.c.d",              // 4 部
        "DESCRIBE EXTENDED \"db\".t",             // 二重引用符
        "DESCRIBE EXTENDED db.t n m",             // 列の後ろに余計な語
        "DESCRIBE EXTENDED db.t PARTITION (p=1)", // 値が文字列でない
        "SELECT 1",                               // 先頭語が違う
    ] {
        assert_eq!(parse(query), None, "{query}");
    }
}

// ---- Trino に送る文 ----

#[test]
fn trino_statement_は修飾子と後ろを付けず_describe_だけ送る() {
    let query = "DESCRIBE EXTENDED db.t n";
    let describe = some(query);
    assert_eq!(trino_statement(&describe), "DESCRIBE db.t");
}

// ---- Query の表示（displayed） ----

fn displayed_awsdatacatalog(query: &str) -> (String, Option<String>) {
    displayed(query, Some("AwsDataCatalog"))
}

#[test]
fn 名前の_awsdatacatalog_と_db_を落とす() {
    for query in [
        "DESCRIBE EXTENDED db.t",
        "DESCRIBE EXTENDED awsdatacatalog.db.t",
        "DESCRIBE EXTENDED AwsDataCatalog.db.t",
    ] {
        assert_eq!(
            displayed_awsdatacatalog(query),
            ("DESCRIBE EXTENDED t".to_string(), Some("db".to_string())),
            "{query}"
        );
    }
}

#[test]
fn 小文字と_desc_はキーワードの綴りを残す() {
    assert_eq!(
        displayed_awsdatacatalog("describe extended db.t"),
        ("describe extended t".to_string(), Some("db".to_string()))
    );
    assert_eq!(
        displayed_awsdatacatalog("DESC EXTENDED db.t"),
        ("DESC EXTENDED t".to_string(), Some("db".to_string()))
    );
}

#[test]
fn 空白_2_つだけを_1_つに畳み_それ以外の空白と改行は残す() {
    assert_eq!(
        displayed_awsdatacatalog("DESCRIBE  EXTENDED db.t"),
        ("DESCRIBE EXTENDED t".to_string(), Some("db".to_string()))
    );
    assert_eq!(
        displayed_awsdatacatalog("DESCRIBE   EXTENDED db.t"),
        ("DESCRIBE   EXTENDED t".to_string(), Some("db".to_string()))
    );
    assert_eq!(
        displayed_awsdatacatalog("DESCRIBE\nEXTENDED db.t"),
        ("DESCRIBE\nEXTENDED t".to_string(), Some("db".to_string()))
    );
}

#[test]
fn 無修飾の名前でも空白_2_つは_1_つに畳む() {
    assert_eq!(
        displayed_awsdatacatalog("DESCRIBE  FORMATTED t"),
        ("DESCRIBE FORMATTED t".to_string(), None)
    );
}

#[test]
fn 名前の中のコメントは残す() {
    assert_eq!(
        displayed_awsdatacatalog("DESCRIBE EXTENDED db./* c */t"),
        (
            "DESCRIBE EXTENDED /* c */t".to_string(),
            Some("db".to_string())
        )
    );
}

#[test]
fn formatted_と列_partition_の後ろはそのまま残す() {
    assert_eq!(
        displayed_awsdatacatalog("DESCRIBE FORMATTED db.t"),
        ("DESCRIBE FORMATTED t".to_string(), Some("db".to_string()))
    );
    assert_eq!(
        displayed_awsdatacatalog("DESCRIBE EXTENDED db.t n"),
        ("DESCRIBE EXTENDED t n".to_string(), Some("db".to_string()))
    );
    assert_eq!(
        displayed_awsdatacatalog("DESCRIBE EXTENDED db.t PARTITION (p='x')"),
        (
            "DESCRIBE EXTENDED t PARTITION (p='x')".to_string(),
            Some("db".to_string())
        )
    );
}

#[test]
fn 修飾子無しでも列指定なら_db_を落とす() {
    assert_eq!(
        displayed_awsdatacatalog("DESCRIBE db.t n"),
        ("DESCRIBE t n".to_string(), Some("db".to_string()))
    );
}

#[test]
fn 無修飾の名前は落とすものが無く_database_は_none() {
    assert_eq!(
        displayed_awsdatacatalog("DESCRIBE EXTENDED t"),
        ("DESCRIBE EXTENDED t".to_string(), None)
    );
}

#[test]
fn context_の_catalog_が_awsdatacatalog_か省略のときだけ落とす() {
    let query = "DESCRIBE EXTENDED db.t";
    assert_eq!(displayed(query, None).1.as_deref(), Some("db"));
    assert_eq!(
        displayed(query, Some("awsdatacatalog")).1.as_deref(),
        Some("db")
    );
    assert_eq!(
        displayed("DESCRIBE  EXTENDED db.t", Some("other")),
        ("DESCRIBE EXTENDED db.t".to_string(), None)
    );
}
