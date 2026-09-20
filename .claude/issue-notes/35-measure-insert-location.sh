#!/usr/bin/env bash
# 本物の Athena で、INSERT の OutputLocation（拡張子なしの `<id>` か、`<id>.csv` か）を
# 実測する。issue #35 のための実測スクリプト。#26 の 26-measure-iceberg-detection.sh を
# 雛形にしている（run・loc_shape_of・poll_until_terminal などのヘルパはそのまま）。
#
# 測りたいこと（athena-local は今 INSERT だけ拡張子なしの `<id>` と判定する）:
#   a  Hive テーブルへの INSERT の OutputLocation と付随ファイル
#   b  Iceberg テーブルへの INSERT の同上
#   c  0 行の INSERT（更新件数 0）で置き場所が変わるか
#   d  失敗する INSERT（型不一致）で本体・.metadata が置かれるか
# ついでに、同じ 2026-09-17 の 1 ラウンドで採られた UPDATE / DELETE と、
# 一度も実測していない MERGE の `<id>.csv` も測る（e / f / g）。
#
# **対照を同じラウンドに入れる**（#26 の教訓。別の日・別のラウンドとの差を条件による違いと
# 解釈しない）:
#   h  SELECT     → `<id>.csv` のはず
#   i  CTAS       → `tables/<id>` のはず（#26 の 2026-09-19 の結果の再現確認）
#   probe-show-tables  SHOW TABLES → `<id>.txt` のはず（preflight を兼ねる）
# テーブルが本当に Hive / Iceberg になったかは SHOW CREATE TABLE で裏取りする。
#
# 使い方:
#   OUTPUT=s3://your-bucket/prefix/ DB=your_db bash .claude/issue-notes/35-measure-insert-location.sh
#
# 必要な環境変数:
#   OUTPUT    結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける）。
#   DB        データベース名。実在するものを指定する。
#
# 任意の環境変数:
#   CATALOG      既定 AwsDataCatalog
#   REGION       既定 ap-northeast-1
#   OUT_DIR      既定 $HOME/athena-insert-measurements（実名が入るのでリポジトリの外に出す）
#   POLL_TIMEOUT 終端状態を待つ上限（秒）。既定 180
#   RETRY_MAX    名前解決・接続など一時的な失敗を再試行する回数の上限。既定 4
#   RETRY_DELAY  再試行の間隔（秒）。既定 5
#   PROBE_DDL    既定 1（測る）。**INSERT には書き込み先のテーブルが要るので、既定で作る。**
#                0 にすると全項目を skip する（対照も含めて何も測れない）。
#
# ** このスクリプトが本物に対して行う破壊的な操作 **
#   <db>.athena_local_probe_35_hive（Hive）、_iceberg（Iceberg）、_ctas（対照の CTAS）の
#   3 テーブルを CREATE TABLE AS SELECT で作り、_hive と _iceberg に
#   INSERT / UPDATE / DELETE / MERGE で数行を書き込み、最後に DROP TABLE IF EXISTS で消す
#   （異常終了時も trap で消しにいく）。
#   同名のテーブルが既にあると壊すので、開始前に SHOW TABLES で存在を確かめ、
#   1 件でもあればテーブルを作らずに止まる。
#   Hive の CTAS（_hive / _ctas）のデータは Athena の既定で $OUTPUT の下の tables/<id>/ に
#   置かれ、DROP TABLE では消えない（外部テーブルのため）。残った key の一覧を
#   cleanup-hints.txt に書き出すので、消したければそれを見て手で消すこと。
#   Iceberg のテーブル（_iceberg）は location を $OUTPUT の下の tables-probe-35-i/ に指定し、
#   is_external = false にしてあるので DROP TABLE でデータも消える。
#
# 課金について: 作るテーブルは 1 行、書き込むのも数行で、実テーブルのスキャンは
# UPDATE / DELETE / MERGE の数行だけ。Athena の最小課金（10MB 相当）× クエリ数の見込み。
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
#   <label>.head.txt           本体と .metadata の head-object（Content-Type とバイト数の出どころ）
#   <label>.metadata.bytes     .metadata の中身そのもの（無ければ作らない）
#   <label>.metadata.od.txt    上を 16 進で見たもの（protobuf なので）
#   <label>.keys.txt           OutputLocation の周辺で <id> を含む key の一覧
#                              （INSERT のマニフェスト `<id>-manifest.csv` もここに出る）
#   <label>.show-create.*      作られたテーブルの SHOW CREATE TABLE（形式の裏取り）
#
# summary の決め手になる列は loc_shape で、OutputLocation の末尾の形だけを出す。
# バケット名・プレフィックス・クエリ ID は出さず、`tables/<id>`／`<id>`／`<id>.csv`／
# `<id>.txt`／other のどれかに畳む。table_format 列は SHOW CREATE TABLE の本文に
# table_type='iceberg' が（大文字小文字を無視して）現れたかで iceberg / hive に畳む。
# keys 列は <id> を含む key の**件数**だけを出す（key そのものは貼らない）。
# どれも実名を含まないので、summary.txt はそのまま貼れる。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください}"
: "${DB:?DB にデータベース名を設定してください}"
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
OUT_DIR=${OUT_DIR:-$HOME/athena-insert-measurements}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}
PROBE_DDL=${PROBE_DDL:-1}

