#!/usr/bin/env bash
# 項目を1件実行する本体。describe-extended.sh:663-732（run。#275）を run_query に、
# get-work-group.sh:106-168（--cli-input-json を使わない先例）を athena_call に広げた。
# emit_row・skip（summary.tsv への1行）もここに置く（フェーズ 2 の items.sh の run_items
# から呼ばれるが、フェーズ 1 の run_query・athena_call も単独で呼ぶため）。

# summary.tsv に1行積む。列の並びはヘッダ（lib_init が書く）と同じ 15 列で固定する。
emit_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$SUMMARY"
}

# 項目を未測定として summary に1行残す。全体を止めずに次へ進む。
skip() {
  local item_id=$1 note=$2
  echo "== $item_id: 未測定（$note）"
  emit_row "$item_id" skip SKIPPED "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "$(sanitize "$note")"
}

# ctx（db|catalog|none|<Catalog>/<Database>）を --query-execution-context の shorthand に
# する。none は空文字を返す（start_query_retry はこれを見て --query-execution-context を
# 付けない）。
run_ctx_string() {
  local ctx=$1
  case "$ctx" in
    db) printf 'Catalog=%s,Database=%s' "$CATALOG" "$DB" ;;
    catalog) printf 'Catalog=%s' "$CATALOG" ;;
    none) printf '' ;;
    */*) printf 'Catalog=%s,Database=%s' "${ctx%%/*}" "${ctx#*/}" ;;
    *) return 1 ;;
  esac
}

# PascalCase の Operation 名を aws CLI の kebab-case のサブコマンドにする
# （例: ListDatabases → list-databases）。
pascal_to_kebab() {
  printf '%s' "$1" \
    | sed -E 's/([a-z0-9])([A-Z])/\1-\2/g; s/([A-Z]+)([A-Z][a-z])/\1-\2/g' \
    | tr '[:upper:]' '[:lower:]'
}

