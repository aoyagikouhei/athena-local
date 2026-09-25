#!/usr/bin/env bash
# issue #208 で作成
# 本物の Athena が StartQueryExecution の時点で弾く、無引用の DDL 3 種
# （ALTER TABLE IF EXISTS、ALTER TABLE ... ADD COLUMN（単数）、場所の無い CREATE TABLE）の
# 弾かれ方の規則（`line L:C` の位置、`no viable alternative at input '...'` の input の範囲、
# どの形で文言の種類が変わるか）を洗い出す。athena-local は Trino がこれらを受け付けて
# しまうため実行してしまう（#208 の背景）。athena-local 側を本物に揃える対応の材料として、
# このスクリプトで文言の規則と、Trino にだけある他の ALTER・CREATE の範囲を測る。
#
# 既知の実測（生データ ~/athena-*-measurements。issue #208 本文より）:
#   ALTER TABLE IF EXISTS <t> RENAME TO <t2>
#     → line 1:16: no viable alternative at input 'ALTER TABLE IF EXISTS'（引用符の有無によらず）
#   ALTER TABLE IF EXISTS <db>.<t> ADD COLUMNS (m2 int)
#     → line 1:68: mismatched input 'COLUMNS'. Expecting: '.', 'ADD'（Trino 形の文言）
#   ALTER TABLE <t> ADD COLUMN m int
#     → line 1:45: no viable alternative at input 'ALTER TABLE <t> ADD COLUMN'（位置は COLUMN の先頭）
#   CREATE TABLE <t> (n int) など、場所の無い CREATE TABLE
#     → No location was specified for table. An S3 location must be specified（位置なし）
#   CREATE TABLE <db>.<t> (n int NOT NULL) WITH (...)
#     → line 1:68: no viable alternative at input 'CREATE TABLE <db>.<t> (n int NOT'
#
# tools/measure/quoted-names.sh（#204・#207・#212）を雛形にし、次の関数をそのまま
# （ほぼ無改変で）流用している: redact・mask_names・hide・sanitize・first_err_line・
# is_transient_error・start_query_retry・poll_until_terminal・get_state_once・
# read_attempts・emit_row・skip・run・write_reason・reason_first_line・
# athena_error_fields_of・read_execution_fields・start_err_message・start_err_code・
# query_id_of・succeeded・cleanup・write_summary_txt。
#
# 雛形からの変更点:
#   - ROUND の切り替えは無い（依頼どおり全項目を 1 ラウンドで測る）。name_form・
#     four_part_form・fetch_all_table_names（引用符付きの名前の形の生成・S3 の読み出し）は
#     持ち込んでいない。この実測は「開始時に弾かれたか」「開始できたら最終状態と理由」だけを
#     見れば足りる。
#   - 対象の名前は固定の接頭辞ではなく、実行のたびに乱数を足した接頭辞
#     （athena_local_probe_208_<4 桁 16 進>）を使う。テーブルを作る CREATE 系の項目は
#     項目ごとに別名（<接頭辞>_c1 など）にするので、雛形の「同じ接頭辞のテーブルが
#     既に無いか確かめてから始める」チェックは不要にした（乱数が毎回変わるため衝突しない）。
#   - CREATE TABLE を投げて想定外に成功したときの後始末は、雛形の run_create_guarded
#     （1 項目に対して 1 つの真偽値フラグを対応させる作り）ではなく、作られたかもしれない
#     テーブル名の集合 PENDING_DROPS（連想配列）で管理する run_create_then_drop にした。
#     C1〜C23 のどれで想定外の成功が起きても、この 1 つの仕組みで拾える
#     （trap の cleanup は PENDING_DROPS に残っている名前だけを対象に DROP を投げる）。
#   - S3 Tables は C20 の 1 項目だけなので、雛形のような専用の真偽値フラグ
#     （C20_CREATED）と、S3 Tables 側の QueryExecutionContext で DROP を投げる
#     cleanup_drop_in_ctx を新設した。
#   - 疎通 preflight（SELECT 1）を、既定の QueryExecutionContext とは別に
#     Catalog だけを渡す run_in_ctx で投げる（Database の指定が無くても届くかどうかを
#     DB の実在確認より先に確かめるため。雛形の run_in_ctx をそのまま使う）。
#   - 実在する表が要る項目（B10・C15 の対照）のために、実在する表を 1 つ作る
#     セットアップを新設した（雛形の d0-setup-hive と同じ「WITH 句を付けない CTAS」の
#     形を流用。issue 本文が挙げた `WITH (format='PARQUET')` は、本物で
#     external_location が要るかもしれないため、雛形で実測済みの安全な形にした）。
#   - 【コーディネーターからの追加指示】C22 `CREATE TABLE X (n string)`、
#     C23 `CREATE TABLE X (n array<int>)` を追加した（手元の Trino 482 は受理するとのことで、
#     C3・C21 と同じ「作られうる」扱いにし、run_create_then_drop で後始末する）。
#
# 使い方:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db bash tools/measure/unquoted-ddl.sh
#   S3 Tables も測るとき（C20 だけに効く。両方揃ったときだけ）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns \
#     bash tools/measure/unquoted-ddl.sh
#   （資格情報はホストのシェルで AWS_ACCESS_KEY_ID などを export してから。または ~/.aws/credentials）
#
# 必要な環境変数:
#   OUTPUT    結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける）。
#   DB        データベース名。実在するものを指定する。
#
# 任意の環境変数:
#   CATALOG          既定 AwsDataCatalog
#   REGION           既定 ap-northeast-1
#   OUT_DIR          既定 ${DEV_HOST_HOME:-$HOME}/athena-unquoted-ddl-measurements
#                    （実名が入るのでリポジトリの外に出す）
#   POLL_TIMEOUT     終端状態を待つ上限（秒）。既定 180
#   RETRY_MAX        名前解決・接続など一時的な失敗を再試行する回数の上限。既定 4
#   RETRY_DELAY      再試行の間隔（秒）。既定 5
#   S3TABLES_CATALOG S3 Tables のカタログ名（例 s3tablescatalog/my-bucket）。
#   S3TABLES_NS      S3 Tables の名前空間。
#                    この 2 つが揃ったときだけ C20（S3 Tables への場所の無い CREATE TABLE）を
#                    測る。1 つでも欠けていれば「未測定（S3TABLES_* 未設定）」として summary に残す。
#
# ** このスクリプトが本物に対して行う破壊的な操作 **
#   - 実在する表 <db>.athena_local_probe_208_<乱数>_real を 1 つ CTAS で作り、
#     最後に無引用 + IF EXISTS の DROP TABLE で消す（異常終了時も trap で同じ形で消しにいく）。
#     作れなければ B10 だけ未測定にし、C15 は実在しない名前を対象にする。
#   - C3・C20（S3TABLES_* が揃うときだけ）・C21・C22・C23 は、場所の指定や Hive 互換の
#     型名によって受理され、実際にテーブルが作られる見込み（本物の書き方の対照、または
#     手元の Trino 482 で受理を確認済み）。受理できたらその場で無引用 + IF EXISTS の
#     DROP TABLE を投げて消す（結果は確かめる。SUCCEEDED にならなければ trap がもう一度
#     ベストエフォートで投げる）。
#   - それ以外の C1〜C19（C3 を除く）・C22・C23 を除く項目は「開始時に弾かれる」見込みだが、
#     想定に反して受理されて表ができてしまった場合も、同じ仕組み（run_create_then_drop）で
#     その場で DROP を投げて消す。
#   - ALTER TABLE・DROP は実在しない名前（<接頭辞>_nope）にだけ投げるので、対象のテーブル
#     自体は作らない（後始末の対象にもならない）。B10 だけ実在する表 <接頭辞>_real に対して
#     ADD COLUMN を投げるが、ADD COLUMN 自体は失敗する見込み（表そのものは消さずに残し、
#     最後の後始末でまとめて消す）。
#
# 課金について: ALTER TABLE・DROP TABLE はメタデータだけを見る／書く文で、実データの
# スキャンは無い。CREATE TABLE（実在する表の準備・C3・C20・C21・C22・C23、いずれも 0〜1 行）も
# スキャンや書き込みは軽微。Athena の最小課金 × クエリ数の見込み。
#
# 本物への呼び出し回数の見込み（内訳。実際の回数は下で更新される。GetQueryExecution は
# poll_until_terminal のポーリング + 終端後の 1 回で、開始できた項目の数 × 数回のオーダー。
# メタデータだけの操作なのでどれも数秒で終わる見込み）:
#
#   [StartQueryExecution]
#   preflight（SELECT 1 + SHOW TABLES）2
#   + 実在する表の準備 1・後始末 1
#   + A 群（ALTER TABLE IF EXISTS、A1〜A19）19
#   + B 群（ADD COLUMN 単数、B1〜B12）12
#   + B' 群（Trino にだけある他の ALTER、B13〜B19）7
#   + C1〜C19（場所の無い CREATE TABLE。C3 だけ location 指定で受理される見込み）19
#     + C3 の後始末 1（受理される見込みのときだけ実際に呼ぶ。他の 18 項目は開始時に弾かれる
#       見込みなので後始末は skip で呼ばない）
#   + C20（S3 Tables。S3TABLES_* が揃うときだけ）受理される見込みなので 1 + 後始末 1
#   + C21（本物の LOCATION 句。受理される見込み）1 + 後始末 1
#   + C22（string 型。受理される見込み）1 + 後始末 1
#   + C23（array<int> 型。受理される見込み）1 + 後始末 1
#   = 68（S3TABLES_* 無し）／70（S3TABLES_* あり）。
#   想定に反して開始時に弾かれなかった項目（C3・C20・C21・C22・C23 以外）があれば、その
#   後始末が 1 本ずつ増える。逆に C3・C20・C21・C22・C23 が想定に反して開始時に弾かれれば、
#   その後始末は skip になり呼ばない（その分 1 本ずつ減る）。
#   DB が実在しなければ、SHOW DATABASES の 1 回を追加で呼んで（候補一覧をファイルに残して）
#   その場で止まる（以降は呼ばない）。
#
#   [GetQueryExecution]
#   実際に開始できた（QueryExecutionId が取れた）項目だけ、終端状態になるまで 1 秒間隔で
#   ポーリングし（poll_until_terminal）、終端後にもう 1 回まとめて取得する。見込みは
#   preflight 2・準備/後始末 2・C3/C20/C21/C22/C23 とその後始末 8〜10 の、合計 12〜14 項目
#   × 2〜4 回で、だいたい 25〜55 回程度（メタデータだけの操作で数秒以内に終わる想定）。
#
#   開始時に弾かれた（START_FAILED）項目があっても追加の呼び出しはしない
#   （AthenaErrorCode・Message は同じ標準エラーからそのまま抜くため）。
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く。前の回の結果と混ざらない。
#
# 項目ごとに次を保存する（取れたものだけ）。
#   <label>.sql            投げた SQL そのもの（**DB 名・テーブル名を含む。実名を含む**）
#   <label>.start.err      StartQueryExecution の標準エラー（開始時に弾かれた証拠）。
#                          一切加工せず AWS CLI の出力そのまま保存する。
#   <label>.execution.json GetQueryExecution の生の応答（開始できた項目だけ）
#   <label>.execution.err  GetQueryExecution の標準エラー
#   <label>.reason.txt     StateChangeReason と AthenaError（**実名を含みうる。貼る前に確認**）
#   available-databases.rows.txt  DB が実在しなかったときの候補一覧（**実名**）
#
# summary の決め手になる列は state・statement_type/substatement_type・
# start_message/start_athena_error_code（開始時に弾かれた項目）・
# error_category/error_type/error_message（開始できて FAILED になった項目）。
# DB 名・出力先・バケット名・対象テーブル名・S3 Tables の名前は出さず、プレースホルダに
# 畳む。summary.tsv / summary.txt はそのまま貼れる。
#
# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください}"
: "${DB:?DB にデータベース名を設定してください}"
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_DIR=${OUT_DIR:-${DEV_HOST_HOME:-$HOME}/athena-unquoted-ddl-measurements}
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

