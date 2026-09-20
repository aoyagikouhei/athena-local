#!/usr/bin/env bash
# 本物の Athena で、DROP TABLE の結果ファイルがテーブルの形式（Hive / Iceberg）で
# 違う件を実測する。issue #39 のための実測スクリプト。
# .claude/issue-notes/35-measure-insert-location.sh を雛形にしている（run・
# loc_shape_of・poll_until_terminal・start_query_retry・preflight・trap での
# 後始末・summary の実名マスクはそのまま流用）。
#
# 出どころ（#35 の実測、2026-09-20）: 後始末の DROP TABLE IF EXISTS を 3 本投げたら、
# Hive の CTAS 2 本は本体 0 バイト（binary/octet-stream）・.metadata 無し、
# Iceberg の CTAS は本体 1 バイト（application/octet-stream）・.metadata 41 バイト
# だった。#35 は結果本体を取得しておらず、1 バイトの中身が分からない。
#
# 測りたいこと（この 1 ラウンドで測り切る）:
#   - Iceberg のテーブルを消したときの <id>.txt の 1 バイトが何か（改行か、他の1文字か）
#   - 同じ差が出る DDL がほかにあるか（素の CREATE TABLE、ALTER TABLE）
#   - テーブルの形式ではなく「DROP という語」が効いているだけではないか
#     （テーブルの形式と無関係な DROP DATABASE を対照に入れて切り分ける）
# 「.metadata 41 バイトの中身」は #35 の生データから既に読めているので測り直さないが、
# このラウンドでも同じ経路で保存はする（対照つきで測るため、同じ 1 回に全部入れる）。
#
# 準備（CTAS。#35 の Hive / Iceberg の作り分けをそのまま使う）:
#   prep-h-ctas  CREATE TABLE ... AS SELECT（Hive、Athena の既定）
#   prep-i-ctas  CREATE TABLE ... WITH (table_type='ICEBERG', location=..., is_external=false)
#                AS SELECT（DROP でデータも消えるようにする）
#
# 本編（ラベルは issue #39 の設計表のとおり）:
#   a   素の CREATE TABLE <hive_plain> (n int)                          … CTAS でない Hive
#   b   素の CREATE TABLE <ice_plain> (n int) LOCATION ... TBLPROPERTIES (ICEBERG)
#   c1  ALTER TABLE <hive_plain> SET TBLPROPERTIES ('comment'='x')      … ALTER（Hive）
#   c2  ALTER TABLE <ice_plain> SET TBLPROPERTIES ('comment'='x')       … 同じ文を Iceberg に
#   d1  ALTER TABLE <hive_plain> ADD COLUMNS (m int)                    … ALTER の別の形
#   d2  ALTER TABLE <ice_plain> ADD COLUMNS (m int)
#   e   DROP TABLE <hive_ctas>   … #35 の Hive の結果（0B・.metadata 無し）の再現確認
#   f   DROP TABLE <ice_ctas>    … #35 の Iceberg の結果（1B・41B）の再現確認 + 1 バイトの中身
#   g   DROP TABLE <hive_plain>  … 作り方（CTAS か素の CREATE か）で変わるか
#   h   DROP TABLE <ice_plain>   … 同上（Iceberg）
#
# 対照（同じラウンドに入れる。#26 の教訓: 別の日・別のラウンドとの差を条件による違いと
# 解釈しない）:
#   probe        SHOW TABLES     … <id>.txt 228B / .metadata 312B のはず（preflight を兼ねる）
#   ctl-select   SELECT 1 AS n   … <id>.csv 8B / .metadata 73B のはず
#   ctl-createdb CREATE DATABASE … 対照の DDL（テーブルの形式と無関係）
#   ctl-dropdb   DROP DATABASE   … 「DROP という語」自体が効いているのか、テーブルの
#                                   形式が効いているのかを切り分けるための対照
#
# テーブルの形式は SHOW CREATE TABLE で全 4 テーブルを裏取りする（素の CREATE TABLE で
# 作った 2 本も含む。TBLPROPERTIES の指定が実際に効いたかどうかが結論の前提になるため）。
# 裏取りは DROP される前（作った直後）にしかできないので、先に確かめておいた値を、
# 同じテーブルに触れる後続の行（ALTER・DROP）にも書き込む（apply_table_format）。
#
# 使い方:
#   OUTPUT=s3://your-bucket/prefix/ DB=your_db bash .claude/issue-notes/39-measure-drop-table-format.sh
#
# 必要な環境変数:
#   OUTPUT    結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける）。
#   DB        データベース名。実在するものを指定する。
#
# 任意の環境変数:
#   CATALOG      既定 AwsDataCatalog
#   REGION       既定 ap-northeast-1
#   OUT_DIR      既定 $HOME/athena-drop-table-format-measurements（実名が入るのでリポジトリの外）
#   POLL_TIMEOUT 終端状態を待つ上限（秒）。既定 180
#   RETRY_MAX    名前解決・接続など一時的な失敗を再試行する回数の上限。既定 4
#   RETRY_DELAY  再試行の間隔（秒）。既定 5
#   PROBE_DDL    既定 1（測る）。0 にすると preflight（SHOW TABLES）だけで終わり、
#                本編・対照を含め全項目を skip する（何も作らない）。
#
# ** このスクリプトが本物に対して行う破壊的な操作 **
#   <db>.athena_local_probe_39_hive_ctas / _ice_ctas / _hive_plain / _ice_plain の
#   4 テーブルを作り（前者 2 本は CTAS、後者 2 本は素の CREATE TABLE）、Hive / Iceberg
#   それぞれに ALTER TABLE を 2 回投げてから、最後に全部 DROP TABLE で消す。
#   ついでに athena_local_probe_39_db という名前のデータベースを 1 本 CREATE してすぐ
#   DROP する（対照）。同名のテーブル・データベースが既にあると壊すので、開始前に
#   SHOW TABLES で存在を確かめ、1 件でもあればテーブルを作らずに止まる
#   （データベースは、既存のものを壊さないよう CREATE DATABASE 自体を送ってその成否で
#   判定する。失敗すれば DROP DATABASE は投げない。専用の接頭辞 athena_local_probe_39_db
#   を使うので、実在のデータベースと衝突する見込みは低い）。
#   Hive のテーブル（_hive_ctas。素の CREATE TABLE の _hive_plain がもし LOCATION 無しで
#   成功した場合はそれも）のデータは DROP TABLE では消えない。残った key の一覧を
#   cleanup-hints.txt に書き出すので、消したければそれを見て手で消すこと。
#   Iceberg のテーブル（_ice_ctas / _ice_plain）は location を $OUTPUT の下に指定してあり、
#   DROP TABLE でデータも消える設計にしてある。
#
# 課金について: 作るテーブルはどれも 0〜1 行、スキャンは無い（DDL と SELECT 1 だけ）。
# Athena の最小課金（10MB 相当）× クエリ数の見込み。StartQueryExecution を呼んだ回数は
# summary.txt の冒頭に実測値で出す（trap で発動する後始末のベストエフォート呼び出しは
# 数えない。数えていない理由は summary.txt に書く）。
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く。前の回の結果と混ざらない。
#
# S3 からの取得は `aws s3 cp <src> -` で標準出力に流し、リダイレクトはこのシェルが行う。
# aws が Docker のラッパだと、コンテナにマウントされるのは実行時のカレントディレクトリだけで、
# 絶対パスを渡すとコンテナの中に書かれて消える。しかも終了コードは 0 になる。
#
# #35 から変えたところ（この issue のために足したもの）:
#   - 結果本体（<id>.txt / <id>.csv）の中身を全項目で取得して保存する。
#     <label>.body.bytes（そのまま）と <label>.body.od.txt（16 進）を残す。
#     0 バイトなら 0 バイトのファイルが残る。#35 はバイト数と Content-Type しか見ておらず、
#     Iceberg の DROP TABLE が残す 1 バイトの正体を確かめられなかった。
#   - summary.tsv に body_shape 列を足した。本体の中身そのものは実名が混じりうるので
#     summary には出さず、empty / newline-only / printable-<n>B / other の「形」だけを出す
#     （1 バイトが改行かどうかはこれで読み取れる）。
#   - 素の CREATE TABLE（CTAS でない）2 本を新設し、SHOW CREATE TABLE で裏取りする。
#   - テーブルの形式と無関係な DDL（CREATE/DROP DATABASE）を対照として追加した。
#
# 文ごとに次を保存する（取れたものだけ）。
#   <label>.sql                投げた SQL そのもの（**DB 名を含む**）
#   <label>.start.err          StartQueryExecution の標準エラー（開始自体が失敗した証拠）
#   <label>.execution.json     GetQueryExecution の応答（OutputLocation はここから読む）
#   <label>.execution.err      GetQueryExecution の標準エラー
#   <label>.reason.txt         StateChangeReason と AthenaError（**実名を含みうる。貼る前に確認**）
#   <label>.ls.txt             本体と .metadata の有無（aws s3 ls の結果そのまま）
#   <label>.head.txt           本体と .metadata の head-object（Content-Type とバイト数の出どころ）
#   <label>.body.bytes         本体そのもの（無ければ作らない。今回追加）
#   <label>.body.od.txt        上を 16 進で見たもの（今回追加）
#   <label>.metadata.bytes     .metadata の中身そのもの（無ければ作らない）
#   <label>.metadata.od.txt    上を 16 進で見たもの（protobuf なので）
#   <label>.keys.txt           OutputLocation の周辺で <id> を含む key の一覧
#   show-create-<suffix>.txt   SHOW CREATE TABLE の本文（形式の裏取り。実名を含むので
#                               summary には出さず table_format 列に畳んだ値だけ出す）
#
# summary の決め手になる列は loc_shape（OutputLocation の末尾の形）と body_shape（本体の形）。
# バケット名・プレフィックス・クエリ ID・本体の中身そのものは出さず、実名を伏せた形だけを出す。
# table_format 列は SHOW CREATE TABLE の本文に table_type='iceberg' が（大文字小文字を無視して）
# 現れたかで iceberg / hive に畳む。どれも実名を含まないので、summary.txt はそのまま貼れる。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください}"
: "${DB:?DB にデータベース名を設定してください}"
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
OUT_DIR=${OUT_DIR:-$HOME/athena-drop-table-format-measurements}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}
PROBE_DDL=${PROBE_DDL:-1}

