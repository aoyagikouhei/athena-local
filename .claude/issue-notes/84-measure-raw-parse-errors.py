#!/usr/bin/env python3
"""SigV4 を自前で署名した生 HTTP で、Athena にパースで落ちるはずの本文（型違い・必須キー欠落・
壊れた JSON・未知のキー）と、ディスパッチで落ちるはずのヘッダ（未対応のオペレーション・
X-Amz-Target 無し・Content-Type 違い）を送り、本物の応答を採る。issue #84 の実測用。
83-measure-raw-get-query-results.py を雛形にしていて、署名・応答の保存・要約の仕組みは
そのまま。違うのは次のところ。

  - クエリは 1 本も流さない。StartQueryExecution に送るのはパースで落ちるはずの本文だけで、
    万一通っても QueryString が `SELECT` だけなので構文エラーで止まる。
  - 本文は生のバイト列で送る（壊れた JSON・空の本文を送るため。json.dumps を通さない）。
  - X-Amz-Target と Content-Type を省ける／任意の値にできる。SigV4 は送るヘッダを
    そのまま署名する（AWSRequest の headers に入れたものが署名対象になる）。
  - 送信は urllib ではなく http.client で行う。urllib は Content-Type が無いと
    `application/x-www-form-urlencoded` を勝手に足すので、「Content-Type 無し」を送れない。

使い方:
    OUTPUT=s3://your-bucket/prefix/ python3 84-measure-raw-parse-errors.py

botocore が要る。システムの python3 に入っていないときは、#9 と同じ順で実行方法を探す。

    uv run --with botocore python3 84-measure-raw-parse-errors.py
    # ただし astral の uv（`uv --version` が `uv <数字>` で始まる）のときだけ。
    # このホストには同名の無関係なコマンドがあるので、名前だけで判断しない。

    python3 -m venv /tmp/botocore-venv && /tmp/botocore-venv/bin/pip install botocore
    OUTPUT=... /tmp/botocore-venv/bin/python3 84-measure-raw-parse-errors.py

aws CLI が Docker のラッパのときは、そこに同梱された python では動かないことがある。

必要な環境変数:
    OUTPUT    StartQueryExecution の ResultConfiguration.OutputLocation に入れる。
              s3://bucket/prefix/ の形（末尾の / が無ければ足す）。無ければ no_output で止まる。

任意の環境変数:
    REGION    既定 ap-northeast-1
    OUT_DIR   既定 $HOME/athena-parse-errors-measurements
              （実名が入りうるのでリポジトリの外に出す）

** 課金の注意 **
    本物への呼び出しは 46 回で、すべて 400 を想定している。クエリは流さない。DDL も無い。
    StartQueryExecution の 5 件（ケース 33〜38 のうち QueryString が `SELECT` のもの）が
    万一パースを通っても、`SELECT` だけの文なので構文エラーで止まり、課金は増えない見込み。

実行ごとに $OUT_DIR/raw-<日時>/ を作り、その中だけに書く。前の回と混ざらない。

保存するファイル（すべて raw-<日時>/ の中）。

    case-<n>.json   ケースごとの応答（送ったヘッダの違い・本文、ステータス・ヘッダ全部・
                    応答本文そのまま。**バケット名やアカウント ID を含みうる**）
    summary.txt     実名を含まない要約。そのまま貼れる。

summary.txt には、ケースごとに送ったオペレーション・ヘッダの違い・本文（生のまま。120 文字で
切る）、HTTP ステータス、x-amzn-errortype と x-amzn-requestid の有無、本文の __type・
AthenaErrorCode・ErrorCode・Message（本文が JSON でなければ先頭 200 文字をそのまま）、
200 なら本文のキー一覧を書く。12 桁のアカウント ID らしき数列・OUTPUT の値・
ClientRequestToken の値・200 の応答に出たワークグループ名は <ACCOUNT_ID>／<OUTPUT>／
<CLIENT_TOKEN>／<NAME> に置き換える。
標準出力には summary.txt のパスだけを出す。

資格情報は botocore の既定の探索順（環境変数 AWS_ACCESS_KEY_ID 等、~/.aws/credentials、
IAM ロールなど）でそのまま読む。見つからなければ summary.txt に no_credentials と
だけ書いて終了コード 1 で終わる。
"""

