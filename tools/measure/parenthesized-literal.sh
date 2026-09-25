#!/usr/bin/env bash
# issue #205 で作成
# 本物の Athena で、括弧付きのリテラルを含む SELECT（`SELECT (1)`、`SELECT ((1))`、
# `SELECT (1) AS x` など）について、結果ファイル本体と `.metadata` の Content-Type
# （`binary/octet-stream` か `application/octet-stream` か）と、`.metadata` の先頭
# （protobuf の field 1）が QueryExecutionId か、エンジンのクエリ ID か、を実測する。
# athena-local の `src/content_type.rs` の `is_literal_only_select`（リテラルだけの SELECT を
# binary にする規則）を本物に揃えるための実測。
#
# 背景: #200 の実測で `SELECT (1)` が `SELECT 1` と同じく binary・QueryExecutionId だった
# （`SELECT 1 + 1` は application・エンジンの ID）。括弧の入れ子・別名・符号・型の違う
# リテラル・複数列・式や NULL や行値を括弧に入れた形のどこまでが binary になるかを、
# 対照（k1〜k3）と同じラウンドで測る。符号の変種（s1〜s4）は、Trino のパーサが単項マイナスを
# 数値リテラルに畳むので、空白や括弧を挟んでも binary になるかを見る。
#
# tools/measure/keyword-boundary.sh（#200）を雛形にしている（redact・mask_names・sanitize・
# is_transient_error・start_query_retry・fetch・head_object・emit_row・skip・loc_shape_of・
# meta_has_qid_of・preflight・trap での後始末・summary.tsv と summary.txt の 2 段はそのまま流用）。
#
# 雛形からの変更点:
#   - B 群・D 群・PROBE_DDL・fetch_gqr／analyze_gqr（GetQueryResults の詳細）・
#     update_count_field_of・TABLE（B 群の対象テーブル）を持ち込んでいない。この実測は
#     テーブルを読まず、DDL もしない。summary の列から update_count・gqr_rows・gqr_col_types を外した。
#   - preflight は SHOW TABLES の疎通だけを見る（結果の中身は読まない）。DB が実在しなければ、
#     雛形と同じく SHOW DATABASES の結果を候補一覧として残して止まる。
#   - `.metadata` の protobuf の field 1 を読み、QueryExecutionId（qid）か、エンジンのクエリ ID
#     （engine。`20260916_000544_00027_jemvf` の形）か、それ以外かを判定する列 meta_field1 を足した
#     （`meta_field1_of`）。雛形の meta_has_qid（生バイト列に QueryExecutionId が含まれるか）も残す。
#   - mask_names は、テーブル名の代わりに QueryExecutionId（UUID）・エンジンのクエリ ID・
#     12 桁のアカウント ID を伏せる（開始できなかったときの文言や StateChangeReason に出うるため）。
#   - 項目を SKIP_LABELS で個別に飛ばせるようにした（skip() で summary に SKIPPED の行を残す）。
#   - meta_has_qid_of の一致判定を grep -q に替えた（雛形は一致 0 件のとき `[` が警告を出す）。
#   - summary.txt の「失敗した項目の理由」も redact と mask_names を通す（雛形は reason.txt をそのまま出す）。
#
# 使い方:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db bash tools/measure/parenthesized-literal.sh
#   一部の項目を飛ばすとき:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db SKIP_LABELS="n3 s4" bash tools/measure/parenthesized-literal.sh
#   （資格情報はホストのシェルで AWS_ACCESS_KEY_ID などを export してから。または ~/.aws/credentials）
#
# 必要な環境変数:
#   OUTPUT    結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける）。
#   DB        データベース名。実在するものを指定する（preflight の疎通にだけ使う）。
#
# 任意の環境変数:
#   CATALOG      既定 AwsDataCatalog
#   REGION       既定 ap-northeast-1
#   OUT_DIR      既定 ${DEV_HOST_HOME:-$HOME}/athena-parenthesized-literal-measurements（実名が入るのでリポジトリの外に出す）
#   POLL_TIMEOUT 終端状態を待つ上限（秒）。既定 180
#   RETRY_MAX    名前解決・接続など一時的な失敗を再試行する回数の上限。既定 4
#   RETRY_DELAY  再試行の間隔（秒）。既定 5
#   SKIP_LABELS  飛ばす項目のラベルを空白区切りで（例 "n3 s4"）。既定は空（全部流す）。
#
# 課金について: どの項目もテーブルのスキャンが無い計算クエリ（FROM 無しの SELECT）だけで、
# DDL は無い（テーブル・ビューを作らず、消しもしない）。preflight の SHOW TABLES も
# メタデータの参照だけ。Athena の最小課金 × クエリ数の見込み。
# 本物への呼び出し回数の見込み（StartQueryExecution。GetQueryExecution・S3 への呼び出しは
# 含めない）:
#   preflight 1 + 対照 3（k1〜k3）+ 括弧付きのリテラル 15（p1〜p15）+ 式・NULL・行 5（n1〜n5）
#   + 符号の変種 4（s1〜s4）= 28 本（再試行があれば前後する。SKIP_LABELS で飛ばした分は減る）。
#   DB が実在しないときは preflight 1 + SHOW DATABASES 1 = 2 本で止まる。
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く。前の回の結果と混ざらない。
#
# S3 からの取得は `aws s3 cp <src> -` で標準出力に流し、リダイレクトはこのシェルが行う。
# aws が Docker のラッパだと、コンテナにマウントされるのは実行時のカレントディレクトリだけで、
# 絶対パスを渡すとコンテナの中に書かれて消える。しかも終了コードは 0 になる。
#
# 項目ごとに次を保存する（取れたものだけ）。
#   <label>.sql                投げた SQL そのもの（DB 名・テーブル名は含まない）
#   <label>.start.err          StartQueryExecution の標準エラー（受け付けなかった証拠）
#   <label>.execution.json     GetQueryExecution の生の応答（**実名を含む。貼らないこと**）
#   <label>.execution.err      GetQueryExecution の標準エラー
#   <label>.reason.txt         StateChangeReason と AthenaError（**実名を含みうる。貼る前に確認**）
#   <label>.ls.txt             本体と .metadata の有無（aws s3 ls の結果そのまま）
#   <label>.head.txt           本体と .metadata の head-object（Content-Type とバイト数の出どころ）
#   <label>.metadata.bytes     .metadata の中身そのもの（無ければ作らない）
#   <label>.metadata.od.txt    上を 16 進で見たもの（protobuf なので）
#   <label>.metadata.cp.err    .metadata の取得の標準エラー
#   available-databases.txt    preflight が失敗したときだけ。選べるデータベースの一覧
#   summary.tsv / summary.txt  項目ごとの結果（実名は畳んである。summary.txt はそのまま貼れる）
#
# summary の決め手になる列は state・statement_type/substatement_type・loc_shape・
# body_*・meta_*・meta_has_qid・meta_field1。バケット名・プレフィックス・クエリ ID・DB 名・
# アカウント ID は出さず、OutputLocation は `<OUTPUT><id>`／`<OUTPUT><id>.csv`／
# `<OUTPUT><id>.txt`／`<OUTPUT>tables/<id>`／other のどれかに畳む。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください}"
: "${DB:?DB にデータベース名を設定してください}"
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_DIR=${OUT_DIR:-${DEV_HOST_HOME:-$HOME}/athena-parenthesized-literal-measurements}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}
SKIP_LABELS=${SKIP_LABELS:-}

