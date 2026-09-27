#!/usr/bin/env bash
# issue #260 の実機検証の足場（tools/e2e/ctas-catalog/verify.sh を雛形にした）。
#
# #260 の変更: TRINO_CATALOG_MAP の `AwsDataCatalog` の別名（例 `AwsDataCatalog=hive`）を、SQL の無引用の
# `awsdatacatalog`（大文字小文字によらない）を 1 部目に書いた名前に当てる置換（#246・src/catalog.rs の
# alias_qualified_names）を次に広げる（置換は実行の中だけ。GetQueryExecution の Query は受け取ったまま）:
#   - Context の Catalog が S3 Tables（`s3tablescatalog/<bucket>`）の SELECT・INSERT で、無引用のちょうど 3 部
#     `awsdatacatalog.<db>.<t>`
#   - Context の Catalog が Trino に実在せず別名のキーでもない（例 `nosuchcatalog260`）の SELECT・INSERT で、同じ形
#   - Context の Catalog が AwsDataCatalog か省略の SELECT で、部品に引用符付きを含む
#     `awsdatacatalog."<db>".<t>`・`awsdatacatalog.<db>."<t>"` と 4 部の列の参照
#     `SELECT awsdatacatalog.<db>.<t>.n FROM awsdatacatalog.<db>.<t>`
# 今までどおり（受け取ったまま Trino に送るので、Trino に `awsdatacatalog` という名のカタログが無ければ FAILED）:
# S3 Tables・実在しないカタログの Context のほかの文（EXPLAIN など）、既定の Context の INSERT の引用符付きの
# 部品、S3 Tables の Context の SELECT の引用符付きの部品、Trino に実在するほかのカタログ（例 `iceberg` を
# そのまま Context に書く）の Context の SELECT（.claude/issue-notes/260.md の実測・設計判断・計画）。
#
# この足場は compose のローカル Trino に hive（Glue 役）と iceberg（S3 Tables 役・連携カタログ役を兼ねる）の
# 2 カタログを持たせ、TRINO_CATALOG_MAP=s3tablescatalog/e2e260=iceberg,AwsDataCatalog=hive、
# TRINO_CATALOG=AwsDataCatalog にして、athena-local の StartQueryExecution／GetQueryExecution／
# GetQueryResults に次のケース表を流して判定する。本物の AWS には投げない（compose の trino・minio だけ）。
#
# hive に DB e2e260db、表 t260 (n int, s varchar) を 1 行（1, 'x'）入りで事前に作る。ケースは順に流し、
# INSERT で行を増やす（N2 で 2 行、N3 で 3 行になり、以降は増えない。R4 は FAILED になり増えない想定）。
#
# ケース表（TRINO_CATALOG_MAP=s3tablescatalog/e2e260=iceberg,AwsDataCatalog=hive、TRINO_CATALOG=AwsDataCatalog）:
#   N1 S3 Tables の Context（Catalog=s3tablescatalog/e2e260,Database=e2e260db）
#      SELECT * FROM awsdatacatalog.e2e260db.t260
#      → SUCCEEDED、GetQueryResults に 1 行（1, 'x'）、Query は受け取ったまま
#   N2 同じ Context
#      INSERT INTO awsdatacatalog.e2e260db.t260 VALUES (2, 'y')
#      → SUCCEEDED、hive.e2e260db.t260 が 2 行になる（Trino に直接問い合わせて確かめる）
#   N3 Context の Catalog nosuchcatalog260（Database=e2e260db。Trino に実在せず別名のキーでもない）
#      同じ INSERT（INSERT INTO awsdatacatalog.e2e260db.t260 VALUES (2, 'y')）
#      → SUCCEEDED、hive.e2e260db.t260 が 3 行になる
#   N4 同じ Context（Catalog=nosuchcatalog260,Database=e2e260db）
#      SELECT * FROM awsdatacatalog.e2e260db.t260
#      → SUCCEEDED（3 行になっているはず）
#   N5 既定の Context（Catalog=AwsDataCatalog を明示,Database=e2e260db）
#      SELECT * FROM awsdatacatalog."e2e260db".t260
#      → SUCCEEDED
#   N6 同じ Context
#      SELECT * FROM awsdatacatalog.e2e260db."t260"
#      → SUCCEEDED
#   N7 同じ Context
#      SELECT awsdatacatalog.e2e260db.t260.n FROM awsdatacatalog.e2e260db.t260
#      → SUCCEEDED、列名 n、値に 1 を含む（3 行のはず）
#   R1（回帰。#246） 既定の Context（Catalog 省略,Database=e2e260db）
#      SELECT * FROM awsdatacatalog.e2e260db.t260
#      → SUCCEEDED（#260 の前後で変わらない）
#   R2（回帰） S3 Tables の Context（Catalog=s3tablescatalog/e2e260,Database=e2e260db）
#      EXPLAIN SELECT * FROM awsdatacatalog.e2e260db.t260
#      → 今までどおり受け取ったまま送るので FAILED のはず（実際の状態と理由は下の「実測で確かめた FAILED の内容」）
#   R3（回帰） Context の Catalog iceberg（Trino に実在。Database=e2e260db）
#      SELECT * FROM awsdatacatalog.e2e260db.t260
#      → 今までどおり FAILED のはず（同上）
#   R4（回帰） 既定の Context（Catalog 省略,Database=e2e260db）
#      INSERT INTO awsdatacatalog."e2e260db".t260 VALUES (3, 'z')
#      → 今までどおり FAILED のはず（同上。行は増えない）
#
# 実測で確かめた FAILED の内容（2026-09-27、着手前 SHA 242f09b のビルドで確認。今までどおり受け取ったまま
# Trino に送るだけなので #260 の前後で変わらない想定。値はこのスクリプトの先頭の EXPECT_R2_*・EXPECT_R3_*・
# EXPECT_R4_* にハードコードしてある）:
#   R2: ErrorCategory=2 ErrorType=1006 Retryable=false
#       StateChangeReason "CATALOG_NOT_FOUND: line 1:23: Catalog 'awsdatacatalog' not found"
#   R3: ErrorCategory=2 ErrorType=1006 Retryable=false
#       StateChangeReason "CATALOG_NOT_FOUND: line 1:15: Catalog 'awsdatacatalog' not found"
#   R4: ErrorCategory=2 ErrorType=1301 Retryable=false
#       StateChangeReason "TABLE_NOT_FOUND: line 1:1: Table 'awsdatacatalog.e2e260db.t260' does not exist"
#
# 前提コマンド: tools/dev.sh 経由で動かす（toolbox に全部入っている）
#
# 使い方:
#   tools/dev.sh tools/e2e/catalog-unquoted/verify.sh
#   COMPOSE_PROJECT_NAME=al260 tools/dev.sh tools/e2e/catalog-unquoted/verify.sh   # 他の足場と同時に流すとき
#
# 環境変数:
#   KEEP_UP=1        テスト後に docker compose down -v をせず環境を残す（デバッグ用）
#   SKIP_BUILD=1     cargo build を省略し、$BINARY（無ければ $CARGO_TARGET_DIR の release/athena-local）をそのまま使う
#   BINARY=<path>    使う athena-local バイナリを差し替える（変更前後の 2 段階の受け入れ用。SKIP_BUILD=1 と組み合わせる）
#
# 後始末は本スクリプトの trap が行う: athena-local を止め、Trino の hive.e2e260db を DROP で消し
# （KEEP_UP=1 でなければ）docker compose down -v trino minio minio-init する。ほかの docker コンテナや
# compose のサービス（他のプロジェクトを含む）は止めたり消したりしない。cargo test も走らせない。
# 終了コードは結果表の FAIL の件数を数え、1 件でもあれば 1。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# cargo の成果物の置き場。tools/dev.sh は CARGO_TARGET_DIR を .toolbox/target にする。BINARY を明示すればそちらを使う
# （変更前のビルドを別ディレクトリで作って差し替えるときに使う）。
BINARY="${BINARY:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/athena-local}"
COMPOSE=(docker compose -f "$REPO_ROOT/compose.yml")
SERVICES=(trino minio minio-init)

