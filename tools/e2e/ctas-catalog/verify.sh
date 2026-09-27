#!/usr/bin/env bash
# issue #232 の実機検証の足場（tools/e2e/create-table-catalog/verify.sh を雛形にした）。
#
# #232 の変更: S3 Tables の Context（QueryExecutionContext.Catalog が `s3tablescatalog/<バケット>`）の CTAS で、
# 無引用の 3 部の名前の 1 部目が大文字小文字によらず `awsdatacatalog`（`IF NOT EXISTS` も対象。#251 でガードを
# 外した）なら、本物は 2 部目を Glue（AwsDataCatalog）の DB として引いて作った（実測 i12・j13）。athena-local は
# `TRINO_CATALOG_MAP` の `AwsDataCatalog` の Trino 名（既定の compose では `hive`）で
# `SHOW TABLES FROM "hive"."<db>" LIKE ''` を先に確かめ、
#   - DB が無ければ Trino に本体を送らず、開始して FAILED（
#     `Database <小文字にした DB 名> not found. Please check your query. You may need to manually
#     clean the data at location '<OutputLocation>tables/<QueryExecutionId>' before retrying.
#     Athena will not delete data in your account.`、AthenaError ErrorCategory 2・ErrorType 1301・
#     Retryable false）にし、結果ファイル本体は置かないが、問い合わせ部分を Trino で実行して成功した CTAS と同じ形の `.metadata` を置く（#251）。
#   - DB があれば、1 部目を `"hive"` と空白（文字数を揃える）に差し替えた文を Trino に送り、Glue 側
#     （hive カタログ）に表ができる。GetQueryExecution の Query は受け取ったまま。
# #251 で、既定の Context（Catalog が省略か `AwsDataCatalog`）の CTAS `awsdatacatalog.<DB>.<表>` にも同じ
# 判定を広げた。DB が無ければ同じ FAILED（理由の DB 名は小文字）、あれば書き換えずに（1 部目の別名解決は
# #246 の `alias_qualified_names` に任せる）Trino へ送って作る。CTAS でない CREATE TABLE（#237 の挙動）は
# 変わらない。
#
# この足場は compose のローカル Trino に hive（Glue 役）と iceberg（S3 Tables 役）の 2 カタログを持たせ、
# TRINO_CATALOG_MAP=s3tablescatalog/e2e232=iceberg,AwsDataCatalog=hive にして、athena-local の
# StartQueryExecution／GetQueryExecution に次のケース表を流して判定する。本物の AWS には投げない
# （compose の trino・minio だけ）。TRINO_CATALOG=AwsDataCatalog も設定する（C6・C7 の Catalog 省略で、
# athena-local が QueryExecutionContext.Catalog 無しのときに送る既定のカタログが必要なため。docs/configuration.md
# の TRINO_CATALOG）。
#
# ケース表（TRINO_CATALOG_MAP=s3tablescatalog/e2e232=iceberg,AwsDataCatalog=hive）:
#   C1 S3 Tables の Context（Catalog=s3tablescatalog/e2e232、Database=e2e232ns（iceberg に事前に作った名前空間））
#      CREATE TABLE awsdatacatalog.e2e232db.t232 AS SELECT 1 AS n（e2e232db は hive に事前に作った DB）
#      → SUCCEEDED、Query は受け取ったまま、SubstatementType CREATE_TABLE_AS_SELECT、
#        Trino の hive.e2e232db.t232 ができていて 1 行、iceberg.e2e232ns には t232 が無い
#   C2 同じ Context
#      CREATE TABLE AwsDataCatalog.E2e232Missing.t232c2 AS SELECT 1 AS n（hive に無い DB。書いたとおり大文字混じり）
#      → 開始は 200 と QueryExecutionId、最終 FAILED。StateChangeReason・AthenaError が上の文言と一致
#        （理由の DB 名は小文字 `e2e232missing`、場所は `s3://<bucket>/<prefix>/tables/<id>`）、
#        MinIO に本体は無く、`.metadata` は成功した CTAS の形（Trino のクエリ ID・`CREATE TABLE`・件数 1・`rows bigint`。#251）
#   C3（回帰。#237） 同じ Context
#      CREATE TABLE AwsDataCatalog.e2e232ns.t232b (n int)（CTAS でない。e2e232ns は iceberg の名前空間）
#      → SUCCEEDED、iceberg.e2e232ns.t232b ができる（#232 で #237 の挙動が変わっていないことの確認）。
#        Query は 1 部目を落とした `CREATE TABLE e2e232ns.t232b (n int)`（本物どおり。#271）
#   C4（#251） 同じ Context
#      CREATE TABLE IF NOT EXISTS AwsDataCatalog.E2e232Missing.t232c4 AS SELECT 1 AS n（IF NOT EXISTS・hive に無い DB）
#      → C2 と同じ FAILED（IF NOT EXISTS でも同じ）
#   C5（#251） 同じ Context
#      CREATE TABLE IF NOT EXISTS awsdatacatalog.e2e232db.t232c5 AS SELECT 1 AS n（IF NOT EXISTS・hive にある DB）
#      → SUCCEEDED、hive.e2e232db.t232c5 ができる
#   C6（#251） 既定の Context（Catalog 省略、Database=default）
#      CREATE TABLE awsdatacatalog.E2e232Missing.t232c6 AS SELECT 1 AS n（hive に無い DB）
#      → C2 と同じ FAILED（既定の Context でも同じ）
#   C7（#251） 既定の Context（Catalog 省略、Database=default）
#      CREATE TABLE awsdatacatalog.e2e232db.t232c7 AS SELECT 1 AS n（hive にある DB）
#      → SUCCEEDED、hive.e2e232db.t232c7 ができる。Query は受け取ったまま（Rewrite しない。#246 の別名解決任せ）
#   C8（#251） 既定の Context（Catalog=AwsDataCatalog を明示、Database=default）
#      CREATE TABLE awsdatacatalog.E2e232Missing.t232c8 AS SELECT 1 AS n（hive に無い DB）
#      → C2 と同じ FAILED（Catalog を明示しても省略と同じ）
#   C9（#251） 既定の Context（Catalog=AwsDataCatalog を明示、Database=default）
#      CREATE TABLE awsdatacatalog.e2e232db.t232c9 AS SELECT 1 AS n（hive にある DB）
#      → SUCCEEDED、hive.e2e232db.t232c9 ができる
#
# #272 の変更: エンジン（Trino）で失敗した CTAS・INSERT の理由（StateChangeReason・AthenaError.ErrorMessage）の
# 末尾に、本物と同じ接尾辞を Context・名前の形によらず付ける（src/failure.rs の with_ctas_suffix・
# with_insert_suffix）:
#   - CTAS: ` You may need to manually clean the data at location '<OutputLocation>tables/<id>' before
#     retrying. Athena will not delete data in your account.`
#   - INSERT: ` If a data manifest file was generated at '<OutputLocation><id>-manifest.csv', you may need to
#     manually clean the data from locations specified in the manifest. Athena will not delete data in your
#     account.`
# 加えて、既定の Context（Catalog 省略か AwsDataCatalog）の CTAS で名前が 1〜2 部か 1 部目が `awsdatacatalog`
# の類の 3 部（#251 で問い合わせ部分だけを Trino に送る、無い DB への CTAS の経路も含む）、S3 Tables の
# Context で 1 部目が `awsdatacatalog` の類の 3 部（同じ仕組み）のときだけ、Trino が返す `line N:M` を
# 本物が SQL を整形し直した文の位置に直す。ほかの形（S3 Tables の Context の名前空間への 2 部の名前、
# JOIN などを含む問い合わせ、INSERT）は接尾辞だけ付き、位置は送った文のまま（実測・規則は
# .claude/issue-notes/272.md、docs/dev/decisions.md）。
# エンジンの失敗は、#251 の「DB が無い」短絡（C2 など）と違い、結果ファイル本体も `.metadata` も置かれない
# （results.rs の ResultLocation::failed が `<id>.txt` の文にしか Some を返さないのと同じで、CTAS・INSERT は
# 失敗時に何も置かない）。
#
# 追加のセットアップ（C11 以降で使う）: hive.e2e232db に表 t232src (n int, s varchar) を 1 行（1, 'x'）
# 入りで用意する。
#
# ケース表（続き。TRINO_CATALOG_MAP・TRINO_CATALOG は上と同じ）:
#   C10 既定の Context（Catalog 省略）・hive にある DB
#      CREATE TABLE awsdatacatalog.e2e232db.t232c10 AS SELECT * FROM e2e232db.t232c10src（無い表、SELECT * の 1 項目）
#      → FAILED、TABLE_NOT_FOUND（ErrorType 1301）、StateChangeReason が
#        `TABLE_NOT_FOUND: line 6:3: Table 'hive.e2e232db.t232c10src' does not exist. You may need to
#        manually clean the data at location '<OutputLocation>tables/<id>' before retrying. Athena will not
#        delete data in your account.` と一致（本物が整形し直した位置 line 6:3。#272）、結果ファイル本体・
#        .metadata とも無し
#   C11 同じ Context
#      CREATE TABLE awsdatacatalog.e2e232db.t232c11 AS SELECT nosuch272 FROM e2e232db.t232src（無い列、1 項目）
#      → FAILED、COLUMN_NOT_FOUND（ErrorType 1006）、位置 line 4:13 + 接尾辞
#   C12 同じ Context
#      CREATE TABLE awsdatacatalog.e2e232db.t232c12 AS SELECT n, s, nosuch272 FROM e2e232db.t232src（無い列、3 項目）
#      → FAILED、COLUMN_NOT_FOUND、位置 line 7:3 + 接尾辞（項目が複数だと改行して数える）
#   C13 同じ Context
#      CREATE TABLE awsdatacatalog.e2e232db.t232c13 WITH (format = 'PARQUET') AS SELECT * FROM
#      e2e232db.t232c13src（無い表、CTAS の WITH 句 1 つ）
#      → FAILED、TABLE_NOT_FOUND、位置 line 7:3（WITH のプロパティ 1 つで整形後の行が 1 つ増える）+ 接尾辞
#   C14 同じ Context
#      CREATE TABLE awsdatacatalog.e2e232db.t232c14 AS SELECT 1 + 'a' AS n（型の不一致）
#      → FAILED、TYPE_MISMATCH（ErrorType 1002）、位置 line 4:16 + 接尾辞
#   C15 同じ Context
#      CREATE TABLE awsdatacatalog.E2e232Missing.t232c15 AS SELECT * FROM e2e232db.t232c15src（無い DB・
#      無い表。#251 の問い合わせ部分だけを Trino に送る経路）
#      → FAILED、C10 と同じ TABLE_NOT_FOUND・位置 line 6:3 + 接尾辞（DB が無い短絡の「Database ... not
#        found」ではなく、問い合わせ自体の失敗が理由になる）、結果ファイル本体・.metadata とも無し
#   C16 S3 Tables の Context（Catalog=s3tablescatalog/e2e232,Database=e2e232ns）
#      CREATE TABLE e2e232ns.t232c16 AS SELECT * FROM t232c16src（2 部の CTAS・無い表）
#      → FAILED、TABLE_NOT_FOUND + 接尾辞だが、位置は送った文のまま（既定の Context の 1〜3 部の名前の形の
#        外なので直さない）
#   C17 既定の Context（Catalog 省略）
#      INSERT INTO awsdatacatalog.e2e232db.t232src SELECT nosuch272, 'y' FROM awsdatacatalog.e2e232db.t232src
#      （無い列）
#      → FAILED、COLUMN_NOT_FOUND + INSERT の接尾辞（manifest）。位置は送った文のまま（INSERT は整形し
#        直さない）
#   C18（回帰） 同じ Context
#      CREATE TABLE awsdatacatalog.e2e232db.t232c18 AS SELECT a.n FROM e2e232db.t232src a JOIN
#      e2e232db.t232c18joinsrc b ON a.n = b.n（JOIN・無い表）
#      → FAILED、TABLE_NOT_FOUND + 接尾辞だが、位置は送った文のまま（JOIN は整形器の対象の外）
#
# #251 の変更を入れる前にこの足場を流すと（2026-09-27 に確認、PASS=9 FAIL=5）:
#   - FAIL（新しい挙動をまだ実装していないため）: C2（理由の DB 名が大文字混じりのまま・`.metadata` が無い）、
#     C4（IF NOT EXISTS のガードで ctas() 自体が発火せず、Trino の生の `CATALOG_NOT_FOUND` になる）、
#     C5（同じ理由で、あるはずの DB でも Trino に `awsdatacatalog` という名のカタログが無いとして落ちる）、
#     C6・C8（既定の Context では s3_tables のときしか ctas() を呼ばないため、Trino の生の
#     `NOT_FOUND: Schema ... not found`（ErrorType 1000）のまま）
#   - PASS（回帰。#251 の前後で挙動が変わらない）: C1・C3・C7・C9
# 既定の Context で Catalog を省略する C6・C7 は、athena-local に `TRINO_CATALOG=AwsDataCatalog` を設定して
# 初めて Trino に送るカタログが決まる（省略のままだと C6・C7 のどちらも Trino の
# `Schema is set but catalog is not` という無関係な 400 で落ち、CTAS の判定にすら届かない）。
#
# 前提コマンド: tools/dev.sh 経由で動かす（toolbox に全部入っている）
#
# 使い方:
#   tools/dev.sh tools/e2e/ctas-catalog/verify.sh
#
# 環境変数:
#   KEEP_UP=1        テスト後に docker compose down -v をせず環境を残す（デバッグ用）
#   SKIP_BUILD=1     cargo build を省略し、$BINARY（無ければ $CARGO_TARGET_DIR の release/athena-local）をそのまま使う
#   BINARY=<path>    使う athena-local バイナリを差し替える（変更前後の 2 段階の受け入れ用。SKIP_BUILD=1 と組み合わせる）
#
# 後始末は本スクリプトの trap が行う: athena-local を止め、Trino の DB・名前空間・表を DROP で消し
# （KEEP_UP=1 でなければ）docker compose down -v trino minio minio-init する。ほかの docker コンテナや
# compose のサービスは止めたり消したりしない。cargo test も走らせない。
# 終了コードは結果表の FAIL の件数を数え、1 件でもあれば 1。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# cargo の成果物の置き場。tools/dev.sh は CARGO_TARGET_DIR を .toolbox/target にする。BINARY を明示すればそちらを使う
# （変更前のビルドを worktree で作って差し替えるときに使う）。
BINARY="${BINARY:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/athena-local}"
COMPOSE=(docker compose -f "$REPO_ROOT/compose.yml")
SERVICES=(trino minio minio-init)

