#!/usr/bin/env bash
# issue #6 で作成（tools/ へ移す前の名前は 6-measure-failed.sh）
# 本物の Athena で、失敗したクエリ・取り消したクエリに結果ファイル（本体と .metadata）が
# 置かれるかを実測する。#5 の result-metadata.sh を雛形にしている。
#
# 使い方:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db bash tools/measure/failed-query-results.sh
#   （資格情報はホストのシェルで AWS_ACCESS_KEY_ID などを export してから。または ~/.aws/credentials）
#
# 必要な環境変数:
#   OUTPUT    結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける）。
#   DB        データベース名。実在するものを指定する。
#
# 任意の環境変数:
#   TABLE     省略すると SHOW TABLES の 1 件目を使う。
#   CATALOG   既定 AwsDataCatalog
#   REGION    既定 ap-northeast-1
#   OUT_DIR   既定 ${DEV_HOST_HOME:-$HOME}/athena-failed-measurements（実名が入るのでリポジトリの外に出す）
#   POLL_TIMEOUT    終端状態を待つ上限（秒）。既定 180
#   LONG_QUERY_SQL  取り消し用の重いクエリ。既定は 30000 x 30000 の UNNEST(sequence) の
#                   CROSS JOIN。#3 の実測で 5000 x 5000 は速すぎて取り消せなかったので、
#                   これより軽くしない（軽くすると RUNNING を捕まえられない）。
#   PROBE_DDL 1 にすると、実在するテーブルに対する失敗（ALTER / CREATE 重複 / 型違いの
#             INSERT / 無い列の UPDATE・DELETE）と、取り消した INSERT / CTAS も測る。
#             **テーブル <db>.athena_local_probe_6 を作って、最後に消す。**
#             同名のテーブルが既にあると壊すので、無いことを確かめてから 1 にすること。
#             UPDATE と DELETE には Iceberg テーブルが要るので、CTAS は Iceberg で作る。
#             `is_external = false` なので DROP TABLE でデータも消える。
#             データの置き場所は OUTPUT の下（tables-probe-6/）。
#             取り消した CTAS の置き場所は tables-probe-6-cancel/ で、こちらは取り消しの
#             途中で書かれた断片が残ることがある。最後に一覧を残すので、必要なら手で消す。
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く。前の回の結果と混ざらない。
#
# S3 からの取得は `aws s3 cp <src> -` で標準出力に流し、リダイレクトはこのシェルが行う。
# aws が Docker のラッパだと、コンテナにマウントされるのは実行時のカレントディレクトリだけで、
# 絶対パスを渡すとコンテナの中に書かれて消える。しかも終了コードは 0 になる。
#
# 課金について: 失敗するクエリは解析か実行の途中で落ちるので S3 をほとんどスキャンしない。
# 取り消し用の LONG_QUERY_SQL も UNNEST(sequence(...)) の CROSS JOIN で S3 を一切
# スキャンしない。既定のままなら Athena の最小課金以上はほぼ増えない見込み。
# LONG_QUERY_SQL を重くするほど取り消すまでの待ち時間は伸びる（課金には効かない）。
# PROBE_DDL=1 のときだけ、小さな Iceberg テーブルを 1 つ作って消す。
#
# 文ごとに次を保存する。
#   <label>.start.err          StartQueryExecution の標準エラー（開始自体が失敗したときの証拠）
#   <label>.execution.json     GetQueryExecution の応答（OutputLocation はここから読む）
#   <label>.execution.err      GetQueryExecution の標準エラー
#   <label>.reason.txt         StateChangeReason と AthenaError（**実名を含みうる**）
#   <label>.results.json       GetQueryResults の応答
#   <label>.results.err        GetQueryResults の標準エラー（失敗したときの文言）
#   <label>.ls.txt             本体と .metadata の有無（aws s3 ls の結果そのまま）
#   <label>.bytes              結果ファイル（.csv / .txt）の中身そのもの
#   <label>.od.txt             上をバイト単位で見たもの（**末尾の改行の有無を見るため必須**）
#   <label>.metadata.bytes     .metadata の中身そのもの（無ければ作らない）
#   <label>.metadata.od.txt    上をバイト単位で見たもの（protobuf なので 16 進で見る）
#   <label>.cp.err             本体の取得の標準エラー
#   <label>.metadata.cp.err    .metadata の取得の標準エラー（無いことの証拠になる）
#   <label>.head.json          本体の head-object の応答（Content-Type を見る）
#   <label>.head.err           本体の head-object の標準エラー（無ければ作らない）
#   <label>.metadata.head.json .metadata の head-object の応答
#   <label>.metadata.head.err  .metadata の head-object の標準エラー（無いことの証拠になる）
#   <label>.keys.txt           OutputLocation の周辺で <id> を含む key の一覧
# 取り消したものはさらに次を保存する。
#   <label>.stop-at-state.txt  stop を投げる直前に見えていた State
#   <label>.stop.stdout.txt    StopQueryExecution の標準出力
#   <label>.stop.stderr.txt    StopQueryExecution の標準エラー
# PROBE_DDL=1 のときはさらに次を保存する。
#   cleanup-cancel-ctas.s3.txt 取り消した CTAS の置き場所に断片が残っていないかの一覧
#
# 最後に summary.tsv を作る。中身は分類とサイズとエラーコードだけで実名を含まないので、
# そのまま貼れる。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください}"
: "${DB:?DB にデータベース名を設定してください}"
TABLE=${TABLE:-}
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_DIR=${OUT_DIR:-${DEV_HOST_HOME:-$HOME}/athena-failed-measurements}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
LONG_QUERY_SQL=${LONG_QUERY_SQL:-"SELECT count(*) FROM UNNEST(sequence(1, 30000)) AS a(x) CROSS JOIN UNNEST(sequence(1, 30000)) AS b(y)"}
PROBE_DDL=${PROBE_DDL:-0}

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\text\tbytes\tmetadata_bytes\tcontent_type\tmetadata_content_type\thead_status\tresults_error\tkeys\n' > "$SUMMARY"
echo "出力先: $RUN_DIR"

