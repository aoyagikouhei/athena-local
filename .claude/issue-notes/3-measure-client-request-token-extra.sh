#!/usr/bin/env bash
# 本物の Athena で、1回目の実測（3-measure-client-request-token.sh）で測れなかった4項目
# だけを測る補助スクリプト（issue #3）。
#
# 1回目の実測でわかったこと（.claude/issue-notes/3.md の「実測の結果」参照）:
#   - トークンの長さの境界とトークン無しは、実測を行ったホストに python3 + botocore が
#     無く、丸ごと skip された。
#   - 「実行中」の再送と CANCELLED の後の再送は、既定の LONG_QUERY_SQL
#     （UNNEST(sequence(1, 5000)) 同士の CROSS JOIN、2500万行）が速すぎて、2回目を
#     投げる前や stop-query-execution を送る前に SUCCEEDED になってしまい、測れなかった。
#   - WorkGroup を変えたときの衝突は、実在する別ワークグループ（WORKGROUP2）が無く
#     skip された。
#
# このスクリプトはこの3点だけをやり直す。それ以外（QueryString / Database /
# OutputLocation の衝突・構文エラーのトークン使い回し・SUCCEEDED / FAILED の後の再送・
# トークンの有効期間）は1回目で測れているので、ここでは測らない。
#
# 使い方:
#   DB=<データベース名> OUTPUT=s3://<バケット>/<プレフィックス>/ \
#     WORKGROUP2=<実在する別WG名> \
#     bash 3-measure-client-request-token-extra.sh
#
# 必須の環境変数（どちらか片方でも無ければ、何も実行せず使い方を出して終了する）:
#   DB      StartQueryExecution の QueryExecutionContext.Database に使うデータベース名
#   OUTPUT  StartQueryExecution の ResultConfiguration.OutputLocation（s3://bucket/prefix/）
#
# 任意の環境変数:
#   REGION          既定 ap-northeast-1
#   WORKGROUP       既定 primary
#   WORKGROUP2      WorkGroup を変えたときの衝突（項目(d)）を測るための、実在する別の
#                    ワークグループ名。省略するとその項目だけ skip する
#   QUERY_BASELINE  軽い基準クエリ（トークンの長さ境界・WorkGroup 差分の測定に使う）。
#                    既定 "SELECT 1"
#   LONG_QUERY_SQL  「実行中」の再送と CANCELLED の後の再送に使う、重いクエリ。既定は
#                    UNNEST(sequence(1, 30000)) 同士の CROSS JOIN（9億行を数えるだけ）で、
#                    S3 上のテーブルは一切スキャンしない（スキャン量0バイト = Athena の
#                    最小課金のみ）。それでも速すぎる／遅すぎる場合は差し替える
#   POLL_TIMEOUT    GetQueryExecution のポーリング上限秒。既定 180（重いクエリを想定して
#                    本体スクリプトより長め）
#   OUT_DIR         既定 $HOME/athena-client-request-token-measurements
#                    （本体スクリプトと同じ場所。実名が入るのでリポジトリの外に出す）
#
# python3 + botocore が要る（トークンの長さ境界・トークン無しの節だけ）。まず `uv`
# （このリポジトリの外で使われているツール）があれば `uv run --with botocore python3` で
# 都度 botocore 入りの環境を作って動かす。`uv` が無く、システムの python3 にも botocore が
# 無ければ、$RUN_DIR に venv を作って botocore を入れる。それも失敗したら、その節だけ
# skip して summary に「未測定」と書く。
#
# 実行ごとに $OUT_DIR/run-<日時>-extra/ を作り、その中だけに書く。本体スクリプトの
# run-<日時>/ とは混ざらない。
#
# 前回（issue #1, #2, #3 本体）の実測でつまずいた点を踏襲する。
#   - aws が Docker のラッパだと、aws 自身にファイルへ書かせるとコンテナの中に書いて消え、
#     しかも終了コードは 0 になる。常に `aws ... > file` の形でこのシェル自身がリダイレクト
#     する。
#   - バケット名・データベース名・アカウント ID・ワークグループ名などの実名は端末に出さず、
#     ファイルに置くだけにする。summary.txt も実名を含まない形にする。
#   - --debug の生ログや SigV4 の署名には Authorization ヘッダと Access Key ID が入るので、
#     応答側だけを抜いたら生ログは消す。途中で止めても残らないよう trap も張る。
#
# 測る項目。
#   (a) トークン無し・空文字・トークンの長さの境界（31/32/128/129文字）。生 HTTP
#       （3-measure-raw-token.py、本体スクリプトから切り出した独立ファイル）。
#       トークン無しで成功した場合だけ、QueryExecutionId の先頭8桁と GetQueryExecution の
#       State も採る（本物がトークン無しを本当に拒否するかどうかが、issue #3 の判断2の
#       前提になるため）。
#   (b) CANCELLED の後に、同じトークン・同じパラメータで再送したときの挙動。
#   (c) 実行中に、同じトークン・同じパラメータで再送したときの挙動。
#   (b) と (c) は同じ1本の長いクエリで続けて測る: 投げる → 直後に2回目を投げて ID を
#   比較（このとき1回目の State を記録） → 1回目を stop-query-execution で取り消す →
#   CANCELLED を確認してから3回目を投げて ID を比較。CANCELLED にならなかったら、
#   その旨だけ summary に書いて3回目は投げない。
#   (d) WorkGroup を変えたときの衝突（WORKGROUP2 が要る。省略時は skip）。新しいトークンで
#       QUERY_BASELINE を WorkGroup=WORKGROUP（既定 primary）で投げて成功させ、同じ
#       トークン・同じパラメータで WorkGroup だけ WORKGROUP2 に変えて再送する。本体
#       スクリプトの項目2（diff-*）と同じ形で、エラーになれば HTTP ステータス・__type・
#       Message・ErrorCode・AthenaErrorCode を --debug のワイヤから採り、成功すれば ID が
#       同じかを記録する。summary の行名は diff-WorkGroup。
#
# 保存するファイル（すべて $RUN_DIR の中）。
#   raw-token-omit.json / .stdout.txt / .stderr.txt（成功時はさらに raw-token-omit-state.json）
#   raw-token-empty.json / .stdout.txt / .stderr.txt
#   raw-token-len-<31|32|128|129>.json / .stdout.txt / .stderr.txt
#   running-first / running-second / running-first-state                       項目(c)
#   cancelled-first / cancelled-stop / cancelled-third                          項目(b)
#   diff-workgroup-base / diff-workgroup-changed（エラー時はさらに .wire.txt）    項目(d)
#   summary.txt                                    実名を含まない要約。そのまま貼れる。
#
# 課金について: トークンの長さ境界は「SELECT 1」相当、CANCELLED・実行中の再送は
# UNNEST(sequence(...)) の CROSS JOIN で S3 を一切スキャンしない。既定のままなら Athena の
# 最小課金以上はほぼ増えない見込み。ただし LONG_QUERY_SQL を重くするほど、取り消すまでの
# 実行時間は長くなる（課金には効かないが、待ち時間は増える）。テーブルの作成・削除は
# 行わない（DDL を投げない）。