PREFIX=athena_local_probe_39
# 作るテーブルの接尾辞（本編のラベル a〜h と紛れないよう別の名前にする）。
TABLES="hive_ctas ice_ctas hive_plain ice_plain"
# 対照用に作って消すデータベース名。専用の接頭辞なので実在のものと衝突する見込みは低いが、
# 万一衝突しても CREATE DATABASE 自体が失敗するので、そのときは DROP DATABASE を投げない
# （下の CREATEDB_OK による gate）。
PROBE_DB="${PREFIX}_db"
# 本編で測る項目のラベル（preflight・対照・準備を除く）。
LABELS="a b c1 c2 d1 d2 e f g h"
# summary.txt の「投げた文」「失敗した項目の理由」を並べる順（実行順と同じ）。
ALL_LABELS="probe ctl-select ctl-createdb ctl-dropdb prep-h-ctas prep-i-ctas $LABELS"

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\tstatement_type\tloc_shape\tbody_bytes\tbody_content_type\tbody_shape\tmetadata_bytes\tmetadata_content_type\tkeys\ttable_format\tnote\n' > "$SUMMARY"
echo "出力先: $RUN_DIR"

# StartQueryExecution を実際に呼んだ回数（再試行も含む）。summary.txt の冒頭に出す。
# run は `id=$(start_query_retry ...)` とコマンド置換で呼ぶのでサブシェルになり、変数の
# 加算は親に伝わらない。1 回ごとにファイルへ 1 行積み、最後に行数を数える。
START_CALL_FILE="$RUN_DIR/.start-calls"
: > "$START_CALL_FILE"
# テーブル作成・データベース作成に着手したかどうか。trap での後始末に使う。
TABLES_ATTEMPTED=0
DB_ATTEMPTED=0

