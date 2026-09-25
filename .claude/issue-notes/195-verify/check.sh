#!/usr/bin/env bash
# #195 の検証の足場。散らばった SQL の文の判定を crate の API に寄せる（本体を書き換える）ので、#194 の正規化 diff は使えない。
# 代わりに「消えても green のままになるもの」（既存のテスト・記録の行・doc）と、挙動を変えない証拠（tests/ 無差分）を合否付きで確かめる。
# #194 の足場（PR #198 の履歴 `.claude/issue-notes/194-verify/check.sh`。この場に `check-194.sh` として復元）の項目 1・3・4・6・7b・9 を借りた。
#
# 使い方（リポジトリの中で。cargo はホストでも toolbox（tools/dev.sh）でもよい）:
#   .claude/issue-notes/195-verify/check.sh                       # 着手前のツリーでも各フェーズの後でも同じ形で流す
#   SKIP_CARGO=1 .claude/issue-notes/195-verify/check.sh          # 足場の壊し試験用: cargo を使う 1・4 を飛ばす（受け入れ判定には使わない）
#   P2A=1 .claude/issue-notes/195-verify/check.sh                 # フェーズ 2a（crate の純粋な分割）の後: 8 の正規化 diff も判定する
#   REMOVED_NAMES='skip_qualified_name|read_name_part' ...        # 消した関数名。P6 の後だけ渡す（doc の参照の追随が P6 なので、それより前は必ず NG になる）
#
# 期待値のファイル（計画が「消す・移す・改名する」と決めたぶんだけ、そのフェーズで書き換える。それ以外の変更は事故）:
#   baseline-test-names.txt   着手前の 398 本（バイナリ + 名前）。書き換えない（記録）
#   expected-test-names.txt   今の期待名。P2a でテストを移す 15 行をモジュールのパス付きに、P3 で改名する 6 行を新しい名前に書き換える。ALLOW の正規表現は使わない
#                             （広く外すと監視から抜ける。計画レビュー 2-1・3-1）
#   record-allow.txt          消える・文言を変える記録の行（字下げを除いた行そのもの）。P3 と P6 で計画に列挙した行だけを足す（計画レビュー 1-1・3-2）
#
# 項目:
#   1 `cargo test --locked` が通り、`expected-test-names.txt` の全行が実際のテスト名（バイナリ + モジュールのパス + 名前）に完全一致で存在する。増えるのはよい
#   2 記録の行（「実測」「採取」「計画攻撃」「レビュー」「issue #」「#<番号>」を含む `///`・`//!`・`//` の行）が、着手前の対象ファイル群から `record-allow.txt` に無い限り 1 行も消えていない
#     （対象ファイル群 + crates/athena-sql/src/ の全ファイルの和集合。行全体で比べるので文言の変更も検出する。同じ文の行は 1 つにまとまる）
#   3 `///` の総行数が着手前以上（doc の取りこぼし。増えるのはよい）
#   4 cargo fmt --check と cargo clippy --all-targets --locked -D warnings
#   5 Cargo.lock に差分が無い（crate に外部依存を足さない）
#   6 `tests/` に差分が無い（issue の完了条件「既存のテストを変えずに通す」）
#   7 [REMOVED_NAMES] 消した関数名の残骸が src/・crates/・docs/dev/・CLAUDE.md に無い（未追跡のファイルも見る。`.claude/` は除く）。
#     `skip_keyword` は既存テストの記録の行（classification/tests.rs:218、target_table/tests.rs:385）が指すので渡せない。P4 で `git grep -n 'fn skip_keyword' crates` が 0 件であることを記録に残す
#   8 [P2A=1] 正規化 diff: `use`・`mod`・`pub use`・`//!`・空行・`#[cfg(test)]`・単独の括弧を除き、字下げを潰して行をソートし、着手前の lib.rs と crate の全ファイルを比べる。
#     それ以外の差分が 1 行でも残れば NG（純粋な移動の証拠。可視性の変更は無い: 移す関数は既に `pub fn`、`skip_name_part` は private のまま呼び出し元と一緒に移る）
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"
HERE=.claude/issue-notes/195-verify
BASE_SHA=76e66f8ed52ffbe48492ab80ce41f32f38bd4752
SKIP_CARGO="${SKIP_CARGO:-0}"
P2A="${P2A:-0}"
REMOVED_NAMES="${REMOVED_NAMES:-}"
WORK="$(mktemp -d)"
keep_work=0
cleanup() { if [ "$keep_work" = 1 ]; then echo "証跡を残す: $WORK"; else rm -rf "$WORK"; fi; }
trap cleanup EXIT

