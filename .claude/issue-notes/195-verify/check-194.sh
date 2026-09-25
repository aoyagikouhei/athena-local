#!/usr/bin/env bash
# #194 の検証の足場。`src/catalog.rs` の字句処理を `crates/athena-sql/src/lib.rs` へ「そのまま移す」ことを合否付きで確かめる。
# #193 の足場（PR #197 の履歴 `.claude/issue-notes/193-verify/check.sh`）の項目 1 を再利用し、移動の検証（move-refactor）を足した。
#
# 使い方（リポジトリの中で。cargo はホストでも toolbox（tools/dev.sh）でもよい）:
#   .claude/issue-notes/194-verify/check.sh           # 着手前のツリー（AFTER=0 の既定）: 移動前の内訳を期待する。5・7 は skip
#   AFTER=1 .claude/issue-notes/194-verify/check.sh   # 移動後: 移動後の内訳を期待し、正規化 diff と呼び出し元の差分も判定する
#   SKIP_CARGO=1 AFTER=1 .claude/issue-notes/194-verify/check.sh   # 足場の壊し試験用: cargo を使う 1・2・6 を飛ばす（受け入れ判定には使わない）
#
# 項目:
#   1 テスト総数が 398・`test result:` が 25 ブロックで、ブロックごとの件数が期待どおり（移動前: athena_local lib 228 / athena_sql 0、移動後: 213 / 15）
#   2 `catalog::tests` と athena_sql の `tests::` のテスト名の一覧が期待どおり（どちらのファイルに属するかを固定する。和集合ではない）
#   3 `///` の総行数が着手前の `src/catalog.rs` と同じ（`src/catalog.rs` + `crates/athena-sql/src/lib.rs`。`//!` のモジュール doc は書き直すので数えず、7-5b で目視）
#   4 「実測」「採取」「計画攻撃」「確認」を含む行が、着手前と同じ内容で全部残っている（両ファイルの和集合）
#   5 [AFTER=1] 正規化 diff: `use`・`mod`・`//!`・空行・`#[cfg(test)]`・単独の括弧を除き、字下げを潰して行をソートし、着手前の catalog.rs と「catalog.rs + lib.rs」を比べる。
#     許容リスト（計画が要求する非純粋変更）: 移した関数の `pub(crate) fn` → `pub fn`、`skip_trivia` の `fn` → `pub fn`、`athena_sql::` の接頭辞。それ以外の差分が 1 行でも残れば NG
#   6 cargo fmt --check と cargo clippy --all-targets --locked -D warnings
#   7 [AFTER=1] `src/catalog.rs` 以外の src/ の差分が `crate::catalog::X` → `athena_sql::X`（と `use` の付け替え・use の組を分ける空行 1 行以内）だけ。Cargo.lock に差分が無い。
#     P1_SHA を渡すとフェーズ 1 の SHA までで判定し、7c でフェーズ 2 の src/・crates/ の差分がコメント行だけであることを確かめる
#   8 本体（`#[cfg(test)]` より前）の分岐の語（if/match/return/else/while/loop/for）を含む行数が着手前と同じ（両ファイルの和）
#   9 `tests/` に差分が無い（issue の完了条件）
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"
BASE_SHA=0137b93b22a5afe5bcb12a820202d62269b777d6
AFTER="${AFTER:-0}"
SKIP_CARGO="${SKIP_CARGO:-0}"
SRC=src/catalog.rs
DST=crates/athena-sql/src/lib.rs
WORK="$(mktemp -d)"
keep_work=0
cleanup() { if [ "$keep_work" = 1 ]; then echo "証跡を残す: $WORK"; else rm -rf "$WORK"; fi; }
trap cleanup EXIT

fail=0
ok()   { echo "ok   $1"; }
ng()   { echo "NG   $1"; fail=1; }
skip() { echo "skip $1"; }

git show "$BASE_SHA:$SRC" >"$WORK/base.rs"
cat "$SRC" "$DST" >"$WORK/union.rs"

# 移す関数（`pub(crate)` → `pub` になる 7 つ）と、残留側の `next_is_dot` が呼ぶので `pub` になる `skip_trivia`。
MOVED_PUB='skip_quoted|comment_end|skip_leading_trivia|words|skip_keyword|skip_qualified_name|unquote'

