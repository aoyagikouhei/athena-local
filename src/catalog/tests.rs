use super::*;

const S3_TABLES: &str = "s3tablescatalog/my-bucket";

fn aliases(pairs: &[(&str, &str)]) -> HashMap<String, String> {
    pairs
        .iter()
        .map(|(from, to)| (from.to_string(), to.to_string()))
        .collect()
}

fn alias(sql: &str) -> String {
    alias_qualified_names(
        sql,
        &aliases(&[(S3_TABLES, "iceberg")]),
        UnquotedForms::ThreeUnquotedParts,
    )
    .into_owned()
}

#[test]
fn 引用符付きのカタログ名を別名にして桁を空白で揃える() {
    let sql = r#"SELECT * FROM "s3tablescatalog/my-bucket".db.users WHERE id = 1"#;
    let aliased = alias(sql);

    assert_eq!(
        aliased,
        r#"SELECT * FROM "iceberg"                  .db.users WHERE id = 1"#
    );
    assert_eq!(aliased.chars().count(), sql.chars().count());
}

#[test]
fn 修飾名がいくつあってもそれぞれ置き換える() {
    let map = aliases(&[
        ("s3tablescatalog/a", "iceberg_a"),
        ("s3tablescatalog/b", "iceberg_b"),
    ]);
    let sql =
        r#"SELECT * FROM "s3tablescatalog/a".ns.t JOIN "s3tablescatalog/b"."ns"."u" USING (id)"#;

    assert_eq!(
        alias_qualified_names(sql, &map, UnquotedForms::ThreeUnquotedParts),
        r#"SELECT * FROM "iceberg_a"        .ns.t JOIN "iceberg_b"        ."ns"."u" USING (id)"#
    );
}

