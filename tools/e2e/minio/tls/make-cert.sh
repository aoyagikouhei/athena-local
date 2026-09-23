#!/usr/bin/env bash
# issue #39 で作成（tools/ へ移す前の名前は 39-e2e/tls/make-cert.sh）
# JDBC の検証に使う自己署名証明書を作る。**鍵はリポジトリに入れない**ので、
# verify.sh や jdbc-client を動かす前にここで作る。
#
#   bash tools/e2e/minio/tls/make-cert.sh
#
# 名前は、ドライバが接続する先をすべて subjectAltName に入れる（JVM が
# 名前の一致を見るため）。README の「Athena JDBC 3.x needs a TLS terminator in front」
# に同じ手順がある。
set -euo pipefail

dir="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$dir/server.key" ]; then
  echo "既にある: $dir/server.key（作り直すなら先に消す）"
  exit 0
fi

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$dir/server.key" -out "$dir/server.crt" \
  -subj "/CN=athena-local" \
  -addext "subjectAltName=DNS:localhost,DNS:*.localhost,DNS:athena-local,DNS:minio,DNS:tls-proxy,DNS:athena-results.tls-proxy,DNS:results.localhost,IP:127.0.0.1"

chmod 600 "$dir/server.key"
echo "作成した: $dir/server.crt と $dir/server.key（どちらも git は追跡しない）"
