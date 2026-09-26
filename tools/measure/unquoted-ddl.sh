#!/usr/bin/env bash
# issue #208 で作成。issue #221 で ROUND=3、issue #224 で ROUND=4、issue #227 で ROUND=5、
# issue #228 で ROUND=6、issue #240 で ROUND=7、issue #242 で ROUND=8、issue #229 で ROUND=9 を追加
# 本物の Athena が StartQueryExecution の時点で弾く、無引用の DDL 3 種
# （ALTER TABLE IF EXISTS、ALTER TABLE ... ADD COLUMN（単数）、場所の無い CREATE TABLE）の
# 弾かれ方の規則（`line L:C` の位置、`no viable alternative at input '...'` の input の範囲、
# どの形で文言の種類が変わるか）を洗い出す。athena-local は Trino がこれらを受け付けて
# しまうため実行してしまう（#208 の背景）。athena-local 側を本物に揃える対応の材料として、
# このスクリプトで文言の規則と、Trino にだけある他の ALTER・CREATE の範囲を測る。
#
# 既知の実測（生データ ~/athena-*-measurements。issue #208 本文より）:
#   ALTER TABLE IF EXISTS <t> RENAME TO <t2>
#     → line 1:16: no viable alternative at input 'ALTER TABLE IF EXISTS'（引用符の有無によらず）
#   ALTER TABLE IF EXISTS <db>.<t> ADD COLUMNS (m2 int)
#     → line 1:68: mismatched input 'COLUMNS'. Expecting: '.', 'ADD'（Trino 形の文言）
#   ALTER TABLE <t> ADD COLUMN m int
#     → line 1:45: no viable alternative at input 'ALTER TABLE <t> ADD COLUMN'（位置は COLUMN の先頭）
#   CREATE TABLE <t> (n int) など、場所の無い CREATE TABLE
#     → No location was specified for table. An S3 location must be specified（位置なし）
#   CREATE TABLE <db>.<t> (n int NOT NULL) WITH (...)
#     → line 1:68: no viable alternative at input 'CREATE TABLE <db>.<t> (n int NOT'
#
# tools/measure/quoted-names.sh（#204・#207・#212）を雛形にし、次の関数をそのまま
# （ほぼ無改変で）流用している: hide（#224 で redact・mask_names をまとめた）・sanitize・first_err_line・
# is_transient_error・start_query_retry・poll_until_terminal・get_state_once・
# read_attempts・emit_row・skip・run・write_reason・reason_first_line・
# athena_error_fields_of・read_execution_fields・start_err_message・start_err_code・
# query_id_of・succeeded・cleanup・write_summary_txt。
#
# 雛形からの変更点:
#   - ROUND（既定 1）でラウンドを切り替える。ROUND=1 は元の全項目（A・B・B' 群、
#     場所の無い CREATE TABLE の C 群、S3 Tables）をそのまま測り、挙動は変えていない。
#     ROUND=2 は preflight・DB 確認・実在する表の準備/後始末は共通のまま、
#     E 群（CREATE TABLE の型名）・F 群（LIKE と Trino の型の中身）・G 群
#     （Trino 形の文言の綴り）だけを測る（#208 ラウンド 2）。name_form・
#     four_part_form・fetch_all_table_names（引用符付きの名前の形の生成・S3 の読み出し）は
#     持ち込んでいない。この実測は「開始時に弾かれたか」「開始できたら最終状態と理由」だけを
#     見れば足りる。
#   - 【issue #221 で追加】ROUND=3 は、#208 の 2 ラウンドで測れなかった／測っていない
#     場所の無い CREATE TABLE の形だけを測る。preflight・DB 確認・後始末の仕組みは共通だが、
#     実在する表 <PROBE>_real は使わないので作らない（setup-real・z-drop-real の行も出さない）。
#       H 群: QueryExecutionContext の Catalog が S3 Tables のときの CREATE TABLE
#             （#208 の C20 が S3TABLES_* 未設定で測れなかった。S3 Tables は場所を要らないので
#             No location にならないかもしれない）。h9 は既定の Context の対照。
#       Q 群: 列名・型が引用符付きの CREATE TABLE（Hive の文法では "n" は文字列）。
#       P 群: 無引用の 4 部以上の名前の CREATE TABLE（IF NOT EXISTS・CTAS を含む。
#             IF NOT EXISTS の無い形は 3 つ目の `.` で弾かれると #212 で測った）。
#     別の QueryExecutionContext で作られうるテーブルは、C20_CREATED のような 1 項目 1 フラグ
#     ではなく、「DROP を投げる Context と名前の組」の集合 PENDING_DROPS_CTX で管理する
#     run_create_then_drop_ctx を新設した（作る Context と消す Context を別に渡せる。h8 は
#     S3 Tables の Context で AwsDataCatalog の 3 部の名前を作るので、既定の Context で消す）。
#     trap の cleanup は PENDING_DROPS_CTX に残っている組を全部、その Context で DROP する。
#   - 対象の名前は固定の接頭辞ではなく、実行のたびに乱数を足した接頭辞
#     （athena_local_probe_208_<4 桁 16 進>）を使う。テーブルを作る CREATE 系の項目は
#     項目ごとに別名（<接頭辞>_c1 など）にするので、雛形の「同じ接頭辞のテーブルが
#     既に無いか確かめてから始める」チェックは不要にした（乱数が毎回変わるため衝突しない）。
#   - CREATE TABLE を投げて想定外に成功したときの後始末は、雛形の run_create_guarded
#     （1 項目に対して 1 つの真偽値フラグを対応させる作り）ではなく、作られたかもしれない
#     テーブル名の集合 PENDING_DROPS（連想配列）で管理する run_create_then_drop にした。
#     C1〜C23 のどれで想定外の成功が起きても、この 1 つの仕組みで拾える
#     （trap の cleanup は PENDING_DROPS に残っている名前だけを対象に DROP を投げる）。
#   - S3 Tables は C20 の 1 項目だけなので、雛形のような専用の真偽値フラグ
#     （C20_CREATED）と、S3 Tables 側の QueryExecutionContext で DROP を投げる
#     cleanup_drop_in_ctx を新設した。
#   - 疎通 preflight（SELECT 1）を、既定の QueryExecutionContext とは別に
#     Catalog だけを渡す run_in_ctx で投げる（Database の指定が無くても届くかどうかを
#     DB の実在確認より先に確かめるため。雛形の run_in_ctx をそのまま使う）。
#   - 実在する表が要る項目（B10・C15 の対照）のために、実在する表を 1 つ作る
#     セットアップを新設した（雛形の d0-setup-hive と同じ「WITH 句を付けない CTAS」の
#     形を流用。issue 本文が挙げた `WITH (format='PARQUET')` は、本物で
#     external_location が要るかもしれないため、雛形で実測済みの安全な形にした）。
#   - 【コーディネーターからの追加指示】C22 `CREATE TABLE X (n string)`、
#     C23 `CREATE TABLE X (n array<int>)` を追加した（手元の Trino 482 は受理するとのことで、
#     C3・C21 と同じ「作られうる」扱いにし、run_create_then_drop で後始末する）。
#   - 【issue #227 で追加】ROUND=5 は、#224 の I 群で見つけた事実（S3 Tables の
#     Context で `CREATE TABLE AwsDataCatalog.<db>.<t>` が開始でき FAILED になった。
#     大文字混じりの 1 部目が S3 Tables 側の名前として扱われ、2 部目が S3 Tables の
#     名前空間として引かれているという仮説）を確かめる J 群だけを測る。preflight・
#     DB 確認は共通で走るが、実在する表は作らない（ROUND=3・4 と同じ）。作られうる
#     テーブルと後始末は run_create_then_drop_ctx をそのまま流用する。加えて、FAILED
#     になった項目は GetQueryExecution の OutputLocation から結果ファイル本体と
#     `.metadata` を `aws s3 cp` で読み出して保存する（fetch_failed_attachments。
#     読み取りのみで、書き込みは行わない）。
#   - 【issue #229 で追加】ROUND=9 は、ROUND=4 の I 群（i14・i15）で見つけた事実（QueryExecutionContext の
#     Catalog が S3 Tables のとき、`CREATE TABLE awsdatacatalog.<db>.<t> (n int) LOCATION '...'` と
#     `CREATE EXTERNAL TABLE ...` が同じ形で開始時に InvalidRequestException・MALFORMED_QUERY、
#     `Table location can not be specified for tables hosted in S3 table buckets` で弾かれた）の
#     周辺を測る N 群だけを測る。preflight・DB 確認は共通で走るが、実在する表は作らない
#     （ROUND=3〜7 と同じ）。i14 と同じ LOCATION の組み立て（`probe_location`。空のプレフィックス）と、
#     受理されたら同じ Context で消す run_create_then_drop_ctx をそのまま流用する。S3 Tables に
#     作られうる項目は S3 Tables の Context で、AwsDataCatalog に作られうる項目（n1・n5・n6・n12・n15・n31）は
#     既定の Context で DROP する（i 群の後始末と同じ考え方）。n32 だけ Context に Database を含めない
#     （Catalog=<S3TABLES_CATALOG> だけ）。S3TABLES_* が無ければ、既定の Context だけで測れる n31 を
#     除いて未測定として残す。
#
# 使い方:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db bash tools/measure/unquoted-ddl.sh
#   ラウンド 2（CREATE TABLE の型名・LIKE・ALTER TABLE の Trino 形の文言の綴りだけを測る）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=2 \
#     bash tools/measure/unquoted-ddl.sh
#   S3 Tables も測るとき（ROUND=1 の C20 と ROUND=3 の H 群に効く。両方揃ったときだけ）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns \
#     bash tools/measure/unquoted-ddl.sh
#   ラウンド 3（issue #221。S3 Tables の Context の CREATE TABLE・引用符付きの列名と型・
#   4 部以上の無引用の名前だけを測る。S3TABLES_* が無ければ H 群は未測定として残す）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=3 \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns \
#     bash tools/measure/unquoted-ddl.sh
#   ラウンド 4（issue #224。S3 Tables の Context で別カタログの名前の CREATE TABLE が
#   `Unsupported ddl with 2 catalogs: <文>` になる範囲と、文言の後ろに付く文の書かれ方だけを測る。
#   S3TABLES_* が無ければ I 群は i18 を除いて未測定として残す）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=4 \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns \
#     bash tools/measure/unquoted-ddl.sh
#   ラウンド 5（issue #227。#224 の I 群で見つけた「S3 Tables の Context で大文字混じりの
#   AwsDataCatalog を 1 部目にした 3 部の CREATE TABLE が開始でき FAILED になる」の周辺
#   （1 部目が S3 Tables 側の名前、2 部目が S3 Tables の名前空間として引かれているという
#   仮説）だけを測る。S3TABLES_* が無ければ J 群の j0〜j13 は未測定として残し、
#   常に投げる j14〜j16 だけ測る。FAILED になった項目は結果ファイル本体と .metadata も
#   取得する）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=5 \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns \
#     bash tools/measure/unquoted-ddl.sh
#   ラウンド 6（issue #228。#224 の i10 で見つけた `Only one sql statement is allowed. Got: <文>` が
#   どの形で返るか（`;` の後ろに何があるとき・文字列やコメントの中の `;`・他の判定との順番・
#   `Got:` の後ろの文の書かれ方）だけを測る。S3TABLES_* が無ければ k29・k30 は未測定として残す）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=6 \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns \
#     bash tools/measure/unquoted-ddl.sh
#   ラウンド 7（issue #240。末尾の `;` だけの文を本物がどう見せるか（GetQueryExecution の Query の
#   正規化の範囲・先頭の `;`・文を引用する文言・文の種類ごとの見え方・パラメータ付き・同じ
#   ClientRequestToken での冪等の比較）だけを測る。S3TABLES_* が無ければ l13 は未測定として残す）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=7 \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns \
#     bash tools/measure/unquoted-ddl.sh
#   ラウンド 8（issue #242。DESCRIBE・DESC の Query から修飾が落ちる範囲と QueryExecutionContext.Database の
#   書き換え、ほかの文で awsdatacatalog. が落ちる範囲だけを測る。S3TABLES_* は使わない）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=8 bash tools/measure/unquoted-ddl.sh
#   ラウンド 9（issue #229。#224 の i14・i15 で見つけた「QueryExecutionContext の Catalog が S3 Tables のとき、
#   LOCATION 付きの CREATE TABLE・CREATE EXTERNAL TABLE が Table location can not be specified で弾かれる」
#   範囲だけを測る。S3TABLES_* が無ければ n31 以外の N 群は未測定として残す）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=9 \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns \
#     bash tools/measure/unquoted-ddl.sh
#   （資格情報はホストのシェルで AWS_ACCESS_KEY_ID などを export してから。または ~/.aws/credentials）
#
# 必要な環境変数:
#   OUTPUT    結果の出力先。s3://bucket/prefix/ の形（末尾の / を付ける）。
#   DB        データベース名。実在するものを指定する。
#
# 任意の環境変数:
#   ROUND            既定 1。1 は元の全項目（A・B・B' 群、場所の無い CREATE TABLE の
#                    C 群、S3 Tables）。2 は E 群（CREATE TABLE の型名）・F 群（LIKE と
#                    Trino の型の中身）・G 群（Trino 形の文言の綴り）だけ（preflight・
#                    DB 確認・実在する表の準備/後始末は共通で両方の値で走る）。
#                    3 は H 群（S3 Tables の Context）・Q 群（引用符付きの列名と型）・
#                    P 群（4 部以上の無引用の名前）だけ（issue #221）。preflight・DB 確認は
#                    共通で走るが、実在する表 <PROBE>_real は作らない。
#                    4 は I 群（S3 Tables の Context の別カタログの名前。issue #224）だけ。
#                    実在する表は作らない。
#                    5 は J 群（S3 Tables の Context の別カタログ・別名前空間の名前。
#                    issue #227）だけ。実在する表は作らない。FAILED になった項目は
#                    結果ファイル本体と .metadata も取得する。
#                    6 は K 群（複数の文・末尾の `;`。issue #228）だけ。実在する表は作らない。
#                    7 は L 群（末尾の `;` だけの文の見え方。issue #240）だけ。実在する表は作らず、
#                    l16 の CTAS で作った表を l20 で消す。
#                    8 は M 群（DESCRIBE の修飾落ちとカタログ部分の落ち。issue #242）だけ。表・ビュー・
#                    別の DB を作り、最後に消す。
#                    9 は N 群（S3 Tables の Context の LOCATION 付き CREATE TABLE。issue #229）だけ。
#                    実在する表は作らない。
#   CATALOG          既定 AwsDataCatalog
#   REGION           既定 ap-northeast-1
#   OUT_DIR          既定 ${DEV_HOST_HOME:-$HOME}/athena-unquoted-ddl-measurements
#                    （実名が入るのでリポジトリの外に出す）
#   POLL_TIMEOUT     終端状態を待つ上限（秒）。既定 180
#   RETRY_MAX        名前解決・接続など一時的な失敗を再試行する回数の上限。既定 4
#   RETRY_DELAY      再試行の間隔（秒）。既定 5
#   S3TABLES_CATALOG S3 Tables のカタログ名（例 s3tablescatalog/my-bucket）。
#   S3TABLES_NS      S3 Tables の名前空間。
#                    この 2 つが揃ったときだけ、ROUND=1 の C20（S3 Tables への場所の無い
#                    CREATE TABLE）と ROUND=3 の H 群（h0〜h9）、ROUND=5 の J 群（j0〜j13）、
#                    ROUND=9 の N 群（n0〜n30・n32）を測る。1 つでも欠けていれば
#                    「未測定（S3TABLES_* 未設定）」として summary に残す（ROUND=5 は j14〜j16、
#                    ROUND=9 は n31 だけ測る）。ROUND=2 では使わない。
#
# ** このスクリプトが本物に対して行う破壊的な操作 **
#   - 実在する表 <db>.athena_local_probe_208_<乱数>_real を 1 つ CTAS で作り、
#     最後に無引用 + IF EXISTS の DROP TABLE で消す（異常終了時も trap で同じ形で消しにいく）。
#     作れなければ B10 だけ未測定にし、C15 は実在しない名前を対象にする。
#   - C3・C20（S3TABLES_* が揃うときだけ）・C21・C22・C23 は、場所の指定や Hive 互換の
#     型名によって受理され、実際にテーブルが作られる見込み（本物の書き方の対照、または
#     手元の Trino 482 で受理を確認済み）。受理できたらその場で無引用 + IF EXISTS の
#     DROP TABLE を投げて消す（結果は確かめる。SUCCEEDED にならなければ trap がもう一度
#     ベストエフォートで投げる）。
#   - それ以外の C1〜C19（C3 を除く）・C22・C23 を除く項目は「開始時に弾かれる」見込みだが、
#     想定に反して受理されて表ができてしまった場合も、同じ仕組み（run_create_then_drop）で
#     その場で DROP を投げて消す。
#   - ALTER TABLE・DROP は実在しない名前（<接頭辞>_nope）にだけ投げるので、対象のテーブル
#     自体は作らない（後始末の対象にもならない）。B10 だけ実在する表 <接頭辞>_real に対して
#     ADD COLUMN を投げるが、ADD COLUMN 自体は失敗する見込み（表そのものは消さずに残し、
#     最後の後始末でまとめて消す）。
#   - ROUND=2: E 群（e1〜e25、CREATE TABLE の型名）・F 群（f1〜f16、LIKE と Trino の型の
#     中身）は場所の指定が無い CREATE TABLE のため、C 群と同様に大半は開始時に弾かれる
#     見込みだが、想定に反して受理されて表ができた場合は、その場で無引用 + IF EXISTS の
#     DROP TABLE を投げて消す（run_create_then_drop をそのまま流用。結果は確かめる。
#     SUCCEEDED にならなければ trap がもう一度ベストエフォートで投げる）。F1・F3・F4・F5 は
#     実在する表 <接頭辞>_real を LIKE の対象にする（準備できていれば）。G 群
#     （g1〜g7、Trino 形の文言の綴り）は ALTER TABLE のみで、実在しない名前
#     （<接頭辞>_nope）にだけ投げるため表は作らない。
#   - ROUND=3: 実在する表 <接頭辞>_real は作らない。CREATE TABLE（H・Q・P 群）はすべて
#     「想定外に成功したらその場で無引用 + IF EXISTS の DROP TABLE を投げて消す」経路
#     （run_create_then_drop か run_create_then_drop_ctx）で投げる。結果は確かめ、
#     SUCCEEDED にならなければ trap がもう一度ベストエフォートで投げる。
#     作られうるテーブルと、消すときの Context・名前:
#       h1〜h7（S3 Tables の Context）→ S3 Tables の Context で DROP TABLE IF EXISTS <接頭辞>_hN
#       h8（S3 Tables の Context で awsdatacatalog.<db>.<接頭辞>_h8）
#                                     → 既定の Context で DROP TABLE IF EXISTS <接頭辞>_h8
#       h9（既定の Context）          → 既定の Context で DROP TABLE IF EXISTS <接頭辞>_h9
#       q0〜q8（既定の Context）      → 既定の Context で DROP TABLE IF EXISTS <接頭辞>_qN
#       p0〜p8（既定の Context）      → 既定の Context で DROP TABLE IF EXISTS <接頭辞>_pN
#                                       （4 部以上の名前が万一受理されたときに、<db> の下に
#                                       できうる名前を消しにいく）
#     h1〜h7 は S3 Tables が場所を要らないため受理されて作られうる。h9・q0・p0 は対照で
#     開始時に弾かれる見込み（No location、または #212 で測った 3 つ目の `.` の構文エラー）。
#   - ROUND=5: 実在する表 <接頭辞>_real は作らない。J 群の CREATE TABLE（S3TABLES_* が
#     揃うときだけの j1〜j13 と、常に投げる j14〜j16）はすべて run_create_then_drop_ctx で
#     投げ、想定外に成功したらその場で無引用 + IF EXISTS の DROP TABLE を投げて消す。
#     結果は確かめ、SUCCEEDED にならなければ trap がもう一度ベストエフォートで投げる。
#     作られうるテーブルと、消すときの Context・名前:
#       j1・j4・j11・j13（S3 Tables の Context。仮説どおりなら受理されうる）
#                                     → S3 Tables の Context で DROP TABLE IF EXISTS <接頭辞>_jN
#       j5（S3 Tables の Context、実在しないカタログ。開始時に弾かれる見込み）
#                                     → S3 Tables の Context で DROP TABLE IF EXISTS <接頭辞>_j5
#       j2・j3・j6・j7・j8・j9・j10・j12（S3 Tables の Context で AwsDataCatalog・実在しない
#       カタログ側を指す。i2・i3・i4 と同様に FAILED か DATACATALOG_NOT_FOUND の見込み）
#                                     → 既定の Context で DROP TABLE IF EXISTS <接頭辞>_jN
#       j14〜j16（既定の Context）    → 既定の Context で DROP TABLE IF EXISTS <接頭辞>_jN
#     加えて、FAILED になった項目は GetQueryExecution の OutputLocation から結果ファイル
#     本体と `.metadata` を `aws s3 cp <uri> -` で読み出して保存する
#     （fetch_failed_attachments。読み取りのみで、書き込みは行わない）。
#   - ROUND=6: 実在する表 <接頭辞>_real は作らない。K 群の大半は SELECT などの読み取りで、
#     CREATE TABLE（k25〜k27・k30）は run_create_then_drop_ctx で投げ、想定外に成功したら
#     その場で無引用 + IF EXISTS の DROP TABLE を投げて消す（k30 は S3 Tables の Context で
#     awsdatacatalog 側の名前なので既定の Context で消す）。DESCRIBE・DROP TABLE IF EXISTS は
#     実在しない名前（<接頭辞>_nope）にだけ投げる。
#   - ROUND=7: 実在する表 <接頭辞>_real は作らない。l16 の CTAS で <接頭辞>_l16（1 行）を作り、l17 で
#     1 行 INSERT し、l20 の DROP TABLE IF EXISTS（末尾 `;`）で消す。l20 が SUCCEEDED にならなければ trap が
#     もう一度 DROP を投げる。l12・l13 の CREATE TABLE は run_create_then_drop_ctx で、受理されたら消す。
#   - ROUND=9: 実在する表 <接頭辞>_real は作らない。N 群の CREATE TABLE（n0 の SELECT 1 を除く）は
#     すべて run_create_then_drop_ctx で投げ、想定外に（あるいは LOCATION 無しの項目は想定どおり）
#     受理されたらその場で無引用 + IF EXISTS の DROP TABLE を投げて消す。結果は確かめ、SUCCEEDED に
#     ならなければ trap がもう一度ベストエフォートで投げる。作られうるテーブルと、消すときの Context：
#       n1・n5・n6・n12・n15・n31（AwsDataCatalog に作られうる。n31 は既定の Context で作る対照）
#                                     → 既定の Context で DROP TABLE IF EXISTS <接頭辞>_nN
#       n2〜n4・n7〜n11・n13・n14・n16〜n30（S3 Tables の Context。i14・i15 と同様、大半は
#       LOCATION 指定で開始時に弾かれる見込みだが、n11・n12・n21・n26・n27 は LOCATION 無しで
#       受理されうる）             → S3 Tables の Context で DROP TABLE IF EXISTS <接頭辞>_nN
#       n32（Context は Catalog=<S3TABLES_CATALOG> だけ、Database 無し）
#                                     → 同じ Context で DROP TABLE IF EXISTS <接頭辞>_n32
#     LOCATION は <OUTPUT>athena-local-probe-229/<接頭辞>_<項目>/（空のプレフィックス。データは置かない）。
#
# 課金について: ALTER TABLE・DROP TABLE はメタデータだけを見る／書く文で、実データの
# スキャンは無い。CREATE TABLE（実在する表の準備・C3・C20・C21・C22・C23、E・F 群、
# ROUND=3 の H・Q・P 群、ROUND=5 の J 群、ROUND=9 の N 群。いずれも 0〜1 行）もスキャンや
# 書き込みは軽微。Athena の最小課金 × クエリ数の見込み。ROUND=5 の結果ファイルの読み出し
# （aws s3 cp）は Athena のクエリではなく S3 の GetObject で、課金には乗らない。
#
# 本物への呼び出し回数の見込み（内訳。実際の回数は下で更新される。GetQueryExecution は
# poll_until_terminal のポーリング + 終端後の 1 回で、開始できた項目の数 × 数回のオーダー。
# メタデータだけの操作なのでどれも数秒で終わる見込み）:
#
# == ROUND=1（元の全項目。挙動・見込みとも変えていない） ==
#
#   [StartQueryExecution]
#   preflight（SELECT 1 + SHOW TABLES）2
#   + 実在する表の準備 1・後始末 1
#   + A 群（ALTER TABLE IF EXISTS、A1〜A19）19
#   + B 群（ADD COLUMN 単数、B1〜B12）12
#   + B' 群（Trino にだけある他の ALTER、B13〜B19）7
#   + C1〜C19（場所の無い CREATE TABLE。C3 だけ location 指定で受理される見込み）19
#     + C3 の後始末 1（受理される見込みのときだけ実際に呼ぶ。他の 18 項目は開始時に弾かれる
#       見込みなので後始末は skip で呼ばない）
#   + C20（S3 Tables。S3TABLES_* が揃うときだけ）受理される見込みなので 1 + 後始末 1
#   + C21（本物の LOCATION 句。受理される見込み）1 + 後始末 1
#   + C22（string 型。受理される見込み）1 + 後始末 1
#   + C23（array<int> 型。受理される見込み）1 + 後始末 1
#   = 68（S3TABLES_* 無し）／70（S3TABLES_* あり）。
#   想定に反して開始時に弾かれなかった項目（C3・C20・C21・C22・C23 以外）があれば、その
#   後始末が 1 本ずつ増える。逆に C3・C20・C21・C22・C23 が想定に反して開始時に弾かれれば、
#   その後始末は skip になり呼ばない（その分 1 本ずつ減る）。
#   DB が実在しなければ、SHOW DATABASES の 1 回を追加で呼んで（候補一覧をファイルに残して）
#   その場で止まる（以降は呼ばない）。
#
#   [GetQueryExecution]
#   実際に開始できた（QueryExecutionId が取れた）項目だけ、終端状態になるまで 1 秒間隔で
#   ポーリングし（poll_until_terminal）、終端後にもう 1 回まとめて取得する。見込みは
#   preflight 2・準備/後始末 2・C3/C20/C21/C22/C23 とその後始末 8〜10 の、合計 12〜14 項目
#   × 2〜4 回で、だいたい 25〜55 回程度（メタデータだけの操作で数秒以内に終わる想定）。
#
#   開始時に弾かれた（START_FAILED）項目があっても追加の呼び出しはしない
#   （AthenaErrorCode・Message は同じ標準エラーからそのまま抜くため）。
#
# == ROUND=2（E・F・G 群のみ。preflight・DB 確認・実在する表の準備/後始末は共通） ==
#
#   [StartQueryExecution]
#   preflight（SELECT 1 + SHOW TABLES）2
#   + 実在する表の準備 1・後始末 1
#   + E 群（CREATE TABLE の型名、e1〜e25）25
#   + F 群（LIKE と Trino の型の中身、f1〜f16）16
#   + G 群（Trino 形の文言の綴り、g1〜g7）7
#   = 52。E・F 群は場所を指定しない CREATE TABLE なので大半は開始時に弾かれる見込みだが、
#   想定に反して受理された項目があれば、その場で DROP する後始末が 1 本ずつ増える
#   （run_create_then_drop を流用）。G 群は ALTER TABLE のみで表を作らないため後始末は無い。
#   DB が実在しなければ ROUND=1 と同様に SHOW DATABASES で候補一覧を残してその場で止まる。
#
#   [GetQueryExecution]
#   実際に開始できた項目だけ終端状態までポーリングし、終端後にもう 1 回まとめて取得する。
#   preflight・DB 確認・実在する表の準備/後始末の 4 項目に加え、受理された E・F 群と
#   その後始末、開始できた G 群の項目が乗る見込み。件数は受理され方次第で変わる
#   （4〜52 項目程度 × 2〜4 回）。
#
# == ROUND=3（H・Q・P 群のみ。issue #221。preflight・DB 確認は共通、実在する表は作らない） ==
#
#   [StartQueryExecution]
#   preflight（SELECT 1 + SHOW TABLES）2
#   + H 群（S3TABLES_* が揃うときだけ。h0 の SELECT 1 と h1〜h9 の CREATE TABLE）10
#   + Q 群（引用符付きの列名と型、q0〜q8）9
#   + P 群（4 部以上の無引用の名前、p0〜p8）9
#   = 20（S3TABLES_* 無し）／30（あり）。
#   受理された CREATE TABLE ごとに、その場で DROP する後始末が 1 本ずつ増える
#   （最大で S3TABLES_* 無し +18、あり +27）。h1〜h7 は受理されうる。
#   DB が実在しなければ ROUND=1 と同様に SHOW DATABASES で候補一覧を残してその場で止まる。
#
#   [GetQueryExecution]
#   実際に開始できた項目だけ終端状態までポーリングし、終端後にもう 1 回まとめて取得する。
#   preflight 2 と h0 に加え、受理された CREATE とその後始末が乗る見込み
#   （2〜57 項目程度 × 2〜4 回）。
#
# == ROUND=4（I 群のみ。issue #224。preflight・DB 確認は共通、実在する表は作らない） ==
#
#   [StartQueryExecution]
#   preflight（SELECT 1 + SHOW TABLES）2
#   + I 群（i0 の SELECT 1 と i1〜i22 の CREATE TABLE。S3TABLES_* が無ければ i18 だけ）23
#   = 25（S3TABLES_* あり）／3（無し）。
#   受理された CREATE TABLE ごとに、その場で DROP する後始末が 1 本ずつ増える（最大 +22）。
#   i14・i15（LOCATION 付き）・i12（CTAS）・i17・i18 は受理されうる。
#
#   [GetQueryExecution]
#   開始できた項目だけ終端状態までポーリングし、終端後にもう 1 回まとめて取得する。
#
# == ROUND=8（M 群のみ。issue #242。preflight・DB 確認は共通、実在する表 <PROBE>_real は作らない） ==
#
#   [StartQueryExecution]
#   preflight 2 + 準備 4（表・ビュー・別の DB・その表）+ M 群 36 + 後始末 6 = 48。
#   DDL: 表 <PROBE>_m・ビュー <PROBE>_mv・DB <PROBE>_db2・表 <PROBE>_db2.<PROBE>_m2・m35 の表・m36 のビューを作って消す。
#
# == ROUND=7（L 群のみ。issue #240。preflight・DB 確認は共通、実在する表は作らない） ==
#
#   [StartQueryExecution]
#   preflight（SELECT 1 + SHOW TABLES）2 + L 群（l0〜l28）29 = 31（S3TABLES_* が無ければ l13 を引いて 30）。
#   l12・l13 が受理されたら、その場で DROP する後始末が 1 本ずつ増える（最大 +2）。
#   l22〜l26 は同じ ClientRequestToken で投げる（冪等なら同じ QueryExecutionId が返り、実行は増えない）。
#
# == ROUND=6（K 群のみ。issue #228。preflight・DB 確認は共通、実在する表は作らない） ==
#
#   [StartQueryExecution]
#   preflight（SELECT 1 + SHOW TABLES）2 + K 群（k0〜k28）29
#   + S3TABLES_* が揃うときだけ k29・k30 の 2 = 33（あり）／31（無し）。
#   受理された CREATE TABLE ごとに、その場で DROP する後始末が 1 本ずつ増える（最大 +4）。
#
#   [GetQueryExecution]
#   開始できた項目だけ終端状態までポーリングし、終端後にもう 1 回まとめて取得する。
#
# == ROUND=5（J 群のみ。issue #227。preflight・DB 確認は共通、実在する表は作らない） ==
#
#   [StartQueryExecution]
#   preflight（SELECT 1 + SHOW TABLES）2
#   + J 群のうち S3TABLES_* が揃うときだけ（j0 の SELECT 1 と j1〜j13 の CREATE TABLE）14
#   + j14〜j16（既定の Context。S3TABLES_* によらず常に投げる）3
#   = 19（S3TABLES_* あり）／5（無し）。
#   受理された CREATE TABLE ごとに、その場で DROP する後始末が 1 本ずつ増える
#   （最大 +16）。仮説どおりなら j1・j4・j11・j13 は受理されうる。
#
#   [GetQueryExecution]
#   開始できた項目だけ終端状態までポーリングし、終端後にもう 1 回まとめて取得する。
#
#   [その他]
#   FAILED になった項目ごとに、結果ファイル本体と `<OutputLocation>.metadata` の取得
#   （aws s3 cp、それぞれ 1 回）を追加で呼ぶ（最大で J 群の項目数 × 2 回）。Athena の
#   API ではないので上の StartQueryExecution・GetQueryExecution の回数には含めない。
#
# == ROUND=9（N 群のみ。issue #229。preflight・DB 確認は共通、実在する表は作らない） ==
#
#   [StartQueryExecution]
#   preflight（SELECT 1 + SHOW TABLES）2
#   + N 群のうち S3TABLES_* が揃うときだけ（n0 の SELECT 1 と n1〜n30・n32 の CREATE TABLE の 32）
#   + n31（既定の Context。S3TABLES_* によらず常に投げる）1
#   = 35（S3TABLES_* あり）／3（無し）。
#   受理された CREATE TABLE ごとに、その場で DROP する後始末が 1 本ずつ増える（最大 +32）。
#   LOCATION 無しの n11・n12・n21・n26・n27 と、既定の Context の対照 n31 は受理されうる。
#
#   [GetQueryExecution]
#   開始できた項目だけ終端状態までポーリングし、終端後にもう 1 回まとめて取得する。
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く。前の回の結果と混ざらない。
#
# 項目ごとに次を保存する（取れたものだけ）。
#   <label>.sql            投げた SQL そのもの（**DB 名・テーブル名を含む。実名を含む**）
#   <label>.start.err      StartQueryExecution の標準エラー（開始時に弾かれた証拠）。
#                          一切加工せず AWS CLI の出力そのまま保存する。
#   <label>.execution.json GetQueryExecution の生の応答（開始できた項目だけ）
#   <label>.execution.err  GetQueryExecution の標準エラー
#   <label>.reason.txt     StateChangeReason と AthenaError（**実名を含みうる。貼る前に確認**）
#   available-databases.rows.txt  DB が実在しなかったときの候補一覧（**実名**）
#
# summary の決め手になる列は state・statement_type/substatement_type・
# start_message/start_athena_error_code（開始時に弾かれた項目）・
# error_category/error_type/error_message（開始できて FAILED になった項目）。
# DB 名・出力先・バケット名・対象テーブル名・S3 Tables の名前は出さず、プレースホルダに
# 畳む。summary.tsv / summary.txt はそのまま貼れる。
#
# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。

