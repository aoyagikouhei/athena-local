#!/usr/bin/env bash
# 本物の Athena が S3 に置く結果ファイルの Content-Type が、文によって
# `binary/octet-stream` と `application/octet-stream` に分かれる規則を実測する。
# issue #70 のための実測スクリプト。
#
# これまでに分かっていること（過去 16 ラウンド・約 140 件の head-object の集計）:
#   - 同じ SQL は日をまたいでも常に同じ値（`SELECT 1` は 20 件すべて binary。
#     先頭コメントを付けても同じ）。
#   - binary だったもの: `SELECT 1`、`SELECT 1 AS i`、`SHOW TABLES`、0 バイトの DDL。
#   - application だったもの: `SELECT 1 AS i WHERE false`、複数列の `SELECT`、
#     `SELECT * FROM t LIMIT 1`、`DESCRIBE`、`SHOW CREATE TABLE`、`EXPLAIN`。
#   - 140 MB の本体（ETag が `-N` 付きのマルチパート）は binary で、その `.metadata` は application。
#   - 行数・列数・型・サイズ・実行統計（QueryPlanningTimeInMillis の有無）・ETag の形・
#     書き込み時刻のどれとも相関しなかった。
# そこで今回は「条件を 1 つだけ変えた対」を同じラウンドに入れて、規則を決めにいく。
#
# 使い方:
#   OUTPUT=s3://your-bucket/prefix/ DB=your_db TABLE=small_table bash 70-measure-content-type.sh
#
# ** 課金の注意（先に読むこと） **
#   テーブルをスキャンするのは項目 b13（`SELECT 1 FROM <db>.<t> LIMIT 1`）の 1 件だけ。
#   ほかの項目は定数・メタデータ・`UNNEST(sequence(...))` だけで、テーブルを読まない。
#   DDL は一切実行しない（作成・変更・削除はしない。読み取りだけ）。
#   ただし d 系は 1 万〜300 万行の結果を S3 に書くので、結果ファイルの保管料と
#   S3 の PUT/GET は発生する。
#
# 必要な環境変数:
#   OUTPUT    結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける。無ければ足す）。
#   DB        データベース名。実在するものを指定する。
#
# 任意の環境変数:
#   TABLE       対象テーブル名（<DB> の中の名前。修飾なし。二重引用符が要る名前は
#               そのままでは通らないので、引用符の要らない小さなテーブルを選ぶこと）。
#               省略すると preflight で `SHOW TABLES IN <DB>` を 1 本流して 1 件目を使う。
#               1 件も無ければ、テーブルを要る項目（b13, c3, c4, c5, c8, c10）を未測定にする。
#               ** TABLE を明示したほうが良い理由 **: 省略すると preflight で
#               `SHOW TABLES IN <DB>` を流すので、項目 c1（同じ SQL）が同一ラウンドの
#               2 回目になってしまう。1 回目・2 回目の比較をしたいなら TABLE を明示すること。
#   CATALOG     既定 AwsDataCatalog
#   REGION      既定 ap-northeast-1
#   OUT_DIR     既定 $HOME/athena-content-type-measurements（実名が入るのでリポジトリの外に出す）
#   POLL_TIMEOUT 終端状態を待つ上限（秒）。既定 300
#                （d 系は 100 万〜300 万行を書き出すので 30 秒程度かかりうる）
#   RETRY_MAX   名前解決・接続など一時的な失敗を再試行する回数の上限。既定 4
#   RETRY_DELAY 再試行の間隔（秒）。既定 5
#
# 項目（すべて実行順。★ はテーブルをスキャンする唯一の項目）:
#   A. 対照と、初めて流す SQL の 1 回目・2 回目
#     a1-select-1          SELECT 1                       対照。過去は binary
#     a2-fresh-first       SELECT <乱数 5 桁> AS fresh     一度も流していない SQL の 1 回目
#     a3-fresh-second      （a2 と全く同じ文字列）          2 回目。キャッシュの有無
#     a4-where-false       SELECT 1 AS i WHERE false      過去に 1 回だけ application
#   B. 1 行の SELECT の形を 1 つずつ変える（binary だった `SELECT 1` から 1 要素だけ変える）
#     b1-two-int-cols      SELECT 1, 2
#     b2-varchar           SELECT 'a'
#     b3-double            SELECT CAST(1.5 AS DOUBLE)
#     b4-decimal-literal   SELECT 1.5
#     b5-alias             SELECT 1 AS i                  対照。過去は binary
#     b6-boolean           SELECT true
#     b7-null              SELECT NULL
#     b8-where-true        SELECT 1 WHERE true
#     b9-values            SELECT * FROM (VALUES 1)
#     b10-expression       SELECT 1 + 1
#     b11-bigint-cast      SELECT CAST(1 AS BIGINT)
#     b12-two-rows         SELECT 1 UNION ALL SELECT 2
#     b13-from-table-limit1 ★ SELECT 1 FROM <db>.<t> LIMIT 1   唯一のスキャン
#     b14-int-and-varchar  SELECT 1, 'a'
#   C. SHOW / DESCRIBE 系（本体は `.txt`）
#     c1-show-tables       SHOW TABLES IN <db>            対照。過去は binary
#     c2-show-databases    SHOW DATABASES
#     c3-show-columns      SHOW COLUMNS IN <db>.<t>
#     c4-show-tblproperties SHOW TBLPROPERTIES <db>.<t>
#     c5-describe          DESCRIBE <db>.<t>              対照。過去は application
#     c6-show-tables-nomatch SHOW TABLES IN <db> '...%'   0 行の SHOW
#     c7-show-views        SHOW VIEWS IN <db>
#     c8-show-partitions   SHOW PARTITIONS <db>.<t>       パーティション無しなら FAILED でよい
#     c9-explain           EXPLAIN SELECT 1               対照。過去は application
#     c10-show-create-table SHOW CREATE TABLE <db>.<t>    対照。過去は application
#   D. スキャン無しで結果サイズだけを変える（`sequence` は 1 万要素が上限なので cross join で増やす）
#     d0-rows-1 / d1-rows-10 / d2-rows-1000 / d3-rows-100k / d4-rows-1m / d5-rows-3m
#   E. 対照の再実行
#     e1-select-1-again    SELECT 1                       a1 と同じ。同一ラウンド内の 2 回目
#
# preflight（本編の前。どちらもスキャンしない）:
#   preflight-select-1    SELECT 1  疎通確認。終端状態まで到達し、本体と `.metadata` の
#                                   head-object が取れることまで確かめる。落ちたらここで止まる。
#                                   （`SELECT 1` は a1・e1 と同じ SQL なので、このラウンドでは
#                                    `SELECT 1` を 3 回流すことになる。3 回とも記録する。）
#   preflight-show-tables SHOW TABLES IN <DB>  TABLE を省略したときだけ流す。
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
#                               （本体が大きい項目はダウンロードしない。下の定数を見ること）
#   <label>.cp.err              本体を取れなかったときの stderr（= 本体が無いことの証拠）
#   <label>.metadata.bytes / .metadata.od.txt  .metadata の中身と 16 進（無ければ作らない）
#   <label>.metadata.cp.err     .metadata を取れなかったときの stderr（= 無いことの証拠）
#   <label>.head.json / <label>.metadata.head.json  head-object の応答（Content-Type と ETag）
#   <label>.head.err / <label>.metadata.head.err    head-object が失敗したときの stderr
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
OUT_DIR=${OUT_DIR:-$HOME/athena-content-type-measurements}
POLL_TIMEOUT=${POLL_TIMEOUT:-300}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}

