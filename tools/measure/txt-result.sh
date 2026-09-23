#!/usr/bin/env bash
# issue #1 で作成（tools/ へ移す前の名前は 1-measure-txt.sh）
# 本物の Athena で、DDL と SHOW の結果ファイル <id>.txt を実測する。
#
# 使い方:
#   OUTPUT=s3://your-bucket/prefix/ DB=your_db bash txt-result.sh
#
# 任意の環境変数:
#   TABLE     省略すると SHOW TABLES の 1 件目を使う。
#   CATALOG   既定 AwsDataCatalog
#   REGION    既定 ap-northeast-1
#   OUT_DIR   既定 $HOME/athena-txt-measurements（実名が入るのでリポジトリの外に出す）
#   PROBE_DDL 1 にすると CREATE TABLE / ALTER TABLE / DROP TABLE も測る。
#             OUTPUT の下にテーブルを 1 つ作って消す。
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く。前の回の結果と混ざらない。
#
# S3 からの取得は `aws s3 cp <src> -` で標準出力に流し、リダイレクトはこのシェルが行う。
# aws が Docker のラッパだと、コンテナにマウントされるのは実行時のカレントディレクトリだけで、
# 絶対パスを渡すとコンテナの中に書かれて消える。しかも終了コードは 0 になる。
#
# 文ごとに次を保存する。
#   <label>.execution.json   GetQueryExecution の応答
#   <label>.results.json     GetQueryResults の応答（.txt と突き合わせるため）
#   <label>.ls.txt           本体と .metadata の有無
#   <label>.bytes            結果ファイルの中身そのもの
#   <label>.od.txt           上をバイト単位で見たもの
#   <label>.metadata.bytes   .txt.metadata があればその中身
#
# 最後に summary.tsv を作る。中身は分類とサイズだけで実名を含まないので、そのまま貼れる。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください}"
: "${DB:?DB にデータベース名を設定してください}"
TABLE=${TABLE:-}
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
OUT_DIR=${OUT_DIR:-$HOME/athena-txt-measurements}
PROBE_DDL=${PROBE_DDL:-0}

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\text\tbytes\tmetadata_bytes\n' > "$SUMMARY"
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

# ラベルを指定して 1 文を実行し、結果ファイルと付随ファイルを保存する。
# 成功したときだけ 0 を返す。
run() {
  local label=$1 sql=$2
  local id state loc ext size meta_size

  id=$(aws athena start-query-execution --region "$REGION" \
    --query-string "$sql" \
    --query-execution-context "Catalog=$CATALOG,Database=$DB" \
    --result-configuration "OutputLocation=$OUTPUT" \
    --query QueryExecutionId --output text 2> "$RUN_DIR/$label.start.err")
  if [ -z "${id:-}" ]; then
    echo "== $label: 開始できませんでした。$RUN_DIR/$label.start.err を見てください"
    printf '%s\tSTART_FAILED\t-\t-\t-\n' "$label" >> "$SUMMARY"
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

  ext="-"; size="none"; meta_size="none"
  if [ -n "$loc" ]; then
    ext=${loc##*/}; ext=${ext#*.}
    aws s3 ls "$loc" > "$RUN_DIR/$label.ls.txt" 2>&1
    aws s3 ls "$loc.metadata" >> "$RUN_DIR/$label.ls.txt" 2>&1
    if fetch "$loc" "$RUN_DIR/$label.bytes" "$RUN_DIR/$label.cp.err"; then
      od -c "$RUN_DIR/$label.bytes" > "$RUN_DIR/$label.od.txt"
      size=$(wc -c < "$RUN_DIR/$label.bytes")
    fi
    if fetch "$loc.metadata" "$RUN_DIR/$label.metadata.bytes" /dev/null; then
      meta_size=$(wc -c < "$RUN_DIR/$label.metadata.bytes")
    fi
  fi

  echo "== $label  state=$state  ext=$ext  bytes=$size  metadata=$meta_size"
  printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$state" "$ext" "$size" "$meta_size" >> "$SUMMARY"
  [ "$state" = SUCCEEDED ]
}

# まず指定のデータベースが実在するかを確かめる。
# ここが通らないと、以降の SHOW や DESCRIBE はすべて Entity Not Found で落ちる。
if ! run show-tables "SHOW TABLES"; then
  echo
  echo "SHOW TABLES が通りませんでした。DB か CATALOG の指定が実在しません。"
  echo "理由: $RUN_DIR/show-tables.execution.json の StateChangeReason"
  if run available-databases "SHOW DATABASES"; then
    echo "選べるデータベースの一覧: $RUN_DIR/available-databases.bytes"
    echo "その中の名前を DB に指定して、もう一度実行してください。"
  fi
  exit 1
fi

# テーブル名は SHOW TABLES の結果から取る。指定が無いか、一覧に無ければ 1 件目を使う。
# 名前は端末に出さず、ファイルに置くだけ。
python3 - "$RUN_DIR/show-tables.results.json" "$RUN_DIR/tables.txt" <<'EOF'
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

# 複数列になる文。区切り文字と NULL の書き方を知るのが目的。
run show-columns       "SHOW COLUMNS IN $TABLE"
run describe           "DESCRIBE $TABLE"
run show-tblproperties "SHOW TBLPROPERTIES $TABLE"
run show-create-table  "SHOW CREATE TABLE $TABLE"
run show-partitions    "SHOW PARTITIONS $TABLE"

# 1 列の文と、複数行にわたる文。
run show-databases     "SHOW DATABASES"
run explain            "EXPLAIN SELECT 1"

# 件数の無い DDL。
run create-database    "CREATE DATABASE IF NOT EXISTS athena_local_probe_db"
run drop-database      "DROP DATABASE IF EXISTS athena_local_probe_db"

# 失敗したクエリ。
run failed-show        "SHOW COLUMNS IN athena_local_no_such_table"

if [ "$PROBE_DDL" = 1 ]; then
  run create-table "CREATE TABLE athena_local_probe_t (id int) LOCATION '${OUTPUT}athena_local_probe_t/' TBLPROPERTIES ('table_type'='ICEBERG')"
  run alter-table  "ALTER TABLE athena_local_probe_t SET TBLPROPERTIES ('comment'='probe')"
  run drop-table   "DROP TABLE athena_local_probe_t"
fi

echo
echo "完了しました。"
echo "実名を含まない一覧: $SUMMARY"
echo "中身のファイルは $RUN_DIR にあります。リポジトリには入れないでください。"
