# shellcheck shell=bash
# issue #113: 結果ファイル関連の未実測 6 項目（r1-r4, x1, x2）。単独では実行しない。
# run.sh が source して item_r1 などを呼ぶ。
#
# r1・r2・x1 は Hive の外部テーブル（CREATE EXTERNAL TABLE ... LOCATION）を使う。この綴りは
# Trino の文法に無い（docs/caveats.md の「六つの ALTER TABLE の綴り」と同種）ので、
# TARGET=local では athena-local の構文チェック（PREPARE）で MALFORMED_QUERY になり、
# QueryExecutionId すら作られない。「local では FAILED が期待どおり」として declare_expectation する。

# r1: CREATE TABLE の重複（Hive・Iceberg それぞれ 2 回）。2 回目は FAILED のはず。
item_r1() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  local hive_t="${TDB}.${PROBE_PREFIX}_r1_hive" ice_t="${TDB}.${PROBE_PREFIX}_r1_ice"
  if probe_prefix_exists "$dir" "$TCAT_HIVE" "$TDB" "${PROBE_PREFIX}_r1"; then
    skip_item "$id" all "同名のテーブルが既にある"
    return 0
  fi

  local hive_loc="${OUTPUT}tables-probe-113-r1-hive/"
  run_stmt "$dir" r1-hive-create1 "CREATE EXTERNAL TABLE $hive_t (n int) LOCATION '$hive_loc'" "$TCAT_HIVE" "$TDB"
  local hive_rc=$?
  record_created TABLE "$hive_t" "$TCAT_HIVE" "$TDB"
  run_stmt "$dir" r1-hive-create2 "CREATE EXTERNAL TABLE $hive_t (n int) LOCATION '$hive_loc'" "$TCAT_HIVE" "$TDB"
  best_effort_drop TABLE "$hive_t" "$TCAT_HIVE" "$TDB"
  record_cleanup_hint "r1 hive: $hive_loc"

  local ice_loc="${OUTPUT}tables-probe-113-r1-ice/"
  run_stmt "$dir" r1-ice-create1 \
    "CREATE TABLE $ice_t WITH (table_type = 'ICEBERG', location = '$ice_loc', is_external = false) AS SELECT 1 AS n" \
    "$TCAT_ICEBERG" "$TDB"
  record_created TABLE "$ice_t" "$TCAT_ICEBERG" "$TDB"
  run_stmt "$dir" r1-ice-create2 \
    "CREATE TABLE $ice_t WITH (table_type = 'ICEBERG', location = '$ice_loc', is_external = false) AS SELECT 1 AS n" \
    "$TCAT_ICEBERG" "$TDB"
  best_effort_drop TABLE "$ice_t" "$TCAT_ICEBERG" "$TDB"

  if [ "$TARGET" = local ]; then
    declare_expectation "$id" local_ddl_fails fail "$([ "$hive_rc" -eq 0 ] && echo success || echo fail)" \
      "CREATE EXTERNAL TABLEはTrinoの構文に無い"
  fi
}

# r2: .txt の値のタブ・改行・NULL。Hive の列コメントと TBLPROPERTIES にタブ・改行を入れ、
# DESCRIBE / SHOW TBLPROPERTIES で見る。もう 1 列はコメント無し（NULL）。
item_r2() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  local t="${TDB}.${PROBE_PREFIX}_r2"
  if probe_prefix_exists "$dir" "$TCAT_HIVE" "$TDB" "${PROBE_PREFIX}_r2"; then
    skip_item "$id" all "同名のテーブルが既にある"
    return 0
  fi
  local loc="${OUTPUT}tables-probe-113-r2/"
  local weird=$'a\tb\nc'
  run_stmt "$dir" r2-create \
    "CREATE EXTERNAL TABLE $t (n int COMMENT '${weird}', m int) LOCATION '$loc' TBLPROPERTIES ('note'='x${weird}y')" \
    "$TCAT_HIVE" "$TDB"
  local create_rc=$?
  record_created TABLE "$t" "$TCAT_HIVE" "$TDB"
  run_stmt "$dir" r2-describe "DESCRIBE $t" "$TCAT_HIVE" "$TDB"
  run_stmt "$dir" r2-show-tblproperties "SHOW TBLPROPERTIES $t" "$TCAT_HIVE" "$TDB"
  best_effort_drop TABLE "$t" "$TCAT_HIVE" "$TDB"
  record_cleanup_hint "r2 hive: $loc"

  if [ "$TARGET" = local ]; then
    declare_expectation "$id" local_ddl_fails fail "$([ "$create_rc" -eq 0 ] && echo success || echo fail)" \
      "CREATE EXTERNAL TABLEはTrinoの構文に無い"
  fi
}

