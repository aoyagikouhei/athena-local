# shellcheck shell=bash
# issue #113: tools/measure/unmeasured-batch/ の共通ヘルパ（1 文を投げて待って保存する部分）。
# 単独では実行しない。run.sh が source し、items-*.sh から呼ぶ。
#
# 手本: tools/measure/drop-table-format.sh の run()/poll_until_terminal()/start_query_retry()/
# redact()/fetch() をほぼそのまま踏襲する。decisions.md:47 は「別々の足場の間で共有しない」決定だが、
# これは 1 本のバッチの中のファイル分割（行数の目安を守るため）で、外からは source しない。
#
# TARGET=local では ATHENA_EXTRA_ARGS / S3_EXTRA_ARGS（lib-local.sh が設定）で aws CLI の
# 向き先を athena-local（127.0.0.1:8087）／MinIO（http://minio:9000）に変える。それ以外の経路は
# TARGET=real と共通（同じ aws athena / aws s3 のサブコマンドを通る）。
#
# 呼び出し側が使う主な関数:
#   run_stmt <item_dir> <label> <sql> [catalog] [database] [workgroup] [token] [output_override]
#     文を 1 本投げて終端状態まで待ち、GetQueryExecution・全ページの GetQueryResults・
#     本体と .metadata を保存して summary.tsv に 1 行足す。SUCCEEDED なら 0 を返す。
#     省略した引数は "-" を渡す（間の引数だけ省くことはできない）。
#   declare_expectation <item_id> <key> <expected> <actual> <note>
#     local で決まる答えの宣言と実測を summary.tsv に記録する（kind=expect）。
#   skip_item <item_id> <label> <reason>
#   reset_item_rows <item_id>
#     RUN_DIR 追記（ONLY の再実行）のときに、その項目の古い行を消してから足す。

declare -a ATHENA_EXTRA_ARGS=()
declare -a S3_EXTRA_ARGS=()

# CURRENT_ITEM は run.sh が items-*.sh の各関数を呼ぶ直前に設定する。
CURRENT_ITEM=${CURRENT_ITEM:-}

athena_cli() { aws athena --region "$REGION" "${ATHENA_EXTRA_ARGS[@]}" "$@"; }
s3_cli() { aws s3 "${S3_EXTRA_ARGS[@]}" "$@"; }
s3api_cli() { aws s3api "${S3_EXTRA_ARGS[@]}" "$@"; }

new_token() { uuidgen | tr -d '\n'; }

# --- 実名を隠す・短くする ------------------------------------------------