# 本体をダウンロードする上限（バイト）。これを超える本体は head-object の ContentLength と
# ETag だけを記録して、中身は取りに行かない（d 系は数百万行になるため）。
# `.metadata` は小さいので常に取る。
MAX_BODY_DOWNLOAD_BYTES=$((1024 * 1024))
# od に流す先頭バイト数。本体が大きいと od の出力はその 4〜5 倍になるので頭だけにする。
OD_HEAD_BYTES=4096

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
printf 'label\tstate\tstatement_type\tsubstatement_type\toutput_ext\tbody_bytes\tbody_etag_form\tbody_content_type\tmetadata_bytes\tmetadata_content_type\tplanning_ms\tengine_ms\tgqr_rows\tgqr_cols\tscanned_bytes\tnote\n' > "$SUMMARY"

echo "出力先: $RUN_DIR"
echo "スキャンするのは項目 b13（SELECT 1 FROM <db>.<t> LIMIT 1）の 1 件だけです。"
echo "DDL は実行しません（読み取りだけ）。"
echo "対象テーブル: ${TABLE:-（未指定。preflight の SHOW TABLES の 1 件目を使う）}"

# 最後まで走り切ったか。走り切らなかったら INCOMPLETE.txt を残して、途中の run と分かるようにする。
COMPLETED=0
# テーブルの決め方（summary.md に出す）。preflight の前に初期化しておく。
TABLE_NOTE="（未確定）"
# 異常終了した理由（summary.md の冒頭に出す）。
ABORT_NOTE=""
# a2 / a3 に使う乱数 5 桁。実名ではないのでマスクしない。
FRESH_N=$(( (RANDOM % 90000) + 10000 ))
FRESH_SQL="SELECT $FRESH_N AS fresh"
# run が最後に測った値。preflight の判定に使う。
LAST_STATE=""
LAST_BODY_CTYPE="-"
LAST_META_CTYPE="-"
LAST_ATTEMPTS=0

# 中間ファイルは、途中で止めても残らないよう trap で消す。DDL を投げないので後始末は無い。
cleanup() {
  rm -f "$RUN_DIR"/.tmp-*
  if [ "$COMPLETED" != 1 ]; then
    {
      echo "この run は最後まで走り切っていません（$(date -Iseconds)）。"
      echo "summary.tsv は途中までの行しか無いことがあります。"
    } > "$RUN_DIR/INCOMPLETE.txt" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ---- 本物への呼び出し回数のカウンタ -------------------------------------
# 数える場所の一部（ポーリングなど）はコマンド置換のサブシェルの中なので、変数ではなく
# ファイルで数える。呼び出しは逐次なので、上書きし合うことは無い。
bump() {
  local f="$RUN_DIR/.tmp-count-$1" n=0
  if [ -s "$f" ]; then n=$(cat "$f"); fi
  echo $((n + 1)) > "$f"
}
counter() {
  local f="$RUN_DIR/.tmp-count-$1"
  if [ -s "$f" ]; then cat "$f"; else echo 0; fi
}

# ---- 文字列の整形 -------------------------------------------------------
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
  grep -qiE 'Could not connect|Connection aborted|Connection reset|EndpointConnectionError|Temporary failure in name resolution|Name or service not known|Network is unreachable|Read timed out|[Cc]onnect timeout|ConnectTimeoutError|ReadTimeoutError|SSLError|Broken pipe|ThrottlingException|TooManyRequestsException|RequestLimitExceeded|ServiceUnavailable|InternalServerError|InternalFailure|SlowDown|503' "$1"
}

