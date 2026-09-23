#!/usr/bin/env python3
"""#83 で未実測のまま残した 3 点（#85）を、本物の Athena に生 HTTP（SigV4 自前署名）で測る。
署名・送信・保存・要約の関数は同じディレクトリの 83-measure-raw-get-query-results.py から読み込む
（ファイル名にハイフンがあるので importlib で読む）。

測ること:
  A. ListWorkGroups で MaxResults の上限超過（51）と NextToken の空文字が同時のときの文言
     （下限未満と空文字の同時は #83 のケース 31 で `2 validation errors detected: ...` と実測済み）。
     ついでに 51 と不正なトークンの同時（検証と malformed のどちらが先か）も採る。
  B. RUNNING と CANCELLED のクエリに不正な NextToken・空文字・MaxResults 0・1001 を渡したときの順序
     （FAILED では状態のエラーがトークンの形より先、上限は状態より先と実測済み。#83 ケース 25〜27）。
     実行中のクエリを作るために、テーブルを読まない重い SELECT を 1 本流し、測り終えたら StopQueryExecution で止める。
  C. 0 行の結果（DML: `SELECT 1 AS n WHERE false` は列名行だけ、UTILITY: `SHOW DATABASES LIKE ...` は 0 行）に
     NextToken を渡したときの文言。
  D. 参考: GetQueryResults の MaxResults が Integer の範囲外（#87 の項目 7。上限 1000 の文言になるか）。

使い方:
    OUTPUT=s3://your-bucket/prefix/ <botocore 入りの python3> 85-measure-raw-paging-leftovers.py

任意の環境変数:
    REGION        既定 ap-northeast-1
    OUT_DIR       既定 $HOME/athena-paging-leftovers-measurements（実名が入りうるのでリポジトリの外）
    POLL_TIMEOUT  終端状態を待つ上限（秒）。既定 120
    HEAVY_ROWS    重いクエリの片側の行数。既定 50000（sequence の上限。3 方向の CROSS JOIN で 1.25e14 行を数えるので途中で止める）

** 課金の注意 **
    流すクエリは 3 本で、どれもテーブルは読まない（スキャン 0 バイト）。DDL・書き込みは無い。
      - `SELECT 1 AS n WHERE false`（0 行の DML）
      - `SHOW DATABASES LIKE 'athena_local_issue85_no_such_db'`（0 行の UTILITY。実在しない名前）
      - `SELECT n FROM UNNEST(sequence(1, 5))`（5 行。トークン発行の規則を辿る。2 ラウンド目で追加）
      - `SELECT count(*) FROM UNNEST(sequence(1, 50000)) a CROSS JOIN ... b CROSS JOIN ... c`（重い。RUNNING を測ったら
        StopQueryExecution で止める。万一止められなくても数分で終わり、スキャンは 0 バイト）
    結果ファイルが OUTPUT に 3 組置かれる。本物への呼び出しは StartQueryExecution 4 回、GetQueryExecution が数十回、
    GetQueryResults 約 30 回、StopQueryExecution 1 回、ListWorkGroups 2 回。すべて読み取り（StopQueryExecution は自分のクエリの取り消し）。

保存するファイル: run_dir/<prefix>-start.json、<prefix>-execution-<n>.json、case-<n>.json、stop.json、summary.txt（実名マスク済み）。
標準出力には summary.txt のパスだけを出す。資格情報は botocore の既定の探索順で読み、無ければ no_credentials で止まる。
"""

import datetime
import importlib.util
import os
import sys
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "measure83", os.path.join(HERE, "83-measure-raw-get-query-results.py")
)
m83 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m83)

BAD_TOKEN = m83.BAD_TOKEN
EMPTY_DML = "SELECT 1 AS n WHERE false"
EMPTY_UTILITY = "SHOW DATABASES LIKE 'athena_local_issue85_no_such_db'"


