#!/usr/bin/env bash
# issue #275 の実機検証の足場（tools/e2e/utility-rows/verify.sh・tools/e2e/context-catalog/verify.sh・
# tools/e2e/block-comment/verify.sh を雛形にした）。
#
# #275 は、名前のある DESCRIBE EXTENDED／FORMATTED（と、その後ろの列 1 つ・PARTITION (...)）を本物どおり
# 実行し、GetQueryExecution の Query から Database を落とす（今の athena-local は、これらの形をすべて
# 開始時の構文チェックで 400 にしている。名前無しの DESCRIBE EXTENDED だけは entity_check が EXTENDED を
# 表の名前と読んで Entity Not Found にする。#242）。
#
# この足場は compose のローカル Trino（hive・iceberg カタログ）にスキーマ 1 つ（両カタログに同名で作る）を
# 用意し、Hive 表 h（n int, s varchar COMMENT 'the s column'）・パーティション付き Hive 表 hp（n int, p
# varchar, partitioned_by p, 1 行 p='x'）・Iceberg 表 i（n int, p varchar, partitioning p）・ビュー v
# （SELECT 1 AS n）を作る。athena-local には Context の Database をこのスキーマにし、名前は <db>.<t> の
# 2 部で書いて投げる（DB を落とす規則を確かめるため）。本物の AWS には投げない（compose の trino だけ）。
#
# DB を落とす既存の書き換え（reported_query::drop_database、#242）は、Context の Catalog が
# `AwsDataCatalog`（大文字小文字によらない）か省略のときだけ動く（docs/api.md の「Real Athena rewrites」節）。
# hive 表と iceberg 表を同じ実行で両方確かめたいが、TRINO_CATALOG_MAP の AwsDataCatalog の別名は 1 プロセス
# に 1 つしか持てないので、athena-local を 2 つ起動する（tools/e2e/context-catalog/verify.sh の系統 A と同じ
# 手筋）: 系統 H は TRINO_CATALOG_MAP=AwsDataCatalog=hive（h・hp・v が対象）、系統 I は
# TRINO_CATALOG_MAP=AwsDataCatalog=iceberg（i が対象）。どちらの StartQueryExecution も
# QueryExecutionContext.Catalog に文字どおり `AwsDataCatalog` を渡す。
#
# 期待値は実測の生データ（$HOME/athena-describe-extended-measurements/）を読まず、issue #275 のケース表
# （2026-09-27 実測の規則）から printf で組み立てる。組み立てに使う規則:
#   Hive の行           : `<列名 %-20s>\t<型 %-20s>\t<コメント。%-20s に詰めてから先頭のタブの手前まで>`
#                          （tools/e2e/utility-rows/verify.sh の hive_describe_row と同じ）。
#   空行（n 列）         : `\t ` を (n-1) 回（先頭の空文字の欄を除き、残りの欄はどれも空白 1 個）。
#   パーティション見出し : 空行(3)・`# Partition Information` に空行(3) を続けたもの・
#                          `# col_name`（22 桁）\t`data_type`（20 桁）\t`comment`（20 桁）・空行(3)
#                          （EXTENDED の DESCRIBE 側。utility-rows の hive_partition_heading_rows と同じ形）。
#   FORMATTED の見出し   : `# col_name`（22 桁）\t 残り 20 桁詰めの列名を並べたもの（3 列か、列指定なら 11 列:
#                          data_type・min・max・num_nulls・distinct_count・avg_col_len・max_col_len・
#                          num_trues・num_falses・comment）。
#   Iceberg の DESCRIBE  : 詰め無し。`# Table schema:\t\t`・`# col_name\tdata_type\tcomment`・
#                          `<列>\t<型>\t<コメント>`・空行 `\t\t`・`# Partition spec:\t\t`・
#                          `# field_name\tfield_transform\tcolumn_name`・`<列>\tidentity\t<列>`。
#   後半（Detailed Table/Partition Information・Storage Information・View Information など）は athena-local
#   が一部の行を省く設計のため、足場では完全一致を見ない。見るのは (a) 列の部分（上の規則で組む行）の完全一致、
#   (b) 後半の見出しの行が含まれること、の 2 つだけ（ケース表の「を含む」「で始まる」の指示に従う）。
#
# 実装前（#275 着手前の main）の athena-local で流すと、名前のある EXTENDED／FORMATTED はどれも Trino の
# 構文に無い形として開始時に 400 になる（列指定・PARTITION 指定を含む）ので、新しいケース（E*・F*・C*・P*・
# X*・Q*）はすべて FAIL になるはず。回帰の R1（名前無しの DESCRIBE EXTENDED。entity_check の Entity Not
# Found で 400）・R2（プレーンな DESCRIBE。既存のまま成功）は変更の前後で変わらず PASS のはず。
#
# 前提コマンド: tools/dev.sh 経由で動かす（toolbox に全部入っている）
#
# 使い方:
#   COMPOSE_PROJECT_NAME=athena-local-275 tools/dev.sh tools/e2e/describe-extended/verify.sh
#
# 環境変数:
#   KEEP_UP=1        テスト後に docker compose down -v <サービス...> をせず環境を残す（デバッグ用）
#   SKIP_BUILD=1     cargo build を省略し、既存の $CARGO_TARGET_DIR の release/athena-local をそのまま使う
#
# 後始末は本スクリプトの trap が行う: athena-local を 2 つ止め、Trino のスキーマ（hive・iceberg 両カタログ）
# を DROP SCHEMA ... CASCADE で消し（KEEP_UP=1 でなければ）docker compose down -v <このスクリプトが使った
# サービス> する。終了コードは結果表の FAIL の件数を数え、1 件でもあれば 1（GATE 行は数えない）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BINARY="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/athena-local"
COMPOSE=(docker compose -f "$REPO_ROOT/compose.yml")
SERVICES=(trino minio minio-init)

TRINO_BASE="http://trino:8080"
MINIO_ENDPOINT="http://minio:9000"
BUCKET="athena-results"
PREFIX="e2e275"
OUTPUT_LOCATION="s3://${BUCKET}/${PREFIX}/"
SCHEMA="e2e275"

# フィクスチャの名前（ケース表そのまま）。
H="h"
HP="hp"
ICE="i"
VIEWT="v"

