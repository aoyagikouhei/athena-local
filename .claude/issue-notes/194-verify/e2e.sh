#!/usr/bin/env bash
# #194 の実機検証（Step 9）。release バイナリを本物の Trino（compose の trino、memory カタログ）に向けて起動し、
# crate へ移した字句処理を通る最小のケースを流す。結果ファイルは書かない（ATHENA_LOCAL_RESULTS=none）。
#
# 使い方（toolbox の中で。先に `docker compose -f compose.yml up -d trino`）:
#   tools/dev.sh .claude/issue-notes/194-verify/e2e.sh
#   SKIP_BUILD=1 tools/dev.sh .claude/issue-notes/194-verify/e2e.sh   # 既存の release バイナリを使う
#
# ケース（通る関数は移動後の crate 側。移動前のツリーで流しても全部 PASS になるのが正しい = 挙動を変えない）:
#   1 CTAS `CREATE TABLE memory.default.t194 AS SELECT 1 AS a`      → SUCCEEDED（準備。分類の words を通るが判定結果は見ない）
#   2 `/* c */ SELECT a FROM "s3tablescatalog/x" /* c */ . default.t194 -- x` with TRINO_CATALOG_MAP=s3tablescatalog/x=memory
#                                                                    → SUCCEEDED、StatementType DML、SubstatementType SELECT、結果 1 行 "1"
#                                                                      （alias_qualified_names → skip_quoted / unquote / comment_end / skip_trivia、分類 → words）
#   3 `ALTER TABLE memory.default.t194 RENAME TO t194b`              → SUCCEEDED、SubstatementType ALTER_TABLE_RENAME（skip_keyword / skip_leading_trivia / skip_qualified_name）
#   2-対照 別名マップ無しの athena-local（8095）に同じ SELECT（t194b）→ SUCCEEDED にならない（検証が別名の置換を通っている証拠）
#   4 `DROP TABLE memory.default.t194b`                              → SUCCEEDED（後始末。ATHENA_LOCAL_RESULTS=none では形式の問い合わせが走らず target_table は通らない。
#                                                                      target_table の経路は tools/e2e/result-content-type/verify.sh の SHOW CREATE TABLE で見る。計画レビュー 4-2）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BINARY="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/athena-local"
TRINO_URL="${TRINO_URL:-http://trino:8080}"
ATHENA_BIND="127.0.0.1:8094"
ATHENA_BASE="http://${ATHENA_BIND}"
EVIDENCE_DIR="$(mktemp -d /tmp/athena-local-issue194-e2e.XXXXXX)"
ATHENA_PID=""
fail=0

log() { echo "[e2e] $*" >&2; }
cleanup() { if [ -n "$ATHENA_PID" ]; then kill "$ATHENA_PID" 2>/dev/null; wait "$ATHENA_PID" 2>/dev/null; fi; }
trap cleanup EXIT

if [ "${SKIP_BUILD:-0}" != 1 ]; then
  log "cargo build --release --locked"
  (cd "$REPO_ROOT" && cargo build --release --locked >"$EVIDENCE_DIR/cargo-build.log" 2>&1) || { log "build failed: $EVIDENCE_DIR/cargo-build.log"; exit 1; }
fi

# Trino が起動直後だと構文チェック（PREPARE）が落ちて StartQueryExecution が失敗するので、/v1/info の starting が false になるまで待つ。
for _ in $(seq 1 120); do
  [ "$(curl -s "$TRINO_URL/v1/info" | jq -r '.starting // "true"')" = false ] && break
  sleep 1
done
log "trino: $(curl -s "$TRINO_URL/v1/info" | jq -c '{starting, nodeVersion}')"

ATHENA_LOCAL_BIND="$ATHENA_BIND" TRINO_URL="$TRINO_URL" ATHENA_LOCAL_RESULTS=none \
  TRINO_CATALOG_MAP="s3tablescatalog/x=memory" \
  "$BINARY" >"$EVIDENCE_DIR/athena-local.log" 2>&1 &
ATHENA_PID=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null "$ATHENA_BASE/" && break
  sleep 0.2
done

