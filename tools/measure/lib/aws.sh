#!/usr/bin/env bash
# aws CLI 呼び出しの下回り: 一時的な失敗の見分け・再試行、S3 の取得、状態の待ち。
# describe-extended.sh:326-394, :550-645（#275）から移植。呼び出し元（run.sh の
# run_query・athena_call）は素の `aws …` の形で呼ぶ（DRY_RUN=1 のときは PATH の先頭の
# 偽 aws に化ける。`command aws` や絶対パスにしない）。

# 名前解決・接続などの一時的な失敗だけを見分ける。実際の API エラー（構文エラーや
# 権限エラーなど）はここに一致させない。一致しなければ 1 回で確定させる。
is_transient_error() {
  [ -s "$1" ] || return 1
  grep -qiE 'Could not connect|Connection aborted|Connection reset|EndpointConnectionError|Temporary failure in name resolution|Name or service not known|Network is unreachable|Read timed out|[Cc]onnect timeout|ConnectTimeoutError|ReadTimeoutError|SSLError|Broken pipe' "$1"
}

# 任意のコマンドを実行し、標準出力を $1・標準エラーを $2 に取る。名前解決・接続の失敗だけ
# RETRY_MAX 回まで再試行する（StartQueryExecution 以外の aws 呼び出し全部で共通に使う）。
retry_aws() {
  local out=$1 err=$2
  shift 2
  local attempt=1
  while :; do
    if "$@" > "$out" 2> "$err"; then
      rm -f "$err"
      return 0
    fi
    if [ "$attempt" -ge "$RETRY_MAX" ] || ! is_transient_error "$err"; then
      return 1
    fi
    echo "== 一時的な失敗とみて ${RETRY_DELAY} 秒後に再試行します（試行 $attempt/$RETRY_MAX）: $*" >&2
    sleep "$RETRY_DELAY"
    attempt=$((attempt + 1))
  done
}

# S3 のオブジェクトを手元のファイルに取る。書き込むのはこのシェル（リダイレクト）。
fetch() {
  local src=$1 dest=$2 err=$3
  if retry_aws "$dest" "$err" aws s3 cp "$src" - --region "$REGION"; then
    [ -s "$dest" ] || [ ! -s "$err" ]
  else
    rm -f "$dest"
    return 1
  fi
}

# head-object の応答を手元のファイルに取る。src は s3://bucket/key の形。
head_object() {
  local src=$1 dest=$2 err=$3
  local rest=${src#s3://} bucket key
  bucket=${rest%%/*}
  key=${rest#*/}
  if retry_aws "$dest" "$err" aws s3api head-object --region "$REGION" --bucket "$bucket" --key "$key"; then
    return 0
  fi
  rm -f "$dest"
  return 1
}

# head-object の応答から ContentType を取る。
content_type_of() {
  [ -s "$1" ] || { echo "-"; return; }
  python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("ContentType") or "-")
except Exception:
    print("-")' "$1"
}

# OutputLocation の末尾の拡張子だけを返す（"." が無ければ none。実名は含まない）。
ext_of() {
  local loc=$1 tail
  [ -n "$loc" ] || { echo "-"; return; }
  tail=${loc##*/}
  case "$tail" in
    *.*) echo "${tail##*.}" ;;
    *) echo "none" ;;
  esac
}

# 今の State だけを1回取って返す（待たない）。
get_state_once() {
  local id=$1 state
  aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/.tmp-state-once.json" 2>/dev/null
  state=$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1]))["QueryExecution"]["Status"]["State"])
except Exception:
    print("")' "$RUN_DIR/.tmp-state-once.json" 2>/dev/null)
  rm -f "$RUN_DIR/.tmp-state-once.json"
  printf '%s' "$state"
}

# 終端状態（SUCCEEDED / FAILED / CANCELLED）になるまで待つ。上限 POLL_TIMEOUT 秒。
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

# start_query_retry が記録した試行回数を読む（無ければ 0）。
read_attempts() {
  cat "$RUN_DIR/.tmp-attempts-$1" 2>/dev/null || echo 0
}

# StartQueryExecution を投げる。名前解決・接続系の失敗だけを RETRY_MAX 回まで再試行する
# （実際の SQL エラーは1回で確定させる）。context が空文字なら --query-execution-context
# を付けない（run.sh の run_ctx_string が ctx=none をここに渡す）。
# 呼ぶたびに START_CALL_FILE に1行積み、試行回数は $RUN_DIR/.tmp-attempts-<id> に記録する
# （read_attempts で読む）。
start_query_retry() {
  local item_id=$1 sql=$2 context=$3
  local attempt=1 qid
  while :; do
    echo "$item_id" >> "$START_CALL_FILE"
    if [ -n "$context" ]; then
      qid=$(aws athena start-query-execution --region "$REGION" \
        --query-string "$sql" \
        --query-execution-context "$context" \
        --result-configuration "OutputLocation=$OUTPUT" \
        --query QueryExecutionId --output text 2> "$RUN_DIR/$item_id.start.err")
    else
      qid=$(aws athena start-query-execution --region "$REGION" \
        --query-string "$sql" \
        --result-configuration "OutputLocation=$OUTPUT" \
        --query QueryExecutionId --output text 2> "$RUN_DIR/$item_id.start.err")
    fi
    if [ -n "${qid:-}" ]; then
      echo "$attempt" > "$RUN_DIR/.tmp-attempts-$item_id"
      printf '%s' "$qid"
      return 0
    fi
    if [ "$attempt" -ge "$RETRY_MAX" ] || ! is_transient_error "$RUN_DIR/$item_id.start.err"; then
      echo "$attempt" > "$RUN_DIR/.tmp-attempts-$item_id"
      return 1
    fi
    echo "== $item_id: 一時的な失敗とみて ${RETRY_DELAY} 秒後に再試行します（試行 $attempt/$RETRY_MAX）" >&2
    sleep "$RETRY_DELAY"
    attempt=$((attempt + 1))
  done
}
