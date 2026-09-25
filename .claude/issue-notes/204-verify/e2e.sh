#!/usr/bin/env bash
# issue #204 の実機検証の足場。
#
# 引用符付きの名前を取る DESCRIBE / DESC / SHOW CREATE TABLE / SHOW COLUMNS / DROP TABLE / ALTER TABLE を
# 本物の Athena は StartQueryExecution の開始時に 400（MALFORMED_QUERY）で弾く（#204 本文、
# .claude/issue-notes/204.md の実測）。本物の Trino（compose の trino、memory カタログ）を相手に
# athena-local を動かし、この 12 ケース（q1〜q12）と、弾かないはずの対照 9 ケース（c1〜c9）を
# StartQueryExecution で投げ、応答を 400 のケースと 200 のケースに分けて表にする。
#
# 雛形: `git show b3f59d9:.claude/issue-notes/200-verify/e2e.sh`（#200 の同種の足場）。
#
# 前提: tools/dev.sh 経由で toolbox の中で動かす（`aws` は使わず、S3 は toolbox の mc で minio:9000 を
# 直接見る）。環境はルートの compose.yml の trino / minio / minio-init。開始時に使うサービスだけ
# down -v → up -d で作り直す。既定の compose プロジェクト（trino が既に立っている場合がある）を
# 落とさない・作り直さないよう、呼び出し側でプロジェクト名を専用のものに分けること:
#   COMPOSE_PROJECT_NAME=athena204 tools/dev.sh .claude/issue-notes/204-verify/e2e.sh
#
# 環境変数:
#   KEEP_UP=1        終了時に docker compose down -v <サービス...> をせず環境を残す（デバッグ用）
#   SKIP_BUILD=1     cargo build を省略し、既存の $CARGO_TARGET_DIR（tools/dev.sh では .toolbox/target）の
#                    release/athena-local をそのまま使う
#   EXPECT=after     ケース表の期待値（本物の実測に合わせたもの）と照合し、ラベルごとに PASS/FAIL を
#                    出す。q1〜q12 は 400・MALFORMED_QUERY・決まった文言（q6/q7 は前方一致）を、
#                    c1〜c9 は 200・SUCCEEDED を期待する。省略時（既定）は測った値をそのまま表にする
#                    だけで、合否は付けない。
#
# 終了コード: EXPECT=after のとき FAIL の件数（0 なら全 PASS）。それ以外は StartQueryExecution 自体が
# 想定外のステータスを返したケースの件数（0 なら異常なし）。
#
# 副作用の注意: q8（ALTER TABLE "t" RENAME TO u）は、直す前の athena-local ではそのまま Trino に
# 送られ、本物に本当に table t を u へ改名させてしまう可能性がある。後続のケース（q9〜c9）が
# table t を前提にしているため、q8 の直後に u を消して t を作り直す後始末を必ず挟む。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BINARY="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/athena-local"
COMPOSE=(docker compose -f "$REPO_ROOT/compose.yml")
SERVICES=(trino minio minio-init)

TRINO_BASE="http://trino:8080"
MINIO_ENDPOINT="http://minio:9000"
ATHENA_BASE="http://127.0.0.1:8096"
BUCKET="athena-results"
PREFIX="e2e204"
OUTPUT_LOCATION="s3://${BUCKET}/${PREFIX}/"
CATALOG="memory"
DATABASE="default"
EXPECT="${EXPECT:-raw}"

EVIDENCE_DIR="$(mktemp -d /tmp/athena-local-issue204-e2e.XXXXXX)"
ATHENA_LOG="$EVIDENCE_DIR/athena-local.log"
BUILD_LOG="$EVIDENCE_DIR/cargo-build.log"

ATHENA_PID=""

# --- 結果の記録 ---
declare -a LABELS=()
declare -A SQLS=() STATUS=() TYPES=() ACODES=() MSGS=() STATES=() STMTS=() SUBSTMTS=() JUDGE=()
# --- 期待値（EXPECT=after で使う。issue 本文のケース表そのまま） ---
declare -A EXP_KIND=() EXP_CODE=() EXP_MSG=() EXP_MSG_MODE=()

log() { echo "[e2e204] $*" >&2; }

