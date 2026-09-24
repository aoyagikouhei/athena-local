# shellcheck shell=bash
# issue #173: DESCRIBE／SHOW COLUMNS／SHOW SCHEMAS／SHOW TABLES の GetQueryResults の行の形（d1〜d7）。
# 単独では実行しない。run.sh が source して item_d1 などを呼ぶ。
#
# 既存の生データで分かっていること（Hive の DESCRIBE は列名・型を 20 桁に左詰め、20 桁ちょうどは
# 詰めない、空のコメントは空白 20 個、`a<TAB>b` のコメントは `a` で切れる、パーティション付きは
# `# Partition Information` の見出し行群、Iceberg のパーティション無しは `# Table schema:`〜
# `# Partition spec:` の 6 行、SHOW COLUMNS の Hive は 20 桁詰め・Iceberg は詰めない、SHOW TABLES は
# `tab_name`、SHOW DATABASES は `database_name`）は測り直さず、残りを 1 ラウンドで測る:
#   d1 Hive の型の綴りと 20 桁の境界（列名・型・コメントの 19／20／21 文字）。非 ASCII の列名は別テーブル
#   d2 Iceberg のパーティション付き（変換あり）・コメント付きの DESCRIBE と SHOW COLUMNS
#   d3 SHOW SCHEMAS を本物が受けるか・列名（対照 SHOW DATABASES）
#   d4 SHOW TABLES の書き方（LIKE・FROM・パターン文字列）
#   d5 ビューへの DESCRIBE と SHOW COLUMNS
#   d6 DESC（DESCRIBE との対）
#   d7 20 桁を超えるパーティション列名と timestamp（d1 に含む）
#
# 行の形は run_stmt が残す <label>.results-N.json（全ページ）から shape_case が要約し、kind=shape の行で
# summary に出す（ColumnInfo・行数・各行の Data の個数・.txt 本体が行と一致するか、行ごとの repr）。
# SHOW SCHEMAS／SHOW TABLES の結果には利用者の実名（ほかの DB・テーブル）が入るので、行の repr は
# 自分で作った athena_local_probe_173_* と DB に一致する行だけ出し、ほかは本数と空白詰めの有無だけにする。
#
# DDL は CREATE（Hive 外部テーブル・Iceberg・ビュー）と後始末の DROP だけ。Hive 外部テーブルの LOCATION は
# DROP で消えないので record_cleanup_hint に残す。local では CREATE EXTERNAL TABLE が Trino の構文に無く
# 失敗する（u1 と同じ）ので、Hive に依存する文は skip になる。

# 作るテーブル・ビューの接頭辞（#173 の分。run.sh の PROBE_PREFIX は #113 のもの）。
UTIL_PREFIX="athena_local_probe_173"

# FAILED・開始失敗の理由を 1 行で返す（start.err があればそれ、無ければ StateChangeReason）。
util_fail_note() {
  local dir=$1 label=$2 line=""
  if [ -s "$dir/$label.start.err" ]; then
    first_err_line "$dir/$label.start.err"
    return
  fi
  [ -f "$dir/$label.reason.txt" ] && line=$(sed -n 's/^StateChangeReason: //p' "$dir/$label.reason.txt" | head -n 1)
  sanitize "$(redact "${line:-理由不明}")"
}

