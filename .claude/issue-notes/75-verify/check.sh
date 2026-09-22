#!/usr/bin/env bash
# issue #75 の分割（src/results.rs の mod tests を src/results/tests.rs へ移す）が
# 「挙動を変えない移動」であることを機械的に確かめる。#44 の check.sh を元にした。
# 使い方: .claude/issue-notes/75-verify/check.sh [<着手前 SHA>]
# 既定の着手前 SHA は quick ノートのコミット（src は着手前の 9add5d3 と同じ）。
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

BASE="${1:-a1b6919}"
DST=src/results/tests.rs
fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }
ng()   { printf '  \033[31mNG\033[0m   %s\n' "$1"; fail=1; }

echo "== 1. テスト総数（期待 303） =="
total=$(cargo test --locked 2>&1 | grep -oE '^test result: ok\. [0-9]+ passed' | grep -oE '[0-9]+' | paste -sd+ | bc)
[ "$total" = "303" ] && ok "合計 $total" || ng "合計 $total（期待 303）"

echo "== 2. results::tests の件数（期待 19）と、テストがどちらのファイルにあるか =="
# 表示だけでは足りない。モジュール名は移動の前後で results::tests のまま変わらないので、
# 件数だけでは「移動先に入ったか」を区別できない。#[test] の数をファイルごとに数える。
got2=$(cargo test --locked --lib results 2>&1 | grep -cE '^test results::tests::')
[ "$got2" = "19" ] && ok "results::tests $got2 件" || ng "results::tests $got2 件（期待 19）"
in_src=$(grep -c '^\s*#\[test\]' src/results.rs)
if [ -f "$DST" ]; then
  in_dst=$(grep -c '^\s*#\[test\]' "$DST")
  [ "$in_src" = "0" ] && [ "$in_dst" = "19" ] \
    && ok "results.rs に 0 件・tests.rs に $in_dst 件" \
    || ng "results.rs に $in_src 件・tests.rs に $in_dst 件（期待 0 / 19）"
  grep -qE '^#\[cfg\(test\)\]$' src/results.rs && grep -qE '^mod tests;$' src/results.rs \
    && ok "results.rs に #[cfg(test)] mod tests; の宣言がある" \
    || ng "results.rs に #[cfg(test)] mod tests; の宣言が無い（宣言漏れは件数が減るだけで green のまま通る）"
else
  [ "$in_src" = "19" ] && ok "移動前: results.rs に $in_src 件" || ng "移動前: results.rs に $in_src 件（期待 19）"
fi

echo "== 3. src 全体の doc コメント行数（期待 502） =="
docs=$(grep -rc '^\s*///' src/ --include=*.rs | awk -F: '{s+=$2} END {print s}')
[ "$docs" = "502" ] && ok "/// $docs 行" || ng "/// $docs 行（期待 502）"

echo "== 4. 実測記録の全件突き合わせ（missing_docs が無いのでこれでしか気づけない） =="
before=$(mktemp) ; after=$(mktemp)
# before と after は同じ範囲（src 配下の .rs 全部）で取る。
git ls-tree -r --name-only "$BASE" src/ | grep '\.rs$' | while read -r f; do git show "$BASE:$f"; done \
  | grep -E '実測|採取' | sed -E 's/^[[:space:]]+//' | sort > "$before"
find src -name '*.rs' -print0 | xargs -0 cat \
  | grep -E '実測|採取' | sed -E 's/^[[:space:]]+//' | sort > "$after"
if diff -q "$before" "$after" >/dev/null; then
  ok "実測記録 $(wc -l < "$before") 行すべて一致"
else
  ng "実測記録が一致しない:"; diff "$before" "$after" | sed 's/^/    /'
fi
rm -f "$before" "$after"

echo "== 5. 純粋な移動か（use・mod・//!・空行を除いて行をソートして diff） =="
if [ -f "$DST" ]; then
  b=$(mktemp) ; a=$(mktemp)
  # use / mod / //! / 空行を除く。//! は新ファイルに書き足すので移動ではない（中身は目視とレビューで見る）。
  # `mod tests {` と `mod tests;` はどちらも mod で始まるのでここで落ちる。
  strip() { grep -vE '^[[:space:]]*(pub(\([a-z:( )]+\))? )?(use |mod )|^[[:space:]]*//!|^[[:space:]]*$' | sed -E 's/^[[:space:]]+//' | sort ; }
  git show "$BASE:src/results.rs" | strip > "$b"
  cat src/results.rs "$DST" | strip > "$a"
  # 計画が要求する非純粋変更だけを許容リストに入れる: mod tests { ... } の閉じ括弧 1 行が消えるだけ。
  # 許容リストに無い差分が 1 行でも残れば NG。
  allow='^[0-9]+(,[0-9]+)?[acd][0-9]+(,[0-9]+)?$'
  allow="$allow"'|^---$'
  allow="$allow"'|^< \}$'        # mod tests { ... } の閉じ括弧（移動先ではファイル末尾の枠が無くなる）
  raw=$(diff "$b" "$a")
  rest=$(printf '%s\n' "$raw" | grep -vE "$allow")
  if [ -z "$raw" ]; then
    ok "results.rs → results.rs + tests.rs は完全に同一"
  elif [ -z "$rest" ]; then
    ok "results.rs → results.rs + tests.rs は純粋な移動（想定内の差分のみ。内訳は下記）"
    printf '%s\n' "$raw" | sed 's/^/    /'
  else
    ng "results.rs → results.rs + tests.rs に想定外の差分がある:"; printf '%s\n' "$rest" | sed 's/^/    /'
  fi
  rm -f "$b" "$a"
else
  echo "  (skip: $DST はまだ無い)"
fi

echo "== 6. 本体の分岐の計数（期待 17。mod tests { より前の if / match / return / ? を数える） =="
branches=$(awk '/^mod tests \{/ {exit} {print}' src/results.rs | grep -cE '\b(if|match|return)\b|\?[;)]')
[ "$branches" = "17" ] && ok "分岐 $branches" || ng "分岐 $branches（期待 17）"

echo "== 7. results.rs の行数（issue の目標: 400 行以内） =="
lines=$(wc -l < src/results.rs)
if [ -f "$DST" ]; then
  [ "$lines" -le 400 ] && ok "results.rs $lines 行" || ng "results.rs $lines 行（400 行を超えている）"
else
  echo "  (移動前: $lines 行)"
fi

echo "== 8. fmt / clippy =="
cargo fmt --check >/dev/null 2>&1 && ok "fmt" || ng "fmt"
cargo clippy --all-targets --locked -- -D warnings >/dev/null 2>&1 && ok "clippy" || ng "clippy"

echo
[ "$fail" = "0" ] && echo "すべて ok" || echo "NG があります"
exit "$fail"
