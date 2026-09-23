#!/usr/bin/env python3
# issue #83 で作成（tools/ へ移す前の名前は 83-measure-raw-get-query-results.py）
"""SigV4 を自前で署名した生 HTTP で、Athena の GetQueryResults に範囲外の MaxResults と
不正な NextToken を何通りか送り、本物の応答を採る。issue #83 の実測用。
raw-list-work-groups.py を雛形にしていて、署名・送信・応答の保存・要約の
仕組みはそのまま。違うのは、最初に小さなクエリを 1 本流して QueryExecutionId を取る
ところと、正しい NextToken を 1 ページ目から採ってその変形も送るところ。

AWS CLI は botocore のクライアント側検証で `--max-results 0` や `--next-token ""` を
手前で止めてしまい、サーバの応答が測れない。生 HTTP なら素通しできる。

使い方:
    OUTPUT=s3://your-bucket/prefix/ python3 raw-get-query-results.py

botocore が要る。システムの python3 に入っていないときは、#9 と同じ順で実行方法を探す。

    uv run --with botocore python3 raw-get-query-results.py
    # ただし astral の uv（`uv --version` が `uv <数字>` で始まる）のときだけ。
    # このホストには同名の無関係なコマンドがあるので、名前だけで判断しない。

    python3 -m venv /tmp/botocore-venv && /tmp/botocore-venv/bin/pip install botocore
    OUTPUT=... /tmp/botocore-venv/bin/python3 raw-get-query-results.py

aws CLI が Docker のラッパのときは、そこに同梱された python では動かないことがある。

必要な環境変数:
    OUTPUT    StartQueryExecution の OutputLocation。s3://bucket/prefix/ の形
              （末尾の / が無ければ足す）。

任意の環境変数:
    REGION        既定 ap-northeast-1
    OUT_DIR       既定 $HOME/athena-get-query-results-measurements
                  （実名が入りうるのでリポジトリの外に出す）
    POLL_TIMEOUT  クエリの終端状態を待つ上限（秒）。既定 120

** 課金の注意 **
    流すクエリは 3 本で、どれもテーブルは読まない（スキャン 0 バイト）。DDL・書き込みは無い。
      - `SELECT n FROM UNNEST(sequence(1, 5)) AS t(n)`（5 行。ケース 1〜22）
      - `SELECT n FROM UNNEST(sequence(1, 1500)) AS t(n)`（1500 行。既定ページサイズを測る。3 ラウンド目で追加）
      - 存在しないテーブルの SELECT（FAILED になる。結果の無いクエリの検証順序を測る。3 ラウンド目で追加）
    結果ファイル（数 KB）が OUTPUT に 2 組置かれる。
    本物への呼び出しは StartQueryExecution 3 回、GetQueryExecution が終端まで数回ずつ、
    GetQueryResults が約 30 回、ListWorkGroups 1 回。すべて読み取り。

実行ごとに $OUT_DIR/raw-<日時>/ を作り、その中だけに書く。前の回と混ざらない。

保存するファイル（すべて raw-<日時>/ の中）。

    <prefix>-start.json         StartQueryExecution の応答（prefix は small / failed / big）
    <prefix>-execution-<n>.json GetQueryExecution の応答（ポーリングの回ごと）
    case-<n>.json               ケースごとの応答（ステータス・ヘッダ全部・本文そのまま。
                                **バケット名やアカウント ID を含みうる**）
    summary.txt                 実名を含まない要約。そのまま貼れる。

summary.txt には、ケースごとに HTTP ステータス、x-amzn-errortype ヘッダ（あれば）、
本文の __type・AthenaErrorCode・ErrorCode・Message、正常系なら Rows の件数・
1 列目の値の並び・NextToken の有無と形（長さ・文字種。値そのものは出さない）を書く。
NextToken の値・OUTPUT のバケットとプレフィックス・12 桁のアカウント ID らしき数列は
<NEXT_TOKEN>／<OUTPUT>／<ACCOUNT_ID> に置き換える。QueryExecutionId は秘密ではないが、
行を短くするため <QUERY_ID> に置き換える。
標準出力には summary.txt のパスだけを出す。

資格情報は botocore の既定の探索順（環境変数 AWS_ACCESS_KEY_ID 等、~/.aws/credentials、
IAM ロールなど）でそのまま読む。見つからなければ summary.txt に no_credentials と
だけ書いて終了コード 1 で終わる。
"""