# <label>.results-*.json を読み、"<サブラベル>\t<要約>" の行を標準出力に出す。
#   mode=rows    行ごとの repr を全部出す（自分で作ったテーブル・ビューの DESCRIBE など）
#   mode=listing 実名が混ざる一覧。接頭辞・DB に一致する行だけ repr、ほかは本数と空白詰めの有無だけ
util_shape_lines() {
  python3 -c 'import glob, json, os, re, sys
from collections import Counter
d, label, mode, prefix, db = sys.argv[1:6]
def page(p):
    m = re.search(r"results-(\d+)\.json$", p)
    return int(m.group(1)) if m else 0
files = sorted(glob.glob(os.path.join(d, label + ".results-*.json")), key=page)
cols, rows, uc = None, [], "(unreadable)"
for i, p in enumerate(files):
    try:
        j = json.load(open(p))
    except Exception:
        continue
    if i == 0:
        v = j.get("UpdateCount")
        uc = "absent" if v is None else v
    rs = j.get("ResultSet", {})
    if cols is None:
        cols = ["%s:%s" % (c.get("Name"), c.get("Type")) for c in rs.get("ResultSetMetadata", {}).get("ColumnInfo", [])]
    for r in rs.get("Rows", []):
        rows.append([x.get("VarCharValue") for x in r.get("Data", [])])
body_path = os.path.join(d, label + ".body.bytes")
if os.path.exists(body_path):
    body = open(body_path, "rb").read().decode("utf-8", "replace")
    joined = "\n".join("\t".join(v if v is not None else "" for v in r) for r in rows)
    txt = "行と一致" if body == joined else "行と不一致(%dB)" % len(body.encode("utf-8"))
else:
    txt = "本体無し"
counts = dict(sorted(Counter(len(r) for r in rows).items()))
print("cols\tColumnInfo=[%s] 行数=%d Data個数=%s UpdateCount=%s .txt=%s" % (
    ",".join(cols or []), len(rows), counts, uc, txt))
def show(r):
    return repr(r[0]) if len(r) == 1 else repr(r)
if mode == "rows":
    for n, r in enumerate(rows[:120], 1):
        print("row-%03d\t%s" % (n, show(r)))
    if len(rows) > 120:
        print("row-more\t残り %d 行は results-*.json を見る" % (len(rows) - 120))
else:
    def hit(r):
        return any(v is not None and (prefix in v or (db and v.rstrip() == db)) for v in r)
    hits = [r for r in rows if hit(r)]
    others = [r for r in rows if not hit(r)]
    padded = sum(1 for r in rows if any(v is not None and v != v.rstrip(" ") for v in r))
    lengths = sorted(set(len(v) for r in rows for v in r if v is not None))
    print("rows\t一致行=%d その他=%d 末尾に空白のある行=%d 値の長さ=%s" % (
        len(hits), len(others), padded, lengths[:12]))
    for n, r in enumerate(hits[:20], 1):
        print("hit-%02d\t%s" % (n, show(r)))' "$@"
}

# 1 文を投げ、行の形を kind=shape の行で summary に足す。失敗したら理由を 1 行。
shape_case() {
  local label=$1 sql=$2 catalog=$3 database=$4 mode=${5:-rows}
  local dir="$RUN_DIR/$CURRENT_ITEM"
  if ! run_stmt "$dir" "$label" "$sql" "$catalog" "$database"; then
    write_summary_row "$CURRENT_ITEM" "$label-shape" shape - - - - - - - - - - - \
      "測れず（$(util_fail_note "$dir" "$label")）"
    return 1
  fi
  local sub note
  while IFS=$'\t' read -r sub note; do
    [ -n "$sub" ] || continue
    write_summary_row "$CURRENT_ITEM" "$label-$sub" shape - - - - - - - - - - - "$note"
  done < <(util_shape_lines "$dir" "$label" "$mode" "$UTIL_PREFIX" "${DB:-}")
  return 0
}

util_info() {
  echo "== $1/$2: $3"
  write_summary_row "$1" "$2" info - - - - - - - - - - - "$3"
}