TRINO_BASE="http://trino:8080"
MINIO_ENDPOINT="http://minio:9000"
BUCKET="athena-results"
PREFIX="e2e232"
OUTPUT_LOCATION="s3://${BUCKET}/${PREFIX}/"

S3_TABLES_CATALOG="s3tablescatalog/e2e232"
CONTEXT_NS="e2e232ns"       # S3 Tables の Context の Database（iceberg に作る名前空間。C1・C2・C3 で共通）
HIVE_DB="e2e232db"          # hive（Glue 役）に事前に作る DB（C1 の 2 部目）
HIVE_DB_MISSING="E2e232Missing" # hive に作らない DB（C2・C4・C6・C8・C15 の 2 部目。大文字混じりのまま送り、理由文言は小文字で確かめる。#251）
HIVE_SRC_TABLE="t232src"    # hive.${HIVE_DB} に事前に作る表（n int, s varchar、1 行。C11・C12・C17・C18 で使う。#272）

ATHENA_BIND="127.0.0.1:8140"
ATHENA_BASE="http://${ATHENA_BIND}"

EVIDENCE_DIR="$(mktemp -d /tmp/athena-local-issue232-e2e.XXXXXX)"
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

  log "Trino の DB・名前空間を消す（無ければ何もしない）"
  trino_exec "DROP SCHEMA IF EXISTS hive.${HIVE_DB} CASCADE" hive default >/dev/null 2>&1 || true
  trino_exec "DROP SCHEMA IF EXISTS iceberg.${CONTEXT_NS} CASCADE" iceberg default >/dev/null 2>&1 || true

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

