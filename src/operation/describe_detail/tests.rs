//! describe_detail.rs のユニットテスト。
//! 期待値は `$HOME/athena-describe-extended-measurements/run-20260927-034102` の e_h・e_hp・e_v・
//! f_h・f_hp・f_v・p1・p2・p3・p4（2026-09-27 実測。#275）から、D7 で省いた行・対を除いた形。
//! DB 名・表名は実名の代わりに `db`・`h`・`hp`・`v` を使う。

use super::*;

/// Trino の DESCRIBE の 1 行（`Column`／`Type`／`Extra`／`Comment`）。
fn row(name: &str, type_name: &str, extra: &str, comment: &str) -> Vec<Value> {
    [name, type_name, extra, comment].map(Value::from).into()
}

fn table<'a>(name: &'a str, kind: Kind) -> Table<'a> {
    Table {
        db: "db",
        name,
        kind,
    }
}

/// 本物の e_h（Hive 表、列コメント付き。2026-09-27 実測）と一致する。
#[test]
fn extended_は_hive_表の列の行と_thrift_の_1_行を返す() {
    let rows = [
        row("n", "integer", "", ""),
        row("s", "varchar", "", "the s column"),
    ];
    let expected = [
        "n                   \tint                 \t                    ",
        "s                   \tstring              \tthe s column        ",
        "\t \t ",
        "Detailed Table Information\tTable(tableName:h, dbName:db, lastAccessTime:0, retention:0, sd:StorageDescriptor(cols:[FieldSchema(name:n, type:int, comment:null), FieldSchema(name:s, type:string, comment:the s column)], compressed:false, bucketCols:[], sortCols:[], parameters:{}, storedAsSubDirectories:false), partitionKeys:[], tableType:EXTERNAL_TABLE)\t",
    ];
    assert_eq!(extended(&rows, &table("h", Kind::Table)), expected);
}

/// 本物の e_hp（パーティション付き Hive 表。2026-09-27 実測）と一致する。`partitionKeys` にパーティション列。
#[test]
fn extended_はパーティション付きなら_partition_information_の塊と_partitionkeys_を持つ() {
    let rows = [
        row("n", "integer", "", ""),
        row("p", "varchar(1)", "partition key", ""),
    ];
    let expected = [
        "n                   \tint                 \t                    ",
        "p                   \tvarchar(1)          \t                    ",
        "\t \t ",
        "# Partition Information\t \t ",
        "# col_name            \tdata_type           \tcomment             ",
        "\t \t ",
        "p                   \tvarchar(1)          \t                    ",
        "\t \t ",
        "Detailed Table Information\tTable(tableName:hp, dbName:db, lastAccessTime:0, retention:0, sd:StorageDescriptor(cols:[FieldSchema(name:n, type:int, comment:null), FieldSchema(name:p, type:varchar(1), comment:null)], compressed:false, bucketCols:[], sortCols:[], parameters:{}, storedAsSubDirectories:false), partitionKeys:[FieldSchema(name:p, type:varchar(1), comment:null)], tableType:EXTERNAL_TABLE)\t",
    ];
    assert_eq!(extended(&rows, &table("hp", Kind::Table)), expected);
}

/// 本物の e_v（ビュー。2026-09-27 実測）と一致する。`tableType` が `VIRTUAL_VIEW`。
#[test]
fn extended_はビューなら_tabletype_が_virtual_view() {
    let rows = [row("n", "integer", "", ""), row("s", "varchar(1)", "", "")];
    let expected = [
        "n                   \tint                 \t                    ",
        "s                   \tvarchar(1)          \t                    ",
        "\t \t ",
        "Detailed Table Information\tTable(tableName:v, dbName:db, lastAccessTime:0, retention:0, sd:StorageDescriptor(cols:[FieldSchema(name:n, type:int, comment:null), FieldSchema(name:s, type:varchar(1), comment:null)], compressed:false, bucketCols:[], sortCols:[], parameters:{}, storedAsSubDirectories:false), partitionKeys:[], tableType:VIRTUAL_VIEW)\t",
    ];
    assert_eq!(extended(&rows, &table("v", Kind::View)), expected);
}

