#!/usr/bin/env bash
# #307 の実機確認: 手元の Trino（compose の trino）に対し、athena-local を立てて Iceberg／Hive の表に DESCRIBE を投げる。
# 前提: iceberg.p307 に time・tstz・uuid の列の表（CTAS）と hive.p307.h がある（ノートの「手元の Trino」の手順で作ったもの）。
# 使い方: tools/dev.sh bash .claude/issue-notes/307/verify-local.sh <time の表> <tstz の表> <uuid の表>
set -uo pipefail
T_TIME=$1; T_TSTZ=$2; T_UUID=$3
PORT=18307
ATHENA_LOCAL_BIND=127.0.0.1:$PORT TRINO_CATALOG=iceberg TRINO_SCHEMA=p307 "${CARGO_TARGET_DIR:-./target}"/debug/athena-local >/tmp/al307.log 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null' EXIT
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.2; done
call() { curl -s -X POST "http://127.0.0.1:$PORT/" -H 'Content-Type: application/x-amz-json-1.1' -H "X-Amz-Target: AmazonAthena.$1" -d "$2"; }
run() {
  local sql=$1 catalog=${2:-iceberg}
  local id; id=$(call StartQueryExecution "$(jq -cn --arg s "$sql" --arg c "$catalog" --arg t "$(cat /proc/sys/kernel/random/uuid)" '{QueryString:$s, ClientRequestToken:$t, QueryExecutionContext:{Catalog:$c, Database:"p307"}}')" | jq -r .QueryExecutionId)
  local st
  for _ in $(seq 1 100); do
    st=$(call GetQueryExecution "{\"QueryExecutionId\":\"$id\"}")
    case $(jq -r .QueryExecution.Status.State <<<"$st") in SUCCEEDED|FAILED|CANCELLED) break;; esac
    sleep 0.2
  done
  echo "### $sql (Catalog=$catalog)"
  jq -c '.QueryExecution | {State:.Status.State, Reason:.Status.StateChangeReason, Err:.Status.AthenaError, Type:.StatementType, Sub:.SubstatementType}' <<<"$st"
  if [ "$(jq -r .QueryExecution.Status.State <<<"$st")" = SUCCEEDED ]; then
    call GetQueryResults "{\"QueryExecutionId\":\"$id\"}" | jq -r '.ResultSet.Rows[].Data[0].VarCharValue'
  fi
}
run "DESCRIBE $T_TIME"
run "DESC $T_UUID"
run "DESCRIBE $T_TSTZ"
run "DESCRIBE h" hive
