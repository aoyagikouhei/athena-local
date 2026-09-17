#!/usr/bin/env bash
# 本物の Athena で、先頭にコメントが付いた SQL の StatementType / SubstatementType /
# OutputLocation のファイル名 / 本体と .metadata の有無・Content-Type / UpdateCount を実測する。
# issue #17（先頭にコメントが付いた SQL の文の種類を正しく判定する）のための実測スクリプト。
#
# 使い方:
#   OUTPUT=s3://your-bucket/prefix/ DB=your_db bash 17-measure-leading-comment.sh
#
# 必要な環境変数:
#   OUTPUT    結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける）。
#   DB        データベース名。実在するものを指定する。
#
# 任意の環境変数:
#   TABLE       省略すると SHOW TABLES の 1 件目を使う。1 件も無ければ DESCRIBE の項目だけ
#               未測定にして続ける（全体は止めない）。
#   CATALOG     既定 AwsDataCatalog
#   REGION      既定 ap-northeast-1
#   OUT_DIR     既定 $HOME/athena-comment-measurements（実名が入るのでリポジトリの外に出す）
#   POLL_TIMEOUT 終端状態を待つ上限（秒）。既定 180
#   RETRY_MAX   名前解決・接続など一時的な失敗を再試行する回数の上限。既定 4
#   RETRY_DELAY 再試行の間隔（秒）。既定 5
#   PROBE_DDL   1 にすると F 群（CTAS / INSERT）も測る。
#               **テーブル <db>.athena_local_probe_17 / athena_local_probe_17b を作って、
#               最後に必ず消す。** 同名のテーブルが既にあると壊すので、無いことを
#               確かめてから 1 にすること。データの置き場所は OUTPUT の下
#               （tables-probe-17/、tables-probe-17b/）。
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く。前の回の結果と混ざらない。
#
# ** SQL に改行を含める書き方の注意 **
# 「-- c\nSELECT 1」のような文は、シェルで実際の改行文字（0x0a）にしてから渡さないと、
# 「-- c」と「\」「n」「SELECT 1」という 1 行の文字列になってしまい、まったく別の測定に
# なる。そのため、この中では bash の ANSI-C quoting（$'...'）を使う。
#   良い例: run label $'-- c\nSELECT 1'                    # 改行文字になる
#   悪い例: run label "-- c\nSELECT 1"                     # \n の 2 文字のまま
# ただし $'...' は変数展開をしない（バックスラッシュのエスケープだけを解釈する）ので、
# $DB や $OUTPUT を埋め込みたい行（F 群の CTAS / INSERT）は、
#   $'-- c\n'"CREATE TABLE $DB.foo ..."
# のように、改行だけを ANSI-C quoting の断片で作り、変数展開が要る残りを普通の
# ダブルクオート文字列で続けて、隣り合わせて連結する（bash は隣接する引用文字列を
# 1 つの単語に連結する）。
#
# S3 からの取得は `aws s3 cp <src> -` で標準出力に流し、リダイレクトはこのシェルが行う。
# aws が Docker のラッパだと、コンテナにマウントされるのは実行時のカレントディレクトリだけで、
# 絶対パスを渡すとコンテナの中に書かれて消える。しかも終了コードは 0 になる。
#
# 課金について: 既定はすべてスキャンしない計算だけのクエリ（SELECT 1 等）か、
# メタデータだけを見る SHOW / DESCRIBE / EXPLAIN。実テーブルを読むのは DESCRIBE だけで、
# SELECT * は使わない。PROBE_DDL=1 でも小さな Iceberg テーブルを 2 つ作って消すだけ。
# 呼び出し回数と DDL の有無は summary.txt の冒頭に実測した回数を書く。
#
# 文ごとに次を保存する（fetch できたものだけ）。
#   <label>.start.err          StartQueryExecution の標準エラー（開始自体が失敗した証拠）
#   <label>.execution.json     GetQueryExecution の応答
#   <label>.execution.err      GetQueryExecution の標準エラー
#   <label>.reason.txt         StateChangeReason と AthenaError（**実名を含みうる。貼る前に確認**）
#   <label>.results.json       GetQueryResults の応答（UpdateCount はここから読む）
#   <label>.results.err        GetQueryResults の標準エラー
#   <label>.ls.txt              本体と .metadata の有無（aws s3 ls の結果そのまま）
#   <label>.bytes               結果ファイルの中身そのもの
#   <label>.od.txt               上をバイト単位で見たもの
#   <label>.metadata.bytes       .metadata の中身そのもの（無ければ作らない）
#   <label>.metadata.od.txt      上を 16 進で見たもの（protobuf なので）
#   <label>.head.json / .head.err                 本体の head-object（Content-Type）
#   <label>.metadata.head.json / .metadata.head.err  .metadata の head-object
#   <label>.keys.txt            OutputLocation の周辺で <id> を含む key の一覧（CTAS/INSERT のみ）
#
# 最後に summary.tsv（機械可読）と summary.txt（そのまま貼れる整形済み）を作る。
# 実名は summary には出さない（DB 名・テーブル名は note に混じらないよう置換している）。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください}"
: "${DB:?DB にデータベース名を設定してください}"
TABLE=${TABLE:-}
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
OUT_DIR=${OUT_DIR:-$HOME/athena-comment-measurements}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}
PROBE_DDL=${PROBE_DDL:-0}

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\tstatement_type\tsubstatement_type\text\tbytes\tmetadata_bytes\tcontent_type\tmetadata_content_type\tupdate_count\tnote\n' > "$SUMMARY"
echo "出力先: $RUN_DIR"

