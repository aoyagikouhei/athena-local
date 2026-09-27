#!/usr/bin/env bash
# issue #283 で作成。ROUND=2 は #283 の 2 ラウンド目（ROUND=1 で Iceberg の表が作れず未測定だった
# c13・c26〜c29 と、c22（CREATE VIEW）の再現と本体の中身、対照の c1 だけを測る）。
# 本物の Athena が返す COLUMN_NOT_FOUND の文言（#272 の先行実測で見つけた
# `Column '<名前>' cannot be resolved or requester is not authorized to access
# requested resources`、手元の Trino 482 は `... cannot be resolved` まで）が、
# CTAS・INSERT 以外の文（SELECT・EXPLAIN・CREATE VIEW・UPDATE・MERGE など）でも
# 同じ形かを実測する。同じ文言で終わるなら athena-local の COLUMN_NOT_FOUND 全般に
# 付けてよい材料になる（DELETE の WHERE は #272 と同じ 2026-09-17 の実測で確認済みなので
# ここでは測らない）。
#
# 使い方:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db bash tools/measure/column-not-found.sh
#   （資格情報はホストのシェルで AWS_ACCESS_KEY_ID などを export してから。または ~/.aws/credentials）
#   DB を省略するか実在しなければ、ListDatabases の一覧の 1 件目を使う。
#
# 必須の環境変数:
#   OUTPUT    結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける）。
#
# 任意の環境変数:
#   DB              データベース名。省略か実在しなければ ListDatabases の 1 件目。
#   CATALOG         既定 AwsDataCatalog
#   REGION          既定 ap-northeast-1
#   OUT_DIR         既定 ${DEV_HOST_HOME:-$HOME}/athena-column-not-found-measurements
#                   （実名が入るのでリポジトリの外に出す）
#   POLL_TIMEOUT    終端状態を待つ上限（秒）。既定 180
#   RETRY_MAX       名前解決・接続の一時的な失敗を再試行する回数。既定 4
#   RETRY_DELAY     再試行の間隔（秒）。既定 5
#   ROUND           既定 1。1 は全項目。2 は c1・c13・c22・c26〜c29 だけ（準備は <PROBE>_real と
#                   <PROBE>_ice だけ。ROUND=1 は Iceberg の表を長さの無い varchar で作ろうとして
#                   `varchar type is specified without length` で失敗したので、string に直した）
#
# 準備（すべて $DB に作り、最後に消す。trap でも保険をかける）:
#   <PROBE>_real   Hive の表（CTAS。n int, s varchar(1)、行 1 つ）。場所は既定のまま
#                  （CTAS の管理表なので <OUTPUT>tables/<id>/ の下になる。drop-table-format.sh の
#                  b・insert-location.sh の prep-h と同じ、WITH 句を付けない安全な形）。
#   <PROBE>_other  JOIN 用にもう 1 つ、同じ形で作る Hive の表。
#   <PROBE>_ice    Iceberg の表。CTAS ではなく列を書く CREATE TABLE + LOCATION +
#                  TBLPROPERTIES('table_type'='ICEBERG')（drop-table-format.sh の b で
#                  実測済みの形）。作った直後に 1 行 INSERT する。
#
# 測る項目（ID は c で始める。存在しない列名は nosuch283）:
#   c0                対照 SELECT n FROM <P>_real（成功する見込み）
#   c1〜c13           SELECT の各位置（選択リスト・WHERE・GROUP BY・ORDER BY・HAVING・
#                     JOIN の ON・別名修飾・3 部の列参照・サブクエリ・WITH 句・集約・
#                     複数行・Iceberg 表）
#   c14〜c16          表を読まない形（FROM 無し・VALUES・ラムダ）
#   c17〜c18          名前の書き方（大文字・引用符付き）
#   c19〜c21          EXPLAIN（素・ANALYZE・TYPE DISTRIBUTED）
#   c22〜c23          CREATE VIEW・CREATE OR REPLACE VIEW（受理されたら消す）
#   c24〜c25          対照。#272 で同じ文言が付いた CTAS・INSERT の再現
#   c26〜c29          UPDATE・MERGE（Iceberg）
# 詳しい対応（ID・文・確かめる点）はノート .claude/issue-notes/283.md の
# 「項目 ID の一覧」に書く。
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く。前の回の結果と混ざらない。
#
# 項目ごとに次を保存する（取れたものだけ）。
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
# 実名（DB 名・出力先・バケット名・接頭辞の乱数・アカウント ID）は伏せる。
#
# 課金について: 作る表はどれも 1 行（<P>_real・<P>_other・<P>_ice）。SELECT 系の項目は
# 存在しない列で失敗するので実行前に落ち、CTAS・INSERT・UPDATE・MERGE も同様。
# スキャンが乗るとしても、この 1 行の表を対象にした分だけ。
#
# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。
#   実測値は工場出荷時の既定とは限らない。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください}"
DB=${DB:-}
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_DIR=${OUT_DIR:-${DEV_HOST_HOME:-$HOME}/athena-column-not-found-measurements}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}
ROUND=${ROUND:-1}
case "$ROUND" in
  1 | 2) ;;
  *) echo "ROUND は 1 か 2 です: $ROUND" >&2; exit 2 ;;
