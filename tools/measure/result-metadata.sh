#!/usr/bin/env bash
# issue #5 で作成（tools/ へ移す前の名前は 5-measure-metadata.sh）
# 本物の Athena で、結果ファイルの隣に置かれる <id>.csv.metadata と <id>.txt.metadata を実測する。
#
# 使い方:
#   OUTPUT=s3://your-bucket/prefix/ DB=your_db bash result-metadata.sh
#
# 必要な環境変数:
#   OUTPUT    結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける）。
#   DB        データベース名。実在するものを指定する。
#
# 任意の環境変数:
#   TABLE     省略すると SHOW TABLES の 1 件目を使う。
#   CATALOG   既定 AwsDataCatalog
#   REGION    既定 ap-northeast-1
#   OUT_DIR   既定 $HOME/athena-metadata-measurements（実名が入るのでリポジトリの外に出す）
#   PROBE_DDL 1 にすると CTAS / INSERT / UPDATE / DELETE も測る。
#             **テーブル <db>.athena_local_probe_5 を作って、最後に消す。**
#             同名のテーブルが既にあると壊すので、無いことを確かめてから 1 にすること。
#             UPDATE と DELETE には Iceberg テーブルが要るので、CTAS は Iceberg で作る。
#             `is_external = false` なので DROP TABLE でデータも消える。
#             データの置き場所は OUTPUT の下（tables-probe-5/）。
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く。前の回の結果と混ざらない。
#
# S3 からの取得は `aws s3 cp <src> -` で標準出力に流し、リダイレクトはこのシェルが行う。
# aws が Docker のラッパだと、コンテナにマウントされるのは実行時のカレントディレクトリだけで、
# 絶対パスを渡すとコンテナの中に書かれて消える。しかも終了コードは 0 になる。
#
# 文ごとに次を保存する。
#   <label>.execution.json     GetQueryExecution の応答（OutputLocation はここから読む）
#   <label>.results.json       GetQueryResults の応答（.metadata の列情報と突き合わせるため）
#   <label>.ls.txt             本体と .metadata の有無（aws s3 ls の結果そのまま）
#   <label>.bytes              結果ファイル（.csv / .txt）の中身そのもの
#   <label>.od.txt             上をバイト単位で見たもの
#   <label>.metadata.bytes     .metadata の中身そのもの（無ければ作らない）
#   <label>.metadata.od.txt    上をバイト単位で見たもの（protobuf なので 16 進で見る）
#   <label>.cp.err             本体の取得の標準エラー
#   <label>.metadata.cp.err    .metadata の取得の標準エラー（無いことの証拠になる）
#   <label>.head.json          本体の head-object の応答（Content-Type を見る）
#   <label>.head.err           本体の head-object の標準エラー（無ければ作らない）
#   <label>.metadata.head.json .metadata の head-object の応答
#   <label>.metadata.head.err  .metadata の head-object の標準エラー（無いことの証拠になる）
#   <label>.keys.txt           OutputLocation の周辺で <id> を含む key の一覧
#
# 最後に summary.tsv を作る。中身は分類とサイズだけで実名を含まないので、そのまま貼れる。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください}"
: "${DB:?DB にデータベース名を設定してください}"
TABLE=${TABLE:-}
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
OUT_DIR=${OUT_DIR:-$HOME/athena-metadata-measurements}
PROBE_DDL=${PROBE_DDL:-0}

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\text\tbytes\tmetadata_bytes\tkeys\tcontent_type\tmetadata_content_type\n' > "$SUMMARY"
echo "出力先: $RUN_DIR"

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
# aws が Docker のラッパでも、標準出力をリダイレクトするのはこのシェルなので手元に残る。
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

# OutputLocation の周辺を一覧し、<id> を含む key を全部書き出す。件数を返す（標準出力）。
# --recursive は付けない。見るのは 3 か所。
#   1. OUTPUT の直下（<id>.csv、<id>.csv.metadata、<id>.txt、<id> のマニフェストなど）
#   2. OutputLocation の親（CTAS の tables/ の直下。<id> という「ディレクトリ」が見える）
#   3. OutputLocation 自身を / で閉じたもの（CTAS の tables/<id>/ の中のデータファイル）
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

