#!/usr/bin/env bash
# issue #65 で作成（tools/ へ移す前の名前は 65-measure-table-statement.sh）
# 本物の Athena が `TABLE <t>`（Trino では `SELECT * FROM <t>` の短縮形）をどう扱うかを実測する。
# issue #65 のための実測スクリプト。
#
# athena-local は `TABLE` の扱いが 2 か所で食い違っている:
#   - src/results.rs の `ResultFile::of` は `TABLE` を SELECT と同列の `Csv`（`<id>.csv`、列名行あり）
#   - src/operation/classification.rs の `statement_type` は `TABLE` を DML に入れていないので UTILITY
#     （#64 以降、UTILITY は `GetQueryResults` の先頭に列名行を入れない）
# 同じクエリなのに S3 経由（JDBC の ResultFetcher=auto / S3）と API 経由で行数が 1 行ずれる。
# 本物がそもそも `TABLE t` を受け付けるのか、受け付けるなら StatementType / SubstatementType /
# 結果ファイル名 / 列名行の有無がどうなるのかを 1 ラウンドで決める。
#
# 使い方:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db TABLE=small_table bash tools/measure/table-statement.sh
#   （資格情報はホストのシェルで AWS_ACCESS_KEY_ID などを export してから。または ~/.aws/credentials）
#
# ** 課金の注意（先に読むこと） **
#   この実行は対象テーブル <T> を 6 回フルスキャンする（a, b, c, d, e, g）。
#   `TABLE` に小さなテーブルを明示して指定することを強く勧める。
#   指定しないと SHOW TABLES の 1 件目が選ばれ、それが巨大なテーブルだと高くつく。
#   DDL は一切実行しない（作成・変更・削除はしない。読み取りだけ）。
#
# 必要な環境変数:
#   OUTPUT    結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける。無ければ足す）。
#   DB        データベース名。実在するものを指定する。
#
# 任意の環境変数:
#   TABLE       対象テーブル名（<DB> の中の名前。修飾なし。二重引用符が要る名前は
#               そのままでは通らないので、引用符の要らない小さなテーブルを選ぶこと）。省略すると
#               `SHOW TABLES IN <DB>` の 1 件目を使う。1 件も無ければ a〜e・g を未測定にして
#               f（存在しないテーブル）だけを測る。
#   CATALOG     既定 AwsDataCatalog
#   REGION      既定 ap-northeast-1
#   OUT_DIR     既定 ${DEV_HOST_HOME:-$HOME}/athena-table-statement-measurements（実名が入るのでリポジトリの外に出す）
#   POLL_TIMEOUT 終端状態を待つ上限（秒）。既定 180
#   RETRY_MAX   名前解決・接続など一時的な失敗を再試行する回数の上限。既定 4
#   RETRY_DELAY 再試行の間隔（秒）。既定 5
#
# 項目（対照と変異を同じラウンドに入れる。フルスキャンする項目に ★ を付けた）:
#   a-select-plain   ★ SELECT * FROM <db>.<T>            対照。列名行と結果ファイルの形の比較用
#   b-table-plain    ★ TABLE <db>.<T>                    本題
#   c-table-lower    ★ table <db>.<T>                    小文字。分類が大文字化して判定する前提の裏取り
#   d-table-paren    ★ (TABLE <db>.<T>)                  athena-local は先頭の `(` を取り除いて判定する
#   e-table-comment  ★ -- c<改行>TABLE <db>.<T>          先頭コメント。既存の判定は読み飛ばす
#   f-table-missing     TABLE <db>.athena_local_probe_65_missing
#                       存在しないテーブル。失敗しても StatementType / SubstatementType /
#                       OutputLocation が返るかを見る（スキャンしない）
#   g-table-limit    ★ TABLE <db>.<T> LIMIT 1            受け付けるかどうかだけ。参考
#
# preflight（本編の前に 2 本だけ投げる。どちらもスキャンしない）:
#   preflight-select-1   SELECT 1            Athena 自身で最も軽い 1 本。落ちたらここで止まる
#   preflight-show-tables SHOW TABLES IN <DB> TABLE が実在するかの確認と、省略時の 1 件目の取得
#
# ** SQL に改行を含める書き方の注意 **
# 「-- c\nTABLE ...」のような文は、シェルで実際の改行文字（0x0a）にしてから渡さないと、
# 「\」「n」という 2 文字が入った 1 行の文字列になり、まったく別の測定になる。
# そのため bash の ANSI-C quoting（$'...'）を使う。$'...' は変数展開をしないので、
# $DB を埋め込む行は $'-- c\n'"TABLE $DB.$TABLE" のように断片を隣り合わせて連結する。
#
# S3 からの取得は `aws s3 cp <src> -` で標準出力に流し、リダイレクトはこのシェルが行う。
# aws が Docker のラッパだと、コンテナにマウントされるのは実行時のカレントディレクトリだけで、
# 絶対パスを渡すとコンテナの中に書かれて消える。しかも終了コードは 0 になる。
# `aws athena ... --output json` の応答も同じ理由で標準出力からファイルに落とす。
# `--debug` は使わない（生ログに署名やアクセスキーが残るため）。
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く。前の回の結果と混ざらない。
#
# 出力ファイル（項目ごと。<label> は上の項目名）:
#   <label>.request.txt         投げた SQL と実行文脈（要求そのもの）
#   <label>.start.err           StartQueryExecution の stderr（失敗したときの手掛かり）
#   <label>.execution.json      GetQueryExecution の応答そのもの
#   <label>.statistics.json     Statistics（execution.json から抜粋）
#   <label>.results.json        GetQueryResults の応答そのもの（本編は --max-items 3）
#   <label>.reason.txt          State / StateChangeReason / AthenaError（execution.json から抜粋）
#   <label>.ls.txt              OutputLocation と .metadata の ls の結果
#   <label>.bytes / .od.txt     結果ファイル本体の中身と、バイト単位で見たもの
#   <label>.cp.err              本体を取れなかったときの stderr（= 本体が無いことの証拠）
#   <label>.metadata.bytes / .metadata.od.txt  .metadata の中身と 16 進（無ければ作らない）
#   <label>.metadata.cp.err     .metadata を取れなかったときの stderr（= 無いことの証拠）
#   <label>.head.json / .metadata.head.json     head-object の応答（Content-Type）
#   <label>.head.err / .metadata.head.err       head-object が失敗したときの stderr（無いことの証拠）
# 中身が空の .err は項目ごとに消している。残っている .err は「その取得が失敗した」証拠として読める。
#
# 最後に summary.tsv（機械可読）と summary.md（実名をマスクした、そのまま貼れる形）を作る。
# summary.md 以外のファイルにはデータベース名・テーブル名・実データが入る。貼るときは中身を確かめること。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください}"
: "${DB:?DB にデータベース名を設定してください}"
TABLE=${TABLE:-}
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_DIR=${OUT_DIR:-${DEV_HOST_HOME:-$HOME}/athena-table-statement-measurements}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}

