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

# 先頭が "--" のコメントの SQL も、偽 aws が Query を落とさず先頭語で DML と読む（値が "--" で始まる引数）
lead_sql=$'-- leading comment\nSELECT 1'
run_query lead1 db "$lead_sql"
assert "ケース5: 先頭コメントの SQL が Query に残る" [ "$(cat "$RUN_DIR/lead1.query.txt")" = "$lead_sql" ]
assert "ケース5: 先頭コメントの SELECT は DML" [ "$(col "$SUMMARY" lead1 4)" = DML ]

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

# ============================================================================
# フェーズ2（items.sh・cleanup.sh・preflight.sh・summary.sh）のケース。
# それぞれ独立した OUT_DIR・lib_init で流したいので、サブシェルの中で完結させ、
# 見たい値（RUN_DIR や DB）だけをマーカーファイル経由で親へ持ち帰る（親の
# FAILURES/CHECKS を直接いじれるのは親のプロセスだけなので、assert は必ず親で呼ぶ）。
# ============================================================================

# サブシェルの中で lib_init まで済ませ、（渡されれば）宣言・run_items のコード片を
# eval してから、$RUN_DIR・$DB をマーカーファイルに書いて返す。eval にしているのは、
# 別プロセス（bash -c）にすると item/run_items が定義されていないため
# （シェル関数は export -f しない限り子プロセスへ渡らない）。
# 使う環境変数は呼び出し側が export 済みという前提（DB・ONLY・DRY_RUN_* など）。
_p2_run_dir_of() {
  local marker=$1 issue=$2 prefix=$3 code=${4:-}
  (
    export OUT_DIR="$(mktemp -d)"
    # shellcheck source=tools/measure/lib.sh
    . "$LIB_DIR/lib.sh" > /dev/null
    lib_init "$issue" "$prefix" > /dev/null
    [ -n "$code" ] && eval "$code"
    {
      echo "RUN_DIR=$RUN_DIR"
      echo "DB=$DB"
    } > "$marker"
  ) > "$marker.out" 2> "$marker.err"
}

# マーカーファイルから RUN_DIR / DB を読む。
_p2_field() {
  sed -n "s/^$2=//p" "$1" 2> /dev/null | head -1
}

# --- ケース12: needs の先が FAILED なら skip -------------------------------------
marker=$(mktemp)
DB=fixed_db_a DRY_RUN_FAIL=mk_a _p2_run_dir_of "$marker" 310 athena_local_probe_310a \
  'item mk_a ctx=db "SELECT 1"; item use_a ctx=db needs=mk_a "SELECT 1"; run_items > /dev/null'
dir12=$(_p2_field "$marker" RUN_DIR)
assert "ケース12: needs の先が FAILED の項目が用意できる" [ -n "$dir12" ]
assert "ケース12: needs の先が FAILED なら use_a は skip" [ "$(col "$dir12/summary.tsv" use_a 2)" = skip ]
note12=$(col "$dir12/summary.tsv" use_a 15)
assert "ケース12: 理由に needs mk_a が FAILED が残る" contains "$note12" "needs mk_a が FAILED"

# --- ケース13: creates → 使う2項目 → 最後の利用者の直後に DROP が1回 -------------
marker=$(mktemp)
DB=fixed_db_b _p2_run_dir_of "$marker" 310 athena_local_probe_310b \
  'item mk_b creates=TABLE:probe_b ctx=db "CREATE EXTERNAL TABLE dummy (n int)"
item use_b1 ctx=db needs=mk_b "SELECT 1"
item use_b2 ctx=db needs=mk_b "SELECT 1"
run_items > /dev/null'
dir13=$(_p2_field "$marker" RUN_DIR)
assert "ケース13: creates の項目が用意できる" [ -n "$dir13" ]
assert "ケース13: DROP は1回だけ（drops.tsv が1行）" \
  [ "$(wc -l < "$dir13/drops.tsv" | tr -d ' ')" -eq 1 ]