set -uo pipefail

: "${OUTPUT:?OUTPUT に s3://bucket/prefix/ を設定してください}"
: "${DB:?DB にデータベース名を設定してください}"
ROUND=${ROUND:-1}
case "$ROUND" in
  1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9) ;;
  *)
    echo "ROUND には 1・2・3・4・5・6・7・8・9 のどれかを指定してください（既定 1）" >&2
    exit 1
    ;;
esac
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_DIR=${OUT_DIR:-${DEV_HOST_HOME:-$HOME}/athena-unquoted-ddl-measurements}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}
S3TABLES_CATALOG=${S3TABLES_CATALOG:-}
S3TABLES_NS=${S3TABLES_NS:-}
# S3TABLES_CATALOG が s3tablescatalog/<バケット> の形なら、そのバケット名（伏せ字用）。
S3TABLES_BUCKET=""
case "$S3TABLES_CATALOG" in
  */*) S3TABLES_BUCKET=${S3TABLES_CATALOG#*/} ;;
esac

# 実行のたびに変わる乱数入りの接頭辞。CREATE の対象は項目ごとに <PREFIX>_c1 のように別名。
RAND_SUFFIX=$(printf '%04x' $((RANDOM % 65536)))
PROBE_PREFIX="athena_local_probe_208_${RAND_SUFFIX}"
NOPE="${PROBE_PREFIX}_nope"
NOPE2="${PROBE_PREFIX}_nope2"
REAL="${PROBE_PREFIX}_real"

