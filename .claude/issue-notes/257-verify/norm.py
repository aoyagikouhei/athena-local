"""#257 の 5: 移した範囲(ALTER の部分)を、宣言単位・順不同の多重集合として着手前と比べる。

3 組のファイルペアを見る:
  (a) src/operation/comment_parse_error.rs           <-> 同ファイル + comment_parse_error/alter.rs
  (b) src/operation/comment_parse_error/tests.rs     <-> 同ファイル + comment_parse_error/alter/tests.rs
  (c) tests/comment_parse_error.rs                   <-> 同ファイル + tests/comment_parse_error_alter.rs

各ファイルを「use 文・mod 宣言・モジュール doc(//!)・空行」を除いた上で空行区切りの段落(宣言単位)に割り、
各段落から空白を全部落として正規化する(可視性の修飾 pub/pub(super)/pub(in ...) も落とすので、
可視性の付与はここでは差にならない)。before 側の多重集合と after 側の多重集合を比べ、
複製したヘルパ(一致台帳。ALLOWED_DUPLICATES)だけ before+1 を許す。
"""

import re
import subprocess
import sys
from collections import Counter

BASE = sys.argv[1]

# (label, path, [(0 個以上の追加先パス)])
FILE_GROUPS = [
    (
        "comment_parse_error.rs",
        "src/operation/comment_parse_error.rs",
        ["src/operation/comment_parse_error/alter.rs"],
    ),
    (
        "comment_parse_error/tests.rs",
        "src/operation/comment_parse_error/tests.rs",
        ["src/operation/comment_parse_error/alter/tests.rs"],
    ),
    (
        "tests/comment_parse_error.rs",
        "tests/comment_parse_error.rs",
        ["tests/comment_parse_error_alter.rs"],
    ),
]

# 複製を許すヘルパ・枠(canon した文字列に部分一致。前に写しの doc コメントが付いていてもよい)。
# after 側で before よりちょうど 1 つ多いことだけ許す。
ALLOWED_DUPLICATES = [
    "fnparse_exception(",
    "fnselect_response(",
    "fnprobe_sql(",
    "fnprobe_response(",
    "fnprobe_response_missing(",
    "constDEFAULT_CATALOG",
    "constDEFAULT_SCHEMA",
    "#[cfg(test)]",  # テストモジュールの枠(mod tests; 自体は mod 行として除外済み)
]

USE_RE = re.compile(r"^\s*(pub(\([^)]*\))?\s+)?use\s.*;\s*$")
MOD_RE = re.compile(r"^\s*(pub(\([^)]*\))?\s+)?mod\s+\w+;\s*$")
MODDOC_RE = re.compile(r"^\s*//!")


def git_show(path):
    r = subprocess.run(
        ["git", "show", f"{BASE}:{path}"], capture_output=True, text=True
    )
    return r.stdout if r.returncode == 0 else None


def read_file(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return None


def paragraphs(text):
    if text is None:
        return []
    kept = []
    for line in text.split("\n"):
        if MODDOC_RE.match(line) or USE_RE.match(line) or MOD_RE.match(line):
            continue
        kept.append(line)
    joined = "\n".join(kept)
    paras = re.split(r"\n\s*\n", joined)
    return [p for p in paras if p.strip()]


def canon(paragraph):
    # pub / pub(super) / pub(crate) / pub(in ...) の可視性修飾は差にしない
    p = re.sub(r"\bpub(\([^)]*\))?\s+", "", paragraph)
    return re.sub(r"\s+", "", p)


def counter_for(texts):
    c = Counter()
    for text in texts:
        for p in paragraphs(text):
            c[canon(p)] += 1
    return c


def reconcile_duplicates(before, after):
    """ALLOWED_DUPLICATES に一致する宣言だけ after が before+1 であることを確かめ、
    一致すれば before 側を +1 して以降の比較で差にならないようにする。"""
    ng = []
    matched = []
    for key in list(after.keys()):
        if any(prefix in key for prefix in ALLOWED_DUPLICATES):
            b = before.get(key, 0)
            a = after[key]
            if a == b + 1:
                before[key] = a
                matched.append((key[:40], b, a))
            elif a != b:
                ng.append((key[:60], b, a))
    return matched, ng


ng_total = 0
for label, main_path, extra_paths in FILE_GROUPS:
    before_text = git_show(main_path)

    after_texts = [read_file(main_path)] + [read_file(p) for p in extra_paths]

    before_counter = counter_for([before_text])
    after_counter = counter_for(after_texts)

    matched, dup_ng = reconcile_duplicates(before_counter, after_counter)

    if before_counter == after_counter:
        extra = f"(複製 {len(matched)} 件: {', '.join(m[0] for m in matched)})" if matched else ""
        print(f"ok 5 {label} 宣言単位で一致 {extra}")
    else:
        print(f"NG 5 {label} 宣言が違う")
        ng_total = 1
        missing = before_counter - after_counter
        added = after_counter - before_counter
        for key, cnt in missing.items():
            print(f"    - 消えた({cnt}): {key[:100]}")
        for key, cnt in added.items():
            print(f"    + 増えた({cnt}): {key[:100]}")
    for key, b, a in dup_ng:
        print(f"NG 5 {label} 複製ヘルパの件数がおかしい {key}: 前 {b} 後 {a}")
        ng_total = 1

sys.exit(ng_total)
