#!/usr/bin/env bash
# issue #200 の実機検証の足場。
#
# 語の境界の判定が words 系（空白とコメントだけで切る）と Cursor 系（識別子の文字以外を境界にする）の
# 2 系統に割れているため、キーワードの直後に空白が無い SQL（`SELECT(1)` など）の分類が、空白ありの
# 対照（`SELECT (1)`）と athena-local の中で食い違っている疑いがある（#200 本文、.claude/issue-notes/200.md）。
# 本物の Trino（compose の trino、memory カタログ）と本物の S3 互換ストレージ（MinIO）を相手に athena-local を
# 動かし、空白なしの形と対照を両方 StartQueryExecution で投げて、State・StatementType・SubstatementType・
# OutputLocation の末尾の形（`.csv`／`.txt`／`tables/<id>`／`<id>`）・結果本体の Content-Type（MinIO に置かれた
# もの）・EXPLAIN は GetQueryResults の行数を 1 行ずつ表にする。
#
# 雛形: `git show 58780f9:.claude/issue-notes/195-verify/e2e.sh`（#195 の同種の足場）。
#
# 前提: tools/dev.sh 経由で toolbox の中で動かす（`aws` は使わず、S3 は toolbox の mc で minio:9000 を直接見る）。
# 環境はルートの compose.yml の trino / minio / minio-init。開始時に使うサービスだけ down -v → up -d で作り直す。
# 既定の compose プロジェクト（trino が既に立っている場合がある）を落とさない・作り直さないよう、
# 呼び出し側でプロジェクト名を専用のものに分けること:
#   COMPOSE_PROJECT_NAME=athena200 tools/dev.sh .claude/issue-notes/200-verify/e2e.sh
#
# 環境変数:
#   KEEP_UP=1        終了時に docker compose down -v <サービス...> をせず環境を残す（デバッグ用）
#   SKIP_BUILD=1     cargo build を省略し、既存の $CARGO_TARGET_DIR（tools/dev.sh では .toolbox/target）の
#                    release/athena-local をそのまま使う
#   EXPECT=after     空白なしの形が対照（空白あり）と同じ StatementType／SubstatementType／拡張子／
#                    Content-Type になっていることを照合し、ラベルごとに PASS/FAIL を追加で出す。
#                    省略時（既定）は測った値をそのまま表にするだけで、合否は付けない。
#
# 終了コード: EXPECT=after のとき FAIL の件数（0 なら全 PASS）。それ以外は StartQueryExecution 自体が
# 失敗したケースがあれば 1、無ければ 0。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BINARY="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/athena-local"
COMPOSE=(docker compose -f "$REPO_ROOT/compose.yml")
SERVICES=(trino minio minio-init)

TRINO_BASE="http://trino:8080"
MINIO_ENDPOINT="http://minio:9000"
ATHENA_BASE="http://127.0.0.1:8096"
BUCKET="athena-results"
PREFIX="e2e200"
OUTPUT_LOCATION="s3://${BUCKET}/${PREFIX}/"
CATALOG="memory"
DATABASE="default"
EXPECT="${EXPECT:-raw}"

EVIDENCE_DIR="$(mktemp -d /tmp/athena-local-issue200-e2e.XXXXXX)"
ATHENA_LOG="$EVIDENCE_DIR/athena-local.log"
BUILD_LOG="$EVIDENCE_DIR/cargo-build.log"

ATHENA_PID=""

# --- 結果の記録（列を横に増やせるよう、ラベルをキーに連想配列へ持つ） ---
declare -a LABELS=()
declare -A SQLS=() STATES=() STMTS=() SUBSTMTS=() EXTS=() CTS=() ROWSV=() JUDGE=()

log() { echo "[e2e200] $*" >&2; }

idx_of() {
  local target="$1" i
  for i in "${!LABELS[@]}"; do
    [ "${LABELS[$i]}" = "$target" ] && { echo "$i"; return 0; }
  done
  return 1
}

