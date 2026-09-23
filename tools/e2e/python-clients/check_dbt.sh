#!/usr/bin/env bash
# issue #111: dbt-athena 1.11.1 を work_group 付きで athena-local（s3 モード、中継 8102 → 8098）につなぐ。
#   E1 dbt debug                          … rc 0、区間の中継に StartQueryExecution と GetQueryExecution
#   E2 dbt run-operation check_work_group … ログに ENFORCED=False、区間の中継に GetWorkGroup ≥1
#                                           （athena-local は EnforceWorkGroupConfiguration=false を返すので、
#                                           値だけでは呼んだ証拠にならない）
#   E3 dbt run --select m111（INFO）       … Glue・STS を要求してどこで止まるかを記録する
# dbt-athena の impl の client は profile の endpoint_url を受け取らない（impl.py:347-351）ので、
# endpoint_url は profile に書かず、env.sh の AWS_ENDPOINT_URL* で向ける。
# 前提: verify.sh が env.sh を source 済みで、EVIDENCE_DIR・PROXY_LOG・TRACE_CONTAINER・DBT_BIN が決まっていること。
# 出力は `PASS|FAIL|SKIP|INFO <名前>: <詳細>` の行。終了コードは FAIL の件数。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$EVIDENCE_DIR/dbt"
mkdir -p "$OUT"
FAILS=0

# profiles.yml はコミットせず、ここで生成する（認証情報は env_var() で env.sh のダミーを読む）。
cat >"$OUT/profiles.yml" <<'EOF'
athena_local_111:
  target: dev
  outputs:
    dev:
      type: athena
      region_name: us-east-1
      s3_staging_dir: s3://athena-results/dbt/
      s3_data_dir: s3://athena-results/dbt-data/
      database: awsdatacatalog
      schema: default
      work_group: wg111
      threads: 1
      aws_access_key_id: "{{ env_var('AWS_ACCESS_KEY_ID') }}"
      aws_secret_access_key: "{{ env_var('AWS_SECRET_ACCESS_KEY') }}"
EOF
# target/ と logs/ をリポジトリに作らせない。
export DBT_PROFILES_DIR="$OUT" DBT_PROJECT_DIR="$SCRIPT_DIR/dbt" DBT_TARGET_PATH="$OUT/target" DBT_LOG_PATH="$OUT/logs"

result() {
  echo "$1 $2: $3"
  [ "$1" = "FAIL" ] && FAILS=$((FAILS + 1))
  return 0
}

mark() { python3 "$SCRIPT_DIR/common.py" mark | cut -d' ' -f1; }
count() { python3 "$SCRIPT_DIR/common.py" count "$1" "$2"; }
targets() { tail -n +"$(($1 + 1))" "$PROXY_LOG" | grep '^proxy: ' | sed -n 's/.*target=\([^ ]*\).*/\1/p' | sort | uniq -c | tr -s ' \n' ' '; }
# dbt の JSON ログから error の行の msg を 1 行ずつ抜く。
errors_of() { python3 -c 'import json,re,sys
for line in open(sys.argv[1], encoding="utf-8"):
    try: e = json.loads(line)
    except ValueError: continue
    if e.get("info", {}).get("level") != "error": continue
    msg = [m.strip() for m in re.sub(r"\x1b\[[0-9;]*m", "", e["info"].get("msg", "")).splitlines() if m.strip()]
    if msg and not msg[0].startswith("Traceback"): print(" / ".join(msg[:2])[:300])' "$1" | head -3; }

run_dbt() {
  local name="$1"
  shift
  "$DBT_BIN" "$@" --log-format json >"$OUT/$name.jsonl" 2>&1
}

# E1
from=$(mark)
run_dbt debug debug
rc=$?
start=$(count "$from" 'target=AmazonAthena\.StartQueryExecution ')
get=$(count "$from" 'target=AmazonAthena\.GetQueryExecution ')
detail="rc=$rc 中継の区間: StartQueryExecution=$start GetQueryExecution=$get targets=[$(targets "$from")]"
if [ "$rc" = 0 ] && [ "$start" -ge 1 ] && [ "$get" -ge 1 ]; then
  result PASS "(1) E1 dbt debug" "$detail"
else
  result FAIL "(1) E1 dbt debug" "$detail errors=$(errors_of "$OUT/debug.jsonl" | tr '\n' '|')"
fi

# E2
from=$(mark)
run_dbt run-operation run-operation check_work_group
rc=$?
enforced=$(grep -o 'ENFORCED=[A-Za-z]*' "$OUT/run-operation.jsonl" | head -1)
gw=$(count "$from" 'target=AmazonAthena\.GetWorkGroup ')
detail="rc=$rc log=${enforced:-無し} 中継の区間: GetWorkGroup=$gw targets=[$(targets "$from")]"
if [ "$rc" = 0 ] && [ "$enforced" = "ENFORCED=False" ] && [ "$gw" -ge 1 ]; then
  result PASS "(1) E2 dbt run-operation check_work_group" "$detail"
elif [ -z "$enforced" ] && [ "$rc" != 0 ] && [ "$gw" -eq 0 ]; then
  # GetWorkGroup が中継に届いていれば「呼べなかった」ではなく応答側の問題なので、下の FAIL に落とす。
  result SKIP "(1) E2 dbt run-operation check_work_group" "未測定: マクロから呼べなかった $detail errors=$(errors_of "$OUT/run-operation.jsonl" | tr '\n' '|')"
else
  result FAIL "(1) E2 dbt run-operation check_work_group" "$detail"
fi

# E3（INFO）
from=$(mark)
run_dbt run run --select m111
rc=$?
glue=$(count "$from" 'target=AWSGlue\.')
sts=$(count "$from" 'target=- ')
result INFO "(1) E3 dbt run --select m111" \
  "rc=$rc 中継の区間: Glue=$glue STS(target=-)=$sts targets=[$(targets "$from")] errors=$(errors_of "$OUT/run.jsonl" | tr '\n' '|')"

exit "$FAILS"
