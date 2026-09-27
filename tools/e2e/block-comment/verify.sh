#!/usr/bin/env bash
# issue #244 の実機検証の足場（tools/e2e/quoted-names/verify.sh・tools/e2e/result-content-type/verify.sh を雛形にした）。
#
# #244 は、ブロックコメントの入った SHOW CREATE TABLE・MSCK REPAIR TABLE・ALTER TABLE（ADD COLUMNS・
# DROP COLUMN・RENAME TO）・DESCRIBE/DESC を、本物の Athena と同じく「開始はするが Trino に送らず FAILED」
# にする（今の athena-local は、Trino が構文としてコメントを許す形だとそのまま実行してしまい、
# Trino に無い構文の形だけ開始時に 400 で弾いている）。
#
# この足場は compose のローカル Trino（hive・iceberg カタログ）に Hive の表・Iceberg の表・Hive のビューを
# 用意し、athena-local の StartQueryExecution／GetQueryExecution に、.claude/issue-notes/244.md の
# 「実測の結果」（ラウンド 2・3）と docs/caveats.md の「Block comments Athena's Hive parser rejects」節
# （2026-09-26 実測、#244 の実装に合わせてまだ未コミットで更新済み）のケース表を流して判定する。
# 本物の AWS には投げない（compose の trino だけ）。
#
# 実装前（main-244、#244 未着手）の athena-local で流すと、「新しい挙動」の群のケースの多くが FAIL になる
# （Trino がコメントを構文として許すので、SHOW CREATE TABLE・ALTER ADD COLUMNS の変種はそのまま実行されて
# しまい、期待した FAILED にならない）。ただし DESCRIBE の Hive 表 3 件（DS1〜DS3）は #242 で先に実装済みの
# ため、実装前から PASS する（このスクリプトの受け入れ判定で確かめて報告する）。「回帰」の群は実装前後で
# 変わらない前提（#242 の DESCRIBE・今までの Trino の制約による開始時 400 の 2 件・既存の SHOW CREATE
# TABLE／ALTER DROP COLUMN × Iceberg の成功）。
#
# issue #257 で、.claude/issue-notes/257.md の「実測の結果」（2026-09-27・ROUND=3）にある、#244 で
# 測っていなかった形を足す: 名前の中・後ろ・句の中のコメント（G1〜G3）、DESCRIBE EXTENDED のコメント
# （DE1）、REPLACE COLUMNS・CHANGE COLUMN（R1・R3）、先頭コメントの中身が 2 文字の記号・閉じていない
# 引用符（E1・E2・E5）、ALTER の後ろのコメントで awsdatacatalog. を含む DROP COLUMN（POS1。ErrorMessage・
# Query とも受け取ったままの文で数える点が #244 までの規則と違う）。これらは「新しい挙動」の群で、#257 の
# 実装前（このスクリプトを書いた時点の main）では FAIL するのが正しい。あわせて、本 issue で送ってみたが
# 実装で変えない「回帰」の群（G1・G3・DE1 のほかの表・位置、SET LOCATION、#256 の形の awsdatacatalog. 付き
# コメント無し DROP COLUMN）も足した。これらの期待値は本物の Athena ではなく、今のビルドを実際に流して
# 観測した値（SUCCEEDED・Trino 自身のエラー文言・開始時 400 のいずれか）をそのまま固定したもの。
#
# 前提コマンド: tools/dev.sh 経由で動かす（toolbox に全部入っている）
#
# 使い方:
#   tools/dev.sh tools/e2e/block-comment/verify.sh
#
# 環境変数:
#   KEEP_UP=1        テスト後に docker compose down -v <サービス...> をせず環境を残す（デバッグ用）
#   SKIP_BUILD=1     cargo build を省略し、既存の $CARGO_TARGET_DIR（tools/dev.sh では .toolbox/target）の release/athena-local をそのまま使う
#
# 後始末は本スクリプトの trap が行う: athena-local を止め、Trino のスキーマ hive.e2e244・iceberg.e2e244 を
# DROP SCHEMA ... CASCADE で消し（KEEP_UP=1 でなければ）docker compose down -v <このスクリプトが使ったサービス> する。
# S3（MinIO）側の確認は toolbox の mc で minio:9000 を直接見る（aws は使わない。#129 と同じ流儀）。
# 終了コードは結果表の FAIL の件数を数え、1 件でもあれば 1（判定の自己確認の GATE 行は数えない）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# cargo の成果物の置き場。tools/dev.sh は CARGO_TARGET_DIR を .toolbox/target にする
BINARY="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/athena-local"
COMPOSE=(docker compose -f "$REPO_ROOT/compose.yml")
SERVICES=(trino minio minio-init)

TRINO_BASE="http://trino:8080"
MINIO_ENDPOINT="http://minio:9000"
ATHENA_BIND="127.0.0.1:8115"
ATHENA_BASE="http://${ATHENA_BIND}"
BUCKET="athena-results"
PREFIX="e2e244"
OUTPUT_LOCATION="s3://${BUCKET}/${PREFIX}/"
SCHEMA="e2e244"

# フィクスチャの名前。無い表・リネーム先は作らない。
H="h244"
I="i244"
V="v244"
M="missing244"
NEWNAME="renamed244"
EXTRA1="extra1"
EXTRA2="extra2"

EVIDENCE_DIR="$(mktemp -d /tmp/athena-local-issue244-e2e.XXXXXX)"
ATHENA_LOG="$EVIDENCE_DIR/athena-local.log"
BUILD_LOG="$EVIDENCE_DIR/cargo-build.log"

ATHENA_PID=""

declare -a RESULT_NAMES=()
declare -a RESULT_STATUS=()
declare -a RESULT_DETAIL=()

# run_and_wait が書く直近の StartQueryExecution／GetQueryExecution の値。
# check_failed_result／case_succeeded／case_start_reject が読む。
LAST_START_CODE=""
LAST_START_BODY=""
LAST_ID=""
LAST_EXEC_JSON=""

# GATE（わざと壊す自己確認）用に、SC1 の実行結果を退避しておく変数。
SC1_ID=""
SC1_EXEC_JSON=""

log() { echo "[verify] $*" >&2; }

record() {
  RESULT_NAMES+=("$1")
  RESULT_STATUS+=("$2")
  RESULT_DETAIL+=("$3")
}

