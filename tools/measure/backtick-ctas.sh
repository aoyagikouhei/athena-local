#!/usr/bin/env bash
# issue #293 で作成。
#
# 背景（#293）: #273 の先行実測（unquoted-ddl.sh の ROUND=19、2026-09-27、生データ
# $HOME/athena-unquoted-ddl-measurements/run-20260927-001229 の f11）で見つけた本物との差を
# 掘り下げる。S3 Tables の Context（Catalog=s3tablescatalog/<bucket>,Database=<ns>）の
# ``CREATE TABLE `<無い名前空間>`.<t> AS SELECT 1 AS n`` を投げると、本物は**開始時に**
# `Creation of tables using select query uses a different syntax. Please see
# https://docs.aws.amazon.com/athena/latest/ug/ctas.html`（InvalidRequestException、
# AthenaErrorCode MALFORMED_QUERY）で弾いた。過去の生データでこの文言が出たのは f11 だけ
# （同じラウンドの f1〜f10・f12 は無引用／二重引用符で、いずれも開始はできて
# NOT_FOUND: Schema ... not found で FAILED になった）。athena-local はこの文言を持っていない。
#
# このスクリプトが確かめること: どのバッククォートの形・どの QueryExecutionContext・
# どの文の種類でこの「別の構文」の文言になるか。CTAS でない CREATE TABLE のバッククォートの
# 表名は #248 の s11 など別の判定（unquoted_ddl::create_table::hive）で、ここでは対照として
# 測るだけ（別判定に触らない）。
#
# 雛形: tools/measure/column-not-found.sh（preflight・DB の自動選択・hide によるマスク・
# start_query_retry・項目の skip・summary・trap の後始末・FAILED なのに本体があれば中身を
# 保存）の関数をほぼそのまま流用し、tools/measure/unquoted-ddl.sh の S3 Tables の Context の
# 扱い（S3TABLES_CATALOG・S3TABLES_NS、Context を指定して投げる run_in_ctx、作る Context と
# 消す Context の組の後始末 PENDING_DROPS_CTX、実名のマスク）を足した。
#
# 使い方:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns \
#     bash tools/measure/backtick-ctas.sh
#   （資格情報はホストのシェルで AWS_ACCESS_KEY_ID などを export してから。または ~/.aws/credentials）
#   DB を省略するか実在しなければ、ListDatabases の一覧の 1 件目を使う。
#   S3TABLES_CATALOG・S3TABLES_NS が無いか、その Context の SELECT 1 が通らなければ、
#   S3 Tables を使う項目はすべて未測定にし、既定の Context（<DEF>）の項目だけ測る。
#
# 必須の環境変数:
#   OUTPUT              結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける）。
#
# 任意の環境変数:
#   DB                  データベース名。省略か実在しなければ ListDatabases の 1 件目。
#   CATALOG             既定 AwsDataCatalog
#   REGION              既定 ap-northeast-1
#   OUT_DIR             既定 ${DEV_HOST_HOME:-$HOME}/athena-backtick-ctas-measurements
#                       （実名が入るのでリポジトリの外に出す）
#   POLL_TIMEOUT        終端状態を待つ上限（秒）。既定 180
#   RETRY_MAX           名前解決・接続の一時的な失敗を再試行する回数。既定 4
#   RETRY_DELAY         再試行の間隔（秒）。既定 5
#   S3TABLES_CATALOG    S3 Tables のカタログ名（例 s3tablescatalog/my-bucket）。無ければ
#                       S3 Tables の項目はすべて未測定。
#   S3TABLES_NS         S3 Tables の名前空間（実在するもの）。無ければ同上。
#
# 準備（すべて最後に消す。trap でも保険をかける）:
#   <S3CTX> に <P>_s3   CREATE TABLE <P>_s3 (n int)（S3 Tables の Context。#273 の実測で
#                       成功すると確認済みの形）。S3 Tables が使えないときは作らない。
#   <DEF> に <P>_real   CREATE TABLE <DB>.<P>_real AS SELECT 1 AS n（既定の Context）。
# 受理された CTAS・CREATE TABLE はその場で、作った Context で DROP する（trap でも保険）。
#
# 測る項目（ID は b で始める。<S3CTX>=Catalog=<S3TABLES_CATALOG>,Database=<S3TABLES_NS>、
# <DEF>=Catalog=AwsDataCatalog,Database=<DB>。無い名前空間・DB は乱数入りの接頭辞を付けた
# nosuchns293、作る表の名前は項目ごとに別名）:
#   b1        対照: f11 の再現。<S3CTX> で `` CREATE TABLE `<無い名前空間>`.<t> AS SELECT 1 AS n ``
#   b2        対照: <S3CTX> のバッククォート無し `` CREATE TABLE <NS>.<t> AS SELECT 1 AS n ``（成功見込み）
#   b3〜b7    <S3CTX> のバッククォートの位置（実在する名前空間 `` `<NS>`.<t> ``、表名だけ
#             `` <NS>.`<t>` ``、1 部 `` `<t>` ``、両方 `` `<NS>`.`<t>` ``、3 部
#             `` "<S3TABLES_CATALOG>".`<NS>`.<t> ``）
#   b8〜b11   <DEF> のバッククォート（`` `<DB>`.<t> ``・``<DB>.`<t>` ``・`` `<t>` ``・
#             `` `<無いDB>`.<t> ``）
#   b12〜b23  CTAS の変種（<S3CTX>、無い名前空間・実在する名前空間の両方）: IF NOT EXISTS、
#             小文字の create table、先頭のコメント、WITH (format='PARQUET')、
#             AS (SELECT ...)、WITH NO DATA
#   b24〜b25  CTAS でない形との対照（<S3CTX>、実在する名前空間・無い名前空間）
#   b26〜b28  CTAS 以外の文でバッククォート（<S3CTX> の SELECT・INSERT、<DEF> の SELECT）
# 詳しい対応（ID・文・確かめる点）はノート .claude/issue-notes/293.md の「項目 ID の一覧」に書く。
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く。
#
# 項目ごとに次を保存する（取れたものだけ）。
#   <label>.context.txt         投げた QueryExecutionContext
#   <label>.sql                 投げた SQL そのもの（**実名を含む**）
#   <label>.start.err           StartQueryExecution の標準エラー（開始時に弾かれた証拠）
#   <label>.execution.json      GetQueryExecution の応答
#   <label>.execution.err       GetQueryExecution の標準エラー
#   <label>.reason.txt          StateChangeReason と AthenaError（**実名を含みうる**）
#   <label>.body.err            結果ファイル本体の HeadObject が失敗した証拠（無いことの証拠）
#   <label>.metadata.err        .metadata の HeadObject が失敗した証拠（無いことの証拠）
#   <label>.body.txt            FAILED なのに結果ファイル本体があったときの中身（**実名を含みうる**）
#   available-databases.txt     DB が指定/実在しなかったときに使った ListDatabases の一覧
#
# 最後に summary.tsv（機械可読）と summary.txt（そのまま貼れる整形済み）を作る。
# 実名（DB 名・出力先・バケット名・S3 Tables のカタログ／名前空間・接頭辞の乱数・アカウント ID）は伏せる。
#
# 課金について: 作る表は <P>_s3・<P>_real（どちらも小さい）。CTAS の各項目は 1 行だけの
# SELECT で、想定どおり開始時に弾かれれば課金対象にならない。想定に反して開始できて
# FAILED になっても、スキャンは 1 行の定数か <P>_s3・<P>_real の小さい表だけ。
#
# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。
#   実測値は工場出荷時の既定とは限らない。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください}"
DB=${DB:-}
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_DIR=${OUT_DIR:-${DEV_HOST_HOME:-$HOME}/athena-backtick-ctas-measurements}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}
S3TABLES_CATALOG=${S3TABLES_CATALOG:-}
S3TABLES_NS=${S3TABLES_NS:-}

