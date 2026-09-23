# shellcheck shell=bash
# issue #116: verify.sh から抜き出したヘルパ（結果表・Trino への直接アクセス・athena-local の起動と API 呼び出し・
# MinIO 側の検証・.metadata の先頭の読み取り）。単独では実行しない。verify.sh が `source` し、ケース 10〜12・14 の
# cases-dml-retention.sh もここの関数を使う。呼び出し時に verify.sh の変数（REPO_ROOT・BINARY・TRINO_BASE・
# MINIO_ENDPOINT・ATHENA_BASE・BUCKET・OUTPUT_LOCATION・EVIDENCE_DIR・ATHENA_LOG・BUILD_LOG）を読み、
# start_athena_local は ATHENA_PID に書く。

declare -a RESULT_NAMES=()
declare -a RESULT_STATUS=()
declare -a RESULT_DETAIL=()

log() { echo "[verify] $*" >&2; }

record() {
  RESULT_NAMES+=("$1")
  RESULT_STATUS+=("$2")
  RESULT_DETAIL+=("$3")
}

print_table() {
  echo
  echo "==================== 結果 ===================="
  local i
  for i in "${!RESULT_NAMES[@]}"; do
    printf "%-2s %-8s %-46s %s\n" "$((i + 1))" "${RESULT_STATUS[$i]}" "${RESULT_NAMES[$i]}" "${RESULT_DETAIL[$i]}"
  done
  echo "================================================"
}

# --- Trino への直接アクセス（セットアップ専用。測定対象の文は athena-local 経由で投げる） ---

trino_exec() {
  local sql="$1" catalog="$2" schema="$3"
  local resp next
  resp=$(curl -sf -X POST "$TRINO_BASE/v1/statement" \
    -H "X-Trino-User: e2e-setup" \
    -H "X-Trino-Catalog: $catalog" \
    -H "X-Trino-Schema: $schema" \
    -H "X-Trino-Client-Capabilities: PARAMETRIC_DATETIME" \
    --data-binary "$sql")
  while true; do
    if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
      log "trino_exec 失敗: $sql"
      echo "$resp" | jq '.error' >&2
      return 1
    fi
    next=$(echo "$resp" | jq -r '.nextUri // empty')
    if [ -z "$next" ]; then
      break
    fi
    resp=$(curl -sf "$next")
  done
  return 0
}

wait_for_trino() {
  log "Trino の起動待ち ($TRINO_BASE)"
  for _ in $(seq 1 60); do
    if trino_exec "SELECT 1" system runtime >/dev/null 2>&1; then
      log "Trino 起動確認"
      return 0
    fi
    sleep 2
  done
  log "Trino が起動しなかった"
  return 1
}

wait_for_bucket() {
  log "MinIO バケットの用意待ち"
  for _ in $(seq 1 60); do
    if mc ls "local/$BUCKET" >/dev/null 2>&1; then
      log "バケット確認: $BUCKET"
      return 0
    fi
    sleep 2
  done
  log "バケットの用意ができなかった"
  return 1
}

# --- athena-local 起動 ---

build_athena_local() {
  if [ "${SKIP_BUILD:-0}" = "1" ]; then
    log "SKIP_BUILD=1 のため cargo build を省略する"
    [ -x "$BINARY" ] && return 0
    log "$BINARY が無い"
    return 1
  fi

  log "cargo build --release --locked を実行する（他エージェントの target ロックで待たされることがある）"
  if (cd "$REPO_ROOT" && cargo build --release --locked) >"$BUILD_LOG" 2>&1; then
    log "ビルド成功"
    return 0
  fi

  log "ビルド失敗。ログ: $BUILD_LOG（末尾 40 行）"
  tail -n 40 "$BUILD_LOG" >&2
  return 1
}

