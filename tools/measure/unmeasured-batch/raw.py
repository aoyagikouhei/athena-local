#!/usr/bin/env python3
# issue #113（フェーズ2）で作成
"""SigV4 を自前で署名した生 HTTP で、AWS CLI（botocore のクライアント側パラメータ検証）を
経由できない B 項目（t2・t3・t4・e2）と preflight（ListWorkGroups を1回）を測る。
raw-parse-errors.py（http.client・SigV4・call/save/parsed_body/mask の形）と
raw-client-request-token.py（token_mode）を雛形にしている。

--endpoint は必須で既定値を持たない（本物にも athena-local にも取り違えて送らないため）。

使い方（run.sh の lib-raw.sh の run_raw_item / raw_preflight から呼ばれる。単体で試すなら）:
    tools/dev.sh python3 tools/measure/unmeasured-batch/raw.py t2 \\
      --endpoint http://127.0.0.1:8087/ --region ap-northeast-1 \\
      --out-dir "$RUN_DIR/t2" --output s3://bucket/prefix/ --target local

item は preflight|t2|t3|t4|e2。--endpoint は run.sh が TARGET から決める（local:
lib-local.sh の LOCAL_ATHENA_BASE、real: https://athena.$REGION.amazonaws.com/）。
--output は preflight 以外で必須。--catalog/--database/--work-group は任意。
--target local なら local の期待値と突き合わせて detail に「期待どおり / 期待と違う」を足す。

保存: <out-dir>/<case>.json（送った本文・応答ヘッダ全部・送り先の URL。送信ヘッダは
Authorization と X-Amz-Security-Token を除く）。
標準出力: ケースごとに TSV 1 行「item<TAB>case<TAB>status<TAB>detail」。
run_raw_item / raw_preflight がこれを summary.tsv の 15 列（item→item_id、case→label、
kind=stmt、status→state、detail→note、残りは "-"）に変換して追記する。

資格情報は botocore の既定の探索順で読む（run.sh が export する AWS_EC2_METADATA_DISABLED=true
の下で動くので、資格情報が無いときも IMDS を待たずに no_credentials で終わる）。
見つからなければ no_credentials で終了コード2（他の使い方の誤りは1）。
"""

import argparse
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
ITEMS = ("preflight", "t2", "t3", "t4", "e2")


def call(endpoint, region, credentials, body, target):
    """1 リクエストを送って結果を dict で返す（raw-parse-errors.py の call を踏襲）。"""
    headers = {"Content-Type": DEFAULT_CONTENT_TYPE, "X-Amz-Target": target}
    result = {"target": target, "endpoint": endpoint}
    for attempt in range(3):
        request = AWSRequest(method="POST", url=endpoint, data=body, headers=dict(headers))
        SigV4Auth(credentials, SERVICE, region).add_auth(request)
        prepared = request.prepare()
        sent_headers = dict(prepared.headers)
        result["sent_headers"] = {
            k: v for k, v in sent_headers.items() if k.lower() not in ("authorization", "x-amz-security-token")
        }
        parts = urllib.parse.urlsplit(prepared.url)
        conn_cls = http.client.HTTPSConnection if parts.scheme == "https" else http.client.HTTPConnection
        conn = conn_cls(parts.netloc, timeout=60)
        try:
            conn.request("POST", parts.path or "/", body=prepared.body or b"", headers=sent_headers)
            resp = conn.getresponse()
            result["status"] = resp.status
            result["headers"] = dict(resp.getheaders())
            result["body"] = resp.read().decode("utf-8", "replace")
            result["outcome"] = "success" if resp.status == 200 else "error"
            result.pop("exception", None)
            break
        except Exception as e:  # noqa: BLE001 送信そのものの失敗（HTTP 応答以外）
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


def error_fields(result):
    parsed = parsed_body(result) or {}
    message = parsed.get("Message")
    if message is None:
        message = parsed.get("message")
    return {
        "__type": parsed.get("__type"),
        "AthenaErrorCode": parsed.get("AthenaErrorCode"),
        "ErrorCode": parsed.get("ErrorCode"),
        "Message": message,
    }


def query_execution_id(result):
    parsed = parsed_body(result)
    return parsed.get("QueryExecutionId") if parsed else None


def header_value(result, name):
    for key, value in (result.get("headers") or {}).items():
        if key.lower() == name:
            return value
    return None


def mask(text, values):
    for value in sorted((v for v in values if v), key=len, reverse=True):
        text = text.replace(value, "<VALUE>")
    return re.sub(r"\d{12}", "<ACCOUNT_ID>", text)


def short_id(value):
    return (value or "")[:8]


def make_token(length, unit="0123456789abcdef"):
    """長さ length ちょうどのトークンを作る（既定は ASCII 16 進の繰り返し。unit に
    複数バイト文字を渡せばそれを繰り返す。t3 のマルチバイト境界値に使う）。"""
    s = ""
    while len(s) < length:
        s += uuid.uuid4().hex if unit == "0123456789abcdef" else unit
    return s[:length]


