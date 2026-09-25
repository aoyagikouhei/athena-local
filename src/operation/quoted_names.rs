//! 本物の Athena が StartQueryExecution の時点で弾く、引用符付きの名前を取る DDL 系の文とその文言（#204）。

use athena_sql::{Cursor, skip_leading_trivia, skip_trivia};

use super::classification::substatement_type;
use super::target_table::{if_follows, table_name_start};

/// 本物の `expecting {…}` の一覧（2026-09-25 実測。どの文・名前の形でも 1 文字も違わなかった）。
const EXPECTING: &str = "{'SELECT', 'FROM', 'ADD', 'AS', 'ALL', 'DISTINCT', 'WHERE', 'GROUP', 'BY', 'GROUPING', 'SETS', 'CUBE', 'ROLLUP', 'ORDER', 'HAVING', 'LIMIT', 'AT', 'OR', 'AND', 'IN', NOT, 'NO', 'EXISTS', 'BETWEEN', 'LIKE', RLIKE, 'IS', 'NULL', 'TRUE', 'FALSE', 'NULLS', 'ASC', 'DESC', 'FOR', 'INTERVAL', 'CASE', 'WHEN', 'THEN', 'ELSE', 'END', 'JOIN', 'CROSS', 'OUTER', 'INNER', 'LEFT', 'SEMI', 'RIGHT', 'FULL', 'NATURAL', 'ON', 'LATERAL', 'WINDOW', 'OVER', 'PARTITION', 'RANGE', 'ROWS', 'UNBOUNDED', 'PRECEDING', 'FOLLOWING', 'CURRENT', 'ROW', 'WITH', 'VALUES', 'CREATE', 'TABLE', 'VIEW', 'REPLACE', 'INSERT', 'DELETE', 'INTO', 'DESCRIBE', 'EXPLAIN', 'FORMAT', 'LOGICAL', 'CODEGEN', 'CAST', 'SHOW', 'TABLES', 'COLUMNS', 'COLUMN', 'USE', 'PARTITIONS', 'FUNCTIONS', 'DROP', 'UNION', 'EXCEPT', 'INTERSECT', 'TO', 'TABLESAMPLE', 'STRATIFY', 'ALTER', 'RENAME', 'ARRAY', 'MAP', 'STRUCT', 'COMMENT', 'SET', 'RESET', 'DATA', 'START', 'TRANSACTION', 'COMMIT', 'ROLLBACK', 'MACRO', 'FIRST', 'AFTER', 'IF', 'DIV', 'PERCENT', 'BUCKET', 'OUT', 'OF', 'SORT', 'CLUSTER', 'DISTRIBUTE', 'OVERWRITE', 'TRANSFORM', 'REDUCE', 'USING', 'SERDE', 'SERDEPROPERTIES', 'RECORDREADER', 'RECORDWRITER', 'DELIMITED', 'FIELDS', 'TERMINATED', 'COLLECTION', 'ITEMS', 'KEYS', 'ESCAPED', 'LINES', 'SEPARATED', 'FUNCTION', 'EXTENDED', 'REFRESH', 'CLEAR', 'CACHE', 'UNCACHE', 'LAZY', 'FORMATTED', TEMPORARY, 'OPTIONS', 'UNSET', 'TBLPROPERTIES', 'DBPROPERTIES', 'BUCKETS', 'SKEWED', 'STORED', 'DIRECTORIES', 'LOCATION', 'EXCHANGE', 'ARCHIVE', 'UNARCHIVE', 'FILEFORMAT', 'TOUCH', 'COMPACT', 'CONCATENATE', 'CHANGE', 'CASCADE', 'RESTRICT', 'CLUSTERED', 'SORTED', 'PURGE', 'INPUTFORMAT', 'OUTPUTFORMAT', DATABASE, DATABASES, 'DFS', 'TRUNCATE', 'ANALYZE', 'COMPUTE', 'LIST', 'STATISTICS', 'PARTITIONED', 'EXTERNAL', 'DEFINED', 'REVOKE', 'GRANT', 'LOCK', 'UNLOCK', 'MSCK', 'REPAIR', 'EXPORT', 'IMPORT', 'LOAD', 'ROLE', 'ROLES', 'COMPACTIONS', 'PRINCIPALS', 'TRANSACTIONS', 'INDEX', 'INDEXES', 'LOCKS', 'OPTION', 'ANTI', 'LOCAL', 'INPATH', IDENTIFIER, BACKQUOTED_IDENTIFIER}";

