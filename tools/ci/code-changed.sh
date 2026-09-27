#!/usr/bin/env bash
# CI（.github/workflows/ci.yml）の changes ジョブ: その push で変わったファイルに、Check・e2e で確かめるものがあるか（#286）。
#
# 使い方: tools/ci/code-changed.sh <比べる元のコミット> <比べる先のコミット>
# 出力: `code=true` か `code=false`（GITHUB_OUTPUT にそのまま足せる形）。
#   変わったファイルが docs/・.claude/・tools/measure/・*.md だけなら false（CI で確かめるものが無い。tools/e2e/ は
#   e2e ジョブで流すので含めない）。
#   元か先が空、元が全部 0（新しいブランチへの push）、手元に無い（force push で前の head が消えた）など、差分が
#   取れないときは true（走らせる側に倒す）。
set -uo pipefail

from=${1:-}
to=${2:-}
if [ -z "$from" ] || [ -z "$to" ] || [ -z "${from//0/}" ]; then
  echo "code=true"
  exit 0
fi
if ! files=$(git diff --name-only "$from" "$to" 2>/dev/null); then
  echo "code=true"
  exit 0
fi

code=false
while IFS= read -r file; do
  [ -z "$file" ] && continue
  case "$file" in
    docs/* | .claude/* | tools/measure/* | *.md) ;;
    *) code=true ;;
  esac
done <<<"$files"
echo "code=$code"
