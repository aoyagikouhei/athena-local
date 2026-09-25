#!/usr/bin/env bash
# issue #214 の実機検証の足場（tools/e2e/quoted-names/verify.sh を雛形にした）。
#
# #214 の変更: StartQueryExecution の
# QueryExecutionContext.Catalog に Trino に実在しないカタログ名を渡したとき、メタデータの文
# （DESCRIBE/DESC・SHOW COLUMNS・SHOW TABLES・SHOW DATABASES/SCHEMAS・SHOW CREATE TABLE・DROP TABLE）
# だけ、Trino に送るカタログを TRINO_CATALOG_MAP の AwsDataCatalog の別名（無ければ TRINO_CATALOG）に
# 差し替える。表を読む SELECT などは差し替えず、Trino の CATALOG_NOT_FOUND で FAILED になり、
# AthenaError の ErrorType は 1006 になる（.claude/issue-notes/214.md の実測・設計判断 D1〜D3）。
#
# この足場は compose のローカル Trino（hive カタログ）にスキーマ e2e214 と表 t214 を用意し、athena-local の
# StartQueryExecution／GetQueryExecution／GetQueryResults に次のケース表を流して判定する。本物の AWS には
# 投げない（compose の trino だけ）。
#
# ケース表（系統 A: TRINO_CATALOG_MAP=AwsDataCatalog=hive・TRINO_CATALOG は設定しない。
# 系統 B: TRINO_CATALOG_MAP 無し・TRINO_CATALOG=hive。Database はどれも e2e214）:
#   L1  系統A Catalog=NoSuchCat214 SHOW SCHEMAS                       SUCCEEDED、結果が Catalog=hive の対照と一致（hive は SHOW SCHEMAS に作ったスキーマを出さない）
#   L2  系統A Catalog=NoSuchCat214 DESCRIBE t214（実在）              SUCCEEDED
#   L3  系統A Catalog=NoSuchCat214 DESCRIBE t214_nope（実在しない）   開始時に InvalidRequestException／INVALID_INPUT／Entity Not Found
#   L4  系統A Catalog=NoSuchCat214 SELECT * FROM t214                 FAILED、ErrorCategory 2／ErrorType 1006／CATALOG_NOT_FOUND:
#   L5  系統A Catalog=NoSuchCat214 SELECT 1                           SUCCEEDED
#   L6  系統A Catalog=hive         DESCRIBE t214                      SUCCEEDED
#   L7  系統B Catalog=NoSuchCat214 SHOW TABLES                        SUCCEEDED、結果に t214 を含む
#   L8  系統A Catalog=NoSuchCat214 DROP TABLE IF EXISTS t214_nope     SUCCEEDED
#   L9  系統A Catalog=NoSuchCat214 SHOW CREATE TABLE t214             SUCCEEDED
#   L10 系統A Catalog=NoSuchCat214 SHOW COLUMNS FROM t214             SUCCEEDED
# L1・L4 では GetQueryExecution の QueryExecutionContext.Catalog が送った名前の小文字
# （nosuchcat214）で返ることも確かめる。
#
# 実装前（#212 のまま）の athena-local で流すと L1〜L4・L7・L9・L10 の 7 件が FAIL になり（メタデータの文は
# 実在しないカタログのまま Trino に送って CATALOG_NOT_FOUND、L3 は開始できてしまい、L4 は ErrorType が汎用の
# 1000）、#214 の実装後は全件 PASS になることを確かめてある（2026-09-25）。L8 は Trino が実在しないカタログでも
# DROP TABLE IF EXISTS を成功させるので、実装前から PASS。
#
# 前提コマンド: tools/dev.sh 経由で動かす（toolbox に全部入っている）
#
# 使い方:
#   tools/dev.sh tools/e2e/context-catalog/verify.sh
#
# 環境変数:
#   KEEP_UP=1        テスト後に docker compose down -v trino をせず環境を残す（デバッグ用）
#   SKIP_BUILD=1     cargo build を省略し、既存の $CARGO_TARGET_DIR（tools/dev.sh では .toolbox/target）の release/athena-local をそのまま使う
#
# 後始末は本スクリプトの trap が行う: 2 つの athena-local を止め、Trino のスキーマ e2e214 を
# DROP SCHEMA ... CASCADE で消し（KEEP_UP=1 でなければ）docker compose down -v trino する。
# ほかの docker コンテナや compose のサービスは止めたり消したりしない。cargo test も走らせない。
# 終了コードは結果表の FAIL の件数を数え、1 件でもあれば 1。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# cargo の成果物の置き場。tools/dev.sh は CARGO_TARGET_DIR を .toolbox/target にする
BINARY="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/athena-local"
COMPOSE=(docker compose -f "$REPO_ROOT/compose.yml")
SERVICES=(trino)

