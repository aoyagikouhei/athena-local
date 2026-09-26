#!/usr/bin/env bash
# issue #244 で作成。
# 本物の Athena で、SHOW CREATE TABLE・ALTER TABLE・MSCK REPAIR TABLE・DESCRIBE の
# キーワードの間や直後にブロックコメント（/* c */）を挟んだ SQL がどう扱われるか
# （ParseException になるか、成功するか、位置・綴りでどう変わるか）を実測する。
#
# 出どころ（.claude/issue-notes/244.md、issue #244 本文）:
#   #242（DESCRIBE の直後のブロックコメントを本物どおり FAILED にする）の設計時に見つかった、
#   同じ形の失敗が SHOW CREATE TABLE・ALTER TABLE・MSCK REPAIR TABLE にもあるという事実
#   （docs/caveats.md の SQL dialect の項）を、位置・綴り・実在する表の形式（Hive/Iceberg/
#   ビュー/無い表）まで広げて実測する。過去の実測（#17・#27・#52・#146）は無い表への
#   ALTER と、SHOW CREATE TABLE の一部の形しかカバーしていない。
#
# 使い方:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db bash tools/measure/block-comment-parse-error.sh
#   （資格情報はホストのシェルで AWS_ACCESS_KEY_ID などを export してから。または ~/.aws/credentials）
#   DB を省略するか実在しなければ、SHOW DATABASES の候補の 1 件目を自動で使う。
#   ラウンド 2（RENAME・DROP COLUMN・ADD COLUMNS の先頭寄りの位置、MSCK REPAIR TABLE の
#   I・V・無い表、DESCRIBE の続き、空白 2 つ・タブ・複数改行・コメントの中身の違い。
#   下の「項目（ROUND=2）」）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=2 bash tools/measure/block-comment-parse-error.sh
#
# 必要な環境変数:
#   OUTPUT    結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける）。
#
# 任意の環境変数:
#   DB           データベース名。省略するか実在しなければ、SHOW DATABASES の候補の 1 件目を使う
#                （$RUN_DIR/available-databases.bytes に一覧を残す。実名を含む）。
#   ROUND        既定 1（A・S・R・D 群）。2 にすると下の「項目（ROUND=2）」だけを流す
#                （フィクスチャの作成・形式の裏取り・後始末・衝突確認・preflight・マスク・
#                summary の仕組みは ROUND=1 と共通）。
#   CATALOG      既定 AwsDataCatalog
#   REGION       既定 ap-northeast-1
#   OUT_DIR      既定 ${DEV_HOST_HOME:-$HOME}/athena-block-comment-parse-error-measurements
#                （実名が入るのでリポジトリの外に出す。toolbox では DEV_HOST_HOME がホストの
#                ホームを指す。#129）
#   POLL_TIMEOUT 終端状態を待つ上限（秒）。既定 180
#   RETRY_MAX    名前解決・接続など一時的な失敗を再試行する回数の上限。既定 4
#   RETRY_DELAY  再試行の間隔（秒）。既定 5
#
# ** このスクリプトが本物に対して行う DDL（破壊的な操作） **
#   最初に SHOW TABLES で athena_local_probe_244_* という名前が db に既に無いことを確かめ、
#   1 件でもあれば何も作らずに止まる。確かめた後、次の 3 つを作る:
#     - athena_local_probe_244_h（Hive の EXTERNAL TABLE。PARTITIONED BY (p string)）
#     - athena_local_probe_244_i（Iceberg。TBLPROPERTIES で table_type='ICEBERG'）
#     - athena_local_probe_244_v（ビュー。SELECT 1 AS n）
#   作った直後に SHOW CREATE TABLE で形式を裏取りする（DROP 後は呼べないため）。
#   A 群（最大 17 回）で H・I に ADD COLUMNS・ADD/DROP PARTITION・SET TBLPROPERTIES・
#   DROP COLUMN を投げる（無い表 athena_local_probe_244_missing は作らない。存在しないままで
#   使う）。最後に 3 つとも DROP する（正常終了なら本編の中で。異常終了時は trap がベストエフォートで
#   もう一度 DROP TABLE IF EXISTS / DROP VIEW IF EXISTS を投げる）。
#   Iceberg 表 I は location を $OUTPUT の下に置いてあり、DROP でデータも消える。Hive 表 H は
#   EXTERNAL なので DROP TABLE では S3 の場所自体は残るが、行を入れていないので中身は無い。
#   スキャンする SELECT は一切投げない（S/R/D 群は SHOW / MSCK REPAIR / DESCRIBE で、いずれも
#   メタデータだけを見る）。
#   ROUND=2 は同じ 3 つのフィクスチャを使い、ALTER TABLE ... RENAME TO を H・V にも投げる
#   （n1・n2）。RENAME が成功すると対象は athena_local_probe_244_h_ren /
#   athena_local_probe_244_v_ren という名前になる。後始末は元の名前と _ren の両方に
#   DROP TABLE/VIEW IF EXISTS を投げるので、どちらの名前で残っていても消える
#   （athena_local_probe_244_i_ren も念のため同様に消す。本ラウンドの項目には I の RENAME は無い）。
#
# 課金について: メタデータだけの操作（DDL は 0 行、SHOW/DESCRIBE/MSCK は読み取りのみ）。
# Athena の最小課金 × クエリ数の見込み。StartQueryExecution を呼んだ回数は summary.txt の
# 冒頭に実測値で出す（list-work-groups など Athena のクエリではない API 呼び出しは含めない。
# trap で発動する後始末のベストエフォート呼び出しも、正常終了で本編の DROP が全部済んでいれば
# 呼ばれないため含めない）。
#
# 項目（ROUND=1、既定。A・S・R・D の 4 群。<H>/<I>/<V> はフィクスチャの修飾名
# <DB>.athena_local_probe_244_h などで、<M> は作らない無い表。改行を含む文は本物の改行文字を送る）:
#   A. ALTER TABLE（コメント無しの対照と対で。a17 は I の列を消すので、I を使うほかの項目
#      （a3・s6〜s9・r10・d1）の後、後始末の直前に流す）
#     a1  ALTER TABLE <H> ADD COLUMNS (c1 int)                          対照（コメント無し）
#     a2  ALTER /* c */ TABLE <H> ADD COLUMNS (c2 int)
#     a3  ALTER /* c */ TABLE <I> ADD COLUMNS (c3 int)                  Iceberg。過去は SUCCEEDED
#     a4  ALTER /* c */ TABLE <M> ADD COLUMNS (c int)                   無い表。過去は ParseException line 1:0
#     a5  alter /* c */ table <M> add columns (c int)                  小文字
#     a6  ALTER  /* c */ TABLE <M> ADD COLUMNS (c int)                  空白 2 つ
#     a7  ALTER\n/* c */ TABLE <M> ADD COLUMNS (c int)                  改行
#     a8  ALTER /* c */ TABLE <H> ADD PARTITION (p='x')
#     a9  ALTER /* c */ TABLE <H> DROP PARTITION (p='x')
#     a10 ALTER /* c */ TABLE <H> SET TBLPROPERTIES ('k'='v')
#     a11 ALTER /* c */ TABLE <M> RENAME TO <DB>.athena_local_probe_244_renamed
#     a12 /* c */ ALTER TABLE <M> ADD COLUMNS (c int)                   先頭のコメント
#     a13 ALTER TABLE /* c */ <M> ADD COLUMNS (c int)                   TABLE の後
#     a14 ALTER /* c */ TABLE <V> ADD COLUMNS (c int)                   ビュー
#     a15 ALTER /* c */ TABLE <M> DROP COLUMN c                        無い表（コーディネーター追加）
#     a16 ALTER /* c */ TABLE <H> DROP COLUMN n                        Hive（コーディネーター追加）
#     a17 ALTER /* c */ TABLE <I> DROP COLUMN n                        Iceberg（コーディネーター追加。
#         実行は D 群の後、後始末の直前）
#   S. SHOW CREATE TABLE
#     s1  SHOW CREATE TABLE <H>                                        対照
#     s2  /* c */ SHOW CREATE TABLE <H>
#     s3  SHOW /* c */ CREATE TABLE <H>
#     s4  SHOW CREATE /* c */ TABLE <H>
#     s5  SHOW CREATE TABLE /* c */ <H>
#     s6〜s9   s2〜s5 と同じ 4 形を <I> に
#     s10〜s12 s2〜s4 の 3 形を <M> に
#     s13 SHOW CREATE /* c */ TABLE <V>                                ビュー
#     s14 show /* c */ create table <H>                                小文字
#     s15 show create /* c */ table <H>                                小文字
#     s16 SHOW  /* c */ CREATE TABLE <H>                               空白 2 つ
#     s17 SHOW CREATE  /* c */ TABLE <H>                               空白 2 つ
#     s18 SHOW\n/* c */ CREATE TABLE <H>                               改行
#     s19 SHOW CREATE\n/* c */ TABLE <H>                                改行
#     s20 /* abc */ SHOW CREATE TABLE <H>
#     s21 /**/ SHOW CREATE TABLE <H>
#     s22 /*c*/ SHOW CREATE TABLE <H>
#     s23 /* a b */ SHOW CREATE TABLE <H>
#     s24 /* , */ SHOW CREATE TABLE <H>
#     s25 -- x\n/* c */ SHOW CREATE TABLE <H>                          先頭に行コメント
#     s26 /* c */\nSHOW CREATE TABLE <H>
#     s27 SHOW /* a */ /* b */ CREATE TABLE <H>                        コメント 2 つ
#   R. MSCK REPAIR TABLE
#     r1  MSCK REPAIR TABLE <H>                                        対照
#     r2  MSCK REPAIR /* c */ TABLE <H>
#     r3  MSCK /* c */ REPAIR TABLE <H>
#     r4  /* c */ MSCK REPAIR TABLE <H>
#     r5  MSCK REPAIR TABLE /* c */ <H>
#     r6  msck repair /* c */ table <H>                                小文字
#     r7  MSCK REPAIR  /* c */ TABLE <H>                               空白 2 つ
#     r8  MSCK REPAIR\n/* c */ TABLE <H>                               改行
#     r9  MSCK REPAIR /* c */ TABLE <M>                                無い表
#     r10 MSCK REPAIR /* c */ TABLE <I>                                Iceberg
#   D. DESCRIBE（#242 の周辺の未実測）
#     d1  DESCRIBE /* c */ <I>                                         Iceberg
#     d2  describe /* c */ <H>                                         小文字
#     d3  DESC /* c */ <H>
#     d4  /* c */ DESCRIBE <H>
#     d5  DESCRIBE /* c */ <V>                                         ビュー
#     d6  DESCRIBE -- c\n<H>                                           行コメント
#
# 項目（ROUND=2。RENAME・DROP COLUMN・ADD COLUMNS の先頭寄りの位置、MSCK REPAIR TABLE の
# I・V・無い表、DESCRIBE の続き、空白 2 つ・タブ・複数改行・コメントの中身の違い。
# n1・n2（RENAME）が成功すると H・V は <名前>_ren に移る。後始末は両方の名前に投げる）:
#   n1  ALTER /* c */ TABLE <H> RENAME TO <DB>.athena_local_probe_244_h_ren（H を使う
#       ほかの全項目の後、後始末の直前に流す）
#   n2  ALTER /* c */ TABLE <V> RENAME TO <DB>.athena_local_probe_244_v_ren（V を使う
#       ほかの項目（n8・m5・m6・d9・d10）の後に流す）
#   n3  /* c */ ALTER TABLE <M> RENAME TO <DB>.athena_local_probe_244_renamed
#   n4  ALTER TABLE /* c */ <M> RENAME TO <DB>.athena_local_probe_244_renamed
#   n5  /* c */ ALTER TABLE <H> DROP COLUMN n
#   n6  ALTER TABLE /* c */ <H> DROP COLUMN n
#   n7  alter /* c */ table <H> drop column n                            小文字
#   n8  ALTER /* c */ TABLE <V> DROP COLUMN n
#   n9  ALTER  /* c */ TABLE <M> DROP COLUMN c                           空白 2 つ
#   n10 /* c */ ALTER TABLE <H> ADD COLUMNS (c6 int)
#   n11 ALTER TABLE /* c */ <H> ADD COLUMNS (c7 int)
#   n12 /* c */ ALTER TABLE <I> ADD COLUMNS (c8 int)                     m1〜m4・d7・d8 の後
#   n13 ALTER TABLE /* c */ <I> ADD COLUMNS (c9 int)                     m1〜m4・d7・d8 の後
#   m1  MSCK REPAIR TABLE <I>                                            対照（コメント無し）
#   m2  /* c */ MSCK REPAIR TABLE <I>
#   m3  MSCK /* c */ REPAIR TABLE <I>
#   m4  MSCK REPAIR TABLE /* c */ <I>
#   m5  MSCK REPAIR TABLE <V>                                            対照（コメント無し）
#   m6  MSCK REPAIR /* c */ TABLE <V>
#   m7  MSCK REPAIR TABLE <M>                                            対照（コメント無し）
#   d7  /* c */ DESCRIBE <I>
#   d8  DESC /* c */ <I>
#   d9  /* c */ DESCRIBE <V>
#   d10 SHOW CREATE TABLE /* c */ <V>
#   p1  SHOW  CREATE /* c */ TABLE <H>                                   空白 2 つ
#   p2  SHOW\t/* c */ CREATE TABLE <H>                                   タブ
#   p3  MSCK  REPAIR /* c */ TABLE <H>                                   空白 2 つ
#   p4  SHOW CREATE TABLE  /* c */ <H>                                   空白 2 つ
#   p5  SHOW CREATE\n  /* c */ TABLE <H>                                 改行 + 空白 2 つ
#   p6  SHOW\n\n/* c */ CREATE TABLE <H>                                 改行 2 つ
#   p7     /* c */ SHOW CREATE TABLE <H>                                 先頭に空白 3 つ
#   p8  SHOW  CREATE  TABLE  /* c */ <H>                                 空白 2 つ × 3
#   p9  ALTER TABLE  /* c */ <M> ADD COLUMNS (c int)                     空白 2 つ
#   p10 ALTER  TABLE /* c */ <M> ADD COLUMNS (c int)                     空白 2 つ
#   p11 SHOW\t\t/* c */ CREATE TABLE <H>                                 タブ 2 つ
#   c1  /* 1 */ SHOW CREATE TABLE <H>
#   c2  /* 'x' */ SHOW CREATE TABLE <H>
#   c3  /* a.b */ SHOW CREATE TABLE <H>
#   c4  /* _a1 */ SHOW CREATE TABLE <H>
#   c5  /*+ x */ SHOW CREATE TABLE <H>
#   c6  /* あ */ SHOW CREATE TABLE <H>                                   非 ASCII
#   c7  /* 1a */ SHOW CREATE TABLE <H>
#   c8  /*\nc */ SHOW CREATE TABLE <H>                                   コメントの中に改行
#   c9  /* "q" */ SHOW CREATE TABLE <H>
#   c10 /* ) */ SHOW CREATE TABLE <H>
#   c11 SHOW CREATE TABLE /* 1 */ <H>
#   c12 /* 1.5 */ SHOW CREATE TABLE <H>
#   c13 /* a-b */ SHOW CREATE TABLE <H>
#
# ** SQL に改行を含める書き方の注意 **
# 「ALTER\n/* c */ TABLE ...」のような文は、シェルで実際の改行文字（0x0a）にしてから渡さないと、
# 「\」「n」という 2 文字が入った 1 行の文字列になり、まったく別の測定になる。そのため bash の
# ANSI-C quoting（$'...'）を使う。$'...' は変数展開をしないので、$DB を埋め込む行は
# $'ALTER\n'"/* c */ TABLE $DB.$MISSING ..." のように断片を隣り合わせて連結する。
#
# S3 からの取得は `aws s3 cp <src> -` で標準出力に流し、リダイレクトはこのシェルが行う。
# aws が Docker のラッパだと、コンテナにマウントされるのは実行時のカレントディレクトリだけで、
# 絶対パスを渡すとコンテナの中に書かれて消える。しかも終了コードは 0 になる。`--debug` は
# 使わない（生ログに署名やアクセスキーが残るため）。
#
# 実行系（aws・python3）は command -v（PATH にあるか）だけでなく、実際に使うオプションで
# 呼べるかを preflight で試す（tools/measure/content-type-rules.sh の「実行系の能力を実際に
# 試して確かめる」と同じ考え方）。名前解決・接続の一時的な失敗は RETRY_MAX 回まで再試行し、
# 試行回数を summary の note に残す。
#
# 項目は独立して失敗しうる。前提のフィクスチャ（H/I/V）が作れなかった項目だけを skip にして
# 未測定にし、全体は止めない（run_req）。DB が実在しない・指定が無いときも、SHOW DATABASES の
# 候補の 1 件目を自動で使って続ける（止まるのは、その候補でも SHOW TABLES が通らない、または
# SHOW DATABASES 自体が通らないとき）。
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く（リポジトリの外）。
#
# 項目ごとに次を保存する（取れたものだけ）。
#   <label>.sql                投げた SQL そのもの（**DB 名を含む**）
#   <label>.start.err          StartQueryExecution の標準エラー（開始時に弾かれた証拠。AWS CLI の
#                              出力そのまま。署名・Authorization ヘッダ・アクセスキーは --debug を
#                              使わないので載らない）
#   <label>.execution.json     GetQueryExecution の応答そのもの
#   <label>.execution.err      GetQueryExecution の標準エラー
#   <label>.reason.txt         State / StateChangeReason / AthenaError の全文（**実名を含みうる**）
#   <label>.ls.txt             OutputLocation と .metadata の aws s3 ls の結果
#   <label>.bytes / .od.txt    結果ファイル本体の中身と、バイト単位で見たもの（無ければ作らない）
#   <label>.cp.err             本体を取れなかったときの stderr（= 本体が無いことの証拠）
#   <label>.metadata.bytes / .metadata.od.txt  .metadata の中身と 16 進（無ければ作らない）
#   <label>.metadata.cp.err    .metadata を取れなかったときの stderr（= 無いことの証拠）
#   <label>.head.json / .metadata.head.json    head-object の応答（Content-Type の出どころ）
#   available-databases.bytes  DB が実在しなかった／指定が無かったときの候補の一覧（**実名**）
#
# 最後に summary.tsv（機械可読）と summary.txt（実名をマスクした、そのまま貼れる形）を作る。
# summary.txt 以外のファイルにはデータベース名・テーブル名が入りうる。貼るときは中身を確かめること。
# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更や、コンソールでの設定変更で
# 変わりうる（工場出荷時の既定とは限らない）。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください（末尾に / を付ける）}"
DB=${DB:-}
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_DIR=${OUT_DIR:-${DEV_HOST_HOME:-$HOME}/athena-block-comment-parse-error-measurements}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}
ROUND=${ROUND:-1}
case "$ROUND" in
  1 | 2) ;;
  *)
    echo "ROUND には 1・2 のどちらかを指定してください（既定 1）" >&2
    exit 1
    ;;
