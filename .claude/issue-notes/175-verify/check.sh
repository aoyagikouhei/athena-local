#!/usr/bin/env bash
# issue #175（src/operation/execution.rs の分割）が「挙動を変えない移動」であることを機械的に確かめる。
# #75 の check.sh（src/results.rs → src/results/tests.rs）を元にした。
#
# 計画（フェーズ 1・純粋な移動）:
#   execution.rs の iceberg_partition_specs（doc 込み 351〜379 行）・split_explain_rows（381〜409 行）・
#   update_count（411〜436 行）と、テストモジュール（438 行〜末尾、#[test] 5 件）を新ファイル $DST に移す。
#   mod.rs に `mod completion;` が 1 行増え、移動した 3 関数は pub(super) になる。
# 計画（フェーズ 2・関数の抽出、純粋な移動ではない）:
#   run の前半（形式の問い合わせ）を新ファイル $DST2 の関数に抽出する。
#
# 使い方: .claude/issue-notes/175-verify/check.sh [before|phase1|phase2]
#   モードを省くと、$DST2 → $DST の存在から推測する（明示の引数があればそちらを優先）。
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

# 着手前（src が a34621c と同一のコミット。9a22501 のノートコミットより前）。
BASE="a34621c"
# フェーズ 1 が完了した時点のコミット。phase2 の正規化 diff の比較元（execution.rs + completion.rs）。
# フェーズ 1 をコミットしたらここに SHA を書く（未設定なら phase2 の項目 5 は NG にする）。
PHASE1_SHA="${PHASE1_SHA:-4bbbae7}"

SRC=src/operation/execution.rs
DST=src/operation/completion.rs
DST2=src/operation/format_probe.rs

# --- 着手前に実測して焼き込んだ基準値 ---
# 1. `tools/dev.sh cargo test --locked 2>&1 | grep -oE '^test result: ok\. [0-9]+ passed' | ... | paste -sd+ | bc` → 396
BASE_TOTAL_TESTS=396
# 3. `grep -rc '^\s*///' src/ --include=*.rs | awk -F: '{s+=$2} END {print s}'` → 723
BASE_DOCS=723
# フェーズ 2 で抽出した関数に doc コメントを書いたら、その /// 行数をここに足す（既定 0 = 未実装）。
EXTRA_DOC_PHASE2=2
# 6. `awk '/^mod tests \{/ {exit} {print}' src/operation/execution.rs | grep -cE '\b(if|match|return)\b|\?[;)]'` → 45
BASE_BRANCHES=45

fail=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }
ng()   { printf '  \033[31mNG\033[0m   %s\n' "$1"; fail=1; }

MODE="${1:-}"
if [ -z "$MODE" ]; then
  if [ -f "$DST2" ]; then MODE=phase2
  elif [ -f "$DST" ]; then MODE=phase1
  else MODE=before
  fi
fi
case "$MODE" in
  before|phase1|phase2) ;;
  *) echo "使い方: $0 [before|phase1|phase2]" >&2; exit 2 ;;
esac
echo "モード: $MODE"

echo "== 1. テスト総数（期待 $BASE_TOTAL_TESTS） =="
total=$(tools/dev.sh cargo test --locked 2>&1 | grep -oE '^test result: ok\. [0-9]+ passed' | grep -oE '[0-9]+' | paste -sd+ | bc)
[ "$total" = "$BASE_TOTAL_TESTS" ] && ok "合計 $total" || ng "合計 $total（期待 $BASE_TOTAL_TESTS）"