def swap_char(s, index, ch):
    return s[:index] + ch + s[index + 1 :]


class Ctx:
    """1 回の実行で共有する引数・資格情報と、よく使う操作をまとめた入れ物。"""

    def __init__(self, args, credentials):
        self.args = args
        self.credentials = credentials

    def call(self, body, target):
        return call(self.args.endpoint, self.args.region, self.credentials, body, target)

    def save(self, name, result):
        with open(os.path.join(self.args.out_dir, name + ".json"), "w") as f:
            json.dump(result, f, ensure_ascii=False, indent=2)

    def mask(self, text):
        return mask(text, [self.args.output, self.args.catalog, self.args.database, self.args.work_group])

    def emit(self, item, case, status, detail):
        print("\t".join([item, case, str(status), self.mask(detail)]))

    def sqe_body(self, token, query, output=True):
        """output は True なら --output の値、文字列ならその値、None なら省く。"""
        payload = {"QueryString": query}
        context = {}
        if self.args.database:
            context["Database"] = self.args.database
        if self.args.catalog:
            context["Catalog"] = self.args.catalog
        if context:
            payload["QueryExecutionContext"] = context
        if output is True:
            payload["ResultConfiguration"] = {"OutputLocation": self.args.output}
        elif output is not None:
            payload["ResultConfiguration"] = {"OutputLocation": output}
        if self.args.work_group:
            payload["WorkGroup"] = self.args.work_group
        payload["ClientRequestToken"] = token
        return json.dumps(payload).encode("utf-8")

    def sqe(self, name, token, query, output=True):
        result = self.call(self.sqe_body(token, query, output), PREFIX + "StartQueryExecution")
        self.save(name, result)
        return result


def compare_detail(base_id, result):
    if result.get("outcome") != "success":
        fields = error_fields(result)
        return "エラー __type={} AthenaErrorCode={}".format(fields["__type"], fields["AthenaErrorCode"])
    return "同じ ID" if query_execution_id(result) == base_id else "別 ID"


def judge(actual_ok):
    return "期待どおり" if actual_ok else "期待と違う"


def run_preflight(ctx):
    """ListWorkGroups を 1 回呼ぶ。HTTP ステータスが 200 なら True、それ以外（エラー応答・
    送信自体の例外）は False を返す。main() がこれを見て終了コードを決める。"""
    result = ctx.call(b"{}", PREFIX + "ListWorkGroups")
    ctx.save("preflight", result)
    ok = result.get("status") == 200
    if ok:
        groups = (parsed_body(result) or {}).get("WorkGroups") or []
        detail = "{} 件のワークグループ".format(len(groups))
    else:
        detail = "status={} __type={}".format(result.get("status", result.get("outcome")), error_fields(result)["__type"])
    ctx.emit("preflight", "preflight", result.get("status", result.get("outcome")), detail)
    return ok


# t2 トークンの正規化: 基準トークンと、前後空白・ダブルクォート・バックスラッシュ・大文字化の
# 4変種、対照の再送を同じ文・同じパラメータで送る。local は文字列がそのまま違えば別トークン
# 扱いなので、変種は基準と別 ID、対照（そのまま再送）は基準と同じ ID になるはず。
def run_t2(ctx):
    base = make_token(40)
    base_result = ctx.sqe("t2-base", base, "SELECT 1")
    base_id = query_execution_id(base_result)
    ctx.emit("t2", "t2-base", base_result.get("status"), "ID={}".format(short_id(base_id)))

    variants = [
        ("space", " " + base + " ", "前後空白"),
        ("quote", swap_char(base, 20, '"'), "ダブルクォート"),
        ("backslash", swap_char(base, 20, "\\"), "バックスラッシュ"),
        ("upper", base.upper(), "大文字化"),
    ]
    for key, token, note in variants:
        result = ctx.sqe("t2-" + key, token, "SELECT 1")
        detail = "{}: {}".format(note, compare_detail(base_id, result))
        if ctx.args.target == "local":
            same = result.get("outcome") == "success" and query_execution_id(result) == base_id
            detail += " / " + judge(not same)
        ctx.emit("t2", "t2-" + key, result.get("status", result.get("outcome")), detail)

    control = ctx.sqe("t2-control", base, "SELECT 1")
    detail = "そのまま再送: {}".format(compare_detail(base_id, control))
    if ctx.args.target == "local":
        same = control.get("outcome") == "success" and query_execution_id(control) == base_id
        detail += " / " + judge(same)
    ctx.emit("t2", "t2-control", control.get("status", control.get("outcome")), detail)