redact() {
  local s=$1
  [ -n "${DB:-}" ] && s=${s//$DB/<DB>}
  [ -n "${OUTPUT:-}" ] && s=${s//$OUTPUT/<OUTPUT>}
  [ -n "${OUTPUT_BUCKET:-}" ] && s=${s//$OUTPUT_BUCKET/<BUCKET>}
  [ -n "${WORKGROUP2:-}" ] && s=${s//$WORKGROUP2/<WORKGROUP2>}
  printf '%s' "$s" | sed -E 's/[0-9]{12}/<ACCOUNT_ID>/g'
}
sanitize() { printf '%s' "$1" | tr '\t\n\r' '   ' | cut -c1-300; }
# aws CLI が本文の前に空行を挟むことがある（2026-09-23 実測。awscli 2.37.0）ので、
# 最初の空でない行を返す（無ければ全体が空扱い）。
first_err_line() {
  if [ -s "$1" ]; then
    sanitize "$(redact "$(grep -m1 -v '^[[:space:]]*$' "$1")")"
  else
    echo "(エラー出力なし)"
  fi
}
is_transient_error() {
  [ -s "$1" ] || return 1
  grep -qiE 'Could not connect|Connection aborted|Connection reset|EndpointConnectionError|Temporary failure in name resolution|Name or service not known|Network is unreachable|Read timed out|[Cc]onnect timeout|ConnectTimeoutError|ReadTimeoutError|SSLError|Broken pipe' "$1"
}
# StartQueryExecution が失敗したときの本文を、既知の分類に畳む。
#   conflict          IDEMPOTENT_PARAMETER_MISMATCH（2026-09-17 実測の文言）
#   validation_error  それ以外の何らかのエラー（OutputLocation 不正・構文エラーなど）
#   success           エラーが無い（呼び出し側が先に判定していれば普通ここには来ない）
classify_start_error() {
  local err_file=$1
  [ -s "$err_file" ] || { echo success; return; }
  if grep -qi 'Idempotent parameters do not match' "$err_file"; then
    echo conflict
  else
    echo validation_error
  fi
}

# --- S3 取得 ---------------------------------------------------------------

# aws が Docker のラッパだと絶対パスへの書き出しがコンテナの中に消えるため、
# 常に `aws s3 cp <src> -` を標準出力に流し、リダイレクトはこのシェルが行う。
fetch() {
  local src=$1 dest=$2 err=$3
  if s3_cli cp "$src" - >"$dest" 2>"$err"; then
    [ -s "$dest" ] || [ ! -s "$err" ]
  else
    rm -f "$dest"
    return 1
  fi
}

# s3://bucket/key から ContentLength と ContentType をタブ区切りで返す。無ければ "-\t-"。
head_object() {
  local uri=$1 rest bucket key out
  rest=${uri#s3://}
  bucket=${rest%%/*}
  key=${rest#*/}
  if [ "$bucket" = "$rest" ] || [ -z "$key" ]; then
    printf -- '-\t-'
    return
  fi
  out=$(s3api_cli head-object --bucket "$bucket" --key "$key" \
    --query '[ContentLength,ContentType]' --output text 2>/dev/null)
  if [ -n "${out:-}" ]; then printf '%s' "$out"; else printf -- '-\t-'; fi
}

# --- JSON の読み取り（python3。model 各スクリプトと同じ流儀） ----------------

write_reason() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception:
    open(sys.argv[2], "w").write("(execution.json を読めませんでした)\n"); sys.exit(0)
st = d.get("Status", {})
err = st.get("AthenaError")
out = ["State: %s" % st.get("State", ""), "StateChangeReason: %s" % st.get("StateChangeReason", "(無し)"),
       "AthenaError: %s" % ("(無し)" if err is None else json.dumps(err, ensure_ascii=False, sort_keys=True))]
open(sys.argv[2], "w").write("\n".join(out) + "\n")' "$1" "$2"
}
error_codes_of() {
  python3 -c 'import json, sys
try: err = json.load(open(sys.argv[1]))["QueryExecution"]["Status"].get("AthenaError")
except Exception: err = None
print("-" if err is None else "cat=%s,type=%s" % (err.get("ErrorCategory", "-"), err.get("ErrorType", "-")))' "$1"
}
# StatementType / SubstatementType / OutputLocation をタブ区切りで返す。
read_execution_fields() {
  python3 -c 'import json, sys
try: d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception: print("-\t-\t"); sys.exit(0)
print("%s\t%s\t%s" % (d.get("StatementType") or "-", d.get("SubstatementType") or "-", d.get("ResultConfiguration", {}).get("OutputLocation", "")))' "$1"
}
query_execution_id_of() {
  python3 -c 'import json, sys
try: print(json.load(open(sys.argv[1])).get("QueryExecutionId", ""))
except Exception: print("")' "$1" 2>/dev/null
}
loc_shape_of() {
  local loc=$1 id=$2
  [ -n "$loc" ] || { echo "-"; return; }
  case "$loc" in
    */tables/"$id") echo 'tables/<id>' ;;
    *"/$id") echo '<id>' ;;
    *"/$id.csv") echo '<id>.csv' ;;
    *"/$id.txt") echo '<id>.txt' ;;
    *"$id"*) echo 'other(idを含む)' ;;
    *) echo 'other(idを含まない)' ;;
  esac
}

get_state_once() {
  athena_cli get-query-execution --query-execution-id "$1" \
    --query 'QueryExecution.Status.State' --output text 2>/dev/null
}
poll_until_terminal() {
  local id=$1 waited=0 state=""
  while [ "$waited" -lt "$POLL_TIMEOUT" ]; do
    state=$(get_state_once "$id")
    case "$state" in SUCCEEDED | FAILED | CANCELLED) break ;; esac
    state=""
    sleep 1
    waited=$((waited + 1))
  done
  printf '%s' "${state:-TIMEOUT}"
}

# --- StartQueryExecution（名前解決系の一時的な失敗だけ再試行） ---------------

start_query_retry() {
  local out_json=$1 err_file=$2
  shift 2
  local attempt=1
  while :; do
    if athena_cli start-query-execution "$@" >"$out_json" 2>"$err_file"; then
      return 0
    fi
    if [ "$attempt" -ge "$RETRY_MAX" ] || ! is_transient_error "$err_file"; then
      return 1
    fi
    echo "== 一時的な失敗とみて ${RETRY_DELAY} 秒後に再試行します（試行 $attempt/$RETRY_MAX）" >&2
    sleep "$RETRY_DELAY"
    attempt=$((attempt + 1))
  done
}

# --- 全ページの GetQueryResults ---------------------------------------------

