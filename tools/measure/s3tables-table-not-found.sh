#!/usr/bin/env bash
# issue #294 で作成。
#
# #273 の先行実測（ROUND=19、2026-09-27、tools/measure/unquoted-ddl.sh の生データ
# `$HOME/athena-unquoted-ddl-measurements/run-20260927-001229` の f7）で見つけた差を掘る。
# S3 Tables の Context（Catalog=s3tablescatalog/<bucket>,Database=<ns>）で
# `CREATE TABLE <無い名前空間>.<t> AS SELECT * FROM <ns>.<無い表>` を投げると、本物は開始して
# FAILED になり、理由の中の表名が Trino の内部名の形（
# `"awsdatacatalog$iceberg-aws"."catalog:<アカウント ID>:s3tablescatalog/<bucket>$schema:<ns>".<表>`）
# だった。athena-local は Trino の表名（`iceberg.<ns>.<表>` など）のまま返す。
#
# このスクリプトは、内部名がどの文（CTAS 以外の SELECT・INSERT・EXPLAIN・JOIN 等）・どの名前の
# 書き方（1 部・2 部・3 部・引用符付き・大文字）でも同じ形で出るか、無い列と無い名前空間の
# どちらが先に判定されるか、既定の Context から S3 Tables の表を引いたときも同じ内部名になるかを測る。
#
# 使い方:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns \
#     bash tools/measure/s3tables-table-not-found.sh
#   （資格情報はホストのシェルで AWS_ACCESS_KEY_ID などを export してから。または ~/.aws/credentials）
#   DB を省略するか実在しなければ、ListDatabases の一覧の 1 件目を使う。
#   S3TABLES_CATALOG・S3TABLES_NS が無いか、その Context で SELECT 1 が通らなければ、S3 Tables の
#   項目（t1・t3〜t16）はすべて未測定にし、既定の Context だけの対照（t2）だけを測る。
#
# 必須の環境変数:
#   OUTPUT    結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける）。
#
# 任意の環境変数:
#   DB               データベース名。省略か実在しなければ ListDatabases の 1 件目。
#   CATALOG          既定 AwsDataCatalog
#   REGION           既定 ap-northeast-1
#   S3TABLES_CATALOG S3 Tables のカタログ名（例 s3tablescatalog/your-bucket）。無ければ S3 Tables の項目は未測定
#   S3TABLES_NS      S3TABLES_CATALOG の中の実在する名前空間。無ければ S3 Tables の項目は未測定
#   OUT_DIR          既定 ${DEV_HOST_HOME:-$HOME}/athena-s3tables-table-not-found-measurements
#                    （実名が入るのでリポジトリの外に出す）
#   POLL_TIMEOUT     終端状態を待つ上限（秒）。既定 180
#   RETRY_MAX        名前解決・接続の一時的な失敗を再試行する回数。既定 4
#   RETRY_DELAY      再試行の間隔（秒）。既定 5
#
# 準備（S3 Tables の項目が測れるときだけ。<S3CTX>=Catalog=<S3TABLES_CATALOG>,Database=<S3TABLES_NS>
# で作り、最後に消す。trap でも保険をかける）:
#   <P>_s3   実在する表。`CREATE TABLE <P>_s3 (n int)`（#273 の c1 で S3 Tables の Context で
#            成功すると実測済みの形）の後に 1 行 INSERT する。
#
# 測る項目（ID は t で始める。<S3CTX>=Catalog=<S3TABLES_CATALOG>,Database=<S3TABLES_NS>、
# <DEF>=Catalog=<CATALOG>,Database=<DB>。無い表は nosuch294、無い名前空間は nosuchns294、
# 無い列は nosuch_col）:
#   t1        <S3CTX> の f7 の再現: CREATE TABLE nosuchns294.<t> AS SELECT * FROM <NS>.nosuch294
#   t2        <DEF> の対照: SELECT * FROM <DB>.nosuch294
#   t3〜t6    <S3CTX> の CTAS（書き込む先の名前空間は実在）。無い表を 1 部（t3）・3 部の
#             修飾（t4）・引用符付き（t5）・大文字（t6）で書いた形
#   t7〜t9    <S3CTX> の SELECT。無い表を 1 部（t7）・2 部（t8）・3 部（t9）で書いた形
#   t10       <S3CTX> の INSERT INTO <P>_s3 SELECT * FROM <NS>.nosuch294（書き込む先は実在）
#   t11       <S3CTX> の INSERT INTO nosuch294 VALUES (1)（書き込む先が無い）
#   t12       <S3CTX> の EXPLAIN SELECT * FROM <NS>.nosuch294
#   t13       <S3CTX> の SELECT * FROM <NS>.<P>_s3 JOIN <NS>.nosuch294 ON true
#   t14       <S3CTX> の CREATE TABLE nosuchns294.<t> AS SELECT nosuch_col FROM <NS>.<P>_s3
#             （無い列と無い名前空間のどちらが先に判定されるか）
#   t15       <S3CTX> の CREATE TABLE <NS>.<t> AS SELECT nosuch_col FROM <NS>.<P>_s3
#             （名前空間は実在。無い列の文言。#283 の「or requester is not authorized ...」が付くか）
#   t16       <DEF> の SELECT * FROM "<S3TABLES_CATALOG>".<NS>.nosuch294（既定の Context から見ても
#             内部名になるか）
# 詳しい対応（ID・文・確かめる点）はノート .claude/issue-notes/294.md の「項目 ID の一覧」に書く。
#
# t1・t3〜t6・t14・t15 は CREATE TABLE なので、想定に反して受理されたらその場で DROP して消す
# （PENDING_DROPS_CTX で trap の保険も張る）。
#
# 項目ごとに次を保存する（取れたものだけ）:
#   <label>.sql              投げた SQL そのもの（**実名を含む**）
#   <label>.context.txt      投げた QueryExecutionContext（**実名を含む**）
#   <label>.start.err        StartQueryExecution の標準エラー（開始時に弾かれた証拠）
#   <label>.execution.json   GetQueryExecution の応答
#   <label>.execution.err    GetQueryExecution の標準エラー
#   <label>.reason.txt       StateChangeReason と AthenaError（**実名を含みうる**）
#   <label>.body.err         結果ファイル本体の HeadObject が失敗した証拠（無いことの証拠）
#   <label>.metadata.err     .metadata の HeadObject が失敗した証拠（無いことの証拠）
#   <label>.body.txt         FAILED なのに結果ファイル本体があったときの中身（**実名を含みうる**）
#   available-databases.txt  DB が指定/実在しなかったときに使った ListDatabases の一覧
#
# 最後に summary.tsv（機械可読）と summary.txt（そのまま貼れる整形済み。実名は伏せる）を作る。
#
# 課金について: 準備で作る表 <P>_s3 は 1 行だけ。無い表・無い名前空間・無い列を対象にした項目は
# どれも解析・実行前に落ちる見込みなので、スキャンが乗るとしてもこの 1 行の表が対象。
#
# 要る IAM 権限: athena:StartQueryExecution・athena:GetQueryExecution・athena:ListDatabases・
# s3:GetObject（HeadObject も同じ権限）・s3:PutObject・s3:ListBucket（OUTPUT のバケット）。
# S3 Tables のカタログ・名前空間・表を読み書きする権限（lakeformation・s3tables 側の設定）は、
# S3TABLES_CATALOG・S3TABLES_NS の疎通確認（<S3CTX> の SELECT 1）で確かめる。それが通らない
# ロールでは S3 Tables の項目は自動的に未測定になる。
#
# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。
#   実測値は工場出荷時の既定とは限らない。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください}"
DB=${DB:-}
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
S3TABLES_CATALOG=${S3TABLES_CATALOG:-}
S3TABLES_NS=${S3TABLES_NS:-}
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_DIR=${OUT_DIR:-${DEV_HOST_HOME:-$HOME}/athena-s3tables-table-not-found-measurements}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}