# --- 1: テストの総数と内訳 -------------------------------------------------
if [ "$AFTER" = 1 ]; then lib_local=213; lib_sql=15; else lib_local=228; lib_sql=0; fi
expected_blocks() {
  cat <<EOF
unittests src/lib.rs [athena_local] $lib_local
unittests src/main.rs [athena_local] 0
tests/catalog.rs [athena_local] 6
tests/describe.rs [athena_local] 18
tests/dml.rs [athena_local] 9
tests/failed_results.rs [athena_local] 4
tests/idempotency.rs [athena_local] 9
tests/list_work_groups.rs [athena_local] 9
tests/metadata.rs [athena_local] 14
tests/parameters.rs [athena_local] 8
tests/request.rs [athena_local] 10
tests/results.rs [athena_local] 16
tests/retention.rs [athena_local] 4
tests/select.rs [athena_local] 18
tests/show_create.rs [athena_local] 6
tests/startup.rs [athena_local] 1
tests/statistics.rs [athena_local] 2
tests/stop.rs [athena_local] 8
tests/syntax.rs [athena_local] 6
tests/table_format.rs [athena_local] 13
tests/waiting.rs [athena_local] 2
tests/work_group.rs [athena_local] 7
unittests src/lib.rs [athena_sql] $lib_sql
Doc-tests athena_local [athena_local] 0
Doc-tests athena_sql [athena_sql] 0
EOF
}

if [ "$SKIP_CARGO" = 1 ]; then : >"$WORK/test.log"; test_exit=0; else cargo test --locked >"$WORK/test.log" 2>&1; test_exit=$?; fi
# cargo は `Running unittests` のパスを package 相対で出す（crate も `src/lib.rs`）ので、括弧の中のバイナリ名で package を見分ける。
awk '
  /^ +Running / { line=$0; sub(/^ +Running /, "", line); target=line; sub(/ \(.*$/, "", target);
                  pkg = (line ~ /athena_sql-[0-9a-f]+\)$/) ? "athena_sql" : "athena_local"; next }
  /^ +Doc-tests / { target=$0; sub(/^ +/, "", target); pkg = (target ~ /athena_sql$/) ? "athena_sql" : "athena_local"; next }
  /^test .* \.\.\. ok$/ { name=$2; print pkg, name > "'"$WORK/names.txt"'" }
  /^test result: / { n=$0; sub(/^test result: [a-zA-Z]+\. /, "", n); sub(/ passed.*$/, "", n); print target " [" pkg "] " n }
' "$WORK/test.log" >"$WORK/blocks.txt"
if [ "$SKIP_CARGO" = 1 ]; then
  skip "1 テストの総数と内訳（SKIP_CARGO=1）"
elif [ "$test_exit" -ne 0 ]; then
  ng "1 cargo test --locked が失敗した（exit $test_exit）。$WORK/test.log"
  grep -E '^test .* FAILED|^error' "$WORK/test.log" | head -5
  keep_work=1
else
  missing=0
  while read -r line; do
    if ! grep -Fxq "$line" "$WORK/blocks.txt"; then
      key="${line% *}"
      echo "     内訳が違う: 期待「$line」 実際「$(grep -F "$key " "$WORK/blocks.txt" || echo '無し')」"
      missing=1
    fi
  done < <(expected_blocks)
  total=$(awk '{ s += $NF } END { print s + 0 }' "$WORK/blocks.txt")
  n=$(wc -l <"$WORK/blocks.txt")
  if [ "$missing" -eq 0 ] && [ "$total" -eq 398 ] && [ "$n" -eq 25 ]; then
    ok "1 テスト総数 $total 件・ブロック $n 本（内訳は期待どおり）"
  else
    ng "1 テスト総数 $total 件（期待 398）・ブロック $n 本（期待 25）・内訳の不一致 $missing"
  fi
fi