# 直前に record した 1 件を配列から取り除き、LAST_POPPED_* に退避する（GATE の自己確認専用。
# 本来のケース表の PASS/FAIL の集計・終了コードに GATE を混ぜないため）。
LAST_POPPED_STATUS=""
LAST_POPPED_DETAIL=""
pop_result() {
  local n=${#RESULT_STATUS[@]}
  local idx=$((n - 1))
  LAST_POPPED_STATUS="${RESULT_STATUS[$idx]}"
  LAST_POPPED_DETAIL="${RESULT_DETAIL[$idx]}"
  unset "RESULT_NAMES[$idx]" "RESULT_STATUS[$idx]" "RESULT_DETAIL[$idx]"
}

# 直前に record した 1 件を FAIL に格下げし、理由を書き足す（#257 の POS1・AT9 専用。Query が
# 受け取ったまま／書き換え後のどちらかを、case_failed の判定とは別に確かめるため）。
downgrade_last_result() {
  local extra="$1"
  local idx=$((${#RESULT_STATUS[@]} - 1))
  RESULT_STATUS[$idx]="FAIL"
  RESULT_DETAIL[$idx]="${RESULT_DETAIL[$idx]} ${extra}"
}

print_table() {
  echo
  echo "==================== 結果 ===================="
  local i
  for i in "${!RESULT_NAMES[@]}"; do
    printf "%-6s %-58s %s\n" "${RESULT_STATUS[$i]}" "${RESULT_NAMES[$i]}" "${RESULT_DETAIL[$i]}"
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
  echo "GATE（判定の自己確認。期待値を1つ壊した SC1 の再判定。集計・終了コードには含めない）: ${GATE_STATUS:-未実行} ${GATE_DETAIL:-}"
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

  log "Trino のスキーマ hive.${SCHEMA}・iceberg.${SCHEMA} を消す（無ければ何もしない）"
  trino_exec "DROP SCHEMA IF EXISTS hive.${SCHEMA} CASCADE" hive default >/dev/null 2>&1 || true
  trino_exec "DROP SCHEMA IF EXISTS iceberg.${SCHEMA} CASCADE" iceberg default >/dev/null 2>&1 || true

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
    -H "X-Trino-User: e2e-244-setup" \
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
  local _
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
  local _
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
  log "athena-local を起動する（bind=$ATHENA_BIND、TRINO_CATALOG_MAP=AwsDataCatalog=hive、ログ: $ATHENA_LOG）"
  (
    cd "$REPO_ROOT"
    exec env \
      ATHENA_LOCAL_BIND="$ATHENA_BIND" \
      TRINO_URL="$TRINO_BASE" \
      TRINO_USER="athena-local-e2e244" \
      TRINO_SCHEMA="$SCHEMA" \
      TRINO_CATALOG_MAP="AwsDataCatalog=hive" \
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

athena_call() {
  local operation="$1" body="$2"
  curl -s -X POST "$ATHENA_BASE/" \
    -H "X-Amz-Target: AmazonAthena.$operation" \
    -H "Content-Type: application/x-amz-json-1.1" \
    --data-binary "$body"
}

# StartQueryExecution を生で呼び、HTTP コードと本文を LAST_START_CODE／LAST_START_BODY に残す。
athena_start_raw() {
  local sql="$1" catalog="$2" database="$3"
  local body resp
  body=$(jq -cn --arg sql "$sql" --arg cat "$catalog" --arg db "$database" --arg token "$(uuidgen)" \
    '{QueryString: $sql, QueryExecutionContext: {Catalog: $cat, Database: $db}, ClientRequestToken: $token}')
  resp=$(curl -s -w '\n%{http_code}' -X POST "$ATHENA_BASE/" \
    -H "X-Amz-Target: AmazonAthena.StartQueryExecution" \
    -H "Content-Type: application/x-amz-json-1.1" \
    --data-binary "$body")
  LAST_START_CODE="${resp##*$'\n'}"
  LAST_START_BODY="${resp%$'\n'*}"
}

# GetQueryExecution を終端状態（QUEUED/RUNNING 以外）になるまでポーリングして応答を返す。
poll_terminal() {
  local id="$1" resp state
  local i
  for i in $(seq 1 150); do
    resp=$(athena_call GetQueryExecution "$(jq -cn --arg id "$id" '{QueryExecutionId: $id}')")
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

# StartQueryExecution を投げて（開始できれば）終端まで待つ。結果は LAST_ID／LAST_EXEC_JSON に残す。
# 開始できなければ LAST_ID は空、LAST_EXEC_JSON も空のまま。
run_and_wait() {
  local sql="$1" catalog="$2" database="$3"
  athena_start_raw "$sql" "$catalog" "$database"
  LAST_ID=$(echo "$LAST_START_BODY" | jq -r '.QueryExecutionId // empty')
  if [ -z "$LAST_ID" ]; then
    LAST_EXEC_JSON=""
    return
  fi
  LAST_EXEC_JSON=$(poll_terminal "$LAST_ID")
}

# --- S3（MinIO）側の確認（toolbox の mc で minio:9000 を直接見る。#129） ---

# `mc stat --json <key>` を実行して、その key に厳密一致するオブジェクトの JSON を 1 行返す。
# 無ければ {"status":"error"} を返す。
#
# 注意（result-content-type/verify.sh・#39・#111 と同じ理由）: mc stat は与えたキーを前方一致の
# プレフィックスとしても扱い、`<id>.txt` を指定すると `<id>.txt.metadata` まで一緒にヒットして
# JSON が複数行返る。`name` フィールドで厳密に絞り込み、「無いことの証拠」が別のキーの行に
# 混ざらないようにする（.claude/design-checklist.md #111）。
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

# --- 判定 ---

# GetQueryExecution の JSON（$1）から 1 つ jq で取り出す薄い包み。
jqx() { echo "$1" | jq -r "$2"; }

# StartQueryExecution が開始できない（400 で QueryExecutionId が返らない）ことを確かめる。
# 今の Trino の制約による既存の 400（コメント無しの MSCK・ALTER ADD COLUMNS）専用。
case_start_reject() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5"
  run_and_wait "$sql" "$catalog" "$database"
  if [ -n "$LAST_ID" ]; then
    record "$no $name" FAIL "開始できてしまった（400 を期待）: QueryExecutionId=$LAST_ID"
    return
  fi
  if [ "$LAST_START_CODE" = "400" ]; then
    record "$no $name" PASS "開始時に 400（期待どおり）"
  else
    record "$no $name" FAIL "開始時のコードが ${LAST_START_CODE}（期待 400）: $(echo "$LAST_START_BODY" | tr -d '\n' | cut -c1-200)"
  fi
}

# 開始でき、終端が SUCCEEDED になることだけ確かめる（回帰群。本文・.metadata の中身は
# 既存のテスト・足場（show_create.rs・table_format.rs・reported_query.rs 等）でカバー済みのため、
# ここでは #244 の変更が開始・終端の成否を崩していないことだけを見る）。
case_succeeded() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5"
  run_and_wait "$sql" "$catalog" "$database"
  if [ -z "$LAST_ID" ]; then
    record "$no $name" FAIL "開始できなかった: code=$LAST_START_CODE body=$(echo "$LAST_START_BODY" | tr -d '\n' | cut -c1-200)"
    return
  fi
  local state
  state=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.Status.State // empty')
  if [ "$state" = "SUCCEEDED" ]; then
    record "$no $name" PASS "SUCCEEDED [id=$LAST_ID]"
  else
    local reason
    reason=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.Status.StateChangeReason // empty')
    record "$no $name" FAIL "終端状態が ${state:-無し}（期待 SUCCEEDED）: ${reason} [id=$LAST_ID]"
  fi
}

# LAST_ID／LAST_EXEC_JSON（run_and_wait 済み）を、FAILED の期待値と突き合わせる。
# txt_mode: same（.txt が有り、中身が reason と一致）／none（.txt が無い）。
# .metadata は常に「無し」を期待する（#244 の対象はどれも write_failure の経路で、.metadata を置かない）。
check_failed_result() {
  local no="$1" name="$2" reason="$3" err_cat="$4" err_type="$5" err_msg="$6" stmt="$7" substmt="$8" txt_mode="$9"

  if [ -z "$LAST_ID" ]; then
    record "$no $name" FAIL "開始できなかった（FAILED での終端を期待）: code=$LAST_START_CODE body=$(echo "$LAST_START_BODY" | tr -d '\n' | cut -c1-200)"
    return
  fi

  local ok=1 diff=""
  local got_state got_reason got_cat got_type got_retryable got_errmsg got_stmt got_substmt
  got_state=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.Status.State // "無し"')
  got_reason=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.Status.StateChangeReason // "無し"')
  got_cat=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.Status.AthenaError.ErrorCategory // "無し"')
  got_type=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.Status.AthenaError.ErrorType // "無し"')
  # Retryable は真偽値なので `//` は使わない（false が偽扱いされ "無し" にすり替わる jq の罠。
  # AthenaError 自体が無いときだけ「無し」にする）。
  got_retryable=$(jqx "$LAST_EXEC_JSON" \
    '.QueryExecution.Status.AthenaError | if . == null then "無し" else (.Retryable | tostring) end')
  got_errmsg=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.Status.AthenaError.ErrorMessage // "無し"')
  got_stmt=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.StatementType // "無し"')
  got_substmt=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.SubstatementType // "無し"')

  [ "$got_state" = "FAILED" ] || { ok=0; diff="$diff State=${got_state}(期待 FAILED)"; }
  [ "$got_reason" = "$reason" ] || { ok=0; diff="$diff StateChangeReason=\"${got_reason}\"(期待 \"${reason}\")"; }
  [ "$got_cat" = "$err_cat" ] || { ok=0; diff="$diff ErrorCategory=${got_cat}(期待 ${err_cat})"; }
  [ "$got_type" = "$err_type" ] || { ok=0; diff="$diff ErrorType=${got_type}(期待 ${err_type})"; }
  [ "$got_retryable" = "false" ] || { ok=0; diff="$diff Retryable=${got_retryable}(期待 false)"; }
  [ "$got_errmsg" = "$err_msg" ] || { ok=0; diff="$diff ErrorMessage=\"${got_errmsg}\"(期待 \"${err_msg}\")"; }
  [ "$got_stmt" = "$stmt" ] || { ok=0; diff="$diff StatementType=${got_stmt}(期待 ${stmt})"; }
  [ "$got_substmt" = "$substmt" ] || { ok=0; diff="$diff SubstatementType=${got_substmt}(期待 ${substmt})"; }

  local key="${PREFIX}/${LAST_ID}.txt"
  local body_stat
  body_stat=$(mc_stat "$key")
  case "$txt_mode" in
    same)
      if mc_exists "$body_stat"; then
        local content
        content=$(mc cat "local/$BUCKET/$key" 2>/dev/null)
        if [ "$content" != "$reason" ]; then
          ok=0
          diff="$diff .txtの中身が違う"
        fi
      else
        ok=0
        diff="$diff .txt=無し(期待 有り)"
      fi
      ;;
    none)
      if mc_exists "$body_stat"; then
        ok=0
        diff="$diff .txt=有り(期待 無し)"
      fi
      ;;
    prefixed)
      # reason が "FAILED: " で始まらない（Hive のブロックコメント検知を通らず、Trino が実際に
      # 実行して返した本物のエラー。write_failure が "FAILED: " を足す。#257 の G1V・G1M）。
      if mc_exists "$body_stat"; then
        local content
        content=$(mc cat "local/$BUCKET/$key" 2>/dev/null)
        if [ "$content" != "FAILED: $reason" ]; then
          ok=0
          diff="$diff .txtの中身が違う"
        fi
      else
        ok=0
        diff="$diff .txt=無し(期待 有り)"
      fi
      ;;
    *)
      ok=0
      diff="$diff 未知の txt_mode=${txt_mode}"
      ;;
  esac

  local meta_stat
  meta_stat=$(mc_stat "${key}.metadata")
  if mc_exists "$meta_stat"; then
    ok=0
    diff="$diff .metadata=有り(期待 無し)"
  fi

  if [ "$ok" = "1" ]; then
    record "$no $name" PASS "FAILED・文言/種類/txt/metadata すべて期待どおり [id=$LAST_ID]"
  else
    record "$no $name" FAIL "${diff# } [id=$LAST_ID]"
  fi
}

# run_and_wait と check_failed_result をまとめた薄い包み。
case_failed() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5"
  local reason="$6" err_cat="$7" err_type="$8" err_msg="$9"
  shift 9
  local stmt="$1" substmt="$2" txt_mode="$3"
  run_and_wait "$sql" "$catalog" "$database"
  check_failed_result "$no" "$name" "$reason" "$err_cat" "$err_type" "$err_msg" "$stmt" "$substmt" "$txt_mode"
}

