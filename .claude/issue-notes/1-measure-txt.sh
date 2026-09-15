#!/usr/bin/env bash
# 本物の Athena で、DDL と SHOW の結果ファイル <id>.txt を実測する。
#
# 使い方:
#   OUTPUT=s3://your-bucket/prefix/ DB=your_db TABLE=your_table bash 1-measure-txt.sh
#
# 任意の環境変数:
#   CATALOG   既定 AwsDataCatalog
#   REGION    既定 ap-northeast-1
#   OUT_DIR   既定 $HOME/athena-txt-measurements（実名が入るのでリポジトリの外に出す）
#   PROBE_DDL 1 にすると CREATE TABLE / ALTER TABLE / DROP TABLE も測る。
#             OUTPUT の下にテーブルを 1 つ作って消す。
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
TABLE=${TABLE:?TABLE に既存のテーブル名を設定してください}
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
OUT_DIR=${OUT_DIR:-$HOME/athena-txt-measurements}
PROBE_DDL=${PROBE_DDL:-0}

mkdir -p "$OUT_DIR"
SUMMARY="$OUT_DIR/summary.tsv"
printf 'label\tstate\text\tbytes\tmetadata_bytes\n' > "$SUMMARY"
echo "出力先: $OUT_DIR"

run() {
  local label=$1 sql=$2
  local id state loc ext size meta_size

  id=$(aws athena start-query-execution --region "$REGION" \
    --query-string "$sql" \
    --query-execution-context "Catalog=$CATALOG,Database=$DB" \
    --result-configuration "OutputLocation=$OUTPUT" \
    --query QueryExecutionId --output text 2> "$OUT_DIR/$label.start.err")
  if [ -z "${id:-}" ]; then
    echo "== $label: 開始できませんでした。$OUT_DIR/$label.start.err を見てください"
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
    > "$OUT_DIR/$label.execution.json"
  aws athena get-query-results --region "$REGION" --query-execution-id "$id" \
    > "$OUT_DIR/$label.results.json" 2> "$OUT_DIR/$label.results.err"

  loc=$(python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))["QueryExecution"]
print(d.get("ResultConfiguration", {}).get("OutputLocation", ""))' "$OUT_DIR/$label.execution.json")

  ext="-"; size="-"; meta_size="-"
  if [ -n "$loc" ]; then
    ext=${loc##*/}; ext=${ext#*.}
    aws s3 ls "$loc" > "$OUT_DIR/$label.ls.txt" 2>&1
    aws s3 ls "$loc.metadata" >> "$OUT_DIR/$label.ls.txt" 2>&1
    if aws s3 cp "$loc" "$OUT_DIR/$label.bytes" --quiet 2> "$OUT_DIR/$label.cp.err"; then
      od -c "$OUT_DIR/$label.bytes" > "$OUT_DIR/$label.od.txt"
      size=$(wc -c < "$OUT_DIR/$label.bytes")
    else
      size="none"
    fi
    if aws s3 cp "$loc.metadata" "$OUT_DIR/$label.metadata.bytes" --quiet 2> /dev/null; then
      meta_size=$(wc -c < "$OUT_DIR/$label.metadata.bytes")
    else
      meta_size="none"
    fi
  fi

  echo "== $label  state=$state  ext=$ext  bytes=$size  metadata=$meta_size"
  printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$state" "$ext" "$size" "$meta_size" >> "$SUMMARY"
  [ "$state" = SUCCEEDED ]
}

# まず指定のデータベースとテーブルが実在するかを確かめる。
# ここが失敗すると、以降の SHOW や DESCRIBE はすべて Entity Not Found で落ちる。
if ! run show-tables "SHOW TABLES"; then
  echo
  echo "SHOW TABLES が通りませんでした。DB と CATALOG を確かめてください。"
  echo "詳しくは $OUT_DIR/show-tables.execution.json の StateChangeReason を見てください。"
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
echo "中身のファイルは $OUT_DIR にあります。リポジトリには入れないでください。"
