# shellcheck shell=bash
# issue #111: jdbc-drivers/verify.sh の環境まわりの関数（compose・証明書・ドライバ・athena-local・JVM の実行）。
# 足場は tools/e2e/minio/ をそのまま使う。関数の多くは tools/measure/jdbc-show-metadata.sh の複製
# （共通化は #111 の範囲外）。違いは版を引数に取ることと、JVM を timeout で包むこと。verify.sh から source する。

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../../.." && pwd)"
# cargo の成果物の置き場。tools/dev.sh は CARGO_TARGET_DIR を .toolbox/target にする
BINARY="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/athena-local"
E2E_DIR="$REPO_ROOT/tools/e2e/minio"
COMPOSE_FILE="$E2E_DIR/docker-compose.yml"
COMPOSE_PROJECT="athena-local-issue39-e2e"

TRINO_BASE="http://127.0.0.1:8092"
ATHENA_BASE="http://127.0.0.1:8087"
BUCKET="athena-results"
PREFIX_ROOT="e2e-jdbc111"
USED_PORTS="8087 8092 9002 9003 8443 9443"

DRIVER_CACHE_DIR="$HOME/.cache/athena-local-jdbc"
DRIVER_MOUNT="/driver/athena-jdbc.jar"
MC_IMAGE="quay.io/minio/mc:latest"
MC_NETWORK="${COMPOSE_PROJECT}_default"
MC_ALIAS_CMD='mc alias set local http://minio:9000 minioadmin minioadmin >/dev/null 2>&1'

ATHENA_PID=""

log() { echo "[jdbc-drivers] $*" >&2; }

dc() { docker compose -f "$COMPOSE_FILE" "$@"; }

