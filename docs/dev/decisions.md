# 設計判断

決着済みの設計判断と、その理由。各 issue のノート（#98 で消した。git の履歴に残る）から、後の開発でも効くものだけを写した。末尾の（#番号、日付）が出典で、日付はその issue のノートを書き始めた日。

- [CLAUDE.md](../../CLAUDE.md) の「開発上の約束」とアーキテクチャの節にすでに書いてある方針（本物の Athena に合わせる、推測で埋めない、SQL の本文は書き換えない、`mod.rs` は宣言と再エクスポートだけ、など）はここに重ねない。
- 後の issue で覆った判断は載せない。変わったものは新しいほうを載せ、「#N で変更」と添える。
- 実測の値そのものは [measurements/](measurements/README.md)、まだ測っていないものは [unmeasured.md](unmeasured.md)。

## 実測の進め方

- 挙動を決める issue では、本物で実測してから計画を確定する（失敗時・取り消し時の扱いもそうした）。（#5・#6、2026-09-17）
- 実測が過去の実測と食い違ったときは、どちらを採るかをユーザーに 1 問聞いて決める。（#26、2026-09-19。このときは当日の実測を採った）
- 本物の Athena が要らない未実測（クライアントや Trino の挙動、athena-local 自身の観測）は、手元の Trino + MinIO の e2e 足場（`tools/e2e/`）で測る。クライアント相手は measurements の `clients.md`、Trino 相手は `trino.md` に書き、athena-local 自身の観測（保持期限で捨てた後の S3 の結果、メモリの頭打ちなど）は measurements に書かず `docs/caveats.md` の該当の記述を実測済みに直して `unmeasured.md` の「済み」に足場のパスを添える。（#111、2026-09-23）
- e2e の足場で「無いことの証拠」（GET 0 件・STS の呼び出し 0 件）を合否にするときは、数える範囲を check ごとの区間（ログの開始行）と接頭辞の前方一致（`.txt` なら `.txt.metadata` も）で閉じ、対照（オブジェクトが置かれていること、canary が中継に届くこと）と対で判定する。旧版のクライアントを相手にするときは、文書に載っている既知の不具合（3.5.1 未満の DDL の NoSuchKey など）を測りたい項目の判定に混ぜず、その項目の出力行だけで合否を決める。状態の語は PASS / FAIL / SKIP / INFO の 4 つ、終了コードは FAIL の件数、証跡は `/tmp/athena-local-issue<番号>-<足場>.XXXXXX`。（#111、2026-09-23）
- Python のクライアント（awswrangler・PyAthena・dbt-athena）を athena-local に向けるときは `endpoint_url` を渡さず、`AWS_ENDPOINT_URL`（全サービス）・`AWS_ENDPOINT_URL_ATHENA`・`AWS_ENDPOINT_URL_S3` の環境変数で向ける。理由: PyAthena は `connect(endpoint_url=)` を S3 の client にも流用し、dbt-athena の impl の client は profile の `endpoint_url` を受け取らない。`AWS_ENDPOINT_URL` を手元に向けておけば STS・Glue が本物に漏れない。（#111、2026-09-23）
- 長時間の負荷でメモリの頭打ちを判定するときは、同じ負荷を保持期限の長短で流した対照つきで見る（RSS は glibc が返さないので「下がる」ではなく「伸びが止まる」を見る）。1 本の長時間実行だけで判定しない。（#111、2026-09-23）
- 外部クライアント（ドライバ・SDK）を相手にする実測では、そのクライアント自身で最小の 1 本（例: `SELECT 1`）を通すことを preflight にする。理由: コマンドの有無だけの preflight では、条件を 1 つずつ変える無駄なラウンドを畳めなかった。（#46、2026-09-21）
- JDBC の足場のドライバは Maven の依存にせず、実測スクリプトが取得してコンテナにマウントする（`Main.java` は `java.sql` しか使わず、実行時に `ServiceLoader` が拾う）。（#46、2026-09-21）
- 利用者向けの文書に書いた実測の主張は、保存済みの実測バイト列から再導出するスクリプトで固定する（`tools/measure/opaque-metadata-form.sh`）。（#24、2026-09-19）
- 実測した本物との差分は、その issue の範囲外でも Caveats（現 [docs/caveats.md](../caveats.md)）に書く。（#6、2026-09-17）
- 実測値をコードに書くときは日付入りのコメントを添え、テストは同じリテラルを 1 箇所のヘルパに集めて使う。（#2、2026-09-16）
- 同じ事実の正は利用者向けの文書の 1 か所（Content-Type の規則なら [docs/result-files.md](../result-files.md)）にし、ほかは参照に任せる。（#70、2026-09-23）
- 途中のコミットで本物より悪い契約を作らない（例: 同じトークン・違うクエリに黙って 1 回目の結果を返す）。関連する変更（重複排除と衝突エラー）は同じフェーズに入れる。（#3、2026-09-17）
- 本番コードの挙動が変わらない変更（ファイルの移動・分割、内部ヘルパの統合、検証だけの issue、テストだけの変更）では README・CHANGELOG・docs を変えない。CLAUDE.md は、記述が事実として誤りになるときだけ追随させる。（#19、2026-09-18、#44、2026-09-21、#46、2026-09-21、#49、2026-09-22、#57、2026-09-22、#61、2026-09-22、#75、2026-09-23）

## 開発の足場

使い方は [development.md](development.md) の「検証の足場（toolbox）」。