import datetime
import json
import os
import re
import string
import sys
import time
import uuid
import urllib.error
import urllib.request

import botocore.session
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest

SERVICE = "athena"
QUERY = "SELECT n FROM UNNEST(sequence(1, 5)) AS t(n)"
# 既定ページサイズを測る（上限 1000 を超える行数）。
BIG_QUERY = "SELECT n FROM UNNEST(sequence(1, 1500)) AS t(n)"
# FAILED にするための、存在しないテーブルの SELECT。
FAILED_QUERY = "SELECT 1 FROM athena_local_issue83_missing_table"
# 実在しない QueryExecutionId（形は正しい UUID）。検証エラーと存在確認の順序を見るために使う。
MISSING_ID = "00000000-0000-4000-8000-000000000083"
# 不正な NextToken の固定値。ListWorkGroups（#9）の実測と同じ文字列。
BAD_TOKEN = "not-a-token"


def call(region, credentials, target, payload):
    """1 リクエスト分を送って、結果を dict で返す（raw-list-work-groups.py と同じ形）。"""
    body = json.dumps(payload).encode("utf-8")
    endpoint = "https://athena.{}.amazonaws.com/".format(region)
    result = {"target": target}
    # 名前解決の一時的な失敗に備え、HTTP エラー以外の送信失敗は 2 秒あけて 3 回まで試す。
    for attempt in range(3):
        # 署名は再試行のたびに付け直す（X-Amz-Date が古いと弾かれるため）。
        request = AWSRequest(
            method="POST",
            url=endpoint,
            data=body,
            headers={
                "Content-Type": "application/x-amz-json-1.1",
                "X-Amz-Target": target,
            },
        )
        SigV4Auth(credentials, SERVICE, region).add_auth(request)
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


def save(run_dir, name, result):
    with open(os.path.join(run_dir, name), "w") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)


def token_shape(token):
    """NextToken の値を出さずに形だけを言葉にする。"""
    kinds = []
    if token.isdigit():
        kinds.append("10 進の数字だけ")
    if re.fullmatch(r"[A-Za-z0-9+/]+=*", token):
        kinds.append("base64 らしい文字種")
    if re.fullmatch(r"[A-Za-z0-9_-]+=*", token):
        kinds.append("base64url らしい文字種")
    others = sorted(set(c for c in token if c not in string.ascii_letters + string.digits + "+/=_-"))
    if others:
        kinds.append("その他の文字 {}".format("".join(others)))
    return "長さ {}、{}".format(len(token), "・".join(kinds) if kinds else "文字種を判定できず")


def tweak(token):
    """正しいトークンの末尾 1 文字を別の文字に変えたもの（#9 と同じ変形）。"""
    last = token[-1]
    replacement = "B" if last != "B" else "C"
    return token[:-1] + replacement


def start_query(region, credentials, run_dir, output, query, prefix):
    """クエリを 1 本流して終端まで待ち、(QueryExecutionId, 最終状態, 理由) を返す。
    応答は run_dir/<prefix>-start.json と <prefix>-execution-<n>.json に置く。"""
    result = call(
        region,
        credentials,
        "AmazonAthena.StartQueryExecution",
        {
            "QueryString": query,
            "ResultConfiguration": {"OutputLocation": output},
            # 生 HTTP では CLI が自動で入れる ClientRequestToken が付かず、無いと
            # `clientRequestToken is null or empty` で弾かれる（#3 と 1 ラウンド目で実測）。
            "ClientRequestToken": str(uuid.uuid4()),
        },
    )
    save(run_dir, "{}-start.json".format(prefix), result)
    parsed = parsed_body(result)
    if result.get("status") != 200 or parsed is None or "QueryExecutionId" not in parsed:
        return None, "start_failed", result.get("body", result.get("exception", ""))
    query_id = parsed["QueryExecutionId"]
    timeout = float(os.environ.get("POLL_TIMEOUT", "120"))
    deadline = time.time() + timeout
    n = 0
    state = "UNKNOWN"
    reason = ""
    while True:
        n += 1
        execution = call(
            region, credentials, "AmazonAthena.GetQueryExecution", {"QueryExecutionId": query_id}
        )
        save(run_dir, "{}-execution-{}.json".format(prefix, n), execution)
        parsed = parsed_body(execution) or {}
        status = parsed.get("QueryExecution", {}).get("Status", {})
        state = status.get("State", "UNKNOWN")
        reason = status.get("StateChangeReason", "")
        if state in ("SUCCEEDED", "FAILED", "CANCELLED"):
            break
        if time.time() > deadline:
            state = "TIMEOUT({}s, last {})".format(int(timeout), state)
            break
        time.sleep(2)
    return query_id, state, reason


