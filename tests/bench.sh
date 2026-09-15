#!/bin/sh
# Rough timings for the list, a recipe and the start-up parse. See bench.lua.
set -e
here=$(cd "$(dirname "$0")" && pwd)
LUA=${LUA:-$(command -v luajit || command -v lua5.1 || command -v lua)}
if [ -z "$LUA" ]; then
    echo "No Lua interpreter found. Set LUA=/path/to/luajit" >&2
    exit 1
fi
MEALIE_BENCH_DIR=$(mktemp -d)
export MEALIE_BENCH_DIR
trap 'rm -rf "$MEALIE_BENCH_DIR"' EXIT
exec "$LUA" "$here/bench.lua" "$@"