esac

PREFIX=athena_local_probe_244
H="${PREFIX}_h"
I="${PREFIX}_i"
V="${PREFIX}_v"
MISSING="${PREFIX}_missing"
RENAMED="${PREFIX}_renamed"
# ROUND=2 の n1・n2（RENAME）が成功したときの行き先。後始末で両方の名前に
# DROP TABLE/VIEW IF EXISTS を投げる（IF EXISTS なので無い方は無害）。
H_REN="${H}_ren"
I_REN="${I}_ren"
V_REN="${V}_ren"
LOC_H="${OUTPUT}tables-probe-244-h/"
LOC_I="${OUTPUT}tables-probe-244-i/"

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\tstatement_type\tsubstatement_type\tloc_tail\terror_category\terror_type\tstart_message\tstart_athena_error_code\tbody_bytes\tmetadata_present\tnote\n' > "$SUMMARY"
echo "出力先: $RUN_DIR"

# StartQueryExecution を実際に呼んだ回数（再試行込み）。run/determine_table_format は
# コマンド置換（id=$(...)）で start_query_retry を呼ぶのでサブシェルになり、変数の加算は
# 親に伝わらない。1 回ごとにファイルへ 1 行積み、最後に行数を数える。
START_CALL_FILE="$RUN_DIR/.start-calls"
: > "$START_CALL_FILE"