case "$OUTPUT" in
  s3://*) ;;
  *) echo "OUTPUT は s3://bucket/prefix/ の形で指定してください（今の値: $OUTPUT）" >&2; exit 1 ;;
esac
case "$OUTPUT" in
  */) ;;
  *) OUTPUT="$OUTPUT/"; echo "OUTPUT の末尾に / を足しました: $OUTPUT" ;;
esac

# summary から実名を隠すための材料。バケット名にアカウント ID が入っていることが多い。
OUTPUT_REST=${OUTPUT#s3://}
BUCKET=${OUTPUT_REST%%/*}

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\tstatement_type\tsubstatement_type\toutput_file\tbody_lines\tbody_head1\tbody_head2\tmetadata\tcontent_type\tmetadata_content_type\tgqr_rows\tgqr_row1\tgqr_row2\theader_in_gqr\tupdate_count\tscanned_bytes\tnote\n' > "$SUMMARY"

echo "出力先: $RUN_DIR"
echo "警告: この実行は対象テーブルを 6 回フルスキャンします（a, b, c, d, e, g）。"
echo "      小さいテーブルを TABLE で指定することを勧めます（今の指定: ${TABLE:-（未指定。SHOW TABLES の 1 件目を使う）}）。"
echo "      DDL は実行しません（読み取りだけ）。"

# StartQueryExecution を実際に呼んだ回数（再試行も含む）。summary の冒頭に出す。
START_CALL_COUNT=0
# 最後まで走り切ったか。走り切らなかったら INCOMPLETE.txt を残して、途中の run と分かるようにする。
COMPLETED=0

# 中間ファイルは、途中で止めても残らないよう trap で消す。DDL を投げないので後始末は無い。
cleanup() {
  rm -f "$RUN_DIR"/.tmp-*
  if [ "$COMPLETED" != 1 ]; then
    {
      echo "この run は最後まで走り切っていません（$(date -Iseconds)）。"
      echo "summary.tsv は途中までの行しか無く、summary.md は作られていないことがあります。"
    } > "$RUN_DIR/INCOMPLETE.txt" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# 実名（アカウント ID・バケット・DB 名・テーブル名）を置換して隠す。
# 置換の順は長い方から（OUTPUT はバケットを含むので先に消す）。
redact() {
  local s=$1
  s=${s//$OUTPUT/<OUTPUT>}
  s=${s//$BUCKET/<BUCKET>}
  s=${s//$DB/<DB>}
  if [ -n "$TABLE" ]; then
    s=${s//$TABLE/<TABLE>}
  fi
  # 12 桁の数字の並び（AWS アカウント ID）を潰す。バケット名の中のものは上の置換で既に
  # 消えているので、ここで効くのは主にエラー文言の中の ARN。
  # クエリ ID（UUID）の最後の区画は 12 桁で、全部数字だと巻き込まれてしまうので、
  # UUID の形のものだけ先に印（0x01）で数字の並びを割って避け、最後に印を外す。
  printf '%s' "$s" | sed -E \
    -e 's/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{6})([0-9a-fA-F]{6})/\1\x01\2/g' \
    -e 's/[0-9]{12}/<ACCOUNT_ID>/g' \
    -e 's/\x01//g'
}

# 制御文字を落として短くする。summary に入れる前に必ず通す。
sanitize() {
  printf '%s' "$1" | tr '\t\n\r' '   ' | cut -c1-300
}

# 実名を隠して制御文字も落とす。summary の列に入れるのはこれを通した値だけ。
clean() {
  sanitize "$(redact "$1")"
}

# stderr ファイルの 1 行目を、実名を隠して短く返す。ファイルが無ければ定型文を返す。
first_err_line() {
  local f=$1 line
  if [ -s "$f" ]; then
    line=$(head -1 "$f")
    clean "$line"
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

# head-object の応答を手元のファイルに取る。src は s3://bucket/key の形。
# 失敗したら dest を消して err（= そのオブジェクトが無いことの証拠）だけを残す。
head_object() {
  local src=$1 dest=$2 err=$3
  local rest=${src#s3://} bucket key
  bucket=${rest%%/*}
  key=${rest#*/}
  if aws s3api head-object --region "$REGION" --bucket "$bucket" --key "$key" > "$dest" 2> "$err"; then
    rm -f "$err"
    return 0
  fi
  rm -f "$dest"
  return 1
}

