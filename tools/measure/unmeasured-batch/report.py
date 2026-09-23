#!/usr/bin/env python3
"""issue #113: summary.tsv を実名マスク済みの summary.txt にまとめる。

tools/measure/unmeasured-batch/run.sh が最後に呼ぶ。単独では意味を持たない
（summary.tsv・cleanup-hints.txt・<item>/*.sql が無いと空の要約しか作れない）。

使い方: python3 report.py <RUN_DIR> <TARGET>

マスクする実名は環境変数から読む（run.sh が export 済み）: OUTPUT・DB・WORKGROUP2・OUTPUT_BUCKET。
12 桁の数列（アカウント ID らしきもの）も伏せる。
"""
import csv
import datetime
import glob
import os
import re
import sys


def mask(text, ):
    if not text:
        return text
    for key in ("OUTPUT", "DB", "WORKGROUP2", "OUTPUT_BUCKET"):
        value = os.environ.get(key)
        if value:
            text = text.replace(value, "<%s>" % key)
    return re.sub(r"\b\d{12}\b", "<ACCOUNT_ID>", text)


def load_rows(run_dir):
    path = os.path.join(run_dir, "summary.tsv")
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def count_ddl(run_dir):
    creates = drops = 0
    for sql_path in glob.glob(os.path.join(run_dir, "*", "*.sql")):
        with open(sql_path, encoding="utf-8", errors="replace") as f:
            text = f.read().strip().upper()
        if text.startswith("CREATE"):
            creates += 1
        elif text.startswith("DROP"):
            drops += 1
    return creates, drops


def cleanup_locations(run_dir):
    path = os.path.join(run_dir, "cleanup-hints.txt")
    if not os.path.exists(path):
        return []
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = mask(line.strip())
            if line:
                out.append(line)
    return out


def render_item_rows(rows, item, kind, formatter):
    return [formatter(r) for r in rows if r["item_id"] == item and r["kind"] == kind]


def main():
    run_dir, target = sys.argv[1], sys.argv[2]
    rows = load_rows(run_dir)

    stmt_rows = [r for r in rows if r["kind"] == "stmt"]
    expect_rows = [r for r in rows if r["kind"] == "expect"]
    skip_rows = [r for r in rows if r["kind"] == "skip"]

    started = len(stmt_rows)
    succeeded = sum(1 for r in stmt_rows if r["state"] == "SUCCEEDED")
    failed = sum(1 for r in stmt_rows if r["state"] in ("FAILED", "CANCELLED", "TIMEOUT"))
    start_failed = sum(1 for r in stmt_rows if r["state"] == "START_FAILED")
    creates, drops = count_ddl(run_dir)

    now = datetime.datetime.now()
    deadline = now + datetime.timedelta(minutes=90)

    lines = [
        "# issue #113 未実測バッチ フェーズ1: 実測結果の要約（実名はマスク済み）",
        "# TARGET: %s" % target,
        "# 開始時刻: %s" % now.isoformat(timespec="seconds"),
        "# 開始+90分（資格情報はこれより長く有効なものを使うこと）: %s" % deadline.isoformat(timespec="seconds"),
        "# StartQueryExecution を呼んだ回数: %d"
        " (SUCCEEDED=%d FAILED/CANCELLED/TIMEOUT=%d 開始自体が失敗=%d)"
        % (started, succeeded, failed, start_failed),
        "# DDL の内訳（各 .sql の先頭語から集計。目安）: CREATE=%d DROP=%d" % (creates, drops),
        "# skip した項目/文の数: %d" % len(skip_rows),
    ]
    locs = cleanup_locations(run_dir)
    if locs:
        lines.append("# 作った S3 の LOCATION（Hive 外部テーブル。DROP では消えない。cleanup-hints.txt も見る）:")
        for loc in locs:
            lines.append("#   %s" % loc)
    lines.append("")

    lines.append("## 項目ごとの結果")
    items = sorted(set(r["item_id"] for r in rows))
    for item in items:
        lines.append("### %s" % item)
        stmt_lines = render_item_rows(
            rows, item, "stmt",
            lambda r: "- %s: state=%s %s/%s loc=%s body=%sB(%s) metadata=%sB(%s) note=%s" % (
                r["label"], r["state"], r["statement_type"], r["substatement_type"],
                r["loc_shape"], r["body_bytes"], r["body_ct"], r["metadata_bytes"], r["metadata_ct"],
                mask(r["note"]),
            ),
        )
        expect_lines = render_item_rows(
            rows, item, "expect",
            lambda r: "- [expect] %s: expected=%s actual=%s -> %s (%s)" % (
                r["label"], r["expected"], r["actual"],
                "期待どおり" if r["match"] == "yes" else "期待と違う",
                mask(r["note"]),
            ),
        )
        skip_lines = render_item_rows(
            rows, item, "skip",
            lambda r: "- [skip] %s: %s" % (r["label"], mask(r["note"])),
        )
        body = stmt_lines + expect_lines + skip_lines
        lines.extend(body if body else ["- (行なし)"])
    lines.append("")

    mismatches = [r for r in expect_rows if r["match"] != "yes"]
    lines.append("## 宣言した期待との食い違い")
    if mismatches:
        for r in mismatches:
            lines.append("- %s/%s: expected=%s actual=%s (%s)" % (
                r["item_id"], r["label"], r["expected"], r["actual"], mask(r["note"]),
            ))
    else:
        lines.append("- 無し")

    out_path = os.path.join(run_dir, "summary.txt")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(out_path)


if __name__ == "__main__":
    main()