fetch_all_results() {
  local item_dir=$1 label=$2 id=$3
  local next="" page=1 out
  while :; do
    out="$item_dir/$label.results-$page.json"
    if [ -n "$next" ]; then
      athena_cli get-query-results --query-execution-id "$id" --next-token "$next" \
        >"$out" 2>"$item_dir/$label.results-$page.err"
    else
      athena_cli get-query-results --query-execution-id "$id" \
        >"$out" 2>"$item_dir/$label.results-$page.err"
    fi
    [ -s "$out" ] || break
    next=$(python3 -c 'import json, sys
try: print(json.load(open(sys.argv[1])).get("NextToken", ""))
except Exception: print("")' "$out" 2>/dev/null)
    page=$((page + 1))
    [ -z "$next" ] && break
    [ "$page" -gt 50 ] && break # 安全弁（無限ページを踏まない）
  done
}

# --- summary.tsv -------------------------------------------------------------
# 列: item_id label kind state statement_type substatement_type loc_shape
#     body_bytes body_ct metadata_bytes metadata_ct expected actual match note

write_summary_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}" "${13}" "${14}" "$(sanitize "${15}")" \
    >>"$SUMMARY"
}

# ONLY で 1 項目だけ再実行するとき、RUN_DIR 追記の重複行を避けるため先に消す。
reset_item_rows() {
  local item_id=$1
  [ -f "$SUMMARY" ] || return 0
  python3 -c 'import sys
item_id, path = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines(True)
kept = [lines[0]] + [l for l in lines[1:] if not l.startswith(item_id + "\t")]
open(path, "w").writelines(kept)' "$item_id" "$SUMMARY"
}

skip_item() {
  local item_id=$1 label=$2 reason=$3
  echo "== $item_id/$label: skip（$reason）"
  write_summary_row "$item_id" "$label" skip - - - - - - - - - - - "$(sanitize "$reason")"
}

declare_expectation() {
  local item_id=$1 key=$2 expected=$3 actual=$4 note=${5:-}
  local match=no
  [ "$expected" = "$actual" ] && match=yes
  echo "== $item_id/$key: expected=$expected actual=$actual match=$match"
  write_summary_row "$item_id" "$key" expect - - - - - - - - "$expected" "$actual" "$match" "$note"
}

# --- 1 文を投げて保存する本体 -------------------------------------------------

# start-query-execution の引数配列を組む。結果はグローバル配列 STMT_ARGS に入れる
# （bash の関数は配列を戻り値にできないため）。引数を省くときは "-" を渡す。
build_stmt_args() {
  local sql=$1 catalog=$2 database=$3 workgroup=$4 token=$5 output_override=$6
  STMT_ARGS=(--query-string "$sql" --client-request-token "$token")
  local qec=()
  [ "$catalog" != "-" ] && qec+=("Catalog=$catalog")
  [ "$database" != "-" ] && qec+=("Database=$database")
  if [ "${#qec[@]}" -gt 0 ]; then
    local joined
    joined=$(
      IFS=,
      echo "${qec[*]}"
    )
    STMT_ARGS+=(--query-execution-context "$joined")
  fi
  [ "$output_override" != "-" ] && STMT_ARGS+=(--result-configuration "OutputLocation=$output_override")
  [ "$workgroup" != "-" ] && STMT_ARGS+=(--work-group "$workgroup")
}

# OutputLocation の本体と .metadata を保存する。結果はグローバル変数
# BODY_BYTES/BODY_CT/META_BYTES/META_CT に入れる。
fetch_result_files() {
  local item_dir=$1 label=$2 loc=$3
  BODY_BYTES=-; BODY_CT=-; META_BYTES=-; META_CT=-
  [ -n "$loc" ] || return 0
  {
    echo "# ls $loc"
    s3_cli ls "$loc"
    echo "# rc=$?"
    echo "# ls $loc.metadata"
    s3_cli ls "$loc.metadata"
    echo "# rc=$?"
  } >"$item_dir/$label.ls.txt" 2>&1
  IFS=$'\t' read -r BODY_BYTES BODY_CT < <(head_object "$loc")
  IFS=$'\t' read -r META_BYTES META_CT < <(head_object "$loc.metadata")
  if [ "$BODY_BYTES" != "-" ] && fetch "$loc" "$item_dir/$label.body.bytes" "$item_dir/$label.body.cp.err"; then
    od -An -tx1c "$item_dir/$label.body.bytes" >"$item_dir/$label.body.od.txt"
  fi
  if [ "$META_BYTES" != "-" ] && fetch "$loc.metadata" "$item_dir/$label.metadata.bytes" "$item_dir/$label.metadata.cp.err"; then
    od -An -tx1c "$item_dir/$label.metadata.bytes" >"$item_dir/$label.metadata.od.txt"
  fi
}

