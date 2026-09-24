#!/usr/bin/env bash
# issue #162（operation/ の 3 ファイルのテストを子モジュールに出し、EngineDdl を改名する）が
# 「挙動を変えない移動」と「改名」であることを機械的に確かめる。
# #75（.claude/issue-notes/75-verify/check.sh。src/results.rs → src/results/tests.rs 1 本）と
# #175（.claude/issue-notes/175-verify/check.sh。許容リストを名指しで絞る書き方）を元にした。
#
# このスクリプト自身は tools/dev.sh 経由で toolbox の中で動かす前提で書いてあるので、
# 中では cargo / cargo fmt / cargo clippy を直に呼ぶ（CLAUDE.md「検証の足場は tools/dev.sh 経由」）。
#
# 使い方:
#   tools/dev.sh .claude/issue-notes/162-verify/check.sh phase1 [<着手前 SHA>]
#     フェーズ 1（移動）の検証。着手前 SHA の既定は e1b85f0（issue #162 着手前。src は quick ノートの
#     コミット 059d14d でも同じ）。3 ファイルのうち移動が済んでいないものは該当項目を skip と表示する。
#
#   tools/dev.sh RENAME_TYPE=<新しい型名> RENAME_FN=<新しい関数名> \
#     .claude/issue-notes/162-verify/check.sh phase3 <改名前 SHA> [<新しい型名> <新しい関数名>]
#     フェーズ 3（改名）の検証。改名前の SHA は必須（引数で受け取る）。新しい型名・関数名は
#     環境変数 RENAME_TYPE / RENAME_FN でも、phase3 の後ろの位置引数でも渡せる（位置引数が優先）。
#     旧名は既定で EngineDdl / engine_ddl（RENAME_TYPE_OLD / RENAME_FN_OLD で上書きできる）。
#     doc・コメントの文言だけの差分を許容したいときは RENAME_DOC_ALLOW に拡張正規表現を渡す
#     （diff -ru の `+`/`-` 行にマッチした行だけを許容する。既定は空 = 一切の差分を許さない）。
#     型名・関数名から決まらない別名（定数など）は RENAME_EXTRA="新=旧 ..." で対を渡す。
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }
ng()   { printf '  \033[31mNG\033[0m   %s\n' "$1"; fail=1; }
skip() { printf '  \033[33mskip\033[0m %s\n' "$1"; }

MODE="${1:-phase1}"
case "$MODE" in
  phase1|phase3) ;;
  *) echo "使い方: $0 [phase1|phase3] ..." >&2; exit 2 ;;
esac
echo "モード: $MODE"

