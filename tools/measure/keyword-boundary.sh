#!/usr/bin/env bash
# issue #200 で作成
# 本物の Athena で、キーワードの直後に空白なしで記号・引用符・括弧が続く SQL
# （`SELECT(1)`、`SHOW CREATE TABLE"t"` など）を、空白ありの対照と同じラウンドで
# StatementType／SubstatementType／結果ファイルの置き場所と拡張子／Content-Type／
# `.metadata` がどう変わるかを実測する。issue #200 のための実測スクリプト。
#
# 背景（`.claude/issue-notes/200.md` の quick ノートより）: athena-local の語の境界の
# 判定は 2 系統に分かれている。先頭語で分類する経路（StatementType・結果ファイル名・
# EXPLAIN の行分割。crates/athena-sql/src/words.rs の `words()`）は空白とコメントだけで
# 語を切り、記号・引用符・括弧は直前の語にくっつく。一方キーワード列を読む経路
# （ALTER TABLE の細分類など。crates/athena-sql/src/cursor.rs の `Cursor::keyword`）は
# 識別子の文字（英数字・`_`）以外ならどこでも区切りと見なす。この 2 系統が割れる形
# （`SELECT(1)`・`EXPLAIN(TYPE IO)`・`ALTER TABLE"t"`・`SHOW CREATE TABLE"t"` など）で、
# athena-local の値が本物とずれている可能性がある。本物がどちらの規則に近いかを、
# 各系統の代表的な文で実測する。
#
# tools/measure/ctas-parenthesized-query.sh（#199）を雛形にしている（redact・sanitize・
# is_transient_error・start_query_retry・fetch・head_object・emit_row・preflight・
# trap での後始末・summary.tsv と summary.txt の 2 段はそのまま流用。#199 との違いは
# 下の「雛形からの変更点」を参照）。
#
# 雛形からの変更点:
#   - PROBE_DDL の既定を 0 にした（この実測は DDL 無しの A 群だけでも大半の観点が測れる。
#     D 群は破壊的な DDL を伴うので明示的に opt-in させる。#199 は逆に既定 1 だった）。
#   - `record_table_info`（SHOW CREATE TABLE での裏取り）と `list_keys`（<id> 周辺の全 key
#     列挙）は持ち込んでいない。この実測は OutputLocation の形と本体・`.metadata` の
#     有無・ContentType・UpdateCount だけを見れば足り、作ったテーブルの列名・実際の
#     テーブル形式までは要らない（D 群の CTAS・CREATE VIEW は道具であって主題ではない）。
#   - `.metadata` の中に QueryExecutionId の文字列が含まれるかを新しく採る
#     （`meta_has_qid_of`。carries_execution_id の実測用）。
#   - EXPLAIN・DESCRIBE・SHOW CREATE の項目だけ、GetQueryResults を追加で 1 回呼び、
#     行数・ColumnInfo・先頭 3 行を `<label>.gqr-detail.txt` に保存する（`fetch_gqr`・
#     `analyze_gqr`）。列名・値そのものは summary.tsv / summary.txt には出さない
#     （B 群は PROBE_DDL=0 のとき実在のテーブルを覗くので、列名が実名になりうるため。
#     summary には行数と列の型だけを出す）。
#   - D 群は CTAS・CREATE VIEW の後始末を「空白ありの形」＋`IF EXISTS` でまとめて行う
#     （d2/d2c が失敗したら d3/d3c は測らず skip し、後始末だけ投げる。d4/d4c も同じ形に
#     揃えた。CLAUDE.md 不変条件・design-checklist の「対照は過去に成功した形」に合わせ、
#     後始末そのものは壊れた形では投げない）。
#
# 使い方:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db bash tools/measure/keyword-boundary.sh
#   D 群（DDL）も測るとき:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db PROBE_DDL=1 bash tools/measure/keyword-boundary.sh
#   （資格情報はホストのシェルで AWS_ACCESS_KEY_ID などを export してから。または ~/.aws/credentials）
#
# 必要な環境変数:
#   OUTPUT    結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける）。
#   DB        データベース名。実在するものを指定する。
#
# 任意の環境変数:
#   CATALOG      既定 AwsDataCatalog
#   REGION       既定 ap-northeast-1
#   OUT_DIR      既定 ${DEV_HOST_HOME:-$HOME}/athena-keyword-boundary-measurements（実名が入るのでリポジトリの外に出す）
#   POLL_TIMEOUT 終端状態を待つ上限（秒）。既定 180
#   RETRY_MAX    名前解決・接続など一時的な失敗を再試行する回数の上限。既定 4
#   RETRY_DELAY  再試行の間隔（秒）。既定 5
#   PROBE_DDL    既定 0（D 群を測らない）。1 にすると D 群（ALTER・CTAS・CREATE VIEW・
#                SHOW CREATE VIEW・OPTIMIZE を含む）も測る。
#
# ** PROBE_DDL=1 のときにこのスクリプトが本物に対して行う破壊的な操作 **
#   <db>.athena_local_probe_200（Hive。ALTER TABLE の対象を兼ねる）、
#   <db>.athena_local_probe_200_{c1,c2}（CTAS）、<db>.athena_local_probe_200_{v1,v2}（VIEW）、
#   <db>.athena_local_probe_200_ice（Iceberg。OPTIMIZE の対象）を作り、全部 DROP で消す
#   （異常終了時も trap で「空白ありの形」＋ IF EXISTS で消しにいく）。
#   同名のオブジェクトが既にあると壊すので、開始前に SHOW TABLES で athena_local_probe_200
#   という接頭辞が無いことを確かめ、1 件でもあれば何も作らずに止まる。
#   athena_local_probe_200_ice は WITH (location = ...) を付けて $OUTPUT の下に置くので、
#   DROP TABLE でデータも消える。それ以外（Hive の既定）は外部テーブル相当になり、
#   DROP TABLE では $OUTPUT 下のデータは消えない（cleanup-hints.txt にヒントを書く）。
#
# 課金について: A 群・B 群はテーブルのスキャンが無い計算クエリ（`(VALUES 1)` や
# 既存テーブルのメタデータ参照）。D 群で作るテーブルはどれも 0〜1 行で、実データの
# スキャンも無い。Athena の最小課金 × クエリ数の見込み。
# 本物への呼び出し回数の見込み（StartQueryExecution。GetQueryExecution・
# GetQueryResults・S3 への呼び出しは含めない）:
#   preflight 1 + A 群 16（a1〜a8 と対照 8 本）+ B 群 8（PROBE_DDL=0/1 のどちらでも）
#   = 25（既定の PROBE_DDL=0）
#   PROBE_DDL=1 だとさらに D 群が乗る: セットアップ 2（Hive・Iceberg）+ d1 系 3 +
#   d2〜d6 系 10（CREATE ×4・DROP ×4・SHOW CREATE VIEW ×2。片方が失敗した対は
#   後始末の IF EXISTS 1 本に置き換わるので本数はほぼ変わらない）+ d7 系 3
#   （OPTIMIZE ×2・後始末の DROP ×1）+ 最後の DROP 1 ＝ 19 本増え、合計 44 本程度
#   （再試行・失敗した対の後始末があれば前後する）。
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く。前の回の結果と混ざらない。
#
# S3 からの取得は `aws s3 cp <src> -` で標準出力に流し、リダイレクトはこのシェルが行う。
# aws が Docker のラッパだと、コンテナにマウントされるのは実行時のカレントディレクトリだけで、
# 絶対パスを渡すとコンテナの中に書かれて消える。しかも終了コードは 0 になる。
#
# 項目ごとに次を保存する（取れたものだけ）。
#   <label>.sql                投げた SQL そのもの（**DB 名は含まない。B/D 群はテーブル名を含む**）
#   <label>.start.err          StartQueryExecution の標準エラー（受け付けなかった証拠）
#   <label>.execution.json     GetQueryExecution の生の応答
#   <label>.execution.err      GetQueryExecution の標準エラー
#   <label>.reason.txt         StateChangeReason と AthenaError（**実名を含みうる。貼る前に確認**）
#   <label>.ls.txt             本体と .metadata の有無（aws s3 ls の結果そのまま）
#   <label>.head.txt           本体と .metadata の head-object（Content-Type とバイト数の出どころ）
#   <label>.metadata.bytes     .metadata の中身そのもの（無ければ作らない）
#   <label>.metadata.od.txt    上を 16 進で見たもの（protobuf なので）
#   <label>.results.json       GetQueryResults の生の応答（EXPLAIN・DESCRIBE・SHOW CREATE の項目のみ）
#   <label>.gqr-detail.txt     行数・ColumnInfo の Name/Type・先頭 3 行（同上。**実名を含みうる。
#                               とくに B 群は PROBE_DDL=0 のとき実在のテーブルの列名が出るので、
#                               貼る前に確認すること**）
#
# summary の決め手になる列は state・statement_type/substatement_type・loc_shape・
# body_*・meta_*・meta_has_qid・update_count・gqr_rows・gqr_col_types。バケット名・
# プレフィックス・クエリ ID・DB 名は出さず、`<OUTPUT><id>`／`<OUTPUT><id>.csv`／
# `<OUTPUT><id>.txt`／`<OUTPUT>tables/<id>`／other のどれかに畳む。gqr_col_types は
# 列の型だけ（varchar 等）を出し、列名・値そのものは出さない。summary.tsv / summary.txt は
# そのまま貼れる（reason_line・note に文言が入るときは実名があれば置換される）。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください}"
: "${DB:?DB にデータベース名を設定してください}"
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_DIR=${OUT_DIR:-${DEV_HOST_HOME:-$HOME}/athena-keyword-boundary-measurements}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}
PROBE_DDL=${PROBE_DDL:-0}

