#!/usr/bin/env bash
# issue #111 フェーズ 3: Python クライアント（awswrangler 3.17.1・PyAthena 3.36.0・dbt-athena 1.11.1）を
# athena-local の release バイナリ + 本物の Trino 482 + MinIO に向けて確かめる。本物の AWS は一切使わない。
#   (1) dbt-athena（debug・run-operation で GetWorkGroup、run は INFO）  → check_dbt.sh
#   (2) awswrangler read_sql_query(ctas_approach=False)                   → check_awswrangler.py s3 / none
#   (3) 失敗した DDL の <id>.txt を PyAthena の PandasCursor が読まないこと  → check_pyathena.py
#   (7) PyAthena・awswrangler の退行                                      → check_pyathena.py / check_awswrangler.py s3
#   (9) awswrangler が GetQueryResults を読む経路の先頭行                  → check_awswrangler.py none
#
# 構成: athena-local を 2 本（s3 モード 8098・none モード 8099）。s3 側の手前に中継
# （../sdk-retry/drop_proxy.py を DROP_COUNT=0 で。全部そのまま通し、1 リクエスト 1 行の X-Amz-Target を残す）を 8102 に置く。
# クライアントの向け先は env.sh（AWS_ENDPOINT_URL と _ATHENA → 中継、_S3 → MinIO 9006）。
# MinIO へのアクセスは `mc admin trace --json` を流す使い捨てコンテナで記録し、check ごとの区間だけを数える（common.py）。
#
# 前提: docker / docker compose / curl / jq、venv（先に ./setup-venvs.sh）、target/release/athena-local。
# 環境変数: KEEP_UP=1（compose を残す）、SKIP_BUILD=1（cargo build をしない）、VENV_ROOT（既定 $HOME/.cache/athena-local-111）
# 終了コードは FAIL の件数。証跡は /tmp/athena-local-issue111-py.* に残す。
# 落とすのはこの compose プロジェクト（athena-local-issue111-py）と、このスクリプトが起動したプロセス・trace コンテナだけ。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
COMPOSE=(docker compose -f "$SCRIPT_DIR/docker-compose.yml")
VENV_ROOT="${VENV_ROOT:-$HOME/.cache/athena-local-111}"
PY_WR="$VENV_ROOT/venv-wr/bin/python"
export DBT_BIN="$VENV_ROOT/venv-dbt/bin/dbt"

TRINO_BASE="http://127.0.0.1:8097"
export MINIO_ENDPOINT="http://127.0.0.1:9006"
ATHENA_S3="127.0.0.1:8098"
ATHENA_NONE="127.0.0.1:8099"
export PROXY_BIND="127.0.0.1:8102"
export TRACE_CONTAINER="athena-local-issue111-py-trace"
MC_IMAGE="quay.io/minio/mc:latest"
export RUN_ID="$(date +%s)"

export EVIDENCE_DIR="$(mktemp -d /tmp/athena-local-issue111-py.XXXXXX)"
export PROXY_LOG="$EVIDENCE_DIR/proxy.log"
RESULTS="$EVIDENCE_DIR/results.txt"
: >"$RESULTS"
PIDS=()

log() { echo "[verify] $*" >&2; }
record() { echo "$1 $2: $3" | tee -a "$RESULTS"; }

cleanup() {
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; done
  docker rm -f "$TRACE_CONTAINER" >/dev/null 2>&1
  if [ "${KEEP_UP:-0}" != "1" ]; then "${COMPOSE[@]}" down -v >/dev/null 2>&1; fi
  log "証跡: $EVIDENCE_DIR"
}
trap cleanup EXIT

