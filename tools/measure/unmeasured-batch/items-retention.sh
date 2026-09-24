# shellcheck shell=bash
# issue #113（フェーズ2）: t6・t7（保持期限）。単独では実行しない。run.sh の「フェーズ 2 の
# 差し込み口」が retention_phase_a（本編の前）／retention_phase_b（本編の後・report.py の前）
# を呼ぶ。段階 A は ONLY に t6 があるとき、段階 B は t7 があるときだけ動く（#147）。
# 1 本のトークンの往復が 段階 A（t6）→ 他の項目 → 締切まで待つ → 段階 B（t7）という
# 1 つの流れで、`ONLY=t6` → 65 分以上あとに `RUN_DIR=<同じ run> ONLY=t7` と 2 回に分けられる。
#
# 待ち時間: real は 65 分固定。local は run.sh が athena-local に渡した保持期限
# （LOCAL_RETENTION_SECONDS、既定 120 秒）+ 5 秒。段階 A の完了時刻に足した締切を
# state.env の DEADLINE に残し、段階 B はその時刻まで（既に過ぎていれば待たずに）待つ。
# 他の項目（本編）が締切より長くかかっていれば、段階 B の実際の待ちは 0 になる。
#
# RUN_DIR の再開: state.env が既にあれば段階 A は投げ直さず、保存済みのトークン・ID・
# 締切をそのまま使う。
#
# 使う lib-aws.sh の関数: new_token・run_stmt・query_execution_id_of・first_err_line・
# write_summary_row・declare_expectation・skip_item・reset_item_rows・athena_cli。
# want_item は run.sh 本体で定義する（RETENTION_SELECTED の計算にも使う）。

RETENTION_DIR="$RUN_DIR/retention"
RETENTION_STATE="$RETENTION_DIR/state.env"
RETENTION_WAIT_REAL_SECONDS=$((65 * 60))

# 段階A: トークン付きの軽い文を投げて待ち、直後に同じトークンで再送して対照を取る。
# 締切を state.env に残す。既に state.env があれば投げ直さない（再開）。
retention_phase_a() {
  mkdir -p "$RETENTION_DIR"
  CURRENT_ITEM=t6

  if [ -s "$RETENTION_STATE" ]; then
    echo "== t6: 既に $RETENTION_STATE があるので投げ直さない（再開）"
    write_summary_row t6 phase-a skip - - - - - - - - - - - "既存の state.env を使う（再開）"
    return 0
  fi

  local tok
  tok=$(new_token)
  if ! run_stmt "$RETENTION_DIR" t6-first "SELECT 1 AS t6_probe" "$TCAT_GENERIC" "$TDB" - "$tok"; then
    echo "== t6: 1回目が SUCCEEDED になりませんでした（保持期限は測れない）"
    return 1
  fi
  local id
  id=$(query_execution_id_of "$RETENTION_DIR/t6-first.start.json")

  # 直後の対照。期限内なので同じ ID が返るはず（real・local とも）。
  run_stmt "$RETENTION_DIR" t6-immediate-reuse "SELECT 1 AS t6_probe" "$TCAT_GENERIC" "$TDB" - "$tok" >/dev/null
  local reuse_id same
  reuse_id=$(query_execution_id_of "$RETENTION_DIR/t6-immediate-reuse.start.json")
  same=$([ "$id" = "$reuse_id" ] && echo yes || echo no)
  write_summary_row t6 immediate-reuse-compare stmt - - - - - - - - - - - \
    "元id=$id 再送id=$reuse_id 一致=$same"

  local wait_seconds
  if [ "$TARGET" = local ]; then
    wait_seconds=$((LOCAL_RETENTION_SECONDS + 5))
  else
    wait_seconds=$RETENTION_WAIT_REAL_SECONDS
  fi
  local deadline=$(($(date +%s) + wait_seconds))
  {
    printf 'TOKEN=%q\n' "$tok"
    printf 'ID=%s\n' "$id"
    printf 'DEADLINE=%s\n' "$deadline"
  } >"$RETENTION_STATE"
  echo "== t6: 段階A完了。id=$id 締切まで ${wait_seconds} 秒"
}

