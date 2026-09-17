#!/usr/bin/env python3
"""SigV4 を自前で署名した生 HTTP で、Athena の ListWorkGroups を何通りか呼ぶ。

issue #9（athena-local の ListWorkGroups 対応）の実測用。3-measure-raw-token.py を
雛形にしていて、署名・送信・応答の保存の仕組みはそのまま。違うのは、シェルのラッパを
作らずこのスクリプト単体で全ケースを回し、要約まで書くところ。

AWS CLI は botocore のクライアント側検証で `--max-results 0` を
`Invalid value for parameter MaxResults, value: 0, valid min value: 1` と
手前で止めてしまい、サーバの応答が測れなかった。同じ理由で `--next-token ""`
（botocore の Token は min 1）も送れない。生 HTTP なら素通しできるので、サーバが返す
エラーの __type・AthenaErrorCode・Message と HTTP ステータスが分かる。

使い方:
    python3 9-measure-raw-list-work-groups.py

botocore が要る。システムの python3 に入っていないときは、#3 の
3-measure-client-request-token.sh と同じ順で実行方法を探す。

    uv run --with botocore python3 9-measure-raw-list-work-groups.py
    # ただし astral の uv（`uv --version` が `uv <数字>` で始まる）のときだけ。
    # このホストには同名の無関係なコマンドがあるので、名前だけで判断しない。

    python3 -m venv /tmp/botocore-venv && /tmp/botocore-venv/bin/pip install botocore
    /tmp/botocore-venv/bin/python3 9-measure-raw-list-work-groups.py

aws CLI が Docker のラッパのときは、そこに同梱された python では動かないことがある。

任意の環境変数:
    REGION    既定 ap-northeast-1
    OUT_DIR   既定 $HOME/athena-list-work-groups-measurements
              （実名が入りうるのでリポジトリの外に出す）

実行ごとに $OUT_DIR/raw-<日時>/ を作り、その中だけに書く。前の回と混ざらない。
ListWorkGroups は読み取り専用で、クエリは一切流さないので課金は増えない。

保存するファイル（すべて raw-<日時>/ の中）。
    case-1.json … case-6.json   ケースごとの応答（ステータス・ヘッダ全部・本文そのまま。
                                **実名やアカウント ID を含みうる**）
    summary.txt                 実名を含まない要約。そのまま貼れる。

summary.txt には、ケースごとに HTTP ステータス、x-amzn-errortype ヘッダ（あれば）、
本文の __type・AthenaErrorCode・ErrorCode・Message、正常系なら WorkGroups の件数と
NextToken の有無を書く。ワークグループ名・Description・12 桁のアカウント ID らしき
数列・NextToken の値は <NAME>／<ACCOUNT_ID>／<NEXT_TOKEN> に置き換える。
標準出力には summary.txt のパスだけを出す。

資格情報は botocore の既定の探索順（環境変数 AWS_ACCESS_KEY_ID 等、~/.aws/credentials、
IAM ロールなど）でそのまま読む。見つからなければ summary.txt に no_credentials と
だけ書いて終了コード 1 で終わる。
"""

import datetime
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

import botocore.session
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

TARGET = "AmazonAthena.ListWorkGroups"

# 送るケース。payload はそのまま JSON にして本文にする（型違いも含めたいので、
# ここで botocore のモデルを通さない）。
CASES = [
    (1, "MaxResults=0", {"MaxResults": 0}),
    (2, "MaxResults=-1", {"MaxResults": -1}),
    (3, "NextToken=空文字", {"NextToken": ""}),
    (4, "MaxResults=1 と NextToken=空文字", {"MaxResults": 1, "NextToken": ""}),
    (5, "MaxResults=\"1\"（文字列。型違い）", {"MaxResults": "1"}),
    (6, "引数なし（比較用の正常系）", {}),
]


