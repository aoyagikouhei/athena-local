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
# 環境はルートの compose.yml の trino / minio / minio-init / tls-proxy と jdbc-client。開始時に down -v → up -d で作り直す。
# 後始末は trap が行う（KEEP_UP=1 でなければ必ず使ったサービスだけ docker compose down -v する。dev は残す）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# cargo の成果物の置き場。tools/dev.sh は CARGO_TARGET_DIR を .toolbox/target にする
BINARY="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/athena-local"
TLS_DIR="$REPO_ROOT/tools/compose/tls"
COMPOSE=(docker compose -f "$REPO_ROOT/compose.yml")
# 開始時に down -v → up -d で作り直し、後始末で落とすサービス（jdbc-client は run の使い捨てなので入れない）。
SERVICES=(trino minio minio-init tls-proxy)

TRINO_BASE="http://trino:8080"
ATHENA_BASE="http://127.0.0.1:8087"
BUCKET="athena-results"
PREFIX="e2e-jdbc"
OUTPUT_LOCATION="s3://${BUCKET}/${PREFIX}/"

# 公式ドライバ。Maven Central には無い（Maven Central の com.amazonaws:athena-jdbc は
# Athena Federated Query の JDBC コネクタで、java.sql.Driver を持たない別物）。
DRIVER_VERSION="3.8.1"
DRIVER_URL="https://downloads.athena.us-east-1.amazonaws.com/drivers/JDBC/${DRIVER_VERSION}/athena-jdbc-${DRIVER_VERSION}-with-dependencies.jar"
DRIVER_CACHE_DIR="$HOME/.cache/athena-local-jdbc"
DRIVER_CACHE="$DRIVER_CACHE_DIR/athena-jdbc-${DRIVER_VERSION}-with-dependencies.jar"
# コンテナ内のマウント先。ホストの jdbc-client/target/ は maven コンテナが root で作るため
# ホスト側から書けない。classpath に直接マウントして渡す。
DRIVER_MOUNT="/driver/athena-jdbc.jar"

# 出力はリポジトリの外に置く（生ログを追跡しない）。
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_ROOT="${DEV_HOST_HOME:-$HOME}/athena-local-issue46-measurements/run-$(date +%Y%m%d-%H%M%S)"
SUMMARY="$OUT_ROOT/summary.txt"
ATHENA_LOG="$OUT_ROOT/athena-local.log"
BUILD_LOG="$OUT_ROOT/cargo-build.log"
MVN_LOG="$OUT_ROOT/mvn.log"

ATHENA_PID=""

declare -a RESULT_NAMES=()
declare -a RESULT_STATUS=()
declare -a RESULT_DETAIL=()

log() { echo "[verify46] $*" >&2; }

record() {
  RESULT_NAMES+=("$1")
  RESULT_STATUS+=("$2")
  RESULT_DETAIL+=("$3")
}

