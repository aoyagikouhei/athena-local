# 検証の足場（cargo、tools/e2e、tools/measure）を動かす実行環境。tools/dev.sh が compose.yml の dev サービスとして使う。
# #127。tools/dev.sh がタグを Dockerfile の sha256 から決めるので、このファイルを変えると次の実行で作り直される。
# COPY するファイルを足すときは、tools/dev.sh のタグの計算にもそのファイルを入れる。

# ルートの Dockerfile の builder と同じタグにする。変えるときは両方。
FROM rust:1.98-bookworm

# 公式イメージは --profile minimal で clippy と rustfmt を持たない（CI も ci.yml で足している）。
RUN rustup component add clippy rustfmt

# 足場が呼ぶコマンド: jq、python3 -m venv と pip、boto3（sdk-retry）、uuidgen、ss、openssl（minio/tls/make-cert.sh）、curl。
# gnupg は下の Docker 公式 apt の鍵を入れるため。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      jq python3-venv python3-pip python3-boto3 uuid-runtime iproute2 openssl ca-certificates curl gnupg \
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
