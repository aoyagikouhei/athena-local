# shellcheck shell=bash
# issue #113: 作ったテーブル・ビューの後始末（cleanup-hints・created.tsv・drops.tsv）。run.sh が source する。
# 関数は lib-aws.sh の athena_cli・new_token・poll_until_terminal を使う。

# Hive の外部テーブルは DROP TABLE では LOCATION 配下のデータが消えない
# （tools/measure/drop-table-format.sh の cleanup-hints.txt と同じ扱い）。
record_cleanup_hint() {
  echo "$1" >>"$RUN_DIR/cleanup-hints.txt"
}

# --- 作った・消したテーブル/ビューの記録（TARGET=real だけ。local は compose down -v が
# 環境ごと消すので不要） -------------------------------------------------------

# 作った直後に呼ぶ。DROP が失敗しても created.tsv に残るので、run の最後（finish_cleanup）と
# 中断時の trap（run.sh の cleanup_real）が拾って DROP IF EXISTS をもう一度投げられる。
record_created() {
  [ "$TARGET" = real ] || return 0
  local kind=$1 name=$2 catalog=$3 database=$4
  printf '%s\t%s\t%s\t%s\n' "$kind" "$name" "$catalog" "$database" >>"$RUN_DIR/created.tsv"
}

# DROP が SUCCEEDED になったときだけ呼び、created.tsv からその 1 行を消す。
forget_created() {
  local kind=$1 name=$2 catalog=$3 database=$4
  [ -s "$RUN_DIR/created.tsv" ] || return 0
  python3 -c 'import sys
kind, name, catalog, database, path = sys.argv[1:6]
target = "%s\t%s\t%s\t%s\n" % (kind, name, catalog, database)
lines = open(path).readlines()
open(path, "w").writelines(l for l in lines if l != target)' \
    "$kind" "$name" "$catalog" "$database" "$RUN_DIR/created.tsv"
}

# 後始末の DROP TABLE/VIEW IF EXISTS を投げる。TARGET=local はこれまでどおり投げっぱなし
# （結果を待たない、ベストエフォート）。TARGET=real は QueryExecutionId を drops.tsv に
# 記録するだけに留め、待つのは run の最後の finish_cleanup で 1 回にまとめる。
# 戻り値: StartQueryExecution を開始できたら 0、できなければ 1（呼び出し側の cleanup_real が
# 投げた本数・開始に失敗した本数を数えるのに使う）。
best_effort_drop() {
  local kind=$1 name=$2 catalog=$3 database=$4
  if [ "$TARGET" != real ]; then
    local rc=0
    athena_cli start-query-execution \
      --query-string "DROP $kind IF EXISTS $name" \
      --query-execution-context "Catalog=$catalog,Database=$database" \
      --result-configuration "OutputLocation=$OUTPUT" \
      --client-request-token "$(new_token)" \
      >/dev/null 2>&1 || rc=1
    # local には drops.tsv（real 専用）が無いので、report.py の DDL 内訳・呼び出し回数に
    # 数えられるよう、投げた本数だけ 1 行ずつ記録する（成否は問わない。「投げた」本数）。
    echo "$kind $name" >>"$RUN_DIR/drop-count"
    return "$rc"
  fi
  local out
  out=$(mktemp)
  local rc=1
  if athena_cli start-query-execution \
    --query-string "DROP $kind IF EXISTS $name" \
    --query-execution-context "Catalog=$catalog,Database=$database" \
    --result-configuration "OutputLocation=$OUTPUT" \
    --client-request-token "$(new_token)" \
    >"$out" 2>/dev/null; then
    local id
    id=$(query_execution_id_of "$out")
    if [ -n "$id" ]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$kind" "$name" "$catalog" "$database" >>"$RUN_DIR/drops.tsv"
      rc=0
    fi
  fi
  rm -f "$out"
  return "$rc"
}

# run の最後に 1 回だけ呼ぶ（TARGET=real のみ）。drops.tsv の DROP を全部終端状態まで待ち、
# SUCCEEDED なら created.tsv から消す。結果を summary.txt に載せる行を cleanup-report.txt
# に書く（report.py が読む）。最後に created.tsv に残っている行（DROP の開始に失敗した・
# SUCCEEDED にならなかったもの）を数えて名前付きで報告し、残りがあれば「手で消してください」を
# 添える（手本 tools/measure/drop-table-format.sh:701-708）。
finish_cleanup() {
  local report="$RUN_DIR/cleanup-report.txt"
  if [ -s "$RUN_DIR/drops.tsv" ]; then
    local total=0 succeeded=0
    local -a other_names=()
    local id kind name catalog database state
    while IFS=$'\t' read -r id kind name catalog database; do
      [ -n "$id" ] || continue
      total=$((total + 1))
      state=$(poll_until_terminal "$id")
      if [ "$state" = SUCCEEDED ]; then
        succeeded=$((succeeded + 1))
        forget_created "$kind" "$name" "$catalog" "$database"
      else
        other_names+=("${name}(${state})")
      fi
    done <"$RUN_DIR/drops.tsv"
    local other=$((total - succeeded)) names=""
    if [ "$other" -gt 0 ]; then
      names=$(
        IFS=,
        echo "${other_names[*]}"
      )
      names=" (${names})"
    fi
    echo "後始末: DROP ${total}本、SUCCEEDED ${succeeded}、それ以外 ${other}${names}" >"$report"
  else
    echo "後始末: DROP 0本" >"$report"
  fi

  local leftover=0
  local -a leftover_names=()
  if [ -s "$RUN_DIR/created.tsv" ]; then
    local kind name catalog database
    while IFS=$'\t' read -r kind name catalog database; do
      [ -n "${kind:-}" ] || continue
      leftover=$((leftover + 1))
      leftover_names+=("$name")
    done <"$RUN_DIR/created.tsv"
  fi
  if [ "$leftover" -gt 0 ]; then
    local leftover_joined
    leftover_joined=$(
      IFS=,
      echo "${leftover_names[*]}"
    )
    {
      echo "後始末: 残り ${leftover}本（${leftover_joined}）"
      echo "後始末: 終了時にもう一度投げます。それでも消えなければ、${TDB} の ${PROBE_PREFIX}_* を手で消してください。"
    } >>"$report"
  fi
  cat "$report"
}

