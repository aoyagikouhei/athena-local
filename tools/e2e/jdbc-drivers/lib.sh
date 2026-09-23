# shellcheck shell=bash
# jdbc 系 3 本（tools/e2e/jdbc-drivers/verify.sh、tools/measure/jdbc-metadata.sh、tools/measure/jdbc-show-metadata.sh）
# が共有する環境関数（compose・証明書・ドライバ・athena-local・JVM の実行）。環境はルートの compose.yml の
# trino / minio / minio-init / tls-proxy と jdbc-client。呼び出し元は record と OUT_ROOT を用意し、source の前に
# PREFIX_ROOT・TRINO_SETUP_USER・ATHENA_TRINO_USER を代入すれば変えられる（既定はそれぞれ e2e-jdbc111・issue111-setup・athena-local-issue111）。

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../../.." && pwd)"
# cargo の成果物の置き場。tools/dev.sh は CARGO_TARGET_DIR を .toolbox/target にする
BINARY="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/athena-local"
TLS_DIR="$REPO_ROOT/tools/compose/tls"
COMPOSE_FILE="$REPO_ROOT/compose.yml"
# 開始時に down -v → up -d で作り直し、後始末で落とすサービス（jdbc-client は run の使い捨てなので入れない）。
SERVICES=(trino minio minio-init tls-proxy)

TRINO_BASE="http://trino:8080"
ATHENA_BASE="http://127.0.0.1:8087"
BUCKET="athena-results"
PREFIX_ROOT="${PREFIX_ROOT:-e2e-jdbc111}"
TRINO_SETUP_USER="${TRINO_SETUP_USER:-issue111-setup}"
ATHENA_TRINO_USER="${ATHENA_TRINO_USER:-athena-local-issue111}"

DRIVER_CACHE_DIR="$HOME/.cache/athena-local-jdbc"
DRIVER_MOUNT="/driver/athena-jdbc.jar"

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

# 前提の確認（存在ではなく実際に使えるかで判定する）と、同じプロジェクトで別の足場が動いていないか。
preflight_tools() {
  local missing=() p project others
  docker info >/dev/null 2>&1 || missing+=("docker（デーモンに繋がらない）")
  docker compose version >/dev/null 2>&1 || missing+=("docker compose")
  for p in curl jq openssl python3 timeout; do
    command -v "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    record "preflight" FAIL "使えないもの: ${missing[*]}"
    return 1
  fi
  # 開始時の down -v が相手の環境を消すので、同じプロジェクトに自分以外の dev がいたら止まる
  # （hostname は自分のコンテナ ID の先頭 12 桁）。
  project=$(dc config --format json 2>/dev/null | jq -r '.name // empty')
  if [ -z "$project" ]; then
    record "preflight" FAIL "compose のプロジェクト名を取れない（docker compose config が失敗した）"
    return 1
  fi
  others=$(docker ps -q --filter "label=com.docker.compose.project=$project" --filter label=com.docker.compose.service=dev | grep -v "^$(hostname)" | wc -l)
  if [ "$others" != "0" ]; then
    record "preflight" FAIL "同じプロジェクト（$project）で別の足場が動いている。COMPOSE_PROJECT_NAME で分けるか、終わるのを待つ"
    return 1
  fi
  record "preflight" PASS "docker・compose・curl・jq・openssl・python3・timeout。同じプロジェクト（$project）に別の dev は無い"
}

prepare_cert() {
  if [ ! -f "$TLS_DIR/server.key" ] || [ ! -f "$TLS_DIR/server.crt" ]; then
    log "自己署名証明書を作る"
    bash "$TLS_DIR/make-cert.sh" >>"$OUT_ROOT/make-cert.log" 2>&1 || { record "TLS 証明書" FAIL "make-cert.sh が失敗"; return 1; }
  fi
  chmod 644 "$TLS_DIR/server.crt" 2>/dev/null || true
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
  tail -n 30 "$OUT_ROOT/cargo-build.log" >&2
  return 1
}

trino_exec() {
  local resp next
  resp=$(curl -sf -X POST "$TRINO_BASE/v1/statement" -H "X-Trino-User: $TRINO_SETUP_USER" \
    -H "X-Trino-Catalog: $2" -H "X-Trino-Schema: $3" \
    -H "X-Trino-Client-Capabilities: PARAMETRIC_DATETIME" --data-binary "$1") || return 1
  while true; do
    if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
      log "trino_exec 失敗: $1"
      echo "$resp" | jq '.error' >&2
      return 1
    fi
    next=$(echo "$resp" | jq -r '.nextUri // empty')
    [ -z "$next" ] && return 0
    resp=$(curl -sf "$next") || return 1
  done
}

