#!/usr/bin/env bash
# tools/measure 配下の実測ラウンドが共通で使う入口。#310。
#
# 使い方（ラウンドのスクリプトの先頭）:
#   #!/usr/bin/env bash
#   set -uo pipefail
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#   lib_init 307 athena_local_probe_307
#   run_query id1 db "SELECT 1"
#   athena_call id2 ListDatabases '{"CatalogName":"AwsDataCatalog"}'
#
# DRY_RUN=1 で流すと、本物の aws の代わりに lib/dry-run-bin/aws を PATH の先頭に置いて
# lib の全経路を通す（本物には1本も投げない）。tools/measure/lib/selftest.sh がこの
# モードだけで動く。
#
# 実行の芯（mask・aws・execution・run）と DRY_RUN の切り替えに加えて、preflight（実行系の
# 確認・DB の自動選択・PREFIX の衝突確認）、項目の宣言（item/api/run_items）、後始末の台帳
# （cleanup）、summary.txt（summary）も揃っている（#310 issue ノートの P-8 フェーズ 1・2）。
# ラウンドのスクリプト（フェーズ 3）は lib_init のあとに item/api を宣言し、最後に
# run_items を1回呼ぶだけでよい。
set -uo pipefail

LIB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 環境変数の既定値 ----------------------------------------------------------
OUTPUT=${OUTPUT:-}
DB=${DB:-}
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}
# 実名（DB 名・バケット名など）が入るのでリポジトリの外に出す。toolbox では
# DEV_HOST_HOME がホストのホームを指す（#129）。ラウンドのスクリプト（$0）の
# basename から .sh を除いたものをディレクトリ名に使う。
_lib_round_name="$(basename "${0:-round}")"
_lib_round_name="${_lib_round_name%.sh}"
OUT_DIR=${OUT_DIR:-${DEV_HOST_HOME:-$HOME}/athena-${_lib_round_name}-measurements}
unset _lib_round_name

# shellcheck source=tools/measure/lib/mask.sh
. "$LIB_ROOT/lib/mask.sh"
# shellcheck source=tools/measure/lib/aws.sh
. "$LIB_ROOT/lib/aws.sh"
# shellcheck source=tools/measure/lib/execution.sh
. "$LIB_ROOT/lib/execution.sh"
# shellcheck source=tools/measure/lib/run.sh
. "$LIB_ROOT/lib/run.sh"
# shellcheck source=tools/measure/lib/items.sh
. "$LIB_ROOT/lib/items.sh"
# shellcheck source=tools/measure/lib/cleanup.sh
. "$LIB_ROOT/lib/cleanup.sh"
# shellcheck source=tools/measure/lib/preflight.sh
. "$LIB_ROOT/lib/preflight.sh"
# shellcheck source=tools/measure/lib/summary.sh
. "$LIB_ROOT/lib/summary.sh"

# 異常終了時の保険。cleanup.sh の lib_cleanup_trap（created.tsv を読んでの DROP IF EXISTS）が
# これを上書きする（source の順序で後勝ち）。

# 実行の芯を組み立てる。<issue> は issue 番号、<PREFIX> はフィクスチャの名前の接頭辞
# （items.sh の record_created・cleanup.sh の DROP、preflight.sh の衝突確認が使う）。
lib_init() {
  ISSUE=$1
  PREFIX=$2

  if [ "${DRY_RUN:-0}" = 1 ]; then
    local dry_run_bin="$LIB_ROOT/lib/dry-run-bin"
    PATH="$dry_run_bin:$PATH"
    export PATH
    if [ "$(command -v aws)" != "$dry_run_bin/aws" ]; then
      echo "DRY_RUN=1 ですが偽の aws（$dry_run_bin/aws）が PATH の先頭にありません（command -v aws = $(command -v aws)）" >&2
      exit 1
    fi
    # 万一 PATH の偽物を通らない経路で本物の aws が呼ばれても、資格情報が
    # ダミーで接続先も存在しないため外へは出ない（計画攻撃 A2 の対応）。
    export AWS_ACCESS_KEY_ID=dry-run-access-key-id
    export AWS_SECRET_ACCESS_KEY=dry-run-secret-access-key
    export AWS_SESSION_TOKEN=dry-run-session-token
    export AWS_SHARED_CREDENTIALS_FILE=/dev/null
    export AWS_CONFIG_FILE=/dev/null
    export AWS_ENDPOINT_URL=http://127.0.0.1:9
    [ -n "$OUTPUT" ] || OUTPUT="s3://dry-run-bucket/prefix/"
  fi

  RUN_STAMP="$(date +%Y%m%d-%H%M%S)"
  RUN_DIR="$OUT_DIR/run-$RUN_STAMP"
  mkdir -p "$RUN_DIR"
  export RUN_DIR OUTPUT
  echo "出力先: $RUN_DIR"

  SUMMARY="$RUN_DIR/summary.tsv"
  printf 'id\tkind\tstate\tstatement_type\tsubstatement_type\text\tcontent_type\tmetadata_present\tupdate_count\trow_count\terror_category\terror_type\tstart_message\tstart_athena_error_code\tnote\n' > "$SUMMARY"

  # StartQueryExecution を実際に呼んだ回数（再試行込み）。start_query_retry が呼ぶたびに
  # 1行積み、最後に行数を数える（課金の見える化。CLAUDE.md の要件と同じ考え方）。
  START_CALL_FILE="$RUN_DIR/.start-calls"
  : > "$START_CALL_FILE"

  if [ "${DRY_RUN:-0}" = 1 ]; then
    mkdir -p "$RUN_DIR/.dry-run"
    : > "$RUN_DIR/.dry-run/calls.log"
  fi

  trap 'lib_cleanup_trap' EXIT

  # preflight.sh の lib_preflight（実行系の確認・DB の自動選択・PREFIX の衝突確認）を、
  # 宣言（item/api）より前に呼ぶ（宣言の SQL が $DB・$OUTPUT を展開するため）。
  if declare -f lib_preflight > /dev/null 2>&1; then
    lib_preflight
  fi
}
