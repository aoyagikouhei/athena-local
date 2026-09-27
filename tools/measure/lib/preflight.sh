#!/usr/bin/env bash
# 実行系の能力確認・DB の自動選択・PREFIX の衝突確認。#310 フェーズ2。
# describe-extended.sh:799-935（#275）の考え方の移植。lib_init が（定義されていれば）
# 宣言の前に呼ぶ口を持っている（lib.sh 参照）ので、ここで定義するだけでよい。

# 本物のとき OUTPUT が空なら、S3 に書けないまま進めても後で必ず落ちるので先に止める。
# DRY_RUN=1 は lib_init が既に既定値を補っているのでここには来ない。
_lib_preflight_require_output() {
  if [ "${DRY_RUN:-0}" != 1 ] && [ -z "$OUTPUT" ]; then
    echo "OUTPUT が空です。s3://bucket/prefix/ を指定してください。" >&2
    exit 1
  fi
}

# (a) list-work-groups が通るか（retry_aws で一時的な失敗だけ再試行）。通らなければ、
# 本物の Athena に1本も投げられていないことを示して止まる。
_lib_preflight_list_work_groups() {
  if ! retry_aws "$RUN_DIR/preflight-list-work-groups.json" "$RUN_DIR/preflight-list-work-groups.err" \
    aws athena list-work-groups --region "$REGION"; then
    echo "aws athena list-work-groups が通りません（本物の Athena には1本も投げていません）。" >&2
    echo "aws コマンド・資格情報・REGION（$REGION）を確かめてください。理由: $(first_err_line "$RUN_DIR/preflight-list-work-groups.err")" >&2
    exit 1
  fi
}

# (b) python3 で json を読めるか。
_lib_preflight_python3() {
  if ! python3 -c 'import json, sys' > /dev/null 2> "$RUN_DIR/preflight-python.err"; then
    echo "python3 で json を読み込めません（$(first_err_line "$RUN_DIR/preflight-python.err")）。" >&2
    exit 1
  fi
}

# (c) sts get-caller-identity はベストエフォート。取れたら Account/Arn/末尾の名前を
# マスク対象に足す（summary.txt に呼び出し元の identity が出ないようにする）。
_lib_preflight_caller_identity() {
  if retry_aws "$RUN_DIR/caller-identity.json" "$RUN_DIR/caller-identity.err" \
    aws sts get-caller-identity --region "$REGION"; then
    local caller_arn caller_account
    caller_arn=$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("Arn") or "")
except Exception:
    print("")' "$RUN_DIR/caller-identity.json")
    caller_account=$(python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get("Account") or "")
except Exception:
    print("")' "$RUN_DIR/caller-identity.json")
    add_hide_pair "$caller_arn" "<CALLER_ARN>"
    add_hide_pair "$caller_account" "<CALLER_ACCOUNT>"
    add_hide_pair "${caller_arn##*/}" "<CALLER_NAME>"
  fi
}

# (d)+(e) DB の自動選択と PREFIX の衝突確認を1本の SHOW TABLES で兼ねる。
# DB が指定されていれば、まずそれで SHOW TABLES を試す（実在確認）。無いか失敗すれば
# SHOW DATABASES の1件目を DB にして SHOW TABLES を取り直す。どちらの経路でも id は
# 同じ preflight-list-tables（後勝ちでファイルが残る）。run_query を使うので、この2つの
# 項目も summary と課金（START_CALL_FILE）に数えられる。
_lib_preflight_select_db() {
  local tables_ok=0
  if [ -n "$DB" ] && run_query preflight-list-tables db "SHOW TABLES"; then
    tables_ok=1
  fi

  if [ "$tables_ok" != 1 ]; then
    if ! run_query preflight-databases catalog "SHOW DATABASES"; then
      echo "DB を自動選択できません（SHOW DATABASES が失敗しました）。資格情報・REGION（$REGION）・権限を確かめてください。" >&2
      exit 1
    fi
    DB=$(head -n1 "$RUN_DIR/preflight-databases.results.rows.txt" 2> /dev/null)
    if [ -z "$DB" ]; then
      echo "SHOW DATABASES の結果からデータベース名を読めませんでした。" >&2
      exit 1
    fi
    if ! run_query preflight-list-tables db "SHOW TABLES"; then
      echo "自動選択したデータベースで SHOW TABLES が通りませんでした。" >&2
      exit 1
    fi
  fi

  if [ ! -f "$RUN_DIR/preflight-list-tables.results.rows.txt" ]; then
    echo "SHOW TABLES の結果を取得できず、${PREFIX} を含む表が無いことを確認できません。安全のため何も作らずに止まります。" >&2
    exit 1
  fi
  if [ -s "$RUN_DIR/preflight-list-tables.results.rows.txt" ] && grep -qF "$PREFIX" "$RUN_DIR/preflight-list-tables.results.rows.txt"; then
    echo "このデータベースに ${PREFIX} を含む表・ビューが既にあります。上書き事故を避けるため、何も作らずに止まります。" >&2
    exit 1
  fi
}

# 決まった DB・OUTPUT をマスク対象に足す（バケット名は s3://bucket/prefix/ の bucket 部分）。
_lib_preflight_hide_targets() {
  local bucket=${OUTPUT#s3://}
  bucket=${bucket%%/*}
  add_hide_pair "$DB" "<DB>"
  add_hide_pair "$OUTPUT" "<OUTPUT>"
  add_hide_pair "$bucket" "<BUCKET>"
}

# lib_init が宣言の前に呼ぶ（定義されていれば、の口は lib.sh 側にある）。
lib_preflight() {
  _lib_preflight_require_output
  _lib_preflight_list_work_groups
  _lib_preflight_python3
  _lib_preflight_caller_identity
  _lib_preflight_select_db
  _lib_preflight_hide_targets
}