echo "== 2. operation::execution::tests / operation::completion::tests の件数と、テストがどちらのファイルにあるか =="
# 表示だけでは足りない。件数だけでは「移動先に入ったか」を区別できないので、#[test] の数をファイルごとに数える。
lib_tests=$(tools/dev.sh cargo test --locked --lib 2>&1)
exec_count=$(printf '%s\n' "$lib_tests" | grep -cE '^test operation::execution::tests::')
comp_count=$(printf '%s\n' "$lib_tests" | grep -cE '^test operation::completion::tests::')
if [ "$MODE" = "before" ]; then want_exec=5; want_comp=0; else want_exec=0; want_comp=5; fi
[ "$exec_count" = "$want_exec" ] && ok "operation::execution::tests $exec_count 件" || ng "operation::execution::tests $exec_count 件（期待 $want_exec）"
[ "$comp_count" = "$want_comp" ] && ok "operation::completion::tests $comp_count 件" || ng "operation::completion::tests $comp_count 件（期待 $want_comp）"

exec_attr=$(grep -c '^\s*#\[test\]' "$SRC")
if [ -f "$DST" ]; then dst_attr=$(grep -c '^\s*#\[test\]' "$DST"); else dst_attr=0; fi
if [ "$MODE" = "before" ]; then want_exec_attr=5; want_dst_attr=0; else want_exec_attr=0; want_dst_attr=5; fi
[ "$exec_attr" = "$want_exec_attr" ] && ok "execution.rs の #[test] $exec_attr 件" || ng "execution.rs の #[test] $exec_attr 件（期待 $want_exec_attr）"
[ "$dst_attr" = "$want_dst_attr" ] && ok "$DST の #[test] $dst_attr 件" || ng "$DST の #[test] $dst_attr 件（期待 $want_dst_attr）"

if [ "$MODE" = "before" ]; then
  echo "  (skip: #[cfg(test)] 残存・mod tests・mod completion; の確認は phase1 以降のみ)"
else
  if grep -qE '^#\[cfg\(test\)\]$' "$SRC"; then
    ng "execution.rs に #[cfg(test)] が残っている"
  else
    ok "execution.rs に #[cfg(test)] が残っていない"
  fi
  if [ -f "$DST" ] && grep -qE '^\s*mod tests \{' "$DST"; then
    ok "$DST に mod tests がある"
  else
    ng "$DST に mod tests が無い"
  fi
  if grep -qE '^mod completion;$' src/operation/mod.rs; then
    ok "mod.rs に mod completion; がある"
  else
    ng "mod.rs に mod completion; が無い"
  fi
  if [ "$MODE" = "phase2" ]; then
    if grep -qE '^mod format_probe;$' src/operation/mod.rs && [ -f "$DST2" ]; then
      ok "mod.rs に mod format_probe; があり $DST2 がある"
    else
      ng "mod.rs に mod format_probe; が無いか $DST2 が無い"
    fi
    dst2_attr=$(grep -c '^\s*#\[test\]' "$DST2" 2>/dev/null || true)
    [ "${dst2_attr:-0}" = "0" ] && ok "$DST2 に #[test] は無い（抽出なのでテストは足さない）" || ng "$DST2 に #[test] が ${dst2_attr} 件ある（計画では 0）"
  fi
fi

echo "== 3. src 全体の doc コメント行数 =="
docs=$(grep -rc '^\s*///' src/ --include=*.rs | awk -F: '{s+=$2} END {print s}')
case "$MODE" in
  before|phase1) want_docs=$BASE_DOCS ;;
  phase2) want_docs=$((BASE_DOCS + EXTRA_DOC_PHASE2)) ;;
esac
[ "$docs" = "$want_docs" ] && ok "/// $docs 行" || ng "/// $docs 行（期待 $want_docs）"

echo "== 4. 実測記録の全件突き合わせ =="
# grep は行の中身で拾うので //! のモジュール doc も対象になる。新しく書くモジュール doc
# （completion.rs・probe.rs の //!）に「実測」「採取」を含めないこと（含めると before に無い行が
# 増えて必ず不一致になる。この一致確認だけが唯一の歯止め）。
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

