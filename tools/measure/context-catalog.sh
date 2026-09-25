#!/usr/bin/env bash
# issue #214 で作成
# 本物の Athena で、StartQueryExecution の QueryExecutionContext.Catalog に実在しない
# カタログ名を渡したとき、文の種類ごとにどう解決するかを実測する。issue #214 のための
# 実測スクリプト。
#
# 背景（2026-09-25 実測の #212、docs/dev/measurements/statements.md の末尾の節）: Catalog=nocatalog_212・
# Database=<実在の DB> の QueryExecutionContext で `SELECT 1`・`DESCRIBE t`・
# `SHOW COLUMNS FROM t` は SUCCEEDED、実在しない表への `DESCRIBE` は Entity Not Found
# （既定の AwsDataCatalog で解決しているように見える）。表を読む SELECT・SHOW・DDL・INSERT・
# エラーの文言にどのカタログ名が出るか（GetQueryResults の ColumnInfo・GetQueryExecution が
# 返す QueryExecutionContext・AthenaError の文言のどれに「本当に投げたカタログ名」と
# 「解決先の既定カタログ名」のどちらが出るか）は未実測。このスクリプトでそれを洗う。
#
# tools/measure/quoted-names.sh（#204）を雛形にしている。redact・mask_names・hide・
# sanitize・first_err_line・is_transient_error・start_query_retry（QE_CONTEXT で Context を
# 渡す）・poll_until_terminal・run・run_in_ctx・skip・emit_row・fetch_all_table_names・
# preflight（SHOW TABLES）・接頭辞のテーブルが既にあれば止まる安全装置・準備の CTAS と
# 後始末・trap cleanup EXIT・summary.tsv と summary.txt の 2 段・アカウント ID の伏せ字は
# そのまま流用する。ROUND の切り替えは要らない（1 ラウンド分だけ）ので持ち込んでいない。
# 雛形からの変更点:
#   - summary.tsv に qec_catalog・qec_database の 2 列を足した（GetQueryExecution が返す
#     QueryExecutionContext。送った Context と違う値が返れば、それ自体が解決の証拠になる）。
#     11 列だった雛形のヘッダに 2 列足して 13 列にした。
#   - run() が呼ぶたびに <label>.context.txt にそのとき投げた QueryExecutionContext を書く
#     ようにした（雛形は run_in_ctx を呼んだときの診断用の一部の項目だけに書いていたが、
#     この実測は Context の差し替えそのものが主題なので、全項目に付ける）。
#   - GetQueryResults の 1 ページ目を見る gqr_check() を新設した（雛形は結果ファイルを見ず、
#     「開始できたか」「FAILED の理由」だけを見ていたが、この実測は ColumnInfo に出る
#     カタログ名も見る）。
#
# 使い方:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db bash tools/measure/context-catalog.sh
#   （資格情報はホストのシェルで AWS_ACCESS_KEY_ID などを export してから。または ~/.aws/credentials）
#
# 必要な環境変数:
#   OUTPUT    結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける）。
#   DB        データベース名。実在するものを指定する。
#
# 任意の環境変数:
#   CATALOG        既定 AwsDataCatalog（対照の OK Context に使う）
#   REGION         既定 ap-northeast-1
#   OUT_DIR        既定 ${DEV_HOST_HOME:-$HOME}/athena-context-catalog-measurements
#                  （実名が入るのでリポジトリの外に出す）
#   POLL_TIMEOUT   終端状態を待つ上限（秒）。既定 180
#   RETRY_MAX      名前解決・接続など一時的な失敗を再試行する回数の上限。既定 4
#   RETRY_DELAY    再試行の間隔（秒）。既定 5
#   PROBE_DDL      既定 1（測る）。準備の Hive テーブル athena_local_probe_214 と、
#                  DDL・DML 群で使う athena_local_probe_214_c を作る。最後にどちらも
#                  無引用 + IF EXISTS の DROP で消す。0 にすると、対象テーブルが要る項目は
#                  SHOW TABLES の 1 件目（実在のテーブル）を使い、DDL・DML 群は未測定にする。
#
# ** このスクリプトが本物に対して行う破壊的な操作（DDL の一覧と後始末） **
#   PROBE_DDL=1 のとき（既定）:
#     1. 準備: CREATE TABLE <DB>.athena_local_probe_214 AS SELECT 1 AS n, 'x' AS s
#        （OK Context。SELECT 系・SHOW 系・EXPLAIN の対象テーブルに使う）
#        → 後始末: DROP TABLE IF EXISTS athena_local_probe_214（OK Context。ラベル z-drop-hive）
#     2. DDL・DML 群（対象は別のテーブル athena_local_probe_214_c。準備の表とは別物）:
#          z-ctas-nc  CREATE TABLE athena_local_probe_214_c AS SELECT 1 AS n
#                     （NC Context = Catalog=nocatalog_214,Database=<DB>。1 部の名前）
#          z-insert-nc  INSERT INTO athena_local_probe_214_c SELECT 2（NC Context）
#          z-dropif-nc  DROP TABLE IF EXISTS athena_local_probe_214_c（NC Context。これで
#                       消えるかどうか自体が「NC が既定カタログを引いているか」の証拠になる）
#        z-ctas-nc が開始時に弾かれたら、z-ctas-verify 以降は未測定にする（表を作れて
#        いないので後始末も不要）。開始できれば（SUCCEEDED でも FAILED でも）、必ず
#        OK Context の DROP TABLE IF EXISTS <DB>.athena_local_probe_214_c を最後に投げて
#        消す（ラベル z-drop-c-cleanup。z-dropif-nc で消えていても IF EXISTS なので無害）。
#     trap にも、DDL_ATTEMPTED・CTABLE_CREATED の 2 つのフラグで同じ 2 本の DROP
#     （athena_local_probe_214 と <DB>.athena_local_probe_214_c、どちらも OK Context）を
#     保険として持つ。
#   PROBE_DDL=0 のとき: DDL・DML 群はまるごと未測定。準備の CREATE TABLE も行わず、
#     SELECT 系・SHOW 系・EXPLAIN の対象は SHOW TABLES の 1 件目（実在のテーブル）を使う。
#   DROP は上記の後始末を除いて実在しない名前（athena_local_probe_214_nope）にだけ投げる。
#   nocatalog_214 というカタログは作らず、QueryExecutionContext に渡すだけ（実在しない
#   カタログ名が本物にどう扱われるかを見るのがこの実測の目的）。
#
# 課金について: 準備の表・athena_local_probe_214_c ともに 1 行だけの CTAS・INSERT
#   （PROBE_DDL=1 のときだけ）。DESCRIBE・SHOW 系・EXPLAIN・DROP はメタデータだけを
#   見る／書く文でスキャンは無い。SELECT はどれも 1 行の表を読むだけ。Athena の
#   最小課金 × クエリ数の見込み。
#
# 本物への StartQueryExecution の見込み本数（GetQueryExecution・GetQueryResults への
# 呼び出しは含めない。課金には影響しない）:
#   preflight 1
#   + PROBE_DDL=1 のときの準備 1・後始末 1（既定はこちら）
#   + 表を読む SELECT（z-sel1-nc・z-sel1-ok・z-sel2-nc・z-sel3-nc）4
#   + 実在しない表・DB の SELECT（z-selnope-nc・z-selnope-ok・z-selnodb-nc・z-selnodb-ok）4
#   + SHOW 系（z-showtables-nc・z-showdb-nc・z-showcreate-nc・z-tblprops-nc・z-showviews-nc）5
#   + EXPLAIN（z-explain-nc）1
#   + DDL・DML 群 最大 6（z-ctas-nc 1 + 開始できれば z-ctas-verify・z-insert-nc・
#     z-dropif-nc・z-drop-verify の 4 + 後始末 z-drop-c-cleanup 1）
#   + 実在しない表の DROP（z-dropnope-nc）1
#   + Database を省いた Context（z-desc-nodbctx・z-sel-nodbctx）2
#   + 大文字小文字違いの既存カタログ名との対照（z-sel1-upper）1
#   = 27（PROBE_DDL=1・CTAS が開始できたとき）／22（CTAS が開始時に弾かれ、DDL・DML 群の
#   後続 5 本を未測定にしたとき）／19（PROBE_DDL=0。準備・後始末・DDL・DML 群がまるごと無い）。
#   開始時に弾かれた（START_FAILED）項目があっても追加の呼び出しはしない
#   （AthenaErrorCode・Message は同じ標準エラーからそのまま抜く）。
#   GetQueryResults は別に、preflight・z-ctas-verify・z-drop-verify の一覧取得と、
#   SUCCEEDED した対照 7 本（下記 GQR_LABELS）の 1 ページ目取得で最大 10 回程度呼ぶ
#   （課金に影響しない）。
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く。前の回の結果と混ざらない。
#
# 項目ごとに次を保存する（取れたものだけ）。
#   <label>.sql             投げた SQL そのもの（**DB 名・テーブル名を含む。実名を含む**）
#   <label>.context.txt     投げた QueryExecutionContext（実名を含む）
#   <label>.start.err       StartQueryExecution の標準エラー（開始時に弾かれた証拠。
#                            一切加工せず AWS CLI の出力そのまま保存する）
#   <label>.execution.json  GetQueryExecution の生の応答（開始できた項目だけ）
#   <label>.execution.err   GetQueryExecution の標準エラー
#   <label>.reason.txt      State・StateChangeReason・AthenaError（**実名を含みうる**）
#   <label>.gqr.json         GetQueryResults の 1 ページ目（GQR_LABELS の 7 本だけ）
#   <label>.rows.txt         z-ctas-verify・z-drop-verify の SHOW TABLES の全行（**実名**）
#
# summary の決め手になる列は state・statement_type/substatement_type・
# qec_catalog/qec_database（GetQueryExecution が返した QueryExecutionContext）・
# start_message/start_athena_error_code（開始時に弾かれた項目）・
# error_category/error_type/error_message（開始できて FAILED になった項目）。
# DB 名・出力先・バケット名・対象テーブル名・アカウント ID は出さず、プレースホルダに畳む。
# SHOW TABLES・SHOW DATABASES の結果の中身は summary に出さず、GQR の対照は
# ColumnInfo（CatalogName・SchemaName・TableName）と行数だけを出す（他のテーブル名が
# 漏れるため）。summary.tsv / summary.txt はそのまま貼れる。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください}"
: "${DB:?DB にデータベース名を設定してください}"
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_DIR=${OUT_DIR:-${DEV_HOST_HOME:-$HOME}/athena-context-catalog-measurements}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}
PROBE_DDL=${PROBE_DDL:-1}