# 系統 H（TRINO_CATALOG_MAP=AwsDataCatalog=hive。h・hp・v が対象）。
ATHENA_BIND_H="127.0.0.1:8190"
BASE_H="http://${ATHENA_BIND_H}"
# 系統 I（TRINO_CATALOG_MAP=AwsDataCatalog=iceberg。i が対象）。
ATHENA_BIND_I="127.0.0.1:8191"
BASE_I="http://${ATHENA_BIND_I}"

EVIDENCE_DIR="$(mktemp -d /tmp/athena-local-issue275-e2e.XXXXXX)"
ATHENA_LOG_H="$EVIDENCE_DIR/athena-local-h.log"
ATHENA_LOG_I="$EVIDENCE_DIR/athena-local-i.log"
BUILD_LOG="$EVIDENCE_DIR/cargo-build.log"
EXPECT_DIR="$EVIDENCE_DIR/expect"
mkdir -p "$EXPECT_DIR"

ATHENA_PID_H=""
ATHENA_PID_I=""

declare -a RESULT_NAMES=()
declare -a RESULT_STATUS=()
declare -a RESULT_DETAIL=()

# run_and_wait / athena_start_raw が書く直近の値。
LAST_ID=""
LAST_EXEC_JSON=""
LAST_START_CODE=""
LAST_START_BODY=""

# GATE（わざと壊す自己確認）用に、R2 の実行結果を退避する。
R2_ID=""
R2_EXEC_JSON=""

log() { echo "[verify] $*" >&2; }

record() {
  RESULT_NAMES+=("$1")
  RESULT_STATUS+=("$2")
  RESULT_DETAIL+=("$3")
}

# 直前に record した 1 件を配列から取り除く（GATE の自己確認専用。本来の PASS/FAIL の集計に混ぜない）。
LAST_POPPED_STATUS=""
pop_result() {
  local idx=$((${#RESULT_STATUS[@]} - 1))
  LAST_POPPED_STATUS="${RESULT_STATUS[$idx]}"
  unset "RESULT_NAMES[$idx]" "RESULT_STATUS[$idx]" "RESULT_DETAIL[$idx]"
}

print_table() {
  echo
  echo "==================== 結果 ===================="
  local i
  for i in "${!RESULT_NAMES[@]}"; do
    printf "%-6s %-46s %s\n" "${RESULT_STATUS[$i]}" "${RESULT_NAMES[$i]}" "${RESULT_DETAIL[$i]}"
  done
  echo "================================================"
  local pass=0 fail=0 other=0
  local -a failed=()
  for i in "${!RESULT_STATUS[@]}"; do
    case "${RESULT_STATUS[$i]}" in
      PASS) pass=$((pass + 1)) ;;
      FAIL) fail=$((fail + 1)); failed+=("${RESULT_NAMES[$i]}") ;;
      *) other=$((other + 1)) ;;
    esac
  done
  echo "PASS=$pass FAIL=$fail その他=$other"
  if [ "$fail" -gt 0 ]; then
    echo "FAIL の一覧:"
    for i in "${failed[@]}"; do echo "  - $i"; done
  fi
  echo "証跡: $EVIDENCE_DIR"
  [ "$fail" -eq 0 ]
}

cleanup() {
  local status=$?
  if [ -n "$ATHENA_PID_H" ] && kill -0 "$ATHENA_PID_H" 2>/dev/null; then
    log "athena-local 系統H (PID $ATHENA_PID_H) を止める"
    kill "$ATHENA_PID_H" 2>/dev/null || true
    wait "$ATHENA_PID_H" 2>/dev/null || true
  fi
  if [ -n "$ATHENA_PID_I" ] && kill -0 "$ATHENA_PID_I" 2>/dev/null; then
    log "athena-local 系統I (PID $ATHENA_PID_I) を止める"
    kill "$ATHENA_PID_I" 2>/dev/null || true
    wait "$ATHENA_PID_I" 2>/dev/null || true
  fi

  log "Trino のスキーマ $SCHEMA を消す（無ければ何もしない）"
  trino_exec "DROP SCHEMA IF EXISTS hive.${SCHEMA} CASCADE" hive default >/dev/null 2>&1 || true
  trino_exec "DROP SCHEMA IF EXISTS iceberg.${SCHEMA} CASCADE" iceberg default >/dev/null 2>&1 || true

  if [ "${KEEP_UP:-0}" = "1" ]; then
    log "KEEP_UP=1 のため環境を残す"
  else
    log "docker compose down -v ${SERVICES[*]}"
    "${COMPOSE[@]}" down -v "${SERVICES[@]}" >/dev/null 2>&1
  fi
  print_table
  local table_status=$?
  [ "$status" -eq 0 ] && status=$table_status
  exit "$status"
}
trap cleanup EXIT

# --- Trino への直接アクセス（セットアップ・後始末専用） ---

trino_exec() {
  local sql="$1" catalog="$2" schema="$3"
  local resp next
  resp=$(curl -sf -X POST "$TRINO_BASE/v1/statement" \
    -H "X-Trino-User: e2e-275-setup" \
    -H "X-Trino-Catalog: $catalog" \
    -H "X-Trino-Schema: $schema" \
    -H "X-Trino-Client-Capabilities: PARAMETRIC_DATETIME" \
    --data-binary "$sql")
  while true; do
    if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
      log "trino_exec 失敗: $sql"
      echo "$resp" | jq '.error' >&2
      return 1
    fi
    next=$(echo "$resp" | jq -r '.nextUri // empty')
    [ -z "$next" ] && break
    resp=$(curl -sf "$next")
  done
  return 0
}

wait_for_trino() {
  log "Trino の起動待ち ($TRINO_BASE)"
  for _ in $(seq 1 60); do
    if trino_exec "SELECT 1" system runtime >/dev/null 2>&1; then
      log "Trino 起動確認"
      return 0
    fi
    sleep 2
  done
  log "Trino が起動しなかった"
  return 1
}

wait_for_bucket() {
  log "MinIO バケットの用意待ち"
  for _ in $(seq 1 60); do
    if mc ls "local/$BUCKET" >/dev/null 2>&1; then
      log "バケット確認: $BUCKET"
      return 0
    fi
    sleep 2
  done
  log "バケットの用意ができなかった"
  return 1
}

# --- athena-local 起動（系統 H・系統 I の 2 本） ---