# head-object の応答から ContentType を取る。jq が無いこともあるので python3 で読む。
content_type_of() {
  [ -s "$1" ] || { echo "-"; return; }
  python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("ContentType") or "-")
except Exception:
    print("-")' "$1"
}

# execution.json から State / StateChangeReason / AthenaError を取り出してファイルに書く。
# 実名を含みうるので、summary には使わずファイルにだけ残す。
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

# execution.json から Statistics をそのままファイルに書き出し、DataScannedInBytes を返す。
write_statistics() {
  local src=$1 dest=$2
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception:
    open(sys.argv[2], "w").write("{}\n")
    print("-")
    sys.exit(0)
stats = d.get("Statistics", {})
open(sys.argv[2], "w").write(json.dumps(stats, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
v = stats.get("DataScannedInBytes")
print("-" if v is None else v)' "$src" "$dest"
}

# AthenaError の ErrorCategory / ErrorType（数値コードだけ。実名を含まない）を返す。無ければ "-"。
error_codes_of() {
  python3 -c 'import json, sys
try:
    err = json.load(open(sys.argv[1]))["QueryExecution"]["Status"].get("AthenaError")
except Exception:
    err = None
if err is None:
    print("-")
else:
    print("cat=%s,type=%s" % (err.get("ErrorCategory", "-"), err.get("ErrorType", "-")))' "$1"
}

# execution.json から StatementType・SubstatementType・OutputLocation をタブ区切りで返す。
read_execution_fields() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception:
    print("-\t-\t")
    sys.exit(0)
st = d.get("StatementType") or "-"
sub = d.get("SubstatementType") or "-"
loc = d.get("ResultConfiguration", {}).get("OutputLocation", "")
print("%s\t%s\t%s" % (st, sub, loc))' "$1"
}

# results.json から UpdateCount を返す。無ければ "-"。
read_update_count() {
  python3 -c 'import json, sys
try:
    v = json.load(open(sys.argv[1])).get("UpdateCount")
    print(v if v is not None else "-")
except Exception:
    print("-")' "$1"
}

# 結果ファイル本体の「形」をタブ区切りで返す: 行数 / 先頭行そのもの / 2 行目の列数。
# 2 行目は実データなので、値は出さず列数だけにする（列名行の有無は先頭行で分かる）。
body_shape() {
  # `--` を付けないと printf が先頭の `-` をオプションと見て落ちる（値が全部 `-` の行もあるため）。
  [ -s "$1" ] || { printf -- 'none\t-\t-\n'; return; }
  python3 -c 'import csv, io, sys
try:
    data = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
except Exception:
    print("none\t-\t-")
    sys.exit(0)
lines = data.splitlines()
def flat(s):
    return s.replace("\t", " ").replace("\r", " ")
def fields(line):
    try:
        row = next(csv.reader(io.StringIO(line)))
    except Exception:
        return "-"
    return "fields=%d" % len(row)
head1 = flat(lines[0]) if len(lines) >= 1 else "-"
head2 = fields(lines[1]) if len(lines) >= 2 else "-"
print("%d\t%s\t%s" % (len(lines), head1, head2))' "$1"
}

# results.json の Rows の「形」をタブ区切りで返す: 行数 / 1 行目の値をカンマで繋いだもの /
# 2 行目の列数。2 行目は実データなので列数だけにする。
rows_shape() {
  # ここも `--` が要る（printf は先頭の `-` をオプションと見る）。
  [ -s "$1" ] || { printf -- '-\t-\t-\n'; return; }
  python3 -c 'import json, sys
try:
    rows = json.load(open(sys.argv[1]))["ResultSet"]["Rows"]
except Exception:
    print("-\t-\t-")
    sys.exit(0)
def values(row):
    return [c.get("VarCharValue", "") for c in row.get("Data", [])]
def flat(s):
    return s.replace("\t", " ").replace("\r", " ").replace("\n", " ")
row1 = flat(",".join(values(rows[0]))) if len(rows) >= 1 else "-"
row2 = ("fields=%d" % len(values(rows[1]))) if len(rows) >= 2 else "-"
print("%d\t%s\t%s" % (len(rows), row1, row2))' "$1"
}

# 結果ファイル本体の先頭行（CSV として解釈した値の並び）と GetQueryResults の Rows の 1 行目が
# 同じかを返す。この issue の本題（列名行が API 側にも入るか）はこれで決まる。
# yes / no / unknown。
compare_header() {
  local body=$1 results=$2
  [ -s "$body" ] || { echo "unknown"; return; }
  [ -s "$results" ] || { echo "unknown"; return; }
  python3 -c 'import csv, io, json, sys
try:
    data = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
    lines = data.splitlines()
    head = next(csv.reader(io.StringIO(lines[0]))) if lines else None
except Exception:
    head = None
try:
    rows = json.load(open(sys.argv[2]))["ResultSet"]["Rows"]
    first = [c.get("VarCharValue", "") for c in rows[0].get("Data", [])] if rows else None
except Exception:
    first = None
if head is None or first is None:
    print("unknown")
else:
    print("yes" if head == first else "no")' "$body" "$results"
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
# （実際の SQL エラーは 1 回で確定させる）。試行回数は LAST_ATTEMPTS に残す。
# この関数はクエリ ID を標準出力に返すので、呼び出し側は `$( )` で受ける。
# つまり中身はサブシェルで走り、変数への代入は呼び出し側に戻らない。
# 試行回数と呼び出し回数はファイル（.tmp-attempts / .tmp-calls）に書いて渡す。
# 呼び出しは逐次なので、上書きし合うことは無い。
LAST_ATTEMPTS=0
start_query_retry() {
  local label=$1 sql=$2
  local attempt=1 id
  while :; do
    START_CALL_COUNT=$((START_CALL_COUNT + 1))
    echo "$START_CALL_COUNT" > "$RUN_DIR/.tmp-calls"
    echo "$attempt" > "$RUN_DIR/.tmp-attempts"
    id=$(aws athena start-query-execution --region "$REGION" \
      --query-string "$sql" \
      --query-execution-context "Catalog=$CATALOG,Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" \
      --query QueryExecutionId --output text 2> "$RUN_DIR/$label.start.err")
    if [ -n "${id:-}" ]; then
      printf '%s' "$id"
      return 0
    fi
    if [ "$attempt" -ge "$RETRY_MAX" ] || ! is_transient_error "$RUN_DIR/$label.start.err"; then
      return 1
    fi
    echo "== $label: 一時的な失敗とみて ${RETRY_DELAY} 秒後に再試行します（試行 $attempt/$RETRY_MAX）" >&2
    sleep "$RETRY_DELAY"
    attempt=$((attempt + 1))
  done
}

# start_query_retry がサブシェルに残した試行回数・呼び出し回数を呼び出し側に取り込む。
absorb_counters() {
  if [ -s "$RUN_DIR/.tmp-attempts" ]; then
    LAST_ATTEMPTS=$(cat "$RUN_DIR/.tmp-attempts")
  else
    LAST_ATTEMPTS=0
  fi
  if [ -s "$RUN_DIR/.tmp-calls" ]; then
    START_CALL_COUNT=$(cat "$RUN_DIR/.tmp-calls")
  fi
}

# 項目を未測定として summary に 1 行残す。全体を止めずに次へ進む。
skip() {
  local label=$1 note=$2
  echo "== $label: 未測定（$note）"
  printf '%s\tSKIPPED\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t%s\n' "$label" "$(clean "$note")" >> "$SUMMARY"
}

# ラベルを指定して 1 文を実行し、終端状態まで待って StatementType 等を採取する。
# 第 3 引数は GetQueryResults の --max-items（既定 3。0 を渡すと指定せず全件取る）。
# 項目ごとに独立していて、失敗しても全体は止めない。成功したときだけ 0 を返す。
run() {
  local label=$1 sql=$2 max_items=${3:-3}
  local id state stype sstype loc out_file note ucount scanned
  local body_lines body_head1 body_head2 gqr_rows gqr_row1 gqr_row2
  local meta ctype mctype header

  {
    echo "# label: $label"
    echo "# Catalog: $CATALOG"
    echo "# Database: $DB"
    echo "# OutputLocation: $OUTPUT"
    echo "# SQL（次の行から最後まで）:"
    printf '%s\n' "$sql"
  } > "$RUN_DIR/$label.request.txt"

  id=$(start_query_retry "$label" "$sql")
  absorb_counters
  if [ -z "${id:-}" ]; then
    note="attempts=$LAST_ATTEMPTS; $(first_err_line "$RUN_DIR/$label.start.err")"
    if ! grep -q "An error occurred" "$RUN_DIR/$label.start.err" 2>/dev/null; then
      note="$note; CLI が送信前に拒否した可能性"
    fi
    echo "== $label: 開始できませんでした（試行 $LAST_ATTEMPTS 回）。$RUN_DIR/$label.start.err を見てください"
    printf '%s\tSTART_FAILED\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t%s\n' "$label" "$(clean "$note")" >> "$SUMMARY"
    return 1
  fi

  state=$(poll_until_terminal "$id")

  aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.execution.json" 2> "$RUN_DIR/$label.execution.err"
  if [ "$max_items" = 0 ]; then
    aws athena get-query-results --region "$REGION" --query-execution-id "$id" \
      > "$RUN_DIR/$label.results.json" 2> "$RUN_DIR/$label.results.err"
  else
    aws athena get-query-results --region "$REGION" --query-execution-id "$id" \
      --max-items "$max_items" \
      > "$RUN_DIR/$label.results.json" 2> "$RUN_DIR/$label.results.err"
  fi
  write_reason "$RUN_DIR/$label.execution.json" "$RUN_DIR/$label.reason.txt"
  scanned=$(write_statistics "$RUN_DIR/$label.execution.json" "$RUN_DIR/$label.statistics.json")

  IFS=$'\t' read -r stype sstype loc < <(read_execution_fields "$RUN_DIR/$label.execution.json")
  ucount=$(read_update_count "$RUN_DIR/$label.results.json")
  IFS=$'\t' read -r gqr_rows gqr_row1 gqr_row2 < <(rows_shape "$RUN_DIR/$label.results.json")

  out_file="-"; body_lines="none"; body_head1="-"; body_head2="-"
  meta="none"; ctype="-"; mctype="-"; header="unknown"
  if [ -n "$loc" ]; then
    # OutputLocation のうち OUTPUT より後ろだけを出す（`<id>.csv` / `tables/<id>` の形を見たい）。
    case "$loc" in
      "$OUTPUT"*) out_file=${loc#"$OUTPUT"} ;;
      *) out_file=${loc##*/} ;;
    esac
    [ -n "$out_file" ] || out_file="(prefix のみ)"

    { echo "# ls $loc"; aws s3 ls "$loc"; echo "# rc=$?"
      echo "# ls $loc.metadata"; aws s3 ls "$loc.metadata"; echo "# rc=$?"
    } > "$RUN_DIR/$label.ls.txt" 2>&1

    if fetch "$loc" "$RUN_DIR/$label.bytes" "$RUN_DIR/$label.cp.err"; then
      od -c "$RUN_DIR/$label.bytes" > "$RUN_DIR/$label.od.txt"
      IFS=$'\t' read -r body_lines body_head1 body_head2 < <(body_shape "$RUN_DIR/$label.bytes")
    fi
    if head_object "$loc" "$RUN_DIR/$label.head.json" "$RUN_DIR/$label.head.err"; then
      ctype=$(content_type_of "$RUN_DIR/$label.head.json")
    fi
    if fetch "$loc.metadata" "$RUN_DIR/$label.metadata.bytes" "$RUN_DIR/$label.metadata.cp.err"; then
      od -tx1c "$RUN_DIR/$label.metadata.bytes" > "$RUN_DIR/$label.metadata.od.txt"
      meta=$(wc -c < "$RUN_DIR/$label.metadata.bytes" | tr -d ' ')
    fi
    if head_object "$loc.metadata" "$RUN_DIR/$label.metadata.head.json" "$RUN_DIR/$label.metadata.head.err"; then
      mctype=$(content_type_of "$RUN_DIR/$label.metadata.head.json")
    fi

    header=$(compare_header "$RUN_DIR/$label.bytes" "$RUN_DIR/$label.results.json")
  fi

  note="attempts=$LAST_ATTEMPTS"
  case "$state" in
    FAILED | CANCELLED | TIMEOUT) note="$note; $(error_codes_of "$RUN_DIR/$label.execution.json")" ;;
  esac

  echo "== $label  state=$state  stype=$stype  sstype=$sstype  out=$(clean "$out_file")  body_lines=$body_lines  metadata=$meta  gqr_rows=$gqr_rows  header_in_gqr=$header  update_count=$ucount"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$label" "$state" "$stype" "$sstype" "$(clean "$out_file")" "$body_lines" \
    "$(clean "$body_head1")" "$body_head2" "$meta" "$ctype" "$mctype" \
    "$gqr_rows" "$(clean "$gqr_row1")" "$gqr_row2" "$header" "$ucount" "$scanned" \
    "$(clean "$note")" >> "$SUMMARY"

  # 中身の無い .err は消す。残っている .err は「その取得が失敗した（= 置かれていない）」証拠、
  # という読み方を崩さないため（リダイレクトは成功したときも空のファイルを作ってしまう）。
  for e in "$RUN_DIR/$label"*.err; do
    if [ -f "$e" ] && [ ! -s "$e" ]; then
      rm -f "$e"
    fi
  done

  [ "$state" = SUCCEEDED ]
}

# ---- preflight ----------------------------------------------------------
# 1. Athena 自身で最も軽い 1 本。スキャンしない。ここが通らないなら資格情報・リージョン・
#    OutputLocation の権限のどれかが違うので、本編には進まない。
if ! run preflight-select-1 "SELECT 1" 0; then
  echo
  echo "SELECT 1 が通りませんでした。資格情報・REGION・OUTPUT の権限を確かめてください。"
  echo "理由: $RUN_DIR/preflight-select-1.reason.txt"
  echo "開始できていない場合: $RUN_DIR/preflight-select-1.start.err"
  exit 1
fi

# 2. 対象テーブルの確認。SHOW TABLES はメタデータだけを見るのでスキャンしない。
#    ここは全件取る（--max-items を付けると 3 件しか見えず、実在の確認にならない）。
TABLE_LIST_OK=0
if run preflight-show-tables "SHOW TABLES IN $DB" 0; then
  python3 - "$RUN_DIR/preflight-show-tables.results.json" "$RUN_DIR/preflight-show-tables.bytes" "$RUN_DIR/tables.txt" <<'PYEOF'
import json, os, sys
names = []
try:
    rows = json.load(open(sys.argv[1]))["ResultSet"]["Rows"]
    names = [r["Data"][0].get("VarCharValue", "") for r in rows if r.get("Data")]
except Exception:
    names = []
if not names and os.path.exists(sys.argv[2]):
    # GetQueryResults を読めなかったときは、結果ファイル本体（<id>.txt）から拾う。
    try:
        names = open(sys.argv[2], "rb").read().decode("utf-8", "replace").splitlines()
    except Exception:
        names = []
names = [n for n in (n.strip() for n in names) if n]
open(sys.argv[3], "w").write("\n".join(names) + "\n")
PYEOF
  if [ -s "$RUN_DIR/tables.txt" ] && [ -n "$(head -1 "$RUN_DIR/tables.txt")" ]; then
    TABLE_LIST_OK=1
  fi
else
  echo "SHOW TABLES IN $DB が通りませんでした。DB か CATALOG の指定が実在しない可能性があります。"
  echo "理由: $RUN_DIR/preflight-show-tables.reason.txt"
fi

TABLE_NOTE=""
if [ "$TABLE_LIST_OK" = 1 ]; then
  if [ -z "$TABLE" ]; then
    TABLE=$(head -1 "$RUN_DIR/tables.txt")
    TABLE_NOTE="TABLE 未指定のため SHOW TABLES の 1 件目を使った"
    echo "テーブルは SHOW TABLES の 1 件目を使います。一覧: $RUN_DIR/tables.txt"
  elif ! grep -qx -- "$TABLE" "$RUN_DIR/tables.txt"; then
    echo "指定された TABLE は $DB の一覧に見当たりません。1 件目に切り替えます。一覧: $RUN_DIR/tables.txt"
    TABLE=$(head -1 "$RUN_DIR/tables.txt")
    TABLE_NOTE="指定された TABLE が一覧に無かったので 1 件目を使った"
  else
    TABLE_NOTE="指定された TABLE が一覧にあることを確認した"
  fi
else
  TABLE=""
  TABLE_NOTE="テーブルの一覧を取れなかった（または 1 件も無かった）"
fi

# ---- 本編 ---------------------------------------------------------------
MISSING="$DB.athena_local_probe_65_missing"

if [ -n "$TABLE" ]; then
  T="$DB.$TABLE"
  # a. 対照。列名行と結果ファイルの形を b 以降と比べるための基準。
  run a-select-plain  "SELECT * FROM $T"
  # b. 本題。Trino では SELECT * FROM の短縮形。
  run b-table-plain   "TABLE $T"
  # c. 小文字。分類が大文字化してから判定する前提の裏取り。
  run c-table-lower   "table $T"
  # d. 先頭の `(`。athena-local は取り除いてから判定する。
  run d-table-paren   "(TABLE $T)"
  # e. 先頭コメント。既存の判定は読み飛ばす（2026-09-18 実測）。
  #    $'...' は変数を展開しないので、改行だけを $'...' にして残りを連結する。
  run e-table-comment $'-- c\n'"TABLE $T"
else
  for label in a-select-plain b-table-plain c-table-lower d-table-paren e-table-comment; do
    skip "$label" "$TABLE_NOTE"
  done
fi

# f. 存在しないテーブル。必ず失敗するがスキャンしない。失敗時にも分類と OutputLocation が
#    返るかを見る。テーブルが無いデータベースでもここだけは測れる。
run f-table-missing "TABLE $MISSING"

# g. LIMIT を付けた形。受け付けるかどうかだけの参考。
if [ -n "$TABLE" ]; then
  run g-table-limit "TABLE $DB.$TABLE LIMIT 1"
else
  skip g-table-limit "$TABLE_NOTE"
fi

# ---- summary ------------------------------------------------------------
# summary.tsv を Markdown の表にする。main は分類と結果ファイル、detail は中身の形。
# 値は summary.tsv に書いた時点で redact 済みなので、ここでは整形だけ。
md_table() {
  python3 - "$SUMMARY" "$1" <<'PYEOF'
import csv, sys

MAIN = [
    ("label", "項目"),
    ("state", "State"),
    ("statement_type", "StatementType"),
    ("substatement_type", "SubstatementType"),
    ("output_file", "OutputLocation の末尾"),
    ("metadata", ".metadata"),
    ("update_count", "UpdateCount"),
    ("header_in_gqr", "本体の先頭行 = GQR の 1 行目"),
]
DETAIL = [
    ("label", "項目"),
    ("body_lines", "本体の行数"),
    ("body_head1", "本体の 1 行目"),
    ("body_head2", "本体の 2 行目"),
    ("gqr_rows", "GQR の Rows 数"),
    ("gqr_row1", "GQR の 1 行目"),
    ("gqr_row2", "GQR の 2 行目"),
    ("content_type", "本体の Content-Type"),
    ("metadata_content_type", ".metadata の Content-Type"),
    ("scanned_bytes", "scanned_bytes"),
]

cols = MAIN if sys.argv[2] == "main" else DETAIL
with open(sys.argv[1], newline="") as f:
    # summary.tsv は printf でそのまま書いていて引用符の約束が無い。既定のまま読むと
    # CSV の列名行（`"k","v"`）の先頭の `"` を引用の開始と見て値が壊れるので、引用を無効にする。
    rows = list(csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE, quotechar=None))

print("| " + " | ".join(h for _, h in cols) + " |")
print("|" + "|".join(" --- " for _ in cols) + "|")
for row in rows:
    cells = [(row.get(k) or "-").replace("|", "\\|") for k, _ in cols]
    print("| " + " | ".join(cells) + " |")
PYEOF
}

