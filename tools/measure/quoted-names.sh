#!/usr/bin/env bash
# issue #204 で作成
# 本物の Athena で、引用符付きの名前を取る DESCRIBE・DESC・SHOW CREATE TABLE・
# SHOW COLUMNS・DROP TABLE・ALTER TABLE・MSCK REPAIR TABLE が、StartQueryExecution の
# 時点でどの形なら弾かれ、どの形なら通るか（境界の規則）と、弾かれたときの文言の規則
# （エラー位置 `line L:C` と `input '...'` の中身、Message・AthenaErrorCode）を洗い出す。
# issue #204 のための実測スクリプト。
#
# 背景（`docs/dev/measurements/statements.md` の「引用符付きの名前は空白の有無によらず
# 開始時に弾かれる」節、#200 の実測より）: `DESCRIBE "t"`・`DESC "t"`・
# `SHOW CREATE TABLE "t"`・`DROP TABLE "t"`・`ALTER TABLE "t" ADD COLUMNS (...)`・
# `OPTIMIZE "t" ...` は、単一の引用符付き名前 `"t"` だけで StartQueryExecution が
# InvalidRequestException（MALFORMED_QUERY）になることを確認済み。athena-local は
# SQL を書き換えず・独自に弾かない方針（CLAUDE.md）のため、これらを Trino に投げて
# 実行してしまう（空白ありの形と同じ値を返す。#200 の備考）。athena-local 側を本物に
# 揃える対応の材料として、このスクリプトで境界（`db.t`・`"db"."t"`・3 部修飾・
# バッククォートなど）と文言の規則を洗う。
#
# tools/measure/keyword-boundary.sh（#200）を雛形にしている。redact・mask_names・
# sanitize・first_err_line・is_transient_error・start_query_retry・poll_until_terminal・
# emit_row・skip・preflight（SHOW TABLES → 空なら SHOW DATABASES を案内）・trap での
# 後始末・summary.tsv と summary.txt の 2 段はそのまま流用する。
#
# 雛形からの変更点:
#   - S3 への読み書き（fetch・head_object・.metadata の解析・GetQueryResults の行数採取）は
#     持ち込んでいない。この実測は「開始できたか」「StatementType/SubstatementType」
#     「FAILED の理由」「開始時に弾かれたときの文言」だけを見れば足り、結果ファイルの
#     置き場所や中身は関係ない（CLAUDE.md の不変条件どおり、成功した項目は結果ファイルを
#     置くが、この実測の対象ではない）。preflight の SHOW TABLES の読み出しも S3 の CSV
#     ではなく GetQueryResults（ページングして全件）に替えた（S3 の読み取り権限が
#     無くても preflight が通るようにするため）。
#   - AthenaErrorCode・Message は、追加の呼び出しをせずに、開始時に弾かれた
#     StartQueryExecution の標準エラー（`<label>.start.err`）からそのまま抜く。
#     新しめの AWS CLI は「An error occurred (...) ... operation: <Message>」の行に続けて
#     「Additional error details: / AthenaErrorCode: <コード>」を同じ標準エラーに出す
#     （#200 の実例 `b1.start.err` で確認済み）ので、2 回目の呼び出しは要らない。
#   - 名前の形（n0〜n11）を 1 つの関数 `name_form` に集約し、D/C 群（全 12 形）・
#     E/L/X 群（絞った 6 形）で使い回す。ALTER・DROP は実在しない名前
#     （athena_local_probe_204_nope）にだけ投げ、準備したテーブルには触れない。
#   - P 群（文言の位置の規則: 小文字キーワード・連続空白・改行・先頭空白・先頭コメント・
#     末尾空白）を新設した。改行を挟む形は ANSI-C quoting（`$'...'`）で作る
#     （tools/measure/leading-comment.sh の注意のとおり、$'...' は変数展開しないので
#     改行だけを $'...' の断片にして残りと隣接させて連結する）。
#   - S3 Tables（環境変数 3 つが揃ったときだけ測る任意の群）を新設した。
#   - 【2 ラウンド目】環境変数 `ROUND`（既定 1）でラウンドを切り替える。ROUND=1 は
#     上の D〜P 群・S3 Tables 群（1 ラウンド目と同じ項目。変えていない）を流し、
#     ROUND=2 は下の「ROUND=2 の項目」の U1〜U7 群だけを流す。preflight・準備の
#     Hive テーブル（d0-setup-hive）・後始末（z-drop-hive）は両ラウンド共通。
#   - 【3 ラウンド目】issue #207。ROUND=3 は下の「ROUND=3 の項目」の V1〜V7 群だけを
#     流す。preflight・準備・後始末は 1・2 ラウンド目と共通。V7 の診断のために、
#     QueryExecutionContext を 1 文だけ差し替える仕組み（run_in_ctx）を足した。
#     summary の伏せ字に、アカウント ID（12 桁の数字）と S3 Tables のバケット名
#     （S3TABLES_CATALOG の `/` より後ろ）を足し、「失敗した項目の理由」の節にも
#     伏せ字をかけるようにした（ラウンド 2 の summary.txt で、この節からアカウント ID と
#     S3 Tables の実名が漏れていたため。1・2 ラウンド目にも効く）。
#   - 【4 ラウンド目】issue #207 の続き。ROUND=4 は下の「ROUND=4 の項目」の W1〜W5 群
#     だけを流す。preflight・準備・後始末は共通。3 ラウンド目（run-20260925-104713）で、
#     DESCRIBE・SHOW COLUMNS は開始前に Glue で対象の存在を確かめ、実在しなければ
#     （無引用でも）Entity Not Found（INVALID_INPUT）、実在すれば構文の文言になり、
#     4 部の DESCRIBE・SHOW COLUMNS は `Invalid table name <引用符を外した名前>` になると
#     分かったので、存在の確認が何を対象に解決しているかと、4 部の文言の細部を測る。
#     W1 の大文字の名前を伏せるため、伏せ字に DB 名・対象テーブル名・接頭辞の大文字形
#     （<DB_UPPER>・<TT_UPPER>・<PROBE_UPPER>）を足した（どのラウンドにも効く）。
#   - 【5 ラウンド目】issue #212。ROUND=5 は下の「ROUND=5 の項目」の Y1〜Y4 群だけを
#     流す。preflight・準備・後始末は共通。#207 の 3・4 ラウンド目で測らずに残した形
#     （docs/dev/unmeasured.md の「文の種類と構文」節）を測る。伏せ字は 4 ラウンド目の
#     大文字形がそのまま効く。
#
# ROUND=2 の項目（1 ラウンド目 `run-20260925-075408` の結果を踏まえた 2 ラウンド目）:
#   U1  3 部の名前で途中・末尾だけ引用符付き（n12 = awsdatacatalog."db".t、
#       n13 = awsdatacatalog.db."t"）を DESCRIBE・DESC・SHOW CREATE TABLE・
#       SHOW COLUMNS FROM の 4 文に、DROP TABLE には実在しない名前に対して。
#   U2  ALTER で Trino が受ける操作（RENAME TO／DROP COLUMN）を、db."nope"・
#       "db".nope・"awsdatacatalog".db.nope（n14）・awsdatacatalog.db."nope"（n13）の
#       4 形に、加えて ALTER TABLE IF EXISTS の引用符付き／無引用の対。すべて
#       実在しない名前 athena_local_probe_204_nope に対して投げる。
#   U3  S3 Tables（S3TABLES_* が揃うときだけ）。1 ラウンド目は名前空間の綴り違いで
#       対照の SELECT が SCHEMA_NOT_FOUND だったので、正しい値で対照を取り直しつつ、
#       DESCRIBE・DESC・SHOW COLUMNS FROM・SHOW CREATE TABLE・存在しない表への
#       DESCRIBE/DROP/ALTER・名前空間まで引用符付きの形を測る。
#   U4  先頭・区切りの空白（タブ・改行・CRLF・2 連続改行・行コメント後・改行入り
#       ブロックコメント）を ANSI-C quoting（`$'...'`）で作る。DROP にも先頭・区切りの
#       改行を 1 本ずつ。
#   U5  コメントの中の非 ASCII（ひらがな・4 バイトの絵文字）と、存在しない非 ASCII
#       名前 "日本" への DESCRIBE。
#   U6  DESCRIBE EXTENDED／FORMATTED の引用符付きと、対照の無引用 EXTENDED。
#   U7  SHOW TABLES IN／DROP DATABASE IF EXISTS／CREATE TABLE（非 EXTERNAL の Hive。
#       本物では失敗するはずだが、万一成功したら直後に無引用 IF EXISTS の DROP を
#       run で投げて後始末する）を、引用符付き・無引用の対で。
#
# ROUND=3 の項目（issue #207。#204 で実測した形の外側にある、まだ測っていない形）:
#   名前の表記: <DB> は DB、<TT> は準備のテーブル athena_local_probe_204、<TT>_nope は
#   実在しない名前、<TT>_nope3 は CREATE TABLE 用の実在しない名前（U7 と同じ）、
#   "日本" は実在しない非 ASCII の名前。非 ASCII は u5-jp と同じく $'\xe6\x97\xa5...'
#   のバイト列で組み、UTF-8 のままワイヤに乗せる。
#   V1  3 部の ALTER で途中が引用符付き（n12 = awsdatacatalog."<DB>".<TT>_nope、
#       n15 = awsdatacatalog."<DB>"."<TT>_nope"）に、U2 と同じ RENAME TO と
#       DROP COLUMN の 2 操作。すべて実在しない名前に対して。4 本。
#   V2  4 部の修飾名 awsdatacatalog.<DB>.<X>.n の、無引用の対照（p0）と、引用符を
#       1 部目（p1）・2 部目（p2）・3 部目（p3）・4 部目（p4）のどれか 1 つだけに付けた
#       4 形。<X> は DESCRIBE と SHOW COLUMNS FROM では実在する <TT>、DROP TABLE と
#       ALTER TABLE ... RENAME TO <TT>_nope2 では <TT>_nope。4 文 × 5 形 = 20 本。
#   V3  SHOW TABLES IN の 2 部（awsdatacatalog.<DB> の対照と引用符の 3 形）4 本と、
#       CTAS でない CREATE TABLE <name> (n int)（非 EXTERNAL の Hive）の 2 部以上
#       （<DB>.<TT>_nope3 の対照と、n4・n5・n6・n12・n13 の 5 形）6 本と、
#       CREATE TABLE IF NOT EXISTS の引用符付き・無引用の対 2 本。CREATE TABLE は
#       U7 と同じく、想定外に成功したら直後に無引用 IF EXISTS の DROP で消す。
#   V4  実在しない ASCII の名前を引用符付きで（DESCRIBE の n1・n5・n6、無引用の対照
#       n0、SHOW COLUMNS FROM の n1）。5 本。
#   V5  実在しない非 ASCII の名前 "日本" を DESCRIBE 以外の文に（DESCRIBE の対照、
#       DESC、DESCRIBE <DB>."日本"、SHOW COLUMNS FROM、DROP TABLE、
#       ALTER TABLE ... RENAME TO <TT>_nope2、SHOW CREATE TABLE、SHOW TABLES IN、
#       CREATE TABLE（想定外に成功したら DROP TABLE IF EXISTS `日本` で消す））。9 本。
#       preflight の SHOW TABLES に「日本」が実在すれば、DROP・ALTER を実在の表に
#       投げてしまうので、V5 群をまるごと未測定にする。
#   V6  実在する非 ASCII の名前（PROBE_DDL=1 のときだけ）。
#       CREATE TABLE <DB>."<TT>_日本" AS SELECT 1 AS n を試し、開始時に弾かれるか
#       失敗したら、残りを「未測定（非 ASCII のテーブルを作れなかった）」にする。
#       成功したら DESCRIBE "<TT>_日本"・DESCRIBE <DB>."<TT>_日本"・
#       SHOW COLUMNS FROM "<TT>_日本"・DESCRIBE `<TT>_日本`（対照）を測り、最後に
#       DROP TABLE IF EXISTS <DB>.`<TT>_日本` で消して、SHOW TABLES で消えたことを
#       確かめる（消えなければ summary の冒頭で手動削除を案内する）。開始できて
#       FAILED になったときも、念のため同じ DROP と SHOW TABLES を投げる。
#   V7  S3 Tables（S3TABLES_* が揃うときだけ。U3 を下敷きに）。はじめに診断として、
#       QueryExecutionContext の Catalog を S3TABLES_CATALOG にして（Database は
#       付けない）SHOW DATABASES と SHOW TABLES IN <ns> を投げ、行を GetQueryResults で
#       取って生データ（v7-diag-*.rows.txt。実名を含む）にだけ保存する。summary には
#       件数と、S3TABLES_NS／S3TABLES_TABLE がその一覧に含まれるか（完全一致・大小無視）
#       だけを出す。続けて U3 と同じ 10 本（対照 SELECT・DESCRIBE・DESC・
#       SHOW COLUMNS FROM・SHOW CREATE TABLE・存在しない表への DESCRIBE/DROP TABLE/
#       ALTER TABLE の RENAME TO と DROP COLUMN・名前空間まで引用符付きの DESCRIBE）。
#       対照 SELECT が失敗しても項目は流し、summary に「対照 SELECT 失敗」と出す。
#
# ROUND=4 の項目（issue #207 の続き。3 ラウンド目 `run-20260925-104713` を踏まえる）:
#   名前の表記は ROUND=3 と同じ。<NODB> は実在しない DB 名 athena_local_probe_204_nodb、
#   <TT>_v は W4 で作るビュー athena_local_probe_204_v。
#   W1  存在の確認が何を対象に解決するか。次の 8 形を DESCRIBE と SHOW COLUMNS FROM の
#       両方に（16 本）: <NODB>.<TT>（スキーマが実在しない）、"<NODB>".<TT>、
#       awsdatacatalog.<DB>.<TT>（3 部・実在）、awsdatacatalog.<DB>.<TT>_nope（3 部・
#       実在しない）、nocatalog_204.<DB>.<TT>（カタログが実在しない）、1 部の <TT> を
#       QueryExecutionContext の Database を <NODB> にして（Catalog は既定）、大文字の
#       無引用 <TT の大文字>（実在）、2 部 <DB の大文字>.<TT の大文字>。
#   W2  4 部の名前の文言の細部（DESCRIBE）: AwsDataCatalog.<DB>.<TT>.N（無引用の部分の
#       大文字小文字）、awsdatacatalog."<DB>"."a""b".n（引用符の中の ""）、
#       awsdatacatalog.<DB>."x.y".n（引用符の中の .）、5 部 awsdatacatalog.<DB>.<TT>.n.m、
#       DESC awsdatacatalog.<DB>.<TT>.n、SHOW COLUMNS IN awsdatacatalog.<DB>.<TT>.n の
#       6 本と、S3TABLES_* があるときだけ DESCRIBE "<S3TABLES_CATALOG>".<ns>.<t>.n。
#   W3  4 部・5 部の DROP・ALTER（実在しない名前に）: DROP TABLE IF EXISTS
#       awsdatacatalog.<DB>.<TT>_nope.n、DROP TABLE awsdatacatalog.<DB>.<TT>_nope.n.m、
#       ALTER TABLE awsdatacatalog.<DB>.<TT>_nope.n.m RENAME TO <TT>_nope2。3 本。
#   W4  ビュー（PROBE_DDL=1 のときだけ）。CREATE VIEW <DB>.<TT>_v AS SELECT 1 AS n を
#       作り、DESCRIBE <TT>_v・DESCRIBE "<TT>_v"・SHOW COLUMNS FROM <TT>_v・
#       SHOW COLUMNS FROM "<TT>_v" を測って、DROP VIEW IF EXISTS <DB>.<TT>_v で消し、
#       SHOW TABLES と SHOW VIEWS で消えたことを確かめる（消えなければ summary の冒頭で
#       手動削除を案内する）。開始時に弾かれたら残りを未測定にし、開始できて FAILED に
#       なったときも念のため同じ DROP VIEW と確かめを投げる。
#   W5  存在の確認と引用符の順序: 実在しない DESCRIBE "<TT>_nope" を 2 回（Request ID が
#       毎回違うことの確認）、実在しない 2 部の無引用 DESCRIBE <DB>.<TT>_nope と
#       SHOW COLUMNS FROM <DB>.<TT>_nope。4 本。
#
# ROUND=5 の項目（issue #212。#207 の 3・4 ラウンド目で測らなかった形）:
#   名前の表記は ROUND=3 と同じ。<NOCAT> は実在しないカタログ名 nocatalog_212。
#   Y1  4 部以上の SHOW CREATE TABLE・SHOW TABLES IN・CTAS でない CREATE TABLE。
#       SHOW CREATE TABLE は awsdatacatalog.<DB>.<TT>.n（無引用）、"<DB>" だけ引用符付き、
#       "n" だけ引用符付き、5 部の .n.m の 4 本。SHOW TABLES IN は awsdatacatalog.<DB>.x.n の
#       無引用・"<DB>"・"n" の 3 本。CREATE TABLE は実在しない <TT>_nope3 に SHOW CREATE TABLE と
#       同じ 4 形で (n int) を付けて 4 本（想定外に成功したら後始末の DROP を投げる）。
#   Y2  SHOW TABLES IN の 3 部 awsdatacatalog.<DB>.x を、無引用と 1・2・3 部目だけ
#       引用符付きの 4 本。
#   Y3  QueryExecutionContext の Catalog を <NOCAT>（Database は <DB>）にして、SELECT 1
#       （対照）、DESCRIBE <TT>・<DB>.<TT>・awsdatacatalog.<DB>.<TT>（対照）・"<TT>"、
#       SHOW COLUMNS FROM <TT>・<DB>.<TT>、DESCRIBE <TT>_nope（実在しない表）の 8 本と、
#       Catalog を NoCatalog_212 にした DESCRIBE <TT> の 1 本。
#   Y4  4 部の DESCRIBE で引用符付きの部分が大文字: awsdatacatalog.<DB>."<TT の大文字>".n、
#       "AwsDataCatalog".<DB>.<TT>.n、awsdatacatalog.<DB>.<TT>."N"、
#       awsdatacatalog."<DB の大文字>".<TT>.n と、SHOW COLUMNS FROM で 1 つ目の形の 5 本。
#
# 使い方:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db bash tools/measure/quoted-names.sh
#   2 ラウンド目:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=2 bash tools/measure/quoted-names.sh
#   3 ラウンド目（issue #207）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=3 bash tools/measure/quoted-names.sh
#   4 ラウンド目（issue #207 の続き）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=4 bash tools/measure/quoted-names.sh
#   5 ラウンド目（issue #212）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=5 bash tools/measure/quoted-names.sh
#   S3 Tables も測るとき（どのラウンドでも指定できる）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=3 \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns S3TABLES_TABLE=your_table \
#     bash tools/measure/quoted-names.sh
#   （資格情報はホストのシェルで AWS_ACCESS_KEY_ID などを export してから。または ~/.aws/credentials）
#
# 必要な環境変数:
#   OUTPUT    結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける）。
#   DB        データベース名。実在するものを指定する。
#
# 任意の環境変数:
#   CATALOG          既定 AwsDataCatalog
#   REGION           既定 ap-northeast-1
#   OUT_DIR          既定 ${DEV_HOST_HOME:-$HOME}/athena-quoted-names-measurements
#                    （実名が入るのでリポジトリの外に出す）
#   POLL_TIMEOUT     終端状態を待つ上限（秒）。既定 180
#   RETRY_MAX        名前解決・接続など一時的な失敗を再試行する回数の上限。既定 4
#   RETRY_DELAY      再試行の間隔（秒）。既定 5
#   PROBE_DDL        既定 1（測る）。準備の Hive テーブル athena_local_probe_204 を
#                    作って対象テーブルが要る群に使い、最後に無引用 + IF EXISTS の
#                    DROP で消す。0 にすると SHOW TABLES の 1 件目（実在のテーブル）を
#                    対象にする（名前は小文字。実名は summary に出さない）。
#   ROUND            既定 1。1 は D〜P 群・S3 Tables 群（1 ラウンド目）、2 は
#                    U1〜U7 群（2 ラウンド目）、3 は V1〜V7 群（3 ラウンド目、
#                    issue #207）、4 は W1〜W5 群（4 ラウンド目、issue #207 の続き）、
#                    5 は Y1〜Y4 群（5 ラウンド目、issue #212）だけを流す。
#   S3TABLES_CATALOG S3 Tables のカタログ名（例 s3tablescatalog/my-bucket）。
#   S3TABLES_NS      S3 Tables の名前空間。
#   S3TABLES_TABLE   S3 Tables のテーブル名。
#                    この 3 つが揃ったときだけ S3 Tables 群（ROUND=1 の S3T・
#                    ROUND=2 の U3・ROUND=3 の V7・ROUND=4 の w2-s3t）を測る。1 つでも欠けていれば
#                    「未測定（S3TABLES_* 未設定）」として summary に残す。
#
# ** このスクリプトが本物に対して行う破壊的な操作 **
#   PROBE_DDL=1 のとき: <db>.athena_local_probe_204（Hive。CREATE TABLE ... AS SELECT
#   で作成）を作り、最後に無引用 + IF EXISTS の DROP TABLE で消す（異常終了時も trap で
#   同じ形で消しにいく）。同名のテーブルが既にあると壊すので、開始前に SHOW TABLES で
#   athena_local_probe_204 という接頭辞が無いことを確かめ、1 件でもあれば何も作らずに
#   止まる。ALTER TABLE・DROP TABLE は実在しない名前
#   （<db>.athena_local_probe_204_nope）にだけ投げるので、そのテーブル自体は作らない
#   （後始末の対象にもならない）。
#   ROUND=2 の U7 群だけ、実在しない名前 <db>.athena_local_probe_204_nope3 に対する
#   CREATE TABLE（非 EXTERNAL の Hive。本物では失敗するはず）を引用符付き・無引用の
#   両方で投げる。想定外に成功したら、その場で無引用 IF EXISTS の DROP を投げて消す
#   （trap にも同じ DROP を保険として持つ）。
#   ROUND=3 では、準備のテーブルのほかに次の DDL がありうる。
#     - V3 群の CREATE TABLE（<DB>.<TT>_nope3 を 8 通りの書き方で。非 EXTERNAL の
#       Hive で本物では失敗するはず）。想定外に成功したら、その場で無引用 IF EXISTS の
#       DROP TABLE IF EXISTS <TT>_nope3 を投げて消す（trap にも保険）。
#     - V5 群の CREATE TABLE "日本" (n int)。想定外に成功したら、その場で
#       DROP TABLE IF EXISTS `日本` を投げて消す（trap にも保険）。
#     - V6 群（PROBE_DDL=1 のときだけ）の CTAS CREATE TABLE <DB>."<TT>_日本" AS
#       SELECT 1 AS n。作れたら（または開始できて FAILED になったら）
#       DROP TABLE IF EXISTS <DB>.`<TT>_日本` で消し、SHOW TABLES で消えたことを
#       確かめる（trap にも同じ DROP を保険として持つ）。準備の CTAS と同じく、
#       S3 の OUTPUT 配下に書かれたデータファイルは DROP では消えない。
#     DROP・ALTER は、これらの後始末を除いて実在しない名前にだけ投げる。ROUND=3 では
#     PROBE_DDL=0 でも接頭辞 athena_local_probe_204 のテーブルが無いことを確かめる。
#   ROUND=4 では、準備のテーブルのほかに W4 群（PROBE_DDL=1 のときだけ）のビューが
#   ある。CREATE VIEW <DB>.<TT>_v AS SELECT 1 AS n で作り、DROP VIEW IF EXISTS
#   <DB>.<TT>_v で消して、SHOW TABLES と SHOW VIEWS で消えたことを確かめる（trap にも
#   同じ DROP VIEW を保険として持つ）。ビューはデータファイルを書かない。DROP・ALTER は
#   これを除いて実在しない名前にだけ投げる。<NODB> への DESCRIBE・SHOW COLUMNS は
#   読むだけで、DB は作らない。
#   ROUND=5 では、準備のテーブルのほかに Y1 群の CREATE TABLE（実在しない <TT>_nope3 に
#   4 部・5 部の名前で 4 本。本物では開始時に弾かれるはず）がある。想定外に成功したら、
#   その場で DROP TABLE IF EXISTS <DB>.<TT>_nope3 を投げて消す（trap にも保険）。
#   PROBE_DDL=0 でも接頭辞 athena_local_probe_204 のテーブルが無いことを確かめる。
#   <NOCAT> はカタログを作らず、QueryExecutionContext に渡すだけ。
#
# 課金について: スキャンの無いクエリだけ。DESCRIBE・DESC・SHOW CREATE TABLE・
# SHOW COLUMNS・MSCK REPAIR TABLE・ALTER TABLE・DROP TABLE・SHOW TABLES・
# SHOW DATABASES・SHOW VIEWS・DROP DATABASE・CREATE VIEW・DROP VIEW はどれもメタデータ
# だけを見る／書く文で、実データの
# スキャンは無い。準備の CTAS（PROBE_DDL=1 のときだけ）・V6 の CTAS（1 行）・
# U3／V7 の SELECT（S3 Tables、LIMIT 1）・U7／V3／V5 の CREATE TABLE（0 行）も、
# スキャンや書き込みは軽微。Athena の最小課金 × クエリ数の見込み。
#
# 本物への呼び出し回数の見込み（StartQueryExecution のみ。GetQueryExecution・
# GetQueryResults・S3 への呼び出しは含めない。課金には影響しない）:
#
#   [ROUND=1]
#   preflight 1
#   + PROBE_DDL=1 のときのセットアップ 1・後始末 1（既定はこちら）
#   + D 群（DESCRIBE、n0〜n11）12
#   + E 群（DESC、6 形）6
#   + C 群（SHOW CREATE TABLE、n0〜n11）12
#   + L 群（SHOW COLUMNS FROM、6 形 + SHOW COLUMNS IN）7
#   + X 群（DROP TABLE、6 形 + IF EXISTS 引用 1 + IF EXISTS 無引用の対照 1）8
#   + A 群（ALTER TABLE、5 種 × 引用/無引用）10
#   + M 群（MSCK REPAIR TABLE、引用/無引用）2
#   + P 群（文言の位置の規則）8
#   = 68。S3TABLES_* が 3 つとも揃っていればさらに 4 本増え、72 になる。
#
#   [ROUND=2]
#   preflight 1 + セットアップ 1・後始末 1
#   + U1 群（8 + DROP 2）10
#   + U2 群（4 形 × 2 操作 8 + IF EXISTS 対 2）10
#   + U3 群（S3TABLES_* が揃うときだけ）10
#   + U4 群（先頭・区切りの空白）10
#   + U5 群（非 ASCII の位置）3
#   + U6 群（DESCRIBE の変種）3
#   + U7 群（3 対 6。CREATE TABLE の対照が想定外に成功すれば後始末が最大 2 本増える）6
#   = 45（S3TABLES_* 無し）／55（S3TABLES_* あり）。
#
#   [ROUND=3]
#   preflight 1 + セットアップ 1・後始末 1
#   + V1 群（2 形 × 2 操作）4
#   + V2 群（4 文 × 5 形）20
#   + V3 群（SHOW TABLES IN 4 + CREATE TABLE 6 + IF NOT EXISTS 2）12
#   + V4 群（実在しない ASCII の名前）5
#   + V5 群（実在しない "日本"）9
#   + V6 群（PROBE_DDL=1 のときだけ）CTAS 1。作れたら + 測定 4 + DROP 1 +
#     SHOW TABLES 1 で 7（開始できて FAILED なら DROP と SHOW TABLES が乗って 3）
#   + V7 群（S3TABLES_* が揃うときだけ）診断 2 + U3 と同じ 10 で 12
#   = 54（S3TABLES_* 無し・CTAS が開始時に弾かれた）／60（S3TABLES_* 無し・CTAS 成功）
#     ／66・72（それぞれ S3TABLES_* あり）。PROBE_DDL=0 なら V6 の 1 本が減る。
#   V3・V5 の CREATE TABLE が想定外に成功すれば、後始末が最大 9 本増える。
#
#   [ROUND=4]
#   preflight 1 + セットアップ 1・後始末 1
#   + W1 群（8 形 × DESCRIBE/SHOW COLUMNS）16
#   + W2 群（4 部の文言の細部）6。S3TABLES_* が揃えば + 1
#   + W3 群（4 部・5 部の DROP・ALTER）3
#   + W4 群（PROBE_DDL=1 のときだけ）CREATE VIEW 1。作れたら + 測定 4 + DROP VIEW 1 +
#     SHOW TABLES 1 + SHOW VIEWS 1 で 8（開始できて FAILED なら確かめまで乗って 4）
#   + W5 群（存在の確認と引用符の順序）4
#   = 33（S3TABLES_* 無し・CREATE VIEW が開始時に弾かれた）／40（S3TABLES_* 無し・
#     CREATE VIEW 成功）／34・41（それぞれ S3TABLES_* あり）。PROBE_DDL=0 なら
#     W4 の 1 本とセットアップ・後始末の 2 本が減って 30（S3TABLES_* ありで 31）。
#
#   [ROUND=5]
#   preflight 1 + セットアップ 1・後始末 1
#   + Y1 群（SHOW CREATE TABLE 4 + SHOW TABLES IN 3 + CREATE TABLE 4）11
#   + Y2 群（SHOW TABLES IN の 3 部）4
#   + Y3 群（Context の Catalog が実在しない）9
#   + Y4 群（4 部の引用符付きの大文字）5
#   = 32。PROBE_DDL=0 ならセットアップ・後始末の 2 本が減って 30。Y1 の CREATE TABLE が
#   想定外に成功すれば、後始末が最大 4 本増える。
#
#   どのラウンドも、開始時に弾かれた（START_FAILED）項目があっても追加の呼び出しは
#   しない（AthenaErrorCode・Message は同じ標準エラーからそのまま抜くため）。
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く。前の回の結果と混ざらない。
#
# 項目ごとに次を保存する（取れたものだけ）。
#   <label>.sql            投げた SQL そのもの（**DB 名・テーブル名を含む。実名を含む**。
#                          U4/U5 群は実際のタブ・CR・改行・非 ASCII をそのまま含む）
#   <label>.start.err      StartQueryExecution の標準エラー（開始時に弾かれた証拠）。
#                          **一切加工せず AWS CLI の出力そのまま保存する**（実際の制御
#                          文字か `\t` のような 2 文字表記かを、ファイルの中身では
#                          失わない）。Message と AthenaErrorCode は summary 用にここから
#                          抜くときだけ、実際の制御文字を <TAB>/<CR>/<LF> という目に
#                          見える形に変える（start_err_message を参照）
#   <label>.execution.json GetQueryExecution の生の応答（開始できた項目だけ）
#   <label>.execution.err  GetQueryExecution の標準エラー
#   <label>.reason.txt     StateChangeReason と AthenaError（**実名を含みうる。貼る前に確認**）
#   <label>.rows.txt       ROUND=3 の V7 の診断（v7-diag-*）と V6 の確かめ（v6-verify）、
#                          ROUND=4 の W4 の確かめ（w4-verify-*）で
#                          GetQueryResults から取った 1 列目の全行（**実名そのもの**）
#
# summary の決め手になる列は state・statement_type/substatement_type・
# start_message/start_athena_error_code（開始時に弾かれた項目）・
# error_category/error_type/error_message（開始できて FAILED になった項目）。
# DB 名・出力先・バケット名・対象テーブル名・S3 Tables の名前は出さず、プレースホルダに
# 畳む。summary.tsv / summary.txt はそのまま貼れる。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください}"
: "${DB:?DB にデータベース名を設定してください}"
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_DIR=${OUT_DIR:-${DEV_HOST_HOME:-$HOME}/athena-quoted-names-measurements}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}
PROBE_DDL=${PROBE_DDL:-1}
ROUND=${ROUND:-1}
S3TABLES_CATALOG=${S3TABLES_CATALOG:-}
S3TABLES_NS=${S3TABLES_NS:-}
S3TABLES_TABLE=${S3TABLES_TABLE:-}
# S3TABLES_CATALOG が s3tablescatalog/<バケット> の形なら、そのバケット名（伏せ字用）。
S3TABLES_BUCKET=""
case "$S3TABLES_CATALOG" in
  */*) S3TABLES_BUCKET=${S3TABLES_CATALOG#*/} ;;