build_athena_local() {
  if [ "${SKIP_BUILD:-0}" = "1" ]; then
    log "SKIP_BUILD=1 のため cargo build を省略する"
    [ -x "$BINARY" ] && return 0
    log "$BINARY が無い"
    return 1
  fi

  log "cargo build --release --locked を実行する（他エージェントの target ロックで待たされることがある）"
  if (cd "$REPO_ROOT" && cargo build --release --locked) >"$BUILD_LOG" 2>&1; then
    log "ビルド成功"
    return 0
  fi

  log "ビルド失敗。ログ: $BUILD_LOG（末尾 40 行）"
  tail -n 40 "$BUILD_LOG" >&2
  return 1
}

# 引数: 1 bind、2 TRINO_CATALOG_MAP の値、3 ログの置き場所、4 起動した PID を書き込む変数名。
start_athena_local() {
  local bind="$1" catalog_map="$2" athena_log="$3" pid_var="$4"
  log "athena-local を起動する（bind=$bind, TRINO_CATALOG_MAP=$catalog_map, ログ: $athena_log）"
  (
    cd "$REPO_ROOT"
    exec env \
      ATHENA_LOCAL_BIND="$bind" \
      TRINO_URL="$TRINO_BASE" \
      TRINO_USER="athena-local-e2e275" \
      TRINO_CATALOG_MAP="$catalog_map" \
      ATHENA_LOCAL_RESULTS="s3" \
      AWS_ENDPOINT_URL_S3="$MINIO_ENDPOINT" \
      AWS_ACCESS_KEY_ID="minioadmin" \
      AWS_SECRET_ACCESS_KEY="minioadmin" \
      ATHENA_LOCAL_OUTPUT_LOCATION="$OUTPUT_LOCATION" \
      "$BINARY"
  ) >"$athena_log" 2>&1 &
  local pid=$!
  printf -v "$pid_var" '%s' "$pid"

  log "athena-local (http://$bind) の起動待ち"
  local _ status
  for _ in $(seq 1 30); do
    if ! kill -0 "$pid" 2>/dev/null; then
      log "athena-local が異常終了した。ログ:"
      cat "$athena_log" >&2
      return 1
    fi
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://$bind/" \
      -H "X-Amz-Target: AmazonAthena.ListWorkGroups" \
      -H "Content-Type: application/x-amz-json-1.1" \
      --data-binary '{}')
    if [ "$status" = "200" ]; then
      log "athena-local ($bind) 起動確認"
      return 0
    fi
    sleep 1
  done
  log "athena-local ($bind) が応答しなかった"
  return 1
}

# --- athena-local の Athena API 呼び出し（$1 がベース URL） ---

athena_call() {
  local base="$1" operation="$2" body="$3"
  curl -s -X POST "$base/" \
    -H "X-Amz-Target: AmazonAthena.$operation" \
    -H "Content-Type: application/x-amz-json-1.1" \
    --data "$body"
}

jqx() { echo "$1" | jq -r "$2"; }

athena_start_raw() {
  local base="$1" sql="$2" catalog="$3" database="$4"
  local body resp
  body=$(jq -cn --arg sql "$sql" --arg cat "$catalog" --arg db "$database" --arg token "$(uuidgen)" \
    '{QueryString: $sql, QueryExecutionContext: {Catalog: $cat, Database: $db}, ClientRequestToken: $token}')
  resp=$(curl -s -w '\n%{http_code}' -X POST "$base/" \
    -H "X-Amz-Target: AmazonAthena.StartQueryExecution" \
    -H "Content-Type: application/x-amz-json-1.1" \
    --data-binary "$body")
  LAST_START_CODE="${resp##*$'\n'}"
  LAST_START_BODY="${resp%$'\n'*}"
}

athena_wait() {
  local base="$1" id="$2" resp state
  for _ in $(seq 1 150); do
    resp=$(athena_call "$base" GetQueryExecution "$(jq -cn --arg id "$id" '{QueryExecutionId: $id}')")
    state=$(echo "$resp" | jq -r '.QueryExecution.Status.State // empty')
    if [ -n "$state" ] && [ "$state" != "QUEUED" ] && [ "$state" != "RUNNING" ]; then
      echo "$resp"
      return 0
    fi
    sleep 0.2
  done
  echo "$resp"
  return 1
}

# StartQueryExecution → 終端まで待つ。開始できなければ LAST_ID を空のままにする。
run_and_wait() {
  local base="$1" sql="$2" catalog="$3" database="$4"
  athena_start_raw "$base" "$sql" "$catalog" "$database"
  LAST_ID=$(echo "$LAST_START_BODY" | jq -r '.QueryExecutionId // empty')
  if [ -z "$LAST_ID" ]; then
    LAST_EXEC_JSON=""
    return
  fi
  LAST_EXEC_JSON=$(athena_wait "$base" "$LAST_ID")
}

# --- S3（MinIO）側の確認（toolbox の mc で minio:9000 を直接見る。#129） ---

