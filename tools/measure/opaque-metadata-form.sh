#!/usr/bin/env bash
# issue #24 で作成（tools/ へ移す前の名前は 24-verify-metadata-form.sh）
# README に書く数値を、保存済みの実測バイト列から再導出して検証する。
# ホストで `bash tools/measure/opaque-metadata-form.sh`（xxd を使う。toolbox には無い）。#129
set -u
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1: $2"; else echo "NG   $1: 期待 $3 / 実際 $2"; fail=1; fi; }

R1=~/athena-txt-measurements/run-20260916-090202
R2=~/athena-txt-measurements/run-20260916-094100
R3=~/athena-metadata-measurements/run-20260917-175312
R4=~/athena-comment-measurements/run-20260918-090622

# 1. 不透明系の 5 文（4 ラウンド分）は 312 文字 → 233 バイト、SHOW TBLPROPERTIES だけ 460 → 345
for f in $R1/show-{tables,databases,columns,partitions}.metadata.bytes \
         $R2/show-{tables,databases,columns,partitions}.metadata.bytes \
         $R3/{probe-show-tables,show-tables}.metadata.bytes \
         $R4/{probe-show-tables,a-line-show,b-block-show,c-keyword-in-line,c-keyword-in-block}.metadata.bytes; do
  check "312文字 $(basename $f)" "$(stat -c%s $f)" 312
  check "233バイト $(basename $f)" "$(base64 -d $f | wc -c)" 233
done
for f in $R1/show-tblproperties.metadata.bytes $R2/show-tblproperties.metadata.bytes; do
  check "460文字 $(basename $f)" "$(stat -c%s $f)" 460
  check "345バイト $(basename $f)" "$(base64 -d $f | wc -c)" 345
done

# 2. 先頭バイトは全件 0x01
firsts=$(for f in $R1/show-{tables,databases,columns,partitions,tblproperties}.metadata.bytes \
                  $R2/show-{tables,databases,columns,partitions,tblproperties}.metadata.bytes \
                  $R3/{probe-show-tables,show-tables}.metadata.bytes \
                  $R4/{probe-show-tables,a-line-show,b-block-show}.metadata.bytes; do
  base64 -d $f | xxd -l 1 -p; done | sort -u | tr '\n' ' ')
check "先頭バイトは 01 だけ" "$(echo $firsts)" "01"

# 3. 先頭バイト以降はラウンドをまたいでも、同じラウンドの中でも一定しない
p9=$(for f in $R1/show-tables.metadata.bytes $R3/show-tables.metadata.bytes $R4/probe-show-tables.metadata.bytes; do
  base64 -d $f | xxd -l 9 -p; done | sort -u | wc -l)
check "ラウンドをまたぐと先頭9バイトが割れる" "$p9" "3"
same_round=$(for f in $R3/probe-show-tables.metadata.bytes $R3/show-tables.metadata.bytes; do
  base64 -d $f | xxd -l 9 -p; done | sort -u | wc -l)
check "同じラウンドの中でも割れることがある" "$same_round" "2"

# 4. 同じ SHOW TABLES を 2 回実行するとバイト列が変わる（同じ表を返している）
a=$(base64 -d $R1/show-tables.metadata.bytes | md5sum | cut -d' ' -f1)
b=$(base64 -d $R2/show-tables.metadata.bytes | md5sum | cut -d' ' -f1)
check "2回の実行で内容が変わる" "$([ "$a" != "$b" ] && echo differ || echo same)" "differ"

# 5. SHOW CREATE TABLE と DESCRIBE は protobuf（先頭 0a = field 1 の length-delimited）
for f in $R1/show-create-table $R2/show-create-table $R1/describe $R3/describe $R4/a-line-show-create; do
  check "protobuf $(basename $f)" "$(xxd -l 1 -p $f.metadata.bytes)" "0a"
done

# 6. SHOW TABLES の結果本体そのものは平文（実テーブル名は書かない。形だけを確かめる）
body=$R4/probe-show-tables.bytes
check "本体は印字可能な ASCII と改行だけ" "$(LC_ALL=C tr -d '\n\t\40-\176' < $body | wc -c)" "0"
check "本体は複数行（1 行 1 テーブル）" "$([ "$(wc -l < $body)" -ge 2 ] && echo yes || echo no)" "yes"
check "本体の 1 行目は base64 の塊ではない（233 バイトに戻らない）" \
  "$([ "$(head -n 1 $body | base64 -d 2>/dev/null | wc -c)" = 233 ] && echo blob || echo text)" "text"

[ $fail -eq 0 ] && echo "=== 全項目 ok ===" || echo "=== 失敗あり ==="
exit $fail
