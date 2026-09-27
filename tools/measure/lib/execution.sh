#!/usr/bin/env bash
# GetQueryExecution・GetQueryResults の応答から必要な項目を抜き出す下回り、
# StartQueryExecution の start.err の読み取り。describe-extended.sh:397-547, :577-615
# （#275）から移植。JSON は jq でなく python3 -c（CLAUDE.md の既存の流儀）。

# execution.json から State / StateChangeReason / AthenaError の全文をファイルに書く。
write_reason() {
  local src=$1 dest=$2
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception:
    open(sys.argv[2], "w").write("(execution.json を読めませんでした)\n")
    sys.exit(0)
status = d.get("Status", {})
out = []
out.append("State: %s" % status.get("State", ""))
out.append("StateChangeReason: %s" % status.get("StateChangeReason", "(無し)"))
err = status.get("AthenaError")
if err is None:
    out.append("AthenaError: (無し)")
else:
    out.append("AthenaError: %s" % json.dumps(err, ensure_ascii=False, indent=2, sort_keys=True))
open(sys.argv[2], "w").write("\n".join(out) + "\n")' "$src" "$dest"
}

# AthenaError の ErrorCategory / ErrorType / ErrorMessage をタブ区切りで返す（無ければ 3 つとも "-"）。
athena_error_fields_of() {
  python3 -c 'import json, sys
try:
    err = json.load(open(sys.argv[1]))["QueryExecution"]["Status"].get("AthenaError")
except Exception:
    err = None
if err is None:
    print("-\t-\t-")
else:
    def g(k):
        v = err.get(k)
        return "-" if v is None else str(v).replace("\t", " ").replace("\n", " ")
    print("%s\t%s\t%s" % (g("ErrorCategory"), g("ErrorType"), g("ErrorMessage")))' "$1"
}

# execution.json から StatementType / SubstatementType / OutputLocation をタブ区切りで返す。
read_execution_fields() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception:
    print("-\t-\t")
    sys.exit(0)
print("%s\t%s\t%s" % (
    d.get("StatementType") or "-",
    d.get("SubstatementType") or "-",
    (d.get("ResultConfiguration") or {}).get("OutputLocation", "")))' "$1"
}

# execution.json から Query（受け取った SQL の写し。DB が落ちるかを見る本命）を返す。
query_of() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception:
    print("")
    sys.exit(0)
print(d.get("Query") or "")' "$1"
}

# execution.json から QueryExecutionContext を1行の JSON にして返す。
context_of() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception:
    print("{}")
    sys.exit(0)
print(json.dumps(d.get("QueryExecutionContext") or {}, ensure_ascii=False, sort_keys=True))' "$1"
}

# GetQueryResults の1ページから ColumnInfo（1行1列、Name:Type）を書き出す。
results_columns_of() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
rs = d.get("ResultSet") or {}
md = rs.get("ResultSetMetadata") or {}
cols = md.get("ColumnInfo") or []
for c in cols:
    print("%s:%s" % (c.get("Name"), c.get("Type")))' "$1"
}

# GetQueryResults の1ページから Rows（1行1Row、列はタブ区切りで連結。None は空文字）を書き出す。
results_rows_of() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
rs = d.get("ResultSet") or {}
for r in rs.get("Rows") or []:
    vals = []
    for x in r.get("Data") or []:
        v = x.get("VarCharValue")
        vals.append(v if v is not None else "")
    print("\t".join(vals).replace("\n", "\\n"))' "$1"
}

# GetQueryResults の1ページから NextToken を返す（無ければ空）。
results_next_token_of() {
  python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("NextToken") or "")
except Exception:
    print("")' "$1"
}

# GetQueryResults の1ページから UpdateCount を返す（無ければ "-"）。
results_update_count_of() {
  python3 -c 'import json, sys
try:
    u = json.load(open(sys.argv[1])).get("UpdateCount")
except Exception:
    u = None
print("-" if u is None else str(u))' "$1"
}

# GetQueryResults を全ページ取り、<id>.results-<n>.json・<id>.results.columns.txt・
# <id>.results.rows.txt・<id>.results.update_count.txt に書く。ページの取得は retry_aws
# 経由（名前解決・接続の一時的な失敗を RETRY_MAX 回まで再試行）。FAILED でも本物は
# GetQueryResults に 200 を返すはずなので、State によらず必ず試す
# （result-files.md「失敗・取り消し時に本物が置く結果ファイル」参照）。最大 20 ページ。
capture_results() {
  local item_id=$1 qid=$2 token="" page=0
  : > "$RUN_DIR/$item_id.results.rows.txt"
  rm -f "$RUN_DIR/$item_id.results.columns.txt" "$RUN_DIR/$item_id.results.update_count.txt"
  while :; do
    page=$((page + 1))
    local page_json="$RUN_DIR/$item_id.results-$page.json"
    local page_err="$RUN_DIR/$item_id.results-$page.err"
    if [ -z "$token" ]; then
      retry_aws "$page_json" "$page_err" aws athena get-query-results --region "$REGION" \
        --query-execution-id "$qid" --max-results 1000
    else
      retry_aws "$page_json" "$page_err" aws athena get-query-results --region "$REGION" \
        --query-execution-id "$qid" --max-results 1000 --next-token "$token"
    fi
    [ -s "$page_json" ] || break
    if [ "$page" = 1 ]; then
      results_columns_of "$page_json" > "$RUN_DIR/$item_id.results.columns.txt"
      results_update_count_of "$page_json" > "$RUN_DIR/$item_id.results.update_count.txt"
    fi
    results_rows_of "$page_json" >> "$RUN_DIR/$item_id.results.rows.txt"
    token=$(results_next_token_of "$page_json")
    [ -n "$token" ] || break
    [ "$page" -ge 20 ] && break
  done
  [ -s "$RUN_DIR/$item_id.results.update_count.txt" ] || echo "-" > "$RUN_DIR/$item_id.results.update_count.txt"
}

# start.err から Message を抜く（"operation: " の後ろから、"Additional error details:" の
# 手前まで。実名を伏せて短くする）。
start_err_message() {
  local f=$1 msg
  [ -s "$f" ] || { echo "-"; return; }
  msg=$(python3 -c '
import sys
try:
    text = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
except Exception:
    print("-")
    sys.exit(0)
marker = "operation: "
idx = text.find(marker)
if idx == -1:
    print("-")
    sys.exit(0)
rest = text[idx + len(marker):]
end = rest.find("\n\nAdditional error details:")
msg = rest[:end] if end != -1 else rest
msg = msg.rstrip("\r\n \t")
msg = msg.replace("\\", "<BACKSLASH>")
msg = msg.replace("\t", "<TAB>").replace("\r", "<CR>").replace("\n", "<LF>")
print(msg)
' "$f")
  if [ -n "$msg" ] && [ "$msg" != "-" ]; then
    sanitize "$(hide "$msg")"
  else
    echo "-"
  fi
}

# start.err から AthenaErrorCode の行を抜く。
start_err_code() {
  local f=$1 line
  [ -s "$f" ] || { echo "-"; return; }
  line=$(grep -m1 -oE '^AthenaErrorCode: .*' "$f")
  if [ -n "$line" ]; then
    sanitize "$(hide "${line#AthenaErrorCode: }")"
  else
    echo "-"
  fi
}
