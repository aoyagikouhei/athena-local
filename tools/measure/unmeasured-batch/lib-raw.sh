# shellcheck shell=bash
# issue #113: 生 HTTP の項目（raw.py）を呼んで summary.tsv の 15 列に変える。run.sh が source する。

# --- 生 HTTP（raw.py） -------------------------------------------------------
# t2・t3・t4・e2（items-token.sh, items-workgroup-errors.sh）と preflight が使う。
# RAW_ENDPOINT・RAW_TARGET は run.sh が TARGET から決めて export する。

# raw.py <item> を呼び、標準出力の TSV 行（item, case, status, detail）をそれぞれ
# summary.tsv の 15 列（kind=stmt。文の統計にならない列は "-"）に変換して追記する。
run_raw_item() {
  local item_id=$1
  local dir="$RUN_DIR/$item_id"
  mkdir -p "$dir"
  local out rc
  out=$(python3 "$SCRIPT_DIR/raw.py" "$item_id" \
    --endpoint "$RAW_ENDPOINT" --region "$REGION" --out-dir "$dir" \
    --output "$OUTPUT" --catalog "$TCAT_GENERIC" --database "$TDB" --target "$RAW_TARGET" \
    2>"$dir/raw.err")
  rc=$?
  if [ -z "$out" ]; then
    write_summary_row "$item_id" "$item_id" stmt RAW_FAILED - - - - - - - - - - \
      "raw.py が出力しませんでした(rc=$rc)。$dir/raw.err を見る"
    return 1
  fi
  local r_item r_case r_status r_detail
  while IFS=$'\t' read -r r_item r_case r_status r_detail; do
    [ -n "$r_item" ] || continue
    write_summary_row "$item_id" "$r_case" stmt "$r_status" - - - - - - - - - - "$r_detail"
  done <<<"$out"
  return "$rc"
}

# ListWorkGroups を生 HTTP で 1 回だけ通す。aws CLI の SELECT 1 とは独立の疎通確認。
# 失敗すれば呼び出し側が本物の項目を 1 本も投げずに止める。TARGET=local では、応答に
# 記録された送り先の URL を LOCAL_ATHENA_BASE と突き合わせて declare_expectation する
# （raw.py が本物へ向いてしまう経路が無いことの確認。受け入れ判定2）。
raw_preflight() {
  local dir="$RUN_DIR/.preflight"
  mkdir -p "$dir"
  local out rc
  out=$(python3 "$SCRIPT_DIR/raw.py" preflight --endpoint "$RAW_ENDPOINT" --region "$REGION" \
    --out-dir "$dir" --target "$RAW_TARGET" 2>"$dir/raw-preflight.err")
  rc=$?
  echo "== raw.py preflight: $out"
  if [ "$rc" -ne 0 ]; then
    echo "run.sh: raw.py preflight（ListWorkGroups）が失敗しました（rc=$rc）。$dir を見る。" >&2
    echo "        本物の項目は1本も投げていません。" >&2
    exit 1
  fi
  if [ "$RAW_TARGET" = local ]; then
    local actual_endpoint
    actual_endpoint=$(python3 -c 'import json, sys
try: print(json.load(open(sys.argv[1])).get("endpoint", ""))
except Exception: print("")' "$dir/preflight.json")
    declare_expectation preflight raw_endpoint "${LOCAL_ATHENA_BASE}/" "$actual_endpoint" "raw.py(preflight)の送り先"
  fi
}
