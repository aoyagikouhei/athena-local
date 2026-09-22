#!/usr/bin/env bash
# issue #70 Step 9（実機検証）: 本物の Trino（trinodb/trino:482）と本物の S3 互換ストレージ
# （MinIO）を相手に athena-local を動かし、結果ファイル（本体と `.metadata`）の Content-Type が
# issue #70 の規則どおりかを実際に確かめる。
#
#   .csv（SELECT）   リテラルだけの SELECT        -> binary/octet-stream
#                    それ以外の SELECT            -> application/octet-stream
#   .txt             SHOW 系・0 バイトの DDL      -> binary/octet-stream
#                    DESCRIBE / EXPLAIN / SHOW CREATE TABLE -> application/octet-stream
#   .metadata        本体と同じ値
#
# 期待値は上の規則ひとつだけをハードコードしている（「変更前の期待値」に切り替える環境変数は無い）。
# したがって **#70 の変更が入る前のビルドで流すと、規則が変わるケースは FAIL になるのが正しい**。
# 変更前の予測: 1 FAIL / 2 PASS / 3 FAIL / 4 FAIL(.metadata だけ不一致) / 5 FAIL / 6 FAIL /
#               7a PASS / 7b PASS
#
# 前提コマンド: docker, docker compose, curl, jq, uuidgen, cargo
# S3（MinIO）側の確認は aws cli を使わず、compose と同じネットワークに繋いだ
# quay.io/minio/mc の使い捨てコンテナで行う（このマシンの aws コマンドは docker ラッパーで、
# ホストにマップしたポートに届かない。2026-09-21 実測）。
#
# 使い方:
#   .claude/issue-notes/70-e2e/verify.sh
#
# 環境変数:
#   KEEP_UP=1        テスト後に docker compose down -v をせず環境を残す（デバッグ用）
#   SKIP_BUILD=1     cargo build を省略し、既存の target/release/athena-local をそのまま使う
#
# 後始末は本スクリプトの trap が行う（KEEP_UP=1 でなければ必ず docker compose down -v する）。
# 落とすのはこの compose プロジェクト（athena-local-issue70-e2e）だけで、他のプロジェクトには触らない。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
COMPOSE_PROJECT="athena-local-issue70-e2e"

TRINO_BASE="http://127.0.0.1:8093"
MINIO_ENDPOINT="http://127.0.0.1:9004"
ATHENA_BASE="http://127.0.0.1:8088"
BUCKET="athena-results"
PREFIX="e2e"
OUTPUT_LOCATION="s3://${BUCKET}/${PREFIX}/"
RUN_ID="$(date +%s)"

BINARY="binary/octet-stream"
APPLICATION="application/octet-stream"

MC_IMAGE="quay.io/minio/mc:latest"
MC_NETWORK="${COMPOSE_PROJECT}_default"
MC_ALIAS_CMD='mc alias set local http://minio:9000 minioadmin minioadmin >/dev/null 2>&1'

EVIDENCE_DIR="$(mktemp -d /tmp/athena-local-issue70-e2e.XXXXXX)"
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
    printf "%-8s %-46s %s\n" "${RESULT_STATUS[$i]}" "${RESULT_NAMES[$i]}" "${RESULT_DETAIL[$i]}"
  done
  echo "=============================================="
  local pass=0 fail=0 skip=0
  for i in "${!RESULT_STATUS[@]}"; do
    case "${RESULT_STATUS[$i]}" in
      PASS) pass=$((pass + 1)) ;;
      FAIL) fail=$((fail + 1)) ;;
      *) skip=$((skip + 1)) ;;
    esac
  done
  echo "PASS=$pass FAIL=$fail SKIP=$skip"
  echo "証跡（応答 JSON・mc stat の出力・本体の中身・ログ）: $EVIDENCE_DIR"
}

