#!/usr/bin/env bash
# issue #39 で作成（tools/ へ移す前の名前は 39-e2e/verify.sh）
# issue #39 Step 9（実機検証）: 本物の Trino（trinodb/trino:482）と本物の S3 互換ストレージ
# （MinIO）を相手に athena-local を動かし、DROP TABLE の結果ファイルがテーブルの形式
# （Hive / Iceberg）で変わることを実際に確かめる。
#
# 前提コマンド: docker, docker compose, curl, jq, uuidgen, od, cargo
# S3（MinIO）側の確認は aws cli を使わず、compose と同じネットワークに繋いだ
# minio/mc の使い捨てコンテナで行う（環境によって aws cli が docker ラッパーで、
# ホストにマップしたポートに届かないことがあるため。2026-09-21 実測）。
#
# 使い方:
#   tools/e2e/minio/verify.sh
#
# 環境変数:
#   KEEP_UP=1        テスト後に docker compose down -v をせず環境を残す（デバッグ用）
#   SKIP_BUILD=1     cargo build を省略し、既存の target/release/athena-local をそのまま使う
#
# 後始末は本スクリプトの trap が行う（KEEP_UP=1 でなければ必ず docker compose down -v する）。
# 終了コードは結果表の FAIL の件数（issue #111。SKIP と INFO は数えない。起動の失敗などで途中で止まったときは 1）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"

TRINO_BASE="http://127.0.0.1:8092"
MINIO_ENDPOINT="http://127.0.0.1:9002"
ATHENA_BASE="http://127.0.0.1:8087"
BUCKET="athena-results"
PREFIX="e2e"
OUTPUT_LOCATION="s3://${BUCKET}/${PREFIX}/"
RUN_ID="$(date +%s)"

MC_IMAGE="quay.io/minio/mc:latest"
# docker compose up -d の後、compose のデフォルトネットワークを実際に調べて上書きする
# （docker-compose.yml の `name:` から決まる想定値。念のため動的にも確かめる）。
MC_NETWORK="athena-local-issue39-e2e_default"
MC_ALIAS_CMD='mc alias set local http://minio:9000 minioadmin minioadmin >/dev/null 2>&1'

EVIDENCE_DIR="$(mktemp -d /tmp/athena-local-issue39-e2e.XXXXXX)"
ATHENA_LOG="$EVIDENCE_DIR/athena-local.log"
BUILD_LOG="$EVIDENCE_DIR/cargo-build.log"

ATHENA_PID=""

# issue #111: ケース 10〜12（UPDATE / DELETE）と 14（s3 × 保持期限）
# shellcheck source=tools/e2e/minio/cases-dml-retention.sh
source "$SCRIPT_DIR/cases-dml-retention.sh"

declare -a RESULT_NAMES=()
declare -a RESULT_STATUS=()
declare -a RESULT_DETAIL=()

log() { echo "[verify] $*" >&2; }

record() {
  RESULT_NAMES+=("$1")
  RESULT_STATUS+=("$2")
  RESULT_DETAIL+=("$3")
}

cleanup() {
  local status=$?
  if [ -n "$ATHENA_PID" ] && kill -0 "$ATHENA_PID" 2>/dev/null; then
    log "athena-local (PID $ATHENA_PID) を止める"
    kill "$ATHENA_PID" 2>/dev/null || true
    wait "$ATHENA_PID" 2>/dev/null || true
  fi
  if [ "${KEEP_UP:-0}" = "1" ]; then
    log "KEEP_UP=1 のため docker compose はそのまま残す（後で手動で down -v してください）"
  else
    log "docker compose down -v"
    docker compose -f "$COMPOSE_FILE" down -v >/dev/null 2>&1
  fi
  log "証跡（ログ・取得したファイル）: $EVIDENCE_DIR"
  print_table
  exit "$status"
}
trap cleanup EXIT

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
    if docker run --rm --network "$MC_NETWORK" --entrypoint sh "$MC_IMAGE" \
      -c "$MC_ALIAS_CMD && mc ls 'local/$BUCKET' >/dev/null" >/dev/null 2>&1; then
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
    [ -x "$REPO_ROOT/target/release/athena-local" ] && return 0
    log "target/release/athena-local が無い"
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
      "$REPO_ROOT/target/release/athena-local"
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

