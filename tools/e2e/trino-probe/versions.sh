#!/usr/bin/env bash
# issue #111 で作成
# issue #111 の実測 (10): Trino 482 より古い版で、athena-local が形式判定に使う
# system.metadata.catalogs の connector_name、probe_sql（src/operation/table_format.rs）の結果、
# DROP TABLE / ALTER TABLE ... ADD COLUMN の updateType がどう返るかを版ごとに集める。
# 版ごとにルートの compose.yml の trino を TRINO_TAG と CATALOG_DIR で作り直し（down -v trino → up -d trino）、
# catalog → catalog-legacy → catalog-nofsflag の順に
# 「SHOW SCHEMAS FROM hive / iceberg が error 無しで返る」構成を探して採用し、probe.sh を流す。
# 本物の AWS は使わない。
#
# 使い方: tools/dev.sh tools/e2e/trino-probe/versions.sh
# 環境変数:
#   TRINO_TAGS="480 475 470 440 400"  測る版（482 は対照。trino.md の #39 の表と完全一致で PASS）
#   START_TIMEOUT=120                 /v1/info の starting:false を待つ秒数（1 試行あたり）
#   PULL_TIMEOUT=600                  手元に無いイメージの pull を待つ秒数
#   KEEP_UP=1                         最後の版の trino を残す（デバッグ用）
# 同じ compose プロジェクトで別の足場（dev）が動いていたら止まる（down -v trino が相手の Trino を消すため）。
# 状態: 482 は期待と完全一致で PASS。旧版は値をそのまま記録して INFO（482 との差は列に出す）。
# FAIL は nodeVersion がタグと違うときと 482 の不一致だけ。採用できる catalog が無い・
# イメージが取れない版は SKIP。終了コードは FAIL の件数。
# 証跡は /tmp/athena-local-issue111-trino.XXXXXX に残す（版ごとの生の JSON・起動ログ・summary.md）。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/compose.yml"
TRINO_TAGS="${TRINO_TAGS:-480 475 470 440 400}"
BASE="http://trino:8080"
START_TIMEOUT="${START_TIMEOUT:-120}"
PULL_TIMEOUT="${PULL_TIMEOUT:-600}"
CATALOG_DIRS="catalog catalog-legacy catalog-nofsflag"
CONTROL_TAG="482"
# 482 の期待値。A2・D1・D4・C1・C2 は docs/dev/measurements/trino.md の「Trino のバージョン差」（#39）の表。
# D2・D3 は同じ probe_sql で対照テーブル t1 の有無だけを入れ替えたもの（表には無い行）。
EXPECTED=(hive iceberg '[["hive",1]]' '[["iceberg",1]]' '[["hive",0]]' '[["iceberg",0]]' 'DROP TABLE' 'ADD COLUMN')
COLUMNS_HDR=("A2 hive" "A2 iceberg" D1 D2 D3 D4 C1 C2)

command -v jq >/dev/null || { echo "jq が要る"; exit 1; }
# 同じプロジェクトに自分以外の dev（別の足場）がいたら止まる（hostname は自分のコンテナ ID の先頭 12 桁）。
PROJECT=$(docker compose -f "$COMPOSE_FILE" config --format json 2>/dev/null | jq -r '.name // empty')
[ -n "$PROJECT" ] || { echo "compose のプロジェクト名を取れない（docker compose config が失敗した）。止めて報告する"; exit 1; }
others=$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter label=com.docker.compose.service=dev | grep -v "^$(hostname)" | wc -l)
if [ "$others" != "0" ]; then
  echo "同じプロジェクト（$PROJECT）で別の足場が動いている。COMPOSE_PROJECT_NAME で分けるか、終わるのを待つ"; exit 1
fi

EVIDENCE_DIR="$(mktemp -d /tmp/athena-local-issue111-trino.XXXXXX)"
SUMMARY="$EVIDENCE_DIR/summary.md"
FAILS=0

compose() { docker compose -f "$COMPOSE_FILE" "$@"; }
down() { compose down -v trino >/dev/null 2>&1; }
# 止まったコンテナのログも読むので -a を付ける。
trino_id() { compose ps -aq trino; }
cleanup() {
  [ "${KEEP_UP:-0}" = "1" ] || down
  echo "evidence: $EVIDENCE_DIR"
}
trap cleanup EXIT

# 表のセル用に 1 行・80 文字に丸め、| を逃がす
cell() { jq -Rrs 'split("\n") | join(" ") | rtrimstr(" ") | .[0:80] | split("|") | join("\\|")'; }

# $1 ディレクトリ, $2 ラベル: <ラベル>.<ページ>.json をページ順に並べる
pages() {
  local i=0
  while [ -f "$1/$2.$i.json" ]; do echo "$1/$2.$i.json"; i=$((i + 1)); done
}

