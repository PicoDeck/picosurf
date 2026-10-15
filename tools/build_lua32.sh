#!/usr/bin/env bash
# Builds build/lua32: host Lua with the device's number model (LUA_32BITS:
# 32-bit integers, single-precision floats), from PicoDeck's Lua sources.
# The host tests run under it as well as under the system `lua`, so float
# precision and integer wrap-around bugs show up before the device.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
picodeck="${PICODECK_ROOT:-$HOME/Projects/PicoDeck/picodeck}"
src="$picodeck/third_party/lua-5.4/src"
if [ ! -f "$src/lua.c" ]; then
    echo "build_lua32: no Lua sources at $src (set PICODECK_ROOT)" >&2
    exit 1
fi
work="$here/build/lua32-src"
rm -rf "$work"
mkdir -p "$work"
cp "$src"/*.c "$src"/*.h "$work"/
rm -f "$work/luac.c"
# Stock luaconf.h hard-codes LUA_32BITS to 0; set it in the copy.
sed -i 's/^#define LUA_32BITS\t0$/#define LUA_32BITS\t1/' "$work/luaconf.h"
cc -O2 -std=gnu99 -DLUA_32BITS=1 -DLUA_USE_LINUX -o "$here/build/lua32" "$work"/*.c -lm -ldl
"$here/build/lua32" -e 'assert(math.maxinteger == 2147483647, "lua32 is not a 32-bit build")'
echo "built $here/build/lua32"