# --- 2: テスト名の帰属 ----------------------------------------------------------
# 残す側（alias_qualified_names の 12 本）は athena_local の catalog::tests に、移す側（15 本）は AFTER=1 なら athena_sql の tests に。
stay_names() {
  cat <<'EOF'
catalog::tests::引用符付きのカタログ名を別名にして桁を空白で揃える
catalog::tests::修飾名がいくつあってもそれぞれ置き換える
catalog::tests::空白や改行やコメントを挟んで続く点でも置き換える
catalog::tests::後ろに点が続かなければ置き換えない
catalog::tests::文字列リテラルとコメントの中は置き換えない
catalog::tests::リテラルやコメントが閉じた後ろは置き換える
catalog::tests::引用符の無い名前と大文字小文字の違う名前は置き換えない
catalog::tests::別名の方が長ければ空白で埋めずに置き換える
catalog::tests::識別子の二重の引用符は中身として比べて別名では二重にする
catalog::tests::桁は文字数で揃える
catalog::tests::置き換える箇所が無ければ受け取った_sql_を借りたまま返す
catalog::tests::閉じていない引用符やコメントでも止まらない
EOF
}
move_names() {
  cat <<'EOF'
トリビアが無ければ受け取った_sql_をそのまま返す
行コメントを読み飛ばす
ブロックコメントを読み飛ばす
空白とコメントを交互に読み飛ばす
コメントだけの文は空文字列になる
非_ascii_のコメントでもバイト単位の走査が途中を切らない
words_は空白とコメントの両方を区切りにして大文字の語にする
words_は引用符の中のコメント記号をコメントと読まない
words_はコメントだけの文や未閉じのコメントで空か途中までになる
skip_qualified_name_は無引用の単純な名前を読み飛ばす
skip_qualified_name_はドットで繋いだ修飾名を読み飛ばす
skip_qualified_name_は引用符付きの識別子を読み飛ばす
skip_qualified_name_はドットの前後の空白やコメントを読み飛ばす
skip_qualified_name_はドットが続かなければ後ろのトリビアを消費せずに止まる
skip_qualified_name_は途中の位置からも読める
EOF
}
if [ "$SKIP_CARGO" = 1 ]; then
  skip "2 テスト名の帰属（SKIP_CARGO=1）"
elif [ -s "$WORK/names.txt" ]; then
  if [ "$AFTER" = 1 ]; then
    { stay_names | sed 's/^/athena_local /'; move_names | sed 's/^/athena_sql tests::/'; } | sort >"$WORK/expect-names.txt"
  else
    { stay_names | sed 's/^/athena_local /'; move_names | sed 's/^/athena_local catalog::tests::/'; } | sort >"$WORK/expect-names.txt"
  fi
  grep -E '^athena_local catalog::tests::|^athena_sql ' "$WORK/names.txt" | sort >"$WORK/actual-names.txt"
  if diff "$WORK/expect-names.txt" "$WORK/actual-names.txt" >"$WORK/names.diff"; then
    ok "2 テスト名の帰属（残す 12 本・移す 15 本）が期待どおり"
  else
    ng "2 テスト名の帰属が期待と違う"; head -10 "$WORK/names.diff"
  fi
else
  ng "2 テスト名を test.log から取れなかった"
fi

# --- 3: /// の総行数 ------------------------------------------------------------
base_doc=$(grep -c '^ *///' "$WORK/base.rs")
now_doc=$(grep -c '^ *///' "$WORK/union.rs")
if [ "$base_doc" -eq "$now_doc" ]; then ok "3 /// の行数 $now_doc（着手前と同じ）"; else ng "3 /// の行数 $now_doc（着手前 $base_doc）"; fi

# --- 4: 記録の行 ------------------------------------------------------------------
grep -E '実測|採取|計画攻撃|確認' "$WORK/base.rs" | sed 's/^ *//' | sort >"$WORK/base-records.txt"
grep -E '実測|採取|計画攻撃|確認' "$WORK/union.rs" | sed 's/^ *//' | sort >"$WORK/now-records.txt"
if diff "$WORK/base-records.txt" "$WORK/now-records.txt" >"$WORK/records.diff"; then
  ok "4 記録の行 $(wc -l <"$WORK/base-records.txt") 行が全部残っている"
else
  ng "4 記録の行に差分がある"; head -10 "$WORK/records.diff"
fi

# --- 5: 正規化 diff ----------------------------------------------------------------
normalize() {
  # use・mod・モジュール doc・cfg(test)・空行・単独の括弧を除き、字下げを潰す。
  sed -E 's/^[[:space:]]+//' "$1" \
    | grep -vE '^(use |mod |//!|#\[cfg\(test\)\]|\{|\}|\};|$)' \
    | sort
}
if [ "$AFTER" = 1 ]; then
  normalize "$WORK/base.rs" >"$WORK/base.norm"
  # 許容リスト: 移した 7 関数の可視性、skip_trivia の可視性、athena_sql:: の接頭辞。
  normalize "$WORK/union.rs" \
    | sed -E "s/^pub fn ($MOVED_PUB)\b/pub(crate) fn \1/; s/^pub fn skip_trivia\b/fn skip_trivia/; s/athena_sql:://g" \
    | sort >"$WORK/union.norm"
  if diff "$WORK/base.norm" "$WORK/union.norm" >"$WORK/norm.diff"; then
    ok "5 正規化 diff に許容リスト以外の差分なし（$(wc -l <"$WORK/base.norm") 行）"
  else
    ng "5 正規化 diff に差分がある（$(grep -c '^[<>]' "$WORK/norm.diff") 行）"; head -20 "$WORK/norm.diff"; keep_work=1
  fi
