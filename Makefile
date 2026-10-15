LUA ?= lua
PICODECK_ROOT ?= $(HOME)/Projects/PicoDeck/picodeck
export PICODECK_ROOT

.PHONY: test test-host test-lua32 e2e clean

# Host tests under the system Lua and under lua32 (the device's numbers).
test: test-host test-lua32

test-host:
	$(LUA) tests/run.lua

build/lua32: tools/build_lua32.sh
	tools/build_lua32.sh

test-lua32: build/lua32
	build/lua32 tests/run.lua

# Simulator smoke tests (needs PicoDeck's simulator: make simulator in picodeck).
e2e:
	SDL_VIDEODRIVER=dummy python3 -m pytest tests/e2e -v

clean:
	rm -rf build