PROBE_PREFIX=athena_local_probe_200
TABLE_HIVE=$PROBE_PREFIX
TABLE_ICE=${PROBE_PREFIX}_ice
TABLE_C1=${PROBE_PREFIX}_c1
TABLE_C2=${PROBE_PREFIX}_c2
VIEW_V1=${PROBE_PREFIX}_v1
VIEW_V2=${PROBE_PREFIX}_v2

A_LABELS="a1 a1c a2 a2c a3 a3c a4 a4c a5 a5c a6 a6c a7 a7c a8 a8c"
B_LABELS="b1 b1c b1b b2 b2c b3 b3c b3b"
D_LABELS="d1 d1c d1b d2 d2c d3 d3c d4 d4c d5 d5c d6 d6c d7 d7c"
ALL_LABELS="$A_LABELS $B_LABELS $D_LABELS"

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\tstatement_type\tsubstatement_type\tloc_shape\tbody_bytes\tbody_content_type\tmeta_bytes\tmeta_content_type\tmeta_has_qid\tupdate_count\tgqr_rows\tgqr_col_types\treason_line\tnote\n' > "$SUMMARY"
echo "出力先: $RUN_DIR"

# StartQueryExecution を実際に呼んだ回数（再試行も含む）。summary.txt の冒頭に出す。
START_CALL_FILE="$RUN_DIR/.start-calls"
: > "$START_CALL_FILE"
# D 群のオブジェクト作成に着手したかどうか。trap での後始末に使う。
DDL_ATTEMPTED=0

