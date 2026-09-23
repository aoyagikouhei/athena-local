#!/usr/bin/env bash
# issue #26 で作成（tools/ へ移す前の名前は 26-measure-iceberg-detection.sh）
# 本物の Athena で、CTAS の OutputLocation（`tables/<id>` か `<id>` か）が
# 「SQL の文字列のどこに table_type='ICEBERG' が現れるか」でどう変わるかを実測する。
# issue #26（is_iceberg_table がコメントと文字列リテラルの中の table_type='ICEBERG' も数える）
# のための実測スクリプト。#17 の leading-comment.sh を雛形にしている。
#
# 測りたいこと（athena-local は今どれも「Iceberg（`<id>`）」と判定する）:
#   B  コメントの中に table_type='ICEBERG' がある Hive の CTAS
#   C  文字列リテラルの中に table_type='ICEBERG' がある Hive の CTAS
#   F  WITH 句の外（WHERE 句）に table_type = 'ICEBERG' がある Hive の CTAS
# 対照として、素の Hive の CTAS（A）と、WITH 句で Iceberg を指定した CTAS（D）、
# WITH 句の中にコメントを挟んだ Iceberg の CTAS（E。athena-local は今これを Hive と判定する）も測る。
#
# 使い方:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db bash tools/measure/ctas-iceberg-detection.sh
#   （資格情報はホストのシェルで AWS_ACCESS_KEY_ID などを export してから。または ~/.aws/credentials）
#
# 必要な環境変数:
#   OUTPUT    結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける）。
#   DB        データベース名。実在するものを指定する。
#
# 任意の環境変数:
#   CATALOG      既定 AwsDataCatalog
#   REGION       既定 ap-northeast-1
#   OUT_DIR      既定 ${DEV_HOST_HOME:-$HOME}/athena-iceberg-measurements（実名が入るのでリポジトリの外に出す）
#   POLL_TIMEOUT 終端状態を待つ上限（秒）。既定 180
#   RETRY_MAX    名前解決・接続など一時的な失敗を再試行する回数の上限。既定 4
#   RETRY_DELAY  再試行の間隔（秒）。既定 5
#   PROBE_DDL    既定 1（測る）。**この実測は CTAS そのものが対象なので、既定でテーブルを作る。**
#                0 にすると CTAS 群を全部 skip する（対照も含めて何も測れない）。
#
# ** このスクリプトが本物に対して行う破壊的な操作 **
#   <db>.athena_local_probe_26_a 〜 _f の 6 テーブルを CREATE TABLE AS SELECT で作り、
#   最後に DROP TABLE IF EXISTS で消す（異常終了時も trap で消しにいく）。
#   同名のテーブルが既にあると壊すので、開始前に SHOW TABLES で存在を確かめ、
#   1 件でもあればテーブルを作らずに止まる。
#   Hive の CTAS（A/B/C/F）のデータは Athena の既定で $OUTPUT の下の tables/<id>/ に置かれ、
#   DROP TABLE では消えない（外部テーブルのため）。残った key の一覧を cleanup-hints.txt に
#   書き出すので、消したければそれを見て手で消すこと。
#   Iceberg の CTAS（D/E）は location を $OUTPUT の下の tables-probe-26-<label>/ に指定し、
#   is_external = false にしてあるので DROP TABLE でデータも消える。
#
# 課金について: SELECT 1 と VALUES だけで、S3 も実テーブルも一切スキャンしない
# （SELECT * を実テーブルに投げる項目は無い）。Athena の最小課金（10MB 相当）× クエリ数の見込み。
# StartQueryExecution を呼んだ回数は summary.txt の冒頭に実測値を出す。
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く。前の回の結果と混ざらない。
#
# S3 からの取得は `aws s3 cp <src> -` で標準出力に流し、リダイレクトはこのシェルが行う。
# aws が Docker のラッパだと、コンテナにマウントされるのは実行時のカレントディレクトリだけで、
# 絶対パスを渡すとコンテナの中に書かれて消える。しかも終了コードは 0 になる。
#
# 文ごとに次を保存する（取れたものだけ）。
#   <label>.sql                投げた SQL そのもの（**DB 名を含む**）
#   <label>.start.err          StartQueryExecution の標準エラー（開始自体が失敗した証拠）
#   <label>.execution.json     GetQueryExecution の応答（OutputLocation はここから読む）
#   <label>.execution.err      GetQueryExecution の標準エラー
#   <label>.reason.txt         StateChangeReason と AthenaError（**実名を含みうる。貼る前に確認**）
#   <label>.ls.txt             本体と .metadata の有無（aws s3 ls の結果そのまま）
#   <label>.metadata.bytes     .metadata の中身そのもの（無ければ作らない）
#   <label>.metadata.od.txt    上を 16 進で見たもの（protobuf なので）
#   <label>.keys.txt           OutputLocation の周辺で <id> を含む key の一覧
#   <label>.show-create.*      作られたテーブルの SHOW CREATE TABLE（実際に Iceberg になったかの裏取り）
#
# summary の決め手になる列は loc_shape で、OutputLocation の末尾の形だけを出す。
# バケット名・プレフィックス・クエリ ID は出さず、`tables/<id>`／`<id>`／`<id>.csv`／
# `<id>.txt`／other のどれかに畳む。table_format 列は SHOW CREATE TABLE の本文に
# table_type='iceberg' が（大文字小文字を無視して）現れたかで iceberg / hive に畳む。
# どちらも実名を含まないので、summary.txt はそのまま貼れる。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください}"
: "${DB:?DB にデータベース名を設定してください}"
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_DIR=${OUT_DIR:-${DEV_HOST_HOME:-$HOME}/athena-iceberg-measurements}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}
PROBE_DDL=${PROBE_DDL:-1}

