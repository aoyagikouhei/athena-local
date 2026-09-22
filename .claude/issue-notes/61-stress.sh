#!/bin/bash
# issue #61 の実機検証: CPU を飽和させた状態で tests/retention.rs を繰り返し走らせ、落ちる回数を数える。
# 使い方: bash .claude/issue-notes/61-stress.sh [ラウンド数(既定 6)] [同時実行数(既定 4)] [yes の本数(既定 CPU 数×8)]
# 出力: 各ラウンドの結果と "fails=<落ちた回数> / <総回数>"。ログは $LOG_DIR（既定 /tmp/athena-local-61）に残る。
set -u
cd "$(dirname "$0")/../.."
ROUNDS=${1:-6}
PARALLEL=${2:-4}
HOGS=${3:-$(( $(nproc) * 8 ))}
LOG_DIR=${LOG_DIR:-/tmp/athena-local-61}
mkdir -p "$LOG_DIR"

cargo test --locked --test retention --no-run 2>&1 | tail -1
bin=$(ls -t target/debug/deps/retention-* | grep -v '\.d$' | head -1)
echo "binary: $bin"

hogs=()
for _ in $(seq "$HOGS"); do timeout 600 yes > /dev/null & hogs+=($!); done
trap 'kill "${hogs[@]}" 2>/dev/null' EXIT
sleep 1

fails=0
total=0
for round in $(seq "$ROUNDS"); do
  pids=()
  for j in $(seq "$PARALLEL"); do
    ( "$bin" --test-threads 12 > "$LOG_DIR/round-$round-$j.log" 2>&1 ) &
    pids+=($!)
  done
  for p in "${pids[@]}"; do
    total=$((total + 1))
    wait "$p" || fails=$((fails + 1))
  done
  echo "round $round: fails so far $fails / $total"
done
grep -h 'panicked at' "$LOG_DIR"/round-*.log | sort | uniq -c
echo "fails=$fails / $total"
[ "$fails" -eq 0 ]