# 引数 1: ATHENA_LOCAL_RETENTION_SECONDS（省略時は既定と同じ 3600）。引数 2: ログの置き場所（省略時は $ATHENA_LOG）。
start_athena_local() {
  local retention="${1:-3600}" athena_log="${2:-$ATHENA_LOG}"
  log "athena-local を起動する（保持期限 ${retention} 秒、ログ: $athena_log）"
  (
    cd "$REPO_ROOT"
    exec env \
      ATHENA_LOCAL_BIND="127.0.0.1:8087" \
      TRINO_URL="$TRINO_BASE" \
      TRINO_USER="athena-local-e2e" \
      TRINO_CATALOG="iceberg" \
      TRINO_SCHEMA="default" \
      ATHENA_LOCAL_RESULTS="s3" \
      AWS_ENDPOINT_URL_S3="$MINIO_ENDPOINT" \
      AWS_ACCESS_KEY_ID="minioadmin" \
      AWS_SECRET_ACCESS_KEY="minioadmin" \
      ATHENA_LOCAL_OUTPUT_LOCATION="$OUTPUT_LOCATION" \
      ATHENA_LOCAL_RETENTION_SECONDS="$retention" \
      "$BINARY"
  ) >"$athena_log" 2>&1 &
  ATHENA_PID=$!

  log "athena-local ($ATHENA_BASE) の起動待ち"
  for _ in $(seq 1 30); do
    if ! kill -0 "$ATHENA_PID" 2>/dev/null; then
      log "athena-local が異常終了した。ログ:"
      cat "$athena_log" >&2
      return 1
    fi
    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ATHENA_BASE/" \
      -H "X-Amz-Target: AmazonAthena.ListWorkGroups" \
      -H "Content-Type: application/x-amz-json-1.1" \
      --data '{}')
    if [ "$status" = "200" ]; then
      log "athena-local 起動確認"
      return 0
    fi
    sleep 1
  done
  log "athena-local が応答しなかった"
  return 1
}

# --- athena-local の Athena API 呼び出し ---

athena_call() {
  local operation="$1" body="$2"
  curl -s -X POST "$ATHENA_BASE/" \
    -H "X-Amz-Target: AmazonAthena.$operation" \
    -H "Content-Type: application/x-amz-json-1.1" \
    --data "$body"
}

athena_start_query() {
  local sql="$1" catalog="$2" database="$3"
  local token body resp
  token="$(uuidgen)"
  body=$(jq -n --arg sql "$sql" --arg catalog "$catalog" --arg db "$database" --arg token "$token" \
    '{QueryString: $sql, QueryExecutionContext: {Catalog: $catalog, Database: $db}, ClientRequestToken: $token}')
  resp=$(athena_call StartQueryExecution "$body")
  echo "$resp" | jq -r '.QueryExecutionId // empty'
}

# StartQueryExecution の生の応答をそのまま返す（QueryExecutionId の有無を呼び出し元が判定する）。
# 構文確認の探り（例: Athena の綴りが Trino の構文エラーで弾かれること）に使う。
athena_start_query_raw() {
  local sql="$1" catalog="$2" database="$3"
  local token body
  token="$(uuidgen)"
  body=$(jq -n --arg sql "$sql" --arg catalog "$catalog" --arg db "$database" --arg token "$token" \
    '{QueryString: $sql, QueryExecutionContext: {Catalog: $catalog, Database: $db}, ClientRequestToken: $token}')
  athena_call StartQueryExecution "$body"
}

athena_wait() {
  local id="$1" resp state
  for _ in $(seq 1 100); do
    resp=$(athena_call GetQueryExecution "$(jq -n --arg id "$id" '{QueryExecutionId: $id}')")
    state=$(echo "$resp" | jq -r '.QueryExecution.Status.State // empty')
    if [ "$state" != "QUEUED" ] && [ "$state" != "RUNNING" ]; then
      echo "$resp"
      return 0
    fi
    sleep 0.3
  done
  echo "$resp"
  return 1
}

# --- S3（MinIO）側の検証（toolbox の mc で minio:9000 を直接見る。#129） ---