print_table() {
  echo
  echo "==================== 結果（issue #200） ===================="
  if [ "$EXPECT" = after ]; then
    printf "%-4s %-8s %-42s %-12s %-26s %-11s %-24s %-6s %-6s\n" \
      "#" "State" "SQL" "Statement" "Substatement" "拡張子" "Content-Type" "Rows" "判定"
  else
    printf "%-4s %-8s %-42s %-12s %-26s %-11s %-24s %-6s\n" \
      "#" "State" "SQL" "Statement" "Substatement" "拡張子" "Content-Type" "Rows"
  fi
  local label
  for label in "${LABELS[@]}"; do
    if [ "$EXPECT" = after ]; then
      printf "%-4s %-8s %-42s %-12s %-26s %-11s %-24s %-6s %-6s\n" \
        "$label" "${STATES[$label]}" "${SQLS[$label]}" "${STMTS[$label]}" "${SUBSTMTS[$label]}" \
        "${EXTS[$label]}" "${CTS[$label]}" "${ROWSV[$label]}" "${JUDGE[$label]:--}"
    else
      printf "%-4s %-8s %-42s %-12s %-26s %-11s %-24s %-6s\n" \
        "$label" "${STATES[$label]}" "${SQLS[$label]}" "${STMTS[$label]}" "${SUBSTMTS[$label]}" \
        "${EXTS[$label]}" "${CTS[$label]}" "${ROWSV[$label]}"
    fi
  done
  echo "=============================================================="
  log "証跡（応答 JSON・athena-local のログ・ビルドログ）: $EVIDENCE_DIR"
}

cleanup() {
  local status=$?
  if [ -n "$ATHENA_PID" ] && kill -0 "$ATHENA_PID" 2>/dev/null; then
    log "athena-local (PID $ATHENA_PID) を止める"
    kill "$ATHENA_PID" 2>/dev/null || true
    wait "$ATHENA_PID" 2>/dev/null || true
  fi
  if [ "${KEEP_UP:-0}" = "1" ]; then
    log "KEEP_UP=1 のため docker compose はそのまま残す（後で tools/dev.sh docker compose -f $REPO_ROOT/compose.yml down -v ${SERVICES[*]}）"
  else
    log "docker compose down -v ${SERVICES[*]}（使ったサービスだけ）"
    "${COMPOSE[@]}" down -v "${SERVICES[@]}" >/dev/null 2>&1
  fi
  print_table
  exit "$status"
}
trap cleanup EXIT

# --- Trino への直接アクセス（テーブル／ビューの準備・後始末専用。測定対象の文は athena-local 経由で投げる） ---

