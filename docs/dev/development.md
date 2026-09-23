# 開発

athena-local をビルド・テスト・リリースするための手順（コントリビュータ向け）。

## コマンド

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

## テスト

テストは本物のルーターを、同じプロセス内に立てた偽 Trino と偽 S3 に向けて動かす。そのため Athena のワイヤ上の形（ヘッダ行、`UpdateCount`、ページング、エラーの写し方）、パラメータの分類、そしてパラメータの無い SQL がカタログの別名を除いて書き換えずに渡されることを確かめられる。CI は main への push とプルリクエストのたびに（手動でも起動できる）`fmt`、`clippy`、`test` を回す。

## リリース

コミットに `v*` のタグを付けると、GitHub Actions が `linux/amd64` と `linux/arm64` のイメージを Docker Hub に publish する（シークレットは `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`）。アーキテクチャごとにネイティブのランナーでビルドし、結果を 1 つのマニフェストにまとめるので、QEMU のエミュレーションは使わない。
