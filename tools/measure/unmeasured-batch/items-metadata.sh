# shellcheck shell=bash
# issue #113: .metadata 関連の未実測 4 項目（m1, m2, m3, m5）。単独では実行しない。
# run.sh が source して item_m1 などを呼ぶ。m4（列の field 2/3）は metadata.md:33 で
# 観測済み（実テーブルの SELECT でも無い）としてバッチから外してある（issue-notes 参照）。
#
# m2・m3 は Iceberg の CTAS/DML を「測る文」として local でも成功させたいので、
# フィクスチャの作り方だけ TARGET で分ける（測る文自体は同じ SQL）。m5 は Athena の
# TBLPROPERTIES('table_type'='ICEBERG') 綴りが Trino の Iceberg カタログには無いプロパティなので、
# r1・r2・x1 と同じく「local では FAILED が期待どおり」として declare_expectation する。

# m1: timestamp with time zone・time with time zone・interval year to month・uuid・ipaddress の
# field 7/8/10 の有無。対照の timestamp・time・interval day to second も同じ SELECT に入れる。
item_m1() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  local sql="SELECT
    TIMESTAMP '2026-09-17 12:34:56.789' AS ts,
    TIMESTAMP '2026-09-17 12:34:56.789 UTC' AS tstz,
    TIME '12:34:56.789' AS t,
    TIME '12:34:56.789+00:00' AS ttz,
    INTERVAL '1' DAY AS iv_ds,
    INTERVAL '1' YEAR AS iv_ym,
    CAST('12151fd2-7586-11e9-8f9e-2a86e4085a59' AS UUID) AS u,
    CAST('10.0.0.1' AS IPADDRESS) AS ip"
  run_stmt "$dir" m1-types "$sql" "$TCAT_GENERIC" "$TDB"
}

# m2: 0 行の UPDATE/DELETE/MERGE（Iceberg）の field 3。1 行が対象になる対照も添える。
item_m2() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  local name="${PROBE_PREFIX}_m2"
  if probe_prefix_exists "$dir" "$TCAT_ICEBERG" "$TDB" "$name"; then
    skip_item "$id" all "同名のテーブルが既にある"
    return 0
  fi
  local t="${TDB}.${name}" create_sql
  if [ "$TARGET" = local ]; then
    create_sql="CREATE TABLE $t AS SELECT 1 AS n"
  else
    create_sql="CREATE TABLE $t WITH (table_type = 'ICEBERG', location = '${OUTPUT}tables-probe-113-m2/', is_external = false) AS SELECT 1 AS n"
  fi
  run_stmt "$dir" m2-fixture "$create_sql" "$TCAT_ICEBERG" "$TDB"
  if [ $? -ne 0 ]; then
    skip_item "$id" statements "フィクスチャの Iceberg テーブルを作れなかった"
    return 0
  fi

  run_stmt "$dir" m2-update-zero "UPDATE $t SET n = 2 WHERE false" "$TCAT_ICEBERG" "$TDB"
  run_stmt "$dir" m2-update-one "UPDATE $t SET n = 2 WHERE n = 1" "$TCAT_ICEBERG" "$TDB"
  run_stmt "$dir" m2-delete-zero "DELETE FROM $t WHERE false" "$TCAT_ICEBERG" "$TDB"
  run_stmt "$dir" m2-reset "UPDATE $t SET n = 1 WHERE n = 2" "$TCAT_ICEBERG" "$TDB"
  run_stmt "$dir" m2-delete-one "DELETE FROM $t WHERE n = 1" "$TCAT_ICEBERG" "$TDB"
  run_stmt "$dir" m2-merge-fixture "INSERT INTO $t VALUES (1)" "$TCAT_ICEBERG" "$TDB"
  run_stmt "$dir" m2-merge-zero \
    "MERGE INTO $t AS tgt USING (VALUES (999)) AS src(n) ON tgt.n = src.n WHEN MATCHED THEN UPDATE SET n = src.n" \
    "$TCAT_ICEBERG" "$TDB"
  run_stmt "$dir" m2-merge-one \
    "MERGE INTO $t AS tgt USING (VALUES (1)) AS src(n) ON tgt.n = src.n WHEN MATCHED THEN UPDATE SET n = src.n" \
    "$TCAT_ICEBERG" "$TDB"
  best_effort_drop TABLE "$t" "$TCAT_ICEBERG" "$TDB"
}

