#!/usr/bin/env bash
# issue #173 で作成。
# 本物の Trino（compose の trino）と MinIO を相手に athena-local を動かし、SHOW TABLES／SHOW COLUMNS／DESCRIBE の
# GetQueryResults（ColumnInfo の Name/Type/Precision/CaseSensitive、Rows の各行の Data の個数と値、UpdateCount の有無）と、
# MinIO に置かれた `<id>.txt` のバイト列が、本物の Athena で測った形と一致するかを確かめる。
#
# 期待値は実測の生データからコピーせず、次の規則から printf で組み立てる（2026-09-24 実測の規則。#173）。
#   SHOW TABLES   : `tab_name`／string／0／false の 1 列。行は素のテーブル名。UpdateCount 0。
#   SHOW COLUMNS  : `field`／string／0／false の 1 列。Hive は列名を 20 桁に左詰め（20 桁以上は詰めない。パーティション列も含む）、
#                   Iceberg は詰めない。UpdateCount 0。
#   DESCRIBE Hive : `col_name`／`data_type`／`comment` の 3 列（string／0／false）。各行の Data は 1 個で
#                   `<列名 %-20s>\t<Hive の型 %-20s>\t<コメント>`（コメントが空なら空白 20 個、空でなければ詰めずタブの手前まで）。
#                   パーティション付きは通常列（パーティション列も含む）の後に見出し 4 行とパーティション列。UpdateCount 無し。
#   DESCRIBE Iceberg（パーティション無し）: 同じ 3 列で、詰め無しの 6 行。UpdateCount 0。
#   DESCRIBE Iceberg（パーティション付き）: 上の 6 行の間に列の行（`name\t<Iceberg の型>\t<コメント>`、詰め無し）、
#                   末尾にパーティションごとの `field_name\tfield_transform\tcolumn_name`（`s\tidentity\ts`、`n_bucket\tbucket[4]\tn`、
#                   `ts_day\tday\tts`、`ts_year\tyear\tts`、`d2_month\tmonth\td2`、`ts2_hour\thour\tts2`、`s_trunc\ttruncate[3]\ts`）。
#                   Iceberg の型は `int`／`string`／`timestamp`／`decimal(10, 2)`／`array<string>`／`struct<a: int>`／`float`／`binary`／
#                   `map<string, int>`（`double`／`boolean`／`date`／`bigint` はそのまま）。UpdateCount 0。
#   DESC          : DESCRIBE と同じ行（SubstatementType は足場では見ない）。
#   SHOW SCHEMAS  : `database_name`／string／0／false の 1 列。行は素のスキーマ名。UpdateCount 0。
#   ビューへの DESCRIBE／SHOW COLUMNS: `column`／`type`（varchar／0／false）の 2 列。行は `name\t<Trino の型>`（詰め無し）、
#                   UpdateCount 0、`.txt` は binary/octet-stream、GetQueryExecution の SubstatementType は `DESC_VIEW`。
#   `.txt` はどれも GetQueryResults の値を `\n` で連結したもの（末尾改行なし）。
#
# #173 の変更前のビルドで流すと、E1〜E11 は FAIL、回帰の R1・R2 は PASS になるのが正しい。
#
# 前提: tools/dev.sh 経由で toolbox の中で動かす（`aws` は使わず、S3 は toolbox の mc で minio:9000 を直接見る）。
# 環境はルートの compose.yml の trino / minio / minio-init。開始時に使うサービスだけ down -v → up -d で作り直す。
# 別の足場と同時に流すときは、プロジェクト名をホストの環境変数で分ける:
#   COMPOSE_PROJECT_NAME=athena173 tools/dev.sh tools/e2e/utility-rows/verify.sh
#
# 環境変数:
#   KEEP_UP=1        終了時に docker compose down -v <サービス...> をせず環境を残す（デバッグ用）
#   SKIP_BUILD=1     cargo build を省略し、既存の $CARGO_TARGET_DIR の release/athena-local をそのまま使う
#
# athena-local は lib.sh の start_athena_local で dev コンテナの中の 127.0.0.1:8087 に立てる（tools/dev.sh は
# 実行のたびに別の dev コンテナを作るので、ほかの足場のポートとはぶつからない）。
# 終了コード: FAIL が 1 件でもあれば 1。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BINARY="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/athena-local"
COMPOSE=(docker compose -f "$REPO_ROOT/compose.yml")
SERVICES=(trino minio minio-init)

