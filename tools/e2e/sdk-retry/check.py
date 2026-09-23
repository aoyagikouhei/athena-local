#!/usr/bin/env python3
# issue #94 で作成
"""ClientRequestToken の冪等性を、実 SDK のリトライと高多重度の同時送信で確かめる。

verify.sh が Trino・athena-local・応答を落とす代理（drop_proxy.py）を立てたあとに呼ぶ。
boto3 が要る（verify.sh は `uv run --with boto3` で呼ぶ）。本物の AWS は一切使わない。

確かめること:
  1. boto3 を代理に向けて INSERT を 1 回呼ぶ。代理が最初の 2 回の応答を落とすので、SDK は同じ
     ClientRequestToken で再送する（botocore が idempotencyToken を補い、リトライでも変えない）。
     Trino に届いた INSERT が 1 回で、表の行が 1 行であること。構文チェックの PREPARE は
     試行のたびに届く（照合は構文チェックの後）ので、その回数が試行回数の証拠になる。
  2. 同じトークンを 50 スレッドから athena-local に直接同時に送り、返る QueryExecutionId が
     1 つで、Trino に届いた SELECT が 1 回で、詰まらずに返ること。対照として違うトークン 2 つを
     同時に送ると ID が 2 つになること。

出力は 1 件 1 行の `PASS <名前>` / `FAIL <名前>: <詳細>`。終了コードは FAIL の件数。
"""

import json
import os
import sys
import time
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor

import boto3
from botocore.config import Config

ATHENA_DIRECT = os.environ.get("ATHENA_DIRECT", "http://127.0.0.1:8091")
PROXY = os.environ.get("PROXY", "http://127.0.0.1:8096")
TRINO = os.environ.get("TRINO", "http://127.0.0.1:8095")
PARALLEL = int(os.environ.get("PARALLEL", "50"))

failures = 0


def report(name, ok, detail=""):
    global failures
    if ok:
        print(f"PASS {name}")
    else:
        failures += 1
        print(f"FAIL {name}: {detail}")


def trino(sql):
    """Trino の REST で 1 文を実行し、行を返す（nextUri を辿る）。"""
    request = urllib.request.Request(
        f"{TRINO}/v1/statement",
        data=sql.encode(),
        headers={"X-Trino-User": "check94"},
        method="POST",
    )
    with urllib.request.urlopen(request) as response:
        page = json.load(response)
    rows = []
    while True:
        rows.extend(page.get("data", []))
        if "error" in page:
            raise RuntimeError(page["error"].get("message"))
        next_uri = page.get("nextUri")
        if not next_uri:
            return rows
        time.sleep(0.05)
        with urllib.request.urlopen(next_uri) as response:
            page = json.load(response)


def trino_query_count(marker):
    """目印を含む文が Trino に届いた回数。構文チェックの PREPARE と、この問い合わせ自身は除く。"""
    rows = trino(
        "SELECT count(*) FROM system.runtime.queries "
        f"WHERE query LIKE '%{marker}%' AND query NOT LIKE 'PREPARE%' AND query NOT LIKE '%system.runtime%'"
    )
    return rows[0][0]


def trino_prepare_count(marker):
    rows = trino(
        "SELECT count(*) FROM system.runtime.queries "
        f"WHERE query LIKE 'PREPARE%' AND query LIKE '%{marker}%'"
    )
    return rows[0][0]


def athena_direct(operation, body):
    request = urllib.request.Request(
        ATHENA_DIRECT + "/",
        data=json.dumps(body).encode(),
        headers={
            "X-Amz-Target": f"AmazonAthena.{operation}",
            "Content-Type": "application/x-amz-json-1.1",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read() or b"{}")


def wait_terminal(client, query_id, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        state = client.get_query_execution(QueryExecutionId=query_id)["QueryExecution"]["Status"]["State"]
        if state in ("SUCCEEDED", "FAILED", "CANCELLED"):
            return state
        time.sleep(0.2)
    return "TIMEOUT"


def check_sdk_retry():
    trino("CREATE TABLE IF NOT EXISTS memory.default.t94 (n bigint)")
    client = boto3.client(
        "athena",
        endpoint_url=PROXY,
        region_name="us-east-1",
        aws_access_key_id="dummy",
        aws_secret_access_key="dummy",
        config=Config(retries={"max_attempts": 5, "mode": "standard"}),
    )
    started = time.time()
    query_id = client.start_query_execution(
        QueryString="INSERT INTO memory.default.t94 VALUES (94) /* t94-insert */",
        QueryExecutionContext={"Catalog": "memory", "Database": "default"},
    )["QueryExecutionId"]
    elapsed = time.time() - started
    print(f"info sdk-retry: QueryExecutionId={query_id} start_query_execution took {elapsed:.1f}s (retries included)")
    state = wait_terminal(client, query_id)
    report("sdk-retry query succeeded", state == "SUCCEEDED", f"state={state}")
    prepares = trino_prepare_count("t94-insert")
    print(f"info sdk-retry: PREPARE (syntax check) reached Trino {prepares} times = SDK attempts")
    report("sdk-retry reached the server more than once", prepares >= 2, f"PREPARE count={prepares}")
    inserts = trino_query_count("t94-insert")
    report("sdk-retry INSERT executed once on Trino", inserts == 1, f"count={inserts}")
    rows = trino("SELECT count(*) FROM memory.default.t94")[0][0]
    report("sdk-retry table has one row", rows == 1, f"rows={rows}")


def start_with_token(token, marker):
    return athena_direct(
        "StartQueryExecution",
        {"QueryString": f"SELECT 94 /* {marker} */", "ClientRequestToken": token},
    )


def check_parallel():
    token = str(uuid.uuid4())
    started = time.time()
    with ThreadPoolExecutor(max_workers=PARALLEL) as pool:
        results = list(pool.map(lambda _: start_with_token(token, "t94-parallel"), range(PARALLEL)))
    elapsed = time.time() - started
    statuses = {status for status, _ in results}
    ids = {body.get("QueryExecutionId") for _, body in results}
    print(f"info parallel: {PARALLEL} calls with one token took {elapsed:.2f}s, ids={len(ids)}")
    report("parallel all 200", statuses == {200}, f"statuses={statuses} sample={results[0][1]}")
    report("parallel one QueryExecutionId", len(ids) == 1, f"ids={ids}")
    report("parallel finished within 10s", elapsed < 10, f"{elapsed:.2f}s")
    time.sleep(1)
    selects = trino_query_count("t94-parallel")
    report("parallel SELECT executed once on Trino", selects == 1, f"count={selects}")

    tokens = [str(uuid.uuid4()), str(uuid.uuid4())]
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda t: start_with_token(t, "t94-control"), tokens))
    ids = {body.get("QueryExecutionId") for _, body in results}
    report("control: two tokens give two ids", len(ids) == 2, f"ids={ids}")


def main():
    check_sdk_retry()
    check_parallel()
    print(f"summary: {failures} failed")
    sys.exit(min(failures, 125))


if __name__ == "__main__":
    main()