else
  skip "5 正規化 diff（AFTER=1 で判定する）"
fi

# --- 6: fmt / clippy ------------------------------------------------------------
if [ "$SKIP_CARGO" = 1 ]; then skip "6 fmt / clippy（SKIP_CARGO=1）"
elif cargo fmt --check >"$WORK/fmt.log" 2>&1; then ok "6a cargo fmt --check"; else ng "6a cargo fmt --check"; head -5 "$WORK/fmt.log"; fi
if [ "$SKIP_CARGO" = 1 ]; then :
elif cargo clippy --all-targets --locked -- -D warnings >"$WORK/clippy.log" 2>&1; then
  ok "6b cargo clippy --all-targets --locked -D warnings"
else
  ng "6b cargo clippy"; grep -E '^(error|warning)' "$WORK/clippy.log" | head -5
fi

# --- 7: 呼び出し元の差分 -----------------------------------------------------------
# 7a はフェーズ 1（移動）の作業ツリーかコミットで判定する。フェーズ 2（文書の追随）の後は P1_SHA にフェーズ 1 の SHA を渡すと、
# 7a は BASE..P1_SHA で判定し、7c で P1_SHA..HEAD の src/・crates/ の差分がコメント行だけであることを確かめる。
if [ "$AFTER" = 1 ]; then
  # P1_SHA が無ければ作業ツリーと比べる（コミット前の verify で使う。コミット同士の比較にすると正しい実装でも差分 0 で NG になる。計画レビュー 4-1）。
  git diff "$BASE_SHA" ${P1_SHA:+"$P1_SHA"} -- src ":!$SRC" | grep -E '^[-+]' | grep -vE '^(\+\+\+|---)' >"$WORK/callers.diff"
  # 許容: `-` は catalog:: を含む行、`+` は athena_sql:: を含む行か、use の組を分ける空行（content_type.rs で std と外部 crate の組を分ける 1 行）。
  bad=$(grep -vE "^-.*catalog::|^\+.*athena_sql::|^\+$" "$WORK/callers.diff" || true)
  blank=$(grep -c '^+$' "$WORK/callers.diff")
  if [ -s "$WORK/callers.diff" ] && [ -z "$bad" ] && [ "$blank" -le 1 ]; then
    ok "7a 呼び出し元の差分は catalog:: → athena_sql:: の書き換えだけ（$(wc -l <"$WORK/callers.diff") 行、空行 $blank）"
  else
    ng "7a 呼び出し元の差分が空か、書き換え以外を含む（空行 $blank）"; echo "$bad" | head -10
  fi
  if git diff --quiet "$BASE_SHA" -- Cargo.lock; then ok "7b Cargo.lock に差分なし"; else ng "7b Cargo.lock に差分がある"; fi
  if [ -n "${P1_SHA:-}" ]; then
    git diff "$P1_SHA" -- src crates | grep -E '^[-+][^-+]' | grep -vE '^[-+][[:space:]]*(//|$)' >"$WORK/phase2.diff"
    if [ -s "$WORK/phase2.diff" ]; then ng "7c フェーズ 2 の src/・crates/ の差分にコメント以外の行がある"; head -10 "$WORK/phase2.diff"; else ok "7c フェーズ 2 の src/・crates/ の差分はコメント行だけ"; fi
  fi
else
  skip "7 呼び出し元の差分（AFTER=1 で判定する）"
fi

# --- 8: 本体の分岐の計数 -----------------------------------------------------------
body_branches() { sed '/^#\[cfg(test)\]/,$d' "$1" | grep -cE '\b(if|match|return|else|while|loop|for)\b'; }
base_br=$(body_branches "$WORK/base.rs")
now_br=$(( $(body_branches "$SRC") + $(body_branches "$DST") ))
if [ "$base_br" -eq "$now_br" ]; then ok "8 本体の分岐の語を含む行 $now_br（着手前と同じ）"; else ng "8 本体の分岐の語を含む行 $now_br（着手前 $base_br）"; fi

# --- 9: tests/ に差分なし ----------------------------------------------------------
if git diff --quiet "$BASE_SHA" -- tests/; then ok "9 tests/ に差分なし"; else ng "9 tests/ に差分がある"; fi

if [ "$fail" -eq 0 ]; then echo "すべて ok"; else echo "NG あり"; fi
exit "$fail"
