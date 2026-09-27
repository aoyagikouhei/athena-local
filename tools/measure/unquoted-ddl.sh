#!/usr/bin/env bash
# issue #208 で作成。issue #221 で ROUND=3、issue #224 で ROUND=4、issue #227 で ROUND=5、
# issue #228 で ROUND=6、issue #240 で ROUND=7、issue #242 で ROUND=8、issue #229 で ROUND=9、
# issue #248 で ROUND=10、issue #251 で ROUND=11・15、issue #260 で ROUND=12、
# issue #266 で ROUND=13・14、issue #270 で ROUND=16・20、issue #271 で ROUND=17、
# issue #272 で ROUND=18、issue #273 で ROUND=19、issue #279 で ROUND=22・23 を追加
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
#   - 【issue #248 で追加】ROUND=10 は、#229 で扱わなかった S3 Tables の Context の Hive の
#     CREATE TABLE の残り（表の COMMENT・CLUSTERED BY・ROW FORMAT SERDE・FIELDS 以外の
#     DELIMITED の句・TBLPROPERTIES の 2 組以上、LOCATION の無い EXTERNAL の 2 部の名前・
#     AwsDataCatalog の 3 部・ほかの句付き、TRINO_CATALOG_MAP の別名や Trino にだけあるカタログの
#     3 部 + LOCATION、バッククォートの名前）を測る S 群だけを測る。加えて、n6（実在しないカタログ +
#     LOCATION）の対照として既定の Context の同じ形（S3 Tables の判定を経ないときも同じ
#     DATACATALOG_NOT_FOUND になるか）と、連携カタログ（FEDERATED_CATALOG。設定されていれば）を
#     1 部目にした同じ形、n21（STORED AS PARQUET・LOCATION 無し）の対照として STORED AS の
#     別形式（ORC）と LOCATION 付き、#249 の独立レビューで挙がった入れ子の型（`row(...)`・
#     `array(row(...))`）の列を持つ形も測る。preflight・DB 確認は共通で走るが、実在する表は
#     作らない（ROUND=3〜7・9 と同じ）。LOCATION の組み立ては `probe_location_s`（`probe_location`
#     と同じ形。空のプレフィックス、接頭辞だけ issue 番号を 248 にする）。受理されたら同じ
#     Context で消す run_create_then_drop_ctx をそのまま流用する。S3TABLES_* が無ければ、
#     既定の Context だけで測れる s12 を除いて未測定として残す。s14（連携カタログ）は
#     S3TABLES_* に加えて FEDERATED_CATALOG も要る。
#   - 【issue #251 で追加】ROUND=11 は、S3 Tables の Context の場所の無い CREATE TABLE で、
#     名前空間まわりの未実測の形（issue 本文の 1〜3）と、CTAS の残り（#232 の未実測。issue の
#     コメントの 4〜8）を測る R 群だけを測る。preflight・DB 確認は共通で走るが、実在する表は
#     作らない（ROUND=3〜7・9・10 と同じ）。受理されたら同じ Context で消す
#     run_create_then_drop_ctx をそのまま流用するが、CTAS の対象 DB がテスト用に作った
#     実在しない名前のときは、その DB を Database にした Context で消す（作られていれば、
#     という前提。実際は作られない見込み）。r4・r5・r6b・r7b・r8a・r8c（DB が無い CTAS）が
#     FAILED になったときは、理由に書かれた `location '...'` を `aws s3 ls --recursive` で
#     読み取り専用に確かめ、データが実際に書かれているかを見る（`check_ctas_orphan_data`。
#     #251 のコメントの項目 4）。S3TABLES_* が無ければ、既定の Context だけで測れる r8a〜r8c を
#     除いて未測定として残す。
#   - 【issue #260 で追加】ROUND=12 は、#246 の無引用の `awsdatacatalog.<db>.<t>` の置換で
#     測っていない周辺（S3 Tables・連携カタログ・実在しないカタログの Context の SELECT・INSERT、
#     部品に引用符付きを含む形、3 部以外の 4 部の列の参照、AwsDataCatalog 以外の別名キーを
#     無引用で書いた形、Context の Catalog を省略したとき）を測る O 群だけを測る。実在しない
#     カタログの Context の SELECT は #214 で SUCCEEDED と実測済みなので投げない（同じ理由の
#     INSERT は未測定なので測る）。preflight・DB 確認は共通で走るが、O 群だけ実在する表
#     `<PROBE>_o` を 1 つ作り、全項目で使い回して最後に消す（M 群と同じ作り）。S3TABLES_* が
#     無ければ o0・o1・o2 が、FEDERATED_CATALOG が無ければ o3・o4・o9 が「未測定」として残る。
#   - 【issue #266 で追加】ROUND=13 は、#248 の実装（`src/operation/unquoted_ddl/create_table/hive.rs`
#     の `s3_tables_rejection`・`s3_tables_stored_as`・`location_catalog`）が「測った形だけ」に
#     絞った条件の外側（実在しないカタログの 3 部 + LOCATION に句が付く形、S3 Tables の Context の
#     LOCATION 付きの句の組み合わせ、LOCATION の無い CREATE EXTERNAL TABLE に句が付く形、
#     LOCATION の無い STORED AS の 2〜3 部の名前・IF NOT EXISTS・ほかの句、Trino にだけある
#     カタログ名・実在する連携カタログの 3 部 + LOCATION）を測る T・U・V・W・X・Y 群だけを測る。
#     preflight・DB 確認は共通で走るが、実在する表は作らない（ROUND=3〜7・9〜12 と同じ）。
#     T 群（実在しないカタログ nosuchcatalog266 の 3 部 + LOCATION に句が付く形。t0〜t10 は
#     既定の Context、S3TABLES_* が揃えば t0s・t1s・t2s・t7s・t9s も S3 Tables の Context で
#     測る）と Y 群（Trino にだけあるカタログ名 hive・iceberg・system・tpch・memory、y1〜y5）は
#     常に既定の Context で投げる。U 群（u0〜u7）・V 群（v0〜v9・vc1・vc4）・W 群（w0〜w10）は
#     S3TABLES_* が揃うときだけ S3 Tables の Context で投げる。LOCATION の組み立ては
#     probe_location_t（probe_location_s と同じ形。空のプレフィックス、接頭辞を 266 にする）。
#     受理されたら同じ仕組み（run_create_then_drop_ctx）で消す（消す Context は項目ごとに
#     issue 本文の指示どおり。既定・S3 Tables のどちらで作られても対応する Context で消す）。
#     X 群（実在する連携カタログの 3 部 + LOCATION）は、xc（既定の Context の対照）だけは常に
#     投げ、x1〜x4（連携カタログの 3 部）は連携カタログが要る。連携カタログは
#     FEDERATED_CATALOG が設定されていればそれを使い、無くて CREATE_GLUE_CATALOG=1 のときだけ
#     aws athena create-data-catalog で自分のアカウントの Glue を指すデータカタログ
#     （athena_local_probe_266_<乱数>cat）を作って使う（aws sts get-caller-identity・
#     aws athena list-data-catalogs の疎通が通るときだけ。失敗すれば X 群だけ未測定にする）。
#     作ったデータカタログは、x1〜x4 の後始末が終わってから明示的に delete-data-catalog で
#     消し、結果を summary に出す（消せなければ summary の冒頭に「要手動削除」と出し、trap でも
#     ベストエフォートでもう一度消しにいく）。create/delete-data-catalog には
#     start_query_retry と同じ考え方の再試行（名前解決・接続の失敗だけ、aws_call_retry）を掛ける。
#     x1〜x4 のうち、連携カタログが作った Glue のデータカタログのときは、後始末の DROP が
#     失敗したら既定の Context でも同じ DROP をもう一度投げる（同じ Glue を指すため）。
#     どちらも無ければ X 群は x1〜x4 を未測定として残す（xc だけ測る）。
#   - 【issue #266 の補足で追加】ROUND=14 は、ROUND=13 の実測（2026-09-26、生データ
#     `run-20260926-221348`）で見つかった「未測定のまま残るもの」（x3 の対照。既定の Context の
#     `CREATE EXTERNAL TABLE AwsDataCatalog.<db>.<t> (n int) LOCATION '..'` が xc の EXTERNAL 無し
#     の対照と対にならなかった）と「範囲外の発見」（S3 Tables の Context で LOCATION の無い
#     非 EXTERNAL の ROW FORMAT が開始して FAILED になる族）を測る Z 群だけを測る。preflight・
#     DB 確認は共通で走るが、実在する表は作らない。LOCATION の組み立ては ROUND=13 と同じ
#     probe_location_t（接頭辞は 266 のまま。プレフィックスは変えていない）。連携カタログを
#     決める・作る・削除するロジック（resolve_federated_catalog・delete_glue_catalog_if_created）と、
#     受理されたら連携カタログの Context で消し、失敗したら既定の Context でも試みる後始末
#     （run_x_create）は、共有の関数として ROUND=13 の X 群とそのまま同じものを使う（ROUND=13
#     の挙動・出力は変えていない。ROUND=13 側は inline だった処理をこの共有関数の呼び出しに
#     置き換えただけ）。z0・z0b・z0c（既定の Context。x3 の対照。EXTERNAL 付きの 1〜3 部の名前）は
#     常に投げる。z1〜z5（連携カタログの 3 部・1 部の名前。既定の Context と、連携カタログを
#     Catalog にした Context <GCTX>=`Catalog=<連携カタログ>,Database=<DB>`）は連携カタログが
#     使えるときだけ（z3 は <GCTX> で作って既定の Context で消す。それ以外は run_x_create で
#     連携カタログの Context に作って消し、Glue のデータカタログなら既定の Context にも
#     フォールバックする）。z6〜z17（S3 Tables の Context の、LOCATION の無い非 EXTERNAL の
#     ROW FORMAT の族と、ほかの単独の Hive の句）は S3TABLES_* が揃うときだけ。開始できた
#     z0・z0b・z0c・z1〜z5 は、ROUND=13 の X 群と同じく QueryExecutionContext・
#     StatementType/SubstatementType の詳細も summary に出す。
#   - 【issue #251 で追加（2 ラウンド目）】ROUND=15 は、CTAS の SELECT 部分が解析／実行の
#     どちらで失敗するか（issue #251 のコメントの項目 1〜3）と、Catalog 省略・プロパティ付き・
#     `WITH NO DATA`・複数行／0 行・括弧／`WITH` 句・ExecutionParameters（項目 4〜10）、
#     S3 Tables の Context の名前空間まわり（項目 11・12）を測る T 群だけを測る。preflight・
#     DB 確認は共通で走るが、実在する表は作らない（ROUND=3〜7・9〜11 と同じ）。t1〜t2・t5〜t15
#     は S3TABLES_* によらず常に既定の Context（または Catalog を省略した Context）で投げ、
#     t3・t4（S3 Tables の Context で t1・t2 と同じ文）と t16〜t19（S3 Tables の Context の
#     名前空間まわり。t19 は r1 の再現 + IF NOT EXISTS で CTAS でない）は S3TABLES_* が
#     揃うときだけ測る。受理されたら同じ Context か、CTAS の対象 DB・名前空間を Database に
#     した Context で消す（run_create_then_drop_ctx をそのまま流用。t15 だけ
#     ExecutionParameters を CREATE の 1 回にしか掛けられないため手組みにした）。FAILED に
#     なった項目は結果ファイル本体・`.metadata` を取得し、CTAS（t1〜t18）は理由に書かれた
#     location のオーファンデータ確認（`check_ctas_orphan_data`）も行う。SUCCEEDED の CTAS
#     （t1〜t18）は `.metadata` も取得する（t19 は CTAS でないので、どちらも r1 と同じ
#     本体・`.metadata` の有無だけを見る）。
#   - 【issue #270 で追加】ROUND=16 は、#266 の先行実測（ROUND=13・14。範囲外の発見の 1）で見つかった
#     「S3 Tables の Context で LOCATION の無い非 EXTERNAL の CREATE TABLE の ROW FORMAT・
#     PARTITIONED BY・CLUSTERED BY・TBLPROPERTIES が開始して FAILED になる族」の、issue #270 本文の
#     「測っていない形」1〜3（句どうしの優先順、Iceberg の書き方の PARTITIONED BY、Iceberg で有効な
#     TBLPROPERTIES）と、周辺の名前の形を測る cl・pr・pn・pa・tp 群だけを測る。preflight・
#     DB 確認は共通で走るが、実在する表は作らない。GLUE のデータカタログ（CREATE_GLUE_CATALOG）は
#     このラウンドでは使わない。すべて S3 Tables の Context（Catalog=<S3TABLES_CATALOG>,
#     Database=<S3TABLES_NS>）だけに投げ、LOCATION は付けない（このラウンドは全部 LOCATION 無し）。
#     S3TABLES_* が揃わなければ全項目を「未測定（S3TABLES_* 未設定）」として残す。
#     cl 群（cl0・cl1）は対照で、cl1 は z15（`PARTITIONED BY (p int)` 単独）の再現。pr 群（pr1〜pr10）は
#     Hive の句の順（PARTITIONED BY → CLUSTERED BY → ROW FORMAT → STORED AS → TBLPROPERTIES）で複数の
#     句を組み合わせ、句どうしの優先順（issue の 1）を測る。pn 群（pn1〜pn6）は名前の形（名前空間・
#     AwsDataCatalog 3 部・IF NOT EXISTS・バッククォート・列リスト無し）を測る（z15〜z17 は 1 部の
#     名前だけ測った周辺）。pa 群（pa1〜pa6）は Iceberg の書き方の PARTITIONED BY（issue の 2。列名だけ・
#     `bucket`／`day` などの変換関数・型付き・存在しない列名）を測る。tp 群（tp1〜tp7）は Iceberg で
#     有効な TBLPROPERTIES（issue の 3。`table_type`・`format`・`write_compression`、大文字のキー、
#     複数キー、`table_type`='HIVE'）を測る。受理された項目（SUCCEEDED）は、DROP の前に同じ Context で
#     `SHOW CREATE TABLE <名前>` を `<label>-showcreate` として投げ、結果ファイル本体を取得・保存する
#     （`run_create_then_drop_ctx_showcreate`。パーティション・表プロパティの実際の形をあとで確かめる
#     ため。SHOW CREATE TABLE が失敗しても DROP は続ける）。この SHOW CREATE TABLE の分も見込み本数に
#     数える（受理された項目ごとに +1）。summary では SHOW CREATE TABLE の結果に含まれうる LOCATION の
#     S3 URI も `mask_s3_uri` で `<S3_URI>` に畳んで伏せる（S3 Tables の実バケット・テーブル ID は
#     hide の実名の完全一致の置換では畳めないため）。
#   - 【issue #271 で追加】ROUND=17 は、本物の `CREATE EXTERNAL TABLE <3 部の名前>` が
#     GetQueryExecution の `Query` から 1 部目のカタログと直後の `.` を落とす（実測済み。
#     #266 の先行実測の範囲外の発見）のに、athena-local の `src/operation/reported_query.rs` の
#     `CATALOG_DROPPED` に `CREATE EXTERNAL TABLE` が無く落とさない、という食い違いの周辺だけを
#     測る q 群（q0〜q25。q15 は欠番）を測る。ROUND=8（#242）の「別の DB を作って最後に消す」
#     `<DB2>`（`<PROBE>_db2`）の準備・後始末をそのまま流用し、開始できた全項目の返った
#     `Query`（repr）・`QueryExecutionContext`・状態・StatementType/SubstatementType・理由を
#     summary に出す（このラウンドの決め手のため、ROUND=13・14 のように一部の項目だけに絞らない）。
#     preflight・DB 確認は共通で走るが、実在する表 `<PROBE>_real` は作らない。準備で
#     `<DB2>` に加えて、同名の表がある形（q14）用の実在する表 `<PROBE>_qdup`
#     （`CREATE EXTERNAL TABLE <DB>.<PROBE>_qdup (n int) PARTITIONED BY (p int) LOCATION '...'`）も
#     作り、最後に消す（どちらも作れなければ、使う項目だけ未測定にする。qdup が無ければ
#     q14・q16 だけ未測定。q16b はそのまま投げる）。LOCATION の組み立ては probe_location_t と
#     同じ形の probe_location_q（空のプレフィックス、接頭辞を 271 にする）。q1〜q5b・q0（Context の
#     DB と文の DB が違う形）・q6〜q11b（IF NOT EXISTS・句・空白・コメント・大小文字などの形）・
#     q12・q12b（Iceberg）・q13・q13b・q14（FAILED になる形）は
#     すべて `run_create_then_drop_ctx` で投げ、消す名前は `<DB>.<t>` / `<DB2>.<t>` の
#     2 部で指定する（Context の Database と文の DB が違っても確実に消すため。q14 だけは
#     受理されても後始末を投げず、最後の準備の後始末に任せる）。q16〜q21（SHOW PARTITIONS・
#     CREATE DATABASE・ALTER DATABASE・DESCRIBE DATABASE・DROP DATABASE・ALTER TABLE ADD
#     PARTITION）は読み取りか、表・DB を作らない DDL なので `run_in_ctx` だけで投げる
#     （q17 だけ、受理されたら `DROP DATABASE IF EXISTS <PROBE>_q17db CASCADE` で消す）。
#     q18・q18b・q19・q19b は対象を必ず作った `<DB2>` にする（利用者の DB には投げない）。
#     S3 Tables の Context の q22・q23 と、連携カタログ（FEDERATED_CATALOG か
#     CREATE_GLUE_CATALOG=1）の `<GCTX>`=`Catalog=<連携カタログ>,Database=<DB>` の q24・q25 は、
#     それぞれ S3TABLES_*・連携カタログが揃うときだけ投げる。q24・q25 は ROUND=13・14 と共有する
#     `resolve_federated_catalog`・`run_x_create`・`delete_glue_catalog_if_created` をそのまま
#     流用し（挙動は変えていない）、消す名前を `<DB2>.<t>` の 2 部にすることで、Context は
#     `<GCTX>`（Database=`<DB>`）のまま `<DB2>` 側の表を消す。後始末の順序は
#     表（各項目の `-cleanup`）→ `<DB2>` の DROP DATABASE → `<PROBE>_qdup` の DROP TABLE →
#     （連携カタログを作っていれば）データカタログの削除。
#   - 【issue #270 の 2 ラウンド目で追加】ROUND=20 は、ROUND=16 と同じ族（S3 Tables の Context で
#     LOCATION の無い非 EXTERNAL の CREATE TABLE が開始してから FAILED にする句）のうち、
#     issue #270 のコメントで挙がった続き（TBLPROPERTIES のキーの範囲、table_type の値と組、
#     列リスト無しの形、ちょうど小文字の awsdatacatalog の 3 部、名前空間が無いときとの優先順）を
#     測る k・v・c・a・m 群と、対照 x0（cl0 と同じ `(n int)` だけの形）だけを測る。ROUND=18 は #272、19 は
#     #273 の実測が使う（16 の次は 20）。preflight・DB 確認は
#     共通で走るが、実在する表は作らない。すべて S3 Tables の Context（Catalog=`<S3TABLES_CATALOG>`,
#     Database=`<S3TABLES_NS>`）だけに投げ（m5 だけ Context の Database を実在しない名前空間
#     `<NOPE>`=`<PROBE>_nope270` にする）、LOCATION は付けない。S3TABLES_* が揃わなければ全項目
#     「未測定」として残す。m 群（m0〜m7）は名前空間 `<NOPE>` を文の中で 2 部・3 部の qualified
#     name に含める形（m5 だけ Context の Database に `<NOPE>` を使う 1 部の名前）で、名前空間が
#     無いときの理由（#231 の i2・j12 と同じ `Cannot find or access the specified table` の見込み。
#     m0 が対照）と、ほかの句の理由との優先順を測る。a 群は、ROUND=13〜16 で測った大文字混じりの
#     `AwsDataCatalog`・`awsdatacatalog . ` ではなく、ちょうど小文字の 3 部連続（空白・ドット無し）が
#     句付きでも同じ扱いかを見る。受理された項目は ROUND=16 と同じ `run_create_then_drop_ctx_showcreate`
#     で、DROP の前に同じ Context で `SHOW CREATE TABLE <名前>` を `<label>-showcreate` として投げ、
#     結果ファイル本体を取得・保存する（この分も見込み本数に数える）。
#   - 【issue #272 で追加】ROUND=18 は、#251 の 2 ラウンド目の実測（ROUND=15、生データ
#     `run-20260926-231125` の t1〜t5）で見つかった、エンジン（Trino）で失敗した CTAS の理由に
#     本物が付ける接尾辞（` You may need to manually clean the data at location
#     '<OutputLocation>tables/<id>' before retrying. Athena will not delete data in your account.`）と、
#     解析のエラーの位置が受け取った文の位置ではない（`line 6:3` のように、本物が CTAS を組み直して
#     実行しているとみられる）という 2 つの差の周辺だけを測る p・w 群と、対照の c1y、INSERT の位置を
#     見る i 群を測る（issue #272 のコメントの `WITH NO DATA` も w 群に含める）。preflight・DB 確認は
#     共通で走るが、実在する表 `<PROBE>_real` は作らない。すべて既定の Context
#     （`Catalog=AwsDataCatalog,Database=<DB>`）だけに投げる（S3 Tables・連携カタログは使わない）。
#     準備で実在する表 `<PROBE>_src`（CTAS、`SELECT 1 AS n, 'x' AS s`）を作り、最後に消す（作れなければ、
#     これを使う項目 p2・p2y・p3・p3y・p4・p4y・w3・w3y・c1y・i1・i2 だけ未測定にする）。無い表の名前は
#     `<PROBE>_nosrc`（固定）、無い DB の名前は `<PROBE>_nodb<N>`（項目ごとに別名。組み直しの規則が
#     DB の有無で変わるかを見るため、無い DB を 1 部目にした X 群と、実在する DB を使う Y 群
#     （ラベルの末尾に y）の両方に投げる）。p 群（p1〜p12、p13y〜p15y）は SELECT の失敗の位置
#     （無い表・無い列・複数行・空白・括弧・WITH 句・CTAS の WITH 句・IF NOT EXISTS・先頭のコメント・
#     型の不一致）と名前の部数（p13y・p14y）・WITH DATA（p15y）を測り、w 群（w1〜w3。X・Y とも）は
#     issue のコメントの `WITH NO DATA` が問い合わせの失敗を実行するかを測る。c1y は失敗しない対照
#     （SUCCEEDED の見込み → 消す）、i 群（i1・i2）は INSERT で同じ失敗が同じ位置になるかを見る
#     （表そのものは作らず `<PROBE>_src` に使い回す）。開始できた全項目は、返った Query（repr）・
#     StatementType/SubstatementType・StateChangeReason の全文を summary に出す（一部の項目に
#     絞らない）。FAILED になった CTAS（p・w 群・c1y）は、結果ファイル本体・.metadata の
#     取得（fetch_failed_attachments）に加えて、理由に書かれた location のオーファンデータ確認
#     （check_ctas_orphan_data、ROUND=11 と共有）も行う。加えて summary の末尾に「位置の表」を出し、
#     `line L:C` を含む項目ごとに、本物が返した位置と、送った文（マスク前の実文で数える）でエラーの
#     対象の語（無い表名・列名・リテラルなど）が始まる 1 始まりの行・桁を並べる（組み直しの規則を
#     読むため）。
#   - 【issue #273 で追加】ROUND=19 は、S3 Tables の Context で名前空間が無い CTAS が開始して
#     FAILED になる（`NOT_FOUND: Schema <S3 Tables のカタログの内部名>$schema:<名前空間> not found.` +
#     `You may need to manually clean the data at location '...' before retrying.`。#251 の
#     ラウンド 15 の t16・t17 で見つけた事実の周辺）のうち、Database を省略した Context（`<S3NODB>`
#     ＝ `Catalog=<S3TABLES_CATALOG>` だけ）の形（d 群）と、名前空間が無い CTAS の残りの形
#     （f 群）、対照（c 群）だけを測る。preflight・DB 確認は共通で走るが、実在する表
#     `<PROBE>_real` は作らない。代わりに、実在する Glue の表 `<DB>.<PROBE>_src`
#     （`CREATE TABLE <DB>.<PROBE>_src AS SELECT 1 AS n`）を S3TABLES_* の有無によらず作り、
#     最後に消す（f7・f10 の対照・問い合わせ元。作れなければ f7・f10 だけ未測定にする）。
#     S3TABLES_* が無ければ d・f・c 群は全項目「未測定（S3TABLES_* 未設定）」になる（準備の
#     `<PROBE>_src` 以外ほぼ何も測れない旨を summary の冒頭と実行開始時の標準出力の両方に
#     目立つように出す）。d1〜d4（`<S3NODB>` で作る。d1 は非 CTAS、d2 は 1 部の CTAS、d3 は
#     ある名前空間の 2 部、d4 は無い名前空間の 2 部）は、受理されたら後始末を `<S3NODB>` で
#     まず試み、失敗すれば `<S3>`（`Catalog=<S3TABLES_CATALOG>,Database=<S3TABLES_NS>`）でも
#     う一度 `DROP TABLE IF EXISTS` を試みる（`run_create_then_drop_nodb`。どちらも消せなければ
#     `PENDING_DROPS_CTX` に残り、summary 冒頭の「手で消してください」に載る）。d0 は
#     `<S3NODB>` の `SELECT 1`（対照）。f1〜f12（t16・t17 の再現、IF NOT EXISTS、名前空間の
#     綴りを大文字にした形、`WITH NO DATA`、問い合わせの失敗・無い表との順序、`WITH (format=...)`、
#     Glue にはあるが S3 Tables には無い名前、問い合わせ自体は通る形、バッククォート・二重引用符）
#     と c1・c2（t18 の再現・SUCCEEDED の見込み、#251 で分かっている非 CTAS の
#     `Cannot find or access the specified table`）は、受理されうるものも含めてすべて
#     `run_create_then_drop_ctx` で投げ、受理されたら作った Context と同じ Context で消す。
#     FAILED になった CTAS の項目（d2〜d4、f1〜f12、c1）は、`fetch_failed_attachments` で
#     結果ファイル本体と `.metadata` を、`check_ctas_orphan_data`（ROUND=11）で理由に書かれた
#     location のオーファンデータの有無も確かめる。開始できた全項目は、状態・
#     StatementType/SubstatementType・ErrorCategory/ErrorType・StateChangeReason の全文・
#     返った `QueryExecutionContext`・`Query`（repr）を summary に出す（ROUND=17 と同じ考え方）。
#   - 【issue #279 で追加】ROUND=22 は、#260 の無引用の `awsdatacatalog.<db>.<t>` の置換で
#     測れなかった／測っていない周辺（issue #279 本文の 1〜6）を測る P 群だけを測る。
#     preflight・DB 確認は共通で走るが、O 群とは別に実在する表 `<PROBE>_p_real`（Hive、1 行）・
#     Iceberg 表 `<PROBE>_p_ice`（LOCATION + `TBLPROPERTIES ('table_type'='ICEBERG')`、1 行）・
#     ビュー `<PROBE>_p_view` を作り、全項目で使い回して最後に消す（LOCATION の組み立ては
#     probe_location_t・probe_location_q と同じ形の `probe_location_p`。接頭辞を 279 にする）。
#     p0・p0b は各群の対照として常に投げる（p0: `<DEF>` の SELECT、p0b: Context の Catalog 省略
#     （`Database=<DB>` だけ）で #260 の o1 の形を再現）。p1〜p4（連携カタログ `<G>`。
#     ROUND=13・14・17 と共有する `resolve_federated_catalog`・`delete_glue_catalog_if_created`
#     をそのまま使い、CREATE_GLUE_CATALOG=1 で自分のアカウントの Glue を指すデータカタログを
#     作れるときだけ測る。p1・p2 は `<GCTX>`=`Catalog=<G>,Database=<DB>` の SELECT・INSERT、
#     p3・p4 は `<DEF>` で `<G>` を無引用の大文字混じりで書いた SELECT・INSERT）は `<G>` が
#     無ければ未測定にする。p5〜p16（`<DEF>` の DELETE・UPDATE・MERGE（対照は 1 部なしの
#     `<DB>.<ice>`。行を変えないよう `WHERE n = 999` の無害な no-op にする）・SHOW CREATE VIEW・
#     DROP VIEW・DROP VIEW IF EXISTS・ALTER TABLE RENAME の 3 形（受理されたら名前を戻す）・
#     SHOW COLUMNS・SHOW TBLPROPERTIES・SHOW PARTITIONS）は常に投げる。p17〜p26
#     （`<S3CTX>`=`Catalog=<S3TABLES_CATALOG>,Database=<S3TABLES_NS>` と
#     `<NOCAT>`=`Catalog=nosuchcatalog279,Database=<DB>` の EXPLAIN・CTAS・CREATE VIEW・
#     引用符付きの部品を含む SELECT）は、`<S3CTX>` 側だけ S3TABLES_* が揃うときだけ測り、
#     `<NOCAT>` 側は常に測る（CTAS・CREATE VIEW の受理された分は消す。CTAS・CREATE VIEW の
#     後始末は `run_create_then_drop_ctx` を、ビューは h8 と同じ「作る Context と消す Context を
#     分ける」手組みの後始末を使う）。p27・p28（`<DEF>` の INSERT の引用符付きの部品）・
#     p29〜p32（`<DEF>` の SELECT。p29 は引用符付きが 2 つ、p30・p31 は 4 部の列の参照に
#     引用符付きを含む形、p32 は o8 の再現）は常に投げる。成功した SELECT 系（p32 を含む）は
#     結果ファイル本体を `aws s3 cp` のリダイレクトで取得して保存する（列名の行は summary に出す）。
#     成功した INSERT（p2・p4・p27・p28）は、直後に `<label>-count` として
#     `SELECT count(*) FROM <DB>.<PROBE>_p_real` を投げ、結果を同じ形で取得する（p0・p0b の
#     直後の件数と比べれば増えたかが分かる）。
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
#   ラウンド 10（issue #248。#229 で扱わなかった S3 Tables の Context の Hive の CREATE TABLE の残り
#   （COMMENT・CLUSTERED BY・ROW FORMAT SERDE・FIELDS 以外の DELIMITED の句・TBLPROPERTIES の
#   2 組以上、LOCATION の無い EXTERNAL の各形、TRINO_CATALOG_MAP の別名や Trino にだけあるカタログの
#   3 部 + LOCATION、バッククォートの名前、入れ子の型）だけを測る。S3TABLES_* が無ければ s12 以外の
#   S 群は未測定として残す。連携カタログも測るなら FEDERATED_CATALOG を足す（無ければ s14 だけ
#   未測定として残す））:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=10 \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns \
#     FEDERATED_CATALOG=your_federated_catalog \
#     bash tools/measure/unquoted-ddl.sh
#   ラウンド 11（issue #251。S3 Tables の Context の場所の無い CREATE TABLE の名前空間まわり
#   （1 部の名前・2 部の IF NOT EXISTS・3 部の IF NOT EXISTS）と、CTAS の残り（j13 の再現の
#   .metadata・データの有無、DB 名の大文字小文字、IF NOT EXISTS の CTAS、1 部目の綴りと DB の
#   有無の組、既定の Context の対照）だけを測る。S3TABLES_* が無ければ r8a〜r8c 以外の R 群は
#   未測定として残す）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=11 \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns \
#     bash tools/measure/unquoted-ddl.sh
#   ラウンド 12（issue #260。無引用の awsdatacatalog.<db>.<t> の置換（#246）で測っていない周辺
#   （S3 Tables・連携カタログ・実在しないカタログの Context の SELECT・INSERT、引用符付きの部品、
#   4 部の列の参照、AwsDataCatalog 以外の別名キー、Context の Catalog 省略）だけを測る。
#   S3TABLES_*・FEDERATED_CATALOG が無ければ該当項目だけ未測定として残す）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=12 \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns \
#     FEDERATED_CATALOG=your_federated_catalog FEDERATED_DB=your_federated_db \
#     FEDERATED_TABLE=your_federated_table \
#     bash tools/measure/unquoted-ddl.sh
#   ラウンド 13（issue #266。#248 が「測った形だけ」に絞った条件の外側（実在しないカタログの
#   3 部 + LOCATION に句が付く形、S3 Tables の Context の LOCATION 付きの句の組み合わせ、
#   LOCATION の無い CREATE EXTERNAL TABLE に句が付く形、LOCATION の無い STORED AS の
#   2〜3 部の名前・IF NOT EXISTS・ほかの句、Trino にだけあるカタログ名・実在する連携カタログの
#   3 部 + LOCATION）だけを測る。S3TABLES_* が無ければ U・V・W 群と T 群の *s 項目は未測定として
#   残す。連携カタログが無ければ（FEDERATED_CATALOG も CREATE_GLUE_CATALOG=1 も無ければ）
#   X 群は xc だけ測り x1〜x4 は未測定として残す）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=13 \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns \
#     FEDERATED_CATALOG=your_federated_catalog \
#     bash tools/measure/unquoted-ddl.sh
#   ラウンド 13 で、連携カタログの代わりに自分のアカウントの Glue を指すデータカタログを
#   作って測るとき（athena:CreateDataCatalog・GetDataCatalog・DeleteDataCatalog・
#   ListDataCatalogs と sts:GetCallerIdentity が要る）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=13 \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns \
#     CREATE_GLUE_CATALOG=1 \
#     bash tools/measure/unquoted-ddl.sh
#   ラウンド 14（issue #266 の補足。ROUND=13 で見つかった未測定（x3 の対照）と範囲外の発見
#   （S3 Tables の Context の LOCATION の無い非 EXTERNAL の ROW FORMAT の族）だけを測る。
#   S3TABLES_* が無ければ Z 群の z6〜z17 は未測定として残す。連携カタログが無ければ
#   z1〜z5 は未測定として残す（z0・z0b・z0c だけ測る）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=14 \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns \
#     FEDERATED_CATALOG=your_federated_catalog \
#     bash tools/measure/unquoted-ddl.sh
#   ラウンド 14 で、連携カタログの代わりに自分のアカウントの Glue を指すデータカタログを
#   作って測るとき（ROUND=13 と同じ IAM 権限が要る）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=14 \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns \
#     CREATE_GLUE_CATALOG=1 \
#     bash tools/measure/unquoted-ddl.sh
#   ラウンド 15（issue #251 の 2 ラウンド目。CTAS の SELECT が解析／実行のどちらで失敗するか、
#   Catalog 省略・プロパティ付き・WITH NO DATA・複数行／0 行・括弧／WITH 句・
#   ExecutionParameters、S3 Tables の Context の名前空間まわりだけを測る。S3TABLES_* が
#   無ければ t3・t4・t16〜t19 は未測定として残す）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=15 \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns \
#     bash tools/measure/unquoted-ddl.sh
#   ラウンド 16（issue #270。#266 の先行実測の範囲外の発見の周辺、句どうしの優先順・Iceberg の
#   書き方の PARTITIONED BY・Iceberg で有効な TBLPROPERTIES・名前の形だけを測る。S3TABLES_* が
#   無ければ全項目が未測定として残る）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=16 \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns \
#     bash tools/measure/unquoted-ddl.sh
#   ラウンド 17（issue #271。開始できた CREATE EXTERNAL TABLE の 3 部の名前が GetQueryExecution の
#   Query から 1 部目のカタログを落とす周辺だけを測る。S3TABLES_* が無ければ q22・q23 が、
#   連携カタログ（FEDERATED_CATALOG か CREATE_GLUE_CATALOG=1）が無ければ q24・q25 が
#   未測定として残る）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=17 \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns \
#     FEDERATED_CATALOG=your_federated_catalog \
#     bash tools/measure/unquoted-ddl.sh
#   ラウンド 17 で、連携カタログの代わりに自分のアカウントの Glue を指すデータカタログを
#   作って測るとき（ROUND=13・14 と同じ IAM 権限が要る）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=17 \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns \
#     CREATE_GLUE_CATALOG=1 \
#     bash tools/measure/unquoted-ddl.sh
#   ラウンド 18（issue #272。エンジンで失敗した CTAS の理由に本物が付ける接尾辞と、解析のエラーの
#   位置が受け取った文の位置と違う規則（組み直し）の周辺、INSERT の位置、WITH NO DATA の失敗だけを
#   測る。S3 Tables・連携カタログは使わない）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=18 \
#     bash tools/measure/unquoted-ddl.sh
#   ラウンド 19（issue #273。S3 Tables の Context で名前空間が無い CTAS の、Database を省略した
#   形（d 群）と残りの形（f 群）・対照（c 群）だけを測る。S3TABLES_* が無ければ全項目が
#   未測定として残る。準備の実在する表 <PROBE>_src は S3TABLES_* によらず作って消す）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=19 \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns \
#     bash tools/measure/unquoted-ddl.sh
#   ラウンド 20（issue #270 の 2 ラウンド目。ROUND=16 の続きで、TBLPROPERTIES のキーの範囲・
#   table_type の値と組・列リスト無しの形・ちょうど小文字の awsdatacatalog の 3 部・名前空間が
#   無いときとの優先順だけを測る。S3TABLES_* が無ければ全項目が未測定として残る）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=20 \
#     S3TABLES_CATALOG=s3tablescatalog/your-bucket S3TABLES_NS=your_ns \
#     bash tools/measure/unquoted-ddl.sh
#   ラウンド 22（issue #279。#260 で測れなかった／測っていない周辺（連携カタログ・S3 Tables・
#   実在しないカタログの Context の DELETE・UPDATE・MERGE・DROP VIEW・ALTER TABLE RENAME など、
#   引用符付きの部品、4 部の列の参照）だけを測る。S3TABLES_* が無ければ p17・p19・p21・p23・p24 が、
#   連携カタログ（CREATE_GLUE_CATALOG=1）が無ければ p1〜p4 が未測定として残る）:
#   tools/dev.sh OUTPUT=s3://your-bucket/prefix/ DB=your_db ROUND=22 \
#     CREATE_GLUE_CATALOG=1 \
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
#                    10 は S 群（S3 Tables の Context の Hive の CREATE TABLE の残り。issue #248）だけ。
#                    実在する表は作らない。
#                    11 は R 群（S3 Tables の Context の場所の無い CREATE TABLE の名前空間まわりと
#                    CTAS の残り。issue #251）だけ。実在する表は作らない。
#                    12 は O 群（無引用の awsdatacatalog. の置換で測っていない周辺。issue #260）
#                    だけ。実在する表 `<PROBE>_o` を 1 つ作り、全項目で使い回して最後に消す。
#                    13 は T・U・V・W・X・Y 群（#248 が「測った形だけ」に絞った条件の外側。
#                    issue #266）だけ。実在する表は作らない。
#                    14 は Z 群（ROUND=13 の未測定・範囲外の発見の補足。issue #266）だけ。
#                    実在する表は作らない。
#                    15 は T 群（CTAS の SELECT が解析／実行のどちらで失敗するか、Catalog 省略・
#                    プロパティ付き・WITH NO DATA・複数行／0 行・括弧／WITH 句・
#                    ExecutionParameters、S3 Tables の Context の名前空間まわり。issue #251 の
#                    2 ラウンド目）だけ。実在する表は作らない。
#                    16 は cl・pr・pn・pa・tp 群（#266 の範囲外の発見の周辺。issue #270）だけ。
#                    実在する表は作らない。
#                    17 は q 群（開始できた CREATE EXTERNAL TABLE の 3 部の名前が
#                    GetQueryExecution の Query から 1 部目のカタログを落とす周辺。issue #271）
#                    だけ。実在する表 `<PROBE>_real` は作らないが、同名の表がある形（q14）用に
#                    `<PROBE>_qdup` を、別の DB として `<PROBE>_db2` を作り、最後に消す。
#                    20 は k・v・c・a・m 群と対照 x0（ROUND=16 の続き。issue #270 の 2 ラウンド目）
#                    だけ。実在する表は作らない（ROUND=18 は #272、19 は #273 の実測が使う）。
#                    18 は p・w 群と c1y・i 群（エンジンで失敗した CTAS の理由の接尾辞と、解析の
#                    エラー位置の組み直しの規則、INSERT の位置、WITH NO DATA の失敗。issue #272）
#                    だけ。実在する表 `<PROBE>_real` は作らないが、SELECT の失敗の対象にする実在する
#                    表 `<PROBE>_src` を作り、最後に消す（S3TABLES_*・FEDERATED_CATALOG は使わない）。
#                    19 は d・f・c 群（S3 Tables の Context で名前空間が無い CTAS の、Database を
#                    省略した形と残りの形・対照。issue #273）だけ。
#                    実在する表 `<PROBE>_real` は作らないが、実在する Glue の表
#                    `<DB>.<PROBE>_src` を S3TABLES_* によらず作り、最後に消す。
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
#                    ROUND=9 の N 群（n0〜n30・n32）、ROUND=10 の S 群（s1〜s11・s13・s15〜s18）、
#                    ROUND=11 の R 群（r1〜r7b）、ROUND=12 の O 群（o0〜o2）、ROUND=15 の T 群のうち
#                    t3・t4・t16〜t19 を測る。1 つでも欠けていれば「未測定（S3TABLES_* 未設定）」
#                    として summary に残す（ROUND=5 は j14〜j16、ROUND=9 は n31、ROUND=10 は s12、
#                    ROUND=11 は r8a〜r8c、ROUND=15 は t1・t2・t5〜t15 だけ測る）。
#                    ROUND=13 は U 群（u0〜u7）・V 群（v0〜v9・vc1・vc4）・W 群（w0〜w10）と、
#                    T 群のうち S3 Tables の Context で測る t0s・t1s・t2s・t7s・t9s、X 群の x2 を測る
#                    （欠ければこれらだけ未測定として残す。T 群の t0〜t10・Y 群・X 群の xc は
#                    ROUND=2 と同じく使わない）。ROUND=14 は Z 群の z6〜z17（S3 Tables の Context の
#                    非 EXTERNAL の ROW FORMAT の族とほかの句）を測る（欠ければ未測定として残す。
#                    z0・z0b・z0c・z1〜z5 は使わない）。ROUND=16 は cl・pr・pn・pa・tp 群の全項目
#                    （合計 31）を測る（欠ければ全項目が未測定として残る。GLUE のデータカタログ
#                    （CREATE_GLUE_CATALOG）はこのラウンドでは使わない）。ROUND=17 は q22・q23
#                    （S3 Tables の Context の CREATE TABLE）を測る（欠ければこの 2 項目だけ
#                    未測定として残る）。ROUND=19 は d・f・c 群の全項目（合計 19）を測る
#                    （欠ければ全項目が未測定として残り、準備の `<PROBE>_src` 以外ほぼ何も
#                    測れない。GLUE のデータカタログ（CREATE_GLUE_CATALOG）・FEDERATED_CATALOG は
#                    このラウンドでは使わない）。ROUND=20 は k・v・c・a・m 群と対照 x0 の全項目
#                    （合計 32）を測る（欠ければ全項目が未測定として残る）。ROUND=22 は
#                    P 群（issue #279）を測る（S3TABLES_* が無ければ p17・p19・p21・p23・p24 が、
#                    連携カタログ（FEDERATED_CATALOG か CREATE_GLUE_CATALOG=1）が無ければ
#                    p1〜p4 が未測定として残る）。
#   FEDERATED_CATALOG 連携カタログ（S3 Tables 以外）の名前。設定されていれば ROUND=10 の s14
#                    （TRINO_CATALOG_MAP の別名や Trino にだけあるカタログの 3 部 + LOCATION が
#                    実在するカタログのとき）と ROUND=12 の o3・o4（連携カタログの Context の
#                    SELECT・INSERT）、ROUND=13 の x1〜x4（連携カタログの 3 部 + LOCATION）、
#                    ROUND=14 の z1〜z5（同上の補足）、ROUND=17 の q24・q25（Context の DB と
#                    文の DB が違う形の補足）、ROUND=22 の p1〜p4（issue #279 の連携カタログの
#                    Context の SELECT・INSERT と、無引用の大文字混じりの別名キー）も測る。
#                    ROUND=13・14・17・22 だけ、これが無くても
#                    CREATE_GLUE_CATALOG=1 なら自分のアカウントの Glue を指すデータカタログを
#                    作って代わりに使う。無ければ該当項目だけ「未測定（FEDERATED_CATALOG
#                    未設定）」として残す。
#   FEDERATED_DB     連携カタログの中の、実在するデータベース名。
#   FEDERATED_TABLE  同じく実在する表名。この 2 つと FEDERATED_CATALOG が揃ったときだけ、
#                    ROUND=12 の o9（AwsDataCatalog 以外の別名キーを無引用の大文字混じりで
#                    書いた形）を測る。無ければ o9 だけ「未測定」として残す。
#   CREATE_GLUE_CATALOG ROUND=13・14・17・22 だけで使う。1 のとき、FEDERATED_CATALOG が未設定なら
#                    `aws athena create-data-catalog` で自分のアカウントの Glue を指す
#                    データカタログ（athena_local_probe_266_<乱数>cat）を作り、X 群の x1〜x4
#                    （ROUND=13）・Z 群の z1〜z5（ROUND=14）・q24・q25（ROUND=17）・
#                    p1〜p4（ROUND=22）の連携カタログ
#                    代わりに使う（要 athena:CreateDataCatalog・GetDataCatalog・
#                    DeleteDataCatalog・ListDataCatalogs、sts:GetCallerIdentity）。preflight で
#                    aws sts get-caller-identity・aws athena list-data-catalogs の疎通を確かめ、
#                    通らなければ該当群の連携カタログの項目だけ未測定にする（全体は止めない）。
#                    作ったデータカタログは後始末のあとに必ず削除を試み、消せなければ summary の
#                    冒頭に「要手動削除」と出す。FEDERATED_CATALOG が設定されていれば無視する。
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
#   - ROUND=10: 実在する表 <接頭辞>_real は作らない。S 群の CREATE TABLE（EXTERNAL を含む）は
#     すべて run_create_then_drop_ctx で投げ、想定外に受理されたらその場で無引用 + IF EXISTS の
#     DROP TABLE を投げて消す。結果は確かめ、SUCCEEDED にならなければ trap がもう一度
#     ベストエフォートで投げる。s8（EXTERNAL の AwsDataCatalog 3 部）は既定の Context で、
#     s12（既定の Context の n6 対照）・s13（Trino にだけあるような綴りの連携カタログ）・s14
#     （FEDERATED_CATALOG、設定されていれば）以外は S3 Tables の Context で DROP TABLE IF
#     EXISTS <接頭辞>_sN を投げる。s14 は FEDERATED_CATALOG の Context で消す。LOCATION は
#     <OUTPUT>athena-local-probe-248/<接頭辞>_<項目>/（空のプレフィックス。データは置かない）。
#   - ROUND=11: 実在する表 <接頭辞>_real は作らない。R 群の CREATE TABLE（r1〜r8c）はすべて
#     run_create_then_drop_ctx で投げ、想定外に（あるいは r3・r6a・r7a・r8b は想定どおり）
#     受理されたらその場で無引用 + IF EXISTS の DROP TABLE を投げて消す。結果は確かめ、
#     SUCCEEDED にならなければ trap がもう一度ベストエフォートで投げる。CTAS の対象 DB が
#     テスト用の実在しない名前（r4・r5・r6b・r7b・r8a・r8c）のときは、その DB を Database に
#     した Context で DROP する（作られていれば、という前提）。r6a・r7a・r8b（実在する DB・
#     既存の名前空間）は既定の Context か S3 Tables の Context（作った Context と同じ）で消す。
#     FAILED になった項目は結果ファイル本体と `.metadata` も取得し、CTAS で DB が無いために
#     FAILED になった項目（r4・r5・r6a・r6b・r7a・r7b・r8a・r8b・r8c のうち FAILED のもの）は、
#     理由に書かれた `location '...'` を `aws s3 ls --recursive` で読み取り、データが実際に
#     書かれているかも確かめる（`check_ctas_orphan_data`。読み取りのみで、書き込みは行わない）。
#   - ROUND=12: `<db>.<接頭辞>_o` を 1 つ CTAS で作り（O_TABLE）、O 群の全項目（SELECT・INSERT・
#     4 部の列の参照）で使い回して、最後に無引用 + IF EXISTS の DROP TABLE で消す（trap でも
#     保険をかける）。o5（実在しないカタログの Context）・o2・o4（S3 Tables・連携カタログの
#     Context）の INSERT は同じ表に 1 行足すだけで、表そのものは作り直さない。CREATE TABLE は
#     投げない（新しい表を作らない）。
#   - ROUND=13: 実在する表 `<接頭辞>_real` は作らない。T・U・V・W・X・Y 群の CREATE TABLE
#     （EXTERNAL を含む）はすべて run_create_then_drop_ctx で投げ、受理されたらその場で
#     無引用 + IF EXISTS の DROP TABLE を投げて消す（結果は確かめ、SUCCEEDED にならなければ
#     trap がもう一度ベストエフォートで投げる）。消す Context は、既定の Context で作られうる
#     項目（T・Y 群の全部、U 群の u7、W 群の w3）は既定の Context、S3 Tables の Context で
#     作られうる項目（U・V・W 群の残り）は S3 Tables の Context、X 群（x1〜x4）は連携カタログの
#     Context で、それぞれ DROP TABLE IF EXISTS を投げる。加えて、CREATE_GLUE_CATALOG=1 で
#     作った Glue のデータカタログを x1〜x4 が指すときは、その DROP が失敗したら既定の
#     Context でも同じ DROP をもう一度投げる（同じ Glue を指すため）。CREATE_GLUE_CATALOG=1 かつ
#     FEDERATED_CATALOG 未設定のときは、`aws athena create-data-catalog` で
#     `athena_local_probe_266_<乱数>cat`（自分のアカウントの Glue を指す GLUE 型のデータ
#     カタログ）を 1 つ作り、x1〜x4 の後始末が終わったあとに `aws athena delete-data-catalog` で
#     必ず消す（消せなければ summary の冒頭に「要手動削除」と出し、trap でも保険をかける）。
#   - ROUND=14: 実在する表 `<接頭辞>_real` は作らない。Z 群の CREATE TABLE（EXTERNAL を含む）は
#     すべて run_create_then_drop_ctx（z1・z2・z4・z5 は共有関数 run_x_create、z3 は直接）で投げ、
#     受理されたらその場で無引用 + IF EXISTS の DROP TABLE を投げて消す（結果は確かめ、
#     SUCCEEDED にならなければ trap がもう一度ベストエフォートで投げる）。消す Context は、
#     既定の Context で作られうる z0・z0b・z0c・z3 は既定の Context、z1・z2・z4・z5 は連携
#     カタログの Context（`Catalog=<連携カタログ>,Database=<DB>`）、S3 Tables の Context で
#     作られうる z6〜z17 は S3 Tables の Context で、それぞれ DROP TABLE IF EXISTS を投げる。
#     連携カタログの決め方・Glue のデータカタログの作成/削除（ROUND=13 の X 群と共有する
#     resolve_federated_catalog・delete_glue_catalog_if_created）と、Glue のデータカタログを
#     指すときの既定の Context への DROP のフォールバック（run_x_create）は ROUND=13 と同じ。
#   - ROUND=15: 実在する表 <接頭辞>_real は作らない。T 群（t1〜t19。t19 だけ CTAS でない
#     plain CREATE TABLE）はすべて run_create_then_drop_ctx で投げ（t15 だけ
#     ExecutionParameters を CREATE の 1 回にしか掛けられないため手組みで同じ形の後始末を
#     する）、想定外に（あるいは t7・t10・t18 は想定どおり）受理されたらその場で無引用 +
#     IF EXISTS の DROP TABLE を投げて消す。結果は確かめ、SUCCEEDED にならなければ trap が
#     もう一度ベストエフォートで投げる。対象 DB・名前空間がテスト用の実在しない名前
#     （t1〜t4・t6・t8・t9・t11〜t17・t19）のときは、その DB・名前空間を Database にした
#     Context で DROP する（作られていれば、という前提）。t5・t7・t10・t18（実在する DB・
#     名前空間）は作った Context と同じ Context で消す。FAILED になった項目は結果ファイル
#     本体と `.metadata` も取得し、CTAS（t1〜t18）は理由に書かれた `location '...'` を
#     `aws s3 ls --recursive` で読み取り、データが実際に書かれているかも確かめる
#     （`check_ctas_orphan_data`）。SUCCEEDED の CTAS（t1〜t18 のうち t7・t10・t18、想定外に
#     受理された項目を含む）は `.metadata` も取得する（t19 は CTAS でないので、どちらも r1 と
#     同じ本体・`.metadata` の有無だけを見る）。
#   - ROUND=16: 実在する表 `<接頭辞>_real` は作らない。GLUE のデータカタログ（CREATE_GLUE_CATALOG）は
#     このラウンドでは使わない。cl・pr・pn・pa・tp 群の CREATE TABLE はすべて S3 Tables の Context
#     だけに `run_create_then_drop_ctx_showcreate`（作る Context と消す Context は常に同じ）で投げる。
#     受理されたら、DROP の前に同じ Context で `SHOW CREATE TABLE <名前>` を投げて結果ファイル本体を
#     取得し（SHOW CREATE TABLE が失敗しても続ける）、そのあと無引用 + IF EXISTS の DROP TABLE を
#     投げて消す（結果は確かめ、SUCCEEDED にならなければ trap がもう一度ベストエフォートで投げる）。
#     LOCATION は付けない（このラウンドは全部 LOCATION 無し）。
#   - ROUND=17: 実在する表 `<接頭辞>_real` は作らない。準備で別の DB `<接頭辞>_db2` と、同名の表が
#     ある形（q14）用の実在する表 `<接頭辞>_qdup`（PARTITIONED BY 付き、場所の指定あり）を作り、
#     最後に消す（どちらも trap でも保険をかける）。q1〜q13b・q22〜q25 の CREATE TABLE（EXTERNAL を
#     含む）は `run_create_then_drop_ctx`（q24・q25 は共有関数 `run_x_create`）で投げ、受理された
#     らその場で無引用 + IF EXISTS の DROP TABLE を投げて消す（消す名前は `<DB>.<t>` /
#     `<DB2>.<t>` の 2 部で指定し、結果は確かめる。SUCCEEDED にならなければ trap がもう一度
#     ベストエフォートで投げる）。q14 だけは受理されても後始末を投げない（同名の準備の表と
#     同じなので、最後の `<PROBE>_qdup` の後始末に任せる）。q17（CREATE DATABASE）は受理されたら
#     その場で `DROP DATABASE IF EXISTS <PROBE>_q17db CASCADE` を投げて消す。CREATE_GLUE_CATALOG=1
#     かつ FEDERATED_CATALOG 未設定のときは、ROUND=13・14 と同じ `athena_local_probe_266_<乱数>cat`
#     を 1 つ作り、q24・q25 の後始末が終わったあとに必ず削除を試みる。
#   - ROUND=20: 実在する表 `<接頭辞>_real` は作らない。k・v・c・a・m 群と対照 x0 の CREATE TABLE は
#     すべて S3 Tables の Context（m5 だけ Database を `<NOPE>` にした Context）だけに
#     `run_create_then_drop_ctx_showcreate`（作る Context と消す Context は常に同じ）で投げる。
#     受理されたら、DROP の前に同じ Context で `SHOW CREATE TABLE <名前>` を投げて結果ファイル本体を
#     取得し（SHOW CREATE TABLE が失敗しても続ける）、そのあと無引用 + IF EXISTS の DROP TABLE を
#     投げて消す（結果は確かめ、SUCCEEDED にならなければ trap がもう一度ベストエフォートで投げる）。
#     LOCATION は付けない（このラウンドは全部 LOCATION 無し）。
#   - ROUND=22: 実在する表 `<接頭辞>_p_real`（Hive、1 行）・Iceberg 表 `<接頭辞>_p_ice`
#     （LOCATION 付き、1 行）・ビュー `<接頭辞>_p_view` を作り、全項目で使い回して最後に消す
#     （どれも trap でも保険をかける）。p19・p20（CTAS）は `run_create_then_drop_ctx`、
#     p21・p22（CREATE VIEW）は h8 と同じ「作る Context と消す Context を分ける」手組みの
#     後始末で受理されたその場で消す。ALTER TABLE RENAME の 3 形（p11〜p13）は、受理されたら
#     次の項目の前に必ず名前を戻す。CREATE_GLUE_CATALOG=1 かつ FEDERATED_CATALOG 未設定のときは、
#     ROUND=13・14・17 と同じ `athena_local_probe_266_<乱数>cat` を 1 つ作り、p 群の後始末が
#     終わったあとに必ず削除を試みる。
#
# 課金について: ALTER TABLE・DROP TABLE・DELETE・UPDATE・MERGE はメタデータだけを見る／書く文
# （DELETE・UPDATE・MERGE は `WHERE n = 999` などの no-op で行を変えない）で、実データの
# スキャンは無い。CREATE TABLE（実在する表の準備・C3・C20・C21・C22・C23、E・F 群、
# ROUND=3 の H・Q・P 群、ROUND=5 の J 群、ROUND=9 の N 群、ROUND=10 の S 群、ROUND=11 の R 群、
# ROUND=12 の O_TABLE の準備、ROUND=13 の T・U・V・W・X・Y 群、ROUND=14 の Z 群、ROUND=15 の
# T 群、ROUND=16 の cl・pr・pn・pa・tp 群、ROUND=17 の準備（<PROBE>_qdup）と q 群、ROUND=18 の
# 準備（<PROBE>_src）と p・w 群・c1y、ROUND=20 の k・v・c・a・m 群と対照 x0、ROUND=22 の
# 準備（<PROBE>_p_real・<PROBE>_p_ice）と p19・p20。
# いずれも 0〜3 行（t11 だけ 3 行、ほかは 0 行）もスキャンや書き込みは軽微。SHOW CREATE TABLE・
# ROUND=12 の SELECT・INSERT も 1 行だけ、ROUND=18 の i1・i2（INSERT）は 0〜1 行、ROUND=22 の
# SELECT・INSERT・count(*) も 1 行だけ。Athena の最小課金 × クエリ数の見込み。
# ROUND=5・10・11・13・14・15・16・17・18・22 の結果ファイルの読み出し（aws s3 cp）と
# ROUND=11・15・18 のオーファンデータ確認（aws s3 ls）は Athena のクエリではなく S3 の
# GetObject／ListObjects で、課金には乗らない。ROUND=13・14・17・22 の
# create-data-catalog／get-data-catalog／delete-data-catalog／list-data-catalogs・
# sts:GetCallerIdentity は Athena のクエリではなく、スキャン課金には乗らない。
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
# == ROUND=10（S 群のみ。issue #248。preflight・DB 確認は共通、実在する表は作らない） ==
#
#   [StartQueryExecution]
#   preflight（SELECT 1 + SHOW TABLES）2
#   + S 群のうち S3TABLES_* が揃うときだけ（s1〜s11・s13・s15〜s18 の 16）
#   + s14（S3TABLES_* と FEDERATED_CATALOG が両方揃うときだけ）1
#   + s12（既定の Context。S3TABLES_* によらず常に投げる）1
#   = 20（S3TABLES_* と FEDERATED_CATALOG が両方あり）／19（S3TABLES_* のみ）／3（どちらも無し）。
#   受理された CREATE TABLE ごとに、その場で DROP する後始末が 1 本ずつ増える（最大 +18）。
#
#   [GetQueryExecution]
#   開始できた項目だけ終端状態までポーリングし、終端後にもう 1 回まとめて取得する。
#
#   [その他]
#   FAILED になった項目ごとに、結果ファイル本体と `<OutputLocation>.metadata` の取得
#   （aws s3 cp、それぞれ 1 回）を追加で呼ぶ（最大で S 群の項目数 × 2 回）。Athena の
#   API ではないので上の StartQueryExecution・GetQueryExecution の回数には含めない。
#
# == ROUND=11（R 群のみ。issue #251。preflight・DB 確認は共通、実在する表は作らない） ==
#
#   [StartQueryExecution]
#   preflight（SELECT 1 + SHOW TABLES）2
#   + R 群のうち S3TABLES_* が揃うときだけ（r1〜r7b の 9）
#   + r8a〜r8c（既定の Context。S3TABLES_* によらず常に投げる）3
#   = 14（S3TABLES_* あり）／5（無し）。
#   受理された CREATE TABLE ごとに、その場で DROP する後始末が 1 本ずつ増える（最大 +12）。
#   r3・r6a・r7a・r8b は受理されうる（IF NOT EXISTS・既存の名前空間・既存の DB）。
#
#   [GetQueryExecution]
#   開始できた項目だけ終端状態までポーリングし、終端後にもう 1 回まとめて取得する。
#
#   [その他]
#   FAILED になった項目ごとに、結果ファイル本体と `<OutputLocation>.metadata` の取得
#   （aws s3 cp、それぞれ 1 回）を追加で呼ぶ（最大で R 群の項目数 × 2 回）。CTAS で DB が
#   無いために FAILED になった項目（最大 9 項目）ごとに、理由に書かれた location をオーファン
#   データの確認（aws s3 ls --recursive、1 回）にも使う。どちらも Athena の API ではないので
#   上の StartQueryExecution・GetQueryExecution の回数には含めない。
#
# == ROUND=12（O 群のみ。issue #260。preflight・DB 確認は共通） ==
#
#   [StartQueryExecution]
#   preflight（SELECT 1 + SHOW TABLES）2
#   + O_TABLE の準備 1・後始末 1
#   + 常に投げる o5・o6・o7・o8・o10・o11 の 6
#   + S3TABLES_* が揃うときだけの o0・o1・o2 の 3
#   + FEDERATED_CATALOG が揃うときだけの o3・o4 の 2
#   + FEDERATED_CATALOG・FEDERATED_DB・FEDERATED_TABLE が揃うときだけの o9 の 1
#   = 16（全部あり）／10（どちらも無し）。
#   このスクリプトの実測値は $START_CALL_FILE の行数（summary.txt に出る）。
#
#   [GetQueryExecution]
#   開始できた項目だけ終端状態までポーリングし、終端後にもう 1 回まとめて取得する。
#
#   [その他]
#   FAILED になった項目ごとに、結果ファイル本体と `<OutputLocation>.metadata` の取得
#   （aws s3 cp、それぞれ 1 回）を追加で呼ぶ（最大で O 群の項目数 × 2 回）。Athena の
#   API ではないので上の StartQueryExecution・GetQueryExecution の回数には含めない。
#
# == ROUND=13（T・U・V・W・X・Y 群のみ。issue #266。preflight・DB 確認は共通） ==
#
#   [StartQueryExecution]
#   preflight（SELECT 1 + SHOW TABLES）2
#   + 常に投げる T 群 t0〜t10 の 11 + Y 群 y1〜y5 の 5 + X 群 xc の 1
#   + S3TABLES_* が揃うときだけの T 群 t0s・t1s・t2s・t7s・t9s の 5、U 群 u0〜u7 の 8、
#     V 群 v0〜v9・vc1・vc4 の 12、W 群 w0〜w10 の 11（計 36）
#   + 連携カタログ（FEDERATED_CATALOG か、CREATE_GLUE_CATALOG=1 で作れた Glue のデータ
#     カタログ）が使えるときだけの x1・x3・x4 の 3、そのうち S3TABLES_* も揃えば x2 の 1（計 4）
#   = 19（S3TABLES_* も連携カタログも無し）／55（S3TABLES_* のみ）／22（連携カタログのみ）／
#   59（両方あり）。このスクリプトの実測値は $START_CALL_FILE の行数（summary.txt に出る）。
#   受理された CREATE TABLE ごとに、その場で DROP する後始末が 1 本ずつ増える
#   （最大 +16 T 群、+5 Y 群、+8 U 群、+12 V 群、+11 W 群、+4 X 群 = 最大 +56）。
#   CREATE_GLUE_CATALOG=1 で作った Glue のデータカタログを指す x1〜x4 は、後始末の DROP が
#   失敗すると既定の Context でももう一度 DROP を試みる（最大 +4。上の内訳には含めない）。
#
#   [GetQueryExecution]
#   開始できた項目だけ終端状態までポーリングし、終端後にもう 1 回まとめて取得する。
#
#   [Athena データカタログ管理 API]
#   CREATE_GLUE_CATALOG=1 かつ FEDERATED_CATALOG 未設定のときだけ呼ぶ。preflight で
#   sts:GetCallerIdentity・athena:ListDataCatalogs を 1 回ずつ、作成できれば
#   athena:CreateDataCatalog・GetDataCatalog を 1 回ずつ、x1〜x4 の後始末のあとに
#   athena:DeleteDataCatalog を 1 回（消せなければ trap でもう一度ベストエフォートで）。
#   create-data-catalog・delete-data-catalog は名前解決・接続の失敗だけ再試行する
#   （aws_call_retry。試行回数を記録する）。Athena のクエリではないので上の
#   StartQueryExecution・GetQueryExecution の回数には含めない。
#
#   [その他]
#   FAILED になった項目ごとに、結果ファイル本体と `<OutputLocation>.metadata` の取得
#   （aws s3 cp、それぞれ 1 回）を追加で呼ぶ（最大で T・U・V・W・X・Y 群の項目数 × 2 回）。
#   Athena の API ではないので上の StartQueryExecution・GetQueryExecution の回数には含めない。
#
# == ROUND=14（Z 群のみ。issue #266 の補足。preflight・DB 確認は共通） ==
#
#   [StartQueryExecution]
#   preflight（SELECT 1 + SHOW TABLES）2
#   + 常に投げる z0・z0b・z0c の 3
#   + 連携カタログ（FEDERATED_CATALOG か、CREATE_GLUE_CATALOG=1 で作れた Glue のデータ
#     カタログ）が使えるときだけの z1〜z5 の 5
#   + S3TABLES_* が揃うときだけの z6〜z17 の 12
#   = 5（S3TABLES_* も連携カタログも無し）／17（S3TABLES_* のみ）／10（連携カタログのみ）／
#   22（両方あり）。このスクリプトの実測値は $START_CALL_FILE の行数（summary.txt に出る）。
#   受理された CREATE TABLE ごとに、その場で DROP する後始末が 1 本ずつ増える
#   （最大 +3 z0 系、+5 z1〜z5、+12 z6〜z17 ＝ 最大 +20）。CREATE_GLUE_CATALOG=1 で作った
#   Glue のデータカタログを指す z1・z2・z4・z5 は、後始末の DROP が失敗すると既定の Context でも
#   もう一度 DROP を試みる（最大 +4。上の内訳には含めない。z3 は最初から既定の Context で
#   消すのでフォールバックは無い）。
#
#   [GetQueryExecution]
#   開始できた項目だけ終端状態までポーリングし、終端後にもう 1 回まとめて取得する。
#
#   [Athena データカタログ管理 API]
#   ROUND=13 と同じ（CREATE_GLUE_CATALOG=1 かつ FEDERATED_CATALOG 未設定のときだけ、
#   sts:GetCallerIdentity・athena:ListDataCatalogs・athena:CreateDataCatalog・GetDataCatalog・
#   DeleteDataCatalog を呼ぶ。ラベルの接頭辞が "z-" になるだけ）。Athena のクエリではないので
#   上の StartQueryExecution・GetQueryExecution の回数には含めない。
#
#   [その他]
#   FAILED になった項目ごとに、結果ファイル本体と `<OutputLocation>.metadata` の取得
#   （aws s3 cp、それぞれ 1 回）を追加で呼ぶ（最大で Z 群の項目数 × 2 回）。Athena の
#   API ではないので上の StartQueryExecution・GetQueryExecution の回数には含めない。
#
# == ROUND=15（T 群のみ。issue #251 の 2 ラウンド目。preflight・DB 確認は共通、実在する表は作らない） ==
#
#   [StartQueryExecution]
#   preflight（SELECT 1 + SHOW TABLES）2
#   + S3TABLES_* によらず常に投げる t1・t2・t5〜t15 の 13
#   + S3TABLES_* が揃うときだけの t3・t4・t16〜t19 の 6
#   = 21（S3TABLES_* あり）／15（無し）。
#   受理された CREATE TABLE ごとに、その場で DROP する後始末が 1 本ずつ増える
#   （最大 +19（あり）／+13（無し））。t7・t10 は既定の Context で DB があるため、
#   t18 は S3 Tables の Context で既存の名前空間のため受理される見込み。
#
#   [GetQueryExecution]
#   開始できた項目だけ終端状態までポーリングし、終端後にもう 1 回まとめて取得する。
#
#   [その他]
#   FAILED になった項目ごとに、結果ファイル本体と `<OutputLocation>.metadata` の取得
#   （aws s3 cp、それぞれ 1 回）を追加で呼ぶ（最大で T 群の項目数 × 2 回）。CTAS（t1〜t18）で
#   FAILED になった項目は、理由に書かれた location のオーファンデータの確認
#   （aws s3 ls --recursive、1 回）にも使う（最大 t1〜t18 の 18 回）。SUCCEEDED の CTAS
#   （t7・t10・t18、想定外に受理された項目を含む）は `.metadata` の取得（aws s3 cp、1 回）を
#   追加で呼ぶ。どれも Athena の API ではないので上の StartQueryExecution・GetQueryExecution
#   の回数には含めない。
#
# == ROUND=16（cl・pr・pn・pa・tp 群のみ。issue #270。preflight・DB 確認は共通） ==
#
#   [StartQueryExecution]
#   preflight（SELECT 1 + SHOW TABLES）2
#   + S3TABLES_* が揃うときだけ、常に投げる cl 群 2・pr 群 10・pn 群 6・pa 群 6・tp 群 7 の計 31
#   = 33（S3TABLES_* あり）／2（無し）。このスクリプトの実測値は $START_CALL_FILE の行数
#   （summary.txt に出る）。受理された CREATE TABLE ごとに、その場で SHOW CREATE TABLE 1 本・
#   DROP する後始末が 1 本ずつ増える（それぞれ最大 +31）。
#
#   [GetQueryExecution]
#   開始できた項目だけ終端状態までポーリングし、終端後にもう 1 回まとめて取得する。
#
#   [その他]
#   FAILED になった項目（CREATE TABLE・SHOW CREATE TABLE のどちらでも）ごとに、結果ファイル
#   本体と `<OutputLocation>.metadata` の取得（aws s3 cp、それぞれ 1 回）を追加で呼ぶ（最大で
#   cl・pr・pn・pa・tp 群と SHOW CREATE TABLE の項目数の合計 × 2 回）。受理された項目の
#   SHOW CREATE TABLE の結果ファイル本体の取得（aws s3 cp、1 回）も同様。Athena の API では
#   ないので上の StartQueryExecution・GetQueryExecution の回数には含めない。
#
# == ROUND=17（q 群のみ。issue #271。preflight・DB 確認は共通） ==
#
#   [StartQueryExecution]
#   preflight（SELECT 1 + SHOW TABLES）2
#   + 準備（<PROBE>_db2・<PROBE>_qdup）2 + 後始末（同じ 2 つを消す）2
#   + 常に投げる q4・q5・q0・q6〜q11b・q12・q12b の 16（create + cleanup で 32）
#   + 常に投げるが DB が無く FAILED になる見込みの q13・q13b（2。cleanup は投げない）
#   + <DB2> が作れたときだけの q1・q2・q3・q5b（4、create + cleanup で 8）
#   + q14・q16・q18・q18b・q19・q19b・q20・q21 の 8（<PROBE>_qdup・<DB2> が作れなければ該当項目だけ
#     未測定。q16b は常に投げる）+ q17（CREATE DATABASE。受理されれば cleanup も 1）
#   + S3TABLES_* が揃うときだけの q22・q23（2、create + cleanup で 4）
#   + 連携カタログ（FEDERATED_CATALOG か CREATE_GLUE_CATALOG=1）が使え、<DB2> も作れたときだけの
#     q24・q25（2、create + cleanup で 4）
#   = 51（S3TABLES_* も連携カタログも無し）／55（どちらか一方）／59（両方あり）。
#   これは <PROBE>_db2・<PROBE>_qdup がどちらも作れ、q17 も受理され、q13・q13b が見込みどおり
#   FAILED になった場合の見込み本数で、<PROBE>_db2・<PROBE>_qdup のどちらかが作れなければ使う
#   項目の分だけ少なくなり、q13・q13b が想定に反して受理されれば cleanup の分だけ多くなる
#   （未測定の項目は StartQueryExecution を呼ばない）。このスクリプトの実測値は
#   $START_CALL_FILE の行数（summary.txt に出る）。
#   CREATE_GLUE_CATALOG=1 で作った Glue のデータカタログを指す q24・q25 は、後始末の DROP が
#   失敗すると既定の Context でももう一度 DROP を試みる（最大 +2。上の内訳には含めない）。
#
#   [GetQueryExecution]
#   開始できた項目だけ終端状態までポーリングし、終端後にもう 1 回まとめて取得する。
#
#   [Athena データカタログ管理 API]
#   ROUND=13・14 と同じ（CREATE_GLUE_CATALOG=1 かつ FEDERATED_CATALOG 未設定のときだけ、
#   sts:GetCallerIdentity・athena:ListDataCatalogs・athena:CreateDataCatalog・GetDataCatalog・
#   DeleteDataCatalog を呼ぶ。ラベルの接頭辞が "q-" になるだけ）。Athena のクエリではないので
#   上の StartQueryExecution・GetQueryExecution の回数には含めない。
#
#   [その他]
#   FAILED になった項目ごとに、結果ファイル本体と `<OutputLocation>.metadata` の取得
#   （aws s3 cp、それぞれ 1 回）を追加で呼ぶ（最大で q 群の項目数 × 2 回）。Athena の
#   API ではないので上の StartQueryExecution・GetQueryExecution の回数には含めない。
#
# == ROUND=18（p・w 群と c1y・i 群のみ。issue #272。preflight・DB 確認は共通） ==
#
#   [StartQueryExecution]
#   preflight（SELECT 1 + SHOW TABLES）2
#   + 実在する表 <PROBE>_src の準備 1
#   + 常に投げる p1・p1y・p5・p5y・p6・p6y・p7・p7y・p8・p8y・p9・p9y・p10・p10y・p11・p11y・p12・p12y・
#     p13y・p14y・p15y の 21 + w1・w1y・w2・w2y の 4（合計 25。<PROBE>_src の有無によらず投げる）
#   + <PROBE>_src が作れたときだけの後始末 1 と、p2・p2y・p3・p3y・p4・p4y・w3・w3y の 8（create のみ。
#     想定どおり FAILED になる見込み）+ c1y の 1（SUCCEEDED の見込み。create + cleanup で 2）+
#     i1・i2 の 2
#   = 28（<PROBE>_src が作れなかったとき）／41（作れたとき）。このスクリプトの実測値は
#   $START_CALL_FILE の行数（summary.txt に出る）。受理された CREATE TABLE ごとに、その場で DROP
#   する後始末が 1 本ずつ増える（p・w 群の 33 項目は最大 +33。想定どおりならすべて FAILED なので
#   増えない）。
#
#   [GetQueryExecution]
#   開始できた項目だけ終端状態までポーリングし、終端後にもう 1 回まとめて取得する。
#
#   [その他]
#   FAILED になった CTAS（p・w 群・c1y）ごとに、結果ファイル本体と `<OutputLocation>.metadata` の
#   取得（aws s3 cp、それぞれ 1 回）と、理由に書かれた location のオーファンデータ確認（aws s3 ls
#   --recursive、1 回。ROUND=11 と共有する check_ctas_orphan_data）を追加で呼ぶ（最大で p・w 群・
#   c1y の項目数 × 3 回。i1・i2 が FAILED になったときは結果ファイル本体と .metadata の取得だけ）。
#   Athena の API ではないので上の StartQueryExecution・GetQueryExecution の回数には含めない。
#
# == ROUND=19（d・f・c 群のみ。issue #273。preflight・DB 確認は共通） ==
#
#   [StartQueryExecution]
#   preflight（SELECT 1 + SHOW TABLES）2 + 準備（<PROBE>_src の作成・削除）2
#   + S3TABLES_* が揃うときだけ、常に投げる d0〜d4 の 5・f1〜f12 の 12・c1・c2 の 2（計 19）
#   = 23（S3TABLES_* あり）／4（無し）。d3・c1 は既存の名前空間を指すため受理される見込みで、
#   その場で DROP する後始末が 1 本ずつ増える（+2。d1・d2・d4 が想定に反して受理されれば
#   同様に +1、その DROP が <S3NODB> で失敗すれば <S3> でのもう一度の DROP でさらに +1）。
#   このスクリプトの実測値は $START_CALL_FILE の行数（summary.txt に出る）。
#
#   [GetQueryExecution]
#   開始できた項目だけ終端状態までポーリングし、終端後にもう 1 回まとめて取得する。
#
#   [その他]
#   FAILED になった CTAS の項目（d2〜d4・f1〜f12・c1）ごとに、結果ファイル本体と
#   `<OutputLocation>.metadata` の取得（aws s3 cp、それぞれ 1 回）と、理由に書かれた
#   location のオーファンデータの確認（aws s3 ls --recursive、1 回）を追加で呼ぶ
#   （最大でその項目数 × 3 回）。Athena の API ではないので上の StartQueryExecution・
#   GetQueryExecution の回数には含めない。
#
# == ROUND=22（P 群のみ。issue #279。preflight・DB 確認は共通） ==
#
#   [StartQueryExecution]
#   preflight（SELECT 1 + SHOW TABLES）2
#   + 準備（<PROBE>_p_real・<PROBE>_p_ice・INSERT・<PROBE>_p_view）4
#   + 各群の対照 p0・p0b の 2
#   + <DEF> の p5〜p16 の 15（DELETE・UPDATE・MERGE とその対照・SHOW CREATE VIEW・
#     DROP VIEW（IF EXISTS・無し）・ALTER TABLE RENAME の 3 形・SHOW COLUMNS/TBLPROPERTIES/PARTITIONS）
#   + <NOCAT>（nosuchcatalog279）の p18・p20・p22・p25・p26 の 5
#   + <DEF> の p27・p28（INSERT の引用符付きの部品）・p29〜p32（SELECT）の 6
#   + 後始末（<PROBE>_p_ice・<PROBE>_p_ice2・<PROBE>_p_real・<PROBE>_p_view の DROP）4
#   + 連携カタログ <G>（FEDERATED_CATALOG か CREATE_GLUE_CATALOG=1）が使えるときだけの
#     p1〜p4 の 4
#   + S3TABLES_* が揃うときだけの <S3CTX> の p17・p19・p21・p23・p24 の 5
#   = 38（S3TABLES_* も <G> も無し）／43（S3TABLES_* のみ）／42（<G> のみ）／47（両方あり）。
#   これは ALTER TABLE RENAME（p11〜p13）・CTAS/CREATE VIEW（p19〜p22）・INSERT
#   （p2・p4・p27・p28）がすべて開始時に弾かれるか FAILED になった場合の最小の見込みで、
#   受理された分だけ revert（p11-revert〜p13-revert）・cleanup（p19-cleanup・p20-cleanup・
#   p21-cleanup・p22-cleanup）・件数確認（p2-count・p4-count・p27-count・p28-count）が
#   1 本ずつ増える（最大 +11。未測定の項目は StartQueryExecution を呼ばない）。
#   このスクリプトの実測値は $START_CALL_FILE の行数（summary.txt に出る）。
#
#   [GetQueryExecution]
#   開始できた項目だけ終端状態までポーリングし、終端後にもう 1 回まとめて取得する。
#
#   [Athena データカタログ管理 API]
#   ROUND=13・14・17 と同じ（CREATE_GLUE_CATALOG=1 かつ FEDERATED_CATALOG 未設定のときだけ、
#   sts:GetCallerIdentity・athena:ListDataCatalogs・athena:CreateDataCatalog・GetDataCatalog・
#   DeleteDataCatalog を呼ぶ。ラベルの接頭辞が "p-" になるだけ）。Athena のクエリではないので
#   上の StartQueryExecution・GetQueryExecution の回数には含めない。
#
#   [その他]
#   FAILED になった項目ごとに、結果ファイル本体と `<OutputLocation>.metadata` の取得
#   （aws s3 cp、それぞれ 1 回）を追加で呼ぶ。成功した SELECT（p0・p0b・p1・p3・p23〜p26・
#   p29〜p32）は結果ファイル本体だけを同じ形で取得する。いずれも Athena の API ではないので
#   上の StartQueryExecution・GetQueryExecution の回数には含めない。
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
  1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 | 20 | 22 | 23) ;;
  *)
    echo "ROUND には 1・2・3・4・5・6・7・8・9・10・11・12・13・14・15・16・17・18・19・20・22・23 のどれかを指定してください（既定 1。21 は他の実測ブランチが使用中）" >&2
    exit 1
    ;;
