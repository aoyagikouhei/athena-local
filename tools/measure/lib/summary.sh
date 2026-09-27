#!/usr/bin/env bash
# summary.txt（実名を伏せた、そのまま貼れる要約）を書く。#310 フェーズ2。
# describe-extended.sh:1114-1254（#275）の row_summary_of・columns_display_of・
# write_summary_txt の考え方の移植。run_items（items.sh）が最後に1回呼ぶ。

# summary.tsv から id が一致する行のうち最後のもの（同じ id が2回書かれたら後勝ち。
# preflight-list-tables が DB の自動選択でやり直されたときなど）を1行の要約にする。
_lib_summary_row_of() {
  python3 -c 'import csv, sys
item_id = sys.argv[2]
last = None
with open(sys.argv[1], newline="") as f:
    for row in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
        if row["id"] == item_id:
            last = row
if last is not None:
    print(
        "state={state} type={statement_type}/{substatement_type} "
        "ext={ext} content_type={content_type} metadata={metadata_present} "
        "update_count={update_count} row_count={row_count} "
        "error={error_category}/{error_type} "
        "start_message={start_message} start_athena_error_code={start_athena_error_code} "
        "note={note}".format(**last)
    )' "$SUMMARY" "$1"
}

# <id>.results.columns.txt を「Name:Type, Name:Type, ...」の1行にして返す（無ければ "-"）。
_lib_summary_columns_of() {
  local f="$RUN_DIR/$1.results.columns.txt"
  if [ -s "$f" ]; then
    hide "$(paste -sd, "$f")"
  else
    echo "-"
  fi
}

# ファイルの中身を repr 相当（実名を伏せて1行に）で返す。無ければ "-"。
_lib_summary_file_repr() {
  local f=$1
  if [ -s "$f" ] || [ -e "$f" ]; then
    hide "$(python3 -c 'import sys
print(repr(open(sys.argv[1], "rb").read().decode("utf-8", "replace")))' "$f")"
  else
    echo "-"
  fi
}

# ヘッダ: issue・実行日時・DRY_RUN・課金の回数・DDL の内訳・skip の数・注意書き。
_lib_summary_header() {
  echo "# issue #${ISSUE}"
  echo "# 実行日時: $(date -Iseconds)"
  if [ "${DRY_RUN:-0}" = 1 ]; then
    echo "# DRY_RUN: 本物に投げていない（偽の aws）"
  fi
  echo "# StartQueryExecution を呼んだ回数（一時的な失敗の再試行・後始末の DROP を含む。"
  echo "#   GetQueryExecution・GetQueryResults・S3 への呼び出しは含めない）: $(wc -l < "$START_CALL_FILE" | tr -d ' ')"
  echo "# DDL の内訳（作った表・ビューと DROP の対）:"
  if [ -s "$RUN_DIR/drop-log.tsv" ]; then
    while IFS=$'\t' read -r kind name state; do
      echo "#   $name ($kind): DROP -> $state"
    done < "$RUN_DIR/drop-log.tsv"
  else
    echo "#   （作成した表・ビューは無し）"
  fi
  if [ -s "$RUN_DIR/created.tsv" ]; then
    echo "# DDL: 消せずに残っているもの（手で消してください）:"
    while IFS=$'\t' read -r kind name; do
      echo "#   $name ($kind)"
    done < "$RUN_DIR/created.tsv"
  fi
  if [ -s "$RUN_DIR/cleanup-hints.txt" ]; then
    echo "# DROP では消えないもの（手で消してください）:"
    while IFS= read -r line; do
      echo "#   $(hide "$line")"
    done < "$RUN_DIR/cleanup-hints.txt"
  fi
  echo "# skip の数: $(awk -F'\t' '$2=="skip"{n++} END{print n+0}' "$SUMMARY")"
  echo "# 注意: これは実測した本物の Athena の挙動であり、将来の Athena の変更や、コンソールでの"
  echo "#   設定変更で変わりうる。実測値は工場出荷時の既定とは限らない。"
  echo "# マスク: 実名と、前後が数字でない 12 桁の数字（アカウント ID とみなす）を伏せている。測った値が"
  echo "#   12 桁の数字だと <ACCOUNT_ID> に見えるので、生の値は <id>.bytes・<id>.results-*.json で確かめる。"
}