preflight() {
  local cmd port
  for cmd in docker curl jq python3; do
    command -v "$cmd" >/dev/null || { log "$cmd が無い"; return 1; }
  done
  [ -x "$PY_WR" ] && [ -x "$DBT_BIN" ] || { log "venv が無い。先に $SCRIPT_DIR/setup-venvs.sh を流す"; return 1; }
  if [ "${SKIP_BUILD:-0}" != "1" ]; then
    (cd "$REPO_ROOT" && cargo build --release --locked >"$EVIDENCE_DIR/cargo-build.log" 2>&1) || { log "cargo build 失敗"; return 1; }
  fi
  [ -x "$REPO_ROOT/target/release/athena-local" ] || { log "target/release/athena-local が無い"; return 1; }
  for port in 8097 8098 8099 8102 9006; do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then log "ポート $port が使用中。止まる"; return 1; fi
  done
  "$PY_WR" -m pip freeze >"$EVIDENCE_DIR/freeze-wr.txt"
  "$VENV_ROOT/venv-dbt/bin/python" -m pip freeze >"$EVIDENCE_DIR/freeze-dbt.txt"
}

trino_exec() {
  local resp next
  resp=$(curl -sf -X POST "$TRINO_BASE/v1/statement" -H "X-Trino-User: e2e-setup" --data-binary "$1") || return 1
  while true; do
    echo "$resp" | jq -e '.error' >/dev/null 2>&1 && { echo "$resp" | jq -c '.error.message' >&2; return 1; }
    next=$(echo "$resp" | jq -r '.nextUri // empty')
    [ -z "$next" ] && return 0
    resp=$(curl -sf "$next") || return 1
  done
}

start_env() {
  log "compose up"
  "${COMPOSE[@]}" up -d >"$EVIDENCE_DIR/compose-up.log" 2>&1 || { log "compose up 失敗"; return 1; }
  for _ in $(seq 1 120); do trino_exec "SELECT 1" 2>/dev/null && break; sleep 1; done
  trino_exec "SELECT 1" || { log "Trino が起動しない"; return 1; }
  curl -s "$TRINO_BASE/v1/info" >"$EVIDENCE_DIR/trino-info.json"
  trino_exec "CREATE SCHEMA IF NOT EXISTS hive.default" && trino_exec "CREATE SCHEMA IF NOT EXISTS iceberg.default" || return 1
  MC_NETWORK=$(docker inspect athena-local-issue111-py-minio --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')
  export MC_NETWORK
}

start_athena_local() {
  local bind="$1" mode="$2" name="$3"
  (cd "$REPO_ROOT" && exec env ATHENA_LOCAL_BIND="$bind" TRINO_URL="$TRINO_BASE" TRINO_USER="athena-local-e2e" \
    TRINO_CATALOG=iceberg TRINO_SCHEMA=default TRINO_CATALOG_MAP="awsdatacatalog=iceberg,AwsDataCatalog=iceberg" \
    ATHENA_LOCAL_RESULTS="$mode" AWS_ENDPOINT_URL_S3="$MINIO_ENDPOINT" AWS_ACCESS_KEY_ID=minioadmin \
    AWS_SECRET_ACCESS_KEY=minioadmin ATHENA_LOCAL_OUTPUT_LOCATION="s3://athena-results/py/" \
    "$REPO_ROOT/target/release/athena-local") >"$EVIDENCE_DIR/athena-local-$name.log" 2>&1 &
  PIDS+=($!)
  for _ in $(seq 1 30); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://$bind/" -H 'X-Amz-Target: AmazonAthena.ListWorkGroups' \
      -H 'Content-Type: application/x-amz-json-1.1' --data '{}')" = 200 ] && return 0
    sleep 0.5
  done
  log "athena-local ($name) が応答しない"; return 1
}