mc_stat() {
  local key="$1" name raw
  name=$(basename "$key")
  raw=$(mc stat --json "local/$BUCKET/$key" 2>/dev/null)
  if [ -z "$raw" ]; then
    echo '{"status":"error"}'
    return
  fi
  echo "$raw" | jq -s --arg name "$name" '
    map(select(.name == $name and (.status // "success") == "success"))
    | if length > 0 then .[0] else {"status":"error"} end
  '
}

mc_exists() {
  local stat_json="$1"
  [ -n "$stat_json" ] && ! echo "$stat_json" | jq -e '.status == "error"' >/dev/null 2>&1
}

mc_get() {
  local key="$1" out="$2"
  mc cat "local/$BUCKET/$key" >"$out" 2>/dev/null
}

# --- 期待値の組み立て（ケース表の規則を式で表す。printf のみ、実測の生データは読まない） ---

TAB=$'\t'

# Hive の DESCRIBE の 1 行（utility-rows の hive_describe_row と同じ規則）。
hive_row() {
  local name="$1" type="$2" comment="$3" padded
  padded=$(printf '%-20s' "$comment")
  printf '%-20s\t%-20s\t%s' "$name" "$type" "${padded%%"$TAB"*}"
}

# n 列の空行（先頭の欄は空文字、残りの欄はどれも空白 1 個。utility-rows の hive_partition_heading_rows の
# 空行と同じ形）。
empty_row() {
  local n="$1" i out=""
  for ((i = 1; i < n; i++)); do out+=$'\t '; done
  printf '%s' "$out"
}

# EXTENDED の DESCRIBE のパーティション見出し 3 列（col_name は 22 桁）。
header3() {
  printf '%-22s\t%-20s\t%-20s' "# col_name" "data_type" "comment"
}

# FORMATTED の列指定（DESCRIBE FORMATTED <t> <col>）の見出し 11 列。
header11() {
  local out f
  out=$(printf '%-22s' "# col_name")
  for f in data_type min max num_nulls distinct_count avg_col_len max_col_len num_trues num_falses comment; do
    out+="${TAB}$(printf '%-20s' "$f")"
  done
  printf '%s' "$out"
}

# C2 の n の行（col_name/data_type を詰め、中間 8 欄は空白 20 個、最後は comment "from deserializer"）。
row11_n() {
  local out i
  out=$(printf '%-20s\t%-20s' n int)
  for i in 1 2 3 4 5 6 7 8; do
    out+="${TAB}$(printf '%-20s' '')"
  done
  out+="${TAB}$(printf '%-20s' 'from deserializer')"
  printf '%s' "$out"
}

# 行の配列を \n で連結してファイルに書く（末尾改行なし）。
write_lines() {
  local file="$1"
  shift
  local IFS=$'\n'
  printf '%s' "$*" >"$file"
}

DTI3="# Detailed Table Information$(empty_row 3)"
SI3="# Storage Information$(empty_row 3)"
DPI3="# Detailed Partition Information$(empty_row 3)"
# 先頭（write_lines で末尾改行なし）の直後は改行から始まる。
DTI_PREFIX=$'\n'"Detailed Table Information${TAB}"
DPI_PREFIX=$'\n'"Detailed Partition Information${TAB}"

build_expectations() {
  # E1 / Q1 / Q3: h の EXTENDED（n・s の 2 行）。
  write_lines "$EXPECT_DIR/E1.head" "$(hive_row n int '')" "$(hive_row s string 'the s column')" "$(empty_row 3)"

  # E2 / P1: hp の EXTENDED（n・p の 2 行、パーティション見出し 4 行、p の行、空行）。
  write_lines "$EXPECT_DIR/E2.head" \
    "$(hive_row n int '')" \
    "$(hive_row p string '')" \
    "$(empty_row 3)" \
    "# Partition Information$(empty_row 3)" \
    "$(header3)" \
    "$(empty_row 3)" \
    "$(hive_row p string '')" \
    "$(empty_row 3)"
  cp "$EXPECT_DIR/E2.head" "$EXPECT_DIR/P1.head"

  # E3: v の EXTENDED（n の行、空行）。
  write_lines "$EXPECT_DIR/E3.head" "$(hive_row n int '')" "$(empty_row 3)"

  # F1: h の FORMATTED（見出し・空行・n・s の行・空行）。
  write_lines "$EXPECT_DIR/F1.head" \
    "$(header3)" "$(empty_row 3)" "$(hive_row n int '')" "$(hive_row s string 'the s column')" "$(empty_row 3)"

  # F2 / Q2 用の h の FORMATTED と同じ見出し・空行・n の行（hp は列だけ n）。
  write_lines "$EXPECT_DIR/F2.head" "$(header3)" "$(empty_row 3)" "$(hive_row n int '')"
  write_lines "$EXPECT_DIR/F3.head" "$(header3)" "$(empty_row 3)" "$(hive_row n int '')"

  # F4: i の FORMATTED（詰め無しの 8 行。その後に空行 `\t\t` と `Name:\ticeberg.<db>.<t>\t` が続く）。
  write_lines "$EXPECT_DIR/F4.head" \
    "# Table schema:${TAB}${TAB}" \
    "# col_name${TAB}data_type${TAB}comment" \
    "n${TAB}int${TAB}" \
    "p${TAB}string${TAB}" \
    "${TAB}${TAB}" \
    "# Partition spec:${TAB}${TAB}" \
    "# field_name${TAB}field_transform${TAB}column_name" \
    "p${TAB}identity${TAB}p"

  # C1: h の EXTENDED n（1 行、完全一致）。
  write_lines "$EXPECT_DIR/C1.head" "$(hive_row n int 'from deserializer')"

  # C2: h の FORMATTED n（見出し 11 列・空行 11 列・n の行、完全一致）。
  write_lines "$EXPECT_DIR/C2.head" "$(header11)" "$(empty_row 11)" "$(row11_n)"

  # C3: i の DESCRIBE n（1 行、完全一致）。
  write_lines "$EXPECT_DIR/C3.head" "n${TAB}int${TAB}"

  # R2（回帰）: h のプレーンな DESCRIBE（n・s の 2 行、完全一致）。
  write_lines "$EXPECT_DIR/R2.head" "$(hive_row n int '')" "$(hive_row s string 'the s column')"
}

# --- 判定（成功） ---

STR="string|0|false"
COLS3="col_name|$STR,data_type|$STR,comment|$STR"
COLS11="col_name|$STR,data_type|$STR,min|$STR,max|$STR,num_nulls|$STR,distinct_count|$STR,avg_col_len|$STR,max_col_len|$STR,num_trues|$STR,num_falses|$STR,comment|$STR"

# 直近に見る「後半に含まれるべき文字列」の一覧。呼び出し側がケースごとに詰め替える。
CONTAINS=()

# id・exec_json が既にある前提で検証する（GATE の自己確認から直接呼べるように run とは分離してある）。
#   head_file: 先頭からの完全一致（空文字なら先頭チェックを省く）
#   tail_mode: exact（head の後に何も無い）／prefix（head の後が tail_prefix で始まる）／
#              contains-only（head の後は見ず CONTAINS だけ見る）
do_check_success() {
  local no="$1" name="$2" id="$3" exec_json="$4"
  local expect_query="$5" expect_ctxdb="$6" expect_ct="$7" expect_update="$8" expect_cols="$9"
  shift 9
  local head_file="$1" tail_mode="$2" tail_prefix="${3:-}"
  local ok=1 diff=""

  local got_state
  got_state=$(jqx "$exec_json" '.QueryExecution.Status.State // "無し"')
  if [ "$got_state" != "SUCCEEDED" ]; then
    local reason
    reason=$(jqx "$exec_json" '.QueryExecution.Status.StateChangeReason // "無し"')
    record "$no $name" FAIL "State=$got_state(期待 SUCCEEDED) reason=$reason [id=$id]"
    return
  fi

  local got_query got_ctxdb got_stmt got_substmt
  got_query=$(jqx "$exec_json" '.QueryExecution.Query // "無し"')
  got_ctxdb=$(jqx "$exec_json" '.QueryExecution.QueryExecutionContext.Database // "無し"')
  got_stmt=$(jqx "$exec_json" '.QueryExecution.StatementType // "無し"')
  got_substmt=$(jqx "$exec_json" '.QueryExecution.SubstatementType // "無し"')
  [ "$got_query" = "$expect_query" ] || { ok=0; diff="$diff Query=\"$got_query\"(期待 \"$expect_query\")"; }
  [ "$got_ctxdb" = "$expect_ctxdb" ] || { ok=0; diff="$diff Context.Database=$got_ctxdb(期待 $expect_ctxdb)"; }
  [ "$got_stmt" = "UTILITY" ] || { ok=0; diff="$diff StatementType=$got_stmt(期待 UTILITY)"; }
  [ "$got_substmt" = "DESCRIBE_TABLE" ] || { ok=0; diff="$diff SubstatementType=$got_substmt(期待 DESCRIBE_TABLE)"; }

  local results cols upd
  results=$(athena_call "$BASE_FOR_RESULTS" GetQueryResults "$(jq -n --arg id "$id" '{QueryExecutionId: $id}')")
  cols=$(echo "$results" | jq -r '[.ResultSet.ResultSetMetadata.ColumnInfo[] | "\(.Name)|\(.Type)|\(.Precision)|\(.CaseSensitive)"] | join(",")' 2>/dev/null)
  [ "$cols" = "$expect_cols" ] || { ok=0; diff="$diff ColumnInfo=[$cols](期待 [$expect_cols])"; }
  upd=$(echo "$results" | jq -c 'if has("UpdateCount") then .UpdateCount else "無し" end' 2>/dev/null)
  case "$expect_update" in
    absent) [ "$upd" = '"無し"' ] || { ok=0; diff="$diff UpdateCount=$upd(期待 無し)"; } ;;
    *) [ "$upd" = "$expect_update" ] || { ok=0; diff="$diff UpdateCount=$upd(期待 $expect_update)"; } ;;
  esac

  local key="${PREFIX}/${id}.txt" got="$EVIDENCE_DIR/$no.txt"
  if ! mc_get "$key" "$got"; then
    ok=0
    diff="$diff .txtが無い"
  else
    local actual
    actual=$(cat "$got")
    if [ -n "$head_file" ]; then
      local head_expected hlen ahead rest
      head_expected=$(cat "$head_file")
      hlen=${#head_expected}
      ahead="${actual:0:$hlen}"
      if [ "$ahead" != "$head_expected" ]; then
        ok=0
        diff="$diff 先頭が不一致(got=$got, expect=$head_file)"
      fi
      rest="${actual:$hlen}"
      case "$tail_mode" in
        exact) [ -z "$rest" ] || { ok=0; diff="$diff 先頭より後に余分な内容がある(${#rest}バイト)"; } ;;
        prefix) [[ "$rest" == "$tail_prefix"* ]] || { ok=0; diff="$diff 続きが「$tail_prefix」で始まらない"; } ;;
        contains-only) : ;;
        *) ok=0; diff="$diff 未知の tail_mode=$tail_mode" ;;
      esac
    fi
    local c
    for c in "${CONTAINS[@]}"; do
      [[ "$actual" == *"$c"* ]] || { ok=0; diff="$diff 「$c」を含まない"; }
    done
  fi

  local ct
  ct=$(mc_stat "$key" | jq -r '.metadata["Content-Type"] // "無し"')
  [ "$ct" = "$expect_ct" ] || { ok=0; diff="$diff Content-Type=$ct(期待 $expect_ct)"; }

  if ! mc_exists "$(mc_stat "${key}.metadata")"; then
    ok=0
    diff="$diff .metadataが無い"
  fi

  if [ "$ok" = "1" ]; then
    record "$no $name" PASS "${diff# } [id=$id]"
  else
    record "$no $name" FAIL "${diff# } [id=$id]"
  fi
}