# 項目1件ぶんのブロック（query 系: sql・要約行・Query・Context・ColumnInfo・State/Reason・
# 結果の先頭3行・結果本体・.metadata の有無。api 系: request・response）。
_lib_summary_block() {
  local id=$1 kind=$2
  echo "### $id"

  if [ "$kind" = api ]; then
    if [ -s "$RUN_DIR/$id.request.json" ]; then
      echo "- request: $(_lib_summary_file_repr "$RUN_DIR/$id.request.json")"
      echo "- response: $(_lib_summary_file_repr "$RUN_DIR/$id.response.json")"
      local row
      row=$(_lib_summary_row_of "$id")
      [ -n "$row" ] && echo "- $row"
      if [ -s "$RUN_DIR/$id.err" ]; then
        echo "- 失敗: $(first_err_line "$RUN_DIR/$id.err")"
      fi
    else
      _lib_summary_skip_note "$id"
    fi
    echo
    return
  fi

  if [ ! -s "$RUN_DIR/$id.sql" ]; then
    _lib_summary_skip_note "$id"
    echo
    return
  fi

  echo "- sql: $(_lib_summary_file_repr "$RUN_DIR/$id.sql")"
  local row
  row=$(_lib_summary_row_of "$id")
  [ -n "$row" ] && echo "- $row"
  if [ -s "$RUN_DIR/$id.query.txt" ]; then
    echo "- Query: $(_lib_summary_file_repr "$RUN_DIR/$id.query.txt")"
  fi
  if [ -s "$RUN_DIR/$id.context.txt" ]; then
    echo "- Context: $(hide "$(cat "$RUN_DIR/$id.context.txt")")"
  fi
  echo "- ColumnInfo: $(_lib_summary_columns_of "$id")"
  if [ -s "$RUN_DIR/$id.reason.txt" ]; then
    echo "- State / StateChangeReason / AthenaError（全文）:"
    hide_multiline "$RUN_DIR/$id.reason.txt" | sed 's/^/    /'
  elif [ -s "$RUN_DIR/$id.start.err" ]; then
    echo "- 開始時に弾かれた（AthenaErrorCode・Message は上の行を参照。原文は $id.start.err）"
  fi
  if [ -s "$RUN_DIR/$id.results.rows.txt" ]; then
    local rc
    rc=$(wc -l < "$RUN_DIR/$id.results.rows.txt" | tr -d ' ')
    echo "- GetQueryResults の行数: $rc（先頭3行。全文は $id.results.rows.txt）"
    head -3 "$RUN_DIR/$id.results.rows.txt" | while IFS= read -r line; do
      echo "    $(sanitize "$(hide "$line")")"
    done
  else
    echo "- GetQueryResults の行数: 0（または取得できず）"
  fi
  echo "- 結果ファイル本体（マスク済み。長ければ先頭4000文字。全文は $id.bytes）:"
  hide_multiline "$RUN_DIR/$id.bytes" | sed 's/^/    /'
  if [ -s "$RUN_DIR/$id.metadata.bytes" ]; then
    echo "- .metadata: あり（$(wc -c < "$RUN_DIR/$id.metadata.bytes" | tr -d ' ') バイト）"
  elif [ -f "$RUN_DIR/$id.metadata.bytes" ]; then
    echo "- .metadata: あり（0バイト）"
  else
    echo "- .metadata: 無し（または未確認）"
  fi
  echo
}

_lib_summary_skip_note() {
  local id=$1 note
  note=$(python3 -c 'import csv, sys
item_id = sys.argv[2]
last = None
with open(sys.argv[1], newline="") as f:
    for row in csv.DictReader(f, delimiter="\t", quoting=csv.QUOTE_NONE):
        if row["id"] == item_id:
            last = row
print(last["note"] if last is not None else "")' "$SUMMARY" "$id")
  if [ -n "$note" ]; then
    echo "- 未測定: $note"
  else
    echo "- この実行では投げなかった"
  fi
}

# run_items の最後に1回だけ呼ぶ。$RUN_DIR/summary.txt に書き、パスを返す。
write_summary_txt() {
  local txt="$RUN_DIR/summary.txt"
  {
    _lib_summary_header
    echo
    echo "## 項目ごとの結果（1項目 = 1ブロック。実名は伏せる）"
    local i
    for i in "${!_ITEM_IDS[@]}"; do
      _lib_summary_block "${_ITEM_IDS[$i]}" "${_ITEM_KINDS[$i]}"
    done
  } > "$txt"
  echo "$txt"
}
