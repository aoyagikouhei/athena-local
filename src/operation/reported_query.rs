//! 本物の Athena が GetQueryExecution の `Query` と Context の Database を組み直す文を、Store に入れる前に
//! 同じ形にする（2026-09-26 実測 ROUND=8。#242）。
//!
//! 本物は DESCRIBE・DESC・SHOW COLUMNS・SHOW CREATE TABLE・SHOW TABLES IN・ALTER TABLE・DROP TABLE の名前の
//! 1 部目の `awsdatacatalog`（大文字小文字によらない）と直後の `.` を落とし、Context の Database を修飾の DB に
//! する。表への DESCRIBE・DESC はさらに DB も落とす（ビューは残す）。SELECT・INSERT・CTAS・CREATE VIEW・
//! EXPLAIN・SHOW VIEWS IN は送ったまま。落とした文は Context のカタログ・DB で同じ表を指すので、athena-local は
//! 実行もその文で行う。

use crate::failure::Failure;

use super::target_table::table_name_start;

/// 本物が `awsdatacatalog.` を落とす文の、名前の前のキーワードの並びと、カタログを含む名前の部品の数。
/// 4 部以上は本物が名前の形だけで弾く（`Invalid table name`）ので、部品の数がちょうどのときだけ落とす。
const CATALOG_DROPPED: &[(&[&str], usize)] = &[
    (&["DESCRIBE"], 3),
    (&["DESC"], 3),
    (&["SHOW", "COLUMNS", "FROM"], 3),
    (&["SHOW", "COLUMNS", "IN"], 3),
    (&["SHOW", "CREATE", "TABLE"], 3),
    (&["SHOW", "TABLES", "IN"], 2),
    (&["ALTER", "TABLE"], 3),
    (&["DROP", "TABLE"], 3),
];

/// 組み直した文と、Context の Database にする修飾の DB（文中の綴り）。
#[derive(Debug, PartialEq)]
pub(super) struct Rewritten {
    pub query: String,
    pub database: String,
}

/// `awsdatacatalog.` を落とせる文なら、落とした文と修飾の DB を返す。測ったのは Context の Catalog が
/// `AwsDataCatalog` のときだけなので、ほかのカタログでは落とさない（省略は本物の既定の AwsDataCatalog）。
/// 引用符付きの部品を含む名前は、開始時の判定（`quoted_names`）に任せて落とさない。
pub(super) fn drop_catalog(query: &str, context_catalog: Option<&str>) -> Option<Rewritten> {
    if !context_catalog.is_none_or(is_aws_data_catalog) {
        return None;
    }
    CATALOG_DROPPED.iter().find_map(|(keywords, parts)| {
        let (query, _, database) = drop_first_part(query, keywords, *parts, is_aws_data_catalog)?;
        Some(Rewritten { query, database })
    })
}

/// 表への `DESCRIBE <db>.<t>`・`DESC <db>.<t>`（`drop_catalog` の後の 2 部）なら、DB と直後の `.` を落とした
/// 文と、修飾の DB（小文字にしない。本物は文中の綴りを返した。2026-09-26 実測 m12）を返す。表かどうかは
/// 呼び出し側が開始時の確認（`entity_check`）で決める。Context の条件は `drop_catalog` と同じ（実在しない
/// Catalog では本物は修飾を残した。#212・#214 の実測）。
pub(super) fn drop_database(query: &str, context_catalog: Option<&str>) -> Option<Rewritten> {
    if !context_catalog.is_none_or(is_aws_data_catalog) {
        return None;
    }
    [&["DESCRIBE"][..], &["DESC"]].iter().find_map(|keywords| {
        let (query, database, _) = drop_first_part(query, keywords, 2, |_| true)?;
        Some(Rewritten { query, database })
    })
}

/// DESCRIBE の直後がブロックコメントなら、本物の Hive の ParseException（2026-09-22 実測 `DESCRIBE /* c */ t`、
/// 2026-09-26 実測 m10 `DESCRIBE <db>./* c */<t>`）。文言の `'DESCRIBE'` は書いた綴りにする（測ったのは大文字）。
/// 行コメント・DESC・先頭のコメントは測っていないので対象にしない。
pub(super) fn describe_parse_error(query: &str) -> Option<Failure> {
    let keyword = query
        .get(..8)
        .filter(|word| word.eq_ignore_ascii_case("DESCRIBE"))?;
    query[8..]
        .trim_start_matches([' ', '\t', '\r', '\n'])
        .starts_with("/*")
        .then(|| Failure::describe_parse_error(keyword))
}

/// `keywords` の後ろの名前がちょうど `parts` 部ですべて無引用で、1 部目が `first` に当たれば、1 部目と直後の
/// `.`・空白を落とした文と、1 部目・2 部目の綴りを返す。引用符付きの部品を含む名前は、開始時の判定（`quoted_names`）に
/// 任せて落とさない。
fn drop_first_part(
    query: &str,
    keywords: &[&str],
    parts: usize,
    first: impl Fn(&str) -> bool,
) -> Option<(String, String, String)> {
    let name = table_name_start(query, keywords)?;
    let offset = query.len() - name.len();
    let qualified = athena_sql::Cursor::new(name).qualified_name()?;
    let [head, second, ..] = qualified.parts.as_slice() else {
        return None;
    };
    if qualified.parts.len() != parts
        || !first(head.text)
        || qualified
            .parts
            .iter()
            .any(|part| part.text.starts_with('"'))
    {
        return None;
    }
    Some((
        remove_keeping_comments(query, offset + head.start, offset + second.start),
        head.text.to_string(),
        second.text.to_string(),
    ))
}