- 新しい issue に着手したら、ブランチを切った直後に過去の issue のノート（`.claude/issue-notes`）を全部消す。Skill が新しいノートを書く前に消す。理由: 古いノートには後で覆った事実が残っていて、正のドキュメント（docs/dev）より先に読まれると誤った前提で開発が進む。過去のノートは履歴に残る。（#98・#100。理由を CLAUDE.md から移した。#190）
- 検証の足場（`tools/e2e/`）は toolbox の中で動かし、ホストのコマンドに依存しない。理由: ホストの PATH にある同名の別物（Docker で包んだ `aws`、snap 製の `jq`、astral でない `uv`）を踏むたびに足場とコメントに回避策を積み上げていた（2026-09-16〜23）。動く場所をコンテナに固定すれば、回避策ごと要らなくなる。（#127、2026-09-23）
- toolbox は `docker run` の直呼びではなく、ルートの `compose.yml` の dev サービスにして `tools/dev.sh` から `docker compose run` で呼ぶ。理由: 段階 2 で trino などを同じファイルに足す（#126 の方針）。（#127、2026-09-23）
- 段階 1 の dev サービスは `network_mode: host`。理由: 足場の宛先（`127.0.0.1:<port>`）を変えずに無改造で動かす。（#127、2026-09-23。#128 で変更: dev は compose のネットワークに入った）
- toolbox の HOME はリポジトリの `.toolbox/home`。理由: `tools/e2e/jdbc-drivers/lib.sh` が `$HOME` の下の jar を `docker compose run -v` の元に渡し、デーモンはそのパスをホストのパスとして解決する。ホストと同じ絶対パスでマウントしたリポジトリの中なら、両側で同じパスに実在する。（#127、2026-09-23）
- cargo の成果物は `.toolbox/cargo` と `.toolbox/target` に置いてホストの `~/.cargo`・`target/` と混ぜず、足場は athena-local の起動パスを `BINARY="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/athena-local"` で `CARGO_TARGET_DIR` に追随させる。理由: ホストで作ったバイナリは GLIBC_2.34 までしか要求せず bookworm でも動くので、置き場を共有したりパスを直書きしたりすると、toolbox でビルドした直後にホスト製の古いバイナリを黙って起動する。（#127、2026-09-23）
- ホストの `/tmp` は toolbox に同じパスで共有する。理由: 足場は証跡を `/tmp/athena-local-issue<番号>-<足場>.XXXXXX` に置いてパスを表示する。共有すればホストからそのまま開け、「実測の進め方」の証跡の置き場の判断もそのまま成り立つ。（#127、2026-09-23）
- 環境変数は `tools/dev.sh VAR=値 <コマンド>` の形で `env --` に渡し、通す変数の許可リストを持たない。理由: 足場が読む変数は e2e だけで約 30 あり、許可リストは足場が増えるたびに突き合わせる対になる。（#127、2026-09-23）
- `compose.yml` では `${VAR:?}` を使わない（値は `tools/dev.sh` が必ず代入してから export し、取れなければ `set -e` で止まる）。理由: 使わないサービスの補間エラーでも compose 全体が止まり、足場が toolbox の中から `docker compose up` / `down` を呼べなくなる。（#127、2026-09-23）
- toolbox に awscli と mc を入れない。理由: e2e の足場はどちらも呼ばない（S3 の確認は compose のネットワークに繋いだ `minio/mc` の使い捨てコンテナ）。`tools/measure/` の `aws` は #129 で扱う。（#127、2026-09-23。#129 で変更: 両方入れた）
- toolbox に mc を入れ、足場は `mc alias set local http://minio:9000` で MinIO を直接見る。理由: #128 で dev が compose のネットワークに入り、使い捨てコンテナ（minio/verify.sh だけで 1 回 30〜40 回の docker run）と MC_NETWORK の取得が要らなくなった。イメージはマルチアーキの manifest list のダイジェストで固定する（toolbox のタグは Dockerfile の sha256 だけなので `:latest` だと中身だけ変わる）。（#129、2026-09-23）
- 足場の環境（trino・minio・minio-init・tls-proxy・jdbc-client）はルートの 1 本の `compose.yml` にまとめ、足場はサービス名（`trino:8080`、`minio:9000`）で相手を見る。理由: issue ごとの compose 6 本と、衝突を避けるためのポート表の乱立を消す（#126）。（#128、2026-09-23）
- 足場ごとの隔離は「使うサービスだけ開始時に `down -v` → `up -d`」で保ち、`down` は必ずサービス名を列挙する。理由: 前の走行の残骸で判定が狂う足場が 4 つある（sdk-retry、jdbc-show-metadata、jdbc-drivers、trino-probe）。`--remove-orphans` とサービス名の無い `up` は dev 自身を壊し、anonymous volume を作り直す `-V` は古い volume がリークする。（#128、2026-09-23）
- 足場の開始時のポートの空き確認は、「同じプロジェクトに自分以外の dev がいたら止まる」判定に置き換えた。理由: 全足場が同じプロジェクトに入るので、並行して流した足場の開始時の `down -v` が相手の Trino を走行の途中で黙って消す。（#128、2026-09-23）
- 足場の同時実行は `COMPOSE_PROJECT_NAME` で環境ごと分ける（使い方は [development.md](development.md) の「足場の環境と同時実行」）。`trino2` のような 2 号機のサービスは足さない。理由: 2 号機には足場の宛先を振り分ける仕組みが要り、組み合わせが固定される。プロジェクト名なら足場を変えずに環境ごと分かれる。（#128、2026-09-23）
- tls-proxy の nginx は静的な `proxy_pass http://dev:8087` で athena-local に中継する。理由: 足場は tls-proxy を毎回作り直すので、そのときの dev（`--use-aliases` で別名が付く）を起動時の名前解決で引ける。`resolver` による実行時の解決は要らない。（#128、2026-09-23）
- compose.yml のサービスに `container_name` と `ports` は置かず、足場はコンテナを `docker compose ps -q <サービス>` の ID で指す。理由: 固定の名前やホストのポートがあると、プロジェクト名で分けた環境どうしが衝突する。（#128、2026-09-23）
- compose の付属物（カタログ、tls、jdbc-client）は `tools/compose/` に置き、trino-probe の `catalog/` は trino-probe に残す。理由: probe は版ごとのカタログの差を測る道具で、`catalog`・`catalog-legacy`・`catalog-nofsflag` を並べておく方が対称。（#128、2026-09-23）
- 足場の共通の lib は作らない（Trino を待つ関数などは足場ごとに複製する）。理由: 足場ごとの複製が慣習で、共通化は足場の移行とは別の変更になる（`tools/e2e/jdbc-drivers/lib.sh` の冒頭）。（#128、2026-09-23）
  例外: jdbc 系 3 本（`tools/e2e/jdbc-drivers/verify.sh` と `tools/measure/jdbc-metadata.sh`・`jdbc-show-metadata.sh`）は
  同じ環境（compose・証明書・ドライバ・athena-local・JVM の実行）を使い、環境を変えるたびに 3 本を並べて直してきたので
  `tools/e2e/jdbc-drivers/lib.sh` を共有する。（#115、2026-09-24）
- #127 は足場の規則そのものを変えたので、CLAUDE.md の注意書き（ホストの `aws`・`jq` の回避策）を toolbox の 1 項目に書き換えた。「実測の進め方」の「CLAUDE.md は記述が事実として誤りになるときだけ追随させる」は挙動を変えない変更の規則で、規則を変える変更はこれに当たらない。（#127、2026-09-23）
- cargo と docker build の既定のコマンドも toolbox（`tools/dev.sh`）に寄せる。ホストに rust があればホスト直でも動く。理由: 新しい開発者は Docker だけで開発できる。CI の `check` はホストランナーで直に cargo。（#129、2026-09-23）
- CI の `e2e` ジョブは toolbox の中で Trino と MinIO の要らない・Trino だけ要る足場（request-errors、paging-validation）を流す。retention（約 10 分）と jdbc-drivers（ドライバの取得）は載せない。toolbox のイメージは docker.yml と同じ GHA キャッシュ（`mode` は既定）で、Docker Hub には docker.yml と同じ secrets でログインする（ランナーは IP を共有し、匿名 pull の制限に当たる。secrets の無いフォークの PR では省く）。cargo は `.toolbox/target/release` だけキャッシュする。理由: GHA キャッシュの上限を docker.yml のリリース用のキャッシュと取り合わない（`.toolbox/target` 全体は数 GB）。（#130、2026-09-24）
- 実測（tools/measure）の生データはホストの `~/athena-*-measurements` に書く（dev にホストのホームを同じパスでマウントし、`DEV_HOST_HOME` を既定の出力先にする）。理由: 過去の記録と同じ場所で、`rm -rf .toolbox` で消えない。（#129、2026-09-23）
- tools/measure も toolbox で動かす。awscli v2 は版付きの zip（2.37.0）で固定する。理由: toolbox のタグは Dockerfile の sha256 だけなので、版を固定しないと再ビルドで中身が変わる。（#129、2026-09-23）
- AWS の資格情報は設定されているときだけ dev に渡す（compose の値無しキー）。理由: `${VAR:-}` だと空文字が渡る。（#129、2026-09-23）

