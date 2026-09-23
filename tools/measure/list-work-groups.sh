#!/usr/bin/env bash
# issue #9 で作成（tools/ へ移す前の名前は 9-measure-list-work-groups.sh）
# 本物の Athena で、ListWorkGroups の挙動を実測する（issue #9）。
# #2 の get-work-group.sh を雛形にしている。
#
# 使い方:
#   tools/dev.sh bash tools/measure/list-work-groups.sh
#   （資格情報はホストのシェルで AWS_ACCESS_KEY_ID などを export してから。または ~/.aws/credentials）
#
# 任意の環境変数:
#   REGION    既定 ap-northeast-1
#   OUT_DIR   既定 ${DEV_HOST_HOME:-$HOME}/athena-list-work-groups-measurements
#             （実名が入るのでリポジトリの外に出す）
#
# クエリは一切流さないので DB や OutputLocation は要らない。呼ぶのは
# ListWorkGroups と GetWorkGroup だけで、どちらも読み取り専用。課金は増えない。
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く。前の回の結果と混ざらない。
#
# 前の回（issue #1・#2）の実測でつまずいた点を踏襲する。
#   - aws が Docker のラッパだと、マウントされるのは実行時のカレントディレクトリだけ。
#     aws 自身にファイルへの書き込みをさせると、コンテナの中に書いて消え、しかも
#     終了コードは 0 になる。このスクリプトでは aws に直接ファイルへ書かせず、
#     常に `aws ... > file` の形でこのシェル自身がリダイレクトする。
#   - ワークグループ名・アカウント ID などの実名は端末に出さず、ファイルに置くだけに
#     する。summary.txt も実名を含まない形にし、ワークグループ名は WG1・WG2 … の
#     番号に、12 桁のアカウント ID らしき数列と OUT_DIR・NextToken の値は
#     <ACCOUNT_ID> 等のプレースホルダに置き換えてから書く。
#   - NextToken にはワークグループ名が入りうるので、**値そのものは summary に
#     出さない**。長さ・文字種・base64 らしいかだけを書く。
#   - --debug の生ログにはリクエスト側の SigV4 の Authorization ヘッダと
#     Access Key ID が入る。応答ヘッダとボディだけを抜き出したら必ず消す。
#     途中で止めても残らないよう trap も張る。
#
# JSON の読み取りは jq ではなく python3 で行う（#2 と同じ。jq が無い環境でも動く）。
#
# 測る項目（GitHub issue #9「実装の前に本物の Athena で測ること」より）。
#   1. list-work-groups の素の応答（--no-paginate で CLI の自動ページングを止めた
#      生の 1 ページ）。件数、各要素のキー集合、State の値の集合、Description が
#      空文字／非空の要素数、EngineVersion の値、NextToken の有無。--debug から
#      応答ヘッダとボディを抜いて CreationTime のワイヤ表記（数値か文字列か）も採る。
#   2. --max-results 1 のときの NextToken の有無と形（長さ・base64 らしいか・文字種。
#      値そのものは出さない）。NextToken が返ったら --next-token で 2 ページ目以降を
#      最後まで辿り（上限 20 回）、各ページの件数と、全ページを合わせた Name の並びが
#      1 の順序と一致するかを書く。
#   3. --max-results の上限。50 / 51 / 0 を渡して、応答またはエラー（CLI の標準エラーと、
#      --debug から抜いた応答ボディの __type・message・AthenaErrorCode）。
#   4. 不正な NextToken。固定の文字列と、2 で取れた正しいトークンの末尾を 1 文字
#      変えたもの（2 が取れたときだけ）を渡し、エラーの型・文言・AthenaErrorCode を採る。
#   5. GetWorkGroup と ListWorkGroups で Description の有無が食い違うか。1 で得た
#      同じワークグループ（先頭の 1 件と、Description が非空の 1 件があればそれ）に
#      get-work-group を投げ、Description キーがあるか、あれば値が一致するか
#      （値そのものは出さず、長さだけ）。
#   6. 一覧の順序。1 の Name の並びが辞書順（sort）と一致するか、CreationTime 昇順と
#      一致するか。名前そのものは出さない。
#
# 保存するファイル（すべて $RUN_DIR の中）。
#   list-work-groups.json / .stderr.txt      1 の素の応答
#   list-work-groups.wire.txt                --debug から抜いた応答ヘッダ・ボディ
#                                            （CreationTime の生の表記を見るため）
#   wg-names.tsv                             ワークグループ名と WG<n> の対応（**実名を含む**）
#   wg-names-order.txt                       1 の応答での名前の並び（**実名を含む**）
#   wg-first.txt                             5 で投げる先頭 1 件の名前（**実名を含む**）
#   wg-desc-nonempty.txt                     5 で投げる Description 非空の 1 件の名前（**実名を含む**）
#   max-results-1.json / .stderr.txt         2 の 1 ページ目
#   max-results-1.page<N>.json / .stderr.txt 2 の N ページ目（2 以降）
#   paged-names.txt                          2 で辿った全ページの名前の並び（**実名を含む**）
#   max-results-50.json / .stderr.txt        3 の --max-results 50
#   max-results-50.wire.txt                  同上の --debug から抜いた応答
#   max-results-51.*                         3 の --max-results 51（同じ 3 点セット）
#   max-results-0.*                          3 の --max-results 0（同じ 3 点セット）
#   bad-token.*                              4 の固定の不正トークン（同じ 3 点セット）
#   tweaked-token.*                          4 の末尾を 1 文字変えたトークン（同上）
#   desc-first.get-work-group.json / .stderr.txt      5 の先頭 1 件
#   desc-nonempty.get-work-group.json / .stderr.txt   5 の Description 非空の 1 件
#   summary.txt                              実名を含まない要約。そのまま貼れる。

