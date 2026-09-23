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

検証の足場（`tools/e2e/`）は、ホストで直接叩かず toolbox の中で動かす（理由は [decisions.md](decisions.md) の「開発の足場」）。toolbox はルートの [compose.yml](../../compose.yml) の dev サービスとして定義してあり、[tools/dev.sh](../../tools/dev.sh) がその呼び口（`docker compose run --rm dev env -- <コマンド>` の薄い包み）。ホストに要るのは Docker（compose プラグイン付き）だけ。

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
- dev サービスは `network_mode: host` なので、足場が使う `127.0.0.1:<port>` はホストのポートそのもの（ホストで同じポートを使っているものとは衝突する）。`/tmp` はホストと同じパスで共有しているので、足場が表示する証跡のパスはホストからそのまま開ける。
- この先の予定: trino・minio などを compose.yml に足し足場をサービス名の宛先へ移す（#128）、dev サービスを同じネットワークへ移して `tools/measure/` も toolbox で走らせる（#129）、CI に軽い e2e を載せる（#130）。

## テスト

テストは本物のルーターを、同じプロセス内に立てた偽 Trino と偽 S3 に向けて動かす。そのため Athena のワイヤ上の形（ヘッダ行、`UpdateCount`、ページング、エラーの写し方）、パラメータの分類、そしてパラメータの無い SQL がカタログの別名を除いて書き換えずに渡されることを確かめられる。CI は main への push とプルリクエストのたびに（手動でも起動できる）`fmt`、`clippy`、`test` を回す。

## リリース

コミットに `v*` のタグを付けると、GitHub Actions が `linux/amd64` と `linux/arm64` のイメージを Docker Hub に publish する（シークレットは `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`）。アーキテクチャごとにネイティブのランナーでビルドし、結果を 1 つのマニフェストにまとめるので、QEMU のエミュレーションは使わない。

手順（版の書き換え、PR、タグ、publish の確認、止まる条件）はリポジトリの Skill `.claude/skills/release/SKILL.md` にある。Claude Code では `/release X.Y.Z` で呼ぶ。