PREFIX=athena_local_probe_35
# 作るテーブルの接尾辞（本編のラベル a〜i と紛れないよう別の名前にする）。
TABLES="hive iceberg ctas"
# 本編で測る項目のラベル。
LABELS="a b c d e f g h i"

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\tstatement_type\tloc_shape\tbody_bytes\tbody_content_type\tmetadata_bytes\tmetadata_content_type\tkeys\ttable_format\tnote\n' > "$SUMMARY"
echo "出力先: $RUN_DIR"

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

# 実名（DB 名・出力先・バケット名）を置換して隠す。prep-i の SQL には location として
# $OUTPUT がそのまま入るので、DB 名だけでは足りない。
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
# INSERT のマニフェスト（`<id>-manifest.csv`）が置かれるならここに出る。
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
  # 分からない（`tables/<id>.metadata` が `<id>.metadata` に見える）。
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
  printf '%s\tSKIPPED\t-\t-\t-\t-\t-\t-\t-\t-\t%s\n' "$label" "$(sanitize "$note")" >> "$SUMMARY"
}

# ラベルを指定して 1 文を実行し、終端状態まで待って OutputLocation の形などを採取する。
# 成功したときだけ 0 を返す。失敗した文でも、本体と .metadata の有無は必ず採る
# （d の「失敗した INSERT で何が置かれるか」がこの採取に乗る）。
run() {
  local label=$1 sql=$2 want_keys=${3:-}
  local id state stype loc shape note keys
  local body_bytes body_ct meta_bytes meta_ct

  printf '%s\n' "$sql" > "$RUN_DIR/$label.sql"
  id=$(start_query_retry "$label" "$sql")
  LAST_ATTEMPTS=$(read_attempts "$label")
  if [ -z "${id:-}" ]; then
    note="attempts=$LAST_ATTEMPTS; $(first_err_line "$RUN_DIR/$label.start.err")"
    echo "== $label: 開始できませんでした（試行 $LAST_ATTEMPTS 回）。$RUN_DIR/$label.start.err を見てください"
    printf '%s\tSTART_FAILED\t-\t-\t-\t-\t-\t-\t-\t-\t%s\n' "$label" "$(sanitize "$note")" >> "$SUMMARY"
    return 1
  fi

  state=$(poll_until_terminal "$id")

  aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.execution.json" 2> "$RUN_DIR/$label.execution.err"
  write_reason "$RUN_DIR/$label.execution.json" "$RUN_DIR/$label.reason.txt"

  IFS=$'\t' read -r stype loc < <(read_execution_fields "$RUN_DIR/$label.execution.json")
  shape=$(loc_shape_of "$loc" "$id")
  body_bytes="-"; body_ct="-"; meta_bytes="-"; meta_ct="-"; keys="-"

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
    fi
    if [ -n "$want_keys" ]; then
      keys=$(list_keys "$label" "$id" "$loc")
    fi
  fi

  note="attempts=$LAST_ATTEMPTS"
  case "$state" in
    FAILED | CANCELLED) note="$note; $(error_codes_of "$RUN_DIR/$label.execution.json")" ;;
  esac

  echo "== $label  state=$state  stype=$stype  loc_shape=$shape  body=$body_bytes($body_ct)  metadata=$meta_bytes($meta_ct)  keys=$keys"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$label" "$state" "$stype" "$shape" "$body_bytes" "$body_ct" \
    "$meta_bytes" "$meta_ct" "$keys" "-" "$(sanitize "$note")" >> "$SUMMARY"
  [ "$state" = SUCCEEDED ]
}