# d1: Hive の型の綴りと 20 桁の境界。対照（x1 と同じ形）1 本・本題 1 本・非 ASCII の列名 1 本。
# d7（21 文字のパーティション列名 p21_… と timestamp の列）も本題のテーブルに入れてある。
item_d1() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  if probe_prefix_exists "$dir" "$TCAT_HIVE" "$TDB" "${UTIL_PREFIX}_d1"; then
    skip_item "$id" all "同名のテーブルが既にある"
    return 0
  fi
  local ctl="${TDB}.${UTIL_PREFIX}_d1_ctl" main="${TDB}.${UTIL_PREFIX}_d1_main" na="${TDB}.${UTIL_PREFIX}_d1_nonascii"

  # 1. 対照: x1 と同じ作り方（本物で成功済み。既知の形がこのラウンドでも出るかを見る）。
  local ctl_loc="${OUTPUT}tables-probe-173-d1-ctl/"
  run_stmt "$dir" d1-ctl-create \
    "CREATE EXTERNAL TABLE $ctl (n int) PARTITIONED BY (p string) LOCATION '$ctl_loc'" "$TCAT_HIVE" "$TDB"
  local ctl_rc=$?
  record_created TABLE "$ctl" "$TCAT_HIVE" "$TDB"
  if [ "$ctl_rc" -eq 0 ]; then
    shape_case d1-ctl-describe "DESCRIBE $ctl" "$TCAT_HIVE" "$TDB"
  else
    skip_item "$id" ctl "対照の Hive 外部テーブルを作れなかった（local では想定どおり）: $(util_fail_note "$dir" d1-ctl-create)"
  fi
  best_effort_drop TABLE "$ctl" "$TCAT_HIVE" "$TDB"
  record_cleanup_hint "d1 ctl hive ext: $ctl_loc"

  # 2. 本題: 列名 19/20/21 文字、型 17 種（struct は型名が 20／21 文字）、コメント無し・短い・20／21 文字。
  local main_loc="${OUTPUT}tables-probe-173-d1-main/"
  local cols="c19_aaaaaaaaaaaaaaa int, c20_aaaaaaaaaaaaaaaa int, c21_aaaaaaaaaaaaaaaaa int"
  cols+=", t_bigint bigint, t_smallint smallint, t_tinyint tinyint, t_double double, t_float float"
  cols+=", t_boolean boolean, t_date date, t_decimal decimal(10,2), t_varchar varchar(10), t_char char(36)"
  cols+=", t_string string, t_timestamp timestamp, t_binary binary, t_array array<string>"
  cols+=", t_map map<string,int>, t_struct20 struct<aa:int,b:int>, t_struct21 struct<aa:int,bb:int>"
  cols+=", m_none int, m_abc int COMMENT 'abc', m_c20 int COMMENT 'cmt20_bbbbbbbbbbbbbb'"
  cols+=", m_c21 int COMMENT 'cmt21_bbbbbbbbbbbbbbb'"
  run_stmt "$dir" d1-main-create \
    "CREATE EXTERNAL TABLE $main ($cols) PARTITIONED BY (p string COMMENT 'pc', q int, p21_aaaaaaaaaaaaaaaaa string) LOCATION '$main_loc'" \
    "$TCAT_HIVE" "$TDB"
  local main_rc=$?
  record_created TABLE "$main" "$TCAT_HIVE" "$TDB"
  if [ "$main_rc" -eq 0 ]; then
    shape_case d1-main-describe "DESCRIBE $main" "$TCAT_HIVE" "$TDB"
    shape_case d1-main-show-columns-from "SHOW COLUMNS FROM $main" "$TCAT_HIVE" "$TDB"
    shape_case d1-main-show-columns-in "SHOW COLUMNS IN $main" "$TCAT_HIVE" "$TDB"
  else
    skip_item "$id" main "本題の Hive 外部テーブルを作れなかった（local では想定どおり）: $(util_fail_note "$dir" d1-main-create)"
  fi
  best_effort_drop TABLE "$main" "$TCAT_HIVE" "$TDB"
  record_cleanup_hint "d1 main hive ext: $main_loc"
  # 改行入りのコメントは Glue の列コメントの制約で CREATE ごと落ちる（#146 の r2。2026-09-24 実測）。
  skip_item "$id" comment-lf "改行入りの列コメントは Glue が ValidationException で弾く（#146 r2 で実測済み）ので投げない"

  # 3. 非 ASCII の列名（20 桁が文字数かバイト数か）。失敗しても 1・2 には影響しない。
  local na_loc="${OUTPUT}tables-probe-173-d1-nonascii/"
  run_stmt "$dir" d1-nonascii-create \
    "CREATE EXTERNAL TABLE $na (\`列名\` int COMMENT 'コメント', n int) LOCATION '$na_loc'" "$TCAT_HIVE" "$TDB"
  local na_rc=$?
  record_created TABLE "$na" "$TCAT_HIVE" "$TDB"
  if [ "$na_rc" -eq 0 ]; then
    shape_case d1-nonascii-describe "DESCRIBE $na" "$TCAT_HIVE" "$TDB"
    shape_case d1-nonascii-show-columns "SHOW COLUMNS FROM $na" "$TCAT_HIVE" "$TDB"
  else
    skip_item "$id" nonascii "非 ASCII の列名のテーブルを作れなかった: $(util_fail_note "$dir" d1-nonascii-create)"
  fi
  best_effort_drop TABLE "$na" "$TCAT_HIVE" "$TDB"
  record_cleanup_hint "d1 nonascii hive ext: $na_loc"
}

