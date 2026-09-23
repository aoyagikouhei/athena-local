# 開発

athena-local をビルド・テスト・リリースするための手順（コントリビュータ向け）。

## コマンド

ホストで直接でも toolbox（下の「検証の足場（toolbox）」）でも動く（`tools/dev.sh cargo test` のように前に付ける）。

```bash
cargo run                                          # 実行には到達できる Trino（TRINO_URL）が要る
cargo test                                         # Trino も AWS も要らない（テスト内で偽物を立てる）
cargo test --test parameters                       # 結合テストを 1 ファイルだけ（tests/<名前>.rs）
cargo test --test select ページング                  # テスト名の一部で絞る（テスト名は日本語）
cargo test --lib config::tests                     # src 内のユニットテストだけ
cargo fmt --check
cargo clippy --all-targets --locked -- -D warnings
docker build -t aoyagikouhei/athena-local:dev .
```

## 検証の足場（toolbox）

検証の足場（`tools/e2e/`）は、ホストで直接叩かず toolbox の中で動かす（理由は [decisions.md](decisions.md) の「開発の足場」）。toolbox はルートの [compose.yml](../../compose.yml) の dev サービスとして定義してあり、[tools/dev.sh](../../tools/dev.sh) がその呼び口（`docker compose run --rm --use-aliases dev env -- <コマンド>` の薄い包み）。ホストに要るのは Docker（compose プラグイン付き）だけ。

```bash
tools/dev.sh cargo test
tools/dev.sh cargo clippy --all-targets --locked -- -D warnings
tools/dev.sh tools/e2e/minio/verify.sh
tools/dev.sh KEEP_UP=1 SKIP_BUILD=1 tools/e2e/minio/verify.sh   # 環境変数はコマンドの前に並べる
tools/dev.sh bash -c 'cargo test 2>&1 | tail -n 5'             # パイプやリダイレクトは bash -c の中に書く
```

- 入っているもの（[tools/toolbox/Dockerfile](../../tools/toolbox/Dockerfile)）: Rust（`rust:1.98-bookworm`。clippy・rustfmt 付き）、jq、python3（venv・pip・boto3）、docker CLI と compose、curl、uuidgen、ss、openssl。awscli と mc は入れていない（足場は使わない。S3 の確認は `minio/mc` の使い捨てコンテナ）。
- 環境変数は `tools/dev.sh VAR=値 <コマンド>` の形で渡す（`env` の代入として効く）。`KEEP_UP=1 tools/dev.sh ...` のようにホスト側で前に置いても、コンテナには届かない。
- 引数の `~` や `$VAR` はホストのシェルが展開してから渡る。コンテナの中で展開したいもの、パイプ、リダイレクトは `bash -c '...'` に書く。
- リポジトリの中のどこからでも呼べて、cwd はそのままコンテナに引き継ぐ。リポジトリの外では止まる。
- コンテナの中の HOME・`CARGO_HOME`・`CARGO_TARGET_DIR` はリポジトリの `.toolbox/` の下（`home/`・`cargo/`・`target/`）。python-clients の venv（`home/.cache/athena-local-111`）と JDBC のドライバ（`home/.cache/athena-local-jdbc`）も `home/` の下に置かれる。ホストの `~/.cargo` と `target/` とは混ぜない。足場は athena-local の起動パスを `BINARY` 変数で `CARGO_TARGET_DIR` に追随させている。
- `.toolbox/` を消すときは `rm -rf .toolbox`（イメージ以外は次の実行で作り直される。venv は `tools/dev.sh tools/e2e/python-clients/setup-venvs.sh` を流し直し、JDBC のドライバは足場が取り直す）。
- イメージのタグは `tools/toolbox/Dockerfile` の sha256 から決まるので、Dockerfile を変えると次の実行で作り直される。
- dev サービスは compose のネットワークに入り、足場は `trino:8080` / `minio:9000` のサービス名で相手に届く。ホストにはポートを公開しない（人間が Trino を触るときは `docker compose -f compose.yml exec trino trino --execute 'SELECT 1'` か `tools/dev.sh curl http://trino:8080/v1/info`）。`/tmp` はホストと同じパスで共有しているので、足場が表示する証跡のパスはホストからそのまま開ける。
- この先の予定: `tools/measure/` も toolbox で走らせる（#129）、CI に軽い e2e を載せる（#130）。

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
- **同じプロジェクト名で 2 つの足場は流せない**（片方の開始時の `down -v` が、もう片方の Trino を走行の途中で消す）。開始時に「同じプロジェクトで別の足場が動いている」と出して止まる足場がある（jdbc-drivers、python-clients、retention、trino-probe の versions.sh）。
- 同時に流すなら、プロジェクト名をホストの環境変数で分ける: `COMPOSE_PROJECT_NAME=athena-local-b tools/dev.sh tools/e2e/minio/verify.sh`。dev もその中の足場も同じ別プロジェクト（別のネットワーク・コンテナ・named volume）で動く。`tools/dev.sh COMPOSE_PROJECT_NAME=... <コマンド>` の形では dev 自身が既定のプロジェクトに入り、足場だけが別のプロジェクトになるので効かない。
- プロジェクトを分けても同時に流せないもの: jdbc 系の 3 本（`tools/e2e/jdbc-drivers/verify.sh`、`tools/measure/jdbc-metadata.sh`、`tools/measure/jdbc-show-metadata.sh`）は、どのプロジェクトからも `tools/compose/jdbc-client/target` を bind するので、同時に 1 本だけ。
- named volume（Trino のデータ、MinIO のデータ、maven のキャッシュ `jdbc-client-m2`）はプロジェクトごとに別。共有されるのは `.toolbox/`（cargo はロックで直列にする）と `/tmp`（証跡は `mktemp` で一意）だけ。

## テスト

テストは本物のルーターを、同じプロセス内に立てた偽 Trino と偽 S3 に向けて動かす。そのため Athena のワイヤ上の形（ヘッダ行、`UpdateCount`、ページング、エラーの写し方）、パラメータの分類、そしてパラメータの無い SQL がカタログの別名を除いて書き換えずに渡されることを確かめられる。CI は main への push とプルリクエストのたびに（手動でも起動できる）`fmt`、`clippy`、`test` を回す。

## リリース

コミットに `v*` のタグを付けると、GitHub Actions が `linux/amd64` と `linux/arm64` のイメージを Docker Hub に publish する（シークレットは `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`）。アーキテクチャごとにネイティブのランナーでビルドし、結果を 1 つのマニフェストにまとめるので、QEMU のエミュレーションは使わない。

手順（版の書き換え、PR、タグ、publish の確認、止まる条件）はリポジトリの Skill `.claude/skills/release/SKILL.md` にある。Claude Code では `/release X.Y.Z` で呼ぶ。
