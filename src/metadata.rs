//! 結果ファイルの隣に置く `<id>.csv.metadata` / `<id>.txt.metadata` の中身（protobuf）。
//! `ResultSetMetadata`（`GetQueryResults` が返す JSON）のことではない。
//!
//! 形式は 2026-09-17 に本物の Athena が置いたファイルを実測したもの。公式のスキーマは無く、
//! フィールド番号は burtcorp/athena-jdbc の `AthenaMetaDataParser` が記録しているものと同じ。

use crate::athena::ColumnInfo;

/// 9 Nullable の値。`ColumnInfo.nullable` は常に `"UNKNOWN"` なので定数にしている
/// （1 = NOT_NULL、2 = NULLABLE は本物で未観測なので写像は作らない）。
const NULLABLE_UNKNOWN: u64 = 3;

/// 結果ファイルの隣に置く `.metadata` の中身を作る。
/// top-level は field 1 クエリ ID、2 updateType、3 更新件数、4 列（繰り返し）の順。
pub(crate) fn to_metadata(
    query_id: &str,
    update_type: Option<&str>,
    update_count: Option<i64>,
    columns: &[ColumnInfo],
) -> Vec<u8> {
    let mut buffer = Vec::new();
    put_string(&mut buffer, 1, query_id);
    if let Some(update_type) = update_type {
        put_string(&mut buffer, 2, update_type);
    }
    if let Some(update_count) = update_count {
        // 0 でも書く。0 行の INSERT は本物も `18 00` を書く（Hive は 2026-09-20、Iceberg は 2026-09-23 実測）。
        // 0 件の UPDATE / DELETE / MERGE は未実測。
        put_varint_field(&mut buffer, 3, update_count as u64);
    }
    for column in columns {
        put_message(&mut buffer, 4, &column_message(column));
    }
    buffer
}

/// 列 1 本ぶんの message。1 CatalogName、4 Name、5 Label、6 Type、7 Precision、
/// 8 Scale、9 Nullable、10 CaseSensitive の順。2 / 3（SchemaName / TableName）は本物にも無い。
fn column_message(column: &ColumnInfo) -> Vec<u8> {
    let (has_precision, has_scale, has_case_sensitive) = optional_fields(&column.type_name);
    let mut buffer = Vec::new();
    put_string(&mut buffer, 1, &column.catalog_name);
    put_string(&mut buffer, 4, &column.name);
    put_string(&mut buffer, 5, &column.label);
    put_string(&mut buffer, 6, &column.type_name);
    if has_precision {
        put_varint_field(&mut buffer, 7, column.precision as u64);
    }
    if has_scale {
        put_varint_field(&mut buffer, 8, column.scale as u64);
    }
    put_varint_field(&mut buffer, 9, NULLABLE_UNKNOWN);
    if has_case_sensitive {
        put_varint_field(&mut buffer, 10, u64::from(column.case_sensitive));
    }
    buffer
}

/// 7 Precision / 8 Scale / 10 CaseSensitive を出すかどうかは、値ではなく Athena の型名で決まる
/// （値が 0 でも出す。proto3 の既定値省略ではない）。Trino JDBC の ColumnInfo の型ごとの設定と同じ形。
fn optional_fields(type_name: &str) -> (bool, bool, bool) {
    match type_name {
        "tinyint" | "smallint" | "integer" | "bigint" | "double" | "float" | "decimal"
        | "varchar" | "char" | "varbinary" | "timestamp" | "time"
        // 未実測。timestamp / time と同じ系統として同じ扱いにする。
        | "timestamp with time zone" | "time with time zone" => (true, true, true),
        // interval year to month は未実測。interval day to second と同じ扱いにする。
        "boolean" | "interval day to second" | "interval year to month" => (false, false, true),
        "date" => (false, true, true),
        // array / map / row / json / string と未知の型は 3 つとも出さない。
        _ => (false, false, false),
    }
}

/// LEB128。
fn put_varint(buffer: &mut Vec<u8>, mut value: u64) {
    while value >= 0x80 {
        buffer.push((value as u8) | 0x80);
        value >>= 7;
    }
    buffer.push(value as u8);
}

