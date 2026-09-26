#!/usr/bin/env bash
# issue #229 の実機検証の足場（tools/e2e/create-table-catalog/verify.sh を雛形にした）。
#
# #229 の変更: QueryExecutionContext の Catalog が S3 Tables（`s3tablescatalog/` で始まる、大文字小文字は
# 区別しない）のとき、StartQueryExecution は構文チェック（Trino への PREPARE）より前に、Hive の
# `CREATE [EXTERNAL] TABLE ... LOCATION '...'` を
# `Table location can not be specified for tables hosted in S3 table buckets` で、LOCATION の無い
# `CREATE EXTERNAL TABLE t (n int)` を `External keyword not supported for table type ICEBERG` で弾く
# （400、InvalidRequestException、AthenaErrorCode MALFORMED_QUERY）。Hive の構文で読めない形（NOT NULL・
# LOCATION より前の TBLPROPERTIES など）は今までどおり Trino の構文チェックの文言を返す。既定の Context
# （S3 Tables でないカタログ）は変わらない（src/operation/unquoted_ddl/create_table/hive.rs）。
#
# この足場は compose のローカル Trino の iceberg カタログを S3 Tables の別名（TRINO_CATALOG_MAP の
# `s3tablescatalog/e2e229=iceberg,AwsDataCatalog=hive`）にし、athena-local の StartQueryExecution／
# GetQueryExecution に次のケース表を流して判定する。本物の AWS には投げない（compose の trino・minio だけ）。
# 名前空間は作らない（すべて開始時に弾かれるか、表を触らない SELECT なので不要）。
#
# ケース表（TRINO_CATALOG_MAP=s3tablescatalog/e2e229=iceberg,AwsDataCatalog=hive）:
#   L1 S3 Tables の Context（Catalog=s3tablescatalog/e2e229,Database=e2e229ns）
#      CREATE TABLE awsdatacatalog.default.t229 (n int) LOCATION 's3://b/p/'
#      → 400、MALFORMED_QUERY／Message ちょうど
#        "Table location can not be specified for tables hosted in S3 table buckets"
#   L2 同じ Context
#      CREATE EXTERNAL TABLE t229 (n int)
#      → 400、MALFORMED_QUERY／"External keyword not supported for table type ICEBERG"
#   L3 同じ Context・Catalog を大文字混じり S3TablesCatalog/e2e229
#      create table t229 (n int) location 's3://b/p/'
#      → L1 と同じ文言
#   L4 同じ Context（Catalog は L1 と同じ小文字 s3tablescatalog/e2e229）
#      CREATE TABLE t229 (n int NOT NULL) LOCATION 's3://b/p/'
#      → 400、MALFORMED_QUERY／Message ちょうど
#        "line 1:36: mismatched input 'LOCATION'. Expecting: 'COMMENT', 'WITH', <EOF>"
#        （NOT NULL は hive.rs の測った形にないので None になり、Trino の構文チェックに落ちる。列位置 36 は
#        "CREATE TABLE t229 (n int NOT NULL) " の文字数から数えて確認済み）
#   L5 同じ Context
#      CREATE TABLE t229 (n int) TBLPROPERTIES ('table_type'='ICEBERG') LOCATION 's3://b/p/'
#      → 400、MALFORMED_QUERY／Message ちょうど
#        "line 1:27: mismatched input 'TBLPROPERTIES'. Expecting: 'COMMENT', 'WITH', <EOF>"
#        （LOCATION より前の TBLPROPERTIES も測った形にないので None。列位置 27 を確認済み）
#   L6 既定の Context（Catalog=AwsDataCatalog,Database=default）
#      CREATE TABLE t229 (n int) LOCATION 's3://b/p/'
#      → 400、MALFORMED_QUERY／Message ちょうど
#        "line 1:27: mismatched input 'LOCATION'. Expecting: 'COMMENT', 'WITH', <EOF>"
#        （S3 Tables でない Context なので hive.rs は素通りし、いつもの Trino の構文チェックの文言のまま）
#   L7 既定の Context
#      CREATE EXTERNAL TABLE t229 (n int)
#      → 400、MALFORMED_QUERY／Message が "mismatched input 'EXTERNAL'" を含む
#        （実際は "line 1:8: mismatched input 'EXTERNAL'. Expecting: ..." で、先頭に位置情報が付くので
#        部分一致で見る。位置・語順まで固定するのは過剰）
#   L8 S3 Tables の Context
#      SELECT 1
#      → 200 と QueryExecutionId（疎通。SUCCEEDED まで待つ）
#
# 前提コマンド: tools/dev.sh 経由で動かす（toolbox に全部入っている）
#
# 使い方:
#   tools/dev.sh tools/e2e/s3-tables-location/verify.sh
#
# 環境変数:
#   KEEP_UP=1        テスト後に docker compose down -v をせず環境を残す（デバッグ用）
#   SKIP_BUILD=1     cargo build を省略し、既存の $CARGO_TARGET_DIR（tools/dev.sh では .toolbox/target）の release/athena-local をそのまま使う
#
# 後始末は本スクリプトの trap が行う: athena-local を止め、docker compose down -v trino minio minio-init する
# （KEEP_UP=1 でなければ）。ほかの docker コンテナや compose のサービスは止めたり消したりしない。cargo test も
# 走らせない。終了コードは結果表の FAIL の件数を数え、1 件でもあれば 1。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# cargo の成果物の置き場。tools/dev.sh は CARGO_TARGET_DIR を .toolbox/target にする
BINARY="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/athena-local"
COMPOSE=(docker compose -f "$REPO_ROOT/compose.yml")
SERVICES=(trino minio minio-init)

