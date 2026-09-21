#!/usr/bin/env bash
# issue #44 の分割が「挙動を変えない移動」であることを機械的に確かめる。
# 使い方: .claude/issue-notes/44-verify/check.sh [<着手前 SHA>]
# 既定の着手前 SHA は quick ノートのコミット。
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

BASE="${1:-6ed63dc}"
fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }
ng()   { printf '  \033[31mNG\033[0m   %s\n' "$1"; fail=1; }

echo "== 1. テスト総数（期待 275） =="
total=$(cargo test --locked 2>&1 | grep -oE '^test result: ok\. [0-9]+ passed' | grep -oE '[0-9]+' | paste -sd+ | bc)
[ "$total" = "275" ] && ok "合計 $total" || ng "合計 $total（期待 275）"

echo "== 2. operation のユニットテストの内訳 =="
# 表示だけでは足りない。テストの移動境界を間違えても 1・3・4・5 はすべて ok を返す
# （5 は和集合しか見ないので、どちらのファイルに入っているかを区別しない）。ここだけが検出できる。
if [ -f src/operation/target_table.rs ]; then
  want2="classification:4 query_execution:4 table_format:15 target_table:14"
else
  want2="classification:4 query_execution:4 table_format:29"
fi
got2=$(cargo test --locked --lib operation 2>&1 | grep -oE 'operation::[a-z_]+::tests' | sort | uniq -c \
  | awk '{gsub(/operation::|::tests/, "", $2); printf "%s:%s ", $2, $1}' | sed 's/ $//')
echo "  実際: $got2"
if [ "$got2" = "$want2" ]; then ok "内訳が期待どおり"; else ng "内訳が違う（期待: $want2）"; fi

# チェック 5 はフェーズ 1 の 2 組しか見ない。catalog.rs を触るフェーズ 2 を見るのはここだけなので残す。
echo "== 3. src 全体の doc コメント行数（期待 435） =="
docs=$(grep -rc '^\s*///' src/ --include=*.rs | awk -F: '{s+=$2} END {print s}')
[ "$docs" = "435" ] && ok "/// $docs 行" || ng "/// $docs 行（期待 435）"

echo "== 4. 実測記録の全件突き合わせ（missing_docs が無いのでこれでしか気づけない） =="
before=$(mktemp) ; after=$(mktemp)
# before と after は同じ範囲（src 配下の .rs 全部）で取る。分割は src/operation/ 内で完結するので
# 総数は変わらないはず。片方だけ範囲を狭めると、動いていない行まで差分に出る。
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

echo "== 5. 純粋な移動か（use・mod・空行を除いて行をソートして diff） =="
for pair in "execution.rs:result_output.rs" "table_format.rs:target_table.rs"; do
  src="${pair%%:*}" ; dst="${pair##*:}"
  [ -f "src/operation/$dst" ] || { echo "  (skip: src/operation/$dst はまだ無い)" ; continue ; }
  b=$(mktemp) ; a=$(mktemp)
  # use / mod / //! / 空行を除く。//! は新ファイルに書き足すので移動ではない（中身は目視とレビューで見る）。
  strip() { grep -vE '^[[:space:]]*(pub(\([a-z:( )]+\))? )?(use |mod )|^[[:space:]]*//!|^[[:space:]]*$' | sed -E 's/^[[:space:]]+//' | sort ; }
  git show "$BASE:src/operation/$src" | strip > "$b"
  cat "src/operation/$src" "src/operation/$dst" | strip > "$a"
  # 計画が要求する非純粋変更だけを許容リストに入れる。これを入れないと、計画どおり正しく
  # 実装するほど確実に NG が出る（可視性 2 件・呼び出しの修飾・テストモジュールの枠）。
  # 許容リストに無い差分が 1 行でも残れば NG なので、意図しない可視性変更は引き続き検出できる。
  allow='^[0-9]+(,[0-9]+)?[acd][0-9]+(,[0-9]+)?$'
  allow="$allow"'|^---$'
  allow="$allow"'|^[<>] (pub\(super\) )?async fn write_(result|failure)\('          # 可視性の付与
  allow="$allow"'|^[<>] (result_output::)?write_(result|failure)\(&app'             # 呼び出しの修飾
  allow="$allow"'|^[<>] .*(table_format|target_table)::parse_target_table\($'       # 同上（呼び出しが行の途中にある）
  allow="$allow"'|^[<>] #\[cfg\(test\)\]$|^[<>] mod tests \{$|^[<>] \}$'        # テストモジュールの枠が 1 組 → 2 組
  raw=$(diff "$b" "$a")
  rest=$(printf '%s\n' "$raw" | grep -vE "$allow")
  if [ -z "$raw" ]; then
    ok "$src → $src + $dst は完全に同一"
  elif [ -z "$rest" ]; then
    ok "$src → $src + $dst は純粋な移動（想定内の差分のみ。内訳は下記）"
    printf '%s\n' "$raw" | sed 's/^/    /'
  else
    ng "$src → $src + $dst に想定外の差分がある:"; printf '%s\n' "$rest" | sed 's/^/    /'
  fi
  rm -f "$b" "$a"
done

echo "== 6. fmt / clippy =="
cargo fmt --check >/dev/null 2>&1 && ok "fmt" || ng "fmt"
cargo clippy --all-targets --locked -- -D warnings >/dev/null 2>&1 && ok "clippy" || ng "clippy"

echo
[ "$fail" = "0" ] && echo "すべて ok" || echo "NG があります"
exit "$fail"
