#!/bin/bash
# #257 フェーズ 0 の検証の足場(挙動を変えない移動: comment_parse_error.rs の ALTER 部分を
# comment_parse_error/alter.rs へ)。着手前 SHA 18d2be2 と、移動後(移動元 + 移動先)を比べる。
# 使い方: tools/dev.sh .claude/issue-notes/257-verify/check.sh [--no-test]
cd "$(git rev-parse --show-toplevel)"
D=.claude/issue-notes/257-verify
BASE=18d2be2
ng=0

MOVED=false
if [ -f src/operation/comment_parse_error/alter.rs ]; then
  MOVED=true
fi

# 1・2: テスト総数と、モジュール・ファイルごとの内訳
if [ "$1" != "--no-test" ]; then
  cargo test --locked 2>&1 | tee /tmp/257-tests-raw.txt | grep -E "^\s*Running|^test result:" \
    | sed 's/-[0-9a-f]\{16\})/)/; s/; finished in .*//' > /tmp/257-tests-after.txt

  sum() { grep -o 'ok\. [0-9]* passed' "$1" | awk '{s+=$2} END {print s+0}'; }
  b=$(sum "$D/tests-before.txt"); a=$(sum /tmp/257-tests-after.txt)
  [ "$b" = "$a" ] && echo "ok 1 テスト総数 $a" || { echo "NG 1 テスト総数 前 $b 後 $a"; ng=1; }

  if grep -qE "FAILED|failed; [1-9]" /tmp/257-tests-after.txt; then
    echo "NG 1 失敗したテストがある"; ng=1
  fi

  EXPECT="$D/tests-before.txt"
  $MOVED && EXPECT="$D/tests-expected-after.txt"
  if diff "$EXPECT" /tmp/257-tests-after.txt >/dev/null; then
    echo "ok 2 バイナリ・モジュールごとの内訳(移動済み=$MOVED)"
  else
    echo "NG 2 内訳が期待(移動済み=$MOVED)と違う:"
    diff "$EXPECT" /tmp/257-tests-after.txt
    ng=1
  fi

  # 内訳の要: comment_parse_error 系のテスト名を直接数える(バイナリのハッシュに頼らない裏取り)
  cpe_unit=$(grep -c "test operation::comment_parse_error::tests::" /tmp/257-tests-raw.txt)
  cpe_alter_unit=$(grep -c "test operation::comment_parse_error::alter::tests::" /tmp/257-tests-raw.txt)
  cpe_pos_unit=$(grep -c "test operation::comment_parse_error::position::tests::" /tmp/257-tests-raw.txt)
  if $MOVED; then
    exp_unit=9; exp_alter_unit=4
  else
    exp_unit=13; exp_alter_unit=0
  fi
  [ "$cpe_unit" = "$exp_unit" ] && echo "ok 2a comment_parse_error::tests 件数 $cpe_unit" || { echo "NG 2a comment_parse_error::tests 件数 期待 $exp_unit 実物 $cpe_unit"; ng=1; }
  [ "$cpe_alter_unit" = "$exp_alter_unit" ] && echo "ok 2b comment_parse_error::alter::tests 件数 $cpe_alter_unit" || { echo "NG 2b comment_parse_error::alter::tests 件数 期待 $exp_alter_unit 実物 $cpe_alter_unit"; ng=1; }
  [ "$cpe_pos_unit" = 3 ] && echo "ok 2c comment_parse_error::position::tests 件数 3(不変)" || { echo "NG 2c position のテストが変わった: $cpe_pos_unit"; ng=1; }
fi

# 3: doc 行(src と crates 全体)。着手前の doc 行が全部残っていること(多重集合の包含)。
#    足した行(alter.rs・alter/tests.rs のモジュール doc)は情報として印字する。
missing=$(comm -23 <(git grep -h '^\s*\(///\|//!\)' "$BASE" -- src crates | sed 's/^\s*//' | sort) \
                    <(git grep -h --untracked '^\s*\(///\|//!\)' -- src crates | sed 's/^\s*//' | sort))
added=$(comm -13 <(git grep -h '^\s*\(///\|//!\)' "$BASE" -- src crates | sed 's/^\s*//' | sort) \
                  <(git grep -h --untracked '^\s*\(///\|//!\)' -- src crates | sed 's/^\s*//' | sort))
if [ -z "$missing" ]; then
  b=$(git grep -h '^\s*\(///\|//!\)' "$BASE" -- src crates | wc -l)
  a=$(git grep -h --untracked '^\s*\(///\|//!\)' -- src crates | wc -l)
  echo "ok 3 doc 行 前 $b 後 $a(足した行 $(printf '%s' "$added" | grep -c .))"
  [ -n "$added" ] && printf '%s\n' "$added" | sed 's/^/    + /'
else
  echo "NG 3 消えた doc 行:"; printf '%s\n' "$missing"; ng=1
fi

# 4: 「実測」を含む行の多重集合(src 全体)。移動しても文言は変えないので完全一致のはず。
if diff <(git grep -h '実測' "$BASE" -- src | sed 's/^\s*//' | sort) \
        <(git grep -h --untracked '実測' -- src | sed 's/^\s*//' | sort) >/dev/null; then
  echo "ok 4 実測の行 $(git grep -h --untracked '実測' -- src | wc -l)"
else
  echo "NG 4 実測の行が違う:"
  diff <(git grep -h '実測' "$BASE" -- src | sed 's/^\s*//' | sort) \
       <(git grep -h --untracked '実測' -- src | sed 's/^\s*//' | sort)
  ng=1
fi

# 5: 宣言単位の正規化 diff(移動先が無ければ skip。python3 側で 3 組のファイルペアを比べる)
if $MOVED; then
  python3 "$D/norm.py" "$BASE" || ng=1
else
  echo "skip 5 正規化 diff(移動先なし)"
fi

# 6: 整形・lint
cargo fmt --check >/dev/null 2>&1 && echo "ok 6 fmt" || { echo "NG 6 fmt"; ng=1; }
cargo clippy --all-targets --locked -- -D warnings >/dev/null 2>&1 && echo "ok 6 clippy" || { echo "NG 6 clippy"; ng=1; }

[ $ng = 0 ] && echo "ALL OK" || echo "SOME NG"
exit $ng