TRINO_BASE="http://trino:8080"
MINIO_ENDPOINT="http://minio:9000"
BUCKET="athena-results"
PREFIX="e2e229"
OUTPUT_LOCATION="s3://${BUCKET}/${PREFIX}/"

S3_TABLES_CATALOG="s3tablescatalog/e2e229"
S3_TABLES_CATALOG_MIXED="S3TablesCatalog/e2e229"
NS="e2e229ns"

ATHENA_BIND="127.0.0.1:8129"
ATHENA_BASE="http://${ATHENA_BIND}"

EVIDENCE_DIR="$(mktemp -d /tmp/athena-local-issue229-e2e.XXXXXX)"
ATHENA_LOG="$EVIDENCE_DIR/athena-local.log"
BUILD_LOG="$EVIDENCE_DIR/cargo-build.log"

ATHENA_PID=""

declare -a RESULT_NAMES=()
declare -a RESULT_STATUS=()
declare -a RESULT_DETAIL=()

log() { echo "[verify] $*" >&2; }

record() {
  RESULT_NAMES+=("$1")
  RESULT_STATUS+=("$2")
  RESULT_DETAIL+=("$3")
}

print_table() {
  echo
  echo "==================== 結果 ===================="
  local i
  for i in "${!RESULT_NAMES[@]}"; do
    printf "%-6s %-56s %s\n" "${RESULT_STATUS[$i]}" "${RESULT_NAMES[$i]}" "${RESULT_DETAIL[$i]}"
  done
  echo "=============================================="
  local pass=0 fail=0 skip=0
  local -a failed=()
  for i in "${!RESULT_STATUS[@]}"; do
    case "${RESULT_STATUS[$i]}" in
      PASS) pass=$((pass + 1)) ;;
      FAIL) fail=$((fail + 1)); failed+=("${RESULT_NAMES[$i]}") ;;
      *) skip=$((skip + 1)) ;;
    esac
  done
  echo "PASS=$pass FAIL=$fail SKIP=$skip"
  if [ "$fail" -gt 0 ]; then
    echo "FAIL の一覧:"
    for i in "${failed[@]}"; do
      echo "  - $i"
    done
  fi
  echo "証跡（起動ログ・取得したファイル）: $EVIDENCE_DIR"
  [ "$fail" -eq 0 ]
}

cleanup() {
  local status=$?
  if [ -n "$ATHENA_PID" ] && kill -0 "$ATHENA_PID" 2>/dev/null; then
    log "athena-local (PID $ATHENA_PID) を止める"
    kill "$ATHENA_PID" 2>/dev/null || true
    wait "$ATHENA_PID" 2>/dev/null || true
  fi

  if [ "${KEEP_UP:-0}" = "1" ]; then
    log "KEEP_UP=1 のため docker compose はそのまま残す（後で tools/dev.sh docker compose -f $REPO_ROOT/compose.yml down -v ${SERVICES[*]}）"
  else
    log "docker compose down -v ${SERVICES[*]}"
    "${COMPOSE[@]}" down -v "${SERVICES[@]}" >/dev/null 2>&1
  fi
  print_table
  local table_status=$?
  if [ "$status" -eq 0 ]; then
    status=$table_status
  fi
  exit "$status"
}
trap cleanup EXIT

