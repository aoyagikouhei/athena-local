//! 構文チェックの後・前の判定（本物の Hive のパーサがブロックコメントで返す ParseException を FAILED にする。
//! #244）のうち、ALTER TABLE（ADD COLUMNS・DROP COLUMN・RENAME TO）の結合テスト。`tests/comment_parse_error.rs`
//! から切り出したもの（挙動を変えない移動。#257）。

mod common;

use common::Harness;
use serde_json::{Value, json};

const DEFAULT_CATALOG: &str = "default_catalog";
const DEFAULT_SCHEMA: &str = "default_schema";

fn select_response() -> Value {
    json!({ "columns": [{ "name": "n", "type": "bigint" }], "data": [[1]] })
}

/// 形式と存在を 1 つにまとめた問い合わせ（`src/operation/table_format.rs` の `probe_sql` と同じ形。
/// tests/comment_parse_error.rs の写し。#257 フェーズ 0 の一致台帳）。
fn probe_sql(catalog: &str, schema: &str, table: &str) -> String {
    format!(
        "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = '{catalog}'), (SELECT table_type FROM system.jdbc.tables WHERE table_cat = '{catalog}' AND table_schem = '{schema}' AND table_name = '{table}')"
    )
}

fn probe_response(connector_name: &str, table_type: &str) -> Value {
    json!({
        "columns": [
            { "name": "_col0", "type": "varchar" },
            { "name": "_col1", "type": "varchar" }
        ],
        "data": [[connector_name, table_type]]
    })
}

/// 対象が存在しない（カタログはあるが `table_type` が null）応答（tests/comment_parse_error.rs の写し）。
fn probe_response_missing() -> Value {
    json!({
        "columns": [
            { "name": "_col0", "type": "varchar" },
            { "name": "_col1", "type": "varchar" }
        ],
        "data": [["hive", null]]
    })
}

#[tokio::test]
async fn alter_table_rename_to_のブロックコメントは_hive_無い表で本物どおり_failed_になる() {
    const REASON: &str = "FAILED: ParseException line 1:0 cannot recognize input near 'ALTER' '/' '*' in alter statement";
    const MESSAGE: &str = "Query type not supported by DDL engine.";
    for (name, response) in [
        ("t", probe_response("hive", "TABLE")),
        ("nope", probe_response_missing()),
    ] {
        let sql = format!("ALTER /* c */ TABLE {name} RENAME TO u");
        let harness = Harness::builder(select_response())
            .route(&probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, name), response)
            .start()
            .await;

        let execution =
            harness.run_query(json!({ "QueryString": sql })).await["QueryExecution"].clone();

        assert_eq!(
            execution["Status"]["State"], "FAILED",
            "{name}: {execution}"
        );
        assert_eq!(execution["Status"]["StateChangeReason"], REASON, "{name}");
        assert_eq!(
            execution["Status"]["AthenaError"]["ErrorCategory"], 2,
            "{name}"
        );
        assert_eq!(
            execution["Status"]["AthenaError"]["ErrorType"], 1006,
            "{name}"
        );
        assert_eq!(
            execution["Status"]["AthenaError"]["ErrorMessage"], MESSAGE,
            "{name}"
        );
        assert!(
            harness.trino_sqls().iter().all(|s| !s.starts_with("ALTER")),
            "{name}: Trino に ALTER の文を送らない"
        );
    }
}

#[tokio::test]
async fn alter_table_drop_column_のブロックコメントは_hive_なら本物どおり_failed_になる() {
    let sql = "ALTER /* c */ TABLE t DROP COLUMN n";
    let harness = Harness::builder(select_response())
        .route(
            &probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, "t"),
            probe_response("hive", "TABLE"),
        )
        .start()
        .await;

    let execution =
        harness.run_query(json!({ "QueryString": sql })).await["QueryExecution"].clone();

    assert_eq!(execution["Status"]["State"], "FAILED", "{execution}");
    assert_eq!(
        execution["Status"]["StateChangeReason"],
        "FAILED: ParseException line 1:0 cannot recognize input near 'ALTER' '/' '*' in alter statement"
    );
    assert_eq!(execution["Status"]["AthenaError"]["ErrorCategory"], 2);
    assert_eq!(execution["Status"]["AthenaError"]["ErrorType"], 1006);
    assert_eq!(
        execution["Status"]["AthenaError"]["ErrorMessage"],
        "line 1:28: mismatched input 'COLUMN' expecting 'PARTITION'"
    );
}

