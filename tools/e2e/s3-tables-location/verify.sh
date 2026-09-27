#!/usr/bin/env bash
# issue #229 の実機検証の足場（tools/e2e/create-table-catalog/verify.sh を雛形にした）。
#
# #229 の変更: QueryExecutionContext の Catalog が S3 Tables（`s3tablescatalog/` で始まる、大文字小文字は
# 区別しない）のとき、StartQueryExecution は構文チェック（Trino への PREPARE）より前に、Hive の
# `CREATE [EXTERNAL] TABLE ... LOCATION '...'` を
# `Table location can not be specified for tables hosted in S3 table buckets` で、LOCATION の無い
# `CREATE EXTERNAL TABLE t (n int)` を `External keyword not supported for table type ICEBERG` で弾く
# （400、InvalidRequestException、AthenaErrorCode MALFORMED_QUERY）。Hive の構文で読めない形（NOT NULL・
# LOCATION より前の TBLPROPERTIES など）は今までどおり Trino の構文チェックの文言を返す。既定の Context
# （S3 Tables でないカタログ）は変わらない（src/operation/unquoted_ddl/create_table/hive.rs）。
#
# この足場は compose のローカル Trino の iceberg カタログを S3 Tables の別名（TRINO_CATALOG_MAP の
# `s3tablescatalog/e2e229=iceberg,AwsDataCatalog=hive`）にし、athena-local の StartQueryExecution／
# GetQueryExecution に次のケース表を流して判定する。本物の AWS には投げない（compose の trino・minio だけ）。
# 名前空間は作らない（すべて開始時に弾かれるか、表を触らない SELECT なので不要）。
#
# ケース表（TRINO_CATALOG_MAP=s3tablescatalog/e2e229=iceberg,AwsDataCatalog=hive）:
#   L1 S3 Tables の Context（Catalog=s3tablescatalog/e2e229,Database=e2e229ns）
#      CREATE TABLE awsdatacatalog.default.t229 (n int) LOCATION 's3://b/p/'
#      → 400、MALFORMED_QUERY／Message ちょうど
#        "Table location can not be specified for tables hosted in S3 table buckets"
#   L2 同じ Context
#      CREATE EXTERNAL TABLE t229 (n int)
#      → 400、MALFORMED_QUERY／"External keyword not supported for table type ICEBERG"
#   L3 同じ Context・Catalog を大文字混じり S3TablesCatalog/e2e229
#      create table t229 (n int) location 's3://b/p/'
#      → L1 と同じ文言
#   L4 同じ Context（Catalog は L1 と同じ小文字 s3tablescatalog/e2e229）
#      CREATE TABLE t229 (n int NOT NULL) LOCATION 's3://b/p/'
#      → 400、MALFORMED_QUERY／Message ちょうど
#        "line 1:36: mismatched input 'LOCATION'. Expecting: 'COMMENT', 'WITH', <EOF>"
#        （NOT NULL は hive.rs の測った形にないので None になり、Trino の構文チェックに落ちる。列位置 36 は
#        "CREATE TABLE t229 (n int NOT NULL) " の文字数から数えて確認済み）
#   L5 同じ Context
#      CREATE TABLE t229 (n int) TBLPROPERTIES ('table_type'='ICEBERG') LOCATION 's3://b/p/'
#      → 400、MALFORMED_QUERY／Message ちょうど
#        "line 1:27: mismatched input 'TBLPROPERTIES'. Expecting: 'COMMENT', 'WITH', <EOF>"
#        （LOCATION より前の TBLPROPERTIES も測った形にないので None。列位置 27 を確認済み）
#   L6 既定の Context（Catalog=AwsDataCatalog,Database=default）
#      CREATE TABLE t229 (n int) LOCATION 's3://b/p/'
#      → 400、MALFORMED_QUERY／Message ちょうど
#        "line 1:27: mismatched input 'LOCATION'. Expecting: 'COMMENT', 'WITH', <EOF>"
#        （S3 Tables でない Context なので hive.rs は素通りし、いつもの Trino の構文チェックの文言のまま）
#   L7 既定の Context
#      CREATE EXTERNAL TABLE t229 (n int)
#      → 400、MALFORMED_QUERY／Message が "mismatched input 'EXTERNAL'" を含む
#        （実際は "line 1:8: mismatched input 'EXTERNAL'. Expecting: ..." で、先頭に位置情報が付くので
#        部分一致で見る。位置・語順まで固定するのは過剰）
#   L8 S3 Tables の Context
#      SELECT 1
#      → 200 と QueryExecutionId（疎通。SUCCEEDED まで待つ）
#   #248 で足したケース:
#   L9 S3 Tables の Context
#      CREATE TABLE t229 (n int) COMMENT 'c' LOCATION 's3://b/p/'
#      → L1 と同じ文言（表の COMMENT も Hive の句として読む。実測 s1）
#   L10 S3 Tables の Context
#      CREATE TABLE t229 (c row(a int)) LOCATION 's3://b/p/'
#      → 400、MALFORMED_QUERY／Message ちょうど
#        "line 1:34: mismatched input 'LOCATION'. Expecting: 'COMMENT', 'WITH', <EOF>"
#        （本物も Trino の形の文言を返した（実測 s17）。ローカルの Trino の構文チェックの文言と位置が本物と
#        同じ形になることをここで確かめる。列位置 34 は "CREATE TABLE t229 (c row(a int)) " の文字数 + 1）
#   L11 既定の Context
#      CREATE TABLE nosuchcatalog248.default.t229 (n int) LOCATION 's3://b/p/'
#      → 400、DATACATALOG_NOT_FOUND／"Catalog 'nosuchcatalog248' does not exist"（実測 s12）
#   L12 S3 Tables の Context
#      CREATE TABLE t229 (n int) STORED AS ORC
#      → 開始でき FAILED、StateChangeReason
#        "Iceberg create table statement does not allow STORED AS/BY"（実測 s15）
#
#   #266 で足したケース（LOCATION の無い EXTERNAL の句・IF NOT EXISTS・バッククォート、LOCATION の無い
#   STORED AS の 2 部・3 部・IF NOT EXISTS・句・列リスト無し、実在しないカタログの EXTERNAL の 3 部 + LOCATION、
#   実在しないカタログの IF NOT EXISTS + STORED AS の 3 部 + LOCATION による絞り込みの広がりと、変わらない
#   4 つの回帰）:
#   M1 S3 Tables の Context
#      CREATE EXTERNAL TABLE t266 (n int) COMMENT 'c'
#      → L2 と同じ文言（COMMENT があっても EXTERNAL の判定は変わらない）
#   M2 S3 Tables の Context
#      CREATE EXTERNAL TABLE `t266` (n int)
#      → L2 と同じ文言（バッククォートの名前でも変わらない）
#   M3 S3 Tables の Context
#      CREATE TABLE e2e229ns.t266 (n int) STORED AS PARQUET
#      → 開始して FAILED、StateChangeReason "Iceberg create table statement does not allow STORED AS/BY"
#        （L12 と同じ文言。2 部の名前でも変わらない）
#   M4 S3 Tables の Context
#      CREATE TABLE IF NOT EXISTS t266 (n int) STORED AS PARQUET
#      → M3 と同じ（IF NOT EXISTS があっても変わらない）
#   M5 S3 Tables の Context
#      CREATE TABLE t266 (n int) COMMENT 'c' STORED AS PARQUET
#      → M3 と同じ（COMMENT があっても変わらない）
#   M6 S3 Tables の Context
#      CREATE TABLE AwsDataCatalog.e2e229ns.t266 (n int) STORED AS PARQUET
#      → M3 と同じ（大文字混じりの AwsDataCatalog の 3 部でも変わらない）
#   M7 S3 Tables の Context
#      CREATE TABLE t266 STORED AS PARQUET
#      → M3 と同じ（列リストが無くても変わらない）
#   M8 既定の Context（Catalog=AwsDataCatalog,Database=default）
#      CREATE EXTERNAL TABLE nosuchcatalog266.default.t266 (n int) LOCATION 's3://b/p/'
#      → 400、DATACATALOG_NOT_FOUND／"Catalog 'nosuchcatalog266' does not exist"（EXTERNAL があっても L11 と同じ）
#   M9 S3 Tables の Context
#      CREATE EXTERNAL TABLE nosuchcatalog266.e2e229ns.t266 (n int) LOCATION 's3://b/p/'
#      → M8 と同じ（S3 Tables の Context でも同じ）
#   M10 S3 Tables の Context
#      CREATE TABLE IF NOT EXISTS nosuchcatalog266.e2e229ns.t266 (n int) STORED AS PARQUET LOCATION 's3://b/p/'
#      → M8 と同じ（IF NOT EXISTS・STORED AS があっても DATACATALOG_NOT_FOUND が先）
#   #270 で足したケース（S3 Tables の Context・LOCATION も EXTERNAL も無い CREATE TABLE で、本物は開始してから
#   句どうしの優先順 CLUSTERED BY > ROW FORMAT > STORED AS > 型付き PARTITIONED BY > 未知の TBLPROPERTIES に
#   したがって FAILED にする。結果ファイル本体も .metadata も置かない。StatementType DDL・SubstatementType
#   CREATE_TABLE・Retryable false。実測は .claude/issue-notes/270.md の ROUND=16）:
#   N1 S3 Tables の Context
#      CREATE TABLE t270row1 (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
#      → 開始して FAILED、StateChangeReason・AthenaError.ErrorMessage ちょうど
#        "Iceberg create table statement does not allow ROW FORMAT"（ErrorCategory 2・ErrorType 1200）
#   N2 S3 Tables の Context
#      CREATE TABLE t270row2 (n int) ROW FORMAT DELIMITED FIELDS TERMINATED BY ','
#      → N1 と同じ文言（DELIMITED でも SERDE と変わらない）
#   N3 S3 Tables の Context
#      CREATE TABLE t270clu (n int) CLUSTERED BY (n) INTO 4 BUCKETS
#      → 開始して FAILED、"Iceberg create table statement does not allow CLUSTERED BY"（2/1200）
#   N4 S3 Tables の Context
#      CREATE TABLE t270part (n int) PARTITIONED BY (p int)（型付き列）
#      → 開始して FAILED、"Invalid PARTITIONED BY clause in Iceberg create table statement"（2/1006）
#   N5 S3 Tables の Context
#      CREATE TABLE t270prop (n int) TBLPROPERTIES ('a270'='b')（未知のキー 1 つ）
#      → 開始して FAILED、"Unsupported table property key: a270"（2/1200）
#   N6 S3 Tables の Context
#      CREATE TABLE t270nocol TBLPROPERTIES ('a270'='b')（列リスト無し + 未知のキー）
#      → 開始して FAILED、"At least one column is required for Iceberg create table statement"（2/1006。
#        列が無いことが未知のキーより先）
#   N7 S3 Tables の Context
#      CREATE TABLE AwsDataCatalog.e2e229ns.t270awsdc (n int) ROW FORMAT SERDE 'x'（大文字混じりの 3 部）
#      → N1 と同じ文言。GetQueryExecution の Query は 1 部目を落とした
#        "CREATE TABLE e2e229ns.t270awsdc (n int) ROW FORMAT SERDE 'x'"、
#        QueryExecutionContext.Database は "e2e229ns"（#271 の挙動が #270 の失敗でも効く）
#   N8（優先順の対） S3 Tables の Context
#      CREATE TABLE t270pair1 (n int) CLUSTERED BY (n) INTO 4 BUCKETS ROW FORMAT SERDE 'x'
#      → N3 と同じ（CLUSTERED BY が ROW FORMAT より先）
#   N9（優先順の対） S3 Tables の Context
#      CREATE TABLE t270pair2 (n int) PARTITIONED BY (p int) TBLPROPERTIES ('a270'='b')
#      → N4 と同じ（型付き PARTITIONED BY が未知の TBLPROPERTIES より先）
#
#   R1（#270 の範囲。旧: #266 の広がりの外の回帰） S3 Tables の Context
#      CREATE TABLE t266 (n int) ROW FORMAT SERDE 'x' STORED AS TEXTFILE
#      → N1 と同じ（ROW FORMAT が STORED AS より先。#270 で Trino の構文エラーから開始後の FAILED に変わる）
#   R2（#270 の範囲。旧: #266 の広がりの外の回帰） S3 Tables の Context
#      CREATE TABLE t266 (n int) CLUSTERED BY (n) INTO 4 BUCKETS STORED AS PARQUET
#      → N3 と同じ（CLUSTERED BY が STORED AS より先。同じく #270 で変わる）
#   R3（#270 の範囲。旧: #266 の広がりの外の回帰） S3 Tables の Context
#      CREATE TABLE awsdatacatalog.e2e229ns.t266 (n int) STORED AS PARQUET
#      → 開始時に弾く（400、MALFORMED_QUERY、"Unsupported ddl with 2 catalogs: <文>"。<文> は受け取った文の
#        前後の空白を落としたもの。ちょうど小文字の 3 部は句によらず 2 catalogs が先で、#270 で Trino の構文
#        エラーから開始時の 2 catalogs に変わる）
#   R4（回帰） 既定の Context
#      CREATE EXTERNAL TABLE hive.default.t266 (n int) LOCATION 's3://b/p/'
#      → 400、MALFORMED_QUERY（Trino にあるカタログを 1 部目に書いた EXTERNAL は S3 Tables の判定の外。
#        Trino の構文エラーのまま。#270 でも変わらない）
#   R5（回帰） S3 Tables の Context
#      CREATE TABLE t270reg1 (n int) PARTITIONED BY (n)（Iceberg の書き方。型の無い列名だけ）
#      → 400、MALFORMED_QUERY（本物は SUCCEEDED だが、athena-local は Athena と Trino の書き方の違いを
#        埋める書き換えをしない方針なので、#270 の後も Trino の構文エラーのまま。文言は変更前のビルドで
#        実測して確認した実際のもの）
#   R6（回帰） S3 Tables の Context
#      CREATE TABLE t270reg2 (n int) TBLPROPERTIES ('table_type'='ICEBERG')（Iceberg で有効なキー）
#      → 400、MALFORMED_QUERY（本物は SUCCEEDED だが、同じ理由で #270 の後も Trino の構文エラーのまま）
#
#   #270 のフェーズ 2 で足したケース（LOCATION も EXTERNAL も無い CREATE TABLE の TBLPROPERTIES の
#   table_type・compression_level を開始時に弾く、列の並び無し + 型付き PARTITIONED BY・複数の未知のキー・
#   名前空間が無い 2 部 + ROW FORMAT を開始して FAILED にする、Trino に TBLPROPERTIES が無いことによる回帰）:
#   P1 S3 Tables の Context
#      CREATE TABLE t270ty1 (n int) TBLPROPERTIES ('table_type'='hive')
#      → 400、MALFORMED_QUERY／"Only ICEBERG table format is supported with S3 table buckets"
#   P2 S3 Tables の Context
#      CREATE TABLE t270ty2 (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
#      TBLPROPERTIES ('table_type'='HIVE')
#      → P1 と同じ（ROW FORMAT があっても table_type が ICEBERG 以外が先）
#   P3 S3 Tables の Context
#      CREATE TABLE t270cl3 (n int) TBLPROPERTIES ('compression_level'='3')
#      → 400、MALFORMED_QUERY／"Compression codec must be defined when compression_level property is
#        specified."
#   P4 S3 Tables の Context
#      CREATE TABLE awsdatacatalog.e2e229ns.t270awsdc3 (n int) ROW FORMAT SERDE
#      'org.apache.hadoop.hive.serde2.OpenCSVSerde'（ちょうど小文字の 3 部）
#      → 400、MALFORMED_QUERY／"Unsupported ddl with 2 catalogs: <前後の空白を落とした文>"
#   P5 S3 Tables の Context
#      CREATE TABLE t270bare（列の並びも句も無し）
#      → 開始して FAILED、"At least one column is required for Iceberg create table statement"（2/1006）
#   P6 S3 Tables の Context
#      CREATE TABLE t270barepart PARTITIONED BY (p int)（列の並び無し + 型付き PARTITIONED BY）
#      → 開始して FAILED、"Invalid PARTITIONED BY clause in Iceberg create table statement"（2/1006。
#        列が無いことより PARTITIONED BY の句が先）
#   P7 S3 Tables の Context
#      CREATE TABLE t270multi (n int) TBLPROPERTIES ('a270x'='b', 'a270y'='c')（未知のキー 2 つ）
#      → 開始して FAILED、"Unsupported table property key: a270x"（2/1200。書いた順の最初のキー）
#   P8 S3 Tables の Context
#      CREATE TABLE e2e270nope.t270row4 (n int) ROW FORMAT SERDE
#      'org.apache.hadoop.hive.serde2.OpenCSVSerde'（e2e270nope は作らない 2 部の名前空間）
#      → 開始して FAILED、"Iceberg create table statement does not allow ROW FORMAT"（2/1200。
#        名前空間の存在確認より句の判定が先）
#   P9（回帰） S3 Tables の Context
#      CREATE TABLE t270reg3 (n int) TBLPROPERTIES ('vacuum_max_snapshot_age_seconds'='432000')
#      （本物が受理する Iceberg の有効なキーだが Trino に TBLPROPERTIES が無い）
#      → 400、MALFORMED_QUERY（Trino の構文エラーのまま。文言はローカルの Trino で実測した実際のもの）
#
#   #270 の変更を入れる前（このブランチの着手前ビルド）に流すと、N1〜N9・R1〜R3・P1〜P9 が FAIL し、L・M 系と
#   R4〜R6 は PASS になる想定（#270 の変更は別の担当がこのあと src に入れる）。
#
# 前提コマンド: tools/dev.sh 経由で動かす（toolbox に全部入っている）
#
# 使い方:
#   tools/dev.sh tools/e2e/s3-tables-location/verify.sh
#
# 環境変数:
#   KEEP_UP=1        テスト後に docker compose down -v をせず環境を残す（デバッグ用）
#   SKIP_BUILD=1     cargo build を省略し、$BINARY（無ければ $CARGO_TARGET_DIR の release/athena-local）をそのまま使う
#   BINARY=<path>    使う athena-local バイナリを差し替える（変更前後の 2 段階の受け入れ用。SKIP_BUILD=1 と組み合わせる）
#
# 後始末は本スクリプトの trap が行う: athena-local を止め、docker compose down -v trino minio minio-init する
# （KEEP_UP=1 でなければ）。ほかの docker コンテナや compose のサービスは止めたり消したりしない。cargo test も
# 走らせない。終了コードは結果表の FAIL の件数を数え、1 件でもあれば 1。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# cargo の成果物の置き場。tools/dev.sh は CARGO_TARGET_DIR を .toolbox/target にする。BINARY を明示すればそちらを使う
BINARY="${BINARY:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/athena-local}"
COMPOSE=(docker compose -f "$REPO_ROOT/compose.yml")
SERVICES=(trino minio minio-init)