esac

PROBE_PREFIX=athena_local_probe_204
TABLE_HIVE=$PROBE_PREFIX
NOPE=${PROBE_PREFIX}_nope
NOPE2=${PROBE_PREFIX}_nope2
NOPE3=${PROBE_PREFIX}_nope3
# 非 ASCII の名前（ROUND=3 の V5・V6 群）。u5-jp と同じくバイト列で組み、UTF-8 のまま
# 送る。JP は「日本」、TABLE_JP は V6 で作る「athena_local_probe_204_日本」。
JP=$'\xe6\x97\xa5\xe6\x9c\xac'
TABLE_JP=${PROBE_PREFIX}_$JP
# ROUND=4 の名前。NODB は実在しない DB 名（W1。読むだけで作らない）、VIEW_NAME は
# W4 で作って消すビュー。
NODB=${PROBE_PREFIX}_nodb
VIEW_NAME=${PROBE_PREFIX}_v
# ROUND=5 の名前。NOCAT は実在しないカタログ名（Y3 の QueryExecutionContext に渡す。
# 読むだけで作らない）、NOCAT_MIXED はその大文字混じりの綴り。
NOCAT=nocatalog_212
NOCAT_MIXED=NoCatalog_212

D_FORMS="n0 n1 n2 n3 n4 n5 n6 n7 n8 n9 n10 n11"
E_FORMS="n0 n1 n4 n5 n6 n10"
C_FORMS="$D_FORMS"
L_FORMS="n0 n1 n4 n5 n6 n10"
X_FORMS="n0 n1 n4 n5 n6 n10"

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\tstatement_type\tsubstatement_type\tstart_message\tstart_athena_error_code\terror_category\terror_type\terror_message\treason_line\tnote\n' > "$SUMMARY"
echo "出力先: $RUN_DIR"