# ---- S3 ------------------------------------------------------------------
# S3 のオブジェクトを手元のファイルに取る。書き込むのはこのシェル。
fetch() {
  local src=$1 dest=$2 err=$3
  bump s3
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
  bump s3
  if aws s3api head-object --region "$REGION" --bucket "$bucket" --key "$key" > "$dest" 2> "$err"; then
    rm -f "$err"
    return 0
  fi
  rm -f "$dest"
  return 1
}

# head-object の応答から ContentType / ContentLength / ETag の形をタブ区切りで返す。
# ETag は引用符を外して見て、`-` を含めば multipart（= マルチパートで書かれた）、
# 含まなければ single。jq が無いこともあるので python3 で読む。
head_fields() {
  # `--` を付けないと printf が先頭の `-` をオプションと見て落ちる。
  [ -s "$1" ] || { printf -- '-\t-\t-\n'; return; }
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("-\t-\t-")
    sys.exit(0)
ct = d.get("ContentType") or "-"
cl = d.get("ContentLength")
cl = "-" if cl is None else str(cl)
et = (d.get("ETag") or "").strip("\"")
form = "-" if not et else ("multipart" if "-" in et else "single")
print("%s\t%s\t%s" % (ct, cl, form))' "$1"
}

# ---- GetQueryExecution / GetQueryResults の読み出し ----------------------
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

