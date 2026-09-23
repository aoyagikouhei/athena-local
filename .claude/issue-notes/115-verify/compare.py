#!/usr/bin/env python3
# issue #115: JDBC の足場 3 本を lib に寄せる前後で、判定の行が同じかを比べる。
# 使い方: compare.py <前のログのディレクトリ> <後のログのディレクトリ>
#   各ディレクトリに metadata.log・show.log・drivers.log（足場の標準出力と標準エラー、末尾に rc=N）を置く。
# 終了コードは NG の件数。
import re, sys

STATUS = re.compile(r'^(PASS|FAIL|INFO|SKIP)\s+(.*?)\s{2,}(.*)$')

# 判定の行: 状態と正規化した詳細が前後で一致しなければならない
MUST = {
    'metadata': ['JDBC auto', 'JDBC S3', '.metadata 回収', '列 0 個の .metadata の存在'],
    'show': ['JDBC auto', 'JDBC S3', 'JDBC GetQueryResults', '.metadata 回収', 'SHOW の .txt.metadata の存在',
             'ドライバが .txt.metadata を読んだ(auto)', 'ドライバが .txt.metadata を読んだ(S3 明示)', '行数の突き合わせ'],
}
# 意図して変える行: 後の状態と詳細が正規表現に合うこと
CHANGED = {
    # 拡張子なしの <id>.metadata（DROP・ALTER の置くもの）だけを数えたと書いてあること（計画レビュー 1）
    'metadata': {'S3 直読みの裏取り': r'^PASS .*拡張子なし.* [1-9][0-9]* 件'},
    'show': {'S3 直読みの裏取り': r'^PASS .*\.txt\.metadata.* [1-9][0-9]* 件',
             '.csv.metadata（対照 SELECT）': r'^INFO 9 個.*= 9 のはず'},
}

KNOWN = {k for d in (MUST, CHANGED) for v in d.values() for k in v}

def norm(s):
    s = re.sub(r'run-\d{8}-\d{6}', 'run-X', s)
    s = re.sub(r'/tmp/athena-local-issue111-jdbc\.\w+', '/tmp/X', s)
    s = re.sub(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', 'UUID', s)
    # .metadata 回収のバイト数の並びは S3 の一覧の順（キーに UUID を含む）なので並べ替える
    m = re.search(r'バイト数: ([0-9 ]+)', s)
    if m:
        s = s.replace(m.group(1), ' '.join(sorted(m.group(1).split(), key=int)) + ' ')
    return re.sub(r'\s+', ' ', s).strip()

def rows(path):
    out, rc = {}, None
    for line in open(path, encoding='utf-8', errors='replace'):
        line = line.rstrip('\n')
        if line.startswith('rc='):
            rc = line[3:]
        m = STATUS.match(line)
        if m:
            rest = line[len(m.group(1)):].strip()
            # 名前が長いと詳細との間が空白 1 つになるので、既知の名前は前方一致で切る
            for k in sorted(KNOWN, key=len, reverse=True):
                if rest.startswith(k):
                    out[k] = (m.group(1), norm(rest[len(k):]))
                    break
            else:
                out[m.group(2).strip()] = (m.group(1), norm(m.group(3)))
    return out, rc

ng = 0
def bad(msg):
    global ng
    ng += 1
    print('NG  ' + msg)

before_dir, after_dir = sys.argv[1], sys.argv[2]
for name in ['metadata', 'show', 'drivers']:
    b, brc = rows(f'{before_dir}/{name}.log')
    a, arc = rows(f'{after_dir}/{name}.log')
    if arc != '0':
        bad(f'{name}: rc={arc}')
    for k, (st, _) in a.items():
        if st == 'FAIL':
            bad(f'{name}: FAIL の行 {k}')
    if name == 'drivers':
        # verify.sh の挙動は変えないので、行の集合と詳細が全部一致する
        for k in sorted(set(b) | set(a)):
            if b.get(k) != a.get(k):
                bad(f'drivers: {k}: 前 {b.get(k)} / 後 {a.get(k)}')
        continue
    for k in MUST[name]:
        if k not in b:
            bad(f'{name}: 前のログに {k} が無い（足場の誤り）')
        elif b.get(k) != a.get(k):
            bad(f'{name}: {k}: 前 {b.get(k)} / 後 {a.get(k)}')
    for k, pat in CHANGED[name].items():
        v = a.get(k)
        if v is None or not re.search(pat, f'{v[0]} {v[1]}'):
            bad(f'{name}: {k} が期待の形でない: 後 {v}（期待 {pat}）')
    known = set(MUST[name]) | set(CHANGED[name])
    for k in sorted(set(a) - set(b) - known):
        print(f'NEW {name}: {k} {a[k]}')
    for k in sorted(set(b) - set(a) - known):
        print(f'GONE {name}: {k}（準備の段の行。消えてよい）')
print(f'NG={ng}')
sys.exit(ng)
