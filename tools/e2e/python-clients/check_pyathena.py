#!/usr/bin/env python3
# issue #111: PyAthena 3.36.0 を athena-local（s3 モード、中継 8102 → 8098）に向けて確かめる
# （verify.sh が venv-wr の python で呼ぶ）。
#   preflight  … 既定 Cursor で修飾の無い information_schema を読む。通らなければ残りは SKIP
#                （例: TRINO_CATALOG_MAP が無く、PyAthena の既定 Catalog awsdatacatalog を Trino が知らない）
#   (3)        … 失敗した DDL を PandasCursor で投げ、OperationalError になり、<id>.txt は置かれているのに
#                読みに行かない（trace の区間に .txt* への GET/HEAD が 0 件）こと。既定 Cursor は INFO（対照）
#   (7)        … Cursor と PandasCursor の退行。行数と int・varchar の値は突き合わせ、INSERT・CTAS を
#                PandasCursor で読む反応は INFO
# connect() に endpoint_url は渡さない（渡すと S3 の client も athena-local に向く。filesystem/s3.py:150-155）。
# 終了コードは FAIL の件数。

import os
import sys

from pyathena import connect
from pyathena.error import OperationalError
from pyathena.pandas.cursor import PandasCursor

from common import TYPES_I, TYPES_SQL, TYPES_V, Window, failures, mc_exists, report, short, types_key

RUN = os.environ.get("RUN_ID", "0")
STAGING = "s3://athena-results/py/"


def conn():
    return connect(s3_staging_dir=STAGING, region_name=os.environ["AWS_DEFAULT_REGION"], schema_name="default")


def failed_ddl(label, sql, cursor_class, status_if_ok):
    window = Window().start()
    cursor = conn().cursor(cursor_class) if cursor_class else conn().cursor()
    try:
        cursor.execute(sql)
        error, kind = None, "例外なし"
    except OperationalError as exc:
        error, kind = str(exc), "OperationalError"
    except Exception as exc:  # noqa: BLE001
        error, kind = short(exc), type(exc).__name__
    query_id = cursor.query_id
    reads = window.reads(f"/athena-results/py/{query_id}.txt")  # .txt.metadata も前方一致で含む
    placed = mc_exists(f"athena-results/py/{query_id}.txt")
    detail = (f"{kind} msg={(error or '')[:200]!r} id={query_id} .txt あり={placed} "
              f"区間の .txt* への GET/HEAD={len(reads)} {[(e.get('api'), e.get('path')) for e in reads]}")
    ok = kind == "OperationalError" and "does not exist" in (error or "") and placed and not reads
    report(status_if_ok if ok else ("FAIL" if status_if_ok == "PASS" else "INFO"), f"(3) {label}", detail)


def rows_of(cursor_class):
    cursor = conn().cursor(cursor_class) if cursor_class else conn().cursor()
    cursor.execute(TYPES_SQL)
    if cursor_class:
        df = cursor.as_pandas()
        return len(df), types_key(df["i"].tolist(), df["v"].tolist()), df.astype(object).values.tolist()[0]
    names = [d[0] for d in cursor.description]
    rows = cursor.fetchall()
    cols = list(zip(*rows)) if rows else [[]] * len(names)
    return len(rows), types_key(cols[names.index("i")], cols[names.index("v")]), list(rows[0]) if rows else None