new_name() { printf '%s_%s' "$PROBE_PREFIX" "$1"; }

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.tsv"
printf 'label\tstate\tstatement_type\tsubstatement_type\tstart_message\tstart_athena_error_code\terror_category\terror_type\terror_message\treason_line\tnote\n' > "$SUMMARY"
echo "出力先: $RUN_DIR"

# StartQueryExecution を実際に呼んだ回数（再試行も含む）。summary.txt の冒頭に出す。
START_CALL_FILE="$RUN_DIR/.start-calls"
: > "$START_CALL_FILE"

# 実在する表のセットアップに着手したかどうか。trap での後始末に使う（雛形の DDL_ATTEMPTED）。
REAL_SETUP_ATTEMPTED=0
REAL_SETUP_OK=0
# C1〜C23 のどれかで CREATE TABLE が想定外に（あるいは想定どおり C3/C20/C21/C22/C23 で）
# 成功し、まだ消せていないテーブル名の集合。キーは DB 名を付けない裸のテーブル名。
declare -A PENDING_DROPS=()
# C20（S3 Tables）だけ、DB とは別カタログ・別名前空間に作るので専用のフラグにする。
C20_CREATED=0
# ROUND=3（issue #221）で作られたかもしれず、まだ消せていないテーブルの集合。キーは
# 「DROP を投げる QueryExecutionContext|裸のテーブル名」（名前は new_name で作るので `|` を
# 含まない。区切りは最後の `|`）。run_create_then_drop_ctx が立て、後始末が SUCCEEDED に
# なったら下ろす。
declare -A PENDING_DROPS_CTX=()

# StartQueryExecution に足す引数（ROUND=7 の ClientRequestToken・ExecutionParameters。#240）。ふだんは空。
START_EXTRA=()

# StartQueryExecution に渡す QueryExecutionContext。ふだんは CATALOG・DB で、
# run_in_ctx で 1 文だけ差し替える（preflight・C20）。
QE_CONTEXT="Catalog=$CATALOG,Database=$DB"

# trap の後始末で 1 文だけ投げる（結果は確かめない）。既定の Catalog/DB。
cleanup_drop() {
  aws athena start-query-execution --region "$REGION" \
    --query-string "$1" \
    --query-execution-context "Catalog=$CATALOG,Database=$DB" \
    --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
}

# trap の後始末で 1 文だけ、指定した QueryExecutionContext で投げる（C20 用）。
cleanup_drop_in_ctx() {
  local ctx=$1 sql=$2
  aws athena start-query-execution --region "$REGION" \
    --query-string "$sql" \
    --query-execution-context "$ctx" \
    --result-configuration "OutputLocation=$OUTPUT" >/dev/null 2>&1 || true
}

# 中間ファイル（.tmp-*）は、途中で止めても残らないよう trap で消す。実在する表の
# セットアップに着手していたら、ベストエフォートで後始末を投げる。PENDING_DROPS に
# 残っている名前（本編の -cleanup で消せなかったもの）も同様にベストエフォートで消す。
cleanup() {
  rm -f "$RUN_DIR"/.tmp-*
  if [ "$REAL_SETUP_ATTEMPTED" = 1 ]; then
    cleanup_drop "DROP TABLE IF EXISTS $REAL"
  fi
  local name
  for name in "${!PENDING_DROPS[@]}"; do
    cleanup_drop "DROP TABLE IF EXISTS $name"
  done
  if [ "$C20_CREATED" = 1 ] && [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
    cleanup_drop_in_ctx "Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS" \
      "DROP TABLE IF EXISTS $(new_name c20)"
  fi
  local key
  for key in "${!PENDING_DROPS_CTX[@]}"; do
    # ROUND=8 のビュー（<PROBE>_mv・<PROBE>_m36）は DROP VIEW で消す（#242）。
    case "${key##*|}" in
      "${PROBE_PREFIX}_mv" | "${PROBE_PREFIX}_m36") cleanup_drop_in_ctx "${key%|*}" "DROP VIEW IF EXISTS ${key##*|}" ;;
      *) cleanup_drop_in_ctx "${key%|*}" "DROP TABLE IF EXISTS ${key##*|}" ;;
    esac
  done
  # ROUND=8 で作った別の DB が残っていれば、中の表ごと消す（#242）。
  if [ "${M_DB2_OK:-0}" = 1 ] && ! grep -qs "^State: SUCCEEDED" "$RUN_DIR/m-drop-db2.reason.txt"; then
    cleanup_drop "DROP DATABASE IF EXISTS ${PROBE_PREFIX}_db2 CASCADE"
  fi
}
trap cleanup EXIT

