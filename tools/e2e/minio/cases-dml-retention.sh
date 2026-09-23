# shellcheck shell=bash
# issue #111 フェーズ 1: verify.sh に足すケース 10〜12（UPDATE / DELETE）と 14（s3 × 保持期限）。
# 単独では実行しない。verify.sh が `source` し、その変数と、verify.sh・lib.sh のヘルパ（trino_exec、athena_start_query、
# athena_wait、athena_call、mc_stat、mc_exists、run_merge_case、record、start_athena_local）を使う。
#
# - ケース 10・11: Iceberg への UPDATE / DELETE が本体（<id>.csv）を置かず <id>.csv.metadata だけを置き、
#   その updateType と更新件数が Trino の返した値（UPDATE/1、DELETE/1）になること（run_merge_case で判定）。
# - ケース 12: Hive（非 ACID）への UPDATE は Trino が拒否して FAILED になり、<id>.csv も
#   <id>.csv.metadata も置かれないこと（UPDATE は ResultFile::Csv で、write_failure は Text だけ）。
# - ケース 14: ATHENA_LOCAL_RETENTION_SECONDS=1 で再起動し、SUCCEEDED の後に保持期限を過ぎた実行が
#   GetQueryExecution で 400 QUERY_EXECUTION_NOT_FOUND になっても、S3 の結果ファイルは残ること。