TRINO_BASE="http://trino:8080"
MINIO_ENDPOINT="http://minio:9000"
BUCKET="athena-results"
PREFIX="e2e229"
OUTPUT_LOCATION="s3://${BUCKET}/${PREFIX}/"

S3_TABLES_CATALOG="s3tablescatalog/e2e229"
S3_TABLES_CATALOG_MIXED="S3TablesCatalog/e2e229"
NS="e2e229ns"
# #266 で足したケースの表名・実在しないカタログ名（L1〜L12 の t229 と区別する）
T266="t266"
NOSUCHCATALOG266="nosuchcatalog266"
# #270 で足したケースの表名接頭辞（既存の t229・t266 と区別する）
T270="t270"
# #270 のフェーズ 2（P8）で使う、わざと作らない 2 部の名前空間
NS_MISSING="e2e270nope"

ATHENA_BIND="127.0.0.1:8129"
ATHENA_BASE="http://${ATHENA_BIND}"

EVIDENCE_DIR="$(mktemp -d /tmp/athena-local-issue229-e2e.XXXXXX)"
ATHENA_LOG="$EVIDENCE_DIR/athena-local.log"
BUILD_LOG="$EVIDENCE_DIR/cargo-build.log"

ATHENA_PID=""

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
    printf "%-6s %-56s %s\n" "${RESULT_STATUS[$i]}" "${RESULT_NAMES[$i]}" "${RESULT_DETAIL[$i]}"
  done
  echo "=============================================="
  local pass=0 fail=0 skip=0
  local -a failed=()
  for i in "${!RESULT_STATUS[@]}"; do
    case "${RESULT_STATUS[$i]}" in
      PASS) pass=$((pass + 1)) ;;
      FAIL) fail=$((fail + 1)); failed+=("${RESULT_NAMES[$i]}") ;;
      *) skip=$((skip + 1)) ;;
    esac
  done
  echo "PASS=$pass FAIL=$fail SKIP=$skip"
  if [ "$fail" -gt 0 ]; then
    echo "FAIL の一覧:"
    for i in "${failed[@]}"; do
      echo "  - $i"
    done
  fi
  echo "証跡（起動ログ・取得したファイル）: $EVIDENCE_DIR"
  [ "$fail" -eq 0 ]
}

