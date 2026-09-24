# shellcheck shell=bash
# issue #157: GetQueryExecution の QueryExecutionContext（Catalog / Database）を本物がどう返すか（c1）。
# 単独では実行しない。run.sh が source して item_c1 を呼ぶ。
#
# #146 の t1 で、`AwsDataCatalog` を渡した実行の Catalog が小文字 `awsdatacatalog` で返った。
# それ以外（大文字・混在の Catalog、大文字の Database、Catalog の省略、実在しない Catalog、
# AwsDataCatalog 以外のカタログ）は未実測。SELECT 1 と SHOW TABLES だけで、DDL も書き込みも無い。
# 本物への呼び出しは StartQueryExecution 10 本 + ListDataCatalogs 1 本 + 追加カタログ 1 本ずつ（最大 3）。
#
# athena-local は送られた値をそのまま返す（src/operation/query_execution.rs）ので、local の
# 期待値は「送ったまま」。省略した項目は athena-local が既定を当てて返すので期待値を置かず記録だけ。

# execution.json の QueryExecutionContext を "Catalog=<値|(absent)> Database=<値|(absent)>" の形にする。
context_of() {
  python3 -c 'import json,sys
try:
    ctx = json.load(open(sys.argv[1]))["QueryExecution"].get("QueryExecutionContext") or {}
except Exception:
    print("(unreadable)"); sys.exit()
print("Catalog=%s Database=%s" % (ctx.get("Catalog", "(absent)"), ctx.get("Database", "(absent)")))' "$1"
}

# 1 文を投げ、送った Catalog / Database と返った QueryExecutionContext を並べた行を書く。
# 第 5 引数 expected は local の期待値（空なら記録だけ）。
echo_case() {
  local label=$1 sql=$2 catalog=$3 database=$4 expected=${5:-}
  local dir="$RUN_DIR/$CURRENT_ITEM"
  local sent="sent Catalog=$catalog Database=$database"
  if ! run_stmt "$dir" "$label" "$sql" "$catalog" "$database"; then
    if [ ! -s "$dir/$label.start.json" ]; then
      write_summary_row "$CURRENT_ITEM" "$label-echo" stmt - - - - - - - - - - - \
        "$sent -> 開始できず: $(first_err_line "$dir/$label.start.err")"
      return 0
    fi
  fi
  local got
  got=$(context_of "$dir/$label.execution.json")
  if [ "$TARGET" = local ] && [ -n "$expected" ]; then
    declare_expectation "$CURRENT_ITEM" "$label-echo" "$expected" "$got" "$sent"
  else
    write_summary_row "$CURRENT_ITEM" "$label-echo" stmt - - - - - - - - - - - "$sent -> returned $got"
  fi
}

swapcase() { python3 -c 'import sys; print(sys.argv[1].swapcase())' "$1"; }

# c1: Catalog / Database の大文字小文字・省略・実在しない名前・追加カタログで、応答の表示を見る。
item_c1() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  local sql="SELECT 1 AS c1_probe"
  local cat_upper="${TCAT_GENERIC^^}" cat_mixed db_upper="${TDB^^}" db_mixed
  cat_mixed=$(swapcase "$TCAT_GENERIC")
  db_mixed=$(swapcase "$TDB")

  # 対照（t1 の再現）と、Catalog だけ変えた 3 通り。
  echo_case c1-control "$sql" "$TCAT_GENERIC" "$TDB" "Catalog=$TCAT_GENERIC Database=$TDB"
  echo_case c1-cat-upper "$sql" "$cat_upper" "$TDB" "Catalog=$cat_upper Database=$TDB"
  echo_case c1-cat-mixed "$sql" "$cat_mixed" "$TDB" "Catalog=$cat_mixed Database=$TDB"
  echo_case c1-cat-omit "$sql" - "$TDB"
  # Database だけ変えた 3 通り。
  echo_case c1-db-upper "$sql" "$TCAT_GENERIC" "$db_upper" "Catalog=$TCAT_GENERIC Database=$db_upper"
  echo_case c1-db-mixed "$sql" "$TCAT_GENERIC" "$db_mixed" "Catalog=$TCAT_GENERIC Database=$db_mixed"
  echo_case c1-db-omit "$sql" "$TCAT_GENERIC" -
  # 実在しない Catalog（混在ケース。新しいトークンなので #146 の t1-c と違い衝突にはならない）。
  echo_case c1-cat-nonexistent "$sql" "Athena_Local_Probe_157_No_Such_Catalog" "$TDB" \
    "Catalog=Athena_Local_Probe_157_No_Such_Catalog Database=$TDB"
  # 名前の解決が大文字小文字を区別するか（SHOW TABLES は Database を実際に引く）。
  echo_case c1-resolve-cat-upper "SHOW TABLES" "$cat_upper" "$TDB" "Catalog=$cat_upper Database=$TDB"
  echo_case c1-resolve-db-upper "SHOW TABLES" "$TCAT_GENERIC" "$db_upper" "Catalog=$TCAT_GENERIC Database=$db_upper"

  # AwsDataCatalog 以外のカタログ。EXTRA_CATALOGS（カンマ区切り）があればそれを、real では
  # ListDataCatalogs で見つかったものも（AwsDataCatalog を除き最大 3 つ）。
  local extras=()
  if [ -n "${EXTRA_CATALOGS:-}" ]; then
    IFS=, read -r -a extras <<<"$EXTRA_CATALOGS"
  fi
  if [ "$TARGET" = real ]; then
    if athena_cli list-data-catalogs >"$dir/list-data-catalogs.json" 2>"$dir/list-data-catalogs.err"; then
      while IFS= read -r name; do
        [ -n "$name" ] && extras+=("$name")
      done < <(python3 -c 'import json,sys
names = [c["CatalogName"] for c in json.load(open(sys.argv[1])).get("DataCatalogsSummary", [])]
names = [n for n in names if n.lower() != sys.argv[2].lower()]
print("\n".join(names[:3]))' "$dir/list-data-catalogs.json" "$TCAT_GENERIC")
      write_summary_row "$id" list-data-catalogs stmt - - - - - - - - - - - \
        "ListDataCatalogs: $(python3 -c 'import json,sys
print(", ".join("%s(%s)" % (c["CatalogName"], c.get("Type", "?")) for c in json.load(open(sys.argv[1])).get("DataCatalogsSummary", [])))' "$dir/list-data-catalogs.json")"
    else
      skip_item "$id" list-data-catalogs "ListDataCatalogs が失敗: $(first_err_line "$dir/list-data-catalogs.err")"
    fi
  fi
  if [ "${#extras[@]}" -eq 0 ]; then
    skip_item "$id" extra-catalog "AwsDataCatalog 以外のカタログが無い（EXTRA_CATALOGS で渡せる）"
    return 0
  fi
  local n=0 extra
  for extra in "${extras[@]}"; do
    n=$((n + 1))
    echo_case "c1-extra-$n" "$sql" "$extra" "$TDB" "Catalog=$extra Database=$TDB"
  done
}