# 生ログの中間ファイルは、途中で止めても残らないよう trap で消す。
# テーブル作成に着手していたら、ベストエフォートで DROP も投げる
# （本編の e/f/g/h でも消すので、これは異常終了時の保険。正常終了で e〜h と
# ctl-dropdb が全部 SUCCEEDED だったときは、この保険を省いて二重に呼ばない）。
cleanup() {
  rm -f "$RUN_DIR"/.tmp-*
  if [ "$TABLES_ATTEMPTED" = 1 ]; then
    for t in $TABLES; do
      aws athena start-query-execution --region "$REGION" \
        --query-string "DROP TABLE IF EXISTS $DB.${PREFIX}_$t" \
        --query-execution-context "Catalog=$CATALOG,Database=$DB" \
        --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
    done
  fi
  if [ "$DB_ATTEMPTED" = 1 ]; then
    aws athena start-query-execution --region "$REGION" \
      --query-string "DROP DATABASE IF EXISTS $PROBE_DB" \
      --query-execution-context "Catalog=$CATALOG,Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# 実名（DB 名・出力先・バケット名）を置換して隠す。prep-i-ctas / b の SQL には location
# として $OUTPUT がそのまま入るので、DB 名だけでは足りない。
OUTPUT_BUCKET=${OUTPUT#s3://}
OUTPUT_BUCKET=${OUTPUT_BUCKET%%/*}
redact() {
  local s=$1
  s=${s//$DB/<DB>}
  s=${s//$OUTPUT/<OUTPUT>}
  s=${s//$OUTPUT_BUCKET/<BUCKET>}
  printf '%s' "$s"
}

# 制御文字を落として短くする。note に入れる前に必ず通す。
sanitize() {
  printf '%s' "$1" | tr '\t\n\r' '   ' | cut -c1-300
}

# stderr ファイルの 1 行目を、実名を隠して短く返す。ファイルが無ければ定型文を返す。
first_err_line() {
  local f=$1 line
  if [ -s "$f" ]; then
    line=$(head -1 "$f")
    sanitize "$(redact "$line")"
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

# S3 のオブジェクトを手元のファイルに取る。書き込むのはこのシェル。
fetch() {
  local src=$1 dest=$2 err=$3
  if aws s3 cp "$src" - > "$dest" 2> "$err"; then
    [ -s "$dest" ] || [ ! -s "$err" ]
  else
    rm -f "$dest"
    return 1
  fi
}

# s3://bucket/key の URI から ContentLength と ContentType をタブ区切りで返す。
# 取れなければ "-\t-"。本体が置かれたかどうかの判定にも使う（無ければ 404）。
head_object() {
  local uri=$1 rest bucket key out
  rest=${uri#s3://}
  bucket=${rest%%/*}
  key=${rest#*/}
  if [ "$bucket" = "$rest" ] || [ -z "$key" ]; then
    printf -- '-\t-'
    return
  fi
  out=$(aws s3api head-object --region "$REGION" --bucket "$bucket" --key "$key" \
    --query '[ContentLength,ContentType]' --output text 2>/dev/null)
  if [ -n "${out:-}" ]; then
    printf '%s' "$out"
  else
    printf -- '-\t-'
  fi
}

# execution.json から StateChangeReason と AthenaError を取り出してファイルに書く。
# 実名を含みうるので、summary には使わずファイルにだけ残す。
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

# AthenaError の ErrorCategory / ErrorType（数値コードだけ。実名を含まない）を返す。
error_codes_of() {
  python3 -c 'import json, sys
try:
    err = json.load(open(sys.argv[1]))["QueryExecution"]["Status"].get("AthenaError")
except Exception:
    err = None
print("-" if err is None else "cat=%s,type=%s" % (err.get("ErrorCategory", "-"), err.get("ErrorType", "-")))' "$1"
}

# execution.json から StatementType と OutputLocation をタブ区切りで返す。
read_execution_fields() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception:
    print("-\t")
    sys.exit(0)
print("%s\t%s" % (d.get("StatementType") or "-", d.get("ResultConfiguration", {}).get("OutputLocation", "")))' "$1"
}