## SQL の字句処理と文の分類

- SQL の本文を書き換えない約束の唯一の例外として、`TRINO_CATALOG_MAP` の別名を引用符付きの修飾名に当てる置換（`catalog.rs`）を入れた。理由: Trino には `/` を含むカタログ名を作れず、S3 Tables の修飾名はほかに Trino へ通す方法が無い。汎用ツールとして入れ、条件は広げない。引用符の無い名前や大文字小文字の違う名前は、Trino 側のカタログ名を合わせる回避策（`docs/configuration.md`・`docs/caveats.md`）で受ける。（2026-09-15。理由を CLAUDE.md から移した。#190）
- SQL の字句走査の道具（`skip_leading_trivia`、`skip_quoted`、`comment_end`、`skip_keyword` など）は `src/catalog.rs` に集める。新しいモジュール（`lexer.rs`）は作らない。理由: 字句処理が 2 ファイルに散る。区切りは全部 ASCII なので UTF-8 の境界は壊れない。（#17、2026-09-18、#49、2026-09-22）
- `skip_keyword` は `catalog.rs` に 1 つだけ置く（内部で `skip_leading_trivia` を呼ぶ版）。同名の別定義は作らない。ラッパーを残して呼び出し元を変えずに済ませる案は、前例になるので採らない。（#49、2026-09-22。#44 の「2 版を統合しない」を変更）
- `catalog.rs` の可視性は、doc に「どのファイルが再利用するか」と issue 番号を書いたものを `pub(crate)`、それが無い私的な補助を private にする。呼び出しは `crate::catalog::foo()` のフルパスで書く。（#49、2026-09-22）
- 文の種類の判定箇所を増やさない。`ResultFile::of`（ファイル名）と `statement_type`／`substatement_type` は同じ前処理と同じ判定を使い、新しい判定が要るときは `classification` の関数を再利用する。（#6、2026-09-17、#17、2026-09-18、#39、2026-09-20、#52、2026-09-22）
- キーワードの間のコメント（`/* c */`、`-- c`）は空白として読み飛ばす。引用符（リテラル）の中の `--`／`/*` はコメントと読まない。字句処理は必ずリテラルを `skip_quoted` で読んでからコメントを見る。（#52、2026-09-22、#70、2026-09-23）
- `trim_start_matches('(')` の非対称（`classification` 側は括弧を除いた後、`results.rs` 側は括弧付き）は変えない。`is_create_table_as` の `SELECT`／`WITH`／`(` の 3 通りの OR がこの差を吸収している。（#17、2026-09-18）
- カタログ別名専用の `next_is_dot` は、ほかの字句関数とループが数行重複しても書き直さない。理由: Trino の実機で検証済みの機能に挙動変化のリスクを持ち込まない。（#17、2026-09-18）
- `ALTER TABLE` の分類は全文走査ではなく位置固定（キーワードごとに `skip_leading_trivia` を挟んで読み進める）。理由: 全文走査は `SET TBLPROPERTIES ('comment'='...add column...')` を `ALTER_TABLE_ADD_COLUMN` と誤判定する。（#39、2026-09-20）
- `ADD COLUMN`／`ADD COLUMNS` は `starts_with("COLUMN")` で両方の綴りを受ける（Trino の綴りで書けば動く）。`DROP` は単数形の `COLUMN` だけ（本物は複数形を構文エラーにする）。`REPLACE` は複数形の `COLUMNS` だけで、測っていない単数形は分類しない。（#39、2026-09-20、#43、2026-09-21）
- Trino に構文が無く実機で到達しない文（`REPLACE COLUMNS` など）は結合テストを足さずにユニットテストで配線を固定し、分類だけを足した文は「athena-local で実行できる」と誤読されないよう到達可能性を利用者向けの文書に書く。（#43、2026-09-21）
- `TABLE` で始まる文は DML／`SELECT` に分類する（`.csv` と揃う）。（#65、2026-09-22）
- `SHOW FUNCTIONS` は `.csv`・`SubstatementType` `SHOW_FUNCTIONS`・`GetQueryResults` の列名行つき（UTILITY の例外）。失敗したときは他の `.csv` の文と同じく結果ファイルを置かず、本体の PUT 失敗は FAILED にする。（#76・#80、2026-09-23）
- `CREATE OR REPLACE TABLE ... AS` を `tables/<id>` にする扱いは、Trino（Iceberg）が実行できる文に対する athena-local の規則として残す。本物は構文エラーで受け付けないので比べる相手が無い。（#93、2026-09-23）

## 結果ファイル

- `<id>.txt` の中身は `GetQueryResults` と同じ値を使い、行を `\n` で連結する。末尾に改行は足さない。複数列はタブで繋ぎ、NULL は空文字。（#1、2026-09-16、ユーザーの判断 1）
  - #1 は「Hive 由来の固定幅の空白詰めは真似しない（幅の決め方は推測になる）」としていたが、#173 で覆した。`DESCRIBE`／`DESC` と `SHOW COLUMNS` は完了時に本物と同じ 1 値の行（Hive のテーブルは 20 文字の左詰め、見出し行群つき）に作り直し、`.txt` にも同じ空白詰めが入る。理由: 20 文字の左詰めの規則（20 文字以上は切らない、幅は文字数、コメントは詰めてから先頭のタブまで）と見出し行群を実測で確かめ、「推測になる」が当たらなくなった。（#173、2026-09-24、ユーザーの判断 D2）
  - 列名の見出し行は `GetQueryResults` と同じく `StatementType` が DML（`EXPLAIN`）のときだけ入れ、UTILITY／DDL では入れない。（#63、2026-09-22 で変更。#1 では全文で見出し無しだった）