# 実名（DB 名・出力先・バケット名・アカウント ID・接頭辞の乱数）を置換して隠す。
# アカウント ID は、前後が数字でない 12 桁の数字として伏せる（quoted-names.sh の実測より）。
OUTPUT_BUCKET=${OUTPUT#s3://}
OUTPUT_BUCKET=${OUTPUT_BUCKET%%/*}
# 伏せる実名と置き換える印を「長さ<TAB>実名<TAB>印」で 1 行ずつ出す（空の実名は出さない）。
hide_pairs() {
  local value mark
  while IFS=$'\t' read -r value mark; do
    [ -n "$value" ] && printf '%s\t%s\t%s\n' "${#value}" "$value" "$mark"
  done <<EOF
$DB	<DB>
$OUTPUT	<OUTPUT>
$OUTPUT_BUCKET	<BUCKET>
$PROBE_PREFIX	<PROBE>
$S3TABLES_CATALOG	<S3TABLES_CATALOG>
$S3TABLES_BUCKET	<S3TABLES_BUCKET>
$S3TABLES_NS	<S3TABLES_NS>
${DB^^}	<DB_UPPER>
EOF
}

# 実名をすべて伏せる。実名どうしが入れ子になる（S3 Tables の名前空間が DB 名を含む、DB 名が S3 Tables の
# バケット名を含む、など）と、短い方を先に置き換えた時点で長い方が一致しなくなって一部が残るので、長い実名
# から先に置き換える（#221 の summary で名前空間の実名の一部が残った。#224）。
hide() {
  local s=$1 value mark
  while IFS=$'\t' read -r _ value mark; do
    s=${s//"$value"/$mark}
  done < <(hide_pairs | sort -t $'\t' -k1,1nr)
  printf '%s' "$s" | sed -E 's/(^|[^0-9])[0-9]{12}([^0-9]|$)/\1<ACCOUNT_ID>\2/g'
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

# start.err から Message と AthenaErrorCode を抜く（quoted-names.sh の実測どおり、
# 開始時に弾かれた StartQueryExecution の標準エラーに追加の呼び出し無しで両方出る）。
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
      "${START_EXTRA[@]}" \
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

# ラベルを指定して 1 文を実行する。開始できなければ、AthenaErrorCode・Message を
# その場の start.err からそのまま抜く（追加の呼び出しはしない）。開始できたら終端状態まで
# 待って StatementType・SubstatementType・FAILED の理由を採る。
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

# QueryExecutionContext を $1 に差し替えて run を 1 回呼ぶ（preflight・C20 で使う）。
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

# <label>.reason.txt が FAILED を示していれば真（ROUND=5 の付随物取得で使う）。
is_failed() {
  grep -qs "^State: FAILED" "$RUN_DIR/$1.reason.txt"
}

# <label>.execution.json の OutputLocation を返す（無ければ空文字）。
output_location_of() {
  local loc
  IFS=$'\t' read -r _ loc _ < <(read_execution_fields "$RUN_DIR/$1.execution.json")
  printf '%s' "$loc"
}

# uri の中身を標準出力にコピーして out に保存する（ROUND=5 の付随物取得で使う）。
# 失敗したら out は作らず、標準エラーを err に残す。成功したら err を消す。
# uri が空なら何もしない。
fetch_s3_body() {
  local uri=$1 out=$2 err=$3
  [ -n "$uri" ] || return 0
  if aws s3 cp "$uri" - --region "$REGION" > "$out" 2> "$err"; then
    rm -f "$err"
  else
    rm -f "$out"
  fi
}

# FAILED になった項目（引数に渡したラベルのうち）だけ、結果ファイル本体、次に
# `<OutputLocation>.metadata` を取得して保存する（ROUND=5、issue #227）。
# <label>.output.txt / <label>.output.metadata に保存し、取得できなければ
# <label>.output.txt.err / <label>.output.metadata.err に標準エラーを残す。
fetch_failed_attachments() {
  local label loc
  for label in "$@"; do
    is_failed "$label" || continue
    loc=$(output_location_of "$label")
    [ -n "$loc" ] || continue
    fetch_s3_body "$loc" "$RUN_DIR/$label.output.txt" "$RUN_DIR/$label.output.txt.err"
    fetch_s3_body "${loc}.metadata" "$RUN_DIR/$label.output.metadata" "$RUN_DIR/$label.output.metadata.err"
  done
}

# CREATE TABLE を投げ、成功したら（想定どおりでも想定外でも）その場で
# DROP TABLE IF EXISTS <name> を <label>-cleanup として投げて消す。成功するまで
# PENDING_DROPS[name] を立てておき、後始末が SUCCEEDED になったら下ろす（trap の保険が
# 対象にする名前の集合）。CREATE TABLE が失敗したら後始末は未測定の行だけ残す。
run_create_then_drop() {
  local label=$1 sql=$2 name=$3
  if run "$label" "$sql"; then
    PENDING_DROPS[$name]=1
    run "$label-cleanup" "DROP TABLE IF EXISTS $name"
    if succeeded "$label-cleanup"; then
      unset 'PENDING_DROPS[$name]'
    fi
  else
    skip "$label-cleanup" "CREATE TABLE が失敗したため後始末不要"
  fi
}

# run_create_then_drop の QueryExecutionContext 付き版（ROUND=3、issue #221）。
# CREATE TABLE を $1 の Context で投げ、成功したら DROP TABLE IF EXISTS <name> を $2 の
# Context で <label>-cleanup として投げて消す。作る Context と消す Context を分けるのは、
# S3 Tables の Context で AwsDataCatalog の 3 部の名前を作る項目（h8）があるため。
# 後始末が SUCCEEDED になるまで PENDING_DROPS_CTX["<消す Context>|<name>"] を立てておく
# （trap の保険が対象にする組の集合）。CREATE TABLE が失敗したら後始末は未測定の行だけ残す。
run_create_then_drop_ctx() {
  local create_ctx=$1 drop_ctx=$2 label=$3 sql=$4 name=$5
  local key="$drop_ctx|$name"
  if run_in_ctx "$create_ctx" "$label" "$sql"; then
    PENDING_DROPS_CTX[$key]=1
    run_in_ctx "$drop_ctx" "$label-cleanup" "DROP TABLE IF EXISTS $name"
    if succeeded "$label-cleanup"; then
      unset 'PENDING_DROPS_CTX[$key]'
    fi
  else
    skip "$label-cleanup" "CREATE TABLE が失敗したため後始末不要"
  fi
}

# --- preflight -----------------------------------------------------------------
# Database を渡さず Catalog だけで疎通を確かめる（DB の実在確認より先に、資格情報や
# エンドポイントの問題を切り分ける）。

if ! run_in_ctx "Catalog=$CATALOG" preflight-select1 "SELECT 1"; then
  echo
  echo "疎通確認（SELECT 1）が通りませんでした。資格情報かエンドポイント（REGION=$REGION）を"
  echo "確かめてください。理由: $RUN_DIR/preflight-select1.reason.txt"
  echo "（開始すらできなければ $RUN_DIR/preflight-select1.start.err）"
  exit 1
fi

# --- DB の実在確認 ---------------------------------------------------------------

fetch_all_rows() {
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

if ! run probe-show-tables "SHOW TABLES"; then
  echo
  echo "SHOW TABLES が通りませんでした。DB が実在しないかもしれません。"
  echo "理由: $RUN_DIR/probe-show-tables.reason.txt"
  if run_in_ctx "Catalog=$CATALOG" available-databases "SHOW DATABASES"; then
    fetch_all_rows "$(query_id_of available-databases)" "$RUN_DIR/available-databases.rows.txt"
    echo "候補の一覧: $RUN_DIR/available-databases.rows.txt（実名を含むので確認してから使ってください）"
  fi
  exit 1
fi

# --- 実在する表のセットアップ（B10・C15、ROUND=2 の F1・F3・F4・F5 の対照に使う） --------
# WITH (format='PARQUET') は本物で external_location が要るかもしれないため、
# quoted-names.sh の d0-setup-hive と同じ「WITH 句を付けない CTAS」の形にした。
# ROUND=3・4・5・6 は実在する表を使わないので作らない
# （REAL_SETUP_ATTEMPTED・REAL_SETUP_OK は 0 のまま）。

if [ "$ROUND" = 1 ] || [ "$ROUND" = 2 ]; then
REAL_SETUP_ATTEMPTED=1
if run setup-real "CREATE TABLE $DB.$REAL AS SELECT 1 AS n, 'x' AS s, 10 AS x"; then
  REAL_SETUP_OK=1
else
  echo "== setup-real: 実在する表が作れませんでした。B10・ROUND=2 の F1・F3・F4・F5 は実在しない名前を対象にします。"
fi
fi # ROUND = 1 || ROUND = 2

if [ "$REAL_SETUP_OK" = 1 ]; then
  LIKE_TARGET="$DB.$REAL"
else
  LIKE_TARGET="$NOPE"
fi

# ROUND=2 の F 群（LIKE と Trino の型の中身）で使う、実在する表を指す 1/2/3 部の名前。
# 準備できていなければ、同じ部数の実在しない名前にフォールバックする（依頼どおり）。
if [ "$REAL_SETUP_OK" = 1 ]; then
  LIKE_REAL_1PART="$REAL"
  LIKE_REAL_2PART="$DB.$REAL"
  LIKE_REAL_3PART="awsdatacatalog.$DB.$REAL"
else
  LIKE_REAL_1PART="$NOPE"
  LIKE_REAL_2PART="$DB.$NOPE"
  LIKE_REAL_3PART="awsdatacatalog.$DB.$NOPE"
fi

# ROUND=1 だけ、元の A・B・B'・C 群（S3 Tables 含む）を投げる。ROUND=2 は後段の E・F・G 群。
if [ "$ROUND" = 1 ]; then

# --- A 群（ALTER TABLE IF EXISTS。続く操作と位置の規則） ----------------------------

run a1  "ALTER TABLE IF EXISTS $NOPE RENAME TO $NOPE2"
run a2  "ALTER TABLE IF EXISTS $NOPE ADD COLUMN m int"
run a3  "ALTER TABLE IF EXISTS $NOPE ADD COLUMNS (m int)"
run a4  "ALTER TABLE IF EXISTS $NOPE DROP COLUMN m"
run a5  "ALTER TABLE IF EXISTS $NOPE RENAME COLUMN a TO b"
run a6  "ALTER TABLE IF EXISTS $NOPE SET PROPERTIES x = 1"
run a7  "ALTER TABLE IF EXISTS $NOPE SET TBLPROPERTIES ('a'='b')"
run a8  "ALTER TABLE IF EXISTS $NOPE EXECUTE optimize"
run a9  "ALTER TABLE IF EXISTS $NOPE ADD COLUMN IF NOT EXISTS m int"
run a10 "ALTER TABLE IF EXISTS $NOPE ALTER COLUMN m SET DATA TYPE bigint"
run a11 "ALTER TABLE IF EXISTS $DB.$NOPE RENAME TO $DB.$NOPE2"
run a12 "ALTER TABLE IF EXISTS awsdatacatalog.$DB.$NOPE RENAME TO $DB.$NOPE2"
run a13 "alter table if exists $NOPE rename to $NOPE2"
run a14 "/* c */ ALTER TABLE IF EXISTS $NOPE RENAME TO $NOPE2"
# 改行を挟む形。$'...' は変数展開しないので、改行だけを断片にして隣接させて連結する
# （tools/measure/leading-comment.sh の注意のとおり）。
run a15 "ALTER TABLE"$'\n'"IF EXISTS $NOPE RENAME TO $NOPE2"
run a16 "ALTER  TABLE  IF  EXISTS $NOPE RENAME TO $NOPE2"
run a17 "ALTER TABLE /* c */ IF EXISTS $NOPE RENAME TO $NOPE2"
run a18 "ALTER TABLE IF EXISTS $DB.$NOPE ADD COLUMNS (m int)"
run a19 "ALTER TABLE IF EXISTS $NOPE DROP COLUMN IF EXISTS m"

# --- B 群（ADD COLUMN 単数） ------------------------------------------------------

run b1  "ALTER TABLE $NOPE ADD COLUMN m int"
run b2  "alter table $NOPE add column m int"
run b3  "/* c */ ALTER TABLE $NOPE ADD COLUMN m int"
run b4  "ALTER TABLE $NOPE ADD"$'\n'"COLUMN m int"
run b5  "ALTER TABLE $NOPE ADD /* c */ COLUMN m int"
run b6  "ALTER TABLE $DB.$NOPE ADD COLUMN m int"
run b7  "ALTER TABLE awsdatacatalog.$DB.$NOPE ADD COLUMN m int"
run b8  "ALTER TABLE $NOPE ADD COLUMN IF NOT EXISTS m int"
run b9  "ALTER TABLE $NOPE ADD COLUMN m int COMMENT 'x'"
if [ "$REAL_SETUP_OK" = 1 ]; then
  run b10 "ALTER TABLE $DB.$REAL ADD COLUMN m int"
else
  skip b10 "実在する表を作れなかったため未測定"
fi
run b11 "ALTER TABLE $NOPE  ADD  COLUMN m int"
run b12 "ALTER TABLE $NOPE ADD COLUMN m varchar"

# --- B' 群（Trino にだけある他の ALTER。範囲の把握用。IF EXISTS 無し） -------------------

run b13 "ALTER TABLE $NOPE RENAME COLUMN a TO b"
run b14 "ALTER TABLE $NOPE SET PROPERTIES x = 1"
run b15 "ALTER TABLE $NOPE EXECUTE optimize"
run b16 "ALTER TABLE $NOPE ALTER COLUMN m SET DATA TYPE bigint"
run b17 "ALTER TABLE $NOPE DROP COLUMN IF EXISTS m"
run b18 "ALTER TABLE $NOPE SET AUTHORIZATION someone"
run b19 "ALTER TABLE $NOPE DROP COLUMN m"

# --- C 群（場所の無い CREATE TABLE） -----------------------------------------------

run_create_then_drop c1  "CREATE TABLE $(new_name c1) (n int)" "$(new_name c1)"
run_create_then_drop c2  "CREATE TABLE $(new_name c2) (n int) WITH (format = 'PARQUET')" "$(new_name c2)"
LOC_C3="${OUTPUT%/}/${PROBE_PREFIX}-c3/"
run_create_then_drop c3  "CREATE TABLE $(new_name c3) (n int) WITH (location = '$LOC_C3')" "$(new_name c3)"
run_create_then_drop c4  "CREATE TABLE $(new_name c4) (n int) COMMENT 'x'" "$(new_name c4)"
run_create_then_drop c5  "CREATE TABLE $(new_name c5) (n varchar)" "$(new_name c5)"
run_create_then_drop c6  "CREATE TABLE $(new_name c6) (n integer)" "$(new_name c6)"
run_create_then_drop c7  "CREATE TABLE $(new_name c7) (n timestamp(3))" "$(new_name c7)"
run_create_then_drop c8  "CREATE TABLE $(new_name c8) (n row(a int))" "$(new_name c8)"
run_create_then_drop c9  "CREATE TABLE $(new_name c9) (n array(int))" "$(new_name c9)"
run_create_then_drop c10 "CREATE TABLE $(new_name c10) (n int COMMENT 'x')" "$(new_name c10)"
run_create_then_drop c11 "CREATE TABLE $(new_name c11) (n int NOT NULL)" "$(new_name c11)"
run_create_then_drop c12 "create table $(new_name c12) (n int)" "$(new_name c12)"
run_create_then_drop c13 "/* c */ CREATE TABLE $(new_name c13) (n int)" "$(new_name c13)"
run_create_then_drop c14 "CREATE TABLE awsdatacatalog.$DB.$(new_name c14) (n int)" "$(new_name c14)"
run_create_then_drop c15 "CREATE TABLE $(new_name c15) (LIKE $LIKE_TARGET)" "$(new_name c15)"
run_create_then_drop c16 "CREATE TABLE $(new_name c16) (n int) WITH (partitioned_by = ARRAY['n'])" "$(new_name c16)"
run_create_then_drop c17 "CREATE TABLE $(new_name c17) (n double, m decimal(10,2), s varchar(10), d date, b boolean)" "$(new_name c17)"
run_create_then_drop c18 "CREATE TABLE $(new_name c18) (n int, m map(varchar, int))" "$(new_name c18)"
run_create_then_drop c19 "CREATE TABLE $(new_name c19) (n int) WITH (table_type = 'ICEBERG')" "$(new_name c19)"

# C20: S3 Tables（S3TABLES_CATALOG・S3TABLES_NS が両方揃ったときだけ）。
# QueryExecutionContext の Catalog を S3 Tables のカタログ、Database を名前空間にして、
# 1 部の名前だけの CREATE TABLE を投げる。引用符付きの形（"<catalog>".<ns>.X）は
# 既に文言が分かっている（quoted-names.sh）ので測らない。
if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  C20_NAME=$(new_name c20)
  S3T_CTX="Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS"
  if run_in_ctx "$S3T_CTX" c20 "CREATE TABLE $C20_NAME (n int)"; then
    C20_CREATED=1
    run_in_ctx "$S3T_CTX" c20-cleanup "DROP TABLE IF EXISTS $C20_NAME"
    if succeeded c20-cleanup; then
      C20_CREATED=0
    fi
  else
    skip c20-cleanup "CREATE TABLE が失敗したため後始末不要"
  fi
else
  skip c20 "未測定（S3TABLES_CATALOG・S3TABLES_NS 未設定）"
  skip c20-cleanup "CREATE TABLE が失敗したため後始末不要"
fi

# C21: 本物の書き方の対照（HiveQL 形の LOCATION 句）。受けて作られる見込み。
LOC_C21="${OUTPUT%/}/${PROBE_PREFIX}-c21/"
run_create_then_drop c21 "CREATE TABLE $(new_name c21) (n int) LOCATION '$LOC_C21'" "$(new_name c21)"

# C22・C23: コーディネーターからの追加指示（手元の Trino 482 が受理すると分かったため）。
# string 型・array<int> 型（Hive 互換の型名）。作られうるので後始末の対象にする。
run_create_then_drop c22 "CREATE TABLE $(new_name c22) (n string)" "$(new_name c22)"
run_create_then_drop c23 "CREATE TABLE $(new_name c23) (n array<int>)" "$(new_name c23)"

fi # ROUND=1

# ROUND=2 だけ、E・F・G 群を投げる（#208 ラウンド 2）。
if [ "$ROUND" = 2 ]; then

# --- E 群（CREATE TABLE の型名。No location になるか、構文の文言になるか） ----------------
# 場所を指定しないので、C 群と同様に大半は開始時に弾かれる見込み。型名の書き方によって
# 弾かれ方（No location か、構文エラーの文言か）が変わるかどうかを見る。

run_create_then_drop e1  "CREATE TABLE $(new_name e1) (n bigint)" "$(new_name e1)"
run_create_then_drop e2  "CREATE TABLE $(new_name e2) (n tinyint)" "$(new_name e2)"
run_create_then_drop e3  "CREATE TABLE $(new_name e3) (n smallint)" "$(new_name e3)"
run_create_then_drop e4  "CREATE TABLE $(new_name e4) (n real)" "$(new_name e4)"
run_create_then_drop e5  "CREATE TABLE $(new_name e5) (n float)" "$(new_name e5)"
run_create_then_drop e6  "CREATE TABLE $(new_name e6) (n char(3))" "$(new_name e6)"
run_create_then_drop e7  "CREATE TABLE $(new_name e7) (n varbinary)" "$(new_name e7)"
run_create_then_drop e8  "CREATE TABLE $(new_name e8) (n binary)" "$(new_name e8)"
run_create_then_drop e9  "CREATE TABLE $(new_name e9) (n uuid)" "$(new_name e9)"
run_create_then_drop e10 "CREATE TABLE $(new_name e10) (n json)" "$(new_name e10)"
run_create_then_drop e11 "CREATE TABLE $(new_name e11) (n ipaddress)" "$(new_name e11)"
run_create_then_drop e12 "CREATE TABLE $(new_name e12) (n foo)" "$(new_name e12)"
run_create_then_drop e13 "CREATE TABLE $(new_name e13) (n timestamp)" "$(new_name e13)"
run_create_then_drop e14 "CREATE TABLE $(new_name e14) (n time)" "$(new_name e14)"
run_create_then_drop e15 "CREATE TABLE $(new_name e15) (n time(3))" "$(new_name e15)"
run_create_then_drop e16 "CREATE TABLE $(new_name e16) (n timestamp(3) with time zone)" "$(new_name e16)"
run_create_then_drop e17 "CREATE TABLE $(new_name e17) (n double precision)" "$(new_name e17)"
run_create_then_drop e18 "CREATE TABLE $(new_name e18) (n decimal)" "$(new_name e18)"
run_create_then_drop e19 "CREATE TABLE $(new_name e19) (n struct<a:int,b:string>)" "$(new_name e19)"
run_create_then_drop e20 "CREATE TABLE $(new_name e20) (n map<string,int>)" "$(new_name e20)"
run_create_then_drop e21 "CREATE TABLE $(new_name e21) (n array<array<int>>)" "$(new_name e21)"
run_create_then_drop e22 "CREATE TABLE $(new_name e22) (n INT)" "$(new_name e22)"
run_create_then_drop e23 "CREATE TABLE $(new_name e23) (n varchar(10, 2))" "$(new_name e23)"
run_create_then_drop e24 "CREATE TABLE $(new_name e24) (n interval day to second)" "$(new_name e24)"
run_create_then_drop e25 "CREATE TABLE $(new_name e25) (n int, m bigint, s string)" "$(new_name e25)"

# --- F 群（LIKE と Trino の型の中身） ----------------------------------------------
# f1・f3・f4・f5 は実在する表（準備できていれば LIKE_REAL_*PART、できていなければ
# 同じ部数の実在しない名前）を LIKE の対象にする。

run_create_then_drop f1  "CREATE TABLE $(new_name f1) (LIKE $LIKE_REAL_1PART)" "$(new_name f1)"
run_create_then_drop f2  "CREATE TABLE $(new_name f2) (LIKE $NOPE)" "$(new_name f2)"
run_create_then_drop f3  "CREATE TABLE $(new_name f3) (LIKE $LIKE_REAL_2PART INCLUDING PROPERTIES)" "$(new_name f3)"
run_create_then_drop f4  "CREATE TABLE $(new_name f4) (LIKE $LIKE_REAL_3PART)" "$(new_name f4)"
run_create_then_drop f5  "CREATE TABLE $(new_name f5) (n int, LIKE $LIKE_REAL_2PART)" "$(new_name f5)"
run_create_then_drop f6  "CREATE TABLE $(new_name f6) (n row(a int, b varchar))" "$(new_name f6)"
run_create_then_drop f7  "CREATE TABLE $(new_name f7) (n array(row(a int)))" "$(new_name f7)"
run_create_then_drop f8  "CREATE TABLE $(new_name f8) (n map(varchar, array(int)))" "$(new_name f8)"
run_create_then_drop f9  "CREATE TABLE $(new_name f9) (n ROW(a int))" "$(new_name f9)"
run_create_then_drop f10 "CREATE TABLE $(new_name f10) (n row( a int))" "$(new_name f10)"
run_create_then_drop f11 "CREATE TABLE $(new_name f11) (m int, n row(a int))" "$(new_name f11)"
run_create_then_drop f12 "CREATE TABLE $(new_name f12) (n int NOT NULL, m int)" "$(new_name f12)"
run_create_then_drop f13 "CREATE TABLE $(new_name f13) (n int) COMMENT 'x' WITH (format = 'PARQUET')" "$(new_name f13)"
run_create_then_drop f14 "CREATE TABLE IF NOT EXISTS $(new_name f14) (n int) WITH (format = 'PARQUET')" "$(new_name f14)"
run_create_then_drop f15 "CREATE TABLE $DB.$(new_name f15) (n int) WITH (format = 'PARQUET')" "$(new_name f15)"
# 改行を挟む形。a15 と同じく、$'...' は変数展開しないので断片にして隣接させて連結する。
run_create_then_drop f16 "CREATE TABLE $(new_name f16) (n int)"$'\n'"WITH (format = 'PARQUET')" "$(new_name f16)"

# --- G 群（Trino 形の文言の綴り。表は作らないので run のみ） -------------------------

run g1 "alter table $NOPE alter column m set data type bigint"
run g2 "alter table if exists $NOPE alter column m set data type bigint"
run g3 "ALTER TABLE $DB.$NOPE ALTER COLUMN m SET DATA TYPE bigint"
run g4 "ALTER TABLE $NOPE RENAME  COLUMN a TO b"
run g5 "alter table $NOPE rename column a to b"
run g6 "alter table $NOPE drop column if exists m"
run g7 "/* c */ ALTER TABLE $NOPE SET PROPERTIES x = 1"

fi # ROUND=2

# ROUND=3 だけ、H・Q・P 群を投げる（issue #221）。
if [ "$ROUND" = 3 ]; then

DEFAULT_CTX="Catalog=$CATALOG,Database=$DB"

# --- H 群（QueryExecutionContext の Catalog が S3 Tables。S3TABLES_* が揃うときだけ） ------
# #208 の C20 の続き。S3 Tables は場所を要らないので、No location にならないかもしれない。
# h1〜h7 は S3 Tables の Context で作られうるので、同じ Context で消す。h8 は S3 Tables の
# Context で AwsDataCatalog の 3 部の名前を作るので、既定の Context で消す。h9 は既定の
# Context の対照（No location の見込み）。h0 は疎通で、失敗しても他の H 項目は投げる。
if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  S3T_CTX="Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS"
  run_in_ctx "$S3T_CTX" h0 "SELECT 1"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" h1 "CREATE TABLE $(new_name h1) (n int)" "$(new_name h1)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" h2 "CREATE TABLE IF NOT EXISTS $(new_name h2) (n int)" "$(new_name h2)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" h3 "CREATE TABLE $(new_name h3) (n int) TBLPROPERTIES ('table_type' = 'iceberg')" "$(new_name h3)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" h4 "CREATE TABLE $S3TABLES_NS.$(new_name h4) (n int)" "$(new_name h4)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" h5 "CREATE TABLE $(new_name h5) (n int NOT NULL)" "$(new_name h5)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" h6 "CREATE TABLE $(new_name h6) (n int) WITH (format = 'PARQUET')" "$(new_name h6)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" h7 "CREATE TABLE $(new_name h7) (n string)" "$(new_name h7)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" h8 "CREATE TABLE awsdatacatalog.$DB.$(new_name h8) (n int)" "$(new_name h8)"
  run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" h9 "CREATE TABLE $(new_name h9) (n int)" "$(new_name h9)"
else
  skip h0 "未測定（S3TABLES_* 未設定）"
  for l in h1 h2 h3 h4 h5 h6 h7 h8 h9; do
    skip "$l" "未測定（S3TABLES_* 未設定）"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

# --- Q 群（列名・型が引用符付き。既定の Context） ------------------------------------
# Hive の文法では "n" は文字列リテラル。q0 は No location の対照。

run_create_then_drop q0 "CREATE TABLE $(new_name q0) (n int)" "$(new_name q0)"
run_create_then_drop q1 "CREATE TABLE $(new_name q1) (\"n\" int)" "$(new_name q1)"
run_create_then_drop q2 "CREATE TABLE $(new_name q2) (n int, \"m\" int)" "$(new_name q2)"
run_create_then_drop q3 "CREATE TABLE $(new_name q3) (\"n\" int NOT NULL)" "$(new_name q3)"
# バッククォート（Hive の引用符）。二重引用符の中なのでバッククォートはエスケープする。
run_create_then_drop q4 "CREATE TABLE $(new_name q4) (\`n\` int)" "$(new_name q4)"
run_create_then_drop q5 "CREATE TABLE IF NOT EXISTS $(new_name q5) (\"n\" int)" "$(new_name q5)"
run_create_then_drop q6 "CREATE TABLE $(new_name q6) (n row(\"f\" int))" "$(new_name q6)"
run_create_then_drop q7 "CREATE TABLE $(new_name q7) (n struct<\"f\":int>)" "$(new_name q7)"
run_create_then_drop q8 "CREATE TABLE $(new_name q8) (n \"int\")" "$(new_name q8)"

# --- P 群（4 部以上の無引用の名前。既定の Context） -----------------------------------
# p0 は #212 で測った形の対照（3 つ目の `.` で弾かれる）。p8 は IF NOT EXISTS の 1 部で、
# No location の対照。万一受理されたときに <db> の下にできうる名前 <接頭辞>_pN を消しにいく。

run_create_then_drop p0 "CREATE TABLE awsdatacatalog.$DB.$(new_name p0).n (n int)" "$(new_name p0)"
run_create_then_drop p1 "CREATE TABLE IF NOT EXISTS awsdatacatalog.$DB.$(new_name p1).n (n int)" "$(new_name p1)"
run_create_then_drop p2 "CREATE TABLE IF NOT EXISTS x.y.$(new_name p2).n (n int)" "$(new_name p2)"
run_create_then_drop p3 "CREATE TABLE IF NOT EXISTS awsdatacatalog.$DB.$(new_name p3).n.m (n int)" "$(new_name p3)"
run_create_then_drop p4 "CREATE TABLE IF NOT EXISTS awsdatacatalog.$DB.$(new_name p4).\"n\" (n int)" "$(new_name p4)"
run_create_then_drop p5 "CREATE TABLE awsdatacatalog.$DB.$(new_name p5).n AS SELECT 1 AS n" "$(new_name p5)"
run_create_then_drop p6 "CREATE TABLE IF NOT EXISTS awsdatacatalog.$DB.$(new_name p6).n AS SELECT 1 AS n" "$(new_name p6)"
run_create_then_drop p7 "CREATE TABLE awsdatacatalog.$DB.$(new_name p7).n WITH (format = 'PARQUET') AS SELECT 1 AS n" "$(new_name p7)"
run_create_then_drop p8 "CREATE TABLE IF NOT EXISTS $(new_name p8) (n int)" "$(new_name p8)"

fi # ROUND=3

# ROUND=4 だけ、I 群を投げる（issue #224）。
if [ "$ROUND" = 4 ]; then

DEFAULT_CTX="Catalog=$CATALOG,Database=$DB"
# LOCATION 付きの項目（i14・i15）の置き場。結果の出力先の下の、項目ごとの空のプレフィックス。
probe_location() { printf '%sathena-local-probe-224/%s/' "$OUTPUT" "$(new_name "$1")"; }

# --- I 群（QueryExecutionContext の Catalog が S3 Tables で、名前が別カタログを指す CREATE TABLE） ----
# #221 の h8（S3 Tables の Context で `CREATE TABLE awsdatacatalog.<db>.<t> (n int)` →
# `Unsupported ddl with 2 catalogs: <文>`）の周辺。i0 は疎通、i1 は h8 の再現（対照）。
# i2〜i4 は名前の形、i5〜i10 は文言の後ろに付く文の書かれ方（大文字小文字・コメント・改行・空白・`;`）、
# i11〜i16 は他の判定（IF NOT EXISTS・CTAS・NV・LOCATION・EXTERNAL）との順番、i17〜i22 は
# 引用符付きの名前と逆向き（既定の Context で S3 Tables のカタログ）と既定の Context の対照。
# AwsDataCatalog に作られうるものは既定の Context で、S3 Tables に作られうるものは S3 Tables の
# Context で消す。
if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  S3T_CTX="Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS"
  run_in_ctx "$S3T_CTX" i0 "SELECT 1"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" i1 "CREATE TABLE awsdatacatalog.$DB.$(new_name i1) (n int)" "$(new_name i1)"
  # 2 部で、1 部目が S3 Tables の名前空間でなく AwsDataCatalog の DB。
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" i2 "CREATE TABLE $DB.$(new_name i2) (n int)" "$DB.$(new_name i2)"
  # 1 部目が実在しないカタログ。
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" i3 "CREATE TABLE nosuchcatalog224.$DB.$(new_name i3) (n int)" "$(new_name i3)"
  # 1 部目が AwsDataCatalog（大文字混じり）。文言の後ろの文がそのままか、小文字にされるか。
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" i4 "CREATE TABLE AwsDataCatalog.$DB.$(new_name i4) (n int)" "$(new_name i4)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" i5 "create table awsdatacatalog.$DB.$(new_name i5) (n int)" "$(new_name i5)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" i6 "/* c */ CREATE TABLE awsdatacatalog.$DB.$(new_name i6) (n int)" "$(new_name i6)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" i7 "-- c
CREATE TABLE awsdatacatalog.$DB.$(new_name i7) (n int)" "$(new_name i7)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" i8 "CREATE TABLE awsdatacatalog.$DB.$(new_name i8)
(
  n int
)" "$(new_name i8)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" i9 "  CREATE  TABLE	awsdatacatalog.$DB.$(new_name i9) (n int)  " "$(new_name i9)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" i10 "CREATE TABLE awsdatacatalog.$DB.$(new_name i10) (n int); -- c" "$(new_name i10)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" i11 "CREATE TABLE IF NOT EXISTS awsdatacatalog.$DB.$(new_name i11) (n int)" "$(new_name i11)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" i12 "CREATE TABLE awsdatacatalog.$DB.$(new_name i12) AS SELECT 1 AS n" "$(new_name i12)"
  # 既定の Context では NV(NOT)・NV(`"n"`)・NV(`WITH` の後の `(`)になる形。2 catalogs と NV のどちらが先か。
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" i13 "CREATE TABLE awsdatacatalog.$DB.$(new_name i13) (n int NOT NULL)" "$(new_name i13)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" i14 "CREATE TABLE awsdatacatalog.$DB.$(new_name i14) (n int) LOCATION '$(probe_location i14)'" "$(new_name i14)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" i15 "CREATE EXTERNAL TABLE awsdatacatalog.$DB.$(new_name i15) (n int) LOCATION '$(probe_location i15)'" "$(new_name i15)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" i16 "CREATE TABLE awsdatacatalog.$DB.$(new_name i16) (\"n\" int)" "$(new_name i16)"
  # 引用符付きの 1 部目（AwsDataCatalog と、Context と同じ S3 Tables のカタログ）。
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" i17 "CREATE TABLE \"awsdatacatalog\".$DB.$(new_name i17) (n int)" "$(new_name i17)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" i19 "CREATE TABLE \"$S3TABLES_CATALOG\".$S3TABLES_NS.$(new_name i19) (n int)" "$(new_name i19)"
  # 逆向き（既定の Context で 1 部目が S3 Tables のカタログ）。
  run_create_then_drop_ctx "$DEFAULT_CTX" "$S3T_CTX" i20 "CREATE TABLE \"$S3TABLES_CATALOG\".$S3TABLES_NS.$(new_name i20) (n int)" "$(new_name i20)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" i21 "CREATE TABLE awsdatacatalog.$DB.$(new_name i21) (n int) WITH (format = 'PARQUET')" "$(new_name i21)"
  # 既定の Context の IF NOT EXISTS の 3 部（No location の見込み。i11 の対照）。
  run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" i22 "CREATE TABLE IF NOT EXISTS awsdatacatalog.$DB.$(new_name i22) (n int)" "$(new_name i22)"
else
  skip i0 "未測定（S3TABLES_* 未設定）"
  for l in i1 i2 i3 i4 i5 i6 i7 i8 i9 i10 i11 i12 i13 i14 i15 i16 i17 i19 i20 i21 i22; do
    skip "$l" "未測定（S3TABLES_* 未設定）"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi
# 既定の Context の 3 部（No location の見込み。i1 の対照）。
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" i18 "CREATE TABLE awsdatacatalog.$DB.$(new_name i18) (n int)" "$(new_name i18)"

fi # ROUND=4

# ROUND=5 だけ、J 群を投げる（issue #227）。
if [ "$ROUND" = 5 ]; then

DEFAULT_CTX="Catalog=$CATALOG,Database=$DB"
# J 群のラベル一覧（j0〜j16。-cleanup は含まない）。ALL_LABELS の組み立てと、後始末の
# 付随物取得（fetch_failed_attachments）・summary の付随物一覧の両方から参照する。
J_LABELS="j0 j1 j2 j3 j4 j5 j6 j7 j8 j9 j10 j11 j12 j13 j14 j15 j16"

# --- J 群（QueryExecutionContext の Catalog が S3 Tables で、別カタログ・別名前空間を
#     指す CREATE TABLE） ----------------------------------------------------------
# #224 の i4（S3 Tables の Context で `CREATE TABLE AwsDataCatalog.<db>.<t> (n int)` が
# 開始でき FAILED になった）の周辺。1 部目が大文字混じりの AwsDataCatalog だと S3 Tables
# 側の名前として扱われ、2 部目が S3 Tables の名前空間として引かれているという仮説を、
# 2 部目を S3TABLES_NS に変えた形（j1・j4）や、既定の Context 側の対照（j14〜j16）などで
# 確かめる。j0 は疎通。S3 Tables に作られうる項目（仮説どおりなら j1・j4・j11・j13）は
# S3 Tables の Context で、AwsDataCatalog・実在しないカタログ側を指す項目は既定の
# Context で消す。
if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  S3T_CTX="Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS"
  run_in_ctx "$S3T_CTX" j0 "SELECT 1"
  # 仮説の検証: 1 部目が AwsDataCatalog（大文字混じり）、2 部目が S3 Tables の名前空間。
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" j1 "CREATE TABLE AwsDataCatalog.$S3TABLES_NS.$(new_name j1) (n int)" "$(new_name j1)"
  # i4 の再現（対照）。2 部目が AwsDataCatalog 側の DB。
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" j2 "CREATE TABLE AwsDataCatalog.$DB.$(new_name j2) (n int)" "$(new_name j2)"
  # 1 部目が全部大文字。
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" j3 "CREATE TABLE AWSDATACATALOG.$DB.$(new_name j3) (n int)" "$(new_name j3)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" j4 "CREATE TABLE AWSDATACATALOG.$S3TABLES_NS.$(new_name j4) (n int)" "$(new_name j4)"
  # 1 部目が実在しないカタログ。2 部目が S3 Tables の名前空間／AwsDataCatalog の DB。
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" j5 "CREATE TABLE nosuchcatalog227.$S3TABLES_NS.$(new_name j5) (n int)" "$(new_name j5)"
  # 文言の中のカタログ名の大文字小文字。
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" j6 "CREATE TABLE NoSuchCatalog227.$DB.$(new_name j6) (n int)" "$(new_name j6)"
  # NV（NOT NULL）と DATACATALOG_NOT_FOUND の順番。
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" j7 "CREATE TABLE nosuchcatalog227.$DB.$(new_name j7) (n int NOT NULL)" "$(new_name j7)"
  # NV が「2 catalogs」より先に判定されるか。
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" j8 "CREATE TABLE AwsDataCatalog.$DB.$(new_name j8) (n int NOT NULL)" "$(new_name j8)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" j9 "CREATE TABLE IF NOT EXISTS AwsDataCatalog.$DB.$(new_name j9) (n int)" "$(new_name j9)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" j10 "CREATE TABLE IF NOT EXISTS nosuchcatalog227.$DB.$(new_name j10) (n int)" "$(new_name j10)"
  # j1 の対照。2 部で作れる（#221 の h4 と同じ形）。
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" j11 "CREATE TABLE $S3TABLES_NS.$(new_name j11) (n int)" "$(new_name j11)"
  # i2 の再現（対照）。2 部で、1 部目が S3 Tables の名前空間でなく AwsDataCatalog の DB。
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" j12 "CREATE TABLE $DB.$(new_name j12) (n int)" "$DB.$(new_name j12)"
  # CTAS で同じ形が S3 Tables 側に作られるか。
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" j13 "CREATE TABLE AwsDataCatalog.$S3TABLES_NS.$(new_name j13) AS SELECT 1 AS n" "$(new_name j13)"
else
  skip j0 "未測定（S3TABLES_* 未設定）"
  for l in j1 j2 j3 j4 j5 j6 j7 j8 j9 j10 j11 j12 j13; do
    skip "$l" "未測定（S3TABLES_* 未設定）"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

# --- 既定の Context の対照（S3TABLES_* によらず常に投げる） ----------------------------
# j14: 実在しないカタログ（No location か DATACATALOG_NOT_FOUND か）。
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" j14 "CREATE TABLE nosuchcatalog227.$DB.$(new_name j14) (n int)" "$(new_name j14)"
# j15: No location の見込み。
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" j15 "CREATE TABLE AwsDataCatalog.$DB.$(new_name j15) (n int)" "$(new_name j15)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" j16 "CREATE TABLE AWSDATACATALOG.$DB.$(new_name j16) (n int)" "$(new_name j16)"

# --- 付随物の取得（FAILED になった項目だけ） --------------------------------------------
fetch_failed_attachments $J_LABELS

fi # ROUND=5

# ROUND=6 だけ、K 群を投げる（issue #228）。
if [ "$ROUND" = 6 ]; then

DEFAULT_CTX="Catalog=$CATALOG,Database=$DB"
# K 群のラベル一覧（k0〜k30。-cleanup は含まない）。ALL_LABELS と summary の repr の節から参照する。
K_LABELS="k0 k1 k2 k3 k4 k5 k6 k7 k8 k9 k10 k11 k12 k13 k14 k15 k16 k17 k18 k19 k20 k21 k22 k23 k24 k25 k26 k27 k28 k29 k30"

# --- K 群（複数の文と末尾の `;`） -----------------------------------------------------
# #224 の i10（S3 Tables の Context で `CREATE TABLE awsdatacatalog.<db>.<t> (n int); -- c` →
# `Only one sql statement is allowed. Got: <文>`）の周辺。#76 で `SELECT 1;` は SUCCEEDED だった。
# k0 は疎通の対照。k1〜k12 は `;` の後ろに何があれば弾かれるか（コメント・別の文・`;`・空白・改行・CRLF）、
# k13〜k17 は文字列・引用符付きの名前・コメントの中の `;`、k18・k19 は `Got:` の後ろの文の前後の空白、
# k20〜k27 は他の判定（構文エラー・DESCRIBE の存在確認・No location・NV）との順番と文の種類、
# k28 は末尾の CRLF、k29・k30 は S3 Tables の Context の対照（k30 は i10 の再現）。
run_in_ctx "$DEFAULT_CTX" k0 "SELECT 1"
run_in_ctx "$DEFAULT_CTX" k1 "SELECT 1; -- c"
run_in_ctx "$DEFAULT_CTX" k2 "SELECT 1; /* c */"
run_in_ctx "$DEFAULT_CTX" k3 $'SELECT 1;\n-- c'
run_in_ctx "$DEFAULT_CTX" k4 "SELECT 1; SELECT 2"
run_in_ctx "$DEFAULT_CTX" k5 "SELECT 1;SELECT 2"
run_in_ctx "$DEFAULT_CTX" k6 "SELECT 1;;"
run_in_ctx "$DEFAULT_CTX" k7 "SELECT 1; ;"
run_in_ctx "$DEFAULT_CTX" k8 "SELECT 1; "
run_in_ctx "$DEFAULT_CTX" k9 $'SELECT 1;\n\n'
run_in_ctx "$DEFAULT_CTX" k10 "SELECT 1 ;"
run_in_ctx "$DEFAULT_CTX" k11 $'-- c\nSELECT 1;'
run_in_ctx "$DEFAULT_CTX" k12 $'SELECT 1 -- c\n;'
run_in_ctx "$DEFAULT_CTX" k13 "SELECT 'a;b'"
run_in_ctx "$DEFAULT_CTX" k14 "SELECT 'a;b'; -- c"
run_in_ctx "$DEFAULT_CTX" k15 'SELECT 1 AS "a;b"'
run_in_ctx "$DEFAULT_CTX" k16 "SELECT 1 -- a;b"
run_in_ctx "$DEFAULT_CTX" k17 "SELECT 1 /* a;b */"
run_in_ctx "$DEFAULT_CTX" k18 "  SELECT  1; -- c  "
run_in_ctx "$DEFAULT_CTX" k19 $'SELECT 1\n; -- c\n'
run_in_ctx "$DEFAULT_CTX" k20 "SELEC 1; -- c"
run_in_ctx "$DEFAULT_CTX" k21 "SELECT 1; SELEC 2"
run_in_ctx "$DEFAULT_CTX" k22 "DESCRIBE $DB.$NOPE; -- c"
run_in_ctx "$DEFAULT_CTX" k23 "SHOW DATABASES; -- c"
run_in_ctx "$DEFAULT_CTX" k24 "DROP TABLE IF EXISTS $DB.$NOPE; -- c"
# No location・NV(NOT) との順番と、DDL の末尾の `;` だけ（既定の Context）。
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" k25 "CREATE TABLE $DB.$(new_name k25) (n int); -- c" "$(new_name k25)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" k26 "CREATE TABLE $DB.$(new_name k26) (n int NOT NULL); -- c" "$(new_name k26)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" k27 "CREATE TABLE $DB.$(new_name k27) (n int);" "$(new_name k27)"
run_in_ctx "$DEFAULT_CTX" k28 $'SELECT 1;\r\n'
if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  S3T_CTX="Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS"
  run_in_ctx "$S3T_CTX" k29 "SELECT 1; -- c"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" k30 "CREATE TABLE awsdatacatalog.$DB.$(new_name k30) (n int); -- c" "$(new_name k30)"
else
  skip k29 "未測定（S3TABLES_* 未設定）"
  skip k30 "未測定（S3TABLES_* 未設定）"
  skip k30-cleanup "CREATE TABLE を投げていないため後始末不要"
fi

fi # ROUND=6

# ROUND=7 だけ、L 群を投げる（issue #240）。
if [ "$ROUND" = 7 ]; then

DEFAULT_CTX="Catalog=$CATALOG,Database=$DB"
# L 群のラベル一覧（l0〜l28。-cleanup は含まない）。ALL_LABELS と summary の repr の節から参照する。
L_LABELS="l0 l1 l2 l3 l4 l5 l6 l7 l8 l9 l10 l11 l12 l13 l14 l15 l16 l17 l18 l19 l20 l21 l22 l23 l24 l25 l26 l27 l28"
T16="$(new_name l16)"

# --- L 群（末尾の `;` だけの文を本物がどう見せるか） ----------------------------------------
# #228 の k6〜k12 で、末尾の `;` だけの SELECT は SUCCEEDED になり、GetQueryExecution の Query から
# 末尾の `;` と前後の空白が落ちていた。l0 は対照。l1〜l5 は Query の正規化の範囲（先頭の空白・`;` の無い文の
# 末尾の空白）、l6〜l8 は先頭の `;`、l9・l10・l27 は `;` の直前で構文が不完全な文の文言と位置、l11〜l13 は
# 文を引用する文言（Entity Not Found・NV・2 catalogs）、l14〜l20 は文の種類ごとの見え方（SHOW・EXPLAIN・
# CTAS・INSERT・DESCRIBE・SHOW CREATE TABLE・DROP）、l21 はパラメータ付き、l22〜l26 は同じ
# ClientRequestToken で `;` の有無・末尾の空白だけが違う文を投げたときの冪等の比較。
run_in_ctx "$DEFAULT_CTX" l0 "SELECT 1"
run_in_ctx "$DEFAULT_CTX" l1 "  SELECT 1;"
run_in_ctx "$DEFAULT_CTX" l2 "SELECT 1  "
run_in_ctx "$DEFAULT_CTX" l3 $'\n\nSELECT 1\n'
run_in_ctx "$DEFAULT_CTX" l4 "  SELECT 1  ;  "
run_in_ctx "$DEFAULT_CTX" l5 $'SELECT 1\t;'
run_in_ctx "$DEFAULT_CTX" l6 ";SELECT 1"
run_in_ctx "$DEFAULT_CTX" l7 "; SELECT 1"
run_in_ctx "$DEFAULT_CTX" l8 ";"
run_in_ctx "$DEFAULT_CTX" l9 "SELECT;"
run_in_ctx "$DEFAULT_CTX" l10 $'SELECT 1\nFROM;'
run_in_ctx "$DEFAULT_CTX" l11 "DESCRIBE $DB.$NOPE;"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" l12 "CREATE TABLE $DB.$(new_name l12) (n int NOT NULL);" "$(new_name l12)"
if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  S3T_CTX="Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" l13 "CREATE TABLE awsdatacatalog.$DB.$(new_name l13) (n int);" "$(new_name l13)"
else
  skip l13 "未測定（S3TABLES_* 未設定）"
  skip l13-cleanup "CREATE TABLE を投げていないため後始末不要"
fi
run_in_ctx "$DEFAULT_CTX" l14 "SHOW TABLES;"
run_in_ctx "$DEFAULT_CTX" l15 "EXPLAIN SELECT 1;"
# l16 の CTAS で作った表を l17〜l19 で使い、l20 の DROP（末尾 `;`）で消す。消せなければ trap が消す。
PENDING_DROPS[$T16]=1
if run_in_ctx "$DEFAULT_CTX" l16 "CREATE TABLE $DB.$T16 AS SELECT 1 AS n;"; then
  run_in_ctx "$DEFAULT_CTX" l17 "INSERT INTO $DB.$T16 VALUES (2);"
  run_in_ctx "$DEFAULT_CTX" l18 "DESCRIBE $DB.$T16;"
  run_in_ctx "$DEFAULT_CTX" l19 "SHOW CREATE TABLE $DB.$T16;"
else
  skip l17 "l16 の CTAS が失敗したため"
  skip l18 "l16 の CTAS が失敗したため"
  skip l19 "l16 の CTAS が失敗したため"
fi
run_in_ctx "$DEFAULT_CTX" l20 "DROP TABLE IF EXISTS $DB.$T16;"
if succeeded l20; then
  unset 'PENDING_DROPS[$T16]'
fi
START_EXTRA=(--execution-parameters 1)
run_in_ctx "$DEFAULT_CTX" l21 "SELECT ?;"
START_EXTRA=()
# 冪等の比較。同じトークンで、`;` の有無・`;` の数・末尾の空白だけが違う文を続けて投げる。
TOKEN=$(python3 -c 'import uuid; print(uuid.uuid4())')
START_EXTRA=(--client-request-token "$TOKEN")
run_in_ctx "$DEFAULT_CTX" l22 "SELECT 1;"
run_in_ctx "$DEFAULT_CTX" l23 "SELECT 1"
run_in_ctx "$DEFAULT_CTX" l24 "SELECT 1;;"
run_in_ctx "$DEFAULT_CTX" l25 "SELECT 1 "
run_in_ctx "$DEFAULT_CTX" l26 "SELECT 2;"
START_EXTRA=()
run_in_ctx "$DEFAULT_CTX" l27 "SELECT 1 +;"
# l28: 先頭のコメントと末尾の `;` の間に改行がある複数行の文（Query の中の改行と末尾の扱い）。
run_in_ctx "$DEFAULT_CTX" l28 $'-- c\nSELECT\n  1 ;\n'

fi # ROUND=7

# ROUND=8 だけ、M 群を投げる（issue #242）。
if [ "$ROUND" = 8 ]; then

DEFAULT_CTX="Catalog=$CATALOG,Database=$DB"
# M 群のラベル一覧（setup・cleanup を除く）。ALL_LABELS と summary の repr の節から参照する。
M_LABELS="m0 m1 m2 m3 m4 m5 m6 m7 m8 m9 m10 m11 m12 m13 m14 m20 m21 m22 m23 m24 m25 m26 m27 m28 m30 m31 m32 m33 m34 m35 m36 m37 m38 m39 m41 m42"
T="$(new_name m)"
V="$(new_name mv)"
DB2="$(new_name db2)"
T2="$(new_name m2)"
DB2_CTX="Catalog=$CATALOG,Database=$DB2"

# --- 準備: 表 <DB>.<T>・ビュー <DB>.<V>・別の DB <DB2> と表 <DB2>.<T2> ------------------------
# 作ったものは最後の後始末で消す。途中で止めても trap（PENDING_DROPS・PENDING_DROPS_CTX）が消しにいく。
PENDING_DROPS[$T]=1
run_in_ctx "$DEFAULT_CTX" m-setup-t "CREATE TABLE $DB.$T AS SELECT 1 AS n, 'x' AS s"
PENDING_DROPS_CTX["$DEFAULT_CTX|$V"]=1
run_in_ctx "$DEFAULT_CTX" m-setup-v "CREATE VIEW $DB.$V AS SELECT 1 AS n"
M_DB2_OK=0
if run_in_ctx "$DEFAULT_CTX" m-setup-db2 "CREATE DATABASE $DB2"; then
  M_DB2_OK=1
  PENDING_DROPS_CTX["$DB2_CTX|$T2"]=1
  run_in_ctx "$DB2_CTX" m-setup-t2 "CREATE TABLE $DB2.$T2 AS SELECT 2 AS n"
fi

# --- DESCRIBE・DESC（表は修飾が落ちるか、Context.Database が変わるか） ---------------------------
# m0 は疎通。m1 は過去の実測（DESCRIBE <db>.<t> → DESCRIBE <t>）の再現。m2・m3・m6・m13 は Context と
# 違う実在の DB、m4 は Context に Database が無い、m5 は大文字混じりのカタログ、m7・m8 は EXTENDED と列、
# m9・m10 は名前の部品の間の空白・コメント、m11 はビュー（残る見込み）、m12 は DB の大文字（Database の書き換えの
# 再現）、m14 は m13 の対照。
run_in_ctx "$DEFAULT_CTX" m0 "SELECT 1"
run_in_ctx "$DEFAULT_CTX" m1 "DESCRIBE $DB.$T"
if [ "$M_DB2_OK" = 1 ]; then
  run_in_ctx "$DEFAULT_CTX" m2 "DESCRIBE $DB2.$T2"
  run_in_ctx "$DEFAULT_CTX" m3 "DESC $DB2.$T2"
else
  skip m2 "別の DB を作れなかったため"
  skip m3 "別の DB を作れなかったため"
fi
run_in_ctx "Catalog=$CATALOG" m4 "DESCRIBE $DB.$T"
run_in_ctx "$DEFAULT_CTX" m5 "DESCRIBE AwsDataCatalog.$DB.$T"
if [ "$M_DB2_OK" = 1 ]; then
  run_in_ctx "$DEFAULT_CTX" m6 "DESCRIBE awsdatacatalog.$DB2.$T2"
else
  skip m6 "別の DB を作れなかったため"
fi
run_in_ctx "$DEFAULT_CTX" m7 "DESCRIBE EXTENDED $DB.$T"
run_in_ctx "$DEFAULT_CTX" m8 "DESCRIBE $DB.$T n"
run_in_ctx "$DEFAULT_CTX" m9 "DESCRIBE $DB . $T"
run_in_ctx "$DEFAULT_CTX" m10 "DESCRIBE $DB./* c */$T"
run_in_ctx "$DEFAULT_CTX" m11 "DESCRIBE $DB.$V"
run_in_ctx "$DEFAULT_CTX" m12 "DESCRIBE ${DB^^}.$T"
if [ "$M_DB2_OK" = 1 ]; then
  run_in_ctx "$DB2_CTX" m13 "DESCRIBE $DB.$T"
  run_in_ctx "$DB2_CTX" m14 "DESCRIBE $T2"
else
  skip m13 "別の DB を作れなかったため"
  skip m14 "別の DB を作れなかったため"
fi

# --- カタログ部分の落ち（DESCRIBE 以外の文。過去の実測では awsdatacatalog. だけ落ちて DB は残った） -----------
# m20・m24・m26 は過去の実測の再現。m21・m25・m27・m31 は大文字混じりのカタログ、m22・m27 は別の DB、m23 は IN、
# m28・m30〜m36・m41・m42 はまだ見ていない文の種類、m37 はビュー、m38 は部品の間の空白、m39 は Context に Database が無い。
run_in_ctx "$DEFAULT_CTX" m20 "SHOW COLUMNS FROM awsdatacatalog.$DB.$T"
run_in_ctx "$DEFAULT_CTX" m21 "SHOW COLUMNS FROM AwsDataCatalog.$DB.$T"
if [ "$M_DB2_OK" = 1 ]; then
  run_in_ctx "$DEFAULT_CTX" m22 "SHOW COLUMNS FROM awsdatacatalog.$DB2.$T2"
else
  skip m22 "別の DB を作れなかったため"
fi
run_in_ctx "$DEFAULT_CTX" m23 "SHOW COLUMNS IN awsdatacatalog.$DB.$T"
run_in_ctx "$DEFAULT_CTX" m24 "SHOW CREATE TABLE awsdatacatalog.$DB.$T"
run_in_ctx "$DEFAULT_CTX" m25 "SHOW CREATE TABLE AwsDataCatalog.$DB.$T"
run_in_ctx "$DEFAULT_CTX" m26 "SHOW TABLES IN awsdatacatalog.$DB"
if [ "$M_DB2_OK" = 1 ]; then
  run_in_ctx "$DEFAULT_CTX" m27 "SHOW TABLES IN AwsDataCatalog.$DB2"
else
  skip m27 "別の DB を作れなかったため"
fi
run_in_ctx "$DEFAULT_CTX" m28 "SHOW TBLPROPERTIES awsdatacatalog.$DB.$T"
run_in_ctx "$DEFAULT_CTX" m30 "SELECT * FROM awsdatacatalog.$DB.$T"
run_in_ctx "$DEFAULT_CTX" m31 "SELECT * FROM AwsDataCatalog.$DB.$T"
run_in_ctx "$DEFAULT_CTX" m32 "INSERT INTO awsdatacatalog.$DB.$T VALUES (2, 'y')"
run_in_ctx "$DEFAULT_CTX" m33 "ALTER TABLE awsdatacatalog.$DB.$T SET TBLPROPERTIES ('athena_local_probe'='242')"
run_in_ctx "$DEFAULT_CTX" m34 "DROP TABLE IF EXISTS awsdatacatalog.$DB.$NOPE"
PENDING_DROPS["$(new_name m35)"]=1
run_in_ctx "$DEFAULT_CTX" m35 "CREATE TABLE awsdatacatalog.$DB.$(new_name m35) AS SELECT 1 AS n"
PENDING_DROPS_CTX["$DEFAULT_CTX|$(new_name m36)"]=1
run_in_ctx "$DEFAULT_CTX" m36 "CREATE VIEW awsdatacatalog.$DB.$(new_name m36) AS SELECT 1 AS n"
run_in_ctx "$DEFAULT_CTX" m37 "SHOW COLUMNS FROM awsdatacatalog.$DB.$V"
run_in_ctx "$DEFAULT_CTX" m38 "SHOW CREATE TABLE awsdatacatalog . $DB . $T"
run_in_ctx "Catalog=$CATALOG" m39 "SHOW COLUMNS FROM awsdatacatalog.$DB.$T"
run_in_ctx "$DEFAULT_CTX" m41 "EXPLAIN SELECT * FROM awsdatacatalog.$DB.$T"
run_in_ctx "$DEFAULT_CTX" m42 "SHOW VIEWS IN awsdatacatalog.$DB"

# --- 後始末（作ったものを逆順に消す） ---------------------------------------------------------------
run_in_ctx "$DEFAULT_CTX" m-drop-v36 "DROP VIEW IF EXISTS $DB.$(new_name m36)"
succeeded m-drop-v36 && unset "PENDING_DROPS_CTX[$DEFAULT_CTX|$(new_name m36)]"
run_in_ctx "$DEFAULT_CTX" m-drop-t35 "DROP TABLE IF EXISTS $DB.$(new_name m35)"
succeeded m-drop-t35 && unset "PENDING_DROPS[$(new_name m35)]"
run_in_ctx "$DEFAULT_CTX" m-drop-v "DROP VIEW IF EXISTS $DB.$V"
succeeded m-drop-v && unset "PENDING_DROPS_CTX[$DEFAULT_CTX|$V]"
run_in_ctx "$DEFAULT_CTX" m-drop-t "DROP TABLE IF EXISTS $DB.$T"
succeeded m-drop-t && unset "PENDING_DROPS[$T]"
if [ "$M_DB2_OK" = 1 ]; then
  run_in_ctx "$DB2_CTX" m-drop-t2 "DROP TABLE IF EXISTS $DB2.$T2"
  succeeded m-drop-t2 && unset "PENDING_DROPS_CTX[$DB2_CTX|$T2]"
  run_in_ctx "$DEFAULT_CTX" m-drop-db2 "DROP DATABASE IF EXISTS $DB2"
  if ! succeeded m-drop-db2; then
    echo "== 別の DB <PROBE>_db2 を消せませんでした。手で DROP DATABASE IF EXISTS してください。"
  fi
fi

fi # ROUND=8

# ROUND=9 だけ、N 群を投げる（issue #229）。
if [ "$ROUND" = 9 ]; then

DEFAULT_CTX="Catalog=$CATALOG,Database=$DB"
# LOCATION 付きの項目の置き場。結果の出力先の下の、項目ごとの空のプレフィックス（i14 と同じ形）。
probe_location() { printf '%sathena-local-probe-229/%s/' "$OUTPUT" "$(new_name "$1")"; }

# --- N 群（QueryExecutionContext の Catalog が S3 Tables で、LOCATION 付きの CREATE TABLE） ----
# #224 の i14・i15（S3 Tables の Context で `CREATE TABLE awsdatacatalog.<db>.<t> (n int) LOCATION '...'`・
# `CREATE EXTERNAL TABLE ...同...` が開始時に InvalidRequestException・MALFORMED_QUERY、
# `Table location can not be specified for tables hosted in S3 table buckets` で弾かれた）の周辺。
# n0 は疎通、n1 は i14 の再現（対照）。n2〜n9 は名前の形（1〜4 部、S3 Tables の名前空間・Glue の DB 名・
# 大文字混じり・実在しないカタログ・引用符付き）、n10〜n12 は EXTERNAL（LOCATION の有無）、n13〜n15 は
# NOT NULL・引用符付き列名との順番、n16〜n30 は LOCATION の書かれ方・他の判定との順番（ごみ・引用符無し・
# 値無し・PARTITIONED BY・Hive の句・STORED AS・TBLPROPERTIES の前後・大文字小文字・コメント・列名が
# location・文字列の中の LOCATION・複数の文・列の並び無し）、n31 は既定の Context の対照
# （CREATE EXTERNAL TABLE + LOCATION が本物の書き方として通る見込み）、n32 は Database 無しの
# Catalog だけの Context。AwsDataCatalog に作られうる項目（n1・n5・n6・n12・n15・n31）は既定の
# Context で、それ以外は S3 Tables の Context（n32 は Database 無しの Context）で消す。
if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  S3T_CTX="Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS"
  S3T_CTX_NO_NS="Catalog=$S3TABLES_CATALOG"

  run_in_ctx "$S3T_CTX" n0 "SELECT 1"

  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" n1 \
    "CREATE TABLE awsdatacatalog.$DB.$(new_name n1) (n int) LOCATION '$(probe_location n1)'" "$(new_name n1)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n2 \
    "CREATE TABLE $(new_name n2) (n int) LOCATION '$(probe_location n2)'" "$(new_name n2)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n3 \
    "CREATE TABLE $S3TABLES_NS.$(new_name n3) (n int) LOCATION '$(probe_location n3)'" "$(new_name n3)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n4 \
    "CREATE TABLE $DB.$(new_name n4) (n int) LOCATION '$(probe_location n4)'" "$DB.$(new_name n4)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" n5 \
    "CREATE TABLE AwsDataCatalog.$DB.$(new_name n5) (n int) LOCATION '$(probe_location n5)'" "$(new_name n5)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" n6 \
    "CREATE TABLE nosuchcatalog229.$DB.$(new_name n6) (n int) LOCATION '$(probe_location n6)'" "$(new_name n6)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n7 \
    "CREATE TABLE \"$S3TABLES_CATALOG\".$S3TABLES_NS.$(new_name n7) (n int) LOCATION '$(probe_location n7)'" "$(new_name n7)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n8 \
    "CREATE TABLE \"$(new_name n8)\" (n int) LOCATION '$(probe_location n8)'" "$(new_name n8)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n9 \
    "CREATE TABLE a229.b229.c229.$(new_name n9) (n int) LOCATION '$(probe_location n9)'" "$(new_name n9)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n10 \
    "CREATE EXTERNAL TABLE $(new_name n10) (n int) LOCATION '$(probe_location n10)'" "$(new_name n10)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n11 \
    "CREATE EXTERNAL TABLE $(new_name n11) (n int)" "$(new_name n11)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" n12 \
    "CREATE EXTERNAL TABLE awsdatacatalog.$DB.$(new_name n12) (n int)" "$(new_name n12)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n13 \
    "CREATE TABLE $(new_name n13) (n int NOT NULL) LOCATION '$(probe_location n13)'" "$(new_name n13)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n14 \
    "CREATE TABLE $(new_name n14) (\"n\" int) LOCATION '$(probe_location n14)'" "$(new_name n14)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" n15 \
    "CREATE TABLE awsdatacatalog.$DB.$(new_name n15) (n int NOT NULL) LOCATION '$(probe_location n15)'" "$(new_name n15)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n16 \
    "CREATE TABLE $(new_name n16) (n int) LOCATION '$(probe_location n16)' garbage" "$(new_name n16)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n17 \
    "CREATE TABLE $(new_name n17) (n int) LOCATION s3path" "$(new_name n17)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n18 \
    "CREATE TABLE $(new_name n18) (n int) LOCATION" "$(new_name n18)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n19 \
    "CREATE TABLE $(new_name n19) (n int) PARTITIONED BY (p string) LOCATION '$(probe_location n19)'" "$(new_name n19)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n20 \
    "CREATE TABLE $(new_name n20) (n int) ROW FORMAT DELIMITED FIELDS TERMINATED BY ',' STORED AS TEXTFILE LOCATION '$(probe_location n20)' TBLPROPERTIES ('a'='b')" "$(new_name n20)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n21 \
    "CREATE TABLE $(new_name n21) (n int) STORED AS PARQUET" "$(new_name n21)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n22 \
    "CREATE TABLE $(new_name n22) (n int) TBLPROPERTIES ('table_type'='ICEBERG') LOCATION '$(probe_location n22)'" "$(new_name n22)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n23 \
    "CREATE TABLE IF NOT EXISTS $(new_name n23) (n int) LOCATION '$(probe_location n23)'" "$(new_name n23)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n24 \
    "create table $(new_name n24) (n int) location '$(probe_location n24)'" "$(new_name n24)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n25 \
    "CREATE TABLE $(new_name n25) (n int) /* c */ LOCATION '$(probe_location n25)'" "$(new_name n25)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n26 \
    "CREATE TABLE $(new_name n26) (location string)" "$(new_name n26)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n27 \
    "CREATE TABLE $(new_name n27) (n int) COMMENT 'LOCATION'" "$(new_name n27)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n28 \
    "CREATE EXTERNAL TABLE $DB.$(new_name n28) (n int) LOCATION '$(probe_location n28)'" "$DB.$(new_name n28)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n29 \
    "CREATE TABLE $(new_name n29) (n int) LOCATION '$(probe_location n29)'; -- c" "$(new_name n29)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" n30 \
    "CREATE TABLE $(new_name n30) LOCATION '$(probe_location n30)'" "$(new_name n30)"
  run_create_then_drop_ctx "$S3T_CTX_NO_NS" "$S3T_CTX_NO_NS" n32 \
    "CREATE TABLE $(new_name n32) (n int) LOCATION '$(probe_location n32)'" "$(new_name n32)"
else
  skip n0 "未測定（S3TABLES_* 未設定）"
  for l in n1 n2 n3 n4 n5 n6 n7 n8 n9 n10 n11 n12 n13 n14 n15 n16 n17 n18 n19 n20 n21 n22 n23 n24 n25 n26 n27 n28 n29 n30 n32; do
    skip "$l" "未測定（S3TABLES_* 未設定）"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi
# n31: 既定の Context の対照（S3TABLES_* によらず常に投げる）。
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" n31 \
  "CREATE EXTERNAL TABLE $(new_name n31) (n int) LOCATION '$(probe_location n31)'" "$(new_name n31)"

fi # ROUND=9

# --- 後始末（実在する表） ----------------------------------------------------------

if [ "$REAL_SETUP_OK" = 1 ]; then
  run z-drop-real "DROP TABLE IF EXISTS $DB.$REAL"
  if succeeded z-drop-real; then
    REAL_SETUP_ATTEMPTED=0
  else
    echo "== 後始末の DROP TABLE が SUCCEEDED になりませんでした。終了時にもう一度投げます。"
    echo "   それでも消えなければ、$DB の $REAL を手で消してください。"
  fi
elif [ "$ROUND" = 1 ] || [ "$ROUND" = 2 ]; then
  skip z-drop-real "実在する表を作れなかったため後始末不要"
fi

# --- summary ---------------------------------------------------------------------

ALL_LABELS="preflight-select1 probe-show-tables setup-real"
if [ "$ROUND" = 1 ]; then
  for l in a1 a2 a3 a4 a5 a6 a7 a8 a9 a10 a11 a12 a13 a14 a15 a16 a17 a18 a19; do
    ALL_LABELS="$ALL_LABELS $l"
  done
  for l in b1 b2 b3 b4 b5 b6 b7 b8 b9 b10 b11 b12 b13 b14 b15 b16 b17 b18 b19; do
    ALL_LABELS="$ALL_LABELS $l"
  done
  for l in c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12 c13 c14 c15 c16 c17 c18 c19; do
    ALL_LABELS="$ALL_LABELS $l $l-cleanup"
  done
  ALL_LABELS="$ALL_LABELS c20 c20-cleanup c21 c21-cleanup c22 c22-cleanup c23 c23-cleanup"
elif [ "$ROUND" = 3 ]; then
  ALL_LABELS="$ALL_LABELS h0"
  for l in h1 h2 h3 h4 h5 h6 h7 h8 h9 q0 q1 q2 q3 q4 q5 q6 q7 q8 p0 p1 p2 p3 p4 p5 p6 p7 p8; do
    ALL_LABELS="$ALL_LABELS $l $l-cleanup"
  done
elif [ "$ROUND" = 4 ]; then
  ALL_LABELS="$ALL_LABELS i0"
  for l in i1 i2 i3 i4 i5 i6 i7 i8 i9 i10 i11 i12 i13 i14 i15 i16 i17 i18 i19 i20 i21 i22; do
    ALL_LABELS="$ALL_LABELS $l $l-cleanup"
  done
elif [ "$ROUND" = 9 ]; then
  ALL_LABELS="$ALL_LABELS n0"
  for l in n1 n2 n3 n4 n5 n6 n7 n8 n9 n10 n11 n12 n13 n14 n15 n16 n17 n18 n19 n20 n21 n22 n23 n24 n25 n26 n27 n28 n29 n30 n31 n32; do
    ALL_LABELS="$ALL_LABELS $l $l-cleanup"
  done
elif [ "$ROUND" = 8 ]; then
  ALL_LABELS="$ALL_LABELS m-setup-t m-setup-v m-setup-db2 m-setup-t2 $M_LABELS"
  ALL_LABELS="$ALL_LABELS m-drop-v36 m-drop-t35 m-drop-v m-drop-t m-drop-t2 m-drop-db2"
elif [ "$ROUND" = 7 ]; then
  for l in $L_LABELS; do
    case "$l" in
      l12 | l13) ALL_LABELS="$ALL_LABELS $l $l-cleanup" ;;
      *) ALL_LABELS="$ALL_LABELS $l" ;;
    esac
  done
elif [ "$ROUND" = 6 ]; then
  for l in $K_LABELS; do
    case "$l" in
      k25 | k26 | k27 | k30) ALL_LABELS="$ALL_LABELS $l $l-cleanup" ;;
      *) ALL_LABELS="$ALL_LABELS $l" ;;
    esac
  done