check_success() {
  local no="$1" name="$2" sql="$3" base="$4" database="$5"
  shift 5
  BASE_FOR_RESULTS="$base"
  run_and_wait "$base" "$sql" "AwsDataCatalog" "$database"
  if [ -z "$LAST_ID" ]; then
    record "$no $name" FAIL "開始できなかった(SUCCEEDED を期待): code=$LAST_START_CODE body=$(echo "$LAST_START_BODY" | tr -d '\n' | cut -c1-200)"
    return
  fi
  do_check_success "$no" "$name" "$LAST_ID" "$LAST_EXEC_JSON" "$@"
}

# Q1〜Q3: SUCCEEDED であることと Query の文言だけを見る（ケース表の指示どおり）。
check_query_only() {
  local no="$1" name="$2" sql="$3" base="$4" database="$5" expect_query="$6"
  run_and_wait "$base" "$sql" "AwsDataCatalog" "$database"
  if [ -z "$LAST_ID" ]; then
    record "$no $name" FAIL "開始できなかった(SUCCEEDED を期待): code=$LAST_START_CODE body=$(echo "$LAST_START_BODY" | tr -d '\n' | cut -c1-200)"
    return
  fi
  local state
  state=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.Status.State // "無し"')
  if [ "$state" != "SUCCEEDED" ]; then
    record "$no $name" FAIL "State=$state(期待 SUCCEEDED) [id=$LAST_ID]"
    return
  fi
  local got_query
  got_query=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.Query // "無し"')
  if [ "$got_query" = "$expect_query" ]; then
    record "$no $name" PASS "Query=\"$got_query\" [id=$LAST_ID]"
  else
    record "$no $name" FAIL "Query=\"$got_query\"(期待 \"$expect_query\") [id=$LAST_ID]"
  fi
}

# --- 判定（失敗） ---