# --- Trino への直接アクセス（起動待ちの疎通確認専用。測定対象の文は athena-local 経由で投げる） ---

trino_exec() {
  local sql="$1" catalog="$2" schema="$3"
  local resp next
  resp=$(curl -sf -X POST "$TRINO_BASE/v1/statement" \
    -H "X-Trino-User: e2e-229-setup" \
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
    if [ -z "$next" ]; then
      break
    fi
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

# --- athena-local 起動 ---

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

start_athena_local() {
  log "athena-local を起動する（bind=$ATHENA_BIND、TRINO_CATALOG_MAP=${S3_TABLES_CATALOG}=iceberg,AwsDataCatalog=hive、ログ: $ATHENA_LOG）"
  (
    cd "$REPO_ROOT"
    exec env \
      ATHENA_LOCAL_BIND="$ATHENA_BIND" \
      TRINO_URL="$TRINO_BASE" \
      TRINO_USER="athena-local-e2e229" \
      TRINO_CATALOG_MAP="${S3_TABLES_CATALOG}=iceberg,AwsDataCatalog=hive" \
      ATHENA_LOCAL_RESULTS="s3" \
      AWS_ENDPOINT_URL_S3="$MINIO_ENDPOINT" \
      AWS_ACCESS_KEY_ID="minioadmin" \
      AWS_SECRET_ACCESS_KEY="minioadmin" \
      ATHENA_LOCAL_OUTPUT_LOCATION="$OUTPUT_LOCATION" \
      "$BINARY"
  ) >"$ATHENA_LOG" 2>&1 &
  ATHENA_PID=$!

  log "athena-local ($ATHENA_BASE) の起動待ち"
  local _ status
  for _ in $(seq 1 30); do
    if ! kill -0 "$ATHENA_PID" 2>/dev/null; then
      log "athena-local が異常終了した。ログ:"
      cat "$ATHENA_LOG" >&2
      return 1
    fi
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ATHENA_BASE/" \
      -H "X-Amz-Target: AmazonAthena.ListWorkGroups" \
      -H "Content-Type: application/x-amz-json-1.1" \
      --data-binary '{}')
    if [ "$status" = "200" ]; then
      log "athena-local 起動確認"
      return 0
    fi
    sleep 1
  done
  log "athena-local が応答しなかった"
  return 1
}

# --- athena-local の Athena API 呼び出し ---

athena_call() {
  local operation="$1" body="$2"
  curl -s -X POST "$ATHENA_BASE/" \
    -H "X-Amz-Target: AmazonAthena.$operation" \
    -H "Content-Type: application/x-amz-json-1.1" \
    --data "$body"
}

# QueryExecutionContext（Catalog・Database）付きの StartQueryExecution。
start_raw() {
  local sql="$1" catalog="$2" database="$3"
  local body
  body=$(jq -cn --arg sql "$sql" --arg catalog "$catalog" --arg db "$database" --arg token "$(uuidgen)" \
    '{QueryString: $sql, QueryExecutionContext: {Catalog: $catalog, Database: $db}, ClientRequestToken: $token}')
  athena_call StartQueryExecution "$body"
}

# QUEUED/RUNNING でなくなるまで GetQueryExecution をポーリングし、最後の応答を返す。
athena_wait() {
  local id="$1" resp state
  for _ in $(seq 1 100); do
    resp=$(athena_call GetQueryExecution "$(jq -n --arg id "$id" '{QueryExecutionId: $id}')")
    state=$(echo "$resp" | jq -r '.QueryExecution.Status.State // empty')
    if [ "$state" != "QUEUED" ] && [ "$state" != "RUNNING" ]; then
      echo "$resp"
      return 0
    fi
    sleep 0.3
  done
  echo "$resp"
  return 1
}

# --- ケースの判定 ---

# StartQueryExecution が開始時に弾かれることを確かめる。expect_message は完全一致。
case_reject() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5" expect_code="$6" expect_message="$7"
  local resp qid type_ code msg ok=1 detail=""
  resp=$(start_raw "$sql" "$catalog" "$database")
  qid=$(echo "$resp" | jq -r '.QueryExecutionId // empty')
  if [ -n "$qid" ]; then
    record "$no $name" FAIL "拒否される想定が開始できてしまった: QueryExecutionId=$qid"
    return
  fi
  type_=$(echo "$resp" | jq -r '.__type // empty')
  code=$(echo "$resp" | jq -r '.AthenaErrorCode // empty')
  msg=$(echo "$resp" | jq -r '.Message // empty')
  [ "$type_" = "InvalidRequestException" ] || { ok=0; detail="$detail __type=${type_:-無し}(期待 InvalidRequestException)"; }
  [ "$code" = "$expect_code" ] || { ok=0; detail="$detail AthenaErrorCode=${code:-無し}(期待 $expect_code)"; }
  [ "$msg" = "$expect_message" ] || { ok=0; detail="$detail Message=\"$msg\"(期待 \"$expect_message\")"; }
  if [ "$ok" = "1" ]; then
    record "$no $name" PASS "AthenaErrorCode=$code Message=\"$msg\""
  else
    record "$no $name" FAIL "${detail# }"
  fi
}

# case_reject と同じだが、Message は部分一致（contains）で確かめる（L7: Trino のごく普通の構文エラーで、
# 実際には "line 1:8: mismatched input 'EXTERNAL'. Expecting: ..." のように先頭に位置情報が付く。実測していない
# 位置・語順・空白まで固定するのは過剰なため、期待の断片を含むかどうかだけ見る）。
case_reject_contains() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5" expect_code="$6" expect_substring="$7"
  local resp qid type_ code msg ok=1 detail=""
  resp=$(start_raw "$sql" "$catalog" "$database")
  qid=$(echo "$resp" | jq -r '.QueryExecutionId // empty')
  if [ -n "$qid" ]; then
    record "$no $name" FAIL "拒否される想定が開始できてしまった: QueryExecutionId=$qid"
    return
  fi
  type_=$(echo "$resp" | jq -r '.__type // empty')
  code=$(echo "$resp" | jq -r '.AthenaErrorCode // empty')
  msg=$(echo "$resp" | jq -r '.Message // empty')
  [ "$type_" = "InvalidRequestException" ] || { ok=0; detail="$detail __type=${type_:-無し}(期待 InvalidRequestException)"; }
  [ "$code" = "$expect_code" ] || { ok=0; detail="$detail AthenaErrorCode=${code:-無し}(期待 $expect_code)"; }
  case "$msg" in
    *"$expect_substring"*) ;;
    *) ok=0; detail="$detail Message=\"$msg\"(期待 部分一致 \"$expect_substring\")" ;;
  esac
  if [ "$ok" = "1" ]; then
    record "$no $name" PASS "AthenaErrorCode=$code Message=\"$msg\""
  else
    record "$no $name" FAIL "${detail# }"
  fi
}