# フィクスチャ（H・I・V）の作成に着手したかどうか。trap での後始末に使う。
FIXTURES_ATTEMPTED=0
H_OK=0
I_OK=0
V_OK=0

# QueryExecutionContext。DB が決まった後に設定する（既定は preflight の間だけ Catalog のみ）。
QE_CONTEXT="Catalog=$CATALOG"

# 生ログの中間ファイルは、途中で止めても残らないよう trap で消す。フィクスチャ作成に
# 着手していたら、ベストエフォートで DROP も投げる（本編の後始末でも消すので、これは
# 異常終了時の保険。正常終了で 3 つとも消えていれば、この保険は呼ばない）。
cleanup() {
  rm -f "$RUN_DIR"/.tmp-*
  if [ "$FIXTURES_ATTEMPTED" = 1 ]; then
    aws athena start-query-execution --region "$REGION" \
      --query-string "DROP VIEW IF EXISTS $DB.$V" \
      --query-execution-context "Catalog=$CATALOG,Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
    aws athena start-query-execution --region "$REGION" \
      --query-string "DROP TABLE IF EXISTS $DB.$I" \
      --query-execution-context "Catalog=$CATALOG,Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
    aws athena start-query-execution --region "$REGION" \
      --query-string "DROP TABLE IF EXISTS $DB.$H" \
      --query-execution-context "Catalog=$CATALOG,Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
    if [ "$ROUND" = 2 ]; then
      # ROUND=2 の n1・n2（RENAME）が成功していると、H・V は元の名前ではなく
      # <名前>_ren に残っている。IF EXISTS なので両方の名前に投げて無害に消す。
      aws athena start-query-execution --region "$REGION" \
        --query-string "DROP VIEW IF EXISTS $DB.$V_REN" \
        --query-execution-context "Catalog=$CATALOG,Database=$DB" \
        --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
      aws athena start-query-execution --region "$REGION" \
        --query-string "DROP TABLE IF EXISTS $DB.$I_REN" \
        --query-execution-context "Catalog=$CATALOG,Database=$DB" \
        --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
      aws athena start-query-execution --region "$REGION" \
        --query-string "DROP TABLE IF EXISTS $DB.$H_REN" \
        --query-execution-context "Catalog=$CATALOG,Database=$DB" \
        --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup EXIT

# --- 実名のマスク ----------------------------------------------------------------
# 実名（DB 名・出力先・バケット名・アカウント ID）を置換して隠す。長い実名から先に
# 置き換える（DB 名がバケット名の一部を含む、などの入れ子で短い方を先に潰すと一部が
# 残ることがある。#221・#224 の教訓）。
OUTPUT_BUCKET=${OUTPUT#s3://}
OUTPUT_BUCKET=${OUTPUT_BUCKET%%/*}
hide_pairs() {
  local value mark
  while IFS=$'\t' read -r value mark; do
    [ -n "$value" ] && printf '%s\t%s\t%s\n' "${#value}" "$value" "$mark"
  done <<EOF
$DB	<DB>
$OUTPUT	<OUTPUT>
$OUTPUT_BUCKET	<BUCKET>
EOF
}
hide() {
  local s=$1 value mark
  while IFS=$'\t' read -r _ value mark; do
    s=${s//"$value"/$mark}
  done < <(hide_pairs | sort -t $'\t' -k1,1nr)
  printf '%s' "$s" | sed -E 's/(^|[^0-9])[0-9]{12}([^0-9]|$)/\1<ACCOUNT_ID>\2/g'
}

# 制御文字を落として短くする（改行も潰す）。note に入れる前に必ず通す。
sanitize() {
  printf '%s' "$1" | tr '\t\n\r' '   ' | cut -c1-300
}

# 制御文字（改行は残す）を落とし、実名を伏せたうえで長すぎれば頭だけにする。
# summary.txt の本体・StateChangeReason の全文表示に使う。
hide_multiline() {
  local f=$1 data
  [ -s "$f" ] || { echo "(空)"; return; }
  data=$(tr -d '\000-\010\013\014\016-\037' < "$f")
  data=$(hide "$data")
  if [ "${#data}" -gt 4000 ]; then
    printf '%s\n[...4000 文字を超えたので省略。全文は %s]\n' "${data:0:4000}" "$(basename "$f")"
  else
    printf '%s\n' "$data"
  fi
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

# 名前解決・接続などの一時的な失敗だけを見分ける。実際の API エラー（構文エラーや
# 権限エラーなど）はここに一致させない。一致しなければ 1 回で確定させる。
is_transient_error() {
  [ -s "$1" ] || return 1
  grep -qiE 'Could not connect|Connection aborted|Connection reset|EndpointConnectionError|Temporary failure in name resolution|Name or service not known|Network is unreachable|Read timed out|[Cc]onnect timeout|ConnectTimeoutError|ReadTimeoutError|SSLError|Broken pipe' "$1"
}

# S3 のオブジェクトを手元のファイルに取る。書き込むのはこのシェル（リダイレクト）。
fetch() {
  local src=$1 dest=$2 err=$3
  if aws s3 cp "$src" - --region "$REGION" > "$dest" 2> "$err"; then
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

# head-object の応答から ContentType を取る。
content_type_of() {
  [ -s "$1" ] || { echo "-"; return; }
  python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("ContentType") or "-")
except Exception:
    print("-")' "$1"
}

# execution.json から State / StateChangeReason / AthenaError の全文をファイルに書く。
# 実名を含みうるので、summary.tsv には使わずファイルにだけ残す（summary.txt では hide 済みで出す）。
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

# AthenaError の ErrorCategory / ErrorType / ErrorMessage をタブ区切りで返す（無ければ 3 つとも "-"）。
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

# execution.json から StatementType / SubstatementType / OutputLocation をタブ区切りで返す。
read_execution_fields() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))["QueryExecution"]
except Exception:
    print("-\t-\t")
    sys.exit(0)
print("%s\t%s\t%s" % (
    d.get("StatementType") or "-",
    d.get("SubstatementType") or "-",
    d.get("ResultConfiguration", {}).get("OutputLocation", "")))' "$1"
}

# OutputLocation の末尾の「形」だけを返す（クエリ ID は <id> に畳む。実名は含まない）。
loc_tail_of() {
  local loc=$1 id=$2
  [ -n "$loc" ] || { echo "-"; return; }
  case "$loc" in
    */tables/"$id") echo 'tables/<id>' ;;
    *"/$id.txt") echo '<id>.txt' ;;
    *"/$id.csv") echo '<id>.csv' ;;
    *"/$id") echo '<id>' ;;
    *) echo 'other' ;;
  esac
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

