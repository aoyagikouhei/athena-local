#!/usr/bin/env bash
# issue #92 で作成（tools/ へ移す前の名前は 92-measure-explain-variants.sh）
# 本物の Athena で、EXPLAIN の変種の GetQueryResults の Rows の分け方と結果ファイル <id>.txt を
# 実測する。issue #92 のための実測スクリプト。#1 の txt-result.sh を雛形に、#35 の
# 再試行・実名の置換・summary の整形を足した。
#
# 測りたいこと（#73 は `EXPLAIN SELECT 1` の 1 形だけ実測し、「プラン全文 + `\n` を `\n` で
# 分ける」規則をすべての EXPLAIN に当てている）:
#   e1  EXPLAIN SELECT 1                          対照（#73 の再現。Rows 15 行・.txt 393 バイトのはず）
#   e2  EXPLAIN (FORMAT JSON) SELECT 1            プランが改行で終わらない
#   e3  EXPLAIN (TYPE IO) SELECT 1                同上
#   e4  EXPLAIN ANALYZE SELECT 1                  実行を伴う。SubstatementType も見る
#   e5  EXPLAIN (TYPE DISTRIBUTED) SELECT 1
#   e6  EXPLAIN (TYPE VALIDATE) SELECT 1          1 行の true が返るはず
#   e7  EXPLAIN (FORMAT GRAPHVIZ) SELECT 1
#   e8  EXPLAIN ANALYZE VERBOSE SELECT 1
#   f1  EXPLAIN SELECT * FROM <無いテーブル>        失敗した EXPLAIN の結果ファイル（docs/dev/unmeasured.md の項目）
#   f2  EXPLAIN ANALYZE SELECT * FROM <無いテーブル>
# 各文で GetQueryResults の Rows（末尾の空行の数）と .txt（末尾の改行の数）を採り、
# 「.txt == 列名行 + Rows を `\n` で連結 + `\n`」が成り立つかを summary に出す。
#
# 使い方:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db bash tools/measure/explain-variants.sh
#   （資格情報はホストのシェルで AWS_ACCESS_KEY_ID などを export してから。または ~/.aws/credentials）
#
# 必要な環境変数:
#   OUTPUT    結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける）。
#   DB        データベース名。実在するものを指定する（preflight の SHOW TABLES に使うだけ）。
#
# 任意の環境変数:
#   CATALOG      既定 AwsDataCatalog
#   REGION       既定 ap-northeast-1
#   OUT_DIR      既定 ${DEV_HOST_HOME:-$HOME}/athena-explain-variants-measurements（実名が入るのでリポジトリの外に出す）
#   POLL_TIMEOUT 終端状態を待つ上限（秒）。既定 180
#   RETRY_MAX    名前解決・接続など一時的な失敗を再試行する回数の上限。既定 4
#   RETRY_DELAY  再試行の間隔（秒）。既定 5
#
# 本物に対する操作: DDL 無し、テーブルのスキャン無し（すべて `SELECT 1` の EXPLAIN か、
# 無いテーブルへの EXPLAIN）。StartQueryExecution は preflight 込みで 11 回。
# 課金: Athena の最小課金 × クエリ数の見込み（EXPLAIN ANALYZE も `SELECT 1` を実行するだけ）。
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く。
# S3 からの取得は `aws s3 cp <src> -` で標準出力に流し、リダイレクトはこのシェルが行う
# （aws が Docker のラッパだと、絶対パスへの書き出しはコンテナの中に消える）。
#
# 文ごとに次を保存する（取れたものだけ）。
#   <label>.sql              投げた SQL（DB 名は含まない）
#   <label>.start.err        StartQueryExecution の標準エラー
#   <label>.execution.json   GetQueryExecution の応答
#   <label>.results.json     GetQueryResults の応答（Rows の分け方はここから読む）
#   <label>.results.err      GetQueryResults の標準エラー（失敗した文では本物がエラーを返す）
#   <label>.reason.txt       StateChangeReason と AthenaError（**DB 名を含みうる。貼る前に確認**）
#   <label>.ls.txt           本体と .metadata の有無
#   <label>.bytes            結果ファイル <id>.txt の中身そのもの
#   <label>.od.txt           上をバイト単位で見たもの
#   <label>.metadata.bytes   <id>.txt.metadata があればその中身
#
# summary.txt は実名を含まない（プランの本文は載せず、行数・バイト数・末尾の形だけを出す）。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください}"
: "${DB:?DB にデータベース名を設定してください}"
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_DIR=${OUT_DIR:-${DEV_HOST_HOME:-$HOME}/athena-explain-variants-measurements}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}

