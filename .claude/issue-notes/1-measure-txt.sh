#!/usr/bin/env bash
# 本物の Athena で、DDL と SHOW の結果ファイル <id>.txt を実測する。
#
# 使い方:
#   OUTPUT=s3://your-bucket/prefix/ DB=your_db TABLE=your_table bash measure-txt.sh
#
# 任意の環境変数:
#   CATALOG  既定 AwsDataCatalog
#   REGION   既定 ap-northeast-1
#   OUT_DIR  既定 $HOME/athena-txt-measurements（実名が入るのでリポジトリの外に出す）
#
# 文ごとに次を保存する。
#   <label>.execution.json  GetQueryExecution の応答（OutputLocation と状態）
#   <label>.results.json    GetQueryResults の応答（列名と行。txt と比べるため）
#   <label>.ls.txt          本体と .metadata の有無
#   <label>.bytes           結果ファイルの中身そのもの
#   <label>.od.txt          上をバイト単位で見たもの（区切り文字と改行の確認用）

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください}"
: "${DB:?DB にデータベース名を設定してください}"
TABLE=${TABLE:?TABLE に既存のテーブル名を設定してください}
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
OUT_DIR=${OUT_DIR:-$HOME/athena-txt-measurements}

mkdir -p "$OUT_DIR"
echo "出力先: $OUT_DIR"

run() {
  local label=$1 sql=$2
  local id state loc

  id=$(aws athena start-query-execution --region "$REGION" \
    --query-string "$sql" \
    --query-execution-context "Catalog=$CATALOG,Database=$DB" \
    --result-configuration "OutputLocation=$OUTPUT" \
    --query QueryExecutionId --output text 2> "$OUT_DIR/$label.start.err")
  if [ -z "${id:-}" ]; then
    echo "== $label: StartQueryExecution が失敗しました。$OUT_DIR/$label.start.err を見てください"
    return
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

  echo "== $label  state=$state"
  echo "   sql=$sql"
  echo "   location=$loc"

  if [ -z "$loc" ]; then
    echo "   OutputLocation がありません"
    return
  fi

  aws s3 ls "$loc" > "$OUT_DIR/$label.ls.txt" 2>&1
  aws s3 ls "$loc.metadata" >> "$OUT_DIR/$label.ls.txt" 2>&1

  if aws s3 cp "$loc" "$OUT_DIR/$label.bytes" --quiet 2> "$OUT_DIR/$label.cp.err"; then
    od -c "$OUT_DIR/$label.bytes" > "$OUT_DIR/$label.od.txt"
    echo "   bytes=$(wc -c < "$OUT_DIR/$label.bytes")"
  else
    echo "   結果ファイルはありませんでした"
  fi
}

# SHOW と DESCRIBE の系統
run show-tables       "SHOW TABLES"
run show-databases    "SHOW DATABASES"
run show-columns      "SHOW COLUMNS IN $TABLE"
run describe          "DESCRIBE $TABLE"
run show-create-table "SHOW CREATE TABLE $TABLE"
run show-partitions   "SHOW PARTITIONS $TABLE"
run show-tblproperties "SHOW TBLPROPERTIES $TABLE"

# EXPLAIN
run explain           "EXPLAIN SELECT 1"

# 件数の無い DDL
run create-database   "CREATE DATABASE IF NOT EXISTS athena_local_probe_db"
run drop-database     "DROP DATABASE IF EXISTS athena_local_probe_db"

# 失敗したときに置かれるか
run failed-show       "SHOW COLUMNS IN athena_local_no_such_table"

echo
echo "完了しました。$OUT_DIR をそのまま渡してください。"
echo "CREATE TABLE と ALTER TABLE と DROP TABLE は、テーブルの形式に合わせて run を足してください。"