# $1 ディレクトリ, $2 ラベル: 全ページのうち最初の error.message（無ければ空）
page_error() {
  local files; files=$(pages "$1" "$2")
  [ -n "$files" ] || { echo "応答なし"; return; }
  # jq にはファイルを引数でなく標準入力で渡す
  # shellcheck disable=SC2086
  cat $files | jq -rs '[.[] | .error.message // empty][0] // empty' 2>/dev/null || echo "JSON でない応答"
}

# $1 SQL, $2 ディレクトリ, $3 ラベル: /v1/statement に投げて nextUri を辿り、error.message を出す
run_query() {
  local resp next i=0
  resp=$(curl -s -X POST "$BASE/v1/statement" -H "X-Trino-User: probe" --data-binary "$1")
  while [ -n "$resp" ]; do
    echo "$resp" > "$2/$3.$i.json"
    next=$(echo "$resp" | jq -r '.nextUri // empty' 2>/dev/null)
    [ -n "$next" ] || break
    resp=$(curl -s "$next"); i=$((i + 1))
  done
  page_error "$2" "$3"
}

# /v1/info の starting:false を待つ。コンテナが止まったら諦める
wait_ready() {
  local waited=0
  while [ "$waited" -lt "$START_TIMEOUT" ]; do
    [ "$(docker inspect -f '{{.State.Running}}' "$(trino_id)" 2>/dev/null)" = "true" ] || return 1
    [ "$(curl -s "$BASE/v1/info" | jq -r '.starting' 2>/dev/null)" = "false" ] && return 0
    sleep 2; waited=$((waited + 2))
  done
  return 1
}

# $1 試行の証跡: 起動しなかった理由を 1 行（設定エラー → 例外 → ERROR の順に探す）
startup_reason() {
  local logs pat line; logs=$(cat "$1/startup.log" "$1/compose-up.log" 2>/dev/null)
  for pat in '^[0-9]+\) Error: ' 'Exception in thread' 'ERROR|error'; do
    line=$(echo "$logs" | grep -m1 -E "$pat") && break
  done
  echo "${line:-ログに手がかり無し}" | tr '\t' ' ' | cell
}

# $1 タグ, $2 証跡: catalog を順に試し、採用した名前を ADOPTED、試行の記録を NOTES に入れる。
# 戻り値 0=採用、1=どれも通らない、2=nodeVersion がタグと違う
try_catalogs() {
  local tag="$1" ev="$2" dir att err_h err_i version
  ADOPTED=""; NOTES=""; NODE_VERSION="-"
  for dir in $CATALOG_DIRS; do
    att="$ev/attempt-$dir"; mkdir -p "$att"; down
    TRINO_TAG="$tag" CATALOG_DIR="$SCRIPT_DIR/$dir" \
      compose up -d --pull never trino >"$att/compose-up.log" 2>&1
    if ! wait_ready; then
      docker logs --tail 60 "$(trino_id)" >"$att/startup.log" 2>&1
      NOTES+="$dir: 起動せず（$(startup_reason "$att")）; "
      continue
    fi
    curl -s "$BASE/v1/info" >"$att/info.json"
    version=$(jq -r '.nodeVersion.version' <"$att/info.json"); NODE_VERSION="$version"
    [ "$version" = "$tag" ] || { NOTES+="nodeVersion=$version がタグ $tag と違う; "; return 2; }
    err_h=$(run_query "SHOW SCHEMAS FROM hive" "$att" show_schemas_hive)
    err_i=$(run_query "SHOW SCHEMAS FROM iceberg" "$att" show_schemas_iceberg)
    if [ -z "$err_h$err_i" ]; then ADOPTED="$dir"; return 0; fi
    docker logs --tail 60 "$(trino_id)" >"$att/startup.log" 2>&1
    NOTES+="$dir: hive=$(echo "${err_h:-ok}" | cell) iceberg=$(echo "${err_i:-ok}" | cell); "
  done
  return 1
}