/// 本物の f_h（Hive 表。2026-09-27 実測）と一致する。
#[test]
fn formatted_は見出しと列の行の後に_detailed_table_information_と_storage_information() {
    let rows = [
        row("n", "integer", "", ""),
        row("s", "varchar", "", "the s column"),
    ];
    let expected = [
        "# col_name            \tdata_type           \tcomment             ",
        "\t \t ",
        "n                   \tint                 \t                    ",
        "s                   \tstring              \tthe s column        ",
        "\t \t ",
        "# Detailed Table Information\t \t ",
        "Database:           \tdb                  \t ",
        "LastAccessTime:     \tUNKNOWN             \t ",
        "Protect Mode:       \tNone                \t ",
        "Retention:          \t0                   \t ",
        "Table Type:         \tEXTERNAL_TABLE      \t ",
        "\t \t ",
        "# Storage Information\t \t ",
        "Compressed:         \tNo                  \t ",
        "Bucket Columns:     \t[]                  \t ",
        "Sort Columns:       \t[]                  \t ",
    ];
    assert_eq!(formatted(&rows, &table("h", Kind::Table)), expected);
}

/// 本物の f_hp（パーティション付き Hive 表。2026-09-27 実測）と一致する。
/// パーティション列は上半分に出さず、`# Partition Information` の塊に出す。
#[test]
fn formatted_はパーティション列を上半分から除き_partition_information_の塊に出す() {
    let rows = [
        row("n", "integer", "", ""),
        row("p", "varchar(1)", "partition key", ""),
    ];
    let expected = [
        "# col_name            \tdata_type           \tcomment             ",
        "\t \t ",
        "n                   \tint                 \t                    ",
        "\t \t ",
        "# Partition Information\t \t ",
        "# col_name            \tdata_type           \tcomment             ",
        "\t \t ",
        "p                   \tvarchar(1)          \t                    ",
        "\t \t ",
        "# Detailed Table Information\t \t ",
        "Database:           \tdb                  \t ",
        "LastAccessTime:     \tUNKNOWN             \t ",
        "Protect Mode:       \tNone                \t ",
        "Retention:          \t0                   \t ",
        "Table Type:         \tEXTERNAL_TABLE      \t ",
        "\t \t ",
        "# Storage Information\t \t ",
        "Compressed:         \tNo                  \t ",
        "Bucket Columns:     \t[]                  \t ",
        "Sort Columns:       \t[]                  \t ",
    ];
    assert_eq!(formatted(&rows, &table("hp", Kind::Table)), expected);
}

/// 本物の f_v（ビュー。2026-09-27 実測）と一致する。`Table Type` が `VIRTUAL_VIEW`、
/// `Location:`・`# View Information` の節は省く。
#[test]
fn formatted_はビューなら_table_type_が_virtual_view_で_view_information_を出さない() {
    let rows = [row("n", "integer", "", ""), row("s", "varchar(1)", "", "")];
    let expected = [
        "# col_name            \tdata_type           \tcomment             ",
        "\t \t ",
        "n                   \tint                 \t                    ",
        "s                   \tvarchar(1)          \t                    ",
        "\t \t ",
        "# Detailed Table Information\t \t ",
        "Database:           \tdb                  \t ",
        "LastAccessTime:     \tUNKNOWN             \t ",
        "Protect Mode:       \tNone                \t ",
        "Retention:          \t0                   \t ",
        "Table Type:         \tVIRTUAL_VIEW        \t ",
        "\t \t ",
        "# Storage Information\t \t ",
        "Compressed:         \tNo                  \t ",
        "Bucket Columns:     \t[]                  \t ",
        "Sort Columns:       \t[]                  \t ",
    ];
    assert_eq!(formatted(&rows, &table("v", Kind::View)), expected);
}

/// 本物の p1（2026-09-27 実測）と一致する。コメント欄は列コメントによらず `from deserializer`。
#[test]
fn column_extended_は_1_行_comment欄はfrom_deserializer() {
    let r = row("n", "integer", "", "");
    assert_eq!(
        column_extended(&r),
        ["n                   \tint                 \tfrom deserializer   "]
    );
}