# StartQueryExecution を実際に呼んだ回数（再試行も含む）。summary.txt の冒頭に出す。
START_CALL_FILE="$RUN_DIR/.start-calls"
: > "$START_CALL_FILE"
# PROBE_DDL=1 のセットアップに着手したかどうか。trap での後始末に使う。
DDL_ATTEMPTED=0
# ROUND=2 の U7 群・ROUND=3 の V3 群で、<TT>_nope3 への CREATE TABLE が想定外に
# 成功したかどうか。trap での後始末に使う（本編の *-cleanup で消せなかったときの保険）。
NOPE3_CREATED=0
# ROUND=3 の V5 群で CREATE TABLE "日本" が想定外に成功したかどうか（同上）。
JP_CREATED=0
# ROUND=3 の V6 群の CTAS で <TT>_日本 ができた（かもしれない）かどうか。
# v6-verify の SHOW TABLES で消えたと確かめられたら 0 に戻す。
V6_CREATED=0
# ROUND=4 の W4 群の CREATE VIEW で <TT>_v ができた（かもしれない）かどうか。
# w4-verify-* の SHOW TABLES と SHOW VIEWS で消えたと確かめられたら 0 に戻す。
W4_CREATED=0

# StartQueryExecution に渡す QueryExecutionContext。ふだんは CATALOG・DB で、
# run_in_ctx で 1 文だけ差し替える（ROUND=3 の V7 の診断）。
QE_CONTEXT="Catalog=$CATALOG,Database=$DB"

# trap の後始末で 1 文だけ投げる（結果は確かめない）。
cleanup_drop() {
  aws athena start-query-execution --region "$REGION" \
    --query-string "$1" \
    --query-execution-context "Catalog=$CATALOG,Database=$DB" \
    --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
}

# 中間ファイル（.tmp-*）は、途中で止めても残らないよう trap で消す。セットアップに
# 着手していたら、ベストエフォートで「無引用 + IF EXISTS」の後始末も投げる
# （本編の z-drop-hive・*-cleanup・v6-drop で消せなかったときの保険。cleanup 自体は
# 結果を確かめない）。
cleanup() {
  rm -f "$RUN_DIR"/.tmp-*
  if [ "$DDL_ATTEMPTED" = 1 ]; then
    cleanup_drop "DROP TABLE IF EXISTS $TABLE_HIVE"
  fi
  if [ "$NOPE3_CREATED" = 1 ]; then
    cleanup_drop "DROP TABLE IF EXISTS $NOPE3"
  fi
  if [ "$JP_CREATED" = 1 ]; then
    cleanup_drop "DROP TABLE IF EXISTS \`$JP\`"
  fi
  if [ "$V6_CREATED" = 1 ]; then
    cleanup_drop "DROP TABLE IF EXISTS $DB.\`$TABLE_JP\`"
  fi
  if [ "$W4_CREATED" = 1 ]; then
    cleanup_drop "DROP VIEW IF EXISTS $DB.$VIEW_NAME"
  fi
}
trap cleanup EXIT

