#!/usr/bin/env python3
# issue #111: awswrangler 3.17.1 を athena-local に向けて確かめる（verify.sh が venv-wr の python で呼ぶ）。
#   python check_awswrangler.py s3    … (2) F1・F2、(7) awswrangler 側。athena-local は s3 モード（中継 8102 → 8098）
#   python check_awswrangler.py none  … (2) F3（INFO）、(9)。AWS_ENDPOINT_URL_ATHENA だけ none モードの 8099 に向ける
#                                        （AWS_ENDPOINT_URL は中継のままなので、STS が呼ばれれば中継に出る）
# endpoint_url は渡さない（env.sh の AWS_ENDPOINT_URL* が効く）。終了コードは FAIL の件数。

import os
import sys

import awswrangler as wr

from common import TYPES_I, TYPES_SQL, TYPES_V, Window, athena_client, failures, report, short, types_key, wait_query

RUN = os.environ.get("RUN_ID", "0")
DB = "default"


def read(sql, **kwargs):
    return wr.athena.read_sql_query(sql, database=DB, ctas_approach=False, **kwargs)


def f_case(name, **kwargs):
    """(2) 出力先を渡さず、GetWorkGroup の OutputLocation を使う経路。"""
    window = Window().start()
    try:
        df = read("SELECT 1 AS n, 'a' AS s", **kwargs)
        rows = [[int(r[0]), str(r[1])] for r in df.astype(object).values.tolist()]
        error = None
    except Exception as exc:  # noqa: BLE001
        rows, error = None, short(exc)
    gw = window.proxy_count(r"target=AmazonAthena\.GetWorkGroup ")
    sts = window.proxy_count(r"target=- ")
    detail = f"rows={rows} error={error} 中継の区間: GetWorkGroup={gw} STS(target=-)={sts} targets={window.proxy_targets()}"
    ok = error is None and rows == [[1, "a"]] and gw >= 1 and sts == 0
    report("PASS" if ok else "FAIL", name, detail)


def regression():
    """(7) awswrangler 側の退行。型の行は int・varchar の値まで、それ以外は例外なしを見る。"""
    try:
        df = read(TYPES_SQL)
        got = types_key(df["i"].tolist(), df["v"].tolist())
        ok = len(df) == 2 and got == (TYPES_I, TYPES_V)
        report("PASS" if ok else "FAIL", "(7) wr 型の行(int・varchar)", f"rows={len(df)} i={got[0]} v={got[1]!r}")
        report("INFO", "(7) wr 型の行(表記)", f"dtypes={dict(df.dtypes.astype(str))} row0={df.astype(object).values.tolist()[0]!r}")
    except Exception as exc:  # noqa: BLE001
        report("FAIL", "(7) wr 型の行(int・varchar)", short(exc))
    table = f"iceberg.default.t111_wr_{RUN}"
    steps = [
        ("PASS", "CREATE TABLE", f"CREATE TABLE {table} (n int, s varchar)"),
        ("INFO", "INSERT", f"INSERT INTO {table} VALUES (1, 'a')"),
        ("PASS", "SHOW TABLES", "SHOW TABLES IN iceberg.default"),
        ("PASS", "DESCRIBE", f"DESCRIBE {table}"),
        ("INFO", "CTAS", f"CREATE TABLE {table}_ctas AS SELECT * FROM {table}"),
        ("PASS", "DROP TABLE", f"DROP TABLE {table}"),
        ("PASS", "DROP TABLE(CTAS)", f"DROP TABLE IF EXISTS {table}_ctas"),
    ]
    for expect, label, sql in steps:
        try:
            df = read(sql)
            report(expect, f"(7) wr {label}", f"例外なし rows={len(df)} columns={list(df.columns)}")
        except Exception as exc:  # noqa: BLE001
            report("FAIL" if expect == "PASS" else "INFO", f"(7) wr {label}", short(exc))


def api_first_row(name, sql, expected):
    """(9) OutputLocation 無しで始めた SELECT を get_query_results で読む（_fetch_api_result の経路）。"""
    window = Window().start()
    try:
        client = athena_client()
        query_id = client.start_query_execution(QueryString=sql, QueryExecutionContext={"Database": DB})["QueryExecutionId"]
        state = wait_query(client, query_id)["State"]
        df = wr.athena.get_query_results(query_id)
        values = [str(v) for v in df.iloc[:, 0].tolist()]
        error = None
    except Exception as exc:  # noqa: BLE001
        state, values, error = "-", [], short(exc)
    gets = window.reads("/athena-results/", apis=("s3.GetObject",))
    head_tail = f"n={len(values)} first={values[:1]} last={values[-1:]}"
    detail = f"state={state} {head_tail} error={error} 区間の S3 GET={len(gets)} 期待 n={len(expected)} first={expected[:1]} last={expected[-1:]}"
    ok = error is None and values == expected and not gets
    report("PASS" if ok else "FAIL", name, detail)


def main(mode):
    if mode == "s3":
        f_case("(2) F1 read_sql_query(ctas_approach=False) 出力先未指定・workgroup 既定")
        f_case("(2) F2 read_sql_query(ctas_approach=False) workgroup=wg111", workgroup="wg111")
        regression()
    elif mode == "none":
        window = Window().start()
        try:
            read("SELECT 1 AS n, 'a' AS s")
            outcome = "例外なし"
        except Exception as exc:  # noqa: BLE001
            outcome = short(exc)
        report("INFO", "(2) F3 none モード(OutputLocation 無し)",
               f"{outcome} 中継の区間: STS(target=-)={window.proxy_count(r'target=- ')} targets={window.proxy_targets()}")
        api_first_row("(9) get_query_results 1500 行", "SELECT x FROM UNNEST(sequence(1, 1500)) AS t(x)",
                      [str(i) for i in range(1, 1501)])
        api_first_row("(9) get_query_results 1 行", "SELECT 'c' AS c", ["c"])
    return failures()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
