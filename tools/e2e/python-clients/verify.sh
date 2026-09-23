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
# クライアントの向け先は env.sh（AWS_ENDPOINT_URL と _ATHENA → 中継、_S3 → MinIO（minio:9000））。
# MinIO へのアクセスは `mc admin trace --json` を流す使い捨てコンテナで記録し、check ごとの区間だけを数える（common.py）。
#
# 環境はルートの compose.yml の trino / minio / minio-init。開始時に down -v → up -d で作り直す。
# 同じ compose プロジェクトで別の足場（dev）が動いていたら止まる（開始時の down -v が相手の環境を消すため）。
# 前提: tools/dev.sh 経由で動かす（toolbox に全部入っている）。venv（先に ./setup-venvs.sh）、$CARGO_TARGET_DIR（tools/dev.sh では .toolbox/target）の release/athena-local。
# 環境変数: KEEP_UP=1（compose を残す）、SKIP_BUILD=1（cargo build をしない）、VENV_ROOT（既定 $HOME/.cache/athena-local-111）
# 終了コードは FAIL の件数。証跡は /tmp/athena-local-issue111-py.* に残す。
# 落とすのは使ったサービス（trino / minio / minio-init）と、このスクリプトが起動したプロセス・trace コンテナだけ。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# cargo の成果物の置き場。tools/dev.sh は CARGO_TARGET_DIR を .toolbox/target にする
BINARY="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/athena-local"
COMPOSE=(docker compose -f "$REPO_ROOT/compose.yml")
SERVICES=(trino minio minio-init)
# 自分で環境を作り直した（down -v → up -d した）ときだけ後始末で落とす。判定より前に止まった経路で相手の環境を消さない。
COMPOSE_OWNED=0
VENV_ROOT="${VENV_ROOT:-$HOME/.cache/athena-local-111}"
PY_WR="$VENV_ROOT/venv-wr/bin/python"
export DBT_BIN="$VENV_ROOT/venv-dbt/bin/dbt"

TRINO_BASE="http://trino:8080"
export MINIO_ENDPOINT="http://minio:9000"
ATHENA_S3="127.0.0.1:8098"
ATHENA_NONE="127.0.0.1:8099"
export PROXY_BIND="127.0.0.1:8102"
MC_IMAGE="quay.io/minio/mc:latest"
export RUN_ID="$(date +%s)"
# プロジェクト名で分けて同時に流したとき、相手の trace コンテナと名前が衝突しない（後始末で消さない）よう RUN_ID を入れる。
export TRACE_CONTAINER="athena-local-py-trace-$RUN_ID"

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
  if [ "${KEEP_UP:-0}" = "1" ]; then
    log "KEEP_UP=1 のため残す（後で tools/dev.sh docker compose -f compose.yml down -v ${SERVICES[*]}）"
  elif [ "$COMPOSE_OWNED" = "1" ]; then
    "${COMPOSE[@]}" down -v "${SERVICES[@]}" >/dev/null 2>&1
  fi
  log "証跡: $EVIDENCE_DIR"
}
trap cleanup EXIT

preflight() {
  local cmd project others
  for cmd in docker curl jq python3; do
    command -v "$cmd" >/dev/null || { log "$cmd が無い"; return 1; }
  done
  [ -x "$PY_WR" ] && [ -x "$DBT_BIN" ] || { log "venv が無い。先に $SCRIPT_DIR/setup-venvs.sh を流す"; return 1; }
  if [ "${SKIP_BUILD:-0}" != "1" ]; then
    (cd "$REPO_ROOT" && cargo build --release --locked >"$EVIDENCE_DIR/cargo-build.log" 2>&1) || { log "cargo build 失敗"; return 1; }
  fi
  [ -x "$BINARY" ] || { log "$BINARY が無い"; return 1; }
  # 同じプロジェクトに自分以外の dev（別の足場）がいたら止まる（hostname は自分のコンテナ ID の先頭 12 桁）。
  project=$("${COMPOSE[@]}" config --format json 2>/dev/null | jq -r '.name // empty')
  [ -n "$project" ] || { log "compose のプロジェクト名を取れない（docker compose config が失敗した）"; return 1; }
  others=$(docker ps -q --filter "label=com.docker.compose.project=$project" --filter label=com.docker.compose.service=dev | grep -v "^$(hostname)" | wc -l)
  if [ "$others" != "0" ]; then
    log "同じプロジェクト（$project）で別の足場が動いている。COMPOSE_PROJECT_NAME で分けるか、終わるのを待つ"; return 1
  fi
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
  # 前の走行の残骸（テーブル、結果ファイル）を持ち越さないよう、使うサービスを作り直す。
  log "compose down -v / up -d ${SERVICES[*]}"
  COMPOSE_OWNED=1
  "${COMPOSE[@]}" down -v "${SERVICES[@]}" >"$EVIDENCE_DIR/compose-down.log" 2>&1 \
    || { record FAIL "compose起動" "docker compose down -v ${SERVICES[*]} が失敗した（$EVIDENCE_DIR/compose-down.log）"; return 1; }
  "${COMPOSE[@]}" up -d "${SERVICES[@]}" >"$EVIDENCE_DIR/compose-up.log" 2>&1 || { log "compose up 失敗"; return 1; }
  for _ in $(seq 1 120); do trino_exec "SELECT 1" 2>/dev/null && break; sleep 1; done
  trino_exec "SELECT 1" || { log "Trino が起動しない"; return 1; }
  curl -s "$TRINO_BASE/v1/info" >"$EVIDENCE_DIR/trino-info.json"
  trino_exec "CREATE SCHEMA IF NOT EXISTS hive.default" && trino_exec "CREATE SCHEMA IF NOT EXISTS iceberg.default" || return 1
  MC_NETWORK=$(docker inspect "$("${COMPOSE[@]}" ps -q minio)" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null)
  [ -n "$MC_NETWORK" ] || { record FAIL "MinIOネットワーク" "minio のコンテナのネットワークを取れなかった（mc を繋ぐ先が無い）"; return 1; }
  export MC_NETWORK
}

start_athena_local() {
  local bind="$1" mode="$2" name="$3"
  (cd "$REPO_ROOT" && exec env ATHENA_LOCAL_BIND="$bind" TRINO_URL="$TRINO_BASE" TRINO_USER="athena-local-e2e" \
    TRINO_CATALOG=iceberg TRINO_SCHEMA=default TRINO_CATALOG_MAP="awsdatacatalog=iceberg,AwsDataCatalog=iceberg" \
    ATHENA_LOCAL_RESULTS="$mode" AWS_ENDPOINT_URL_S3="$MINIO_ENDPOINT" AWS_ACCESS_KEY_ID=minioadmin \
    AWS_SECRET_ACCESS_KEY=minioadmin ATHENA_LOCAL_OUTPUT_LOCATION="s3://athena-results/py/" \
    "$BINARY") >"$EVIDENCE_DIR/athena-local-$name.log" 2>&1 &
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
  # jq にはファイルを引数でなく標準入力で渡す。
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
    || { record FAIL "全項目" "athena-local が起動しない（athena-local 側の退行。compose と Trino は上がっている）"; return; }
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