cleanup() {
  local status=$?
  if [ -n "$ATHENA_PID" ] && kill -0 "$ATHENA_PID" 2>/dev/null; then
    log "athena-local (PID $ATHENA_PID) を止める"
    kill "$ATHENA_PID" 2>/dev/null || true
    wait "$ATHENA_PID" 2>/dev/null || true
  fi

  if [ "${KEEP_UP:-0}" = "1" ]; then
    log "KEEP_UP=1 のため docker compose はそのまま残す（後で tools/dev.sh docker compose -f $REPO_ROOT/compose.yml down -v ${SERVICES[*]}）"
  else
    log "docker compose down -v ${SERVICES[*]}"
    "${COMPOSE[@]}" down -v "${SERVICES[@]}" >/dev/null 2>&1
  fi
  print_table
  local table_status=$?
  if [ "$status" -eq 0 ]; then
    status=$table_status
  fi
  exit "$status"
}
trap cleanup EXIT

# --- Trino への直接アクセス（起動待ちの疎通確認専用。測定対象の文は athena-local 経由で投げる） ---

trino_exec() {
  local sql="$1" catalog="$2" schema="$3"
  local resp next
  resp=$(curl -sf -X POST "$TRINO_BASE/v1/statement" \
    -H "X-Trino-User: e2e-229-setup" \
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

start_athena_local() {
  log "athena-local を起動する（bind=$ATHENA_BIND、binary=$BINARY、TRINO_CATALOG_MAP=${S3_TABLES_CATALOG}=iceberg,AwsDataCatalog=hive、ログ: $ATHENA_LOG）"
  (
    cd "$REPO_ROOT"
    exec env \
      ATHENA_LOCAL_BIND="$ATHENA_BIND" \
      TRINO_URL="$TRINO_BASE" \
      TRINO_USER="athena-local-e2e229" \
      TRINO_CATALOG_MAP="${S3_TABLES_CATALOG}=iceberg,AwsDataCatalog=hive" \
      ATHENA_LOCAL_RESULTS="s3" \
      AWS_ENDPOINT_URL_S3="$MINIO_ENDPOINT" \
      AWS_ACCESS_KEY_ID="minioadmin" \
      AWS_SECRET_ACCESS_KEY="minioadmin" \
      ATHENA_LOCAL_OUTPUT_LOCATION="$OUTPUT_LOCATION" \
      "$BINARY"
  ) >"$ATHENA_LOG" 2>&1 &
  ATHENA_PID=$!

  log "athena-local ($ATHENA_BASE) の起動待ち"
  local _ status
  for _ in $(seq 1 30); do
    if ! kill -0 "$ATHENA_PID" 2>/dev/null; then
      log "athena-local が異常終了した。ログ:"
      cat "$ATHENA_LOG" >&2
      return 1
    fi
    status=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$ATHENA_BASE/" \
      -H "X-Amz-Target: AmazonAthena.ListWorkGroups" \
      -H "Content-Type: application/x-amz-json-1.1" \
      --data-binary '{}')
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

# QueryExecutionContext（Catalog・Database）付きの StartQueryExecution。
start_raw() {
  local sql="$1" catalog="$2" database="$3"
  local body
  body=$(jq -cn --arg sql "$sql" --arg catalog "$catalog" --arg db "$database" --arg token "$(uuidgen)" \
    '{QueryString: $sql, QueryExecutionContext: {Catalog: $catalog, Database: $db}, ClientRequestToken: $token}')
  athena_call StartQueryExecution "$body"
}

# QUEUED/RUNNING でなくなるまで GetQueryExecution をポーリングし、最後の応答を返す。
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

# --- S3（MinIO）側の確認（toolbox の mc で minio:9000 を直接見る。tools/e2e/create-table-catalog/verify.sh の
#     mc_stat・mc_exists と同じ確かめ方。#270） ---

# `mc stat --json <key>` を実行して、key ちょうど一致するオブジェクトの JSON を返す。無ければ
# {"status":"error"} を返す（mc stat が前方一致もヒットさせる注意は tools/e2e/minio/lib.sh の mc_stat と同じ）。
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

# --- ケースの判定 ---

# StartQueryExecution が開始時に弾かれることを確かめる。expect_message は完全一致。
case_reject() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5" expect_code="$6" expect_message="$7"
  local resp qid type_ code msg ok=1 detail=""
  resp=$(start_raw "$sql" "$catalog" "$database")
  qid=$(echo "$resp" | jq -r '.QueryExecutionId // empty')
  if [ -n "$qid" ]; then
    record "$no $name" FAIL "拒否される想定が開始できてしまった: QueryExecutionId=$qid"
    return
  fi
  type_=$(echo "$resp" | jq -r '.__type // empty')
  code=$(echo "$resp" | jq -r '.AthenaErrorCode // empty')
  msg=$(echo "$resp" | jq -r '.Message // empty')
  [ "$type_" = "InvalidRequestException" ] || { ok=0; detail="$detail __type=${type_:-無し}(期待 InvalidRequestException)"; }
  [ "$code" = "$expect_code" ] || { ok=0; detail="$detail AthenaErrorCode=${code:-無し}(期待 $expect_code)"; }
  [ "$msg" = "$expect_message" ] || { ok=0; detail="$detail Message=\"$msg\"(期待 \"$expect_message\")"; }
  if [ "$ok" = "1" ]; then
    record "$no $name" PASS "AthenaErrorCode=$code Message=\"$msg\""
  else
    record "$no $name" FAIL "${detail# }"
  fi
}

# case_reject と同じだが、Message は部分一致（contains）で確かめる（L7: Trino のごく普通の構文エラーで、
# 実際には "line 1:8: mismatched input 'EXTERNAL'. Expecting: ..." のように先頭に位置情報が付く。実測していない
# 位置・語順・空白まで固定するのは過剰なため、期待の断片を含むかどうかだけ見る）。
case_reject_contains() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5" expect_code="$6" expect_substring="$7"
  local resp qid type_ code msg ok=1 detail=""
  resp=$(start_raw "$sql" "$catalog" "$database")
  qid=$(echo "$resp" | jq -r '.QueryExecutionId // empty')
  if [ -n "$qid" ]; then
    record "$no $name" FAIL "拒否される想定が開始できてしまった: QueryExecutionId=$qid"
    return
  fi
  type_=$(echo "$resp" | jq -r '.__type // empty')
  code=$(echo "$resp" | jq -r '.AthenaErrorCode // empty')
  msg=$(echo "$resp" | jq -r '.Message // empty')
  [ "$type_" = "InvalidRequestException" ] || { ok=0; detail="$detail __type=${type_:-無し}(期待 InvalidRequestException)"; }
  [ "$code" = "$expect_code" ] || { ok=0; detail="$detail AthenaErrorCode=${code:-無し}(期待 $expect_code)"; }
  case "$msg" in
    *"$expect_substring"*) ;;
    *) ok=0; detail="$detail Message=\"$msg\"(期待 部分一致 \"$expect_substring\")" ;;
  esac
  if [ "$ok" = "1" ]; then
    record "$no $name" PASS "AthenaErrorCode=$code Message=\"$msg\""
  else
    record "$no $name" FAIL "${detail# }"
  fi
}

