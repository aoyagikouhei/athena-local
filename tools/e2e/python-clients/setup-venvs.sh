#!/usr/bin/env bash
# issue #111: python-clients の検証に使う venv を 2 つ作る（リポジトリの外に置く）。
#   venv-wr  : awswrangler + PyAthena（pandas）
#   venv-dbt : dbt-core + dbt-athena
# dbt-athena 1.11.1 は pyathena<3.35 を要求し、PyAthena 3.36.0 と同じ venv に入らないので分ける。
# 既に入っていれば pip は何もしない（何度流してもよい）。
#
# 使い方: tools/e2e/python-clients/setup-venvs.sh
# 環境変数: VENV_ROOT（既定 $HOME/.cache/athena-local-111）、PYTHON（既定 python3）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_ROOT="${VENV_ROOT:-$HOME/.cache/athena-local-111}"
PYTHON="${PYTHON:-python3}"

make_venv() {
  local name="$1" requirements="$2"
  local dir="$VENV_ROOT/$name"
  if [ ! -x "$dir/bin/python" ]; then
    echo "[setup] $dir を作る"
    "$PYTHON" -m venv "$dir"
  fi
  "$dir/bin/pip" install --quiet --disable-pip-version-check -r "$requirements"
  echo "[setup] $name の主な版:"
  "$dir/bin/pip" freeze | grep -iE '^(awswrangler|pyathena|pandas|boto3|botocore|dbt-core|dbt-athena|dbt-adapters)==' | sed 's/^/  /'
}

mkdir -p "$VENV_ROOT"
make_venv venv-wr "$SCRIPT_DIR/requirements-wr.txt"
make_venv venv-dbt "$SCRIPT_DIR/requirements-dbt.txt"