esac

# 実行のたびに変わる乱数入りの接頭辞。tools/measure/unquoted-ddl.sh と同じ考え方。
RAND_SUFFIX=$(printf '%04x' $((RANDOM % 65536)))
PROBE_PREFIX="athena_local_probe_283_${RAND_SUFFIX}"
new_name() { printf '%s_%s' "$PROBE_PREFIX" "$1"; }
REAL=$(new_name real)
OTHER=$(new_name other)
ICE=$(new_name ice)

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\tstatement_type\tsubstatement_type\tstart_message\tstart_athena_error_code\terror_category\terror_type\tretryable\terror_message\treason_line\tbody_exists\tmetadata_exists\tmsg_pos\tmsg_ends_cannot\tmsg_has_suffix\tmsg_extra_after\tnote\n' > "$SUMMARY"
echo "出力先: $RUN_DIR"

# StartQueryExecution を実際に呼んだ回数（再試行も含む）。summary.txt の冒頭に出す。
START_CALL_FILE="$RUN_DIR/.start-calls"
: > "$START_CALL_FILE"

# 実在する表のセットアップに着手したかどうか。trap の後始末に使う。
REAL_ATTEMPTED=0; REAL_OK=0
OTHER_ATTEMPTED=0; OTHER_OK=0
ICE_ATTEMPTED=0; ICE_OK=0

# c22・c23（CREATE VIEW）・c24（CTAS）が想定に反して受理され、まだ消せていない
# 名前の集合（キーは裸の名前、値はテーブルなら table、ビューなら view）。
declare -A PENDING_DROPS=()

# --- 後始末 -------------------------------------------------------------------

cleanup_drop() {
  # trap の後始末で 1 文だけ投げる（結果は確かめない）。
  aws athena start-query-execution --region "$REGION" \
    --query-string "$1" \
    --query-execution-context "Catalog=$CATALOG,Database=$DB" \
    --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
}