# collect が最後に見た State と QueryExecutionId。呼び出し側が続きの操作に使う。
LAST_STATE=""
LAST_ID=""

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

# head-object の標準エラーから括弧の中のコードを取る。
# 「An error occurred (404) when calling the HeadObject operation」の 404 を拾う。
# 実名は括弧の外にしか出ないので、この形なら summary に載せても安全。
head_status_of() {
  local err=$1 code=""
  if [ -s "$err" ]; then
    code=$(grep -oE '\([0-9A-Za-z]+\)' "$err" 2>/dev/null | head -1 | tr -d '()')
  fi
  if [ -n "$code" ]; then
    printf '%s' "$code"
  else
    printf 'err'
  fi
}

# GetQueryResults の標準エラーからコード語だけを取る。
# 文言そのものはテーブル名を含みうるので、既知のコード語か例外名だけを summary に載せる。
results_error_of() {
  local err=$1 code=""
  [ -s "$err" ] || { printf 'err'; return; }
  code=$(grep -oE 'RESULT_NOT_FOUND|INVALID_QUERY_EXECUTION_STATE|INVALID_STATE_TRANSITION|QUERY_EXECUTION_NOT_FOUND|INVALID_INPUT|INVALID_REQUEST|NOT_FOUND' "$err" 2>/dev/null | head -1)
  if [ -z "$code" ]; then
    code=$(grep -oE '[A-Za-z]+Exception' "$err" 2>/dev/null | head -1)
  fi
  if [ -n "$code" ]; then
    printf '%s' "$code"
  else
    printf 'err'
  fi
}

# execution.json から StateChangeReason と AthenaError を取り出してファイルに書く。
# 失敗の理由にはデータベース名・テーブル名が入るので、端末には出さずファイルに置くだけ。
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
  printf '%s' "$state"
}

# クエリを開始して QueryExecutionId を返す（標準出力）。開始に失敗したら空を返す。
start_query() {
  local label=$1 sql=$2
  aws athena start-query-execution --region "$REGION" \
    --query-string "$sql" \
    --query-execution-context "Catalog=$CATALOG,Database=$DB" \
    --result-configuration "OutputLocation=$OUTPUT" \
    --query QueryExecutionId --output text 2> "$RUN_DIR/$label.start.err"
}

# 終端状態まで来た実行から、結果ファイルと .metadata と付随ファイルを採取する。
# run と run_and_stop の共通部分。同じ id を別のラベルで 2 回採ることもできる
# （stopped-after-succeeded のように、あとから stop を投げて消えていないかを見る）。
# 第 3 引数に keys を渡すと、OutputLocation の周辺の key も一覧する（CTAS と INSERT 用）。
# 見えた State を LAST_STATE に残す。
collect() {
  local label=$1 id=$2 want_keys=${3:-}
  local state loc ext size meta_size keys ctype mctype hstatus rerr

  aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.execution.json" 2> "$RUN_DIR/$label.execution.err"
  write_reason "$RUN_DIR/$label.execution.json" "$RUN_DIR/$label.reason.txt"

  state=$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1]))["QueryExecution"]["Status"]["State"])
