#!/usr/bin/env bash
# issue #307: Hive・Iceberg の DESCRIBE で測っていない型の綴り・2 フィールドの struct の区切りと、
# SHOW SCHEMAS／SHOW DATABASES の LIKE のパターンの意味を本物の Athena で測る。
# #310 の lib.sh の最初の利用者。
#
# 使い方: tools/dev.sh env OUTPUT=s3://your-bucket/prefix/ [DB=your_db] bash tools/measure/describe-types.sh
#         受け入れ判定: tools/dev.sh env DRY_RUN=1 bash tools/measure/describe-types.sh
#
# 型は Athena の文書（data-types.html、querying-iceberg-supported-data-types.html）で DDL に書けるものを CREATE で、
# DDL では「Not available」のもの（time・timestamp with time zone・interval・json・uuid）は型ごとの CTAS で作れるかから測る。
# パーティション変換は文書の表（year・month・day・hour・bucket・truncate）を #173 で全部測ったので、void などは skip にする。
# DDL: CREATE 2・CTAS 最大 10・DROP は作れた分だけ。スキャンは CTAS の 1 行のリテラルだけ。
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
lib_init 307 athena_local_probe_307

T_H="${PREFIX}_h"; T_I="${PREFIX}_i"
loc() { printf '%stables-probe-307-%s-%s/' "$OUTPUT" "$1" "$RUN_STAMP"; }
cleanup_hint "Hive の表（mk_h・ch_*）の LOCATION は DROP で消えない: $(loc '*')"

# Hive: DDL で書ける未測の型を 1 表に
item mk_h creates=TABLE:"$T_H" "CREATE EXTERNAL TABLE $DB.$T_H (c_char char(10), c_varchar varchar(10), c_dec decimal(10,2), c_bin binary, c_arr_st array<struct<a:int,b:string>>, c_st2 struct<a:int,b:string>, c_map_arr map<string,array<int>>) LOCATION '$(loc h)'"
item d_h needs=mk_h "DESCRIBE $DB.$T_H"

# Iceberg: DDL で書ける未測の型を 1 表に（#146 の対照 3 と同じ LOCATION … TBLPROPERTIES の形）
item mk_i creates=TABLE:"$T_I" "CREATE TABLE $DB.$T_I (c_dec decimal(10,2), c_bin binary, c_st2 struct<a:int,b:string>, c_arr_st array<struct<a:int,b:string>>) LOCATION '$(loc i)' TBLPROPERTIES ('table_type'='ICEBERG')"
item d_i needs=mk_i "DESCRIBE $DB.$T_I"

# DDL で書けない型: 型ごとに Hive・Iceberg の CTAS で作れるかを試し、作れたら DESCRIBE
for spec in "time:TIME '01:02:03'" "tstz:TIMESTAMP '2026-01-01 00:00:00 UTC'" "interval:INTERVAL '1' DAY" "json:JSON '{\"a\":1}'" "uuid:UUID '12151fd2-7586-11e9-8f9e-2a86e4085a59'"; do
  name=${spec%%:*}; value=${spec#*:}
  t_h="${PREFIX}_ctas_h_$name"; t_i="${PREFIX}_ctas_i_$name"
  item "ch_$name" creates=TABLE:"$t_h" "CREATE TABLE $DB.$t_h WITH (external_location = '$(loc "ch-$name")') AS SELECT $value AS c"
  item "dch_$name" needs="ch_$name" "DESCRIBE $DB.$t_h"
  item "ci_$name" creates=TABLE:"$t_i" "CREATE TABLE $DB.$t_i WITH (table_type = 'ICEBERG', is_external = false, location = '$(loc "ci-$name")') AS SELECT $value AS c"
  item "dci_$name" needs="ci_$name" "DESCRIBE $DB.$t_i"
done

item x_void skip="Athena の文書の変換の表（querying-iceberg-creating-tables）に void などは無く、表の 7 種は #173 で測った" -

# SHOW SCHEMAS / SHOW DATABASES の LIKE（Context は Catalog だけ。対照 s_all は #173 の d3 で成功した形）
P3=${DB:0:3}; UND=$(printf '%*s' $(( ${#DB} - 3 )) '' | tr ' ' _)
# DB から作った値も summary.txt で伏せる（hide は大文字小文字を区別し、部分の一致は拾わない）。先頭 3 文字は
# 型の綴り（str → string・struct）まで伏せないよう、LIKE の引用符の直後に限る
add_hide_pair "${DB^^}" "<DB_UPPER>"; add_hide_pair "${DB:1}" "<DB_TAIL>"; add_hide_pair "'$P3" "'<DB_HEAD3>"
item s_all        ctx=catalog "SHOW SCHEMAS"
item s_exact      ctx=catalog "SHOW SCHEMAS LIKE '$DB'"
item s_upper      ctx=catalog "SHOW SCHEMAS LIKE '${DB^^}'"
item s_star       ctx=catalog "SHOW SCHEMAS LIKE '${P3}*'"
item s_pct        ctx=catalog "SHOW SCHEMAS LIKE '${P3}%'"
item s_under      ctx=catalog "SHOW SCHEMAS LIKE '${P3}${UND}'"
item s_star_only  ctx=catalog "SHOW SCHEMAS LIKE '*'"
item s_star_mid   ctx=catalog "SHOW SCHEMAS LIKE '*${DB:1}'"
item db_exact     ctx=catalog "SHOW DATABASES LIKE '$DB'"
item db_star      ctx=catalog "SHOW DATABASES LIKE '${P3}*'"

run_items
