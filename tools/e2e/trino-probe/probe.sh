#!/usr/bin/env bash
# issue #39 で作成（tools/ へ移す前の名前は 39-trino-probe/probe.sh）
# issue #39 の実測: Trino がテーブル形式（Hive / Iceberg）を判定する手段があるか、
# DROP TABLE / ALTER TABLE の updateType がどう出るかを、ローカル Trino の
# /v1/statement を直接叩いて確かめるスクリプト。
#
# 前提: tools/e2e/trino-probe/docker-compose.yml で Trino を起動済み
#       （スキーマ・対照テーブルは本スクリプトが作成する）。
#
# バージョンを変えて確かめるときは、このスクリプトではなく docker-compose.yml 側を
# 差し替える: TRINO_TAG=<タグ> [CATALOG_DIR=./catalog-legacy] docker compose up -d
# （古いバージョンは fs.local.enabled が無く fs.native-local.enabled が要るため
# catalog-legacy/ を用意してある。要るかはバージョンごとに起動ログで確認する）。
#
# 出力: $OUT_DIR 以下に <ラベル>.<ページ番号>.json で生の応答を保存する。
# バージョンごとに OUT_DIR を分けて実行すること。
#
# 使い方: OUT_DIR=/path/to/out/482 BASE=http://127.0.0.1:8090 bash probe.sh

set -euo pipefail

BASE="${BASE:-http://127.0.0.1:8090}"
OUT_DIR="${OUT_DIR:?OUT_DIR を指定してください}"
mkdir -p "$OUT_DIR"

# $1 sql, $2 label, $3 catalog(省略可), $4 schema(省略可)
post() {
  local sql="$1"
  local label="$2"
  local catalog="${3:-}"
  local schema="${4:-}"
  local hdrs=(-H "X-Trino-User: probe" -H "X-Trino-Client-Capabilities: PARAMETRIC_DATETIME")
  if [ -n "$catalog" ]; then hdrs+=(-H "X-Trino-Catalog: $catalog"); fi
  if [ -n "$schema" ]; then hdrs+=(-H "X-Trino-Schema: $schema"); fi

  local start end resp next i
  start=$(date +%s.%N)
  resp=$(curl -s -X POST "$BASE/v1/statement" "${hdrs[@]}" --data-binary "$sql")
  echo "$resp" > "$OUT_DIR/${label}.0.json"
  i=1
  next=$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('nextUri',''))" 2>/dev/null || true)
  while [ -n "$next" ] && [ "$next" != "None" ]; do
    resp=$(curl -s "$next")
    echo "$resp" > "$OUT_DIR/${label}.${i}.json"
    next=$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('nextUri',''))" 2>/dev/null || true)
    i=$((i+1))
  done
  end=$(date +%s.%N)
  local elapsed
  elapsed=$(python3 -c "print(f'{$end-$start:.3f}')")
  echo "${label}: pages=${i} elapsed=${elapsed}s"
}

echo "=== セットアップ（スキーマ・対照テーブル） ==="
post "CREATE SCHEMA IF NOT EXISTS hive.default" setup_hive_schema
post "CREATE SCHEMA IF NOT EXISTS iceberg.default" setup_iceberg_schema
post "CREATE TABLE IF NOT EXISTS hive.default.t1 AS SELECT 1 AS n" setup_hive_t1
post "CREATE TABLE IF NOT EXISTS iceberg.default.t1 AS SELECT 1 AS n" setup_iceberg_t1

echo
echo "=== A. カタログ／テーブルの形式を知る手段 ==="
post "SHOW CATALOGS" a1_show_catalogs
post "SELECT * FROM system.metadata.catalogs" a2_system_metadata_catalogs
post "SHOW CREATE TABLE hive.default.t1" a3_show_create_hive
post "SHOW CREATE TABLE iceberg.default.t1" a3_show_create_iceberg
post "SELECT * FROM hive.information_schema.tables WHERE table_name = 't1'" a4_info_schema_hive
post "SELECT * FROM iceberg.information_schema.tables WHERE table_name = 't1'" a4_info_schema_iceberg
post 'SELECT * FROM hive.default."t1$properties"' a5_dollar_properties_hive
post 'SELECT * FROM iceberg.default."t1$properties"' a5_dollar_properties_iceberg
post "SELECT * FROM system.metadata.table_properties" a6_system_metadata_table_properties
# 追加で見つけた手段
post "SELECT * FROM system.jdbc.tables WHERE table_name = 't1'" a7_system_jdbc_tables
post 'SELECT * FROM iceberg.default."t1$snapshots"' a7_dollar_snapshots_iceberg_ctrl
post 'SELECT * FROM hive.default."t1$partitions"' a7_dollar_partitions_hive_ctrl
post "SHOW TABLES FROM hive.default LIKE 't1'" a7_show_tables_hive
post "SHOW TABLES FROM iceberg.default LIKE 't1'" a7_show_tables_iceberg

