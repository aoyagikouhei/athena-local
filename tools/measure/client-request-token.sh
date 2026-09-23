#!/usr/bin/env bash
# issue #3 で作成（tools/ へ移す前の名前は 3-measure-client-request-token.sh）
# 本物の Athena で、ClientRequestToken（StartQueryExecution の冪等性）の挙動を実測する（issue #3）。
#
# 使い方:
#   DB=<データベース名> OUTPUT=s3://<バケット>/<プレフィックス>/ \
#     bash client-request-token.sh
#
# 必須の環境変数（どちらか片方でも無ければ、何も実行せず使い方を出して終了する）:
#   DB      StartQueryExecution の QueryExecutionContext.Database に使うデータベース名
#   OUTPUT  StartQueryExecution の ResultConfiguration.OutputLocation（s3://bucket/prefix/）
#
# 任意の環境変数:
#   REGION            既定 ap-northeast-1
#   WORKGROUP         既定 primary。基準として使うワークグループ
#   WORKGROUP2        WorkGroup を変えたときの挙動（項目2）を測るための、実在する別のワーク
#                      グループ名。省略するとその項目だけ skip する。存在しない名前を使うと、
#                      トークンの不一致より先に「ワークグループが無い」エラーになりかねない
#                      ため、実在の名前が要る
#   DB2               QueryExecutionContext.Database を変えたとき（項目2）に使う値。既定は
#                      "<DB>_athena_local_probe"。実在しなくてよい（不一致の検出がクエリの
#                      実行より前に働くかを見るのが目的なので、存在確認までは進まない想定）
#   OUTPUT2           ResultConfiguration.OutputLocation を変えたとき（項目2）に使う値。既定は
#                      OUTPUT の末尾に "athena_local_probe/" を足した値。同じく実在しなくてよい
#   QUERY_BASELINE    軽い基準クエリ。既定 "SELECT 1"
#   QUERY_CHANGED     QueryString を変えたとき（項目2）に使うクエリ。既定 "SELECT 2"
#   QUERY_WITH_PARAM  ExecutionParameters を測る（項目2）ためのクエリ。既定 "SELECT ? AS v"
#   LONG_QUERY_SQL    項目1（冪等性）と CANCELLED の後の再送に使う、数秒かかるが安いクエリ。
#                      既定は UNNEST(sequence(...)) 同士の CROSS JOIN を数えるだけで、S3 上の
#                      テーブルを一切スキャンしない（スキャン量0バイト = Athena の最小課金の
#                      み）。速すぎて2回目が「実行中」や「取り消し」に間に合わない、または
#                      逆に遅すぎる場合は差し替える
#   FAIL_QUERY_SQL    FAILED の後の再送に使う、構文は正しいが実行時に失敗するクエリ。既定は
#                      $DB の中に存在しないはずのテーブル名への SELECT
#   SYNTAX_ERROR_SQL  構文エラーのトークン使い回しに使う、構文的に壊れた SQL。既定 "SELEC 1"
#   POLL_TIMEOUT      GetQueryExecution のポーリング上限秒。既定 120。超えたら諦めて summary
#                      にその旨を書く
#   TTL_WAIT          項目6（トークンの有効期間）で、終了後に待つ秒数。既定 60。0 なら skip
#   OUT_DIR           既定 $HOME/athena-client-request-token-measurements
#                      （実名が入るのでリポジトリの外に出す）
#
# python3 + botocore が要る項目（項目3・項目4）:
#   - AWS CLI（botocore）が32文字未満のトークンをクライアント側のパラメータ検証で送信前に
#     拒否し、トークン省略時は自動で UUID を入れてしまうため、この2項目は CLI からはそも
#     そも測れない（実測して確認済み）。同じディレクトリの raw-client-request-token.py に、
#     SigV4 を自前で署名した生 HTTP リクエストで送る処理を切り出してあり、そちらを呼ぶ。
#   - 呼び出し方法は3通り試す。`uv`（https://docs.astral.sh/uv/）があれば
#     `uv run --with botocore python3 raw-client-request-token.py ...` で都度 botocore 入りの
#     環境を作る。無く、システムの python3 に botocore が既に入っていればそれを使う。
#     どちらも無ければ $RUN_DIR に venv を作って botocore を入れる（`pip install botocore`
#     と同じことを自動でやる）。それも失敗したらこの2項目だけ skip して summary に書く。
#     aws CLI 同梱の python では動かないことがあるので注意。
#
# 実行ごとに $OUT_DIR/run-<日時>/ を作り、その中だけに書く。前の回の結果と混ざらない。
#
# 前回（issue #1, #2）の実測でつまずいた点を踏襲する。
#   - aws が Docker のラッパだと、aws 自身にファイルへ書かせるとコンテナの中に書いて消え、
#     しかも終了コードは 0 になる。このスクリプトでは aws に直接ファイルへ書かせず、常に
#     `aws ... > file` の形でこのシェル自身がリダイレクトする。
#   - バケット名・データベース名・アカウント ID・ワークグループ名などの実名は端末に出さず、
#     ファイルに置くだけにする。summary.txt も実名を含まない形にする（DB・OUTPUT・DB2・
#     OUTPUT2・WORKGROUP・WORKGROUP2 の値と、12桁の数列は <DB> 等のプレースホルダに置き換える）。
#   - --debug の生ログや SigV4 の署名にはリクエスト側の Authorization ヘッダと Access Key ID
#     が入るので、応答側（や送信したトークンの値）だけを抜いたら生ログは消す。途中で止めて
#     も残らないよう trap も張る。
#
# 測る項目（GitHub issue #3「実装の前に本物の Athena で測ること」より）。
#   1. 同じトークン・同じパラメータで2回 StartQueryExecution を呼んだときに同じ
#      QueryExecutionId が返るか。実行中（数秒かかる LONG_QUERY_SQL を使い、2回目は間を
#      置かず投げる）と、終了後（SUCCEEDED を待ってから3回目も）の両方で測る。
#   2. 同じトークンでパラメータを1項目だけ変えたときのエラー。QueryString /
#      QueryExecutionContext(Database) / ResultConfiguration(OutputLocation) / WorkGroup /
#      ExecutionParameters を、それぞれ独立したトークンから「1回目=基準、2回目=その項目
#      だけ変える」で測る。
#   3. トークンの長さの境界（31 / 32 / 128 / 129 文字）で返るエラーか成功か。生 HTTP 経由。
#   4. トークンを付けずに呼んだときの挙動。
#        (a) CLI が自動生成する値を --debug から採る（UUID かどうか）。
#        (b) 生 HTTP 経由で、本当にトークン無し（および空文字）のリクエストを送る。
#   5. 構文エラーで弾かれたリクエストのトークンを、正しい SQL で使い回したときの挙動。
#   6. トークンの有効期間。終了後 TTL_WAIT 秒たってから同じトークンで投げ、同じ
#      QueryExecutionId が返るかを1回だけ測る（測れる範囲であることを summary に明記する）。
#
# 追加（issue 本文には無いが、実装時に必ず判断が要るためユーザー承認済みで追加）:
#   - FAILED の後、同じトークン・同じパラメータで再送したときの挙動。
#   - CANCELLED の後、同じトークン・同じパラメータで再送したときの挙動。
#   - これらと項目5・項目1を、「トークンが消費される条件」という1つの表に summary でまとめる。
#
# 保存するファイル（すべて $RUN_DIR の中。<label> ごとに .stdout.json / .stderr.txt、
# エラーで --debug も採ったものはさらに .wire.txt。生 HTTP 経由のものは .json / .stderr.txt）。
#   idempotent-running-a / -b、idempotent-running-a-state、idempotent-after-c   項目1
#   diff-<querystring|database|outputlocation|workgroup|executionparameters>
#     -base / -changed                                                          項目2
#   raw-token-omit、raw-token-empty、raw-token-len-<31|32|128|129>              項目3・4
#   no-token-cli.auto-token.txt                                                 項目4(a)
#   syntax-error-reuse-bad / -good                                              項目5
#   failed-after-first / -reuse、cancelled-after-first / -reuse / -stop         追加項目
#   ttl-wait-first / -second                                                    項目6
#   summary.txt                                    実名を含まない要約。そのまま貼れる。
#
# 課金について: 既定のクエリはすべて「SELECT 1」相当か、UNNEST(sequence(...)) のような
# S3 を一切スキャンしない計算だけで、実行のたびに Athena の最小課金（10MB 相当）以上は
# 増えない見込み。ただしこのスクリプトは本物の Athena に対して StartQueryExecution を
# 30回前後呼ぶ。テーブルの作成・削除は行わない（DDL を投げない）。

