#!/usr/bin/env bash
# issue #1 で作成（tools/ へ移す前の名前は 1-measure-content-type.sh）
# 結果ファイルの Content-Type を実測する。txt-result.sh の出力をそのまま使う。
#
# 使い方:
#   bash txt-result-content-type.sh
#
# 任意の環境変数:
#   OUT_DIR  既定 $HOME/athena-txt-measurements
#   RUN_DIR  既定は OUT_DIR の中でいちばん新しい run-*
#   REGION   既定 ap-northeast-1
#
# 端末に出すのはラベルと Content-Type だけで、バケット名やキーは出さない。

set -uo pipefail

OUT_DIR=${OUT_DIR:-$HOME/athena-txt-measurements}
RUN_DIR=${RUN_DIR:-$(ls -dt "$OUT_DIR"/run-* 2>/dev/null | head -1)}
REGION=${REGION:-ap-northeast-1}

if [ -z "${RUN_DIR:-}" ] || [ ! -d "$RUN_DIR" ]; then
  echo "実測の出力が見つかりません。先に txt-result.sh を実行してください。"
  exit 1
fi

RESULT="$RUN_DIR/content-types.tsv"
echo "対象: $RUN_DIR"
printf 'label\tcontent_type\n' | tee "$RESULT"

for execution in "$RUN_DIR"/*.execution.json; do
  [ -e "$execution" ] || continue
  label=$(basename "$execution" .execution.json)

  location=$(python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))["QueryExecution"]
print(d.get("ResultConfiguration", {}).get("OutputLocation", ""))' "$execution")
  [ -n "$location" ] || continue

  rest=${location#s3://}
  bucket=${rest%%/*}
  key=${rest#*/}

  content_type=$(aws s3api head-object --region "$REGION" \
    --bucket "$bucket" --key "$key" \
    --query 'ContentType' --output text 2>/dev/null)

  printf '%s\t%s\n' "$label" "${content_type:-取得できず}"
done

echo
echo "この一覧は実名を含みません。そのまま貼れます。"