# execution.json から Statistics をそのままファイルに書き出し、
# DataScannedInBytes / QueryPlanningTimeInMillis / EngineExecutionTimeInMillis を
# タブ区切りで返す。無い項目は "-"（QueryPlanningTimeInMillis は文によって無い）。
write_statistics() {
  local src=$1 dest=$2
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception:
    open(sys.argv[2], "w").write("{}\n")
    print("-\t-\t-")
    sys.exit(0)
stats = d.get("Statistics", {})
open(sys.argv[2], "w").write(json.dumps(stats, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
def g(k):
    v = stats.get(k)
    return "-" if v is None else str(v)
print("%s\t%s\t%s" % (g("DataScannedInBytes"), g("QueryPlanningTimeInMillis"), g("EngineExecutionTimeInMillis")))' "$src" "$dest"
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

# results.json の Rows の「形」をタブ区切りで返す: 行数 / 1 行目の列数。
# 値そのものは実データを含みうるので出さない（この issue では中身は要らない）。
rows_shape() {
  [ -s "$1" ] || { printf -- '-\t-\n'; return; }
  python3 -c 'import json, sys
try:
    rows = json.load(open(sys.argv[1]))["ResultSet"]["Rows"]
except Exception:
    print("-\t-")
    sys.exit(0)
cols = len(rows[0].get("Data", [])) if rows else "-"
print("%s\t%s" % (len(rows), cols))' "$1"
}

# ---- Athena の呼び出し ---------------------------------------------------
# 今の State だけを 1 回取って返す（待たない）。
get_state_once() {
  local id=$1 state
  bump gqe
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
# （実際の SQL エラーは 1 回で確定させる）。試行回数は .tmp-attempts に残す。
# この関数はクエリ ID を標準出力に返すので、呼び出し側は `$( )` で受ける。
# つまり中身はサブシェルで走り、変数への代入は呼び出し側に戻らない。
start_query_retry() {
  local label=$1 sql=$2
  local attempt=1 id
  while :; do
    bump start
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

# start_query_retry がサブシェルに残した試行回数を呼び出し側に取り込む。
absorb_attempts() {
  if [ -s "$RUN_DIR/.tmp-attempts" ]; then
    LAST_ATTEMPTS=$(cat "$RUN_DIR/.tmp-attempts")
  else
    LAST_ATTEMPTS=0
  fi
}

# ---- 項目の実行 ----------------------------------------------------------
# 項目を未測定として summary に 1 行残す。全体を止めずに次へ進む。
skip() {
  local label=$1 note=$2
  echo "== $label: 未測定（$note）"
  printf '%s\tSKIPPED\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t%s\n' "$label" "$(clean "$note")" >> "$SUMMARY"
}

# ラベルを指定して 1 文を実行し、終端状態まで待って Content-Type 等を採取する。
# 第 3 引数は GetQueryResults の --max-items（既定 3。0 を渡すと指定せず全件取る）。
# 項目ごとに独立していて、失敗しても全体は止めない。成功したときだけ 0 を返す。
# 最後に測った値を LAST_STATE / LAST_BODY_CTYPE / LAST_META_CTYPE に残す（preflight の判定用）。
run() {
  local label=$1 sql=$2 max_items=${3:-3}
  local id state stype sstype loc out_ext note scanned planning engine
  local body_bytes body_etag body_ctype meta_bytes meta_etag meta_ctype
  local gqr_rows gqr_cols numeric size_for_od

  LAST_STATE=""
  LAST_BODY_CTYPE="-"
  LAST_META_CTYPE="-"

  {
    echo "# label: $label"
    echo "# Catalog: $CATALOG"
    echo "# Database: $DB"
    echo "# OutputLocation: $OUTPUT"
    echo "# SQL（次の行から最後まで）:"
    printf '%s\n' "$sql"
  } > "$RUN_DIR/$label.request.txt"

  id=$(start_query_retry "$label" "$sql")
  absorb_attempts
  if [ -z "${id:-}" ]; then
    note="attempts=$LAST_ATTEMPTS; $(first_err_line "$RUN_DIR/$label.start.err")"
    if ! grep -q "An error occurred" "$RUN_DIR/$label.start.err" 2>/dev/null; then
      note="$note; CLI が送信前に拒否した可能性"
    fi
    echo "== $label: 開始できませんでした（試行 $LAST_ATTEMPTS 回）。$RUN_DIR/$label.start.err を見てください"
    printf '%s\tSTART_FAILED\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t%s\n' "$label" "$(clean "$note")" >> "$SUMMARY"
    return 1
  fi

  state=$(poll_until_terminal "$id")
  LAST_STATE=$state

  bump gqe
  aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.execution.json" 2> "$RUN_DIR/$label.execution.err"
  bump gqr
  if [ "$max_items" = 0 ]; then
    aws athena get-query-results --region "$REGION" --query-execution-id "$id" \
      > "$RUN_DIR/$label.results.json" 2> "$RUN_DIR/$label.results.err"
  else
    aws athena get-query-results --region "$REGION" --query-execution-id "$id" \
      --max-items "$max_items" \
      > "$RUN_DIR/$label.results.json" 2> "$RUN_DIR/$label.results.err"
  fi
  write_reason "$RUN_DIR/$label.execution.json" "$RUN_DIR/$label.reason.txt"
  IFS=$'\t' read -r scanned planning engine \
    < <(write_statistics "$RUN_DIR/$label.execution.json" "$RUN_DIR/$label.statistics.json")

  IFS=$'\t' read -r stype sstype loc < <(read_execution_fields "$RUN_DIR/$label.execution.json")
  IFS=$'\t' read -r gqr_rows gqr_cols < <(rows_shape "$RUN_DIR/$label.results.json")

  out_ext="-"; body_bytes="-"; body_etag="-"; body_ctype="-"
  meta_bytes="-"; meta_etag="-"; meta_ctype="-"
  note="attempts=$LAST_ATTEMPTS"

  if [ -n "$loc" ]; then
    # 出力ファイルの拡張子だけを見る（`<id>.csv` / `<id>.txt` / `<id>` / `tables/<id>`）。
    case "$loc" in
      *.csv) out_ext="csv" ;;
      *.txt) out_ext="txt" ;;
      *) out_ext="none" ;;
    esac

    { echo "# ls $loc"; bump s3; aws s3 ls "$loc"; echo "# rc=$?"
      echo "# ls $loc.metadata"; bump s3; aws s3 ls "$loc.metadata"; echo "# rc=$?"
    } > "$RUN_DIR/$label.ls.txt" 2>&1

    # 本体: head-object を先に取る。サイズが大きければ中身は取りに行かない。
    if head_object "$loc" "$RUN_DIR/$label.head.json" "$RUN_DIR/$label.head.err"; then
      IFS=$'\t' read -r body_ctype body_bytes body_etag < <(head_fields "$RUN_DIR/$label.head.json")
    fi
    case "$body_bytes" in
      '' | *[!0-9]*) numeric=0 ;;
      *) numeric=1 ;;
    esac
    if [ "$numeric" = 1 ] && [ "$body_bytes" -gt "$MAX_BODY_DOWNLOAD_BYTES" ]; then
      note="$note; 本体は ${body_bytes}B で上限 ${MAX_BODY_DOWNLOAD_BYTES}B を超えるため未取得（head-object だけ）"
    elif fetch "$loc" "$RUN_DIR/$label.bytes" "$RUN_DIR/$label.cp.err"; then
      size_for_od=$(wc -c < "$RUN_DIR/$label.bytes" | tr -d ' ')
      if [ "${size_for_od:-0}" -gt "$OD_HEAD_BYTES" ]; then
        { echo "# 先頭 $OD_HEAD_BYTES バイトだけ（本体は $size_for_od バイト）"
          head -c "$OD_HEAD_BYTES" "$RUN_DIR/$label.bytes" | od -c
        } > "$RUN_DIR/$label.od.txt"
      else
        od -c "$RUN_DIR/$label.bytes" > "$RUN_DIR/$label.od.txt"
      fi
      # head-object が取れなかったときだけ、実ファイルのサイズで埋める。
      if [ "$body_bytes" = "-" ]; then
        body_bytes=$size_for_od
      fi
    fi

    # .metadata: 小さいので常に取る。
    if head_object "$loc.metadata" "$RUN_DIR/$label.metadata.head.json" "$RUN_DIR/$label.metadata.head.err"; then
      IFS=$'\t' read -r meta_ctype meta_bytes meta_etag < <(head_fields "$RUN_DIR/$label.metadata.head.json")
    fi
    if fetch "$loc.metadata" "$RUN_DIR/$label.metadata.bytes" "$RUN_DIR/$label.metadata.cp.err"; then
      od -tx1c "$RUN_DIR/$label.metadata.bytes" > "$RUN_DIR/$label.metadata.od.txt"
      if [ "$meta_bytes" = "-" ]; then
        meta_bytes=$(wc -c < "$RUN_DIR/$label.metadata.bytes" | tr -d ' ')
      fi
    fi
    # .metadata の ETag の形は使わないが、読んだことを黙らせないため note に残す。
    if [ "$meta_etag" != "-" ] && [ "$meta_etag" != "single" ]; then
      note="$note; metadata_etag=$meta_etag"
    fi
  else
    note="$note; OutputLocation が返らなかった"
  fi

  case "$state" in
    FAILED | CANCELLED | TIMEOUT) note="$note; $(error_codes_of "$RUN_DIR/$label.execution.json")" ;;
  esac

  LAST_BODY_CTYPE=$body_ctype
  LAST_META_CTYPE=$meta_ctype

  echo "== $label  state=$state  ext=$out_ext  body=${body_bytes}B/$body_etag  ctype=$body_ctype  metadata=${meta_bytes}B/$meta_ctype  gqr=${gqr_rows}行×${gqr_cols}列"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$label" "$state" "$stype" "$sstype" "$out_ext" "$body_bytes" "$body_etag" "$body_ctype" \
    "$meta_bytes" "$meta_ctype" "$planning" "$engine" "$gqr_rows" "$gqr_cols" "$scanned" \
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