except Exception:
    print("UNKNOWN")' "$RUN_DIR/$label.execution.json")

  # 失敗したクエリの GetQueryResults は落ちるはず。その文言も記録に残す。
  if aws athena get-query-results --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.results.json" 2> "$RUN_DIR/$label.results.err"; then
    rerr="-"
  else
    rerr=$(results_error_of "$RUN_DIR/$label.results.err")
  fi

  loc=$(python3 -c 'import json,sys
try:
    d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception:
    print("")
    sys.exit(0)
print(d.get("ResultConfiguration", {}).get("OutputLocation", ""))' "$RUN_DIR/$label.execution.json")

  ext="-"; size="none"; meta_size="none"; keys="-"; ctype="-"; mctype="-"; hstatus="-"
  if [ -n "$loc" ]; then
    # 末尾のファイル名に . があれば拡張子、無ければ（CTAS の tables/<id> など）none。
    ext=${loc##*/}
    case "$ext" in *.*) ext=${ext#*.} ;; *) ext="none" ;; esac

    # 本体と .metadata の有無を、aws s3 ls の出力そのままで残す。
    { echo "# ls $loc"; aws s3 ls "$loc"; echo "# rc=$?"
      echo "# ls $loc.metadata"; aws s3 ls "$loc.metadata"; echo "# rc=$?"
    } > "$RUN_DIR/$label.ls.txt" 2>&1

    if fetch "$loc" "$RUN_DIR/$label.bytes" "$RUN_DIR/$label.cp.err"; then
      # 末尾に改行があるかを見たいので od -c は必ず取る。
      od -c "$RUN_DIR/$label.bytes" > "$RUN_DIR/$label.od.txt"
      size=$(wc -c < "$RUN_DIR/$label.bytes")
    fi
    # 本体の Content-Type。本体が無いときは stderr だけ残り、そこから 404 を拾う。
    if head_object "$loc" "$RUN_DIR/$label.head.json" "$RUN_DIR/$label.head.err"; then
      ctype=$(content_type_of "$RUN_DIR/$label.head.json")
      hstatus=200
    else
      hstatus=$(head_status_of "$RUN_DIR/$label.head.err")
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

  echo "== $label  state=$state  ext=$ext  bytes=$size  metadata=$meta_size  head=$hstatus  results=$rerr  keys=$keys  ct=$ctype  meta_ct=$mctype"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$label" "$state" "$ext" "$size" "$meta_size" "$ctype" "$mctype" "$hstatus" "$rerr" "$keys" >> "$SUMMARY"
  LAST_STATE=$state
}

# ラベルを指定して 1 文を実行し、終端状態まで待って採取する。
# 失敗するクエリを投げるのが目的なので、呼び出し側は戻り値を見ない
# （疎通確認だけは SUCCEEDED を見る）。
run() {
  local label=$1 sql=$2 want_keys=${3:-}
  local id
  LAST_STATE=""; LAST_ID=""
  id=$(start_query "$label" "$sql")
  if [ -z "${id:-}" ]; then
    echo "== $label: 開始できませんでした。$RUN_DIR/$label.start.err を見てください"
    printf '%s\tSTART_FAILED\t-\t-\t-\t-\t-\t-\t-\t-\n' "$label" >> "$SUMMARY"
    return 1
  fi
  LAST_ID=$id
  poll_until_terminal "$id" > /dev/null
  collect "$label" "$id" "$want_keys"
  [ "$LAST_STATE" = SUCCEEDED ]
}

# ラベルを指定して 1 文を実行し、RUNNING になったところで取り消して採取する。
# QUEUED のうちに止めると「実行していないものを止めた」ことになるので、RUNNING を待つ。
# 0.5 秒 x 60 回見ても RUNNING にならず終端状態になったら、止める前に終わったと記録して
# 採取だけ続ける（state 列にはその最終状態が入る）。
run_and_stop() {
  local label=$1 sql=$2 want_keys=${3:-}
  local id seen="" st
  LAST_STATE=""; LAST_ID=""
  id=$(start_query "$label" "$sql")
  if [ -z "${id:-}" ]; then
    echo "== $label: 開始できませんでした。$RUN_DIR/$label.start.err を見てください"
    printf '%s\tSTART_FAILED\t-\t-\t-\t-\t-\t-\t-\t-\n' "$label" >> "$SUMMARY"
    return 1
  fi
  LAST_ID=$id

  for _ in $(seq 1 60); do
    st=$(get_state_once "$id")
    case "$st" in
      RUNNING) seen=$st; break ;;
      SUCCEEDED | FAILED | CANCELLED) seen=$st; break ;;
    esac
    sleep 0.5
  done
  printf '%s\n' "${seen:-(捕まえられず)}" > "$RUN_DIR/$label.stop-at-state.txt"

  if [ "$seen" = RUNNING ]; then
    aws athena stop-query-execution --region "$REGION" --query-execution-id "$id" \
      > "$RUN_DIR/$label.stop.stdout.txt" 2> "$RUN_DIR/$label.stop.stderr.txt"
  else
    echo "== $label: RUNNING を捕まえられませんでした（見えた状態=${seen:-(採取できず)}）。stop は投げません"
    printf '# %s: RUNNING を捕まえる前に終わったので stop を投げていません（捕捉時の状態=%s）\n' \
      "$label" "${seen:-none}" >> "$SUMMARY"
  fi

  poll_until_terminal "$id" > /dev/null
  collect "$label" "$id" "$want_keys"
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