# --- Trino への直接アクセス（セットアップ・後始末・追加確認専用。測定対象の文は athena-local 経由で投げる） ---

trino_exec() {
  local sql="$1" catalog="$2" schema="$3"
  local resp next
  resp=$(curl -sf -X POST "$TRINO_BASE/v1/statement" \
    -H "X-Trino-User: e2e-232-setup" \
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

# trino_exec と同じだが、行データ（`data` フィールド）を JSON 配列にまとめて返す（表の有無の確認用）。
trino_query_rows() {
  local sql="$1" catalog="$2" schema="$3"
  local resp next rows="[]"
  resp=$(curl -sf -X POST "$TRINO_BASE/v1/statement" \
    -H "X-Trino-User: e2e-232-check" \
    -H "X-Trino-Catalog: $catalog" \
    -H "X-Trino-Schema: $schema" \
    -H "X-Trino-Client-Capabilities: PARAMETRIC_DATETIME" \
    --data-binary "$sql")
  while true; do
    if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
      log "trino_query_rows 失敗: $sql"
      echo "$resp" | jq '.error' >&2
      echo "$rows"
      return 1
    fi
    if echo "$resp" | jq -e '.data' >/dev/null 2>&1; then
      rows=$(jq -c -n --argjson a "$rows" --argjson b "$(echo "$resp" | jq -c '.data')" '$a + $b')
    fi
    next=$(echo "$resp" | jq -r '.nextUri // empty')
    if [ -z "$next" ]; then
      break
    fi
    resp=$(curl -sf "$next")
  done
  echo "$rows"
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
  log "athena-local を起動する（bind=$ATHENA_BIND、binary=$BINARY、TRINO_CATALOG_MAP=${S3_TABLES_CATALOG}=iceberg,AwsDataCatalog=hive、TRINO_CATALOG=AwsDataCatalog、ログ: $ATHENA_LOG）"
  (
    cd "$REPO_ROOT"
    exec env \
      ATHENA_LOCAL_BIND="$ATHENA_BIND" \
      TRINO_URL="$TRINO_BASE" \
      TRINO_USER="athena-local-e2e232" \
      TRINO_CATALOG_MAP="${S3_TABLES_CATALOG}=iceberg,AwsDataCatalog=hive" \
      TRINO_CATALOG="AwsDataCatalog" \
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

# QueryExecutionContext（Catalog・Database）付きの StartQueryExecution。catalog に空文字を渡すと
# QueryExecutionContext.Catalog そのものを省略する（C6・C7 の「既定の Context（Catalog 省略）」用）。
start_raw() {
  local sql="$1" catalog="$2" database="$3"
  local body
  if [ -z "$catalog" ]; then
    body=$(jq -cn --arg sql "$sql" --arg db "$database" --arg token "$(uuidgen)" \
      '{QueryString: $sql, QueryExecutionContext: {Database: $db}, ClientRequestToken: $token}')
  else
    body=$(jq -cn --arg sql "$sql" --arg catalog "$catalog" --arg db "$database" --arg token "$(uuidgen)" \
      '{QueryString: $sql, QueryExecutionContext: {Catalog: $catalog, Database: $db}, ClientRequestToken: $token}')
  fi
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

# StartQueryExecution → 終端状態まで待ち、LAST_ID・LAST_RESP に結果を残す。開始できなければ
# LAST_ID を空のままにし、LAST_START に生の応答を残して 1 を返す。
LAST_ID=""
LAST_RESP=""
LAST_START=""

run_and_wait() {
  local sql="$1" catalog="$2" database="$3"
  local start
  start=$(start_raw "$sql" "$catalog" "$database")
  LAST_ID=$(echo "$start" | jq -r '.QueryExecutionId // empty')
  if [ -z "$LAST_ID" ]; then
    LAST_START="$start"
    LAST_RESP=""
    return 1
  fi
  LAST_START=""
  LAST_RESP=$(athena_wait "$LAST_ID")
  return 0
}

# --- S3（MinIO）側の確認（toolbox の mc で minio:9000 を直接見る。#129） ---

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

# C1・C3: SUCCEEDED になり、Query を受け取ったまま（13 番目の引数があればその文）返し、指定の SubstatementType になり、
# 期待のカタログ・スキーマに表ができ、もう一方のカタログ・スキーマには表が無いことを確かめる。
case_success() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5" expect_substmt="$6"
  local expect_catalog="$7" expect_schema="$8" expect_table="$9"
  local other_catalog="${10}" other_schema="${11}" other_table="${12}" expect_query="${13:-$3}"
  if ! run_and_wait "$sql" "$catalog" "$database"; then
    record "$no $name" FAIL "開始できなかった: $(echo "$LAST_START" | tr -d '\n' | cut -c1-200)"
    return
  fi
  local state query substmt ok=1 detail=""
  state=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.State // empty')
  query=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Query // empty')
  substmt=$(echo "$LAST_RESP" | jq -r '.QueryExecution.SubstatementType // empty')
  [ "$state" = "SUCCEEDED" ] || {
    local reason
    reason=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.StateChangeReason // empty')
    ok=0; detail="$detail State=${state:-無し}(期待 SUCCEEDED) StateChangeReason=\"$reason\""
  }
  [ "$query" = "$expect_query" ] || { ok=0; detail="$detail Query=\"$query\"(期待 \"$expect_query\")"; }
  [ "$substmt" = "$expect_substmt" ] || { ok=0; detail="$detail SubstatementType=${substmt:-無し}(期待 $expect_substmt)"; }

  local rows
  rows=$(trino_query_rows "SELECT table_name FROM system.jdbc.tables WHERE table_cat = '${expect_catalog}' AND table_schem = '${expect_schema}' AND table_name = '${expect_table}'" system jdbc)
  if [ "$(echo "$rows" | jq 'length')" != "1" ]; then
    ok=0
    detail="$detail 表ができていない(期待 ${expect_catalog}.${expect_schema}.${expect_table}): rows=$rows"
  fi
  if [ -n "$other_catalog" ]; then
    rows=$(trino_query_rows "SELECT table_name FROM system.jdbc.tables WHERE table_cat = '${other_catalog}' AND table_schem = '${other_schema}' AND table_name = '${other_table}'" system jdbc)
    if [ "$(echo "$rows" | jq 'length')" != "0" ]; then
      ok=0
      detail="$detail 反対側にも表ができている(期待は無し) ${other_catalog}.${other_schema}.${other_table}: rows=$rows"
    fi
  fi

  if [ "$ok" = "1" ]; then
    record "$no $name" PASS "State=$state SubstatementType=$substmt Query 一致 表=${expect_catalog}.${expect_schema}.${expect_table} [id=$LAST_ID]"
  else
    record "$no $name" FAIL "${detail# } [id=$LAST_ID]"
  fi
}

# C2・C4・C6・C8: 開始できて最終的に FAILED になることを確かめる。理由・AthenaError・Query・
# SubstatementType に加え、結果ファイル本体が MinIO に無く `.metadata` は CTAS の形であることも見る（#251。`.metadata` の
# 中身の検証はフェーズ 2）。missing_db は書いたとおりの綴り（大文字混じり）で渡し、理由文言では小文字にする。
case_fail_at_runtime() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5" missing_db="$6"
  if ! run_and_wait "$sql" "$catalog" "$database"; then
    record "$no $name" FAIL "開始できなかった: $(echo "$LAST_START" | tr -d '\n' | cut -c1-200)"
    return
  fi
  local state reason category type_ retryable query substmt ok=1 detail=""
  state=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.State // empty')
  reason=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.StateChangeReason // empty')
  category=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.AthenaError.ErrorCategory // empty')
  type_=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.AthenaError.ErrorType // empty')
  # Retryable は真偽値なので `// empty`（jq は false も偽扱いする）は使えない。null かどうかで分ける。
  retryable=$(echo "$LAST_RESP" | jq -r \
    'if .QueryExecution.Status.AthenaError.Retryable == null then "" else (.QueryExecution.Status.AthenaError.Retryable | tostring) end')
  query=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Query // empty')
  substmt=$(echo "$LAST_RESP" | jq -r '.QueryExecution.SubstatementType // empty')

  local expect_reason="Database ${missing_db,,} not found. Please check your query. You may need to manually clean the data at location '${OUTPUT_LOCATION}tables/${LAST_ID}' before retrying. Athena will not delete data in your account."

  [ "$state" = "FAILED" ] || { ok=0; detail="$detail State=${state:-無し}(期待 FAILED)"; }
  [ "$reason" = "$expect_reason" ] || { ok=0; detail="$detail StateChangeReason=\"$reason\"(期待 \"$expect_reason\")"; }
  [ "$category" = "2" ] || { ok=0; detail="$detail ErrorCategory=${category:-無し}(期待 2)"; }
  [ "$type_" = "1301" ] || { ok=0; detail="$detail ErrorType=${type_:-無し}(期待 1301)"; }
  [ "$retryable" = "false" ] || { ok=0; detail="$detail Retryable=${retryable:-無し}(期待 false)"; }
  [ "$query" = "$sql" ] || { ok=0; detail="$detail Query=\"$query\"(期待 受け取ったまま)"; }
  [ "$substmt" = "CREATE_TABLE_AS_SELECT" ] || { ok=0; detail="$detail SubstatementType=${substmt:-無し}(期待 CREATE_TABLE_AS_SELECT)"; }

  local body_key="${PREFIX}/tables/${LAST_ID}" body_stat meta_stat
  body_stat=$(mc_stat "$body_key")
  if mc_exists "$body_stat"; then
    ok=0
    detail="$detail 結果ファイル本体がある(期待は無し): $body_key"
  fi
  meta_stat=$(mc_stat "${body_key}.metadata")
  if ! mc_exists "$meta_stat"; then
    ok=0
    detail="$detail .metadata が無い(期待はある。#251): ${body_key}.metadata"
  else
    # 中身は成功した CTAS と同じ形（本物は 81 バイト。2026-09-27 実測 r4）: field 1 に問い合わせ部分を投げた Trino の
    # クエリ ID（27 バイト）、field 2 に `CREATE TABLE`、field 3 に件数 1（`SELECT 1 AS n` の 1 行）、列 `rows bigint`。
    local meta_hex id_hex column_hex
    meta_hex=$(mc cat "local/$BUCKET/${body_key}.metadata" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    # クエリ ID は `yyyymmdd_hhmmss_nnnnn_xxxxx` の 27 文字（数字・`_`・英小文字）。
    id_hex='((3[0-9]|5f|6[1-9a-f]|7[0-9a])){27}'
    column_hex='22220a04686976652204726f77732a04726f77733206626967696e743813400048035000'
    if ! [[ "$meta_hex" =~ ^0a1b${id_hex}120c435245415445205441424c451801${column_hex}$ ]]; then
      ok=0
      detail="$detail .metadata の中身が CTAS の形（Trino のクエリ ID・CREATE TABLE・件数 1・rows bigint）でない: $meta_hex"
    fi
  fi

  if [ "$ok" = "1" ]; then
    record "$no $name" PASS "State=$state StateChangeReason 一致 ErrorCategory=$category ErrorType=$type_ Retryable=$retryable Query 一致 SubstatementType=$substmt 結果ファイル本体無し .metadata は CTAS の形（件数 1） [id=$LAST_ID]"
  else
    record "$no $name" FAIL "${detail# } [id=$LAST_ID]"
  fi
}

# #272: `line N:M` の期待位置を、pos_spec から求める。`fixed:<line>:<col>` は本物が SQL を整形し直した
# あとの位置（実測済みの定数）をそのまま使う。`auto:<検索語>` は送った文のまま（位置を直さない形）で、
# $sql の中でその検索語が最初に現れるバイト位置（1 始まり）を桁、行は 1 に固定して使う（この足場の
# 位置を確かめるケースはすべて 1 行で送るので十分）。
resolve_pos() {
  local sql="$1" spec="$2"
  case "$spec" in
    fixed:*)
      echo "${spec#fixed:}"
      ;;
    auto:*)
      local term="${spec#auto:}" col
      col=$(awk -v s="$sql" -v t="$term" 'BEGIN{print index(s,t)}')
      echo "1:${col}"
      ;;
    *)
      echo "0:0"
      ;;
  esac
}

# C10〜C16・C18（#272）: CTAS がエンジン（Trino）で失敗したときの判定。StateChangeReason が
# 「本物のエラー本文（body_template の `<POS>` を resolve_pos で解決した `line:col` に差し替えたもの）+ 接尾辞」
# と一致し、ErrorCategory・ErrorType・Retryable・Query・SubstatementType に加え、結果ファイル本体・.metadata の
# どちらも無い（普通のエンジンの失敗は成功時と違って何も置かない。results.rs の ResultLocation::failed）ことを
# 確かめる。
case_fail_ctas_engine() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5" pos_spec="$6" body_template="$7" expect_type="$8"
  if ! run_and_wait "$sql" "$catalog" "$database"; then
    record "$no $name" FAIL "開始できなかった: $(echo "$LAST_START" | tr -d '\n' | cut -c1-200)"
    return
  fi
  local state reason category type_ retryable query substmt ok=1 detail=""
  state=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.State // empty')
  reason=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.StateChangeReason // empty')
  category=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.AthenaError.ErrorCategory // empty')
  type_=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.AthenaError.ErrorType // empty')
  retryable=$(echo "$LAST_RESP" | jq -r \
    'if .QueryExecution.Status.AthenaError.Retryable == null then "" else (.QueryExecution.Status.AthenaError.Retryable | tostring) end')
  query=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Query // empty')
  substmt=$(echo "$LAST_RESP" | jq -r '.QueryExecution.SubstatementType // empty')

  local pos body_message suffix expect_reason
  pos=$(resolve_pos "$sql" "$pos_spec")
  body_message="${body_template/<POS>/$pos}"
  suffix="You may need to manually clean the data at location '${OUTPUT_LOCATION}tables/${LAST_ID}' before retrying. Athena will not delete data in your account."
  expect_reason="${body_message}. ${suffix}"

  [ "$state" = "FAILED" ] || { ok=0; detail="$detail State=${state:-無し}(期待 FAILED)"; }
  [ "$reason" = "$expect_reason" ] || { ok=0; detail="$detail StateChangeReason=\"$reason\"(期待 \"$expect_reason\")"; }
  [ "$category" = "2" ] || { ok=0; detail="$detail ErrorCategory=${category:-無し}(期待 2)"; }
  [ "$type_" = "$expect_type" ] || { ok=0; detail="$detail ErrorType=${type_:-無し}(期待 $expect_type)"; }
  [ "$retryable" = "false" ] || { ok=0; detail="$detail Retryable=${retryable:-無し}(期待 false)"; }
  [ "$query" = "$sql" ] || { ok=0; detail="$detail Query=\"$query\"(期待 受け取ったまま)"; }
  [ "$substmt" = "CREATE_TABLE_AS_SELECT" ] || { ok=0; detail="$detail SubstatementType=${substmt:-無し}(期待 CREATE_TABLE_AS_SELECT)"; }

  local body_key="${PREFIX}/tables/${LAST_ID}" body_stat meta_stat
  body_stat=$(mc_stat "$body_key")
  if mc_exists "$body_stat"; then
    ok=0
    detail="$detail 結果ファイル本体がある(期待は無し): $body_key"
  fi
  meta_stat=$(mc_stat "${body_key}.metadata")
  if mc_exists "$meta_stat"; then
    ok=0
    detail="$detail .metadata がある(期待は無し。普通のエンジンの失敗は何も置かない): ${body_key}.metadata"
  fi

  if [ "$ok" = "1" ]; then
    record "$no $name" PASS "State=$state StateChangeReason 一致 ErrorCategory=$category ErrorType=$type_ Retryable=$retryable Query 一致 SubstatementType=$substmt 結果ファイル無し [id=$LAST_ID]"
  else
    record "$no $name" FAIL "${detail# } [id=$LAST_ID]"
  fi
}

