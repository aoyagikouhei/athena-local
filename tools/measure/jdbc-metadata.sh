#!/usr/bin/env bash
# issue #46 で作成（tools/ へ移す前の名前は 46-verify-jdbc-metadata.sh）
# issue #46 実機検証: 列を 1 つも持たない .metadata を、公式 Athena JDBC ドライバ 3.8.1 が
# 例外なく読めるかを確かめる。
#
# #39 で athena-local は次の 2 つで「列 0 個の .metadata」を置くようになった。
#   DROP TABLE（Iceberg）              -> 41 バイト（field 1 = エンジンのクエリ ID、field 2 = "DROP TABLE"）
#   ALTER TABLE ... ADD COLUMNS（Hive） -> 38 バイト（field 1 = QueryExecutionId のみ）
# .metadata は本来、結果の列情報を JDBC ドライバに渡すためのもので、列 0 個は本来の用途から外れた形。
# Athena JDBC 3.x は既定の ResultFetcher=auto で S3 から結果ファイルと .metadata を直接読むため、
# ここで例外を投げないかが焦点。
#
# 本物の AWS は一切使わない（Trino + MinIO + nginx + JDBC クライアントをすべてローカルの
# docker compose で立てる）。課金は発生しない。DDL はローカルの Trino に対してのみ。
#
# 使い方:
#   tools/dev.sh bash tools/measure/jdbc-metadata.sh
#
# 環境変数:
#   KEEP_UP=1     終了後に docker compose down -v <サービス...> をせず環境を残す（デバッグ用）
#   SKIP_BUILD=1  cargo build を省略し、既存の $CARGO_TARGET_DIR（tools/dev.sh では .toolbox/target）の release/athena-local を使う
#
# 環境（compose・証明書・ドライバの取得・athena-local の起動・JVM の実行）は jdbc 系 3 本
# （このスクリプト、tools/measure/jdbc-show-metadata.sh、tools/e2e/jdbc-drivers/verify.sh）が共有する
# tools/e2e/jdbc-drivers/lib.sh（#115）。ここには判定（run_jdbc_case・collect_metadata・check_s3_access）と
# 本体の流れだけを書く。開始時に down -v → up -d で作り直す。後始末は trap が行う
# （KEEP_UP=1 でなければ必ず使ったサービスだけ docker compose down -v する。dev は残す）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# lib.sh の既定から変える値（source の前に代入する）。
PREFIX_ROOT="e2e-jdbc"
TRINO_SETUP_USER="issue46-setup"
ATHENA_TRINO_USER="athena-local-issue46"
# shellcheck source=../e2e/jdbc-drivers/lib.sh
. "$REPO_ROOT/tools/e2e/jdbc-drivers/lib.sh"
log() { echo "[verify46] $*" >&2; }

PREFIX="$PREFIX_ROOT"
OUTPUT_LOCATION="s3://${BUCKET}/${PREFIX}/"
DRIVER_VERSION="3.8.1"

# 出力はリポジトリの外に置く（生ログを追跡しない）。
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_ROOT="${DEV_HOST_HOME:-$HOME}/athena-local-issue46-measurements/run-$(date +%Y%m%d-%H%M%S)"
SUMMARY="$OUT_ROOT/summary.txt"

declare -a RESULT_NAMES=()
declare -a RESULT_STATUS=()
declare -a RESULT_DETAIL=()

record() {
  RESULT_NAMES+=("$1")
  RESULT_STATUS+=("$2")
  RESULT_DETAIL+=("$3")
}

print_table() {
  {
    echo
    echo "==================== issue #46 実測結果 ===================="
    echo "ドライバ: Athena JDBC $DRIVER_VERSION"
    echo "本物の AWS への呼び出し: 0 回（ドライバ jar のダウンロードのみ）。課金なし。"
    echo "DDL: ローカルの Trino に対してのみ（compose の down -v <サービス...> で消える）"
    echo
    local i
    for i in "${!RESULT_NAMES[@]}"; do
      printf '%-8s %-46s %s\n' "${RESULT_STATUS[$i]}" "${RESULT_NAMES[$i]}" "${RESULT_DETAIL[$i]}"
    done
    echo
    echo "証跡: $OUT_ROOT"
  } | tee -a "$SUMMARY"
}

cleanup() {
  local status=$?
  if [ -n "$ATHENA_PID" ] && kill -0 "$ATHENA_PID" 2>/dev/null; then
    log "athena-local (PID $ATHENA_PID) を止める"
    kill "$ATHENA_PID" 2>/dev/null || true
    wait "$ATHENA_PID" 2>/dev/null || true
  fi
  # nginx（tls-proxy）のアクセスログは down の前に回収する。
  if dc ps -q tls-proxy >/dev/null 2>&1; then
    dc logs --no-color tls-proxy >"$OUT_ROOT/tls-proxy.log" 2>&1 || true
  fi
  if [ "${KEEP_UP:-0}" = "1" ]; then
    log "KEEP_UP=1 のため docker compose はそのまま残す（後で tools/dev.sh docker compose -f $REPO_ROOT/compose.yml down -v ${SERVICES[*]}）"
  else
    log "docker compose down -v ${SERVICES[*]}"
    dc down -v "${SERVICES[@]}" >/dev/null 2>&1
  fi
  print_table
  exit "$status"
}

mkdir -p "$OUT_ROOT"
trap cleanup EXIT