TRINO_BASE="http://trino:8080"
MINIO_ENDPOINT="http://minio:9000"
BUCKET="athena-results"
PREFIX="e2e260"
OUTPUT_LOCATION="s3://${BUCKET}/${PREFIX}/"

S3_TABLES_CATALOG="s3tablescatalog/e2e260"
HIVE_DB="e2e260db"              # hive（Glue 役）に事前に作る DB。全ケース共通の Context の Database にも使う
NOSUCH_CATALOG="nosuchcatalog260" # Trino に実在せず、別名のキーでもない（N3・N4）
FEDERATED_CATALOG="iceberg"      # Trino に実在するカタログをそのまま Context に書く（R3。連携カタログの代わり）

ATHENA_BIND="127.0.0.1:8160"
ATHENA_BASE="http://${ATHENA_BIND}"

# R2・R3・R4 が FAILED になったときの実際の内容（2026-09-27、着手前 SHA 242f09b のビルドで確認。#260 の前後で
# 挙動が変わらない想定の回帰なので、このスクリプトではハードコードして厳密に比較する）。空文字なら比較を
# 省き、実際の値を記録するだけにする（初回の実測用）。
EXPECT_R2_CATEGORY="2"
EXPECT_R2_TYPE="1006"
EXPECT_R2_RETRYABLE="false"
EXPECT_R2_REASON_SUBSTR="CATALOG_NOT_FOUND: line 1:23: Catalog 'awsdatacatalog' not found"
EXPECT_R3_CATEGORY="2"
EXPECT_R3_TYPE="1006"
EXPECT_R3_RETRYABLE="false"
EXPECT_R3_REASON_SUBSTR="CATALOG_NOT_FOUND: line 1:15: Catalog 'awsdatacatalog' not found"
EXPECT_R4_CATEGORY="2"
EXPECT_R4_TYPE="1301"
EXPECT_R4_RETRYABLE="false"
EXPECT_R4_REASON_SUBSTR="TABLE_NOT_FOUND: line 1:1: Table 'awsdatacatalog.e2e260db.t260' does not exist"