# S3TABLES_CATALOG が s3tablescatalog/<バケット> の形なら、そのバケット名（伏せ字用）。
S3TABLES_BUCKET=""
case "$S3TABLES_CATALOG" in
  */*) S3TABLES_BUCKET=${S3TABLES_CATALOG#*/} ;;
esac

# 実行のたびに変わる乱数入りの接頭辞。作る対象は項目ごとに <PREFIX>_b1 のように別名。
RAND_SUFFIX=$(printf '%04x' $((RANDOM % 65536)))
PROBE_PREFIX="athena_local_probe_293_${RAND_SUFFIX}"
new_name() { printf '%s_%s' "$PROBE_PREFIX" "$1"; }
NOPE_NS=$(new_name nosuchns293)
NOPE_DB=$(new_name nosuchns293db)
REAL=$(new_name real)
S3PROBE=$(new_name s3)

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\tstatement_type\tsubstatement_type\tstart_message\tstart_athena_error_code\terror_category\terror_type\tretryable\terror_message\treason_line\tbody_exists\tmetadata_exists\tquery_echoed\tnote\n' > "$SUMMARY"
echo "出力先: $RUN_DIR"

# StartQueryExecution を実際に呼んだ回数（再試行も含む）。summary.txt の冒頭に出す。
START_CALL_FILE="$RUN_DIR/.start-calls"
: > "$START_CALL_FILE"

DEFAULT_CTX="Catalog=$CATALOG,Database=$DB"
# QueryExecutionContext の既定値。run_in_ctx が呼び出しのたびに差し替える。
QE_CONTEXT="$DEFAULT_CTX"

# 実在する表のセットアップに着手したかどうか。trap の後始末に使う。
REAL_ATTEMPTED=0; REAL_OK=0
S3_AVAILABLE=0
S3PROBE_ATTEMPTED=0; S3PROBE_OK=0

# 想定に反して CREATE TABLE が受理され、まだ消せていない「DROP を投げる
# QueryExecutionContext|そのまま DROP に使える名前の式（バッククォート・引用符込み）」の集合。
# キーは最後の `|` で区切る（tools/measure/unquoted-ddl.sh の PENDING_DROPS_CTX と同じ考え方）。
declare -A PENDING_DROPS_CTX=()

# --- 後始末 -------------------------------------------------------------------

# trap の後始末で 1 文だけ、指定した QueryExecutionContext で投げる（結果は確かめない）。
cleanup_drop_in_ctx() {
  local ctx=$1 sql=$2
  aws athena start-query-execution --region "$REGION" \
    --query-string "$sql" \
    --query-execution-context "$ctx" \
    --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
}