cleanup() {
  rm -f "$RUN_DIR"/.tmp-*
  local name kind
  for name in "${!PENDING_DROPS[@]}"; do
    kind=${PENDING_DROPS[$name]}
    if [ "$kind" = view ]; then
      cleanup_drop "DROP VIEW IF EXISTS $DB.$name"
    else
      cleanup_drop "DROP TABLE IF EXISTS $DB.$name"
    fi
  done
  if [ "$ICE_ATTEMPTED" = 1 ]; then
    cleanup_drop "DROP TABLE IF EXISTS $DB.$ICE"
  fi
  if [ "$OTHER_ATTEMPTED" = 1 ]; then
    cleanup_drop "DROP TABLE IF EXISTS $DB.$OTHER"
  fi
  if [ "$REAL_ATTEMPTED" = 1 ]; then
    cleanup_drop "DROP TABLE IF EXISTS $DB.$REAL"
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

# メッセージの中の位置（line L:C）と、`cannot be resolved` で終わるか／本物の追加の文言
# （or requester is not authorized to access requested resources）が付くか／その後ろに
# さらに続きがあるかを見る（issue #283 の本題）。
column_message_summary() {
  python3 -c '
import re, sys
msg = sys.argv[1]
pos_m = re.search(r"line (\d+):(\d+)", msg)
pos = "line %s:%s" % (pos_m.group(1), pos_m.group(2)) if pos_m else "-"
idx = msg.find("cannot be resolved")
if idx == -1:
    print("%s\t-\t-\t-" % pos)
else:
    after = msg[idx + len("cannot be resolved"):]
    ends_here = "yes" if after.strip() == "" else "no"
    suffix = "or requester is not authorized to access requested resources"
    stripped = after.lstrip()
    has_suffix = "yes" if stripped.startswith(suffix) else "no"
    extra = "no"
    if has_suffix == "yes" and stripped[len(suffix):].strip():
        extra = "yes"
    print("%s\t%s\t%s\t%s" % (pos, ends_here, has_suffix, extra))
' "$1"
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
      --query-execution-context "Catalog=$CATALOG,Database=$DB" \
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
# 一時的な失敗だけ再試行する。標準出力は outfile に、標準エラーは $RUN_DIR/$label.err に、
# 試行回数は $RUN_DIR/.tmp-attempts-$label に残す。
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
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$SUMMARY"
}

# 項目を未測定として summary に 1 行残す。全体を止めずに次へ進む。
skip() {
  local label=$1 note=$2
  echo "== $label: 未測定（$note）"
  emit_row "$label" SKIPPED - - - - - - - - - - - - - - - "$(sanitize "$note")"
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

# ラベルを指定して 1 文を実行する。開始できなければ start.err から Message・
# AthenaErrorCode を抜く。開始できたら終端状態まで待って StatementType・
# SubstatementType・AthenaError（ErrorCategory・ErrorType・Retryable・ErrorMessage）・
# 結果ファイル本体と .metadata の有無を採る。
run() {
  local label=$1 sql=$2
  local id state stype sub note reason_line loc
  local start_msg="-" start_code="-" err_cat="-" err_type="-" retryable="-" err_msg="-"
  local body_exists="-" meta_exists="-" msg_pos="-" msg_ends="-" msg_suffix="-" msg_extra="-"

  printf '%s\n' "$sql" > "$RUN_DIR/$label.sql"
  id=$(start_query_retry "$label" "$sql")

  if [ -z "${id:-}" ]; then
    note="attempts=$(read_attempts "$label"); $(first_err_line "$RUN_DIR/$label.start.err")"
    start_msg=$(start_err_message "$RUN_DIR/$label.start.err")
    start_code=$(start_err_code "$RUN_DIR/$label.start.err")
    echo "== $label: 開始できませんでした。AthenaErrorCode=$start_code"
    emit_row "$label" START_FAILED - - "$start_msg" "$start_code" - - - - - - - - - - - \
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
      IFS=$'\t' read -r msg_pos msg_ends msg_suffix msg_extra < <(column_message_summary "$(python3 -c 'import json,sys
try:
    status = json.load(open(sys.argv[1]))["QueryExecution"]["Status"]
except Exception:
    print("")
    sys.exit(0)
err = status.get("AthenaError") or {}
print(err.get("ErrorMessage") or status.get("StateChangeReason") or "")' "$RUN_DIR/$label.execution.json")")
      ;;
  esac

  if [ -n "$loc" ]; then
    body_exists=$(head_exists "$label.body" "$loc")
    meta_exists=$(head_exists "$label.metadata" "${loc}.metadata")
    # FAILED なのに本体が置かれていたら中身も取る（ROUND=1 の c22・c23 の CREATE VIEW。
    # コンテナ内のパスへの書き出しは消えるので、標準出力をシェルでリダイレクトする）
    if [ "$state" = FAILED ] && [ "$body_exists" = yes ]; then
      aws s3 cp --region "$REGION" "$loc" - > "$RUN_DIR/$label.body.txt" 2> "$RUN_DIR/$label.body-cp.err" || true
    fi
  fi

  note="attempts=$(read_attempts "$label")"
  echo "== $label  state=$state  stype=$stype/$sub  error=$err_cat/$err_type  body=$body_exists  metadata=$meta_exists"
  emit_row "$label" "$state" "$stype" "$sub" "$start_msg" "$start_code" \
    "$err_cat" "$err_type" "$retryable" "$err_msg" "$reason_line" \
    "$body_exists" "$meta_exists" "$msg_pos" "$msg_ends" "$msg_suffix" "$msg_extra" \
    "$(sanitize "$note")"
  [ "$state" = SUCCEEDED ]
}

succeeded() {
  grep -qs "^State: SUCCEEDED" "$RUN_DIR/$1.reason.txt"
}

# CREATE TABLE／CREATE [OR REPLACE] VIEW を投げ、想定に反して受理されたら
# （kind は table/view）その場で DROP して消す。PENDING_DROPS で trap の保険を張る。
run_create_then_drop() {
  local label=$1 sql=$2 name=$3 kind=$4
  if run "$label" "$sql"; then
    PENDING_DROPS[$name]=$kind
    if [ "$kind" = view ]; then
      run "$label-cleanup" "DROP VIEW IF EXISTS $DB.$name"
    else
      run "$label-cleanup" "DROP TABLE IF EXISTS $DB.$name"
    fi
    if succeeded "$label-cleanup"; then
      unset 'PENDING_DROPS[$name]'
    fi
  else
    skip "$label-cleanup" "作成が失敗したため後始末不要"
  fi
}

# --- preflight -------------------------------------------------------------------
# ListDatabases（最も軽い読み取り。実能力の確認も兼ねる。command -v ではなく実際に呼ぶ）で
# 疎通と DB の候補一覧を取り、続けて SELECT 1 でクエリ実行の疎通も確かめる。

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

if ! run preflight-select1 "SELECT 1"; then
  echo
  echo "疎通確認（SELECT 1）が通りませんでした。理由: $RUN_DIR/preflight-select1.reason.txt"
  echo "（開始すらできなければ $RUN_DIR/preflight-select1.start.err）"
  exit 1
fi

# --- 準備: 実在する表を 3 つ作る --------------------------------------------------

REAL_ATTEMPTED=1
if run setup-real "CREATE TABLE $DB.$REAL AS SELECT 1 AS n, 'x' AS s"; then
  REAL_OK=1
else
  echo "== setup-real: 実在する表が作れませんでした。この表を使う項目は未測定にします。"
fi

if [ "$ROUND" = 1 ]; then
OTHER_ATTEMPTED=1
if run setup-other "CREATE TABLE $DB.$OTHER AS SELECT 1 AS n, 'x' AS s"; then
  OTHER_OK=1
else
  echo "== setup-other: JOIN 用の表が作れませんでした。c6 は未測定にします。"
fi
fi

ICE_ATTEMPTED=1
if run setup-ice "CREATE TABLE $DB.$ICE (n int, s string) LOCATION '${OUTPUT}athena-local-probe-283/${RAND_SUFFIX}/ice/' TBLPROPERTIES ('table_type'='ICEBERG')"; then
  if run setup-ice-insert "INSERT INTO $DB.$ICE VALUES (1, 'x')"; then
    ICE_OK=1
  else
    echo "== setup-ice-insert: Iceberg の表に行を入れられませんでした。Iceberg を使う項目は未測定にします。"
  fi
else
  echo "== setup-ice: Iceberg の表が作れませんでした。Iceberg を使う項目は未測定にします。"
fi

# --- 2. SELECT の各位置 -----------------------------------------------------------

if [ "$ROUND" = 2 ]; then
  if [ "$REAL_OK" = 1 ]; then
    run c1  "SELECT nosuch283 FROM $DB.$REAL"
  else
    skip c1 "<PROBE>_real が作れなかったため未測定"
  fi
elif [ "$REAL_OK" = 1 ]; then
  run c0  "SELECT n FROM $DB.$REAL"
  run c1  "SELECT nosuch283 FROM $DB.$REAL"
  run c2  "SELECT n FROM $DB.$REAL WHERE nosuch283 = 1"
  run c3  "SELECT n FROM $DB.$REAL GROUP BY nosuch283"
  run c4  "SELECT n FROM $DB.$REAL ORDER BY nosuch283"
  run c5  "SELECT n FROM $DB.$REAL GROUP BY n HAVING nosuch283 > 0"
  run c7  "SELECT r.nosuch283 FROM $DB.$REAL r"
  run c8  "SELECT $DB.$REAL.nosuch283 FROM $DB.$REAL"
  run c9  "SELECT n FROM (SELECT nosuch283 FROM $DB.$REAL) t"
  run c10 "WITH w AS (SELECT nosuch283 FROM $DB.$REAL) SELECT * FROM w"
  run c11 "SELECT count(nosuch283) FROM $DB.$REAL"
  run c12 "SELECT n"$'\n'"FROM $DB.$REAL"$'\n'"WHERE nosuch283 = 1"
else
  for label in c0 c1 c2 c3 c4 c5 c7 c8 c9 c10 c11 c12; do
    skip "$label" "<PROBE>_real が作れなかったため未測定"
  done
fi

if [ "$ROUND" = 2 ]; then
  :
elif [ "$REAL_OK" = 1 ] && [ "$OTHER_OK" = 1 ]; then
  run c6 "SELECT a.n FROM $DB.$REAL a JOIN $DB.$OTHER b ON a.nosuch283 = b.n"
else
  skip c6 "<PROBE>_real か <PROBE>_other が作れなかったため未測定"
fi

if [ "$ICE_OK" = 1 ]; then
  run c13 "SELECT n FROM $DB.$ICE WHERE nosuch283 = 1"
else
  skip c13 "<PROBE>_ice が作れなかったため未測定"
fi

if [ "$ROUND" = 1 ]; then
# --- 3. 表を読まない形 -------------------------------------------------------------

run c14 "SELECT nosuch283"
run c15 "SELECT nosuch283 FROM (VALUES 1) AS t(n)"
run c16 "SELECT transform(ARRAY[1], x -> y)"

# --- 4. 名前の書き方 ---------------------------------------------------------------

if [ "$REAL_OK" = 1 ]; then
  run c17 "SELECT NOSUCH283 FROM $DB.$REAL"
  run c18 'SELECT "NoSuch283" FROM '"$DB.$REAL"
else
  skip c17 "<PROBE>_real が作れなかったため未測定"
  skip c18 "<PROBE>_real が作れなかったため未測定"
fi

# --- 5. EXPLAIN ---------------------------------------------------------------------

if [ "$REAL_OK" = 1 ]; then
  run c19 "EXPLAIN SELECT nosuch283 FROM $DB.$REAL"
  run c20 "EXPLAIN ANALYZE SELECT nosuch283 FROM $DB.$REAL"
  run c21 "EXPLAIN (TYPE DISTRIBUTED) SELECT nosuch283 FROM $DB.$REAL"
else
  skip c19 "<PROBE>_real が作れなかったため未測定"
  skip c20 "<PROBE>_real が作れなかったため未測定"
  skip c21 "<PROBE>_real が作れなかったため未測定"
fi
fi

# --- 6. CREATE VIEW ------------------------------------------------------------------

if [ "$REAL_OK" = 1 ]; then
  V=$(new_name v)
  run_create_then_drop c22 "CREATE VIEW $DB.$V AS SELECT nosuch283 FROM $DB.$REAL" "$V" view
  [ "$ROUND" = 1 ] && run_create_then_drop c23 "CREATE OR REPLACE VIEW $DB.$V AS SELECT nosuch283 FROM $DB.$REAL" "$V" view
else
  skip c22 "<PROBE>_real が作れなかったため未測定"
  skip c22-cleanup "<PROBE>_real が作れなかったため未測定"
  skip c23 "<PROBE>_real が作れなかったため未測定"
  skip c23-cleanup "<PROBE>_real が作れなかったため未測定"
fi

# --- 7. 対照: #272 の文言の再現（CTAS・INSERT） ----------------------------------------

if [ "$ROUND" = 2 ]; then
  :
elif [ "$REAL_OK" = 1 ]; then
  CTAS_T=$(new_name ctas)
  run_create_then_drop c24 "CREATE TABLE $DB.$CTAS_T AS SELECT nosuch283 FROM $DB.$REAL" "$CTAS_T" table
  run c25 "INSERT INTO $DB.$REAL SELECT nosuch283, 'y' FROM $DB.$REAL"
else
  skip c24 "<PROBE>_real が作れなかったため未測定"
  skip c24-cleanup "<PROBE>_real が作れなかったため未測定"
  skip c25 "<PROBE>_real が作れなかったため未測定"
fi

# --- 8. UPDATE・MERGE（Iceberg） ------------------------------------------------------

if [ "$ICE_OK" = 1 ]; then
  run c26 "UPDATE $DB.$ICE SET n = 2 WHERE nosuch283 = 1"
  run c27 "UPDATE $DB.$ICE SET n = nosuch283"
  run c28 "MERGE INTO $DB.$ICE t USING (SELECT 1 AS n) s ON t.nosuch283 = s.n WHEN MATCHED THEN UPDATE SET n = 2"
  run c29 "MERGE INTO $DB.$ICE t USING (SELECT 1 AS n) s ON t.n = s.n WHEN MATCHED THEN UPDATE SET n = s.nosuch283"
else
  skip c26 "<PROBE>_ice が作れなかったため未測定"
  skip c27 "<PROBE>_ice が作れなかったため未測定"
  skip c28 "<PROBE>_ice が作れなかったため未測定"
  skip c29 "<PROBE>_ice が作れなかったため未測定"
fi

# --- 後始末: 準備した実在する表を消す ---------------------------------------------------

if [ "$REAL_OK" = 1 ]; then
  run z-drop-real "DROP TABLE IF EXISTS $DB.$REAL"
  if succeeded z-drop-real; then REAL_ATTEMPTED=0; fi
fi
if [ "$OTHER_OK" = 1 ]; then
  run z-drop-other "DROP TABLE IF EXISTS $DB.$OTHER"
  if succeeded z-drop-other; then OTHER_ATTEMPTED=0; fi
fi
if [ "$ICE_OK" = 1 ]; then
  run z-drop-ice "DROP TABLE IF EXISTS $DB.$ICE"
  if succeeded z-drop-ice; then ICE_ATTEMPTED=0; fi
fi

# --- summary.txt（そのまま貼れる整形済み） ---------------------------------------------

write_summary_txt() {
  local txt="$RUN_DIR/summary.txt"
  {
    echo "# issue #283: COLUMN_NOT_FOUND の文言（cannot be resolved / or requester is not"
    echo "#             authorized to access requested resources）が CTAS・INSERT 以外の文でも"
    echo "#             同じ形かを実測（DELETE の WHERE は #272 と同じ 2026-09-17 の実測で確認済みのため対象外）"
    echo "# 実行日時: $(date -Iseconds)"
    echo "# ROUND=$ROUND"
    if [ "$ROUND" = 2 ]; then
      echo "# StartQueryExecution の見込み本数: 13〜14（preflight 1 + 準備 3（real の CTAS、ice の CREATE・"
      echo "#   INSERT）+ 項目 7（c1・c13・c22・c26〜c29）+ 後始末 2（real・ice の DROP）。c22 が"
      echo "#   想定に反して受理されたらその場で消す後始末が 1 本増える）。以下の ROUND=1 の内訳は参考"
    fi
    echo "# StartQueryExecution の見込み本数（ROUND=1）: 39〜42"
    echo "#   （preflight 2（SELECT 1 は 1、ListDatabases は Athena のクエリではないので含めない）+"
    echo "#   準備 4（real・other の CTAS、ice の CREATE・INSERT）+ 主要項目 30（c0〜c29）+"
    echo "#   後始末 3（real・other・ice の DROP）。c22〜c24 が想定に反して受理されたら"
    echo "#   その場で消す後始末が最大 3 本増える）。"
    echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
    echo "# DDL・書き込み: 表 <PROBE>_real・<PROBE>_other（CTAS、1 行）と <PROBE>_ice"
    echo "#   （CREATE + INSERT、1 行）を作って最後に消す。c22・c23（CREATE VIEW）・c24（CTAS）は"
    echo "#   列が無いため失敗する見込みだが、想定に反して受理されたらその場で消す。c25（INSERT）は"
    echo "#   失敗する見込みで、<PROBE>_real に行は増えない見込み。"
    echo "# 課金: どの表も 1 行だけで、スキャンが乗るとしてもこの小さな表が対象。"
    echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
    echo "#   実測値は工場出荷時の既定とは限らない。"
    echo
    if [ "${#PENDING_DROPS[@]}" -gt 0 ] || [ "$REAL_ATTEMPTED" = 1 ] || [ "$OTHER_ATTEMPTED" = 1 ] || [ "$ICE_ATTEMPTED" = 1 ]; then
      echo "## 手で消してください（本編の後始末で消せず、trap のベストエフォートに委ねたもの）"
      [ "$REAL_ATTEMPTED" = 1 ] && echo "- <PROBE>_real（DROP TABLE IF EXISTS で確認）"
      [ "$OTHER_ATTEMPTED" = 1 ] && echo "- <PROBE>_other（DROP TABLE IF EXISTS で確認）"
      [ "$ICE_ATTEMPTED" = 1 ] && echo "- <PROBE>_ice（DROP TABLE IF EXISTS で確認）"
      local name
      for name in "${!PENDING_DROPS[@]}"; do
        echo "- $(hide "$name")（${PENDING_DROPS[$name]} 相当。DROP で確認）"
      done
      echo
    fi
    echo "## 項目ごとの結果（実名は伏せる）"
    printf '%-14s %-11s %-16s %-30s %-8s %-8s %-6s\n' label state stype/sub pos ends_cannot has_suffix extra
    tail -n +2 "$SUMMARY" | while IFS=$'\t' read -r label state stype sub start_msg start_code err_cat err_type retryable err_msg reason_line body_exists meta_exists msg_pos msg_ends msg_suffix msg_extra note; do
      printf '%-14s %-11s %-16s %-30s %-8s %-8s %-6s' "$label" "$state" "$stype/$sub" "$msg_pos" "$msg_ends" "$msg_suffix" "$msg_extra"
      echo
      if [ "$err_msg" != "-" ]; then
        echo "  error: $err_cat/$err_type retryable=$retryable body=$body_exists metadata=$meta_exists"
        echo "  message: $err_msg"
      elif [ "$start_msg" != "-" ]; then
        echo "  start: $start_code $start_msg"
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
echo "<label>.sql・<label>.reason.txt・<label>.start.err は実名（DB 名・テーブル名）を"
echo "含みうるので、貼るときは中身を確かめてください。"