# start.err から Message と AthenaErrorCode を抜く（開始時に弾かれた StartQueryExecution の
# 標準エラーに、追加の呼び出し無しで両方出る。unquoted-ddl.sh の実測どおり）。
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

# StartQueryExecution を投げる。名前解決・接続系の失敗だけを RETRY_MAX 回まで再試行する
# （実際の SQL エラーは 1 回で確定させる）。試行回数は呼び出し側が read_attempts で読む
# （この関数はコマンド置換で呼ばれるので、変数に入れても親には伝わらない）。
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

# summary.tsv に 1 行積む。列の並びはヘッダと同じ 12 列で固定する。
emit_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$SUMMARY"
}

# 項目を未測定として summary に 1 行残す。全体を止めずに次へ進む。
skip() {
  local label=$1 note=$2
  echo "== $label: 未測定（$note）"
  emit_row "$label" "SKIPPED" - - - - - - - - - "$(sanitize "$note")"
}

# ラベルを指定して 1 文を実行し、終端状態まで待って State・StatementType・SubstatementType・
# OutputLocation の末尾・エラー・本体・.metadata を採取する。開始できなければ、
# AthenaErrorCode・Message をその場の start.err からそのまま抜く（追加の呼び出しはしない）。
# 成功したときだけ 0 を返す。
run() {
  local label=$1 sql=$2
  local id state stype sub loc loc_tail note
  local err_cat="-" err_type="-"
  local start_msg="-" start_code="-"
  local body_bytes="-" meta_present="no"

  printf '%s' "$sql" > "$RUN_DIR/$label.sql"
  id=$(start_query_retry "$label" "$sql")
  local attempts
  attempts=$(read_attempts "$label")

  if [ -z "${id:-}" ]; then
    start_msg=$(start_err_message "$RUN_DIR/$label.start.err")
    start_code=$(start_err_code "$RUN_DIR/$label.start.err")
    note="attempts=$attempts; $(first_err_line "$RUN_DIR/$label.start.err")"
    echo "== $label: 開始できませんでした（試行 $attempts 回）。AthenaErrorCode=$start_code"
    emit_row "$label" "START_FAILED" - - - - - "$start_msg" "$start_code" - - "$(sanitize "$note")"
    return 1
  fi

  state=$(poll_until_terminal "$id")

  aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.execution.json" 2> "$RUN_DIR/$label.execution.err"
  write_reason "$RUN_DIR/$label.execution.json" "$RUN_DIR/$label.reason.txt"
  IFS=$'\t' read -r stype sub loc < <(read_execution_fields "$RUN_DIR/$label.execution.json")
  loc_tail=$(loc_tail_of "$loc" "$id")

  case "$state" in
    FAILED | CANCELLED)
      # ErrorMessage は summary.tsv の列には持たず、reason.txt の全文（AthenaError）で
      # summary.txt に出す。ここでは ErrorCategory/ErrorType だけ受け取る。
      IFS=$'\t' read -r err_cat err_type _ < <(athena_error_fields_of "$RUN_DIR/$label.execution.json")
      ;;
  esac

  if [ -n "$loc" ]; then
    { echo "# ls $loc"; aws s3 ls "$loc" --region "$REGION"; echo "# rc=$?"
      echo "# ls $loc.metadata"; aws s3 ls "$loc.metadata" --region "$REGION"; echo "# rc=$?"
    } > "$RUN_DIR/$label.ls.txt" 2>&1

    if fetch "$loc" "$RUN_DIR/$label.bytes" "$RUN_DIR/$label.cp.err"; then
      od -An -tx1c "$RUN_DIR/$label.bytes" > "$RUN_DIR/$label.od.txt"
      body_bytes=$(wc -c < "$RUN_DIR/$label.bytes" | tr -d ' ')
    fi
    head_object "$loc" "$RUN_DIR/$label.head.json" "$RUN_DIR/$label.head.err" || true
    if fetch "$loc.metadata" "$RUN_DIR/$label.metadata.bytes" "$RUN_DIR/$label.metadata.cp.err"; then
      od -An -tx1c "$RUN_DIR/$label.metadata.bytes" > "$RUN_DIR/$label.metadata.od.txt"
      meta_present="yes"
    fi
    head_object "$loc.metadata" "$RUN_DIR/$label.metadata.head.json" "$RUN_DIR/$label.metadata.head.err" || true
  fi

  note="attempts=$attempts"
  echo "== $label  state=$state  type=$stype/$sub  loc_tail=$loc_tail  body=${body_bytes}B  metadata=$meta_present  error=$err_cat/$err_type"
  emit_row "$label" "$state" "$stype" "$sub" "$loc_tail" "$err_cat" "$err_type" "$start_msg" "$start_code" "$body_bytes" "$meta_present" "$(sanitize "$note")"
  [ "$state" = SUCCEEDED ]
}

# フィクスチャ（H/I/V）が揃っていなければ skip し、揃っていれば run を呼ぶ。
# $3 以降は必要なフィクスチャの識別子（H/I/V）。無い表 <M> やビュー無しの項目は要件無しで呼ぶ。
run_req() {
  local label=$1 sql=$2
  shift 2
  local req
  for req in "$@"; do
    case "$req" in
      H) [ "$H_OK" = 1 ] || { skip "$label" "H（Hive の EXTERNAL TABLE）を作れなかったため未測定"; return 1; } ;;
      I) [ "$I_OK" = 1 ] || { skip "$label" "I（Iceberg 表）を作れなかったため未測定"; return 1; } ;;
      V) [ "$V_OK" = 1 ] || { skip "$label" "V（ビュー）を作れなかったため未測定"; return 1; } ;;
    esac
  done
  run "$label" "$sql"
}