check_hive_failure() {
  local no="$1" name="$2" sql="$3" base="$4" database="$5" reason="$6" err_cat="$7" err_type="$8"
  local expect_query="${9:-}" expect_ctxdb="${10:-}"
  run_and_wait "$base" "$sql" "AwsDataCatalog" "$database"
  if [ -z "$LAST_ID" ]; then
    record "$no $name" FAIL "開始できなかった(FAILED を期待): code=$LAST_START_CODE body=$(echo "$LAST_START_BODY" | tr -d '\n' | cut -c1-200)"
    return
  fi
  local id="$LAST_ID" ok=1 diff=""
  local got_state got_reason got_cat got_type got_errmsg
  got_state=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.Status.State // "無し"')
  got_reason=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.Status.StateChangeReason // "無し"')
  got_cat=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.Status.AthenaError.ErrorCategory // "無し"')
  got_type=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.Status.AthenaError.ErrorType // "無し"')
  got_errmsg=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.Status.AthenaError.ErrorMessage // "無し"')
  [ "$got_state" = "FAILED" ] || { ok=0; diff="$diff State=$got_state(期待 FAILED)"; }
  [ "$got_reason" = "$reason" ] || { ok=0; diff="$diff StateChangeReason=\"$got_reason\"(期待 \"$reason\")"; }
  [ "$got_cat" = "$err_cat" ] || { ok=0; diff="$diff ErrorCategory=$got_cat(期待 $err_cat)"; }
  [ "$got_type" = "$err_type" ] || { ok=0; diff="$diff ErrorType=$got_type(期待 $err_type)"; }
  [ "$got_errmsg" = "$reason" ] || { ok=0; diff="$diff ErrorMessage=\"$got_errmsg\"(期待 \"$reason\")"; }

  if [ -n "$expect_query" ]; then
    local got_query
    got_query=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.Query // "無し"')
    [ "$got_query" = "$expect_query" ] || { ok=0; diff="$diff Query=\"$got_query\"(期待 \"$expect_query\")"; }
  fi
  if [ -n "$expect_ctxdb" ]; then
    local got_ctxdb
    got_ctxdb=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.QueryExecutionContext.Database // "無し"')
    [ "$got_ctxdb" = "$expect_ctxdb" ] || { ok=0; diff="$diff Context.Database=$got_ctxdb(期待 $expect_ctxdb)"; }
  fi

  local key="${PREFIX}/${id}.txt" body_stat
  body_stat=$(mc_stat "$key")
  if mc_exists "$body_stat"; then
    local content
    content=$(mc cat "local/$BUCKET/$key" 2>/dev/null)
    [ "$content" = "$reason" ] || { ok=0; diff="$diff .txtの中身が違う"; }
  else
    ok=0
    diff="$diff .txt=無し(期待 有り)"
  fi
  if mc_exists "$(mc_stat "${key}.metadata")"; then
    ok=0
    diff="$diff .metadata=有り(期待 無し)"
  fi

  if [ "$ok" = "1" ]; then
    record "$no $name" PASS "${diff# } [id=$id]"
  else
    record "$no $name" FAIL "${diff# } [id=$id]"
  fi
}

check_iceberg_failure() {
  local no="$1" name="$2" sql="$3" base="$4" database="$5" reason="$6"
  run_and_wait "$base" "$sql" "AwsDataCatalog" "$database"
  if [ -z "$LAST_ID" ]; then
    record "$no $name" FAIL "開始できなかった(FAILED を期待): code=$LAST_START_CODE body=$(echo "$LAST_START_BODY" | tr -d '\n' | cut -c1-200)"
    return
  fi
  local id="$LAST_ID" ok=1 diff=""
  local got_state got_reason got_cat got_type got_errmsg
  got_state=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.Status.State // "無し"')
  got_reason=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.Status.StateChangeReason // "無し"')
  got_cat=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.Status.AthenaError.ErrorCategory // "無し"')
  got_type=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.Status.AthenaError.ErrorType // "無し"')
  got_errmsg=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.Status.AthenaError.ErrorMessage // "無し"')
  [ "$got_state" = "FAILED" ] || { ok=0; diff="$diff State=$got_state(期待 FAILED)"; }
  [ "$got_reason" = "$reason" ] || { ok=0; diff="$diff StateChangeReason=\"$got_reason\"(期待 \"$reason\")"; }
  [ "$got_cat" = "2" ] || { ok=0; diff="$diff ErrorCategory=$got_cat(期待 2)"; }
  [ "$got_type" = "1100" ] || { ok=0; diff="$diff ErrorType=$got_type(期待 1100)"; }
  [ "$got_errmsg" = "$reason" ] || { ok=0; diff="$diff ErrorMessage=\"$got_errmsg\"(期待 \"$reason\")"; }

  local key="${PREFIX}/${id}.txt"
  if mc_exists "$(mc_stat "$key")"; then ok=0; diff="$diff .txt=有り(期待 無し)"; fi
  if mc_exists "$(mc_stat "${key}.metadata")"; then ok=0; diff="$diff .metadata=有り(期待 無し)"; fi

  if [ "$ok" = "1" ]; then
    record "$no $name" PASS "${diff# } [id=$id]"
  else
    record "$no $name" FAIL "${diff# } [id=$id]"
  fi
}

# R1（回帰）: 開始時に 400・InvalidRequestException・Entity Not Found で始まる。
check_start_reject() {
  local no="$1" name="$2" sql="$3" base="$4" database="$5" expect_prefix="$6"
  athena_start_raw "$base" "$sql" "AwsDataCatalog" "$database"
  local id
  id=$(echo "$LAST_START_BODY" | jq -r '.QueryExecutionId // empty')
  if [ -n "$id" ]; then
    record "$no $name" FAIL "開始できてしまった(400 を期待): id=$id"
    return
  fi
  local ok=1 diff=""
  [ "$LAST_START_CODE" = "400" ] || { ok=0; diff="$diff code=$LAST_START_CODE(期待 400)"; }
  local msg type
  msg=$(echo "$LAST_START_BODY" | jq -r '.Message // empty')
  type=$(echo "$LAST_START_BODY" | jq -r '.__type // empty')
  [ "$type" = "InvalidRequestException" ] || { ok=0; diff="$diff __type=$type(期待 InvalidRequestException)"; }
  [[ "$msg" == "$expect_prefix"* ]] || { ok=0; diff="$diff Message=\"$msg\"(先頭が「$expect_prefix」でない)"; }
  if [ "$ok" = "1" ]; then
    record "$no $name" PASS "${diff# }"
  else
    record "$no $name" FAIL "${diff# }"
  fi
}

# --- セットアップ ---