elif [ "$ROUND" = 5 ]; then
  ALL_LABELS="$ALL_LABELS j0"
  for l in j1 j2 j3 j4 j5 j6 j7 j8 j9 j10 j11 j12 j13 j14 j15 j16; do
    ALL_LABELS="$ALL_LABELS $l $l-cleanup"
  done
else
  for l in e1 e2 e3 e4 e5 e6 e7 e8 e9 e10 e11 e12 e13 e14 e15 e16 e17 e18 e19 e20 e21 e22 e23 e24 e25; do
    ALL_LABELS="$ALL_LABELS $l $l-cleanup"
  done
  for l in f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12 f13 f14 f15 f16; do
    ALL_LABELS="$ALL_LABELS $l $l-cleanup"
  done
  for l in g1 g2 g3 g4 g5 g6 g7; do
    ALL_LABELS="$ALL_LABELS $l"
  done
fi
ALL_LABELS="$ALL_LABELS z-drop-real"

write_summary_txt() {
  local txt="$RUN_DIR/summary.txt"
  {
    if [ "$ROUND" = 1 ]; then
      echo "# issue #208 ラウンド 1: 無引用の DDL 3 種（ALTER TABLE IF EXISTS、"
      echo "#             ALTER TABLE ... ADD COLUMN 単数、場所の無い CREATE TABLE）が"
      echo "#             StartQueryExecution の時点で弾かれる文言の規則と、Trino にだけある"
      echo "#             他の ALTER・CREATE の範囲を実測"
      echo "# 実行日時: $(date -Iseconds)"
      echo "# StartQueryExecution の見込み本数: 68（S3TABLES_* 無し）／70（あり）"
      echo "#   （preflight 2 + 実在する表の準備/後始末 2 + A 群 19 + B 群 12 + B' 群 7 +"
      echo "#   C1〜C19 19 + C3 の後始末 1 + C21・C22・C23 とその後始末 6、S3TABLES_* が"
      echo "#   揃っていれば C20 とその後始末の 2 が乗る）。"
      echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
      echo "#   （開始時に弾かれた項目があっても追加の呼び出しはしない）。"
      echo "#   想定に反して開始時に弾かれなかった項目があれば後始末が 1 本増え、逆に"
      echo "#   C3・C20・C21・C22・C23 が想定に反して開始時に弾かれれば後始末は skip になり減る。"
      echo "# DDL: 実在する表 <PROBE>_real を 1 つ作って消す。C3・C21・C22・C23（と S3TABLES_* が"
      echo "#   揃えば C20）は受けて作られる見込みで、その場で DROP して消す。それ以外の C 群は"
      echo "#   開始時に弾かれる見込みだが、想定外に成功したら同じ仕組みで消す。ALTER・DROP は"
      echo "#   実在しない名前（<PROBE>_nope）にだけ投げる。"
      echo "# 課金: スキャンの無いクエリだけ（ALTER・DROP はメタデータのみ、CREATE は 0〜1 行）。"
      echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
      echo "#   実測値は既定とは限らない（本物の Athena の挙動が変わっていれば、ここに書いた"
      echo "#   見込みと食い違うことがある）。"
    elif [ "$ROUND" = 4 ]; then
      echo "# issue #224（#208 ラウンド 4）: QueryExecutionContext の Catalog が S3 Tables のとき、"
      echo "#             別カタログを指す名前の CREATE TABLE が StartQueryExecution の時点で"
      echo "#             どう弾かれるか（Unsupported ddl with 2 catalogs の範囲と、文言の後ろに"
      echo "#             付く文の書かれ方）を実測"
      echo "# 実行日時: $(date -Iseconds)"
      if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
        echo "# S3TABLES_*: 設定あり（I 群を測る）"
      else
        echo "# S3TABLES_*: 未設定（i18 以外の I 群は未測定）"
      fi
      echo "# StartQueryExecution の見込み本数: 25（S3TABLES_* あり）／3（無し）"
      echo "#   （preflight 2 + I 群 23（i0 の SELECT 1 と i1〜i22））。"
      echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
      echo "#   受理された CREATE TABLE ごとに、その場で DROP する後始末が 1 本ずつ増える（最大 +22）。"
      echo "# DDL: 実在する表 <PROBE>_real は作らない。I 群の CREATE TABLE は、受理されたらその場で"
      echo "#   DROP して消す（AwsDataCatalog に作られうるものは既定の Context、S3 Tables に作られうる"
      echo "#   i2・i19・i20 は S3 Tables の Context で DROP TABLE IF EXISTS）。i14・i15 の LOCATION は"
      echo "#   <OUTPUT>athena-local-probe-224/<PROBE>_<項目>/（空のプレフィックス。データは置かない）。"
      echo "# 課金: スキャンの無いクエリだけ（CREATE は 0〜1 行、DROP はメタデータのみ）。"
      echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
      echo "#   実測値は既定とは限らない。"
    elif [ "$ROUND" = 9 ]; then
      echo "# issue #229（#208 ラウンド 9）: QueryExecutionContext の Catalog が S3 Tables のとき、"
      echo "#             LOCATION 付きの CREATE TABLE・CREATE EXTERNAL TABLE が StartQueryExecution の時点で"
      echo "#             どう弾かれるか（#224 の i14・i15 で見つけた InvalidRequestException・MALFORMED_QUERY、"
      echo "#             Table location can not be specified for tables hosted in S3 table buckets の範囲と、"
      echo "#             他の判定との順番）を実測"
      echo "# 実行日時: $(date -Iseconds)"
      if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
        echo "# S3TABLES_*: 設定あり（N 群 n0〜n30・n32 を測る）"
      else
        echo "# S3TABLES_*: 未設定（n31 以外の N 群は未測定）"
      fi
      echo "# StartQueryExecution の見込み本数: 35（S3TABLES_* あり）／3（無し）"
      echo "#   （preflight 2 + N 群のうち S3TABLES_* が揃うときだけの 32（n0 の SELECT 1 と"
      echo "#   n1〜n30・n32）+ 常に投げる n31 の 1）。"
      echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
      echo "#   受理された CREATE TABLE ごとに、その場で DROP する後始末が 1 本ずつ増える（最大 +32）。"
      echo "# DDL: 実在する表 <PROBE>_real は作らない。N 群の CREATE TABLE は、受理されたらその場で"
      echo "#   DROP して消す（AwsDataCatalog に作られうる n1・n5・n6・n12・n15・n31 は既定の Context、"
      echo "#   それ以外は S3 Tables の Context（n32 は Database 無しの Catalog だけ）で DROP TABLE IF EXISTS）。"
      echo "#   LOCATION は <OUTPUT>athena-local-probe-229/<PROBE>_<項目>/（空のプレフィックス。データは置かない）。"
      echo "# 課金: スキャンの無いクエリだけ（CREATE は 0〜1 行、DROP はメタデータのみ）。"
      echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
      echo "#   実測値は既定とは限らない。"
    elif [ "$ROUND" = 8 ]; then
      echo "# issue #242（#208 ラウンド 8）: DESCRIBE・DESC の GetQueryExecution の Query から修飾が落ちる範囲と"
      echo "#             QueryExecutionContext.Database の書き換え、ほかの文で awsdatacatalog. のカタログ部分が"
      echo "#             落ちる範囲を実測"
      echo "# 実行日時: $(date -Iseconds)"
      echo "# StartQueryExecution の見込み本数: 48（preflight 2 + 準備 4 + M 群 36 + 後始末 6）。"
      echo "#   別の DB を作れなければ m2・m3・m6・m13・m14・m22・m27 と準備・後始末の 3 本が減る。"
      echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
      echo "# DDL: <DB> に表 <PROBE>_m（CTAS 1 行）とビュー <PROBE>_mv、別の DB <PROBE>_db2 とその表 <PROBE>_m2 を作り、"
      echo "#   m32 で <PROBE>_m に 1 行 INSERT し m33 で TBLPROPERTIES を足す。m35（CTAS）・m36（VIEW）も作る。"
      echo "#   最後にすべて DROP する（途中で止まっても trap が消しにいく。DB は CASCADE）。"
      echo "#   DROP TABLE IF EXISTS（m34）は実在しない名前（<PROBE>_nope）にだけ投げる。"
      echo "# 課金: スキャンは 1〜2 行の表だけ（SELECT・INSERT・CTAS）、ほかはメタデータのみ。"
      echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
      echo "#   実測値は既定とは限らない。"
    elif [ "$ROUND" = 7 ]; then
      echo "# issue #240（#208 ラウンド 7）: 末尾の ; だけの文を本物がどう見せるか（GetQueryExecution の"
      echo "#             Query の正規化の範囲、先頭の ;、文を引用する文言、文の種類ごとの見え方、"
      echo "#             パラメータ付き、同じ ClientRequestToken での冪等の比較）を実測"
      echo "# 実行日時: $(date -Iseconds)"
      if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
        echo "# S3TABLES_*: 設定あり（l13 を測る）"
      else
        echo "# S3TABLES_*: 未設定（l13 は未測定）"
      fi
      echo "# StartQueryExecution の見込み本数: 31（S3TABLES_* あり）／30（無し）"
      echo "#   （preflight 2 + L 群 l0〜l28 の 29、S3TABLES_* が無ければ l13 の 1 を引く）。"
      echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
      echo "#   l12・l13 の CREATE TABLE が受理されたら、その場で DROP する後始末が 1 本ずつ増える（最大 +2）。"
      echo "# DDL: 実在する表 <PROBE>_real は作らない。l16 の CTAS で <PROBE>_l16 を作り、l17 で 1 行 INSERT し、"
      echo "#   l20 の DROP TABLE IF EXISTS で消す（消せなければ trap が消す）。l12・l13 は受理されたら消す。"
      echo "#   DESCRIBE（l11）は実在しない名前（<PROBE>_nope）にだけ投げる。"
      echo "# 課金: スキャンの無いクエリだけ（SELECT は定数、CTAS・INSERT は 1 行、DROP はメタデータのみ）。"
      echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
      echo "#   実測値は既定とは限らない。"
    elif [ "$ROUND" = 6 ]; then
      echo "# issue #228（#208 ラウンド 6）: 複数の文（; の後ろに何かある文）が StartQueryExecution の"
      echo "#             時点で Only one sql statement is allowed で弾かれる範囲と、Got: の後ろの"
      echo "#             文の書かれ方、他の判定との順番を実測"
      echo "# 実行日時: $(date -Iseconds)"
      if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
        echo "# S3TABLES_*: 設定あり（k29・k30 を測る）"
      else
        echo "# S3TABLES_*: 未設定（k29・k30 は未測定）"
      fi
      echo "# StartQueryExecution の見込み本数: 33（S3TABLES_* あり）／31（無し）"
      echo "#   （preflight 2 + K 群 k0〜k28 の 29、S3TABLES_* が揃えば k29・k30 の 2）。"
      echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
      echo "#   受理された CREATE TABLE ごとに、その場で DROP する後始末が 1 本ずつ増える（最大 +4）。"
      echo "# DDL: 実在する表 <PROBE>_real は作らない。k25〜k27・k30 の CREATE TABLE は、受理されたら"
      echo "#   その場で既定の Context で DROP TABLE IF EXISTS <PROBE>_<項目> を投げて消す。"
      echo "#   DESCRIBE・DROP TABLE IF EXISTS は実在しない名前（<PROBE>_nope）にだけ投げる。"
      echo "# 課金: スキャンの無いクエリだけ（SELECT は定数、CREATE は 0 行、DROP はメタデータのみ）。"
      echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
      echo "#   実測値は既定とは限らない。"
    elif [ "$ROUND" = 5 ]; then
      echo "# issue #227（#208 ラウンド 5）: QueryExecutionContext の Catalog が S3 Tables のとき、"
      echo "#             大文字混じりの AwsDataCatalog を 1 部目にした CREATE TABLE が開始でき"
      echo "#             FAILED になった（#224 の i4）現象の周辺。1 部目が S3 Tables 側の名前、"
      echo "#             2 部目が S3 Tables の名前空間として引かれているという仮説を実測"
      echo "# 実行日時: $(date -Iseconds)"
      if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
        echo "# S3TABLES_*: 設定あり（J 群 j0〜j13 を測る）"
      else
        echo "# S3TABLES_*: 未設定（j14〜j16 以外の J 群は未測定）"
      fi
      echo "# StartQueryExecution の見込み本数: 19（S3TABLES_* あり）／5（無し）"
      echo "#   （preflight 2 + J 群のうち S3TABLES_* が揃うときだけの 14（j0 の SELECT 1 と"
      echo "#   j1〜j13）+ 常に投げる j14〜j16 の 3）。"
      echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
      echo "#   受理された CREATE TABLE ごとに、その場で DROP する後始末が 1 本ずつ増える（最大 +16）。"
      echo "# DDL: 実在する表 <PROBE>_real は作らない。J 群の CREATE TABLE は、受理されたらその場で"
      echo "#   DROP して消す（仮説どおりなら S3 Tables 側に作られうる j1・j4・j11・j13 は S3 Tables の"
      echo "#   Context で、AwsDataCatalog・実在しないカタログ側を指す項目は既定の Context で"
      echo "#   DROP TABLE IF EXISTS）。"
      echo "# 付随物: FAILED になった項目は、結果ファイル本体と <OutputLocation>.metadata を"
      echo "#   aws s3 cp で読み出して保存する（<label>.output.txt・<label>.output.metadata）。"
      echo "# 課金: スキャンの無いクエリだけ（CREATE は 0〜1 行、DROP はメタデータのみ）。結果ファイルの"
      echo "#   読み出しは S3 の GetObject で、Athena のクエリ課金には乗らない。"
      echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
      echo "#   実測値は既定とは限らない（本物の Athena の挙動が変わっていれば、ここに書いた"
      echo "#   見込みと食い違うことがある）。"
    elif [ "$ROUND" = 3 ]; then
      echo "# issue #221（#208 ラウンド 3）: 場所の無い CREATE TABLE のうち #208 で測れなかった形"
      echo "#             （QueryExecutionContext の Catalog が S3 Tables のとき、列名・型が"
      echo "#             引用符付きのとき、4 部以上の無引用の名前）が StartQueryExecution の時点で"
      echo "#             どう扱われるかを実測"
      echo "# 実行日時: $(date -Iseconds)"
      if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
        echo "# S3TABLES_*: 設定あり（H 群を測る）"
      else
        echo "# S3TABLES_*: 未設定（H 群 h0〜h9 は未測定）"
      fi
      echo "# StartQueryExecution の見込み本数: 20（S3TABLES_* 無し）／30（あり）"
      echo "#   （preflight 2 + Q 群 9 + P 群 9、S3TABLES_* が揃っていれば H 群 10"
      echo "#   （h0 の SELECT 1 と h1〜h9）が乗る）。"
      echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
      echo "#   （開始時に弾かれた項目があっても追加の呼び出しはしない）。"
      echo "#   受理された CREATE TABLE ごとに、その場で DROP する後始末が 1 本ずつ増える"
      echo "#   （最大で S3TABLES_* 無し +18、あり +27）。"
      echo "# DDL: 実在する表 <PROBE>_real は作らない。H・Q・P 群の CREATE TABLE は、受理されたら"
      echo "#   その場で DROP して消す（h1〜h7 は S3 Tables の Context で、h8・h9・Q・P 群は"
      echo "#   既定の Context で DROP TABLE IF EXISTS <PROBE>_<項目>）。h1〜h7 は S3 Tables が"
      echo "#   場所を要らないため受理されうる。h9・q0・p0 は対照で開始時に弾かれる見込み。"
      echo "# 課金: スキャンの無いクエリだけ（CREATE は 0〜1 行、DROP はメタデータのみ）。"
      echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
      echo "#   実測値は既定とは限らない（本物の Athena の挙動が変わっていれば、ここに書いた"
      echo "#   見込みと食い違うことがある）。"
    else
      echo "# issue #208 ラウンド 2: CREATE TABLE の型名・LIKE と Trino の型の中身、"
      echo "#             ALTER TABLE の Trino 形の文言の綴りが StartQueryExecution の時点で"
      echo "#             どう扱われるか（No location になるか、構文の文言になるか）を実測"
      echo "# 実行日時: $(date -Iseconds)"
      echo "# StartQueryExecution の見込み本数: 52"
      echo "#   （preflight 2 + 実在する表の準備/後始末 2 + E 群 25 + F 群 16 + G 群 7）。"
      echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
      echo "#   （開始時に弾かれた項目があっても追加の呼び出しはしない）。"
      echo "#   想定に反して受理された E・F 群の項目があれば、その場で DROP する後始末が"
      echo "#   1 本ずつ増える。G 群は ALTER TABLE のみで表を作らないため後始末は無い。"
      echo "# DDL: 実在する表 <PROBE>_real を 1 つ作って消す（F1・F3・F4・F5 の LIKE 対象）。"
      echo "#   E・F 群は場所を指定しない CREATE TABLE で、大半は開始時に弾かれる見込みだが、"
      echo "#   受理されて表ができた場合はその場で DROP して消す（run_create_then_drop を流用）。"
      echo "#   G 群は ALTER TABLE のみで、実在しない名前（<PROBE>_nope）にだけ投げる。"
      echo "# 課金: スキャンの無いクエリだけ（ALTER はメタデータのみ、CREATE は 0〜1 行）。"
      echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
      echo "#   実測値は既定とは限らない（本物の Athena の挙動が変わっていれば、ここに書いた"
      echo "#   見込みと食い違うことがある）。"
    fi
    echo
    if [ -n "${PENDING_DROPS_REPORT:-}" ]; then
      echo "## 要対応・確かめ"
      echo "$PENDING_DROPS_REPORT"
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
    if [ "$ROUND" = 6 ] || [ "$ROUND" = 7 ] || [ "$ROUND" = 8 ]; then
      case "$ROUND" in
        6) REPR_LABELS=$K_LABELS ;;
        7) REPR_LABELS=$L_LABELS ;;
        *) REPR_LABELS=$M_LABELS ;;
      esac
      echo
      echo "## 文と開始時の文言・Query（Python の repr。前後の空白・改行・CR を区別する。実名は伏せる）"
      for label in $REPR_LABELS; do
        [ -s "$RUN_DIR/$label.sql" ] || continue
        echo "### $label"
        hide "$(python3 - "$RUN_DIR/$label.sql" "$RUN_DIR/$label.start.err" "$RUN_DIR/$label.execution.json" <<'PYEOF'