TRINO_BASE="http://trino:8080"
MINIO_ENDPOINT="http://minio:9000"
ATHENA_BASE="http://127.0.0.1:8087"
BUCKET="athena-results"
PREFIX="e2e173"
OUTPUT_LOCATION="s3://${BUCKET}/${PREFIX}/"

EVIDENCE_DIR="$(mktemp -d /tmp/athena-local-issue173-e2e.XXXXXX)"
ATHENA_LOG="$EVIDENCE_DIR/athena-local.log"
BUILD_LOG="$EVIDENCE_DIR/cargo-build.log"
EXPECT_DIR="$EVIDENCE_DIR/expect"
mkdir -p "$EXPECT_DIR"

ATHENA_PID=""

# shellcheck source=tools/e2e/minio/lib.sh
source "$SCRIPT_DIR/../minio/lib.sh"

# Trino 側のオブジェクト（名前は t173_*）
SCHEMA="t173"
T_PART="t173_part"   # Hive (n integer, p varchar) partitioned_by p
T_CMT="t173_cmt"     # Hive (n integer COMMENT 'a<TAB>b', m integer)
T_WIDE="t173_wide"   # Hive 列名 19・20・21 文字の varchar 3 列
T_ICE="t173_ice"     # Iceberg (n integer)
T_ICEP="t173_icep"   # Iceberg 7 列、partitioning = s, bucket(n, 4), day(ts)
T_ICET="t173_icet"   # Iceberg 11 列、partitioning = year(ts), month(d2), hour(ts2), truncate(s, 3)
T_VIEW="t173_view"   # Hive のビュー SELECT 1 AS n, 'a' AS s。E1（SHOW TABLES）の行に混ざらないよう別スキーマに置く
VIEW_SCHEMA="t173v"
TAB=$'\t'

summary() {
  local i pass=0 fail=0 other=0
  for i in "${!RESULT_STATUS[@]}"; do
    case "${RESULT_STATUS[$i]}" in
      PASS) pass=$((pass + 1)) ;;
      FAIL) fail=$((fail + 1)) ;;
      *) other=$((other + 1)) ;;
    esac
  done
  echo "PASS=$pass FAIL=$fail その他=$other"
  echo "証跡（応答 JSON・期待値・取得した .txt・ログ）: $EVIDENCE_DIR"
  [ "$fail" = "0" ]
}

