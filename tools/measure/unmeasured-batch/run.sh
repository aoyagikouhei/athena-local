#!/usr/bin/env bash
# issue #113: 未実測 28 件（既に答えがある 5 件は除く）のうち、フェーズ 1 の対象（生 HTTP・
# 保持期限を除く 19 項目）を 1 本のバッチで測る。.claude/issue-notes/113.md の「## 計画」節が仕様の正。
#
# 使い方（tools/dev.sh 経由。ホストで直接叩かない）:
#   tools/dev.sh env TARGET=local WAIT_RETENTION=0 bash tools/measure/unmeasured-batch/run.sh
#   tools/dev.sh env TARGET=real OUTPUT=s3://your-bucket/prefix/ DB=your_db WORKGROUP2=wg \
#     bash tools/measure/unmeasured-batch/run.sh
#   （TARGET=real の資格情報はホストのシェルで export した AWS_* を渡す。90 分以上有効なものを使うこと）
#
# 環境変数:
#   TARGET         real（既定）/ local。real は本物の Athena、local は tools/dev.sh 経由の
#                  trino/minio + ビルドした athena-local。
#   OUTPUT, DB     TARGET=real で必須（s3://bucket/prefix/、データベース名）。local では
#                  lib-local.sh が s3://athena-results/unmeasured-batch/ / default に固定する。
#   WORKGROUP2     TARGET=real で必須。OutputLocation が設定済みのワークグループ名（w1・t8 が使う）。
#   REGION         既定 ap-northeast-1。CATALOG 既定 AwsDataCatalog（real でだけ使う）。
#   ONLY           項目 id をカンマ区切りで絞る（例 ONLY=r3,m1）。他の項目は行を増やさない。
#   RUN_DIR        渡せば新しく作らず、同じ run に追記する（ONLY で 1 項目だけ直したいとき用）。
#   WAIT_RETENTION フェーズ 2 の保持期限（t6/t7）用の口。フェーズ 1 では読むだけで使わない。
#   SKIP_BUILD     1 なら TARGET=local で cargo build を省く。
#   POLL_TIMEOUT・RETRY_MAX・RETRY_DELAY  既定 180 / 4 / 5（lib-aws.sh が使う）。
#
# 出力: ${DEV_HOST_HOME:-$HOME}/athena-unmeasured-batch-measurements/run-<日時>/<項目id>/
#   に文ごとのファイル、run 直下に summary.tsv（機械可読）と summary.txt（そのまま貼れる要約）。
#
# フェーズ 1 の範囲: items-result-files.sh（r1-r4, x1, x2）、items-metadata.sh（m1-m3, m5）、
# items-statements.sh（s1, s2, p1）、items-token.sh（t1, t5, t8, t4c）、
# items-workgroup-errors.sh（w1, e1）。フェーズ 2 で足すもの:
#   - 保持期限（t6・t7、items-retention.sh）: 段階 A は「本編の前」、段階 B は「本編の後・report.py の前」
#     （下のコメント参照）。ONLY に t6/t7 が無ければ 65 分待ちを起こさない。
#   - 生 HTTP（t2・t3・t4・e2、raw.py）: items-token.sh と items-workgroup-errors.sh から呼ぶ。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

TARGET=${TARGET:-real}
REGION=${REGION:-ap-northeast-1}
CATALOG=${CATALOG:-AwsDataCatalog}
OUTPUT=${OUTPUT:-}
DB=${DB:-}
WORKGROUP2=${WORKGROUP2:-}
ONLY=${ONLY:-}
WAIT_RETENTION=${WAIT_RETENTION:-1}
SKIP_BUILD=${SKIP_BUILD:-0}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}

case "$TARGET" in
  real | local) ;;
  *)
    echo "run.sh: TARGET は real か local（$TARGET は不明）" >&2
    exit 2
    ;;
esac

# 作るテーブル・ビューの接頭辞。作る前に SHOW TABLES で同名が無いことを確かめる（probe_prefix_exists）。
PROBE_PREFIX="athena_local_probe_113"

RUN_DIR=${RUN_DIR:-"${DEV_HOST_HOME:-$HOME}/athena-unmeasured-batch-measurements/run-$(date +%Y%m%d-%H%M%S)"}
mkdir -p "$RUN_DIR"
touch "$RUN_DIR/cleanup-hints.txt"
SUMMARY="$RUN_DIR/summary.tsv"
if [ ! -f "$SUMMARY" ]; then
  printf 'item_id\tlabel\tkind\tstate\tstatement_type\tsubstatement_type\tloc_shape\tbody_bytes\tbody_ct\tmetadata_bytes\tmetadata_ct\texpected\tactual\tmatch\tnote\n' >"$SUMMARY"
fi
echo "出力先: $RUN_DIR"

# shellcheck source=tools/measure/unmeasured-batch/lib-aws.sh
source "$SCRIPT_DIR/lib-aws.sh"