PREFIX=athena_local_probe_26
LABELS="a b c d e f"

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\tstatement_type\tloc_shape\tmetadata_bytes\ttable_format\tkeys\tnote\n' > "$SUMMARY"
echo "出力先: $RUN_DIR"

# StartQueryExecution を実際に呼んだ回数（再試行も含む）。summary.txt の冒頭に出す。
START_CALL_COUNT=0
# テーブル作成に着手したかどうか。trap での後始末に使う。
CTAS_ATTEMPTED=0

# 生ログの中間ファイルは、途中で止めても残らないよう trap で消す。
# テーブル作成に着手していたら、ベストエフォートで DROP も投げる
# （本編の Z 群でも消すので、これは異常終了時の保険）。
cleanup() {
  rm -f "$RUN_DIR"/.tmp-*
  if [ "$CTAS_ATTEMPTED" = 1 ]; then
    for label in $LABELS; do
      aws athena start-query-execution --region "$REGION" \
        --query-string "DROP TABLE IF EXISTS $DB.${PREFIX}_$label" \
        --query-execution-context "Catalog=$CATALOG,Database=$DB" \
        --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
    done
  fi
}
trap cleanup EXIT

# 実名（DB 名）を note から置換して隠す。
redact() {
  local s=$1
  s=${s//$DB/<DB>}
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
# これがこの実測の決め手の値になる。
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

# OutputLocation の周辺を一覧し、<id> を含む key を全部書き出す。件数を返す（標準出力）。
list_keys() {
  local label=$1 id=$2 loc=$3
  local parent="${loc%/*}/"
  local raw="$RUN_DIR/$label.ls.raw.txt"
  : > "$raw"
  { echo "# ls $OUTPUT"; aws s3 ls "$OUTPUT"; } >> "$raw" 2>&1
  if [ "$parent" != "$OUTPUT" ]; then
    { echo "# ls $parent"; aws s3 ls "$parent"; } >> "$raw" 2>&1
  fi
  { echo "# ls $loc/"; aws s3 ls "$loc/"; } >> "$raw" 2>&1
  grep -F -- "$id" "$raw" > "$RUN_DIR/$label.keys.txt" 2>/dev/null
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
# （実際の SQL エラーは 1 回で確定させる）。試行回数は LAST_ATTEMPTS に残す。
LAST_ATTEMPTS=0
start_query_retry() {
  local label=$1 sql=$2
  local attempt=1 id
  while :; do
    START_CALL_COUNT=$((START_CALL_COUNT + 1))
    id=$(aws athena start-query-execution --region "$REGION" \
      --query-string "$sql" \
      --query-execution-context "Catalog=$CATALOG,Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" \
      --query QueryExecutionId --output text 2> "$RUN_DIR/$label.start.err")
    if [ -n "${id:-}" ]; then
      LAST_ATTEMPTS=$attempt
      printf '%s' "$id"
      return 0
    fi
    if [ "$attempt" -ge "$RETRY_MAX" ] || ! is_transient_error "$RUN_DIR/$label.start.err"; then
      LAST_ATTEMPTS=$attempt
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
  printf '%s\tSKIPPED\t-\t-\t-\t-\t-\t%s\n' "$label" "$(sanitize "$note")" >> "$SUMMARY"
}

# ラベルを指定して 1 文を実行し、終端状態まで待って OutputLocation の形などを採取する。
# 成功したときだけ 0 を返す。
run() {
  local label=$1 sql=$2 want_keys=${3:-}
  local id state stype loc shape meta_size note keys

  printf '%s\n' "$sql" > "$RUN_DIR/$label.sql"
  id=$(start_query_retry "$label" "$sql")
  if [ -z "${id:-}" ]; then
    note="attempts=$LAST_ATTEMPTS; $(first_err_line "$RUN_DIR/$label.start.err")"
    echo "== $label: 開始できませんでした（試行 $LAST_ATTEMPTS 回）。$RUN_DIR/$label.start.err を見てください"
    printf '%s\tSTART_FAILED\t-\t-\t-\t-\t-\t%s\n' "$label" "$(sanitize "$note")" >> "$SUMMARY"
    return 1
  fi

  state=$(poll_until_terminal "$id")

  aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.execution.json" 2> "$RUN_DIR/$label.execution.err"
  write_reason "$RUN_DIR/$label.execution.json" "$RUN_DIR/$label.reason.txt"

  IFS=$'\t' read -r stype loc < <(read_execution_fields "$RUN_DIR/$label.execution.json")
  shape=$(loc_shape_of "$loc" "$id")
  meta_size="none"; keys="-"

  if [ -n "$loc" ]; then
    { echo "# ls $loc"; aws s3 ls "$loc"; echo "# rc=$?"
      echo "# ls $loc.metadata"; aws s3 ls "$loc.metadata"; echo "# rc=$?"
    } > "$RUN_DIR/$label.ls.txt" 2>&1
    if fetch "$loc.metadata" "$RUN_DIR/$label.metadata.bytes" "$RUN_DIR/$label.metadata.cp.err"; then
      od -tx1c "$RUN_DIR/$label.metadata.bytes" > "$RUN_DIR/$label.metadata.od.txt"
      meta_size=$(wc -c < "$RUN_DIR/$label.metadata.bytes")
    fi
    if [ -n "$want_keys" ]; then
      keys=$(list_keys "$label" "$id" "$loc")
    fi
  fi

  note="attempts=$LAST_ATTEMPTS"
  case "$state" in
    FAILED | CANCELLED) note="$note; $(error_codes_of "$RUN_DIR/$label.execution.json")" ;;
  esac

  echo "== $label  state=$state  stype=$stype  loc_shape=$shape  metadata=$meta_size  keys=$keys"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$label" "$state" "$stype" "$shape" "$meta_size" "-" "$keys" "$(sanitize "$note")" >> "$SUMMARY"
  [ "$state" = SUCCEEDED ]
}

# 作られたテーブルが本当に Iceberg になったかを SHOW CREATE TABLE で裏取りし、
# summary.tsv の table_format 列を iceberg / hive に埋める。
# 本文（DB 名・S3 のパスを含む）はファイルにだけ残し、summary には形だけを出す。
record_table_format() {
  local label=$1 id state loc fmt="unknown"
  id=$(start_query_retry "$label-show-create" "SHOW CREATE TABLE $DB.${PREFIX}_$label")
  if [ -n "${id:-}" ]; then
    state=$(poll_until_terminal "$id")
    aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
      > "$RUN_DIR/$label.show-create.execution.json" 2>/dev/null
    IFS=$'\t' read -r _ loc < <(read_execution_fields "$RUN_DIR/$label.show-create.execution.json")
    if [ "$state" = SUCCEEDED ] && [ -n "$loc" ] \
      && fetch "$loc" "$RUN_DIR/$label.show-create.txt" "$RUN_DIR/$label.show-create.err"; then
      if grep -qi "table_type'*=*'*iceberg" "$RUN_DIR/$label.show-create.txt"; then
        fmt=iceberg
      else
        fmt=hive
      fi
    fi
  fi
  # summary.tsv の当該行の table_format 列（6 列目）を埋める。
  python3 - "$SUMMARY" "$label" "$fmt" <<'PYEOF'
import sys
path, label, fmt = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines()
for i, line in enumerate(lines):
    cols = line.split("\t")
    if cols[0] == label and len(cols) >= 6:
        cols[5] = fmt
        lines[i] = "\t".join(cols)
open(path, "w").write("\n".join(lines) + "\n")
PYEOF
  echo "== $label: table_format=$fmt（SHOW CREATE TABLE で確認）"
}

# --- preflight ---------------------------------------------------------------

# まず指定のデータベースが実在するかを確かめる。
# ここが通らないと、以降の CTAS はすべて Entity Not Found で落ちる。
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

IFS=$'\t' read -r _ SHOW_TABLES_LOC < <(read_execution_fields "$RUN_DIR/probe-show-tables.execution.json")
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
    skip "$label-ctas" "PROBE_DDL=0 のため未測定（この実測は CTAS そのものが対象なので、何も測れない）"
  done
  echo "PROBE_DDL=0 のため CTAS を測らずに終わります。"
  exit 0
fi

# --- 本編 --------------------------------------------------------------------

CTAS_ATTEMPTED=1

# A. 対照: 素の Hive の CTAS。`tables/<id>` になるはず（2026-09-14 実測済み）。
run a "CREATE TABLE $DB.${PREFIX}_a AS SELECT 1 AS i" keys

# B. コメントの中に table_type='ICEBERG'。テーブル自体は Hive。
run b "CREATE TABLE $DB.${PREFIX}_b AS SELECT 1 AS i -- table_type = 'ICEBERG'" keys

# C. 文字列リテラルの中に table_type='ICEBERG'。テーブル自体は Hive。
run c "CREATE TABLE $DB.${PREFIX}_c AS SELECT 'table_type=''ICEBERG''' AS s" keys

# D. 対照: WITH 句で Iceberg。`<id>` になるはず（2026-09-17 実測済み）。
run d "CREATE TABLE $DB.${PREFIX}_d WITH (table_type = 'ICEBERG', location = '${OUTPUT}tables-probe-26-d/', is_external = false) AS SELECT 1 AS i" keys

# E. WITH 句の中の `table_type` と `=` の間にブロックコメント。テーブルは Iceberg のはず。
#    athena-local は今これを Hive と判定する（空白を潰した全文検索なのでコメントが邪魔になる）。
run e "CREATE TABLE $DB.${PREFIX}_e WITH (table_type /* c */ = 'ICEBERG', location = '${OUTPUT}tables-probe-26-e/', is_external = false) AS SELECT 1 AS i" keys

# F. WITH 句の外（WHERE 句）に table_type = 'ICEBERG'。テーブル自体は Hive。
#    コメントと文字列リテラルを読み飛ばすだけの直し方では救えない形なので、
#    docs/caveats.md にどう書くかがこの結果で決まる。
run f "CREATE TABLE $DB.${PREFIX}_f AS SELECT * FROM (VALUES ('HIVE')) AS t(table_type) WHERE t.table_type = 'ICEBERG'" keys

# 作られたテーブルの実際の形式を裏取りする（CTAS が成功したものだけ）。
for label in $LABELS; do
  if awk -F'\t' -v l="$label" '$1 == l && $2 == "SUCCEEDED" { found = 1 } END { exit !found }' "$SUMMARY"; then
    record_table_format "$label"
  fi
done

# Z. 後始末。CTAS が失敗していても IF EXISTS なので安全に呼べる。
for label in $LABELS; do
  run "z-drop-$label" "DROP TABLE IF EXISTS $DB.${PREFIX}_$label"
done

# ここまで来れば Z 群で DROP を投げ終えているので、trap での二度目の DROP は要らない。
CTAS_ATTEMPTED=0

# Hive の CTAS が $OUTPUT の下に残したデータの key を、消すためのヒントとして残す。
# バケット名・プレフィックスを含むので summary.txt には入れない。
{
  echo "# Hive の CTAS（A/B/C/F）のデータは DROP TABLE では消えません。"
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
    echo "# issue #26: CTAS の OutputLocation が table_type='ICEBERG' の出現場所でどう変わるかの実測"
    echo "# 実行日時: $(date -Iseconds)"
    echo "# StartQueryExecution を呼んだ回数（一時的な失敗の再試行込み）: $START_CALL_COUNT"
    echo "#   ※ GetQueryExecution / S3 への呼び出しはこの回数に含めない（課金には影響しない）。"
    echo "# DDL: あり（${PREFIX}_a 〜 _f の 6 テーブルを CTAS で作成→DROP）"
    echo "# 課金: SELECT 1 と VALUES だけで、S3 も実テーブルもスキャンしていない。"
    echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
    echo
    echo "## 投げた文（DB 名は <DB> に置換）"
    for label in $LABELS; do
      [ -s "$RUN_DIR/$label.sql" ] && echo "- $label: $(sanitize "$(redact "$(cat "$RUN_DIR/$label.sql")")")"
    done
    echo
    echo "## 項目ごとの結果"
    echo "#   loc_shape   OutputLocation の末尾の形（tables/<id> なら Hive 扱い、<id> なら Iceberg 扱い）"
    echo "#   table_format SHOW CREATE TABLE で見た実際のテーブル形式"
    python3 - "$SUMMARY" <<'PYEOF'
import csv, sys
with open(sys.argv[1], newline="") as f:
    for row in csv.DictReader(f, delimiter="\t"):
        print(
            "- {label}: state={state} statement_type={statement_type} loc_shape={loc_shape} "
            "metadata_bytes={metadata_bytes} table_format={table_format} keys={keys} note={note}".format(**row)
        )
PYEOF
    echo
    echo "## 失敗した項目の理由（実名を含みうるので貼る前に確認すること）"
    for label in $LABELS; do
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
