#!/usr/bin/env bash
# #195 フェーズ 1（挙動固定テスト）の期待値を、**着手前のコード**を実際に流して採る（推測で書かない。decisions.md「red を作れないリファクタ」の規則）。
# 入力ファイル（1 行 1 つの Rust の文字列リテラル。例: "SELECT 1" / "-- c\nSELECT 1" / r#""my table""#）を受け取り、
# 一時テストを src/operation/classification/tests.rs の末尾に足して `cargo test` で印字させ、終わったら git checkout で戻す。
#
# 使い方: .claude/issue-notes/195-verify/golden.sh <入力ファイル> > <出力>
# 出力: 1 入力 1 行、タブ区切り:
#   <入力リテラル> \t statement_type \t substatement_type(Option) \t fixed_column(Option) \t ResultFile::of \t content_type::of \t plain_text_statement \t carries_execution_id \t target_statement(Option) \t parse_target_table(Option; default_catalog="dc", default_schema="ds") \t describe_target_name(Option)
# 各列は Rust の `{:?}` の表記（そのままテストの期待値に写せる）。最後の列は P1a（`completion::describe_target_name` を `pub(super)` で切り出した後）でだけ出る。
# それより前のツリー（着手前）で流すときは `DESCRIBE=0` を渡して列を省く。
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$REPO_ROOT"
INPUT="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
TARGET=src/operation/classification/tests.rs
if ! git diff --quiet -- "$TARGET"; then echo "$TARGET に未コミットの差分がある。先に片付けること" >&2; exit 1; fi
# 戻した直後の cargo が古いテストバイナリ（一時テスト入り）を使い回すことがあったので、戻した後に touch して必ず作り直させる（2026-09-25 に踏んだ）。
cleanup() { git checkout -q -- "$TARGET"; sleep 1; touch "$TARGET"; }
trap cleanup EXIT

{
  echo
  echo '#[test]'
  echo 'fn tmp195_golden() {'
  echo '    let inputs: &[&str] = &['
  sed -E '/^[[:space:]]*(#|$)/d; s/$/,/' "$INPUT"
  echo '    ];'
  cat <<'EOF'
    for q in inputs {
        let st = statement_type(q);
        let sub = substatement_type(q);
        let fixed = fixed_column(q);
        let file = crate::results::ResultFile::of(q);
        let ct = crate::content_type::of(file, q);
        let plain = crate::content_type::plain_text_statement(q);
        let carries = crate::content_type::carries_execution_id(q);
        let ts = super::super::table_format::target_statement(q);
        let tt = ts.and_then(|s| super::super::target_table::parse_target_table(q, s, Some("dc"), Some("ds")))
            .map(|t| (t.catalog, t.schema, t.table));
EOF
  if [ "${DESCRIBE:-1}" = 1 ]; then
    echo '        let dn = super::super::completion::describe_target_name(q);'
    echo '        println!("GOLDEN\t{q:?}\t{st:?}\t{sub:?}\t{fixed:?}\t{file:?}\t{ct:?}\t{plain:?}\t{carries:?}\t{ts:?}\t{tt:?}\t{dn:?}");'
  else
    echo '        println!("GOLDEN\t{q:?}\t{st:?}\t{sub:?}\t{fixed:?}\t{file:?}\t{ct:?}\t{plain:?}\t{carries:?}\t{ts:?}\t{tt:?}");'
  fi
  echo '    }'
  echo '}'
} >>"$TARGET"

cargo test --locked --lib tmp195_golden -- --nocapture 2>/dev/null | grep '^GOLDEN' | cut -f2- | sort -u