# ---- summary の生成 ------------------------------------------------------
# summary.tsv を Markdown の表にする。main は Content-Type、detail は相関を疑う値。
# 値は summary.tsv に書いた時点で redact 済みなので、ここでは整形だけ。
md_table() {
  python3 - "$SUMMARY" "$1" <<'PYEOF'
import csv, sys

MAIN = [
    ("label", "項目"),
    ("state", "State"),
    ("statement_type", "StatementType"),
    ("substatement_type", "SubstatementType"),
    ("output_ext", "拡張子"),
    ("body_content_type", "本体の Content-Type"),
    ("metadata_content_type", ".metadata の Content-Type"),
    ("note", "備考"),
]
DETAIL = [
    ("label", "項目"),
    ("body_bytes", "本体のバイト数"),
    ("body_etag_form", "本体の ETag の形"),
    ("metadata_bytes", ".metadata のバイト数"),
    ("planning_ms", "QueryPlanningTimeInMillis"),
    ("engine_ms", "EngineExecutionTimeInMillis"),
    ("gqr_rows", "GQR の Rows 数"),
    ("gqr_cols", "GQR の 1 行目の列数"),
    ("scanned_bytes", "scanned_bytes"),
]

cols = MAIN if sys.argv[2] == "main" else DETAIL
with open(sys.argv[1], newline="") as f:
    # summary.tsv は printf でそのまま書いていて引用符の約束が無い。既定のまま読むと
    # 値の中の `"` を引用の開始と見て壊れるので、引用を無効にする。
    rows = list(csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE, quotechar=None))

print("| " + " | ".join(h for _, h in cols) + " |")
print("|" + "|".join(" --- " for _ in cols) + "|")
for row in rows:
    cells = [(row.get(k) or "-").replace("|", "\\|") for k, _ in cols]
    print("| " + " | ".join(cells) + " |")
PYEOF
}

# 「同じ SQL を 2 回流した対」で Content-Type が一致したかを機械的に出す。
md_pairs() {
  python3 - "$SUMMARY" <<'PYEOF'
import csv, sys

# (1 回目, 2 回目, 説明)
PAIRS = [
    ("a2-fresh-first", "a3-fresh-second", "一度も流していない SQL の 1 回目と 2 回目"),
    ("a1-select-1", "e1-select-1-again", "SELECT 1 を同一ラウンドで 2 回"),
    ("preflight-select-1", "a1-select-1", "SELECT 1 の preflight と本編 1 本目（参考）"),
]

with open(sys.argv[1], newline="") as f:
    rows = {r["label"]: r for r in
            csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE, quotechar=None)}

def cmp_field(a, b, key):
    va = (a.get(key) or "-")
    vb = (b.get(key) or "-")
    if va == "-" or vb == "-":
        return "判定不可（%s / %s）" % (va, vb)
    if va == vb:
        return "一致（%s）" % va
    return "不一致（%s / %s）" % (va, vb)

for first, second, desc in PAIRS:
    a = rows.get(first)
    b = rows.get(second)
    if a is None or b is None:
        print("- `%s` / `%s`（%s）: 片方が summary に無い（未実行）" % (first, second, desc))
        continue
    print("- `%s` / `%s`（%s）" % (first, second, desc))
    print("  - 本体: %s" % cmp_field(a, b, "body_content_type"))
    print("  - `.metadata`: %s" % cmp_field(a, b, "metadata_content_type"))
    print("  - State: %s / %s、拡張子: %s / %s"
          % (a.get("state"), b.get("state"), a.get("output_ext"), b.get("output_ext")))
PYEOF
}

# Content-Type ごとに項目を並べる。binary / application / その他 の 3 つに分ける。
md_groups() {
  python3 - "$SUMMARY" <<'PYEOF'
import csv, sys

BINARY = "binary/octet-stream"
APPLICATION = "application/octet-stream"

with open(sys.argv[1], newline="") as f:
    rows = list(csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE, quotechar=None))