setup_tables() {
  trino_exec "CREATE SCHEMA hive.${SCHEMA}" hive default &&
    trino_exec "CREATE SCHEMA iceberg.${SCHEMA}" iceberg default &&
    trino_exec "CREATE TABLE hive.${SCHEMA}.${H} (n integer, s varchar COMMENT 'the s column')" hive "$SCHEMA" &&
    trino_exec "CREATE TABLE hive.${SCHEMA}.${HP} (n integer, p varchar) WITH (partitioned_by = ARRAY['p'])" hive "$SCHEMA" &&
    trino_exec "INSERT INTO hive.${SCHEMA}.${HP} (n, p) VALUES (1, 'x')" hive "$SCHEMA" &&
    trino_exec "CREATE TABLE iceberg.${SCHEMA}.${ICE} (n integer, p varchar) WITH (partitioning = ARRAY['p'])" iceberg "$SCHEMA" &&
    trino_exec "CREATE VIEW hive.${SCHEMA}.${VIEWT} AS SELECT 1 AS n" hive "$SCHEMA"
}

# --- GATE（わざと壊す自己確認） ---

self_check_gate() {
  if [ -z "$R2_ID" ]; then
    log "GATE省略(R2が開始できなかった)"
    return
  fi
  log "自己確認: R2 の期待値をわざと 1 か所変えて FAIL になるか確かめる"
  local wrong_head="$EVIDENCE_DIR/GATE.head"
  write_lines "$wrong_head" "$(hive_row n int '')" "$(hive_row s string 'WRONG_COMMENT')"
  BASE_FOR_RESULTS="$BASE_H"
  CONTAINS=()
  do_check_success "GATE" "わざと壊した期待値(R2のsのコメントを改変)" "$R2_ID" "$R2_EXEC_JSON" \
    "DESCRIBE h" "$SCHEMA" "application/octet-stream" absent "$COLS3" "$wrong_head" exact
  pop_result
  if [ "$LAST_POPPED_STATUS" = "FAIL" ]; then
    log "自己確認 OK: 期待値を壊すと判定は FAIL になった"
  else
    log "自己確認 NG: 期待値を壊しても判定が FAIL にならなかった（足場のバグの疑い）"
  fi
}

# --- ケース ---

