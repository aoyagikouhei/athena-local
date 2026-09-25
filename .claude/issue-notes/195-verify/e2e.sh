#!/usr/bin/env bash
# #195 の実機検証（Step 9）。release バイナリを本物の Trino（compose の trino、memory カタログ）に向けて起動し、
# 文の判定（分類・ALTER・DESCRIBE・SHOW CREATE・CTAS・語の境界の既存の食い違い）を通るケースを流す。結果ファイルは書かない
# （ATHENA_LOCAL_RESULTS=none。結果ファイル名・Content-Type・.metadata・target_table は tools/e2e/result-content-type/verify.sh と
# tools/e2e/utility-rows/verify.sh で見る）。骨組みは #194 の e2e.sh（PR #198）。
#
# 使い方（toolbox の中で。先に `docker compose -f compose.yml up -d trino`）:
#   tools/dev.sh .claude/issue-notes/195-verify/e2e.sh
#   tools/dev.sh SKIP_BUILD=1 .claude/issue-notes/195-verify/e2e.sh   # 既存の release バイナリを使う（環境変数はコマンドの前に並べる）
#
# 合格の条件: 着手前のバイナリ（76e66f8）と最終のバイナリで全ケースが同じ結果になる（挙動を変えない）。期待値は着手前の値。
# ケース（期待値は athena-local の今の判定。本物の Athena の値ではない）:
#   1  CTAS `CREATE TABLE memory.default.t195 AS SELECT 1 AS a`                    → SUCCEEDED、DDL、CREATE_TABLE_AS_SELECT
#   2  `/* c */ CREATE TABLE memory.default.t195c AS -- c\n(SELECT 1 AS a)`         → SUCCEEDED、DDL、CREATE_TABLE_AS_SELECT（コメントと括弧）
#   3  `CREATE TABLE memory.default.t195v (a) AS (VALUES 1)`                        → DDL、CREATE_TABLE（10-1 の今の値。Trino が受けるかは Z-3。受けなければ 400 を記録）
#   4a `SELECT(1)`、4b `EXPLAIN(TYPE IO) SELECT 1`                                  → UTILITY、SubstatementType 無し（10-2 の今の値。Z-3）
#   5  `( SELECT 1 )`、`sElEcT 1`、`SELECT\t1`、`SELECT\r\n1`                         → DML、SELECT
#   6  `DESCRIBE memory.default.t195`、`desc /* c */ memory . default . t195`         → UTILITY、DESCRIBE_TABLE
#   7  `SHOW CREATE /* c */ TABLE memory.default.t195`                              → UTILITY、SHOW_CREATE_TABLE、GetQueryResults の列名 createtab_stmt
#   8  `SHOW CREATE TABLE"t195"`                                                    → UTILITY、SubstatementType 無し（unmeasured.md:11 の今の値。Z-3）
#   9  `ALTER TABLE memory.default.t195 ADD COLUMN b integer`                       → DDL、ALTER_TABLE_ADD_COLUMN（memory コネクタが受けるかは Z-2。受けなければ FAILED を記録し分類だけ見る）
#   10 `ALTER TABLE "memory" . "default" . t195 RENAME TO t195r`                     → SUCCEEDED、DDL、ALTER_TABLE_RENAME
#   11 D2 の対照 `ALTER TABLE memory.default..t195r ADD COLUMN c integer`、`ALTER TABLE .t ADD COLUMN c integer`
#                                                                                   → StartQueryExecution が 400（MALFORMED_QUERY）で実行を作らない（Z-1）
#   12 `SHOW TABLES FROM memory.default`                                            → UTILITY、SHOW_TABLES、列名 tab_name
#   13 後始末 `DROP TABLE IF EXISTS …`                                              → SUCCEEDED、DDL、DROP_TABLE
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BINARY="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/athena-local"
TRINO_URL="${TRINO_URL:-http://trino:8080}"
ATHENA_BIND="127.0.0.1:8094"
ATHENA_BASE="http://${ATHENA_BIND}"
EVIDENCE_DIR="$(mktemp -d /tmp/athena-local-issue195-e2e.XXXXXX)"
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

ATHENA_LOCAL_BIND="$ATHENA_BIND" TRINO_URL="$TRINO_URL" ATHENA_LOCAL_RESULTS=none "$BINARY" >"$EVIDENCE_DIR/athena-local.log" 2>&1 &
ATHENA_PID=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null "$ATHENA_BASE/" && break
  sleep 0.2
done