# --- S3（MinIO）側の検証（minio/mc の使い捨てコンテナ経由） ---

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
  raw=$(docker run --rm --network "$MC_NETWORK" --entrypoint sh "$MC_IMAGE" \
    -c "$MC_ALIAS_CMD && mc stat --json 'local/$BUCKET/$key'" 2>/dev/null)
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
  docker run --rm --network "$MC_NETWORK" --entrypoint sh "$MC_IMAGE" \
    -c "$MC_ALIAS_CMD && mc cat 'local/$BUCKET/$key'" >"$out" 2>/dev/null
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

# --- ケース ---

run_case() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5" ext="$6"
  local body_expect_size="$7" body_expect_ct="$8" body_expect_newline="$9" meta_expect_present="${10}" meta_expect_size="${11:-}"

  log "ケース $no: $name -- $sql"
  local id resp state body_detail meta_detail body_ok meta_ok

  id=$(athena_start_query "$sql" "$catalog" "$database")
  if [ -z "$id" ]; then
    record "$no $name" FAIL "StartQueryExecution が QueryExecutionId を返さなかった"
    return
  fi

  resp=$(athena_wait "$id")
  state=$(echo "$resp" | jq -r '.QueryExecution.Status.State // empty')
  if [ "$state" != "SUCCEEDED" ]; then
    local reason
    reason=$(echo "$resp" | jq -r '.QueryExecution.Status.StateChangeReason // empty')
    record "$no $name" FAIL "終了状態が SUCCEEDED でない: $state ($reason) [id=$id]"
    return
  fi

  local key="${PREFIX}/${id}.${ext}"
  body_detail=$(check_body "$key" "$body_expect_size" "$body_expect_ct" "$body_expect_newline")
  body_ok=$?
  meta_detail=$(check_metadata "${key}.metadata" "$meta_expect_present" "$meta_expect_size")
  meta_ok=$?

  if [ "$body_ok" = "0" ] && [ "$meta_ok" = "0" ]; then
    record "$no $name" PASS "本体: $body_detail / metadata: $meta_detail [id=$id]"
  else
    record "$no $name" FAIL "本体: $body_detail / metadata: $meta_detail [id=$id]"
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

# DML（MERGE）のケース。本体（<id>.csv）は置かれず、<id>.csv.metadata だけが置かれ、
# その field 2 が expect_type、field 3 が expect_count であることを確かめる。
# field 3 より後ろ（列 `rows bigint`）は本物の Athena の実測値（tests/metadata.rs の
# COLUMN_ROWS_BIGINT）とバイト単位で同じであることも見る。
run_merge_case() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5" expect_type="$6" expect_count="$7"
  local rows_bigint_column="22220a04686976652204726f77732a04726f77733206626967696e743813400048035000"

  log "ケース $no: $name -- $sql"
  local id resp state

  id=$(athena_start_query "$sql" "$catalog" "$database")
  if [ -z "$id" ]; then
    record "$no $name" FAIL "StartQueryExecution が QueryExecutionId を返さなかった"
    return
  fi

  resp=$(athena_wait "$id")
  state=$(echo "$resp" | jq -r '.QueryExecution.Status.State // empty')
  if [ "$state" != "SUCCEEDED" ]; then
    local reason
    reason=$(echo "$resp" | jq -r '.QueryExecution.Status.StateChangeReason // empty')
    record "$no $name" FAIL "終了状態が SUCCEEDED でない: $state ($reason) [id=$id]"
    return
  fi

  local key="${PREFIX}/${id}.csv" detail="" ok=1
  if mc_exists "$(mc_stat "$key")"; then
    ok=0; detail="$detail 本体 ${id}.csv がある（DML は .metadata だけを置く想定）"
  fi

  local out="$EVIDENCE_DIR/${id}.csv.metadata"
  if ! mc_exists "$(mc_stat "${key}.metadata")"; then
    record "$no $name" FAIL ".metadata が無い [id=$id]"
    return
  fi
  mc_get "${key}.metadata" "$out"
  od -An -tx1c "$out" >"$out.od.txt" 2>/dev/null || true

  local head type_ count rest
  if ! head=$(read_metadata_head "$out"); then
    record "$no $name" FAIL ".metadata の形が想定外: $head (od: $out.od.txt) [id=$id]"
    return
  fi
  IFS=$'\t' read -r type_ count rest <<<"$head"
  [ "$type_" = "$expect_type" ] || { ok=0; detail="$detail updateType=$type_(期待 $expect_type)"; }
  [ "$count" = "$expect_count" ] || { ok=0; detail="$detail count=$count(期待 $expect_count)"; }
  [ "$rest" = "$rows_bigint_column" ] || { ok=0; detail="$detail field3より後ろ=$rest(期待 $rows_bigint_column)"; }

  if [ "$ok" = "1" ]; then
    record "$no $name" PASS "本体無し / metadata: updateType=$type_ count=$count 列=rows bigint（本物と同じバイト列） (od: $out.od.txt) [id=$id]"
  else
    record "$no $name" FAIL "不一致:$detail (od: $out.od.txt) [id=$id]"
  fi
}