def heavy_query():
    # sequence は 50000 件までしか作れない（1 ラウンド目で INVALID_FUNCTION_ARGUMENT。#85）。
    # 50000^3 = 1.25e14 行を数えるので数分では終わらず、RUNNING を捕まえてから止められる。
    n = int(os.environ.get("HEAVY_ROWS", "50000"))
    return (
        "SELECT count(*) FROM UNNEST(sequence(1, {n})) AS a(x) "
        "CROSS JOIN UNNEST(sequence(1, {n})) AS b(y) CROSS JOIN UNNEST(sequence(1, {n})) AS c(z)"
    ).format(n=n)


def follow_pages(region, credentials, run_dir, query_id, max_results, label, first_number, limit=6):
    """MaxResults を固定してページを最後まで辿り、(ケースの列, 結果の列) を返す。
    本物がトークンを「ページが満杯のとき」に出すのか「残りがあるとき」に出すのかを、
    行数がちょうど割り切れる組み合わせで確かめる。"""
    cases, results = [], []
    token = None
    for i in range(limit):
        payload = {"QueryExecutionId": query_id, "MaxResults": max_results}
        if token:
            payload["NextToken"] = token
        result = m83.call(region, credentials, "AmazonAthena.GetQueryResults", payload)
        number = first_number + i
        m83.save(run_dir, "case-{}.json".format(number), result)
        cases.append((number, "{}: MaxResults={} の {} ページ目".format(label, max_results, i + 1), "GetQueryResults", payload))
        results.append(result)
        body = m83.parsed_body(result) or {}
        token = body.get("NextToken") if isinstance(body.get("NextToken"), str) else None
        if not token:
            break
    return cases, results


def start_only(region, credentials, run_dir, output, query, prefix):
    """StartQueryExecution だけ行い、(QueryExecutionId, 応答) を返す（終端は待たない）。"""
    result = m83.call(
        region,
        credentials,
        "AmazonAthena.StartQueryExecution",
        {
            "QueryString": query,
            "ResultConfiguration": {"OutputLocation": output},
            "ClientRequestToken": str(uuid.uuid4()),
        },
    )
    m83.save(run_dir, "{}-start.json".format(prefix), result)
    parsed = m83.parsed_body(result)
    if result.get("status") != 200 or parsed is None or "QueryExecutionId" not in parsed:
        return None, result
    return parsed["QueryExecutionId"], result


def wait_state(region, credentials, run_dir, query_id, prefix, wanted, timeout):
    """状態が wanted のどれかになるまで待ち、(最終状態, 理由) を返す。終端に入ったらそこで止める。"""
    deadline = time.time() + timeout
    n = 0
    state, reason = "UNKNOWN", ""
    while True:
        n += 1
        execution = m83.call(
            region, credentials, "AmazonAthena.GetQueryExecution", {"QueryExecutionId": query_id}
        )
        m83.save(run_dir, "{}-execution-{}.json".format(prefix, n), execution)
        status = (m83.parsed_body(execution) or {}).get("QueryExecution", {}).get("Status", {})
        state = status.get("State", "UNKNOWN")
        reason = status.get("StateChangeReason", "")
        if state in wanted or state in ("SUCCEEDED", "FAILED", "CANCELLED"):
            return state, reason
        if time.time() > deadline:
            return "TIMEOUT({}s, last {})".format(int(timeout), state), reason
        time.sleep(1)


def gqr_cases(number, label_prefix, query_id):
    """1 つのクエリに対する 4 通り（不正トークン・空文字・MaxResults 0・1001）。"""
    q = {"QueryExecutionId": query_id}
    return [
        (number, "{}: 引数なし（対照）".format(label_prefix), dict(q)),
        (number + 1, "{}: NextToken=不正な文字列".format(label_prefix), dict(q, NextToken=BAD_TOKEN)),
        (number + 2, "{}: NextToken=空文字".format(label_prefix), dict(q, NextToken="")),
        (number + 3, "{}: MaxResults=0".format(label_prefix), dict(q, MaxResults=0)),
        (number + 4, "{}: MaxResults=1001".format(label_prefix), dict(q, MaxResults=1001)),
    ]