import datetime
import http.client
import json
import os
import re
import sys
import time
import urllib.parse
import uuid

import botocore.session
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

SERVICE = "athena"
PREFIX = "AmazonAthena."
DEFAULT_CONTENT_TYPE = "application/x-amz-json-1.1"
# 実在しない QueryExecutionId（形は正しい UUID）。
MISSING_ID = "00000000-0000-4000-8000-000000000084"
# ヘッダを省くことを表す印。
OMIT = object()


def call(region, credentials, body, target=PREFIX + "ListWorkGroups", content_type=DEFAULT_CONTENT_TYPE):
    """1 リクエスト分を送って、結果を dict で返す。

    body は送る本文のバイト列そのもの（json.dumps を通さない）。target と content_type は
    ヘッダの値で、OMIT を渡すとそのヘッダを付けない。付けたヘッダはすべて署名対象になる。
    """
    endpoint = "https://athena.{}.amazonaws.com/".format(region)
    headers = {}
    if content_type is not OMIT:
        headers["Content-Type"] = content_type
    if target is not OMIT:
        headers["X-Amz-Target"] = target
    result = {
        "target": None if target is OMIT else target,
        "content_type": None if content_type is OMIT else content_type,
    }
    # 名前解決の一時的な失敗に備え、HTTP の応答以外の送信失敗は 2 秒あけて 3 回まで試す。
    for attempt in range(3):
        # 署名は再試行のたびに付け直す（X-Amz-Date が古いと弾かれるため）。
        request = AWSRequest(method="POST", url=endpoint, data=body, headers=dict(headers))
        SigV4Auth(credentials, SERVICE, region).add_auth(request)
        prepared = request.prepare()
        sent_headers = dict(prepared.headers)
        result["sent_headers"] = {
            k: v for k, v in sent_headers.items() if k.lower() not in ("authorization", "x-amz-security-token")
        }
        parts = urllib.parse.urlsplit(prepared.url)
        conn = http.client.HTTPSConnection(parts.netloc, timeout=60)
        try:
            # http.client は Content-Type を勝手に足さない（Host と Content-Length だけ足す）。
            conn.request("POST", parts.path or "/", body=prepared.body or b"", headers=sent_headers)
            resp = conn.getresponse()
            result["outcome"] = "success" if resp.status == 200 else "error"
            result["status"] = resp.status
            result["headers"] = dict(resp.getheaders())
            result["body"] = resp.read().decode("utf-8", "replace")
            result.pop("exception", None)
            break
        except Exception as e:  # noqa: BLE001 送信そのものの失敗
            result["outcome"] = "exception"
            result["exception"] = repr(e)
            result["attempts"] = attempt + 1
            if attempt < 2:
                time.sleep(2)
        finally:
            conn.close()
    result["request_body"] = body.decode("utf-8", "replace")
    return result


def parsed_body(result):
    """本文を JSON の object として読む。読めなければ None。"""
    try:
        value = json.loads(result.get("body", ""))
    except Exception:  # noqa: BLE001 本文が JSON でないこともある
        return None
    return value if isinstance(value, dict) else None


def save(run_dir, name, result):
    with open(os.path.join(run_dir, name), "w") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)