def group(key, title):
    print("### %s" % title)
    print()
    buckets = {BINARY: [], APPLICATION: [], "その他": [], "未取得": []}
    for r in rows:
        v = r.get(key) or "-"
        label = r["label"]
        if v == BINARY:
            buckets[BINARY].append(label)
        elif v == APPLICATION:
            buckets[APPLICATION].append(label)
        elif v == "-":
            buckets["未取得"].append("%s（%s）" % (label, r.get("state") or "-"))
        else:
            buckets["その他"].append("%s（%s）" % (label, v))
    for name in (BINARY, APPLICATION, "その他", "未取得"):
        items = buckets[name]
        shown = "、".join("`%s`" % i if name in (BINARY, APPLICATION) else i for i in items)
        print("- **%s**（%d 件）: %s" % (name, len(items), shown or "（無し）"))
    print()

group("body_content_type", "本体（<id>.csv / <id>.txt）")
group("metadata_content_type", ".metadata")
PYEOF
}

# 未測定の項目を並べる。
md_skipped() {
  python3 - "$SUMMARY" <<'PYEOF'
import csv, sys

with open(sys.argv[1], newline="") as f:
    rows = [r for r in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE, quotechar=None)
            if r["state"] in ("SKIPPED", "START_FAILED", "TIMEOUT", "ABORTED")]
if not rows:
    print("（無し。全項目を測れた）")
else:
    for r in rows:
        print("- %s: %s（%s）" % (r["label"], r["state"], r["note"] or "理由不明"))
PYEOF
}