athena_call() {
  curl -s -X POST "$ATHENA_BASE/" -H "X-Amz-Target: AmazonAthena.$1" -H "Content-Type: application/x-amz-json-1.1" --data "$2"
}
start_sql() {
  athena_call StartQueryExecution "$(jq -n --arg sql "$1" --arg token "$(uuidgen)" '{QueryString: $sql, QueryExecutionContext: {Catalog: "memory", Database: "default"}, ClientRequestToken: $token}')"
}
# 完了まで待って GetQueryExecution の応答を返す。StartQueryExecution が失敗したら {} を返す。
run_sql() {
  local sql="$1" id resp state
  resp=$(start_sql "$sql")
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
# 分類の 3 つ組（状態・StatementType・SubstatementType）を 1 行で比べる。SubstatementType が無ければ「-」。
classify() {
  local label="$1" sql="$2" expect="$3" r
  r=$(run_sql "$sql"); echo "$r" >"$EVIDENCE_DIR/$label.json"
  check "$label $(printf '%q' "$sql")" "$(echo "$r" | jq -r '[.QueryExecution.Status.State, .QueryExecution.StatementType, (.QueryExecution.SubstatementType // "-")] | join(" ")')" "$expect"
}
first_column() {
  local label="$1" id
  id=$(jq -r '.QueryExecution.QueryExecutionId' "$EVIDENCE_DIR/$label.json")
  athena_call GetQueryResults "$(jq -n --arg id "$id" '{QueryExecutionId: $id}')" | tee "$EVIDENCE_DIR/$label-results.json" | jq -r '.ResultSet.ResultSetMetadata.ColumnInfo[0].Name'
}

classify 1 'CREATE TABLE memory.default.t195 AS SELECT 1 AS a' 'SUCCEEDED DDL CREATE_TABLE_AS_SELECT'
classify 2 $'/* c */ CREATE TABLE memory.default.t195c AS -- c\n(SELECT 1 AS a)' 'SUCCEEDED DDL CREATE_TABLE_AS_SELECT'
# 3 は Trino が受けるかが未検証（Z-3）。受けなければ StartQueryExecution が失敗して {} になるので、その事実を記録する。
r=$(run_sql 'CREATE TABLE memory.default.t195v (a) AS (VALUES 1)'); echo "$r" >"$EVIDENCE_DIR/3.json"
if [ "$r" = '{}' ]; then echo "INFO 3 CREATE TABLE ... AS (VALUES 1) は Trino が受けない（400）: $(tail -1 "$EVIDENCE_DIR/start.jsonl" | jq -c .)"
else check "3 CTAS AS (VALUES 1) は今の判定では CREATE_TABLE（10-1）" "$(echo "$r" | jq -r '[.QueryExecution.Status.State, .QueryExecution.StatementType, (.QueryExecution.SubstatementType // "-")] | join(" ")')" 'SUCCEEDED DDL CREATE_TABLE'; fi
classify 4a 'SELECT(1)' 'SUCCEEDED UTILITY -'
classify 4b 'EXPLAIN(TYPE IO) SELECT 1' 'SUCCEEDED UTILITY -'
classify 5a '( SELECT 1 )' 'SUCCEEDED DML SELECT'
classify 5b 'sElEcT 1' 'SUCCEEDED DML SELECT'
classify 5c $'SELECT\t1' 'SUCCEEDED DML SELECT'
classify 5d $'SELECT\r\n1' 'SUCCEEDED DML SELECT'
classify 6a 'DESCRIBE memory.default.t195' 'SUCCEEDED UTILITY DESCRIBE_TABLE'
classify 6b 'desc /* c */ memory . default . t195' 'SUCCEEDED UTILITY DESCRIBE_TABLE'
classify 7 'SHOW CREATE /* c */ TABLE memory.default.t195' 'SUCCEEDED UTILITY SHOW_CREATE_TABLE'
check "7 GetQueryResults の列名" "$(first_column 7)" createtab_stmt
classify 8 'SHOW CREATE TABLE"t195"' 'SUCCEEDED UTILITY -'
# 9 は memory コネクタが ADD COLUMN を受けるかが未検証（Z-2）。分類は実行の成否によらないので、状態は記録だけにして分類を比べる。
r=$(run_sql 'ALTER TABLE memory.default.t195 ADD COLUMN b integer'); echo "$r" >"$EVIDENCE_DIR/9.json"
echo "INFO 9 ALTER TABLE ADD COLUMN の状態: $(echo "$r" | jq -r '.QueryExecution.Status.State') $(echo "$r" | jq -r '.QueryExecution.Status.StateChangeReason // ""' | head -c 120)"
check "9 ALTER TABLE ADD COLUMN の分類" "$(echo "$r" | jq -r '[.QueryExecution.StatementType, (.QueryExecution.SubstatementType // "-")] | join(" ")')" 'DDL ALTER_TABLE_ADD_COLUMN'
classify 10 'ALTER TABLE "memory" . "default" . t195 RENAME TO t195r' 'SUCCEEDED DDL ALTER_TABLE_RENAME'
# 11 D2 の対照: 空の名前部分は Trino が構文エラーにし、StartQueryExecution が 400 で実行を作らない（Z-1）。
for sql in 'ALTER TABLE memory.default..t195r ADD COLUMN c integer' 'ALTER TABLE .t ADD COLUMN c integer'; do
  resp=$(start_sql "$sql"); echo "$resp" >>"$EVIDENCE_DIR/11.jsonl"
  check "11 $(printf '%q' "$sql")" "$(echo "$resp" | jq -r '[(.__type // "-"), (.AthenaErrorCode // "-"), (if .QueryExecutionId then "実行あり" else "実行なし" end)] | join(" ")')" 'InvalidRequestException MALFORMED_QUERY 実行なし'
done
classify 12 'SHOW TABLES FROM memory.default' 'SUCCEEDED UTILITY SHOW_TABLES'
check "12 GetQueryResults の列名" "$(first_column 12)" tab_name
classify 13a 'DROP TABLE IF EXISTS memory.default.t195r' 'SUCCEEDED DDL DROP_TABLE'
classify 13b 'DROP TABLE IF EXISTS memory.default.t195c' 'SUCCEEDED DDL DROP_TABLE'
classify 13c 'DROP TABLE IF EXISTS memory.default.t195v' 'SUCCEEDED DDL DROP_TABLE'

log "証跡: $EVIDENCE_DIR"
if [ "$fail" -eq 0 ]; then echo "すべて PASS"; else echo "FAIL あり"; fi
exit "$fail"
