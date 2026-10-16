#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if ! command -v node >/dev/null 2>&1; then
  printf '%s\n' 'hikari: install Node >= 22 before running this installer.' >&2
  exit 1
fi
exec node "$ROOT/scripts/install/main.mjs" "$@"
