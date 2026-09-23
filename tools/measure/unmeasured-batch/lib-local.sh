# shellcheck shell=bash
# issue #113: TARGET=local のときだけ使う環境の上げ下げ。tools/e2e/minio/lib.sh の
# wait_for_trino / wait_for_bucket / start_athena_local を手本にしているが、
# decisions.md:47（足場間で source しない）に従い source せず、要る部分だけ複製する。
#
# 提供する関数（run.sh が呼ぶ）:
#   local_up      trino/minio/minio-init を作り直し、Trino のスキーマを用意し、
#                 athena-local をビルドして 127.0.0.1:8087 で起動する。
#   local_down    athena-local を止め、compose を down -v する。
#
# COMPOSE_PROJECT_NAME は上書きしない（tools/e2e/minio/verify.sh と同じ流儀）。
# dev コンテナ自身と同じ compose project でないと、trino/minio が dev と別ネットワークになり
# `http://trino:8080`／`http://minio:9000` に届かなくなるため。同時に別プロジェクトで
# 走らせたいときは、ホストで `COMPOSE_PROJECT_NAME=athena-local-unmeasured-batch
# tools/dev.sh env TARGET=local ...` のように起動全体を包むこと（docs/dev/development.md）。

REPO_ROOT_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LOCAL_BINARY="${CARGO_TARGET_DIR:-$REPO_ROOT_LOCAL/target}/release/athena-local"
LOCAL_COMPOSE=(docker compose -f "$REPO_ROOT_LOCAL/compose.yml")
LOCAL_SERVICES=(trino minio minio-init)

LOCAL_TRINO_BASE="http://trino:8080"
LOCAL_MINIO_ENDPOINT="http://minio:9000"
LOCAL_ATHENA_BASE="http://127.0.0.1:8087"
LOCAL_BUCKET="athena-results"
LOCAL_OUTPUT="s3://${LOCAL_BUCKET}/unmeasured-batch/"

LOCAL_ATHENA_PID=""
LOCAL_ATHENA_LOG=""

# セットアップ専用（測定対象の文は athena-local 経由で投げる）。
local_trino_exec() {
  local sql=$1 catalog=$2 schema=$3
  local resp next
  resp=$(curl -sf -X POST "$LOCAL_TRINO_BASE/v1/statement" \
    -H "X-Trino-User: unmeasured-batch-setup" \
    -H "X-Trino-Catalog: $catalog" \
    -H "X-Trino-Schema: $schema" \
    -H "X-Trino-Client-Capabilities: PARAMETRIC_DATETIME" \
    --data-binary "$sql") || return 1
  while true; do
    if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
      echo "local_trino_exec 失敗: $sql" >&2
      echo "$resp" | jq '.error' >&2
      return 1
    fi
    next=$(echo "$resp" | jq -r '.nextUri // empty')
    [ -z "$next" ] && break
    resp=$(curl -sf "$next")
  done
}

local_wait_for_trino() {
  echo "== Trino の起動待ち ($LOCAL_TRINO_BASE)"
  for _ in $(seq 1 60); do
    local_trino_exec "SELECT 1" system runtime >/dev/null 2>&1 && return 0
    sleep 2
  done
  echo "== Trino が起動しなかった" >&2
  return 1
}

local_wait_for_bucket() {
  echo "== MinIO バケットの用意待ち"
  for _ in $(seq 1 60); do
    mc ls "local/$LOCAL_BUCKET" >/dev/null 2>&1 && return 0
    sleep 2
  done
  echo "== バケットの用意ができなかった" >&2
  return 1
}

local_build_athena() {
  if [ "${SKIP_BUILD:-0}" = "1" ]; then
    echo "== SKIP_BUILD=1 のため cargo build を省略する"
    [ -x "$LOCAL_BINARY" ] && return 0
    echo "== $LOCAL_BINARY が無い" >&2
    return 1
  fi
  echo "== cargo build --release --locked を実行する"
  (cd "$REPO_ROOT_LOCAL" && cargo build --release --locked) >"$RUN_DIR/cargo-build.log" 2>&1 && return 0
  echo "== ビルド失敗。$RUN_DIR/cargo-build.log の末尾 40 行:" >&2
  tail -n 40 "$RUN_DIR/cargo-build.log" >&2
  return 1
}

