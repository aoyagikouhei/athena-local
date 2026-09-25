#!/usr/bin/env bash
# issue #199 で作成
# athena-local は `CREATE TABLE t AS (VALUES 1)` のような括弧付きのクエリを持つ CTAS で、
# 結果ファイルの置き場所を `tables/<id>`（CTAS 扱い）にし、SubstatementType を
# `CREATE_TABLE`（CTAS でない扱い）にしていて、2 つの判定が割れている（詳しくは #199 の本文）。
# 本物の Athena がこの形の CTAS をそもそも受け付けるか、受け付けるときにどちらの判定に
# 揃えるべきかを実測する。手元の Trino 482 では v1・v3（列名なしの VALUES）が
# `Column name not specified at position 1` で失敗し、v2・v4・t1・t2・c1 は通った
# （c2・c0 は Trino 側の分岐に関係しないはずだが実測はしていない）。本物でも同じかは未確認。
#
# 測りたいこと（テーブル名は <DB>.athena_local_probe_199_<項目名>。全部 Hive の既定のまま。
# WITH も LOCATION も付けない）:
#   c0  CREATE TABLE <c0> AS SELECT 1 AS n            対照（素の CTAS）。t1・t2 の読み元も兼ねる
#   c1  CREATE TABLE <c1> AS (SELECT 1 AS n)          括弧付き SELECT（athena-local は両判定とも CTAS）
#   c2  CREATE TABLE <c2> AS(SELECT 1 AS n)           括弧付き SELECT・AS と "(" の間に空白なし
#   v1  CREATE TABLE <v1> AS (VALUES 1)               issue の形そのもの。列名なし
#   v2  CREATE TABLE <v2> (n) AS (VALUES 1)           列の別名つき（v1 が列名なしで弾かれたときの比較）
#   v3  CREATE TABLE <v3> AS VALUES 1                 括弧なし VALUES（athena-local は両判定とも CTAS でない）
#   v4  CREATE TABLE <v4> (n) AS VALUES 1             括弧なし・列の別名つき
#   t1  CREATE TABLE <t1> AS (TABLE <c0>)             括弧付き TABLE
#   t2  CREATE TABLE <t2> AS TABLE <c0>               括弧なし TABLE
# c0 を最初に流し、c0 が作れなかったら t1・t2 は skip する（読み元が無いため）。
# それ以外の項目は互いに独立で、1 つが受け付けられなかったり失敗したりしても他は続ける。
# 受け付けなかった（StartQueryExecution が弾いた）場合と、受け付けたが実行時に失敗した
# （FAILED になった）場合を区別して採る。実行時に失敗しても、GetQueryExecution が返す
# SubstatementType・OutputLocation・その周辺のオブジェクト一覧は必ず採る
# （FAILED のときの値が #199 の判定そのものに効く）。
#
# 使い方:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db bash tools/measure/ctas-parenthesized-query.sh
#   （資格情報はホストのシェルで AWS_ACCESS_KEY_ID などを export してから。または ~/.aws/credentials）
#
# 必要な環境変数:
#   OUTPUT    結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける）。
#   DB        データベース名。実在するものを指定する。
#
# 任意の環境変数:
#   CATALOG      既定 AwsDataCatalog
#   REGION       既定 ap-northeast-1
#   OUT_DIR      既定 ${DEV_HOST_HOME:-$HOME}/athena-ctas-parenthesized-measurements（実名が入るのでリポジトリの外に出す）
#   POLL_TIMEOUT 終端状態を待つ上限（秒）。既定 180
#   RETRY_MAX    名前解決・接続など一時的な失敗を再試行する回数の上限。既定 4
#   RETRY_DELAY  再試行の間隔（秒）。既定 5
#   PROBE_DDL    既定 1（測る）。0 にすると全項目を skip する（この実測も DDL そのものなので何も測れない）。
#
# ** このスクリプトが本物に対して行う破壊的な操作 **
#   <db>.athena_local_probe_199_{c0,c1,c2,v1,v2,v3,v4,t1,t2} の 9 テーブルを
#   CREATE TABLE ... AS で作り（作れたものだけ）、最後に DROP TABLE IF EXISTS で消す
#   （異常終了時も trap で消しにいく）。
#   同名のテーブルが既にあると壊すので、開始前に SHOW TABLES で存在を確かめ、
#   1 件でもあればテーブルを作らずに止まる。
#   どのテーブルも WITH も LOCATION も付けない Hive の既定なので、データは Athena の既定で
#   $OUTPUT の下の tables/<id>/ 等に置かれ、DROP TABLE では消えない（外部テーブルのため）。
#   残った key の一覧を cleanup-hints.txt に書き出すので、消したければそれを見て手で消すこと。
#
# 課金について: 作るテーブルはどれも 1 行で、実テーブルのスキャンは無い（t1・t2 も
# c0 の 1 行を読むだけ）。Athena の最小課金（10MB 相当）× クエリ数の見込み。
# StartQueryExecution を呼んだ回数は summary.txt の冒頭に実測値を出す。
# 見込み: 前段の SHOW TABLES 1 + 本編 9（c0 が失敗すると t1・t2 が skip されて 7 に減る）+
# SHOW CREATE TABLE による裏取り最大 9 + 後始末の DROP 9 ≒ 28 回程度（再試行があれば増える）。
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く。前の回の結果と混ざらない。
#
# S3 からの取得は `aws s3 cp <src> -` で標準出力に流し、リダイレクトはこのシェルが行う。
# aws が Docker のラッパだと、コンテナにマウントされるのは実行時のカレントディレクトリだけで、
# 絶対パスを渡すとコンテナの中に書かれて消える。しかも終了コードは 0 になる。
#
# 項目ごとに次を保存する（取れたものだけ）。
#   <label>.sql                投げた SQL そのもの（**DB 名を含む**）
#   <label>.start.err          StartQueryExecution の標準エラー（受け付けなかった証拠）
#   <label>.execution.json     GetQueryExecution の生の応答（OutputLocation・SubstatementType はここから読む）
#   <label>.execution.err      GetQueryExecution の標準エラー
#   <label>.reason.txt         StateChangeReason と AthenaError（**実名を含みうる。貼る前に確認**）
#   <label>.ls.txt             本体と .metadata の有無（aws s3 ls の結果そのまま）
#   <label>.head.txt           本体と .metadata の head-object（Content-Type とバイト数の出どころ）
#   <label>.metadata.bytes     .metadata の中身そのもの（無ければ作らない）
#   <label>.metadata.od.txt    上を 16 進で見たもの（protobuf なので）
#   <label>.ls.raw.txt         OutputLocation・その親・<OUTPUT><id>/・<OUTPUT>tables/<id>/ を覗いた生の一覧
#   <label>.keys.txt           上のうち <id> を含む key の一覧（件数を summary の keys 列に出す）
#   show-create-<suffix>.txt   作られたテーブルの SHOW CREATE TABLE（形式と列名の裏取り）
#
# summary の決め手になる列は state（START_FAILED なら受け付けない）・loc_shape・
# statement_type/substatement_type・table_created・columns。バケット名・プレフィックス・
# クエリ ID は出さず、`<OUTPUT>tables/<id>`／`<OUTPUT><id>`／`<OUTPUT><id>.csv`／
# `<OUTPUT><id>.txt`／other のどれかに畳む。keys 列は <id> を含む key の**件数**だけを出す。
# どれも実名を含まないので、summary.txt はそのまま貼れる（reason_line・note に文言が入る
# ときは、DB 名などの実名があれば <DB> 等に置換される）。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください}"
: "${DB:?DB にデータベース名を設定してください}"
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_DIR=${OUT_DIR:-${DEV_HOST_HOME:-$HOME}/athena-ctas-parenthesized-measurements}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}
PROBE_DDL=${PROBE_DDL:-1}