trunc() {
  local s="$1" n="${2:-70}"
  s="${s//$'\n'/\\n}" # 表の行を壊さないよう、実際の改行は見た目だけ \n の 2 文字にする（q11）
  if [ "${#s}" -gt "$n" ]; then echo "${s:0:$n}…"; else echo "$s"; fi
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
    log "docker compose down -v ${SERVICES[*]}（使ったサービスだけ）"
    "${COMPOSE[@]}" down -v "${SERVICES[@]}" >/dev/null 2>&1
  fi
  print_tables
  exit "$status"
}
trap cleanup EXIT

# --- Trino への直接アクセス（テーブル／ビューの準備・後始末専用。測定対象の文は athena-local 経由で投げる） ---

trino_exec() {
  local sql="$1" catalog="$2" schema="$3"
  local resp next
  resp=$(curl -sf -X POST "$TRINO_BASE/v1/statement" \
    -H "X-Trino-User: e2e204-setup" \
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
  for _ in $(seq 1 90); do
    trino_exec "SELECT 1" system runtime >/dev/null 2>&1 && { log "Trino 起動確認"; return 0; }
    sleep 2
  done
  log "Trino が起動しなかった"
  return 1
}

wait_for_bucket() {
  log "MinIO バケットの用意待ち"
  for _ in $(seq 1 60); do
    mc ls "local/$BUCKET" >/dev/null 2>&1 && { log "バケット確認: $BUCKET"; return 0; }
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
  log "ビルド失敗。ログ末尾 40 行:"
  tail -n 40 "$BUILD_LOG" >&2
  return 1
}

start_athena_local() {
  log "athena-local を起動する ($ATHENA_BASE)"
  (
    cd "$REPO_ROOT"
    exec env \
      ATHENA_LOCAL_BIND="127.0.0.1:8096" \
      TRINO_URL="$TRINO_BASE" \
      TRINO_USER="athena-local-e2e204" \
      TRINO_CATALOG="$CATALOG" \
      TRINO_SCHEMA="$DATABASE" \
      ATHENA_LOCAL_RESULTS="s3" \
      AWS_ENDPOINT_URL_S3="$MINIO_ENDPOINT" \
      AWS_ACCESS_KEY_ID="minioadmin" \
      AWS_SECRET_ACCESS_KEY="minioadmin" \
      ATHENA_LOCAL_OUTPUT_LOCATION="$OUTPUT_LOCATION" \
      "$BINARY"
  ) >"$ATHENA_LOG" 2>&1 &
  ATHENA_PID=$!
  for _ in $(seq 1 30); do
    if ! kill -0 "$ATHENA_PID" 2>/dev/null; then
      log "athena-local が異常終了した。ログ:"
      cat "$ATHENA_LOG" >&2
      return 1
    fi
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ATHENA_BASE/" \
      -H "X-Amz-Target: AmazonAthena.ListWorkGroups" -H "Content-Type: application/x-amz-json-1.1" --data '{}')
    [ "$status" = "200" ] && { log "athena-local 起動確認"; return 0; }
    sleep 1
  done
  log "athena-local が応答しなかった"
  return 1
}

# --- athena-local の Athena API 呼び出し ---

athena_call() {
  curl -s -X POST "$ATHENA_BASE/" -H "X-Amz-Target: AmazonAthena.$1" \
    -H "Content-Type: application/x-amz-json-1.1" --data "$2"
}

athena_wait() {
  local id="$1" resp state
  for _ in $(seq 1 100); do
    resp=$(athena_call GetQueryExecution "$(jq -n --arg id "$id" '{QueryExecutionId: $id}')")
    state=$(echo "$resp" | jq -r '.QueryExecution.Status.State // empty')
    [ "$state" = QUEUED ] || [ "$state" = RUNNING ] || { echo "$resp"; return 0; }
    sleep 0.3
  done
  echo "$resp"
}

# --- 1 ケースぶんの計測: StartQueryExecution → 400 ならそのまま記録、200 なら完了を待つ ---

run_case() {
  local label="$1" sql="$2"
  local body_file="$EVIDENCE_DIR/$label.start.json" req status id resp
  LABELS+=("$label")
  SQLS[$label]="$sql"

  req=$(jq -n --arg sql "$sql" --arg catalog "$CATALOG" --arg db "$DATABASE" --arg token "$(uuidgen)" \
    '{QueryString: $sql, QueryExecutionContext: {Catalog: $catalog, Database: $db}, ClientRequestToken: $token}')
  status=$(curl -s -o "$body_file" -w '%{http_code}' -X POST "$ATHENA_BASE/" \
    -H "X-Amz-Target: AmazonAthena.StartQueryExecution" -H "Content-Type: application/x-amz-json-1.1" --data "$req")
  STATUS[$label]="$status"

  if [ "$status" = "400" ]; then
    TYPES[$label]=$(jq -r '.__type // "-"' "$body_file")
    ACODES[$label]=$(jq -r '.AthenaErrorCode // "-"' "$body_file")
    MSGS[$label]=$(jq -r '.Message // "-"' "$body_file")
    STATES[$label]="-"
    STMTS[$label]="-"
    SUBSTMTS[$label]="-"
    return
  fi

  TYPES[$label]="-"
  ACODES[$label]="-"
  MSGS[$label]="-"

  if [ "$status" != "200" ]; then
    log "label=$label StartQueryExecution が想定外のステータス $status を返した: $sql"
    STATES[$label]="START異常(${status})"
    STMTS[$label]="-"
    SUBSTMTS[$label]="-"
    return
  fi

  id=$(jq -r '.QueryExecutionId // empty' "$body_file")
  if [ -z "$id" ]; then
    log "label=$label 200 なのに QueryExecutionId が無い: $sql"
    STATES[$label]="START異常(200)"
    STMTS[$label]="-"
    SUBSTMTS[$label]="-"
    return
  fi

  resp=$(athena_wait "$id")
  echo "$resp" >"$EVIDENCE_DIR/$label.get.json"
  STATES[$label]=$(echo "$resp" | jq -r '.QueryExecution.Status.State // "?"')
  STMTS[$label]=$(echo "$resp" | jq -r '.QueryExecution.StatementType // "-"')
  SUBSTMTS[$label]=$(echo "$resp" | jq -r '.QueryExecution.SubstatementType // "-"')
}

# --- 期待値（issue 本文のケース表。本物の実測に合わせたもの） ---

setup_expectations() {
  local label
  for label in q1 q2 q3 q4 q5 q6 q7 q8 q9 q10 q11 q12; do
    EXP_KIND[$label]="400"
    EXP_CODE[$label]="MALFORMED_QUERY"
    EXP_MSG_MODE[$label]="exact"
  done
  for label in c1 c2 c3 c4 c5 c6 c7 c8 c9; do
    EXP_KIND[$label]="200"
  done

  EXP_MSG[q1]="line 1:10: no viable alternative at input 'DESCRIBE \"t\"'"
  EXP_MSG[q2]="line 1:9: no viable alternative at input 'DESCRIBE\"t\"'"
  EXP_MSG[q3]="line 1:6: no viable alternative at input 'DESC \"t\"'"
  EXP_MSG[q4]="line 1:18: no viable alternative at input 'default.\"t\"'"
  EXP_MSG[q5]="Queries of this type are not supported"
  EXP_MSG[q6]="line 1:19: mismatched input '\"t\"' expecting {"
  EXP_MSG_MODE[q6]="prefix"
  EXP_MSG[q7]="line 1:22: mismatched input '\"nope\"' expecting {"
  EXP_MSG_MODE[q7]="prefix"
  EXP_MSG[q8]="line 1:13: no viable alternative at input 'ALTER TABLE \"t\"'"
  EXP_MSG[q9]="line 1:10: no viable alternative at input 'DESCRIBE \"t\"'"
  EXP_MSG[q10]="line 1:18: no viable alternative at input 'DESCRIBE \"t\"'"
  EXP_MSG[q11]="line 2:1: no viable alternative at input 'DESCRIBE\\n\"t\"'"
  EXP_MSG[q12]="line 1:21: mismatched input 'COLUMNS'. Expecting: '.', 'ADD'"
}

judge_label() {
  local label="$1"
  case "${EXP_KIND[$label]:-}" in
    400)
      if [ "${STATUS[$label]}" != "400" ] || [ "${ACODES[$label]}" != "${EXP_CODE[$label]}" ]; then
        echo FAIL
        return
      fi
      if [ "${EXP_MSG_MODE[$label]}" = "prefix" ]; then
        case "${MSGS[$label]}" in
          "${EXP_MSG[$label]}"*) echo PASS ;;
          *) echo FAIL ;;
        esac
      else
        if [ "${MSGS[$label]}" = "${EXP_MSG[$label]}" ]; then echo PASS; else echo FAIL; fi
      fi
      ;;
    200)
      if [ "${STATUS[$label]}" = "200" ] && [ "${STATES[$label]}" = "SUCCEEDED" ]; then
        echo PASS
      else
        echo FAIL
      fi
      ;;
    *)
      echo "-"
      ;;
  esac
}