# 引数を省くときは "-" を渡す（末尾側は丸ごと省略できる）。
run_stmt() {
  local item_dir=$1 label=$2 sql=$3
  local catalog=${4:--} database=${5:--} workgroup=${6:--} token=${7:--} output_override=${8:--}
  mkdir -p "$item_dir"
  printf '%s\n' "$sql" >"$item_dir/$label.sql"
  [ "$token" = "-" ] && token=$(new_token)

  local STMT_ARGS=()
  build_stmt_args "$sql" "$catalog" "$database" "$workgroup" "$token" "$output_override"

  local out_json="$item_dir/$label.start.json" err_file="$item_dir/$label.start.err"
  if ! start_query_retry "$out_json" "$err_file" "${STMT_ARGS[@]}"; then
    local note
    note=$(first_err_line "$err_file")
    echo "== $label: 開始できませんでした。$note"
    write_summary_row "$CURRENT_ITEM" "$label" stmt START_FAILED - - - - - - - - - - "$note"
    return 1
  fi

  local id
  id=$(query_execution_id_of "$out_json")
  if [ -z "$id" ]; then
    echo "== $label: QueryExecutionId が取れませんでした"
    write_summary_row "$CURRENT_ITEM" "$label" stmt START_FAILED - - - - - - - - - - "QueryExecutionId無し"
    return 1
  fi

  local state
  state=$(poll_until_terminal "$id")
  athena_cli get-query-execution --query-execution-id "$id" \
    >"$item_dir/$label.execution.json" 2>"$item_dir/$label.execution.err"
  write_reason "$item_dir/$label.execution.json" "$item_dir/$label.reason.txt"
  fetch_all_results "$item_dir" "$label" "$id"

  local stype sub loc
  IFS=$'\t' read -r stype sub loc < <(read_execution_fields "$item_dir/$label.execution.json")
  local shape
  shape=$(loc_shape_of "$loc" "$id")

  local BODY_BYTES=- BODY_CT=- META_BYTES=- META_CT=-
  fetch_result_files "$item_dir" "$label" "$loc"
  local body_bytes=$BODY_BYTES body_ct=$BODY_CT meta_bytes=$META_BYTES meta_ct=$META_CT

  local note="id=$id"
  case "$state" in
    FAILED | CANCELLED) note="$note; $(error_codes_of "$item_dir/$label.execution.json")" ;;
  esac
  write_summary_row "$CURRENT_ITEM" "$label" stmt "$state" "$stype" "$sub" "$shape" \
    "$body_bytes" "$body_ct" "$meta_bytes" "$meta_ct" - - - "$note"
  echo "== $label state=$state $stype/$sub loc=$shape body=${body_bytes}($body_ct) meta=${meta_bytes}($meta_ct) id=$id"
  [ "$state" = SUCCEEDED ]
}

# 同名のテーブル・ビューを壊さないよう、作る前に SHOW TABLES で確かめる。
# 見つかれば 1（呼び出し側は作らずに skip する）、確認できなければ安全側に倒して 1。
# 何も見つからなければ 0。
probe_prefix_exists() {
  local item_dir=$1 catalog=$2 database=$3 prefix=$4
  local label="_probe_show_tables_${prefix}"
  if ! run_stmt "$item_dir" "$label" "SHOW TABLES LIKE '${prefix}%'" "$catalog" "$database" >/dev/null 2>&1; then
    echo "== $prefix: SHOW TABLES が失敗したので安全側に倒して skip 扱いにする" >&2
    return 1
  fi
  local body="$item_dir/$label.body.bytes"
  [ -s "$body" ] && grep -qi "$prefix" "$body"
}

# GetWorkGroup を呼んで応答を保存する。成功すれば 0。
get_work_group() {
  local item_dir=$1 label=$2 name=$3
  mkdir -p "$item_dir"
  athena_cli get-work-group --work-group "$name" \
    >"$item_dir/$label.json" 2>"$item_dir/$label.err"
}

# Hive の外部テーブルは DROP TABLE では LOCATION 配下のデータが消えない
# （tools/measure/drop-table-format.sh の cleanup-hints.txt と同じ扱い）。
record_cleanup_hint() {
  echo "$1" >>"$RUN_DIR/cleanup-hints.txt"
}

# 後始末の DROP TABLE/VIEW IF EXISTS を投げるだけ（結果は見ない。ベストエフォート）。
best_effort_drop() {
  local kind=$1 name=$2 catalog=$3 database=$4
  athena_cli start-query-execution \
    --query-string "DROP $kind IF EXISTS $name" \
    --query-execution-context "Catalog=$catalog,Database=$database" \
    --client-request-token "$(new_token)" \
    >/dev/null 2>&1 || true
}