PREFIX=athena_local_probe_199
# 作るテーブル・本編で測る項目のラベル（この実測はラベルとテーブルの接尾辞が 1 対 1）。
LABELS="c0 c1 c2 v1 v2 v3 v4 t1 t2"
TABLES="c0 c1 c2 v1 v2 v3 v4 t1 t2"

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\tstatement_type\tsubstatement_type\tloc_shape\tbody_bytes\tbody_content_type\tmetadata_bytes\tmetadata_content_type\tkeys\tupdate_count\ttable_created\tcolumns\ttable_format\treason_line\tnote\n' > "$SUMMARY"
echo "出力先: $RUN_DIR"

# summary.tsv に 1 行積む。列の並びはヘッダと同じ 16 列で固定する。
emit_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$SUMMARY"
}

# StartQueryExecution を実際に呼んだ回数（再試行も含む）。summary.txt の冒頭に出す。
# run は `id=$(start_query_retry ...)` とコマンド置換で呼ぶのでサブシェルになり、変数の
# 加算は親に伝わらない。1 回ごとにファイルへ 1 行積み、最後に行数を数える。
START_CALL_FILE="$RUN_DIR/.start-calls"
: > "$START_CALL_FILE"
# テーブル作成に着手したかどうか。trap での後始末に使う。
CTAS_ATTEMPTED=0

