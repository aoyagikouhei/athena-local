#!/usr/bin/env bash
# issue #52 で作成（tools/ へ移す前の名前は 52-measure-keyword-comment.sh）
# 本物の Athena で、動詞と TABLE の間（キーワードとキーワードの間）にコメントを挟んだ SQL の
# StatementType / SubstatementType / OutputLocation のファイル名 / 本体と .metadata の有無・
# Content-Type / UpdateCount を実測する。issue #52 のための実測スクリプト。
#
# #17（2026-09-18）で測ったのは「先頭の」コメントだけ。athena-local は先頭のコメントは飛ばすが、
# `DROP /* c */ TABLE t` のようにキーワードの間にあるコメントは語として数えてしまい、
# SubstatementType が None になり、CTAS は結果の置き場所まで `tables/<id>` から `<id>.txt` に変わる。
# 本物が同じ SQL をどう扱うか（コメントを空白として読むか、弾くか、同じように落ちるか）で直し方が決まる。
#
# 使い方:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db PROBE_DDL=1 bash tools/measure/keyword-comment.sh
#   （資格情報はホストのシェルで AWS_ACCESS_KEY_ID などを export してから。または ~/.aws/credentials）
#
# 必要な環境変数:
#   OUTPUT    結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける）。
#   DB        データベース名。実在するものを指定する。
#
# 任意の環境変数:
#   TABLE       省略すると SHOW TABLES の 1 件目を使う（D 群の SHOW CREATE TABLE にだけ使う。
#               読むだけで変更しない）。1 件も無ければその項目だけ未測定にして続ける。
#   CATALOG     既定 AwsDataCatalog
#   REGION      既定 ap-northeast-1
#   OUT_DIR     既定 ${DEV_HOST_HOME:-$HOME}/athena-keyword-comment-measurements（実名が入るのでリポジトリの外に出す）
#   POLL_TIMEOUT 終端状態を待つ上限（秒）。既定 180
#   RETRY_MAX   名前解決・接続など一時的な失敗を再試行する回数の上限。既定 4
#   RETRY_DELAY 再試行の間隔（秒）。既定 5
#   PROBE_DDL   1 にすると F 群（成功する CTAS / ALTER TABLE / DROP TABLE）も測る。
#               **テーブル <db>.athena_local_probe_52 / athena_local_probe_52b を作って、
#               最後に必ず消す。** 同名のテーブルが既にあると壊すので、無いことを
#               確かめてから 1 にすること。データの置き場所は OUTPUT の下
#               （tables-probe-52/、tables-probe-52b/）。
#               この issue の本題（CTAS の結果の置き場所）は F 群でしか「成功したときに実際に
#               置かれるファイル」を見られないので、1 での実行を勧める。0 でも C 群
#               （存在しないテーブルを読むので必ず失敗する CTAS）で分類と OutputLocation の形は測れる。
#
# 項目（対照と変異を同じラウンドに入れる。「plain」がコメント無しの対照）:
#   A. DROP TABLE（IF EXISTS で存在しない名前。何も消さない）
#      a-drop-plain            DROP TABLE IF EXISTS <db>.athena_local_probe_52_missing
#      a-drop-block            DROP /* c */ TABLE IF EXISTS ...        ← issue の本題
#      a-drop-line             DROP -- c<改行>TABLE IF EXISTS ...
#      a-drop-block-after      DROP TABLE /* c */ IF EXISTS ...        （TABLE の後ろ。athena-local は通る）
#   B. ALTER TABLE（存在しないテーブル。実行時に失敗するが、#43 の実測では失敗しても
#      SubstatementType は返っていたので分類だけ測る）
#      b-alter-plain           ALTER TABLE <missing> ADD COLUMNS (c int)
#      b-alter-block           ALTER /* c */ TABLE <missing> ADD COLUMNS (c int)
#      b-alter-line            ALTER -- c<改行>TABLE <missing> ADD COLUMNS (c int)
#   C. CTAS と CREATE TABLE（存在しないテーブルを読む／作れない形なので失敗する。テーブルは残らない。
#      失敗しても OutputLocation は割り当てられるので、その形（tables/<id> か <id>.txt か）を見る）
#      c-ctas-plain            CREATE TABLE <db>.athena_local_probe_52_fail AS SELECT * FROM <missing>
#      c-ctas-block            CREATE /* c */ TABLE ... AS SELECT * FROM <missing>   ← issue の本題
#      c-ctas-line             CREATE -- c<改行>TABLE ... AS SELECT * FROM <missing>
#      c-ctas-block-after-table CREATE TABLE /* c */ ... AS SELECT ...   （athena-local は通る）
#      c-ctas-block-before-as  CREATE TABLE ... /* c */ AS SELECT ...    （athena-local は通る）
#      c-ctas-block-after-as   CREATE TABLE ... AS /* c */ SELECT ...    （athena-local は `AS` の次が `/*` になり落ちる）
#      c-create-plain          CREATE TABLE <db>.athena_local_probe_52_fail (n int)   （CTAS でない対照）
#      c-create-block          CREATE /* c */ TABLE <db>.athena_local_probe_52_fail (n int)
#   D. 3 語目まで見る SHOW（読むだけ）
#      d-show-create-plain     SHOW CREATE TABLE <TABLE>
#      d-show-create-block     SHOW /* c */ CREATE TABLE <TABLE>   （先頭の /* c */ は本物が弾く。#27）
#      d-show-create-block2    SHOW CREATE /* c */ TABLE <TABLE>
#      d-show-tables-block     SHOW /* c */ TABLES
#   E. 先頭の語だけで決まる文と DATABASE（対照。CREATE/DROP DATABASE は #17 と同じ使い捨ての名前）
#      e-select-block          SELECT /* c */ 1
#      e-create-db-block       CREATE /* c */ DATABASE IF NOT EXISTS athena_local_probe_52
#      e-drop-db-block         DROP /* c */ DATABASE IF EXISTS athena_local_probe_52
#   F. 成功する CTAS / ALTER TABLE / DROP TABLE（PROBE_DDL=1 のときだけ。作ったテーブルは必ず消す）
#      f-ctas-plain            CREATE TABLE <db>.athena_local_probe_52 WITH (Iceberg) AS SELECT 1 AS i
#      f-ctas-block            CREATE /* c */ TABLE <db>.athena_local_probe_52b WITH (Iceberg) AS SELECT 1 AS i
#      f-alter-plain           ALTER TABLE <db>.athena_local_probe_52 ADD COLUMNS (m int)
#      f-alter-block           ALTER /* c */ TABLE <db>.athena_local_probe_52b ADD COLUMNS (m int)
#      f-drop-plain            DROP TABLE IF EXISTS <db>.athena_local_probe_52        （後始末を兼ねる）
#      f-drop-block            DROP /* c */ TABLE IF EXISTS <db>.athena_local_probe_52b（後始末を兼ねる）
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く。前の回の結果と混ざらない。
#
# ** SQL に改行を含める書き方の注意 **
# 「DROP -- c\nTABLE」のような文は、シェルで実際の改行文字（0x0a）にしてから渡さないと、
# 「\」「n」という 2 文字が入った 1 行の文字列になり、まったく別の測定になる。
# そのため bash の ANSI-C quoting（$'...'）を使う。$'...' は変数展開をしないので、
# $DB を埋め込む行は $'DROP -- c\n'"TABLE IF EXISTS $DB.x" のように断片を隣り合わせて連結する。
#
# S3 からの取得は `aws s3 cp <src> -` で標準出力に流し、リダイレクトはこのシェルが行う。
# aws が Docker のラッパだと、コンテナにマウントされるのは実行時のカレントディレクトリだけで、
# 絶対パスを渡すとコンテナの中に書かれて消える。しかも終了コードは 0 になる。
#
# 課金について: 既定（PROBE_DDL=0）はスキャンしない計算だけのクエリ（SELECT 1）、メタデータだけを
# 見る SHOW、存在しないテーブルに対して失敗する DDL/CTAS、使い捨ての DATABASE の作成と削除。
# 実テーブルを読むのは SHOW CREATE TABLE だけ（データはスキャンしない）。
# PROBE_DDL=1 は Iceberg テーブル 2 件（各 1 行）を作って ALTER し、最後に消す。
#
# 出力ファイル（項目ごと。<label> は上の項目名）:
#   <label>.start.err           StartQueryExecution の stderr（失敗したときの手掛かり）
#   <label>.execution.json      GetQueryExecution の応答そのもの
#   <label>.results.json        GetQueryResults の応答そのもの
#   <label>.reason.txt          StateChangeReason と AthenaError（execution.json から抜粋）
#   <label>.ls.txt              OutputLocation と .metadata の ls の結果
#   <label>.bytes / .od.txt     結果ファイルの中身と、バイト単位で見たもの
#   <label>.metadata.bytes / .metadata.od.txt   .metadata の中身と 16 進（無ければ作らない）
#   <label>.head.json / .metadata.head.json     head-object（Content-Type）
#   <label>.keys.txt            OutputLocation の周辺で <id> を含む key の一覧（CTAS のみ）
#
# metadata_query_id の列は、.metadata（protobuf）の先頭 field 1 に入っているクエリ ID の
# 「形」だけを出す（trino / uuid）。本物は DESCRIBE と SHOW CREATE TABLE だけを
# QueryExecutionId（uuid）にする。athena-local はこの分岐も語の並びで決めているので、
# `SHOW /* c */ CREATE TABLE` で形が変わるかどうかを見る。
#
# 最後に summary.tsv（機械可読）と summary.txt（そのまま貼れる整形済み）を作る。
# 実名は summary には出さない（DB 名・テーブル名は note に混じらないよう置換している）。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください}"
: "${DB:?DB にデータベース名を設定してください}"
TABLE=${TABLE:-}
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_DIR=${OUT_DIR:-${DEV_HOST_HOME:-$HOME}/athena-keyword-comment-measurements}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}
PROBE_DDL=${PROBE_DDL:-0}

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\tstatement_type\tsubstatement_type\text\tbytes\tmetadata_bytes\tcontent_type\tmetadata_content_type\tupdate_count\tmetadata_query_id\tnote\n' > "$SUMMARY"
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
      --query-string "DROP TABLE IF EXISTS $DB.athena_local_probe_52" \
      --query-execution-context "Catalog=$CATALOG,Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
    aws athena start-query-execution --region "$REGION" \
      --query-string "DROP TABLE IF EXISTS $DB.athena_local_probe_52b" \
      --query-execution-context "Catalog=$CATALOG,Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
  fi
  # C 群の CREATE TABLE は失敗する想定だが、途中で止めたときも残さない（IF EXISTS なので無ければ何もしない）。
  aws athena start-query-execution --region "$REGION" \
    --query-string "DROP TABLE IF EXISTS $DB.athena_local_probe_52_fail" \
    --query-execution-context "Catalog=$CATALOG,Database=$DB" \
    --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
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