- `GetQueryResults` の列名の見出し行は `StatementType` が DML のときだけ残し、UTILITY では外す（`get_query_results` 側で外し、`all_rows` は変えない）。例外は `SHOW FUNCTIONS`。（#60、2026-09-22、#80、2026-09-23）
- `<id>.txt` と `.metadata` の書き込みに失敗しても FAILED にせず `SUCCEEDED` のままにし、標準エラーに 1 行出す。`.csv` の書き込み失敗は FAILED。理由: 本物は補助ファイルの書き込みで失敗にしない。Trino で実行済みの DDL は取り消せないので失敗と報告すると実害がある。`SHOW` の結果は `GetQueryResults` からも取れる。（#1、2026-09-16、ユーザーの判断 4、#5、2026-09-17）
- `to_csv` と `to_text` は、NULL の扱いしか重ならず引用符と列名行の有無が違うので、無理にまとめない。（#1、2026-09-16）
- S3 への PUT には `reqwest` のタイムアウトを固定値で入れる（環境変数は足さない）。タイムアウトは新しい分岐を作らず、既存の PUT 失敗の経路に合流させる。（#16、2026-09-18）
- その上限 30 秒は、本物に対応する挙動が無い athena-local 独自の値。（#16、2026-09-18）
- 本体の PUT 中の取り消しに備えて `.metadata` の前に取り消しを確かめ直す分岐は入れない（既に起きている競合で、新しい壊れ方は生まれない）。（#5、2026-09-17）
- INSERT の結果ファイルは、テーブルの形式・更新件数によらず `<id>`（`ResultFile::Manifest`）。更新件数 0 の INSERT も `.metadata` だけを置き、field 3 に 0 を書く。（#35、2026-09-20、#91、2026-09-23）
- 失敗ファイル（`FAILED: ` + `StateChangeReason`）の中身は本物の `StateChangeReason` と一致しない（本物は Hive の文言そのものが `FAILED: ` で始まり、athena-local は Trino の `ERROR_NAME: message`）。それを承知で、ファイルを読んだクライアントが失敗と分かる印を優先し、差を利用者向けの文書に書く。（#6、2026-09-17、ユーザーの判断 2）
- 失敗ファイルは FAILED にする前に PUT する（クライアントは FAILED を見た直後に S3 を読む）。Trino に届かないなどの `QueryError::other` でも分岐を足さずに置く。`.csv` の PUT 失敗で FAILED になる経路では置かない。（#6、2026-09-17）
- 失敗した `EXPLAIN`（`EXPLAIN ANALYZE` を含む）は `.txt` の文でも失敗ファイルを置かない。（#92、2026-09-23）

## Content-Type

- Content-Type は「ファイルの種類 × SQL」で決め、`src/content_type.rs` に集める。`ResultFile::of` は「文の種類だけで決まり SQL の残りは見ない」をファイル名の判定として守り、SQL の残りを見る判定は別の関数に置く。（#70、2026-09-23）
- `.metadata` の Content-Type は本体に追従させる（`ResultLocation` に持たせ、`metadata()` が引き継ぐ）。失敗ファイルは application 固定。テーブル形式に依存する DDL の上書きは本体と `.metadata` の両方に同じ値を渡す。（#70・#76、2026-09-23）
- リテラルだけの `SELECT` は実測した形だけを受け、ほかは application に落とす（本物が binary にする形を取りこぼす方向にだけ外れる）。（#70、2026-09-23、ユーザーの選択。#76 で実測した形を足した）
- `SELECT 1;` は本物では binary だが、Trino が弾くので判定を変えない。（#76、2026-09-23）
- `.txt` の判定は先頭の語で、`DESCRIBE`／`DESC`、`EXPLAIN`、`SHOW CREATE TABLE`（3 語目まで見る）が application、それ以外の `.txt`（`SHOW CREATE VIEW` を含む `SHOW` 系・DDL）が binary。`DESCRIBE`／`DESC`／`SHOW CREATE TABLE` の組は `.metadata` の先頭に QueryExecutionId を載せる組と同じなので、1 つの述語 `content_type::carries_execution_id` に集約して Content-Type と `metadata_query_id` の両方から呼ぶ（#151、2026-09-24。それまでは 2 語目までの同じ組を 2 か所に書いて「片方を変えたら両方を直す」としていた）。`SHOW CREATE TABLE` 以外の `SHOW CREATE ...` は Athena の構文に無く未実測なので既定の binary に落とす。INSERT・CTAS（`Manifest`／`Table`）は application。（#70、2026-09-23）
- `.csv` の `text/csv` は 0.3.0 からの未実測の推測値で、2026-09-17 の実測（6 件中 5 件が application、残る 1 件は `SELECT 1`）を根拠に `application/octet-stream` へ置き換えた。多数決で丸めていたことは #70 の規則で解消した。（#5、2026-09-17）

## `.metadata`

- protobuf は依存を足さずに手書きでエンコードする（varint と length-delimited だけ）。理由: proto3 の既定値の省略に頼れない（Scale 0 を明示する `40 00` を出す）ので prost は向かない。長さは UTF-8 のバイト長。（#5、2026-09-17）
- 先頭のクエリ ID（field 1）は文ごとに実測に合わせる。エンジン ID の文は Trino の応答の `id`、`DESCRIBE`／`DESC`／`SHOW CREATE TABLE` は athena-local の実行 ID。Trino の `id` が無ければ実行 ID。（#5、2026-09-17、ユーザーの判断 3）
- 本物が不透明な形式を置く `SHOW` 6 文（`SHOW TABLES`／`DATABASES`／`COLUMNS`／`PARTITIONS`／`TBLPROPERTIES`／`CREATE VIEW`。`CREATE VIEW` は #151、2026-09-24）にも素の protobuf を書く。先頭のクエリ ID は観測できないので EXPLAIN と同じくエンジン ID（#151）。理由: Trino から列情報が取れ、JDBC 3.5.1 未満は metadata が無いと NoSuchKey で落ちる。形式は特定できず、JDBC 3.8.1 は athena-local の protobuf を読めた。（#5、2026-09-17、ユーザーの判断 2、#24、2026-09-19）
- 型ごとの表は `ColumnInfo` の型名（Athena の型名。real は `float`）で引く。Nullable は定数 3。列の field 2 / 3（SchemaName／TableName）は書かない。（#5、2026-09-17）
- `ColumnInfo` の Precision／Scale を `Option` にして有無を持たせる案は採らない（`GetQueryResults` の JSON から `Precision` が消え、常に出す本物と食い違う）。`convert::column_infos` を `ColumnInfo` の唯一の生成元にし、`GetQueryResults` と `.metadata` の両方が通る。（#5、2026-09-17）
- top の field 2 / 3 は `outcome.update_count` が `Some` の文（DML・CTAS）にだけ書く。SELECT で `Some(0)` に化かす `operation::update_count` は使わない。`update_type` は `clone()` で写す（`take()` すると DML の data を行にしない判定が壊れる）。field 2 には Trino の `update_type` をそのまま渡す。（#5、2026-09-17、#41、2026-09-20）
- `.metadata` のキーは `ResultLocation::metadata()` だけが作る。`ResultFile::of` は `Metadata` を返さない。（#5、2026-09-17）
- `SELECT 1` の特別扱い（QueryExecutionId、空の field 2）は再現しない（エンジン ID で書く）。（#5、2026-09-17）
- varchar の Precision は typeSignature の引数（`varchar(n)` の n）をそのまま使い、引数が無いときだけ 2147483647。（#68、2026-09-22）

