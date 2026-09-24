# shellcheck shell=bash
# issue #113: 文の種類関連の未実測 3 項目（s1, s2, p1）。単独では実行しない。
# run.sh が source して item_s1 などを呼ぶ。

# s1: ALTER TABLE ... REPLACE COLUMN（単数形）の受理と SubstatementType。
# 複数形 REPLACE COLUMNS を対照にする。どちらも Trino の文法に無い綴りなので、
# local では フィクスチャ（CREATE EXTERNAL TABLE）自体が構文チェックで落ちる。
item_s1() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  local t="${TDB}.${PROBE_PREFIX}_s1"
  if probe_prefix_exists "$dir" "$TCAT_HIVE" "$TDB" "${PROBE_PREFIX}_s1"; then
    skip_item "$id" all "同名のテーブルが既にある"
    return 0
  fi
  local loc="${OUTPUT}tables-probe-113-s1/"
  run_stmt "$dir" s1-fixture "CREATE EXTERNAL TABLE $t (n int, s string) LOCATION '$loc'" "$TCAT_HIVE" "$TDB"
  local fixture_rc=$?
  record_created TABLE "$t" "$TCAT_HIVE" "$TDB"

  run_stmt "$dir" s1-replace-column-singular "ALTER TABLE $t REPLACE COLUMN (n int, s string)" "$TCAT_HIVE" "$TDB"
  run_stmt "$dir" s1-replace-columns-plural "ALTER TABLE $t REPLACE COLUMNS (n int, s varchar)" "$TCAT_HIVE" "$TDB"

  best_effort_drop TABLE "$t" "$TCAT_HIVE" "$TDB"
  record_cleanup_hint "s1 hive: $loc"

  if [ "$TARGET" = local ]; then
    declare_expectation "$id" local_ddl_fails fail "$([ "$fixture_rc" -eq 0 ] && echo success || echo fail)" \
      "CREATE EXTERNAL TABLEはTrinoの構文に無い"
  fi
}

# s2: ALTER TABLE ... DROP PARTITION × Iceberg（本題）。同じ文を Hive にも投げて対照にする。
# DROP PARTITION は Trino の文法に無い綴り（caveats.md の 6 綴りの表）なので、フィクスチャの
# 成否によらず、文それ自体が local では構文チェックで落ちるはず。
item_s2() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  local ice_t="${TDB}.${PROBE_PREFIX}_s2_ice" hive_t="${TDB}.${PROBE_PREFIX}_s2_hive"
  if probe_prefix_exists "$dir" "$TCAT_ICEBERG" "$TDB" "${PROBE_PREFIX}_s2"; then
    skip_item "$id" all "同名のテーブルが既にある"
    return 0
  fi

  local ice_sql
  if [ "$TARGET" = local ]; then
    ice_sql="CREATE TABLE $ice_t WITH (partitioning = ARRAY['p']) AS SELECT 1 AS n, 'a' AS p"
  else
    ice_sql="CREATE TABLE $ice_t WITH (table_type = 'ICEBERG', partitioning = ARRAY['p'], location = '${OUTPUT}tables-probe-113-s2-ice/', is_external = false) AS SELECT 1 AS n, 'a' AS p"
  fi
  run_stmt "$dir" s2-ice-fixture "$ice_sql" "$TCAT_ICEBERG" "$TDB"
  record_created TABLE "$ice_t" "$TCAT_ICEBERG" "$TDB"
  run_stmt "$dir" s2-ice-drop-partition "ALTER TABLE $ice_t DROP PARTITION (p = 'a')" "$TCAT_ICEBERG" "$TDB"
  local ice_drop_rc=$?
  best_effort_drop TABLE "$ice_t" "$TCAT_ICEBERG" "$TDB"

  local hive_loc="${OUTPUT}tables-probe-113-s2-hive/"
  run_stmt "$dir" s2-hive-fixture \
    "CREATE EXTERNAL TABLE $hive_t (n int) PARTITIONED BY (p string) LOCATION '$hive_loc'" "$TCAT_HIVE" "$TDB"
  record_created TABLE "$hive_t" "$TCAT_HIVE" "$TDB"
  # DROP PARTITION の前に ADD PARTITION でパーティションを足しておく（手本
  # tools/measure/alter-variants.sh:763,770 と同じ順）。local はフィクスチャ自体が通らない。
  run_stmt "$dir" s2-hive-add-partition \
    "ALTER TABLE $hive_t ADD PARTITION (p = 'a') LOCATION '${hive_loc}p=a/'" "$TCAT_HIVE" "$TDB"
  run_stmt "$dir" s2-hive-drop-partition "ALTER TABLE $hive_t DROP PARTITION (p = 'a')" "$TCAT_HIVE" "$TDB"
  best_effort_drop TABLE "$hive_t" "$TCAT_HIVE" "$TDB"
  record_cleanup_hint "s2 hive: $hive_loc"

  if [ "$TARGET" = local ]; then
    declare_expectation "$id" local_ddl_fails fail "$([ "$ice_drop_rc" -eq 0 ] && echo success || echo fail)" \
      "DROP PARTITIONはTrinoの構文に無い"
  fi
}

# p1: 括弧で始まるクエリの分類。`(SELECT 1)` は DML/SELECT と既知。空白入り・改行入りが
# 同じに分類されるかを見る（athena-local の分類はコメント・空白を読み飛ばすだけなので同じになるはず）。
item_p1() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  run_stmt "$dir" p1-control "(SELECT 1)" "$TCAT_GENERIC" "$TDB"
  run_stmt "$dir" p1-spaced "( SELECT 1 )" "$TCAT_GENERIC" "$TDB"
  run_stmt "$dir" p1-newline "(
SELECT 1
)" "$TCAT_GENERIC" "$TDB"

  if [ "$TARGET" = local ]; then
    local st sub
    IFS=$'\t' read -r st sub _ < <(read_execution_fields "$dir/p1-spaced.execution.json")
    declare_expectation "$id" spaced_classification "DML/SELECT" "$st/$sub" "空白入り"
    IFS=$'\t' read -r st sub _ < <(read_execution_fields "$dir/p1-newline.execution.json")
    declare_expectation "$id" newline_classification "DML/SELECT" "$st/$sub" "改行入り"
  fi
}