# 1. 無いデータベースへの SHOW TABLES。#1 で「結果ファイルが置かれた」ケースの再現。
#    --query-execution-context の Database は $DB のままにして、文の中だけを無い名前にする。
run failed-show-tables "SHOW TABLES IN no_such_db_athena_local_6"

# 2-3. 無いテーブルへの SHOW COLUMNS / DESCRIBE。.txt 側の失敗をもう 2 種類。
run failed-show-columns "SHOW COLUMNS IN no_such_table_athena_local_6"
run failed-describe "DESCRIBE $DB.no_such_table_athena_local_6"

# 4. 解析で落ちる SELECT。ファイル名は .csv になるはず。
run failed-select-analysis "SELECT * FROM $DB.no_such_table_athena_local_6"

# 5. 解析は通り、実行中に落ちる SELECT。もし Athena が定数畳み込みで解析時に落とすなら、
#    それも（4 と区別が付かないという）記録として価値がある。
run failed-select-runtime "SELECT 1/0"

# 6. 実行時の変換エラー。5 と割れるか（畳み込みされない形）を見る。
run failed-select-runtime-2 "SELECT CAST(x AS integer) FROM (VALUES 'abc') AS t(x)"

# 7. 構文エラー。StartQueryExecution 自体が失敗して START_FAILED になるはず。
run failed-syntax "SELECT FROM"

# 8-9. 失敗する DDL。DROP は無いテーブル、CREATE DATABASE は既存名なので落ちる。
#      IF NOT EXISTS は付けない（付けると成功してしまう）。
run failed-drop-table "DROP TABLE $DB.no_such_table_athena_local_6"
run failed-create-database "CREATE DATABASE $DB"

# 10-12. 無いテーブルへの更新系。OutputLocation がマニフェストの形になりうるので keys も採る。
run failed-insert-no-table "INSERT INTO $DB.no_such_table_athena_local_6 VALUES (1)" keys
run failed-update-no-table "UPDATE $DB.no_such_table_athena_local_6 SET i = 1" keys
run failed-delete-no-table "DELETE FROM $DB.no_such_table_athena_local_6 WHERE i = 1" keys

# 13. 失敗する CTAS。OutputLocation が tables/<id> の形になるので keys も採る。
#     失敗するのでテーブルは作られないはずだが、念のため後始末に DROP を投げる。
run failed-ctas-no-func "CREATE TABLE $DB.athena_local_probe_6_ctas WITH (table_type = 'ICEBERG', location = '${OUTPUT}tables-probe-6-ctas/', is_external = false) AS SELECT no_such_function_athena_local_6(1) AS i" keys
run cleanup-ctas "DROP TABLE IF EXISTS $DB.athena_local_probe_6_ctas"

# 14. 取り消した SELECT。本命のケース。
run_and_stop cancelled-select "$LONG_QUERY_SQL"