# 生ログの中間ファイルは、途中で止めても残らないよう trap で消す。
# テーブル作成に着手していたら、ベストエフォートで DROP も投げる
# （本編の Z 群でも消すので、これは異常終了時の保険）。
cleanup() {
  rm -f "$RUN_DIR"/.tmp-*
  if [ "$CTAS_ATTEMPTED" = 1 ]; then
    for t in $TABLES; do
      aws athena start-query-execution --region "$REGION" \
        --query-string "DROP TABLE IF EXISTS $DB.${PREFIX}_$t" \
        --query-execution-context "Catalog=$CATALOG,Database=$DB" \
        --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
    done
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

# 制御文字を落として短くする。note に入れる前に必ず通す。
sanitize() {
  printf '%s' "$1" | tr '\t\n\r' '   ' | cut -c1-300
}

# stderr ファイルの 1 行目を、実名を隠して短く返す。ファイルが無ければ定型文を返す。
first_err_line() {
  local f=$1 line
  if [ -s "$f" ]; then
    # aws CLI のエラーは空行から始まるので、最初の空でない行を取る。
    line=$(grep -m1 . "$f")
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

# StateChangeReason の 1 行目だけを、実名を隠して短く返す。無ければ "-"。
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
    sanitize "$(redact "$line")"
  else
    echo "-"
  fi
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

# execution.json から StatementType と OutputLocation と SubstatementType をタブ区切りで返す。
read_execution_fields() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception:
    print("-\t\t-")
    sys.exit(0)
print("%s\t%s\t%s" % (d.get("StatementType") or "-", d.get("ResultConfiguration", {}).get("OutputLocation", ""), d.get("SubstatementType") or "-"))' "$1"
}

# .metadata の先頭を protobuf として読み、トップレベルの field 3（varint。DML の更新件数）を返す。
# 無ければ absent。壊れていて読めなければ unreadable。実名を含まない（数値だけ）。
# field 1（クエリ ID）と field 2（updateType）は長さ付きなので読み飛ばす。
update_count_field_of() {
  python3 - "$1" <<'PYEOF'
import sys
try:
    data = open(sys.argv[1], "rb").read()
except Exception:
    print("-")
    sys.exit(0)
pos = 0
def varint():
    global pos
    shift = value = 0
    while True:
        b = data[pos]
        pos += 1
        value |= (b & 0x7F) << shift
        shift += 7
        if not b & 0x80:
            return value
found = None
try:
    while pos < len(data):
        tag = varint()
        field, wire = tag >> 3, tag & 7
        if wire == 0:
            v = varint()
            if field == 3:
                found = v
                break
        elif wire == 2:
            # `pos += varint()` は左辺の pos を先に読むので、長さの読み取りで進んだ分が消える。
            length = varint()
            pos += length
        else:
            print("unreadable")
            sys.exit(0)
except Exception:
    print("unreadable")
    sys.exit(0)
print("absent" if found is None else str(found))
PYEOF
}

# OutputLocation の末尾の「形」だけを返す。バケット名・プレフィックス・クエリ ID は出さない。
# これがこの実測の決め手の値の 1 つになる（athena-local の 2 つの判定のうち置き場所側）。
loc_shape_of() {
  local loc=$1 id=$2
  [ -n "$loc" ] || { echo "-"; return; }
  case "$loc" in
    */tables/"$id") echo '<OUTPUT>tables/<id>' ;;
    *"/$id") echo '<OUTPUT><id>' ;;
    *"/$id.csv") echo '<OUTPUT><id>.csv' ;;
    *"/$id.txt") echo '<OUTPUT><id>.txt' ;;
    *"$id"*) echo 'other(id を含む)' ;;
    *) echo 'other(id を含まない)' ;;
  esac
}