def build_cases(query_id, good_token, failed_id, big_id):
    """送るケース。payload はそのまま JSON にして本文にする（型違いも含めたいので、
    ここで botocore のモデルを通さない）。good_token が None のときは、それを使う
    ケースを None にして未測定にする。"""
    q = {"QueryExecutionId": query_id}

    def with_(**extra):
        payload = dict(q)
        payload.update(extra)
        return payload

    tweaked = tweak(good_token) if good_token else None
    return [
        (1, "引数なし（比較用の正常系。5 行 + 列名行）", with_()),
        (2, "MaxResults=1（正常系。NextToken の形を採る）", with_(MaxResults=1)),
        (3, "MaxResults=1000（botocore の上限ちょうど。正常系のはず）", with_(MaxResults=1000)),
        (4, "MaxResults=1001（上限 +1）", with_(MaxResults=1001)),
        (5, "MaxResults=0（下限 -1）", with_(MaxResults=0)),
        (6, "MaxResults=-1", with_(MaxResults=-1)),
        (7, "NextToken=空文字", with_(NextToken="")),
        (8, "NextToken=固定の不正な文字列", with_(NextToken=BAD_TOKEN)),
        (
            9,
            "NextToken=正しいトークンの末尾 1 文字を変えたもの",
            with_(NextToken=tweaked) if tweaked else None,
        ),
        (
            10,
            "NextToken=正しいトークン（2 ページ目。正常系）",
            with_(NextToken=good_token) if good_token else None,
        ),
        (
            11,
            "MaxResults=1 と NextToken=正しいトークン（2 ページ目にも NextToken が付くか）",
            with_(MaxResults=1, NextToken=good_token) if good_token else None,
        ),
        (12, "MaxResults=0 と NextToken=空文字（同時。2 validation errors になるか）", with_(MaxResults=0, NextToken="")),
        (13, "MaxResults=1001 と NextToken=空文字（同時）", with_(MaxResults=1001, NextToken="")),
        (14, "MaxResults=0 と NextToken=不正な文字列（検証と malformed のどちらが先か）", with_(MaxResults=0, NextToken=BAD_TOKEN)),
        (15, "MaxResults=1001 と NextToken=不正な文字列", with_(MaxResults=1001, NextToken=BAD_TOKEN)),
        (
            16,
            "MaxResults=0 と NextToken=正しいトークン",
            with_(MaxResults=0, NextToken=good_token) if good_token else None,
        ),
        (17, "実在しない QueryExecutionId だけ（比較用）", {"QueryExecutionId": MISSING_ID}),
        (18, "実在しない QueryExecutionId と MaxResults=0（検証と存在確認のどちらが先か）", {"QueryExecutionId": MISSING_ID, "MaxResults": 0}),
        (19, "実在しない QueryExecutionId と NextToken=不正な文字列", {"QueryExecutionId": MISSING_ID, "NextToken": BAD_TOKEN}),
        (20, "実在しない QueryExecutionId と NextToken=空文字", {"QueryExecutionId": MISSING_ID, "NextToken": ""}),
        (21, "MaxResults=\"1\"（文字列。型違い。#84 の参考）", with_(MaxResults="1")),
        (22, "QueryExecutionId 無し（必須項目の欠落。参考）", {"MaxResults": 1}),
        # ---- 3 ラウンド目で追加（2 ラウンド目で未実測だった順序と既定値）----
        (23, "実在しない QueryExecutionId と MaxResults=1001（上限と存在確認のどちらが先か）", {"QueryExecutionId": MISSING_ID, "MaxResults": 1001}),
        (24, "FAILED のクエリだけ（比較用。結果の無いクエリのエラー）", {"QueryExecutionId": failed_id} if failed_id else None),
        (25, "FAILED のクエリと NextToken=不正な文字列（結果無しとトークンの形のどちらが先か）", {"QueryExecutionId": failed_id, "NextToken": BAD_TOKEN} if failed_id else None),
        (26, "FAILED のクエリと MaxResults=1001", {"QueryExecutionId": failed_id, "MaxResults": 1001} if failed_id else None),
        (27, "FAILED のクエリと NextToken=空文字", {"QueryExecutionId": failed_id, "NextToken": ""} if failed_id else None),
        (28, "1500 行のクエリで MaxResults 無し（既定ページサイズ。列名行を数に入れるか）", {"QueryExecutionId": big_id} if big_id else None),
        (29, "1500 行のクエリで MaxResults=1000", {"QueryExecutionId": big_id, "MaxResults": 1000} if big_id else None),
        (30, "1500 行のクエリで MaxResults=1000 と 2 ページ目（1 ページ目の NextToken で。行数と NextToken の有無）", "big-page-2" if big_id else None),
    ]


