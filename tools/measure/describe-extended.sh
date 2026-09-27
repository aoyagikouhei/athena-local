#!/usr/bin/env bash
# issue #275 で作成。
# 本物の Athena で DESCRIBE EXTENDED・DESCRIBE FORMATTED（と対照の DESCRIBE・DESC）を
# 実際に実行し、結果の形（GetQueryExecution の Query・Context・StatementType・
# SubstatementType、結果ファイル本体・Content-Type・.metadata の有無、GetQueryResults の
# ColumnInfo・Rows・UpdateCount）を丸ごと実測する。
#
# 出どころ（.claude/issue-notes/275.md、issue #275 本文）:
#   #257 の調査と実機の足場（tools/e2e/block-comment/verify.sh の DE1I・DE1V）で見つかった。
#   本物は DESCRIBE EXTENDED <db>.<t> を実行し、GetQueryExecution の Query は
#   DESCRIBE EXTENDED <t>（DB が落ちる。#257 の m7 で実測済み）。athena-local は Trino に
#   構文が無いので構文チェックで開始時に 400 にしている。Trino に何を投げて読み替えるかを
#   決めるには、本物の結果の形（行・列・Content-Type・.metadata・UpdateCount・
#   StatementType/SubstatementType・Query・Context）を丸ごと知る必要がある。
#
# 使い方:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db bash tools/measure/describe-extended.sh
#   （資格情報はホストのシェルで AWS_ACCESS_KEY_ID などを export してから。または ~/.aws/credentials）
#   DB を省略するか実在しなければ、SHOW DATABASES の候補の 1 件目を自動で使う。
#
# 必要な環境変数:
#   OUTPUT    結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける）。
#
# 任意の環境変数:
#   DB           データベース名。省略するか実在しなければ、SHOW DATABASES の候補の 1 件目を使う
#                （$RUN_DIR/available-databases.bytes に一覧を残す。実名を含む）。
#   CATALOG      既定 AwsDataCatalog
#   REGION       既定 ap-northeast-1
#   OUT_DIR      既定 ${DEV_HOST_HOME:-$HOME}/athena-describe-extended-measurements
#                （実名が入るのでリポジトリの外に出す。toolbox では DEV_HOST_HOME がホストの
#                ホームを指す。#129）
#   POLL_TIMEOUT 終端状態を待つ上限（秒）。既定 180
#   RETRY_MAX    名前解決・接続など一時的な失敗を再試行する回数の上限。既定 4
#   RETRY_DELAY  再試行の間隔（秒）。既定 5
#
# ** このスクリプトが本物に対して行う DDL（破壊的な操作） **
#   最初に SHOW TABLES で athena_local_probe_275_* という名前が db に既に無いことを確かめ、
#   1 件でもあれば何も作らずに止まる。確かめた後、次の 4 つを CREATE で作る:
#     - athena_local_probe_275_h  （Hive の EXTERNAL TABLE。列 n int、s string（列コメント付き））
#     - athena_local_probe_275_hp （Hive。CTAS で PARTITIONED BY 相当の partitioned_by を持ち、
#                                   最小の 1 行（p='x'）を最初から持つ）
#     - athena_local_probe_275_i  （Iceberg。CTAS で partitioning を持ち、最小の 1 行（p='x'））
#     - athena_local_probe_275_v  （ビュー。SELECT 1 AS n, 'x' AS s）
#   athena_local_probe_275_x（無い表）は作らない。作った直後に SHOW CREATE TABLE で
#   形式を裏取りする（DROP 後は呼べないため）。
#   投げる文はすべて DESCRIBE 系（EXTENDED・FORMATTED・無印・DESC）で、読み取りのみ。
#   ALTER・RENAME・DROP COLUMN の類は一切投げない（対象の表を変えない）。
#   最後に 4 つとも DROP する（正常終了なら本編の中で。異常終了時は trap がベストエフォートで
#   もう一度 DROP TABLE IF EXISTS / DROP VIEW IF EXISTS を投げる）。
#   location は $OUTPUT の下の実行ごとの場所（tables-probe-275-*-<日時>/）。_i（Iceberg）は DROP で
#   データも消えるが、_hp（Hive の CTAS。external_location）は DROP してもデータ（1 行）が残る。
#   athena_local_probe_275_h は EXTERNAL なので DROP TABLE では S3 の場所自体は残るが、
#   行を入れていないので中身は無い。
#   スキャンする SELECT は一切投げない（CTAS の SELECT はリテラルだけで、既存データを読まない）。
#
# 課金について: CTAS 2 回・CREATE 1 回・CREATE VIEW 1 回・DROP 4 回（メタデータのみ）と、
# 読み取りのみの DESCRIBE 系を最大 48 回。Athena の最小課金 × クエリ数の見込み。
# StartQueryExecution を呼んだ回数は summary.txt の冒頭に実測値で出す（list-work-groups・
# sts get-caller-identity など Athena のクエリではない API 呼び出しは含めない。trap で発動する
# 後始末のベストエフォート呼び出しも、正常終了で本編の DROP が全部済んでいれば呼ばれないため
# 含めない）。
#
# 項目（<H>/<HP>/<I>/<V> はフィクスチャの修飾名 <DB>.athena_local_probe_275_h など、
# <X> は作らない無い表、<NODB> は作らない無いデータベース。改行を含む文は本物の改行文字を送る）:
#
#   1. EXTENDED・FORMATTED・対照の DESCRIBE を H・HP・I・V・X に <db>.<t> で投げる:
#     e_h  DESCRIBE EXTENDED <H>            e_hp DESCRIBE EXTENDED <HP>
#     e_i  DESCRIBE EXTENDED <I>            e_v  DESCRIBE EXTENDED <V>
#     e_x  DESCRIBE EXTENDED <X>            （無い表）
#     f_h  DESCRIBE FORMATTED <H>           f_hp DESCRIBE FORMATTED <HP>
#     f_i  DESCRIBE FORMATTED <I>           f_v  DESCRIBE FORMATTED <V>
#     f_x  DESCRIBE FORMATTED <X>           （無い表）
#     d_h  DESCRIBE <H>                     d_hp DESCRIBE <HP>            対照
#     d_i  DESCRIBE <I>                     d_v  DESCRIBE <V>             対照
#
#   2. Query の書き方の変異（H が対象。EXTENDED は qe1〜qe10、FORMATTED は qf1〜qf10 で同じ 10 形）:
#     1  無修飾の <t>（Context の Database で解決）
#     2  awsdatacatalog.<db>.<t>
#     3  AwsDataCatalog.<db>.<t>
#     4  小文字のキーワード（describe extended／describe formatted）
#     5  DESC EXTENDED／DESC FORMATTED
#     6  キーワードの間に空白 2 つ
#     7  キーワードの間に改行
#     8  末尾に ;
#     9  Context に Database 無しで <db>.<t>（Catalog だけの Context）
#     10 バッククォートで囲んだ表名
#
#   3. 列指定とパーティション指定:
#     p1 DESCRIBE EXTENDED <H> n            p2 DESCRIBE FORMATTED <H> n
#     p3 DESCRIBE EXTENDED <HP> PARTITION (p='x')   p4 DESCRIBE FORMATTED <HP> PARTITION (p='x')
#     p5 DESCRIBE <I> n                     p6 DESCRIBE EXTENDED <I> n
#     p7 DESCRIBE FORMATTED <I> n           p8 DESCRIBE <I> PARTITION (p='x')
#     p9 DESC <I>
#     （p5・p9 は docs/dev/unmeasured.md の「Iceberg の DESCRIBE t col」「DESC t の Iceberg」と
#     同じ族なので同じラウンドで測る）
#
#   4. 失敗系:
#     z1 DESCRIBE EXTENDED（名前無し）        z2 DESCRIBE FORMATTED（名前無し）
#     z3 DESCRIBE EXTENDED <NODB>.<H>（無い DB）
#     z4 DESCRIBE EXTENDED <H> nocol_275（無い列）
#     z5 DESCRIBE EXTENDED <HP> PARTITION (p='nope_275')（無いパーティション値）
#
# ** SQL に改行を含める書き方の注意 **
# 「DESCRIBE\nEXTENDED ...」のような文は、シェルで実際の改行文字（0x0a）にしてから渡さないと、
# 「\」「n」という 2 文字が入った 1 行の文字列になり、まったく別の測定になる。そのため bash の
# ANSI-C quoting（$'...'）を使う。$'...' は変数展開をしないので、$DB を埋め込む行は
# $'DESCRIBE\n'"EXTENDED $DB.$H" のように断片を隣り合わせて連結する
# （tools/measure/block-comment-parse-error.sh と同じ注意）。
#
# S3 からの取得は `aws s3 cp <src> -` で標準出力に流し、リダイレクトはこのシェルが行う。
# aws が Docker のラッパだと、コンテナにマウントされるのは実行時のカレントディレクトリだけで、
# 絶対パスを渡すとコンテナの中に書かれて消える。しかも終了コードは 0 になる。`--debug` は
# 使わない（生ログに署名やアクセスキーが残るため）。
#
# 実行系（aws・python3）は command -v（PATH にあるか）だけでなく、実際に使うオプションで
# 呼べるかを preflight で試す（list-work-groups・DESCRIBE 1 本を実際に投げて確かめる。
# tools/measure/content-type-rules.sh・tools/measure/block-comment-parse-error.sh と同じ考え方）。
# 名前解決・接続の一時的な失敗は RETRY_MAX 回まで再試行し（StartQueryExecution・
# GetQueryResults・S3 の取得のすべてで共通の retry_aws を通す）、試行回数を summary の note に残す。
#
# 項目は独立して失敗しうる。前提のフィクスチャ（H/HP/I/V）が作れなかった項目だけを skip にして
# 未測定にし、全体は止めない（run_req）。DB が実在しない・指定が無いときも、SHOW DATABASES の
# 候補の 1 件目を自動で使って続ける（止まるのは、その候補でも SHOW TABLES が通らない、または
# SHOW DATABASES 自体が通らないとき）。
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く（リポジトリの外）。
#
# 項目ごとに次を保存する（取れたものだけ）。
#   <label>.sql                投げた SQL そのもの（**DB 名を含む**）
#   <label>.start.err          StartQueryExecution の標準エラー（開始時に弾かれた証拠）
#   <label>.execution.json     GetQueryExecution の応答そのもの
#   <label>.execution.err      GetQueryExecution の標準エラー
#   <label>.reason.txt         State / StateChangeReason / AthenaError の全文（**実名を含みうる**）
#   <label>.query.txt          GetQueryExecution の Query（**DB 名を含みうる。DB が落ちるか見る本命**）
#   <label>.context.txt        GetQueryExecution の QueryExecutionContext（**実名を含みうる**）
#   <label>.ls.txt             OutputLocation と .metadata の aws s3 ls の結果
#   <label>.bytes / .od.txt    結果ファイル本体の中身と、バイト単位で見たもの（無ければ作らない）
#   <label>.cp.err             本体を取れなかったときの stderr（= 本体が無いことの証拠）
#   <label>.metadata.bytes / .metadata.od.txt  .metadata の中身と 16 進（無ければ作らない）
#   <label>.metadata.cp.err    .metadata を取れなかったときの stderr（= 無いことの証拠）
#   <label>.head.json / .metadata.head.json    head-object の応答（Content-Type の出どころ）
#   <label>.results-<n>.json   GetQueryResults の各ページの応答そのまま（1 始まり）
#   <label>.results.columns.txt  1 ページ目の ResultSetMetadata.ColumnInfo（1 行 1 列、Name:Type）
#   <label>.results.rows.txt     全ページの Rows（1 行 1 Row。列は タブ区切りで連結。**実名を含みうる**）
#   <label>.results.update_count.txt  UpdateCount（無ければ "-"）
#   available-databases.bytes  DB が実在しなかった／指定が無かったときの候補の一覧（**実名**）
#   caller-identity.json       aws sts get-caller-identity の応答（**実名。Owner 欄のマスクに使う**）
#
# 最後に summary.tsv（機械可読）と summary.txt（実名をマスクした、そのまま貼れる形）を作る。
# summary.txt 以外のファイルにはデータベース名・テーブル名・IAM の identity が入りうる。
# 貼るときは中身を確かめること。DESCRIBE EXTENDED／FORMATTED の本体には S3 のロケーション
# （バケット名を含む）や Owner（IAM の識別子）が入りうるため、それらも hide() でマスクする
# （バケット名は OUTPUT からの置換、Owner は sts get-caller-identity から得た Account/Arn/
# 末尾の名前を追加でマスク対象にする）。
# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更や、コンソールでの設定変更で
# 変わりうる（工場出荷時の既定とは限らない）。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください（末尾に / を付ける）}"
DB=${DB:-}
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_DIR=${OUT_DIR:-${DEV_HOST_HOME:-$HOME}/athena-describe-extended-measurements}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}