# 引数 1: ATHENA_LOCAL_RETENTION_SECONDS（省略時は既定 3600。フェーズ 2 の t6/t7 が短い値で使う口）。
local_start_athena() {
  local retention=${1:-3600}
  LOCAL_ATHENA_LOG="$RUN_DIR/athena-local.log"
  echo "== athena-local を起動する（保持期限 ${retention} 秒）"
  (
    cd "$REPO_ROOT_LOCAL"
    exec env \
      ATHENA_LOCAL_BIND="127.0.0.1:8087" \
      TRINO_URL="$LOCAL_TRINO_BASE" \
      TRINO_USER="athena-local-unmeasured-batch" \
      ATHENA_LOCAL_RESULTS="s3" \
      AWS_ENDPOINT_URL_S3="$LOCAL_MINIO_ENDPOINT" \
      AWS_ACCESS_KEY_ID="minioadmin" \
      AWS_SECRET_ACCESS_KEY="minioadmin" \
      ATHENA_LOCAL_OUTPUT_LOCATION="$LOCAL_OUTPUT" \
      ATHENA_LOCAL_RETENTION_SECONDS="$retention" \
      "$LOCAL_BINARY"
  ) >"$LOCAL_ATHENA_LOG" 2>&1 &
  LOCAL_ATHENA_PID=$!

  echo "== athena-local ($LOCAL_ATHENA_BASE) の起動待ち"
  for _ in $(seq 1 30); do
    if ! kill -0 "$LOCAL_ATHENA_PID" 2>/dev/null; then
      echo "== athena-local が異常終了した。ログ:" >&2
      cat "$LOCAL_ATHENA_LOG" >&2
      return 1
    fi
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$LOCAL_ATHENA_BASE/" \
      -H "X-Amz-Target: AmazonAthena.ListWorkGroups" \
      -H "Content-Type: application/x-amz-json-1.1" \
      --data '{}')
    [ "$status" = "200" ] && {
      echo "== athena-local 起動確認"
      return 0
    }
    sleep 1
  done
  echo "== athena-local が応答しなかった" >&2
  return 1
}

local_stop_athena() {
  if [ -n "$LOCAL_ATHENA_PID" ] && kill -0 "$LOCAL_ATHENA_PID" 2>/dev/null; then
    echo "== athena-local (PID $LOCAL_ATHENA_PID) を止める"
    kill "$LOCAL_ATHENA_PID" 2>/dev/null || true
    wait "$LOCAL_ATHENA_PID" 2>/dev/null || true
  fi
  LOCAL_ATHENA_PID=""
}

# trino/minio/minio-init を作り直し、athena-local を起動するところまで。
local_up() {
  echo "== docker compose down -v / up -d ${LOCAL_SERVICES[*]}"
  "${LOCAL_COMPOSE[@]}" down -v "${LOCAL_SERVICES[@]}" >/dev/null 2>&1
  "${LOCAL_COMPOSE[@]}" up -d "${LOCAL_SERVICES[@]}" || return 1

  mc alias set local "$LOCAL_MINIO_ENDPOINT" minioadmin minioadmin >/dev/null || return 1
  local_wait_for_trino || return 1
  local_wait_for_bucket || return 1

  echo "== Trino 側のスキーマを用意する（hive.default / iceberg.default）"
  local_trino_exec "CREATE SCHEMA IF NOT EXISTS hive.default" hive default || true
  local_trino_exec "CREATE SCHEMA IF NOT EXISTS iceberg.default" iceberg default || true

  local_build_athena || return 1
  local_start_athena 3600 || return 1
}

local_down() {
  local_stop_athena
  echo "== docker compose down -v ${LOCAL_SERVICES[*]}"
  "${LOCAL_COMPOSE[@]}" down -v "${LOCAL_SERVICES[@]}" >/dev/null 2>&1 || true
}

# 誤って本物の AWS に飛んでも認証で落ちるように、プロセス全体の資格情報をダミーへ差し替える。
# run.sh が TARGET=local と分かった直後、一番最初に呼ぶ。
local_harden_credentials() {
  export AWS_ACCESS_KEY_ID="minioadmin"
  export AWS_SECRET_ACCESS_KEY="minioadmin"
  unset AWS_SESSION_TOKEN AWS_PROFILE
  export AWS_SHARED_CREDENTIALS_FILE=/dev/null
  export AWS_CONFIG_FILE=/dev/null
}
