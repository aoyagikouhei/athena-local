#!/usr/bin/env bash
# issue #217 で作成
# 本物の Athena で、StartQueryExecution の QueryExecutionContext.Catalog に実在しない
# カタログ名（nocatalog_217）を渡したとき、#214 で測っていない文の種類（INSERT・
# ALTER TABLE の亜種・CTAS でない CREATE TABLE・CREATE VIEW・SHOW PARTITIONS・
# MSCK REPAIR TABLE・DROP VIEW・CREATE/DROP DATABASE・CREATE/DROP SCHEMA・
# Iceberg の DML・保守文・RENAME TO・SHOW COLUMNS IN など）が「既定の AwsDataCatalog で
# 解決して成功する」か「CATALOG_NOT_FOUND 等で失敗する」かを測る。成功した文を
# src/operation/context_catalog.rs の RESOLVED_STATEMENTS に足すのが後の実装（issue #217）。
#
# 背景: #214（tools/measure/context-catalog.sh、記録は docs/dev/measurements/statements.md の
# 「実在しない QueryExecutionContext の Catalog と文の種類」）で、DESCRIBE・SHOW 系
# （TABLES/DATABASES/CREATE TABLE/TBLPROPERTIES/VIEWS）・DROP TABLE は既定のカタログで
# 成功、表を読む SELECT・EXPLAIN は CATALOG_NOT_FOUND（1006）、CTAS は 1300 の
# `NOT_FOUND: Session property catalog does not exist` で失敗と分かった。INSERT は前の
# CTAS が失敗して表が無く測れなかった。issue #217（docs/dev/unmeasured.md の
# 「文の種類と構文」節）はその残りを測る。
#
# tools/measure/context-catalog.sh（#214）をそのまま雛形にしている。redact・mask_names・
# hide・sanitize・first_err_line・is_transient_error・start_query_retry（QE_CONTEXT で
# Context を渡す）・poll_until_terminal・run・run_in_ctx・skip・info_row・emit_row・
# fetch_all_table_names・gqr_check・qec_of（GetQueryExecution が返す QueryExecutionContext）・
# preflight（SHOW TABLES）・接頭辞の名前が既にあれば止まる安全装置・trap cleanup EXIT・
# summary.tsv と summary.txt の 2 段・アカウント ID の伏せ字はそのまま流用する。PROBE_DDL の
# トグルは持ち込んでいない（測る対象が DDL そのものなので、既定で全部作る。フラグで測定を
# 後回しにしない）。
#
# 雛形からの変更点:
#   - 準備のテーブル・ビューを 4 つに増やした（#214 は Hive 表 1 つだけ）。Hive の
#     非パーティション表・パーティション表・Iceberg 表・（Hive 表を参照する）ビューを
#     あらかじめ OK Context（Catalog=AwsDataCatalog）で作る。
#   - measure_nc()／measure_nc_read() を新設した。NC Context（Catalog=nocatalog_217）で
#     1 文を投げ、失敗（開始失敗・FAILED・CANCELLED・TIMEOUT のいずれか）なら同じ文を
#     OK Context で対照として投げる。読み取り専用の文（measure_nc_read）は、成功時は
#     その文自身の GetQueryResults を gqr_check() で見るだけ（追加の StartQueryExecution を
#     課金対象として投げない）。書き込みを伴う文（measure_nc）は、成功時に呼び出し側が
#     OK Context の別の文で効果を裏取りする（verify_count／verify_membership／
#     verify_contains の 3 つを新設）。
#   - mask_names は $PROBE_PREFIX の置換だけにした（#214 の $TARGET_TABLE 相当の別名は
#     無い。準備する名前が全部 $PROBE_PREFIX 始まりなので、この置換だけで全部隠れる）。
#   - コーディネーターの指示で、手元の Trino（構文の確認用）でも通る書き方の項目を
#     3 つ足した。Hive 専用の構文（`CREATE DATABASE`・`CREATE EXTERNAL TABLE`・
#     `LOCATION`/`TBLPROPERTIES` を伴う素の `CREATE TABLE` など）は Trino の文法に無く、
#     athena-local の構文チェック（`PREPARE ... FROM`）より先に弾かれて Trino には届かない。
#     `CREATE SCHEMA`・`ALTER TABLE ... RENAME TO`・`SHOW COLUMNS IN` はどちらの文法にも
#     ある綴りなので、athena-local が実際に解決を試す対象になり得る。それ以外の指示
#     （元からの項目 1〜21）は変えていない:
#       17b  CREATE SCHEMA IF NOT EXISTS <p>_sch・DROP SCHEMA IF EXISTS <p>_sch
#            （17 の CREATE/DROP DATABASE と同じことを SCHEMA の綴りで）。裏取りは
#            OK Context の SHOW DATABASES に有無だけ
#       22   ALTER TABLE <p>_t RENAME TO <p>_t_ren（Hive の表）。#43 の実測
#            （docs/dev/measurements/result-files.md の「ALTER TABLE の亜種 × テーブル形式」）
#            では Hive の RENAME TO は常に Glue の `Table cannot be renamed` で失敗する
#            （カタログの解決とは無関係）。なのでこの項目の決め手は成功/失敗そのものでは
#            なくエラーの中身: CATALOG_NOT_FOUND なら未解決、Glue の rename 拒否なら
#            既定カタログまで解決できている証拠になる。成功した場合だけ OK Context の
#            RENAME TO で <p>_t に戻す（後始末と <p>_t_ren の DROP も足した）。<p>_t を
#            使う項目（1・2・3・6・7・13）より後ろに置く
#       23   SHOW COLUMNS IN <p>_v（ビュー。#214 は SHOW COLUMNS FROM しか測っていない。
#            FROM ではなく IN の綴り）。対象のビューが消える前に測る必要があるため、実行
#            順は 14・15（同じビューへの読み取り）の直後、16（DROP VIEW）の手前に置いた
#            （番号は指示どおり 23 だが、実行順は依存関係を優先した）
#   - 開始前の安全装置に SHOW DATABASES を足した（#214 は SHOW TABLES だけ。この実測は
#     データベース・スキーマも作るため、<p>_db・<p>_sch の衝突も確かめる）。
#
# 使い方:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db bash tools/measure/context-catalog-statements.sh
#   （資格情報はホストのシェルで AWS_ACCESS_KEY_ID などを export してから。または ~/.aws/credentials）
#
# 必要な環境変数:
#   OUTPUT    結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける）。
#   DB        データベース名。実在するものを指定する。
#
# 任意の環境変数:
#   CATALOG        既定 AwsDataCatalog（対照の OK Context に使う）
#   REGION         既定 ap-northeast-1
#   OUT_DIR        既定 ${DEV_HOST_HOME:-$HOME}/athena-context-catalog-measurements
#                  （#214 と同じ親。実名が入るのでリポジトリの外に出す）
#   POLL_TIMEOUT   終端状態を待つ上限（秒）。既定 180
#   RETRY_MAX      名前解決・接続など一時的な失敗を再試行する回数の上限。既定 4
#   RETRY_DELAY    再試行の間隔（秒）。既定 5
#
# ** このスクリプトが本物に対して行う破壊的な操作（DDL・DML の一覧と後始末） **
#   準備（OK Context = Catalog=AwsDataCatalog,Database=<DB>）:
#     p1  CREATE TABLE <DB>.athena_local_probe_217_t AS SELECT 1 AS n, 'x' AS s
#         （Hive、非パーティション）
#     p2  CREATE TABLE <DB>.athena_local_probe_217_tp WITH (partitioned_by = ARRAY['p'])
#         AS SELECT 1 AS n, 'a' AS p（Hive、パーティション）
#     p3  CREATE TABLE <DB>.athena_local_probe_217_ti WITH (table_type = 'ICEBERG',
#         location = '<OUTPUT>tables/217-iceberg/<run>/', is_external = false)
#         AS SELECT 1 AS n, 'x' AS s（Iceberg。is_external=false なので DROP TABLE で
#         データも消える）
#     p4  CREATE VIEW <DB>.athena_local_probe_217_v AS SELECT n FROM <DB>.athena_local_probe_217_t
#         （p1 の表を参照するビュー。p1 が失敗したら作らない）
#   NC Context（Catalog=nocatalog_217,Database=<DB>）で投げる DDL・DML（番号は上の「測る
#   項目」と対応。詳しい SQL は本体のコメントと <label>.sql を参照）:
#     1〜3   INSERT（1 部／2 部／VALUES 形）を athena_local_probe_217_t に
#     4      CREATE EXTERNAL TABLE athena_local_probe_217_ext（Hive、場所は
#            <OUTPUT>tables/217-ext/<run>/）
#     5      CREATE TABLE athena_local_probe_217_ice2（Iceberg 風の素の CREATE、場所は
#            <OUTPUT>tables/217-ice2/<run>/。is_external を指定していないので DROP TABLE
#            でデータが消えるかは未確認）
#     6・7   ALTER TABLE ADD COLUMNS・SET TBLPROPERTIES を athena_local_probe_217_t に
#     8〜11  ALTER TABLE ADD/DROP PARTITION・SHOW PARTITIONS・MSCK REPAIR TABLE を
#            athena_local_probe_217_tp に
#     12・13 CREATE VIEW athena_local_probe_217_v2（表を参照しない）・_v3（p1 の表を参照）
#     14・15・23  SHOW CREATE VIEW・DESCRIBE・SHOW COLUMNS IN を athena_local_probe_217_v に
#     16     DROP VIEW IF EXISTS を _v2・_v に
#     17     CREATE/DROP DATABASE IF NOT EXISTS athena_local_probe_217_db
#     17b    CREATE/DROP SCHEMA IF NOT EXISTS athena_local_probe_217_sch
#     18     SHOW FUNCTIONS
#     19     Iceberg の DML・保守文（DELETE・UPDATE・MERGE INTO・OPTIMIZE・VACUUM・
#            ALTER TABLE ADD COLUMNS）を athena_local_probe_217_ti に
#     20     SHOW TBLPROPERTIES・SHOW CREATE TABLE を athena_local_probe_217_ti に
#     21     DROP TABLE IF EXISTS athena_local_probe_217_ext
#     22     ALTER TABLE athena_local_probe_217_t RENAME TO athena_local_probe_217_t_ren
#            （成功したら OK Context で戻す）
#   後始末（必須。OK Context の DROP ... IF EXISTS で全部消す。trap にも同じ保険を張る）:
#     DROP TABLE IF EXISTS athena_local_probe_217_t・_t_ren・_tp・_ti・_ext・_ice2、
#     DROP VIEW IF EXISTS _v・_v2・_v3、DROP DATABASE IF EXISTS _db、
#     DROP SCHEMA IF EXISTS _sch。
#   Iceberg 表（_ti）は is_external=false の CTAS なので DROP TABLE でデータも消える。
#   Hive の表・外部表（_t・_tp・_ext）と is_external 未指定の _ice2 は、DROP TABLE では
#   S3 上のデータが消えない可能性がある（#26 などの既測と同じ）。残るパスは summary.txt
#   の末尾に**実名のまま**出す（手で消すための参考。aws s3 rm はしない）。
#   nocatalog_217 というカタログは作らず、QueryExecutionContext に渡すだけ。
#
# 課金について: すべて 1〜4 行程度の表への CTAS・INSERT・DML と、スキャンを伴わない
#   メタデータの文（DESCRIBE・SHOW 系・ALTER・DROP・CREATE DATABASE/SCHEMA・MSCK・
#   OPTIMIZE・VACUUM）。Athena の最小課金 × クエリ数の見込み。
#
# 本物への StartQueryExecution の見込み本数: 前提（準備の 4 テーブル/ビューが作れる）が
#   満たされたとき、おおよそ 72〜84 本（結果次第で変動する）。内訳:
#     - 書き込みを伴う項目（1・2・3・4・5・6・7・8・10・11・12・13・16a・16b・17create・
#       17drop・17b create・17b drop・19f・21・22 の 21 項目）は常に「NC 1 本 + 対照または
#       裏取り 1 本」の 2 本 = 42 本
#     - 読み取り専用の項目（9・14・15・18・20a・20b・23 の 7 項目）は NC が成功すれば
#       追加の呼び出しは無い（gqr_check は課金対象にならない GetQueryResults だけ）＝1 本、
#       失敗すれば OK の対照で 1 本足して 2 本になる = 7〜14 本
#     - 19a〜19e（Iceberg の DELETE/UPDATE/MERGE/OPTIMIZE/VACUUM）は個別の裏取りをせず、
#       5 本の後にまとめて 1 本（SELECT count(*)）で裏取りする = 6〜11 本
#     - 固定: preflight 2 本（SHOW TABLES・SHOW DATABASES）+ 準備 4 本 + 後始末 11 本 = 17 本
#   準備のいずれかが作れなければ、それに依存する項目がまとめて未測定になり、本数は減る。
#   開始時に弾かれた項目があっても追加の呼び出しはしない。
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く。前の回の結果と混ざらない。
#
# 項目ごとに次を保存する（取れたものだけ。#214 と同じ形）。
#   <label>.sql             投げた SQL そのもの（**DB 名・テーブル名を含む。実名を含む**）
#   <label>.context.txt     投げた QueryExecutionContext（実名を含む）
#   <label>.start.err       StartQueryExecution の標準エラー（開始時に弾かれた証拠。
#                            一切加工せず AWS CLI の出力そのまま保存する）
#   <label>.execution.json  GetQueryExecution の生の応答（開始できた項目だけ）
#   <label>.execution.err   GetQueryExecution の標準エラー
#   <label>.reason.txt      State・StateChangeReason・AthenaError（**実名を含みうる**）
#   <label>.gqr.json        GetQueryResults の 1 ページ目（読み取り専用の項目だけ）
#   <label>.rows.txt        裏取りの一覧系の文（SHOW TABLES・SHOW DATABASES・
#                            SHOW PARTITIONS・DESCRIBE・SHOW TBLPROPERTIES など）の
#                            全行（**実名**）
#
# summary の決め手になる列は state・statement_type/substatement_type・
# qec_catalog/qec_database（GetQueryExecution が返した QueryExecutionContext）・
# start_message/start_athena_error_code（開始時に弾かれた項目）・
# error_category/error_type/error_message（開始できて FAILED になった項目）。
# DB 名・出力先・バケット名・対象テーブル名・アカウント ID は出さず、プレースホルダに畳む
# （末尾の「消えないかもしれない S3 のデータ」節だけは、手で消すために実名のまま出す）。
# 一覧系の文の結果の中身は summary に出さず、裏取りは件数・有無・行数だけ（info_row）。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください}"
: "${DB:?DB にデータベース名を設定してください}"
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_DIR=${OUT_DIR:-${DEV_HOST_HOME:-$HOME}/athena-context-catalog-measurements}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}