# 実行のたびに変わる乱数入りの接頭辞。CREATE の対象は項目ごとに <PREFIX>_c1 のように別名。
RAND_SUFFIX=$(printf '%04x' $((RANDOM % 65536)))
PROBE_PREFIX="athena_local_probe_208_${RAND_SUFFIX}"
NOPE="${PROBE_PREFIX}_nope"
NOPE2="${PROBE_PREFIX}_nope2"
REAL="${PROBE_PREFIX}_real"

new_name() { printf '%s_%s' "$PROBE_PREFIX" "$1"; }

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\tstatement_type\tsubstatement_type\tstart_message\tstart_athena_error_code\terror_category\terror_type\terror_message\treason_line\tnote\n' > "$SUMMARY"
echo "出力先: $RUN_DIR"

# StartQueryExecution を実際に呼んだ回数（再試行も含む）。summary.txt の冒頭に出す。
START_CALL_FILE="$RUN_DIR/.start-calls"
: > "$START_CALL_FILE"

# 実在する表のセットアップに着手したかどうか。trap での後始末に使う（雛形の DDL_ATTEMPTED）。
REAL_SETUP_ATTEMPTED=0
REAL_SETUP_OK=0
# C1〜C23 のどれかで CREATE TABLE が想定外に（あるいは想定どおり C3/C20/C21/C22/C23 で）
# 成功し、まだ消せていないテーブル名の集合。キーは DB 名を付けない裸のテーブル名。
declare -A PENDING_DROPS=()
# C20（S3 Tables）だけ、DB とは別カタログ・別名前空間に作るので専用のフラグにする。
C20_CREATED=0

