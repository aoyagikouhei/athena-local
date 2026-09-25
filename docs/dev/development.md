# 開発

athena-local をビルド・テスト・リリースするための手順（コントリビュータ向け）。

## コマンド

ホストで直接でも toolbox（下の「検証の足場（toolbox）」）でも動く（`tools/dev.sh cargo test` のように前に付ける）。既定は toolbox。ホストに rust があればホスト直でも動く（`target/` は toolbox の `.toolbox/target` と別）。

```bash
tools/dev.sh cargo run                             # 実行には到達できる Trino が要る。既定の TRINO_URL は http://trino:8080（先に `docker compose -f compose.yml up -d trino`）
tools/dev.sh cargo test                            # Trino も AWS も要らない（テスト内で偽物を立てる）
tools/dev.sh cargo test --test parameters          # 結合テストを 1 ファイルだけ（tests/<名前>.rs）
tools/dev.sh cargo test --test select ページング      # テスト名の一部で絞る（テスト名は日本語）
tools/dev.sh cargo test --lib config::tests        # src 内のユニットテストだけ
tools/dev.sh cargo fmt --check
tools/dev.sh cargo clippy --all-targets --locked -- -D warnings
tools/dev.sh docker build -t aoyagikouhei/athena-local:dev .
tools/dev.sh tools/e2e/minio/verify.sh             # 検証の足場（tools/e2e）。環境は compose.yml の trino / minio など。同時に流すなら COMPOSE_PROJECT_NAME
```

ルートの `Cargo.toml` は workspace を兼ね、`default-members` に内部 crate（`crates/athena-sql`）も入れているので、上のコマンドは `-p`／`--workspace` なしで crate にも効く（`cargo test` の出力に crate の `unittests` と `Doc-tests` の行が足される）。`--test <名前>` は athena-local の結合テストだけ、`--lib <パス>` は両方の lib で走る（crate 側は filtered out）。`Cargo.lock` はルートの 1 つだけで、crate の版は追わない（[decisions.md](decisions.md) の「SQL の内部 crate（athena-sql）」）。

CI（`.github/workflows/ci.yml`）の `check` ジョブはホストランナーで直に cargo を回す。`e2e` ジョブは toolbox の中で request-errors と paging-validation と quoted-names（#207）を流し、`cargo test --locked` を回す（amd64 の toolbox で通すため。#184）（toolbox のイメージは GHA キャッシュ、cargo は `.toolbox/target/release` だけキャッシュ）。

## 検証の足場（toolbox）

検証の足場（`tools/e2e/`）は、ホストで直接叩かず toolbox の中で動かす（理由は [decisions.md](decisions.md) の「開発の足場」）。toolbox はルートの [compose.yml](../../compose.yml) の dev サービスとして定義してあり、[tools/dev.sh](../../tools/dev.sh) がその呼び口（`docker compose run --rm --use-aliases dev env -- <コマンド>` の薄い包み）。ホストに要るのは Docker（compose プラグイン付き）だけで、daemon はルート権限で動くもの（ソケットが `/var/run/docker.sock`）に限る。rootless docker では動かない（下の「確かめた環境」。#184）。

```bash
tools/dev.sh cargo test
tools/dev.sh cargo clippy --all-targets --locked -- -D warnings
tools/dev.sh tools/e2e/minio/verify.sh
tools/dev.sh KEEP_UP=1 SKIP_BUILD=1 tools/e2e/minio/verify.sh   # 環境変数はコマンドの前に並べる
tools/dev.sh bash -c 'cargo test 2>&1 | tail -n 5'             # パイプやリダイレクトは bash -c の中に書く
```

- 入っているもの（[tools/toolbox/Dockerfile](../../tools/toolbox/Dockerfile)）: Rust（`rust:1.98-bookworm`。clippy・rustfmt 付き）、jq、python3（venv・pip・boto3）、docker CLI と compose、curl、uuidgen、ss、openssl、mc（マルチアーキの manifest list のダイジェストで固定。#129。S3 の確認は `mc alias set local http://minio:9000 ...` で直接見る）、awscli v2（2.37.0。版付きの zip で固定。#129。`tools/measure` が呼ぶ）。
- 環境変数は `tools/dev.sh VAR=値 <コマンド>` の形で渡す（`env` の代入として効く）。`KEEP_UP=1 tools/dev.sh ...` のようにホスト側で前に置いても、コンテナには届かない。
- 引数の `~` や `$VAR` はホストのシェルが展開してから渡る。コンテナの中で展開したいもの、パイプ、リダイレクトは `bash -c '...'` に書く。
- リポジトリの中のどこからでも呼べて、cwd はそのままコンテナに引き継ぐ。リポジトリの外では止まる。
- コンテナの中の HOME・`CARGO_HOME`・`CARGO_TARGET_DIR` はリポジトリの `.toolbox/` の下（`home/`・`cargo/`・`target/`）。python-clients の venv（`home/.cache/athena-local-111`）と JDBC のドライバ（`home/.cache/athena-local-jdbc`）も `home/` の下に置かれる。ホストの `~/.cargo` と `target/` とは混ぜない。足場は athena-local の起動パスを `BINARY` 変数で `CARGO_TARGET_DIR` に追随させている。
- `.toolbox/` を消すときは `rm -rf .toolbox`（イメージ以外は次の実行で作り直される。venv は `tools/dev.sh tools/e2e/python-clients/setup-venvs.sh` を流し直し、JDBC のドライバは足場が取り直す）。
- イメージのタグは `tools/toolbox/Dockerfile` の sha256 から決まるので、Dockerfile を変えると次の実行で作り直される。
- dev サービスは compose のネットワークに入り、足場は `trino:8080` / `minio:9000` のサービス名で相手に届く。ホストにはポートを公開しない（人間が Trino を触るときは `docker compose -f compose.yml exec trino trino --execute 'SELECT 1'` か `tools/dev.sh curl http://trino:8080/v1/info`）。`/tmp` はホストと同じパスで共有しているので、足場が表示する証跡のパスはホストからそのまま開ける。