# 実名（DB 名・出力先・バケット名・アカウント ID）を置換して隠す。
# アカウント ID は、前後が数字でない 12 桁の数字として伏せる（ラウンド 2 の
# SCHEMA_NOT_FOUND の文言 `catalog:<アカウント ID>:...` に出ていた）。
# DB 名の大文字形（ROUND=4 の W1 で投げる）は <DB_UPPER> にする。伏せ字の置き換え先は
# 大文字なので、小文字の DB 名が置き換え先の中に当たらないよう、大文字形を先に置き換える。
OUTPUT_BUCKET=${OUTPUT#s3://}
OUTPUT_BUCKET=${OUTPUT_BUCKET%%/*}
redact() {
  local s=$1
  s=${s//${DB^^}/<DB_UPPER>}
  s=${s//$DB/<DB>}
  s=${s//$OUTPUT/<OUTPUT>}
  s=${s//$OUTPUT_BUCKET/<BUCKET>}
  printf '%s' "$s" | sed -E 's/(^|[^0-9])[0-9]{12}([^0-9]|$)/\1<ACCOUNT_ID>\2/g'
}

# 標準入力から、対象テーブル名（TARGET_TABLE）・接頭辞 athena_local_probe_204・
# S3 Tables の実名（設定されていれば）を置換して隠す。summary.txt に流し込む
# 文言・エラー文言・SQL の伏せ字表示に使う。
mask_names() {
  local s
  s=$(cat)
  # 大文字形（ROUND=4 の W1）を先に置き換える（redact と同じ理由）。
  if [ -n "${TARGET_TABLE:-}" ]; then
    s=${s//${TARGET_TABLE^^}/<TT_UPPER>}
  fi
  s=${s//${PROBE_PREFIX^^}/<PROBE_UPPER>}
  if [ -n "${TARGET_TABLE:-}" ]; then
    s=${s//$TARGET_TABLE/<TT>}
  fi
  s=${s//$PROBE_PREFIX/<PROBE>}
  if [ -n "$S3TABLES_CATALOG" ]; then
    s=${s//$S3TABLES_CATALOG/<S3TABLES_CATALOG>}
    # カタログ名の `/` より後ろ（S3 Tables のバケット名）が単独で出ても伏せる。
    if [ -n "$S3TABLES_BUCKET" ]; then
      s=${s//$S3TABLES_BUCKET/<S3TABLES_BUCKET>}
    fi
  fi
  if [ -n "$S3TABLES_NS" ]; then
    s=${s//$S3TABLES_NS/<S3TABLES_NS>}
  fi
  if [ -n "$S3TABLES_TABLE" ]; then
    s=${s//$S3TABLES_TABLE/<S3TABLES_TABLE>}
  fi
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

# start.err から Message と AthenaErrorCode を抜く。AWS CLI は開始時に弾かれた
# StartQueryExecution の標準エラーに、追加の呼び出しをしなくても両方とも出す
# （#200 の実例 `~/athena-keyword-boundary-measurements/run-20260925-055931/b1.start.err`）。
#   aws: [ERROR]: An error occurred (InvalidRequestException) when calling the
#   StartQueryExecution operation: line 1:9: no viable alternative at input 'DESCRIBE"<T>"'
#
#   Additional error details:
#   AthenaErrorCode: MALFORMED_QUERY
# Message は「operation: 」より後ろ、「\n\nAdditional error details:」の手前まで
# （無ければファイル末尾まで）を取る。AthenaErrorCode は「AthenaErrorCode: 」で
# 始まる行から取る。どちらも見つからなければ "-"。
#
# ラウンド 2 の U4/U5 群は SQL に実際のタブ・CR・改行・コメントを挟むので、
# Message の中にそれが実際の制御文字のまま echo back されることがある
# （#204 の依頼どおり「実際の制御文字か \t などの 2 文字表記か」を区別できるよう、
# start.err そのものは加工せず保存し、summary に載せるときだけ <TAB>/<CR>/<LF> という
# 目に見える形に変える。始めに <BACKSLASH> へ変えておくことで、message がもともと
# 持っていた 2 文字表記の `\t` などと、実際の制御文字を変換した <TAB> を混同しない）。
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

# execution.json から AthenaError の ErrorCategory / ErrorType / ErrorMessage を
# タブ区切りで返す（無ければ 3 つとも "-"）。
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

# summary.tsv に 1 行積む。列の並びはヘッダと同じ 11 列で固定する。
emit_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$SUMMARY"
}

# 項目を未測定として summary に 1 行残す。全体を止めずに次へ進む。
skip() {
  local label=$1 note=$2
  echo "== $label: 未測定（$note）"
  emit_row "$label" "SKIPPED" - - - - - - - - "$(sanitize "$note")"
}

# 名前の形を返す（設計の n0〜n11 は #204 の依頼文どおり、n12〜n14 はラウンド 2 の
# U1・U2 群で使う「3 部のうち一部だけ引用符付き」の形）。
#   n0  無引用                          t
#   n1  引用符付き（小文字）            "t"
#   n2  引用符付き（大文字）            "T"
#   n3  db 修飾・無引用                 db.t
#   n4  db・テーブルとも引用符付き      "db"."t"
#   n5  db 無引用・テーブル引用符付き   db."t"
#   n6  db 引用符付き・テーブル無引用   "db".t
#   n7  catalog 修飾（3 部・無引用）    awsdatacatalog.db.t
#   n8  catalog だけ引用符付き（大小混在） "AwsDataCatalog".db.t
#   n9  3 部とも引用符付き              "awsdatacatalog"."db"."t"
#   n10 バッククォート（テーブルのみ）  `t`
#   n11 バッククォート（db・テーブル）  `db`.`t`
#   n12 catalog 無引用・db 引用符付き・table 無引用   awsdatacatalog."db".t
#   n13 catalog 無引用・db 無引用・table 引用符付き   awsdatacatalog.db."t"
#   n14 catalog だけ引用符付き（小文字）・残り無引用  "awsdatacatalog".db.t
#   n15 catalog 無引用・db と table 引用符付き        awsdatacatalog."db"."t"（ラウンド 3 の V1）
name_form() {
  local idx=$1 base=$2 upper
  upper=$(printf '%s' "$base" | tr '[:lower:]' '[:upper:]')
  case "$idx" in
    n0) printf '%s' "$base" ;;
    n1) printf '"%s"' "$base" ;;
    n2) printf '"%s"' "$upper" ;;
    n3) printf '%s.%s' "$DB" "$base" ;;
    n4) printf '"%s"."%s"' "$DB" "$base" ;;
    n5) printf '%s."%s"' "$DB" "$base" ;;
    n6) printf '"%s".%s' "$DB" "$base" ;;
    n7) printf 'awsdatacatalog.%s.%s' "$DB" "$base" ;;
    n8) printf '"AwsDataCatalog".%s.%s' "$DB" "$base" ;;
    n9) printf '"awsdatacatalog"."%s"."%s"' "$DB" "$base" ;;
    n10) printf '`%s`' "$base" ;;
    n11) printf '`%s`.`%s`' "$DB" "$base" ;;
    n12) printf 'awsdatacatalog."%s".%s' "$DB" "$base" ;;
    n13) printf 'awsdatacatalog.%s."%s"' "$DB" "$base" ;;
    n14) printf '"awsdatacatalog".%s.%s' "$DB" "$base" ;;
    n15) printf 'awsdatacatalog."%s"."%s"' "$DB" "$base" ;;
    *) printf '%s' "$base" ;;
  esac
}

# 4 部の修飾名 awsdatacatalog.<db>.<base>.n の形を返す（ラウンド 3 の V2 群）。
#   p0 無引用（対照）          awsdatacatalog.db.t.n
#   p1 1 部目だけ引用符付き    "awsdatacatalog".db.t.n
#   p2 2 部目だけ引用符付き    awsdatacatalog."db".t.n
#   p3 3 部目だけ引用符付き    awsdatacatalog.db."t".n
#   p4 4 部目だけ引用符付き    awsdatacatalog.db.t."n"
four_part_form() {
  local idx=$1 base=$2
  case "$idx" in
    p0) printf 'awsdatacatalog.%s.%s.n' "$DB" "$base" ;;
    p1) printf '"awsdatacatalog".%s.%s.n' "$DB" "$base" ;;
    p2) printf 'awsdatacatalog."%s".%s.n' "$DB" "$base" ;;
    p3) printf 'awsdatacatalog.%s."%s".n' "$DB" "$base" ;;
    p4) printf 'awsdatacatalog.%s.%s."n"' "$DB" "$base" ;;
    *) printf '%s' "$base" ;;
  esac
}

# ラベルを指定して 1 文を実行する。開始できなければ、AthenaErrorCode・Message を
# その場の start.err からそのまま抜く（追加の呼び出しはしない。上の start_err_message /
# start_err_code を参照）。開始できたら終端状態まで待って StatementType・
# SubstatementType・FAILED の理由を採る。
run() {
  local label=$1 sql=$2
  local id state stype sub note reason_line
  local start_msg="-" start_code="-" err_cat="-" err_type="-" err_msg="-"

  printf '%s\n' "$sql" > "$RUN_DIR/$label.sql"
  id=$(start_query_retry "$label" "$sql")
  LAST_ATTEMPTS=$(read_attempts "$label")

  if [ -z "${id:-}" ]; then
    note="attempts=$LAST_ATTEMPTS; $(first_err_line "$RUN_DIR/$label.start.err")"
    start_msg=$(start_err_message "$RUN_DIR/$label.start.err")
    start_code=$(start_err_code "$RUN_DIR/$label.start.err")
    echo "== $label: 開始できませんでした（試行 $LAST_ATTEMPTS 回）。AthenaErrorCode=$start_code"
    emit_row "$label" "START_FAILED" - - "$start_msg" "$start_code" - - - - "$(sanitize "$note")"
    return 1
  fi

  state=$(poll_until_terminal "$id")

  aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
    > "$RUN_DIR/$label.execution.json" 2> "$RUN_DIR/$label.execution.err"
  write_reason "$RUN_DIR/$label.execution.json" "$RUN_DIR/$label.reason.txt"
  reason_line=$(reason_first_line "$RUN_DIR/$label.execution.json")

  IFS=$'\t' read -r stype _ sub < <(read_execution_fields "$RUN_DIR/$label.execution.json")

  note="attempts=$LAST_ATTEMPTS"
  case "$state" in
    FAILED | CANCELLED)
      IFS=$'\t' read -r err_cat err_type err_msg < <(athena_error_fields_of "$RUN_DIR/$label.execution.json")
      err_msg=$(sanitize "$(hide "$err_msg")")
      ;;
  esac

  echo "== $label  state=$state  stype=$stype/$sub  error=$err_cat/$err_type"
  emit_row "$label" "$state" "$stype" "$sub" "$start_msg" "$start_code" \
    "$err_cat" "$err_type" "$err_msg" "$reason_line" "$(sanitize "$note")"
  [ "$state" = SUCCEEDED ]
}

# QueryExecutionContext を $1 に差し替えて run を 1 回呼ぶ（ROUND=3 の V7 の診断）。
# 差し替えた context は <label>.context.txt に残す（伏せ字は summary 側でかける）。
run_in_ctx() {
  local ctx=$1 label=$2 saved=$QE_CONTEXT rc
  shift
  printf '%s\n' "$ctx" > "$RUN_DIR/$label.context.txt"
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

# CREATE TABLE を投げ、想定外に成功したら直後に後始末の DROP を <label>-cleanup として
# 投げる（U7 と同じ扱い）。$4 は trap の保険に使うフラグの変数名で、成功したら 1 に、
# 後始末が SUCCEEDED なら 0 に戻す。CREATE TABLE が失敗したら後始末は未測定の行だけ残す。
run_create_guarded() {
  local label=$1 sql=$2 cleanup_sql=$3 flag=$4
  if run "$label" "$sql"; then
    printf -v "$flag" '%s' 1
    run "$label-cleanup" "$cleanup_sql"
    if succeeded "$label-cleanup"; then
      printf -v "$flag" '%s' 0
    fi
  else
    skip "$label-cleanup" "CREATE TABLE が失敗したため後始末不要"
  fi
}

# summary に、測定ではない確かめの結果を 1 行残す（state は INFO）。
info_row() {
  local label=$1 note=$2
  echo "== $label: $note"
  emit_row "$label" "INFO" - - - - - - - - "$(sanitize "$note")"
}

# --- preflight ---------------------------------------------------------------

if ! run probe-show-tables "SHOW TABLES"; then
  echo
  echo "SHOW TABLES が通りませんでした。DB か CATALOG の指定が実在しません。"
  echo "理由: $RUN_DIR/probe-show-tables.reason.txt"
  if run available-databases "SHOW DATABASES"; then
    echo "選べるデータベースの一覧は $RUN_DIR/available-databases.execution.json の"
    echo "GetQueryExecution 応答からは分からない（結果は GetQueryResults 側）。"
    echo "aws athena get-query-results --query-execution-id <id> で確認してください。"
  fi
  exit 1
fi

# SHOW TABLES の結果を GetQueryResults でページングしながら全件取る（S3 は使わない）。
SHOW_TABLES_ID=$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1]))["QueryExecution"]["QueryExecutionId"])
except Exception:
    print("")' "$RUN_DIR/probe-show-tables.execution.json" 2>/dev/null)

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

if [ -z "$SHOW_TABLES_ID" ]; then
  echo
  echo "SHOW TABLES の QueryExecutionId が取れませんでした。止まります。"
  exit 1
fi
fetch_all_table_names "$SHOW_TABLES_ID" "$RUN_DIR/tables.txt"

# ROUND=3・5 は PROBE_DDL=0 でも CREATE TABLE（V3・Y1）と後始末の DROP を <TT>_nope3 に投げる
# ので、同じく確かめる。接頭辞の部分一致なので、V6 の <TT>_日本 の残りもここで止まる。
if { [ "$PROBE_DDL" = 1 ] || [ "$ROUND" = 3 ] || [ "$ROUND" = 5 ]; } && grep -qi "$PROBE_PREFIX" "$RUN_DIR/tables.txt"; then
  echo
  echo "このデータベースに ${PROBE_PREFIX}* という名前のテーブルが既にあります。"
  echo "上書き・削除してしまうので、何も作らずに止まります。一覧: $RUN_DIR/tables.txt"
  exit 1
fi

# --- 対象テーブル（<t>）を決める -----------------------------------------------
# PROBE_DDL=1 のときは下で作る Hive テーブル。0 のときは SHOW TABLES の 1 件目
# （実在のテーブル）。名前は小文字で使う。
TARGET_TABLE=""
if [ "$PROBE_DDL" = 1 ]; then
  TARGET_TABLE=$TABLE_HIVE
else
  TARGET_TABLE=$(head -n1 "$RUN_DIR/tables.txt" 2>/dev/null | tr -d '\r' | tr '[:upper:]' '[:lower:]')
fi

# --- セットアップ（PROBE_DDL=1 のときだけ） ------------------------------------

D_SETUP_OK=0
if [ "$PROBE_DDL" = 1 ]; then
  DDL_ATTEMPTED=1
  if run d0-setup-hive "CREATE TABLE $DB.$TABLE_HIVE AS SELECT 1 AS n, 'x' AS s, 10 AS x"; then
    D_SETUP_OK=1
  else
    echo "== d0-setup-hive: 準備テーブルが作れませんでした。対象テーブルが要る群は未測定にします。"
    TARGET_TABLE=""
  fi
else
  D_SETUP_OK=1
fi

if [ -z "$TARGET_TABLE" ]; then
  echo "== 対象テーブルが決められないため、D/E/C/L/M 群と P 群の一部を未測定にします。"
fi

if [ "$ROUND" = 1 ]; then

# --- D 群（DESCRIBE <t>） -------------------------------------------------------

if [ -n "$TARGET_TABLE" ]; then
  for n in $D_FORMS; do
    run "d-$n" "DESCRIBE $(name_form "$n" "$TARGET_TABLE")"
  done
else
  for n in $D_FORMS; do skip "d-$n" "対象テーブルが無いため未測定"; done
fi

# --- E 群（DESC <t>） ------------------------------------------------------------

if [ -n "$TARGET_TABLE" ]; then
  for n in $E_FORMS; do
    run "e-$n" "DESC $(name_form "$n" "$TARGET_TABLE")"
  done
else
  for n in $E_FORMS; do skip "e-$n" "対象テーブルが無いため未測定"; done
fi

# --- C 群（SHOW CREATE TABLE <t>） ----------------------------------------------

if [ -n "$TARGET_TABLE" ]; then
  for n in $C_FORMS; do
    run "c-$n" "SHOW CREATE TABLE $(name_form "$n" "$TARGET_TABLE")"
  done
else
  for n in $C_FORMS; do skip "c-$n" "対象テーブルが無いため未測定"; done
fi

# --- L 群（SHOW COLUMNS FROM/IN <t>） --------------------------------------------

if [ -n "$TARGET_TABLE" ]; then
  for n in $L_FORMS; do
    run "l-$n" "SHOW COLUMNS FROM $(name_form "$n" "$TARGET_TABLE")"
  done
  run "l-in" "SHOW COLUMNS IN \"$TARGET_TABLE\""
else
  for n in $L_FORMS; do skip "l-$n" "対象テーブルが無いため未測定"; done
  skip "l-in" "対象テーブルが無いため未測定"
fi

# --- X 群（DROP TABLE <nope の形>） ----------------------------------------------

for n in $X_FORMS; do
  run "x-$n" "DROP TABLE $(name_form "$n" "$NOPE")"
done
run "x-ifq" "DROP TABLE IF EXISTS \"$NOPE\""
run "x-ifu" "DROP TABLE IF EXISTS $NOPE"

# --- A 群（ALTER TABLE <nope の形> ...） -----------------------------------------
# すべて実在しない名前 athena_local_probe_204_nope に対して投げる。
# 引用符付き（n1 "nope"）と対照の無引用（n0 nope）の対で 5 種。

run_alt_pair() {
  local key=$1 stmt=$2
  run "alt-$key-q" "ALTER TABLE \"$NOPE\" $stmt"
  run "alt-$key-u" "ALTER TABLE $NOPE $stmt"
}

run_alt_pair addcols "ADD COLUMNS (m int)"
run_alt_pair addcol "ADD COLUMN m int"
run_alt_pair dropcol "DROP COLUMN m"
run_alt_pair rename "RENAME TO $NOPE2"
run_alt_pair settbl "SET TBLPROPERTIES ('k'='v')"

# --- M 群（MSCK REPAIR TABLE <t>） -----------------------------------------------

if [ -n "$TARGET_TABLE" ]; then
  run "msck-q" "MSCK REPAIR TABLE \"$TARGET_TABLE\""
  run "msck-u" "MSCK REPAIR TABLE $TARGET_TABLE"
else
  skip "msck-q" "対象テーブルが無いため未測定"
  skip "msck-u" "対象テーブルが無いため未測定"
fi

# --- P 群（文言の位置の規則） -----------------------------------------------------

if [ -n "$TARGET_TABLE" ]; then
  run "pos-lower" "describe \"$TARGET_TABLE\""
  run "pos-dblspace" "DESCRIBE  \"$TARGET_TABLE\""
  # 改行を挟む形。$'...' は変数展開しないので、改行だけを断片にして隣接させて連結する
  # （tools/measure/leading-comment.sh の注意のとおり）。
  run "pos-newline" $'DESCRIBE\n'"\"$TARGET_TABLE\""
  run "pos-leadspace" "  DESCRIBE \"$TARGET_TABLE\""
  run "pos-leadcomment" "/* c */ DESCRIBE \"$TARGET_TABLE\""
  run "pos-trailspace" "SHOW CREATE TABLE \"$TARGET_TABLE\" "
else
  for label in pos-lower pos-dblspace pos-newline pos-leadspace pos-leadcomment pos-trailspace; do
    skip "$label" "対象テーブルが無いため未測定"
  done
fi
run "pos-drop-dblspace" "DROP TABLE  \"$NOPE\""
run "pos-drop-lower" "drop table \"$NOPE\""

# --- S3 Tables（任意。環境変数が 3 つとも揃ったときだけ） -------------------------

if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ] && [ -n "$S3TABLES_TABLE" ]; then
  run "s3t-desc" "DESCRIBE \"$S3TABLES_CATALOG\".$S3TABLES_NS.$S3TABLES_TABLE"
  run "s3t-show" "SHOW CREATE TABLE \"$S3TABLES_CATALOG\".$S3TABLES_NS.$S3TABLES_TABLE"
  run "s3t-select" "SELECT * FROM \"$S3TABLES_CATALOG\".$S3TABLES_NS.$S3TABLES_TABLE LIMIT 1"
  run "s3t-drop" "DROP TABLE IF EXISTS \"$S3TABLES_CATALOG\".$S3TABLES_NS.nope_204"
else
  for label in s3t-desc s3t-show s3t-select s3t-drop; do
    skip "$label" "未測定（S3TABLES_* 未設定）"
  done
fi

fi # ROUND=1

if [ "$ROUND" = 2 ]; then

# --- U1 群（3 部の名前で途中・末尾だけ引用符付き） --------------------------------
# n12 = awsdatacatalog."<db>".<t>（catalog 無引用・db 引用符付き・table 無引用）
# n13 = awsdatacatalog.<db>."<t>"（catalog 無引用・db 無引用・table 引用符付き）

if [ -n "$TARGET_TABLE" ]; then
  run "u1-desc-n12"    "DESCRIBE $(name_form n12 "$TARGET_TABLE")"
  run "u1-desc-n13"    "DESCRIBE $(name_form n13 "$TARGET_TABLE")"
  run "u1-descd-n12"   "DESC $(name_form n12 "$TARGET_TABLE")"
  run "u1-descd-n13"   "DESC $(name_form n13 "$TARGET_TABLE")"
  run "u1-showc-n12"   "SHOW CREATE TABLE $(name_form n12 "$TARGET_TABLE")"
  run "u1-showc-n13"   "SHOW CREATE TABLE $(name_form n13 "$TARGET_TABLE")"
  run "u1-showcol-n12" "SHOW COLUMNS FROM $(name_form n12 "$TARGET_TABLE")"
  run "u1-showcol-n13" "SHOW COLUMNS FROM $(name_form n13 "$TARGET_TABLE")"
else
  for label in u1-desc-n12 u1-desc-n13 u1-descd-n12 u1-descd-n13 \
    u1-showc-n12 u1-showc-n13 u1-showcol-n12 u1-showcol-n13; do
    skip "$label" "対象テーブルが無いため未測定"
  done
fi
run "u1-drop-n12" "DROP TABLE $(name_form n12 "$NOPE")"
run "u1-drop-n13" "DROP TABLE $(name_form n13 "$NOPE")"

# --- U2 群（ALTER。Trino が受ける RENAME TO / DROP COLUMN で、実在しない名前に） ----
# n14 = "awsdatacatalog".<db>.<nope>（catalog だけ引用符付き・小文字）
# n13（U1 と同じ関数）= awsdatacatalog.<db>."<nope>"

U2_FORMS="n5 n6 n14 n13"
for n in $U2_FORMS; do
  run "u2-$n-rename"  "ALTER TABLE $(name_form "$n" "$NOPE") RENAME TO $NOPE2"
  run "u2-$n-dropcol" "ALTER TABLE $(name_form "$n" "$NOPE") DROP COLUMN m"
done
run "u2-ifq" "ALTER TABLE IF EXISTS \"$NOPE\" RENAME TO $NOPE2"
run "u2-ifu" "ALTER TABLE IF EXISTS $NOPE RENAME TO $NOPE2"

# --- U3 群（S3 Tables。任意。環境変数が 3 つとも揃ったときだけ） -------------------
# <s3>     = "<S3TABLES_CATALOG>".<ns>.<table>（実在する表。ラウンド 1 は名前空間の
#            綴り違いで SCHEMA_NOT_FOUND だったので、今回は正しい値で対照を取り直す）
# <s3nope> = "<S3TABLES_CATALOG>".<ns>.nope_204（実在しない表）

if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ] && [ -n "$S3TABLES_TABLE" ]; then
  S3_NAME="\"$S3TABLES_CATALOG\".$S3TABLES_NS.$S3TABLES_TABLE"
  S3_NOPE_NAME="\"$S3TABLES_CATALOG\".$S3TABLES_NS.nope_204"
  run "u3-select"          "SELECT * FROM $S3_NAME LIMIT 1"
  run "u3-desc"            "DESCRIBE $S3_NAME"
  run "u3-descd"           "DESC $S3_NAME"
  run "u3-showcol"         "SHOW COLUMNS FROM $S3_NAME"
  run "u3-showc"           "SHOW CREATE TABLE $S3_NAME"
  run "u3-desc-nope"       "DESCRIBE $S3_NOPE_NAME"
  run "u3-drop-nope"       "DROP TABLE $S3_NOPE_NAME"
  run "u3-alt-rename-nope" "ALTER TABLE $S3_NOPE_NAME RENAME TO nope_204b"
  run "u3-alt-dropcol-nope" "ALTER TABLE $S3_NOPE_NAME DROP COLUMN m"
  run "u3-desc-allq" "DESCRIBE \"$S3TABLES_CATALOG\".\"$S3TABLES_NS\".\"$S3TABLES_TABLE\""
