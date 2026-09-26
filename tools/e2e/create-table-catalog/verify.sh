#!/usr/bin/env bash
# issue #227 の実機検証の足場（tools/e2e/context-catalog/verify.sh を雛形にした）。
#
# #227 の変更: QueryExecutionContext の Catalog によらず、場所の無い（No location になる）無引用の 3 部の
# CREATE TABLE は、名前に書いた 1 部目のカタログが Trino に無ければ開始時に DATACATALOG_NOT_FOUND で弾く。
# S3 Tables の Context（Catalog が `s3tablescatalog/<バケット>`）で 1 部目が大文字小文字によらず
# `awsdatacatalog`（ちょうど小文字は別の「2 catalogs」判定が先に決まるので、実際には `AwsDataCatalog` などの
# 大文字混じりだけがここに来る）なら、1 部目を無視して 2 部目を Context のカタログ（Trino 側）の名前空間として
# 存在を確かめ、無ければ Trino に本体を送らずに FAILED（`Cannot find or access the specified table`）にする。
# 名前空間があれば（Trino にある他のカタログのときも）今までどおり No location のまま
# （.claude/issue-notes/227.md の実測・設計判断・計画）。
#
# この足場は compose のローカル Trino の iceberg カタログを S3 Tables の別名（TRINO_CATALOG_MAP の
# `s3tablescatalog/e2e227=iceberg`）にし、名前空間 e2e227ns を事前に作って、athena-local の
# StartQueryExecution／GetQueryExecution に次のケース表を流して判定する。本物の AWS には投げない
# （compose の trino・minio だけ）。
#
# ケース表（TRINO_CATALOG_MAP=s3tablescatalog/e2e227=iceberg,AwsDataCatalog=hive）:
#   M1 既定の Context（Catalog=AwsDataCatalog,Database=default）
#      CREATE TABLE nosuchcatalog227.default.t227 (n int)
#      → 400、InvalidRequestException／DATACATALOG_NOT_FOUND／
#        Message "Catalog 'nosuchcatalog227' does not exist"
#   M2 S3 Tables の Context（Catalog=s3tablescatalog/e2e227,Database=e2e227ns）
#      CREATE TABLE NoSuchCatalog227.e2e227ns.t227 (n int)
#      → 400、DATACATALOG_NOT_FOUND／Message "Catalog 'NoSuchCatalog227' does not exist"
#   M3 S3 Tables の Context
#      CREATE TABLE AwsDataCatalog.e2e227ns.t227 (n int)（名前空間 e2e227ns は実在）
#      → 400、MALFORMED_QUERY／No location
#   M4 S3 Tables の Context（Database=e2e227missing。名前空間は作らない）
#      CREATE TABLE AwsDataCatalog.e2e227missing.t227 (n int)
#      → 200 と QueryExecutionId、最終状態 FAILED（StateChangeReason・AthenaError.ErrorMessage
#        "Cannot find or access the specified table"、ErrorCategory 2・ErrorType 1100・Retryable false、
#        StatementType DDL・SubstatementType CREATE_TABLE）。結果ファイル本体も .metadata も置かない
#        （MinIO に無い）。iceberg に表 t227 ができていない
#   M5 既定の Context
#      CREATE TABLE AwsDataCatalog.default.t227 (n int)
#      → 400、MALFORMED_QUERY／No location
#   M6 S3 Tables の Context
#      CREATE TABLE iceberg.e2e227ns.t227 (n int)（Trino にあるカタログは実在扱い）
#      → 400、MALFORMED_QUERY／No location
#
# 前提コマンド: tools/dev.sh 経由で動かす（toolbox に全部入っている）
#
# 使い方:
#   tools/dev.sh tools/e2e/create-table-catalog/verify.sh
#
# 環境変数:
#   KEEP_UP=1        テスト後に docker compose down -v をせず環境を残す（デバッグ用）
#   SKIP_BUILD=1     cargo build を省略し、既存の $CARGO_TARGET_DIR（tools/dev.sh では .toolbox/target）の release/athena-local をそのまま使う
#
# 後始末は本スクリプトの trap が行う: athena-local を止め、Trino の名前空間 e2e227ns を DROP SCHEMA ...
# CASCADE で消し（KEEP_UP=1 でなければ）docker compose down -v trino minio minio-init する。ほかの docker
# コンテナや compose のサービスは止めたり消したりしない。cargo test も走らせない。
# 終了コードは結果表の FAIL の件数を数え、1 件でもあれば 1。
#
# 実機での確認（2026-09-26）: この Trino のカタログ構成（iceberg.properties の TESTING_FILE_METASTORE、
# fs.local.enabled=true）では、CREATE SCHEMA で作った名前空間が一覧（system.jdbc.schemas・SHOW SCHEMAS・
# information_schema.schemata）に現れない（生の Trino CLI でも再現する）。そのため athena-local は名前空間の
# 有無を一覧ではなく `SHOW TABLES FROM "<カタログ>"."<名前空間>" LIKE ''` で直接引いて確かめる（無ければ
# SCHEMA_NOT_FOUND）。最初の版は system.jdbc.schemas を引いていて、この足場の M3 で「あるのに無い」と
# 誤判定したので直した（#227）。

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
PREFIX="e2e227"
OUTPUT_LOCATION="s3://${BUCKET}/${PREFIX}/"