set -uo pipefail

if [ -z "${DB:-}" ] || [ -z "${OUTPUT:-}" ]; then
  cat <<'USAGE'
使い方:
  DB=<データベース名> OUTPUT=s3://<バケット>/<プレフィックス>/ \
    bash client-request-token.sh

DB と OUTPUT は必須です（どちらか片方でも無いと何も実行しません）。
任意の環境変数はスクリプト冒頭のコメントを参照してください。
USAGE
  exit 1
fi

REGION=${REGION:-ap-northeast-1}
WORKGROUP=${WORKGROUP:-primary}
WORKGROUP2=${WORKGROUP2:-}
DB2=${DB2:-"${DB}_athena_local_probe"}
OUTPUT2=${OUTPUT2:-"${OUTPUT%/}athena_local_probe/"}
QUERY_BASELINE=${QUERY_BASELINE:-"SELECT 1"}
QUERY_CHANGED=${QUERY_CHANGED:-"SELECT 2"}
QUERY_WITH_PARAM=${QUERY_WITH_PARAM:-"SELECT ? AS v"}
LONG_QUERY_SQL=${LONG_QUERY_SQL:-"SELECT count(*) FROM UNNEST(sequence(1, 5000)) AS a(x) CROSS JOIN UNNEST(sequence(1, 5000)) AS b(y)"}
FAIL_QUERY_SQL=${FAIL_QUERY_SQL:-"SELECT * FROM athena_local_nonexistent_table_probe"}
SYNTAX_ERROR_SQL=${SYNTAX_ERROR_SQL:-"SELEC 1"}
POLL_TIMEOUT=${POLL_TIMEOUT:-120}
TTL_WAIT=${TTL_WAIT:-60}
OUT_DIR=${OUT_DIR:-$HOME/athena-client-request-token-measurements}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAW_SCRIPT="$SCRIPT_DIR/raw-client-request-token.py"

RUN_DIR="$OUT_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
SUMMARY="$RUN_DIR/summary.txt"
: > "$SUMMARY"
echo "出力先: $RUN_DIR"

# 生 HTTP 経由の項目（3・4）で使う python + botocore の実行方法を決める。「使えるか」は
# 実際に `<候補> -c "import botocore..."` を通して確かめる（コマンドが存在するかどうかで
# は判断しない）。候補は順に: (a) システムの python3、(b) `uv`（`uv --version` の出力が
# `uv <数字>` で始まるときだけ。**このホストには `uv` という名前の、astral の uv とは
# 無関係な独自コマンドがあり、名前だけで判断すると誤動作する**ため）、(c) $RUN_DIR に
# 作る venv。どれも使えなければ、生 HTTP の節は skip し、試した候補と失敗理由を summary
# に書く。
PY_RUNNER=()
PY_RUNNER_LOG=()
if [ ! -f "$RAW_SCRIPT" ]; then
  PY_RUNNER_LOG+=("$RAW_SCRIPT が見つからない")
  echo "見つかりません: $RAW_SCRIPT（raw-client-request-token.py と同じディレクトリに置いてください）。生 HTTP 経由の項目は skip します"
elif python3 -c "import botocore.session, botocore.auth, botocore.awsrequest" >/dev/null 2>&1; then
  PY_RUNNER=(python3)
  echo "python 実行方法: システムの python3（botocore は既に入っています）"
else
  PY_RUNNER_LOG+=("システムの python3: botocore を import できない")
  if command -v uv >/dev/null 2>&1; then
    uv_version=$(uv --version 2>/dev/null | head -1)
    if printf '%s' "$uv_version" | grep -qE '^uv [0-9]'; then
      if uv run --with botocore python3 -c "import botocore.session, botocore.auth, botocore.awsrequest" >/dev/null 2>&1; then
        PY_RUNNER=(uv run --with botocore python3)
        echo "python 実行方法: uv run --with botocore python3（astral の uv、${uv_version}）"
      else
        PY_RUNNER_LOG+=("uv run --with botocore python3: astral の uv（${uv_version}）のようだが import に失敗")
      fi
    else
      PY_RUNNER_LOG+=("「uv」というコマンドはあるが astral の uv ではないようだ（uv --version = ${uv_version:-出力なし}）。使わない")
    fi
  else
    PY_RUNNER_LOG+=("uv コマンドが見つからない")
  fi

  if [ "${#PY_RUNNER[@]}" -eq 0 ]; then
    echo "venv を作って botocore を入れます"
    if python3 -m venv "$RUN_DIR/.venv-botocore" > "$RUN_DIR/.tmp-venv-setup.log" 2>&1 \
      && "$RUN_DIR/.venv-botocore/bin/pip" install --quiet botocore >> "$RUN_DIR/.tmp-venv-setup.log" 2>&1 \
      && "$RUN_DIR/.venv-botocore/bin/python3" -c "import botocore.session, botocore.auth, botocore.awsrequest" >/dev/null 2>&1; then
      PY_RUNNER=("$RUN_DIR/.venv-botocore/bin/python3")
      echo "python 実行方法: venv に botocore を入れました"
    else
      PY_RUNNER_LOG+=("venv + pip install botocore: 失敗（詳細は破棄済みの一時ログ）")
    fi
  fi