else
  for label in u3-select u3-desc u3-descd u3-showcol u3-showc u3-desc-nope \
    u3-drop-nope u3-alt-rename-nope u3-alt-dropcol-nope u3-desc-allq; do
    skip "$label" "未測定（S3TABLES_* 未設定）"
  done
fi

# --- U4 群（先頭と区切りの空白。ANSI-C quoting $'...' で作る） --------------------

if [ -n "$TARGET_TABLE" ]; then
  run "u4-leadtab"     $'\t'"DESCRIBE \"$TARGET_TABLE\""
  run "u4-leadnl"      $'\n'"DESCRIBE \"$TARGET_TABLE\""
  run "u4-leadcrlf"    $'\r\n'"DESCRIBE \"$TARGET_TABLE\""
  run "u4-lead2nl"     $'\n\n'"DESCRIBE \"$TARGET_TABLE\""
  run "u4-linecomment" $'-- c\n'"DESCRIBE \"$TARGET_TABLE\""
  run "u4-blockcomment" $'/* a\nb */ '"DESCRIBE \"$TARGET_TABLE\""
  run "u4-septab"      "DESCRIBE"$'\t'"\"$TARGET_TABLE\""
  run "u4-sepcrlf"     "DESCRIBE"$'\r\n'"\"$TARGET_TABLE\""
else
  for label in u4-leadtab u4-leadnl u4-leadcrlf u4-lead2nl u4-linecomment \
    u4-blockcomment u4-septab u4-sepcrlf; do
    skip "$label" "対象テーブルが無いため未測定"
  done
fi
run "u4-drop-leadnl" $'\n'"DROP TABLE \"$NOPE\""
run "u4-drop-sepnl"  "DROP TABLE"$'\n'"\"$NOPE\""

# --- U5 群（非 ASCII の後ろの位置） ------------------------------------------------

if [ -n "$TARGET_TABLE" ]; then
  run "u5-hira"  $'/* \xe3\x81\x82 */ '"DESCRIBE \"$TARGET_TABLE\""
  run "u5-emoji" $'/* \xf0\x9f\x98\x80 */ '"DESCRIBE \"$TARGET_TABLE\""
else
  skip "u5-hira" "対象テーブルが無いため未測定"
  skip "u5-emoji" "対象テーブルが無いため未測定"
fi
run "u5-jp" $'DESCRIBE "\xe6\x97\xa5\xe6\x9c\xac"'

# --- U6 群（DESCRIBE の変種） -----------------------------------------------------

if [ -n "$TARGET_TABLE" ]; then
  run "u6-extended-q"   "DESCRIBE EXTENDED \"$TARGET_TABLE\""
  run "u6-formatted-q"  "DESCRIBE FORMATTED \"$TARGET_TABLE\""
  run "u6-extended-u"   "DESCRIBE EXTENDED $TARGET_TABLE"
else
  for label in u6-extended-q u6-formatted-q u6-extended-u; do
    skip "$label" "対象テーブルが無いため未測定"
  done
fi

# --- U7 群（ほかの文。すべて実在しない名前に対して） -------------------------------

run "u7-showtables-q" "SHOW TABLES IN \"$DB\""
run "u7-showtables-u" "SHOW TABLES IN $DB"
run "u7-dropdb-q" "DROP DATABASE IF EXISTS \"${NOPE}_db\""
run "u7-dropdb-u" "DROP DATABASE IF EXISTS ${NOPE}_db"

if run "u7-createtable-q" "CREATE TABLE \"${NOPE}3\" (n int)"; then
  NOPE3_CREATED=1
  run "u7-createtable-q-cleanup" "DROP TABLE IF EXISTS ${NOPE}3"
  if [ -s "$RUN_DIR/u7-createtable-q-cleanup.reason.txt" ] && grep -q "^State: SUCCEEDED" "$RUN_DIR/u7-createtable-q-cleanup.reason.txt"; then
    NOPE3_CREATED=0
  fi
else
  skip "u7-createtable-q-cleanup" "CREATE TABLE が失敗したため後始末不要"
fi

if run "u7-createtable-u" "CREATE TABLE ${NOPE}3 (n int)"; then
  NOPE3_CREATED=1
  run "u7-createtable-u-cleanup" "DROP TABLE IF EXISTS ${NOPE}3"
  if [ -s "$RUN_DIR/u7-createtable-u-cleanup.reason.txt" ] && grep -q "^State: SUCCEEDED" "$RUN_DIR/u7-createtable-u-cleanup.reason.txt"; then
    NOPE3_CREATED=0
  fi
else
  skip "u7-createtable-u-cleanup" "CREATE TABLE が失敗したため後始末不要"
fi

fi # ROUND=2

# ROUND=3 の V6・V7 群の確かめの結果（summary の冒頭と INFO 行に出す）。
V6_STATUS=""
V7_SELECT_OK=""

if [ "$ROUND" = 3 ]; then

# --- V1 群（3 部の ALTER で途中が引用符付き。実在しない名前に） --------------------
# n12 = awsdatacatalog."<db>".<nope>、n15 = awsdatacatalog."<db>"."<nope>"

V1_FORMS="n12 n15"
for n in $V1_FORMS; do
  run "v1-$n-rename"  "ALTER TABLE $(name_form "$n" "$NOPE") RENAME TO $NOPE2"
  run "v1-$n-dropcol" "ALTER TABLE $(name_form "$n" "$NOPE") DROP COLUMN m"
done

# --- V2 群（4 部の修飾名） -----------------------------------------------------------
# DESCRIBE・SHOW COLUMNS FROM は実在する <TT>、DROP TABLE・ALTER TABLE は <TT>_nope に。

V2_FORMS="p0 p1 p2 p3 p4"
if [ -n "$TARGET_TABLE" ]; then
  for p in $V2_FORMS; do
    run "v2-desc-$p" "DESCRIBE $(four_part_form "$p" "$TARGET_TABLE")"
  done
  for p in $V2_FORMS; do
    run "v2-showcol-$p" "SHOW COLUMNS FROM $(four_part_form "$p" "$TARGET_TABLE")"
  done
else
  for p in $V2_FORMS; do
    skip "v2-desc-$p" "対象テーブルが無いため未測定"
    skip "v2-showcol-$p" "対象テーブルが無いため未測定"
  done
fi
for p in $V2_FORMS; do
  run "v2-drop-$p" "DROP TABLE $(four_part_form "$p" "$NOPE")"
done
for p in $V2_FORMS; do
  run "v2-rename-$p" "ALTER TABLE $(four_part_form "$p" "$NOPE") RENAME TO $NOPE2"
done

# --- V3 群（SHOW TABLES IN と CTAS でない CREATE TABLE の 2 部以上） ----------------

run "v3-showtables-u"  "SHOW TABLES IN awsdatacatalog.$DB"
run "v3-showtables-qq" "SHOW TABLES IN \"awsdatacatalog\".\"$DB\""
run "v3-showtables-uq" "SHOW TABLES IN awsdatacatalog.\"$DB\""
run "v3-showtables-qu" "SHOW TABLES IN \"awsdatacatalog\".$DB"

# n3 = <db>.<nope3>（対照）、n4 = "<db>"."<nope3>"、n5 = <db>."<nope3>"、
# n6 = "<db>".<nope3>、n12 = awsdatacatalog."<db>".<nope3>、n13 = awsdatacatalog.<db>."<nope3>"
V3_CREATE_FORMS="n3 n4 n5 n6 n12 n13"
for n in $V3_CREATE_FORMS; do
  run_create_guarded "v3-create-$n" "CREATE TABLE $(name_form "$n" "$NOPE3") (n int)" \
    "DROP TABLE IF EXISTS $NOPE3" NOPE3_CREATED
