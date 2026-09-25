#!/usr/bin/env bash
# issue #204 で作成
# 本物の Athena で、引用符付きの名前を取る DESCRIBE・DESC・SHOW CREATE TABLE・
# SHOW COLUMNS・DROP TABLE・ALTER TABLE・MSCK REPAIR TABLE が、StartQueryExecution の
# 時点でどの形なら弾かれ、どの形なら通るか（境界の規則）と、弾かれたときの文言の規則
# （エラー位置 `line L:C` と `input '...'` の中身、Message・AthenaErrorCode）を洗い出す。
# issue #204 のための実測スクリプト。
#
# 背景（`docs/dev/measurements/statements.md` の「引用符付きの名前は空白の有無によらず
# 開始時に弾かれる」節、#200 の実測より）: `DESCRIBE "t"`・`DESC "t"`・
# `SHOW CREATE TABLE "t"`・`DROP TABLE "t"`・`ALTER TABLE "t" ADD COLUMNS (...)`・
# `OPTIMIZE "t" ...` は、単一の引用符付き名前 `"t"` だけで StartQueryExecution が
# InvalidRequestException（MALFORMED_QUERY）になることを確認済み。athena-local は
# SQL を書き換えず・独自に弾かない方針（CLAUDE.md）のため、これらを Trino に投げて
# 実行してしまう（空白ありの形と同じ値を返す。#200 の備考）。athena-local 側を本物に
# 揃える対応の材料として、このスクリプトで境界（`db.t`・`"db"."t"`・3 部修飾・
# バッククォートなど）と文言の規則を洗う。
#
# tools/measure/keyword-boundary.sh（#200）を雛形にしている。redact・mask_names・
# sanitize・first_err_line・is_transient_error・start_query_retry・poll_until_terminal・
# emit_row・skip・preflight（SHOW TABLES → 空なら SHOW DATABASES を案内）・trap での
# 後始末・summary.tsv と summary.txt の 2 段はそのまま流用する。
#
# 雛形からの変更点:
#   - S3 への読み書き（fetch・head_object・.metadata の解析・GetQueryResults の行数採取）は
#     持ち込んでいない。この実測は「開始できたか」「StatementType/SubstatementType」
#     「FAILED の理由」「開始時に弾かれたときの文言」だけを見れば足り、結果ファイルの
#     置き場所や中身は関係ない（CLAUDE.md の不変条件どおり、成功した項目は結果ファイルを
#     置くが、この実測の対象ではない）。preflight の SHOW TABLES の読み出しも S3 の CSV
#     ではなく GetQueryResults（ページングして全件）に替えた（S3 の読み取り権限が
#     無くても preflight が通るようにするため）。
#   - AthenaErrorCode・Message は、追加の呼び出しをせずに、開始時に弾かれた
#     StartQueryExecution の標準エラー（`<label>.start.err`）からそのまま抜く。
#     新しめの AWS CLI は「An error occurred (...) ... operation: <Message>」の行に続けて
#     「Additional error details: / AthenaErrorCode: <コード>」を同じ標準エラーに出す
#     （#200 の実例 `b1.start.err` で確認済み）ので、2 回目の呼び出しは要らない。
#   - 名前の形（n0〜n11）を 1 つの関数 `name_form` に集約し、D/C 群（全 12 形）・
#     E/L/X 群（絞った 6 形）で使い回す。ALTER・DROP は実在しない名前
#     （athena_local_probe_204_nope）にだけ投げ、準備したテーブルには触れない。
#   - P 群（文言の位置の規則: 小文字キーワード・連続空白・改行・先頭空白・先頭コメント・
#     末尾空白）を新設した。改行を挟む形は ANSI-C quoting（`$'...'`）で作る
#     （tools/measure/leading-comment.sh の注意のとおり、$'...' は変数展開しないので
#     改行だけを $'...' の断片にして残りと隣接させて連結する）。
#   - S3 Tables（環境変数 3 つが揃ったときだけ測る任意の群）を新設した。
#   - 【2 ラウンド目】環境変数 `ROUND`（既定 1）でラウンドを切り替える。ROUND=1 は
#     上の D〜P 群・S3 Tables 群（1 ラウンド目と同じ項目。変えていない）を流し、
#     ROUND=2 は下の「ROUND=2 の項目」の U1〜U7 群だけを流す。preflight・準備の
#     Hive テーブル（d0-setup-hive）・後始末（z-drop-hive）は両ラウンド共通。
#
# ROUND=2 の項目（1 ラウンド目 `run-20260925-075408` の結果を踏まえた 2 ラウンド目）:
#   U1  3 部の名前で途中・末尾だけ引用符付き（n12 = awsdatacatalog."db".t、
#       n13 = awsdatacatalog.db."t"）を DESCRIBE・DESC・SHOW CREATE TABLE・
#       SHOW COLUMNS FROM の 4 文に、DROP TABLE には実在しない名前に対して。
#   U2  ALTER で Trino が受ける操作（RENAME TO／DROP COLUMN）を、db."nope"・
#       "db".nope・"awsdatacatalog".db.nope（n14）・awsdatacatalog.db."nope"（n13）の
#       4 形に、加えて ALTER TABLE IF EXISTS の引用符付き／無引用の対。すべて
#       実在しない名前 athena_local_probe_204_nope に対して投げる。
#   U3  S3 Tables（S3TABLES_* が揃うときだけ）。1 ラウンド目は名前空間の綴り違いで
#       対照の SELECT が SCHEMA_NOT_FOUND だったので、正しい値で対照を取り直しつつ、
#       DESCRIBE・DESC・SHOW COLUMNS FROM・SHOW CREATE TABLE・存在しない表への
#       DESCRIBE/DROP/ALTER・名前空間まで引用符付きの形を測る。
#   U4  先頭・区切りの空白（タブ・改行・CRLF・2 連続改行・行コメント後・改行入り
#       ブロックコメント）を ANSI-C quoting（`$'...'`）で作る。DROP にも先頭・区切りの
#       改行を 1 本ずつ。
#   U5  コメントの中の非 ASCII（ひらがな・4 バイトの絵文字）と、存在しない非 ASCII
#       名前 "日本" への DESCRIBE。
#   U6  DESCRIBE EXTENDED／FORMATTED の引用符付きと、対照の無引用 EXTENDED。
#   U7  SHOW TABLES IN／DROP DATABASE IF EXISTS／CREATE TABLE（非 EXTERNAL の Hive。
#       本物では失敗するはずだが、万一成功したら直後に無引用 IF EXISTS の DROP を
#       run で投げて後始末する）を、引用符付き・無引用の対で。
#
# 使い方:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db bash tools/measure/quoted-names.sh
#   2 ラウンド目:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=2 bash tools/measure/quoted-names.sh
#   S3 Tables も測るとき（どちらのラウンドでも指定できる）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=2 \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns S3TABLES_TABLE=your_table \
#     bash tools/measure/quoted-names.sh
#   （資格情報はホストのシェルで AWS_ACCESS_KEY_ID などを export してから。または ~/.aws/credentials）
#
# 必要な環境変数:
#   OUTPUT    結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける）。
#   DB        データベース名。実在するものを指定する。
#
# 任意の環境変数:
#   CATALOG          既定 AwsDataCatalog
#   REGION           既定 ap-northeast-1
#   OUT_DIR          既定 ${DEV_HOST_HOME:-$HOME}/athena-quoted-names-measurements
#                    （実名が入るのでリポジトリの外に出す）
#   POLL_TIMEOUT     終端状態を待つ上限（秒）。既定 180
#   RETRY_MAX        名前解決・接続など一時的な失敗を再試行する回数の上限。既定 4
#   RETRY_DELAY      再試行の間隔（秒）。既定 5
#   PROBE_DDL        既定 1（測る）。準備の Hive テーブル athena_local_probe_204 を
#                    作って対象テーブルが要る群に使い、最後に無引用 + IF EXISTS の
#                    DROP で消す。0 にすると SHOW TABLES の 1 件目（実在のテーブル）を
#                    対象にする（名前は小文字。実名は summary に出さない）。
#   ROUND            既定 1。1 は D〜P 群・S3 Tables 群（1 ラウンド目）、2 は
#                    U1〜U7 群（2 ラウンド目）だけを流す。
#   S3TABLES_CATALOG S3 Tables のカタログ名（例 s3tablescatalog/my-bucket）。
#   S3TABLES_NS      S3 Tables の名前空間。
#   S3TABLES_TABLE   S3 Tables のテーブル名。
#                    この 3 つが揃ったときだけ S3 Tables 群（ROUND=1 の S3T・
#                    ROUND=2 の U3）を測る。1 つでも欠けていれば
#                    「未測定（S3TABLES_* 未設定）」として summary に残す。
#
# ** このスクリプトが本物に対して行う破壊的な操作 **
#   PROBE_DDL=1 のとき: <db>.athena_local_probe_204（Hive。CREATE TABLE ... AS SELECT
#   で作成）を作り、最後に無引用 + IF EXISTS の DROP TABLE で消す（異常終了時も trap で
#   同じ形で消しにいく）。同名のテーブルが既にあると壊すので、開始前に SHOW TABLES で
#   athena_local_probe_204 という接頭辞が無いことを確かめ、1 件でもあれば何も作らずに
#   止まる。ALTER TABLE・DROP TABLE は実在しない名前
#   （<db>.athena_local_probe_204_nope）にだけ投げるので、そのテーブル自体は作らない
#   （後始末の対象にもならない）。
#   ROUND=2 の U7 群だけ、実在しない名前 <db>.athena_local_probe_204_nope3 に対する
#   CREATE TABLE（非 EXTERNAL の Hive。本物では失敗するはず）を引用符付き・無引用の
#   両方で投げる。想定外に成功したら、その場で無引用 IF EXISTS の DROP を投げて消す
#   （trap にも同じ DROP を保険として持つ）。
#
# 課金について: スキャンの無いクエリだけ。DESCRIBE・DESC・SHOW CREATE TABLE・
# SHOW COLUMNS・MSCK REPAIR TABLE・ALTER TABLE・DROP TABLE・SHOW TABLES・
# DROP DATABASE はどれもメタデータだけを見る／書く文で、実データのスキャンは無い。
# 準備の CTAS（PROBE_DDL=1 のときだけ）・U3 の SELECT（S3 Tables、LIMIT 1）・
# U7 の CREATE TABLE（0 行）も、スキャンや書き込みは軽微。Athena の最小課金 ×
# クエリ数の見込み。
#
# 本物への呼び出し回数の見込み（StartQueryExecution のみ。GetQueryExecution・
# GetQueryResults・S3 への呼び出しは含めない。課金には影響しない）:
#
#   [ROUND=1]
#   preflight 1
#   + PROBE_DDL=1 のときのセットアップ 1・後始末 1（既定はこちら）
#   + D 群（DESCRIBE、n0〜n11）12
#   + E 群（DESC、6 形）6
#   + C 群（SHOW CREATE TABLE、n0〜n11）12
#   + L 群（SHOW COLUMNS FROM、6 形 + SHOW COLUMNS IN）7
#   + X 群（DROP TABLE、6 形 + IF EXISTS 引用 1 + IF EXISTS 無引用の対照 1）8
#   + A 群（ALTER TABLE、5 種 × 引用/無引用）10
#   + M 群（MSCK REPAIR TABLE、引用/無引用）2
#   + P 群（文言の位置の規則）8
#   = 68。S3TABLES_* が 3 つとも揃っていればさらに 4 本増え、72 になる。
#
#   [ROUND=2]
#   preflight 1 + セットアップ 1・後始末 1
#   + U1 群（8 + DROP 2）10
#   + U2 群（4 形 × 2 操作 8 + IF EXISTS 対 2）10
#   + U3 群（S3TABLES_* が揃うときだけ）10
#   + U4 群（先頭・区切りの空白）10
#   + U5 群（非 ASCII の位置）3
#   + U6 群（DESCRIBE の変種）3
#   + U7 群（3 対 6。CREATE TABLE の対照が想定外に成功すれば後始末が最大 2 本増える）6
#   = 45（S3TABLES_* 無し）／55（S3TABLES_* あり）。
#
#   どちらのラウンドも、開始時に弾かれた（START_FAILED）項目があっても追加の呼び出しは
#   しない（AthenaErrorCode・Message は同じ標準エラーからそのまま抜くため）。
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く。前の回の結果と混ざらない。
#
# 項目ごとに次を保存する（取れたものだけ）。
#   <label>.sql            投げた SQL そのもの（**DB 名・テーブル名を含む。実名を含む**。
#                          U4/U5 群は実際のタブ・CR・改行・非 ASCII をそのまま含む）
#   <label>.start.err      StartQueryExecution の標準エラー（開始時に弾かれた証拠）。
#                          **一切加工せず AWS CLI の出力そのまま保存する**（実際の制御
#                          文字か `\t` のような 2 文字表記かを、ファイルの中身では
#                          失わない）。Message と AthenaErrorCode は summary 用にここから
#                          抜くときだけ、実際の制御文字を <TAB>/<CR>/<LF> という目に
#                          見える形に変える（start_err_message を参照）
#   <label>.execution.json GetQueryExecution の生の応答（開始できた項目だけ）
#   <label>.execution.err  GetQueryExecution の標準エラー
#   <label>.reason.txt     StateChangeReason と AthenaError（**実名を含みうる。貼る前に確認**）
#
# summary の決め手になる列は state・statement_type/substatement_type・
# start_message/start_athena_error_code（開始時に弾かれた項目）・
# error_category/error_type/error_message（開始できて FAILED になった項目）。
# DB 名・出力先・バケット名・対象テーブル名・S3 Tables の名前は出さず、プレースホルダに
# 畳む。summary.tsv / summary.txt はそのまま貼れる。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください}"
: "${DB:?DB にデータベース名を設定してください}"
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_DIR=${OUT_DIR:-${DEV_HOST_HOME:-$HOME}/athena-quoted-names-measurements}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}
PROBE_DDL=${PROBE_DDL:-1}
ROUND=${ROUND:-1}
S3TABLES_CATALOG=${S3TABLES_CATALOG:-}
S3TABLES_NS=${S3TABLES_NS:-}
S3TABLES_TABLE=${S3TABLES_TABLE:-}