set -uo pipefail

if [ -z "${DB:-}" ] || [ -z "${OUTPUT:-}" ]; then
  cat <<'USAGE'
使い方:
  DB=<データベース名> OUTPUT=s3://<バケット>/<プレフィックス>/ \
    bash 3-measure-client-request-token-extra.sh

DB と OUTPUT は必須です（どちらか片方でも無いと何も実行しません）。
任意の環境変数はスクリプト冒頭のコメントを参照してください。
USAGE
  exit 1
fi

REGION=${REGION:-ap-northeast-1}
WORKGROUP=${WORKGROUP:-primary}
WORKGROUP2=${WORKGROUP2:-}
QUERY_BASELINE=${QUERY_BASELINE:-"SELECT 1"}
LONG_QUERY_SQL=${LONG_QUERY_SQL:-"SELECT count(*) FROM UNNEST(sequence(1, 30000)) AS a(x) CROSS JOIN UNNEST(sequence(1, 30000)) AS b(y)"}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
OUT_DIR=${OUT_DIR:-$HOME/athena-client-request-token-measurements}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW_SCRIPT="$SCRIPT_DIR/3-measure-raw-token.py"
if [ ! -f "$RAW_SCRIPT" ]; then
  echo "見つかりません: $RAW_SCRIPT（3-measure-raw-token.py と同じディレクトリに置いてください）" >&2
  exit 1
