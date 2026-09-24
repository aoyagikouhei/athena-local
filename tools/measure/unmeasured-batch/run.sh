#!/usr/bin/env bash
# issue #113: 未実測 28 件（既に答えがある 5 件は除く）を本物の Athena に投げるバッチ。
# #113 ではバッチを作って TARGET=local でドライランするところまで。本物での実行は、SQL / API の
# 項目（aws CLI で投げるもの）を #146、生 HTTP（raw.py）と保持期限（t6/t7）を #147 で流す
# （1 件の失敗が他を道連れにしないため。生 HTTP の preflight は ONLY に生 HTTP の項目があるときだけ通す）:
#   #146: ONLY=r1,r2,r3,r4,x1,x2,m1,m2,m3,m5,s1,s2,p1,t1,t4c,t5,t8,w1,e1（約 10 分。落ちた項目は
#         RUN_DIR=<同じ run> ONLY=<id,...> で再実行）
#   #147: ONLY=t2,t3,t4,e2（生 HTTP）と、ONLY=t6 → 65 分以上あとに RUN_DIR=<同じ run> ONLY=t7
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
#   WAIT_RETENTION 0 なら t6/t7 の段階 A/B を丸ごと省いて skip 行だけ出す（既定 1）。
#                  ONLY に t6/t7 のどちらも無ければ、これが 1 でも待ちは起こさない。
#   LOCAL_RETENTION_SECONDS  TARGET=local で t6/t7 用に athena-local へ渡す短い保持期限
#                  （既定 120 秒。他の項目の再送がこの秒数に収まるように大きさを決める）。
#   SKIP_BUILD     1 なら TARGET=local で cargo build を省く。
#   POLL_TIMEOUT・RETRY_MAX・RETRY_DELAY  既定 180 / 4 / 5（lib-aws.sh が使う）。
#
# 出力: ${DEV_HOST_HOME:-$HOME}/athena-unmeasured-batch-measurements/run-<日時>/<項目id>/
#   に文ごとのファイル、run 直下に summary.tsv（機械可読）と summary.txt（そのまま貼れる要約）。
#
# items-result-files.sh（r1-r4, x1, x2）、items-metadata.sh（m1-m3, m5）、
# items-statements.sh（s1, s2, p1）、items-token.sh（t1, t2, t3, t4, t5, t8, t4c）、
# items-workgroup-errors.sh（w1, e1, e2）、items-retention.sh（t6, t7）に全 28 項目（既に
# 答えのある 5 件を除く）を分けてある。t2・t3・t4・e2 は raw.py（生 HTTP。aws CLI では送れない
# 短いトークンなどを扱う）を通す。t6・t7（保持期限）は「フェーズ 2 の差し込み口」参照。

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
LOCAL_RETENTION_SECONDS=${LOCAL_RETENTION_SECONDS:-120}
SKIP_BUILD=${SKIP_BUILD:-0}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}
# --region を渡していても、botocore/awscli はリージョンの決定経路で IMDS に問い合わせに
# 行くことがあり、届かない環境（toolbox）では 1 回 2 秒以上待つ（2026-09-24 実測）。
export AWS_EC2_METADATA_DISABLED=true

case "$TARGET" in
  real | local) ;;
  *)
    echo "run.sh: TARGET は real か local（$TARGET は不明）" >&2
    exit 2
    ;;
esac

# ONLY だけで決まる判定なので、TARGET の分岐（athena-local の保持期限を短くするかどうか）
# より前に置く。items-retention.sh もこれをそのまま使う。
want_item() {
  local id=$1
  [ -z "$ONLY" ] && return 0
  case ",$ONLY," in
    *",$id,"*) return 0 ;;
    *) return 1 ;;
  esac
}
RETENTION_SELECTED=0
if want_item t6 || want_item t7; then RETENTION_SELECTED=1; fi
# 生 HTTP（raw.py）の項目。real ではこれが 1 つも無ければ raw.py の preflight を通さない
# （署名や送り先の不備で aws CLI の項目まで止めないため。#146）。local は常に通す
# （raw.py の送り先が athena-local である証拠を毎回残す。#113 の受け入れ判定 2）。
RAW_SELECTED=0
if want_item t2 || want_item t3 || want_item t4 || want_item e2; then RAW_SELECTED=1; fi

# 作るテーブル・ビューの接頭辞。作る前に SHOW TABLES で同名が無いことを確かめる（probe_prefix_exists）。
PROBE_PREFIX="athena_local_probe_113"

RUN_DIR=${RUN_DIR:-"${DEV_HOST_HOME:-$HOME}/athena-unmeasured-batch-measurements/run-$(date +%Y%m%d-%H%M%S)"}
mkdir -p "$RUN_DIR"
# RUN_DIR を作った直後（既にあれば書かない）に開始時刻を残す。report.py がここから
# 「開始時刻」と「開始+90分」を出す（RUN_DIR 再開では最初の実行の時刻のまま変わらない）。
if [ ! -f "$RUN_DIR/started_at" ]; then
  date '+%Y-%m-%dT%H:%M:%S' >"$RUN_DIR/started_at"
fi
touch "$RUN_DIR/cleanup-hints.txt" "$RUN_DIR/created.tsv"
SUMMARY="$RUN_DIR/summary.tsv"
if [ ! -f "$SUMMARY" ]; then
  printf 'item_id\tlabel\tkind\tstate\tstatement_type\tsubstatement_type\tloc_shape\tbody_bytes\tbody_ct\tmetadata_bytes\tmetadata_ct\texpected\tactual\tmatch\tnote\n' >"$SUMMARY"
fi
echo "出力先: $RUN_DIR"

