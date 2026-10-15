# PicoSurf App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the PicoSurf device app, a Lua app for PicoDeck. It reads web pages and feeds through the PicoSurf proxy, has bookmarks, history, feed subscriptions with unread tracking, and full-screen images.

**Architecture:**
- **Pure modules** (`url`, `gemtext`, `wrap`, `layout`, `pagestate`, `keys`, `proxy`, `store`, `feeds`) carry the logic. They are tested on the host under stock Lua and under `lua32`, which uses the device's 32-bit numbers.
- **Device modules** (`http`, `theme`, `app` and the screens) take the `picocalc` API as a parameter. Host tests drive the whole app against `tests/fakepc.lua`, a recording fake of that API, so navigation, screens and storage are tested without the simulator.
- **Simulator test.** A small end-to-end suite runs the real app in PicoDeck's simulator against a Python fake proxy. It confirms the fake matches the real API.

**Tech Stack:**
- Lua 5.4 on PicoDeck's restricted stdlib: `base`, `table`, `string`, `math`, `coroutine` and `utf8`, with no `io`, `os`, `package` or `debug`.
- `picocalc.*` APIs.
- Host tests use nova-rail's `tests/run.lua` runner and `tools/build_lua32.sh`.
- Simulator tests use pytest, PicoDeck's `tests/e2e/picodeck_simulator.py` and Pillow.
- GitHub Actions for CI and release.

**Spec:** `docs/superpowers/specs/2026-10-15-picosurf-design.md`, sections 3, 4, 6, 7.2 and 8. The proxy in `proxy/` is already built and merged. Its README documents the API this app consumes.

**Device API reference:** `.superpowers/research/device-api.md` in the main checkout (gitignored, code-verified). The facts this plan relies on are copied into Global Constraints. Implementers don't need the file, but it's there if a device behaviour is in doubt.

**Working directory:** the repo root (`picosurf/`). Lua tests run from there: `lua tests/run.lua`.

## Global Constraints

**App manifest and runtime**
- `app.json`: id `net.picodeck.picosurf`, name `PicoSurf`, category `network`, `min_firmware` `0.5.0`, requirements `["http"]`.
- Modules load with `require("src.<name>")`, which resolves to `APP_DIR/src/<name>.lua`. Screens load with `require("src.screens.<name>")`. Host tests set `package.path = "./?.lua;" .. package.path`.
- The device's Lua has 32-bit integers and single-precision floats. Keep epoch seconds and counts as integers: use `//`, never `/`. `math.tointeger(tonumber(s))` parses integers.
- There is no `os.time`. Use `sys.getClock()`, which returns `{synced, epoch}` with `epoch` 0 until synced, and `sys.getTimeMs()` for durations. Compare time differences (`now - t >= 0`), never absolute values.

**Proxy protocol**
- `GET <prefix>/v1/get?url=<percent-encoded>&as=reader|full|feed` and `GET <prefix>/v1/ping`, both with header `Authorization: Bearer <token>`.
- Response headers reach Lua lowercased: `content-type`, `x-final-url`, `x-title`, `x-mode`, `x-feed-url`, `x-truncated`.
- Content types: `text/gemini`, `text/plain`, `image/jpeg`. Errors are a status plus a one-line `text/plain` reason. Ping answers `picosurf-proxy 1`.

**HTTP (device)**
- `picocalc.network.http.new(host, port, tls)` returns a connection or `nil, err`.
- Callbacks get no arguments, and fire asynchronously between any two Lua statements. They must only record results.
- On success the connection stays usable. On failure `setConnectionClosedCallback` fires and the connection is released, so it must be recreated.
- Redirects are not followed; the proxy follows them.
- `setReadBufferSize` must be called before `get`. It returns a bool and resets the ring buffer. Drain the body in the request callback with `getBytesAvailable` / `read(n)`, and collect chunks in a table. Never build the body with `s = s .. chunk`.
- Timeouts are integer seconds: connect 15, read 20 (an idle timeout).
- At most 2 concurrent requests. Each TLS connection uses about 40 KB of the 128 KB network pool.
- The response body may be at most 512 KB. Anything larger fails with `Page too large (over 512 KB)`.

**Text and display**
- Fonts draw only ASCII 0x20–0x7E. Anything else, including `\t` and `\n`, draws as a box. The proxy folds text to ASCII, and the app expands tabs to 4 spaces.
- The screen is 320×320. `ui.drawHeader(title)` occupies y 0–20 and returns 21. `ui.drawFooter(left, right)` occupies y 302–319. Content rows run from y 21 to 301.
- The body font is `FONT_SCIENTIFICA` (6×12) and headings use `FONT_SCIENTIFICA_BOLD`. The optional large font is `FONT_8X12`. Rows are 13 px apart, with a 4 px side margin. That gives `cols = (320 - 8) // cw`: 52 columns for 6×12 and 39 for 8×12. `rows = (302 - 21) // 13` = 21.
- `display.drawText(x, y, text, fg, false)` draws with a transparent background. Redraw and `flush()` only when something changed. `flush()` swaps buffers, so never flush without redrawing the whole screen.

**UI**
- `ui.textInput(prompt, default)` blocks. It returns the string, or `nil` on Esc, and accepts printable ASCII up to 127 characters.
- `ui.confirm(msg)` blocks and returns a bool.
- `ui.toast(text, style)` is queued and appears on the next flush. Styles are `ui.TOAST_INFO`, `TOAST_SUCCESS`, `TOAST_WARNING` and `TOAST_ERROR`.
- `ui.drawTabs(y, tabs, active)` takes a 1-based index and returns `(active, 21)`. Pass no key masks; the app handles Left/Right itself.
- `ui.drawListItem(x, y, w, text, selected, focused)` draws a 13 px row.
- `sys.addMenuItem(label, fn)` allows at most 4 items. Their callbacks run after the system menu closes.

**Input**
- Use `input.update()` then `input.pollEvent()`. Events look like `{type="down"|"up"|"char", key, char?, mods, button?, repeat?}`.
- Digits and Space arrive as `char` events.
- Shift+Tab arrives as key `0xD2` on the device and as key `0x09` with `mods & BTN_SHIFT` in the simulator. Handle both.
- Ignore `repeat` on F-keys and Esc.

**Storage**
- Use `picocalc.config` only for `proxy_url`, `token` and `font`. All values are strings. It holds at most 4 keys and persists only on `config.save()`. Setting `""` deletes a key.
- Everything else is JSON via `picocalc.fs` and `picocalc.json` under `/data/net.picodeck.picosurf/`. That covers `bookmarks.json` (cap 200), `history.json` (cap 100), `feeds/index.json` (at most 50 feeds) and `feeds/<id>.json` (at most 50 items).
- `fs.mkdir` is not recursive and succeeds when the directory exists. `fs.rename` fails if the destination exists.
- Safe write: write `<name>.tmp`, delete `<name>`, then rename. A leftover `.tmp` is used if the main file is missing, and a corrupt file is renamed `.bad`.
- `picocalc.json.decode` returns `nil, err` on bad input and keeps integers that fit in 32 bits as integers.

**Limits**
- Back stack: 20 entries. Body cache: 3 pages.
- A feed is stale after 1800 s. Refresh-all runs 2 requests at a time.
- `graphics.image.loadFromBuffer` raises on failure, so wrap it in `pcall`.

**Logging.** The app logs with `sys.log("picosurf: <event> ...")`. These lines are part of the test contract; the formats are fixed in the tasks.

### Deviations from the spec (decided while planning)
- **`fetch.lua` is split** into `http.lua` (transport: pool, drain, caps, cancel) and `proxy.lua` (pure protocol: paths, headers, interpreting responses).
- **`view.lua` is split** into `pagestate.lua` (pure: scrolling, selection, typed link number) and `screens/page.lua` (drawing and keys).
- **Word wrapping is pure Lua (`wrap.lua`), not `ui.wrapText`.** The firmware wrapper ignores `\n`, caps output at 512 rows and uses 0-based offsets. The pure version also tests on the host.
- **The app takes the `picocalc` API as a parameter**, so host tests can run every screen against a fake. Spec 7.2 only described simulator tests.
- **The simulator tests use a Python fake proxy, not the Node proxy.** The real proxy's SSRF guard rightly refuses localhost fixture sites, and the app is what's under test here.
- **CI runs the Lua tests under stock Lua 5.4 only.** `make test` also runs them under `lua32`, but building `lua32` needs PicoDeck's Lua sources, which CI doesn't have.
- **Timestamps stay integers.** Research confirmed `picocalc.json` keeps 32-bit integers, which settles the spec's section 10 risk.
- **The feed index stores `newest`**, the date of the newest item, to sort the Feeds tab. Spec 6.7 sorts by newest item.
- **The release ZIP has no icon.** None exists yet, and the store doesn't require one.

### SDK changes considered
The current PicoDeck API covers v1, so this plan adds no firmware functions. These follow-ups are recorded in the README's "Later" section:
- `ui.textInput` with a longer limit. At 127 characters, "Edit URL" refuses many article URLs.
- Simulator fidelity for Shift+Tab (key 0xD2) and for HTTP back-pressure.
- `tcp:peerFingerprint()` for Gemini's trust-on-first-use (TOFU), as spec section 9 already plans.

## Review Focus

These are the inputs the spec implies but no task tests directly, most likely to bite first. Each one now has a test in the task that owns the code:
1. **A very long page** (about 5,000 gemtext lines, the 256 KB cap) must lay out in reasonable time and scroll to 100%. Tests in Task 3 (`layout`) and Task 4 (`pagestate`).
2. **Esc while a page is loading** must cancel the request, ignore the late response and return to the previous screen. Test in Task 10.
3. **A save interrupted by power loss** (a `.tmp` left behind, main file missing) must be recovered on the next load. Test in Task 7.
4. **A typed link number that isn't on the page** must show a toast and not navigate. Tests in Task 4 and Task 10.
5. **Proxy URL variants** (trailing slash, a subpath, a port, plain `http://`, an upper-case scheme) must all parse. An `http://` URL must show the unencrypted-token warning. Tests in Task 1 and Task 10.

---

## File Structure

```
app.json                      manifest
main.lua                      entry: require check, then App.new(picocalc, APP_ID):run()
Makefile                      test (host + lua32), e2e, clean
tools/build_lua32.sh          builds build/lua32 from PicoDeck's Lua sources
src/url.lua                   URL helpers, proxy base parsing
src/gemtext.lua               gemtext → typed lines; feed items; plain text
src/wrap.lua                  word wrap → byte ranges
src/layout.lua                typed lines → screen rows (parallel arrays) + links
src/pagestate.lua             scroll, link selection, typed link number
src/keys.lua                  input events → actions
src/proxy.lua                 proxy paths, headers, response interpretation
src/store.lua                 bookmarks, history, feed files; safe writes
src/feeds.lua                 subscribe, merge, unread, staleness, sorting, list lines
src/http.lua                  connection pool to the proxy (device transport)
src/theme.lua                 colours, fonts, row geometry
src/app.lua                   controller: config, loop, requests, navigation, feeds
src/screens/home.lua          Feeds / Bookmarks / History tabs
src/screens/page.lua          page view
src/screens/image.lua         full-screen image
src/screens/loading.lua       WiFi/clock wait, request progress, cancel
src/screens/message.lua       errors with retry
src/screens/settings.lua      proxy URL, token, font, test connection
tests/run.lua, tests/t.lua    host test runner and asserts (from nova-rail)
tests/fakes.lua               in-memory fs and json
tests/fakepc.lua              fake picocalc API + fake proxy responder
tests/test_*.lua              host tests
tests/e2e/fake_proxy.py       Python fake proxy for the simulator
tests/e2e/conftest.py         simulator fixture
tests/e2e/test_app.py         simulator smoke flows
.github/workflows/ci.yml      + Lua job
.github/workflows/release.yml tag → tests → ZIP → GitHub Release
README.md                     what it is, setup, keys, development, later
docs/hardware-pass.md         the manual hardware checklist (spec 7.2)
```

---

### Task 1: Test scaffold, manifest and URL helpers

**Files:**
- Create: `app.json`, `Makefile`, `tools/build_lua32.sh`, `tests/run.lua`, `tests/t.lua`, `src/url.lua`
- Modify: `.gitignore`, `.github/workflows/ci.yml`
- Test: `tests/test_url.lua`

**Interfaces:**
- Produces:
  - `url.encode(s) -> string`: percent-encodes everything except `A-Za-z0-9-._~`.
  - `url.scheme(u) -> string|nil`: lower-cased.
  - `url.host(u) -> string`.
  - `url.normalize(text) -> url | nil, message`.
  - `url.parseBase(base) -> {host, port, tls, prefix} | nil, message`.
  - Test asserts: `T.ok`, `T.eq`, `T.near`, `T.raises`. A test file returns a table of name → function.

- [ ] **Step 1: Create the manifest, the runner, the asserts, the lua32 build and the Makefile**

`app.json`:
```json
{
  "id": "net.picodeck.picosurf",
  "name": "PicoSurf",
  "description": "Read the web and RSS feeds through your own PicoSurf proxy",
  "version": "0.1.0",
  "author": "PicoDeck",
  "category": "network",
  "min_firmware": "0.5.0",
  "requirements": ["http"]
}
```

`tests/run.lua`:
```lua
-- Host test runner. From the repo root: lua tests/run.lua [file ...]
-- Runs every tests/test_*.lua (or the files given); each returns a table
-- of test functions.
package.path = "./?.lua;" .. package.path

local function discover()
    local files = {}
    local p = assert(io.popen("ls tests/test_*.lua 2>/dev/null"))
    for line in p:lines() do files[#files + 1] = line end
    p:close()
    return files
end

local files = #arg > 0 and arg or discover()
local passed, failed = 0, 0
for _, path in ipairs(files) do
    local cases = assert(loadfile(path))()
    local names = {}
    for name in pairs(cases) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local ok, err = xpcall(cases[name], debug.traceback)
        if ok then
            passed = passed + 1
        else
            failed = failed + 1
            print("FAIL " .. path .. " " .. name .. "\n" .. err)
        end
    end
end
print(string.format("%d passed, %d failed (%s, %s numbers)", passed, failed, _VERSION,
    math.maxinteger == 2147483647 and "32-bit" or "64-bit"))
os.exit(failed == 0 and 0 or 1)
```

`tests/t.lua`:
```lua
-- Assertions for the host tests.
local T = {}

function T.ok(v, msg)
    if not v then error(msg or "expected a true value", 2) end
end

function T.eq(got, want, msg)
    if got ~= want then
        error(string.format("%s: got %s, want %s", msg or "eq", tostring(got), tostring(want)), 2)
    end
end

function T.near(got, want, eps, msg)
    if type(got) ~= "number" or math.abs(got - want) > eps then
        error(string.format("%s: got %s, want %s +- %s", msg or "near", tostring(got),
            tostring(want), tostring(eps)), 2)
    end
end

-- fn must raise an error whose message contains `pattern` (plain text).
function T.raises(fn, pattern, msg)
    local ok, err = pcall(fn)
    if ok then error((msg or "raises") .. ": no error raised", 2) end
    if not string.find(tostring(err), pattern, 1, true) then
        error(string.format("%s: error %q lacks %q", msg or "raises", tostring(err), pattern), 2)
    end
end

return T
```

`tools/build_lua32.sh`, executable (`chmod +x`):
```bash
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
```

`Makefile`. Recipe lines start with a tab.
```make
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
```

Append these two lines to `.gitignore`:
```
build/
__pycache__/
```

- [ ] **Step 2: Write the failing URL tests**

`tests/test_url.lua`:
```lua
local T = require("tests.t")
local url = require("src.url")

return {
    encode_keeps_unreserved_and_escapes_the_rest = function()
        T.eq(url.encode("https://a.b/c?d=e f&g~_-"), "https%3A%2F%2Fa.b%2Fc%3Fd%3De%20f%26g~_-")
    end,
    scheme_is_lower_case_or_nil = function()
        T.eq(url.scheme("HTTPS://x.org/"), "https")
        T.eq(url.scheme("gemini://g.test/"), "gemini")
        T.eq(url.scheme("example.com"), nil)
    end,
    host_strips_scheme_port_and_path = function()
        T.eq(url.host("https://example.com:8080/a?b"), "example.com")
        T.eq(url.host("not a url"), "not a url")
    end,
    normalize_adds_https_and_trims = function()
        T.eq(url.normalize("example.com/a"), "https://example.com/a")
        T.eq(url.normalize("  http://x.org/a  "), "http://x.org/a")
    end,
    normalize_refuses_spaces_and_empty_text = function()
        local u, err = url.normalize("two words")
        T.eq(u, nil)
        T.eq(err, "Not a URL (search isn't supported yet)")
        T.eq(url.normalize("   "), nil)
    end,
    parse_base_variants = function() -- Review Focus 5
        local b = url.parseBase("https://p.example.com")
        T.eq(b.host, "p.example.com"); T.eq(b.port, 443); T.eq(b.tls, true); T.eq(b.prefix, "")
        b = url.parseBase("https://p.example.com/")
        T.eq(b.prefix, "")
        b = url.parseBase("http://192.168.1.5:8080/picosurf/")
        T.eq(b.host, "192.168.1.5"); T.eq(b.port, 8080); T.eq(b.tls, false); T.eq(b.prefix, "/picosurf")
        b = url.parseBase("HTTPS://P.example.com/x")
        T.eq(b.tls, true); T.eq(b.host, "P.example.com"); T.eq(b.prefix, "/x")
        T.eq(math.type(url.parseBase("http://h:81").port), "integer")
    end,
    parse_base_refuses_bad_input = function()
        local b, err = url.parseBase("ftp://x.org")
        T.eq(b, nil); T.eq(err, "Proxy URL must start with https:// or http://")
        b, err = url.parseBase("https://")
        T.eq(err, "Proxy URL has no host")
        b, err = url.parseBase("https://h:99999")
        T.eq(err, "Proxy URL has a bad port")
    end,
}
```

- [ ] **Step 3: Run it to make sure it fails**

Run: `lua tests/run.lua tests/test_url.lua`
Expected: an error that module `src.url` was not found.

- [ ] **Step 4: Implement `src/url.lua`**

```lua
-- URL helpers: what the user typed, schemes and hosts, query encoding, and the
-- proxy's base URL (spec 6.1). Pure.
local M = {}

function M.encode(s)
    return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

function M.scheme(u)
    local s = u:match("^(%a[%w+.%-]*):")
    return s and s:lower() or nil
end

function M.host(u)
    return u:match("^%a[%w+.%-]*://([^/?#:]+)") or u
end

-- What the user typed, as a URL, or nil and a reason. No scheme means https.
function M.normalize(text)
    local t = text:match("^%s*(.-)%s*$")
    if t == "" then return nil, "Type a URL" end
    if t:find("%s") then return nil, "Not a URL (search isn't supported yet)" end
    if not t:find("://", 1, true) then t = "https://" .. t end
    return t
end

-- The proxy's base URL: {host, port, tls, prefix} or nil and a reason.
-- prefix is the path the proxy is served under, without a trailing slash.
function M.parseBase(base)
    local scheme, rest = base:match("^%s*(%a+)://(.-)%s*$")
    scheme = scheme and scheme:lower()
    if scheme ~= "http" and scheme ~= "https" then
        return nil, "Proxy URL must start with https:// or http://"
    end
    local hostport, path = rest:match("^([^/]*)(.*)$")
    local host, port = hostport:match("^(.-):(%d+)$")
    host = host or hostport
    if host == "" then return nil, "Proxy URL has no host" end
    if port then
        port = math.tointeger(tonumber(port))
        if not port or port < 1 or port > 65535 then return nil, "Proxy URL has a bad port" end
    else
        port = scheme == "https" and 443 or 80
    end
    return { host = host, port = port, tls = scheme == "https", prefix = (path:gsub("/+$", "")) }
end

return M
```

- [ ] **Step 5: Run the tests under both Luas**

Run: `make test`
Expected: two summary lines, `7 passed, 0 failed (Lua 5.4, 64-bit numbers)` and `7 passed, 0 failed (Lua 5.4, 32-bit numbers)`. The first run builds `build/lua32`.

- [ ] **Step 6: Add the Lua CI job**

In `.github/workflows/ci.yml`, add a second job under `jobs:`, at the same indent as `proxy:`:
```yaml
  lua:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get install -y lua5.4 > /dev/null
      - run: lua5.4 tests/run.lua
```

- [ ] **Step 7: Commit**

```bash
git add app.json Makefile tools/build_lua32.sh tests/run.lua tests/t.lua tests/test_url.lua src/url.lua .gitignore .github/workflows/ci.yml
git commit -m "feat(app): test scaffold, manifest and URL helpers"
```

---

### Task 2: Gemtext parsing

**Files:**
- Create: `src/gemtext.lua`
- Test: `tests/test_gemtext.lua`

**Interfaces:**
- Produces:
  - `gemtext.parse(body) -> lines`. Each line is `{t = "text"|"h1"|"h2"|"h3"|"item"|"quote"|"pre"|"blank"|"link", text = string}`. Links also have `url`, `n` (the integer in a `[n] label`, or nil) and `image` (true when the label starts with `[IMG]`).
  - `gemtext.line(raw) -> line`, the same as `parse` for a single non-preformatted line.
  - `gemtext.fromPlain(body) -> lines`: text and blank lines only.
  - `gemtext.title(lines) -> string|nil`: the first h1.
  - `gemtext.feedItems(lines) -> {{url, date = "YYYY-MM-DD"|nil, title}}`.
  - Tabs become 4 spaces, and a trailing `\r` is removed.

- [ ] **Step 1: Write the failing tests**

`tests/test_gemtext.lua`:
````lua
local T = require("tests.t")
local g = require("src.gemtext")