def main():
    region = os.environ.get("REGION", "ap-northeast-1")
    output = os.environ.get("OUTPUT", "")
    out_dir = os.environ.get(
        "OUT_DIR", os.path.join(os.path.expanduser("~"), "athena-paging-leftovers-measurements")
    )
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    run_dir = os.path.join(out_dir, "raw-{}".format(stamp))
    os.makedirs(run_dir, exist_ok=True)
    summary_path = os.path.join(run_dir, "summary.txt")
    timeout = float(os.environ.get("POLL_TIMEOUT", "120"))

    if not output.startswith("s3://"):
        with open(summary_path, "w") as f:
            f.write("no_output\nOUTPUT（s3://bucket/prefix/）が要る。何も送っていない。\n")
        print(summary_path)
        return 1
    if not output.endswith("/"):
        output += "/"

    session = m83.botocore.session.get_session()
    credentials = session.get_credentials()
    if credentials is None:
        with open(summary_path, "w") as f:
            f.write("no_credentials\nbotocore の既定の探索順で資格情報が見つからなかった。何も送っていない。\n")
        print(summary_path)
        return 1

    lines = [
        "#85 ページング検証の未実測 3 点を生 HTTP で測った — {}".format(stamp),
        "リージョン = {}".format(region),
        "注: 実測値は工場出荷時の既定とは限らない（コンソールで変更済みの可能性）。",
        "",
    ]
    cases = []   # (number, label, target, payload or None)
    results = []
    ids = []

    # A. ListWorkGroups の同時
    cases.append((1, "ListWorkGroups: MaxResults=51 と NextToken=空文字（上限超過と空文字の同時）", "ListWorkGroups", {"MaxResults": 51, "NextToken": ""}))
    cases.append((2, "ListWorkGroups: MaxResults=51 と NextToken=不正な文字列", "ListWorkGroups", {"MaxResults": 51, "NextToken": BAD_TOKEN}))
    cases.append((3, "ListWorkGroups: MaxResults=0 と NextToken=不正な文字列", "ListWorkGroups", {"MaxResults": 0, "NextToken": BAD_TOKEN}))

    # C. 0 行の結果
    for prefix, query, base in (("empty-dml", EMPTY_DML, 10), ("empty-utility", EMPTY_UTILITY, 20)):
        query_id, state, reason = m83.start_query(region, credentials, run_dir, output, query, prefix)
        lines.append("[準備] {} → 最終状態 = {}{}".format(query, state, "（" + reason + "）" if reason else ""))
        ids.append((prefix, query_id))
        ok = query_id is not None and state == "SUCCEEDED"
        q = {"QueryExecutionId": query_id} if ok else None
        cases.append((base, "{}: 引数なし（行数の対照）".format(prefix), "GetQueryResults", q))
        cases.append((base + 1, "{}: NextToken=不正な文字列".format(prefix), "GetQueryResults", dict(q, NextToken=BAD_TOKEN) if ok else None))
        cases.append((base + 2, "{}: NextToken=\"1\"（athena-local が発行しうる形）".format(prefix), "GetQueryResults", dict(q, NextToken="1") if ok else None))
        cases.append((base + 3, "{}: MaxResults=1（NextToken が付くか）".format(prefix), "GetQueryResults", dict(q, MaxResults=1) if ok else None))

    # D. 参考: GetQueryResults の MaxResults が Integer の範囲外（0 行の DML のクエリで）
    dml_id = ids[0][1]
    cases.append((30, "empty-dml: MaxResults=99999999999（Integer の範囲外。#87 の項目 7）", "GetQueryResults",
                  {"QueryExecutionId": dml_id, "MaxResults": 99999999999} if dml_id else None))

    # E. トークン発行の規則（2 ラウンド目で追加）。1 ラウンド目で「列名行だけの結果に MaxResults=1 で
    # NextToken が付く」と分かった。行数がちょうど割り切れるとき（5 行 + 列名行 = 6 行）に、
    # MaxResults=6（1 ページで満杯）・3（2 ページで満杯）・4（2 ページ目が半端）でトークンが付くか、
    # 付いたトークンで次を取ると何が返るかを最後まで辿る。列名行だけの結果も MaxResults=1 で辿る。
    small_id, state, reason = m83.start_query(region, credentials, run_dir, output, m83.QUERY, "small")
    lines.append("[準備] {} → 最終状態 = {}{}".format(m83.QUERY, state, "（" + reason + "）" if reason else ""))
    ids.append(("small", small_id))
    follow = []
    if small_id and state == "SUCCEEDED":
        follow.append((small_id, 6, "small(6 行)", 60))
        follow.append((small_id, 3, "small(6 行)", 70))
        follow.append((small_id, 4, "small(6 行)", 80))
    if dml_id:
        follow.append((dml_id, 1, "empty-dml(列名行だけ)", 90))

    # B. 実行中と取り消し後
    heavy_id, start_result = start_only(region, credentials, run_dir, output, heavy_query(), "heavy")
    ids.append(("heavy", heavy_id))
    running_ok = False
    if heavy_id is None:
        lines.append("[準備] 重いクエリの StartQueryExecution が失敗: {}".format(start_result.get("body", start_result.get("exception", ""))))
    else:
        state, reason = wait_state(region, credentials, run_dir, heavy_id, "heavy", ("RUNNING",), timeout)
        lines.append("[準備] 重いクエリ → 状態 = {}{}".format(state, "（" + reason + "）" if reason else ""))
        running_ok = state == "RUNNING"
        if not running_ok:
            lines.append("  RUNNING で捕まえられなかった（速すぎた／QUEUED のまま）。RUNNING のケースは未測定。")
    for number, label, payload in gqr_cases(40, "RUNNING", heavy_id):
        cases.append((number, label, "GetQueryResults", payload if running_ok else None))

    # ここまでのケースを送る（RUNNING のケースは止める前に送る必要がある）
    for number, label, target, payload in cases:
        if payload is None:
            results.append(None)
            continue
        result = m83.call(region, credentials, "AmazonAthena." + target, payload)
        results.append(result)
        m83.save(run_dir, "case-{}.json".format(number), result)
    for query_id, max_results, label, first_number in follow:
        c, r = follow_pages(region, credentials, run_dir, query_id, max_results, label, first_number)
        cases.extend(c)
        results.extend(r)

    cancelled_ok = False
    if heavy_id is not None:
        stop = m83.call(region, credentials, "AmazonAthena.StopQueryExecution", {"QueryExecutionId": heavy_id})
        m83.save(run_dir, "stop.json", stop)
        state, reason = wait_state(region, credentials, run_dir, heavy_id, "heavy-after-stop", ("CANCELLED",), timeout)
        lines.append("[準備] StopQueryExecution → HTTP {} → 状態 = {}{}".format(stop.get("status"), state, "（" + reason + "）" if reason else ""))
        cancelled_ok = state == "CANCELLED"
        if not cancelled_ok:
            lines.append("  CANCELLED にならなかった。CANCELLED のケースは未測定。")
    later = []
    for number, label, payload in gqr_cases(50, "CANCELLED", heavy_id):
        later.append((number, label, "GetQueryResults", payload if cancelled_ok else None))
    for number, label, target, payload in later:
        if payload is None:
            results.append(None)
        else:
            result = m83.call(region, credentials, "AmazonAthena." + target, payload)
            results.append(result)
            m83.save(run_dir, "case-{}.json".format(number), result)
    cases.extend(later)
    lines.append("")

    tokens, output_plain = m83.collect_secrets([r for r in results if r], None, output)
    for (number, label, target, payload), result in zip(cases, results):
        head = m83.summarize(number, "[{}] {}".format(target, label), payload, result)
        lines.extend(head)
        lines.append("")
    others = tuple(("<{}_ID>".format(prefix.upper().replace("-", "_")), query_id) for prefix, query_id in ids)
    with open(summary_path, "w") as f:
        f.write("\n".join(m83.mask(line, tokens, output_plain, None, others) for line in lines) + "\n")
    print(summary_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
