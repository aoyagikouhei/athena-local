#!/usr/bin/env bash
# issue #207 の実機検証の足場（tools/e2e/request-errors/verify.sh を雛形にした）。
#
# #207 は StartQueryExecution の開始時の判定を広げる:
#   (1) 引用符付きの名前・4 部以上の名前を取る DDL 系の文の構文の文言（MALFORMED_QUERY。既存の #204 の続き）
#   (2) DESCRIBE・DESC・SHOW COLUMNS の開始前の存在の確認（テーブル不在は INVALID_INPUT の Entity Not Found、
#       3 部の名前でカタログ不在は DATACATALOG_NOT_FOUND、ビューは引用符付きでも実行される）
# この足場は compose のローカル Trino に hive のテーブル・ビューを用意し、athena-local の
# StartQueryExecution に .claude/issue-notes/207.md の「実測の結果」に基づくケース表を流して、
# 「開始できる（QueryExecutionId が返る）」か「InvalidRequestException で AthenaErrorCode と
# Message が一致する」かを確かめる。本物の AWS には投げない（compose の trino だけ）。
#
# 実装前（#204 のまま）の athena-local で流すと 16 件が FAIL になり、#207 の実装後は全件 PASS になることを
# 確かめてある（2026-09-25）。
#
# 期待値の line:column はどれも python3 で検算した値（コメントに数え方を残す）。
# expecting の一覧（EXPECTING）は quoted_names.rs の同名の定数と 1 文字も違わないコピー。
#
# 前提コマンド: tools/dev.sh 経由で動かす（toolbox に全部入っている）
#
# 使い方:
#   tools/dev.sh tools/e2e/quoted-names/verify.sh
#
# 環境変数:
#   KEEP_UP=1        テスト後に docker compose down -v trino をせず環境を残す（デバッグ用）
#   SKIP_BUILD=1     cargo build を省略し、既存の $CARGO_TARGET_DIR（tools/dev.sh では .toolbox/target）の release/athena-local をそのまま使う
#
# 後始末は本スクリプトの trap が行う: 2 つの athena-local を止め、Trino のスキーマ e2e207 を
# DROP SCHEMA ... CASCADE で消し（KEEP_UP=1 でなければ）docker compose down -v trino する。
# 終了コードは結果表の FAIL の件数を数え、1 件でもあれば 1。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# cargo の成果物の置き場。tools/dev.sh は CARGO_TARGET_DIR を .toolbox/target にする
BINARY="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/athena-local"
COMPOSE=(docker compose -f "$REPO_ROOT/compose.yml")
SERVICES=(trino)

TRINO_BASE="http://trino:8080"
SCHEMA="e2e207"

# 主系（TRINO_CATALOG_MAP あり）。ケース 1〜8。
ATHENA_BIND="127.0.0.1:8093"
ATHENA_BASE="http://${ATHENA_BIND}"
# 副系（TRINO_CATALOG_MAP 無し）。ケース 9（最小構成の確認）だけに使う。
ATHENA_BIND2="127.0.0.1:8094"
ATHENA_BASE2="http://${ATHENA_BIND2}"

EVIDENCE_DIR="$(mktemp -d /tmp/athena-local-issue207-e2e.XXXXXX)"
ATHENA_LOG="$EVIDENCE_DIR/athena-local.log"
ATHENA_LOG2="$EVIDENCE_DIR/athena-local-nomap.log"
BUILD_LOG="$EVIDENCE_DIR/cargo-build.log"

ATHENA_PID=""
ATHENA_PID2=""

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
  echo "証跡（起動ログ）: $EVIDENCE_DIR"
  [ "$fail" -eq 0 ]
}

