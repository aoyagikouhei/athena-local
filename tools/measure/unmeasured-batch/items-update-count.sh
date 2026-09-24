# shellcheck shell=bash
# issue #160: UTILITY 文の GetQueryResults の UpdateCount がテーブルの形式（Hive／Iceberg）で割れるか（u1）。
# 単独では実行しない。run.sh が source して item_u1 を呼ぶ。
#
# #151 の r5 で、Hive のテーブルへの SHOW CREATE TABLE は UpdateCount 無し（null）、Iceberg は 0 と分かった。
# DESCRIBE は Hive の外部テーブルでしか測っておらず（#76 c5・#146 x1: null）、Iceberg は未実測。
# 同じラウンドに Hive の外部テーブルと Iceberg の素の CREATE TABLE を作り、DESCRIBE・SHOW COLUMNS・
# SHOW TBLPROPERTIES・SHOW CREATE TABLE（対照）を両方に投げて UpdateCount を並べる。
# DDL あり（CREATE 2 本・DROP 2 本。r5 と同じ作り方と後始末）。本物への呼び出しは StartQueryExecution 12 本。

# results-1.json の UpdateCount を "0" / "absent"（キー無しか null）/ "(unreadable)" にする。
update_count_of() {
  python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("(unreadable)"); sys.exit()
v = d.get("UpdateCount")
print("absent" if v is None else v)' "$1"
}

# 1 文を投げ、UpdateCount の行を足す。local は記録だけ（期待値は置かない。#160 の実装で変わるため）。
count_case() {
  local label=$1 sql=$2 catalog=$3 database=$4
  local dir="$RUN_DIR/$CURRENT_ITEM"
  if ! run_stmt "$dir" "$label" "$sql" "$catalog" "$database"; then
    write_summary_row "$CURRENT_ITEM" "$label-count" stmt - - - - - - - - - - - \
      "UpdateCount: 測れず（$(first_err_line "$dir/$label.start.err" 2>/dev/null || echo 失敗)）"
    return 0
  fi
  write_summary_row "$CURRENT_ITEM" "$label-count" stmt - - - - - - - - - - - \
    "UpdateCount=$(update_count_of "$dir/$label.results-1.json")"
}

# u1: Hive 外部テーブルと Iceberg テーブルへの DESCRIBE・SHOW COLUMNS・SHOW TBLPROPERTIES・SHOW CREATE TABLE。
item_u1() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  local hive_ext="${TDB}.${PROBE_PREFIX}_u1_hive_ext" ice_plain="${TDB}.${PROBE_PREFIX}_u1_ice_plain"
  if probe_prefix_exists "$dir" "$TCAT_HIVE" "$TDB" "${PROBE_PREFIX}_u1"; then
    skip_item "$id" all "同名のテーブルが既にある"
    return 0
  fi

  # 1. Hive の外部テーブル（r5 と同じ作り方）。local では Trino の構文に無いので作れず skip になる。
  local ext_loc="${OUTPUT}tables-probe-160-u1-hive-ext/"
  run_stmt "$dir" u1-hive-ext-create "CREATE EXTERNAL TABLE $hive_ext (n int) LOCATION '$ext_loc'" "$TCAT_HIVE" "$TDB"
  local ext_rc=$?
  record_created TABLE "$hive_ext" "$TCAT_HIVE" "$TDB"
  if [ "$ext_rc" -eq 0 ]; then
    count_case u1-hive-describe "DESCRIBE $hive_ext" "$TCAT_HIVE" "$TDB"
    count_case u1-hive-show-columns "SHOW COLUMNS FROM $hive_ext" "$TCAT_HIVE" "$TDB"
    count_case u1-hive-show-tblproperties "SHOW TBLPROPERTIES $hive_ext" "$TCAT_HIVE" "$TDB"
    count_case u1-hive-show-create "SHOW CREATE TABLE $hive_ext" "$TCAT_HIVE" "$TDB"
  else
    skip_item "$id" hive "Hive の外部テーブルを作れなかった（local では想定どおり）"
  fi
  best_effort_drop TABLE "$hive_ext" "$TCAT_HIVE" "$TDB"
  record_cleanup_hint "u1 hive ext: $ext_loc"

  # 2. Iceberg の素の CREATE TABLE（r5 と同じ作り方）。
  local ice_loc="${OUTPUT}tables-probe-160-u1-ice-plain/"
  local ice_sql
  if [ "$TARGET" = local ]; then
    ice_sql="CREATE TABLE $ice_plain (n int)"
  else
    ice_sql="CREATE TABLE $ice_plain (n int) LOCATION '$ice_loc' TBLPROPERTIES ('table_type'='ICEBERG')"
  fi
  run_stmt "$dir" u1-ice-plain-create "$ice_sql" "$TCAT_ICEBERG" "$TDB"
  local ice_rc=$?
  record_created TABLE "$ice_plain" "$TCAT_ICEBERG" "$TDB"
  if [ "$ice_rc" -eq 0 ]; then
    count_case u1-ice-describe "DESCRIBE $ice_plain" "$TCAT_ICEBERG" "$TDB"
    count_case u1-ice-show-columns "SHOW COLUMNS FROM $ice_plain" "$TCAT_ICEBERG" "$TDB"
    count_case u1-ice-show-tblproperties "SHOW TBLPROPERTIES $ice_plain" "$TCAT_ICEBERG" "$TDB"
    count_case u1-ice-show-create "SHOW CREATE TABLE $ice_plain" "$TCAT_ICEBERG" "$TDB"
  else
    skip_item "$id" iceberg "Iceberg の素の CREATE TABLE を作れなかった"
  fi
  best_effort_drop TABLE "$ice_plain" "$TCAT_ICEBERG" "$TDB"
}