# r3: 失敗する SHOW FUNCTIONS（ESCAPE が 2 文字）。成功する SHOW FUNCTIONS が対照。
# ESCAPE の桁数は SQL の一般規則で、Athena 固有ではないので local でも同じく失敗するはず。
item_r3() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  run_stmt "$dir" r3-control "SHOW FUNCTIONS" "$TCAT_GENERIC" "$TDB"
  run_stmt "$dir" r3-fail "SHOW FUNCTIONS LIKE 'x' ESCAPE 'ab'" "$TCAT_GENERIC" "$TDB"
}

# r4: SHOW CREATE VIEW の Content-Type。対照は SHOW CREATE TABLE（既知）。
# Iceberg カタログを使う（memory 連携はビューを持てないことがあるため）。対照のテーブルは、
# real では他の項目と同じく Iceberg の CTAS で作る（table_type を付けないと Hive の CTAS に
# なり、DROP で S3 にデータが残るため。r1・m2・m3 と同じ理由）。local はこれまでどおり。
item_r4() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  local v="${TDB}.${PROBE_PREFIX}_r4_view" t="${TDB}.${PROBE_PREFIX}_r4_table"
  if probe_prefix_exists "$dir" "$TCAT_ICEBERG" "$TDB" "${PROBE_PREFIX}_r4"; then
    skip_item "$id" all "同名のテーブル/ビューが既にある"
    return 0
  fi

  run_stmt "$dir" r4-create-view "CREATE VIEW $v AS SELECT 1 AS n" "$TCAT_ICEBERG" "$TDB"
  record_created VIEW "$v" "$TCAT_ICEBERG" "$TDB"
  run_stmt "$dir" r4-show-create-view "SHOW CREATE VIEW $v" "$TCAT_ICEBERG" "$TDB"
  best_effort_drop VIEW "$v" "$TCAT_ICEBERG" "$TDB"

  local table_sql
  if [ "$TARGET" = local ]; then
    table_sql="CREATE TABLE $t AS SELECT 1 AS n"
  else
    table_sql="CREATE TABLE $t WITH (table_type = 'ICEBERG', location = '${OUTPUT}tables-probe-113-r4/', is_external = false) AS SELECT 1 AS n"
  fi
  run_stmt "$dir" r4-create-table "$table_sql" "$TCAT_ICEBERG" "$TDB"
  record_created TABLE "$t" "$TCAT_ICEBERG" "$TDB"
  run_stmt "$dir" r4-show-create-table "SHOW CREATE TABLE $t" "$TCAT_ICEBERG" "$TDB"
  best_effort_drop TABLE "$t" "$TCAT_ICEBERG" "$TDB"
}