K_LABELS="k1 k2 k3"
P_LABELS="p1 p2 p3 p4 p5 p6 p7 p8 p9 p10 p11 p12 p13 p14 p15"
N_LABELS="n1 n2 n3 n4 n5"
S_LABELS="s1 s2 s3 s4"
ALL_LABELS="$K_LABELS $P_LABELS $N_LABELS $S_LABELS"

# SKIP_LABELS に知らないラベルがあれば、打ち間違いとみて何も投げずに止まる。
for label in $SKIP_LABELS; do
  case " $ALL_LABELS " in
    *" $label "*) ;;
    *)
      echo "SKIP_LABELS に知らないラベルがあります: $label（使えるのは $ALL_LABELS）" >&2
      exit 1
      ;;
  esac
done

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\tstatement_type\tsubstatement_type\tloc_shape\tbody_bytes\tbody_content_type\tmeta_bytes\tmeta_content_type\tmeta_has_qid\tmeta_field1\treason_line\tnote\n' > "$SUMMARY"
echo "出力先: $RUN_DIR"

# StartQueryExecution を実際に呼んだ回数（再試行も含む）。summary.txt の冒頭に出す。
START_CALL_FILE="$RUN_DIR/.start-calls"
: > "$START_CALL_FILE"

# 生ログの中間ファイルは、途中で止めても残らないよう trap で消す。
# この実測は DDL をしないので、本物の側に後始末するものは無い。
cleanup() {
  rm -f "$RUN_DIR"/.tmp-*
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

# 標準入力から、エンジンのクエリ ID・QueryExecutionId（UUID）・12 桁のアカウント ID を
# 置換して隠す。summary に流し込む文言・エラー文言に使う。UUID の末尾 12 桁が数字だけの
# こともあるので、アカウント ID より先に UUID を畳む。
mask_names() {
  sed -E \
    -e 's/[0-9]{8}_[0-9]{6}_[0-9]{5}_[a-z0-9]{5}/<ENGINE_ID>/g' \
    -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/<QID>/g' \
    -e 's/(^|[^0-9])[0-9]{12}([^0-9]|$)/\1<ACCOUNT>\2/g'
}

# 制御文字を落として短くする。note に入れる前に必ず通す。
sanitize() {
  printf '%s' "$1" | tr '\t\n\r' '   ' | cut -c1-300
}

# stderr ファイルの 1 行目を、実名を隠して短く返す。ファイルが無ければ定型文を返す。
first_err_line() {
  local f=$1 line
  if [ -s "$f" ]; then
    line=$(grep -m1 . "$f")
    sanitize "$(redact "$line" | mask_names)"
  else
    echo "(エラー出力なし)"
  fi
}

# 名前解決・接続などの一時的な失敗だけを見分ける。
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
    sanitize "$(redact "$line" | mask_names)"
  else
    echo "-"
  fi
}