fi

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)-extra"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.txt"
: > "$SUMMARY"
echo "出力先: $RUN_DIR"

# 実名（DB・OUTPUT・WORKGROUP・WORKGROUP2、12桁のアカウント ID らしき数列）を summary に
# 書く前にプレースホルダへ置き換える。
mask() {
  local s=$1
  [ -n "$DB" ] && s=${s//$DB/<DB>}
  [ -n "$OUTPUT" ] && s=${s//$OUTPUT/<OUTPUT>}
  [ -n "$WORKGROUP" ] && s=${s//$WORKGROUP/<WORKGROUP>}
  [ -n "$WORKGROUP2" ] && s=${s//$WORKGROUP2/<WORKGROUP2>}
  printf '%s' "$s" | sed -E 's/[0-9]{12}/<ACCOUNT_ID>/g'
}

# 生ログや venv などの中間ファイルは、途中で止めても残らないよう trap で消す。
# venv（.venv-botocore）は botocore 本体だけで秘密は含まないが、ついでに片付ける。
trap 'rm -f "$RUN_DIR"/.tmp-*; rm -rf "$RUN_DIR"/.venv-botocore' EXIT

# ---- python + botocore の実行方法を決める（生 HTTP の項目 (a) だけに要る） -----------

PY_RUNNER=()
if command -v uv >/dev/null 2>&1; then
  PY_RUNNER=(uv run --with botocore python3)
  echo "python 実行方法: uv run --with botocore python3"
elif python3 -c "import botocore.session, botocore.auth, botocore.awsrequest" >/dev/null 2>&1; then
  PY_RUNNER=(python3)
  echo "python 実行方法: システムの python3（botocore は既に入っています）"
else
  echo "uv が無く、システムの python3 にも botocore が無いため、venv を作って botocore を入れます"
  if python3 -m venv "$RUN_DIR/.venv-botocore" > "$RUN_DIR/.tmp-venv-setup.log" 2>&1 \
    && "$RUN_DIR/.venv-botocore/bin/pip" install --quiet botocore >> "$RUN_DIR/.tmp-venv-setup.log" 2>&1; then
    PY_RUNNER=("$RUN_DIR/.venv-botocore/bin/python3")
    echo "python 実行方法: venv に botocore を入れました"
  else
    echo "botocore を用意できませんでした（詳細は破棄済みの一時ログ）。項目 (a) は skip します"
    PY_RUNNER=()
  fi
fi

# ---- 共通のヘルパ ---------------------------------------------------------------------

capture_wire() {
  local label=$1
  shift
  local raw="$RUN_DIR/.$label-debug-raw.tmp"
  "$@" --debug > "$raw" 2>&1
  {
    grep -E 'Response headers:' "$raw"
    grep -A1 -E 'Response body:' "$raw"
    grep -E '"[A-Z]+ / HTTP/[0-9.]+" [0-9]{3}' "$raw"
  } > "$RUN_DIR/$label.wire.txt" 2>/dev/null
  rm -f "$raw"
}

report_wire_error() {
  local label=$1 prefix=$2
  local wire="$RUN_DIR/$label.wire.txt"
  if [ -s "$wire" ]; then
    local http_status errortype dunder_type athena_error_code error_code message
    http_status=$(grep -oE '"[A-Z]+ / HTTP/[0-9.]+" [0-9]{3}' "$wire" | grep -oE '[0-9]{3}$' | head -1)
    errortype=$(grep -oE "'x-amzn-errortype':[[:space:]]*'[^']*'" "$wire" | head -1 | sed -E "s/.*:[[:space:]]*'([^']*)'/\1/")
    dunder_type=$(grep -oiE '"__type"[[:space:]]*:[[:space:]]*"[^"]*"' "$wire" | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
    athena_error_code=$(grep -oiE '"AthenaErrorCode"[[:space:]]*:[[:space:]]*"[^"]*"' "$wire" | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
    error_code=$(grep -oiE '"ErrorCode"[[:space:]]*:[[:space:]]*"[^"]*"' "$wire" | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
    message=$(grep -oiE '"[Mm]essage"[[:space:]]*:[[:space:]]*"[^"]*"' "$wire" | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
    {
      printf '[%s] HTTP ステータス = %s\n' "$prefix" "${http_status:-(採取できず)}"
      printf '[%s] x-amzn-errortype ヘッダ = %s\n' "$prefix" "${errortype:-(採取できず)}"
      printf '[%s] __type = %s\n' "$prefix" "${dunder_type:-(採取できず)}"
      printf '[%s] AthenaErrorCode = %s\n' "$prefix" "${athena_error_code:-(無し)}"
      printf '[%s] ErrorCode = %s\n' "$prefix" "${error_code:-(無し)}"
      printf '[%s] Message/message = %s\n' "$prefix" "$(mask "${message:-(採取できず)}")"
    } >> "$SUMMARY"
  else
    printf '[%s] --debug からのワイヤ形式の採取に失敗（ログ形式差の可能性）\n' "$prefix" >> "$SUMMARY"
  fi
}

extract_cli_error_line() {
  grep -o 'An error occurred ([A-Za-z]*) when calling the [A-Za-z]* operation: .*' "$1" | head -1
}

# start-query-execution（AWS CLI）の応答 JSON から QueryExecutionId を抜く。
extract_id() {
  python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("QueryExecutionId", ""))
except Exception:
    print("")' "$1" 2>/dev/null
}

# 3-measure-raw-token.py が書いた JSON（キーは snake_case）から query_execution_id を抜く。
extract_raw_id() {
  python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("query_execution_id", ""))
except Exception:
    print("")' "$1" 2>/dev/null
}

extract_raw_outcome() {
  python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("outcome", ""))
except Exception:
    print("")' "$1" 2>/dev/null
}

gen_token() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    python3 -c 'import uuid; print(uuid.uuid4())'
  fi
}

make_token_of_length() {
  local n=$1
  local s=""
  while [ ${#s} -lt "$n" ]; do
    s="${s}$(gen_token)"
  done
  printf '%s' "${s:0:$n}"
}

sqe_plain() {
  local label=$1
  shift
  aws athena start-query-execution --region "$REGION" "$@" \
    > "$RUN_DIR/$label.stdout.json" 2> "$RUN_DIR/$label.stderr.txt"
}

sqe_wire() {
  local label=$1
  shift
  capture_wire "$label" aws athena start-query-execution --region "$REGION" "$@"
}

# id が終端状態（SUCCEEDED/FAILED/CANCELLED）になるまで待つ。上限 timeout 秒。
poll_until_terminal() {
  local id=$1 timeout=$2 waited=0 state=""
  while [ "$waited" -lt "$timeout" ]; do
    aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
      > "$RUN_DIR/.tmp-poll.json" 2>/dev/null
    state=$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1]))["QueryExecution"]["Status"]["State"])
except Exception:
    print("")' "$RUN_DIR/.tmp-poll.json" 2>/dev/null)
    case "$state" in
      SUCCEEDED | FAILED | CANCELLED) break ;;
    esac
    state=""
    sleep 2
    waited=$((waited + 2))
  done
  rm -f "$RUN_DIR/.tmp-poll.json"
  printf '%s' "$state"
}

# 今の State だけを1回だけ取って返す（poll しない）。
get_state_once() {
  local id=$1
  aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/.tmp-state-once.json" 2>/dev/null
  local state
  state=$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1]))["QueryExecution"]["Status"]["State"])