def collect_secrets(results, good_token, output):
    """summary から伏せる文字列（トークン・OUTPUT・QueryExecutionId）を集める。"""
    tokens = set()
    if good_token:
        tokens.add(good_token)
        tokens.add(tweak(good_token))
    for result in results:
        parsed = parsed_body(result)
        if parsed is None:
            continue
        token = parsed.get("NextToken")
        if isinstance(token, str) and token:
            tokens.add(token)
    return tokens, output.rstrip("/")


def mask(text, tokens, output, query_id, other_ids=()):
    """トークン・OUTPUT・QueryExecutionId・12 桁のアカウント ID らしき数列をプレースホルダに置き換える。"""
    # 長いものから先に置き換える（短いトークンが長いトークンの一部のことがある）。
    for token in sorted(tokens, key=len, reverse=True):
        text = text.replace(token, "<NEXT_TOKEN>")
    if output:
        text = text.replace(output, "<OUTPUT>")
    if query_id:
        text = text.replace(query_id, "<QUERY_ID>")
    for name, other in other_ids:
        if other:
            text = text.replace(other, name)
    return re.sub(r"\d{12}", "<ACCOUNT_ID>", text)


def summarize(number, label, payload, result):
    """1 ケース分の要約を行の列で返す（マスクは呼び出し側）。"""
    lines = ["[ケース {}] {}".format(number, label)]
    if payload is None or result is None:
        lines.append("  未測定: 依存する準備（正しい NextToken / FAILED のクエリ / 1500 行のクエリ）が揃わなかった")
        return lines
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
    result_set = parsed.get("ResultSet")
    if isinstance(result_set, dict):
        rows = result_set.get("Rows")
        rows = rows if isinstance(rows, list) else []
        lines.append("  ResultSet.Rows の件数 = {}".format(len(rows)))
        firsts = []
        for row in rows:
            data = row.get("Data") if isinstance(row, dict) else None
            if isinstance(data, list) and data and isinstance(data[0], dict):
                firsts.append(str(data[0].get("VarCharValue")))
            else:
                firsts.append("?")
        shown = firsts if len(firsts) <= 8 else firsts[:4] + ["..."] + firsts[-3:]
        lines.append("  1 列目の値の並び = {}".format(", ".join(shown)))
        lines.append("  UpdateCount = {}".format(parsed.get("UpdateCount", "(キー無し)")))
        token = parsed.get("NextToken")
        if isinstance(token, str):
            lines.append("  NextToken = あり（{}）".format(token_shape(token)))
        else:
            lines.append("  NextToken = なし（キー無し）" if "NextToken" not in parsed else "  NextToken = {!r}".format(token))
    return lines