esac
# ROUND=23（issue #279 の 2 ラウンド目）は、ROUND=22 の準備・連携カタログ・後始末をそのまま使い、
# INSERT の項目だけを測り直す（ROUND=22 は CTAS で作った表の s が varchar(1) で、2 文字の値の
# INSERT が INVALID_CAST_ARGUMENT で落ち、行が入るかを測れなかった）。以降は ROUND=22 として走る。
P_INSERT_ONLY=0
if [ "$ROUND" = 23 ]; then
  ROUND=22
  P_INSERT_ONLY=1
fi
CATALOG=${CATALOG:-AwsDataCatalog}
REGION=${REGION:-ap-northeast-1}
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_DIR=${OUT_DIR:-${DEV_HOST_HOME:-$HOME}/athena-unquoted-ddl-measurements}
POLL_TIMEOUT=${POLL_TIMEOUT:-180}
RETRY_MAX=${RETRY_MAX:-4}
RETRY_DELAY=${RETRY_DELAY:-5}
S3TABLES_CATALOG=${S3TABLES_CATALOG:-}
S3TABLES_NS=${S3TABLES_NS:-}
# 連携カタログ（S3 Tables 以外）の名前。ROUND=10 の s14（issue #248）と ROUND=12 の
# o3・o4・o9（issue #260）、ROUND=13 の x1〜x4（issue #266）が使う。
FEDERATED_CATALOG=${FEDERATED_CATALOG:-}
# 連携カタログの中の実在する DB・表名。ROUND=12 の o9 だけが使う。
FEDERATED_DB=${FEDERATED_DB:-}
FEDERATED_TABLE=${FEDERATED_TABLE:-}
# ROUND=13・14 だけで使う。1 のとき、FEDERATED_CATALOG が未設定なら自分のアカウントの Glue を
# 指すデータカタログを作って X 群・Z 群の連携カタログ代わりに使う（issue #266）。
CREATE_GLUE_CATALOG=${CREATE_GLUE_CATALOG:-}
# CREATE_GLUE_CATALOG=1 で作れたデータカタログの名前。空なら「作っていない」か「もう消した」。
# trap の cleanup が、消し残しがあればベストエフォートで削除する対象を判定する
# （明示的な削除に成功したら空に戻す）。
GLUE_CATALOG_NAME=""
# 上と違い、一度作れたら削除できたあとも空にしない（hide_pairs で伏せるためだけの変数。
# summary は削除の結果によらず実名を出さない）。
GLUE_CATALOG_CREATED_NAME=""
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
    # ROUND=8 のビュー（<PROBE>_mv・<PROBE>_m36）と ROUND=22 のビュー（<PROBE>_p_view・
    # <PROBE>_p21・<PROBE>_p22）は DROP VIEW で消す（#242・#279）。
    case "${key##*|}" in
      "${PROBE_PREFIX}_mv" | "${PROBE_PREFIX}_m36" | "${PROBE_PREFIX}_p_view" | "${PROBE_PREFIX}_p21" | "${PROBE_PREFIX}_p22")
        cleanup_drop_in_ctx "${key%|*}" "DROP VIEW IF EXISTS ${key##*|}" ;;
      *) cleanup_drop_in_ctx "${key%|*}" "DROP TABLE IF EXISTS ${key##*|}" ;;
    esac
  done
  # ROUND=13（issue #266）で CREATE_GLUE_CATALOG=1 により作ったデータカタログが、本編の
  # 明示的な削除で消せていなければ、X 群の表を消したこの後にベストエフォートでもう一度
  # 消しにいく（結果は確かめない。名前解決・接続以外の失敗は本編の summary が既に報告済み）。
  if [ -n "$GLUE_CATALOG_NAME" ]; then
    aws athena delete-data-catalog --region "$REGION" --name "$GLUE_CATALOG_NAME" >/dev/null 2>&1 || true
  fi
  # ROUND=8 で作った別の DB が残っていれば、中の表ごと消す（#242）。
  if [ "${M_DB2_OK:-0}" = 1 ] && ! grep -qs "^State: SUCCEEDED" "$RUN_DIR/m-drop-db2.reason.txt"; then
    cleanup_drop "DROP DATABASE IF EXISTS ${PROBE_PREFIX}_db2 CASCADE"
  fi
  # ROUND=17（issue #271）で作った別の DB <PROBE>_db2 が残っていれば、中の表ごと消す。
  if [ "${Q_DB2_OK:-0}" = 1 ] && ! grep -qs "^State: SUCCEEDED" "$RUN_DIR/q-drop-db2.reason.txt"; then
    cleanup_drop "DROP DATABASE IF EXISTS ${PROBE_PREFIX}_db2 CASCADE"
  fi
  # ROUND=17（issue #271）で q14 用に作った実在する表 <PROBE>_qdup が残っていれば消す。
  if [ "${Q_QDUP_OK:-0}" = 1 ] && ! grep -qs "^State: SUCCEEDED" "$RUN_DIR/q-drop-qdup.reason.txt"; then
    cleanup_drop "DROP TABLE IF EXISTS ${PROBE_PREFIX}_qdup"
  fi
  # ROUND=17（issue #271）の q17 が受理して作った DB <PROBE>_q17db が残っていれば消す。
  if [ "${Q17_DB_OK:-0}" = 1 ] && ! grep -qs "^State: SUCCEEDED" "$RUN_DIR/q17-cleanup.reason.txt"; then
    cleanup_drop "DROP DATABASE IF EXISTS ${PROBE_PREFIX}_q17db CASCADE"
  fi
  # ROUND=18（issue #272）・ROUND=19（issue #273）で作った実在する表 <PROBE>_src が残っていれば消す
  # （本編の後始末のラベルは ROUND=18 が p-drop-src、ROUND=19 が v-cleanup-src）。
  local src_drop_label=p-drop-src
  [ "$ROUND" = 19 ] && src_drop_label=v-cleanup-src
  if [ "${SRC_OK:-0}" = 1 ] && ! grep -qs "^State: SUCCEEDED" "$RUN_DIR/$src_drop_label.reason.txt"; then
    cleanup_drop "DROP TABLE IF EXISTS ${PROBE_PREFIX}_src"
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
$FEDERATED_CATALOG	<FEDERATED_CATALOG>
${FEDERATED_CATALOG^^}	<FEDERATED_CATALOG_UPPER>
$FEDERATED_DB	<FEDERATED_DB>
$FEDERATED_TABLE	<FEDERATED_TABLE>
${DB^^}	<DB_UPPER>
$GLUE_CATALOG_CREATED_NAME	<GLUE_PROBE_CATALOG>
${NOPE_NS_UPPER:-}	<NOPE_NS_UPPER>
${GLUE_CATALOG_CREATED_NAME^^}	<GLUE_PROBE_CATALOG_UPPER>
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