except Exception:
    print("")' "$RUN_DIR/.tmp-state-once.json" 2>/dev/null)
  rm -f "$RUN_DIR/.tmp-state-once.json"
  printf '%s' "$state"
}

# 生 HTTP で StartQueryExecution を1回呼ぶ（3-measure-raw-token.py に委譲）。
raw_start_query_execution() {
  local label=$1 token_mode=$2
  local out_json="$RUN_DIR/$label.json"
  "${PY_RUNNER[@]}" "$RAW_SCRIPT" "$REGION" "$DB" "$OUTPUT" "$WORKGROUP" "$QUERY_BASELINE" "$token_mode" "$out_json" \
    > "$RUN_DIR/$label.stdout.txt" 2> "$RUN_DIR/$label.stderr.txt"
}

report_raw_result() {
  local label=$1 prefix=$2
  local json="$RUN_DIR/$label.json"
  if [ ! -s "$json" ]; then
    printf '[%s] 生 HTTP 呼び出しに失敗した（詳細は %s.stdout.txt / .stderr.txt）\n' "$prefix" "$label" >> "$SUMMARY"
    return
  fi
  python3 - "$json" > "$RUN_DIR/.tmp-raw-summary" 2>/dev/null <<'PYEOF'
import json
import sys

path = sys.argv[1]
try:
    d = json.load(open(path))
except Exception as e:
    print("パースに失敗: {!r}".format(e))
    sys.exit(0)

outcome = d.get("outcome")
lines = ["結果 = {}".format(outcome)]
if outcome == "success":
    lines.append("HTTP ステータス = {}".format(d.get("status")))
    lines.append("QueryExecutionId 先頭8桁 = {}".format(str(d.get("query_execution_id", ""))[:8]))
elif outcome == "error":
    body = d.get("body") or ""
    try:
        b = json.loads(body)
    except Exception:
        b = {}
    headers = d.get("headers") or {}
    errtype_header = None
    for k, v in headers.items():
        if k.lower() == "x-amzn-errortype":
            errtype_header = v
    lines.append("HTTP ステータス = {}".format(d.get("status")))
    lines.append("__type = {}".format(b.get("__type")))
    lines.append("Message/message = {}".format(b.get("Message", b.get("message"))))
    lines.append("ErrorCode = {}".format(b.get("ErrorCode")))
    lines.append("AthenaErrorCode = {}".format(b.get("AthenaErrorCode")))
    lines.append("x-amzn-errortype ヘッダ = {}".format(errtype_header))
elif outcome == "no_credentials":
    lines.append("資格情報が見つからず送れなかった（AWS_* の環境変数や ~/.aws/credentials を確認してください）")
else:
    lines.append("例外 = {}".format(d.get("exception")))

print("\n".join(lines))
PYEOF
  while IFS= read -r line; do
    printf '[%s] %s\n' "$prefix" "$(mask "$line")" >> "$SUMMARY"
  done < "$RUN_DIR/.tmp-raw-summary"
  rm -f "$RUN_DIR/.tmp-raw-summary"
}