cleanup() {
  local status=$?
  if [ -n "$ATHENA_PID" ] && kill -0 "$ATHENA_PID" 2>/dev/null; then
    log "athena-local (PID $ATHENA_PID) を止める"
    kill "$ATHENA_PID" 2>/dev/null || true
    wait "$ATHENA_PID" 2>/dev/null || true
  fi
  if [ "${KEEP_UP:-0}" = "1" ]; then
    log "KEEP_UP=1 のため docker compose はそのまま残す（後で手動で down -v してください）"
    log "  docker compose -f $COMPOSE_FILE down -v"
  else
    log "docker compose down -v（このプロジェクトだけ）"
    docker compose -f "$COMPOSE_FILE" down -v >/dev/null 2>&1
  fi
  print_table
  exit "$status"
}
trap cleanup EXIT

# --- Trino への直接アクセス（セットアップ専用。測定対象の文は athena-local 経由で投げる） ---

trino_exec() {
  local sql="$1" catalog="$2" schema="$3"
  local resp next
  resp=$(curl -sf -X POST "$TRINO_BASE/v1/statement" \
    -H "X-Trino-User: e2e-setup" \
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
  for _ in $(seq 1 90); do
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
    if docker run --rm --network "$MC_NETWORK" --entrypoint sh "$MC_IMAGE" \
      -c "$MC_ALIAS_CMD && mc ls 'local/$BUCKET' >/dev/null" >/dev/null 2>&1; then
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
    [ -x "$REPO_ROOT/target/release/athena-local" ] && return 0
    log "target/release/athena-local が無い"
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
      ATHENA_LOCAL_BIND="127.0.0.1:8088" \
      TRINO_URL="$TRINO_BASE" \
      TRINO_USER="athena-local-e2e70" \
      TRINO_CATALOG="hive" \
      TRINO_SCHEMA="default" \
      ATHENA_LOCAL_RESULTS="s3" \
      AWS_ENDPOINT_URL_S3="$MINIO_ENDPOINT" \
      AWS_ACCESS_KEY_ID="minioadmin" \
      AWS_SECRET_ACCESS_KEY="minioadmin" \
      ATHENA_LOCAL_OUTPUT_LOCATION="$OUTPUT_LOCATION" \
      "$REPO_ROOT/target/release/athena-local"
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
    --data "$body"
}

# StartQueryExecution の生の応答を返す（QueryExecutionId の有無は呼び出し元が見る）。
athena_start_query_raw() {
  local sql="$1" catalog="$2" database="$3"
  local token body
  token="$(uuidgen)"
  body=$(jq -n --arg sql "$sql" --arg catalog "$catalog" --arg db "$database" --arg token "$token" \
    '{QueryString: $sql, QueryExecutionContext: {Catalog: $catalog, Database: $db}, ClientRequestToken: $token}')
  athena_call StartQueryExecution "$body"
}

athena_wait() {
  local id="$1" resp state _
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

# --- S3（MinIO）側の確認（quay.io/minio/mc の使い捨てコンテナ経由） ---

# `mc stat --json <key>` を実行して、その key に厳密一致するオブジェクトの JSON を 1 行返す。
# 無ければ {"status":"error"} を返す。
#
# 注意（2026-09-21 実測・#39 から引き継ぎ）: mc stat は与えたキーを前方一致のプレフィックスとしても
# 扱い、`<id>.csv` を指定すると `<id>.csv.metadata` まで一緒にヒットして JSON が複数行返る。
# `name` フィールドで厳密に絞り込む。
mc_stat() {
  local key="$1" name raw
  name=$(basename "$key")
  raw=$(docker run --rm --network "$MC_NETWORK" --entrypoint sh "$MC_IMAGE" \
    -c "$MC_ALIAS_CMD && mc stat --json 'local/$BUCKET/$key'" 2>/dev/null)
  printf '%s\n' "$raw" >"$EVIDENCE_DIR/${name}.stat.raw.json"
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

# オブジェクトの中身をバイト単位そのまま $out に落とす（証跡用）。
mc_get() {
  local key="$1" out="$2"
  docker run --rm --network "$MC_NETWORK" --entrypoint sh "$MC_IMAGE" \
    -c "$MC_ALIAS_CMD && mc cat 'local/$BUCKET/$key'" >"$out" 2>/dev/null
}

stat_content_type() {
  echo "$1" | jq -r '.metadata["Content-Type"] // .metadata["content-type"] // empty'
}

stat_size() {
  echo "$1" | jq -r '.size // empty'
}

# --- ケース ---
#
# 期待値は #70 の規則そのもの。本体の Content-Type（expect_body_ct）と
# `.metadata` の Content-Type（expect_meta_ct。`absent` ならオブジェクトが無いこと）を判定する。
# expect_body_size が空でなければ本体のバイト数も判定する。
run_case() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5" ext="$6"
  local expect_body_ct="$7" expect_meta_ct="$8" expect_body_size="${9:-}"

  log "ケース $no: $name -- $sql"

  local label="$no $name"
  local start_resp id resp state
  start_resp=$(athena_start_query_raw "$sql" "$catalog" "$database")
  printf '%s\n' "$start_resp" >"$EVIDENCE_DIR/case-${no}.start.json"
  id=$(echo "$start_resp" | jq -r '.QueryExecutionId // empty')
  if [ -z "$id" ]; then
    record "$label" FAIL "StartQueryExecution が QueryExecutionId を返さなかった: $(echo "$start_resp" | tr -d '\n')"
    return
  fi

  resp=$(athena_wait "$id")
  printf '%s\n' "$resp" >"$EVIDENCE_DIR/case-${no}.execution.json"
  state=$(echo "$resp" | jq -r '.QueryExecution.Status.State // empty')
  if [ "$state" != "SUCCEEDED" ]; then
    local reason
    reason=$(echo "$resp" | jq -r '.QueryExecution.Status.StateChangeReason // empty')
    record "$label" FAIL "終了状態が SUCCEEDED でない: $state ($reason) [id=$id]"
    return
  fi

  local key="${PREFIX}/${id}.${ext}"
  local ok=1 detail=""

  # 本体
  local body_stat body_ct body_size
  body_stat=$(mc_stat "$key")
  if ! mc_exists "$body_stat"; then
    ok=0
    detail="本体=無し(期待 ${expect_body_ct})"
  else
    body_ct=$(stat_content_type "$body_stat")
    body_size=$(stat_size "$body_stat")
    mc_get "$key" "$EVIDENCE_DIR/$(basename "$key")"
    if [ "$body_ct" = "$expect_body_ct" ]; then
      detail="本体=${body_ct}(期待どおり,${body_size}B)"
    else
      ok=0
      detail="本体=${body_ct}(期待 ${expect_body_ct},${body_size}B)"
    fi
    if [ -n "$expect_body_size" ] && [ "$body_size" != "$expect_body_size" ]; then
      ok=0
      detail="$detail 本体のバイト数=${body_size}(期待 ${expect_body_size})"
    fi
  fi

  # .metadata
  local meta_stat meta_ct
  meta_stat=$(mc_stat "${key}.metadata")
  if [ "$expect_meta_ct" = "absent" ]; then
    if mc_exists "$meta_stat"; then
      ok=0
      detail="$detail / .metadata=ある(期待 無し, $(stat_content_type "$meta_stat"))"
    else
      detail="$detail / .metadata=無し(期待どおり)"
    fi
  elif ! mc_exists "$meta_stat"; then
    ok=0
    detail="$detail / .metadata=無し(期待 ${expect_meta_ct})"
  else
    meta_ct=$(stat_content_type "$meta_stat")
    mc_get "${key}.metadata" "$EVIDENCE_DIR/$(basename "$key").metadata"
    if [ "$meta_ct" = "$expect_meta_ct" ]; then
      detail="$detail / .metadata=${meta_ct}(期待どおり)"
    else
      ok=0
      detail="$detail / .metadata=${meta_ct}(期待 ${expect_meta_ct})"
    fi
  fi

  if [ "$ok" = "1" ]; then
    record "$label" PASS "$detail [id=$id]"
  else
    record "$label" FAIL "$detail [id=$id]"
  fi
}

main() {
  log "作業ディレクトリ: $SCRIPT_DIR"
  log "証跡の保存先: $EVIDENCE_DIR"

  log "docker compose up -d"
  if ! docker compose -f "$COMPOSE_FILE" up -d; then
    record "compose起動" FAIL "docker compose up -d が失敗した"
    return 1
  fi

  local detected_network
  detected_network=$(docker network ls --filter "label=com.docker.compose.project=${COMPOSE_PROJECT}" --format '{{.Name}}' | head -1)
  if [ -n "$detected_network" ]; then
    MC_NETWORK="$detected_network"
  fi
  log "mc 用ネットワーク: $MC_NETWORK"

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

  log "Trino 側のスキーマとテーブルを用意する（#39 の e2e と同じ流儀）"
  trino_exec "CREATE SCHEMA IF NOT EXISTS hive.default" hive default || true

  local t_desc="t_ct_desc_${RUN_ID}"
  if ! trino_exec "CREATE TABLE hive.default.${t_desc} AS SELECT 1 AS n, 'a' AS s" hive default; then
    record "セットアップ(hive テーブル)" FAIL "hive.default.${t_desc} の作成に失敗した（ケース 5 の DESCRIBE が実行できない）"
    return 1
  fi
  record "セットアップ(hive テーブル)" PASS "hive.default.${t_desc} 作成済み"

  if ! build_athena_local; then
    record "cargo build" FAIL "ビルドが失敗した"
    record "ケース1〜7" SKIP "athena-local が起動できないため実行しなかった（ビルド失敗）"
    return 1
  fi
  record "cargo build" PASS "target/release/athena-local を用意した"

  if ! start_athena_local; then
    record "ケース1〜7" SKIP "athena-local が起動しなかったため実行しなかった"
    return 1
  fi
  record "athena-local起動" PASS "$ATHENA_BASE で応答"

  # ケース 1: リテラルだけの SELECT -> .csv も .metadata も binary
  run_case 1 "SELECT_1" \
    "SELECT 1" hive default csv "$BINARY" "$BINARY"

  # ケース 2: 式を含む SELECT -> .csv も .metadata も application
  run_case 2 "SELECT_1_plus_1" \
    "SELECT 1 + 1" hive default csv "$APPLICATION" "$APPLICATION"

  # ケース 3: リテラルだけの SELECT（別名つき・複数列） -> binary
  run_case 3 "SELECT_1_AS_i_comma_a" \
    "SELECT 1 AS i, 'a'" hive default csv "$BINARY" "$BINARY"

  # ケース 4: SHOW 系 -> .txt も .metadata も binary
  run_case 4 "SHOW_TABLES" \
    "SHOW TABLES" hive default txt "$BINARY" "$BINARY"

  # ケース 5: DESCRIBE -> .txt も .metadata も application
  run_case 5 "DESCRIBE_table" \
    "DESCRIBE ${t_desc}" hive default txt "$APPLICATION" "$APPLICATION"

  # ケース 6: EXPLAIN -> .txt も .metadata も application
  run_case 6 "EXPLAIN_SELECT_1" \
    "EXPLAIN SELECT 1" hive default txt "$APPLICATION" "$APPLICATION"

  # ケース 7: 0 バイトの DDL（Hive のスキーマ作成・削除） -> .txt は binary、.metadata は置かれない。
  # 作った schema は同じケースの DROP で必ず片づける（compose ごと消すので残っても害は無い）。
  local s_ddl="e2e_ct_${RUN_ID}"
  run_case 7a "CREATE_SCHEMA_hive_0バイト" \
    "CREATE SCHEMA ${s_ddl}" hive default txt "$BINARY" absent 0
  run_case 7b "DROP_SCHEMA_hive_0バイト" \
    "DROP SCHEMA ${s_ddl}" hive default txt "$BINARY" absent 0

  log "セットアップで作ったテーブルを片づける"
  trino_exec "DROP TABLE IF EXISTS hive.default.${t_desc}" hive default || true

  return 0
}

main