PROBE_PREFIX=athena_local_probe_204
TABLE_HIVE=$PROBE_PREFIX
NOPE=${PROBE_PREFIX}_nope
NOPE2=${PROBE_PREFIX}_nope2

D_FORMS="n0 n1 n2 n3 n4 n5 n6 n7 n8 n9 n10 n11"
E_FORMS="n0 n1 n4 n5 n6 n10"
C_FORMS="$D_FORMS"
L_FORMS="n0 n1 n4 n5 n6 n10"
X_FORMS="n0 n1 n4 n5 n6 n10"

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\tstatement_type\tsubstatement_type\tstart_message\tstart_athena_error_code\terror_category\terror_type\terror_message\treason_line\tnote\n' > "$SUMMARY"
echo "出力先: $RUN_DIR"

# StartQueryExecution を実際に呼んだ回数（再試行も含む）。summary.txt の冒頭に出す。
START_CALL_FILE="$RUN_DIR/.start-calls"
: > "$START_CALL_FILE"
# PROBE_DDL=1 のセットアップに着手したかどうか。trap での後始末に使う。
DDL_ATTEMPTED=0
# ROUND=2 の U7 群で CREATE TABLE の対照（無引用・引用符付きのどちらか）が想定外に
# 成功したかどうか。trap での後始末に使う（本編の u7-*-cleanup で消せなかったときの保険）。
U7_CREATED=0