fail=0
ok()   { echo "ok   $1"; }
ng()   { echo "NG   $1"; fail=1; }
skip() { echo "skip $1"; }

# 判定を持つ対象ファイル（着手前に存在するもの）。crate 側は分割で増えるので、現在のツリーでは crates/athena-sql/src/ の全 .rs を和集合に入れる。
BASE_FILES=(
  crates/athena-sql/src/lib.rs
  src/operation/classification.rs src/operation/classification/tests.rs
  src/results.rs src/results/tests.rs
  src/content_type.rs
  src/operation/target_table.rs src/operation/target_table/tests.rs
  src/operation/completion.rs
  src/operation/result_output.rs
  src/operation/table_format.rs src/operation/table_format/tests.rs
)
: >"$WORK/base.rs"
for f in "${BASE_FILES[@]}"; do git show "$BASE_SHA:$f" >>"$WORK/base.rs"; done
: >"$WORK/now.rs"
for f in "${BASE_FILES[@]}"; do [ -f "$f" ] && cat "$f" >>"$WORK/now.rs"; done
find crates/athena-sql/src -name '*.rs' ! -path 'crates/athena-sql/src/lib.rs' -exec cat {} + >>"$WORK/now.rs" 2>/dev/null

# --- 1: テストが通り、既存のテスト名が消えていない ---------------------------------
if [ "$SKIP_CARGO" = 1 ]; then
  skip "1 テストの総数と既存テスト名（SKIP_CARGO=1）"
else
  cargo test --locked >"$WORK/test.log" 2>&1; test_exit=$?
  # cargo は `Running unittests` のパスを package 相対で出す（crate も `src/lib.rs`）ので、括弧の中のバイナリ名で package を見分ける。
  awk '
    /^ +Running / { line=$0; sub(/^ +Running /, "", line); target=line; sub(/ \(.*$/, "", target);
                    pkg = (line ~ /athena_sql-[0-9a-f]+\)$/) ? "athena_sql" : "athena_local"; next }
    /^ +Doc-tests / { target=$0; sub(/^ +/, "", target); pkg = (target ~ /athena_sql$/) ? "athena_sql" : "athena_local"; next }
    /^test .* \.\.\. ok$/ { print target " [" pkg "] " $2 }
  ' "$WORK/test.log" | sort >"$WORK/names.txt"
  total=$(grep -E '^test result: ok' "$WORK/test.log" | sed -E 's/^test result: ok\. ([0-9]+) passed.*/\1/' | awk '{ s += $1 } END { print s + 0 }')
  if [ "$test_exit" -ne 0 ]; then
    ng "1 cargo test --locked が失敗した（exit $test_exit）。$WORK/test.log"
    grep -E '^test .* FAILED|^error' "$WORK/test.log" | head -5
    keep_work=1
  else
    sort "$HERE/expected-test-names.txt" >"$WORK/expect.txt"
    comm -23 "$WORK/expect.txt" "$WORK/names.txt" >"$WORK/missing.txt"
    if [ -s "$WORK/missing.txt" ]; then
      ng "1 期待するテストが $(wc -l <"$WORK/missing.txt") 本無い（合計 $total 本）"; head -10 "$WORK/missing.txt"; keep_work=1
    else
      ok "1 cargo test --locked $total 本（期待する $(wc -l <"$WORK/expect.txt") 本は全部ある。着手前 $(wc -l <"$HERE/baseline-test-names.txt") 本）"
    fi
  fi
fi

# --- 2: 記録の行 ------------------------------------------------------------------
records() { grep -E '^\s*(///|//!|//)' "$1" | grep -E '実測|採取|計画攻撃|レビュー|issue #|#[0-9]+' | sed 's/^ *//' | sort -u; }
records "$WORK/base.rs" >"$WORK/base-records-all.txt"
sed 's/^ *//' "$HERE/record-allow.txt" | grep -v '^$' | sort -u >"$WORK/record-allow.txt"
# 許容の行は着手前に実在するものだけ（実在しない行を書いても効かない = 書き間違いに気づける）。
comm -13 "$WORK/base-records-all.txt" "$WORK/record-allow.txt" >"$WORK/record-allow-unknown.txt"
comm -23 "$WORK/base-records-all.txt" "$WORK/record-allow.txt" >"$WORK/base-records.txt"
records "$WORK/now.rs" >"$WORK/now-records.txt"
comm -23 "$WORK/base-records.txt" "$WORK/now-records.txt" >"$WORK/records-missing.txt"
if [ -s "$WORK/record-allow-unknown.txt" ]; then
  ng "2 record-allow.txt に着手前に存在しない行がある（$(wc -l <"$WORK/record-allow-unknown.txt") 行）"; head -5 "$WORK/record-allow-unknown.txt"; keep_work=1