# S3TABLES_CATALOG が s3tablescatalog/<バケット> の形なら、そのバケット名（伏せ字用）。
S3TABLES_BUCKET=""
case "$S3TABLES_CATALOG" in
  */*) S3TABLES_BUCKET=${S3TABLES_CATALOG#*/} ;;
esac

# 実行のたびに変わる乱数入りの接頭辞。作る表の名前だけに使う（無い表・無い名前空間・無い列は
# issue のとおり固定の名前 nosuch294／nosuchns294／nosuch_col を使う。実在しない前提の名前なので
# 乱数を混ぜる必要が無く、実測結果を読むときにそのまま識別できるほうがよい）。
RAND_SUFFIX=$(printf '%04x' $((RANDOM % 65536)))
PROBE_PREFIX="athena_local_probe_294_${RAND_SUFFIX}"
new_name() { printf '%s_%s' "$PROBE_PREFIX" "$1"; }

NOSUCH_TABLE="nosuch294"
NOPE_NS="nosuchns294"
NOSUCH_COL="nosuch_col"

P_S3=$(new_name s3)
T1=$(new_name t1)
T3=$(new_name t3)
T3B=$(new_name t3b)
T4=$(new_name t4)
T5=$(new_name t5)
T6=$(new_name t6)
T14=$(new_name t14)
T15=$(new_name t15)

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\tstatement_type\tsubstatement_type\tstart_message\tstart_athena_error_code\terror_category\terror_type\tretryable\terror_message\treason_line\tbody_exists\tmetadata_exists\tnote\n' > "$SUMMARY"
echo "出力先: $RUN_DIR"