error_codes_of() {
  python3 -c 'import json, sys
try:
    err = json.load(open(sys.argv[1]))["QueryExecution"]["Status"].get("AthenaError")
except Exception:
    err = None
print("-" if err is None else "cat=%s,type=%s" % (err.get("ErrorCategory", "-"), err.get("ErrorType", "-")))' "$1"
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

# .metadata の生バイト列の中に QueryExecutionId の文字列が含まれるか（grep -c 程度）。
# ファイルが無ければ "-"。carries_execution_id の実測用。
# 雛形の `grep -ac ... || echo 0` は一致 0 件のとき「0」を 2 回出して `[` が文句を言うので、
# grep -q の終了コードで分ける形に直した（結果の yes/no は雛形と同じ）。
meta_has_qid_of() {
  local bytes_file=$1 id=$2
  [ -s "$bytes_file" ] || { echo "-"; return; }
  if grep -aq -- "$id" "$bytes_file" 2>/dev/null; then echo "yes"; else echo "no"; fi
}

# .metadata を protobuf として読み、トップレベルの最初の field 1（length-delimited）の中身が
# QueryExecutionId（qid）か、エンジンのクエリ ID（engine。`20260916_000544_00027_jemvf` の形）か、
# それ以外（other(len=N)。値そのものは出さない）かを返す。field 1 が無ければ absent、
# protobuf として読めなければ unreadable（不透明な `.metadata` など）、ファイルが無ければ "-"。
meta_field1_of() {
  local bytes_file=$1 id=$2
  [ -s "$bytes_file" ] || { echo "-"; return; }
  python3 - "$bytes_file" "$id" <<'PYEOF'
import re, sys
data = open(sys.argv[1], "rb").read()
qid = sys.argv[2]
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
            varint()
        elif wire == 1:
            pos += 8
        elif wire == 2:
            length = varint()
            if pos + length > len(data):
                raise ValueError("truncated")
            if field == 1:
                found = data[pos:pos + length]
                break
            pos += length
        elif wire == 5:
            pos += 4
        else:
            raise ValueError("wire type %d" % wire)
except Exception:
    print("unreadable")
    sys.exit(0)
if found is None:
    print("absent")
    sys.exit(0)
try:
    s = found.decode("utf-8")
except UnicodeDecodeError:
    print("other(len=%d,非UTF-8)" % len(found))
    sys.exit(0)
if s == qid:
    print("qid")
elif re.fullmatch(r"[0-9]{8}_[0-9]{6}_[0-9]{5}_[a-z0-9]{5}", s):
    print("engine")
else:
    print("other(len=%d)" % len(found))
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

# OutputLocation の末尾の「形」だけを返す。バケット名・プレフィックス・クエリ ID は出さない。
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

# ラベルを指定して 1 文を実行し、終端状態まで待って各種の値を採取する。
# 成功したときだけ 0 を返す。受け付けたが実行時に FAILED / CANCELLED になった文でも、
# 値は必ず採る（どの形が本物で失敗するかも結果）。
run() {
  local label=$1 sql=$2
  local id state stype loc sub shape note reason_line
  local body_bytes body_ct meta_bytes meta_ct meta_qid meta_f1

  printf '%s\n' "$sql" > "$RUN_DIR/$label.sql"
  id=$(start_query_retry "$label" "$sql")
  LAST_ATTEMPTS=$(read_attempts "$label")
  if [ -z "${id:-}" ]; then
    note="attempts=$LAST_ATTEMPTS; $(first_err_line "$RUN_DIR/$label.start.err")"
    echo "== $label: 開始できませんでした（試行 $LAST_ATTEMPTS 回）。$RUN_DIR/$label.start.err を見てください"
    emit_row "$label" "START_FAILED" - - - - - - - - - - "$(sanitize "$note")"
    return 1
  fi

  state=$(poll_until_terminal "$id")

  aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.execution.json" 2> "$RUN_DIR/$label.execution.err"
  write_reason "$RUN_DIR/$label.execution.json" "$RUN_DIR/$label.reason.txt"
  reason_line=$(reason_first_line "$RUN_DIR/$label.execution.json")

  IFS=$'\t' read -r stype loc sub < <(read_execution_fields "$RUN_DIR/$label.execution.json")
  shape=$(loc_shape_of "$loc" "$id")
  body_bytes="-"; body_ct="-"; meta_bytes="-"; meta_ct="-"; meta_qid="-"; meta_f1="-"

  if [ -n "$loc" ]; then
    { echo "# ls $loc"; aws s3 ls "$loc"; echo "# rc=$?"
      echo "# ls $loc.metadata"; aws s3 ls "$loc.metadata"; echo "# rc=$?"
    } > "$RUN_DIR/$label.ls.txt" 2>&1

    IFS=$'\t' read -r body_bytes body_ct < <(head_object "$loc")
    IFS=$'\t' read -r meta_bytes meta_ct < <(head_object "$loc.metadata")
    { echo "# head-object $loc"; echo "$body_bytes	$body_ct"
      echo "# head-object $loc.metadata"; echo "$meta_bytes	$meta_ct"
    } > "$RUN_DIR/$label.head.txt" 2>&1

    if fetch "$loc.metadata" "$RUN_DIR/$label.metadata.bytes" "$RUN_DIR/$label.metadata.cp.err"; then
      od -tx1c "$RUN_DIR/$label.metadata.bytes" > "$RUN_DIR/$label.metadata.od.txt"
      meta_qid=$(meta_has_qid_of "$RUN_DIR/$label.metadata.bytes" "$id")
      meta_f1=$(meta_field1_of "$RUN_DIR/$label.metadata.bytes" "$id")
    fi
  fi

  note="attempts=$LAST_ATTEMPTS"
  case "$state" in
    FAILED | CANCELLED) note="$note; $(error_codes_of "$RUN_DIR/$label.execution.json")" ;;
  esac

  echo "== $label  state=$state  stype=$stype/$sub  loc_shape=$shape  body=$body_bytes($body_ct)  metadata=$meta_bytes($meta_ct)  qid=$meta_qid  field1=$meta_f1"
  emit_row "$label" "$state" "$stype" "$sub" "$shape" "$body_bytes" "$body_ct" \
    "$meta_bytes" "$meta_ct" "$meta_qid" "$meta_f1" "$reason_line" "$(sanitize "$note")"
  [ "$state" = SUCCEEDED ]
}

# SKIP_LABELS に入っていれば skip（投げていないので <label>.sql も書かない）、そうでなければ
# run する。失敗しても次の項目へ進む。
item() {
  local label=$1 sql=$2
  case " $SKIP_LABELS " in
    *" $label "*)
      skip "$label" "SKIP_LABELS で飛ばした"
      return 0
      ;;
  esac
  run "$label" "$sql" || true
}