done
run_create_guarded "v3-create-ifq" "CREATE TABLE IF NOT EXISTS \"$NOPE3\" (n int)" \
  "DROP TABLE IF EXISTS $NOPE3" NOPE3_CREATED
run_create_guarded "v3-create-ifu" "CREATE TABLE IF NOT EXISTS $NOPE3 (n int)" \
  "DROP TABLE IF EXISTS $NOPE3" NOPE3_CREATED

# --- V4 群（実在しない ASCII の名前を引用符付きで） ---------------------------------

run "v4-desc-n1"    "DESCRIBE $(name_form n1 "$NOPE")"
run "v4-desc-n5"    "DESCRIBE $(name_form n5 "$NOPE")"
run "v4-desc-n6"    "DESCRIBE $(name_form n6 "$NOPE")"
run "v4-desc-n0"    "DESCRIBE $(name_form n0 "$NOPE")"
run "v4-showcol-n1" "SHOW COLUMNS FROM $(name_form n1 "$NOPE")"

# --- V5 群（実在しない非 ASCII の名前 "日本" を DESCRIBE 以外の文に） -----------------
# 「日本」が実在すると DROP・ALTER を実在の表に投げてしまうので、preflight の
# SHOW TABLES の一覧（tables.txt）にあれば群ごと未測定にする。

V5_LABELS="v5-desc v5-descd v5-desc-db v5-showcol v5-drop v5-rename v5-showc v5-showtables v5-create v5-create-cleanup"
if grep -Fxq "$JP" "$RUN_DIR/tables.txt"; then
  for label in $V5_LABELS; do
    skip "$label" "未測定（<DB> に同名の非 ASCII のテーブルが実在する）"
  done
else
  run "v5-desc"       "DESCRIBE \"$JP\""
  run "v5-descd"      "DESC \"$JP\""
  run "v5-desc-db"    "DESCRIBE $DB.\"$JP\""
  run "v5-showcol"    "SHOW COLUMNS FROM \"$JP\""
  run "v5-drop"       "DROP TABLE \"$JP\""
  run "v5-rename"     "ALTER TABLE \"$JP\" RENAME TO $NOPE2"
  run "v5-showc"      "SHOW CREATE TABLE \"$JP\""
  run "v5-showtables" "SHOW TABLES IN \"$JP\""
  run_create_guarded "v5-create" "CREATE TABLE \"$JP\" (n int)" \
    "DROP TABLE IF EXISTS \`$JP\`" JP_CREATED
fi

# --- V6 群（実在する非 ASCII の名前。PROBE_DDL=1 のときだけ） -----------------------
# <TT>_日本 を CTAS で作って測り、バッククォートの DROP で消し、SHOW TABLES で確かめる。

V6_MEASURE_LABELS="v6-desc-n1 v6-desc-n5 v6-showcol-n1 v6-desc-n10"
if [ "$PROBE_DDL" != 1 ]; then
  for label in v6-ctas $V6_MEASURE_LABELS v6-drop v6-verify; do
    skip "$label" "未測定（PROBE_DDL=0 では非 ASCII のテーブルを作らない）"
  done
else
  # 開始できたかどうかが分かるまでは、できたものとして trap の保険を掛けておく。
  V6_CREATED=1
  if run "v6-ctas" "CREATE TABLE $(name_form n5 "$TABLE_JP") AS SELECT 1 AS n"; then
    run "v6-desc-n1"    "DESCRIBE $(name_form n1 "$TABLE_JP")"
    run "v6-desc-n5"    "DESCRIBE $(name_form n5 "$TABLE_JP")"
    run "v6-showcol-n1" "SHOW COLUMNS FROM $(name_form n1 "$TABLE_JP")"
    run "v6-desc-n10"   "DESCRIBE $(name_form n10 "$TABLE_JP")"
  else
    for label in $V6_MEASURE_LABELS; do
      skip "$label" "未測定（非 ASCII のテーブルを作れなかった）"
    done
  fi

  if [ ! -s "$RUN_DIR/v6-ctas.execution.json" ]; then
    # 開始時に弾かれた（StartQueryExecution が ID を返さなかった）ので、何もできていない。
    V6_CREATED=0
    V6_STATUS="CTAS が開始時に弾かれたので作られていない"
    skip "v6-drop" "CTAS が開始時に弾かれたため後始末不要"
    skip "v6-verify" "CTAS が開始時に弾かれたため後始末不要"
  else
    # 作れた（または開始できて FAILED になった）ので、念のため消して確かめる。
    run "v6-drop" "DROP TABLE IF EXISTS $DB.\`$TABLE_JP\`"
    if run "v6-verify" "SHOW TABLES"; then
      fetch_all_table_names "$(query_id_of v6-verify)" "$RUN_DIR/v6-verify.rows.txt"
      v6_left=$(grep -Fxc "$TABLE_JP" "$RUN_DIR/v6-verify.rows.txt")
      # 準備のテーブル <TT> 本体（このあと z-drop-hive で消す）を除いた、接頭辞付きの残り。
      v6_others=$(grep -i "$PROBE_PREFIX" "$RUN_DIR/v6-verify.rows.txt" | grep -Fxv "$TABLE_HIVE" | grep -Fxvc "$TABLE_JP")
      if [ "$v6_left" = 0 ] && [ "$v6_others" = 0 ]; then
        V6_CREATED=0
        V6_STATUS="消えた（SHOW TABLES に <TT>_日本 も、<TT> 本体以外の <TT> 接頭辞の表も無い）"
      else
        V6_STATUS="残っている（<TT>_日本 ${v6_left} 件、<TT> 本体以外の <TT> 接頭辞の表 ${v6_others} 件）"
      fi
    else
      V6_STATUS="SHOW TABLES が通らず、消えたか確かめられなかった"
    fi
    info_row "v6-verify-check" "$V6_STATUS"
  fi
fi

# --- V7 群（S3 Tables。任意。環境変数が 3 つとも揃ったときだけ） -------------------

V7_LABELS="v7-select v7-desc v7-descd v7-showcol v7-showc v7-desc-nope v7-drop-nope v7-alt-rename-nope v7-alt-dropcol-nope v7-desc-allq"
if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ] && [ -n "$S3TABLES_TABLE" ]; then
  # 診断: Catalog を S3 Tables のカタログにして（Database は付けない）、名前空間と
  # テーブルの一覧を取る。一覧そのもの（実名）は <label>.rows.txt にだけ置く。
  S3T_CTX="Catalog=$S3TABLES_CATALOG"
  # $1 = ラベル、$2 = 一覧に含まれるか確かめる名前、$3 = summary に出す名前の表記
  v7_list_check() {
    local label=$1 want=$2 shown=$3 rows count exact ci
    rows="$RUN_DIR/$label.rows.txt"
    fetch_all_table_names "$(query_id_of "$label")" "$rows"
    count=$(grep -c . "$rows")
    exact=no
    ci=no
    grep -Fxq -- "$want" "$rows" && exact=yes
    grep -Fxqi -- "$want" "$rows" && ci=yes
    info_row "$label-check" "行数=$count、$shown を含む: 完全一致=$exact、大小無視=$ci"
  }
  if run_in_ctx "$S3T_CTX" "v7-diag-databases" "SHOW DATABASES"; then
    v7_list_check "v7-diag-databases" "$S3TABLES_NS" "S3TABLES_NS"
  else
    info_row "v7-diag-databases-check" "SHOW DATABASES が通らず、名前空間の一覧を取れなかった"
  fi
  if run_in_ctx "$S3T_CTX" "v7-diag-tables" "SHOW TABLES IN $S3TABLES_NS"; then
    v7_list_check "v7-diag-tables" "$S3TABLES_TABLE" "S3TABLES_TABLE"
  else
    info_row "v7-diag-tables-check" "SHOW TABLES IN <S3TABLES_NS> が通らず、テーブルの一覧を取れなかった"
  fi

  # <s3>     = "<S3TABLES_CATALOG>".<ns>.<table>（実在する表）
  # <s3nope> = "<S3TABLES_CATALOG>".<ns>.nope_204（実在しない表）
  S3_NAME="\"$S3TABLES_CATALOG\".$S3TABLES_NS.$S3TABLES_TABLE"
  S3_NOPE_NAME="\"$S3TABLES_CATALOG\".$S3TABLES_NS.nope_204"
  if run "v7-select" "SELECT * FROM $S3_NAME LIMIT 1"; then
    V7_SELECT_OK=yes
    info_row "v7-select-check" "対照 SELECT 成功"
  else
    V7_SELECT_OK=no
    info_row "v7-select-check" "対照 SELECT 失敗（以降の項目はそのまま流した）"
  fi
  run "v7-desc"             "DESCRIBE $S3_NAME"
  run "v7-descd"            "DESC $S3_NAME"
  run "v7-showcol"          "SHOW COLUMNS FROM $S3_NAME"
  run "v7-showc"            "SHOW CREATE TABLE $S3_NAME"
  run "v7-desc-nope"        "DESCRIBE $S3_NOPE_NAME"
  run "v7-drop-nope"        "DROP TABLE $S3_NOPE_NAME"
  run "v7-alt-rename-nope"  "ALTER TABLE $S3_NOPE_NAME RENAME TO nope_204b"
  run "v7-alt-dropcol-nope" "ALTER TABLE $S3_NOPE_NAME DROP COLUMN m"
  run "v7-desc-allq"        "DESCRIBE \"$S3TABLES_CATALOG\".\"$S3TABLES_NS\".\"$S3TABLES_TABLE\""
else
  for label in v7-diag-databases v7-diag-tables $V7_LABELS; do
    skip "$label" "未測定（S3TABLES_* 未設定）"
  done
fi

fi # ROUND=3

# ROUND=4 の W4 群の確かめの結果（summary の冒頭と INFO 行に出す）。
W4_STATUS=""

if [ "$ROUND" = 4 ]; then

# --- W1 群（存在の確認が何を対象に解決するか。DESCRIBE と SHOW COLUMNS FROM） ------
# 形の名前（ラベルの末尾）:
#   nodb     <NODB>.<TT>                 スキーマが実在しない
#   nodbq    "<NODB>".<TT>               同上・DB だけ引用符付き
#   n7       awsdatacatalog.<DB>.<TT>    3 部・実在
#   n7nope   awsdatacatalog.<DB>.<TT>_nope  3 部・実在しない
#   nocat    nocatalog_204.<DB>.<TT>     カタログが実在しない
#   ctxnodb  <TT>（QueryExecutionContext の Database を <NODB> にする。Catalog は既定）
#   upper    <TT の大文字>               大文字の無引用（実在）
#   upper2   <DB の大文字>.<TT の大文字>  2 部・大文字の無引用

W1_FORMS="nodb nodbq n7 n7nope nocat ctxnodb upper upper2"
W1_STMTS="desc showcol"
# $1 = 文の略号（desc / showcol）→ 文の頭
w1_head() {
  case "$1" in
    desc) printf 'DESCRIBE' ;;
    showcol) printf 'SHOW COLUMNS FROM' ;;
  esac
}
# $1 = 形の名前 → 名前（ctxnodb は 1 部の <TT>。context は呼ぶ側で差し替える）
w1_name() {
  case "$1" in
    nodb) printf '%s.%s' "$NODB" "$TARGET_TABLE" ;;
    nodbq) printf '"%s".%s' "$NODB" "$TARGET_TABLE" ;;
    n7) name_form n7 "$TARGET_TABLE" ;;
    n7nope) name_form n7 "$NOPE" ;;
    nocat) printf 'nocatalog_204.%s.%s' "$DB" "$TARGET_TABLE" ;;
    ctxnodb) printf '%s' "$TARGET_TABLE" ;;
    upper) printf '%s' "${TARGET_TABLE^^}" ;;
    upper2) printf '%s.%s' "${DB^^}" "${TARGET_TABLE^^}" ;;
  esac
}
for st in $W1_STMTS; do
  for f in $W1_FORMS; do
    label="w1-$st-$f"
    if [ "$f" != n7nope ] && [ -z "$TARGET_TABLE" ]; then
      skip "$label" "対象テーブルが無いため未測定"
      continue
    fi
    if [ "$f" = ctxnodb ]; then
      run_in_ctx "Catalog=$CATALOG,Database=$NODB" "$label" "$(w1_head "$st") $(w1_name "$f")"
    else
      run "$label" "$(w1_head "$st") $(w1_name "$f")"
    fi
  done
done

# --- W2 群（4 部の名前の文言の細部。DESCRIBE ほか） ---------------------------------

if [ -n "$TARGET_TABLE" ]; then
  run "w2-mixedcase" "DESCRIBE AwsDataCatalog.$DB.$TARGET_TABLE.N"
else
  skip "w2-mixedcase" "対象テーブルが無いため未測定"
fi
run "w2-dq-escape" "DESCRIBE awsdatacatalog.\"$DB\".\"a\"\"b\".n"
run "w2-dq-dot"    "DESCRIBE awsdatacatalog.$DB.\"x.y\".n"
if [ -n "$TARGET_TABLE" ]; then
  run "w2-5part"      "DESCRIBE awsdatacatalog.$DB.$TARGET_TABLE.n.m"
  run "w2-desc-short" "DESC awsdatacatalog.$DB.$TARGET_TABLE.n"
  run "w2-showcol-in" "SHOW COLUMNS IN awsdatacatalog.$DB.$TARGET_TABLE.n"
else
  for label in w2-5part w2-desc-short w2-showcol-in; do
    skip "$label" "対象テーブルが無いため未測定"
  done
fi
if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ] && [ -n "$S3TABLES_TABLE" ]; then
  run "w2-s3t" "DESCRIBE \"$S3TABLES_CATALOG\".$S3TABLES_NS.$S3TABLES_TABLE.n"
else
  skip "w2-s3t" "未測定（S3TABLES_* 未設定）"
fi

# --- W3 群（4 部・5 部の DROP・ALTER。実在しない名前に） -----------------------------