S3_TABLES_CATALOG="s3tablescatalog/e2e227"
NS="e2e227ns"
NS_MISSING="e2e227missing"

ATHENA_BIND="127.0.0.1:8106"
ATHENA_BASE="http://${ATHENA_BIND}"

EVIDENCE_DIR="$(mktemp -d /tmp/athena-local-issue227-e2e.XXXXXX)"
ATHENA_LOG="$EVIDENCE_DIR/athena-local.log"
BUILD_LOG="$EVIDENCE_DIR/cargo-build.log"

ATHENA_PID=""

declare -a RESULT_NAMES=()
declare -a RESULT_STATUS=()
declare -a RESULT_DETAIL=()

# case_* が run_and_wait / start_raw 経由で書く、直近のケースの QueryExecutionId と GetQueryExecution の
# 応答（開始が失敗したときは LAST_ID が空、LAST_START に生の応答）。
LAST_ID=""
LAST_RESP=""
LAST_START=""

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

  log "Trino の名前空間 $NS・$NS_MISSING を消す（無ければ何もしない）"
  trino_exec "DROP SCHEMA IF EXISTS iceberg.${NS} CASCADE" iceberg default >/dev/null 2>&1 || true
  trino_exec "DROP SCHEMA IF EXISTS iceberg.${NS_MISSING} CASCADE" iceberg default >/dev/null 2>&1 || true

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

# --- Trino への直接アクセス（セットアップ・後始末・追加確認専用。測定対象の文は athena-local 経由で投げる） ---