# L8: 開始できて QueryExecutionId が返ることを確かめる。待てれば SUCCEEDED まで見る。
case_start_ok() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5"
  local start qid final state
  start=$(start_raw "$sql" "$catalog" "$database")
  qid=$(echo "$start" | jq -r '.QueryExecutionId // empty')
  if [ -z "$qid" ]; then
    record "$no $name" FAIL "開始できなかった: $(echo "$start" | tr -d '\n' | cut -c1-200)"
    return
  fi
  final=$(athena_wait "$qid")
  state=$(echo "$final" | jq -r '.QueryExecution.Status.State // empty')
  if [ "$state" = "SUCCEEDED" ]; then
    record "$no $name" PASS "QueryExecutionId=$qid State=$state"
  else
    local reason
    reason=$(echo "$final" | jq -r '.QueryExecution.Status.StateChangeReason // empty')
    record "$no $name" FAIL "QueryExecutionId=$qid だが State=${state:-無し}(期待 SUCCEEDED) StateChangeReason=\"$reason\""
  fi
}

# L12・#270 の N・R 系: 開始できて FAILED になることを確かめる。StateChangeReason・AthenaError（ErrorCategory 固定
# 2・ErrorType・ErrorMessage・Retryable 固定 false）・StatementType 固定 DDL・SubstatementType 固定 CREATE_TABLE が
# 本物の形と一致すること、結果ファイル（本体・.metadata）が MinIO に無いことも見る（create-table-catalog/verify.sh の
# case_fail_at_runtime と同じ確かめ方。#270）。expect_query・expect_database を渡せば GetQueryExecution の Query・
# QueryExecutionContext.Database も確かめる（#271 で 3 部の AwsDataCatalog の 1 部目を落とす形。渡さなければ見ない）。
case_start_failed() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5" expect_reason="$6" expect_error_type="$7"
  local expect_query="${8:-}" expect_database="${9:-}"
  local start qid final ok=1 detail=""
  start=$(start_raw "$sql" "$catalog" "$database")
  qid=$(echo "$start" | jq -r '.QueryExecutionId // empty')
  if [ -z "$qid" ]; then
    record "$no $name" FAIL "開始できなかった: $(echo "$start" | tr -d '\n' | cut -c1-200)"
    return
  fi
  final=$(athena_wait "$qid")
  local state reason category type_ err_message retryable stmt substmt
  state=$(echo "$final" | jq -r '.QueryExecution.Status.State // empty')
  reason=$(echo "$final" | jq -r '.QueryExecution.Status.StateChangeReason // empty')
  category=$(echo "$final" | jq -r '.QueryExecution.Status.AthenaError.ErrorCategory // empty')
  type_=$(echo "$final" | jq -r '.QueryExecution.Status.AthenaError.ErrorType // empty')
  err_message=$(echo "$final" | jq -r '.QueryExecution.Status.AthenaError.ErrorMessage // empty')
  # Retryable は真偽値なので `// empty`（jq は false も偽扱いする）は使えない。null かどうかで分ける。
  retryable=$(echo "$final" | jq -r \
    'if .QueryExecution.Status.AthenaError.Retryable == null then "" else (.QueryExecution.Status.AthenaError.Retryable | tostring) end')
  stmt=$(echo "$final" | jq -r '.QueryExecution.StatementType // empty')
  substmt=$(echo "$final" | jq -r '.QueryExecution.SubstatementType // empty')

  [ "$state" = "FAILED" ] || { ok=0; detail="$detail State=${state:-無し}(期待 FAILED)"; }
  [ "$reason" = "$expect_reason" ] || { ok=0; detail="$detail StateChangeReason=\"$reason\"(期待 \"$expect_reason\")"; }
  [ "$category" = "2" ] || { ok=0; detail="$detail ErrorCategory=${category:-無し}(期待 2)"; }
  [ "$type_" = "$expect_error_type" ] || { ok=0; detail="$detail ErrorType=${type_:-無し}(期待 $expect_error_type)"; }
  [ "$err_message" = "$expect_reason" ] || { ok=0; detail="$detail ErrorMessage=\"$err_message\"(期待 \"$expect_reason\")"; }
  [ "$retryable" = "false" ] || { ok=0; detail="$detail Retryable=${retryable:-無し}(期待 false)"; }
  [ "$stmt" = "DDL" ] || { ok=0; detail="$detail StatementType=${stmt:-無し}(期待 DDL)"; }
  [ "$substmt" = "CREATE_TABLE" ] || { ok=0; detail="$detail SubstatementType=${substmt:-無し}(期待 CREATE_TABLE)"; }

  if [ -n "$expect_query" ]; then
    local query
    query=$(echo "$final" | jq -r '.QueryExecution.Query // empty')
    [ "$query" = "$expect_query" ] || { ok=0; detail="$detail Query=\"$query\"(期待 \"$expect_query\")"; }
  fi
  if [ -n "$expect_database" ]; then
    local db
    db=$(echo "$final" | jq -r '.QueryExecution.QueryExecutionContext.Database // empty')
    [ "$db" = "$expect_database" ] || { ok=0; detail="$detail Database=${db:-無し}(期待 $expect_database)"; }
  fi

  local body_key="${PREFIX}/${qid}.txt" body_stat meta_stat
  body_stat=$(mc_stat "$body_key")
  if mc_exists "$body_stat"; then
    ok=0
    detail="$detail 結果ファイル本体がある(期待は無し): $body_key"
  fi
  meta_stat=$(mc_stat "${body_key}.metadata")
  if mc_exists "$meta_stat"; then
    ok=0
    detail="$detail .metadata がある(期待は無し): ${body_key}.metadata"
  fi

  if [ "$ok" = "1" ]; then
    record "$no $name" PASS "QueryExecutionId=$qid State=$state StateChangeReason=\"$reason\" ErrorType=$type_ 結果ファイル無し"
  else
    record "$no $name" FAIL "${detail# } [id=$qid]"
  fi
}