if [ "$TARGET" = local ]; then
  # shellcheck source=tools/measure/unmeasured-batch/lib-local.sh
  source "$SCRIPT_DIR/lib-local.sh"
  local_harden_credentials
  cleanup_local() { local_down; }
  trap cleanup_local EXIT
  if ! local_up; then
    echo "run.sh: local の環境を作れませんでした（$RUN_DIR/athena-local.log・cargo-build.log を見る）" >&2
    exit 1
  fi
  ATHENA_EXTRA_ARGS=(--endpoint-url "$LOCAL_ATHENA_BASE")
  S3_EXTRA_ARGS=(--endpoint-url "$LOCAL_MINIO_ENDPOINT")
  OUTPUT="$LOCAL_OUTPUT"
  DB="default"
  OUTPUT_BUCKET="$LOCAL_BUCKET"
  # local の各項目内カタログ（items-*.sh が TARGET=local で参照する）。
  TCAT_GENERIC="memory"
  TCAT_ICEBERG="iceberg"
  TCAT_HIVE="hive"
  TDB="default"
  # athena-local は名前を見ないので実在しなくてよい。primary との違いを見る w1 のため、
  # わざと primary とは違う文字列にする。
  WORKGROUP2="athena-local-wg2-probe"
  # GetWorkGroup がどの名前でも返す既定の出力先（t8 が使う）。
  TARGET_WG2_OUTPUT="$LOCAL_OUTPUT"
else
  : "${OUTPUT:?TARGET=real には OUTPUT (s3://bucket/prefix/) が要ります}"
  : "${DB:?TARGET=real には DB（データベース名）が要ります}"
  : "${WORKGROUP2:?TARGET=real には WORKGROUP2（OutputLocation 設定済みのワークグループ名）が要ります}"
  OUTPUT_BUCKET=${OUTPUT#s3://}
  OUTPUT_BUCKET=${OUTPUT_BUCKET%%/*}
  TCAT_GENERIC="$CATALOG"
  TCAT_ICEBERG="$CATALOG"
  TCAT_HIVE="$CATALOG"
  TDB="$DB"

  echo "== preflight: GetWorkGroup($WORKGROUP2) の OutputLocation を確認する"
  if ! get_work_group "$RUN_DIR/.preflight" preflight-workgroup2 "$WORKGROUP2"; then
    echo "run.sh: GetWorkGroup($WORKGROUP2) が失敗しました。$RUN_DIR/.preflight/preflight-workgroup2.err を見る。" >&2
    echo "        本物の項目は 1 本も投げていません。" >&2
    exit 1
  fi
  WG2_OUTPUT=$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1]))["WorkGroup"]["Configuration"]["ResultConfiguration"].get("OutputLocation") or "")
except Exception: print("")' "$RUN_DIR/.preflight/preflight-workgroup2.json")
  if [ -z "$WG2_OUTPUT" ]; then
    echo "run.sh: WORKGROUP2（$WORKGROUP2）の OutputLocation が空です。t8・w1 が測れません。" >&2
    echo "        本物の項目は 1 本も投げていません。コンソールで出力先を設定してから再実行してください。" >&2
    exit 1
  fi
  echo "== preflight: SELECT 1 で疎通を確認する"
  if ! run_stmt "$RUN_DIR/.preflight" preflight-select1 "SELECT 1" "$CATALOG" "$DB"; then
    echo "run.sh: preflight の SELECT 1 が SUCCEEDED になりませんでした（$RUN_DIR/.preflight を見る）。止めます。" >&2
    exit 1
  fi
  TARGET_WG2_OUTPUT="$WG2_OUTPUT"
fi
export TCAT_GENERIC TCAT_ICEBERG TCAT_HIVE TDB WORKGROUP2 TARGET OUTPUT DB CATALOG REGION RUN_DIR SUMMARY OUTPUT_BUCKET
export TARGET_WG2_OUTPUT

# shellcheck source=tools/measure/unmeasured-batch/items-result-files.sh
source "$SCRIPT_DIR/items-result-files.sh"
# shellcheck source=tools/measure/unmeasured-batch/items-metadata.sh
source "$SCRIPT_DIR/items-metadata.sh"
# shellcheck source=tools/measure/unmeasured-batch/items-statements.sh
source "$SCRIPT_DIR/items-statements.sh"
# shellcheck source=tools/measure/unmeasured-batch/items-token.sh
source "$SCRIPT_DIR/items-token.sh"
# shellcheck source=tools/measure/unmeasured-batch/items-workgroup-errors.sh
source "$SCRIPT_DIR/items-workgroup-errors.sh"

ALL_ITEMS="r1 r2 r3 r4 x1 x2 m1 m2 m3 m5 s1 s2 p1 t4c t1 t5 t8 w1 e1"

want_item() {
  local id=$1
  [ -z "$ONLY" ] && return 0
  case ",$ONLY," in
    *",$id,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- フェーズ 2 の差し込み口: 保持期限の段階 A（ここ。本編より前。ONLY に t6/t7 が
# 無ければ 65 分待ちを起こさない設計にする） ---

for id in $ALL_ITEMS; do
  want_item "$id" || continue
  echo
  echo "---- $id ----"
  CURRENT_ITEM="$id"
  reset_item_rows "$id"
  "item_$id" "$id" || echo "== $id: 0 以外を返しました（続ける）"
done

# --- フェーズ 2 の差し込み口: 保持期限の段階 B（ここ。本編の後・report.py の前） ---

python3 "$SCRIPT_DIR/report.py" "$RUN_DIR" "$TARGET"

echo
echo "完了しました。"
echo "機械可読な一覧: $SUMMARY"
echo "そのまま貼れる要約: $RUN_DIR/summary.txt"
echo "消し残しのヒント（Hive 外部テーブルの LOCATION）: $RUN_DIR/cleanup-hints.txt"
echo "中身のファイルは $RUN_DIR にあります。リポジトリには入れないでください。"
