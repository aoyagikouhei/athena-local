# shellcheck shell=bash
# issue #113: ClientRequestToken の未実測 7 項目（t1, t2, t3, t4, t5, t8, t4c）。単独では
# 実行しない。run.sh が source して item_t1 などを呼ぶ。t2・t3・t4 は aws CLI が短すぎる
# トークンを送信前に弾くため raw.py（生 HTTP。lib-raw.sh の run_raw_item 経由）で測る。
# t4c は t4 のうち aws CLI だけで送れる組（不正な OutputLocation × 構文エラー、有効な長さの
# トークン）。raw.py 側の run_t4 はこれと同じ組（output-syntax）を含まないよう外してあり、
# aws CLI では送れない短いトークンが絡む組だけを担う（重複を避けるため。issue-notes 参照）。
#
# store.rs の Fingerprint は Catalog を持たない（2026-09-17 実測）ので、local では
# Catalog を変えても同じ ID になるはず（t1）。execution.rs の検証順は
# token → OutputLocation → 構文チェック → Store::submit の順（#102）なので、
# local では同じトークンでの再送が検証エラーに引っかかれば IDEMPOTENT_PARAMETER_MISMATCH
# より先に検証エラーが返るはず（t5・t4c）。Fingerprint は既定を当てる前の生の値で比べるので、
# Database／OutputLocation の「省略」と「既定と同じ値の明示」は local では別物（Conflict）になるはず（t8）。

# t1: 同じトークン・同じ SQL で Catalog だけ変える（大文字小文字違いと実在しない名前）。
item_t1() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  local tok
  tok=$(new_token)
  local sql="SELECT 1 AS t1_probe"

  run_stmt "$dir" t1-a "$sql" "$TCAT_GENERIC" "$TDB" - "$tok"
  local id_a
  id_a=$(query_execution_id_of "$dir/t1-a.start.json")

  local alt_case="${TCAT_GENERIC^^}"
  run_stmt "$dir" t1-b "$sql" "$alt_case" "$TDB" - "$tok"
  local id_b
  id_b=$(query_execution_id_of "$dir/t1-b.start.json")
  if [ "$TARGET" = local ]; then
    declare_expectation "$id" same_id_case_variant "$id_a" "$id_b" "Catalogの大文字小文字違い($TCAT_GENERIC vs $alt_case)"
  else
    write_summary_row "$id" case-variant stmt - - - - - - - - - - - \
      "Catalogの大文字小文字違い($TCAT_GENERIC vs $alt_case): 元id=$id_a 変種id=$id_b 一致=$([ "$id_a" = "$id_b" ] && echo yes || echo no)"
  fi

  run_stmt "$dir" t1-c "$sql" "athena_local_probe_113_no_such_catalog" "$TDB" - "$tok"
  local id_c
  id_c=$(query_execution_id_of "$dir/t1-c.start.json")
  if [ "$TARGET" = local ]; then
    declare_expectation "$id" same_id_nonexistent_catalog "$id_a" "$id_c" "存在しないCatalog名"
  else
    write_summary_row "$id" nonexistent-catalog stmt - - - - - - - - - - - \
      "存在しないCatalog名: 元id=$id_a 変種id=$id_c 一致=$([ "$id_a" = "$id_c" ] && echo yes || echo no)"
  fi
}

# t5（#102）: 1 回目成功のあと、同じトークンで (a) OutputLocation だけ不正、
# (b) QueryString だけ構文エラーにする。athena-local は検証がトークンの照合より先。
item_t5() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  local tok
  tok=$(new_token)
  local sql="SELECT 1 AS t5_probe"

  run_stmt "$dir" t5-first "$sql" "$TCAT_GENERIC" "$TDB" - "$tok"

  run_stmt "$dir" t5-bad-output "$sql" "$TCAT_GENERIC" "$TDB" - "$tok" "not-a-valid-s3-path"
  local outcome_output
  outcome_output=$(classify_start_error "$dir/t5-bad-output.start.err")
  if [ "$TARGET" = local ]; then
    declare_expectation "$id" outputlocation_before_conflict validation_error "$outcome_output" \
      "同じトークン+不正なOutputLocation: $(first_err_line "$dir/t5-bad-output.start.err")"
  else
    write_summary_row "$id" outputlocation-before-conflict stmt - - - - - - - - - - - \
      "分類=$outcome_output 同じトークン+不正なOutputLocation: $(first_err_line "$dir/t5-bad-output.start.err")"
  fi

  run_stmt "$dir" t5-bad-syntax "SELEC 1" "$TCAT_GENERIC" "$TDB" - "$tok"
  local outcome_syntax
  outcome_syntax=$(classify_start_error "$dir/t5-bad-syntax.start.err")
  if [ "$TARGET" = local ]; then
    declare_expectation "$id" syntax_before_conflict validation_error "$outcome_syntax" \
      "同じトークン+構文エラー: $(first_err_line "$dir/t5-bad-syntax.start.err")"
  else
    write_summary_row "$id" syntax-before-conflict stmt - - - - - - - - - - - \
      "分類=$outcome_syntax 同じトークン+構文エラー: $(first_err_line "$dir/t5-bad-syntax.start.err")"
  fi
}

