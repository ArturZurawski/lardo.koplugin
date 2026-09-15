#!/bin/sh
# Runs the offline test suite. Needs lua5.1, luajit or lua on PATH.
set -e
here=$(cd "$(dirname "$0")" && pwd)
LUA=${LUA:-$(command -v luajit || command -v lua5.1 || command -v lua)}
if [ -z "$LUA" ]; then
    echo "No Lua interpreter found. Set LUA=/path/to/luajit" >&2
    exit 1
fi
MEALIE_TEST_DIR=$(mktemp -d)
export MEALIE_TEST_DIR
mkdir -p "$MEALIE_TEST_DIR/koreader/settings"
trap 'rm -rf "$MEALIE_TEST_DIR"' EXIT

status=0
for t in "$here/test_units.lua" "$here/test_plugin.lua"; do
    echo "== $(basename "$t")"
    "$LUA" "$t" || status=1
done
exit $status