# QueryExecutionContext を $1 に差し替えて run を 1 回呼ぶ（preflight の DB 選定で使う）。
run_in_ctx() {
  local ctx=$1 label=$2 sql=$3 saved=$QE_CONTEXT rc
  QE_CONTEXT=$ctx
  run "$label" "$sql"
  rc=$?
  QE_CONTEXT=$saved
  return "$rc"
}

# SHOW CREATE TABLE でテーブルの形式を確かめ、hive / iceberg / unknown を標準出力に返す
# （呼び出し側は $(...) で受ける）。DROP される前（作った直後）にしか呼べない。
# tools/measure/alter-variants.sh の determine_table_format と同じやり方。
determine_table_format() {
  local suffix=$1 table_name=$2 id state loc fmt="unknown"
  local sql="SHOW CREATE TABLE $DB.$table_name"
  printf '%s' "$sql" > "$RUN_DIR/verify-$suffix.sql"
  id=$(start_query_retry "verify-$suffix" "$sql")
  if [ -n "${id:-}" ]; then
    state=$(poll_until_terminal "$id")
    aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
      > "$RUN_DIR/verify-$suffix.execution.json" 2>/dev/null
    IFS=$'\t' read -r _ _ loc < <(read_execution_fields "$RUN_DIR/verify-$suffix.execution.json")
    if [ "$state" = SUCCEEDED ] && [ -n "$loc" ] \
      && fetch "$loc" "$RUN_DIR/verify-$suffix.txt" "$RUN_DIR/verify-$suffix.err"; then
      if grep -qi "table_type'*=*'*iceberg" "$RUN_DIR/verify-$suffix.txt"; then
        fmt=iceberg
      else
        fmt=hive
      fi
    fi
  fi
  echo "== $table_name: table_format=$fmt（SHOW CREATE TABLE で確認）" >&2
  printf '%s' "$fmt"
}

# ============================================================================
# preflight 1: 実行系（aws・python3）の能力を実際に試して確かめる。
# command -v は PATH にあるかしか確かめないので、実際に使うオプションで呼んでみる
# （tools/measure/content-type-rules.sh と同じ考え方）。list-work-groups は Athena の
# クエリではない軽い読み取りで、DB を要らず課金も乗らない。
# ============================================================================

CAPS="$RUN_DIR/capabilities.txt"
{
  echo "# 実行環境の能力（$(date -Iseconds)）"
  echo "aws: $(command -v aws 2>/dev/null || echo '(見つからない)')"
  echo "python3: $(command -v python3 2>/dev/null || echo '(見つからない)')"
  echo "REGION: $REGION"
  echo "CATALOG: $CATALOG"
} > "$CAPS"

lwg_attempt=1
while :; do
  if aws athena list-work-groups --region "$REGION" --output json \
    > "$RUN_DIR/preflight-list-work-groups.json" 2> "$RUN_DIR/preflight-list-work-groups.err"; then
    rm -f "$RUN_DIR/preflight-list-work-groups.err"
    echo "athena list-work-groups: 通った（試行 $lwg_attempt 回）" >> "$CAPS"
    break
  fi
  if [ "$lwg_attempt" -ge "$RETRY_MAX" ] || ! is_transient_error "$RUN_DIR/preflight-list-work-groups.err"; then
    echo "athena list-work-groups: 通らなかった（試行 $lwg_attempt 回）" >> "$CAPS"
    [ -s "$RUN_DIR/preflight-list-work-groups.json" ] || rm -f "$RUN_DIR/preflight-list-work-groups.json"
    echo
    echo "aws athena list-work-groups が通りません（試行 $lwg_attempt 回）。"
    echo "aws コマンド・資格情報・REGION（$REGION）を確かめてください。理由: $(first_err_line "$RUN_DIR/preflight-list-work-groups.err")"
    echo "詳細: $RUN_DIR/preflight-list-work-groups.err"
    exit 1
  fi
  echo "== preflight: list-work-groups が一時的に失敗。${RETRY_DELAY} 秒後に再試行します（試行 $lwg_attempt/$RETRY_MAX）" >&2
  sleep "$RETRY_DELAY"
  lwg_attempt=$((lwg_attempt + 1))
done

if ! python3 -c 'import json, sys' > /dev/null 2> "$RUN_DIR/preflight-python.err"; then
  echo "python3: 使えない" >> "$CAPS"
  echo
  echo "python3 で json を読み込めません（$(first_err_line "$RUN_DIR/preflight-python.err")）。"
  exit 1
fi
rm -f "$RUN_DIR/preflight-python.err"
echo "python3: json を読める" >> "$CAPS"

# ============================================================================
# preflight 2: DB の選定（対象の自動選択）。DB が指定されていれば SHOW TABLES で
# 実在を確かめる。指定が無いか実在しなければ SHOW DATABASES の候補の 1 件目を使う。
# 続けて、athena_local_probe_244_* という名前が既に無いことを同じ SHOW TABLES の結果で
# 確かめる（衝突防止。1 件でもあれば何も作らずに止まる）。
# ============================================================================

LIST_OK=1
if [ -n "$DB" ]; then
  if run_in_ctx "Catalog=$CATALOG,Database=$DB" list-tables "SHOW TABLES"; then
    LIST_OK=0
  fi
fi