# shellcheck source=tools/measure/unmeasured-batch/lib-aws.sh
source "$SCRIPT_DIR/lib-aws.sh"
# shellcheck source=tools/measure/unmeasured-batch/lib-cleanup.sh
source "$SCRIPT_DIR/lib-cleanup.sh"
# shellcheck source=tools/measure/unmeasured-batch/lib-raw.sh
source "$SCRIPT_DIR/lib-raw.sh"

if [ "$TARGET" = local ]; then
  # shellcheck source=tools/measure/unmeasured-batch/lib-local.sh
  source "$SCRIPT_DIR/lib-local.sh"
  local_harden_credentials
  cleanup_local() { local_down; }
  trap cleanup_local EXIT
  # t6/t7 を測るときだけ保持期限を短くする（他の項目には影響しない。WAIT_RETENTION=0 や
  # ONLY に t6/t7 が無いときは既定の 3600 のまま）。
  local_retention_arg=3600
  if [ "$WAIT_RETENTION" != 0 ] && [ "$RETENTION_SELECTED" = 1 ]; then
    local_retention_arg=$LOCAL_RETENTION_SECONDS
  fi
  if ! local_up "$local_retention_arg"; then
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
  RAW_ENDPOINT="$LOCAL_ATHENA_BASE/"
  RAW_TARGET=local

  echo "== preflight: raw.py で ListWorkGroups を確認する（aws CLI の疎通とは別経路）"
  raw_preflight
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
  RAW_ENDPOINT="https://athena.$REGION.amazonaws.com/"
  RAW_TARGET=real

  if [ "$RAW_SELECTED" = 1 ]; then
    echo "== preflight: raw.py で ListWorkGroups を確認する（aws CLI の疎通とは別経路）"
    raw_preflight
  else
    echo "== preflight: 生 HTTP の項目（t2/t3/t4/e2）が無いので raw.py の preflight は通さない"
  fi

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

  # 中断時（正常終了時も含む。finish_cleanup の後始末で消しきれなかった分の再送）の保険。
  # created.tsv に残っているものへ DROP IF EXISTS を投げる（結果は待たない）。投げた本数と
  # 開始に失敗した本数を標準出力に出す。
  cleanup_real() {
    [ -s "$RUN_DIR/created.tsv" ] || return 0
    echo "== 中断時の後始末: created.tsv に残っているものへ DROP IF EXISTS を投げる" >&2
    local kind name catalog database total=0 started=0
    while IFS=$'\t' read -r kind name catalog database; do
      [ -n "${kind:-}" ] || continue
      total=$((total + 1))
      best_effort_drop "$kind" "$name" "$catalog" "$database" && started=$((started + 1))
    done <"$RUN_DIR/created.tsv"
    echo "中断時の後始末（再送）: DROP IF EXISTS ${total}本中 ${started}本を投げた（開始に失敗=$((total - started))本）"
  }
  trap cleanup_real EXIT
fi
export TCAT_GENERIC TCAT_ICEBERG TCAT_HIVE TDB WORKGROUP2 TARGET OUTPUT DB CATALOG REGION RUN_DIR SUMMARY OUTPUT_BUCKET
export TARGET_WG2_OUTPUT RAW_ENDPOINT RAW_TARGET LOCAL_RETENTION_SECONDS

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
# shellcheck source=tools/measure/unmeasured-batch/items-retention.sh
source "$SCRIPT_DIR/items-retention.sh"

ALL_ITEMS="r1 r2 r3 r4 x1 x2 m1 m2 m3 m5 s1 s2 p1 t4c t1 t2 t3 t4 t5 t8 w1 e1 e2"

# --- フェーズ 2 の差し込み口: 保持期限の段階 A（ここ。本編より前。ONLY に t6/t7 が
# 無ければ 65 分待ちを起こさない設計にする） ---

if [ "$RETENTION_SELECTED" = 1 ]; then
  # t6 の行は、段階 A を新しく流すとき（state.env が無いとき）だけ消す。RUN_DIR を
  # 指定した再開（例: ONLY=t7 だけで段階 B を流し直す）では、前回の段階 A の行を残す。
  if [ ! -s "$RETENTION_STATE" ]; then
    reset_item_rows t6
  fi
  reset_item_rows t7
  if [ "$WAIT_RETENTION" = 0 ]; then
    skip_item t6 phase-a "WAIT_RETENTION=0のため実行しない"
    skip_item t7 phase-b "WAIT_RETENTION=0のため実行しない"
  else
    retention_phase_a
  fi
fi

for id in $ALL_ITEMS; do
  want_item "$id" || continue
  echo
  echo "---- $id ----"
  CURRENT_ITEM="$id"
  reset_item_rows "$id"
  "item_$id" "$id" || echo "== $id: 0 以外を返しました（続ける）"
done

# --- フェーズ 2 の差し込み口: 保持期限の段階 B（ここ。本編の後・report.py の前） ---

if [ "$RETENTION_SELECTED" = 1 ] && [ "$WAIT_RETENTION" != 0 ]; then
  retention_phase_b
fi

if [ "$TARGET" = real ]; then
  echo
  echo "== 後始末: drops.tsv の DROP を終端状態まで待つ"
  finish_cleanup
fi

python3 "$SCRIPT_DIR/report.py" "$RUN_DIR" "$TARGET"

echo
echo "完了しました。"
echo "機械可読な一覧: $SUMMARY"
echo "そのまま貼れる要約: $RUN_DIR/summary.txt"
echo "消し残しのヒント（Hive 外部テーブルの LOCATION）: $RUN_DIR/cleanup-hints.txt"
echo "中身のファイルは $RUN_DIR にあります。リポジトリには入れないでください。"