def build_cases(output):
    """送るケースを (番号, 説明, オペレーション名, ヘッダの違い, 本文のバイト列, target, content_type)
    の列で返す。あわせて、付けた ClientRequestToken の集合も返す（要約で伏せるため）。

    本文は JSON 文字列をそのまま書く。<OUTPUT> と <TOKEN> だけ、ここで実値に差し替える
    （TOKEN は uuid4 で毎回作る。無いと `clientRequestToken is null or empty` で弾かれる）。
    """
    tokens = set()

    def raw(text):
        if "<TOKEN>" in text:
            token = str(uuid.uuid4())
            tokens.add(token)
            text = text.replace("<TOKEN>", token)
        # OUTPUT は s3:// と英数字・記号だけなので、JSON 文字列の中にそのまま埋めてよい。
        text = text.replace("<OUTPUT>", output)
        return text.encode("utf-8")

    rc = '"ResultConfiguration": {"OutputLocation": "<OUTPUT>"}'
    lwg = "ListWorkGroups"
    gqe = "GetQueryExecution"
    sqe = "StartQueryExecution"
    m = MISSING_ID
    # (番号, 説明, オペレーション, 本文)。ヘッダは既定（Content-Type 1.1・X-Amz-Target 正しい）。
    plain = [
        # A. ListWorkGroups（副作用なし）
        (1, "MaxResults が文字列 \"1\"（対照。既知の SerializationException）", lwg, '{"MaxResults": "1"}'),
        (2, "MaxResults が数字でない文字列", lwg, '{"MaxResults": "abc"}'),
        (3, "MaxResults が真偽値", lwg, '{"MaxResults": true}'),
        (4, "MaxResults が小数", lwg, '{"MaxResults": 1.5}'),
        (5, "MaxResults が null", lwg, '{"MaxResults": null}'),
        (6, "MaxResults が配列", lwg, '{"MaxResults": [1]}'),
        (7, "MaxResults がオブジェクト", lwg, '{"MaxResults": {"a": 1}}'),
        (8, "MaxResults が Integer の範囲外", lwg, '{"MaxResults": 99999999999}'),
        (9, "NextToken が数値", lwg, '{"NextToken": 1}'),
        (10, "NextToken が真偽値", lwg, '{"NextToken": true}'),
        (11, "NextToken が null", lwg, '{"NextToken": null}'),
        (12, "NextToken が配列", lwg, '{"NextToken": ["a"]}'),
        (13, "NextToken がオブジェクト", lwg, '{"NextToken": {"a": 1}}'),
        (14, "未知のキー（通れば 200）", lwg, '{"Foo": 1}'),
        (15, "型違いと NextToken 空文字の同時（どちらが先か）", lwg, '{"MaxResults": "1", "NextToken": ""}'),
        (16, "壊れた JSON", lwg, "{"),
        (17, "本文が空（0 バイト）", lwg, ""),
        (18, "本文が null", lwg, "null"),
        (19, "本文が配列", lwg, "[]"),
        (20, "本文が文字列", lwg, '"x"'),
        (21, "末尾カンマ", lwg, '{"MaxResults": 1,}'),
        # B. 他のオペレーション
        (22, "QueryExecutionId が数値", gqe, '{"QueryExecutionId": 1}'),
        (23, "QueryExecutionId が真偽値", gqe, '{"QueryExecutionId": true}'),
        (24, "QueryExecutionId が null", gqe, '{"QueryExecutionId": null}'),
        (25, "QueryExecutionId が配列", gqe, '{"QueryExecutionId": ["x"]}'),
        (26, "QueryExecutionId がオブジェクト", gqe, '{"QueryExecutionId": {"a": 1}}'),
        (27, "必須の QueryExecutionId が欠落", gqe, "{}"),
        (28, "未知のキー（通れば NOT_FOUND）", gqe, '{"QueryExecutionId": "' + m + '", "Foo": 1}'),
        (29, "StopQueryExecution で QueryExecutionId が数値", "StopQueryExecution", '{"QueryExecutionId": 1}'),
        (30, "GetWorkGroup で WorkGroup が数値", "GetWorkGroup", '{"WorkGroup": 1}'),
        (31, "GetWorkGroup で必須の WorkGroup が欠落", "GetWorkGroup", "{}"),
        (32, "GetQueryResults で型違いと必須欠落の同時（どちらが先か）", "GetQueryResults", '{"MaxResults": "1"}'),
        (33, "QueryString が数値", sqe,
         '{"QueryString": 1, "ClientRequestToken": "<TOKEN>", ' + rc + "}"),
        (34, "ExecutionParameters が文字列", sqe,
         '{"QueryString": "SELECT", "ExecutionParameters": "x", "ClientRequestToken": "<TOKEN>", ' + rc + "}"),
        (35, "ExecutionParameters の要素が数値", sqe,
         '{"QueryString": "SELECT", "ExecutionParameters": [1], "ClientRequestToken": "<TOKEN>", ' + rc + "}"),
        (36, "ResultConfiguration が文字列", sqe,
         '{"QueryString": "SELECT", "ResultConfiguration": "x", "ClientRequestToken": "<TOKEN>"}'),
        (37, "QueryExecutionContext が配列", sqe,
         '{"QueryString": "SELECT", "QueryExecutionContext": [], "ClientRequestToken": "<TOKEN>", ' + rc + "}"),
        (38, "必須の QueryString が欠落", sqe,
         '{"ClientRequestToken": "<TOKEN>", ' + rc + "}"),
    ]
    cases = []
    for number, label, operation, text in plain:
        cases.append((number, label, operation, "(既定)", raw(text), PREFIX + operation, DEFAULT_CONTENT_TYPE))

    # C. ディスパッチ（本文は {}、ListWorkGroups を基準にする）
    dispatch = [
        (39, "未対応のオペレーション", "X-Amz-Target: AmazonAthena.Nope", PREFIX + "Nope", DEFAULT_CONTENT_TYPE),
        (40, "前置き無しの未対応名", "X-Amz-Target: Nope", "Nope", DEFAULT_CONTENT_TYPE),
        (41, "前置き無しの実在する名前", "X-Amz-Target: ListWorkGroups", "ListWorkGroups", DEFAULT_CONTENT_TYPE),
        (42, "X-Amz-Target ヘッダ無し", "X-Amz-Target 無し", OMIT, DEFAULT_CONTENT_TYPE),
        (43, "X-Amz-Target が小文字", "X-Amz-Target: amazonathena.listworkgroups",
         "amazonathena.listworkgroups", DEFAULT_CONTENT_TYPE),
        (44, "Content-Type が application/json", "Content-Type: application/json",
         PREFIX + lwg, "application/json"),
        (45, "Content-Type ヘッダ無し", "Content-Type 無し", PREFIX + lwg, OMIT),
        (46, "Content-Type が 1.0", "Content-Type: application/x-amz-json-1.0",
         PREFIX + lwg, "application/x-amz-json-1.0"),
    ]
    for number, label, header_note, target, content_type in dispatch:
        cases.append((number, label, lwg, header_note, raw("{}"), target, content_type))
    return cases, tokens


