#!/usr/bin/env bash
# issue #83 で作成（tools/ へ移す前の名前は 83-e2e/verify.sh）
# issue #83 Step 9（実機検証）: 本物の Trino（trinodb/trino:482）を相手に athena-local の release
# バイナリを動かし、GetQueryResults と ListWorkGroups に範囲外の MaxResults と不正な NextToken を
# 送って、本物の Athena で 2026-09-23 に実測した応答と一致するかを確かめる。
# 本物の AWS は一切使わない。結果ファイルは書かない（ATHENA_LOCAL_RESULTS=none）。
#
# 期待値は本物の実測値ひとつだけをハードコードしている（「変更前の期待値」に切り替える環境変数は無い）。
# したがって **#83 の変更が入る前のビルドで流すと、検証系のケースは FAIL・対照（正常系）は PASS に
# なるのが正しい**。
# 変更前の予測:
#   PASS: 1〜4（正常系の対照）、13（存在しない ID）、15（存在確認が上限より先）、
#         16・17（FAILED の状態エラー。トークンの形は見ない）
#   FAIL: 5〜12（範囲外の MaxResults・空や不正な NextToken がそのまま 200 で通る、または
#         検証エラーが 1 件分の文言にしかならない）、14（存在確認が先に走って NOT_FOUND になる）、
#         18（状態エラーが先に走る）、19（ListWorkGroups が 200 で通る）
#
# 前提コマンド: tools/dev.sh 経由で動かす（toolbox に全部入っている）
# 環境はルートの compose.yml の trino。開始時に down -v → up -d で作り直す。
# jq にはファイルを引数でなく標準入力（<）で渡す。
#
# 使い方:
#   tools/dev.sh tools/e2e/paging-validation/verify.sh
#
# 環境変数:
#   KEEP_UP=1        テスト後に docker compose down -v <サービス...> をせず環境を残す（デバッグ用）
#   SKIP_BUILD=1     cargo build を省略し、既存の $CARGO_TARGET_DIR（tools/dev.sh では .toolbox/target）の release/athena-local をそのまま使う
#
# 後始末は本スクリプトの trap が行う（KEEP_UP=1 でなければ必ず docker compose down -v する）。
# 落とすのは使ったサービス（trino）だけで、dev やほかのサービスには触らない。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# cargo の成果物の置き場。tools/dev.sh は CARGO_TARGET_DIR を .toolbox/target にする
BINARY="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/athena-local"
COMPOSE=(docker compose -f "$REPO_ROOT/compose.yml")
SERVICES=(trino)

TRINO_BASE="http://trino:8080"
ATHENA_BIND="127.0.0.1:8089"
ATHENA_BASE="http://${ATHENA_BIND}"

MISSING_ID="00000000-0000-4000-8000-000000000083"

MSG_MAX_OVER="MaxResults is more than maximum allowed length 1000"
MSG_MAX_UNDER="1 validation error detected: Value at 'maxResults' failed to satisfy constraint: Member must have value greater than or equal to 1"
MSG_TOKEN_EMPTY="1 validation error detected: Value at 'nextToken' failed to satisfy constraint: Member must have length greater than or equal to 1"
MSG_TOKEN_MALFORMED="Malformed nextPageToken not-a-token"
MSG_TWO_ERRORS="2 validation errors detected: Value at 'nextToken' failed to satisfy constraint: Member must have length greater than or equal to 1; Value at 'maxResults' failed to satisfy constraint: Member must have value greater than or equal to 1"
MSG_FAILED_STATE="Query did not finish successfully. Final query state: FAILED"

EVIDENCE_DIR="$(mktemp -d /tmp/athena-local-issue83-e2e.XXXXXX)"
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
    printf "%-6s %-40s %s\n" "${RESULT_STATUS[$i]}" "${RESULT_NAMES[$i]}" "${RESULT_DETAIL[$i]}"
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
  echo "PASS=$pass FAIL=$fail SKIP(未測定)=$skip"
  if [ "$fail" -gt 0 ]; then
    echo "FAIL の一覧:"
    for i in "${failed[@]}"; do
      echo "  - $i"
    done
  fi
  echo "証跡（応答 JSON・ログ）: $EVIDENCE_DIR"
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
    log "KEEP_UP=1 のため docker compose はそのまま残す（後で tools/dev.sh docker compose -f compose.yml down -v ${SERVICES[*]}）"
  else
    log "docker compose down -v ${SERVICES[*]}（使ったサービスだけ）"
    "${COMPOSE[@]}" down -v "${SERVICES[@]}" >/dev/null 2>&1
  fi
  if ! print_table; then
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT

# --- 準備 ---

wait_for_trino() {
  log "Trino の起動待ち ($TRINO_BASE)"
  local _ resp next ok
  for _ in $(seq 1 90); do
    ok=0
    resp=$(curl -sf -X POST "$TRINO_BASE/v1/statement" -H "X-Trino-User: e2e-setup" --data-binary "SELECT 1" 2>/dev/null)
    while [ -n "$resp" ]; do
      if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
        break
      fi
      next=$(echo "$resp" | jq -r '.nextUri // empty' 2>/dev/null)
      if [ -z "$next" ]; then
        ok=1
        break
      fi
      resp=$(curl -sf "$next" 2>/dev/null)
    done
    if [ "$ok" = "1" ]; then
      log "Trino 起動確認"
      return 0
    fi
    sleep 2
  done
  log "Trino が起動しなかった"
  return 1
}

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
  log "athena-local を起動する（ログ: $ATHENA_LOG）"
  # 結果ファイルは書かない（ATHENA_LOCAL_RESULTS=none）。既定の文脈は常に存在する system.runtime。
  (
    cd "$REPO_ROOT"
    exec env \
      ATHENA_LOCAL_BIND="$ATHENA_BIND" \
      TRINO_URL="$TRINO_BASE" \
      TRINO_USER="athena-local-e2e83" \
      TRINO_CATALOG="system" \
      TRINO_SCHEMA="runtime" \
      ATHENA_LOCAL_RESULTS="none" \
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
      --data '{}')
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

# 本文を $out に書き、HTTP ステータスを標準出力に返す。
athena_call() {
  local operation="$1" body="$2" out="$3"
  curl -s -o "$out" -w '%{http_code}' -X POST "$ATHENA_BASE/" \
    -H "Content-Type: application/x-amz-json-1.1" \
    -H "X-Amz-Target: AmazonAthena.$operation" \
    --data "$body"
}

# クエリを流して終端状態を待つ。成功すれば QueryExecutionId を標準出力に返す。
# 戻り値: 0=期待した終端状態、2=StartQueryExecution が失敗、1=それ以外（時間切れ・別の状態）
start_and_wait() {
  local label="$1" sql="$2" expect_state="$3"
  local out="$EVIDENCE_DIR/prep-${label}.start.json" status id state _
  # athena-local は ClientRequestToken が無いと 400（clientRequestToken is null or empty）を返すので付ける。
  status=$(athena_call StartQueryExecution \
    "$(jq -n --arg sql "$sql" --arg token "$(uuidgen)" '{QueryString: $sql, ClientRequestToken: $token}')" "$out")
  id=$(jq -r '.QueryExecutionId // empty' <"$out" 2>/dev/null)
  if [ "$status" != "200" ] || [ -z "$id" ]; then
    log "準備 $label: StartQueryExecution が失敗した (HTTP $status): $(tr -d '\n' <"$out")"
    return 2
  fi
  local exec_out="$EVIDENCE_DIR/prep-${label}.execution.json"
  for _ in $(seq 1 30); do
    athena_call GetQueryExecution "$(jq -n --arg id "$id" '{QueryExecutionId: $id}')" "$exec_out" >/dev/null
    state=$(jq -r '.QueryExecution.Status.State // empty' <"$exec_out" 2>/dev/null)
    case "$state" in
      QUEUED | RUNNING) sleep 2 ;;
      *) break ;;
    esac
  done
  if [ "$state" != "$expect_state" ]; then
    log "準備 $label: 終了状態が $expect_state でない: ${state:-不明} ($(jq -r '.QueryExecution.Status.StateChangeReason // empty' <"$exec_out"))"
    return 1
  fi
  log "準備 $label: $id は $state"
  echo "$id"
  return 0
}