# --- ケース（新しい挙動。今のビルドでは多くが FAIL するはず） ---
#
# 出典: .claude/issue-notes/244.md の「実測の結果」（ラウンド 2・3）と
# docs/caveats.md の「Block comments Athena's Hive parser rejects」節（#244 の実装に合わせて
# まだコミットされていないが本文は確定済み）。位置 L:C は `/` の行（1 始まり）と列（0 始まり）。
run_new_behavior_cases() {
  local reason

  # SC1〜SC11: SHOW CREATE TABLE。UTILITY/SHOW_CREATE_TABLE、1/1003、txt=reason。
  reason="FAILED: ParseException line 1:5 cannot recognize input near 'SHOW' '/' '*' in ddl statement"
  case_failed "SC1" "SHOW /* c */ CREATE TABLE（Hive）" \
    "SHOW /* c */ CREATE TABLE $H" AwsDataCatalog "$SCHEMA" \
    "$reason" 1 1003 "$reason" UTILITY SHOW_CREATE_TABLE same
  SC1_ID="$LAST_ID"
  SC1_EXEC_JSON="$LAST_EXEC_JSON"

  reason="FAILED: ParseException line 1:12 mismatched input '/' expecting TABLE near 'CREATE' in show statement"
  case_failed "SC2" "SHOW CREATE /* c */ TABLE（Hive）" \
    "SHOW CREATE /* c */ TABLE $H" AwsDataCatalog "$SCHEMA" \
    "$reason" 1 1003 "$reason" UTILITY SHOW_CREATE_TABLE same

  reason="FAILED: ParseException line 1:0 cannot recognize input near '/' '*' 'c'"
  case_failed "SC3" "/* c */ SHOW CREATE TABLE（Hive）" \
    "/* c */ SHOW CREATE TABLE $H" AwsDataCatalog "$SCHEMA" \
    "$reason" 1 1003 "$reason" UTILITY SHOW_CREATE_TABLE same

  reason="FAILED: ParseException line 1:18 cannot recognize input near '/' '*' 'c' in table name"
  case_failed "SC4" "SHOW CREATE TABLE /* c */（Hive・名前の直前）" \
    "SHOW CREATE TABLE /* c */ $H" AwsDataCatalog "$SCHEMA" \
    "$reason" 1 1003 "$reason" UTILITY SHOW_CREATE_TABLE same

  reason="FAILED: ParseException line 1:5 cannot recognize input near 'show' '/' '*' in ddl statement"
  case_failed "SC5" "show /* c */ create table（小文字）" \
    "show /* c */ create table $H" AwsDataCatalog "$SCHEMA" \
    "$reason" 1 1003 "$reason" UTILITY SHOW_CREATE_TABLE same

  reason="FAILED: ParseException line 2:0 cannot recognize input near 'SHOW' '/' '*' in ddl statement"
  case_failed "SC6" "SHOW\\n/* c */ CREATE TABLE（改行）" \
    "$(printf 'SHOW\n/* c */ CREATE TABLE %s' "$H")" AwsDataCatalog "$SCHEMA" \
    "$reason" 1 1003 "$reason" UTILITY SHOW_CREATE_TABLE same

  reason="FAILED: ParseException line 1:5 cannot recognize input near 'SHOW' '/' '*' in ddl statement"
  case_failed "SC7" "SHOW /* c */ CREATE TABLE（無い表）" \
    "SHOW /* c */ CREATE TABLE $M" AwsDataCatalog "$SCHEMA" \
    "$reason" 1 1003 "$reason" UTILITY SHOW_CREATE_TABLE same

  reason="FAILED: ParseException line 1:12 mismatched input '/' expecting TABLE near 'CREATE' in show statement"
  case_failed "SC8" "SHOW CREATE /* c */ TABLE（ビュー）" \
    "SHOW CREATE /* c */ TABLE $V" AwsDataCatalog "$SCHEMA" \
    "$reason" 1 1003 "$reason" UTILITY SHOW_CREATE_TABLE same

  # SC9〜SC11: 2 文字以上の空白は 1 つに畳んで数え、先頭コメントの 3 語目は Hive の字句
  # （2026-09-26 ラウンド 3 の p6・p1・c12）。
  reason="FAILED: ParseException line 1:5 cannot recognize input near 'SHOW' '/' '*' in ddl statement"
  case_failed "SC9" "SHOW\\n\\n/* c */ CREATE TABLE（改行 2 つは畳む）" \
    "$(printf 'SHOW\n\n/* c */ CREATE TABLE %s' "$H")" AwsDataCatalog "$SCHEMA" \
    "$reason" 1 1003 "$reason" UTILITY SHOW_CREATE_TABLE same

  reason="FAILED: ParseException line 1:12 mismatched input '/' expecting TABLE near 'CREATE' in show statement"
  case_failed "SC10" "SHOW  CREATE /* c */ TABLE（空白 2 つは畳む）" \
    "SHOW  CREATE /* c */ TABLE $H" AwsDataCatalog "$SCHEMA" \
    "$reason" 1 1003 "$reason" UTILITY SHOW_CREATE_TABLE same

  reason="FAILED: ParseException line 1:0 cannot recognize input near '/' '*' '1.5'"
  case_failed "SC11" "/* 1.5 */ SHOW CREATE TABLE（小数は 1 語）" \
    "/* 1.5 */ SHOW CREATE TABLE $H" AwsDataCatalog "$SCHEMA" \
    "$reason" 1 1003 "$reason" UTILITY SHOW_CREATE_TABLE same

  # MS1〜MS6: MSCK REPAIR TABLE。DDL/MSCK_REPAIR。MS4・MS5（Iceberg）だけ 2/1200・txt 無し。
  reason="FAILED: ParseException line 1:12 missing EOF at '/' near 'REPAIR'"
  case_failed "MS1" "MSCK REPAIR /* c */ TABLE（Hive）" \
    "MSCK REPAIR /* c */ TABLE $H" AwsDataCatalog "$SCHEMA" \
    "$reason" 1 1003 "$reason" DDL MSCK_REPAIR same

  reason="FAILED: ParseException line 1:5 missing EOF at '/' near 'MSCK'"
  case_failed "MS2" "MSCK /* c */ REPAIR TABLE（Hive）" \
    "MSCK /* c */ REPAIR TABLE $H" AwsDataCatalog "$SCHEMA" \
    "$reason" 1 1003 "$reason" DDL MSCK_REPAIR same

  reason="FAILED: ParseException line 1:12 missing EOF at '/' near 'REPAIR'"
  case_failed "MS3" "MSCK REPAIR /* c */ TABLE（無い表）" \
    "MSCK REPAIR /* c */ TABLE $M" AwsDataCatalog "$SCHEMA" \
    "$reason" 1 1003 "$reason" DDL MSCK_REPAIR same

  reason="Query type not supported by Athena Iceberg at this time"
  case_failed "MS4" "MSCK REPAIR /* c */ TABLE（Iceberg）" \
    "MSCK REPAIR /* c */ TABLE $I" iceberg "$SCHEMA" \
    "$reason" 2 1200 "$reason" DDL MSCK_REPAIR none

  # MS5・MS6: Iceberg 表の MSCK はコメント無しでも 2/1200、ビューはコメント入りで
  # ParseException（2026-09-26 ラウンド 3 の m1・m6）。
  case_failed "MS5" "MSCK REPAIR TABLE（Iceberg・コメント無し）" \
    "MSCK REPAIR TABLE $I" iceberg "$SCHEMA" \
    "$reason" 2 1200 "$reason" DDL MSCK_REPAIR none

  reason="FAILED: ParseException line 1:12 missing EOF at '/' near 'REPAIR'"
  case_failed "MS6" "MSCK REPAIR /* c */ TABLE（ビュー）" \
    "MSCK REPAIR /* c */ TABLE $V" AwsDataCatalog "$SCHEMA" \
    "$reason" 1 1003 "$reason" DDL MSCK_REPAIR same

  # AT1〜AT7: ALTER TABLE。DDL/ALTER_TABLE_*。AT5（RENAME TO）・AT6・AT7（DROP COLUMN）だけ
  # ErrorMessage が StateChangeReason と別で 2/1006。
  reason="FAILED: ParseException line 1:0 cannot recognize input near 'ALTER' '/' '*' in alter statement"
  case_failed "AT1" "ALTER /* c */ TABLE ADD COLUMNS（Hive）" \
    "ALTER /* c */ TABLE $H ADD COLUMNS (c int)" AwsDataCatalog "$SCHEMA" \
    "$reason" 1 1003 "$reason" DDL ALTER_TABLE_ADD_COLUMN same

  case_failed "AT2" "ALTER /* c */ TABLE ADD COLUMNS（無い表）" \
    "ALTER /* c */ TABLE $M ADD COLUMNS (c int)" AwsDataCatalog "$SCHEMA" \
    "$reason" 1 1003 "$reason" DDL ALTER_TABLE_ADD_COLUMN same

  case_failed "AT3" "ALTER /* c */ TABLE ADD COLUMNS（ビュー）" \
    "ALTER /* c */ TABLE $V ADD COLUMNS (c int)" AwsDataCatalog "$SCHEMA" \
    "$reason" 1 1003 "$reason" DDL ALTER_TABLE_ADD_COLUMN same

  reason="FAILED: ParseException line 1:12 cannot recognize input near '/' '*' 'c' in table name"
  case_failed "AT4" "ALTER TABLE /* c */ ADD COLUMNS（無い表・名前の直前）" \
    "ALTER TABLE /* c */ $M ADD COLUMNS (c int)" AwsDataCatalog "$SCHEMA" \
    "$reason" 1 1003 "$reason" DDL ALTER_TABLE_ADD_COLUMN same

  reason="FAILED: ParseException line 1:0 cannot recognize input near 'ALTER' '/' '*' in alter statement"
  case_failed "AT5" "ALTER /* c */ TABLE RENAME TO（無い表）" \
    "ALTER /* c */ TABLE $M RENAME TO $NEWNAME" AwsDataCatalog "$SCHEMA" \
    "$reason" 2 1006 "Query type not supported by DDL engine." DDL ALTER_TABLE_RENAME same

  local at6_sql at6_prefix at6_col at6_errmsg
  at6_sql="ALTER /* c */ TABLE $H DROP COLUMN n"
  at6_prefix="${at6_sql%%COLUMN*}"
  at6_col=$((${#at6_prefix} + 1))
  at6_errmsg="line 1:${at6_col}: mismatched input 'COLUMN' expecting 'PARTITION'"
  case_failed "AT6" "ALTER /* c */ TABLE DROP COLUMN（Hive）" \
    "$at6_sql" AwsDataCatalog "$SCHEMA" \
    "$reason" 2 1006 "$at6_errmsg" DDL ALTER_TABLE_DROP_COLUMN same

  # AT7: ErrorMessage の位置も 2 文字以上の空白を畳んだ文で数える（2026-09-26 ラウンド 3 の n9）。
  local at7_sql at7_prefix at7_errmsg
  at7_sql="ALTER  /* c */ TABLE $M DROP COLUMN c"
  at7_prefix="ALTER /* c */ TABLE $M DROP "
  at7_errmsg="line 1:$((${#at7_prefix} + 1)): mismatched input 'COLUMN' expecting 'PARTITION'"
  case_failed "AT7" "ALTER  /* c */ TABLE DROP COLUMN（無い表・空白 2 つ）" \
    "$at7_sql" AwsDataCatalog "$SCHEMA" \
    "$reason" 2 1006 "$at7_errmsg" DDL ALTER_TABLE_DROP_COLUMN same

  # AT8: 名前の 1 部目の awsdatacatalog. は落として表を確かめる（#244 の最終パスで直した。#242 の m33）。
  reason="FAILED: ParseException line 1:0 cannot recognize input near 'ALTER' '/' '*' in alter statement"
  case_failed "AT8" "ALTER /* c */ TABLE awsdatacatalog.<db>.<t> ADD COLUMNS（Hive）" \
    "ALTER /* c */ TABLE awsdatacatalog.$SCHEMA.$H ADD COLUMNS (c int)" AwsDataCatalog "$SCHEMA" \
    "$reason" 1 1003 "$reason" DDL ALTER_TABLE_ADD_COLUMN same

  # DS1〜DS4: DESCRIBE/DESC。UTILITY/DESCRIBE_TABLE。実装前に PASS するのは DS1（#242 の既存）だけで、
  # DS2（DESC）・DS3（先頭コメント）・DS4（Iceberg は成功）は #244 で直す。
  reason="FAILED: ParseException line 1:0 cannot recognize input near 'DESCRIBE' '/' '*' in describe statement"
  case_failed "DS1" "DESCRIBE /* c */（Hive・#242の既存）" \
    "DESCRIBE /* c */ $H" AwsDataCatalog "$SCHEMA" \
    "$reason" 1 1003 "$reason" UTILITY DESCRIBE_TABLE same

  reason="FAILED: ParseException line 1:0 cannot recognize input near 'DESC' '/' '*' in describe statement"
  case_failed "DS2" "DESC /* c */（Hive）" \
    "DESC /* c */ $H" AwsDataCatalog "$SCHEMA" \
    "$reason" 1 1003 "$reason" UTILITY DESCRIBE_TABLE same

  reason="FAILED: ParseException line 1:0 cannot recognize input near '/' '*' 'c'"
  case_failed "DS3" "/* c */ DESCRIBE（Hive）" \
    "/* c */ DESCRIBE $H" AwsDataCatalog "$SCHEMA" \
    "$reason" 1 1003 "$reason" UTILITY DESCRIBE_TABLE same

  # DS4 は #242 の欠陥（Iceberg も誤って FAILED にしていた）を #244 が取り込んで直す。
  # 実装前は FAILED のままなので、このケースは今のビルドで FAIL するのが正しい。
  case_succeeded "DS4" "DESCRIBE /* c */（Iceberg・#242の欠陥を#244で直す）" \
    "DESCRIBE /* c */ $I" iceberg "$SCHEMA"

  # --- #257: #244 で測っていなかった位置・形（.claude/issue-notes/257.md の実測の結果）。
  # 実装前はどれも FAIL するのが正しい（Trino の構文がそのまま通るか、開始時 400 になるかのどちらかで、
  # 期待している「本物どおりの FAILED」にはならない）。

  # G1: SHOW CREATE TABLE のコメントが名前の中（DB の後の . の直後）にあるとき（実測 g1）。
  local g1_sql g1_prefix g1_pos g1_reason
  g1_sql="SHOW CREATE TABLE ${SCHEMA}./* c */${H}"
  g1_prefix="${g1_sql%%/*}"
  g1_pos=${#g1_prefix}
  g1_reason="FAILED: ParseException line 1:${g1_pos} cannot recognize input near '${SCHEMA}' '.' '/' in table name"
  case_failed "G1" "SHOW CREATE TABLE DB./* c */T（名前の中）" \
    "$g1_sql" AwsDataCatalog "$SCHEMA" \
    "$g1_reason" 1 1003 "$g1_reason" UTILITY SHOW_CREATE_TABLE same

  # G2: MSCK REPAIR TABLE のコメントが名前の後ろにあるとき（実測 g2）。
  local g2_sql g2_prefix g2_pos g2_reason
  g2_sql="MSCK REPAIR TABLE ${SCHEMA}.${H} /* c */"
  g2_prefix="${g2_sql%%/*}"
  g2_pos=${#g2_prefix}
  g2_reason="FAILED: ParseException line 1:${g2_pos} missing EOF at '/' near '${H}'"
  case_failed "G2" "MSCK REPAIR TABLE DB.T /* c */（名前の後ろ）" \
    "$g2_sql" AwsDataCatalog "$SCHEMA" \
    "$g2_reason" 1 1003 "$g2_reason" DDL MSCK_REPAIR same

  # G3: ALTER TABLE のコメントが句の中（名前と ADD COLUMNS の間）にあるとき（実測 g3）。
  local g3_sql g3_prefix g3_pos g3_reason
  g3_sql="ALTER TABLE ${SCHEMA}.${H} /* c */ ADD COLUMNS (c20 int)"
  g3_prefix="${g3_sql%%/*}"
  g3_pos=${#g3_prefix}
  g3_reason="FAILED: ParseException line 1:${g3_pos} cannot recognize input near '/' '*' 'c' in alter table statement"
  case_failed "G3" "ALTER TABLE DB.T /* c */ ADD COLUMNS（句の中）" \
    "$g3_sql" AwsDataCatalog "$SCHEMA" \
    "$g3_reason" 1 1003 "$g3_reason" DDL ALTER_TABLE_ADD_COLUMN same

  # DE1: DESCRIBE EXTENDED のコメントが直後（EXTENDED の後）にあるとき（実測 de1）。
  local de1_sql de1_prefix de1_pos de1_reason
  de1_sql="DESCRIBE EXTENDED /* c */ ${SCHEMA}.${H}"
  de1_prefix="${de1_sql%%/*}"
  de1_pos=${#de1_prefix}
  de1_reason="FAILED: ParseException line 1:${de1_pos} cannot recognize input near '/' '*' 'c' in specifying describe table types"
  case_failed "DE1" "DESCRIBE EXTENDED /* c */ DB.T（EXTENDED の後）" \
    "$de1_sql" AwsDataCatalog "$SCHEMA" \
    "$de1_reason" 1 1003 "$de1_reason" UTILITY DESCRIBE_TABLE same

  # R1・R3: REPLACE COLUMNS・CHANGE COLUMN も ALTER の直後のコメントで ParseException になる
  # （実測 r1・r3。ErrorMessage は StateChangeReason と別で、AT5 と同じ「サポート外」の文言）。
  local ar_reason="FAILED: ParseException line 1:0 cannot recognize input near 'ALTER' '/' '*' in alter statement"
  local ar_errmsg="Query type not supported by DDL engine."

  case_failed "R1" "ALTER /* c */ TABLE REPLACE COLUMNS" \
    "ALTER /* c */ TABLE ${SCHEMA}.${H} REPLACE COLUMNS (n int, s string)" AwsDataCatalog "$SCHEMA" \
    "$ar_reason" 2 1006 "$ar_errmsg" DDL ALTER_TABLE_REPLACE_COLUMN same

  case_failed "R3" "ALTER /* c */ TABLE CHANGE COLUMN" \
    "ALTER /* c */ TABLE ${SCHEMA}.${H} CHANGE COLUMN n n2 int" AwsDataCatalog "$SCHEMA" \
    "$ar_reason" 2 1006 "$ar_errmsg" DDL ALTER_TABLE_CHANGE_COLUMN same

  # E1・E2・E5: 先頭コメントの中身が 2 文字の記号・閉じていない引用符のとき（実測 e1・e2・e5）。
  case_failed "E1" "先頭コメント /* <= */" \
    "/* <= */ SHOW CREATE TABLE ${SCHEMA}.${H}" AwsDataCatalog "$SCHEMA" \
    "FAILED: ParseException line 1:0 cannot recognize input near '/' '*' '<='" 1 1003 \
    "FAILED: ParseException line 1:0 cannot recognize input near '/' '*' '<='" UTILITY SHOW_CREATE_TABLE same

  case_failed "E2" "先頭コメント /* != */" \
    "/* != */ SHOW CREATE TABLE ${SCHEMA}.${H}" AwsDataCatalog "$SCHEMA" \
    "FAILED: ParseException line 1:0 cannot recognize input near '/' '*' '!='" 1 1003 \
    "FAILED: ParseException line 1:0 cannot recognize input near '/' '*' '!='" UTILITY SHOW_CREATE_TABLE same

  case_failed "E5" "先頭コメント /* 'a */（閉じていない引用符）" \
    "/* 'a */ SHOW CREATE TABLE ${SCHEMA}.${H}" AwsDataCatalog "$SCHEMA" \
    "FAILED: ParseException line 1:0 cannot recognize input near '/' '*' 'a'" 1 1003 \
    "FAILED: ParseException line 1:0 cannot recognize input near '/' '*' 'a'" UTILITY SHOW_CREATE_TABLE same

  # POS1: ALTER の後のコメントで awsdatacatalog. を含む DROP COLUMN。ErrorMessage・Query とも
  # 受け取ったままの文で数える（実測 pos1。落とした後の文で数えていた #244 までの規則と違う点）。
  local pos1_sql pos1_prefix pos1_t pos1_errmsg pos1_got_query
  pos1_sql="ALTER /* c */ TABLE awsdatacatalog.${SCHEMA}.${H} DROP COLUMN n"
  pos1_prefix="ALTER /* c */ TABLE awsdatacatalog.${SCHEMA}."
  pos1_t=${#pos1_prefix}
  pos1_errmsg="line 1:${pos1_t}: no viable alternative at input '${pos1_prefix}'"
  case_failed "POS1" "ALTER /* c */ TABLE awsdatacatalog.DB.T DROP COLUMN" \
    "$pos1_sql" AwsDataCatalog "$SCHEMA" \
    "$ar_reason" 2 1006 "$pos1_errmsg" DDL ALTER_TABLE_DROP_COLUMN same
  pos1_got_query=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.Query // "無し"')
  if [ "$pos1_got_query" != "$pos1_sql" ]; then
    downgrade_last_result "Query=\"${pos1_got_query}\"(期待は受け取ったままの \"${pos1_sql}\")"
  fi
}

# --- ケース（回帰。今のビルドでも PASS するはず） ---
run_regression_cases() {
  case_succeeded "REG1" "SHOW CREATE TABLE（Hive・コメント無し）" \
    "SHOW CREATE TABLE $H" AwsDataCatalog "$SCHEMA"

  case_succeeded "REG2" "SHOW /* c */ CREATE TABLE（Iceberg）" \
    "SHOW /* c */ CREATE TABLE $I" iceberg "$SCHEMA"

  case_succeeded "REG3" "/* c */ SHOW CREATE TABLE（Iceberg）" \
    "/* c */ SHOW CREATE TABLE $I" iceberg "$SCHEMA"

  case_succeeded "REG4" "ALTER TABLE DROP COLUMN（Iceberg・コメント無し）" \
    "ALTER TABLE $I DROP COLUMN $EXTRA1" iceberg "$SCHEMA"

  case_succeeded "REG5" "ALTER /* c */ TABLE DROP COLUMN（Iceberg）" \
    "ALTER /* c */ TABLE $I DROP COLUMN $EXTRA2" iceberg "$SCHEMA"

  case_succeeded "REG6" "DESCRIBE /* c */（ビュー）" \
    "DESCRIBE /* c */ $V" AwsDataCatalog "$SCHEMA"

  case_succeeded "REG7" "DESCRIBE -- c\\n（Hive・行コメント）" \
    "$(printf 'DESCRIBE -- c\n%s' "$H")" AwsDataCatalog "$SCHEMA"

  case_succeeded "REG8" "SHOW /* c */ TABLES（範囲外の文）" \
    "SHOW /* c */ TABLES" AwsDataCatalog "$SCHEMA"

  case_start_reject "REG9" "MSCK REPAIR TABLE（コメント無し・Trino に無い構文）" \
    "MSCK REPAIR TABLE $H" AwsDataCatalog "$SCHEMA"

  case_start_reject "REG10" "ALTER TABLE ADD COLUMNS（コメント無し・Trino に無い構文）" \
    "ALTER TABLE $H ADD COLUMNS (c int)" AwsDataCatalog "$SCHEMA"

  # 本物は Iceberg 表への ADD COLUMNS をコメント入りでも成功させた（2026-09-26 実測 a3）が、Trino に
  # ADD COLUMNS の文法が無いので athena-local は今までどおり構文チェックで弾く（偽 Trino では確かめられない）。
  case_start_reject "REG11" "ALTER /* c */ TABLE ADD COLUMNS（Iceberg・Trino に無い構文のまま）" \
    "ALTER /* c */ TABLE $I ADD COLUMNS (c int)" iceberg "$SCHEMA"

  # --- #257: 本 issue で送ってみたが実装で変えない形。期待値は本物ではなく、今のビルドを実際に
  # 流して観測した値（.claude/issue-notes/257.md には無い。このスクリプトの探索用の別実行で確認済み）。

  # G1 の形・Iceberg 表: 本物も成功する形（issue #257 本文）。今のビルドも Trino がそのまま実行して
  # SUCCEEDED になる（Hive の表だけを止める #244 の判定は Iceberg には掛からない）。
  case_succeeded "G1I" "SHOW CREATE TABLE DB./* c */T（Iceberg・名前の中）" \
    "SHOW CREATE TABLE ${SCHEMA}./* c */${I}" iceberg "$SCHEMA"

  # G1 の形・ビュー: Trino 自身が実行して「view であって table でない」と断る（NOT_SUPPORTED）。
  # ParseException の文言にはならない。
  local g1v_reason="NOT_SUPPORTED: line 1:1: Relation 'hive.${SCHEMA}.${V}' is a view, not a table"
  case_failed "G1V" "SHOW CREATE TABLE DB./* c */T（ビュー・名前の中）" \
    "SHOW CREATE TABLE ${SCHEMA}./* c */${V}" AwsDataCatalog "$SCHEMA" \
    "$g1v_reason" 2 1200 "$g1v_reason" UTILITY SHOW_CREATE_TABLE prefixed

  # G1 の形・無い表: Trino 自身が実行して TABLE_NOT_FOUND を返す。
  local g1m_reason="TABLE_NOT_FOUND: line 1:1: Table 'hive.${SCHEMA}.${M}' does not exist"
  case_failed "G1M" "SHOW CREATE TABLE DB./* c */T（無い表・名前の中）" \
    "SHOW CREATE TABLE ${SCHEMA}./* c */${M}" AwsDataCatalog "$SCHEMA" \
    "$g1m_reason" 2 1301 "$g1m_reason" UTILITY SHOW_CREATE_TABLE prefixed

  # G3 の形・ビュー: Trino に ADD COLUMNS（複数形）の文法が無いので、表がビューでも開始時 400
  # （REG10・REG11 と同じ理由。ビューかどうかを見る前に構文チェックで弾かれる）。
  case_start_reject "G3V" "ALTER TABLE DB.T /* c */ ADD COLUMNS（ビュー・句の中）" \
    "ALTER TABLE ${SCHEMA}.${V} /* c */ ADD COLUMNS (c20 int)" AwsDataCatalog "$SCHEMA"

  # DE1 の形・Iceberg・ビュー: Trino の DESCRIBE 文法に EXTENDED が無く、"EXTENDED" 自体を表名として
  # 読んでから続きの修飾名で構文エラーになる（表の種類によらず開始時 400）。
  case_start_reject "DE1I" "DESCRIBE EXTENDED /* c */ DB.T（Iceberg・EXTENDED の後）" \
    "DESCRIBE EXTENDED /* c */ ${SCHEMA}.${I}" iceberg "$SCHEMA"

  case_start_reject "DE1V" "DESCRIBE EXTENDED /* c */ DB.T（ビュー・EXTENDED の後）" \
    "DESCRIBE EXTENDED /* c */ ${SCHEMA}.${V}" AwsDataCatalog "$SCHEMA"

  # ほかの位置（名前の後ろの空白を挟んだ末尾）: Trino がそのまま実行して SUCCEEDED になる。
  case_succeeded "G1POS2" "SHOW CREATE TABLE DB.T /* c */（名前の後ろ・末尾）" \
    "SHOW CREATE TABLE ${SCHEMA}.${H} /* c */" AwsDataCatalog "$SCHEMA"

  # R2: SET LOCATION は Trino に構文が無いので開始時 400（本文の予想どおり）。
  case_start_reject "R2" "ALTER /* c */ TABLE SET LOCATION（Trino に無い構文）" \
    "ALTER /* c */ TABLE ${SCHEMA}.${H} SET LOCATION 's3://dummy/loc/'" AwsDataCatalog "$SCHEMA"

  # AT9: #256 の形（コメント無し）。awsdatacatalog. は #242 の drop_catalog で落ち、athena-local は落とした後の
  # 文で Hive 表の DROP COLUMN を Trino に送らずに FAILED にする（#256 の plain_alter_failure）。位置は
  # StateChangeReason が落とした後の文の COLUMN の 0 始まり、ErrorMessage がその + 1（落とす前と後のどちらで
  # 数えるかは本物で未実測）。ほかの H に触るケースをすべて終えたこの位置でだけ実行する。
  local at9_sql at9_rewritten at9_before_column at9_p1 at9_p2 at9_reason at9_errmsg at9_got_query
  at9_sql="ALTER TABLE awsdatacatalog.${SCHEMA}.${H} DROP COLUMN n"
  # Query（GetQueryExecution が返す・#242 の drop_catalog）は awsdatacatalog. を落とした 2 部の名前。
  at9_rewritten="ALTER TABLE ${SCHEMA}.${H} DROP COLUMN n"
  at9_before_column="${at9_rewritten%%COLUMN*}"
  at9_p1=${#at9_before_column}
  at9_p2=$((at9_p1 + 1))
  at9_reason="FAILED: ParseException line 1:${at9_p1} mismatched input 'COLUMN' expecting PARTITION near 'DROP' in drop partition statement"
  at9_errmsg="line 1:${at9_p2}: mismatched input 'COLUMN' expecting 'PARTITION'"
  case_failed "AT9" "ALTER TABLE awsdatacatalog.DB.T DROP COLUMN（コメント無し・#256）" \
    "$at9_sql" AwsDataCatalog "$SCHEMA" \
    "$at9_reason" 2 1006 "$at9_errmsg" DDL ALTER_TABLE_DROP_COLUMN same
  at9_got_query=$(jqx "$LAST_EXEC_JSON" '.QueryExecution.Query // "無し"')
  if [ "$at9_got_query" != "$at9_rewritten" ]; then
    downgrade_last_result "Query=\"${at9_got_query}\"(期待は awsdatacatalog. を落とした \"${at9_rewritten}\")"
  fi
}

GATE_STATUS=""
GATE_DETAIL=""

# 判定がわざと壊すと落ちることの自己確認（design-checklist の趣旨に沿った確認）。
# SC1 の実行結果を使い回し、期待の StateChangeReason を 1 文字変えて再判定する。
# 本来のケース表の集計・終了コードには含めない（record 後すぐに pop_result で抜く）。
run_self_check_gate() {
  if [ -z "$SC1_ID" ]; then
    GATE_STATUS="SKIP"
    GATE_DETAIL="(SC1 が開始できなかったため自己確認を省略)"
    return
  fi
  log "自己確認: SC1 の期待値をわざと 1 か所変えて FAIL になるか確かめる"
  LAST_ID="$SC1_ID"
  LAST_EXEC_JSON="$SC1_EXEC_JSON"
  local wrong_reason="FAILED: ParseException line 1:5 cannot recognize input near 'SHOW' '/' '*' in ddl statement DUMMY"
  check_failed_result "GATE" "わざと壊した期待値（SC1のreasonを改変）" \
    "$wrong_reason" 1 1003 "$wrong_reason" UTILITY SHOW_CREATE_TABLE same
  pop_result
  GATE_STATUS="$LAST_POPPED_STATUS"
  GATE_DETAIL="$LAST_POPPED_DETAIL"
  if [ "$GATE_STATUS" = "FAIL" ]; then
    log "自己確認 OK: 期待値を壊すと判定は FAIL になった"
  else
    log "自己確認 NG: 期待値を壊しても判定が FAIL にならなかった（足場のバグの疑い）"
  fi
}

main() {
  log "作業ディレクトリ: $SCRIPT_DIR"
  log "証跡の保存先: $EVIDENCE_DIR"

  log "docker compose down -v / up -d ${SERVICES[*]}"
  if ! "${COMPOSE[@]}" down -v "${SERVICES[@]}" >/dev/null 2>&1; then
    record "compose起動" FAIL "docker compose down -v ${SERVICES[*]} が失敗した"
    return 1
  fi
  if ! "${COMPOSE[@]}" up -d "${SERVICES[@]}"; then
    record "compose起動" FAIL "docker compose up -d ${SERVICES[*]} が失敗した"
    return 1
  fi

  if ! mc alias set local http://minio:9000 minioadmin minioadmin >/dev/null; then
    record "MinIOバケット" FAIL "mc alias set が失敗した（minio:9000 に繋がらない）"
    return 1
  fi

  if ! wait_for_trino; then
    record "Trino起動" FAIL "Trino が起動しなかった"
    return 1
  fi
  record "Trino起動" PASS "$TRINO_BASE で応答"

  if ! wait_for_bucket; then
    record "MinIOバケット" FAIL "バケット $BUCKET の用意ができなかった"
    return 1
  fi
  record "MinIOバケット" PASS "バケット $BUCKET 用意済み"

  log "Trino 側のスキーマ・表・ビューを用意する"
  if ! trino_exec "CREATE SCHEMA IF NOT EXISTS hive.${SCHEMA}" hive default; then
    record "セットアップ(hiveスキーマ)" FAIL "hive.${SCHEMA} の作成に失敗した"
    return 1
  fi
  if ! trino_exec "CREATE SCHEMA IF NOT EXISTS iceberg.${SCHEMA}" iceberg default; then
    record "セットアップ(icebergスキーマ)" FAIL "iceberg.${SCHEMA} の作成に失敗した"
    return 1
  fi
  if ! trino_exec "CREATE TABLE hive.${SCHEMA}.${H} AS SELECT 1 AS n" hive "$SCHEMA"; then
    record "セットアップ(Hive表)" FAIL "hive.${SCHEMA}.${H} の作成に失敗した"
    return 1
  fi
  if ! trino_exec "CREATE VIEW hive.${SCHEMA}.${V} AS SELECT 1 AS n" hive "$SCHEMA"; then
    record "セットアップ(Hiveビュー)" FAIL "hive.${SCHEMA}.${V} の作成に失敗した"
    return 1
  fi
  if ! trino_exec "CREATE TABLE iceberg.${SCHEMA}.${I} AS SELECT 1 AS n" iceberg "$SCHEMA"; then
    record "セットアップ(Iceberg表)" FAIL "iceberg.${SCHEMA}.${I} の作成に失敗した"
    return 1
  fi
  if ! trino_exec "ALTER TABLE iceberg.${SCHEMA}.${I} ADD COLUMN ${EXTRA1} int" iceberg "$SCHEMA"; then
    record "セットアップ(Iceberg列extra1)" FAIL "${EXTRA1} の追加に失敗した"
    return 1
  fi
  if ! trino_exec "ALTER TABLE iceberg.${SCHEMA}.${I} ADD COLUMN ${EXTRA2} int" iceberg "$SCHEMA"; then
    record "セットアップ(Iceberg列extra2)" FAIL "${EXTRA2} の追加に失敗した"
    return 1
  fi
  record "セットアップ" PASS "hive.${SCHEMA}.${H}（表）・${V}（ビュー）、iceberg.${SCHEMA}.${I}（表・列 ${EXTRA1}/${EXTRA2} 追加済み）作成済み。${M}・${NEWNAME} は作らない"

  if ! build_athena_local; then
    record "cargo build" FAIL "ビルドが失敗した"
    return 1
  fi
  record "cargo build" PASS "$BINARY を用意した"

  if ! start_athena_local; then
    record "athena-local起動" FAIL "athena-local が起動しなかった"
    return 1
  fi
  record "athena-local起動" PASS "$ATHENA_BASE で応答（TRINO_CATALOG_MAP=AwsDataCatalog=hive）"

  run_new_behavior_cases
  run_regression_cases
  run_self_check_gate
}

main
