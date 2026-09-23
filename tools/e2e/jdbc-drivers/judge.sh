# shellcheck shell=bash
# issue #111: jdbc-drivers/verify.sh の判定（JVM 1 回分の PASS/FAIL/SKIP/INFO と、版×(fetcher, シナリオ) の表）。
# verify.sh から source する。lib.sh の関数（dc・mc_run・athena_call）を使う。
#
# 「読みに行ったか」は tls-proxy（nginx）のアクセスログで、その回の出力先 /<接頭辞>/ の下の
# `.txt*`（.txt.metadata を含む）への GET を数える。nginx のログは既定の combined 形式で、ドライバは
# virtual-hosted style なのでパスにバケット名が入らない（`GET /e2e-jdbc111/... HTTP/1.1`）。この形を
# check_nginx_log_format が本体の前に確かめる。path-style でも一致するよう、接頭辞は部分一致で探す。

# 読みに行ったとみなすキーの正規表現（接頭辞より後ろに対して）。ミューテーション確認ではここに .csv を足す。
READ_EXT_RE='\.txt'
# 失敗した DDL の例外メッセージに含まれる Trino の失敗理由。実測（2026-09-23、全版・4 文とも）は
# `Query execution failed: TABLE_NOT_FOUND: line 1:1: Table '...' does not exist` だったのでそれに絞る。
REASON_RE='NOT_FOUND|does not exist'
FAILED_DDL_LABELS="DROP_TABLE_iceberg SHOW_COLUMNS_hive DESCRIBE_hive ALTER_TABLE_ADD_COLUMN_hive"
SHOW_LABELS=("SHOW_TABLES(対照)" "SHOW_SCHEMAS" "SHOW_COLUMNS")

declare -a RESULT_NAMES=() RESULT_STATUS=() RESULT_DETAIL=()
declare -A CELL=()

record() {
  RESULT_NAMES+=("$1")
  RESULT_STATUS+=("$2")
  RESULT_DETAIL+=("$3")
}

# $1 = nginx のログ, $2 = 接頭辞（/e2e-jdbc111/<ver>/<fetcher>/<scenario>/）, $3 = キーの正規表現（空なら全部）
count_gets() {
  PRE="$2" EXT="$3" awk '
    match($0, /"GET [^ ]+/) {
      path = substr($0, RSTART + 5, RLENGTH - 5)
      i = index(path, ENVIRON["PRE"])
      if (i == 0) next
      rest = substr(path, i + length(ENVIRON["PRE"]))
      if (ENVIRON["EXT"] == "" || rest ~ ENVIRON["EXT"]) n++
    }
    END { print n + 0 }' "$1"
}

# 本体の前に 1 回: athena-local に SELECT 1 を流して <id>.csv を作り、tls-proxy 経由で GET して、
# nginx のログに `GET /e2e-jdbc111/preflight/<id>.csv` の形で出るかを確かめる。出なければ判定の前提が崩れる。
check_nginx_log_format() {
  local body id state i n
  # ClientRequestToken は必須（athena-local も本物と同じく無いと INVALID_INPUT）。
  body=$(jq -n --arg o "s3://$BUCKET/$PREFIX_ROOT/preflight/" --arg t "issue111-preflight-$$-$(date +%s)" \
    '{QueryString: "SELECT 1 AS n", ClientRequestToken: $t, ResultConfiguration: {OutputLocation: $o}}')
  athena_call StartQueryExecution "$body" >"$OUT_ROOT/preflight-start.json"
  id=$(jq -r '.QueryExecutionId // empty' <"$OUT_ROOT/preflight-start.json")
  for i in $(seq 1 30); do
    state=$(athena_call GetQueryExecution "$(jq -n --arg id "$id" '{QueryExecutionId: $id}')" | jq -r '.QueryExecution.Status.State // empty')
    [ "$state" = "SUCCEEDED" ] && break
    sleep 1
  done
  if [ -z "$id" ] || [ "$state" != "SUCCEEDED" ]; then
    # athena-local が SELECT 1 を通せないのは athena-local 側の退行なので、未測定ではなく FAIL にする。
    record "nginx ログの形式" FAIL "athena-local が SELECT 1 を SUCCEEDED にしない（id=${id:-無し} state=${state:-無し}）"
    return 1
  fi
  curl -ks -o /dev/null "https://127.0.0.1:9443/$PREFIX_ROOT/preflight/$id.csv" -H "Host: $BUCKET.tls-proxy"
  sleep 1
  dc logs --no-color tls-proxy >"$OUT_ROOT/nginx-preflight.log" 2>&1
  n=$(grep -cF "GET /$PREFIX_ROOT/preflight/$id.csv" "$OUT_ROOT/nginx-preflight.log")
  if [ "${n:-0}" -lt 1 ]; then
    record "nginx ログの形式" SKIP "未測定: 既知の GET がログに出ない（全体を止める。ログ: $OUT_ROOT/nginx-preflight.log）"
    return 1
  fi
  record "nginx ログの形式" PASS "GET /$PREFIX_ROOT/preflight/$id.csv が $n 件出た"
}