PROBE_PREFIX=athena_local_probe_214
NOPE=${PROBE_PREFIX}_nope
NODB=${PROBE_PREFIX}_nodb
CTABLE=${PROBE_PREFIX}_c
NOCAT=nocatalog_214

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\tstatement_type\tsubstatement_type\tqec_catalog\tqec_database\tstart_message\tstart_athena_error_code\terror_category\terror_type\terror_message\treason_line\tnote\n' > "$SUMMARY"
echo "出力先: $RUN_DIR"

# StartQueryExecution を実際に呼んだ回数（再試行も含む）。summary.txt の冒頭に出す。
START_CALL_FILE="$RUN_DIR/.start-calls"
: > "$START_CALL_FILE"
# 準備の表 athena_local_probe_214 の CREATE TABLE に着手したかどうか。trap での後始末に使う。
DDL_ATTEMPTED=0
# DDL・DML 群の athena_local_probe_214_c が（開始できて）できたかもしれないかどうか。
# 後始末の DROP が SUCCEEDED になったら 0 に戻す。trap での後始末に使う。
CTABLE_CREATED=0

# StartQueryExecution に渡す QueryExecutionContext。ふだんは対照の OK（CATALOG・DB）で、
# run_in_ctx で 1 文だけ差し替える。
QE_CONTEXT="Catalog=$CATALOG,Database=$DB"
NC_CTX="Catalog=$NOCAT,Database=$DB"
NC_NODB_CTX="Catalog=$NOCAT"
UPPER_CTX="Catalog=AWSDATACATALOG,Database=$DB"