# StartQueryExecution を実際に呼んだ回数（再試行も含む）。summary.txt の冒頭に出す。
START_CALL_FILE="$RUN_DIR/.start-calls"
: > "$START_CALL_FILE"

S3_OK=0
P3_ATTEMPTED=0
P3_OK=0

# t1・t3〜t6・t14・t15（CREATE TABLE）が想定に反して受理され、まだ消せていない
# 「Context|裸のテーブル名」の集合（trap の保険が対象にする組）。
declare -A PENDING_DROPS_CTX=()

# StartQueryExecution に渡す QueryExecutionContext。run_in_ctx で 1 文だけ差し替える。
# DB が決まる（preflight）まで使わない。
QE_CONTEXT=""

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
  if [ "$P3_ATTEMPTED" = 1 ] && [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
    cleanup_drop_in_ctx "Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS" "DROP TABLE IF EXISTS $P_S3"
  fi
}
trap cleanup EXIT

# --- 実名を伏せる --------------------------------------------------------------

OUTPUT_BUCKET=${OUTPUT#s3://}
OUTPUT_BUCKET=${OUTPUT_BUCKET%%/*}

# 伏せる実名と置き換える印を「長さ<TAB>実名<TAB>印」で 1 行ずつ出す（空の実名は出さない）。
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

# 実名をすべて伏せる。長い実名から先に置き換える（S3 Tables のバケット名がカタログ名に
# 入れ子になっているなど、短い方を先に置き換えると長い方が一致しなくなるため）。
hide() {
  local s=$1 value mark
  while IFS=$'\t' read -r _ value mark; do
    s=${s//"$value"/$mark}
  done < <(hide_pairs | sort -t $'\t' -k1,1nr)
  # アカウント ID は前後が数字でない 12 桁の数字として伏せる（内部名の catalog:<ID>: の部分）。
  printf '%s' "$s" | sed -E 's/(^|[^0-9])[0-9]{12}([^0-9]|$)/\1<ACCOUNT_ID>\2/g'
}

sanitize() {
  printf '%s' "$1" | tr '\t\n\r' '   ' | cut -c1-400
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
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$SUMMARY"
}

# 項目を未測定として summary に 1 行残す。全体を止めずに次へ進む。
skip() {
  local label=$1 note=$2
  echo "== $label: 未測定（$note）"
  emit_row "$label" SKIPPED - - - - - - - - - - - "$(sanitize "$note")"
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

# ラベルを指定して 1 文を実行する（QE_CONTEXT に入っている QueryExecutionContext で投げる）。
# 開始できなければ start.err から Message・AthenaErrorCode を抜く。開始できたら終端状態まで
# 待って StatementType・SubstatementType・AthenaError（ErrorCategory・ErrorType・Retryable・
# ErrorMessage）・結果ファイル本体と .metadata の有無を採る。
run() {
  local label=$1 sql=$2
  local id state stype sub note reason_line loc
  local start_msg="-" start_code="-" err_cat="-" err_type="-" retryable="-" err_msg="-"
  local body_exists="-" meta_exists="-"

  printf '%s\n' "$sql" > "$RUN_DIR/$label.sql"
  printf '%s\n' "$QE_CONTEXT" > "$RUN_DIR/$label.context.txt"
  id=$(start_query_retry "$label" "$sql")

  if [ -z "${id:-}" ]; then
    note="attempts=$(read_attempts "$label"); $(first_err_line "$RUN_DIR/$label.start.err")"
    start_msg=$(start_err_message "$RUN_DIR/$label.start.err")
    start_code=$(start_err_code "$RUN_DIR/$label.start.err")
    echo "== $label: 開始できませんでした。AthenaErrorCode=$start_code"
    emit_row "$label" START_FAILED - - "$start_msg" "$start_code" - - - - - - - \
      "$(sanitize "$note")"
    return 1
  fi

  state=$(poll_until_terminal "$id")

  aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.execution.json" 2> "$RUN_DIR/$label.execution.err"
  write_reason "$RUN_DIR/$label.execution.json" "$RUN_DIR/$label.reason.txt"
  reason_line=$(reason_first_line "$RUN_DIR/$label.execution.json")

  IFS=$'\t' read -r stype loc sub < <(read_execution_fields "$RUN_DIR/$label.execution.json")

  case "$state" in
    FAILED | CANCELLED)
      IFS=$'\t' read -r err_cat err_type retryable err_msg < <(athena_error_fields_of "$RUN_DIR/$label.execution.json")
      err_msg=$(sanitize "$(hide "$err_msg")")
      ;;
  esac

  if [ -n "$loc" ]; then
    body_exists=$(head_exists "$label.body" "$loc")
    meta_exists=$(head_exists "$label.metadata" "${loc}.metadata")
    # FAILED なのに本体が置かれていたら中身も取る（コンテナ内のパスへの書き出しは消えるので、
    # 標準出力をシェルでリダイレクトする）。
    if [ "$state" = FAILED ] && [ "$body_exists" = yes ]; then
      aws s3 cp --region "$REGION" "$loc" - > "$RUN_DIR/$label.body.txt" 2> "$RUN_DIR/$label.body-cp.err" || true
    fi
  fi

  note="attempts=$(read_attempts "$label")"
  echo "== $label  state=$state  stype=$stype/$sub  error=$err_cat/$err_type  body=$body_exists  metadata=$meta_exists"
  emit_row "$label" "$state" "$stype" "$sub" "$start_msg" "$start_code" \
    "$err_cat" "$err_type" "$retryable" "$err_msg" "$reason_line" \
    "$body_exists" "$meta_exists" "$(sanitize "$note")"
  [ "$state" = SUCCEEDED ]
}

# QueryExecutionContext を $1 に差し替えて run を 1 回呼ぶ（preflight・S3 Tables の項目で使う）。
run_in_ctx() {
  local ctx=$1 label=$2 saved=$QE_CONTEXT rc
  shift
  QE_CONTEXT=$ctx
  run "$@"
  rc=$?
  QE_CONTEXT=$saved
  return "$rc"
}

# <label>.reason.txt が SUCCEEDED を示していれば真。
succeeded() {
  grep -qs "^State: SUCCEEDED" "$RUN_DIR/$1.reason.txt"
}

# CREATE TABLE を $1 の Context で投げ、想定に反して受理されたら $2 の Context で
# DROP TABLE IF EXISTS <name> を <label>-cleanup として投げて消す（t1・t3〜t6・t14・t15。
# create_ctx と drop_ctx は常に同じ S3 Tables の Context だが、unquoted-ddl.sh の
# run_create_then_drop_ctx と同じ引数の形にして流用しやすくする）。CREATE TABLE が失敗したら
# 後始末は未測定の行だけ残す。
run_create_then_drop_ctx() {
  local create_ctx=$1 drop_ctx=$2 label=$3 sql=$4 name=$5
  local key="$drop_ctx|$name"
  if run_in_ctx "$create_ctx" "$label" "$sql"; then
    PENDING_DROPS_CTX[$key]=1
    run_in_ctx "$drop_ctx" "$label-cleanup" "DROP TABLE IF EXISTS $name"
    if succeeded "$label-cleanup"; then
      unset 'PENDING_DROPS_CTX[$key]'
    fi
  else
    skip "$label-cleanup" "CREATE TABLE が失敗したため後始末不要"
  fi
}

# --- preflight -------------------------------------------------------------------
# ListDatabases（最も軽い読み取り。実能力の確認も兼ねる）で疎通と DB の候補一覧を取り、
# 続けて既定の Context の SELECT 1 でクエリ実行の疎通も確かめる。どちらも通らなければ
# 全体を止める。

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
  echo "疎通確認（SELECT 1）が通りませんでした。理由: $RUN_DIR/preflight-select1.reason.txt"
  echo "（開始すらできなければ $RUN_DIR/preflight-select1.start.err）"
  exit 1
fi

if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  S3_CTX="Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS"
  if run_in_ctx "$S3_CTX" preflight-s3-select1 "SELECT 1"; then
    S3_OK=1
  else
    echo "== S3 Tables の Context（$RUN_DIR/preflight-s3-select1.context.txt。実名を含む）で"
    echo "   SELECT 1 が通りませんでした。S3 Tables の項目はすべて未測定にします。"
  fi
else
  echo "== S3TABLES_CATALOG・S3TABLES_NS が未設定です。S3 Tables の項目はすべて未測定にします。"
fi

# --- 準備: S3 Tables に実在する表 <P>_s3 ----------------------------------------------

if [ "$S3_OK" = 1 ]; then
  P3_ATTEMPTED=1
  if run_in_ctx "$S3_CTX" setup-s3 "CREATE TABLE $P_S3 (n int)"; then
    P3_OK=1
    run_in_ctx "$S3_CTX" setup-s3-insert "INSERT INTO $P_S3 VALUES (1)" || \
      echo "== setup-s3-insert: <P>_s3 への INSERT が失敗しました。表は作れているので続けます。"
  else
    echo "== setup-s3: <P>_s3 が作れませんでした。<P>_s3 を使う項目（t10・t13〜t15）は未測定にします。"
  fi
else
  skip setup-s3 "未測定（S3TABLES_* 未設定または S3 Tables の Context の疎通不可）"
  skip setup-s3-insert "CREATE TABLE を投げていないため未測定"
fi

# --- 1. 対照 ------------------------------------------------------------------------

if [ "$S3_OK" = 1 ]; then
  run_create_then_drop_ctx "$S3_CTX" "$S3_CTX" t1 \
    "CREATE TABLE $NOPE_NS.$T1 AS SELECT * FROM $S3TABLES_NS.$NOSUCH_TABLE" "$NOPE_NS.$T1"
else
  skip t1 "未測定（S3TABLES_* 未設定または S3 Tables の Context の疎通不可）"
  skip t1-cleanup "CREATE TABLE を投げていないため後始末不要"
fi

run_in_ctx "$DEFAULT_CTX" t2 "SELECT * FROM $DB.$NOSUCH_TABLE"

# --- 2. CTAS（書き込む先の名前空間は実在。無い表の書き方） ------------------------------

if [ "$S3_OK" = 1 ]; then
  run_create_then_drop_ctx "$S3_CTX" "$S3_CTX" t3 \
    "CREATE TABLE $S3TABLES_NS.$T3 AS SELECT * FROM $NOSUCH_TABLE" "$S3TABLES_NS.$T3"
  # t3b: f7（t1）と同じ 2 部の無い表を、実在する名前空間に書き込む CTAS で（名前空間の有無だけを変えた対）。
  run_create_then_drop_ctx "$S3_CTX" "$S3_CTX" t3b \
    "CREATE TABLE $S3TABLES_NS.$T3B AS SELECT * FROM $S3TABLES_NS.$NOSUCH_TABLE" "$S3TABLES_NS.$T3B"
  run_create_then_drop_ctx "$S3_CTX" "$S3_CTX" t4 \
    "CREATE TABLE $S3TABLES_NS.$T4 AS SELECT * FROM \"$S3TABLES_CATALOG\".$S3TABLES_NS.$NOSUCH_TABLE" "$S3TABLES_NS.$T4"
  run_create_then_drop_ctx "$S3_CTX" "$S3_CTX" t5 \
    "CREATE TABLE $S3TABLES_NS.$T5 AS SELECT * FROM \"$NOSUCH_TABLE\"" "$S3TABLES_NS.$T5"
  run_create_then_drop_ctx "$S3_CTX" "$S3_CTX" t6 \
    "CREATE TABLE $S3TABLES_NS.$T6 AS SELECT * FROM ${NOSUCH_TABLE^^}" "$S3TABLES_NS.$T6"
else
  for l in t3 t3b t4 t5 t6; do
    skip "$l" "未測定（S3TABLES_* 未設定または S3 Tables の Context の疎通不可）"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

# --- 3. ほかの文（SELECT・INSERT・EXPLAIN・JOIN） ---------------------------------------

if [ "$S3_OK" = 1 ]; then
  run_in_ctx "$S3_CTX" t7 "SELECT * FROM $NOSUCH_TABLE"
  run_in_ctx "$S3_CTX" t8 "SELECT * FROM $S3TABLES_NS.$NOSUCH_TABLE"
  run_in_ctx "$S3_CTX" t9 "SELECT * FROM \"$S3TABLES_CATALOG\".$S3TABLES_NS.$NOSUCH_TABLE"
  # t17: 名前空間ごと無い SELECT（手元の Trino 482 は TABLE_NOT_FOUND ではなく `Schema '<ns>' does not exist`）。
  run_in_ctx "$S3_CTX" t17 "SELECT * FROM $NOPE_NS.$NOSUCH_TABLE"
  if [ "$P3_OK" = 1 ]; then
    run_in_ctx "$S3_CTX" t10 "INSERT INTO $P_S3 SELECT * FROM $S3TABLES_NS.$NOSUCH_TABLE"
  else
    skip t10 "<P>_s3 が作れなかったため未測定"
  fi
  run_in_ctx "$S3_CTX" t11 "INSERT INTO $NOSUCH_TABLE VALUES (1)"
  run_in_ctx "$S3_CTX" t12 "EXPLAIN SELECT * FROM $S3TABLES_NS.$NOSUCH_TABLE"
  if [ "$P3_OK" = 1 ]; then
    run_in_ctx "$S3_CTX" t13 "SELECT * FROM $S3TABLES_NS.$P_S3 JOIN $S3TABLES_NS.$NOSUCH_TABLE ON true"
  else
    skip t13 "<P>_s3 が作れなかったため未測定"
  fi
else
  for l in t7 t8 t9 t17 t10 t11 t12 t13; do
    skip "$l" "未測定（S3TABLES_* 未設定または S3 Tables の Context の疎通不可）"
  done
fi

# --- 4. 順序（無い列と無い名前空間） --------------------------------------------------

if [ "$S3_OK" = 1 ] && [ "$P3_OK" = 1 ]; then
  run_create_then_drop_ctx "$S3_CTX" "$S3_CTX" t14 \
    "CREATE TABLE $NOPE_NS.$T14 AS SELECT $NOSUCH_COL FROM $S3TABLES_NS.$P_S3" "$NOPE_NS.$T14"
  run_create_then_drop_ctx "$S3_CTX" "$S3_CTX" t15 \
    "CREATE TABLE $S3TABLES_NS.$T15 AS SELECT $NOSUCH_COL FROM $S3TABLES_NS.$P_S3" "$S3TABLES_NS.$T15"
else
  for l in t14 t15; do
    if [ "$S3_OK" != 1 ]; then
      skip "$l" "未測定（S3TABLES_* 未設定または S3 Tables の Context の疎通不可）"
    else
      skip "$l" "<P>_s3 が作れなかったため未測定"
    fi
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

# --- 5. 既定の Context から S3 Tables の表を引く ----------------------------------------

if [ "$S3_OK" = 1 ]; then
  run_in_ctx "$DEFAULT_CTX" t16 "SELECT * FROM \"$S3TABLES_CATALOG\".$S3TABLES_NS.$NOSUCH_TABLE"
else
  skip t16 "未測定（S3TABLES_* 未設定または S3 Tables の Context の疎通不可）"
fi

# --- 後始末: 準備した <P>_s3 を消す ----------------------------------------------------

if [ "$P3_ATTEMPTED" = 1 ]; then
  run_in_ctx "$S3_CTX" z-drop-s3 "DROP TABLE IF EXISTS $P_S3"
  if succeeded z-drop-s3; then
    P3_ATTEMPTED=0
  else
    echo "== <P>_s3 を消せませんでした。手で DROP TABLE IF EXISTS してください。"
  fi
fi

# --- summary.txt（そのまま貼れる整形済み） ---------------------------------------------

write_summary_txt() {
  local txt="$RUN_DIR/summary.txt"
  {
    echo "# issue #294: S3 Tables の Context の TABLE_NOT_FOUND の内部名（"
    echo "#   \"awsdatacatalog\$iceberg-aws\".\"catalog:<ACCOUNT_ID>:<S3TABLES_CATALOG>\$schema:<S3TABLES_NS>\".<表>"
    echo "#   の形。#273 の f7 で見た）が、CTAS 以外の文・名前の書き方・既定の Context からの参照でも"
    echo "#   同じ形か、無い列と無い名前空間のどちらが先に判定されるかを実測"
    echo "# 実行日時: $(date -Iseconds)"
    echo "# StartQueryExecution の見込み本数（S3TABLES_* あり）: 23〜31"
    echo "#   （preflight 2（既定の Context の SELECT 1、S3 Tables の Context の SELECT 1）+"
    echo "#   準備 2（<P>_s3 の CREATE・INSERT）+ 主要項目 18（t1〜t17・t3b）+ 後始末 1（<P>_s3 の DROP）。"
    echo "#   t1・t3〜t6・t3b・t14・t15（CREATE TABLE、8 項目）が想定に反して受理されたら、その場で"
    echo "#   消す後始末が最大 8 本増える）。S3TABLES_* が無いか S3 Tables の Context の疎通が"
    echo "#   通らなければ、preflight 1（既定の Context の SELECT 1）+ t2 の 1 本の 2 回だけ。"
    echo "#   このほかに Athena のクエリでない ListDatabases を preflight で 1 回、HeadObject"
    echo "#   （結果ファイル本体・.metadata の有無の確認）を開始できた項目ごとに最大 2 回呼ぶ"
    echo "#   （どちらも上の回数には含めない）。"
    echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
    echo "# DDL・書き込み: S3 Tables の名前空間 <S3TABLES_NS> に表 <P>_s3（CREATE TABLE (n int) +"
    echo "#   INSERT で 1 行）を作り、最後に DROP TABLE で消す。t1・t3〜t6・t14・t15 は CTAS で、"
    echo "#   無い表・無い名前空間・無い列が対象のため失敗する見込みだが、想定に反して受理されたら"
    echo "#   その場で DROP TABLE して消す。"
    echo "# 課金: <P>_s3 は 1 行だけ。ほかの項目は無い表・無い名前空間・無い列を対象にしていて"
    echo "#   解析・実行前に落ちる見込みなので、スキャンが乗るとしてもこの小さな表が対象。"
    echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
    echo "#   実測値は工場出荷時の既定とは限らない。"
    echo
    if [ "${#PENDING_DROPS_CTX[@]}" -gt 0 ] || [ "$P3_ATTEMPTED" = 1 ]; then
      echo "## 手で消してください（本編の後始末で消せず、trap のベストエフォートに委ねたもの）"
      [ "$P3_ATTEMPTED" = 1 ] && echo "- <P>_s3（S3 Tables の Context。DROP TABLE IF EXISTS で確認）"
      local key
      for key in "${!PENDING_DROPS_CTX[@]}"; do
        echo "- $(hide "${key##*|}")（Context: $(hide "${key%|*}")。DROP TABLE IF EXISTS で確認）"
      done
      echo
    fi
    echo "## 項目ごとの結果（実名は伏せる）"
    printf '%-16s %-11s %-16s %-8s %-8s\n' label state stype/sub error body/meta
    tail -n +2 "$SUMMARY" | while IFS=$'\t' read -r label state stype sub start_msg start_code err_cat err_type retryable err_msg reason_line body_exists meta_exists note; do
      printf '%-16s %-11s %-16s %-8s %-8s\n' "$label" "$state" "$stype/$sub" "$err_cat/$err_type" "$body_exists/$meta_exists"
      if [ "$err_msg" != "-" ]; then
        echo "  error: retryable=$retryable"
        echo "  message: $err_msg"
      elif [ "$start_msg" != "-" ]; then
        echo "  start: $start_code $start_msg"
      elif [ "$state" = SKIPPED ]; then
        echo "  note: $note"
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
echo "<label>.sql・<label>.context.txt・<label>.reason.txt・<label>.start.err は実名"
echo "（DB 名・S3 Tables のカタログ名・名前空間・バケット名・アカウント ID）を含みうるので、"
echo "貼るときは中身を確かめてください。"