# 中間ファイル（.tmp-*）は、途中で止めても残らないよう trap で消す。セットアップに
# 着手していたら、ベストエフォートで「無引用 + IF EXISTS」の後始末も投げる
# （本編の z-drop-hive・u7-*-cleanup で消せなかったときの保険。cleanup 自体は結果を
# 確かめない）。
cleanup() {
  rm -f "$RUN_DIR"/.tmp-*
  if [ "$DDL_ATTEMPTED" = 1 ]; then
    aws athena start-query-execution --region "$REGION" \
      --query-string "DROP TABLE IF EXISTS $TABLE_HIVE" \
      --query-execution-context "Catalog=$CATALOG,Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
  fi
  if [ "$U7_CREATED" = 1 ]; then
    aws athena start-query-execution --region "$REGION" \
      --query-string "DROP TABLE IF EXISTS ${NOPE}3" \
      --query-execution-context "Catalog=$CATALOG,Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# 実名（DB 名・出力先・バケット名）を置換して隠す。
OUTPUT_BUCKET=${OUTPUT#s3://}
OUTPUT_BUCKET=${OUTPUT_BUCKET%%/*}
redact() {
  local s=$1
  s=${s//$DB/<DB>}
  s=${s//$OUTPUT/<OUTPUT>}
  s=${s//$OUTPUT_BUCKET/<BUCKET>}
  printf '%s' "$s"
}

# 標準入力から、対象テーブル名（TARGET_TABLE）・接頭辞 athena_local_probe_204・
# S3 Tables の実名（設定されていれば）を置換して隠す。summary.txt に流し込む
# 文言・エラー文言・SQL の伏せ字表示に使う。
mask_names() {
  local s
  s=$(cat)
  if [ -n "${TARGET_TABLE:-}" ]; then
    s=${s//$TARGET_TABLE/<TT>}
  fi
  s=${s//$PROBE_PREFIX/<PROBE>}
  if [ -n "$S3TABLES_CATALOG" ]; then
    s=${s//$S3TABLES_CATALOG/<S3TABLES_CATALOG>}
  fi
  if [ -n "$S3TABLES_NS" ]; then
    s=${s//$S3TABLES_NS/<S3TABLES_NS>}
  fi
  if [ -n "$S3TABLES_TABLE" ]; then
    s=${s//$S3TABLES_TABLE/<S3TABLES_TABLE>}
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

# start.err から Message と AthenaErrorCode を抜く。AWS CLI は開始時に弾かれた
# StartQueryExecution の標準エラーに、追加の呼び出しをしなくても両方とも出す
# （#200 の実例 `~/athena-keyword-boundary-measurements/run-20260925-055931/b1.start.err`）。
#   aws: [ERROR]: An error occurred (InvalidRequestException) when calling the
#   StartQueryExecution operation: line 1:9: no viable alternative at input 'DESCRIBE"<T>"'
#
#   Additional error details:
#   AthenaErrorCode: MALFORMED_QUERY
# Message は「operation: 」より後ろ、「\n\nAdditional error details:」の手前まで
# （無ければファイル末尾まで）を取る。AthenaErrorCode は「AthenaErrorCode: 」で
# 始まる行から取る。どちらも見つからなければ "-"。
#
# ラウンド 2 の U4/U5 群は SQL に実際のタブ・CR・改行・コメントを挟むので、
# Message の中にそれが実際の制御文字のまま echo back されることがある
# （#204 の依頼どおり「実際の制御文字か \t などの 2 文字表記か」を区別できるよう、
# start.err そのものは加工せず保存し、summary に載せるときだけ <TAB>/<CR>/<LF> という
# 目に見える形に変える。始めに <BACKSLASH> へ変えておくことで、message がもともと
# 持っていた 2 文字表記の `\t` などと、実際の制御文字を変換した <TAB> を混同しない）。
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

# 名前の形を返す（設計の n0〜n11 は #204 の依頼文どおり、n12〜n14 はラウンド 2 の
# U1・U2 群で使う「3 部のうち一部だけ引用符付き」の形）。
#   n0  無引用                          t
#   n1  引用符付き（小文字）            "t"
#   n2  引用符付き（大文字）            "T"
#   n3  db 修飾・無引用                 db.t
#   n4  db・テーブルとも引用符付き      "db"."t"
#   n5  db 無引用・テーブル引用符付き   db."t"
#   n6  db 引用符付き・テーブル無引用   "db".t
#   n7  catalog 修飾（3 部・無引用）    awsdatacatalog.db.t
#   n8  catalog だけ引用符付き（大小混在） "AwsDataCatalog".db.t
#   n9  3 部とも引用符付き              "awsdatacatalog"."db"."t"
#   n10 バッククォート（テーブルのみ）  `t`
#   n11 バッククォート（db・テーブル）  `db`.`t`
#   n12 catalog 無引用・db 引用符付き・table 無引用   awsdatacatalog."db".t
#   n13 catalog 無引用・db 無引用・table 引用符付き   awsdatacatalog.db."t"
#   n14 catalog だけ引用符付き（小文字）・残り無引用  "awsdatacatalog".db.t
name_form() {
  local idx=$1 base=$2 upper
  upper=$(printf '%s' "$base" | tr '[:lower:]' '[:upper:]')
  case "$idx" in
    n0) printf '%s' "$base" ;;
    n1) printf '"%s"' "$base" ;;
    n2) printf '"%s"' "$upper" ;;
    n3) printf '%s.%s' "$DB" "$base" ;;
    n4) printf '"%s"."%s"' "$DB" "$base" ;;
    n5) printf '%s."%s"' "$DB" "$base" ;;
    n6) printf '"%s".%s' "$DB" "$base" ;;
    n7) printf 'awsdatacatalog.%s.%s' "$DB" "$base" ;;
    n8) printf '"AwsDataCatalog".%s.%s' "$DB" "$base" ;;
    n9) printf '"awsdatacatalog"."%s"."%s"' "$DB" "$base" ;;
    n10) printf '`%s`' "$base" ;;
    n11) printf '`%s`.`%s`' "$DB" "$base" ;;
    n12) printf 'awsdatacatalog."%s".%s' "$DB" "$base" ;;
    n13) printf 'awsdatacatalog.%s."%s"' "$DB" "$base" ;;
    n14) printf '"awsdatacatalog".%s.%s' "$DB" "$base" ;;
    *) printf '%s' "$base" ;;
  esac
}

# ラベルを指定して 1 文を実行する。開始できなければ、AthenaErrorCode・Message を
# その場の start.err からそのまま抜く（追加の呼び出しはしない。上の start_err_message /
# start_err_code を参照）。開始できたら終端状態まで待って StatementType・
# SubstatementType・FAILED の理由を採る。
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

# --- preflight ---------------------------------------------------------------

if ! run probe-show-tables "SHOW TABLES"; then
  echo
  echo "SHOW TABLES が通りませんでした。DB か CATALOG の指定が実在しません。"
  echo "理由: $RUN_DIR/probe-show-tables.reason.txt"
  if run available-databases "SHOW DATABASES"; then
    echo "選べるデータベースの一覧は $RUN_DIR/available-databases.execution.json の"
    echo "GetQueryExecution 応答からは分からない（結果は GetQueryResults 側）。"
    echo "aws athena get-query-results --query-execution-id <id> で確認してください。"
  fi
  exit 1
fi

# SHOW TABLES の結果を GetQueryResults でページングしながら全件取る（S3 は使わない）。
SHOW_TABLES_ID=$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1]))["QueryExecution"]["QueryExecutionId"])
except Exception:
    print("")' "$RUN_DIR/probe-show-tables.execution.json" 2>/dev/null)

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

# --- 対象テーブル（<t>）を決める -----------------------------------------------
# PROBE_DDL=1 のときは下で作る Hive テーブル。0 のときは SHOW TABLES の 1 件目
# （実在のテーブル）。名前は小文字で使う。
TARGET_TABLE=""
if [ "$PROBE_DDL" = 1 ]; then
  TARGET_TABLE=$TABLE_HIVE
else
  TARGET_TABLE=$(head -n1 "$RUN_DIR/tables.txt" 2>/dev/null | tr -d '\r' | tr '[:upper:]' '[:lower:]')
fi

# --- セットアップ（PROBE_DDL=1 のときだけ） ------------------------------------

D_SETUP_OK=0
if [ "$PROBE_DDL" = 1 ]; then
  DDL_ATTEMPTED=1
  if run d0-setup-hive "CREATE TABLE $DB.$TABLE_HIVE AS SELECT 1 AS n, 'x' AS s, 10 AS x"; then
    D_SETUP_OK=1
  else
    echo "== d0-setup-hive: 準備テーブルが作れませんでした。対象テーブルが要る群は未測定にします。"
    TARGET_TABLE=""
  fi
else
  D_SETUP_OK=1
fi

if [ -z "$TARGET_TABLE" ]; then
  echo "== 対象テーブルが決められないため、D/E/C/L/M 群と P 群の一部を未測定にします。"
fi

if [ "$ROUND" = 1 ]; then

# --- D 群（DESCRIBE <t>） -------------------------------------------------------

if [ -n "$TARGET_TABLE" ]; then
  for n in $D_FORMS; do
    run "d-$n" "DESCRIBE $(name_form "$n" "$TARGET_TABLE")"
  done
else
  for n in $D_FORMS; do skip "d-$n" "対象テーブルが無いため未測定"; done
fi

# --- E 群（DESC <t>） ------------------------------------------------------------

if [ -n "$TARGET_TABLE" ]; then
  for n in $E_FORMS; do
    run "e-$n" "DESC $(name_form "$n" "$TARGET_TABLE")"
  done
else
  for n in $E_FORMS; do skip "e-$n" "対象テーブルが無いため未測定"; done
fi

# --- C 群（SHOW CREATE TABLE <t>） ----------------------------------------------

if [ -n "$TARGET_TABLE" ]; then
  for n in $C_FORMS; do
    run "c-$n" "SHOW CREATE TABLE $(name_form "$n" "$TARGET_TABLE")"
  done
else
  for n in $C_FORMS; do skip "c-$n" "対象テーブルが無いため未測定"; done
fi

# --- L 群（SHOW COLUMNS FROM/IN <t>） --------------------------------------------

if [ -n "$TARGET_TABLE" ]; then
  for n in $L_FORMS; do
    run "l-$n" "SHOW COLUMNS FROM $(name_form "$n" "$TARGET_TABLE")"
  done
  run "l-in" "SHOW COLUMNS IN \"$TARGET_TABLE\""
else
  for n in $L_FORMS; do skip "l-$n" "対象テーブルが無いため未測定"; done
  skip "l-in" "対象テーブルが無いため未測定"
fi

# --- X 群（DROP TABLE <nope の形>） ----------------------------------------------

for n in $X_FORMS; do
  run "x-$n" "DROP TABLE $(name_form "$n" "$NOPE")"
done
run "x-ifq" "DROP TABLE IF EXISTS \"$NOPE\""
run "x-ifu" "DROP TABLE IF EXISTS $NOPE"

# --- A 群（ALTER TABLE <nope の形> ...） -----------------------------------------
# すべて実在しない名前 athena_local_probe_204_nope に対して投げる。
# 引用符付き（n1 "nope"）と対照の無引用（n0 nope）の対で 5 種。

run_alt_pair() {
  local key=$1 stmt=$2
  run "alt-$key-q" "ALTER TABLE \"$NOPE\" $stmt"
  run "alt-$key-u" "ALTER TABLE $NOPE $stmt"
}

run_alt_pair addcols "ADD COLUMNS (m int)"
run_alt_pair addcol "ADD COLUMN m int"
run_alt_pair dropcol "DROP COLUMN m"
run_alt_pair rename "RENAME TO $NOPE2"
run_alt_pair settbl "SET TBLPROPERTIES ('k'='v')"

# --- M 群（MSCK REPAIR TABLE <t>） -----------------------------------------------

if [ -n "$TARGET_TABLE" ]; then
  run "msck-q" "MSCK REPAIR TABLE \"$TARGET_TABLE\""
  run "msck-u" "MSCK REPAIR TABLE $TARGET_TABLE"
else
  skip "msck-q" "対象テーブルが無いため未測定"
  skip "msck-u" "対象テーブルが無いため未測定"
fi

# --- P 群（文言の位置の規則） -----------------------------------------------------

if [ -n "$TARGET_TABLE" ]; then
  run "pos-lower" "describe \"$TARGET_TABLE\""
  run "pos-dblspace" "DESCRIBE  \"$TARGET_TABLE\""
  # 改行を挟む形。$'...' は変数展開しないので、改行だけを断片にして隣接させて連結する
  # （tools/measure/leading-comment.sh の注意のとおり）。
  run "pos-newline" $'DESCRIBE\n'"\"$TARGET_TABLE\""
  run "pos-leadspace" "  DESCRIBE \"$TARGET_TABLE\""
  run "pos-leadcomment" "/* c */ DESCRIBE \"$TARGET_TABLE\""
  run "pos-trailspace" "SHOW CREATE TABLE \"$TARGET_TABLE\" "
else
  for label in pos-lower pos-dblspace pos-newline pos-leadspace pos-leadcomment pos-trailspace; do
    skip "$label" "対象テーブルが無いため未測定"
  done
fi
run "pos-drop-dblspace" "DROP TABLE  \"$NOPE\""
run "pos-drop-lower" "drop table \"$NOPE\""

# --- S3 Tables（任意。環境変数が 3 つとも揃ったときだけ） -------------------------

if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ] && [ -n "$S3TABLES_TABLE" ]; then
  run "s3t-desc" "DESCRIBE \"$S3TABLES_CATALOG\".$S3TABLES_NS.$S3TABLES_TABLE"
  run "s3t-show" "SHOW CREATE TABLE \"$S3TABLES_CATALOG\".$S3TABLES_NS.$S3TABLES_TABLE"
  run "s3t-select" "SELECT * FROM \"$S3TABLES_CATALOG\".$S3TABLES_NS.$S3TABLES_TABLE LIMIT 1"
  run "s3t-drop" "DROP TABLE IF EXISTS \"$S3TABLES_CATALOG\".$S3TABLES_NS.nope_204"
else
  for label in s3t-desc s3t-show s3t-select s3t-drop; do
    skip "$label" "未測定（S3TABLES_* 未設定）"
  done
fi

fi # ROUND=1

if [ "$ROUND" = 2 ]; then

# --- U1 群（3 部の名前で途中・末尾だけ引用符付き） --------------------------------
# n12 = awsdatacatalog."<db>".<t>（catalog 無引用・db 引用符付き・table 無引用）
# n13 = awsdatacatalog.<db>."<t>"（catalog 無引用・db 無引用・table 引用符付き）

if [ -n "$TARGET_TABLE" ]; then
  run "u1-desc-n12"    "DESCRIBE $(name_form n12 "$TARGET_TABLE")"
  run "u1-desc-n13"    "DESCRIBE $(name_form n13 "$TARGET_TABLE")"
  run "u1-descd-n12"   "DESC $(name_form n12 "$TARGET_TABLE")"
  run "u1-descd-n13"   "DESC $(name_form n13 "$TARGET_TABLE")"
  run "u1-showc-n12"   "SHOW CREATE TABLE $(name_form n12 "$TARGET_TABLE")"
  run "u1-showc-n13"   "SHOW CREATE TABLE $(name_form n13 "$TARGET_TABLE")"
  run "u1-showcol-n12" "SHOW COLUMNS FROM $(name_form n12 "$TARGET_TABLE")"
  run "u1-showcol-n13" "SHOW COLUMNS FROM $(name_form n13 "$TARGET_TABLE")"
else
  for label in u1-desc-n12 u1-desc-n13 u1-descd-n12 u1-descd-n13 \
    u1-showc-n12 u1-showc-n13 u1-showcol-n12 u1-showcol-n13; do
    skip "$label" "対象テーブルが無いため未測定"
  done
fi
run "u1-drop-n12" "DROP TABLE $(name_form n12 "$NOPE")"
run "u1-drop-n13" "DROP TABLE $(name_form n13 "$NOPE")"

# --- U2 群（ALTER。Trino が受ける RENAME TO / DROP COLUMN で、実在しない名前に） ----
# n14 = "awsdatacatalog".<db>.<nope>（catalog だけ引用符付き・小文字）
# n13（U1 と同じ関数）= awsdatacatalog.<db>."<nope>"

U2_FORMS="n5 n6 n14 n13"
for n in $U2_FORMS; do
  run "u2-$n-rename"  "ALTER TABLE $(name_form "$n" "$NOPE") RENAME TO $NOPE2"
  run "u2-$n-dropcol" "ALTER TABLE $(name_form "$n" "$NOPE") DROP COLUMN m"
done
run "u2-ifq" "ALTER TABLE IF EXISTS \"$NOPE\" RENAME TO $NOPE2"
run "u2-ifu" "ALTER TABLE IF EXISTS $NOPE RENAME TO $NOPE2"

# --- U3 群（S3 Tables。任意。環境変数が 3 つとも揃ったときだけ） -------------------
# <s3>     = "<S3TABLES_CATALOG>".<ns>.<table>（実在する表。ラウンド 1 は名前空間の
#            綴り違いで SCHEMA_NOT_FOUND だったので、今回は正しい値で対照を取り直す）
# <s3nope> = "<S3TABLES_CATALOG>".<ns>.nope_204（実在しない表）

if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ] && [ -n "$S3TABLES_TABLE" ]; then
  S3_NAME="\"$S3TABLES_CATALOG\".$S3TABLES_NS.$S3TABLES_TABLE"
  S3_NOPE_NAME="\"$S3TABLES_CATALOG\".$S3TABLES_NS.nope_204"
  run "u3-select"          "SELECT * FROM $S3_NAME LIMIT 1"
  run "u3-desc"            "DESCRIBE $S3_NAME"
  run "u3-descd"           "DESC $S3_NAME"
  run "u3-showcol"         "SHOW COLUMNS FROM $S3_NAME"
  run "u3-showc"           "SHOW CREATE TABLE $S3_NAME"
  run "u3-desc-nope"       "DESCRIBE $S3_NOPE_NAME"
  run "u3-drop-nope"       "DROP TABLE $S3_NOPE_NAME"
  run "u3-alt-rename-nope" "ALTER TABLE $S3_NOPE_NAME RENAME TO nope_204b"
  run "u3-alt-dropcol-nope" "ALTER TABLE $S3_NOPE_NAME DROP COLUMN m"
  run "u3-desc-allq" "DESCRIBE \"$S3TABLES_CATALOG\".\"$S3TABLES_NS\".\"$S3TABLES_TABLE\""
else
  for label in u3-select u3-desc u3-descd u3-showcol u3-showc u3-desc-nope \
    u3-drop-nope u3-alt-rename-nope u3-alt-dropcol-nope u3-desc-allq; do
    skip "$label" "未測定（S3TABLES_* 未設定）"
  done
fi

# --- U4 群（先頭と区切りの空白。ANSI-C quoting $'...' で作る） --------------------

if [ -n "$TARGET_TABLE" ]; then
  run "u4-leadtab"     $'\t'"DESCRIBE \"$TARGET_TABLE\""
  run "u4-leadnl"      $'\n'"DESCRIBE \"$TARGET_TABLE\""
  run "u4-leadcrlf"    $'\r\n'"DESCRIBE \"$TARGET_TABLE\""
  run "u4-lead2nl"     $'\n\n'"DESCRIBE \"$TARGET_TABLE\""
  run "u4-linecomment" $'-- c\n'"DESCRIBE \"$TARGET_TABLE\""
  run "u4-blockcomment" $'/* a\nb */ '"DESCRIBE \"$TARGET_TABLE\""
  run "u4-septab"      "DESCRIBE"$'\t'"\"$TARGET_TABLE\""
  run "u4-sepcrlf"     "DESCRIBE"$'\r\n'"\"$TARGET_TABLE\""
else
  for label in u4-leadtab u4-leadnl u4-leadcrlf u4-lead2nl u4-linecomment \
    u4-blockcomment u4-septab u4-sepcrlf; do
    skip "$label" "対象テーブルが無いため未測定"
  done
fi
run "u4-drop-leadnl" $'\n'"DROP TABLE \"$NOPE\""
run "u4-drop-sepnl"  "DROP TABLE"$'\n'"\"$NOPE\""

# --- U5 群（非 ASCII の後ろの位置） ------------------------------------------------

if [ -n "$TARGET_TABLE" ]; then
  run "u5-hira"  $'/* \xe3\x81\x82 */ '"DESCRIBE \"$TARGET_TABLE\""
  run "u5-emoji" $'/* \xf0\x9f\x98\x80 */ '"DESCRIBE \"$TARGET_TABLE\""
else
  skip "u5-hira" "対象テーブルが無いため未測定"
  skip "u5-emoji" "対象テーブルが無いため未測定"
fi
run "u5-jp" $'DESCRIBE "\xe6\x97\xa5\xe6\x9c\xac"'

# --- U6 群（DESCRIBE の変種） -----------------------------------------------------

if [ -n "$TARGET_TABLE" ]; then
  run "u6-extended-q"   "DESCRIBE EXTENDED \"$TARGET_TABLE\""
  run "u6-formatted-q"  "DESCRIBE FORMATTED \"$TARGET_TABLE\""
  run "u6-extended-u"   "DESCRIBE EXTENDED $TARGET_TABLE"
else
  for label in u6-extended-q u6-formatted-q u6-extended-u; do
    skip "$label" "対象テーブルが無いため未測定"
  done
fi

# --- U7 群（ほかの文。すべて実在しない名前に対して） -------------------------------

run "u7-showtables-q" "SHOW TABLES IN \"$DB\""
run "u7-showtables-u" "SHOW TABLES IN $DB"
run "u7-dropdb-q" "DROP DATABASE IF EXISTS \"${NOPE}_db\""
run "u7-dropdb-u" "DROP DATABASE IF EXISTS ${NOPE}_db"

if run "u7-createtable-q" "CREATE TABLE \"${NOPE}3\" (n int)"; then
  U7_CREATED=1
  run "u7-createtable-q-cleanup" "DROP TABLE IF EXISTS ${NOPE}3"
  if [ -s "$RUN_DIR/u7-createtable-q-cleanup.reason.txt" ] && grep -q "^State: SUCCEEDED" "$RUN_DIR/u7-createtable-q-cleanup.reason.txt"; then
    U7_CREATED=0
  fi
else
  skip "u7-createtable-q-cleanup" "CREATE TABLE が失敗したため後始末不要"
fi

if run "u7-createtable-u" "CREATE TABLE ${NOPE}3 (n int)"; then
  U7_CREATED=1
  run "u7-createtable-u-cleanup" "DROP TABLE IF EXISTS ${NOPE}3"
  if [ -s "$RUN_DIR/u7-createtable-u-cleanup.reason.txt" ] && grep -q "^State: SUCCEEDED" "$RUN_DIR/u7-createtable-u-cleanup.reason.txt"; then
    U7_CREATED=0
  fi
else
  skip "u7-createtable-u-cleanup" "CREATE TABLE が失敗したため後始末不要"
fi

fi # ROUND=2

# --- 後始末（PROBE_DDL=1 のときだけ） ---------------------------------------------

if [ "$PROBE_DDL" = 1 ] && [ "$D_SETUP_OK" = 1 ]; then
  run z-drop-hive "DROP TABLE IF EXISTS $TABLE_HIVE"
  if [ -s "$RUN_DIR/z-drop-hive.reason.txt" ] && grep -q "^State: SUCCEEDED" "$RUN_DIR/z-drop-hive.reason.txt"; then
    DDL_ATTEMPTED=0
  else
    echo "== 後始末の DROP TABLE が SUCCEEDED になりませんでした。終了時にもう一度投げます。"
    echo "   それでも消えなければ、$DB の $TABLE_HIVE を手で消してください。"
  fi
fi

# --- summary -----------------------------------------------------------------

ALL_LABELS="probe-show-tables d0-setup-hive"
if [ "$ROUND" = 1 ]; then
  for n in $D_FORMS; do ALL_LABELS="$ALL_LABELS d-$n"; done
  for n in $E_FORMS; do ALL_LABELS="$ALL_LABELS e-$n"; done
  for n in $C_FORMS; do ALL_LABELS="$ALL_LABELS c-$n"; done
  for n in $L_FORMS; do ALL_LABELS="$ALL_LABELS l-$n"; done
  ALL_LABELS="$ALL_LABELS l-in"
  for n in $X_FORMS; do ALL_LABELS="$ALL_LABELS x-$n"; done
  ALL_LABELS="$ALL_LABELS x-ifq x-ifu"
  for key in addcols addcol dropcol rename settbl; do
    ALL_LABELS="$ALL_LABELS alt-$key-q alt-$key-u"
  done
  ALL_LABELS="$ALL_LABELS msck-q msck-u"
  ALL_LABELS="$ALL_LABELS pos-lower pos-dblspace pos-newline pos-leadspace pos-leadcomment pos-trailspace pos-drop-dblspace pos-drop-lower"
  ALL_LABELS="$ALL_LABELS s3t-desc s3t-show s3t-select s3t-drop"
elif [ "$ROUND" = 2 ]; then
  ALL_LABELS="$ALL_LABELS u1-desc-n12 u1-desc-n13 u1-descd-n12 u1-descd-n13"
  ALL_LABELS="$ALL_LABELS u1-showc-n12 u1-showc-n13 u1-showcol-n12 u1-showcol-n13"
  ALL_LABELS="$ALL_LABELS u1-drop-n12 u1-drop-n13"
  for n in $U2_FORMS; do ALL_LABELS="$ALL_LABELS u2-$n-rename u2-$n-dropcol"; done
  ALL_LABELS="$ALL_LABELS u2-ifq u2-ifu"
  ALL_LABELS="$ALL_LABELS u3-select u3-desc u3-descd u3-showcol u3-showc u3-desc-nope"
  ALL_LABELS="$ALL_LABELS u3-drop-nope u3-alt-rename-nope u3-alt-dropcol-nope u3-desc-allq"
  ALL_LABELS="$ALL_LABELS u4-leadtab u4-leadnl u4-leadcrlf u4-lead2nl u4-linecomment u4-blockcomment"
  ALL_LABELS="$ALL_LABELS u4-septab u4-sepcrlf u4-drop-leadnl u4-drop-sepnl"
  ALL_LABELS="$ALL_LABELS u5-hira u5-emoji u5-jp"
  ALL_LABELS="$ALL_LABELS u6-extended-q u6-formatted-q u6-extended-u"
  ALL_LABELS="$ALL_LABELS u7-showtables-q u7-showtables-u u7-dropdb-q u7-dropdb-u"
  ALL_LABELS="$ALL_LABELS u7-createtable-q u7-createtable-q-cleanup u7-createtable-u u7-createtable-u-cleanup"
fi
ALL_LABELS="$ALL_LABELS z-drop-hive"

write_summary_txt() {
  local txt="$RUN_DIR/summary.txt"
  {
    echo "# issue #204: 引用符付きの名前を取る文が StartQueryExecution の時点でどの形なら"
    echo "#             弾かれ、どの形なら通るか（境界の規則）と、弾かれた文言の規則を実測"
    echo "# 実行日時: $(date -Iseconds)"
    echo "# ROUND: $ROUND（1 = D〜P 群・S3 Tables 群、2 = U1〜U7 群）"
    if [ "$ROUND" = 1 ]; then
      echo "# StartQueryExecution の見込み本数: 68（preflight 1 + セットアップ/後始末 2 +"
      echo "#   D 12 + E 6 + C 12 + L 7 + X 8 + A 10 + M 2 + P 8）。"
      echo "#   S3TABLES_* が揃っていれば +4 で 72。"
    else
      echo "# StartQueryExecution の見込み本数: 45（S3TABLES_* 無し）／55（あり）"
      echo "#   （preflight 1 + セットアップ/後始末 2 + U1 10 + U2 10 + U4 10 + U5 3 +"
      echo "#   U6 3 + U7 6、S3TABLES_* が揃っていれば U3 の 10 が乗る）。U7 の"
      echo "#   CREATE TABLE の対照が想定外に成功すれば後始末が最大 2 本増える。"
    fi
    echo "#   開始時に弾かれた（START_FAILED）項目があっても追加の呼び出しはしない"
    echo "#   （このラウンドの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回）。"
    echo "# DDL は準備の Hive テーブル athena_local_probe_204 を 1 つ作って消すだけ"
    echo "#   (PROBE_DDL=1)。DROP・ALTER は実在しない名前 (..._nope) にだけ投げる。"
    echo "# 課金: スキャンの無いクエリだけ（メタデータの参照・書き換えのみ）。"
    echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
    echo
    echo "## 投げた文（DB 名・テーブル名は伏せる。実名は各 <label>.sql を参照）"
    for label in $ALL_LABELS; do
      [ -s "$RUN_DIR/$label.sql" ] && echo "- $label: $(sanitize "$(hide "$(cat "$RUN_DIR/$label.sql")")")"
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
    echo "## 失敗した項目の理由（実名を含みうるので貼る前に確認すること）"
    for label in $ALL_LABELS; do
      if [ -s "$RUN_DIR/$label.reason.txt" ] && ! grep -q "^State: SUCCEEDED" "$RUN_DIR/$label.reason.txt"; then
        echo "### $label"
        cat "$RUN_DIR/$label.reason.txt"
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
echo "<label>.sql・<label>.reason.txt・<label>.start.err は実名（DB 名・テーブル名）を"
echo "含みうるので、summary.txt 以外を貼るときは中身を確かめてください。"