# StartQueryExecution を実際に呼んだ回数（再試行も含む）。summary.txt の冒頭に出す。
START_CALL_COUNT=0
# F 群でテーブル作成に着手したかどうか。trap での後始末に使う。
CTAS_ATTEMPTED=0

# 生ログや中間ファイルは、途中で止めても残らないよう trap で消す。
# PROBE_DDL=1 でテーブル作成に着手していたら、ベストエフォートで DROP も投げる
# （本編でも f-drop-line / f-drop-block で消すので、これは異常終了時の保険）。
cleanup() {
  rm -f "$RUN_DIR"/.tmp-*
  if [ "$PROBE_DDL" = 1 ] && [ "$CTAS_ATTEMPTED" = 1 ]; then
    aws athena start-query-execution --region "$REGION" \
      --query-string "DROP TABLE IF EXISTS $DB.athena_local_probe_17" \
      --query-execution-context "Catalog=$CATALOG,Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
    aws athena start-query-execution --region "$REGION" \
      --query-string "DROP TABLE IF EXISTS $DB.athena_local_probe_17b" \
      --query-execution-context "Catalog=$CATALOG,Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# 実名（DB 名・テーブル名）を note から置換して隠す。値そのものが無ければ何もしない。
redact() {
  local s=$1
  s=${s//$DB/<DB>}
  if [ -n "$TABLE" ]; then
    s=${s//$TABLE/<TABLE>}
  fi
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

# head-object の応答を手元のファイルに取る。src は s3://bucket/key の形。
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

# execution.json から StateChangeReason と AthenaError を取り出してファイルに書く。
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

# AthenaError の ErrorCategory / ErrorType（数値コードだけ。実名を含まない）を返す。
# 無ければ "-"。
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

# OutputLocation の周辺を一覧し、<id> を含む key を全部書き出す。件数を返す（標準出力）。
# 5-measure-metadata.sh の list_keys をそのまま流用（CTAS / INSERT 用）。
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
  printf '%s\tSKIPPED\t-\t-\t-\t-\t-\t-\t-\t-\t%s\n' "$label" "$(sanitize "$note")" >> "$SUMMARY"
}

# ラベルを指定して 1 文を実行し、終端状態まで待って StatementType 等を採取する。
# 第 3 引数に keys を渡すと OutputLocation の周辺の key も一覧する（CTAS / INSERT 用）。
# 成功したときだけ 0 を返す。失敗する文をわざと投げる項目も多いので、呼び出し側の
# ほとんどは戻り値を見ない。
run() {
  local label=$1 sql=$2 want_keys=${3:-}
  local id state stype sstype loc ext size meta_size ctype mctype ucount note keys

  id=$(start_query_retry "$label" "$sql")
  if [ -z "${id:-}" ]; then
    note="attempts=$LAST_ATTEMPTS; $(first_err_line "$RUN_DIR/$label.start.err")"
    if ! grep -q "An error occurred" "$RUN_DIR/$label.start.err" 2>/dev/null; then
      note="$note; CLI が送信前に拒否した可能性"
    fi
    echo "== $label: 開始できませんでした（試行 $LAST_ATTEMPTS 回）。$RUN_DIR/$label.start.err を見てください"
    printf '%s\tSTART_FAILED\t-\t-\t-\t-\t-\t-\t-\t-\t%s\n' "$label" "$(sanitize "$note")" >> "$SUMMARY"
    return 1
  fi

  state=$(poll_until_terminal "$id")

  aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.execution.json" 2> "$RUN_DIR/$label.execution.err"
  aws athena get-query-results --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.results.json" 2> "$RUN_DIR/$label.results.err"
  write_reason "$RUN_DIR/$label.execution.json" "$RUN_DIR/$label.reason.txt"

  IFS=$'\t' read -r stype sstype loc < <(read_execution_fields "$RUN_DIR/$label.execution.json")
  ucount=$(read_update_count "$RUN_DIR/$label.results.json")

  ext="-"; size="none"; meta_size="none"; ctype="-"; mctype="-"; keys="-"
  if [ -n "$loc" ]; then
    # 末尾のファイル名に . があれば拡張子、無ければ（CTAS の tables/<id> など）none。
    ext=${loc##*/}
    case "$ext" in *.*) ext=${ext#*.} ;; *) ext="none" ;; esac

    { echo "# ls $loc"; aws s3 ls "$loc"; echo "# rc=$?"
      echo "# ls $loc.metadata"; aws s3 ls "$loc.metadata"; echo "# rc=$?"
    } > "$RUN_DIR/$label.ls.txt" 2>&1

    if fetch "$loc" "$RUN_DIR/$label.bytes" "$RUN_DIR/$label.cp.err"; then
      od -c "$RUN_DIR/$label.bytes" > "$RUN_DIR/$label.od.txt"
      size=$(wc -c < "$RUN_DIR/$label.bytes")
    fi
    if head_object "$loc" "$RUN_DIR/$label.head.json" "$RUN_DIR/$label.head.err"; then
      ctype=$(content_type_of "$RUN_DIR/$label.head.json")
    fi
    if fetch "$loc.metadata" "$RUN_DIR/$label.metadata.bytes" "$RUN_DIR/$label.metadata.cp.err"; then
      od -tx1c "$RUN_DIR/$label.metadata.bytes" > "$RUN_DIR/$label.metadata.od.txt"
      meta_size=$(wc -c < "$RUN_DIR/$label.metadata.bytes")
    fi
    if head_object "$loc.metadata" "$RUN_DIR/$label.metadata.head.json" "$RUN_DIR/$label.metadata.head.err"; then
      mctype=$(content_type_of "$RUN_DIR/$label.metadata.head.json")
    fi

    if [ -n "$want_keys" ]; then
      keys=$(list_keys "$label" "$id" "$loc")
    fi
  fi

  note="attempts=$LAST_ATTEMPTS"
  case "$state" in
    FAILED | CANCELLED) note="$note; $(error_codes_of "$RUN_DIR/$label.execution.json")" ;;
  esac
  if [ "$keys" != "-" ]; then
    note="$note; keys=$keys"
  fi

  echo "== $label  state=$state  stype=$stype  sstype=$sstype  ext=$ext  bytes=$size  metadata=$meta_size  ct=$ctype  meta_ct=$mctype  update_count=$ucount"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$label" "$state" "$stype" "$sstype" "$ext" "$size" "$meta_size" "$ctype" "$mctype" "$ucount" "$(sanitize "$note")" >> "$SUMMARY"
  [ "$state" = SUCCEEDED ]
}

# まず指定のデータベースが実在するかを確かめる。
# ここが通らないと、以降の SHOW や DESCRIBE はすべて Entity Not Found で落ちる。
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

# テーブル名は SHOW TABLES の結果から取る。指定が無いか、一覧に無ければ 1 件目を使う。
# 名前は端末に出さず、ファイルに置くだけ。1 件も無くても全体は止めず、DESCRIBE の
# 項目だけを未測定にする。
python3 - "$RUN_DIR/probe-show-tables.results.json" "$RUN_DIR/tables.txt" <<'EOF'
import json, sys
rows = json.load(open(sys.argv[1]))["ResultSet"]["Rows"]
names = [r["Data"][0].get("VarCharValue", "") for r in rows if r.get("Data")]
open(sys.argv[2], "w").write("\n".join(names) + "\n")
EOF
if [ -z "$TABLE" ] || ! grep -qx -- "$TABLE" "$RUN_DIR/tables.txt"; then
  TABLE=$(head -1 "$RUN_DIR/tables.txt")
  echo "テーブルは SHOW TABLES の 1 件目を使います。一覧: $RUN_DIR/tables.txt"
fi

# A. 行コメント -- が先頭。
run a-line-select   $'-- c\nSELECT 1'
run a-line-show     $'-- c\nSHOW TABLES'
if [ -z "$TABLE" ]; then
  skip a-line-describe "このデータベースにテーブルが無いため DESCRIBE を測れない"
else
  run a-line-describe $'-- c\nDESCRIBE '"$TABLE"
fi
run a-line-explain    $'-- c\nEXPLAIN SELECT 1'
run a-line-create-db  $'-- c\nCREATE DATABASE IF NOT EXISTS athena_local_probe_17'
run a-line-drop-db    $'-- c\nDROP DATABASE IF EXISTS athena_local_probe_17'

# B. ブロックコメント /* */ が先頭。
run b-block-select    '/* c */ SELECT 1'
run b-block-show      '/* c */ SHOW TABLES'
run b-block-create-db '/* c */ CREATE DATABASE IF NOT EXISTS athena_local_probe_17'
run b-block-drop-db   '/* c */ DROP DATABASE IF EXISTS athena_local_probe_17'

# C. 決定的な検証（コメントの中のキーワードを本物が読むか）。実装の正解を決める。
run c-keyword-in-line       $'-- SELECT\nSHOW TABLES'
run c-keyword-in-block      '/* SELECT */ SHOW TABLES'
run c-block-keyword-reverse '/* SHOW TABLES */ SELECT 1'

# D. 空白・改行・連続・境界。
run d-blank-after      $'-- c\n\n   SELECT 1'
run d-two-line         $'-- a\n-- b\nSELECT 1'
run d-mixed            $'-- a\n/* b */ SELECT 1'
run d-no-space-line    $'--c\nSELECT 1'
run d-no-space-block   '/* c */SELECT 1'
run d-block-newline    $'/* a\nb */ SELECT 1'
run d-leading-space    '   SELECT 1'
run d-trailing-comment 'SELECT 1 -- c'

# E. 失敗系・境界。StartQueryExecution 自体が失敗する可能性が高いが、それも測定結果。
#    エラー全文は <label>.start.err（または .reason.txt）に残り、summary には短く出す。
run e-only-line     '-- only'
run e-only-block     '/* only */'
run e-unclosed-block  '/* c SELECT 1'
run e-empty ''

# F. CTAS と INSERT。テーブルを作って消すので PROBE_DDL=1 のときだけ。
if [ "$PROBE_DDL" = 1 ]; then
  CTAS_ATTEMPTED=1
  run f-line-ctas  $'-- c\n'"CREATE TABLE $DB.athena_local_probe_17 WITH (table_type = 'ICEBERG', location = '${OUTPUT}tables-probe-17/', is_external = false) AS SELECT 1 AS i" keys
  run f-block-ctas "/* c */ CREATE TABLE $DB.athena_local_probe_17b WITH (table_type = 'ICEBERG', location = '${OUTPUT}tables-probe-17b/', is_external = false) AS SELECT 1 AS i" keys
  run f-line-insert $'-- c\n'"INSERT INTO $DB.athena_local_probe_17 VALUES (2)" keys
  # 後始末。CTAS が失敗していても IF EXISTS なので安全に呼べる。
  run f-drop-line  "DROP TABLE IF EXISTS $DB.athena_local_probe_17"
  run f-drop-block "DROP TABLE IF EXISTS $DB.athena_local_probe_17b"
else
  skip f-line-ctas   "PROBE_DDL=0 のため未測定"
  skip f-block-ctas  "PROBE_DDL=0 のため未測定"
  skip f-line-insert "PROBE_DDL=0 のため未測定"
fi

# summary.txt を作る。summary.tsv を整形し、E 群のエラー文言（<label>.start.err /
# <label>.reason.txt）を短く添える。実名は redact 済みの note しか使わない。
write_summary_txt() {
  local txt="$RUN_DIR/summary.txt"
  {
    echo "# issue #17: 先頭にコメントが付いた SQL の文の種類の実測"
    echo "# 実行日時: $(date -Iseconds)"
    echo "# StartQueryExecution を呼んだ回数（一時的な失敗の再試行込み）: $START_CALL_COUNT"
    echo "#   ※ GetQueryExecution / GetQueryResults / S3 への呼び出しはこの回数に含めない"
    echo "#     （ポーリングのぶん多くなるが、課金には影響しない）。"
    if [ "$PROBE_DDL" = 1 ]; then
      echo "# DDL: あり（Iceberg テーブルを 2 件作成→削除。F 群のみ）"
    else
      echo "# DDL: テーブルの CREATE/DROP は無し（PROBE_DDL=0）。CREATE/DROP DATABASE のみ実行"
    fi
    echo "# 課金: 既定はスキャン無しの計算クエリ（SELECT 1 等）と SHOW / DESCRIBE / EXPLAIN。"
    echo "#       実テーブルを読むのは DESCRIBE のみで、SELECT * は使っていない。"
    echo "# 注意: 以下は実測した本物の Athena の挙動であり、athena-local の「工場出荷時の"
    echo "#       既定」ではない。将来の Athena の変更で変わりうる。"
    echo
    echo "## 項目ごとの結果"
    python3 - "$SUMMARY" <<'PYEOF'
import csv, sys
with open(sys.argv[1], newline="") as f:
    r = csv.DictReader(f, delimiter="\t")
    for row in r:
        print(
            "- {label}: state={state} statement_type={statement_type} "
            "substatement_type={substatement_type} ext={ext} bytes={bytes} "
            "metadata_bytes={metadata_bytes} content_type={content_type} "
            "metadata_content_type={metadata_content_type} update_count={update_count} "
            "note={note}".format(**row)
        )
PYEOF
    echo
    echo "## E（失敗系・境界）の生エラー（実名を含みうるので貼る前に確認すること）"
    for label in e-only-line e-only-block e-unclosed-block e-empty; do
      echo "### $label"
      if [ -s "$RUN_DIR/$label.start.err" ]; then
        echo "start.err:"
        head -5 "$RUN_DIR/$label.start.err"
      fi
      if [ -s "$RUN_DIR/$label.reason.txt" ]; then
        echo "reason.txt:"
        cat "$RUN_DIR/$label.reason.txt"
      fi
      echo
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
echo "<label>.reason.txt と <label>.results.json はデータベース名・テーブル名を含みうるので、"
echo "summary.txt 以外を貼るときは中身を確かめてください。"
