#!/usr/bin/env bash
# 実名（データベース名・出力先・バケット名・呼び出し元の IAM identity など）を
# summary から隠す。describe-extended.sh:273-322（#275）から移植。
#
# 長い実名から先に置換する。短い方を先に潰すと、長い実名がその短い実名を
# 部分文字列として含む場合に一部が残ってしまう（#221・#224 の教訓）。

# 隠す対象の一覧。add_hide_pair で足す（値が空なら無視する）。
_HIDE_VALUES=()
_HIDE_MARKS=()

# ラウンドや preflight が実名を1件足す（例: add_hide_pair "$CALLER_ARN" "<CALLER_ARN>"）。
# 値が空文字なら何もしない（空文字を全置換すると印だらけになるため）。
add_hide_pair() {
  local value=$1 mark=$2
  [ -n "$value" ] || return 0
  _HIDE_VALUES+=("$value")
  _HIDE_MARKS+=("$mark")
}

# 登録済みの対を「長さ\t値\t印」の形で出す（hide がソートに使う。値が空の対は出さない）。
hide_pairs() {
  local i value
  for i in "${!_HIDE_VALUES[@]}"; do
    value=${_HIDE_VALUES[$i]}
    [ -n "$value" ] && printf '%s\t%s\t%s\n' "${#value}" "$value" "${_HIDE_MARKS[$i]}"
  done
}

# 登録済みの実名をすべて置換する（長い実名から先に。sort -k1,1nr）。
# 12 桁の数字はアカウント ID とみなして、登録の有無によらず追加でマスクする。
hide() {
  local s=$1 value mark
  while IFS=$'\t' read -r _ value mark; do
    s=${s//"$value"/$mark}
  done < <(hide_pairs | sort -t $'\t' -k1,1nr)
  printf '%s' "$s" | sed -E 's/(^|[^0-9])[0-9]{12}([^0-9]|$)/\1<ACCOUNT_ID>\2/g'
}

# 制御文字を落として短くする（改行も潰す）。summary.tsv の note に入れる前に必ず通す。
sanitize() {
  printf '%s' "$1" | tr '\t\n\r' '   ' | cut -c1-300
}

# 制御文字（改行は残す）を落とし、実名を伏せたうえで長すぎれば頭だけにする。
# summary.txt の本体・StateChangeReason の全文表示に使う（フェーズ 2 の summary.sh から呼ぶ）。
hide_multiline() {
  local f=$1 data
  [ -s "$f" ] || { echo "(空)"; return; }
  data=$(tr -d '\000-\010\013\014\016-\037' < "$f")
  data=$(hide "$data")
  if [ "${#data}" -gt 4000 ]; then
    printf '%s\n[...4000 文字を超えたので省略。全文は %s]\n' "${data:0:4000}" "$(basename "$f")"
  else
    printf '%s\n' "$data"
  fi
}

# stderr ファイルの1行目を、実名を隠して短く返す。ファイルが無ければ定型文を返す。
first_err_line() {
  local f=$1 line
  if [ -s "$f" ]; then
    line=$(grep -m1 . "$f")
    sanitize "$(hide "$line")"
  else
    echo "(エラー出力なし)"
  fi
}