raw_maybe_stop() {
  local label=$1
  local json="$RUN_DIR/$label.json"
  [ -s "$json" ] || return
  local outcome qid
  outcome=$(extract_raw_outcome "$json")
  if [ "$outcome" = "success" ]; then
    qid=$(extract_raw_id "$json")
    if [ -n "$qid" ]; then
      aws athena stop-query-execution --region "$REGION" --query-execution-id "$qid" >/dev/null 2>&1 || true
    fi
  fi
}

# ---- (a) トークン無し・空文字・長さの境界（生 HTTP） -----------------------------------

if [ "${#PY_RUNNER[@]}" -gt 0 ]; then
  echo "== raw-token-omit (トークン無し、生 HTTP): 実行します"
  raw_start_query_execution raw-token-omit "__OMIT__"
  report_raw_result raw-token-omit raw-token-omit
  # トークン無しで成功したかどうかは判断2の前提になるので、成功時は ID と State も採る。
  omit_outcome=$(extract_raw_outcome "$RUN_DIR/raw-token-omit.json")
  if [ "$omit_outcome" = "success" ]; then
    omit_id=$(extract_raw_id "$RUN_DIR/raw-token-omit.json")
    if [ -n "$omit_id" ]; then
      aws athena get-query-execution --region "$REGION" --query-execution-id "$omit_id" \
        > "$RUN_DIR/raw-token-omit-state.json" 2> "$RUN_DIR/raw-token-omit-state.stderr.txt"
      omit_state=$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1]))["QueryExecution"]["Status"]["State"])
