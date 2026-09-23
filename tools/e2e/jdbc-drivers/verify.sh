#!/usr/bin/env bash
# issue #111: Athena JDBC 3.x の版ごとの実機検証（本物の AWS は使わない。足場は tools/e2e/minio/）。
#   (3) 失敗した DDL の <id>.txt（athena-local が `FAILED: ` + 理由を置く）をドライバが読みに行かないか
#       （Main のシナリオ 111。nginx のログで .txt* への GET を数える）
#   (6) 旧版（3.0.0〜3.5.0）が athena-local の素の protobuf の .txt.metadata（SHOW 系）を読めるか
#       （シナリオ 57。合否は RESULT SHOW_* 行だけ）
# 3.8.1 は対照として fetcher 未指定・S3・GetQueryResults × 46/57/111 の 9 回。旧版は
# {auto（3.4.0 以上のみ）, S3} × {57, 111}。compose は 1 回だけ立て、ループの中では down しない。
#
# 使い方:
#   SKIP_BUILD=1 bash tools/e2e/jdbc-drivers/verify.sh
# 環境変数:
#   DRIVER_VERSIONS  版の一覧（既定 "3.8.1 3.5.0 3.4.0 3.3.0 3.2.2 3.1.0 3.0.0"）。取れない版は SKIP
#   SKIP_BUILD=1     cargo build を省き、既存の target/release/athena-local を使う
#   KEEP_UP=1        終了後に docker compose down -v をしない
#   JVM_TIMEOUT      JVM 1 回の上限秒（既定 300。超えたらその回は SKIP「ハング」）
# 終了コードは FAIL の件数（INFO と SKIP は数えない）。証跡は /tmp/athena-local-issue111-jdbc.* に残る。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"
# shellcheck source=judge.sh
. "$SCRIPT_DIR/judge.sh"

CONTROL_VERSION="3.8.1"
DRIVER_VERSIONS="${DRIVER_VERSIONS:-3.8.1 3.5.0 3.4.0 3.3.0 3.2.2 3.1.0 3.0.0}"
# 3.1.0 で `awsathena` が非推奨になったので、全版 `athena` にそろえる。
JDBC_URL="jdbc:athena://"
OUT_ROOT="$(mktemp -d /tmp/athena-local-issue111-jdbc.XXXXXX)"
SUMMARY_FAILS=0
# 自分で up したときだけ down する（ポートが使用中で止まったとき、同じプロジェクト名で動いている
# 別の検証（minio/verify.sh など）を落とさないため）。
COMPOSE_STARTED=0

cleanup() {
  if [ -n "$ATHENA_PID" ] && kill -0 "$ATHENA_PID" 2>/dev/null; then
    kill "$ATHENA_PID" 2>/dev/null || true
    wait "$ATHENA_PID" 2>/dev/null || true
  fi
  if [ "$COMPOSE_STARTED" = "1" ]; then
    dc logs --no-color tls-proxy >"$OUT_ROOT/tls-proxy.log" 2>&1 || true
    if [ "${KEEP_UP:-0}" = "1" ]; then
      log "KEEP_UP=1 のため docker compose はそのまま残す"
    else
      dc down -v >/dev/null 2>&1
    fi
  fi
  # パイプに流すとサブシェルで SUMMARY_FAILS が失われるので、ファイルに書いてから表示する。
  print_summary >"$OUT_ROOT/summary.txt"
  cat "$OUT_ROOT/summary.txt"
  [ "$SUMMARY_FAILS" -gt 100 ] && SUMMARY_FAILS=100
  exit "$SUMMARY_FAILS"
}

# 版ごとの組み合わせ（fetcher:シナリオ）。auto は ResultFetcher を指定しないこと（3.4.0 から auto が既定）。
combos_for() {
  local ver="$1" f s fetchers scenarios
  if [ "$ver" = "$CONTROL_VERSION" ]; then
    fetchers="auto S3 GetQueryResults"
    scenarios="46 57 111"
  else
    fetchers="S3"
    [ "$(printf '%s\n%s\n' "3.4.0" "$ver" | sort -V | head -1)" = "3.4.0" ] && fetchers="auto S3"
    scenarios="57 111"
  fi
  for f in $fetchers; do
    for s in $scenarios; do echo "$f:$s"; done
  done
}

# JVM 1 回: 出力先を版・fetcher・シナリオで分け、判定して表のセルに入れる。
run_one() {
  local ver="$1" fetcher="$2" scenario="$3" prefix output fetcher_arg="" out rc nlog
  prefix="/$PREFIX_ROOT/$ver/$fetcher/$scenario/"
  output="s3://$BUCKET$prefix"
  [ "$fetcher" != "auto" ] && fetcher_arg="$fetcher"
  out="$OUT_ROOT/$ver/$fetcher-$scenario.log"
  nlog="$OUT_ROOT/$ver/$fetcher-$scenario.nginx.log"
  mkdir -p "$OUT_ROOT/$ver"
  log "JDBC $ver ResultFetcher=$fetcher シナリオ $scenario（出力先 $output）"
  run_jvm "$ver" "$fetcher_arg" "$scenario" "$output" "$JDBC_URL" "$out"
  rc=$?
  dc logs --no-color tls-proxy >"$nlog" 2>&1
  judge_run "$ver" "$fetcher" "$scenario" "$out" "$rc" "$nlog" "$prefix" "$JDBC_URL" "$output"
  CELL["$ver|$fetcher|$scenario"]="$JUDGE_STATUS"
  record "$ver $fetcher/$scenario" "$JUDGE_STATUS" "$JUDGE_DETAIL"
}

run_version() {
  local ver="$1" combo
  if ! prepare_driver "$ver"; then
    for combo in $(combos_for "$ver"); do
      CELL["$ver|${combo%%:*}|${combo##*:}"]=SKIP
      record "$ver ${combo%%:*}/${combo##*:}" SKIP "未測定: $DRIVER_SKIP_REASON"
    done
    return 0
  fi
  for combo in $(combos_for "$ver"); do
    run_one "$ver" "${combo%%:*}" "${combo##*:}"
  done
}

main() {
  log "証跡: $OUT_ROOT"
  trap cleanup EXIT
  preflight_tools || exit
  prepare_cert || exit
  build_athena_local || exit
  COMPOSE_STARTED=1
  compose_up || exit
  start_athena_local || exit
  build_jdbc_client || exit
  check_nginx_log_format || exit
  local ver
  for ver in $DRIVER_VERSIONS; do
    run_version "$ver"
  done
  log "完了"
}

main "$@"
