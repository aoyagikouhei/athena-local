#!/bin/bash
# #245 の検証の足場。着手前 2762fc8 の execution.rs と、後の execution.rs + start_checks.rs を比べる。
# 使い方: tools/dev.sh .claude/issue-notes/245-verify/check.sh [--no-test]
cd "$(git rev-parse --show-toplevel)"
D=.claude/issue-notes/245-verify
BASE=2762fc8
ng=0
# 1・2: テストの総数と、テストバイナリごとの内訳（Running の行と件数の組）
if [ "$1" != "--no-test" ]; then
  cargo test --locked 2>&1 | grep -E "^\s*Running|^test result:" | sed 's/-[0-9a-f]\{16\})/)/; s/; finished in .*//' > /tmp/245-tests-after.txt
  norm() { sed 's/-[0-9a-f]\{16\})/)/; s/; finished in .*//' "$1"; }
  sum() { grep -o 'ok\. [0-9]* passed' "$1" | awk '{s+=$2} END {print s}'; }
  b=$(sum $D/tests-before.txt); a=$(sum /tmp/245-tests-after.txt)
  [ "$b" = "$a" ] && echo "ok 1 テスト総数 $a" || { echo "NG 1 テスト総数 前 $b 後 $a"; ng=1; }
  diff <(norm $D/tests-before.txt) /tmp/245-tests-after.txt >/dev/null && echo "ok 2 バイナリごとの内訳" || { echo "NG 2 内訳:"; diff <(norm $D/tests-before.txt) /tmp/245-tests-after.txt; ng=1; }
  grep -q "FAILED\|failed; [1-9]" /tmp/245-tests-after.txt && { echo "NG 1 失敗したテストがある"; ng=1; }
fi
# 3: doc 行（src と crates 全体）。着手前の doc 行が全部残っていること（多重集合の包含）。足した doc 行は印字して目視する
missing=$(comm -23 <(git grep -h '^\s*///' $BASE -- src crates | sed 's/^\s*//' | sort) <(git grep -h --untracked '^\s*///' -- src crates | sed 's/^\s*//; s/`start_checks\.rs` のブロックコメント/`execution.rs` のブロックコメント/' | sort))
added=$(comm -13 <(git grep -h '^\s*///' $BASE -- src crates | sed 's/^\s*//' | sort) <(git grep -h --untracked '^\s*///' -- src crates | sed 's/^\s*//; s/`start_checks\.rs` のブロックコメント/`execution.rs` のブロックコメント/' | sort))
if [ -z "$missing" ]; then echo "ok 3 doc 行 前 $(git grep -h '^\s*///' $BASE -- src crates | wc -l) 後 $(git grep -h --untracked '^\s*///' -- src crates | wc -l)（足した行 $(printf '%s' "$added" | grep -c .)）"; [ -n "$added" ] && printf '%s\n' "$added" | sed 's/^/    + /'; else echo "NG 3 消えた doc 行:"; printf '%s\n' "$missing"; ng=1; fi
# 4: 「実測」を含む行の多重集合（src 全体）
if diff <(git grep -h '実測' $BASE -- src | sed 's/^\s*//' | sort) <(git grep -h --untracked '実測' -- src | sed 's/^\s*//; s/`start_checks\.rs` のブロックコメント/`execution.rs` のブロックコメント/' | sort) >/dev/null; then
  echo "ok 4 実測の行 $(git grep -h --untracked '実測' -- src | wc -l)"
else
  echo "NG 4 実測の行が違う:"; diff <(git grep -h '実測' $BASE -- src | sed 's/^\s*//' | sort) <(git grep -h --untracked '実測' -- src | sed 's/^\s*//; s/`start_checks\.rs` のブロックコメント/`execution.rs` のブロックコメント/' | sort); ng=1
fi
# 5: 行単位の正規化 diff（許容リスト外が残れば NG）
python3 $D/norm.py $BASE || ng=1
# 6: 整形・lint
cargo fmt --check >/dev/null 2>&1 && echo "ok 6 fmt" || { echo "NG 6 fmt"; ng=1; }
cargo clippy --all-targets --locked -- -D warnings >/dev/null 2>&1 && echo "ok 6 clippy" || { echo "NG 6 clippy"; ng=1; }
[ $ng = 0 ] && echo "ALL OK" || echo "SOME NG"
exit $ng