# s3://... の URI をまるごと <S3_URI> に畳む（ROUND=16、issue #270）。SHOW CREATE TABLE が
# 返す LOCATION は S3 Tables の実バケット・テーブル ID を含みうるため、hide（実名の完全一致の
# 置換）では畳めない。空白・引用符の手前までを 1 つの URI とみなす。
mask_s3_uri() {
  printf '%s' "$1" | sed -E "s#s3://[^[:space:]\"']+#<S3_URI>#g"
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

# SHOW CREATE TABLE の結果ファイル本体だけを、成功・失敗によらず取得する（ROUND=16、
# issue #270）。fetch_failed_attachments は FAILED だけを対象にするが、受理された CREATE TABLE の
# あとの SHOW CREATE TABLE は SUCCEEDED の見込みなので、状態によらず取得する（無ければ何もしない）。
# `.metadata` は取らない（見たいのはパーティション・表プロパティの実際の形だけ）。
fetch_showcreate_body() {
  local label=$1 loc
  loc=$(output_location_of "$label")
  [ -n "$loc" ] || return 0
  fetch_s3_body "$loc" "$RUN_DIR/$label.output.txt" "$RUN_DIR/$label.output.txt.err"
}

# CTAS が DB 無しで FAILED になったとき、StateChangeReason・AthenaError.ErrorMessage に書かれた
# `location '<uri>'`（j13 の実測どおりの書かれ方）を取り出し、その下に実際にオブジェクトが
# 書かれているかを `aws s3 ls --recursive` で確かめる（読み取りのみ。ROUND=11、issue #251 の
# コメントの項目 4）。結果は <label>.orphan-data.txt に保存する。location が見つからなければ
# その旨を書いて終わる。
check_ctas_orphan_data() {
  local label=$1 uri
  uri=$(python3 - "$RUN_DIR/$label.execution.json" <<'PYEOF'
import json, re, sys
try:
    status = json.load(open(sys.argv[1]))["QueryExecution"]["Status"]
except Exception:
    print("")
    sys.exit(0)
text = status.get("StateChangeReason") or ""
err = status.get("AthenaError") or {}
text += " " + (err.get("ErrorMessage") or "")
m = re.search(r"location '([^']+)'", text)
print(m.group(1) if m else "")
PYEOF
)
  if [ -z "$uri" ]; then
    echo "(理由に location が見つかりませんでした)" > "$RUN_DIR/$label.orphan-data.txt"
    return
  fi
  if ! aws s3 ls --recursive "$uri" --region "$REGION" > "$RUN_DIR/$label.orphan-data.txt" 2> "$RUN_DIR/$label.orphan-data.err"; then
    : # ls が失敗しても（オブジェクトが無いなど）orphan-data.txt はそのまま残す（空か途中まで）
  else
    rm -f "$RUN_DIR/$label.orphan-data.err"
  fi
}

# StateChangeReason 全文（<label>.reason.txt）から最初の `line L:C` を抜き出す（ROUND=18、
# issue #272。本物が CTAS/INSERT を組み直して実行するときのエラー位置を読むため）。タブ区切りで
# "L\tC" を返す（読めない・見つからなければ "-\t-"）。
reason_line_col() {
  local f="$RUN_DIR/$1.reason.txt"
  if [ ! -s "$f" ]; then
    printf -- '-\t-'
    return
  fi
  python3 -c '
import re, sys
try:
    text = open(sys.argv[1], "r", encoding="utf-8", errors="replace").read()
except OSError:
    text = ""
m = re.search(r"line (\d+):(\d+)", text)
if m:
    print("%s\t%s" % (m.group(1), m.group(2)))
else:
    print("-\t-")
' "$f"
}

# <label>.sql（run が保存した、マスク前の実際の文。末尾に足された改行だけ取り除く）の中で
# needle が最初に始まる 1 始まりの行・桁をタブ区切りで返す（ROUND=18、issue #272。無い表名・
# 列名・型不一致のリテラルなど、エラーの対象の語の実際の位置を、本物が返した line L:C と
# 突き合わせて組み直しの規則を読むため）。見つからない・読めなければ "-\t-"。
sql_position_of() {
  local label=$1 needle=$2
  python3 - "$RUN_DIR/$label.sql" "$needle" <<'PYEOF'
import sys
try:
    sql = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
except OSError:
    print("-\t-")
    sys.exit(0)
if sql.endswith("\n"):
    sql = sql[:-1]
needle = sys.argv[2]
idx = sql.find(needle)
if idx == -1:
    print("-\t-")
else:
    prefix = sql[:idx]
    line = prefix.count("\n") + 1
    col = idx - prefix.rfind("\n")
    print("%d\t%d" % (line, col))
PYEOF
}

# Athena のクエリではない AWS CLI 呼び出し（ROUND=13、issue #266 の create/delete-data-catalog・
# sts:GetCallerIdentity・list-data-catalogs・get-data-catalog）を、start_query_retry と同じ
# 考え方で名前解決・接続などの一時的な失敗だけ再試行する。標準出力は $2 に、標準エラーは
# $RUN_DIR/$1.err に保存し、試行回数を $RUN_DIR/.tmp-attempts-$1 に記録する（read_attempts で読める）。
# $1: ラベル、$2: 標準出力の保存先、$3 以降: 実行するコマンド。
aws_call_retry() {
  local label=$1 outfile=$2
  shift 2
  local attempt=1
  while :; do
    if "$@" > "$outfile" 2> "$RUN_DIR/$label.err"; then
      echo "$attempt" > "$RUN_DIR/.tmp-attempts-$label"
      return 0
    fi
    if [ "$attempt" -ge "$RETRY_MAX" ] || ! is_transient_error "$RUN_DIR/$label.err"; then
      echo "$attempt" > "$RUN_DIR/.tmp-attempts-$label"
      return 1
    fi
    echo "== $label: 一時的な失敗とみて ${RETRY_DELAY} 秒後に再試行します（試行 $attempt/$RETRY_MAX）" >&2
    sleep "$RETRY_DELAY"
    attempt=$((attempt + 1))
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

# run_create_then_drop_ctx に SHOW CREATE TABLE の 1 段を挟んだ版（ROUND=16、issue #270）。
# CREATE TABLE が受理されたら、DROP の前に同じ Context で SHOW CREATE TABLE <name> を
# <label>-showcreate として投げ、結果ファイル本体を取得する（パーティション・表プロパティの
# 実際の形をあとで確かめるため。SHOW CREATE TABLE が失敗しても後始末の DROP は続ける）。
# 作る Context と消す Context は常に同じ（このラウンドは S3 Tables の Context だけを使う）。
run_create_then_drop_ctx_showcreate() {
  local ctx=$1 label=$2 sql=$3 name=$4
  local key="$ctx|$name"
  if run_in_ctx "$ctx" "$label" "$sql"; then
    PENDING_DROPS_CTX[$key]=1
    run_in_ctx "$ctx" "$label-showcreate" "SHOW CREATE TABLE $name"
    fetch_showcreate_body "$label-showcreate"
    run_in_ctx "$ctx" "$label-cleanup" "DROP TABLE IF EXISTS $name"
    if succeeded "$label-cleanup"; then
      unset 'PENDING_DROPS_CTX[$key]'
    fi
  else
    skip "$label-showcreate" "CREATE TABLE が失敗したため SHOW CREATE TABLE 不要"
    skip "$label-cleanup" "CREATE TABLE が失敗したため後始末不要"
  fi
}

# $create_ctx で CREATE TABLE を投げ、受理されたら Catalog=$FC,Database=$drop_db の Context で
# DROP TABLE IF EXISTS <name> を <label>-cleanup として投げて消す（run_create_then_drop_ctx を
# 呼ぶだけ）。$FC が CREATE_GLUE_CATALOG=1 で作ったデータカタログ（$GLUE_CATALOG_NAME と一致）の
# ときは、その DROP が SUCCEEDED にならなければ、既定の Context（$DEFAULT_CTX）でも同じ DROP を
# <label>-cleanup2 としてもう一度投げる（同じ Glue を指すため）。drop_db は呼び出し元が渡す
# （ROUND=13 の X 群は連携カタログ側の DB、ROUND=14 の Z 群は athena-local の DB。文の qualified
# name の 2 部目に合わせる）。$FC・$GLUE_CATALOG_NAME・$DEFAULT_CTX はグローバルを読む
# （呼び出し前に呼び出し元が設定しておく。ROUND=13・14 で共有、issue #266）。
run_x_create() {
  local create_ctx=$1 drop_db=$2 label=$3 sql=$4 name=$5
  local drop_ctx="Catalog=$FC,Database=$drop_db"
  local key="$drop_ctx|$name"
  run_create_then_drop_ctx "$create_ctx" "$drop_ctx" "$label" "$sql" "$name"
  if [ -n "$GLUE_CATALOG_NAME" ] && [ "$FC" = "$GLUE_CATALOG_NAME" ] \
    && [ -n "${PENDING_DROPS_CTX[$key]:-}" ]; then
    run_in_ctx "$DEFAULT_CTX" "$label-cleanup2" "DROP TABLE IF EXISTS $name"
    if succeeded "$label-cleanup2"; then
      unset 'PENDING_DROPS_CTX[$key]'
    fi
  fi
}

# 連携カタログを決める（ROUND=13 の X 群・ROUND=14 の Z 群で共有、issue #266）。
# FEDERATED_CATALOG があればそれを使う（作らない・消さない）。無く、CREATE_GLUE_CATALOG=1 の
# ときだけ、sts:GetCallerIdentity・athena:ListDataCatalogs の疎通が通ることを確かめてから、
# 自分のアカウントの Glue を指すデータカタログを作って使う。結果はグローバル FC・FDB・
# GLUE_CATALOG_NAME・GLUE_CATALOG_CREATED_NAME・FEDCAT_SKIP_REASON に積む（呼び出しのたびに
# 初期化する）。$1: ラベルの接頭辞（呼び出し元の group 名。ファイル名の衝突を避ける。
# ROUND=13 は "x"、ROUND=14 は "z"）。
resolve_federated_catalog() {
  local prefix=$1
  FC=""
  FDB=""
  FEDCAT_SKIP_REASON=""
  GLUE_CATALOG_DELETED=""
  if [ -n "$FEDERATED_CATALOG" ]; then
    FC="$FEDERATED_CATALOG"
    FDB="${FEDERATED_DB:-$DB}"
  elif [ "${CREATE_GLUE_CATALOG:-}" = 1 ]; then
    if aws_call_retry "$prefix-sts-preflight" "$RUN_DIR/.tmp-sts.json" \
        aws sts get-caller-identity --region "$REGION" --output json \
      && aws_call_retry "$prefix-list-catalogs-preflight" "$RUN_DIR/.tmp-list-catalogs.json" \
        aws athena list-data-catalogs --region "$REGION"; then
      ACCOUNT_ID=$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("Account", ""))
except Exception:
    print("")' "$RUN_DIR/.tmp-sts.json" 2>/dev/null)
      if [ -n "$ACCOUNT_ID" ]; then
        GLUE_CATALOG_NAME="athena_local_probe_266_${RAND_SUFFIX}cat"
        GLUE_CATALOG_CREATED_NAME="$GLUE_CATALOG_NAME"
        if aws_call_retry "$prefix-create-catalog" "$RUN_DIR/$prefix-create-catalog.json" \
          aws athena create-data-catalog --region "$REGION" --name "$GLUE_CATALOG_NAME" \
          --type GLUE --parameters "catalog-id=$ACCOUNT_ID"; then
          FC="$GLUE_CATALOG_NAME"
          FDB="$DB"
          aws_call_retry "$prefix-get-catalog" "$RUN_DIR/$prefix-get-catalog.json" \
            aws athena get-data-catalog --region "$REGION" --name "$GLUE_CATALOG_NAME" || true
        else
          FEDCAT_SKIP_REASON="未測定（データカタログを作れませんでした: $(first_err_line "$RUN_DIR/$prefix-create-catalog.err")）"
          GLUE_CATALOG_NAME=""
        fi
      else
        FEDCAT_SKIP_REASON="未測定（アカウント ID を取得できませんでした）"
      fi
    else
      FEDCAT_SKIP_REASON="未測定（CREATE_GLUE_CATALOG の疎通確認に失敗しました）"
    fi
  else
    FEDCAT_SKIP_REASON="未測定（FEDERATED_CATALOG 未設定・CREATE_GLUE_CATALOG 未指定）"
  fi
}

# CREATE_GLUE_CATALOG=1 で作ったデータカタログ（$GLUE_CATALOG_NAME）が残っていれば、明示的に
# 削除する（ROUND=13 の X 群・ROUND=14 の Z 群で共有）。結果を $GLUE_CATALOG_DELETED に積み
# （1: 消せた、0: 消せなかった）、消せたら $GLUE_CATALOG_NAME を空に戻す（trap のベストエフォート
# 削除の対象から外す）。$1: ラベルの接頭辞（resolve_federated_catalog と同じものを渡す）。
delete_glue_catalog_if_created() {
  local prefix=$1
  if [ -n "$GLUE_CATALOG_NAME" ]; then
    if aws_call_retry "$prefix-delete-catalog" "$RUN_DIR/$prefix-delete-catalog.json" \
      aws athena delete-data-catalog --region "$REGION" --name "$GLUE_CATALOG_NAME"; then
      GLUE_CATALOG_DELETED=1
      GLUE_CATALOG_NAME=""
    else
      GLUE_CATALOG_DELETED=0
    fi
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

# ROUND=10 だけ、S 群を投げる（issue #248）。
if [ "$ROUND" = 10 ]; then

DEFAULT_CTX="Catalog=$CATALOG,Database=$DB"
# バッククォート 1 文字（s11。ダブルクォートと違い、二重引用符で囲むと bash のコマンド置換に
# なってしまうので変数にして埋め込む）。
BT='`'
# LOCATION 付きの項目の置き場（n 群の probe_location と同じ形。空のプレフィックス）。
probe_location_s() { printf '%sathena-local-probe-248/%s/' "$OUTPUT" "$(new_name "$1")"; }

# --- S 群（QueryExecutionContext の Catalog が S3 Tables の Hive の CREATE TABLE の残り） --------
# #229 で測っていない句（s1〜s6）、LOCATION の無い EXTERNAL の各形（s7〜s10）、バッククォートの
# 名前（s11）、n6（実在しないカタログ + LOCATION）の対照（s12・s13・s14）、n21（STORED AS PARQUET・
# LOCATION 無し）の対照（s15・s16）、#249 の独立レビューで挙がった入れ子の型（s17・s18）。
if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  S3T_CTX="Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS"

  # s1〜s6: #229 で測っていない句。列の並びは Hive のデリミタ系の句が要る型にする。
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" s1 \
    "CREATE TABLE $(new_name s1) (n int) COMMENT 't comment' LOCATION '$(probe_location_s s1)'" "$(new_name s1)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" s2 \
    "CREATE TABLE $(new_name s2) (n int) CLUSTERED BY (n) INTO 4 BUCKETS LOCATION '$(probe_location_s s2)'" "$(new_name s2)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" s3 \
    "CREATE TABLE $(new_name s3) (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde' LOCATION '$(probe_location_s s3)'" "$(new_name s3)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" s4 \
    "CREATE TABLE $(new_name s4) (n int) ROW FORMAT DELIMITED FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n' LOCATION '$(probe_location_s s4)'" "$(new_name s4)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" s5 \
    "CREATE TABLE $(new_name s5) (n map<string,string>) ROW FORMAT DELIMITED COLLECTION ITEMS TERMINATED BY ',' MAP KEYS TERMINATED BY ':' NULL DEFINED AS 'N' LOCATION '$(probe_location_s s5)'" "$(new_name s5)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" s6 \
    "CREATE TABLE $(new_name s6) (n int) LOCATION '$(probe_location_s s6)' TBLPROPERTIES ('a248'='b', 'c248'='d')" "$(new_name s6)"

  # s7〜s10: LOCATION の無い EXTERNAL（n11 は 1 部の無引用の名前だけ測った）。
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" s7 \
    "CREATE EXTERNAL TABLE $S3TABLES_NS.$(new_name s7) (n int)" "$(new_name s7)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" s8 \
    "CREATE EXTERNAL TABLE AwsDataCatalog.$DB.$(new_name s8) (n int)" "$(new_name s8)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" s9 \
    "CREATE EXTERNAL TABLE $(new_name s9) (n int) STORED AS PARQUET" "$(new_name s9)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" s10 \
    "CREATE EXTERNAL TABLE $(new_name s10) (n int) TBLPROPERTIES ('a248'='b')" "$(new_name s10)"

  # s11: バッククォートの名前（Hive は引用符でなくバッククォートで名前を囲む）。
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" s11 \
    "CREATE TABLE ${BT}$(new_name s11)${BT} (n int) LOCATION '$(probe_location_s s11)'" "$(new_name s11)"

  # s13: n6 と同じ形で、1 部目を Trino にだけあるような綴り（TRINO_CATALOG_MAP の別名候補）にする。
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" s13 \
    "CREATE TABLE hive248.$DB.$(new_name s13) (n int) LOCATION '$(probe_location_s s13)'" "$(new_name s13)"

  # s15・s16: n21（STORED AS PARQUET、LOCATION 無し）の対照。
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" s15 \
    "CREATE TABLE $(new_name s15) (n int) STORED AS ORC" "$(new_name s15)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" s16 \
    "CREATE TABLE $(new_name s16) (n int) STORED AS PARQUET LOCATION '$(probe_location_s s16)'" "$(new_name s16)"

  # s17・s18: #249 の独立レビュー（low）で挙がった入れ子の型の列。
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" s17 \
    "CREATE TABLE $(new_name s17) (c row(a int)) LOCATION '$(probe_location_s s17)'" "$(new_name s17)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" s18 \
    "CREATE TABLE $(new_name s18) (c array(row(a int))) LOCATION '$(probe_location_s s18)'" "$(new_name s18)"

  # s14: n6 の対照（実在するカタログ名での同じ形）。連携カタログが設定されていれば測る。
  if [ -n "$FEDERATED_CATALOG" ]; then
    run_create_then_drop_ctx "$S3T_CTX" "Catalog=$FEDERATED_CATALOG" s14 \
      "CREATE TABLE $FEDERATED_CATALOG.$DB.$(new_name s14) (n int) LOCATION '$(probe_location_s s14)'" "$(new_name s14)"
  else
    skip s14 "未測定（FEDERATED_CATALOG 未設定）"
    skip s14-cleanup "CREATE TABLE を投げていないため後始末不要"
  fi
else
  for l in s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 s13 s14 s15 s16 s17 s18; do
    skip "$l" "未測定（S3TABLES_* 未設定）"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

# s12: n6 の対照（Hive の Context。既定の Context で同じ形が同じ DATACATALOG_NOT_FOUND になるか）。
# S3TABLES_* によらず常に投げる。
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" s12 \
  "CREATE TABLE nosuchcatalog248.$DB.$(new_name s12) (n int) LOCATION '$(probe_location_s s12)'" "$(new_name s12)"

S_LABELS="s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 s12 s13 s14 s15 s16 s17 s18"

# --- 付随物の取得（FAILED になった項目だけ） --------------------------------------------
fetch_failed_attachments $S_LABELS

fi # ROUND=10

# ROUND=11 だけ、R 群を投げる（issue #251）。
if [ "$ROUND" = 11 ]; then

DEFAULT_CTX="Catalog=$CATALOG,Database=$DB"
# S3 Tables に無い名前空間（乱数入りの接頭辞なので実在しない見込み）。
R_NOPE_NS="$(new_name r_nope_ns)"

# --- R 群（S3 Tables の Context の場所の無い CREATE TABLE の名前空間まわり） ----------------
# issue 本文の 1〜3（r1〜r3）と、コメントの 4〜8（CTAS の残り。r4〜r8c）。
if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  S3T_CTX="Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS"

  # r1: 1 部の名前で、Context の Database が S3 Tables に無い名前空間のとき（issue 本文の 1）。
  run_create_then_drop_ctx "Catalog=$S3TABLES_CATALOG,Database=$R_NOPE_NS" "Catalog=$S3TABLES_CATALOG,Database=$R_NOPE_NS" r1 \
    "CREATE TABLE $(new_name r1) (n int)" "$(new_name r1)"
  # r2: 2 部の IF NOT EXISTS で、1 部目（名前空間）が無いとき（issue 本文の 2。j12 は IF NOT EXISTS 無し）。
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" r2 \
    "CREATE TABLE IF NOT EXISTS $R_NOPE_NS.$(new_name r2) (n int)" "$(new_name r2)"
  # r3: 3 部の IF NOT EXISTS で、名前空間があるとき（issue 本文の 3。j1 は IF NOT EXISTS 無し、j9 は無い名前空間）。
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" r3 \
    "CREATE TABLE IF NOT EXISTS AwsDataCatalog.$S3TABLES_NS.$(new_name r3) (n int)" "$(new_name r3)"

  # r4: j13 の再現（CTAS、DB 無し）。.metadata の中身と書かれたデータの有無を確かめる（コメントの項目 4）。
  R4_DB="$(new_name r4db)"
  run_create_then_drop_ctx "$S3T_CTX" "Catalog=$CATALOG,Database=$R4_DB" r4 \
    "CREATE TABLE AwsDataCatalog.$R4_DB.$(new_name r4) AS SELECT 1 AS n" "$(new_name r4)"
  # r5: j13 と同じ形で、DB 名を大文字混じりにする（理由の Database <名前> が書いたとおりか小文字か。項目 5）。
  R5_DB="$(new_name R5Mixed)"
  run_create_then_drop_ctx "$S3T_CTX" "Catalog=$CATALOG,Database=$R5_DB" r5 \
    "CREATE TABLE AwsDataCatalog.$R5_DB.$(new_name r5) AS SELECT 1 AS n" "$(new_name r5)"
  # r6a/r6b: IF NOT EXISTS + 小文字 awsdatacatalog の CTAS（DB がある・無い。項目 6）。
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" r6a \
    "CREATE TABLE IF NOT EXISTS awsdatacatalog.$DB.$(new_name r6a) AS SELECT 1 AS n" "$(new_name r6a)"
  R6B_DB="$(new_name r6bdb)"
  run_create_then_drop_ctx "$S3T_CTX" "Catalog=$CATALOG,Database=$R6B_DB" r6b \
    "CREATE TABLE IF NOT EXISTS awsdatacatalog.$R6B_DB.$(new_name r6b) AS SELECT 1 AS n" "$(new_name r6b)"
  # r7a/r7b: 1 部目の綴りと DB の有無の残りの組（項目 7）。
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" r7a \
    "CREATE TABLE AwsDataCatalog.$DB.$(new_name r7a) AS SELECT 1 AS n" "$(new_name r7a)"
  R7B_DB="$(new_name r7bdb)"
  run_create_then_drop_ctx "$S3T_CTX" "Catalog=$CATALOG,Database=$R7B_DB" r7b \
    "CREATE TABLE awsdatacatalog.$R7B_DB.$(new_name r7b) AS SELECT 1 AS n" "$(new_name r7b)"
else
  for l in r1 r2 r3 r4 r5 r6a r6b r7a r7b; do
    skip "$l" "未測定（S3TABLES_* 未設定）"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

# r8a〜r8c: 既定の Context（Catalog=AwsDataCatalog）で r5・r7a・r7b と同じ形（項目 8。S3TABLES_* によらず常に投げる）。
R8A_DB="$(new_name R8AMixed)"
run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$R8A_DB" r8a \
  "CREATE TABLE AwsDataCatalog.$R8A_DB.$(new_name r8a) AS SELECT 1 AS n" "$(new_name r8a)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" r8b \
  "CREATE TABLE AwsDataCatalog.$DB.$(new_name r8b) AS SELECT 1 AS n" "$(new_name r8b)"
R8C_DB="$(new_name r8cdb)"
run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$R8C_DB" r8c \
  "CREATE TABLE awsdatacatalog.$R8C_DB.$(new_name r8c) AS SELECT 1 AS n" "$(new_name r8c)"

R_LABELS="r1 r2 r3 r4 r5 r6a r6b r7a r7b r8a r8b r8c"

# --- 付随物の取得（FAILED になった項目だけ） --------------------------------------------
fetch_failed_attachments $R_LABELS
for l in r4 r5 r6a r6b r7a r7b r8a r8b r8c; do
  is_failed "$l" && check_ctas_orphan_data "$l"
done

fi # ROUND=11

# ROUND=12 だけ、O 群を投げる（issue #260）。
if [ "$ROUND" = 12 ]; then

DEFAULT_CTX="Catalog=$CATALOG,Database=$DB"

# --- O 群（無引用の awsdatacatalog.<db>.<t> の置換（#246）で測っていない周辺） ------------------
# Context が AwsDataCatalog か省略のときの SELECT・INSERT・EXPLAIN などは #242 の m30〜m41 で
# 実測済み（ここには含めない）。実在しないカタログの Context の SELECT も #214 で SUCCEEDED と
# 実測済み（run-20260925-131314）なので投げない。同じ理由の INSERT は未測定なので o5 で測る。
O_TABLE="$(new_name o)"
PENDING_DROPS[$O_TABLE]=1
run_in_ctx "$DEFAULT_CTX" o-setup "CREATE TABLE $DB.$O_TABLE AS SELECT 1 AS n, 'x' AS s"

if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  S3T_CTX="Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS"
  run_in_ctx "$S3T_CTX" o0 "SELECT 1"
  # S3 Tables の Context で AwsDataCatalog 側の表を無引用の 3 部で読み書きできるか
  # （CREATE TABLE は #227 の j2 などで FAILED、SELECT・INSERT は未測定）。
  run_in_ctx "$S3T_CTX" o1 "SELECT * FROM awsdatacatalog.$DB.$O_TABLE"
  run_in_ctx "$S3T_CTX" o2 "INSERT INTO awsdatacatalog.$DB.$O_TABLE VALUES (2, 'y')"
else
  skip o0 "未測定（S3TABLES_* 未設定）"
  skip o1 "未測定（S3TABLES_* 未設定）"
  skip o2 "未測定（S3TABLES_* 未設定）"
fi

if [ -n "$FEDERATED_CATALOG" ]; then
  # 連携カタログの Context でも同じ無引用の awsdatacatalog. が Glue 側を指すか。
  run_in_ctx "Catalog=$FEDERATED_CATALOG" o3 "SELECT * FROM awsdatacatalog.$DB.$O_TABLE"
  run_in_ctx "Catalog=$FEDERATED_CATALOG" o4 "INSERT INTO awsdatacatalog.$DB.$O_TABLE VALUES (2, 'y')"
else
  skip o3 "未測定（FEDERATED_CATALOG 未設定）"
  skip o4 "未測定（FEDERATED_CATALOG 未設定）"
fi

# 実在しないカタログの Context の SELECT は #214 で SUCCEEDED と実測済み（同じ理由で投げない）。
# INSERT は #214 でも測っていないのでここで測る。
run_in_ctx "Catalog=nosuchcatalog260,Database=$DB" o5 "INSERT INTO awsdatacatalog.$DB.$O_TABLE VALUES (2, 'y')"

# 部品に引用符付きを含む形（1 部目は無引用のまま）。
run_in_ctx "$DEFAULT_CTX" o6 "SELECT * FROM awsdatacatalog.\"$DB\".$O_TABLE"
run_in_ctx "$DEFAULT_CTX" o7 "SELECT * FROM awsdatacatalog.$DB.\"$O_TABLE\""

# 3 部以外（4 部の列の参照）。
run_in_ctx "$DEFAULT_CTX" o8 "SELECT awsdatacatalog.$DB.$O_TABLE.n FROM awsdatacatalog.$DB.$O_TABLE"

if [ -n "$FEDERATED_CATALOG" ] && [ -n "$FEDERATED_DB" ] && [ -n "$FEDERATED_TABLE" ]; then
  # AwsDataCatalog 以外の別名キー（連携カタログの名前）を無引用の大文字混じりで書いた形。
  run_in_ctx "Catalog=$FEDERATED_CATALOG" o9 "SELECT * FROM ${FEDERATED_CATALOG^^}.$FEDERATED_DB.$FEDERATED_TABLE"
else
  skip o9 "未測定（FEDERATED_CATALOG・FEDERATED_DB・FEDERATED_TABLE のいずれか未設定）"
fi

# Context の Catalog を省略したとき（既定と同じ扱いになるか。大文字小文字も併せて見る）。
run_in_ctx "Database=$DB" o10 "SELECT * FROM awsdatacatalog.$DB.$O_TABLE"
run_in_ctx "Database=$DB" o11 "SELECT * FROM AWSDATACATALOG.$DB.$O_TABLE"

run_in_ctx "$DEFAULT_CTX" o-cleanup "DROP TABLE IF EXISTS $DB.$O_TABLE"
succeeded o-cleanup && unset "PENDING_DROPS[$O_TABLE]"

O_LABELS="o0 o1 o2 o3 o4 o5 o6 o7 o8 o9 o10 o11"

# --- 付随物の取得（FAILED になった項目だけ） --------------------------------------------
fetch_failed_attachments $O_LABELS

fi # ROUND=12

# ROUND=13 だけ、T・U・V・W・X・Y 群を投げる（issue #266）。
if [ "$ROUND" = 13 ]; then

DEFAULT_CTX="Catalog=$CATALOG,Database=$DB"
# バッククォート 1 文字（v9・w9。ROUND=10 の s11 と同じ理由で変数にして埋め込む）。
BT='`'
# LOCATION 付きの項目の置き場（ROUND=10 の probe_location_s と同じ形。空のプレフィックス）。
probe_location_t() { printf '%sathena-local-probe-266/%s/' "$OUTPUT" "$(new_name "$1")"; }

if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  S3T_CTX="Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS"
fi

# --- T 群（issue の 2: 実在しないカタログ nosuchcatalog266 の 3 部 + LOCATION に句が付く形） ---
# 常に投げる（既定の Context）。t0 は同じラウンドで測り直す s12 の対照。
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" t0 \
  "CREATE TABLE nosuchcatalog266.$DB.$(new_name t0) (n int) LOCATION '$(probe_location_t t0)'" "$(new_name t0)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" t1 \
  "CREATE EXTERNAL TABLE nosuchcatalog266.$DB.$(new_name t1) (n int) LOCATION '$(probe_location_t t1)'" "$(new_name t1)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" t2 \
  "CREATE TABLE IF NOT EXISTS nosuchcatalog266.$DB.$(new_name t2) (n int) LOCATION '$(probe_location_t t2)'" "$(new_name t2)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" t3 \
  "CREATE TABLE nosuchcatalog266.$DB.$(new_name t3) (n int) COMMENT 't comment' LOCATION '$(probe_location_t t3)'" "$(new_name t3)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" t4 \
  "CREATE TABLE nosuchcatalog266.$DB.$(new_name t4) (n int) PARTITIONED BY (p int) LOCATION '$(probe_location_t t4)'" "$(new_name t4)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" t5 \
  "CREATE TABLE nosuchcatalog266.$DB.$(new_name t5) (n int) CLUSTERED BY (n) INTO 4 BUCKETS LOCATION '$(probe_location_t t5)'" "$(new_name t5)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" t6 \
  "CREATE TABLE nosuchcatalog266.$DB.$(new_name t6) (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde' LOCATION '$(probe_location_t t6)'" "$(new_name t6)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" t7 \
  "CREATE TABLE nosuchcatalog266.$DB.$(new_name t7) (n int) STORED AS PARQUET LOCATION '$(probe_location_t t7)'" "$(new_name t7)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" t8 \
  "CREATE TABLE nosuchcatalog266.$DB.$(new_name t8) (n int) LOCATION '$(probe_location_t t8)' TBLPROPERTIES ('a266'='b')" "$(new_name t8)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" t9 \
  "CREATE EXTERNAL TABLE IF NOT EXISTS nosuchcatalog266.$DB.$(new_name t9) (n int) COMMENT 't comment' PARTITIONED BY (p int) ROW FORMAT DELIMITED FIELDS TERMINATED BY ',' STORED AS TEXTFILE LOCATION '$(probe_location_t t9)' TBLPROPERTIES ('a266'='b')" "$(new_name t9)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" t10 \
  "CREATE TABLE nosuchcatalog266.$DB.$(new_name t10) LOCATION '$(probe_location_t t10)'" "$(new_name t10)"

# t0s・t1s・t2s・t7s・t9s: t0・t1・t2・t7・t9 と同じ文で表名の接尾辞だけ変え、S3 Tables の
# Context で投げる（2 部目は $DB のまま）。S3TABLES_* が揃うときだけ。
if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" t0s \
    "CREATE TABLE nosuchcatalog266.$DB.$(new_name t0s) (n int) LOCATION '$(probe_location_t t0s)'" "$(new_name t0s)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" t1s \
    "CREATE EXTERNAL TABLE nosuchcatalog266.$DB.$(new_name t1s) (n int) LOCATION '$(probe_location_t t1s)'" "$(new_name t1s)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" t2s \
    "CREATE TABLE IF NOT EXISTS nosuchcatalog266.$DB.$(new_name t2s) (n int) LOCATION '$(probe_location_t t2s)'" "$(new_name t2s)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" t7s \
    "CREATE TABLE nosuchcatalog266.$DB.$(new_name t7s) (n int) STORED AS PARQUET LOCATION '$(probe_location_t t7s)'" "$(new_name t7s)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" t9s \
    "CREATE EXTERNAL TABLE IF NOT EXISTS nosuchcatalog266.$DB.$(new_name t9s) (n int) COMMENT 't comment' PARTITIONED BY (p int) ROW FORMAT DELIMITED FIELDS TERMINATED BY ',' STORED AS TEXTFILE LOCATION '$(probe_location_t t9s)' TBLPROPERTIES ('a266'='b')" "$(new_name t9s)"
else
  for l in t0s t1s t2s t7s t9s; do
    skip "$l" "未測定（S3TABLES_* 未設定）"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

T_LABELS="t0 t1 t2 t3 t4 t5 t6 t7 t8 t9 t10 t0s t1s t2s t7s t9s"

# --- Y 群（issue の 1 のうち、Trino にだけあるよくあるカタログ名） ---
# 常に投げる（既定の Context）。万一受理されたら既定の Context で消す。
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" y1 \
  "CREATE TABLE hive.$DB.$(new_name y1) (n int) LOCATION '$(probe_location_t y1)'" "$(new_name y1)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" y2 \
  "CREATE TABLE iceberg.$DB.$(new_name y2) (n int) LOCATION '$(probe_location_t y2)'" "$(new_name y2)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" y3 \
  "CREATE TABLE system.$DB.$(new_name y3) (n int) LOCATION '$(probe_location_t y3)'" "$(new_name y3)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" y4 \
  "CREATE TABLE tpch.$DB.$(new_name y4) (n int) LOCATION '$(probe_location_t y4)'" "$(new_name y4)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" y5 \
  "CREATE TABLE memory.$DB.$(new_name y5) (n int) LOCATION '$(probe_location_t y5)'" "$(new_name y5)"

Y_LABELS="y1 y2 y3 y4 y5"

# --- U 群（issue の 3: S3 Tables の Context の LOCATION 付きの句の組み合わせ） ---
# S3TABLES_* が揃うときだけ、S3 Tables の Context で投げる。
if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" u0 \
    "CREATE TABLE $(new_name u0) (n int) LOCATION '$(probe_location_t u0)'" "$(new_name u0)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" u1 \
    "CREATE TABLE $(new_name u1) (n int) COMMENT 't comment' CLUSTERED BY (n) INTO 4 BUCKETS LOCATION '$(probe_location_t u1)'" "$(new_name u1)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" u2 \
    "CREATE TABLE $(new_name u2) (n int) PARTITIONED BY (p int) ROW FORMAT DELIMITED FIELDS TERMINATED BY ',' STORED AS TEXTFILE LOCATION '$(probe_location_t u2)' TBLPROPERTIES ('a266'='b')" "$(new_name u2)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" u3 \
    "CREATE TABLE $(new_name u3) (n int) COMMENT 't comment' ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde' STORED AS TEXTFILE LOCATION '$(probe_location_t u3)'" "$(new_name u3)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" u4 \
    "CREATE EXTERNAL TABLE $(new_name u4) (n int) COMMENT 't comment' PARTITIONED BY (p int) CLUSTERED BY (n) INTO 4 BUCKETS ROW FORMAT DELIMITED FIELDS TERMINATED BY ',' STORED AS TEXTFILE LOCATION '$(probe_location_t u4)' TBLPROPERTIES ('a266'='b')" "$(new_name u4)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" u5 \
    "CREATE TABLE IF NOT EXISTS $(new_name u5) (n int) COMMENT 't comment' LOCATION '$(probe_location_t u5)'" "$(new_name u5)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" u6 \
    "CREATE TABLE $S3TABLES_NS.$(new_name u6) (n int) COMMENT 't comment' STORED AS PARQUET LOCATION '$(probe_location_t u6)'" "$(new_name u6)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" u7 \
    "CREATE TABLE AwsDataCatalog.$DB.$(new_name u7) (n int) PARTITIONED BY (p int) LOCATION '$(probe_location_t u7)'" "$(new_name u7)"
else
  for l in u0 u1 u2 u3 u4 u5 u6 u7; do
    skip "$l" "未測定（S3TABLES_* 未設定）"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

U_LABELS="u0 u1 u2 u3 u4 u5 u6 u7"

# --- V 群（issue の 4: LOCATION の無い CREATE EXTERNAL TABLE に句が付く形） ---
# S3TABLES_* が揃うときだけ、S3 Tables の Context で投げる。vc1・vc4 は EXTERNAL の無い対照。
if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" v0 \
    "CREATE EXTERNAL TABLE $(new_name v0) (n int)" "$(new_name v0)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" v1 \
    "CREATE EXTERNAL TABLE $(new_name v1) (n int) COMMENT 't comment'" "$(new_name v1)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" v2 \
    "CREATE EXTERNAL TABLE $(new_name v2) (n int) PARTITIONED BY (p int)" "$(new_name v2)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" v3 \
    "CREATE EXTERNAL TABLE $(new_name v3) (n int) CLUSTERED BY (n) INTO 4 BUCKETS" "$(new_name v3)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" v4 \
    "CREATE EXTERNAL TABLE $(new_name v4) (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'" "$(new_name v4)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" v5 \
    "CREATE EXTERNAL TABLE $(new_name v5) (n int) ROW FORMAT DELIMITED FIELDS TERMINATED BY ','" "$(new_name v5)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" v6 \
    "CREATE EXTERNAL TABLE $(new_name v6) (n int) COMMENT 't comment' ROW FORMAT DELIMITED FIELDS TERMINATED BY ',' STORED AS PARQUET TBLPROPERTIES ('a266'='b')" "$(new_name v6)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" v7 \
    "CREATE EXTERNAL TABLE IF NOT EXISTS $(new_name v7) (n int)" "$(new_name v7)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" v8 \
    "CREATE EXTERNAL TABLE $(new_name v8) TBLPROPERTIES ('a266'='b')" "$(new_name v8)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" v9 \
    "CREATE EXTERNAL TABLE ${BT}$(new_name v9)${BT} (n int)" "$(new_name v9)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" vc1 \
    "CREATE TABLE $(new_name vc1) (n int) COMMENT 't comment'" "$(new_name vc1)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" vc4 \
    "CREATE TABLE $(new_name vc4) (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'" "$(new_name vc4)"
else
  for l in v0 v1 v2 v3 v4 v5 v6 v7 v8 v9 vc1 vc4; do
    skip "$l" "未測定（S3TABLES_* 未設定）"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

V_LABELS="v0 v1 v2 v3 v4 v5 v6 v7 v8 v9 vc1 vc4"

# --- W 群（issue の 5: LOCATION の無い STORED AS の 2〜3 部の名前・IF NOT EXISTS・ほかの句） ---
# S3TABLES_* が揃うときだけ、S3 Tables の Context で投げる。受理されうるものも含め、
# すべて run_create_then_drop_ctx で投げる（失敗しても後始末は skip になるだけで安全）。
if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" w0 \
    "CREATE TABLE $(new_name w0) (n int) STORED AS PARQUET" "$(new_name w0)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" w1 \
    "CREATE TABLE $S3TABLES_NS.$(new_name w1) (n int) STORED AS PARQUET" "$(new_name w1)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" w2 \
    "CREATE TABLE AwsDataCatalog.$S3TABLES_NS.$(new_name w2) (n int) STORED AS PARQUET" "$(new_name w2)"
  run_create_then_drop_ctx "$S3T_CTX" "$DEFAULT_CTX" w3 \
    "CREATE TABLE awsdatacatalog.$DB.$(new_name w3) (n int) STORED AS PARQUET" "$(new_name w3)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" w4 \
    "CREATE TABLE IF NOT EXISTS $(new_name w4) (n int) STORED AS PARQUET" "$(new_name w4)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" w5 \
    "CREATE TABLE $(new_name w5) (n int) COMMENT 't comment' STORED AS PARQUET" "$(new_name w5)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" w6 \
    "CREATE TABLE $(new_name w6) (n int) PARTITIONED BY (p int) STORED AS PARQUET" "$(new_name w6)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" w7 \
    "CREATE TABLE $(new_name w7) (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde' STORED AS TEXTFILE" "$(new_name w7)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" w8 \
    "CREATE TABLE $(new_name w8) (n int) STORED AS PARQUET TBLPROPERTIES ('a266'='b')" "$(new_name w8)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" w9 \
    "CREATE TABLE ${BT}$(new_name w9)${BT} (n int) STORED AS PARQUET" "$(new_name w9)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" w10 \
    "CREATE TABLE $(new_name w10) STORED AS PARQUET" "$(new_name w10)"
else
  for l in w0 w1 w2 w3 w4 w5 w6 w7 w8 w9 w10; do
    skip "$l" "未測定（S3TABLES_* 未設定）"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

W_LABELS="w0 w1 w2 w3 w4 w5 w6 w7 w8 w9 w10"

# --- X 群（issue の 1: 実在する連携カタログの 3 部 + LOCATION） ---
# xc は既定の Context の対照で、連携カタログの有無によらず常に投げる。
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" xc \
  "CREATE TABLE AwsDataCatalog.$DB.$(new_name xc) (n int) LOCATION '$(probe_location_t xc)'" "$(new_name xc)"

# 連携カタログを決める（共有関数。ROUND=14 の Z 群と同じ）。ラベルの接頭辞は "x"。
resolve_federated_catalog x

# x1〜x4: 連携カタログの表を作り、受理されたら Catalog=<FC>,Database=<FDB> の Context で消す
# （run_x_create。共有関数。ROUND=14 の Z 群と同じ）。
if [ -n "$FC" ]; then
  run_x_create "$DEFAULT_CTX" "$FDB" x1 \
    "CREATE TABLE $FC.$FDB.$(new_name x1) (n int) LOCATION '$(probe_location_t x1)'" "$(new_name x1)"
  if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
    run_x_create "$S3T_CTX" "$FDB" x2 \
      "CREATE TABLE $FC.$FDB.$(new_name x2) (n int) LOCATION '$(probe_location_t x2)'" "$(new_name x2)"
  else
    skip x2 "未測定（S3TABLES_* 未設定）"
    skip x2-cleanup "CREATE TABLE を投げていないため後始末不要"
  fi
  run_x_create "$DEFAULT_CTX" "$FDB" x3 \
    "CREATE EXTERNAL TABLE $FC.$FDB.$(new_name x3) (n int) LOCATION '$(probe_location_t x3)'" "$(new_name x3)"
  run_x_create "$DEFAULT_CTX" "$FDB" x4 \
    "CREATE TABLE $FC.$FDB.$(new_name x4) (n int) STORED AS PARQUET LOCATION '$(probe_location_t x4)'" "$(new_name x4)"
else
  for l in x1 x2 x3 x4; do
    skip "$l" "$FEDCAT_SKIP_REASON"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

# CREATE_GLUE_CATALOG=1 で作ったデータカタログは、x1〜x4 の後始末が終わってから明示的に消す
# （共有関数。結果を summary に出す。消せなければ trap がもう一度ベストエフォートで消しにいく）。
delete_glue_catalog_if_created x

X_LABELS="xc x1 x2 x3 x4"

# --- 付随物の取得（FAILED になった項目だけ） --------------------------------------------
fetch_failed_attachments $T_LABELS $Y_LABELS $U_LABELS $V_LABELS $W_LABELS $X_LABELS

fi # ROUND=13

# ROUND=14 だけ、Z 群を投げる（issue #266 の補足）。
if [ "$ROUND" = 14 ]; then

DEFAULT_CTX="Catalog=$CATALOG,Database=$DB"
# バッククォート 1 文字（z14。ROUND=10 の s11 と同じ理由で変数にして埋め込む）。
BT='`'
# LOCATION 付きの項目の置き場（ROUND=13 と同じ probe_location_t。接頭辞は 266 のまま変えていない）。
probe_location_t() { printf '%sathena-local-probe-266/%s/' "$OUTPUT" "$(new_name "$1")"; }

if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  S3T_CTX="Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS"
fi

# --- z0・z0b・z0c（ROUND=13 で見つかった x3 の対照。既定の Context。EXTERNAL 付きの 1〜3 部の
# 名前 + LOCATION）。常に投げる。受理される見込み。 ---
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" z0 \
  "CREATE EXTERNAL TABLE AwsDataCatalog.$DB.$(new_name z0) (n int) LOCATION '$(probe_location_t z0)'" "$(new_name z0)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" z0b \
  "CREATE EXTERNAL TABLE $DB.$(new_name z0b) (n int) LOCATION '$(probe_location_t z0b)'" "$(new_name z0b)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" z0c \
  "CREATE EXTERNAL TABLE awsdatacatalog.$DB.$(new_name z0c) (n int) LOCATION '$(probe_location_t z0c)'" "$(new_name z0c)"

Z_LABELS_PREFIX="z0 z0b z0c"

# --- z1〜z5（連携カタログの 3 部・1 部の名前。既定の Context と、連携カタログを Catalog に
# した Context <GCTX>=Catalog=<連携カタログ>,Database=<DB>）。連携カタログが使えるときだけ。
# 連携カタログの決め方・Glue のデータカタログの作成/削除は ROUND=13 の X 群と共有する。 ---
resolve_federated_catalog z

if [ -n "$FC" ]; then
  GCTX="Catalog=$FC,Database=$DB"
  run_x_create "$DEFAULT_CTX" "$DB" z1 \
    "CREATE EXTERNAL TABLE $FC.$DB.$(new_name z1) (n int) LOCATION '$(probe_location_t z1)'" "$(new_name z1)"
  run_x_create "$GCTX" "$DB" z2 \
    "CREATE EXTERNAL TABLE $FC.$DB.$(new_name z2) (n int) LOCATION '$(probe_location_t z2)'" "$(new_name z2)"
  # z3 は既定の Context に作られる見込みなので、run_x_create のフォールバックは要らない
  # （w3・u7 と同じ、直接 run_create_then_drop_ctx で消す Context を <DEF> にする）。
  run_create_then_drop_ctx "$GCTX" "$DEFAULT_CTX" z3 \
    "CREATE EXTERNAL TABLE AwsDataCatalog.$DB.$(new_name z3) (n int) LOCATION '$(probe_location_t z3)'" "$(new_name z3)"
  run_x_create "$GCTX" "$DB" z4 \
    "CREATE EXTERNAL TABLE $(new_name z4) (n int) LOCATION '$(probe_location_t z4)'" "$(new_name z4)"
  run_x_create "$GCTX" "$DB" z5 \
    "CREATE TABLE $FC.$DB.$(new_name z5) (n int) LOCATION '$(probe_location_t z5)'" "$(new_name z5)"
else
  for l in z1 z2 z3 z4 z5; do
    skip "$l" "$FEDCAT_SKIP_REASON"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

# CREATE_GLUE_CATALOG=1 で作ったデータカタログは、z1〜z5 の後始末が終わってから明示的に消す
# （共有関数。結果を summary に出す。消せなければ trap がもう一度ベストエフォートで消しにいく）。
delete_glue_catalog_if_created z

Z_LABELS_FEDCAT="z1 z2 z3 z4 z5"

# --- z6〜z17（S3 Tables の Context。LOCATION の無い非 EXTERNAL の ROW FORMAT の族と、ほかの
# 単独の Hive の句。S3TABLES_* が揃うときだけ。受理されたら S3 Tables の Context で消す） ---
if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" z6 \
    "CREATE TABLE $(new_name z6) (n int) ROW FORMAT DELIMITED FIELDS TERMINATED BY ','" "$(new_name z6)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" z7 \
    "CREATE TABLE $(new_name z7) (n int) COMMENT 't comment' ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'" "$(new_name z7)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" z8 \
    "CREATE TABLE $S3TABLES_NS.$(new_name z8) (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'" "$(new_name z8)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" z9 \
    "CREATE TABLE IF NOT EXISTS $(new_name z9) (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'" "$(new_name z9)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" z10 \
    "CREATE TABLE $(new_name z10) (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde' TBLPROPERTIES ('a266'='b')" "$(new_name z10)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" z11 \
    "CREATE TABLE $(new_name z11) (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'" "$(new_name z11)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" z12 \
    "CREATE TABLE AwsDataCatalog.$S3TABLES_NS.$(new_name z12) (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'" "$(new_name z12)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" z13 \
    "CREATE TABLE $(new_name z13) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'" "$(new_name z13)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" z14 \
    "CREATE TABLE ${BT}$(new_name z14)${BT} (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'" "$(new_name z14)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" z15 \
    "CREATE TABLE $(new_name z15) (n int) PARTITIONED BY (p int)" "$(new_name z15)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" z16 \
    "CREATE TABLE $(new_name z16) (n int) CLUSTERED BY (n) INTO 4 BUCKETS" "$(new_name z16)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" z17 \
    "CREATE TABLE $(new_name z17) (n int) TBLPROPERTIES ('a266'='b')" "$(new_name z17)"
else
  for l in z6 z7 z8 z9 z10 z11 z12 z13 z14 z15 z16 z17; do
    skip "$l" "未測定（S3TABLES_* 未設定）"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

Z_LABELS_S3="z6 z7 z8 z9 z10 z11 z12 z13 z14 z15 z16 z17"
Z_LABELS="$Z_LABELS_PREFIX $Z_LABELS_FEDCAT $Z_LABELS_S3"
# 開始できた項目の QueryExecutionContext・StatementType/SubstatementType の詳細を出す対象
# （ROUND=13 の X 群と同じ範囲。z6〜z17 の S3 Tables の族は対象外）。
Z_REPR_LABELS="$Z_LABELS_PREFIX $Z_LABELS_FEDCAT"

# --- 付随物の取得（FAILED になった項目だけ） --------------------------------------------
fetch_failed_attachments $Z_LABELS

fi # ROUND=14

# ROUND=15 だけ、T 群を投げる（issue #251 の 2 ラウンド目）。
if [ "$ROUND" = 15 ]; then

DEFAULT_CTX="Catalog=$CATALOG,Database=$DB"
DB_ONLY_CTX="Database=$DB"

# --- T 群（CTAS の SELECT が解析／実行のどちらで失敗するか、Catalog 省略、プロパティ付き、
#     WITH NO DATA、複数行／0 行、括弧／WITH 句、ExecutionParameters、S3 Tables の Context の
#     名前空間まわり） ----------------------------------------------------------------------

# t1: SELECT が FROM の表を解決できず解析で失敗するとき（既定の Context。DB 無し。項目 1）。
T1_DB="$(new_name t1db)"
T1_SRC="$(new_name t1src)"
run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$T1_DB" t1 \
  "CREATE TABLE awsdatacatalog.$T1_DB.$(new_name t1) AS SELECT * FROM $DB.$T1_SRC" "$(new_name t1)"
# t2: SELECT 自体は解析を通り、実行中に失敗するとき（既定の Context。DB 無し。項目 2）。
T2_DB="$(new_name t2db)"
run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$T2_DB" t2 \
  "CREATE TABLE awsdatacatalog.$T2_DB.$(new_name t2) AS SELECT CAST('x' AS integer) AS n" "$(new_name t2)"

if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  S3T_CTX="Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS"

  # t3: t1 と同じ文を S3 Tables の Context で（項目 3）。
  T3_DB="$(new_name t3db)"
  T3_SRC="$(new_name t3src)"
  run_create_then_drop_ctx "$S3T_CTX" "Catalog=$CATALOG,Database=$T3_DB" t3 \
    "CREATE TABLE awsdatacatalog.$T3_DB.$(new_name t3) AS SELECT * FROM $DB.$T3_SRC" "$(new_name t3)"
  # t4: t2 と同じ文を S3 Tables の Context で（項目 3）。
  T4_DB="$(new_name t4db)"
  run_create_then_drop_ctx "$S3T_CTX" "Catalog=$CATALOG,Database=$T4_DB" t4 \
    "CREATE TABLE awsdatacatalog.$T4_DB.$(new_name t4) AS SELECT CAST('x' AS integer) AS n" "$(new_name t4)"
else
  for l in t3 t4; do
    skip "$l" "未測定（S3TABLES_* 未設定）"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

# t5: 対照。DB があり、SELECT が実行中に失敗するとき（既定の Context。エンジンのエラーの
# 見込み。項目 4）。
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" t5 \
  "CREATE TABLE awsdatacatalog.$DB.$(new_name t5) AS SELECT CAST('x' AS integer) AS n" "$(new_name t5)"

# t6/t7: Context の Catalog を省略し Database=<DB> だけにしたとき（DB 無し・ある対照。項目 5）。
T6_DB="$(new_name t6db)"
run_create_then_drop_ctx "$DB_ONLY_CTX" "Catalog=$CATALOG,Database=$T6_DB" t6 \
  "CREATE TABLE awsdatacatalog.$T6_DB.$(new_name t6) AS SELECT 1 AS n" "$(new_name t6)"
run_create_then_drop_ctx "$DB_ONLY_CTX" "$DB_ONLY_CTX" t7 \
  "CREATE TABLE awsdatacatalog.$DB.$(new_name t7) AS SELECT 1 AS n" "$(new_name t7)"

# t8: プロパティ付き（WITH (format = 'PARQUET')。既定の Context。DB 無し。項目 6）。
T8_DB="$(new_name t8db)"
run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$T8_DB" t8 \
  "CREATE TABLE awsdatacatalog.$T8_DB.$(new_name t8) WITH (format = 'PARQUET') AS SELECT 1 AS n" "$(new_name t8)"

# t9/t10: WITH NO DATA（DB 無し・ある対照。項目 7）。t10 は成功時の .metadata も後で取る。
T9_DB="$(new_name t9db)"
run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$T9_DB" t9 \
  "CREATE TABLE awsdatacatalog.$T9_DB.$(new_name t9) AS SELECT 1 AS n WITH NO DATA" "$(new_name t9)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" t10 \
  "CREATE TABLE awsdatacatalog.$DB.$(new_name t10) AS SELECT 1 AS n WITH NO DATA" "$(new_name t10)"

# t11/t12: 3 行・0 行（既定の Context。DB 無し。項目 8）。
T11_DB="$(new_name t11db)"
run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$T11_DB" t11 \
  "CREATE TABLE awsdatacatalog.$T11_DB.$(new_name t11) AS SELECT n FROM (VALUES 1, 2, 3) AS v(n)" "$(new_name t11)"
T12_DB="$(new_name t12db)"
run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$T12_DB" t12 \
  "CREATE TABLE awsdatacatalog.$T12_DB.$(new_name t12) AS SELECT 1 AS n WHERE false" "$(new_name t12)"

# t13/t14: 括弧付き・WITH 句（既定の Context。DB 無し。項目 9）。
T13_DB="$(new_name t13db)"
run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$T13_DB" t13 \
  "CREATE TABLE awsdatacatalog.$T13_DB.$(new_name t13) AS (SELECT 1 AS n)" "$(new_name t13)"
T14_DB="$(new_name t14db)"
run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$T14_DB" t14 \
  "CREATE TABLE awsdatacatalog.$T14_DB.$(new_name t14) AS WITH c AS (SELECT 1 AS n) SELECT n FROM c" "$(new_name t14)"

# t15: ExecutionParameters（既定の Context。DB 無し。項目 10）。DROP に ? が無いので、
# START_EXTRA は CREATE の 1 回だけに掛けてすぐ戻す（run_create_then_drop_ctx は使わず、
# 同じ形の後始末を手組みする）。
T15_DB="$(new_name t15db)"
T15_NAME="$(new_name t15)"
T15_DROP_CTX="Catalog=$CATALOG,Database=$T15_DB"
START_EXTRA=(--execution-parameters 7)
T15_OK=0
run_in_ctx "$DEFAULT_CTX" t15 "CREATE TABLE awsdatacatalog.$T15_DB.$T15_NAME AS SELECT ? AS n" && T15_OK=1
START_EXTRA=()
if [ "$T15_OK" = 1 ]; then
  T15_KEY="$T15_DROP_CTX|$T15_NAME"
  PENDING_DROPS_CTX[$T15_KEY]=1
  run_in_ctx "$T15_DROP_CTX" t15-cleanup "DROP TABLE IF EXISTS $T15_NAME"
  succeeded t15-cleanup && unset 'PENDING_DROPS_CTX[$T15_KEY]'
else
  skip t15-cleanup "CREATE TABLE が失敗したため後始末不要"
fi

# t16〜t19: S3 Tables の Context の名前空間まわり（項目 11・12）。
if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  S3T_CTX="Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS"
  T_NOPE_NS="$(new_name t_nope_ns)"
  T_NOPE_NS_CTX="Catalog=$S3TABLES_CATALOG,Database=$T_NOPE_NS"

  # t16: Context の Database が無い名前空間、1 部の CTAS。
  run_create_then_drop_ctx "$T_NOPE_NS_CTX" "$T_NOPE_NS_CTX" t16 \
    "CREATE TABLE $(new_name t16) AS SELECT 1 AS n" "$(new_name t16)"
  # t17: 既存の名前空間の Context で、2 部の CTAS が無い名前空間を指すとき。
  run_create_then_drop_ctx "$S3T_CTX" "$T_NOPE_NS_CTX" t17 \
    "CREATE TABLE $T_NOPE_NS.$(new_name t17) AS SELECT 1 AS n" "$(new_name t17)"
  # t18: 対照。2 部の CTAS が既存の名前空間を指すとき（作られたら同じ Context で DROP）。
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" t18 \
    "CREATE TABLE $S3TABLES_NS.$(new_name t18) AS SELECT 1 AS n" "$(new_name t18)"
  # t19: r1 の再現 + IF NOT EXISTS、CTAS でない（項目 12。コーディネーターからの追加）。
  # 取るものは r1 と同じなので、後段の check_ctas_orphan_data・SUCCEEDED 時の .metadata 取得の
  # 対象からは外す（CTAS ではないため）。
  run_create_then_drop_ctx "$T_NOPE_NS_CTX" "$T_NOPE_NS_CTX" t19 \
    "CREATE TABLE IF NOT EXISTS $(new_name t19) (n int)" "$(new_name t19)"
else
  for l in t16 t17 t18 t19; do
    skip "$l" "未測定（S3TABLES_* 未設定）"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

T_LABELS="t1 t2 t3 t4 t5 t6 t7 t8 t9 t10 t11 t12 t13 t14 t15 t16 t17 t18 t19"

# --- 付随物の取得（FAILED になった項目は本体・.metadata・オーファンデータ確認。
#     SUCCEEDED の CTAS は .metadata も取る。t19 は CTAS でないので、どちらも r1 と同じく
#     本体・.metadata の有無だけを見る） -----------------------------------------------
fetch_failed_attachments $T_LABELS
for l in $T_LABELS; do
  if is_failed "$l"; then
    [ "$l" = t19 ] || check_ctas_orphan_data "$l"
  elif succeeded "$l" && [ "$l" != t19 ]; then
    T_LOC=$(output_location_of "$l")
    [ -n "$T_LOC" ] && fetch_s3_body "${T_LOC}.metadata" "$RUN_DIR/$l.output.metadata" "$RUN_DIR/$l.output.metadata.err"
  fi
done

fi # ROUND=15

# ROUND=16 だけ、cl・pr・pn・pa・tp 群を投げる（issue #270。#266 の先行実測（ROUND=13・14）の
# 範囲外の発見 1 と、issue #270 本文の「測っていない形」1〜3 を測る。ROUND=15 は #251 が
# 別ブランチ（main-measure-251）で使うため、このブランチには無い）。すべて S3 Tables の
# Context（Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS）だけに投げ、LOCATION は付けない
# （このラウンドは全部 LOCATION 無し）。S3TABLES_* が揃わなければ全項目「未測定」として残す。
if [ "$ROUND" = 16 ]; then

# バッククォート 1 文字（pn4。ROUND=10 の s11 と同じ理由で変数にして埋め込む）。
BT='`'

CL_LABELS="cl0 cl1"
PR_LABELS="pr1 pr2 pr3 pr4 pr5 pr6 pr7 pr8 pr9 pr10"
PN_LABELS="pn1 pn2 pn3 pn4 pn5 pn6"
PA_LABELS="pa1 pa2 pa3 pa4 pa5 pa6"
TP_LABELS="tp1 tp2 tp3 tp4 tp5 tp6 tp7"

if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  S3T_CTX="Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS"

  # --- cl 群（対照。issue の範囲外の発見 1 の再現の足場） ---
  run_create_then_drop_ctx_showcreate "$S3T_CTX" cl0 \
    "CREATE TABLE $(new_name cl0) (n int)" "$(new_name cl0)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" cl1 \
    "CREATE TABLE $(new_name cl1) (n int) PARTITIONED BY (p int)" "$(new_name cl1)"

  # --- pr 群（issue の 1: 句どうしの優先順。Hive の句の順 PARTITIONED BY → CLUSTERED BY →
  # ROW FORMAT → STORED AS → TBLPROPERTIES で書く） ---
  run_create_then_drop_ctx_showcreate "$S3T_CTX" pr1 \
    "CREATE TABLE $(new_name pr1) (n int) PARTITIONED BY (p int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'" "$(new_name pr1)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" pr2 \
    "CREATE TABLE $(new_name pr2) (n int) PARTITIONED BY (p int) CLUSTERED BY (n) INTO 4 BUCKETS" "$(new_name pr2)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" pr3 \
    "CREATE TABLE $(new_name pr3) (n int) CLUSTERED BY (n) INTO 4 BUCKETS ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'" "$(new_name pr3)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" pr4 \
    "CREATE TABLE $(new_name pr4) (n int) PARTITIONED BY (p int) TBLPROPERTIES ('a270'='b')" "$(new_name pr4)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" pr5 \
    "CREATE TABLE $(new_name pr5) (n int) CLUSTERED BY (n) INTO 4 BUCKETS TBLPROPERTIES ('a270'='b')" "$(new_name pr5)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" pr6 \
    "CREATE TABLE $(new_name pr6) (n int) PARTITIONED BY (p int) STORED AS PARQUET" "$(new_name pr6)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" pr7 \
    "CREATE TABLE $(new_name pr7) (n int) CLUSTERED BY (n) INTO 4 BUCKETS STORED AS PARQUET" "$(new_name pr7)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" pr8 \
    "CREATE TABLE $(new_name pr8) (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde' TBLPROPERTIES ('table_type'='ICEBERG')" "$(new_name pr8)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" pr9 \
    "CREATE TABLE $(new_name pr9) (n int) PARTITIONED BY (p int) CLUSTERED BY (n) INTO 4 BUCKETS ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde' STORED AS PARQUET TBLPROPERTIES ('a270'='b')" "$(new_name pr9)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" pr10 \
    "CREATE TABLE $(new_name pr10) (n int) COMMENT 't comment' PARTITIONED BY (p int)" "$(new_name pr10)"

  # --- pn 群（名前の形。z15〜z17 は 1 部の名前だけ測った周辺） ---
  run_create_then_drop_ctx_showcreate "$S3T_CTX" pn1 \
    "CREATE TABLE $S3TABLES_NS.$(new_name pn1) (n int) PARTITIONED BY (p int)" "$(new_name pn1)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" pn2 \
    "CREATE TABLE AwsDataCatalog.$S3TABLES_NS.$(new_name pn2) (n int) CLUSTERED BY (n) INTO 4 BUCKETS" "$(new_name pn2)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" pn3 \
    "CREATE TABLE IF NOT EXISTS $(new_name pn3) (n int) TBLPROPERTIES ('a270'='b')" "$(new_name pn3)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" pn4 \
    "CREATE TABLE ${BT}$(new_name pn4)${BT} (n int) PARTITIONED BY (p int)" "$(new_name pn4)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" pn5 \
    "CREATE TABLE $(new_name pn5) CLUSTERED BY (n) INTO 4 BUCKETS" "$(new_name pn5)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" pn6 \
    "CREATE TABLE $(new_name pn6) TBLPROPERTIES ('a270'='b')" "$(new_name pn6)"

  # --- pa 群（issue の 2: Iceberg の書き方の PARTITIONED BY） ---
  run_create_then_drop_ctx_showcreate "$S3T_CTX" pa1 \
    "CREATE TABLE $(new_name pa1) (n int) PARTITIONED BY (n)" "$(new_name pa1)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" pa2 \
    "CREATE TABLE $(new_name pa2) (n int, s string) PARTITIONED BY (bucket(4, n))" "$(new_name pa2)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" pa3 \
    "CREATE TABLE $(new_name pa3) (n int, d date) PARTITIONED BY (day(d))" "$(new_name pa3)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" pa4 \
    "CREATE TABLE $(new_name pa4) (n int) PARTITIONED BY (n int)" "$(new_name pa4)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" pa5 \
    "CREATE TABLE $(new_name pa5) (n int) PARTITIONED BY (nosuch270)" "$(new_name pa5)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" pa6 \
    "CREATE TABLE $(new_name pa6) (n int) PARTITIONED BY (n) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'" "$(new_name pa6)"

  # --- tp 群（issue の 3: TBLPROPERTIES） ---
  run_create_then_drop_ctx_showcreate "$S3T_CTX" tp1 \
    "CREATE TABLE $(new_name tp1) (n int) TBLPROPERTIES ('table_type'='ICEBERG')" "$(new_name tp1)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" tp2 \
    "CREATE TABLE $(new_name tp2) (n int) TBLPROPERTIES ('format'='parquet')" "$(new_name tp2)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" tp3 \
    "CREATE TABLE $(new_name tp3) (n int) TBLPROPERTIES ('write_compression'='zstd')" "$(new_name tp3)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" tp4 \
    "CREATE TABLE $(new_name tp4) (n int) TBLPROPERTIES ('table_type'='ICEBERG', 'a270'='b')" "$(new_name tp4)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" tp5 \
    "CREATE TABLE $(new_name tp5) (n int) TBLPROPERTIES ('TABLE_TYPE'='ICEBERG')" "$(new_name tp5)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" tp6 \
    "CREATE TABLE $(new_name tp6) (n int) TBLPROPERTIES ('table_type'='HIVE')" "$(new_name tp6)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" tp7 \
    "CREATE TABLE $(new_name tp7) (n int) TBLPROPERTIES ('a270'='b', 'table_type'='ICEBERG')" "$(new_name tp7)"
else
  for l in $CL_LABELS $PR_LABELS $PN_LABELS $PA_LABELS $TP_LABELS; do
    skip "$l" "未測定（S3TABLES_* 未設定）"
    skip "$l-showcreate" "CREATE TABLE を投げていないため SHOW CREATE TABLE 不要"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

# SHOW CREATE TABLE のラベル一覧（付随物の取得・summary で使う）。
SC_LABELS=""
for l in $CL_LABELS $PR_LABELS $PN_LABELS $PA_LABELS $TP_LABELS; do
  SC_LABELS="$SC_LABELS $l-showcreate"
done

# --- 付随物の取得（FAILED になった項目だけ。SHOW CREATE TABLE の結果本体は
# run_create_then_drop_ctx_showcreate の中で受理された項目ごとに取得済み） -----------------
fetch_failed_attachments $CL_LABELS $PR_LABELS $PN_LABELS $PA_LABELS $TP_LABELS $SC_LABELS

fi # ROUND=16

# ROUND=17 だけ、q 群を投げる（issue #271。本物の CREATE EXTERNAL TABLE の 3 部の名前が
# GetQueryExecution の Query から 1 部目のカタログを落とす（実測済み。#266 の先行実測の範囲外の
# 発見）のに、athena-local の CATALOG_DROPPED に CREATE EXTERNAL TABLE が無く落とさない、という
# 食い違いの周辺を測る）。
if [ "$ROUND" = 17 ]; then

DEFAULT_CTX="Catalog=$CATALOG,Database=$DB"
# LOCATION 付きの項目の置き場（ROUND=13 の probe_location_t と同じ形。空のプレフィックス、
# 接頭辞を 271 にする）。
probe_location_q() { printf '%sathena-local-probe-271/%s/' "$OUTPUT" "$(new_name "$1")"; }

if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  S3T_CTX="Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS"
fi

# --- 準備: 別の DB <DB2> と、同名の表がある形（q14）用の実在する表 <PROBE>_qdup ---------------
# 作ったものは最後の後始末で消す（途中で止めても trap の Q_DB2_OK・Q_QDUP_OK のチェックが
# ベストエフォートで消しにいく。ROUND=8 の別 DB の後始末の考え方を流用）。
DB2="$(new_name db2)"
Q_DB2_OK=0
if run_in_ctx "$DEFAULT_CTX" q-setup-db2 "CREATE DATABASE $DB2"; then
  Q_DB2_OK=1
else
  echo "== q-setup-db2: 別の DB <PROBE>_db2 を作れませんでした。<DB2> を使う項目は未測定にします。"
fi

QDUP="$(new_name qdup)"
Q_QDUP_OK=0
if run_in_ctx "$DEFAULT_CTX" q-setup-qdup \
  "CREATE EXTERNAL TABLE $DB.$QDUP (n int) PARTITIONED BY (p int) LOCATION '$(probe_location_q qdup)'"; then
  Q_QDUP_OK=1
else
  echo "== q-setup-qdup: 実在する表 <PROBE>_qdup を作れませんでした。q14・q16 は未測定にします。"
fi

# --- issue の 1: Context の DB と文の DB が違う形 -----------------------------------------
if [ "$Q_DB2_OK" = 1 ]; then
  run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" q1 \
    "CREATE EXTERNAL TABLE awsdatacatalog.$DB2.$(new_name q1) (n int) LOCATION '$(probe_location_q q1)'" \
    "$DB2.$(new_name q1)"
  run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" q2 \
    "CREATE EXTERNAL TABLE AwsDataCatalog.$DB2.$(new_name q2) (n int) LOCATION '$(probe_location_q q2)'" \
    "$DB2.$(new_name q2)"
  run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" q3 \
    "CREATE EXTERNAL TABLE $DB2.$(new_name q3) (n int) LOCATION '$(probe_location_q q3)'" \
    "$DB2.$(new_name q3)"
else
  for l in q1 q2 q3; do
    skip "$l" "別の DB を作れなかったため"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi
run_create_then_drop_ctx "Catalog=$CATALOG" "$DEFAULT_CTX" q4 \
  "CREATE EXTERNAL TABLE awsdatacatalog.$DB.$(new_name q4) (n int) LOCATION '$(probe_location_q q4)'" \
  "$DB.$(new_name q4)"
run_create_then_drop_ctx "Database=$DB" "$DEFAULT_CTX" q5 \
  "CREATE EXTERNAL TABLE awsdatacatalog.$DB.$(new_name q5) (n int) LOCATION '$(probe_location_q q5)'" \
  "$DB.$(new_name q5)"
if [ "$Q_DB2_OK" = 1 ]; then
  run_create_then_drop_ctx "Database=$DB" "$DEFAULT_CTX" q5b \
    "CREATE EXTERNAL TABLE awsdatacatalog.$DB2.$(new_name q5b) (n int) LOCATION '$(probe_location_q q5b)'" \
    "$DB2.$(new_name q5b)"
else
  skip q5b "別の DB を作れなかったため"
  skip q5b-cleanup "CREATE TABLE を投げていないため後始末不要"
fi
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" q0 \
  "CREATE EXTERNAL TABLE awsdatacatalog.$DB.$(new_name q0) (n int) LOCATION '$(probe_location_q q0)'" \
  "$DB.$(new_name q0)"

# --- issue の 2: 形のバリエーション -------------------------------------------------------
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" q6 \
  "CREATE EXTERNAL TABLE IF NOT EXISTS awsdatacatalog.$DB.$(new_name q6) (n int) LOCATION '$(probe_location_q q6)'" \
  "$DB.$(new_name q6)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" q7 \
  "CREATE EXTERNAL TABLE awsdatacatalog.$DB.$(new_name q7) (n int) PARTITIONED BY (p int) ROW FORMAT DELIMITED FIELDS TERMINATED BY ',' STORED AS TEXTFILE LOCATION '$(probe_location_q q7)' TBLPROPERTIES ('a271'='b')" \
  "$DB.$(new_name q7)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" q8 \
  "CREATE EXTERNAL TABLE awsdatacatalog . $DB . $(new_name q8) (n int) LOCATION '$(probe_location_q q8)'" \
  "$DB.$(new_name q8)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" q9 \
  "CREATE EXTERNAL TABLE /* c */ awsdatacatalog.$DB.$(new_name q9) (n int) LOCATION '$(probe_location_q q9)'" \
  "$DB.$(new_name q9)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" q10 \
  "create external table awsdatacatalog.$DB.$(new_name q10) (n int) location '$(probe_location_q q10)'" \
  "$DB.$(new_name q10)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" q11 \
  "CREATE EXTERNAL TABLE AWSDATACATALOG.$DB.$(new_name q11) (n int) LOCATION '$(probe_location_q q11)'" \
  "$DB.$(new_name q11)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" q11b \
  "  CREATE EXTERNAL TABLE awsdatacatalog.$DB.$(new_name q11b) (n int) LOCATION '$(probe_location_q q11b)';  " \
  "$DB.$(new_name q11b)"

# --- issue の 3: Iceberg の書き方 ---------------------------------------------------------
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" q12 \
  "CREATE TABLE awsdatacatalog.$DB.$(new_name q12) (n int) LOCATION '$(probe_location_q q12)' TBLPROPERTIES ('table_type'='ICEBERG')" \
  "$DB.$(new_name q12)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" q12b \
  "CREATE TABLE $DB.$(new_name q12b) (n int) LOCATION '$(probe_location_q q12b)' TBLPROPERTIES ('table_type'='ICEBERG')" \
  "$DB.$(new_name q12b)"

# --- issue の 5: FAILED になる形 ----------------------------------------------------------
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" q13 \
  "CREATE EXTERNAL TABLE awsdatacatalog.nosuchdb271.$(new_name q13) (n int) LOCATION '$(probe_location_q q13)'" \
  "nosuchdb271.$(new_name q13)"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" q13b \
  "CREATE EXTERNAL TABLE nosuchdb271.$(new_name q13b) (n int) LOCATION '$(probe_location_q q13b)'" \
  "nosuchdb271.$(new_name q13b)"
# q14: 同名の表 <PROBE>_qdup がある形。受理されても後始末は投げない（消すのは準備の表と
# 同じなので、最後の <PROBE>_qdup の後始末に任せる）。
if [ "$Q_QDUP_OK" = 1 ]; then
  run_in_ctx "$DEFAULT_CTX" q14 \
    "CREATE EXTERNAL TABLE awsdatacatalog.$DB.$QDUP (n int) PARTITIONED BY (p int) LOCATION '$(probe_location_q qdup)'"
else
  skip q14 "実在する表を作れなかったため"
fi

# --- issue の 6: Hive のほかの DDL --------------------------------------------------------
if [ "$Q_QDUP_OK" = 1 ]; then
  run_in_ctx "$DEFAULT_CTX" q16 "SHOW PARTITIONS awsdatacatalog.$DB.$QDUP"
else
  skip q16 "実在する表を作れなかったため"
fi
run_in_ctx "$DEFAULT_CTX" q16b "SHOW PARTITIONS $DB.$QDUP"

Q17_DB_OK=0
if run_in_ctx "$DEFAULT_CTX" q17 "CREATE DATABASE awsdatacatalog.$(new_name q17db)"; then
  Q17_DB_OK=1
  run_in_ctx "$DEFAULT_CTX" q17-cleanup "DROP DATABASE IF EXISTS $(new_name q17db) CASCADE"
  if succeeded q17-cleanup; then
    Q17_DB_OK=0
  else
    echo "== q17 で作った DB <PROBE>_q17db を消せませんでした。手で DROP DATABASE IF EXISTS してください。"
  fi
else
  skip q17-cleanup "CREATE DATABASE が失敗したため後始末不要"
fi

if [ "$Q_DB2_OK" = 1 ]; then
  run_in_ctx "$DEFAULT_CTX" q18 "ALTER DATABASE awsdatacatalog.$DB2 SET DBPROPERTIES ('a271'='b')"
  run_in_ctx "$DEFAULT_CTX" q18b "ALTER DATABASE $DB2 SET DBPROPERTIES ('a271'='c')"
  run_in_ctx "$DEFAULT_CTX" q19 "DESCRIBE DATABASE awsdatacatalog.$DB2"
  run_in_ctx "$DEFAULT_CTX" q19b "DESCRIBE DATABASE $DB2"
else
  for l in q18 q18b q19 q19b; do
    skip "$l" "別の DB を作れなかったため"
  done
fi
run_in_ctx "$DEFAULT_CTX" q20 "DROP DATABASE IF EXISTS awsdatacatalog.nosuchdb271x"
if [ "$Q_QDUP_OK" = 1 ]; then
  run_in_ctx "$DEFAULT_CTX" q21 "ALTER TABLE awsdatacatalog.$DB.$QDUP ADD IF NOT EXISTS PARTITION (p=1)"
else
  skip q21 "実在する表を作れなかったため"
fi

# --- S3 Tables の Context（S3TABLES_* が揃うときだけ） ------------------------------------
if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" q22 \
    "CREATE TABLE AwsDataCatalog.$S3TABLES_NS.$(new_name q22) (n int)" "$(new_name q22)"
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" q23 \
    "CREATE TABLE $S3TABLES_NS.$(new_name q23) (n int)" "$(new_name q23)"
else
  for l in q22 q23; do
    skip "$l" "未測定（S3TABLES_* 未設定）"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

# --- 連携カタログ（FEDERATED_CATALOG か CREATE_GLUE_CATALOG=1 のときだけ） -------------------
# 連携カタログの決め方・Glue のデータカタログの作成/削除は ROUND=13・14 の X・Z 群と共有する
# （resolve_federated_catalog・run_x_create・delete_glue_catalog_if_created。挙動は変えていない）。
resolve_federated_catalog q

if [ -n "$FC" ] && [ "$Q_DB2_OK" = 1 ]; then
  GCTX="Catalog=$FC,Database=$DB"
  # 消す名前を <DB2>.<t> の 2 部にすることで、Context は <GCTX>（Database=<DB>）のまま
  # <DB2> 側の表を消す（run_x_create の drop_db には <DB> を渡し、drop_ctx を <GCTX> と
  # 一致させる）。
  run_x_create "$GCTX" "$DB" q24 \
    "CREATE EXTERNAL TABLE $FC.$DB2.$(new_name q24) (n int) LOCATION '$(probe_location_q q24)'" \
    "$DB2.$(new_name q24)"
  run_x_create "$GCTX" "$DB" q25 \
    "CREATE EXTERNAL TABLE AwsDataCatalog.$DB2.$(new_name q25) (n int) LOCATION '$(probe_location_q q25)'" \
    "$DB2.$(new_name q25)"
elif [ -n "$FC" ]; then
  for l in q24 q25; do
    skip "$l" "別の DB を作れなかったため"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
else
  for l in q24 q25; do
    skip "$l" "$FEDCAT_SKIP_REASON"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

Q_LABELS="q1 q2 q3 q4 q5 q5b q0 q6 q7 q8 q9 q10 q11 q11b q12 q12b q13 q13b q14 q16 q16b q17 q18 q18b q19 q19b q20 q21 q22 q23 q24 q25"

# --- 後始末（表 → DB → データカタログの順） -------------------------------------------------
# 各項目の表は run_create_then_drop_ctx・run_x_create の中でここまでにすでに消えている
# （q14 だけは準備の <PROBE>_qdup と同じ表なので、下の q-drop-qdup に任せる）。
if [ "$Q_DB2_OK" = 1 ]; then
  run_in_ctx "$DEFAULT_CTX" q-drop-db2 "DROP DATABASE IF EXISTS $DB2 CASCADE"
  if succeeded q-drop-db2; then
    Q_DB2_OK=0
  else
    echo "== 別の DB <PROBE>_db2 を消せませんでした。手で DROP DATABASE IF EXISTS してください。"
  fi
else
  skip q-drop-db2 "別の DB を作れなかったため後始末不要"
fi
if [ "$Q_QDUP_OK" = 1 ]; then
  run_in_ctx "$DEFAULT_CTX" q-drop-qdup "DROP TABLE IF EXISTS $DB.$QDUP"
  if succeeded q-drop-qdup; then
    Q_QDUP_OK=0
  else
    echo "== 実在する表 <PROBE>_qdup を消せませんでした。手で DROP TABLE IF EXISTS してください。"
  fi
else
  skip q-drop-qdup "実在する表を作れなかったため後始末不要"
fi
# CREATE_GLUE_CATALOG=1 で作ったデータカタログは、表・DB を消したこのあとに明示的に消す
# （共有関数。結果を summary に出す。消せなければ trap がもう一度ベストエフォートで消しにいく）。
delete_glue_catalog_if_created q

# --- 付随物の取得（FAILED になった項目だけ） ------------------------------------------------
fetch_failed_attachments $Q_LABELS

fi # ROUND=17

# ROUND=18 だけ、p・w 群と c1y・i 群を投げる（issue #272。エンジン（Trino）で失敗した CTAS の
# 理由に本物が付ける接尾辞と、解析のエラーの位置が受け取った文の位置と違う規則（本物が組み直して
# 実行しているとみられる）の周辺、INSERT の位置、WITH NO DATA の失敗を測る）。
if [ "$ROUND" = 18 ]; then

DEFAULT_CTX="Catalog=$CATALOG,Database=$DB"
# 無い表の名前（固定。ラウンド全体で共有する）。
NOSRC="$(new_name nosrc)"
# 無い DB の名前を項目ごとに別名で払い出す（組み直しの規則が DB の有無で変わるかを見るため）。
# コマンド置換 $(...) はサブシェルなので、カウンタは NODB_NAME への代入で受け取る（呼び出し元は
# `new_nodb; X_NODB="$NODB_NAME"` の形で使う。サブシェル越しだとインクリメントが親に伝わらない）。
NODB_SEQ=0
new_nodb() { NODB_SEQ=$((NODB_SEQ + 1)); NODB_NAME="${PROBE_PREFIX}_nodb${NODB_SEQ}"; }
# line L:C を含む項目ごとに、送った文の中でエラーの対象の語が始まる位置を求めるための、
# 項目ラベル → 対象の語（マスク前の実文字列）。summary の「位置の表」で使う。
declare -A POS_TARGET=()

# --- 準備: 実在する表 <PROBE>_src（作れなければ、これを使う項目だけ未測定にする） -----------------
SRC="$(new_name src)"
SRC_OK=0
if run_in_ctx "$DEFAULT_CTX" p-setup-src "CREATE TABLE $DB.$SRC AS SELECT 1 AS n, 'x' AS s"; then
  SRC_OK=1
else
  echo "== p-setup-src: 実在する表 <PROBE>_src を作れませんでした。使う項目は未測定にします。"
fi

# --- p1/p1y: t1（#251 ROUND=15）の再現・対照（無い表） --------------------------------------
new_nodb; P1_NODB="$NODB_NAME"
POS_TARGET[p1]="$DB.$NOSRC"
run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$P1_NODB" p1 \
  "CREATE TABLE awsdatacatalog.$P1_NODB.$(new_name p1) AS SELECT * FROM $DB.$NOSRC" "$(new_name p1)"
POS_TARGET[p1y]="$DB.$NOSRC"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" p1y \
  "CREATE TABLE $DB.$(new_name p1y) AS SELECT * FROM $DB.$NOSRC" "$DB.$(new_name p1y)"

# --- p2/p2y: 列が無い（位置は SELECT の直後）。<PROBE>_src が要る ---------------------------
if [ "$SRC_OK" = 1 ]; then
  new_nodb; P2_NODB="$NODB_NAME"
  POS_TARGET[p2]="nosuch272"
  run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$P2_NODB" p2 \
    "CREATE TABLE awsdatacatalog.$P2_NODB.$(new_name p2) AS SELECT nosuch272 FROM $DB.$SRC" "$(new_name p2)"
  POS_TARGET[p2y]="nosuch272"
  run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" p2y \
    "CREATE TABLE $DB.$(new_name p2y) AS SELECT nosuch272 FROM $DB.$SRC" "$DB.$(new_name p2y)"
else
  for l in p2 p2y; do
    skip "$l" "実在する表 <PROBE>_src を作れなかったため"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

# --- p3/p3y: 列が無い（同じ行のもっと右）。<PROBE>_src が要る -------------------------------
if [ "$SRC_OK" = 1 ]; then
  new_nodb; P3_NODB="$NODB_NAME"
  POS_TARGET[p3]="nosuch272"
  run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$P3_NODB" p3 \
    "CREATE TABLE awsdatacatalog.$P3_NODB.$(new_name p3) AS SELECT n, s, nosuch272 FROM $DB.$SRC" "$(new_name p3)"
  POS_TARGET[p3y]="nosuch272"
  run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" p3y \
    "CREATE TABLE $DB.$(new_name p3y) AS SELECT n, s, nosuch272 FROM $DB.$SRC" "$DB.$(new_name p3y)"
else
  for l in p3 p3y; do
    skip "$l" "実在する表 <PROBE>_src を作れなかったため"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

# --- p4/p4y: 複数行（本物の改行 LF）。WHERE の列が無い。<PROBE>_src が要る -------------------
if [ "$SRC_OK" = 1 ]; then
  new_nodb; P4_NODB="$NODB_NAME"
  POS_TARGET[p4]="nosuch272"
  run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$P4_NODB" p4 \
    "CREATE TABLE awsdatacatalog.$P4_NODB.$(new_name p4) AS
SELECT n
FROM $DB.$SRC
WHERE nosuch272 = 1" "$(new_name p4)"
  POS_TARGET[p4y]="nosuch272"
  run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" p4y \
    "CREATE TABLE $DB.$(new_name p4y) AS
SELECT n
FROM $DB.$SRC
WHERE nosuch272 = 1" "$DB.$(new_name p4y)"
else
  for l in p4 p4y; do
    skip "$l" "実在する表 <PROBE>_src を作れなかったため"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

# --- p5/p5y: AS の後の空白 4 つ（無い表） ---------------------------------------------------
new_nodb; P5_NODB="$NODB_NAME"
POS_TARGET[p5]="$DB.$NOSRC"
run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$P5_NODB" p5 \
  "CREATE TABLE awsdatacatalog.$P5_NODB.$(new_name p5) AS    SELECT * FROM $DB.$NOSRC" "$(new_name p5)"
POS_TARGET[p5y]="$DB.$NOSRC"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" p5y \
  "CREATE TABLE $DB.$(new_name p5y) AS    SELECT * FROM $DB.$NOSRC" "$DB.$(new_name p5y)"

# --- p6/p6y: 括弧（無い表） ------------------------------------------------------------------
new_nodb; P6_NODB="$NODB_NAME"
POS_TARGET[p6]="$DB.$NOSRC"
run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$P6_NODB" p6 \
  "CREATE TABLE awsdatacatalog.$P6_NODB.$(new_name p6) AS (SELECT * FROM $DB.$NOSRC)" "$(new_name p6)"
POS_TARGET[p6y]="$DB.$NOSRC"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" p6y \
  "CREATE TABLE $DB.$(new_name p6y) AS (SELECT * FROM $DB.$NOSRC)" "$DB.$(new_name p6y)"

# --- p7/p7y: WITH 句（無い表） ---------------------------------------------------------------
new_nodb; P7_NODB="$NODB_NAME"
POS_TARGET[p7]="$DB.$NOSRC"
run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$P7_NODB" p7 \
  "CREATE TABLE awsdatacatalog.$P7_NODB.$(new_name p7) AS WITH c AS (SELECT * FROM $DB.$NOSRC) SELECT * FROM c" "$(new_name p7)"
POS_TARGET[p7y]="$DB.$NOSRC"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" p7y \
  "CREATE TABLE $DB.$(new_name p7y) AS WITH c AS (SELECT * FROM $DB.$NOSRC) SELECT * FROM c" "$DB.$(new_name p7y)"

# --- p8/p8y: CTAS の WITH (format='PARQUET')（無い表） ---------------------------------------
new_nodb; P8_NODB="$NODB_NAME"
POS_TARGET[p8]="$DB.$NOSRC"
run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$P8_NODB" p8 \
  "CREATE TABLE awsdatacatalog.$P8_NODB.$(new_name p8) WITH (format = 'PARQUET') AS SELECT * FROM $DB.$NOSRC" "$(new_name p8)"
POS_TARGET[p8y]="$DB.$NOSRC"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" p8y \
  "CREATE TABLE $DB.$(new_name p8y) WITH (format = 'PARQUET') AS SELECT * FROM $DB.$NOSRC" "$DB.$(new_name p8y)"

# --- p9/p9y: CTAS の WITH (format=..., write_compression=...)（無い表） ----------------------
new_nodb; P9_NODB="$NODB_NAME"
POS_TARGET[p9]="$DB.$NOSRC"
run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$P9_NODB" p9 \
  "CREATE TABLE awsdatacatalog.$P9_NODB.$(new_name p9) WITH (format = 'PARQUET', write_compression = 'SNAPPY') AS SELECT * FROM $DB.$NOSRC" "$(new_name p9)"
POS_TARGET[p9y]="$DB.$NOSRC"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" p9y \
  "CREATE TABLE $DB.$(new_name p9y) WITH (format = 'PARQUET', write_compression = 'SNAPPY') AS SELECT * FROM $DB.$NOSRC" "$DB.$(new_name p9y)"

# --- p10/p10y: IF NOT EXISTS（無い表） --------------------------------------------------------
new_nodb; P10_NODB="$NODB_NAME"
POS_TARGET[p10]="$DB.$NOSRC"
run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$P10_NODB" p10 \
  "CREATE TABLE IF NOT EXISTS awsdatacatalog.$P10_NODB.$(new_name p10) AS SELECT * FROM $DB.$NOSRC" "$(new_name p10)"
POS_TARGET[p10y]="$DB.$NOSRC"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" p10y \
  "CREATE TABLE IF NOT EXISTS $DB.$(new_name p10y) AS SELECT * FROM $DB.$NOSRC" "$DB.$(new_name p10y)"

# --- p11/p11y: 先頭のコメント（無い表） -------------------------------------------------------
new_nodb; P11_NODB="$NODB_NAME"
POS_TARGET[p11]="$DB.$NOSRC"
run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$P11_NODB" p11 \
  "/* c */ CREATE TABLE awsdatacatalog.$P11_NODB.$(new_name p11) AS SELECT * FROM $DB.$NOSRC" "$(new_name p11)"
POS_TARGET[p11y]="$DB.$NOSRC"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" p11y \
  "/* c */ CREATE TABLE $DB.$(new_name p11y) AS SELECT * FROM $DB.$NOSRC" "$DB.$(new_name p11y)"

# --- p12/p12y: 型の不一致（1 + 'a'） ----------------------------------------------------------
new_nodb; P12_NODB="$NODB_NAME"
POS_TARGET[p12]="'a'"
run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$P12_NODB" p12 \
  "CREATE TABLE awsdatacatalog.$P12_NODB.$(new_name p12) AS SELECT 1 + 'a' AS n" "$(new_name p12)"
POS_TARGET[p12y]="'a'"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" p12y \
  "CREATE TABLE $DB.$(new_name p12y) AS SELECT 1 + 'a' AS n" "$DB.$(new_name p12y)"

# --- p13y: 1 部の名前（ある DB） --------------------------------------------------------------
POS_TARGET[p13y]="$DB.$NOSRC"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" p13y \
  "CREATE TABLE $(new_name p13y) AS SELECT * FROM $DB.$NOSRC" "$DB.$(new_name p13y)"

# --- p14y: 2 部の名前 --------------------------------------------------------------------------
POS_TARGET[p14y]="$DB.$NOSRC"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" p14y \
  "CREATE TABLE $DB.$(new_name p14y) AS SELECT * FROM $DB.$NOSRC" "$DB.$(new_name p14y)"

# --- p15y: WITH DATA（明示的な既定。無い表） --------------------------------------------------
POS_TARGET[p15y]="$DB.$NOSRC"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" p15y \
  "CREATE TABLE $DB.$(new_name p15y) AS SELECT * FROM $DB.$NOSRC WITH DATA" "$DB.$(new_name p15y)"

# --- w1/w1y: WITH NO DATA、CAST の失敗（issue のコメント） ------------------------------------
new_nodb; W1_NODB="$NODB_NAME"
POS_TARGET[w1]="'x'"
run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$W1_NODB" w1 \
  "CREATE TABLE awsdatacatalog.$W1_NODB.$(new_name w1) AS SELECT CAST('x' AS integer) AS n WITH NO DATA" "$(new_name w1)"
POS_TARGET[w1y]="'x'"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" w1y \
  "CREATE TABLE $DB.$(new_name w1y) AS SELECT CAST('x' AS integer) AS n WITH NO DATA" "$DB.$(new_name w1y)"

# --- w2/w2y: WITH NO DATA、無い表 --------------------------------------------------------------
new_nodb; W2_NODB="$NODB_NAME"
POS_TARGET[w2]="$DB.$NOSRC"
run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$W2_NODB" w2 \
  "CREATE TABLE awsdatacatalog.$W2_NODB.$(new_name w2) AS SELECT * FROM $DB.$NOSRC WITH NO DATA" "$(new_name w2)"
POS_TARGET[w2y]="$DB.$NOSRC"
run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" w2y \
  "CREATE TABLE $DB.$(new_name w2y) AS SELECT * FROM $DB.$NOSRC WITH NO DATA" "$DB.$(new_name w2y)"

# --- w3/w3y: WITH NO DATA、無い列。<PROBE>_src が要る -------------------------------------------
if [ "$SRC_OK" = 1 ]; then
  new_nodb; W3_NODB="$NODB_NAME"
  POS_TARGET[w3]="nosuch272"
  run_create_then_drop_ctx "$DEFAULT_CTX" "Catalog=$CATALOG,Database=$W3_NODB" w3 \
    "CREATE TABLE awsdatacatalog.$W3_NODB.$(new_name w3) AS SELECT nosuch272 FROM $DB.$SRC WITH NO DATA" "$(new_name w3)"
  POS_TARGET[w3y]="nosuch272"
  run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" w3y \
    "CREATE TABLE $DB.$(new_name w3y) AS SELECT nosuch272 FROM $DB.$SRC WITH NO DATA" "$DB.$(new_name w3y)"
else
  for l in w3 w3y; do
    skip "$l" "実在する表 <PROBE>_src を作れなかったため"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

# --- c1y: 対照（失敗しない見込み）。<PROBE>_src が要る -----------------------------------------
if [ "$SRC_OK" = 1 ]; then
  run_create_then_drop_ctx "$DEFAULT_CTX" "$DEFAULT_CTX" c1y \
    "CREATE TABLE $DB.$(new_name c1y) AS SELECT n FROM $DB.$SRC" "$DB.$(new_name c1y)"
else
  skip c1y "実在する表 <PROBE>_src を作れなかったため"
  skip c1y-cleanup "CREATE TABLE を投げていないため後始末不要"
fi

# --- i1/i2: INSERT の位置（別の文の種類で位置がずれるかの確認）。<PROBE>_src が要る -------------
if [ "$SRC_OK" = 1 ]; then
  POS_TARGET[i1]="nosuch272"
  run_in_ctx "$DEFAULT_CTX" i1 "INSERT INTO $DB.$SRC SELECT nosuch272, 'y' FROM $DB.$SRC"
  POS_TARGET[i2]="$DB.$NOSRC"
  run_in_ctx "$DEFAULT_CTX" i2 "INSERT INTO $DB.$SRC SELECT * FROM $DB.$NOSRC"
else
  skip i1 "実在する表 <PROBE>_src を作れなかったため"
  skip i2 "実在する表 <PROBE>_src を作れなかったため"
fi

P_LABELS="p1 p1y p2 p2y p3 p3y p4 p4y p5 p5y p6 p6y p7 p7y p8 p8y p9 p9y p10 p10y p11 p11y p12 p12y p13y p14y p15y"
W_LABELS="w1 w1y w2 w2y w3 w3y"
I_LABELS="i1 i2"

# --- 付随物の取得（FAILED になった項目だけ。結果ファイル本体・.metadata） -----------------------
fetch_failed_attachments $P_LABELS $W_LABELS c1y $I_LABELS
# --- CTAS が FAILED になった項目のオーファンデータ確認（ROUND=11 と共有。INSERT の i1・i2 は対象外） ---
for l in $P_LABELS $W_LABELS c1y; do
  is_failed "$l" && check_ctas_orphan_data "$l"
done

# --- 後始末（実在する表 <PROBE>_src） -----------------------------------------------------------
if [ "$SRC_OK" = 1 ]; then
  run_in_ctx "$DEFAULT_CTX" p-drop-src "DROP TABLE IF EXISTS $DB.$SRC"
  if succeeded p-drop-src; then
    SRC_OK=0
  else
    echo "== 実在する表 <PROBE>_src を消せませんでした。手で DROP TABLE IF EXISTS してください。"
  fi
else
  skip p-drop-src "実在する表を作れなかったため後始末不要"
fi

fi # ROUND=18
# ROUND=22 だけ、P 群を投げる（issue #279。#260 の無引用の awsdatacatalog.<db>.<t> の置換で
# 測れなかった／測っていない周辺を測る）。
if [ "$ROUND" = 22 ]; then

DEFAULT_CTX="Catalog=$CATALOG,Database=$DB"
NOCAT_CTX="Catalog=nosuchcatalog279,Database=$DB"
# LOCATION 付きの項目の置き場（probe_location_t・probe_location_q と同じ形。空のプレフィックス、
# 接頭辞を 279 にする）。
probe_location_p() { printf '%sathena-local-probe-279/%s/' "$OUTPUT" "$(new_name "$1")"; }

if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  S3T_CTX="Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS"
else
  S3T_CTX=""
fi

# 成功した SELECT の結果ファイル本体だけを取得する（列名の行は summary に出す）。
p_fetch_select() {
  succeeded "$1" || return 0
  fetch_s3_body "$(output_location_of "$1")" "$RUN_DIR/$1.output.txt" "$RUN_DIR/$1.output.txt.err"
}
# 成功した INSERT の直後に、同じ既定の Context で SELECT count(*) を投げて結果を取得する
# （行が増えたかは、前後の <label>-count の結果を summary で見比べれば分かる）。
p_insert_count() {
  local label=$1
  if succeeded "$label"; then
    run_in_ctx "$DEFAULT_CTX" "$label-count" "SELECT count(*) FROM $DB.$P_REAL"
    succeeded "$label-count" && fetch_s3_body "$(output_location_of "$label-count")" \
      "$RUN_DIR/$label-count.output.txt" "$RUN_DIR/$label-count.output.txt.err"
  else
    skip "$label-count" "INSERT が失敗したため件数確認不要"
  fi
}

# --- 準備: 実在する表 <PROBE>_p_real（Hive、1 行）・Iceberg 表 <PROBE>_p_ice（LOCATION 付き、
#     1 行）・ビュー <PROBE>_p_view -------------------------------------------------------
# 作ったものは最後の後始末で消す（途中で止めても trap の PENDING_DROPS・PENDING_DROPS_CTX が
# ベストエフォートで消しにいく）。
P_REAL="$(new_name p_real)"
P_ICE="$(new_name p_ice)"
P_ICE2="$(new_name p_ice2)"
P_VIEW="$(new_name p_view)"

PENDING_DROPS[$P_REAL]=1
run_in_ctx "$DEFAULT_CTX" p-setup-real "CREATE TABLE $DB.$P_REAL AS SELECT 1 AS n, 'x' AS s"

if [ "$P_INSERT_ONLY" = 1 ]; then
# --- ROUND=23: INSERT だけ（値は s が varchar(1) に収まる 1 文字） -----------------------------
# 最初の件数（1 行のはず）を取ってから、INSERT ごとに件数を取る（p_insert_count）。
run_in_ctx "$DEFAULT_CTX" p-base-count "SELECT count(*) FROM $DB.$P_REAL"
succeeded p-base-count && fetch_s3_body "$(output_location_of p-base-count)" \
  "$RUN_DIR/p-base-count.output.txt" "$RUN_DIR/p-base-count.output.txt.err"
# p35: 対照（1 部目無し、<DEF>）。
run_in_ctx "$DEFAULT_CTX" p35 "INSERT INTO $DB.$P_REAL VALUES (3, 'c')"
p_insert_count p35
# p36: #260 の o2 の再現（S3 Tables の Context の無引用の 3 部）。
if [ -n "$S3T_CTX" ]; then
  run_in_ctx "$S3T_CTX" p36 "INSERT INTO awsdatacatalog.$DB.$P_REAL VALUES (2, 'y')"
  p_insert_count p36
else
  skip p36 "S3TABLES_CATALOG・S3TABLES_NS が未設定"
  skip p36-count "INSERT を投げていないため件数確認不要"
fi
# p37: #260 の o5 の再現（実在しないカタログの Context）。
run_in_ctx "$NOCAT_CTX" p37 "INSERT INTO awsdatacatalog.$DB.$P_REAL VALUES (5, 'z')"
p_insert_count p37
# p2・p4: ROUND=22 と同じ文（値だけ 1 文字）。
resolve_federated_catalog p
if [ -n "$FC" ]; then
  GCTX="Catalog=$FC,Database=$DB"
  run_in_ctx "$GCTX" p2 "INSERT INTO awsdatacatalog.$DB.$P_REAL VALUES (20, 'g')"
  p_insert_count p2
  run_in_ctx "$DEFAULT_CTX" p4 "INSERT INTO ${FC^^}.$DB.$P_REAL VALUES (21, 'h')"
  p_insert_count p4
else
  skip p2 "$FEDCAT_SKIP_REASON"
  skip p2-count "連携カタログが使えないため件数確認不要"
  skip p4 "$FEDCAT_SKIP_REASON"
  skip p4-count "連携カタログが使えないため件数確認不要"
fi
# p27・p28: ROUND=22 と同じ文（値だけ 1 文字）。
run_in_ctx "$DEFAULT_CTX" p27 "INSERT INTO awsdatacatalog.\"$DB\".$P_REAL VALUES (30, 'q')"
p_insert_count p27
run_in_ctx "$DEFAULT_CTX" p28 "INSERT INTO awsdatacatalog.$DB.\"$P_REAL\" VALUES (31, 'r')"
p_insert_count p28

P_LABELS="p35 p36 p37 p2 p4 p27 p28"
fetch_failed_attachments $P_LABELS
run_in_ctx "$DEFAULT_CTX" p-drop-real "DROP TABLE IF EXISTS $DB.$P_REAL"
succeeded p-drop-real && unset "PENDING_DROPS[$P_REAL]"
delete_glue_catalog_if_created p

else
PENDING_DROPS[$P_ICE]=1
PENDING_DROPS[$P_ICE2]=1
run_in_ctx "$DEFAULT_CTX" p-setup-ice \
  "CREATE TABLE $DB.$P_ICE (n int, s string) LOCATION '$(probe_location_p ice)' TBLPROPERTIES ('table_type'='ICEBERG')"
run_in_ctx "$DEFAULT_CTX" p-setup-ice-insert "INSERT INTO $DB.$P_ICE VALUES (1, 'x')"
PENDING_DROPS_CTX["$DEFAULT_CTX|$P_VIEW"]=1
run_in_ctx "$DEFAULT_CTX" p-setup-view "CREATE VIEW $DB.$P_VIEW AS SELECT 1 AS n"

# --- 対照（各群で参照する、同じラウンドの基準） ---------------------------------------
# p0: <DEF> での成功の対照。p0b: Context の Catalog 省略（Database=<DB> だけ）で #260 の
# o1 の形（SELECT * FROM awsdatacatalog.<DB>.<t>）を再現する（<G>・S3TABLES_* の有無に
# よらず投げられる）。
run_in_ctx "$DEFAULT_CTX" p0 "SELECT * FROM awsdatacatalog.$DB.$P_REAL"
p_fetch_select p0
run_in_ctx "Database=$DB" p0b "SELECT * FROM awsdatacatalog.$DB.$P_REAL"
p_fetch_select p0b

# --- issue の 1: 連携カタログ <G>（CREATE_GLUE_CATALOG=1 かつ FEDERATED_CATALOG 未設定なら
#     自分のアカウントの Glue を指すデータカタログを一時的に作る。ROUND=13・14・17 と共有する
#     resolve_federated_catalog をそのまま使う） -----------------------------------------
resolve_federated_catalog p

if [ -n "$FC" ]; then
  GCTX="Catalog=$FC,Database=$DB"
  # <GCTX> で無引用の 3 部（o3・o4 の再現）。
  run_in_ctx "$GCTX" p1 "SELECT * FROM awsdatacatalog.$DB.$P_REAL"
  p_fetch_select p1
  run_in_ctx "$GCTX" p2 "INSERT INTO awsdatacatalog.$DB.$P_REAL VALUES (20, 'g')"
  p_insert_count p2
  # <DEF> で <G> を無引用の大文字混じりで書いた別名キー（o9 の再現）。
  run_in_ctx "$DEFAULT_CTX" p3 "SELECT * FROM ${FC^^}.$DB.$P_REAL"
  p_fetch_select p3
  run_in_ctx "$DEFAULT_CTX" p4 "INSERT INTO ${FC^^}.$DB.$P_REAL VALUES (21, 'h')"
  p_insert_count p4
else
  skip p1 "$FEDCAT_SKIP_REASON"
  skip p2 "$FEDCAT_SKIP_REASON"
  skip p2-count "連携カタログが使えないため件数確認不要"
  skip p3 "$FEDCAT_SKIP_REASON"
  skip p4 "$FEDCAT_SKIP_REASON"
  skip p4-count "連携カタログが使えないため件数確認不要"
fi

# --- issue の 2: <DEF> のほかの文（1 部目が無引用の awsdatacatalog） ------------------------
# DELETE・UPDATE・MERGE は行を変えないよう、存在しない値（n = 999）を対象にした無害な
# no-op にする（対照は 1 部なしの <DB>.<PROBE>_p_ice）。
run_in_ctx "$DEFAULT_CTX" p5  "DELETE FROM awsdatacatalog.$DB.$P_ICE WHERE n = 999"
run_in_ctx "$DEFAULT_CTX" p5c "DELETE FROM $DB.$P_ICE WHERE n = 999"
run_in_ctx "$DEFAULT_CTX" p6  "UPDATE awsdatacatalog.$DB.$P_ICE SET s = 'z' WHERE n = 999"
run_in_ctx "$DEFAULT_CTX" p6c "UPDATE $DB.$P_ICE SET s = 'z' WHERE n = 999"
run_in_ctx "$DEFAULT_CTX" p7  "MERGE INTO awsdatacatalog.$DB.$P_ICE t USING (SELECT 999 AS n) s ON t.n = s.n WHEN MATCHED THEN UPDATE SET s = 'z'"
run_in_ctx "$DEFAULT_CTX" p7c "MERGE INTO $DB.$P_ICE t USING (SELECT 999 AS n) s ON t.n = s.n WHEN MATCHED THEN UPDATE SET s = 'z'"

# SHOW CREATE VIEW は DROP VIEW より前に投げる。
run_in_ctx "$DEFAULT_CTX" p8 "SHOW CREATE VIEW awsdatacatalog.$DB.$P_VIEW"
run_in_ctx "$DEFAULT_CTX" p9 "DROP VIEW IF EXISTS awsdatacatalog.$DB.$(new_name p_nosuch)"
run_in_ctx "$DEFAULT_CTX" p10 "DROP VIEW awsdatacatalog.$DB.$P_VIEW"
succeeded p10 && unset "PENDING_DROPS_CTX[$DEFAULT_CTX|$P_VIEW]"

# ALTER TABLE ... RENAME TO の 3 つの形。受理されたら次の項目の前に必ず名前を戻す
# （どの形が実際に効いたかを確かめるため、1 つずつ試す）。
run_in_ctx "$DEFAULT_CTX" p11 "ALTER TABLE awsdatacatalog.$DB.$P_ICE RENAME TO awsdatacatalog.$DB.$P_ICE2"
if succeeded p11; then
  run_in_ctx "$DEFAULT_CTX" p11-revert "ALTER TABLE $DB.$P_ICE2 RENAME TO $DB.$P_ICE"
  succeeded p11-revert || echo "== p11 で名前を戻せませんでした。$DB の <PROBE>_p_ice/<PROBE>_p_ice2 を確認してください。"
else
  skip p11-revert "RENAME が失敗したため後始末不要"
fi
run_in_ctx "$DEFAULT_CTX" p12 "ALTER TABLE $DB.$P_ICE RENAME TO awsdatacatalog.$DB.$P_ICE2"
if succeeded p12; then
  run_in_ctx "$DEFAULT_CTX" p12-revert "ALTER TABLE $DB.$P_ICE2 RENAME TO $DB.$P_ICE"
  succeeded p12-revert || echo "== p12 で名前を戻せませんでした。$DB の <PROBE>_p_ice/<PROBE>_p_ice2 を確認してください。"
else
  skip p12-revert "RENAME が失敗したため後始末不要"
fi
# 対照（1 部なし）。
run_in_ctx "$DEFAULT_CTX" p13 "ALTER TABLE $DB.$P_ICE RENAME TO $DB.$P_ICE2"
if succeeded p13; then
  run_in_ctx "$DEFAULT_CTX" p13-revert "ALTER TABLE $DB.$P_ICE2 RENAME TO $DB.$P_ICE"
  succeeded p13-revert || echo "== p13 で名前を戻せませんでした。$DB の <PROBE>_p_ice/<PROBE>_p_ice2 を確認してください。"
else
  skip p13-revert "RENAME が失敗したため後始末不要"
fi

run_in_ctx "$DEFAULT_CTX" p14 "SHOW COLUMNS FROM awsdatacatalog.$DB.$P_REAL"
run_in_ctx "$DEFAULT_CTX" p15 "SHOW TBLPROPERTIES awsdatacatalog.$DB.$P_REAL"
run_in_ctx "$DEFAULT_CTX" p16 "SHOW PARTITIONS awsdatacatalog.$DB.$P_REAL"

# --- issue の 3: <S3CTX>・<NOCAT> の Context で SELECT・INSERT 以外の文と、引用符付きの
#     部品を含む名前 --------------------------------------------------------------------
if [ -n "$S3T_CTX" ]; then
  run_in_ctx "$S3T_CTX" p17 "EXPLAIN SELECT * FROM awsdatacatalog.$DB.$P_REAL"
else
  skip p17 "未測定（S3TABLES_* 未設定）"
fi
run_in_ctx "$NOCAT_CTX" p18 "EXPLAIN SELECT * FROM awsdatacatalog.$DB.$P_REAL"

if [ -n "$S3T_CTX" ]; then
  run_create_then_drop_ctx "$S3T_CTX" "$S3T_CTX" p19 \
    "CREATE TABLE $S3TABLES_NS.$(new_name p19) AS SELECT * FROM awsdatacatalog.$DB.$P_REAL" \
    "$S3TABLES_NS.$(new_name p19)"
else
  skip p19 "未測定（S3TABLES_* 未設定）"
  skip p19-cleanup "CREATE TABLE を投げていないため後始末不要"
fi
# 対象 DB は文中で <DB> を明示するので、<NOCAT> の Context でも既定の DB に作られうる
# （作れなければ既定の Context で消す。r 群と同じ考え方）。
run_create_then_drop_ctx "$NOCAT_CTX" "$DEFAULT_CTX" p20 \
  "CREATE TABLE $DB.$(new_name p20) AS SELECT * FROM awsdatacatalog.$DB.$P_REAL" \
  "$DB.$(new_name p20)"

if [ -n "$S3T_CTX" ]; then
  if run_in_ctx "$S3T_CTX" p21 "CREATE VIEW $S3TABLES_NS.$(new_name p21) AS SELECT * FROM awsdatacatalog.$DB.$P_REAL"; then
    PENDING_DROPS_CTX["$S3T_CTX|$(new_name p21)"]=1
    run_in_ctx "$S3T_CTX" p21-cleanup "DROP VIEW IF EXISTS $S3TABLES_NS.$(new_name p21)"
    succeeded p21-cleanup && unset "PENDING_DROPS_CTX[$S3T_CTX|$(new_name p21)]"
  else
    skip p21-cleanup "CREATE VIEW が失敗したため後始末不要"
  fi
else
  skip p21 "未測定（S3TABLES_* 未設定）"
  skip p21-cleanup "CREATE VIEW を投げていないため後始末不要"
fi
if run_in_ctx "$NOCAT_CTX" p22 "CREATE VIEW $DB.$(new_name p22) AS SELECT * FROM awsdatacatalog.$DB.$P_REAL"; then
  PENDING_DROPS_CTX["$DEFAULT_CTX|$(new_name p22)"]=1
  run_in_ctx "$DEFAULT_CTX" p22-cleanup "DROP VIEW IF EXISTS $DB.$(new_name p22)"
  succeeded p22-cleanup && unset "PENDING_DROPS_CTX[$DEFAULT_CTX|$(new_name p22)]"
else
  skip p22-cleanup "CREATE VIEW が失敗したため後始末不要"
fi

if [ -n "$S3T_CTX" ]; then
  run_in_ctx "$S3T_CTX" p23 "SELECT * FROM awsdatacatalog.\"$DB\".$P_REAL"
  p_fetch_select p23
  run_in_ctx "$S3T_CTX" p24 "SELECT * FROM awsdatacatalog.$DB.\"$P_REAL\""
  p_fetch_select p24
else
  skip p23 "未測定（S3TABLES_* 未設定）"
  skip p24 "未測定（S3TABLES_* 未設定）"
fi
run_in_ctx "$NOCAT_CTX" p25 "SELECT * FROM awsdatacatalog.\"$DB\".$P_REAL"
p_fetch_select p25
run_in_ctx "$NOCAT_CTX" p26 "SELECT * FROM awsdatacatalog.$DB.\"$P_REAL\""
p_fetch_select p26

# --- issue の 4: <DEF> の INSERT の引用符付きの部品 -----------------------------------------
run_in_ctx "$DEFAULT_CTX" p27 "INSERT INTO awsdatacatalog.\"$DB\".$P_REAL VALUES (30, 'q')"
p_insert_count p27
run_in_ctx "$DEFAULT_CTX" p28 "INSERT INTO awsdatacatalog.$DB.\"$P_REAL\" VALUES (31, 'r')"
p_insert_count p28

# --- issue の 5: <DEF> の SELECT（引用符付きが 2 つ・4 部の列の参照・o8 の再現） ------------------
run_in_ctx "$DEFAULT_CTX" p29 "SELECT * FROM awsdatacatalog.\"$DB\".\"$P_REAL\""
p_fetch_select p29
run_in_ctx "$DEFAULT_CTX" p30 "SELECT awsdatacatalog.$DB.$P_REAL.\"n\" FROM awsdatacatalog.$DB.$P_REAL"
p_fetch_select p30
run_in_ctx "$DEFAULT_CTX" p31 "SELECT awsdatacatalog.\"$DB\".$P_REAL.n FROM awsdatacatalog.$DB.$P_REAL"
p_fetch_select p31
# o8 の再現（引用符無し）。
run_in_ctx "$DEFAULT_CTX" p32 "SELECT awsdatacatalog.$DB.$P_REAL.n FROM awsdatacatalog.$DB.$P_REAL"
p_fetch_select p32

P_LABELS="p0 p0b p1 p2 p3 p4 p5 p5c p6 p6c p7 p7c p8 p9 p10 p11 p12 p13 p14 p15 p16 p17 p18 p19 p20 p21 p22 p23 p24 p25 p26 p27 p28 p29 p30 p31 p32"

# --- 付随物の取得（FAILED になった項目だけ。結果ファイルの有無の証拠になる） ------------------
fetch_failed_attachments $P_LABELS

# --- 後始末（作ったものを消す） ---------------------------------------------------------
run_in_ctx "$DEFAULT_CTX" p-drop-ice "DROP TABLE IF EXISTS $DB.$P_ICE"
succeeded p-drop-ice && unset "PENDING_DROPS[$P_ICE]"
run_in_ctx "$DEFAULT_CTX" p-drop-ice2 "DROP TABLE IF EXISTS $DB.$P_ICE2"
succeeded p-drop-ice2 && unset "PENDING_DROPS[$P_ICE2]"
run_in_ctx "$DEFAULT_CTX" p-drop-real "DROP TABLE IF EXISTS $DB.$P_REAL"
succeeded p-drop-real && unset "PENDING_DROPS[$P_REAL]"
# p10 が SUCCEEDED でも、そうでなくても IF EXISTS で確実に消しにいく（M 群の m-drop-v と同じ考え方）。
run_in_ctx "$DEFAULT_CTX" p-drop-view "DROP VIEW IF EXISTS $DB.$P_VIEW"
succeeded p-drop-view && unset "PENDING_DROPS_CTX[$DEFAULT_CTX|$P_VIEW]"

# 連携カタログ（CREATE_GLUE_CATALOG=1 で作ったもの）は、表・ビューを消したこのあとに明示的に
# 消す（共有関数。結果を summary に出す。消せなければ trap がもう一度ベストエフォートで消しにいく）。
delete_glue_catalog_if_created p

fi # P_INSERT_ONLY
fi # ROUND=22

# ROUND=19 だけ、d・f・c 群を投げる（issue #273）。preflight・DB 確認は共通で走るが、
# 実在する表 <PROBE>_real は作らない。
if [ "$ROUND" = 19 ]; then

if [ -z "$S3TABLES_CATALOG" ] || [ -z "$S3TABLES_NS" ]; then
  echo
  echo "########################################################################"
  echo "# ROUND=19（issue #273）は S3TABLES_CATALOG・S3TABLES_NS が無いと、"
  echo "# 準備（実在する表 <DB>.<PROBE>_src の作成/削除）以外ほぼ何も測れません。"
  echo "# d・f・c 群はすべて「未測定（S3TABLES_* 未設定）」になります。"
  echo "########################################################################"
  echo
fi

DEFAULT_CTX="Catalog=$CATALOG,Database=$DB"
# S3 Tables に無い名前空間（乱数入りの接頭辞なので実在しない見込み）。
NOPE_NS="$(new_name nope_ns)"
# f4: 先頭の athena を大文字にした綴り（NOPE_NS は "<PROBE_PREFIX>_nope_ns" で、PROBE_PREFIX は
# 常に "athena_local_probe_208_<乱数>" なので、先頭の "athena" だけ大文字にする。issue の
# コメントの例と同じ形。理由に書かれる名前空間が書いたとおりか小文字かを見る）。
NOPE_NS_UPPER="ATHENA${NOPE_NS:6}"

# --- 準備: 実在する Glue の表 <DB>.<PROBE>_src（S3TABLES_* によらず作る。作れなければ
# f10 だけ未測定にする） ---------------------------------------------------------------
SRC_TABLE="$(new_name src)"
SRC_OK=0
if run_in_ctx "$DEFAULT_CTX" v-setup-src "CREATE TABLE $DB.$SRC_TABLE AS SELECT 1 AS n"; then
  SRC_OK=1
else
  echo "== v-setup-src: 実在する表 <DB>.<PROBE>_src を作れませんでした。f10 は未測定にします。"
fi

if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  S3_CTX="Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS"
  S3NOPE_CTX="Catalog=$S3TABLES_CATALOG,Database=$NOPE_NS"
  S3NODB_CTX="Catalog=$S3TABLES_CATALOG"
  # バッククォート 1 文字（f11。二重引用符と違い、これをそのまま埋め込むと bash のコマンド
  # 置換になってしまうので変数にする。ROUND=10 の s11 と同じ考え方）。
  BT='`'

  # --- <S3NODB> で作った表の後始末（issue 本文どおり、まず同じ <S3NODB> で、失敗すれば
  # <S3> でもう一度 DROP TABLE IF EXISTS を試みる。どちらも消せなければ PENDING_DROPS_CTX に
  # 残り、summary 冒頭の「手で消してください」＝要手動削除に載る） -----------------------
  run_create_then_drop_nodb() {
    local label=$1 sql=$2 name=$3
    local key="$S3NODB_CTX|$name"
    if run_in_ctx "$S3NODB_CTX" "$label" "$sql"; then
      PENDING_DROPS_CTX[$key]=1
      run_in_ctx "$S3NODB_CTX" "$label-cleanup" "DROP TABLE IF EXISTS $name"
      if succeeded "$label-cleanup"; then
        unset 'PENDING_DROPS_CTX[$key]'
      else
        run_in_ctx "$S3_CTX" "$label-cleanup2" "DROP TABLE IF EXISTS $name"
        if succeeded "$label-cleanup2"; then
          unset 'PENDING_DROPS_CTX[$key]'
        fi
      fi
    else
      skip "$label-cleanup" "CREATE TABLE が失敗したため後始末不要"
    fi
  }

  # --- D 群: Database を省略した Context（<S3NODB>） -----------------------------------
  run_in_ctx "$S3NODB_CTX" d0 "SELECT 1"
  run_create_then_drop_nodb d1 "CREATE TABLE $(new_name d1) (n int)" "$(new_name d1)"
  run_create_then_drop_nodb d2 "CREATE TABLE $(new_name d2) AS SELECT 1 AS n" "$(new_name d2)"
  run_create_then_drop_nodb d3 "CREATE TABLE $S3TABLES_NS.$(new_name d3) AS SELECT 1 AS n" "$S3TABLES_NS.$(new_name d3)"
  run_create_then_drop_nodb d4 "CREATE TABLE $NOPE_NS.$(new_name d4) AS SELECT 1 AS n" "$NOPE_NS.$(new_name d4)"
  D_LABELS="d0 d1 d2 d3 d4"

  # --- F 群: 名前空間が無い CTAS の残りの形 ---------------------------------------------
  run_create_then_drop_ctx "$S3NOPE_CTX" "$S3NOPE_CTX" f1 \
    "CREATE TABLE $(new_name f1) AS SELECT 1 AS n" "$(new_name f1)"
  run_create_then_drop_ctx "$S3_CTX" "$S3_CTX" f2 \
    "CREATE TABLE $NOPE_NS.$(new_name f2) AS SELECT 1 AS n" "$NOPE_NS.$(new_name f2)"
  run_create_then_drop_ctx "$S3_CTX" "$S3_CTX" f3 \
    "CREATE TABLE IF NOT EXISTS $NOPE_NS.$(new_name f3) AS SELECT 1 AS n" "$NOPE_NS.$(new_name f3)"
  run_create_then_drop_ctx "$S3_CTX" "$S3_CTX" f4 \
    "CREATE TABLE $NOPE_NS_UPPER.$(new_name f4) AS SELECT 1 AS n" "$NOPE_NS_UPPER.$(new_name f4)"
  run_create_then_drop_ctx "$S3_CTX" "$S3_CTX" f5 \
    "CREATE TABLE $NOPE_NS.$(new_name f5) AS SELECT 1 AS n WITH NO DATA" "$NOPE_NS.$(new_name f5)"
  run_create_then_drop_ctx "$S3_CTX" "$S3_CTX" f6 \
    "CREATE TABLE $NOPE_NS.$(new_name f6) AS SELECT CAST('x' AS integer) AS n" "$NOPE_NS.$(new_name f6)"
  run_create_then_drop_ctx "$S3_CTX" "$S3_CTX" f7 \
    "CREATE TABLE $NOPE_NS.$(new_name f7) AS SELECT * FROM $S3TABLES_NS.$(new_name nosrc)" "$NOPE_NS.$(new_name f7)"
  run_create_then_drop_ctx "$S3_CTX" "$S3_CTX" f8 \
    "CREATE TABLE $NOPE_NS.$(new_name f8) WITH (format = 'PARQUET') AS SELECT 1 AS n" "$NOPE_NS.$(new_name f8)"
  run_create_then_drop_ctx "$S3_CTX" "$S3_CTX" f9 \
    "CREATE TABLE $DB.$(new_name f9) AS SELECT 1 AS n" "$DB.$(new_name f9)"
  if [ "$SRC_OK" = 1 ]; then
    run_create_then_drop_ctx "$S3NOPE_CTX" "$S3NOPE_CTX" f10 \
      "CREATE TABLE $(new_name f10) AS SELECT n FROM awsdatacatalog.$DB.$SRC_TABLE" "$(new_name f10)"
  else
    skip f10 "実在する表を作れなかったため"
    skip f10-cleanup "CREATE TABLE を投げていないため後始末不要"
  fi
  run_create_then_drop_ctx "$S3_CTX" "$S3_CTX" f11 \
    "CREATE TABLE ${BT}$NOPE_NS${BT}.$(new_name f11) AS SELECT 1 AS n" "${BT}$NOPE_NS${BT}.$(new_name f11)"
  run_create_then_drop_ctx "$S3_CTX" "$S3_CTX" f12 \
    "CREATE TABLE \"$NOPE_NS\".$(new_name f12) AS SELECT 1 AS n" "\"$NOPE_NS\".$(new_name f12)"
  F_LABELS="f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12"

  # --- C 群: 対照 -----------------------------------------------------------------------
  # c1: t18 の再現（SUCCEEDED の見込み → 消す）。c2: #251 で分かっている非 CTAS の形
  # （Cannot find or access the specified table）。
  run_create_then_drop_ctx "$S3_CTX" "$S3_CTX" c1 \
    "CREATE TABLE $S3TABLES_NS.$(new_name c1) AS SELECT 1 AS n" "$S3TABLES_NS.$(new_name c1)"
  run_create_then_drop_ctx "$S3_CTX" "$S3_CTX" c2 \
    "CREATE TABLE $NOPE_NS.$(new_name c2) (n int)" "$NOPE_NS.$(new_name c2)"
  C_LABELS="c1 c2"
else
  skip d0 "未測定（S3TABLES_* 未設定）"
  for l in d1 d2 d3 d4; do
    skip "$l" "未測定（S3TABLES_* 未設定）"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
  for l in f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12 c1 c2; do
    skip "$l" "未測定（S3TABLES_* 未設定）"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
  D_LABELS="d0 d1 d2 d3 d4"
  F_LABELS="f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12"
  C_LABELS="c1 c2"
fi

# --- 後始末: 実在する Glue の表 <DB>.<PROBE>_src --------------------------------------
if [ "$SRC_OK" = 1 ]; then
  run_in_ctx "$DEFAULT_CTX" v-cleanup-src "DROP TABLE IF EXISTS $DB.$SRC_TABLE"
  if succeeded v-cleanup-src; then
    SRC_OK=0
  else
    echo "== 実在する表 <DB>.<PROBE>_src を消せませんでした。手で DROP TABLE IF EXISTS してください。"
  fi
else
  skip v-cleanup-src "実在する表を作れなかったため後始末不要"
fi

# --- 付随物の取得（FAILED になった CTAS の項目だけ、オーファンデータも確認） ----------------
fetch_failed_attachments $D_LABELS $F_LABELS $C_LABELS
for l in d2 d3 d4 f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12 c1; do
  is_failed "$l" && check_ctas_orphan_data "$l"
done

fi # ROUND=19

# ROUND=20 だけ、k・v・c・a・m 群と対照 x0 を投げる（issue #270 の 2 ラウンド目。ROUND=16 の続きで、
# TBLPROPERTIES のキーの範囲・table_type の値と組・列リスト無しの形・ちょうど小文字の
# awsdatacatalog の 3 部・名前空間が無いときとの優先順を測る。ROUND=18 は #272、19 は
# #273 の実測が使う）。すべて S3 Tables の Context（Catalog=$S3TABLES_CATALOG,
# Database=$S3TABLES_NS。m5 だけ Database を <NOPE> にする）だけに投げ、LOCATION は付けない。
# S3TABLES_* が揃わなければ全項目「未測定」として残す。
if [ "$ROUND" = 20 ]; then

X0_LABEL="x0"
K_LABELS="k1 k2 k3 k4 k5 k6 k7 k8"
V_LABELS="v1 v2 v3 v4 v5 v6"
C_LABELS="c1 c2 c3 c4"
A_LABELS="a1 a2 a3 a4 a5"
M_LABELS="m0 m1 m2 m3 m4 m5 m6 m7"

if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
  S3T_CTX="Catalog=$S3TABLES_CATALOG,Database=$S3TABLES_NS"
  # 実在しない名前空間（乱数入りの接頭辞なので実在しない見込み）。
  NOPE270="$(new_name nope270)"

  # --- 対照（ROUND=16 の cl0 と同じ形。SUCCEEDED の見込み） ---
  run_create_then_drop_ctx_showcreate "$S3T_CTX" x0 \
    "CREATE TABLE $(new_name x0) (n int)" "$(new_name x0)"

  # --- k 群（TBLPROPERTIES のキーの範囲） ---
  run_create_then_drop_ctx_showcreate "$S3T_CTX" k1 \
    "CREATE TABLE $(new_name k1) (n int) TBLPROPERTIES ('vacuum_max_snapshot_age_seconds'='432000')" "$(new_name k1)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" k2 \
    "CREATE TABLE $(new_name k2) (n int) TBLPROPERTIES ('vacuum_min_snapshots_to_keep'='1')" "$(new_name k2)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" k3 \
    "CREATE TABLE $(new_name k3) (n int) TBLPROPERTIES ('optimize_rewrite_delete_file_threshold'='2')" "$(new_name k3)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" k4 \
    "CREATE TABLE $(new_name k4) (n int) TBLPROPERTIES ('write_target_data_file_size_bytes'='536870912')" "$(new_name k4)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" k5 \
    "CREATE TABLE $(new_name k5) (n int) TBLPROPERTIES ('compression_level'='3')" "$(new_name k5)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" k6 \
    "CREATE TABLE $(new_name k6) (n int) TBLPROPERTIES ('classification'='csv')" "$(new_name k6)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" k7 \
    "CREATE TABLE $(new_name k7) (n int) TBLPROPERTIES ('a270x'='b', 'a270y'='c')" "$(new_name k7)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" k8 \
    "CREATE TABLE $(new_name k8) (n int) TBLPROPERTIES ('A270'='b')" "$(new_name k8)"

  # --- v 群（table_type の値と組） ---
  run_create_then_drop_ctx_showcreate "$S3T_CTX" v1 \
    "CREATE TABLE $(new_name v1) (n int) TBLPROPERTIES ('table_type'='hive')" "$(new_name v1)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" v2 \
    "CREATE TABLE $(new_name v2) (n int) TBLPROPERTIES ('table_type'='DELTA')" "$(new_name v2)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" v3 \
    "CREATE TABLE $(new_name v3) (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde' TBLPROPERTIES ('table_type'='HIVE')" "$(new_name v3)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" v4 \
    "CREATE TABLE $(new_name v4) (n int) PARTITIONED BY (p int) TBLPROPERTIES ('table_type'='HIVE')" "$(new_name v4)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" v5 \
    "CREATE TABLE $(new_name v5) (n int) TBLPROPERTIES ('table_type'='HIVE', 'a270'='b')" "$(new_name v5)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" v6 \
    "CREATE TABLE $(new_name v6) TBLPROPERTIES ('table_type'='HIVE')" "$(new_name v6)"

  # --- c 群（列リスト無し） ---
  run_create_then_drop_ctx_showcreate "$S3T_CTX" c1 \
    "CREATE TABLE $(new_name c1)" "$(new_name c1)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" c2 \
    "CREATE TABLE $(new_name c2) TBLPROPERTIES ('table_type'='ICEBERG')" "$(new_name c2)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" c3 \
    "CREATE TABLE $(new_name c3) PARTITIONED BY (p int)" "$(new_name c3)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" c4 \
    "CREATE TABLE $(new_name c4) COMMENT 't comment'" "$(new_name c4)"

  # --- a 群（ちょうど小文字の awsdatacatalog の 3 部。名前は awsdatacatalog.$S3TABLES_NS.<t>） ---
  run_create_then_drop_ctx_showcreate "$S3T_CTX" a1 \
    "CREATE TABLE awsdatacatalog.$S3TABLES_NS.$(new_name a1) (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'" \
    "awsdatacatalog.$S3TABLES_NS.$(new_name a1)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" a2 \
    "CREATE TABLE awsdatacatalog.$S3TABLES_NS.$(new_name a2) (n int) CLUSTERED BY (n) INTO 4 BUCKETS" \
    "awsdatacatalog.$S3TABLES_NS.$(new_name a2)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" a3 \
    "CREATE TABLE awsdatacatalog.$S3TABLES_NS.$(new_name a3) (n int) PARTITIONED BY (p int)" \
    "awsdatacatalog.$S3TABLES_NS.$(new_name a3)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" a4 \
    "CREATE TABLE awsdatacatalog.$S3TABLES_NS.$(new_name a4) (n int) TBLPROPERTIES ('a270'='b')" \
    "awsdatacatalog.$S3TABLES_NS.$(new_name a4)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" a5 \
    "CREATE TABLE awsdatacatalog.$S3TABLES_NS.$(new_name a5) (n int) TBLPROPERTIES ('table_type'='HIVE')" \
    "awsdatacatalog.$S3TABLES_NS.$(new_name a5)"

  # --- m 群（名前空間が無いときとの優先。m0 は #231 の i2・j12 と同じ形の対照） ---
  run_create_then_drop_ctx_showcreate "$S3T_CTX" m0 \
    "CREATE TABLE $NOPE270.$(new_name m0) (n int)" "$NOPE270.$(new_name m0)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" m1 \
    "CREATE TABLE $NOPE270.$(new_name m1) (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'" \
    "$NOPE270.$(new_name m1)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" m2 \
    "CREATE TABLE $NOPE270.$(new_name m2) (n int) STORED AS PARQUET" "$NOPE270.$(new_name m2)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" m3 \
    "CREATE TABLE $NOPE270.$(new_name m3) (n int) PARTITIONED BY (p int)" "$NOPE270.$(new_name m3)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" m4 \
    "CREATE TABLE $NOPE270.$(new_name m4) (n int) TBLPROPERTIES ('a270'='b')" "$NOPE270.$(new_name m4)"
  run_create_then_drop_ctx_showcreate "Catalog=$S3TABLES_CATALOG,Database=$NOPE270" m5 \
    "CREATE TABLE $(new_name m5) (n int) CLUSTERED BY (n) INTO 4 BUCKETS" "$(new_name m5)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" m6 \
    "CREATE TABLE AwsDataCatalog.$NOPE270.$(new_name m6) (n int) ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'" \
    "AwsDataCatalog.$NOPE270.$(new_name m6)"
  run_create_then_drop_ctx_showcreate "$S3T_CTX" m7 \
    "CREATE TABLE $NOPE270.$(new_name m7) (n int) TBLPROPERTIES ('table_type'='HIVE')" "$NOPE270.$(new_name m7)"
else
  for l in $X0_LABEL $K_LABELS $V_LABELS $C_LABELS $A_LABELS $M_LABELS; do
    skip "$l" "未測定（S3TABLES_* 未設定）"
    skip "$l-showcreate" "CREATE TABLE を投げていないため SHOW CREATE TABLE 不要"
    skip "$l-cleanup" "CREATE TABLE を投げていないため後始末不要"
  done
fi

# SHOW CREATE TABLE のラベル一覧（付随物の取得・summary で使う）。
SC_LABELS=""
for l in $X0_LABEL $K_LABELS $V_LABELS $C_LABELS $A_LABELS $M_LABELS; do
  SC_LABELS="$SC_LABELS $l-showcreate"
done

# --- 付随物の取得（FAILED になった項目だけ。SHOW CREATE TABLE の結果本体は
# run_create_then_drop_ctx_showcreate の中で受理された項目ごとに取得済み） -----------------
fetch_failed_attachments $X0_LABEL $K_LABELS $V_LABELS $C_LABELS $A_LABELS $M_LABELS $SC_LABELS

fi # ROUND=20

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
elif [ "$ROUND" = 10 ]; then
  for l in $S_LABELS; do
    ALL_LABELS="$ALL_LABELS $l $l-cleanup"
  done
elif [ "$ROUND" = 11 ]; then
  for l in $R_LABELS; do
    ALL_LABELS="$ALL_LABELS $l $l-cleanup"
  done
elif [ "$ROUND" = 12 ]; then
  ALL_LABELS="$ALL_LABELS o-setup $O_LABELS o-cleanup"
elif [ "$ROUND" = 13 ]; then
  for l in $T_LABELS $Y_LABELS $U_LABELS $V_LABELS $W_LABELS $X_LABELS; do
    ALL_LABELS="$ALL_LABELS $l $l-cleanup"
  done
  # x1〜x4 は、作った Glue のデータカタログを指すときだけ -cleanup2 も投げる（存在すれば拾う）。
  for l in x1 x2 x3 x4; do
    ALL_LABELS="$ALL_LABELS $l-cleanup2"
  done
elif [ "$ROUND" = 14 ]; then
  for l in $Z_LABELS; do
    ALL_LABELS="$ALL_LABELS $l $l-cleanup"
  done
  # z1・z2・z4・z5 は、作った Glue のデータカタログを指すときだけ -cleanup2 も投げる（存在すれば拾う）。
  for l in z1 z2 z4 z5; do
    ALL_LABELS="$ALL_LABELS $l-cleanup2"
  done
elif [ "$ROUND" = 15 ]; then
  for l in $T_LABELS; do
    ALL_LABELS="$ALL_LABELS $l $l-cleanup"
  done
elif [ "$ROUND" = 16 ]; then
  for l in $CL_LABELS $PR_LABELS $PN_LABELS $PA_LABELS $TP_LABELS; do
    ALL_LABELS="$ALL_LABELS $l $l-showcreate $l-cleanup"
  done
elif [ "$ROUND" = 17 ]; then
  ALL_LABELS="$ALL_LABELS q-setup-db2 q-setup-qdup"
  for l in q1 q2 q3 q4 q5 q5b q0 q6 q7 q8 q9 q10 q11 q11b q12 q12b q13 q13b q22 q23; do
    ALL_LABELS="$ALL_LABELS $l $l-cleanup"
  done
  ALL_LABELS="$ALL_LABELS q14 q16 q16b q17 q17-cleanup q18 q18b q19 q19b q20 q21"
  for l in q24 q25; do
    ALL_LABELS="$ALL_LABELS $l $l-cleanup $l-cleanup2"
  done
  ALL_LABELS="$ALL_LABELS q-drop-db2 q-drop-qdup"
elif [ "$ROUND" = 20 ]; then
  for l in $X0_LABEL $K_LABELS $V_LABELS $C_LABELS $A_LABELS $M_LABELS; do
    ALL_LABELS="$ALL_LABELS $l $l-showcreate $l-cleanup"
  done
elif [ "$ROUND" = 18 ]; then
  ALL_LABELS="$ALL_LABELS p-setup-src"
  for l in $P_LABELS $W_LABELS; do
    ALL_LABELS="$ALL_LABELS $l $l-cleanup"
  done
  ALL_LABELS="$ALL_LABELS c1y c1y-cleanup $I_LABELS p-drop-src"
elif [ "$ROUND" = 19 ]; then
  ALL_LABELS="$ALL_LABELS v-setup-src d0"
  for l in d1 d2 d3 d4; do
    ALL_LABELS="$ALL_LABELS $l $l-cleanup $l-cleanup2"
  done
  for l in $F_LABELS $C_LABELS; do
    ALL_LABELS="$ALL_LABELS $l $l-cleanup"
  done
  ALL_LABELS="$ALL_LABELS v-cleanup-src"
elif [ "$ROUND" = 22 ] && [ "$P_INSERT_ONLY" = 1 ]; then
  ALL_LABELS="$ALL_LABELS p-setup-real p-base-count"
  for l in $P_LABELS; do
    ALL_LABELS="$ALL_LABELS $l $l-count"
  done
  ALL_LABELS="$ALL_LABELS p-drop-real"
elif [ "$ROUND" = 22 ]; then
  ALL_LABELS="$ALL_LABELS p-setup-real p-setup-ice p-setup-ice-insert p-setup-view"
  for l in $P_LABELS; do
    ALL_LABELS="$ALL_LABELS $l"
  done
  for l in p2 p4 p27 p28; do
    ALL_LABELS="$ALL_LABELS $l-count"
  done
  for l in p19 p20 p21 p22; do
    ALL_LABELS="$ALL_LABELS $l-cleanup"
  done
  for l in p11 p12 p13; do
    ALL_LABELS="$ALL_LABELS $l-revert"
  done
  ALL_LABELS="$ALL_LABELS p-drop-ice p-drop-ice2 p-drop-real p-drop-view"
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
    elif [ "$ROUND" = 10 ]; then
      echo "# issue #248（#208 ラウンド 10）: QueryExecutionContext の Catalog が S3 Tables のとき、"
      echo "#             #229 で測っていない Hive の CREATE TABLE の句（COMMENT・CLUSTERED BY・"
      echo "#             ROW FORMAT SERDE・FIELDS 以外の DELIMITED の句・TBLPROPERTIES の 2 組以上）、"
      echo "#             LOCATION の無い EXTERNAL の各形、バッククォートの名前、n6・n21 の対照、"
      echo "#             入れ子の型の列を実測"
      echo "# 実行日時: $(date -Iseconds)"
      if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
        echo "# S3TABLES_*: 設定あり（S 群 s1〜s11・s13・s15〜s18 を測る）"
      else
        echo "# S3TABLES_*: 未設定（s12 以外の S 群は未測定）"
      fi
      if [ -n "$FEDERATED_CATALOG" ]; then
        echo "# FEDERATED_CATALOG: 設定あり（s14 を測る）"
      else
        echo "# FEDERATED_CATALOG: 未設定（s14 は未測定）"
      fi
      echo "# StartQueryExecution の見込み本数: 20（S3TABLES_* と FEDERATED_CATALOG が両方あり）／"
      echo "#   19（S3TABLES_* のみ）／3（どちらも無し）"
      echo "#   （preflight 2 + S 群のうち S3TABLES_* が揃うときだけの 16（s1〜s11・s13・s15〜s18）+"
      echo "#   FEDERATED_CATALOG も揃うときだけの s14 の 1 + 常に投げる s12 の 1）。"
      echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
      echo "#   受理された CREATE TABLE ごとに、その場で DROP する後始末が 1 本ずつ増える（最大 +18）。"
      echo "# DDL: 実在する表 <PROBE>_real は作らない。S 群の CREATE TABLE（EXTERNAL を含む）は、"
      echo "#   受理されたらその場で DROP して消す（s8 は既定の Context、s14 は FEDERATED_CATALOG の"
      echo "#   Context、それ以外は S3 Tables の Context で DROP TABLE IF EXISTS）。"
      echo "#   LOCATION は <OUTPUT>athena-local-probe-248/<PROBE>_<項目>/（空のプレフィックス。データは置かない）。"
      echo "# 付随物: FAILED になった項目は、結果ファイル本体と <OutputLocation>.metadata を"
      echo "#   aws s3 cp で読み出して保存する（<label>.output.txt・<label>.output.metadata）。"
      echo "# 課金: スキャンの無いクエリだけ（CREATE は 0〜1 行、DROP はメタデータのみ）。結果ファイルの"
      echo "#   読み出しは S3 の GetObject で、Athena のクエリ課金には乗らない。"
      echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
      echo "#   実測値は既定とは限らない。"
    elif [ "$ROUND" = 11 ]; then
      echo "# issue #251（#208 ラウンド 11）: QueryExecutionContext の Catalog が S3 Tables のとき、"
      echo "#             場所の無い CREATE TABLE の名前空間まわり（1 部の名前・2 部と 3 部の"
      echo "#             IF NOT EXISTS）と、CTAS の残り（j13 の再現の .metadata・データの有無、"
      echo "#             DB 名の大文字小文字、1 部目の綴りと DB の有無の組、既定の Context の対照）を実測"
      echo "# 実行日時: $(date -Iseconds)"
      if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
        echo "# S3TABLES_*: 設定あり（R 群 r1〜r7b を測る）"
      else
        echo "# S3TABLES_*: 未設定（r8a〜r8c 以外の R 群は未測定）"
      fi
      echo "# StartQueryExecution の見込み本数: 14（S3TABLES_* あり）／5（無し）"
      echo "#   （preflight 2 + R 群のうち S3TABLES_* が揃うときだけの 9（r1〜r7b）+"
      echo "#   常に投げる r8a〜r8c の 3）。"
      echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
      echo "#   受理された CREATE TABLE ごとに、その場で DROP する後始末が 1 本ずつ増える（最大 +12）。"
      echo "#   r3・r6a・r7a・r8b は受理されうる（IF NOT EXISTS・既存の名前空間・既存の DB）。"
      echo "# DDL: 実在する表 <PROBE>_real は作らない。R 群の CREATE TABLE は、受理されたらその場で"
      echo "#   DROP して消す（CTAS の対象 DB がテスト用の実在しない名前のときは、その DB を"
      echo "#   Database にした Context で消す。既存の DB・名前空間の項目は作った Context と同じ）。"
      echo "# 付随物: FAILED になった項目は、結果ファイル本体と <OutputLocation>.metadata を"
      echo "#   aws s3 cp で読み出して保存する（<label>.output.txt・<label>.output.metadata）。CTAS で"
      echo "#   DB が無いために FAILED になった項目は、理由に書かれた location を aws s3 ls --recursive で"
      echo "#   確かめ、データが実際に書かれているかも見る（<label>.orphan-data.txt）。"
      echo "# 課金: スキャンの無いクエリだけ（CREATE は 0〜1 行、DROP はメタデータのみ）。結果ファイルの"
      echo "#   読み出し・オーファンデータの確認は Athena のクエリ課金には乗らない。"
      echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
      echo "#   実測値は既定とは限らない。"
    elif [ "$ROUND" = 12 ]; then
      echo "# issue #260（#208 ラウンド 12）: 無引用の awsdatacatalog.<db>.<t> の置換（#246）で"
      echo "#             測っていない周辺（S3 Tables・連携カタログ・実在しないカタログの Context の"
      echo "#             SELECT・INSERT、引用符付きの部品、4 部の列の参照、AwsDataCatalog 以外の"
      echo "#             別名キー、Context の Catalog 省略）を実測"
      echo "# 実行日時: $(date -Iseconds)"
      if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
        echo "# S3TABLES_*: 設定あり（o0・o1・o2 を測る）"
      else
        echo "# S3TABLES_*: 未設定（o0・o1・o2 は未測定）"
      fi
      if [ -n "$FEDERATED_CATALOG" ]; then
        echo "# FEDERATED_CATALOG: 設定あり（o3・o4 を測る）"
      else
        echo "# FEDERATED_CATALOG: 未設定（o3・o4 は未測定）"
      fi
      if [ -n "$FEDERATED_CATALOG" ] && [ -n "$FEDERATED_DB" ] && [ -n "$FEDERATED_TABLE" ]; then
        echo "# FEDERATED_DB・FEDERATED_TABLE: 設定あり（o9 を測る）"
      else
        echo "# FEDERATED_DB・FEDERATED_TABLE: 未設定（o9 は未測定）"
      fi
      echo "# StartQueryExecution の見込み本数: 16（すべて設定あり）／10（S3TABLES_*・FEDERATED_* 無し）"
      echo "#   （preflight 2 + O_TABLE の準備/後始末 2 + 常に投げる o5・o6・o7・o8・o10・o11 の 6"
      echo "#   + S3TABLES_* が揃うときだけの o0・o1・o2 の 3 + FEDERATED_CATALOG が揃うときだけの"
      echo "#   o3・o4 の 2 + FEDERATED_CATALOG・FEDERATED_DB・FEDERATED_TABLE が揃うときだけの o9 の 1）。"
      echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
      echo "# DDL: <db>.<PROBE>_o を 1 つ CTAS で作り、O 群の全項目で使い回して最後に DROP する"
      echo "#   （新しい表は作らない。o2・o4・o5 の INSERT は同じ表に 1 行足すだけ）。"
      echo "# 付随物: FAILED になった項目は、結果ファイル本体と <OutputLocation>.metadata を"
      echo "#   aws s3 cp で読み出して保存する（<label>.output.txt・<label>.output.metadata）。"
      echo "# 課金: スキャンの無いクエリだけ（CTAS・SELECT・INSERT はどれも 0〜1 行）。結果ファイルの"
      echo "#   読み出しは S3 の GetObject で、Athena のクエリ課金には乗らない。"
      echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
      echo "#   実測値は既定とは限らない。"
    elif [ "$ROUND" = 13 ]; then
      echo "# issue #266（#208 ラウンド 13）: #248 の実装（s3_tables_rejection・s3_tables_stored_as・"
      echo "#             location_catalog）が「測った形だけ」に絞った条件の外側（実在しないカタログの"
      echo "#             3 部 + LOCATION に句が付く形、S3 Tables の Context の LOCATION 付きの句の"
      echo "#             組み合わせ、LOCATION の無い CREATE EXTERNAL TABLE に句が付く形、LOCATION の"
      echo "#             無い STORED AS の 2〜3 部の名前・IF NOT EXISTS・ほかの句、Trino にだけある"
      echo "#             カタログ名・実在する連携カタログの 3 部 + LOCATION）を実測"
      echo "# 実行日時: $(date -Iseconds)"
      if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
        echo "# S3TABLES_*: 設定あり（T 群の t0s・t1s・t2s・t7s・t9s、U・V・W 群、X 群の x2 を測る）"
      else
        echo "# S3TABLES_*: 未設定（T 群の *s・U・V・W 群、X 群の x2 は未測定）"
      fi
      if [ -n "$FEDERATED_CATALOG" ]; then
        echo "# FEDERATED_CATALOG: 設定あり（X 群の x1・x3・x4 を FEDERATED_CATALOG で測る）"
      elif [ "${CREATE_GLUE_CATALOG:-}" = 1 ]; then
        if [ -n "$FC" ]; then
          echo "# CREATE_GLUE_CATALOG=1: データカタログを作成できた（X 群の x1・x3・x4 を測る）"
        else
          echo "# CREATE_GLUE_CATALOG=1: 設定あり（$FEDCAT_SKIP_REASON）"
        fi
      else
        echo "# FEDERATED_CATALOG・CREATE_GLUE_CATALOG: 未設定（X 群の x1・x3・x4 は未測定。xc だけ測る）"
      fi
      echo "# StartQueryExecution の見込み本数: 19（S3TABLES_* も連携カタログも無し）／"
      echo "#   55（S3TABLES_* のみ）／22（連携カタログのみ）／59（両方あり）"
      echo "#   （preflight 2 + 常に投げる T 群 11・Y 群 5・X 群の xc 1 + S3TABLES_* が揃うときだけの"
      echo "#   T 群の *s 5・U 群 8・V 群 12・W 群 11（計 36）+ 連携カタログが使えるときだけの"
      echo "#   x1・x3・x4 の 3、そのうち S3TABLES_* も揃えば x2 の 1）。"
      echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
      echo "#   受理された CREATE TABLE ごとに、その場で DROP する後始末が 1 本ずつ増える"
      echo "#   （最大 +16 T 群、+5 Y 群、+8 U 群、+12 V 群、+11 W 群、+4 X 群 = 最大 +56。"
      echo "#   作った Glue のデータカタログを指す x1〜x4 は、DROP が失敗すると既定の Context でも"
      echo "#   もう一度 DROP を試みる。最大 +4、上の内訳には含めない）。"
      echo "# DDL: 実在する表 <PROBE>_real は作らない。T・U・V・W・X・Y 群の CREATE TABLE（EXTERNAL を"
      echo "#   含む）は、受理されたらその場で DROP して消す（消す Context は項目ごとに issue 本文の"
      echo "#   指示どおり）。CREATE_GLUE_CATALOG=1 かつ FEDERATED_CATALOG 未設定のときは、"
      echo "#   athena_local_probe_266_<乱数>cat（自分のアカウントの Glue を指す GLUE 型のデータ"
      echo "#   カタログ）を 1 つ作り、x1〜x4 の後始末が終わったあとに必ず削除を試みる。"
      if [ "${CREATE_GLUE_CATALOG:-}" = 1 ] && [ -n "$FEDERATED_CATALOG" ]; then
        : # FEDERATED_CATALOG が優先されるので、この回は作っていない。
      elif [ "${CREATE_GLUE_CATALOG:-}" = 1 ]; then
        case "${GLUE_CATALOG_DELETED:-}" in
          1) echo "#   このスクリプトの実測: データカタログを作成し、削除できた。" ;;
          0) echo "#   このスクリプトの実測: データカタログを作成したが、削除できなかった（要手動削除）。" ;;
          *) echo "#   このスクリプトの実測: データカタログは作成していない（$FEDCAT_SKIP_REASON）。" ;;
        esac
      fi
      echo "# 付随物: FAILED になった項目は、結果ファイル本体と <OutputLocation>.metadata を"
      echo "#   aws s3 cp で読み出して保存する（<label>.output.txt・<label>.output.metadata）。"
      echo "# 課金: スキャンの無いクエリだけ（CREATE は 0〜1 行、DROP はメタデータのみ）。結果ファイルの"
      echo "#   読み出し、create/get/delete/list-data-catalog・sts:GetCallerIdentity は Athena の"
      echo "#   クエリ課金には乗らない。"
      echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
      echo "#   実測値は既定とは限らない。"
    elif [ "$ROUND" = 14 ]; then
      echo "# issue #266 の補足（#208 ラウンド 14）: ROUND=13 の実測で見つかった「未測定のまま"
      echo "#             残るもの」（x3 の対照。既定の Context の EXTERNAL 付きの AwsDataCatalog"
      echo "#             3 部 + LOCATION）と「範囲外の発見」（S3 Tables の Context で LOCATION の"
      echo "#             無い非 EXTERNAL の ROW FORMAT が開始して FAILED になる族、ほかの単独の"
      echo "#             Hive の句）を実測"
      echo "# 実行日時: $(date -Iseconds)"
      if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
        echo "# S3TABLES_*: 設定あり（Z 群の z6〜z17 を測る）"
      else
        echo "# S3TABLES_*: 未設定（Z 群の z6〜z17 は未測定）"
      fi
      if [ -n "$FEDERATED_CATALOG" ]; then
        echo "# FEDERATED_CATALOG: 設定あり（Z 群の z1〜z5 を FEDERATED_CATALOG で測る）"
      elif [ "${CREATE_GLUE_CATALOG:-}" = 1 ]; then
        if [ -n "$FC" ]; then
          echo "# CREATE_GLUE_CATALOG=1: データカタログを作成できた（Z 群の z1〜z5 を測る）"
        else
          echo "# CREATE_GLUE_CATALOG=1: 設定あり（$FEDCAT_SKIP_REASON）"
        fi
      else
        echo "# FEDERATED_CATALOG・CREATE_GLUE_CATALOG: 未設定（Z 群の z1〜z5 は未測定。"
        echo "#   z0・z0b・z0c だけ測る）"
      fi
      echo "# StartQueryExecution の見込み本数: 5（S3TABLES_* も連携カタログも無し）／"
      echo "#   17（S3TABLES_* のみ）／10（連携カタログのみ）／22（両方あり）"
      echo "#   （preflight 2 + 常に投げる z0・z0b・z0c の 3 + 連携カタログが使えるときだけの"
      echo "#   z1〜z5 の 5 + S3TABLES_* が揃うときだけの z6〜z17 の 12）。"
      echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
      echo "#   受理された CREATE TABLE ごとに、その場で DROP する後始末が 1 本ずつ増える"
      echo "#   （最大 +3 z0 系、+5 z1〜z5、+12 z6〜z17 ＝ 最大 +20。作った Glue のデータカタログを"
      echo "#   指す z1・z2・z4・z5 は、DROP が失敗すると既定の Context でももう一度 DROP を試みる。"
      echo "#   最大 +4、上の内訳には含めない。z3 は最初から既定の Context で消す）。"
      echo "# DDL: 実在する表 <PROBE>_real は作らない。Z 群の CREATE TABLE（EXTERNAL を含む）は、"
      echo "#   受理されたらその場で DROP して消す（消す Context は項目ごとに issue 本文の指示"
      echo "#   どおり）。連携カタログの決め方・Glue のデータカタログの作成/削除は ROUND=13 の"
      echo "#   X 群と共有する関数（resolve_federated_catalog・delete_glue_catalog_if_created）を"
      echo "#   使う（ROUND=13 の挙動は変えていない）。CREATE_GLUE_CATALOG=1 かつ FEDERATED_CATALOG"
      echo "#   未設定のときは、athena_local_probe_266_<乱数>cat を 1 つ作り、z1〜z5 の後始末が"
      echo "#   終わったあとに必ず削除を試みる。"
      if [ "${CREATE_GLUE_CATALOG:-}" = 1 ] && [ -n "$FEDERATED_CATALOG" ]; then
        : # FEDERATED_CATALOG が優先されるので、この回は作っていない。
      elif [ "${CREATE_GLUE_CATALOG:-}" = 1 ]; then
        case "${GLUE_CATALOG_DELETED:-}" in
          1) echo "#   このスクリプトの実測: データカタログを作成し、削除できた。" ;;
          0) echo "#   このスクリプトの実測: データカタログを作成したが、削除できなかった（要手動削除）。" ;;
          *) echo "#   このスクリプトの実測: データカタログは作成していない（$FEDCAT_SKIP_REASON）。" ;;
        esac
      fi
      echo "# 付随物: FAILED になった項目は、結果ファイル本体と <OutputLocation>.metadata を"
      echo "#   aws s3 cp で読み出して保存する（<label>.output.txt・<label>.output.metadata）。"
      echo "# 課金: スキャンの無いクエリだけ（CREATE は 0〜1 行、DROP はメタデータのみ）。結果ファイルの"
      echo "#   読み出し、create/get/delete/list-data-catalog・sts:GetCallerIdentity は Athena の"
      echo "#   クエリ課金には乗らない。"
      echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
      echo "#   実測値は既定とは限らない。"
    elif [ "$ROUND" = 15 ]; then
      echo "# issue #251（#208 ラウンド 15、2 ラウンド目）: CTAS の SELECT が解析／実行のどちらで"
      echo "#             失敗するか、QueryExecutionContext.Catalog の省略、プロパティ付き、"
      echo "#             WITH NO DATA、複数行／0 行、括弧／WITH 句、ExecutionParameters、"
      echo "#             S3 Tables の Context の名前空間まわりを実測"
      echo "# 実行日時: $(date -Iseconds)"
      if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
        echo "# S3TABLES_*: 設定あり（T 群 t3・t4・t16〜t19 を測る）"
      else
        echo "# S3TABLES_*: 未設定（t3・t4・t16〜t19 は未測定）"
      fi
      echo "# StartQueryExecution の見込み本数: 21（S3TABLES_* あり）／15（無し）"
      echo "#   （preflight 2 + 常に投げる t1・t2・t5〜t15 の 13 +"
      echo "#   S3TABLES_* が揃うときだけの t3・t4・t16〜t19 の 6）。"
      echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
      echo "#   受理された CREATE TABLE ごとに、その場で DROP する後始末が 1 本ずつ増える"
      echo "#   （最大 +19（あり）／+13（無し））。t7・t10 は既定の Context で DB があるため、"
      echo "#   t18 は S3 Tables の Context で既存の名前空間のため受理される見込み。"
      echo "# DDL: 実在する表 <PROBE>_real は作らない。T 群（t19 は CTAS でない plain"
      echo "#   CREATE TABLE）は、受理されたらその場で DROP して消す（対象 DB・名前空間が"
      echo "#   テスト用の実在しない名前のときは、その DB・名前空間を Database にした Context で"
      echo "#   消す。既存の DB・名前空間の項目は作った Context と同じ Context で消す）。"
      echo "# 付随物: FAILED になった項目は、結果ファイル本体と <OutputLocation>.metadata を"
      echo "#   aws s3 cp で読み出して保存する。CTAS（t1〜t18）は理由に書かれた location を"
      echo "#   aws s3 ls --recursive で確かめ、データが実際に書かれているかも見る"
      echo "#   （<label>.orphan-data.txt）。SUCCEEDED の CTAS（t7・t10・t18、想定外に受理された"
      echo "#   項目を含む）は .metadata も取得する（t19 は CTAS でないのでどちらも対象外）。"
      echo "# 課金: スキャンの無いクエリだけ（CREATE は 0〜3 行、t11 だけ 3 行。DROP はメタデータの"
      echo "#   み）。結果ファイルの読み出し・オーファンデータの確認は Athena のクエリ課金には乗らない。"
    elif [ "$ROUND" = 16 ]; then
      echo "# issue #270（#208 ラウンド 16）: #266 の先行実測（ROUND=13・14）の範囲外の発見（S3 Tables の"
      echo "#             Context で LOCATION の無い非 EXTERNAL の CREATE TABLE の ROW FORMAT・"
      echo "#             PARTITIONED BY・CLUSTERED BY・TBLPROPERTIES が開始して FAILED になる族）の"
      echo "#             「測っていない形」1〜3（句どうしの優先順、Iceberg の書き方の PARTITIONED BY、"
      echo "#             Iceberg で有効な TBLPROPERTIES）と、周辺の名前の形を実測"
      echo "# 実行日時: $(date -Iseconds)"
      if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
        echo "# S3TABLES_*: 設定あり（cl・pr・pn・pa・tp 群を測る）"
      else
        echo "# S3TABLES_*: 未設定（cl・pr・pn・pa・tp 群はすべて未測定）"
      fi
      echo "# StartQueryExecution の見込み本数: 33（S3TABLES_* あり）／2（無し）"
      echo "#   （preflight 2 + 常に投げる cl 群 2・pr 群 10・pn 群 6・pa 群 6・tp 群 7 の計 31。"
      echo "#   S3TABLES_* が無ければ 31 項目すべて未測定になり、preflight の 2 だけになる）。"
      echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
      echo "#   受理された CREATE TABLE ごとに、その場で SHOW CREATE TABLE 1 本・DROP する後始末 1 本が"
      echo "#   増える（それぞれ最大 +31。cl0 は受理される見込み（対照）、cl1 は z15 の再現で FAILED に"
      echo "#   なる見込み。ほかの項目が受理されるかどうかは、このラウンドで確かめるのが目的）。"
      echo "# DDL: 実在する表 <PROBE>_real は作らない。cl・pr・pn・pa・tp 群の CREATE TABLE は、S3 Tables の"
      echo "#   Context（作る Context と消す Context は常に同じ）だけに投げ、LOCATION は付けない。"
      echo "#   受理されたら DROP の前に同じ Context で SHOW CREATE TABLE <名前> を投げて結果ファイル"
      echo "#   本体を取得し（<label>-showcreate.output.txt）、そのあと DROP TABLE IF EXISTS で消す"
      echo "#   （SHOW CREATE TABLE が失敗しても DROP は続ける）。"
      echo "# 付随物: FAILED になった項目（CREATE TABLE・SHOW CREATE TABLE のどちらでも）は、結果ファイル"
      echo "#   本体と <OutputLocation>.metadata を aws s3 cp で読み出して保存する"
      echo "#   （<label>.output.txt・<label>.output.metadata）。"
      echo "# 課金: スキャンの無いクエリだけ（CREATE は 0 行、SHOW CREATE TABLE・DROP はメタデータのみ）。"
      echo "#   結果ファイルの読み出しは S3 の GetObject で、Athena のクエリ課金には乗らない。"
      echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
      echo "#   実測値は既定とは限らない。"
    elif [ "$ROUND" = 17 ]; then
      echo "# issue #271（#208 ラウンド 17）: 本物の CREATE EXTERNAL TABLE の 3 部の名前が"
      echo "#             GetQueryExecution の Query から 1 部目のカタログと直後の . を落とす"
      echo "#             （#266 の先行実測の範囲外の発見）のに、athena-local の"
      echo "#             reported_query.rs の CATALOG_DROPPED に CREATE EXTERNAL TABLE が無く"
      echo "#             落とさない、という食い違いの周辺（Context の DB と文の DB が違う形、"
      echo "#             句・空白・コメント・大小文字の形、Iceberg、FAILED になる形、ほかの"
      echo "#             Hive の DDL、S3 Tables・連携カタログの Context）を実測"
      echo "# 実行日時: $(date -Iseconds)"
      if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
        echo "# S3TABLES_*: 設定あり（q22・q23 を測る）"
      else
        echo "# S3TABLES_*: 未設定（q22・q23 は未測定）"
      fi
      if [ -n "$FEDERATED_CATALOG" ]; then
        echo "# FEDERATED_CATALOG: 設定あり（q24・q25 を FEDERATED_CATALOG で測る）"
      elif [ "${CREATE_GLUE_CATALOG:-}" = 1 ]; then
        if [ -n "$FC" ]; then
          echo "# CREATE_GLUE_CATALOG=1: データカタログを作成できた（q24・q25 を測る）"
        else
          echo "# CREATE_GLUE_CATALOG=1: 設定あり（$FEDCAT_SKIP_REASON）"
        fi
      else
        echo "# FEDERATED_CATALOG・CREATE_GLUE_CATALOG: 未設定（q24・q25 は未測定）"
      fi
      if [ "$Q_DB2_OK" = 1 ] || grep -qs "^State: SUCCEEDED" "$RUN_DIR/q-drop-db2.reason.txt" 2>/dev/null; then
        echo "# 別の DB <PROBE>_db2: 作れた（q1・q2・q3・q5b・q18・q18b・q19・q19b・q24・q25 を測る）"
      else
        echo "# 別の DB <PROBE>_db2: 作れなかった（q1・q2・q3・q5b・q18・q18b・q19・q19b・q24・q25 は未測定）"
      fi
      if grep -qs "^State: SUCCEEDED" "$RUN_DIR/q-setup-qdup.reason.txt" 2>/dev/null; then
        echo "# 実在する表 <PROBE>_qdup: 作れた（q14・q16・q21 を測る）"
      else
        echo "# 実在する表 <PROBE>_qdup: 作れなかった（q14・q16 は未測定。q21 も同じ表が要るため未測定）"
      fi
      echo "# StartQueryExecution の見込み本数: 51（S3TABLES_* も連携カタログも無し）／"
      echo "#   55（どちらか一方）／59（両方あり）（<DB2>・<PROBE>_qdup がどちらも作れ、q17 も"
      echo "#   受理され、q13・q13b が見込みどおり FAILED になった場合。作れなければ使う項目の"
      echo "#   分だけ少なくなる）"
      echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
      echo "#   受理された CREATE TABLE ごとに、その場で DROP する後始末が 1 本ずつ増える"
      echo "#   （作った Glue のデータカタログを指す q24・q25 は、DROP が失敗すると既定の"
      echo "#   Context でももう一度 DROP を試みる。最大 +2、上の内訳には含めない）。"
      echo "# DDL: 実在する表 <PROBE>_real は作らない。準備で別の DB <PROBE>_db2 と、同名の表が"
      echo "#   ある形（q14）用の実在する表 <PROBE>_qdup を作り、最後に消す。q1〜q13b・q22〜q25 の"
      echo "#   CREATE TABLE（EXTERNAL を含む）は、受理されたらその場で DROP して消す（消す名前は"
      echo "#   <DB>.<t> / <DB2>.<t> の 2 部で指定。q14 だけは後始末を投げず、準備の"
      echo "#   <PROBE>_qdup の後始末に任せる）。q17（CREATE DATABASE）は受理されたらその場で"
      echo "#   DROP DATABASE で消す。CREATE_GLUE_CATALOG=1 かつ FEDERATED_CATALOG 未設定のときは、"
      echo "#   athena_local_probe_266_<乱数>cat（ROUND=13・14 と共有する自分のアカウントの Glue を"
      echo "#   指すデータカタログ）を 1 つ作り、q24・q25 の後始末が終わったあとに必ず削除を試みる。"
      if [ "${CREATE_GLUE_CATALOG:-}" = 1 ] && [ -n "$FEDERATED_CATALOG" ]; then
        : # FEDERATED_CATALOG が優先されるので、この回は作っていない。
      elif [ "${CREATE_GLUE_CATALOG:-}" = 1 ]; then
        case "${GLUE_CATALOG_DELETED:-}" in
          1) echo "#   このスクリプトの実測: データカタログを作成し、削除できた。" ;;
          0) echo "#   このスクリプトの実測: データカタログを作成したが、削除できなかった（要手動削除）。" ;;
          *) echo "#   このスクリプトの実測: データカタログは作成していない（$FEDCAT_SKIP_REASON）。" ;;
        esac
      fi
      echo "# 付随物: FAILED になった項目は、結果ファイル本体と <OutputLocation>.metadata を"
      echo "#   aws s3 cp で読み出して保存する（<label>.output.txt・<label>.output.metadata）。"
      echo "# 課金: スキャンの無いクエリだけ（CREATE は 0〜1 行、DROP・ALTER・DESCRIBE はメタデータの"
      echo "#   み）。結果ファイルの読み出し、create/get/delete/list-data-catalog・"
      echo "#   sts:GetCallerIdentity は Athena のクエリ課金には乗らない。"
      echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
      echo "#   実測値は既定とは限らない。"
    elif [ "$ROUND" = 18 ]; then
      echo "# issue #272（#208 ラウンド 18）: エンジン（Trino）で失敗した CTAS の理由に本物が付ける"
      echo "#             接尾辞（location の手動クリーンアップの注意）と、解析のエラーの位置が"
      echo "#             受け取った文の位置と違う規則（本物が CTAS/INSERT を組み直して実行している"
      echo "#             とみられる）の周辺、WITH NO DATA の失敗（issue のコメント）を実測"
      echo "# 実行日時: $(date -Iseconds)"
      if [ "$SRC_OK" = 1 ] || grep -qs "^State: SUCCEEDED" "$RUN_DIR/p-drop-src.reason.txt" 2>/dev/null; then
        echo "# 実在する表 <PROBE>_src: 作れた（p2・p2y・p3・p3y・p4・p4y・w3・w3y・c1y・i1・i2 を測る）"
      else
        echo "# 実在する表 <PROBE>_src: 作れなかった（p2・p2y・p3・p3y・p4・p4y・w3・w3y・c1y・i1・i2 は未測定）"
      fi
      echo "# StartQueryExecution の見込み本数: 28（<PROBE>_src が作れなかったとき）／"
      echo "#   41（作れたとき）（preflight 2 + <PROBE>_src の準備 1・後始末 1 + 常に投げる p・w 群 25 +"
      echo "#   <PROBE>_src が要る p・w 群 8（create のみ）+ c1y 1（create + cleanup で 2）+ i1・i2 2）"
      echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
      echo "#   受理された CREATE TABLE ごとに、その場で DROP する後始末が 1 本ずつ増える（p・w 群の"
      echo "#   33 項目は最大 +33。想定どおりならすべて FAILED なので増えない）。"
      echo "# DDL: 実在する表 <PROBE>_real は作らない。準備で実在する表 <PROBE>_src（CTAS、"
      echo "#   SELECT 1 AS n, 'x' AS s）を作り、最後に消す。p・w 群・c1y の CREATE TABLE はすべて"
      echo "#   既定の Context だけに投げ、受理されたらその場で DROP して消す（無い DB を 1 部目に"
      echo "#   した X 群は Catalog=AwsDataCatalog,Database=<PROBE>_nodbN の Context で消す）。"
      echo "#   i1・i2（INSERT）は表を作らず <PROBE>_src に投げるだけ。"
      echo "# 付随物: FAILED になった CTAS（p・w 群・c1y）と i1・i2 は、結果ファイル本体と"
      echo "#   <OutputLocation>.metadata を aws s3 cp で読み出して保存する（<label>.output.txt・"
      echo "#   <label>.output.metadata）。FAILED になった CTAS はさらに、理由に書かれた location の"
      echo "#   オーファンデータ確認（aws s3 ls --recursive、ROUND=11 と共有する"
      echo "#   check_ctas_orphan_data）も行う。"
      echo "# 課金: スキャンの無いクエリだけ（CREATE は 0 行、INSERT は 0〜1 行、DROP はメタデータの"
      echo "#   み）。結果ファイルの読み出し・オーファンデータ確認は S3 の GetObject／ListObjects で、"
      echo "#   Athena のクエリ課金には乗らない。"
      echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
      echo "#   実測値は既定とは限らない。"
    elif [ "$ROUND" = 19 ]; then
      echo "# issue #273（#208 ラウンド 19）: S3 Tables の Context の 1 部・2 部の CTAS で"
      echo "#             名前空間が無いとき、本物が開始して FAILED になる（NOT_FOUND: Schema"
      echo "#             <内部名>\$schema:<名前空間> not found. + location の手動削除の注意。"
      echo "#             #251 のラウンド 15 の t16・t17 で見つけた事実）の、Database を省略した"
      echo "#             Context（<S3NODB>）の形（d 群）と、名前空間が無い CTAS の残りの形"
      echo "#             （f 群）・対照（c 群）を実測"
      echo "# 実行日時: $(date -Iseconds)"
      if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
        echo "# S3TABLES_*: 設定あり（d・f・c 群を測る）"
      else
        echo "# S3TABLES_*: 未設定（d・f・c 群はすべて未測定。準備の <PROBE>_src 以外"
        echo "#   ほぼ何も測れない）"
      fi
      if [ "$SRC_OK" = 1 ] || grep -qs "^State: SUCCEEDED" "$RUN_DIR/v-cleanup-src.reason.txt" 2>/dev/null; then
        echo "# 実在する表 <DB>.<PROBE>_src: 作れた（S3TABLES_* も揃えば f10 を測る）"
      else
        echo "# 実在する表 <DB>.<PROBE>_src: 作れなかった（f10 は未測定）"
      fi
      echo "# StartQueryExecution の見込み本数: 23（S3TABLES_* あり）／4（無し）"
      echo "#   （preflight 2 + 準備（<PROBE>_src の作成・削除）2 + S3TABLES_* が揃うときだけの"
      echo "#   d0〜d4 の 5・f1〜f12 の 12・c1・c2 の 2 = 計 19）。"
      echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
      echo "#   受理された CREATE TABLE ごとに、その場で DROP する後始末が 1 本ずつ増える"
      echo "#   （最大 +5。d3・c1 は既存の名前空間を指すため受理される見込み。d1・d2・d4 が"
      echo "#   想定に反して受理され、その DROP が <S3NODB> で失敗すれば <S3> でのもう一度の"
      echo "#   DROP でさらに増える）。"
      echo "# DDL: 実在する表 <PROBE>_real は作らない。準備で実在する Glue の表 <DB>.<PROBE>_src を"
      echo "#   1 つ作り（S3TABLES_* によらず）、最後に消す。d・f・c 群の CREATE TABLE は、受理"
      echo "#   されたらその場で DROP して消す（<S3NODB> で作った d1〜d4 は、まず同じ <S3NODB> で、"
      echo "#   失敗すれば <S3>（Catalog=<S3TABLES_CATALOG>,Database=<S3TABLES_NS>）でもう一度"
      echo "#   DROP TABLE IF EXISTS を試みる。それ以外は作った Context と同じ Context で消す）。"
      echo "# 付随物: FAILED になった CTAS の項目（d2〜d4・f1〜f12・c1）は、結果ファイル本体と"
      echo "#   <OutputLocation>.metadata を aws s3 cp で読み出して保存し（<label>.output.txt・"
      echo "#   <label>.output.metadata）、理由に書かれた location を aws s3 ls --recursive で"
      echo "#   確かめ、データが実際に書かれているかも見る（<label>.orphan-data.txt）。"
      echo "# 課金: スキャンの無いクエリだけ（CREATE は 0〜1 行、DROP はメタデータのみ）。結果ファイルの"
      echo "#   読み出し・オーファンデータの確認は Athena のクエリ課金には乗らない。"
    elif [ "$ROUND" = 20 ]; then
      echo "# issue #270 の 2 ラウンド目（#208 ラウンド 20）: ROUND=16 で測った族（S3 Tables の Context で"
      echo "#             LOCATION の無い非 EXTERNAL の CREATE TABLE が開始してから FAILED になる句）の続き"
      echo "#             （TBLPROPERTIES のキーの範囲、table_type の値と組、列リスト無しの形、ちょうど"
      echo "#             小文字の awsdatacatalog の 3 部、名前空間が無いときとの優先順）を実測"
      echo "# 実行日時: $(date -Iseconds)"
      if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
        echo "# S3TABLES_*: 設定あり（k・v・c・a・m 群と対照 x0 を測る）"
      else
        echo "# S3TABLES_*: 未設定（k・v・c・a・m 群と対照 x0 はすべて未測定）"
      fi
      echo "# StartQueryExecution の見込み本数: 34（S3TABLES_* あり）／2（無し）"
      echo "#   （preflight 2 + 常に投げる対照 x0 1・k 群 8・v 群 6・c 群 4・a 群 5・m 群 8 の計 32。"
      echo "#   S3TABLES_* が無ければ 32 項目すべて未測定になり、preflight の 2 だけになる）。"
      echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
      echo "#   受理された CREATE TABLE ごとに、その場で SHOW CREATE TABLE 1 本・DROP する後始末 1 本が"
      echo "#   増える（それぞれ最大 +32。x0 は受理される見込み（対照）。ほかの項目が受理されるかどうかは、"
      echo "#   このラウンドで確かめるのが目的）。"
      echo "# DDL: 実在する表 <PROBE>_real は作らない。k・v・c・a・m 群と対照 x0 の CREATE TABLE は、S3 Tables の"
      echo "#   Context（m5 だけ Database を <NOPE>=<PROBE>_nope270 にした Context。作る Context と"
      echo "#   消す Context は常に同じ）だけに投げ、LOCATION は付けない。受理されたら DROP の前に同じ"
      echo "#   Context で SHOW CREATE TABLE <名前> を投げて結果ファイル本体を取得し"
      echo "#   （<label>-showcreate.output.txt）、そのあと DROP TABLE IF EXISTS で消す（SHOW CREATE TABLE"
      echo "#   が失敗しても DROP は続ける）。"
      echo "# 付随物: FAILED になった項目（CREATE TABLE・SHOW CREATE TABLE のどちらでも）は、結果ファイル"
      echo "#   本体と <OutputLocation>.metadata を aws s3 cp で読み出して保存する"
      echo "#   （<label>.output.txt・<label>.output.metadata）。"
      echo "# 課金: スキャンの無いクエリだけ（CREATE は 0 行、SHOW CREATE TABLE・DROP はメタデータのみ）。"
      echo "#   結果ファイルの読み出しは S3 の GetObject で、Athena のクエリ課金には乗らない。"
      echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
      echo "#   実測値は既定とは限らない。"
    elif [ "$ROUND" = 22 ]; then
      echo "# issue #279（#208 ラウンド 22）: #260 の無引用の awsdatacatalog.<db>.<t> の置換で"
      echo "#             測れなかった／測っていない周辺（連携カタログ・S3 Tables・実在しないカタログの"
      echo "#             Context の DELETE・UPDATE・MERGE・DROP VIEW・SHOW CREATE VIEW・"
      echo "#             ALTER TABLE RENAME・EXPLAIN・CTAS・CREATE VIEW、引用符付きの部品、"
      echo "#             4 部の列の参照、無引用の大文字混じりの別名キー）を実測"
      if [ "$P_INSERT_ONLY" = 1 ]; then
        echo "# ROUND=23（issue #279 の 2 ラウンド目）: ROUND=22 の INSERT の項目（p2・p4・p27・p28。値を 1 文字に"
        echo "#   直した）と、#260 の o2・o5 の再現（p36・p37）、対照 p35 だけを測る。StartQueryExecution の"
        echo "#   見込み: preflight 2 + 準備 1 + 最初の件数 1 + INSERT 7 と件数 7 + 後始末 1 = 19（連携カタログか"
        echo "#   S3TABLES_* が無ければ、その分の INSERT と件数が減る）。DDL は準備の表 1 つと一時的なデータカタログ"
        echo "#   （CREATE_GLUE_CATALOG=1 のとき）だけで、最後に消す。以下の ROUND=22 の見込みは参考"
      fi
      echo "# 実行日時: $(date -Iseconds)"
      if [ -n "$S3TABLES_CATALOG" ] && [ -n "$S3TABLES_NS" ]; then
        echo "# S3TABLES_*: 設定あり（p17・p19・p21・p23・p24 を測る）"
      else
        echo "# S3TABLES_*: 未設定（p17・p19・p21・p23・p24 は未測定）"
      fi
      if [ -n "$FEDERATED_CATALOG" ]; then
        echo "# FEDERATED_CATALOG: 設定あり（p1〜p4 を FEDERATED_CATALOG で測る）"
      elif [ "${CREATE_GLUE_CATALOG:-}" = 1 ]; then
        if [ -n "$FC" ]; then
          echo "# CREATE_GLUE_CATALOG=1: データカタログを作成できた（p1〜p4 を測る）"
        else
          echo "# CREATE_GLUE_CATALOG=1: 設定あり（$FEDCAT_SKIP_REASON）"
        fi
      else
        echo "# FEDERATED_CATALOG・CREATE_GLUE_CATALOG: 未設定（p1〜p4 は未測定）"
      fi
      echo "# StartQueryExecution の見込み本数: 38（S3TABLES_* も連携カタログも無し）／"
      echo "#   43（S3TABLES_* のみ）／42（連携カタログのみ）／47（両方あり）"
      echo "#   （最小の見込み。ALTER TABLE RENAME・CTAS/CREATE VIEW・INSERT が受理された分だけ"
      echo "#   revert・cleanup・件数確認が 1 本ずつ増える。最大 +11）"
      echo "#   このスクリプトの実測値: $(wc -l < "$START_CALL_FILE" | tr -d ' ') 回"
      echo "# DDL: 実在する表 <PROBE>_p_real（Hive、1 行）・Iceberg 表 <PROBE>_p_ice"
      echo "#   （LOCATION 付き、1 行）・ビュー <PROBE>_p_view を作り、全項目で使い回して"
      echo "#   最後に消す。ALTER TABLE RENAME（p11〜p13）は、受理されたら次の項目の前に"
      echo "#   必ず名前を戻す。CTAS・CREATE VIEW（p19〜p22）は、受理されたらその場で消す。"
      echo "#   CREATE_GLUE_CATALOG=1 かつ FEDERATED_CATALOG 未設定のときは、ROUND=13・14・17 と"
      echo "#   共有する athena_local_probe_266_<乱数>cat を 1 つ作り、後始末が終わったあとに"
      echo "#   必ず削除を試みる。"
      if [ "${CREATE_GLUE_CATALOG:-}" = 1 ] && [ -n "$FEDERATED_CATALOG" ]; then
        : # FEDERATED_CATALOG が優先されるので、この回は作っていない。
      elif [ "${CREATE_GLUE_CATALOG:-}" = 1 ]; then
        case "${GLUE_CATALOG_DELETED:-}" in
          1) echo "#   このスクリプトの実測: データカタログを作成し、削除できた。" ;;
          0) echo "#   このスクリプトの実測: データカタログを作成したが、削除できなかった（要手動削除）。" ;;
          *) echo "#   このスクリプトの実測: データカタログは作成していない（$FEDCAT_SKIP_REASON）。" ;;
        esac
      fi
      echo "# 付随物: FAILED になった項目は、結果ファイル本体と <OutputLocation>.metadata を"
      echo "#   aws s3 cp で読み出して保存する（<label>.output.txt・<label>.output.metadata）。"
      echo "#   成功した SELECT は結果ファイル本体だけを、成功した INSERT は直後の"
      echo "#   SELECT count(*)（<label>-count）の結果ファイル本体だけを同じ形で取得する。"
      echo "# 課金: スキャンの無いクエリだけ（CREATE・SELECT・INSERT・count(*) はどれも 0〜1 行、"
      echo "#   DROP・ALTER・DELETE・UPDATE・MERGE はメタデータのみか no-op）。結果ファイルの"
      echo "#   読み出し、create/get/delete/list-data-catalog・sts:GetCallerIdentity は"
      echo "#   Athena のクエリ課金には乗らない。"
      echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更で変わりうる。"
      echo "#   実測値は既定とは限らない（本物の Athena の挙動が変わっていれば、ここに書いた"
      echo "#   見込みと食い違うことがある）。"
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
    if [ "$ROUND" = 6 ] || [ "$ROUND" = 7 ] || [ "$ROUND" = 8 ] || [ "$ROUND" = 10 ] || [ "$ROUND" = 11 ] \
      || [ "$ROUND" = 12 ] || [ "$ROUND" = 13 ] || [ "$ROUND" = 14 ] || [ "$ROUND" = 15 ] || [ "$ROUND" = 17 ] \
      || [ "$ROUND" = 18 ] || [ "$ROUND" = 19 ] || [ "$ROUND" = 22 ]; then
      case "$ROUND" in
        6) REPR_LABELS=$K_LABELS ;;
        7) REPR_LABELS=$L_LABELS ;;
        8) REPR_LABELS=$M_LABELS ;;
        10) REPR_LABELS=$S_LABELS ;;
        12) REPR_LABELS=$O_LABELS ;;
        # ROUND=13（issue #266）は X 群だけ、開始できた項目の QueryExecutionContext・
        # StatementType/SubstatementType も見たいので repr の対象にする。
        13) REPR_LABELS=$X_LABELS ;;
        # ROUND=14（issue #266 の補足）は Z 群のうち z0 系・連携カタログ絡みの z1〜z5 だけ
        # （ROUND=13 の X 群と同じ範囲。z6〜z17 の S3 Tables の族は対象外）。
        14) REPR_LABELS=$Z_REPR_LABELS ;;
        15) REPR_LABELS=$T_LABELS ;;
        # ROUND=17（issue #271）はこのラウンドの決め手（返った Query・QueryExecutionContext・
        # 状態・StatementType/SubstatementType・理由）なので、開始できた q 群の全項目を対象にする。
        17) REPR_LABELS=$Q_LABELS ;;
        # ROUND=18（issue #272）も同じく一部の項目に絞らない（開始できた p・w 群・c1y・i 群の全項目）。
        18) REPR_LABELS="$P_LABELS $W_LABELS c1y $I_LABELS" ;;
        # ROUND=19（issue #273）も開始できた d・f・c 群の全項目を対象にする（要件どおり）。
        19) REPR_LABELS="$D_LABELS $F_LABELS $C_LABELS" ;;
        # ROUND=22（issue #279）も Query が書き換わったかが決め手なので、開始できた
        # p 群の全項目を対象にする。
        22) REPR_LABELS=$P_LABELS ;;
        *) REPR_LABELS=$R_LABELS ;;
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
    if [ "$ROUND" = 5 ] || [ "$ROUND" = 10 ] || [ "$ROUND" = 11 ] || [ "$ROUND" = 12 ] || [ "$ROUND" = 13 ] || [ "$ROUND" = 14 ] || [ "$ROUND" = 15 ] || [ "$ROUND" = 16 ] || [ "$ROUND" = 17 ] || [ "$ROUND" = 18 ] || [ "$ROUND" = 19 ] || [ "$ROUND" = 20 ] || [ "$ROUND" = 22 ]; then
      echo
      if [ "$ROUND" = 15 ]; then
        echo "## 付随物（結果ファイル本体・.metadata。FAILED または SUCCEEDED の CTAS だけ。実名は伏せる）"
      else
        echo "## 付随物（結果ファイル本体・.metadata。FAILED になった項目だけ。実名は伏せる）"
      fi
      case "$ROUND" in
        5) ATTACH_LABELS=$J_LABELS ;;
        10) ATTACH_LABELS=$S_LABELS ;;
        12) ATTACH_LABELS=$O_LABELS ;;
        13) ATTACH_LABELS="$T_LABELS $Y_LABELS $U_LABELS $V_LABELS $W_LABELS $X_LABELS" ;;
        14) ATTACH_LABELS=$Z_LABELS ;;
        15) ATTACH_LABELS=$T_LABELS ;;
        17) ATTACH_LABELS=$Q_LABELS ;;
        18) ATTACH_LABELS="$P_LABELS $W_LABELS c1y $I_LABELS" ;;
        19) ATTACH_LABELS="$D_LABELS $F_LABELS $C_LABELS" ;;
        22) ATTACH_LABELS=$P_LABELS ;;
        16) ATTACH_LABELS="$CL_LABELS $PR_LABELS $PN_LABELS $PA_LABELS $TP_LABELS $SC_LABELS" ;;
        20) ATTACH_LABELS="$X0_LABEL $K_LABELS $V_LABELS $C_LABELS $A_LABELS $M_LABELS $SC_LABELS" ;;
        *) ATTACH_LABELS=$R_LABELS ;;
      esac
      for label in $ATTACH_LABELS; do
        if [ "$ROUND" = 15 ]; then
          is_failed "$label" || succeeded "$label" || continue
        else
          is_failed "$label" || continue
        fi
        echo "### $label"
        if [ "$ROUND" != 15 ] || is_failed "$label"; then
          body="$RUN_DIR/$label.output.txt"
          if [ -s "$body" ]; then
            echo "- 本体: あり（$(wc -c < "$body" | tr -d ' ') バイト） 先頭: $(sanitize "$(hide "$(head -n1 "$body")")")"
          elif [ -f "$body" ]; then
            echo "- 本体: あり（0 バイト）"
          else
            echo "- 本体: 取得できず（$(first_err_line "$body.err")）"
          fi
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
    if [ "$ROUND" = 16 ] || [ "$ROUND" = 20 ]; then
      echo
      echo "## SHOW CREATE TABLE の結果（受理された項目だけ。実名・LOCATION の S3 URI は伏せる）"
      case "$ROUND" in
        20) SHOWCREATE_LABELS="$X0_LABEL $K_LABELS $V_LABELS $C_LABELS $A_LABELS $M_LABELS" ;;
        *) SHOWCREATE_LABELS="$CL_LABELS $PR_LABELS $PN_LABELS $PA_LABELS $TP_LABELS" ;;
      esac
      for label in $SHOWCREATE_LABELS; do
        f="$RUN_DIR/$label-showcreate.output.txt"
        [ -s "$f" ] || continue
        echo "### $label"
        mask_s3_uri "$(hide "$(cat "$f")")"
        echo
      done
    fi
    if [ "$ROUND" = 11 ] || [ "$ROUND" = 15 ]; then
      echo
      echo "## CTAS が失敗した項目のオーファンデータ確認（aws s3 ls --recursive。実名は伏せる）"
      case "$ROUND" in
        15) ORPHAN_LABELS=$T_LABELS ;;
        *) ORPHAN_LABELS="r4 r5 r6a r6b r7a r7b r8a r8b r8c" ;;
      esac
      for label in $ORPHAN_LABELS; do
        f="$RUN_DIR/$label.orphan-data.txt"
        [ -f "$f" ] || continue
        echo "### $label"
        if [ -s "$f" ]; then
          echo "$(hide "$(cat "$f")")"
        else
          echo "(オブジェクトなし)"
        fi
        echo
      done
    fi
    if [ "$ROUND" = 18 ] || [ "$ROUND" = 19 ]; then
      echo
      if [ "$ROUND" = 18 ]; then
        echo "## CTAS が失敗した項目のオーファンデータ確認（aws s3 ls --recursive。実名は伏せる）"
        orphan_labels="$P_LABELS $W_LABELS c1y"
      else
        echo "## 名前空間が無くて失敗した CTAS のオーファンデータ確認（aws s3 ls --recursive。実名は伏せる）"
        orphan_labels="d2 d3 d4 f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 f11 f12 c1"
      fi
      for label in $orphan_labels; do
        f="$RUN_DIR/$label.orphan-data.txt"
        [ -f "$f" ] || continue
        echo "### $label"
        if [ -s "$f" ]; then
          echo "$(hide "$(cat "$f")")"
        else
          echo "(オブジェクトなし)"
        fi
        echo
      done
      if [ "$ROUND" = 18 ]; then
        echo
        echo "## 位置の表（本物が返した line L:C と、送った文でエラーの対象の語が始まる行・桁。実名は伏せる）"
        echo "#   L:C は StateChangeReason・AthenaError に書かれた位置（そのまま）。line/col は対象の語"
        echo "#   （無い表名・列名・型不一致のリテラルなど）が、送った文（マスク前の実文で数える）の中で"
        echo "#   1 始まりで始まる行・桁。組み直しの規則（本物が CTAS/INSERT をどう組み替えているか）を"
        echo "#   読むための表。"
        for label in $P_LABELS $W_LABELS c1y $I_LABELS; do
          [ -s "$RUN_DIR/$label.reason.txt" ] || continue
          IFS=$'\t' read -r rl rc < <(reason_line_col "$label")
          [ "$rl" = "-" ] && continue
          needle="${POS_TARGET[$label]:-}"
          if [ -n "$needle" ]; then
            IFS=$'\t' read -r tl tc < <(sql_position_of "$label" "$needle")
          else
            tl="-"; tc="-"
          fi
          echo "- $label: line $rl:$rc → 対象の語（$(sanitize "$(hide "$needle")")）は line $tl:$tc"
        done
      fi
    fi
    if [ "$ROUND" = 22 ]; then
      echo
      echo "## 成功した SELECT の結果ファイルの列名の行（実名は伏せる）"
      for label in p0 p0b p1 p3 p23 p24 p25 p26 p29 p30 p31 p32; do
        f="$RUN_DIR/$label.output.txt"
        [ -s "$f" ] || continue
        echo "### $label"
        echo "$(sanitize "$(hide "$(head -n1 "$f")")")"
        echo
      done
      echo
      echo "## 成功した INSERT の直後の SELECT count(*)（実名は伏せる。前後の <label>-count と"
      echo "## p0・p0b の結果を見比べれば、行が増えたかが分かる）"
      for label in p-base p35 p36 p37 p2 p4 p27 p28; do
        f="$RUN_DIR/$label-count.output.txt"
        [ -s "$f" ] || continue
        echo "### $label-count"
        echo "$(sanitize "$(hide "$(cat "$f")")")"
        echo
      done
    fi
  } > "$txt"
  echo "$txt"
}

