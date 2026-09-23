#!/usr/bin/env bash
# issue #57 で作成（tools/ へ移す前の名前は 57-verify-jdbc-show-metadata.sh）
# issue #57 実機検証: SHOW TABLES 以外の SHOW 文の .txt.metadata（素の protobuf）を、公式 Athena JDBC
# ドライバ 3.8.1 の既定 ResultFetcher=auto が例外なく読めるかを確かめる。
#
# 本物の Athena は SHOW TABLES / SHOW DATABASES / SHOW COLUMNS / SHOW PARTITIONS / SHOW TBLPROPERTIES の
# .txt.metadata に不透明な形式（docs/caveats.md）を置くが、athena-local は素の protobuf を置く。
# JDBC が読めることを実機で確かめたのは SHOW TABLES だけ（#5）だったので、残りを測る。
#
# Trino の文法には SHOW DATABASES / SHOW PARTITIONS / SHOW TBLPROPERTIES が無い。そこで同じラウンドに
#   - Trino の同義文（SHOW SCHEMAS = athena-local が SHOW_DATABASES に分類する文、SHOW COLUMNS FROM）
#   - Athena の原文（そのまま投げて、どこで弾かれるかを記録する。弾かれたら REJECTED で失敗に数えない）
#   - 対照（SHOW TABLES、SELECT ... "t$partitions"）
# を入れ、ResultFetcher を auto / S3 / GetQueryResults の 3 通りで流して行数を突き合わせる
# （GetQueryResults は .metadata を読まない経路なので、行数の基準になる）。
#
# 本物の AWS は一切使わない（Trino + MinIO + nginx + JDBC クライアントをすべてローカルの
# docker compose で立てる）。課金は発生しない。DDL はローカルの Trino に対してのみ。
#
# 使い方:
#   tools/dev.sh bash tools/measure/jdbc-show-metadata.sh
#
# 環境変数:
#   KEEP_UP=1     終了後に docker compose down -v <サービス...> をせず環境を残す（デバッグ用）
#   SKIP_BUILD=1  cargo build を省略し、既存の $CARGO_TARGET_DIR（tools/dev.sh では .toolbox/target）の release/athena-local を使う
#
# 環境（compose・証明書・ドライバの取得・athena-local の起動・JVM の実行）は jdbc 系 3 本
# （tools/measure/jdbc-metadata.sh、このスクリプト、tools/e2e/jdbc-drivers/verify.sh）が共有する
# tools/e2e/jdbc-drivers/lib.sh（#115）。ここには判定（run_jdbc_case・collect_metadata・check_s3_access・
# check_metadata_loaded・compare_row_counts）と本体の流れだけを書く。開始時に down -v → up -d で作り直す。
# 後始末は trap が行う（KEEP_UP=1 でなければ必ず使ったサービスだけ docker compose down -v する。dev は残す）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# lib.sh の既定から変える値（source の前に代入する）。
PREFIX_ROOT="e2e-jdbc"
TRINO_SETUP_USER="issue57-setup"
ATHENA_TRINO_USER="athena-local-issue57"
# shellcheck source=../e2e/jdbc-drivers/lib.sh
. "$REPO_ROOT/tools/e2e/jdbc-drivers/lib.sh"
log() { echo "[verify57] $*" >&2; }

PREFIX="$PREFIX_ROOT"
OUTPUT_LOCATION="s3://${BUCKET}/${PREFIX}/"
DRIVER_VERSION="3.8.1"

# 出力はリポジトリの外に置く（生ログを追跡しない）。
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_ROOT="${DEV_HOST_HOME:-$HOME}/athena-local-issue57-measurements/run-$(date +%Y%m%d-%H%M%S)"
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
    echo "==================== issue #57 実測結果 ===================="
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

  run_jvm "$DRIVER_VERSION" "$fetcher" 57 "$OUTPUT_LOCATION" "" "$out"
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
    record "JDBC $label" PASS "全ケース例外なし（$failures。REJECTED は失敗に数えない）"
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

  # 焦点: SHOW SCHEMAS / SHOW COLUMNS / SHOW TABLES の 3 文が 3 ラウンド（auto / S3 / GetQueryResults）で
  # 置く .txt.metadata は 9 個のはず。原文の 3 文（SHOW DATABASES / PARTITIONS / TBLPROPERTIES）が
  # もし Trino に通って .txt.metadata を置いたら 9 を超える。少なければ SHOW の .txt.metadata が置かれていない。
  local txt_meta csv_meta
  txt_meta=$(echo "$keys" | grep -c '\.txt\.metadata$')
  csv_meta=$(echo "$keys" | grep -c '\.csv\.metadata$')
  if [ "$txt_meta" = "9" ]; then
    record "SHOW の .txt.metadata の存在" PASS ".txt.metadata が 9 個（3 文 × 3 ラウンド。原文 3 文は置いていない）"
  else
    record "SHOW の .txt.metadata の存在" FAIL ".txt.metadata が $txt_meta 個（期待 9。一覧: $listing）"
  fi
  # 9 個 = \$partitions の SELECT × 3 ラウンド + ドライバが接続時に流す接続テストの SELECT × 3 ラウンド
  # （#5 で見つけた `-- Athena JDBC driver connection test\nSELECT 1`。#52 で先頭コメントを読み飛ばすようになり .csv になった）
  # + Main が本体の前に流す PREFLIGHT の SELECT 1 × 3 ラウンド（#111 で足した。以前の「6 のはず」はこの分を
  # 数え漏らしていた。#115、2026-09-24 に基準値の実行で 9 個を確認）。
  record ".csv.metadata（対照 SELECT）" INFO "$csv_meta 個（\$partitions の SELECT × 3 + 接続テストの SELECT × 3 + PREFLIGHT の SELECT 1 × 3 = 9 のはず）"
  return 0
}