main() {
  log "証跡の保存先: $EVIDENCE_DIR"
  log "compose プロジェクト: ${COMPOSE_PROJECT_NAME:-athena-local}"

  build_expectations

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
    record "セットアップ" FAIL "Trino でスキーマか表が作れなかった"
    return 1
  fi
  record "セットアップ" PASS "hive.${SCHEMA}.{${H},${HP},${VIEWT}}、iceberg.${SCHEMA}.${ICE}"

  if ! build_athena_local; then
    record "cargo build" FAIL "ビルドが失敗した（$BUILD_LOG）"
    return 1
  fi
  record "cargo build" PASS "$BINARY"

  if ! start_athena_local "$ATHENA_BIND_H" "AwsDataCatalog=hive" "$ATHENA_LOG_H" ATHENA_PID_H; then
    record "athena-local起動(系統H)" FAIL "athena-local（hive）が起動しなかった（$ATHENA_LOG_H）"
    return 1
  fi
  record "athena-local起動(系統H)" PASS "$BASE_H"
  if ! start_athena_local "$ATHENA_BIND_I" "AwsDataCatalog=iceberg" "$ATHENA_LOG_I" ATHENA_PID_I; then
    record "athena-local起動(系統I)" FAIL "athena-local（iceberg）が起動しなかった（$ATHENA_LOG_I）"
    return 1
  fi
  record "athena-local起動(系統I)" PASS "$BASE_I"

  # E group（名前のある EXTENDED）
  CONTAINS=()
  check_success E1 "DESCRIBE_EXTENDED_h" "DESCRIBE EXTENDED ${SCHEMA}.${H}" "$BASE_H" "$SCHEMA" \
    "DESCRIBE EXTENDED ${H}" "$SCHEMA" "application/octet-stream" absent "$COLS3" \
    "$EXPECT_DIR/E1.head" prefix "$DTI_PREFIX"
  check_success E2 "DESCRIBE_EXTENDED_hp" "DESCRIBE EXTENDED ${SCHEMA}.${HP}" "$BASE_H" "$SCHEMA" \
    "DESCRIBE EXTENDED ${HP}" "$SCHEMA" "application/octet-stream" absent "$COLS3" \
    "$EXPECT_DIR/E2.head" prefix "$DTI_PREFIX"
  check_success E3 "DESCRIBE_EXTENDED_v" "DESCRIBE EXTENDED ${SCHEMA}.${VIEWT}" "$BASE_H" "$SCHEMA" \
    "DESCRIBE EXTENDED ${VIEWT}" "$SCHEMA" "application/octet-stream" absent "$COLS3" \
    "$EXPECT_DIR/E3.head" prefix "$DTI_PREFIX"
  check_iceberg_failure E4 "DESCRIBE_EXTENDED_i" "DESCRIBE EXTENDED ${SCHEMA}.${ICE}" "$BASE_I" "$SCHEMA" \
    "EXTENDED keyword is not supported for Iceberg tables."

  # F group（名前のある FORMATTED）
  CONTAINS=("$DTI3" "$SI3")
  check_success F1 "DESCRIBE_FORMATTED_h" "DESCRIBE FORMATTED ${SCHEMA}.${H}" "$BASE_H" "$SCHEMA" \
    "DESCRIBE FORMATTED ${H}" "$SCHEMA" "application/octet-stream" absent "$COLS3" \
    "$EXPECT_DIR/F1.head" contains-only
  CONTAINS=("# Partition Information" "$(hive_row p string '')" "$DTI3")
  check_success F2 "DESCRIBE_FORMATTED_hp" "DESCRIBE FORMATTED ${SCHEMA}.${HP}" "$BASE_H" "$SCHEMA" \
    "DESCRIBE FORMATTED ${HP}" "$SCHEMA" "application/octet-stream" absent "$COLS3" \
    "$EXPECT_DIR/F2.head" contains-only
  CONTAINS=("$DTI3")
  check_success F3 "DESCRIBE_FORMATTED_v" "DESCRIBE FORMATTED ${SCHEMA}.${VIEWT}" "$BASE_H" "$SCHEMA" \
    "DESCRIBE FORMATTED ${VIEWT}" "$SCHEMA" "application/octet-stream" absent "$COLS3" \
    "$EXPECT_DIR/F3.head" contains-only
  CONTAINS=("Name:${TAB}")
  check_success F4 "DESCRIBE_FORMATTED_i" "DESCRIBE FORMATTED ${SCHEMA}.${ICE}" "$BASE_I" "$SCHEMA" \
    "DESCRIBE FORMATTED ${ICE}" "$SCHEMA" "binary/octet-stream" 0 "$COLS3" \
    "$EXPECT_DIR/F4.head" prefix $'\n'"${TAB}${TAB}"$'\n'"Name:${TAB}iceberg.${SCHEMA}.${ICE}${TAB}"

  # C group（列指定）
  CONTAINS=()
  check_success C1 "DESCRIBE_EXTENDED_h_n" "DESCRIBE EXTENDED ${SCHEMA}.${H} n" "$BASE_H" "$SCHEMA" \
    "DESCRIBE EXTENDED ${H} n" "$SCHEMA" "application/octet-stream" absent "$COLS3" \
    "$EXPECT_DIR/C1.head" exact
  check_success C2 "DESCRIBE_FORMATTED_h_n" "DESCRIBE FORMATTED ${SCHEMA}.${H} n" "$BASE_H" "$SCHEMA" \
    "DESCRIBE FORMATTED ${H} n" "$SCHEMA" "application/octet-stream" absent "$COLS11" \
    "$EXPECT_DIR/C2.head" exact
  check_success C3 "DESCRIBE_i_n" "DESCRIBE ${SCHEMA}.${ICE} n" "$BASE_I" "$SCHEMA" \
    "DESCRIBE ${ICE} n" "$SCHEMA" "binary/octet-stream" 0 "$COLS3" \
    "$EXPECT_DIR/C3.head" exact
  check_iceberg_failure C4 "DESCRIBE_EXTENDED_i_n" "DESCRIBE EXTENDED ${SCHEMA}.${ICE} n" "$BASE_I" "$SCHEMA" \
    "EXTENDED keyword is not supported for Iceberg tables."
  check_iceberg_failure C5 "DESCRIBE_FORMATTED_i_n" "DESCRIBE FORMATTED ${SCHEMA}.${ICE} n" "$BASE_I" "$SCHEMA" \
    "FORMATTED keyword is not supported for Iceberg table columns."

  # P group（PARTITION 指定）
  CONTAINS=()
  check_success P1 "DESCRIBE_EXTENDED_hp_PARTITION" "DESCRIBE EXTENDED ${SCHEMA}.${HP} PARTITION (p='x')" "$BASE_H" "$SCHEMA" \
    "DESCRIBE EXTENDED ${HP} PARTITION (p='x')" "$SCHEMA" "application/octet-stream" absent "$COLS3" \
    "$EXPECT_DIR/P1.head" prefix "$DPI_PREFIX"
  CONTAINS=("$DPI3")
  check_success P2 "DESCRIBE_FORMATTED_hp_PARTITION" "DESCRIBE FORMATTED ${SCHEMA}.${HP} PARTITION (p='x')" "$BASE_H" "$SCHEMA" \
    "DESCRIBE FORMATTED ${HP} PARTITION (p='x')" "$SCHEMA" "application/octet-stream" absent "$COLS3" \
    "" contains-only
  check_iceberg_failure P3 "DESCRIBE_i_PARTITION" "DESCRIBE ${SCHEMA}.${ICE} PARTITION (p='x')" "$BASE_I" "$SCHEMA" \
    "PARTITION keyword is not supported for Iceberg tables."

  # X group（無い表・無い DB・無い列・無いパーティション）
  check_hive_failure X1 "DESCRIBE_EXTENDED_無い表" "DESCRIBE EXTENDED ${SCHEMA}.nope" "$BASE_H" "$SCHEMA" \
    "FAILED: SemanticException [Error 10001]: Table not found nope" 2 1006
  check_hive_failure X2 "DESCRIBE_FORMATTED_無い表" "DESCRIBE FORMATTED ${SCHEMA}.nope" "$BASE_H" "$SCHEMA" \
    "FAILED: SemanticException [Error 10001]: Table not found nope" 2 1006
  check_hive_failure X3 "DESCRIBE_EXTENDED_無いDB" "DESCRIBE EXTENDED nodb_275.${H}" "$BASE_H" "$SCHEMA" \
    "FAILED: SemanticException [Error 10072]: Database does not exist: nodb_275" 2 1006 \
    "DESCRIBE EXTENDED ${H}" "nodb_275"
  check_hive_failure X4 "DESCRIBE_EXTENDED_無い列" "DESCRIBE EXTENDED ${SCHEMA}.${H} nocol" "$BASE_H" "$SCHEMA" \
    "FAILED: Execution Error, return code 1 from org.apache.hadoop.hive.ql.exec.DDLTask. cannot find field nocol from [0:n, 1:s]" 1 1003
  check_hive_failure X5 "DESCRIBE_EXTENDED_無いパーティション" "DESCRIBE EXTENDED ${SCHEMA}.${HP} PARTITION (p='nope')" "$BASE_H" "$SCHEMA" \
    "FAILED: SemanticException [Error 10006]: Partition not found {p=nope}" 2 1006

  # Q group（空白・大文字小文字・awsdatacatalog. の綴り）
  check_query_only Q1 "空白2つ" "DESCRIBE  EXTENDED ${SCHEMA}.${H}" "$BASE_H" "$SCHEMA" "DESCRIBE EXTENDED ${H}"
  check_query_only Q2 "小文字_awsdatacatalog" "describe formatted awsdatacatalog.${SCHEMA}.${H}" "$BASE_H" "$SCHEMA" "describe formatted ${H}"
  check_query_only Q3 "DESCの綴り" "DESC EXTENDED ${SCHEMA}.${H}" "$BASE_H" "$SCHEMA" "DESC EXTENDED ${H}"

  # 回帰
  check_start_reject R1 "DESCRIBE_EXTENDED_名前無し" "DESCRIBE EXTENDED" "$BASE_H" "$SCHEMA" \
    "Entity Not Found (Service: AmazonDataCatalog; "
  CONTAINS=()
  check_success R2 "DESCRIBE_プレーン_h" "DESCRIBE ${SCHEMA}.${H}" "$BASE_H" "$SCHEMA" \
    "DESCRIBE ${H}" "$SCHEMA" "application/octet-stream" absent "$COLS3" \
    "$EXPECT_DIR/R2.head" exact
  R2_ID="$LAST_ID"
  R2_EXEC_JSON="$LAST_EXEC_JSON"

  self_check_gate

  return 0
}

main