# OutputLocation の周辺を一覧し、<id> を含む key を全部書き出す。件数を返す（標準出力）。
# この実測の争点そのもの: `<OUTPUT><id>/` と `<OUTPUT>tables/<id>/` の 2 つの候補は、
# OutputLocation が実際にどちらの形でも必ず覗く（重複しても aws s3 ls が空を返すだけで害はない）。
list_keys() {
  local label=$1 id=$2 loc=$3
  local parent="${loc%/*}/"
  local raw="$RUN_DIR/$label.ls.raw.txt"
  local cand_id="${OUTPUT}${id}/"
  local cand_tables="${OUTPUT}tables/${id}/"
  local paths="$OUTPUT" p rel
  [ "$parent" != "$OUTPUT" ] && paths="$paths $parent"
  paths="$paths $loc/"
  case " $paths " in *" $cand_id "*) ;; *) paths="$paths $cand_id" ;; esac
  case " $paths " in *" $cand_tables "*) ;; *) paths="$paths $cand_tables" ;; esac
  : > "$raw"
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

# SHOW CREATE TABLE の本文から列名だけを抜き出す（型・COMMENT は捨てる）。
# WITH 句が無い定義への保険として、無ければ最後の ")" までを列定義とみなす。
extract_columns() {
  python3 - "$1" <<'PYEOF'
import re, sys
try:
    text = open(sys.argv[1]).read()
except Exception:
    print("-")
    sys.exit(0)
m = re.search(r"\(\s*\n(.*?)\n\)\s*\nWITH", text, re.S)
if not m:
    m = re.search(r"\(\s*\n(.*?)\n\)\s*$", text, re.S)
if not m:
    print("-")
    sys.exit(0)
cols = []
for line in m.group(1).splitlines():
    line = line.strip().rstrip(",")
    if not line:
        continue
    tok = line.split()[0].strip('"')
    cols.append(tok)
print(";".join(cols) if cols else "-")
PYEOF
}

# summary.tsv の table_created・columns・table_format の 3 列（0-index で 11, 12, 13）だけを
# label で引いて上書きする。record_table_info からだけ呼ぶ。
patch_summary_cols() {
  local row_label=$1 created=$2 cols=$3 fmt=$4
  python3 - "$SUMMARY" "$row_label" "$created" "$cols" "$fmt" <<'PYEOF'
import sys
path, label, created, cols, fmt = sys.argv[1:6]
lines = open(path).read().splitlines()
for i, line in enumerate(lines):
    c = line.split("\t")
    if c and c[0] == label and len(c) >= 14:
        c[11] = created
        c[12] = cols
        c[13] = fmt
        lines[i] = "\t".join(c)
open(path, "w").write("\n".join(lines) + "\n")
PYEOF
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
  emit_row "$label" "SKIPPED" - - - - - - - - - - - - - "$(sanitize "$note")"
}