# ラベルを指定して 1 文を実行し、結果ファイルと .metadata と付随ファイルを保存する。
# 第 3 引数に keys を渡すと、OutputLocation の周辺の key も一覧する（CTAS と INSERT 用）。
# 成功したときだけ 0 を返す。
run() {
  local label=$1 sql=$2 want_keys=${3:-}
  local id state loc ext size meta_size keys ctype mctype

  id=$(aws athena start-query-execution --region "$REGION" \
    --query-string "$sql" \
    --query-execution-context "Catalog=$CATALOG,Database=$DB" \
    --result-configuration "OutputLocation=$OUTPUT" \
    --query QueryExecutionId --output text 2> "$RUN_DIR/$label.start.err")
  if [ -z "${id:-}" ]; then
    echo "== $label: 開始できませんでした。$RUN_DIR/$label.start.err を見てください"
    printf '%s\tSTART_FAILED\t-\t-\t-\t-\t-\t-\n' "$label" >> "$SUMMARY"
    return 1
  fi

  for _ in $(seq 1 180); do
    state=$(aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
      --query QueryExecution.Status.State --output text)
    case "$state" in SUCCEEDED|FAILED|CANCELLED) break ;; esac
    sleep 1
  done

  aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.execution.json"
  aws athena get-query-results --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.results.json" 2> "$RUN_DIR/$label.results.err"

  loc=$(python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))["QueryExecution"]
print(d.get("ResultConfiguration", {}).get("OutputLocation", ""))' "$RUN_DIR/$label.execution.json")

  ext="-"; size="none"; meta_size="none"; keys="-"; ctype="-"; mctype="-"
  if [ -n "$loc" ]; then
    # 末尾のファイル名に . があれば拡張子、無ければ（CTAS の tables/<id> など）none。
    ext=${loc##*/}
    case "$ext" in *.*) ext=${ext#*.} ;; *) ext="none" ;; esac

    # 本体と .metadata の有無を、aws s3 ls の出力そのままで残す。
    { echo "# ls $loc"; aws s3 ls "$loc"; echo "# rc=$?"
      echo "# ls $loc.metadata"; aws s3 ls "$loc.metadata"; echo "# rc=$?"
    } > "$RUN_DIR/$label.ls.txt" 2>&1

    if fetch "$loc" "$RUN_DIR/$label.bytes" "$RUN_DIR/$label.cp.err"; then
      od -c "$RUN_DIR/$label.bytes" > "$RUN_DIR/$label.od.txt"
      size=$(wc -c < "$RUN_DIR/$label.bytes")
    fi
    # 本体の Content-Type。本体が無いときは stderr だけ残る。
    if head_object "$loc" "$RUN_DIR/$label.head.json" "$RUN_DIR/$label.head.err"; then
      ctype=$(content_type_of "$RUN_DIR/$label.head.json")
    fi
    # .metadata は protobuf なので 16 進でも残す。取れなくても stderr は残す。
    if fetch "$loc.metadata" "$RUN_DIR/$label.metadata.bytes" "$RUN_DIR/$label.metadata.cp.err"; then
      od -tx1c "$RUN_DIR/$label.metadata.bytes" > "$RUN_DIR/$label.metadata.od.txt"
      meta_size=$(wc -c < "$RUN_DIR/$label.metadata.bytes")
    fi
    # .metadata の Content-Type。無ければ stderr が「置かれていない」証拠になる。
    if head_object "$loc.metadata" "$RUN_DIR/$label.metadata.head.json" "$RUN_DIR/$label.metadata.head.err"; then
      mctype=$(content_type_of "$RUN_DIR/$label.metadata.head.json")
    fi

    if [ -n "$want_keys" ]; then
      keys=$(list_keys "$label" "$id" "$loc")
    fi
  fi

  echo "== $label  state=$state  ext=$ext  bytes=$size  metadata=$meta_size  keys=$keys  ct=$ctype  meta_ct=$mctype"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$label" "$state" "$ext" "$size" "$meta_size" "$keys" "$ctype" "$mctype" >> "$SUMMARY"
  [ "$state" = SUCCEEDED ]
}

# まず指定のデータベースが実在するかを確かめる。
# ここが通らないと、以降の SHOW や DESCRIBE はすべて Entity Not Found で落ちる。
if ! run probe-show-tables "SHOW TABLES"; then
  echo
  echo "SHOW TABLES が通りませんでした。DB か CATALOG の指定が実在しません。"
  echo "理由: $RUN_DIR/probe-show-tables.execution.json の StateChangeReason"
  if run available-databases "SHOW DATABASES"; then
    echo "選べるデータベースの一覧: $RUN_DIR/available-databases.bytes"
    echo "その中の名前を DB に指定して、もう一度実行してください。"
  fi
  exit 1