#[tokio::test]
async fn alter_table_のブロックコメントは_iceberg_表なら成功して_trino_に送る() {
    for sql in [
        "ALTER /* c */ TABLE t RENAME TO u",
        "ALTER /* c */ TABLE t DROP COLUMN n",
    ] {
        let harness = Harness::builder(select_response())
            .route(
                &probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, "t"),
                probe_response("iceberg", "TABLE"),
            )
            .start()
            .await;

        let execution =
            harness.run_query(json!({ "QueryString": sql })).await["QueryExecution"].clone();

        assert_eq!(
            execution["Status"]["State"], "SUCCEEDED",
            "{sql}: {execution}"
        );
        assert!(
            harness.trino_sqls().iter().any(|s| s == sql),
            "{sql}: Iceberg 表なら Trino に送る"
        );
    }
}

#[tokio::test]
async fn alter_table_add_columns_複数形_のブロックコメントは_hive_無い表で本物どおり_failed_になり構文チェックへ進まない()
 {
    const REASON: &str = "FAILED: ParseException line 1:0 cannot recognize input near 'ALTER' '/' '*' in alter statement";
    for (name, response) in [
        ("t", probe_response("hive", "TABLE")),
        ("nope", probe_response_missing()),
    ] {
        let sql = format!("ALTER /* c */ TABLE {name} ADD COLUMNS (c int)");
        let harness = Harness::builder(select_response())
            .route(&probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, name), response)
            .start()
            .await;

        let execution =
            harness.run_query(json!({ "QueryString": sql })).await["QueryExecution"].clone();

        assert_eq!(
            execution["Status"]["State"], "FAILED",
            "{name}: {execution}"
        );
        assert_eq!(execution["Status"]["StateChangeReason"], REASON, "{name}");
        assert_eq!(
            execution["Status"]["AthenaError"]["ErrorCategory"], 1,
            "{name}"
        );
        assert_eq!(
            execution["Status"]["AthenaError"]["ErrorType"], 1003,
            "{name}"
        );
        assert_eq!(execution["StatementType"], "DDL", "{name}");
        assert_eq!(
            execution["SubstatementType"], "ALTER_TABLE_ADD_COLUMN",
            "{name}"
        );

        assert!(
            !harness.syntax_checks().contains(&sql),
            "{name}: 構文チェックへ進まない: {:?}",
            harness.syntax_checks()
        );
    }
}

#[tokio::test]
async fn alter_table_add_columns_複数形_は_iceberg_表なら今までどおり構文チェックへ進む() {
    let sql = "ALTER /* c */ TABLE t ADD COLUMNS (c int)";
    let harness = Harness::builder(select_response())
        .route(
            &probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, "t"),
            probe_response("iceberg", "TABLE"),
        )
        .start()
        .await;

    harness
        .call("StartQueryExecution", json!({ "QueryString": sql }))
        .await;

    assert!(
        harness.syntax_checks().contains(&sql.to_string()),
        "Iceberg 表なら構文チェックへ進む: {:?}",
        harness.syntax_checks()
    );
}

#[tokio::test]
async fn alter_table_add_columns_複数形_はコメントが無ければ_probe_を投げずに構文チェックへ進む() {
    let sql = "ALTER TABLE t ADD COLUMNS (c int)";
    let harness = Harness::builder(select_response()).start().await;

    harness
        .call("StartQueryExecution", json!({ "QueryString": sql }))
        .await;

    assert!(
        harness.syntax_checks().contains(&sql.to_string()),
        "コメントが無ければ構文チェックへ進む: {:?}",
        harness.syntax_checks()
    );
    // 実行そのもの（今までどおり Trino に送る文）は数に入れない。probe（存在の確認）だけ送っていないことを見る。
    assert!(
        !harness
            .trino_sqls()
            .contains(&probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, "t")),
        "コメントが無ければ probe を投げない: {:?}",
        harness.trino_sqls()
    );
}