TRINO_BASE="http://trino:8080"
SCHEMA="e2e214"
NOCAT="NoSuchCat214"
NOCAT_LOWER="nosuchcat214"

# 系統 A（TRINO_CATALOG_MAP=AwsDataCatalog=hive・TRINO_CATALOG は設定しない）。ケース L1〜L6・L8〜L10。
ATHENA_BIND="127.0.0.1:8102"
ATHENA_BASE="http://${ATHENA_BIND}"
# 系統 B（TRINO_CATALOG_MAP 無し・TRINO_CATALOG=hive）。ケース L7 だけに使う。
ATHENA_BIND2="127.0.0.1:8103"
ATHENA_BASE2="http://${ATHENA_BIND2}"

EVIDENCE_DIR="$(mktemp -d /tmp/athena-local-issue214-e2e.XXXXXX)"
ATHENA_LOG="$EVIDENCE_DIR/athena-local.log"
ATHENA_LOG2="$EVIDENCE_DIR/athena-local-nomap.log"
BUILD_LOG="$EVIDENCE_DIR/cargo-build.log"

ATHENA_PID=""
ATHENA_PID2=""

declare -a RESULT_NAMES=()
declare -a RESULT_STATUS=()
declare -a RESULT_DETAIL=()

# case_succeeded / case_failed_catalog_not_found が run_and_wait 経由で書く、直近のケースの
# QueryExecutionId と GetQueryExecution の応答（開始が失敗したときは LAST_ID が空）。
# check_context_catalog / check_rows_contain の追加確認が読む。
LAST_ID=""
LAST_RESP=""
LAST_START=""

log() { echo "[verify] $*" >&2; }

record() {
  RESULT_NAMES+=("$1")
  RESULT_STATUS+=("$2")
  RESULT_DETAIL+=("$3")
}