cleanup() {
  rm -f "$RUN_DIR"/.tmp-*
  local key
  for key in "${!PENDING_DROPS_CTX[@]}"; do
    cleanup_drop_in_ctx "${key%|*}" "DROP TABLE IF EXISTS ${key##*|}"
  done
  if [ "$S3PROBE_ATTEMPTED" = 1 ] && [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
    cleanup_drop_in_ctx "Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS" \
      "DROP TABLE IF EXISTS $S3PROBE"
  fi
  if [ "$REAL_ATTEMPTED" = 1 ]; then
    cleanup_drop_in_ctx "$DEFAULT_CTX" "DROP TABLE IF EXISTS $DB.$REAL"
  fi
}
trap cleanup EXIT

# --- 実名を伏せる --------------------------------------------------------------

OUTPUT_BUCKET=${OUTPUT#s3://}
OUTPUT_BUCKET=${OUTPUT_BUCKET%%/*}

hide_pairs() {
  local value mark
  while IFS=$'\t' read -r value mark; do
    [ -n "$value" ] && printf '%s\t%s\t%s\n' "${#value}" "$value" "$mark"
  done <<EOF
$DB	<DB>
$OUTPUT	<OUTPUT>
$OUTPUT_BUCKET	<BUCKET>
$PROBE_PREFIX	<PROBE>
$S3TABLES_CATALOG	<S3TABLES_CATALOG>
$S3TABLES_BUCKET	<S3TABLES_BUCKET>
$S3TABLES_NS	<S3TABLES_NS>
${DB^^}	<DB_UPPER>
EOF
}

# 実名をすべて伏せる。長い実名から先に置き換える（入れ子で短い方が先だと一部が残るため。
# tools/measure/unquoted-ddl.sh の hide の注意と同じ）。
hide() {
  local s=$1 value mark
  while IFS=$'\t' read -r _ value mark; do
    s=${s//"$value"/$mark}
  done < <(hide_pairs | sort -t $'\t' -k1,1nr)
  printf '%s' "$s" | sed -E 's/(^|[^0-9])[0-9]{12}([^0-9]|$)/\1<ACCOUNT_ID>\2/g'
}

sanitize() {
  printf '%s' "$1" | tr '\t\n\r' '   ' | cut -c1-300
}

first_err_line() {
  local f=$1 line
  if [ -s "$f" ]; then
    line=$(grep -m1 . "$f")
    sanitize "$(hide "$line")"
  else
    echo "(エラー出力なし)"
  fi
}

# 名前解決・接続などの一時的な失敗だけを見分ける。
is_transient_error() {
  [ -s "$1" ] || return 1
  grep -qiE 'Could not connect|Connection aborted|Connection reset|EndpointConnectionError|Temporary failure in name resolution|Name or service not known|Network is unreachable|Read timed out|[Cc]onnect timeout|ConnectTimeoutError|ReadTimeoutError|SSLError|Broken pipe' "$1"
}

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

write_reason() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception:
    open(sys.argv[2], "w").write("(execution.json を読めませんでした)\n")
    sys.exit(0)
status = d.get("Status", {})
out = ["State: %s" % status.get("State", "")]
out.append("StateChangeReason: %s" % status.get("StateChangeReason", "(無し)"))
err = status.get("AthenaError")
out.append("AthenaError: %s" % ("(無し)" if err is None else json.dumps(err, ensure_ascii=False, indent=2, sort_keys=True)))
open(sys.argv[2], "w").write("\n".join(out) + "\n")' "$1" "$2"
}

reason_first_line() {
  local f=$1 line
  line=$(python3 -c 'import json, sys
try:
    status = json.load(open(sys.argv[1]))["QueryExecution"]["Status"]
except Exception:
    print("")
    sys.exit(0)
reason = status.get("StateChangeReason") or ""
print(reason.splitlines()[0] if reason else "")' "$f" 2>/dev/null)
  if [ -n "$line" ]; then
    sanitize "$(hide "$line")"
  else
    echo "-"
  fi
}

# execution.json から AthenaError の ErrorCategory / ErrorType / Retryable / ErrorMessage を
# タブ区切りで返す（無ければ 4 つとも "-"）。
athena_error_fields_of() {
  python3 -c 'import json, sys
try:
    err = json.load(open(sys.argv[1]))["QueryExecution"]["Status"].get("AthenaError")
except Exception:
    err = None
if err is None:
    print("-\t-\t-\t-")
else:
    def g(k):
        v = err.get(k)
        return "-" if v is None else str(v).replace("\t", " ").replace("\n", " ")
    print("%s\t%s\t%s\t%s" % (g("ErrorCategory"), g("ErrorType"), g("Retryable"), g("ErrorMessage")))' "$1"
}

read_execution_fields() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception:
    print("-\t\t-")
    sys.exit(0)
print("%s\t%s\t%s" % (d.get("StatementType") or "-", d.get("ResultConfiguration", {}).get("OutputLocation", ""), d.get("SubstatementType") or "-"))' "$1"
}

# GetQueryExecution の QueryExecution.Query（本物が保持している送信済みの文字列）を返す。
read_query_field() {
  python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1]))["QueryExecution"].get("Query", ""))
except Exception:
    print("")' "$1" 2>/dev/null
}

# --- ポーリング・再試行 ---------------------------------------------------------

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

read_attempts() {
  cat "$RUN_DIR/.tmp-attempts-$1" 2>/dev/null || echo 0
}

start_query_retry() {
  local label=$1 sql=$2
  local attempt=1 id
  while :; do
    echo "$label" >> "$START_CALL_FILE"
    id=$(aws athena start-query-execution --region "$REGION" \
      --query-string "$sql" \
      --query-execution-context "$QE_CONTEXT" \
      --result-configuration "OutputLocation=$OUTPUT" \
      --query QueryExecutionId --output text 2> "$RUN_DIR/$label.start.err")
    if [ -n "${id:-}" ]; then
      echo "$attempt" > "$RUN_DIR/.tmp-attempts-$label"
      printf '%s' "$id"
      return 0
    fi
    if [ "$attempt" -ge "$RETRY_MAX" ] || ! is_transient_error "$RUN_DIR/$label.start.err"; then
      echo "$attempt" > "$RUN_DIR/.tmp-attempts-$label"
      return 1
    fi
    echo "== $label: 一時的な失敗とみて ${RETRY_DELAY} 秒後に再試行します（試行 $attempt/$RETRY_MAX）" >&2
    sleep "$RETRY_DELAY"
    attempt=$((attempt + 1))
  done
}

# Athena のクエリではない aws 呼び出し（ListDatabases・HeadObject）を、名前解決・接続の
# 一時的な失敗だけ再試行する。
call_retry() {
  local label=$1 outfile=$2
  shift 2
  local attempt=1
  while :; do
    if "$@" > "$outfile" 2> "$RUN_DIR/$label.err"; then
      echo "$attempt" > "$RUN_DIR/.tmp-attempts-$label"
      rm -f "$RUN_DIR/$label.err"
      return 0
    fi
    if [ "$attempt" -ge "$RETRY_MAX" ] || ! is_transient_error "$RUN_DIR/$label.err"; then
      echo "$attempt" > "$RUN_DIR/.tmp-attempts-$label"
      return 1
    fi
    echo "== $label: 一時的な失敗とみて ${RETRY_DELAY} 秒後に再試行します（試行 $attempt/$RETRY_MAX）" >&2
    sleep "$RETRY_DELAY"
    attempt=$((attempt + 1))
  done
}

# --- summary への 1 行 -----------------------------------------------------------

emit_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$SUMMARY"
}

# 項目を未測定として summary に 1 行残す。全体を止めずに次へ進む。
skip() {
  local label=$1 note=$2
  echo "== $label: 未測定（$note）"
  emit_row "$label" SKIPPED - - - - - - - - - - - - "$(sanitize "$note")"
}

# OutputLocation の本体・.metadata が置かれているかだけを HeadObject で確かめる
# （フルの取得はしない。無いことの証拠は $RUN_DIR/<label>.err に残る）。
head_exists() {
  local label=$1 uri=$2 rest bucket key
  [ -n "$uri" ] || { echo "no"; return; }
  rest=${uri#s3://}
  bucket=${rest%%/*}
  key=${rest#*/}
  if call_retry "$label" "$RUN_DIR/.tmp-head-$label.json" \
      aws s3api head-object --region "$REGION" --bucket "$bucket" --key "$key"; then
    echo "yes"
  else
    echo "no"
  fi
}

# ラベルを指定して 1 文を投げる（QE_CONTEXT を使う）。開始できなければ start.err から
# Message・AthenaErrorCode を抜く。開始できたら終端状態まで待って StatementType・
# SubstatementType・AthenaError・結果ファイル本体と .metadata の有無・Query が送ったままかを採る。
run() {
  local label=$1 sql=$2
  local id state stype sub note reason_line loc
  local start_msg="-" start_code="-" err_cat="-" err_type="-" retryable="-" err_msg="-"
  local body_exists="-" meta_exists="-" query_echoed="-"

  printf '%s\n' "$QE_CONTEXT" > "$RUN_DIR/$label.context.txt"
  printf '%s\n' "$sql" > "$RUN_DIR/$label.sql"
  id=$(start_query_retry "$label" "$sql")

  if [ -z "${id:-}" ]; then
    note="attempts=$(read_attempts "$label"); $(first_err_line "$RUN_DIR/$label.start.err")"
    start_msg=$(start_err_message "$RUN_DIR/$label.start.err")
    start_code=$(start_err_code "$RUN_DIR/$label.start.err")
    echo "== $label: 開始できませんでした。AthenaErrorCode=$start_code"
    emit_row "$label" START_FAILED - - "$start_msg" "$start_code" - - - - - - - - \
      "$(sanitize "$note")"
    return 1
  fi

  state=$(poll_until_terminal "$id")

  aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.execution.json" 2> "$RUN_DIR/$label.execution.err"
  write_reason "$RUN_DIR/$label.execution.json" "$RUN_DIR/$label.reason.txt"
  reason_line=$(reason_first_line "$RUN_DIR/$label.execution.json")

  IFS=$'\t' read -r stype loc sub < <(read_execution_fields "$RUN_DIR/$label.execution.json")

  local actual_query
  actual_query=$(read_query_field "$RUN_DIR/$label.execution.json")
  if [ "$actual_query" = "$sql" ]; then
    query_echoed=yes
  else
    query_echoed=no
  fi

  case "$state" in
    FAILED | CANCELLED)
      IFS=$'\t' read -r err_cat err_type retryable err_msg < <(athena_error_fields_of "$RUN_DIR/$label.execution.json")
      err_msg=$(sanitize "$(hide "$err_msg")")
      ;;
  esac

  if [ -n "$loc" ]; then
    body_exists=$(head_exists "$label.body" "$loc")
    meta_exists=$(head_exists "$label.metadata" "${loc}.metadata")
    # FAILED なのに本体が置かれていたら中身も取る（無いはずのデータの確認）。
    # コンテナ内のパスへの書き出しは消えるので、標準出力をシェルでリダイレクトする。
    if [ "$state" = FAILED ] && [ "$body_exists" = yes ]; then
      aws s3 cp --region "$REGION" "$loc" - > "$RUN_DIR/$label.body.txt" 2> "$RUN_DIR/$label.body-cp.err" || true
    fi
  fi

  note="attempts=$(read_attempts "$label")"
  echo "== $label  state=$state  stype=$stype/$sub  error=$err_cat/$err_type  body=$body_exists  metadata=$meta_exists  query_echoed=$query_echoed"
  emit_row "$label" "$state" "$stype" "$sub" "$start_msg" "$start_code" \
    "$err_cat" "$err_type" "$retryable" "$err_msg" "$reason_line" \
    "$body_exists" "$meta_exists" "$query_echoed" "$(sanitize "$note")"
  [ "$state" = SUCCEEDED ]
}