fn is_aws_data_catalog(name: &str) -> bool {
    name.eq_ignore_ascii_case("awsdatacatalog")
}

/// `query` の `start..end` から、コメントだけを残して空白・`.`・無引用の名前を捨てる（本物は
/// `DESCRIBE <db>./* c */<t>` の `/* c */` を残した。2026-09-26 実測 m10）。範囲に引用符付きの名前は来ない。
fn remove_keeping_comments(query: &str, start: usize, end: usize) -> String {
    let bytes = query.as_bytes();
    let mut kept = String::from(&query[..start]);
    let mut i = start;
    while i < end {
        match athena_sql::comment_end(bytes, i) {
            Some(comment_end) => {
                kept.push_str(&query[i..comment_end.min(end)]);
                i = comment_end;
            }
            None => i += 1,
        }
    }
    kept.push_str(&query[end..]);
    kept
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dropped(query: &str) -> Option<(String, String)> {
        drop_catalog(query, Some("AwsDataCatalog")).map(|r| (r.query, r.database))
    }

    #[test]
    fn 一部目の_awsdatacatalog_と直後の点と空白を落とし_修飾の_db_を返す() {
        for (query, statement, database) in [
            ("DESCRIBE awsdatacatalog.db.t", "DESCRIBE db.t", "db"),
            ("DESC AwsDataCatalog.DB.t", "DESC DB.t", "DB"),
            (
                "SHOW COLUMNS IN awsdatacatalog.db.t",
                "SHOW COLUMNS IN db.t",
                "db",
            ),
            (
                "SHOW CREATE TABLE awsdatacatalog . db . t",
                "SHOW CREATE TABLE db . t",
                "db",
            ),
            (
                "SHOW TABLES IN awsdatacatalog.db",
                "SHOW TABLES IN db",
                "db",
            ),
            (
                "DROP TABLE IF EXISTS awsdatacatalog.db.t",
                "DROP TABLE IF EXISTS db.t",
                "db",
            ),
            (
                "ALTER TABLE awsdatacatalog.db.t ADD COLUMNS (m int)",
                "ALTER TABLE db.t ADD COLUMNS (m int)",
                "db",
            ),
            // 落とす範囲のコメントは残す。
            (
                "DESCRIBE awsdatacatalog./* c */db.t",
                "DESCRIBE /* c */db.t",
                "db",
            ),
        ] {
            assert_eq!(
                dropped(query),
                Some((statement.to_string(), database.to_string())),
                "{query}"
            );
        }
    }

    #[test]
    fn 対象外の文と形は落とさない() {
        for query in [
            "SELECT * FROM awsdatacatalog.db.t",
            "SHOW VIEWS IN awsdatacatalog.db",
            "DESCRIBE db.t",
            "DESCRIBE awsdatacatalog.db.t.n",
            "SHOW TABLES IN awsdatacatalog.db.t",
            "DESCRIBE \"awsdatacatalog\".db.t",
            "DESCRIBE awsdatacatalog.\"db\".t",
            "DESCRIBE hive.db.t",
        ] {
            assert_eq!(dropped(query), None, "{query}");
        }
    }

    #[test]
    fn describe_の_2_部は_db_を落とし_綴りのまま返す() {
        let dropped =
            |query| drop_database(query, Some("AwsDataCatalog")).map(|r| (r.query, r.database));
        assert_eq!(
            dropped("DESCRIBE DB.t"),
            Some(("DESCRIBE t".to_string(), "DB".to_string()))
        );
        assert_eq!(
            dropped("DESC db./* c */t"),
            Some(("DESC /* c */t".to_string(), "db".to_string()))
        );
        for query in [
            "DESCRIBE t",
            "DESCRIBE a.b.c",
            "DESCRIBE \"db\".t",
            "SHOW COLUMNS FROM db.t",
        ] {
            assert_eq!(dropped(query), None, "{query}");
        }
        assert_eq!(drop_database("DESCRIBE db.t", Some("nocatalog")), None);
    }

    #[test]
    fn describe_の直後のブロックコメントだけ_parse_exception_にする() {
        for query in [
            "DESCRIBE /* c */ t",
            "DESCRIBE /* c */t",
            "describe\n/* c */ t",
        ] {
            assert!(describe_parse_error(query).is_some(), "{query}");
        }
        assert_eq!(
            describe_parse_error("describe /* c */ t").map(|failure| failure.reason),
            Some(
                "FAILED: ParseException line 1:0 cannot recognize input near 'describe' '/' '*' in describe statement"
                    .to_string()
            )
        );
        for query in [
            "DESCRIBE -- c\nt",
            "DESCRIBE t /* c */",
            "DESC /* c */ t",
            "DESCRIBEX /* c */ t",
        ] {
            assert!(describe_parse_error(query).is_none(), "{query}");
        }
    }

    #[test]
    fn context_の_catalog_が_awsdatacatalog_か省略のときだけ落とす() {
        let query = "SHOW TABLES IN awsdatacatalog.db";
        assert!(drop_catalog(query, None).is_some());
        assert!(drop_catalog(query, Some("awsdatacatalog")).is_some());
        assert_eq!(drop_catalog(query, Some("other")), None);
    }
}