# ラベルを指定して 1 文を実行し、終端状態まで待って OutputLocation の形などを採取する。
# 成功したときだけ 0 を返す。受け付けたが実行時に FAILED / CANCELLED になった文でも、
# GetQueryExecution が返す StatementType・SubstatementType・OutputLocation と、
# 本体・.metadata の有無・その周辺のオブジェクト一覧は必ず採る（FAILED のときの値が
# #199 の判定そのものに効く）。
run() {
  local label=$1 sql=$2 want_keys=${3:-}
  local id state stype loc sub shape note keys reason_line
  local body_bytes body_ct meta_bytes meta_ct update_count

  printf '%s\n' "$sql" > "$RUN_DIR/$label.sql"
  id=$(start_query_retry "$label" "$sql")
  LAST_ATTEMPTS=$(read_attempts "$label")
  if [ -z "${id:-}" ]; then
    note="attempts=$LAST_ATTEMPTS; $(first_err_line "$RUN_DIR/$label.start.err")"
    echo "== $label: 開始できませんでした（試行 $LAST_ATTEMPTS 回）。$RUN_DIR/$label.start.err を見てください"
    emit_row "$label" "START_FAILED" - - - - - - - - - - - - - "$(sanitize "$note")"
    return 1
  fi

  state=$(poll_until_terminal "$id")

  aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.execution.json" 2> "$RUN_DIR/$label.execution.err"
  write_reason "$RUN_DIR/$label.execution.json" "$RUN_DIR/$label.reason.txt"
  reason_line=$(reason_first_line "$RUN_DIR/$label.execution.json")

  IFS=$'\t' read -r stype loc sub < <(read_execution_fields "$RUN_DIR/$label.execution.json")
  shape=$(loc_shape_of "$loc" "$id")
  body_bytes="-"; body_ct="-"; meta_bytes="-"; meta_ct="-"; keys="-"; update_count="-"

  # loc が空でない限り、state が FAILED / CANCELLED でも採る（下の注参照）。
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

    if fetch "$loc.metadata" "$RUN_DIR/$label.metadata.bytes" "$RUN_DIR/$label.metadata.cp.err"; then
      od -tx1c "$RUN_DIR/$label.metadata.bytes" > "$RUN_DIR/$label.metadata.od.txt"
      update_count=$(update_count_field_of "$RUN_DIR/$label.metadata.bytes")
    fi
    if [ -n "$want_keys" ]; then
      keys=$(list_keys "$label" "$id" "$loc")
    fi
  fi

  note="attempts=$LAST_ATTEMPTS"
  case "$state" in
    FAILED | CANCELLED) note="$note; $(error_codes_of "$RUN_DIR/$label.execution.json")" ;;
  esac

  echo "== $label  state=$state  stype=$stype/$sub  loc_shape=$shape  body=$body_bytes($body_ct)  metadata=$meta_bytes($meta_ct)  keys=$keys  update_count=$update_count"
  # 列の並び: label state statement_type substatement_type loc_shape body_bytes body_content_type
  #           metadata_bytes metadata_content_type keys update_count table_created columns
  #           table_format reason_line note （table_created/columns/table_format は record_table_info が後で埋める）
  emit_row "$label" "$state" "$stype" "$sub" "$shape" "$body_bytes" "$body_ct" \
    "$meta_bytes" "$meta_ct" "$keys" "$update_count" - - - "$reason_line" "$(sanitize "$note")"
  [ "$state" = SUCCEEDED ]
}

# 作られたテーブルが本当に存在するかを SHOW CREATE TABLE で裏取りし、列名と実際の形式を
# summary.tsv の table_created・columns・table_format 列に足す。存在しなければ table_created=no。
record_table_info() {
  local suffix=$1 row_label=$2 id state loc created="no" fmt="unknown" cols="-"
  id=$(start_query_retry "show-create-$suffix" "SHOW CREATE TABLE $DB.${PREFIX}_$suffix")
  if [ -n "${id:-}" ]; then
    state=$(poll_until_terminal "$id")
    aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
      > "$RUN_DIR/show-create-$suffix.execution.json" 2>/dev/null
    IFS=$'\t' read -r _ loc _ < <(read_execution_fields "$RUN_DIR/show-create-$suffix.execution.json")
    if [ "$state" = SUCCEEDED ] && [ -n "$loc" ] \
      && fetch "$loc" "$RUN_DIR/show-create-$suffix.txt" "$RUN_DIR/show-create-$suffix.err"; then
      created="yes"
      if grep -qi "table_type'*=*'*iceberg" "$RUN_DIR/show-create-$suffix.txt"; then
        fmt=iceberg
      else
        fmt=hive
      fi
      cols=$(extract_columns "$RUN_DIR/show-create-$suffix.txt")
    fi
  fi
  patch_summary_cols "$row_label" "$created" "$cols" "$fmt"
  echo "== ${PREFIX}_$suffix: created=$created columns=$cols table_format=$fmt（SHOW CREATE TABLE で確認）"
}

# --- preflight ---------------------------------------------------------------

# まず指定のデータベースが実在するかを確かめる。
if ! run probe-show-tables "SHOW TABLES"; then
  echo
  echo "SHOW TABLES が通りませんでした。DB か CATALOG の指定が実在しません。"
  echo "理由: $RUN_DIR/probe-show-tables.reason.txt"
  if run available-databases "SHOW DATABASES"; then
    echo "選べるデータベースの一覧: $RUN_DIR/available-databases.bytes"
    echo "その中の名前を DB に指定して、もう一度実行してください。"
  fi
  exit 1
fi

IFS=$'\t' read -r _ SHOW_TABLES_LOC _ < <(read_execution_fields "$RUN_DIR/probe-show-tables.execution.json")
if fetch "$SHOW_TABLES_LOC" "$RUN_DIR/tables.txt" "$RUN_DIR/tables.err"; then
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
  for label in $LABELS; do
    skip "$label" "PROBE_DDL=0 のため未測定（この実測も DDL そのものなので、何も測れない）"
  done
  echo "PROBE_DDL=0 のためテーブルを作らずに終わります。"
  exit 0
