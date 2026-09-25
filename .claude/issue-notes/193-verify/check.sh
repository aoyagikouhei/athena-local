#!/usr/bin/env bash
# #193 の検証の足場。workspace 化の前後で「挙動を変えない」ことと、cargo の各コマンドが crate に効くことを合否付きで確かめる。
#
# 使い方（リポジトリの中で。cargo はホストでも toolbox（tools/dev.sh）でもよい）:
#   .claude/issue-notes/193-verify/check.sh                  # 着手前のツリー: 項目 1〜3・5 が ok、4 は skip（EXPECT_CRATE=0 の既定）
#   EXPECT_CRATE=1 .claude/issue-notes/193-verify/check.sh   # workspace 化の後: 4（crate の unittests の行と Cargo.lock の差分）も判定する
#   DOCKER=1 EXPECT_CRATE=1 .claude/issue-notes/193-verify/check.sh   # 6（docker build）も流す（数分かかる）
#
# 項目:
#   1 テスト総数と `test result:` のブロックの内訳が着手前（398 件・23 ブロック）と同じ
#   2 cargo fmt --check が通る
#   3 cargo clippy --all-targets --locked -D warnings が通る
#   4 [EXPECT_CRATE=1] a: crate の unittests（`Running unittests src/lib.rs (…/deps/athena_sql-<hash>)`。cargo は package 相対のパスで出す）と `Doc-tests athena_sql` の行がある / b: Cargo.lock の着手前との差分が athena-sql の追加だけ /
#     c: crate に整形崩れを入れると fmt --check が落ちる / d: crate に clippy の警告を入れると clippy が落ちる（どちらも退避して戻す）
#   5 release スキルの版の grep（`0.5.0` を *.md/*.toml/*.yml で探す）が着手前と同じ 3 ファイルにしか当たらない（git grep --untracked。crate の版を本体と同じにすると増える）
#   6 [DOCKER=1] docker build が通る
#   7 `cargo metadata` に cargo の警告（resolver・member の profile など。-D warnings では落ちない）が無い
#   8 ルート Cargo.toml の `^version` が 1 行のまま（release スキルの grep の前提）で、着手前からの削除行が無い
#   9 `cargo test --test startup` が athena-local の結合テスト 1 本だけを走らせる（crate があっても --test で絞れる）
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"
BASE_SHA=1cb0d23c8250c309cdd901842d4857d351261c68
EXPECT_CRATE="${EXPECT_CRATE:-0}"
DOCKER="${DOCKER:-0}"
WORK="$(mktemp -d)"
keep_work=0
cleanup() { if [ "$keep_work" = 1 ]; then echo "証跡を残す: $WORK"; else rm -rf "$WORK"; fi; }
trap cleanup EXIT

fail=0
ok()   { echo "ok   $1"; }
ng()   { echo "NG   $1"; fail=1; }
skip() { echo "skip $1"; }

# 着手前の内訳（1cb0d23、ホストの cargo test --locked、2026-09-25 採取）。「ターゲット 件数」。
expected_blocks() {
  cat <<'EOF'
unittests src/lib.rs 228
unittests src/main.rs 0
tests/catalog.rs 6
tests/describe.rs 18
tests/dml.rs 9
tests/failed_results.rs 4
tests/idempotency.rs 9
tests/list_work_groups.rs 9
tests/metadata.rs 14
tests/parameters.rs 8
tests/request.rs 10
tests/results.rs 16
tests/retention.rs 4
tests/select.rs 18
tests/show_create.rs 6
tests/startup.rs 1
tests/statistics.rs 2
tests/stop.rs 8
tests/syntax.rs 6
tests/table_format.rs 13
tests/waiting.rs 2
tests/work_group.rs 7
Doc-tests athena_local 0
EOF
}