/// varint のフィールド（tag は field << 3 | 0）。
fn put_varint_field(buffer: &mut Vec<u8>, field: u64, value: u64) {
    put_varint(buffer, field << 3);
    put_varint(buffer, value);
}

/// 長さ前置のフィールド（tag は field << 3 | 2）。
fn put_bytes(buffer: &mut Vec<u8>, field: u64, bytes: &[u8]) {
    put_varint(buffer, (field << 3) | 2);
    put_varint(buffer, bytes.len() as u64);
    buffer.extend_from_slice(bytes);
}

/// 長さは文字数ではなく UTF-8 のバイト数。
fn put_string(buffer: &mut Vec<u8>, field: u64, text: &str) {
    put_bytes(buffer, field, text.as_bytes());
}

fn put_message(buffer: &mut Vec<u8>, field: u64, message: &[u8]) {
    put_bytes(buffer, field, message);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// fixtures の ColumnInfo は CatalogName `hive`、SchemaName / TableName 空、
    /// Nullable `UNKNOWN`、Label = Name がどの行でも同じなので、変わる 5 つだけを受ける。
    fn column(
        name: &str,
        type_name: &str,
        precision: i64,
        scale: i64,
        case_sensitive: bool,
    ) -> ColumnInfo {
        ColumnInfo {
            name: name.to_string(),
            label: name.to_string(),
            type_name: type_name.to_string(),
            nullable: "UNKNOWN".to_string(),
            case_sensitive,
            catalog_name: "hive".to_string(),
            schema_name: String::new(),
            table_name: String::new(),
            precision,
            scale,
        }
    }

    /// 16 進文字列を読む。空白と改行は無視する。
    fn hex(text: &str) -> Vec<u8> {
        let digits: Vec<u8> = text
            .bytes()
            .filter(|byte| !byte.is_ascii_whitespace())
            .collect();
        digits
            .chunks(2)
            .map(|pair| {
                u8::from_str_radix(std::str::from_utf8(pair).expect("16 進は ASCII"), 16)
                    .expect("16 進として読めない")
            })
            .collect()
    }

    /// 失敗したときに差分が読めるよう、比較は 16 進文字列どうしでする。
    fn hex_of(bytes: &[u8]) -> String {
        bytes.iter().map(|byte| format!("{byte:02x}")).collect()
    }

    #[test]
    fn 実測した_select_の_metadata_と同じバイト列になる() {
        // 採取元: run-20260917-175312/select-types.metadata.bytes、2026-09-17 実測（710 バイト）。
        let columns = vec![
            column("i", "integer", 10, 0, false),
            column("ti", "tinyint", 3, 0, false),
            column("si", "smallint", 5, 0, false),
            column("bi", "bigint", 19, 0, false),
            column("dec_lit", "double", 17, 0, false),
            column("d", "double", 17, 0, false),
            column("r", "float", 17, 0, false),
            column("dc", "decimal", 10, 2, false),
            column("b", "boolean", 0, 0, false),
            column("s", "varchar", 3, 0, true),
            column("vc", "varchar", 10, 0, true),
            column("c", "char", 5, 0, true),
            column("dt", "date", 0, 0, false),
            column("ts", "timestamp", 3, 0, false),
            column("arr", "array", 0, 0, false),
            column("m", "map", 0, 0, false),
            column("rw", "row", 0, 0, false),
            column("j", "json", 0, 0, false),
            column("vb", "varbinary", 1073741824, 0, false),
            column("n", "integer", 10, 0, false),
            column("iv", "interval day to second", 0, 0, false),
            column("t", "time", 3, 0, false),
        ];

        let actual = to_metadata("20260917_085344_00007_k6s5b", None, None, &columns);

        let expected = hex(
            "0a1b32303236303931375f3038353334345f30303030375f6b36733562221d0a
             04686976652201692a01693207696e7465676572380a400048035000221f0a04
             68697665220274692a027469320774696e79696e74380340004803500022200a
             0468697665220273692a0273693208736d616c6c696e74380540004803500022
             1e0a0468697665220262692a0262693206626967696e74381340004803500022
             280a046869766522076465635f6c69742a076465635f6c69743206646f75626c
             653811400048035000221c0a04686976652201642a01643206646f75626c6538
             11400048035000221b0a04686976652201722a01723205666c6f617438114000
             48035000221f0a0468697665220264632a0264633207646563696d616c380a40
             024803500022190a04686976652201622a01623207626f6f6c65616e48035000
             221d0a04686976652201732a0173320776617263686172380340004803500122
             1f0a0468697665220276632a027663320776617263686172380a400048035001
             221a0a04686976652201632a01633204636861723805400048035001221a0a04
             68697665220264742a02647432046461746540004803500022210a0468697665
             220274732a027473320974696d657374616d70380340004803500022190a0468
             69766522036172722a0361727232056172726179480322130a04686976652201
             6d2a016d32036d6170480322150a0468697665220272772a0272773203726f77
             480322140a046869766522016a2a016a32046a736f6e480322250a0468697665
             220276622a027662320976617262696e61727938808080800440004803500022
             1d0a046869766522016e2a016e3207696e7465676572380a400048035000222a
             0a0468697665220269762a0269763216696e74657276616c2064617920746f20
             7365636f6e6448035000221a0a04686976652201742a0174320474696d653803
             400048035000",
        );
        assert_eq!(hex_of(&actual), hex_of(&expected));
    }

    #[test]
    fn 実測した_describe_の_metadata_と同じバイト列になる() {
        // 採取元: run-20260917-175312/describe.metadata.bytes、2026-09-17 実測（152 バイト）。
        // DESCRIBE の field 1 は QueryExecutionId（UUID）。
        let columns = vec![
            column("col_name", "string", 0, 0, false),
            column("data_type", "string", 0, 0, false),
            column("comment", "string", 0, 0, false),
        ];

        let actual = to_metadata("6f0ab452-01a7-4d24-9128-216ba996b760", None, None, &columns);

        let expected = hex(
            "0a2436663061623435322d303161372d346432342d393132382d323136626139
             39366237363022240a04686976652208636f6c5f6e616d652a08636f6c5f6e61
             6d653206737472696e67480322260a04686976652209646174615f747970652a
             09646174615f747970653206737472696e67480322220a04686976652207636f
             6d6d656e742a07636f6d6d656e743206737472696e674803",
        );
        assert_eq!(hex_of(&actual), hex_of(&expected));
    }

    #[test]
    fn 実測した_update_の_metadata_と同じバイト列になる() {
        // 採取元: run-20260917-175312/update.metadata.bytes、2026-09-17 実測（75 バイト）。
        let columns = vec![column("rows", "bigint", 19, 0, false)];

        let actual = to_metadata(
            "20260917_085915_00133_pqi84",
            Some("UPDATE"),
            Some(2),
            &columns,
        );

        let expected = hex(
            "0a1b32303236303931375f3038353931355f30303133335f7071693834120655
             5044415445180222220a04686976652204726f77732a04726f77733206626967
             696e743813400048035000",
        );
        assert_eq!(hex_of(&actual), hex_of(&expected));
    }

    #[test]
    fn 実測した_0_行の_select_の_metadata_と同じバイト列になる() {
        // 採取元: run-20260917-175312/select-empty.metadata.bytes、2026-09-17 実測（60 バイト）。
        let columns = vec![column("i", "integer", 10, 0, false)];

        let actual = to_metadata("20260917_085516_00349_2tzvk", None, None, &columns);

        let expected = hex(
            "0a1b32303236303931375f3038353531365f30303334395f32747a766b221d0a
             04686976652201692a01693207696e7465676572380a400048035000",
        );
        assert_eq!(hex_of(&actual), hex_of(&expected));
    }

    #[test]
    fn 未実測の型は同じ系統の型と同じフィールドを出す() {
        // 本物では未実測の 2 つの型（docs/caveats.md の Result files and `.metadata` に「同じ系統の型と同じに書く」と書いてある）。
        // 期待値は手計算。timestamp with time zone は timestamp と同じく 7 / 8 / 10 を出し、
        // interval year to month は interval day to second と同じく 10 だけを出す。
        let columns = vec![
            column("ts", "timestamp with time zone", 3, 0, false),
            column("iv", "interval year to month", 0, 0, false),
        ];

        let actual = to_metadata("q1", None, None, &columns);

        // `timestamp with time zone` は 24 バイト（0x18）なので列 message は
        // 6 + 4 + 4 + 26 + 2 + 2 + 2 + 2 = 48 = 0x30。
        // `interval year to month` は 22 バイト（0x16）で 6 + 4 + 4 + 24 + 2 + 2 = 42 = 0x2a
        // （実測した `interval day to second` の列と同じ長さ・同じ形）。
        let expected = hex("0a02 7131
             2230
               0a04 68697665
               2202 7473
               2a02 7473
               3218 74696d657374616d7020776974682074696d65207a6f6e65
               3803 4000 4803 5000
             222a
               0a04 68697665
               2202 6976
               2a02 6976
               3216 696e74657276616c207965617220746f206d6f6e7468
               4803 5000");
        assert_eq!(hex_of(&actual), hex_of(&expected));
    }

    #[test]
    fn 更新件数が_0_でも_field_3_を書く() {
        // 0 件の更新（`DELETE ... WHERE false`）は本物で未実測。docs/caveats.md の Result files and `.metadata` に書いた
        // 「athena-local は 0 を書く」という契約を固定する（proto3 の既定値の省略はしない）。
        let columns = vec![column("rows", "bigint", 19, 0, false)];

        let actual = to_metadata("q1", Some("DELETE"), Some(0), &columns);

        // 期待値は手計算。field 2 は `DELETE` の 6 バイト、field 3 は 0 でも 18 00 を書く。
        // 列 `rows bigint` は 6 + 6 + 6 + 8 + 2 + 2 + 2 + 2 = 34 = 0x22。
        let expected = hex("0a02 7131
             1206 44454c455445
             1800
             2222
               0a04 68697665
               2204 726f7773
               2a04 726f7773
               3206 626967696e74
               3813 4000 4803 5000");
        assert_eq!(hex_of(&actual), hex_of(&expected));
    }

    #[test]
    fn 列名の長さは文字数ではなくバイト数で数える() {
        // 期待値は手計算。`日本語` は UTF-8 で 9 バイト（e697a5 e69cac e8aa9e）なので長さ前置は 09。
        // 列 message = CatalogName 6 + Name 11 + Label 11 + Type 9 + 7 の 2 + 8 の 2 + 9 の 2
        // + 10 の 2 = 45 = 0x2d。top は field 1（0a 02 "q1"）+ field 4（22 2d ...）。
        let columns = vec![column("日本語", "integer", 10, 0, false)];

        let actual = to_metadata("q1", None, None, &columns);

        let expected = hex("0a02 7131
             222d
               0a04 68697665
               2209 e697a5e69cace8aa9e
               2a09 e697a5e69cace8aa9e
               3207 696e7465676572
               380a 4000 4803 5000");
        assert_eq!(hex_of(&actual), hex_of(&expected));
    }

    #[test]
    fn 長い列名では長さの_varint_が_2_バイトになる() {
        // 期待値は手計算。130 バイトの名前の長さ前置は 82 01（130 = 0x82 | 0x80 の下位 7 ビット + 1）。
        // 列 message = CatalogName 6 + Name (1 + 2 + 130) + Label (1 + 2 + 130) + Type 9
        // + 7 の 2 + 8 の 2 + 9 の 2 + 10 の 2 = 289 で、長さ前置も 2 バイトの a1 02 になる。
        let name = "a".repeat(130);
        let columns = vec![column(&name, "integer", 10, 0, false)];

        let actual = to_metadata("q1", None, None, &columns);

        let body = "61".repeat(130);
        let expected = hex(&format!(
            "0a02 7131
             22a102
               0a04 68697665
               228201 {body}
               2a8201 {body}
               3207 696e7465676572
               380a 4000 4803 5000"
        ));
        assert_eq!(hex_of(&actual), hex_of(&expected));
    }
}