## テーブルの形式に依存する DDL

- `DROP TABLE` × Iceberg と `ALTER TABLE ... ADD COLUMNS` × Hive の結果ファイルは、Caveats に書くだけにせず、Trino に形式を問い合わせて本物に合わせる。（#39、2026-09-20、ユーザーの選択。#5 の「列が無ければ `.metadata` を置かない」を変更）
- テーブルの形式は SQL から読まず、Trino の `connector_name` に聞き、カタログ単位で判定する。理由: Trino の Hive と Iceberg は別カタログとしてしか共存できない。#26 が撤回した「SQL から形式を読む」やり方に戻らずに済む。（#39、2026-09-20）
- 形式と存在の確認は `system.jdbc.tables` の 1 クエリにまとめる（往復 1 回、カタログ名を識別子として SQL に埋めずに済む、対象が存在しない `DROP TABLE IF EXISTS` で本物と食い違わない）。（#39、2026-09-20、ユーザー確認済み）
- 修飾名のカタログも見る（1/2/3 パート、引用符の有無、`IF EXISTS`、コメント。カタログかスキーマが決まらなければ判定しない）。修飾名から取ったカタログにも別名を当て、引用符の無い名前は Trino の規則どおり小文字にする。問い合わせの SQL のリテラルとヘッダは同じ別名解決後のカタログ名を使う。（#39、2026-09-20、ユーザーの判断）
- カタログ未指定・問い合わせの失敗・未知の `connector_name` は、すべて今までどおりの扱いに倒す（判定しない）。（#39、2026-09-20）
- S3 への書き込みが無効なら形式を問い合わせない。取り消し済みなら問い合わせない。対象の文のときだけ問い合わせる。（#39、2026-09-20）→ `SHOW CREATE TABLE` と `DESCRIBE` は判定を `GetQueryResults` の `UpdateCount` にも使うので、S3 が無効でも問い合わせる（`table_format::needs_format_for_update_count`）。`DROP TABLE`／`ALTER TABLE` は今までどおり。（#160、2026-09-24、ユーザー確認済み）→ `SHOW COLUMNS` も行の形（Hive は詰める、Iceberg は詰めない）に使うので S3 が無効でも問い合わせる（関数名は改名しない）。（#173、2026-09-24）
- `UpdateCount` は `GetQueryResults` で決め直さず、完了時に `operation::completion::update_count` が文の種類・Trino の件数・形式の判定から決めて `Store::finish` に渡し、`Execution.update_count` に持つ（形式の判定は実行時にしか取れない。EXPLAIN の行分けと同じ「完了時に決めて finish に渡す」形）。null にする文は `content_type::carries_execution_id`（`DESCRIBE`／`DESC`／`SHOW CREATE TABLE`）と同じ述語で選び、判定を増やさない（本物でも `UpdateCount` の有無と Content-Type は一致する）。`DESCRIBE` × Iceberg は `FormatOverride::DescribeIceberg` として `ShowCreateTableIceberg` と同じ腕に並べる。（#160、2026-09-24）
- `DROP TABLE` × Iceberg の本体（改行 1 つ）と `ALTER` × Hive の本体（0 バイト）は条件をまとめずバリアントで分ける。`ADD COLUMNS` と `REPLACE COLUMNS` は Hive で同じ 38 バイトの `.metadata` を共有する（`(id, None, None)` で書く）。（#39、2026-09-20、#43、2026-09-21）
- 形式の問い合わせを `SHOW CREATE TABLE` にも使い（Iceberg なら本体・`.metadata` とも binary、先頭はエンジン ID）、`FormatOverride` に上書きの向きが逆（application ではなく binary）の腕 `ShowCreateTableIceberg` を足した。上書きの Content-Type・先頭 ID は `FormatOverride` のメソッドにせず `write_result` の `match` で腕ごとに分ける。（#151、2026-09-24）
- 形式で本体・`.metadata` の書き方を上書きする文の型は `FormatOverride`（決める関数は `format_override`）。DDL だけを対象にしていた頃の名前 `EngineDdl` が SHOW CREATE TABLE・DESCRIBE の腕で意味とずれたため改名した。DDL の腕だけが使う application の Content-Type の定数は `DDL_OVERRIDE_CONTENT_TYPE` とし、型名に揃えない（BINARY で上書きする腕に流用されないように）。（#151 では改名を見送った。#162、2026-09-25 で変更）
- 限界として、Athena は同じ `AwsDataCatalog` に両形式を混在させるが Trino は別カタログなので、本物と一致するのは利用者の Trino のカタログ構成と形式が揃っている場合だけ。これを利用者向けの文書に書く。（#39、2026-09-20）

## SHOW／DESCRIBE の列と行

- 列数と行が Trino と同じ文（`SHOW CREATE TABLE`／`SHOW CREATE VIEW`／`SHOW TABLES`／`SHOW SCHEMAS`）は `classification::fixed_column` で列名・型だけを置き換え、列数か行の形が違う文（`SHOW COLUMNS`／`DESCRIBE`／`DESC`）は `operation::utility_rows::reshape` で完了時に `Outcome` の列と行を作り直す。2 つは統合しない。理由: `fixed_column` は全列に同じ値を当てる作りで列数を変えられず、`SHOW CREATE VIEW` の varchar/0/false は SQL だけで決まる。（#173、2026-09-24）→ `SHOW CREATE TABLE`／`SHOW CREATE VIEW` の行は、Trino の改行入りの 1 値を完了時に `\n` で分ける（`completion::split_show_create_rows`。EXPLAIN の `split_explain_rows` と同じ置き場で、EXPLAIN と違って末尾に空行を足さない）。列は `fixed_column` のまま。（#181、2026-09-25）
- 作り直す位置は `run` の `split_explain_rows` の直後。作り直した `Outcome` が `write_result`（`.txt`・`.metadata`）と `Store::finish`（GetQueryResults）の両方に渡る（EXPLAIN の行分けと同じ形）。`update_count`・`id`・`update_type` は触らない。`convert` は SQL を読まないので `operation` に置く。（#173、2026-09-24）
- 作り直した文の ColumnInfo は `Outcome.athena_columns` に本物の値のまま持たせ、`convert::column_infos` はこれがあれば優先して `fixed_column` を当てない。`columns` は列名行と「列があるか」の判定用に名前だけ合わせて残す。理由: ビューの `column`／`type` は varchar で Precision 0・CaseSensitive false なので、`athena_type` の表（varchar は 2147483647／true）では作れない。`column_infos` が唯一の生成元という約束は、生成元の入口を 1 つに保つ形で守る。（#173、2026-09-24）
- 型の綴り（Hive のテーブルは `int`／`map<string,int>`、Iceberg のテーブルは `decimal(10, 2)`／`map<string, int>`）は実測した綴りだけを `operation::type_spelling` で写し、測っていない型は Trino の綴りのまま返して caveat に書く。Iceberg の `struct` の複数フィールドの区切りは測っていないが、`map` に倣って `, ` にする。（#173、2026-09-24、ユーザーの判断 D1）
- 形式が判定できないときは行も Hive の形に倒す（Content-Type・UpdateCount の既存の倒れ方と同じ）。（#173、2026-09-24）
- Iceberg のテーブルの `DESCRIBE` の `# Partition spec:` の下の行は、Trino の `DESCRIBE` から取れないので、対象の Trino の `SHOW CREATE TABLE` の `partitioning = ARRAY[...]` から作る（`operation::iceberg_partitions`。問い合わせは Iceberg × DESCRIBE のときだけ 1 本増える）。名前は元の SQL の範囲を `catalog::skip_qualified_name` で切り出して `alias_qualified_names` を当て、手で修飾名を組まない。失敗は握ってパーティション行を出さない（本体は SUCCEEDED のまま）。測っていない変換は行を出さない。（#173、2026-09-24、ユーザーの判断 D3）
- ビューへの `DESCRIBE`／`SHOW COLUMNS` の `SubstatementType`（`DESC_VIEW`）は形式の問い合わせ（`table_type`）の結果で完了時に決め、`Store::finish` に渡して `GetQueryExecution` が優先する。完了前は SQL から決まる値（`DESCRIBE_TABLE`／`SHOW_COLUMNS`）のまま。`UpdateCount` を完了時に決める #160 と同じ形。（#173、2026-09-24、ユーザーの判断 D11）
- `DESC` は `DESCRIBE` と同じく `DESCRIBE_TABLE` に分類する（形式の問い合わせ・`.metadata` の先頭 ID・UpdateCount も同じ）。（#173、2026-09-24、ユーザーの判断 D10）

