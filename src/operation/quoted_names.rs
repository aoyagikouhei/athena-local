//! 本物の Athena が StartQueryExecution の時点で弾く、引用符付きの名前を取る DDL 系の文とその文言（#204）。

use athena_sql::{Cursor, skip_leading_trivia};

use super::classification::substatement_type;
use super::target_table::table_name_start;

/// 本物の `expecting {…}` の一覧（2026-09-25 実測。どの文・名前の形でも 1 文字も違わなかった）。
const EXPECTING: &str = "{'SELECT', 'FROM', 'ADD', 'AS', 'ALL', 'DISTINCT', 'WHERE', 'GROUP', 'BY', 'GROUPING', 'SETS', 'CUBE', 'ROLLUP', 'ORDER', 'HAVING', 'LIMIT', 'AT', 'OR', 'AND', 'IN', NOT, 'NO', 'EXISTS', 'BETWEEN', 'LIKE', RLIKE, 'IS', 'NULL', 'TRUE', 'FALSE', 'NULLS', 'ASC', 'DESC', 'FOR', 'INTERVAL', 'CASE', 'WHEN', 'THEN', 'ELSE', 'END', 'JOIN', 'CROSS', 'OUTER', 'INNER', 'LEFT', 'SEMI', 'RIGHT', 'FULL', 'NATURAL', 'ON', 'LATERAL', 'WINDOW', 'OVER', 'PARTITION', 'RANGE', 'ROWS', 'UNBOUNDED', 'PRECEDING', 'FOLLOWING', 'CURRENT', 'ROW', 'WITH', 'VALUES', 'CREATE', 'TABLE', 'VIEW', 'REPLACE', 'INSERT', 'DELETE', 'INTO', 'DESCRIBE', 'EXPLAIN', 'FORMAT', 'LOGICAL', 'CODEGEN', 'CAST', 'SHOW', 'TABLES', 'COLUMNS', 'COLUMN', 'USE', 'PARTITIONS', 'FUNCTIONS', 'DROP', 'UNION', 'EXCEPT', 'INTERSECT', 'TO', 'TABLESAMPLE', 'STRATIFY', 'ALTER', 'RENAME', 'ARRAY', 'MAP', 'STRUCT', 'COMMENT', 'SET', 'RESET', 'DATA', 'START', 'TRANSACTION', 'COMMIT', 'ROLLBACK', 'MACRO', 'FIRST', 'AFTER', 'IF', 'DIV', 'PERCENT', 'BUCKET', 'OUT', 'OF', 'SORT', 'CLUSTER', 'DISTRIBUTE', 'OVERWRITE', 'TRANSFORM', 'REDUCE', 'USING', 'SERDE', 'SERDEPROPERTIES', 'RECORDREADER', 'RECORDWRITER', 'DELIMITED', 'FIELDS', 'TERMINATED', 'COLLECTION', 'ITEMS', 'KEYS', 'ESCAPED', 'LINES', 'SEPARATED', 'FUNCTION', 'EXTENDED', 'REFRESH', 'CLEAR', 'CACHE', 'UNCACHE', 'LAZY', 'FORMATTED', TEMPORARY, 'OPTIONS', 'UNSET', 'TBLPROPERTIES', 'DBPROPERTIES', 'BUCKETS', 'SKEWED', 'STORED', 'DIRECTORIES', 'LOCATION', 'EXCHANGE', 'ARCHIVE', 'UNARCHIVE', 'FILEFORMAT', 'TOUCH', 'COMPACT', 'CONCATENATE', 'CHANGE', 'CASCADE', 'RESTRICT', 'CLUSTERED', 'SORTED', 'PURGE', 'INPUTFORMAT', 'OUTPUTFORMAT', DATABASE, DATABASES, 'DFS', 'TRUNCATE', 'ANALYZE', 'COMPUTE', 'LIST', 'STATISTICS', 'PARTITIONED', 'EXTERNAL', 'DEFINED', 'REVOKE', 'GRANT', 'LOCK', 'UNLOCK', 'MSCK', 'REPAIR', 'EXPORT', 'IMPORT', 'LOAD', 'ROLE', 'ROLES', 'COMPACTIONS', 'PRINCIPALS', 'TRANSACTIONS', 'INDEX', 'INDEXES', 'LOCKS', 'OPTION', 'ANTI', 'LOCAL', 'INPATH', IDENTIFIER, BACKQUOTED_IDENTIFIER}";

