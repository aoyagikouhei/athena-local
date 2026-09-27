#!/usr/bin/env bash
# 後始末の台帳（created.tsv・drops.tsv・drop-log.tsv・cleanup-report.txt）。#310 フェーズ2。
# unmeasured-batch/lib-cleanup.sh:1-132（#113）の考え方の移植: 作った直後に record_created、
# 使い終えたら（items.sh の run_items が判定して）best_effort_drop、run の最後に
# finish_cleanup が drops.tsv の全 id を終端まで待つ。DROP は課金の数えに入れるため
# start_query_retry 経由（run_query は使わない。結果ファイルの採取は要らない）。

# 作った直後に呼ぶ（items.sh の run_items から。SUCCEEDED した creates の項目だけ）。
# DROP が失敗しても created.tsv に残るので、finish_cleanup と中断時の trap
# （lib_cleanup_trap、下）が拾って DROP IF EXISTS をもう一度投げられる。
record_created() {
  local kind=$1 name=$2
  printf '%s\t%s\n' "$kind" "$name" >> "$RUN_DIR/created.tsv"
}

# DROP が SUCCEEDED になったときだけ呼び、created.tsv からその1行を消す。
forget_created() {
  local kind=$1 name=$2
  [ -s "$RUN_DIR/created.tsv" ] || return 0
  python3 -c 'import sys
kind, name, path = sys.argv[1:4]
target = "%s\t%s\n" % (kind, name)
lines = open(path).readlines()
open(path, "w").writelines(l for l in lines if l != target)' \
    "$kind" "$name" "$RUN_DIR/created.tsv"
}

# 後始末の DROP を start_query_retry 経由で投げる（課金の数え = START_CALL_FILE に乗る）。
# 開始できた QueryExecutionId を drops.tsv に積むだけで、終端まで待つのは finish_cleanup が
# まとめて1回でやる。開始できなければ drop-log.tsv に START_FAILED を残す
# （created.tsv はそのまま残り、finish_cleanup の「残り」報告と trap の保険の対象になる）。
best_effort_drop() {
  local kind=$1 name=$2 sql ctx qid
  sql="DROP $kind IF EXISTS $DB.$name"
  ctx=$(run_ctx_string db) || ctx=""
  # run_query・athena_call と同じく、偽 aws（DRY_RUN=1）が参照する DRY_RUN_CURRENT_ID を
  # このドロップの id に合わせておく（さもないと直前の項目の id のまま呼ぶことになる）。
  export DRY_RUN_CURRENT_ID="drop-$name"
  if qid=$(start_query_retry "drop-$name" "$sql" "$ctx"); then
    printf '%s\t%s\t%s\n' "$qid" "$kind" "$name" >> "$RUN_DIR/drops.tsv"
    return 0
  fi
  printf '%s\t%s\t%s\n' "$kind" "$name" START_FAILED >> "$RUN_DIR/drop-log.tsv"
  return 1
}

# run_items の最後に1回だけ呼ぶ。drops.tsv の DROP を全部終端状態まで待ち、SUCCEEDED なら
# created.tsv から消す。名前ごとの対は drop-log.tsv（summary.sh の DDL の内訳が読む）、
# 要約は cleanup-report.txt に書く。全部 SUCCEEDED で消せていれば created.tsv は空になる
# （lib_cleanup_trap の保険が何もしなくてよい状態）。
finish_cleanup() {
  local report="$RUN_DIR/cleanup-report.txt"
  local total=0 succeeded=0
  local -a other_names=()

  if [ -s "$RUN_DIR/drops.tsv" ]; then
    local id kind name state
    while IFS=$'\t' read -r id kind name; do
      [ -n "$id" ] || continue
      total=$((total + 1))
      state=$(poll_until_terminal "$id")
      printf '%s\t%s\t%s\n' "$kind" "$name" "$state" >> "$RUN_DIR/drop-log.tsv"
      if [ "$state" = SUCCEEDED ]; then
        succeeded=$((succeeded + 1))
        forget_created "$kind" "$name"
      else
        other_names+=("${name}(${state})")
      fi
    done < "$RUN_DIR/drops.tsv"
  fi

  local other=$((total - succeeded)) names=""
  if [ "$other" -gt 0 ]; then
    names=$(
      IFS=,
      echo "${other_names[*]}"
    )
    names=" (${names})"
  fi
  echo "後始末: DROP ${total} 本、SUCCEEDED ${succeeded}、それ以外 ${other}${names}" > "$report"

  local leftover=0
  local -a leftover_names=()
  if [ -s "$RUN_DIR/created.tsv" ]; then
    local kind name
    while IFS=$'\t' read -r kind name; do
      [ -n "${kind:-}" ] || continue
      leftover=$((leftover + 1))
      leftover_names+=("$name")
    done < "$RUN_DIR/created.tsv"
  fi
  if [ "$leftover" -gt 0 ]; then
    local leftover_joined
    leftover_joined=$(
      IFS=,
      echo "${leftover_names[*]}"
    )
    {
      echo "後始末: 残り ${leftover} 本（${leftover_joined}）"
      echo "後始末: 中断時の保険（lib_cleanup_trap）で DROP IF EXISTS をもう一度投げます。それでも消えなければ手で消してください。"
    } >> "$report"
  fi
  cat "$report"
}

# lib.sh の既定（.tmp-* を消すだけ）を上書きする。created.tsv に残っている分だけ、
# 待たずに（poll しない）DROP IF EXISTS を投げる保険。start_query_retry を通さない
# （一時的な失敗の再試行をしない・START_CALL_FILE にも数えない。P-9）。finish_cleanup が
# 正常に終わっていれば created.tsv は空なので、通常終了ではここは何もしない。
lib_cleanup_trap() {
  rm -f "${RUN_DIR:-}"/.tmp-* 2>/dev/null || true
  [ -n "${RUN_DIR:-}" ] && [ -s "$RUN_DIR/created.tsv" ] || return 0
  local ctx
  ctx=$(run_ctx_string db 2>/dev/null) || return 0
  local kind name
  while IFS=$'\t' read -r kind name; do
    [ -n "${kind:-}" ] || continue
    aws athena start-query-execution --region "$REGION" \
      --query-string "DROP $kind IF EXISTS $DB.$name" \
      --query-execution-context "$ctx" \
      --result-configuration "OutputLocation=$OUTPUT" \
      > /dev/null 2>&1 || true
  done < "$RUN_DIR/created.tsv"
}
