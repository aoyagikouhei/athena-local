#!/usr/bin/env bash
# 本物の Athena で、GetWorkGroup の挙動を実測する（issue #2）。
#
# 使い方:
#   bash 2-measure-workgroup.sh
#
# 任意の環境変数:
#   REGION            既定 ap-northeast-1
#   WORKGROUP         既定 primary。1 の GetWorkGroup で測る対象。
#   WORKGROUP2        OutputLocation が設定済みの別ワークグループがあれば指定する。
#                     省略するとその分だけ skip する。
#   MISSING_WORKGROUP 存在しないワークグループの名前。既定は衝突しない固定名。
#   DB, OUTPUT        3 の StartQueryExecution に要る（DB=データベース名、
#                     OUTPUT=s3://bucket/prefix/）。どちらか片方でも未設定なら
#                     その項目だけ skip し、その旨を出す。
#   OUT_DIR           既定 $HOME/athena-workgroup-measurements
#                     （実名が入るのでリポジトリの外に出す）
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く。前の回の結果と混ざらない。
#
# 前回（issue #1）の実測でつまずいた点を踏襲する。
#   - aws が Docker のラッパだと、マウントされるのは実行時のカレントディレクトリだけ。
#     `aws s3 cp <src> <絶対パス>` のように aws 自身にファイルへの書き込みをさせると、
#     コンテナの中に書いて消え、しかも終了コードは 0 になる。このスクリプトでは
#     aws に直接ファイルへ書かせず、常に `aws ... > file` の形でこのシェル自身が
#     リダイレクトする（S3 のオブジェクト本体を取得する処理は無い）。
#   - バケット名・データベース名・アカウント ID などの実名は端末に出さず、ファイルに
#     置くだけにする。summary.txt も実名を含まない形にし、DB・OUTPUT・WORKGROUP・
#     WORKGROUP2・MISSING_WORKGROUP の値と 12 桁のアカウント ID らしき数列は、
#     万一エラー文言に混ざっても <DB> 等のプレースホルダに置き換えてから書く。
#
# 測る項目（GitHub issue #2 より）。
#   1. GetWorkGroup（primary、任意で WORKGROUP2）の応答の全項目。生 JSON をそのまま
#      保存し、State・EngineVersion・Description の有無・CreationTime の表記・
#      ResultConfiguration.OutputLocation の有無などを summary にも書く。
#   2. 存在しないワークグループを指定したときのエラー。CLI の標準エラーに加えて、
#      --debug の botocore ログから応答ヘッダとボディだけを抜き出して保存する。
#   3. StartQueryExecution に存在しないワークグループを渡したときの挙動
#      （DB と OUTPUT が要る。クエリは SELECT 1 のみで、表は作らない）。
#   4. OutputLocation が設定されたワークグループの見え方は 1 の中で読み取る。
#   5. 参考として ListWorkGroups の応答も保存する（件数だけ summary に書く）。
#
# 保存するファイル（すべて $RUN_DIR の中）。
#   workgroup1.get-work-group.json / .stderr.txt   WORKGROUP の応答
#   workgroup1.wire.txt                            --debug から抜いた応答ヘッダ・ボディ
#                                                  （CreationTime の生の表記を見るため）
#   workgroup2.get-work-group.json / .stderr.txt   WORKGROUP2 の応答（設定時のみ）
#   missing-workgroup.stdout.txt / .stderr.txt     存在しないワークグループの CLI エラー
#   missing-workgroup.wire.txt                     --debug から抜いた応答ヘッダ・ボディ
#   start-query-missing-workgroup.stdout.json / .stderr.txt
#   list-work-groups.json / .stderr.txt
#   summary.txt                                    実名を含まない要約。そのまま貼れる。

set -uo pipefail

REGION=${REGION:-ap-northeast-1}
WORKGROUP=${WORKGROUP:-primary}
WORKGROUP2=${WORKGROUP2:-}
MISSING_WORKGROUP=${MISSING_WORKGROUP:-athena-local-nonexistent-workgroup-probe}
DB=${DB:-}
OUTPUT=${OUTPUT:-}
OUT_DIR=${OUT_DIR:-$HOME/athena-workgroup-measurements}

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.txt"
: > "$SUMMARY"
echo "出力先: $RUN_DIR"