# 直前に record した結果に、追加の確かめを重ねる（PASS はそのまま、FAIL なら上書きして detail を足す）。
amend_last() {
  local status="$1" detail="$2" last=$((${#RESULT_STATUS[@]} - 1))
  [ "$status" = "FAIL" ] && RESULT_STATUS[last]=FAIL
  RESULT_DETAIL[last]="${RESULT_DETAIL[last]} $detail"
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
  echo "証跡（起動ログ）: $EVIDENCE_DIR"
  [ "$fail" -eq 0 ]
}

cleanup() {
  local status=$?
  if [ -n "$ATHENA_PID" ] && kill -0 "$ATHENA_PID" 2>/dev/null; then
    log "athena-local (PID $ATHENA_PID) を止める"
    kill "$ATHENA_PID" 2>/dev/null || true
    wait "$ATHENA_PID" 2>/dev/null || true
  fi
  if [ -n "$ATHENA_PID2" ] && kill -0 "$ATHENA_PID2" 2>/dev/null; then
    log "athena-local (PID $ATHENA_PID2、TRINO_CATALOG_MAP 無し) を止める"
    kill "$ATHENA_PID2" 2>/dev/null || true
    wait "$ATHENA_PID2" 2>/dev/null || true
  fi

  log "Trino のスキーマ $SCHEMA を消す（無ければ何もしない）"
  trino_exec "DROP SCHEMA IF EXISTS hive.${SCHEMA} CASCADE" hive default >/dev/null 2>&1 || true

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

# --- Trino への直接アクセス（セットアップ・後始末専用。測定対象の文は athena-local 経由で投げる） ---

trino_exec() {
  local sql="$1" catalog="$2" schema="$3"
  local resp next
  resp=$(curl -sf -X POST "$TRINO_BASE/v1/statement" \
    -H "X-Trino-User: e2e-214-setup" \
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

# 引数: 1 bind（127.0.0.1:PORT）、2 TRINO_CATALOG_MAP の値（空文字なら設定しない）、
# 3 TRINO_CATALOG の値（空文字なら設定しない）、4 ログの置き場所、5 起動した PID を書き込む変数名。
# 雛形（quoted-names）は両系統とも常に TRINO_CATALOG=hive を渡すが、#214 の系統 A は TRINO_CATALOG_MAP
# だけで解決できることを確かめたいので TRINO_CATALOG を渡さない。系統ごとに条件付きで足す。
start_athena_local() {
  local bind="$1" catalog_map="$2" default_catalog="$3" athena_log="$4" pid_var="$5"
  log "athena-local を起動する（bind=$bind, TRINO_CATALOG_MAP=${catalog_map:-<無し>}, TRINO_CATALOG=${default_catalog:-<無し>}, ログ: $athena_log）"
  (
    cd "$REPO_ROOT"
    declare -a env_args=(
      ATHENA_LOCAL_BIND="$bind"
      TRINO_URL="$TRINO_BASE"
      TRINO_USER="athena-local-e2e214"
      TRINO_SCHEMA="$SCHEMA"
      ATHENA_LOCAL_RESULTS="none"
    )
    [ -n "$catalog_map" ] && env_args+=(TRINO_CATALOG_MAP="$catalog_map")
    [ -n "$default_catalog" ] && env_args+=(TRINO_CATALOG="$default_catalog")
    exec env "${env_args[@]}" "$BINARY"
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

# --- athena-local の Athena API 呼び出し ---

athena_call() {
  local base="$1" operation="$2" body="$3"
  curl -s -X POST "$base/" \
    -H "X-Amz-Target: AmazonAthena.$operation" \
    -H "Content-Type: application/x-amz-json-1.1" \
    --data "$body"
}

# QueryExecutionContext（Catalog・Database）付きの StartQueryExecution。
start_raw() {
  local base="$1" sql="$2" catalog="$3" database="$4"
  local body
  body=$(jq -cn --arg sql "$sql" --arg catalog "$catalog" --arg db "$database" --arg token "$(uuidgen)" \
    '{QueryString: $sql, QueryExecutionContext: {Catalog: $catalog, Database: $db}, ClientRequestToken: $token}')
  athena_call "$base" StartQueryExecution "$body"
}

# QUEUED/RUNNING でなくなるまで GetQueryExecution をポーリングし、最後の応答を返す。
athena_wait() {
  local base="$1" id="$2" resp state
  for _ in $(seq 1 100); do
    resp=$(athena_call "$base" GetQueryExecution "$(jq -n --arg id "$id" '{QueryExecutionId: $id}')")
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
  local base="$1" sql="$2" catalog="$3" database="$4"
  local start
  start=$(start_raw "$base" "$sql" "$catalog" "$database")
  LAST_ID=$(echo "$start" | jq -r '.QueryExecutionId // empty')
  if [ -z "$LAST_ID" ]; then
    LAST_START="$start"
    LAST_RESP=""
    return 1
  fi
  LAST_START=""
  LAST_RESP=$(athena_wait "$base" "$LAST_ID")
  return 0
}

# 本物の Entity Not Found の形（tools/e2e/quoted-names/verify.sh の写し。Request ID は毎回違う UUID）。
is_entity_not_found() {
  local msg="$1"
  [[ "$msg" =~ ^Entity\ Not\ Found\ \(Service:\ AmazonDataCatalog\;\ Status\ Code:\ 400\;\ Error\ Code:\ EntityNotFoundException\;\ Request\ ID:\ [0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\;\ Proxy:\ null\)$ ]]
}

# --- ケースの判定 ---

# SUCCEEDED になることだけを確かめる。
case_succeeded() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5" base="$6"
  if ! run_and_wait "$base" "$sql" "$catalog" "$database"; then
    record "$no $name" FAIL "開始できなかった: $(echo "$LAST_START" | tr -d '\n' | cut -c1-200)"
    return
  fi
  local state
  state=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.State // empty')
  if [ "$state" = "SUCCEEDED" ]; then
    record "$no $name" PASS "SUCCEEDED [id=$LAST_ID]"
  else
    local reason
    reason=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.StateChangeReason // empty')
    record "$no $name" FAIL "State=$state StateChangeReason=\"$reason\" [id=$LAST_ID]"
  fi
}

# FAILED、AthenaError.ErrorCategory 2・ErrorType 1006、StateChangeReason が CATALOG_NOT_FOUND: で
# 始まることを確かめる（L4）。
case_failed_catalog_not_found() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5" base="$6"
  if ! run_and_wait "$base" "$sql" "$catalog" "$database"; then
    record "$no $name" FAIL "開始できなかった: $(echo "$LAST_START" | tr -d '\n' | cut -c1-200)"
    return
  fi
  local state category type_ reason ok=1 detail=""
  state=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.State // empty')
  category=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.AthenaError.ErrorCategory // empty')
  type_=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.AthenaError.ErrorType // empty')
  reason=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.StateChangeReason // empty')
  [ "$state" = "FAILED" ] || { ok=0; detail="$detail State=${state:-無し}(期待 FAILED)"; }
  [ "$category" = "2" ] || { ok=0; detail="$detail ErrorCategory=${category:-無し}(期待 2)"; }
  [ "$type_" = "1006" ] || { ok=0; detail="$detail ErrorType=${type_:-無し}(期待 1006)"; }
  case "$reason" in
    CATALOG_NOT_FOUND:*) ;;
    *) ok=0; detail="$detail StateChangeReason=\"$reason\"（CATALOG_NOT_FOUND: で始まらない）" ;;
  esac
  if [ "$ok" = "1" ]; then
    record "$no $name" PASS "State=$state ErrorCategory=$category ErrorType=$type_ StateChangeReason=\"$reason\" [id=$LAST_ID]"
  else
    record "$no $name" FAIL "${detail# } [id=$LAST_ID]"
  fi
}

# 開始時に InvalidRequestException／AthenaErrorCode INVALID_INPUT／Entity Not Found の形の
# Message で拒否されることを確かめる（L3）。
case_start_reject_entity_not_found() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5" base="$6"
  LAST_ID=""
  LAST_RESP=""
  local resp qid type_ code msg ok=1 detail=""
  resp=$(start_raw "$base" "$sql" "$catalog" "$database")
  qid=$(echo "$resp" | jq -r '.QueryExecutionId // empty')
  if [ -n "$qid" ]; then
    record "$no $name" FAIL "拒否される想定が開始できてしまった: QueryExecutionId=$qid"
    return
  fi
  type_=$(echo "$resp" | jq -r '.__type // empty')
  code=$(echo "$resp" | jq -r '.AthenaErrorCode // empty')
  msg=$(echo "$resp" | jq -r '.Message // empty')
  [ "$type_" = "InvalidRequestException" ] || { ok=0; detail="$detail __type=${type_:-無し}(期待 InvalidRequestException)"; }
  [ "$code" = "INVALID_INPUT" ] || { ok=0; detail="$detail AthenaErrorCode=${code:-無し}(期待 INVALID_INPUT)"; }
  case "$msg" in
    "Entity Not Found ("*) ;;
    *) ok=0; detail="$detail Message=\"$msg\"（'Entity Not Found (' で始まらない）" ;;
  esac
  if [ "$ok" = "1" ] && ! is_entity_not_found "$msg"; then
    ok=0
    detail="$detail Message=\"$msg\"（本物の Entity Not Found の形と一致しない）"
  fi
  if [ "$ok" = "1" ]; then
    record "$no $name" PASS "AthenaErrorCode=$code Message=\"$msg\""
  else
    record "$no $name" FAIL "${detail# } / 実際: __type=${type_:-無し} AthenaErrorCode=${code:-無し} Message=\"$msg\""
  fi
}

# --- 追加の確かめ（直前の case_* が使った LAST_ID・LAST_RESP を読む） ---

# GetQueryExecution の QueryExecutionContext.Catalog が期待どおり（送った名前の小文字）か。
check_context_catalog() {
  local expect="$1" got
  if [ -z "$LAST_ID" ]; then
    amend_last FAIL "id が無く Context.Catalog を確かめられなかった"
    return
  fi
  got=$(echo "$LAST_RESP" | jq -r '.QueryExecution.QueryExecutionContext.Catalog // empty')
  if [ "$got" = "$expect" ]; then
    amend_last PASS "Context.Catalog=$got"
  else
    amend_last FAIL "Context.Catalog=${got:-無し}(期待 $expect)"
  fi
}

# GetQueryResults の Rows のどこかに want を含む文字列があるか（SHOW SCHEMAS の e2e214、
# SHOW TABLES の t214）。
check_rows_contain() {
  local base="$1" want="$2" resp
  if [ -z "$LAST_ID" ]; then
    amend_last FAIL "id が無く GetQueryResults を確かめられなかった"
    return
  fi
  resp=$(athena_call "$base" GetQueryResults "$(jq -n --arg id "$LAST_ID" '{QueryExecutionId: $id}')")
  if echo "$resp" | jq -e --arg w "$want" \
    '[.ResultSet.Rows[]?.Data[]?.VarCharValue] | map(select(. != null)) | any(contains($w))' \
    >/dev/null 2>&1; then
    amend_last PASS "GetQueryResults に $want を含む"
  else
    local rows
    rows=$(echo "$resp" | jq -c '[.ResultSet.Rows[]?.Data[]?.VarCharValue]' 2>/dev/null | cut -c1-300)
    amend_last FAIL "GetQueryResults に $want を含まない(rows=$rows)"
  fi
}

# 直前のケースの GetQueryResults の行が、同じ文を対照のカタログ（$3）で投げたときの行と一致するかを確かめる。
# compose の hive は SHOW SCHEMAS に作ったスキーマを出さない（information_schema だけ）ので、名前の有無ではなく
# 対照との一致で差し替え先を確かめる。LAST_* は直前のケースのものに戻す（続く check_context_catalog のため）。
check_rows_same_as() {
  local base="$1" sql="$2" control_catalog="$3" database="$4"
  local saved_id="$LAST_ID" saved_resp="$LAST_RESP" saved_start="$LAST_START" rows control
  rows=$(athena_call "$base" GetQueryResults "$(jq -n --arg id "$saved_id" '{QueryExecutionId: $id}')" \
    | jq -c '[.ResultSet.Rows[]?.Data[]?.VarCharValue]')
  if run_and_wait "$base" "$sql" "$control_catalog" "$database"; then
    control=$(athena_call "$base" GetQueryResults "$(jq -n --arg id "$LAST_ID" '{QueryExecutionId: $id}')" \
      | jq -c '[.ResultSet.Rows[]?.Data[]?.VarCharValue]')
  fi
  LAST_ID="$saved_id" LAST_RESP="$saved_resp" LAST_START="$saved_start"
  if [ -n "$rows" ] && [ "$rows" = "${control:-}" ]; then
    amend_last PASS "GetQueryResults が Catalog=$control_catalog の対照と一致(rows=$(echo "$rows" | cut -c1-120))"
  else
    amend_last FAIL "GetQueryResults が Catalog=$control_catalog の対照と違う(rows=$(echo "$rows" | cut -c1-120) 対照=$(echo "${control:-}" | cut -c1-120))"
  fi
}

# --- ケース ---

run_cases() {
  # L1: 系統A・SHOW SCHEMAS。SUCCEEDED、結果が Catalog=hive の対照と一致し、Context.Catalog は小文字で返る。
  case_succeeded "L1" "SHOW SCHEMAS（実在しない Catalog）" "SHOW SCHEMAS" "$NOCAT" "$SCHEMA" "$ATHENA_BASE"
  check_rows_same_as "$ATHENA_BASE" "SHOW SCHEMAS" hive "$SCHEMA"
  check_context_catalog "$NOCAT_LOWER"

  # L2: 系統A・DESCRIBE t214（実在）。SUCCEEDED。
  case_succeeded "L2" "DESCRIBE t214（実在するテーブル）" "DESCRIBE t214" "$NOCAT" "$SCHEMA" "$ATHENA_BASE"

  # L3: 系統A・DESCRIBE t214_nope（実在しない）。開始時に Entity Not Found。
  case_start_reject_entity_not_found "L3" "DESCRIBE t214_nope（実在しないテーブル）" "DESCRIBE t214_nope" \
    "$NOCAT" "$SCHEMA" "$ATHENA_BASE"

  # L4: 系統A・SELECT * FROM t214。FAILED、ErrorCategory 2／ErrorType 1006、Context.Catalog は小文字。
  case_failed_catalog_not_found "L4" "SELECT * FROM t214" "SELECT * FROM t214" "$NOCAT" "$SCHEMA" "$ATHENA_BASE"
  check_context_catalog "$NOCAT_LOWER"

  # L5: 系統A・SELECT 1。カタログを引かないので SUCCEEDED。
  case_succeeded "L5" "SELECT 1" "SELECT 1" "$NOCAT" "$SCHEMA" "$ATHENA_BASE"

  # L6: 系統A・Catalog=hive（実在）・DESCRIBE t214。差し替え無しでも SUCCEEDED。
  case_succeeded "L6" "DESCRIBE t214（Catalog=hive）" "DESCRIBE t214" "hive" "$SCHEMA" "$ATHENA_BASE"

  # L7: 系統B（TRINO_CATALOG_MAP 無し・TRINO_CATALOG=hive）・SHOW TABLES。SUCCEEDED、結果に t214 を含む。
  case_succeeded "L7" "SHOW TABLES（TRINO_CATALOG_MAP 無し）" "SHOW TABLES" "$NOCAT" "$SCHEMA" "$ATHENA_BASE2"
  check_rows_contain "$ATHENA_BASE2" "t214"

  # L8: 系統A・DROP TABLE IF EXISTS t214_nope（実在しない）。SUCCEEDED（IF EXISTS で何もしない）。
  case_succeeded "L8" "DROP TABLE IF EXISTS t214_nope" "DROP TABLE IF EXISTS t214_nope" "$NOCAT" "$SCHEMA" "$ATHENA_BASE"

  # L9: 系統A・SHOW CREATE TABLE t214。SUCCEEDED。
  case_succeeded "L9" "SHOW CREATE TABLE t214" "SHOW CREATE TABLE t214" "$NOCAT" "$SCHEMA" "$ATHENA_BASE"

  # L10: 系統A・SHOW COLUMNS FROM t214。SUCCEEDED。
  case_succeeded "L10" "SHOW COLUMNS FROM t214" "SHOW COLUMNS FROM t214" "$NOCAT" "$SCHEMA" "$ATHENA_BASE"
}

main() {
  log "作業ディレクトリ: $SCRIPT_DIR"
  log "証跡の保存先: $EVIDENCE_DIR"

  if ! build_athena_local; then
    record "cargo build" FAIL "ビルドが失敗した"
    return 1
  fi
  record "cargo build" PASS "$BINARY を用意した"

  # 前の走行の残骸を持ち越さないよう、trino を作り直す。
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

  log "Trino 側のスキーマ・テーブルを用意する"
  if ! trino_exec "CREATE SCHEMA IF NOT EXISTS hive.${SCHEMA}" hive default; then
    record "セットアップ(スキーマ)" FAIL "hive.${SCHEMA} の作成に失敗した"
    return 1
  fi
  if ! trino_exec "CREATE TABLE hive.${SCHEMA}.t214 AS SELECT 1 AS n" hive "$SCHEMA"; then
    record "セットアップ(テーブル)" FAIL "hive.${SCHEMA}.t214 の作成に失敗した"
    return 1
  fi
  record "セットアップ" PASS "hive.${SCHEMA}.t214 作成済み（t214_nope はどのケースも実在しない前提なので作らない）"

  if ! start_athena_local "$ATHENA_BIND" "AwsDataCatalog=hive" "" "$ATHENA_LOG" ATHENA_PID; then
    record "athena-local起動(系統A)" FAIL "athena-local が起動しなかった"
    return 1
  fi
  record "athena-local起動(系統A)" PASS "$ATHENA_BASE で応答（TRINO_CATALOG_MAP=AwsDataCatalog=hive）"

  if ! start_athena_local "$ATHENA_BIND2" "" "hive" "$ATHENA_LOG2" ATHENA_PID2; then
    record "athena-local起動(系統B)" FAIL "athena-local（TRINO_CATALOG_MAP 無し）が起動しなかった"
    return 1
  fi
  record "athena-local起動(系統B)" PASS "$ATHENA_BASE2 で応答（TRINO_CATALOG_MAP 無し・TRINO_CATALOG=hive）"

  run_cases
}

main