cleanup() {
  local status=$?
  if [ -n "$ATHENA_PID" ] && kill -0 "$ATHENA_PID" 2>/dev/null; then
    log "athena-local (PID $ATHENA_PID) を止める"
    kill "$ATHENA_PID" 2>/dev/null || true
    wait "$ATHENA_PID" 2>/dev/null || true
  fi
  if [ "${KEEP_UP:-0}" = "1" ]; then
    log "KEEP_UP=1 のため環境を残す（後で COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME:-athena-local} tools/dev.sh docker compose -f $REPO_ROOT/compose.yml down -v ${SERVICES[*]}）"
  else
    log "docker compose down -v ${SERVICES[*]}（プロジェクト ${COMPOSE_PROJECT_NAME:-athena-local} の使ったサービスだけ）"
    "${COMPOSE[@]}" down -v "${SERVICES[@]}" >/dev/null 2>&1
  fi
  print_table
  if ! summary; then
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT

# --- 期待値の組み立て（規則を式で表す） ---

# 長さ n の列名（先頭 `c<n>`、残りを x で埋める）。
name_of_len() {
  local n="$1" s="c$1"
  while [ "${#s}" -lt "$n" ]; do s="${s}x"; done
  printf '%s' "$s"
}

# Hive の DESCRIBE の 1 行。コメントが空なら空白 20 個、空でなければ詰めずにタブの手前まで。
hive_describe_row() {
  local name="$1" type="$2" comment="$3"
  if [ -z "$comment" ]; then
    printf '%-20s\t%-20s\t%-20s' "$name" "$type" ""
  else
    printf '%-20s\t%-20s\t%s' "$name" "$type" "${comment%%"$TAB"*}"
  fi
}

# Hive の DESCRIBE のパーティション見出し 4 行（各行は改行なし。呼び出し側で \n 連結する）。
hive_partition_heading_rows() {
  printf '\t \t \n'
  printf '# Partition Information\t \t \n'
  # `# col_name` の後ろは空白 12 個（22 桁）。data_type と comment は 20 桁に左詰め。
  printf '%-22s\t%-20s\t%-20s\n' "# col_name" "data_type" "comment"
  printf '\t \t '
}

# Iceberg の DESCRIBE の先頭 2 行（各行の末尾に \n を付けて出す）。
iceberg_heading_rows() {
  printf '# Table schema:\t\t\n'
  printf '# col_name\tdata_type\tcomment\n'
}

# Iceberg の DESCRIBE の列の行とパーティション行の間の 3 行。
iceberg_partition_heading_rows() {
  printf '\t\t\n'
  printf '# Partition spec:\t\t\n'
  printf '# field_name\tfield_transform\tcolumn_name\n'
}

# E7 の 21 文字の列名（`c21_` の後ろを a で埋める。Iceberg は 20 桁で詰めないことの確認用）。
ice_wide_name() {
  local s="c21_"
  while [ "${#s}" -lt 21 ]; do s="${s}a"; done
  printf '%s' "$s"
}

# 行（改行なし）を標準入力から 1 行ずつ受け、\n 連結（末尾改行なし）してファイルに書く。
join_rows() {
  local out="$1" first=1 line
  : >"$out"
  while IFS= read -r line; do
    if [ "$first" = "1" ]; then first=0; else printf '\n' >>"$out"; fi
    printf '%s' "$line" >>"$out"
  done
}

build_expectations() {
  local c19 c20 c21 c21_ice
  c19=$(name_of_len 19)
  c20=$(name_of_len 20)
  c21=$(name_of_len 21)
  c21_ice=$(ice_wide_name)

  # E1: SHOW TABLES（素の名前。Trino の SHOW TABLES は名前順）
  printf '%s\n' "$T_CMT" "$T_PART" "$T_WIDE" | join_rows "$EXPECT_DIR/E1.txt"

  # E2: Hive パーティション付きの DESCRIBE（7 行、291 バイト）
  {
    hive_describe_row n int ""; echo
    hive_describe_row p string ""; echo
    hive_partition_heading_rows; echo
    hive_describe_row p string ""; echo
  } | join_rows "$EXPECT_DIR/E2.txt"

  # E3: コメント付き（本当のタブ）の DESCRIBE（2 行、106 バイト）
  {
    hive_describe_row n int "a${TAB}b"; echo
    hive_describe_row m int ""; echo
  } | join_rows "$EXPECT_DIR/E3.txt"

  # E4: 列名 19・20・21 文字（20 桁ちょうどは詰めず、21 は切らない）
  {
    hive_describe_row "$c19" string ""; echo
    hive_describe_row "$c20" string ""; echo
    hive_describe_row "$c21" string ""; echo
  } | join_rows "$EXPECT_DIR/E4a.txt"
  {
    printf '%-20s\n' "$c19" "$c20" "$c21"
  } | join_rows "$EXPECT_DIR/E4b.txt"

  # E5: Iceberg（パーティション無し）の DESCRIBE（詰め無しの 6 行、117 バイト）
  {
    printf '# Table schema:\t\t\n'
    printf '# col_name\tdata_type\tcomment\n'
    printf 'n\tint\t\n'
    printf '\t\t\n'
    printf '# Partition spec:\t\t\n'
    printf '# field_name\tfield_transform\tcolumn_name\n'
  } | join_rows "$EXPECT_DIR/E5.txt"

  # E6: SHOW COLUMNS。Hive は 20 桁に左詰め（41 バイト）、Iceberg は詰めない（1 バイト）
  printf '%-20s\n' n p | join_rows "$EXPECT_DIR/E6-hive.txt"
  printf '%s\n' n | join_rows "$EXPECT_DIR/E6-iceberg.txt"

  # E7: Iceberg のパーティション付き（identity・bucket・day）の DESCRIBE（詰め無しの 15 行、278 バイト）
  {
    iceberg_heading_rows
    printf '%s\t%s\t%s\n' n int abc s string "" ts timestamp "" d "decimal(10, 2)" "" \
      arr "array<string>" "" st "struct<a: int>" "" "$c21_ice" bigint ""
    iceberg_partition_heading_rows
    printf '%s\t%s\t%s\n' s identity s n_bucket "bucket[4]" n ts_day day ts
  } | join_rows "$EXPECT_DIR/E7.txt"

  # E8: Iceberg の変換 4 種（year・month・hour・truncate）と型の綴り（20 行、343 バイト）
  {
    iceberg_heading_rows
    printf '%s\t%s\t%s\n' n int "" s string "" ts timestamp "" d2 date "" ts2 timestamp "" \
      t_double double "" t_float float "" t_boolean boolean "" t_binary binary "" \
      t_map "map<string, int>" "" big bigint ""
    iceberg_partition_heading_rows
    printf '%s\t%s\t%s\n' ts_year year ts d2_month month d2 ts2_hour hour ts2 s_trunc "truncate[3]" s
  } | join_rows "$EXPECT_DIR/E8.txt"

  # E11: ビューへの DESCRIBE／SHOW COLUMNS（詰め無しの 2 行、22 バイト。型は Trino の綴り）
  printf '%s\t%s\n' n integer s "varchar(1)" | join_rows "$EXPECT_DIR/E11.txt"

  # R1: SELECT 1 AS n（列名行あり）
  printf '%s\n' n 1 | join_rows "$EXPECT_DIR/R1.rows"
  printf '"n"\n"1"\n' >"$EXPECT_DIR/R1.csv"

  # 規則から出したバイト数が、実測で分かっている値と合うか（期待値の組み立て自体の検算）
  local f want got ok=1
  for f in E2:291 E3:106 E5:117 E6-hive:41 E6-iceberg:1 E7:278 E8:343 E11:22; do
    want="${f#*:}"
    got=$(wc -c <"$EXPECT_DIR/${f%%:*}.txt")
    if [ "$got" != "$want" ]; then
      log "期待値の組み立てが実測のバイト数と合わない: ${f%%:*} = ${got}B（実測 ${want}B）"
      ok=0
    fi
  done
  [ "$ok" = "1" ]
}

# --- ケース ---

# 実行して SUCCEEDED を待つ。成功なら QueryExecutionId を標準出力に書く。失敗なら理由を書いて 1 を返す。
run_query() {
  local no="$1" sql="$2" catalog="$3" database="$4"
  local start id resp state
  start=$(athena_start_query_raw "$sql" "$catalog" "$database")
  printf '%s\n' "$start" >"$EVIDENCE_DIR/$no.start.json"
  id=$(echo "$start" | jq -r '.QueryExecutionId // empty' 2>/dev/null)
  if [ -z "$id" ]; then
    echo "StartQueryExecution が ID を返さなかった: $(echo "$start" | tr -d '\n' | cut -c1-200)"
    return 1
  fi
  resp=$(athena_wait "$id")
  printf '%s\n' "$resp" >"$EVIDENCE_DIR/$no.execution.json"
  state=$(echo "$resp" | jq -r '.QueryExecution.Status.State // empty')
  if [ "$state" != "SUCCEEDED" ]; then
    echo "状態が $state: $(echo "$resp" | jq -r '.QueryExecution.Status.StateChangeReason // empty' | cut -c1-200) [id=$id]"
    return 1
  fi
  echo "$id"
}

# 1 ケースを判定して record する。
#   expect_cols   : ColumnInfo を `Name|Type|Precision|CaseSensitive` にして `,` で連結したもの
#   expect_rows   : Rows の値を \n 連結したファイル（各行の Data は 1 個であること）。空なら行の値は見ない（Data 1 個だけ見る）
#   expect_update : UpdateCount の期待値。`absent` なら項目が無いこと、`-` なら見ない
#   expect_txt    : `.txt` の期待値のファイル。空なら `.txt` は見ない
check_case() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5"
  local expect_cols="$6" expect_rows="$7" expect_update="$8" expect_txt="$9"
  local label="$no $name" id out ok=1 detail=""

  log "ケース $no: $name -- $(printf '%s' "$sql" | tr '\t' ' ')"
  if ! out=$(run_query "$no" "$sql" "$catalog" "$database"); then
    record "$label" FAIL "$out"
    return
  fi
  id="$out"

  local results="$EVIDENCE_DIR/$no.results.json"
  athena_call GetQueryResults "$(jq -n --arg id "$id" '{QueryExecutionId: $id}')" >"$results"
  if ! jq -e '.ResultSet' "$results" >/dev/null 2>&1; then
    record "$label" FAIL "GetQueryResults が ResultSet を返さなかった: $(tr -d '\n' <"$results" | cut -c1-200) [id=$id]"
    return
  fi

  # ColumnInfo
  local cols
  cols=$(jq -r '[.ResultSet.ResultSetMetadata.ColumnInfo[] | "\(.Name)|\(.Type)|\(.Precision)|\(.CaseSensitive)"] | join(",")' "$results")
  if [ "$cols" != "$expect_cols" ]; then
    ok=0
    detail="$detail ColumnInfo=[$cols](期待 [$expect_cols])"
  fi

  # Rows: 各行の Data の個数と値
  local counts
  counts=$(jq -r '[.ResultSet.Rows[] | .Data | length] | map(tostring) | join(",")' "$results")
  if jq -e '[.ResultSet.Rows[] | .Data | length] | any(. != 1)' "$results" >/dev/null; then
    ok=0
    detail="$detail Data の個数=[$counts](期待 すべて 1)"
  fi
  if [ -n "$expect_rows" ]; then
    local actual_rows="$EVIDENCE_DIR/$no.rows"
    jq -j '[.ResultSet.Rows[] | (.Data | map(.VarCharValue // "") | join("\u0001"))] | join("\n")' "$results" >"$actual_rows"
    if ! cmp -s "$actual_rows" "$expect_rows"; then
      ok=0
      detail="$detail Rows の値が不一致(行数 $(jq '.ResultSet.Rows | length' "$results")、期待 $(($(tr -cd '\n' <"$expect_rows" | wc -c) + 1)) 行。diff: $actual_rows と $expect_rows)"
    fi
  fi

  # UpdateCount
  case "$expect_update" in
    -) ;;
    absent)
      if jq -e 'has("UpdateCount")' "$results" >/dev/null; then
        ok=0
        detail="$detail UpdateCount=$(jq -c '.UpdateCount' "$results")(期待 無し)"
      fi
      ;;
    *)
      local uc
      uc=$(jq -c 'if has("UpdateCount") then .UpdateCount else "無し" end' "$results")
      if [ "$uc" != "$expect_update" ]; then
        ok=0
        detail="$detail UpdateCount=$uc(期待 $expect_update)"
      fi
      ;;
  esac

  # .txt（MinIO から mc で取ってバイト単位で比べる）
  if [ -n "$expect_txt" ]; then
    local key="${PREFIX}/${id}.txt" got="$EVIDENCE_DIR/$no.txt"
    if ! mc_get "$key" "$got"; then
      ok=0
      detail="$detail .txt が無い"
    elif ! cmp -s "$got" "$expect_txt"; then
      ok=0
      detail="$detail .txt 不一致($(wc -c <"$got")B、期待 $(wc -c <"$expect_txt")B。od: $got.od.txt)"
      od -An -c "$got" >"$got.od.txt" 2>/dev/null || true
    else
      detail="$detail .txt 一致($(wc -c <"$got")B)"
    fi
  fi

  if [ "$ok" = "1" ]; then
    record "$label" PASS "${detail# } [id=$id]"
  else
    record "$label" FAIL "${detail# } [id=$id]"
  fi
}

