//! FAILED になったクエリの理由。StateChangeReason と、GetQueryExecution の Status.AthenaError に使う。
//! Trino のエラー名と ErrorType の対応は、2026-09-14 に本番 Athena で実測したもの。

use crate::trino::QueryError;

mod describe;

/// AthenaError.ErrorCategory。
pub const SYSTEM: i32 = 1;
pub const USER: i32 = 2;

/// ALTER TABLE の RENAME TO（と #244 のブロックコメントの失敗）に本物が返す AthenaError.ErrorMessage（2026-09-21 実測）。
pub const DDL_ENGINE_UNSUPPORTED: &str = "Query type not supported by DDL engine.";

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Failure {
    /// StateChangeReason。
    pub reason: String,
    /// AthenaError.ErrorMessage。`None` は `reason` と同じ（本物は StateChangeReason と
    /// AthenaError.ErrorMessage に同じ文字列を入れるが、ALTER TABLE の RENAME TO・DROP COLUMN の
    /// ブロックコメントの失敗だけ別（2026-09-26 実測。#244））。
    pub error_message: Option<String>,
    pub category: i32,
    pub error_type: i32,
    pub retryable: bool,
}

impl Failure {
    /// Trino が返したエラー、または Trino に届かなかったときのエラー。
    pub fn from_query_error(error: &QueryError) -> Self {
        let reason = error.to_string();
        let Some(name) = error.name.as_deref() else {
            // Trino に届かない・応答が読めないなど athena-local 側の失敗。本物に対応する事象は無いので
            // 「Internal service error」を当て、再試行で通りうるものとして返す。
            return Self {
                reason,
                error_message: None,
                category: SYSTEM,
                error_type: 100,
                retryable: true,
            };
        };

        // Trino は必ず errorType を付ける。無ければユーザーのエラーとして扱う。
        let category = match error.error_type.as_deref() {
            None | Some("USER_ERROR") => USER,
            Some(_) => SYSTEM,
        };
        let error_type = measured_error_type(name).unwrap_or(match category {
            // 実測していない名前は、Athena のエラー一覧の汎用の番号を当てる。
            USER => 1000, // User error
            _ => 200,     // Query engine had an internal error
        });

        Self {
            reason,
            error_message: None,
            category,
            error_type,
            // 実測したユーザーのエラーはすべて false。システムのエラーは実測していないので同じく false。
            retryable: false,
        }
    }

    /// S3 Tables の Context で、1 部目が `awsdatacatalog` の類の `CREATE TABLE` の名前空間が無いときに本物が返した
    /// 固定の文言（表の名前は入らない。2026-09-26 実測 j2・j3・j9。#227）。
    pub fn cannot_find_table() -> Self {
        Self {
            reason: "Cannot find or access the specified table".to_string(),
            error_message: None,
            category: USER,
            error_type: 1100,
            retryable: false,
        }
    }

    /// S3 Tables の Context と既定の Context の CTAS で、1 部目が `awsdatacatalog` の類の名前の 2 部目（Glue の DB）が
    /// 無いときに本物が返した文言（2026-09-26 実測 j13。#232。2026-09-27 実測 r4〜r8c。#251）。`database` は呼び出し側が
    /// 小文字にした名前（本物は書いたとおりでなく小文字で返した。r5・r8a）。`location` は結果の置き場所
    /// （`<OutputLocation>tables/<id>`）。
    pub fn database_not_found(database: &str, location: &str) -> Self {
        Self {
            reason: format!("Database {database} not found. Please check your query"),
            error_message: None,
            category: USER,
            error_type: 1301,
            retryable: false,
        }
        .with_ctas_suffix(location)
    }