def regression():
    try:
        plain, pandas = rows_of(None), rows_of(PandasCursor)
        ok = plain[0] == pandas[0] == 2 and plain[1] == pandas[1] == (TYPES_I, TYPES_V)
        report("PASS" if ok else "FAIL", "(7) PyAthena 型の行(Cursor と PandasCursor の行数・int・varchar)",
               f"Cursor rows={plain[0]} {plain[1]!r} PandasCursor rows={pandas[0]} {pandas[1]!r}")
        report("INFO", "(7) PyAthena 型の行(表記)", f"Cursor row0={plain[2]!r} PandasCursor row0={pandas[2]!r}")
    except Exception as exc:  # noqa: BLE001
        report("FAIL", "(7) PyAthena 型の行(Cursor と PandasCursor の行数・int・varchar)", short(exc))
    for name, cursor_class in (("Cursor", None), ("PandasCursor", PandasCursor)):
        table = f"iceberg.default.t111_{'pc' if cursor_class is None else 'pd'}_{RUN}"
        read_expect = "PASS" if cursor_class is None else "INFO"
        # Iceberg の DROP TABLE の <id>.txt は改行 1 個（1 バイト、列 0 個）で、本物と同じ形（docs/result-files.md:57-60）。
        # PandasCursor は長さ 0 のときだけ空の DataFrame を返し、1 バイトは pandas の EmptyDataError になるので INFO にする。
        # 空ファイル（0 バイト）を置く Hive の DROP TABLE で「例外なし・0 行」を判定する。
        iceberg_drop = "PASS" if cursor_class is None else "INFO"
        hive = f"hive.default.t111_{'pc' if cursor_class is None else 'pd'}h_{RUN}"
        steps = [
            ("PASS", "CREATE TABLE", f"CREATE TABLE {table} (n int, s varchar)"),
            (read_expect, "INSERT", f"INSERT INTO {table} VALUES (1, 'a')"),
            ("PASS", "SHOW TABLES", "SHOW TABLES IN iceberg.default"),
            ("PASS", "DESCRIBE", f"DESCRIBE {table}"),
            (read_expect, "CTAS", f"CREATE TABLE {table}_ctas AS SELECT * FROM {table}"),
            (iceberg_drop, "DROP TABLE(Iceberg)", f"DROP TABLE {table}"),
            (iceberg_drop, "DROP TABLE(Iceberg の CTAS 先)", f"DROP TABLE IF EXISTS {table}_ctas"),
            ("PASS", "CREATE TABLE(Hive)", f"CREATE TABLE {hive} (n int)"),
            ("PASS", "DROP TABLE(Hive、0 行)", f"DROP TABLE {hive}"),
        ]
        note = "1 バイトの <id>.txt（本物と同じ形、docs/result-files.md:57-60）で pandas の EmptyDataError。athena-local のずれではない"
        for expect, label, sql in steps:
            cursor = conn().cursor(cursor_class) if cursor_class else conn().cursor()
            try:
                cursor.execute(sql)
                rows = len(cursor.as_pandas()) if cursor_class else len(cursor.fetchall())
                status = "FAIL" if "0 行" in label and rows != 0 else expect
                report(status, f"(7) PyAthena {name} {label}", f"例外なし rows={rows}")
            except Exception as exc:  # noqa: BLE001
                detail = f"{short(exc)}（{note}）" if "Iceberg" in label and expect == "INFO" else short(exc)
                report("FAIL" if expect == "PASS" else "INFO", f"(7) PyAthena {name} {label}", detail)


def main():
    # 修飾の無い information_schema は文脈のカタログ（PyAthena の既定 awsdatacatalog → TRINO_CATALOG_MAP で iceberg）で
    # 解決されるので、別名が効いていなければここで止まる（SELECT 1 はカタログを引かないので通ってしまう）。
    try:
        cursor = conn().cursor()
        cursor.execute("SELECT count(*) AS n FROM information_schema.schemata")
        report("PASS", "PyAthena preflight(文脈のカタログ)", f"rows={cursor.fetchall()}")
    except Exception as exc:  # noqa: BLE001
        report("SKIP", "PyAthena の (3)(7)", f"未測定: preflight が通らない（{short(exc)}）")
        return failures()
    for label, sql in (("DROP TABLE", f"DROP TABLE iceberg.default.nope_{RUN}"),
                       ("SHOW COLUMNS", f"SHOW COLUMNS FROM hive.default.nope_{RUN}")):
        failed_ddl(f"PandasCursor 失敗した {label}", sql, PandasCursor, "PASS")
        failed_ddl(f"Cursor 失敗した {label}（対照）", sql, None, "INFO")
    try:
        cursor = conn().cursor(PandasCursor)
        cursor.execute("SELECT 1 AS n")
        report("PASS", "(3) PandasCursor 後続の SELECT 1", f"rows={cursor.as_pandas().values.tolist()}")
    except Exception as exc:  # noqa: BLE001
        report("FAIL", "(3) PandasCursor 後続の SELECT 1", short(exc))
    regression()
    return failures()


if __name__ == "__main__":
    sys.exit(main())