fi

# --- 本編 --------------------------------------------------------------------

CTAS_ATTEMPTED=1

# c0. 対照: 素の CTAS。t1・t2 の読み元も兼ねる。
run c0 "CREATE TABLE $DB.${PREFIX}_c0 AS SELECT 1 AS n" keys
C0_OK=$?

# c1. 括弧付き SELECT。athena-local は結果の置き場所（tables/<id>）と
#     SubstatementType（CREATE_TABLE）の両方の判定で CTAS 扱いのはず。
run c1 "CREATE TABLE $DB.${PREFIX}_c1 AS (SELECT 1 AS n)" keys

# c2. c1 と同じ括弧付き SELECT だが、AS と "(" の間に空白が無い（字句境界の判定に効く）。
run c2 "CREATE TABLE $DB.${PREFIX}_c2 AS(SELECT 1 AS n)" keys

# v1. issue #199 の形そのもの。列名なし（VALUES の列名が何になるかも見る）。
run v1 "CREATE TABLE $DB.${PREFIX}_v1 AS (VALUES 1)" keys

# v2. 列の別名つき。v1 が列名なしで弾かれたときの比較に使う。
run v2 "CREATE TABLE $DB.${PREFIX}_v2 (n) AS (VALUES 1)" keys

# v3. 括弧なし VALUES。athena-local は置き場所・SubstatementType のどちらも CTAS でない扱いのはず。
run v3 "CREATE TABLE $DB.${PREFIX}_v3 AS VALUES 1" keys

# v4. 括弧なし・列の別名つき。
run v4 "CREATE TABLE $DB.${PREFIX}_v4 (n) AS VALUES 1" keys

# t1 / t2. 括弧の有無だけが違う TABLE 構文。c0 が読み元なので、c0 が作れなかったら測れない。
if [ "$C0_OK" = 0 ]; then
  run t1 "CREATE TABLE $DB.${PREFIX}_t1 AS (TABLE $DB.${PREFIX}_c0)" keys
  run t2 "CREATE TABLE $DB.${PREFIX}_t2 AS TABLE $DB.${PREFIX}_c0" keys
else
  skip t1 "c0 が作れなかったので未測定（読み元のテーブルが無い）"
  skip t2 "c0 が作れなかったので未測定（読み元のテーブルが無い）"
fi

# 作られたテーブルを SHOW CREATE TABLE で裏取りし、列名と実際の形式を summary に足す。
for suffix in c0 c1 c2 v1 v2 v3 v4; do
  record_table_info "$suffix" "$suffix"
done
if [ "$C0_OK" = 0 ]; then
  record_table_info t1 t1
  record_table_info t2 t2
fi

# --- 後始末 ------------------------------------------------------------------

DROP_ALL_OK=1
for t in $TABLES; do
  run "z-drop-$t" "DROP TABLE IF EXISTS $DB.${PREFIX}_$t" || DROP_ALL_OK=0
done

# Z 群の DROP が全部 SUCCEEDED になったときだけ、trap での二度目の DROP を省く。
# 投げたことは消えたことではないので、1 本でも FAILED・TIMEOUT・開始失敗があれば
# 保険を残す（残すと DROP TABLE IF EXISTS をもう一度投げるだけで、害は無い）。
if [ "$DROP_ALL_OK" = 1 ]; then
  CTAS_ATTEMPTED=0
else
  echo "== 後始末の DROP に成功しなかったものがあります。終了時にもう一度投げます。"
  echo "   それでも消えなければ、$DB の ${PREFIX}_* を手で消してください。"
fi

# どのテーブルも WITH/LOCATION を付けない Hive の既定なので、DROP TABLE では $OUTPUT の
# 下に残ったデータは消えない。消すためのヒントとして key を書き出す（実名を含むので
# summary.txt には入れない）。
{
  echo "# ${PREFIX}_* のデータは DROP TABLE では消えません（外部テーブルのため）。"
  echo "# 下の key を見て、要らなければ手で消してください（例: aws s3 rm --recursive <パス>）。"
  for label in $LABELS; do
    echo "## $label"
    cat "$RUN_DIR/$label.keys.txt" 2>/dev/null
  done
} > "$RUN_DIR/cleanup-hints.txt"