set -uo pipefail

REGION=${REGION:-ap-northeast-1}
# toolbox（tools/dev.sh）ではホストのホーム（DEV_HOST_HOME）。#129
OUT_DIR=${OUT_DIR:-${DEV_HOST_HOME:-$HOME}/athena-list-work-groups-measurements}

# 4 で使う固定の不正トークン。実在のトークンと衝突しない形にしておく。
BAD_TOKEN=athena-local-invalid-next-token-probe
# 2 で取れた正しいトークンと、その末尾を 1 文字変えたもの。mask() で伏せるため
# グローバルに持つ（端末にも summary にも値そのものは出さない）。
TOKEN1=""
TOKEN1_TWEAKED=""

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.txt"
: > "$SUMMARY"
echo "出力先: $RUN_DIR"

# 実名（ワークグループ名・NextToken の値・OUT_DIR・12 桁のアカウント ID らしき数列）を
# summary に書く前にプレースホルダへ置き換える。エラー文言に紛れ込む保険で、通常の
# 項目名や真偽値・バージョン文字列には影響しない。ワークグループ名の対応表は 1 を
# 測ったあとにできるので、それ以前の呼び出しでは名前の置換だけが効かない
# （1 より前に aws を呼ばないようにしてある）。
mask() {
  local s=$1
  [ -n "$OUT_DIR" ] && s=${s//$OUT_DIR/<OUT_DIR>}
  [ -n "$BAD_TOKEN" ] && s=${s//$BAD_TOKEN/<BAD_TOKEN>}
  [ -n "$TOKEN1" ] && s=${s//$TOKEN1/<NEXT_TOKEN>}
  [ -n "$TOKEN1_TWEAKED" ] && s=${s//$TOKEN1_TWEAKED/<TWEAKED_NEXT_TOKEN>}
  if [ -s "$RUN_DIR/wg-names.tsv" ]; then
    # 長い名前から先に置き換える（短い名前が長い名前の一部のことがある）。
    local name ph
    while IFS=$'\t' read -r name ph; do
      [ -n "$name" ] && s=${s//$name/$ph}
    done < "$RUN_DIR/wg-names.tsv"
  fi
  printf '%s' "$s" | sed -E 's/[0-9]{12}/<ACCOUNT_ID>/g'
}

# --debug の生ログから、応答ヘッダとボディと HTTP ステータスだけを抜き出す。
# 生ログにはリクエスト側の SigV4 の Authorization ヘッダと Access Key ID が
# 入るので、抜き出したら必ず消す。途中で止めても残らないよう trap も張る。
trap 'rm -f "$RUN_DIR"/.*-debug-raw.tmp' EXIT

capture_wire() {
  local label=$1
  shift
  local raw="$RUN_DIR/.$label-debug-raw.tmp"
  "$@" --debug > "$raw" 2>&1
  {
    # botocore のログ書式（日時・スレッド名などの前置き）に依存しないよう、
    # "Response headers:" / "Response body:" という文言だけを手がかりにする。
    grep -E 'Response headers:' "$raw"
    grep -A1 -E 'Response body:' "$raw"
    grep -E '"[A-Z]+ / HTTP/[0-9.]+" [0-9]{3}' "$raw"
  } > "$RUN_DIR/$label.wire.txt" 2>/dev/null
  rm -f "$raw"
}

# ワイヤ形式のファイルから、HTTP ステータス・x-amzn-errortype・__type・
# AthenaErrorCode・message を拾って summary に書く。3 と 4 で使い回す。
report_wire_error() {
  local label=$1 file="$RUN_DIR/$1.wire.txt"
  if [ ! -s "$file" ]; then
    printf '[%s] --debug からのワイヤ形式の採取に失敗（CLI 側の検証で止まったか、botocore のログ形式が変わった可能性）\n' \
      "$label" >> "$SUMMARY"
    return
  fi
  local http_status errortype dunder_type athena_error_code message
  http_status=$(grep -oE '"[A-Z]+ / HTTP/[0-9.]+" [0-9]{3}' "$file" | grep -oE '[0-9]{3}$' | head -1)
  errortype=$(grep -oE "'x-amzn-errortype':[[:space:]]*'[^']*'" "$file" \
    | head -1 | sed -E "s/.*:[[:space:]]*'([^']*)'/\1/")
  dunder_type=$(grep -oiE '"__type"[[:space:]]*:[[:space:]]*"[^"]*"' "$file" \
    | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
  athena_error_code=$(grep -oiE '"AthenaErrorCode"[[:space:]]*:[[:space:]]*"[^"]*"' "$file" \
    | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
  message=$(grep -oiE '"message"[[:space:]]*:[[:space:]]*"[^"]*"' "$file" \
    | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
  {
    printf '[%s] HTTP ステータス = %s\n' "$label" "${http_status:-(採取できず)}"
    printf '[%s] x-amzn-errortype ヘッダ = %s\n' "$label" "${errortype:-(採取できず)}"
    printf '[%s] __type = %s\n' "$label" "${dunder_type:-(採取できず)}"
    printf '[%s] AthenaErrorCode = %s\n' "$label" "${athena_error_code:-(無し)}"
    printf '[%s] ワイヤ上の message = %s\n' "$label" "$(mask "${message:-(採取できず)}")"
  } >> "$SUMMARY"
}

# CLI の標準エラーから「An error occurred (...) ...」の 1 行を拾って summary に書く。
report_cli_error() {
  local label=$1 err="$RUN_DIR/$1.stderr.txt" line=""
  if [ -s "$err" ]; then
    line=$(grep -o 'An error occurred ([A-Za-z]*) when calling the [A-Za-z]* operation: .*' "$err" | head -1)
    if [ -z "$line" ]; then
      # CLI 側の検証で落ちたとき（ParamValidationError など）は上の形にならない。
      line=$(grep -vE '^[[:space:]]*$' "$err" | tail -1)
    fi
  fi
  printf '[%s] CLI エラー = %s\n' "$label" "$(mask "${line:-(標準エラーは空)}")" >> "$SUMMARY"
}

# list-work-groups に追加の引数を渡して、応答（またはエラー）とワイヤ形式を採る。
# 成功したら 0、失敗したら 1 を返す。
probe_list() {
  local label=$1
  shift
  echo "== $label: 実行します"
  if aws athena list-work-groups --region "$REGION" --no-paginate "$@" \
    > "$RUN_DIR/$label.json" 2> "$RUN_DIR/$label.stderr.txt"; then
    local count
    count=$(count_of "$RUN_DIR/$label.json")
    echo "== $label: 成功しました（件数 = $count）"
    printf '[%s] 結果 = 成功（件数 = %s、NextToken の有無 = %s）\n' \
      "$label" "$count" "$(has_next_token "$RUN_DIR/$label.json")" >> "$SUMMARY"
    capture_wire "$label" aws athena list-work-groups --region "$REGION" --no-paginate "$@"
    return 0
  else
    echo "== $label: エラーになりました（想定どおりのこともあります）"
    printf '[%s] 結果 = エラー\n' "$label" >> "$SUMMARY"
    report_cli_error "$label"
    capture_wire "$label" aws athena list-work-groups --region "$REGION" --no-paginate "$@"
    report_wire_error "$label"
    return 1
  fi
}

# 応答の件数を返す。読めなければ ? を返す。
count_of() {
  python3 -c 'import json, sys
try:
    print(len(json.load(open(sys.argv[1])).get("WorkGroups", [])))
except Exception:
    print("?")' "$1" 2>/dev/null
}

# NextToken の有無だけを返す（値は出さない）。
has_next_token() {
  python3 -c 'import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("(読めず)")
    sys.exit(0)
print("有り" if d.get("NextToken") else "無し")' "$1" 2>/dev/null
}

# NextToken の値を返す。呼び出し側は変数に入れるだけで、端末には出さない。
next_token_of() {
  python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("NextToken", "") or "")
except Exception:
    print("")' "$1" 2>/dev/null
}

# ---- 1. 素の応答を測る -----------------------------------------------------

echo "== list-work-groups: 実行します"
aws athena list-work-groups --region "$REGION" --no-paginate \
  > "$RUN_DIR/list-work-groups.json" 2> "$RUN_DIR/list-work-groups.stderr.txt"
if [ ! -s "$RUN_DIR/list-work-groups.json" ]; then
  echo "== list-work-groups: 取得できませんでした。$RUN_DIR/list-work-groups.stderr.txt を見てください"
  printf '[list-work-groups] 取得できませんでした\n' >> "$SUMMARY"
  report_cli_error list-work-groups
  echo "1 が取れないと以降の項目も測れないので、ここで終わります。"
  exit 1
fi
echo "== list-work-groups: 取得できました"

# 件数・キー集合・State・Description・EngineVersion・NextToken と、6 の順序をまとめて見る。
# ワークグループ名は WG<n> に置き換えてから summary に書き、実名は wg-names.tsv と
# wg-names-order.txt にだけ残す。
python3 - "$RUN_DIR/list-work-groups.json" "$SUMMARY" "$RUN_DIR" <<'EOF'
import datetime
import json
import sys

path, out, run_dir = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(path))
wgs = d.get("WorkGroups", [])
names = [w.get("Name", "") for w in wgs]
ph = {}
for i, n in enumerate(names):
    ph.setdefault(n, "WG%d" % (i + 1))

# mask() 用の対応表。長い名前から置き換えられるよう長さの降順で書く。
with open(run_dir + "/wg-names.tsv", "w") as f:
    for n in sorted([n for n in ph if n], key=len, reverse=True):
        f.write("%s\t%s\n" % (n, ph[n]))
# 2 の並び比較に使う、応答での順序そのもの。
with open(run_dir + "/wg-names-order.txt", "w") as f:
    f.write("\n".join(names) + ("\n" if names else ""))
# 5 で投げる先。先頭の 1 件と、Description が非空の 1 件。
with open(run_dir + "/wg-first.txt", "w") as f:
    f.write((names[0] if names else "") + "\n")
nonempty = [w.get("Name", "") for w in wgs if w.get("Description")]
with open(run_dir + "/wg-desc-nonempty.txt", "w") as f:
    f.write((nonempty[0] if nonempty else "") + "\n")


def ct_key(w):
    """CreationTime で並べるためのキー。数値でも ISO 文字列でも並べられるようにする。"""
    ct = w.get("CreationTime")
    if isinstance(ct, bool):
        return (2, 0.0, "")
    if isinstance(ct, (int, float)):
        return (0, float(ct), "")
    if isinstance(ct, str):
        try:
            return (0, datetime.datetime.fromisoformat(ct.replace("Z", "+00:00")).timestamp(), "")
        except Exception:
            return (1, 0.0, ct)
    return (2, 0.0, "")


ct_types = sorted({type(w.get("CreationTime")).__name__ for w in wgs}) or ["(要素無し)"]
key_sets = sorted({tuple(sorted(w.keys())) for w in wgs})
states = sorted({str(w.get("State", "(無し)")) for w in wgs})
desc_missing = sum(1 for w in wgs if "Description" not in w)
desc_empty = sum(1 for w in wgs if w.get("Description") == "")
desc_nonempty = sum(1 for w in wgs if w.get("Description"))
engine_versions = sorted(
    {json.dumps(w.get("EngineVersion"), sort_keys=True, ensure_ascii=False) for w in wgs}
)

as_listed = [ph[n] for n in names]
sorted_order = [ph[n] for n in sorted(names)]
by_ct = [ph[w.get("Name", "")] for w in sorted(wgs, key=ct_key)]

lines = [
    "[list-work-groups] 件数 = %d" % len(wgs),
    "[list-work-groups] 応答直下のキー一覧 = %s" % sorted(d.keys()),
    "[list-work-groups] 各要素のキー集合 = %s" % [list(k) for k in key_sets],
    "[list-work-groups] State の値の集合 = %s" % states,
    "[list-work-groups] Description キーが無い要素数 = %d" % desc_missing,
    "[list-work-groups] Description が空文字の要素数 = %d" % desc_empty,
    "[list-work-groups] Description が非空の要素数 = %d" % desc_nonempty,
    "[list-work-groups] EngineVersion の値 = %s" % engine_versions,
    "[list-work-groups] NextToken の有無 = %s" % ("有り" if d.get("NextToken") else "無し"),
    "[list-work-groups] CreationTime の型（CLI の JSON 出力上） = %s" % ct_types,
    "[order] 応答の並び = %s" % as_listed,
    "[order] 辞書順と一致するか = %s" % ("はい" if as_listed == sorted_order else "いいえ"),
    "[order] 辞書順に並べたとき = %s" % sorted_order,
    "[order] CreationTime 昇順と一致するか = %s" % ("はい" if as_listed == by_ct else "いいえ"),
    "[order] CreationTime 昇順に並べたとき = %s" % by_ct,
]
with open(out, "a") as f:
    f.write("\n".join(lines) + "\n")
EOF

# CLI の JSON 出力は timestamp を整形して見せるので、CreationTime が実際に何で
# 送られてくるか（epoch 秒の数値か文字列か）は生の応答でないと分からない。
echo "== list-work-groups (--debug でワイヤ形式を採取): 実行します"
capture_wire list-work-groups aws athena list-work-groups --region "$REGION" --no-paginate
if [ -s "$RUN_DIR/list-work-groups.wire.txt" ]; then
  echo "== list-work-groups (--debug): ワイヤ形式を採取しました"
  creation=$(grep -oE '"CreationTime"[[:space:]]*:[[:space:]]*[^,}]*' \
    "$RUN_DIR/list-work-groups.wire.txt" | head -1)
  printf '[list-work-groups] ワイヤ上の CreationTime = %s\n' \
    "$(mask "${creation:-(採取できず)}")" >> "$SUMMARY"
else
  echo "== list-work-groups (--debug): ワイヤ形式を採取できませんでした（botocore のログ形式が変わった可能性）"
  printf '[list-work-groups] --debug からのワイヤ形式の採取に失敗（ログ形式差の可能性）\n' >> "$SUMMARY"
fi

# ---- 2. --max-results 1 と NextToken を測る --------------------------------

echo "== max-results-1: 実行します"
aws athena list-work-groups --region "$REGION" --no-paginate --max-results 1 \
  > "$RUN_DIR/max-results-1.json" 2> "$RUN_DIR/max-results-1.stderr.txt"
if [ -s "$RUN_DIR/max-results-1.json" ]; then
  echo "== max-results-1: 取得できました（件数 = $(count_of "$RUN_DIR/max-results-1.json")）"
  # NextToken の形だけを見る。値そのものは summary にも端末にも出さない
  # （トークンにワークグループ名が入りうるため）。
  python3 - "$RUN_DIR/max-results-1.json" "$SUMMARY" <<'EOF'
import json
import re
import sys

path, out = sys.argv[1], sys.argv[2]
d = json.load(open(path))
tok = d.get("NextToken")
lines = ["[max-results-1] 件数 = %d" % len(d.get("WorkGroups", []))]
if not tok:
    lines.append("[max-results-1] NextToken = 無し")
else:
    classes = []
    if re.search(r"[a-z]", tok):
        classes.append("英小文字")
    if re.search(r"[A-Z]", tok):
        classes.append("英大文字")
    if re.search(r"[0-9]", tok):
        classes.append("数字")
    specials = sorted({c for c in tok if not c.isalnum()})
    base64ish = bool(re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", tok))
    base64urlish = bool(re.fullmatch(r"[A-Za-z0-9_-]+={0,2}", tok))
    lines += [
        "[max-results-1] NextToken = 有り（値そのものは伏せる）",
        "[max-results-1] NextToken の長さ = %d" % len(tok),
        "[max-results-1] NextToken の文字種 = %s" % (classes or ["(英数字なし)"]),
        "[max-results-1] NextToken の英数字以外の文字 = %s" % (specials or ["(無し)"]),
        "[max-results-1] NextToken は標準 base64 らしいか = %s" % ("はい" if base64ish else "いいえ"),
        "[max-results-1] NextToken は URL-safe base64 らしいか = %s" % ("はい" if base64urlish else "いいえ"),
    ]
with open(out, "a") as f:
    f.write("\n".join(lines) + "\n")
EOF

  # 1 ページ目の名前を控えてから、NextToken を辿って最後まで取る（上限 20 回）。
  : > "$RUN_DIR/paged-names.txt"
  python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
with open(sys.argv[2], "a") as f:
    for w in d.get("WorkGroups", []):
        f.write(w.get("Name", "") + "\n")' "$RUN_DIR/max-results-1.json" "$RUN_DIR/paged-names.txt"
  page_counts=$(count_of "$RUN_DIR/max-results-1.json")
  TOKEN1=$(next_token_of "$RUN_DIR/max-results-1.json")
  token=$TOKEN1
  page=1
  while [ -n "$token" ] && [ "$page" -lt 20 ]; do
    page=$((page + 1))
    echo "== max-results-1: $page ページ目を取ります"
    aws athena list-work-groups --region "$REGION" --no-paginate --max-results 1 \
      --next-token "$token" \
      > "$RUN_DIR/max-results-1.page$page.json" 2> "$RUN_DIR/max-results-1.page$page.stderr.txt"
    if [ ! -s "$RUN_DIR/max-results-1.page$page.json" ]; then
      echo "== max-results-1: $page ページ目を取れませんでした"
      printf '[max-results-1] %d ページ目でエラー\n' "$page" >> "$SUMMARY"
      report_cli_error "max-results-1.page$page"
      break
    fi
    python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
with open(sys.argv[2], "a") as f:
    for w in d.get("WorkGroups", []):
        f.write(w.get("Name", "") + "\n")' "$RUN_DIR/max-results-1.page$page.json" "$RUN_DIR/paged-names.txt"
    page_counts="$page_counts,$(count_of "$RUN_DIR/max-results-1.page$page.json")"
    token=$(next_token_of "$RUN_DIR/max-results-1.page$page.json")
  done
  {
    printf '[max-results-1] 辿ったページ数 = %d（上限 20）\n' "$page"
    printf '[max-results-1] 各ページの件数 = %s\n' "$page_counts"
    printf '[max-results-1] 最後のページに NextToken が残ったか = %s\n' \
      "$([ -n "$token" ] && echo '残った（上限で打ち切った可能性）' || echo '残らなかった')"
  } >> "$SUMMARY"

  # 全ページを合わせた Name の並びが、1 の順序と一致するか。名前は出さない。
  python3 - "$RUN_DIR/wg-names-order.txt" "$RUN_DIR/paged-names.txt" "$SUMMARY" <<'EOF'
import sys

one, paged, out = sys.argv[1], sys.argv[2], sys.argv[3]
a = [l for l in open(one).read().splitlines() if l]
b = [l for l in open(paged).read().splitlines() if l]
lines = [
    "[max-results-1] 全ページ合計の件数 = %d（1 の件数 = %d）" % (len(b), len(a)),
    "[max-results-1] 並びが 1 と一致するか = %s" % ("はい" if a == b else "いいえ"),
    "[max-results-1] 集合として一致するか = %s" % ("はい" if sorted(a) == sorted(b) else "いいえ"),
]
if a != b and sorted(a) == sorted(b):
    # 何番目から食い違ったかだけを書く（名前そのものは出さない）。
    for i, (x, y) in enumerate(zip(a, b)):
        if x != y:
            lines.append("[max-results-1] 並びが食い違い始める位置 = %d 番目" % (i + 1))
            break
with open(out, "a") as f:
    f.write("\n".join(lines) + "\n")
EOF

  # 4 で使う「末尾を 1 文字だけ変えたトークン」を作る。値は端末に出さない。
  if [ -n "$TOKEN1" ]; then
    last=${TOKEN1: -1}
    if [ "$last" = "A" ]; then
      TOKEN1_TWEAKED="${TOKEN1%?}B"
    else
      TOKEN1_TWEAKED="${TOKEN1%?}A"
    fi
  fi
else
  echo "== max-results-1: 取得できませんでした。$RUN_DIR/max-results-1.stderr.txt を見てください"
  printf '[max-results-1] 取得できませんでした\n' >> "$SUMMARY"
  report_cli_error max-results-1
fi

# ---- 3. --max-results の上限を測る -----------------------------------------

# 50 は上限ちょうど、51 は 1 つ超え、0 は下限割れ。0 は CLI 側の検証で
# 止まることがあり、そのときはワイヤ形式が採れない（その旨を summary に書く）。
probe_list max-results-50 --max-results 50
probe_list max-results-51 --max-results 51
probe_list max-results-0 --max-results 0

# ---- 4. 不正な NextToken を測る --------------------------------------------

probe_list bad-token --next-token "$BAD_TOKEN"

if [ -n "$TOKEN1_TWEAKED" ]; then
  probe_list tweaked-token --next-token "$TOKEN1_TWEAKED"
  printf '[tweaked-token] 元のトークンの末尾 1 文字だけを変えたもの（値は伏せる）\n' >> "$SUMMARY"
else
  echo "== tweaked-token: skip (2 で NextToken が取れなかった)"
  printf '[tweaked-token] skip (2 で NextToken が取れなかった)\n' >> "$SUMMARY"
fi

# ---- 5. GetWorkGroup と ListWorkGroups の Description の食い違いを測る -----

# ラベルと名前を渡して get-work-group を投げ、1 の応答の同じ要素と Description を比べる。
# 名前も Description の値も summary には出さない（長さと一致するかだけ）。
compare_desc() {
  local label=$1 name=$2
  echo "== $label (get-work-group): 実行します"
  aws athena get-work-group --region "$REGION" --work-group "$name" \
    > "$RUN_DIR/$label.get-work-group.json" 2> "$RUN_DIR/$label.get-work-group.stderr.txt"
  if [ ! -s "$RUN_DIR/$label.get-work-group.json" ]; then
    echo "== $label (get-work-group): 取得できませんでした"
    printf '[%s] get-work-group を取得できませんでした\n' "$label" >> "$SUMMARY"
    report_cli_error "$label.get-work-group"
    return 1
  fi
  python3 - "$RUN_DIR/list-work-groups.json" "$RUN_DIR/$label.get-work-group.json" "$name" "$label" "$SUMMARY" <<'EOF'
import json
import sys

list_path, get_path, name, label, out = sys.argv[1:6]
wgs = json.load(open(list_path)).get("WorkGroups", [])
item = next((w for w in wgs if w.get("Name") == name), {})
wg = json.load(open(get_path)).get("WorkGroup", {})

in_list = "Description" in item
in_get = "Description" in wg
lv = item.get("Description")
gv = wg.get("Description")


def desc(has, v):
    if not has:
        return "キー無し"
    if v == "":
        return "空文字"
    return "非空（長さ %d）" % len(v)


lines = [
    "[%s] ListWorkGroups 側の Description = %s" % (label, desc(in_list, lv)),
    "[%s] GetWorkGroup 側の Description = %s" % (label, desc(in_get, gv)),
    "[%s] 有無が食い違うか = %s" % (label, "はい" if in_list != in_get else "いいえ"),
    "[%s] 値が一致するか = %s"
    % (label, "はい" if (in_list and in_get and lv == gv) else ("いいえ" if (in_list or in_get) else "(両方キー無し)")),
    "[%s] GetWorkGroup の WorkGroup 直下のキー一覧 = %s" % (label, sorted(wg.keys())),
    "[%s] ListWorkGroups の要素のキー一覧 = %s" % (label, sorted(item.keys())),
]
with open(out, "a") as f:
    f.write("\n".join(lines) + "\n")
EOF
}

first_wg=$(head -1 "$RUN_DIR/wg-first.txt" 2>/dev/null)
if [ -n "$first_wg" ]; then
  compare_desc desc-first "$first_wg"
else
  echo "== desc-first: skip (1 の応答が空)"
  printf '[desc-first] skip (1 の応答にワークグループが 1 件も無い)\n' >> "$SUMMARY"
fi

desc_wg=$(head -1 "$RUN_DIR/wg-desc-nonempty.txt" 2>/dev/null)
if [ -n "$desc_wg" ] && [ "$desc_wg" != "$first_wg" ]; then
  compare_desc desc-nonempty "$desc_wg"
elif [ -n "$desc_wg" ]; then
  echo "== desc-nonempty: skip (先頭の 1 件と同じワークグループ)"
  printf '[desc-nonempty] skip (Description が非空の 1 件目が先頭の 1 件と同じ)\n' >> "$SUMMARY"
else
  echo "== desc-nonempty: skip (Description が非空のワークグループが無い)"
  printf '[desc-nonempty] skip (1 の応答に Description が非空のワークグループが無い)\n' >> "$SUMMARY"
fi

echo
echo "完了しました。"
echo "実名を含まない要約: $SUMMARY"
echo
cat "$SUMMARY"
echo
echo "中身のファイルは $RUN_DIR にあります。リポジトリには入れないでください。"
echo "wg-names.tsv・wg-names-order.txt・paged-names.txt・*.json はワークグループ名や"
echo "NextToken の値を含むので、貼るときは中身を確かめてください。"

# 実行例:
#   REGION=ap-northeast-1 bash list-work-groups.sh