# QueryExecutionContext を $1 に差し替えて run を呼ぶ（tools/measure/unquoted-ddl.sh の
# run_in_ctx と同じ考え方）。
run_in_ctx() {
  local ctx=$1 saved=$QE_CONTEXT rc
  shift
  QE_CONTEXT=$ctx
  run "$@"
  rc=$?
  QE_CONTEXT=$saved
  return "$rc"
}

succeeded() {
  grep -qs "^State: SUCCEEDED" "$RUN_DIR/$1.reason.txt"
}

is_failed() {
  grep -qs "^State: FAILED" "$RUN_DIR/$1.reason.txt"
}

# CREATE TABLE を $ctx で投げ、想定に反して受理されたら同じ $ctx で
# DROP TABLE IF EXISTS <qref> を <label>-cleanup として投げて消す。qref はバッククォート・
# 引用符を含みうる、DROP にそのまま使える式（CREATE の対象と同じ書き方）。
# 後始末が SUCCEEDED になるまで PENDING_DROPS_CTX["<ctx>|<qref>"] を立てておく
# （trap の保険が対象にする組の集合）。CREATE TABLE が失敗したら後始末は未測定の行だけ残す。
run_create_then_drop_ctx() {
  local ctx=$1 label=$2 sql=$3 qref=$4
  local key="$ctx|$qref"
  if run_in_ctx "$ctx" "$label" "$sql"; then
    PENDING_DROPS_CTX[$key]=1
    run_in_ctx "$ctx" "$label-cleanup" "DROP TABLE IF EXISTS $qref"
    if succeeded "$label-cleanup"; then
      unset 'PENDING_DROPS_CTX[$key]'
    fi
  else
    skip "$label-cleanup" "CREATE TABLE が失敗したため後始末不要"
  fi
}

