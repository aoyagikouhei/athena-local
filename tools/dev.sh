#!/usr/bin/env bash
# 検証の足場（cargo、tools/e2e、tools/measure）を toolbox コンテナ（compose.yml の dev サービス）の中で動かす（#127）。
#
# 使い方（リポジトリの中のどこからでも。cwd はそのままコンテナに引き継ぐ）:
#   tools/dev.sh cargo test
#   tools/dev.sh KEEP_UP=1 tools/e2e/minio/verify.sh     # 環境変数は VAR=VALUE をコマンドの前に並べる（env に渡す）
#   tools/dev.sh bash -c 'cargo test 2>&1 | tail -n 5'   # パイプやリダイレクトをコンテナの中でするときは bash -c
# `~` や $VAR はホストのシェルが展開してから渡る。コンテナの中で展開したいものは bash -c '...' に書く。
# 同時に流すなら `COMPOSE_PROJECT_NAME=<名前> tools/dev.sh ...`（ホストの環境変数。`tools/dev.sh VAR=VALUE` の形では dev 自身が既定のプロジェクトに入るので効かない）。
#
# コンテナの中の HOME・CARGO_HOME・CARGO_TARGET_DIR はリポジトリの .toolbox/ の下（home / cargo / target）。
# ホストの ~/.cargo と target/ とは混ぜない。消すときは rm -rf .toolbox（次の実行で作り直される）。
# イメージのタグは tools/toolbox/Dockerfile の sha256 から決めるので、Dockerfile を変えると次の実行で作り直される。
# Dockerfile が COPY するファイルを足したら、そのファイルもタグの計算に入れる。
set -euo pipefail

die() {
  echo "dev.sh: $1" >&2
  exit 2
}

main() {
  if [ $# -eq 0 ]; then
    die "使い方: tools/dev.sh [VAR=VALUE ...] <コマンド> [引数...]"
  fi

  local repo cwd
  repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
  cwd=$(pwd -P)
  # リポジトリの外はコンテナにマウントしていないので、そこを cwd にはできない。
  case "$cwd/" in
    "$repo/"*) ;;
    *) die "リポジトリの外（$cwd）では動かせない。$repo の中で実行する" ;;
  esac

  # 代入と export を分ける（export VAR=$(...) だと置換の失敗を set -e が拾わない）。
  # docker.sock が無ければ stat が失敗してここで止まる。
  DOCKER_GID=$(stat -c %g /var/run/docker.sock)
  TOOLBOX_TAG=$(sha256sum "$repo/tools/toolbox/Dockerfile" | cut -c1-12)
  DEV_REPO=$repo
  DEV_CWD=$cwd
  DEV_UID=$(id -u)
  DEV_GID=$(id -g)
  DEV_USER=$(id -un)
  # 実測（tools/measure）の出力先と `~/.aws` の既定に使う、ホストのホーム。
  DEV_HOST_HOME=$HOME
  export DEV_REPO DEV_CWD DEV_UID DEV_GID DEV_USER DOCKER_GID TOOLBOX_TAG DEV_HOST_HOME

  # HOME だけ先に作る（HOME が無いとその下に書くもの（pip、venv の置き場）が落ちる。cargo と target は cargo が自分で作る）。
  mkdir -p "$repo/.toolbox/home"

  # イメージの有無（pull_policy: never で無ければ build）と TTY（stdin と stdout がともに端末のときだけ割り当てる）は
  # compose に任せる。env -- を挟んで、先頭の VAR=VALUE を環境変数として効かせる。
  # tls-proxy が dev:8087 で届くよう、サービス名の別名を付ける。
  exec docker compose -f "$repo/compose.yml" run --rm --use-aliases dev env -- "$@"
}

main "$@"