run "w3-dropif-4part"  "DROP TABLE IF EXISTS awsdatacatalog.$DB.$NOPE.n"
run "w3-drop-5part"    "DROP TABLE awsdatacatalog.$DB.$NOPE.n.m"
run "w3-rename-5part"  "ALTER TABLE awsdatacatalog.$DB.$NOPE.n.m RENAME TO $NOPE2"

# --- W4 群（ビュー。PROBE_DDL=1 のときだけ） -----------------------------------------
# <TT>_v を CREATE VIEW で作って測り、DROP VIEW IF EXISTS で消し、SHOW TABLES と
# SHOW VIEWS で消えたことを確かめる。

W4_MEASURE_LABELS="w4-desc-u w4-desc-q w4-showcol-u w4-showcol-q"
if [ "$PROBE_DDL" != 1 ]; then
  for label in w4-createview $W4_MEASURE_LABELS w4-dropview w4-verify-tables w4-verify-views; do
    skip "$label" "未測定（PROBE_DDL=0 ではビューを作らない）"
  done
else
  # 開始できたかどうかが分かるまでは、できたものとして trap の保険を掛けておく。
  W4_CREATED=1
  if run "w4-createview" "CREATE VIEW $DB.$VIEW_NAME AS SELECT 1 AS n"; then
    run "w4-desc-u"    "DESCRIBE $VIEW_NAME"
    run "w4-desc-q"    "DESCRIBE \"$VIEW_NAME\""
    run "w4-showcol-u" "SHOW COLUMNS FROM $VIEW_NAME"
    run "w4-showcol-q" "SHOW COLUMNS FROM \"$VIEW_NAME\""
  else
    for label in $W4_MEASURE_LABELS; do
      skip "$label" "未測定（ビューを作れなかった）"
    done
  fi

  if [ ! -s "$RUN_DIR/w4-createview.execution.json" ]; then
    # 開始時に弾かれた（StartQueryExecution が ID を返さなかった）ので、何もできていない。
    W4_CREATED=0
    W4_STATUS="CREATE VIEW が開始時に弾かれたので作られていない"
    for label in w4-dropview w4-verify-tables w4-verify-views; do
      skip "$label" "CREATE VIEW が開始時に弾かれたため後始末不要"
    done
  else
    # 作れた（または開始できて FAILED になった）ので、念のため消して確かめる。
    run "w4-dropview" "DROP VIEW IF EXISTS $DB.$VIEW_NAME"
    # 一覧に <TT>_v が何件あるか。一覧が取れなければ "?"。
    w4_count_in() {
      local label=$1 sql=$2
      if run "$label" "$sql" >&2; then
        fetch_all_table_names "$(query_id_of "$label")" "$RUN_DIR/$label.rows.txt"
        grep -Fxc "$VIEW_NAME" "$RUN_DIR/$label.rows.txt"
      else
        echo "?"
      fi
    }
    w4_left_tables=$(w4_count_in "w4-verify-tables" "SHOW TABLES")
    w4_left_views=$(w4_count_in "w4-verify-views" "SHOW VIEWS")
    w4_counts="SHOW TABLES に ${w4_left_tables} 件、SHOW VIEWS に ${w4_left_views} 件"
    if [ "$w4_left_tables" = 0 ] && [ "$w4_left_views" = 0 ]; then
      W4_CREATED=0
      W4_STATUS="消えた（<TT>_v は $w4_counts）"
    elif [ "$w4_left_tables" = "?" ] || [ "$w4_left_views" = "?" ]; then
      W4_STATUS="確かめられなかった（一覧が取れなかった。<TT>_v は $w4_counts）"
    else
      W4_STATUS="残っている（<TT>_v は $w4_counts）"
    fi
    info_row "w4-verify-check" "$W4_STATUS"
  fi
fi

# --- W5 群（存在の確認と引用符の順序） -----------------------------------------------

run "w5-desc-n1-a"  "DESCRIBE \"$NOPE\""
run "w5-desc-n1-b"  "DESCRIBE \"$NOPE\""
run "w5-desc-n3"    "DESCRIBE $DB.$NOPE"
run "w5-showcol-n3" "SHOW COLUMNS FROM $DB.$NOPE"

fi # ROUND=4

if [ "$ROUND" = 5 ]; then

# --- Y1 群（4 部以上の SHOW CREATE TABLE・SHOW TABLES IN・CREATE TABLE） ------------
# 形の名前（ラベルの末尾）: 4u = 無引用の 4 部、4q1 = 2 部目（DB）だけ引用符付き、
# 4q3 = 4 部目だけ引用符付き、5u = 無引用の 5 部。SHOW TABLES IN は DB の位置に
# 名前を取るので、実在の有無に関わらない x・n を使う。CREATE TABLE は実在しない
# <TT>_nope3 に投げ、想定外に成功したら run_create_guarded が後始末の DROP を投げる。

if [ -n "$TARGET_TABLE" ]; then
  run "y1-showc-4u"  "SHOW CREATE TABLE awsdatacatalog.$DB.$TARGET_TABLE.n"
  run "y1-showc-4q1" "SHOW CREATE TABLE awsdatacatalog.\"$DB\".$TARGET_TABLE.n"
  run "y1-showc-4q3" "SHOW CREATE TABLE awsdatacatalog.$DB.$TARGET_TABLE.\"n\""
  run "y1-showc-5u"  "SHOW CREATE TABLE awsdatacatalog.$DB.$TARGET_TABLE.n.m"
else
  for label in y1-showc-4u y1-showc-4q1 y1-showc-4q3 y1-showc-5u; do
    skip "$label" "対象テーブルが無いため未測定"
  done
fi
run "y1-showt-4u"  "SHOW TABLES IN awsdatacatalog.$DB.x.n"
run "y1-showt-4q1" "SHOW TABLES IN awsdatacatalog.\"$DB\".x.n"
run "y1-showt-4q3" "SHOW TABLES IN awsdatacatalog.$DB.x.\"n\""
Y1_CREATE_CLEANUP="DROP TABLE IF EXISTS $DB.$NOPE3"
run_create_guarded "y1-create-4u"  "CREATE TABLE awsdatacatalog.$DB.$NOPE3.n (n int)" "$Y1_CREATE_CLEANUP" NOPE3_CREATED
run_create_guarded "y1-create-4q1" "CREATE TABLE awsdatacatalog.\"$DB\".$NOPE3.n (n int)" "$Y1_CREATE_CLEANUP" NOPE3_CREATED
run_create_guarded "y1-create-4q3" "CREATE TABLE awsdatacatalog.$DB.$NOPE3.\"n\" (n int)" "$Y1_CREATE_CLEANUP" NOPE3_CREATED
run_create_guarded "y1-create-5u"  "CREATE TABLE awsdatacatalog.$DB.$NOPE3.n.m (n int)" "$Y1_CREATE_CLEANUP" NOPE3_CREATED

# --- Y2 群（SHOW TABLES IN の 3 部） -------------------------------------------------
# 3u = 無引用、3q0・3q1・3q2 = 1・2・3 部目だけ引用符付き。

run "y2-showt-3u"  "SHOW TABLES IN awsdatacatalog.$DB.x"
run "y2-showt-3q0" "SHOW TABLES IN \"awsdatacatalog\".$DB.x"
run "y2-showt-3q1" "SHOW TABLES IN awsdatacatalog.\"$DB\".x"
run "y2-showt-3q2" "SHOW TABLES IN awsdatacatalog.$DB.\"x\""

# --- Y3 群（QueryExecutionContext の Catalog が実在しないときの DESCRIBE・SHOW COLUMNS） --
# Context は Catalog=<NOCAT>,Database=<DB>。3 部の実在カタログ（y3-desc-3）と SELECT 1
# （y3-select）は対照。y3-desc-1-mixed だけ Catalog を大文字混じりの <NOCAT_MIXED> にして、
# 文言にどちらの綴りが出るかを見る。

Y3_CTX="Catalog=$NOCAT,Database=$DB"
run_in_ctx "$Y3_CTX" "y3-select" "SELECT 1"
if [ -n "$TARGET_TABLE" ]; then
  run_in_ctx "$Y3_CTX" "y3-desc-1"     "DESCRIBE $TARGET_TABLE"
  run_in_ctx "$Y3_CTX" "y3-desc-2"     "DESCRIBE $DB.$TARGET_TABLE"
  run_in_ctx "$Y3_CTX" "y3-desc-3"     "DESCRIBE awsdatacatalog.$DB.$TARGET_TABLE"
  run_in_ctx "$Y3_CTX" "y3-descq-1"    "DESCRIBE \"$TARGET_TABLE\""
  run_in_ctx "$Y3_CTX" "y3-showcol-1"  "SHOW COLUMNS FROM $TARGET_TABLE"
  run_in_ctx "$Y3_CTX" "y3-showcol-2"  "SHOW COLUMNS FROM $DB.$TARGET_TABLE"
  run_in_ctx "Catalog=$NOCAT_MIXED,Database=$DB" "y3-desc-1-mixed" "DESCRIBE $TARGET_TABLE"
else
  for label in y3-desc-1 y3-desc-2 y3-desc-3 y3-descq-1 y3-showcol-1 y3-showcol-2 y3-desc-1-mixed; do
    skip "$label" "対象テーブルが無いため未測定"
  done
fi
run_in_ctx "$Y3_CTX" "y3-desc-nope" "DESCRIBE $NOPE"

# --- Y4 群（4 部の名前で、引用符付きの部分が大文字のときの Invalid table name） --------

if [ -n "$TARGET_TABLE" ]; then
  run "y4-desc-q2upper"    "DESCRIBE awsdatacatalog.$DB.\"${TARGET_TABLE^^}\".n"
  run "y4-desc-q0mixed"    "DESCRIBE \"AwsDataCatalog\".$DB.$TARGET_TABLE.n"
  run "y4-desc-q3upper"    "DESCRIBE awsdatacatalog.$DB.$TARGET_TABLE.\"N\""
  run "y4-desc-q1upper"    "DESCRIBE awsdatacatalog.\"${DB^^}\".$TARGET_TABLE.n"
  run "y4-showcol-q2upper" "SHOW COLUMNS FROM awsdatacatalog.$DB.\"${TARGET_TABLE^^}\".n"
else
  for label in y4-desc-q2upper y4-desc-q0mixed y4-desc-q3upper y4-desc-q1upper y4-showcol-q2upper; do
    skip "$label" "対象テーブルが無いため未測定"
  done
fi

fi # ROUND=5

# --- 後始末（PROBE_DDL=1 のときだけ） ---------------------------------------------

if [ "$PROBE_DDL" = 1 ] && [ "$D_SETUP_OK" = 1 ]; then
  run z-drop-hive "DROP TABLE IF EXISTS $TABLE_HIVE"
  if [ -s "$RUN_DIR/z-drop-hive.reason.txt" ] && grep -q "^State: SUCCEEDED" "$RUN_DIR/z-drop-hive.reason.txt"; then
    DDL_ATTEMPTED=0
  else
    echo "== 後始末の DROP TABLE が SUCCEEDED になりませんでした。終了時にもう一度投げます。"
    echo "   それでも消えなければ、$DB の $TABLE_HIVE を手で消してください。"
  fi
fi

# --- summary -----------------------------------------------------------------

ALL_LABELS="probe-show-tables d0-setup-hive"
if [ "$ROUND" = 1 ]; then
  for n in $D_FORMS; do ALL_LABELS="$ALL_LABELS d-$n"; done
  for n in $E_FORMS; do ALL_LABELS="$ALL_LABELS e-$n"; done
  for n in $C_FORMS; do ALL_LABELS="$ALL_LABELS c-$n"; done
  for n in $L_FORMS; do ALL_LABELS="$ALL_LABELS l-$n"; done
  ALL_LABELS="$ALL_LABELS l-in"
  for n in $X_FORMS; do ALL_LABELS="$ALL_LABELS x-$n"; done
  ALL_LABELS="$ALL_LABELS x-ifq x-ifu"
  for key in addcols addcol dropcol rename settbl; do
    ALL_LABELS="$ALL_LABELS alt-$key-q alt-$key-u"
  done
  ALL_LABELS="$ALL_LABELS msck-q msck-u"
  ALL_LABELS="$ALL_LABELS pos-lower pos-dblspace pos-newline pos-leadspace pos-leadcomment pos-trailspace pos-drop-dblspace pos-drop-lower"
  ALL_LABELS="$ALL_LABELS s3t-desc s3t-show s3t-select s3t-drop"
elif [ "$ROUND" = 2 ]; then
  ALL_LABELS="$ALL_LABELS u1-desc-n12 u1-desc-n13 u1-descd-n12 u1-descd-n13"
  ALL_LABELS="$ALL_LABELS u1-showc-n12 u1-showc-n13 u1-showcol-n12 u1-showcol-n13"
  ALL_LABELS="$ALL_LABELS u1-drop-n12 u1-drop-n13"
  for n in $U2_FORMS; do ALL_LABELS="$ALL_LABELS u2-$n-rename u2-$n-dropcol"; done
  ALL_LABELS="$ALL_LABELS u2-ifq u2-ifu"
  ALL_LABELS="$ALL_LABELS u3-select u3-desc u3-descd u3-showcol u3-showc u3-desc-nope"
  ALL_LABELS="$ALL_LABELS u3-drop-nope u3-alt-rename-nope u3-alt-dropcol-nope u3-desc-allq"
  ALL_LABELS="$ALL_LABELS u4-leadtab u4-leadnl u4-leadcrlf u4-lead2nl u4-linecomment u4-blockcomment"
  ALL_LABELS="$ALL_LABELS u4-septab u4-sepcrlf u4-drop-leadnl u4-drop-sepnl"
  ALL_LABELS="$ALL_LABELS u5-hira u5-emoji u5-jp"
  ALL_LABELS="$ALL_LABELS u6-extended-q u6-formatted-q u6-extended-u"
  ALL_LABELS="$ALL_LABELS u7-showtables-q u7-showtables-u u7-dropdb-q u7-dropdb-u"
  ALL_LABELS="$ALL_LABELS u7-createtable-q u7-createtable-q-cleanup u7-createtable-u u7-createtable-u-cleanup"