# --- preflight -------------------------------------------------------------------
# ListDatabases（最も軽い読み取り。実能力の確認も兼ねる。command -v ではなく実際に呼ぶ）で
# 疎通と DB の候補一覧を取り、続けて <DEF>・<S3CTX> の SELECT 1 で疎通を確かめる。

DB_CANDIDATES="$RUN_DIR/available-databases.txt"
if call_retry preflight-list-databases "$RUN_DIR/.tmp-list-databases.json" \
    aws athena list-databases --region "$REGION" --catalog-name "$CATALOG"; then
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for db in d.get("DatabaseList", []):
    print(db.get("Name", ""))' "$RUN_DIR/.tmp-list-databases.json" > "$DB_CANDIDATES"
else
  echo
  echo "ListDatabases が通りませんでした。資格情報か CATALOG（$CATALOG）・REGION（$REGION）を確かめてください。"
  echo "理由: $RUN_DIR/preflight-list-databases.err"
  exit 1
fi

if [ -z "$DB" ] || ! grep -qx -- "$DB" "$DB_CANDIDATES"; then
  DB=$(head -1 "$DB_CANDIDATES")
  echo "DB は ListDatabases の 1 件目を使います。一覧: $DB_CANDIDATES（実名を含みます）"
fi
if [ -z "$DB" ]; then
  echo "使えるデータベースがありませんでした。一覧: $DB_CANDIDATES"
  exit 1
fi
DEFAULT_CTX="Catalog=$CATALOG,Database=$DB"
QE_CONTEXT="$DEFAULT_CTX"

if ! run preflight-select1 "SELECT 1"; then
  echo
  echo "疎通確認（<DEF> の SELECT 1）が通りませんでした。理由: $RUN_DIR/preflight-select1.reason.txt"
  echo "（開始すらできなければ $RUN_DIR/preflight-select1.start.err）"
  exit 1
fi

if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  S3_CTX="Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS"
  if run_in_ctx "$S3_CTX" preflight-select1-s3 "SELECT 1"; then
    S3_AVAILABLE=1
  else
    echo "== S3 Tables の Context（<S3CTX>）の SELECT 1 が通りませんでした。S3 Tables を使う項目は未測定にします。"
    echo "   理由: $RUN_DIR/preflight-select1-s3.reason.txt（開始すらできなければ $RUN_DIR/preflight-select1-s3.start.err）"
  fi