# d2: Iceberg のパーティション付き（識別・bucket・day）・コメント付きの DESCRIBE と SHOW COLUMNS。
# 変換付きの PARTITIONED BY が通らなければ PARTITIONED BY (s) に落とし、落とした理由を info に出す。
item_d2() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  if probe_prefix_exists "$dir" "$TCAT_ICEBERG" "$TDB" "${UTIL_PREFIX}_d2"; then
    skip_item "$id" all "同名のテーブルが既にある"
    return 0
  fi
  local t="${TDB}.${UTIL_PREFIX}_d2"
  local loc="${OUTPUT}tables-probe-173-d2/"
  local full_sql fallback_sql
  if [ "$TARGET" = local ]; then
    # Trino の Iceberg の綴り（local のドライラン用。本物に投げる文は下の else）。
    local tcols="n integer COMMENT 'abc', s varchar, ts timestamp(6), d decimal(10,2), arr array(varchar)"
    tcols+=", st row(a integer), c21_aaaaaaaaaaaaaaaaa bigint"
    full_sql="CREATE TABLE $t ($tcols) WITH (partitioning = ARRAY['s', 'bucket(n, 4)', 'day(ts)'])"
    fallback_sql="CREATE TABLE $t ($tcols) WITH (partitioning = ARRAY['s'])"
  else
    local cols="n int COMMENT 'abc', s string, ts timestamp, d decimal(10,2), arr array<string>"
    cols+=", st struct<a:int>, c21_aaaaaaaaaaaaaaaaa bigint"
    local props="LOCATION '$loc' TBLPROPERTIES ('table_type'='ICEBERG')"
    full_sql="CREATE TABLE $t ($cols) PARTITIONED BY (s, bucket(4, n), day(ts)) $props"
    fallback_sql="CREATE TABLE $t ($cols) PARTITIONED BY (s) $props"
  fi
  run_stmt "$dir" d2-create "$full_sql" "$TCAT_ICEBERG" "$TDB"
  local rc=$?
  record_created TABLE "$t" "$TCAT_ICEBERG" "$TDB"
  if [ "$rc" -eq 0 ]; then
    util_info "$id" partitioning "PARTITIONED BY (s, bucket(4, n), day(ts)) で作れた"
  else
    util_info "$id" partitioning "変換付きが通らず PARTITIONED BY (s) に落とす: $(util_fail_note "$dir" d2-create)"
    run_stmt "$dir" d2-create-fallback "$fallback_sql" "$TCAT_ICEBERG" "$TDB"
    rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    shape_case d2-describe "DESCRIBE $t" "$TCAT_ICEBERG" "$TDB"
    shape_case d2-show-columns "SHOW COLUMNS FROM $t" "$TCAT_ICEBERG" "$TDB"
  else
    skip_item "$id" iceberg "Iceberg のテーブルを作れなかった: $(util_fail_note "$dir" d2-create-fallback)"
  fi
  best_effort_drop TABLE "$t" "$TCAT_ICEBERG" "$TDB"
}

# d3: SHOW SCHEMAS を本物が受けるか・列名。対照は SHOW DATABASES。パターンは Athena の文書の `*` と、
# issue の書き方の `%` の両方（`%` はリテラル扱いかもしれない。probe_prefix_exists の注記）。
# 結果には利用者の DB 名が入るので listing で要約する（DB 自体の行だけ repr、マスク済み）。
item_d3() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  local head3=${TDB:0:3}
  shape_case d3-show-schemas "SHOW SCHEMAS" "$TCAT_GENERIC" "$TDB" listing
  shape_case d3-show-schemas-like-star "SHOW SCHEMAS LIKE '${head3}*'" "$TCAT_GENERIC" "$TDB" listing
  shape_case d3-show-schemas-like-pct "SHOW SCHEMAS LIKE '${head3}%'" "$TCAT_GENERIC" "$TDB" listing
  shape_case d3-show-databases "SHOW DATABASES" "$TCAT_GENERIC" "$TDB" listing
  shape_case d3-show-databases-like-star "SHOW DATABASES LIKE '${head3}*'" "$TCAT_GENERIC" "$TDB" listing
  shape_case d3-show-databases-like-pct "SHOW DATABASES LIKE '${head3}%'" "$TCAT_GENERIC" "$TDB" listing
}