# t3 長さはバイトか文字か: マルチバイト20文字(60バイト)・50文字(150バイト)は、文字数判定と
# バイト数判定とで結果が割れるように選んだ境界値。ASCII 31/32/128/129 は既知の対照。
# local は chars().count() なので 20文字は拒否・50文字は受理、ASCIIは31拒否・32受理・
# 128受理・129拒否のはず。
def run_t3(ctx):
    cases = [
        ("mb20", make_token(20, "あ"), 20, 60, True),
        ("mb50", make_token(50, "あ"), 50, 150, False),
        ("ascii31", make_token(31), 31, 31, True),
        ("ascii32", make_token(32), 32, 32, False),
        ("ascii128", make_token(128), 128, 128, False),
        ("ascii129", make_token(129), 129, 129, True),
    ]
    for key, token, chars, byte_len, expect_rejected in cases:
        result = ctx.sqe("t3-" + key, token, "SELECT 1")
        accepted = result.get("outcome") == "success"
        detail = "chars={} bytes={} {}".format(chars, byte_len, "受理" if accepted else "拒否")
        if not accepted:
            detail += " Message={}".format(error_fields(result)["Message"])
        if ctx.args.target == "local":
            detail += " / " + judge(accepted == (not expect_rejected))
        ctx.emit("t3", "t3-" + key, result.get("status", result.get("outcome")), detail)


# t4 検証の優先順位: 短いトークン(10文字)×不正な OutputLocation、短いトークン×構文エラー、
# 対照として各エラー単独。「不正な OutputLocation×構文エラー」（有効な長さのトークン）は
# items-token.sh の t4c（aws CLI で送れる）が既に測っているので、raw.py 側では aws CLI では
# 送れない短いトークンが絡む組だけを持つ（重複を避けるため。issue-notes 参照）。
# local は token → OutputLocation → 構文の順（src/operation/execution.rs）。
def run_t4(ctx):
    valid_token = make_token(40)
    short_token = make_token(10)
    bad_output = "s3://"
    bad_query = "SELEC 1"
    good_query = "SELECT 1"
    cases = [
        ("token-output", short_token, bad_output, good_query, "token"),
        ("token-syntax", short_token, True, bad_query, "token"),
        ("token-only", short_token, True, good_query, "token"),
        ("output-only", valid_token, bad_output, good_query, "output"),
        ("syntax-only", valid_token, True, bad_query, "syntax"),
    ]
    for key, token, output, query, expected in cases:
        result = ctx.sqe("t4-" + key, token, query, output)
        fields = error_fields(result)
        code = fields["AthenaErrorCode"]
        message = fields["Message"] or ""
        if code == "MALFORMED_QUERY":
            actual = "syntax"
        elif "clientRequestToken" in message:
            actual = "token"
        elif "outputLocation" in message:
            actual = "output"
        else:
            actual = "unknown({})".format(code)
        detail = "AthenaErrorCode={} 先に弾かれたのは={}".format(code, actual)
        if ctx.args.target == "local":
            detail += " / " + judge(actual == expected)
        ctx.emit("t4", "t4-" + key, result.get("status", result.get("outcome")), detail)


# e2 構文エラー(SELEC 1)の StartQueryExecution 1本。本文のキーと応答ヘッダを保存。
# local は ErrorCode キーが必ず付く（AthenaErrorCode と同じ値。src/response.rs）。
def run_e2(ctx):
    token = make_token(40)
    result = ctx.sqe("e2", token, "SELEC 1")
    fields = error_fields(result)
    errortype_header = header_value(result, "x-amzn-errortype")
    detail = "__type={} AthenaErrorCode={} ErrorCode={} x-amzn-errortype={}".format(
        fields["__type"], fields["AthenaErrorCode"], fields["ErrorCode"], errortype_header or "(なし)"
    )
    if ctx.args.target == "local":
        detail += " / " + judge(fields["ErrorCode"] is not None)
    ctx.emit("e2", "e2", result.get("status", result.get("outcome")), detail)


RUNNERS = {"preflight": run_preflight, "t2": run_t2, "t3": run_t3, "t4": run_t4, "e2": run_e2}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("item", choices=ITEMS)
    parser.add_argument("--endpoint", required=True, help="送り先の URL（既定値は無い）")
    parser.add_argument("--region", required=True)
    parser.add_argument("--out-dir", required=True, dest="out_dir")
    parser.add_argument("--output", default=None, help="OutputLocation（preflight 以外は必須）")
    parser.add_argument("--catalog", default=None)
    parser.add_argument("--database", default=None)
    parser.add_argument("--work-group", default=None, dest="work_group")
    parser.add_argument("--target", choices=("local", "real"), default="real")
    args = parser.parse_args()

    if args.item != "preflight" and not args.output:
        print("{0}\t{0}\tno_output\t--output（OutputLocation）が要る".format(args.item))
        return 1

    os.makedirs(args.out_dir, exist_ok=True)

    session = botocore.session.get_session()
    credentials = session.get_credentials()
    if credentials is None:
        print("{0}\t{0}\tno_credentials\tbotocore の既定の探索で資格情報が見つからない".format(args.item))
        return 2

    result = RUNNERS[args.item](Ctx(args, credentials))
    # preflight（ListWorkGroups）だけは、HTTP ステータスが 200 でなければ終了コード 1 にする
    # （lib-raw.sh の raw_preflight がこれで本編を止める）。他の item の終了コードは今のまま 0。
    if args.item == "preflight" and result is False:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