else
  echo "== S3TABLES_CATALOG・S3TABLES_NS が未設定です。S3 Tables を使う項目は未測定にします。"
fi

# --- 準備 --------------------------------------------------------------------

REAL_ATTEMPTED=1
if run setup-real "CREATE TABLE $DB.$REAL AS SELECT 1 AS n"; then
  REAL_OK=1
else
  echo "== setup-real: <DEF> の実在する表が作れませんでした。それを使う項目（b28）は未測定にします。"
fi

if [ "$S3_AVAILABLE" = 1 ]; then
  S3PROBE_ATTEMPTED=1
  if run_in_ctx "$S3_CTX" setup-s3 "CREATE TABLE $S3PROBE (n int)"; then
    S3PROBE_OK=1
  else
    echo "== setup-s3: <S3CTX> の実在する表が作れませんでした。それを使う項目（b26・b27）は未測定にします。"
  fi
else
  skip setup-s3 "S3 Tables が未測定のため準備不要"
fi

# --- 1. 対照: f11 の再現とバッククォート無しの対照 ------------------------------------

if [ "$S3_AVAILABLE" = 1 ]; then
  run_create_then_drop_ctx "$S3_CTX" b1 "CREATE TABLE \`$NOPE_NS\`.$(new_name b1) AS SELECT 1 AS n" "\`$NOPE_NS\`.$(new_name b1)"
  run_create_then_drop_ctx "$S3_CTX" b2 "CREATE TABLE $S3TABLES_NS.$(new_name b2) AS SELECT 1 AS n" "$S3TABLES_NS.$(new_name b2)"
else
  for l in b1 b2; do
    skip "$l" "S3 Tables が未測定のため"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

# --- 2. <S3CTX> のバッククォートの位置（実在する名前空間） --------------------------------

if [ "$S3_AVAILABLE" = 1 ]; then
  run_create_then_drop_ctx "$S3_CTX" b3 "CREATE TABLE \`$S3TABLES_NS\`.$(new_name b3) AS SELECT 1 AS n" "\`$S3TABLES_NS\`.$(new_name b3)"
  run_create_then_drop_ctx "$S3_CTX" b4 "CREATE TABLE $S3TABLES_NS.\`$(new_name b4)\` AS SELECT 1 AS n" "$S3TABLES_NS.\`$(new_name b4)\`"
  run_create_then_drop_ctx "$S3_CTX" b5 "CREATE TABLE \`$(new_name b5)\` AS SELECT 1 AS n" "\`$(new_name b5)\`"
  run_create_then_drop_ctx "$S3_CTX" b6 "CREATE TABLE \`$S3TABLES_NS\`.\`$(new_name b6)\` AS SELECT 1 AS n" "\`$S3TABLES_NS\`.\`$(new_name b6)\`"
  run_create_then_drop_ctx "$S3_CTX" b7 "CREATE TABLE \"$S3TABLES_CATALOG\".\`$S3TABLES_NS\`.$(new_name b7) AS SELECT 1 AS n" "\"$S3TABLES_CATALOG\".\`$S3TABLES_NS\`.$(new_name b7)"
else
  for l in b3 b4 b5 b6 b7; do
    skip "$l" "S3 Tables が未測定のため"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

# --- 3. <DEF> のバッククォート ------------------------------------------------------

run_create_then_drop_ctx "$DEFAULT_CTX" b8 "CREATE TABLE \`$DB\`.$(new_name b8) AS SELECT 1 AS n" "\`$DB\`.$(new_name b8)"
run_create_then_drop_ctx "$DEFAULT_CTX" b9 "CREATE TABLE $DB.\`$(new_name b9)\` AS SELECT 1 AS n" "$DB.\`$(new_name b9)\`"
run_create_then_drop_ctx "$DEFAULT_CTX" b10 "CREATE TABLE \`$(new_name b10)\` AS SELECT 1 AS n" "\`$(new_name b10)\`"
run_create_then_drop_ctx "$DEFAULT_CTX" b11 "CREATE TABLE \`$NOPE_DB\`.$(new_name b11) AS SELECT 1 AS n" "\`$NOPE_DB\`.$(new_name b11)"

# --- 4. CTAS の変種（<S3CTX>、無い名前空間・実在する名前空間） -----------------------------