# OutputLocation の末尾の「形」だけを返す。バケット名・プレフィックス・クエリ ID は出さない。
loc_shape_of() {
  local loc=$1 id=$2
  [ -n "$loc" ] || { echo "-"; return; }
  case "$loc" in
    */tables/"$id") echo 'tables/<id>' ;;
    *"/$id") echo '<id>' ;;
    *"/$id.csv") echo '<id>.csv' ;;
    *"/$id.txt") echo '<id>.txt' ;;
    *"$id"*) echo 'other(id を含む)' ;;
    *) echo 'other(id を含まない)' ;;
  esac
}

# 本体バイト列の「形」だけを返す。中身そのものは summary に出さない
# （measurement.md 要件 6: 実名や実値のリテラルを summary に埋め込まない）。
# empty          0 バイト
# newline-only   1 バイトで、その 1 バイトが 0x0a（改行）
# printable-<n>B 全バイトが印字可能 ASCII か \t\n\r（1 バイトなら中身は改行以外の 1 文字）
# other          上のどれでもない（バイナリなど）
body_shape_of() {
  python3 -c 'import sys
data = open(sys.argv[1], "rb").read()
n = len(data)
if n == 0:
    print("empty")
elif data == b"\n":
    print("newline-only")
elif all(32 <= b <= 126 or b in (9, 10, 13) for b in data):
    print("printable-%dB" % n)
else:
    print("other")' "$1"
}

