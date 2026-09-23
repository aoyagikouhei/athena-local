#!/usr/bin/env bash
# issue #84 で作成（tools/ へ移す前の名前は 84-e2e/verify.sh）
# issue #84 Step 9（実機検証）: athena-local の release バイナリを起動し、リクエスト本文のパース失敗
# （型違い・必須欠落・壊れた JSON など）とディスパッチの失敗（未対応オペレーション・前置き無し・
# ヘッダ無し・大文字小文字違い）に curl で当てて、本物の Athena で 2026-09-23 に実測した応答
# （$HOME/athena-parse-errors-measurements/raw-20260923-105053/summary.txt。ケース番号はこの summary の
# 番号をそのまま使う）と一致するかを確かめる。
#
# docker も Trino も要らない: これらの応答は Trino に届く前に決まるので、TRINO_URL には繋がらない
# アドレス（http://127.0.0.1:9）を渡す。本物の AWS も使わない。結果ファイルも書かない
# （ATHENA_LOCAL_RESULTS=none）。
#
# 見るもの: HTTP ステータス、本文の __type・AthenaErrorCode・Message、本文のキー一覧。
# athena-local は x-amzn-errortype ヘッダを送る（本物は送らない）ので、ヘッダは見ない。
# 本物で Message が「無い」ケースは、本文のキーが __type だけであることを確かめる。
# 本物で SerializationException に Message があるケースは、キーが __type と Message だけ
# （AthenaErrorCode 無し）であることも確かめる。
#
# 期待値は本物の実測値ひとつだけをハードコードしている。したがって **#84 の変更が入る前のビルドで
# 流すと、対照と一部を除いて FAIL になるのが正しい**。
# 変更前の予測（ケース 4 の小数の切り捨てと 37 の配列 → 入れ子の構造体は揃えないので、足場から外してある）:
#   PASS: 対照 A（ListWorkGroups {} が 200）、対照 B（存在しない ID で QUERY_EXECUTION_NOT_FOUND）、
#         5（MaxResults が null で 200）、14（未知のキー Foo で 200）
#   FAIL: 8（i32 の範囲外で serde が弾く）、
#         それ以外の全部（SerializationException の文言・キー、必須欠落の検証文言、
#         UnknownOperationException が本物と違う）
#
# 前提コマンド: curl, jq, uuidgen, cargo
# jq にはファイルを引数でなく標準入力（<）で渡す。このマシンの jq は snap 版で、/tmp の private
# 名前空間のせいで mktemp -d /tmp/... のファイルを引数で開けない（2026-09-23 に踏んだ）。
#
# 使い方:
#   tools/e2e/request-errors/verify.sh
#
# 環境変数:
#   SKIP_BUILD=1     cargo build を省略し、既存の $CARGO_TARGET_DIR（tools/dev.sh では .toolbox/target）の release/athena-local をそのまま使う
#
# 後始末は本スクリプトの trap が行う（起動した athena-local を必ず止める）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# cargo の成果物の置き場。tools/dev.sh は CARGO_TARGET_DIR を .toolbox/target にする
BINARY="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/athena-local"

TRINO_BASE="http://127.0.0.1:9" # 繋がらないアドレス（Trino に届く前に応答が決まるケースだけを流す）
ATHENA_BIND="127.0.0.1:8090"
ATHENA_BASE="http://${ATHENA_BIND}"

MISSING_ID="00000000-0000-4000-8000-000000000084"
OUTPUT='{"OutputLocation": "s3://bucket/prefix/"}'

MSG_STRING_TO_INT="STRING_VALUE can not be converted to an Integer"
MSG_TRUE_TO_INT="TRUE_VALUE can not be converted to an Integer"
MSG_NUMBER_TO_STRING="NUMBER_VALUE can not be converted to a String"
MSG_LIST="Start of list found where not expected"
MSG_STRUCT="Start of structure or map found where not expected."
MSG_MAX_OVER_50="1 validation error detected: Value at 'maxResults' failed to satisfy constraint: Member must have value less than or equal to 50"
MSG_NULL_QUERY_EXECUTION_ID="1 validation error detected: Value null at 'queryExecutionId' failed to satisfy constraint: Member must not be null"
MSG_NULL_WORK_GROUP="1 validation error detected: Value null at 'workGroup' failed to satisfy constraint: Member must not be null"
MSG_NULL_QUERY_STRING="1 validation error detected: Value null at 'queryString' failed to satisfy constraint: Member must not be null"
MSG_NOT_FOUND="QueryExecution ${MISSING_ID} was not found"

EVIDENCE_DIR="$(mktemp -d /tmp/athena-local-issue84-e2e.XXXXXX)"
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
  if ! print_table; then
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT

# --- 準備 ---

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
  (
    cd "$REPO_ROOT"
    exec env \
      ATHENA_LOCAL_BIND="$ATHENA_BIND" \
      TRINO_URL="$TRINO_BASE" \
      TRINO_USER="athena-local-e2e84" \
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

# 本文を $out に書き、HTTP ステータスを標準出力に返す。
# target が "-" なら X-Amz-Target ヘッダを付けない。それ以外はその値をそのまま付ける。
send() {
  local target="$1" body="$2" out="$3"
  local -a headers=(-H "Content-Type: application/x-amz-json-1.1")
  if [ "$target" != "-" ]; then
    headers+=(-H "X-Amz-Target: $target")
  fi
  curl -s -o "$out" -w '%{http_code}' -X POST "$ATHENA_BASE/" "${headers[@]}" --data-binary "$body"
}

# 空の本文が Content-Length: 0 で送られることを 1 度だけ確かめる（ケース 17 の前提）。
check_empty_body_is_sent() {
  local trace="$EVIDENCE_DIR/empty-body.curl-v.txt"
  curl -s -v -o /dev/null -X POST "$ATHENA_BASE/" \
    -H "Content-Type: application/x-amz-json-1.1" \
    -H "X-Amz-Target: AmazonAthena.ListWorkGroups" \
    --data-binary '' 2>"$trace"
  if grep -qi '^> Content-Length: 0' "$trace"; then
    record "前提(空本文の送り方)" PASS "Content-Length: 0 で送られた"
  else
    record "前提(空本文の送り方)" FAIL "Content-Length: 0 が見当たらない（証跡 empty-body.curl-v.txt）"
  fi
}

# --- ケース ---
#
# check_case <番号> <X-Amz-Target|-> <本文> <期待ステータス> <期待 __type|-> <期待 AthenaErrorCode|-> <期待 Message>
#
# 期待 Message の書き方:
#   NONE            Message が無い。本文のキーが ["__type"] だけであることを確かめる
#   -               Message を見ない（200 のケース。代わりに WorkGroups キーの有無を見る）
#   それ以外        Message の完全一致。__type が SerializationException ならキーが ["Message","__type"]
#                   だけ（AthenaErrorCode 無し）であることも確かめる
check_case() {
  local no="$1" target="$2" body="$3" exp_status="$4" exp_type="$5" exp_code="$6" exp_msg="$7"
  local out="$EVIDENCE_DIR/case-${no}.json"
  printf '%s' "$body" >"$EVIDENCE_DIR/case-${no}.request.txt"

  local status type code msg keys
  status=$(send "$target" "$body" "$out")
  type=$(jq -r '.__type // empty' <"$out" 2>/dev/null)
  code=$(jq -r '.AthenaErrorCode // empty' <"$out" 2>/dev/null)
  msg=$(jq -r 'if has("Message") then .Message elif has("message") then .message else empty end' <"$out" 2>/dev/null)
  keys=$(jq -c 'keys' <"$out" 2>/dev/null || echo "(JSON でない: $(head -c 200 <"$out" | tr -d '\n'))")

  local ok=1 diff=""
  if [ "$status" != "$exp_status" ]; then
    ok=0
    diff="$diff status=$status(期待 $exp_status)"
  fi
  if [ "$exp_status" = "200" ]; then
    if ! jq -e 'has("WorkGroups")' <"$out" >/dev/null 2>&1; then
      ok=0
      diff="$diff WorkGroups キーが無い"
    fi
  else
    if [ "$type" != "$exp_type" ]; then
      ok=0
      diff="$diff __type=${type:-無し}(期待 $exp_type)"
    fi
    if [ "$exp_code" != "-" ] && [ "$code" != "$exp_code" ]; then
      ok=0
      diff="$diff AthenaErrorCode=${code:-無し}(期待 $exp_code)"
    fi
    case "$exp_msg" in
      NONE)
        if [ "$keys" != '["__type"]' ]; then
          ok=0
          diff="$diff keys=$keys(期待 [\"__type\"])"
        fi
        ;;
      -) ;;
      *)
        if [ "$msg" != "$exp_msg" ]; then
          ok=0
          diff="$diff Message=\"$msg\"(期待 \"$exp_msg\")"
        fi
        if [ "$exp_type" = "SerializationException" ] && [ "$keys" != '["Message","__type"]' ]; then
          ok=0
          diff="$diff keys=$keys(期待 [\"Message\",\"__type\"])"
        fi
        ;;
    esac
  fi

  local actual="status=$status __type=${type:-無し} AthenaErrorCode=${code:-無し} Message=\"$msg\" keys=$keys"
  local name="$no ${target#AmazonAthena.}"
  if [ "$ok" = "1" ]; then
    record "$name" PASS "$actual"
  else
    record "$name" FAIL "差:${diff} / 実際: $actual"
  fi
}