# Athena の綴り（ADD COLUMNS）で ALTER TABLE を投げ、athena-local の構文確認
# （PREPARE ... FROM）で Trino の構文エラーとして弾かれることを確かめる。
# classification.rs の判定自体は ADD COLUMNS / ADD COLUMN のどちらでも効くが、
# Trino の文法には ADD COLUMN（単数形）しか無いため、実機では Athena の綴りは
# StartQueryExecution の時点で MALFORMED_QUERY になる想定（本物の Trino で先に実測済み）。
probe_add_columns_spelling() {
  local table="$1" catalog="$2" database="$3"
  local resp qid type_ code msg

  resp=$(athena_start_query_raw "ALTER TABLE ${table} ADD COLUMNS (m int)" "$catalog" "$database")
  qid=$(echo "$resp" | jq -r '.QueryExecutionId // empty')
  if [ -n "$qid" ]; then
    record "6前 ADD_COLUMNS綴り確認" FAIL "Athenaの綴り(ADD COLUMNS)がStartQueryExecutionを通ってしまった [id=$qid]（想定外）"
    return
  fi

  type_=$(echo "$resp" | jq -r '.__type // empty')
  code=$(echo "$resp" | jq -r '.AthenaErrorCode // empty')
  msg=$(echo "$resp" | jq -r '.Message // empty')
  record "6前 ADD_COLUMNS綴り確認" PASS \
    "Athenaの綴り(ADD COLUMNS)はTrinoの構文エラーで弾かれた（想定どおり）: __type=$type_ AthenaErrorCode=$code Message=$msg"
}

