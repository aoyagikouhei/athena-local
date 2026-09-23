#!/usr/bin/env python3
"""issue #111 (5): 保持期限（ATHENA_LOCAL_RETENTION_SECONDS）で実行情報を捨てると RSS が頭打ちになるかを測る。

負荷モード: 逐次 1 本で StartQueryExecution → GetQueryExecution を 0.1 秒間隔でポーリング →
SUCCEEDED なら GetQueryResults を 1 ページ、を DURATION 秒繰り返す。SAMPLE 秒ごとに
/proc/<pid>/status の VmRSS と VmHWM（KiB）と完了件数を CSV（t,rss_kib,hwm_kib,done）に書き、
終了時に最初のクエリの ID へ GetQueryExecution を 1 回投げた結果をサマリ JSON（<csv>.json）に残す。
  load.py --base http://127.0.0.1:8101 --pid <pid> --retention 1 --csv out-1.csv

判定モード（FAIL の件数が終了コード。閾値は環境変数 JUDGE_*）: load.py --judge out-3600.csv out-1.csv
標準ライブラリだけを使う。本物の AWS には出ない（--base の手元の athena-local だけを叩く）。
"""
import argparse
import csv
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid

SQL = "SELECT x, lpad(cast(x AS varchar), 1000, 'x') AS pad FROM UNNEST(sequence(1, {rows})) AS t(x)"
MIB = 1024