# 段階B: 締切まで待ち（既に過ぎていれば待たない）、同じトークンで再送・GetQueryExecution・
# StopQueryExecution を試す。local では期待値を declare_expectation で宣言する
# （再送は新しい ID、GetQueryExecution/StopQueryExecution は QUERY_EXECUTION_NOT_FOUND
# 相当。src/store.rs の Inner::sweep、src/operation/query_execution.rs の unknown_execution）。
retention_phase_b() {
  CURRENT_ITEM=t7
  if [ ! -s "$RETENTION_STATE" ]; then
    write_summary_row t7 phase-b skip - - - - - - - - - - - "段階Aの state.env が無い（段階Aが失敗した）"
    return 0
  fi
  # shellcheck disable=SC1090
  . "$RETENTION_STATE"

  local now remaining
  now=$(date +%s)
  if [ "$now" -lt "$DEADLINE" ]; then
    remaining=$((DEADLINE - now))
    echo "== t7: 保持期限の締切まで ${remaining} 秒待つ"
    sleep "$remaining"
  fi

  retention_check_reuse
  retention_check_get
  retention_check_stop
}

# 締切後に同じトークンで再送する。local は「新しい ID」が期待値。
retention_check_reuse() {
  run_stmt "$RETENTION_DIR" t7-reuse-after-wait "SELECT 1 AS t6_probe" "$TCAT_GENERIC" "$TDB" - "$TOKEN" >/dev/null
  local reuse_id kind
  reuse_id=$(query_execution_id_of "$RETENTION_DIR/t7-reuse-after-wait.start.json")
  if [ -z "$reuse_id" ]; then
    kind=error
  elif [ "$reuse_id" = "$ID" ]; then
    kind=same_id
  else
    kind=new_id
  fi
  if [ "$TARGET" = local ]; then
    declare_expectation t7 reuse_after_wait new_id "$kind" "元id=$ID 再送id=$reuse_id"
  else
    write_summary_row t7 reuse-after-wait stmt - - - - - - - - - - - "元id=$ID 再送id=$reuse_id 種別=$kind"
  fi
}

# 締切後に元の ID へ GetQueryExecution。local は QUERY_EXECUTION_NOT_FOUND 相当が期待値。
retention_check_get() {
  local rc not_found=no detail
  athena_cli get-query-execution --query-execution-id "$ID" \
    >"$RETENTION_DIR/t7-get.json" 2>"$RETENTION_DIR/t7-get.err"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    detail="成功（保持されたまま）"
  else
    detail=$(first_err_line "$RETENTION_DIR/t7-get.err")
    echo "$detail" | grep -qi 'was not found\|QUERY_EXECUTION_NOT_FOUND' && not_found=yes
  fi
  write_summary_row t7 get-query-execution stmt - - - - - - - - - - - "$detail"
  [ "$TARGET" = local ] && declare_expectation t7 get_after_wait_not_found yes "$not_found" "$detail"
}

# 締切後に元の ID へ StopQueryExecution。local は同じく QUERY_EXECUTION_NOT_FOUND 相当。
retention_check_stop() {
  local rc not_found=no detail
  athena_cli stop-query-execution --query-execution-id "$ID" \
    >"$RETENTION_DIR/t7-stop.json" 2>"$RETENTION_DIR/t7-stop.err"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    detail="成功"
  else
    detail=$(first_err_line "$RETENTION_DIR/t7-stop.err")
    echo "$detail" | grep -qi 'was not found\|QUERY_EXECUTION_NOT_FOUND' && not_found=yes
  fi
  write_summary_row t7 stop-query-execution stmt - - - - - - - - - - - "$detail"
  [ "$TARGET" = local ] && declare_expectation t7 stop_after_wait_not_found yes "$not_found" "$detail"
}
