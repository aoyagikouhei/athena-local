# shellcheck shell=bash
# issue #113: ClientRequestToken の未実測 4 項目（t1, t5, t8, t4c）。単独では実行しない。
# run.sh が source して item_t1 などを呼ぶ。t2・t3・t4（短いトークンの組）・e2 は生 HTTP が要るので
# フェーズ 2（raw.py）。t4c は t4 のうち aws CLI だけで送れる組（不正な OutputLocation × 構文エラー）。
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
  declare_expectation "$id" same_id_case_variant "$id_a" "$id_b" "Catalogの大文字小文字違い($TCAT_GENERIC vs $alt_case)"

  run_stmt "$dir" t1-c "$sql" "athena_local_probe_113_no_such_catalog" "$TDB" - "$tok"
  local id_c
  id_c=$(query_execution_id_of "$dir/t1-c.start.json")
  declare_expectation "$id" same_id_nonexistent_catalog "$id_a" "$id_c" "存在しないCatalog名"
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
  declare_expectation "$id" outputlocation_before_conflict validation_error "$outcome_output" \
    "同じトークン+不正なOutputLocation: $(first_err_line "$dir/t5-bad-output.start.err")"

  run_stmt "$dir" t5-bad-syntax "SELEC 1" "$TCAT_GENERIC" "$TDB" - "$tok"
  local outcome_syntax
  outcome_syntax=$(classify_start_error "$dir/t5-bad-syntax.start.err")
  declare_expectation "$id" syntax_before_conflict validation_error "$outcome_syntax" \
    "同じトークン+構文エラー: $(first_err_line "$dir/t5-bad-syntax.start.err")"
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
  declare_expectation "$id" outputlocation_checked_before_syntax outputlocation "$classification" "$msg"
}

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
  declare_expectation "$id" database_omit_vs_default conflict "$outcome_db" \
    "Database省略 vs 'default'明示: $(first_err_line "$dir/t8-db-explicit.start.err")"

  if [ -z "${TARGET_WG2_OUTPUT:-}" ]; then
    skip_item "$id" t8-output "WORKGROUP2 の OutputLocation が取れないので測れない"
    return 0
  fi
  local tok2
  tok2=$(new_token)
  run_stmt "$dir" t8-output-omit "SELECT 2 AS t8_probe" "$TCAT_GENERIC" "$TDB" "$WORKGROUP2" "$tok2"
  run_stmt "$dir" t8-output-explicit "SELECT 2 AS t8_probe" "$TCAT_GENERIC" "$TDB" "$WORKGROUP2" "$tok2" \
    "$TARGET_WG2_OUTPUT"
  local outcome_output
  outcome_output=$(classify_start_error "$dir/t8-output-explicit.start.err")
  declare_expectation "$id" outputlocation_omit_vs_explicit conflict "$outcome_output" \
    "OutputLocation省略 vs 明示: $(first_err_line "$dir/t8-output-explicit.start.err")"
}
