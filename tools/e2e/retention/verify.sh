#!/usr/bin/env bash
# issue #111 で作成（項目 (5)）
# 保持期限（ATHENA_LOCAL_RETENTION_SECONDS）で実行情報を捨てると、長く流したときの athena-local の
# メモリ（VmRSS）が頭打ちになるかを確かめる。同じ負荷を保持 3600 秒（対照）と保持 1 秒で DURATION 秒ずつ
# 流し、load.py --judge が (a)〜(e) を判定する（判定の中身は README.md）。本物の AWS は一切使わない。
#
# compose は新設せず tools/e2e/sdk-retry/docker-compose.yml（Trino 482 + memory カタログ、8095、
# プロジェクト athena-local-issue94-e2e）を流用する。sdk-retry の verify.sh とは同時に流せない。
# athena-local はホスト上の release バイナリを 127.0.0.1:8101 で起動する（結果ファイルは書かない）。
#
# 使い方:
#   tools/e2e/retention/verify.sh
#
# 環境変数:
#   KEEP_UP=1           終了後に docker compose down -v をしない（デバッグ用）
#   SKIP_BUILD=1        cargo build を省略し、ビルド済みの $CARGO_TARGET_DIR（tools/dev.sh では .toolbox/target）の release/athena-local を使う
#   DURATION=240        1 回の負荷の秒数。数時間の推移を見るなら 3600 などにするが、対照側は約 15MiB/秒で伸びて
#                       メモリを使い切るので、ROWS=100 のように 1 件を小さくすること（README の注意）
#   WARMUP=20           判定から外す最初の秒数
#   ROWS=2000           1 クエリの行数（1 行 ≒ 1KiB。1 件 ≒ 2.2MiB の見込み）
#   RETENTION_HIGH=3600 対照側の保持期限（秒）
#   RETENTION_LOW=1     確かめる側の保持期限（秒）
#   JUDGE_*             判定の閾値（load.py の judge を参照。既定は計画の値）
#
# 終了コードは FAIL の件数。後始末は trap が行う（このスクリプトが起動した athena-local と、
# KEEP_UP=1 でなければ athena-local-issue94-e2e プロジェクトだけを落とす）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/../sdk-retry/docker-compose.yml"
# cargo の成果物の置き場。tools/dev.sh は CARGO_TARGET_DIR を .toolbox/target にする
BINARY="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/athena-local"

TRINO_BASE="http://127.0.0.1:8095"
ATHENA_BIND="127.0.0.1:8101"
export DURATION="${DURATION:-240}" WARMUP="${WARMUP:-20}" ROWS="${ROWS:-2000}"
RETENTION_HIGH="${RETENTION_HIGH:-3600}"
RETENTION_LOW="${RETENTION_LOW:-1}"

EVIDENCE_DIR="$(mktemp -d /tmp/athena-local-issue111-retention.XXXXXX)"
ATHENA_PID=""
FAILS=0

cleanup() {
  stop_athena_local
  if [ "${KEEP_UP:-0}" != "1" ]; then
    docker compose -f "$COMPOSE_FILE" down -v >/dev/null 2>&1
  fi
  echo "evidence: $EVIDENCE_DIR"
}
trap cleanup EXIT

stop_athena_local() {
  if [ -n "$ATHENA_PID" ]; then
    kill "$ATHENA_PID" 2>/dev/null
    wait "$ATHENA_PID" 2>/dev/null
    ATHENA_PID=""
  fi
}

# ListWorkGroups が 200 を返すまで待つ。起動しなければ 1 を返す。
wait_athena_local() {
  local code
  for _ in $(seq 1 50); do
    code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://$ATHENA_BIND/" \
      -H 'X-Amz-Target: AmazonAthena.ListWorkGroups' -H 'Content-Type: application/x-amz-json-1.1' -d '{}')"
    [ "$code" = "200" ] && return 0
    kill -0 "$ATHENA_PID" 2>/dev/null || return 1
    sleep 0.2
  done
  return 1
}

# 保持期限 $1 秒で athena-local を起動して負荷を流す。CSV は $EVIDENCE_DIR/load-$1.csv（とその .json）。
run_side() {
  local retention="$1" label="$2"
  local csv="$EVIDENCE_DIR/load-$label.csv"
  echo "== athena-local (retention ${retention}s, $label)"
  ATHENA_LOCAL_BIND="$ATHENA_BIND" TRINO_URL="$TRINO_BASE" TRINO_CATALOG=memory TRINO_SCHEMA=default \
    ATHENA_LOCAL_RESULTS=none ATHENA_LOCAL_RETENTION_SECONDS="$retention" \
    "$BINARY" >"$EVIDENCE_DIR/athena-local-$label.log" 2>&1 &
  ATHENA_PID=$!
  if ! wait_athena_local; then
    echo "FAIL $label: athena-local が起動しない（$EVIDENCE_DIR/athena-local-$label.log）"
    stop_athena_local
    return 1
  fi
  echo "== load (${DURATION}s, warmup ${WARMUP}s, rows $ROWS)"
  python3 "$SCRIPT_DIR/load.py" --base "http://$ATHENA_BIND" --pid "$ATHENA_PID" \
    --retention "$retention" --csv "$csv" | tee "$EVIDENCE_DIR/load-$label.log"
  local status=${PIPESTATUS[0]}
  stop_athena_local
  # 2 は /proc を読めない（判定側で SKIP）。1 は 1 件も SUCCEEDED にならない。
  if [ "$status" = "1" ]; then
    echo "FAIL $label: 負荷が流れない（1 件も SUCCEEDED にならない。$EVIDENCE_DIR/load-$label.log）"
    return 1
  fi
  return 0
}

echo "== build"
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  (cd "$REPO_ROOT" && cargo build --release --locked >"$EVIDENCE_DIR/cargo-build.log" 2>&1) || {
    echo "FAIL cargo build（$EVIDENCE_DIR/cargo-build.log）"; exit 1; }
fi
[ -x "$BINARY" ] || { echo "FAIL $BINARY が無い（SKIP_BUILD=1 ならビルド済みのものが要る）"; exit 1; }

if curl -s -o /dev/null "http://$ATHENA_BIND/" 2>/dev/null; then
  echo "FAIL $ATHENA_BIND が使用中（ほかのプロセスを止めてから流す）"; exit 1
fi

echo "== trino"
docker compose -f "$COMPOSE_FILE" up -d >"$EVIDENCE_DIR/compose-up.log" 2>&1 || {
  echo "FAIL docker compose up（$EVIDENCE_DIR/compose-up.log）"; exit 1; }
for _ in $(seq 1 120); do
  curl -fsS "$TRINO_BASE/v1/info" 2>/dev/null | grep -q '"starting":false' && break
  sleep 1
done
curl -fsS "$TRINO_BASE/v1/info" 2>/dev/null | grep -q '"starting":false' || { echo "FAIL trino が起動しない"; exit 1; }

run_side "$RETENTION_HIGH" high || FAILS=$((FAILS + 1))
run_side "$RETENTION_LOW" low || FAILS=$((FAILS + 1))

echo "== summary"
if [ "$FAILS" = "0" ]; then
  python3 "$SCRIPT_DIR/load.py" --judge "$EVIDENCE_DIR/load-high.csv" "$EVIDENCE_DIR/load-low.csv" \
    | tee "$EVIDENCE_DIR/summary.txt"
  FAILS=$((FAILS + PIPESTATUS[0]))
else
  echo "FAIL retention-memory: 片側が流れなかったので判定しない" | tee "$EVIDENCE_DIR/summary.txt"
fi

echo "== result: $FAILS failed"
exit "$FAILS"