# summary.md を作る。
write_summary_md() {
  local md="$RUN_DIR/summary.md"
  {
    echo "# issue #65: 本物の Athena が \`TABLE <t>\` をどう扱うかの実測"
    echo
    echo "- 実行日時: $(date -Iseconds)"
    echo "- StartQueryExecution を呼んだ回数（一時的な失敗の再試行込み）: $START_CALL_COUNT"
    echo "  - GetQueryExecution（ポーリング）・GetQueryResults・S3 への呼び出しはこの回数に含めない。"
    echo "- スキャン: 対象テーブルを最大 6 回フルスキャンする（a, b, c, d, e, g）。"
    echo "  小さいテーブルを \`TABLE\` で指定することを勧める。実際にスキャンした量は各行の scanned_bytes を見る。"
    echo "- DDL: 無し（このスクリプトは作成・変更・削除を一切しない。読み取りだけ）。"
    echo "- テーブルの決め方: $(clean "$TABLE_NOTE")"
    echo
    echo "> 注意: 以下は実測した本物の Athena の挙動であって、athena-local の「工場出荷時の既定」ではない。"
    echo "> 将来の Athena の変更で変わりうる。"
    echo
    echo "> 実名（アカウント ID・バケット・データベース名・テーブル名）は置換してある。"
    echo "> OutputLocation は \`OUTPUT\` より後ろだけを出している（クエリ ID はそのまま）。"
    echo "> 結果の 2 行目は実データなので値を出さず列数だけにしてある。"
    echo
    echo "## 分類と結果ファイル"
    echo
    md_table main
    echo
    echo "## 本体と GetQueryResults の中身"
    echo
    md_table detail
    echo
    echo "- \`.metadata\` の列はバイト数。\`none\` は取得できなかった（= 置かれていない）ことを表す。"
    echo "- \`本体の行数\` の \`none\` は本体そのものを取得できなかったことを表す。"
    echo "- \`本体の先頭行 = GQR の 1 行目\` が \`yes\` なら、S3 の結果ファイルと API の結果は同じ行から始まる"
    echo "  （= API にも列名行が入っている）。\`no\` なら API 側だけ列名行が落ちている。"
    echo
    echo "## 未測定の項目"
    echo
    python3 - "$SUMMARY" <<'PYEOF'
import csv, sys

with open(sys.argv[1], newline="") as f:
    rows = [r for r in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE, quotechar=None)
            if r["state"] in ("SKIPPED", "START_FAILED", "TIMEOUT")]
if not rows:
    print("（無し。全項目を測れた）")
else:
    for r in rows:
        print("- %s: %s（%s）" % (r["label"], r["state"], r["note"] or "理由不明"))
PYEOF
    echo
    echo "## 失敗した項目の理由"
    echo
    failed_any=0
    for f in "$RUN_DIR"/*.reason.txt; do
      [ -e "$f" ] || continue
      label=$(basename "$f" .reason.txt)
      if grep -q '^State: FAILED' "$f" 2>/dev/null || [ -s "$RUN_DIR/$label.start.err" ]; then
        failed_any=1
        echo "### $label"
        echo
        echo '```'
        if [ -s "$RUN_DIR/$label.start.err" ]; then
          echo "start.err:"
          redact "$(head -3 "$RUN_DIR/$label.start.err")"
          echo
        fi
        redact "$(grep -E '^(State|StateChangeReason):' "$f" | cut -c1-300)"
        echo
        echo '```'
        echo
      fi
    done
    [ "$failed_any" = 1 ] || echo "（無し。FAILED も開始できなかった項目も無かった）"
  } > "$md"
  echo "$md"
}

SUMMARY_MD=$(write_summary_md)
COMPLETED=1
rm -f "$RUN_DIR/INCOMPLETE.txt"

echo
echo "完了しました。"
echo "機械可読な一覧: $SUMMARY"
echo "そのまま貼れる整形済みの一覧（実名はマスク済み）: $SUMMARY_MD"
echo "取得したファイルは $RUN_DIR にあります。リポジトリには入れないでください。"
echo "summary.md 以外（*.request.txt / *.reason.txt / *.results.json / *.bytes など）は"
echo "データベース名・テーブル名・実データを含みます。貼るときは中身を確かめてください。"