# --- ケース ---
#
# check_case <番号> <操作> <本文JSON> <期待ステータス> <期待 AthenaErrorCode|-> <Message の判定 exact|contains|-> <期待 Message>
#            <期待 Rows 件数|-> <NextToken present|absent|->
check_case() {
  local no="$1" op="$2" body="$3" exp_status="$4" exp_code="$5" msg_mode="$6" exp_msg="$7"
  local exp_rows="${8:--}" exp_token="${9:--}"
  local out="$EVIDENCE_DIR/case-${no}.json"
  printf '%s\n' "$body" >"$EVIDENCE_DIR/case-${no}.request.json"

  local status type code msg rows token
  status=$(athena_call "$op" "$body" "$out")
  type=$(jq -r '.__type // empty' <"$out" 2>/dev/null)
  code=$(jq -r '.AthenaErrorCode // empty' <"$out" 2>/dev/null)
  msg=$(jq -r '.Message // .message // empty' <"$out" 2>/dev/null)
  rows=$(jq -r '.ResultSet.Rows // [] | length' <"$out" 2>/dev/null)
  if jq -e 'has("NextToken") and .NextToken != null' <"$out" >/dev/null 2>&1; then
    token=present
  else
    token=absent
  fi

  local ok=1 diff=""
  if [ "$status" != "$exp_status" ]; then
    ok=0
    diff="$diff status=$status(期待 $exp_status)"
  fi
  if [ "$exp_status" = "400" ]; then
    if [ "$type" != "InvalidRequestException" ]; then
      ok=0
      diff="$diff __type=${type:-無し}(期待 InvalidRequestException)"
    fi
    if [ "$code" != "$exp_code" ]; then
      ok=0
      diff="$diff AthenaErrorCode=${code:-無し}(期待 $exp_code)"
    fi
    case "$msg_mode" in
      exact)
        if [ "$msg" != "$exp_msg" ]; then
          ok=0
          diff="$diff Message=\"$msg\"(期待 \"$exp_msg\")"
        fi
        ;;
      contains)
        if [[ "$msg" != *"$exp_msg"* ]]; then
          ok=0
          diff="$diff Message=\"$msg\"(期待 \"$exp_msg\" を含む)"
        fi
        ;;
    esac
  fi
  if [ "$exp_rows" != "-" ] && [ "$rows" != "$exp_rows" ]; then
    ok=0
    diff="$diff Rows=$rows(期待 $exp_rows)"
  fi
  if [ "$exp_token" != "-" ] && [ "$token" != "$exp_token" ]; then
    ok=0
    diff="$diff NextToken=$token(期待 $exp_token)"
  fi

  local actual
  if [ "$status" = "200" ]; then
    actual="status=200 Rows=$rows NextToken=$token"
  else
    actual="status=$status $code \"$msg\""
  fi
  if [ "$ok" = "1" ]; then
    record "$no $op" PASS "$actual"
  else
    record "$no $op" FAIL "差:${diff} / 実際: $actual"
  fi
}