import json, sys
# .sql は printf '%s\n' で書いたので、末尾の改行 1 つだけが足されている。
sql = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
if sql.endswith("\n"):
    sql = sql[:-1]
print("- sql: " + repr(sql))
try:
    text = open(sys.argv[2], "rb").read().decode("utf-8", "replace")
except OSError:
    text = ""
if not text:
    print("- message: (開始できた)")
    # 開始できた項目は GetQueryExecution の Query（repr）・種類・ID・出力先の拡張子を出す（ROUND=7。#240）。
    try:
        q = json.load(open(sys.argv[3]))["QueryExecution"]
    except (OSError, ValueError, KeyError):
        sys.exit(0)
    status = q.get("Status", {})
    location = q.get("ResultConfiguration", {}).get("OutputLocation", "")
    print("- Query: " + repr(q.get("Query")))
    # 返った QueryExecutionContext（ROUND=8。DESCRIBE で Database が文中の綴りに変わるか。#242）。
    print("- Context: " + repr(q.get("QueryExecutionContext")))
    print("- id: %s state: %s type: %s/%s output: %s" % (
        q.get("QueryExecutionId"), status.get("State"), q.get("StatementType"),
        q.get("SubstatementType"), location.rsplit("/", 1)[-1].split(".", 1)[-1] if "." in location.rsplit("/", 1)[-1] else "(拡張子なし)"))
    if status.get("State") == "FAILED":
        print("- reason: " + repr(status.get("StateChangeReason")))
    sys.exit(0)