if [ "$LIST_OK" != 0 ]; then
  if [ -n "$DB" ]; then
    echo "指定された DB で SHOW TABLES が通りませんでした。理由: $RUN_DIR/list-tables.reason.txt"
  else
    echo "DB が指定されていません。"
  fi
  echo "SHOW DATABASES の候補から選びます。"
  if ! run_in_ctx "Catalog=$CATALOG" available-databases "SHOW DATABASES"; then
    echo
    echo "SHOW DATABASES も通りませんでした。資格情報・REGION（$REGION）・権限を確かめてください。"
    echo "理由: $RUN_DIR/available-databases.reason.txt（開始できなければ $RUN_DIR/available-databases.start.err）"
    exit 1
  fi
  if [ ! -s "$RUN_DIR/available-databases.bytes" ]; then
    echo
    echo "SHOW DATABASES は成功しましたが、候補の一覧を取得できませんでした（$RUN_DIR/available-databases.cp.err）。"
    exit 1
  fi
  DB=$(python3 -c '
import csv, sys
with open(sys.argv[1], newline="") as f:
    for row in csv.reader(f):
        if row and row[0]:
            print(row[0])
            break
' "$RUN_DIR/available-databases.bytes")
  if [ -z "$DB" ]; then
    echo
    echo "候補の一覧から DB 名を読めませんでした。$RUN_DIR/available-databases.bytes を確かめてください。"
    exit 1
  fi
  echo "候補の一覧の 1 件目を DB に使います（実名は端末には出しません。一覧: $RUN_DIR/available-databases.bytes）。"
  if ! run_in_ctx "Catalog=$CATALOG,Database=$DB" list-tables "SHOW TABLES"; then
    echo
    echo "候補の 1 件目でも SHOW TABLES が通りませんでした。理由: $RUN_DIR/list-tables.reason.txt"
    exit 1
  fi
fi

QE_CONTEXT="Catalog=$CATALOG,Database=$DB"

if [ -s "$RUN_DIR/list-tables.bytes" ] && grep -qi "$PREFIX" "$RUN_DIR/list-tables.bytes"; then
  echo
  echo "このデータベースに ${PREFIX}_* という名前のテーブル／ビューが既にあります。"
  echo "上書き事故を避けるため、何も作らずに止まります。一覧: $RUN_DIR/list-tables.bytes（実名を含みます）"
  exit 1
elif [ ! -s "$RUN_DIR/list-tables.bytes" ] && [ -f "$RUN_DIR/list-tables.bytes" ]; then
  : # 0 バイト（テーブルが 1 件も無い）は衝突なしとみなして続ける。
elif [ ! -f "$RUN_DIR/list-tables.bytes" ]; then
  echo
  echo "SHOW TABLES の結果本体を取得できず、${PREFIX}_* が無いことを確認できません。"
  echo "安全のため何も作らずに止まります（$RUN_DIR/list-tables.cp.err）。"
  exit 1
fi

# ============================================================================
# フィクスチャの作成: H（Hive の EXTERNAL TABLE）・I（Iceberg）・V（ビュー）。
# 作った直後に SHOW CREATE TABLE で形式を裏取りする（DROP 後は呼べない）。
# ============================================================================

echo
echo "フィクスチャを作成します（DDL）。"
FIXTURES_ATTEMPTED=1
FMT_H=unknown
FMT_I=unknown

if run create-h "CREATE EXTERNAL TABLE $DB.$H (n int) PARTITIONED BY (p string) LOCATION '$LOC_H'"; then
  H_OK=1
  FMT_H=$(determine_table_format h "$H")
else
  echo "== H（Hive の EXTERNAL TABLE）を作れませんでした。H を使う項目は未測定にします。"
fi

if run create-i "CREATE TABLE $DB.$I (n int) LOCATION '$LOC_I' TBLPROPERTIES ('table_type'='ICEBERG')"; then
  I_OK=1
  FMT_I=$(determine_table_format i "$I")
else
  echo "== I（Iceberg 表）を作れませんでした。I を使う項目は未測定にします。"
fi

if run create-v "CREATE VIEW $DB.$V AS SELECT 1 AS n"; then
  V_OK=1
else
  echo "== V（ビュー）を作れませんでした。V を使う項目は未測定にします。"
fi

# ============================================================================
# ROUND=1: A・S・R・D 群（既定）。
# ============================================================================

if [ "$ROUND" = 1 ]; then

# --- A 群: ALTER TABLE（a17 は末尾で実行する。I の唯一の列 n を消すため）。 -----------

run_req a1  "ALTER TABLE $DB.$H ADD COLUMNS (c1 int)" H
run_req a2  "ALTER /* c */ TABLE $DB.$H ADD COLUMNS (c2 int)" H
run_req a3  "ALTER /* c */ TABLE $DB.$I ADD COLUMNS (c3 int)" I
run     a4  "ALTER /* c */ TABLE $DB.$MISSING ADD COLUMNS (c int)"
run     a5  "alter /* c */ table $DB.$MISSING add columns (c int)"
run     a6  "ALTER  /* c */ TABLE $DB.$MISSING ADD COLUMNS (c int)"
run     a7  $'ALTER\n'"/* c */ TABLE $DB.$MISSING ADD COLUMNS (c int)"
run_req a8  "ALTER /* c */ TABLE $DB.$H ADD PARTITION (p='x')" H
run_req a9  "ALTER /* c */ TABLE $DB.$H DROP PARTITION (p='x')" H
run_req a10 "ALTER /* c */ TABLE $DB.$H SET TBLPROPERTIES ('k'='v')" H
run     a11 "ALTER /* c */ TABLE $DB.$MISSING RENAME TO $DB.$RENAMED"
run     a12 "/* c */ ALTER TABLE $DB.$MISSING ADD COLUMNS (c int)"
run     a13 "ALTER TABLE /* c */ $DB.$MISSING ADD COLUMNS (c int)"
run_req a14 "ALTER /* c */ TABLE $DB.$V ADD COLUMNS (c int)" V
run     a15 "ALTER /* c */ TABLE $DB.$MISSING DROP COLUMN c"
run_req a16 "ALTER /* c */ TABLE $DB.$H DROP COLUMN n" H

# --- S 群: SHOW CREATE TABLE。 ------------------------------------------------

run_req s1  "SHOW CREATE TABLE $DB.$H" H
run_req s2  "/* c */ SHOW CREATE TABLE $DB.$H" H
run_req s3  "SHOW /* c */ CREATE TABLE $DB.$H" H
run_req s4  "SHOW CREATE /* c */ TABLE $DB.$H" H
run_req s5  "SHOW CREATE TABLE /* c */ $DB.$H" H
run_req s6  "/* c */ SHOW CREATE TABLE $DB.$I" I
run_req s7  "SHOW /* c */ CREATE TABLE $DB.$I" I
run_req s8  "SHOW CREATE /* c */ TABLE $DB.$I" I
run_req s9  "SHOW CREATE TABLE /* c */ $DB.$I" I
run     s10 "/* c */ SHOW CREATE TABLE $DB.$MISSING"
run     s11 "SHOW /* c */ CREATE TABLE $DB.$MISSING"
run     s12 "SHOW CREATE /* c */ TABLE $DB.$MISSING"
run_req s13 "SHOW CREATE /* c */ TABLE $DB.$V" V
run_req s14 "show /* c */ create table $DB.$H" H
run_req s15 "show create /* c */ table $DB.$H" H
run_req s16 "SHOW  /* c */ CREATE TABLE $DB.$H" H
run_req s17 "SHOW CREATE  /* c */ TABLE $DB.$H" H
run_req s18 $'SHOW\n'"/* c */ CREATE TABLE $DB.$H" H
run_req s19 $'SHOW CREATE\n'"/* c */ TABLE $DB.$H" H
run_req s20 "/* abc */ SHOW CREATE TABLE $DB.$H" H
run_req s21 "/**/ SHOW CREATE TABLE $DB.$H" H
run_req s22 "/*c*/ SHOW CREATE TABLE $DB.$H" H
run_req s23 "/* a b */ SHOW CREATE TABLE $DB.$H" H
run_req s24 "/* , */ SHOW CREATE TABLE $DB.$H" H
run_req s25 $'-- x\n'"/* c */ SHOW CREATE TABLE $DB.$H" H
run_req s26 $'/* c */\n'"SHOW CREATE TABLE $DB.$H" H
run_req s27 "SHOW /* a */ /* b */ CREATE TABLE $DB.$H" H

# --- R 群: MSCK REPAIR TABLE。 ------------------------------------------------

run_req r1  "MSCK REPAIR TABLE $DB.$H" H
run_req r2  "MSCK REPAIR /* c */ TABLE $DB.$H" H
run_req r3  "MSCK /* c */ REPAIR TABLE $DB.$H" H
run_req r4  "/* c */ MSCK REPAIR TABLE $DB.$H" H
run_req r5  "MSCK REPAIR TABLE /* c */ $DB.$H" H
run_req r6  "msck repair /* c */ table $DB.$H" H
run_req r7  "MSCK REPAIR  /* c */ TABLE $DB.$H" H
run_req r8  $'MSCK REPAIR\n'"/* c */ TABLE $DB.$H" H
run     r9  "MSCK REPAIR /* c */ TABLE $DB.$MISSING"
run_req r10 "MSCK REPAIR /* c */ TABLE $DB.$I" I

# --- D 群: DESCRIBE（#242 の周辺の未実測）。 ------------------------------------

run_req d1 "DESCRIBE /* c */ $DB.$I" I
run_req d2 "describe /* c */ $DB.$H" H
run_req d3 "DESC /* c */ $DB.$H" H
run_req d4 "/* c */ DESCRIBE $DB.$H" H
run_req d5 "DESCRIBE /* c */ $DB.$V" V
run_req d6 $'DESCRIBE -- c\n'"$DB.$H" H

# a17: I の唯一の列 n を消すので、I を使うほかの項目（a3・s6〜s9・r10・d1）が全部終わった
# 後、後始末の直前に流す。
run_req a17 "ALTER /* c */ TABLE $DB.$I DROP COLUMN n" I

fi # ROUND=1

# ============================================================================
# ROUND=2: RENAME・DROP COLUMN・ADD COLUMNS の先頭寄りの位置、MSCK REPAIR TABLE
# （I・V・無い表）、DESCRIBE の続き（I・V）、空白 2 つ・タブ・複数改行・コメントの
# 中身の違い（n・m・d7〜d10・p・c 群）。
#
# 並び: I を使う項目（m1〜m4・d7・d8・n12・n13）は n12・n13 が m1〜m4・d7・d8 の後に
# なるようにまとめて先に流す。V を使う項目（n8・m5・m6・d9・d10・n2）は n2 が最後になる
# ようにまとめて流す。H を使う項目（n5・n6・n7・n10・n11・p 群の大半・c 群・n1）は
# n1（RENAME）が最後になるように、p 群・c 群の後に n1 を置く。M を使う項目
# （n3・n4・n9・m7・p9・p10）は依存が無いので好きな位置に置く。
# ============================================================================

if [ "$ROUND" = 2 ]; then

# --- M（無い表）。依存が無いのでここでまとめて流す。 ------------------------------

run n3 "/* c */ ALTER TABLE $DB.$MISSING RENAME TO $DB.$RENAMED"
run n4 "ALTER TABLE /* c */ $DB.$MISSING RENAME TO $DB.$RENAMED"

# --- H: DROP COLUMN n（3 形）。前提: どれかが実際に列を消してしまうと、後続は
# 「列が無い」という別の理由で失敗しうる（コメント位置とは別の原因）。本物の挙動は
# 未知のため、指示どおりの並びで投げ、結果は reason.txt の全文で見分ける。 ----------

run_req n5 "/* c */ ALTER TABLE $DB.$H DROP COLUMN n" H
run_req n6 "ALTER TABLE /* c */ $DB.$H DROP COLUMN n" H
run_req n7 "alter /* c */ table $DB.$H drop column n" H

# --- V: DROP COLUMN n。 --------------------------------------------------------

run_req n8 "ALTER /* c */ TABLE $DB.$V DROP COLUMN n" V

# --- M: DROP COLUMN（空白 2 つ）。 -----------------------------------------------

run n9 "ALTER  /* c */ TABLE $DB.$MISSING DROP COLUMN c"

# --- H: ADD COLUMNS（先頭寄りの位置。2 形）。 -----------------------------------

run_req n10 "/* c */ ALTER TABLE $DB.$H ADD COLUMNS (c6 int)" H
run_req n11 "ALTER TABLE /* c */ $DB.$H ADD COLUMNS (c7 int)" H

# --- I: MSCK REPAIR TABLE（対照 + 3 形）。 --------------------------------------

run_req m1 "MSCK REPAIR TABLE $DB.$I" I
run_req m2 "/* c */ MSCK REPAIR TABLE $DB.$I" I
run_req m3 "MSCK /* c */ REPAIR TABLE $DB.$I" I
run_req m4 "MSCK REPAIR TABLE /* c */ $DB.$I" I

# --- I: DESCRIBE・DESC。 --------------------------------------------------------

run_req d7 "/* c */ DESCRIBE $DB.$I" I
run_req d8 "DESC /* c */ $DB.$I" I

# --- I: ADD COLUMNS（先頭寄りの位置。2 形）。m1〜m4・d7・d8 の後に置く。 -------------

run_req n12 "/* c */ ALTER TABLE $DB.$I ADD COLUMNS (c8 int)" I
run_req n13 "ALTER TABLE /* c */ $DB.$I ADD COLUMNS (c9 int)" I

# --- V: MSCK REPAIR TABLE（対照 + 1 形）。 --------------------------------------

run_req m5 "MSCK REPAIR TABLE $DB.$V" V
run_req m6 "MSCK REPAIR /* c */ TABLE $DB.$V" V

# --- V: DESCRIBE・SHOW CREATE TABLE。 --------------------------------------------

run_req d9  "/* c */ DESCRIBE $DB.$V" V
run_req d10 "SHOW CREATE TABLE /* c */ $DB.$V" V

# --- V: RENAME。V を使うほかの項目（n8・m5・m6・d9・d10）が全部終わった後に置く。 -----

run_req n2 "ALTER /* c */ TABLE $DB.$V RENAME TO $DB.$V_REN" V

# --- M: MSCK REPAIR TABLE（対照）。 ----------------------------------------------

run m7 "MSCK REPAIR TABLE $DB.$MISSING"

# --- H: 空白 2 つ・タブ・複数改行・先頭の空白（p 群。p9・p10 は M）。 -----------------

run_req p1  "SHOW  CREATE /* c */ TABLE $DB.$H" H
run_req p2  $'SHOW\t'"/* c */ CREATE TABLE $DB.$H" H
run_req p3  "MSCK  REPAIR /* c */ TABLE $DB.$H" H
run_req p4  "SHOW CREATE TABLE  /* c */ $DB.$H" H
run_req p5  $'SHOW CREATE\n  '"/* c */ TABLE $DB.$H" H
run_req p6  $'SHOW\n\n'"/* c */ CREATE TABLE $DB.$H" H
run_req p7  "   /* c */ SHOW CREATE TABLE $DB.$H" H
run_req p8  "SHOW  CREATE  TABLE  /* c */ $DB.$H" H
run     p9  "ALTER TABLE  /* c */ $DB.$MISSING ADD COLUMNS (c int)"
run     p10 "ALTER  TABLE /* c */ $DB.$MISSING ADD COLUMNS (c int)"
run_req p11 $'SHOW\t\t'"/* c */ CREATE TABLE $DB.$H" H

# --- H: コメントの中身の違い（c 群）。 --------------------------------------------

run_req c1  "/* 1 */ SHOW CREATE TABLE $DB.$H" H
run_req c2  "/* 'x' */ SHOW CREATE TABLE $DB.$H" H
run_req c3  "/* a.b */ SHOW CREATE TABLE $DB.$H" H
run_req c4  "/* _a1 */ SHOW CREATE TABLE $DB.$H" H
run_req c5  "/*+ x */ SHOW CREATE TABLE $DB.$H" H
run_req c6  "/* あ */ SHOW CREATE TABLE $DB.$H" H
run_req c7  "/* 1a */ SHOW CREATE TABLE $DB.$H" H
run_req c8  $'/*\n'"c */ SHOW CREATE TABLE $DB.$H" H
run_req c9  "/* \"q\" */ SHOW CREATE TABLE $DB.$H" H
run_req c10 "/* ) */ SHOW CREATE TABLE $DB.$H" H
run_req c11 "SHOW CREATE TABLE /* 1 */ $DB.$H" H
run_req c12 "/* 1.5 */ SHOW CREATE TABLE $DB.$H" H
run_req c13 "/* a-b */ SHOW CREATE TABLE $DB.$H" H

# --- H: RENAME。H を使うほかの全項目（n5・n6・n7・n10・n11・p 群・c 群）が全部終わった
# 後、後始末の直前に流す（RENAME が成功すると H は $H_REN に移る）。 -------------------

run_req n1 "ALTER /* c */ TABLE $DB.$H RENAME TO $DB.$H_REN" H

fi # ROUND=2

# ============================================================================
# 後始末: 作った 3 つを DROP する。
# ============================================================================

echo
echo "後始末（DROP）を行います。"
CLEANUP_ALL_OK=1
if [ "$V_OK" = 1 ]; then
  run drop-v "DROP VIEW IF EXISTS $DB.$V" || CLEANUP_ALL_OK=0
fi
if [ "$I_OK" = 1 ]; then
  run drop-i "DROP TABLE IF EXISTS $DB.$I" || CLEANUP_ALL_OK=0
fi
if [ "$H_OK" = 1 ]; then
  run drop-h "DROP TABLE IF EXISTS $DB.$H" || CLEANUP_ALL_OK=0
fi
if [ "$ROUND" = 2 ]; then
  # n1・n2（RENAME）が成功していると、上の DROP は元の名前を探して見つからないだけ
  # （IF EXISTS なので SUCCEEDED のまま）。<名前>_ren の方も IF EXISTS で消す。
  if [ "$V_OK" = 1 ]; then
    run drop-v-ren "DROP VIEW IF EXISTS $DB.$V_REN" || CLEANUP_ALL_OK=0
  fi
  if [ "$I_OK" = 1 ]; then
    run drop-i-ren "DROP TABLE IF EXISTS $DB.$I_REN" || CLEANUP_ALL_OK=0
  fi
  if [ "$H_OK" = 1 ]; then
    run drop-h-ren "DROP TABLE IF EXISTS $DB.$H_REN" || CLEANUP_ALL_OK=0
  fi
fi
if [ "$CLEANUP_ALL_OK" = 1 ]; then
  FIXTURES_ATTEMPTED=0
else
  echo "== 後始末の DROP に成功しなかったものがあります。終了時にもう一度投げます。"
  echo "   それでも消えなければ、$DB の ${PREFIX}_* を手で消してください。"
fi

# ============================================================================
# summary の作成。
# ============================================================================

PREFLIGHT_LABELS="list-tables available-databases"
FIXTURE_LABELS="create-h create-i create-v verify-h verify-i"
CLEANUP_LABELS="drop-v drop-i drop-h"
if [ "$ROUND" = 2 ]; then
  CLEANUP_LABELS="$CLEANUP_LABELS drop-v-ren drop-i-ren drop-h-ren"
fi

if [ "$ROUND" = 1 ]; then
  A_LABELS="a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16"
  S_LABELS="s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 s12 s13 s14 s15 s16 s17 s18 s19 s20 s21 s22 s23 s24 s25 s26 s27"
  R_LABELS="r1 r2 r3 r4 r5 r6 r7 r8 r9 r10"
  D_LABELS="d1 d2 d3 d4 d5 d6"
  ALL_LABELS="$PREFLIGHT_LABELS $FIXTURE_LABELS $A_LABELS $S_LABELS $R_LABELS $D_LABELS a17 $CLEANUP_LABELS"
else
  ROUND2_LABELS="n3 n4 n5 n6 n7 n8 n9 n10 n11 m1 m2 m3 m4 d7 d8 n12 n13 m5 m6 d9 d10 n2 m7"
  ROUND2_LABELS="$ROUND2_LABELS p1 p2 p3 p4 p5 p6 p7 p8 p9 p10 p11"
  ROUND2_LABELS="$ROUND2_LABELS c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12 c13"
  ALL_LABELS="$PREFLIGHT_LABELS $FIXTURE_LABELS $ROUND2_LABELS n1 $CLEANUP_LABELS"
fi

# summary.tsv から 1 行を読み、要点を 1 行にまとめて返す。
row_summary_of() {
  python3 -c 'import csv, sys
label = sys.argv[2]
with open(sys.argv[1], newline="") as f:
    for row in csv.DictReader(f, delimiter="\t"):
        if row["label"] == label:
            print(
                "state={state} type={statement_type}/{substatement_type} "
                "loc_tail={loc_tail} error={error_category}/{error_type} "
                "start_message={start_message} start_code={start_athena_error_code} "
                "body_bytes={body_bytes} metadata={metadata_present} note={note}".format(**row)
            )
            break' "$SUMMARY" "$1"
}

write_summary_txt() {
  local txt="$RUN_DIR/summary.txt"
  {
    echo "# issue #244: SHOW CREATE TABLE・ALTER TABLE・MSCK REPAIR TABLE・DESCRIBE の"
    echo "#             キーワードの間や直後のブロックコメントが本物の Athena でどう扱われるかを実測"
    echo "# ROUND: $ROUND"
    echo "# 実行日時: $(date -Iseconds)"
    echo "# StartQueryExecution を呼んだ回数（一時的な失敗の再試行込み。フィクスチャ作成・"
    echo "#   形式の裏取り（SHOW CREATE TABLE）・後始末の DROP を含む。list-work-groups など"
    echo "#   Athena のクエリではない API 呼び出しは含めない）: $(wc -l < "$START_CALL_FILE" | tr -d ' ')"
    echo "#   ※ GetQueryExecution / S3 への呼び出しはこの回数に含めない（課金には影響しない）。"
    echo "#   ※ trap で発動する後始末（ベストエフォートの DROP）だけはこの回数に含めない。"
    echo "#     正常終了で 3 つとも消せていれば trap は何も呼ばない。"
    if [ "$ROUND" = 1 ]; then
      echo "# DDL: あり。作成: ${PREFIX}_h（Hive の EXTERNAL TABLE）・${PREFIX}_i（Iceberg）・"
      echo "#   ${PREFIX}_v（ビュー）の 3 つ。A 群で ALTER TABLE を最大 17 回、S/R/D 群は"
      echo "#   SHOW CREATE TABLE / MSCK REPAIR TABLE / DESCRIBE で読むだけ。最後に 3 つとも DROP。"
      echo "#   ${PREFIX}_i（Iceberg）は location を <OUTPUT> の下に置いてあり、DROP でデータも消える。"
      echo "#   ${PREFIX}_h（Hive の EXTERNAL）は DROP TABLE では S3 の場所自体は残るが、行を"
      echo "#   入れていないので中身は無い。"
    else
      echo "# DDL: あり（ROUND=2）。フィクスチャの作成・後始末は ROUND=1 と同じ 3 つ"
      echo "#   （${PREFIX}_h・${PREFIX}_i・${PREFIX}_v）。n1（H を RENAME）・n2（V を RENAME）が"
      echo "#   成功しうるため、後始末は元の名前と <名前>_ren（${PREFIX}_h_ren・${PREFIX}_v_ren・"
      echo "#   ${PREFIX}_i_ren。I は本ラウンドでは RENAME しないが念のため）の両方に"
      echo "#   DROP TABLE/VIEW IF EXISTS を投げる。n・m・d7〜d10 群で ADD/DROP COLUMNS・"
      echo "#   RENAME TO・MSCK REPAIR TABLE（I・V・無い表）・DESCRIBE（I・V）を投げ、"
      echo "#   p・c 群は空白 2 つ・タブ・複数改行・先頭空白・コメントの中身の違いを"
      echo "#   SHOW CREATE TABLE / MSCK REPAIR TABLE / ALTER TABLE で見る。"
    fi
    echo "# 課金の見込み: スキャンする SELECT は投げていない。ALTER・DROP はメタデータのみ、"
    echo "#   CREATE は 0 行、SHOW/MSCK/DESCRIBE は読み取りのみ。Athena の最小課金 × クエリ数の見込み。"
    echo "# フィクスチャの形式（SHOW CREATE TABLE で裏取り。作成直後の値）: H=$FMT_H  I=$FMT_I"
    echo "#   （hive/iceberg 以外は、作成に失敗したか裏取りできなかったことを示す）"
    echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更や、コンソールでの"
    echo "#   設定変更で変わりうる。実測値は工場出荷時の既定とは限らない。"
    echo
    echo "## 項目ごとの結果（1 項目 = 1 ブロック。実名は伏せる）"
    for label in $ALL_LABELS; do
      if [ -s "$RUN_DIR/$label.sql" ]; then
        echo "### $label"
        echo "- sql: $(hide "$(python3 -c 'import sys
print(repr(open(sys.argv[1], "rb").read().decode("utf-8", "replace")))' "$RUN_DIR/$label.sql")")"
        local row
        row=$(row_summary_of "$label")
        [ -n "$row" ] && echo "- $row"
        if [ -s "$RUN_DIR/$label.reason.txt" ]; then
          echo "- State / StateChangeReason / AthenaError（全文）:"
          hide_multiline "$RUN_DIR/$label.reason.txt" | sed 's/^/    /'
        elif [ -s "$RUN_DIR/$label.start.err" ]; then
          echo "- 開始時に弾かれた（AthenaErrorCode・Message は上の行を参照。原文は $label.start.err）"
        fi
        echo "- 本体:"
        hide_multiline "$RUN_DIR/$label.bytes" | sed 's/^/    /'
        if [ -s "$RUN_DIR/$label.metadata.bytes" ]; then
          echo "- .metadata: あり（$(wc -c < "$RUN_DIR/$label.metadata.bytes" | tr -d ' ') バイト）"
        elif [ -f "$RUN_DIR/$label.metadata.bytes" ]; then
          echo "- .metadata: あり（0 バイト）"
        elif [ -s "$RUN_DIR/$label.metadata.cp.err" ]; then
          echo "- .metadata: 無し（証拠: $label.metadata.cp.err）"
        else
          echo "- .metadata: - （OutputLocation が無い、または未確認）"
        fi
        echo
      else
        echo "### $label"
        local skip_note
        skip_note=$(python3 -c 'import csv, sys
label = sys.argv[2]
with open(sys.argv[1], newline="") as f:
    for row in csv.DictReader(f, delimiter="\t"):
        if row["label"] == label:
            print(row["note"])
            break' "$SUMMARY" "$label")
        if [ -n "$skip_note" ]; then
          echo "- 未測定: $skip_note"
        else
          echo "- この実行では投げなかった（DB が指定どおり実在したため SHOW DATABASES は不要、など）"
        fi
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
echo "実名をマスクした、そのまま貼れる一覧: $SUMMARY_TXT"
echo "中身のファイルは $RUN_DIR にあります。リポジトリには入れないでください。"
echo "<label>.sql・<label>.reason.txt・<label>.start.err・available-databases.bytes は"
echo "実名（DB 名・テーブル名）を含みうるので、summary.txt 以外を貼るときは中身を確かめてください。"