LABELS="e1 e2 e3 e4 e5 e6 e7 e8 f1 f2"

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\tstatement_type\tsubstatement_type\tloc_shape\ttxt_bytes\ttxt_lines\ttxt_trailing_newlines\tmetadata_bytes\trows\theader_row\ttrailing_empty_rows\tcolumn_type\tprecision\ttxt_matches_rows\tnote\n' > "$SUMMARY"
echo "出力先: $RUN_DIR"

START_CALL_FILE="$RUN_DIR/.start-calls"
: > "$START_CALL_FILE"
trap 'rm -f "$RUN_DIR"/.tmp-*' EXIT

OUTPUT_BUCKET=${OUTPUT#s3://}
OUTPUT_BUCKET=${OUTPUT_BUCKET%%/*}
redact() {
  local s=$1
  s=${s//$DB/<DB>}
  s=${s//$OUTPUT/<OUTPUT>}
  s=${s//$OUTPUT_BUCKET/<BUCKET>}
  printf '%s' "$s"
}
sanitize() { printf '%s' "$1" | tr '\t\n\r' '   ' | cut -c1-300; }
first_err_line() {
  if [ -s "$1" ]; then sanitize "$(redact "$(head -1 "$1")")"; else echo "(エラー出力なし)"; fi
}
is_transient_error() {
  [ -s "$1" ] || return 1
  grep -qiE 'Could not connect|Connection aborted|Connection reset|EndpointConnectionError|Temporary failure in name resolution|Name or service not known|Network is unreachable|Read timed out|[Cc]onnect timeout|ConnectTimeoutError|ReadTimeoutError|SSLError|Broken pipe' "$1"
}

fetch() {
  local src=$1 dest=$2 err=$3
  if aws s3 cp "$src" - > "$dest" 2> "$err"; then
    [ -s "$dest" ] || [ ! -s "$err" ]
  else
    rm -f "$dest"
    return 1
  fi
}

write_reason() {
  python3 -c 'import json, sys
try: d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception:
    open(sys.argv[2], "w").write("(execution.json を読めませんでした)\n"); sys.exit(0)
st = d.get("Status", {})
err = st.get("AthenaError")
out = ["State: %s" % st.get("State", ""), "StateChangeReason: %s" % st.get("StateChangeReason", "(無し)"),
       "AthenaError: %s" % ("(無し)" if err is None else json.dumps(err, ensure_ascii=False, sort_keys=True))]
open(sys.argv[2], "w").write("\n".join(out) + "\n")' "$1" "$2"
}
error_codes_of() {
  python3 -c 'import json, sys
try: err = json.load(open(sys.argv[1]))["QueryExecution"]["Status"].get("AthenaError")
except Exception: err = None
print("-" if err is None else "cat=%s,type=%s" % (err.get("ErrorCategory", "-"), err.get("ErrorType", "-")))' "$1"
}
# StatementType / SubstatementType / OutputLocation をタブ区切りで返す。
read_execution_fields() {
  python3 -c 'import json, sys
try: d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception: print("-\t-\t"); sys.exit(0)
print("%s\t%s\t%s" % (d.get("StatementType") or "-", d.get("SubstatementType") or "-", d.get("ResultConfiguration", {}).get("OutputLocation", "")))' "$1"
}
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

# results.json と .txt を突き合わせ、Rows の形と .txt の末尾の形をタブ区切りで返す。
#   rows / header_row / trailing_empty_rows / column_type / precision / txt_lines / txt_trailing_newlines / txt_matches_rows
# プランの本文は出さない。
analyze_rows_and_txt() {
  python3 - "$1" "$2" <<'PYEOF'
import json, sys
results_path, txt_path = sys.argv[1], sys.argv[2]
rows = header = trailing = ctype = prec = "-"
values = None
try:
    rs = json.load(open(results_path))["ResultSet"]
    data = rs.get("Rows", [])
    values = [(r.get("Data") or [{}])[0].get("VarCharValue") for r in data]
    rows = str(len(values))
    header = "yes" if values and values[0] == "Query Plan" else ("no" if values else "-")
    n = 0
    for v in reversed(values):
        if v in (None, ""): n += 1
        else: break
    trailing = str(n)
    cols = rs.get("ResultSetMetadata", {}).get("ColumnInfo", [])
    if cols:
        ctype = cols[0].get("Type", "-"); prec = str(cols[0].get("Precision", "-"))
except Exception:
    pass
lines = tnl = match = "-"
try:
    txt = open(txt_path, "rb").read().decode("utf-8")
    lines = str(txt.count("\n"))
    k = 0
    for ch in reversed(txt):
        if ch == "\n": k += 1
        else: break
    tnl = str(k)
    if values is not None:
        joined = "\n".join("" if v is None else v for v in values) + "\n"
        if txt == joined: match = "yes(rows+\\n)"
        elif txt == "\n".join("" if v is None else v for v in values): match = "yes(rows, no final \\n)"
        else: match = "no"
except FileNotFoundError:
    pass
except Exception:
    lines = tnl = match = "unreadable"
print("\t".join([rows, header, trailing, ctype, prec, lines, tnl, match]))
PYEOF
}

get_state_once() {
  aws athena get-query-execution --region "$REGION" --query-execution-id "$1" \
    --query QueryExecution.Status.State --output text 2>/dev/null
}
poll_until_terminal() {
  local id=$1 waited=0 state=""
  while [ "$waited" -lt "$POLL_TIMEOUT" ]; do
    state=$(get_state_once "$id")
    case "$state" in SUCCEEDED | FAILED | CANCELLED) break ;; esac
    state=""; sleep 1; waited=$((waited + 1))
  done
  printf '%s' "${state:-TIMEOUT}"
}
start_query_retry() {
  local label=$1 sql=$2 attempt=1 id
  while :; do
    echo "$label" >> "$START_CALL_FILE"
    id=$(aws athena start-query-execution --region "$REGION" \
      --query-string "$sql" \
      --query-execution-context "Catalog=$CATALOG,Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" \
      --query QueryExecutionId --output text 2> "$RUN_DIR/$label.start.err")
    echo "$attempt" > "$RUN_DIR/.tmp-attempts-$label"
    if [ -n "${id:-}" ]; then printf '%s' "$id"; return 0; fi
    if [ "$attempt" -ge "$RETRY_MAX" ] || ! is_transient_error "$RUN_DIR/$label.start.err"; then return 1; fi
    echo "== $label: 一時的な失敗とみて ${RETRY_DELAY} 秒後に再試行します（試行 $attempt/$RETRY_MAX）" >&2
    sleep "$RETRY_DELAY"; attempt=$((attempt + 1))
  done
}

run() {
  local label=$1 sql=$2
  local id state stype sub loc shape note attempts
  local txt_bytes meta_bytes analysis

  printf '%s\n' "$sql" > "$RUN_DIR/$label.sql"
  id=$(start_query_retry "$label" "$sql")
  attempts=$(cat "$RUN_DIR/.tmp-attempts-$label" 2>/dev/null || echo 0)
  if [ -z "${id:-}" ]; then
    note="attempts=$attempts; $(first_err_line "$RUN_DIR/$label.start.err")"
    echo "== $label: 開始できませんでした（試行 $attempts 回）。$RUN_DIR/$label.start.err を見てください"
    printf '%s\tSTART_FAILED\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t%s\n' "$label" "$(sanitize "$note")" >> "$SUMMARY"
    return 1
  fi

  state=$(poll_until_terminal "$id")
  aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.execution.json" 2> "$RUN_DIR/$label.execution.err"
  write_reason "$RUN_DIR/$label.execution.json" "$RUN_DIR/$label.reason.txt"
  aws athena get-query-results --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.results.json" 2> "$RUN_DIR/$label.results.err"

  IFS=$'\t' read -r stype sub loc < <(read_execution_fields "$RUN_DIR/$label.execution.json")
  shape=$(loc_shape_of "$loc" "$id")
  txt_bytes="-"; meta_bytes="-"
  if [ -n "$loc" ]; then
    { aws s3 ls "$loc"; echo "# rc=$?"; aws s3 ls "$loc.metadata"; echo "# rc=$?"; } > "$RUN_DIR/$label.ls.txt" 2>&1
    if fetch "$loc" "$RUN_DIR/$label.bytes" "$RUN_DIR/$label.cp.err"; then
      od -c "$RUN_DIR/$label.bytes" > "$RUN_DIR/$label.od.txt"
      txt_bytes=$(wc -c < "$RUN_DIR/$label.bytes" | tr -d ' ')
    fi
    if fetch "$loc.metadata" "$RUN_DIR/$label.metadata.bytes" "$RUN_DIR/$label.metadata.cp.err"; then
      meta_bytes=$(wc -c < "$RUN_DIR/$label.metadata.bytes" | tr -d ' ')
    fi
  fi
  analysis=$(analyze_rows_and_txt "$RUN_DIR/$label.results.json" "$RUN_DIR/$label.bytes")
  IFS=$'\t' read -r rows header trailing ctype prec lines tnl match <<< "$analysis"

  note="attempts=$attempts"
  case "$state" in FAILED | CANCELLED) note="$note; $(error_codes_of "$RUN_DIR/$label.execution.json")" ;; esac
  if [ -s "$RUN_DIR/$label.results.err" ]; then
    note="$note; results: $(first_err_line "$RUN_DIR/$label.results.err")"
  fi

  echo "== $label  state=$state  $stype/$sub  loc=$shape  txt=${txt_bytes}B(lines=$lines, trailing \\n=$tnl)  rows=$rows(header=$header, trailing empty=$trailing)  type=$ctype($prec)  txt==rows: $match"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$label" "$state" "$stype" "$sub" "$shape" "$txt_bytes" "$lines" "$tnl" "$meta_bytes" \
    "$rows" "$header" "$trailing" "$ctype" "$prec" "$match" "$(sanitize "$note")" >> "$SUMMARY"
  [ "$state" = SUCCEEDED ]
}

# --- preflight ---------------------------------------------------------------
if ! run probe-show-tables "SHOW TABLES"; then
  echo
  echo "SHOW TABLES が通りませんでした。DB か CATALOG の指定が実在しないか、認証情報がありません。"
  echo "理由: $RUN_DIR/probe-show-tables.reason.txt / $RUN_DIR/probe-show-tables.start.err"
  exit 1
fi

# --- 本編 --------------------------------------------------------------------
run e1 "EXPLAIN SELECT 1"
run e2 "EXPLAIN (FORMAT JSON) SELECT 1"
run e3 "EXPLAIN (TYPE IO) SELECT 1"
run e4 "EXPLAIN ANALYZE SELECT 1"
run e5 "EXPLAIN (TYPE DISTRIBUTED) SELECT 1"
run e6 "EXPLAIN (TYPE VALIDATE) SELECT 1"
run e7 "EXPLAIN (FORMAT GRAPHVIZ) SELECT 1"
run e8 "EXPLAIN ANALYZE VERBOSE SELECT 1"
run f1 "EXPLAIN SELECT * FROM athena_local_no_such_table_92"
run f2 "EXPLAIN ANALYZE SELECT * FROM athena_local_no_such_table_92"

# --- summary -----------------------------------------------------------------
{
  echo "# issue #92: EXPLAIN の変種の Rows の分け方と <id>.txt（対照 e1 = EXPLAIN SELECT 1）"
  echo "# 実行日時: $(date -Iseconds)"
  echo "# StartQueryExecution を呼んだ回数（再試行込み）: $(wc -l < "$START_CALL_FILE" | tr -d ' ')"
  echo "# DDL: 無し。テーブルのスキャン: 無し。"
  echo "# 注意: 実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。ワークグループの設定は既定とは限らない。"
  echo
  echo "## 投げた文"
  for label in probe-show-tables $LABELS; do
    [ -s "$RUN_DIR/$label.sql" ] && echo "- $label: $(sanitize "$(redact "$(cat "$RUN_DIR/$label.sql")")")"
  done
  echo
  echo "## 項目ごとの結果"
  echo "#   loc_shape              OutputLocation の末尾の形"
  echo "#   txt_bytes/lines        <id>.txt のバイト数と \\n の数。txt_trailing_newlines は末尾に連続する \\n の数"
  echo "#   rows                   GetQueryResults の Rows の数（列名行を含む）。header_row は先頭が Query Plan か"
  echo "#   trailing_empty_rows    Rows の末尾に連続する空の行（VarCharValue が空か無い）の数"
  echo "#   column_type/precision  ColumnInfo[0] の Type と Precision"
  echo "#   txt_matches_rows       .txt が「Rows を \\n で連結 + \\n」と一致するか（athena-local はこの形で書く）"
  python3 - "$SUMMARY" <<'PYEOF'
import csv, sys
with open(sys.argv[1], newline="") as f:
    for row in csv.DictReader(f, delimiter="\t"):
        print("- {label}: state={state} {statement_type}/{substatement_type} loc={loc_shape} "
              "txt={txt_bytes}B(lines={txt_lines}, trailing_nl={txt_trailing_newlines}) metadata={metadata_bytes}B "
              "rows={rows}(header={header_row}, trailing_empty={trailing_empty_rows}) "
              "type={column_type}({precision}) txt_matches_rows={txt_matches_rows} note={note}".format(**row))
PYEOF
  echo
  echo "## Rows の末尾 3 行と先頭 2 行の形（本文は伏せ、空か非空かと長さだけ）"
  python3 - "$RUN_DIR" "$LABELS" <<'PYEOF'
import json, os, sys
run_dir, labels = sys.argv[1], sys.argv[2].split()
for label in labels:
    p = os.path.join(run_dir, label + ".results.json")
    try:
        rows = json.load(open(p))["ResultSet"]["Rows"]
    except Exception:
        print("- %s: (results.json を読めない)" % label); continue
    vals = [(r.get("Data") or [{}])[0].get("VarCharValue") for r in rows]
    def shape(v): return "absent" if v is None else ("empty" if v == "" else "len=%d" % len(v))
    head = [shape(v) for v in vals[:2]]
    tail = [shape(v) for v in vals[-3:]]
    print("- %s: head=%s ... tail=%s" % (label, head, tail))
PYEOF
  echo
  echo "## 失敗した項目の理由（DB 名を含みうるので貼る前に確認すること）"
  for label in $LABELS; do
    if [ -s "$RUN_DIR/$label.reason.txt" ] && ! grep -q "^State: SUCCEEDED" "$RUN_DIR/$label.reason.txt"; then
      echo "### $label"; redact "$(cat "$RUN_DIR/$label.reason.txt")"; echo
    fi
  done
} > "$RUN_DIR/summary.txt"

echo
echo "完了しました。"
echo "そのまま貼れる整形済みの一覧: $RUN_DIR/summary.txt"
echo "中身のファイルは $RUN_DIR にあります。リポジトリには入れないでください。"