## EXPLAIN

- `EXPLAIN` の結果は Trino が返す 1 行（改行入りのプラン全文）を `\n` で分け、末尾に空行を 1 つ足して `Rows` にする（`split_explain_rows`）。分けた行を `write_result` と `Store::finish` の両方に渡し、`GetQueryResults` と `.txt` を揃える。boolean の値（`TYPE VALIDATE`）も文字列にして同じく空行を足す。（#73、2026-09-23、#92、2026-09-23）

## オペレーション

### GetWorkGroup／ListWorkGroups

- `GetWorkGroup` は任意の名前を受け付け、その名前を `Name` に返し、名前を理由にエラーを返さない。`State`／`Configuration` はリクエストによらず、環境変数と実測した固定値だけで決まる。理由: athena-local にワークグループの実体が無く、dbt-athena と Grafana は独自の名前を使う。（#2、2026-09-16）
- `StartQueryExecution` の `WorkGroup` を `GetQueryExecution` が返す。省略時は `primary`。既定の名前（`DEFAULT_WORK_GROUP`）は `src/config.rs` の 1 か所で定義し、既定を当てるのも 1 か所。（#2、2026-09-16、#9、2026-09-18）
- `ResultConfiguration` は本物に合わせて常に返す（出力先があれば `{"OutputLocation": ...}`、無ければ `{}`）。（#2、2026-09-16）
- awswrangler が出力先の無いときに実 AWS へ出る件は利用者向けの文書に書くだけで、コードでは防がない（`ManagedQueryResultsConfiguration` は定義しない）。理由: 本物に合わせる目的から外れる、守れるのは一部の経路だけ、`AWS_ENDPOINT_URL` を設定していれば実 AWS には出ない、awswrangler 自身も警告を出す。（#2、2026-09-16）
- `ATHENA_LOCAL_OUTPUT_LOCATION` が無いときは、`ATHENA_LOCAL_RESULTS` によらず起動時に同じ文言の警告を標準エラーに 1 行出す。起動は止めず、API の形も変えない。（#20、2026-09-19、ユーザーの選択）
- `CreationTime` は返さない。理由: 作成時刻の実体が無く、どんな値も偽になる。`Description` は `GetWorkGroup` では省き、`ListWorkGroups` では常に空文字（本物の「説明の無いワークグループ」と同じ）。`IdentityCenterApplicationArn`（本物に無かった）、ワイヤ上の `EngineVersion.Category` と `Configuration.QuerySchedulingType`（SDK のモデルに無い）は返さない。`EnableMinimumEncryptionConfiguration` は 2026-09-23 に値（false）が採れたので返す。（#2、2026-09-16、#9、2026-09-18、#137、2026-09-23）
- `ListWorkGroups` の一覧は環境変数 `ATHENA_LOCAL_WORK_GROUPS` で列挙し、未設定なら `primary` の 1 件。一覧は `GetWorkGroup` の入力を制限せず、`primary` を自動で足さない。名前の辞書順で返す（整列済みを `Config` の不変条件にする）。カンマ区切り・要素ごとに trim・空要素は起動時エラー・重複と名前の形式は検査しない。（#9、2026-09-18、ユーザーの判断）
- 一覧が 1 ページに収まるときは `NextToken` をキーごと省く（空文字にしない）。理由: Grafana は `nextToken == nil` しか見ないので、空文字だと無限ループする。`NextToken` の中身はオフセットの 10 進文字列。既定のページサイズは 50。（#9、2026-09-18）
- `State` と `EngineVersion` は `GetWorkGroup` と `ListWorkGroups` で定数と関数を共有し、食い違わないことをコンパイラで保証する。（#9、2026-09-18）

### GetQueryResults と ListWorkGroups のページング検証

- `MaxResults`／`NextToken` は実測どおりに検証し、枠組みの検証と制約の文言は `src/operation/validation.rs` に置いて両方のオペレーションから呼ぶ（`query_execution.rs` が `work_group.rs` に依存する形は避ける）。枠組みの違反は nextToken → maxResults の順に集めて 1 文にする。（#9、2026-09-18、#83、2026-09-23）
- `GetQueryResults` の検証の順序は実測どおり（枠組み → ID の存在 → 上限 → クエリの状態 → トークンの形）。上限 1000 は枠組みではない別の文言で、既定のページサイズ（列名行込み）と同じ定数にする。（#83、2026-09-23）
- 範囲の比較は整数型のまま行い、`usize` へのキャストは検証の後。理由: `-1` が巨大値になり、`0` だと `NextToken` が進まず Grafana が無限ループする。（#9、2026-09-18、#83、2026-09-23。#84 で `i32` から `i64` に変更）
- `NextToken` の形の検査は両オペレーションで同じ式にし、文言だけ実測どおりに分ける。不正なトークンの文言には受け取った値をそのまま載せる。（#9、2026-09-18、#83、2026-09-23）
- `GetQueryResults` の `NextToken` はページが満杯のときに発行する。0 行の UTILITY の結果に渡された `NextToken` は無視する。トークンの形の検査は `len` ちょうども通す。枠組みの検証に上限 100000 を足す。（#85、2026-09-23）

### StartQueryExecution と ClientRequestToken