# ドライバが本当に S3 から SHOW の .txt.metadata を読んだかを nginx のアクセスログで確かめる。
# .txt.metadata への GET だけを数える（.csv.metadata・拡張子なしの .metadata は含めない。#115、2026-09-24:
# 以前は `.metadata` の部分一致だったため、PREFLIGHT が置く .csv.metadata だけでも満たされていた）。
check_s3_access() {
  local nlog="$OUT_ROOT/tls-proxy-live.log"
  dc logs --no-color tls-proxy >"$nlog" 2>&1
  local meta_gets
  meta_gets=$(grep -cE 'GET [^"]*\.txt\.metadata' "$nlog" 2>/dev/null)
  meta_gets=${meta_gets:-0}
  if [ "$meta_gets" -gt 0 ]; then
    record "S3 直読みの裏取り" PASS ".txt.metadata への GET が $meta_gets 件（ドライバが S3 から読んだ）"
  else
    record "S3 直読みの裏取り" FAIL ".txt.metadata への GET が 0 件（S3 経路を通っていない可能性。ログ: $nlog）"
  fi
  return 0
}

# ドライバが .txt.metadata を「読んで」列情報に使ったことを、ドライバ自身のログで裏取りする
# （S3 の GET だけでは、読んだあと捨てたのか区別できない）。
# 既定の auto が焦点。ResultFetcher=S3 を明示したときは、ラウンド 1（2026-09-22）で .txt.metadata を
# 1 つも取りに行かなかった（.csv.metadata と INSERT の .metadata は取った）ので、件数を観察として残すだけにする。
check_metadata_loaded() {
  local n
  n=$(grep -c 'loaded query result metadata from "[^"]*\.txt\.metadata"' "$OUT_ROOT/jdbc-auto.log" 2>/dev/null)
  n=${n:-0}
  if [ "$n" -ge 3 ]; then
    record "ドライバが .txt.metadata を読んだ(auto)" PASS "loaded query result metadata ... .txt.metadata が $n 件（SHOW 3 文）"
  else
    record "ドライバが .txt.metadata を読んだ(auto)" FAIL "該当ログが $n 件（期待 3 以上）。ログ: $OUT_ROOT/jdbc-auto.log"
  fi
  n=$(grep -c 'loaded query result metadata from "[^"]*\.txt\.metadata"' "$OUT_ROOT/jdbc-S3.log" 2>/dev/null)
  record "ドライバが .txt.metadata を読んだ(S3 明示)" INFO "該当ログが ${n:-0} 件（S3 を明示すると SHOW の .txt.metadata は取りに行かない。観察のみ）"
  return 0
}

# ケースごとの行数と列数を ResultFetcher の 3 通りで突き合わせる。
#   - auto と S3 は完全一致のはず（どちらも S3 の本体を読む）
#   - GetQueryResults も一致するはず。athena-local は #60 で本物に合わせ、UTILITY（SHOW / DESCRIBE）の 1 ページ目に
#     列名行を入れなくなった（docs/dev/measurements/clients.md の #57 の備考）。以前の「SHOW だけ +1 行」の期待は
#     その前の挙動で、#134 で外した。SELECT はドライバが見出し行を読み飛ばすので一致する。
compare_row_counts() {
  local base="$OUT_ROOT/jdbc-S3.log"
  local line label rows cols status got mismatch=0 total=0 want
  while IFS= read -r line; do
    label=$(echo "$line" | awk '{print $2}')
    rows=$(echo "$line" | sed -E 's/.* rows=(-?[0-9]+).*/\1/')
    cols=$(echo "$line" | sed -E 's/.* cols=(-?[0-9]+).*/\1/')
    status=$(echo "$line" | sed -E 's/.* status=([A-Z]+).*/\1/')
    total=$((total + 1))
    got=$(grep "^RESULT $label " "$OUT_ROOT/jdbc-auto.log" | sed -E 's/^RESULT [^ ]+ //')
    if [ "$got" != "rows=$rows cols=$cols status=$status" ]; then
      mismatch=$((mismatch + 1))
      record "突き合わせ $label" FAIL "S3: rows=$rows cols=$cols status=$status / auto: ${got:-（無し）}"
    fi
    want=$rows
    got=$(grep "^RESULT $label " "$OUT_ROOT/jdbc-GetQueryResults.log" | sed -E 's/^RESULT [^ ]+ //')
    if [ "$got" != "rows=$want cols=$cols status=$status" ]; then
      mismatch=$((mismatch + 1))
      record "突き合わせ $label" FAIL "期待 GetQueryResults: rows=$want cols=$cols status=$status / 実際: ${got:-（無し）}"
    fi
  done < <(grep '^RESULT ' "$base" 2>/dev/null)
  if [ "$total" = "0" ]; then
    record "行数の突き合わせ" FAIL "S3 のログに RESULT 行が無い"
  elif [ "$mismatch" = "0" ]; then
    record "行数の突き合わせ" PASS "$total ケースすべて auto = S3 = GetQueryResults で一致"
  fi
  {
    echo
    echo "--- ケースごとの結果（ResultFetcher=S3 のログ。GetQueryResults は SHOW で +1 行） ---"
    grep '^RESULT ' "$base" | sed 's/^/    /'
    echo "--- Trino の文法に無い原文 3 文の弾かれ方（ResultFetcher=auto のログ） ---"
    grep '^REJECTED ' "$OUT_ROOT/jdbc-auto.log" | sed 's/^/    /'
  } >>"$SUMMARY"
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
run_jdbc_case "GetQueryResults" "GetQueryResults"

collect_metadata
check_s3_access
check_metadata_loaded
compare_row_counts

log "完了"