    /// S3 Tables の Context の CTAS で、書き込む先の名前空間が無いときに本物が返した文言（2026-09-27 実測 d2・d4・f1〜f5・
    /// f8〜f10・f12。#273）。本物の内部名 `catalog:<アカウント ID>:<Catalog>$schema:<名前空間>` のアカウント ID は
    /// athena-local に無いので `000000000000` にする。`catalog` は Context の Catalog（受け取ったまま。本物は小文字の
    /// Catalog でしか測っていない）、`namespace` は小文字の名前空間（本物は書いたとおりでなく小文字で返した。f4）。
    pub fn s3_tables_schema_not_found(catalog: &str, namespace: &str, location: &str) -> Self {
        Self {
            reason: format!(
                "NOT_FOUND: Schema catalog:000000000000:{catalog}$schema:{namespace} not found."
            ),
            error_message: None,
            category: USER,
            error_type: 1300,
            retryable: false,
        }
        .with_ctas_suffix(location)
    }

    /// エンジンで失敗した CTAS の理由の後ろに本物が付けた文（2026-09-27 実測 p・w・t・f 群。#272）。`location` は結果の
    /// 置き場所（`<OutputLocation>tables/<id>`）。
    pub fn with_ctas_suffix(self, location: &str) -> Self {
        self.with_sentence(&format!(
            "You may need to manually clean the data at location '{location}' before retrying. \
             Athena will not delete data in your account."
        ))
    }

    /// エンジンで失敗した INSERT の理由の後ろに本物が付けた文（2026-09-25 実測 #217、2026-09-27 実測 i1・i2。#272）。
    /// `manifest` は `<OutputLocation><id>-manifest.csv`。
    pub fn with_insert_suffix(self, manifest: &str) -> Self {
        self.with_sentence(&format!(
            "If a data manifest file was generated at '{manifest}', you may need to manually clean the data \
             from locations specified in the manifest. Athena will not delete data in your account."
        ))
    }

    /// 本物の理由は `<エンジンの文言>. <文>` の形で、エンジンの文言が `.` で終わらなければ `.` を足していた（Trino の文言は
    /// `.` で終わらない。`.` で終わる文言は測っていないので重ねない）。
    fn with_sentence(mut self, sentence: &str) -> Self {
        if !self.reason.ends_with('.') {
            self.reason.push('.');
        }
        self.reason.push(' ');
        self.reason.push_str(sentence);
        self
    }

    /// MSCK REPAIR TABLE の対象が Iceberg 表のときに本物が返した固定の文言（ブロックコメントの有無・位置に
    /// よらず。`.txt` も `.metadata` も置かない。2026-09-26 実測 m1〜m4。#244）。
    pub fn msck_iceberg() -> Self {
        Self {
            reason: "Query type not supported by Athena Iceberg at this time".to_string(),
            error_message: None,
            category: USER,
            error_type: 1200,
            retryable: false,
        }
    }

    /// S3 Tables の Context の LOCATION の無い `CREATE TABLE` の句（`STORED AS/BY`・`ROW FORMAT`・`CLUSTERED BY`）に本物が
    /// 返した固定の文言（`.txt` も `.metadata` も置かない。2026-09-26 実測 n21・vc4・z16、2026-09-27 実測 s15。#248・#270）。
    pub fn iceberg_does_not_allow(clause: &str) -> Self {
        Self::iceberg_create_table(
            format!("Iceberg create table statement does not allow {clause}"),
            1200,
        )
    }

    /// 同じ Context の型付きの `PARTITIONED BY (p int)`（2026-09-26 実測 z15、2026-09-27 実測 cl1・pa4。#270）。
    pub fn invalid_partitioned_by() -> Self {
        Self::iceberg_create_table(
            "Invalid PARTITIONED BY clause in Iceberg create table statement".to_string(),
            1006,
        )
    }

    /// 同じ Context の列の並びの無い文（2026-09-27 実測 pn6。#270）。
    pub fn at_least_one_column() -> Self {
        Self::iceberg_create_table(
            "At least one column is required for Iceberg create table statement".to_string(),
            1006,
        )
    }

    /// 同じ Context の未知のキーの `TBLPROPERTIES`。キーは書いた綴りのまま（2026-09-26 実測 z17、2026-09-27 実測 pn3・
    /// tp4・tp7。#270）。
    pub fn unsupported_table_property_key(key: &str) -> Self {
        Self::iceberg_create_table(format!("Unsupported table property key: {key}"), 1200)
    }