### 実測（tools/measure）

実測（`tools/measure`）も toolbox で動かす。`AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... tools/dev.sh bash tools/measure/get-work-group.sh`
のように、資格情報はホストのシェルの環境変数として渡す（`~/.aws/credentials` でも届く）。出力はホストの `~/athena-*-measurements`
（dev にホストのホームを同じパスでマウントし、`DEV_HOST_HOME` を既定の出力先にしている）。`opaque-metadata-form.sh` は
aws を呼ばず保存済みの実測データを検算するだけなので、ホストで直接流す（xxd を使う）。

### 足場の環境と同時実行

足場が相手にする環境は、ルートの [compose.yml](../../compose.yml) の次のサービス（どれもホストにポートを公開しない）。

| サービス | 中身 | 足場からの宛先 |
|---|---|---|
| `trino` | `trinodb/trino`（既定 482）。カタログは hive / iceberg / memory | `trino:8080` |
| `minio` | S3 互換ストレージ | `minio:9000` |
| `minio-init` | バケット `athena-results` を作って終わる使い捨て | — |
| `tls-proxy` | nginx。Athena JDBC 3.x の前で TLS を終端し、`dev:8087`（athena-local）と MinIO に中継する | `tls-proxy:8443`（athena-local）、`tls-proxy:9443`（MinIO） |
| `jdbc-client` | 公式 Athena JDBC ドライバを動かす maven。常駐させず `docker compose run --rm` で使う | — |

athena-local 自身は dev の中のプロセスで、足場は `127.0.0.1:<port>` で叩く。tls-proxy から届く必要がある jdbc 系の足場だけ `0.0.0.0:8087` で待たせる。

付属物は `tools/compose/` にある: `catalog/`（hive・iceberg・memory の 3 つ）、`tls/`（`nginx.conf` と、自己署名証明書を作る `make-cert.sh`）、`jdbc-client/`（`Main.java` などの JVM 側）。証明書と鍵はリポジトリに入れないので、新しい clone では `tools/dev.sh bash tools/compose/tls/make-cert.sh` で作る（jdbc-drivers の足場は無ければ自分で作る）。

- 足場は開始時に、使うサービスだけを `docker compose -f compose.yml down -v <サービス...>` → `up -d <サービス...>` で作り直す。前の走行の残骸（テーブル、結果ファイル、nginx のログ）で判定が狂う足場があるため。
- 後始末の trap も同じサービスだけを `down -v` する。dev は残す。`KEEP_UP=1` で残した環境のうち、次に流した足場が使うサービスは、その足場の開始時に作り直される（使わないサービス、例えば jdbc 系だけが使う tls-proxy は残る）。手で落とすときはリポジトリのルートで `tools/dev.sh docker compose -f compose.yml down -v <サービス...>`（サービス名を必ず並べる。`-f` は cwd からの相対パス）。
- **同じプロジェクト名で 2 つの足場は流せない**（片方の開始時の `down -v` が、もう片方の Trino を走行の途中で消す）。開始時に「同じプロジェクトで別の足場が動いている」と出して止まる足場がある（jdbc 系 3 本（jdbc-drivers・jdbc-metadata・jdbc-show-metadata）、python-clients、retention、trino-probe の versions.sh）。
- 同時に流すなら、プロジェクト名をホストの環境変数で分ける: `COMPOSE_PROJECT_NAME=athena-local-b tools/dev.sh tools/e2e/minio/verify.sh`。dev もその中の足場も同じ別プロジェクト（別のネットワーク・コンテナ・named volume）で動く。`tools/dev.sh COMPOSE_PROJECT_NAME=... <コマンド>` の形では dev 自身が既定のプロジェクトに入り、足場だけが別のプロジェクトになるので効かない。
- プロジェクトを分けても同時に流せないもの: jdbc 系の 3 本（`tools/e2e/jdbc-drivers/verify.sh`、`tools/measure/jdbc-metadata.sh`、`tools/measure/jdbc-show-metadata.sh`）は、どのプロジェクトからも `tools/compose/jdbc-client/target` を bind するので、同時に 1 本だけ。
- named volume（Trino のデータ、MinIO のデータ、maven のキャッシュ `jdbc-client-m2`）はプロジェクトごとに別。共有されるのは `.toolbox/`（cargo はロックで直列にする）と `/tmp`（証跡は `mktemp` で一意）だけ。
- jdbc 系の足場の走行中に、同じプロジェクト名で `tools/dev.sh cargo test` のような足場でないコマンドを動かすのはかまわない。そのあいだ compose のネットワークでは `dev` が 2 つのアドレスに解決されるが、tls-proxy の nginx は `resolver` 無しで `dev:8087` を書いているので名前解決は起動時の 1 回だけで、jdbc 系の足場は開始時に tls-proxy を作り直し、preflight で別の dev がいれば止まる。つまり nginx が掴む `dev` は足場の dev の 1 つだけになる（#131）。