if [ "$S3_AVAILABLE" = 1 ]; then
  run_create_then_drop_ctx "$S3_CTX" b12 "CREATE TABLE IF NOT EXISTS \`$NOPE_NS\`.$(new_name b12) AS SELECT 1 AS n" "\`$NOPE_NS\`.$(new_name b12)"
  run_create_then_drop_ctx "$S3_CTX" b13 "CREATE TABLE IF NOT EXISTS \`$S3TABLES_NS\`.$(new_name b13) AS SELECT 1 AS n" "\`$S3TABLES_NS\`.$(new_name b13)"
  run_create_then_drop_ctx "$S3_CTX" b14 "create table \`$NOPE_NS\`.$(new_name b14) as select 1 as n" "\`$NOPE_NS\`.$(new_name b14)"
  run_create_then_drop_ctx "$S3_CTX" b15 "create table \`$S3TABLES_NS\`.$(new_name b15) as select 1 as n" "\`$S3TABLES_NS\`.$(new_name b15)"
  run_create_then_drop_ctx "$S3_CTX" b16 "/* c */ CREATE TABLE \`$NOPE_NS\`.$(new_name b16) AS SELECT 1 AS n" "\`$NOPE_NS\`.$(new_name b16)"
  run_create_then_drop_ctx "$S3_CTX" b17 "/* c */ CREATE TABLE \`$S3TABLES_NS\`.$(new_name b17) AS SELECT 1 AS n" "\`$S3TABLES_NS\`.$(new_name b17)"
  run_create_then_drop_ctx "$S3_CTX" b18 "CREATE TABLE \`$NOPE_NS\`.$(new_name b18) WITH (format = 'PARQUET') AS SELECT 1 AS n" "\`$NOPE_NS\`.$(new_name b18)"
  run_create_then_drop_ctx "$S3_CTX" b19 "CREATE TABLE \`$S3TABLES_NS\`.$(new_name b19) WITH (format = 'PARQUET') AS SELECT 1 AS n" "\`$S3TABLES_NS\`.$(new_name b19)"
  run_create_then_drop_ctx "$S3_CTX" b20 "CREATE TABLE \`$NOPE_NS\`.$(new_name b20) AS (SELECT 1 AS n)" "\`$NOPE_NS\`.$(new_name b20)"
  run_create_then_drop_ctx "$S3_CTX" b21 "CREATE TABLE \`$S3TABLES_NS\`.$(new_name b21) AS (SELECT 1 AS n)" "\`$S3TABLES_NS\`.$(new_name b21)"
  run_create_then_drop_ctx "$S3_CTX" b22 "CREATE TABLE \`$NOPE_NS\`.$(new_name b22) AS SELECT 1 AS n WITH NO DATA" "\`$NOPE_NS\`.$(new_name b22)"
  run_create_then_drop_ctx "$S3_CTX" b23 "CREATE TABLE \`$S3TABLES_NS\`.$(new_name b23) AS SELECT 1 AS n WITH NO DATA" "\`$S3TABLES_NS\`.$(new_name b23)"
else
  for l in b12 b13 b14 b15 b16 b17 b18 b19 b20 b21 b22 b23; do
    skip "$l" "S3 Tables が未測定のため"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

# --- 5. CTAS でない形との対照（<S3CTX>） -----------------------------------------------

if [ "$S3_AVAILABLE" = 1 ]; then
  run_create_then_drop_ctx "$S3_CTX" b24 "CREATE TABLE \`$S3TABLES_NS\`.$(new_name b24) (n int)" "\`$S3TABLES_NS\`.$(new_name b24)"
  run_create_then_drop_ctx "$S3_CTX" b25 "CREATE TABLE \`$NOPE_NS\`.$(new_name b25) (n int)" "\`$NOPE_NS\`.$(new_name b25)"
else
  for l in b24 b25; do
    skip "$l" "S3 Tables が未測定のため"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

# --- 6. CTAS 以外の文でバッククォート ---------------------------------------------------

if [ "$S3_AVAILABLE" = 1 ] && [ "$S3PROBE_OK" = 1 ]; then
  run_in_ctx "$S3_CTX" b26 "SELECT * FROM \`$S3TABLES_NS\`.$S3PROBE"
  run_in_ctx "$S3_CTX" b27 "INSERT INTO \`$S3TABLES_NS\`.$S3PROBE VALUES (1)"
else
  skip b26 "S3 Tables か <P>_s3 の準備が未測定のため"
  skip b27 "S3 Tables か <P>_s3 の準備が未測定のため"
fi

if [ "$REAL_OK" = 1 ]; then
  run b28 "SELECT * FROM \`$DB\`.$REAL"
else
  skip b28 "<PROBE>_real が作れなかったため未測定"
fi

# --- 後始末: 準備した実在する表を消す ---------------------------------------------------

if [ "$REAL_OK" = 1 ]; then
  run z-drop-real "DROP TABLE IF EXISTS $DB.$REAL"
  if succeeded z-drop-real; then REAL_ATTEMPTED=0; fi
fi
if [ "$S3PROBE_OK" = 1 ]; then
  run_in_ctx "$S3_CTX" z-drop-s3 "DROP TABLE IF EXISTS $S3PROBE"
  if succeeded z-drop-s3; then S3PROBE_ATTEMPTED=0; fi
fi

# --- summary.txt（そのまま貼れる整形済み） ---------------------------------------------

ALL_LABELS="preflight-select1 preflight-select1-s3 setup-real setup-s3"
for l in b1 b2 b3 b4 b5 b6 b7 b8 b9 b10 b11 b12 b13 b14 b15 b16 b17 b18 b19 b20 b21 b22 b23 b24 b25; do
  ALL_LABELS="$ALL_LABELS $l $l-cleanup"
done
ALL_LABELS="$ALL_LABELS b26 b27 b28 z-drop-real z-drop-s3"