#[test]
fn 空白や改行やコメントを挟んで続く点でも置き換える() {
    assert_eq!(
        alias("SELECT * FROM \"s3tablescatalog/my-bucket\" \n\t. db.users"),
        "SELECT * FROM \"iceberg\"                   \n\t. db.users"
    );
    assert_eq!(
        alias(r#"SELECT * FROM "s3tablescatalog/my-bucket" /* c */ .db.users"#),
        r#"SELECT * FROM "iceberg"                   /* c */ .db.users"#
    );
    assert_eq!(
        alias("SELECT * FROM \"s3tablescatalog/my-bucket\" -- c\n.db.users"),
        "SELECT * FROM \"iceberg\"                   -- c\n.db.users"
    );
}

#[test]
fn 後ろに点が続かなければ置き換えない() {
    for sql in [
        r#"SELECT 1 AS "s3tablescatalog/my-bucket""#,
        r#"SHOW SCHEMAS FROM "s3tablescatalog/my-bucket""#,
        r#"SELECT "s3tablescatalog/my-bucket" , x FROM t"#,
        r#"SELECT * FROM "s3tablescatalog/my-bucket" /* . */ -- .
"#,
    ] {
        assert_eq!(alias(sql), sql);
    }
}

#[test]
fn 文字列リテラルとコメントの中は置き換えない() {
    for sql in [
        r#"SELECT '"s3tablescatalog/my-bucket".db.users'"#,
        r#"SELECT 'it''s "s3tablescatalog/my-bucket".db.users'"#,
        "SELECT 1 -- \"s3tablescatalog/my-bucket\".db.users",
        "SELECT 1 /* \"s3tablescatalog/my-bucket\".db.users */",
        "SELECT 1 /* * / \"s3tablescatalog/my-bucket\".db.users */",
        // `/*` の `*` を閉じの `*/` の一部として読まない。
        "SELECT 1 /*/ \"s3tablescatalog/my-bucket\".db.users */",
    ] {
        assert_eq!(alias(sql), sql);
    }
}

#[test]
fn リテラルやコメントが閉じた後ろは置き換える() {
    assert_eq!(
        alias("SELECT 'a''b', 1 -- x\n, 2 /* y */ FROM \"s3tablescatalog/my-bucket\".db.t"),
        "SELECT 'a''b', 1 -- x\n, 2 /* y */ FROM \"iceberg\"                  .db.t"
    );
    // 閉じた直後に空白が無くても、次の識別子を読み飛ばさない。
    assert_eq!(
        alias("SELECT * FROM/* y */\"s3tablescatalog/my-bucket\".db.t"),
        "SELECT * FROM/* y */\"iceberg\"                  .db.t"
    );
    assert_eq!(
        alias("SELECT 'x'\"s3tablescatalog/my-bucket\".db.t"),
        "SELECT 'x'\"iceberg\"                  .db.t"
    );
    // 識別子の中の単一引用符は文字列の始まりではない。
    assert_eq!(
        alias(r#"SELECT "it's" FROM "s3tablescatalog/my-bucket".db.t"#),
        r#"SELECT "it's" FROM "iceberg"                  .db.t"#
    );
}

#[test]
fn 引用符付きの名前は大文字小文字が違えば置き換えない() {
    let map = aliases(&[("AwsDataCatalog", "hive"), (S3_TABLES, "iceberg")]);
    for sql in [
        r#"SELECT * FROM "S3TablesCatalog/my-bucket".db.users"#,
        r#"SELECT * FROM "awsdatacatalog".db.users"#,
    ] {
        assert_eq!(
            alias_qualified_names(sql, &map, UnquotedForms::ThreeUnquotedParts),
            sql
        );
    }
}

fn alias_unquoted(sql: &str) -> String {
    let map = aliases(&[("AwsDataCatalog", "hive"), (S3_TABLES, "iceberg")]);
    alias_qualified_names(sql, &map, UnquotedForms::ThreeUnquotedParts).into_owned()
}

#[test]
fn aws_data_catalog_の_context_では無引用の_awsdatacatalog_を大文字小文字によらず置き換える() {
    for (sql, expected) in [
        (
            "SELECT * FROM awsdatacatalog.db.t",
            "SELECT * FROM \"hive\"        .db.t",
        ),
        (
            "INSERT INTO AwsDataCatalog.db.t VALUES (1)",
            "INSERT INTO \"hive\"        .db.t VALUES (1)",
        ),
        (
            "SELECT * FROM awsdatacatalog /* c */ . db . t JOIN AWSDATACATALOG.db.u USING (id)",
            "SELECT * FROM \"hive\"         /* c */ . db . t JOIN \"hive\"        .db.u USING (id)",
        ),
    ] {
        assert_eq!(alias_unquoted(sql), expected);
        assert_eq!(alias_unquoted(sql).chars().count(), sql.chars().count());
    }
}

#[test]
fn 無引用の_3_部だけを当てる形では_3_部でない名前と引用符付きの部品を置き換えない() {
    for sql in [
        // 3 部でない（4 部の列の参照は WithQuotedPartsOrColumn だけが当てる）
        "SELECT awsdatacatalog.c FROM t awsdatacatalog",
        "SELECT * FROM awsdatacatalog.db.t.c",
        // 1 部目でない
        "SELECT * FROM x.awsdatacatalog.db.t",
        "SELECT * FROM x . awsdatacatalog.db.t",
        // 名前の一部
        "SELECT * FROM xawsdatacatalog.db.t",
        "SELECT * FROM awsdatacatalog_x.db.t",
        // 引用符付きの部品を含む（同上）
        "SELECT * FROM awsdatacatalog.\"db\".t",
        "SELECT * FROM awsdatacatalog.db.\"t\"",
        // リテラルとコメントの中
        "SELECT 'awsdatacatalog.db.t'",
        "SELECT 1 -- awsdatacatalog.db.t",
    ] {
        assert_eq!(alias_unquoted(sql), sql);
    }
}

fn alias_quoted_or_column(sql: &str) -> String {
    let map = aliases(&[("AwsDataCatalog", "hive")]);
    alias_qualified_names(sql, &map, UnquotedForms::WithQuotedPartsOrColumn).into_owned()
}

#[test]
fn 引用符付きの部品と_4_部の列の参照も当てる形では測った名前を置き換える() {
    for (sql, expected) in [
        // o6・o7（2026-09-27 実測）
        (
            "SELECT * FROM awsdatacatalog.\"db\".t",
            "SELECT * FROM \"hive\"        .\"db\".t",
        ),
        (
            "SELECT * FROM awsdatacatalog.db.\"t\"",
            "SELECT * FROM \"hive\"        .db.\"t\"",
        ),
        // o8: 列の参照と FROM の 2 か所
        (
            "SELECT awsdatacatalog.db.t.n FROM awsdatacatalog.db.t",
            "SELECT \"hive\"        .db.t.n FROM \"hive\"        .db.t",
        ),
        // 無引用の 3 部（#246）も当てる
        (
            "SELECT * FROM AwsDataCatalog.db.t",
            "SELECT * FROM \"hive\"        .db.t",
        ),
    ] {
        assert_eq!(alias_quoted_or_column(sql), expected);
    }
}

#[test]
fn 引用符付きの部品と_4_部の列の参照も当てる形でも測っていない並びは置き換えない() {
    for sql in [
        "SELECT * FROM awsdatacatalog.db",
        "SELECT awsdatacatalog.db.t.n.m FROM x",
        // 引用符付きが 2 つ・4 部に引用符付きを含む（測ったのは o6・o7 の 1 つだけと、無引用の 4 部の o8）
        "SELECT * FROM awsdatacatalog.\"db\".\"t\"",
        "SELECT awsdatacatalog.db.t.\"n\" FROM x",
        "SELECT awsdatacatalog.\"db\".t.n FROM x",
        "SELECT * FROM \"awsdatacatalog\".db.t",
        "SELECT * FROM x.awsdatacatalog.db.t",
    ] {
        assert_eq!(alias_quoted_or_column(sql), sql);
    }
}

#[test]
fn 無引用の位置に非_ascii_の文字があっても止まらずに後ろを置き換える() {
    assert_eq!(
        alias_unquoted("SELECT 1 AS 列 FROM awsdatacatalog.db.t"),
        "SELECT 1 AS 列 FROM \"hive\"        .db.t"
    );
}

#[test]
fn 形が_none_なら無引用の名前は置き換えない() {
    let map = aliases(&[("AwsDataCatalog", "hive")]);
    let sql = "SELECT * FROM awsdatacatalog.db.t";
    assert_eq!(alias_qualified_names(sql, &map, UnquotedForms::None), sql);
}

#[test]
fn 別名の方が長ければ空白で埋めずに置き換える() {
    let map = aliases(&[("a", "iceberg")]);
    assert_eq!(
        alias_qualified_names(r#"SELECT * FROM "a".db.t"#, &map, UnquotedForms::None),
        r#"SELECT * FROM "iceberg".db.t"#
    );
}

#[test]
fn 識別子の二重の引用符は中身として比べて別名では二重にする() {
    let map = aliases(&[("a\"b", "c\"d")]);
    assert_eq!(
        alias_qualified_names(r#"SELECT * FROM "a""b".db.t"#, &map, UnquotedForms::None),
        r#"SELECT * FROM "c""d".db.t"#
    );
}

#[test]
fn 桁は文字数で揃える() {
    let map = aliases(&[("カタログ/x", "t")]);
    let sql = r#"SELECT * FROM "カタログ/x".db.t"#;
    let aliased = alias_qualified_names(sql, &map, UnquotedForms::ThreeUnquotedParts);

    assert_eq!(aliased, r#"SELECT * FROM "t"     .db.t"#);
    assert_eq!(aliased.chars().count(), sql.chars().count());
}

#[test]
fn 置き換える箇所が無ければ受け取った_sql_を借りたまま返す() {
    let sql = r#"SELECT * FROM "s3tablescatalog/my-bucket".db.users"#;
    assert!(matches!(
        alias_qualified_names(sql, &HashMap::new(), UnquotedForms::ThreeUnquotedParts),
        Cow::Borrowed(_)
    ));
    assert!(matches!(
        alias_qualified_names(
            "SELECT * FROM users",
            &aliases(&[(S3_TABLES, "iceberg")]),
            UnquotedForms::ThreeUnquotedParts
        ),
        Cow::Borrowed(_)
    ));
}

#[test]
fn 閉じていない引用符やコメントでも止まらない() {
    for sql in [
        r#"SELECT "s3tablescatalog/my-bucket"#,
        "SELECT 's3tablescatalog/my-bucket",
        "SELECT 1 /* \"s3tablescatalog/my-bucket\".x",
        "SELECT \"s3tablescatalog/my-bucket\" --",
    ] {
        assert_eq!(alias(sql), sql);
    }
}