main() {
  log "証跡の保存先: $EVIDENCE_DIR"

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

  check_empty_body_is_sent

  local LWG="AmazonAthena.ListWorkGroups" GQE="AmazonAthena.GetQueryExecution"
  local SQE="AmazonAthena.StartQueryExecution" SE="SerializationException" IR="InvalidRequestException"
  local UO="UnknownOperationException"
  start_body() { # $1 = 追加するキー（JSON のオブジェクト）。ClientRequestToken は毎回新しくする
    jq -cn --arg t "$(uuidgen)" --argjson out "$OUTPUT" --argjson extra "$1" \
      '{ClientRequestToken: $t, ResultConfiguration: $out} + $extra'
  }

  # 対照
  check_case A "$LWG" '{}' 200 - - -
  check_case B "$GQE" "{\"QueryExecutionId\": \"$MISSING_ID\"}" 400 "$IR" QUERY_EXECUTION_NOT_FOUND "$MSG_NOT_FOUND"

  # ListWorkGroups の型違い
  check_case 1 "$LWG" '{"MaxResults": "1"}' 400 "$SE" - "$MSG_STRING_TO_INT"
  check_case 3 "$LWG" '{"MaxResults": true}' 400 "$SE" - "$MSG_TRUE_TO_INT"
  check_case 5 "$LWG" '{"MaxResults": null}' 200 - - -
  check_case 6 "$LWG" '{"MaxResults": [1]}' 400 "$SE" - "$MSG_LIST"
  check_case 7 "$LWG" '{"MaxResults": {"a": 1}}' 400 "$SE" - "$MSG_STRUCT"
  check_case 8 "$LWG" '{"MaxResults": 99999999999}' 400 "$IR" INVALID_INPUT "$MSG_MAX_OVER_50"
  check_case 9 "$LWG" '{"NextToken": 1}' 400 "$SE" - "$MSG_NUMBER_TO_STRING"
  check_case 14 "$LWG" '{"Foo": 1}' 200 - - -
  check_case 15 "$LWG" '{"MaxResults": "1", "NextToken": ""}' 400 "$SE" - "$MSG_STRING_TO_INT"

  # 壊れた本文
  check_case 16 "$LWG" '{' 400 "$SE" - NONE
  check_case 17 "$LWG" '' 400 "$SE" - NONE
  check_case 18 "$LWG" 'null' 400 "$SE" - NONE
  check_case 19 "$LWG" '[]' 400 "$SE" - "$MSG_LIST"
  check_case 20 "$LWG" '"x"' 400 "$SE" - NONE
  check_case 21 "$LWG" '{"MaxResults": 1,}' 400 "$SE" - NONE

  # 他のオペレーション
  check_case 22 "$GQE" '{"QueryExecutionId": 1}' 400 "$SE" - "$MSG_NUMBER_TO_STRING"
  check_case 24 "$GQE" '{"QueryExecutionId": null}' 400 "$IR" INVALID_INPUT "$MSG_NULL_QUERY_EXECUTION_ID"
  check_case 27 "$GQE" '{}' 400 "$IR" INVALID_INPUT "$MSG_NULL_QUERY_EXECUTION_ID"
  check_case 29 AmazonAthena.StopQueryExecution '{"QueryExecutionId": 1}' 400 "$SE" - "$MSG_NUMBER_TO_STRING"
  check_case 30 AmazonAthena.GetWorkGroup '{"WorkGroup": 1}' 400 "$SE" - "$MSG_NUMBER_TO_STRING"
  check_case 31 AmazonAthena.GetWorkGroup '{}' 400 "$IR" INVALID_INPUT "$MSG_NULL_WORK_GROUP"
  check_case 32 AmazonAthena.GetQueryResults '{"MaxResults": "1"}' 400 "$SE" - "$MSG_STRING_TO_INT"

  # StartQueryExecution
  check_case 33 "$SQE" "$(start_body '{"QueryString": 1}')" 400 "$SE" - "$MSG_NUMBER_TO_STRING"
  check_case 34 "$SQE" "$(start_body '{"QueryString": "SELECT", "ExecutionParameters": "x"}')" 400 "$SE" - "Expected list or null"
  check_case 35 "$SQE" "$(start_body '{"QueryString": "SELECT", "ExecutionParameters": [1]}')" 400 "$SE" - "$MSG_NUMBER_TO_STRING"
  check_case 36 "$SQE" "$(jq -cn --arg t "$(uuidgen)" '{QueryString: "SELECT", ResultConfiguration: "x", ClientRequestToken: $t}')" 400 "$SE" - "Expected null"
  check_case 38 "$SQE" "$(start_body '{}')" 400 "$IR" INVALID_INPUT "$MSG_NULL_QUERY_STRING"

  # ディスパッチの失敗
  check_case 39 AmazonAthena.Nope '{}' 400 "$UO" - NONE
  check_case 41 ListWorkGroups '{}' 400 "$UO" - NONE
  check_case 42 - '{}' 400 "$UO" - NONE
  check_case 43 amazonathena.listworkgroups '{}' 400 "$UO" - NONE
}

main