# $1 = 回数。残りのコマンドが成功するまで 2 秒おきに繰り返す。
retry() {
  local n="$1" i
  shift
  for i in $(seq 1 "$n"); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

# 前提の確認（存在ではなく実際に使えるかで判定する）と、使うポートが空いているか。
preflight_tools() {
  local missing=() p
  docker info >/dev/null 2>&1 || missing+=("docker（デーモンに繋がらない）")
  docker compose version >/dev/null 2>&1 || missing+=("docker compose")
  for p in curl jq openssl python3 timeout; do
    command -v "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    record "preflight" FAIL "使えないもの: ${missing[*]}"
    return 1
  fi
  for p in $USED_PORTS; do
    if timeout 1 bash -c "exec 3<>/dev/tcp/127.0.0.1/$p" 2>/dev/null; then
      record "preflight" FAIL "ポート $p が使用中（minio の足場が動いていないか確かめる。他のプロジェクトには触らない）"
      return 1
    fi
  done
  record "preflight" PASS "docker・compose・curl・jq・openssl・python3・timeout。ポート $USED_PORTS は空き"
}

prepare_cert() {
  if [ ! -f "$E2E_DIR/tls/server.key" ] || [ ! -f "$E2E_DIR/tls/server.crt" ]; then
    log "自己署名証明書を作る"
    bash "$E2E_DIR/tls/make-cert.sh" >>"$OUT_ROOT/make-cert.log" 2>&1 || { record "TLS 証明書" FAIL "make-cert.sh が失敗"; return 1; }
  fi
  chmod 644 "$E2E_DIR/tls/server.crt" 2>/dev/null || true
}

driver_path() { echo "$DRIVER_CACHE_DIR/athena-jdbc-$1-with-dependencies.jar"; }

# $1 = 版。キャッシュに無ければ取得し、本物のドライバかを中身で確かめる（java.sql.Driver の登録か、
# 3.1.0 以前のように登録が無ければ AthenaDriver のクラス。Main が Class.forName で読み込む）。
# 取れなければ DRIVER_SKIP_REASON に理由を入れて 1 を返す（呼び出し側がその版を SKIP にする）。
prepare_driver() {
  local ver="$1" jar url svc
  jar=$(driver_path "$ver")
  url="https://downloads.athena.us-east-1.amazonaws.com/drivers/JDBC/${ver}/athena-jdbc-${ver}-with-dependencies.jar"
  mkdir -p "$DRIVER_CACHE_DIR"
  if [ ! -s "$jar" ]; then
    log "Athena JDBC $ver を取得する: $url"
    if ! curl -fsSL -o "$jar.part" "$url"; then
      rm -f "$jar.part"
      DRIVER_SKIP_REASON="ドライバを取得できない（$url）"
      return 1
    fi
    mv "$jar.part" "$jar"
  fi
  svc=$(python3 - "$jar" <<'PY' 2>/dev/null
import sys, zipfile
try:
    z = zipfile.ZipFile(sys.argv[1]); names = z.namelist()
    if 'META-INF/services/java.sql.Driver' in names: print(z.read('META-INF/services/java.sql.Driver').decode().strip())
    elif 'com/amazon/athena/jdbc/AthenaDriver.class' in names:
        print('com.amazon.athena.jdbc.AthenaDriver（ServiceLoader の登録なし。3.1.0 以前）')
except Exception:
    pass
PY
)
  if [ -z "$svc" ]; then
    DRIVER_SKIP_REASON="java.sql.Driver の登録も AthenaDriver のクラスも無い（別物: $jar）"
    return 1
  fi
  log "ドライバ $ver: $(stat -c %s "$jar") バイト、java.sql.Driver = $svc"
}

build_athena_local() {
  if [ "${SKIP_BUILD:-0}" = "1" ]; then
    [ -x "$BINARY" ] || { record "cargo build" FAIL "SKIP_BUILD=1 だが $BINARY が無い"; return 1; }
    return 0
  fi
  log "cargo build --release --locked"
  (cd "$REPO_ROOT" && cargo build --release --locked) >"$OUT_ROOT/cargo-build.log" 2>&1 && return 0
  record "cargo build" FAIL "ビルド失敗。ログ: $OUT_ROOT/cargo-build.log"
  return 1
}

trino_exec() {
  local resp next
  resp=$(curl -sf -X POST "$TRINO_BASE/v1/statement" -H "X-Trino-User: issue111-setup" \
    -H "X-Trino-Catalog: $2" -H "X-Trino-Schema: $3" --data-binary "$1") || return 1
  while true; do
    echo "$resp" | jq -e '.error' >/dev/null 2>&1 && return 1
    next=$(echo "$resp" | jq -r '.nextUri // empty')
    [ -z "$next" ] && return 0
    resp=$(curl -sf "$next") || return 1
  done
}

mc_run() {
  docker run --rm --network "$MC_NETWORK" --entrypoint sh "$MC_IMAGE" -c "$MC_ALIAS_CMD && $1"
}

# サービスを指定して立てる（jdbc-client は常駐させない）。Trino・バケット・スキーマまで用意する。
compose_up() {
  local net
  log "docker compose up -d trino minio minio-init tls-proxy"
  dc up -d trino minio minio-init tls-proxy >"$OUT_ROOT/compose-up.log" 2>&1 \
    || { record "compose 起動" FAIL "up が失敗（ログ: $OUT_ROOT/compose-up.log）"; return 1; }
  net=$(docker inspect "${COMPOSE_PROJECT}-minio" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' 2>/dev/null)
  [ -n "$net" ] && MC_NETWORK="$net"
  retry 60 trino_exec "SELECT 1" system runtime || { record "Trino 起動" FAIL "起動しなかった"; return 1; }
  retry 60 mc_run "mc ls 'local/$BUCKET' >/dev/null" || { record "バケット用意" FAIL "できなかった"; return 1; }
  trino_exec "CREATE SCHEMA IF NOT EXISTS hive.default" hive default
  trino_exec "CREATE SCHEMA IF NOT EXISTS iceberg.default" iceberg default
  record "compose 起動" PASS "trino・minio・tls-proxy・バケット・スキーマ（ネットワーク: $MC_NETWORK）"
}

athena_call() {
  curl -s -X POST "$ATHENA_BASE/" -H "X-Amz-Target: AmazonAthena.$1" \
    -H "Content-Type: application/x-amz-json-1.1" --data-binary "$2"
}

# tls-proxy から届くよう 0.0.0.0 で待つ。出力先は JDBC が回ごとに OutputLocation で上書きする。
start_athena_local() {
  local i
  (
    cd "$REPO_ROOT" && exec env ATHENA_LOCAL_BIND="0.0.0.0:8087" TRINO_URL="$TRINO_BASE" \
      TRINO_USER="athena-local-issue111" TRINO_CATALOG="iceberg" TRINO_SCHEMA="default" \
      ATHENA_LOCAL_RESULTS="s3" AWS_ENDPOINT_URL_S3="http://127.0.0.1:9002" \
      AWS_ACCESS_KEY_ID="minioadmin" AWS_SECRET_ACCESS_KEY="minioadmin" \
      ATHENA_LOCAL_OUTPUT_LOCATION="s3://$BUCKET/$PREFIX_ROOT/default/" \
      "$BINARY"
  ) >"$OUT_ROOT/athena-local.log" 2>&1 &
  ATHENA_PID=$!
  for i in $(seq 1 30); do
    kill -0 "$ATHENA_PID" 2>/dev/null || { record "athena-local 起動" FAIL "異常終了。ログ: $OUT_ROOT/athena-local.log"; return 1; }
    [ "$(athena_call ListWorkGroups '{}' 2>/dev/null | jq -r 'has("WorkGroups")' 2>/dev/null)" = "true" ] && return 0
    sleep 1
  done
  record "athena-local 起動" FAIL "応答しなかった"
  return 1
}

# mvn は 1 回だけ（ループの中で down しないので jdbc-client-m2 のボリュームが残る）。
build_jdbc_client() {
  dc run --rm -T --entrypoint sh jdbc-client \
    -c "rm -f target/dependency/athena-jdbc-20*.jar && mvn -q -B package" </dev/null >"$OUT_ROOT/mvn.log" 2>&1 && return 0
  record "JDBC クライアント build" FAIL "mvn package が失敗。ログ: $OUT_ROOT/mvn.log"
  return 1
}

# $1 = 版, $2 = ResultFetcher（空なら未指定）, $3 = シナリオ, $4 = OutputLocation, $5 = URL, $6 = 出力ファイル
# JDBC の実行は jdbc-show-metadata.sh と同じ形（/etc/hosts に tls-proxy を固定、keytool で証明書を取り込む）。
# 値は位置引数で渡す（-e は使わない）。1 回を timeout で包み、終了コードを返す（124 はハング）。
run_jvm() {
  local proxy_ip rc
  proxy_ip=$(docker inspect "${COMPOSE_PROJECT}-tls-proxy" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
  timeout "${JVM_TIMEOUT:-300}" docker compose -f "$COMPOSE_FILE" run --rm -T \
    -v "$(driver_path "$1"):$DRIVER_MOUNT:ro" --entrypoint sh jdbc-client -c "
    echo '$proxy_ip tls-proxy athena-results.tls-proxy' >> /etc/hosts
    keytool -importcert -noprompt -alias athena-local -file /tls/server.crt -cacerts -storepass changeit >/dev/null 2>&1
    java -cp 'target/classes:target/dependency/*:$DRIVER_MOUNT' local.athenajdbccheck.Main '$2' '$3' '$4' '$5' 2>&1
  " </dev/null >"$6" 2>&1
  rc=$?
  if [ "$rc" = "124" ]; then
    # timeout が止めたのは compose の CLI だけのことがあるので、自分のプロジェクトの使い捨てコンテナだけを消す。
    docker ps -aq --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
      --filter "label=com.docker.compose.oneoff=True" | xargs -r docker rm -f >/dev/null 2>&1
  fi
  return "$rc"
}
