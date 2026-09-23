#!/usr/bin/env python3
# issue #3 で作成（tools/ へ移す前の名前は 3-measure-raw-token.py）
"""SigV4 を自前で署名した生 HTTP で、Athena の StartQueryExecution を1回だけ呼ぶ。

issue #3（athena-local の ClientRequestToken 対応）の実測用。AWS CLI（botocore の
クライアント側パラメータ検証や ClientRequestToken の自動生成）を経由しないので、
トークン無し・空文字・32文字未満・128文字超もそのまま送れる。

client-request-token.sh / client-request-token-extra.sh の
両方から呼ばれる、独立した1回分の呼び出しスクリプト。単体では実行しない。

使い方（単体で流すなら）:
    tools/dev.sh python3 tools/measure/raw-client-request-token.py <region> <db> <output> <workgroup> <query> <token_mode> <out_json>
    （資格情報はホストのシェルで AWS_ACCESS_KEY_ID などを export してから。または ~/.aws/credentials）

    token_mode は "__OMIT__" なら ClientRequestToken を JSON に含めない。それ以外は
    そのままの値を送る（空文字も可）。

応答のステータス・ヘッダ全部・本文をそのまま <out_json> に書く。標準出力には何も書かない
（呼び出し元のシェルが out_json を読み、実名をマスクしてから summary に足す）。

資格情報は botocore の既定の探索順（環境変数 AWS_ACCESS_KEY_ID 等、~/.aws/credentials、
IAM ロールなど）でそのまま読む。見つからなければ <out_json> に {"outcome": "no_credentials"}
とだけ書く。
"""

import json
import time
import sys
import urllib.error
import urllib.request

import botocore.session
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest


def main() -> None:
    region, db, output, workgroup, query, token_mode, out_json = sys.argv[1:8]

    payload = {
        "QueryString": query,
        "QueryExecutionContext": {"Database": db},
        "ResultConfiguration": {"OutputLocation": output},
        "WorkGroup": workgroup,
    }
    if token_mode != "__OMIT__":
        payload["ClientRequestToken"] = token_mode

    body = json.dumps(payload).encode("utf-8")

    session = botocore.session.get_session()
    credentials = session.get_credentials()

    result = {}
    if credentials is None:
        result["outcome"] = "no_credentials"
    else:
        endpoint = "https://athena.{}.amazonaws.com/".format(region)
        request = AWSRequest(
            method="POST",
            url=endpoint,
            data=body,
            headers={
                "Content-Type": "application/x-amz-json-1.1",
                "X-Amz-Target": "AmazonAthena.StartQueryExecution",
            },
        )
        SigV4Auth(credentials, "athena", region).add_auth(request)
        prepared = request.prepare()

        req = urllib.request.Request(
            prepared.url,
            data=prepared.body,
            headers=dict(prepared.headers),
            method="POST",
        )
        # 名前解決の一時的な失敗（3 回目の実測で omit の 1 件だけ gaierror になった）に備え、
        # HTTP エラー以外の送信失敗は 2 秒あけて 3 回まで試す。
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req, timeout=60) as resp:
                    resp_body = resp.read().decode("utf-8", "replace")
                    result["outcome"] = "success"
                    result["status"] = resp.status
                    result["headers"] = dict(resp.headers.items())
                    result["body"] = resp_body
                    try:
                        result["query_execution_id"] = json.loads(resp_body).get(
                            "QueryExecutionId", ""
                        )
                    except Exception:
                        pass
                break
            except urllib.error.HTTPError as e:
                resp_body = e.read().decode("utf-8", "replace")
                result["outcome"] = "error"
                result["status"] = e.code
                result["headers"] = dict(e.headers.items()) if e.headers else {}
                result["body"] = resp_body
                break
            except Exception as e:
                result["outcome"] = "exception"
                result["exception"] = repr(e)
                result["attempts"] = attempt + 1
                if attempt < 2:
                    time.sleep(2)

    with open(out_json, "w") as f:
        json.dump(result, f)


if __name__ == "__main__":
    main()