/// 本物が開始時に弾く形なら、その文言を返す。`is_alias` は `TRINO_CATALOG_MAP` の別名（S3 Tables の
/// カタログ名）かどうか。構文チェックの後で呼ぶ: 本物は Trino が構文エラーにする形（`ALTER TABLE "t" ADD
/// COLUMNS` など）には Trino の文言を返した（2026-09-25 実測）。DESCRIBE・SHOW COLUMNS の対象が実在しないときと
/// ビューのときは、先に `entity_check` が決める（本物は存在を先に確かめる。#207）。
///
/// 本物は、下の文の名前に引用符付きの部分が 1 つでもあると、その部分を Hive 系のパーサが読めずに弾く。
/// 無引用とバッククォートは通る。4 部以上の名前（SHOW TABLES IN は 3 部以上）は無引用でも弾く（#207・#212）。
/// 弾くのは実測した形だけで、実測していない形（`ALTER TABLE IF EXISTS`、CTAS の 4 部以上、引用符付きの部分が
/// 3 部目までに無い `CREATE TABLE IF NOT EXISTS` の 4 部以上）は今までどおり実行する。
pub(super) fn rejection(query: &str, is_alias: impl Fn(&str) -> bool) -> Option<String> {
    // 本物は先頭の空白・タブ・改行を数えずに位置を出す（先頭のコメントは数える）。
    let sql = query.trim_start_matches([' ', '\t', '\r', '\n']);
    let (statement, rest) = STATEMENTS
        .iter()
        .find_map(|(keywords, statement)| Some((*statement, table_name_start(sql, keywords)?)))?;
    // `ALTER TABLE IF EXISTS ...` は #208 から `unquoted_ddl::rejection` が引き取る
    // （引用符の有無によらず、名前の後ろの語だけで文言が決まるため）。
    if statement == Statement::AlterTable && if_follows(sql, "ALTER") {
        return None;
    }
    let offset = sql.len() - rest.len();
    let parts = Cursor::new(rest).qualified_name()?.parts;
    let part = |index: usize| (offset + parts[index].start, offset + parts[index].end);
    // 文の最初の語（先頭のコメントの後ろ）と名前の始まり。
    let statement_start = sql.len() - skip_leading_trivia(sql).len();
    let quoted = parts.iter().position(|part| part.text.starts_with('"'));
    // SHOW TABLES IN の 3 部以上（2026-09-25 実測 Y1・Y2。#212）。引用符付きの部分が 2 部目までに無ければ
    // 2 つ目の `.` で弾かれ、その直後が引用符付き（Hive では文字列）なら extraneous input になる。
    if statement == Statement::ShowTables
        && parts.len() >= 3
        && quoted.is_none_or(|index| index >= 2)
    {
        let (line, column) = position(sql, skip_trivia(sql.as_bytes(), part(1).1));
        let kind = if parts[2].text.starts_with('"') {
            "extraneous"
        } else {
            "mismatched"
        };
        return Some(format!(
            "line {line}:{column}: {kind} input '.' expecting {{<EOF>, 'LIKE', STRING}}"
        ));
    }
    let quoted = if parts.len() <= 3 {
        quoted?
    } else {
        // 4 部以上（2026-09-25 実測 V2・W2・W3（#207）、Y1・Y4（#212））。DESCRIBE・SHOW COLUMNS・
        // SHOW CREATE TABLE は引用符の有無・位置によらず、S3 Tables の別名より先に Invalid table name で、
        // 名前は引用符を外した中身を小文字にしてつなぐ。DROP・ALTER・CREATE TABLE（と、上で 2 部目までに
        // 引用符付きの部分がある SHOW TABLES IN）は引用符付きの部分が 3 部目までにあれば 3 部と同じ規則で、
        // 無ければ 3 つ目の `.` で弾かれる。
        let dot = skip_trivia(sql.as_bytes(), part(2).1);
        match (statement, quoted) {
            (Statement::Describe | Statement::ShowColumns | Statement::ShowCreateTable, _) => {
                let name: Vec<String> = parts
                    .iter()
                    .map(|part| part.value().to_lowercase())
                    .collect();
                return Some(format!("Invalid table name {}", name.join(".")));
            }
            (
                Statement::DropTable
                | Statement::AlterTable
                | Statement::CreateTable
                | Statement::ShowTables,
                Some(index),
            ) if index < 3 => index,
            (Statement::DropTable, _) => {
                let (line, column) = position(sql, dot);
                return Some(format!(
                    "line {line}:{column}: mismatched input '.' expecting {{<EOF>, 'PURGE'}}"
                ));
            }
            (Statement::AlterTable, _) => {
                return Some(no_viable_alternative(sql, dot, &sql[statement_start..=dot]));
            }
            (Statement::CreateTable, _)
                // IF NOT EXISTS の 3 つ目の `.` は実測していない（引用符付きの部分が 3 部目までにあれば、4 部目を
                // 読む前に文言が決まるので、上の腕で 3 部と同じ規則を当てる）。
                if substatement_type(query) == Some("CREATE_TABLE")
                    && !if_follows(sql, "CREATE") =>
            {
                let (line, column) = position(sql, dot);
                return Some(format!(
                    "line {line}:{column}: mismatched input '.' expecting {CREATE_TABLE_EXPECTING}"
                ));
            }
            _ => return None,
        }
    };
    let (start, end) = part(quoted);
    let name_start = part(0).0;
    let no_viable = |from: usize| Some(no_viable_alternative(sql, start, &sql[from..end]));
    let mismatched = || Some(mismatched_input(sql, start, &sql[start..end]));

    match (statement, parts.len(), quoted) {
        (Statement::ShowCreateTable, _, _) => Some(NOT_SUPPORTED.to_string()),
        (Statement::Describe | Statement::ShowColumns, _, 0) if is_alias(&parts[0].value()) => {
            Some(TWO_CATALOGS.to_string())
        }
        (Statement::Describe, _, 0) => no_viable(statement_start),
        (Statement::Describe | Statement::ShowColumns | Statement::DropTable, _, 1) => {
            no_viable(name_start)
        }
        (Statement::Describe, _, _) | (Statement::ShowColumns | Statement::DropTable, _, _) => {
            mismatched()
        }
        (Statement::AlterTable, _, _) => no_viable(statement_start),
        (Statement::ShowTables, _, _) => mismatched(),
        (Statement::CreateTable, _, _) if substatement_type(query) == Some("CREATE_TABLE") => {
            no_viable(statement_start)
        }
        (Statement::CreateTable, _, _) => None,
    }
}

