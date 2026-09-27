#!/usr/bin/env bash
# tools/measure/lib.sh の実行の芯（フェーズ 1）の自己テスト。#310。
# DRY_RUN=1 だけで動く（本物の aws にも Trino にも繋がない）。
# 失敗したケースは `FAIL: <理由>` を stderr に出し、最後にまとめて exit 1 にする。
# 全部通れば `selftest: ok (<n> checks)` を出して exit 0。
set -uo pipefail

FAILURES=0
CHECKS=0

fail() {
  FAILURES=$((FAILURES + 1))
  echo "FAIL: $1" >&2
}

# assert <説明> <条件コマンド...>（例: assert "state=SUCCEEDED" [ "$state" = SUCCEEDED ]）
assert() {
  local desc=$1
  shift
  CHECKS=$((CHECKS + 1))
  if ! "$@"; then
    fail "$desc"
  fi
}

contains() { printf '%s' "$1" | grep -qF -- "$2"; }
not_contains() { ! contains "$1" "$2"; }

col() {
  # col <summary.tsv> <id> <列番号（1始まり）>
  awk -F'\t' -v id="$2" -v n="$3" '$1==id{print $n; found=1} END{if(!found) print ""}' "$1"
}

OUT_DIR="$(mktemp -d)"
export OUT_DIR
export DRY_RUN=1
export RETRY_DELAY=0
export RETRY_MAX=4

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tools/measure/lib.sh
. "$LIB_DIR/lib.sh"

lib_init 310 athena_local_probe_310

# --- ケース1: 成功 --------------------------------------------------------------
run_query ok1 db "SELECT 1"
rc=$?
assert "ケース1: run_query が 0 を返す" [ "$rc" -eq 0 ]
assert "ケース1: state=SUCCEEDED" [ "$(col "$SUMMARY" ok1 3)" = SUCCEEDED ]
assert "ケース1: <id>.sql が保存される" [ -s "$RUN_DIR/ok1.sql" ]
assert "ケース1: <id>.execution.json が保存される" [ -s "$RUN_DIR/ok1.execution.json" ]
assert "ケース1: 結果本体（<id>.bytes）が保存される" [ -s "$RUN_DIR/ok1.bytes" ]
assert "ケース1: .metadata（<id>.metadata.bytes）が保存される" [ -s "$RUN_DIR/ok1.metadata.bytes" ]

# --- ケース2: DRY_RUN_FAIL で FAILED ---------------------------------------------
DRY_RUN_FAIL=fail1 run_query fail1 db "SELECT 1"
rc=$?
assert "ケース2: run_query が非 0 を返す" [ "$rc" -ne 0 ]
assert "ケース2: state=FAILED" [ "$(col "$SUMMARY" fail1 3)" = FAILED ]
errtype=$(col "$SUMMARY" fail1 12)
assert "ケース2: error_type が空でない" [ -n "$errtype" ]
assert "ケース2: error_type が - でない（埋まっている）" [ "$errtype" != "-" ]

# --- ケース3: DRY_RUN_START_FAIL で START 失敗 -----------------------------------
DRY_RUN_START_FAIL=start1 run_query start1 db "SELECT 1"
rc=$?
assert "ケース3: run_query が非 0 を返す" [ "$rc" -ne 0 ]
assert "ケース3: state=START_FAILED" [ "$(col "$SUMMARY" start1 3)" = START_FAILED ]
startmsg=$(col "$SUMMARY" start1 13)
assert "ケース3: start_message が空でない" [ -n "$startmsg" ]
assert "ケース3: start_message が - でない（埋まっている）" [ "$startmsg" != "-" ]
assert "ケース3: start_athena_error_code=MALFORMED_QUERY" [ "$(col "$SUMMARY" start1 14)" = MALFORMED_QUERY ]

# --- ケース4: 一時的な失敗の後に成功する -----------------------------------------
DRY_RUN_TRANSIENT=trans1:2 run_query trans1 db "SELECT 1"
rc=$?
assert "ケース4: run_query が 0 を返す" [ "$rc" -eq 0 ]
assert "ケース4: state=SUCCEEDED" [ "$(col "$SUMMARY" trans1 3)" = SUCCEEDED ]
note=$(col "$SUMMARY" trans1 15)
assert "ケース4: note に attempts=3 が残る" contains "$note" "attempts=3"

# --- ケース5: 厄介な SQL（'・"・\・タブ・改行・非 ASCII） -----------------------
nasty_sql=$'SELECT 1 -- \x27"\\\tafter_tab\nline2 日本語 END'
before_lines=$(wc -l < "$SUMMARY" | tr -d ' ')
run_query nasty1 db "$nasty_sql"
after_lines=$(wc -l < "$SUMMARY" | tr -d ' ')
printf '%s' "$nasty_sql" > "$OUT_DIR/.nasty-expected"
assert "ケース5: <id>.sql がバイト一致で残る" cmp -s "$OUT_DIR/.nasty-expected" "$RUN_DIR/nasty1.sql"
assert "ケース5: summary.tsv が1行だけ増える" [ "$((after_lines - before_lines))" -eq 1 ]

# --- ケース6: マスク（add_hide_pair・長い方が先に置換される） ---------------------
# 短い方を先に登録する（登録順のままだと短い方が先に潰され、長い方の一部
# （"2345"）が残ってしまう。長さ降順のソートが効いているかをこの順序で確かめる）。
add_hide_pair "mysecretdb1" "<SECRET_SHORT>"
add_hide_pair "mysecretdb12345" "<SECRET_LONG>"
masked=$(hide "見た目 mysecretdb12345 end")
assert "ケース6: 登録した実名（長い方）が hide の出力に残らない" not_contains "$masked" "mysecretdb12345"
assert "ケース6: 長い方の一致で消費され、短い方の断片も残らない" not_contains "$masked" "mysecretdb1"
assert "ケース6: 長い方の印に置き換わる" contains "$masked" "<SECRET_LONG>"