# $1 = ラベル, $2 = Main に渡す ResultFetcher（空なら未指定 = 既定の auto）
run_jdbc_case() {
  local label="$1" fetcher="$2"
  local out="$OUT_ROOT/jdbc-$label.log"
  log "JDBC 実行: $label（ResultFetcher=${fetcher:-未指定=既定}）"

  run_jvm "$DRIVER_VERSION" "$fetcher" 46 "$OUTPUT_LOCATION" "" "$out"
  local rc=$?
  if [ "$rc" = "97" ]; then
    record "JDBC $label" FAIL "tls-proxy の IP を取得できなかった"
    return 0
  fi
  if [ "$rc" = "124" ]; then
    record "JDBC $label" FAIL "ハングした（timeout ${JVM_TIMEOUT:-300} 秒）。ログ: $out"
    return 0
  fi

  local failures
  failures=$(grep -o 'failures=[0-9]*' "$out" | tail -1)
  if [ "$rc" = "0" ] && [ "$failures" = "failures=0" ]; then
    record "JDBC $label" PASS "4 ケースすべて例外なし（$failures）"
  else
    record "JDBC $label" FAIL "rc=$rc ${failures:-（総括行が出ていない）}。ログ: $out"
  fi
  return 0
}

# S3 に置かれた .metadata を回収し、サイズと中身を記録する。
collect_metadata() {
  local listing="$OUT_ROOT/s3-listing.txt"
  mc_run "mc ls --recursive 'local/$BUCKET/$PREFIX/'" >"$listing" 2>&1

  local keys
  keys=$(mc_run "mc ls --recursive 'local/$BUCKET/$PREFIX/'" 2>/dev/null | awk '{print $NF}' | grep '\.metadata$')
  if [ -z "$keys" ]; then
    record ".metadata 回収" FAIL "1 つも置かれていない（一覧: $listing）"
    return 0
  fi

  local dir="$OUT_ROOT/metadata"
  mkdir -p "$dir"
  local sizes=() k n
  while IFS= read -r k; do
    [ -z "$k" ] && continue
    n=$(basename "$k")
    # 取得はコンテナの標準出力に流し、リダイレクトはホスト側のシェルが行う
    # （CLAUDE.md: CLI が Docker ラッパのとき、コンテナ内の絶対パスへの書き出しは消える）。
    mc_run "mc cat 'local/$BUCKET/$PREFIX/$k' | base64" 2>/dev/null | tr -d '\r\n' | base64 -d >"$dir/$n" 2>/dev/null
    sizes+=("$(stat -c %s "$dir/$n" 2>/dev/null || echo 0)")
    od -An -tx1c "$dir/$n" >"$dir/$n.od" 2>/dev/null
  done <<<"$keys"

  local joined
  joined=$(printf '%s ' "${sizes[@]}")
  record ".metadata 回収" PASS "$(echo "$keys" | wc -l) 個。バイト数: $joined（中身は $dir/*.od）"

  # 焦点の 2 つ（41 バイト = DROP TABLE Iceberg、38 バイト = ALTER TABLE ADD COLUMNS Hive）が
  # 実際に置かれたかを確かめる。ここが無いと「列 0 個を読ませた」ことにならない。
  local has41=no has38=no
  for s in "${sizes[@]}"; do
    [ "$s" = "41" ] && has41=yes
    [ "$s" = "38" ] && has38=yes
  done
  if [ "$has41" = "yes" ] && [ "$has38" = "yes" ]; then
    record "列 0 個の .metadata の存在" PASS "41 バイトと 38 バイトの両方が置かれた（検証対象が実在した）"
  else
    record "列 0 個の .metadata の存在" FAIL "41B=$has41 38B=$has38（検証対象が置かれていない）"
  fi
  return 0
}

# ドライバが本当に S3 から「列 0 個」の .metadata を読んだかを nginx のアクセスログで確かめる。
# 拡張子なしの <id>.metadata（DROP TABLE・ALTER TABLE が置くもの。UUID の直後が .metadata）だけを数える。
# .csv.metadata・.txt.metadata（対照の SELECT・接続テストが置くもの）は含めない（#115、2026-09-24:
# 以前は `.metadata` の部分一致だったため、PREFLIGHT が置く .csv.metadata だけでも満たされていた）。
check_s3_access() {
  local nlog="$OUT_ROOT/tls-proxy-live.log"
  dc logs --no-color tls-proxy >"$nlog" 2>&1
  local meta_gets
  meta_gets=$(grep -oE 'GET [^"]*\.metadata' "$nlog" 2>/dev/null | grep -vcE '\.(csv|txt)\.metadata$')
  meta_gets=${meta_gets:-0}
  if [ "$meta_gets" -gt 0 ]; then
    record "S3 直読みの裏取り" PASS "拡張子なしの .metadata への GET が $meta_gets 件（ドライバが S3 から読んだ）"
  else
    record "S3 直読みの裏取り" FAIL "拡張子なしの .metadata への GET が 0 件（S3 経路を通っていない可能性。ログ: $nlog）"
  fi
  return 0
}

# ---------------- 本体 ----------------

log "証跡: $OUT_ROOT"
preflight_tools || exit 1
prepare_cert || exit 1
prepare_driver "$DRIVER_VERSION" || { record "ドライバ取得" FAIL "$DRIVER_SKIP_REASON"; exit 1; }
build_athena_local || exit 1
compose_up || exit 1
start_athena_local || exit 1
build_jdbc_client || exit 1

# 焦点: 既定（auto）。対照: S3 を明示（auto が S3 を選ばなかった場合でも同じ経路を通す）。
run_jdbc_case "auto" ""
run_jdbc_case "S3" "S3"

collect_metadata
check_s3_access

log "完了"