# $1 = JVM の出力, $2 = fetcher の表示（未指定は -）, $3 = シナリオ, $4 = URL, $5 = OutputLocation
check_config() {
  local want="CONFIG fetcher=$2 scenario=$3 url=$4 output=$5" got
  got=$(grep -m1 '^CONFIG ' "$1")
  [ "$got" = "$want" ] && return 0
  JUDGE_DETAIL="引数の受け渡しの誤り: 要求「$want」/ 実際「${got:-（CONFIG 行が無い）}」"
  return 1
}

failures_of() { grep -o 'failures=[0-9]*' "$1" | tail -1 | cut -d= -f2; }

# (6): 合否は SHOW 3 行の status と、その回の接頭辞の下の `.txt.metadata` を実際に取りに行ったか（nginx の GET）で決める。
# `ResultFetcher=S3` はどの版も `.txt.metadata` を取りに行かない（GET 0 件）ので、SHOW が通っても「読めた」とは言えず INFO。
# 準備の失敗（3.5.0 以下の既知の NoSuchKey）は INFO で別に数える。$3 = 接頭辞, $4 = nginx のログ。
judge_57() {
  local out="$1" id="$2" prefix="$3" nlog="$4" label line st pass=0 bad="" setup nsk meta
  for label in "${SHOW_LABELS[@]}"; do
    line=$(grep -m1 -F "RESULT $label rows=" "$out")
    st=${line##*status=}
    if [ "$st" = "PASS" ]; then pass=$((pass + 1)); else bad+="$label=${st:-無し} "; fi
  done
  setup=$(grep -c '^\[setup\] 失敗' "$out")
  nsk=$(grep -c 'NoSuchKey' "$out")
  if [ "$setup" -gt 0 ]; then
    record "$id 準備" INFO "[setup] 失敗 $setup 件（NoSuchKey の出現 $nsk 行。既知: docs/result-files.md:155）"
  fi
  meta=$(count_gets "$nlog" "$prefix" '\.txt\.metadata')
  JUDGE_DETAIL="SHOW 3 行のうち PASS $pass ${bad:+（$bad）}failures=$(failures_of "$out") GET(.txt.metadata)=$meta 件"
  if [ "$pass" != "3" ]; then JUDGE_STATUS=FAIL
  elif [ "$meta" -ge 1 ]; then JUDGE_STATUS=PASS
  else JUDGE_STATUS=INFO; JUDGE_DETAIL="この fetcher は .txt.metadata を取りに行かない（読めるかは未測定）。$JUDGE_DETAIL"
  fi
}

# (3): 4 文とも SQLException（理由つき）、後続の SELECT 1 が通り、対照の .txt が 4 件あり、.txt* への GET が 0 件。
judge_111() {
  local out="$1" fetcher="$2" prefix="$3" nlog="$4" label line ok=0 bad="" sel=0 fl txt gets all
  for label in $FAILED_DDL_LABELS; do
    line=$(grep -m1 "^FAILED_DDL $label " "$out")
    if [[ "$line" == *" status=EXPECTED_SQLEXCEPTION msg="* ]] && grep -Eq "$REASON_RE" <<<"${line#*msg=}"; then
      ok=$((ok + 1))
    else
      bad+="$label "
    fi
  done
  grep -qF 'SELECT1_後続: 例外なし（PASS）' "$out" && sel=1
  fl=$(failures_of "$out")
  txt=$(mc_run "mc ls --recursive 'local/$BUCKET$prefix'" 2>/dev/null | awk '{print $NF}' | grep -c '\.txt$')
  gets=$(count_gets "$nlog" "$prefix" "$READ_EXT_RE")
  all=$(count_gets "$nlog" "$prefix" "")
  JUDGE_DETAIL="例外 $ok/4 ${bad:+（外れ: $bad）}SELECT1=$sel failures=${fl:-無し} .txt=$txt 件 GET(.txt*)=$gets 件 GET(全体)=$all 件"
  if [ "$ok" != "4" ] || [ "$sel" != "1" ] || [ "$fl" != "0" ]; then JUDGE_STATUS=FAIL
  elif [ "$txt" != "4" ]; then JUDGE_STATUS=SKIP; JUDGE_DETAIL="未測定: 対照の .txt が 4 件でない。$JUDGE_DETAIL"
  elif [ "$fetcher" != "GetQueryResults" ] && [ "$all" -lt 1 ]; then
    # PREFLIGHT と後続の SELECT 1 が必ず .csv を読むので、接頭辞への GET が 0 件なら nginx のログが取れていない。
    JUDGE_STATUS=SKIP; JUDGE_DETAIL="未測定: 接頭辞への GET が 0 件（nginx のログが取れていない）。$JUDGE_DETAIL"
  elif [ "$fetcher" = "GetQueryResults" ]; then JUDGE_STATUS=INFO; JUDGE_DETAIL="S3 を読まない対照。$JUDGE_DETAIL"
  elif [ "$gets" -ge 1 ]; then JUDGE_STATUS=FAIL
  else JUDGE_STATUS=PASS
  fi
}

# PREFLIGHT が失敗した回: その回の接頭辞への GET があれば S3 に届いてから処理できなかった（FAIL）、
# 無ければ接続の非互換（未測定の SKIP）。
# $4 = 版, $5 = fetcher。対照の版（3.8.1）と S3 を読まない GetQueryResults は接続の非互換があり得ないので、
# GET の数によらず FAIL（athena-local の応答の退行を SKIP で通さない。最終パスの指摘）。
judge_preflight_failed() {
  local out="$1" prefix="$2" nlog="$3" ver="${4:-}" fetcher="${5:-}" msg gets words
  msg=$(grep -m1 '^PREFLIGHT failed: ' "$out" | cut -c 19- | cut -c 1-200)
  gets=$(count_gets "$nlog" "$prefix" "")
  words=$(grep -ioE 'metadata|protobuf' "$out" | sort -u | tr '\n' ' ')
  if [ "$ver" = "${CONTROL_VERSION:-3.8.1}" ] || [ "$fetcher" = "GetQueryResults" ]; then
    JUDGE_STATUS=FAIL
    JUDGE_DETAIL="PREFLIGHT 失敗（対照の版か S3 を読まない fetcher なので接続の非互換ではない）。例外: $msg ／スタックの語: ${words:-無し}"
  elif [ "$gets" -ge 1 ]; then
    JUDGE_STATUS=FAIL
    JUDGE_DETAIL="PREFLIGHT 失敗・接頭辞への GET $gets 件（S3 に届いたが処理できない）。例外: $msg ／スタックの語: ${words:-無し}"
  else
    JUDGE_STATUS=SKIP
    JUDGE_DETAIL="未測定: 接続の非互換（接頭辞への GET 0 件）。例外: $msg"
  fi
}

# JVM 1 回分の判定。JUDGE_STATUS と JUDGE_DETAIL に入れる。
# $1 = 版, $2 = fetcher（auto/S3/GetQueryResults）, $3 = シナリオ, $4 = 出力, $5 = rc, $6 = nginx のログ,
# $7 = 接頭辞, $8 = URL, $9 = OutputLocation
judge_run() {
  local flabel="$2"
  [ "$flabel" = "auto" ] && flabel="-"
  JUDGE_STATUS=FAIL
  if [ "$5" = "124" ]; then JUDGE_STATUS=SKIP; JUDGE_DETAIL="未測定: ハング（timeout ${JVM_TIMEOUT:-300} 秒）"; return; fi
  check_config "$4" "$flabel" "$3" "$8" "$9" || return
  if grep -q '^PREFLIGHT failed: ' "$4"; then judge_preflight_failed "$4" "$7" "$6" "$1" "$2"; return; fi
  if ! grep -q '^PREFLIGHT ok$' "$4"; then JUDGE_DETAIL="PREFLIGHT 行が無い（rc=$5）"; return; fi
  case "$3" in
    46) JUDGE_DETAIL="rc=$5 failures=$(failures_of "$4")"
        [ "$5" = "0" ] && [ "$(failures_of "$4")" = "0" ] && JUDGE_STATUS=PASS ;;
    57) judge_57 "$4" "$1 $2/57" "$7" "$6" ;;
    111) judge_111 "$4" "$2" "$7" "$6" ;;
    *) JUDGE_DETAIL="知らないシナリオ $3" ;;
  esac
}

print_summary() {
  local cols=(auto:46 S3:46 GetQueryResults:46 auto:57 S3:57 GetQueryResults:57 auto:111 S3:111 GetQueryResults:111)
  local ver c i fails=0
  echo
  echo "==================== issue #111 旧版 Athena JDBC の行列 ===================="
  printf '%-8s' "版"
  for c in "${cols[@]}"; do printf ' %-9s' "${c/GetQueryResults/GQR}"; done
  echo
  for ver in $DRIVER_VERSIONS; do
    printf '%-8s' "$ver"
    for c in "${cols[@]}"; do printf ' %-9s' "${CELL[$ver|${c%%:*}|${c##*:}]:--}"; done
    echo
  done
  echo
  for i in "${!RESULT_NAMES[@]}"; do
    printf '%-5s %-28s %s\n' "${RESULT_STATUS[$i]}" "${RESULT_NAMES[$i]}" "${RESULT_DETAIL[$i]}"
    [ "${RESULT_STATUS[$i]}" = "FAIL" ] && fails=$((fails + 1))
  done
  echo
  echo "FAIL: $fails 件（INFO と SKIP は数えない）。証跡: $OUT_ROOT"
  SUMMARY_FAILS=$fails
}