PREFIX=athena_local_probe_275
H="${PREFIX}_h"
HP="${PREFIX}_hp"
I="${PREFIX}_i"
V="${PREFIX}_v"
X="${PREFIX}_x"
NODB="${PREFIX}_nodb"
# 場所は実行ごとに分ける。Hive の CTAS（external_location）は DROP してもデータが残り、
# 同じ場所で 2 回目を流すと「場所が既にある」で作成が失敗するため。
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"
LOC_HP="${OUTPUT}tables-probe-275-hp-${RUN_STAMP}/"
LOC_I="${OUTPUT}tables-probe-275-i-${RUN_STAMP}/"
LOC_H="${OUTPUT}tables-probe-275-h-${RUN_STAMP}/"

RUN_DIR="$OUT_DIR/run-$RUN_STAMP"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\tstatement_type\tsubstatement_type\text\tcontent_type\tmetadata_present\tupdate_count\trow_count\terror_category\terror_type\tstart_message\tstart_athena_error_code\tnote\n' > "$SUMMARY"
echo "出力先: $RUN_DIR"

# StartQueryExecution を実際に呼んだ回数（再試行込み）。1 回ごとにファイルへ 1 行積み、
# 最後に行数を数える（block-comment-parse-error.sh と同じやり方。コマンド置換で呼ぶ
# 関数は加算が親に伝わらないため）。
START_CALL_FILE="$RUN_DIR/.start-calls"
: > "$START_CALL_FILE"