# 15. 成功したクエリを、終わったあとに取り消す。結果ファイルが消えないことを見る。
#     stop の後にもう一度採るので、同じ id を 2 つのラベルで採取する。
run stopped-after-succeeded "SELECT 1 AS i"
if [ -n "$LAST_ID" ]; then
  succeeded_id=$LAST_ID
  aws athena stop-query-execution --region "$REGION" --query-execution-id "$succeeded_id" \
    > "$RUN_DIR/stopped-after-succeeded.stop.stdout.txt" \
    2> "$RUN_DIR/stopped-after-succeeded.stop.stderr.txt"
  collect stopped-after-succeeded-after-stop "$succeeded_id"
fi

# 16-24. 実在するテーブルに対する失敗と、取り消した INSERT / CTAS。
#        テーブルを作って消すので PROBE_DDL=1 のときだけ。
if [ "$PROBE_DDL" = 1 ]; then
  # 16. 土台のテーブル。ここが成功しなければ以降は測れないので飛ばす。
  if run probe-ctas "CREATE TABLE $DB.athena_local_probe_6 WITH (table_type = 'ICEBERG', location = '${OUTPUT}tables-probe-6/', is_external = false) AS SELECT 1 AS i" keys; then
    # 17. 失敗する ALTER TABLE。#1 で「結果ファイルが置かれなかった」ケースの再現。
    #     Iceberg には無いプロパティ名なので失敗する（#1 で実績あり）。
    run failed-alter-table "ALTER TABLE $DB.athena_local_probe_6 SET TBLPROPERTIES ('comment'='probe')"

    # 18. 既存名への CREATE TABLE。
    run failed-create-table-exists "CREATE TABLE $DB.athena_local_probe_6 (i int)"

    # 19-21. 実在するテーブルへの、失敗する更新系。
    #        テーブルが実在するので OutputLocation は INSERT / UPDATE / DELETE の形になるはず。
    run failed-insert-type "INSERT INTO $DB.athena_local_probe_6 VALUES ('abc')" keys
    run failed-update-no-column "UPDATE $DB.athena_local_probe_6 SET no_such_col = 9" keys
    run failed-delete-no-column "DELETE FROM $DB.athena_local_probe_6 WHERE no_such_col = 1" keys

    # 22. 取り消した INSERT。
    run_and_stop cancelled-insert "INSERT INTO $DB.athena_local_probe_6 SELECT count(*) FROM UNNEST(sequence(1, 30000)) AS a(x) CROSS JOIN UNNEST(sequence(1, 30000)) AS b(y)" keys

    # 23. 取り消した CTAS。途中まで書かれた断片が残ることがあるので、後始末の一覧も残す。
    run_and_stop cancelled-ctas "CREATE TABLE $DB.athena_local_probe_6_cancel WITH (table_type = 'ICEBERG', location = '${OUTPUT}tables-probe-6-cancel/', is_external = false) AS SELECT count(*) AS n FROM UNNEST(sequence(1, 30000)) AS a(x) CROSS JOIN UNNEST(sequence(1, 30000)) AS b(y)" keys
    run cleanup-cancel-ctas "DROP TABLE IF EXISTS $DB.athena_local_probe_6_cancel"
    { echo "# ls ${OUTPUT}tables-probe-6-cancel/ --recursive"
      aws s3 ls "${OUTPUT}tables-probe-6-cancel/" --recursive
      echo "# rc=$?"
    } > "$RUN_DIR/cleanup-cancel-ctas.s3.txt" 2>&1

    # 24. 土台のテーブルを消す。is_external = false なのでデータも消える。
    run drop-probe "DROP TABLE $DB.athena_local_probe_6"
  else
    echo "probe-ctas が成功しなかったので、PROBE_DDL のケースは飛ばします。"
    echo "理由: $RUN_DIR/probe-ctas.reason.txt"
  fi
fi

echo
echo "完了しました。"
echo "実名を含まない一覧: $SUMMARY"
echo
cat "$SUMMARY"
echo
echo "中身のファイルは $RUN_DIR にあります。リポジトリには入れないでください。"
echo "<label>.od.txt と <label>.reason.txt はデータベース名・テーブル名を含みうるので、"
echo "貼るときは中身を確かめてください。"
if [ -s "$RUN_DIR/cleanup-cancel-ctas.s3.txt" ]; then
  echo "取り消した CTAS の断片が ${OUTPUT}tables-probe-6-cancel/ に残っていないかは"
  echo "$RUN_DIR/cleanup-cancel-ctas.s3.txt で確かめてください（残っていれば手で消せます）。"
fi