PROBE_PREFIX=athena_local_probe_217
NOCAT=nocatalog_217

T=${PROBE_PREFIX}_t
TREN=${PROBE_PREFIX}_t_ren
TP=${PROBE_PREFIX}_tp
TI=${PROBE_PREFIX}_ti
VW=${PROBE_PREFIX}_v
VW2=${PROBE_PREFIX}_v2
VW3=${PROBE_PREFIX}_v3
EXT=${PROBE_PREFIX}_ext
ICE2=${PROBE_PREFIX}_ice2
NEWDB=${PROBE_PREFIX}_db
NEWSCH=${PROBE_PREFIX}_sch

RUN_TS=$(date +%Y%m%d-%H%M%S)
ICE_LOC="${OUTPUT}tables/217-iceberg/$RUN_TS/"
EXT_LOC="${OUTPUT}tables/217-ext/$RUN_TS/"
ICE2_LOC="${OUTPUT}tables/217-ice2/$RUN_TS/"

RUN_DIR="$OUT_DIR/run-$RUN_TS"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\tstatement_type\tsubstatement_type\tqec_catalog\tqec_database\tstart_message\tstart_athena_error_code\terror_category\terror_type\terror_message\treason_line\tnote\n' > "$SUMMARY"
echo "出力先: $RUN_DIR"

# StartQueryExecution を実際に呼んだ回数（再試行も含む）。summary.txt の冒頭に出す。
START_CALL_FILE="$RUN_DIR/.start-calls"
: > "$START_CALL_FILE"

# StartQueryExecution に渡す QueryExecutionContext。ふだんは対照の OK（CATALOG・DB）で、
# run_in_ctx で 1 文だけ差し替える。
QE_CONTEXT="Catalog=$CATALOG,Database=$DB"
NC_CTX="Catalog=$NOCAT,Database=$DB"