fi

# テーブル名は SHOW TABLES の結果から取る。指定が無いか、一覧に無ければ 1 件目を使う。
# 名前は端末に出さず、ファイルに置くだけ。
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
if [ -z "$TABLE" ]; then
  echo "このデータベースにはテーブルがありません。別の DB を指定してください。"
  exit 1
fi

# 1. 型を網羅した SELECT。.csv.metadata に型がどう入るかを見るのが本命。
#    Athena v3 で通らない型があると 1 文まるごと落ちるので、最小版も必ず投げる。
run select-types "SELECT 1 AS i, CAST(1 AS TINYINT) AS ti, CAST(1 AS SMALLINT) AS si, CAST(1 AS BIGINT) AS bi, 1.5 AS dec_lit, CAST(1.5 AS DOUBLE) AS d, CAST(1.5 AS REAL) AS r, CAST(1.5 AS DECIMAL(10,2)) AS dc, true AS b, 'abc' AS s, CAST('abc' AS VARCHAR(10)) AS vc, CAST('abc' AS CHAR(5)) AS c, DATE '2026-09-17' AS dt, TIMESTAMP '2026-09-17 12:34:56.789' AS ts, ARRAY[1,2] AS arr, MAP(ARRAY['k'], ARRAY[1]) AS m, CAST(ROW(1, 'x') AS ROW(a INTEGER, b VARCHAR)) AS rw, CAST('{\"a\":1}' AS JSON) AS j, CAST('abc' AS VARBINARY) AS vb, CAST(NULL AS INTEGER) AS n, INTERVAL '1' DAY AS iv, TIME '12:34:56' AS t"
run select-types-min "SELECT 1 AS i, 'abc' AS s, CAST(1.5 AS DOUBLE) AS d, CAST(1.5 AS DECIMAL(10,2)) AS dc, true AS b, DATE '2026-09-17' AS dt, TIMESTAMP '2026-09-17 12:34:56.789' AS ts"

# 2. 実テーブルへの SELECT。SchemaName / TableName が .metadata に入るかを見る。
run select-table "SELECT * FROM $DB.$TABLE LIMIT 1"

# 3. 0 行の SELECT。行が無くても .metadata が置かれるか。
run select-empty "SELECT 1 AS i WHERE false"

# 4. 別名の無い SELECT。列名が _col0 になる。
run select-nocolname "SELECT 1"

# 5. 失敗する SELECT。.metadata が置かれないことの再確認（#1 で .txt 側は確認済み）。
run select-failed "SELECT * FROM $DB.no_such_table_athena_local_5"

# 6. .txt.metadata の再採取。#1 と同じ形で取れることの確認。
run show-tables "SHOW TABLES IN $DB"

# 7. 素の protobuf の再採取。#1 では 152 バイトだった。
run describe "DESCRIBE $DB.$TABLE"

# 8-12. CTAS / INSERT / UPDATE / DELETE / DROP。OutputLocation が tables/<id> やマニフェストの
#       形になるので、<id> を含む key を全部記録する。
#       UPDATE と DELETE は Iceberg テーブルにしか投げられないので、CTAS を Iceberg で作る。
#       更新系は OutputLocation が <id>.csv でも本体を置かず .csv.metadata だけを置くと言われて
#       いるので、本体が無いこと（ls.txt と cp.err）も記録に残す。
#       テーブルを作って消すので PROBE_DDL=1 のときだけ。
if [ "$PROBE_DDL" = 1 ]; then
  run ctas   "CREATE TABLE $DB.athena_local_probe_5 WITH (table_type = 'ICEBERG', location = '${OUTPUT}tables-probe-5/', is_external = false) AS SELECT 1 AS i" keys
  run insert "INSERT INTO $DB.athena_local_probe_5 VALUES (2)" keys
  run update "UPDATE $DB.athena_local_probe_5 SET i = 3" keys
  run delete "DELETE FROM $DB.athena_local_probe_5 WHERE i = 3" keys
  run drop-table "DROP TABLE $DB.athena_local_probe_5"
fi

echo
echo "完了しました。"
echo "実名を含まない一覧: $SUMMARY"
echo "中身のファイルは $RUN_DIR にあります。リポジトリには入れないでください。"