# C17（#272）: INSERT がエンジン（Trino）で失敗したときの判定。case_fail_ctas_engine と同じ考え方だが、
# 接尾辞が INSERT の manifest の文言、結果ファイルのキーが `<id>`（`tables/` の下ではない）、
# StatementType が DML（SubstatementType は無い）になる。
case_fail_insert_engine() {
  local no="$1" name="$2" sql="$3" catalog="$4" database="$5" pos_spec="$6" body_template="$7" expect_type="$8"
  if ! run_and_wait "$sql" "$catalog" "$database"; then
    record "$no $name" FAIL "開始できなかった: $(echo "$LAST_START" | tr -d '\n' | cut -c1-200)"
    return
  fi
  local state reason category type_ retryable query stmt ok=1 detail=""
  state=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.State // empty')
  reason=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.StateChangeReason // empty')
  category=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.AthenaError.ErrorCategory // empty')
  type_=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Status.AthenaError.ErrorType // empty')
  retryable=$(echo "$LAST_RESP" | jq -r \
    'if .QueryExecution.Status.AthenaError.Retryable == null then "" else (.QueryExecution.Status.AthenaError.Retryable | tostring) end')
  query=$(echo "$LAST_RESP" | jq -r '.QueryExecution.Query // empty')
  stmt=$(echo "$LAST_RESP" | jq -r '.QueryExecution.StatementType // empty')

  local pos body_message suffix expect_reason
  pos=$(resolve_pos "$sql" "$pos_spec")
  body_message="${body_template/<POS>/$pos}"
  suffix="If a data manifest file was generated at '${OUTPUT_LOCATION}${LAST_ID}-manifest.csv', you may need to manually clean the data from locations specified in the manifest. Athena will not delete data in your account."
  expect_reason="${body_message}. ${suffix}"

  [ "$state" = "FAILED" ] || { ok=0; detail="$detail State=${state:-無し}(期待 FAILED)"; }
  [ "$reason" = "$expect_reason" ] || { ok=0; detail="$detail StateChangeReason=\"$reason\"(期待 \"$expect_reason\")"; }
  [ "$category" = "2" ] || { ok=0; detail="$detail ErrorCategory=${category:-無し}(期待 2)"; }
  [ "$type_" = "$expect_type" ] || { ok=0; detail="$detail ErrorType=${type_:-無し}(期待 $expect_type)"; }
  [ "$retryable" = "false" ] || { ok=0; detail="$detail Retryable=${retryable:-無し}(期待 false)"; }
  [ "$query" = "$sql" ] || { ok=0; detail="$detail Query=\"$query\"(期待 受け取ったまま)"; }
  [ "$stmt" = "DML" ] || { ok=0; detail="$detail StatementType=${stmt:-無し}(期待 DML)"; }

  local body_key="${PREFIX}/${LAST_ID}" body_stat meta_stat
  body_stat=$(mc_stat "$body_key")
  if mc_exists "$body_stat"; then
    ok=0
    detail="$detail 結果ファイルがある(期待は無し): $body_key"
  fi
  meta_stat=$(mc_stat "${body_key}.metadata")
  if mc_exists "$meta_stat"; then
    ok=0
    detail="$detail .metadata がある(期待は無し): ${body_key}.metadata"
  fi

  if [ "$ok" = "1" ]; then
    record "$no $name" PASS "State=$state StateChangeReason 一致 ErrorCategory=$category ErrorType=$type_ Retryable=$retryable Query 一致 StatementType=$stmt 結果ファイル無し [id=$LAST_ID]"
  else
    record "$no $name" FAIL "${detail# } [id=$LAST_ID]"
  fi
}