- 同じトークン・同じパラメータなら、先行クエリの状態によらず同じ `QueryExecutionId` を返し、新しい実行を作らない。（#3、2026-09-17）
- フィンガープリントは `QueryString`・`QueryExecutionContext.Catalog`・`QueryExecutionContext.Database`・`ResultConfiguration.OutputLocation` の 4 つで、既定を当てる前の生のリクエスト値で比べる。`ExecutionParameters` と `WorkGroup` は本物が比べないので入れない。`Catalog` は #3 では測っていなかったので入れず、#146 で本物が比べる（大文字小文字違いも衝突）と分かったので #150 で足した。`OutputLocation` の「省略」と「既定と同じ値の明示」は、本物では強制するワークグループでしか測れておらず（同じ ID）、athena-local が当たる強制しない条件は未実測なので、生の値で比べたまま（ユーザー判断）。（#3、2026-09-17 → #150、2026-09-24）
- トークンは正規化しない。正規化が要ると分かったら `Store` に渡す直前の 1 箇所だけ直す。（#3、2026-09-17）
- トークンの照合は `submit` の 1 ロックの中（`OutputLocation` の検証と構文チェックの後）で行い、早期のチェックは置かない。構文エラーで弾かれたトークンは登録されない。理由: 判定を 2 箇所に持つとずれを作れる。（#3、2026-09-17）
- トークンの長さは 32 文字未満（空文字を含む）と 129 文字以上を本物と同じ文言で弾き、文字数で数える。キーが無いときは自前の文言（`clientRequestToken is null or empty`）で、本文の解釈の後に見る。（#3、2026-09-17、#84、2026-09-23）
- `AthenaErrorCode` 付きのエラーの本文は `{"__type","AthenaErrorCode","ErrorCode","Message"}`（`ErrorCode` は `AthenaErrorCode` と同じ値、キーは大文字始まりの `Message`）。`x-amzn-errortype` ヘッダは付けない。本物に無いことは #3・#9・#83・#84・#87・#147（2026-09-17〜24）の生 HTTP で一貫して確かめた。#3 では「SDK は `__type` を先に見るので消す理由も無い」と残したが、Rust / Java の SDK はヘッダを先に見て、無ければ本文の `__type` にフォールバックし（botocore は本文しか見ない）、値は常に `__type` と同じだったので、外しても決まる例外の型は変わらない。（#3、2026-09-17 → #145、2026-09-24）

### リクエスト本文の解釈

- 本文の解釈は `src/request.rs` に置き、`response.rs` は応答の組み立てにする。serde のエラーは種類（`Category`）だけでは分けられないので、エラー文の先頭で分ける（`missing field` → 枠組みの検証、`invalid type` → 実測の文言、それ以外 → `Message` 無し）。（#84、2026-09-23）
- `MaxResults` は `Option<i64>` で受ける。理由: Integer の範囲外を本物は上限の検証エラーにするので、serde のエラーにせず上限の検査に流す。（#84、2026-09-23）
- 小数の切り捨ては入れない（SDK・JDBC・Grafana は整数で送る。切り捨ては全フィールドにかかる）。配列 → 入れ子の構造体（serde の derive が位置順に読んで通す）も揃えない。`Content-Type` は見ない。どれも差を Caveats に書く。（#84、2026-09-23）

### その他

- 起動時の設定エラーは平文 1 行を標準エラーに出し、終了コード 1 で止める。（#55、2026-09-22）
- JDBC 3.x 向けの TLS 終端は athena-local に入れず、nginx での手順を利用者向けの文書に書く。（#18、2026-09-18）

## 状態の保存先（Store）

以下は旧 TODO.md（#98 で docs/dev/ に割って削除）の「設計メモ：状態の保存先」（2026-09-16）から。

- 当面はメモリ上の `Store` のままにする。状態の出入口は `Store` の公開メソッドにまとまり、呼び出しは `operation` モジュールだけなので、あとから保存先を差し替えやすい。
- DB を入れても、保持期限による破棄は別に必要になる。
- SQLite を検討する目安は次の二つ。
  - 再起動をまたいでクエリの履歴を残したくなったとき。
  - 名前付きクエリ、プリペアドステートメント、データカタログのように、作成・更新・削除する API を増やすとき。
- DuckDB は状態の保存には向かない。分析向けの列指向 DB で、Rust から使うと C++ の本体ごとビルドすることになり、2 アーキテクチャのイメージビルドも重くなる。
- 永続化するなら、次の前提を見直す。
  - `Store` の「本物の永続性は模さない」という方針。
  - Docker イメージが、書き込み無しで nobody ユーザーとして動く前提。
  - 再起動で途中になった実行の扱い。

- `Store` にワイヤ用の DTO（`athena.rs` の型）を持ち込まない。`submit` の引数が増えたら専用の `Submission` 構造体にまとめる（`clippy::too_many_arguments` は構造体のフィールド数を数えない）。理由: 型 1 つのコストより層の境界を保つ。（#2、2026-09-16）
- `tokens` は `executions` と同じ 1 つの `Mutex`（`Inner`）に同居させ、両方の登録を `submit` の 1 ロック内で行う。`Inner` は `store.rs` の外に出さない。フィンガープリントは `tokens` の `Claim` にだけ持ち、`Execution` には持たせない。理由: 別の Mutex 2 本だと同じトークンに 2 つの実行ができる（TOCTOU）。（#3、2026-09-17）
- 二重実行の最後の防波堤は `Store::mark_running` の「QUEUED からしか進めない」ガード。（#3、2026-09-17）
- 終わった実行は、終端状態になってからの経過時間だけで捨てる（件数の上限は入れない）。既定は 1 時間で、本物の保持期間は測っていないので athena-local の都合で決めた値。起点は終端になった時刻で、読んでも延びない。トークンだけ別の期限にする案も採らない。（#4、2026-09-17、ユーザーの回答）
- 設定は `ATHENA_LOCAL_RETENTION_SECONDS`（秒の整数）。数として読めない値と 0 は起動時に止める（0 を無期限と思った人が全部の結果を失う事故を防ぐ）。trim しない。既定値の 3600 は `src/config.rs` の定数 1 か所だけに書く。（#4、2026-09-17）
- 定期タスクは作らず、`Store` の公開メソッドがロックを取った直後に `Inner::sweep(now)` で期限切れを捨てる。理由: 定期タスクの前例が無く、テストのハーネスごとにタスクが増える。全公開メソッドがロックを通るので掛け忘れが起きず、テストが決定的になる。（#4、2026-09-17）
- 実行を捨てるときは、その実行を指すトークンも同じ掃除で捨てる。`completed_at` が無い（QUEUED／RUNNING）ものは捨てない。捨てた後の応答は未知の ID と同じ `QUERY_EXECUTION_NOT_FOUND`。（#4、2026-09-17）
- `Store` と `Inner` の `Default` derive は外し、`Store::new(retention)` で明示的に作る（残すと保持期限 0 の経路ができる）。時計は注入せず、`Inner::sweep(now: f64)` を分けてユニットテストで時刻を渡す。（#4、2026-09-17）

