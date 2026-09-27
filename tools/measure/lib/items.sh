#!/usr/bin/env bash
# 項目の宣言（item・api）と実行順の制御（run_items）。#310 フェーズ2。
# unmeasured-batch/run.sh:83-90（want_item・ONLY）の考え方を、TSV でなく宣言の関数呼び出し
# （issue ノートの P-2）で持たせたもの。item/api は配列に積むだけで副作用が無い。
# 宣言と実行を分けているので、ラウンドのスクリプトは宣言をすべて書いたあとに1回 run_items
# を呼べばよい。

_ITEM_IDS=()
_ITEM_KINDS=()    # query | api
_ITEM_CTX=()      # query のみ。ctx（既定 db）
_ITEM_NEEDS=()    # カンマ区切りの id（無ければ空）
_ITEM_CREATES=()  # "TABLE:name" / "VIEW:name"（無ければ空）
_ITEM_SKIP=()     # skip= の理由（無ければ空）
_ITEM_ARG1=()     # query: SQL / api: Operation
_ITEM_ARG2=()     # query: 未使用（空） / api: JSON

# item の key=value で許す key。ここに無いものは綴りの誤りとみなし、宣言の時点で止める
# （黙って別の Context・needs で投げるのを防ぐ）。
_lib_items_known_key() {
  case "$1" in
    ctx | needs | creates | skip) return 0 ;;
    *) return 1 ;;
  esac
}

# item <id> [key=value...] <sql>
# 最後の引数が SQL（bash の引数のまま渡るので '・"・改行・タブのエスケープの境界が無い）。
item() {
  local id=$1
  shift
  local -a rest=("$@")
  local n=${#rest[@]}
  if [ "$n" -lt 1 ]; then
    echo "item $id: SQL がありません" >&2
    exit 2
  fi
  local sql="${rest[$((n - 1))]}"
  local -a kvs=()
  if [ "$n" -gt 1 ]; then
    kvs=("${rest[@]:0:$((n - 1))}")
  fi

  local ctx=db needs="" creates="" skip=""
  local kv key value
  for kv in "${kvs[@]}"; do
    key=${kv%%=*}
    value=${kv#*=}
    if ! _lib_items_known_key "$key"; then
      echo "item $id: 知らない key です（$key）。ctx=/needs=/creates=/skip= のどれかにしてください" >&2
      exit 2
    fi
    case "$key" in
      ctx) ctx=$value ;;
      needs) needs=$value ;;
      creates) creates=$value ;;
      skip) skip=$value ;;
    esac
  done

  _ITEM_IDS+=("$id")
  _ITEM_KINDS+=("query")
  _ITEM_CTX+=("$ctx")
  _ITEM_NEEDS+=("$needs")
  _ITEM_CREATES+=("$creates")
  _ITEM_SKIP+=("$skip")
  _ITEM_ARG1+=("$sql")
  _ITEM_ARG2+=("")
}

# api <id> <Operation> <json>（key=value は取らない。athena_call をそのまま宣言に開く）。
api() {
  local id=$1 operation=$2 json=$3
  _ITEM_IDS+=("$id")
  _ITEM_KINDS+=("api")
  _ITEM_CTX+=("")
  _ITEM_NEEDS+=("")
  _ITEM_CREATES+=("")
  _ITEM_SKIP+=("")
  _ITEM_ARG1+=("$operation")
  _ITEM_ARG2+=("$json")
}