# --- ケース ---

run_cases() {
  # L1: S3 Tables の Context・LOCATION 付きの Hive の CREATE TABLE（3 部・awsdatacatalog）。
  case_reject "L1" "S3Tables の Context・LOCATION 付き(3 部 awsdatacatalog)" \
    "CREATE TABLE awsdatacatalog.default.t229 (n int) LOCATION 's3://b/p/'" "$S3_TABLES_CATALOG" "$NS" \
    MALFORMED_QUERY "Table location can not be specified for tables hosted in S3 table buckets"

  # L2: 同じ Context・LOCATION 無しの CREATE EXTERNAL TABLE。
  case_reject "L2" "S3Tables の Context・LOCATION 無しの EXTERNAL" \
    "CREATE EXTERNAL TABLE t229 (n int)" "$S3_TABLES_CATALOG" "$NS" \
    MALFORMED_QUERY "External keyword not supported for table type ICEBERG"

  # L3: 同じ Context・Catalog を大文字混じり・小文字の create table / location。
  case_reject "L3" "S3Tables の Context(大文字混じり)・小文字の create/location" \
    "create table t229 (n int) location 's3://b/p/'" "$S3_TABLES_CATALOG_MIXED" "$NS" \
    MALFORMED_QUERY "Table location can not be specified for tables hosted in S3 table buckets"

  # L4: 同じ Context・NOT NULL は測った形にないので Trino の構文チェックに落ちる。
  case_reject "L4" "S3Tables の Context・NOT NULL は構文チェックへ" \
    "CREATE TABLE t229 (n int NOT NULL) LOCATION 's3://b/p/'" "$S3_TABLES_CATALOG" "$NS" \
    MALFORMED_QUERY "line 1:36: mismatched input 'LOCATION'. Expecting: 'COMMENT', 'WITH', <EOF>"

  # L5: 同じ Context・LOCATION より前の TBLPROPERTIES も測った形にないので構文チェックへ。
  case_reject "L5" "S3Tables の Context・LOCATION 前の TBLPROPERTIES は構文チェックへ" \
    "CREATE TABLE t229 (n int) TBLPROPERTIES ('table_type'='ICEBERG') LOCATION 's3://b/p/'" "$S3_TABLES_CATALOG" "$NS" \
    MALFORMED_QUERY "line 1:27: mismatched input 'TBLPROPERTIES'. Expecting: 'COMMENT', 'WITH', <EOF>"

  # L6: 既定の Context では S3 Tables の文言にならず、いつもの Trino の構文チェックの文言のまま。
  case_reject "L6" "既定の Context・LOCATION は S3Tables の文言にならない" \
    "CREATE TABLE t229 (n int) LOCATION 's3://b/p/'" AwsDataCatalog default \
    MALFORMED_QUERY "line 1:27: mismatched input 'LOCATION'. Expecting: 'COMMENT', 'WITH', <EOF>"

  # L7: 既定の Context・EXTERNAL も S3Tables の文言にならない（Trino の普通の構文エラー、部分一致で確認）。
  case_reject_contains "L7" "既定の Context・EXTERNAL は S3Tables の文言にならない" \
    "CREATE EXTERNAL TABLE t229 (n int)" AwsDataCatalog default \
    MALFORMED_QUERY "mismatched input 'EXTERNAL'"

  # L8: S3 Tables の Context でも普通の SELECT は今までどおり実行できる（疎通）。
  case_start_ok "L8" "S3Tables の Context・SELECT 1 は通る" \
    "SELECT 1" "$S3_TABLES_CATALOG" "$NS"

  # L9: 表の COMMENT も Hive の句として読み、LOCATION を弾く（#248）。
  case_reject "L9" "S3Tables の Context・COMMENT 付きの LOCATION" \
    "CREATE TABLE t229 (n int) COMMENT 'c' LOCATION 's3://b/p/'" "$S3_TABLES_CATALOG" "$NS" \
    MALFORMED_QUERY "Table location can not be specified for tables hosted in S3 table buckets"

  # L10: 入れ子の型の列は本物も Trino の形の構文エラー。ローカルの Trino の文言と位置がその形になるか（#248）。
  case_reject "L10" "S3Tables の Context・row 型の列は Trino の構文エラー" \
    "CREATE TABLE t229 (c row(a int)) LOCATION 's3://b/p/'" "$S3_TABLES_CATALOG" "$NS" \
    MALFORMED_QUERY "line 1:34: mismatched input 'LOCATION'. Expecting: 'COMMENT', 'WITH', <EOF>"

  # L11: 既定の Context・実在しないカタログの 3 部 + LOCATION は DATACATALOG_NOT_FOUND（#248）。
  case_reject "L11" "既定の Context・実在しないカタログの LOCATION" \
    "CREATE TABLE nosuchcatalog248.default.t229 (n int) LOCATION 's3://b/p/'" AwsDataCatalog default \
    DATACATALOG_NOT_FOUND "Catalog 'nosuchcatalog248' does not exist"

  # L12: S3 Tables の Context・LOCATION の無い STORED AS は開始して FAILED（#248）。
  case_start_failed "L12" "S3Tables の Context・LOCATION の無い STORED AS" \
    "CREATE TABLE t229 (n int) STORED AS ORC" "$S3_TABLES_CATALOG" "$NS" \
    "Iceberg create table statement does not allow STORED AS/BY" 1200

  # --- #266: LOCATION の無い EXTERNAL・STORED AS の判定の広がり、実在しないカタログの EXTERNAL・
  #     IF NOT EXISTS + STORED AS の 3 部 + LOCATION、変わらない回帰 ---

  # M1: LOCATION の無い EXTERNAL は COMMENT があっても L2 と同じ文言。
  case_reject "M1" "S3Tables の Context・LOCATION 無しの EXTERNAL + COMMENT" \
    "CREATE EXTERNAL TABLE ${T266} (n int) COMMENT 'c'" "$S3_TABLES_CATALOG" "$NS" \
    MALFORMED_QUERY "External keyword not supported for table type ICEBERG"

  # M2: 同じく、バッククォートの名前でも変わらない。
  case_reject "M2" "S3Tables の Context・LOCATION 無しの EXTERNAL・バッククォート" \
    "CREATE EXTERNAL TABLE \`${T266}\` (n int)" "$S3_TABLES_CATALOG" "$NS" \
    MALFORMED_QUERY "External keyword not supported for table type ICEBERG"

  # M3: LOCATION の無い STORED AS は 2 部の名前でも開始して FAILED。
  case_start_failed "M3" "S3Tables の Context・LOCATION 無しの STORED AS・2 部の名前" \
    "CREATE TABLE ${NS}.${T266} (n int) STORED AS PARQUET" "$S3_TABLES_CATALOG" "$NS" \
    "Iceberg create table statement does not allow STORED AS/BY" 1200

  # M4: 同じく、IF NOT EXISTS があっても変わらない。
  case_start_failed "M4" "S3Tables の Context・LOCATION 無しの STORED AS・IF NOT EXISTS" \
    "CREATE TABLE IF NOT EXISTS ${T266} (n int) STORED AS PARQUET" "$S3_TABLES_CATALOG" "$NS" \
    "Iceberg create table statement does not allow STORED AS/BY" 1200

  # M5: 同じく、COMMENT があっても変わらない。
  case_start_failed "M5" "S3Tables の Context・LOCATION 無しの STORED AS・COMMENT" \
    "CREATE TABLE ${T266} (n int) COMMENT 'c' STORED AS PARQUET" "$S3_TABLES_CATALOG" "$NS" \
    "Iceberg create table statement does not allow STORED AS/BY" 1200

  # M6: 同じく、大文字混じりの AwsDataCatalog の 3 部でも変わらない。
  case_start_failed "M6" "S3Tables の Context・LOCATION 無しの STORED AS・AwsDataCatalog の 3 部" \
    "CREATE TABLE AwsDataCatalog.${NS}.${T266} (n int) STORED AS PARQUET" "$S3_TABLES_CATALOG" "$NS" \
    "Iceberg create table statement does not allow STORED AS/BY" 1200

  # M7: 同じく、列リストが無くても変わらない。
  case_start_failed "M7" "S3Tables の Context・LOCATION 無しの STORED AS・列リスト無し" \
    "CREATE TABLE ${T266} STORED AS PARQUET" "$S3_TABLES_CATALOG" "$NS" \
    "Iceberg create table statement does not allow STORED AS/BY" 1200

  # M8: 実在しないカタログの EXTERNAL の 3 部 + LOCATION は既定の Context でも DATACATALOG_NOT_FOUND。
  case_reject "M8" "既定の Context・実在しないカタログの EXTERNAL + LOCATION" \
    "CREATE EXTERNAL TABLE ${NOSUCHCATALOG266}.default.${T266} (n int) LOCATION 's3://b/p/'" AwsDataCatalog default \
    DATACATALOG_NOT_FOUND "Catalog '${NOSUCHCATALOG266}' does not exist"

  # M9: 同じく、S3 Tables の Context でも同じ。
  case_reject "M9" "S3Tables の Context・実在しないカタログの EXTERNAL + LOCATION" \
    "CREATE EXTERNAL TABLE ${NOSUCHCATALOG266}.${NS}.${T266} (n int) LOCATION 's3://b/p/'" "$S3_TABLES_CATALOG" "$NS" \
    DATACATALOG_NOT_FOUND "Catalog '${NOSUCHCATALOG266}' does not exist"

  # M10: 実在しないカタログの 3 部 + LOCATION は、IF NOT EXISTS・STORED AS があっても DATACATALOG_NOT_FOUND が先。
  case_reject "M10" "S3Tables の Context・実在しないカタログの IF NOT EXISTS + STORED AS + LOCATION" \
    "CREATE TABLE IF NOT EXISTS ${NOSUCHCATALOG266}.${NS}.${T266} (n int) STORED AS PARQUET LOCATION 's3://b/p/'" \
    "$S3_TABLES_CATALOG" "$NS" \
    DATACATALOG_NOT_FOUND "Catalog '${NOSUCHCATALOG266}' does not exist"

  # --- #270: LOCATION も EXTERNAL も無い CREATE TABLE の句どうしの優先順（CLUSTERED BY > ROW FORMAT >
  #     STORED AS > 型付き PARTITIONED BY > 未知の TBLPROPERTIES）、3 部の AwsDataCatalog + 句、優先順の対、
  #     ちょうど小文字の 3 部 + STORED AS の 2 catalogs、Iceberg の書き方の回帰 ---

  # N1: ROW FORMAT SERDE 単独は開始して FAILED。
  case_start_failed "N1" "S3Tables の Context・ROW FORMAT SERDE 単独は開始して FAILED" \
    "CREATE TABLE ${T270}row1 (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'" \
    "$S3_TABLES_CATALOG" "$NS" \
    "Iceberg create table statement does not allow ROW FORMAT" 1200

  # N2: 同じく、ROW FORMAT DELIMITED でも変わらない。
  case_start_failed "N2" "S3Tables の Context・ROW FORMAT DELIMITED 単独は開始して FAILED" \
    "CREATE TABLE ${T270}row2 (n int) ROW FORMAT DELIMITED FIELDS TERMINATED BY ','" \
    "$S3_TABLES_CATALOG" "$NS" \
    "Iceberg create table statement does not allow ROW FORMAT" 1200

  # N3: CLUSTERED BY 単独は開始して FAILED。
  case_start_failed "N3" "S3Tables の Context・CLUSTERED BY 単独は開始して FAILED" \
    "CREATE TABLE ${T270}clu (n int) CLUSTERED BY (n) INTO 4 BUCKETS" \
    "$S3_TABLES_CATALOG" "$NS" \
    "Iceberg create table statement does not allow CLUSTERED BY" 1200

  # N4: 型付きの PARTITIONED BY 単独は開始して FAILED。
  case_start_failed "N4" "S3Tables の Context・型付き PARTITIONED BY 単独は開始して FAILED" \
    "CREATE TABLE ${T270}part (n int) PARTITIONED BY (p int)" \
    "$S3_TABLES_CATALOG" "$NS" \
    "Invalid PARTITIONED BY clause in Iceberg create table statement" 1006

  # N5: 未知のキー 1 つの TBLPROPERTIES 単独は開始して FAILED。
  case_start_failed "N5" "S3Tables の Context・未知のキーの TBLPROPERTIES 単独は開始して FAILED" \
    "CREATE TABLE ${T270}prop (n int) TBLPROPERTIES ('a270'='b')" \
    "$S3_TABLES_CATALOG" "$NS" \
    "Unsupported table property key: a270" 1200

  # N6: 列リスト無し + 未知のキーの TBLPROPERTIES だけでも開始して FAILED（列が無いことが未知のキーより先）。
  case_start_failed "N6" "S3Tables の Context・列リスト無し+未知のキーの TBLPROPERTIES は開始して FAILED" \
    "CREATE TABLE ${T270}nocol TBLPROPERTIES ('a270'='b')" \
    "$S3_TABLES_CATALOG" "$NS" \
    "At least one column is required for Iceberg create table statement" 1006

  # N7: 3 部の AwsDataCatalog + ROW FORMAT は N1 と同じ文言。Query は 1 部目を落とした形、Database は
  # 名前空間になる（#271 の挙動が #270 の失敗でも効く）。
  case_start_failed "N7" "S3Tables の Context・AwsDataCatalog の 3 部 + ROW FORMAT は N1 と同じ" \
    "CREATE TABLE AwsDataCatalog.${NS}.${T270}awsdc (n int) ROW FORMAT SERDE 'x'" \
    "$S3_TABLES_CATALOG" "$NS" \
    "Iceberg create table statement does not allow ROW FORMAT" 1200 \
    "CREATE TABLE ${NS}.${T270}awsdc (n int) ROW FORMAT SERDE 'x'" "$NS"

  # N8（優先順の対）: CLUSTERED BY + ROW FORMAT は CLUSTERED BY が先（N3 と同じ）。
  case_start_failed "N8" "S3Tables の Context・CLUSTERED BY+ROW FORMAT は CLUSTERED BY が先" \
    "CREATE TABLE ${T270}pair1 (n int) CLUSTERED BY (n) INTO 4 BUCKETS ROW FORMAT SERDE 'x'" \
    "$S3_TABLES_CATALOG" "$NS" \
    "Iceberg create table statement does not allow CLUSTERED BY" 1200

  # N9（優先順の対）: 型付き PARTITIONED BY + 未知の TBLPROPERTIES は PARTITIONED BY が先（N4 と同じ）。
  case_start_failed "N9" "S3Tables の Context・PARTITIONED BY+未知の TBLPROPERTIES は PARTITIONED BY が先" \
    "CREATE TABLE ${T270}pair2 (n int) PARTITIONED BY (p int) TBLPROPERTIES ('a270'='b')" \
    "$S3_TABLES_CATALOG" "$NS" \
    "Invalid PARTITIONED BY clause in Iceberg create table statement" 1006

  # R1（#270 の範囲。旧: #266 の広がりの外の回帰）: ROW FORMAT + STORED AS は N1 と同じ（ROW FORMAT が
  # STORED AS より先。#270 で Trino の構文エラーから開始後の FAILED に変わる）。
  case_start_failed "R1" "S3Tables の Context・ROW FORMAT+STORED AS は ROW FORMAT が先" \
    "CREATE TABLE ${T266} (n int) ROW FORMAT SERDE 'x' STORED AS TEXTFILE" "$S3_TABLES_CATALOG" "$NS" \
    "Iceberg create table statement does not allow ROW FORMAT" 1200

  # R2（#270 の範囲。旧: #266 の広がりの外の回帰）: CLUSTERED BY + STORED AS は N3 と同じ（CLUSTERED BY が
  # STORED AS より先。同じく #270 で変わる）。
  case_start_failed "R2" "S3Tables の Context・CLUSTERED BY+STORED AS は CLUSTERED BY が先" \
    "CREATE TABLE ${T266} (n int) CLUSTERED BY (n) INTO 4 BUCKETS STORED AS PARQUET" "$S3_TABLES_CATALOG" "$NS" \
    "Iceberg create table statement does not allow CLUSTERED BY" 1200

  # R3（#270 の範囲。旧: #266 の広がりの外の回帰）: ちょうど小文字の awsdatacatalog の 3 部 + STORED AS は
  # 句によらず開始時の 2 catalogs が先（#270 で Trino の構文エラーから開始時の 2 catalogs に変わる）。
  local r3_sql="CREATE TABLE awsdatacatalog.${NS}.${T266} (n int) STORED AS PARQUET"
  case_reject "R3" "S3Tables の Context・ちょうど小文字 awsdatacatalog の 3 部+STORED AS は開始時の 2 catalogs" \
    "$r3_sql" "$S3_TABLES_CATALOG" "$NS" \
    MALFORMED_QUERY "Unsupported ddl with 2 catalogs: $r3_sql"

  # R4（回帰）: 既定の Context・Trino にあるカタログを 1 部目に書いた EXTERNAL は S3 Tables の判定の外。
  # Trino の構文エラーのまま（部分一致で確認。位置情報が先頭に付く。#270 でも変わらない）。
  case_reject_contains "R4" "既定の Context・Trino にあるカタログの EXTERNAL + LOCATION は構文チェックへ（回帰）" \
    "CREATE EXTERNAL TABLE hive.default.${T266} (n int) LOCATION 's3://b/p/'" AwsDataCatalog default \
    MALFORMED_QUERY "mismatched input 'EXTERNAL'"

  # R5（回帰）: Iceberg の書き方の PARTITIONED BY（型の無い列名だけ）は本物は SUCCEEDED だが、athena-local は
  # Athena と Trino の書き方の違いを埋める書き換えをしない方針なので、#270 の後も Trino の構文エラーのまま。
  case_reject "R5" "S3Tables の Context・Iceberg 書き方の PARTITIONED BY は構文チェックへ（回帰）" \
    "CREATE TABLE ${T270}reg1 (n int) PARTITIONED BY (n)" "$S3_TABLES_CATALOG" "$NS" \
    MALFORMED_QUERY "line 1:31: mismatched input 'PARTITIONED'. Expecting: 'COMMENT', 'WITH', <EOF>"

  # R6（回帰）: Iceberg で有効な TBLPROPERTIES（table_type=ICEBERG）も本物は SUCCEEDED だが、同じ理由で
  # #270 の後も Trino の構文エラーのまま。
  case_reject "R6" "S3Tables の Context・Iceberg で有効な TBLPROPERTIES は構文チェックへ（回帰）" \
    "CREATE TABLE ${T270}reg2 (n int) TBLPROPERTIES ('table_type'='ICEBERG')" "$S3_TABLES_CATALOG" "$NS" \
    MALFORMED_QUERY "line 1:31: mismatched input 'TBLPROPERTIES'. Expecting: 'COMMENT', 'WITH', <EOF>"

  # --- #270 のフェーズ 2: TBLPROPERTIES の table_type・compression_level を開始時に弾く、列の並び無し+
  #     型付き PARTITIONED BY・複数の未知のキー・名前空間の無い 2 部+ROW FORMAT を開始して FAILED にする、
  #     Trino に TBLPROPERTIES が無いことによる回帰 ---

  # P1: table_type が ICEBERG 以外の TBLPROPERTIES は開始時に Only ICEBERG で弾く。
  case_reject "P1" "S3Tables の Context・table_type が hive の TBLPROPERTIES" \
    "CREATE TABLE ${T270}ty1 (n int) TBLPROPERTIES ('table_type'='hive')" "$S3_TABLES_CATALOG" "$NS" \
    MALFORMED_QUERY "Only ICEBERG table format is supported with S3 table buckets"

  # P2: 同じく、ROW FORMAT があっても table_type が ICEBERG 以外が先。
  case_reject "P2" "S3Tables の Context・ROW FORMAT+table_type が HIVE の TBLPROPERTIES" \
    "CREATE TABLE ${T270}ty2 (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde' TBLPROPERTIES ('table_type'='HIVE')" \
    "$S3_TABLES_CATALOG" "$NS" \
    MALFORMED_QUERY "Only ICEBERG table format is supported with S3 table buckets"

  # P3: write_compression の無い compression_level は開始時に Compression codec で弾く。
  case_reject "P3" "S3Tables の Context・write_compression 無しの compression_level" \
    "CREATE TABLE ${T270}cl3 (n int) TBLPROPERTIES ('compression_level'='3')" "$S3_TABLES_CATALOG" "$NS" \
    MALFORMED_QUERY "Compression codec must be defined when compression_level property is specified."

  # P4: ちょうど小文字の awsdatacatalog の 3 部 + ROW FORMAT は開始時の 2 catalogs（table_type の判定の対象外）。
  local p4_sql="CREATE TABLE awsdatacatalog.${NS}.${T270}awsdc3 (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'"
  case_reject "P4" "S3Tables の Context・ちょうど小文字 awsdatacatalog の 3 部+ROW FORMAT は開始時の 2 catalogs" \
    "$p4_sql" "$S3_TABLES_CATALOG" "$NS" \
    MALFORMED_QUERY "Unsupported ddl with 2 catalogs: $p4_sql"

  # P5: 列の並びも句も無い CREATE TABLE は開始して FAILED（At least one column）。
  case_start_failed "P5" "S3Tables の Context・列の並びも句も無い CREATE TABLE" \
    "CREATE TABLE ${T270}bare" "$S3_TABLES_CATALOG" "$NS" \
    "At least one column is required for Iceberg create table statement" 1006

  # P6: 列の並びが無くても、型付きの PARTITIONED BY があれば列が無いことより句の判定が先。
  case_start_failed "P6" "S3Tables の Context・列の並び無し+型付き PARTITIONED BY" \
    "CREATE TABLE ${T270}barepart PARTITIONED BY (p int)" "$S3_TABLES_CATALOG" "$NS" \
    "Invalid PARTITIONED BY clause in Iceberg create table statement" 1006

  # P7: 未知のキーが 2 つ以上あれば、書いた順の最初のキーを綴りのまま出す。
  case_start_failed "P7" "S3Tables の Context・未知のキー 2 つの TBLPROPERTIES" \
    "CREATE TABLE ${T270}multi (n int) TBLPROPERTIES ('a270x'='b', 'a270y'='c')" "$S3_TABLES_CATALOG" "$NS" \
    "Unsupported table property key: a270x" 1200

  # P8: 名前空間が無い 2 部の名前でも、ROW FORMAT の判定が名前空間の存在確認より先。
  case_start_failed "P8" "S3Tables の Context・名前空間の無い 2 部+ROW FORMAT は句の判定が先" \
    "CREATE TABLE ${NS_MISSING}.${T270}row4 (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'" \
    "$S3_TABLES_CATALOG" "$NS" \
    "Iceberg create table statement does not allow ROW FORMAT" 1200

  # P9（回帰）: 本物が受理する Iceberg の有効なキー（vacuum_max_snapshot_age_seconds）でも、Trino に
  # TBLPROPERTIES が無いので今までどおり構文エラーのまま。
  case_reject "P9" "S3Tables の Context・Iceberg で有効な vacuum のキーは構文チェックへ（回帰）" \
    "CREATE TABLE ${T270}reg3 (n int) TBLPROPERTIES ('vacuum_max_snapshot_age_seconds'='432000')" \
    "$S3_TABLES_CATALOG" "$NS" \
    MALFORMED_QUERY "line 1:31: mismatched input 'TBLPROPERTIES'. Expecting: 'COMMENT', 'WITH', <EOF>"
}