# L8: 開始できて QueryExecutionId が返ることを確かめる。待てれば SUCCEEDED まで見る。
case_start_ok() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5"
  local start qid final state
  start=$(start_raw "$sql" "$catalog" "$database")
  qid=$(echo "$start" | jq -r '.QueryExecutionId // empty')
  if [ -z "$qid" ]; then
    record "$no $name" FAIL "開始できなかった: $(echo "$start" | tr -d '\n' | cut -c1-200)"
    return
  fi
  final=$(athena_wait "$qid")
  state=$(echo "$final" | jq -r '.QueryExecution.Status.State // empty')
  if [ "$state" = "SUCCEEDED" ]; then
    record "$no $name" PASS "QueryExecutionId=$qid State=$state"
  else
    local reason
    reason=$(echo "$final" | jq -r '.QueryExecution.Status.StateChangeReason // empty')
    record "$no $name" FAIL "QueryExecutionId=$qid だが State=${state:-無し}(期待 SUCCEEDED) StateChangeReason=\"$reason\""
  fi
}

# --- ケース ---

run_cases() {
  # L1: S3 Tables の Context・LOCATION 付きの Hive の CREATE TABLE（3 部・awsdatacatalog）。
  case_reject "L1" "S3Tables の Context・LOCATION 付き(3 部 awsdatacatalog)" \
    "CREATE TABLE awsdatacatalog.default.t229 (n int) LOCATION 's3://b/p/'" "$S3_TABLES_CATALOG" "$NS" \
    MALFORMED_QUERY "Table location can not be specified for tables hosted in S3 table buckets"

  # L2: 同じ Context・LOCATION 無しの CREATE EXTERNAL TABLE。
  case_reject "L2" "S3Tables の Context・LOCATION 無しの EXTERNAL" \
    "CREATE EXTERNAL TABLE t229 (n int)" "$S3_TABLES_CATALOG" "$NS" \
    MALFORMED_QUERY "External keyword not supported for table type ICEBERG"

  # L3: 同じ Context・Catalog を大文字混じり・小文字の create table / location。
  case_reject "L3" "S3Tables の Context(大文字混じり)・小文字の create/location" \
    "create table t229 (n int) location 's3://b/p/'" "$S3_TABLES_CATALOG_MIXED" "$NS" \
    MALFORMED_QUERY "Table location can not be specified for tables hosted in S3 table buckets"

  # L4: 同じ Context・NOT NULL は測った形にないので Trino の構文チェックに落ちる。
  case_reject "L4" "S3Tables の Context・NOT NULL は構文チェックへ" \
    "CREATE TABLE t229 (n int NOT NULL) LOCATION 's3://b/p/'" "$S3_TABLES_CATALOG" "$NS" \
    MALFORMED_QUERY "line 1:36: mismatched input 'LOCATION'. Expecting: 'COMMENT', 'WITH', <EOF>"

  # L5: 同じ Context・LOCATION より前の TBLPROPERTIES も測った形にないので構文チェックへ。
  case_reject "L5" "S3Tables の Context・LOCATION 前の TBLPROPERTIES は構文チェックへ" \
    "CREATE TABLE t229 (n int) TBLPROPERTIES ('table_type'='ICEBERG') LOCATION 's3://b/p/'" "$S3_TABLES_CATALOG" "$NS" \
    MALFORMED_QUERY "line 1:27: mismatched input 'TBLPROPERTIES'. Expecting: 'COMMENT', 'WITH', <EOF>"

  # L6: 既定の Context では S3 Tables の文言にならず、いつもの Trino の構文チェックの文言のまま。
  case_reject "L6" "既定の Context・LOCATION は S3Tables の文言にならない" \
    "CREATE TABLE t229 (n int) LOCATION 's3://b/p/'" AwsDataCatalog default \
    MALFORMED_QUERY "line 1:27: mismatched input 'LOCATION'. Expecting: 'COMMENT', 'WITH', <EOF>"

  # L7: 既定の Context・EXTERNAL も S3Tables の文言にならない（Trino の普通の構文エラー、部分一致で確認）。
  case_reject_contains "L7" "既定の Context・EXTERNAL は S3Tables の文言にならない" \
    "CREATE EXTERNAL TABLE t229 (n int)" AwsDataCatalog default \
    MALFORMED_QUERY "mismatched input 'EXTERNAL'"

  # L8: S3 Tables の Context でも普通の SELECT は今までどおり実行できる（疎通）。
  case_start_ok "L8" "S3Tables の Context・SELECT 1 は通る" \
    "SELECT 1" "$S3_TABLES_CATALOG" "$NS"
}