# .metadata（protobuf）の先頭 field 1 に入っているクエリ ID の「形」を返す。
# Trino のクエリ ID は 20260918_083012_00001_abcde の形、Athena の QueryExecutionId は UUID。
# どちらが入るかは文の種類で変わる（src/operation/result_output.rs の metadata_query_id）ので、
# `SHOW /* c */ CREATE TABLE` でこれが変わるかどうかを見る。
# 値そのものは実名ではないが、念のため形だけ（trino / uuid / other）を summary に出す。
metadata_query_id_shape() {
  [ -s "$1" ] || { echo "-"; return; }
  python3 -c 'import re, sys
try:
    b = open(sys.argv[1], "rb").read()
except Exception:
    print("-"); sys.exit(0)
# protobuf: field 1, wire type 2 (length-delimited) => tag byte 0x0a, then a varint length.
if not b or b[0] != 0x0A:
    print("no-field1"); sys.exit(0)
i, shift, length = 1, 0, 0
while i < len(b):
    byte = b[i]; i += 1
    length |= (byte & 0x7F) << shift
    if not byte & 0x80:
        break
    shift += 7
value = b[i:i + length].decode("utf-8", "replace")
if re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", value):
    print("uuid")
elif re.fullmatch(r"\d{8}_\d{6}_\d{5}_\w+", value):
    print("trino")
else:
    print("other(len=%d)" % len(value))' "$1"
}