echo
echo "=== B. 存在しないテーブルに対する挙動 ==="
post "SHOW CREATE TABLE hive.default.nope" b_show_create_hive_missing
post "SHOW CREATE TABLE iceberg.default.nope" b_show_create_iceberg_missing
post "SELECT * FROM hive.information_schema.tables WHERE table_name = 'nope'" b_info_schema_hive_missing
post "SELECT * FROM iceberg.information_schema.tables WHERE table_name = 'nope'" b_info_schema_iceberg_missing
post 'SELECT * FROM hive.default."nope$properties"' b_dollar_properties_hive_missing
post 'SELECT * FROM iceberg.default."nope$properties"' b_dollar_properties_iceberg_missing
post "SELECT * FROM system.metadata.table_properties WHERE table_name = 'nope'" b_system_metadata_table_properties_missing

echo
echo "=== C. DDL の updateType ==="
# C1: DROP TABLE 用に専用テーブルを作る
post "CREATE TABLE hive.default.t_drop AS SELECT 1 AS n" setup_hive_t_drop
post "CREATE TABLE iceberg.default.t_drop AS SELECT 1 AS n" setup_iceberg_t_drop
post "DROP TABLE hive.default.t_drop" c1_drop_table_hive
post "DROP TABLE iceberg.default.t_drop" c1_drop_table_iceberg

# C2: ALTER TABLE ADD COLUMN 用に専用テーブルを作る
post "CREATE TABLE hive.default.t_alter AS SELECT 1 AS n" setup_hive_t_alter
post "CREATE TABLE iceberg.default.t_alter AS SELECT 1 AS n" setup_iceberg_t_alter
post "ALTER TABLE hive.default.t_alter ADD COLUMN m int" c2_alter_add_column_hive
post "ALTER TABLE iceberg.default.t_alter ADD COLUMN m int" c2_alter_add_column_iceberg

# C3: 対照 CREATE TABLE（AS SELECT ではない素の CREATE）
post "CREATE TABLE hive.default.t_plain (n int)" c3_create_table_hive
post "CREATE TABLE iceberg.default.t_plain (n int)" c3_create_table_iceberg

# C4: 対照 SELECT
post "SELECT 1 AS n" c4_select_1_hive hive default
post "SELECT 1 AS n" c4_select_1_iceberg iceberg default

echo
echo "=== D. 本番の probe_sql と同じ形（system.metadata.catalogs + system.jdbc.tables を1クエリで） ==="
# src/operation/table_format.rs の probe_sql() と同じ組み立て。
# table_cat / table_schem / table_name を3つとも指定したときの count(*) が
# 存在するテーブルで1、しないテーブルで0になるかを見る。
post "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = 'hive'), (SELECT count(*) FROM system.jdbc.tables WHERE table_cat = 'hive' AND table_schem = 'default' AND table_name = 't1')" d1_probe_hive_exists
post "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = 'iceberg'), (SELECT count(*) FROM system.jdbc.tables WHERE table_cat = 'iceberg' AND table_schem = 'default' AND table_name = 't1')" d2_probe_iceberg_exists
post "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = 'hive'), (SELECT count(*) FROM system.jdbc.tables WHERE table_cat = 'hive' AND table_schem = 'default' AND table_name = 'nope')" d3_probe_hive_missing
post "SELECT (SELECT connector_name FROM system.metadata.catalogs WHERE catalog_name = 'iceberg'), (SELECT count(*) FROM system.jdbc.tables WHERE table_cat = 'iceberg' AND table_schem = 'default' AND table_name = 'nope')" d4_probe_iceberg_missing
# table_schem/table_name は一致するがカタログが違う（3つ全部を見ているかの確認。0件のはず）
post "SELECT count(*) FROM system.jdbc.tables WHERE table_cat = 'no_such_catalog' AND table_schem = 'default' AND table_name = 't1'" d5_probe_wrong_catalog

echo
echo "=== 完了 ==="