main() {
  log "作業ディレクトリ: $SCRIPT_DIR"
  log "証跡の保存先: $EVIDENCE_DIR"

  if ! build_athena_local; then
    record "cargo build" FAIL "ビルドが失敗した"
    return 1
  fi
  record "cargo build" PASS "$BINARY を用意した"

  # 前の走行の残骸を持ち越さないよう、使うサービスを作り直す。
  log "docker compose down -v / up -d ${SERVICES[*]}"
  if ! "${COMPOSE[@]}" down -v "${SERVICES[@]}" >/dev/null 2>&1; then
    record "compose起動" FAIL "docker compose down -v ${SERVICES[*]} が失敗した"
    return 1
  fi
  if ! "${COMPOSE[@]}" up -d "${SERVICES[@]}"; then
    record "compose起動" FAIL "docker compose up -d ${SERVICES[*]} が失敗した"
    return 1
  fi

  if ! wait_for_trino; then
    record "Trino起動" FAIL "Trino が起動しなかった"
    return 1
  fi
  record "Trino起動" PASS "$TRINO_BASE で応答"

  if ! mc alias set local http://minio:9000 minioadmin minioadmin >/dev/null; then
    record "MinIOバケット" FAIL "mc alias set が失敗した（minio:9000 に繋がらない）"
    return 1
  fi
  if ! wait_for_bucket; then
    record "MinIOバケット" FAIL "バケット $BUCKET の用意ができなかった"
    return 1
  fi
  record "MinIOバケット" PASS "バケット $BUCKET 用意済み"

  if ! start_athena_local; then
    record "athena-local起動" FAIL "athena-local が起動しなかった"
    return 1
  fi
  record "athena-local起動" PASS "$ATHENA_BASE で応答（TRINO_CATALOG_MAP=${S3_TABLES_CATALOG}=iceberg,AwsDataCatalog=hive）"

  run_cases
}

main