marker = "operation: "
idx = text.find(marker)
if idx == -1:
    print("- message: (見つからない)")
    sys.exit(0)
rest = text[idx + len(marker):]
end = rest.find("\n\nAdditional error details:")
# AWS CLI は文言の直後に空行と Additional error details を続ける（#224 の i10 の生データ）。
msg = rest[:end] if end != -1 else rest
print("- message: " + repr(msg))
PYEOF
)"
        echo
      done
    fi
    if [ "$ROUND" = 5 ]; then
      echo
      echo "## 付随物（結果ファイル本体・.metadata。FAILED になった項目だけ。実名は伏せる）"
      for label in $J_LABELS; do
        is_failed "$label" || continue
        echo "### $label"
        body="$RUN_DIR/$label.output.txt"
        if [ -s "$body" ]; then
          echo "- 本体: あり（$(wc -c < "$body" | tr -d ' ') バイト） 先頭: $(sanitize "$(hide "$(head -n1 "$body")")")"
        elif [ -f "$body" ]; then
          echo "- 本体: あり（0 バイト）"
        else
          echo "- 本体: 取得できず（$(first_err_line "$body.err")）"
        fi
        meta="$RUN_DIR/$label.output.metadata"
        if [ -s "$meta" ]; then
          echo "- .metadata: あり（$(wc -c < "$meta" | tr -d ' ') バイト）"
        elif [ -f "$meta" ]; then
          echo "- .metadata: あり（0 バイト）"
        else
          echo "- .metadata: 取得できず（$(first_err_line "$meta.err")）"
        fi
        echo
      done
    fi
  } > "$txt"
  echo "$txt"
}

