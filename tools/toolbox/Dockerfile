# 検証の足場（cargo、tools/e2e、tools/measure）を動かす実行環境。tools/dev.sh が compose.yml の dev サービスとして使う。
# #127。tools/dev.sh がタグを Dockerfile の sha256 から決めるので、このファイルを変えると次の実行で作り直される。
# COPY するファイルを足すときは、tools/dev.sh のタグの計算にもそのファイルを入れる。

# mc はマルチアーキの manifest list のダイジェストで固定する（:latest だと toolbox のタグ（Dockerfile の sha256）を
# 変えないまま中身が変わる）。#129。版を上げるときは `docker buildx imagetools inspect docker.io/pgsty/mc:latest` で
# ダイジェストを取り直す。quay.io/minio/mc は 2026-09-25 に 401 で取れなくなったので、MinIO のフォーク
# pgsty/silo の mc（同じ /usr/bin/mc）に替えた（#178）。
FROM docker.io/pgsty/mc@sha256:cfc83108c3abb371f8fb84d99c1fdc88f8c237e022409b0081fb7c0a3be634dd AS mc

# ルートの Dockerfile の builder と同じタグにする。変えるときは両方。
FROM rust:1.98-bookworm

# 公式イメージは --profile minimal で clippy と rustfmt を持たない（CI も ci.yml で足している）。
RUN rustup component add clippy rustfmt

# 足場が呼ぶコマンド: jq、python3 -m venv と pip、boto3（sdk-retry）、uuidgen、ss、openssl（tools/compose/tls/make-cert.sh）、curl。
# gnupg は下の Docker 公式 apt の鍵を入れるため。unzip は下の awscli v2 の展開に使う。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      jq python3-venv python3-pip python3-boto3 uuid-runtime iproute2 openssl ca-certificates curl gnupg unzip \
 && rm -rf /var/lib/apt/lists/*

# docker CLI と compose は Docker 公式 apt から入れる（Debian の docker.io は古く compose v2 が付かない）。
RUN install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      >/etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
 && rm -rf /var/lib/apt/lists/*

# mc（#129）。足場は compose のネットワークに直接繋いで minio:9000 を見るので、使い捨てコンテナが要らない。
COPY --from=mc /usr/bin/mc /usr/local/bin/mc

# awscli v2（#129）。tools/measure が呼ぶ（--no-paginate・--max-items・--debug など v2 本体が要る形を使う）。
# 版を版付きの zip で固定する。理由: toolbox のタグは Dockerfile の sha256 だけで、`awscli-exe-linux-<arch>-latest.zip`
# だと Dockerfile を変えないまま中身（版）が変わる。版を上げるときは
# https://raw.githubusercontent.com/aws/aws-cli/v2/CHANGELOG.rst で最新を見て、この行の版番号を書き換える。
RUN arch="$(uname -m)" \
 && case "$arch" in \
      aarch64) awscli_arch=aarch64 ;; \
      x86_64)  awscli_arch=x86_64 ;; \
      *) echo "未対応のアーキテクチャ: $arch" >&2; exit 1 ;; \
    esac \
 && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${awscli_arch}-2.37.0.zip" -o /tmp/awscliv2.zip \
 && unzip -q /tmp/awscliv2.zip -d /tmp \
 && /tmp/aws/install \
 && rm -rf /tmp/awscliv2.zip /tmp/aws