# $1 = mc の呼び出しを含む文字列（judge.sh:117 の `mc_run "mc ls --recursive '...'"` のように渡す）。
# alias local は compose_up が 1 回だけ設定する（#129。toolbox の mc で minio:9000 を直接見る）。
mc_run() {
  bash -c "$1"
}

# サービスを指定して作り直す（jdbc-client は常駐させない）。Trino・バケット・スキーマまで用意する。
# tls-proxy も毎回作り直す（nginx は起動時に dev を名前解決する。judge はログの全履歴を数える）。
compose_up() {
  log "docker compose down -v / up -d ${SERVICES[*]}"
  dc down -v "${SERVICES[@]}" >"$OUT_ROOT/compose-down.log" 2>&1 \
    || { record "compose 起動" FAIL "down -v が失敗（ログ: $OUT_ROOT/compose-down.log）"; return 1; }
  dc up -d "${SERVICES[@]}" >"$OUT_ROOT/compose-up.log" 2>&1 \
    || { record "compose 起動" FAIL "up が失敗（ログ: $OUT_ROOT/compose-up.log）"; return 1; }
  mc alias set local http://minio:9000 minioadmin minioadmin >/dev/null \
    || { record "compose 起動" FAIL "mc alias set が失敗した（minio:9000 に繋がらない）"; return 1; }
  retry 60 trino_exec "SELECT 1" system runtime || { record "Trino 起動" FAIL "起動しなかった"; return 1; }
  retry 60 mc_run "mc ls 'local/$BUCKET' >/dev/null" || { record "バケット用意" FAIL "できなかった"; return 1; }
  trino_exec "CREATE SCHEMA IF NOT EXISTS hive.default" hive default
  trino_exec "CREATE SCHEMA IF NOT EXISTS iceberg.default" iceberg default
  record "compose 起動" PASS "trino・minio・tls-proxy・バケット・スキーマ"
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
      TRINO_USER="$ATHENA_TRINO_USER" TRINO_CATALOG="iceberg" TRINO_SCHEMA="default" \
      ATHENA_LOCAL_RESULTS="s3" AWS_ENDPOINT_URL_S3="http://minio:9000" \
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
  tail -n 30 "$OUT_ROOT/mvn.log" >&2
  return 1
}

# $1 = 版, $2 = ResultFetcher（空なら未指定）, $3 = シナリオ, $4 = OutputLocation, $5 = URL, $6 = 出力ファイル
# JDBC の実行は jdbc-show-metadata.sh と同じ形（/etc/hosts に tls-proxy を固定、keytool で証明書を取り込む）。
# 値は位置引数で渡す（-e は使わない）。1 回を timeout で包み、終了コードを返す（124 はハング、97 は tls-proxy の
# IP が取れず JVM を起動しなかった。どちらも record は呼ばない＝判定は呼び出し元に任せる）。
run_jvm() {
  local proxy_ip rc project
  proxy_ip=$(docker inspect "$(dc ps -q tls-proxy)" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
  if [ -z "$proxy_ip" ]; then
    log "tls-proxy の IP を取得できない。JVM を起動しない"
    return 97
  fi
  timeout "${JVM_TIMEOUT:-300}" docker compose -f "$COMPOSE_FILE" run --rm -T \
    -v "$(driver_path "$1"):$DRIVER_MOUNT:ro" --entrypoint sh jdbc-client -c "
    echo '$proxy_ip tls-proxy athena-results.tls-proxy' >> /etc/hosts
    keytool -importcert -noprompt -alias athena-local -file /tls/server.crt -cacerts -storepass changeit >/dev/null 2>&1
    java -cp 'target/classes:target/dependency/*:$DRIVER_MOUNT' local.athenajdbccheck.Main '$2' '$3' '$4' '$5' 2>&1
  " </dev/null >"$6" 2>&1
  rc=$?
  if [ "$rc" = "124" ]; then
    # timeout が止めたのは compose の CLI だけのことがあるので、自分のプロジェクトの jdbc-client の使い捨てコンテナだけを消す
    # （dev も run の使い捨てなので、service で絞らないと自分自身を消す）。
    project=$(dc config --format json 2>/dev/null | jq -r '.name // empty')
    [ -n "$project" ] && docker ps -aq --filter "label=com.docker.compose.project=$project" \
      --filter "label=com.docker.compose.service=jdbc-client" \
      --filter "label=com.docker.compose.oneoff=True" | xargs -r docker rm -f >/dev/null 2>&1
  fi
  return "$rc"
}