# 手で消す必要が残っていれば summary の冒頭に警告を積む（PENDING_DROPS に名前が
# 残っている = 本編の -cleanup では消せず、trap のベストエフォートに委ねた状態）。
if [ "${#PENDING_DROPS[@]}" -gt 0 ] || [ "${#PENDING_DROPS_CTX[@]}" -gt 0 ] \
  || [ "$C20_CREATED" = 1 ] || [ "$REAL_SETUP_ATTEMPTED" = 1 ]; then
  PENDING_DROPS_REPORT="- **手で消してください**: 次のテーブルが残っているか、消えたか確かめられませんでした。"
  PENDING_DROPS_REPORT="$PENDING_DROPS_REPORT 終了時に trap がもう一度 DROP を投げますが、結果は確かめません。"
  if [ "$REAL_SETUP_ATTEMPTED" = 1 ]; then
    PENDING_DROPS_REPORT="$PENDING_DROPS_REPORT"$'\n'"  - <PROBE>_real（DROP TABLE IF EXISTS で確認）"
  fi
  for name in "${!PENDING_DROPS[@]}"; do
    PENDING_DROPS_REPORT="$PENDING_DROPS_REPORT"$'\n'"  - $(hide "$name")（DROP TABLE IF EXISTS で確認）"
  done
  if [ "$C20_CREATED" = 1 ]; then
    PENDING_DROPS_REPORT="$PENDING_DROPS_REPORT"$'\n'"  - S3 Tables 側の <PROBE>_c20（Catalog=<S3TABLES_CATALOG>,Database=<S3TABLES_NS> で DROP TABLE IF EXISTS）"
  fi
  for key in "${!PENDING_DROPS_CTX[@]}"; do
    PENDING_DROPS_REPORT="$PENDING_DROPS_REPORT"$'\n'"  - $(hide "${key##*|}")（$(hide "${key%|*}") で DROP TABLE IF EXISTS）"
  done
fi

SUMMARY_TXT=$(write_summary_txt)

echo
echo "完了しました。"
echo "機械可読な一覧: $SUMMARY"
echo "そのまま貼れる整形済みの一覧: $SUMMARY_TXT"
echo "中身のファイルは $RUN_DIR にあります。リポジトリには入れないでください。"
echo "<label>.sql・<label>.reason.txt・<label>.start.err は実名（DB 名・テーブル名）を"
echo "含みうるので、summary.txt 以外を貼るときは中身を確かめてください。"
