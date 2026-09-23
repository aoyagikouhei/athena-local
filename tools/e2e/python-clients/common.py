#!/usr/bin/env python3
# issue #111: python-clients の check が共有する小道具。
# - 結果行 `PASS|FAIL|SKIP|INFO <名前>: <詳細>` を出す（verify.sh がこの形の行だけを集計する）
# - 中継のログと MinIO の trace の「区間読み」: check の開始時に行数を控え、それより後の行だけを数える。
#   先行する check や canary の STS・GetWorkGroup の行が、後の check の「0 件」「≥1 件」に混ざらないようにするため。
# - 中継のログの形式は tools/e2e/sdk-retry/drop_proxy.py:11-12 の
#   `proxy: <relay|drop> target=<X-Amz-Target か -> token=<ClientRequestToken か ->`（STS・S3 は target=-）。
# - trace は `mc admin trace --json` の 1 行 1 JSON（"api":"s3.GetObject"、"path":"/<bucket>/<key>"）。
#
# 環境変数: PROXY_LOG（中継の標準エラーの保存先）、TRACE_CONTAINER（trace を流す mc のコンテナ名）
# コマンドとしても使う（check_dbt.sh から）:
#   common.py mark                 → `<中継の行数> <trace の行数>` を出す
#   common.py count <起点> <正規表現> → 起点より後の中継の行のうち正規表現に一致する件数を出す

import json
import os
import re
import subprocess
import sys
import time

RESULTS = []

# (7) 退行の「型の行」。awswrangler と PyAthena で同じものを読む。値を突き合わせるのは int（i）と varchar（v）だけ。
TYPES_SQL = """SELECT * FROM (
SELECT 1 AS i, CAST(10 AS bigint) AS bi, 1.5E0 AS d, CAST(1.25 AS decimal(10,2)) AS dc,
  'a,b"c' || chr(10) || 'd' || chr(9) || 'é日本' AS v, true AS bo, DATE '2026-09-23' AS dt,
  TIMESTAMP '2026-09-23 12:34:56.789' AS ts, ARRAY[1, 2] AS arr, MAP(ARRAY['k'], ARRAY[1]) AS mp,
  CAST(NULL AS varchar) AS nul
UNION ALL
SELECT 2, CAST(20 AS bigint), 2.5E0, CAST(2.50 AS decimal(10,2)), 'plain', false, DATE '2026-01-01',
  TIMESTAMP '2026-01-01 00:00:00.000', ARRAY[3], MAP(ARRAY['z'], ARRAY[2]), 'x'
) ORDER BY i"""
TYPES_I = ["1", "2"]
TYPES_V = ['a,b"c\nd\té日本', "plain"]


def types_key(rows_i, rows_v):
    """int 列は整数の文字列に、varchar 列は生の値にそろえる（比べるのはこの 2 列だけ）。"""
    return [str(int(x)) for x in rows_i], [str(x) for x in rows_v]


def report(status, name, detail):
    assert status in ("PASS", "FAIL", "SKIP", "INFO"), status
    detail = " ".join(str(detail).split())
    RESULTS.append(status)
    print(f"{status} {name}: {detail}", flush=True)


def failures():
    return RESULTS.count("FAIL")


def proxy_lines():
    with open(os.environ["PROXY_LOG"], encoding="utf-8", errors="replace") as f:
        return [line for line in f.read().splitlines() if line.startswith("proxy: ")]


def trace_lines():
    # trace のコンテナ（--rm）が途中で消えると docker logs が失敗して空になり、「GET 0 件」が偽の PASS になる。
    # 失敗は例外にして check を異常終了させる（verify.sh の run_check が FAIL に数える）。
    out = subprocess.run(
        ["docker", "logs", os.environ["TRACE_CONTAINER"]],
        capture_output=True, text=True, check=False,
    )
    if out.returncode != 0:
        raise RuntimeError(f"trace のコンテナのログを読めない: {out.stderr.strip()[:200]}")
    return [line for line in out.stdout.splitlines() if line.startswith("{")]