elif [ -s "$WORK/records-missing.txt" ]; then
  ng "2 記録の行が $(wc -l <"$WORK/records-missing.txt") 行消えている（着手前 $(wc -l <"$WORK/base-records-all.txt") 行、許容 $(wc -l <"$WORK/record-allow.txt") 行）"; head -10 "$WORK/records-missing.txt"; keep_work=1
else
  ok "2 記録の行 $(wc -l <"$WORK/base-records.txt") 行が全部残っている（着手前 $(wc -l <"$WORK/base-records-all.txt") 行、許容 $(wc -l <"$WORK/record-allow.txt") 行、今 $(wc -l <"$WORK/now-records.txt") 行）"
fi

# --- 3: /// の総行数 ------------------------------------------------------------
base_doc=$(grep -c '^ *///' "$WORK/base.rs")
now_doc=$(grep -c '^ *///' "$WORK/now.rs")
if [ "$now_doc" -ge "$base_doc" ]; then ok "3 /// の行数 $now_doc（着手前 $base_doc 以上）"; else ng "3 /// の行数 $now_doc（着手前 $base_doc より少ない）"; fi

# --- 4: fmt / clippy ------------------------------------------------------------
if [ "$SKIP_CARGO" = 1 ]; then skip "4 fmt / clippy（SKIP_CARGO=1）"
else
  if cargo fmt --check >"$WORK/fmt.log" 2>&1; then ok "4a cargo fmt --check"; else ng "4a cargo fmt --check"; head -5 "$WORK/fmt.log"; fi
  if cargo clippy --all-targets --locked -- -D warnings >"$WORK/clippy.log" 2>&1; then ok "4b cargo clippy --all-targets --locked -D warnings"; else ng "4b cargo clippy"; grep -E '^(error|warning)' "$WORK/clippy.log" | head -5; fi
fi

# --- 5: Cargo.lock -----------------------------------------------------------------
if git diff --quiet "$BASE_SHA" -- Cargo.lock; then ok "5 Cargo.lock に差分なし"; else ng "5 Cargo.lock に差分がある"; fi

# --- 6: tests/ に差分なし ----------------------------------------------------------
if git diff --quiet "$BASE_SHA" -- tests/; then ok "6 tests/ に差分なし"; else ng "6 tests/ に差分がある"; fi

# --- 7: 消した関数名の残骸 --------------------------------------------------------
if [ -n "$REMOVED_NAMES" ]; then
  if git grep --untracked -nE "\b($REMOVED_NAMES)\b" -- src crates docs/dev CLAUDE.md >"$WORK/residue.txt"; then
    ng "7 消した関数名の残骸が $(wc -l <"$WORK/residue.txt") 行ある"; head -10 "$WORK/residue.txt"
  else
    ok "7 消した関数名（$REMOVED_NAMES）の残骸なし"
  fi
else
  skip "7 消した関数名の残骸（REMOVED_NAMES を渡したときだけ）"
fi

# --- 8: [P2A=1] crate の純粋な分割の正規化 diff -------------------------------------
normalize() {
  # use・mod・pub use・モジュール doc・cfg(test)・空行・単独の括弧を除き、字下げを潰す（#194 の足場の項目 5。許容リストは `pub use` だけ）。
  sed -E 's/^[[:space:]]+//' "$1" | grep -vE '^(use |mod |pub use |//!|#\[cfg\(test\)\]|\{|\}|\};|$)' | sort
}
if [ "$P2A" = 1 ]; then
  git show "$BASE_SHA:crates/athena-sql/src/lib.rs" >"$WORK/crate-base.rs"
  find crates/athena-sql/src -name '*.rs' -exec cat {} + >"$WORK/crate-union.rs"
  normalize "$WORK/crate-base.rs" >"$WORK/crate-base.norm"
  normalize "$WORK/crate-union.rs" >"$WORK/crate-union.norm"
  if diff "$WORK/crate-base.norm" "$WORK/crate-union.norm" >"$WORK/crate-norm.diff"; then
    ok "8 crate の正規化 diff に差分なし（$(wc -l <"$WORK/crate-base.norm") 行）"
  else
    ng "8 crate の正規化 diff に差分がある（$(grep -c '^[<>]' "$WORK/crate-norm.diff") 行）"; head -20 "$WORK/crate-norm.diff"; keep_work=1
  fi
else
  skip "8 crate の正規化 diff（P2A=1 で判定する）"
fi

if [ "$fail" -eq 0 ]; then echo "すべて ok"; else echo "NG あり"; fi
exit "$fail"