except Exception:
    print("")' "$RUN_DIR/raw-token-omit-state.json" 2>/dev/null)
      printf '[raw-token-omit] トークン無しでも成功した。QueryExecutionId 先頭8桁=%s, State=%s\n' "${omit_id:0:8}" "${omit_state:-(採取できず)}" >> "$SUMMARY"
    fi
  fi
  raw_maybe_stop raw-token-omit

  echo "== raw-token-empty (空文字、生 HTTP): 実行します"
  raw_start_query_execution raw-token-empty ""
  report_raw_result raw-token-empty raw-token-empty
  raw_maybe_stop raw-token-empty

  for n in 31 32 128 129; do
    label="raw-token-len-$n"
    echo "== $label: 実行します"
    token=$(make_token_of_length "$n")
    raw_start_query_execution "$label" "$token"
    report_raw_result "$label" "$label"
    raw_maybe_stop "$label"
  done
else
  echo "== raw-token-* (生 HTTP 経由の項目): skip (botocore を用意できませんでした)"
  printf '[raw-token] skip (uv も botocore も使えなかったため未測定)\n' >> "$SUMMARY"
fi

# ---- (b)・(c) 実行中の再送と CANCELLED の後の再送（同じ1本のクエリで続けて測る） -------

echo "== running/cancelled-after-reuse: 実行します"
token=$(gen_token)
sqe_plain running-first --client-request-token "$token" \
  --query-string "$LONG_QUERY_SQL" \
  --query-execution-context "Database=$DB" \
  --result-configuration "OutputLocation=$OUTPUT" \
  --work-group "$WORKGROUP"
if [ $? -ne 0 ]; then
  err_line=$(extract_cli_error_line "$RUN_DIR/running-first.stderr.txt")
  printf '[running/cancelled] 1回目の呼び出しが失敗したため (b)(c) は skip。CLI エラー = %s\n' "$(mask "$err_line")" >> "$SUMMARY"
else
  first_id=$(extract_id "$RUN_DIR/running-first.stdout.json")

  # (c) 実行中の再送: stop する前に、間を置かずすぐ2回目を投げる。
  sqe_plain running-second --client-request-token "$token" \
    --query-string "$LONG_QUERY_SQL" \
    --query-execution-context "Database=$DB" \
    --result-configuration "OutputLocation=$OUTPUT" \
    --work-group "$WORKGROUP"
  running_second_rc=$?
  # 2回目を投げた直後の1回目の State を記録してから、ID を比べる。
  state_now=$(get_state_once "$first_id")
  printf '[running] 2回目を投げた直後の1回目の State = %s\n' "${state_now:-(採取できず)}" >> "$SUMMARY"
  if [ "$running_second_rc" -eq 0 ]; then
    second_id=$(extract_id "$RUN_DIR/running-second.stdout.json")
    if [ -n "$first_id" ] && [ "$first_id" = "$second_id" ]; then
      printf '[running] 実行中に同じトークンで呼ぶと同じ QueryExecutionId が返った\n' >> "$SUMMARY"
    else
      printf '[running] 実行中に同じトークンで呼ぶと違う QueryExecutionId が返った\n' >> "$SUMMARY"
    fi
  else
    err_line=$(extract_cli_error_line "$RUN_DIR/running-second.stderr.txt")
    printf '[running] 2回目の呼び出しがエラー = %s\n' "$(mask "$err_line")" >> "$SUMMARY"
  fi

  # (b) CANCELLED の後の再送: 1回目を取り消す。
  aws athena stop-query-execution --region "$REGION" --query-execution-id "$first_id" \
    > "$RUN_DIR/cancelled-stop.stdout.txt" 2> "$RUN_DIR/cancelled-stop.stderr.txt"
  final_state=$(poll_until_terminal "$first_id" "$POLL_TIMEOUT")
  printf '[cancelled] 1回目の最終 State = %s\n' "${final_state:-(ポーリング上限到達)}" >> "$SUMMARY"

  if [ "$final_state" = "CANCELLED" ]; then
    sqe_plain cancelled-third --client-request-token "$token" \
      --query-string "$LONG_QUERY_SQL" \
      --query-execution-context "Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" \
      --work-group "$WORKGROUP"
    if [ $? -eq 0 ]; then
      third_id=$(extract_id "$RUN_DIR/cancelled-third.stdout.json")
      if [ -n "$first_id" ] && [ "$first_id" = "$third_id" ]; then
        printf '[cancelled] CANCELLED の後に同じトークンで呼ぶと同じ QueryExecutionId が返った\n' >> "$SUMMARY"
      else
        printf '[cancelled] CANCELLED の後に同じトークンで呼ぶと違う QueryExecutionId が返った\n' >> "$SUMMARY"
        # 新しい実行が作られていたら、後片付けとして取り消しておく。
        [ -n "$third_id" ] && aws athena stop-query-execution --region "$REGION" --query-execution-id "$third_id" >/dev/null 2>&1 || true
      fi
    else
      err_line=$(extract_cli_error_line "$RUN_DIR/cancelled-third.stderr.txt")
      printf '[cancelled] CANCELLED の後の再送がエラー = %s\n' "$(mask "$err_line")" >> "$SUMMARY"
      sqe_wire cancelled-third --client-request-token "$token" \
        --query-string "$LONG_QUERY_SQL" \
        --query-execution-context "Database=$DB" \
        --result-configuration "OutputLocation=$OUTPUT" \
        --work-group "$WORKGROUP"
      report_wire_error cancelled-third cancelled-third
    fi
  else
    printf '[cancelled] 想定していた CANCELLED にならなかった（State=%s）ため、再送は行わない\n' "${final_state:-不明（ポーリング上限到達）}" >> "$SUMMARY"
  fi
