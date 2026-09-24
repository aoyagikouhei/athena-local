# shellcheck shell=bash
# issue #113: w1（GetWorkGroup(WORKGROUP2) の見え方）、e1（QUEUED への GetQueryResults）、
# e2（構文エラーの ErrorCode キー、生 HTTP）。単独では実行しない。run.sh が source して
# item_w1 / item_e1 / item_e2 を呼ぶ。
# 手本: tools/measure/get-work-group.sh（GetWorkGroup の主要フィールドの畳み方）。

# w1: primary と WORKGROUP2 の GetWorkGroup を比べる。athena-local は名前を見ないので、
# local では Name 以外が一致するはず（work_group.rs）。real は素の値を保存するだけ
# （unmeasured.md「出力先が設定されたワークグループの GetWorkGroup の ResultConfiguration の形」）。
item_w1() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"

  if ! get_work_group "$dir" primary primary; then
    skip_item "$id" primary "GetWorkGroup(primary) が失敗した: $(first_err_line "$dir/primary.err")"
    return 1
  fi
  if ! get_work_group "$dir" workgroup2 "$WORKGROUP2"; then
    skip_item "$id" workgroup2 "GetWorkGroup(\$WORKGROUP2) が失敗した: $(first_err_line "$dir/workgroup2.err")"
    return 1
  fi

  local note same
  IFS=$'\t' read -r note same < <(python3 - "$dir/primary.json" "$dir/workgroup2.json" <<'PY'
import json, sys

def summarize(path):
    try:
        wg = json.load(open(path))["WorkGroup"]
    except Exception as e:
        return {"error": str(e)}
    c = wg.get("Configuration", {})
    rc = c.get("ResultConfiguration", {})
    return {
        "State": wg.get("State"),
        "Enforce": c.get("EnforceWorkGroupConfiguration"),
        "PublishMetrics": c.get("PublishCloudWatchMetricsEnabled"),
        "RequesterPays": c.get("RequesterPaysEnabled"),
        "MinEncryption": c.get("EnableMinimumEncryptionConfiguration"),
        "OutputLocation有無": bool(rc.get("OutputLocation")),
        "EngineVersion": c.get("EngineVersion"),
    }

a, b = summarize(sys.argv[1]), summarize(sys.argv[2])
same = a == b
note = "primary=%s workgroup2=%s" % (a, b)
print("%s\t%s" % (note.replace("\t", " "), "true" if same else "false"))
PY
  )
  write_summary_row "$id" get-work-group stmt - - - - - - - - - - - "$(sanitize "$note")"
  echo "== w1: $note (Name除く一致=$same)"

  if [ "$TARGET" = local ]; then
    declare_expectation "$id" configuration_matches_primary true "$same" \
      "GetWorkGroup は名前を無視する設計（work_group.rs）"
  fi
}

# e1: 軽い文を 5 本続けて投げ、直後に GetQueryExecution / GetQueryResults を呼んで
# QUEUED を捕まえられるか見る（重い計算は実行時間を延ばすだけで QUEUED を延ばさないので使わない）。
item_e1() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"

  local n ids=()
  for n in 1 2 3 4 5; do
    local label="e1-$n" tok
    tok=$(new_token)
    printf 'SELECT %d\n' "$n" >"$dir/$label.sql"
    athena_cli start-query-execution --query-string "SELECT $n" \
      --query-execution-context "Catalog=$TCAT_GENERIC,Database=$TDB" \
      --result-configuration "OutputLocation=$OUTPUT" \
      --client-request-token "$tok" \
      >"$dir/$label.start.json" 2>"$dir/$label.start.err"
    ids+=("$(query_execution_id_of "$dir/$label.start.json")")
  done

  local caught_queued=no
  for n in 1 2 3 4 5; do
    local label="e1-$n" qid="${ids[$((n - 1))]}"
    if [ -z "$qid" ]; then
      skip_item "$id" "$label" "StartQueryExecution が失敗した: $(first_err_line "$dir/$label.start.err")"
      continue
    fi
    athena_cli get-query-execution --query-execution-id "$qid" \
      >"$dir/$label.execution-immediate.json" 2>"$dir/$label.execution-immediate.err"
    athena_cli get-query-results --query-execution-id "$qid" \
      >"$dir/$label.results-immediate.json" 2>"$dir/$label.results-immediate.err"

    local state
    state=$(python3 -c 'import json, sys
try: print(json.load(open(sys.argv[1]))["QueryExecution"]["Status"]["State"])
except Exception: print("?")' "$dir/$label.execution-immediate.json")
    [ "$state" = QUEUED ] && caught_queued=yes
    local results_err
    results_err=$(first_err_line "$dir/$label.results-immediate.err")
    write_summary_row "$id" "$label" stmt "$state" - - - - - - - - - - \
      "immediate_state=$state; results_err=$results_err"
    echo "== $label: 直後の state=$state (results err: $results_err)"

    # 終端状態まで待って通常どおり保存する（後始末・比較のため id は残す）。
    poll_until_terminal "$qid" >/dev/null
    athena_cli get-query-execution --query-execution-id "$qid" >"$dir/$label.execution.json" 2>/dev/null
    fetch_all_results "$dir" "$label" "$qid"
  done

  write_summary_row "$id" observed stmt - - - - - - - - - - - "5本中QUEUEDを直後に観測できたか=$caught_queued"
  echo "== e1: QUEUED を直後に観測できたか=$caught_queued"
}

# e2（生 HTTP。raw.py）。lib-raw.sh の run_raw_item が summary.tsv への変換を担う。
item_e2() { run_raw_item "$1"; }