/// 本物は ALTER TABLE の名前の 1 部目の `awsdatacatalog.` を Context のカタログとして落とす（2026-09-26 実測 m33。
/// #242）。構文チェックの前の判定も、落とした後の名前（`db.t`）で表を確かめる。落とさずに `awsdatacatalog` を
/// Trino のカタログとして引くと、カタログが無いと判定して今までどおり構文エラーになってしまう（#244 の最終パス）。
#[tokio::test]
async fn alter_table_add_columns_複数形_のブロックコメントは名前の_awsdatacatalog_を落として表を確かめる()
 {
    let sql = "ALTER /* c */ TABLE awsdatacatalog.db.t ADD COLUMNS (c int)";
    let harness = Harness::builder(select_response())
        .catalog_map(&[("AwsDataCatalog", "hive")])
        .route(
            &probe_sql("hive", "db", "t"),
            probe_response("hive", "TABLE"),
        )
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": sql,
            "QueryExecutionContext": { "Catalog": "AwsDataCatalog", "Database": "other" }
        }))
        .await["QueryExecution"]
        .clone();

    assert_eq!(execution["Status"]["State"], "FAILED", "{execution}");
    assert_eq!(
        execution["Status"]["StateChangeReason"],
        "FAILED: ParseException line 1:0 cannot recognize input near 'ALTER' '/' '*' in alter statement"
    );
    assert!(
        !harness.syntax_checks().contains(&sql.to_string()),
        "構文チェックへ進まない: {:?}",
        harness.syntax_checks()
    );
}

/// g3: 名前と複数形 `ADD COLUMNS` の間のコメント（2026-09-27 実測。#257）は、Hive 表だけ本物どおり
/// FAILED になり、ビュー・無い表・Iceberg は今までどおり構文チェックへ進む（`hive_only` の印）。
#[tokio::test]
async fn alter_table_add_columns_複数形_は名前と_add_columns_の間のコメントで_hive_表だけ_failed_になる()
 {
    const REASON: &str = "FAILED: ParseException line 1:14 cannot recognize input near '/' '*' 'c' in alter table statement";
    let sql = "ALTER TABLE t /* c */ ADD COLUMNS (c int)";
    let harness = Harness::builder(select_response())
        .route(
            &probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, "t"),
            probe_response("hive", "TABLE"),
        )
        .start()
        .await;

    let execution =
        harness.run_query(json!({ "QueryString": sql })).await["QueryExecution"].clone();

    assert_eq!(execution["Status"]["State"], "FAILED", "{execution}");
    assert_eq!(execution["Status"]["StateChangeReason"], REASON);
    assert_eq!(execution["Status"]["AthenaError"]["ErrorCategory"], 1);
    assert_eq!(execution["Status"]["AthenaError"]["ErrorType"], 1003);
    assert!(
        !harness.syntax_checks().contains(&sql.to_string()),
        "構文チェックへ進まない: {:?}",
        harness.syntax_checks()
    );
}

#[tokio::test]
async fn alter_table_add_columns_複数形_は名前と_add_columns_の間のコメントでビュー_無い表_iceberg_なら今までどおり構文チェックへ進む()
 {
    let sql = "ALTER TABLE t /* c */ ADD COLUMNS (c int)";
    for response in [
        probe_response("hive", "VIEW"),
        probe_response_missing(),
        probe_response("iceberg", "TABLE"),
    ] {
        let harness = Harness::builder(select_response())
            .route(&probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, "t"), response)
            .start()
            .await;

        harness
            .call("StartQueryExecution", json!({ "QueryString": sql }))
            .await;

        assert!(
            harness.syntax_checks().contains(&sql.to_string()),
            "構文チェックへ進む: {:?}",
            harness.syntax_checks()
        );
    }
}