# trap の後始末で 1 文だけ投げる（結果は確かめない。OK Context）。
cleanup_drop() {
  aws athena start-query-execution --region "$REGION" \
    --query-string "$1" \
    --query-execution-context "Catalog=$CATALOG,Database=$DB" \
    --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
}

# 中間ファイル（.tmp-*）は、途中で止めても残らないよう trap で消す。作ったかもしれない
# ものは全部 IF EXISTS で消す（本編の z-cleanup-* で消せなかったときの保険。cleanup 自体は
# 結果を確かめない）。
cleanup() {
  rm -f "$RUN_DIR"/.tmp-*
  cleanup_drop "DROP TABLE IF EXISTS $DB.$T"
  cleanup_drop "DROP TABLE IF EXISTS $DB.$TREN"
  cleanup_drop "DROP TABLE IF EXISTS $DB.$TP"
  cleanup_drop "DROP TABLE IF EXISTS $DB.$TI"
  cleanup_drop "DROP TABLE IF EXISTS $DB.$EXT"
  cleanup_drop "DROP TABLE IF EXISTS $DB.$ICE2"
  cleanup_drop "DROP VIEW IF EXISTS $DB.$VW"
  cleanup_drop "DROP VIEW IF EXISTS $DB.$VW2"
  cleanup_drop "DROP VIEW IF EXISTS $DB.$VW3"
  cleanup_drop "DROP DATABASE IF EXISTS $NEWDB"
  cleanup_drop "DROP SCHEMA IF EXISTS $NEWSCH"
}
trap cleanup EXIT