main() {
  log "作業ディレクトリ: $SCRIPT_DIR"
  log "証跡の保存先: $EVIDENCE_DIR"

  if ! build_athena_local; then
    record "cargo build" FAIL "ビルドが失敗した"
    return 1
  fi
  record "cargo build" PASS "$BINARY を用意した"

  # 前の走行の残骸を持ち越さないよう、使うサービスを作り直す。
  log "docker compose down -v / up -d ${SERVICES[*]}"
  if ! "${COMPOSE[@]}" down -v "${SERVICES[@]}" >/dev/null 2>&1; then
    record "compose起動" FAIL "docker compose down -v ${SERVICES[*]} が失敗した"
    return 1
  fi
  if ! "${COMPOSE[@]}" up -d "${SERVICES[@]}"; then
    record "compose起動" FAIL "docker compose up -d ${SERVICES[*]} が失敗した"
    return 1
  fi

  if ! wait_for_trino; then
    record "Trino起動" FAIL "Trino が起動しなかった"
    return 1
  fi
  record "Trino起動" PASS "$TRINO_BASE で応答"

  if ! mc alias set local http://minio:9000 minioadmin minioadmin >/dev/null; then
    record "MinIOバケット" FAIL "mc alias set が失敗した（minio:9000 に繋がらない）"
    return 1
  fi
  if ! wait_for_bucket; then
    record "MinIOバケット" FAIL "バケット $BUCKET の用意ができなかった"
    return 1
  fi
  record "MinIOバケット" PASS "バケット $BUCKET 用意済み"

  if ! start_athena_local; then
    record "athena-local起動" FAIL "athena-local が起動しなかった"
    return 1
  fi
  record "athena-local起動" PASS "$ATHENA_BASE で応答（TRINO_CATALOG_MAP=${S3_TABLES_CATALOG}=iceberg,AwsDataCatalog=hive、binary=$BINARY）"

  run_cases
}

main