# d4: SHOW TABLES の書き方。当たる行を作るため Iceberg のテーブルを 1 本作る（u1 と同じ作り方）。
# 対照は素の SHOW TABLES。結果には利用者のテーブル名が入るので listing で要約する。
item_d4() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  if probe_prefix_exists "$dir" "$TCAT_ICEBERG" "$TDB" "${UTIL_PREFIX}_d4"; then
    skip_item "$id" all "同名のテーブルが既にある"
    return 0
  fi
  local name="${UTIL_PREFIX}_d4_t" t="${TDB}.${UTIL_PREFIX}_d4_t"
  local sql
  if [ "$TARGET" = local ]; then
    sql="CREATE TABLE $t (n int)"
  else
    sql="CREATE TABLE $t (n int) LOCATION '${OUTPUT}tables-probe-173-d4/' TBLPROPERTIES ('table_type'='ICEBERG')"
  fi
  run_stmt "$dir" d4-create "$sql" "$TCAT_ICEBERG" "$TDB"
  local rc=$?
  record_created TABLE "$t" "$TCAT_ICEBERG" "$TDB"
  if [ "$rc" -ne 0 ]; then
    util_info "$id" fixture "当たる行のテーブルを作れなかった（0 行の形だけ測る）: $(util_fail_note "$dir" d4-create)"
  fi
  shape_case d4-control "SHOW TABLES" "$TCAT_ICEBERG" "$TDB" listing
  shape_case d4-in-like "SHOW TABLES IN $TDB LIKE '${UTIL_PREFIX}_d4*'" "$TCAT_ICEBERG" "$TDB" listing
  shape_case d4-from "SHOW TABLES FROM $TDB" "$TCAT_ICEBERG" "$TDB" listing
  shape_case d4-in-regex "SHOW TABLES IN $TDB '${UTIL_PREFIX}_d4.*'" "$TCAT_ICEBERG" "$TDB" listing
  shape_case d4-in-exact "SHOW TABLES IN $TDB '$name'" "$TCAT_ICEBERG" "$TDB" listing
  best_effort_drop TABLE "$t" "$TCAT_ICEBERG" "$TDB"
}

# d5: ビューへの DESCRIBE と SHOW COLUMNS（r4 と同じく Iceberg のカタログで作る）。
item_d5() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  if probe_prefix_exists "$dir" "$TCAT_ICEBERG" "$TDB" "${UTIL_PREFIX}_d5"; then
    skip_item "$id" all "同名のテーブル/ビューが既にある"
    return 0
  fi
  local v="${TDB}.${UTIL_PREFIX}_d5_view"
  run_stmt "$dir" d5-create-view "CREATE VIEW $v AS SELECT 1 AS n, 'a' AS s" "$TCAT_ICEBERG" "$TDB"
  local rc=$?
  record_created VIEW "$v" "$TCAT_ICEBERG" "$TDB"
  if [ "$rc" -eq 0 ]; then
    shape_case d5-describe "DESCRIBE $v" "$TCAT_ICEBERG" "$TDB"
    shape_case d5-show-columns "SHOW COLUMNS FROM $v" "$TCAT_ICEBERG" "$TDB"
  else
    skip_item "$id" view "ビューを作れなかった: $(util_fail_note "$dir" d5-create-view)"
  fi
  best_effort_drop VIEW "$v" "$TCAT_ICEBERG" "$TDB"
}

# d6: DESC と DESCRIBE の対。d1 と独立に skip できるよう、d1 の対照と同じ形の Hive 外部テーブルを自分で作る。
item_d6() {
  local id=$1 dir="$RUN_DIR/$id"
  mkdir -p "$dir"
  if probe_prefix_exists "$dir" "$TCAT_HIVE" "$TDB" "${UTIL_PREFIX}_d6"; then
    skip_item "$id" all "同名のテーブルが既にある"
    return 0
  fi
  local t="${TDB}.${UTIL_PREFIX}_d6" loc="${OUTPUT}tables-probe-173-d6/"
  run_stmt "$dir" d6-create \
    "CREATE EXTERNAL TABLE $t (n int) PARTITIONED BY (p string) LOCATION '$loc'" "$TCAT_HIVE" "$TDB"
  local rc=$?
  record_created TABLE "$t" "$TCAT_HIVE" "$TDB"
  if [ "$rc" -eq 0 ]; then
    shape_case d6-describe "DESCRIBE $t" "$TCAT_HIVE" "$TDB"
    shape_case d6-desc "DESC $t" "$TCAT_HIVE" "$TDB"
  else
    skip_item "$id" hive "Hive の外部テーブルを作れなかった（local では想定どおり）: $(util_fail_note "$dir" d6-create)"
  fi
  best_effort_drop TABLE "$t" "$TCAT_HIVE" "$TDB"
  record_cleanup_hint "d6 hive ext: $loc"
}

# d7: d1 の本題のテーブルに含めた（21 文字のパーティション列 p21_aaaaaaaaaaaaaaaaa と t_timestamp）。
# 本物への呼び出しは無い。d1 を流さずに d7 だけ選んでも何も測らないことを summary に出す。
item_d7() {
  local id=$1
  if want_item d1; then
    util_info "$id" included "d1 に含む（d1-main の p21_aaaaaaaaaaaaaaaaa と t_timestamp。d1-main-* の行を見る）"
  else
    skip_item "$id" included "d1 に含む。ONLY に d1 が無いので未測定"
  fi
}