    fn iceberg_create_table(reason: String, error_type: i32) -> Self {
        Self {
            reason,
            error_message: None,
            category: USER,
            error_type,
            retryable: false,
        }
    }

    /// コメント無しの `ALTER TABLE <Hive 表> RENAME TO` に本物が返した Glue の失敗（2026-09-21 実測 #43 b1、
    /// 2026-09-25 実測 #217 n22）。Request ID は本物では毎回違う UUID なので、毎回新しく作る（#256）。
    pub fn rename_hive_table() -> Self {
        Self {
            reason: format!(
                "FAILED: Execution Error, return code 1 from org.apache.hadoop.hive.ql.exec.DDLTask. Unable to alter table. Unable to change partition or table: com.amazonaws.services.datacatalog.model.InvalidInputException: Table cannot be renamed (Service: AmazonDataCatalog; Status Code: 400; Error Code: InvalidInputException; Request ID: {}; Proxy: null)",
                uuid::Uuid::new_v4()
            ),
            error_message: Some(DDL_ENGINE_UNSUPPORTED.to_string()),
            category: USER,
            error_type: 1006,
            retryable: false,
        }
    }

    /// コメント無しの `ALTER TABLE <無い表> RENAME TO` に本物が返した失敗（2026-09-25 実測 #204 alt-rename-u。#256）。
    /// 名前は `<DB>.<表>`（実測は小文字の名前だけ）。
    pub fn rename_table_not_found(database: &str, table: &str) -> Self {
        Self {
            reason: format!(
                "FAILED: SemanticException [Error 10001]: Table not found {database}.{table}"
            ),
            error_message: Some(DDL_ENGINE_UNSUPPORTED.to_string()),
            category: USER,
            error_type: 1006,
            retryable: false,
        }
    }

    /// 結果 CSV を置けなかった。本物は書き込みで FAILED にならないので、一覧の
    /// 「Failed to write query results to Amazon S3」を当て、再試行で通りうるものとして返す。
    pub fn result_write(reason: String) -> Self {
        Self {
            reason,
            error_message: None,
            category: SYSTEM,
            error_type: 401,
            retryable: true,
        }
    }
}