/// r1・r3: REPLACE COLUMNS・CHANGE COLUMN は ALTER の直後のコメントだけ本物どおり FAILED になる
/// （2026-09-27 実測。#257）。SubstatementType は ALTER_TABLE_REPLACE_COLUMN・ALTER_TABLE_CHANGE_COLUMN。
#[tokio::test]
async fn alter_table_replace_columns_と_change_column_は_alter_の直後のコメントで_failed_になる() {
    const REASON: &str = "FAILED: ParseException line 1:0 cannot recognize input near 'ALTER' '/' '*' in alter statement";
    const MESSAGE: &str = "Query type not supported by DDL engine.";
    for (sql, substatement_type) in [
        (
            "ALTER /* c */ TABLE t REPLACE COLUMNS (n int, s string)",
            "ALTER_TABLE_REPLACE_COLUMN",
        ),
        (
            "ALTER /* c */ TABLE t CHANGE COLUMN n n2 int",
            "ALTER_TABLE_CHANGE_COLUMN",
        ),
    ] {
        let harness = Harness::builder(select_response())
            .route(
                &probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, "t"),
                probe_response("hive", "TABLE"),
            )
            .start()
            .await;

        let execution =
            harness.run_query(json!({ "QueryString": sql })).await["QueryExecution"].clone();

        assert_eq!(execution["Status"]["State"], "FAILED", "{sql}: {execution}");
        assert_eq!(execution["Status"]["StateChangeReason"], REASON, "{sql}");
        assert_eq!(
            execution["Status"]["AthenaError"]["ErrorCategory"], 2,
            "{sql}"
        );
        assert_eq!(
            execution["Status"]["AthenaError"]["ErrorType"], 1006,
            "{sql}"
        );
        assert_eq!(
            execution["Status"]["AthenaError"]["ErrorMessage"], MESSAGE,
            "{sql}"
        );
        assert_eq!(execution["SubstatementType"], substatement_type, "{sql}");
        assert!(
            !harness.syntax_checks().contains(&sql.to_string()),
            "{sql}: 構文チェックへ進まない: {:?}",
            harness.syntax_checks()
        );
    }
}

/// pos1: ALTER の直後のコメント・無引用 3 部・1 部目 awsdatacatalog（大文字小文字によらない）の
/// DROP COLUMN は、Hive 表なら本物どおり受け取ったままの文（`awsdatacatalog.` を落とす前）で
/// ErrorMessage を作り、Query も受け取ったまま返す（2026-09-27 実測 pos1。#257）。StateChangeReason は
/// `drop_catalog` で落とした文で数えても変わらないので今までどおり。
#[tokio::test]
async fn alter_table_drop_column_の_awsdatacatalog_3_部_は_hive_表なら受け取ったままの文で_error_message_と_query_を返す()
 {
    let sql = "ALTER /* c */ TABLE awsdatacatalog.db.t DROP COLUMN n";
    let harness = Harness::builder(select_response())
        .catalog_map(&[("AwsDataCatalog", "hive")])
        .route(
            &probe_sql("hive", "db", "t"),
            probe_response("hive", "TABLE"),
        )
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": sql,
            "QueryExecutionContext": { "Catalog": "AwsDataCatalog", "Database": "other" }
        }))
        .await["QueryExecution"]
        .clone();

    assert_eq!(execution["Status"]["State"], "FAILED", "{execution}");
    assert_eq!(
        execution["Status"]["StateChangeReason"],
        "FAILED: ParseException line 1:0 cannot recognize input near 'ALTER' '/' '*' in alter statement"
    );
    assert_eq!(execution["Status"]["AthenaError"]["ErrorCategory"], 2);
    assert_eq!(execution["Status"]["AthenaError"]["ErrorType"], 1006);
    assert_eq!(
        execution["Status"]["AthenaError"]["ErrorMessage"],
        "line 1:38: no viable alternative at input 'ALTER /* c */ TABLE awsdatacatalog.db.'"
    );
    assert_eq!(
        execution["Query"], sql,
        "Query は受け取ったまま（awsdatacatalog. を落とさない）"
    );
}

/// ビュー・無い表は pos1 の対象外（未実測）で今までどおり、`drop_catalog` で落とした文で ErrorMessage・Query
/// を作る。
#[tokio::test]
async fn alter_table_drop_column_の_awsdatacatalog_3_部_はビュー_無い表なら今までどおり落とした文になる()
 {
    for (name, response, expected_message) in [
        (
            "v",
            probe_response("hive", "VIEW"),
            "line 1:31: mismatched input 'COLUMN' expecting 'PARTITION'",
        ),
        (
            "nope",
            probe_response_missing(),
            "line 1:34: mismatched input 'COLUMN' expecting 'PARTITION'",
        ),
    ] {
        let sql = format!("ALTER /* c */ TABLE awsdatacatalog.db.{name} DROP COLUMN n");
        let dropped = format!("ALTER /* c */ TABLE db.{name} DROP COLUMN n");
        let harness = Harness::builder(select_response())
            .catalog_map(&[("AwsDataCatalog", "hive")])
            .route(&probe_sql("hive", "db", name), response)
            .start()
            .await;

        let execution = harness
            .run_query(json!({
                "QueryString": sql,
                "QueryExecutionContext": { "Catalog": "AwsDataCatalog", "Database": "other" }
            }))
            .await["QueryExecution"]
            .clone();

        assert_eq!(
            execution["Status"]["State"], "FAILED",
            "{name}: {execution}"
        );
        assert_eq!(
            execution["Status"]["AthenaError"]["ErrorMessage"], expected_message,
            "{name}"
        );
        assert_eq!(
            execution["Query"], dropped,
            "{name}: pos1 の対象外は今までどおり落とした文"
        );
    }
}