# --- summary -----------------------------------------------------------------

write_summary_txt() {
  local txt="$RUN_DIR/summary.txt"
  {
    echo "# issue #199: 括弧付きのクエリを持つ CTAS を本物が受け付けるかと、置き場所・SubstatementType の対応"
    echo "# 実行日時: $(date -Iseconds)"
    echo "# StartQueryExecution を呼んだ回数（一時的な失敗の再試行込み）: $(wc -l < "$START_CALL_FILE" | tr -d ' ')"
    echo "#   ※ GetQueryExecution / S3 への呼び出しはこの回数に含めない（課金には影響しない）。"
    echo "# DDL: あり（${PREFIX}_{c0,c1,c2,v1,v2,v3,v4,t1,t2} を CREATE TABLE ... AS で作成→DROP。作れたものだけ）"
    echo "# 課金: 作るテーブルはどれも 1 行、実テーブルのスキャンは無い。"
    echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
    echo "#       また、ワークグループの設定はコンソールで変更済みかもしれず、工場出荷時の既定とは限らない。"
    echo
    echo "## 投げた文（DB 名は <DB> に置換）"
    for label in probe-show-tables $LABELS; do
      [ -s "$RUN_DIR/$label.sql" ] && echo "- $label: $(sanitize "$(redact "$(cat "$RUN_DIR/$label.sql")")")"
    done
    echo
    echo "## 項目ごとの結果"
    echo "#   loc_shape          OutputLocation の末尾の形（athena-local の 2 つの判定の一方）"
    echo "#   substatement_type  GetQueryExecution の SubstatementType（athena-local の 2 つの判定のもう一方。"
    echo "#                      CTAS 扱いなら CREATE_TABLE_AS_SELECT、そうでなければ CREATE_TABLE のはず）"
    echo "#   body_*             結果本体そのもの（- なら置かれていない）"
    echo "#   metadata_*         付随ファイル <OutputLocation>.metadata（- なら置かれていない）"
    echo "#   keys               OutputLocation・<OUTPUT><id>/・<OUTPUT>tables/<id>/ の周辺で"
    echo "#                      <id> を含む key の件数"
    echo "#   table_created      SHOW CREATE TABLE で見た、テーブルが実際に作られたか"
    echo "#   columns            作られていた場合の列名（; 区切り。v1 の列名が何になるかを見る）"
    echo "#   table_format       SHOW CREATE TABLE の本文に table_type='iceberg' が現れたか（hive/iceberg/unknown）"
    echo "#   update_count       .metadata の field 3（DML の更新件数）。absent なら field 自体が無い"
    echo "#   reason_line        StateChangeReason の 1 行目（無ければ -）"
    python3 - "$SUMMARY" <<'PYEOF'
import csv, sys
with open(sys.argv[1], newline="") as f:
    for row in csv.DictReader(f, delimiter="\t"):
        print(
            "- {label}: state={state} statement_type={statement_type}/{substatement_type} "
            "loc_shape={loc_shape} body={body_bytes}B/{body_content_type} "
            "metadata={metadata_bytes}B/{metadata_content_type} keys={keys} "
            "table_created={table_created} columns={columns} table_format={table_format} "
            "update_count={update_count} reason={reason_line} note={note}".format(**row)
        )
PYEOF
    echo
    echo "## <id> を含む key の形（実名は伏せ、<id> と末尾だけを出す）"
    python3 - "$RUN_DIR" "$LABELS" "$OUTPUT_BUCKET" <<'PYEOF'
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
        # list_keys で落としきれなかった実名が混ざっても貼れるようにする。
        if bucket:
            name = name.replace(bucket, "<BUCKET>")
        if name and name not in shapes:
            shapes.append(name)
    print("- %s: %s" % (label, ", ".join(shapes) if shapes else "(なし)"))
PYEOF
    echo
    echo "## 開始できなかった項目の文言（DB 名は <DB> に置換）"
    for label in $LABELS; do
      if [ -s "$RUN_DIR/$label.start.err" ]; then
        echo "### $label"; redact "$(cat "$RUN_DIR/$label.start.err")"; echo
      fi
    done
    echo
    echo "## 失敗した項目の理由（実名を含みうるので貼る前に確認すること）"
    for label in probe-show-tables $LABELS; do
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
echo "summary.txt 以外を貼るときは中身を確かめてください。"