/// 本物の p2（2026-09-27 実測）と一致する。ColumnInfo は 11 列。
#[test]
fn column_formatted_は見出し_空行_列の行の_3_行で_11_列() {
    let r = row("n", "integer", "", "");
    let expected = [
        "# col_name            \tdata_type           \tmin                 \tmax                 \tnum_nulls           \tdistinct_count      \tavg_col_len         \tmax_col_len         \tnum_trues           \tnum_falses          \tcomment             ",
        "\t \t \t \t \t \t \t \t \t \t ",
        "n                   \tint                 \t                    \t                    \t                    \t                    \t                    \t                    \t                    \t                    \tfrom deserializer   ",
    ];
    assert_eq!(column_formatted(&r), expected);
    assert_eq!(
        COLUMN_INFO_NAMES,
        [
            "col_name",
            "data_type",
            "min",
            "max",
            "num_nulls",
            "distinct_count",
            "avg_col_len",
            "max_col_len",
            "num_trues",
            "num_falses",
            "comment",
        ]
    );
}

/// 本物の p3（2026-09-27 実測）と一致する。Thrift の `cols` は、パーティション列以外の
/// コメント無しは `comment:`（空。表の EXTENDED の `comment:null` と違う）、パーティション列は
/// `comment:null`（生データどおり。#275 のノート参照）。
#[test]
fn partition_extended_は_partition_の_thrift_の_1_行を末尾に持つ() {
    let rows = [
        row("n", "integer", "", ""),
        row("p", "varchar(1)", "partition key", ""),
    ];
    let values = [("p".to_string(), "x".to_string())];
    let expected = [
        "n                   \tint                 \t                    ",
        "p                   \tvarchar(1)          \t                    ",
        "\t \t ",
        "# Partition Information\t \t ",
        "# col_name            \tdata_type           \tcomment             ",
        "\t \t ",
        "p                   \tvarchar(1)          \t                    ",
        "\t \t ",
        "Detailed Partition Information\tPartition(values:[x], dbName:db, tableName:hp, lastAccessTime:0, sd:StorageDescriptor(cols:[FieldSchema(name:n, type:int, comment:), FieldSchema(name:p, type:varchar(1), comment:null)], compressed:false, bucketCols:[], sortCols:[], parameters:{}, storedAsSubDirectories:false))\t",
    ];
    assert_eq!(
        partition_extended(&rows, &table("hp", Kind::Table), &values),
        expected
    );
}

/// 本物の p4（2026-09-27 実測）と一致する。`Detailed Partition Information` は
/// `Partition Value:`・`Database:`・`Table:`・`LastAccessTime:`・`Protect Mode:` だけを残す
/// （`CreateTime:`・`Location:`・`Partition Parameters:` の節は省く）。
#[test]
fn partition_formatted_は_detailed_partition_information_の節を持つ() {
    let rows = [
        row("n", "integer", "", ""),
        row("p", "varchar(1)", "partition key", ""),
    ];
    let values = [("p".to_string(), "x".to_string())];
    let expected = [
        "# col_name            \tdata_type           \tcomment             ",
        "\t \t ",
        "n                   \tint                 \t                    ",
        "\t \t ",
        "# Partition Information\t \t ",
        "# col_name            \tdata_type           \tcomment             ",
        "\t \t ",
        "p                   \tvarchar(1)          \t                    ",
        "\t \t ",
        "# Detailed Partition Information\t \t ",
        "Partition Value:    \t[x]                 \t ",
        "Database:           \tdb                  \t ",
        "Table:              \thp                  \t ",
        "LastAccessTime:     \tUNKNOWN             \t ",
        "Protect Mode:       \tNone                \t ",
        "\t \t ",
        "# Storage Information\t \t ",
        "Compressed:         \tNo                  \t ",
        "Bucket Columns:     \t[]                  \t ",
        "Sort Columns:       \t[]                  \t ",
    ];
    assert_eq!(
        partition_formatted(&rows, &table("hp", Kind::Table), &values),
        expected
    );
}
