# issue #111: python-clients の check に渡す AWS 系の環境変数を 1 か所で export する（verify.sh が source する）。
# どのクライアントにも endpoint_url を渡さず、botocore の環境変数だけで向ける
# （PyAthena は connect(endpoint_url=) を S3 の client にも流用し、dbt-athena の impl の client は
# profile の endpoint_url を受け取らないため。explore-111.md Explore 2 の 4・5）。
#   AWS_ENDPOINT_URL        → 中継（STS・Glue など、サービス別の指定が無いものは全部ここに来る。
#                             本物の AWS に漏れないための網。canary で確かめる）
#   AWS_ENDPOINT_URL_ATHENA → 中継（athena-local の s3 モードの手前）
#   AWS_ENDPOINT_URL_S3     → MinIO（中継は Content-Length の無い本文を扱えないので S3 は通さない）
# 前提: EVIDENCE_DIR・PROXY_BIND・MINIO_ENDPOINT が決まっていること。

cat >"$EVIDENCE_DIR/aws-config" <<'CONFIG'
[default]
s3 =
    addressing_style = path
CONFIG

export AWS_ENDPOINT_URL="http://$PROXY_BIND"
export AWS_ENDPOINT_URL_ATHENA="http://$PROXY_BIND"
export AWS_ENDPOINT_URL_S3="$MINIO_ENDPOINT"
# ローカル専用のダミー認証情報（MinIO の root と同じ）。本物の AWS の認証情報ではない。
export AWS_ACCESS_KEY_ID=minioadmin
export AWS_SECRET_ACCESS_KEY=minioadmin
export AWS_DEFAULT_REGION=us-east-1
unset AWS_PROFILE AWS_SESSION_TOKEN
export AWS_SHARED_CREDENTIALS_FILE=/dev/null
export AWS_EC2_METADATA_DISABLED=true
export AWS_CONFIG_FILE="$EVIDENCE_DIR/aws-config"
export DBT_SEND_ANONYMOUS_USAGE_STATS=false
