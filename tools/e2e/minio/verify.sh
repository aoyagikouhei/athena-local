#!/usr/bin/env bash
# issue #39 で作成（tools/ へ移す前の名前は 39-e2e/verify.sh）
# issue #39 Step 9（実機検証）: 本物の Trino（trinodb/trino:482）と本物の S3 互換ストレージ
# （MinIO）を相手に athena-local を動かし、DROP TABLE の結果ファイルがテーブルの形式
# （Hive / Iceberg）で変わることを実際に確かめる。
#
# 前提コマンド: tools/dev.sh 経由で動かす（toolbox に全部入っている）
# 環境はルートの compose.yml の trino / minio / minio-init。開始時に down -v → up -d で作り直す。
# S3（MinIO）側の確認は、toolbox の mc で minio:9000 を直接見る（#129）。
#
# 使い方:
#   tools/dev.sh tools/e2e/minio/verify.sh
#
# 環境変数:
#   KEEP_UP=1        テスト後に docker compose down -v <サービス...> をせず環境を残す（デバッグ用）
#   SKIP_BUILD=1     cargo build を省略し、既存の $CARGO_TARGET_DIR（tools/dev.sh では .toolbox/target）の release/athena-local をそのまま使う
#
# 後始末は本スクリプトの trap が行う（KEEP_UP=1 でなければ必ず使ったサービスだけ docker compose down -v する。dev は残す）。
# 終了コードは結果表の FAIL の件数（issue #111。SKIP と INFO は数えない。起動の失敗などで途中で止まったときは 1）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# cargo の成果物の置き場。tools/dev.sh は CARGO_TARGET_DIR を .toolbox/target にする
BINARY="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/athena-local"
COMPOSE=(docker compose -f "$REPO_ROOT/compose.yml")
SERVICES=(trino minio minio-init)

TRINO_BASE="http://trino:8080"
MINIO_ENDPOINT="http://minio:9000"
ATHENA_BASE="http://127.0.0.1:8087"
BUCKET="athena-results"
PREFIX="e2e"
OUTPUT_LOCATION="s3://${BUCKET}/${PREFIX}/"
RUN_ID="$(date +%s)"

EVIDENCE_DIR="$(mktemp -d /tmp/athena-local-issue39-e2e.XXXXXX)"
ATHENA_LOG="$EVIDENCE_DIR/athena-local.log"
BUILD_LOG="$EVIDENCE_DIR/cargo-build.log"

ATHENA_PID=""

# shellcheck source=tools/e2e/minio/lib.sh
source "$SCRIPT_DIR/lib.sh"

# issue #111: ケース 10〜12（UPDATE / DELETE）と 14（s3 × 保持期限）
# shellcheck source=tools/e2e/minio/cases-dml-retention.sh
source "$SCRIPT_DIR/cases-dml-retention.sh"

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
  log "証跡（ログ・取得したファイル）: $EVIDENCE_DIR"
  print_table
  exit "$status"
}
trap cleanup EXIT

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

  # 前の走行の残骸（テーブル、結果ファイル）を持ち越さないよう、使うサービスを作り直す。
  log "docker compose down -v / up -d ${SERVICES[*]}"
  if ! "${COMPOSE[@]}" down -v "${SERVICES[@]}" >/dev/null 2>&1; then
    record "compose起動" FAIL "docker compose down -v ${SERVICES[*]} が失敗した"
    return 1
  fi
  if ! "${COMPOSE[@]}" up -d "${SERVICES[@]}"; then
    record "compose起動" FAIL "docker compose up -d ${SERVICES[*]} が失敗した"
    return 1
  fi

  if ! mc alias set local http://minio:9000 minioadmin minioadmin >/dev/null; then
    record "MinIOバケット" FAIL "mc alias set が失敗した（minio:9000 に繋がらない）"
    return 1
  fi

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
  record "cargo build" PASS "$BINARY を用意した"

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