# 作られたテーブルが本当に Hive / Iceberg になったかを SHOW CREATE TABLE で裏取りし、
# summary.tsv の table_format 列（10 列目）を埋める。
# 本文（DB 名・S3 のパスを含む）はファイルにだけ残し、summary には形だけを出す。
record_table_format() {
  local suffix=$1 row_label=$2 id state loc fmt="unknown"
  id=$(start_query_retry "show-create-$suffix" "SHOW CREATE TABLE $DB.${PREFIX}_$suffix")
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
  python3 - "$SUMMARY" "$row_label" "$fmt" <<'PYEOF'
import sys
path, label, fmt = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines()
for i, line in enumerate(lines):
    cols = line.split("\t")
    if cols[0] == label and len(cols) >= 10:
        cols[9] = fmt
        lines[i] = "\t".join(cols)
open(path, "w").write("\n".join(lines) + "\n")
PYEOF
  echo "== ${PREFIX}_$suffix: table_format=$fmt（SHOW CREATE TABLE で確認）"
}

# --- preflight ---------------------------------------------------------------

# まず指定のデータベースが実在するかを確かめる。ついでに SHOW TABLES は
# `<id>.txt` の対照も兼ねる（この文が `<id>.txt` に出ることはこのラウンドで確かめる）。
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
    skip "$label" "PROBE_DDL=0 のため未測定（INSERT には書き込み先のテーブルが要るので、何も測れない）"
  done
  echo "PROBE_DDL=0 のためテーブルを作らずに終わります。"
  exit 0
fi

# --- 準備: 書き込み先のテーブルを作る ----------------------------------------

CTAS_ATTEMPTED=1

# Hive のテーブル（Athena の既定）。
run prep-h "CREATE TABLE $DB.${PREFIX}_hive AS SELECT 1 AS n, 'x' AS s" keys
PREP_H_OK=$?

# Iceberg のテーブル。location を結果プレフィックス配下に置き、DROP でデータも消えるようにする。
run prep-i "CREATE TABLE $DB.${PREFIX}_iceberg WITH (table_type = 'ICEBERG', location = '${OUTPUT}tables-probe-35-i/', is_external = false) AS SELECT 1 AS n, 'x' AS s" keys
PREP_I_OK=$?

# 実際にその形式になったかを裏取りする（この裏取りが無いと a / b の差を形式の違いと言えない）。
[ "$PREP_H_OK" = 0 ] && record_table_format hive prep-h
[ "$PREP_I_OK" = 0 ] && record_table_format iceberg prep-i

# --- 本編 --------------------------------------------------------------------

# a. 争点: Hive テーブルへの INSERT。athena-local は今 `<id>`（拡張子なし）と判定する。
if [ "$PREP_H_OK" = 0 ]; then
  run a "INSERT INTO $DB.${PREFIX}_hive VALUES (2, 'y')" keys
else
  skip a "Hive のテーブルを作れなかったので未測定"
fi

# b. 争点: Iceberg テーブルへの INSERT。テーブルの形式で置き場所が変わるかを見る。
if [ "$PREP_I_OK" = 0 ]; then
  run b "INSERT INTO $DB.${PREFIX}_iceberg VALUES (2, 'y')" keys
else
  skip b "Iceberg のテーブルを作れなかったので未測定"
fi

# c. 境界: 0 行の INSERT（更新件数 0）。置き場所と .metadata が変わるかを見る。
if [ "$PREP_H_OK" = 0 ]; then
  run c "INSERT INTO $DB.${PREFIX}_hive SELECT * FROM (VALUES (3, 'z')) AS t(n, s) WHERE t.n < 0" keys
else
  skip c "Hive のテーブルを作れなかったので未測定"
fi

# d. 失敗系: 型が合わない INSERT。失敗したときに本体・.metadata が置かれるかを見る
#    （#6 で測った失敗時の挙動は SHOW / DROP / CREATE DATABASE で、INSERT は測っていない）。
if [ "$PREP_H_OK" = 0 ]; then
  run d "INSERT INTO $DB.${PREFIX}_hive VALUES ('not_an_int', 'y')" keys
else
  skip d "Hive のテーブルを作れなかったので未測定"
fi

# e. UPDATE。2026-09-17 と同じ 1 ラウンドで採られた `<id>.csv` を測り直す。
if [ "$PREP_I_OK" = 0 ]; then
  run e "UPDATE $DB.${PREFIX}_iceberg SET s = 'w' WHERE n = 2" keys
else
  skip e "Iceberg のテーブルを作れなかったので未測定"
fi

# f. DELETE。同上。
if [ "$PREP_I_OK" = 0 ]; then
  run f "DELETE FROM $DB.${PREFIX}_iceberg WHERE n = 2" keys
else
  skip f "Iceberg のテーブルを作れなかったので未測定"
fi