EVIDENCE_DIR="$(mktemp -d /tmp/athena-local-issue260-e2e.XXXXXX)"
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
    printf "%-6s %-56s %s\n" "${RESULT_STATUS[$i]}" "${RESULT_NAMES[$i]}" "${RESULT_DETAIL[$i]}"
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
  echo "証跡（起動ログ・取得したファイル）: $EVIDENCE_DIR"
  [ "$fail" -eq 0 ]
}

cleanup() {
  local status=$?
  if [ -n "$ATHENA_PID" ] && kill -0 "$ATHENA_PID" 2>/dev/null; then
    log "athena-local (PID $ATHENA_PID) を止める"
    kill "$ATHENA_PID" 2>/dev/null || true
    wait "$ATHENA_PID" 2>/dev/null || true
  fi

  log "Trino の DB を消す（無ければ何もしない）"
  trino_exec "DROP SCHEMA IF EXISTS hive.${HIVE_DB} CASCADE" hive default >/dev/null 2>&1 || true

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

# --- Trino への直接アクセス（セットアップ・後始末・追加確認専用。測定対象の文は athena-local 経由で投げる） ---

trino_exec() {
  local sql="$1" catalog="$2" schema="$3"
  local resp next
  resp=$(curl -sf -X POST "$TRINO_BASE/v1/statement" \
    -H "X-Trino-User: e2e-260-setup" \
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

# trino_exec と同じだが、行データ（`data` フィールド）を JSON 配列にまとめて返す（件数の確認用）。
trino_query_rows() {
  local sql="$1" catalog="$2" schema="$3"
  local resp next rows="[]"
  resp=$(curl -sf -X POST "$TRINO_BASE/v1/statement" \
    -H "X-Trino-User: e2e-260-check" \
    -H "X-Trino-Catalog: $catalog" \
    -H "X-Trino-Schema: $schema" \
    -H "X-Trino-Client-Capabilities: PARAMETRIC_DATETIME" \
    --data-binary "$sql")
  while true; do
    if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
      log "trino_query_rows 失敗: $sql"
      echo "$resp" | jq '.error' >&2
      echo "$rows"
      return 1
    fi
    if echo "$resp" | jq -e '.data' >/dev/null 2>&1; then
      rows=$(jq -c -n --argjson a "$rows" --argjson b "$(echo "$resp" | jq -c '.data')" '$a + $b')
    fi
    next=$(echo "$resp" | jq -r '.nextUri // empty')
    if [ -z "$next" ]; then
      break
    fi
    resp=$(curl -sf "$next")
  done
  echo "$rows"
  return 0
}

# hive.e2e260db.t260 の件数（整数）。
hive_row_count() {
  trino_query_rows "SELECT count(*) FROM ${HIVE_DB}.t260" hive default | jq -r '.[0][0]'
}

wait_for_trino() {
  log "Trino の起動待ち ($TRINO_BASE)"
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
  log "athena-local を起動する（bind=$ATHENA_BIND、binary=$BINARY、TRINO_CATALOG_MAP=${S3_TABLES_CATALOG}=iceberg,AwsDataCatalog=hive、TRINO_CATALOG=AwsDataCatalog、ログ: $ATHENA_LOG）"
  (
    cd "$REPO_ROOT"
    exec env \
      ATHENA_LOCAL_BIND="$ATHENA_BIND" \
      TRINO_URL="$TRINO_BASE" \
      TRINO_USER="athena-local-e2e260" \
      TRINO_CATALOG_MAP="${S3_TABLES_CATALOG}=iceberg,AwsDataCatalog=hive" \
      TRINO_CATALOG="AwsDataCatalog" \
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
      --data-binary '{}')
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

# QueryExecutionContext（Catalog・Database）付きの StartQueryExecution。catalog に空文字を渡すと
# QueryExecutionContext.Catalog そのものを省略する（R1・R4 の「既定の Context（Catalog 省略）」用）。
start_raw() {
  local sql="$1" catalog="$2" database="$3"
  local body
  if [ -z "$catalog" ]; then
    body=$(jq -cn --arg sql "$sql" --arg db "$database" --arg token "$(uuidgen)" \
      '{QueryString: $sql, QueryExecutionContext: {Database: $db}, ClientRequestToken: $token}')
  else
    body=$(jq -cn --arg sql "$sql" --arg catalog "$catalog" --arg db "$database" --arg token "$(uuidgen)" \
      '{QueryString: $sql, QueryExecutionContext: {Catalog: $catalog, Database: $db}, ClientRequestToken: $token}')
  fi
  athena_call StartQueryExecution "$body"
}

# QUEUED/RUNNING でなくなるまで GetQueryExecution をポーリングし、最後の応答を返す。
athena_wait() {
  local id="$1" resp state
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

# StartQueryExecution → 終端状態まで待ち、LAST_ID・LAST_RESP に結果を残す。開始できなければ
# LAST_ID を空のままにし、LAST_START に生の応答を残して 1 を返す。
LAST_ID=""
LAST_RESP=""
LAST_START=""

run_and_wait() {
  local sql="$1" catalog="$2" database="$3"
  local start
  start=$(start_raw "$sql" "$catalog" "$database")
  LAST_ID=$(echo "$start" | jq -r '.QueryExecutionId // empty')
  if [ -z "$LAST_ID" ]; then
    LAST_START="$start"
    LAST_RESP=""
    return 1
  fi
  LAST_START=""
  LAST_RESP=$(athena_wait "$LAST_ID")
  return 0
}

# --- ケースの判定 ---

# SELECT 系: SUCCEEDED になり、Query を受け取ったまま返すことを確かめる。
case_select_ok() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5"
  if ! run_and_wait "$sql" "$catalog" "$database"; then
    record "$no $name" FAIL "開始できなかった: $(echo "$LAST_START" | tr -d '\n' | cut -c1-200)"
    return
  fi
  local state query substmt ok=1 detail=""
  state=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.State // empty')
  query=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Query // empty')
  substmt=$(echo "$LAST_RESP" | jq -r '.QueryExecution.SubstatementType // empty')
  [ "$state" = "SUCCEEDED" ] || {
    local reason
    reason=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.StateChangeReason // empty')
    ok=0; detail="$detail State=${state:-無し}(期待 SUCCEEDED) StateChangeReason=\"$reason\""
  }
  [ "$query" = "$sql" ] || { ok=0; detail="$detail Query=\"$query\"(期待 受け取ったまま)"; }

  if [ "$ok" = "1" ]; then
    record "$no $name" PASS "State=$state SubstatementType=${substmt:-無し} Query 一致 [id=$LAST_ID]"
  else
    record "$no $name" FAIL "${detail# } [id=$LAST_ID]"
  fi
}

# N1: SELECT が SUCCEEDED になることに加え、GetQueryResults の行数が expect_rows（ヘッダ行を含む）で、
# want_substr をどこかに含むことも確かめる。
case_select_ok_with_results() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5" expect_rows="$6" want_substr="$7"
  if ! run_and_wait "$sql" "$catalog" "$database"; then
    record "$no $name" FAIL "開始できなかった: $(echo "$LAST_START" | tr -d '\n' | cut -c1-200)"
    return
  fi
  local state query ok=1 detail=""
  state=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.State // empty')
  query=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Query // empty')
  [ "$state" = "SUCCEEDED" ] || {
    local reason
    reason=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.StateChangeReason // empty')
    ok=0; detail="$detail State=${state:-無し}(期待 SUCCEEDED) StateChangeReason=\"$reason\""
  }
  [ "$query" = "$sql" ] || { ok=0; detail="$detail Query=\"$query\"(期待 受け取ったまま)"; }

  local results row_count
  results=$(athena_call GetQueryResults "$(jq -n --arg id "$LAST_ID" '{QueryExecutionId: $id}')")
  row_count=$(echo "$results" | jq -r '.ResultSet.Rows | length' 2>/dev/null || echo "-1")
  if [ "$row_count" != "$expect_rows" ]; then
    ok=0
    detail="$detail GetQueryResults の行数=${row_count}(期待 $expect_rows)"
  fi
  if [ -n "$want_substr" ] && ! echo "$results" | grep -q "$want_substr"; then
    ok=0
    detail="$detail GetQueryResults に \"$want_substr\" を含まない"
  fi

  if [ "$ok" = "1" ]; then
    record "$no $name" PASS "State=$state Query 一致 GetQueryResults 行数=$row_count [id=$LAST_ID]"
  else
    record "$no $name" FAIL "${detail# } [id=$LAST_ID] results=$(echo "$results" | tr -d '\n' | cut -c1-300)"
  fi
}

# INSERT 系: SUCCEEDED になり、hive.e2e260db.t260 の件数が expect_count になることを確かめる。
case_insert_ok() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5" expect_count="$6"
  if ! run_and_wait "$sql" "$catalog" "$database"; then
    record "$no $name" FAIL "開始できなかった: $(echo "$LAST_START" | tr -d '\n' | cut -c1-200)"
    return
  fi
  local state query ok=1 detail=""
  state=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.State // empty')
  query=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Query // empty')
  [ "$state" = "SUCCEEDED" ] || {
    local reason
    reason=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.StateChangeReason // empty')
    ok=0; detail="$detail State=${state:-無し}(期待 SUCCEEDED) StateChangeReason=\"$reason\""
  }
  [ "$query" = "$sql" ] || { ok=0; detail="$detail Query=\"$query\"(期待 受け取ったまま)"; }

  local count
  count=$(hive_row_count)
  if [ "$count" != "$expect_count" ]; then
    ok=0
    detail="$detail hive.${HIVE_DB}.t260 の件数=${count}(期待 $expect_count)"
  fi

  if [ "$ok" = "1" ]; then
    record "$no $name" PASS "State=$state Query 一致 件数=$count [id=$LAST_ID]"
  else
    record "$no $name" FAIL "${detail# } [id=$LAST_ID]"
  fi
}

# 回帰の FAILED 系: State=FAILED・Query 受け取ったまま・行が増えていないことを確かめ、StateChangeReason・
# AthenaError・件数を記録する。expect_* が空文字なら比較を省いて実際の値をそのまま記録する（初回の実測用）。
# 件数は実行の直前に読んで「増えない」ことだけを見る（N2・N3 の INSERT が通るかどうかで基準が変わっても
# 影響されないように。#260 の新挙動が入る前後どちらでも成り立つ）。
case_fail_regression() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5"
  local expect_category="$6" expect_type="$7" expect_retryable="$8" expect_reason_substr="$9"
  local before_count
  before_count=$(hive_row_count)
  if ! run_and_wait "$sql" "$catalog" "$database"; then
    record "$no $name" FAIL "開始できなかった: $(echo "$LAST_START" | tr -d '\n' | cut -c1-200)"
    return
  fi
  local state reason category type_ retryable query ok=1 detail=""
  state=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.State // empty')
  reason=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.StateChangeReason // empty')
  category=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.AthenaError.ErrorCategory // empty')
  type_=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.AthenaError.ErrorType // empty')
  retryable=$(echo "$LAST_RESP" | jq -r \
    'if .QueryExecution.Status.AthenaError.Retryable == null then "" else (.QueryExecution.Status.AthenaError.Retryable | tostring) end')
  query=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Query // empty')

  [ "$state" = "FAILED" ] || { ok=0; detail="$detail State=${state:-無し}(期待 FAILED)"; }
  [ "$query" = "$sql" ] || { ok=0; detail="$detail Query=\"$query\"(期待 受け取ったまま)"; }
  if [ -n "$expect_category" ] && [ "$category" != "$expect_category" ]; then
    ok=0; detail="$detail ErrorCategory=${category:-無し}(期待 $expect_category)"
  fi
  if [ -n "$expect_type" ] && [ "$type_" != "$expect_type" ]; then
    ok=0; detail="$detail ErrorType=${type_:-無し}(期待 $expect_type)"
  fi
  if [ -n "$expect_retryable" ] && [ "$retryable" != "$expect_retryable" ]; then
    ok=0; detail="$detail Retryable=${retryable:-無し}(期待 $expect_retryable)"
  fi
  if [ -n "$expect_reason_substr" ] && ! echo "$reason" | grep -qF "$expect_reason_substr"; then
    ok=0; detail="$detail StateChangeReason=\"$reason\"(期待に \"$expect_reason_substr\" を含む)"
  fi

  local count
  count=$(hive_row_count)
  if [ "$count" != "$before_count" ]; then
    ok=0
    detail="$detail hive.${HIVE_DB}.t260 の件数=${count}(期待 実行前と同じ $before_count。FAILED で増えないはず)"
  fi

  local record_detail="State=$state ErrorCategory=${category:-無し} ErrorType=${type_:-無し} Retryable=${retryable:-無し} StateChangeReason=\"$reason\" 件数=$count(実行前 $before_count) [id=$LAST_ID]"
  if [ "$ok" = "1" ]; then
    record "$no $name" PASS "$record_detail"
  else
    record "$no $name" FAIL "${detail# } / 実際の値: $record_detail"
  fi
}

# --- ケース ---

run_cases() {
  local sql

  # N1: S3 Tables の Context・SELECT・無引用の 3 部。1 行(1,'x') のはず（まだ何も INSERT していない）。
  # GetQueryResults はヘッダ行 + データ行の 2 行想定。
  case_select_ok_with_results "N1" "S3Tablesの_Context・SELECT・無引用3部" \
    "SELECT * FROM awsdatacatalog.${HIVE_DB}.t260" "$S3_TABLES_CATALOG" "$HIVE_DB" 2 "x"

  # N2: S3 Tables の Context・INSERT・無引用の 3 部。2 行になる。
  case_insert_ok "N2" "S3Tablesの_Context・INSERT・無引用3部" \
    "INSERT INTO awsdatacatalog.${HIVE_DB}.t260 VALUES (2, 'y')" "$S3_TABLES_CATALOG" "$HIVE_DB" 2

  # N3: 実在しないカタログの Context・INSERT・無引用の 3 部（N2 と同じ INSERT 文）。3 行になる。
  case_insert_ok "N3" "実在しないカタログの_Context・INSERT・無引用3部" \
    "INSERT INTO awsdatacatalog.${HIVE_DB}.t260 VALUES (2, 'y')" "$NOSUCH_CATALOG" "$HIVE_DB" 3

  # N4: 実在しないカタログの Context・SELECT・無引用の 3 部。
  case_select_ok "N4" "実在しないカタログの_Context・SELECT・無引用3部" \
    "SELECT * FROM awsdatacatalog.${HIVE_DB}.t260" "$NOSUCH_CATALOG" "$HIVE_DB"

  # N5: 既定の Context（Catalog=AwsDataCatalog 明示）・SELECT・DB だけ引用符付き。
  case_select_ok "N5" "既定Context_Catalog明示・SELECT・DB引用符付き" \
    "SELECT * FROM awsdatacatalog.\"${HIVE_DB}\".t260" "AwsDataCatalog" "$HIVE_DB"

  # N6: 同じ Context・表だけ引用符付き。
  case_select_ok "N6" "既定Context_Catalog明示・SELECT・表引用符付き" \
    "SELECT * FROM awsdatacatalog.${HIVE_DB}.\"t260\"" "AwsDataCatalog" "$HIVE_DB"

  # N7: 同じ Context・4 部の列の参照。列名 n、値に 1 を含むはず（3 行 + ヘッダ行で 4 行想定）。
  case_select_ok_with_results "N7" "既定Context_Catalog明示・SELECT・4部の列参照" \
    "SELECT awsdatacatalog.${HIVE_DB}.t260.n FROM awsdatacatalog.${HIVE_DB}.t260" "AwsDataCatalog" "$HIVE_DB" 4 "\"n\""

  # R1（回帰・#246）: 既定の Context（Catalog 省略）・SELECT・無引用の 3 部。#260 の前後で変わらないはず。
  case_select_ok "R1" "回帰_既定Context_Catalog省略・SELECT・無引用3部" \
    "SELECT * FROM awsdatacatalog.${HIVE_DB}.t260" "" "$HIVE_DB"

  # R2（回帰）: S3 Tables の Context・EXPLAIN。今までどおり受け取ったまま送るので FAILED のはず。
  case_fail_regression "R2" "回帰_S3Tablesの_Context・EXPLAIN" \
    "EXPLAIN SELECT * FROM awsdatacatalog.${HIVE_DB}.t260" "$S3_TABLES_CATALOG" "$HIVE_DB" \
    "$EXPECT_R2_CATEGORY" "$EXPECT_R2_TYPE" "$EXPECT_R2_RETRYABLE" "$EXPECT_R2_REASON_SUBSTR"

  # R3（回帰）: Trino に実在するカタログ（iceberg）をそのまま Context に書いた SELECT。今までどおり FAILED のはず。
  case_fail_regression "R3" "回帰_実在カタログiceberg明示・SELECT" \
    "SELECT * FROM awsdatacatalog.${HIVE_DB}.t260" "$FEDERATED_CATALOG" "$HIVE_DB" \
    "$EXPECT_R3_CATEGORY" "$EXPECT_R3_TYPE" "$EXPECT_R3_RETRYABLE" "$EXPECT_R3_REASON_SUBSTR"

  # R4（回帰）: 既定の Context（Catalog 省略）・INSERT・DB だけ引用符付き。今までどおり FAILED のはず（行は増えない）。
  case_fail_regression "R4" "回帰_既定Context_Catalog省略・INSERT・DB引用符付き" \
    "INSERT INTO awsdatacatalog.\"${HIVE_DB}\".t260 VALUES (3, 'z')" "" "$HIVE_DB" \
    "$EXPECT_R4_CATEGORY" "$EXPECT_R4_TYPE" "$EXPECT_R4_RETRYABLE" "$EXPECT_R4_REASON_SUBSTR"
}

main() {
  log "作業ディレクトリ: $SCRIPT_DIR"
  log "証跡の保存先: $EVIDENCE_DIR"

  if ! build_athena_local; then
    record "cargo build" FAIL "ビルドが失敗した"
    return 1
  fi
  record "cargo build" PASS "$BINARY を用意した"

  # 前の走行の残骸を持ち越さないよう、使うサービスを作り直す。
  log "docker compose down -v / up -d ${SERVICES[*]}"
  if ! "${COMPOSE[@]}" down -v "${SERVICES[@]}" >/dev/null 2>&1; then
    record "compose起動" FAIL "docker compose down -v ${SERVICES[*]} が失敗した"
    return 1
  fi
  if ! "${COMPOSE[@]}" up -d "${SERVICES[@]}"; then
    record "compose起動" FAIL "docker compose up -d ${SERVICES[*]} が失敗した"
    return 1
  fi

  if ! wait_for_trino; then
    record "Trino起動" FAIL "Trino が起動しなかった"
    return 1
  fi
  record "Trino起動" PASS "$TRINO_BASE で応答"

  if ! mc alias set local http://minio:9000 minioadmin minioadmin >/dev/null; then
    record "MinIOバケット" FAIL "mc alias set が失敗した（minio:9000 に繋がらない）"
    return 1
  fi
  if ! wait_for_bucket; then
    record "MinIOバケット" FAIL "バケット $BUCKET の用意ができなかった"
    return 1
  fi
  record "MinIOバケット" PASS "バケット $BUCKET 用意済み"

  log "hive に DB $HIVE_DB と表 t260 (n int, s varchar) を 1 行(1,'x') 入りで用意する（$NOSUCH_CATALOG は作らない）"
  if ! trino_exec "CREATE SCHEMA IF NOT EXISTS hive.${HIVE_DB}" hive default; then
    record "セットアップ(hive DB)" FAIL "hive.${HIVE_DB} の作成に失敗した"
    return 1
  fi
  if ! trino_exec "CREATE TABLE IF NOT EXISTS hive.${HIVE_DB}.t260 (n int, s varchar)" hive default; then
    record "セットアップ(表)" FAIL "hive.${HIVE_DB}.t260 の作成に失敗した"
    return 1
  fi
  if ! trino_exec "INSERT INTO hive.${HIVE_DB}.t260 VALUES (1, 'x')" hive default; then
    record "セットアップ(初期行)" FAIL "hive.${HIVE_DB}.t260 への初期行の投入に失敗した"
    return 1
  fi
  record "セットアップ(DB・表・初期行)" PASS "hive.${HIVE_DB}.t260 作成済み・1 行(1,'x')（${NOSUCH_CATALOG} は未作成のまま）"

  if ! start_athena_local; then
    record "athena-local起動" FAIL "athena-local が起動しなかった"
    return 1
  fi
  record "athena-local起動" PASS "$ATHENA_BASE で応答（TRINO_CATALOG_MAP=${S3_TABLES_CATALOG}=iceberg,AwsDataCatalog=hive、binary=$BINARY）"

  run_cases
}

main