# m3: 0 行の CTAS（Iceberg）の field 3。1 行の CTAS を対照にする。
item_m3() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  if probe_prefix_exists "$dir" "$TCAT_ICEBERG" "$TDB" "${PROBE_PREFIX}_m3"; then
    skip_item "$id" all "同名のテーブルが既にある"
    return 0
  fi
  local t0="${TDB}.${PROBE_PREFIX}_m3_zero" t1="${TDB}.${PROBE_PREFIX}_m3_one"
  # WHERE 句は FROM が無いと構文エラーになる（Trino）ので、VALUES を経由する
  # （手本 iceberg-zero-row-insert.sh:538 と同じ形）。
  local zero_select="SELECT * FROM (VALUES (1)) AS t(n) WHERE t.n < 0"
  local sql0 sql1
  if [ "$TARGET" = local ]; then
    sql0="CREATE TABLE $t0 AS $zero_select"
    sql1="CREATE TABLE $t1 AS SELECT 1 AS n"
  else
    sql0="CREATE TABLE $t0 WITH (table_type = 'ICEBERG', location = '${OUTPUT}tables-probe-113-m3-zero/', is_external = false) AS $zero_select"
    sql1="CREATE TABLE $t1 WITH (table_type = 'ICEBERG', location = '${OUTPUT}tables-probe-113-m3-one/', is_external = false) AS SELECT 1 AS n"
  fi
  run_stmt "$dir" m3-zero "$sql0" "$TCAT_ICEBERG" "$TDB"
  best_effort_drop TABLE "$t0" "$TCAT_ICEBERG" "$TDB"
  run_stmt "$dir" m3-one "$sql1" "$TCAT_ICEBERG" "$TDB"
  best_effort_drop TABLE "$t1" "$TCAT_ICEBERG" "$TDB"
}

# m5: NOT NULL 列を持つ Iceberg テーブルを作って SELECT（作れなければ記録して「測れない」へ）。
# NULL 可の対照も添える。Athena の TBLPROPERTIES('table_type'='ICEBERG') は Trino の Iceberg
# カタログに無いプロパティなので、local では作成自体が失敗するはず（r1・r2・x1 と同種）。
item_m5() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  if probe_prefix_exists "$dir" "$TCAT_ICEBERG" "$TDB" "${PROBE_PREFIX}_m5"; then
    skip_item "$id" all "同名のテーブルが既にある"
    return 0
  fi
  local t_nn="${TDB}.${PROBE_PREFIX}_m5_notnull" t_n="${TDB}.${PROBE_PREFIX}_m5_null"

  run_stmt "$dir" m5-create-notnull \
    "CREATE TABLE $t_nn (n int NOT NULL, s string) LOCATION '${OUTPUT}tables-probe-113-m5-notnull/' TBLPROPERTIES ('table_type'='ICEBERG')" \
    "$TCAT_ICEBERG" "$TDB"
  local nn_rc=$?
  if [ "$nn_rc" -eq 0 ]; then
    run_stmt "$dir" m5-select-notnull "SELECT * FROM $t_nn" "$TCAT_ICEBERG" "$TDB"
  else
    skip_item "$id" m5-select-notnull "NOT NULL 列のテーブルを作れなかった（測れない）"
  fi
  best_effort_drop TABLE "$t_nn" "$TCAT_ICEBERG" "$TDB"

  run_stmt "$dir" m5-create-null \
    "CREATE TABLE $t_n (n int, s string) LOCATION '${OUTPUT}tables-probe-113-m5-null/' TBLPROPERTIES ('table_type'='ICEBERG')" \
    "$TCAT_ICEBERG" "$TDB"
  [ $? -eq 0 ] && run_stmt "$dir" m5-select-null "SELECT * FROM $t_n" "$TCAT_ICEBERG" "$TDB"
  best_effort_drop TABLE "$t_n" "$TCAT_ICEBERG" "$TDB"

  if [ "$TARGET" = local ]; then
    declare_expectation "$id" local_ddl_fails fail "$([ "$nn_rc" -eq 0 ] && echo success || echo fail)" \
      "TBLPROPERTIES('table_type'='ICEBERG')はTrinoのIcebergカタログに無いプロパティ"
  fi
}