# 手で消す必要が残っていれば summary の冒頭に警告を積む（PENDING_DROPS に名前が
# 残っている = 本編の -cleanup では消せず、trap のベストエフォートに委ねた状態）。
if [ "${#PENDING_DROPS[@]}" -gt 0 ] || [ "${#PENDING_DROPS_CTX[@]}" -gt 0 ] \
  || [ "$C20_CREATED" = 1 ] || [ "$REAL_SETUP_ATTEMPTED" = 1 ] || [ -n "${GLUE_CATALOG_NAME:-}" ]; then
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
  # ROUND=13（issue #266）で CREATE_GLUE_CATALOG=1 により作ったデータカタログを、本編の
  # 明示的な delete-data-catalog で消せなかった（GLUE_CATALOG_NAME がまだ残っている）。
  if [ -n "${GLUE_CATALOG_NAME:-}" ]; then
    PENDING_DROPS_REPORT="$PENDING_DROPS_REPORT"$'\n'"  - **要手動削除**: データカタログ $(hide "$GLUE_CATALOG_NAME")（aws athena delete-data-catalog で確認）"
  fi
fi

SUMMARY_TXT=$(write_summary_txt)

echo
echo "完了しました。"
echo "機械可読な一覧: $SUMMARY"
echo "そのまま貼れる整形済みの一覧: $SUMMARY_TXT"
echo "中身のファイルは $RUN_DIR にあります。リポジトリには入れないでください。"
echo "<label>.sql・<label>.reason.txt・<label>.start.err は実名（DB 名・テーブル名）を"
echo "含みうるので、summary.txt 以外を貼るときは中身を確かめてください。"