# --- 表の出力 ---

print_tables() {
  echo
  echo "==================== 結果（issue #204）: StartQueryExecution が 400 を返したケース ===================="
  if [ "$EXPECT" = after ]; then
    printf "%-4s %-38s %-4s %-24s %-16s %-72s %-6s\n" "#" "SQL" "HTTP" "__type" "AthenaErrorCode" "Message" "判定"
  else
    printf "%-4s %-38s %-4s %-24s %-16s %-72s\n" "#" "SQL" "HTTP" "__type" "AthenaErrorCode" "Message"
  fi
  local label
  for label in "${LABELS[@]}"; do
    [ "${STATUS[$label]}" = "400" ] || continue
    if [ "$EXPECT" = after ]; then
      printf "%-4s %-38s %-4s %-24s %-16s %-72s %-6s\n" \
        "$label" "$(trunc "${SQLS[$label]}" 36)" "${STATUS[$label]}" "${TYPES[$label]}" "${ACODES[$label]}" \
        "$(trunc "${MSGS[$label]}" 70)" "${JUDGE[$label]:--}"
    else
      printf "%-4s %-38s %-4s %-24s %-16s %-72s\n" \
        "$label" "$(trunc "${SQLS[$label]}" 36)" "${STATUS[$label]}" "${TYPES[$label]}" "${ACODES[$label]}" \
        "$(trunc "${MSGS[$label]}" 70)"
    fi
  done

  echo
  echo "==================== 結果（issue #204）: StartQueryExecution が 200 を返した（または想定外の）ケース ===================="
  if [ "$EXPECT" = after ]; then
    printf "%-4s %-38s %-4s %-14s %-24s %-20s %-6s\n" "#" "SQL" "HTTP" "State" "StatementType" "SubstatementType" "判定"
  else
    printf "%-4s %-38s %-4s %-14s %-24s %-20s\n" "#" "SQL" "HTTP" "State" "StatementType" "SubstatementType"
  fi
  for label in "${LABELS[@]}"; do
    [ "${STATUS[$label]}" = "400" ] && continue
    if [ "$EXPECT" = after ]; then
      printf "%-4s %-38s %-4s %-14s %-24s %-20s %-6s\n" \
        "$label" "$(trunc "${SQLS[$label]}" 36)" "${STATUS[$label]}" "${STATES[$label]}" "${STMTS[$label]}" \
        "${SUBSTMTS[$label]}" "${JUDGE[$label]:--}"
    else
      printf "%-4s %-38s %-4s %-14s %-24s %-20s\n" \
        "$label" "$(trunc "${SQLS[$label]}" 36)" "${STATUS[$label]}" "${STATES[$label]}" "${STMTS[$label]}" \
        "${SUBSTMTS[$label]}"
    fi
  done
  echo "=============================================================================================="
  log "証跡（応答 JSON・athena-local のログ・ビルドログ）: $EVIDENCE_DIR"
}