# $1 probe の出力ディレクトリ, $2 カタログ名: A2 の connector_name
a2_value() {
  local err files; err=$(page_error "$1" a2_system_metadata_catalogs)
  [ -z "$err" ] || { echo "error: $err" | cell; return; }
  files=$(pages "$1" a2_system_metadata_catalogs)
  # shellcheck disable=SC2086
  cat $files | jq -rs --arg c "$2" '([.[].columns // empty][0] // [] | map(.name)) as $n
    | ($n | index("catalog_name")) as $ci | ($n | index("connector_name")) as $ki
    | if $ki == null then "connector_name 列無し" else
        ([.[].data // empty] | add // [] | map(select(.[$ci] == $c)))
        | if length == 0 then "行無し" else (.[0][$ki] | tostring) end end' | cell
}

# $1 ディレクトリ, $2 ラベル: data 全体（error なら先頭 80 文字）
data_value() {
  local err files; err=$(page_error "$1" "$2")
  [ -z "$err" ] || { echo "error: $err" | cell; return; }
  files=$(pages "$1" "$2")
  # shellcheck disable=SC2086
  cat $files | jq -cs '[.[].data // empty] | add // []' | cell
}

# $1 ディレクトリ, $2 ラベル: 最初の updateType（error なら error: と先頭の文言）
one_update_type() {
  local err; err=$(page_error "$1" "$2")
  if [ -n "$err" ]; then echo "error: $err"; return; fi
  # shellcheck disable=SC2046
  cat $(pages "$1" "$2") | jq -rs '[.[].updateType // empty][0] // "-"'
}

# $1 ディレクトリ, $2 C 節の接頭辞: hive と iceberg の updateType（同じなら 1 つ）
update_type() {
  local h i; h=$(one_update_type "$1" "$2_hive"); i=$(one_update_type "$1" "$2_iceberg")
  if [ "$h" = "$i" ]; then echo "$h" | cell; else echo "hive=$h iceberg=$i" | cell; fi
}

# $1 probe の出力: probe.sh の準備（スキーマ・対照テーブル）で error になったものを並べる。
# 準備が失敗した版の D1・D2・C1・C2 は Trino の違いではなく準備の失敗で値が変わるため、詳細に出す
setup_errors() {
  local f label err out=""
  for f in "$1"/setup_*.0.json; do
    [ -f "$f" ] || continue
    label=$(basename "$f" .0.json); err=$(page_error "$1" "$label")
    [ -z "$err" ] || out+="$label=$(echo "$err" | cell); "
  done
  [ -z "$out" ] || echo "準備の失敗: $out"
}

# 表の 1 行を書く（引数がそのままセル）
row() { local c line="|"; for c in "$@"; do line+=" $c |"; done; echo "$line" >>"$SUMMARY"; }

# $1 タグ: 1 版を測って summary に 1 行足す
measure_tag() {
  local tag="$1" ev="$EVIDENCE_DIR/$1" rc status same="-" detail="" out k
  local -a vals=()
  mkdir -p "$ev"
  if ! docker image inspect "trinodb/trino:$tag" >/dev/null 2>&1 \
     && ! timeout "$PULL_TIMEOUT" docker pull "trinodb/trino:$tag" >"$ev/pull.log" 2>&1; then
    status=SKIP; detail="未測定: イメージ trinodb/trino:$tag を取得できない（$(tail -1 "$ev/pull.log" | cell)）"
    row "$tag" "$status" - - - - - - - - - - - "$detail"; echo "$status $tag: $detail"; return
  fi
  try_catalogs "$tag" "$ev"; rc=$?
  if [ "$rc" -eq 0 ]; then
    out="$ev/probe"
    OUT_DIR="$out" BASE="$BASE" bash "$SCRIPT_DIR/probe.sh" >"$ev/probe.log" 2>&1
    vals=("$(a2_value "$out" hive)" "$(a2_value "$out" iceberg)")
    for k in d1_probe_hive_exists d2_probe_iceberg_exists d3_probe_hive_missing d4_probe_iceberg_missing; do
      vals+=("$(data_value "$out" "$k")")
    done
    vals+=("$(update_type "$out" c1_drop_table)" "$(update_type "$out" c2_alter_add_column)")
    same="同じ"
    for k in "${!EXPECTED[@]}"; do
      [ "${vals[$k]}" = "${EXPECTED[$k]}" ] || { same="差あり"; detail+="${COLUMNS_HDR[$k]}; "; }
    done
    if [ "$tag" = "$CONTROL_TAG" ]; then
      [ "$same" = "同じ" ] && status=PASS || { status=FAIL; detail="期待と違う列: $detail"; }
    else
      status=INFO; [ "$same" = "同じ" ] || detail="482 と違う列: $detail"
    fi
    detail+="$(setup_errors "$out")${NOTES}"
  elif [ "$rc" -eq 2 ]; then
    status=FAIL; detail="$NOTES"
  else
    status=SKIP; detail="未測定: 3 つの catalog とも SHOW SCHEMAS が通らない（$NOTES）"
  fi
  [ "${#vals[@]}" -gt 0 ] || vals=(- - - - - - - -)
  [ "$status" = FAIL ] && FAILS=$((FAILS + 1))
  row "$tag" "$status" "${ADOPTED:--}" "$NODE_VERSION" "${vals[@]}" "$same" "$detail"
  echo "$status $tag: catalog=${ADOPTED:--} nodeVersion=$NODE_VERSION $same $detail"
}

: >"$SUMMARY"
row 版 状態 "採用 catalog" nodeVersion "${COLUMNS_HDR[@]}" "482 と同じか" 詳細
row --- --- --- --- --- --- --- --- --- --- --- --- --- ---
set -- $TRINO_TAGS
while [ $# -gt 0 ]; do
  echo "== Trino $1"
  measure_tag "$1"
  if [ $# -gt 1 ] || [ "${KEEP_UP:-0}" != "1" ]; then down; fi
  shift
done
echo; cat "$SUMMARY"; echo; echo "FAIL: $FAILS"
exit "$FAILS"