# id を指定して1文を実行し、終端状態まで待って State・StatementType・SubstatementType・
# Query・Context・OutputLocation の拡張子・Content-Type・.metadata・GetQueryResults
# （ColumnInfo・Rows・UpdateCount）を採取する。開始できなければ、AthenaErrorCode・Message
# をその場の start.err からそのまま抜く（追加の呼び出しはしない）。成功したときだけ 0 を返す。
#
# 保存物は describe-extended.sh の run と同じ（<label> を <id> に変えただけ）:
#   <id>.sql / .start.err / .execution.json / .execution.err / .reason.txt / .query.txt /
#   .context.txt / .ls.txt / .bytes / .od.txt / .cp.err / .metadata.bytes / .metadata.od.txt /
#   .metadata.cp.err / .head.json / .metadata.head.json /
#   .results-<n>.json / .results.columns.txt / .results.rows.txt / .results.update_count.txt
run_query() {
  local item_id=$1 ctx=$2 sql=$3
  local qid state stype sub loc query ctx_json qe_context
  local ext="-" ctype="-" meta_present="no" update_count="-" row_count="-"
  local err_cat="-" err_type="-" start_msg="-" start_code="-"
  local attempts note

  if ! qe_context=$(run_ctx_string "$ctx"); then
    skip "$item_id" "ctx の値が分かりません（$ctx）"
    return 1
  fi

  printf '%s' "$sql" > "$RUN_DIR/$item_id.sql"
  export DRY_RUN_CURRENT_ID="$item_id"
  qid=$(start_query_retry "$item_id" "$sql" "$qe_context")
  attempts=$(read_attempts "$item_id")

  if [ -z "${qid:-}" ]; then
    start_msg=$(start_err_message "$RUN_DIR/$item_id.start.err")
    start_code=$(start_err_code "$RUN_DIR/$item_id.start.err")
    note="attempts=$attempts; $(first_err_line "$RUN_DIR/$item_id.start.err")"
    echo "== $item_id: 開始できませんでした（試行 $attempts 回）。AthenaErrorCode=$start_code"
    emit_row "$item_id" query START_FAILED "-" "-" "-" "-" "-" "-" "-" "-" "-" "$start_msg" "$start_code" "$(sanitize "$note")"
    return 1
  fi

  state=$(poll_until_terminal "$qid")

  retry_aws "$RUN_DIR/$item_id.execution.json" "$RUN_DIR/$item_id.execution.err" \
    aws athena get-query-execution --region "$REGION" --query-execution-id "$qid"
  write_reason "$RUN_DIR/$item_id.execution.json" "$RUN_DIR/$item_id.reason.txt"

  IFS=$'\t' read -r stype sub loc < <(read_execution_fields "$RUN_DIR/$item_id.execution.json")
  query=$(query_of "$RUN_DIR/$item_id.execution.json")
  printf '%s' "$query" > "$RUN_DIR/$item_id.query.txt"
  ctx_json=$(context_of "$RUN_DIR/$item_id.execution.json")
  printf '%s' "$ctx_json" > "$RUN_DIR/$item_id.context.txt"
  ext=$(ext_of "$loc")

  case "$state" in
    FAILED | CANCELLED)
      IFS=$'\t' read -r err_cat err_type _ < <(athena_error_fields_of "$RUN_DIR/$item_id.execution.json")
      ;;
  esac

  capture_results "$item_id" "$qid"
  update_count=$(cat "$RUN_DIR/$item_id.results.update_count.txt" 2>/dev/null || echo -)
  if [ -f "$RUN_DIR/$item_id.results.rows.txt" ]; then
    row_count=$(wc -l < "$RUN_DIR/$item_id.results.rows.txt" | tr -d ' ')
  fi

  if [ -n "$loc" ]; then
    { echo "# ls $loc"; aws s3 ls "$loc" --region "$REGION"; echo "# rc=$?"
      echo "# ls $loc.metadata"; aws s3 ls "$loc.metadata" --region "$REGION"; echo "# rc=$?"
    } > "$RUN_DIR/$item_id.ls.txt" 2>&1

    if fetch "$loc" "$RUN_DIR/$item_id.bytes" "$RUN_DIR/$item_id.cp.err"; then
      od -An -tx1c "$RUN_DIR/$item_id.bytes" > "$RUN_DIR/$item_id.od.txt"
    fi
    if head_object "$loc" "$RUN_DIR/$item_id.head.json" "$RUN_DIR/$item_id.head.err"; then
      ctype=$(content_type_of "$RUN_DIR/$item_id.head.json")
    fi
    if fetch "$loc.metadata" "$RUN_DIR/$item_id.metadata.bytes" "$RUN_DIR/$item_id.metadata.cp.err"; then
      od -An -tx1c "$RUN_DIR/$item_id.metadata.bytes" > "$RUN_DIR/$item_id.metadata.od.txt"
      meta_present="yes"
    fi
    head_object "$loc.metadata" "$RUN_DIR/$item_id.metadata.head.json" "$RUN_DIR/$item_id.metadata.head.err" || true
  fi

  note="attempts=$attempts"
  echo "== $item_id  state=$state  type=$stype/$sub  ext=$ext  ct=$ctype  metadata=$meta_present  update_count=$update_count  rows=$row_count  error=$err_cat/$err_type"
  emit_row "$item_id" query "$state" "$stype" "$sub" "$ext" "$ctype" "$meta_present" "$update_count" "$row_count" "$err_cat" "$err_type" "$start_msg" "$start_code" "$(sanitize "$note")"
  [ "$state" = SUCCEEDED ]
}

# Operation（PascalCase）と JSON を指定して任意の Athena API を1回呼ぶ。JSON は python3 の
# json.loads で妥当性だけ確かめ、不正なら投げずに skip する。要求を <id>.request.json、
# 応答を <id>.response.json、失敗を <id>.err に保存する（retry_aws 経由）。
athena_call() {
  local item_id=$1 operation=$2 json=$3
  local sub note

  if ! printf '%s' "$json" | python3 -c 'import json, sys; json.loads(sys.stdin.read())' 2>/dev/null; then
    skip "$item_id" "不正な JSON のため未測定（Operation=$operation）"
    return 1
  fi

  sub=$(pascal_to_kebab "$operation")
  printf '%s' "$json" > "$RUN_DIR/$item_id.request.json"
  export DRY_RUN_CURRENT_ID="$item_id"

  if retry_aws "$RUN_DIR/$item_id.response.json" "$RUN_DIR/$item_id.err" \
      aws athena "$sub" --region "$REGION" --cli-input-json "$json"; then
    echo "== $item_id ($operation): 成功しました"
    emit_row "$item_id" api "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "ok"
    return 0
  else
    note=$(first_err_line "$RUN_DIR/$item_id.err")
    echo "== $item_id ($operation): 失敗しました。$note"
    emit_row "$item_id" api "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "-" "$(sanitize "error: $note")"
    return 1
  fi
}