def call(base, operation, body):
    request = urllib.request.Request(
        base + "/",
        data=json.dumps(body).encode(),
        headers={"X-Amz-Target": f"AmazonAthena.{operation}", "Content-Type": "application/x-amz-json-1.1"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        try:
            return error.code, json.loads(error.read() or b"{}")
        except ValueError:
            return error.code, {}
    except (urllib.error.URLError, OSError, ValueError) as error:
        # athena-local が落ちた（対照側の OOM など）・応答が途切れた・JSON でない応答。
        # 呼び出し側が run_one の失敗として数えられるよう、状態コード無しで返す。
        return None, {"__type": type(error).__name__}


def read_status(pid):
    """(VmRSS, VmHWM) を KiB で返す。読めなければ None。"""
    try:
        with open(f"/proc/{pid}/status") as f:
            values = dict(line.split(":", 1) for line in f if ":" in line)
        return int(values["VmRSS"].split()[0]), int(values["VmHWM"].split()[0])
    except (OSError, KeyError, ValueError):
        return None


def run_one(base, rows):
    """1 件流して (クエリ ID, 最終状態) を返す。"""
    status, body = call(base, "StartQueryExecution", {"QueryString": SQL.format(rows=rows), "ClientRequestToken": str(uuid.uuid4())})
    if status != 200:
        return None, f"start {status} {body.get('__type')}"
    query_id = body["QueryExecutionId"]
    deadline = time.time() + 60
    while time.time() < deadline:
        status, body = call(base, "GetQueryExecution", {"QueryExecutionId": query_id})
        if status != 200:
            return query_id, f"poll {status} {body.get('AthenaErrorCode') or body.get('__type')}"
        state = body.get("QueryExecution", {}).get("Status", {}).get("State")
        if state in ("SUCCEEDED", "FAILED", "CANCELLED"):
            if state == "SUCCEEDED":
                call(base, "GetQueryResults", {"QueryExecutionId": query_id})
            return query_id, state
        time.sleep(0.1)
    return query_id, "TIMEOUT"


def load(args):
    if read_status(args.pid) is None:
        write_json(args.csv, {"retention": args.retention, "proc_ok": False, "done": 0})
        print(f"SKIP /proc/{args.pid}/status を読めない（RSS を測れないので未測定）")
        return 2
    counters = {"done": 0, "failed": 0}
    stop = threading.Event()
    started = time.time()

    def sample():
        with open(args.csv, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["t", "rss_kib", "hwm_kib", "done"])
            while True:
                values = read_status(args.pid) or ("", "")
                writer.writerow([round(time.time() - started, 1), *values, counters["done"]])
                f.flush()
                if stop.is_set():
                    return  # 止めた直後の 1 行を最後の標本にする
                stop.wait(args.sample)

    # daemon にして、負荷側が例外で抜けても標本のスレッドがプロセスを生かし続けないようにする（軽量レビューの指摘）。
    sampler = threading.Thread(target=sample, daemon=True)
    sampler.start()
    first_id, reasons = None, {}
    try:
        while time.time() - started < args.duration:
            query_id, state = run_one(args.base, args.rows)
            first_id = first_id or query_id
            if state == "SUCCEEDED":
                counters["done"] += 1
            else:
                counters["failed"] += 1
                reasons[state] = reasons.get(state, 0) + 1
                if counters["done"] == 0 or state.startswith("start None"):
                    break  # 最初の 1 件が通らない、または athena-local に届かなくなったら負荷を止める
    finally:
        stop.set()
        sampler.join()
    status, body = call(args.base, "GetQueryExecution", {"QueryExecutionId": first_id}) if first_id else (None, {})
    summary = {
        "retention": args.retention, "proc_ok": True, "elapsed": round(time.time() - started, 1),
        "done": counters["done"], "failed": counters["failed"],
        "failed_reasons": reasons, "first_id": first_id, "first_id_status": status,
        "first_id_code": body.get("AthenaErrorCode") or body.get("__type"),
    }
    write_json(args.csv, summary)
    print(json.dumps(summary, ensure_ascii=False))
    return 0 if counters["done"] > 0 else 1


def write_json(csv_path, value):
    with open(csv_path + ".json", "w") as f:
        json.dump(value, f, ensure_ascii=False, indent=2)


def growth(csv_path, warmup):
    """暖機後・中間・最終の VmRSS（KiB）と前半・後半・全体の伸び、最終の VmHWM を返す。"""
    with open(csv_path) as f:
        samples = [(float(r["t"]), int(r["rss_kib"]), int(r["hwm_kib"])) for r in csv.DictReader(f) if r["rss_kib"]]
    after = [s for s in samples if s[0] >= warmup]
    if len(after) < 3:
        return None
    warm, final = after[0], after[-1]
    mid = next(s for s in after if s[0] >= warm[0] + (final[0] - warm[0]) / 2)
    return {"warm": warm[1], "mid": mid[1], "final": final[1], "hwm": final[2],
            "first": mid[1] - warm[1], "second": final[1] - mid[1], "total": final[1] - warm[1]}


def judge(control_csv, test_csv, warmup):
    t = {k: float(os.environ.get(k, d)) for k, d in [
        ("JUDGE_GROWTH_MIN_MIB", 100), ("JUDGE_SECOND_HALF_MIN_RATIO", 0.5), ("JUDGE_GROWTH_MAX_RATIO", 0.25),
        ("JUDGE_FLAT_MAX_MIB", 16), ("JUDGE_SECOND_HALF_MAX_RATIO", 0.5), ("JUDGE_DONE_RATIO_MIN", 0.7), ("JUDGE_DONE_RATIO_MAX", 1.3)]}
    hi, lo = (json.load(open(p + ".json")) for p in (control_csv, test_csv))
    results = []
    for side, s in (("high", hi), ("low", lo)):
        print(f"INFO {side}: retention={s['retention']}s done={s['done']} failed={s.get('failed')} "
              f"first_id_status={s.get('first_id_status')} code={s.get('first_id_code')}")
    if not (hi["proc_ok"] and lo["proc_ok"]):
        return report([("SKIP", "(a)-(e)", "/proc を読めず負荷を流していない（未測定）")])
    # (d) は負荷の量によらないので、対照が成り立たなくても判定する。対照側の 200 は、経過が保持期限未満のときだけ
    # 求める（DURATION が RETENTION_HIGH 以上だと対照側の最初の ID も正しく捨てられている。最終パスの指摘）。
    hi_expired = hi.get("elapsed") is None or hi.get("elapsed", 0) >= hi.get("retention", 0)
    ok_d_low = lo.get("first_id_status") == 400 and lo.get("first_id_code") == "QUERY_EXECUTION_NOT_FOUND"
    ok_d_high = True if hi_expired else hi.get("first_id_status") == 200
    high_note = "対照側は経過が保持期限以上なので判定しない" if hi_expired else "期待 200"
    results.append(("PASS" if ok_d_low and ok_d_high else "FAIL", "(d)",
                    f"最初の ID: low={lo.get('first_id_status')}（期待 400） high={hi.get('first_id_status')}（{high_note}）"))
    ratio = lo["done"] / hi["done"] if hi["done"] else 0.0
    ok_e = t["JUDGE_DONE_RATIO_MIN"] <= ratio <= t["JUDGE_DONE_RATIO_MAX"]
    results.append(("PASS" if ok_e else "SKIP", "(e)", f"完了数の比 low/high={ratio:.2f}（{t['JUDGE_DONE_RATIO_MIN']}〜{t['JUDGE_DONE_RATIO_MAX']}）"))
    g_hi, g_lo = growth(control_csv, warmup), growth(test_csv, warmup)
    if g_hi is None or g_lo is None:
        results.append(("SKIP", "(a)(b)(c)", f"暖機 {warmup} 秒のあとの標本が 3 つ未満（未測定）"))
        return report(results)
    for side, g in (("high", g_hi), ("low", g_lo)):
        print(f"INFO {side}: rss warm={g['warm'] / MIB:.1f} mid={g['mid'] / MIB:.1f} final={g['final'] / MIB:.1f} "
              f"hwm={g['hwm'] / MIB:.1f} MiB / growth first={g['first'] / MIB:.1f} second={g['second'] / MIB:.1f} total={g['total'] / MIB:.1f} MiB")
    ok_a = g_hi["total"] >= t["JUDGE_GROWTH_MIN_MIB"] * MIB and g_hi["second"] >= t["JUDGE_SECOND_HALF_MIN_RATIO"] * g_hi["first"]
    results.append(("PASS" if ok_a else "SKIP", "(a)", f"対照の伸び {g_hi['total'] / MIB:.1f} MiB（≥{t['JUDGE_GROWTH_MIN_MIB']}）、"
                    f"後半/前半 {g_hi['second'] / MIB:.1f}/{g_hi['first'] / MIB:.1f} MiB（≥{t['JUDGE_SECOND_HALF_MIN_RATIO']} 倍）"))
    established = ok_a and ok_e
    ok_b = g_lo["total"] <= t["JUDGE_GROWTH_MAX_RATIO"] * g_hi["total"]
    # 「後半 < 前半」だけだと、対照側（伸び続ける）でも処理のペースが落ちて後半が減り、通ってしまう（red で観測）。
    # 後半が前半の JUDGE_SECOND_HALF_MAX_RATIO 倍未満か、雑音の下限 JUDGE_FLAT_MAX_MIB 以下なら頭打ちとみなす。
    ok_c = g_lo["second"] < t["JUDGE_SECOND_HALF_MAX_RATIO"] * g_lo["first"] or g_lo["second"] <= t["JUDGE_FLAT_MAX_MIB"] * MIB
    word = (lambda ok: "PASS" if ok else "FAIL") if established else (lambda ok: "INFO")
    results.append((word(ok_b), "(b)", f"low の伸び {g_lo['total'] / MIB:.1f} MiB ≤ high の {t['JUDGE_GROWTH_MAX_RATIO']} 倍 {t['JUDGE_GROWTH_MAX_RATIO'] * g_hi['total'] / MIB:.1f} MiB"))
    results.append((word(ok_c), "(c)", f"low の後半 {g_lo['second'] / MIB:.1f} MiB < 前半 {g_lo['first'] / MIB:.1f} MiB の {t['JUDGE_SECOND_HALF_MAX_RATIO']} 倍 または ≤{t['JUDGE_FLAT_MAX_MIB']} MiB"))
    if not established:
        results.append(("SKIP", "memory", "対照不成立（(a) か (e) を満たさない。(b)(c) は判定しない）"))
    return report(results)


def report(results):
    for word, label, detail in results:
        print(f"{word} {label} {detail}")
    words = [w for w, _, _ in results]
    overall = "FAIL" if "FAIL" in words else "SKIP" if "SKIP" in words else "PASS"
    print(f"{overall} retention-memory（FAIL {words.count('FAIL')} 件）")
    return words.count("FAIL")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--judge", nargs=2, metavar=("CONTROL_CSV", "TEST_CSV"))
    parser.add_argument("--base", default="http://127.0.0.1:8101")
    parser.add_argument("--pid", type=int)
    parser.add_argument("--retention", type=int)
    parser.add_argument("--csv")
    parser.add_argument("--duration", type=float, default=float(os.environ.get("DURATION", 240)))
    parser.add_argument("--warmup", type=float, default=float(os.environ.get("WARMUP", 20)))
    parser.add_argument("--sample", type=float, default=5)
    parser.add_argument("--rows", type=int, default=int(os.environ.get("ROWS", 2000)))
    args = parser.parse_args()
    if args.judge:
        return judge(args.judge[0], args.judge[1], args.warmup)
    return load(args)


if __name__ == "__main__":
    sys.exit(main())