# --- ケース7: athena_call（成功1件・不正な JSON で skip 1件） --------------------
athena_call apiok1 ListDatabases '{"CatalogName":"AwsDataCatalog"}'
rc=$?
assert "ケース7: athena_call（成功）が 0 を返す" [ "$rc" -eq 0 ]
assert "ケース7: <id>.request.json が保存される" [ -s "$RUN_DIR/apiok1.request.json" ]
assert "ケース7: <id>.response.json が保存される" [ -s "$RUN_DIR/apiok1.response.json" ]

athena_call apibad1 ListDatabases '{not valid json'
rc=$?
assert "ケース7: 不正な JSON は非 0 を返す" [ "$rc" -ne 0 ]
assert "ケース7: 不正な JSON の kind=skip" [ "$(col "$SUMMARY" apibad1 2)" = skip ]

# --- ケース10: ctx の4形（db/catalog/none/<Catalog>/<Database>） ----------------
run_query ctxdb1 db "SELECT 1"
ctx_json=$(cat "$RUN_DIR/ctxdb1.context.txt")
assert "ケース10: ctx=db は Catalog と Database を含む" \
  python3 -c 'import json, sys
d = json.loads(sys.argv[1])
sys.exit(0 if ("Catalog" in d and "Database" in d) else 1)' "$ctx_json"

run_query ctxcat1 catalog "SELECT 1"
ctx_json=$(cat "$RUN_DIR/ctxcat1.context.txt")
assert "ケース10: ctx=catalog は Catalog だけを含む（Database は無い）" \
  python3 -c 'import json, sys
d = json.loads(sys.argv[1])
sys.exit(0 if ("Catalog" in d and "Database" not in d) else 1)' "$ctx_json"

run_query ctxnone1 none "SELECT 1"
ctx_json=$(cat "$RUN_DIR/ctxnone1.context.txt")
assert "ケース10: ctx=none は Context を付けない（空）" \
  python3 -c 'import json, sys
sys.exit(0 if json.loads(sys.argv[1]) == {} else 1)' "$ctx_json"

run_query ctxcustom1 "CustomCat/CustomDB" "SELECT 1"
ctx_json=$(cat "$RUN_DIR/ctxcustom1.context.txt")
assert "ケース10: ctx=<Catalog>/<Database> はその値をそのまま使う" \
  python3 -c 'import json, sys
d = json.loads(sys.argv[1])
sys.exit(0 if (d.get("Catalog") == "CustomCat" and d.get("Database") == "CustomDB") else 1)' "$ctx_json"

# 綴りを誤った ctx は db に倒さず、投げずに skip する
run_query ctxtypo1 cataog "SELECT 1"
assert "ケース10: 不明な ctx は SKIPPED" [ "$(col "$SUMMARY" ctxtypo1 3)" = SKIPPED ]
assert "ケース10: 不明な ctx では投げない" [ ! -e "$RUN_DIR/ctxtypo1.sql" ]

# --- ケース11: retry_aws を使い切った athena_call の本当の失敗（.err・note） -----
# DRY_RUN_TRANSIENT の n を大きくすると一時的な失敗が続き、RETRY_MAX 回で
# retry_aws が諦める（DRY_RUN_FAIL・DRY_RUN_START_FAIL とは別の失敗経路）。
DRY_RUN_TRANSIENT=apifail1:99 athena_call apifail1 ListDatabases '{"CatalogName":"AwsDataCatalog"}'
rc=$?
assert "ケース11: retry_aws を使い切ると athena_call は非 0 を返す" [ "$rc" -ne 0 ]
assert "ケース11: <id>.err が保存される" [ -s "$RUN_DIR/apifail1.err" ]
note=$(col "$SUMMARY" apifail1 15)
assert "ケース11: summary の note に失敗が残る" contains "$note" "error"

# --- ケース9: retry_aws 自身の再試行（athena_call 経由。start_query_retry の再試行
# ループとは別物）。1回だけ一時的な失敗を注入し、retry_aws が拾って2回目で成功する
# ことを確かめる（RETRY_MAX=4 の範囲内）。
DRY_RUN_TRANSIENT=apitrans1:1 athena_call apitrans1 ListDatabases '{"CatalogName":"AwsDataCatalog"}'
rc=$?
assert "ケース9: retry_aws の再試行で athena_call が成功する" [ "$rc" -eq 0 ]
assert "ケース9: <id>.response.json が保存される" [ -s "$RUN_DIR/apitrans1.response.json" ]

# --- ケース8: START_CALL_FILE の行数 = calls.log の start-query-execution の行数 ---
start_call_lines=$(wc -l < "$START_CALL_FILE" | tr -d ' ')
calls_log_start_lines=$(grep -c '^athena start-query-execution$' "$RUN_DIR/.dry-run/calls.log")
assert "ケース8: START_CALL_FILE と calls.log の start-query-execution の行数が一致" \
  [ "$start_call_lines" -eq "$calls_log_start_lines" ]
assert "ケース8: calls.log が空でない" [ -s "$RUN_DIR/.dry-run/calls.log" ]

if [ "$FAILURES" -eq 0 ]; then
  echo "selftest: ok ($CHECKS checks)"
  exit 0
else
  echo "selftest: $FAILURES/$CHECKS 件失敗" >&2
  exit 1
fi
