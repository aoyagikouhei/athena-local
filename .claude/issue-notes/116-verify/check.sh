#!/usr/bin/env bash
# issue #116: tools/e2e/minio/verify.sh からヘルパを lib.sh へ移したことが「移動だけ」であることを確かめる。
# 使い方: .claude/issue-notes/116-verify/check.sh [着手前の rev（既定 30eb4eb）]
# lib.sh が無ければ移動前として扱い、構文と基準値だけを出す。各項目が NG なら終了コード 1。
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
BASE="${1:-30eb4eb}"
DIR=tools/e2e/minio
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
ok() { echo "ok  $*"; }
ng() { echo "NG  $*"; fail=1; }

git show "$BASE:$DIR/verify.sh" >"$TMP/before.sh"

# 1. 構文
for f in "$DIR/verify.sh" "$DIR/cases-dml-retention.sh" ${DIR}/lib.sh; do
  [ -f "$f" ] || continue
  bash -n "$f" && ok "bash -n $f" || ng "bash -n $f"
done

defs() { grep -hoE '^[a-z_]+\(\)' "$@" | sort; }

if [ ! -f "$DIR/lib.sh" ]; then
  echo "lib.sh が無い（移動前）: 関数 $(defs "$DIR/verify.sh" | wc -l) 個、実測の行 $(grep -c '実測' "$DIR/verify.sh")"
  exit "$fail"
fi

# 2. 関数の集合が前後で同じで、どれも 1 回だけ定義されている
if diff <(defs "$TMP/before.sh") <(defs "$DIR/verify.sh" "$DIR/lib.sh") >"$TMP/defs.diff"; then
  ok "関数の集合が同じ（$(defs "$TMP/before.sh" | wc -l) 個）"
else ng "関数の集合が違う"; cat "$TMP/defs.diff"; fi
dup=$(defs "$DIR/verify.sh" "$DIR/lib.sh" | uniq -d)
[ -z "$dup" ] && ok "二重定義なし" || ng "二重定義: $dup"

# 3. lib.sh に入る関数（計画どおりか）
expect_lib="athena_call athena_start_query athena_start_query_raw athena_wait build_athena_local check_body check_metadata log mc_exists mc_get mc_stat print_table read_metadata_head record start_athena_local trino_exec wait_for_bucket wait_for_trino"
got_lib=$(defs "$DIR/lib.sh" | tr -d '()' | tr '\n' ' ' | sed 's/ $//')
[ "$got_lib" = "$expect_lib" ] && ok "lib.sh の関数が計画どおり" || ng "lib.sh の関数: $got_lib（期待: $expect_lib）"

# 4. 「実測」を含む行の突き合わせ
diff <(grep -h '実測' "$TMP/before.sh" | sort) <(grep -h '実測' "$DIR/verify.sh" "$DIR/lib.sh" | sort) >/dev/null \
  && ok "実測の行が同じ（$(grep -c '実測' "$TMP/before.sh") 行）" || ng "実測の行が違う"

# 5. 正規化 diff: 空行を除き、行頭の空白を潰してソートし、前 と 後（verify.sh + lib.sh）を比べる。
#    許すのは、lib.sh の先頭のコメントの塊（最初のコード行より前）と、verify.sh の lib.sh を source する 2 行だけ。
norm() { sed -E 's/^[[:space:]]+//' "$@" | grep -v '^$' | sort; }
awk 'f || !/^#|^$/ {f=1} f' "$DIR/lib.sh" >"$TMP/lib.body"
grep -vE '^# shellcheck source=tools/e2e/minio/lib\.sh$|^source "\$SCRIPT_DIR/lib\.sh"$' "$DIR/verify.sh" >"$TMP/verify.body"
if diff <(norm "$TMP/before.sh") <(norm "$TMP/verify.body" "$TMP/lib.body") >"$TMP/norm.diff"; then
  ok "正規化 diff が空"
else ng "正規化 diff が残る"; cat "$TMP/norm.diff"; fi

# 6. source の順序: lib.sh を cases-dml-retention.sh と trap より前に読む
l_lib=$(grep -n 'source "\$SCRIPT_DIR/lib.sh"' "$DIR/verify.sh" | cut -d: -f1)
l_cases=$(grep -n 'source "\$SCRIPT_DIR/cases-dml-retention.sh"' "$DIR/verify.sh" | cut -d: -f1)
l_trap=$(grep -n '^trap cleanup EXIT' "$DIR/verify.sh" | cut -d: -f1)
[ -n "$l_lib" ] && [ "$l_lib" -lt "$l_cases" ] && [ "$l_lib" -lt "$l_trap" ] \
  && ok "lib.sh の source が cases と trap より前（$l_lib < $l_cases, $l_trap）" || ng "source の順序（lib=$l_lib cases=$l_cases trap=$l_trap）"

wc -l "$DIR/verify.sh" "$DIR/lib.sh"
exit "$fail"