# OutputLocation の周辺を一覧し、<id> を含む key を全部書き出す。件数を返す（標準出力）。
list_keys() {
  local label=$1 id=$2 loc=$3
  local parent="${loc%/*}/"
  local raw="$RUN_DIR/$label.ls.raw.txt"
  local paths="$OUTPUT" p rel
  [ "$parent" != "$OUTPUT" ] && paths="$paths $parent"
  paths="$paths $loc/"
  : > "$raw"
  # 起点・その親・その下の 3 階層を見る。key には起点からの相対プレフィックスを
  # 付けてから raw に積む。付けないと、どの階層で見つかった key かが summary から
  # 分からない。
  for p in $paths; do
    rel=${p#"$OUTPUT"}
    { echo "# ls $p"
      aws s3 ls "$p" 2>&1 | awk -v rel="$rel" 'NF >= 4 { $NF = rel $NF } { print }'
    } >> "$raw" 2>&1
  done
  # `# ls <パス>` の見出しと stderr の行にはバケット名が入り、しかも <id> を含むので
  # grep に引っかかる。そのまま残すと件数が狂い、summary.txt に実名が漏れる。
  grep -F -- "$id" "$raw" 2>/dev/null | grep -vE '^(#|[a-z_]+ error|An error)' \
    > "$RUN_DIR/$label.keys.txt"
  wc -l < "$RUN_DIR/$label.keys.txt" | tr -d ' '
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

# StartQueryExecution を投げる。名前解決・接続系の失敗だけを RETRY_MAX 回まで再試行する
# （実際の SQL エラーは 1 回で確定させる）。試行回数は呼び出し側が read_attempts で読む
# （この関数はコマンド置換で呼ばれるので、変数に入れても親には伝わらない）。
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

# 項目を未測定として summary に 1 行残す。全体を止めずに次へ進む。
skip() {
  local label=$1 note=$2
  echo "== $label: 未測定（$note）"
  printf '%s\tSKIPPED\t-\t-\t-\t-\t-\t-\t-\t-\t-\t%s\n' "$label" "$(sanitize "$note")" >> "$SUMMARY"
}

# ラベルを指定して 1 文を実行し、終端状態まで待って OutputLocation の形などを採取する。
# 成功したときだけ 0 を返す。失敗した文でも、本体と .metadata の有無は必ず採る。
run() {
  local label=$1 sql=$2 want_keys=${3:-}
  local id state stype loc shape note keys
  local body_bytes body_ct body_shape meta_bytes meta_ct

  printf '%s\n' "$sql" > "$RUN_DIR/$label.sql"
  id=$(start_query_retry "$label" "$sql")
  LAST_ATTEMPTS=$(read_attempts "$label")
  if [ -z "${id:-}" ]; then
    note="attempts=$LAST_ATTEMPTS; $(first_err_line "$RUN_DIR/$label.start.err")"
    echo "== $label: 開始できませんでした（試行 $LAST_ATTEMPTS 回）。$RUN_DIR/$label.start.err を見てください"
    printf '%s\tSTART_FAILED\t-\t-\t-\t-\t-\t-\t-\t-\t-\t%s\n' "$label" "$(sanitize "$note")" >> "$SUMMARY"
    return 1
  fi

  state=$(poll_until_terminal "$id")

  aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.execution.json" 2> "$RUN_DIR/$label.execution.err"
  write_reason "$RUN_DIR/$label.execution.json" "$RUN_DIR/$label.reason.txt"

  IFS=$'\t' read -r stype loc < <(read_execution_fields "$RUN_DIR/$label.execution.json")
  shape=$(loc_shape_of "$loc" "$id")
  body_bytes="-"; body_ct="-"; body_shape="-"; meta_bytes="-"; meta_ct="-"; keys="-"

  if [ -n "$loc" ]; then
    { echo "# ls $loc"; aws s3 ls "$loc"; echo "# rc=$?"
      echo "# ls $loc.metadata"; aws s3 ls "$loc.metadata"; echo "# rc=$?"
    } > "$RUN_DIR/$label.ls.txt" 2>&1

    # 本体と .metadata の有無・バイト数・Content-Type を head-object で採る。
    IFS=$'\t' read -r body_bytes body_ct < <(head_object "$loc")
    IFS=$'\t' read -r meta_bytes meta_ct < <(head_object "$loc.metadata")
    { echo "# head-object $loc"; echo "$body_bytes	$body_ct"
      echo "# head-object $loc.metadata"; echo "$meta_bytes	$meta_ct"
    } > "$RUN_DIR/$label.head.txt" 2>&1

    # 本体そのものを取る（#39 で足した項目。#35 はここを見ておらず、Iceberg の
    # DROP TABLE が残す 1 バイトの正体を確かめられなかった）。オブジェクトが
    # 無い（head-object が "-" を返した）ときは取りに行かない。
    if [ "$body_bytes" != "-" ]; then
      if fetch "$loc" "$RUN_DIR/$label.body.bytes" "$RUN_DIR/$label.body.cp.err"; then
        od -An -tx1c "$RUN_DIR/$label.body.bytes" > "$RUN_DIR/$label.body.od.txt"
        body_shape=$(body_shape_of "$RUN_DIR/$label.body.bytes")
      else
        body_shape="fetch-failed"
      fi
    fi

    if fetch "$loc.metadata" "$RUN_DIR/$label.metadata.bytes" "$RUN_DIR/$label.metadata.cp.err"; then
      od -An -tx1c "$RUN_DIR/$label.metadata.bytes" > "$RUN_DIR/$label.metadata.od.txt"
    fi
    if [ -n "$want_keys" ]; then
      keys=$(list_keys "$label" "$id" "$loc")
    fi
  fi

  note="attempts=$LAST_ATTEMPTS"
  case "$state" in
    FAILED | CANCELLED) note="$note; $(error_codes_of "$RUN_DIR/$label.execution.json")" ;;
  esac

  echo "== $label  state=$state  stype=$stype  loc_shape=$shape  body=$body_bytes($body_ct)  body_shape=$body_shape  metadata=$meta_bytes($meta_ct)  keys=$keys"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$label" "$state" "$stype" "$shape" "$body_bytes" "$body_ct" "$body_shape" \
    "$meta_bytes" "$meta_ct" "$keys" "-" "$(sanitize "$note")" >> "$SUMMARY"
  [ "$state" = SUCCEEDED ]
}

# SHOW CREATE TABLE でテーブルの形式を確かめ、fmt（hive / iceberg / unknown）を
# 標準出力に返す（呼び出し側は $(...) で受ける）。診断メッセージは stderr に出す。
# DROP される前（作った直後）にしか呼べないので、summary.tsv への書き込みは
# ここでは行わず、呼び出し側が apply_table_format で後から複数行に書き込む。
determine_table_format() {
  local suffix=$1 table_name=$2 id state loc fmt="unknown"
  id=$(start_query_retry "show-create-$suffix" "SHOW CREATE TABLE $DB.$table_name")
  if [ -n "${id:-}" ]; then
    state=$(poll_until_terminal "$id")
    aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
      > "$RUN_DIR/show-create-$suffix.execution.json" 2>/dev/null
    IFS=$'\t' read -r _ loc < <(read_execution_fields "$RUN_DIR/show-create-$suffix.execution.json")
    if [ "$state" = SUCCEEDED ] && [ -n "$loc" ] \
      && fetch "$loc" "$RUN_DIR/show-create-$suffix.txt" "$RUN_DIR/show-create-$suffix.err"; then
      if grep -qi "table_type'*=*'*iceberg" "$RUN_DIR/show-create-$suffix.txt"; then
        fmt=iceberg
      else
        fmt=hive
      fi
    fi
  fi
  echo "== $table_name: table_format=$fmt（SHOW CREATE TABLE で確認）" >&2
  printf '%s' "$fmt"
}

# labels（空白区切り）に列挙した行の table_format 列を fmt で埋める。
# SHOW CREATE TABLE は表を作った直後にしか呼べない（後で DROP すると失敗する）ので、
# 先に確かめておいた fmt を、同じテーブルに触れる行すべて（作成・ALTER・DROP）へ
# 後からまとめて書き込む。
apply_table_format() {
  local labels=$1 fmt=$2
  [ -n "$labels" ] || return 0
  python3 - "$SUMMARY" "$labels" "$fmt" <<'PYEOF'
import sys
path, labels, fmt = sys.argv[1], sys.argv[2].split(), sys.argv[3]
lines = open(path).read().splitlines()
for i, line in enumerate(lines):
    cols = line.split("\t")
    if cols and cols[0] in labels and len(cols) > 10:
        cols[10] = fmt
        lines[i] = "\t".join(cols)
open(path, "w").write("\n".join(lines) + "\n")
PYEOF
}

# --- preflight ---------------------------------------------------------------

# まず指定のデータベースが実在するかを確かめる。ついでに SHOW TABLES は
# <id>.txt の対照も兼ねる（この文が <id>.txt に出ることはこのラウンドで確かめる）。
if ! run probe "SHOW TABLES"; then
  echo
  echo "SHOW TABLES が通りませんでした。DB か CATALOG の指定が実在しません。"
  echo "理由: $RUN_DIR/probe.reason.txt"
  if run available-databases "SHOW DATABASES"; then
    echo "選べるデータベースの一覧: $RUN_DIR/available-databases.bytes"
    echo "その中の名前を DB に指定して、もう一度実行してください。"
  fi
  exit 1
fi

IFS=$'\t' read -r _ PROBE_LOC < <(read_execution_fields "$RUN_DIR/probe.execution.json")
if fetch "$PROBE_LOC" "$RUN_DIR/tables.txt" "$RUN_DIR/tables.err"; then
  if grep -qi "$PREFIX" "$RUN_DIR/tables.txt"; then
    echo
    echo "このデータベースに ${PREFIX}_* という名前のテーブルが既にあります。"
    echo "上書き・削除してしまうので、何も作らずに止まります。一覧: $RUN_DIR/tables.txt"
    exit 1
  fi
else
  echo
  echo "SHOW TABLES の結果を S3 から取れませんでした（$RUN_DIR/tables.err）。"
  echo "${PREFIX}_* が既に無いことを確かめられないので、何も作らずに止まります。"
  exit 1
fi

if [ "$PROBE_DDL" != 1 ]; then
  for label in ctl-select ctl-createdb ctl-dropdb prep-h-ctas prep-i-ctas $LABELS; do
    skip "$label" "PROBE_DDL=0 のため未測定"
  done
  echo "PROBE_DDL=0 のためテーブルを作らずに終わります。"
  exit 0
fi

# --- 対照: テーブルの形式と無関係な DDL -------------------------------------

# ctl-select: <id>.csv 8B / .metadata 73B のはず（README・#5 の既知の値）。
run ctl-select "SELECT 1 AS n"

# ctl-createdb / ctl-dropdb: DROP TABLE ではなく DROP DATABASE を対照に置く。
# 「DROP という語」自体が空ファイル・.metadata 無しを引き起こしているのか、
# テーブルの形式が効いているのかを切り分けるため。既存のデータベースを壊さないよう、
# CREATE DATABASE が失敗したら DROP DATABASE は投げない。
DB_ATTEMPTED=1
if run ctl-createdb "CREATE DATABASE $PROBE_DB"; then
  CREATEDB_OK=0
else
  CREATEDB_OK=1
fi
if [ "$CREATEDB_OK" = 0 ]; then
  run ctl-dropdb "DROP DATABASE $PROBE_DB"
  DROPDB_OK=$?
  [ "$DROPDB_OK" = 0 ] && DB_ATTEMPTED=0
else
  skip ctl-dropdb "ctl-createdb に失敗したため未測定（既存のデータベースを壊さないための安全策）"
fi

# --- 準備: CTAS で書き込み先のテーブルを作る（#35 の作り分けをそのまま使う）---

TABLES_ATTEMPTED=1

# Hive の CTAS（Athena の既定）。
run prep-h-ctas "CREATE TABLE $DB.${PREFIX}_hive_ctas AS SELECT 1 AS n, 'x' AS s" keys
PREP_H_CTAS_OK=$?

# Iceberg の CTAS。location を結果プレフィックス配下に置き、DROP でデータも消えるようにする。
run prep-i-ctas "CREATE TABLE $DB.${PREFIX}_ice_ctas WITH (table_type = 'ICEBERG', location = '${OUTPUT}tables-probe-39-ice-ctas/', is_external = false) AS SELECT 1 AS n, 'x' AS s" keys
PREP_I_CTAS_OK=$?

# 形式の裏取り（DROP の直前ではなく作った直後にしかできない）。
FMT_HIVE_CTAS=unknown
FMT_ICE_CTAS=unknown
[ "$PREP_H_CTAS_OK" = 0 ] && FMT_HIVE_CTAS=$(determine_table_format hive_ctas "${PREFIX}_hive_ctas")
[ "$PREP_I_CTAS_OK" = 0 ] && FMT_ICE_CTAS=$(determine_table_format ice_ctas "${PREFIX}_ice_ctas")

# --- 本編: a/b 素の CREATE TABLE ---------------------------------------------

# a. 争点: CTAS でない素の CREATE TABLE（Hive）。CTAS との作り方の違いで形式判定や
#    結果ファイルが変わるかを見る。
run a "CREATE TABLE $DB.${PREFIX}_hive_plain (n int)" keys
A_OK=$?

# b. 争点: CTAS でない素の CREATE TABLE（Iceberg）。location と TBLPROPERTIES を
#    明示する。
run b "CREATE TABLE $DB.${PREFIX}_ice_plain (n int) LOCATION '${OUTPUT}tables-probe-39-ice-plain/' TBLPROPERTIES ('table_type'='ICEBERG')" keys
B_OK=$?

FMT_HIVE_PLAIN=unknown
FMT_ICE_PLAIN=unknown
# TBLPROPERTIES の指定が本当に効いたかどうかは、素の CREATE TABLE で作ったテーブルも
# 必ず裏取りする（issue #39 の要求）。
[ "$A_OK" = 0 ] && FMT_HIVE_PLAIN=$(determine_table_format hive_plain "${PREFIX}_hive_plain")
[ "$B_OK" = 0 ] && FMT_ICE_PLAIN=$(determine_table_format ice_plain "${PREFIX}_ice_plain")

# --- 本編: c1/c2/d1/d2 ALTER TABLE -------------------------------------------

# c1/c2. 同じ ALTER 文を Hive / Iceberg の両形式に投げる対。
if [ "$A_OK" = 0 ]; then
  run c1 "ALTER TABLE $DB.${PREFIX}_hive_plain SET TBLPROPERTIES ('comment'='x')" keys
else
  skip c1 "hive_plain を作れなかったので未測定"
fi
if [ "$B_OK" = 0 ]; then
  run c2 "ALTER TABLE $DB.${PREFIX}_ice_plain SET TBLPROPERTIES ('comment'='x')" keys
else
  skip c2 "ice_plain を作れなかったので未測定"
fi

# d1/d2. ALTER の別の形（列追加）。
if [ "$A_OK" = 0 ]; then
  run d1 "ALTER TABLE $DB.${PREFIX}_hive_plain ADD COLUMNS (m int)" keys
else
  skip d1 "hive_plain を作れなかったので未測定"
fi
if [ "$B_OK" = 0 ]; then
  run d2 "ALTER TABLE $DB.${PREFIX}_ice_plain ADD COLUMNS (m int)" keys
else
  skip d2 "ice_plain を作れなかったので未測定"
fi

# --- 本編: e/f/g/h DROP TABLE（この issue の本題）----------------------------

ALL_DROPS_OK=1

# e. #35 の Hive の結果（0B・.metadata 無し）の再現確認。
if [ "$PREP_H_CTAS_OK" = 0 ]; then
  run e "DROP TABLE $DB.${PREFIX}_hive_ctas" keys || ALL_DROPS_OK=0
else
  skip e "hive_ctas を作れなかったので未測定"
fi

# f. #35 の Iceberg の結果（1B・41B）の再現確認 + 1 バイトの中身（この issue の核心）。
if [ "$PREP_I_CTAS_OK" = 0 ]; then
  run f "DROP TABLE $DB.${PREFIX}_ice_ctas" keys || ALL_DROPS_OK=0
else
  skip f "ice_ctas を作れなかったので未測定"
fi

# g. 作り方（CTAS か素の CREATE か）で変わるか（Hive）。
if [ "$A_OK" = 0 ]; then
  run g "DROP TABLE $DB.${PREFIX}_hive_plain" keys || ALL_DROPS_OK=0
else
  skip g "hive_plain を作れなかったので未測定"
fi

# h. 同上（Iceberg）。
if [ "$B_OK" = 0 ]; then
  run h "DROP TABLE $DB.${PREFIX}_ice_plain" keys || ALL_DROPS_OK=0
else
  skip h "ice_plain を作れなかったので未測定"
fi

# e〜h が全部 SUCCEEDED（またはそもそも作られておらず対象が無い）なら、4 テーブルとも
# もう存在しないので、trap での保険の DROP TABLE IF EXISTS は省く。1 本でも
# FAILED・TIMEOUT・開始失敗があれば保険を残す（残しても DROP TABLE IF EXISTS を
# もう一度投げるだけで、害は無い）。
if [ "$ALL_DROPS_OK" = 1 ]; then
  TABLES_ATTEMPTED=0
else
  echo "== 後始末の DROP に成功しなかったものがあります。終了時にもう一度投げます。"
  echo "   それでも消えなければ、$DB の ${PREFIX}_* を手で消してください。"
fi

# --- table_format 列を後から埋める -------------------------------------------
# SHOW CREATE TABLE は作った直後にしか呼べない（e〜h で DROP した後は失敗する）ので、
# 先に確かめておいた fmt を、同じテーブルに触れた行すべてへまとめて書き込む。

apply_table_format "prep-h-ctas e" "$FMT_HIVE_CTAS"
apply_table_format "prep-i-ctas f" "$FMT_ICE_CTAS"
apply_table_format "a c1 d1 g" "$FMT_HIVE_PLAIN"
apply_table_format "b c2 d2 h" "$FMT_ICE_PLAIN"

# --- 消し残しのヒント ---------------------------------------------------------

# Hive のテーブルが $OUTPUT の下に残したデータの key を、消すためのヒントとして残す。
# バケット名・プレフィックスを含むので summary.txt には入れない。
{
  echo "# Hive のテーブル（${PREFIX}_hive_ctas。${PREFIX}_hive_plain も LOCATION 無しで"
  echo "# 成功していれば同様）のデータは DROP TABLE では消えません。"
  echo "# 下の key を見て、要らなければ手で消してください（例: aws s3 rm --recursive <パス>）。"
  for label in prep-h-ctas prep-i-ctas $LABELS; do
    echo "## $label"
    cat "$RUN_DIR/$label.keys.txt" 2>/dev/null
  done
} > "$RUN_DIR/cleanup-hints.txt"

# --- summary -----------------------------------------------------------------

write_summary_txt() {
  local txt="$RUN_DIR/summary.txt"
  {
    echo "# issue #39: DROP TABLE の結果ファイルがテーブルの形式で違う件の実測"
    echo "# 実行日時: $(date -Iseconds)"
    echo "# StartQueryExecution を呼んだ回数（一時的な失敗の再試行込み）: $(wc -l < "$START_CALL_FILE" | tr -d ' ')"
    echo "#   ※ GetQueryExecution / S3 への呼び出しはこの回数に含めない（課金には影響しない）。"
    echo "#   ※ trap で発動する後始末（ベストエフォートの DROP TABLE/DATABASE IF EXISTS）も"
    echo "#     この回数に含めない。正常終了で全部 SUCCEEDED していれば trap は何も呼ばない。"
    echo "# DDL: あり。作成: ${PREFIX}_hive_ctas（CTAS, Hive）/ _ice_ctas（CTAS, Iceberg）/"
    echo "#       _hive_plain（素の CREATE TABLE）/ _ice_plain（素の CREATE TABLE, Iceberg）"
    echo "#       の4テーブルと ${PREFIX}_db の1データベース。ALTER TABLE を4回、最後に全部 DROP。"
    echo "# 課金: 作るテーブルはどれも 0〜1 行、スキャンは無い（DDL と SELECT 1 だけ）。"
    echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
    echo "#       また、ワークグループの設定はコンソールで変更済みかもしれず、工場出荷時の既定とは限らない。"
    echo
    echo "## 投げた文（DB 名・出力先は <DB> / <OUTPUT> に置換）"
    for label in $ALL_LABELS; do
      [ -s "$RUN_DIR/$label.sql" ] && echo "- $label: $(sanitize "$(redact "$(cat "$RUN_DIR/$label.sql")")")"
    done
    echo
    echo "## 項目ごとの結果"
    echo "#   loc_shape     OutputLocation の末尾の形（決め手の値の1つ）"
    echo "#   body_*        結果本体そのもの（- なら置かれていない）"
    echo "#   body_shape    本体バイト列の形だけ（empty / newline-only / printable-<n>B / other）"
    echo "#                 1 バイトの中身はここで読み取れる（もう1つの決め手の値）"
    echo "#   metadata_*    付随ファイル <OutputLocation>.metadata（- なら置かれていない）"
    echo "#   keys          OutputLocation の周辺で <id> を含む key の件数"
    echo "#   table_format  SHOW CREATE TABLE で見た実際のテーブル形式（該当するテーブルに"
    echo "#                 触れる行だけ。unknown はテーブルを作れなかったため未確認）"
    python3 - "$SUMMARY" <<'PYEOF'
import csv, sys
with open(sys.argv[1], newline="") as f:
    for row in csv.DictReader(f, delimiter="\t"):
        print(
            "- {label}: state={state} statement_type={statement_type} loc_shape={loc_shape} "
            "body={body_bytes}B/{body_content_type} body_shape={body_shape} "
            "metadata={metadata_bytes}B/{metadata_content_type} "
            "keys={keys} table_format={table_format} note={note}".format(**row)
        )
PYEOF
    echo
    echo "## <id> を含む key の形（実名は伏せ、<id> と末尾だけを出す）"
    python3 - "$RUN_DIR" "prep-h-ctas prep-i-ctas $LABELS" "$OUTPUT_BUCKET" <<'PYEOF'
import json, os, sys
run_dir, labels, bucket = sys.argv[1], sys.argv[2].split(), sys.argv[3]
for label in labels:
    keys_path = os.path.join(run_dir, "%s.keys.txt" % label)
    exec_path = os.path.join(run_dir, "%s.execution.json" % label)
    if not os.path.exists(keys_path):
        continue
    try:
        qid = json.load(open(exec_path))["QueryExecution"]["QueryExecutionId"]
    except Exception:
        qid = None
    shapes = []
    for line in open(keys_path):
        if line.startswith("#"):
            continue
        # `aws s3 ls` の行は "日付 時刻 サイズ key" か "PRE prefix/"。末尾の名前だけを見る。
        name = line.split()[-1] if line.split() else ""
        if qid:
            name = name.replace(qid, "<id>")
        if bucket:
            name = name.replace(bucket, "<BUCKET>")
        if name and name not in shapes:
            shapes.append(name)
    print("- %s: %s" % (label, ", ".join(shapes) if shapes else "(なし)"))
PYEOF
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
echo "消し残しのヒント: $RUN_DIR/cleanup-hints.txt（バケット名を含むので貼らないこと）"
echo "中身のファイルは $RUN_DIR にあります。リポジトリには入れないでください。"
echo "<label>.sql と <label>.reason.txt はデータベース名を含むので、"
echo "<label>.body.bytes / <label>.metadata.bytes は本体・付随ファイルの中身そのものなので、"
echo "summary.txt 以外を貼るときは中身を確かめてください。"