write_summary_txt() {
  local txt="$RUN_DIR/summary.txt"
  {
    echo "# issue #293: S3 Tables の Context のバッククォートの名前の CTAS を本物どおり"
    echo "#             開始時に弾くかどうかの実測（#273 の先行実測 f11 で見つけた"
    echo "#             'Creation of tables using select query uses a different syntax' の"
    echo "#             文言が、どのバッククォートの形・どの Context・どの文で出るか）"
    echo "# 実行日時: $(date -Iseconds)"
    echo "# S3 Tables: $([ "$S3_AVAILABLE" = 1 ] && echo "設定あり（S3 Tables を使う項目 b1〜b7・b12〜b27 を測る）" || echo "未測定（S3TABLES_CATALOG・S3TABLES_NS 未設定か疎通不可。<DEF> の項目 b8〜b11・b28 だけ測る）")"
    echo "# StartQueryExecution の見込み本数: 28（S3 Tables 無し。preflight 1（<DEF> の SELECT 1） +"
    echo "#   準備 1（<PROBE>_real） + b8〜b11 4 + b28 1 + 後始末 1）／72（S3 Tables あり。"
    echo "#   preflight 2 + 準備 2 + b1〜b28 28 + 後始末 2。受理された CREATE TABLE ごとに"
    echo "#   その場で消す DROP が 1 本ずつ増える。最大 +25（b1〜b25 のすべてが受理された場合）)。"
    echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
    echo "# DDL・書き込み: <S3CTX> に <PROBE>_s3（CREATE TABLE、0 行）、<DEF> に <PROBE>_real"
    echo "#   （CTAS、1 行）を作って最後に消す。b1〜b25 の CREATE TABLE は、受理されたらその場で"
    echo "#   DROP して消す。b27（INSERT INTO）が受理されれば <PROBE>_s3 に 1 行増えるが、"
    echo "#   その表ごと最後に消す。"
    echo "# 課金: どの表も 0〜1 行で、スキャンが乗るとしてもこの小さな表・定数値が対象。"
    echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
    echo "#   実測値は工場出荷時の既定とは限らない。"
    echo
    if [ "${#PENDING_DROPS_CTX[@]}" -gt 0 ] || [ "$REAL_ATTEMPTED" = 1 ] || [ "$S3PROBE_ATTEMPTED" = 1 ]; then
      echo "## 手で消してください（本編の後始末で消せず、trap のベストエフォートに委ねたもの）"
      [ "$REAL_ATTEMPTED" = 1 ] && echo "- <DEF> の <PROBE>_real（DROP TABLE IF EXISTS で確認）"
      [ "$S3PROBE_ATTEMPTED" = 1 ] && echo "- <S3CTX> の <PROBE>_s3（DROP TABLE IF EXISTS で確認）"
      local key
      for key in "${!PENDING_DROPS_CTX[@]}"; do
        echo "- $(hide "${key##*|}")（Context: $(hide "${key%|*}")。DROP TABLE IF EXISTS で確認）"
      done
      echo
    fi
    echo "## 投げた文（DB 名・テーブル名・S3 Tables の名前は伏せる。実名は各 <label>.sql・<label>.context.txt を参照）"
    local l
    for l in $ALL_LABELS; do
      [ -s "$RUN_DIR/$l.sql" ] || continue
      printf -- '- %s: %s' "$l" "$(sanitize "$(hide "$(cat "$RUN_DIR/$l.sql")")")"
      if [ -s "$RUN_DIR/$l.context.txt" ]; then
        printf '（QueryExecutionContext: %s）' "$(sanitize "$(hide "$(cat "$RUN_DIR/$l.context.txt")")")"
      fi
      echo
    done
    echo
    echo "## 項目ごとの結果（実名は伏せる）"
    printf '%-14s %-13s %-28s %-10s %-8s\n' label state stype/sub body/metadata query_echoed
    tail -n +2 "$SUMMARY" | while IFS=$'\t' read -r label state stype sub start_msg start_code err_cat err_type retryable err_msg reason_line body_exists meta_exists query_echoed note; do
      printf '%-14s %-13s %-28s %-10s %-8s\n' "$label" "$state" "$stype/$sub" "$body_exists/$meta_exists" "$query_echoed"
      if [ "$start_msg" != "-" ]; then
        echo "  start: $start_code $start_msg"
      fi
      if [ "$err_msg" != "-" ]; then
        echo "  error: $err_cat/$err_type retryable=$retryable"
        echo "  message: $err_msg"
      fi
      if [ "$reason_line" != "-" ]; then
        echo "  reason: $reason_line"
      fi
    done
    local f
    for f in "$RUN_DIR"/*.body.txt; do
      [ -e "$f" ] || continue
      echo
      echo "## FAILED なのに置かれた結果ファイル本体の中身: $(basename "$f" .body.txt)（$(wc -c < "$f" | tr -d ' ') バイト。実名は伏せる。先頭 600 文字）"
      hide "$(head -c 600 "$f")" | cat -A | head -20
      echo
    done
  } > "$txt"
  echo "$txt"
}

SUMMARY_TXT=$(write_summary_txt)

echo
echo "完了しました。"
echo "機械可読な一覧: $SUMMARY"
echo "そのまま貼れる整形済みの一覧: $SUMMARY_TXT"
echo "中身のファイルは $RUN_DIR にあります。リポジトリには入れないでください。"
echo "<label>.sql・<label>.reason.txt・<label>.start.err・<label>.context.txt は実名"
echo "（DB 名・テーブル名・S3 Tables のカタログ／名前空間）を含みうるので、貼るときは中身を確かめてください。"