# OutputLocation の周辺を一覧し、<id> を含む key を全部書き出す。件数を返す（標準出力）。
# result-metadata.sh の list_keys をそのまま流用（CTAS / INSERT 用）。
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
  printf '%s\tSKIPPED\t-\t-\t-\t-\t-\t-\t-\t-\t-\t%s\n' "$label" "$(sanitize "$note")" >> "$SUMMARY"
}

# ラベルを指定して 1 文を実行し、終端状態まで待って StatementType 等を採取する。
# 第 3 引数に keys を渡すと OutputLocation の周辺の key も一覧する（CTAS / INSERT 用）。
# 成功したときだけ 0 を返す。失敗する文をわざと投げる項目も多いので、呼び出し側の
# ほとんどは戻り値を見ない。
run() {
  local label=$1 sql=$2 want_keys=${3:-}
  local id state stype sstype loc ext size meta_size ctype mctype ucount note keys mqid

  id=$(start_query_retry "$label" "$sql")
  if [ -z "${id:-}" ]; then
    note="attempts=$LAST_ATTEMPTS; $(first_err_line "$RUN_DIR/$label.start.err")"
    if ! grep -q "An error occurred" "$RUN_DIR/$label.start.err" 2>/dev/null; then
      note="$note; CLI が送信前に拒否した可能性"
    fi
    echo "== $label: 開始できませんでした（試行 $LAST_ATTEMPTS 回）。$RUN_DIR/$label.start.err を見てください"
    printf '%s\tSTART_FAILED\t-\t-\t-\t-\t-\t-\t-\t-\t-\t%s\n' "$label" "$(sanitize "$note")" >> "$SUMMARY"
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

  ext="-"; size="none"; meta_size="none"; ctype="-"; mctype="-"; keys="-"; mqid="-"
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
      mqid=$(metadata_query_id_shape "$RUN_DIR/$label.metadata.bytes")
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

  echo "== $label  state=$state  stype=$stype  sstype=$sstype  ext=$ext  bytes=$size  metadata=$meta_size  ct=$ctype  meta_ct=$mctype  update_count=$ucount  meta_query_id=$mqid"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$label" "$state" "$stype" "$sstype" "$ext" "$size" "$meta_size" "$ctype" "$mctype" "$ucount" "$mqid" "$(sanitize "$note")" >> "$SUMMARY"
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
# 名前は端末に出さず、ファイルに置くだけ。1 件も無くても全体は止めず、SHOW CREATE TABLE の
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

MISSING="$DB.athena_local_probe_52_missing"
FAIL="$DB.athena_local_probe_52_fail"

# A. DROP TABLE。IF EXISTS で存在しない名前なので何も消さない。
run a-drop-plain       "DROP TABLE IF EXISTS $MISSING"
run a-drop-block       "DROP /* c */ TABLE IF EXISTS $MISSING"
run a-drop-line        $'DROP -- c\n'"TABLE IF EXISTS $MISSING"
run a-drop-block-after "DROP TABLE /* c */ IF EXISTS $MISSING"

# B. ALTER TABLE。存在しないテーブルなので実行時に失敗する（分類だけを見る）。
run b-alter-plain "ALTER TABLE $MISSING ADD COLUMNS (c int)"
run b-alter-block "ALTER /* c */ TABLE $MISSING ADD COLUMNS (c int)"
run b-alter-line  $'ALTER -- c\n'"TABLE $MISSING ADD COLUMNS (c int)"

# C. CTAS と CREATE TABLE。存在しないテーブルを読むので失敗し、テーブルは残らない。
#    OutputLocation は失敗しても割り当てられるので、その形を見る。keys で周辺の key も一覧する。
run c-ctas-plain              "CREATE TABLE $FAIL AS SELECT * FROM $MISSING" keys
run c-ctas-block              "CREATE /* c */ TABLE $FAIL AS SELECT * FROM $MISSING" keys
run c-ctas-line               $'CREATE -- c\n'"TABLE $FAIL AS SELECT * FROM $MISSING" keys
run c-ctas-block-after-table  "CREATE TABLE /* c */ $FAIL AS SELECT * FROM $MISSING" keys
run c-ctas-block-before-as    "CREATE TABLE $FAIL /* c */ AS SELECT * FROM $MISSING" keys
run c-ctas-block-after-as     "CREATE TABLE $FAIL AS /* c */ SELECT * FROM $MISSING" keys
# CTAS でない CREATE TABLE の対照。Athena では EXTERNAL も table_type も無い形は失敗する想定だが、
# 万一作られても最後の後始末（DROP TABLE IF EXISTS）で消す。
run c-create-plain "CREATE TABLE $FAIL (n int)"
run c-create-block "CREATE /* c */ TABLE $FAIL (n int)"

# D. 3 語目まで見る SHOW。読むだけ。
if [ -z "$TABLE" ]; then
  skip d-show-create-plain  "このデータベースにテーブルが無いため SHOW CREATE TABLE を測れない"
  skip d-show-create-block  "このデータベースにテーブルが無いため SHOW CREATE TABLE を測れない"
  skip d-show-create-block2 "このデータベースにテーブルが無いため SHOW CREATE TABLE を測れない"
else
  run d-show-create-plain  "SHOW CREATE TABLE $TABLE"
  run d-show-create-block  "SHOW /* c */ CREATE TABLE $TABLE"
  run d-show-create-block2 "SHOW CREATE /* c */ TABLE $TABLE"
fi
run d-show-tables-block "SHOW /* c */ TABLES"

# E. 先頭の語だけで決まる文と DATABASE（対照）。
run e-select-block    "SELECT /* c */ 1"
run e-create-db-block "CREATE /* c */ DATABASE IF NOT EXISTS athena_local_probe_52"
run e-drop-db-block   "DROP /* c */ DATABASE IF EXISTS athena_local_probe_52"

# F. 成功する CTAS / ALTER TABLE / DROP TABLE。テーブルを作って消すので PROBE_DDL=1 のときだけ。
if [ "$PROBE_DDL" = 1 ]; then
  CTAS_ATTEMPTED=1
  run f-ctas-plain  "CREATE TABLE $DB.athena_local_probe_52 WITH (table_type = 'ICEBERG', location = '${OUTPUT}tables-probe-52/', is_external = false) AS SELECT 1 AS i" keys
  run f-ctas-block  "CREATE /* c */ TABLE $DB.athena_local_probe_52b WITH (table_type = 'ICEBERG', location = '${OUTPUT}tables-probe-52b/', is_external = false) AS SELECT 1 AS i" keys
  run f-alter-plain "ALTER TABLE $DB.athena_local_probe_52 ADD COLUMNS (m int)"
  run f-alter-block "ALTER /* c */ TABLE $DB.athena_local_probe_52b ADD COLUMNS (m int)"
  # 後始末を兼ねる。CTAS が失敗していても IF EXISTS なので安全に呼べる。
  run f-drop-plain  "DROP TABLE IF EXISTS $DB.athena_local_probe_52"
  run f-drop-block  "DROP /* c */ TABLE IF EXISTS $DB.athena_local_probe_52b"
else
  for label in f-ctas-plain f-ctas-block f-alter-plain f-alter-block f-drop-plain f-drop-block; do
    skip "$label" "PROBE_DDL=0 のため未測定"
  done
fi

# C 群の後始末。失敗する想定だが、万一 CREATE TABLE が通っていたら消す（IF EXISTS なので無ければ何もしない）。
run z-cleanup-fail "DROP TABLE IF EXISTS $FAIL"

# summary.txt を作る。summary.tsv を整形し、失敗した項目のエラー文言（<label>.start.err /
# <label>.reason.txt）を短く添える。実名は redact 済みの note しか使わない。
write_summary_txt() {
  local txt="$RUN_DIR/summary.txt"
  {
    echo "# issue #52: キーワードの間にコメントを挟んだ SQL の文の種類の実測"
    echo "# 実行日時: $(date -Iseconds)"
    echo "# StartQueryExecution を呼んだ回数（一時的な失敗の再試行込み）: $START_CALL_COUNT"
    echo "#   ※ GetQueryExecution / GetQueryResults / S3 への呼び出しはこの回数に含めない"
    echo "#     （ポーリングのぶん多くなるが、課金には影響しない）。"
    if [ "$PROBE_DDL" = 1 ]; then
      echo "# DDL: あり（Iceberg テーブルを 2 件作成→ALTER→削除。F 群のみ）"
    else
      echo "# DDL: テーブルの作成は無し（PROBE_DDL=0）。失敗する CTAS/ALTER/DROP と CREATE/DROP DATABASE のみ実行"
    fi
    echo "# 課金: 既定はスキャン無しの計算クエリ（SELECT 1）と SHOW、存在しないテーブルに対する失敗する DDL。"
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
            "metadata_query_id={metadata_query_id} note={note}".format(**row)
        )
PYEOF
    echo
    echo "## OutputLocation の末尾（<id> を伏せて、tables/ の有無と拡張子だけ）"
    python3 - "$RUN_DIR" <<'PYEOF'
import glob, json, os, re, sys
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.execution.json"))):
    label = os.path.basename(path)[: -len(".execution.json")]
    try:
        d = json.load(open(path))["QueryExecution"]
    except Exception:
        continue
    loc = d.get("ResultConfiguration", {}).get("OutputLocation", "")
    qid = d.get("QueryExecutionId", "")
    tail = loc.rsplit("/", 2)[-2:] if loc else []
    tail = "/".join(tail).replace(qid, "<id>") if qid else "/".join(tail)
    print("- %s: %s" % (label, tail or "(無し)"))
PYEOF
    echo
    echo "## 失敗した項目の理由（ErrorCategory / ErrorType と StateChangeReason の先頭。実名は <DB> に置換）"
    for f in "$RUN_DIR"/*.reason.txt; do
      label=$(basename "$f" .reason.txt)
      if grep -q '^State: FAILED' "$f" 2>/dev/null || [ -s "$RUN_DIR/$label.start.err" ]; then
        echo "### $label"
        [ -s "$RUN_DIR/$label.start.err" ] && { echo "start.err:"; redact "$(head -3 "$RUN_DIR/$label.start.err")"; echo; }
        redact "$(grep -E '^(State|StateChangeReason):' "$f" | cut -c1-300)"
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
echo "<label>.reason.txt と <label>.results.json はデータベース名・テーブル名を含みうるので、"
echo "summary.txt 以外を貼るときは中身を確かめてください。"
