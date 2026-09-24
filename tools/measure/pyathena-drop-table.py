"""issue #119: 本物の Athena + PyAthena 3.36.0 の PandasCursor で DROP TABLE を読むと何が起きるかを測る。

athena-local 相手では、Iceberg の DROP TABLE の結果ファイル <id>.txt（改行 1 バイト、列 0 個）を PandasCursor が
pandas の read_csv に渡し、EmptyDataError → OperationalError("No columns to parse from file") になった（#111）。
Hive の DROP TABLE（0 バイト）は、PyAthena が長さ 0 のときだけ空の DataFrame を返すので読める。
本物でも同じになるかを、同じラウンドに対照を入れて確かめる。

項目（すべて本物の Athena。1 ラウンドで測り切る）:
  preflight     PyAthena の Cursor で SELECT 1（測る対象のクライアント自身で疎通を確かめる）
  exists        SHOW TABLES IN <db> 'athena_local_probe_119*'。1 件でもあれば何も作らずに止まる
  prep-*        CTAS で 3 テーブルを作る（Iceberg 2 本、Hive 1 本）
  fmt-*         SHOW CREATE TABLE で形式を裏取りする（DROP の前にしかできない）
  drop-ice-pandas   焦点: Iceberg を PandasCursor で DROP TABLE
  drop-ice-cursor   対照 1: 同じ形式を素の Cursor で DROP TABLE（ファイルを読まない経路）
  drop-hive-pandas  対照 2: Hive を PandasCursor で DROP TABLE（0 バイトのはず）
各 DROP について、例外（クラスと文言）、GetQueryExecution（StatementType／SubstatementType／OutputLocation）、
結果ファイルの大きさ・Content-Type・中身（16 進）、GetQueryResults の ColumnInfo の数を残す。

本物に対する操作（DDL を含む）:
  - クエリ: SELECT 1、SHOW TABLES、CTAS 3 本、SHOW CREATE TABLE 3 本、DROP TABLE 3 本（失敗時は後始末の DROP TABLE IF EXISTS が最大 3 本）
  - 作るもの: <db>.athena_local_probe_119_ice_pandas / _ice_cursor（Iceberg、is_external=false なので DROP でデータも消える）、
    <db>.athena_local_probe_119_hive（Hive、データは <OUTPUT>tables-probe-119-hive/ の下。DROP の後にこの接頭辞だけ S3 から消す）
  - 課金: 1 行のテーブル 3 本の作成と削除。スキャン量はどのクエリも数 KB 以下
  - 実測値は工場出荷時の既定とは限らない（ワークグループの設定などで変わりうる）

使い方（toolbox の中。venv は tools/e2e/python-clients/setup-venvs.sh が作る venv-wr を使う）:
  AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... tools/dev.sh OUTPUT=s3://bucket/prefix/ DB=your_db \
    .toolbox/home/.cache/athena-local-111/venv-wr/bin/python tools/measure/pyathena-drop-table.py
  （~/.aws/credentials でもよい）

環境変数: OUTPUT（必須。s3://bucket/prefix/）、DB（必須。実在するもの）、REGION（既定 ap-northeast-1）、WORK_GROUP（既定 primary）、
OUT_DIR（既定 ${DEV_HOST_HOME:-$HOME}/athena-pyathena-drop-measurements）、RETRY_MAX（既定 4）、RETRY_DELAY（既定 5 秒）。
出力は OUT_DIR/run-<日時>/ に項目ごとの JSON と summary.txt（アカウント ID・バケット・DB 名はマスク済み）。
"""

import datetime
import json
import os
import re
import sys
import time
import traceback

