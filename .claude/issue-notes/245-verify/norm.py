"""#245 の 5: 移した範囲と残った範囲を、空白を潰した文字列として順序ごと突き合わせる。

許容する書き換え（計画の許容リスト）だけを着手前の文に当て、それ以外の差分が 1 文字でもあれば NG。
"""
import re, subprocess, sys

base = sys.argv[1]
before = subprocess.run(['git', 'show', f'{base}:src/operation/execution.rs'], capture_output=True, text=True, check=True).stdout
after_exec = open('src/operation/execution.rs').read()
try:
    new = open('src/operation/start_checks.rs').read()
except FileNotFoundError:
    new = None


def squash(text):
    text = re.sub(r'^\s*(pub(\(\w+\))? )?use [^;]*;\n', '', text, flags=re.M | re.S)
    text = re.sub(r'^\s*//!.*\n', '', text, flags=re.M)
    text = re.sub(r'\s+', '', text)
    return re.sub(r',([)}\]])', r'\1', text)


START, END = '//S3Tablesのカタログは', 'letwork_group='
b = squash(before)
bs, be = b.index(START), b.index(END)
block, rest_before = b[bs:be], b[:bs] + b[be:]

if new is None:
    # 着手前のツリー: 移動先が無いので残った範囲だけ（= 全体）を比べる
    ok = squash(after_exec) == b
    print('ok 5 正規化 diff（移動先なし、execution.rs が着手前と同一）' if ok else 'NG 5 execution.rs が着手前と違う')
    sys.exit(0 if ok else 1)

expected = block
for pat, rep in [
    (r'returninvalid_request_with_code\((message),"MALFORMED_QUERY"\)', r'returnErr(Box::new(invalid_request_with_code(\1,"MALFORMED_QUERY")))'),
    (r'return\*response', 'returnErr(response)'),
    (r'catalog\.as_deref\(\)', 'catalog'),
    (r'result_location\.as_ref\(\)', 'result_location'),
    # fmt の折り返し: 行が短くなり、match の腕の本体の `{ }` が外れた（2 回目の as_deref を落とした結果）
    (r'Check::Table\{\.\.\}=>\{(matchreported_query::drop_database\(&statement,catalog\)\{Some\(rewritten\)=>\(rewritten\.query,Some\(rewritten\.database\)\),None=>\(statement,database\)\})\}',
     r'Check::Table{..}=>\1,'),
]:
    expected = re.sub(pat, rep, expected)

n = squash(new)
ns, ne = n.find(START), n.find('Ok(Decision{')
ng = 0
if ns < 0 or ne < 0:
    print('NG 5 start_checks.rs に移した範囲の目印が無い'); ng = 1
elif n[ns:ne] != expected:
    a, e = n[ns:ne], expected
    i = next((k for k in range(min(len(a), len(e))) if a[k] != e[k]), min(len(a), len(e)))
    print(f'NG 5 移した範囲が違う（{i} 文字目）\n  期待: {e[max(0, i - 60):i + 80]}\n  実物: {a[max(0, i - 60):i + 80]}'); ng = 1
else:
    print(f'ok 5a 移した範囲が許容の書き換えだけ（{len(a) if False else ne - ns} 文字）')
    if n.count(START) != 1:
        print('NG 5 移した範囲が 2 回以上ある'); ng = 1

ae = squash(after_exec)
m = re.search(r'letDecision\{[^}]*\}=matchdecide\(.*?\)\.await\{Ok\(decision\)=>decision,Err\(response\)=>return\*response\};', ae)
if not m:
    print('NG 5 execution.rs に decide の呼び出しが無い'); ng = 1
else:
    rest_after = ae[:m.start()] + ae[m.end():]
    if rest_after != rest_before:
        a, e = rest_after, rest_before
        i = next((k for k in range(min(len(a), len(e))) if a[k] != e[k]), min(len(a), len(e)))
        print(f'NG 5 残った範囲が違う（{i} 文字目）\n  期待: {e[max(0, i - 60):i + 80]}\n  実物: {a[max(0, i - 60):i + 80]}'); ng = 1
    else:
        print('ok 5b 残った範囲が同一（decide の呼び出しを除く）')
sys.exit(ng)