elif [ "$ROUND" = 3 ]; then
  for n in $V1_FORMS; do ALL_LABELS="$ALL_LABELS v1-$n-rename v1-$n-dropcol"; done
  for p in $V2_FORMS; do ALL_LABELS="$ALL_LABELS v2-desc-$p"; done
  for p in $V2_FORMS; do ALL_LABELS="$ALL_LABELS v2-showcol-$p"; done
  for p in $V2_FORMS; do ALL_LABELS="$ALL_LABELS v2-drop-$p"; done
  for p in $V2_FORMS; do ALL_LABELS="$ALL_LABELS v2-rename-$p"; done
  ALL_LABELS="$ALL_LABELS v3-showtables-u v3-showtables-qq v3-showtables-uq v3-showtables-qu"
  for n in $V3_CREATE_FORMS ifq ifu; do
    ALL_LABELS="$ALL_LABELS v3-create-$n v3-create-$n-cleanup"
  done
  ALL_LABELS="$ALL_LABELS v4-desc-n1 v4-desc-n5 v4-desc-n6 v4-desc-n0 v4-showcol-n1"
  ALL_LABELS="$ALL_LABELS $V5_LABELS"
  ALL_LABELS="$ALL_LABELS v6-ctas $V6_MEASURE_LABELS v6-drop v6-verify"
  ALL_LABELS="$ALL_LABELS v7-diag-databases v7-diag-tables $V7_LABELS"
elif [ "$ROUND" = 4 ]; then
  for st in $W1_STMTS; do
    for f in $W1_FORMS; do ALL_LABELS="$ALL_LABELS w1-$st-$f"; done
  done
  ALL_LABELS="$ALL_LABELS w2-mixedcase w2-dq-escape w2-dq-dot w2-5part w2-desc-short w2-showcol-in w2-s3t"
  ALL_LABELS="$ALL_LABELS w3-dropif-4part w3-drop-5part w3-rename-5part"
  ALL_LABELS="$ALL_LABELS w4-createview $W4_MEASURE_LABELS w4-dropview w4-verify-tables w4-verify-views"
  ALL_LABELS="$ALL_LABELS w5-desc-n1-a w5-desc-n1-b w5-desc-n3 w5-showcol-n3"
elif [ "$ROUND" = 5 ]; then
  ALL_LABELS="$ALL_LABELS y1-showc-4u y1-showc-4q1 y1-showc-4q3 y1-showc-5u"
  ALL_LABELS="$ALL_LABELS y1-showt-4u y1-showt-4q1 y1-showt-4q3"
  for f in 4u 4q1 4q3 5u; do
    ALL_LABELS="$ALL_LABELS y1-create-$f y1-create-$f-cleanup"
  done
  ALL_LABELS="$ALL_LABELS y2-showt-3u y2-showt-3q0 y2-showt-3q1 y2-showt-3q2"
  ALL_LABELS="$ALL_LABELS y3-select y3-desc-1 y3-desc-2 y3-desc-3 y3-descq-1 y3-showcol-1 y3-showcol-2 y3-desc-1-mixed y3-desc-nope"
  ALL_LABELS="$ALL_LABELS y4-desc-q2upper y4-desc-q0mixed y4-desc-q3upper y4-desc-q1upper y4-showcol-q2upper"
fi
ALL_LABELS="$ALL_LABELS z-drop-hive"

write_summary_txt() {
  local txt="$RUN_DIR/summary.txt"
  {
    echo "# issue #204: 引用符付きの名前を取る文が StartQueryExecution の時点でどの形なら"
    echo "#             弾かれ、どの形なら通るか（境界の規則）と、弾かれた文言の規則を実測"
    if [ "$ROUND" = 3 ]; then
      echo "# 3 ラウンド目は issue #207（#204 で測っていない形の実測）"
    elif [ "$ROUND" = 4 ]; then
      echo "# 4 ラウンド目は issue #207 の続き（存在の確認の対象の解決と 4 部の名前の文言の細部）"
    elif [ "$ROUND" = 5 ]; then
      echo "# 5 ラウンド目は issue #212（#207 で残った未実測の名前の形）"
    fi
    echo "# 実行日時: $(date -Iseconds)"
    echo "# ROUND: $ROUND（1 = D〜P 群・S3 Tables 群、2 = U1〜U7 群、3 = V1〜V7 群、4 = W1〜W5 群、5 = Y1〜Y4 群）"
    if [ "$ROUND" = 1 ]; then
      echo "# StartQueryExecution の見込み本数: 68（preflight 1 + セットアップ/後始末 2 +"
      echo "#   D 12 + E 6 + C 12 + L 7 + X 8 + A 10 + M 2 + P 8）。"
      echo "#   S3TABLES_* が揃っていれば +4 で 72。"
    elif [ "$ROUND" = 3 ]; then
      echo "# StartQueryExecution の見込み本数: 54（S3TABLES_* 無し・V6 の CTAS が開始時に"
      echo "#   弾かれた）／60（S3TABLES_* 無し・CTAS 成功）／66・72（それぞれ S3TABLES_* あり）"
      echo "#   （preflight 1 + セットアップ/後始末 2 + V1 4 + V2 20 + V3 12 + V4 5 + V5 9 +"
      echo "#   V6 1〜7（PROBE_DDL=1 のときだけ）、S3TABLES_* が揃っていれば V7 の 12 が乗る）。"
      echo "#   V3・V5 の CREATE TABLE が想定外に成功すれば後始末が最大 9 本増える。"
      echo "#   v7-diag-* は QueryExecutionContext の Catalog を <S3TABLES_CATALOG> にして"
      echo "#   （Database 無し）投げた。一覧の実名は <label>.rows.txt にだけある。"
    elif [ "$ROUND" = 4 ]; then
      echo "# StartQueryExecution の見込み本数: 33（S3TABLES_* 無し・CREATE VIEW が開始時に"
      echo "#   弾かれた）／40（S3TABLES_* 無し・CREATE VIEW 成功）／34・41（それぞれ S3TABLES_* あり）"
      echo "#   （preflight 1 + セットアップ/後始末 2 + W1 16 + W2 6 + W3 3 + W4 1〜8"
      echo "#   （PROBE_DDL=1 のときだけ）+ W5 4、S3TABLES_* が揃っていれば w2-s3t の 1 が乗る）。"
      echo "#   PROBE_DDL=0 なら 30（S3TABLES_* ありで 31）。"
      echo "#   w1-*-ctxnodb は QueryExecutionContext の Database を <NODB>（= <TT>_nodb）にして"
      echo "#   投げた。大文字の名前は <DB_UPPER>・<TT_UPPER> と伏せる。"
    elif [ "$ROUND" = 5 ]; then
      echo "# StartQueryExecution の見込み本数: 32（preflight 1 + セットアップ/後始末 2 +"
      echo "#   Y1 11 + Y2 4 + Y3 9 + Y4 5）。PROBE_DDL=0 なら 30。"
      echo "#   Y1 の CREATE TABLE が想定外に成功すれば後始末が最大 4 本増える。"
      echo "#   y3-* は QueryExecutionContext の Catalog を実在しない nocatalog_212"
      echo "#   （y3-desc-1-mixed だけ NoCatalog_212）にして投げた。"
    else
      echo "# StartQueryExecution の見込み本数: 45（S3TABLES_* 無し）／55（あり）"
      echo "#   （preflight 1 + セットアップ/後始末 2 + U1 10 + U2 10 + U4 10 + U5 3 +"
      echo "#   U6 3 + U7 6、S3TABLES_* が揃っていれば U3 の 10 が乗る）。U7 の"
      echo "#   CREATE TABLE の対照が想定外に成功すれば後始末が最大 2 本増える。"
    fi
    echo "#   開始時に弾かれた（START_FAILED）項目があっても追加の呼び出しはしない"
    echo "#   （このラウンドの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回）。"
    echo "# DDL は準備の Hive テーブル athena_local_probe_204 を 1 つ作って消すだけ"
    echo "#   (PROBE_DDL=1)。DROP・ALTER は実在しない名前 (..._nope) にだけ投げる。"
    if [ "$ROUND" = 3 ]; then
      echo "#   ROUND=3 はほかに、V6 の CTAS（<TT>_日本、PROBE_DDL=1 のときだけ）と、その"
      echo "#   後始末の DROP TABLE IF EXISTS <DB>.\`<TT>_日本\`、V3・V5 の CREATE TABLE が"
      echo "#   想定外に成功したときの後始末の DROP がありうる。"
    elif [ "$ROUND" = 5 ]; then
      echo "#   ROUND=5 はほかに、Y1 の CREATE TABLE（<TT>_nope3。本物では開始時に弾かれるはず）が"
      echo "#   想定外に成功したときの後始末の DROP TABLE IF EXISTS <DB>.<TT>_nope3 がありうる。"
    elif [ "$ROUND" = 4 ]; then
      echo "#   ROUND=4 はほかに、W4 のビュー（CREATE VIEW <DB>.<TT>_v、PROBE_DDL=1 のときだけ）"
      echo "#   と、その後始末の DROP VIEW IF EXISTS <DB>.<TT>_v がある。"
    fi
    echo "# 課金: スキャンの無いクエリだけ（メタデータの参照・書き換えのみ）。"
    echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
    echo
    if [ "$ROUND" = 3 ]; then
      echo "## 要対応・確かめ（ROUND=3）"
      if [ "$PROBE_DDL" = 1 ]; then
        echo "- V6 の <TT>_日本: ${V6_STATUS:-(V6 まで進まなかった)}"
      else
        echo "- V6 の <TT>_日本: PROBE_DDL=0 のため作っていない"
      fi
      if [ "$V6_CREATED" = 1 ]; then
        echo "- **手で消してください**: <TT>_日本 が残っているか、消えたか確かめられなかった。"
        echo "  終了時に trap がもう一度 DROP を投げるが、結果は確かめない。SHOW TABLES で確かめ、"
        echo "  残っていれば DROP TABLE IF EXISTS <DB>.\`<TT>_日本\` を投げる。"
      fi
      if [ "$NOPE3_CREATED" = 1 ]; then
        echo "- **手で消してください**: V3 の CREATE TABLE が成功し、後始末の DROP が SUCCEEDED に"
        echo "  ならなかった。SHOW TABLES で確かめ、残っていれば DROP TABLE IF EXISTS <TT>_nope3 を投げる。"
      fi
      if [ "$JP_CREATED" = 1 ]; then
        echo "- **手で消してください**: V5 の CREATE TABLE \"日本\" が成功し、後始末の DROP が"
        echo "  SUCCEEDED にならなかった。残っていれば DROP TABLE IF EXISTS \`日本\` を投げる。"
      fi
      case "$V7_SELECT_OK" in
        yes) echo "- V7 の対照 SELECT: 成功" ;;
        no) echo "- V7 の対照 SELECT: **失敗**（以降の V7 の項目はそのまま流した。v7-diag-*-check を参照）" ;;
        *) echo "- V7: 未測定（S3TABLES_* 未設定）" ;;
      esac
      echo
    fi
    if [ "$ROUND" = 5 ] && [ "$NOPE3_CREATED" = 1 ]; then
      echo "## 要対応・確かめ（ROUND=5）"
      echo "- **手で消してください**: Y1 の CREATE TABLE が成功し、後始末の DROP が SUCCEEDED に"
      echo "  ならなかった。SHOW TABLES で確かめ、残っていれば DROP TABLE IF EXISTS <DB>.<TT>_nope3 を投げる。"
      echo
    fi
    if [ "$ROUND" = 4 ]; then
      echo "## 要対応・確かめ（ROUND=4）"
      if [ "$PROBE_DDL" = 1 ]; then
        echo "- W4 のビュー <TT>_v: ${W4_STATUS:-(W4 まで進まなかった)}"
      else
        echo "- W4 のビュー <TT>_v: PROBE_DDL=0 のため作っていない"
      fi
      if [ "$W4_CREATED" = 1 ]; then
        echo "- **手で消してください**: <TT>_v が残っているか、消えたか確かめられなかった。"
        echo "  終了時に trap がもう一度 DROP VIEW を投げるが、結果は確かめない。SHOW VIEWS で"
        echo "  確かめ、残っていれば DROP VIEW IF EXISTS <DB>.<TT>_v を投げる。"
      fi
      echo
    fi
    echo "## 投げた文（DB 名・テーブル名は伏せる。実名は各 <label>.sql を参照）"
    for label in $ALL_LABELS; do
      if [ -s "$RUN_DIR/$label.sql" ]; then
        if [ -s "$RUN_DIR/$label.context.txt" ]; then
          echo "- $label: $(sanitize "$(hide "$(cat "$RUN_DIR/$label.sql")")")（QueryExecutionContext: $(sanitize "$(hide "$(cat "$RUN_DIR/$label.context.txt")")")）"
        else
          echo "- $label: $(sanitize "$(hide "$(cat "$RUN_DIR/$label.sql")")")"
        fi
      fi
    done
    echo
    echo "## 項目ごとの結果"
    echo "#   start_message/start_athena_error_code  開始時に弾かれた項目の Message・AthenaErrorCode"
    echo "#   error_category/error_type/error_message  開始できて FAILED になった項目の AthenaError"
    echo "#   reason_line  StateChangeReason の 1 行目（無ければ -）"
    python3 - "$SUMMARY" <<'PYEOF'
import csv, sys
with open(sys.argv[1], newline="") as f:
    for row in csv.DictReader(f, delimiter="\t"):
        print(
            "- {label}: state={state} statement_type={statement_type}/{substatement_type} "
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
  } > "$txt"
  echo "$txt"
}

SUMMARY_TXT=$(write_summary_txt)

echo
echo "完了しました。"
echo "機械可読な一覧: $SUMMARY"
echo "そのまま貼れる整形済みの一覧: $SUMMARY_TXT"
echo "中身のファイルは $RUN_DIR にあります。リポジトリには入れないでください。"
echo "<label>.sql・<label>.reason.txt・<label>.start.err・<label>.rows.txt は実名（DB 名・"
echo "テーブル名・S3 Tables の名前）を含みうるので、summary.txt 以外を貼るときは中身を確かめてください。"