# =====================================================================================
# フェーズ 1: 移動
# =====================================================================================
run_phase1() {
  local BASE="${1:-e1b85f0}"
  # --- 着手前（$BASE）に実測して焼き込んだ基準値（.claude/issue-notes/162.md）---
  local BASE_TOTAL_TESTS=396
  local BASE_DOCS=725
  # 対象 3 ファイル。移動先は src/operation/<name>/tests.rs（mod.rs 無し）。
  local NAMES=(classification target_table table_format)
  local TEST_COUNTS=(8 21 20)
  local BRANCH_COUNTS=(32 16 8)

  echo "着手前 SHA: $BASE"

  echo "== 1. テスト総数（期待 $BASE_TOTAL_TESTS） =="
  local total
  total=$(cargo test --locked 2>&1 | grep -oE '^test result: ok\. [0-9]+ passed' | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}')
  [ "$total" = "$BASE_TOTAL_TESTS" ] && ok "合計 $total" || ng "合計 $total（期待 $BASE_TOTAL_TESTS）"

  echo "== 2. 各ファイルの operation::<name>::tests の件数と、テストがどちらのファイルにあるか =="
  local lib_tests
  lib_tests=$(cargo test --locked --lib operation:: 2>&1)
  local i name expect_n src dst moved got_mod got_src_attr got_dst_attr
  for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"
    expect_n="${TEST_COUNTS[$i]}"
    src="src/operation/${name}.rs"
    dst="src/operation/${name}/tests.rs"
    if [ -f "$dst" ]; then moved=1; else moved=0; fi

    got_mod=$(printf '%s\n' "$lib_tests" | grep -cE "^test operation::${name}::tests::")
    [ "$got_mod" = "$expect_n" ] \
      && ok "operation::${name}::tests $got_mod 件" \
      || ng "operation::${name}::tests $got_mod 件（期待 $expect_n）"

    got_src_attr=$(grep -cE '^\s*#\[(tokio::)?test\]' "$src")
    if [ "$moved" = "1" ]; then
      got_dst_attr=$(grep -cE '^\s*#\[(tokio::)?test\]' "$dst")
      if [ "$got_src_attr" = "0" ] && [ "$got_dst_attr" = "$expect_n" ]; then
        ok "$name: ${src} に 0 件・${dst} に $got_dst_attr 件"
      else
        ng "$name: ${src} に $got_src_attr 件・${dst} に $got_dst_attr 件（期待 0 / $expect_n）"
      fi
      if grep -qE '^#\[cfg\(test\)\]$' "$src" && grep -qE '^mod tests;$' "$src"; then
        ok "$name: ${src} に #[cfg(test)] / mod tests; の宣言がある"
      else
        ng "$name: ${src} に #[cfg(test)] / mod tests; の宣言が無い（宣言漏れは件数が減るだけで green のまま通る）"
      fi
      if [ -f "src/operation/${name}/mod.rs" ]; then
        ng "$name: src/operation/${name}/mod.rs がある（mod.rs 無しの子モジュールにする計画）"
      else
        ok "$name: mod.rs が無い"
      fi
      if head -n1 "$dst" | grep -qE '^//!'; then
        ok "$name: ${dst} の先頭が //! で始まる"
      else
        ng "$name: ${dst} の先頭が //! で始まっていない"
      fi
    else
      [ "$got_src_attr" = "$expect_n" ] \
        && ok "$name: 移動前 ${src} に $got_src_attr 件" \
        || ng "$name: 移動前 ${src} に $got_src_attr 件（期待 $expect_n）"
    fi
  done

  echo "== 3. src 全体の doc コメント行数（期待 $BASE_DOCS） =="
  local docs
  docs=$(grep -rc '^\s*///' src/ --include=*.rs | awk -F: '{s+=$2} END {print s}')
  [ "$docs" = "$BASE_DOCS" ] && ok "/// $docs 行" || ng "/// $docs 行（期待 $BASE_DOCS）"

  echo "== 4. 実測記録の全件突き合わせ（着手前 $BASE と作業ツリー） =="
  local before_f after_f
  before_f=$(mktemp); after_f=$(mktemp)
  git ls-tree -r --name-only "$BASE" src/ | grep '\.rs$' | while read -r f; do git show "$BASE:$f"; done \
    | grep -E '実測|採取' | sed -E 's/^[[:space:]]+//' | sort > "$before_f"
  find src -name '*.rs' -print0 | xargs -0 cat \
    | grep -E '実測|採取' | sed -E 's/^[[:space:]]+//' | sort > "$after_f"
  if diff -q "$before_f" "$after_f" >/dev/null; then
    ok "実測記録 $(wc -l < "$before_f") 行すべて一致"
  else
    ng "実測記録が一致しない:"; diff "$before_f" "$after_f" | sed 's/^/    /'
  fi
  rm -f "$before_f" "$after_f"

  echo "== 5. 純粋な移動か（ファイルごとに、use・mod・//!・空行を除いて行をソートして diff） =="
  local strip='grep -vE '\''^[[:space:]]*(pub(\([a-z:( )]+\))? )?(use |mod )|^[[:space:]]*//!|^[[:space:]]*$'\'' | sed -E '\''s/^[[:space:]]+//'\'' | sort'
  local b a raw rest allow
  for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"
    src="src/operation/${name}.rs"
    dst="src/operation/${name}/tests.rs"
    if [ -f "$dst" ]; then
      b=$(mktemp); a=$(mktemp)
      git show "$BASE:src/operation/${name}.rs" | eval "$strip" > "$b"
      cat "$src" "$dst" | eval "$strip" > "$a"
      # 計画が要求する非純粋変更だけを許容リストに入れる: mod tests { ... } の閉じ括弧 1 行が
      # 消えるだけ（#75 と同じ形）。許容リストに無い差分が 1 行でも残れば NG。
      allow='^[0-9]+(,[0-9]+)?[acd][0-9]+(,[0-9]+)?$'
      allow="$allow"'|^---$'
      allow="$allow"'|^< \}$'
      raw=$(diff "$b" "$a")
      rest=$(printf '%s\n' "$raw" | grep -vE "$allow")
      if [ -z "$raw" ]; then
        ok "$name: ${src} → ${src} + ${dst} は完全に同一"
      elif [ -z "$rest" ]; then
        ok "$name: ${src} → ${src} + ${dst} は純粋な移動（想定内の差分のみ）"
      else
        ng "$name: ${src} → ${src} + ${dst} に想定外の差分がある:"; printf '%s\n' "$rest" | sed 's/^/    /'
      fi
      rm -f "$b" "$a"
    else
      skip "$name: ${dst} はまだ無い"
    fi
  done

  echo "== 6. 本体（mod tests { より前）の分岐の計数（if/match/return/? の合計） =="
  for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"
    src="src/operation/${name}.rs"
    local expect_b="${BRANCH_COUNTS[$i]}"
    local branches
    branches=$(awk '/^mod tests \{/ {exit} {print}' "$src" | grep -cE '\b(if|match|return)\b|\?[;)]')
    [ "$branches" = "$expect_b" ] \
      && ok "$name: 分岐 $branches" \
      || ng "$name: 分岐 $branches（期待 $expect_b）"
  done

  echo "== 7. 各元ファイルの行数（移動後は 400 行以下） =="
  for i in "${!NAMES[@]}"; do
    name="${NAMES[$i]}"
    src="src/operation/${name}.rs"
    dst="src/operation/${name}/tests.rs"
    local lines
    lines=$(wc -l < "$src")
    if [ -f "$dst" ]; then
      [ "$lines" -le 400 ] && ok "$name: ${src} $lines 行" || ng "$name: ${src} $lines 行（400 行を超えている）"
    else
      skip "$name: 移動前（現在 $lines 行）"
    fi
  done

  echo "== 8. fmt / clippy =="
  cargo fmt --check >/dev/null 2>&1 && ok "fmt" || ng "fmt"
  cargo clippy --all-targets --locked -- -D warnings >/dev/null 2>&1 && ok "clippy" || ng "clippy"
}