def main():
    region = os.environ.get("REGION", "ap-northeast-1")
    output = os.environ.get("OUTPUT", "")
    out_dir = os.environ.get(
        "OUT_DIR",
        os.path.join(os.path.expanduser("~"), "athena-get-query-results-measurements"),
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

    lines = [
        "GetQueryResults を生 HTTP（SigV4 自前署名）で呼んだ実測 — {}".format(stamp),
        "リージョン = {}".format(region),
        "Content-Type = application/x-amz-json-1.1",
        "流したクエリ = {}（テーブルは読まない）".format(QUERY),
        "注: 実測値は工場出荷時の既定とは限らない（コンソールで変更済みの可能性）。",
        "",
    ]

    query_id, state, reason = start_query(region, credentials, run_dir, output, QUERY, "small")
    lines.append("[準備] 5 行のクエリ → 最終状態 = {}".format(state))
    if reason:
        lines.append("  StateChangeReason = {}".format(reason))
    if query_id is None or state != "SUCCEEDED":
        lines.append("  クエリが成功しなかったので、GetQueryResults のケースは全部未測定。")
        with open(summary_path, "w") as f:
            f.write("\n".join(mask(line, set(), output.rstrip("/"), query_id) for line in lines) + "\n")
        print(summary_path)
        return 1

    failed_id, failed_state, failed_reason = start_query(
        region, credentials, run_dir, output, FAILED_QUERY, "failed"
    )
    lines.append("[準備] 存在しないテーブルのクエリ → 最終状態 = {}".format(failed_state))
    if failed_reason:
        lines.append("  StateChangeReason = {}".format(failed_reason))
    if failed_state != "FAILED":
        failed_id = None
        lines.append("  FAILED にならなかったので、FAILED のクエリを使うケースは未測定。")

    big_id, big_state, big_reason = start_query(region, credentials, run_dir, output, BIG_QUERY, "big")
    lines.append("[準備] 1500 行のクエリ → 最終状態 = {}".format(big_state))
    if big_reason:
        lines.append("  StateChangeReason = {}".format(big_reason))
    if big_state != "SUCCEEDED":
        big_id = None
        lines.append("  成功しなかったので、1500 行のクエリを使うケースは未測定。")
    lines.append("")

    # 先に MaxResults=1 を 1 回流して正しい NextToken を採る（ケース 2 と同じ本文。
    # ケース 2 自身は build_cases の順で改めて送るので、1 ページ目は 2 回呼ぶことになる）。
    probe = call(
        region,
        credentials,
        "AmazonAthena.GetQueryResults",
        {"QueryExecutionId": query_id, "MaxResults": 1},
    )
    save(run_dir, "probe-token.json", probe)
    probe_body = parsed_body(probe) or {}
    good_token = probe_body.get("NextToken") if isinstance(probe_body.get("NextToken"), str) else None
    if not good_token:
        lines.append("[準備] MaxResults=1 で NextToken が採れなかった。トークンを使うケースは未測定。")
        lines.append("")

    cases = build_cases(query_id, good_token, failed_id, big_id)
    results = []
    big_token = None
    for i, (number, _label, payload) in enumerate(cases):
        if payload == "big-page-2":
            # ケース 29 の応答の NextToken で 2 ページ目を取る。無ければ未測定。
            payload = (
                {"QueryExecutionId": big_id, "MaxResults": 1000, "NextToken": big_token}
                if big_token
                else None
            )
            cases[i] = (number, _label, payload)
        if payload is None:
            results.append(None)
            continue
        result = call(region, credentials, "AmazonAthena.GetQueryResults", payload)
        results.append(result)
        save(run_dir, "case-{}.json".format(number), result)
        if number == 29:
            token = (parsed_body(result) or {}).get("NextToken")
            big_token = token if isinstance(token, str) and token else None

    # ListWorkGroups の 2 件同時の形（#9 で未実測。GetQueryResults と同じ枠組みか）。
    lwg = call(region, credentials, "AmazonAthena.ListWorkGroups", {"MaxResults": 0, "NextToken": ""})
    save(run_dir, "case-31-list-work-groups.json", lwg)
    cases.append((31, "ListWorkGroups で MaxResults=0 と NextToken=空文字（同時。#9 の未実測分）", {"MaxResults": 0, "NextToken": ""}))
    results.append(lwg)

    tokens, output_plain = collect_secrets([r for r in results if r], good_token, output)
    for (number, label, payload), result in zip(cases, results):
        lines.extend(summarize(number, label, payload, result))
        lines.append("")
    with open(summary_path, "w") as f:
        others = (("<FAILED_ID>", failed_id), ("<BIG_ID>", big_id))
        f.write("\n".join(mask(line, tokens, output_plain, query_id, others) for line in lines) + "\n")
    print(summary_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
