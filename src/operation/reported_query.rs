//! 本物の Athena が GetQueryExecution の `Query` と Context の Database を組み直す文を、Store に入れる前に
//! 同じ形にする（2026-09-26 実測 ROUND=8。#242）。
//!
//! 本物は DESCRIBE・DESC・SHOW COLUMNS・SHOW CREATE TABLE・SHOW TABLES IN・ALTER TABLE・DROP TABLE の名前の
//! 1 部目の `awsdatacatalog`（大文字小文字によらない）と直後の `.` を落とし、Context の Database を修飾の DB に
//! する。SELECT・INSERT・CTAS・CREATE VIEW・EXPLAIN・SHOW VIEWS IN は送ったまま。落とした文は Context の
//! カタログで同じ表を指すので、athena-local は実行もその文で行う。

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
    let (name, parts) = CATALOG_DROPPED
        .iter()
        .find_map(|(keywords, parts)| Some((table_name_start(query, keywords)?, *parts)))?;
    let offset = query.len() - name.len();
    let qualified = athena_sql::Cursor::new(name).qualified_name()?;
    let [catalog, database, ..] = qualified.parts.as_slice() else {
        return None;
    };
    if qualified.parts.len() != parts
        || !is_aws_data_catalog(catalog.text)
        || qualified
            .parts
            .iter()
            .any(|part| part.text.starts_with('"'))
    {
        return None;
    }
    Some(Rewritten {
        query: remove_keeping_comments(query, offset + catalog.start, offset + database.start),
        database: database.text.to_string(),
    })
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
    fn context_の_catalog_が_awsdatacatalog_か省略のときだけ落とす() {
        let query = "SHOW TABLES IN awsdatacatalog.db";
        assert!(drop_catalog(query, None).is_some());
        assert!(drop_catalog(query, Some("awsdatacatalog")).is_some());
        assert_eq!(drop_catalog(query, Some("other")), None);
    }
}