# 実名（DB・OUTPUT・WORKGROUP・WORKGROUP2・MISSING_WORKGROUP・12 桁のアカウント ID
# らしき数列）を summary に書く前にプレースホルダへ置き換える。エラー文言に紛れ込む
# 保険で、通常の項目名や真偽値・バージョン文字列には影響しない。
mask() {
  local s=$1
  [ -n "$DB" ] && s=${s//$DB/<DB>}
  [ -n "$OUTPUT" ] && s=${s//$OUTPUT/<OUTPUT>}
  [ -n "$WORKGROUP" ] && s=${s//$WORKGROUP/<WORKGROUP>}
  [ -n "$WORKGROUP2" ] && s=${s//$WORKGROUP2/<WORKGROUP2>}
  [ -n "$MISSING_WORKGROUP" ] && s=${s//$MISSING_WORKGROUP/<MISSING_WORKGROUP>}
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

# ---- 1. GetWorkGroup の応答を測る ------------------------------------------

# ラベルを指定してワークグループを 1 つ測る。応答が取れたときだけ 0 を返す。
get_wg() {
  local label=$1 name=$2
  aws athena get-work-group --region "$REGION" --work-group "$name" \
    > "$RUN_DIR/$label.get-work-group.json" 2> "$RUN_DIR/$label.get-work-group.stderr.txt"
  if [ -s "$RUN_DIR/$label.get-work-group.json" ]; then
    echo "== $label (get-work-group): 取得できました"
    python3 - "$label" "$RUN_DIR/$label.get-work-group.json" "$SUMMARY" <<'EOF'
import json, sys

label, path, out = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(path))
wg = d.get("WorkGroup", {})
conf = wg.get("Configuration", {})
ev = conf.get("EngineVersion", {})
rc = conf.get("ResultConfiguration", {})
ct = wg.get("CreationTime")

if ct is None:
    ct_desc = "(無し)"
elif isinstance(ct, bool):
    ct_desc = f"型={type(ct).__name__}（値そのものは省略）"
elif isinstance(ct, (int, float)):
    frac = isinstance(ct, float) and not float(ct).is_integer()
    ct_desc = f"数値（epoch 秒相当、小数部の有無={'あり' if frac else 'なし'}）"
else:
    ct_desc = f"文字列（型={type(ct).__name__}、値そのものは省略）"


def yn(container, key):
    return "有り" if key in container else "無し"


lines = [
    f"[{label}] State = {wg.get('State', '(無し)')}",
    f"[{label}] Description の有無 = {yn(wg, 'Description')}",
    f"[{label}] CreationTime の表記 = {ct_desc}",
    f"[{label}] EngineVersion.SelectedEngineVersion = {ev.get('SelectedEngineVersion', '(無し)')}",
    f"[{label}] EngineVersion.EffectiveEngineVersion = {ev.get('EffectiveEngineVersion', '(無し)')}",
    f"[{label}] Configuration.EnforceWorkGroupConfiguration = {conf.get('EnforceWorkGroupConfiguration', '(無し)')}",
    f"[{label}] Configuration.PublishCloudWatchMetricsEnabled = {conf.get('PublishCloudWatchMetricsEnabled', '(無し)')}",
    f"[{label}] Configuration.RequesterPaysEnabled = {conf.get('RequesterPaysEnabled', '(無し)')}",
    f"[{label}] Configuration.BytesScannedCutoffPerQuery の有無 = {yn(conf, 'BytesScannedCutoffPerQuery')}",
    f"[{label}] Configuration.ExecutionRole の有無 = {yn(conf, 'ExecutionRole')}",
    f"[{label}] Configuration.AdditionalConfiguration の有無 = {yn(conf, 'AdditionalConfiguration')}",
    f"[{label}] Configuration.CustomerContentEncryptionConfiguration の有無 = {yn(conf, 'CustomerContentEncryptionConfiguration')}",
    f"[{label}] Configuration.ResultConfiguration.OutputLocation の有無 = {'有り' if rc.get('OutputLocation') else '無し'}",
    f"[{label}] Configuration.ResultConfiguration.EncryptionConfiguration の有無 = {yn(rc, 'EncryptionConfiguration')}",
    f"[{label}] WorkGroup 直下のキー一覧 = {sorted(wg.keys())}",
    f"[{label}] Configuration 直下のキー一覧 = {sorted(conf.keys())}",
]
with open(out, "a") as f:
    f.write("\n".join(lines) + "\n")
EOF
    return 0
  else
    echo "== $label (get-work-group): 取得できませんでした。$RUN_DIR/$label.get-work-group.stderr.txt を見てください"
    printf '[%s] 取得できませんでした\n' "$label" >> "$SUMMARY"
    return 1
  fi
}

get_wg workgroup1 "$WORKGROUP"

# 成功した応答のワイヤ形式も採る。AWS CLI の JSON 出力は timestamp を整形して
# 見せるので、CreationTime が実際に何で送られてくるか（epoch 秒の数値か文字列か）
# は生の応答でないと分からない。athena-local は既存の SubmissionDateTime を
# f64 の epoch 秒で返しているので、そこに合わせられるかをここで確かめる。
echo "== workgroup1 (--debug でワイヤ形式を採取): 実行します"
capture_wire workgroup1 aws athena get-work-group --region "$REGION" --work-group "$WORKGROUP"
if [ -s "$RUN_DIR/workgroup1.wire.txt" ]; then
  creation=$(grep -oE '"CreationTime"[[:space:]]*:[[:space:]]*[^,}]*' \
    "$RUN_DIR/workgroup1.wire.txt" | head -1)
  echo "== workgroup1 (--debug): ワイヤ形式を採取しました"
  printf '[workgroup1] ワイヤ上の CreationTime = %s\n' "$(mask "${creation:-(採取できず)}")" >> "$SUMMARY"
else
  echo "== workgroup1 (--debug): ワイヤ形式を採取できませんでした（botocore のログ形式が変わった可能性）"
  printf '[workgroup1] --debug からのワイヤ形式の採取に失敗（ログ形式差の可能性）\n' >> "$SUMMARY"
fi

if [ -n "$WORKGROUP2" ]; then
  get_wg workgroup2 "$WORKGROUP2"
else
  echo "== workgroup2 (get-work-group): skip (WORKGROUP2 が未設定)"
  printf '[workgroup2] skip (WORKGROUP2 が未設定)\n' >> "$SUMMARY"
fi

# ---- 2. 存在しないワークグループのエラーを測る -----------------------------

echo "== missing-workgroup (get-work-group、CLI エラー): 実行します"
aws athena get-work-group --region "$REGION" --work-group "$MISSING_WORKGROUP" \
  > "$RUN_DIR/missing-workgroup.stdout.txt" 2> "$RUN_DIR/missing-workgroup.stderr.txt"
if [ $? -ne 0 ]; then
  err_line=$(grep -o 'An error occurred ([A-Za-z]*) when calling the [A-Za-z]* operation: .*' \
    "$RUN_DIR/missing-workgroup.stderr.txt" | head -1)
  printf '[missing-workgroup] CLI エラー = %s\n' "$(mask "$err_line")" >> "$SUMMARY"
  echo "== missing-workgroup: エラーを確認しました"
else
  echo "== missing-workgroup: 想定外に成功しました。MISSING_WORKGROUP が実在の名前と衝突していないか確認してください"
  printf '[missing-workgroup] 想定外に成功した（MISSING_WORKGROUP が実在のワークグループ名と衝突している可能性）\n' >> "$SUMMARY"
fi

# 生のログ全体（リクエスト側のヘッダを含む）はそのままでは保存しない。
echo "== missing-workgroup (--debug でワイヤ形式を採取): 実行します"
capture_wire missing-workgroup aws athena get-work-group --region "$REGION" --work-group "$MISSING_WORKGROUP"

if [ -s "$RUN_DIR/missing-workgroup.wire.txt" ]; then
  echo "== missing-workgroup (--debug): ワイヤ形式を採取しました"
  http_status=$(grep -oE '"[A-Z]+ / HTTP/[0-9.]+" [0-9]{3}' "$RUN_DIR/missing-workgroup.wire.txt" \
    | grep -oE '[0-9]{3}$' | head -1)
  errortype=$(grep -oE "'x-amzn-errortype':[[:space:]]*'[^']*'" "$RUN_DIR/missing-workgroup.wire.txt" \
    | head -1 | sed -E "s/.*:[[:space:]]*'([^']*)'/\1/")
  dunder_type=$(grep -oiE '"__type"[[:space:]]*:[[:space:]]*"[^"]*"' "$RUN_DIR/missing-workgroup.wire.txt" \
    | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
  athena_error_code=$(grep -oiE '"AthenaErrorCode"[[:space:]]*:[[:space:]]*"[^"]*"' "$RUN_DIR/missing-workgroup.wire.txt" \
    | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
  message=$(grep -oiE '"message"[[:space:]]*:[[:space:]]*"[^"]*"' "$RUN_DIR/missing-workgroup.wire.txt" \
    | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
  {
    printf '[missing-workgroup] HTTP ステータス = %s\n' "${http_status:-(採取できず)}"
    printf '[missing-workgroup] x-amzn-errortype ヘッダ = %s\n' "${errortype:-(採取できず)}"
    printf '[missing-workgroup] __type = %s\n' "${dunder_type:-(採取できず)}"
    printf '[missing-workgroup] AthenaErrorCode = %s\n' "${athena_error_code:-(無し)}"
    printf '[missing-workgroup] ワイヤ上の message = %s\n' "$(mask "${message:-(採取できず)}")"
  } >> "$SUMMARY"
else
  echo "== missing-workgroup (--debug): ワイヤ形式を採取できませんでした（botocore のログ形式が変わった可能性）"
  printf '[missing-workgroup] --debug からのワイヤ形式の採取に失敗（ログ形式差の可能性）\n' >> "$SUMMARY"
fi

# ---- 3. StartQueryExecution に存在しないワークグループを渡す ---------------

if [ -n "$DB" ] && [ -n "$OUTPUT" ]; then
  echo "== start-query-execution (存在しないワークグループ): 実行します"
  aws athena start-query-execution --region "$REGION" \
    --work-group "$MISSING_WORKGROUP" \
    --query-string "SELECT 1" \
    --query-execution-context "Database=$DB" \
    --result-configuration "OutputLocation=$OUTPUT" \
    > "$RUN_DIR/start-query-missing-workgroup.stdout.json" \
    2> "$RUN_DIR/start-query-missing-workgroup.stderr.txt"
  if [ $? -eq 0 ]; then
    echo "== start-query-execution: 想定外に成功しました。MISSING_WORKGROUP が実在の名前と衝突していないか確認してください"
    printf '[start-query-missing-workgroup] 想定外に成功した（MISSING_WORKGROUP が実在のワークグループ名と衝突している可能性）\n' >> "$SUMMARY"
    # 読み取り専用の原則を守るため、成功してしまった場合だけ念のため取り消す。
    id=$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("QueryExecutionId", ""))
except Exception:
    print("")' "$RUN_DIR/start-query-missing-workgroup.stdout.json" 2>/dev/null)
    if [ -n "$id" ]; then
      aws athena stop-query-execution --region "$REGION" --query-execution-id "$id" >/dev/null 2>&1 || true
    fi
  else
    err_line=$(grep -o 'An error occurred ([A-Za-z]*) when calling the [A-Za-z]* operation: .*' \
      "$RUN_DIR/start-query-missing-workgroup.stderr.txt" | head -1)
    printf '[start-query-missing-workgroup] CLI エラー = %s\n' "$(mask "$err_line")" >> "$SUMMARY"
    echo "== start-query-execution: エラーを確認しました"
  fi
else
  echo "== start-query-execution (存在しないワークグループ): skip (DB か OUTPUT が未設定)"
  printf '[start-query-missing-workgroup] skip (DB か OUTPUT が未設定)\n' >> "$SUMMARY"
fi

# ---- 5. 参考として ListWorkGroups も測る -----------------------------------

echo "== list-work-groups: 実行します"
aws athena list-work-groups --region "$REGION" \
  > "$RUN_DIR/list-work-groups.json" 2> "$RUN_DIR/list-work-groups.stderr.txt"
if [ -s "$RUN_DIR/list-work-groups.json" ]; then
  count=$(python3 -c 'import json,sys
try:
    print(len(json.load(open(sys.argv[1])).get("WorkGroups", [])))
except Exception:
    print("?")' "$RUN_DIR/list-work-groups.json")
  echo "== list-work-groups: 取得できました"
  printf '[list-work-groups] 件数 = %s\n' "$count" >> "$SUMMARY"
else
  echo "== list-work-groups: 取得できませんでした。$RUN_DIR/list-work-groups.stderr.txt を見てください"
  printf '[list-work-groups] 取得できませんでした\n' >> "$SUMMARY"
fi

echo
echo "完了しました。"
echo "実名を含まない要約: $SUMMARY"
echo "中身のファイルは $RUN_DIR にあります。リポジトリには入れないでください。"

# 実行例（DB と OUTPUT を渡すと項目 3 も測れる）:
#   WORKGROUP2=analytics DB=your_db OUTPUT=s3://your-bucket/prefix/ bash 2-measure-workgroup.sh