print_table() {
  {
    echo
    echo "==================== issue #46 実測結果 ===================="
    echo "ドライバ: Athena JDBC $DRIVER_VERSION（$DRIVER_URL）"
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
  if "${COMPOSE[@]}" ps -q tls-proxy >/dev/null 2>&1; then
    "${COMPOSE[@]}" logs --no-color tls-proxy >"$OUT_ROOT/tls-proxy.log" 2>&1 || true
  fi
  if [ "${KEEP_UP:-0}" = "1" ]; then
    log "KEEP_UP=1 のため docker compose はそのまま残す（後で tools/dev.sh docker compose -f $REPO_ROOT/compose.yml down -v ${SERVICES[*]}）"
  else
    log "docker compose down -v ${SERVICES[*]}"
    "${COMPOSE[@]}" down -v "${SERVICES[@]}" >/dev/null 2>&1
  fi
  print_table
  exit "$status"
}

mkdir -p "$OUT_ROOT"
trap cleanup EXIT

# --- Trino への直接アクセス（スキーマ作成だけ。測定対象の文は JDBC 経由で投げる） ---

trino_exec() {
  local sql="$1" catalog="$2" schema="$3"
  local resp next
  resp=$(curl -sf -X POST "$TRINO_BASE/v1/statement" \
    -H "X-Trino-User: issue46-setup" \
    -H "X-Trino-Catalog: $catalog" \
    -H "X-Trino-Schema: $schema" \
    -H "X-Trino-Client-Capabilities: PARAMETRIC_DATETIME" \
    --data-binary "$sql") || return 1
  while true; do
    if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
      log "trino_exec 失敗: $sql"
      echo "$resp" | jq '.error' >&2
      return 1
    fi
    next=$(echo "$resp" | jq -r '.nextUri // empty')
    [ -z "$next" ] && break
    resp=$(curl -sf "$next") || return 1
  done
  return 0
}

wait_for_trino() {
  log "Trino の起動待ち ($TRINO_BASE)"
  local i
  for i in $(seq 1 60); do
    if trino_exec "SELECT 1" system runtime >/dev/null 2>&1; then
      log "Trino 起動確認（${i} 回目）"
      return 0
    fi
    sleep 2
  done
  return 1
}

# alias local は本体の compose 起動の直後に 1 回設定する（#129。toolbox の mc で minio:9000 を直接見る）。
mc_run() {
  bash -c "$1"
}

wait_for_bucket() {
  log "MinIO バケットの用意待ち"
  local i
  for i in $(seq 1 60); do
    if mc_run "mc ls 'local/$BUCKET' >/dev/null" >/dev/null 2>&1; then
      log "バケット確認: $BUCKET（${i} 回目）"
      return 0
    fi
    sleep 2
  done
  return 1
}

# --- 前提の確認（存在ではなく実際に使えるかで判定する） ---

preflight() {
  local missing=()
  docker info >/dev/null 2>&1 || missing+=("docker（デーモンに繋がらない）")
  docker compose version >/dev/null 2>&1 || missing+=("docker compose")
  curl --version >/dev/null 2>&1 || missing+=("curl")
  jq --version >/dev/null 2>&1 || missing+=("jq")
  openssl version >/dev/null 2>&1 || missing+=("openssl")
  if [ "${SKIP_BUILD:-0}" != "1" ]; then
    cargo --version >/dev/null 2>&1 || missing+=("cargo")
  fi
  if [ ${#missing[@]} -gt 0 ]; then
    record "preflight" FAIL "使えないもの: ${missing[*]}"
    return 1
  fi
  record "preflight" PASS "docker・compose・curl・jq・openssl（と cargo）を実際に実行して確認した"
  return 0
}

prepare_cert() {
  if [ ! -f "$TLS_DIR/server.key" ] || [ ! -f "$TLS_DIR/server.crt" ]; then
    log "自己署名証明書を作る"
    bash "$TLS_DIR/make-cert.sh" >>"$OUT_ROOT/make-cert.log" 2>&1 || return 1
  fi
  # nginx がコンテナ内の非 root ユーザで読むため、鍵は 600 のままだと読めないことがある。
  chmod 644 "$TLS_DIR/server.crt" 2>/dev/null || true
  record "TLS 証明書" PASS "server.crt / server.key を用意した（git は追跡しない）"
  return 0
}

prepare_driver() {
  mkdir -p "$DRIVER_CACHE_DIR"
  if [ ! -s "$DRIVER_CACHE" ]; then
    log "Athena JDBC $DRIVER_VERSION を取得する（約 44MB）"
    if ! curl -fsSL -o "$DRIVER_CACHE.part" "$DRIVER_URL"; then
      rm -f "$DRIVER_CACHE.part"
      record "ドライバ取得" FAIL "$DRIVER_URL から取得できなかった"
      return 1
    fi
    mv "$DRIVER_CACHE.part" "$DRIVER_CACHE"
  else
    log "キャッシュ済みのドライバを使う: $DRIVER_CACHE"
  fi

  # java.sql.Driver として登録されているかを中身で確かめる（名前が似た別物を掴んでいないか）。
  local svc
  svc=$(python3 - "$DRIVER_CACHE" <<'PY' 2>/dev/null
import sys, zipfile
try:
    z = zipfile.ZipFile(sys.argv[1])
    print(z.read('META-INF/services/java.sql.Driver').decode().strip())
except Exception:
    pass
PY
)
  if [ -z "$svc" ]; then
    record "ドライバ取得" FAIL "META-INF/services/java.sql.Driver が無い（別物を掴んでいる）"
    return 1
  fi

  record "ドライバ取得" PASS "$(stat -c %s "$DRIVER_CACHE") バイト、java.sql.Driver = $svc"
  return 0
}

build_athena_local() {
  if [ "${SKIP_BUILD:-0}" = "1" ]; then
    [ -x "$BINARY" ] || { record "cargo build" FAIL "SKIP_BUILD=1 だが $BINARY が無い"; return 1; }
    record "cargo build" SKIP "SKIP_BUILD=1。既存の $BINARY を使う"
    return 0
  fi
  log "cargo build --release --locked"
  if (cd "$REPO_ROOT" && cargo build --release --locked) >"$BUILD_LOG" 2>&1; then
    record "cargo build" PASS "$BINARY を用意した"
    return 0
  fi
  record "cargo build" FAIL "ビルド失敗。ログ: $BUILD_LOG"
  tail -n 30 "$BUILD_LOG" >&2
  return 1
}

start_athena_local() {
  log "athena-local を起動する（ログ: $ATHENA_LOG）"
  (
    cd "$REPO_ROOT"
    # 0.0.0.0 で待つ。tls-proxy コンテナが dev:8087 で届く必要があるため
    # （127.0.0.1 バインドだとコンテナから繋がらない）。
    exec env \
      ATHENA_LOCAL_BIND="0.0.0.0:8087" \
      TRINO_URL="$TRINO_BASE" \
      TRINO_USER="athena-local-issue46" \
      TRINO_CATALOG="iceberg" \
      TRINO_SCHEMA="default" \
      ATHENA_LOCAL_RESULTS="s3" \
      AWS_ENDPOINT_URL_S3="http://minio:9000" \
      AWS_ACCESS_KEY_ID="minioadmin" \
      AWS_SECRET_ACCESS_KEY="minioadmin" \
      ATHENA_LOCAL_OUTPUT_LOCATION="$OUTPUT_LOCATION" \
      "$BINARY"
  ) >"$ATHENA_LOG" 2>&1 &
  ATHENA_PID=$!

  local i status
  for i in $(seq 1 30); do
    if ! kill -0 "$ATHENA_PID" 2>/dev/null; then
      record "athena-local 起動" FAIL "異常終了した。ログ: $ATHENA_LOG"
      return 1
    fi
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ATHENA_BASE/" \
      -H "X-Amz-Target: AmazonAthena.ListWorkGroups" \
      -H "Content-Type: application/x-amz-json-1.1" --data '{}')
    if [ "$status" = "200" ]; then
      record "athena-local 起動" PASS "ListWorkGroups が 200（0.0.0.0:8087）"
      return 0
    fi
    sleep 1
  done
  record "athena-local 起動" FAIL "応答しなかった"
  return 1
}

build_jdbc_client() {
  log "JDBC クライアントをビルドする（maven コンテナ）"
  # 以前 pom.xml が誤って引いていた Federated Query コネクタ（com.amazonaws:athena-jdbc）が
  # target/dependency に残っていると classpath に混ざるので、コンテナ内（root）で消す。
  if "${COMPOSE[@]}" run --rm --entrypoint sh jdbc-client \
      -c "rm -f target/dependency/athena-jdbc-20*.jar && mvn -q -B package" >"$MVN_LOG" 2>&1; then
    record "JDBC クライアント build" PASS "target/classes と target/dependency を用意した"
    return 0
  fi
  record "JDBC クライアント build" FAIL "mvn package が失敗した。ログ: $MVN_LOG"
  tail -n 30 "$MVN_LOG" >&2
  return 1
}

# $1 = ラベル, $2 = Main に渡す ResultFetcher（空なら未指定 = 既定の auto）
run_jdbc_case() {
  local label="$1" fetcher="$2"
  local out="$OUT_ROOT/jdbc-$label.log"
  log "JDBC 実行: $label（ResultFetcher=${fetcher:-未指定=既定}）"

  # ドライバが内部で使う AWS SDK の非同期 DNS は、docker の埋め込みリゾルバ
  # （/etc/resolv.conf の `search .` と `ndots:0`）を扱えず UnknownHostException になる。
  # getent と java.net.InetAddress はどちらも解決できるので、名前ではなく /etc/hosts に
  # 固定して渡す（2026-09-21 実測）。
  local proxy_ip
  proxy_ip=$(docker inspect "$("${COMPOSE[@]}" ps -q tls-proxy)" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
  if [ -z "$proxy_ip" ]; then
    record "JDBC $label" FAIL "tls-proxy の IP を取得できなかった"
    return 0
  fi

  "${COMPOSE[@]}" run --rm \
    -v "$DRIVER_CACHE:$DRIVER_MOUNT:ro" --entrypoint sh jdbc-client -c "
    echo '$proxy_ip tls-proxy athena-results.tls-proxy' >> /etc/hosts
    keytool -importcert -noprompt -alias athena-local -file /tls/server.crt -cacerts -storepass changeit >/dev/null 2>&1
    java -cp 'target/classes:target/dependency/*:$DRIVER_MOUNT' local.athenajdbccheck.Main '$fetcher' 2>&1
  " >"$out" 2>&1
  local rc=$?
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

# ドライバが本当に S3 から .metadata を読んだかを nginx のアクセスログで確かめる。
# （auto が GetQueryResults を選んでいたら、焦点の経路を通っていないことになる）
check_s3_access() {
  local nlog="$OUT_ROOT/tls-proxy-live.log"
  "${COMPOSE[@]}" logs --no-color tls-proxy >"$nlog" 2>&1
  local meta_gets
  meta_gets=$(grep -c 'GET [^"]*\.metadata' "$nlog" 2>/dev/null)
  meta_gets=${meta_gets:-0}
  if [ "$meta_gets" -gt 0 ]; then
    record "S3 直読みの裏取り" PASS ".metadata への GET が $meta_gets 件（ドライバが S3 から読んだ）"
  else
    record "S3 直読みの裏取り" FAIL ".metadata への GET が 0 件（S3 経路を通っていない可能性。ログ: $nlog）"
  fi
  return 0
}

# ---------------- 本体 ----------------

log "証跡: $OUT_ROOT"
preflight || exit 1
prepare_cert || exit 1
prepare_driver || exit 1
build_athena_local || exit 1

# 前の走行の残骸（テーブル、結果ファイル、nginx のログ）を持ち越さないよう、使うサービスを作り直す。
# tls-proxy は起動時に dev を名前解決するので、今の dev がいる状態で毎回作り直す。
log "docker compose down -v / up -d ${SERVICES[*]}"
if ! "${COMPOSE[@]}" down -v "${SERVICES[@]}" >"$OUT_ROOT/compose-down.log" 2>&1; then
  record "compose 起動" FAIL "docker compose down -v が失敗した（ログ: $OUT_ROOT/compose-down.log）"
  exit 1
fi
if ! "${COMPOSE[@]}" up -d "${SERVICES[@]}" >"$OUT_ROOT/compose-up.log" 2>&1; then
  record "compose 起動" FAIL "docker compose up -d が失敗した（ログ: $OUT_ROOT/compose-up.log）"
  exit 1
fi
if ! mc alias set local http://minio:9000 minioadmin minioadmin >/dev/null; then
  record "compose 起動" FAIL "mc alias set が失敗した（minio:9000 に繋がらない）"
  exit 1
fi
record "compose 起動" PASS "trino・minio・tls-proxy"

wait_for_trino || { record "Trino 起動" FAIL "起動しなかった"; exit 1; }
record "Trino 起動" PASS "SELECT 1 が通った"

wait_for_bucket || { record "バケット用意" FAIL "できなかった"; exit 1; }
record "バケット用意" PASS "$BUCKET"

trino_exec "CREATE SCHEMA IF NOT EXISTS hive.default" hive default >/dev/null 2>&1
trino_exec "CREATE SCHEMA IF NOT EXISTS iceberg.default" iceberg default >/dev/null 2>&1
record "スキーマ用意" PASS "hive.default と iceberg.default"

start_athena_local || exit 1
build_jdbc_client || exit 1

# 焦点: 既定（auto）。対照: S3 を明示（auto が S3 を選ばなかった場合でも同じ経路を通す）。
run_jdbc_case "auto" ""
run_jdbc_case "S3" "S3"

collect_metadata
check_s3_access

log "完了"