/// RENAME TO は DROP COLUMN でないので pos1 の対象外（今までどおり落とした文のまま）。
#[tokio::test]
async fn alter_table_rename_to_の_awsdatacatalog_3_部_は_pos1_の対象外で今までどおり落とした文になる()
 {
    let sql = "ALTER /* c */ TABLE awsdatacatalog.db.t RENAME TO u";
    let harness = Harness::builder(select_response())
        .catalog_map(&[("AwsDataCatalog", "hive")])
        .route(
            &probe_sql("hive", "db", "t"),
            probe_response("hive", "TABLE"),
        )
        .start()
        .await;

    let execution = harness
        .run_query(json!({
            "QueryString": sql,
            "QueryExecutionContext": { "Catalog": "AwsDataCatalog", "Database": "other" }
        }))
        .await["QueryExecution"]
        .clone();

    assert_eq!(execution["Status"]["State"], "FAILED", "{execution}");
    assert_eq!(
        execution["Status"]["AthenaError"]["ErrorMessage"],
        "Query type not supported by DDL engine."
    );
    assert_eq!(
        execution["Query"], "ALTER /* c */ TABLE db.t RENAME TO u",
        "RENAME TO は pos1 の対象外で今までどおり落とした文"
    );
}

/// Context の Catalog がほかのカタログ（`drop_catalog` が落とさない）ときは、そもそも `awsdatacatalog.` が
/// 落ちないので pos1 は関係せず、Query は受け取ったまま（drop_catalog が触らないだけ。今までどおり）。
#[tokio::test]
async fn alter_table_drop_column_の_awsdatacatalog_3_部_は_context_の_catalog_がほかなら今までどおりquery_は受け取ったまま()
 {
    let sql = "ALTER /* c */ TABLE awsdatacatalog.db.t DROP COLUMN n";
    let harness = Harness::builder(select_response()).start().await;

    let execution = harness
        .run_query(json!({
            "QueryString": sql,
            "QueryExecutionContext": { "Catalog": "other", "Database": "db" }
        }))
        .await["QueryExecution"]
        .clone();

    assert_eq!(
        execution["Query"], sql,
        "drop_catalog がほかのカタログでは落とさないので Query は受け取ったまま"
    );
}

/// 先頭・TABLE の後のコメントは未実測なので None（今までどおり構文チェックへ進む。Trino に構文が無い
/// ので、実際にはこの先で構文エラーになる想定だが、ここでは判定に介入しないことだけを確かめる）。
#[tokio::test]
async fn alter_table_replace_columns_と_change_column_は先頭_table_の後のコメントなら今までどおり構文チェックへ進む()
 {
    for sql in [
        "/* c */ ALTER TABLE t REPLACE COLUMNS (n int, s string)",
        "ALTER TABLE /* c */ t REPLACE COLUMNS (n int, s string)",
        "/* c */ ALTER TABLE t CHANGE COLUMN n n2 int",
        "ALTER TABLE /* c */ t CHANGE COLUMN n n2 int",
    ] {
        // 対象を Hive 表として返し、ALTER の直後のコメント（r1・r3）なら失敗させる状態でも、先頭・TABLE の後の
        // コメントは判定せずに構文チェックへ進むことを確かめる。
        let harness = Harness::builder(select_response())
            .route(
                &probe_sql(DEFAULT_CATALOG, DEFAULT_SCHEMA, "t"),
                probe_response("hive", "TABLE"),
            )
            .start()
            .await;

        harness
            .call("StartQueryExecution", json!({ "QueryString": sql }))
            .await;

        assert!(
            harness.syntax_checks().contains(&sql.to_string()),
            "{sql}: 構文チェックへ進む: {:?}",
            harness.syntax_checks()
        );
    }
}