pos_use_b2=$(grep -n '^use_b2$' "$dir13/.start-calls" | head -1 | cut -d: -f1)
pos_drop_b=$(grep -n '^drop-probe_b$' "$dir13/.start-calls" | head -1 | cut -d: -f1)
assert "ケース13: DROP の StartQueryExecution が記録される" [ -n "$pos_drop_b" ]
assert "ケース13: use_b2 の StartQueryExecution が記録される" [ -n "$pos_use_b2" ]
assert "ケース13: DROP は最後の利用者（use_b2）より後" [ "${pos_drop_b:-0}" -gt "${pos_use_b2:-0}" ]
assert "ケース13: finish_cleanup 後に created.tsv が空" [ ! -s "$dir13/created.tsv" ]

# --- ケース14: 作る項目が FAILED なら DROP を投げない ----------------------------
marker=$(mktemp)
DB=fixed_db_c DRY_RUN_FAIL=mk_c _p2_run_dir_of "$marker" 310 athena_local_probe_310c \
  'item mk_c creates=TABLE:probe_c ctx=db "SELECT 1"; run_items > /dev/null'
dir14=$(_p2_field "$marker" RUN_DIR)
assert "ケース14: FAILED の creates が用意できる" [ -n "$dir14" ]
assert "ケース14: drops.tsv が無い（DROP を投げない）" [ ! -s "$dir14/drops.tsv" ]
assert "ケース14: created.tsv にも残らない（SUCCEEDED でないので記録自体しない）" [ ! -s "$dir14/created.tsv" ]

# --- ケース15: skip= の項目 -------------------------------------------------------
marker=$(mktemp)
DB=fixed_db_d _p2_run_dir_of "$marker" 310 athena_local_probe_310d \
  'item skipped1 skip="Athena の文書に無い" ctx=db "SELECT 1"; run_items > /dev/null'
dir15=$(_p2_field "$marker" RUN_DIR)
assert "ケース15: skip= の項目が用意できる" [ -n "$dir15" ]
assert "ケース15: kind=skip" [ "$(col "$dir15/summary.tsv" skipped1 2)" = skip ]
assert "ケース15: 理由がそのまま残る" contains "$(col "$dir15/summary.tsv" skipped1 15)" "Athena の文書に無い"
assert "ケース15: 投げていない（<id>.sql が無い）" [ ! -e "$dir15/skipped1.sql" ]

# --- ケース16: ONLY で1件だけ（needs の先を含めないと skip） --------------------
marker=$(mktemp)
DB=fixed_db_e ONLY=only_b _p2_run_dir_of "$marker" 310 athena_local_probe_310e \
  'item only_a ctx=db "SELECT 1"; item only_b ctx=db needs=only_a "SELECT 1"; run_items > /dev/null'
dir16=$(_p2_field "$marker" RUN_DIR)
assert "ケース16: ONLY で絞った実行が用意できる" [ -n "$dir16" ]
assert "ケース16: ONLY に無い only_a は投げない" [ ! -e "$dir16/only_a.sql" ]
assert "ケース16: only_a は summary.tsv に出ない" [ -z "$(col "$dir16/summary.tsv" only_a 2)" ]
assert "ケース16: needs の先を自動で含めないので only_b は skip" [ "$(col "$dir16/summary.tsv" only_b 2)" = skip ]
assert "ケース16: 理由に未実行が残る" contains "$(col "$dir16/summary.tsv" only_b 15)" "needs only_a が"

# --- ケース17: 知らない key は宣言の時点で exit 2（サブシェルで） ----------------
marker=$(mktemp)
(
  # shellcheck source=tools/measure/lib.sh
  . "$LIB_DIR/lib.sh" > /dev/null
  item bad1 badkey=1 "SELECT 1"
) > "$marker.out" 2> "$marker.err"
rc17=$?
assert "ケース17: 知らない key は exit 2" [ "$rc17" -eq 2 ]
assert "ケース17: エラーに key 名が残る" contains "$(cat "$marker.err")" "badkey"