# --- preflight ---------------------------------------------------------------
# DB と CATALOG が実在するかを SHOW TABLES で確かめる（結果の中身は読まない）。

if ! run probe-show-tables "SHOW TABLES"; then
  echo
  echo "SHOW TABLES が通りませんでした。DB か CATALOG の指定が実在しません。"
  echo "理由: $RUN_DIR/probe-show-tables.reason.txt"
  if run available-databases "SHOW DATABASES"; then
    IFS=$'\t' read -r _ DBS_LOC _ < <(read_execution_fields "$RUN_DIR/available-databases.execution.json")
    if fetch "$DBS_LOC" "$RUN_DIR/available-databases.txt" "$RUN_DIR/available-databases.fetch.err"; then
      echo "選べるデータベースの一覧: $RUN_DIR/available-databases.txt"
    fi
    echo "その中の名前を DB に指定して、もう一度実行してください。"
  fi
  exit 1
fi

# --- 対照（過去に値が分かっている形） -------------------------------------------
# k1 は過去 binary・QueryExecutionId、k2 は application・engine、k3 は #200 で binary・QueryExecutionId。

item k1 "SELECT 1"
item k2 "SELECT 1 + 1"
item k3 "SELECT (1)"

# --- 括弧付きのリテラル --------------------------------------------------------