# t4（生 HTTP。フェーズ 2）のうち、短いトークンが要らない組だけ aws CLI で測る:
# 不正な OutputLocation × 構文エラーの 1 本で、どちらの検証が先に出るかを見る。
item_t4c() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  run_stmt "$dir" t4c-combo "SELEC 1" "$TCAT_GENERIC" "$TDB" - - "not-a-valid-s3-path"
  local msg
  msg=$(first_err_line "$dir/t4c-combo.start.err")
  local classification=other
  if echo "$msg" | grep -qi 'outputLocation is not a valid S3 path'; then
    classification=outputlocation
  elif echo "$msg" | grep -qiE 'mismatched input|SYNTAX_ERROR|line [0-9]+:[0-9]+'; then
    classification=syntax
  fi
  if [ "$TARGET" = local ]; then
    declare_expectation "$id" outputlocation_checked_before_syntax outputlocation "$classification" "$msg"
  else
    write_summary_row "$id" outputlocation-checked-before-syntax stmt - - - - - - - - - - - \
      "先に弾かれたのは=$classification: $msg"
  fi
}

# t2・t3・t4（生 HTTP。raw.py）。lib-raw.sh の run_raw_item が summary.tsv への変換を担う。
item_t2() { run_raw_item "$1"; }
item_t3() { run_raw_item "$1"; }
item_t4() { run_raw_item "$1"; }

# t8: Database の省略 vs 'default' の明示、OutputLocation の省略 vs 明示
# （WORKGROUP2 の出力先と同じ値。TARGET_WG2_OUTPUT が空なら後半は skip）。
item_t8() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"

  local tok1
  tok1=$(new_token)
  run_stmt "$dir" t8-db-omit "SELECT 1 AS t8_probe" "$TCAT_GENERIC" - "$WORKGROUP2" "$tok1"
  run_stmt "$dir" t8-db-explicit "SELECT 1 AS t8_probe" "$TCAT_GENERIC" default "$WORKGROUP2" "$tok1"
  local outcome_db
  outcome_db=$(classify_start_error "$dir/t8-db-explicit.start.err")
  if [ "$TARGET" = local ]; then
    declare_expectation "$id" database_omit_vs_default conflict "$outcome_db" \
      "Database省略 vs 'default'明示: $(first_err_line "$dir/t8-db-explicit.start.err")"
  else
    write_summary_row "$id" database-omit-vs-default stmt - - - - - - - - - - - \
      "分類=$outcome_db Database省略 vs 'default'明示: $(first_err_line "$dir/t8-db-explicit.start.err")"
  fi

  if [ -z "${TARGET_WG2_OUTPUT:-}" ]; then
    skip_item "$id" t8-output "WORKGROUP2 の OutputLocation が取れないので測れない"
    return 0
  fi
  local tok2
  tok2=$(new_token)
  run_stmt "$dir" t8-output-omit "SELECT 2 AS t8_probe" "$TCAT_GENERIC" "$TDB" "$WORKGROUP2" "$tok2" omit
  run_stmt "$dir" t8-output-explicit "SELECT 2 AS t8_probe" "$TCAT_GENERIC" "$TDB" "$WORKGROUP2" "$tok2" \
    "$TARGET_WG2_OUTPUT"
  local outcome_output
  outcome_output=$(classify_start_error "$dir/t8-output-explicit.start.err")
  if [ "$TARGET" = local ]; then
    declare_expectation "$id" outputlocation_omit_vs_explicit conflict "$outcome_output" \
      "OutputLocation省略 vs 明示: $(first_err_line "$dir/t8-output-explicit.start.err")"
  else
    write_summary_row "$id" outputlocation-omit-vs-explicit stmt - - - - - - - - - - - \
      "分類=$outcome_output OutputLocation省略 vs 明示: $(first_err_line "$dir/t8-output-explicit.start.err")"
  fi
}