return {
    parses_every_line_type = function()
        local lines = g.parse("# One\n## Two\n### Three\n#### Four\ntext\n* item\n> quote\n>bare\n\n=> https://a.test/ [3] the docs\n")
        local want = {
            { "h1", "One" }, { "h2", "Two" }, { "h3", "Three" }, { "h3", "Four" }, { "text", "text" },
            { "item", "item" }, { "quote", "quote" }, { "quote", "bare" }, { "blank", "" }, { "link", "[3] the docs" },
        }
        T.eq(#lines, #want)
        for i, w in ipairs(want) do
            T.eq(lines[i].t, w[1], "type " .. i)
            T.eq(lines[i].text, w[2], "text " .. i)
        end
        T.eq(lines[10].url, "https://a.test/")
        T.eq(lines[10].n, 3)
        T.eq(math.type(lines[10].n), "integer")
        T.eq(lines[10].image, false)
    end,
    links_without_a_label_show_the_url_and_images_are_flagged = function()
        local lines = g.parse("=> https://a.test/x\n=>https://a.test/c.jpg [IMG] A cat\n=>\n")
        T.eq(lines[1].text, "https://a.test/x")
        T.eq(lines[1].n, nil)
        T.eq(lines[2].image, true)
        T.eq(lines[2].url, "https://a.test/c.jpg")
        T.eq(lines[3].t, "text", "a bare => is text")
    end,
    preformatted_blocks_keep_their_lines = function()
        local lines = g.parse("before\n```lua\n=> not a link\n# not a heading\n\tx\n```\nafter")
        T.eq(#lines, 5)
        T.eq(lines[2].t, "pre"); T.eq(lines[2].text, "=> not a link")
        T.eq(lines[3].t, "pre"); T.eq(lines[3].text, "# not a heading")
        T.eq(lines[4].text, "    x", "tab expanded")
        T.eq(lines[5].text, "after")
    end,
    escaped_text_stays_text_and_crlf_is_removed = function()
        local lines = g.parse(" # not heading\r\n => not link\r\n")
        T.eq(lines[1].t, "text"); T.eq(lines[1].text, " # not heading")
        T.eq(lines[2].t, "text"); T.eq(lines[2].text, " => not link")
    end,
    plain_text_becomes_text_and_blank_lines = function()
        local lines = g.fromPlain("a\tb\n\n# c\n")
        T.eq(#lines, 3)
        T.eq(lines[1].text, "a    b")
        T.eq(lines[2].t, "blank")
        T.eq(lines[3].t, "text"); T.eq(lines[3].text, "# c")
    end,
    title_is_the_first_heading = function()
        T.eq(g.title(g.parse("text\n## Sub\n# Main\n# Later\n")), "Main")
        T.eq(g.title(g.parse("no heading\n")), nil)
    end,
    feed_items_split_dates_from_titles = function()
        local items = g.feedItems(g.parse("# Blog\n\n=> https://b.test/2 2026-10-13 Two\n=> https://b.test/u Undated\n"))
        T.eq(#items, 2)
        T.eq(items[1].url, "https://b.test/2"); T.eq(items[1].date, "2026-10-13"); T.eq(items[1].title, "Two")
        T.eq(items[2].date, nil); T.eq(items[2].title, "Undated")
    end,
}
````

- [ ] **Step 2: Run it to make sure it fails**

Run: `lua tests/run.lua tests/test_gemtext.lua`
Expected: an error that `src.gemtext` was not found.

- [ ] **Step 3: Implement `src/gemtext.lua`**

````lua
-- Gemtext into typed lines (spec 6.1-6.3). Pure.
--   {t = "text"|"h1"|"h2"|"h3"|"item"|"quote"|"pre"|"blank"|"link", text = string}
-- Links also carry url, n (the number of a "[n] label", or nil) and image
-- (true when the label starts "[IMG]").
local M = {}

local function eachLine(body)
    if body:sub(-1) ~= "\n" then body = body .. "\n" end
    return body:gmatch("([^\n]*)\n")
end

-- Fonts draw a box for tabs and control bytes.
local function clean(raw)
    return (raw:gsub("\r$", ""):gsub("\t", "    "))
end

function M.line(raw)
    if raw:sub(1, 2) == "=>" then
        local u, label = raw:match("^=>%s*(%S+)%s*(.-)%s*$")
        if u then
            local num = label:match("^%[(%d+)%]")
            return {
                t = "link", url = u, text = label ~= "" and label or u,
                n = num and math.tointeger(tonumber(num)) or nil,
                image = label:sub(1, 5) == "[IMG]",
            }
        end
        return { t = "text", text = raw }
    end
    local hashes, rest = raw:match("^(#+)%s*(.-)%s*$")
    if hashes then return { t = "h" .. math.min(#hashes, 3), text = rest } end
    if raw:sub(1, 2) == "* " then return { t = "item", text = raw:sub(3) } end
    if raw:sub(1, 1) == ">" then return { t = "quote", text = (raw:sub(2):gsub("^ ", "")) } end
    if raw:match("^%s*$") then return { t = "blank", text = "" } end
    return { t = "text", text = raw }
end

function M.parse(body)
    local lines, pre = {}, false
    for raw in eachLine(body) do
        raw = clean(raw)
        if raw:sub(1, 3) == "```" then
            pre = not pre
        elseif pre then
            lines[#lines + 1] = { t = "pre", text = raw }
        else
            lines[#lines + 1] = M.line(raw)
        end
    end
    return lines
end

function M.fromPlain(body)
    local lines = {}
    for raw in eachLine(body) do
        raw = clean(raw)
        lines[#lines + 1] = raw:match("^%s*$") and { t = "blank", text = "" } or { t = "text", text = raw }
    end
    return lines
end

function M.title(lines)
    for _, l in ipairs(lines) do
        if l.t == "h1" then return l.text end
    end
    return nil
end

-- The link lines of a proxy feed list: "=> url YYYY-MM-DD title" or "=> url title".
function M.feedItems(lines)
    local items = {}
    for _, l in ipairs(lines) do
        if l.t == "link" then
            local date, title = l.text:match("^(%d%d%d%d%-%d%d%-%d%d)%s+(.*)$")
            items[#items + 1] = { url = l.url, date = date, title = date and title or l.text }
        end
    end
    return items
end

return M
````

- [ ] **Step 4: Run the tests to make sure they pass**

Run: `make test`
Expected: all tests pass under both Luas.

- [ ] **Step 5: Commit**

```bash
git add src/gemtext.lua tests/test_gemtext.lua
git commit -m "feat(app): parse gemtext into typed lines"
```

---

### Task 3: Word wrap and layout

**Files:**
- Create: `src/wrap.lua`, `src/layout.lua`
- Test: `tests/test_layout.lua`

**Interfaces:**
- Consumes: the line tables from `gemtext` (Task 2). Links may also carry `dim = true`, meaning an already-read feed item (Task 8).
- Produces:
  - `wrap.wrap(text, width) -> starts, ends`. Rows are 1-based inclusive byte ranges, breaking at spaces or hard-breaking long words. Empty text gives one empty row, `{1}, {0}`.
  - `layout.build(lines, cols) -> L`, where `L = {count, line = {}, s = {}, e = {}, style = {}, link = {}, cont = {}, text = {}, links = {}}`.
    - Row `r` shows `L.text[L.line[r]]:sub(L.s[r], L.e[r])`.
    - `L.link[r]` is the link index, or 0.
    - `L.cont[r]` is true for a preformatted row that continues on the next row.
    - Each link is `{url, label, n, image, line, first, last}`, where `first` and `last` are its rows.
  - `layout.rowText(L, r) -> string`.
  - Style constants: `layout.TEXT, H1, H2, H3, ITEM, ITEMC, QUOTE, PRE, LINK, IMAGE, BLANK, READ`.
  - Items and quotes wrap at `cols - 2`, and the view indents them by two columns. Preformatted text is cut at `cols - 1`, leaving room for the `\` continuation mark.

- [ ] **Step 1: Write the failing tests**

`tests/test_layout.lua`:
```lua
local T = require("tests.t")
local wrap = require("src.wrap")
local layout = require("src.layout")
local g = require("src.gemtext")

local function rows(text, width)
    local s, e = wrap.wrap(text, width)
    local out = {}
    for i = 1, #s do out[i] = text:sub(s[i], e[i]) end
    return table.concat(out, "|")
end

return {
    wrap_breaks_at_spaces_and_splits_long_words = function()
        T.eq(rows("hello world", 5), "hello|world")
        T.eq(rows("hello world", 11), "hello world")
        T.eq(rows("abcde fgh", 5), "abcde|fgh")
        T.eq(rows("aaa bbb ccc", 7), "aaa bbb|ccc")
        T.eq(rows("abcdefghij", 4), "abcd|efgh|ij")
        T.eq(rows("a   b", 2), "a|b")
    end,
    wrap_gives_one_empty_row_for_empty_text = function()
        local s, e = wrap.wrap("", 10)
        T.eq(#s, 1); T.eq(s[1], 1); T.eq(e[1], 0)
    end,
    builds_rows_with_styles_and_indents = function()
        local L = layout.build(g.parse("# Title\nhello world foo\n* item text here\n> quoted words\n\n"), 10)
        local got = {}
        for r = 1, L.count do got[r] = L.style[r] .. ":" .. layout.rowText(L, r) end
        T.eq(table.concat(got, "|"), table.concat({
            layout.H1 .. ":Title",
            layout.TEXT .. ":hello", layout.TEXT .. ":world foo",
            layout.ITEM .. ":item", layout.ITEMC .. ":text", layout.ITEMC .. ":here",
            layout.QUOTE .. ":quoted", layout.QUOTE .. ":words",
            layout.BLANK .. ":",
        }, "|"))
    end,
    preformatted_rows_are_cut_and_marked = function()
        local L = layout.build(g.parse("```\nabcdefghijklm\n\n```\n"), 6)
        T.eq(L.count, 4)
        T.eq(layout.rowText(L, 1), "abcde"); T.eq(L.cont[1], true)
        T.eq(layout.rowText(L, 2), "fghij"); T.eq(L.cont[2], true)
        T.eq(layout.rowText(L, 3), "klm"); T.eq(L.cont[3], false)
        T.eq(layout.rowText(L, 4), ""); T.eq(L.style[4], layout.PRE)
    end,
    links_record_their_rows = function()
        local lines = g.parse("intro\n=> https://a.test/ [1] a long link label\n=> https://a.test/c.jpg [IMG] Cat\n")
        lines[#lines + 1] = { t = "link", url = "https://a.test/r", text = "read one", dim = true }
        local L = layout.build(lines, 10)
        T.eq(#L.links, 3)
        local a = L.links[1]
        -- "[1] a long link label" at 10 columns wraps to "[1] a long" / "link label".
        T.eq(a.url, "https://a.test/"); T.eq(a.n, 1); T.eq(a.first, 2); T.eq(a.last, 3)
        for r = a.first, a.last do T.eq(L.link[r], 1); T.eq(L.style[r], layout.LINK) end
        T.eq(L.link[1], 0)
        T.eq(L.style[L.links[2].first], layout.IMAGE)
        T.eq(L.style[L.links[3].first], layout.READ)
    end,
    lays_out_a_very_long_page = function() -- Review Focus 1
        local parts = {}
        local line = string.rep("word ", 20)
        for i = 1, 5000 do parts[i] = line end
        local started = os.clock()
        local L = layout.build(g.parse(table.concat(parts, "\n")), 52)
        T.eq(L.count, 10000, "100 characters at 52 columns is two rows per line")
        T.ok(os.clock() - started < 3, "layout took under 3 s on the host")
    end,
}
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `lua tests/run.lua tests/test_layout.lua`
Expected: an error that `src.wrap` was not found.

- [ ] **Step 3: Implement `src/wrap.lua`**

```lua
-- Word wrap for fixed-width text (spec 6.3). Pure. Rows are 1-based inclusive
-- byte ranges; text has no newlines (one gemtext line at a time).
local M = {}

-- Returns starts, ends: row k is text:sub(starts[k], ends[k]). Breaks at the last
-- space that fits, splits words longer than width, and drops the spaces at a
-- break. Empty text gives one empty row.
function M.wrap(text, width)
    local s, e = {}, {}
    local n, i = #text, 1
    if n == 0 then return { 1 }, { 0 } end
    while i <= n do
        if n - i + 1 <= width then
            s[#s + 1], e[#e + 1] = i, n
            break
        end
        local cut
        for j = i + width, i + 1, -1 do
            if text:byte(j) == 32 then cut = j; break end
        end
        if cut then
            local k = cut - 1
            while k > i and text:byte(k) == 32 do k = k - 1 end
            s[#s + 1], e[#e + 1] = i, k
            i = cut + 1
            while i <= n and text:byte(i) == 32 do i = i + 1 end
        else
            s[#s + 1], e[#e + 1] = i, i + width - 1
            i = i + width
        end
    end
    return s, e
end

return M
```

- [ ] **Step 4: Implement `src/layout.lua`**

```lua
-- Typed lines into screen rows (spec 6.3). Pure. Rows are parallel integer
-- arrays pointing into the lines' text, so a 256 KB page doesn't copy its text.
local wrap = require("src.wrap")

local M = {}
M.TEXT, M.H1, M.H2, M.H3, M.ITEM, M.ITEMC = 1, 2, 3, 4, 5, 6
M.QUOTE, M.PRE, M.LINK, M.IMAGE, M.BLANK, M.READ = 7, 8, 9, 10, 11, 12

local INDENT = 2
local HEADINGS = { h1 = M.H1, h2 = M.H2, h3 = M.H3 }

function M.build(lines, cols)
    local L = { count = 0, line = {}, s = {}, e = {}, style = {}, link = {}, cont = {}, text = {}, links = {} }
    local function add(li, s, e, style, link, cont)
        local n = L.count + 1
        L.count = n
        L.line[n], L.s[n], L.e[n], L.style[n], L.link[n], L.cont[n] = li, s, e, style, link, cont
    end
    for li, ln in ipairs(lines) do
        local t = ln.t
        L.text[li] = ln.text
        if t == "blank" then
            add(li, 1, 0, M.BLANK, 0, false)
        elseif t == "pre" then
            local text, w = ln.text, cols - 1
            if #text == 0 then add(li, 1, 0, M.PRE, 0, false) end
            local i = 1
            while i <= #text do
                local j = math.min(i + w - 1, #text)
                add(li, i, j, M.PRE, 0, j < #text)
                i = j + 1
            end
        else
            local style, width, link = HEADINGS[t] or M.TEXT, cols, 0
            if t == "item" then
                style, width = M.ITEM, cols - INDENT
            elseif t == "quote" then
                style, width = M.QUOTE, cols - INDENT
            elseif t == "link" then
                style = ln.image and M.IMAGE or (ln.dim and M.READ or M.LINK)
                L.links[#L.links + 1] = { url = ln.url, label = ln.text, n = ln.n, image = ln.image,
                                          line = li, first = L.count + 1, last = 0 }
                link = #L.links
            end
            local s, e = wrap.wrap(ln.text, width)
            for k = 1, #s do
                add(li, s[k], e[k], (style == M.ITEM and k > 1) and M.ITEMC or style, link, false)
            end
            if link > 0 then L.links[link].last = L.count end
        end
    end
    return L
end

function M.rowText(L, r)
    return L.text[L.line[r]]:sub(L.s[r], L.e[r])
end

return M
```

- [ ] **Step 5: Run the tests to make sure they pass**

Run: `make test`
Expected: all tests pass under both Luas.

- [ ] **Step 6: Commit**

```bash
git add src/wrap.lua src/layout.lua tests/test_layout.lua
git commit -m "feat(app): word wrap and row layout"
```

---

### Task 4: Page state (scrolling, selection, typed link numbers)

**Files:**
- Create: `src/pagestate.lua`
- Test: `tests/test_pagestate.lua`

**Interfaces:**
- Consumes: `layout.build` (Task 3).
- Produces:
  - `pagestate.new(L, visible) -> ps`, with fields `ps.L`, `ps.visible`, `ps.top` (first visible row, starting at 1), `ps.sel` (selected link index or nil) and `ps.digits` (a string).
  - Methods:
    - `ps:maxTop()`, `ps:lastVisible()`, `ps:visibleLinks()`
    - `ps:scroll(n) -> moved`, `ps:page(dir) -> moved`
    - `ps:nextLink(dir) -> changed`, where `dir` is `1` or `-1`
    - `ps:selected() -> link|nil`
    - `ps:typeDigit(c)` (at most 4 digits), `ps:eraseDigit()`, `ps:clearDigits()`
    - `ps:takeNumbered() -> link | nil, n`, which clears the digits
    - `ps:percent() -> integer 0..100`
    - `ps:restore(top, sel)`
  - Selection rules:
    - Only visible links can be selected, and stepping wraps around among them.
    - When scrolling moves the selection off screen, the nearest visible link is selected: the first visible one if the selection went off the top, the last if it went off the bottom. With no visible link, nothing is selected.

- [ ] **Step 1: Write the failing tests**

`tests/test_pagestate.lua`:
```lua
local T = require("tests.t")
local layout = require("src.layout")
local pagestate = require("src.pagestate")
local g = require("src.gemtext")

-- 30 rows: link [1] on row 2, [2] on row 15, [3] on row 29.
local function page()
    local parts = {}
    for i = 1, 30 do parts[i] = "line " .. i end
    parts[2] = "=> https://a.test/1 [1] one"
    parts[15] = "=> https://a.test/2 [2] two"
    parts[29] = "=> https://a.test/3 [3] three"
    return pagestate.new(layout.build(g.parse(table.concat(parts, "\n")), 40), 10)
end

return {
    scrolling_is_clamped = function()
        local ps = page()
        T.eq(ps:maxTop(), 21)
        T.eq(ps:scroll(-1), false)
        T.eq(ps:scroll(5), true); T.eq(ps.top, 6)
        ps:scroll(100); T.eq(ps.top, 21); T.eq(ps:lastVisible(), 30)
        ps:page(-1); T.eq(ps.top, 12)
    end,
    percent_runs_from_0_to_100 = function()
        local ps = page()
        T.eq(ps:percent(), 0)
        ps:scroll(10); T.eq(ps:percent(), 50)
        ps:scroll(100); T.eq(ps:percent(), 100)
        local short = pagestate.new(layout.build(g.parse("one\ntwo"), 40), 10)
        T.eq(short:percent(), 100)
    end,
    next_link_selects_among_visible_links_and_wraps = function()
        local ps = page()
        T.eq(ps:nextLink(1), true); T.eq(ps.sel, 1)
        ps:nextLink(1); T.eq(ps.sel, 1, "only [1] is visible on rows 1-10")
        ps:scroll(5) -- rows 6-15
        T.eq(ps.sel, 2, "[1] scrolled off the top, so the first visible link is chosen")
        ps:scroll(-5) -- rows 1-10
        T.eq(ps.sel, 1, "[2] scrolled off the bottom, so the last visible link is chosen")
        ps:scroll(2) -- rows 3-12: no links
        T.eq(ps.sel, nil)
        T.eq(ps:nextLink(1), false)
    end,
    previous_link_starts_from_the_last_visible = function()
        local ps = page()
        ps:scroll(14) -- rows 15-24
        ps:nextLink(-1)
        T.eq(ps:selected().url, "https://a.test/2")
    end,
    typed_numbers_find_links_anywhere_on_the_page = function() -- Review Focus 4
        local ps = page()
        ps:typeDigit("3")
        T.eq(ps.digits, "3")
        local link = ps:takeNumbered()
        T.eq(link.url, "https://a.test/3")
        T.eq(ps.digits, "")
        ps:typeDigit("9"); ps:typeDigit("9")
        local missing, n = ps:takeNumbered()
        T.eq(missing, nil); T.eq(n, 99)
        T.eq(ps:takeNumbered(), nil, "no digits")
    end,
    digits_are_capped_and_editable = function()
        local ps = page()
        for _, d in ipairs({ "1", "2", "3", "4", "5" }) do ps:typeDigit(d) end
        T.eq(ps.digits, "1234")
        ps:eraseDigit(); T.eq(ps.digits, "123")
        ps:clearDigits(); T.eq(ps.digits, "")
    end,
    restore_clamps_and_drops_hidden_selection = function()
        local ps = page()
        ps:restore(500, 1)
        T.eq(ps.top, 21)
        T.eq(ps.sel, 3, "[1] is off screen, so the nearest visible link is chosen")
        ps:restore(1, nil)
        T.eq(ps.sel, nil)
    end,
    scrolls_to_the_end_of_a_very_long_page = function() -- Review Focus 1
        local parts = {}
        for i = 1, 5000 do parts[i] = "line " .. i end
        local ps = pagestate.new(layout.build(g.parse(table.concat(parts, "\n")), 52), 21)
        while ps:page(1) do end
        T.eq(ps:percent(), 100)
        T.eq(ps:lastVisible(), 5000)
    end,
}
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `lua tests/run.lua tests/test_pagestate.lua`
Expected: an error that `src.pagestate` was not found.

- [ ] **Step 3: Implement `src/pagestate.lua`**

```lua
-- Scroll position, link selection and the typed link number of one page
-- (spec 6.4). Pure.
local M = {}
M.__index = M

-- L: a layout (layout.build); visible: how many rows fit on screen.
function M.new(L, visible)
    return setmetatable({ L = L, visible = visible, top = 1, sel = nil, digits = "" }, M)
end

function M:maxTop()
    return math.max(1, self.L.count - self.visible + 1)
end

function M:lastVisible()
    return math.min(self.L.count, self.top + self.visible - 1)
end

local function isVisible(self, k)
    local link = self.L.links[k]
    return link.last >= self.top and link.first <= self:lastVisible()
end

function M:visibleLinks()
    local out = {}
    for k = 1, #self.L.links do
        if isVisible(self, k) then out[#out + 1] = k end
    end
    return out
end

-- Keeps the selection on screen: a link scrolled off the top gives way to the
-- first visible link, one scrolled off the bottom to the last.
local function keepSelectionVisible(self)
    if self.sel and not isVisible(self, self.sel) then
        local vis = self:visibleLinks()
        if #vis == 0 then
            self.sel = nil
        elseif self.L.links[self.sel].last < self.top then
            self.sel = vis[1]
        else
            self.sel = vis[#vis]
        end
    end
end

function M:scroll(n)
    local t = math.max(1, math.min(self:maxTop(), self.top + n))
    if t == self.top then return false end
    self.top = t
    keepSelectionVisible(self)
    return true
end

function M:page(dir)
    return self:scroll(dir * math.max(1, self.visible - 1))
end

function M:nextLink(dir)
    local vis = self:visibleLinks()
    if #vis == 0 then return false end
    if not self.sel then
        self.sel = dir > 0 and vis[1] or vis[#vis]
        return true
    end
    for i, k in ipairs(vis) do
        if k == self.sel then
            local j = i + dir
            if j < 1 then j = #vis elseif j > #vis then j = 1 end
            self.sel = vis[j]
            return true
        end
    end
    self.sel = vis[1]
    return true
end

function M:selected()
    return self.sel and self.L.links[self.sel] or nil
end

function M:typeDigit(c)
    if #self.digits < 4 then self.digits = self.digits .. c end
end

function M:eraseDigit()
    self.digits = self.digits:sub(1, -2)
end

function M:clearDigits()
    self.digits = ""
end

-- The link labelled [n] for the typed number, or nil and n. Clears the digits.
function M:takeNumbered()
    local n = math.tointeger(tonumber(self.digits))
    self.digits = ""
    if not n then return nil end
    for _, link in ipairs(self.L.links) do
        if link.n == n then return link end
    end
    return nil, n
end

function M:percent()
    local m = self:maxTop()
    if m <= 1 then return 100 end
    return ((self.top - 1) * 100) // (m - 1)
end

function M:restore(top, sel)
    self.top = math.max(1, math.min(self:maxTop(), top or 1))
    self.sel = (sel and self.L.links[sel]) and sel or nil
    keepSelectionVisible(self)
end

return M
```

- [ ] **Step 4: Run the tests to make sure they pass**

Run: `make test`
Expected: all tests pass under both Luas.

- [ ] **Step 5: Commit**

```bash
git add src/pagestate.lua tests/test_pagestate.lua
git commit -m "feat(app): page scrolling, link selection and typed link numbers"
```

---

### Task 5: Keys

**Files:**
- Create: `src/keys.lua`
- Test: `tests/test_keys.lua`

**Interfaces:**
- Consumes: the `BTN_*` constants from `picocalc.input`, or a table with the same fields.
- Produces: `keys.decoder(I) -> decode(ev) -> action, arg`. The possible actions are:
  - `"up"`, `"down"`, `"left"`, `"right"`
  - `"enter"`, `"esc"`, `"backspace"`, `"del"`
  - `"f1"` to `"f5"`
  - `"nextlink"`, `"prevlink"`
  - `"space"`
  - `"digit"`, with the digit character as `arg`
  - `nil` for anything else

- [ ] **Step 1: Write the failing tests**

`tests/test_keys.lua`:
```lua
local T = require("tests.t")
local keys = require("src.keys")

local I = {
    BTN_UP = 1, BTN_DOWN = 2, BTN_LEFT = 4, BTN_RIGHT = 8, BTN_ENTER = 16, BTN_ESC = 32,
    BTN_F1 = 128, BTN_F2 = 256, BTN_F3 = 512, BTN_F4 = 1024, BTN_F5 = 2048,
    BTN_BACKSPACE = 65536, BTN_TAB = 131072, BTN_DEL = 262144, BTN_SHIFT = 524288,
}
local decode = keys.decoder(I)
local function down(key, button, mods, rep)
    return decode({ type = "down", key = key, button = button, mods = mods or 0, ["repeat"] = rep })
end

return {
    buttons_map_to_actions = function()
        T.eq(down(0xB5, I.BTN_UP), "up"); T.eq(down(0xB6, I.BTN_DOWN), "down")
        T.eq(down(0xB4, I.BTN_LEFT), "left"); T.eq(down(0xB7, I.BTN_RIGHT), "right")
        T.eq(down(0x0A, I.BTN_ENTER), "enter"); T.eq(down(0xB1, I.BTN_ESC), "esc")
        T.eq(down(0x08, I.BTN_BACKSPACE), "backspace"); T.eq(down(0xD4, I.BTN_DEL), "del")
        T.eq(down(0x81, I.BTN_F1), "f1"); T.eq(down(0x85, I.BTN_F5), "f5")
    end,
    tab_and_both_shift_tab_forms = function()
        T.eq(down(0x09, I.BTN_TAB), "nextlink")
        T.eq(down(0xD2, nil), "prevlink", "the device sends Shift+Tab as key 0xD2")
        T.eq(down(0x09, I.BTN_TAB, I.BTN_SHIFT), "prevlink", "the simulator sends Tab with Shift")
    end,
    chars_give_digits_and_space_only = function()
        local a, d = decode({ type = "char", key = 0x37, char = "7", mods = 0 })
        T.eq(a, "digit"); T.eq(d, "7")
        T.eq(decode({ type = "char", key = 0x20, char = " ", mods = 0 }), "space")
        T.eq(decode({ type = "char", key = 0x61, char = "a", mods = 0 }), nil)
        T.eq(decode({ type = "char", key = 0x0A, char = "\n", mods = 0 }), nil)
    end,
    key_releases_and_repeated_function_keys_are_ignored = function()
        T.eq(decode({ type = "up", key = 0xB5, button = I.BTN_UP, mods = 0 }), nil)
        T.eq(down(0x83, I.BTN_F3, 0, true), nil)
        T.eq(down(0xB1, I.BTN_ESC, 0, true), nil)
        T.eq(down(0xB6, I.BTN_DOWN, 0, true), "down", "arrows keep repeating")
    end,
    unknown_keys_give_nothing = function()
        T.eq(down(0xD6, nil), nil)
    end,
}
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `lua tests/run.lua tests/test_keys.lua`
Expected: an error that `src.keys` was not found.

- [ ] **Step 3: Implement `src/keys.lua`**

```lua
-- Keyboard events into actions (spec 6.4). Pure: the input constants are passed in.
-- On the device Shift+Tab arrives as key 0xD2; the simulator sends Tab with Shift.
local M = {}
local KEY_TAB, KEY_SHIFT_TAB = 0x09, 0xD2

function M.decoder(I)
    local byButton = {
        [I.BTN_UP] = "up", [I.BTN_DOWN] = "down", [I.BTN_LEFT] = "left", [I.BTN_RIGHT] = "right",
        [I.BTN_ENTER] = "enter", [I.BTN_ESC] = "esc", [I.BTN_BACKSPACE] = "backspace", [I.BTN_DEL] = "del",
        [I.BTN_F1] = "f1", [I.BTN_F2] = "f2", [I.BTN_F3] = "f3", [I.BTN_F4] = "f4", [I.BTN_F5] = "f5",
    }
    -- Held F-keys and Esc report repeats; acting on them would run an action twice.
    local noRepeat = { f1 = true, f2 = true, f3 = true, f4 = true, f5 = true, esc = true }
    return function(ev)
        if ev.type == "char" then
            local c = ev.char
            if c and c:match("^%d$") then return "digit", c end
            if c == " " then return "space" end
            return nil
        end
        if ev.type ~= "down" then return nil end
        local shift = ((ev.mods or 0) & I.BTN_SHIFT) ~= 0
        if ev.key == KEY_SHIFT_TAB or (ev.key == KEY_TAB and shift) then return "prevlink" end
        if ev.key == KEY_TAB then return "nextlink" end
        local action = ev.button and byButton[ev.button]
        if action and noRepeat[action] and ev["repeat"] then return nil end
        return action
    end
end

return M
```

- [ ] **Step 4: Run the tests to make sure they pass**

Run: `make test`
Expected: all tests pass under both Luas.

- [ ] **Step 5: Commit**

```bash
git add src/keys.lua tests/test_keys.lua
git commit -m "feat(app): decode keyboard events into actions"
```

---

### Task 6: Proxy protocol

**Files:**
- Create: `src/proxy.lua`
- Test: `tests/test_proxy.lua`

**Interfaces:**
- Consumes: `url.encode` (Task 1), and the `base` table from `url.parseBase`.
- Produces:
  - `proxy.getPath(base, target, as) -> string`
  - `proxy.pingPath(base) -> string`
  - `proxy.headers(token) -> {Authorization = "Bearer <token>"}`
  - `proxy.interpret(ok, status, body, headers) -> result`. The result is one of:
    - `{kind = "gemini"|"text"|"image", body, finalUrl, title, mode, feedUrl, truncated}`
    - `{kind = "error", status?, message}`
    - `{kind = "clock", message}`
  - `proxy.interpretPing(ok, status, body, headers) -> {ok = true} | {ok = false, message}`
  - The arguments `(ok, status, bodyOrError, headers)` are what an `http.lua` callback delivers.

- [ ] **Step 1: Write the failing tests**

`tests/test_proxy.lua`:
```lua
local T = require("tests.t")
local proxy = require("src.proxy")

local BASE = { host = "p.test", port = 443, tls = true, prefix = "/ps" }

return {
    builds_paths_and_headers = function()
        T.eq(proxy.getPath(BASE, "https://a.test/x?y=1", "full"), "/ps/v1/get?url=https%3A%2F%2Fa.test%2Fx%3Fy%3D1&as=full")
        T.eq(proxy.getPath({ prefix = "" }, "https://a.test/", nil), "/v1/get?url=https%3A%2F%2Fa.test%2F")
        T.eq(proxy.pingPath(BASE), "/ps/v1/ping")
        T.eq(proxy.headers("tok").Authorization, "Bearer tok")
    end,
    reads_gemtext_with_headers = function()
        local r = proxy.interpret(true, 200, "# Hi\n", {
            ["content-type"] = "text/gemini; charset=us-ascii", ["x-final-url"] = "https://a.test/f",
            ["x-title"] = "Hi", ["x-mode"] = "reader", ["x-feed-url"] = "https://a.test/feed", ["x-truncated"] = "1",
        })
        T.eq(r.kind, "gemini"); T.eq(r.body, "# Hi\n"); T.eq(r.finalUrl, "https://a.test/f")
        T.eq(r.title, "Hi"); T.eq(r.mode, "reader"); T.eq(r.feedUrl, "https://a.test/feed"); T.eq(r.truncated, true)
    end,
    reads_text_and_images = function()
        T.eq(proxy.interpret(true, 200, "x", { ["content-type"] = "text/plain; charset=us-ascii" }).kind, "text")
        T.eq(proxy.interpret(true, 200, "x", { ["content-type"] = "image/jpeg" }).kind, "image")
        local r = proxy.interpret(true, 200, "x", { ["content-type"] = "application/pdf" })
        T.eq(r.kind, "error"); T.eq(r.message, "Unexpected response: application/pdf")
    end,
    turns_statuses_into_messages = function()
        T.eq(proxy.interpret(true, 401, "Missing or wrong token\n", {}).message, "Proxy rejected the token - check Settings")
        local r = proxy.interpret(true, 502, "Site returned 404 Not Found\n", { ["x-upstream-status"] = "404" })
        T.eq(r.kind, "error"); T.eq(r.status, 502); T.eq(r.message, "Site returned 404 Not Found")
        T.eq(proxy.interpret(true, 500, "", {}).message, "Proxy error 500")
    end,
    turns_transport_failures_into_messages = function()
        T.eq(proxy.interpret(false, nil, "clock not set: TLS needs the time from SNTP", nil).kind, "clock")
        T.eq(proxy.interpret(false, nil, "read timeout (20000ms)", nil).message, "Proxy did not respond")
        T.eq(proxy.interpret(false, nil, "connect timeout (15000ms)", nil).message, "Proxy did not respond")
        T.eq(proxy.interpret(false, nil, "Page too large (over 512 KB)", nil).message, "Page too large (over 512 KB)")
    end,
    interprets_ping = function()
        T.eq(proxy.interpretPing(true, 200, "picosurf-proxy 1\n", {}).ok, true)
        T.eq(proxy.interpretPing(true, 200, "<html>", {}).message, "That URL is not a PicoSurf proxy")
        T.eq(proxy.interpretPing(true, 401, "Missing or wrong token\n", {}).message, "Proxy rejected the token - check Settings")
        T.eq(proxy.interpretPing(false, nil, "connect timeout (15000ms)", nil).message, "Proxy did not respond")
    end,
}
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `lua tests/run.lua tests/test_proxy.lua`
Expected: an error that `src.proxy` was not found.

- [ ] **Step 3: Implement `src/proxy.lua`**

```lua
-- The PicoSurf proxy protocol on the device side (spec 5.1-5.3, 6.1). Pure:
-- request paths and headers, and what a response means.
local url = require("src.url")

local M = {}

function M.getPath(base, target, as)
    local p = base.prefix .. "/v1/get?url=" .. url.encode(target)
    if as then p = p .. "&as=" .. as end
    return p
end

function M.pingPath(base)
    return base.prefix .. "/v1/ping"
end

function M.headers(token)
    return { Authorization = "Bearer " .. token }
end

local function firstLine(s)
    return ((s or ""):match("^%s*([^\r\n]*)") or ""):sub(1, 120)
end

local KINDS = { ["text/gemini"] = "gemini", ["text/plain"] = "text", ["image/jpeg"] = "image" }

-- ok, status, bodyOrError, headers: as delivered by an http.lua callback.
function M.interpret(ok, status, body, headers)
    if not ok then
        local msg = body or "Request failed"
        if msg:find("clock not set", 1, true) then return { kind = "clock", message = "Waiting for time sync..." } end
        if msg:find("timeout", 1, true) then return { kind = "error", message = "Proxy did not respond" } end
        return { kind = "error", message = msg }
    end
    headers = headers or {}
    if status == 200 then
        local mime = ((headers["content-type"] or ""):match("^%s*([^;%s]+)") or ""):lower()
        local kind = KINDS[mime]
        if not kind then
            return { kind = "error", status = status, message = "Unexpected response: " .. (mime ~= "" and mime or "no type") }
        end
        return {
            kind = kind, body = body, finalUrl = headers["x-final-url"], title = headers["x-title"],
            mode = headers["x-mode"], feedUrl = headers["x-feed-url"], truncated = headers["x-truncated"] == "1",
        }
    end
    if status == 401 then
        return { kind = "error", status = 401, message = "Proxy rejected the token - check Settings" }
    end
    local line = firstLine(body)
    return { kind = "error", status = status, message = line ~= "" and line or ("Proxy error " .. tostring(status)) }
end

function M.interpretPing(ok, status, body, headers)
    if ok and status == 200 then
        if (body or ""):find("^picosurf%-proxy") then return { ok = true } end
        return { ok = false, message = "That URL is not a PicoSurf proxy" }
    end
    return { ok = false, message = M.interpret(ok, status, body, headers).message }
end

return M
```

- [ ] **Step 4: Run the tests to make sure they pass**

Run: `make test`
Expected: all tests pass under both Luas.

- [ ] **Step 5: Commit**

```bash
git add src/proxy.lua tests/test_proxy.lua
git commit -m "feat(app): proxy request paths and response interpretation"
```

---

### Task 7: Storage

**Files:**
- Create: `src/store.lua`, `tests/fakes.lua`
- Test: `tests/test_store.lua`

**Interfaces:**
- Consumes:
  - From `picocalc.fs`: `fs.mkdir`, `fs.exists`, `fs.readFile`, `fs.delete`, `fs.rename`, `fs.open(path, "w")`, `fs.write(h, s)` (bytes written, or -1) and `fs.close(h)`.
  - `json.encode`, and `json.decode`, which returns `nil, err` on bad input.
- Produces:
  - `store.new(fs, json, dir) -> s`, which creates `dir` and `dir/feeds`.
  - `s.notes`: messages for the user, such as an unreadable file that was reset.
  - `s:load(name, default) -> table` and `s:save(name, value) -> bool`.
  - Bookmarks: `s:bookmarks() -> list`, `s:isBookmarked(url) -> bool`, `s:toggleBookmark(url, title) -> added`, `s:removeBookmark(i)`.
  - History: `s:history() -> list`, `s:addHistory(url, title)`, `s:removeHistory(i)`.
  - Feeds:
    - `s:feedIndex() -> {next_id, feeds}`, cached in memory; saved with `s:saveFeedIndex()`.
    - `s:feedData(id) -> {items, seen}`, freshly loaded on each call; saved with `s:saveFeedData(id, data)`.
    - `s:deleteFeedData(id)`.
  - Constants: `store.MAX_BOOKMARKS = 200`, `store.MAX_HISTORY = 100`.
  - Test fakes: `fakes.fs() -> fs, files` (files maps path to string) and `fakes.json() -> json`.

- [ ] **Step 1: Write the test fakes**

`tests/fakes.lua`:
```lua
-- In-memory stand-ins for picocalc.fs and picocalc.json (host tests).
local M = {}

-- Keeps the device semantics that matter: rename fails when the destination
-- exists; mkdir succeeds when the directory is already there.
function M.fs()
    local files, dirs = {}, {}
    local fs = {}
    function fs.mkdir(p) dirs[p] = true; return true end
    function fs.exists(p) return files[p] ~= nil or dirs[p] == true end
    function fs.readFile(p) return files[p] end
    function fs.delete(p)
        if files[p] == nil then return false, "delete failed" end
        files[p] = nil
        return true
    end
    function fs.rename(a, b)
        if files[a] == nil or files[b] ~= nil then return false, "rename failed" end
        files[b], files[a] = files[a], nil
        return true
    end
    function fs.open(p, mode)
        if mode ~= "w" then return nil, "cannot open file" end
        return { path = p, parts = {} }
    end
    function fs.write(h, s) h.parts[#h.parts + 1] = s; return #s end
    function fs.close(h) files[h.path] = table.concat(h.parts) end
    return fs, files
end

-- A json that keeps deep copies of values behind handle strings ("#3"), so tests
-- check what was saved without a JSON parser. Decoding anything else fails.
function M.json()
    local blobs = {}
    local function copy(v)
        if type(v) ~= "table" then return v end
        local t = {}
        for k, x in pairs(v) do t[k] = copy(x) end
        return t
    end
    local json = {}
    function json.encode(v)
        blobs[#blobs + 1] = copy(v)
        return "#" .. #blobs
    end
    function json.decode(s)
        local i = s:match("^#(%d+)$")
        local v = i and blobs[math.tointeger(tonumber(i))]
        if v == nil then return nil, "json.decode: invalid" end
        return copy(v)
    end
    return json
end

return M
```

- [ ] **Step 2: Write the failing tests**

`tests/test_store.lua`:
```lua
local T = require("tests.t")
local fakes = require("tests.fakes")
local store = require("src.store")

local DIR = "/data/net.picodeck.picosurf"

local function make()
    local fs, files = fakes.fs()
    local json = fakes.json()
    return store.new(fs, json, DIR), files, fs, json
end

return {
    bookmarks_toggle_newest_first_and_persist = function()
        local s, files, fs, json = make()
        T.eq(s:toggleBookmark("https://a.test/", "A"), true)
        T.eq(s:toggleBookmark("https://b.test/", "B"), true)
        T.eq(s:bookmarks()[1].url, "https://b.test/")
        T.ok(s:isBookmarked("https://a.test/"))
        T.eq(s:toggleBookmark("https://a.test/", "A"), false)
        T.ok(not s:isBookmarked("https://a.test/"))
        local again = store.new(fs, json, DIR)
        T.eq(#again:bookmarks(), 1)
        T.eq(again:bookmarks()[1].title, "B")
        T.eq(files[DIR .. "/bookmarks.json.tmp"], nil, "no temporary file left behind")
    end,
    bookmarks_are_capped = function()
        local s = make()
        for i = 1, store.MAX_BOOKMARKS + 5 do s:toggleBookmark("https://a.test/" .. i, "A") end
        T.eq(#s:bookmarks(), store.MAX_BOOKMARKS)
        T.eq(s:bookmarks()[1].url, "https://a.test/" .. (store.MAX_BOOKMARKS + 5))
        s:removeBookmark(1)
        T.eq(#s:bookmarks(), store.MAX_BOOKMARKS - 1)
    end,
    history_moves_revisits_to_the_top_and_is_capped = function()
        local s = make()
        s:addHistory("https://a.test/", "A")
        s:addHistory("https://b.test/", "B")
        s:addHistory("https://a.test/", "A again")
        T.eq(#s:history(), 2)
        T.eq(s:history()[1].title, "A again")
        for i = 1, store.MAX_HISTORY + 3 do s:addHistory("https://h.test/" .. i, "H") end
        T.eq(#s:history(), store.MAX_HISTORY)
        s:removeHistory(1)
        T.eq(#s:history(), store.MAX_HISTORY - 1)
    end,
    save_replaces_an_existing_file = function()
        local s, files = make()
        T.eq(s:save("x.json", { 1 }), true)
        T.eq(s:save("x.json", { 2 }), true)
        T.eq(s:load("x.json", {})[1], 2)
        T.eq(files[DIR .. "/x.json.tmp"], nil)
    end,
    recovers_a_save_interrupted_before_the_rename = function() -- Review Focus 3
        local s, files, fs, json = make()
        s:save("x.json", { 7 })
        files[DIR .. "/x.json.tmp"] = files[DIR .. "/x.json"]
        files[DIR .. "/x.json"] = nil
        local again = store.new(fs, json, DIR)
        T.eq(again:load("x.json", {})[1], 7)
        T.ok(files[DIR .. "/x.json"] ~= nil, "the temporary file became the main file")
    end,
    an_unreadable_file_is_set_aside = function()
        local s, files = make()
        files[DIR .. "/history.json"] = "not json"
        T.eq(#s:history(), 0)
        T.eq(files[DIR .. "/history.json.bad"], "not json")
        T.eq(files[DIR .. "/history.json"], nil)
        T.eq(s.notes[1], "history.json was unreadable; started empty")
    end,
    feed_index_and_data_round_trip = function()
        local s, _, fs, json = make()
        local idx = s:feedIndex()
        T.eq(idx.next_id, 1); T.eq(#idx.feeds, 0)
        idx.feeds[1] = { id = 1, url = "https://f.test/", title = "F", fetched_at = 1792000000, unread = 2, newest = "2026-10-13" }
        idx.next_id = 2
        T.eq(s:saveFeedIndex(), true)
        s:saveFeedData(1, { items = { { url = "u", date = "", title = "t" } }, seen = { "u" } })
        local again = store.new(fs, json, DIR)
        T.eq(again:feedIndex().feeds[1].fetched_at, 1792000000)
        T.eq(math.type(again:feedIndex().feeds[1].fetched_at), "integer")
        T.eq(again:feedData(1).seen[1], "u")
        again:deleteFeedData(1)
        T.eq(#again:feedData(1).items, 0, "a missing feed file gives empty data")
    end,
}
```

- [ ] **Step 3: Run them to make sure they fail**

Run: `lua tests/run.lua tests/test_store.lua`
Expected: an error that `src.store` was not found.

- [ ] **Step 4: Implement `src/store.lua`**

```lua
-- Bookmarks, history and feeds on the SD card (spec 6.6). fs and json are
-- passed in so tests can fake them.
local M = {}
M.__index = M
M.MAX_BOOKMARKS, M.MAX_HISTORY = 200, 100

function M.new(fs, json, dir)
    local s = setmetatable({ fs = fs, json = json, dir = dir, notes = {} }, M)
    fs.mkdir(dir)
    fs.mkdir(dir .. "/feeds")
    return s
end

function M:path(name)
    return self.dir .. "/" .. name
end

-- A missing file gives `default`. A save interrupted before its rename left
-- only <name>.tmp: that becomes the file. An unreadable file is renamed
-- <name>.bad and reported in self.notes.
function M:load(name, default)
    local fs, p = self.fs, self:path(name)
    if not fs.exists(p) and fs.exists(p .. ".tmp") then fs.rename(p .. ".tmp", p) end
    local text = fs.readFile(p)
    if text == nil then return default end
    local value = self.json.decode(text)
    if type(value) ~= "table" then
        fs.delete(p .. ".bad")
        fs.rename(p, p .. ".bad")
        self.notes[#self.notes + 1] = name .. " was unreadable; started empty"
        return default
    end
    return value
end

-- Writes <name>.tmp, deletes <name>, renames: the device's rename fails when
-- the destination exists, and a power cut leaves either the old file or the
-- .tmp that load() recovers.
function M:save(name, value)
    local fs, p = self.fs, self:path(name)
    local ok, text = pcall(self.json.encode, value)
    if not ok then return false end
    local f = fs.open(p .. ".tmp", "w")
    if not f then return false end
    local written = fs.write(f, text)
    fs.close(f)
    if written ~= #text then
        fs.delete(p .. ".tmp")
        return false
    end
    fs.delete(p)
    return fs.rename(p .. ".tmp", p) == true
end

local function indexOf(list, u)
    for i, v in ipairs(list) do
        if v.url == u then return i end
    end
    return nil
end

function M:bookmarks()
    if not self._bookmarks then self._bookmarks = self:load("bookmarks.json", {}) end
    return self._bookmarks
end

function M:isBookmarked(u)
    return indexOf(self:bookmarks(), u) ~= nil
end

-- Adds the page, or removes it when already bookmarked. Returns true when added.
function M:toggleBookmark(u, title)
    local list = self:bookmarks()
    local i = indexOf(list, u)
    if i then
        table.remove(list, i)
        self:save("bookmarks.json", list)
        return false
    end
    table.insert(list, 1, { url = u, title = title or u })
    while #list > M.MAX_BOOKMARKS do table.remove(list) end
    self:save("bookmarks.json", list)
    return true
end

function M:removeBookmark(i)
    table.remove(self:bookmarks(), i)
    self:save("bookmarks.json", self:bookmarks())
end

function M:history()
    if not self._history then self._history = self:load("history.json", {}) end
    return self._history
end

function M:addHistory(u, title)
    local list = self:history()
    local i = indexOf(list, u)
    if i then table.remove(list, i) end
    table.insert(list, 1, { url = u, title = title or u })
    while #list > M.MAX_HISTORY do table.remove(list) end
    self:save("history.json", list)
end

function M:removeHistory(i)
    table.remove(self:history(), i)
    self:save("history.json", self:history())
end

function M:feedIndex()
    if not self._feedIndex then self._feedIndex = self:load("feeds/index.json", { next_id = 1, feeds = {} }) end
    return self._feedIndex
end

function M:saveFeedIndex()
    return self:save("feeds/index.json", self:feedIndex())
end

function M:feedData(id)
    local data = self:load("feeds/" .. id .. ".json", nil) or {}
    data.items, data.seen = data.items or {}, data.seen or {}
    return data
end

function M:saveFeedData(id, data)
    return self:save("feeds/" .. id .. ".json", data)
end

function M:deleteFeedData(id)
    self.fs.delete(self:path("feeds/" .. id .. ".json"))
end

return M
```

- [ ] **Step 5: Run the tests to make sure they pass**

Run: `make test`
Expected: all tests pass under both Luas.

- [ ] **Step 6: Commit**

```bash
git add src/store.lua tests/fakes.lua tests/test_store.lua
git commit -m "feat(app): bookmarks, history and feed storage with safe writes"
```

---

### Task 8: Feed bookkeeping

**Files:**
- Create: `src/feeds.lua`
- Test: `tests/test_feeds.lua`

**Interfaces:**
- Consumes: the index and data shapes from `store` (Task 7); items from `gemtext.feedItems` (Task 2).
- Produces:
  - Constants: `feeds.MAX_FEEDS = 50`, `feeds.MAX_ITEMS = 50`, `feeds.STALE_SECONDS = 1800`.
  - `feeds.subscribe(index, url, title) -> feed, isNew | nil, message`. A new feed is `{id, url, title, fetched_at = 0, unread = 0, newest = ""}`.
  - `feeds.unsubscribe(index, id) -> bool`.
  - `feeds.unreadCount(data) -> integer`.
  - `feeds.merge(data, items) -> data`: keeps at most 50 items, with `date = ""` when undated, and prunes `seen`.
  - `feeds.summarize(feed, data, now?)`: sets `unread` and `newest`, and sets `fetched_at` only when `now` is given.
  - `feeds.markRead(data, url) -> changed` and `feeds.markAllRead(data)`.
  - `feeds.isStale(feed, now) -> bool`.
  - `feeds.sorted(index) -> list`: newest item first; undated feeds last, ordered by title.
  - `feeds.lines(feed, data) -> gemtext lines`: an h1, a blank line, then one link per item with label `"* "` (unread) or `"  "` (read), then the date and title. Read items have `dim = true`.

- [ ] **Step 1: Write the failing tests**

`tests/test_feeds.lua`:
```lua
local T = require("tests.t")
local feeds = require("src.feeds")

local function items(n, start)
    local out = {}
    for i = 1, n do out[i] = { url = "https://f.test/" .. (start or 0) + i, date = "2026-10-01", title = "T" .. i } end
    return out
end

return {
    subscribe_adds_once_and_respects_the_limit = function()
        local idx = { next_id = 1, feeds = {} }
        local f, new = feeds.subscribe(idx, "https://f.test/feed", "F")
        T.eq(new, true); T.eq(f.id, 1); T.eq(f.fetched_at, 0); T.eq(idx.next_id, 2)
        local again, isNew = feeds.subscribe(idx, "https://f.test/feed", "F")
        T.eq(again, f); T.eq(isNew, false)
        for i = 2, feeds.MAX_FEEDS do feeds.subscribe(idx, "https://f.test/" .. i, "F") end
        local none, msg = feeds.subscribe(idx, "https://f.test/full", "F")
        T.eq(none, nil); T.eq(msg, "Feed limit reached (50)")
        T.eq(feeds.unsubscribe(idx, 1), true)
        T.eq(feeds.unsubscribe(idx, 1), false)
    end,
    merge_caps_items_and_prunes_seen = function()
        local data = { items = {}, seen = { "https://f.test/1", "https://f.test/gone" } }
        local fetched = items(60)
        fetched[2].date = nil
        feeds.merge(data, fetched)
        T.eq(#data.items, feeds.MAX_ITEMS)
        T.eq(data.items[2].date, "")
        T.eq(#data.seen, 1)
        T.eq(data.seen[1], "https://f.test/1")
        T.eq(feeds.unreadCount(data), feeds.MAX_ITEMS - 1)
    end,
    mark_read_and_mark_all_read = function()
        local data = feeds.merge({ items = {}, seen = {} }, items(3))
        T.eq(feeds.markRead(data, "https://f.test/2"), true)
        T.eq(feeds.markRead(data, "https://f.test/2"), false, "already read")
        T.eq(feeds.markRead(data, "https://elsewhere.test/"), false, "not in this feed")
        T.eq(feeds.unreadCount(data), 2)
        feeds.markAllRead(data)
        T.eq(feeds.unreadCount(data), 0)
    end,
    summarize_counts_and_dates = function()
        local data = feeds.merge({ items = {}, seen = {} }, {
            { url = "a", date = "2026-10-12", title = "A" }, { url = "b", date = "2026-10-14", title = "B" },
            { url = "c", title = "C" },
        })
        local f = { fetched_at = 5 }
        feeds.summarize(f, data)
        T.eq(f.unread, 3); T.eq(f.newest, "2026-10-14"); T.eq(f.fetched_at, 5)
        feeds.summarize(f, data, 1792000000)
        T.eq(f.fetched_at, 1792000000)
    end,
    staleness = function()
        T.eq(feeds.isStale({ fetched_at = 0 }, 1792000000), true, "never fetched")
        T.eq(feeds.isStale({ fetched_at = 0 }, 0), true, "never fetched, clock not set")
        T.eq(feeds.isStale({ fetched_at = 1792000000 }, 1792001799), false)
        T.eq(feeds.isStale({ fetched_at = 1792000000 }, 1792001800), true)
        T.eq(feeds.isStale({ fetched_at = 1792000000 }, 0), false, "clock not set: keep what we have")
    end,
    sorted_newest_first_then_undated_by_title = function()
        local idx = { feeds = {
            { title = "beta", newest = "" }, { title = "Old", newest = "2026-01-01" },
            { title = "alpha", newest = "" }, { title = "New", newest = "2026-10-13" },
        } }
        local got = {}
        for i, f in ipairs(feeds.sorted(idx)) do got[i] = f.title end
        T.eq(table.concat(got, ","), "New,Old,alpha,beta")
        T.eq(idx.feeds[1].title, "beta", "the index itself is not reordered")
    end,
    lines_mark_unread_and_dim_read = function()
        local data = feeds.merge({ items = {}, seen = {} }, {
            { url = "https://f.test/1", date = "2026-10-13", title = "One" }, { url = "https://f.test/2", title = "Two" },
        })
        feeds.markRead(data, "https://f.test/2")
        local lines = feeds.lines({ title = "Blog" }, data)
        T.eq(lines[1].t, "h1"); T.eq(lines[1].text, "Blog")
        T.eq(lines[3].text, "* 2026-10-13 One"); T.eq(lines[3].dim, false)
        T.eq(lines[4].text, "  Two"); T.eq(lines[4].dim, true); T.eq(lines[4].url, "https://f.test/2")
        local empty = feeds.lines({ title = "E" }, { items = {}, seen = {} })
        T.eq(empty[3].t, "text")
    end,
}
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `lua tests/run.lua tests/test_feeds.lua`
Expected: an error that `src.feeds` was not found.

- [ ] **Step 3: Implement `src/feeds.lua`**

```lua
-- Feed bookkeeping (spec 6.7). Pure: works on the tables store.lua loads and saves.
local M = {}
M.MAX_FEEDS, M.MAX_ITEMS, M.STALE_SECONDS = 50, 50, 1800

function M.subscribe(index, u, title)
    for _, f in ipairs(index.feeds) do
        if f.url == u then return f, false end
    end
    if #index.feeds >= M.MAX_FEEDS then return nil, "Feed limit reached (" .. M.MAX_FEEDS .. ")" end
    local f = { id = index.next_id, url = u, title = title or u, fetched_at = 0, unread = 0, newest = "" }
    index.next_id = index.next_id + 1
    index.feeds[#index.feeds + 1] = f
    return f, true
end

function M.unsubscribe(index, id)
    for i, f in ipairs(index.feeds) do
        if f.id == id then
            table.remove(index.feeds, i)
            return true
        end
    end
    return false
end

local function seenSet(data)
    local set = {}
    for _, u in ipairs(data.seen) do set[u] = true end
    return set
end

function M.unreadCount(data)
    local set, n = seenSet(data), 0
    for _, it in ipairs(data.items) do
        if not set[it.url] then n = n + 1 end
    end
    return n
end

-- Replaces the items with the freshly fetched ones and forgets read marks for
-- items no longer listed, so `seen` never grows past MAX_ITEMS.
function M.merge(data, items)
    local kept, present = {}, {}
    for i = 1, math.min(#items, M.MAX_ITEMS) do
        local it = items[i]
        kept[i] = { url = it.url, date = it.date or "", title = it.title }
        present[it.url] = true
    end
    local seen = {}
    for _, u in ipairs(data.seen) do
        if present[u] then seen[#seen + 1] = u end
    end
    data.items, data.seen = kept, seen
    return data
end

function M.summarize(feed, data, now)
    feed.unread = M.unreadCount(data)
    local newest = ""
    for _, it in ipairs(data.items) do
        if it.date > newest then newest = it.date end
    end
    feed.newest = newest
    if now then feed.fetched_at = now end
end

function M.markRead(data, u)
    for _, s in ipairs(data.seen) do
        if s == u then return false end
    end
    for _, it in ipairs(data.items) do
        if it.url == u then
            data.seen[#data.seen + 1] = u
            return true
        end
    end
    return false
end

function M.markAllRead(data)
    local seen = {}
    for i, it in ipairs(data.items) do seen[i] = it.url end
    data.seen = seen
end

-- A feed never fetched is stale. Without the clock (now = 0) nothing else is,
-- so opening a feed offline shows what is stored.
function M.isStale(feed, now)
    local at = feed.fetched_at or 0
    if at <= 0 then return true end
    if not now or now <= 0 then return false end
    return now - at >= M.STALE_SECONDS
end

function M.sorted(index)
    local list = {}
    for i, f in ipairs(index.feeds) do list[i] = f end
    table.sort(list, function(a, b)
        if a.newest ~= b.newest then return a.newest > b.newest end
        return a.title:lower() < b.title:lower()
    end)
    return list
end

function M.lines(feed, data)
    local set = seenSet(data)
    local lines = { { t = "h1", text = feed.title }, { t = "blank", text = "" } }
    if #data.items == 0 then
        lines[#lines + 1] = { t = "text", text = "No articles yet. F5 on the Feeds tab refreshes." }
    end
    for _, it in ipairs(data.items) do
        local read = set[it.url] == true
        local label = (read and "  " or "* ") .. (it.date ~= "" and (it.date .. " ") or "") .. it.title
        lines[#lines + 1] = { t = "link", url = it.url, text = label, dim = read }
    end
    return lines
end

return M
```

- [ ] **Step 4: Run the tests to make sure they pass**

Run: `make test`
Expected: all tests pass under both Luas.

- [ ] **Step 5: Commit**

```bash
git add src/feeds.lua tests/test_feeds.lua
git commit -m "feat(app): feed subscriptions, unread tracking and staleness"
```

---

### Task 9: The fake platform and the HTTP transport

**Files:**
- Create: `tests/fakepc.lua`, `src/http.lua`
- Test: `tests/test_http.lua`

**Interfaces:**
- Consumes: `tests/fakes.lua` (Task 7).
- Produces:
  - `http.pool(net, base) -> pool`, where `net` is `picocalc.network` and `base` is `{host, port, tls}`.
    - `pool:get(path, headers, done) -> handle | nil, "busy"`.
      - `done(ok, status, bodyOrError, headers)` runs exactly once unless cancelled.
      - The handle has `handle.cancel()` and `handle.received() -> bytes`.
    - `pool:closeAll()`.
    - Constants: `http.MAX_BODY = 512 * 1024`, `http.MAX_ACTIVE = 2`, `http.CONNECT_TIMEOUT = 15`, `http.READ_TIMEOUT = 20`.
    - Idle keep-alive connections are reused. A reused connection that fails before receiving any bytes is retried once on a fresh connection.
  - `fakepc.new() -> F`, where `F.pc` is a fake `picocalc` with `display`, `ui`, `input`, `sys`, `network`, `fs`, `json`, `config` and `graphics`. It records:
    - `F.texts`: the strings drawn since the last `display.clear`, including `[H] title` for headers, `[F] left | right` for footers, `[T*] tab` and `[T] tab` for tabs, and `[>] text` and `[ ] text` for list items. `F.screenText()` joins them with newlines.
    - `F.logs` (from `sys.log`), `F.toasts`, `F.menu` (label → fn), `F.requests` (`{path, headers}`), `F.config` (key → string) and `F.files`.
    - `F.conns`: connections created.
  - Scripting the fake:
    - `F.events`: push events directly, or with `F.press(name [, mods])` and `F.type(chars)`.
    - `F.inputs`: the values `ui.textInput` returns in order; `false` or an empty queue means Esc.
    - `F.confirms`: the values `ui.confirm` returns; the default is `true`.
    - `F.responder(path, headers) -> status, headers, body` serves requests. `-> nil, errorText` simulates a transport failure.
    - `F.holding = true` delays delivery.
    - `F.netStatus` (default 1), `F.synced` (default true), `F.epoch` (default 1792000000), `F.ms` (advanced by `sys.sleep`), `F.poolFull`.
  - `F.service()` delivers pending requests. `input.update`, `sys.sleep` and `display.flush` call it.
  - Helpers: `F.hasLog(text)`, `F.hasToast(text)` (plain substring).
  - `fakepc.proxy(routes, token) -> responder`, which answers `/v1/ping` and `/v1/get` like the real proxy.
    - Routes are keyed `"<url>|<as>"` or `"<url>"`. A route is `{body, status?, type?, title?, mode? (false omits X-Mode), final?, feed?, truncated?}`.
    - A wrong token gives 401. An unknown URL gives `502 "Site returned 404 Not Found"`.

- [ ] **Step 1: Write the fake platform**

`tests/fakepc.lua`:
```lua
-- A fake `picocalc` for host tests of the app: records drawing, scripts input,
-- serves HTTP from a responder function, and keeps files in memory.
local fakes = require("tests.fakes")

local M = {}

local BTN = {
    UP = 1, DOWN = 2, LEFT = 4, RIGHT = 8, ENTER = 16, ESC = 32, MENU = 64,
    F1 = 128, F2 = 256, F3 = 512, F4 = 1024, F5 = 2048, F6 = 4096, F7 = 8192, F8 = 16384, F9 = 32768,
    BACKSPACE = 65536, TAB = 131072, DEL = 262144, SHIFT = 524288, CTRL = 1048576, ALT = 2097152, FN = 4194304,
}
local KEYCODE = {
    up = 0xB5, down = 0xB6, left = 0xB4, right = 0xB7, enter = 0x0A, esc = 0xB1, backspace = 0x08,
    tab = 0x09, del = 0xD4, f1 = 0x81, f2 = 0x82, f3 = 0x83, f4 = 0x84, f5 = 0x85,
}

function M.new()
    local F = {
        texts = {}, logs = {}, toasts = {}, menu = {}, events = {}, inputs = {}, confirms = {},
        requests = {}, pending = {}, config = {}, conns = 0,
        netStatus = 1, synced = true, epoch = 1792000000, ms = 0,
    }
    local fs, files = fakes.fs()
    F.files = files
    F.responder = function() return 404, {}, "no responder" end

    function F.service()
        if F.holding then return end
        local pending = F.pending
        F.pending = {}
        for _, p in ipairs(pending) do
            local c = p.conn
            if not c.released then
                local status, headers, body = F.responder(p.path, p.headers)
                if status == nil then
                    c.err, c.released = headers or "connection failed", true
                    if c.cb.closed then c.cb.closed() end
                else
                    c.status, c.headers, c.body, c.pos = status, headers or {}, body or "", 1
                    if c.cb.req then c.cb.req() end
                    if c.cb.done then c.cb.done() end
                end
            end
        end
    end

    local display = {
        BLACK = 0, WHITE = 0xFFFF, GRAY = 0x8410, RED = 0xF800, GREEN = 0x07E0, BLUE = 0x001F,
        YELLOW = 0xFFE0, CYAN = 0x07FF,
        FONT_6X8 = 0, FONT_8X12 = 1, FONT_SCIENTIFICA = 2, FONT_SCIENTIFICA_BOLD = 3,
    }
    function display.rgb(r, g, b) return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3) end
    function display.clear() F.texts = {} end
    function display.setFont() end
    function display.fillRect() end
    function display.drawText(_, _, t) F.texts[#F.texts + 1] = t; return #t * 6 end
    function display.flush() F.frames = (F.frames or 0) + 1; F.service() end

    local ui = { TOAST_INFO = 0, TOAST_SUCCESS = 1, TOAST_WARNING = 2, TOAST_ERROR = 3 }
    function ui.drawHeader(t) F.texts[#F.texts + 1] = "[H] " .. t; return 21 end
    function ui.drawFooter(l, r) F.texts[#F.texts + 1] = "[F] " .. (l or "") .. " | " .. (r or "") end
    function ui.drawTabs(_, tabs, active)
        for i, t in ipairs(tabs) do F.texts[#F.texts + 1] = (i == active and "[T*] " or "[T] ") .. t end
        return active, 21
    end
    function ui.drawListItem(_, _, _, text, selected) F.texts[#F.texts + 1] = (selected and "[>] " or "[ ] ") .. text end
    function ui.drawSpinner() end
    function ui.textInput(prompt) F.lastPrompt = prompt; return table.remove(F.inputs, 1) or nil end
    function ui.confirm(msg)
        F.lastConfirm = msg
        local v = table.remove(F.confirms, 1)
        if v == nil then return true end
        return v
    end
    function ui.toast(text) F.toasts[#F.toasts + 1] = text end

    local input = {}
    for name, v in pairs(BTN) do input["BTN_" .. name] = v end
    function input.update() F.service() end
    function input.pollEvent() return table.remove(F.events, 1) end
    function input.clearState() end

    local sys = {}
    function sys.log(m) F.logs[#F.logs + 1] = m end
    function sys.getTimeMs() return F.ms end
    function sys.getClock() return { synced = F.synced, epoch = F.synced and F.epoch or 0, hour = 0, min = 0, sec = 0 } end
    function sys.sleep(ms) F.ms = F.ms + ms; F.service() end
    function sys.addMenuItem(label, fn) F.menu[label] = fn end

    local network = { kStatusNotConnected = 0, kStatusConnected = 1, kStatusNotAvailable = 2, http = {} }
    function network.getStatus() return F.netStatus end
    function network.http.new(host, port, tls)
        if F.poolFull then return nil, "HTTP connection pool full or out of memory" end
        F.conns = F.conns + 1
        local c = { host = host, port = port, tls = tls, cb = {}, released = false }
        function c:setKeepAlive(v) self.keep = v end
        function c:setConnectTimeout() end
        function c:setReadTimeout() end
        function c:setReadBufferSize() return true end
        function c:setRequestCallback(fn) self.cb.req = fn end
        function c:setRequestCompleteCallback(fn) self.cb.done = fn end
        function c:setConnectionClosedCallback(fn) self.cb.closed = fn end
        function c:get(path, headers)
            if self.released then error("http: connection is closed") end
            F.requests[#F.requests + 1] = { path = path, headers = headers }
            F.pending[#F.pending + 1] = { conn = self, path = path, headers = headers }
            return true
        end
        function c:getBytesAvailable() return self.body and (#self.body - self.pos + 1) or 0 end
        function c:read(n)
            if not self.body or self.pos > #self.body then return nil end
            local s = self.body:sub(self.pos, self.pos + (n or 131072) - 1)
            self.pos = self.pos + #s
            return s
        end
        function c:getResponseStatus() return self.status end
        function c:getResponseHeaders() return self.headers end
        function c:getError() return self.err end
        function c:close() self.released = true end
        return c
    end

    local config = {}
    function config.get(k, d)
        local v = F.config[k]
        if v == nil then return d end
        return v
    end
    function config.set(k, v)
        if v == nil or v == "" then F.config[k] = nil else F.config[k] = v end
    end
    function config.save() return true end

    local graphics = { image = {} }
    function graphics.image.loadFromBuffer(data)
        if data:sub(1, 4) ~= "JPEG" then error("JPEG decoding failed") end
        local img = {}
        function img:getSize() return 200, 120 end
        function img:draw() end
        return img
    end

    F.pc = {
        display = display, ui = ui, input = input, sys = sys, network = network,
        fs = fs, json = fakes.json(), config = config, graphics = graphics,
    }

    function F.press(name, mods)
        local button = name:upper()
        F.events[#F.events + 1] = { type = "down", key = KEYCODE[name], button = BTN[button], mods = mods or 0 }
    end
    function F.type(chars)
        for c in chars:gmatch(".") do
            F.events[#F.events + 1] = { type = "char", key = c:byte(), char = c, mods = 0 }
        end
    end
    function F.screenText() return table.concat(F.texts, "\n") end
    local function has(list, text)
        for _, v in ipairs(list) do
            if v:find(text, 1, true) then return true end
        end
        return false
    end
    function F.hasLog(text) return has(F.logs, text) end
    function F.hasToast(text) return has(F.toasts, text) end
    return F
end

-- A responder that behaves like the PicoSurf proxy for the given routes.
function M.proxy(routes, token)
    local plain = { ["content-type"] = "text/plain; charset=us-ascii" }
    return function(path, headers)
        if (headers or {}).Authorization ~= "Bearer " .. (token or "tok") then
            return 401, plain, "Missing or wrong token\n"
        end
        if path:find("/v1/ping", 1, true) then return 200, plain, "picosurf-proxy 1\n" end
        local enc = path:match("[?&]url=([^&]*)")
        local target = enc and (enc:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) or ""
        local as = path:match("[?&]as=([^&]*)") or "reader"
        local r = routes[target .. "|" .. as] or routes[target]
        if not r then
            return 502, { ["content-type"] = plain["content-type"], ["x-upstream-status"] = "404" }, "Site returned 404 Not Found\n"
        end
        local h = { ["content-type"] = r.type or "text/gemini; charset=us-ascii", ["x-final-url"] = r.final or target }
        if r.mode ~= false then h["x-mode"] = r.mode or as end
        if r.title then h["x-title"] = r.title end
        if r.feed then h["x-feed-url"] = r.feed end
        if r.truncated then h["x-truncated"] = "1" end
        return r.status or 200, h, r.body
    end
end

return M
```

- [ ] **Step 2: Write the failing transport tests**

`tests/test_http.lua`:
```lua
local T = require("tests.t")
local fakepc = require("tests.fakepc")
local http = require("src.http")

local BASE = { host = "p.test", port = 443, tls = true }

local function setup(responder)
    local F = fakepc.new()
    F.responder = responder
    return F, http.pool(F.pc.network, BASE)
end

local function ok200(body)
    return function() return 200, { ["content-type"] = "text/gemini" }, body or "hello" end
end

return {
    delivers_status_body_and_headers = function()
        local F, pool = setup(ok200("hello"))
        local got
        local h = pool:get("/v1/ping", { Authorization = "Bearer t" }, function(...) got = table.pack(...) end)
        F.service()
        T.eq(got[1], true); T.eq(got[2], 200); T.eq(got[3], "hello"); T.eq(got[4]["content-type"], "text/gemini")
        T.eq(F.requests[1].path, "/v1/ping"); T.eq(F.requests[1].headers.Authorization, "Bearer t")
        T.eq(h.received(), 5)
    end,
    reuses_an_idle_connection = function()
        local F, pool = setup(ok200())
        pool:get("/a", {}, function() end); F.service()
        pool:get("/b", {}, function() end); F.service()
        T.eq(F.conns, 1)
    end,
    retries_once_when_a_reused_connection_fails_before_any_data = function()
        local calls = 0
        local F, pool = setup(function()
            calls = calls + 1
            if calls == 2 then return nil, "connection closed before the response headers" end
            return 200, {}, "body " .. calls
        end)
        pool:get("/a", {}, function() end); F.service()
        local got
        pool:get("/b", {}, function(...) got = table.pack(...) end)
        F.service(); F.service()
        T.eq(got[1], true); T.eq(got[3], "body 3")
        T.eq(F.conns, 2)
    end,
    reports_transport_failures = function()
        local F, pool = setup(function() return nil, "connect timeout (15000ms)" end)
        local got
        pool:get("/a", {}, function(...) got = table.pack(...) end)
        F.service()
        T.eq(got[1], false); T.eq(got[3], "connect timeout (15000ms)")
        T.eq(pool.active, 0)
    end,
    refuses_bodies_over_512_kb = function()
        local F, pool = setup(ok200(string.rep("x", 600 * 1024)))
        local got
        pool:get("/a", {}, function(...) got = table.pack(...) end)
        F.service()
        T.eq(got[1], false); T.eq(got[3], "Page too large (over 512 KB)")
        T.eq(pool.active, 0); T.eq(#pool.idle, 0)
    end,
    cancelled_requests_never_call_back = function()
        local F, pool = setup(ok200())
        local called = false
        local h = pool:get("/a", {}, function() called = true end)
        h.cancel()
        F.service()
        T.eq(called, false); T.eq(pool.active, 0)
    end,
    allows_two_requests_at_a_time = function()
        local _, pool = setup(ok200())
        T.ok(pool:get("/a", {}, function() end))
        T.ok(pool:get("/b", {}, function() end))
        local h, err = pool:get("/c", {}, function() end)
        T.eq(h, nil); T.eq(err, "busy")
    end,
    reports_when_no_connection_can_be_made = function()
        local F, pool = setup(ok200())
        F.poolFull = true
        local got
        local h = pool:get("/a", {}, function(...) got = table.pack(...) end)
        T.ok(h, "a handle is still returned")
        T.eq(got[1], false); T.eq(got[3], "HTTP connection pool full or out of memory")
        T.eq(pool.active, 0)
    end,
}
```

- [ ] **Step 3: Run them to make sure they fail**

Run: `lua tests/run.lua tests/test_http.lua`
Expected: an error that `src.http` was not found.

- [ ] **Step 4: Implement `src/http.lua`**

```lua
-- HTTP transport to the proxy (spec 6.1): keep-alive connections, body
-- draining, a 512 KB cap and cancellation. The firmware runs the callbacks
-- inside its service pass, between any two Lua statements, so callers must
-- only record results in `done`.
local M = {}
M.MAX_BODY = 512 * 1024
M.MAX_ACTIVE = 2
M.CONNECT_TIMEOUT, M.READ_TIMEOUT = 15, 20
local READ_CHUNK = 16384

local Pool = {}
Pool.__index = Pool

-- net: picocalc.network; base: {host, port, tls} from url.parseBase.
function M.pool(net, base)
    return setmetatable({ net = net, base = base, idle = {}, active = 0 }, Pool)
end

local function connect(self)
    local conn, err = self.net.http.new(self.base.host, self.base.port, self.base.tls)
    if not conn then return nil, err end
    conn:setKeepAlive(true)
    conn:setConnectTimeout(M.CONNECT_TIMEOUT)
    conn:setReadTimeout(M.READ_TIMEOUT)
    if not conn:setReadBufferSize(65536) then conn:setReadBufferSize(32768) end
    return conn
end

-- GET path. done(ok, status, bodyOrError, headers) runs exactly once unless
-- the request is cancelled. Returns a handle {cancel(), received()}, or nil and
-- "busy" when MAX_ACTIVE requests are running.
function Pool:get(path, headers, done)
    if self.active >= M.MAX_ACTIVE then return nil, "busy" end
    self.active = self.active + 1
    local handle = {}
    local state = { finished = false, total = 0 }
    self:send(path, headers, done, handle, state, true)
    return handle
end

function Pool:send(path, headers, done, handle, state, mayRetry)
    local pool = self
    local conn = table.remove(self.idle)
    local reused = conn ~= nil
    if not conn then
        local err
        conn, err = connect(self)
        if not conn then
            state.finished = true
            pool.active = pool.active - 1
            done(false, nil, err or "No connection available")
            return
        end
    end
    local parts, n = {}, 0

    local function finish(keep)
        state.finished = true
        pool.active = pool.active - 1
        if keep then pool.idle[#pool.idle + 1] = conn else conn:close() end
    end

    local function drain()
        while not state.finished and conn:getBytesAvailable() > 0 do
            local d = conn:read(READ_CHUNK)
            if not d then break end
            state.total = state.total + #d
            if state.total > M.MAX_BODY then
                finish(false)
                done(false, nil, "Page too large (over 512 KB)")
                return
            end
            n = n + 1
            parts[n] = d
        end
    end

    conn:setRequestCallback(drain)
    conn:setRequestCompleteCallback(function()
        if state.finished then return end
        drain()
        if state.finished then return end
        local status, hdrs = conn:getResponseStatus(), conn:getResponseHeaders()
        finish(true)
        done(true, status, table.concat(parts), hdrs or {})
    end)
    conn:setConnectionClosedCallback(function()
        if state.finished then return end
        -- The firmware has released the connection. A kept-alive connection the
        -- server closed while idle fails before any data: try once more, fresh.
        if reused and mayRetry and state.total == 0 then
            return pool:send(path, headers, done, handle, state, false)
        end
        state.finished = true
        pool.active = pool.active - 1
        done(false, nil, conn:getError() or "Connection closed")
    end)

    handle.cancel = function()
        if not state.finished then finish(false) end
    end
    handle.received = function() return state.total end

    local ok, sent, err = pcall(conn.get, conn, path, headers)
    if ok and sent then return end
    if not ok and reused and mayRetry then
        -- get() raises on a connection the firmware already released.
        return pool:send(path, headers, done, handle, state, false)
    end
    finish(false)
    done(false, nil, (ok and err) or "Request failed")
end

function Pool:closeAll()
    for _, c in ipairs(self.idle) do c:close() end
    self.idle = {}
end

return M
```

- [ ] **Step 5: Run the tests to make sure they pass**

Run: `make test`
Expected: all tests pass under both Luas.

- [ ] **Step 6: Commit**

```bash
git add tests/fakepc.lua src/http.lua tests/test_http.lua
git commit -m "feat(app): HTTP transport to the proxy, and a fake picocalc for tests"
```

---

### Task 10: The app: browsing, settings and images

**Files:**
- Create: `src/theme.lua`, `src/app.lua`, `main.lua`
- Create the screens: `src/screens/home.lua`, `src/screens/page.lua`, `src/screens/image.lua`, `src/screens/loading.lua`, `src/screens/message.lua`, `src/screens/settings.lua`
- Test: `tests/test_app.lua`

**Interfaces:**
- Consumes: everything from Tasks 1–9.
- Produces:
  - `theme.new(disp, fontName) -> th`, with fields:
    - fonts: `font`, `bold`
    - geometry: `cw`, `rowH = 13`, `top = 21`, `bottom = 302`, `margin = 4`
    - colours: `bg`, `fg`, `dim`, `h1`, `h2`, `h3`, `link`, `image`, `read`, `selBg`, `quote`, `pre`, `bar`, `error`
  - `theme.cols(th)` and `theme.rows(th)`.
  - `App.new(pc, appId) -> app`, with `app:start()`, `app:step()` and `app:run()`.
  - App methods used by screens:
    - setup and output: `log(...)`, `toast(text, style)`, `show(name, args)`, `saveConfig(key, value)`, `relayout()`
    - network: `request(target, as, done) -> handle | nil, message`, `ping()`
    - navigation: `open(target, opts)`, `showResult(target, mode, r, opts)`, `fail(message, retry)`, `goBack()`, `goHome()`, `followLink(link)`, `promptGo(default)`
    - page actions: `toggleBookmark()`, `toggleMode()`, `reload()`, `editUrl()`
  - App fields:
    - `pc`, `disp`, `ui`, `input`, `sys`, `store`, `cfg = {proxyUrl, token, font}`, `theme`
    - `base`, `baseErr`, `pool`
    - `screen`, `screenName`, `page`, `back`, `cache`, `quit`, `dirty`
  - The page table: `{url, want, mode, title, feedUrl, lines, L, ps}`. Task 11 adds `isFeedList` and `feedId` for feed lists.
  - Each screen is a module `{enter?(app, args), update?(app), draw(app), key?(app, action, arg)}`.
  - Log lines (`picosurf: ` followed by):
    - `screen <name>`
    - `loaded <url> mode=<m> links=<n> rows=<n>`
    - `follow <url>`
    - `error <status|-> <message>`
    - `bookmark add|remove <url>`
    - `image w=<w> h=<h>`
    - `cancelled <url>`
    - `tab <name>`
    - `prompt go`, logged just before the F1 text box opens
    - `ping ok` and `ping failed <message>`
  - System menu items: `Reload`, `Edit URL`, `Settings`.

- [ ] **Step 1: Write the failing app tests**

`tests/test_app.lua`:
```lua
local T = require("tests.t")
local fakepc = require("tests.fakepc")
local App = require("src.app")

local A = "# A\n\nSee the docs [1] and more [2].\n=> https://b.test/ [1] the docs\n=> gemini://g.test/ [2] more\n=> https://a.test/cat.jpg [IMG] Cat\n"
local function longBody()
    local parts = { "# Long" }
    for i = 1, 100 do parts[#parts + 1] = "line " .. i end
    return table.concat(parts, "\n")
end
local ROUTES = {
    ["https://a.test/"] = { title = "A", body = A },
    ["https://b.test/"] = { title = "B", body = "# B\n\nBack page.\n" },
    ["https://a.test/cat.jpg"] = { type = "image/jpeg", mode = false, body = "JPEG-DATA" },
    ["https://a.test/bad.jpg"] = { type = "image/jpeg", mode = false, body = "nope" },
    ["https://long.test/"] = { title = "Long", body = longBody() },
    ["https://cut.test/"] = { title = "Cut", body = "# Cut\n", truncated = true },
    ["https://plain.test/"] = { type = "text/plain; charset=us-ascii", mode = false, body = "just text\n" },
}

local function boot(opts)
    opts = opts or {}
    local F = fakepc.new()
    if opts.config ~= false then
        F.config.proxy_url = opts.proxy or "https://p.test"
        F.config.token = "tok"
    end
    F.responder = fakepc.proxy(ROUTES, opts.token or "tok")
    local app = App.new(F.pc, "net.picodeck.picosurf")
    app:start()
    app:step()
    return app, F
end

local function steps(app, n)
    for _ = 1, n or 3 do app:step() end
end

local function go(app, F, text)
    F.inputs[#F.inputs + 1] = text
    F.press("f1")
    steps(app)
end

return {
    first_run_opens_settings = function()
        local app, F = boot({ config = false })
        T.eq(app.screenName, "settings")
        T.ok(F.screenText():find("PicoSurf proxy", 1, true))
        T.ok(F.hasLog("picosurf: screen settings"))
    end,
    settings_save_url_and_token_and_warn_on_http = function() -- Review Focus 5
        local app, F = boot({ config = false })
        F.inputs = { "http://192.168.1.5:8080/x/" }
        F.press("enter"); steps(app, 1)
        T.eq(F.config.proxy_url, "http://192.168.1.5:8080/x/")
        T.eq(app.base.port, 8080); T.eq(app.base.prefix, "/x")
        T.ok(F.screenText():find("Warning: http:// sends the token unencrypted.", 1, true))
        F.inputs = { "tok" }
        F.press("down"); F.press("enter"); steps(app, 1)
        T.eq(F.config.token, "tok")
        F.press("esc"); steps(app, 1)
        T.eq(app.screenName, "home")
    end,
    test_connection_reports_ok_and_token_errors = function()
        local app, F = boot()
        F.menu["Settings"](); steps(app, 1)
        F.press("down"); F.press("down"); F.press("down"); F.press("enter"); steps(app)
        T.ok(F.hasToast("Proxy OK")); T.ok(F.hasLog("picosurf: ping ok"))
        local app2, F2 = boot({ token = "other" })
        F2.menu["Settings"](); steps(app2, 1)
        F2.press("down"); F2.press("down"); F2.press("down"); F2.press("enter"); steps(app2)
        T.ok(F2.hasToast("Proxy rejected the token - check Settings"))
    end,
    font_setting_switches_to_8x12 = function()
        local app, F = boot()
        F.menu["Settings"](); steps(app, 1)
        F.press("down"); F.press("down"); F.press("enter"); steps(app, 1)
        T.eq(F.config.font, "8x12"); T.eq(app.theme.cw, 8)
    end,
    opens_a_typed_url = function()
        local app, F = boot()
        go(app, F, "a.test/")
        T.eq(app.screenName, "page")
        T.ok(F.hasLog("picosurf: loaded https://a.test/ mode=reader links=3"))
        T.ok(F.screenText():find("[H] A", 1, true))
        T.eq(app.store:history()[1].url, "https://a.test/")
    end,
    refuses_text_with_spaces = function()
        local app, F = boot()
        go(app, F, "two words")
        T.ok(F.hasToast("Not a URL (search isn't supported yet)"))
        T.eq(app.screenName, "home")
    end,
    follows_the_selected_link_and_comes_back_from_the_cache = function()
        local app, F = boot()
        go(app, F, "a.test/")
        F.press("tab"); steps(app, 1)
        T.eq(app.page.ps.sel, 1)
        F.press("enter"); steps(app)
        T.ok(F.hasLog("picosurf: follow https://b.test/"))
        T.eq(app.page.url, "https://b.test/")
        local before = #F.requests
        F.press("backspace"); steps(app)
        T.eq(app.page.url, "https://a.test/")
        T.eq(#F.requests, before, "back used the cache")
        T.eq(app.page.ps.sel, 1, "selection restored")
        F.press("esc"); steps(app, 1)
        T.eq(app.screenName, "home", "Esc on the first page goes home")
    end,
    opens_links_by_number = function()
        local app, F = boot()
        go(app, F, "a.test/")
        F.type("1"); steps(app, 1)
        T.ok(F.screenText():find("Link: 1_", 1, true))
        F.press("enter"); steps(app)
        T.eq(app.page.url, "https://b.test/")
    end,
    an_unknown_link_number_shows_a_toast = function() -- Review Focus 4
        local app, F = boot()
        go(app, F, "a.test/")
        F.type("9"); F.press("enter"); steps(app, 1)
        T.ok(F.hasToast("No link [9] on this page"))
        T.eq(app.page.url, "https://a.test/")
        F.type("12"); F.press("backspace"); steps(app, 1)
        T.eq(app.page.ps.digits, "1")
        F.press("esc"); steps(app, 1)
        T.eq(app.page.ps.digits, ""); T.eq(app.screenName, "page", "Esc first clears the number")
    end,
    other_schemes_show_a_toast = function()
        local app, F = boot()
        go(app, F, "a.test/")
        F.type("2"); F.press("enter"); steps(app, 1)
        T.ok(F.hasToast("gemini:// links aren't supported yet"))
        T.eq(app.screenName, "page")
    end,
    opens_and_closes_an_image = function()
        local app, F = boot()
        go(app, F, "a.test/")
        F.press("tab"); F.press("tab"); F.press("tab"); F.press("enter"); steps(app)
        T.eq(app.screenName, "image")
        T.ok(F.hasLog("picosurf: image w=200 h=120"))
        F.press("esc"); steps(app, 1)
        T.eq(app.screenName, "page"); T.eq(app.page.url, "https://a.test/")
    end,
    an_undecodable_image_shows_an_error = function()
        local app, F = boot()
        go(app, F, "a.test/bad.jpg")
        T.eq(app.screenName, "message")
        T.ok(F.screenText():find("Could not decode the image", 1, true))
    end,
    esc_cancels_loading_and_ignores_the_late_answer = function() -- Review Focus 2
        local app, F = boot()
        F.holding = true
        go(app, F, "b.test/")
        T.eq(app.screenName, "loading")
        F.press("esc"); steps(app, 1)
        T.eq(app.screenName, "home")
        T.ok(F.hasLog("picosurf: cancelled https://b.test/"))
        F.holding = false
        steps(app)
        T.eq(app.screenName, "home")
        T.ok(not F.hasLog("loaded https://b.test/"))
    end,
    proxy_errors_show_a_message_that_can_retry = function()
        local app, F = boot()
        go(app, F, "missing.test/")
        T.eq(app.screenName, "message")
        T.ok(F.screenText():find("Site returned 404 Not Found", 1, true))
        T.ok(F.hasLog("picosurf: error 502 Site returned 404 Not Found"))
        local before = #F.requests
        F.press("enter"); steps(app)
        T.eq(#F.requests, before + 1)
        F.press("esc"); steps(app, 1)
        T.eq(app.screenName, "home")
    end,
    a_wrong_token_says_so = function()
        local app, F = boot({ token = "other" })
        go(app, F, "a.test/")
        T.ok(F.screenText():find("Proxy rejected the token - check Settings", 1, true))
    end,
    waits_for_the_clock_before_tls = function()
        local app, F = boot()
        F.synced = false
        go(app, F, "a.test/")
        T.eq(app.screenName, "loading")
        T.ok(F.screenText():find("Waiting for time sync...", 1, true))
        T.eq(#F.requests, 0)
        F.synced = true
        F.ms = F.ms + 3000
        steps(app)
        T.eq(app.screenName, "page")
    end,
    waits_for_wifi_and_reports_missing_wifi = function()
        local app, F = boot()
        F.netStatus = 0
        go(app, F, "a.test/")
        T.ok(F.screenText():find("Connecting to WiFi...", 1, true))
        F.netStatus = 1
        steps(app)
        T.eq(app.screenName, "page")
        local app2, F2 = boot()
        F2.netStatus = 2
        go(app2, F2, "a.test/")
        T.ok(F2.screenText():find("WiFi not available", 1, true))
    end,
    bookmarks_toggle_and_list_on_home = function()
        local app, F = boot()
        go(app, F, "a.test/")
        F.press("f3"); steps(app, 1)
        T.ok(F.hasToast("Bookmarked")); T.ok(app.store:isBookmarked("https://a.test/"))
        T.ok(F.hasLog("picosurf: bookmark add https://a.test/"))
        F.press("f2"); steps(app, 1)
        T.eq(app.screenName, "home")
        T.ok(F.screenText():find("[>] A", 1, true))
        F.press("enter"); steps(app)
        T.eq(app.page.url, "https://a.test/")
        F.press("f3"); steps(app, 1)
        T.ok(F.hasToast("Bookmark removed"))
    end,
    home_tabs_history_and_delete = function()
        local app, F = boot()
        go(app, F, "a.test/")
        F.press("f2"); F.press("right"); steps(app, 1)
        T.ok(F.hasLog("picosurf: tab History"))
        T.ok(F.screenText():find("[>] A", 1, true))
        F.press("del"); steps(app, 1)
        T.eq(#app.store:history(), 0)
        F.press("esc"); steps(app, 1)
        T.eq(app.quit, true)
    end,
    f4_switches_reader_and_full = function()
        local app, F = boot()
        go(app, F, "a.test/")
        F.press("f4"); steps(app)
        T.ok(F.requests[#F.requests].path:find("as=full", 1, true))
        T.eq(app.page.mode, "full")
        T.ok(F.screenText():find("% F", 1, true))
    end,
    menu_reload_and_edit_url = function()
        local app, F = boot()
        go(app, F, "a.test/")
        local before = #F.requests
        F.menu["Reload"](); steps(app)
        T.eq(#F.requests, before + 1, "reload skips the cache")
        T.eq(app.page.url, "https://a.test/")
        F.inputs = { "b.test/" }
        F.menu["Edit URL"](); steps(app)
        T.eq(app.page.url, "https://b.test/")
    end,
    scrolls_and_shows_the_position = function()
        local app, F = boot()
        go(app, F, "long.test/")
        F.press("down"); steps(app, 1)
        T.eq(app.page.ps.top, 2)
        F.press("right"); steps(app, 1)
        T.eq(app.page.ps.top, 22)
        F.press("left"); F.type(" "); steps(app, 1)
        T.eq(app.page.ps.top, 22)
        T.ok(F.screenText():find("% R", 1, true))
    end,
    warns_about_truncated_pages_and_shows_plain_text = function()
        local app, F = boot()
        go(app, F, "cut.test/")
        T.ok(F.hasToast("Page truncated by the proxy"))
        go(app, F, "plain.test/")
        T.eq(app.page.mode, "full")
        T.ok(F.screenText():find("just text", 1, true))
    end,
}
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `lua tests/run.lua tests/test_app.lua`
Expected: an error that `src.app` was not found.

- [ ] **Step 3: Implement `src/theme.lua`**

```lua
-- Colours, fonts and row geometry (spec 6.3).
local M = {}

function M.new(disp, fontName)
    local rgb = disp.rgb
    local large = fontName == "8x12"
    return {
        font = large and disp.FONT_8X12 or disp.FONT_SCIENTIFICA,
        bold = large and disp.FONT_8X12 or disp.FONT_SCIENTIFICA_BOLD,
        cw = large and 8 or 6, rowH = 13, top = 21, bottom = 302, margin = 4,
        bg = disp.BLACK, fg = disp.WHITE, dim = rgb(120, 120, 120),
        h1 = rgb(255, 210, 80), h2 = rgb(120, 200, 255), h3 = rgb(160, 230, 160),
        link = rgb(100, 170, 255), image = rgb(220, 140, 255), read = rgb(110, 130, 160),
        selBg = rgb(40, 70, 130), quote = rgb(170, 170, 170), pre = rgb(150, 220, 150),
        bar = rgb(90, 90, 90), error = rgb(255, 110, 110),
    }
end

function M.cols(th)
    return (320 - 2 * th.margin) // th.cw
end

function M.rows(th)
    return (th.bottom - th.top) // th.rowH
end

return M
```

- [ ] **Step 4: Implement `src/app.lua`**

```lua
-- The app: config, screens, the main loop, proxy requests and navigation (spec 6).
local url = require("src.url")
local proxy = require("src.proxy")
local http = require("src.http")
local gemtext = require("src.gemtext")
local layout = require("src.layout")
local pagestate = require("src.pagestate")
local store = require("src.store")
local keys = require("src.keys")
local theme = require("src.theme")

local App = {}
App.__index = App
App.MAX_BACK, App.MAX_CACHE = 20, 3

local SCREENS = { "home", "page", "image", "settings", "loading", "message" }

-- pc: the picocalc API (a fake in host tests); appId: app.json's id.
function App.new(pc, appId)
    local self = setmetatable({ pc = pc }, App)
    self.disp, self.ui, self.input, self.sys = pc.display, pc.ui, pc.input, pc.sys
    self.store = store.new(pc.fs, pc.json, "/data/" .. appId)
    self.decode = keys.decoder(pc.input)
    self.screens = {}
    for _, name in ipairs(SCREENS) do self.screens[name] = require("src.screens." .. name) end
    self.back, self.cache, self.inbox = {}, {}, {}
    self.dirty = true
    self:loadConfig()
    return self
end

function App:loadConfig()
    local c = self.pc.config
    self.cfg = { proxyUrl = c.get("proxy_url") or "", token = c.get("token") or "", font = c.get("font") or "scientifica" }
    self.theme = theme.new(self.disp, self.cfg.font)
    if self.pool then self.pool:closeAll() end
    self.pool, self.base, self.baseErr = nil, nil, nil
    if self.cfg.proxyUrl ~= "" then
        self.base, self.baseErr = url.parseBase(self.cfg.proxyUrl)
        if self.base then self.pool = http.pool(self.pc.network, self.base) end
    end
end

function App:saveConfig(key, value)
    self.pc.config.set(key, value)
    self.pc.config.save()
    self:loadConfig()
end

function App:log(...)
    local parts = { ... }
    for i = 1, select("#", ...) do parts[i] = tostring(parts[i]) end
    self.sys.log("picosurf: " .. table.concat(parts, " "))
end

function App:toast(text, style)
    self.ui.toast(text, style or self.ui.TOAST_INFO)
    self.dirty = true
end

function App:show(name, args)
    self.screenName = name
    self.screen = self.screens[name]
    self.dirty = true
    self:log("screen", name)
    if self.screen.enter then self.screen.enter(self, args or {}) end
end

function App:addMenuItems()
    self.sys.addMenuItem("Reload", function() self:reload() end)
    self.sys.addMenuItem("Edit URL", function() self:editUrl() end)
    self.sys.addMenuItem("Settings", function() self:show("settings", { from = self.screenName }) end)
end

function App:start()
    self:addMenuItems()
    if self.cfg.proxyUrl == "" then
        self:show("settings", { firstRun = true })
    else
        self:show("home")
    end
end

-- One pass of the main loop: input, finished requests, the screen's own
-- work, and a redraw only when something changed.
function App:step()
    self.input.update()
    while true do
        local ev = self.input.pollEvent()
        if not ev then break end
        local action, arg = self.decode(ev)
        if action and self.screen.key then self.screen.key(self, action, arg) end
    end
    self:pump()
    if self.screen.update then self.screen.update(self) end
    if self.dirty then
        self.dirty = false
        self.disp.clear(self.theme.bg)
        self.screen.draw(self)
        self.disp.flush()
    end
end

function App:run()
    self:start()
    while not self.quit do
        self:step()
        self.sys.sleep(16)
    end
    if self.pool then self.pool:closeAll() end
end

-- Results arrive inside the firmware's service pass; they are applied here,
-- between steps, never in the middle of a draw.
function App:pump()
    while #self.inbox > 0 do
        local m = table.remove(self.inbox, 1)
        m.done(m.result)
        self.dirty = true
    end
    local notes = self.store.notes
    while #notes > 0 do self:toast(table.remove(notes, 1), self.ui.TOAST_WARNING) end
end

-- Starts a proxy request; done(result) runs from the main loop.
function App:request(target, as, done)
    if not self.pool then return nil, self.baseErr or "Set the proxy URL in Settings" end
    local handle, err = self.pool:get(proxy.getPath(self.base, target, as), proxy.headers(self.cfg.token),
        function(ok, status, body, headers)
            self.inbox[#self.inbox + 1] = { done = done, result = proxy.interpret(ok, status, body, headers) }
        end)
    if not handle then return nil, err == "busy" and "Busy: try again" or err end
    return handle
end

function App:ping()
    if not self.pool then
        return self:toast(self.baseErr or "Set the proxy URL first", self.ui.TOAST_WARNING)
    end
    local handle = self.pool:get(proxy.pingPath(self.base), proxy.headers(self.cfg.token),
        function(ok, status, body, headers)
            self.inbox[#self.inbox + 1] = {
                result = proxy.interpretPing(ok, status, body, headers),
                done = function(r)
                    if r.ok then
                        self:log("ping", "ok")
                        self:toast("Proxy OK", self.ui.TOAST_SUCCESS)
                    else
                        self:log("ping", "failed", r.message)
                        self:toast(r.message, self.ui.TOAST_ERROR)
                    end
                end,
            }
        end)
    if not handle then self:toast("Busy: try again", self.ui.TOAST_WARNING) end
end

function App:cacheKey(u, mode)
    return u .. "\n" .. mode
end

function App:cacheGet(u, mode)
    local k = self:cacheKey(u, mode)
    for i, e in ipairs(self.cache) do
        if e.key == k then
            table.remove(self.cache, i)
            self.cache[#self.cache + 1] = e
            return e.result
        end
    end
    return nil
end

function App:cacheDrop(u, mode)
    local k = self:cacheKey(u, mode)
    for i, e in ipairs(self.cache) do
        if e.key == k then
            table.remove(self.cache, i)
            return
        end
    end
end

function App:cachePut(u, mode, result)
    self:cacheDrop(u, mode)
    self.cache[#self.cache + 1] = { key = self:cacheKey(u, mode), result = result }
    while #self.cache > App.MAX_CACHE do table.remove(self.cache, 1) end
end

-- Opens a URL in the page view. opts: mode ("reader"|"full"|"feed"),
-- push (false replaces the current page instead of stacking it), restore ({top, sel}).
function App:open(target, opts)
    opts = opts or {}
    local scheme = url.scheme(target)
    if scheme ~= "http" and scheme ~= "https" then
        return self:toast((scheme or "That") .. ":// links aren't supported yet", self.ui.TOAST_WARNING)
    end
    local mode = opts.mode or "reader"
    local cached = self:cacheGet(target, mode)
    if cached then return self:showResult(target, mode, cached, opts) end
    self:show("loading", {
        url = target, as = mode,
        onResult = function(r) self:showResult(target, mode, r, opts) end,
        onCancel = function() self:show(self.page and "page" or "home") end,
    })
end

function App:showResult(target, mode, r, opts)
    opts = opts or {}
    if r.kind == "gemini" or r.kind == "text" then
        local finalUrl = r.finalUrl or target
        local page, err = self:buildPage(finalUrl, mode, r, opts.restore)
        if not page then return self:fail(err) end
        if opts.push ~= false and self.page then self:pushBack() end
        self.page = page
        self:cachePut(finalUrl, mode, r)
        self.store:addHistory(finalUrl, page.title)
        self:log("loaded", finalUrl, "mode=" .. page.mode, "links=" .. #page.L.links, "rows=" .. page.L.count)
        if r.truncated then self:toast("Page truncated by the proxy", self.ui.TOAST_WARNING) end
        return self:show("page")
    end
    if r.kind == "image" then
        local where = r.finalUrl or target
        local ok, img = pcall(self.pc.graphics.image.loadFromBuffer, r.body)
        if not ok or not img then
            self:log("error", "-", "image decode failed " .. where)
            return self:fail("Could not decode the image: " .. where)
        end
        return self:show("image", { url = where, image = img })
    end
    self:log("error", r.status or "-", r.message)
    self:fail(r.message, function() self:open(target, opts) end)
end

-- Parses and lays out a page; on a memory error drops the cache and tries once more.
function App:buildPage(finalUrl, mode, r, restore)
    local cols = theme.cols(self.theme)
    local function parse()
        local lines = r.kind == "text" and gemtext.fromPlain(r.body) or gemtext.parse(r.body)
        return lines, layout.build(lines, cols)
    end
    local ok, lines, L = pcall(parse)
    if not ok then
        self:log("layout-error", lines)
        self.cache = {}
        collectgarbage()
        ok, lines, L = pcall(parse)
        if not ok then return nil, "Page too large for memory" end
    end
    local page = {
        url = finalUrl, want = mode, mode = r.mode or (r.kind == "text" and "full" or mode),
        title = r.title or gemtext.title(lines) or url.host(finalUrl), feedUrl = r.feedUrl, lines = lines, L = L,
    }
    page.ps = pagestate.new(L, theme.rows(self.theme))
    if restore then page.ps:restore(restore.top, restore.sel) end
    return page
end

-- After a font change: lay the current page out again for the new width.
function App:relayout()
    local p = self.page
    if not p then return end
    p.L = layout.build(p.lines, theme.cols(self.theme))
    p.ps = pagestate.new(p.L, theme.rows(self.theme))
end

function App:fail(message, retry)
    self:show("message", { title = "Error", text = message or "Something went wrong", retry = retry })
end

function App:pushBack()
    local p = self.page
    self.back[#self.back + 1] = { url = p.url, want = p.want, top = p.ps.top, sel = p.ps.sel }
    while #self.back > App.MAX_BACK do table.remove(self.back, 1) end
end

function App:goBack()
    local e = table.remove(self.back)
    if not e then return self:goHome() end
    self:open(e.url, { mode = e.want, push = false, restore = { top = e.top, sel = e.sel } })
end

function App:goHome()
    self.page, self.back = nil, {}
    self:show("home")
end

function App:followLink(link)
    self:log("follow", link.url)
    self:open(link.url)
end

-- F1: ask for a URL. ui.textInput draws over the screen already shown. The log
-- line tells simulator tests the text box is open before they type.
function App:promptGo(default)
    self:log("prompt", "go")
    local text = self.ui.textInput("Go to:", default)
    self.input.clearState()
    self.dirty = true
    if not text then return end
    local target, err = url.normalize(text)
    if not target then return self:toast(err, self.ui.TOAST_WARNING) end
    self:open(target)
end

function App:toggleBookmark()
    local p = self.page
    if not p then return end
    local added = self.store:toggleBookmark(p.url, p.title)
    self:log("bookmark", added and "add" or "remove", p.url)
    self:toast(added and "Bookmarked" or "Bookmark removed", self.ui.TOAST_SUCCESS)
end

function App:toggleMode()
    local p = self.page
    -- A feed's article list has no reader or full mode.
    if not p or p.isFeedList then return end
    self:open(p.url, { mode = p.mode == "full" and "reader" or "full", push = false })
end

function App:reload()
    local p = self.page
    if not p or self.screenName ~= "page" then return self:toast("Nothing to reload") end
    self:cacheDrop(p.url, p.want)
    self:open(p.url, { mode = p.want, push = false, restore = { top = p.ps.top, sel = p.ps.sel } })
end

function App:editUrl()
    local p = self.page
    if not p or self.screenName ~= "page" then return self:promptGo() end
    if #p.url > 127 then return self:toast("URL too long to edit", self.ui.TOAST_WARNING) end
    self:promptGo(p.url)
end

return App
```

- [ ] **Step 5: Implement the screens**

`src/screens/loading.lua`:
```lua
-- Loading: waits for WiFi and the clock, runs one proxy request and shows its
-- progress; Esc cancels (spec 6.2, 6.9).
local url = require("src.url")

local S = {}
local RETRY_MS = 3000

function S.enter(app, args)
    app.loading = {
        url = args.url, as = args.as, onResult = args.onResult, onCancel = args.onCancel,
        state = "start", frame = 0, nextFrame = app.sys.getTimeMs(),
    }
end

local function begin(app, L)
    local status = app.pc.network.getStatus()
    if status == 2 then
        app.loading = nil
        return L.onResult({ kind = "error", message = "WiFi not available" })
    end
    if status ~= 1 then
        L.state = "wifi"
        return
    end
    if app.base and app.base.tls and not app.sys.getClock().synced then
        L.state, L.retryAt = "clock", app.sys.getTimeMs() + RETRY_MS
        return
    end
    local handle, err = app:request(L.url, L.as, function(r)
        if app.loading ~= L then return end -- cancelled
        if r.kind == "clock" then
            L.state, L.retryAt, L.handle = "clock", app.sys.getTimeMs() + RETRY_MS, nil
            return
        end
        app.loading = nil
        L.onResult(r)
    end)
    if not handle then
        app.loading = nil
        return L.onResult({ kind = "error", message = err or "Request failed" })
    end
    L.state, L.handle = "fetching", handle
end

function S.update(app)
    local L = app.loading
    if not L then return end
    local now = app.sys.getTimeMs()
    if L.state == "start" then
        begin(app, L)
    elseif L.state == "wifi" and app.pc.network.getStatus() ~= 0 then
        L.state = "start"
    elseif L.state == "clock" and now - L.retryAt >= 0 then
        L.state = "start"
    end
    if now - L.nextFrame >= 0 then
        L.frame, L.nextFrame = L.frame + 1, now + 150
        app.dirty = true
    end
end

function S.draw(app)
    local L, th, d = app.loading, app.theme, app.disp
    app.ui.drawHeader("PicoSurf")
    d.setFont(th.font)
    local msg, sub = "Loading", ""
    if L then
        msg = "Loading " .. url.host(L.url)
        if L.state == "wifi" then
            msg = "Connecting to WiFi..."
        elseif L.state == "clock" then
            msg = "Waiting for time sync..."
        elseif L.handle and L.handle.received then
            local bytes = L.handle.received()
            if bytes > 0 then sub = (bytes // 1024) .. " KB" end
        end
        app.ui.drawSpinner(160, 120, 10, L.frame)
    end
    d.drawText(th.margin, 150, msg:sub(1, 52), th.fg, false)
    d.drawText(th.margin, 166, sub, th.dim, false)
    app.ui.drawFooter("Esc cancel", "")
end

function S.key(app, action)
    if action ~= "esc" and action ~= "backspace" then return end
    local L = app.loading
    app.loading = nil
    if L then
        if L.handle then L.handle.cancel() end
        app:log("cancelled", L.url)
        L.onCancel()
    end
end

return S
```

`src/screens/message.lua`:
```lua
-- An error with its reason; Enter retries when possible, Esc goes back (spec 6.9).
local wrap = require("src.wrap")
local theme = require("src.theme")

local S = {}

function S.enter(app, args)
    app.msg = args
end

function S.draw(app)
    local m, th, d = app.msg, app.theme, app.disp
    app.ui.drawHeader(m.title or "PicoSurf")
    d.setFont(th.font)
    local text = m.text or ""
    local s, e = wrap.wrap(text, theme.cols(th))
    for i = 1, math.min(#s, 16) do
        d.drawText(th.margin, th.top + 20 + (i - 1) * th.rowH, text:sub(s[i], e[i]), th.error, false)
    end
    app.ui.drawFooter(m.retry and "Enter retry  Esc back" or "Esc back", "")
end

function S.key(app, action)
    local m = app.msg
    if action == "enter" and m.retry then
        app.msg = nil
        return m.retry()
    end
    if action == "esc" or action == "backspace" then
        app.msg = nil
        app:show(app.page and "page" or "home")
    end
end

return S
```

`src/screens/settings.lua`:
```lua
-- Settings: proxy URL, token, font and a connection test (spec 6.8).
local S = {}
local ITEMS = { "proxy", "token", "font", "test" }

function S.enter(app, args)
    app.set = { sel = 1, firstRun = args.firstRun, from = args.from }
end

local function label(app, item)
    local c = app.cfg
    if item == "proxy" then return "Proxy URL: " .. (c.proxyUrl ~= "" and c.proxyUrl or "(not set)") end
    if item == "token" then return "Token: " .. (c.token ~= "" and ("****" .. c.token:sub(-4)) or "(not set)") end
    if item == "font" then return "Font: " .. (c.font == "8x12" and "8x12 (large)" or "Scientifica") end
    return "Test connection"
end

function S.draw(app)
    local th, d, set = app.theme, app.disp, app.set
    app.ui.drawHeader("PicoSurf Settings")
    for i, item in ipairs(ITEMS) do
        app.ui.drawListItem(0, 30 + (i - 1) * 16, 320, label(app, item), i == set.sel, true)
    end
    local notes = {}
    if set.firstRun then
        notes = {
            "PicoSurf reads the web through a",
            "PicoSurf proxy you run yourself.",
            "Setup: github.com/PicoDeck/picosurf",
            "(proxy/README.md), then enter its",
            "URL and token above.",
        }
    end
    if app.cfg.proxyUrl:lower():match("^http://") then
        notes[#notes + 1] = "Warning: http:// sends the token unencrypted."
    end
    if app.baseErr then notes[#notes + 1] = app.baseErr end
    d.setFont(th.font)
    for i, n in ipairs(notes) do
        d.drawText(th.margin, 110 + (i - 1) * th.rowH, n, th.dim, false)
    end
    app.ui.drawFooter("Enter edit  Esc done", "")
end

local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

function S.key(app, action)
    local set = app.set
    if action == "up" then
        set.sel = (set.sel - 2) % #ITEMS + 1
    elseif action == "down" then
        set.sel = set.sel % #ITEMS + 1
    elseif action == "enter" then
        local item = ITEMS[set.sel]
        if item == "proxy" then
            local v = app.ui.textInput("Proxy URL:", app.cfg.proxyUrl)
            app.input.clearState()
            if v then app:saveConfig("proxy_url", trim(v)) end
        elseif item == "token" then
            local v = app.ui.textInput("Token:", "")
            app.input.clearState()
            if v and trim(v) ~= "" then app:saveConfig("token", trim(v)) end
        elseif item == "font" then
            app:saveConfig("font", app.cfg.font == "8x12" and "scientifica" or "8x12")
            app:relayout()
        else
            app:ping()
        end
    elseif action == "esc" or action == "backspace" then
        return app:show((set.from == "page" and app.page) and "page" or "home")
    end
    app.dirty = true
end

return S
```

`src/screens/home.lua`:
```lua
-- Home: Bookmarks and History lists (spec 6.2).
local S = {}
local TABS = { "Bookmarks", "History" }
local LIST_TOP, ROW_H = 43, 13
local VISIBLE = (302 - LIST_TOP) // ROW_H

local function items(app, tab)
    if TABS[tab] == "Bookmarks" then return app.store:bookmarks() end
    return app.store:history()
end

function S.enter(app)
    app.home = app.home or { tab = 1, sel = {}, top = {} }
end

function S.draw(app)
    local h, th = app.home, app.theme
    app.ui.drawHeader("PicoSurf")
    app.ui.drawTabs(21, TABS, h.tab)
    local list = items(app, h.tab)
    local sel, top = h.sel[h.tab] or 1, h.top[h.tab] or 1
    if #list == 0 then
        app.disp.setFont(th.font)
        local hint = TABS[h.tab] == "Bookmarks" and "No bookmarks yet. F3 on a page adds one."
            or "Nothing visited yet. F1 opens a URL."
        app.disp.drawText(th.margin, LIST_TOP + 20, hint, th.dim, false)
    end
    for i = top, math.min(#list, top + VISIBLE - 1) do
        local e = list[i]
        app.ui.drawListItem(0, LIST_TOP + (i - top) * ROW_H, 320, e.title or e.url, i == sel, true)
    end
    app.ui.drawFooter("F1 go  Del remove  Esc quit", "")
end

function S.key(app, action)
    local h = app.home
    local list = items(app, h.tab)
    local sel = h.sel[h.tab] or 1
    if action == "left" or action == "right" then
        h.tab = (h.tab + (action == "right" and 1 or -1) - 1) % #TABS + 1
        app:log("tab", TABS[h.tab])
    elseif action == "up" or action == "down" then
        sel = math.max(1, math.min(#list, sel + (action == "down" and 1 or -1)))
        h.sel[h.tab] = sel
        local top = h.top[h.tab] or 1
        if sel < top then top = sel elseif sel >= top + VISIBLE then top = sel - VISIBLE + 1 end
        h.top[h.tab] = top
    elseif action == "enter" then
        local e = list[sel]
        if e then return app:open(e.url) end
    elseif action == "del" then
        if list[sel] then
            if TABS[h.tab] == "Bookmarks" then app.store:removeBookmark(sel) else app.store:removeHistory(sel) end
            h.sel[h.tab] = math.max(1, math.min(sel, #items(app, h.tab)))
        end
    elseif action == "f1" then
        return app:promptGo()
    elseif action == "esc" then
        app.quit = true
    end
    app.dirty = true
end

return S
```

`src/screens/page.lua`:
```lua
-- The page view: draws rows, handles scrolling, links and page keys (spec 6.2-6.4).
local layout = require("src.layout")
local theme = require("src.theme")
local url = require("src.url")

local S = {}
local MODE_LETTER = { reader = "R", full = "F", feed = "L" }

local function rowColor(th, st)
    if st == layout.H1 then return th.h1 end
    if st == layout.H2 then return th.h2 end
    if st == layout.H3 then return th.h3 end
    if st == layout.LINK then return th.link end
    if st == layout.IMAGE then return th.image end
    if st == layout.READ then return th.read end
    if st == layout.QUOTE then return th.quote end
    if st == layout.PRE then return th.pre end
    return th.fg
end

function S.draw(app)
    local th, d, p = app.theme, app.disp, app.page
    local L, ps = p.L, p.ps
    app.ui.drawHeader(p.title:sub(1, 48))
    local cols = theme.cols(th)
    for r = ps.top, ps:lastVisible() do
        local y = th.top + 1 + (r - ps.top) * th.rowH
        local st = L.style[r]
        local x = th.margin
        if L.link[r] ~= 0 and L.link[r] == ps.sel then d.fillRect(0, y - 1, 320, th.rowH, th.selBg) end
        local heading = st == layout.H1 or st == layout.H2 or st == layout.H3
        d.setFont(heading and th.bold or th.font)
        if st == layout.ITEM then
            d.drawText(x, y, "*", th.dim, false)
            x = x + 2 * th.cw
        elseif st == layout.ITEMC then
            x = x + 2 * th.cw
        elseif st == layout.QUOTE then
            d.fillRect(x, y - 1, 2, th.rowH, th.bar)
            x = x + 2 * th.cw
        end
        d.drawText(x, y, layout.rowText(L, r), rowColor(th, st), false)
        if L.cont[r] then d.drawText(th.margin + (cols - 1) * th.cw, y, "\\", th.dim, false) end
    end
    local left = url.host(p.url)
    if ps.digits ~= "" then left = "Link: " .. ps.digits .. "_" end
    app.ui.drawFooter(left:sub(1, 36), ps:percent() .. "% " .. (MODE_LETTER[p.mode] or "F"))
end

function S.key(app, action, arg)
    local ps = app.page.ps
    if action == "digit" then
        ps:typeDigit(arg)
    elseif action == "backspace" and ps.digits ~= "" then
        ps:eraseDigit()
    elseif action == "esc" and ps.digits ~= "" then
        ps:clearDigits()
    elseif action == "enter" then
        if ps.digits ~= "" then
            local link, n = ps:takeNumbered()
            if link then return app:followLink(link) end
            if n then app:toast("No link [" .. n .. "] on this page", app.ui.TOAST_WARNING) end
        else
            local link = ps:selected()
            if link then return app:followLink(link) end
        end
    elseif action == "up" then
        ps:scroll(-1)
    elseif action == "down" then
        ps:scroll(1)
    elseif action == "left" then
        ps:page(-1)
    elseif action == "right" or action == "space" then
        ps:page(1)
    elseif action == "nextlink" then
        ps:nextLink(1)
    elseif action == "prevlink" then
        ps:nextLink(-1)
    elseif action == "backspace" or action == "esc" then
        return app:goBack()
    elseif action == "f1" then
        return app:promptGo()
    elseif action == "f2" then
        return app:goHome()
    elseif action == "f3" then
        return app:toggleBookmark()
    elseif action == "f4" then
        return app:toggleMode()
    end
    app.dirty = true
end

return S
```

`src/screens/image.lua`:
```lua
-- An image, centred on black (spec 6.2). The proxy has already shrunk it to
-- fit 320x320 as a baseline JPEG.
local S = {}

function S.enter(app, args)
    app.image, app.imageUrl = args.image, args.url
    local w, h = args.image:getSize()
    app.imageSize = { w, h }
    app:log("image", "w=" .. w, "h=" .. h)
end

function S.draw(app)
    app.disp.clear(app.disp.BLACK)
    local w, h = app.imageSize[1], app.imageSize[2]
    app.image:draw((320 - w) // 2, (320 - h) // 2)
end

function S.key(app, action)
    if action == "esc" or action == "backspace" then
        app.image = nil
        collectgarbage()
        app:show(app.page and "page" or "home")
    end
end

return S
```

`main.lua`:
```lua
-- PicoSurf: read the web and feeds on PicoDeck through a PicoSurf proxy.
if not require then
    picocalc.ui.splash("PicoSurf needs a newer PicoDeck", "Update the firmware to 0.5.0 or later")
    picocalc.sys.sleep(3000)
    return
end
local App = require("src.app")
App.new(picocalc, APP_ID):run()
```

- [ ] **Step 6: Run the tests to make sure they pass**

Run: `make test`
Expected: all tests pass under both Luas.

If an app test fails, find the cause in the app code first. Change a test only if it contradicts the spec, and explain the change in your report.

- [ ] **Step 7: Commit**

```bash
git add src/theme.lua src/app.lua src/screens main.lua tests/test_app.lua
git commit -m "feat(app): browsing, settings, loading, errors and images"
```

---

### Task 11: Feeds

**Files:**
- Modify: `src/app.lua`, `src/screens/home.lua` (replaced whole), `src/screens/page.lua` (one branch)
- Test: `tests/test_app_feeds.lua`

**Interfaces:**
- Consumes: `feeds` (Task 8), `store` (Task 7), and App (Task 10).
- Produces:
  - New App methods: `now()`, `feedById(id)`, `applyFeed(feed, r) -> data`, `subscribe()`, `openFeed(feed, opts)`, `showFeed(feed, opts)`, `refreshAll()`, `pumpRefresh()`, `cancelRefresh()`, `markAllRead()`.
  - Replaced App methods: `followLink`, `pushBack`, `goBack`, `reload`, `addMenuItems`, `open`.
  - Feed-list pages have `isFeedList = true` and `feedId`.
  - Home tabs become Feeds, Bookmarks, History.
  - A fourth menu item: `Mark all read`.
  - New log lines:
    - `subscribed <id> <url> unread=<n>`
    - `feed <id> unread=<n>`
    - `refresh done ok=<n> failed=<n>` and `refresh cancelled`
    - `unsubscribed <id>`

- [ ] **Step 1: Write the failing tests**

`tests/test_app_feeds.lua`:
```lua
local T = require("tests.t")
local fakepc = require("tests.fakepc")
local App = require("src.app")

local FEED = "# Blog\n\n=> https://blog.test/1 2026-10-13 One\n=> https://blog.test/2 2026-10-12 Two\n=> https://blog.test/3 Undated\n"
local NEWS = "# News\n\n=> https://news.test/1 2026-10-14 Headline\n"
local ROUTES = {
    ["https://blog.test/"] = { title = "Blog", feed = "https://blog.test/feed.xml", body = "# Blog\n\nHello.\n" },
    ["https://blog.test/|feed"] = { title = "Blog", final = "https://blog.test/feed.xml", mode = "feed", body = FEED },
    ["https://blog.test/feed.xml|feed"] = { title = "Blog", mode = "feed", body = FEED },
    ["https://blog.test/1"] = { title = "One", body = "# One\n" },
    ["https://news.test/"] = { title = "News", body = "# News\n" },
    ["https://news.test/|feed"] = { title = "News", final = "https://news.test/rss", mode = "feed", body = NEWS },
    ["https://news.test/rss|feed"] = { title = "News", mode = "feed", body = NEWS },
    ["https://plain.test/"] = { title = "Plain", body = "# Plain\n" },
    ["https://plain.test/|feed"] = { status = 415, type = "text/plain; charset=us-ascii", mode = false, body = "No feed found on this page\n" },
}

local function boot()
    local F = fakepc.new()
    F.config.proxy_url, F.config.token = "https://p.test", "tok"
    F.responder = fakepc.proxy(ROUTES, "tok")
    local app = App.new(F.pc, "net.picodeck.picosurf")
    app:start()
    app:step()
    return app, F
end

local function steps(app, n)
    for _ = 1, n or 3 do app:step() end
end

local function go(app, F, text)
    F.inputs[#F.inputs + 1] = text
    F.press("f1")
    steps(app)
end

local function subscribe(app, F, site)
    go(app, F, site)
    F.press("f5")
    steps(app)
end

return {
    f5_subscribes_from_a_homepage = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        T.ok(F.hasLog("picosurf: subscribed 1 https://blog.test/feed.xml unread=3"))
        T.ok(F.hasToast("Subscribed: Blog"))
        T.eq(app.screenName, "page")
        local feed = app.store:feedIndex().feeds[1]
        T.eq(feed.url, "https://blog.test/feed.xml"); T.eq(feed.fetched_at, F.epoch); T.eq(feed.newest, "2026-10-13")
        F.press("f5"); steps(app)
        T.ok(F.hasToast("Already subscribed"))
    end,
    f5_on_a_page_without_a_feed_says_so = function()
        local app, F = boot()
        subscribe(app, F, "plain.test/")
        T.ok(F.hasToast("No feed found on this page"))
        T.eq(#app.store:feedIndex().feeds, 0)
    end,
    the_feeds_tab_lists_feeds_and_opens_them_without_fetching = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        F.press("f2"); steps(app, 1)
        T.ok(F.screenText():find("[T*] Feeds", 1, true))
        T.ok(F.screenText():find("[>] Blog (3)", 1, true))
        local before = #F.requests
        F.press("enter"); steps(app, 1)
        T.eq(#F.requests, before, "fresh feed: no request")
        T.eq(app.screenName, "page"); T.eq(app.page.isFeedList, true)
        T.ok(F.screenText():find("* 2026-10-13 One", 1, true))
        T.ok(F.hasLog("picosurf: feed 1 unread=3"))
    end,
    opening_an_article_marks_it_read = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        F.press("f2"); F.press("enter"); steps(app, 1)
        F.press("tab"); F.press("enter"); steps(app)
        T.ok(F.hasLog("picosurf: feed 1 unread=2"))
        T.eq(app.page.url, "https://blog.test/1")
        T.eq(app.store:feedIndex().feeds[1].unread, 2)
        F.press("backspace"); steps(app, 1)
        T.eq(app.page.isFeedList, true)
        T.ok(F.screenText():find("  2026-10-13 One", 1, true), "read item shows without the star")
        T.eq(app.page.ps.sel, 1, "selection restored")
    end,
    a_stale_feed_is_fetched_when_opened = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        F.epoch = F.epoch + 1800
        F.press("f2"); F.press("enter"); steps(app)
        T.ok(F.requests[#F.requests].path:find("feed.xml", 1, true))
        T.eq(app.page.isFeedList, true)
        T.eq(app.store:feedIndex().feeds[1].fetched_at, F.epoch)
    end,
    f5_on_the_feeds_tab_refreshes_every_feed = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        subscribe(app, F, "news.test/")
        F.press("f2"); steps(app, 1)
        local before = #F.requests
        F.press("f5"); steps(app)
        T.eq(#F.requests, before + 2)
        T.ok(F.hasLog("picosurf: refresh done ok=2 failed=0"))
        T.ok(F.hasToast("Feeds refreshed"))
    end,
    esc_cancels_a_refresh_instead_of_quitting = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        F.press("f2"); steps(app, 1)
        F.holding = true
        F.press("f5"); steps(app, 1)
        F.press("esc"); steps(app, 1)
        T.ok(F.hasLog("picosurf: refresh cancelled"))
        T.ok(not app.quit)
        F.holding = false
        steps(app)
        T.ok(not F.hasLog("refresh done"))
    end,
    mark_all_read_from_the_menu = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        F.press("f2"); F.press("enter"); steps(app, 1)
        F.menu["Mark all read"](); steps(app, 1)
        T.ok(F.hasLog("picosurf: feed 1 unread=0"))
        T.eq(app.store:feedIndex().feeds[1].unread, 0)
        T.ok(F.screenText():find("  2026-10-12 Two", 1, true))
    end,
    reload_on_a_feed_list_fetches_the_feed = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        F.press("f2"); F.press("enter"); steps(app, 1)
        local before = #F.requests
        F.menu["Reload"](); steps(app)
        T.eq(#F.requests, before + 1)
        T.ok(F.requests[#F.requests].path:find("as=feed", 1, true))
        T.eq(app.page.isFeedList, true)
        T.eq(#app.back, 0, "reload replaced the page instead of stacking it")
    end,
    del_unsubscribes_after_confirming = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        F.press("f2"); steps(app, 1)
        F.confirms = { false }
        F.press("del"); steps(app, 1)
        T.eq(#app.store:feedIndex().feeds, 1)
        F.press("del"); steps(app, 1)
        T.eq(#app.store:feedIndex().feeds, 0)
        T.eq(F.files["/data/net.picodeck.picosurf/feeds/1.json"], nil)
        T.ok(F.hasLog("picosurf: unsubscribed 1"))
    end,
}
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `lua tests/run.lua tests/test_app_feeds.lua`
Expected: failures. For example, the F5 test logs nothing, and the Feeds tab is missing.

- [ ] **Step 3: Add feeds to `src/app.lua`**

At the top of `src/app.lua`, below `local theme = require("src.theme")`, add:
```lua
local feeds = require("src.feeds")
```

Replace `App:addMenuItems`, `App:open`, `App:pushBack`, `App:goBack`, `App:followLink` and `App:reload` with these versions:
```lua
function App:addMenuItems()
    self.sys.addMenuItem("Reload", function() self:reload() end)
    self.sys.addMenuItem("Edit URL", function() self:editUrl() end)
    self.sys.addMenuItem("Mark all read", function() self:markAllRead() end)
    self.sys.addMenuItem("Settings", function() self:show("settings", { from = self.screenName }) end)
end

-- Opens a URL in the page view. opts: mode ("reader"|"full"|"feed"),
-- push (false replaces the current page instead of stacking it), restore ({top, sel}).
function App:open(target, opts)
    opts = opts or {}
    local scheme = url.scheme(target)
    if scheme ~= "http" and scheme ~= "https" then
        return self:toast((scheme or "That") .. ":// links aren't supported yet", self.ui.TOAST_WARNING)
    end
    self:cancelRefresh() -- frees the connections a refresh holds
    local mode = opts.mode or "reader"
    local cached = self:cacheGet(target, mode)
    if cached then return self:showResult(target, mode, cached, opts) end
    self:show("loading", {
        url = target, as = mode,
        onResult = function(r) self:showResult(target, mode, r, opts) end,
        onCancel = function() self:show(self.page and "page" or "home") end,
    })
end

function App:pushBack()
    local p = self.page
    self.back[#self.back + 1] = {
        url = p.url, want = p.want, top = p.ps.top, sel = p.ps.sel, feedId = p.isFeedList and p.feedId or nil,
    }
    while #self.back > App.MAX_BACK do table.remove(self.back, 1) end
end

function App:goBack()
    local e = table.remove(self.back)
    if not e then return self:goHome() end
    local restore = { top = e.top, sel = e.sel }
    if e.feedId then
        local feed = self:feedById(e.feedId)
        if feed then return self:showFeed(feed, { push = false, restore = restore }) end
        return self:goBack() -- unsubscribed meanwhile
    end
    self:open(e.url, { mode = e.want, push = false, restore = restore })
end

function App:followLink(link)
    local p = self.page
    if p and p.isFeedList then
        local feed = self:feedById(p.feedId)
        local data = self.store:feedData(p.feedId)
        if feed and feeds.markRead(data, link.url) then
            self.store:saveFeedData(feed.id, data)
            feeds.summarize(feed, data)
            self.store:saveFeedIndex()
            self:log("feed", feed.id, "unread=" .. feed.unread)
        end
    end
    self:log("follow", link.url)
    self:open(link.url)
end

function App:reload()
    local p = self.page
    if not p or self.screenName ~= "page" then return self:toast("Nothing to reload") end
    if p.isFeedList then
        local feed = self:feedById(p.feedId)
        if feed then
            feed.fetched_at = 0
            return self:openFeed(feed, { push = false, restore = { top = p.ps.top, sel = p.ps.sel } })
        end
        return
    end
    self:cacheDrop(p.url, p.want)
    self:open(p.url, { mode = p.want, push = false, restore = { top = p.ps.top, sel = p.ps.sel } })
end
```

Then add these new methods before `return App`:
```lua
function App:now()
    local c = self.sys.getClock()
    return c.synced and c.epoch or 0
end

function App:feedById(id)
    for _, f in ipairs(self.store:feedIndex().feeds) do
        if f.id == id then return f end
    end
    return nil
end

-- Stores a fetched feed list (r: a gemini result from as=feed).
function App:applyFeed(feed, r)
    local items = gemtext.feedItems(gemtext.parse(r.body))
    local data = feeds.merge(self.store:feedData(feed.id), items)
    if r.title and r.title ~= "" then feed.title = r.title end
    feeds.summarize(feed, data, self:now())
    self.store:saveFeedData(feed.id, data)
    self.store:saveFeedIndex()
    return data
end

-- F5 on a page: subscribe to its feed (the proxy finds it from a homepage).
function App:subscribe()
    local p = self.page
    if not p then return end
    if p.isFeedList then return self:toast("Already subscribed") end
    self:show("loading", {
        url = p.url, as = "feed",
        onCancel = function() self:show("page") end,
        onResult = function(r)
            self:show("page")
            if r.kind ~= "gemini" then
                self:log("error", r.status or "-", r.message)
                return self:toast(r.message or "Not a feed", self.ui.TOAST_ERROR)
            end
            local index = self.store:feedIndex()
            local feed, isNew = feeds.subscribe(index, r.finalUrl or p.url, r.title)
            if not feed then return self:toast(isNew, self.ui.TOAST_ERROR) end
            if not isNew then return self:toast("Already subscribed") end
            self:applyFeed(feed, r)
            self:log("subscribed", feed.id, feed.url, "unread=" .. feed.unread)
            self:toast("Subscribed: " .. feed.title, self.ui.TOAST_SUCCESS)
        end,
    })
end

-- Opens a feed's article list, fetching it first when stale.
function App:openFeed(feed, opts)
    opts = opts or {}
    self:cancelRefresh()
    if not feeds.isStale(feed, self:now()) then return self:showFeed(feed, opts) end
    self:show("loading", {
        url = feed.url, as = "feed",
        onCancel = function() self:show(self.page and "page" or "home") end,
        onResult = function(r)
            if r.kind == "gemini" then
                self:applyFeed(feed, r)
            else
                self:log("error", r.status or "-", r.message)
                self:toast(r.message or "Refresh failed", self.ui.TOAST_ERROR)
            end
            self:showFeed(feed, opts)
        end,
    })
end

function App:showFeed(feed, opts)
    opts = opts or {}
    local lines = feeds.lines(feed, self.store:feedData(feed.id))
    local L = layout.build(lines, theme.cols(self.theme))
    local page = {
        url = feed.url, want = "feed", mode = "feed", title = feed.title, lines = lines, L = L,
        isFeedList = true, feedId = feed.id,
    }
    page.ps = pagestate.new(L, theme.rows(self.theme))
    if opts.restore then page.ps:restore(opts.restore.top, opts.restore.sel) end
    if opts.push ~= false and self.page then self:pushBack() end
    self.page = page
    self:log("feed", feed.id, "unread=" .. feed.unread)
    self:show("page")
end

-- F5 on the Feeds tab: refresh every feed, two requests at a time.
function App:refreshAll()
    if self.refresh then return end
    local list = feeds.sorted(self.store:feedIndex())
    if #list == 0 then return self:toast("No feeds to refresh") end
    self.refresh = { list = list, nextIndex = 1, active = 0, done = 0, ok = 0, failed = 0, handles = {} }
    self:pumpRefresh()
end

function App:pumpRefresh()
    local R = self.refresh
    if not R then return end
    while self.refresh == R and R.active < 2 and R.nextIndex <= #R.list do
        local feed = R.list[R.nextIndex]
        R.nextIndex = R.nextIndex + 1
        R.active = R.active + 1
        local handle = self:request(feed.url, "feed", function(r)
            if self.refresh ~= R then return end
            R.active, R.done = R.active - 1, R.done + 1
            if r.kind == "gemini" then
                self:applyFeed(feed, r)
                R.ok = R.ok + 1
            else
                R.failed = R.failed + 1
            end
            self:pumpRefresh()
        end)
        if handle then
            R.handles[#R.handles + 1] = handle
        else
            R.active, R.done, R.failed = R.active - 1, R.done + 1, R.failed + 1
        end
    end
    if self.refresh == R and R.done >= #R.list then
        self.refresh = nil
        self:log("refresh", "done", "ok=" .. R.ok, "failed=" .. R.failed)
        if R.failed == 0 then
            self:toast("Feeds refreshed", self.ui.TOAST_SUCCESS)
        else
            self:toast(R.failed .. " feeds failed to refresh", self.ui.TOAST_WARNING)
        end
    end
    self.dirty = true
end

function App:cancelRefresh()
    local R = self.refresh
    if not R then return end
    self.refresh = nil
    for _, h in ipairs(R.handles) do h.cancel() end
    self:log("refresh", "cancelled")
end

function App:markAllRead()
    local p = self.page
    if not p or not p.isFeedList or self.screenName ~= "page" then return self:toast("Open a feed first") end
    local feed = self:feedById(p.feedId)
    if not feed then return end
    local data = self.store:feedData(feed.id)
    feeds.markAllRead(data)
    self.store:saveFeedData(feed.id, data)
    feeds.summarize(feed, data)
    self.store:saveFeedIndex()
    self:showFeed(feed, { push = false, restore = { top = p.ps.top, sel = p.ps.sel } })
end
```

- [ ] **Step 4: Add F5 to the page view**

In `src/screens/page.lua`, in `S.key`, replace:
```lua
    elseif action == "f4" then
        return app:toggleMode()
    end
```
with:
```lua
    elseif action == "f4" then
        return app:toggleMode()
    elseif action == "f5" then
        return app:subscribe()
    end
```

- [ ] **Step 5: Replace `src/screens/home.lua`**

```lua
-- Home: Feeds, Bookmarks and History lists (spec 6.2, 6.7).
local feeds = require("src.feeds")

local S = {}
local TABS = { "Feeds", "Bookmarks", "History" }
local LIST_TOP, ROW_H = 43, 13
local VISIBLE = (302 - LIST_TOP) // ROW_H

local function items(app, tab)
    local name = TABS[tab]
    if name == "Feeds" then
        local out = {}
        for i, f in ipairs(feeds.sorted(app.store:feedIndex())) do
            out[i] = { title = f.title .. " (" .. f.unread .. ")", feed = f }
        end
        return out
    end
    if name == "Bookmarks" then return app.store:bookmarks() end
    return app.store:history()
end

local HINTS = {
    Feeds = "No feeds yet. F5 on a page subscribes.",
    Bookmarks = "No bookmarks yet. F3 on a page adds one.",
    History = "Nothing visited yet. F1 opens a URL.",
}

function S.enter(app)
    app.home = app.home or { tab = 1, sel = {}, top = {} }
end

function S.draw(app)
    local h, th = app.home, app.theme
    app.ui.drawHeader("PicoSurf")
    app.ui.drawTabs(21, TABS, h.tab)
    local list = items(app, h.tab)
    local sel, top = h.sel[h.tab] or 1, h.top[h.tab] or 1
    if #list == 0 then
        app.disp.setFont(th.font)
        app.disp.drawText(th.margin, LIST_TOP + 20, HINTS[TABS[h.tab]], th.dim, false)
    end
    for i = top, math.min(#list, top + VISIBLE - 1) do
        local e = list[i]
        app.ui.drawListItem(0, LIST_TOP + (i - top) * ROW_H, 320, e.title or e.url, i == sel, true)
    end
    local R = app.refresh
    if R then
        app.ui.drawFooter("Refreshing " .. R.done .. "/" .. #R.list .. "  Esc stop", "")
    elseif TABS[h.tab] == "Feeds" then
        app.ui.drawFooter("F5 refresh  Del remove  Esc quit", "")
    else
        app.ui.drawFooter("F1 go  Del remove  Esc quit", "")
    end
end

local function remove(app, h, entry, sel)
    local name = TABS[h.tab]
    if name == "Feeds" then
        local f = entry.feed
        if not app.ui.confirm("Unsubscribe from " .. f.title:sub(1, 30) .. "?") then return end
        app.input.clearState()
        feeds.unsubscribe(app.store:feedIndex(), f.id)
        app.store:deleteFeedData(f.id)
        app.store:saveFeedIndex()
        app:log("unsubscribed", f.id)
    elseif name == "Bookmarks" then
        app.store:removeBookmark(sel)
    else
        app.store:removeHistory(sel)
    end
end

function S.key(app, action)
    local h = app.home
    local list = items(app, h.tab)
    local sel = h.sel[h.tab] or 1
    if action == "left" or action == "right" then
        h.tab = (h.tab + (action == "right" and 1 or -1) - 1) % #TABS + 1
        app:log("tab", TABS[h.tab])
    elseif action == "up" or action == "down" then
        sel = math.max(1, math.min(#list, sel + (action == "down" and 1 or -1)))
        h.sel[h.tab] = sel
        local top = h.top[h.tab] or 1
        if sel < top then top = sel elseif sel >= top + VISIBLE then top = sel - VISIBLE + 1 end
        h.top[h.tab] = top
    elseif action == "enter" then
        local e = list[sel]
        if e and e.feed then return app:openFeed(e.feed) end
        if e then return app:open(e.url) end
    elseif action == "del" then
        if list[sel] then
            remove(app, h, list[sel], sel)
            h.sel[h.tab] = math.max(1, math.min(sel, #items(app, h.tab)))
        end
    elseif action == "f1" then
        app:cancelRefresh()
        return app:promptGo()
    elseif action == "f5" and TABS[h.tab] == "Feeds" then
        app:refreshAll()
    elseif action == "esc" then
        if app.refresh then app:cancelRefresh() else app.quit = true end
    end
    app.dirty = true
end

return S
```

- [ ] **Step 6: Run the tests to make sure they pass**

Run: `make test`
Expected: all tests pass under both Luas.

The Feeds tab is now first, which breaks two Task 10 tests in `tests/test_app.lua`. Update both and note the changes in your report:
- `home_tabs_history_and_delete`: press `right` twice instead of once (`F.press("f2"); F.press("right"); F.press("right")`) so it lands on History.
- `bookmarks_toggle_and_list_on_home`: after `F.press("f2")`, add `F.press("right")` so the list shown is Bookmarks.

- [ ] **Step 7: Commit**

```bash
git add src/app.lua src/screens/home.lua src/screens/page.lua tests/test_app_feeds.lua tests/test_app.lua
git commit -m "feat(app): feed subscriptions, the Feeds tab, unread tracking and refresh"
```

---

### Task 12: Simulator smoke tests

**Files:**
- Create: `tests/e2e/fake_proxy.py`, `tests/e2e/conftest.py`, `tests/e2e/test_app.py`

**Interfaces:**
- Consumes:
  - The app (Tasks 1–11).
  - PicoDeck's harness `$PICODECK_ROOT/tests/e2e/picodeck_simulator.py` (`PicodeckSimulator`), with these methods:
    - `start()` and `stop()`
    - `launch_app(name)`
    - `keypress(key)`: named keys `up down left right enter esc tab del backspace f1-f5`, or a single character
    - `call("inject_button", {"button": "shift", "action": "press"|"release"})`
    - `wait_for_log(regex, timeout, src="lua")`
    - `get_log_lines()`, whose entries have `src` set to `lua` or `err`
  - The simulator binary: `$PICODECK_SIM_BINARY`, or `$PICODECK_ROOT/build_sim/picodeck_simulator`.
- Produces:
  - `FakeProxy(token)`: `.add(url, body, *, as_=None, ctype=..., title=None, mode=None, final=None, feed=None, status=200, delay=0.0)`, `.start()`, `.stop()`, `.url`, `.requests`.
  - `jpeg_bytes(w, h)`.
  - The fixture `picosurf(tmp_path)`, which returns `start(config=True) -> (sim, proxy, data_dir)`.

- [ ] **Step 1: Write the fake proxy**

`tests/e2e/fake_proxy.py`:
```python
"""A stand-in PicoSurf proxy for simulator tests: canned gemtext, feeds and
images for chosen URLs, the token check, and a record of requests. The real
proxy refuses localhost sites (its SSRF guard), and the app is what is under
test here."""
import io
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

PLAIN = "text/plain; charset=us-ascii"


class FakeProxy:
    def __init__(self, token="test-token"):
        self.token = token
        self.routes = {}
        self.requests = []
        self._server = None

    def add(self, url, body, *, as_=None, ctype="text/gemini; charset=us-ascii", title=None,
            mode=None, final=None, feed=None, status=200, delay=0.0):
        data = body if isinstance(body, bytes) else body.encode("ascii")
        self.routes[(url, as_)] = dict(body=data, ctype=ctype, title=title, mode=mode, final=final,
                                       feed=feed, status=status, delay=delay)

    def start(self):
        proxy = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _send(self, status, ctype, body, extra=None):
                self.send_response(status)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                for k, v in (extra or {}).items():
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                parts = urlsplit(self.path)
                q = {k: v[0] for k, v in parse_qs(parts.query).items()}
                proxy.requests.append((parts.path, q))
                if self.headers.get("Authorization") != f"Bearer {proxy.token}":
                    return self._send(401, PLAIN, b"Missing or wrong token\n")
                if parts.path.endswith("/v1/ping"):
                    return self._send(200, PLAIN, b"picosurf-proxy 1\n")
                if not parts.path.endswith("/v1/get"):
                    return self._send(404, PLAIN, b"Not found\n")
                url, as_ = q.get("url", ""), q.get("as")
                r = proxy.routes.get((url, as_)) or proxy.routes.get((url, None))
                if r is None:
                    return self._send(502, PLAIN, b"Site returned 404 Not Found\n", {"X-Upstream-Status": "404"})
                if r["delay"]:
                    time.sleep(r["delay"])
                extra = {"X-Final-Url": r["final"] or url}
                if r["ctype"].startswith("text/gemini"):
                    extra["X-Mode"] = r["mode"] or (as_ or "reader")
                if r["title"]:
                    extra["X-Title"] = r["title"]
                if r["feed"]:
                    extra["X-Feed-Url"] = r["feed"]
                self._send(r["status"], r["ctype"], r["body"], extra)

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        return self

    @property
    def url(self):
        return f"http://127.0.0.1:{self._server.server_address[1]}"

    def stop(self):
        self._server.shutdown()
        self._server.server_close()


def jpeg_bytes(w=200, h=120):
    """A baseline JPEG, as the real proxy sends."""
    from PIL import Image
    buf = io.BytesIO()
    Image.new("RGB", (w, h), (30, 120, 200)).save(buf, "JPEG", quality=80, progressive=False)
    return buf.getvalue()
```

- [ ] **Step 2: Write the fixture**

`tests/e2e/conftest.py`:
```python
"""PicoSurf in the PicoDeck simulator, talking to a fake proxy.

Uses PicoDeck's E2E harness from $PICODECK_ROOT (default
~/Projects/PicoDeck/picodeck); the simulator binary is $PICODECK_SIM_BINARY or
that checkout's build_sim/picodeck_simulator (make simulator there)."""
import json
import os
import shutil
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
PICODECK = Path(os.environ.get("PICODECK_ROOT", Path.home() / "Projects" / "PicoDeck" / "picodeck"))
sys.path.insert(0, str(PICODECK / "tests" / "e2e"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from picodeck_simulator import PicodeckSimulator  # noqa: E402
from fake_proxy import FakeProxy  # noqa: E402

APP, APP_ID = "picosurf", "net.picodeck.picosurf"
APP_FILES = ("app.json", "main.lua", "src")


def stage_app(dest: Path):
    dest.mkdir(parents=True, exist_ok=True)
    for name in APP_FILES:
        src = REPO / name
        if src.is_dir():
            shutil.copytree(src, dest / name, dirs_exist_ok=True)
        else:
            shutil.copy(src, dest / name)


@pytest.fixture
def picosurf(tmp_path):
    """start(config=True) -> (sim, proxy, data_dir). With config, the app's
    config.json points at a fresh FakeProxy; routes can be added after start
    (they are looked up per request)."""
    started = []

    def start(config=True):
        proxy = FakeProxy().start()
        sd = tmp_path / f"sd{len(started)}"
        stage_app(sd / "apps" / APP)
        data = sd / "data" / APP_ID
        (data / "feeds").mkdir(parents=True, exist_ok=True)
        if config:
            (data / "config.json").write_text(json.dumps({"proxy_url": proxy.url, "token": proxy.token}))
        sim = PicodeckSimulator(binary_path=os.environ.get("PICODECK_SIM_BINARY"),
                                sd_card_path=str(sd), test_mode=True)
        sim.start()
        started.append((sim, proxy))
        return sim, proxy, data

    yield start
    for sim, proxy in started:
        sim.stop()
        proxy.stop()
```

- [ ] **Step 3: Write the smoke tests**

`tests/e2e/test_app.py`:
```python
"""PicoSurf smoke flows in the simulator against a fake proxy: the real
picocalc API under the app's own logic (which the host tests cover in depth)."""
import json
import re

from conftest import APP
from fake_proxy import jpeg_bytes

A = "# A\n\nSee B [1].\n=> https://b.test/ [1] B\n=> https://a.test/cat.jpg [IMG] Cat\n"
FEED = "# Blog\n\n=> https://blog.test/1 2026-10-13 One\n=> https://blog.test/2 2026-10-12 Two\n"


def mark(sim):
    """The sequence number after the newest log line: wait() from here sees
    only what the next action causes, never an older line that matches."""
    lines = sim.get_log_lines()
    return (lines[-1]["seq"] + 1) if lines else 0


def wait(sim, pattern, since=0, timeout=15):
    return sim.wait_for_log(pattern, timeout=timeout, since_seq=since, src="lua")


def no_lua_errors(sim):
    errors = [l["text"] for l in sim.get_log_lines() if l.get("src") == "err"]
    assert not errors, errors


def act(sim, *keys):
    """Press keys; returns the log mark taken before them."""
    m = mark(sim)
    for k in keys:
        sim.keypress(k)
    return m


def go(sim, text):
    """F1, wait until the text box is open, type, Enter. Returns the mark
    taken before F1."""
    m = act(sim, "f1")
    wait(sim, r"picosurf: prompt go", m)
    for c in text:
        sim.keypress(c)
    sim.keypress("enter")
    return m


def start_app(sim):
    m = mark(sim)
    sim.launch_app(APP)
    return m


def test_first_run_opens_settings(picosurf):
    sim, _, _ = picosurf(config=False)
    wait(sim, r"picosurf: screen settings", start_app(sim))
    no_lua_errors(sim)


def test_open_follow_back_and_bookmark(picosurf):
    sim, proxy, data = picosurf()
    proxy.add("https://a.test/", A, title="A")
    proxy.add("https://b.test/", "# B\n", title="B")
    wait(sim, r"picosurf: screen home", start_app(sim))
    wait(sim, r"picosurf: loaded https://a\.test/ mode=reader links=2", go(sim, "a.test/"))
    wait(sim, r"picosurf: loaded https://b\.test/", act(sim, "tab", "enter"))
    wait(sim, r"picosurf: loaded https://a\.test/", act(sim, "backspace"))
    assert sum(1 for path, q in proxy.requests if q.get("url") == "https://a.test/") == 1, "back used the cache"
    wait(sim, r"picosurf: bookmark add https://a\.test/", act(sim, "f3"))
    bookmarks = json.loads((data / "bookmarks.json").read_text())
    assert bookmarks[0]["url"] == "https://a.test/"
    no_lua_errors(sim)


def test_image_opens_full_screen(picosurf):
    sim, proxy, _ = picosurf()
    proxy.add("https://a.test/", A, title="A")
    proxy.add("https://a.test/cat.jpg", jpeg_bytes(200, 120), ctype="image/jpeg")
    wait(sim, r"picosurf: screen home", start_app(sim))
    wait(sim, r"picosurf: loaded https://a\.test/", go(sim, "a.test/"))
    wait(sim, r"picosurf: image w=200 h=120", act(sim, "tab", "tab", "enter"))
    wait(sim, r"picosurf: screen page", act(sim, "esc"))
    no_lua_errors(sim)


def test_subscribe_and_read(picosurf):
    sim, proxy, data = picosurf()
    proxy.add("https://blog.test/", "# Blog\n", title="Blog", feed="https://blog.test/feed.xml")
    proxy.add("https://blog.test/", FEED, as_="feed", title="Blog", mode="feed", final="https://blog.test/feed.xml")
    proxy.add("https://blog.test/1", "# One\n", title="One")
    wait(sim, r"picosurf: screen home", start_app(sim))
    wait(sim, r"picosurf: loaded https://blog\.test/", go(sim, "blog.test/"))
    wait(sim, r"picosurf: subscribed 1 https://blog\.test/feed\.xml unread=2", act(sim, "f5"))
    wait(sim, r"picosurf: screen home", act(sim, "f2"))
    wait(sim, r"picosurf: feed 1 unread=2", act(sim, "enter"))
    wait(sim, r"picosurf: feed 1 unread=1", act(sim, "tab", "enter"))
    index = json.loads((data / "feeds" / "index.json").read_text())
    assert index["feeds"][0]["unread"] == 1
    no_lua_errors(sim)


def test_proxy_errors_show(picosurf):
    sim, _, _ = picosurf()
    wait(sim, r"picosurf: screen home", start_app(sim))
    line = wait(sim, r"picosurf: error 502 ", go(sim, "missing.test/"))
    assert re.search(r"Site returned 404 Not Found", line)
    no_lua_errors(sim)
```

- [ ] **Step 4: Run the smoke tests**

Run: `make e2e`
Expected: 5 passed.

This needs the simulator binary. If `$PICODECK_ROOT/build_sim/picodeck_simulator` is missing, build it with `make simulator` in the picodeck checkout.

If a test fails because the real API differs from `tests/fakepc.lua` (an event field, a return value, a header name):
1. Fix the app.
2. Fix the fake to match the real API.
3. Add a host test for that difference.

List every such difference in your report: they are the reason this task exists.

- [ ] **Step 5: Commit**

```bash
git add tests/e2e
git commit -m "test(app): simulator smoke flows against a fake proxy"
```

---

### Task 13: Release workflow, README and hardware checklist

**Files:**
- Create: `.github/workflows/release.yml`, `README.md`, `docs/hardware-pass.md`

**Interfaces:**
- Consumes: the app files `app.json`, `main.lua` and `src/`, and the existing `proxy/README.md`.
- Produces: tags matching `v*` build `picosurf-<tag>.zip`, with `app.json`, `main.lua` and `src/` at the archive root, and publish it as a GitHub Release.

- [ ] **Step 1: Write the release workflow**

`.github/workflows/release.yml`:
```yaml
name: Release
on:
  push:
    tags: ["v*"]
permissions:
  contents: write
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Unit tests
        run: |
          sudo apt-get install -y lua5.4 > /dev/null
          lua5.4 tests/run.lua
      - name: Check app.json version matches the tag
        run: |
          TAG="${GITHUB_REF_NAME#v}"
          VER="$(python3 -c 'import json; print(json.load(open("app.json"))["version"])')"
          [ "$VER" = "$TAG" ] || { echo "app.json version $VER does not match tag $TAG"; exit 1; }
      - name: Package
        run: zip -9 -r "picosurf-${GITHUB_REF_NAME}.zip" app.json main.lua src
      - uses: softprops/action-gh-release@v2
        with:
          files: picosurf-*.zip
          generate_release_notes: true
```

- [ ] **Step 2: Check the packaging locally**

Run: `rm -f /tmp/ps.zip && zip -9 -r /tmp/ps.zip app.json main.lua src > /dev/null && unzip -l /tmp/ps.zip | head -8`
Expected: `app.json` and `main.lua` listed at the root, with no folder prefix, and `src/` files below them.

- [ ] **Step 3: Write `README.md`**

````markdown
# PicoSurf

Read the web and RSS/Atom feeds on a [PicoDeck](https://picodeck.net) PicoCalc. Pages come through your own **PicoSurf proxy**, which does the heavy lifting:
- fetches the page
- extracts the article with Mozilla Readability
- turns it into plain-ASCII gemtext the PicoCalc can draw
- shrinks images to fit the screen

## Set up
1. Deploy the proxy: see [proxy/README.md](proxy/README.md), for Cloudflare Workers or Docker.
2. Install PicoSurf from the PicoDeck App Store.
3. On first launch, PicoSurf opens Settings. Enter the proxy URL and token there, then choose **Test connection**. You can also put the URL and token in `/data/net.picodeck.picosurf/config.json` from a computer, as `{"proxy_url": "...", "token": "..."}`.

## Keys
| Key | On a page | On Home |
|---|---|---|
| Up / Down | scroll a row | move in the list |
| Left / Right, Space | page up / down | switch tab |
| Tab / Shift+Tab | select the next / previous link on screen | |
| Enter | open the selected link | open |
| digits, then Enter | open link `[n]` | |
| Backspace / Esc | back (Esc on the first page: Home) | Esc: quit, or stop a refresh |
| F1 | go to a URL | go to a URL |
| F2 | Home | |
| F3 | bookmark / remove bookmark | |
| F4 | reader / full page | |
| F5 | subscribe to the page's feed | refresh all feeds (Feeds tab) |
| Del | | remove the selected entry |

The system menu has Reload, Edit URL, Mark all read and Settings.

## Development
- `make test`: Lua unit tests under stock Lua and under `lua32`, which has the device's 32-bit numbers. Building `lua32` needs a PicoDeck checkout; set `PICODECK_ROOT`.
- `make e2e`: smoke tests in the PicoDeck simulator against a fake proxy. Run `make simulator` in the PicoDeck checkout first.
- The proxy has its own tests: `cd proxy && npm test`.
- Releases: bump `version` in `app.json`, then tag `v<version>`. CI builds the store ZIP.

## Later
- Native Gemini and Gopher. Gemini needs a firmware call that returns the server certificate's fingerprint, for trust-on-first-use (TOFU).
- A longer `ui.textInput` limit, so "Edit URL" works on article URLs over 127 characters.
- Web search, saving pages offline, OPML import, inline images, non-Latin fonts.
````

- [ ] **Step 4: Write `docs/hardware-pass.md`**

```markdown
# Hardware pass (spec 7.2)

Run this on a real PicoCalc with PicoDeck 0.5.0 or later, against the deployed Worker. Record the results in the release notes.

1. Fresh install: PicoSurf opens Settings. Enter the proxy URL and token. **Test connection** shows "Proxy OK".
2. F1 `en.wikipedia.org/wiki/Gemini_(protocol)`. Time from Enter to the first screen: ______ s (target under 5 s on home WiFi).
3. On that page: scroll to the end with Right, check the footer reaches 100%, then follow a link by number and by Tab, and go Back.
4. Every page on the proxy's smoke list (`proxy/scripts/smoke.ts`) opens without a Lua error.
5. F3 bookmark, F2 Home, open it from Bookmarks. F4 switches reader and full mode.
6. Open an article with images. An `[IMG]` link opens the picture centred, and Esc returns.
7. F5 on jvns.ca subscribes. Subscribe to 9 more feeds (the smoke list's feeds, plus others).
8. On the Feeds tab, F5 refreshes all 10. Time: ______ s (target under 20 s). Opening an article lowers its unread count.
9. Memory: after the largest page, the dev console's memory figure shows more than 1 MB of Lua heap free: ______.
10. With WiFi off, opening a page shows "Connecting to WiFi..." and Esc goes Home. Feeds, bookmarks and history still list.
11. Reboot: bookmarks, history, feeds and read marks are all still there.

Report any missed target as-is; don't round it.
```

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/release.yml README.md docs/hardware-pass.md
git commit -m "docs(app): release workflow, README and hardware checklist"
```