# 生ログの中間ファイルは、途中で止めても残らないよう trap で消す。
# D 群に着手していたら、ベストエフォートで「空白ありの形」＋ IF EXISTS の後始末も投げる
# （本編の後始末でも消すので、これは異常終了時の保険）。
cleanup() {
  rm -f "$RUN_DIR"/.tmp-*
  if [ "$DDL_ATTEMPTED" = 1 ]; then
    for sql in \
      "DROP TABLE IF EXISTS $TABLE_C1" \
      "DROP TABLE IF EXISTS $TABLE_C2" \
      "DROP VIEW IF EXISTS $VIEW_V1" \
      "DROP VIEW IF EXISTS $VIEW_V2" \
      "DROP TABLE IF EXISTS $TABLE_ICE" \
      "DROP TABLE IF EXISTS $TABLE_HIVE"; do
      aws athena start-query-execution --region "$REGION" \
        --query-string "$sql" \
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

# 標準入力から、対象テーブル名（B 群。空なら何もしない）と接頭辞 athena_local_probe_200 を
# 置換して隠す。summary.txt に流し込む文言・エラー文言に使う。
mask_names() {
  local s
  s=$(cat)
  if [ -n "$TARGET_TABLE" ]; then
    s=${s//$TARGET_TABLE/<TT>}
  fi
  s=${s//$PROBE_PREFIX/<PROBE>}
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
    line=$(grep -m1 . "$f")
    sanitize "$(redact "$line")"
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
    sanitize "$(redact "$line")"
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

# .metadata の先頭を protobuf として読み、トップレベルの field 3（varint。DML の更新件数）を返す。
# 無ければ absent。壊れていて読めなければ unreadable。
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

# .metadata の生バイト列の中に QueryExecutionId の文字列が含まれるか（grep -c 程度）。
# ファイルが無ければ "-"。carries_execution_id の実測用。
meta_has_qid_of() {
  local bytes_file=$1 id=$2 n
  [ -s "$bytes_file" ] || { echo "-"; return; }
  n=$(grep -ac -- "$id" "$bytes_file" 2>/dev/null || echo 0)
  if [ "${n:-0}" -gt 0 ]; then echo "yes"; else echo "no"; fi
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

# summary.tsv に 1 行積む。列の並びはヘッダと同じ 15 列で固定する。
emit_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$SUMMARY"
}

# 項目を未測定として summary に 1 行残す。全体を止めずに次へ進む。
skip() {
  local label=$1 note=$2
  echo "== $label: 未測定（$note）"
  emit_row "$label" "SKIPPED" - - - - - - - - - - - - "$(sanitize "$note")"
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

# GetQueryResults を取り、<label>.results.json / .results.err に保存する。
fetch_gqr() {
  local label=$1 id=$2
  aws athena get-query-results --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.results.json" 2> "$RUN_DIR/$label.results.err"
}

# results.json から行数・ColumnInfo の型だけ（型のみ。列名は書かない）・先頭 3 行の「形」を
# <label>.gqr-detail.txt に保存する（実名を含みうるファイルなのでファイルの中にだけ書く）。
# summary.tsv には rows と型のカンマ区切りだけをタブ区切りで返す。
analyze_gqr() {
  local label=$1
  python3 - "$RUN_DIR/$label.results.json" "$RUN_DIR/$label.gqr-detail.txt" <<'PYEOF'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
rows = "-"
types = "-"
lines = []
try:
    rs = json.load(open(src))["ResultSet"]
    data = rs.get("Rows", [])
    rows = str(len(data))
    cols = rs.get("ResultSetMetadata", {}).get("ColumnInfo", [])
    lines.append("rows: %s" % rows)
    lines.append("columns (Name / Type):")
    for c in cols:
        lines.append("  - %s / %s" % (c.get("Name", "-"), c.get("Type", "-")))
    if cols:
        types = ",".join(c.get("Type", "-") for c in cols)
    lines.append("先頭 3 行 (VarCharValue をそのまま、無ければ null):")
    for r in data[:3]:
        vals = [d.get("VarCharValue") for d in r.get("Data", [])]
        lines.append("  - %s" % vals)
except Exception as e:
    lines.append("(results.json を読めませんでした: %s)" % e)
open(dst, "w").write("\n".join(lines) + "\n")
print("%s\t%s" % (rows, types))
PYEOF
}

# ラベルを指定して 1 文を実行し、終端状態まで待って各種の値を採取する。
# want_gqr=1 のときだけ GetQueryResults も追加で呼ぶ（EXPLAIN・DESCRIBE・SHOW CREATE の項目）。
# 成功したときだけ 0 を返す。受け付けたが実行時に FAILED / CANCELLED になった文でも、
# 空白なしの形が本物で FAILED になるのも立派な結果なので、値は必ず採る。
run() {
  local label=$1 sql=$2 want_gqr=${3:-0}
  local id state stype loc sub shape note reason_line
  local body_bytes body_ct meta_bytes meta_ct meta_qid update_count gqr_rows gqr_types

  printf '%s\n' "$sql" > "$RUN_DIR/$label.sql"
  id=$(start_query_retry "$label" "$sql")
  LAST_ATTEMPTS=$(read_attempts "$label")
  if [ -z "${id:-}" ]; then
    note="attempts=$LAST_ATTEMPTS; $(first_err_line "$RUN_DIR/$label.start.err")"
    echo "== $label: 開始できませんでした（試行 $LAST_ATTEMPTS 回）。$RUN_DIR/$label.start.err を見てください"
    emit_row "$label" "START_FAILED" - - - - - - - - - - - - "$(sanitize "$note")"
    return 1
  fi

  state=$(poll_until_terminal "$id")

  aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.execution.json" 2> "$RUN_DIR/$label.execution.err"
  write_reason "$RUN_DIR/$label.execution.json" "$RUN_DIR/$label.reason.txt"
  reason_line=$(reason_first_line "$RUN_DIR/$label.execution.json")

  IFS=$'\t' read -r stype loc sub < <(read_execution_fields "$RUN_DIR/$label.execution.json")
  shape=$(loc_shape_of "$loc" "$id")
  body_bytes="-"; body_ct="-"; meta_bytes="-"; meta_ct="-"; meta_qid="-"; update_count="-"
  gqr_rows="-"; gqr_types="-"

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
      update_count=$(update_count_field_of "$RUN_DIR/$label.metadata.bytes")
      meta_qid=$(meta_has_qid_of "$RUN_DIR/$label.metadata.bytes" "$id")
    fi
  fi

  if [ "$want_gqr" = 1 ]; then
    fetch_gqr "$label" "$id"
    IFS=$'\t' read -r gqr_rows gqr_types < <(analyze_gqr "$label")
  fi

  note="attempts=$LAST_ATTEMPTS"
  case "$state" in
    FAILED | CANCELLED) note="$note; $(error_codes_of "$RUN_DIR/$label.execution.json")" ;;
  esac

  echo "== $label  state=$state  stype=$stype/$sub  loc_shape=$shape  body=$body_bytes($body_ct)  metadata=$meta_bytes($meta_ct) qid=$meta_qid  update_count=$update_count  gqr_rows=$gqr_rows"
  emit_row "$label" "$state" "$stype" "$sub" "$shape" "$body_bytes" "$body_ct" \
    "$meta_bytes" "$meta_ct" "$meta_qid" "$update_count" "$gqr_rows" "$gqr_types" \
    "$reason_line" "$(sanitize "$note")"
  [ "$state" = SUCCEEDED ]
}

# --- preflight ---------------------------------------------------------------

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

IFS=$'\t' read -r _ SHOW_TABLES_LOC _ < <(read_execution_fields "$RUN_DIR/probe-show-tables.execution.json")
if ! fetch "$SHOW_TABLES_LOC" "$RUN_DIR/tables.txt" "$RUN_DIR/tables.err"; then
  echo
  echo "SHOW TABLES の結果を S3 から取れませんでした（$RUN_DIR/tables.err）。"
  echo "PROBE_DDL=1 のときの同名チェックも、PROBE_DDL=0 のときの対象テーブル選びもできないので止まります。"
  exit 1
fi

if [ "$PROBE_DDL" = 1 ] && grep -qi "$PROBE_PREFIX" "$RUN_DIR/tables.txt"; then
  echo
  echo "このデータベースに ${PROBE_PREFIX}* という名前のテーブル／ビューが既にあります。"
  echo "上書き・削除してしまうので、何も作らずに止まります。一覧: $RUN_DIR/tables.txt"
  exit 1
fi

# --- B 群の対象テーブルを決める -----------------------------------------------
# PROBE_DDL=1 のときは D 群のセットアップで作る Hive テーブル。
# PROBE_DDL=0 のときは SHOW TABLES の 1 件目（実在のテーブル）。名前は小文字で使う。
TARGET_TABLE=""
if [ "$PROBE_DDL" = 1 ]; then
  TARGET_TABLE=$TABLE_HIVE
else
  TARGET_TABLE=$(head -n1 "$RUN_DIR/tables.txt" 2>/dev/null | tr -d '\r' | tr '[:upper:]' '[:lower:]')
fi

# --- D 群のセットアップ（PROBE_DDL=1 のときだけ） ------------------------------

D_SETUP_OK=0
if [ "$PROBE_DDL" = 1 ]; then
  DDL_ATTEMPTED=1
  # Hive テーブル（雛形 tools/measure/alter-variants.sh の prep-hive と同じ作り方）。
  # ALTER TABLE の対象、かつ B 群の対象テーブルを兼ねる。
  if run d0-setup-hive "CREATE TABLE $DB.$TABLE_HIVE AS SELECT 1 AS n, 'x' AS s, 10 AS x"; then
    D_SETUP_OK=1
  else
    echo "== d0-setup-hive: Hive の準備テーブルが作れませんでした。B 群・D 群は未測定にします。"
    TARGET_TABLE=""
  fi
fi

# --- A 群（DDL 無し・スキャン無し。常に流す） ----------------------------------

run a1  "SELECT(1)"
run a1c "SELECT (1)"
run a2  "SELECT'a'"
run a2c "SELECT 'a'"
run a3  "SELECT*FROM (VALUES 1)"
run a3c "SELECT * FROM (VALUES 1)"
run a4  'SELECT"x" FROM (VALUES 1) AS t(x)'
run a4c 'SELECT "x" FROM (VALUES 1) AS t(x)'
run a5  'WITH"w" AS (SELECT 1 AS x) SELECT x FROM "w"'
run a5c 'WITH "w" AS (SELECT 1 AS x) SELECT x FROM "w"'
run a6  "VALUES(1)"
run a6c "VALUES (1)"
run a7  "EXPLAIN(TYPE IO) SELECT 1" 1
run a7c "EXPLAIN (TYPE IO) SELECT 1" 1
run a8  "EXPLAIN(SELECT 1)" 1
run a8c "EXPLAIN (SELECT 1)" 1

# --- B 群（既存テーブルへの読み取り） ------------------------------------------

if [ -z "$TARGET_TABLE" ]; then
  for label in $B_LABELS; do
    skip "$label" "対象テーブルが決められないため未測定（SHOW TABLES が空、または d0-setup-hive が失敗）"
  done
else
  echo "== B 群の対象テーブル: <TT>（実名は伏せる。$RUN_DIR/tables.txt か $RUN_DIR/d0-setup-hive.sql を参照）"
  run b1  "DESCRIBE\"$TARGET_TABLE\"" 1
  run b1c "DESCRIBE \"$TARGET_TABLE\"" 1
  run b1b "DESCRIBE $TARGET_TABLE" 1
  run b2  "DESC\"$TARGET_TABLE\"" 1
  run b2c "DESC \"$TARGET_TABLE\"" 1
  run b3  "SHOW CREATE TABLE\"$TARGET_TABLE\"" 1
  run b3c "SHOW CREATE TABLE \"$TARGET_TABLE\"" 1
  run b3b "SHOW CREATE TABLE $TARGET_TABLE" 1
fi

# --- D 群（PROBE_DDL=1 のときだけ） --------------------------------------------

if [ "$PROBE_DDL" != 1 ]; then
  for label in $D_LABELS; do
    skip "$label" "PROBE_DDL=0 のため未測定"
  done
elif [ "$D_SETUP_OK" != 1 ]; then
  for label in $D_LABELS; do
    skip "$label" "d0-setup-hive が失敗したため未測定（対象テーブルが無い）"
  done
else
  # d1 系。alter-variants.sh の成功形（ADD COLUMNS (m int)）に合わせ、列名だけ変えて独立させる。
  run d1  "ALTER TABLE\"$TABLE_HIVE\" ADD COLUMNS (m1 int)"
  run d1c "ALTER TABLE \"$TABLE_HIVE\" ADD COLUMNS (m2 int)"
  run d1b "ALTER TABLE $TABLE_HIVE ADD COLUMNS (m3 int)"

  # d2/d3（c1）と d2c/d3c（c2）は独立の対。片方が失敗しても他方は続ける。
  D2_OK=0
  if run d2 "CREATE TABLE\"$TABLE_C1\" AS SELECT 1 AS x"; then D2_OK=1; fi
  if [ "$D2_OK" = 1 ]; then
    run d3 "DROP TABLE\"$TABLE_C1\""
  else
    skip d3 "d2 が作れなかったので未測定（読み元のテーブルが無い）"
    aws athena start-query-execution --region "$REGION" \
      --query-string "DROP TABLE IF EXISTS $TABLE_C1" \
      --query-execution-context "Catalog=$CATALOG,Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
  fi

  D2C_OK=0
  if run d2c "CREATE TABLE \"$TABLE_C2\" AS SELECT 1 AS x"; then D2C_OK=1; fi
  if [ "$D2C_OK" = 1 ]; then
    run d3c "DROP TABLE \"$TABLE_C2\""
  else
    skip d3c "d2c が作れなかったので未測定（読み元のテーブルが無い）"
    aws athena start-query-execution --region "$REGION" \
      --query-string "DROP TABLE IF EXISTS $TABLE_C2" \
      --query-execution-context "Catalog=$CATALOG,Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
  fi

  # d4/d5/d6（v1）と d4c/d5c/d6c（v2）も同じ形。d4 が失敗したら d5・d6 は測らず後始末だけ。
  D4_OK=0
  if run d4 "CREATE VIEW\"$VIEW_V1\" AS SELECT 1 AS x"; then D4_OK=1; fi
  if [ "$D4_OK" = 1 ]; then
    run d5 "SHOW CREATE VIEW\"$VIEW_V1\"" 1
    run d6 "DROP VIEW\"$VIEW_V1\""
  else
    skip d5 "d4 が作れなかったので未測定（読み元のビューが無い）"
    skip d6 "d4 が作れなかったので未測定（読み元のビューが無い）"
    aws athena start-query-execution --region "$REGION" \
      --query-string "DROP VIEW IF EXISTS $VIEW_V1" \
      --query-execution-context "Catalog=$CATALOG,Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
  fi

  D4C_OK=0
  if run d4c "CREATE VIEW \"$VIEW_V2\" AS SELECT 1 AS x"; then D4C_OK=1; fi
  if [ "$D4C_OK" = 1 ]; then
    run d5c "SHOW CREATE VIEW \"$VIEW_V2\"" 1
    run d6c "DROP VIEW \"$VIEW_V2\""
  else
    skip d5c "d4c が作れなかったので未測定（読み元のビューが無い）"
    skip d6c "d4c が作れなかったので未測定（読み元のビューが無い）"
    aws athena start-query-execution --region "$REGION" \
      --query-string "DROP VIEW IF EXISTS $VIEW_V2" \
      --query-execution-context "Catalog=$CATALOG,Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
  fi

  # d7 系。Iceberg テーブルを 1 つ作り、OPTIMIZE の両形を同じテーブルに順に投げてから消す
  # （OPTIMIZE はデータを書き換えるだけでスキーマは変えないので、同じテーブルを使い回せる）。
  D7_SETUP_OK=0
  if run d7-setup-ice "CREATE TABLE $DB.$TABLE_ICE WITH (table_type = 'ICEBERG', location = '${OUTPUT}tables-probe-200-ice/', is_external = false) AS SELECT 1 AS n"; then
    D7_SETUP_OK=1
  fi
  if [ "$D7_SETUP_OK" = 1 ]; then
    run d7  "OPTIMIZE\"$TABLE_ICE\" REWRITE DATA USING BIN_PACK"
    run d7c "OPTIMIZE \"$TABLE_ICE\" REWRITE DATA USING BIN_PACK"
    run z-drop-ice "DROP TABLE IF EXISTS $TABLE_ICE"
  else
    skip d7 "d7-setup-ice が作れなかったので未測定（対象の Iceberg テーブルが無い）"
    skip d7c "d7-setup-ice が作れなかったので未測定（対象の Iceberg テーブルが無い）"
  fi

  # D 群の最後: セットアップの Hive テーブルを DROP する。
  run z-drop-hive "DROP TABLE IF EXISTS $TABLE_HIVE"

  # 後始末の DROP が（実際に投げたものは）全部 SUCCEEDED になったら、trap での二度目の
  # DROP を省く。d2/d2c・d4/d4c が失敗して d3/d3c・d5・d6/d6c を skip した枠は、その場で
  # 投げた IF EXISTS の後始末を確かめられない（run() を通さないので reason.txt が無い）ので、
  # 安全側に倒して「投げたことにしない」＝ DROP_ALL_OK=0 のままにし、trap の保険を必ず残す。
  drop_succeeded() {
    [ -s "$RUN_DIR/$1.reason.txt" ] && grep -q "^State: SUCCEEDED" "$RUN_DIR/$1.reason.txt"
  }
  DROP_ALL_OK=1
  if [ "$D2_OK" = 1 ]; then drop_succeeded d3 || DROP_ALL_OK=0; else DROP_ALL_OK=0; fi
  if [ "$D2C_OK" = 1 ]; then drop_succeeded d3c || DROP_ALL_OK=0; else DROP_ALL_OK=0; fi
  if [ "$D4_OK" = 1 ]; then drop_succeeded d6 || DROP_ALL_OK=0; else DROP_ALL_OK=0; fi
  if [ "$D4C_OK" = 1 ]; then drop_succeeded d6c || DROP_ALL_OK=0; else DROP_ALL_OK=0; fi
  if [ "$D7_SETUP_OK" = 1 ]; then drop_succeeded z-drop-ice || DROP_ALL_OK=0; fi
  drop_succeeded z-drop-hive || DROP_ALL_OK=0
  if [ "$DROP_ALL_OK" = 1 ]; then
    DDL_ATTEMPTED=0
  else
    echo "== 後始末の DROP に成功しなかったものがあります。終了時にもう一度投げます。"
    echo "   それでも消えなければ、$DB の ${PROBE_PREFIX}* を手で消してください。"
  fi

  # Iceberg 以外（Hive の既定）は外部テーブル相当で、DROP TABLE では $OUTPUT 下のデータは
  # 消えない。手で消すためのヒントを書き出す（実名を含むので summary.txt には入れない）。
  {
    echo "# ${PROBE_PREFIX}（Hive）のデータは DROP TABLE では消えません（外部テーブルのため）。"
    echo "# 消したければ aws s3 rm --recursive <${OUTPUT}${PROBE_PREFIX}/ 相当のパス> のように手で消してください。"
    echo "# ${PROBE_PREFIX}_ice（Iceberg）は WITH (location=...) を付けたので DROP TABLE でデータも消えます。"
  } > "$RUN_DIR/cleanup-hints.txt"
fi

# --- summary -----------------------------------------------------------------

write_summary_txt() {
  local txt="$RUN_DIR/summary.txt"
  {
    echo "# issue #200: キーワードの直後に空白なしで記号・引用符・括弧が続く SQL の分類を実測"
    echo "# 実行日時: $(date -Iseconds)"
    echo "# 本物への呼び出し回数の見込み（StartQueryExecution。再試行込みの実測値）: $(wc -l < "$START_CALL_FILE" | tr -d ' ')"
    echo "#   ※ GetQueryExecution / GetQueryResults / S3 への呼び出しはこの回数に含めない（課金には影響しない）。"
    if [ "$PROBE_DDL" = 1 ]; then
      echo "# DDL (PROBE_DDL): あり。${PROBE_PREFIX}{,_c1,_c2,_v1,_v2,_ice} を作成→DROP（作れたものだけ）。"
    else
      echo "# DDL (PROBE_DDL): 無し（既定）。D 群は未測定。"
    fi
    echo "# 課金: スキャンの無い計算クエリと小さな CTAS だけ（実テーブルのスキャンは無い）。"
    echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
    echo "#       また、ワークグループの設定はコンソールで変更済みかもしれず、工場出荷時の既定とは限らない。"
    echo
    echo "## 投げた文（DB 名・テーブル名は伏せる。実名は各 <label>.sql を参照）"
    for label in probe-show-tables d0-setup-hive $A_LABELS $B_LABELS d7-setup-ice $D_LABELS z-drop-ice z-drop-hive; do
      [ -s "$RUN_DIR/$label.sql" ] && echo "- $label: $(sanitize "$(redact "$(mask_names < "$RUN_DIR/$label.sql")")")"
    done
    echo
    echo "## 項目ごとの結果"
    echo "#   loc_shape       OutputLocation の末尾の形"
    echo "#   body_*/meta_*   結果本体・.metadata（バイト数・Content-Type。- なら置かれていない）"
    echo "#   meta_has_qid    .metadata の中に QueryExecutionId の文字列が含まれるか（grep -c）"
    echo "#   update_count    .metadata の field 3（DML の更新件数）。absent なら field 自体が無い"
    echo "#   gqr_rows/types  EXPLAIN・DESCRIBE・SHOW CREATE の項目だけ GetQueryResults の行数と列の型"
    echo "#                   （列名・値は summary に出さない。<label>.gqr-detail.txt を見ること）"
    echo "#   reason_line     StateChangeReason の 1 行目（無ければ -）"
    python3 - "$SUMMARY" <<'PYEOF'
import csv, sys
with open(sys.argv[1], newline="") as f:
    for row in csv.DictReader(f, delimiter="\t"):
        print(
            "- {label}: state={state} statement_type={statement_type}/{substatement_type} "
            "loc_shape={loc_shape} body={body_bytes}B/{body_content_type} "
            "meta={meta_bytes}B/{meta_content_type} meta_has_qid={meta_has_qid} "
            "update_count={update_count} gqr_rows={gqr_rows} gqr_col_types={gqr_col_types} "
            "reason={reason_line} note={note}".format(**row)
        )
PYEOF
    echo
    echo "## 開始できなかった項目の文言（実名は伏せる）"
    for label in $ALL_LABELS; do
      if [ -s "$RUN_DIR/$label.start.err" ]; then
        echo "### $label"
        redact "$(cat "$RUN_DIR/$label.start.err")" | mask_names
        echo
      fi
    done
    echo
    echo "## 失敗した項目の理由（実名を含みうるので貼る前に確認すること）"
    for label in probe-show-tables d0-setup-hive $A_LABELS $B_LABELS d7-setup-ice $D_LABELS; do
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
[ -f "$RUN_DIR/cleanup-hints.txt" ] && echo "消し残しのヒント: $RUN_DIR/cleanup-hints.txt（貼らないこと）"
echo "中身のファイルは $RUN_DIR にあります。リポジトリには入れないでください。"
echo "<label>.sql・<label>.reason.txt・<label>.gqr-detail.txt は実名（DB 名・テーブル名・列名）を"
echo "含みうるので、summary.txt 以外を貼るときは中身を確かめてください。"