# x1: caveats.md:55「ブロックコメントを弾くほかの文」。動詞の直後に /* c */ を入れた変種と
# 対照（コメント無し）を、7 文（DESCRIBE・SHOW PARTITIONS・SHOW TBLPROPERTIES・SHOW COLUMNS・
# SHOW CREATE VIEW・MSCK REPAIR TABLE・CREATE EXTERNAL TABLE）で比べる。
# フィクスチャの Hive 外部テーブル自体が local では作れない（CREATE EXTERNAL TABLE の構文が
# Trino に無い）ので、Hive に依存する 6 文は local ではフィクスチャ無しで skip する。
item_x1() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  local t="${TDB}.${PROBE_PREFIX}_x1" v="${TDB}.${PROBE_PREFIX}_x1_view"
  if probe_prefix_exists "$dir" "$TCAT_HIVE" "$TDB" "${PROBE_PREFIX}_x1"; then
    skip_item "$id" all "同名のテーブル/ビューが既にある"
    return 0
  fi

  local loc="${OUTPUT}tables-probe-113-x1/"
  run_stmt "$dir" x1-fixture-table \
    "CREATE EXTERNAL TABLE $t (n int) PARTITIONED BY (p string) LOCATION '$loc'" "$TCAT_HIVE" "$TDB"
  local table_ok=$?
  record_created TABLE "$t" "$TCAT_HIVE" "$TDB"
  run_stmt "$dir" x1-fixture-view "CREATE VIEW $v AS SELECT 1 AS n" "$TCAT_ICEBERG" "$TDB"
  local view_ok=$?
  record_created VIEW "$v" "$TCAT_ICEBERG" "$TDB"

  if [ "$table_ok" -eq 0 ]; then
    run_stmt "$dir" x1-describe-plain "DESCRIBE $t" "$TCAT_HIVE" "$TDB"
    run_stmt "$dir" x1-describe-comment "DESCRIBE /* c */ $t" "$TCAT_HIVE" "$TDB"
    run_stmt "$dir" x1-show-partitions-plain "SHOW PARTITIONS $t" "$TCAT_HIVE" "$TDB"
    run_stmt "$dir" x1-show-partitions-comment "SHOW PARTITIONS /* c */ $t" "$TCAT_HIVE" "$TDB"
    run_stmt "$dir" x1-show-tblproperties-plain "SHOW TBLPROPERTIES $t" "$TCAT_HIVE" "$TDB"
    run_stmt "$dir" x1-show-tblproperties-comment "SHOW TBLPROPERTIES /* c */ $t" "$TCAT_HIVE" "$TDB"
    run_stmt "$dir" x1-show-columns-plain "SHOW COLUMNS FROM $t" "$TCAT_HIVE" "$TDB"
    run_stmt "$dir" x1-show-columns-comment "SHOW COLUMNS FROM /* c */ $t" "$TCAT_HIVE" "$TDB"
    run_stmt "$dir" x1-msck-plain "MSCK REPAIR TABLE $t" "$TCAT_HIVE" "$TDB"
    run_stmt "$dir" x1-msck-comment "MSCK REPAIR /* c */ TABLE $t" "$TCAT_HIVE" "$TDB"
  else
    skip_item "$id" hive-dependent "フィクスチャの Hive テーブルを作れなかった（local では想定どおり）"
  fi

  if [ "$view_ok" -eq 0 ]; then
    run_stmt "$dir" x1-show-create-view-plain "SHOW CREATE VIEW $v" "$TCAT_ICEBERG" "$TDB"
    run_stmt "$dir" x1-show-create-view-comment "SHOW CREATE /* c */ VIEW $v" "$TCAT_ICEBERG" "$TDB"
  else
    skip_item "$id" view-dependent "フィクスチャのビューを作れなかった"
  fi

  local t2="${TDB}.${PROBE_PREFIX}_x1_ext" t3="${TDB}.${PROBE_PREFIX}_x1_ext_c"
  run_stmt "$dir" x1-create-external-plain \
    "CREATE EXTERNAL TABLE $t2 (n int) LOCATION '${OUTPUT}tables-probe-113-x1-ext-plain/'" "$TCAT_HIVE" "$TDB"
  record_created TABLE "$t2" "$TCAT_HIVE" "$TDB"
  best_effort_drop TABLE "$t2" "$TCAT_HIVE" "$TDB"
  run_stmt "$dir" x1-create-external-comment \
    "CREATE EXTERNAL /* c */ TABLE $t3 (n int) LOCATION '${OUTPUT}tables-probe-113-x1-ext-comment/'" "$TCAT_HIVE" "$TDB"
  record_created TABLE "$t3" "$TCAT_HIVE" "$TDB"
  best_effort_drop TABLE "$t3" "$TCAT_HIVE" "$TDB"

  best_effort_drop TABLE "$t" "$TCAT_HIVE" "$TDB"
  best_effort_drop VIEW "$v" "$TCAT_ICEBERG" "$TDB"
  record_cleanup_hint "x1 hive: $loc, ${OUTPUT}tables-probe-113-x1-ext-plain/, ${OUTPUT}tables-probe-113-x1-ext-comment/"

  if [ "$TARGET" = local ]; then
    declare_expectation "$id" local_ddl_fails fail "$([ "$table_ok" -eq 0 ] && echo success || echo fail)" \
      "CREATE EXTERNAL TABLE(PARTITIONED)はTrinoの構文に無い"
  fi
}

# x2: caveats.md:156「複合値の中の varbinary」。array/map/row に X'0102' を入れる。
# 対照はトップレベルの varbinary（既知）。
item_x2() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  run_stmt "$dir" x2-top "SELECT X'0102' AS v" "$TCAT_GENERIC" "$TDB"
  run_stmt "$dir" x2-array "SELECT ARRAY[X'0102', X'03'] AS v" "$TCAT_GENERIC" "$TDB"
  run_stmt "$dir" x2-map "SELECT MAP(ARRAY['k'], ARRAY[X'0102']) AS v" "$TCAT_GENERIC" "$TDB"
  run_stmt "$dir" x2-row "SELECT CAST(ROW(X'0102') AS ROW(b varbinary)) AS v" "$TCAT_GENERIC" "$TDB"
}