cleanup() {
  local status=$?
  if [ -n "$ATHENA_PID" ] && kill -0 "$ATHENA_PID" 2>/dev/null; then
    log "athena-local (PID $ATHENA_PID) を止める"
    kill "$ATHENA_PID" 2>/dev/null || true
    wait "$ATHENA_PID" 2>/dev/null || true
  fi
  if [ -n "$ATHENA_PID2" ] && kill -0 "$ATHENA_PID2" 2>/dev/null; then
    log "athena-local (PID $ATHENA_PID2、TRINO_CATALOG_MAP 無し) を止める"
    kill "$ATHENA_PID2" 2>/dev/null || true
    wait "$ATHENA_PID2" 2>/dev/null || true
  fi

  log "Trino のスキーマ $SCHEMA を消す（無ければ何もしない）"
  trino_exec "DROP SCHEMA IF EXISTS hive.${SCHEMA} CASCADE" hive default >/dev/null 2>&1 || true

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

# --- Trino への直接アクセス（セットアップ・後始末専用。測定対象の文は athena-local 経由で投げる） ---

trino_exec() {
  local sql="$1" catalog="$2" schema="$3"
  local resp next
  resp=$(curl -sf -X POST "$TRINO_BASE/v1/statement" \
    -H "X-Trino-User: e2e-207-setup" \
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

# 引数: 1 bind（127.0.0.1:PORT）、2 TRINO_CATALOG_MAP の値（空文字なら設定しない）、
# 3 ログの置き場所、4 起動した PID を書き込む変数名。
start_athena_local() {
  local bind="$1" catalog_map="$2" athena_log="$3" pid_var="$4"
  log "athena-local を起動する（bind=$bind, TRINO_CATALOG_MAP=${catalog_map:-<無し>}, ログ: $athena_log）"
  (
    cd "$REPO_ROOT"
    if [ -n "$catalog_map" ]; then
      exec env \
        ATHENA_LOCAL_BIND="$bind" \
        TRINO_URL="$TRINO_BASE" \
        TRINO_USER="athena-local-e2e207" \
        TRINO_CATALOG="hive" \
        TRINO_SCHEMA="$SCHEMA" \
        TRINO_CATALOG_MAP="$catalog_map" \
        ATHENA_LOCAL_RESULTS="none" \
        "$BINARY"
    else
      exec env \
        ATHENA_LOCAL_BIND="$bind" \
        TRINO_URL="$TRINO_BASE" \
        TRINO_USER="athena-local-e2e207" \
        TRINO_CATALOG="hive" \
        TRINO_SCHEMA="$SCHEMA" \
        ATHENA_LOCAL_RESULTS="none" \
        "$BINARY"
    fi
  ) >"$athena_log" 2>&1 &
  local pid=$!
  printf -v "$pid_var" '%s' "$pid"

  log "athena-local (http://$bind) の起動待ち"
  local _ status
  for _ in $(seq 1 30); do
    if ! kill -0 "$pid" 2>/dev/null; then
      log "athena-local が異常終了した。ログ:"
      cat "$athena_log" >&2
      return 1
    fi
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://$bind/" \
      -H "X-Amz-Target: AmazonAthena.ListWorkGroups" \
      -H "Content-Type: application/x-amz-json-1.1" \
      --data-binary '{}')
    if [ "$status" = "200" ]; then
      log "athena-local ($bind) 起動確認"
      return 0
    fi
    sleep 1
  done
  log "athena-local ($bind) が応答しなかった"
  return 1
}

# --- athena-local の StartQueryExecution を直接呼ぶ ---

start_raw() {
  local base="$1" sql="$2"
  local body
  body=$(jq -cn --arg sql "$sql" --arg token "$(uuidgen)" \
    '{QueryString: $sql, ClientRequestToken: $token}')
  curl -s -X POST "$base/" \
    -H "X-Amz-Target: AmazonAthena.StartQueryExecution" \
    -H "Content-Type: application/x-amz-json-1.1" \
    --data-binary "$body"
}

# 本物の Entity Not Found の形（.claude/issue-notes/207.md の実測。Request ID は毎回違う UUID）。
is_entity_not_found() {
  local msg="$1"
  [[ "$msg" =~ ^Entity\ Not\ Found\ \(Service:\ AmazonDataCatalog\;\ Status\ Code:\ 400\;\ Error\ Code:\ EntityNotFoundException\;\ Request\ ID:\ [0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\;\ Proxy:\ null\)$ ]]
}

# 「開始できる（QueryExecutionId が返る）」ことを確かめる。
expect_start() {
  local no="$1" name="$2" sql="$3" base="${4:-$ATHENA_BASE}"
  local resp qid
  resp=$(start_raw "$base" "$sql")
  qid=$(echo "$resp" | jq -r '.QueryExecutionId // empty')
  if [ -n "$qid" ]; then
    record "$no $name" PASS "開始できた QueryExecutionId=$qid"
  else
    local type_ code msg
    type_=$(echo "$resp" | jq -r '.__type // empty')
    code=$(echo "$resp" | jq -r '.AthenaErrorCode // empty')
    msg=$(echo "$resp" | jq -r '.Message // empty')
    record "$no $name" FAIL "開始できなかった: __type=${type_:-無し} AthenaErrorCode=${code:-無し} Message=\"$msg\""
  fi
}

# 「InvalidRequestException で AthenaErrorCode と Message が一致する」ことを確かめる。
# mode: exact = exp_msg と完全一致 / entity_not_found = is_entity_not_found の形かどうかだけ見る（exp_msg は無視）
expect_reject() {
  local no="$1" name="$2" sql="$3" exp_code="$4" exp_msg="$5" mode="$6" base="${7:-$ATHENA_BASE}"
  local resp qid type_ code msg
  resp=$(start_raw "$base" "$sql")
  qid=$(echo "$resp" | jq -r '.QueryExecutionId // empty')
  if [ -n "$qid" ]; then
    record "$no $name" FAIL "拒否される想定が開始できてしまった: QueryExecutionId=$qid"
    return
  fi

  type_=$(echo "$resp" | jq -r '.__type // empty')
  code=$(echo "$resp" | jq -r '.AthenaErrorCode // empty')
  msg=$(echo "$resp" | jq -r '.Message // empty')

  local ok=1 diff=""
  [ "$type_" = "InvalidRequestException" ] || { ok=0; diff="$diff __type=${type_:-無し}(期待 InvalidRequestException)"; }
  [ "$code" = "$exp_code" ] || { ok=0; diff="$diff AthenaErrorCode=${code:-無し}(期待 $exp_code)"; }
  case "$mode" in
    entity_not_found)
      is_entity_not_found "$msg" || { ok=0; diff="$diff Message=\"$msg\"（Entity Not Found の形でない）"; }
      ;;
    *)
      [ "$msg" = "$exp_msg" ] || { ok=0; diff="$diff Message=\"$msg\"(期待 \"$exp_msg\")"; }
      ;;
  esac

  if [ "$ok" = "1" ]; then
    record "$no $name" PASS "AthenaErrorCode=$code Message=\"$msg\""
  else
    record "$no $name" FAIL "差:${diff} / 実際: __type=${type_:-無し} AthenaErrorCode=${code:-無し} Message=\"$msg\""
  fi
}

# quoted_names.rs の EXPECTING 定数の写し（2026-09-25 実測、1 文字も違わない前提）。
EXPECTING="{'SELECT', 'FROM', 'ADD', 'AS', 'ALL', 'DISTINCT', 'WHERE', 'GROUP', 'BY', 'GROUPING', 'SETS', 'CUBE', 'ROLLUP', 'ORDER', 'HAVING', 'LIMIT', 'AT', 'OR', 'AND', 'IN', NOT, 'NO', 'EXISTS', 'BETWEEN', 'LIKE', RLIKE, 'IS', 'NULL', 'TRUE', 'FALSE', 'NULLS', 'ASC', 'DESC', 'FOR', 'INTERVAL', 'CASE', 'WHEN', 'THEN', 'ELSE', 'END', 'JOIN', 'CROSS', 'OUTER', 'INNER', 'LEFT', 'SEMI', 'RIGHT', 'FULL', 'NATURAL', 'ON', 'LATERAL', 'WINDOW', 'OVER', 'PARTITION', 'RANGE', 'ROWS', 'UNBOUNDED', 'PRECEDING', 'FOLLOWING', 'CURRENT', 'ROW', 'WITH', 'VALUES', 'CREATE', 'TABLE', 'VIEW', 'REPLACE', 'INSERT', 'DELETE', 'INTO', 'DESCRIBE', 'EXPLAIN', 'FORMAT', 'LOGICAL', 'CODEGEN', 'CAST', 'SHOW', 'TABLES', 'COLUMNS', 'COLUMN', 'USE', 'PARTITIONS', 'FUNCTIONS', 'DROP', 'UNION', 'EXCEPT', 'INTERSECT', 'TO', 'TABLESAMPLE', 'STRATIFY', 'ALTER', 'RENAME', 'ARRAY', 'MAP', 'STRUCT', 'COMMENT', 'SET', 'RESET', 'DATA', 'START', 'TRANSACTION', 'COMMIT', 'ROLLBACK', 'MACRO', 'FIRST', 'AFTER', 'IF', 'DIV', 'PERCENT', 'BUCKET', 'OUT', 'OF', 'SORT', 'CLUSTER', 'DISTRIBUTE', 'OVERWRITE', 'TRANSFORM', 'REDUCE', 'USING', 'SERDE', 'SERDEPROPERTIES', 'RECORDREADER', 'RECORDWRITER', 'DELIMITED', 'FIELDS', 'TERMINATED', 'COLLECTION', 'ITEMS', 'KEYS', 'ESCAPED', 'LINES', 'SEPARATED', 'FUNCTION', 'EXTENDED', 'REFRESH', 'CLEAR', 'CACHE', 'UNCACHE', 'LAZY', 'FORMATTED', TEMPORARY, 'OPTIONS', 'UNSET', 'TBLPROPERTIES', 'DBPROPERTIES', 'BUCKETS', 'SKEWED', 'STORED', 'DIRECTORIES', 'LOCATION', 'EXCHANGE', 'ARCHIVE', 'UNARCHIVE', 'FILEFORMAT', 'TOUCH', 'COMPACT', 'CONCATENATE', 'CHANGE', 'CASCADE', 'RESTRICT', 'CLUSTERED', 'SORTED', 'PURGE', 'INPUTFORMAT', 'OUTPUTFORMAT', DATABASE, DATABASES, 'DFS', 'TRUNCATE', 'ANALYZE', 'COMPUTE', 'LIST', 'STATISTICS', 'PARTITIONED', 'EXTERNAL', 'DEFINED', 'REVOKE', 'GRANT', 'LOCK', 'UNLOCK', 'MSCK', 'REPAIR', 'EXPORT', 'IMPORT', 'LOAD', 'ROLE', 'ROLES', 'COMPACTIONS', 'PRINCIPALS', 'TRANSACTIONS', 'INDEX', 'INDEXES', 'LOCKS', 'OPTION', 'ANTI', 'LOCAL', 'INPATH', IDENTIFIER, BACKQUOTED_IDENTIFIER}"

# --- ケース ---
#
# 位置（line:column）の数え方: column は行頭から対象の文字までの文字数（1 起点）。
# 例えば `DESCRIBE "t"` は D(1)E(2)S(3)C(4)R(5)I(6)B(7)E(8)space(9) の次、10 文字目が `"` の
# 開始位置なので line 1:10。すべて python3 の position() 相当（sql[:at] の文字数 + 1）で検算した。
run_cases() {
  local base="$1"

  # 1: DESCRIBE の存在するテーブル。無引用（2 部・大文字を含む）は開始できる。引用符付きは
  #    #204 のまま構文の文言（1 部・名前の始まりから）。
  #    位置の数え方: sql='DESCRIBE "t"' の 10 文字目（DESCRIBE の 8 文字 + 空白 1 文字の次）が `"`。
  expect_start "1a" "DESCRIBE t（小文字・存在・無引用）" "DESCRIBE t" "$base"
  expect_start "1b" "DESCRIBE e2e207.t（2部・存在・無引用）" "DESCRIBE e2e207.t" "$base"
  expect_start "1c" "DESCRIBE T（大文字・存在・無引用）" "DESCRIBE T" "$base"
  expect_reject "1d" 'DESCRIBE "t"（引用符付き・存在）' 'DESCRIBE "t"' \
    MALFORMED_QUERY "line 1:10: no viable alternative at input 'DESCRIBE \"t\"'" exact "$base"

  # 2: DESCRIBE・SHOW COLUMNS・DESC の存在しない名前（無引用・引用符付き・2部・スキーマ不在）は
  #    すべて開始前に Entity Not Found（INVALID_INPUT）。
  expect_reject "2a" "DESCRIBE nope（無引用・不在）" "DESCRIBE nope" \
    INVALID_INPUT "" entity_not_found "$base"
  expect_reject "2b" 'DESCRIBE "nope"（引用符付き・不在）' 'DESCRIBE "nope"' \
    INVALID_INPUT "" entity_not_found "$base"
  expect_reject "2c" "DESCRIBE e2e207.nope（2部・不在）" "DESCRIBE e2e207.nope" \
    INVALID_INPUT "" entity_not_found "$base"
  expect_reject "2d" "DESCRIBE nodb.t（スキーマ不在）" "DESCRIBE nodb.t" \
    INVALID_INPUT "" entity_not_found "$base"
  expect_reject "2e" "SHOW COLUMNS FROM nope" "SHOW COLUMNS FROM nope" \
    INVALID_INPUT "" entity_not_found "$base"
  expect_reject "2f" "DESC nope" "DESC nope" \
    INVALID_INPUT "" entity_not_found "$base"

  # 3: 3部の名前でカタログ不在は DATACATALOG_NOT_FOUND。
  expect_reject "3" "DESCRIBE nocat.e2e207.t（カタログ不在）" "DESCRIBE nocat.e2e207.t" \
    DATACATALOG_NOT_FOUND "Catalog 'nocat' does not exist" exact "$base"

  # 4: ビューは引用符付きでも開始できる（存在の確認でビューと分かれば実行する。#204 からの変更）。
  expect_start "4a" "DESCRIBE v（ビュー・無引用）" "DESCRIBE v" "$base"
  expect_start "4b" 'DESCRIBE "v"（ビュー・引用符付き）' 'DESCRIBE "v"' "$base"
  expect_start "4c" 'SHOW COLUMNS FROM "v"（ビュー・引用符付き）' 'SHOW COLUMNS FROM "v"' "$base"

  # 5: 4部以上の DESCRIBE は引用符の有無・位置によらず Invalid table name（各部の value() を . で
  #    つないだもの。無引用なので小文字化はされない＝そのまま）。
  expect_reject "5" "DESCRIBE hive.e2e207.t.n（4部）" "DESCRIBE hive.e2e207.t.n" \
    MALFORMED_QUERY "Invalid table name hive.e2e207.t.n" exact "$base"

  # 6: 4部以上の DROP TABLE で引用符付きの部分が無ければ、3つ目の . の位置で mismatched input。
  #    位置の数え方: 'DROP TABLE hive.e2e207.nope.n' の中の3つ目の '.'。
  #    D(0)R(1)O(2)P(3) (4) T(5)A(6)B(7)L(8)E(9) (10) h(11)i(12)v(13)e(14) .(15)
  #    e(16)2(17)e(18)2(19)0(20)7(21) .(22) n(23)o(24)p(25)e(26) .(27) n(28)
  #    → 3つ目の '.' は 0-indexed で 27 文字目（before に27文字）→ column = 27+1 = 28。
  expect_reject "6" "DROP TABLE hive.e2e207.nope.n（4部・無引用）" "DROP TABLE hive.e2e207.nope.n" \
    MALFORMED_QUERY "line 1:28: mismatched input '.' expecting {<EOF>, 'PURGE'}" exact "$base"

  # 7: 3部の ALTER TABLE で2番目（スキーマ）が引用符付きなら、文の最初の語から最初の引用符付きの
  #    部分までで no viable alternative。
  #    位置の数え方: 'ALTER TABLE hive."e2e207".nope RENAME TO x' の中の '"e2e207"' の開始位置。
  #    'ALTER TABLE hive.' が17文字（0-16）→ 17文字目（0-indexed）が '"' → column = 17+1 = 18。
  expect_reject "7" 'ALTER TABLE hive."e2e207".nope RENAME TO x（3部・2番目引用符付き）' \
    'ALTER TABLE hive."e2e207".nope RENAME TO x' \
    MALFORMED_QUERY "line 1:18: no viable alternative at input 'ALTER TABLE hive.\"e2e207\"'" exact "$base"

  # 8: SHOW TABLES IN・CREATE TABLE の2〜3部への拡張（#204 では1部だけだった）。
  #    位置の数え方（SHOW TABLES IN）: 'SHOW TABLES IN hive.' が20文字（0-19）→ 20文字目が '"' → column 21。
  expect_reject "8a" 'SHOW TABLES IN hive."e2e207"（2部・引用符付き）' 'SHOW TABLES IN hive."e2e207"' \
    MALFORMED_QUERY "line 1:21: mismatched input '\"e2e207\"' expecting ${EXPECTING}" exact "$base"
  #    位置の数え方（CREATE TABLE 2部）: 'CREATE TABLE ' が13文字（0-12）→ 13文字目が '"' → column 14。
  expect_reject "8b" 'CREATE TABLE "e2e207"."x" (n int)（2部・引用符付き）' 'CREATE TABLE "e2e207"."x" (n int)' \
    MALFORMED_QUERY "line 1:14: no viable alternative at input 'CREATE TABLE \"e2e207\"'" exact "$base"
  #    位置の数え方（CREATE TABLE IF NOT EXISTS）: 'CREATE TABLE IF NOT EXISTS ' が27文字（0-26）
  #    → 27文字目が '"' → column 28。
  expect_reject "8c" 'CREATE TABLE IF NOT EXISTS "x" (n int)' 'CREATE TABLE IF NOT EXISTS "x" (n int)' \
    MALFORMED_QUERY "line 1:28: no viable alternative at input 'CREATE TABLE IF NOT EXISTS \"x\"'" exact "$base"
}

main() {
  log "作業ディレクトリ: $SCRIPT_DIR"
  log "証跡の保存先: $EVIDENCE_DIR"

  if ! build_athena_local; then
    record "cargo build" FAIL "ビルドが失敗した"
    return 1
  fi
  record "cargo build" PASS "$BINARY を用意した"

  # 前の走行の残骸を持ち越さないよう、trino を作り直す。
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

  log "Trino 側のスキーマ・テーブル・ビューを用意する"
  if ! trino_exec "CREATE SCHEMA IF NOT EXISTS hive.${SCHEMA}" hive default; then
    record "セットアップ(スキーマ)" FAIL "hive.${SCHEMA} の作成に失敗した"
    return 1
  fi
  if ! trino_exec "CREATE TABLE hive.${SCHEMA}.t AS SELECT 1 AS n" hive "$SCHEMA"; then
    record "セットアップ(テーブル)" FAIL "hive.${SCHEMA}.t の作成に失敗した"
    return 1
  fi
  if ! trino_exec "CREATE VIEW hive.${SCHEMA}.v AS SELECT n FROM hive.${SCHEMA}.t" hive "$SCHEMA"; then
    record "セットアップ(ビュー)" FAIL "hive.${SCHEMA}.v の作成に失敗した"
    return 1
  fi
  record "セットアップ" PASS "hive.${SCHEMA}.t（テーブル）・hive.${SCHEMA}.v（ビュー）作成済み"
  # 非 ASCII 名のテーブルは、ケース表のどのケースも使わないので用意しない（hive が名前に
  # 使えるかどうかも確かめていない。判断の詳細は verify.sh の呼び出し元への報告を参照）。

  if ! start_athena_local "$ATHENA_BIND" "AwsDataCatalog=hive" "$ATHENA_LOG" ATHENA_PID; then
    record "athena-local起動(主系)" FAIL "athena-local が起動しなかった"
    return 1
  fi
  record "athena-local起動(主系)" PASS "$ATHENA_BASE で応答（TRINO_CATALOG_MAP=AwsDataCatalog=hive）"

  run_cases "$ATHENA_BASE"

  # 9: 最小構成（TRINO_CATALOG_MAP を設定しない）でも 1・2 の代表ケースが同じであることを確かめる。
  if ! start_athena_local "$ATHENA_BIND2" "" "$ATHENA_LOG2" ATHENA_PID2; then
    record "athena-local起動(副系)" FAIL "athena-local（TRINO_CATALOG_MAP 無し）が起動しなかった"
  else
    record "athena-local起動(副系)" PASS "$ATHENA_BASE2 で応答（TRINO_CATALOG_MAP 無し）"
    expect_reject "9a" 'DESCRIBE "t"（最小構成・1の代表）' 'DESCRIBE "t"' \
      MALFORMED_QUERY "line 1:10: no viable alternative at input 'DESCRIBE \"t\"'" exact "$ATHENA_BASE2"
    expect_reject "9b" "DESCRIBE nope（最小構成・2の代表）" "DESCRIBE nope" \
      INVALID_INPUT "" entity_not_found "$ATHENA_BASE2"
  fi
}

main