# summary.md を作る。標準出力にはパスだけを返す。
write_summary_md() {
  local md="$RUN_DIR/summary.md"
  local f label failed_any
  {
    echo "# issue #70: 結果ファイルの Content-Type が binary と application に分かれる規則の実測"
    echo
    echo "- 実行日時: $(date -Iseconds)"
    echo "- 本物への呼び出し回数（一時的な失敗の再試行も含む）:"
    echo "  - StartQueryExecution: $(counter start)"
    echo "  - GetQueryExecution: $(counter gqe)（終端状態を待つポーリングを含む）"
    echo "  - GetQueryResults: $(counter gqr)"
    echo "  - S3（ls / cp / head-object の合計）: $(counter s3)"
    echo "- DDL: 無し（このスクリプトは作成・変更・削除を一切しない。読み取りだけ）。"
    echo "- スキャン: 項目 \`b13-from-table-limit1\`（\`SELECT 1 FROM <DB>.<TABLE> LIMIT 1\`）の 1 件だけ。"
    echo "  ほかは定数・メタデータ・\`UNNEST(sequence(...))\` でテーブルを読まない。"
    echo "  実際にスキャンした量は各行の scanned_bytes を見ること。"
    echo "- テーブルの決め方: $(clean "$TABLE_NOTE")"
    echo "- \`a2\` / \`a3\` に使った乱数: $FRESH_N（実行ごとに変わる。過去に流していない SQL を作るため）"
    if [ -n "$ABORT_NOTE" ]; then
      echo
      echo "> **この run は途中で止まっている**: $(clean "$ABORT_NOTE")"
    fi
    echo
    echo "> 注意: 以下は実測した本物の Athena の挙動であって、athena-local の「工場出荷時の既定」ではない。"
    echo "> 実測値は、コンソールで変更済みの設定（ワークグループの設定、結果の暗号化、"
    echo "> 結果の場所の上書き、エンジンのバージョンなど）の影響を受けうる。"
    echo "> 別のアカウント・別のワークグループでは違う値が出ることがある。"
    echo "> 将来の Athena の変更でも変わりうる。"
    echo
    echo "> 実名（アカウント ID・バケット・データベース名・テーブル名）は置換してある。"
    echo "> 結果の中身（値）は出していない。出しているのは形（バイト数・行数・列数）だけ。"
    echo
    echo "## Content-Type"
    echo
    md_table main
    echo
    echo "## 相関を疑っている値"
    echo
    md_table detail
    echo
    echo "- \`本体のバイト数\` は head-object の ContentLength。本体が大きい項目は中身を取りに行っていない。"
    echo "- \`本体の ETag の形\` は \`multipart\`（ETag に \`-\` を含む）か \`single\`。"
    echo "- \`QueryPlanningTimeInMillis\` の \`-\` は Statistics にその項目が無かったことを表す。"
    echo
    echo "## 同じ SQL を 2 回流した対"
    echo
    md_pairs
    echo
    echo "## Content-Type ごとの項目の一覧"
    echo
    md_groups
    echo "## 未測定の項目"
    echo
    md_skipped
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

# 続けられないときに、理由を summary に残してから止める。
abort() {
  local label=$1 note=$2 md
  ABORT_NOTE="$note"
  echo
  echo "中止します: $note" >&2
  printf '%s\tABORTED\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t%s\n' "$label" "$(clean "$note")" >> "$SUMMARY"
  md=$(write_summary_md)
  echo "機械可読な一覧: $SUMMARY" >&2
  echo "理由を書いた一覧: $md" >&2
  exit 1
}

# ---- preflight: 実行系の能力を実際に試して確かめる -----------------------
CAPS="$RUN_DIR/capabilities.txt"
{
  echo "# 実行環境の能力（$(date -Iseconds)）"
  echo "aws: $(command -v aws 2>/dev/null || echo '(見つからない)')"
  echo "python3: $(command -v python3 2>/dev/null || echo '(見つからない)')"
  echo "REGION: $REGION"
  echo "CATALOG: $CATALOG"
} > "$CAPS"

if ! command -v aws > /dev/null 2>&1; then
  abort preflight-capabilities "aws コマンドが見つかりません"
fi

# python3 は「あるか」ではなく「JSON を読めるか」で確かめる。このスクリプトの集計は全部これに乗る。
if ! python3 -c 'import csv, json, sys' > "$RUN_DIR/.tmp-py.out" 2> "$RUN_DIR/preflight-python.err"; then
  echo "python3: 使えない" >> "$CAPS"
  abort preflight-capabilities "python3 で json / csv を読み込めません（$(first_err_line "$RUN_DIR/preflight-python.err")）"
fi
rm -f "$RUN_DIR/.tmp-py.out"
rm -f "$RUN_DIR/preflight-python.err"
echo "python3: json/csv を読める" >> "$CAPS"

# Athena の API に本当に届くかを、副作用の無い呼び出しで確かめる。
# 名前解決・接続・スロットリングは再試行する。
lwg_attempt=1
while :; do
  if aws athena list-work-groups --region "$REGION" --max-items 1 \
    > "$RUN_DIR/preflight-list-work-groups.json" 2> "$RUN_DIR/preflight-list-work-groups.err"; then
    rm -f "$RUN_DIR/preflight-list-work-groups.err"
    echo "athena list-work-groups: 通った（試行 $lwg_attempt 回）" >> "$CAPS"
    break
  fi
  if [ "$lwg_attempt" -ge "$RETRY_MAX" ] || ! is_transient_error "$RUN_DIR/preflight-list-work-groups.err"; then
    echo "athena list-work-groups: 通らなかった（試行 $lwg_attempt 回）" >> "$CAPS"
    # 失敗したときの空の .json は紛らわしいので消す（証拠は .err のほう）。
    [ -s "$RUN_DIR/preflight-list-work-groups.json" ] || rm -f "$RUN_DIR/preflight-list-work-groups.json"
    abort preflight-capabilities \
      "athena list-work-groups が通りません（試行 $lwg_attempt 回）: $(first_err_line "$RUN_DIR/preflight-list-work-groups.err")"
  fi
  echo "== preflight: list-work-groups が一時的に失敗。${RETRY_DELAY} 秒後に再試行します（試行 $lwg_attempt/$RETRY_MAX）" >&2
  sleep "$RETRY_DELAY"
  lwg_attempt=$((lwg_attempt + 1))
done

# ---- preflight: 疎通（SELECT 1 を最後まで流して S3 まで見える）-----------
# ここが通らないなら資格情報・リージョン・OutputLocation の権限のどれかが違う。
if ! run preflight-select-1 "SELECT 1" 0; then
  abort preflight-select-1 \
    "SELECT 1 が終端 SUCCEEDED になりませんでした（state=${LAST_STATE:-不明}）。資格情報・REGION・OUTPUT の権限を確かめてください。理由: preflight-select-1.reason.txt"
fi
if [ "$LAST_BODY_CTYPE" = "-" ]; then
  abort preflight-select-1 \
    "SELECT 1 は成功したのに、結果ファイル本体の head-object が取れませんでした。s3:GetObject の権限か OUTPUT の指定を確かめてください（preflight-select-1.head.err）"
fi
if [ "$LAST_META_CTYPE" = "-" ]; then
  abort preflight-select-1 \
    "SELECT 1 は成功し本体は取れたのに、.metadata の head-object が取れませんでした（preflight-select-1.metadata.head.err）。この測定は .metadata の Content-Type が本題なので続けません"
fi
echo "preflight: 疎通を確認しました（本体 $LAST_BODY_CTYPE / .metadata $LAST_META_CTYPE）"

# ---- preflight: 対象テーブルの決定 ---------------------------------------
# TABLE を明示していればここは呼ばない（本物への呼び出しを 1 本減らすためと、
# 項目 c1 の `SHOW TABLES IN <db>` を同一ラウンドの 1 回目に保つため）。
if [ -n "$TABLE" ]; then
  TABLE_NOTE="TABLE を環境変数で明示した（一覧との突き合わせはしていない）"
elif run preflight-show-tables "SHOW TABLES IN $DB" 0; then
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
    TABLE=$(head -1 "$RUN_DIR/tables.txt")
    TABLE_NOTE="TABLE 未指定のため SHOW TABLES の 1 件目を使った（c1 はこのラウンドで 2 回目の SHOW TABLES になる）"
    echo "テーブルは SHOW TABLES の 1 件目を使います。一覧: $RUN_DIR/tables.txt"
  else
    TABLE_NOTE="SHOW TABLES は通ったがテーブルが 1 件も無かった"
  fi
else
  TABLE_NOTE="SHOW TABLES IN <DB> が通らなかった（DB か CATALOG の指定が実在しない可能性）"
  echo "$TABLE_NOTE。理由: $RUN_DIR/preflight-show-tables.reason.txt"
fi

NO_TABLE_NOTE="対象テーブルが決まらなかった: $TABLE_NOTE"

# ---- A. 対照と、初めて流す SQL の 1 回目・2 回目 -------------------------
run a1-select-1     "SELECT 1"
run a2-fresh-first  "$FRESH_SQL"
run a3-fresh-second "$FRESH_SQL"
run a4-where-false  "SELECT 1 AS i WHERE false"

# ---- B. 1 行の SELECT の形を 1 つずつ変える ------------------------------
run b1-two-int-cols     "SELECT 1, 2"
run b2-varchar          "SELECT 'a'"
run b3-double           "SELECT CAST(1.5 AS DOUBLE)"
run b4-decimal-literal  "SELECT 1.5"
run b5-alias            "SELECT 1 AS i"
run b6-boolean          "SELECT true"
run b7-null             "SELECT NULL"
run b8-where-true       "SELECT 1 WHERE true"
run b9-values           "SELECT * FROM (VALUES 1)"
run b10-expression      "SELECT 1 + 1"
run b11-bigint-cast     "SELECT CAST(1 AS BIGINT)"
run b12-two-rows        "SELECT 1 UNION ALL SELECT 2"
# b13 はこのスクリプトで唯一テーブルを読む項目。LIMIT 1 を付けている。
if [ -n "$TABLE" ]; then
  run b13-from-table-limit1 "SELECT 1 FROM $DB.$TABLE LIMIT 1"
else
  skip b13-from-table-limit1 "$NO_TABLE_NOTE"
fi
run b14-int-and-varchar "SELECT 1, 'a'"

# ---- C. SHOW / DESCRIBE 系 ----------------------------------------------
run c1-show-tables    "SHOW TABLES IN $DB"
run c2-show-databases "SHOW DATABASES"
if [ -n "$TABLE" ]; then
  run c3-show-columns        "SHOW COLUMNS IN $DB.$TABLE"
  run c4-show-tblproperties  "SHOW TBLPROPERTIES $DB.$TABLE"
  run c5-describe            "DESCRIBE $DB.$TABLE"
else
  skip c3-show-columns       "$NO_TABLE_NOTE"
  skip c4-show-tblproperties "$NO_TABLE_NOTE"
  skip c5-describe           "$NO_TABLE_NOTE"
fi
# 1 件も一致しないパターン。0 行の SHOW の Content-Type を見る。
run c6-show-tables-nomatch "SHOW TABLES IN $DB 'athena_local_probe_70_nomatch_%'"
run c7-show-views          "SHOW VIEWS IN $DB"
if [ -n "$TABLE" ]; then
  # パーティションが無いテーブルなら FAILED になる。失敗したときの本体の Content-Type も
  # そのまま記録する（run は FAILED でも S3 を見に行く）。
  run c8-show-partitions "SHOW PARTITIONS $DB.$TABLE"
else
  skip c8-show-partitions "$NO_TABLE_NOTE"
fi
run c9-explain "EXPLAIN SELECT 1"
if [ -n "$TABLE" ]; then
  run c10-show-create-table "SHOW CREATE TABLE $DB.$TABLE"
else
  skip c10-show-create-table "$NO_TABLE_NOTE"
fi

# ---- D. スキャン無しで結果サイズだけを変える ------------------------------
# `sequence` は 1 万要素が上限なので、それ以上は cross join で増やす。
# 値は a * <b の上限> + b なので、行ごとに違う整数になる（重複で圧縮が効くのを避ける）。
run d0-rows-1    "SELECT n FROM UNNEST(sequence(1, 1)) AS t(n)"
run d1-rows-10   "SELECT n FROM UNNEST(sequence(1, 10)) AS t(n)"
run d2-rows-1000 "SELECT n FROM UNNEST(sequence(1, 1000)) AS t(n)"
run d3-rows-100k "SELECT a * 10 + b AS n FROM UNNEST(sequence(1, 10000)) AS x(a) CROSS JOIN UNNEST(sequence(1, 10)) AS y(b)"
run d4-rows-1m   "SELECT a * 100 + b AS n FROM UNNEST(sequence(1, 10000)) AS x(a) CROSS JOIN UNNEST(sequence(1, 100)) AS y(b)"
run d5-rows-3m   "SELECT a * 300 + b AS n FROM UNNEST(sequence(1, 10000)) AS x(a) CROSS JOIN UNNEST(sequence(1, 300)) AS y(b)"

# ---- E. 対照の再実行 -----------------------------------------------------
run e1-select-1-again "SELECT 1"

# ---- summary ------------------------------------------------------------
SUMMARY_MD=$(write_summary_md)
COMPLETED=1
rm -f "$RUN_DIR/INCOMPLETE.txt"

echo
echo "完了しました。"
echo "本物への呼び出し: StartQueryExecution=$(counter start) GetQueryExecution=$(counter gqe) GetQueryResults=$(counter gqr) S3=$(counter s3)"
echo "機械可読な一覧: $SUMMARY"
echo "そのまま貼れる整形済みの一覧（実名はマスク済み）: $SUMMARY_MD"
echo "取得したファイルは $RUN_DIR にあります。リポジトリには入れないでください。"
echo "summary.md 以外（*.request.txt / *.reason.txt / *.results.json / *.bytes など）は"
echo "データベース名・テーブル名・実データを含みます。貼るときは中身を確かめてください。"