## テスト

- テストの足場の `Harness::call` は、`StartQueryExecution` でトークンが無ければ SDK と同じく呼び出しごとに UUID を入れる。トークン無しを送るテストだけ `call_raw` を使う。（#3、2026-09-17）
- テストの期待値に実測の値を使うときは、生バイトを 16 進リテラルで写し、採取元と日付をコメントに書く。生データはリポジトリに入れない。（#5、2026-09-17）
- テストの偽 Trino には本物と同じ typeSignature（`EXPLAIN` なら `varchar(371)`）を入れて固定する。（#68、2026-09-22）
- 結合テストの足場の `Config` は構造体リテラルで `parse_*` を通らないので、設定の解釈（順序など）は `config.rs` のユニットテストで確かめ、足場には解釈済みの値を渡す。（#9、2026-09-18）
- テストは機能ごとのファイル（`tests/dml.rs` が `StatementType`、`tests/results.rs` が `OutputLocation`、`tests/metadata.rs` が `.metadata` など）に足し、入力の形ごとに新しいファイルを作らない。`SubstatementType` は `StatementType` と同じ経路で作られるので、ユニットテストの表で固定する。（#17、2026-09-18）
- ユニットテストは、そのテストが直接呼ぶ関数の定義先のファイルに置く。テスト名は変えない（`cargo test <部分一致>` の絞り込みを保つ）。テストヘルパが複数ファイルで要るときは数行の複製を許し、`#[cfg(test)]` の境界を越えて共有する配線は作らない。（#19、2026-09-18、#30、2026-09-20）
- 結合テストの待ちは回数ではなく経過時間で諦め、上限は 30 秒（`wait_until_gone` は #61、`wait_for` と `run_query` は #67）。ポーリングは 20 ms。panic の文言には待った時間と最後の応答を入れる。時計は `std::time::Instant`。（#61・#67、2026-09-22。#4 の「20 ms × 100 回 = 2 秒」を変更）
- 保持期限のテストは期限を 200 ms に縮めて実時間で待ち、`run_query` は使わない（期限切れの 400 を「終わった実行」として返してしまう）。捨てた後は `call` の status を見る。遅延に頼る回帰テストには経過時間の断言も入れる。（#4、2026-09-17、#61、2026-09-22）
- red を作れないリファクタでは、挙動を固定するテストを先に別コミットで足し、期待値は着手前のコードに一時テストを流した出力をそのまま焼き込む。（#49、2026-09-22）

## モジュールの分割

- ファイル分割の軸は「`App`／`Response` を扱うディスパッチ本体」と「それが呼ぶロジックの塊」。「Trino や Store を叩くか」は軸にしない。（#2、2026-09-16）
- `src/` にディレクトリを入れることを受け入れる。`operation/` は責務ごとのファイルに割り、実行系／参照系の 2 分割やオペレーションごとのファイルにはしない。新しいオペレーションは `operation/` に新しいファイルとして足す。（#19、2026-09-18）
- 分割の基準は「本体が 400 行を超えるか」「人間が 1 画面でレビューできるか」。行数はファイル全体（本体＋テスト）で測る。テストだけのファイルには 400 行の基準を当てない。移動先の新しいファイルが 200 行を超えても、新規のコードでなく、責務が 1 つで、成長の予定が無いなら割らない。（#19、2026-09-18、#30、2026-09-20、#75、2026-09-23）
- 同じモジュールの中のサブモジュールで共有する関数は `pub(super)`、外に出す関数は実装ファイルで `pub` にして `mod.rs` の `pub(crate) use` で絞る。共有のヘルパは `mod.rs` に置かず、責務の合うファイルに置く。（#19、2026-09-18、#30、2026-09-20）
- `operation/` の新しいファイルはネストせず直下に置く。呼び出し元が 1 つだけの補助関数は呼ぶ側と一緒に移し、可視性を変えない。（#44、2026-09-21）
- 越境の呼び出しは、関数はフルパス（`super::render::to_var_char_value(...)`）で書き、パターンマッチで多用する型だけ `use` してよい。（#30、2026-09-20）
- 実測の文言の定数は使う関数と同じファイルに置き、`messages.rs` のように集めない（「なぜこの文言か」を読むのに 2 ファイルを往復させない）。（#19、2026-09-18）
- 分割後の各ファイルには 1 行の `//!` を書き、そこに「実測」「採取」の語を入れない（実測の記録の突き合わせの件数を保つ）。（#30、2026-09-20、#75、2026-09-23）
- 分割後に存在しなくなるファイル名を指すコメントと文書は直す（出典の issue 番号は書き換えない）。（#19、2026-09-18、#44、2026-09-21）

## リファクタの検証

- ファイルを移すときは、行番号の範囲ではなく「関数・定数とその直前の `///` ブロックと属性」を 1 単位として運ぶ。理由: `missing_docs` が無効なので、doc（実測の記録）の取りこぼしは fmt・clippy・test では検出されない。（#19、2026-09-18、#44、2026-09-21）
- 移動の前後で、テストの総数とファイルごとの内訳、`///` の行数、「実測」「採取」を含む行の集合を機械的に突き合わせる。期待値（テストの件数など）は内訳から数え直す。（#19、2026-09-18、#30、2026-09-20、#44、2026-09-21、#75、2026-09-23）
- 移動の検証は `git diff -M` ではなく正規化 diff（`use`・`mod`・`//!`・空行を除き、インデントを潰してソートした行の diff）で行い、出てよい差分（可視性、呼び出しの修飾、テストモジュールの枠）を先に許容リストにする。それ以外が 1 行でも残れば NG。理由: `git diff -M` は類似度が低くて使えなかった。（#30、2026-09-20、#44、2026-09-21）
- 分割の検証手順: (1) テスト総数と `--lib <モジュール>` の件数、fmt、clippy (2) ファイルごとの本体行数と全体行数 (3) 本体の分岐の計数（`if`／`match`／`=>`／`return`／`fn`）(4)「実測」「採取」を含む行の前後の diff (5) 上の正規化 diff (6) ファイルごとのテスト件数の内訳。（#30、2026-09-20）
- 抽出の各段で `cargo clippy --all-targets --locked -- -D warnings` も走らせる（`unused_imports` は `cargo build` では警告だけで通る）。（#30、2026-09-20）
- ファイルの分割とその文書（CLAUDE.md）の追随は別のコミットにし、分割のコミットを機械的に検証できる純粋な移動として孤立させる。（#30、2026-09-20、#75、2026-09-23）
- 似た関数の統合は「挙動を変えない移動」ではなく挙動の変更として扱う。ただし着手前の基準値の実測、機械的な合否判定、わざと壊して足場が NG を出すことの確認は借りる。doc を別ファイルへ写すときは「実測」を含む行の文言をそのまま保つ。（#49、2026-09-22）