# --- ケース18: preflight の DB の自動選択（DB を空にすると dry_run_db が選ばれる）---
marker=$(mktemp)
DB="" _p2_run_dir_of "$marker" 310 athena_local_probe_310f
dir18=$(_p2_field "$marker" RUN_DIR)
selected_db=$(_p2_field "$marker" DB)
assert "ケース18: DB 未指定の実行が用意できる" [ -n "$dir18" ]
assert "ケース18: SHOW DATABASES の1件目（dry_run_db）が選ばれる" [ "$selected_db" = dry_run_db ]
assert "ケース18: preflight-databases が投げられる" [ -s "$dir18/preflight-databases.sql" ]
assert "ケース18: 選んだ DB で SHOW TABLES を投げる" [ -s "$dir18/preflight-list-tables-auto.sql" ]

# 指定した DB で SHOW TABLES が失敗したら、SHOW DATABASES の1件目に落ちて取り直す
marker=$(mktemp)
DB="nosuch_db" DRY_RUN_FAIL=preflight-list-tables _p2_run_dir_of "$marker" 310 athena_local_probe_310f
dir18b=$(_p2_field "$marker" RUN_DIR)
assert "ケース18: 指定した DB の SHOW TABLES が失敗したら SHOW DATABASES の1件目に落ちる" [ "$(_p2_field "$marker" DB)" = dry_run_db ]
assert "ケース18: 落ちた先で SHOW TABLES を取り直す" [ -s "$dir18b/preflight-list-tables-auto.sql" ]

# 同じ表を 2 つの項目が作り直したとき、DROP 1 本の成功で台帳から消えるのは 1 行だけ
RUN_DIR_SAVE=$RUN_DIR; RUN_DIR=$(mktemp -d)
printf 'TABLE\tprobe_twice\nTABLE\tprobe_twice\n' > "$RUN_DIR/created.tsv"
forget_created TABLE probe_twice
assert "ケース18: forget_created は同じ行を 1 行だけ消す" [ "$(wc -l < "$RUN_DIR/created.tsv" | tr -d ' ')" = 1 ]
RUN_DIR=$RUN_DIR_SAVE

# --- ケース19: SHOW TABLES に PREFIX を含む表があれば止まる（衝突検知） ---------
marker=$(mktemp)
(
  export OUT_DIR="$(mktemp -d)"
  export DB=""
  export DRY_RUN_SHOW_TABLES="athena_local_probe_310h_leftover"
  # shellcheck source=tools/measure/lib.sh
  . "$LIB_DIR/lib.sh" > /dev/null
  lib_init 310 athena_local_probe_310h
  echo "SHOULD_NOT_REACH" > "$marker.reached"
) > "$marker.out" 2> "$marker.err"
rc19=$?
assert "ケース19: PREFIX の衝突で exit 1" [ "$rc19" -eq 1 ]
assert "ケース19: 止まったメッセージが出る" contains "$(cat "$marker.err")" "何も作らずに止まります"
assert "ケース19: 衝突後は先へ進まない" [ ! -e "$marker.reached" ]

# 大文字小文字だけが違う残骸も衝突とみなす
marker=$(mktemp)
(
  export OUT_DIR="$(mktemp -d)"
  export DB=""
  export DRY_RUN_SHOW_TABLES="ATHENA_LOCAL_PROBE_310H_LEFTOVER"
  # shellcheck source=tools/measure/lib.sh
  . "$LIB_DIR/lib.sh" > /dev/null
  lib_init 310 athena_local_probe_310h
) > "$marker.out" 2> "$marker.err"
assert "ケース19: 大文字小文字の違う残骸でも exit 1" [ "$?" -eq 1 ]

# --- ケース22: 終端を待つ間に中断されても、作りかけの表に trap が DROP IF EXISTS を投げる ---
# 中断は待ちの中で自分の subshell に TERM を送って作る。trap の保険の DROP は START_CALL_FILE に
# 数えないので、偽 aws の start-query-execution がそれより 1 本多ければ投げている。
out22=$(mktemp -d)
(
  export OUT_DIR="$out22"
  export DB=""
  # shellcheck source=tools/measure/lib.sh
  . "$LIB_DIR/lib.sh" > /dev/null
  lib_init 310 athena_local_probe_310k > /dev/null
  me=$BASHPID
  poll_until_terminal() { kill -TERM "$me"; sleep 1; }
  item mk_k creates=TABLE:athena_local_probe_310k_t "CREATE TABLE t_k (n int)"
  run_items
) > /dev/null 2>&1
dir22=$(ls -d "$out22"/run-* | head -1)
starts22=$(grep -c start-query-execution "$dir22/.dry-run/calls.log")
counted22=$(wc -l < "$dir22/.start-calls" | tr -d ' ')
assert "ケース22: trap が作りかけの表に DROP を投げる" [ "$starts22" -eq "$((counted22 + 1))" ]