# =====================================================================================
# フェーズ 3: 改名（EngineDdl / engine_ddl → 新名）
# =====================================================================================
run_phase3() {
  local BASE="${1:-}"
  if [ -z "$BASE" ]; then
    ng "phase3 には改名前の SHA が要る: $0 phase3 <改名前 SHA> [<新しい型名> <新しい関数名>]"
    return
  fi
  local OLD_TYPE="${RENAME_TYPE_OLD:-EngineDdl}"
  local OLD_FN="${RENAME_FN_OLD:-engine_ddl}"
  local NEW_TYPE="${2:-${RENAME_TYPE:-}}"
  local NEW_FN="${3:-${RENAME_FN:-}}"
  if [ -z "$NEW_TYPE" ] || [ -z "$NEW_FN" ]; then
    ng "新しい型名・関数名が未指定（RENAME_TYPE / RENAME_FN か、位置引数 3・4 で渡す）"
    return
  fi
  echo "改名前 SHA: $BASE / $OLD_TYPE → $NEW_TYPE / $OLD_FN → $NEW_FN"

  echo "== 1. 新名を旧名に戻すと、改名前 SHA の src と 1 バイトも変わらないか =="
  local tmp_before tmp_after raw rest allow
  tmp_before=$(mktemp -d); tmp_after=$(mktemp -d)
  git archive "$BASE" -- src | tar -x -C "$tmp_before"
  mkdir -p "$tmp_after/src"
  cp -r src/. "$tmp_after/src/"
  # 単語境界（\b）では snake_case の複合識別子（例: engine_ddl_は_drop_table_と... という
  # テスト関数名）の先頭に来た旧名を捉えられない（`_` は \b の外側では非境界）。テスト関数名も
  # 対象の関数名にちなんで付けているので、素の部分文字列置換にする（実測で確認。空リポジトリの
  # 識別子は衝突しない前提。新名の選び方は運用側の責任）。
  find "$tmp_after/src" -name '*.rs' -print0 \
    | xargs -0 sed -i -e "s/${NEW_TYPE}/${OLD_TYPE}/g" -e "s/${NEW_FN}/${OLD_FN}/g" \
      -e "s/${NEW_FN^^}/${OLD_FN^^}/g"
  # 型名・関数名から機械的に決まらない名前（定数を意味に合わせて別名にしたとき）は
  # RENAME_EXTRA="新=旧 新=旧" で対を渡す。上の置換より前に当てる必要は無い（新名は旧名を含まない前提）。
  local pair
  for pair in ${RENAME_EXTRA:-}; do
    find "$tmp_after/src" -name '*.rs' -print0 | xargs -0 sed -i -e "s/${pair%%=*}/${pair#*=}/g"
  done
  # 最後の置換は定数の綴り（ENGINE_DDL_CONTENT_TYPE。result_output.rs:15）。型名と関数名の
  # 置換は大文字小文字を区別するので、これが無いと定数の改名を戻せず、改名し忘れても素通りする。
  # 新名は旧名と長さが違うので、改名後の fmt が行の折り返しを変える（例: match の腕が 1 行に
  # 収まらなくなる）。旧名に戻しただけでは折り返しが改名後の形のまま残り、正しい改名でも NG に
  # なるので、戻した木を rustfmt に通してから比べる（改名前 SHA は fmt 済み。CI の fmt --check）。
  (cd "$tmp_after" && find src -name '*.rs' -print0 | xargs -0 rustfmt --edition 2024 >/dev/null 2>&1) \
    || ng "旧名に戻した木が rustfmt を通らない"
  raw=$(diff -ru "$tmp_before/src" "$tmp_after/src" 2>&1 || true)
  if [ -z "$raw" ]; then
    ok "改名前 SHA ($BASE) の src と 1 バイトも変わらない"
  else
    allow="${RENAME_DOC_ALLOW:-}"
    if [ -n "$allow" ]; then
      rest=$(printf '%s\n' "$raw" | grep -E '^[+-][^+-]' | grep -vE "$allow")
    else
      rest=$(printf '%s\n' "$raw" | grep -E '^[+-][^+-]')
    fi
    if [ -z "$rest" ]; then
      ok "改名前 SHA と 1 バイトも変わらない（RENAME_DOC_ALLOW にマッチする差分のみ）"
      printf '%s\n' "$raw" | sed 's/^/    /'
    else
      ng "改名前 SHA と src が一致しない:"; printf '%s\n' "$rest" | sed 's/^/    /'
    fi
  fi
  rm -rf "$tmp_before" "$tmp_after"

  echo "== 2. 旧名（$OLD_TYPE / $OLD_FN）が src/・tests/ に残っていないか =="
  # 単語境界ではなく部分文字列一致（項目 1 の置換と同じ理由。テスト関数名の接頭辞にも旧名が残っていないか見る）。
  local hits
  # 大文字小文字を区別しない（定数の ENGINE_DDL_* も拾う）。
  hits=$(grep -rniE "(${OLD_TYPE}|${OLD_FN})" src/ tests/ --include=*.rs 2>/dev/null || true)
  if [ -z "$hits" ]; then
    ok "旧名 0 件"
  else
    ng "旧名が残っている:"; printf '%s\n' "$hits" | sed 's/^/    /'
  fi

  echo "== 3. テスト総数（期待 396。改名でテストは増減しない） =="
  local total
  total=$(cargo test --locked 2>&1 | grep -oE '^test result: ok\. [0-9]+ passed' | grep -oE '[0-9]+' | awk '{s+=$1} END {print s+0}')
  [ "$total" = "396" ] && ok "合計 $total" || ng "合計 $total（期待 396）"

  echo "== 4. fmt / clippy =="
  cargo fmt --check >/dev/null 2>&1 && ok "fmt" || ng "fmt"
  cargo clippy --all-targets --locked -- -D warnings >/dev/null 2>&1 && ok "clippy" || ng "clippy"
}

case "$MODE" in
  phase1) run_phase1 "${2:-}" ;;
  phase3) run_phase3 "${2:-}" "${3:-}" "${4:-}" ;;
esac

echo
[ "$fail" = "0" ] && echo "すべて ok" || echo "NG があります"
exit "$fail"