# --- 1: テストの総数と内訳 -------------------------------------------------
cargo test --locked >"$WORK/test.log" 2>&1
test_exit=$?
# "Running unittests src/lib.rs (target/...)" / "Doc-tests athena_local" と、その直後の "test result:" を対にする。
awk '
  /^ +Running / { sub(/^ +Running /, ""); sub(/ \(.*$/, ""); target=$0; next }
  /^ +Doc-tests / { sub(/^ +/, ""); target=$0; next }
  /^test result: / { n=$0; sub(/^test result: [a-zA-Z]+\. /, "", n); sub(/ passed.*$/, "", n); print target, n }
' "$WORK/test.log" >"$WORK/blocks.txt"
if [ "$test_exit" -ne 0 ]; then
  ng "1 cargo test --locked が失敗した（exit $test_exit）。$WORK/test.log"
  grep -E '^test .* FAILED|^error' "$WORK/test.log" | head -5
  keep_work=1
else
  # 着手前の 23 ブロックが、同じ件数で全部ある（順序は問わない）。
  missing=0
  while read -r target count; do
    if ! grep -Fxq "$target $count" "$WORK/blocks.txt"; then
      echo "     内訳が違う: 期待「$target $count」 実際「$(grep -F "$target " "$WORK/blocks.txt" || echo '無し')」"
      missing=1
    fi
  done < <(expected_blocks)
  total=$(awk '{ s += $NF } END { print s + 0 }' "$WORK/blocks.txt")
  # 着手前は 23 ブロック・398 件。crate を足した後は athena-sql の unittests と Doc-tests の 2 ブロック（0 件）が増えるだけ。
  if [ "$EXPECT_CRATE" = 1 ]; then expected_n=25; else expected_n=23; fi
  n=$(wc -l <"$WORK/blocks.txt")
  if [ "$missing" -eq 0 ] && [ "$total" -eq 398 ] && [ "$n" -eq "$expected_n" ]; then
    ok "1 テスト総数 $total 件・ブロック $n 本（着手前と同じ内訳）"
  else
    ng "1 テスト総数 $total 件（期待 398）・ブロック $n 本（期待 $expected_n）・内訳の不一致 $missing"
  fi
fi

# --- 2: fmt ---------------------------------------------------------------
if cargo fmt --check >"$WORK/fmt.log" 2>&1; then ok "2 cargo fmt --check"; else ng "2 cargo fmt --check"; head -5 "$WORK/fmt.log"; fi

# --- 3: clippy ------------------------------------------------------------
if cargo clippy --all-targets --locked -- -D warnings >"$WORK/clippy.log" 2>&1; then
  ok "3 cargo clippy --all-targets --locked -D warnings"
else
  ng "3 cargo clippy"; grep -E '^(error|warning)' "$WORK/clippy.log" | head -5
fi

# --- 4: crate のテストが走る・Cargo.lock の差分 ----------------------------------
if [ "$EXPECT_CRATE" = 1 ]; then
  # cargo は `Running unittests` のパスを package のルートからの相対で出すので、crate の行は `src/lib.rs` のまま。括弧の中のバイナリ名で見分ける。
  if grep -qE '^ +Running unittests src/lib\.rs \([^)]*/deps/athena_sql-[0-9a-f]+\)$' "$WORK/test.log" && grep -Fxq "Doc-tests athena_sql 0" "$WORK/blocks.txt"; then
    ok "4a crate の unittests と Doc-tests が cargo test で走る"
  else
    ng "4a crate の unittests / Doc-tests の行が無い"
  fi
  # 追加行は athena-sql の項（[[package]] / name / version / dependencies の枠と 1 要素）だけ。削除行は無い。
  git diff "$BASE_SHA" -- Cargo.lock | grep -E '^[-+]' | grep -vE '^(\+\+\+|---)' >"$WORK/lock.diff"
  if [ -s "$WORK/lock.diff" ] \
     && ! grep -q '^-' "$WORK/lock.diff" \
     && ! grep -vE '^\+($|\[\[package\]\]|name = "athena-sql"|version = "0\.1\.0"|dependencies = \[| "athena-sql",|\])$' "$WORK/lock.diff" >/dev/null; then
    ok "4b Cargo.lock の差分は athena-sql の追加だけ（$(wc -l <"$WORK/lock.diff") 行）"
  else
    ng "4b Cargo.lock の差分が空か、athena-sql 以外を含む"; head -20 "$WORK/lock.diff"
  fi
  # 4c/4d: crate の lib.rs を退避して壊し、fmt / clippy が crate を見ていることを確かめてから戻す。
  lib=crates/athena-sql/src/lib.rs
  if [ -f "$lib" ]; then
    cp "$lib" "$WORK/lib.rs.bak"
    restore_lib() { cp "$WORK/lib.rs.bak" "$lib"; }
    trap 'restore_lib; cleanup' EXIT
    printf 'pub fn  probe( ) {}\n' >>"$lib"
    if ! cargo fmt --check >"$WORK/fmt-crate.log" 2>&1 && grep -q 'crates/athena-sql/src/lib.rs' "$WORK/fmt-crate.log"; then
      ok "4c cargo fmt --check は crate の整形崩れで落ちる"
    else
      ng "4c cargo fmt --check が crate の整形崩れを見ていない"
    fi
    restore_lib
    printf 'pub fn probe() -> i32 { return 1; }\n' >>"$lib"
    if ! cargo clippy --all-targets --locked -- -D warnings >"$WORK/clippy-crate.log" 2>&1 && grep -q 'needless_return' "$WORK/clippy-crate.log"; then
      ok "4d cargo clippy は crate の警告で落ちる"
    else
      ng "4d cargo clippy が crate の警告を見ていない"
    fi
    restore_lib
    trap cleanup EXIT
    if ! cmp -s "$lib" "$WORK/lib.rs.bak"; then ng "4 lib.rs の復元に失敗した"; fi
  else
    ng "4c/4d $lib が無い"
  fi
else
  skip "4 crate の確認（EXPECT_CRATE=1 で判定する）"
fi

# --- 5: release スキルの版の grep -------------------------------------------
# release スキル（.claude/skills/release/SKILL.md:49-51）と同じ条件を git grep で。着手前は Cargo.toml・README.md・SKILL.md の 3 ファイル。
# crate の Cargo.toml が本体と同じ版を持つと、ここに 1 ファイル増えてリリース手順の「4 ファイルだけ」が崩れる。
version_hits() { git grep -l --untracked -e '0\.5\.0' "$@" -- '*.md' '*.toml' '*.yml' ':!CHANGELOGS.md' ':!.claude/issue-notes' | sed 's/^[0-9a-f]*://' | sort; }
expected=$(git grep -l -e '0\.5\.0' "$BASE_SHA" -- '*.md' '*.toml' '*.yml' ':!CHANGELOGS.md' | sed 's/^[0-9a-f]*://' | sort)
actual=$(version_hits)
if [ "$actual" = "$expected" ]; then ok "5 版の grep は着手前と同じ $(echo "$expected" | wc -l) ファイル"; else ng "5 版の grep が着手前と違う: $(echo $actual)"; fi

# --- 6: docker build ---------------------------------------------------------
if [ "$DOCKER" = 1 ]; then
  if docker build -t aoyagikouhei/athena-local:dev . >"$WORK/docker.log" 2>&1; then
    ok "6 docker build"
  else
    ng "6 docker build"; tail -15 "$WORK/docker.log"
  fi
else
  skip "6 docker build（DOCKER=1 で流す）"
fi

# --- 7: cargo 自身の警告 ------------------------------------------------------
cargo metadata --format-version 1 --no-deps >/dev/null 2>"$WORK/metadata.log"
if grep -q '^warning' "$WORK/metadata.log"; then ng "7 cargo の警告がある"; head -3 "$WORK/metadata.log"; else ok "7 cargo の警告なし"; fi

# --- 8: ルートの Cargo.toml ------------------------------------------------------
if [ "$(grep -c '^version' Cargo.toml)" -eq 1 ] && ! git diff "$BASE_SHA" -- Cargo.toml | grep -qE '^-[^-]'; then
  ok "8 ルート Cargo.toml の ^version は 1 行、削除行なし"
else
  ng "8 ルート Cargo.toml の ^version の行数か削除行"
fi

# --- 9: --test で絞れる -------------------------------------------------------
cargo test --locked --test startup >"$WORK/startup.log" 2>&1
if [ "$(grep -c '^test result:' "$WORK/startup.log")" -eq 1 ] && grep -q '^test result: ok. 1 passed' "$WORK/startup.log"; then
  ok "9 cargo test --test startup は 1 ブロック 1 件"
else
  ng "9 cargo test --test startup の出力が期待と違う"; grep -E 'Running|test result:|error' "$WORK/startup.log" | head -5
fi

if [ "$fail" -eq 0 ]; then echo "すべて ok"; else echo "NG あり"; fi
exit "$fail"