# --- ケース ---

run_cases() {
  # C1: 1 部目 awsdatacatalog・2 部目 hive に実在する DB。差し替えて送り、hive 側に表ができる。
  case_success "C1" "S3Tables の Context・CTAS・hive の DB あり" \
    "CREATE TABLE awsdatacatalog.${HIVE_DB}.t232 AS SELECT 1 AS n" "$S3_TABLES_CATALOG" "$CONTEXT_NS" \
    "CREATE_TABLE_AS_SELECT" \
    hive "$HIVE_DB" t232 \
    iceberg "$CONTEXT_NS" t232

  # C2: 1 部目 AwsDataCatalog・2 部目 hive に無い DB。Trino に送らず FAILED（#251: 理由の DB 名は小文字、
  # .metadata はある）。
  case_fail_at_runtime "C2" "S3Tables の Context・CTAS・hive の DB 無し" \
    "CREATE TABLE AwsDataCatalog.${HIVE_DB_MISSING}.t232c2 AS SELECT 1 AS n" "$S3_TABLES_CATALOG" "$CONTEXT_NS" \
    "$HIVE_DB_MISSING"

  # C3（回帰）: CTAS でない CREATE TABLE。#237 どおり iceberg 側の名前空間にできる。
  case_success "C3" "S3Tables の Context・CTAS でない CREATE TABLE(回帰 #237)" \
    "CREATE TABLE AwsDataCatalog.${CONTEXT_NS}.t232b (n int)" "$S3_TABLES_CATALOG" "$CONTEXT_NS" \
    "CREATE_TABLE" \
    iceberg "$CONTEXT_NS" t232b \
    "" "" "" \
    "CREATE TABLE ${CONTEXT_NS}.t232b (n int)"

  # C4（#251）: C2 と同じだが IF NOT EXISTS 付き。C2 と同じ FAILED になる想定。
  case_fail_at_runtime "C4" "S3Tables の Context・IF NOT EXISTS の CTAS・hive の DB 無し" \
    "CREATE TABLE IF NOT EXISTS AwsDataCatalog.${HIVE_DB_MISSING}.t232c4 AS SELECT 1 AS n" "$S3_TABLES_CATALOG" "$CONTEXT_NS" \
    "$HIVE_DB_MISSING"

  # C5（#251）: IF NOT EXISTS・hive にある DB。今は if_follows のガードで Continue になり Trino に素通しされる
  # ため元から SUCCEEDED のはずだが、#251 でガードを外しても同じ結果になることの確認（回帰）。
  case_success "C5" "S3Tables の Context・IF NOT EXISTS の CTAS・hive の DB あり" \
    "CREATE TABLE IF NOT EXISTS awsdatacatalog.${HIVE_DB}.t232c5 AS SELECT 1 AS n" "$S3_TABLES_CATALOG" "$CONTEXT_NS" \
    "CREATE_TABLE_AS_SELECT" \
    hive "$HIVE_DB" t232c5 \
    "" "" ""

  # C6（#251）: 既定の Context（Catalog 省略）・hive に無い DB。今は Trino にそのまま送られ、Trino の生の
  # `NOT_FOUND: Schema ... not found`（ErrorType 1000）になるので FAILED にはなるが、文言・ErrorType が
  # 一致せず FAIL になる想定。
  case_fail_at_runtime "C6" "既定Context(Catalog省略)・CTAS・hive の DB 無し" \
    "CREATE TABLE awsdatacatalog.${HIVE_DB_MISSING}.t232c6 AS SELECT 1 AS n" "" default \
    "$HIVE_DB_MISSING"

  # C7（#251。回帰）: 既定の Context（Catalog 省略）・hive にある DB。TRINO_CATALOG=AwsDataCatalog があるので
  # Trino に送るカタログが決まり、#246 の alias_qualified_names が 1 部目を hive に差し替えて送る。#251 の
  # 前後どちらでも SUCCEEDED のはず。Query は受け取ったまま。
  case_success "C7" "既定Context(Catalog省略)・CTAS・hive の DB あり" \
    "CREATE TABLE awsdatacatalog.${HIVE_DB}.t232c7 AS SELECT 1 AS n" "" default \
    "CREATE_TABLE_AS_SELECT" \
    hive "$HIVE_DB" t232c7 \
    "" "" ""

  # C8（#251）: 既定の Context を Catalog=AwsDataCatalog で明示・hive に無い DB。C6 と同じ想定。
  case_fail_at_runtime "C8" "既定Context(Catalog=AwsDataCatalog明示)・CTAS・hive の DB 無し" \
    "CREATE TABLE awsdatacatalog.${HIVE_DB_MISSING}.t232c8 AS SELECT 1 AS n" AwsDataCatalog default \
    "$HIVE_DB_MISSING"

  # C9（#251。回帰）: 既定の Context を Catalog=AwsDataCatalog で明示・hive にある DB。C7 と同じ想定。
  case_success "C9" "既定Context(Catalog=AwsDataCatalog明示)・CTAS・hive の DB あり" \
    "CREATE TABLE awsdatacatalog.${HIVE_DB}.t232c9 AS SELECT 1 AS n" AwsDataCatalog default \
    "CREATE_TABLE_AS_SELECT" \
    hive "$HIVE_DB" t232c9 \
    "" "" ""

  # C10（#272）: 既定の Context（Catalog 省略）・hive にある DB。CTAS のエンジンの失敗（無い表、SELECT * の
  # 1 項目）。本物が整形し直した位置 line 6:3 + CTAS の接尾辞。
  case_fail_ctas_engine "C10" "既定Context(Catalog省略)・CTASのエンジン失敗(無い表・SELECT *)" \
    "CREATE TABLE awsdatacatalog.${HIVE_DB}.t232c10 AS SELECT * FROM ${HIVE_DB}.t232c10src" "" default \
    "fixed:6:3" \
    "TABLE_NOT_FOUND: line <POS>: Table 'hive.${HIVE_DB}.t232c10src' does not exist" \
    1301

  # C11（#272）: 同じ Context。無い列（1 項目）。位置 line 4:13 + 接尾辞。
  case_fail_ctas_engine "C11" "既定Context(Catalog省略)・CTASのエンジン失敗(無い列・1項目)" \
    "CREATE TABLE awsdatacatalog.${HIVE_DB}.t232c11 AS SELECT nosuch272 FROM ${HIVE_DB}.${HIVE_SRC_TABLE}" "" default \
    "fixed:4:13" \
    "COLUMN_NOT_FOUND: line <POS>: Column 'nosuch272' cannot be resolved" \
    1006

  # C12（#272）: 同じ Context。無い列（3 項目。改行して数える）。位置 line 7:3 + 接尾辞。
  case_fail_ctas_engine "C12" "既定Context(Catalog省略)・CTASのエンジン失敗(無い列・3項目)" \
    "CREATE TABLE awsdatacatalog.${HIVE_DB}.t232c12 AS SELECT n, s, nosuch272 FROM ${HIVE_DB}.${HIVE_SRC_TABLE}" "" default \
    "fixed:7:3" \
    "COLUMN_NOT_FOUND: line <POS>: Column 'nosuch272' cannot be resolved" \
    1006

  # C13（#272）: 同じ Context。CTAS の WITH 句 1 つ・無い表。WITH のプロパティで整形後の行が 1 つ増え、
  # 位置は line 7:3 + 接尾辞。
  case_fail_ctas_engine "C13" "既定Context(Catalog省略)・CTASのエンジン失敗(WITH句・無い表)" \
    "CREATE TABLE awsdatacatalog.${HIVE_DB}.t232c13 WITH (format = 'PARQUET') AS SELECT * FROM ${HIVE_DB}.t232c13src" "" default \
    "fixed:7:3" \
    "TABLE_NOT_FOUND: line <POS>: Table 'hive.${HIVE_DB}.t232c13src' does not exist" \
    1301

  # C14（#272）: 同じ Context。型の不一致（1 + 'a'）。位置 line 4:16 + 接尾辞。
  case_fail_ctas_engine "C14" "既定Context(Catalog省略)・CTASのエンジン失敗(型の不一致)" \
    "CREATE TABLE awsdatacatalog.${HIVE_DB}.t232c14 AS SELECT 1 + 'a' AS n" "" default \
    "fixed:4:16" \
    "TYPE_MISMATCH: line <POS>: Cannot apply operator: integer + varchar(1)" \
    1002

  # C15（#272）: 同じ Context。無い DB・無い表（#251 の問い合わせ部分だけを Trino に送る経路）。C10 と同じ
  # TABLE_NOT_FOUND・位置 line 6:3 + 接尾辞になる（「Database ... not found」ではなく問い合わせ自体の失敗が
  # 理由になる）。
  case_fail_ctas_engine "C15" "既定Context(Catalog省略)・無いDB・問い合わせも失敗" \
    "CREATE TABLE awsdatacatalog.${HIVE_DB_MISSING}.t232c15 AS SELECT * FROM ${HIVE_DB}.t232c15src" "" default \
    "fixed:6:3" \
    "TABLE_NOT_FOUND: line <POS>: Table 'hive.${HIVE_DB}.t232c15src' does not exist" \
    1301

  # C16（#272）: S3 Tables の Context・2 部の CTAS（名前空間を明示）・無い表。接尾辞は付くが、既定の
  # Context の 1〜3 部の名前の形の外なので位置は送った文のまま。
  case_fail_ctas_engine "C16" "S3Tablesの Context・2部のCTAS・無い表(位置は送った文のまま)" \
    "CREATE TABLE ${CONTEXT_NS}.t232c16 AS SELECT * FROM t232c16src" "$S3_TABLES_CATALOG" "$CONTEXT_NS" \
    "auto:t232c16src" \
    "TABLE_NOT_FOUND: line <POS>: Table 'iceberg.${CONTEXT_NS}.t232c16src' does not exist" \
    1301

  # C17（#272）: 既定の Context。INSERT が無い列で失敗。接尾辞は INSERT の manifest の文言、位置は送った
  # 文のまま（INSERT は整形し直さない）。
  case_fail_insert_engine "C17" "既定Context(Catalog省略)・INSERTのエンジン失敗(無い列)" \
    "INSERT INTO awsdatacatalog.${HIVE_DB}.${HIVE_SRC_TABLE} SELECT nosuch272, 'y' FROM awsdatacatalog.${HIVE_DB}.${HIVE_SRC_TABLE}" "" default \
    "auto:nosuch272" \
    "COLUMN_NOT_FOUND: line <POS>: Column 'nosuch272' cannot be resolved" \
    1006

  # C18（#272。回帰）: 同じ Context。JOIN で無い表を読む CTAS。接尾辞は付くが、JOIN は整形器の対象の外
  # なので位置は送った文のまま。
  case_fail_ctas_engine "C18" "既定Context(Catalog省略)・CTASのエンジン失敗(JOIN・位置は送った文のまま)" \
    "CREATE TABLE awsdatacatalog.${HIVE_DB}.t232c18 AS SELECT a.n FROM ${HIVE_DB}.${HIVE_SRC_TABLE} a JOIN ${HIVE_DB}.t232c18joinsrc b ON a.n = b.n" "" default \
    "auto:${HIVE_DB}.t232c18joinsrc" \
    "TABLE_NOT_FOUND: line <POS>: Table 'hive.${HIVE_DB}.t232c18joinsrc' does not exist" \
    1301
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

  log "hive に DB $HIVE_DB、iceberg に名前空間 $CONTEXT_NS を用意する（$HIVE_DB_MISSING は作らない）"
  if ! trino_exec "CREATE SCHEMA IF NOT EXISTS hive.${HIVE_DB}" hive default; then
    record "セットアップ(hive DB)" FAIL "hive.${HIVE_DB} の作成に失敗した"
    return 1
  fi
  if ! trino_exec "CREATE SCHEMA IF NOT EXISTS iceberg.${CONTEXT_NS}" iceberg default; then
    record "セットアップ(iceberg 名前空間)" FAIL "iceberg.${CONTEXT_NS} の作成に失敗した"
    return 1
  fi
  # #272: C11・C12・C17・C18 が読む表（n int, s varchar、1 行）。
  if ! trino_exec "CREATE TABLE hive.${HIVE_DB}.${HIVE_SRC_TABLE} AS SELECT 1 AS n, 'x' AS s" hive default; then
    record "セットアップ(表)" FAIL "hive.${HIVE_DB}.${HIVE_SRC_TABLE} の作成に失敗した"
    return 1
  fi
  record "セットアップ(DB・名前空間・表)" PASS "hive.${HIVE_DB}・iceberg.${CONTEXT_NS}・hive.${HIVE_DB}.${HIVE_SRC_TABLE} 作成済み（${HIVE_DB_MISSING} は未作成のまま）"

  if ! start_athena_local; then
    record "athena-local起動" FAIL "athena-local が起動しなかった"
    return 1
  fi
  record "athena-local起動" PASS "$ATHENA_BASE で応答（TRINO_CATALOG_MAP=${S3_TABLES_CATALOG}=iceberg,AwsDataCatalog=hive、binary=$BINARY）"

  run_cases
}

main