main() {
  log "作業ディレクトリ: $SCRIPT_DIR"
  log "証跡の保存先: $EVIDENCE_DIR"

  log "docker compose up -d"
  if ! docker compose -f "$COMPOSE_FILE" up -d; then
    record "compose起動" FAIL "docker compose up -d が失敗した"
    return 1
  fi

  local detected_network
  detected_network=$(docker network ls --filter "label=com.docker.compose.project=athena-local-issue39-e2e" --format '{{.Name}}' | head -1)
  if [ -n "$detected_network" ]; then
    MC_NETWORK="$detected_network"
  fi
  log "mc 用ネットワーク: $MC_NETWORK"

  if ! wait_for_trino; then
    record "Trino起動" FAIL "Trino が起動しなかった"
    return 1
  fi
  record "Trino起動" PASS "$TRINO_BASE で応答"

  if ! wait_for_bucket; then
    record "MinIOバケット" FAIL "バケット $BUCKET の用意ができなかった"
    return 1
  fi
  record "MinIOバケット" PASS "バケット $BUCKET 用意済み"

  log "Trino 側のスキーマを用意する"
  trino_exec "CREATE SCHEMA IF NOT EXISTS hive.default" hive default || true
  trino_exec "CREATE SCHEMA IF NOT EXISTS iceberg.default" iceberg default || true

  local t_iceberg="t_drop_iceberg_${RUN_ID}"
  local t_hive="t_drop_hive_${RUN_ID}"
  local t_plain="t_plain_${RUN_ID}"
  local t_missing="t_missing_${RUN_ID}"
  local t_alter_hive="t_alter_hive_${RUN_ID}"
  local t_alter_iceberg="t_alter_iceberg_${RUN_ID}"
  local t_merge_iceberg="t_merge_iceberg_${RUN_ID}"

  log "DROP TABLE 用のテーブルを作る（形式ごと）"
  if ! trino_exec "CREATE TABLE iceberg.default.${t_iceberg} AS SELECT 1 AS n" iceberg default; then
    record "セットアップ(iceberg)" FAIL "iceberg.default.${t_iceberg} の作成に失敗した"
  else
    record "セットアップ(iceberg)" PASS "iceberg.default.${t_iceberg} 作成済み"
  fi
  if ! trino_exec "CREATE TABLE hive.default.${t_hive} AS SELECT 1 AS n" hive default; then
    record "セットアップ(hive)" FAIL "hive.default.${t_hive} の作成に失敗した"
  else
    record "セットアップ(hive)" PASS "hive.default.${t_hive} 作成済み"
  fi

  log "ALTER TABLE 用のテーブルを作る（形式ごと。DROP TABLE のケースで消えるテーブルとは別に用意する）"
  if ! trino_exec "CREATE TABLE hive.default.${t_alter_hive} AS SELECT 1 AS n" hive default; then
    record "セットアップ(alter hive)" FAIL "hive.default.${t_alter_hive} の作成に失敗した"
  else
    record "セットアップ(alter hive)" PASS "hive.default.${t_alter_hive} 作成済み"
  fi
  if ! trino_exec "CREATE TABLE iceberg.default.${t_alter_iceberg} AS SELECT 1 AS n" iceberg default; then
    record "セットアップ(alter iceberg)" FAIL "iceberg.default.${t_alter_iceberg} の作成に失敗した"
  else
    record "セットアップ(alter iceberg)" PASS "iceberg.default.${t_alter_iceberg} 作成済み"
  fi

  log "MERGE 用のテーブルを作る（Iceberg。MERGE は Iceberg のテーブルでしか動かない）"
  if ! trino_exec "CREATE TABLE iceberg.default.${t_merge_iceberg} AS SELECT 1 AS n, 'a' AS s" iceberg default; then
    record "セットアップ(merge iceberg)" FAIL "iceberg.default.${t_merge_iceberg} の作成に失敗した"
  else
    record "セットアップ(merge iceberg)" PASS "iceberg.default.${t_merge_iceberg} 作成済み"
  fi

  if ! build_athena_local; then
    record "cargo build" FAIL "ビルドが失敗した。並行編集中のコードが原因なら athena-local 側のケースは実行不能"
    record "ケース1〜5" SKIP "athena-local が起動できないため実行しなかった（ビルド失敗）"
    return 1
  fi
  record "cargo build" PASS "target/release/athena-local を用意した"

  if ! start_athena_local; then
    record "ケース1〜5" SKIP "athena-local が起動しなかったため実行しなかった"
    return 1
  fi
  record "athena-local起動" PASS "$ATHENA_BASE で応答"

  # ケース 1: DROP TABLE（Iceberg）
  run_case 1 "DROP_TABLE_iceberg" \
    "DROP TABLE ${t_iceberg}" iceberg default txt \
    1 "application/octet-stream" 1 1 41

  # ケース 2: DROP TABLE（Hive）
  run_case 2 "DROP_TABLE_hive" \
    "DROP TABLE ${t_hive}" hive default txt \
    0 "binary/octet-stream" 0 0

  # ケース 3: DROP TABLE IF EXISTS（存在しない・Iceberg）。Phase 2 で初めて通る想定。
  run_case 3 "DROP_TABLE_IF_EXISTS_存在しない_iceberg" \
    "DROP TABLE IF EXISTS ${t_missing}" iceberg default txt \
    0 "binary/octet-stream" 0 0
  local case3_idx=$(( ${#RESULT_STATUS[@]} - 1 ))
  if [ "${RESULT_STATUS[$case3_idx]}" = "FAIL" ]; then
    RESULT_DETAIL[$case3_idx]="${RESULT_DETAIL[$case3_idx]} ※Phase 1 時点は失敗が想定どおり（対象テーブルの存在確認は Phase 2 の範囲）"
  fi

  # ケース 4: CREATE TABLE（Iceberg、素の CREATE）。回帰していないことの確認。
  run_case 4 "CREATE_TABLE_iceberg_回帰確認" \
    "CREATE TABLE ${t_plain} (n int)" iceberg default txt \
    0 "binary/octet-stream" 0 0

  # ケース 5: SELECT。回帰していないことの確認（.csv が置かれること）。
  local id5 resp5 state5 key5 out5 size5
  id5=$(athena_start_query "SELECT 1 AS n" iceberg default)
  if [ -z "$id5" ]; then
    record "5 SELECT_回帰確認" FAIL "StartQueryExecution が QueryExecutionId を返さなかった"
  else
    resp5=$(athena_wait "$id5")
    state5=$(echo "$resp5" | jq -r '.QueryExecution.Status.State // empty')
    if [ "$state5" != "SUCCEEDED" ]; then
      record "5 SELECT_回帰確認" FAIL "終了状態が SUCCEEDED でない: $state5 [id=$id5]"
    else
      key5="${PREFIX}/${id5}.csv"
      out5="$EVIDENCE_DIR/$(basename "$key5")"
      mc_get "$key5" "$out5"
      size5=$(stat -c%s "$out5" 2>/dev/null || wc -c <"$out5")
      if [ "${size5:-0}" -gt 0 ]; then
        record "5 SELECT_回帰確認" PASS ".csv が置かれた size=${size5}B 中身: $(tr '\n' '|' <"$out5") [id=$id5]"
      else
        record "5 SELECT_回帰確認" FAIL ".csv が置かれていないか 0 バイト [id=$id5]"
      fi
    fi
  fi

  # ケース 6 前段: Athena の綴り（ADD COLUMNS）は Trino の構文エラーで弾かれることを確認する
  # （athena-local は SQL 本文を書き換えないため、Trino の文法に無い複数形はそのまま構文エラーになる）。
  probe_add_columns_spelling "${t_alter_hive}" hive default

  # ケース 6: ALTER TABLE ... ADD COLUMN（Trino の綴り・単数形）× Hive。
  # classification.rs の判定は ADD COLUMNS / ADD COLUMN のどちらでも効くが、Trino に投げられるのは
  # 単数形だけなので、実機で通す文はこちらにする。
  run_case 6 "ALTER_TABLE_ADD_COLUMN_hive" \
    "ALTER TABLE ${t_alter_hive} ADD COLUMN m int" hive default txt \
    0 "application/octet-stream" 0 1 38

  # ケース 7: ALTER TABLE ... ADD COLUMN × Iceberg。今までどおり本体 0 バイト・binary/octet-stream・
  # .metadata 無し（Hive だけを特別扱いする実装のままであることの確認）。
  run_case 7 "ALTER_TABLE_ADD_COLUMN_iceberg" \
    "ALTER TABLE ${t_alter_iceberg} ADD COLUMN m int" iceberg default txt \
    0 "binary/octet-stream" 0 0

  # ケース 8: ALTER TABLE ... SET PROPERTIES × Iceberg（対象外の ALTER が巻き込まれていないことの確認）。
  # Athena の綴り（SET TBLPROPERTIES）は Trino の構文エラー（mismatched input 'TBLPROPERTIES'.
  # Expecting: 'AUTHORIZATION', 'PROPERTIES'）になるため実機では投げられない（事前に確認済み）。
  # comment プロパティは Iceberg 側に存在しない（Catalog 'iceberg' table property 'comment' does
  # not exist）ため、Trino で通る format プロパティを使う。
  run_case 8 "ALTER_TABLE_SET_PROPERTIES_iceberg" \
    "ALTER TABLE ${t_alter_iceberg} SET PROPERTIES format = 'PARQUET'" iceberg default txt \
    0 "binary/octet-stream" 0 0

  # ケース 9（issue #56）: MERGE × Iceberg。本物の Trino が updateType に "MERGE" を返し、
  # .metadata の field 2 がその文字列になること（本物の Athena は "MERGE"。2026-09-20 実測）。
  # 1 行が MATCHED（更新）、1 行が NOT MATCHED（挿入）になる形にして、field 3（更新件数）が 2 になることも見る。
  run_merge_case 9 "MERGE_iceberg" \
    "MERGE INTO ${t_merge_iceberg} AS t USING (VALUES (1, 'b'), (2, 'c')) AS u(n, s) ON t.n = u.n WHEN MATCHED THEN UPDATE SET s = u.s WHEN NOT MATCHED THEN INSERT (n, s) VALUES (u.n, u.s)" \
    iceberg default MERGE 2

  # ケース 10〜12（issue #111）: UPDATE / DELETE（Iceberg）と、Hive への UPDATE の失敗。
  run_update_delete_cases
  run_failed_update_case

  # ケース 14（issue #111）: 保持期限 1 秒で再起動し、捨てられた実行の S3 の結果が残ることを見る。
  if restart_athena_local_with_retention 1; then
    run_retention_s3_case
  else
    record "14 保持期限後もS3の結果は残る" FAIL "athena-local が ATHENA_LOCAL_RETENTION_SECONDS=1 で起動しない（athena-local 側の退行）"
  fi

  local status fails=0
  for status in "${RESULT_STATUS[@]}"; do
    [ "$status" = "FAIL" ] && fails=$((fails + 1))
  done
  return "$fails"
}

main