fi

# ---- (d) WorkGroup を変えたときの衝突 --------------------------------------------------

if [ -n "$WORKGROUP2" ]; then
  echo "== diff-workgroup: 実行します"
  token=$(gen_token)
  sqe_plain diff-workgroup-base --client-request-token "$token" \
    --query-string "$QUERY_BASELINE" \
    --query-execution-context "Database=$DB" \
    --result-configuration "OutputLocation=$OUTPUT" \
    --work-group "$WORKGROUP"
  if [ $? -ne 0 ]; then
    err_line=$(extract_cli_error_line "$RUN_DIR/diff-workgroup-base.stderr.txt")
    printf '[diff-WorkGroup] 基準呼び出し自体が失敗したため skip。CLI エラー = %s\n' "$(mask "$err_line")" >> "$SUMMARY"
  else
    base_id=$(extract_id "$RUN_DIR/diff-workgroup-base.stdout.json")

    sqe_plain diff-workgroup-changed --client-request-token "$token" \
      --query-string "$QUERY_BASELINE" \
      --query-execution-context "Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" \
      --work-group "$WORKGROUP2"
    if [ $? -eq 0 ]; then
      changed_id=$(extract_id "$RUN_DIR/diff-workgroup-changed.stdout.json")
      if [ -n "$changed_id" ] && [ "$base_id" = "$changed_id" ]; then
        printf '[diff-WorkGroup] WorkGroup を変えても成功し、QueryExecutionId は同じだった（不一致は検出されなかった）\n' >> "$SUMMARY"
      else
        printf '[diff-WorkGroup] WorkGroup を変えると成功したが、QueryExecutionId は違った（不一致エラーにはならなかった）\n' >> "$SUMMARY"
      fi
    else
      err_line=$(extract_cli_error_line "$RUN_DIR/diff-workgroup-changed.stderr.txt")
      printf '[diff-WorkGroup] WorkGroup を変えると CLI エラー = %s\n' "$(mask "$err_line")" >> "$SUMMARY"
      sqe_wire diff-workgroup-changed --client-request-token "$token" \
        --query-string "$QUERY_BASELINE" \
        --query-execution-context "Database=$DB" \
        --result-configuration "OutputLocation=$OUTPUT" \
        --work-group "$WORKGROUP2"
      report_wire_error diff-workgroup-changed diff-WorkGroup
    fi
  fi
else
  echo "== diff-workgroup: skip (WORKGROUP2 が未設定)"
  printf '[diff-WorkGroup] skip (WORKGROUP2 が未設定)\n' >> "$SUMMARY"
fi

echo
echo "完了しました。"
echo "実名を含まない要約: $SUMMARY"
echo "中身のファイルは $RUN_DIR にあります。リポジトリには入れないでください。"

# 実行例（実在する別ワークグループがあれば WORKGROUP2 も渡すと項目(d)も測れる）:
#   WORKGROUP2=analytics DB=your_db OUTPUT=s3://your-bucket/prefix/ \
#     bash 3-measure-client-request-token-extra.sh