start_proxy_and_trace() {
  # MARKER は本文に現れない文字列（DROP_COUNT=0 なので落とさない）。
  LISTEN="$PROXY_BIND" UPSTREAM="$ATHENA_S3" DROP_COUNT=0 MARKER="никогда-issue111" \
    python3 "$SCRIPT_DIR/../sdk-retry/drop_proxy.py" 2>"$PROXY_LOG" &
  PIDS+=($!)
  docker run -d --rm --name "$TRACE_CONTAINER" --network "$MC_NETWORK" --entrypoint sh "$MC_IMAGE" -c \
    "mc alias set local http://minio:9000 minioadmin minioadmin >/dev/null && mc admin trace --json local" >/dev/null || return 1
  sleep 3
  # 既知のオブジェクトを置いて 1 回 GET し、trace にその GET が出ることを確かめる（「GET 0 件」を判定する前提）。
  local key="athena-results/py/preflight-$RUN_ID.txt"
  docker run --rm --network "$MC_NETWORK" --entrypoint sh "$MC_IMAGE" -c \
    "mc alias set local http://minio:9000 minioadmin minioadmin >/dev/null && echo probe | mc pipe local/$key >/dev/null && mc cat local/$key >/dev/null" || return 1
  sleep 2
  docker logs "$TRACE_CONTAINER" 2>/dev/null | grep -F '"s3.GetObject"' | grep -qF "\"/$key\"" || { log "trace に既知の GET が出ない"; return 1; }
}

run_check() {
  local name="$1" rc fails
  shift
  log "check: $name"
  (cd "$SCRIPT_DIR" && "$@") 2>"$EVIDENCE_DIR/$name.stderr" | tee "$EVIDENCE_DIR/$name.log" | grep -E '^(PASS|FAIL|SKIP|INFO) ' >>"$RESULTS"
  rc=${PIPESTATUS[0]}
  # check の終了コードは FAIL の件数。結果行の FAIL より大きければ、捕まえていない例外で途中で落ちている
  # （結果行が出ないまま合格に見えるのを防ぐ。軽量レビューの指摘）。
  fails=$(grep -c '^FAIL ' "$EVIDENCE_DIR/$name.log")
  if [ "$rc" -gt "$fails" ]; then
    record FAIL "$name 異常終了" "check が rc=$rc で止まった（結果行の FAIL は $fails 件。$EVIDENCE_DIR/$name.stderr）"
  fi
}

summary() {
  echo
  echo "==================== 結果（issue #111 python-clients） ===================="
  if grep -q '^PASS canary' "$RESULTS"; then echo "漏れ: 無し（canary で確認）"; else echo "漏れ: 未確認（canary が PASS していない）"; fi
  # jq は snap 版だと /tmp のファイルを開けないので標準入力で渡す。
  echo "Trino: $(jq -r '.nodeVersion.version // "-"' <"$EVIDENCE_DIR/trino-info.json" 2>/dev/null)"
  grep -iE '^(awswrangler|pyathena|pandas|boto3|botocore)==' "$EVIDENCE_DIR/freeze-wr.txt" 2>/dev/null | tr '\n' ' '; echo
  grep -iE '^(dbt-core|dbt-athena|dbt-adapters|pyathena)==' "$EVIDENCE_DIR/freeze-dbt.txt" 2>/dev/null | tr '\n' ' '; echo
  cat "$RESULTS"
  local s
  for s in PASS FAIL SKIP INFO; do printf '%s=%s ' "$s" "$(grep -c "^$s " "$RESULTS")"; done
  echo
}

main() {
  preflight || { record FAIL preflight "前提が揃わない（上のログ）"; return; }
  start_env || { record SKIP "全項目" "未測定: compose・Trino の準備に失敗"; return; }
  start_athena_local "$ATHENA_S3" s3 s3 && start_athena_local "$ATHENA_NONE" none none \
    || { record SKIP "全項目" "未測定: athena-local が起動しない"; return; }
  local trace_ok=1
  start_proxy_and_trace || trace_ok=0
  source "$SCRIPT_DIR/env.sh"
  run_check canary "$PY_WR" common.py canary
  run_check awswrangler-s3 "$PY_WR" check_awswrangler.py s3
  if [ "$trace_ok" = 1 ]; then
    AWS_ENDPOINT_URL_ATHENA="http://$ATHENA_NONE" run_check awswrangler-none "$PY_WR" check_awswrangler.py none
    run_check pyathena "$PY_WR" check_pyathena.py
  else
    record SKIP "(2) F3・(9)・(3)・(7) PyAthena" "未測定: MinIO の trace に既知の GET が出ない（GET 0 件を判定できない）"
  fi
  run_check dbt bash check_dbt.sh
}

main
summary
exit "$(grep -c '^FAIL ' "$RESULTS")"