item p1  "SELECT ((1))"
item p2  "SELECT (1), 2"
item p3  "SELECT 1, (2)"
item p4  "SELECT (1) AS x"
item p5  "SELECT (1) x"
item p6  'SELECT (1) AS "x"'
item p7  "SELECT ('a')"
item p8  "SELECT (-1)"
item p9  "SELECT -(1)"
item p10 "SELECT (1.5)"
item p11 "SELECT (1.5E0)"
item p12 "SELECT (true)"
item p13 "SELECT ( 1 )"
item p14 "SELECT (/* c */ 1)"
item p15 "SELECT ('a') AS s, (2) AS t"

# --- リテラルに近いが式・NULL・行のもの ------------------------------------------

item n1 "SELECT (1 + 1)"
item n2 "SELECT (1) + 1"
item n3 "SELECT (1, 2)"
item n4 "SELECT (NULL)"
item n5 "SELECT (CAST(1 AS BIGINT))"

# --- 符号の変種 ----------------------------------------------------------------
# Trino のパーサは単項マイナスを数値リテラルに畳むので、空白や括弧を挟んでも binary になるかを見る。

item s1 "SELECT - 1"
item s2 "SELECT +1"
item s3 "SELECT -(-1)"
item s4 "SELECT - (1)"

# --- summary -----------------------------------------------------------------