# R1 の `.csv` を別に確かめる（check_case は `.txt` しか見ないため）。
check_csv() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5" expect_cols="$6" expect_rows="$7" expect_csv="$8"
  check_case "$no" "$name" "$sql" "$catalog" "$database" "$expect_cols" "$expect_rows" - ""
  local last=$((${#RESULT_STATUS[@]} - 1)) id key got
  id=$(jq -r '.QueryExecutionId // empty' "$EVIDENCE_DIR/$no.start.json" 2>/dev/null)
  [ -n "$id" ] || return
  key="${PREFIX}/${id}.csv"
  got="$EVIDENCE_DIR/$no.csv"
  if mc_get "$key" "$got" && cmp -s "$got" "$expect_csv"; then
    RESULT_DETAIL[last]="${RESULT_DETAIL[last]} .csv 一致($(wc -c <"$got")B)"
  else
    RESULT_STATUS[last]=FAIL
    RESULT_DETAIL[last]="${RESULT_DETAIL[last]} .csv 不一致(期待 $expect_csv、取得 $got)"
  fi
}

# 直前に record した結果に、追加の確かめの失敗を重ねる。
amend_last() {
  local status="$1" detail="$2" last=$((${#RESULT_STATUS[@]} - 1))
  [ "$status" = "FAIL" ] && RESULT_STATUS[last]=FAIL
  RESULT_DETAIL[last]="${RESULT_DETAIL[last]} $detail"
}

# E10: SHOW SCHEMAS の行にスキーマ名が素のまま含まれるか。
check_rows_contain() {
  local no="$1" want="$2" results="$EVIDENCE_DIR/$1.results.json"
  [ -f "$results" ] || return
  if jq -e --arg w "$want" '[.ResultSet.Rows[] | .Data[0].VarCharValue] | index($w) != null' "$results" >/dev/null 2>&1; then
    amend_last PASS "行に $want あり"
  else
    amend_last FAIL "行に $want が無い($(jq -c '[.ResultSet.Rows[] | .Data[0].VarCharValue]' "$results" 2>/dev/null | cut -c1-200))"
  fi
}

# E11: 完了後の GetQueryExecution の SubstatementType と、`.txt` の Content-Type。
check_view_extras() {
  local no="$1" id exec_json sub stat_json ct
  id=$(jq -r '.QueryExecutionId // empty' "$EVIDENCE_DIR/$no.start.json" 2>/dev/null)
  [ -n "$id" ] || return
  exec_json="$EVIDENCE_DIR/$no.get-execution.json"
  athena_call GetQueryExecution "$(jq -n --arg id "$id" '{QueryExecutionId: $id}')" >"$exec_json"
  sub=$(jq -r '.QueryExecution.SubstatementType // "無し"' "$exec_json")
  if [ "$sub" = "DESC_VIEW" ]; then
    amend_last PASS "SubstatementType=DESC_VIEW"
  else
    amend_last FAIL "SubstatementType=$sub(期待 DESC_VIEW)"
  fi
  stat_json=$(mc_stat "${PREFIX}/${id}.txt")
  ct=$(echo "$stat_json" | jq -r '.metadata["Content-Type"] // "無し"')
  if [ "$ct" = "binary/octet-stream" ]; then
    amend_last PASS "Content-Type=$ct"
  else
    amend_last FAIL "Content-Type=$ct(期待 binary/octet-stream)"
  fi
}

setup_tables() {
  local c19 c20 c21 c21_ice
  c21_ice=$(ice_wide_name)
  c19=$(name_of_len 19)
  c20=$(name_of_len 20)
  c21=$(name_of_len 21)
  trino_exec "CREATE SCHEMA hive.${SCHEMA}" hive default &&
    trino_exec "CREATE SCHEMA iceberg.${SCHEMA}" iceberg default &&
    trino_exec "CREATE SCHEMA memory.${SCHEMA}" memory default &&
    trino_exec "CREATE SCHEMA hive.${VIEW_SCHEMA}" hive default &&
    trino_exec "CREATE TABLE hive.${SCHEMA}.${T_PART} (n integer, p varchar) WITH (partitioned_by = ARRAY['p'])" hive "$SCHEMA" &&
    trino_exec "CREATE TABLE hive.${SCHEMA}.${T_CMT} (n integer COMMENT 'a${TAB}b', m integer)" hive "$SCHEMA" &&
    trino_exec "CREATE TABLE hive.${SCHEMA}.${T_WIDE} (${c19} varchar, ${c20} varchar, ${c21} varchar)" hive "$SCHEMA" &&
    trino_exec "CREATE TABLE iceberg.${SCHEMA}.${T_ICE} (n integer)" iceberg "$SCHEMA" &&
    trino_exec "CREATE TABLE iceberg.${SCHEMA}.${T_ICEP} (n integer COMMENT 'abc', s varchar, ts timestamp(6), d decimal(10,2), arr array(varchar), st row(\"a\" integer), ${c21_ice} bigint) WITH (partitioning = ARRAY['s', 'bucket(n, 4)', 'day(ts)'])" iceberg "$SCHEMA" &&
    trino_exec "CREATE TABLE iceberg.${SCHEMA}.${T_ICET} (n integer, s varchar, ts timestamp(6), d2 date, ts2 timestamp(6), t_double double, t_float real, t_boolean boolean, t_binary varbinary, t_map map(varchar, integer), big bigint) WITH (partitioning = ARRAY['year(ts)', 'month(d2)', 'hour(ts2)', 'truncate(s, 3)'])" iceberg "$SCHEMA" &&
    trino_exec "CREATE VIEW hive.${VIEW_SCHEMA}.${T_VIEW} AS SELECT 1 AS n, 'a' AS s" hive "$VIEW_SCHEMA"
}

main() {
  log "証跡の保存先: $EVIDENCE_DIR"
  log "compose プロジェクト: ${COMPOSE_PROJECT_NAME:-athena-local}"

  if ! build_expectations; then
    record "期待値の組み立て" FAIL "規則から組んだバイト数が実測値と合わない（$EXPECT_DIR）"
    return 1
  fi
  record "期待値の組み立て" PASS "$EXPECT_DIR"

  log "docker compose down -v / up -d ${SERVICES[*]}"
  if ! "${COMPOSE[@]}" down -v "${SERVICES[@]}" >/dev/null 2>&1; then
    record "compose起動" FAIL "docker compose down -v ${SERVICES[*]} が失敗した"
    return 1
  fi
  if ! "${COMPOSE[@]}" up -d "${SERVICES[@]}"; then
    record "compose起動" FAIL "docker compose up -d ${SERVICES[*]} が失敗した"
    return 1
  fi
  if ! mc alias set local "$MINIO_ENDPOINT" minioadmin minioadmin >/dev/null; then
    record "MinIOバケット" FAIL "mc alias set が失敗した（minio:9000 に繋がらない）"
    return 1
  fi
  if ! wait_for_trino; then
    record "Trino起動" FAIL "Trino が起動しなかった"
    return 1
  fi
  if ! wait_for_bucket; then
    record "MinIOバケット" FAIL "バケット $BUCKET の用意ができなかった"
    return 1
  fi

  if ! setup_tables; then
    record "セットアップ" FAIL "Trino でスキーマかテーブルが作れなかった"
    return 1
  fi
  record "セットアップ" PASS "hive.${SCHEMA}.{${T_PART},${T_CMT},${T_WIDE}}、hive.${VIEW_SCHEMA}.${T_VIEW}、iceberg.${SCHEMA}.{${T_ICE},${T_ICEP},${T_ICET}}、memory.${SCHEMA}"

  if ! build_athena_local; then
    record "cargo build" FAIL "ビルドが失敗した（$BUILD_LOG）"
    return 1
  fi
  record "cargo build" PASS "$BINARY"
  if ! start_athena_local; then
    record "athena-local起動" FAIL "athena-local が起動しなかった（$ATHENA_LOG）"
    return 1
  fi
  record "athena-local起動" PASS "$ATHENA_BASE"

  local STR="string|0|false"

  check_case E1 "SHOW_TABLES" "SHOW TABLES IN hive.${SCHEMA}" hive "$SCHEMA" \
    "tab_name|$STR" "$EXPECT_DIR/E1.txt" 0 "$EXPECT_DIR/E1.txt"

  local DESC_COLS="col_name|$STR,data_type|$STR,comment|$STR"
  check_case E2 "DESCRIBE_hive_パーティション付き" "DESCRIBE ${T_PART}" hive "$SCHEMA" \
    "$DESC_COLS" "$EXPECT_DIR/E2.txt" absent "$EXPECT_DIR/E2.txt"
  check_case E3 "DESCRIBE_hive_コメントにタブ" "DESCRIBE ${T_CMT}" hive "$SCHEMA" \
    "$DESC_COLS" "$EXPECT_DIR/E3.txt" absent "$EXPECT_DIR/E3.txt"
  check_case E4a "DESCRIBE_hive_列名19_20_21文字" "DESCRIBE ${T_WIDE}" hive "$SCHEMA" \
    "$DESC_COLS" "$EXPECT_DIR/E4a.txt" absent "$EXPECT_DIR/E4a.txt"
  check_case E4b "SHOW_COLUMNS_hive_列名19_20_21文字" "SHOW COLUMNS FROM ${T_WIDE}" hive "$SCHEMA" \
    "field|$STR" "$EXPECT_DIR/E4b.txt" 0 "$EXPECT_DIR/E4b.txt"
  check_case E5 "DESCRIBE_iceberg" "DESCRIBE ${T_ICE}" iceberg "$SCHEMA" \
    "$DESC_COLS" "$EXPECT_DIR/E5.txt" 0 "$EXPECT_DIR/E5.txt"

  check_case E6a "SHOW_COLUMNS_FROM_hive" "SHOW COLUMNS FROM ${T_PART}" hive "$SCHEMA" \
    "field|$STR" "$EXPECT_DIR/E6-hive.txt" 0 "$EXPECT_DIR/E6-hive.txt"
  check_case E6b "SHOW_COLUMNS_IN_hive" "SHOW COLUMNS IN ${T_PART}" hive "$SCHEMA" \
    "field|$STR" "$EXPECT_DIR/E6-hive.txt" 0 "$EXPECT_DIR/E6-hive.txt"
  check_case E6c "SHOW_COLUMNS_FROM_iceberg" "SHOW COLUMNS FROM ${T_ICE}" iceberg "$SCHEMA" \
    "field|$STR" "$EXPECT_DIR/E6-iceberg.txt" 0 "$EXPECT_DIR/E6-iceberg.txt"

  check_case E7 "DESCRIBE_iceberg_パーティション付き" "DESCRIBE ${T_ICEP}" iceberg "$SCHEMA" \
    "$DESC_COLS" "$EXPECT_DIR/E7.txt" 0 "$EXPECT_DIR/E7.txt"
  check_case E8 "DESCRIBE_iceberg_変換4種" "DESCRIBE ${T_ICET}" iceberg "$SCHEMA" \
    "$DESC_COLS" "$EXPECT_DIR/E8.txt" 0 "$EXPECT_DIR/E8.txt"
  check_case E9 "DESC_hive_パーティション付き" "DESC ${T_PART}" hive "$SCHEMA" \
    "$DESC_COLS" "$EXPECT_DIR/E2.txt" absent "$EXPECT_DIR/E2.txt"
  # compose の Trino（482）の hive／iceberg はファイルのメタストアで、作ったスキーマが SHOW SCHEMAS にも
  # information_schema.schemata にも出ない（2026-09-24 に athena173 の Trino で確認）。作ったスキーマが出る memory で見る。
  check_case E10 "SHOW_SCHEMAS" "SHOW SCHEMAS" memory "$SCHEMA" \
    "database_name|$STR" "" 0 ""
  check_rows_contain E10 "$SCHEMA"

  local VIEW_COLS="column|varchar|0|false,type|varchar|0|false"
  check_case E11a "DESCRIBE_ビュー" "DESCRIBE ${T_VIEW}" hive "$VIEW_SCHEMA" \
    "$VIEW_COLS" "$EXPECT_DIR/E11.txt" 0 "$EXPECT_DIR/E11.txt"
  check_view_extras E11a
  check_case E11b "SHOW_COLUMNS_ビュー" "SHOW COLUMNS FROM ${T_VIEW}" hive "$VIEW_SCHEMA" \
    "$VIEW_COLS" "$EXPECT_DIR/E11.txt" 0 "$EXPECT_DIR/E11.txt"
  check_view_extras E11b

  # 回帰: SELECT は列名行ありのまま、SHOW CREATE TABLE は #161 の固定列のまま（行の中身は Trino の DDL なので見ない）
  check_csv R1 "SELECT_1_AS_n" "SELECT 1 AS n" hive "$SCHEMA" \
    "n|integer|10|false" "$EXPECT_DIR/R1.rows" "$EXPECT_DIR/R1.csv"
  check_case R2 "SHOW_CREATE_TABLE_hive" "SHOW CREATE TABLE ${T_PART}" hive "$SCHEMA" \
    "createtab_stmt|$STR" "" - ""

  return 0
}

main