# ONLY=id,id に id が含まれるか（空なら全部含む）。unmeasured-batch/run.sh の want_item と同じ形。
_lib_items_wanted() {
  local id=$1
  [ -z "${ONLY:-}" ] && return 0
  case ",$ONLY," in
    *",$id,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# needs=<id>[,<id>] の各先が、この実行で SUCCEEDED になっているかを確かめる。
# だめなら理由（"needs <id> が <state>"）を1つ返す（最初に見つかったもの）。
_lib_items_needs_reason() {
  local needs=$1 id state
  local IFS=,
  for id in $needs; do
    state=${_ITEM_RUN_STATE[$id]:-未実行}
    if [ "$state" != SUCCEEDED ]; then
      printf 'needs %s が %s' "$id" "$state"
      return 1
    fi
  done
  return 0
}

# run_items: 宣言順（ONLY で絞った後はその順）に実行する。needs の先が SUCCEEDED でなければ
# 投げずに skip、skip= の項目は投げない、1項目の失敗で全体を止めない。creates の表は
# 「その表を needs に持つ最後の項目」の直後に best_effort_drop（無ければ作った直後）。
# 最後に finish_cleanup で DROP の終端を待ち、write_summary_txt で summary.txt を書く。
run_items() {
  local total=${#_ITEM_IDS[@]}
  local -a order=()
  local i
  for ((i = 0; i < total; i++)); do
    _lib_items_wanted "${_ITEM_IDS[$i]}" && order+=("$i")
  done

  # creates を持つ項目ごとに「drop すべき位置」を前計算する（order の中の最後の利用者の
  # 直後。利用者が無ければ自分自身の直後）。
  declare -A _ITEM_RUN_STATE=()
  declare -A _LIB_DROP_AT_KIND
  declare -A _LIB_DROP_AT_NAME
  local pos idx creates_spec kind name last_pos consumer_idx needs_ids nid

  for pos in "${!order[@]}"; do
    idx=${order[$pos]}
    creates_spec=${_ITEM_CREATES[$idx]}
    [ -n "$creates_spec" ] || continue
    kind=${creates_spec%%:*}
    name=${creates_spec#*:}

    last_pos=$pos
    for consumer_idx in "${!order[@]}"; do
      needs_ids=${_ITEM_NEEDS[${order[$consumer_idx]}]}
      [ -n "$needs_ids" ] || continue
      # IFS は read にだけ当てる（run_items の中で IFS を変えると、ここから呼ぶ run_query などの
      # 分割まで変わる）
      local -a need_list=()
      IFS=, read -r -a need_list <<< "$needs_ids"
      for nid in "${need_list[@]}"; do
        [ "$nid" = "${_ITEM_IDS[$idx]}" ] || continue
        [ "$consumer_idx" -gt "$last_pos" ] && last_pos=$consumer_idx
      done
    done
    _LIB_DROP_AT_KIND[$last_pos]="${_LIB_DROP_AT_KIND[$last_pos]:-}${_LIB_DROP_AT_KIND[$last_pos]:+,}$kind"
    _LIB_DROP_AT_NAME[$last_pos]="${_LIB_DROP_AT_NAME[$last_pos]:-}${_LIB_DROP_AT_NAME[$last_pos]:+,}$name"
  done

  local reason id kd
  for pos in "${!order[@]}"; do
    idx=${order[$pos]}
    id=${_ITEM_IDS[$idx]}
    kd=${_ITEM_KINDS[$idx]}

    if [ -n "${_ITEM_SKIP[$idx]}" ]; then
      skip "$id" "${_ITEM_SKIP[$idx]}"
      _ITEM_RUN_STATE[$id]=SKIPPED
    elif [ -n "${_ITEM_NEEDS[$idx]}" ] && ! reason=$(_lib_items_needs_reason "${_ITEM_NEEDS[$idx]}"); then
      skip "$id" "$reason"
      _ITEM_RUN_STATE[$id]=SKIPPED
    elif [ "$kd" = api ]; then
      if athena_call "$id" "${_ITEM_ARG1[$idx]}" "${_ITEM_ARG2[$idx]}"; then
        _ITEM_RUN_STATE[$id]=SUCCEEDED
      else
        _ITEM_RUN_STATE[$id]=FAILED
      fi
    else
      # 作る項目は投げる前に台帳へ載せる（終端を待つ間に中断されても、trap の保険が DROP IF EXISTS を
      # 投げる。移植元の describe-extended.sh は作成に着手した時点で保険を有効にしていた）。
      # SUCCEEDED にならなければ台帳から外し、DROP を投げない
      creates_spec=${_ITEM_CREATES[$idx]}
      [ -n "$creates_spec" ] && record_created "${creates_spec%%:*}" "${creates_spec#*:}"
      if run_query "$id" "${_ITEM_CTX[$idx]}" "${_ITEM_ARG1[$idx]}"; then
        _ITEM_RUN_STATE[$id]=SUCCEEDED
      else
        _ITEM_RUN_STATE[$id]=$(awk -F'\t' -v id="$id" '$1==id{s=$3} END{print s}' "$SUMMARY")
        [ -n "$creates_spec" ] && forget_created "${creates_spec%%:*}" "${creates_spec#*:}"
      fi
    fi

    if [ -n "${_LIB_DROP_AT_KIND[$pos]:-}" ]; then
      local -a drop_kinds drop_names
      IFS=, read -r -a drop_kinds <<< "${_LIB_DROP_AT_KIND[$pos]}"
      IFS=, read -r -a drop_names <<< "${_LIB_DROP_AT_NAME[$pos]}"
      local di
      for di in "${!drop_kinds[@]}"; do
        if grep -qxF "$(printf '%s\t%s' "${drop_kinds[$di]}" "${drop_names[$di]}")" "$RUN_DIR/created.tsv" 2>/dev/null; then
          best_effort_drop "${drop_kinds[$di]}" "${drop_names[$di]}"
        fi
      done
    fi
  done

  finish_cleanup
  write_summary_txt
}