main() {
  log "作業ディレクトリ: $SCRIPT_DIR"
  log "証跡の保存先: $EVIDENCE_DIR"

  # 前の走行の残骸（テーブル、結果ファイル）を持ち越さないよう、使うサービスを作り直す。
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

  if ! build_athena_local; then
    record "cargo build" FAIL "ビルドが失敗した"
    return 1
  fi
  record "cargo build" PASS "$BINARY を用意した"

  if ! start_athena_local; then
    record "athena-local起動" FAIL "athena-local が起動しなかった"
    return 1
  fi
  record "athena-local起動" PASS "$ATHENA_BASE で応答"

  # 準備 1: 5 行を返す SELECT（見出し行と合わせて Rows は 6 件）
  local ok_id
  if ! ok_id=$(start_and_wait ok "SELECT n FROM UNNEST(sequence(1, 5)) AS t(n)" SUCCEEDED); then
    record "準備(SUCCEEDED のクエリ)" FAIL "SELECT n FROM UNNEST(sequence(1, 5)) が SUCCEEDED にならなかった"
    return 1
  fi
  record "準備(SUCCEEDED のクエリ)" PASS "OK_ID=$ok_id"

  # 準備 2: 存在しないテーブルの SELECT（実行時に FAILED になる）
  local failed_id="" rc
  failed_id=$(start_and_wait failed "SELECT 1 FROM athena_local_issue83_missing_table" FAILED)
  rc=$?
  case "$rc" in
    0) record "準備(FAILED のクエリ)" PASS "FAILED_ID=$failed_id" ;;
    2)
      failed_id=""
      record "準備(FAILED のクエリ)" SKIP "StartQueryExecution 自体が失敗した（証跡 prep-failed.start.json）。16〜18 は未測定"
      ;;
    *)
      record "準備(FAILED のクエリ)" FAIL "FAILED で終わらなかった（証跡 prep-failed.execution.json）"
      return 1
      ;;
  esac

  # 準備 3: 1 ページ目の NextToken を採る
  local token_out="$EVIDENCE_DIR/prep-token.json" token
  athena_call GetQueryResults "$(jq -n --arg id "$ok_id" '{QueryExecutionId: $id, MaxResults: 1}')" "$token_out" >/dev/null
  token=$(jq -r '.NextToken // empty' <"$token_out" 2>/dev/null)
  if [ -z "$token" ]; then
    record "準備(NextToken)" FAIL "MaxResults=1 の GetQueryResults が NextToken を返さなかった: $(tr -d '\n' <"$token_out")"
    return 1
  fi
  record "準備(NextToken)" PASS "TOKEN=$token"

  local ok missing failed
  ok=$(jq -n --arg id "$ok_id" '{QueryExecutionId: $id}')
  missing=$(jq -n --arg id "$MISSING_ID" '{QueryExecutionId: $id}')
  with() { echo "$1" | jq -c "$2"; }

  # 対照（正常系）
  check_case 1 GetQueryResults "$ok" 200 - - "" 6 absent
  check_case 2 GetQueryResults "$(with "$ok" '. + {MaxResults: 1}')" 200 - - "" 1 present
  check_case 3 GetQueryResults "$(jq -cn --arg id "$ok_id" --arg t "$token" '{QueryExecutionId: $id, NextToken: $t}')" 200 - - "" 5 absent
  check_case 4 GetQueryResults "$(with "$ok" '. + {MaxResults: 1000}')" 200 - - "" 6 -

  # 枠組みの検証
  check_case 5 GetQueryResults "$(with "$ok" '. + {MaxResults: 1001}')" 400 INVALID_INPUT exact "$MSG_MAX_OVER"
  check_case 6 GetQueryResults "$(with "$ok" '. + {MaxResults: 0}')" 400 INVALID_INPUT exact "$MSG_MAX_UNDER"
  check_case 7 GetQueryResults "$(with "$ok" '. + {MaxResults: -1}')" 400 INVALID_INPUT exact "$MSG_MAX_UNDER"
  check_case 8 GetQueryResults "$(with "$ok" '. + {NextToken: ""}')" 400 INVALID_INPUT exact "$MSG_TOKEN_EMPTY"
  check_case 9 GetQueryResults "$(with "$ok" '. + {NextToken: "not-a-token"}')" 400 INVALID_INPUT exact "$MSG_TOKEN_MALFORMED"
  check_case 10 GetQueryResults "$(with "$ok" '. + {MaxResults: 0, NextToken: ""}')" 400 INVALID_INPUT exact "$MSG_TWO_ERRORS"
  check_case 11 GetQueryResults "$(with "$ok" '. + {MaxResults: 1001, NextToken: ""}')" 400 INVALID_INPUT exact "$MSG_TOKEN_EMPTY"
  check_case 12 GetQueryResults "$(with "$ok" '. + {MaxResults: 1001, NextToken: "not-a-token"}')" 400 INVALID_INPUT exact "$MSG_MAX_OVER"

  # 存在しない ID との順序
  check_case 13 GetQueryResults "$missing" 400 QUERY_EXECUTION_NOT_FOUND contains "was not found"
  check_case 14 GetQueryResults "$(with "$missing" '. + {MaxResults: 0}')" 400 INVALID_INPUT exact "$MSG_MAX_UNDER"
  check_case 15 GetQueryResults "$(with "$missing" '. + {MaxResults: 1001}')" 400 QUERY_EXECUTION_NOT_FOUND contains "was not found"

  # FAILED のクエリとの順序
  if [ -n "$failed_id" ]; then
    failed=$(jq -n --arg id "$failed_id" '{QueryExecutionId: $id}')
    check_case 16 GetQueryResults "$failed" 400 INVALID_QUERY_EXECUTION_STATE exact "$MSG_FAILED_STATE"
    check_case 17 GetQueryResults "$(with "$failed" '. + {NextToken: "not-a-token"}')" 400 INVALID_QUERY_EXECUTION_STATE exact "$MSG_FAILED_STATE"
    check_case 18 GetQueryResults "$(with "$failed" '. + {MaxResults: 1001}')" 400 INVALID_INPUT exact "$MSG_MAX_OVER"
  else
    record "16〜18 GetQueryResults" SKIP "FAILED のクエリを用意できなかったため未測定"
  fi

  # ListWorkGroups
  check_case 19 ListWorkGroups '{"MaxResults": 0, "NextToken": ""}' 400 INVALID_INPUT exact "$MSG_TWO_ERRORS"

  return 0
}

main