# `mc stat --json <key>` を実行して、その key ちょうど一致するオブジェクトの JSON を 1 行返す。
# 無ければ {"status":"error"} を返す。
#
# 注意（2026-09-21 実測）: mc stat は与えたキーを前方一致のプレフィックスとしても扱い、
# `<id>.txt` を指定すると `<id>.txt.metadata`（`.txt` を前方一致で含む）まで一緒に
# ヒットして JSON が複数行返る。`jq -r '.size'` はストリームとして両方読んでしまい
# 値が縦に並ぶ（例: "1\n41"）ので、`name` フィールドで厳密に絞り込む。
mc_stat() {
  local key="$1" name
  name=$(basename "$key")
  local raw
  raw=$(mc stat --json "local/$BUCKET/$key" 2>/dev/null)
  if [ -z "$raw" ]; then
    echo '{"status":"error"}'
    return
  fi
  echo "$raw" | jq -s --arg name "$name" '
    map(select(.name == $name and (.status // "success") == "success"))
    | if length > 0 then .[0] else {"status":"error"} end
  '
}

mc_exists() {
  local stat_json="$1"
  [ -n "$stat_json" ] && ! echo "$stat_json" | jq -e '.status == "error"' >/dev/null 2>&1
}

# オブジェクトの中身をバイト単位そのまま $out に落とす。
mc_get() {
  local key="$1" out="$2"
  mc cat "local/$BUCKET/$key" >"$out" 2>/dev/null
}

# 本体（.txt / .csv）を検証する。期待するバイト数・Content-Type・「改行 1 つか」を確かめる。
# 戻り値: 0 = 期待どおり、1 = 不一致（詳細は標準出力に書く）
check_body() {
  local key="$1" expect_size="$2" expect_ct="$3" expect_newline_only="$4"
  local out="$EVIDENCE_DIR/$(basename "$key")"
  local stat_json size ct hex ok=1 detail=""

  stat_json=$(mc_stat "$key")
  if ! mc_exists "$stat_json"; then
    echo "本体が無い（期待: ${expect_size}B）"
    return 1
  fi
  size=$(echo "$stat_json" | jq -r '.size')
  ct=$(echo "$stat_json" | jq -r '.metadata["Content-Type"] // empty')

  mc_get "$key" "$out"
  od -An -tx1c "$out" >"$out.od.txt" 2>/dev/null || true
  hex=$(od -An -tx1 "$out" | tr -d ' \n')

  [ "$size" = "$expect_size" ] || { ok=0; detail="$detail size=$size(期待 $expect_size)"; }
  [ "$ct" = "$expect_ct" ] || { ok=0; detail="$detail content-type=$ct(期待 $expect_ct)"; }
  if [ "$expect_newline_only" = "1" ]; then
    [ "$hex" = "0a" ] || { ok=0; detail="$detail hex=$hex(期待 0a=改行1つ)"; }
  fi

  if [ "$ok" = "1" ]; then
    echo "size=${size}B content-type=${ct} hex=${hex} (od: $out.od.txt)"
    return 0
  else
    echo "不一致:${detail} (od: $out.od.txt)"
    return 1
  fi
}

# .metadata の有無を検証する。expect_present=1 なら存在してバイト数が一致すること、
# expect_present=0 なら存在しないこと。
check_metadata() {
  local key="$1" expect_present="$2" expect_size="${3:-}"
  local out="$EVIDENCE_DIR/$(basename "$key")"
  local stat_json size

  stat_json=$(mc_stat "$key")
  if ! mc_exists "$stat_json"; then
    if [ "$expect_present" = "0" ]; then
      echo ".metadata 無し（期待どおり）"
      return 0
    else
      echo ".metadata が無い（期待 ${expect_size}B）"
      return 1
    fi
  fi

  if [ "$expect_present" = "0" ]; then
    echo ".metadata がある（期待は無し）"
    return 1
  fi

  size=$(echo "$stat_json" | jq -r '.size')
  mc_get "$key" "$out"
  od -An -tx1c "$out" >"$out.od.txt" 2>/dev/null || true

  if [ "$size" = "$expect_size" ]; then
    echo ".metadata size=${size}B (od: $out.od.txt)"
    return 0
  else
    echo ".metadata size=$size (期待 $expect_size) (od: $out.od.txt)"
    return 1
  fi
}

# .metadata の先頭 2 フィールド（1 クエリ ID、2 updateType。どちらも長さ前置の文字列）と
# 続く field 3（更新件数。varint）を読む。長さと件数は 1 バイト（< 128）の前提。
# 標準出力に「<updateType>\t<更新件数>\t<field 3 より後ろの hex>」を書く。形が違えば 1 を返す。
read_metadata_head() {
  local file="$1"
  local hex len off type_hex count rest
  hex=$(od -An -tx1 "$file" | tr -d ' \n')
  [ "${hex:0:2}" = "0a" ] || { echo "field 1 のタグが 0a でない: ${hex:0:2}"; return 1; }
  len=$((16#${hex:2:2}))
  off=$((4 + len * 2))
  [ "${hex:$off:2}" = "12" ] || { echo "field 2 のタグが 12 でない: ${hex:$off:2}"; return 1; }
  len=$((16#${hex:$((off + 2)):2}))
  type_hex="${hex:$((off + 4)):$((len * 2))}"
  off=$((off + 4 + len * 2))
  [ "${hex:$off:2}" = "18" ] || { echo "field 3 のタグが 18 でない: ${hex:$off:2}"; return 1; }
  count=$((16#${hex:$((off + 2)):2}))
  rest="${hex:$((off + 4))}"
  printf '%s\t%s\t%s\n' "$(printf "$(echo "$type_hex" | sed 's/../\\x&/g')")" "$count" "$rest"
}