athena_call() {
  curl -s -X POST "$ATHENA_BASE/" -H "X-Amz-Target: AmazonAthena.$1" -H "Content-Type: application/x-amz-json-1.1" --data "$2"
}
run_sql() {
  local sql="$1" id resp
  resp=$(athena_call StartQueryExecution "$(jq -n --arg sql "$sql" --arg token "$(uuidgen)" '{QueryString: $sql, QueryExecutionContext: {Catalog: "memory", Database: "default"}, ClientRequestToken: $token}')")
  echo "$resp" >>"$EVIDENCE_DIR/start.jsonl"
  id=$(echo "$resp" | jq -r '.QueryExecutionId // empty')
  [ -n "$id" ] || { log "StartQueryExecution failed: $resp"; echo '{}'; return 1; }
  for _ in $(seq 1 100); do
    resp=$(athena_call GetQueryExecution "$(jq -n --arg id "$id" '{QueryExecutionId: $id}')")
    state=$(echo "$resp" | jq -r '.QueryExecution.Status.State // empty')
    [ "$state" = QUEUED ] || [ "$state" = RUNNING ] || { echo "$resp"; return 0; }
    sleep 0.3
  done
  echo "$resp"; return 1
}
check() { if [ "$2" = "$3" ]; then echo "PASS $1: $2"; else echo "FAIL $1: 実際「$2」 期待「$3」"; fail=1; fi; }

r=$(run_sql 'CREATE TABLE memory.default.t194 AS SELECT 1 AS a'); echo "$r" >"$EVIDENCE_DIR/1.json"
check "1 CTAS の状態" "$(echo "$r" | jq -r '.QueryExecution.Status.State')" SUCCEEDED

r=$(run_sql $'/* c */ SELECT a FROM "s3tablescatalog/x" /* c */ . default.t194 -- x'); echo "$r" >"$EVIDENCE_DIR/2.json"
check "2 別名付き SELECT の状態" "$(echo "$r" | jq -r '.QueryExecution.Status.State')" SUCCEEDED
check "2 StatementType" "$(echo "$r" | jq -r '.QueryExecution.StatementType')" DML
check "2 SubstatementType" "$(echo "$r" | jq -r '.QueryExecution.SubstatementType')" SELECT
check "2 Query は受け取ったまま" "$(echo "$r" | jq -r '.QueryExecution.Query')" $'/* c */ SELECT a FROM "s3tablescatalog/x" /* c */ . default.t194 -- x'
id=$(echo "$r" | jq -r '.QueryExecution.QueryExecutionId')
rows=$(athena_call GetQueryResults "$(jq -n --arg id "$id" '{QueryExecutionId: $id}')" | tee "$EVIDENCE_DIR/2-results.json" | jq -c '[.ResultSet.Rows[].Data[0].VarCharValue]')
check "2 結果の行（列名行 + 1 行）" "$rows" '["a","1"]'

r=$(run_sql 'ALTER TABLE memory.default.t194 RENAME TO t194b'); echo "$r" >"$EVIDENCE_DIR/3.json"
check "3 ALTER TABLE RENAME の状態" "$(echo "$r" | jq -r '.QueryExecution.Status.State')" SUCCEEDED
check "3 SubstatementType" "$(echo "$r" | jq -r '.QueryExecution.SubstatementType')" ALTER_TABLE_RENAME

# 対照: 別名マップ無しの 2 本目の athena-local に同じ SELECT を投げると成功しない（検証が別名の置換を実際に通っている証拠）。
ATHENA_LOCAL_BIND="127.0.0.1:8095" TRINO_URL="$TRINO_URL" ATHENA_LOCAL_RESULTS=none "$BINARY" >"$EVIDENCE_DIR/athena-local-control.log" 2>&1 &
CONTROL_PID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:8095/" && break; sleep 0.2; done
r=$(ATHENA_BASE="http://127.0.0.1:8095" run_sql $'/* c */ SELECT a FROM "s3tablescatalog/x" /* c */ . default.t194b -- x'); echo "$r" >"$EVIDENCE_DIR/2-control.json"
kill "$CONTROL_PID" 2>/dev/null; wait "$CONTROL_PID" 2>/dev/null
state=$(echo "$r" | jq -r '.QueryExecution.Status.State // "（StartQueryExecution が失敗）"')
if [ "$state" != SUCCEEDED ]; then echo "PASS 2-対照 別名マップ無しでは成功しない: $state"; else echo "FAIL 2-対照 別名マップ無しでも SUCCEEDED"; fail=1; fi

r=$(run_sql 'DROP TABLE memory.default.t194b'); echo "$r" >"$EVIDENCE_DIR/4.json"
check "4 DROP TABLE の状態" "$(echo "$r" | jq -r '.QueryExecution.Status.State')" SUCCEEDED

log "証跡: $EVIDENCE_DIR"
if [ "$fail" -eq 0 ]; then echo "すべて PASS"; else echo "FAIL あり"; fi
exit "$fail"