class Window:
    """check の区間。start() の時点の行数を控え、それより後の行だけを見る。"""

    def __init__(self, proxy_from=None, trace_from=None):
        self.proxy_from = proxy_from
        self.trace_from = trace_from

    def start(self):
        self.proxy_from = len(proxy_lines())
        self.trace_from = len(trace_lines())
        return self

    def proxy(self):
        return proxy_lines()[self.proxy_from:]

    def proxy_count(self, pattern):
        return sum(1 for line in self.proxy() if re.search(pattern, line))

    def proxy_targets(self):
        return sorted({m.group(1) for line in self.proxy() if (m := re.search(r"target=(\S+)", line))})

    def trace(self, settle=1.5):
        # trace は非同期に流れてくるので、読む前に少し待つ。
        time.sleep(settle)
        lines = trace_lines()
        if len(lines) < self.trace_from:
            raise RuntimeError(f"trace の行数が区間の起点より少ない（{len(lines)} < {self.trace_from}）。コンテナが作り直された")
        events = []
        for line in lines[self.trace_from:]:
            try:
                events.append(json.loads(line))
            except ValueError:
                continue
        return events

    def reads(self, path_prefix, apis=("s3.GetObject", "s3.HeadObject")):
        """path_prefix（/<bucket>/<key> の前方一致。.txt なら .txt.metadata も含む）を読みに行った件数。"""
        return [
            e for e in self.trace()
            if e.get("api") in apis and str(e.get("path", "")).startswith(path_prefix)
        ]


def athena_client():
    import boto3

    # endpoint_url は渡さない（AWS_ENDPOINT_URL_ATHENA が効く）。
    return boto3.client("athena")


def wait_query(client, query_id, timeout=60):
    deadline = time.time() + timeout
    while time.time() < deadline:
        status = client.get_query_execution(QueryExecutionId=query_id)["QueryExecution"]["Status"]
        if status["State"] in ("SUCCEEDED", "FAILED", "CANCELLED"):
            return status
        time.sleep(0.2)
    raise TimeoutError(query_id)


def mc_exists(key):
    """MinIO に <bucket>/<key> があるか（compose のネットワークに繋いだ mc の使い捨てコンテナで。trace にも出る）。"""
    cmd = ("mc alias set local http://minio:9000 minioadmin minioadmin >/dev/null && "
           f"mc stat 'local/{key}' >/dev/null")
    out = subprocess.run(
        ["docker", "run", "--rm", "--network", os.environ["MC_NETWORK"], "--entrypoint", "sh",
         "quay.io/minio/mc:latest", "-c", cmd],
        capture_output=True, text=True, check=False,
    )
    return out.returncode == 0


def short(exc):
    return f"{type(exc).__name__}: {str(exc).splitlines()[0] if str(exc) else ''}"[:300]


def canary():
    """本物の AWS に出そうな経路（STS・Glue・S3 の既定エンドポイント）が手元に塞がれていることを確かめる。

    STS と Glue は AWS_ENDPOINT_URL（中継）に届き、athena-local が 4xx を返して例外になれば塞がれている。
    S3 は client の endpoint が MinIO を指していれば塞がれている。
    """
    import boto3

    window = Window().start()
    outcomes = {}
    for service, call in (("sts", lambda c: c.get_caller_identity()), ("glue", lambda c: c.get_databases())):
        client = boto3.client(service)
        seen = []
        # STS の応答は XML として読めず ResponseParserError になり HTTP の状態が例外に載らないので、
        # 解析の前（before-parse）で状態と本文の頭を控える。
        client.meta.events.register(
            "before-parse", lambda response_dict, **_: seen.append(
                f"{response_dict['status_code']} {response_dict['body'][:60].decode(errors='replace')}"))
        try:
            call(client)
            outcome = "例外なし"
        except Exception as exc:  # noqa: BLE001 何で落ちたかを記録する
            outcome = short(exc)
        outcomes[service] = f"http={seen[0] if seen else '-'} {outcome}"
    sts_rows = window.proxy_count(r"target=- ")
    glue_rows = window.proxy_count(r"target=AWSGlue\.GetDatabases ")
    s3_endpoint = boto3.client("s3").meta.endpoint_url
    blocked = all(str(v).startswith("http=4") for v in outcomes.values())
    detail = (f"中継の区間に STS(target=-)={sts_rows} Glue(AWSGlue.GetDatabases)={glue_rows}; "
              f"sts={outcomes['sts']}; glue={outcomes['glue']}; s3 endpoint={s3_endpoint}")
    ok = sts_rows >= 1 and glue_rows >= 1 and blocked and s3_endpoint == os.environ.get("AWS_ENDPOINT_URL_S3")
    report("PASS" if ok else "FAIL", "canary(漏れ防止)", detail)
    return failures()


def main(argv):
    if argv[1:2] == ["canary"]:
        return canary()
    if argv[1:2] == ["mark"]:
        print(len(proxy_lines()), len(trace_lines()))
    elif argv[1:2] == ["count"]:
        print(Window(proxy_from=int(argv[2])).proxy_count(argv[3]))
    else:
        print(__doc__ or "usage: common.py mark | count <起点> <正規表現>", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
