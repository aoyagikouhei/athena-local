#!/usr/bin/env bash
# issue #273 の実機確認（compose の trino・minio。tools/dev.sh 経由で動かす）。
# S3 Tables の Context の CTAS で書き込む先の名前空間が無いとき、本物の Trino が返すエラーを athena-local が本物の
# NOT_FOUND の文言に直すか、Database を省略した 1 部の名前で名前空間 `default` を引くかを確かめる。
# 使い方: tools/dev.sh bash .claude/issue-notes/273-verify/check.sh
set -uo pipefail

BIND=127.0.0.1:8273
BASE="http://$BIND"
BIN="${CARGO_TARGET_DIR:-target}/release/athena-local"
cargo build --release -q || exit 1

ATHENA_LOCAL_BIND="$BIND" TRINO_URL=http://trino:8080 TRINO_USER=athena-local-e2e273 \
  TRINO_CATALOG_MAP="s3tablescatalog/e2e273=iceberg" ATHENA_LOCAL_RESULTS=s3 \
  AWS_ENDPOINT_URL_S3=http://minio:9000 AWS_ACCESS_KEY_ID=minioadmin AWS_SECRET_ACCESS_KEY=minioadmin \
  ATHENA_LOCAL_OUTPUT_LOCATION="s3://athena-results/e2e273/" "$BIN" >/tmp/athena-local-273.log 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null; tail -5 /tmp/athena-local-273.log' EXIT
for _ in $(seq 1 30); do curl -s -o /dev/null "$BASE" && break; sleep 0.5; done

call() {
  curl -s "$BASE/" -H 'Content-Type: application/x-amz-json-1.1' -H "X-Amz-Target: AmazonAthena.$1" -d "$2"
}

run() {
  local sql=$1 context=$2 id state
  id=$(call StartQueryExecution "$(jq -n --arg q "$sql" --arg t "$(cat /proc/sys/kernel/random/uuid)" --argjson c "$context" \
    '{QueryString: $q, QueryExecutionContext: $c, ResultConfiguration: {OutputLocation: "s3://athena-results/e2e273/"}, ClientRequestToken: $t}')" |
    tee /dev/stderr | jq -r ".QueryExecutionId // empty")
  [ -n "$id" ] || { echo "== $sql $context → 開始できない"; return; }
  for _ in $(seq 1 60); do
    state=$(call GetQueryExecution "{\"QueryExecutionId\":\"$id\"}" | jq -r '.QueryExecution.Status.State')
    case "$state" in SUCCEEDED | FAILED | CANCELLED) break ;; esac
    sleep 0.5
  done
  echo "== $sql $context"
  call GetQueryExecution "{\"QueryExecutionId\":\"$id\"}" |
    jq -c '.QueryExecution.Status | {State, StateChangeReason, AthenaError: (.AthenaError | {ErrorCategory, ErrorType})}'
  mc ls --recursive "local/athena-results/e2e273/" 2>/dev/null | grep -F "$id" || echo "   結果ファイル無し"
}

mc alias set local http://minio:9000 minioadmin minioadmin >/dev/null 2>&1
S3='{"Catalog":"s3tablescatalog/e2e273","Database":"nope273"}'
S3NS='{"Catalog":"s3tablescatalog/e2e273","Database":"information_schema"}'
S3NODB='{"Catalog":"s3tablescatalog/e2e273"}'
run "CREATE TABLE t273a AS SELECT 1 AS n" "$S3"
run "CREATE TABLE IF NOT EXISTS Nope273.t273b AS SELECT 1 AS n WITH NO DATA" "$S3NS"
run "CREATE TABLE nope273.t273c AS SELECT * FROM iceberg.nope273.nosrc" "$S3NS"
run "CREATE TABLE nope273.t273d AS SELECT CAST('x' AS integer) AS n" "$S3NS"
run "CREATE TABLE t273e AS SELECT 1 AS n" "$S3NODB"
run "CREATE TABLE t273f (n int)" "$S3NODB"