# trap の後始末で 1 文だけ投げる（結果は確かめない。OK Context）。
cleanup_drop() {
  aws athena start-query-execution --region "$REGION" \
    --query-string "$1" \
    --query-execution-context "Catalog=$CATALOG,Database=$DB" \
    --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
}

# 中間ファイル（.tmp-*）は、途中で止めても残らないよう trap で消す。準備・DDL・DML 群の
# CREATE TABLE に着手していたら、ベストエフォートで後始末も投げる（本編の z-drop-hive・
# z-drop-c-cleanup で消せなかったときの保険。cleanup 自体は結果を確かめない）。
cleanup() {
  rm -f "$RUN_DIR"/.tmp-*
  if [ "$DDL_ATTEMPTED" = 1 ]; then
    cleanup_drop "DROP TABLE IF EXISTS $PROBE_PREFIX"
  fi
  if [ "$CTABLE_CREATED" = 1 ]; then
    cleanup_drop "DROP TABLE IF EXISTS $DB.$CTABLE"
  fi
}
trap cleanup EXIT

# 実名（DB 名・出力先・バケット名・アカウント ID）を置換して隠す。
# アカウント ID は、前後が数字でない 12 桁の数字として伏せる。
OUTPUT_BUCKET=${OUTPUT#s3://}
OUTPUT_BUCKET=${OUTPUT_BUCKET%%/*}
redact() {
  local s=$1
  s=${s//$DB/<DB>}
  s=${s//$OUTPUT/<OUTPUT>}
  s=${s//$OUTPUT_BUCKET/<BUCKET>}
  printf '%s' "$s" | sed -E 's/(^|[^0-9])[0-9]{12}([^0-9]|$)/\1<ACCOUNT_ID>\2/g'
}

# 標準入力から、対象テーブル名（TARGET_TABLE）・接頭辞 athena_local_probe_214 を置換して
# 隠す。summary.txt に流し込む文言・エラー文言・SQL・Context の伏せ字表示に使う。
mask_names() {
  local s
  s=$(cat)
  if [ -n "${TARGET_TABLE:-}" ]; then
    s=${s//$TARGET_TABLE/<TT>}
  fi
  s=${s//$PROBE_PREFIX/<PROBE>}
  printf '%s' "$s"
}

# redact と mask_names を両方かけて、実名をすべて伏せる。
hide() {
  local s
  s=$(redact "$1")
  s=$(printf '%s' "$s" | mask_names)
  printf '%s' "$s"
}

# 制御文字を落として短くする。note・summary に入れる前に必ず通す。
sanitize() {
  printf '%s' "$1" | tr '\t\n\r' '   ' | cut -c1-300
}

# stderr ファイルの 1 行目を、実名を隠して短く返す。ファイルが無ければ定型文を返す。
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

# start.err から Message と AthenaErrorCode を抜く（#200 の実例どおり、AWS CLI は
# 開始時に弾かれた StartQueryExecution の標準エラーに、追加の呼び出しをしなくても
# 両方とも出す）。Message は「operation: 」より後ろ、「\n\nAdditional error details:」の
# 手前まで（無ければファイル末尾まで）。AthenaErrorCode は「AthenaErrorCode: 」の行から。
# どちらも見つからなければ "-"。
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

# execution.json から StateChangeReason と AthenaError を取り出してファイルに書く。
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

# execution.json から AthenaError の ErrorCategory / ErrorType / ErrorMessage をタブ区切りで返す。
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

# execution.json から StatementType / SubstatementType をタブ区切りで返す。
read_execution_fields() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception:
    print("-\t-")
    sys.exit(0)
print("%s\t%s" % (d.get("StatementType") or "-", d.get("SubstatementType") or "-"))' "$1"
}

# execution.json から GetQueryExecution が返した QueryExecutionContext（Catalog・Database）を
# タブ区切りで返す。送った Context と違う値が返れば、それ自体が解決の証拠になる。
qec_of() {
  python3 -c 'import json, sys
try:
    ctx = json.load(open(sys.argv[1]))["QueryExecution"].get("QueryExecutionContext") or {}
except Exception:
    print("-\t-")
    sys.exit(0)
print("%s\t%s" % (ctx.get("Catalog") or "-", ctx.get("Database") or "-"))' "$1"
}

# 今の State だけを 1 回取って返す（待たない）。
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

LAST_ATTEMPTS=0
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

# summary.tsv に 1 行積む。列の並びはヘッダと同じ 13 列で固定する。
emit_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$SUMMARY"
}

# 項目を未測定として summary に 1 行残す。全体を止めずに次へ進む。
skip() {
  local label=$1 note=$2
  echo "== $label: 未測定（$note）"
  emit_row "$label" "SKIPPED" - - - - - - - - - - "$(sanitize "$note")"
}

# 測定ではない確かめの結果（GQR の ColumnInfo・SHOW TABLES での有無の確認など）を
# summary に 1 行残す（state は INFO）。
info_row() {
  local label=$1 note=$2
  echo "== $label: $note"
  emit_row "$label" "INFO" - - - - - - - - - - "$(sanitize "$note")"
}

# ラベルを指定して 1 文を実行する。呼んだ時点の QueryExecutionContext（QE_CONTEXT）を
# <label>.context.txt に残す。開始できなければ、AthenaErrorCode・Message をその場の
# start.err からそのまま抜く（追加の呼び出しはしない）。開始できたら終端状態まで待って
# StatementType・SubstatementType・GetQueryExecution が返した QueryExecutionContext・
# FAILED の理由を採る。
run() {
  local label=$1 sql=$2
  local id state stype sub note reason_line qec_cat qec_db
  local start_msg="-" start_code="-" err_cat="-" err_type="-" err_msg="-"

  printf '%s\n' "$sql" > "$RUN_DIR/$label.sql"
  printf '%s\n' "$QE_CONTEXT" > "$RUN_DIR/$label.context.txt"
  id=$(start_query_retry "$label" "$sql")
  LAST_ATTEMPTS=$(read_attempts "$label")

  if [ -z "${id:-}" ]; then
    note="attempts=$LAST_ATTEMPTS; $(first_err_line "$RUN_DIR/$label.start.err")"
    start_msg=$(start_err_message "$RUN_DIR/$label.start.err")
    start_code=$(start_err_code "$RUN_DIR/$label.start.err")
    echo "== $label: 開始できませんでした（試行 $LAST_ATTEMPTS 回）。AthenaErrorCode=$start_code"
    emit_row "$label" "START_FAILED" - - - - "$start_msg" "$start_code" - - - - "$(sanitize "$note")"
    return 1
  fi

  state=$(poll_until_terminal "$id")

  aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.execution.json" 2> "$RUN_DIR/$label.execution.err"
  write_reason "$RUN_DIR/$label.execution.json" "$RUN_DIR/$label.reason.txt"
  reason_line=$(reason_first_line "$RUN_DIR/$label.execution.json")

  IFS=$'\t' read -r stype sub < <(read_execution_fields "$RUN_DIR/$label.execution.json")
  IFS=$'\t' read -r qec_cat qec_db < <(qec_of "$RUN_DIR/$label.execution.json")
  qec_cat=$(sanitize "$(hide "$qec_cat")")
  qec_db=$(sanitize "$(hide "$qec_db")")

  note="attempts=$LAST_ATTEMPTS"
  case "$state" in
    FAILED | CANCELLED)
      IFS=$'\t' read -r err_cat err_type err_msg < <(athena_error_fields_of "$RUN_DIR/$label.execution.json")
      err_msg=$(sanitize "$(hide "$err_msg")")
      ;;
  esac

  echo "== $label  state=$state  stype=$stype/$sub  qec=$qec_cat/$qec_db  error=$err_cat/$err_type"
  emit_row "$label" "$state" "$stype" "$sub" "$qec_cat" "$qec_db" "$start_msg" "$start_code" \
    "$err_cat" "$err_type" "$err_msg" "$reason_line" "$(sanitize "$note")"
  [ "$state" = SUCCEEDED ]
}

# QueryExecutionContext を $1 に差し替えて run を 1 回呼ぶ。run() が context.txt を書くので
# ここでは差し替えて戻すだけ。
run_in_ctx() {
  local ctx=$1 saved=$QE_CONTEXT rc
  shift
  QE_CONTEXT=$ctx
  run "$@"
  rc=$?
  QE_CONTEXT=$saved
  return "$rc"
}

# <label>.execution.json から QueryExecutionId を返す（無ければ空）。
query_id_of() {
  python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1]))["QueryExecution"]["QueryExecutionId"])
except Exception:
    print("")' "$RUN_DIR/$1.execution.json" 2>/dev/null
}

# <label>.reason.txt が SUCCEEDED を示していれば真。
succeeded() {
  grep -qs "^State: SUCCEEDED" "$RUN_DIR/$1.reason.txt"
}

# 対象テーブル名（TARGET_TABLE）・接頭辞 athena_local_probe_214 の一覧（SHOW TABLES など）を
# GetQueryResults でページングしながら全件取る（S3 は使わない）。
fetch_all_table_names() {
  local id=$1 out=$2 token="" page=0
  : > "$out"
  while :; do
    page=$((page + 1))
    if [ -z "$token" ]; then
      aws athena get-query-results --region "$REGION" --query-execution-id "$id" \
        --max-results 1000 > "$RUN_DIR/.tmp-gqr-page.json" 2>"$RUN_DIR/.tmp-gqr-page.err"
    else
      aws athena get-query-results --region "$REGION" --query-execution-id "$id" \
        --max-results 1000 --next-token "$token" > "$RUN_DIR/.tmp-gqr-page.json" 2>"$RUN_DIR/.tmp-gqr-page.err"
    fi
    [ -s "$RUN_DIR/.tmp-gqr-page.json" ] || break
    python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
for r in d.get("ResultSet", {}).get("Rows", []):
    data = r.get("Data", [])
    if data and data[0].get("VarCharValue") is not None:
        print(data[0]["VarCharValue"])' "$RUN_DIR/.tmp-gqr-page.json" >> "$out"
    token=$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("NextToken", ""))
except Exception:
    print("")' "$RUN_DIR/.tmp-gqr-page.json")
    [ -n "$token" ] || break
    [ "$page" -ge 20 ] && break
  done
  rm -f "$RUN_DIR/.tmp-gqr-page.json" "$RUN_DIR/.tmp-gqr-page.err"
}

# SUCCEEDED した対照 SELECT・SHOW・EXPLAIN（GQR_LABELS）の GetQueryResults の最初の
# 1 ページを <label>.gqr.json に保存し、ResultSetMetadata.ColumnInfo[0] の
# CatalogName・SchemaName・TableName と行数を summary に INFO 行で残す（本物が
# ColumnInfo にどのカタログ名を入れるかを見るため。行の中身そのものは出さない）。
GQR_LABELS="z-sel1-nc z-sel1-ok z-sel3-nc z-showtables-nc z-showdb-nc z-showcreate-nc z-explain-nc"

gqr_check() {
  local label=$1 id
  if ! succeeded "$label"; then
    skip "$label-gqr" "SUCCEEDED でないため未測定"
    return
  fi
  id=$(query_id_of "$label")
  if [ -z "$id" ]; then
    skip "$label-gqr" "QueryExecutionId が取れず未測定"
    return
  fi
  aws athena get-query-results --region "$REGION" --query-execution-id "$id" --max-results 5 \
    > "$RUN_DIR/$label.gqr.json" 2> "$RUN_DIR/$label.gqr.err"
  if [ ! -s "$RUN_DIR/$label.gqr.json" ]; then
    info_row "$label-gqr" "GetQueryResults が失敗: $(first_err_line "$RUN_DIR/$label.gqr.err")"
    return
  fi
  local info
  info=$(python3 -c '
import json, sys
try:
    rs = json.load(open(sys.argv[1]))["ResultSet"]
except Exception:
    print("(gqr.json を読めませんでした)")
    sys.exit(0)
cols = rs.get("ResultSetMetadata", {}).get("ColumnInfo", [])
rows = rs.get("Rows", [])
if cols:
    c = cols[0]
    print("ColumnInfo[0]: CatalogName=%s SchemaName=%s TableName=%s / 行数=%d" % (
        c.get("CatalogName") or "-", c.get("SchemaName") or "-", c.get("TableName") or "-", len(rows)))
else:
    print("ColumnInfo 無し / 行数=%d" % len(rows))
' "$RUN_DIR/$label.gqr.json")
  info_row "$label-gqr" "$(sanitize "$(hide "$info")")"
}

# --- preflight ---------------------------------------------------------------

if ! run probe-show-tables "SHOW TABLES"; then
  echo
  echo "SHOW TABLES が通りませんでした。DB か CATALOG の指定が実在しません。"
  echo "理由: $RUN_DIR/probe-show-tables.reason.txt"
  exit 1
fi

SHOW_TABLES_ID=$(query_id_of probe-show-tables)
if [ -z "$SHOW_TABLES_ID" ]; then
  echo
  echo "SHOW TABLES の QueryExecutionId が取れませんでした。止まります。"
  exit 1
fi
fetch_all_table_names "$SHOW_TABLES_ID" "$RUN_DIR/tables.txt"

if [ "$PROBE_DDL" = 1 ] && grep -qi "$PROBE_PREFIX" "$RUN_DIR/tables.txt"; then
  echo
  echo "このデータベースに ${PROBE_PREFIX}* という名前のテーブルが既にあります。"
  echo "上書き・削除してしまうので、何も作らずに止まります。一覧: $RUN_DIR/tables.txt"
  exit 1
fi

# --- 対象テーブル（<TT>）を決め、準備の表を作る（PROBE_DDL=1 のときだけ） -------------
# PROBE_DDL=1 のときは athena_local_probe_214 を作る。0 のときは SHOW TABLES の 1 件目
# （実在のテーブル）を使う。名前は小文字で使う。

TARGET_TABLE=""
if [ "$PROBE_DDL" = 1 ]; then
  TARGET_TABLE=$PROBE_PREFIX
else
  TARGET_TABLE=$(head -n1 "$RUN_DIR/tables.txt" 2>/dev/null | tr -d '\r' | tr '[:upper:]' '[:lower:]')
fi

D_SETUP_OK=0
if [ "$PROBE_DDL" = 1 ]; then
  DDL_ATTEMPTED=1
  if run d0-setup-hive "CREATE TABLE $DB.$TARGET_TABLE AS SELECT 1 AS n, 'x' AS s"; then
    D_SETUP_OK=1
  else
    echo "== d0-setup-hive: 準備テーブルが作れませんでした。対象テーブルが要る項目は未測定にします。"
    TARGET_TABLE=""
  fi
else
  D_SETUP_OK=1
fi

if [ -z "$TARGET_TABLE" ]; then
  echo "== 対象テーブルが決められないため、対象テーブルが要る項目を未測定にします。"
fi

# --- 表を読む SELECT ----------------------------------------------------------
# NC = Catalog=nocatalog_214,Database=<DB>、OK = 通常の Catalog=AwsDataCatalog,Database=<DB>（対照）。

if [ -n "$TARGET_TABLE" ]; then
  run_in_ctx "$NC_CTX" z-sel1-nc "SELECT * FROM $TARGET_TABLE"
  gqr_check z-sel1-nc
  run z-sel1-ok "SELECT * FROM $TARGET_TABLE"
  gqr_check z-sel1-ok
  run_in_ctx "$NC_CTX" z-sel2-nc "SELECT * FROM $DB.$TARGET_TABLE"
  run_in_ctx "$NC_CTX" z-sel3-nc "SELECT * FROM awsdatacatalog.$DB.$TARGET_TABLE"
  gqr_check z-sel3-nc
else
  for label in z-sel1-nc z-sel1-ok z-sel2-nc z-sel3-nc; do
    skip "$label" "対象テーブルが無いため未測定"
  done
  for label in z-sel1-nc z-sel1-ok z-sel3-nc; do
    skip "$label-gqr" "対象テーブルが無いため未測定"
  done
fi

# --- 実在しない表・DB の SELECT（エラーの文言にどのカタログ名が出るか。対照つき） --------

run_in_ctx "$NC_CTX" z-selnope-nc "SELECT * FROM $NOPE"
run z-selnope-ok "SELECT * FROM $NOPE"
if [ -n "$TARGET_TABLE" ]; then
  run_in_ctx "$NC_CTX" z-selnodb-nc "SELECT * FROM $NODB.$TARGET_TABLE"
  run z-selnodb-ok "SELECT * FROM $NODB.$TARGET_TABLE"
else
  skip z-selnodb-nc "対象テーブルが無いため未測定"
  skip z-selnodb-ok "対象テーブルが無いため未測定"
fi

# --- SHOW 系 -------------------------------------------------------------------

run_in_ctx "$NC_CTX" z-showtables-nc "SHOW TABLES"
gqr_check z-showtables-nc
run_in_ctx "$NC_CTX" z-showdb-nc "SHOW DATABASES"
gqr_check z-showdb-nc
if [ -n "$TARGET_TABLE" ]; then
  run_in_ctx "$NC_CTX" z-showcreate-nc "SHOW CREATE TABLE $TARGET_TABLE"
  gqr_check z-showcreate-nc
  run_in_ctx "$NC_CTX" z-tblprops-nc "SHOW TBLPROPERTIES $TARGET_TABLE"
else
  skip z-showcreate-nc "対象テーブルが無いため未測定"
  skip z-showcreate-nc-gqr "対象テーブルが無いため未測定"
  skip z-tblprops-nc "対象テーブルが無いため未測定"
fi
run_in_ctx "$NC_CTX" z-showviews-nc "SHOW VIEWS"

# --- EXPLAIN ---------------------------------------------------------------------

if [ -n "$TARGET_TABLE" ]; then
  run_in_ctx "$NC_CTX" z-explain-nc "EXPLAIN SELECT * FROM $TARGET_TABLE"
  gqr_check z-explain-nc
else
  skip z-explain-nc "対象テーブルが無いため未測定"
  skip z-explain-nc-gqr "対象テーブルが無いため未測定"
fi

# --- DDL・DML（PROBE_DDL=1 のときだけ。準備の表とは別の <DB>.athena_local_probe_214_c） ---
# CTAS が開始時に弾かれたら後続は skip。開始できて FAILED でも後始末の DROP（OK の
# Context）を投げる（ラベル z-drop-c-cleanup。後始末（PROBE_DDL=1 のときだけ）の節）。

CTAS_STARTED=0
if [ "$PROBE_DDL" = 1 ]; then
  run_in_ctx "$NC_CTX" z-ctas-nc "CREATE TABLE $CTABLE AS SELECT 1 AS n" || true
  if [ -s "$RUN_DIR/z-ctas-nc.execution.json" ]; then
    CTAS_STARTED=1
    # 開始できたかどうかが分かった時点で、trap の保険をベストエフォートでかけておく
    # （実際に作られたかどうかは z-drop-verify で確かめる）。
    CTABLE_CREATED=1
  fi
else
  skip z-ctas-nc "PROBE_DDL=0 のため未測定"
fi

if [ "$CTAS_STARTED" = 1 ]; then
  if run z-ctas-verify "SHOW TABLES"; then
    fetch_all_table_names "$(query_id_of z-ctas-verify)" "$RUN_DIR/z-ctas-verify.rows.txt"
    ctas_count=$(grep -Fxc "$CTABLE" "$RUN_DIR/z-ctas-verify.rows.txt")
    info_row z-ctas-verify-check "件数=$ctas_count（$CTABLE が <DB> にあるか。1 なら NC の CREATE TABLE が既定カタログに作った）"
  else
    info_row z-ctas-verify-check "SHOW TABLES が通らず確かめられなかった"
  fi
  run_in_ctx "$NC_CTX" z-insert-nc "INSERT INTO $CTABLE SELECT 2"
  run_in_ctx "$NC_CTX" z-dropif-nc "DROP TABLE IF EXISTS $CTABLE"
  if run z-drop-verify "SHOW TABLES"; then
    fetch_all_table_names "$(query_id_of z-drop-verify)" "$RUN_DIR/z-drop-verify.rows.txt"
    drop_count=$(grep -Fxc "$CTABLE" "$RUN_DIR/z-drop-verify.rows.txt")
    info_row z-drop-verify-check "件数=$drop_count（$CTABLE が <DB> から消えたか。0 なら NC の DROP TABLE IF EXISTS で消えた）"
  else
    info_row z-drop-verify-check "SHOW TABLES が通らず確かめられなかった"
  fi
else
  for label in z-ctas-verify z-insert-nc z-dropif-nc z-drop-verify; do
    skip "$label" "CTAS が開始できなかったため未測定"
  done
  skip z-ctas-verify-check "CTAS が開始できなかったため未測定"
  skip z-drop-verify-check "CTAS が開始できなかったため未測定"
fi

# --- 実在しない表の DROP ----------------------------------------------------------

run_in_ctx "$NC_CTX" z-dropnope-nc "DROP TABLE IF EXISTS $NOPE"

# --- Database を省いた Context ------------------------------------------------------

if [ -n "$TARGET_TABLE" ]; then
  run_in_ctx "$NC_NODB_CTX" z-desc-nodbctx "DESCRIBE $DB.$TARGET_TABLE"
  run_in_ctx "$NC_NODB_CTX" z-sel-nodbctx "SELECT * FROM $DB.$TARGET_TABLE"
else
  skip z-desc-nodbctx "対象テーブルが無いため未測定"
  skip z-sel-nodbctx "対象テーブルが無いため未測定"
fi

# --- 大文字小文字違いの既存カタログ名との対照 -------------------------------------------

if [ -n "$TARGET_TABLE" ]; then
  run_in_ctx "$UPPER_CTX" z-sel1-upper "SELECT * FROM $TARGET_TABLE"
else
  skip z-sel1-upper "対象テーブルが無いため未測定"
fi

# --- 後始末（PROBE_DDL=1 のときだけ） -----------------------------------------------

if [ "$PROBE_DDL" = 1 ] && [ "$CTAS_STARTED" = 1 ]; then
  run z-drop-c-cleanup "DROP TABLE IF EXISTS $DB.$CTABLE"
  if succeeded z-drop-c-cleanup; then
    CTABLE_CREATED=0
  else
    echo "== 後始末の DROP TABLE（$CTABLE）が SUCCEEDED になりませんでした。終了時にもう一度投げます。"
    echo "   それでも消えなければ、$DB の $CTABLE を手で消してください。"
  fi
else
  skip z-drop-c-cleanup "CTAS が開始できなかったため後始末不要"
fi

if [ "$PROBE_DDL" = 1 ] && [ "$D_SETUP_OK" = 1 ]; then
  run z-drop-hive "DROP TABLE IF EXISTS $PROBE_PREFIX"
  if succeeded z-drop-hive; then
    DDL_ATTEMPTED=0
  else
    echo "== 後始末の DROP TABLE が SUCCEEDED になりませんでした。終了時にもう一度投げます。"
    echo "   それでも消えなければ、$DB の $PROBE_PREFIX を手で消してください。"
  fi
fi

# --- summary -----------------------------------------------------------------

ALL_LABELS="probe-show-tables d0-setup-hive"
ALL_LABELS="$ALL_LABELS z-sel1-nc z-sel1-ok z-sel2-nc z-sel3-nc"
ALL_LABELS="$ALL_LABELS z-selnope-nc z-selnope-ok z-selnodb-nc z-selnodb-ok"
ALL_LABELS="$ALL_LABELS z-showtables-nc z-showdb-nc z-showcreate-nc z-tblprops-nc z-showviews-nc"
ALL_LABELS="$ALL_LABELS z-explain-nc"
ALL_LABELS="$ALL_LABELS z-ctas-nc z-ctas-verify z-insert-nc z-dropif-nc z-drop-verify z-drop-c-cleanup"
ALL_LABELS="$ALL_LABELS z-dropnope-nc"
ALL_LABELS="$ALL_LABELS z-desc-nodbctx z-sel-nodbctx"
ALL_LABELS="$ALL_LABELS z-sel1-upper"
ALL_LABELS="$ALL_LABELS z-drop-hive"

write_summary_txt() {
  local txt="$RUN_DIR/summary.txt"
  {
    echo "# issue #214: StartQueryExecution の QueryExecutionContext.Catalog に実在しない"
    echo "#             カタログ名を渡したとき、本物の Athena が文の種類ごとにどう解決するかを実測"
    echo "# 実行日時: $(date -Iseconds)"
    echo "# 背景（2026-09-25 実測の #212）: Catalog=nocatalog_212・Database=<実在の DB> の"
    echo "#   Context で SELECT 1・DESCRIBE t・SHOW COLUMNS FROM t は SUCCEEDED、実在しない表の"
    echo "#   DESCRIBE は Entity Not Found（既定の AwsDataCatalog で解決しているように見える）。"
    echo "# StartQueryExecution の見込み本数: 27（PROBE_DDL=1・CTAS が開始できたとき）／"
    echo "#   22（CTAS が開始時に弾かれ、DDL・DML 群の後続 5 本を未測定にしたとき）／"
    echo "#   19（PROBE_DDL=0。準備・後始末・DDL・DML 群がまるごと無い）。"
    echo "#   実測値（このラウンドで実際に呼んだ回数、再試行込み）: $(wc -l < "$START_CALL_FILE" | tr -d ' ')"
    echo "# DDL: 準備 CREATE TABLE <DB>.athena_local_probe_214 AS SELECT 1 AS n, 'x' AS s"
    echo "#   （OK Context）→ 後始末 DROP TABLE IF EXISTS athena_local_probe_214（OK Context、"
    echo "#   z-drop-hive）。PROBE_DDL=1 のときだけ、別に athena_local_probe_214_c を"
    echo "#   CREATE TABLE（z-ctas-nc、NC Context・1 部の名前）・INSERT（z-insert-nc、NC）・"
    echo "#   DROP TABLE IF EXISTS（z-dropif-nc、NC）した後、OK Context の"
    echo "#   DROP TABLE IF EXISTS <DB>.athena_local_probe_214_c（z-drop-c-cleanup）で必ず消す。"
    echo "#   trap にも同じ 2 本の DROP（OK Context）を保険として持つ。"
    echo "# 課金: 準備の表・athena_local_probe_214_c ともに 1 行だけ（CTAS 1 行・INSERT 1 行）。"
    echo "#   DESCRIBE・SHOW 系・EXPLAIN・DROP はメタデータのみ。SELECT はどれも 1 行の表を読むだけ。"
    echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
    echo
    echo "## 投げた文（DB 名・テーブル名・Context は伏せる。実名は各 <label>.sql・<label>.context.txt を参照）"
    for label in $ALL_LABELS; do
      if [ -s "$RUN_DIR/$label.sql" ]; then
        local ctx_shown="-"
        if [ -s "$RUN_DIR/$label.context.txt" ]; then
          ctx_shown=$(sanitize "$(hide "$(cat "$RUN_DIR/$label.context.txt")")")
        fi
        echo "- $label: $(sanitize "$(hide "$(cat "$RUN_DIR/$label.sql")")")（Context: $ctx_shown）"
      fi
    done
    echo
    echo "## 項目ごとの結果"
    echo "#   qec_catalog/qec_database  GetQueryExecution が返した QueryExecutionContext"
    echo "#                             （送った Context と違えば、それが解決の証拠になる）"
    echo "#   start_message/start_athena_error_code  開始時に弾かれた項目の Message・AthenaErrorCode"
    echo "#   error_category/error_type/error_message  開始できて FAILED になった項目の AthenaError"
    echo "#   reason_line  StateChangeReason の 1 行目（無ければ -）"
    python3 - "$SUMMARY" <<'PYEOF'
import csv, sys
with open(sys.argv[1], newline="") as f:
    for row in csv.DictReader(f, delimiter="\t"):
        print(
            "- {label}: state={state} statement_type={statement_type}/{substatement_type} "
            "qec={qec_catalog}/{qec_database} "
            "start_message={start_message} start_athena_error_code={start_athena_error_code} "
            "error={error_category}/{error_type}/{error_message} "
            "reason={reason_line} note={note}".format(**row)
        )
PYEOF
    echo
    echo "## 開始できなかった項目の文言（実名は伏せる）"
    for label in $ALL_LABELS; do
      if [ -s "$RUN_DIR/$label.start.err" ]; then
        echo "### $label"
        hide "$(cat "$RUN_DIR/$label.start.err")"
        echo
      fi
    done
    echo
    echo "## 失敗した項目の理由（実名は伏せる。伏せ漏れが無いか貼る前に確認すること）"
    for label in $ALL_LABELS; do
      if [ -s "$RUN_DIR/$label.reason.txt" ] && ! grep -q "^State: SUCCEEDED" "$RUN_DIR/$label.reason.txt"; then
        echo "### $label"
        hide "$(cat "$RUN_DIR/$label.reason.txt")"
        echo
        echo
      fi
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
echo "<label>.sql・<label>.context.txt・<label>.reason.txt・<label>.start.err・<label>.rows.txt は"
echo "実名（DB 名・テーブル名）を含みうるので、summary.txt 以外を貼るときは中身を確かめてください。"