# 実名（DB 名・出力先・バケット名・アカウント ID）を置換して隠す。
# アカウント ID は、前後が数字でない 12 桁の数字として伏せる。
OUTPUT_BUCKET=${OUTPUT#s3://}
OUTPUT_BUCKET=${OUTPUT_BUCKET%%/*}
redact() {
  local s=$1
  s=${s//$DB/<DB>}
  s=${s//$OUTPUT/<OUTPUT>}
  s=${s//$OUTPUT_BUCKET/<BUCKET>}
  printf '%s' "$s" | sed -E 's/(^|[^0-9])[0-9]{12}([^0-9]|$)/\1<ACCOUNT_ID>\2/g'
}

# 標準入力から接頭辞 athena_local_probe_217 を置換して隠す。この実測で作る名前は全部
# この接頭辞で始まるので、これだけで足りる（#214 の $TARGET_TABLE 相当の別名は無い）。
mask_names() {
  local s
  s=$(cat)
  s=${s//$PROBE_PREFIX/<PROBE>}
  printf '%s' "$s"
}

# redact と mask_names を両方かけて、実名をすべて伏せる。
hide() {
  local s
  s=$(redact "$1")
  s=$(printf '%s' "$s" | mask_names)
  printf '%s' "$s"
}

# 制御文字を落として短くする。note・summary に入れる前に必ず通す。
sanitize() {
  printf '%s' "$1" | tr '\t\n\r' '   ' | cut -c1-300
}

# stderr ファイルの 1 行目を、実名を隠して短く返す。ファイルが無ければ定型文を返す。
first_err_line() {
  local f=$1 line
  if [ -s "$f" ]; then
    line=$(grep -m1 . "$f")
    sanitize "$(hide "$line")"
  else
    echo "(エラー出力なし)"
  fi
}

# 名前解決・接続などの一時的な失敗だけを見分ける。
is_transient_error() {
  [ -s "$1" ] || return 1
  grep -qiE 'Could not connect|Connection aborted|Connection reset|EndpointConnectionError|Temporary failure in name resolution|Name or service not known|Network is unreachable|Read timed out|[Cc]onnect timeout|ConnectTimeoutError|ReadTimeoutError|SSLError|Broken pipe' "$1"
}

# start.err から Message と AthenaErrorCode を抜く（#200 の実例どおり、AWS CLI は
# 開始時に弾かれた StartQueryExecution の標準エラーに、追加の呼び出しをしなくても
# 両方とも出す）。Message は「operation: 」より後ろ、「\n\nAdditional error details:」の
# 手前まで（無ければファイル末尾まで）。AthenaErrorCode は「AthenaErrorCode: 」の行から。
# どちらも見つからなければ "-"。
start_err_message() {
  local f=$1 msg
  [ -s "$f" ] || { echo "-"; return; }
  msg=$(python3 -c '
import sys
try:
    text = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
except Exception:
    print("-")
    sys.exit(0)
marker = "operation: "
idx = text.find(marker)
if idx == -1:
    print("-")
    sys.exit(0)
rest = text[idx + len(marker):]
end = rest.find("\n\nAdditional error details:")
msg = rest[:end] if end != -1 else rest
msg = msg.rstrip("\r\n \t")
msg = msg.replace("\\", "<BACKSLASH>")
msg = msg.replace("\t", "<TAB>").replace("\r", "<CR>").replace("\n", "<LF>")
print(msg)
' "$f")
  if [ -n "$msg" ] && [ "$msg" != "-" ]; then
    sanitize "$(hide "$msg")"
  else
    echo "-"
  fi
}

start_err_code() {
  local f=$1 line
  [ -s "$f" ] || { echo "-"; return; }
  line=$(grep -m1 -oE '^AthenaErrorCode: .*' "$f")
  if [ -n "$line" ]; then
    sanitize "$(hide "${line#AthenaErrorCode: }")"
  else
    echo "-"
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
    sanitize "$(hide "$line")"
  else
    echo "-"
  fi
}

# execution.json から AthenaError の ErrorCategory / ErrorType / ErrorMessage をタブ区切りで返す。
athena_error_fields_of() {
  python3 -c 'import json, sys
try:
    err = json.load(open(sys.argv[1]))["QueryExecution"]["Status"].get("AthenaError")
except Exception:
    err = None
if err is None:
    print("-\t-\t-")
else:
    def g(k):
        v = err.get(k)
        return "-" if v is None else str(v).replace("\t", " ").replace("\n", " ")
    print("%s\t%s\t%s" % (g("ErrorCategory"), g("ErrorType"), g("ErrorMessage")))' "$1"
}

# execution.json から StatementType / SubstatementType をタブ区切りで返す。
read_execution_fields() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception:
    print("-\t-")
    sys.exit(0)
print("%s\t%s" % (d.get("StatementType") or "-", d.get("SubstatementType") or "-"))' "$1"
}

# execution.json から GetQueryExecution が返した QueryExecutionContext（Catalog・Database）を
# タブ区切りで返す。送った Context と違う値が返れば、それ自体が解決の証拠になる。
qec_of() {
  python3 -c 'import json, sys
try:
    ctx = json.load(open(sys.argv[1]))["QueryExecution"].get("QueryExecutionContext") or {}
except Exception:
    print("-\t-")
    sys.exit(0)
print("%s\t%s" % (ctx.get("Catalog") or "-", ctx.get("Database") or "-"))' "$1"
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
      --query-execution-context "$QE_CONTEXT" \
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

# summary.tsv に 1 行積む。列の並びはヘッダと同じ 13 列で固定する。
emit_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$SUMMARY"
}

# 項目を未測定として summary に 1 行残す。全体を止めずに次へ進む。
skip() {
  local label=$1 note=$2
  echo "== $label: 未測定（$note）"
  emit_row "$label" "SKIPPED" - - - - - - - - - - "$(sanitize "$(hide "$note")")"
}

# 測定ではない確かめの結果（裏取り・件数・有無など）を summary に 1 行残す
# （state は INFO）。
info_row() {
  local label=$1 note=$2
  echo "== $label: $note"
  # note には DB 名・表名が入るので、summary には伏せて書く（2026-09-26 のラウンドで実名が出た）。
  emit_row "$label" "INFO" - - - - - - - - - - "$(sanitize "$(hide "$note")")"
}

# ラベルを指定して 1 文を実行する。呼んだ時点の QueryExecutionContext（QE_CONTEXT）を
# <label>.context.txt に残す。開始できなければ、AthenaErrorCode・Message をその場の
# start.err からそのまま抜く（追加の呼び出しはしない）。開始できたら終端状態まで待って
# StatementType・SubstatementType・GetQueryExecution が返した QueryExecutionContext・
# FAILED の理由を採る。
run() {
  local label=$1 sql=$2
  local id state stype sub note reason_line qec_cat qec_db
  local start_msg="-" start_code="-" err_cat="-" err_type="-" err_msg="-"

  printf '%s\n' "$sql" > "$RUN_DIR/$label.sql"
  printf '%s\n' "$QE_CONTEXT" > "$RUN_DIR/$label.context.txt"
  id=$(start_query_retry "$label" "$sql")
  LAST_ATTEMPTS=$(read_attempts "$label")

  if [ -z "${id:-}" ]; then
    note="attempts=$LAST_ATTEMPTS; $(first_err_line "$RUN_DIR/$label.start.err")"
    start_msg=$(start_err_message "$RUN_DIR/$label.start.err")
    start_code=$(start_err_code "$RUN_DIR/$label.start.err")
    echo "== $label: 開始できませんでした（試行 $LAST_ATTEMPTS 回）。AthenaErrorCode=$start_code"
    emit_row "$label" "START_FAILED" - - - - "$start_msg" "$start_code" - - - - "$(sanitize "$note")"
    return 1
  fi

  state=$(poll_until_terminal "$id")

  aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.execution.json" 2> "$RUN_DIR/$label.execution.err"
  write_reason "$RUN_DIR/$label.execution.json" "$RUN_DIR/$label.reason.txt"
  reason_line=$(reason_first_line "$RUN_DIR/$label.execution.json")

  IFS=$'\t' read -r stype sub < <(read_execution_fields "$RUN_DIR/$label.execution.json")
  IFS=$'\t' read -r qec_cat qec_db < <(qec_of "$RUN_DIR/$label.execution.json")
  qec_cat=$(sanitize "$(hide "$qec_cat")")
  qec_db=$(sanitize "$(hide "$qec_db")")

  note="attempts=$LAST_ATTEMPTS"
  case "$state" in
    FAILED | CANCELLED)
      IFS=$'\t' read -r err_cat err_type err_msg < <(athena_error_fields_of "$RUN_DIR/$label.execution.json")
      err_msg=$(sanitize "$(hide "$err_msg")")
      ;;
  esac

  echo "== $label  state=$state  stype=$stype/$sub  qec=$qec_cat/$qec_db  error=$err_cat/$err_type"
  emit_row "$label" "$state" "$stype" "$sub" "$qec_cat" "$qec_db" "$start_msg" "$start_code" \
    "$err_cat" "$err_type" "$err_msg" "$reason_line" "$(sanitize "$note")"
  [ "$state" = SUCCEEDED ]
}

# QueryExecutionContext を $1 に差し替えて run を 1 回呼ぶ。run() が context.txt を書くので
# ここでは差し替えて戻すだけ。
run_in_ctx() {
  local ctx=$1 saved=$QE_CONTEXT rc
  shift
  QE_CONTEXT=$ctx
  run "$@"
  rc=$?
  QE_CONTEXT=$saved
  return "$rc"
}

# <label>.execution.json から QueryExecutionId を返す（無ければ空）。
query_id_of() {
  python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1]))["QueryExecution"]["QueryExecutionId"])
except Exception:
    print("")' "$RUN_DIR/$1.execution.json" 2>/dev/null
}

# <label>.reason.txt が SUCCEEDED を示していれば真。
succeeded() {
  grep -qs "^State: SUCCEEDED" "$RUN_DIR/$1.reason.txt"
}

# 対象の名前（接頭辞 athena_local_probe_217 始まりの名前や、SHOW 系の 1 列目）の一覧を
# GetQueryResults でページングしながら全件取る（S3 は使わない）。SHOW TABLES／
# SHOW DATABASES だけでなく、DESCRIBE・SHOW PARTITIONS・SHOW TBLPROPERTIES などの
# 複数列に見える文も、Athena は 1 行 1 Datum（タブ連結済みの 1 つの文字列）で返すので
# （docs/dev/measurements/result-files.md の該当節）、この関数で汎用的に使える。
fetch_all_table_names() {
  local id=$1 out=$2 token="" page=0
  : > "$out"
  while :; do
    page=$((page + 1))
    if [ -z "$token" ]; then
      aws athena get-query-results --region "$REGION" --query-execution-id "$id" \
        --max-results 1000 > "$RUN_DIR/.tmp-gqr-page.json" 2>"$RUN_DIR/.tmp-gqr-page.err"
    else
      aws athena get-query-results --region "$REGION" --query-execution-id "$id" \
        --max-results 1000 --next-token "$token" > "$RUN_DIR/.tmp-gqr-page.json" 2>"$RUN_DIR/.tmp-gqr-page.err"
    fi
    [ -s "$RUN_DIR/.tmp-gqr-page.json" ] || break
    python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
for r in d.get("ResultSet", {}).get("Rows", []):
    data = r.get("Data", [])
    if data and data[0].get("VarCharValue") is not None:
        print(data[0]["VarCharValue"])' "$RUN_DIR/.tmp-gqr-page.json" >> "$out"
    token=$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("NextToken", ""))
except Exception:
    print("")' "$RUN_DIR/.tmp-gqr-page.json")
    [ -n "$token" ] || break
    [ "$page" -ge 20 ] && break
  done
  rm -f "$RUN_DIR/.tmp-gqr-page.json" "$RUN_DIR/.tmp-gqr-page.err"
}

# SUCCEEDED した読み取り専用の項目の GetQueryResults の最初の 1 ページを <label>.gqr.json に
# 保存し、ResultSetMetadata.ColumnInfo[0] の CatalogName・SchemaName・TableName と行数を
# summary に INFO 行で残す（本物が ColumnInfo にどのカタログ名を入れるかを見るため。
# 行の中身そのものは出さない）。追加の StartQueryExecution は投げない（GetQueryResults は
# 課金対象ではない）。
gqr_check() {
  local label=$1 id
  if ! succeeded "$label"; then
    skip "$label-gqr" "SUCCEEDED でないため未測定"
    return
  fi
  id=$(query_id_of "$label")
  if [ -z "$id" ]; then
    skip "$label-gqr" "QueryExecutionId が取れず未測定"
    return
  fi
  aws athena get-query-results --region "$REGION" --query-execution-id "$id" --max-results 5 \
    > "$RUN_DIR/$label.gqr.json" 2> "$RUN_DIR/$label.gqr.err"
  if [ ! -s "$RUN_DIR/$label.gqr.json" ]; then
    info_row "$label-gqr" "GetQueryResults が失敗: $(first_err_line "$RUN_DIR/$label.gqr.err")"
    return
  fi
  local info
  info=$(python3 -c '
import json, sys
try:
    rs = json.load(open(sys.argv[1]))["ResultSet"]
except Exception:
    print("(gqr.json を読めませんでした)")
    sys.exit(0)
cols = rs.get("ResultSetMetadata", {}).get("ColumnInfo", [])
rows = rs.get("Rows", [])
if cols:
    c = cols[0]
    print("ColumnInfo[0]: CatalogName=%s SchemaName=%s TableName=%s / 行数(先頭5件まで)=%d" % (
        c.get("CatalogName") or "-", c.get("SchemaName") or "-", c.get("TableName") or "-", len(rows)))
else:
    print("ColumnInfo 無し / 行数(先頭5件まで)=%d" % len(rows))
' "$RUN_DIR/$label.gqr.json")
  info_row "$label-gqr" "$(sanitize "$(hide "$info")")"
}

# --- ここから #217 で新設したヘルパ ------------------------------------------------

# NC Context で 1 文を実行する。失敗（開始失敗・FAILED・CANCELLED・TIMEOUT のいずれか）
# なら、同じ文を OK Context で対照として投げる。戻り値は NC が SUCCEEDED なら 0、それ以外は
# 1（呼び出し側は、0 のときだけ効果を OK Context の別の文で裏取りする）。
measure_nc() {
  local base=$1 sql=$2
  if run_in_ctx "$NC_CTX" "${base}-nc" "$sql"; then
    return 0
  fi
  run "${base}-ok" "$sql" || true
  return 1
}

# NC Context で読み取り専用の 1 文を実行する。成功したら、その文自身の GetQueryResults を
# gqr_check() で見るだけ（追加の StartQueryExecution は投げない）。失敗したら、同じ文を
# OK Context で対照として投げる。
measure_nc_read() {
  local base=$1 sql=$2
  if run_in_ctx "$NC_CTX" "${base}-nc" "$sql"; then
    gqr_check "${base}-nc"
    return 0
  fi
  run "${base}-ok" "$sql" || true
  return 1
}

# OK Context で $2 を投げ、結果（1 行 1 Datum の連結済みテキスト）に $3 という行が完全
# 一致で何件あるかを info_row に残す（SHOW TABLES／SHOW DATABASES の存在確認）。
verify_membership() {
  local label=$1 sql=$2 name=$3 desc=$4
  if run "$label" "$sql"; then
    fetch_all_table_names "$(query_id_of "$label")" "$RUN_DIR/$label.rows.txt"
    local count
    count=$(grep -Fxc "$name" "$RUN_DIR/$label.rows.txt")
    info_row "${label}-check" "件数=$count（$desc）"
  else
    info_row "${label}-check" "確認の文が通らず確かめられなかった（$desc）"
  fi
}

# OK Context で $2 を投げ、結果（1 行 1 Datum の連結済みテキスト、行ごと）のどこかの行に
# 拡張正規表現 $3 がマッチするかを info_row に残す（中身は出さず有無だけ）。
verify_contains() {
  local label=$1 sql=$2 pattern=$3 desc=$4
  if run "$label" "$sql"; then
    fetch_all_table_names "$(query_id_of "$label")" "$RUN_DIR/$label.rows.txt"
    if grep -qE "$pattern" "$RUN_DIR/$label.rows.txt"; then
      info_row "${label}-check" "含まれる（$desc）"
    else
      info_row "${label}-check" "含まれない（$desc）"
    fi
  else
    info_row "${label}-check" "確認の文が通らず確かめられなかった（$desc）"
  fi
}

# OK Context で「SELECT count(*) AS c FROM $2」を投げ、件数を info_row に残す。
verify_count() {
  local label=$1 table=$2 desc=$3
  if run "$label" "SELECT count(*) AS c FROM $table"; then
    fetch_all_table_names "$(query_id_of "$label")" "$RUN_DIR/$label.rows.txt"
    local c
    # 1 行目は列名の見出し（c）なので 2 行目を読む。
    c=$(sed -n 2p "$RUN_DIR/$label.rows.txt" 2>/dev/null | tr -d '\r')
    info_row "${label}-check" "count(*)=${c:-?}（$desc）"
  else
    info_row "${label}-check" "SELECT count(*) が通らず確かめられなかった（$desc）"
  fi
}

# OK Context で $2 を投げ、返った行数を info_row に残す（中身は出さない。行数だけ確かめ
# たいとき用。SHOW FUNCTIONS のように既知の行数が無い一覧の確認に使う）。
verify_rowcount() {
  local label=$1 sql=$2 desc=$3
  if run "$label" "$sql"; then
    fetch_all_table_names "$(query_id_of "$label")" "$RUN_DIR/$label.rows.txt"
    local cnt
    cnt=$(wc -l < "$RUN_DIR/$label.rows.txt" | tr -d ' ')
    info_row "${label}-check" "行数=$cnt（$desc）"
  else
    info_row "${label}-check" "確認の文が通らず確かめられなかった（$desc）"
  fi
}

# --- preflight ---------------------------------------------------------------

if ! run probe-show-tables "SHOW TABLES"; then
  echo
  echo "SHOW TABLES が通りませんでした。DB か CATALOG の指定が実在しません。"
  echo "理由: $RUN_DIR/probe-show-tables.reason.txt"
  exit 1
fi
SHOW_TABLES_ID=$(query_id_of probe-show-tables)
if [ -z "$SHOW_TABLES_ID" ]; then
  echo
  echo "SHOW TABLES の QueryExecutionId が取れませんでした。止まります。"
  exit 1
fi
fetch_all_table_names "$SHOW_TABLES_ID" "$RUN_DIR/tables.txt"
if grep -qi "$PROBE_PREFIX" "$RUN_DIR/tables.txt"; then
  echo
  echo "このデータベースに ${PROBE_PREFIX}* という名前のテーブル／ビューが既にあります。"
  echo "上書き・削除してしまうので、何も作らずに止まります。一覧: $RUN_DIR/tables.txt"
  exit 1
fi

if ! run probe-show-databases "SHOW DATABASES"; then
  echo
  echo "SHOW DATABASES が通りませんでした。止まります。"
  echo "理由: $RUN_DIR/probe-show-databases.reason.txt"
  exit 1
fi
SHOW_DATABASES_ID=$(query_id_of probe-show-databases)
if [ -z "$SHOW_DATABASES_ID" ]; then
  echo
  echo "SHOW DATABASES の QueryExecutionId が取れませんでした。止まります。"
  exit 1
fi
fetch_all_table_names "$SHOW_DATABASES_ID" "$RUN_DIR/databases.txt"
if grep -qi "$PROBE_PREFIX" "$RUN_DIR/databases.txt"; then
  echo
  echo "既に ${PROBE_PREFIX}* という名前のデータベース／スキーマがあります。"
  echo "上書き・削除してしまうので、何も作らずに止まります。一覧: $RUN_DIR/databases.txt"
  exit 1
fi

# --- 準備（OK Context）---------------------------------------------------------

P1_OK=0
P1_QID=""
if run p1-setup-t "CREATE TABLE $DB.$T AS SELECT 1 AS n, 'x' AS s"; then
  P1_OK=1
  P1_QID=$(query_id_of p1-setup-t)
fi

P2_OK=0
P2_QID=""
if run p2-setup-tp "CREATE TABLE $DB.$TP WITH (partitioned_by = ARRAY['p']) AS SELECT 1 AS n, 'a' AS p"; then
  P2_OK=1
  P2_QID=$(query_id_of p2-setup-tp)
fi

P3_OK=0
if run p3-setup-ti "CREATE TABLE $DB.$TI WITH (table_type = 'ICEBERG', location = '$ICE_LOC', is_external = false) AS SELECT 1 AS n, 'x' AS s"; then
  P3_OK=1
fi

P4_OK=0
if [ "$P1_OK" = 1 ]; then
  if run p4-setup-v "CREATE VIEW $DB.$VW AS SELECT n FROM $DB.$T"; then
    P4_OK=1
  fi
else
  skip p4-setup-v "p1（$T の準備）が失敗したため未測定"
fi

# --- 1〜3. INSERT（1 部・2 部・VALUES 形） ------------------------------------------

if [ "$P1_OK" = 1 ]; then
  if measure_nc n1-insert1 "INSERT INTO $T SELECT 2, 'y'"; then
    verify_count n1-verify "$T" "1 部の名前の INSERT の後の $T の行数（既定カタログ）"
  fi
else
  skip n1-insert1-nc "p1（$T の準備）が失敗したため未測定"
  skip n1-verify "p1（$T の準備）が失敗したため未測定"
fi

if [ "$P1_OK" = 1 ]; then
  if measure_nc n2-insert2 "INSERT INTO $DB.$T SELECT 3, 'z'"; then
    verify_count n2-verify "$T" "2 部の名前の INSERT の後の $T の行数（既定カタログ）"
  fi
else
  skip n2-insert2-nc "p1（$T の準備）が失敗したため未測定"
  skip n2-verify "p1（$T の準備）が失敗したため未測定"
fi

if [ "$P1_OK" = 1 ]; then
  if measure_nc n3-insertvalues "INSERT INTO $T VALUES (4, 'w')"; then
    verify_count n3-verify "$T" "VALUES 形の INSERT の後の $T の行数（既定カタログ）"
  fi
else
  skip n3-insertvalues-nc "p1（$T の準備）が失敗したため未測定"
  skip n3-verify "p1（$T の準備）が失敗したため未測定"
fi

# --- 4・5. CREATE EXTERNAL TABLE（Hive）・素の CREATE TABLE（Iceberg 風） ---------------

if measure_nc n4-extddl "CREATE EXTERNAL TABLE $EXT (n int) LOCATION '$EXT_LOC'"; then
  verify_membership n4-verify "SHOW TABLES" "$EXT" "$EXT が既定カタログの $DB にあるか（CREATE EXTERNAL TABLE の後）"
fi

if measure_nc n5-icecreate "CREATE TABLE $ICE2 (n int) LOCATION '$ICE2_LOC' TBLPROPERTIES ('table_type'='ICEBERG')"; then
  verify_membership n5-verify "SHOW TABLES" "$ICE2" "$ICE2 が既定カタログの $DB にあるか（CREATE TABLE の後）"
fi

# --- 6・7. ALTER TABLE ADD COLUMNS・SET TBLPROPERTIES（$T に） -----------------------

if [ "$P1_OK" = 1 ]; then
  if measure_nc n6-altercols "ALTER TABLE $T ADD COLUMNS (c string)"; then
    verify_contains n6-verify "DESCRIBE $T" '^c([[:space:]]|$)' "$T の DESCRIBE に列 c があるか"
  fi
else
  skip n6-altercols-nc "p1（$T の準備）が失敗したため未測定"
  skip n6-verify "p1（$T の準備）が失敗したため未測定"
fi

if [ "$P1_OK" = 1 ]; then
  if measure_nc n7-altertblprops "ALTER TABLE $T SET TBLPROPERTIES ('athena_local_217'='1')"; then
    verify_contains n7-verify "SHOW TBLPROPERTIES $T" 'athena_local_217' "$T の SHOW TBLPROPERTIES に athena_local_217 があるか"
  fi
else
  skip n7-altertblprops-nc "p1（$T の準備）が失敗したため未測定"
  skip n7-verify "p1（$T の準備）が失敗したため未測定"
fi

# --- 8〜11. パーティション（$TP に）------------------------------------------------

if [ "$P2_OK" = 1 ]; then
  if measure_nc n8-addpartition "ALTER TABLE $TP ADD PARTITION (p='b')"; then
    verify_contains n8-verify "SHOW PARTITIONS $TP" '^p=b$' "$TP の SHOW PARTITIONS に p=b があるか"
  fi
else
  skip n8-addpartition-nc "p2（$TP の準備）が失敗したため未測定"
  skip n8-verify "p2（$TP の準備）が失敗したため未測定"
fi

if [ "$P2_OK" = 1 ]; then
  measure_nc_read n9-showpartitions "SHOW PARTITIONS $TP"
else
  skip n9-showpartitions-nc "p2（$TP の準備）が失敗したため未測定"
fi

if [ "$P2_OK" = 1 ]; then
  if measure_nc n10-droppartition "ALTER TABLE $TP DROP PARTITION (p='b')"; then
    verify_contains n10-verify "SHOW PARTITIONS $TP" '^p=b$' "$TP の SHOW PARTITIONS に p=b が残っているか（含まれない＝消えた）"
  fi
else
  skip n10-droppartition-nc "p2（$TP の準備）が失敗したため未測定"
  skip n10-verify "p2（$TP の準備）が失敗したため未測定"
fi

if [ "$P2_OK" = 1 ]; then
  if measure_nc n11-msck "MSCK REPAIR TABLE $TP"; then
    verify_rowcount n11-verify "SHOW PARTITIONS $TP" "MSCK REPAIR TABLE の後の $TP のパーティション行数"
  fi
else
  skip n11-msck-nc "p2（$TP の準備）が失敗したため未測定"
  skip n11-verify "p2（$TP の準備）が失敗したため未測定"
fi

# --- 12・13. CREATE VIEW（表を参照しない・$T を参照） --------------------------------

if measure_nc n12-createview-noref "CREATE VIEW $VW2 AS SELECT 1 AS n"; then
  verify_membership n12-verify "SHOW TABLES" "$VW2" "$VW2 が既定カタログの $DB にあるか（CREATE VIEW の後）"
fi

if [ "$P1_OK" = 1 ]; then
  if measure_nc n13-createview-ref "CREATE VIEW $VW3 AS SELECT n FROM $T"; then
    verify_membership n13-verify "SHOW TABLES" "$VW3" "$VW3 が既定カタログの $DB にあるか（CREATE VIEW の後）"
  fi
else
  skip n13-createview-ref-nc "p1（$T の準備）が失敗したため未測定"
  skip n13-verify "p1（$T の準備）が失敗したため未測定"
fi

# --- 14・15・23. $VW への読み取り（SHOW CREATE VIEW・DESCRIBE・SHOW COLUMNS IN） --------
# 23 は対象のビューが消える前に測る必要があるため、ここ（14・15 の直後、16 の DROP の
# 手前）で実行する。番号は issue の指示どおり 23 だが、実行順は依存関係を優先した。

if [ "$P4_OK" = 1 ]; then
  measure_nc_read n14-showcreateview "SHOW CREATE VIEW $VW"
  measure_nc_read n15-describeview "DESCRIBE $VW"
  measure_nc_read n23-showcolumnsin "SHOW COLUMNS IN $VW"
else
  skip n14-showcreateview-nc "p4（$VW の準備）が失敗したため未測定"
  skip n15-describeview-nc "p4（$VW の準備）が失敗したため未測定"
  skip n23-showcolumnsin-nc "p4（$VW の準備）が失敗したため未測定"
fi

# --- 16. DROP VIEW IF EXISTS（$VW2・$VW） ------------------------------------------

if measure_nc n16a-dropview-v2 "DROP VIEW IF EXISTS $VW2"; then
  verify_membership n16a-verify "SHOW TABLES" "$VW2" "$VW2 が既定カタログの $DB に残っているか（0 なら消えた）"
fi

if [ "$P4_OK" = 1 ]; then
  if measure_nc n16b-dropview-v "DROP VIEW IF EXISTS $VW"; then
    verify_membership n16b-verify "SHOW TABLES" "$VW" "$VW が既定カタログの $DB に残っているか（0 なら消えた）"
  fi
else
  skip n16b-dropview-v-nc "p4（$VW の準備）が失敗したため未測定"
fi

# --- 17. CREATE/DROP DATABASE（Hive 書式） ------------------------------------------

if measure_nc n17a-createdb "CREATE DATABASE IF NOT EXISTS $NEWDB"; then
  verify_membership n17a-create-verify "SHOW DATABASES" "$NEWDB" "$NEWDB が既定カタログにあるか（CREATE DATABASE の後）"
fi

if measure_nc n17a-dropdb "DROP DATABASE IF EXISTS $NEWDB"; then
  verify_membership n17a-drop-verify "SHOW DATABASES" "$NEWDB" "$NEWDB が既定カタログに残っているか（DROP DATABASE の後。0 なら消えた）"
fi

# --- 17b. CREATE/DROP SCHEMA（Trino でも通る綴り） -----------------------------------

if measure_nc n17b-createschema "CREATE SCHEMA IF NOT EXISTS $NEWSCH"; then
  verify_membership n17b-create-verify "SHOW DATABASES" "$NEWSCH" "$NEWSCH が既定カタログにあるか（CREATE SCHEMA の後）"
fi

if measure_nc n17b-dropschema "DROP SCHEMA IF EXISTS $NEWSCH"; then
  verify_membership n17b-drop-verify "SHOW DATABASES" "$NEWSCH" "$NEWSCH が既定カタログに残っているか（DROP SCHEMA の後。0 なら消えた）"
fi

# --- 18. SHOW FUNCTIONS -------------------------------------------------------------
# 結果の中身は summary に出さず行数だけ（成功したときだけ、全件ページングして正確な
# 行数を出す。gqr_check の --max-results 5 だと関数の総数までは分からないため）。

if run_in_ctx "$NC_CTX" n18-showfunctions-nc "SHOW FUNCTIONS"; then
  fetch_all_table_names "$(query_id_of n18-showfunctions-nc)" "$RUN_DIR/n18-showfunctions-nc.rows.txt"
  N18_COUNT=$(wc -l < "$RUN_DIR/n18-showfunctions-nc.rows.txt" | tr -d ' ')
  info_row n18-showfunctions-nc-check "行数=$N18_COUNT（SHOW FUNCTIONS の結果行数。中身は出さない）"
else
  run n18-showfunctions-ok "SHOW FUNCTIONS" || true
fi

# --- 19. Iceberg の DML・保守文（$TI に） -------------------------------------------
# WHERE n = 999 はどの行にも当たらない（準備で入れたのは n=1 の 1 行だけ）ので、
# DELETE・UPDATE・MERGE は成否だけが焦点で、行数への影響は無いはず。まとめて 1 回だけ
# OK Context の SELECT count(*) で裏取りする（個別の裏取りはしない）。

if [ "$P3_OK" = 1 ]; then
  measure_nc n19a-delete "DELETE FROM $TI WHERE n = 999" || true
  measure_nc n19b-update "UPDATE $TI SET s = 'u' WHERE n = 999" || true
  measure_nc n19c-merge "MERGE INTO $TI t USING (SELECT 999 AS n) s ON t.n = s.n WHEN MATCHED THEN DELETE" || true
  measure_nc n19d-optimize "OPTIMIZE $TI REWRITE DATA USING BIN_PACK" || true
  measure_nc n19e-vacuum "VACUUM $TI" || true
  verify_count n19-group-verify "$TI" "19a〜19e（DELETE/UPDATE/MERGE/OPTIMIZE/VACUUM）の後の $TI の行数（1 のままのはず）"

  if measure_nc n19f-altercols "ALTER TABLE $TI ADD COLUMNS (c string)"; then
    verify_contains n19f-verify "DESCRIBE $TI" '^c([[:space:]]|$)' "$TI の DESCRIBE に列 c があるか"
  fi
else
  skip n19a-delete-nc "p3（$TI の準備）が失敗したため未測定"
  skip n19b-update-nc "p3（$TI の準備）が失敗したため未測定"
  skip n19c-merge-nc "p3（$TI の準備）が失敗したため未測定"
  skip n19d-optimize-nc "p3（$TI の準備）が失敗したため未測定"
  skip n19e-vacuum-nc "p3（$TI の準備）が失敗したため未測定"
  skip n19-group-verify "p3（$TI の準備）が失敗したため未測定"
  skip n19f-altercols-nc "p3（$TI の準備）が失敗したため未測定"
  skip n19f-verify "p3（$TI の準備）が失敗したため未測定"
fi

# --- 20. SHOW TBLPROPERTIES・SHOW CREATE TABLE（$TI に。Iceberg 版の対照） -------------

if [ "$P3_OK" = 1 ]; then
  measure_nc_read n20a-tblprops "SHOW TBLPROPERTIES $TI"
  measure_nc_read n20b-showcreate "SHOW CREATE TABLE $TI"
else
  skip n20a-tblprops-nc "p3（$TI の準備）が失敗したため未測定"
  skip n20b-showcreate-nc "p3（$TI の準備）が失敗したため未測定"
fi

# --- 21. DROP TABLE IF EXISTS（$EXT。実物がある場合の DROP） --------------------------

if measure_nc n21-dropext "DROP TABLE IF EXISTS $EXT"; then
  verify_membership n21-verify "SHOW TABLES" "$EXT" "$EXT が既定カタログの $DB に残っているか（0 なら消えた）"
fi

# --- 22. ALTER TABLE ... RENAME TO（$T。<p>_t を使う項目の一番最後に置く）--------------
# #43 の実測（docs/dev/measurements/result-files.md）どおりなら、Hive の RENAME TO は
# カタログの解決とは無関係に、常に Glue の `Table cannot be renamed` で失敗する。
# なのでこの項目の決め手は成功/失敗そのものではなく、エラーの中身
# （CATALOG_NOT_FOUND なら未解決、Glue の rename 拒否なら既定カタログまで解決できている
# 証拠）。エラーの中身は summary.tsv の error_category/error_type/error_message に出る。

if [ "$P1_OK" = 1 ]; then
  if run_in_ctx "$NC_CTX" n22-rename-nc "ALTER TABLE $T RENAME TO $TREN"; then
    # 成功した（＝既定カタログまで解決できた、かつ #43 の実測と違って Hive の RENAME TO が
    # 通った）。念のため OK Context で元の名前に戻す。
    if run n22-renameback "ALTER TABLE $TREN RENAME TO $T"; then
      info_row n22-renameback-check "成功（$TREN を $T に戻せた＝$TREN が既定カタログに実在した証拠）"
    else
      info_row n22-renameback-check "失敗（$TREN を $T に戻せなかった。$DB の $TREN を手で確認・後始末すること）"
    fi
  else
    run n22-rename-ok "ALTER TABLE $T RENAME TO $TREN" || true
    if succeeded n22-rename-ok; then
      # OK Context 側で（#43 の実測に反して）リネームが実際に成功していたら、
      # 後始末のために戻しておく。
      run n22-rename-ok-back "ALTER TABLE $TREN RENAME TO $T" || true
    fi
  fi
else
  skip n22-rename-nc "p1（$T の準備）が失敗したため未測定"
fi

# --- 後始末（必須。OK Context の DROP ... IF EXISTS で全部消す） -----------------------

run z-cleanup-drop-t "DROP TABLE IF EXISTS $DB.$T"
run z-cleanup-drop-tren "DROP TABLE IF EXISTS $DB.$TREN"
run z-cleanup-drop-tp "DROP TABLE IF EXISTS $DB.$TP"
run z-cleanup-drop-ti "DROP TABLE IF EXISTS $DB.$TI"
run z-cleanup-drop-ext "DROP TABLE IF EXISTS $DB.$EXT"
run z-cleanup-drop-ice2 "DROP TABLE IF EXISTS $DB.$ICE2"
run z-cleanup-drop-v "DROP VIEW IF EXISTS $DB.$VW"
run z-cleanup-drop-v2 "DROP VIEW IF EXISTS $DB.$VW2"
run z-cleanup-drop-v3 "DROP VIEW IF EXISTS $DB.$VW3"
run z-cleanup-drop-db "DROP DATABASE IF EXISTS $NEWDB"
run z-cleanup-drop-sch "DROP SCHEMA IF EXISTS $NEWSCH"

# --- summary -----------------------------------------------------------------

ALL_LABELS="probe-show-tables probe-show-databases p1-setup-t p2-setup-tp p3-setup-ti p4-setup-v"
ALL_LABELS="$ALL_LABELS n1-insert1-nc n1-insert1-ok n1-verify"
ALL_LABELS="$ALL_LABELS n2-insert2-nc n2-insert2-ok n2-verify"
ALL_LABELS="$ALL_LABELS n3-insertvalues-nc n3-insertvalues-ok n3-verify"
ALL_LABELS="$ALL_LABELS n4-extddl-nc n4-extddl-ok n4-verify"
ALL_LABELS="$ALL_LABELS n5-icecreate-nc n5-icecreate-ok n5-verify"
ALL_LABELS="$ALL_LABELS n6-altercols-nc n6-altercols-ok n6-verify"
ALL_LABELS="$ALL_LABELS n7-altertblprops-nc n7-altertblprops-ok n7-verify"
ALL_LABELS="$ALL_LABELS n8-addpartition-nc n8-addpartition-ok n8-verify"
ALL_LABELS="$ALL_LABELS n9-showpartitions-nc n9-showpartitions-ok"
ALL_LABELS="$ALL_LABELS n10-droppartition-nc n10-droppartition-ok n10-verify"
ALL_LABELS="$ALL_LABELS n11-msck-nc n11-msck-ok n11-verify"
ALL_LABELS="$ALL_LABELS n12-createview-noref-nc n12-createview-noref-ok n12-verify"
ALL_LABELS="$ALL_LABELS n13-createview-ref-nc n13-createview-ref-ok n13-verify"
ALL_LABELS="$ALL_LABELS n14-showcreateview-nc n14-showcreateview-ok"
ALL_LABELS="$ALL_LABELS n15-describeview-nc n15-describeview-ok"
ALL_LABELS="$ALL_LABELS n23-showcolumnsin-nc n23-showcolumnsin-ok"
ALL_LABELS="$ALL_LABELS n16a-dropview-v2-nc n16a-dropview-v2-ok n16a-verify"
ALL_LABELS="$ALL_LABELS n16b-dropview-v-nc n16b-dropview-v-ok n16b-verify"
ALL_LABELS="$ALL_LABELS n17a-createdb-nc n17a-createdb-ok n17a-create-verify"
ALL_LABELS="$ALL_LABELS n17a-dropdb-nc n17a-dropdb-ok n17a-drop-verify"
ALL_LABELS="$ALL_LABELS n17b-createschema-nc n17b-createschema-ok n17b-create-verify"
ALL_LABELS="$ALL_LABELS n17b-dropschema-nc n17b-dropschema-ok n17b-drop-verify"
ALL_LABELS="$ALL_LABELS n18-showfunctions-nc n18-showfunctions-ok"
ALL_LABELS="$ALL_LABELS n19a-delete-nc n19a-delete-ok"
ALL_LABELS="$ALL_LABELS n19b-update-nc n19b-update-ok"
ALL_LABELS="$ALL_LABELS n19c-merge-nc n19c-merge-ok"
ALL_LABELS="$ALL_LABELS n19d-optimize-nc n19d-optimize-ok"
ALL_LABELS="$ALL_LABELS n19e-vacuum-nc n19e-vacuum-ok"
ALL_LABELS="$ALL_LABELS n19-group-verify"
ALL_LABELS="$ALL_LABELS n19f-altercols-nc n19f-altercols-ok n19f-verify"
ALL_LABELS="$ALL_LABELS n20a-tblprops-nc n20a-tblprops-ok"
ALL_LABELS="$ALL_LABELS n20b-showcreate-nc n20b-showcreate-ok"
ALL_LABELS="$ALL_LABELS n21-dropext-nc n21-dropext-ok n21-verify"
ALL_LABELS="$ALL_LABELS n22-rename-nc n22-renameback n22-rename-ok n22-rename-ok-back"
ALL_LABELS="$ALL_LABELS z-cleanup-drop-t z-cleanup-drop-tren z-cleanup-drop-tp z-cleanup-drop-ti"
ALL_LABELS="$ALL_LABELS z-cleanup-drop-ext z-cleanup-drop-ice2 z-cleanup-drop-v z-cleanup-drop-v2"
ALL_LABELS="$ALL_LABELS z-cleanup-drop-v3 z-cleanup-drop-db z-cleanup-drop-sch"

write_summary_txt() {
  local txt="$RUN_DIR/summary.txt"
  {
    echo "# issue #217: StartQueryExecution の QueryExecutionContext.Catalog に実在しない"
    echo "#             カタログ名を渡したとき、本物の Athena が #214 で測っていない文の"
    echo "#             種類（INSERT・ALTER TABLE の亜種・CREATE VIEW・DROP VIEW・"
    echo "#             CREATE/DROP DATABASE/SCHEMA・Iceberg の DML・RENAME TO など）を"
    echo "#             どう解決するかを実測。DDL・DML を含む実測であることに注意"
    echo "#             （下の一覧参照）。実測値はコンソール設定（ワークグループ等）や"
    echo "#             Athena エンジンのバージョンで変わりうる"
    echo "# 実行日時: $(date -Iseconds)"
    echo "# 背景（#214、docs/dev/measurements/statements.md）: 同じ Context で"
    echo "#   DESCRIBE・SHOW 系・DROP TABLE は既定のカタログで成功、表を読む SELECT・"
    echo "#   EXPLAIN は CATALOG_NOT_FOUND（1006）、CTAS は 1300 の"
    echo "#   NOT_FOUND: Session property catalog does not exist で失敗。この実測はその残り"
    echo "#   （INSERT・ALTER TABLE の亜種・CTAS でない CREATE TABLE・CREATE VIEW・"
    echo "#   SHOW PARTITIONS・MSCK REPAIR TABLE・DROP VIEW・CREATE/DROP DATABASE/SCHEMA・"
    echo "#   Iceberg の DML・保守文・RENAME TO・SHOW COLUMNS IN）を測る"
    echo "# StartQueryExecution の見込み本数: 前提（準備の 4 テーブル/ビューが作れる）が"
    echo "#   満たされたとき、おおよそ 72〜84 本（結果次第で変動）。詳細はスクリプト先頭の"
    echo "#   コメントを参照。"
    echo "#   実測値（このラウンドで実際に呼んだ回数、再試行込み）: $(wc -l < "$START_CALL_FILE" | tr -d ' ')"
    echo "# 課金: すべて 1〜4 行程度の表への CTAS・INSERT・DML と、スキャンを伴わない"
    echo "#   メタデータの文（DESCRIBE・SHOW 系・ALTER・DROP・CREATE DATABASE/SCHEMA・"
    echo "#   MSCK・OPTIMIZE・VACUUM）。Athena の最小課金 × クエリ数の見込み。"
    echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
    echo
    echo "## 投げた文（DB 名・テーブル名・Context は伏せる。実名は各 <label>.sql・<label>.context.txt を参照）"
    for label in $ALL_LABELS; do
      if [ -s "$RUN_DIR/$label.sql" ]; then
        local ctx_shown="-"
        if [ -s "$RUN_DIR/$label.context.txt" ]; then
          ctx_shown=$(sanitize "$(hide "$(cat "$RUN_DIR/$label.context.txt")")")
        fi
        echo "- $label: $(sanitize "$(hide "$(cat "$RUN_DIR/$label.sql")")")（Context: $ctx_shown）"
      fi
    done
    echo
    echo "## 項目ごとの結果（測定した文・裏取り・未測定のすべてを含む）"
    echo "#   qec_catalog/qec_database  GetQueryExecution が返した QueryExecutionContext"
    echo "#                             （送った Context と違えば、それが解決の証拠になる）"
    echo "#   start_message/start_athena_error_code  開始時に弾かれた項目の Message・AthenaErrorCode"
    echo "#   error_category/error_type/error_message  開始できて FAILED になった項目の AthenaError"
    echo "#   reason_line  StateChangeReason の 1 行目（無ければ -）"
    echo "#   state=INFO の行は裏取りの結果（note に件数・有無・行数）、SKIPPED は前提が"
    echo "#   崩れたための未測定"
    python3 - "$SUMMARY" <<'PYEOF'
import csv, sys
with open(sys.argv[1], newline="") as f:
    for row in csv.DictReader(f, delimiter="\t"):
        print(
            "- {label}: state={state} statement_type={statement_type}/{substatement_type} "
            "qec={qec_catalog}/{qec_database} "
            "start_message={start_message} start_athena_error_code={start_athena_error_code} "
            "error={error_category}/{error_type}/{error_message} "
            "reason={reason_line} note={note}".format(**row)
        )
PYEOF
    echo
    echo "## 開始できなかった項目の文言（実名は伏せる）"
    for label in $ALL_LABELS; do
      if [ -s "$RUN_DIR/$label.start.err" ]; then
        echo "### $label"
        hide "$(cat "$RUN_DIR/$label.start.err")"
        echo
      fi
    done
    echo
    echo "## 失敗した項目の理由（実名は伏せる。伏せ漏れが無いか貼る前に確認すること）"
    for label in $ALL_LABELS; do
      if [ -s "$RUN_DIR/$label.reason.txt" ] && ! grep -q "^State: SUCCEEDED" "$RUN_DIR/$label.reason.txt"; then
        echo "### $label"
        hide "$(cat "$RUN_DIR/$label.reason.txt")"
        echo
        echo
      fi
    done
    echo
    echo "## 消えないかもしれない S3 のデータ（DROP TABLE では消えない可能性がある。ここだけ、"
    echo "## 手で消すための参考として実名のまま出す。aws s3 rm はしていない）"
    echo "- $T（Hive、場所を指定していないので既定の場所: ${OUTPUT}tables/${P1_QID:-<不明。準備が失敗した>}/）"
    echo "- $TP（Hive、場所を指定していないので既定の場所: ${OUTPUT}tables/${P2_QID:-<不明。準備が失敗した>}/）"
    echo "- $EXT（Hive の外部表）: $EXT_LOC"
    echo "- $ICE2（is_external を指定していない Iceberg 風の表。DROP TABLE でデータが"
    echo "  消えるかどうかは未確認）: $ICE2_LOC"
    echo "- $TI（Iceberg、is_external=false の CTAS）は DROP TABLE でデータも消えるはず"
    echo "  （#26 などの既測どおりなら）: $ICE_LOC"
  } > "$txt"
  echo "$txt"
}

SUMMARY_TXT=$(write_summary_txt)

echo
echo "完了しました。"
echo "機械可読な一覧: $SUMMARY"
echo "そのまま貼れる整形済みの一覧: $SUMMARY_TXT（末尾の S3 データの節だけ実名を含む）"
echo "中身のファイルは $RUN_DIR にあります。リポジトリには入れないでください。"
echo "<label>.sql・<label>.context.txt・<label>.reason.txt・<label>.start.err・<label>.rows.txt は"
echo "実名（DB 名・テーブル名）を含みうるので、summary.txt 以外を貼るときは中身を確かめてください。"