### 確かめた環境

WSL2 の Ubuntu 24.04、ネイティブの Docker Engine、arm64 で、2026-09-25 に次を確かめた（#131。#127・#128 の人間検証の残り）。amd64 では CI の e2e ジョブ（ubuntu-24.04）が toolbox の中で `tools/dev.sh cargo test --locked` を毎回流す（#184）。Docker Desktop と、`~/.aws/credentials` だけでの実測は未確認（#184）。

- `tools/dev.sh tools/e2e/minio/verify.sh` の走行中（ケース 1 の実行中）に端末で Ctrl-C を押すと、1 秒で終了コード 130 で抜け、足場の trap が `down -v trino minio minio-init` を流す。`docker ps -a --filter label=com.docker.compose.project=athena-local` は dev も含めて 0 件になる（compose.yml の `init: true` が効いている）。
- `tools/dev.sh tools/e2e/jdbc-drivers/verify.sh` を既定の全 7 版（3.8.1〜3.0.0）で最後まで流して FAIL 0。
- その走行中に同じプロジェクト名で `tools/dev.sh cargo test --locked` を動かし、tls-proxy から `dev` が 2 つのアドレスに解決されている間も、cargo test は全件通り、tls-proxy のログに接続失敗・upstream のエラー・5xx は 0 件（上の同時実行の項目の理由による）。
- `tools/dev.sh tools/e2e/trino-probe/versions.sh` を既定の 5 版（480 475 470 440 400 の pull から）で最後まで流して FAIL 0（結果は [measurements/trino.md](measurements/trino.md) の #131 の節）。

rootless docker（同じマシンに `dockerd-rootless-setuptool.sh install --force` で並べて入れ、CLI のコンテキストを `rootless` にした）では、toolbox のイメージはビルドできるが `tools/dev.sh cargo test` が `could not find Cargo.toml` で止まる（2026-09-25。#184）。理由は 2 つ:

- rootless ではホストのユーザーがコンテナの root に対応し、compose.yml の `user: "${DEV_UID}:${DEV_GID}"`（コンテナの 1000）はホストの subuid（100999 など）になる。権限 750 のホームの下のリポジトリに入れず（`Permission denied`）、入れたとしても作るファイルがホストのユーザーの持ち物にならない。
- `tools/dev.sh`（`DOCKER_GID`）と compose.yml（マウント）は `/var/run/docker.sock` を決め打ちしている。rootless の daemon のソケット（`$XDG_RUNTIME_DIR/docker.sock`）は渡らず、マウントされたルート権限の daemon のソケットは `nobody:nogroup` に見えて、dev の中の `docker` はどちらにもつながらない。

対応するなら、rootless のときだけ dev を uid 0 で動かし、ソケットを `DOCKER_HOST` から決める形になる（未着手）。

## テスト

テストは本物のルーターを、同じプロセス内に立てた偽 Trino と偽 S3 に向けて動かす。そのため Athena のワイヤ上の形（ヘッダ行、`UpdateCount`、ページング、エラーの写し方）、パラメータの分類、そしてパラメータの無い SQL がカタログの別名を除いて書き換えずに渡されることを確かめられる。CI は main への push とプルリクエストのたびに（手動でも起動できる）`fmt`、`clippy`、`test` と、軽い e2e の足場 3 本（request-errors、paging-validation、quoted-names）を回す。

## リリース

コミットに `v*` のタグを付けると、GitHub Actions が `linux/amd64` と `linux/arm64` のイメージを Docker Hub に publish する（シークレットは `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`）。アーキテクチャごとにネイティブのランナーでビルドし、結果を 1 つのマニフェストにまとめるので、QEMU のエミュレーションは使わない。

手順（版の書き換え、PR、タグ、publish の確認、止まる条件）はリポジトリの Skill `.claude/skills/release/SKILL.md` にある。Claude Code では `/release X.Y.Z` で呼ぶ。