echo "== 5. 正規化 diff（phase1: 着手前の execution.rs → execution.rs + $DST、phase2: フェーズ 1 の execution.rs + $DST → + $DST2） =="
# use / mod / //! / 空行を除き、行頭の空白を落としてソートして比べる。//! は新ファイルに書き足すので移動ではない（中身は目視）。
strip() { grep -vE '^[[:space:]]*(pub(\([a-z:( )]+\))? )?(use |mod )|^[[:space:]]*//!|^[[:space:]]*$' | sed -E 's/^[[:space:]]+//' | sort ; }
# 修飾や pub(super) で行が 100 桁を超えると cargo fmt が宣言・呼び出しを複数行に折り返す。
# 対象の関数の宣言と呼び出しだけを 1 行に戻してから strip に渡す（折り返されていなければ何もしない）。
FN='(?:update_count|split_explain_rows|iceberg_partition_specs|probe_target_format)'
join_calls() {
  FN="$FN" perl -0777 -pe '
    my $fn = $ENV{FN};
    s{((?:pub\(super\)\s+)?(?:async\s+)?fn\s+$fn\s*\()(.*?)(\)\s*(?:->\s*(?:\([^\{]*?\)|[^\{(]+?))?\s*\{)}{
      my ($pre,$mid,$post)=($1,$2,$3);
      $mid =~ s/\s+/ /g; $mid =~ s/^\s+|\s+$//g; $mid =~ s/,\s*$//;
      $post =~ s/\s+/ /g; $post =~ s/^\s+//; $post =~ s/\(\s+/(/g; $post =~ s/,\s*\)/)/g;
      "$pre$mid$post";
    }gesx;
    s{((?:completion|format_probe)::$fn\s*\()(.*?)(\)(?:\s*\.await)?)}{
      my ($pre,$mid,$post)=($1,$2,$3);
      $mid =~ s/\s+/ /g; $mid =~ s/^\s+|\s+$//g; $mid =~ s/,\s*$//;
      $post =~ s/\s+//g;
      "$pre$mid$post";
    }gesx;
    s{(=)\n\s*((?:completion|format_probe)::$fn)}{$1 $2}g;
  '
}
# 許容する差分を行ごとに名指しする。広げない（テストの中の呼び出し行が消えても通るような形にしない）。
normalized_diff() {  # $1 = 比較元の strip 済み, $2 = 比較先の strip 済み, $3 = 許容する < の正規表現, $4 = 許容する > の正規表現, $5 = < の期待件数, $6 = > の上限件数
  local raw rest n_del n_add
  raw=$(diff "$1" "$2" | grep -E '^[<>] ')
  rest=$(printf '%s\n' "$raw" | grep -E '^[<>] ' | grep -vE "$3|$4")
  n_del=$(printf '%s\n' "$raw" | grep -cE '^< ' || true)
  n_add=$(printf '%s\n' "$raw" | grep -cE '^> ' || true)
  if [ -n "$rest" ]; then
    ng "想定外の差分がある:"; printf '%s\n' "$rest" | sed 's/^/    /'
  elif [ "$n_del" != "$5" ] || [ "$n_add" -gt "$6" ]; then
    ng "許容した差分の件数が合わない（< $n_del 件、期待 $5 件 / > $n_add 件、上限 $6 件）:"; printf '%s\n' "$raw" | sed 's/^/    /'
  else
    ok "純粋な移動（許容した差分 < $n_del 件・> $n_add 件。内訳は下記）"; printf '%s\n' "$raw" | sed 's/^/    /'
  fi
}
b=$(mktemp); a=$(mktemp)
case "$MODE" in
  before)
    echo "  (skip: $DST はまだ無い)" ;;
  phase1)
    git show "$BASE:$SRC" | join_calls | strip > "$b"
    cat "$SRC" "$DST" | join_calls | strip > "$a"
    # < は宣言 3 行と呼び出し 3 行だけ（ちょうど 6 件）。> は同じ 6 行に pub(super) か completion:: が付いたもの。
    del='^< ((async )?fn (update_count|split_explain_rows|iceberg_partition_specs)\(|let update_count = update_count\(&execution\.query, &outcome, engine_ddl\);$|let outcome = split_explain_rows\(&execution\.query, outcome\);$|iceberg_partition_specs\(trino, config, &execution\.query, catalog, database, cancel\)\.await$)'
    add='^> (pub\(super\) (async )?fn (update_count|split_explain_rows|iceberg_partition_specs)\(|let update_count = completion::update_count\(&execution\.query, &outcome, engine_ddl\);$|let outcome = completion::split_explain_rows\(&execution\.query, outcome\);$|completion::iceberg_partition_specs\(trino, config, &execution\.query, catalog, database, cancel\)\.await$)'
    normalized_diff "$b" "$a" "$del" "$add" 6 6 ;;
  phase2)
    if [ -z "$PHASE1_SHA" ]; then
      ng "PHASE1_SHA が未設定（フェーズ 1 のコミットを比較元にする）"
    else
      { git show "$PHASE1_SHA:$SRC"; git show "$PHASE1_SHA:$DST"; } | join_calls | strip > "$b"
      cat "$SRC" "$DST" "$DST2" | join_calls | strip > "$a"
      # ブロックは本文のまま運ぶので < は 0 件。> は新しい関数の宣言・doc・末尾のタプル・閉じ括弧と、run 側の呼び出しだけ。
      del='^<$'
      add='^> (pub\(super\) async fn probe_target_format\(trino: &Trino, config: &Config, execution: &Execution, raw_catalog: Option<&str>, database: Option<&str>, cancel: &Cancel\) -> \(Option<table_format::TargetStatement>, Option<table_format::TableFormat>, Option<EngineDdl>, Option<&'"'"'static str>\) \{$|/// .*|\(statement, format, engine_ddl, substatement_type\)$|\}$|let \(statement, format, engine_ddl, substatement_type\) = format_probe::probe_target_format\(trino, config, execution, raw_catalog, database, cancel\)\.await;$)'
      normalized_diff "$b" "$a" "$del" "$add" 0 $((4 + EXTRA_DOC_PHASE2))
    fi ;;
esac
rm -f "$b" "$a"

echo "== 6. 本体の分岐の計数（if/match/return/? の合計。期待 $BASE_BRANCHES） =="
count_branches() {
  local f="$1"
  [ -f "$f" ] || { echo 0; return; }
  awk '/^mod tests \{/ {exit} {print}' "$f" | grep -cE '\b(if|match|return)\b|\?[;)]'
}
b1=$(count_branches "$SRC")
b2=$(count_branches "$DST")
b3=$(count_branches "$DST2")
total_branches=$((b1 + b2 + b3))
if [ "$total_branches" = "$BASE_BRANCHES" ]; then
  ok "分岐 合計 $total_branches（$SRC=$b1 / $DST=$b2 / $DST2=$b3）"
else
  ng "分岐 合計 $total_branches（期待 $BASE_BRANCHES。$SRC=$b1 / $DST=$b2 / $DST2=$b3。phase2 の関数抽出で ? 等が変わる想定は無いので、変わっていたら diff を目視すること）"
fi

echo "== 7. execution.rs の行数（phase1 以降は 400 行以下） =="
lines=$(wc -l < "$SRC")
if [ "$MODE" = "before" ]; then
  echo "  (skip: before は対象外。現在 $lines 行)"
else
  [ "$lines" -le 400 ] && ok "execution.rs $lines 行" || ng "execution.rs $lines 行（400 行を超えている）"
fi

echo "== 8. fmt / clippy =="
tools/dev.sh cargo fmt --check >/dev/null 2>&1 && ok "fmt" || ng "fmt"
tools/dev.sh cargo clippy --all-targets --locked -- -D warnings >/dev/null 2>&1 && ok "clippy" || ng "clippy"

echo
[ "$fail" = "0" ] && echo "すべて ok" || echo "NG があります"
exit "$fail"