fi
if [ "${#PY_RUNNER[@]}" -eq 0 ]; then
  echo "botocore を用意できませんでした。生 HTTP 経由の項目は skip します"
fi

# 実名（DB・OUTPUT・DB2・OUTPUT2・WORKGROUP・WORKGROUP2、12桁のアカウント ID らしき数列）
# を summary に書く前にプレースホルダへ置き換える。エラー文言に紛れ込む保険で、通常の
# 項目名や真偽値・ステータスコードには影響しない。
mask() {
  local s=$1
  [ -n "$DB2" ] && s=${s//$DB2/<DB2>}
  [ -n "$DB" ] && s=${s//$DB/<DB>}
  [ -n "$OUTPUT2" ] && s=${s//$OUTPUT2/<OUTPUT2>}
  [ -n "$OUTPUT" ] && s=${s//$OUTPUT/<OUTPUT>}
  [ -n "$WORKGROUP" ] && s=${s//$WORKGROUP/<WORKGROUP>}
  [ -n "$WORKGROUP2" ] && s=${s//$WORKGROUP2/<WORKGROUP2>}
  printf '%s' "$s" | sed -E 's/[0-9]{12}/<ACCOUNT_ID>/g'
}

# --debug の生ログから、応答ヘッダとボディと HTTP ステータスだけを抜き出す
# （get-work-group.sh の capture_wire と同じ）。
capture_wire() {
  local label=$1
  shift
  local raw="$RUN_DIR/.$label-debug-raw.tmp"
  "$@" --debug > "$raw" 2>&1
  {
    grep -E 'Response headers:' "$raw"
    grep -A1 -E 'Response body:' "$raw"
    grep -E '"[A-Z]+ / HTTP/[0-9.]+" [0-9]{3}' "$raw"
  } > "$RUN_DIR/$label.wire.txt" 2>/dev/null
  rm -f "$raw"
}

# 生ログや中間ファイルは、途中で止めても残らないよう trap でも消す。
trap 'rm -f "$RUN_DIR"/.*-debug-raw.tmp "$RUN_DIR"/.tmp-*; rm -rf "$RUN_DIR"/.venv-botocore' EXIT

# label.wire.txt から HTTP ステータス・x-amzn-errortype・__type・AthenaErrorCode・message を
# 抜き出し、summary に [prefix] 付きで書く（get-work-group.sh のエラー抽出と同じ形）。
report_wire_error() {
  local label=$1 prefix=$2
  local wire="$RUN_DIR/$label.wire.txt"
  if [ -s "$wire" ]; then
    local http_status errortype dunder_type athena_error_code message
    http_status=$(grep -oE '"[A-Z]+ / HTTP/[0-9.]+" [0-9]{3}' "$wire" | grep -oE '[0-9]{3}$' | head -1)
    errortype=$(grep -oE "'x-amzn-errortype':[[:space:]]*'[^']*'" "$wire" | head -1 | sed -E "s/.*:[[:space:]]*'([^']*)'/\1/")
    dunder_type=$(grep -oiE '"__type"[[:space:]]*:[[:space:]]*"[^"]*"' "$wire" | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
    athena_error_code=$(grep -oiE '"AthenaErrorCode"[[:space:]]*:[[:space:]]*"[^"]*"' "$wire" | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
    message=$(grep -oiE '"message"[[:space:]]*:[[:space:]]*"[^"]*"' "$wire" | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
    {
      printf '[%s] HTTP ステータス = %s\n' "$prefix" "${http_status:-(採取できず)}"
      printf '[%s] x-amzn-errortype ヘッダ = %s\n' "$prefix" "${errortype:-(採取できず)}"
      printf '[%s] __type = %s\n' "$prefix" "${dunder_type:-(採取できず)}"
      printf '[%s] AthenaErrorCode = %s\n' "$prefix" "${athena_error_code:-(無し)}"
      printf '[%s] message = %s\n' "$prefix" "$(mask "${message:-(採取できず)}")"
    } >> "$SUMMARY"
  else
    printf '[%s] --debug からのワイヤ形式の採取に失敗（ログ形式差の可能性）\n' "$prefix" >> "$SUMMARY"
  fi
}

# report_wire_error と同じ label.wire.txt から、summary に書かず1行にまとめて返すだけの版。
# 「トークンが消費される条件」表のセルに使う。
wire_error_oneline() {
  local label=$1
  local wire="$RUN_DIR/$label.wire.txt"
  if [ -s "$wire" ]; then
    local dunder_type athena_error_code message
    dunder_type=$(grep -oiE '"__type"[[:space:]]*:[[:space:]]*"[^"]*"' "$wire" | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
    athena_error_code=$(grep -oiE '"AthenaErrorCode"[[:space:]]*:[[:space:]]*"[^"]*"' "$wire" | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
    message=$(grep -oiE '"message"[[:space:]]*:[[:space:]]*"[^"]*"' "$wire" | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')
    printf '__type=%s; AthenaErrorCode=%s; message=%s' "${dunder_type:-?}" "${athena_error_code:-無し}" "$(mask "${message:-?}")"
  else
    printf '(採取できず)'
  fi
}

# CLI の「An error occurred (...) when calling the ... operation: ...」行だけを抜く。
extract_cli_error_line() {
  grep -o 'An error occurred ([A-Za-z]*) when calling the [A-Za-z]* operation: .*' "$1" | head -1
}

# start-query-execution の応答 JSON から QueryExecutionId を抜く。
extract_id() {
  python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("QueryExecutionId", ""))
except Exception:
    print("")' "$1" 2>/dev/null
}

# 新しいトークンを1つ作る。
gen_token() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  else
    python3 -c 'import uuid; print(uuid.uuid4())'
  fi
}

# 指定した長さちょうどのトークン文字列を作る（項目3の境界値用）。UUID を連結して切り詰める。
make_token_of_length() {
  local n=$1
  local s=""
  while [ ${#s} -lt "$n" ]; do
    s="${s}$(gen_token)"
  done
  printf '%s' "${s:0:$n}"
}

# StartQueryExecution を呼び、応答とエラーをファイルに落とすだけ（--debug 無し）。
sqe_plain() {
  local label=$1
  shift
  aws athena start-query-execution --region "$REGION" "$@" \
    > "$RUN_DIR/$label.stdout.json" 2> "$RUN_DIR/$label.stderr.txt"
}

# StartQueryExecution を --debug 付きで呼び、ワイヤ形式を $label.wire.txt に落とす。
sqe_wire() {
  local label=$1
  shift
  capture_wire "$label" aws athena start-query-execution --region "$REGION" "$@"
}

# id が終端状態（SUCCEEDED/FAILED/CANCELLED）になるまで待つ。上限 timeout 秒。
# 終端状態の名前を返す。上限に達したら空文字を返す。
poll_until_terminal() {
  local id=$1 timeout=$2 waited=0 state=""
  while [ "$waited" -lt "$timeout" ]; do
    aws athena get-query-execution --region "$REGION" --query-execution-id "$id" \
      > "$RUN_DIR/.tmp-poll.json" 2>/dev/null
    state=$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1]))["QueryExecution"]["Status"]["State"])
except Exception:
    print("")' "$RUN_DIR/.tmp-poll.json" 2>/dev/null)
    case "$state" in
      SUCCEEDED | FAILED | CANCELLED) break ;;
    esac
    state=""
    sleep 2
    waited=$((waited + 2))
  done
  rm -f "$RUN_DIR/.tmp-poll.json"
  printf '%s' "$state"
}

# 項目2用: 同じトークンで「基準」→「1項目だけ変えた呼び出し」を行い、結果を summary に書く。
# 呼び出し前に、グローバル配列 BASE_ARGS / CHANGED_ARGS（aws athena start-query-execution に
# 渡す残りの引数）をセットしておくこと。
diff_case() {
  local field=$1 file_label=$2
  local token
  token=$(gen_token)

  sqe_plain "${file_label}-base" --client-request-token "$token" "${BASE_ARGS[@]}"
  if [ $? -ne 0 ]; then
    local err_line
    err_line=$(extract_cli_error_line "$RUN_DIR/${file_label}-base.stderr.txt")
    printf '[diff-%s] 基準呼び出し自体が失敗したため skip。CLI エラー = %s\n' "$field" "$(mask "$err_line")" >> "$SUMMARY"
    return
  fi
  local base_id
  base_id=$(extract_id "$RUN_DIR/${file_label}-base.stdout.json")

  sqe_plain "${file_label}-changed" --client-request-token "$token" "${CHANGED_ARGS[@]}"
  if [ $? -eq 0 ]; then
    local changed_id
    changed_id=$(extract_id "$RUN_DIR/${file_label}-changed.stdout.json")
    if [ -n "$changed_id" ] && [ "$base_id" = "$changed_id" ]; then
      printf '[diff-%s] 変えても成功し、QueryExecutionId は同じだった（不一致は検出されなかった）\n' "$field" >> "$SUMMARY"
    else
      printf '[diff-%s] 変えると成功したが、QueryExecutionId は違った（不一致エラーにはならなかった）\n' "$field" >> "$SUMMARY"
    fi
  else
    local err_line
    err_line=$(extract_cli_error_line "$RUN_DIR/${file_label}-changed.stderr.txt")
    printf '[diff-%s] 変えると CLI エラー = %s\n' "$field" "$(mask "$err_line")" >> "$SUMMARY"
    sqe_wire "${file_label}-changed" --client-request-token "$token" "${CHANGED_ARGS[@]}"
    report_wire_error "${file_label}-changed" "diff-$field"
  fi
}

# 「トークンが消費される条件」表に1行足す。$4（エラーの説明）はここでマスクせず生のまま
# 溜め、表を書き出す直前にまとめてマスクする（他の summary 出力と同じ「書く直前にマスク」
# という流儀に合わせるため）。"|" は markdown の表を壊すので "/" に潰す。
record_consumed() {
  local sanitized_err=${4//|//}
  printf '%s\x1f%s\x1f%s\x1f%s\n' "$1" "$2" "$3" "$sanitized_err" >> "$RUN_DIR/.tmp-consumed-table"
}

# 生 HTTP（SigV4 自前署名）で StartQueryExecution を1回呼ぶ。実体は raw-client-request-token.py
# （同じディレクトリの独立ファイル。client-request-token-extra.sh とも共有する）
# に切り出してあり、ここでは PY_RUNNER 経由で呼ぶだけ。AWS CLI（botocore）のクライアント側
# パラメータ検証や ClientRequestToken の自動生成を経由しないので、トークン無し・空文字・
# 32文字未満・128文字超もそのまま送れる。
#   $1 = ファイルラベル
#   $2 = トークンの扱い。"__OMIT__" なら ClientRequestToken を JSON に含めない。それ以外は
#        そのままの値を送る（空文字も可）
raw_start_query_execution() {
  local label=$1 token_mode=$2
  local out_json="$RUN_DIR/$label.json"
  "${PY_RUNNER[@]}" "$RAW_SCRIPT" "$REGION" "$DB" "$OUTPUT" "$WORKGROUP" "$QUERY_BASELINE" "$token_mode" "$out_json" \
    > "$RUN_DIR/$label.stdout.txt" 2> "$RUN_DIR/$label.stderr.txt"
}

# raw_start_query_execution が書いた $label.json を読み、summary に [prefix] 付きで書く。
report_raw_result() {
  local label=$1 prefix=$2
  local json="$RUN_DIR/$label.json"
  if [ ! -s "$json" ]; then
    # python が結果を書く前に終了している（起動できなかった、実行系の取り違えなど）。
    # HTTP 応答が返った場合や署名・送信の例外は json 側の outcome (error/exception) に
    # 乗るので、ここに来るのはそれより手前の失敗。
    local first_err
    first_err=$(head -1 "$RUN_DIR/$label.stderr.txt" 2>/dev/null)
    [ -z "$first_err" ] && first_err=$(head -1 "$RUN_DIR/$label.stdout.txt" 2>/dev/null)
    printf '[%s] 生 HTTP 呼び出しに失敗した（python が結果を書く前に終了。詳細は %s.stdout.txt / .stderr.txt。先頭行 = %s）\n' "$prefix" "$label" "$(mask "${first_err:-(空)}")" >> "$SUMMARY"
    return
  fi
  python3 - "$json" > "$RUN_DIR/.tmp-raw-summary" 2>/dev/null <<'PYEOF'
import json
import sys

path = sys.argv[1]
try:
    d = json.load(open(path))
except Exception as e:
    print("パースに失敗: {!r}".format(e))
    sys.exit(0)

outcome = d.get("outcome")
lines = ["結果 = {}".format(outcome)]
if outcome == "success":
    lines.append("HTTP ステータス = {}".format(d.get("status")))
    lines.append("QueryExecutionId 先頭8桁 = {}".format(str(d.get("query_execution_id", ""))[:8]))
elif outcome == "error":
    body = d.get("body") or ""
    try:
        b = json.loads(body)
    except Exception:
        b = {}
    headers = d.get("headers") or {}
    errtype_header = None
    for k, v in headers.items():
        if k.lower() == "x-amzn-errortype":
            errtype_header = v
    lines.append("HTTP ステータス = {}".format(d.get("status")))
    lines.append("__type = {}".format(b.get("__type")))
    lines.append("message = {}".format(b.get("message")))
    lines.append("AthenaErrorCode = {}".format(b.get("AthenaErrorCode")))
    lines.append("x-amzn-errortype ヘッダ = {}".format(errtype_header))
elif outcome == "no_credentials":
    lines.append("資格情報が見つからず送れなかった（AWS_* の環境変数や ~/.aws/credentials を確認してください）")
else:
    lines.append("例外 = {}".format(d.get("exception")))

print("\n".join(lines))
PYEOF
  while IFS= read -r line; do
    printf '[%s] %s\n' "$prefix" "$(mask "$line")" >> "$SUMMARY"
  done < "$RUN_DIR/.tmp-raw-summary"
  rm -f "$RUN_DIR/.tmp-raw-summary"
}

# raw_start_query_execution の結果が想定外に成功していたら、後片付けとして取り消す。
raw_maybe_stop() {
  local label=$1
  local json="$RUN_DIR/$label.json"
  [ -s "$json" ] || return
  local outcome qid
  outcome=$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("outcome", ""))
except Exception:
    print("")' "$json" 2>/dev/null)
  if [ "$outcome" = "success" ]; then
    qid=$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("query_execution_id", ""))
except Exception:
    print("")' "$json" 2>/dev/null)
    if [ -n "$qid" ]; then
      aws athena stop-query-execution --region "$REGION" --query-execution-id "$qid" >/dev/null 2>&1 || true
    fi
  fi
}

# ---- 1. 同じトークン・同じパラメータで2回（実行中・終了後）呼ぶ ----------------------

echo "== idempotent (実行中): 実行します"
token=$(gen_token)
sqe_plain idempotent-running-a --client-request-token "$token" \
  --query-string "$LONG_QUERY_SQL" \
  --query-execution-context "Database=$DB" \
  --result-configuration "OutputLocation=$OUTPUT" \
  --work-group "$WORKGROUP"
if [ $? -ne 0 ]; then
  err_line=$(extract_cli_error_line "$RUN_DIR/idempotent-running-a.stderr.txt")
  printf '[idempotent] 1回目の呼び出しが失敗したため項目1は skip。CLI エラー = %s\n' "$(mask "$err_line")" >> "$SUMMARY"
  record_consumed "実行中" "比較不可" "不明" "1回目の呼び出し自体が失敗"
  record_consumed "SUCCEEDED の後" "比較不可" "不明" "1回目の呼び出し自体が失敗"
else
  id_a=$(extract_id "$RUN_DIR/idempotent-running-a.stdout.json")

  # 1回目の応答を受け取ったら、間を置かずすぐ2回目を投げる。
  sqe_plain idempotent-running-b --client-request-token "$token" \
    --query-string "$LONG_QUERY_SQL" \
    --query-execution-context "Database=$DB" \
    --result-configuration "OutputLocation=$OUTPUT" \
    --work-group "$WORKGROUP"
  if [ $? -eq 0 ]; then
    id_b=$(extract_id "$RUN_DIR/idempotent-running-b.stdout.json")
    if [ -n "$id_a" ] && [ "$id_a" = "$id_b" ]; then
      printf '[idempotent-running] 実行中に同じトークンで呼ぶと同じ QueryExecutionId が返った\n' >> "$SUMMARY"
      record_consumed "実行中" "同じ" "いいえ" "-"
    else
      printf '[idempotent-running] 実行中に同じトークンで呼ぶと違う QueryExecutionId が返った\n' >> "$SUMMARY"
      record_consumed "実行中" "違う" "はい" "-"
    fi
  else
    err_line=$(extract_cli_error_line "$RUN_DIR/idempotent-running-b.stderr.txt")
    printf '[idempotent-running] 2回目の呼び出しがエラー = %s\n' "$(mask "$err_line")" >> "$SUMMARY"
    sqe_wire idempotent-running-b --client-request-token "$token" \
      --query-string "$LONG_QUERY_SQL" \
      --query-execution-context "Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" \
      --work-group "$WORKGROUP"
    report_wire_error idempotent-running-b idempotent-running-b
    record_consumed "実行中" "比較不可" "いいえ" "$(wire_error_oneline idempotent-running-b)"
  fi

  # 2回目を投げた直後の1回目の State を参考として記録する（まだ実行中かどうか）。
  aws athena get-query-execution --region "$REGION" --query-execution-id "$id_a" \
    > "$RUN_DIR/idempotent-running-a-state.json" 2> "$RUN_DIR/idempotent-running-a-state.stderr.txt"
  state_now=$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1]))["QueryExecution"]["Status"]["State"])
except Exception:
    print("")' "$RUN_DIR/idempotent-running-a-state.json" 2>/dev/null)
  printf '[idempotent-running] 2回目を投げた直後の1回目の State = %s\n' "${state_now:-(採取できず)}" >> "$SUMMARY"

  echo "== idempotent (終了後): 1回目の終了を待ちます（上限 ${POLL_TIMEOUT} 秒）"
  final_state=$(poll_until_terminal "$id_a" "$POLL_TIMEOUT")
  if [ -n "$final_state" ]; then
    printf '[idempotent-after] 1回目の最終 State = %s\n' "$final_state" >> "$SUMMARY"

    sqe_plain idempotent-after-c --client-request-token "$token" \
      --query-string "$LONG_QUERY_SQL" \
      --query-execution-context "Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" \
      --work-group "$WORKGROUP"
    if [ $? -eq 0 ]; then
      id_c=$(extract_id "$RUN_DIR/idempotent-after-c.stdout.json")
      if [ -n "$id_a" ] && [ "$id_a" = "$id_c" ]; then
        printf '[idempotent-after] 終了後に同じトークンで呼ぶ(3回目)と同じ QueryExecutionId が返った\n' >> "$SUMMARY"
        record_consumed "SUCCEEDED の後" "同じ" "いいえ" "-"
      else
        printf '[idempotent-after] 終了後に同じトークンで呼ぶ(3回目)と違う QueryExecutionId が返った\n' >> "$SUMMARY"
        record_consumed "SUCCEEDED の後" "違う" "はい" "-"
      fi
    else
      err_line=$(extract_cli_error_line "$RUN_DIR/idempotent-after-c.stderr.txt")
      printf '[idempotent-after] 3回目の呼び出しがエラー = %s\n' "$(mask "$err_line")" >> "$SUMMARY"
      sqe_wire idempotent-after-c --client-request-token "$token" \
        --query-string "$LONG_QUERY_SQL" \
        --query-execution-context "Database=$DB" \
        --result-configuration "OutputLocation=$OUTPUT" \
        --work-group "$WORKGROUP"
      report_wire_error idempotent-after-c idempotent-after-c
      record_consumed "SUCCEEDED の後" "比較不可" "いいえ" "$(wire_error_oneline idempotent-after-c)"
    fi
  else
    printf '[idempotent-after] 1回目が %s 秒以内に終了状態にならなかったため終了後の測定は skip\n' "$POLL_TIMEOUT" >> "$SUMMARY"
    record_consumed "SUCCEEDED の後" "比較不可" "不明" "1回目がポーリング上限内に終了しなかった"
  fi
fi

# ---- 2. 同じトークンでパラメータを1項目だけ変える -----------------------------------

echo "== diff-querystring: 実行します"
BASE_ARGS=(--query-string "$QUERY_BASELINE" --query-execution-context "Database=$DB" --result-configuration "OutputLocation=$OUTPUT" --work-group "$WORKGROUP")
CHANGED_ARGS=(--query-string "$QUERY_CHANGED" --query-execution-context "Database=$DB" --result-configuration "OutputLocation=$OUTPUT" --work-group "$WORKGROUP")
diff_case "QueryString" diff-querystring

echo "== diff-database: 実行します"
BASE_ARGS=(--query-string "$QUERY_BASELINE" --query-execution-context "Database=$DB" --result-configuration "OutputLocation=$OUTPUT" --work-group "$WORKGROUP")
CHANGED_ARGS=(--query-string "$QUERY_BASELINE" --query-execution-context "Database=$DB2" --result-configuration "OutputLocation=$OUTPUT" --work-group "$WORKGROUP")
diff_case "Database" diff-database

echo "== diff-outputlocation: 実行します"
BASE_ARGS=(--query-string "$QUERY_BASELINE" --query-execution-context "Database=$DB" --result-configuration "OutputLocation=$OUTPUT" --work-group "$WORKGROUP")
CHANGED_ARGS=(--query-string "$QUERY_BASELINE" --query-execution-context "Database=$DB" --result-configuration "OutputLocation=$OUTPUT2" --work-group "$WORKGROUP")
diff_case "OutputLocation" diff-outputlocation

if [ -n "$WORKGROUP2" ]; then
  echo "== diff-workgroup: 実行します"
  BASE_ARGS=(--query-string "$QUERY_BASELINE" --query-execution-context "Database=$DB" --result-configuration "OutputLocation=$OUTPUT" --work-group "$WORKGROUP")
  CHANGED_ARGS=(--query-string "$QUERY_BASELINE" --query-execution-context "Database=$DB" --result-configuration "OutputLocation=$OUTPUT" --work-group "$WORKGROUP2")
  diff_case "WorkGroup" diff-workgroup
else
  echo "== diff-workgroup: skip (WORKGROUP2 が未設定)"
  printf '[diff-WorkGroup] skip (WORKGROUP2 が未設定。実在するワークグループが無いと、トークンの不一致より先にワークグループ不在のエラーになりうるため)\n' >> "$SUMMARY"
fi

echo "== diff-executionparameters: 実行します"
BASE_ARGS=(--query-string "$QUERY_WITH_PARAM" --query-execution-context "Database=$DB" --result-configuration "OutputLocation=$OUTPUT" --work-group "$WORKGROUP" --execution-parameters '["1"]')
CHANGED_ARGS=(--query-string "$QUERY_WITH_PARAM" --query-execution-context "Database=$DB" --result-configuration "OutputLocation=$OUTPUT" --work-group "$WORKGROUP" --execution-parameters '["2"]')
diff_case "ExecutionParameters" diff-executionparameters

# ---- 3・4. トークンの長さの境界とトークン無し（生 HTTP、SigV4 自前署名） ---------------
#
# AWS CLI（botocore 経由）は、32文字未満のトークンをパラメータ検証でクライアント側で拒否
# し、トークンを省略すると自動で UUID を入れてしまうため、この2項目は CLI からは測れない
# （この環境で偽エンドポイントに向けて実測して確認済み）。SigV4 で自前署名した生 HTTP
# リクエストで、botocore のパラメータ検証にも自動生成にも通らない形で送る。

echo "== no-token-cli (CLI が自動生成する値の形式): 実行します"
raw="$RUN_DIR/.tmp-no-token-cli-debug-raw"
aws athena start-query-execution --region "$REGION" \
  --query-string "$QUERY_BASELINE" \
  --query-execution-context "Database=$DB" \
  --result-configuration "OutputLocation=$OUTPUT" \
  --work-group "$WORKGROUP" \
  --debug > "$raw" 2>&1
auto_token=$(grep -oE '"ClientRequestToken":[[:space:]]*"[^"]*"' "$raw" | head -1 | sed -E 's/.*"([^"]*)"$/\1/')
rm -f "$raw"
if [ -n "$auto_token" ]; then
  printf '%s\n' "$auto_token" > "$RUN_DIR/no-token-cli.auto-token.txt"
  if printf '%s' "$auto_token" | grep -qE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
    printf '[no-token-cli] CLI は自動でトークンを入れる。形式 = UUID（長さ=%s）\n' "${#auto_token}" >> "$SUMMARY"
  else
    printf '[no-token-cli] CLI は自動でトークンを入れる。形式 = UUID ではない（長さ=%s）\n' "${#auto_token}" >> "$SUMMARY"
  fi
else
  printf '[no-token-cli] --debug からトークンを採取できなかった（ログ形式差の可能性）\n' >> "$SUMMARY"
fi

if [ "${#PY_RUNNER[@]}" -gt 0 ]; then
  echo "== raw-token-omit (トークン無し、生 HTTP): 実行します"
  raw_start_query_execution raw-token-omit "__OMIT__"
  report_raw_result raw-token-omit raw-token-omit
  raw_maybe_stop raw-token-omit

  echo "== raw-token-empty (空文字、生 HTTP): 実行します"
  raw_start_query_execution raw-token-empty ""
  report_raw_result raw-token-empty raw-token-empty
  raw_maybe_stop raw-token-empty

  for n in 31 32 128 129; do
    label="raw-token-len-$n"
    echo "== $label: 実行します"
    token=$(make_token_of_length "$n")
    raw_start_query_execution "$label" "$token"
    report_raw_result "$label" "$label"
    raw_maybe_stop "$label"
  done
else
  echo "== raw-token-* (生 HTTP 経由の項目): skip (botocore を用意できませんでした)"
  printf '[raw-token] skip (botocore を用意できなかったため未測定)\n' >> "$SUMMARY"
  for entry in "${PY_RUNNER_LOG[@]:-}"; do
    [ -n "$entry" ] && printf '[raw-token] 試した候補: %s\n' "$entry" >> "$SUMMARY"
  done
fi

# ---- 5. 構文エラーで弾かれたトークンの使い回し ----------------------------------------

echo "== syntax-error-reuse: 実行します"
token=$(gen_token)
bad_id=""
sqe_plain syntax-error-reuse-bad --client-request-token "$token" \
  --query-string "$SYNTAX_ERROR_SQL" \
  --query-execution-context "Database=$DB" \
  --result-configuration "OutputLocation=$OUTPUT" \
  --work-group "$WORKGROUP"
if [ $? -eq 0 ]; then
  bad_id=$(extract_id "$RUN_DIR/syntax-error-reuse-bad.stdout.json")
  printf '[syntax-error-reuse] 1回目（構文エラーの SQL）が想定外に成功した。QueryExecutionId 先頭8桁=%s\n' "${bad_id:0:8}" >> "$SUMMARY"
else
  err_line=$(extract_cli_error_line "$RUN_DIR/syntax-error-reuse-bad.stderr.txt")
  printf '[syntax-error-reuse] 1回目（構文エラーの SQL） = CLI エラー = %s\n' "$(mask "$err_line")" >> "$SUMMARY"
fi

sqe_plain syntax-error-reuse-good --client-request-token "$token" \
  --query-string "$QUERY_BASELINE" \
  --query-execution-context "Database=$DB" \
  --result-configuration "OutputLocation=$OUTPUT" \
  --work-group "$WORKGROUP"
if [ $? -eq 0 ]; then
  good_id=$(extract_id "$RUN_DIR/syntax-error-reuse-good.stdout.json")
  printf '[syntax-error-reuse] 同じトークンで正しい SQL を投げたら成功した。QueryExecutionId 先頭8桁=%s\n' "${good_id:0:8}" >> "$SUMMARY"
  if [ -n "$bad_id" ]; then
    if [ "$bad_id" = "$good_id" ]; then
      printf '[syntax-error-reuse] 1回目と2回目の QueryExecutionId は同じだった\n' >> "$SUMMARY"
      record_consumed "構文エラーで弾かれた後" "同じ" "いいえ" "-"
    else
      printf '[syntax-error-reuse] 1回目と2回目の QueryExecutionId は違った\n' >> "$SUMMARY"
      record_consumed "構文エラーで弾かれた後" "違う" "はい" "-"
    fi
  else
    # 1回目は QueryExecutionId を持たない（想定どおり構文エラーで弾かれた）ので比較はできないが、
    # 2回目が成功した = 同じトークンで新しい実行が作れたということ。
    record_consumed "構文エラーで弾かれた後" "比較不可(1回目にIDが無い)" "はい" "-"
  fi
else
  err_line=$(extract_cli_error_line "$RUN_DIR/syntax-error-reuse-good.stderr.txt")
  printf '[syntax-error-reuse] 同じトークンで正しい SQL を投げてもエラー = %s\n' "$(mask "$err_line")" >> "$SUMMARY"
  sqe_wire syntax-error-reuse-good --client-request-token "$token" \
    --query-string "$QUERY_BASELINE" \
    --query-execution-context "Database=$DB" \
    --result-configuration "OutputLocation=$OUTPUT" \
    --work-group "$WORKGROUP"
  report_wire_error syntax-error-reuse-good syntax-error-reuse-good
  record_consumed "構文エラーで弾かれた後" "比較不可" "いいえ" "$(wire_error_oneline syntax-error-reuse-good)"
fi

# ---- 追加（ユーザー承認済み）: FAILED / CANCELLED の後にトークンを使い回す ------------

echo "== failed-after-reuse: 実行します"
token=$(gen_token)
sqe_plain failed-after-first --client-request-token "$token" \
  --query-string "$FAIL_QUERY_SQL" \
  --query-execution-context "Database=$DB" \
  --result-configuration "OutputLocation=$OUTPUT" \
  --work-group "$WORKGROUP"
if [ $? -ne 0 ]; then
  err_line=$(extract_cli_error_line "$RUN_DIR/failed-after-first.stderr.txt")
  printf '[failed-after] 1回目（失敗するはずのクエリ）の呼び出し自体が失敗したため skip。CLI エラー = %s\n' "$(mask "$err_line")" >> "$SUMMARY"
  record_consumed "FAILED の後" "比較不可" "不明" "1回目の呼び出し自体が失敗"
else
  fail_id=$(extract_id "$RUN_DIR/failed-after-first.stdout.json")
  final_state=$(poll_until_terminal "$fail_id" "$POLL_TIMEOUT")
  printf '[failed-after] 1回目の最終 State = %s\n' "${final_state:-(ポーリング上限到達)}" >> "$SUMMARY"
  if [ "$final_state" != "FAILED" ]; then
    printf '[failed-after] 想定していた FAILED にならなかった（State=%s）。それでも同じトークンで再送します\n' "${final_state:-不明}" >> "$SUMMARY"
  fi

  sqe_plain failed-after-reuse --client-request-token "$token" \
    --query-string "$FAIL_QUERY_SQL" \
    --query-execution-context "Database=$DB" \
    --result-configuration "OutputLocation=$OUTPUT" \
    --work-group "$WORKGROUP"
  if [ $? -eq 0 ]; then
    reuse_id=$(extract_id "$RUN_DIR/failed-after-reuse.stdout.json")
    if [ -n "$fail_id" ] && [ "$fail_id" = "$reuse_id" ]; then
      printf '[failed-after] 再送は成功し、QueryExecutionId は同じだった\n' >> "$SUMMARY"
      record_consumed "FAILED の後" "同じ" "いいえ" "-"
    else
      printf '[failed-after] 再送は成功したが、QueryExecutionId は違った\n' >> "$SUMMARY"
      record_consumed "FAILED の後" "違う" "はい" "-"
    fi
  else
    err_line=$(extract_cli_error_line "$RUN_DIR/failed-after-reuse.stderr.txt")
    printf '[failed-after] 再送はエラー = %s\n' "$(mask "$err_line")" >> "$SUMMARY"
    sqe_wire failed-after-reuse --client-request-token "$token" \
      --query-string "$FAIL_QUERY_SQL" \
      --query-execution-context "Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" \
      --work-group "$WORKGROUP"
    report_wire_error failed-after-reuse failed-after-reuse
    record_consumed "FAILED の後" "比較不可" "いいえ" "$(wire_error_oneline failed-after-reuse)"
  fi
fi

echo "== cancelled-after-reuse: 実行します"
token=$(gen_token)
sqe_plain cancelled-after-first --client-request-token "$token" \
  --query-string "$LONG_QUERY_SQL" \
  --query-execution-context "Database=$DB" \
  --result-configuration "OutputLocation=$OUTPUT" \
  --work-group "$WORKGROUP"
if [ $? -ne 0 ]; then
  err_line=$(extract_cli_error_line "$RUN_DIR/cancelled-after-first.stderr.txt")
  printf '[cancelled-after] 1回目の呼び出し自体が失敗したため skip。CLI エラー = %s\n' "$(mask "$err_line")" >> "$SUMMARY"
  record_consumed "CANCELLED の後" "比較不可" "不明" "1回目の呼び出し自体が失敗"
else
  cancel_id=$(extract_id "$RUN_DIR/cancelled-after-first.stdout.json")
  aws athena stop-query-execution --region "$REGION" --query-execution-id "$cancel_id" \
    > "$RUN_DIR/cancelled-after-stop.stdout.txt" 2> "$RUN_DIR/cancelled-after-stop.stderr.txt"
  final_state=$(poll_until_terminal "$cancel_id" "$POLL_TIMEOUT")
  printf '[cancelled-after] 1回目の最終 State = %s\n' "${final_state:-(ポーリング上限到達)}" >> "$SUMMARY"
  if [ "$final_state" != "CANCELLED" ]; then
    printf '[cancelled-after] 想定していた CANCELLED にならなかった（State=%s。LONG_QUERY_SQL が速すぎて取り消す前に終わった可能性がある）。それでも同じトークンで再送します\n' "${final_state:-不明}" >> "$SUMMARY"
  fi

  sqe_plain cancelled-after-reuse --client-request-token "$token" \
    --query-string "$LONG_QUERY_SQL" \
    --query-execution-context "Database=$DB" \
    --result-configuration "OutputLocation=$OUTPUT" \
    --work-group "$WORKGROUP"
  if [ $? -eq 0 ]; then
    reuse_id=$(extract_id "$RUN_DIR/cancelled-after-reuse.stdout.json")
    # 新しい実行が作られていたら、後片付けとして取り消しておく。
    if [ -n "$cancel_id" ] && [ "$cancel_id" = "$reuse_id" ]; then
      printf '[cancelled-after] 再送は成功し、QueryExecutionId は同じだった\n' >> "$SUMMARY"
      record_consumed "CANCELLED の後" "同じ" "いいえ" "-"
    else
      printf '[cancelled-after] 再送は成功したが、QueryExecutionId は違った\n' >> "$SUMMARY"
      record_consumed "CANCELLED の後" "違う" "はい" "-"
      aws athena stop-query-execution --region "$REGION" --query-execution-id "$reuse_id" >/dev/null 2>&1 || true
    fi
  else
    err_line=$(extract_cli_error_line "$RUN_DIR/cancelled-after-reuse.stderr.txt")
    printf '[cancelled-after] 再送はエラー = %s\n' "$(mask "$err_line")" >> "$SUMMARY"
    sqe_wire cancelled-after-reuse --client-request-token "$token" \
      --query-string "$LONG_QUERY_SQL" \
      --query-execution-context "Database=$DB" \
      --result-configuration "OutputLocation=$OUTPUT" \
      --work-group "$WORKGROUP"
    report_wire_error cancelled-after-reuse cancelled-after-reuse
    record_consumed "CANCELLED の後" "比較不可" "いいえ" "$(wire_error_oneline cancelled-after-reuse)"
  fi
fi

# ---- 6. トークンの有効期間（測れる範囲のみ） -----------------------------------------

if [ "$TTL_WAIT" -gt 0 ]; then
  echo "== ttl-wait: 実行します（終了後 ${TTL_WAIT} 秒待ちます）"
  token=$(gen_token)
  sqe_plain ttl-wait-first --client-request-token "$token" \
    --query-string "$QUERY_BASELINE" \
    --query-execution-context "Database=$DB" \
    --result-configuration "OutputLocation=$OUTPUT" \
    --work-group "$WORKGROUP"
  if [ $? -eq 0 ]; then
    first_id=$(extract_id "$RUN_DIR/ttl-wait-first.stdout.json")
    state=$(poll_until_terminal "$first_id" "$POLL_TIMEOUT")
    if [ -n "$state" ]; then
      echo "== ttl-wait: 1回目が終了しました (State=$state)。${TTL_WAIT} 秒待ちます"
      sleep "$TTL_WAIT"
      sqe_plain ttl-wait-second --client-request-token "$token" \
        --query-string "$QUERY_BASELINE" \
        --query-execution-context "Database=$DB" \
        --result-configuration "OutputLocation=$OUTPUT" \
        --work-group "$WORKGROUP"
      if [ $? -eq 0 ]; then
        second_id=$(extract_id "$RUN_DIR/ttl-wait-second.stdout.json")
        if [ -n "$first_id" ] && [ "$first_id" = "$second_id" ]; then
          printf '[ttl-wait] 終了後 %s 秒たっても同じトークンで同じ QueryExecutionId が返った（この範囲では有効期間内）\n' "$TTL_WAIT" >> "$SUMMARY"
        else
          printf '[ttl-wait] 終了後 %s 秒たつと同じトークンで違う QueryExecutionId が返った（この範囲でトークンの有効期間切れが観測できた可能性）\n' "$TTL_WAIT" >> "$SUMMARY"
        fi
      else
        err_line=$(extract_cli_error_line "$RUN_DIR/ttl-wait-second.stderr.txt")
        printf '[ttl-wait] 終了後 %s 秒たつと同じトークンでエラー = %s\n' "$TTL_WAIT" "$(mask "$err_line")" >> "$SUMMARY"
      fi
      printf '[ttl-wait] 測定できたのは %s 秒だけで、それより長い有効期間は測れていない\n' "$TTL_WAIT" >> "$SUMMARY"
    else
      printf '[ttl-wait] 1回目のクエリが %s 秒以内に終了状態にならなかったため skip\n' "$POLL_TIMEOUT" >> "$SUMMARY"
    fi
  else
    err_line=$(extract_cli_error_line "$RUN_DIR/ttl-wait-first.stderr.txt")
    printf '[ttl-wait] 1回目の呼び出しが失敗したため skip。CLI エラー = %s\n' "$(mask "$err_line")" >> "$SUMMARY"
  fi
else
  echo "== ttl-wait: skip (TTL_WAIT=0)"
  printf '[ttl-wait] skip (TTL_WAIT=0)\n' >> "$SUMMARY"
fi

# ---- 「トークンが消費される条件」表をまとめて summary の末尾に書く --------------------

{
  echo
  echo "## トークンが消費される条件"
  echo
  echo "| 状況 | 同じ ID が返るか | 新しい実行が作られるか | エラー |"
  echo "| --- | --- | --- | --- |"
} >> "$SUMMARY"
if [ -s "$RUN_DIR/.tmp-consumed-table" ]; then
  while IFS=$'\x1f' read -r row idsame newexec errdesc; do
    printf '| %s | %s | %s | %s |\n' "$row" "$idsame" "$newexec" "$(mask "$errdesc")" >> "$SUMMARY"
  done < "$RUN_DIR/.tmp-consumed-table"
fi

echo
echo "完了しました。"
echo "実名を含まない要約: $SUMMARY"
echo "中身のファイルは $RUN_DIR にあります。リポジトリには入れないでください。"

# 実行例（実在する別ワークグループがあれば WORKGROUP2 も渡すと項目2の WorkGroup も測れる）:
#   WORKGROUP2=analytics DB=your_db OUTPUT=s3://your-bucket/prefix/ \
#     bash client-request-token.sh