# フィクスチャ（H・HP・I・V）の作成に着手したかどうか。trap での後始末に使う。
FIXTURES_ATTEMPTED=0
H_OK=0
HP_OK=0
I_OK=0
V_OK=0

# QueryExecutionContext。DB が決まった後に設定する（既定は preflight の間だけ Catalog のみ）。
QE_CONTEXT="Catalog=$CATALOG"

# 生ログの中間ファイルは、途中で止めても残らないよう trap で消す。フィクスチャ作成に
# 着手していたら、ベストエフォートで DROP も投げる（本編の後始末でも消すので、これは
# 異常終了時の保険。正常終了で 4 つとも消えていれば、この保険は呼ばない）。
cleanup() {
  rm -f "$RUN_DIR"/.tmp-*
  if [ "$FIXTURES_ATTEMPTED" = 1 ]; then
    aws athena start-query-execution --region "$REGION" \
      --query-string "DROP VIEW IF EXISTS $DB.$V" \
      --query-execution-context "Catalog=$CATALOG,Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
    aws athena start-query-execution --region "$REGION" \
      --query-string "DROP TABLE IF EXISTS $DB.$I" \
      --query-execution-context "Catalog=$CATALOG,Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
    aws athena start-query-execution --region "$REGION" \
      --query-string "DROP TABLE IF EXISTS $DB.$HP" \
      --query-execution-context "Catalog=$CATALOG,Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
    aws athena start-query-execution --region "$REGION" \
      --query-string "DROP TABLE IF EXISTS $DB.$H" \
      --query-execution-context "Catalog=$CATALOG,Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# --- 実名のマスク ----------------------------------------------------------------
# 実名（DB 名・出力先・バケット名・アカウント ID・呼び出し元の IAM identity）を置換して隠す。
# 長い実名から先に置き換える（DB 名がバケット名の一部を含む、などの入れ子で短い方を先に潰すと
# 一部が残ることがある。#221・#224 の教訓）。CALLER_* は preflight で sts get-caller-identity から
# 埋める（取れなければ空のままで、その場合は該当のマスクだけ効かない）。
OUTPUT_BUCKET=${OUTPUT#s3://}
OUTPUT_BUCKET=${OUTPUT_BUCKET%%/*}
CALLER_ACCOUNT=""
CALLER_ARN=""
CALLER_NAME=""
hide_pairs() {
  local value mark
  while IFS=$'\t' read -r value mark; do
    [ -n "$value" ] && printf '%s\t%s\t%s\n' "${#value}" "$value" "$mark"
  done <<EOF
$DB	<DB>
$OUTPUT	<OUTPUT>
$OUTPUT_BUCKET	<BUCKET>
$CALLER_ARN	<CALLER_ARN>
$CALLER_ACCOUNT	<ACCOUNT_ID>
$CALLER_NAME	<CALLER_NAME>
EOF
}
hide() {
  local s=$1 value mark
  while IFS=$'\t' read -r _ value mark; do
    s=${s//"$value"/$mark}
  done < <(hide_pairs | sort -t $'\t' -k1,1nr)
  printf '%s' "$s" | sed -E 's/(^|[^0-9])[0-9]{12}([^0-9]|$)/\1<ACCOUNT_ID>\2/g'
}

# 制御文字を落として短くする（改行も潰す）。note に入れる前に必ず通す。
sanitize() {
  printf '%s' "$1" | tr '\t\n\r' '   ' | cut -c1-300
}

# 制御文字（改行は残す）を落とし、実名を伏せたうえで長すぎれば頭だけにする。
# summary.txt の本体・StateChangeReason の全文表示に使う。
hide_multiline() {
  local f=$1 data
  [ -s "$f" ] || { echo "(空)"; return; }
  data=$(tr -d '\000-\010\013\014\016-\037' < "$f")
  data=$(hide "$data")
  if [ "${#data}" -gt 4000 ]; then
    printf '%s\n[...4000 文字を超えたので省略。全文は %s]\n' "${data:0:4000}" "$(basename "$f")"
  else
    printf '%s\n' "$data"
  fi
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

# execution.json から State / StateChangeReason / AthenaError の全文をファイルに書く。
write_reason() {
  local src=$1 dest=$2
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception:
    open(sys.argv[2], "w").write("(execution.json を読めませんでした)\n")
    sys.exit(0)
status = d.get("Status", {})
out = []
out.append("State: %s" % status.get("State", ""))
out.append("StateChangeReason: %s" % status.get("StateChangeReason", "(無し)"))
err = status.get("AthenaError")
if err is None:
    out.append("AthenaError: (無し)")
else:
    out.append("AthenaError: %s" % json.dumps(err, ensure_ascii=False, indent=2, sort_keys=True))
open(sys.argv[2], "w").write("\n".join(out) + "\n")' "$src" "$dest"
}

# AthenaError の ErrorCategory / ErrorType / ErrorMessage をタブ区切りで返す（無ければ 3 つとも "-"）。
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

# execution.json から StatementType / SubstatementType / OutputLocation をタブ区切りで返す。
read_execution_fields() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception:
    print("-\t-\t")
    sys.exit(0)
print("%s\t%s\t%s" % (
    d.get("StatementType") or "-",
    d.get("SubstatementType") or "-",
    (d.get("ResultConfiguration") or {}).get("OutputLocation", "")))' "$1"
}

# execution.json から Query（受け取った SQL の写し。DB が落ちるかを見る本命）を返す。
query_of() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception:
    print("")
    sys.exit(0)
print(d.get("Query") or "")' "$1"
}

# execution.json から QueryExecutionContext を 1 行の JSON にして返す。
context_of() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception:
    print("{}")
    sys.exit(0)
print(json.dumps(d.get("QueryExecutionContext") or {}, ensure_ascii=False, sort_keys=True))' "$1"
}

# GetQueryResults の 1 ページから ColumnInfo（1 行 1 列、Name:Type）を書き出す。
results_columns_of() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
rs = d.get("ResultSet") or {}
md = rs.get("ResultSetMetadata") or {}
cols = md.get("ColumnInfo") or []
for c in cols:
    print("%s:%s" % (c.get("Name"), c.get("Type")))' "$1"
}

# GetQueryResults の 1 ページから Rows（1 行 1 Row、列はタブ区切りで連結。None は空文字）を書き出す。
results_rows_of() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
rs = d.get("ResultSet") or {}
for r in rs.get("Rows") or []:
    vals = []
    for x in r.get("Data") or []:
        v = x.get("VarCharValue")
        vals.append(v if v is not None else "")
    print("\t".join(vals).replace("\n", "\\n"))' "$1"
}

# GetQueryResults の 1 ページから NextToken を返す（無ければ空）。
results_next_token_of() {
  python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("NextToken") or "")
except Exception:
    print("")' "$1"
}

# GetQueryResults の 1 ページから UpdateCount を返す（無ければ "-"）。
results_update_count_of() {
  python3 -c 'import json, sys
try:
    u = json.load(open(sys.argv[1])).get("UpdateCount")
except Exception:
    u = None
print("-" if u is None else str(u))' "$1"
}

# GetQueryResults を全ページ取り、<label>.results-<n>.json・<label>.results.columns.txt・
# <label>.results.rows.txt・<label>.results.update_count.txt に書く。ページの取得は retry_aws
# 経由（名前解決・接続の一時的な失敗を RETRY_MAX 回まで再試行）。
capture_results() {
  local label=$1 id=$2 token="" page=0
  : > "$RUN_DIR/$label.results.rows.txt"
  rm -f "$RUN_DIR/$label.results.columns.txt" "$RUN_DIR/$label.results.update_count.txt"
  while :; do
    page=$((page + 1))
    local page_json="$RUN_DIR/$label.results-$page.json"
    local page_err="$RUN_DIR/$label.results-$page.err"
    if [ -z "$token" ]; then
      retry_aws "$page_json" "$page_err" aws athena get-query-results --region "$REGION" \
        --query-execution-id "$id" --max-results 1000
    else
      retry_aws "$page_json" "$page_err" aws athena get-query-results --region "$REGION" \
        --query-execution-id "$id" --max-results 1000 --next-token "$token"
    fi
    [ -s "$page_json" ] || break
    if [ "$page" = 1 ]; then
      results_columns_of "$page_json" > "$RUN_DIR/$label.results.columns.txt"
      results_update_count_of "$page_json" > "$RUN_DIR/$label.results.update_count.txt"
    fi
    results_rows_of "$page_json" >> "$RUN_DIR/$label.results.rows.txt"
    token=$(results_next_token_of "$page_json")
    [ -n "$token" ] || break
    [ "$page" -ge 20 ] && break
  done
  [ -s "$RUN_DIR/$label.results.update_count.txt" ] || echo "-" > "$RUN_DIR/$label.results.update_count.txt"
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

# start.err から Message と AthenaErrorCode を抜く。
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

# StartQueryExecution を投げる。名前解決・接続系の失敗だけを RETRY_MAX 回まで再試行する
# （実際の SQL エラーは 1 回で確定させる）。試行回数は呼び出し側が read_attempts で読む。
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

# summary.tsv に 1 行積む。列の並びはヘッダと同じ 14 列で固定する。
emit_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$SUMMARY"
}

# 項目を未測定として summary に 1 行残す。全体を止めずに次へ進む。
skip() {
  local label=$1 note=$2
  echo "== $label: 未測定（$note）"
  emit_row "$label" "SKIPPED" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "$(sanitize "$note")"
}

# ラベルを指定して 1 文を実行し、終端状態まで待って State・StatementType・SubstatementType・
# Query・Context・OutputLocation の拡張子・Content-Type・.metadata・GetQueryResults
# （ColumnInfo・Rows・UpdateCount）を採取する。開始できなければ、AthenaErrorCode・Message を
# その場の start.err からそのまま抜く（追加の呼び出しはしない）。成功したときだけ 0 を返す。
run() {
  local label=$1 sql=$2
  local id state stype sub loc query ctx_json
  local ext="-" ctype="-" meta_present="no" update_count="-" row_count="-"
  local err_cat="-" err_type="-" start_msg="-" start_code="-"
  local attempts note

  printf '%s' "$sql" > "$RUN_DIR/$label.sql"
  id=$(start_query_retry "$label" "$sql")
  attempts=$(read_attempts "$label")

  if [ -z "${id:-}" ]; then
    start_msg=$(start_err_message "$RUN_DIR/$label.start.err")
    start_code=$(start_err_code "$RUN_DIR/$label.start.err")
    note="attempts=$attempts; $(first_err_line "$RUN_DIR/$label.start.err")"
    echo "== $label: 開始できませんでした（試行 $attempts 回）。AthenaErrorCode=$start_code"
    emit_row "$label" "START_FAILED" "-" "-" "-" "-" "-" "-" "-" "-" "-" "$start_msg" "$start_code" "$(sanitize "$note")"
    return 1
  fi

  state=$(poll_until_terminal "$id")

  aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.execution.json" 2> "$RUN_DIR/$label.execution.err"
  write_reason "$RUN_DIR/$label.execution.json" "$RUN_DIR/$label.reason.txt"

  IFS=$'\t' read -r stype sub loc < <(read_execution_fields "$RUN_DIR/$label.execution.json")
  query=$(query_of "$RUN_DIR/$label.execution.json")
  printf '%s' "$query" > "$RUN_DIR/$label.query.txt"
  ctx_json=$(context_of "$RUN_DIR/$label.execution.json")
  printf '%s' "$ctx_json" > "$RUN_DIR/$label.context.txt"
  ext=$(ext_of "$loc")

  case "$state" in
    FAILED | CANCELLED)
      IFS=$'\t' read -r err_cat err_type _ < <(athena_error_fields_of "$RUN_DIR/$label.execution.json")
      ;;
  esac

  # GetQueryResults は本物だと FAILED でも 200（ResultSetMetadata: null）で返るはずなので、
  # State によらず必ず試す（result-files.md「失敗・取り消し時に本物が置く結果ファイル」参照）。
  capture_results "$label" "$id"
  update_count=$(cat "$RUN_DIR/$label.results.update_count.txt" 2>/dev/null || echo -)
  if [ -f "$RUN_DIR/$label.results.rows.txt" ]; then
    row_count=$(wc -l < "$RUN_DIR/$label.results.rows.txt" | tr -d ' ')
  fi

  if [ -n "$loc" ]; then
    { echo "# ls $loc"; aws s3 ls "$loc" --region "$REGION"; echo "# rc=$?"
      echo "# ls $loc.metadata"; aws s3 ls "$loc.metadata" --region "$REGION"; echo "# rc=$?"
    } > "$RUN_DIR/$label.ls.txt" 2>&1

    if fetch "$loc" "$RUN_DIR/$label.bytes" "$RUN_DIR/$label.cp.err"; then
      od -An -tx1c "$RUN_DIR/$label.bytes" > "$RUN_DIR/$label.od.txt"
    fi
    if head_object "$loc" "$RUN_DIR/$label.head.json" "$RUN_DIR/$label.head.err"; then
      ctype=$(content_type_of "$RUN_DIR/$label.head.json")
    fi
    if fetch "$loc.metadata" "$RUN_DIR/$label.metadata.bytes" "$RUN_DIR/$label.metadata.cp.err"; then
      od -An -tx1c "$RUN_DIR/$label.metadata.bytes" > "$RUN_DIR/$label.metadata.od.txt"
      meta_present="yes"
    fi
    head_object "$loc.metadata" "$RUN_DIR/$label.metadata.head.json" "$RUN_DIR/$label.metadata.head.err" || true
  fi

  note="attempts=$attempts"
  echo "== $label  state=$state  type=$stype/$sub  ext=$ext  ct=$ctype  metadata=$meta_present  update_count=$update_count  rows=$row_count  error=$err_cat/$err_type"
  emit_row "$label" "$state" "$stype" "$sub" "$ext" "$ctype" "$meta_present" "$update_count" "$row_count" "$err_cat" "$err_type" "$start_msg" "$start_code" "$(sanitize "$note")"
  [ "$state" = SUCCEEDED ]
}

# フィクスチャ（H/HP/I/V）が揃っていなければ skip し、揃っていれば run を呼ぶ。
# $3 以降は必要なフィクスチャの識別子（H/HP/I/V）。無い表 <X>・<NODB> や名前無しの項目は
# 要件無しで呼ぶ。
run_req() {
  local label=$1 sql=$2
  shift 2
  local req
  for req in "$@"; do
    case "$req" in
      H)  [ "$H_OK" = 1 ]  || { skip "$label" "H（Hive の EXTERNAL TABLE）を作れなかったため未測定"; return 1; } ;;
      HP) [ "$HP_OK" = 1 ] || { skip "$label" "HP（パーティション付き Hive 表）を作れなかったため未測定"; return 1; } ;;
      I)  [ "$I_OK" = 1 ]  || { skip "$label" "I（Iceberg 表）を作れなかったため未測定"; return 1; } ;;
      V)  [ "$V_OK" = 1 ]  || { skip "$label" "V（ビュー）を作れなかったため未測定"; return 1; } ;;
    esac
  done
  run "$label" "$sql"
}

# QueryExecutionContext を $1 に差し替えて run を 1 回呼ぶ（preflight の DB 選定・
# 「Context に Database 無し」の項目で使う）。
run_in_ctx() {
  local ctx=$1 label=$2 sql=$3 saved=$QE_CONTEXT rc
  QE_CONTEXT=$ctx
  run "$label" "$sql"
  rc=$?
  QE_CONTEXT=$saved
  return "$rc"
}

# run_in_ctx の run_req 版。
run_in_ctx_req() {
  local ctx=$1 label=$2 sql=$3
  shift 3
  local saved=$QE_CONTEXT rc
  QE_CONTEXT=$ctx
  run_req "$label" "$sql" "$@"
  rc=$?
  QE_CONTEXT=$saved
  return "$rc"
}

# SHOW CREATE TABLE でテーブルの形式を確かめ、hive / iceberg / unknown を標準出力に返す
# （呼び出し側は $(...) で受ける）。DROP される前（作った直後）にしか呼べない。
verify_format() {
  local suffix=$1 table_name=$2 id state loc fmt="unknown"
  local sql="SHOW CREATE TABLE $DB.$table_name"
  printf '%s' "$sql" > "$RUN_DIR/verify-$suffix.sql"
  id=$(start_query_retry "verify-$suffix" "$sql")
  if [ -n "${id:-}" ]; then
    state=$(poll_until_terminal "$id")
    aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
      > "$RUN_DIR/verify-$suffix.execution.json" 2>/dev/null
    IFS=$'\t' read -r _ _ loc < <(read_execution_fields "$RUN_DIR/verify-$suffix.execution.json")
    if [ "$state" = SUCCEEDED ] && [ -n "$loc" ] \
      && fetch "$loc" "$RUN_DIR/verify-$suffix.txt" "$RUN_DIR/verify-$suffix.err"; then
      if grep -qi "table_type'*=*'*iceberg" "$RUN_DIR/verify-$suffix.txt"; then
        fmt=iceberg
      else
        fmt=hive
      fi
    fi
  fi
  echo "== $table_name: table_format=$fmt（SHOW CREATE TABLE で確認）" >&2
  printf '%s' "$fmt"
}

# ============================================================================
# preflight 1: 実行系（aws・python3）の能力を実際に試して確かめる。
# command -v は PATH にあるかしか確かめないので、実際に使うオプションで呼んでみる。
# list-work-groups は Athena のクエリではない軽い読み取りで、DB を要らず課金も乗らない。
# sts get-caller-identity は Owner 欄のマスクに使う識別子を得るためのもので、失敗しても
# ベストエフォート（該当のマスクだけ効かなくなる）で続行する。
# ============================================================================

CAPS="$RUN_DIR/capabilities.txt"
{
  echo "# 実行環境の能力（$(date -Iseconds)）"
  echo "aws: $(command -v aws 2>/dev/null || echo '(見つからない)')"
  echo "python3: $(command -v python3 2>/dev/null || echo '(見つからない)')"
  echo "REGION: $REGION"
  echo "CATALOG: $CATALOG"
} > "$CAPS"

lwg_attempt=1
while :; do
  if aws athena list-work-groups --region "$REGION" --output json \
    > "$RUN_DIR/preflight-list-work-groups.json" 2> "$RUN_DIR/preflight-list-work-groups.err"; then
    rm -f "$RUN_DIR/preflight-list-work-groups.err"
    echo "athena list-work-groups: 通った（試行 $lwg_attempt 回）" >> "$CAPS"
    break
  fi
  if [ "$lwg_attempt" -ge "$RETRY_MAX" ] || ! is_transient_error "$RUN_DIR/preflight-list-work-groups.err"; then
    echo "athena list-work-groups: 通らなかった（試行 $lwg_attempt 回）" >> "$CAPS"
    [ -s "$RUN_DIR/preflight-list-work-groups.json" ] || rm -f "$RUN_DIR/preflight-list-work-groups.json"
    echo
    echo "aws athena list-work-groups が通りません（試行 $lwg_attempt 回）。"
    echo "aws コマンド・資格情報・REGION（$REGION）を確かめてください。理由: $(first_err_line "$RUN_DIR/preflight-list-work-groups.err")"
    echo "詳細: $RUN_DIR/preflight-list-work-groups.err"
    exit 1
  fi
  echo "== preflight: list-work-groups が一時的に失敗。${RETRY_DELAY} 秒後に再試行します（試行 $lwg_attempt/$RETRY_MAX）" >&2
  sleep "$RETRY_DELAY"
  lwg_attempt=$((lwg_attempt + 1))
done

if ! python3 -c 'import json, sys' > /dev/null 2> "$RUN_DIR/preflight-python.err"; then
  echo "python3: 使えない" >> "$CAPS"
  echo
  echo "python3 で json を読み込めません（$(first_err_line "$RUN_DIR/preflight-python.err")）。"
  exit 1
fi
rm -f "$RUN_DIR/preflight-python.err"
echo "python3: json を読める" >> "$CAPS"

# sts get-caller-identity はベストエフォート。取れたら Account/Arn/末尾の名前をマスク対象に足す。
if aws sts get-caller-identity --region "$REGION" --output json \
  > "$RUN_DIR/caller-identity.json" 2> "$RUN_DIR/caller-identity.err"; then
  rm -f "$RUN_DIR/caller-identity.err"
  CALLER_ACCOUNT=$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("Account") or "")
except Exception:
    print("")' "$RUN_DIR/caller-identity.json")
  CALLER_ARN=$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("Arn") or "")
except Exception:
    print("")' "$RUN_DIR/caller-identity.json")
  CALLER_NAME=${CALLER_ARN##*/}
  echo "sts get-caller-identity: 通った（Owner 欄のマスクに使う）" >> "$CAPS"
else
  echo "sts get-caller-identity: 通らなかった（DESCRIBE FORMATTED の Owner 欄はマスクされない場合がある）" >> "$CAPS"
fi

# ============================================================================
# preflight 2: DB の選定（対象の自動選択）。DB が指定されていれば SHOW TABLES で
# 実在を確かめる。指定が無いか実在しなければ SHOW DATABASES の候補の 1 件目を使う。
# 続けて、athena_local_probe_275_* という名前が既に無いことを同じ SHOW TABLES の結果で
# 確かめる（衝突防止。1 件でもあれば何も作らずに止まる）。
# ============================================================================

LIST_OK=1
if [ -n "$DB" ]; then
  if run_in_ctx "Catalog=$CATALOG,Database=$DB" list-tables "SHOW TABLES"; then
    LIST_OK=0
  fi
fi

if [ "$LIST_OK" != 0 ]; then
  if [ -n "$DB" ]; then
    echo "指定された DB で SHOW TABLES が通りませんでした。理由: $RUN_DIR/list-tables.reason.txt"
  else
    echo "DB が指定されていません。"
  fi
  echo "SHOW DATABASES の候補から選びます。"
  if ! run_in_ctx "Catalog=$CATALOG" available-databases "SHOW DATABASES"; then
    echo
    echo "SHOW DATABASES も通りませんでした。資格情報・REGION（$REGION）・権限を確かめてください。"
    echo "理由: $RUN_DIR/available-databases.reason.txt（開始できなければ $RUN_DIR/available-databases.start.err）"
    exit 1
  fi
  if [ ! -s "$RUN_DIR/available-databases.bytes" ]; then
    echo
    echo "SHOW DATABASES は成功しましたが、候補の一覧を取得できませんでした（$RUN_DIR/available-databases.cp.err）。"
    exit 1
  fi
  DB=$(python3 -c '
import csv, sys
with open(sys.argv[1], newline="") as f:
    for row in csv.reader(f):
        if row and row[0]:
            print(row[0])
            break
' "$RUN_DIR/available-databases.bytes")
  if [ -z "$DB" ]; then
    echo
    echo "候補の一覧から DB 名を読めませんでした。$RUN_DIR/available-databases.bytes を確かめてください。"
    exit 1
  fi
  echo "候補の一覧の 1 件目を DB に使います（実名は端末には出しません。一覧: $RUN_DIR/available-databases.bytes）。"
  if ! run_in_ctx "Catalog=$CATALOG,Database=$DB" list-tables "SHOW TABLES"; then
    echo
    echo "候補の 1 件目でも SHOW TABLES が通りませんでした。理由: $RUN_DIR/list-tables.reason.txt"
    exit 1
  fi
fi

QE_CONTEXT="Catalog=$CATALOG,Database=$DB"

if [ -s "$RUN_DIR/list-tables.bytes" ] && grep -qi "$PREFIX" "$RUN_DIR/list-tables.bytes"; then
  echo
  echo "このデータベースに ${PREFIX}_* という名前のテーブル／ビューが既にあります。"
  echo "上書き事故を避けるため、何も作らずに止まります。一覧: $RUN_DIR/list-tables.bytes（実名を含みます）"
  exit 1
elif [ ! -s "$RUN_DIR/list-tables.bytes" ] && [ -f "$RUN_DIR/list-tables.bytes" ]; then
  : # 0 バイト（テーブルが 1 件も無い）は衝突なしとみなして続ける。
elif [ ! -f "$RUN_DIR/list-tables.bytes" ]; then
  echo
  echo "SHOW TABLES の結果本体を取得できず、${PREFIX}_* が無いことを確認できません。"
  echo "安全のため何も作らずに止まります（$RUN_DIR/list-tables.cp.err）。"
  exit 1
fi

# ============================================================================
# フィクスチャの作成: H（Hive の EXTERNAL TABLE）・HP（パーティション付き Hive。CTAS）・
# I（Iceberg。CTAS）・V（ビュー）。作った直後に SHOW CREATE TABLE で形式を裏取りする
# （DROP 後は呼べない）。
# ============================================================================

echo
echo "フィクスチャを作成します（DDL）。"
FIXTURES_ATTEMPTED=1
FMT_H=unknown
FMT_HP=unknown
FMT_I=unknown

if run create-h "CREATE EXTERNAL TABLE $DB.$H (n int, s string COMMENT 'the s column') LOCATION '$LOC_H'"; then
  H_OK=1
  FMT_H=$(verify_format h "$H")
else
  echo "== H（Hive の EXTERNAL TABLE）を作れませんでした。H を使う項目は未測定にします。"
fi

if run create-hp "CREATE TABLE $DB.$HP WITH (partitioned_by = ARRAY['p'], external_location = '$LOC_HP') AS SELECT 1 AS n, 'x' AS p"; then
  HP_OK=1
  FMT_HP=$(verify_format hp "$HP")
else
  echo "== HP（パーティション付き Hive 表）を作れませんでした。HP を使う項目は未測定にします。"
fi

if run create-i "CREATE TABLE $DB.$I WITH (table_type = 'ICEBERG', partitioning = ARRAY['p'], location = '$LOC_I') AS SELECT 1 AS n, 'x' AS p"; then
  I_OK=1
  FMT_I=$(verify_format i "$I")
else
  echo "== I（Iceberg 表）を作れませんでした。I を使う項目は未測定にします。"
fi

if run create-v "CREATE VIEW $DB.$V AS SELECT 1 AS n, 'x' AS s"; then
  V_OK=1
else
  echo "== V（ビュー）を作れませんでした。V を使う項目は未測定にします。"
fi

# ============================================================================
# 1. EXTENDED・FORMATTED・対照の DESCRIBE を H・HP・I・V・X に。
# ============================================================================

run_req e_h  "DESCRIBE EXTENDED $DB.$H"  H
run_req e_hp "DESCRIBE EXTENDED $DB.$HP" HP
run_req e_i  "DESCRIBE EXTENDED $DB.$I"  I
run_req e_v  "DESCRIBE EXTENDED $DB.$V"  V
run      e_x  "DESCRIBE EXTENDED $DB.$X"

run_req f_h  "DESCRIBE FORMATTED $DB.$H"  H
run_req f_hp "DESCRIBE FORMATTED $DB.$HP" HP
run_req f_i  "DESCRIBE FORMATTED $DB.$I"  I
run_req f_v  "DESCRIBE FORMATTED $DB.$V"  V
run      f_x  "DESCRIBE FORMATTED $DB.$X"

run_req d_h  "DESCRIBE $DB.$H"  H
run_req d_hp "DESCRIBE $DB.$HP" HP
run_req d_i  "DESCRIBE $DB.$I"  I
run_req d_v  "DESCRIBE $DB.$V"  V

# ============================================================================
# 2. Query の書き方の変異（H。EXTENDED は qe1〜qe10、FORMATTED は qf1〜qf10 で同じ 10 形）。
# qe1・qf1 は無修飾の表名 + Context の Database（$QE_CONTEXT には既に Database=$DB が
# 入っている）。qe9・qf9 は Context から Database を落とし、SQL 側の <db>.<t> で解決する。
# ============================================================================

run_req      qe1  "DESCRIBE EXTENDED $H" H
run_req      qe2  "DESCRIBE EXTENDED awsdatacatalog.$DB.$H" H
run_req      qe3  "DESCRIBE EXTENDED AwsDataCatalog.$DB.$H" H
run_req      qe4  "describe extended $DB.$H" H
run_req      qe5  "DESC EXTENDED $DB.$H" H
run_req      qe6  "DESCRIBE  EXTENDED $DB.$H" H
run_req      qe7  $'DESCRIBE\n'"EXTENDED $DB.$H" H
run_req      qe8  "DESCRIBE EXTENDED $DB.$H;" H
run_in_ctx_req "Catalog=$CATALOG" qe9  "DESCRIBE EXTENDED $DB.$H" H
run_req      qe10 "DESCRIBE EXTENDED $DB.\`$H\`" H

run_req      qf1  "DESCRIBE FORMATTED $H" H
run_req      qf2  "DESCRIBE FORMATTED awsdatacatalog.$DB.$H" H
run_req      qf3  "DESCRIBE FORMATTED AwsDataCatalog.$DB.$H" H
run_req      qf4  "describe formatted $DB.$H" H
run_req      qf5  "DESC FORMATTED $DB.$H" H
run_req      qf6  "DESCRIBE  FORMATTED $DB.$H" H
run_req      qf7  $'DESCRIBE\n'"FORMATTED $DB.$H" H
run_req      qf8  "DESCRIBE FORMATTED $DB.$H;" H
run_in_ctx_req "Catalog=$CATALOG" qf9  "DESCRIBE FORMATTED $DB.$H" H
run_req      qf10 "DESCRIBE FORMATTED $DB.\`$H\`" H

# ============================================================================
# 3. 列指定とパーティション指定。
# ============================================================================

run_req p1 "DESCRIBE EXTENDED $DB.$H n" H
run_req p2 "DESCRIBE FORMATTED $DB.$H n" H
run_req p3 "DESCRIBE EXTENDED $DB.$HP PARTITION (p='x')" HP
run_req p4 "DESCRIBE FORMATTED $DB.$HP PARTITION (p='x')" HP
run_req p5 "DESCRIBE $DB.$I n" I
run_req p6 "DESCRIBE EXTENDED $DB.$I n" I
run_req p7 "DESCRIBE FORMATTED $DB.$I n" I
run_req p8 "DESCRIBE $DB.$I PARTITION (p='x')" I
run_req p9 "DESC $DB.$I" I

# ============================================================================
# 4. 失敗系。
# ============================================================================

run "z1" "DESCRIBE EXTENDED"
run "z2" "DESCRIBE FORMATTED"
run "z3" "DESCRIBE EXTENDED $NODB.$H"
run_req z4 "DESCRIBE EXTENDED $DB.$H nocol_275" H
run_req z5 "DESCRIBE EXTENDED $DB.$HP PARTITION (p='nope_275')" HP

# ============================================================================
# 後始末: 作った 4 つを DROP する。
# ============================================================================

echo
echo "後始末（DROP）を行います。"
CLEANUP_ALL_OK=1
if [ "$V_OK" = 1 ]; then
  run drop-v "DROP VIEW IF EXISTS $DB.$V" || CLEANUP_ALL_OK=0
fi
if [ "$I_OK" = 1 ]; then
  run drop-i "DROP TABLE IF EXISTS $DB.$I" || CLEANUP_ALL_OK=0
fi
if [ "$HP_OK" = 1 ]; then
  run drop-hp "DROP TABLE IF EXISTS $DB.$HP" || CLEANUP_ALL_OK=0
fi
if [ "$H_OK" = 1 ]; then
  run drop-h "DROP TABLE IF EXISTS $DB.$H" || CLEANUP_ALL_OK=0
fi
if [ "$CLEANUP_ALL_OK" = 1 ]; then
  FIXTURES_ATTEMPTED=0
else
  echo "== 後始末の DROP に成功しなかったものがあります。終了時にもう一度投げます。"
  echo "   それでも消えなければ、$DB の ${PREFIX}_* を手で消してください。"
fi

# ============================================================================
# summary の作成。
# ============================================================================

PREFLIGHT_LABELS="list-tables available-databases"
FIXTURE_LABELS="create-h create-hp create-i create-v verify-h verify-hp verify-i"
GROUP1_LABELS="e_h e_hp e_i e_v e_x f_h f_hp f_i f_v f_x d_h d_hp d_i d_v"
GROUP2_LABELS="qe1 qe2 qe3 qe4 qe5 qe6 qe7 qe8 qe9 qe10 qf1 qf2 qf3 qf4 qf5 qf6 qf7 qf8 qf9 qf10"
GROUP3_LABELS="p1 p2 p3 p4 p5 p6 p7 p8 p9"
GROUP4_LABELS="z1 z2 z3 z4 z5"
CLEANUP_LABELS="drop-v drop-i drop-hp drop-h"
ALL_LABELS="$PREFLIGHT_LABELS $FIXTURE_LABELS $GROUP1_LABELS $GROUP2_LABELS $GROUP3_LABELS $GROUP4_LABELS $CLEANUP_LABELS"

# summary.tsv から 1 行を読み、要点を 1 行にまとめて返す。
row_summary_of() {
  python3 -c 'import csv, sys
label = sys.argv[2]
with open(sys.argv[1], newline="") as f:
    for row in csv.DictReader(f, delimiter="\t"):
        if row["label"] == label:
            print(
                "state={state} type={statement_type}/{substatement_type} "
                "ext={ext} content_type={content_type} metadata={metadata_present} "
                "update_count={update_count} row_count={row_count} "
                "error={error_category}/{error_type} "
                "start_message={start_message} start_code={start_athena_error_code} "
                "note={note}".format(**row)
            )
            break' "$SUMMARY" "$1"
}

# <label>.results.columns.txt を「Name:Type, Name:Type, ...」の 1 行にして返す（無ければ "-"）。
columns_display_of() {
  local f="$RUN_DIR/$1.results.columns.txt"
  if [ -s "$f" ]; then
    hide "$(paste -sd, "$f")"
  else
    echo "-"
  fi
}

write_summary_txt() {
  local txt="$RUN_DIR/summary.txt"
  {
    echo "# issue #275: DESCRIBE EXTENDED・DESCRIBE FORMATTED を本物どおり実行したときの"
    echo "#             結果の形（Query・Context・StatementType・結果ファイル・GetQueryResults）を実測"
    echo "# 実行日時: $(date -Iseconds)"
    echo "# StartQueryExecution を呼んだ回数（一時的な失敗の再試行込み。フィクスチャ作成・"
    echo "#   形式の裏取り（SHOW CREATE TABLE）・後始末の DROP を含む。list-work-groups・"
    echo "#   sts get-caller-identity など Athena のクエリではない API 呼び出しは含めない）: $(wc -l < "$START_CALL_FILE" | tr -d ' ')"
    echo "#   ※ GetQueryExecution / GetQueryResults / S3 への呼び出しはこの回数に含めない（課金には影響しない）。"
    echo "#   ※ trap で発動する後始末（ベストエフォートの DROP）だけはこの回数に含めない。"
    echo "#     正常終了で 4 つとも消せていれば trap は何も呼ばない。"
    echo "# DDL: あり。作成: ${PREFIX}_h（Hive の EXTERNAL TABLE）・${PREFIX}_hp（パーティション付き"
    echo "#   Hive、CTAS）・${PREFIX}_i（Iceberg、CTAS）・${PREFIX}_v（ビュー）の 4 つ。投げる項目は"
    echo "#   すべて DESCRIBE 系の読み取りのみ（ALTER・RENAME・DROP COLUMN は投げない）。最後に 4 つ"
    echo "#   とも DROP。location は <OUTPUT> の下の実行ごとの場所（tables-probe-275-*-<日時>/）。"
    echo "#   ${PREFIX}_i（Iceberg）は DROP でデータも消えるが、${PREFIX}_hp（Hive の CTAS）は DROP しても"
    echo "#   データ（1 行）が残る。${PREFIX}_h（Hive の EXTERNAL）は行を入れていないので中身は無い。"
    echo "# 課金の見込み: スキャンする SELECT は投げていない。CTAS の SELECT はリテラルだけ。"
    echo "#   DROP はメタデータのみ、DESCRIBE 系は読み取りのみ。Athena の最小課金 × クエリ数の見込み。"
    echo "# フィクスチャの形式（SHOW CREATE TABLE で裏取り。作成直後の値）: H=$FMT_H  HP=$FMT_HP  I=$FMT_I"
    echo "#   （hive/iceberg 以外は、作成に失敗したか裏取りできなかったことを示す）"
    echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更や、コンソールでの"
    echo "#   設定変更で変わりうる。実測値は工場出荷時の既定とは限らない。"
    echo "# 注意: DESCRIBE EXTENDED／FORMATTED の本体には S3 のロケーション（バケット名）や Owner"
    echo "#   （IAM の識別子）が入りうる。バケット名は OUTPUT からの置換でマスクし、Owner は"
    echo "#   sts get-caller-identity から得た Account/Arn/末尾の名前でマスクしている（該当の"
    echo "#   API 呼び出しが失敗しているとマスクされない場合がある。貼る前に中身を確かめること）。"
    echo
    echo "## 項目ごとの結果（1 項目 = 1 ブロック。実名は伏せる）"
    for label in $ALL_LABELS; do
      if [ -s "$RUN_DIR/$label.sql" ]; then
        echo "### $label"
        echo "- sql: $(hide "$(python3 -c 'import sys
print(repr(open(sys.argv[1], "rb").read().decode("utf-8", "replace")))' "$RUN_DIR/$label.sql")")"
        local row
        row=$(row_summary_of "$label")
        [ -n "$row" ] && echo "- $row"
        if [ -s "$RUN_DIR/$label.query.txt" ]; then
          echo "- Query: $(hide "$(python3 -c 'import sys
print(repr(open(sys.argv[1], "rb").read().decode("utf-8", "replace")))' "$RUN_DIR/$label.query.txt")")"
        fi
        if [ -s "$RUN_DIR/$label.context.txt" ]; then
          echo "- Context: $(hide "$(cat "$RUN_DIR/$label.context.txt")")"
        fi
        echo "- ColumnInfo: $(columns_display_of "$label")"
        if [ -s "$RUN_DIR/$label.reason.txt" ]; then
          echo "- State / StateChangeReason / AthenaError（全文）:"
          hide_multiline "$RUN_DIR/$label.reason.txt" | sed 's/^/    /'
        elif [ -s "$RUN_DIR/$label.start.err" ]; then
          echo "- 開始時に弾かれた（AthenaErrorCode・Message は上の行を参照。原文は $label.start.err）"
        fi
        if [ -s "$RUN_DIR/$label.results.rows.txt" ]; then
          local rc
          rc=$(wc -l < "$RUN_DIR/$label.results.rows.txt" | tr -d ' ')
          echo "- GetQueryResults の行数: $rc（先頭 3 行。全文は $label.results.rows.txt）"
          head -3 "$RUN_DIR/$label.results.rows.txt" | while IFS= read -r line; do
            echo "    $(sanitize "$(hide "$line")")"
          done
        else
          echo "- GetQueryResults の行数: 0（または取得できず）"
        fi
        # verify-* は run() を通さず determine_table_format 相当の verify_format が
        # 直接 <label>.txt に書く（.bytes は無い）。無ければ .txt にフォールバックする。
        local body_file="$RUN_DIR/$label.bytes" body_ref="$label.bytes"
        if [ ! -e "$body_file" ] && [ -e "$RUN_DIR/$label.txt" ]; then
          body_file="$RUN_DIR/$label.txt"
          body_ref="$label.txt"
        fi
        echo "- 結果ファイル本体（マスク済み。長ければ先頭 4000 文字。全文は $body_ref）:"
        hide_multiline "$body_file" | sed 's/^/    /'
        if [ -s "$RUN_DIR/$label.metadata.bytes" ]; then
          echo "- .metadata: あり（$(wc -c < "$RUN_DIR/$label.metadata.bytes" | tr -d ' ') バイト）"
        elif [ -f "$RUN_DIR/$label.metadata.bytes" ]; then
          echo "- .metadata: あり（0 バイト）"
        elif [ -s "$RUN_DIR/$label.metadata.cp.err" ]; then
          echo "- .metadata: 無し（証拠: $label.metadata.cp.err）"
        else
          echo "- .metadata: - （OutputLocation が無い、または未確認）"
        fi
        echo
      else
        echo "### $label"
        local skip_note
        skip_note=$(python3 -c 'import csv, sys
label = sys.argv[2]
with open(sys.argv[1], newline="") as f:
    for row in csv.DictReader(f, delimiter="\t"):
        if row["label"] == label:
            print(row["note"])
            break' "$SUMMARY" "$label")
        if [ -n "$skip_note" ]; then
          echo "- 未測定: $skip_note"
        else
          echo "- この実行では投げなかった（DB が指定どおり実在したため SHOW DATABASES は不要、など）"
        fi
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
echo "実名をマスクした、そのまま貼れる一覧: $SUMMARY_TXT"
echo "中身のファイルは $RUN_DIR にあります。リポジトリには入れないでください。"
echo "<label>.sql・<label>.query.txt・<label>.context.txt・<label>.reason.txt・<label>.start.err・"
echo "<label>.results.rows.txt・available-databases.bytes・caller-identity.json は実名（DB 名・"
echo "テーブル名・IAM の識別子）を含みうるので、summary.txt 以外を貼るときは中身を確かめてください。"