/// 本物が開始時に弾く形なら、その文言を返す。`is_alias` は `TRINO_CATALOG_MAP` の別名（S3 Tables の
/// カタログ名）かどうか。構文チェックの後で呼ぶ: 本物は Trino が構文エラーにする形（`ALTER TABLE "t" ADD
/// COLUMNS` など）には Trino の文言を返した（2026-09-25 実測）。
///
/// 本物は、下の文の名前に引用符付きの部分が 1 つでもあると、その部分を Hive 系のパーサが読めずに弾く。
/// 無引用とバッククォートは通る。弾くのは実測した形だけで、実測していない形（3 部の ALTER の 2 番目だけ
/// 引用符付き、4 部以上、`ALTER TABLE IF EXISTS`、`CREATE TABLE IF NOT EXISTS`、SHOW TABLES IN と
/// CREATE TABLE の 2 部以上、引用符付きの部分に非 ASCII があるもの）は今までどおり実行する。
pub(super) fn rejection(query: &str, is_alias: impl Fn(&str) -> bool) -> Option<String> {
    // 本物は先頭の空白・タブ・改行を数えずに位置を出す（先頭のコメントは数える）。
    let sql = query.trim_start_matches([' ', '\t', '\r', '\n']);
    let (statement, rest) = STATEMENTS
        .iter()
        .find_map(|(keywords, statement)| Some((*statement, table_name_start(sql, keywords)?)))?;
    // `table_name_start` は `IF EXISTS` を読み飛ばすので、ALTER TABLE の直後に IF があるかは元から読み直す。
    if statement == Statement::AlterTable && {
        let mut cursor = Cursor::new(sql);
        cursor.keyword("ALTER") && cursor.keyword("TABLE") && cursor.keyword("IF")
    } {
        return None;
    }
    let offset = sql.len() - rest.len();
    let parts = Cursor::new(rest).qualified_name()?.parts;
    if parts.len() > 3 {
        return None;
    }
    let quoted = parts.iter().position(|part| part.text.starts_with('"'))?;
    let part = |index: usize| (offset + parts[index].start, offset + parts[index].end);
    let (start, end) = part(quoted);
    // 引用符付きの部分に非 ASCII があると、本物は構文の文言でなく Glue の Entity Not Found（毎回違う
    // Request ID 付き）を返した（DESCRIBE で実測）。ほかの文は測っていないので、どれも弾かない。
    if !sql[start..end].is_ascii() {
        return None;
    }
    // 文の最初の語（先頭のコメントの後ろ）と名前の始まり。
    let statement_start = sql.len() - skip_leading_trivia(sql).len();
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
        (Statement::AlterTable, 3, 1) => None,
        (Statement::AlterTable, _, _) => no_viable(statement_start),
        (Statement::ShowTables, 1, _) => mismatched(),
        (Statement::CreateTable, 1, _) if substatement_type(query) == Some("CREATE_TABLE") => {
            no_viable(statement_start)
        }
        (Statement::ShowTables | Statement::CreateTable, _, _) => None,
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

const NOT_SUPPORTED: &str = "Queries of this type are not supported";
const TWO_CATALOGS: &str = "Unsupported DDL with 2 catalogs";

fn no_viable_alternative(sql: &str, at: usize, input: &str) -> String {
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
fn position(sql: &str, at: usize) -> (usize, usize) {
    let before = &sql[..at];
    let line_start = before.rfind('\n').map_or(0, |newline| newline + 1);
    (
        before.matches('\n').count() + 1,
        before[line_start..].encode_utf16().count() + 1,
    )
}

/// input の中の改行・CR・タブは、本物もバックスラッシュで書く（`DESCRIBE\r\n"t"`。2026-09-25 実測）。
fn escape(input: &str) -> String {
    input
        .replace('\n', "\\n")
        .replace('\r', "\\r")
        .replace('\t', "\\t")
}

#[cfg(test)]
mod tests;