/// 名前の前のキーワードの並びと文の種類。並びの読み方は対象テーブルの解析と共有する
/// （`target_table::table_name_start`。`IF EXISTS` もそこで読み飛ばす）。
const STATEMENTS: &[(&[&str], Statement)] = &[
    (&["DESCRIBE"], Statement::Describe),
    (&["DESC"], Statement::Describe),
    (&["SHOW", "COLUMNS", "FROM"], Statement::ShowColumns),
    (&["SHOW", "COLUMNS", "IN"], Statement::ShowColumns),
    (&["DROP", "TABLE"], Statement::DropTable),
    (&["SHOW", "CREATE", "TABLE"], Statement::ShowCreateTable),
    (&["ALTER", "TABLE"], Statement::AlterTable),
    (&["SHOW", "TABLES", "IN"], Statement::ShowTables),
    (&["CREATE", "TABLE"], Statement::CreateTable),
    // `table_name_start` は IF の後に EXISTS しか読まないので、IF NOT EXISTS は並びごと書く（#207）。
    (
        &["CREATE", "TABLE", "IF", "NOT", "EXISTS"],
        Statement::CreateTable,
    ),
];

#[derive(Clone, Copy, PartialEq, Eq)]
enum Statement {
    Describe,
    ShowColumns,
    DropTable,
    ShowCreateTable,
    AlterTable,
    ShowTables,
    CreateTable,
}

/// CTAS でない CREATE TABLE の 4 部以上で、3 つ目の `.` に対する本物の `expecting {…}`（2026-09-25 実測 Y1。#212）。
const CREATE_TABLE_EXPECTING: &str = "{<EOF>, '(', 'SELECT', 'FROM', 'AS', 'ROW', 'WITH', 'VALUES', 'TABLE', 'INSERT', 'MAP', 'COMMENT', 'REDUCE', 'TBLPROPERTIES', 'SKEWED', 'STORED', 'LOCATION', 'CLUSTERED', 'PARTITIONED'}";

const NOT_SUPPORTED: &str = "Queries of this type are not supported";
const TWO_CATALOGS: &str = "Unsupported DDL with 2 catalogs";

pub(super) fn no_viable_alternative(sql: &str, at: usize, input: &str) -> String {
    let (line, column) = position(sql, at);
    format!(
        "line {line}:{column}: no viable alternative at input '{}'",
        escape(input)
    )
}

fn mismatched_input(sql: &str, at: usize, input: &str) -> String {
    let (line, column) = position(sql, at);
    format!(
        "line {line}:{column}: mismatched input '{}' expecting {EXPECTING}",
        escape(input)
    )
}

/// `line L:C` の L と C。C は行頭からの UTF-16 の単位数 + 1（`/* 😀 */` の後ろが 1 つ多い。2026-09-25 実測）。
pub(super) fn position(sql: &str, at: usize) -> (usize, usize) {
    let before = &sql[..at];
    let line_start = before.rfind('\n').map_or(0, |newline| newline + 1);
    (
        before.matches('\n').count() + 1,
        before[line_start..].encode_utf16().count() + 1,
    )
}

/// input の中の改行・CR・タブは、本物もバックスラッシュで書く（`DESCRIBE\r\n"t"`。2026-09-25 実測）。
pub(super) fn escape(input: &str) -> String {
    input
        .replace('\n', "\\n")
        .replace('\r', "\\r")
        .replace('\t', "\\t")
}

#[cfg(test)]
mod tests;