def collect_names(results):
    """200 の応答に出たワークグループ名・Description を集める（#9 と同じ）。"""
    names = set()
    for result in results:
        if result is None or result.get("status") != 200:
            continue
        parsed = parsed_body(result)
        if parsed is None:
            continue
        groups = parsed.get("WorkGroups")
        if isinstance(groups, list):
            for group in groups:
                if not isinstance(group, dict):
                    continue
                for key in ("Name", "Description"):
                    value = group.get(key)
                    if isinstance(value, str) and value:
                        names.add(value)
        group = parsed.get("WorkGroup")
        if isinstance(group, dict):
            for key in ("Name", "Description"):
                value = group.get(key)
                if isinstance(value, str) and value:
                    names.add(value)
    return names


def mask(text, output, tokens, names):
    """ClientRequestToken・OUTPUT・ワークグループ名・12 桁のアカウント ID らしき数列を伏せる。"""
    for token in sorted(tokens, key=len, reverse=True):
        text = text.replace(token, "<CLIENT_TOKEN>")
    if output:
        text = text.replace(output, "<OUTPUT>")
    # 長いものから先に置き換える（短い名前が長い名前の一部のことがある）。
    for name in sorted(names, key=len, reverse=True):
        text = text.replace(name, "<NAME>")
    return re.sub(r"\d{12}", "<ACCOUNT_ID>", text)


def shorten(text, limit):
    return text if len(text) <= limit else text[:limit] + "…（以下略。全 {} 文字）".format(len(text))


def header_value(headers, name):
    for key, value in headers.items():
        if key.lower() == name:
            return value
    return None