# g. MERGE。一度も実測していない（results.rs は UPDATE / DELETE と同じ `<id>.csv` に置いている）。
if [ "$PREP_I_OK" = 0 ]; then
  run g "MERGE INTO $DB.${PREFIX}_iceberg AS t USING (VALUES (4, 'm')) AS u(n, s) ON t.n = u.n WHEN NOT MATCHED THEN INSERT (n, s) VALUES (u.n, u.s)" keys
else
  skip g "Iceberg のテーブルを作れなかったので未測定"
fi

# h. 対照: SELECT。`<id>.csv` のはず。同じラウンドで採ることに意味がある。
run h "SELECT 1 AS n" keys

# i. 対照: CTAS。`tables/<id>` のはず（#26 の 2026-09-19 の結果の再現確認）。
run i "CREATE TABLE $DB.${PREFIX}_ctas AS SELECT 1 AS n" keys

# --- 後始末 ------------------------------------------------------------------

for t in $TABLES; do
  run "z-drop-$t" "DROP TABLE IF EXISTS $DB.${PREFIX}_$t"
done

# ここまで来れば Z 群で DROP を投げ終えているので、trap での二度目の DROP は要らない。
CTAS_ATTEMPTED=0

# Hive の CTAS が $OUTPUT の下に残したデータの key を、消すためのヒントとして残す。
# バケット名・プレフィックスを含むので summary.txt には入れない。
{
  echo "# Hive のテーブル（${PREFIX}_hive / _ctas）のデータは DROP TABLE では消えません。"
  echo "# 下の key を見て、要らなければ手で消してください（例: aws s3 rm --recursive <パス>）。"
  for label in prep-h prep-i $LABELS; do
    echo "## $label"
    cat "$RUN_DIR/$label.keys.txt" 2>/dev/null
  done
} > "$RUN_DIR/cleanup-hints.txt"

# --- summary -----------------------------------------------------------------

write_summary_txt() {
  local txt="$RUN_DIR/summary.txt"
  {
    echo "# issue #35: INSERT の OutputLocation（拡張子なしの <id> か）の再実測"
    echo "# 実行日時: $(date -Iseconds)"
    echo "# StartQueryExecution を呼んだ回数（一時的な失敗の再試行込み）: $(wc -l < "$START_CALL_FILE" | tr -d ' ')"
    echo "#   ※ GetQueryExecution / S3 への呼び出しはこの回数に含めない（課金には影響しない）。"
    echo "# DDL: あり（${PREFIX}_hive / _iceberg / _ctas の 3 テーブルを作成→DROP、_hive と _iceberg に数行を書き込み）"
    echo "# 課金: 作るテーブルは 1 行、スキャンは UPDATE / DELETE / MERGE の数行だけ。"
    echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
    echo "#       また、ワークグループの設定はコンソールで変更済みかもしれず、工場出荷時の既定とは限らない。"
    echo
    echo "## 投げた文（DB 名は <DB> に置換）"
    for label in probe-show-tables prep-h prep-i $LABELS; do
      [ -s "$RUN_DIR/$label.sql" ] && echo "- $label: $(sanitize "$(redact "$(cat "$RUN_DIR/$label.sql")")")"
    done
    echo
    echo "## 項目ごとの結果"
    echo "#   loc_shape     OutputLocation の末尾の形（決め手の値）"
    echo "#   body_*        結果本体そのもの（- なら置かれていない）"
    echo "#   metadata_*    付随ファイル <OutputLocation>.metadata（- なら置かれていない）"
    echo "#   keys          OutputLocation の周辺で <id> を含む key の件数"
    echo "#                 （INSERT のマニフェスト <id>-manifest.csv があればここに数えられる）"
    echo "#   table_format  SHOW CREATE TABLE で見た実際のテーブル形式（prep-h / prep-i だけ）"
    python3 - "$SUMMARY" <<'PYEOF'
import csv, sys
with open(sys.argv[1], newline="") as f:
    for row in csv.DictReader(f, delimiter="\t"):
        print(
            "- {label}: state={state} statement_type={statement_type} loc_shape={loc_shape} "
            "body={body_bytes}B/{body_content_type} metadata={metadata_bytes}B/{metadata_content_type} "
            "keys={keys} table_format={table_format} note={note}".format(**row)
        )
PYEOF
    echo
    echo "## <id> を含む key の形（実名は伏せ、<id> と末尾だけを出す）"
    python3 - "$RUN_DIR" "prep-h prep-i $LABELS" "$OUTPUT_BUCKET" <<'PYEOF'
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
    echo "## 失敗した項目の理由（実名を含みうるので貼る前に確認すること）"
    for label in probe-show-tables prep-h prep-i $LABELS; do
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
