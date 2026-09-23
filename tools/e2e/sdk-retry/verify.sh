#!/usr/bin/env bash
# issue #94 で作成
# issue #94 の実機検証: 本物の Trino（trinodb/trino:482）を相手に athena-local の release バイナリを
# 動かし、(1) boto3 のリトライを応答を落とす代理で誘発して同じ ClientRequestToken の再送が
# INSERT を 2 回実行しないこと、(2) 同じトークンの 50 並列の同時送信で QueryExecutionId が
# 1 つになり詰まらないこと、を確かめる。本物の AWS は一切使わない。結果ファイルは書かない。
#
# 前提コマンド: tools/dev.sh 経由で動かす（toolbox に全部入っている。boto3 は toolbox の python3 に入っている）
# 環境はルートの compose.yml の trino（memory カタログで INSERT の副作用を数える）。開始時に down -v → up -d で作り直す。
# athena-local と応答を落とす代理は dev の中のプロセス（127.0.0.1:8091 と 8096）。
#
# 使い方:
#   tools/dev.sh tools/e2e/sdk-retry/verify.sh
#
# 環境変数:
#   KEEP_UP=1        テスト後に docker compose down -v <サービス...> をせず環境を残す（デバッグ用）
#   SKIP_BUILD=1     cargo build を省略し、既存の $CARGO_TARGET_DIR（tools/dev.sh では .toolbox/target）の release/athena-local をそのまま使う
#   PYTHON=...       boto3 入りの python3（既定は python3）
#   DROP_COUNT=2     代理が落とす応答の回数
#
# 後始末は trap が行う（KEEP_UP=1 でなければ必ず docker compose down -v する）。
# 落とすのは使ったサービス（trino）と、このスクリプトが起動した athena-local と代理のプロセスだけ。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# cargo の成果物の置き場。tools/dev.sh は CARGO_TARGET_DIR を .toolbox/target にする
BINARY="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/athena-local"
COMPOSE=(docker compose -f "$REPO_ROOT/compose.yml")
SERVICES=(trino)

TRINO_BASE="http://trino:8080"
ATHENA_BIND="127.0.0.1:8091"
PROXY_BIND="127.0.0.1:8096"
DROP_COUNT="${DROP_COUNT:-2}"
PYTHON="${PYTHON:-python3}"
$PYTHON -c "import boto3" 2>/dev/null || {
  echo "boto3 が要る（$PYTHON で import できない）。tools/dev.sh 経由で動かすか、boto3 入りの python3 を PYTHON に指定する"; exit 1; }

EVIDENCE_DIR="$(mktemp -d /tmp/athena-local-issue94-e2e.XXXXXX)"
ATHENA_LOG="$EVIDENCE_DIR/athena-local.log"
PROXY_LOG="$EVIDENCE_DIR/proxy.log"
CHECK_LOG="$EVIDENCE_DIR/check.log"

ATHENA_PID=""
PROXY_PID=""

cleanup() {
  [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null
  [ -n "$ATHENA_PID" ] && kill "$ATHENA_PID" 2>/dev/null
  if [ "${KEEP_UP:-0}" != "1" ]; then
    "${COMPOSE[@]}" down -v "${SERVICES[@]}" >/dev/null 2>&1
  else
    echo "KEEP_UP=1 のため残す（後で tools/dev.sh docker compose -f compose.yml down -v ${SERVICES[*]}）"
  fi
  echo "evidence: $EVIDENCE_DIR"
}
trap cleanup EXIT

echo "== build"
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  (cd "$REPO_ROOT" && cargo build --release --locked >"$EVIDENCE_DIR/cargo-build.log" 2>&1) || {
    echo "cargo build failed: $EVIDENCE_DIR/cargo-build.log"; exit 1; }
fi
[ -x "$BINARY" ] || { echo "$BINARY が無い（SKIP_BUILD=1 ならビルド済みのものが要る）"; exit 1; }

echo "== trino"
# 前の走行の memory.default.t94 と system.runtime.queries の目印を持ち越さないよう、Trino を作り直す。
"${COMPOSE[@]}" down -v "${SERVICES[@]}" >/dev/null 2>&1 || { echo "docker compose down -v ${SERVICES[*]} failed"; exit 1; }
"${COMPOSE[@]}" up -d "${SERVICES[@]}" >/dev/null 2>&1 || { echo "docker compose up failed"; exit 1; }
for _ in $(seq 1 120); do
  if curl -fsS "$TRINO_BASE/v1/info" 2>/dev/null | grep -q '"starting":false'; then break; fi
  sleep 1
done
curl -fsS "$TRINO_BASE/v1/info" | grep -q '"starting":false' || { echo "trino did not start"; exit 1; }

echo "== athena-local"
ATHENA_LOCAL_BIND="$ATHENA_BIND" TRINO_URL="$TRINO_BASE" TRINO_CATALOG=memory TRINO_SCHEMA=default \
  ATHENA_LOCAL_RESULTS=none "$BINARY" >"$ATHENA_LOG" 2>&1 &
ATHENA_PID=$!
for _ in $(seq 1 30); do
  if curl -s -o /dev/null "http://$ATHENA_BIND/" 2>/dev/null; then break; fi
  sleep 0.2
done

echo "== proxy (drops the first $DROP_COUNT responses to the marked StartQueryExecution)"
LISTEN="$PROXY_BIND" UPSTREAM="$ATHENA_BIND" DROP_COUNT="$DROP_COUNT" \
  python3 "$SCRIPT_DIR/drop_proxy.py" 2>"$PROXY_LOG" &
PROXY_PID=$!
sleep 0.5

echo "== check"
(cd "$SCRIPT_DIR" && ATHENA_DIRECT="http://$ATHENA_BIND" PROXY="http://$PROXY_BIND" TRINO="$TRINO_BASE" \
  $PYTHON check.py) 2>&1 | tee "$CHECK_LOG"
CHECK_STATUS=${PIPESTATUS[0]}

echo "== proxy log"
cat "$PROXY_LOG"
# 落とした試行と、その後に通った試行のトークンが同じであること（SDK が同じトークンで再送した証拠）。
TOKENS="$(grep -E 'proxy: (drop|relay) target=AmazonAthena.StartQueryExecution' "$PROXY_LOG" | head -$((DROP_COUNT + 1)) | sed -n 's/.*token=//p' | sort -u | wc -l)"
DROPS="$(grep -c 'proxy: drop' "$PROXY_LOG")"
if [ "$DROPS" = "$DROP_COUNT" ] && [ "$TOKENS" = "1" ]; then
  echo "PASS proxy: $DROPS responses dropped and the SDK resent the same ClientRequestToken"
else
  echo "FAIL proxy: drops=$DROPS (expected $DROP_COUNT), distinct tokens in first $((DROP_COUNT + 1)) attempts=$TOKENS (expected 1)"
  CHECK_STATUS=$((CHECK_STATUS + 1))
fi

echo "== result: $CHECK_STATUS failed"
exit "$CHECK_STATUS"