trino_exec() {
  local sql="$1" catalog="$2" schema="$3"
  local resp next
  resp=$(curl -sf -X POST "$TRINO_BASE/v1/statement" \
    -H "X-Trino-User: e2e200-setup" \
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
    [ -z "$next" ] && break
    resp=$(curl -sf "$next")
  done
  return 0
}

wait_for_trino() {
  log "Trino の起動待ち ($TRINO_BASE)"
  for _ in $(seq 1 90); do
    trino_exec "SELECT 1" system runtime >/dev/null 2>&1 && { log "Trino 起動確認"; return 0; }
    sleep 2
  done
  log "Trino が起動しなかった"
  return 1
}

wait_for_bucket() {
  log "MinIO バケットの用意待ち"
  for _ in $(seq 1 60); do
    mc ls "local/$BUCKET" >/dev/null 2>&1 && { log "バケット確認: $BUCKET"; return 0; }
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
  log "ビルド失敗。ログ末尾 40 行:"
  tail -n 40 "$BUILD_LOG" >&2
  return 1
}

start_athena_local() {
  log "athena-local を起動する ($ATHENA_BASE)"
  (
    cd "$REPO_ROOT"
    exec env \
      ATHENA_LOCAL_BIND="127.0.0.1:8096" \
      TRINO_URL="$TRINO_BASE" \
      TRINO_USER="athena-local-e2e200" \
      TRINO_CATALOG="$CATALOG" \
      TRINO_SCHEMA="$DATABASE" \
      ATHENA_LOCAL_RESULTS="s3" \
      AWS_ENDPOINT_URL_S3="$MINIO_ENDPOINT" \
      AWS_ACCESS_KEY_ID="minioadmin" \
      AWS_SECRET_ACCESS_KEY="minioadmin" \
      ATHENA_LOCAL_OUTPUT_LOCATION="$OUTPUT_LOCATION" \
      "$BINARY"
  ) >"$ATHENA_LOG" 2>&1 &
  ATHENA_PID=$!
  for _ in $(seq 1 30); do
    if ! kill -0 "$ATHENA_PID" 2>/dev/null; then
      log "athena-local が異常終了した。ログ:"
      cat "$ATHENA_LOG" >&2
      return 1
    fi
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ATHENA_BASE/" \
      -H "X-Amz-Target: AmazonAthena.ListWorkGroups" -H "Content-Type: application/x-amz-json-1.1" --data '{}')
    [ "$status" = "200" ] && { log "athena-local 起動確認"; return 0; }
    sleep 1
  done
  log "athena-local が応答しなかった"
  return 1
}

# --- athena-local の Athena API 呼び出し ---

athena_call() {
  curl -s -X POST "$ATHENA_BASE/" -H "X-Amz-Target: AmazonAthena.$1" \
    -H "Content-Type: application/x-amz-json-1.1" --data "$2"
}

athena_start_query() {
  local sql="$1" body resp
  body=$(jq -n --arg sql "$sql" --arg catalog "$CATALOG" --arg db "$DATABASE" --arg token "$(uuidgen)" \
    '{QueryString: $sql, QueryExecutionContext: {Catalog: $catalog, Database: $db}, ClientRequestToken: $token}')
  resp=$(athena_call StartQueryExecution "$body")
  echo "$resp" | jq -r '.QueryExecutionId // empty'
}

athena_wait() {
  local id="$1" resp state
  for _ in $(seq 1 100); do
    resp=$(athena_call GetQueryExecution "$(jq -n --arg id "$id" '{QueryExecutionId: $id}')")
    state=$(echo "$resp" | jq -r '.QueryExecution.Status.State // empty')
    [ "$state" = QUEUED ] || [ "$state" = RUNNING ] || { echo "$resp"; return 0; }
    sleep 0.3
  done
  echo "$resp"
}

# --- MinIO 側の確認（mc で minio:9000 を直接見る。#129） ---
# mc stat はキーを前方一致でも拾う（`<id>.txt` が `<id>.txt.metadata` も拾ってしまう）ので、
# name フィールドで厳密に絞り込む（tools/e2e/minio/lib.sh の mc_stat と同じ回避策）。
mc_stat() {
  local key="$1" name raw
  name=$(basename "$key")
  raw=$(mc stat --json "local/$BUCKET/$key" 2>/dev/null)
  [ -z "$raw" ] && { echo '{"status":"error"}'; return; }
  echo "$raw" | jq -s --arg name "$name" '
    map(select(.name == $name and (.status // "success") == "success"))
    | if length > 0 then .[0] else {"status":"error"} end'
}
mc_exists() { [ -n "$1" ] && ! echo "$1" | jq -e '.status == "error"' >/dev/null 2>&1; }

# --- 1 ケースぶんの計測 ---

# OutputLocation の末尾から拡張子の形を分類する（results.rs の ResultFile::path と対応）。
classify_ext() {
  local loc="$1" base dir
  [ "$loc" = "-" ] || [ -z "$loc" ] && { echo "-"; return; }
  base=$(basename "$loc")
  dir=$(dirname "$loc")
  case "$base" in
    *.csv) echo "csv" ;;
    *.txt) echo "txt" ;;
    *)
      if [ "$(basename "$dir")" = "tables" ]; then echo "tables/<id>"; else echo "<id>"; fi
      ;;
  esac
}

content_type_of() {
  local loc="$1" key stat_json
  { [ "$loc" = "-" ] || [ -z "$loc" ]; } && { echo "-"; return; }
  key="${loc#s3://${BUCKET}/}"
  stat_json=$(mc_stat "$key")
  if ! mc_exists "$stat_json"; then echo "(本体無し)"; return; fi
  echo "$stat_json" | jq -r '.metadata["Content-Type"] // "-"'
}

row_count_of() {
  local id="$1" resp
  resp=$(athena_call GetQueryResults "$(jq -n --arg id "$id" '{QueryExecutionId: $id}')")
  echo "$resp" | jq -r 'if .ResultSet then (.ResultSet.Rows | length) else "-" end' 2>/dev/null || echo "-"
}

# StartQueryExecution → 完了待ち → 表に積む。
run_case() {
  local label="$1" sql="$2"
  local id resp state stmt substmt outloc
  LABELS+=("$label")
  SQLS[$label]="$sql"
  id=$(athena_start_query "$sql")
  if [ -z "$id" ]; then
    log "label=$label StartQueryExecution が QueryExecutionId を返さなかった: $sql"
    STATES[$label]="START失敗"; STMTS[$label]="-"; SUBSTMTS[$label]="-"
    EXTS[$label]="-"; CTS[$label]="-"; ROWSV[$label]="-"
    return
  fi
  resp=$(athena_wait "$id")
  echo "$resp" >"$EVIDENCE_DIR/$label.json"
  state=$(echo "$resp" | jq -r '.QueryExecution.Status.State // "?"')
  stmt=$(echo "$resp" | jq -r '.QueryExecution.StatementType // "-"')
  substmt=$(echo "$resp" | jq -r '.QueryExecution.SubstatementType // "-"')
  outloc=$(echo "$resp" | jq -r '.QueryExecution.ResultConfiguration.OutputLocation // "-"')
  STATES[$label]="$state"
  STMTS[$label]="$stmt"
  SUBSTMTS[$label]="$substmt"
  EXTS[$label]="$(classify_ext "$outloc")"
  CTS[$label]="$(content_type_of "$outloc")"
  ROWSV[$label]="$(row_count_of "$id")"
}

# --- 空白なし／空白ありの対のラベル（EXPECT=after の照合に使う。d2b は対照が無いので含めない） ---
PAIRS=(
  "s1 s1c" "s2 s2c" "s3 s3c" "s4 s4c" "s5 s5c" "s6 s6c"
  "e1 e1c" "e2 e2c"
  "u1 u1c" "u2 u2c" "u3 u3c"
  "d1 d1c" "d2 d2c" "d3 d3c"
  "v1 v1c" "v2 v2c" "v3 v3c"
)

judge_after() {
  local pair base ctr
  for pair in "${PAIRS[@]}"; do
    read -r base ctr <<<"$pair"
    if [ "${STMTS[$base]:-}" = "${STMTS[$ctr]:-}" ] && [ "${SUBSTMTS[$base]:-}" = "${SUBSTMTS[$ctr]:-}" ] &&
      [ "${EXTS[$base]:-}" = "${EXTS[$ctr]:-}" ] && [ "${CTS[$base]:-}" = "${CTS[$ctr]:-}" ]; then
      JUDGE[$base]="PASS"
    else
      JUDGE[$base]="FAIL"
    fi
    JUDGE[$ctr]="PASS" # 対照は自分自身と比べるので常に一致（基準行）
  done
  JUDGE[d2b]="-" # 対照が無い（引用符の直後に AS が続く形の追加ケース）
}

# --- 本編 ---

main() {
  log "作業ディレクトリ: $SCRIPT_DIR"
  log "証跡の保存先: $EVIDENCE_DIR"

  log "docker compose down -v / up -d ${SERVICES[*]}（前の走行の残骸を持ち越さない）"
  "${COMPOSE[@]}" down -v "${SERVICES[@]}" >/dev/null 2>&1 || true
  if ! "${COMPOSE[@]}" up -d "${SERVICES[@]}"; then
    log "docker compose up -d ${SERVICES[*]} が失敗した"
    return 1
  fi

  if ! mc alias set local "$MINIO_ENDPOINT" minioadmin minioadmin >/dev/null; then
    log "mc alias set が失敗した（minio:9000 に繋がらない）"
    return 1
  fi
  wait_for_trino || return 1
  wait_for_bucket || return 1

  if ! build_athena_local; then
    log "cargo build が失敗したため測定を実行しない"
    return 1
  fi
  start_athena_local || return 1

  log "準備: table t を作る（DESCRIBE / DESC / SHOW CREATE TABLE / ALTER TABLE の対象）"
  trino_exec "CREATE TABLE t AS SELECT 1 AS x" "$CATALOG" "$DATABASE" || log "table t の作成に失敗（続行して測定する）"

  # --- s1〜s6: SELECT / VALUES の様々な形 ---
  run_case s1 'SELECT(1)'
  run_case s1c 'SELECT (1)'
  run_case s2 "SELECT'a'"
  run_case s2c "SELECT 'a'"
  run_case s3 'SELECT*FROM (VALUES 1)'
  run_case s3c 'SELECT * FROM (VALUES 1)'
  run_case s4 '(SELECT(1))'
  run_case s4c '(SELECT (1))'
  run_case s5 'WITH"w" AS (SELECT 1 AS x) SELECT x FROM "w"'
  run_case s5c 'WITH "w" AS (SELECT 1 AS x) SELECT x FROM "w"'
  run_case s6 'VALUES(1)'
  run_case s6c 'VALUES (1)'

  # --- e1〜e2: EXPLAIN ---
  run_case e1 'EXPLAIN(TYPE IO) SELECT 1'
  run_case e1c 'EXPLAIN (TYPE IO) SELECT 1'
  run_case e2 'EXPLAIN(SELECT 1)'
  run_case e2c 'EXPLAIN (SELECT 1)'

  # --- u1〜u3: DESCRIBE / DESC / SHOW CREATE TABLE（table t が対象） ---
  run_case u1 'DESCRIBE"t"'
  run_case u1c 'DESCRIBE "t"'
  run_case u2 'DESC"t"'
  run_case u2c 'DESC "t"'
  run_case u3 'SHOW CREATE TABLE"t"'
  run_case u3c 'SHOW CREATE TABLE "t"'

  # --- d1: ALTER TABLE ADD COLUMN（table t に列を 2 つ足す） ---
  run_case d1 'ALTER TABLE"t" ADD COLUMN m1 int'
  run_case d1c 'ALTER TABLE "t" ADD COLUMN m2 int'

  # --- d2/d2c/d2b: CREATE TABLE AS SELECT（d2b は引用符の直後に AS が続く追加ケース、対照なし） ---
  run_case d2 'CREATE TABLE"t2" AS SELECT 1 AS x'
  run_case d2c 'CREATE TABLE "t3" AS SELECT 1 AS x'
  run_case d2b 'CREATE TABLE"t4"AS SELECT 1 AS x'

  # --- d3/d3c: DROP TABLE（t2/t3 の後始末。t4 はここでは測らず後で片付ける） ---
  run_case d3 'DROP TABLE"t2"'
  run_case d3c 'DROP TABLE "t3"'
  log "後始末: table t4（d2b で作った分、対照が無いので測定対象に含めない）を消す"
  trino_exec 'DROP TABLE IF EXISTS t4' "$CATALOG" "$DATABASE" || true

  # --- v1/v1c: CREATE VIEW ---
  run_case v1 'CREATE VIEW"v1" AS SELECT 1 AS x'
  run_case v1c 'CREATE VIEW "v2" AS SELECT 1 AS x'

  # --- v2/v2c: SHOW CREATE VIEW ---
  run_case v2 'SHOW CREATE VIEW"v1"'
  run_case v2c 'SHOW CREATE VIEW "v2"'

  # --- v3/v3c: DROP VIEW ---
  run_case v3 'DROP VIEW"v1"'
  run_case v3c 'DROP VIEW "v2"'

  log "後始末: table t と、測定中に何か失敗していた場合の残骸を安全網として消す"
  trino_exec 'DROP TABLE IF EXISTS t' "$CATALOG" "$DATABASE" || true
  trino_exec 'DROP TABLE IF EXISTS t2' "$CATALOG" "$DATABASE" || true
  trino_exec 'DROP TABLE IF EXISTS t3' "$CATALOG" "$DATABASE" || true
  trino_exec 'DROP TABLE IF EXISTS t4' "$CATALOG" "$DATABASE" || true
  trino_exec 'DROP VIEW IF EXISTS v1' "$CATALOG" "$DATABASE" || true
  trino_exec 'DROP VIEW IF EXISTS v2' "$CATALOG" "$DATABASE" || true

  if [ "$EXPECT" = after ]; then
    judge_after
  fi

  local fails=0 label
  for label in "${LABELS[@]}"; do
    [ "${STATES[$label]}" = "START失敗" ] && fails=$((fails + 1))
    if [ "$EXPECT" = after ] && [ "${JUDGE[$label]:-}" = "FAIL" ]; then
      fails=$((fails + 1))
    fi
  done
  log "PASS/FAIL 集計対象外の判定（判定列 -）を含め、詳しい内訳は表を参照"
  return "$fails"
}

main