OUTPUT = os.environ.get("OUTPUT", "")
DB = os.environ.get("DB", "")
REGION = os.environ.get("REGION", "ap-northeast-1")
WORK_GROUP = os.environ.get("WORK_GROUP", "primary")
RETRY_MAX = int(os.environ.get("RETRY_MAX", "4"))
RETRY_DELAY = int(os.environ.get("RETRY_DELAY", "5"))
OUT_ROOT = os.environ.get(
    "OUT_DIR",
    os.path.join(os.environ.get("DEV_HOST_HOME", os.path.expanduser("~")), "athena-pyathena-drop-measurements"),
)
RUN_DIR = os.path.join(OUT_ROOT, "run-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))

PREFIX = "athena_local_probe_119"
T_ICE_PANDAS = f"{PREFIX}_ice_pandas"
T_ICE_CURSOR = f"{PREFIX}_ice_cursor"
T_HIVE = f"{PREFIX}_hive"
HIVE_DATA = "tables-probe-119-hive/"

results = []  # (項目, 状態, 詳細)
account_ids = set()


def record(item, status, detail):
    results.append((item, status, detail))
    print(f"{status:8} {item:18} {detail}", flush=True)


def save(item, data):
    with open(os.path.join(RUN_DIR, f"{item}.json"), "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2, default=str)


def mask(text):
    text = str(text)
    bucket = OUTPUT[5:].split("/", 1)[0] if OUTPUT.startswith("s3://") else ""
    if bucket:
        text = text.replace(bucket, "<BUCKET>")
    if DB:
        text = re.sub(re.escape(DB), "<DB>", text)
    return re.sub(r"\b\d{12}\b", "<ACCOUNT_ID>", text)


def retry(label, fn):
    """名前解決・接続の一時的な失敗だけを再試行する。試行回数を返す。"""
    for attempt in range(1, RETRY_MAX + 1):
        try:
            return fn(), attempt
        except Exception as e:  # noqa: BLE001
            text = f"{type(e).__name__}: {e}"
            transient = re.search(r"EndpointConnectionError|ConnectTimeout|Name or service not known|Temporary failure", text)
            if not transient or attempt == RETRY_MAX:
                raise
            print(f"[retry] {label} {attempt}/{RETRY_MAX}: {text}", flush=True)
            time.sleep(RETRY_DELAY)


def describe_execution(athena, s3, query_id):
    """GetQueryExecution・結果ファイル・GetQueryResults の ColumnInfo をまとめて取る。"""
    out = {"query_id": query_id}
    qe = athena.get_query_execution(QueryExecutionId=query_id)["QueryExecution"]
    out["StatementType"] = qe.get("StatementType")
    out["SubstatementType"] = qe.get("SubstatementType")
    out["State"] = qe["Status"]["State"]
    location = qe.get("ResultConfiguration", {}).get("OutputLocation")
    out["OutputLocation"] = location
    if location:
        bucket, key = location[5:].split("/", 1)
        try:
            obj = s3.get_object(Bucket=bucket, Key=key)
            body = obj["Body"].read()
            out["file"] = {"size": len(body), "content_type": obj.get("ContentType"), "hex": body[:64].hex()}
        except Exception as e:  # noqa: BLE001 無いことの証拠として残す
            out["file"] = {"error": f"{type(e).__name__}: {e}"}
    try:
        res = athena.get_query_results(QueryExecutionId=query_id)
        out["ColumnInfo_count"] = len(res["ResultSet"]["ResultSetMetadata"].get("ColumnInfo", []))
        out["Rows_count"] = len(res["ResultSet"].get("Rows", []))
    except Exception as e:  # noqa: BLE001
        out["GetQueryResults_error"] = f"{type(e).__name__}: {e}"
    return out


def run_drop(item, conn, cursor_class, table, athena, s3):
    cursor = conn.cursor(cursor_class) if cursor_class else conn.cursor()
    data = {"sql": f"DROP TABLE {DB}.{table}", "cursor": type(cursor).__name__}
    try:
        cursor.execute(data["sql"])
        data["exception"] = None
        if hasattr(cursor, "as_pandas"):
            df = cursor.as_pandas()
            data["dataframe_shape"] = list(df.shape)
    except Exception as e:  # noqa: BLE001 例外そのものが測る対象
        data["exception"] = {"class": f"{type(e).__module__}.{type(e).__name__}", "message": str(e)}
        cause = e.__cause__
        if cause is not None:
            data["exception"]["cause"] = f"{type(cause).__module__}.{type(cause).__name__}: {cause}"
    if cursor.query_id:
        data.update(describe_execution(athena, s3, cursor.query_id))
    save(item, data)
    exc = data["exception"]
    file = data.get("file", {})
    detail = (
        f"例外={'無し' if exc is None else exc['class'] + ': ' + exc['message']}"
        f"{' / 原因=' + exc['cause'] if exc and exc.get('cause') else ''}"
        f" / {data.get('StatementType')}/{data.get('SubstatementType')}"
        f" / 本体 {file.get('size', file.get('error'))}B {file.get('content_type', '')} hex={file.get('hex', '')}"
        f" / ColumnInfo {data.get('ColumnInfo_count')} 個"
    )
    record(item, "INFO", mask(detail))
    return data


def main():
    if not OUTPUT.startswith("s3://") or not OUTPUT.endswith("/") or not DB:
        print("OUTPUT（s3://bucket/prefix/）と DB を指定する", file=sys.stderr)
        return 2
    os.makedirs(RUN_DIR, exist_ok=True)

    try:
        import boto3
        import pyathena
        from pyathena import connect
        from pyathena.pandas.cursor import PandasCursor
    except Exception as e:  # noqa: BLE001 実行系の実能力で判定する
        print(f"PyAthena・pandas・boto3 が読み込めない（{e}）。tools/e2e/python-clients/setup-venvs.sh を先に流す", file=sys.stderr)
        return 2
    import pandas

    record("versions", "INFO", f"PyAthena {pyathena.__version__} / pandas {pandas.__version__} / boto3 {boto3.__version__}")
    athena = boto3.client("athena", region_name=REGION)
    s3 = boto3.client("s3", region_name=REGION)

    def open_conn():
        return connect(s3_staging_dir=OUTPUT, region_name=REGION, schema_name=DB, work_group=WORK_GROUP)

    # preflight: 測る対象のクライアント（PyAthena）自身で最小の 1 本を通す。
    try:
        conn, attempts = retry("preflight", open_conn)
        cur = conn.cursor()
        (value,) = retry("preflight", lambda: cur.execute("SELECT 1").fetchone())[0]
        record("preflight", "PASS", f"PyAthena の Cursor で SELECT 1 = {value}（接続 {attempts} 回目）")
    except Exception as e:  # noqa: BLE001
        record("preflight", "FAIL", mask(f"{type(e).__name__}: {e}"))
        save("preflight", {"traceback": traceback.format_exc()})
        return 1

    # 同名のテーブルがあれば壊さないよう、何も作らずに止まる。
    rows = conn.cursor().execute(f"SHOW TABLES IN {DB} '{PREFIX}*'").fetchall()
    if rows:
        record("exists", "FAIL", f"同名のテーブルが既にある: {[r[0] for r in rows]}。何も作らずに止まる")
        return 1
    record("exists", "PASS", "athena_local_probe_119* のテーブルは無い")

    created = []
    try:
        preps = [
            ("prep-ice-pandas", T_ICE_PANDAS, f"CREATE TABLE {DB}.{T_ICE_PANDAS} WITH (table_type = 'ICEBERG', location = '{OUTPUT}tables-probe-119-ice-pandas/', is_external = false) AS SELECT 1 AS n"),
            ("prep-ice-cursor", T_ICE_CURSOR, f"CREATE TABLE {DB}.{T_ICE_CURSOR} WITH (table_type = 'ICEBERG', location = '{OUTPUT}tables-probe-119-ice-cursor/', is_external = false) AS SELECT 1 AS n"),
            ("prep-hive", T_HIVE, f"CREATE TABLE {DB}.{T_HIVE} WITH (external_location = '{OUTPUT}{HIVE_DATA}') AS SELECT 1 AS n"),
        ]
        for item, table, sql in preps:
            try:
                conn.cursor().execute(sql)
                created.append(table)
                record(item, "PASS", "作成済み")
            except Exception as e:  # noqa: BLE001
                record(item, "FAIL", mask(f"{type(e).__name__}: {e}"))

        # 形式の裏取り（DROP の前にしかできない）。
        formats = {}
        for table in created:
            ddl = "\n".join(r[0] for r in conn.cursor().execute(f"SHOW CREATE TABLE {DB}.{table}").fetchall())
            formats[table] = "iceberg" if re.search(r"'table_type'\s*=\s*'iceberg'", ddl, re.I) else "hive"
            save(f"fmt-{table}", {"ddl": ddl})
            record(f"fmt-{table[len(PREFIX) + 1:]}", "INFO", f"形式 {formats[table]}")

        cases = [
            ("drop-ice-pandas", PandasCursor, T_ICE_PANDAS),
            ("drop-ice-cursor", None, T_ICE_CURSOR),
            ("drop-hive-pandas", PandasCursor, T_HIVE),
        ]
        for item, cursor_class, table in cases:
            if table not in created:
                record(item, "SKIP", "準備の CTAS が失敗したので未測定")
                continue
            run_drop(item, conn, cursor_class, table, athena, s3)
    finally:
        # 後始末: DROP が例外で終わってもテーブルは消えているはずだが、念のため IF EXISTS を投げる。
        for table in created:
            try:
                conn.cursor().execute(f"DROP TABLE IF EXISTS {DB}.{table}")
            except Exception as e:  # noqa: BLE001
                record("cleanup", "FAIL", mask(f"{table}: {type(e).__name__}: {e}"))
        # Hive のテーブルのデータは DROP で残るので、このスクリプトが指定した接頭辞だけを消す。
        bucket, prefix = OUTPUT[5:].split("/", 1)
        keys = [o["Key"] for o in s3.list_objects_v2(Bucket=bucket, Prefix=prefix + HIVE_DATA).get("Contents", [])]
        for key in keys:
            s3.delete_object(Bucket=bucket, Key=key)
        record("cleanup", "INFO", f"DROP TABLE IF EXISTS {len(created)} 本、{HIVE_DATA} の下のオブジェクト {len(keys)} 個を削除")
    return 0


if __name__ == "__main__":
    status = 1
    try:
        status = main()
    finally:
        if os.path.isdir(RUN_DIR):
            with open(os.path.join(RUN_DIR, "summary.txt"), "w") as f:
                f.write("issue #119: 本物の Athena + PyAthena の PandasCursor で DROP TABLE（実名はマスク済み）\n")
                for item, st, detail in results:
                    f.write(mask(f"{st:8} {item:18} {detail}") + "\n")
            print(f"summary: {os.path.join(RUN_DIR, 'summary.txt')}")
    sys.exit(status)