# --- ケース23: summary.tsv の値が " で始まっても、後の項目の要約行が summary.txt から消えない ---
# 後始末の手掛かり（cleanup_hint）も summary.txt の冒頭に出る
marker=$(mktemp)
_p2_run_dir_of "$marker" 310 athena_local_probe_310m '
  cleanup_hint "hint-for-selftest"
  item quoted1 skip="\"Not available と文書にある（引用符が閉じない）" "SELECT 1"
  item after1 "SELECT 2"
  run_items'
dir23=$(_p2_field "$marker" RUN_DIR)
assert "ケース23: 引用符で始まる note の後の項目にも要約行が出る" grep -q "^- state=SUCCEEDED" <(sed -n '/^### after1/,$p' "$dir23/summary.txt")
assert "ケース23: cleanup_hint が summary.txt の冒頭に出る" grep -q "hint-for-selftest" "$dir23/summary.txt"

# --- ケース20: summary.txt（ケース13の RUN_DIR を使う） --------------------------
summary_txt13="$dir13/summary.txt"
assert "ケース20: summary.txt が作られる" [ -s "$summary_txt13" ]
header_calls13=$(grep -oE '含めない）: [0-9]+' "$summary_txt13" | grep -oE '[0-9]+' | head -1)
start_call_lines13=$(wc -l < "$dir13/.start-calls" | tr -d ' ')
calls_log_lines13=$(grep -c '^athena start-query-execution$' "$dir13/.dry-run/calls.log")
assert "ケース20: summary.txt 冒頭に回数の行がある" [ -n "$header_calls13" ]
assert "ケース20: summary.txt 冒頭の回数 = START_CALL_FILE の行数" \
  [ "${header_calls13:-0}" -eq "$start_call_lines13" ]
assert "ケース20: summary.txt 冒頭の回数 = calls.log の start-query-execution の行数" \
  [ "${header_calls13:-0}" -eq "$calls_log_lines13" ]
assert "ケース20: DDL の内訳に作った表と DROP の対が出る" \
  contains "$(cat "$summary_txt13")" "probe_b (TABLE): DROP -> SUCCEEDED"
assert "ケース20: DB 名（add_hide_pair した値）が summary.txt に出ない" \
  not_contains "$(cat "$summary_txt13")" "fixed_db_b"
assert "ケース20: 工場出荷時の既定とは限らない注意書きが出る" \
  contains "$(cat "$summary_txt13")" "工場出荷時の既定とは限らない"

# --- ケース21: DROP 自体が FAILED なら created.tsv から消さない（forget しない）---
# finish_cleanup が poll_until_terminal で終端まで待たずに SUCCEEDED を決め打ちすると
# 見分けが付かなくなるケース（壊す候補 (c) が壊すのはここ）。
marker=$(mktemp)
DB=fixed_db_g DRY_RUN_FAIL=drop-probe_g _p2_run_dir_of "$marker" 310 athena_local_probe_310g \
  'item mk_g creates=TABLE:probe_g ctx=db "CREATE EXTERNAL TABLE dummy (n int)"; run_items > /dev/null'
dir21=$(_p2_field "$marker" RUN_DIR)
assert "ケース21: DROP が FAILED になる項目が用意できる" [ -n "$dir21" ]
assert "ケース21: drop-log.tsv に FAILED が残る" contains "$(cat "$dir21/drop-log.tsv" 2> /dev/null)" "FAILED"
assert "ケース21: DROP が FAILED なら created.tsv から消さない" \
  grep -qxF "$(printf 'TABLE\tprobe_g')" "$dir21/created.tsv"

if [ "$FAILURES" -eq 0 ]; then
  echo "selftest: ok ($CHECKS checks)"
  exit 0
else
  echo "selftest: $FAILURES/$CHECKS 件失敗" >&2
  exit 1
fi