# StartQueryExecution に渡す QueryExecutionContext。ふだんは CATALOG・DB で、
# run_in_ctx で 1 文だけ差し替える（preflight・C20）。
QE_CONTEXT="Catalog=$CATALOG,Database=$DB"

# trap の後始末で 1 文だけ投げる（結果は確かめない）。既定の Catalog/DB。
cleanup_drop() {
  aws athena start-query-execution --region "$REGION" \
    --query-string "$1" \
    --query-execution-context "Catalog=$CATALOG,Database=$DB" \
    --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
}

# trap の後始末で 1 文だけ、指定した QueryExecutionContext で投げる（C20 用）。
cleanup_drop_in_ctx() {
  local ctx=$1 sql=$2
  aws athena start-query-execution --region "$REGION" \
    --query-string "$sql" \
    --query-execution-context "$ctx" \
    --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
}

# 中間ファイル（.tmp-*）は、途中で止めても残らないよう trap で消す。実在する表の
# セットアップに着手していたら、ベストエフォートで後始末を投げる。PENDING_DROPS に
# 残っている名前（本編の -cleanup で消せなかったもの）も同様にベストエフォートで消す。
cleanup() {
  rm -f "$RUN_DIR"/.tmp-*
  if [ "$REAL_SETUP_ATTEMPTED" = 1 ]; then
    cleanup_drop "DROP TABLE IF EXISTS $REAL"
  fi
  local name
  for name in "${!PENDING_DROPS[@]}"; do
    cleanup_drop "DROP TABLE IF EXISTS $name"
  done
  if [ "$C20_CREATED" = 1 ] && [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
    cleanup_drop_in_ctx "Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS" \
      "DROP TABLE IF EXISTS $(new_name c20)"
  fi
}
trap cleanup EXIT

# 実名（DB 名・出力先・バケット名・アカウント ID・接頭辞の乱数）を置換して隠す。
# アカウント ID は、前後が数字でない 12 桁の数字として伏せる（quoted-names.sh の実測より）。
OUTPUT_BUCKET=${OUTPUT#s3://}
OUTPUT_BUCKET=${OUTPUT_BUCKET%%/*}
redact() {
  local s=$1
  s=${s//$DB/<DB>}
  s=${s//$OUTPUT/<OUTPUT>}
  s=${s//$OUTPUT_BUCKET/<BUCKET>}
  printf '%s' "$s" | sed -E 's/(^|[^0-9])[0-9]{12}([^0-9]|$)/\1<ACCOUNT_ID>\2/g'
}

# 標準入力から、乱数入りの接頭辞と S3 Tables の実名（設定されていれば）を置換して隠す。
mask_names() {
  local s
  s=$(cat)
  s=${s//$PROBE_PREFIX/<PROBE>}
  if [ -n "$S3TABLES_CATALOG" ]; then
    s=${s//$S3TABLES_CATALOG/<S3TABLES_CATALOG>}
    if [ -n "$S3TABLES_BUCKET" ]; then
      s=${s//$S3TABLES_BUCKET/<S3TABLES_BUCKET>}
    fi
  fi
  if [ -n "$S3TABLES_NS" ]; then
    s=${s//$S3TABLES_NS/<S3TABLES_NS>}
  fi
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

# start.err から Message と AthenaErrorCode を抜く（quoted-names.sh の実測どおり、
# 開始時に弾かれた StartQueryExecution の標準エラーに追加の呼び出し無しで両方出る）。
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

# execution.json から AthenaError の ErrorCategory / ErrorType / ErrorMessage を
# タブ区切りで返す（無ければ 3 つとも "-"）。
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

# execution.json から StatementType / OutputLocation / SubstatementType をタブ区切りで返す。
read_execution_fields() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception:
    print("-\t\t-")
    sys.exit(0)
print("%s\t%s\t%s" % (d.get("StatementType") or "-", d.get("ResultConfiguration", {}).get("OutputLocation", ""), d.get("SubstatementType") or "-"))' "$1"
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

# summary.tsv に 1 行積む。列の並びはヘッダと同じ 11 列で固定する。
emit_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$SUMMARY"
}

# 項目を未測定として summary に 1 行残す。全体を止めずに次へ進む。
skip() {
  local label=$1 note=$2
  echo "== $label: 未測定（$note）"
  emit_row "$label" "SKIPPED" - - - - - - - - "$(sanitize "$note")"
}

# ラベルを指定して 1 文を実行する。開始できなければ、AthenaErrorCode・Message を
# その場の start.err からそのまま抜く（追加の呼び出しはしない）。開始できたら終端状態まで
# 待って StatementType・SubstatementType・FAILED の理由を採る。
run() {
  local label=$1 sql=$2
  local id state stype sub note reason_line
  local start_msg="-" start_code="-" err_cat="-" err_type="-" err_msg="-"

  printf '%s\n' "$sql" > "$RUN_DIR/$label.sql"
  id=$(start_query_retry "$label" "$sql")
  LAST_ATTEMPTS=$(read_attempts "$label")

  if [ -z "${id:-}" ]; then
    note="attempts=$LAST_ATTEMPTS; $(first_err_line "$RUN_DIR/$label.start.err")"
    start_msg=$(start_err_message "$RUN_DIR/$label.start.err")
    start_code=$(start_err_code "$RUN_DIR/$label.start.err")
    echo "== $label: 開始できませんでした（試行 $LAST_ATTEMPTS 回）。AthenaErrorCode=$start_code"
    emit_row "$label" "START_FAILED" - - "$start_msg" "$start_code" - - - - "$(sanitize "$note")"
    return 1
  fi

  state=$(poll_until_terminal "$id")

  aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.execution.json" 2> "$RUN_DIR/$label.execution.err"
  write_reason "$RUN_DIR/$label.execution.json" "$RUN_DIR/$label.reason.txt"
  reason_line=$(reason_first_line "$RUN_DIR/$label.execution.json")

  IFS=$'\t' read -r stype _ sub < <(read_execution_fields "$RUN_DIR/$label.execution.json")

  note="attempts=$LAST_ATTEMPTS"
  case "$state" in
    FAILED | CANCELLED)
      IFS=$'\t' read -r err_cat err_type err_msg < <(athena_error_fields_of "$RUN_DIR/$label.execution.json")
      err_msg=$(sanitize "$(hide "$err_msg")")
      ;;
  esac

  echo "== $label  state=$state  stype=$stype/$sub  error=$err_cat/$err_type"
  emit_row "$label" "$state" "$stype" "$sub" "$start_msg" "$start_code" \
    "$err_cat" "$err_type" "$err_msg" "$reason_line" "$(sanitize "$note")"
  [ "$state" = SUCCEEDED ]
}

# QueryExecutionContext を $1 に差し替えて run を 1 回呼ぶ（preflight・C20 で使う）。
run_in_ctx() {
  local ctx=$1 label=$2 saved=$QE_CONTEXT rc
  shift
  printf '%s\n' "$ctx" > "$RUN_DIR/$label.context.txt"
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

# CREATE TABLE を投げ、成功したら（想定どおりでも想定外でも）その場で
# DROP TABLE IF EXISTS <name> を <label>-cleanup として投げて消す。成功するまで
# PENDING_DROPS[name] を立てておき、後始末が SUCCEEDED になったら下ろす（trap の保険が
# 対象にする名前の集合）。CREATE TABLE が失敗したら後始末は未測定の行だけ残す。
run_create_then_drop() {
  local label=$1 sql=$2 name=$3
  if run "$label" "$sql"; then
    PENDING_DROPS[$name]=1
    run "$label-cleanup" "DROP TABLE IF EXISTS $name"
    if succeeded "$label-cleanup"; then
      unset 'PENDING_DROPS[$name]'
    fi
  else
    skip "$label-cleanup" "CREATE TABLE が失敗したため後始末不要"
  fi
}

# --- preflight -----------------------------------------------------------------
# Database を渡さず Catalog だけで疎通を確かめる（DB の実在確認より先に、資格情報や
# エンドポイントの問題を切り分ける）。

if ! run_in_ctx "Catalog=$CATALOG" preflight-select1 "SELECT 1"; then
  echo
  echo "疎通確認（SELECT 1）が通りませんでした。資格情報かエンドポイント（REGION=$REGION）を"
  echo "確かめてください。理由: $RUN_DIR/preflight-select1.reason.txt"
  echo "（開始すらできなければ $RUN_DIR/preflight-select1.start.err）"
  exit 1
fi

# --- DB の実在確認 ---------------------------------------------------------------

fetch_all_rows() {
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

if ! run probe-show-tables "SHOW TABLES"; then
  echo
  echo "SHOW TABLES が通りませんでした。DB が実在しないかもしれません。"
  echo "理由: $RUN_DIR/probe-show-tables.reason.txt"
  if run_in_ctx "Catalog=$CATALOG" available-databases "SHOW DATABASES"; then
    fetch_all_rows "$(query_id_of available-databases)" "$RUN_DIR/available-databases.rows.txt"
    echo "候補の一覧: $RUN_DIR/available-databases.rows.txt（実名を含むので確認してから使ってください）"
  fi
  exit 1
fi

# --- 実在する表のセットアップ（B10・C15 の対照に使う） -----------------------------
# WITH (format='PARQUET') は本物で external_location が要るかもしれないため、
# quoted-names.sh の d0-setup-hive と同じ「WITH 句を付けない CTAS」の形にした。

REAL_SETUP_ATTEMPTED=1
if run setup-real "CREATE TABLE $DB.$REAL AS SELECT 1 AS n, 'x' AS s, 10 AS x"; then
  REAL_SETUP_OK=1
else
  echo "== setup-real: 実在する表が作れませんでした。B10 は未測定にし、C15 は実在しない名前を対象にします。"
fi

if [ "$REAL_SETUP_OK" = 1 ]; then
  LIKE_TARGET="$DB.$REAL"
else
  LIKE_TARGET="$NOPE"
fi

# --- A 群（ALTER TABLE IF EXISTS。続く操作と位置の規則） ----------------------------

run a1  "ALTER TABLE IF EXISTS $NOPE RENAME TO $NOPE2"
run a2  "ALTER TABLE IF EXISTS $NOPE ADD COLUMN m int"
run a3  "ALTER TABLE IF EXISTS $NOPE ADD COLUMNS (m int)"
run a4  "ALTER TABLE IF EXISTS $NOPE DROP COLUMN m"
run a5  "ALTER TABLE IF EXISTS $NOPE RENAME COLUMN a TO b"
run a6  "ALTER TABLE IF EXISTS $NOPE SET PROPERTIES x = 1"
run a7  "ALTER TABLE IF EXISTS $NOPE SET TBLPROPERTIES ('a'='b')"
run a8  "ALTER TABLE IF EXISTS $NOPE EXECUTE optimize"
run a9  "ALTER TABLE IF EXISTS $NOPE ADD COLUMN IF NOT EXISTS m int"
run a10 "ALTER TABLE IF EXISTS $NOPE ALTER COLUMN m SET DATA TYPE bigint"
run a11 "ALTER TABLE IF EXISTS $DB.$NOPE RENAME TO $DB.$NOPE2"
run a12 "ALTER TABLE IF EXISTS awsdatacatalog.$DB.$NOPE RENAME TO $DB.$NOPE2"
run a13 "alter table if exists $NOPE rename to $NOPE2"
run a14 "/* c */ ALTER TABLE IF EXISTS $NOPE RENAME TO $NOPE2"
# 改行を挟む形。$'...' は変数展開しないので、改行だけを断片にして隣接させて連結する
# （tools/measure/leading-comment.sh の注意のとおり）。
run a15 "ALTER TABLE"$'\n'"IF EXISTS $NOPE RENAME TO $NOPE2"
run a16 "ALTER  TABLE  IF  EXISTS $NOPE RENAME TO $NOPE2"
run a17 "ALTER TABLE /* c */ IF EXISTS $NOPE RENAME TO $NOPE2"
run a18 "ALTER TABLE IF EXISTS $DB.$NOPE ADD COLUMNS (m int)"
run a19 "ALTER TABLE IF EXISTS $NOPE DROP COLUMN IF EXISTS m"

# --- B 群（ADD COLUMN 単数） ------------------------------------------------------

run b1  "ALTER TABLE $NOPE ADD COLUMN m int"
run b2  "alter table $NOPE add column m int"
run b3  "/* c */ ALTER TABLE $NOPE ADD COLUMN m int"
run b4  "ALTER TABLE $NOPE ADD"$'\n'"COLUMN m int"
run b5  "ALTER TABLE $NOPE ADD /* c */ COLUMN m int"
run b6  "ALTER TABLE $DB.$NOPE ADD COLUMN m int"
run b7  "ALTER TABLE awsdatacatalog.$DB.$NOPE ADD COLUMN m int"
run b8  "ALTER TABLE $NOPE ADD COLUMN IF NOT EXISTS m int"
run b9  "ALTER TABLE $NOPE ADD COLUMN m int COMMENT 'x'"
if [ "$REAL_SETUP_OK" = 1 ]; then
  run b10 "ALTER TABLE $DB.$REAL ADD COLUMN m int"
else
  skip b10 "実在する表を作れなかったため未測定"
fi
run b11 "ALTER TABLE $NOPE  ADD  COLUMN m int"
run b12 "ALTER TABLE $NOPE ADD COLUMN m varchar"

# --- B' 群（Trino にだけある他の ALTER。範囲の把握用。IF EXISTS 無し） -------------------

run b13 "ALTER TABLE $NOPE RENAME COLUMN a TO b"
run b14 "ALTER TABLE $NOPE SET PROPERTIES x = 1"
run b15 "ALTER TABLE $NOPE EXECUTE optimize"
run b16 "ALTER TABLE $NOPE ALTER COLUMN m SET DATA TYPE bigint"
run b17 "ALTER TABLE $NOPE DROP COLUMN IF EXISTS m"
run b18 "ALTER TABLE $NOPE SET AUTHORIZATION someone"
run b19 "ALTER TABLE $NOPE DROP COLUMN m"

# --- C 群（場所の無い CREATE TABLE） -----------------------------------------------

run_create_then_drop c1  "CREATE TABLE $(new_name c1) (n int)" "$(new_name c1)"
run_create_then_drop c2  "CREATE TABLE $(new_name c2) (n int) WITH (format = 'PARQUET')" "$(new_name c2)"
LOC_C3="${OUTPUT%/}/${PROBE_PREFIX}-c3/"
run_create_then_drop c3  "CREATE TABLE $(new_name c3) (n int) WITH (location = '$LOC_C3')" "$(new_name c3)"
run_create_then_drop c4  "CREATE TABLE $(new_name c4) (n int) COMMENT 'x'" "$(new_name c4)"
run_create_then_drop c5  "CREATE TABLE $(new_name c5) (n varchar)" "$(new_name c5)"
run_create_then_drop c6  "CREATE TABLE $(new_name c6) (n integer)" "$(new_name c6)"
run_create_then_drop c7  "CREATE TABLE $(new_name c7) (n timestamp(3))" "$(new_name c7)"
run_create_then_drop c8  "CREATE TABLE $(new_name c8) (n row(a int))" "$(new_name c8)"
run_create_then_drop c9  "CREATE TABLE $(new_name c9) (n array(int))" "$(new_name c9)"
run_create_then_drop c10 "CREATE TABLE $(new_name c10) (n int COMMENT 'x')" "$(new_name c10)"
run_create_then_drop c11 "CREATE TABLE $(new_name c11) (n int NOT NULL)" "$(new_name c11)"
run_create_then_drop c12 "create table $(new_name c12) (n int)" "$(new_name c12)"
run_create_then_drop c13 "/* c */ CREATE TABLE $(new_name c13) (n int)" "$(new_name c13)"
run_create_then_drop c14 "CREATE TABLE awsdatacatalog.$DB.$(new_name c14) (n int)" "$(new_name c14)"
run_create_then_drop c15 "CREATE TABLE $(new_name c15) (LIKE $LIKE_TARGET)" "$(new_name c15)"
run_create_then_drop c16 "CREATE TABLE $(new_name c16) (n int) WITH (partitioned_by = ARRAY['n'])" "$(new_name c16)"
run_create_then_drop c17 "CREATE TABLE $(new_name c17) (n double, m decimal(10,2), s varchar(10), d date, b boolean)" "$(new_name c17)"
run_create_then_drop c18 "CREATE TABLE $(new_name c18) (n int, m map(varchar, int))" "$(new_name c18)"
run_create_then_drop c19 "CREATE TABLE $(new_name c19) (n int) WITH (table_type = 'ICEBERG')" "$(new_name c19)"

# C20: S3 Tables（S3TABLES_CATALOG・S3TABLES_NS が両方揃ったときだけ）。
# QueryExecutionContext の Catalog を S3 Tables のカタログ、Database を名前空間にして、
# 1 部の名前だけの CREATE TABLE を投げる。引用符付きの形（"<catalog>".<ns>.X）は
# 既に文言が分かっている（quoted-names.sh）ので測らない。
if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  C20_NAME=$(new_name c20)
  S3T_CTX="Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS"
  if run_in_ctx "$S3T_CTX" c20 "CREATE TABLE $C20_NAME (n int)"; then
    C20_CREATED=1
    run_in_ctx "$S3T_CTX" c20-cleanup "DROP TABLE IF EXISTS $C20_NAME"
    if succeeded c20-cleanup; then
      C20_CREATED=0
    fi
  else
    skip c20-cleanup "CREATE TABLE が失敗したため後始末不要"
  fi
else
  skip c20 "未測定（S3TABLES_CATALOG・S3TABLES_NS 未設定）"
  skip c20-cleanup "CREATE TABLE が失敗したため後始末不要"
fi

# C21: 本物の書き方の対照（HiveQL 形の LOCATION 句）。受けて作られる見込み。
LOC_C21="${OUTPUT%/}/${PROBE_PREFIX}-c21/"
run_create_then_drop c21 "CREATE TABLE $(new_name c21) (n int) LOCATION '$LOC_C21'" "$(new_name c21)"

# C22・C23: コーディネーターからの追加指示（手元の Trino 482 が受理すると分かったため）。
# string 型・array<int> 型（Hive 互換の型名）。作られうるので後始末の対象にする。
run_create_then_drop c22 "CREATE TABLE $(new_name c22) (n string)" "$(new_name c22)"
run_create_then_drop c23 "CREATE TABLE $(new_name c23) (n array<int>)" "$(new_name c23)"

# --- 後始末（実在する表） ----------------------------------------------------------

if [ "$REAL_SETUP_OK" = 1 ]; then
  run z-drop-real "DROP TABLE IF EXISTS $DB.$REAL"
  if succeeded z-drop-real; then
    REAL_SETUP_ATTEMPTED=0
  else
    echo "== 後始末の DROP TABLE が SUCCEEDED になりませんでした。終了時にもう一度投げます。"
    echo "   それでも消えなければ、$DB の $REAL を手で消してください。"
  fi
else
  skip z-drop-real "実在する表を作れなかったため後始末不要"
fi

# --- summary ---------------------------------------------------------------------

ALL_LABELS="preflight-select1 probe-show-tables setup-real"
for l in a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17 a18 a19; do
  ALL_LABELS="$ALL_LABELS $l"
done
for l in b1 b2 b3 b4 b5 b6 b7 b8 b9 b10 b11 b12 b13 b14 b15 b16 b17 b18 b19; do
  ALL_LABELS="$ALL_LABELS $l"
done
for l in c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12 c13 c14 c15 c16 c17 c18 c19; do
  ALL_LABELS="$ALL_LABELS $l $l-cleanup"
done
ALL_LABELS="$ALL_LABELS c20 c20-cleanup c21 c21-cleanup c22 c22-cleanup c23 c23-cleanup"
ALL_LABELS="$ALL_LABELS z-drop-real"

write_summary_txt() {
  local txt="$RUN_DIR/summary.txt"
  {
    echo "# issue #208: 無引用の DDL 3 種（ALTER TABLE IF EXISTS、ALTER TABLE ... ADD COLUMN"
    echo "#             単数、場所の無い CREATE TABLE）が StartQueryExecution の時点で弾かれる"
    echo "#             文言の規則と、Trino にだけある他の ALTER・CREATE の範囲を実測"
    echo "# 実行日時: $(date -Iseconds)"
    echo "# StartQueryExecution の見込み本数: 68（S3TABLES_* 無し）／70（あり）"
    echo "#   （preflight 2 + 実在する表の準備/後始末 2 + A 群 19 + B 群 12 + B' 群 7 +"
    echo "#   C1〜C19 19 + C3 の後始末 1 + C21・C22・C23 とその後始末 6、S3TABLES_* が"
    echo "#   揃っていれば C20 とその後始末の 2 が乗る）。"
    echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
    echo "#   （開始時に弾かれた項目があっても追加の呼び出しはしない）。"
    echo "#   想定に反して開始時に弾かれなかった項目があれば後始末が 1 本増え、逆に"
    echo "#   C3・C20・C21・C22・C23 が想定に反して開始時に弾かれれば後始末は skip になり減る。"
    echo "# DDL: 実在する表 <PROBE>_real を 1 つ作って消す。C3・C21・C22・C23（と S3TABLES_* が"
    echo "#   揃えば C20）は受けて作られる見込みで、その場で DROP して消す。それ以外の C 群は"
    echo "#   開始時に弾かれる見込みだが、想定外に成功したら同じ仕組みで消す。ALTER・DROP は"
    echo "#   実在しない名前（<PROBE>_nope）にだけ投げる。"
    echo "# 課金: スキャンの無いクエリだけ（ALTER・DROP はメタデータのみ、CREATE は 0〜1 行）。"
    echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
    echo "#   実測値は既定とは限らない（本物の Athena の挙動が変わっていれば、ここに書いた"
    echo "#   見込みと食い違うことがある）。"
    echo
    if [ -n "${PENDING_DROPS_REPORT:-}" ]; then
      echo "## 要対応・確かめ"
      echo "$PENDING_DROPS_REPORT"
      echo
    fi
    echo "## 投げた文（DB 名・テーブル名は伏せる。実名は各 <label>.sql を参照）"
    for label in $ALL_LABELS; do
      if [ -s "$RUN_DIR/$label.sql" ]; then
        if [ -s "$RUN_DIR/$label.context.txt" ]; then
          echo "- $label: $(sanitize "$(hide "$(cat "$RUN_DIR/$label.sql")")")（QueryExecutionContext: $(sanitize "$(hide "$(cat "$RUN_DIR/$label.context.txt")")")）"
        else
          echo "- $label: $(sanitize "$(hide "$(cat "$RUN_DIR/$label.sql")")")"
        fi
      fi
    done
    echo
    echo "## 項目ごとの結果"
    echo "#   start_message/start_athena_error_code  開始時に弾かれた項目の Message・AthenaErrorCode"
    echo "#   error_category/error_type/error_message  開始できて FAILED になった項目の AthenaError"
    echo "#   reason_line  StateChangeReason の 1 行目（無ければ -）"
    python3 - "$SUMMARY" <<'PYEOF'
import csv, sys
with open(sys.argv[1], newline="") as f:
    for row in csv.DictReader(f, delimiter="\t"):
        print(
            "- {label}: state={state} statement_type={statement_type}/{substatement_type} "
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

# 手で消す必要が残っていれば summary の冒頭に警告を積む（PENDING_DROPS に名前が
# 残っている = 本編の -cleanup では消せず、trap のベストエフォートに委ねた状態）。
if [ "${#PENDING_DROPS[@]}" -gt 0 ] || [ "$C20_CREATED" = 1 ] || [ "$REAL_SETUP_ATTEMPTED" = 1 ]; then
  PENDING_DROPS_REPORT="- **手で消してください**: 次のテーブルが残っているか、消えたか確かめられませんでした。"
  PENDING_DROPS_REPORT="$PENDING_DROPS_REPORT 終了時に trap がもう一度 DROP を投げますが、結果は確かめません。"
  if [ "$REAL_SETUP_ATTEMPTED" = 1 ]; then
    PENDING_DROPS_REPORT="$PENDING_DROPS_REPORT"$'\n'"  - <PROBE>_real（DROP TABLE IF EXISTS で確認）"
  fi
  for name in "${!PENDING_DROPS[@]}"; do
    PENDING_DROPS_REPORT="$PENDING_DROPS_REPORT"$'\n'"  - $(hide "$name")（DROP TABLE IF EXISTS で確認）"
  done
  if [ "$C20_CREATED" = 1 ]; then
    PENDING_DROPS_REPORT="$PENDING_DROPS_REPORT"$'\n'"  - S3 Tables 側の <PROBE>_c20（Catalog=<S3TABLES_CATALOG>,Database=<S3TABLES_NS> で DROP TABLE IF EXISTS）"
  fi
fi

SUMMARY_TXT=$(write_summary_txt)

echo
echo "完了しました。"
echo "機械可読な一覧: $SUMMARY"
echo "そのまま貼れる整形済みの一覧: $SUMMARY_TXT"
echo "中身のファイルは $RUN_DIR にあります。リポジトリには入れないでください。"
echo "<label>.sql・<label>.reason.txt・<label>.start.err は実名（DB 名・テーブル名）を"
echo "含みうるので、summary.txt 以外を貼るときは中身を確かめてください。"