# ケース 10・11 の後で、.metadata のバイト数を結果の詳細に足す（期待にはしない。記録用）。
append_metadata_size() {
  local idx=$(( ${#RESULT_STATUS[@]} - 1 )) id file
  id=$(echo "${RESULT_DETAIL[$idx]}" | sed -n 's/.*\[id=\([^]]*\)\].*/\1/p')
  file="$EVIDENCE_DIR/${id}.csv.metadata"
  if [ -n "$id" ] && [ -f "$file" ]; then
    RESULT_DETAIL[$idx]="${RESULT_DETAIL[$idx]} metadata=$(stat -c%s "$file")B"
  fi
}

# ケース 10・11: Iceberg のテーブル（(1,'a'),(2,'b')）に UPDATE と DELETE を 1 行ずつ当てる。
run_update_delete_cases() {
  local t_dml="t_dml_iceberg_${RUN_ID}"

  log "UPDATE / DELETE 用のテーブルを作る（Iceberg。format_version は既定の 2）"
  if ! trino_exec "CREATE TABLE iceberg.default.${t_dml} AS SELECT * FROM (VALUES (1, 'a'), (2, 'b')) AS v(n, s)" iceberg default; then
    record "セットアップ(dml iceberg)" FAIL "iceberg.default.${t_dml} の作成に失敗した"
    record "10〜11 UPDATE/DELETE_iceberg" SKIP "未測定: テーブルを作れなかった"
    return
  fi
  record "セットアップ(dml iceberg)" PASS "iceberg.default.${t_dml} 作成済み"

  # ケース 10: UPDATE は 1 行（n = 1）に当たる。
  run_merge_case 10 "UPDATE_iceberg" \
    "UPDATE ${t_dml} SET s = 'z' WHERE n = 1" \
    iceberg default UPDATE 1
  append_metadata_size

  # ケース 11: DELETE は 1 行（n = 2）に当たる。
  run_merge_case 11 "DELETE_iceberg" \
    "DELETE FROM ${t_dml} WHERE n = 2" \
    iceberg default DELETE 1
  append_metadata_size
}

# ケース 12: Hive（非 ACID）への UPDATE。FAILED で、<id>.csv も <id>.csv.metadata も無いこと。
# SUCCEEDED になったら FAIL（本物は失敗した DML に何も置かないので、食い違いになる）。
run_failed_update_case() {
  local t_hive="t_dml_hive_${RUN_ID}" name="12 UPDATE_hive_失敗"
  if ! trino_exec "CREATE TABLE hive.default.${t_hive} AS SELECT 1 AS n" hive default; then
    record "$name" SKIP "未測定: hive.default.${t_hive} を作れなかった"
    return
  fi

  local sql="UPDATE ${t_hive} SET n = 2 WHERE n = 1" id resp state reason
  log "ケース 12: $name -- $sql"
  id=$(athena_start_query "$sql" hive default)
  if [ -z "$id" ]; then
    record "$name" FAIL "StartQueryExecution が QueryExecutionId を返さなかった（構文チェックで弾かれた）"
    return
  fi
  resp=$(athena_wait "$id")
  state=$(echo "$resp" | jq -r '.QueryExecution.Status.State // empty')
  reason=$(echo "$resp" | jq -r '.QueryExecution.Status.StateChangeReason // empty')
  if [ "$state" != "FAILED" ]; then
    record "$name" FAIL "終了状態が FAILED でない: $state ($reason) [id=$id]"
    return
  fi

  local key="${PREFIX}/${id}.csv" detail="" ok=1
  if mc_exists "$(mc_stat "$key")"; then
    ok=0; detail="$detail 本体 ${id}.csv がある"
  fi
  if mc_exists "$(mc_stat "${key}.metadata")"; then
    ok=0; detail="$detail ${id}.csv.metadata がある"
  fi
  if [ "$ok" = "1" ]; then
    record "$name" PASS "FAILED、本体も .metadata も無し。理由: $reason [id=$id]"
  else
    record "$name" FAIL "FAILED だが結果ファイルがある:$detail。理由: $reason [id=$id]"
  fi
}

# athena-local を止め、保持期限（秒。空なら start_athena_local の既定 3600）を変えて起動し直す。
# ログは最初の起動のものを上書きしないよう別名にする。
restart_athena_local_with_retention() {
  local seconds="${1:-}"
  log "athena-local を保持期限 ${seconds:-既定(3600)} 秒で再起動する"
  if [ -n "$ATHENA_PID" ] && kill -0 "$ATHENA_PID" 2>/dev/null; then
    kill "$ATHENA_PID" 2>/dev/null || true
    wait "$ATHENA_PID" 2>/dev/null || true
  fi
  ATHENA_PID=""
  start_athena_local "$seconds" "$EVIDENCE_DIR/athena-local-retention.log"
}

# ケース 14: 保持期限を過ぎた実行は GetQueryExecution が 400 QUERY_EXECUTION_NOT_FOUND になるが、
# S3 の <id>.csv と <id>.csv.metadata は残る（athena-local は S3 を消さない）。
# 400 にならない（破棄が起きていない）のは保持期限の退行（tests/retention.rs が固定する挙動）なので FAIL。
run_retention_s3_case() {
  local name="14 保持期限後もS3の結果は残る" expect_status=400 expect_code="QUERY_EXECUTION_NOT_FOUND"
  local id resp state status body code
  log "ケース 14: $name -- SELECT 1 AS n"
  id=$(athena_start_query "SELECT 1 AS n" iceberg default)
  if [ -z "$id" ]; then
    record "$name" FAIL "StartQueryExecution が QueryExecutionId を返さなかった"
    return
  fi
  resp=$(athena_wait "$id")
  state=$(echo "$resp" | jq -r '.QueryExecution.Status.State // empty')
  if [ "$state" != "SUCCEEDED" ]; then
    record "$name" FAIL "終了状態が SUCCEEDED でない: $state [id=$id]"
    return
  fi

  # 保持期限 1 秒に対して 2.5 秒待つ。破棄は次の API 呼び出し（Store::lock の sweep）で起きる。
  sleep 2.5
  body="$EVIDENCE_DIR/${id}.get-after-retention.json"
  status=$(curl -s -o "$body" -w '%{http_code}' -X POST "$ATHENA_BASE/" \
    -H "X-Amz-Target: AmazonAthena.GetQueryExecution" \
    -H "Content-Type: application/x-amz-json-1.1" \
    --data "$(jq -n --arg id "$id" '{QueryExecutionId: $id}')")
  # jq にはファイルを引数でなく標準入力で渡す。
  code=$(jq -r '.AthenaErrorCode // empty' <"$body" 2>/dev/null)
  if [ "$status" = "200" ] && [ "$expect_status" != "200" ]; then
    record "$name" FAIL "2.5 秒後も GetQueryExecution が 200（保持期限 1 秒の破棄が起きていない） [id=$id]"
    return
  fi
  if [ "$status" != "$expect_status" ] || [ "$code" != "$expect_code" ]; then
    record "$name" FAIL "GetQueryExecution が HTTP $status AthenaErrorCode=$code（期待 $expect_status $expect_code） [id=$id]"
    return
  fi

  local key="${PREFIX}/${id}.csv" missing=""
  mc_exists "$(mc_stat "$key")" || missing="$missing ${id}.csv"
  mc_exists "$(mc_stat "${key}.metadata")" || missing="$missing ${id}.csv.metadata"
  if [ -z "$missing" ]; then
    record "$name" PASS "GetQueryExecution は HTTP $status $code、<id>.csv と <id>.csv.metadata は残っている [id=$id]"
  else
    record "$name" FAIL "GetQueryExecution は HTTP $status $code だが S3 に無い:$missing [id=$id]"
  fi
}