write_summary_txt() {
  local txt="$RUN_DIR/summary.txt"
  {
    echo "# issue #205: 括弧付きのリテラルを含む SELECT の Content-Type と .metadata の field 1 を実測"
    echo "# 実行日時: $(date -Iseconds)"
    echo "# 本物への呼び出し回数（StartQueryExecution。再試行込みの実測値）: $(wc -l < "$START_CALL_FILE" | tr -d ' ')"
    echo "#   ※ 見込みは preflight 1 + 項目 27 = 28 本。GetQueryExecution / S3 への呼び出しはこの回数に含めない。"
    echo "# DDL: 無し（テーブル・ビューを作らず、消しもしない）。"
    echo "# 課金: スキャンの無い計算クエリ（FROM 無しの SELECT）と preflight の SHOW TABLES だけ。"
    echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
    echo "#       また、実測値はワークグループの設定で変わりうる（設定はコンソールで変更済みかもしれず、"
    echo "#       工場出荷時の既定とは限らない）。"
    echo "# 対照の過去の値: k1 SELECT 1 = binary・QueryExecutionId、k2 SELECT 1 + 1 = application・engine、"
    echo "#                 k3 SELECT (1) = binary・QueryExecutionId（#200）。"
    if [ -n "$SKIP_LABELS" ]; then
      echo "# SKIP_LABELS: $SKIP_LABELS"
    fi
    echo
    echo "## 投げた文"
    for label in probe-show-tables $ALL_LABELS; do
      [ -s "$RUN_DIR/$label.sql" ] && echo "- $label: $(sanitize "$(redact "$(cat "$RUN_DIR/$label.sql")" | mask_names)")"
    done
    echo
    echo "## 項目ごとの結果"
    echo "#   loc_shape       OutputLocation の末尾の形"
    echo "#   body_*/meta_*   結果本体・.metadata（バイト数・Content-Type。- なら置かれていない）"
    echo "#   meta_has_qid    .metadata の中に QueryExecutionId の文字列が含まれるか（grep -c）"
    echo "#   meta_field1     .metadata の protobuf の field 1 が QueryExecutionId（qid）か、"
    echo "#                   エンジンのクエリ ID（engine）か、それ以外（other。値は出さない）か。"
    echo "#                   absent なら field 1 が無い、unreadable なら protobuf として読めない"
    echo "#   reason_line     StateChangeReason の 1 行目（無ければ -）"
    python3 - "$SUMMARY" <<'PYEOF'
import csv, sys
with open(sys.argv[1], newline="") as f:
    for row in csv.DictReader(f, delimiter="\t"):
        print(
            "- {label}: state={state} statement_type={statement_type}/{substatement_type} "
            "loc_shape={loc_shape} body={body_bytes}B/{body_content_type} "
            "meta={meta_bytes}B/{meta_content_type} meta_has_qid={meta_has_qid} "
            "meta_field1={meta_field1} reason={reason_line} note={note}".format(**row)
        )
PYEOF
    echo
    echo "## 開始できなかった項目の文言（実名は伏せる）"
    for label in probe-show-tables $ALL_LABELS; do
      if [ -s "$RUN_DIR/$label.start.err" ]; then
        echo "### $label"
        redact "$(cat "$RUN_DIR/$label.start.err")" | mask_names
        echo
      fi
    done
    echo
    echo "## 失敗した項目の理由（DB 名・出力先・クエリ ID・アカウント ID は伏せる。ほかの実名が無いか貼る前に確認すること）"
    for label in probe-show-tables $ALL_LABELS; do
      if [ -s "$RUN_DIR/$label.reason.txt" ] && ! grep -q "^State: SUCCEEDED" "$RUN_DIR/$label.reason.txt"; then
        echo "### $label"
        redact "$(cat "$RUN_DIR/$label.reason.txt")" | mask_names
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
echo "<label>.execution.json・<label>.reason.txt・<label>.ls.txt・<label>.head.txt は実名（バケット名・"
echo "DB 名・クエリ ID）を含みうるので、summary.txt 以外を貼るときは中身を確かめてください。"