trino_exec() {
  local sql="$1" catalog="$2" schema="$3"
  local resp next
  resp=$(curl -sf -X POST "$TRINO_BASE/v1/statement" \
    -H "X-Trino-User: e2e-227-setup" \
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

# trino_exec と同じだが、行データ（`data` フィールド）を JSON 配列にまとめて返す（M4 の後始末確認用）。
trino_query_rows() {
  local sql="$1" catalog="$2" schema="$3"
  local resp next rows="[]"
  resp=$(curl -sf -X POST "$TRINO_BASE/v1/statement" \
    -H "X-Trino-User: e2e-227-check" \
    -H "X-Trino-Catalog: $catalog" \
    -H "X-Trino-Schema: $schema" \
    -H "X-Trino-Client-Capabilities: PARAMETRIC_DATETIME" \
    --data-binary "$sql")
  while true; do
    if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
      log "trino_query_rows 失敗: $sql"
      echo "$resp" | jq '.error' >&2
      echo "$rows"
      return 1
    fi
    if echo "$resp" | jq -e '.data' >/dev/null 2>&1; then
      rows=$(jq -c -n --argjson a "$rows" --argjson b "$(echo "$resp" | jq -c '.data')" '$a + $b')
    fi
    next=$(echo "$resp" | jq -r '.nextUri // empty')
    if [ -z "$next" ]; then
      break
    fi
    resp=$(curl -sf "$next")
  done
  echo "$rows"
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
      TRINO_USER="athena-local-e2e227" \
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

# StartQueryExecution → 終端状態まで待ち、LAST_ID・LAST_RESP に結果を残す。開始できなければ
# LAST_ID を空のままにし、LAST_START に生の応答を残して 1 を返す。
run_and_wait() {
  local sql="$1" catalog="$2" database="$3"
  local start
  start=$(start_raw "$sql" "$catalog" "$database")
  LAST_ID=$(echo "$start" | jq -r '.QueryExecutionId // empty')
  if [ -z "$LAST_ID" ]; then
    LAST_START="$start"
    LAST_RESP=""
    return 1
  fi
  LAST_START=""
  LAST_RESP=$(athena_wait "$LAST_ID")
  return 0
}

# --- S3（MinIO）側の確認（toolbox の mc で minio:9000 を直接見る。#129） ---

# `mc stat --json <key>` を実行して、key ちょうど一致するオブジェクトの JSON を返す。無ければ
# {"status":"error"} を返す（mc stat が前方一致もヒットさせる注意は tools/e2e/minio/lib.sh の mc_stat と同じ）。
mc_stat() {
  local key="$1" name
  name=$(basename "$key")
  local raw
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

# --- ケースの判定 ---

# StartQueryExecution が開始時に弾かれることを確かめる。expect_code・expect_message は完全一致。
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

# M4: 開始できて最終的に FAILED になることを確かめる。加えて結果ファイル（本体・.metadata）が MinIO に
# 無いこと、iceberg に表ができていないことも見る。
case_fail_at_runtime() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5" check_schema="$6" check_table="$7"
  if ! run_and_wait "$sql" "$catalog" "$database"; then
    record "$no $name" FAIL "開始できなかった: $(echo "$LAST_START" | tr -d '\n' | cut -c1-200)"
    return
  fi
  local state reason category type_ retryable stmt substmt ok=1 detail=""
  state=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.State // empty')
  reason=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.StateChangeReason // empty')
  category=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.AthenaError.ErrorCategory // empty')
  type_=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.AthenaError.ErrorType // empty')
  # Retryable は真偽値なので `// empty`（jq は false も偽扱いする）は使えない。null かどうかで分ける。
  retryable=$(echo "$LAST_RESP" | jq -r \
    'if .QueryExecution.Status.AthenaError.Retryable == null then "" else (.QueryExecution.Status.AthenaError.Retryable | tostring) end')
  stmt=$(echo "$LAST_RESP" | jq -r '.QueryExecution.StatementType // empty')
  substmt=$(echo "$LAST_RESP" | jq -r '.QueryExecution.SubstatementType // empty')
  [ "$state" = "FAILED" ] || { ok=0; detail="$detail State=${state:-無し}(期待 FAILED)"; }
  [ "$reason" = "Cannot find or access the specified table" ] || { ok=0; detail="$detail StateChangeReason=\"$reason\""; }
  [ "$category" = "2" ] || { ok=0; detail="$detail ErrorCategory=${category:-無し}(期待 2)"; }
  [ "$type_" = "1100" ] || { ok=0; detail="$detail ErrorType=${type_:-無し}(期待 1100)"; }
  [ "$retryable" = "false" ] || { ok=0; detail="$detail Retryable=${retryable:-無し}(期待 false)"; }
  [ "$stmt" = "DDL" ] || { ok=0; detail="$detail StatementType=${stmt:-無し}(期待 DDL)"; }
  [ "$substmt" = "CREATE_TABLE" ] || { ok=0; detail="$detail SubstatementType=${substmt:-無し}(期待 CREATE_TABLE)"; }

  local body_key="${PREFIX}/${LAST_ID}.txt" body_stat meta_stat
  body_stat=$(mc_stat "$body_key")
  if mc_exists "$body_stat"; then
    ok=0
    detail="$detail 結果ファイル本体がある(期待は無し): $body_key"
  fi
  meta_stat=$(mc_stat "${body_key}.metadata")
  if mc_exists "$meta_stat"; then
    ok=0
    detail="$detail .metadata がある(期待は無し): ${body_key}.metadata"
  fi

  local rows
  rows=$(trino_query_rows "SELECT table_name FROM system.jdbc.tables WHERE table_schem = '${check_schema}' AND table_name = '${check_table}'" system jdbc)
  if [ "$(echo "$rows" | jq 'length')" != "0" ]; then
    ok=0
    detail="$detail iceberg に表ができている(期待は無し): rows=$rows"
  fi

  if [ "$ok" = "1" ]; then
    record "$no $name" PASS "State=$state StateChangeReason=\"$reason\" ErrorCategory=$category ErrorType=$type_ Retryable=$retryable StatementType=$stmt SubstatementType=$substmt 結果ファイル無し 表無し [id=$LAST_ID]"
  else
    record "$no $name" FAIL "${detail# } [id=$LAST_ID]"
  fi
}

# --- ケース ---

run_cases() {
  # M1: 既定の Context・実在しない 1 部目。開始時に DATACATALOG_NOT_FOUND。
  case_reject "M1" "既定の Context・実在しないカタログ" \
    "CREATE TABLE nosuchcatalog227.default.t227 (n int)" AwsDataCatalog default \
    DATACATALOG_NOT_FOUND "Catalog 'nosuchcatalog227' does not exist"

  # M2: S3 Tables の Context・実在しない 1 部目。開始時に DATACATALOG_NOT_FOUND。
  case_reject "M2" "S3Tables の Context・実在しないカタログ" \
    "CREATE TABLE NoSuchCatalog227.${NS}.t227 (n int)" "$S3_TABLES_CATALOG" "$NS" \
    DATACATALOG_NOT_FOUND "Catalog 'NoSuchCatalog227' does not exist"

  # M3: S3 Tables の Context・1 部目 AwsDataCatalog・名前空間あり。No location のまま。
  case_reject "M3" "S3Tables の Context・AwsDataCatalog・名前空間あり" \
    "CREATE TABLE AwsDataCatalog.${NS}.t227 (n int)" "$S3_TABLES_CATALOG" "$NS" \
    MALFORMED_QUERY "No location was specified for table. An S3 location must be specified"

  # M4: S3 Tables の Context・1 部目 AwsDataCatalog・名前空間なし。開始して FAILED。
  case_fail_at_runtime "M4" "S3Tables の Context・AwsDataCatalog・名前空間なし" \
    "CREATE TABLE AwsDataCatalog.${NS_MISSING}.t227 (n int)" "$S3_TABLES_CATALOG" "$NS_MISSING" \
    "$NS_MISSING" "t227"

  # M5: 既定の Context・1 部目 AwsDataCatalog。No location のまま。
  case_reject "M5" "既定の Context・AwsDataCatalog" \
    "CREATE TABLE AwsDataCatalog.default.t227 (n int)" AwsDataCatalog default \
    MALFORMED_QUERY "No location was specified for table. An S3 location must be specified"

  # M6: S3 Tables の Context・Trino に実在するカタログ（iceberg 自身）。No location のまま。
  case_reject "M6" "S3Tables の Context・Trino に実在するカタログ" \
    "CREATE TABLE iceberg.${NS}.t227 (n int)" "$S3_TABLES_CATALOG" "$NS" \
    MALFORMED_QUERY "No location was specified for table. An S3 location must be specified"
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

  log "Trino 側に名前空間 $NS を用意する（$NS_MISSING は作らない）"
  if ! trino_exec "CREATE SCHEMA IF NOT EXISTS iceberg.${NS}" iceberg default; then
    record "セットアップ(名前空間)" FAIL "iceberg.${NS} の作成に失敗した"
    return 1
  fi
  record "セットアップ(名前空間)" PASS "iceberg.${NS} 作成済み（${NS_MISSING} は未作成のまま）"

  if ! start_athena_local; then
    record "athena-local起動" FAIL "athena-local が起動しなかった"
    return 1
  fi
  record "athena-local起動" PASS "$ATHENA_BASE で応答（TRINO_CATALOG_MAP=${S3_TABLES_CATALOG}=iceberg,AwsDataCatalog=hive）"

  run_cases
}

main