def summarize(case, result, masker=lambda text: text):
    """1 ケース分の要約を行の列で返す（マスクは呼び出し側）。

    送った本文だけは、120 文字で切る前に masker で伏せる（切ったあとだと OUTPUT が
    途中で切れて置き換えから漏れる）。"""
    number, label, operation, header_note, body, _target, _content_type = case
    lines = ["[ケース {}] {}".format(number, label)]
    lines.append("  オペレーション = {}".format(operation))
    lines.append("  ヘッダの違い = {}".format(header_note))
    lines.append("  送った本文 = {}".format(shorten(masker(body.decode("utf-8", "replace")), 120) if body else "(空。0 バイト)"))
    if result is None:
        lines.append("  未送信")
        return lines
    if result.get("outcome") == "exception":
        lines.append("  送信できず: {}".format(result.get("exception", "")))
        return lines
    lines.append("  HTTP ステータス = {}".format(result.get("status", "(なし)")))
    headers = result.get("headers", {})
    errortype = header_value(headers, "x-amzn-errortype")
    lines.append("  x-amzn-errortype ヘッダ = {}".format("あり: " + errortype if errortype else "(なし)"))
    requestid = header_value(headers, "x-amzn-requestid")
    lines.append("  x-amzn-requestid ヘッダ = {}".format("あり" if requestid else "(なし)"))
    parsed = parsed_body(result)
    if parsed is None:
        raw_body = result.get("body", "")
        lines.append("  本文が JSON の object でない。先頭 200 文字 = {!r}".format(raw_body[:200]))
        return lines
    for key in ("__type", "AthenaErrorCode", "ErrorCode", "Message"):
        value = parsed.get(key)
        if value is None and key == "Message":
            # 小文字の message で返るサービスもあるので拾っておく。
            value = parsed.get("message")
        lines.append("  本文の {} = {}".format(key, value if value is not None else "(なし)"))
    if result.get("status") == 200:
        lines.append("  200 の本文のキー = {}".format(", ".join(sorted(parsed.keys())) or "(なし)"))
    return lines


def header_lines(stamp, region):
    return [
        "Athena のパース失敗とディスパッチ失敗を生 HTTP（SigV4 自前署名）で呼んだ実測 — {}".format(stamp),
        "リージョン = {}".format(region),
        "本物への呼び出し 46 回、すべて 400 想定、クエリは流さない、DDL 無し、課金は増えない見込み",
        "（StartQueryExecution の 5 件が万一通っても `SELECT` の構文エラーで止まる）。",
        "既定のヘッダ = Content-Type: {}、X-Amz-Target: AmazonAthena.<オペレーション>".format(DEFAULT_CONTENT_TYPE),
        "送信は http.client（Content-Type を勝手に足さない）。付けたヘッダはすべて SigV4 の署名対象。",
        "",
    ]


def main():
    region = os.environ.get("REGION", "ap-northeast-1")
    output = os.environ.get("OUTPUT", "")
    out_dir = os.environ.get(
        "OUT_DIR",
        os.path.join(os.path.expanduser("~"), "athena-parse-errors-measurements"),
    )
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    run_dir = os.path.join(out_dir, "raw-{}".format(stamp))
    os.makedirs(run_dir, exist_ok=True)
    summary_path = os.path.join(run_dir, "summary.txt")

    if not output.startswith("s3://"):
        with open(summary_path, "w") as f:
            f.write("no_output\n")
            f.write("OUTPUT（s3://bucket/prefix/）が要る。何も送っていない。\n")
        print(summary_path)
        return 1
    if not output.endswith("/"):
        output += "/"

    session = botocore.session.get_session()
    credentials = session.get_credentials()
    if credentials is None:
        with open(summary_path, "w") as f:
            f.write("no_credentials\n")
            f.write("botocore の既定の探索順で資格情報が見つからなかった。何も送っていない。\n")
        print(summary_path)
        return 1

    cases, tokens = build_cases(output)
    results = []
    for case in cases:
        number, _label, _operation, _note, body, target, content_type = case
        result = call(region, credentials, body, target=target, content_type=content_type)
        results.append(result)
        save(run_dir, "case-{}.json".format(number), result)

    names = collect_names(results)

    def masker(text):
        return mask(text, output.rstrip("/"), tokens, names)

    lines = header_lines(stamp, region)
    for case, result in zip(cases, results):
        lines.extend(summarize(case, result, masker))
        lines.append("")
    with open(summary_path, "w") as f:
        f.write("\n".join(masker(line) for line in lines) + "\n")
    print(summary_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