def call(region, credentials, payload):
    """1 ケース分を送って、結果を dict で返す（3-measure-raw-token.py と同じ形）。"""
    body = json.dumps(payload).encode("utf-8")
    endpoint = "https://athena.{}.amazonaws.com/".format(region)

    result = {}
    # 名前解決の一時的な失敗に備え、HTTP エラー以外の送信失敗は 2 秒あけて 3 回まで試す。
    for attempt in range(3):
        # 署名は再試行のたびに付け直す（X-Amz-Date が古いと弾かれるため）。
        request = AWSRequest(
            method="POST",
            url=endpoint,
            data=body,
            headers={
                "Content-Type": "application/x-amz-json-1.1",
                "X-Amz-Target": TARGET,
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
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                result["outcome"] = "success"
                result["status"] = resp.status
                result["headers"] = dict(resp.headers.items())
                result["body"] = resp.read().decode("utf-8", "replace")
            break
        except urllib.error.HTTPError as e:
            result["outcome"] = "error"
            result["status"] = e.code
            result["headers"] = dict(e.headers.items()) if e.headers else {}
            result["body"] = e.read().decode("utf-8", "replace")
            break
        except Exception as e:  # noqa: BLE001 送信そのものの失敗
            result["outcome"] = "exception"
            result["exception"] = repr(e)
            result["attempts"] = attempt + 1
            if attempt < 2:
                time.sleep(2)

    result["request_body"] = body.decode("utf-8")
    return result


def parsed_body(result):
    """本文を JSON として読む。読めなければ None。"""
    try:
        value = json.loads(result.get("body", ""))
    except Exception:  # noqa: BLE001 本文が JSON でないこともある
        return None
    return value if isinstance(value, dict) else None


def collect_secrets(results):
    """summary から伏せる文字列（名前・Description・トークン）を集める。"""
    names = set()
    tokens = set()
    for result in results:
        parsed = parsed_body(result)
        if parsed is None:
            continue
        token = parsed.get("NextToken")
        if isinstance(token, str) and token:
            tokens.add(token)
        groups = parsed.get("WorkGroups")
        if isinstance(groups, list):
            for group in groups:
                if not isinstance(group, dict):
                    continue
                for key in ("Name", "Description"):
                    value = group.get(key)
                    if isinstance(value, str) and value:
                        names.add(value)
    return names, tokens


def mask(text, names, tokens):
    """実名・トークン・12 桁のアカウント ID らしき数列をプレースホルダに置き換える。"""
    # 長いものから先に置き換える（短い名前が長い名前の一部のことがある）。
    for token in sorted(tokens, key=len, reverse=True):
        text = text.replace(token, "<NEXT_TOKEN>")
    for name in sorted(names, key=len, reverse=True):
        text = text.replace(name, "<NAME>")
    return re.sub(r"\d{12}", "<ACCOUNT_ID>", text)


def summarize(number, label, result, names, tokens):
    """1 ケース分の要約を行の列で返す。"""
    lines = ["[ケース {}] {}".format(number, label)]
    lines.append("  送った本文 = {}".format(result.get("request_body", "")))

    if result.get("outcome") == "exception":
        lines.append("  送信できず: {}".format(result.get("exception", "")))
        return lines

    lines.append("  HTTP ステータス = {}".format(result.get("status", "(なし)")))

    headers = result.get("headers", {})
    errortype = None
    for key, value in headers.items():
        if key.lower() == "x-amzn-errortype":
            errortype = value
    lines.append("  x-amzn-errortype ヘッダ = {}".format(errortype if errortype else "(なし)"))

    parsed = parsed_body(result)
    if parsed is None:
        lines.append("  本文が JSON として読めない（本文は case-{}.json にある）".format(number))
        return lines

    for key in ("__type", "AthenaErrorCode", "ErrorCode", "Message"):
        value = parsed.get(key)
        lines.append("  本文の {} = {}".format(key, value if value is not None else "(なし)"))

    groups = parsed.get("WorkGroups")
    if isinstance(groups, list):
        lines.append("  WorkGroups の件数 = {}".format(len(groups)))
        lines.append(
            "  NextToken = {}".format("あり" if parsed.get("NextToken") else "なし")
        )

    return [mask(line, names, tokens) for line in lines]


def main():
    region = os.environ.get("REGION", "ap-northeast-1")
    out_dir = os.environ.get(
        "OUT_DIR",
        os.path.join(os.path.expanduser("~"), "athena-list-work-groups-measurements"),
    )
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    run_dir = os.path.join(out_dir, "raw-{}".format(stamp))
    os.makedirs(run_dir, exist_ok=True)
    summary_path = os.path.join(run_dir, "summary.txt")

    session = botocore.session.get_session()
    credentials = session.get_credentials()
    if credentials is None:
        with open(summary_path, "w") as f:
            f.write("no_credentials\n")
            f.write("botocore の既定の探索順で資格情報が見つからなかった。何も送っていない。\n")
        print(summary_path)
        return 1

    lines = [
        "ListWorkGroups を生 HTTP（SigV4 自前署名）で呼んだ実測 — {}".format(stamp),
        "リージョン = {}".format(region),
        "X-Amz-Target = {}".format(TARGET),
        "Content-Type = application/x-amz-json-1.1",
        "",
    ]

    results = []
    for number, _label, payload in CASES:
        result = call(region, credentials, payload)
        results.append(result)
        with open(os.path.join(run_dir, "case-{}.json".format(number)), "w") as f:
            json.dump(result, f, ensure_ascii=False, indent=2)

    names, tokens = collect_secrets(results)
    for (number, label, _payload), result in zip(CASES, results):
        lines.extend(summarize(number, label, result, names, tokens))
        lines.append("")

    with open(summary_path, "w") as f:
        f.write("\n".join(lines))

    print(summary_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