# --- 本編 ---

main() {
  setup_expectations
  log "作業ディレクトリ: $SCRIPT_DIR"
  log "証跡の保存先: $EVIDENCE_DIR"

  log "docker compose down -v / up -d ${SERVICES[*]}（前の走行の残骸を持ち越さない）"
  "${COMPOSE[@]}" down -v "${SERVICES[@]}" >/dev/null 2>&1 || true
  if ! "${COMPOSE[@]}" up -d "${SERVICES[@]}"; then
    log "docker compose up -d ${SERVICES[*]} が失敗した"
    return 1
  fi

  if ! mc alias set local "$MINIO_ENDPOINT" minioadmin minioadmin >/dev/null; then
    log "mc alias set が失敗した（minio:9000 に繋がらない）"
    return 1
  fi
  wait_for_trino || return 1
  wait_for_bucket || return 1

  if ! build_athena_local; then
    log "cargo build が失敗したため測定を実行しない"
    return 1
  fi
  start_athena_local || return 1

  log "準備: table t を作る（DESCRIBE / DESC / SHOW CREATE TABLE / SHOW COLUMNS / DROP TABLE / ALTER TABLE の対象）"
  trino_exec "CREATE TABLE t AS SELECT 1 AS x" "$CATALOG" "$DATABASE" || log "table t の作成に失敗（続行して測定する）"

  # --- q1〜q12: 引用符付きの名前を取る形（本物は開始時に 400 で弾く） ---
  run_case q1 'DESCRIBE "t"'
  run_case q2 'DESCRIBE"t"'
  run_case q3 'DESC "t"'
  run_case q4 'DESCRIBE default."t"'
  run_case q5 'SHOW CREATE TABLE "t"'
  run_case q6 'SHOW COLUMNS FROM "t"'
  run_case q7 'DROP TABLE IF EXISTS "nope"'
  run_case q8 'ALTER TABLE "t" RENAME TO u'
  # 副作用の後始末: 直す前の athena-local では q8 がそのまま Trino に送られ、本当に
  # table t を u へ改名させてしまう可能性がある。後続のケースが table t を前提にしているため、
  # u を消してから t を作り直す（既に有れば IF NOT EXISTS で無視）。
  trino_exec 'DROP TABLE IF EXISTS u' "$CATALOG" "$DATABASE" || true
  trino_exec 'CREATE TABLE IF NOT EXISTS t AS SELECT 1 AS x' "$CATALOG" "$DATABASE" || true
  run_case q9 '  DESCRIBE "t"'
  run_case q10 '/* c */ DESCRIBE "t"'
  run_case q11 "$(printf 'DESCRIBE\n"t"')"
  run_case q12 'ALTER TABLE "t" ADD COLUMNS (m int)'

  # --- c1〜c9: 弾かないはずの対照（after でも 200 で SUCCEEDED） ---
  run_case c1 'DESCRIBE t'
  run_case c2 'SHOW CREATE TABLE t'
  run_case c3 'SHOW COLUMNS FROM t'
  run_case c4 'CREATE TABLE "t2" AS SELECT 1 AS x'
  run_case c5 'CREATE VIEW "v" AS SELECT 1 AS x'
  run_case c6 'SHOW CREATE VIEW "v"'
  run_case c7 'DROP VIEW "v"'
  run_case c8 'SELECT * FROM "t"'
  run_case c9 'DROP TABLE IF EXISTS t2'

  log "後始末: table t・t2 とビュー v、q8/q12 が万一通っていた場合の残骸を安全網として消す"
  trino_exec 'DROP TABLE IF EXISTS t' "$CATALOG" "$DATABASE" || true
  trino_exec 'DROP TABLE IF EXISTS t2' "$CATALOG" "$DATABASE" || true
  trino_exec 'DROP TABLE IF EXISTS u' "$CATALOG" "$DATABASE" || true
  trino_exec 'DROP TABLE IF EXISTS nope' "$CATALOG" "$DATABASE" || true
  trino_exec 'DROP VIEW IF EXISTS v' "$CATALOG" "$DATABASE" || true

  local fails=0 label
  if [ "$EXPECT" = after ]; then
    for label in "${LABELS[@]}"; do
      JUDGE[$label]="$(judge_label "$label")"
      [ "${JUDGE[$label]}" = "FAIL" ] && fails=$((fails + 1))
    done
  else
    for label in "${LABELS[@]}"; do
      case "${STATES[$label]}" in
        START異常*) fails=$((fails + 1)) ;;
      esac
    done
  fi
  log "PASS/FAIL の集計は $fails 件（EXPECT=$EXPECT。詳しい内訳は表を参照）"
  return "$fails"
}

main