/// 実測した Trino のエラー名 → ErrorType。
fn measured_error_type(name: &str) -> Option<i32> {
    Some(match name {
        "DIVISION_BY_ZERO" => 1001,
        "TYPE_MISMATCH" => 1002,
        // 本物は構文エラーを StartQueryExecution で弾くので FAILED にはならない。
        // 一覧の「Syntax error」で、列が見つからないときと同じ番号。
        "SYNTAX_ERROR" | "COLUMN_NOT_FOUND" => 1006,
        // 本物は Context の Catalog が無いとき、表を読む SELECT・EXPLAIN をこの番号で失敗させた（2026-09-25 実測。#214）。
        "CATALOG_NOT_FOUND" => 1006,
        "INVALID_CAST_ARGUMENT" | "NUMERIC_VALUE_OUT_OF_RANGE" | "INVALID_PARAMETER_USAGE" => 1100,
        "INVALID_FUNCTION_ARGUMENT" => 1106,
        // 本物は Iceberg のテーブルを二重に作ると 1110 を返した（メッセージは Athena 独自）。
        "TABLE_ALREADY_EXISTS" => 1110,
        "NOT_SUPPORTED" => 1200,
        "TABLE_NOT_FOUND" | "SCHEMA_NOT_FOUND" => 1301,
        "FUNCTION_NOT_FOUND" => 1303,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn trino_error(name: &str, error_type: &str) -> QueryError {
        QueryError {
            name: Some(name.to_string()),
            message: "message".to_string(),
            error_type: Some(error_type.to_string()),
        }
    }

    #[test]
    fn 実測したエラー名はその_error_type_になる() {
        for (name, expected) in [
            ("COLUMN_NOT_FOUND", 1006),
            ("CATALOG_NOT_FOUND", 1006),
            ("TABLE_NOT_FOUND", 1301),
            ("SCHEMA_NOT_FOUND", 1301),
            ("FUNCTION_NOT_FOUND", 1303),
            ("TYPE_MISMATCH", 1002),
            ("INVALID_FUNCTION_ARGUMENT", 1106),
            ("DIVISION_BY_ZERO", 1001),
            ("INVALID_CAST_ARGUMENT", 1100),
            ("NUMERIC_VALUE_OUT_OF_RANGE", 1100),
            ("INVALID_PARAMETER_USAGE", 1100),
            ("NOT_SUPPORTED", 1200),
            ("TABLE_ALREADY_EXISTS", 1110),
        ] {
            let failure = Failure::from_query_error(&trino_error(name, "USER_ERROR"));
            assert_eq!(
                (failure.category, failure.error_type, failure.retryable),
                (USER, expected, false),
                "{name}"
            );
        }
    }

    #[test]
    fn 理由は_error_name_と_message_をつないだもの() {
        let failure = Failure::from_query_error(&trino_error("TABLE_NOT_FOUND", "USER_ERROR"));
        assert_eq!(failure.reason, "TABLE_NOT_FOUND: message");
    }

    #[test]
    fn 実測していない名前は汎用の番号になる() {
        let user = Failure::from_query_error(&trino_error("MISSING_COLUMN_ALIASES", "USER_ERROR"));
        assert_eq!(
            (user.category, user.error_type, user.retryable),
            (USER, 1000, false)
        );

        let system =
            Failure::from_query_error(&trino_error("GENERIC_INTERNAL_ERROR", "INTERNAL_ERROR"));
        assert_eq!(
            (system.category, system.error_type, system.retryable),
            (SYSTEM, 200, false)
        );
    }

    #[test]
    fn athena_local_側の失敗はシステムのエラーで再試行できる() {
        let unreachable = Failure::from_query_error(&QueryError {
            name: None,
            message: "trino への接続に失敗しました".to_string(),
            error_type: None,
        });
        assert_eq!(
            (
                unreachable.category,
                unreachable.error_type,
                unreachable.retryable
            ),
            (SYSTEM, 100, true)
        );

        let write = Failure::result_write("書けませんでした".to_string());
        assert_eq!(
            (write.category, write.error_type, write.retryable),
            (SYSTEM, 401, true)
        );
        assert_eq!(write.reason, "書けませんでした");
    }

    fn engine_failure(message: &str) -> Failure {
        Failure::from_query_error(&QueryError {
            name: Some("TABLE_NOT_FOUND".to_string()),
            message: message.to_string(),
            error_type: Some("USER_ERROR".to_string()),
        })
    }

    #[test]
    fn ctas_の接尾辞は文言の末尾に句点を足してから付ける() {
        let failure = engine_failure("line 6:3: Table 't' does not exist")
            .with_ctas_suffix("s3://b/p/tables/id");
        assert_eq!(
            failure.reason,
            "TABLE_NOT_FOUND: line 6:3: Table 't' does not exist. You may need to manually clean the data \
             at location 's3://b/p/tables/id' before retrying. Athena will not delete data in your account."
        );
        assert_eq!(failure.error_message, None);
        assert_eq!((failure.category, failure.error_type), (USER, 1301));
    }

    #[test]
    fn insert_の接尾辞は_manifest_の場所を付ける() {
        let failure = engine_failure("line 1:65: Column 'x' cannot be resolved")
            .with_insert_suffix("s3://b/p/id-manifest.csv");
        assert_eq!(
            failure.reason,
            "TABLE_NOT_FOUND: line 1:65: Column 'x' cannot be resolved. If a data manifest file was generated \
             at 's3://b/p/id-manifest.csv', you may need to manually clean the data from locations specified \
             in the manifest. Athena will not delete data in your account."
        );
    }

    #[test]
    fn 文言が句点で終わっていれば句点を重ねない() {
        let failure = engine_failure("done.").with_ctas_suffix("s3://b/tables/id");
        assert!(
            failure
                .reason
                .starts_with("TABLE_NOT_FOUND: done. You may need"),
            "{}",
            failure.reason
        );
        let missing = Failure::database_not_found("db", "s3://b/tables/id");
        assert!(
            missing
                .reason
                .starts_with("Database db not found. Please check your query. You may need"),
            "{}",
            missing.reason
        );
    }
}
