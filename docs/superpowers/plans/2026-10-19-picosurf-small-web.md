# PicoSurf Small Web (Gemini and Gopher) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PicoSurf reads Gemini and Gopher natively on the device, with certificate pinning, no proxy needed for them, search from Go, starter bookmarks and gemlog feeds.

**Architecture:** Pure modules turn text into ASCII gemtext (`fold`, `textflow`) and speak the protocols (`gemini`, `gopher`); `tofu` pins certificates; `tcpfetch` runs one request over `picocalc.tcp`; `native` follows redirects and pins per hop. `App:request` dispatches by scheme and returns the same result kinds the proxy path does, so the page view, cache, Back, history and feeds work unchanged; two new result kinds (`input`, `certchanged`) get a prompt and a review screen.

**Tech Stack:** Lua 5.4 (the device runs 32-bit integers; `build/lua32` mirrors it), the picosurf host test runner (`tests/run.lua`, `tests/t.lua`, `tests/fakepc.lua`), pytest e2e against the PicoDeck simulator.

**Spec:** `docs/superpowers/specs/2026-10-17-picosurf-small-web-design.md` (amends `docs/superpowers/specs/2026-10-15-picosurf-design.md`). The firmware half (`tcp:peerFingerprint()`) is a separate plan: `docs/superpowers/plans/2026-10-19-picodeck-tcp-peer-fingerprint.md`. Tasks 1-10 and 12 do not need it; Task 11's Gemini e2e tests do.

**Verified before writing:** every task below was replayed as its own commit in a scratch copy of `main` at 1780495: after each commit `make test` passed under both Luas (238, 242, 250, 266, 275, 283, 294, 305, 320, 328, 328, 328 tests), and Task 11's 13 e2e tests passed against a simulator built with the firmware plan's changes.

## Global Constraints

- Repo `/home/keith/Projects/PicoDeck/picosurf`. Work on branch `feat/small-web` off `main`; never commit to `main` directly.
- Every host test passes under both `lua` and `build/lua32` (`make test`); build `build/lua32` with `make build/lua32` if it is missing.
- `src/` uses only what the device's Lua has: `base`, `table`, `string`, `math`, `coroutine`, `utf8`, and the sandboxed `require`. No `io`, `os` or `package`.
- Firmware callbacks (TCP and HTTP) only record: `tcpfetch`'s callbacks hand results to `native`, which posts them to the app's inbox; no file I/O, screen change or new request happens inside a callback.
- Everything drawn is ASCII 0x20-0x7E (`fold.lua`).
- User-visible messages are copied exactly from the task code (they follow spec section 11).
- Commit messages: `feat: ...`, `test: ...`, `docs: ...`, using the user's git config and no attribution lines. The repo has no remote: never push.

## Rulings (where the plan settles what the spec leaves open)

1. `Image too large to show (<w>x<h>)` uses `x`, not `×`: the fonts are ASCII.
2. Spec 4.1's "the hop count carries over" is not implemented: neither the proxy nor Gopher redirects back into Gemini, so no loop can cross schemes.
3. A connection that fails after connecting for a reason other than a timeout shows `Connection to <host> was lost` (spec 11 is silent).
4. An empty Search setting is saved as `"off"`, because `picocalc.config` drops empty strings.
5. Native pages' footer ends at the percentage, with no trailing space.
6. A Gemini `20` with an empty meta is `text/gemini` (the Gemini default); a `3x` with an empty meta is `Not a Gemini response`.
7. Gopher `h` items with a `URL:` selector link straight to that URL; a `h` item requested directly is reflowed as text.
8. Spec 12.2's "the pinning tests skip when the simulator returns no fingerprint" is replaced by a prerequisite: the simulator fix that lets the Gemini tests connect at all (`setInsecure` honoured) ships with `peerFingerprint()` in the same firmware change, so Task 11 requires that simulator rather than skipping.

## Review Focus

1. A 300 KB gemtext line folds whole and fast (Task 4, `a_300_kb_line_folds_whole`).
2. A body of random bytes becomes printable ASCII, tabs and newlines only (Task 4, `random_bytes_fold_to_printable_text`).
3. A server that never closes waits for the firmware's 20 s read timeout and then reads `<host> stopped responding` (Task 7, `a_server_that_never_closes_waits`; Task 8, `transport_failures_read_plainly`).
4. Gopher menus with CRLF, bare LF, or no `.` terminator read the same (Task 5, `menu_lines_with_bare_lf_and_no_terminator`).
5. A redirect to itself stops after 5 hops with `Too many redirects` (Task 8, `redirects_are_followed_up_to_five_hops`).

---

### Task 1: ASCII folding (`src/fold.lua`)

**Files:**
- Create: `src/fold.lua`
- Create: `tests/test_fold.lua`

**Interfaces:**
- Produces: `fold.decode(s, charset) -> string` (valid UTF-8; Latin-1/Windows-1252 when `charset` names one or `s` is not valid UTF-8); `fold.line(s) -> string` (one line of decoded text as ASCII; tab kept, other controls and CR removed); `fold.url(s) -> string` (non-ASCII bytes, spaces and controls percent-encoded).

- [ ] **Step 1: Write the failing test**

Create `tests/test_fold.lua`:

````lua
local T = require("tests.t")
local fold = require("src.fold")

local function f(s, charset) return fold.line(fold.decode(s, charset)) end

return {
    ascii_passes_through_and_controls_go = function()
        T.eq(f("plain text"), "plain text")
        T.eq(f("a\tb\rc\0d\27e\127"), "a\tbcde")
    end,
    punctuation_follows_the_proxy_table = function()
        T.eq(f("\u{201C}Hi\u{201D} \u{2018}x\u{2019}"), "\"Hi\" 'x'")
        T.eq(f("a\u{2014}b \u{2013} c\u{2026}"), "a--b - c...")
        T.eq(f("\u{2022} 5\u{00D7}3 \u{2192} \u{00A9} \u{20AC}"), "* 5x3 -> (c) EUR")
        T.eq(f("x\u{00A0}y\u{2009}z"), "x y z")
    end,
    accented_letters_lose_their_marks = function()
        T.eq(f("Caf\u{00E9} Stra\u{00DF}e \u{0152}uvre \u{0141}\u{00F3}d\u{017A}"), "Cafe Strasse OEuvre Lodz")
        T.eq(f("e\u{0301}"), "e") -- a combining accent
        T.eq(f("\u{FB01}ne"), "fine")
    end,
    box_drawing_keeps_its_shape = function()
        T.eq(f("\u{250C}\u{2500}\u{2500}\u{2510}"), "+--+")
        T.eq(f("\u{2502} x \u{2551}"), "| x |")
        T.eq(f("\u{2571}\u{2572}\u{2573}"), "/\\X")
        T.eq(f("\u{2588}\u{2593}\u{2591}"), "###")
    end,
    emoji_and_joiners_are_removed = function()
        T.eq(f("hi \u{1F600}!"), "hi !")
        T.eq(f("\u{1F468}\u{200D}\u{1F469} \u{2764}\u{FE0F}"), " ")
        T.eq(f("soft\u{00AD}hyphen"), "softhyphen")
    end,
    other_scripts_become_question_marks = function()
        T.eq(f("\u{65E5}\u{672C} \u{03B1}\u{03B2}"), "?? ??")
    end,
    invalid_utf8_reads_as_latin1 = function()
        T.eq(fold.decode("caf\233"), "caf\u{00E9}")
        T.eq(f("caf\233 \147q\148"), "cafe \"q\"") -- Windows-1252 quotes
        T.eq(f("\195\169"), "e") -- valid UTF-8 stays UTF-8
    end,
    a_latin1_charset_reads_every_byte_as_latin1 = function()
        T.eq(fold.decode("\195\169", "ISO-8859-1"), "\u{00C3}\u{00A9}")
        T.eq(fold.decode("ascii only", "latin1"), "ascii only")
    end,
    url_percent_encodes_what_cannot_be_sent = function()
        T.eq(fold.url("gemini://x.test/caf\195\169 b"), "gemini://x.test/caf%C3%A9%20b")
        T.eq(fold.url("gemini://x.test/a?b=c"), "gemini://x.test/a?b=c")
    end,
}
````

- [ ] **Step 2: Run it to see it fail**

Run: `lua tests/run.lua tests/test_fold.lua`
Expected: FAIL, "module 'src.fold' not found".

- [ ] **Step 3: Write the module**

Create `src/fold.lua` (the letter table is Unicode's NFKD of U+00C0-017F and U+FB00-FB06 with marks stripped, as the proxy computes it; the ten letters NFKD leaves alone, such as `Ħ`, map to their plain letter):

````lua
-- Text to ASCII for the device's fonts (small web spec 8.1): UTF-8 or
-- Latin-1 in, 0x20-0x7E plus tab out. The proxy folds web pages (main spec
-- 5.6); Gemini and Gopher text is folded here, line by line. Pure.
local M = {}

-- The proxy's table (ascii.ts), by code point.
local PUNCT = {
    [0x2018] = "'", [0x2019] = "'", [0x201A] = "'", [0x201B] = "'", [0x2032] = "'",
    [0x201C] = '"', [0x201D] = '"', [0x201E] = '"', [0x201F] = '"', [0x2033] = '"',
    [0xAB] = "<<", [0xBB] = ">>", [0x2039] = "<", [0x203A] = ">",
    [0x2010] = "-", [0x2011] = "-", [0x2012] = "-", [0x2013] = "-", [0x2212] = "-",
    [0x2014] = "--", [0x2015] = "--",
    [0x2026] = "...", [0x2022] = "*", [0xB7] = "*", [0x2023] = "*", [0x25E6] = "*",
    [0x2192] = "->", [0x2190] = "<-", [0x2194] = "<->", [0x21D2] = "=>", [0x2191] = "^", [0x2193] = "v",
    [0x2264] = "<=", [0x2265] = ">=", [0x2260] = "!=", [0x2248] = "~",
    [0xD7] = "x", [0xF7] = "/",
    [0xA9] = "(c)", [0xAE] = "(R)", [0x2122] = "(TM)",
    [0x20AC] = "EUR", [0xA3] = "GBP", [0xA5] = "JPY", [0xA2] = "c",
    [0xB0] = " deg",
    [0xBD] = "1/2", [0xBC] = "1/4", [0xBE] = "3/4",
    [0xA1] = "!", [0xBF] = "?", [0xA7] = "S", [0xB6] = "P",
    [0x2020] = "+", [0x2021] = "++", [0x2030] = "%o", [0x192] = "f", [0x2C6] = "^", [0x2DC] = "~",
}

-- Latin-1 Supplement and Latin Extended-A letters, and the Latin ligatures:
-- the proxy's NFKD-and-strip-marks result, which Lua cannot compute.
local LETTERS = {
    [0xC0] = "A", [0xC1] = "A", [0xC2] = "A", [0xC3] = "A", [0xC4] = "A", [0xC5] = "A", [0xC6] = "AE", [0xC7] = "C",
    [0xC8] = "E", [0xC9] = "E", [0xCA] = "E", [0xCB] = "E", [0xCC] = "I", [0xCD] = "I", [0xCE] = "I", [0xCF] = "I",
    [0xD0] = "D", [0xD1] = "N", [0xD2] = "O", [0xD3] = "O", [0xD4] = "O", [0xD5] = "O", [0xD6] = "O", [0xD8] = "O",
    [0xD9] = "U", [0xDA] = "U", [0xDB] = "U", [0xDC] = "U", [0xDD] = "Y", [0xDE] = "Th", [0xDF] = "ss", [0xE0] = "a",
    [0xE1] = "a", [0xE2] = "a", [0xE3] = "a", [0xE4] = "a", [0xE5] = "a", [0xE6] = "ae", [0xE7] = "c", [0xE8] = "e",
    [0xE9] = "e", [0xEA] = "e", [0xEB] = "e", [0xEC] = "i", [0xED] = "i", [0xEE] = "i", [0xEF] = "i", [0xF0] = "d",
    [0xF1] = "n", [0xF2] = "o", [0xF3] = "o", [0xF4] = "o", [0xF5] = "o", [0xF6] = "o", [0xF8] = "o", [0xF9] = "u",
    [0xFA] = "u", [0xFB] = "u", [0xFC] = "u", [0xFD] = "y", [0xFE] = "th", [0xFF] = "y", [0x100] = "A", [0x101] = "a",
    [0x102] = "A", [0x103] = "a", [0x104] = "A", [0x105] = "a", [0x106] = "C", [0x107] = "c", [0x108] = "C", [0x109] = "c",
    [0x10A] = "C", [0x10B] = "c", [0x10C] = "C", [0x10D] = "c", [0x10E] = "D", [0x10F] = "d", [0x110] = "D", [0x111] = "d",
    [0x112] = "E", [0x113] = "e", [0x114] = "E", [0x115] = "e", [0x116] = "E", [0x117] = "e", [0x118] = "E", [0x119] = "e",
    [0x11A] = "E", [0x11B] = "e", [0x11C] = "G", [0x11D] = "g", [0x11E] = "G", [0x11F] = "g", [0x120] = "G", [0x121] = "g",
    [0x122] = "G", [0x123] = "g", [0x124] = "H", [0x125] = "h", [0x128] = "I", [0x129] = "i", [0x12A] = "I", [0x12B] = "i",
    [0x12C] = "I", [0x12D] = "i", [0x12E] = "I", [0x12F] = "i", [0x130] = "I", [0x131] = "i", [0x132] = "IJ", [0x133] = "ij",
    [0x134] = "J", [0x135] = "j", [0x136] = "K", [0x137] = "k", [0x139] = "L", [0x13A] = "l", [0x13B] = "L", [0x13C] = "l",
    [0x13D] = "L", [0x13E] = "l", [0x141] = "L", [0x142] = "l", [0x143] = "N", [0x144] = "n", [0x145] = "N", [0x146] = "n",
    [0x147] = "N", [0x148] = "n", [0x14C] = "O", [0x14D] = "o", [0x14E] = "O", [0x14F] = "o", [0x150] = "O", [0x151] = "o",
    [0x152] = "OE", [0x153] = "oe", [0x154] = "R", [0x155] = "r", [0x156] = "R", [0x157] = "r", [0x158] = "R", [0x159] = "r",
    [0x15A] = "S", [0x15B] = "s", [0x15C] = "S", [0x15D] = "s", [0x15E] = "S", [0x15F] = "s", [0x160] = "S", [0x161] = "s",
    [0x162] = "T", [0x163] = "t", [0x164] = "T", [0x165] = "t", [0x168] = "U", [0x169] = "u", [0x16A] = "U", [0x16B] = "u",
    [0x16C] = "U", [0x16D] = "u", [0x16E] = "U", [0x16F] = "u", [0x170] = "U", [0x171] = "u", [0x172] = "U", [0x173] = "u",
    [0x174] = "W", [0x175] = "w", [0x176] = "Y", [0x177] = "y", [0x178] = "Y", [0x179] = "Z", [0x17A] = "z", [0x17B] = "Z",
    [0x17C] = "z", [0x17D] = "Z", [0x17E] = "z", [0x17F] = "s", [0xFB00] = "ff", [0xFB01] = "fi", [0xFB02] = "fl", [0xFB03] = "ffi",
    [0xFB04] = "ffl", [0xFB05] = "st", [0xFB06] = "st",
    [0x126] = "H", [0x127] = "h", [0x138] = "k", [0x13F] = "L", [0x140] = "l", [0x149] = "'n", [0x14A] = "N", [0x14B] = "n",
    [0x166] = "T", [0x167] = "t",
}

-- Box drawing (U+2500-257F) by shape; the rest of the block are joins.
local HORIZONTAL = {
    [0x2500] = true, [0x2501] = true, [0x2504] = true, [0x2505] = true, [0x2508] = true, [0x2509] = true,
    [0x254C] = true, [0x254D] = true, [0x2550] = true, [0x2574] = true, [0x2576] = true, [0x2578] = true,
    [0x257A] = true, [0x257C] = true, [0x257E] = true,
}
local VERTICAL = {
    [0x2502] = true, [0x2503] = true, [0x2506] = true, [0x2507] = true, [0x250A] = true, [0x250B] = true,
    [0x254E] = true, [0x254F] = true, [0x2551] = true, [0x2575] = true, [0x2577] = true, [0x2579] = true,
    [0x257B] = true, [0x257D] = true, [0x257F] = true,
}
local DIAGONAL = { [0x2571] = "/", [0x2572] = "\\", [0x2573] = "X" }

-- Windows-1252's printable 0x80-0x9F, which Latin-1 text from Gopher often is.
local CP1252 = {
    [0x80] = 0x20AC, [0x82] = 0x201A, [0x84] = 0x201E, [0x85] = 0x2026, [0x86] = 0x2020, [0x87] = 0x2021,
    [0x89] = 0x2030, [0x8B] = 0x2039, [0x91] = 0x2018, [0x92] = 0x2019, [0x93] = 0x201C, [0x94] = 0x201D,
    [0x95] = 0x2022, [0x96] = 0x2013, [0x97] = 0x2014, [0x99] = 0x2122, [0x9B] = 0x203A,
}

local LATIN1 = {
    ["iso-8859-1"] = true, ["iso_8859-1"] = true, ["latin1"] = true, ["latin-1"] = true,
    ["windows-1252"] = true, ["cp1252"] = true,
}

local function space(cp)
    return cp == 0xA0 or cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200A) or cp == 0x202F or cp == 0x205F
        or cp == 0x3000
end

-- Combining marks, C1 controls, the soft hyphen, zero-width characters,
-- variation selectors, tags, and emoji and other pictographs.
local function removed(cp)
    return (cp >= 0x80 and cp <= 0x9F) or cp == 0xAD or (cp >= 0x300 and cp <= 0x36F)
        or (cp >= 0x200B and cp <= 0x200D) or cp == 0x2060 or cp == 0xFEFF or (cp >= 0xFE00 and cp <= 0xFE0F)
        or (cp >= 0x2600 and cp <= 0x27BF) or (cp >= 0x1F000 and cp <= 0x1FAFF)
        or (cp >= 0xE0020 and cp <= 0xE007F)
end

local function fold(cp)
    local s = PUNCT[cp] or LETTERS[cp]
    if s then return s end
    if space(cp) then return " " end
    if removed(cp) then return "" end
    if cp >= 0x2500 and cp <= 0x257F then
        if HORIZONTAL[cp] then return "-" end
        if VERTICAL[cp] then return "|" end
        return DIAGONAL[cp] or "+"
    end
    if cp >= 0x2580 and cp <= 0x259F then return "#" end
    return "?"
end

-- s as UTF-8: unchanged when it is valid UTF-8 and charset (a MIME charset
-- name, or nil) is not a Latin-1 one; otherwise every byte is read as
-- Windows-1252/Latin-1.
function M.decode(s, charset)
    if not s:find("[\128-\255]") then return s end
    if not LATIN1[(charset or ""):lower()] and utf8.len(s) then return s end
    return (s:gsub("[\128-\255]", function(c)
        local b = c:byte()
        return utf8.char(CP1252[b] or b)
    end))
end

-- One line of valid UTF-8 (from decode) folded to ASCII. Tabs stay; other
-- control characters, a CR included, go.
function M.line(s)
    s = s:gsub("[\0-\8\11-\31\127]", "")
    if not s:find("[\128-\255]") then return s end
    return (s:gsub("[\192-\247][\128-\191]*", function(ch) return fold(utf8.codepoint(ch)) end))
end

-- A URL with its non-ASCII bytes, spaces and control characters
-- percent-encoded, so it can be requested.
function M.url(s)
    return (s:gsub("[%c%s\128-\255]", function(c) return string.format("%%%02X", c:byte()) end))
end

return M
````

- [ ] **Step 4: Run the tests**

Run: `lua tests/run.lua tests/test_fold.lua && build/lua32 tests/run.lua tests/test_fold.lua`
Expected: `9 passed, 0 failed` under both.

- [ ] **Step 5: Commit**

```bash
git add src/fold.lua tests/test_fold.lua
git commit -m "feat: fold Gemini and Gopher text to ASCII on the device"
```

---

### Task 2: URL resolution (`src/url.lua`)

**Files:**
- Modify: `src/url.lua` (add `parts`, `resolve`, `withInput`)
- Create: `tests/test_url_resolve.lua`

**Interfaces:**
- Produces: `url.parts(u) -> {scheme, authority, host, port, path, query, fragment}` or nil (absolute URLs with an authority; `host` lower case without user info, `port` an integer or nil); `url.resolve(base, ref) -> string` or nil (RFC 3986 5.2); `url.withInput(u, text) -> string` (a Gemini URL's query, or a Gopher URL's `%09` search, replaced by `url.encode(text)`).

- [ ] **Step 1: Write the failing test**

Create `tests/test_url_resolve.lua` (every RFC 3986 section 5.4 example):

````lua
local T = require("tests.t")
local url = require("src.url")

local BASE = "http://a/b/c/d;p?q"
-- RFC 3986 5.4.1 and 5.4.2 (strict).
local CASES = {
    { "g:h", "g:h" }, { "g", "http://a/b/c/g" }, { "./g", "http://a/b/c/g" }, { "g/", "http://a/b/c/g/" },
    { "/g", "http://a/g" }, { "//g", "http://g" }, { "?y", "http://a/b/c/d;p?y" }, { "g?y", "http://a/b/c/g?y" },
    { "#s", "http://a/b/c/d;p?q#s" }, { "g#s", "http://a/b/c/g#s" }, { "g?y#s", "http://a/b/c/g?y#s" },
    { ";x", "http://a/b/c/;x" }, { "g;x", "http://a/b/c/g;x" }, { "g;x?y#s", "http://a/b/c/g;x?y#s" },
    { "", "http://a/b/c/d;p?q" }, { ".", "http://a/b/c/" }, { "./", "http://a/b/c/" }, { "..", "http://a/b/" },
    { "../", "http://a/b/" }, { "../g", "http://a/b/g" }, { "../..", "http://a/" }, { "../../", "http://a/" },
    { "../../g", "http://a/g" },
    { "../../../g", "http://a/g" }, { "../../../../g", "http://a/g" }, { "/./g", "http://a/g" },
    { "/../g", "http://a/g" }, { "g.", "http://a/b/c/g." }, { ".g", "http://a/b/c/.g" }, { "g..", "http://a/b/c/g.." },
    { "..g", "http://a/b/c/..g" }, { "./../g", "http://a/b/g" }, { "./g/.", "http://a/b/c/g/" },
    { "g/./h", "http://a/b/c/g/h" }, { "g/../h", "http://a/b/c/h" }, { "g;x=1/./y", "http://a/b/c/g;x=1/y" },
    { "g;x=1/../y", "http://a/b/c/y" }, { "g?y/./x", "http://a/b/c/g?y/./x" }, { "g?y/../x", "http://a/b/c/g?y/../x" },
    { "g#s/./x", "http://a/b/c/g#s/./x" }, { "g#s/../x", "http://a/b/c/g#s/../x" }, { "http:g", "http:g" },
}

return {
    resolve_follows_rfc_3986_examples = function()
        for _, c in ipairs(CASES) do T.eq(url.resolve(BASE, c[1]), c[2], c[1]) end
    end,
    resolve_against_gemini_bases = function()
        T.eq(url.resolve("gemini://g.test", "a.gmi"), "gemini://g.test/a.gmi")
        T.eq(url.resolve("gemini://g.test/log/", "2024/post.gmi"), "gemini://g.test/log/2024/post.gmi")
        T.eq(url.resolve("gemini://g.test/a/b.gmi", "/c"), "gemini://g.test/c")
        T.eq(url.resolve("gemini://g.test/a/", "gopher://h.test/1/x"), "gopher://h.test/1/x")
        T.eq(url.resolve("not a url", "x"), nil)
    end,
    parts_split_host_and_port = function()
        local p = url.parts("gemini://User@G.Test:1966/a/b?q=1#f")
        T.eq(p.scheme, "gemini"); T.eq(p.host, "g.test"); T.eq(p.port, 1966); T.eq(math.type(p.port), "integer")
        T.eq(p.path, "/a/b"); T.eq(p.query, "q=1"); T.eq(p.fragment, "f")
        p = url.parts("gemini://g.test")
        T.eq(p.host, "g.test"); T.eq(p.port, nil); T.eq(p.path, ""); T.eq(p.query, nil)
        T.eq(url.parts("g.test/a"), nil)
    end,
    with_input_sets_the_query_or_search = function()
        T.eq(url.withInput("gemini://g.test/search", "two words"), "gemini://g.test/search?two%20words")
        T.eq(url.withInput("gemini://g.test/s?old#x", "new"), "gemini://g.test/s?new")
        T.eq(url.withInput("gopher://h.test/7/v2/vs", "cats"), "gopher://h.test/7/v2/vs%09cats")
        T.eq(url.withInput("gopher://h.test/7/v2/vs%09dogs", "cats"), "gopher://h.test/7/v2/vs%09cats")
    end,
}
````

- [ ] **Step 2: Run it to see it fail**

Run: `lua tests/run.lua tests/test_url_resolve.lua`
Expected: FAIL, "attempt to call a nil value (field 'resolve')".

- [ ] **Step 3: Add the functions**

Apply this patch from the repo root (`git apply` reads it from standard input):

````diff
diff --git a/src/url.lua b/src/url.lua
index 49b18e1..98e4903 100644
--- a/src/url.lua
+++ b/src/url.lua
@@ -46,4 +46,96 @@ function M.parseBase(base)
     return { host = host, port = port, tls = scheme == "https", prefix = (path:gsub("/+$", "")) }
 end
 
+-- RFC 3986 appendix B: scheme (lower case), authority, path, query and
+-- fragment of a URL or relative reference. Absent parts are nil; path is
+-- always a string.
+local function split(u)
+    local scheme, rest = u:match("^(%a[%w+.%-]*):(.*)$")
+    if not scheme then rest = u end
+    local fragment, query, authority
+    local a, f = rest:match("^([^#]*)#(.*)$")
+    if a then rest, fragment = a, f end
+    a, f = rest:match("^([^?]*)%?(.*)$")
+    if a then rest, query = a, f end
+    local path = rest
+    if rest:sub(1, 2) == "//" then authority, path = rest:match("^//([^/]*)(.*)$") end
+    return { scheme = scheme and scheme:lower(), authority = authority, path = path, query = query, fragment = fragment }
+end
+
+-- RFC 3986 5.2.4.
+local function removeDots(input)
+    local out = {}
+    while input ~= "" do
+        if input:sub(1, 3) == "../" then
+            input = input:sub(4)
+        elseif input:sub(1, 2) == "./" then
+            input = input:sub(3)
+        elseif input:sub(1, 3) == "/./" then
+            input = input:sub(3)
+        elseif input == "/." then
+            input = "/"
+        elseif input:sub(1, 4) == "/../" then
+            input = input:sub(4)
+            table.remove(out)
+        elseif input == "/.." then
+            input = "/"
+            table.remove(out)
+        elseif input == "." or input == ".." then
+            input = ""
+        else
+            local seg = input:match("^/?[^/]*")
+            out[#out + 1] = seg
+            input = input:sub(#seg + 1)
+        end
+    end
+    return table.concat(out)
+end
+
+-- The parts of an absolute URL with an authority, plus host (lower case,
+-- without user info) and port (an integer, or nil when absent); nil otherwise.
+function M.parts(u)
+    local p = split(u)
+    if not p.scheme or not p.authority then return nil end
+    local auth = p.authority:gsub("^.*@", "")
+    local host, port = auth:match("^(.-):(%d*)$")
+    p.host = (host or auth):lower()
+    p.port = port and port ~= "" and math.tointeger(tonumber(port)) or nil
+    return p
+end
+
+-- ref resolved against the absolute URL base (RFC 3986 5.2), or nil when base
+-- has no scheme.
+function M.resolve(base, ref)
+    local B, R = split(base), split(ref)
+    if not B.scheme then return nil end
+    local t = { scheme = B.scheme, authority = B.authority, fragment = R.fragment }
+    if R.scheme then
+        t.scheme, t.authority, t.path, t.query = R.scheme, R.authority, removeDots(R.path), R.query
+    elseif R.authority then
+        t.authority, t.path, t.query = R.authority, removeDots(R.path), R.query
+    elseif R.path == "" then
+        t.path, t.query = B.path, R.query or B.query
+    else
+        if R.path:sub(1, 1) == "/" then
+            t.path = removeDots(R.path)
+        elseif B.authority and B.path == "" then
+            t.path = removeDots("/" .. R.path)
+        else
+            t.path = removeDots((B.path:match("^(.*/)") or "") .. R.path)
+        end
+        t.query = R.query
+    end
+    return t.scheme .. ":" .. (t.authority and ("//" .. t.authority) or "") .. t.path
+        .. (t.query and ("?" .. t.query) or "") .. (t.fragment and ("#" .. t.fragment) or "")
+end
+
+-- u asking again with the text a server asked for (small web spec 5): a
+-- Gemini URL's query replaced, a Gopher URL's search (after %09) replaced.
+function M.withInput(u, text)
+    local q = M.encode(text)
+    if M.scheme(u) == "gopher" then return (u:gsub("%%09.*$", "")) .. "%09" .. q end
+    local base = u:gsub("#.*$", ""):gsub("%?.*$", "")
+    return base .. "?" .. q
+end
+
 return M
````

- [ ] **Step 4: Run the tests**

Run: `lua tests/run.lua tests/test_url_resolve.lua tests/test_url.lua && build/lua32 tests/run.lua tests/test_url_resolve.lua tests/test_url.lua`
Expected: `12 passed, 0 failed` under both.

- [ ] **Step 5: Commit**

```bash
git add src/url.lua tests/test_url_resolve.lua
git commit -m "feat: resolve relative URLs (RFC 3986) and set a server's input"
```

---

### Task 3: Plain text to gemtext (`src/textflow.lua`)

**Files:**
- Create: `src/textflow.lua`
- Create: `tests/test_textflow.lua`

**Interfaces:**
- Consumes: `fold.line` (Task 1).
- Produces: `textflow.convert(utf8text) -> gemtext string` (spec 8.2: prose joined, short-line blocks kept, art in ``` blocks, gemtext markers escaped with a leading space); `textflow.SHORT = 45`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_textflow.lua`:

````lua
local T = require("tests.t")
local textflow = require("src.textflow")

local function lines(s)
    local t = {}
    for l in s:gmatch("([^\n]*)\n") do t[#t + 1] = l end
    return t
end

local PROSE = "The quick brown fox jumps over the lazy dog and keeps\n" ..
    "running far into the evening until it reaches home.\n"

return {
    prose_joins_into_one_line = function()
        T.eq(textflow.convert(PROSE), "The quick brown fox jumps over the lazy dog and keeps running far into "
            .. "the evening until it reaches home.\n")
    end,
    blocks_are_separated_by_one_blank_line = function()
        local out = lines(textflow.convert(PROSE .. "\n\n\n" .. PROSE))
        T.eq(#out, 3); T.eq(out[2], "")
    end,
    bullets_start_new_lines_inside_prose = function()
        local text = "These are the things this long paragraph lists for you today:\n" ..
            "* the first thing, which is long enough to wrap\n" ..
            "  and its second line\n" ..
            "- another thing\n12. a numbered thing\n"
        local out = lines(textflow.convert(text))
        T.eq(out[1], "These are the things this long paragraph lists for you today:")
        T.eq(out[2], "* the first thing, which is long enough to wrap and its second line")
        T.eq(out[3], "- another thing"); T.eq(out[4], "12. a numbered thing")
    end,
    short_lines_keep_their_breaks = function()
        local out = lines(textflow.convert("Roses are red,\nviolets are blue,\n  sugar is sweet\n"))
        T.eq(#out, 3); T.eq(out[1], "Roses are red,"); T.eq(out[3], "sugar is sweet")
    end,
    art_stays_monospace = function()
        local table = "Name        Size   Date\n" .. "file.txt    12 KB  2024-01-01 and more words to make it long\n"
        T.eq(textflow.convert(table), "```\n" .. table .. "```\n")
        local rule = "A heading with a rule under it that is fairly long\n==========\n"
        T.eq(lines(textflow.convert(rule))[1], "```")
        local box = "\u{250C}\u{2500}\u{2510} a box in a line that is more than long enough\n"
        T.eq(textflow.convert(box), "```\n+-+ a box in a line that is more than long enough\n```\n")
        local code = "    for i in range(10):\n        print(i, 'is a number we print out here')\n"
        T.eq(lines(textflow.convert(code))[2], "    for i in range(10):")
    end,
    gemtext_markers_are_escaped = function()
        local out = lines(textflow.convert("# not a heading\n=> not a link\n> not a quote\n"))
        T.eq(out[1], " # not a heading"); T.eq(out[2], " => not a link"); T.eq(out[3], " > not a quote")
        T.eq(lines(textflow.convert("```\n"))[1], " ```")
        T.eq(lines(textflow.convert("````````\n"))[2], " ````````") -- art keeps it, escaped
    end,
    tabs_cr_and_trailing_spaces = function()
        T.eq(textflow.convert("a\tb\r\nc   \r\n"), "```\na    b\nc\n```\n")
        T.eq(textflow.convert("one\r\ntwo\r\n"), "one\ntwo\n")
    end,
    text_is_folded = function()
        T.eq(textflow.convert("Caf\u{00E9} \u{2014} ok\n"), "Cafe -- ok\n")
    end,
}
````

- [ ] **Step 2: Run it to see it fail**

Run: `lua tests/run.lua tests/test_textflow.lua`
Expected: FAIL, "module 'src.textflow' not found".

- [ ] **Step 3: Write the module**

Create `src/textflow.lua`:

````lua
-- Plain text to gemtext (small web spec 8.2): prose is reflowed into the
-- reading font, art and tables stay monospace. In: UTF-8 (fold.decode).
-- Out: folded ASCII gemtext. Pure.
local fold = require("src.fold")

local M = {}
M.SHORT = 45 -- a block whose lines are all shorter keeps its line breaks

-- Lines without their CR, trailing spaces or tabs (4 spaces each).
local function splitLines(text)
    local out = {}
    if text:sub(-1) ~= "\n" then text = text .. "\n" end
    for l in text:gmatch("([^\n]*)\n") do
        out[#out + 1] = (l:gsub("\t", "    "):gsub("%s+$", ""))
    end
    return out
end

-- Box drawing, block elements or geometric shapes (U+2500-25BF), before folding.
local function hasBox(l)
    return l:find("\226[\148-\150]") ~= nil
end

local function isArt(block)
    local allIndented = true
    for _, l in ipairs(block) do
        if hasBox(l) then return true end
        local first = l:find("%S")
        if first and l:find("   ", first, true) then return true end
        if l:find("([^%w%s])%1%1%1") then return true end
        if not l:find("^%s") then allIndented = false end
    end
    return allIndented
end

local function isShort(block)
    for _, l in ipairs(block) do
        if (utf8.len(l) or #l) >= M.SHORT then return false end
    end
    return true
end

-- A folded text line that gemtext reads as text: lines that would be a link,
-- heading, quote or preformatting toggle get a leading space.
local function textLine(l)
    l = fold.line(l)
    if l:find("^=>") or l:find("^#") or l:find("^>") or l:find("^```") then return " " .. l end
    return l
end

local function addBlock(out, block)
    if isArt(block) then
        out[#out + 1] = "```"
        for _, l in ipairs(block) do
            l = fold.line(l)
            out[#out + 1] = l:find("^```") and (" " .. l) or l
        end
        out[#out + 1] = "```"
    elseif isShort(block) then
        for _, l in ipairs(block) do out[#out + 1] = textLine(l:match("^%s*(.*)$")) end
    else
        local cur
        for _, l in ipairs(block) do
            local t = l:match("^%s*(.*)$")
            if cur and not t:find("^[%*%-%+] ") and not t:find("^%d+%. ") then
                cur = cur .. " " .. t
            else
                if cur then out[#out + 1] = textLine(cur) end
                cur = t
            end
        end
        if cur then out[#out + 1] = textLine(cur) end
    end
end

function M.convert(text)
    local out, block = {}, {}
    local function flush()
        if #block == 0 then return end
        if #out > 0 then out[#out + 1] = "" end
        addBlock(out, block)
        block = {}
    end
    for _, l in ipairs(splitLines(text)) do
        if l:find("%S") then block[#block + 1] = l else flush() end
    end
    flush()
    return table.concat(out, "\n") .. "\n"
end

return M
````

- [ ] **Step 4: Run the tests**

Run: `lua tests/run.lua tests/test_textflow.lua && build/lua32 tests/run.lua tests/test_textflow.lua`
Expected: `8 passed, 0 failed` under both.

- [ ] **Step 5: Commit**

```bash
git add src/textflow.lua tests/test_textflow.lua
git commit -m "feat: reflow plain text into gemtext, keeping art monospace"
```

---

### Task 4: The Gemini protocol (`src/gemini.lua`)

**Files:**
- Create: `src/gemini.lua`
- Create: `tests/test_gemini.lua`

**Interfaces:**
- Consumes: `url.parts`, `url.resolve` (Task 2); `fold.decode`, `fold.line`, `fold.url` (Task 1); `textflow.convert` (Task 3).
- Produces: `gemini.request(target) -> {host, port, url, line}` or nil, reason; `gemini.header(data) -> status, meta, body` or nil; `gemini.rewrite(text, base) -> gemtext`; `gemini.feed(text, base) -> list, title` or nil; `gemini.interpret(req, data, as) -> result` where result is `{kind = "gemini", body, finalUrl, title?, mode = "native"}`, `{kind = "image", body, native = true, finalUrl}`, `{kind = "input", prompt, sensitive, url}`, `{kind = "redirect", url}` or `{kind = "error", message}`. `as == "feed"` gives the gemlog list.

- [ ] **Step 1: Write the failing test**

Create `tests/test_gemini.lua` (Review Focus 1 and 2 are the `a_300_kb_line_folds_whole` and `random_bytes_fold_to_printable_text` cases):

````lua
local T = require("tests.t")
local gemini = require("src.gemini")

local REQ = assert(gemini.request("gemini://g.test/dir/page.gmi"))

local function interpret(data, as) return gemini.interpret(REQ, data, as) end

return {
    request_normalises_the_url = function()
        local r = gemini.request("gemini://G.Test")
        T.eq(r.host, "g.test"); T.eq(r.port, 1965); T.eq(r.url, "gemini://g.test/"); T.eq(r.line, "gemini://g.test/\r\n")
        r = gemini.request("gemini://g.test:1965/a?b#frag")
        T.eq(r.url, "gemini://g.test/a?b")
        r = gemini.request("gemini://g.test:7000/")
        T.eq(r.port, 7000); T.eq(r.url, "gemini://g.test:7000/")
    end,
    request_refuses_bad_urls = function()
        local r, err = gemini.request("gemini://g.test/" .. string.rep("a", 1010))
        T.eq(r, nil); T.eq(err, "URL too long for Gemini")
        T.eq(select(2, gemini.request("https://g.test/")), "Not a Gemini URL")
        T.eq(select(2, gemini.request("gemini:///x")), "Not a Gemini URL")
        T.eq(select(2, gemini.request("gemini://g.test:70000/")), "Not a Gemini URL")
    end,
    header_parsing = function()
        local s, meta, body = gemini.header("20 text/gemini\r\n# Hi\n")
        T.eq(s, 20); T.eq(meta, "text/gemini"); T.eq(body, "# Hi\n")
        s, meta = gemini.header("20 text/plain\nbody")
        T.eq(s, 20); T.eq(meta, "text/plain")
        s, meta, body = gemini.header("20\r\n")
        T.eq(s, 20); T.eq(meta, ""); T.eq(body, "")
        T.eq(gemini.header("20 text/gemini"), nil, "no terminator")
        T.eq(gemini.header("200 OK\r\n"), nil)
        T.eq(gemini.header("HTTP/1.1 200 OK\r\n"), nil)
        T.eq(gemini.header("20 " .. string.rep("x", 1030) .. "\r\n"), nil, "meta over 1024 bytes")
    end,
    success_rewrites_links_and_folds = function()
        local r = interpret("20 text/gemini; charset=utf-8\r\n# Caf\u{00E9}\n=> other.gmi Other \u{2192}\n=> /root\n"
            .. "```\n=> not/a/link\n```\n")
        T.eq(r.kind, "gemini"); T.eq(r.mode, "native"); T.eq(r.finalUrl, "gemini://g.test/dir/page.gmi")
        T.eq(r.body, "# Cafe\n=> gemini://g.test/dir/other.gmi Other ->\n=> gemini://g.test/root gemini://g.test/root\n"
            .. "```\n=> not/a/link\n```\n")
        T.eq(r.title, nil, "the page view takes the title from the first heading")
    end,
    non_ascii_link_urls_are_encoded = function()
        local r = interpret("20 text/gemini\r\n=> caf\u{00E9}.gmi Caf\u{00E9}\n")
        T.eq(r.body, "=> gemini://g.test/dir/caf%C3%A9.gmi Cafe\n")
    end,
    an_empty_meta_means_gemtext = function()
        T.eq(interpret("20\r\n# Hi\n").body, "# Hi\n")
    end,
    latin1_charset = function()
        T.eq(interpret("20 text/gemini; charset=ISO-8859-1\r\ncaf\233\n").body, "cafe\n")
    end,
    other_text_is_reflowed = function()
        local r = interpret("20 text/plain\r\nOne short line\n")
        T.eq(r.kind, "gemini"); T.eq(r.body, "One short line\n"); T.eq(r.title, "g.test")
    end,
    images_and_other_types = function()
        local r = interpret("20 image/png\r\n\137PNG")
        T.eq(r.kind, "image"); T.eq(r.native, true); T.eq(r.body, "\137PNG")
        r = interpret("20 application/pdf\r\n%PDF")
        T.eq(r.kind, "error"); T.eq(r.message, "Can't show application/pdf files")
        T.eq(interpret("20 image/webp\r\nRIFF").message, "Can't show image/webp files")
    end,
    input_statuses = function()
        local r = interpret("10 Search for something\r\n")
        T.eq(r.kind, "input"); T.eq(r.prompt, "Search for something"); T.eq(r.sensitive, false)
        T.eq(r.url, "gemini://g.test/dir/page.gmi")
        T.eq(interpret("11 Password\r\n").sensitive, true)
    end,
    redirects_resolve = function()
        local r = interpret("31 ../moved.gmi\r\n")
        T.eq(r.kind, "redirect"); T.eq(r.url, "gemini://g.test/moved.gmi")
        T.eq(interpret("30 https://w.test/x\r\n").url, "https://w.test/x")
        T.eq(interpret("30 \r\n").message, "Not a Gemini response")
    end,
    failures = function()
        T.eq(interpret("40 Server busy\r\n").message, "Server busy (40)")
        T.eq(interpret("42\r\n").message, "Temporary failure (42)")
        T.eq(interpret("44 30\r\n").message, "Server asks to wait 30 s")
        T.eq(interpret("51 Gone fishing\r\n").message, "Not found")
        T.eq(interpret("59 Bad request\r\n").message, "Bad request (59)")
        T.eq(interpret("52\r\n").message, "Permanent failure (52)")
        T.eq(interpret("60 Need a cert\r\n").message,
            "This page needs a client certificate, which PicoSurf doesn't support")
        T.eq(interpret("70 What\r\n").message, "Not a Gemini response")
        T.eq(interpret("").message, "Not a Gemini response")
    end,
    a_300_kb_line_folds_whole = function() -- Review Focus 1
        local line = string.rep("caf\u{00E9} ", 300 * 1024 // 6)
        local r = interpret("20 text/gemini\r\n" .. line .. "\n")
        T.eq(#r.body, #line - (300 * 1024 // 6) + 1)
        T.ok(not r.body:find("[\128-\255]"))
    end,
    random_bytes_fold_to_printable_text = function() -- Review Focus 2
        local bytes = {}
        local seed = 7
        for i = 1, 4096 do
            seed = (seed * 1103515245 + 12345) % 2147483648
            bytes[i] = string.char(seed // 65536 % 256)
        end
        local r = interpret("20 text/gemini\r\n" .. table.concat(bytes))
        T.eq(r.kind, "gemini")
        T.ok(not r.body:find("[^\t\n\32-\126]"), "only tab, newline and printable ASCII")
    end,
    feed_keeps_dated_links = function()
        local body = "# My gemlog\n=> / Home\n=> 2024-03-02-post.gmi 2024-03-02 - Second post\n"
            .. "=> first.gmi 2024-01-15 First: post\n=> x.gmi 2024-01-01\n```\n=> pre.gmi 2023-01-01 In pre\n```\n"
        local r = interpret("20 text/gemini\r\n" .. body, "feed")
        T.eq(r.kind, "gemini"); T.eq(r.title, "My gemlog")
        T.eq(r.body, "=> gemini://g.test/dir/2024-03-02-post.gmi 2024-03-02 Second post\n"
            .. "=> gemini://g.test/dir/first.gmi 2024-01-15 First: post\n")
    end,
    feed_without_dated_links_fails = function()
        T.eq(interpret("20 text/gemini\r\n# Not a log\n=> a.gmi A\n", "feed").message, "No dated posts here - not a gemlog")
        T.eq(interpret("20 text/plain\r\nhello\n", "feed").message, "No dated posts here - not a gemlog")
    end,
}
````

- [ ] **Step 2: Run it to see it fail**

Run: `lua tests/run.lua tests/test_gemini.lua`
Expected: FAIL, "module 'src.gemini' not found".

- [ ] **Step 3: Write the module**

Create `src/gemini.lua`:

````lua
-- The Gemini protocol (small web spec 4): request lines, response headers,
-- and responses as the app's results. Pure.
local url = require("src.url")
local fold = require("src.fold")
local textflow = require("src.textflow")

local M = {}
M.PORT, M.MAX_URL, M.MAX_HEADER = 1965, 1024, 1029

local IMAGES = { ["image/jpeg"] = true, ["image/png"] = true, ["image/gif"] = true, ["image/bmp"] = true }

local function fail(message)
    return { kind = "error", message = message }
end

-- The request for target: {host, port, url, line}, or nil and a reason.
-- The host is lower-cased, an empty path becomes "/", the default port and
-- any fragment are dropped.
function M.request(target)
    local p = url.parts(target)
    if not p or p.scheme ~= "gemini" or p.host == "" then return nil, "Not a Gemini URL" end
    local port = p.port or M.PORT
    if port < 1 or port > 65535 then return nil, "Not a Gemini URL" end
    local u = "gemini://" .. p.host .. (port ~= M.PORT and (":" .. port) or "")
        .. (p.path ~= "" and p.path or "/") .. (p.query and ("?" .. p.query) or "")
    if #u > M.MAX_URL then return nil, "URL too long for Gemini" end
    return { host = p.host, port = port, url = u, line = u .. "\r\n" }
end

-- status (integer), meta and the body, or nil for a malformed header.
function M.header(data)
    local nl = data:find("\n", 1, true)
    if not nl or nl > M.MAX_HEADER then return nil end
    local line = data:sub(1, nl - 1):gsub("\r$", "")
    local status, rest = line:match("^(%d%d)(.*)$")
    if not status or (rest ~= "" and rest:sub(1, 1) ~= " ") then return nil end
    return math.tointeger(tonumber(status)), rest:sub(2), data:sub(nl + 1)
end

-- "text/gemini; charset=UTF-8" -> "text/gemini", "utf-8".
local function mediaType(meta)
    local mime = (meta:match("^%s*([^;%s]+)") or ""):lower()
    local charset = meta:lower():match("charset%s*=%s*\"?([%w%-_]+)")
    return mime, charset
end

local function eachLine(text)
    if text:sub(-1) ~= "\n" then text = text .. "\n" end
    return text:gmatch("([^\n]*)\n")
end

local function linkParts(line)
    return line:match("^=>%s*(%S+)%s*(.-)%s*$")
end

-- Gemtext with every link absolute and requestable and the text folded
-- (small web spec 8.3). Lines inside preformatted blocks are only folded.
function M.rewrite(text, base)
    local out, pre = {}, false
    for raw in eachLine(text) do
        local line = fold.line(raw)
        if line:sub(1, 3) == "```" then
            pre = not pre
        elseif not pre and raw:sub(1, 2) == "=>" then
            local u, label = linkParts(raw)
            if u then
                local abs = fold.url(url.resolve(base, u) or u)
                label = fold.line(label)
                line = "=> " .. abs .. " " .. (label ~= "" and label or abs)
            end
        end
        out[#out + 1] = line
    end
    return table.concat(out, "\n") .. "\n"
end

-- The first level-1 heading of folded gemtext, outside preformatted blocks,
-- or nil.
local function firstHeading(text)
    local pre = false
    for line in eachLine(text) do
        if line:sub(1, 3) == "```" then
            pre = not pre
        elseif not pre and line:sub(1, 1) == "#" and line:sub(2, 2) ~= "#" then
            local h = line:match("^#%s*(.-)%s*$")
            if h ~= "" then return h end
        end
    end
    return nil
end

-- A gemlog as the feed list the proxy sends for web feeds (small web spec
-- 9.6): only links labelled with a date, absolute, "=> url date title".
-- Returns the list and the page's first heading, or nil when no link has a
-- date.
function M.feed(text, base)
    local page = M.rewrite(text, base)
    local out, pre = {}, false
    for line in eachLine(page) do
        if line:sub(1, 3) == "```" then
            pre = not pre
        elseif not pre and line:sub(1, 2) == "=>" then
            local u, label = linkParts(line)
            local date, title = (label or ""):match("^(%d%d%d%d%-%d%d%-%d%d) (.*)$")
            if date then
                title = title:gsub("^%s*[%-:]+%s*", "")
                out[#out + 1] = "=> " .. u .. " " .. date .. " " .. (title ~= "" and title or date)
            end
        end
    end
    if #out == 0 then return nil end
    return table.concat(out, "\n") .. "\n", firstHeading(page)
end

-- The response `data` to request `req` as a result (small web spec 4):
-- gemini (with finalUrl, title, mode "native"), image (native), input,
-- redirect ({url}) or error. as: "feed" for the gemlog list.
function M.interpret(req, data, as)
    local status, meta, body = M.header(data)
    if not status then return fail("Not a Gemini response") end
    local class = status // 10
    if class == 1 then return { kind = "input", prompt = fold.line(meta), sensitive = status == 11, url = req.url } end
    if class == 3 then
        local to = url.resolve(req.url, meta)
        if not to or meta == "" then return fail("Not a Gemini response") end
        return { kind = "redirect", url = fold.url(to) }
    end
    if class == 4 then
        if status == 44 then return fail("Server asks to wait " .. fold.line(meta) .. " s") end
        return fail((meta ~= "" and fold.line(meta) or "Temporary failure") .. " (" .. status .. ")")
    end
    if class == 5 then
        if status == 51 then return fail("Not found") end
        return fail((meta ~= "" and fold.line(meta) or "Permanent failure") .. " (" .. status .. ")")
    end
    if class == 6 then return fail("This page needs a client certificate, which PicoSurf doesn't support") end
    if class ~= 2 then return fail("Not a Gemini response") end
    local mime, charset = mediaType(meta)
    if mime == "" then mime = "text/gemini" end
    local r = { kind = "gemini", finalUrl = req.url, mode = "native" }
    if mime == "text/gemini" then
        local text = fold.decode(body, charset)
        if as == "feed" then
            local list, title = M.feed(text, req.url)
            if not list then return fail("No dated posts here - not a gemlog") end
            r.body, r.title = list, title
            return r
        end
        r.body = M.rewrite(text, req.url)
        return r
    end
    if as == "feed" then return fail("No dated posts here - not a gemlog") end
    if mime:sub(1, 5) == "text/" then
        r.body, r.title = textflow.convert(fold.decode(body, charset)), req.host
        return r
    end
    if IMAGES[mime] then return { kind = "image", body = body, native = true, finalUrl = req.url } end
    return fail("Can't show " .. fold.line(mime) .. " files")
end

return M
````

- [ ] **Step 4: Run the tests**

Run: `lua tests/run.lua tests/test_gemini.lua && build/lua32 tests/run.lua tests/test_gemini.lua`
Expected: `16 passed, 0 failed` under both.

- [ ] **Step 5: Commit**

```bash
git add src/gemini.lua tests/test_gemini.lua
git commit -m "feat: the Gemini protocol: requests, headers, statuses and gemlog lists"
```

---

### Task 5: The Gopher protocol (`src/gopher.lua`)

**Files:**
- Create: `src/gopher.lua`
- Create: `tests/test_gopher.lua`

**Interfaces:**
- Consumes: `fold.decode`, `fold.line`, `fold.url` (Task 1); `textflow.convert` (Task 3).
- Produces: `gopher.parse(target) -> {host, port, type, selector, search, url}` or nil, reason; `gopher.request(req) -> string`; `gopher.url(host, port, type, selector) -> string`; `gopher.blocked(target) -> toast` or nil; `gopher.needsSearch(target) -> bool`; `gopher.menu(utf8text) -> gemtext`; `gopher.interpret(req, data, as) -> result` (kinds `gemini` with `title` and `mode = "native"`, `image` with `native = true`, or `error`).

- [ ] **Step 1: Write the failing test**

Create `tests/test_gopher.lua` (Review Focus 4 is `menu_lines_with_bare_lf_and_no_terminator`):

````lua
local T = require("tests.t")
local gopher = require("src.gopher")

local MENU = table.concat({
    "iWelcome to the hole\t\terror.host\t1",
    "i  ___   art\tfake\t(NULL)\t0",
    "1Phlog\t/phlog\tg.test\t70",
    "0About me\t/about.txt\tg.test\t70",
    "7Search\t/search\tOther.Test\t7070",
    "IA cat\t/cat.jpg\tg.test\t70",
    "9Archive\t/a.zip\tg.test\t70",
    "8Old BBS\t\tbbs.test\t23",
    "hWeb page\tURL:https://w.test/x\tg.test\t70",
    "3Something broke\t\terror.host\t1",
    "XUnknown thing\t/x\tg.test\t70",
    "a line without tabs",
    "iCaf\u{00E9}\t\terror.host\t1",
    ".",
    "1After the end\t/z\tg.test\t70",
}, "\r\n") .. "\r\n"

return {
    parse_urls = function()
        local r = gopher.parse("gopher://G.Test")
        T.eq(r.host, "g.test"); T.eq(r.port, 70); T.eq(r.type, "1"); T.eq(r.selector, ""); T.eq(r.search, nil)
        r = gopher.parse("gopher://g.test:7070/0/docs/a%20b.txt")
        T.eq(r.port, 7070); T.eq(r.type, "0"); T.eq(r.selector, "/docs/a b.txt")
        r = gopher.parse("gopher://g.test/7/v2/vs%09cats and dogs")
        T.eq(r.type, "7"); T.eq(r.selector, "/v2/vs"); T.eq(r.search, "cats and dogs")
        T.eq(gopher.parse("gopher://g.test/").type, "1")
        T.eq(select(2, gopher.parse("gemini://g.test/")), "Not a Gopher URL")
        T.eq(select(2, gopher.parse("gopher://g.test:99999/")), "Not a Gopher URL")
    end,
    request_lines = function()
        T.eq(gopher.request(gopher.parse("gopher://g.test/1/phlog")), "/phlog\r\n")
        T.eq(gopher.request(gopher.parse("gopher://g.test/7/s%09two words")), "/s\ttwo words\r\n")
        T.eq(gopher.request(gopher.parse("gopher://g.test")), "\r\n")
    end,
    item_urls = function()
        T.eq(gopher.url("g.test", 70, "1", "/a b?c"), "gopher://g.test/1/a%20b%3Fc")
        T.eq(gopher.url("g.test", 7070, "0", ""), "gopher://g.test:7070/0")
    end,
    blocked_and_search_links = function()
        T.eq(gopher.blocked("gopher://g.test/9/a.zip"), "Can't open binary files")
        T.eq(gopher.blocked("gopher://g.test/8"), "Telnet isn't supported")
        T.eq(gopher.blocked("gopher://g.test/1/"), nil)
        T.eq(gopher.needsSearch("gopher://g.test/7/s"), true)
        T.eq(gopher.needsSearch("gopher://g.test/7/s%09q"), false)
        T.eq(gopher.needsSearch("gopher://g.test/1/s"), false)
    end,
    menus_become_gemtext = function()
        local body = gopher.menu(MENU)
        T.eq(body, table.concat({
            "```", "Welcome to the hole", "  ___   art", "```",
            "=> gopher://g.test/1/phlog Phlog",
            "=> gopher://g.test/0/about.txt About me",
            "=> gopher://other.test:7070/7/search [?] Search",
            "=> gopher://g.test/I/cat.jpg [IMG] A cat",
            "=> gopher://g.test/9/a.zip [BIN] Archive",
            "=> gopher://bbs.test:23/8 [TEL] Old BBS",
            "=> https://w.test/x Web page",
            "Something broke",
            "Unknown thing",
            "a line without tabs",
            "```", "Cafe", "```",
        }, "\n") .. "\n")
    end,
    menu_lines_with_bare_lf_and_no_terminator = function()
        local crlf = gopher.menu("1A\t/a\tg.test\t70\r\n.\r\n")
        T.eq(gopher.menu("1A\t/a\tg.test\t70\n"), crlf)
        T.eq(crlf, "=> gopher://g.test/1/a A\n")
    end,
    info_lines_cannot_toggle_preformatting = function()
        T.eq(gopher.menu("i```\t\tx\t1\r\n"), "```\n ```\n```\n")
    end,
    interpret_by_type = function()
        local menu = gopher.interpret(gopher.parse("gopher://g.test/1/phlog"), "1A\t/a\tg.test\t70\r\n.\r\n")
        T.eq(menu.kind, "gemini"); T.eq(menu.mode, "native"); T.eq(menu.title, "g.test/phlog")
        T.eq(menu.finalUrl, "gopher://g.test/1/phlog"); T.eq(menu.body, "=> gopher://g.test/1/a A\n")
        local text = gopher.interpret(gopher.parse("gopher://g.test/0about"), "Hello there\r\nfriend\r\n.\r\n")
        T.eq(text.body, "Hello there\nfriend\n"); T.eq(text.title, "g.test/about")
        local img = gopher.interpret(gopher.parse("gopher://g.test/I/c.jpg"), "\255\216")
        T.eq(img.kind, "image"); T.eq(img.native, true)
        T.eq(gopher.interpret(gopher.parse("gopher://g.test/1/"), "").message, "Empty response from g.test")
        T.eq(gopher.interpret(gopher.parse("gopher://g.test/5/x"), "x").message, "Can't open this kind of Gopher item")
        T.eq(gopher.interpret(gopher.parse("gopher://g.test/1/"), "x", "feed").message, "Feeds aren't supported for Gopher")
    end,
    latin1_menus = function()
        T.eq(gopher.menu(require("src.fold").decode("iCaf\233\t\tx\t1\r\n")), "```\nCafe\n```\n")
    end,
}
````

- [ ] **Step 2: Run it to see it fail**

Run: `lua tests/run.lua tests/test_gopher.lua`
Expected: FAIL, "module 'src.gopher' not found".

- [ ] **Step 3: Write the module**

Create `src/gopher.lua`:

````lua
-- The Gopher protocol (small web spec 7): URLs, the request, and menus and
-- text files as gemtext. Pure.
local fold = require("src.fold")
local textflow = require("src.textflow")

local M = {}
M.PORT, M.TITLE_MAX = 70, 60

local LINKS = { ["0"] = "", ["1"] = "", ["7"] = "[?] ", g = "[IMG] ", I = "[IMG] ", p = "[IMG] ",
    ["9"] = "[BIN] ", ["5"] = "[BIN] ", s = "[BIN] ", d = "[BIN] ", ["8"] = "[TEL] ", T = "[TEL] " }
local IMAGES = { g = true, I = true, p = true }
local BINARY = { ["9"] = true, ["5"] = true, s = true, d = true }
local TELNET = { ["8"] = true, T = true }

local function decode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- Selector bytes outside unreserved ASCII and "/" percent-encoded.
local function encode(s)
    return (s:gsub("[^%w%-%._~/]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- {host, port, type, selector, search, url} for a gopher:// URL, or nil and
-- a reason. selector and search are decoded; search is nil when absent.
function M.parse(target)
    local host, port, path = target:match("^[Gg][Oo][Pp][Hh][Ee][Rr]://([^/:]+):?(%d*)(.*)$")
    if not host then return nil, "Not a Gopher URL" end
    port = port ~= "" and math.tointeger(tonumber(port)) or M.PORT
    if port < 1 or port > 65535 then return nil, "Not a Gopher URL" end
    local itemType, selector = "1", ""
    if #path > 1 then itemType, selector = path:sub(2, 2), decode(path:sub(3)) end
    local search
    local tab = selector:find("\t", 1, true)
    if tab then selector, search = selector:sub(1, tab - 1), selector:sub(tab + 1) end
    return { host = host:lower(), port = port, type = itemType, selector = selector, search = search, url = target }
end

function M.request(req)
    return req.selector .. (req.search and ("\t" .. req.search) or "") .. "\r\n"
end

-- A gopher:// URL for a menu item.
function M.url(host, port, itemType, selector)
    return "gopher://" .. host .. (port ~= M.PORT and (":" .. port) or "") .. "/" .. itemType .. encode(selector)
end

-- The toast for a link PicoSurf won't request (binary files, telnet), or nil.
function M.blocked(target)
    local req = M.parse(target)
    if not req then return nil end
    if BINARY[req.type] then return "Can't open binary files" end
    if TELNET[req.type] then return "Telnet isn't supported" end
    return nil
end

-- Whether opening target first needs search terms: a type 7 URL without one.
function M.needsSearch(target)
    local req = M.parse(target)
    return req ~= nil and req.type == "7" and req.search == nil
end

local function lines(text)
    local out = {}
    if text:sub(-1) ~= "\n" then text = text .. "\n" end
    for l in text:gmatch("([^\n]*)\n") do out[#out + 1] = (l:gsub("\r$", "")) end
    return out
end

local function split(s)
    local f = {}
    for v in (s .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = v end
    return f
end

-- A text line gemtext reads as text (as textflow does for plain text).
local function textLine(l)
    if l:find("^=>") or l:find("^#") or l:find("^>") or l:find("^```") then return " " .. l end
    return l
end

-- A menu (UTF-8 from fold.decode) as gemtext: info lines in preformatted
-- blocks, items as links labelled by kind (small web spec 7).
function M.menu(text)
    local out, art = {}, {}
    local function flushArt()
        if #art == 0 then return end
        out[#out + 1] = "```"
        for _, l in ipairs(art) do out[#out + 1] = l end
        out[#out + 1] = "```"
        art = {}
    end
    for _, line in ipairs(lines(text)) do
        if line == "." then break end
        local t = line:sub(1, 1)
        local f = split(line:sub(2))
        local display = fold.line(f[1] or "")
        if t == "i" then
            art[#art + 1] = display:find("^```") and (" " .. display) or display
        elseif line ~= "" and not line:find("\t", 1, true) then
            flushArt()
            out[#out + 1] = textLine(fold.line(line))
        elseif line ~= "" then
            flushArt()
            local selector, host, port = f[2], f[3], math.tointeger(tonumber(f[4] or ""))
            local web = t == "h" and selector and selector:match("^/?URL:(.+)$")
            if web then
                local u = fold.url(web)
                out[#out + 1] = "=> " .. u .. " " .. (display ~= "" and display or u)
            elseif LINKS[t] and selector and host and host ~= "" and port then
                local u = M.url(host:lower(), port, t, selector)
                out[#out + 1] = "=> " .. u .. " " .. LINKS[t] .. (display ~= "" and display or u)
            else
                out[#out + 1] = textLine(display)
            end
        end
    end
    flushArt()
    return table.concat(out, "\n") .. "\n"
end

-- The reply `data` to `req` as a result: gemini (finalUrl, title, mode
-- "native"), image (native) or error.
function M.interpret(req, data, as)
    if as == "feed" then return { kind = "error", message = "Feeds aren't supported for Gopher" } end
    if data == "" then return { kind = "error", message = "Empty response from " .. req.host } end
    local sel = req.selector
    if sel ~= "" and sel:sub(1, 1) ~= "/" then sel = "/" .. sel end
    local title = fold.line(req.host .. sel):sub(1, M.TITLE_MAX)
    local r = { kind = "gemini", finalUrl = req.url, title = title, mode = "native" }
    if req.type == "1" or req.type == "7" then
        r.body = M.menu(fold.decode(data))
    elseif req.type == "0" or req.type == "h" then
        local text = fold.decode(data):gsub("\r?\n%.%s*$", "\n")
        r.body = textflow.convert(text)
    elseif IMAGES[req.type] then
        return { kind = "image", body = data, native = true, finalUrl = req.url }
    else
        return { kind = "error", message = "Can't open this kind of Gopher item" }
    end
    return r
end

return M
````

- [ ] **Step 4: Run the tests**

Run: `lua tests/run.lua tests/test_gopher.lua && build/lua32 tests/run.lua tests/test_gopher.lua`
Expected: `9 passed, 0 failed` under both.

- [ ] **Step 5: Commit**

```bash
git add src/gopher.lua tests/test_gopher.lua
git commit -m "feat: the Gopher protocol: URLs, requests, menus and text as gemtext"
```

---

### Task 6: Pinned certificates (`src/tofu.lua`)

**Files:**
- Create: `src/tofu.lua`
- Create: `tests/test_tofu.lua`

**Interfaces:**
- Consumes: `store:load(name, default, valid)`, `store:save(name, value)` (existing `src/store.lua`).
- Produces: `tofu.new(store)`; `pins:hosts() -> {["host:port"] = {fp, first, seen}}`; `pins:check(host, port, fp, now) -> "unpinned" | "new" | "ok" | "changed", entry` (memory only); `pins:accept(host, port, fp, now)`; `pins:flush(ms)` (saves a new pin or acceptance at once, `seen` at most once a minute); `pins.unavailableLogged` (a flag `native` sets); `tofu.date(epoch) -> "YYYY-MM-DD"` or nil for 0; `tofu.FILE = "known_hosts.json"`, `tofu.MAX = 500`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_tofu.lua`:

````lua
local T = require("tests.t")
local fakes = require("tests.fakes")
local store = require("src.store")
local tofu = require("src.tofu")

local function setup()
    local fs, files = fakes.fs()
    local json = fakes.json()
    local s = store.new(fs, json, "/data/x")
    return tofu.new(s), s, files, json
end

return {
    first_visit_pins_and_saves = function()
        local pins, _, files = setup()
        T.eq(pins:check("g.test", 1965, "aa", 100), "new")
        T.eq(files["/data/x/known_hosts.json"], nil, "nothing written inside the check")
        pins:flush(0)
        T.ok(files["/data/x/known_hosts.json"], "saved by flush")
        T.eq(pins:check("g.test", 1965, "aa", 200), "ok")
        T.eq(pins:hosts()["g.test:1965"].seen, 200); T.eq(pins:hosts()["g.test:1965"].first, 100)
    end,
    a_different_fingerprint_is_a_change = function()
        local pins = setup()
        pins:check("g.test", 1965, "aa", 100)
        local verdict, old = pins:check("g.test", 1965, "bb", 300)
        T.eq(verdict, "changed"); T.eq(old.fp, "aa"); T.eq(old.first, 100)
        T.eq(pins:hosts()["g.test:1965"].fp, "aa", "unchanged until accepted")
        pins:accept("g.test", 1965, "bb", 300)
        T.eq(pins:check("g.test", 1965, "bb", 400), "ok")
        T.eq(pins:check("g.test", 1966, "bb", 400), "new", "ports are pinned separately")
    end,
    no_fingerprint_is_unpinned = function()
        local pins = setup()
        T.eq(pins:check("g.test", 1965, nil, 100), "unpinned")
        T.eq(next(pins:hosts()), nil)
    end,
    seen_alone_saves_at_most_once_a_minute = function()
        local pins, s = setup()
        local saves = 0
        local save = s.save
        s.save = function(...) saves = saves + 1; return save(...) end
        pins:check("g.test", 1965, "aa", 1)
        pins:flush(1000); T.eq(saves, 1)
        pins:check("g.test", 1965, "aa", 2)
        pins:flush(30000); T.eq(saves, 1, "seen changed, under a minute")
        pins:flush(61000); T.eq(saves, 2)
        pins:flush(200000); T.eq(saves, 2, "nothing changed")
    end,
    the_store_keeps_500_hosts = function()
        local pins = setup()
        for i = 1, 501 do pins:check("h" .. i .. ".test", 1965, "fp", i) end
        local n = 0
        for _ in pairs(pins:hosts()) do n = n + 1 end
        T.eq(n, 500); T.eq(pins:hosts()["h1.test:1965"], nil, "the least recently seen goes")
        T.ok(pins:hosts()["h501.test:1965"])
    end,
    a_corrupt_file_starts_empty = function()
        local pins, s, files = setup()
        files["/data/x/known_hosts.json"] = "garbage"
        T.eq(pins:check("g.test", 1965, "aa", 1), "new")
        T.ok(files["/data/x/known_hosts.json.bad"]); T.eq(#s.notes, 1)
    end,
    saved_pins_load_back = function()
        local pins, s = setup()
        pins:check("g.test", 1965, "aa", 5)
        pins:flush(0)
        local again = tofu.new(s)
        T.eq(again:check("g.test", 1965, "aa", 6), "ok")
    end,
    dates_from_epochs = function()
        T.eq(tofu.date(0), nil)
        T.eq(tofu.date(1), "1970-01-01")
        T.eq(tofu.date(951782400), "2000-02-29")
        T.eq(tofu.date(1792000000), "2026-10-14")
        T.eq(tofu.date(2147483647), "2038-01-19")
    end,
}
````

- [ ] **Step 2: Run it to see it fail**

Run: `lua tests/run.lua tests/test_tofu.lua`
Expected: FAIL, "module 'src.tofu' not found".

- [ ] **Step 3: Write the module**

Create `src/tofu.lua` (`date` is Howard Hinnant's days-from-civil inverse, exact under 32-bit integers until 2038):

````lua
-- Pinned server certificates for Gemini, trust on first use (small web spec
-- 6), kept in known_hosts.json through store.lua: "host:port" ->
-- {fp, first, seen}. Times are clock epochs (0 before time sync).
local M = {}
M.__index = M
M.FILE, M.MAX, M.SEEN_SAVE_MS = "known_hosts.json", 500, 60000

local function valid(v)
    for k, e in pairs(v) do
        if type(k) ~= "string" or type(e) ~= "table" or type(e.fp) ~= "string" then return false end
    end
    return true
end

-- store: a store.lua store.
function M.new(store)
    return setmetatable({ store = store, dirty = false, seenDirty = false }, M)
end

function M:hosts()
    if not self._hosts then self._hosts = self.store:load(M.FILE, {}, valid) end
    return self._hosts
end

local function key(host, port) return host .. ":" .. port end

-- Drops the least recently seen hosts past MAX.
function M:trim()
    local hosts, n = self:hosts(), 0
    for _ in pairs(hosts) do n = n + 1 end
    while n > M.MAX do
        local oldK, oldSeen
        for k, e in pairs(hosts) do
            local seen = tonumber(e.seen) or 0
            if not oldK or seen < oldSeen or (seen == oldSeen and k < oldK) then oldK, oldSeen = k, seen end
        end
        hosts[oldK] = nil
        n = n - 1
    end
end

-- The verdict for certificate fingerprint fp (hex, or nil when the firmware
-- can't tell): "unpinned", "new" (now pinned), "ok", or "changed" plus the
-- pinned entry. Changes only memory; flush saves.
function M:check(host, port, fp, now)
    if fp == nil then return "unpinned" end
    local hosts, k = self:hosts(), key(host, port)
    local e = hosts[k]
    if not e then
        hosts[k] = { fp = fp, first = now, seen = now }
        self:trim()
        self.dirty = true
        return "new"
    end
    if e.fp == fp then
        e.seen = now
        self.seenDirty = true
        return "ok"
    end
    return "changed", e
end

-- Trusts fp for host:port from now on.
function M:accept(host, port, fp, now)
    self:hosts()[key(host, port)] = { fp = fp, first = now, seen = now }
    self:trim()
    self.dirty = true
end

-- Saves a new pin or acceptance at once, a changed `seen` at most once a
-- minute; ms is sys.getTimeMs().
function M:flush(ms)
    if not self.dirty and not (self.seenDirty and (not self.savedAt or ms - self.savedAt >= M.SEEN_SAVE_MS)) then
        return
    end
    self.store:save(M.FILE, self:hosts())
    self.dirty, self.seenDirty, self.savedAt = false, false, ms
end

-- "YYYY-MM-DD" for a clock epoch, or nil for 0 (days from civil, H. Hinnant).
function M.date(epoch)
    if not epoch or epoch <= 0 then return nil end
    local z = epoch // 86400 + 719468
    local era = z // 146097
    local doe = z - era * 146097
    local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    local mp = (5 * doy + 2) // 153
    local d = doy - (153 * mp + 2) // 5 + 1
    local m = mp < 10 and mp + 3 or mp - 9
    local y = yoe + era * 400 + (m <= 2 and 1 or 0)
    return string.format("%04d-%02d-%02d", y, m, d)
end

return M
````

- [ ] **Step 4: Run the tests**

Run: `lua tests/run.lua tests/test_tofu.lua && build/lua32 tests/run.lua tests/test_tofu.lua`
Expected: `8 passed, 0 failed` under both.

- [ ] **Step 5: Commit**

```bash
git add src/tofu.lua tests/test_tofu.lua
git commit -m "feat: pin Gemini certificates on first use (known_hosts.json)"
```

---

### Task 7: One request over `picocalc.tcp` (`src/tcpfetch.lua`), and a fake socket

**Files:**
- Modify: `tests/fakepc.lua` (a fake `picocalc.tcp`, run from `F.service`)
- Create: `src/tcpfetch.lua`
- Create: `tests/test_tcpfetch.lua`

**Interfaces:**
- Produces: `tcpfetch.get(tcp, spec, done) -> {cancel(), received()}` or nil, reason (`"busy"` when `tcp.new` returns nil; the firmware's reason when `connect()` refuses). `spec = {host, port, tls, request, check}`; `check(conn) -> true | false, stopValue` runs once connected and before anything is written. `done(res)` runs once inside the firmware's callbacks: `{ok = true, body}`, `{ok = false, err, connected, tooLarge}` or `{stopped = stopValue}`. `tcpfetch.MAX_BODY = 512 * 1024`, `CONNECT_TIMEOUT = READ_TIMEOUT = 20`.
- Fake: `F.tcpServers["host:port"] = {fp, connectErr, reply(request, conn)}` (reply returns the bytes, or `{chunks, err, hang}`), `F.tcpMade` (sockets, with `.writes`, `.insecure`, `.state`), `F.tcpOldFirmware` (no `peerFingerprint` method), `F.tcpFull`, `F.tcpHolding`. One `F.service()` delivers a whole exchange.

- [ ] **Step 1: Add the fake socket**

Apply this patch from the repo root (`git apply` reads it from standard input):

````diff
diff --git a/tests/fakepc.lua b/tests/fakepc.lua
index dc2caa5..539ac80 100644
--- a/tests/fakepc.lua
+++ b/tests/fakepc.lua
@@ -26,6 +26,7 @@ function M.new()
     F.responder = function() return 404, {}, "no responder" end
 
     function F.service()
+        if F.tcpService and not F.tcpHolding then F.tcpService() end
         if F.holding then return end
         local pending = F.pending
         F.pending = {}
@@ -161,6 +162,98 @@ function M.new()
         return c
     end
 
+    -- picocalc.tcp. F.tcpServers["host:port"] = server: server.fp is the
+    -- certificate fingerprint a TLS socket reports, server.connectErr fails
+    -- the connect with that error, and server.reply(request, conn) returns
+    -- the bytes to send before closing, or {chunks = {...}, err = "...",
+    -- hang = true}. A socket to no server fails with a connect timeout.
+    -- Callbacks run in F.service, as the firmware runs them in its service
+    -- pass. F.tcpOldFirmware: sockets have no peerFingerprint method.
+    -- F.tcpFull: tcp.new returns nil.
+    F.tcpServers, F.tcpMade, F.tcpQueue = {}, {}, {}
+    local tcp = {}
+    function tcp.new(host, port, tls)
+        if F.tcpFull then return nil, "TCP connection pool full or out of memory" end
+        local c = { host = host, port = port, tls = tls or false, cb = {}, buf = "", pos = 1, state = "idle", writes = {} }
+        F.tcpMade[#F.tcpMade + 1] = c
+        local function open()
+            if c.state == "released" then error("tcp: connection is closed") end
+        end
+        function c:setInsecure(v) open(); self.insecure = v end
+        function c:setConnectTimeout(s) self.connectTimeout = s end
+        function c:setReadTimeout(s) self.readTimeout = s end
+        function c:setConnectCallback(fn) self.cb.connect = fn end
+        function c:setReadCallback(fn) self.cb.read = fn end
+        function c:setCloseCallback(fn) self.cb.close = fn end
+        function c:connect()
+            open()
+            if F.netStatus ~= 1 then return false, "WiFi not available" end
+            self.state = "connecting"
+            F.tcpQueue[#F.tcpQueue + 1] = { conn = self, step = "connect" }
+            return true
+        end
+        function c:write(data)
+            open()
+            if self.state ~= "connected" then return -1 end
+            self.writes[#self.writes + 1] = data
+            F.tcpQueue[#F.tcpQueue + 1] = { conn = self, step = "reply" }
+            return #data
+        end
+        function c:read(n)
+            open()
+            if self.pos > #self.buf then return nil end
+            local s = self.buf:sub(self.pos, self.pos + (n or 4096) - 1)
+            self.pos = self.pos + #s
+            return s
+        end
+        function c:available() return #self.buf - self.pos + 1 end
+        function c:error() return self.err end
+        function c:isConnected() return self.state == "connected" end
+        if not F.tcpOldFirmware then
+            function c:peerFingerprint()
+                if self.tls and (self.state == "connected" or self.state == "closed") then return self.fp end
+                return nil
+            end
+        end
+        function c:close() self.state = "released" end
+        return c
+    end
+    local function fire(c, name)
+        if c.state ~= "released" and c.cb[name] then c.cb[name](c) end
+    end
+    -- Runs until nothing is queued: one pass delivers a whole exchange.
+    function F.tcpService()
+        while #F.tcpQueue > 0 do
+            local item = table.remove(F.tcpQueue, 1)
+            local c = item.conn
+            local server = F.tcpServers[c.host .. ":" .. c.port]
+            if c.state == "released" then
+                -- closed by the app meanwhile
+            elseif item.step == "connect" then
+                if not server or server.connectErr then
+                    c.err = server and server.connectErr or "connect timeout (20000ms)"
+                    c.state = "failed"
+                    fire(c, "close")
+                else
+                    c.state, c.fp = "connected", server.fp
+                    fire(c, "connect")
+                end
+            else
+                local r = server.reply(table.concat(c.writes), c)
+                if type(r) == "string" then r = { chunks = { r } } end
+                for _, chunk in ipairs(r.chunks or {}) do
+                    c.buf = c.buf .. chunk
+                    fire(c, "read")
+                end
+                if not r.hang and c.state ~= "released" then
+                    c.err = r.err
+                    c.state = r.err and "failed" or "closed"
+                    fire(c, "close")
+                end
+            end
+        end
+    end
+
     local config = {}
     function config.get(k, d)
         local v = F.config[k]
@@ -189,7 +282,7 @@ function M.new()
 
     F.pc = {
         display = display, ui = ui, input = input, sys = sys, network = network,
-        fs = fs, json = fakes.json(), config = config, graphics = graphics,
+        fs = fs, json = fakes.json(), config = config, graphics = graphics, tcp = tcp,
     }
 
     function F.press(name, mods)
````

- [ ] **Step 2: Write the failing test**

Create `tests/test_tcpfetch.lua` (Review Focus 3 is `a_server_that_never_closes_waits`):

````lua
local T = require("tests.t")
local fakepc = require("tests.fakepc")
local tcpfetch = require("src.tcpfetch")

-- Starts a fetch to g.test:1965 against `server`; returns the results list,
-- the handle and the fake.
local function fetch(server, spec)
    local F = fakepc.new()
    F.tcpServers["g.test:1965"] = server
    local results = {}
    spec = spec or {}
    spec.host, spec.port = "g.test", 1965
    spec.tls = spec.tls ~= false
    spec.request = spec.request or "gemini://g.test/\r\n"
    local h, err = tcpfetch.get(F.pc.tcp, spec, function(res) results[#results + 1] = res end)
    return results, h, F, err
end

return {
    a_reply_arrives_whole = function()
        local results, h, F = fetch({ fp = "aa", reply = function(req) return "20 ok\r\n" .. req end })
        T.eq(#results, 0, "nothing before the firmware's pass")
        F.service()
        T.eq(#results, 1); T.eq(results[1].ok, true); T.eq(results[1].body, "20 ok\r\ngemini://g.test/\r\n")
        local c = F.tcpMade[1]
        T.eq(c.tls, true); T.eq(c.insecure, true); T.eq(c.connectTimeout, 20); T.eq(c.readTimeout, 20)
        T.eq(c.state, "released", "closed after the reply"); T.eq(h.received(), 25)
    end,
    plain_sockets_skip_insecure = function()
        local _, _, F = fetch({ reply = function() return "x" end }, { tls = false })
        F.service()
        T.eq(F.tcpMade[1].tls, false); T.eq(F.tcpMade[1].insecure, nil)
    end,
    the_body_can_come_in_parts = function()
        local results, _, F = fetch({ reply = function() return { chunks = { "ab", "cd", "ef" } } end })
        F.service()
        T.eq(results[1].body, "abcdef")
    end,
    the_check_runs_before_anything_is_sent = function()
        local saw
        local results, _, F = fetch({ fp = "aa", reply = function() error("must not send") end }, {
            check = function(conn)
                saw = conn:peerFingerprint()
                return false, { kind = "certchanged" }
            end,
        })
        F.service()
        T.eq(saw, "aa"); T.eq(#F.tcpMade[1].writes, 0)
        T.eq(results[1].stopped.kind, "certchanged"); T.eq(F.tcpMade[1].state, "released")
    end,
    connect_failures_report_the_firmware_reason = function()
        local results, _, F = fetch({ connectErr = "Mongoose error: TLS handshake failed" })
        F.service()
        T.eq(results[1].ok, false); T.eq(results[1].connected, false)
        T.eq(results[1].err, "Mongoose error: TLS handshake failed")
        results, _, F = fetch(nil)
        F.service()
        T.eq(results[1].err, "connect timeout (20000ms)")
    end,
    errors_after_connecting = function()
        local results, _, F = fetch({ reply = function() return { chunks = { "20 x\r\n" }, err = "read timeout (20000ms)" } end })
        F.service()
        T.eq(results[1].ok, false); T.eq(results[1].connected, true); T.eq(results[1].err, "read timeout (20000ms)")
    end,
    bodies_over_512_kb_stop = function()
        local big = string.rep("x", 300 * 1024)
        local results, _, F = fetch({ reply = function() return { chunks = { big, big } } end })
        F.service()
        T.eq(#results, 1); T.eq(results[1].tooLarge, true); T.eq(results[1].err, "Page too large (over 512 KB)")
        T.eq(F.tcpMade[1].state, "released")
    end,
    cancel_closes_and_reports_nothing = function()
        local results, h, F = fetch({ reply = function() return "x" end })
        h.cancel()
        F.service()
        T.eq(#results, 0); T.eq(F.tcpMade[1].state, "released")
    end,
    no_free_socket = function()
        local F = fakepc.new()
        F.tcpFull = true
        local h, err = tcpfetch.get(F.pc.tcp, { host = "g.test", port = 1965, request = "" }, function() end)
        T.eq(h, nil); T.eq(err, "busy")
    end,
    no_wifi_refuses_at_once = function()
        local F = fakepc.new()
        F.netStatus = 0
        local h, err = tcpfetch.get(F.pc.tcp, { host = "g.test", port = 1965, request = "" }, function() end)
        T.eq(h, nil); T.eq(err, "WiFi not available"); T.eq(F.tcpMade[1].state, "released")
    end,
    a_server_that_never_closes_waits = function() -- the firmware's read timeout ends it
        local results, _, F = fetch({ reply = function() return { chunks = { "20 x\r\n" }, hang = true } end })
        F.service()
        T.eq(#results, 0)
    end,
}
````

- [ ] **Step 3: Run it to see it fail**

Run: `lua tests/run.lua tests/test_tcpfetch.lua`
Expected: FAIL, "module 'src.tcpfetch' not found".

- [ ] **Step 4: Write the module**

Create `src/tcpfetch.lua`:

````lua
-- One request over picocalc.tcp (small web spec 3): connect, an optional
-- check before anything is sent, the request, then everything the server
-- sends until it closes. The firmware runs the callbacks inside its service
-- pass, so `done` must only record.
local M = {}
M.MAX_BODY, M.CONNECT_TIMEOUT, M.READ_TIMEOUT = 512 * 1024, 20, 20
local READ_CHUNK = 16384

-- tcp: picocalc.tcp. spec: {host, port, tls, request, check}; check(conn),
-- when given, runs once connected and returns true, or false and a value
-- that ends the request unsent. done(res) runs once unless cancelled:
--   {ok = true, body = s}
--   {ok = false, err = s, connected = bool, tooLarge = bool}
--   {stopped = value}
-- Returns a handle {cancel(), received()}, or nil and a reason (no free
-- socket: "busy"; or the firmware's refusal to connect).
function M.get(tcp, spec, done)
    local conn = tcp.new(spec.host, spec.port, spec.tls)
    if not conn then return nil, "busy" end
    local st = { parts = {}, n = 0, total = 0, finished = false, connected = false }

    local function finish(res)
        if st.finished then return end
        st.finished = true
        st.parts = nil
        conn:setConnectCallback(nil)
        conn:setReadCallback(nil)
        conn:setCloseCallback(nil)
        conn:close()
        if res then done(res) end
    end

    local function drain()
        while not st.finished do
            local d = conn:read(READ_CHUNK)
            if not d or d == "" then return end
            st.total = st.total + #d
            if st.total > M.MAX_BODY then
                return finish({ ok = false, err = "Page too large (over 512 KB)", connected = true, tooLarge = true })
            end
            st.n = st.n + 1
            st.parts[st.n] = d
        end
    end

    if spec.tls then conn:setInsecure(true) end
    conn:setConnectTimeout(M.CONNECT_TIMEOUT)
    conn:setReadTimeout(M.READ_TIMEOUT)
    conn:setConnectCallback(function()
        if st.finished then return end
        st.connected = true
        if spec.check then
            local ok, stop = spec.check(conn)
            if not ok then return finish({ stopped = stop }) end
        end
        if conn:write(spec.request) < 0 then
            finish({ ok = false, err = conn:error() or "write failed", connected = true })
        end
    end)
    conn:setReadCallback(drain)
    conn:setCloseCallback(function()
        if st.finished then return end
        drain()
        if st.finished then return end
        local err = conn:error()
        if err then return finish({ ok = false, err = err, connected = st.connected }) end
        local ok, body = pcall(table.concat, st.parts)
        if not ok then return finish({ ok = false, err = "Page too large for memory", connected = true }) end
        finish({ ok = true, body = body })
    end)
    local started, err = conn:connect()
    if not started then
        finish(nil)
        return nil, err or "Could not connect"
    end
    return {
        cancel = function() finish(nil) end,
        received = function() return st.total end,
    }
end

return M
````

- [ ] **Step 5: Run the tests**

Run: `lua tests/run.lua tests/test_tcpfetch.lua && build/lua32 tests/run.lua tests/test_tcpfetch.lua`
Expected: `11 passed, 0 failed` under both.
Then `make test`: `294 passed, 0 failed` under both (the fake's hook must not disturb the HTTP fakes).

- [ ] **Step 6: Commit**

```bash
git add tests/fakepc.lua src/tcpfetch.lua tests/test_tcpfetch.lua
git commit -m "feat: one request over picocalc.tcp, checked before sending"
```

---

### Task 8: Gemini and Gopher requests (`src/native.lua`)

**Files:**
- Create: `src/native.lua`
- Create: `tests/test_native.lua`

**Interfaces:**
- Consumes: `gemini.request/interpret` (Task 4), `gopher.parse/request/interpret/needsSearch` (Task 5), `pins:check` (Task 6), `tcpfetch.get` (Task 7), `url.scheme` (existing).
- Produces: `native.get(env, target, as, done) -> {cancel(), received()}` with `env = {tcp, pins, now(), post(fn), log(...)}`; `done(result)` runs from `env.post` (the main loop), once, unless cancelled. Results: Task 4's and Task 5's kinds, `{kind = "certchanged", host, port, old, new, firstSeen, url}`, `{kind = "input", prompt = "Search:", ...}` for a Gopher search without terms (no request made), or `{kind = "redirect", url}` for a Gemini redirect to another scheme. Also `native.prepare`, `native.failure`, `native.check`, `native.MAX_HOPS = 5`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_native.lua` (Review Focus 3 and 5 are `transport_failures_read_plainly` and `redirects_are_followed_up_to_five_hops`):

````lua
local T = require("tests.t")
local fakepc = require("tests.fakepc")
local fakes = require("tests.fakes")
local store = require("src.store")
local tofu = require("src.tofu")
local native = require("src.native")

-- A fake device, env and a get() that runs the main loop's posts.
local function setup()
    local F = fakepc.new()
    local posts, logs = {}, {}
    local pins = tofu.new(store.new(fakes.fs(), fakes.json(), "/data/x"))
    local env = {
        tcp = F.pc.tcp, pins = pins, now = function() return 1000 end,
        post = function(fn) posts[#posts + 1] = fn end,
        log = function(...) logs[#logs + 1] = table.concat({ ... }, " ") end,
    }
    -- The firmware's passes and the main loop, until both are quiet.
    local function pump()
        for _ = 1, 20 do
            F.service()
            local p = posts
            posts = {}
            for _, fn in ipairs(p) do fn() end
        end
    end
    local function get(target, as)
        local results = {}
        local h = native.get(env, target, as, function(r) results[#results + 1] = r end)
        pump()
        return results, h
    end
    return F, get, env, logs, pump
end

local function gemini(F, hostport, fp, routes)
    F.tcpServers[hostport] = { fp = fp, reply = function(req)
        local u = req:gsub("\r\n$", "")
        return routes[u] or "51 Not found\r\n"
    end }
end

return {
    prepare_by_scheme = function()
        local s = native.prepare("gemini://G.test/a")
        T.eq(s.tls, true); T.eq(s.port, 1965); T.eq(s.line, "gemini://g.test/a\r\n"); T.eq(s.url, "gemini://g.test/a")
        s = native.prepare("gopher://h.test/1/x")
        T.eq(s.tls, false); T.eq(s.port, 70); T.eq(s.line, "/x\r\n")
        T.eq(native.prepare("gopher://h.test/7/s").search, true)
        T.eq(select(2, native.prepare("spartan://s.test/")), "spartan:// links aren't supported yet")
    end,
    a_gemini_page = function()
        local F, get = setup()
        gemini(F, "g.test:1965", "aa", { ["gemini://g.test/"] = "20 text/gemini\r\n# Hi\n=> a.gmi A\n" })
        local results = get("gemini://g.test/")
        T.eq(#results, 1); T.eq(results[1].kind, "gemini"); T.eq(results[1].body, "# Hi\n=> gemini://g.test/a.gmi A\n")
    end,
    redirects_are_followed_up_to_five_hops = function()
        local F, get = setup()
        gemini(F, "g.test:1965", "aa", {
            ["gemini://g.test/a"] = "31 /b\r\n", ["gemini://g.test/b"] = "30 c\r\n",
            ["gemini://g.test/c"] = "20 text/gemini\r\nC\n", ["gemini://g.test/loop"] = "31 /loop\r\n",
        })
        local results = get("gemini://g.test/a")
        T.eq(results[1].finalUrl, "gemini://g.test/c"); T.eq(#F.tcpMade, 3)
        results = get("gemini://g.test/loop")
        T.eq(results[1].message, "Too many redirects"); T.eq(#F.tcpMade, 3 + 6, "the first try and five hops")
    end,
    a_redirect_to_another_scheme_is_handed_back = function()
        local F, get = setup()
        gemini(F, "g.test:1965", "aa", { ["gemini://g.test/"] = "31 https://w.test/x\r\n" })
        local results = get("gemini://g.test/")
        T.eq(results[1].kind, "redirect"); T.eq(results[1].url, "https://w.test/x")
    end,
    pins_are_kept_and_changes_stop_the_request = function()
        local F, get, env = setup()
        gemini(F, "g.test:1965", "aa", { ["gemini://g.test/q?x"] = "20 text/gemini\r\nok\n" })
        T.eq(get("gemini://g.test/q?x")[1].kind, "gemini")
        T.eq(env.pins:hosts()["g.test:1965"].fp, "aa")
        F.tcpServers["g.test:1965"].fp = "bb"
        local r = get("gemini://g.test/q?x")[1]
        T.eq(r.kind, "certchanged"); T.eq(r.old, "aa"); T.eq(r.new, "bb"); T.eq(r.host, "g.test"); T.eq(r.port, 1965)
        T.eq(r.url, "gemini://g.test/q?x"); T.eq(r.firstSeen, 1000)
        T.eq(#F.tcpMade[2].writes, 0, "the query was never sent")
    end,
    old_firmware_loads_unpinned_and_logs_once = function()
        local F, get, env, logs = setup()
        F.tcpOldFirmware = true
        gemini(F, "g.test:1965", nil, { ["gemini://g.test/"] = "20 text/gemini\r\nok\n" })
        T.eq(get("gemini://g.test/")[1].kind, "gemini")
        get("gemini://g.test/")
        T.eq(next(env.pins:hosts()), nil)
        local n = 0
        for _, l in ipairs(logs) do if l == "pinning unavailable" then n = n + 1 end end
        T.eq(n, 1)
    end,
    gopher_menus_and_searches = function()
        local F, get = setup()
        F.tcpServers["h.test:70"] = { reply = function(req)
            if req == "/s\tcats\r\n" then return "1Cat\t/cat\th.test\t70\r\n.\r\n" end
            return "iHello\t\th\t1\r\n.\r\n"
        end }
        T.eq(get("gopher://h.test/")[1].body, "```\nHello\n```\n")
        local r = get("gopher://h.test/7/s")[1]
        T.eq(r.kind, "input"); T.eq(r.prompt, "Search:"); T.eq(#F.tcpMade, 1, "no request without terms")
        T.eq(get("gopher://h.test/7/s%09cats")[1].body, "=> gopher://h.test/1/cat Cat\n")
    end,
    transport_failures_read_plainly = function()
        local F, get, _, logs = setup()
        F.tcpServers["g.test:1965"] = { connectErr = "Mongoose error: TLS handshake failed" }
        T.eq(get("gemini://g.test/")[1].message,
            "Secure connection to g.test failed (it may need TLS 1.3 or an Ed25519 certificate)")
        T.ok(logs[#logs]:find("TLS handshake failed", 1, true), "the firmware's reason is logged")
        T.eq(get("gemini://nobody.test/")[1].message, "nobody.test did not respond")
        F.tcpServers["r.test:1965"] = { connectErr = "DNS: Name or service not known" }
        T.eq(get("gemini://r.test/")[1].message, "Could not connect to r.test")
        F.tcpServers["s.test:1965"] = { reply = function() return { err = "read timeout (20000ms)" } end }
        T.eq(get("gemini://s.test/")[1].message, "s.test stopped responding")
        F.tcpServers["l.test:1965"] = { reply = function() return { chunks = { "20 t" }, err = "Mongoose error: reset" } end }
        T.eq(get("gemini://l.test/")[1].message, "Connection to l.test was lost")
        F.tcpServers["e.test:1965"] = { reply = function() return "" end }
        T.eq(get("gemini://e.test/")[1].message, "Not a Gemini response")
        F.tcpServers["e.test:70"] = { reply = function() return "" end }
        T.eq(get("gopher://e.test/")[1].message, "Empty response from e.test")
    end,
    no_free_socket_is_busy = function()
        local F, get = setup()
        F.tcpFull = true
        T.eq(get("gemini://g.test/")[1].message, "Busy: try again")
    end,
    bad_urls_fail_without_a_socket = function()
        local F, get = setup()
        T.eq(get("gemini://g.test/" .. string.rep("a", 1100))[1].message, "URL too long for Gemini")
        T.eq(#F.tcpMade, 0)
    end,
    cancel_drops_the_result = function()
        local F, _, env, _, pump = setup()
        gemini(F, "g.test:1965", "aa", { ["gemini://g.test/"] = "20 text/gemini\r\nok\n" })
        local got = 0
        local h = native.get(env, "gemini://g.test/", nil, function() got = got + 1 end)
        h.cancel()
        pump()
        T.eq(got, 0); T.eq(F.tcpMade[1].state, "released")
        -- Cancelled after the reply arrived but before the main loop ran it.
        h = native.get(env, "gemini://g.test/", nil, function() got = got + 1 end)
        F.service()
        h.cancel()
        pump()
        T.eq(got, 0)
    end,
}
````

- [ ] **Step 2: Run it to see it fail**

Run: `lua tests/run.lua tests/test_native.lua`
Expected: FAIL, "module 'src.native' not found".

- [ ] **Step 3: Write the module**

Create `src/native.lua`:

````lua
-- Gemini and Gopher requests for App:request (small web spec 2.1, 4-7): one
-- tcpfetch per hop, Gemini redirects followed, certificates pinned, and
-- transport failures as the messages of spec 11.
local url = require("src.url")
local gemini = require("src.gemini")
local gopher = require("src.gopher")
local tcpfetch = require("src.tcpfetch")

local M = {}
M.MAX_HOPS = 5

local function fail(message)
    return { kind = "error", message = message }
end

-- What to send for target: {scheme, host, port, tls, line, url, req}; or
-- {search = true, url} for a Gopher search without its terms; or nil and a
-- reason.
function M.prepare(target)
    local scheme = url.scheme(target)
    if scheme == "gemini" then
        local req, err = gemini.request(target)
        if not req then return nil, err end
        return { scheme = scheme, host = req.host, port = req.port, tls = true, line = req.line, url = req.url, req = req }
    end
    if scheme == "gopher" then
        if gopher.needsSearch(target) then return { search = true, url = target } end
        local req, err = gopher.parse(target)
        if not req then return nil, err end
        return { scheme = scheme, host = req.host, port = req.port, tls = false, line = gopher.request(req),
            url = target, req = req }
    end
    return nil, (scheme or "That") .. ":// links aren't supported yet"
end

-- A transport failure (a tcpfetch result) as the message a reader sees.
function M.failure(host, res)
    local e = res.err or ""
    if res.tooLarge or e == "Page too large for memory" then return fail(e) end
    if not res.connected then
        if e:find("timeout", 1, true) then return fail(host .. " did not respond") end
        if e:find("TLS", 1, true) or e:find("SSL", 1, true) or e:find("handshake", 1, true) then
            return fail("Secure connection to " .. host .. " failed (it may need TLS 1.3 or an Ed25519 certificate)")
        end
        return fail("Could not connect to " .. host)
    end
    if e:find("timeout", 1, true) then return fail(host .. " stopped responding") end
    return fail("Connection to " .. host .. " was lost")
end

-- The pin check, run by tcpfetch after the handshake and before sending.
function M.check(env, spec, conn)
    local fp = conn.peerFingerprint and conn:peerFingerprint() or nil
    if fp == nil and not env.pins.unavailableLogged then
        env.pins.unavailableLogged = true
        env.log("pinning unavailable")
    end
    local verdict, old = env.pins:check(spec.host, spec.port, fp, env.now())
    if verdict ~= "changed" then return true end
    return false, { kind = "certchanged", host = spec.host, port = spec.port, old = old.fp, new = fp,
        firstSeen = old.first, url = spec.url }
end

-- Fetches target (gemini:// or gopher://). env: {tcp = picocalc.tcp, pins =
-- a tofu, now() -> clock epoch, post(fn) runs fn from the main loop, log(...)}.
-- done(result) runs from the main loop, once, unless cancelled. A redirect to
-- another scheme ends with {kind = "redirect", url} for the app to dispatch.
-- Returns a handle {cancel(), received()}.
function M.get(env, target, as, done)
    local h = { cancelled = false }
    local function finish(r)
        if not h.cancelled then done(r) end
    end
    local hop
    local function onReply(spec, res, n)
        if h.cancelled then return end
        h.cur = nil
        if res.stopped then return finish(res.stopped) end
        if not res.ok then
            env.log("error", "-", spec.host, res.err)
            return finish(M.failure(spec.host, res))
        end
        local proto = spec.scheme == "gemini" and gemini or gopher
        local r = proto.interpret(spec.req, res.body, as)
        if r.kind == "redirect" then
            if n >= M.MAX_HOPS then return finish(fail("Too many redirects")) end
            if url.scheme(r.url) == "gemini" then return hop(r.url, n + 1) end
        end
        finish(r)
    end
    hop = function(u, n)
        local spec, err = M.prepare(u)
        if not spec then return env.post(function() finish(fail(err)) end) end
        if spec.search then
            return env.post(function() finish({ kind = "input", prompt = "Search:", sensitive = false, url = u }) end)
        end
        local cur, ferr = tcpfetch.get(env.tcp, {
            host = spec.host, port = spec.port, tls = spec.tls, request = spec.line,
            check = spec.tls and function(conn) return M.check(env, spec, conn) end or nil,
        }, function(res) env.post(function() onReply(spec, res, n) end) end)
        if not cur then
            return env.post(function() finish(fail(ferr == "busy" and "Busy: try again" or ferr)) end)
        end
        h.cur = cur
    end
    hop(target, 0)
    return {
        cancel = function()
            h.cancelled = true
            if h.cur then h.cur.cancel() end
            h.cur = nil
        end,
        received = function() return h.cur and h.cur.received() or 0 end,
    }
end

return M
````

- [ ] **Step 4: Run the tests**

Run: `lua tests/run.lua tests/test_native.lua && build/lua32 tests/run.lua tests/test_native.lua`
Expected: `11 passed, 0 failed` under both.

- [ ] **Step 5: Commit**

```bash
git add src/native.lua tests/test_native.lua
git commit -m "feat: Gemini and Gopher requests with redirects, pinning and plain errors"
```

---

### Task 9: Native pages in the app

**Files:**
- Modify: `src/app.lua` (dispatch in `request`, `nativeEnv`, open rules, `input` and `certchanged` results, native images, F4, pins flushed in `pump`)
- Create: `src/screens/cert.lua`
- Modify: `src/screens/loading.lua` (the clock wait only for web requests)
- Modify: `src/screens/page.lua` (no mode letter on native pages)
- Modify: `tests/fakepc.lua` (`graphics.image.getInfo`, `loadScaled`)
- Modify: `tests/test_app.lua` (the unsupported-scheme test uses `spartan://`, since `gemini://` now opens)
- Create: `tests/test_app_native.lua`

**Interfaces:**
- Consumes: `native.get` (Task 8), `tofu.new`, `pins:hosts/accept/flush`, `tofu.date` (Task 6), `gopher.blocked` (Task 5), `url.withInput` (Task 2).
- Produces: `App:request(target, as, done, fit)` dispatching by scheme (same handle and inbox contract as before); `App.NO_PROXY = "Web pages need a proxy - set one in Settings"`; `App:askInput(r, opts)`; `App:acceptCert(change, retry)`; `App:loadNativeImage(body) -> img` or nil, reason; the `cert` screen (`args = {change, retry}`); log lines `picosurf: prompt input`, `picosurf: cert accepted <host>:<port>`, `picosurf: pinning unavailable`.

- [ ] **Step 1: Add the image fakes and update the scheme test**

Apply this patch from the repo root (`git apply` reads it from standard input):

````diff
diff --git a/tests/fakepc.lua b/tests/fakepc.lua
index 539ac80..ed3a760 100644
--- a/tests/fakepc.lua
+++ b/tests/fakepc.lua
@@ -17,7 +17,7 @@ local KEYCODE = {
 function M.new()
     local F = {
         texts = {}, textFonts = {}, textXs = {}, logs = {}, toasts = {}, menu = {}, events = {}, inputs = {}, confirms = {},
-        requests = {}, pending = {}, config = {}, conns = 0, made = {}, decoded = {},
+        requests = {}, pending = {}, config = {}, conns = 0, made = {}, decoded = {}, scaled = {},
         rects = {}, imageDraws = {}, fontFiles = {}, missingFonts = {}, nextFontId = 4,
         netStatus = 1, synced = true, epoch = 1792000000, ms = 0,
     }
@@ -280,6 +280,22 @@ function M.new()
         return img
     end
 
+    -- getInfo and loadScaled read a file the app wrote, "JPEG:<w>x<h>...".
+    -- F.failScaled makes loadScaled raise, as out of memory.
+    function graphics.image.getInfo(path)
+        local w, h = (F.files[path] or ""):match("^JPEG:(%d+)x(%d+)")
+        if not w then error("not a recognized image") end
+        return { width = math.tointeger(tonumber(w)), height = math.tointeger(tonumber(h)), format = "jpeg" }
+    end
+    function graphics.image.loadScaled(path, w, h)
+        if F.failScaled then error("out of memory") end
+        F.scaled[#F.scaled + 1] = { path = path, w = w, h = h }
+        local img = {}
+        function img:getSize() return w, h end
+        function img:draw(x, y) F.imageDraws[#F.imageDraws + 1] = { data = "scaled", x = x, y = y } end
+        return img
+    end
+
     F.pc = {
         display = display, ui = ui, input = input, sys = sys, network = network,
         fs = fs, json = fakes.json(), config = config, graphics = graphics, tcp = tcp,
diff --git a/tests/test_app.lua b/tests/test_app.lua
index 9d58d5c..e24878a 100644
--- a/tests/test_app.lua
+++ b/tests/test_app.lua
@@ -2,7 +2,7 @@ local T = require("tests.t")
 local fakepc = require("tests.fakepc")
 local App = require("src.app")
 
-local A = "# A\n\nSee the docs [1] and more [2].\n=> https://b.test/ [1] the docs\n=> gemini://g.test/ [2] more\n=> https://a.test/cat.jpg [IMG] Cat\n"
+local A = "# A\n\nSee the docs [1] and more [2].\n=> https://b.test/ [1] the docs\n=> spartan://s.test/ [2] more\n=> https://a.test/cat.jpg [IMG] Cat\n"
 local function longBody()
     local parts = { "# Long" }
     for i = 1, 100 do parts[#parts + 1] = "line " .. i end
@@ -177,7 +177,7 @@ return {
         local app, F = boot()
         go(app, F, "a.test/")
         F.type("2"); F.press("enter"); steps(app, 1)
-        T.ok(F.hasToast("gemini:// links aren't supported yet"))
+        T.ok(F.hasToast("spartan:// links aren't supported yet"))
         T.eq(app.screenName, "page")
     end,
     opens_and_closes_an_image = function()
````

- [ ] **Step 2: Write the failing test**

Create `tests/test_app_native.lua` (`F.routes` is each test's copy of `GEMINI`, which Task 10's feed tests change):

````lua
local T = require("tests.t")
local fakepc = require("tests.fakepc")
local App = require("src.app")

local HOME = "# Capsule\n=> sub/page.gmi A page\n=> /search Search\n=> /pic.jpg Picture\n=> /big.jpg Big picture\n"
    .. "=> /away Away\n=> gopher://h.test/ Gopher\n"
local GEMINI = {
    ["gemini://g.test/"] = "20 text/gemini\r\n" .. HOME,
    ["gemini://g.test/sub/page.gmi"] = "20 text/gemini\r\n# Page\n",
    ["gemini://g.test/search"] = "10 Search for\r\n",
    ["gemini://g.test/search?two%20words"] = "20 text/gemini\r\n# Results\n",
    ["gemini://g.test/pic.jpg"] = "20 image/jpeg\r\nJPEG:200x100",
    ["gemini://g.test/big.jpg"] = "20 image/jpeg\r\nJPEG:1600x800",
    ["gemini://g.test/bad.jpg"] = "20 image/jpeg\r\nnope",
    ["gemini://g.test/away"] = "31 https://w.test/\r\n",
    ["gemini://g.test/log/"] = "20 text/gemini\r\n# My log\n=> 2.gmi 2024-02-02 - Second\n=> 1.gmi 2024-01-01 First\n"
        .. "=> / Home\n",
}
local GOPHER = table.concat({
    "iWelcome\t\th.test\t1", "0About\t/about\th.test\t70", "9Archive\t/a.zip\th.test\t70",
    "8BBS\t\th.test\t23", "7Find\t/find\th.test\t70", ".",
}, "\r\n") .. "\r\n"

-- F.routes: this test's copy of GEMINI, which a test may change.
local function boot(opts)
    opts = opts or {}
    local F = fakepc.new()
    F.routes = {}
    for k, v in pairs(GEMINI) do F.routes[k] = v end
    if opts.proxy ~= false then F.config.proxy_url, F.config.token = "https://p.test", "tok" end
    F.config.font = "scientifica"
    F.responder = fakepc.proxy({ ["https://w.test/"] = { title = "W", body = "# W\n" } }, "tok")
    F.tcpServers["g.test:1965"] = { fp = "aa" .. string.rep("0", 62), reply = function(req)
        return F.routes[req:gsub("\r\n$", "")] or "51 Not found\r\n"
    end }
    F.tcpServers["h.test:70"] = { reply = function(req)
        if req == "/about\r\n" then return "About this hole.\r\n.\r\n" end
        if req == "/find\tcats\r\n" then return "0Cats\t/cats\th.test\t70\r\n.\r\n" end
        return GOPHER
    end }
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

-- Enter on link n of the page (by the link number keys).
local function follow(app, F, n)
    app.page.ps.sel = n
    F.press("enter")
    steps(app)
end

return {
    a_gemini_page_opens_and_links_resolve = function()
        local app, F = boot()
        go(app, F, "gemini://g.test/")
        T.eq(app.screenName, "page"); T.eq(app.page.url, "gemini://g.test/"); T.eq(app.page.title, "Capsule")
        T.eq(app.page.mode, "native")
        T.ok(F.hasLog("picosurf: loaded gemini://g.test/ mode=native"))
        T.eq(F.tcpMade[1].insecure, true)
        follow(app, F, 1)
        T.eq(app.page.url, "gemini://g.test/sub/page.gmi")
        T.eq(app.store:history()[1].url, "gemini://g.test/sub/page.gmi")
    end,
    the_footer_has_no_mode_letter = function()
        local app, F = boot()
        go(app, F, "gemini://g.test/")
        local footer
        for _, t in ipairs(F.texts) do if t:find("^%[F%]") then footer = t end end
        T.ok(footer and footer:find("%%$"), "footer ends at the percentage: " .. tostring(footer))
    end,
    back_uses_the_cache = function()
        local app, F = boot()
        go(app, F, "gemini://g.test/")
        follow(app, F, 1)
        F.press("backspace"); steps(app)
        T.eq(app.page.url, "gemini://g.test/"); T.eq(#F.tcpMade, 2, "no third request")
    end,
    pins_are_saved = function()
        local app, F = boot()
        go(app, F, "gemini://g.test/")
        T.ok(F.files["/data/net.picodeck.picosurf/known_hosts.json"], "known_hosts.json written")
        T.eq(app.pins:hosts()["g.test:1965"].fp, "aa" .. string.rep("0", 62))
    end,
    input_prompts_and_reopens_with_the_answer = function()
        local app, F = boot()
        go(app, F, "gemini://g.test/")
        F.inputs[#F.inputs + 1] = "two words"
        follow(app, F, 2)
        T.eq(F.lastPrompt, "Search for"); T.ok(F.hasLog("picosurf: prompt input"))
        T.eq(app.page.url, "gemini://g.test/search?two%20words"); T.eq(app.page.title, "Results")
    end,
    cancelled_input_stays_put = function()
        local app, F = boot()
        go(app, F, "gemini://g.test/")
        follow(app, F, 2)
        T.eq(app.screenName, "page"); T.eq(app.page.url, "gemini://g.test/")
    end,
    a_changed_certificate_is_reviewed = function()
        local app, F = boot()
        go(app, F, "gemini://g.test/")
        F.tcpServers["g.test:1965"].fp = "bb" .. string.rep("1", 62)
        follow(app, F, 1)
        T.eq(app.screenName, "cert")
        local text = F.screenText()
        T.ok(text:find("Certificate changed", 1, true)); T.ok(text:find("g.test", 1, true))
        T.ok(text:find("Old: aa00000000000000", 1, true)); T.ok(text:find("New: bb11111111111111", 1, true))
        T.ok(text:find("Enter trust new", 1, true))
        T.eq(#F.tcpMade[2].writes, 0, "nothing was sent")
        F.press("esc"); steps(app)
        T.eq(app.screenName, "page"); T.eq(app.page.url, "gemini://g.test/")
        follow(app, F, 1)
        F.press("enter"); steps(app)
        T.eq(app.page.url, "gemini://g.test/sub/page.gmi")
        T.eq(app.pins:hosts()["g.test:1965"].fp, "bb" .. string.rep("1", 62))
        T.ok(F.hasLog("picosurf: cert accepted g.test:1965"))
    end,
    old_firmware_loads_unpinned = function()
        local app, F = boot()
        F.tcpOldFirmware = true
        go(app, F, "gemini://g.test/")
        T.eq(app.page.url, "gemini://g.test/"); T.ok(F.hasLog("picosurf: pinning unavailable"))
        T.eq(next(app.pins:hosts()), nil)
    end,
    a_redirect_to_the_web_uses_the_proxy = function()
        local app, F = boot()
        go(app, F, "gemini://g.test/")
        follow(app, F, 5)
        T.eq(app.page.url, "https://w.test/"); T.eq(app.page.title, "W")
    end,
    gopher_menus_text_and_blocked_links = function()
        local app, F = boot()
        go(app, F, "gopher://h.test/")
        T.eq(app.page.mode, "native"); T.eq(app.page.title, "h.test")
        follow(app, F, 2) -- [BIN] Archive
        T.ok(F.hasToast("Can't open binary files")); T.eq(#F.tcpMade, 1)
        follow(app, F, 3) -- [TEL] BBS
        T.ok(F.hasToast("Telnet isn't supported"))
        F.inputs[#F.inputs + 1] = "cats"
        follow(app, F, 4) -- [?] Find
        T.eq(F.lastPrompt, "Search:"); T.eq(app.page.url, "gopher://h.test/7/find%09cats")
        follow(app, F, 1)
        T.eq(app.page.url, "gopher://h.test/0/cats")
    end,
    f4_on_a_native_page_explains = function()
        local app, F = boot()
        go(app, F, "gemini://g.test/")
        F.press("f4"); steps(app)
        T.ok(F.hasToast("Reader mode is for web pages")); T.eq(#F.tcpMade, 1)
    end,
    the_web_needs_a_proxy = function()
        local app, F = boot({ proxy = false })
        app:open("https://w.test/")
        T.ok(F.hasToast("Web pages need a proxy - set one in Settings"))
        app:open("gemini://g.test/")
        steps(app)
        T.eq(app.page.url, "gemini://g.test/")
    end,
    gemini_never_waits_for_the_clock = function()
        local app, F = boot()
        F.synced = false
        go(app, F, "gemini://g.test/")
        T.eq(app.screenName, "page")
    end,
    native_images_open_full_screen = function()
        local app, F = boot()
        go(app, F, "gemini://g.test/")
        follow(app, F, 3)
        T.eq(app.screenName, "image"); T.eq(F.decoded[#F.decoded], "JPEG:200x100"); T.eq(#F.scaled, 0)
        T.eq(F.files["/data/net.picodeck.picosurf/image.tmp"], nil, "the temporary file is deleted")
        F.press("esc"); steps(app)
        follow(app, F, 4)
        T.eq(app.screenName, "image"); T.eq(F.scaled[1].w, 320); T.eq(F.scaled[1].h, 160)
    end,
    native_images_that_fail = function()
        local app, F = boot()
        F.failScaled = true
        go(app, F, "gemini://g.test/")
        follow(app, F, 4)
        T.eq(app.screenName, "message"); T.ok(F.screenText():find("Image too large to show (1600x800)", 1, true))
        app:open("gemini://g.test/bad.jpg")
        steps(app)
        T.ok(F.screenText():find("Could not decode the image", 1, true))
    end,
}
````

- [ ] **Step 3: Run it to see it fail**

Run: `lua tests/run.lua tests/test_app_native.lua`
Expected: FAIL in most cases: the app still toasts `gemini:// links aren't supported yet`.

- [ ] **Step 4: Add the review screen**

Create `src/screens/cert.lua`:

````lua
-- A pinned certificate changed (small web spec 6): Enter trusts the new one
-- and loads the page, Esc or Backspace goes back.
local wrap = require("src.wrap")
local theme = require("src.theme")
local tofu = require("src.tofu")

local S = {}

-- args: change (a certchanged result), retry (opens the page again).
function S.enter(app, args)
    app.cert = args
end

function S.draw(app)
    local c, th, d = app.cert.change, app.theme, app.disp
    app.ui.drawHeader("Certificate changed")
    local paras = {
        "The certificate for " .. c.host .. " has changed since " .. (tofu.date(c.firstSeen) or "your first visit")
            .. ". Sites do this when they renew; it can also mean someone is intercepting the connection.",
        "",
        "Old: " .. c.old:sub(1, 16),
        "New: " .. c.new:sub(1, 16),
    }
    local cols, y = theme.uiCols(th), th.top + 20
    for _, text in ipairs(paras) do
        local s, e = wrap.wrap(text, cols)
        if #s == 0 then y = y + th.uiRowH end
        for i = 1, #s do
            d.drawText(th.margin, y, text:sub(s[i], e[i]), th.fg, false)
            y = y + th.uiRowH
        end
    end
    app.ui.drawFooter("Enter trust new  Esc back", "")
end

function S.key(app, action)
    local c = app.cert
    if action == "enter" then
        app.cert = nil
        return app:acceptCert(c.change, c.retry)
    end
    if action == "esc" or action == "backspace" then
        app.cert = nil
        app:show(app.page and "page" or "home")
    end
end

return S
````

- [ ] **Step 5: Wire the app**

Apply this patch from the repo root (`git apply` reads it from standard input):

````diff
diff --git a/src/app.lua b/src/app.lua
index 2307bb7..14696cd 100644
--- a/src/app.lua
+++ b/src/app.lua
@@ -11,10 +11,15 @@ local fonts = require("src.fonts")
 local theme = require("src.theme")
 local feeds = require("src.feeds")
 local inline = require("src.inline")
+local native = require("src.native")
+local tofu = require("src.tofu")
+local gopher = require("src.gopher")
 
 local App = {}
 App.__index = App
 App.MAX_BACK, App.MAX_CACHE = 20, 3
+App.NO_PROXY = "Web pages need a proxy - set one in Settings"
+App.PROMPT_MAX = 48 -- a Gemini input prompt, cut to ui.textInput's width
 
 -- A copy of a page's inline box heights, for a Back entry or Reload (inline images spec 5.6).
 local function copyBoxes(b)
@@ -24,13 +29,14 @@ local function copyBoxes(b)
     return c
 end
 
-local SCREENS = { "home", "page", "image", "settings", "loading", "message" }
+local SCREENS = { "home", "page", "image", "settings", "loading", "message", "cert" }
 
 -- pc: the picocalc API (a fake in host tests); appId: app.json's id.
 function App.new(pc, appId, appDir)
     local self = setmetatable({ pc = pc, appDir = appDir or "/apps/picosurf" }, App)
     self.disp, self.ui, self.input, self.sys = pc.display, pc.ui, pc.input, pc.sys
     self.store = store.new(pc.fs, pc.json, "/data/" .. appId)
+    self.pins = tofu.new(self.store)
     self.decode = keys.decoder(pc.input)
     self.screens = {}
     for _, name in ipairs(SCREENS) do self.screens[name] = require("src.screens." .. name) end
@@ -221,14 +227,46 @@ function App:pump()
         m.done(m.result)
         self.dirty = true
     end
+    self.pins:flush(self.sys.getTimeMs())
     local notes = self.store.notes
     while #notes > 0 do self:toast(table.remove(notes, 1), self.ui.TOAST_WARNING) end
 end
 
--- Starts a proxy request; done(result) runs from the main loop. fit: "WxH"
--- for an inline picture (nil for pages and full-screen images).
+-- What native.get needs from the app. The pins are loaded here, in the
+-- main loop, so the check inside the firmware's callbacks reads no file.
+function App:nativeEnv()
+    self.pins:hosts()
+    return {
+        tcp = self.pc.tcp, pins = self.pins, now = function() return self:now() end,
+        post = function(fn) self.inbox[#self.inbox + 1] = { done = fn } end,
+        log = function(...) self:log(...) end,
+    }
+end
+
+-- Starts a request by the target's scheme (small web spec 2.1): Gemini and
+-- Gopher natively, http(s) through the proxy. done(result) runs from the
+-- main loop. fit: "WxH" for an inline picture (nil for pages and full-screen
+-- images). Returns a handle {cancel(), received()}, or nil and a reason.
 function App:request(target, as, done, fit)
-    if not self.pool then return nil, self.baseErr or "Set the proxy URL in Settings" end
+    local scheme = url.scheme(target)
+    if scheme == "gemini" or scheme == "gopher" then
+        local outer = {}
+        outer.cur = native.get(self:nativeEnv(), target, as, function(r)
+            if r.kind ~= "redirect" then return done(r) end
+            -- A Gemini redirect to another scheme goes through this dispatch.
+            local h, err = self:request(r.url, as, done, fit)
+            if not h then return done({ kind = "error", message = err }) end
+            outer.cur = h
+        end)
+        return {
+            cancel = function() outer.cur.cancel() end,
+            received = function() return outer.cur.received() end,
+        }
+    end
+    if scheme ~= "http" and scheme ~= "https" then
+        return nil, (scheme or "That") .. ":// links aren't supported yet"
+    end
+    if not self.pool then return nil, self.baseErr or App.NO_PROXY end
     local handle, err = self.pool:get(proxy.getPath(self.base, target, as, fit), proxy.headers(self.cfg.token),
         function(ok, status, body, headers)
             self.inbox[#self.inbox + 1] = { done = done, result = proxy.interpret(ok, status, body, headers) }
@@ -293,6 +331,10 @@ end
 
 function App:showResult(target, mode, r, opts)
     opts = opts or {}
+    if r.kind == "input" then return self:askInput(r, opts) end
+    if r.kind == "certchanged" then
+        return self:show("cert", { change = r, retry = function() self:open(target, opts) end })
+    end
     if r.kind == "gemini" or r.kind == "text" then
         local finalUrl = r.finalUrl or target
         local page, err = self:buildPage(finalUrl, mode, r, opts.restore)
@@ -309,6 +351,15 @@ function App:showResult(target, mode, r, opts)
     end
     if r.kind == "image" then
         local where = r.finalUrl or target
+        if r.native then
+            local img, err = self:loadNativeImage(r.body)
+            if not img then
+                self:log("error", "-", err .. " " .. where)
+                return self:fail(err)
+            end
+            if opts.back then table.remove(self.back) end
+            return self:show("image", { url = where, image = img })
+        end
         local ok, img = pcall(self.pc.graphics.image.loadFromBuffer, r.body)
         if not ok or not img then
             self:log("error", "-", "image decode failed " .. where)
@@ -321,6 +372,56 @@ function App:showResult(target, mode, r, opts)
     self:fail(r.message, function() self:open(target, opts) end, r.status)
 end
 
+-- A server asked for text (small web spec 5): back to the screen the load
+-- started from, ask, and open the URL again with the answer.
+function App:askInput(r, opts)
+    self:show(self.page and "page" or "home")
+    local prompt = r.prompt ~= "" and r.prompt or "Input:"
+    self:log("prompt", "input")
+    local text = self.ui.textInput(prompt:sub(1, App.PROMPT_MAX))
+    self.input.clearState()
+    self.dirty = true
+    if not text then return end
+    self:open(url.withInput(r.url, text), opts)
+end
+
+-- The certificate review's Enter (small web spec 6): trust the new
+-- certificate and load the page again.
+function App:acceptCert(change, retry)
+    self.pins:accept(change.host, change.port, change.new, self:now())
+    self.pins:flush(self.sys.getTimeMs())
+    self:log("cert", "accepted", change.host .. ":" .. change.port)
+    retry()
+end
+
+-- A full-size picture from Gemini or Gopher (small web spec 9.7), through a
+-- temporary file so a large one loads scaled to fit 320x320. Returns the
+-- image, or nil and the reason.
+function App:loadNativeImage(body)
+    local fs, g = self.pc.fs, self.pc.graphics.image
+    local path = self.store:path("image.tmp")
+    local f = fs.open(path, "w")
+    if not f then return nil, "Could not decode the image" end
+    fs.write(f, body)
+    fs.close(f)
+    local okInfo, info = pcall(g.getInfo, path)
+    local w, h = okInfo and info and info.width, okInfo and info and info.height
+    local ok, img = false, nil
+    if w and h and w > 0 and h > 0 then
+        if w <= 320 and h <= 320 then
+            ok, img = pcall(g.loadFromBuffer, body)
+        elseif w >= h then
+            ok, img = pcall(g.loadScaled, path, 320, math.max(1, h * 320 // w))
+        else
+            ok, img = pcall(g.loadScaled, path, math.max(1, w * 320 // h), 320)
+        end
+    end
+    fs.delete(path)
+    if ok and img then return img end
+    if w and h then return nil, "Image too large to show (" .. w .. "x" .. h .. ")" end
+    return nil, "Could not decode the image"
+end
+
 -- Runs fn (parsing or layout) under pcall. On an error, most likely out of
 -- memory, logs it, drops the cached bodies, collects and tries once more
 -- (spec 6.9). Returns fn's two results, or nil and "Page too large for memory".
@@ -583,6 +684,7 @@ function App:toggleMode()
     local p = self.page
     -- A feed's article list has no reader or full mode.
     if not p or p.isFeedList then return end
+    if p.mode == "native" then return self:toast("Reader mode is for web pages") end
     self:open(p.url, { mode = p.mode == "full" and "reader" or "full", push = false })
 end
 
@@ -606,9 +708,13 @@ end
 function App:open(target, opts)
     opts = opts or {}
     local scheme = url.scheme(target)
-    if scheme ~= "http" and scheme ~= "https" then
+    local web = scheme == "http" or scheme == "https"
+    if not web and scheme ~= "gemini" and scheme ~= "gopher" then
         return self:toast((scheme or "That") .. ":// links aren't supported yet", self.ui.TOAST_WARNING)
     end
+    if web and not self.pool then return self:toast(self.baseErr or App.NO_PROXY, self.ui.TOAST_WARNING) end
+    local blocked = scheme == "gopher" and gopher.blocked(target)
+    if blocked then return self:toast(blocked, self.ui.TOAST_WARNING) end
     self:cancelRefresh() -- frees the connections a refresh holds
     local mode = opts.mode or "reader"
     local cached = self:cacheGet(target, mode)
diff --git a/src/screens/loading.lua b/src/screens/loading.lua
index 19eeb30..a697863 100644
--- a/src/screens/loading.lua
+++ b/src/screens/loading.lua
@@ -23,7 +23,9 @@ local function begin(app, L)
         L.state = "wifi"
         return
     end
-    if app.base and app.base.tls and not app.sys.getClock().synced then
+    -- Only proxy requests check certificate dates (small web spec 9.1).
+    local web = url.scheme(L.url) == "http" or url.scheme(L.url) == "https"
+    if web and app.base and app.base.tls and not app.sys.getClock().synced then
         L.state, L.retryAt = "clock", app.sys.getTimeMs() + RETRY_MS
         return
     end
diff --git a/src/screens/page.lua b/src/screens/page.lua
index 04c00be..e4881a7 100644
--- a/src/screens/page.lua
+++ b/src/screens/page.lua
@@ -97,7 +97,9 @@ function S.draw(app)
     local left = url.host(p.url)
     if ps.digits ~= "" then left = "Link: " .. ps.digits .. "_" end
     -- A page that advertises a feed (X-Feed-Url) hints that F5 subscribes.
-    local right = (p.feedUrl and "F5 feed  " or "") .. ps:percent() .. "% " .. (MODE_LETTER[p.mode] or "F")
+    -- Gemini and Gopher pages have no mode, so no letter (small web spec 9.5).
+    local letter = p.mode == "native" and "" or (" " .. (MODE_LETTER[p.mode] or "F"))
+    local right = (p.feedUrl and "F5 feed  " or "") .. ps:percent() .. "%" .. letter
     local room = (320 - 16) // th.uiCw - #right - 1
     d.setFont(th.ui)
     app.ui.drawFooter(left:sub(1, math.min(36, room)), right)
````

- [ ] **Step 6: Run the tests**

Run: `lua tests/run.lua tests/test_app_native.lua && build/lua32 tests/run.lua tests/test_app_native.lua`
Expected: `15 passed, 0 failed` under both.
Then `make test`: `320 passed, 0 failed` under both.

- [ ] **Step 7: Commit**

```bash
git add src/app.lua src/screens/cert.lua src/screens/loading.lua src/screens/page.lua tests/fakepc.lua tests/test_app.lua tests/test_app_native.lua
git commit -m "feat: open Gemini and Gopher pages, with input, certificate review and pictures"
```

---

### Task 10: No proxy needed, search, starter bookmarks and gemlog feeds

**Files:**
- Modify: `src/url.lua` (`normalize(text, opts)`: hosts, searches)
- Modify: `src/store.lua` (`appendBookmarks`)
- Modify: `src/app.lua` (`cfg.search`, `start` and `addStarters`, Go, feed failures, `subscribe`, `openFeed`, `refreshAll`)
- Modify: `src/screens/settings.lua` (the Search row, the no-proxy note)
- Modify: `tests/test_url.lua`, `tests/test_app.lua`, `tests/test_app_native.lua`

**Interfaces:**
- Consumes: Task 9's dispatch and `cert` screen.
- Produces: `url.normalize(text, {proxy = bool, search = string}) -> url` or nil, reason; `store:appendBookmarks(entries) -> count`; `App.SEARCH = "gemini://tlgs.one/search"`; `App.STARTERS` (six `{title, url}`); config keys `search` (a URL, or `"off"`) and `starters` (`"1"`); log line `picosurf: starters <n>`; Settings rows Proxy URL, Token, Font, Images, Search, Test connection.

- [ ] **Step 1: Update and add the tests**

Apply this patch from the repo root (`git apply` reads it from standard input):

````diff
diff --git a/tests/test_app.lua b/tests/test_app.lua
index e24878a..79f4152 100644
--- a/tests/test_app.lua
+++ b/tests/test_app.lua
@@ -90,14 +90,32 @@ local function withoutMemory(fn)
 end
 
 return {
-    first_run_opens_settings = function()
+    first_run_opens_home_with_starter_bookmarks = function()
         local app, F = boot({ config = false })
-        T.eq(app.screenName, "settings")
-        T.ok(F.screenText():find("PicoSurf proxy", 1, true))
-        T.ok(F.hasLog("picosurf: screen settings"))
+        T.eq(app.screenName, "home"); T.ok(F.hasLog("picosurf: starters 6"))
+        local b = app.store:bookmarks()
+        T.eq(#b, 6); T.eq(b[1].url, "gemini://geminiprotocol.net/"); T.eq(b[6].url, "gopher://gopher.floodgap.com/7/v2/vs")
+        T.eq(F.config.starters, "1")
+        F.menu["Settings"](); steps(app, 1)
+        T.ok(F.screenText():find("work without one", 1, true))
+    end,
+    starters_are_added_once_after_existing_bookmarks = function()
+        local F = fakepc.new()
+        F.config.proxy_url, F.config.token = "https://p.test", "tok"
+        local first = App.new(F.pc, "net.picodeck.picosurf")
+        first.store:toggleBookmark("https://mine.test/", "Mine")
+        first.store:toggleBookmark("gemini://tlgs.one/", "TLGS")
+        first:start()
+        local b = first.store:bookmarks()
+        T.eq(#b, 7, "two of mine and five starters"); T.eq(b[1].url, "gemini://tlgs.one/"); T.eq(b[2].url, "https://mine.test/")
+        first.store:removeBookmark(3)
+        local again = App.new(F.pc, "net.picodeck.picosurf")
+        again:start()
+        T.eq(#again.store:bookmarks(), 6, "a deleted starter stays deleted")
     end,
     settings_save_url_and_token_and_warn_on_http = function() -- Review Focus 5
         local app, F = boot({ config = false })
+        F.menu["Settings"](); steps(app, 1)
         F.inputs = { "http://192.168.1.5:8080/x/" }
         F.press("enter"); steps(app, 1)
         T.eq(F.config.proxy_url, "http://192.168.1.5:8080/x/")
@@ -112,11 +130,13 @@ return {
     test_connection_reports_ok_and_token_errors = function()
         local app, F = boot()
         F.menu["Settings"](); steps(app, 1)
-        F.press("down"); F.press("down"); F.press("down"); F.press("down"); F.press("enter"); steps(app)
+        for _ = 1, 5 do F.press("down") end
+        F.press("enter"); steps(app)
         T.ok(F.hasToast("Proxy OK")); T.ok(F.hasLog("picosurf: ping ok"))
         local app2, F2 = boot({ token = "other" })
         F2.menu["Settings"](); steps(app2, 1)
-        F2.press("down"); F2.press("down"); F2.press("down"); F2.press("down"); F2.press("enter"); steps(app2)
+        for _ = 1, 5 do F2.press("down") end
+        F2.press("enter"); steps(app2)
         T.ok(F2.hasToast("Proxy rejected the token - check Settings"))
     end,
     font_setting_switches_to_8x12 = function()
@@ -133,11 +153,30 @@ return {
         T.ok(F.screenText():find("[H] A", 1, true))
         T.eq(app.store:history()[1].url, "https://a.test/")
     end,
-    refuses_text_with_spaces = function()
+    searches_text_that_is_not_a_url = function()
         local app, F = boot()
+        F.tcpServers["tlgs.one:1965"] = { fp = "ff", reply = function() return "20 text/gemini\r\n# Results\n" end }
         go(app, F, "two words")
-        T.ok(F.hasToast("Not a URL (search isn't supported yet)"))
-        T.eq(app.screenName, "home")
+        T.eq(app.page.title, "Results")
+        T.eq(F.tcpMade[1].host, "tlgs.one")
+        T.eq(F.tcpMade[1].writes[1], "gemini://tlgs.one/search?two%20words\r\n")
+    end,
+    the_search_setting_changes_and_turns_off = function()
+        local app, F = boot()
+        F.menu["Settings"](); steps(app, 1)
+        T.ok(F.screenText():find("Search: tlgs.one/search", 1, true))
+        for _ = 1, 4 do F.press("down") end
+        F.inputs = { "gopher://gopher.floodgap.com/7/v2/vs" }
+        F.press("enter"); steps(app, 1)
+        T.eq(F.lastPrompt, "Search URL:"); T.eq(F.config.search, "gopher://gopher.floodgap.com/7/v2/vs")
+        T.ok(F.screenText():find("Search: gopher.floodgap.com/7/v2/vs", 1, true))
+        F.inputs = { "  " }
+        F.press("enter"); steps(app, 1)
+        T.eq(F.config.search, "off"); T.eq(app.cfg.search, "")
+        T.ok(F.screenText():find("Search: (off)", 1, true))
+        F.press("esc"); steps(app, 1)
+        go(app, F, "two words")
+        T.ok(F.hasToast("Not a URL")); T.eq(#F.tcpMade, 0)
     end,
     follows_the_selected_link_and_comes_back_from_the_cache = function()
         local app, F = boot()
@@ -529,6 +568,7 @@ return {
     end,
     fixed_texts_use_the_system_font = function() -- M16; the reading font is for pages only
         local app, F = boot({ config = false, font = "8x12" })
+        F.menu["Settings"](); steps(app, 1)
         F.inputs = { "ftp://x" }
         F.press("enter"); steps(app, 1)
         T.ok(app.baseErr)
diff --git a/tests/test_app_native.lua b/tests/test_app_native.lua
index bb74cd0..93d9903 100644
--- a/tests/test_app_native.lua
+++ b/tests/test_app_native.lua
@@ -183,6 +183,54 @@ return {
         follow(app, F, 4)
         T.eq(app.screenName, "image"); T.eq(F.scaled[1].w, 320); T.eq(F.scaled[1].h, 160)
     end,
+    a_gemini_page_is_its_own_feed = function()
+        local app, F = boot()
+        go(app, F, "gemini://g.test/log/")
+        F.press("f5"); steps(app)
+        T.ok(F.hasLog("picosurf: subscribed 1 gemini://g.test/log/ unread=2"))
+        T.eq(app.store:feedIndex().feeds[1].title, "My log")
+        local items = app.store:feedData(1).items
+        T.eq(#items, 2); T.eq(items[1].url, "gemini://g.test/log/2.gmi"); T.eq(items[1].date, "2024-02-02")
+        T.eq(items[1].title, "Second")
+    end,
+    gemlogs_refresh_without_a_proxy_or_the_clock = function()
+        local app, F = boot({ proxy = false })
+        go(app, F, "gemini://g.test/log/")
+        F.press("f5"); steps(app)
+        F.routes["gemini://g.test/log/"] = "20 text/gemini\r\n=> 3.gmi 2024-03-03 Third\n=> 2.gmi 2024-02-02 Second\n"
+        F.synced = false
+        app:refreshAll(); steps(app)
+        T.ok(F.hasToast("Feeds refreshed")); T.eq(app.store:feedIndex().feeds[1].unread, 2)
+    end,
+    a_web_feed_without_a_proxy_fails_its_refresh = function()
+        local app, F = boot({ proxy = false })
+        require("src.feeds").subscribe(app.store:feedIndex(), "https://w.test/feed.xml", "W")
+        app:refreshAll(); steps(app)
+        T.ok(F.hasToast("1 feed failed to refresh: Web pages need a proxy - set one in Settings"))
+    end,
+    feed_failures_from_native_servers = function()
+        local app, F = boot()
+        go(app, F, "gemini://g.test/log/")
+        F.press("f5"); steps(app)
+        F.tcpServers["g.test:1965"].fp = "cc"
+        app:refreshAll(); steps(app)
+        T.ok(F.hasToast("1 feed failed to refresh: Certificate changed - open it to review"))
+        local feed = app.store:feedIndex().feeds[1]
+        feed.fetched_at = 0
+        app:openFeed(feed); steps(app)
+        T.eq(app.screenName, "cert")
+        F.press("enter"); steps(app)
+        T.eq(app.screenName, "page"); T.eq(app.page.isFeedList, true)
+        F.routes["gemini://g.test/log/"] = "10 Who are you\r\n"
+        app:refreshAll(); steps(app)
+        T.ok(F.hasToast("1 feed failed to refresh: Feed asks for input"))
+    end,
+    f5_on_gopher_explains = function()
+        local app, F = boot()
+        go(app, F, "gopher://h.test/")
+        F.press("f5"); steps(app)
+        T.ok(F.hasToast("Feeds aren't supported for Gopher"))
+    end,
     native_images_that_fail = function()
         local app, F = boot()
         F.failScaled = true
diff --git a/tests/test_url.lua b/tests/test_url.lua
index 4a0b4b2..cafe898 100644
--- a/tests/test_url.lua
+++ b/tests/test_url.lua
@@ -14,15 +14,26 @@ return {
         T.eq(url.host("https://example.com:8080/a?b"), "example.com")
         T.eq(url.host("not a url"), "not a url")
     end,
-    normalize_adds_https_and_trims = function()
-        T.eq(url.normalize("example.com/a"), "https://example.com/a")
+    normalize_keeps_urls_and_trims = function()
         T.eq(url.normalize("  http://x.org/a  "), "http://x.org/a")
+        T.eq(url.normalize("gemini://g.test/a b"), "gemini://g.test/a b")
+        T.eq(select(2, url.normalize("   ")), "Type a URL")
     end,
-    normalize_refuses_spaces_and_empty_text = function()
-        local u, err = url.normalize("two words")
-        T.eq(u, nil)
-        T.eq(err, "Not a URL (search isn't supported yet)")
-        T.eq(url.normalize("   "), nil)
+    normalize_hosts_take_https_with_a_proxy_else_gemini = function()
+        T.eq(url.normalize("example.com/a", { proxy = true }), "https://example.com/a")
+        T.eq(url.normalize("example.com/a"), "gemini://example.com/a")
+    end,
+    normalize_searches_everything_else = function()
+        local s = { search = "gemini://tlgs.one/search" }
+        T.eq(url.normalize("two words", s), "gemini://tlgs.one/search?two%20words")
+        T.eq(url.normalize("localhost", s), "gemini://tlgs.one/search?localhost")
+        T.eq(url.normalize("cats", { search = "https://html.duckduckgo.com/html/?q=%s" }),
+            "https://html.duckduckgo.com/html/?q=cats")
+        T.eq(url.normalize("100% cats", { search = "https://s.test/?q=%s" }), "https://s.test/?q=100%25%20cats")
+        T.eq(url.normalize("cats", { search = "gopher://gopher.floodgap.com/7/v2/vs" }),
+            "gopher://gopher.floodgap.com/7/v2/vs%09cats")
+        local u, err = url.normalize("two words", { search = "" })
+        T.eq(u, nil); T.eq(err, "Not a URL")
     end,
     parse_base_variants = function() -- Review Focus 5
         local b = url.parseBase("https://p.example.com")
````

- [ ] **Step 2: Run them to see them fail**

Run: `make test`
Expected: FAIL in `test_url.lua` (normalize), `test_app.lua` (first run, search, Settings rows) and `test_app_native.lua` (the feed cases).

- [ ] **Step 3: Make the changes**

Apply this patch from the repo root (`git apply` reads it from standard input):

````diff
diff --git a/src/app.lua b/src/app.lua
index 14696cd..70c5704 100644
--- a/src/app.lua
+++ b/src/app.lua
@@ -20,6 +20,16 @@ App.__index = App
 App.MAX_BACK, App.MAX_CACHE = 20, 3
 App.NO_PROXY = "Web pages need a proxy - set one in Settings"
 App.PROMPT_MAX = 48 -- a Gemini input prompt, cut to ui.textInput's width
+App.SEARCH = "gemini://tlgs.one/search"
+-- Added once, after the user's own bookmarks (small web spec 9.4).
+App.STARTERS = {
+    { title = "Gemini project", url = "gemini://geminiprotocol.net/" },
+    { title = "Cosmos (gemlogs)", url = "gemini://cosmos.skyjake.fi/" },
+    { title = "CAPCOM (gemlogs)", url = "gemini://gemini.circumlunar.space/capcom/" },
+    { title = "TLGS search", url = "gemini://tlgs.one/" },
+    { title = "Floodgap Gopher", url = "gopher://gopher.floodgap.com/" },
+    { title = "Veronica-2 search", url = "gopher://gopher.floodgap.com/7/v2/vs" },
+}
 
 -- A copy of a page's inline box heights, for a Back entry or Reload (inline images spec 5.6).
 local function copyBoxes(b)
@@ -53,6 +63,9 @@ function App:loadConfig()
         proxyUrl = c.get("proxy_url") or "", token = c.get("token") or "", font = fonts.normalize(c.get("font")),
         images = c.get("images") == "inline" and "inline" or "links",
     }
+    -- "off" turns search off (Settings -> Search left empty); nothing saved means TLGS.
+    local search = c.get("search")
+    self.cfg.search = search == nil and App.SEARCH or (search == "off" and "" or search)
     local fontChanged = self:loadFont()
     self.oldProxyWarned = nil -- a changed setting, say a newer proxy: pictures are tried again
     self:cancelRefresh() -- before closeAll, which would fail its requests
@@ -155,13 +168,22 @@ function App:show(name, args)
     if self.screen.enter then self.screen.enter(self, args or {}) end
 end
 
+-- Home, with or without a proxy: Gemini and Gopher need none (small web
+-- spec 9.1).
 function App:start()
     self:addMenuItems()
-    if self.cfg.proxyUrl == "" then
-        self:show("settings", { firstRun = true })
-    else
-        self:show("home")
-    end
+    self:addStarters()
+    self:show("home")
+end
+
+-- The starter bookmarks, once per device (small web spec 9.4).
+function App:addStarters()
+    local c = self.pc.config
+    if c.get("starters") ~= nil then return end
+    local added = self.store:appendBookmarks(App.STARTERS)
+    c.set("starters", "1")
+    c.save()
+    self:log("starters", added)
 end
 
 -- One pass of the main loop: input, finished requests, the screen's own
@@ -667,7 +689,7 @@ function App:promptGo(default)
     self.input.clearState()
     self.dirty = true
     if not text then return end
-    local target, err = url.normalize(text)
+    local target, err = url.normalize(text, { proxy = self.pool ~= nil, search = self.cfg.search })
     if not target then return self:toast(err, self.ui.TOAST_WARNING) end
     self:open(target)
 end
@@ -806,20 +828,30 @@ function App:applyFeed(feed, r)
     return data
 end
 
+-- Why a feed request failed, for its toast (small web spec 5, 6).
+local function feedFailure(r)
+    if r.kind == "input" then return "Feed asks for input" end
+    if r.kind == "certchanged" then return "Certificate changed - open it to review" end
+    return r.message
+end
+
 -- F5 on a page: subscribe to the feed it advertises (X-Feed-Url), or let the
--- proxy look for one from the page's URL.
+-- proxy look for one from the page's URL. A Gemini page is its own feed: its
+-- dated links (small web spec 9.6).
 function App:subscribe()
     local p = self.page
     if not p then return end
     if p.isFeedList then return self:toast("Already subscribed") end
+    if url.scheme(p.url) == "gopher" then return self:toast("Feeds aren't supported for Gopher") end
     self:show("loading", {
         url = p.feedUrl or p.url, as = "feed",
         onCancel = function() self:show("page") end,
         onResult = function(r)
             self:show("page")
             if r.kind ~= "gemini" then
-                self:log("error", r.status or "-", r.message)
-                return self:toast(r.message or "Not a feed", self.ui.TOAST_ERROR)
+                local why = feedFailure(r) or "Not a feed"
+                self:log("error", r.status or "-", why)
+                return self:toast(why, self.ui.TOAST_ERROR)
             end
             local index = self.store:feedIndex()
             local feed, isNew = feeds.subscribe(index, r.finalUrl or p.url, (r.title ~= "" and r.title) or nil)
@@ -845,11 +877,15 @@ function App:openFeed(feed, opts)
         url = feed.url, as = "feed",
         onCancel = function() self:show(self.page and "page" or "home") end,
         onResult = function(r)
+            if r.kind == "certchanged" then
+                return self:show("cert", { change = r, retry = function() self:openFeed(feed, opts) end })
+            end
             if r.kind == "gemini" then
                 self:applyFeed(feed, r)
             else
-                self:log("error", r.status or "-", r.message)
-                self:toast(r.message or "Refresh failed", self.ui.TOAST_ERROR)
+                local why = feedFailure(r) or "Refresh failed"
+                self:log("error", r.status or "-", why)
+                self:toast(why, self.ui.TOAST_ERROR)
             end
             self:showFeed(feed, opts)
         end,
@@ -875,6 +911,15 @@ function App:showFeed(feed, opts)
     self:show("page")
 end
 
+-- Whether any feed is a website's, fetched through the proxy.
+local function hasWebFeed(list)
+    for _, f in ipairs(list) do
+        local s = url.scheme(f.url)
+        if s == "http" or s == "https" then return true end
+    end
+    return false
+end
+
 -- F5 on the Feeds tab: refresh every feed, two requests at a time. Without
 -- WiFi, or before the clock is set for TLS, it doesn't start: the loading
 -- screen's waits would hold the Feeds tab.
@@ -886,7 +931,7 @@ function App:refreshAll()
         self:log("error", "-", "No WiFi")
         return self:toast("No WiFi - can't refresh feeds", self.ui.TOAST_WARNING)
     end
-    if self.base and self.base.tls and not self.sys.getClock().synced then
+    if self.base and self.base.tls and not self.sys.getClock().synced and hasWebFeed(list) then
         self:log("error", "-", "Clock not set")
         return self:toast("Clock not set yet - try again in a moment", self.ui.TOAST_WARNING)
     end
@@ -917,7 +962,7 @@ function App:pumpRefresh()
                 if self:feedById(feed.id) then self:applyFeed(feed, r) end
                 R.ok = R.ok + 1
             else
-                refreshFailed(self, R, r.status, r.message) -- a "clock" result too
+                refreshFailed(self, R, r.status, feedFailure(r)) -- a "clock" result too
             end
             self:pumpRefresh()
         end)
diff --git a/src/screens/settings.lua b/src/screens/settings.lua
index 5e8d8d5..3cba8aa 100644
--- a/src/screens/settings.lua
+++ b/src/screens/settings.lua
@@ -1,13 +1,14 @@
--- Settings: proxy URL, token, font and a connection test (spec 6.8).
+-- Settings: proxy URL, token, font, images, search and a connection test
+-- (spec 6.8, small web spec 9.3).
 local wrap = require("src.wrap")
 local theme = require("src.theme")
 local fonts = require("src.fonts")
 
 local S = {}
-local ITEMS = { "proxy", "token", "font", "images", "test" }
+local ITEMS = { "proxy", "token", "font", "images", "search", "test" }
 
-function S.enter(app, args)
-    app.set = { sel = 1, firstRun = args.firstRun }
+function S.enter(app)
+    app.set = { sel = 1 }
 end
 
 local function label(app, item)
@@ -16,6 +17,7 @@ local function label(app, item)
     if item == "token" then return "Token: " .. (c.token ~= "" and ("****" .. c.token:sub(-4)) or "(not set)") end
     if item == "font" then return "Font: " .. fonts.LABELS[c.font] end
     if item == "images" then return "Images: " .. (c.images == "inline" and "Inline" or "Links") end
+    if item == "search" then return "Search: " .. (c.search ~= "" and (c.search:gsub("^%a[%w+.%-]*://", "")) or "(off)") end
     return "Test connection"
 end
 
@@ -26,14 +28,9 @@ function S.draw(app)
         app.ui.drawListItem(0, 30 + (i - 1) * 16, 320, label(app, item), i == set.sel, true)
     end
     local notes = {}
-    if set.firstRun then
-        notes = {
-            "PicoSurf reads the web through a",
-            "PicoSurf proxy you run yourself.",
-            "Setup: github.com/PicoDeck/picosurf",
-            "(proxy/README.md), then enter its",
-            "URL and token above.",
-        }
+    if app.cfg.proxyUrl == "" then
+        notes[1] = "Web pages need a PicoSurf proxy (setup: github.com/PicoDeck/picosurf). "
+            .. "Gemini and Gopher work without one."
     end
     if app.cfg.proxyUrl:lower():match("^http://") then
         notes[#notes + 1] = "Warning: http:// sends the token unencrypted."
@@ -75,6 +72,13 @@ function S.key(app, action)
             app:saveConfig("font", fonts.nextChoice(app.cfg.font)) -- lays the page out again
         elseif item == "images" then
             app:setImages(app.cfg.images == "inline" and "links" or "inline")
+        elseif item == "search" then
+            local v = app.ui.textInput("Search URL:", app.cfg.search)
+            app.input.clearState()
+            if v then
+                v = trim(v)
+                app:saveConfig("search", v == "" and "off" or v)
+            end
         else
             app:ping()
         end
diff --git a/src/store.lua b/src/store.lua
index 98cc24b..bed4079 100644
--- a/src/store.lua
+++ b/src/store.lua
@@ -136,6 +136,21 @@ function M:toggleBookmark(u, title)
     return true
 end
 
+-- Appends the entries ({url, title}) not already bookmarked, within the cap.
+-- Returns how many were added.
+function M:appendBookmarks(entries)
+    local list, n = self:bookmarks(), 0
+    for _, e in ipairs(entries) do
+        if #list >= M.MAX_BOOKMARKS then break end
+        if not indexOf(list, e.url) then
+            list[#list + 1] = { url = e.url, title = e.title }
+            n = n + 1
+        end
+    end
+    if n > 0 then self:save("bookmarks.json", list) end
+    return n
+end
+
 function M:removeBookmark(i)
     local list = self:bookmarks()
     if list[i] == nil then return end
diff --git a/src/url.lua b/src/url.lua
index 98e4903..6dbf2b4 100644
--- a/src/url.lua
+++ b/src/url.lua
@@ -15,13 +15,23 @@ function M.host(u)
     return u:match("^%a[%w+.%-]*://([^/?#:]+)") or u
 end
 
--- What the user typed, as a URL, or nil and a reason. No scheme means https.
-function M.normalize(text)
+-- What the user typed in Go, as a URL, or nil and a reason (small web spec
+-- 9.2). opts.proxy: a proxy is set, so a bare host means https:// rather
+-- than gemini://. opts.search: the search URL ("" for none); text that is not
+-- a URL or a host is searched for: %s in it replaced by the query, else the
+-- query after "%09" (gopher://) or "?".
+function M.normalize(text, opts)
+    opts = opts or {}
     local t = text:match("^%s*(.-)%s*$")
     if t == "" then return nil, "Type a URL" end
-    if t:find("%s") then return nil, "Not a URL (search isn't supported yet)" end
-    if not t:find("://", 1, true) then t = "https://" .. t end
-    return t
+    if t:find("://", 1, true) then return t end
+    if not t:find("%s") and t:find(".", 1, true) then return (opts.proxy and "https://" or "gemini://") .. t end
+    local s = opts.search or ""
+    if s == "" then return nil, "Not a URL" end
+    local q = M.encode(t)
+    if s:find("%s", 1, true) then return (s:gsub("%%s", function() return q end)) end
+    if M.scheme(s) == "gopher" then return s .. "%09" .. q end
+    return s .. "?" .. q
 end
 
 -- The proxy's base URL: {host, port, tls, prefix} or nil and a reason.
````

- [ ] **Step 4: Run the tests**

Run: `make test`
Expected: `328 passed, 0 failed` under both.

- [ ] **Step 5: Commit**

```bash
git add src/url.lua src/store.lua src/app.lua src/screens/settings.lua tests/test_url.lua tests/test_app.lua tests/test_app_native.lua
git commit -m "feat: no proxy needed for the small web; search, starter bookmarks and gemlog feeds"
```

---

### Task 11: Simulator tests with local Gemini and Gopher servers

**Files:**
- Create: `tests/e2e/certs/a.pem`, `tests/e2e/certs/b.pem` (generated)
- Create: `tests/e2e/small_servers.py`
- Create: `tests/e2e/test_small_web.py`
- Modify: `tests/e2e/test_app.py` (first run opens Home with the starters)

**Interfaces:**
- Consumes: the app as of Task 10; the PicoDeck simulator from the firmware plan (`feat/tcp-peer-fingerprint`: TLS sockets honour `setInsecure` and report `peerFingerprint()`).
- Produces: `GeminiServer(cert)` (`routes` by request URL, `requests`, `use_cert(name)`, `base`), `GopherServer()` (`routes` by selector, `item(kind, label, selector)`, `base`), `fingerprint(pem_path)`.

- [ ] **Step 1: Check the simulator**

The Gemini tests need a simulator built from the firmware plan's branch. If it isn't merged into the checkout `PICODECK_ROOT` names, build it in that plan's worktree (`make simulator` in `/home/keith/Projects/PicoDeck/picodeck/.worktrees/tcp-fingerprint`) and pass `PICODECK_SIM_BINARY=/home/keith/Projects/PicoDeck/picodeck/.worktrees/tcp-fingerprint/build_sim/picodeck_simulator` to every `make e2e` below. Without it, every Gemini test fails at connect (`Secure connection to 127.0.0.1 failed ...` in the log).

- [ ] **Step 2: Generate the test certificates**

```bash
mkdir -p tests/e2e/certs
for n in a b; do
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 36500 \
    -subj "/CN=localhost" -keyout /tmp/ps_key.pem -out /tmp/ps_cert.pem
  cat /tmp/ps_cert.pem /tmp/ps_key.pem > tests/e2e/certs/$n.pem
done
rm /tmp/ps_key.pem /tmp/ps_cert.pem
```

The tests compute fingerprints from these files, so any certificates generated this way work.

- [ ] **Step 3: Write the servers**

Create `tests/e2e/small_servers.py`:

````python
"""Local Gemini and Gopher servers for PicoSurf's simulator tests. Both
listen on 127.0.0.1 with an OS-assigned port, answer from a routes dict that
a test may change at any time, and record what they were asked. The
certificates in certs/ are fixed self-signed EC P-256 test certificates."""
import hashlib
import socket
import ssl
import threading
from pathlib import Path

CERTS = Path(__file__).resolve().parent / "certs"


def fingerprint(pem_path: Path) -> str:
    """The SHA-256 of the certificate in a PEM file, lowercase hex: what
    tcp:peerFingerprint() reports and known_hosts.json keeps."""
    pem = pem_path.read_text()
    begin = pem.index("-----BEGIN CERTIFICATE-----")
    end = pem.index("-----END CERTIFICATE-----") + len("-----END CERTIFICATE-----")
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem[begin:end])).hexdigest()


class _Server:
    def __init__(self):
        self.routes = {}
        self.requests = []
        self.sock = socket.create_server(("127.0.0.1", 0))
        self.port = self.sock.getsockname()[1]

    def start(self):
        threading.Thread(target=self._serve, daemon=True).start()
        return self

    def _serve(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _request_line(self, s) -> str:
        data = b""
        while b"\n" not in data and len(data) < 2048:
            chunk = s.recv(2048)
            if not chunk:
                break
            data += chunk
        return data.split(b"\r\n")[0].split(b"\n")[0].decode("utf-8", "replace")

    def stop(self):
        self.sock.close()


class GeminiServer(_Server):
    """routes: request URL -> whole response (header and body, str or bytes);
    anything else gets 51. use_cert() swaps the certificate for new
    connections."""

    def __init__(self, cert="a.pem"):
        super().__init__()
        self.use_cert(cert)

    def use_cert(self, name: str):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(str(CERTS / name))
        self.ctx = ctx

    @property
    def base(self) -> str:
        return f"gemini://127.0.0.1:{self.port}/"

    def _handle(self, conn):
        try:
            with self.ctx.wrap_socket(conn, server_side=True) as s:
                s.settimeout(5)
                url = self._request_line(s)
                self.requests.append(url)
                reply = self.routes.get(url, "51 Not found\r\n")
                s.sendall(reply if isinstance(reply, bytes) else reply.encode("utf-8"))
        except (OSError, ssl.SSLError):
            pass


class GopherServer(_Server):
    """routes: selector line (search after a tab) -> reply; anything else
    gets an error item."""

    @property
    def base(self) -> str:
        return f"gopher://127.0.0.1:{self.port}/"

    def item(self, kind: str, label: str, selector: str) -> str:
        return f"{kind}{label}\t{selector}\t127.0.0.1\t{self.port}\r\n"

    def _handle(self, conn):
        try:
            with conn:
                conn.settimeout(5)
                selector = self._request_line(conn)
                self.requests.append(selector)
                reply = self.routes.get(selector, "3Not found\t\terror.host\t1\r\n.\r\n")
                conn.sendall(reply if isinstance(reply, bytes) else reply.encode("utf-8"))
        except OSError:
            pass
````

- [ ] **Step 4: Write the tests**

Create `tests/e2e/test_small_web.py`:

````python
"""Gemini and Gopher in the simulator (small web spec 12.2), against local
servers: pages and relative links, input, a changed certificate, Gopher menus
and text, and a gemlog subscription. Needs a simulator whose TLS sockets honour
setInsecure and report tcp:peerFingerprint() (PicoDeck's
feat/tcp-peer-fingerprint, in develop)."""
import json
import time

import pytest

from small_servers import GeminiServer, GopherServer, fingerprint, CERTS
from test_app import act, no_lua_errors, open_first_history, seed_history, start_app, wait


@pytest.fixture
def gemini():
    server = GeminiServer().start()
    yield server
    server.stop()


@pytest.fixture
def gopher():
    server = GopherServer().start()
    yield server
    server.stop()


def test_gemini_page_and_relative_link(picosurf, gemini):
    sim, _, data = picosurf()
    gemini.routes[gemini.base] = "20 text/gemini\r\n# Capsule\n=> sub.gmi Sub page\n"
    gemini.routes[gemini.base + "sub.gmi"] = "20 text/gemini\r\n# Sub\n"
    seed_history(data, gemini.base)
    wait(sim, r"picosurf: screen home", start_app(sim))
    wait(sim, rf"picosurf: loaded {gemini.base} mode=native", open_first_history(sim))
    wait(sim, rf"picosurf: loaded {gemini.base}sub\.gmi", act(sim, "enter"))
    hosts = json.loads((data / "known_hosts.json").read_text())
    assert hosts[f"127.0.0.1:{gemini.port}"]["fp"] == fingerprint(CERTS / "a.pem")
    no_lua_errors(sim)


def test_gemini_input(picosurf, gemini):
    sim, _, data = picosurf()
    gemini.routes[gemini.base] = "20 text/gemini\r\n# Capsule\n=> search Search\n"
    gemini.routes[gemini.base + "search"] = "10 Search for\r\n"
    gemini.routes[gemini.base + "search?cats"] = "20 text/gemini\r\n# Cats\n"
    seed_history(data, gemini.base)
    wait(sim, r"picosurf: screen home", start_app(sim))
    wait(sim, rf"picosurf: loaded {gemini.base}", open_first_history(sim))
    m = act(sim, "enter")
    wait(sim, r"picosurf: prompt input", m)
    time.sleep(0.5)  # the text box opens after the log line
    for c in "cats":
        sim.keypress(c)
    sim.keypress("\n")
    wait(sim, rf"picosurf: loaded {gemini.base}search\?cats", m)
    no_lua_errors(sim)


def test_changed_certificate_is_reviewed(picosurf, gemini):
    sim, _, data = picosurf()
    gemini.routes[gemini.base] = "20 text/gemini\r\n# Capsule\n=> sub.gmi Sub page\n"
    gemini.routes[gemini.base + "sub.gmi"] = "20 text/gemini\r\n# Sub\n"
    seed_history(data, gemini.base)
    wait(sim, r"picosurf: screen home", start_app(sim))
    wait(sim, rf"picosurf: loaded {gemini.base} ", open_first_history(sim))
    gemini.use_cert("b.pem")
    wait(sim, r"picosurf: screen cert", act(sim, "enter"))
    assert gemini.base + "sub.gmi" not in gemini.requests, "the request waited for the review"
    m = act(sim, "enter")
    wait(sim, rf"picosurf: cert accepted 127\.0\.0\.1:{gemini.port}", m)
    wait(sim, rf"picosurf: loaded {gemini.base}sub\.gmi", m)
    hosts = json.loads((data / "known_hosts.json").read_text())
    assert hosts[f"127.0.0.1:{gemini.port}"]["fp"] == fingerprint(CERTS / "b.pem")
    no_lua_errors(sim)


def test_gopher_menu_and_text(picosurf, gopher):
    sim, _, data = picosurf()
    gopher.routes[""] = "iWelcome\t\t127.0.0.1\t1\r\n" + gopher.item("0", "About", "/about") + ".\r\n"
    gopher.routes["/about"] = "About this hole.\r\n.\r\n"
    seed_history(data, gopher.base)
    wait(sim, r"picosurf: screen home", start_app(sim))
    wait(sim, rf"picosurf: loaded {gopher.base} mode=native", open_first_history(sim))
    wait(sim, rf"picosurf: loaded {gopher.base}0/about", act(sim, "enter"))
    no_lua_errors(sim)


def test_gemlog_subscription(picosurf, gemini):
    sim, _, data = picosurf()
    log = gemini.base + "log.gmi"
    gemini.routes[log] = "20 text/gemini\r\n# Log\n=> 2.gmi 2026-10-02 Two\n=> 1.gmi 2026-10-01 One\n"
    seed_history(data, log)
    wait(sim, r"picosurf: screen home", start_app(sim))
    wait(sim, rf"picosurf: loaded {log}", open_first_history(sim))
    wait(sim, rf"picosurf: subscribed 1 {log} unread=2", act(sim, "f5"))
    no_lua_errors(sim)
````

Apply this patch from the repo root (`git apply` reads it from standard input):

````diff
diff --git a/tests/e2e/test_app.py b/tests/e2e/test_app.py
index 0453a81..e3dafe8 100644
--- a/tests/e2e/test_app.py
+++ b/tests/e2e/test_app.py
@@ -77,9 +77,12 @@ def start_app(sim):
     return m
 
 
-def test_first_run_opens_settings(picosurf):
-    sim, _, _ = picosurf(config=False)
-    wait(sim, r"picosurf: screen settings", start_app(sim))
+def test_first_run_opens_home_with_starters(picosurf):
+    sim, _, data = picosurf(config=False)
+    wait(sim, r"picosurf: starters 6", start_app(sim))
+    wait(sim, r"picosurf: screen home", 0)
+    bookmarks = json.loads((data / "bookmarks.json").read_text())
+    assert [b["url"] for b in bookmarks][0] == "gemini://geminiprotocol.net/"
     no_lua_errors(sim)
 
 
````

- [ ] **Step 5: Run them**

Run: `make e2e` (with `PICODECK_SIM_BINARY` from Step 1 if needed)
Expected: `13 passed`.

- [ ] **Step 6: Commit**

```bash
git add tests/e2e/certs/a.pem tests/e2e/certs/b.pem tests/e2e/small_servers.py tests/e2e/test_small_web.py tests/e2e/test_app.py
git commit -m "test: Gemini and Gopher in the simulator against local servers"
```

---

### Task 12: Docs: README, the main spec and the hardware pass

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-10-15-picosurf-design.md` (the changes small web spec section 14 lists)
- Modify: `docs/hardware-pass.md` (item 1, new item 24)

**Interfaces:**
- Consumes: the behaviour of Tasks 9-11.

- [ ] **Step 1: Apply the doc changes**

Apply this patch from the repo root (`git apply` reads it from standard input):

````diff
diff --git a/README.md b/README.md
index 1f240d2..32e3813 100644
--- a/README.md
+++ b/README.md
@@ -1,15 +1,15 @@
 # PicoSurf
 
-Read the web and RSS/Atom feeds on a [PicoDeck](https://picodeck.net) PicoCalc. Pages come through your own **PicoSurf proxy**, which does the heavy lifting:
+Read Gemini and Gopher, the web and RSS/Atom feeds on a [PicoDeck](https://picodeck.net) PicoCalc. Gemini and Gopher pages are fetched by the PicoCalc itself. Web pages come through your own **PicoSurf proxy**, which does the heavy lifting:
 - fetches the page
 - extracts the article with Mozilla Readability
 - turns it into plain-ASCII gemtext the PicoCalc can draw
 - shrinks images to fit the screen
 
 ## Set up
-1. Deploy the proxy: see [proxy/README.md](proxy/README.md), for Cloudflare Workers or Docker.
-2. Install PicoSurf from the PicoDeck App Store.
-3. On first launch, PicoSurf opens Settings. Enter the proxy URL and token there, then choose **Test connection**. You can also put the URL and token in `/data/net.picodeck.picosurf/config.json` from a computer, as `{"proxy_url": "...", "token": "..."}`.
+1. Install PicoSurf from the PicoDeck App Store. It opens on Home with a few starter bookmarks for Gemini and Gopher, which need nothing else.
+2. For web pages, deploy the proxy: see [proxy/README.md](proxy/README.md), for Cloudflare Workers or Docker.
+3. Open Settings from the system menu, enter the proxy URL and token, then choose **Test connection**. You can also put the URL and token in `/data/net.picodeck.picosurf/config.json` from a computer, as `{"proxy_url": "...", "token": "..."}`.
 
 ## Keys
 | Key | On a page | On Home |
@@ -21,11 +21,11 @@ Read the web and RSS/Atom feeds on a [PicoDeck](https://picodeck.net) PicoCalc.
 | Enter | open the selected link | open |
 | digits, then Enter | open link `[n]` (Backspace deletes a digit, Esc clears the number) | |
 | Backspace / Esc | back (on the first page: Home) | Esc: quit, or stop a refresh |
-| F1 | go to a URL | go to a URL |
+| F1 | go to a URL, or search | go to a URL, or search |
 | F2 | Home | |
 | F3 | bookmark / remove bookmark | |
-| F4 | reader / full page | |
-| F5 | subscribe to the page's feed (the footer shows `F5 feed` when the page names one) | refresh all feeds (Feeds tab) |
+| F4 | reader / full page (web pages) | |
+| F5 | subscribe to the page's feed (the footer shows `F5 feed` when the page names one); on a Gemini page, to its dated posts | refresh all feeds (Feeds tab) |
 | Del | | remove the selected entry |
 
 While a page loads, only Esc cancels it. On an error, Enter retries and Esc or Backspace goes back; on an image, Esc or Backspace goes back.
@@ -34,6 +34,13 @@ The system menu has Reload, Edit URL, Mark all read and Settings.
 
 **Images** in Settings switches between Links (an `[IMG]` line; Enter opens the picture full screen) and Inline (pictures in the page, loaded as you read; Enter still opens one full screen). Inline needs a proxy from the same version or later: redeploy the proxy when you update.
 
+## Gemini and Gopher
+Type a `gemini://` or `gopher://` URL in Go (F1), or follow a link to one. A bare host like `geminiprotocol.net` opens as `https://` when a proxy is set and as `gemini://` when not. Anything else you type is a search: **Search** in Settings holds the search URL (TLGS by default; `%s` in it is replaced by your words, and a `gopher://` search URL gets them as a Gopher search). Leave it empty to turn search off.
+
+PicoSurf pins each Gemini site's certificate on your first visit, in `known_hosts.json`. If it later changes, you see **Certificate changed**: Enter trusts the new one, Esc goes back. Sites change certificates when they renew, but it can also mean someone is intercepting the connection. Pinning needs a PicoDeck firmware with `tcp:peerFingerprint()`; older firmware loads pages without it.
+
+Limits: the firmware speaks TLS 1.2 only and cannot read Ed25519 certificates, so about 5% of Gemini sites won't open (`docs/research/2026-10-16-gemini-tls-survey.md`). A Gemini "sensitive input" prompt shows what you type. Gopher text is reflowed into your reading font, except blocks that look like ASCII art or tables. Pictures from Gemini and Gopher open full screen, shrunk to fit.
+
 **Font** in Settings steps through Scientifica, 8x12, Sans, Serif and System (6x8). Sans is the default: a proportional font that fits about 57 characters a line. System is the smallest: 28 lines a screen. Code blocks always use a monospace font.
 
 ## Credits
@@ -43,12 +50,12 @@ The Sans and Serif reading fonts are converted from X.Org's Adobe bitmap fonts b
 
 ## Development
 - `make test`: Lua unit tests under stock Lua and under `lua32`, which has the device's 32-bit numbers. Building `lua32` needs a PicoDeck checkout; set `PICODECK_ROOT`.
-- `make e2e`: runs the smoke tests locally in the PicoDeck simulator, against a fake proxy. They need a PicoDeck checkout, set by `PICODECK_ROOT` (default `~/Projects/PicoDeck/picodeck`). Run `make simulator` in that checkout first. The F1 "Go to" test types Enter's `\n` through the simulator's control channel, which needs a simulator built with PicoDeck's `fix/sim-enter-char` (JSON strings unescaped); an older one fails that test with a message saying so.
+- `make e2e`: runs the smoke tests locally in the PicoDeck simulator, against a fake proxy and local Gemini and Gopher servers. They need a PicoDeck checkout, set by `PICODECK_ROOT` (default `~/Projects/PicoDeck/picodeck`). Run `make simulator` in that checkout first. The F1 "Go to" test types Enter's `\n` through the simulator's control channel, which needs a simulator built with PicoDeck's `fix/sim-enter-char` (JSON strings unescaped); an older one fails that test with a message saying so. The Gemini tests need a simulator whose TLS sockets honour `setInsecure` and report `peerFingerprint()` (PicoDeck's `feat/tcp-peer-fingerprint`).
 - The proxy has its own tests: `cd proxy && npm test`.
 - Releases: bump `version` in `app.json`, then tag `v<version>`. CI builds the store ZIP, `picosurf-<version>.zip`.
 
 ## Later
-- Native Gemini and Gopher. Gemini needs a firmware call that returns the server certificate's fingerprint, for trust-on-first-use (TOFU).
+- Spartan, Nex and Finger. TLS 1.3 in the PicoDeck firmware, for the Gemini sites that need it.
 - A longer `ui.textInput` limit, so "Edit URL" works on article URLs over 127 characters.
 - Simulator fixes for end-to-end tests: Shift+Tab (key 0xD2) and HTTP back-pressure should behave as on the device.
 - Web search, saving pages offline, OPML import, non-Latin fonts.
diff --git a/docs/hardware-pass.md b/docs/hardware-pass.md
index 1c929cd..744b022 100644
--- a/docs/hardware-pass.md
+++ b/docs/hardware-pass.md
@@ -2,7 +2,7 @@
 
 Run this on a real PicoCalc with PicoDeck 0.5.0 or later, against the deployed Worker. Record the results in the release notes.
 
-1. Fresh install: PicoSurf opens Settings. Enter the proxy URL and token. **Test connection** shows "Proxy OK".
+1. Fresh install: PicoSurf opens Home with the six starter bookmarks. Open Settings from the system menu, enter the proxy URL and token. **Test connection** shows "Proxy OK".
 2. F1 `en.wikipedia.org/wiki/Gemini_(protocol)`. Time from Enter to the first screen: ______ s (target under 5 s on home WiFi).
 3. On that page: scroll to the end with Right, check the footer reaches 100%, then follow a link by number and by Tab, and go Back.
 4. Every page on the proxy's smoke list (`proxy/scripts/smoke.ts`) opens without a Lua error.
@@ -26,4 +26,12 @@ Run this on a real PicoCalc with PicoDeck 0.5.0 or later, against the deployed W
 22. Settings → Images: Inline. Open an article with 10 or more images. Time until the first picture shows: ______ s. Scroll to the end and back with Right and Left: pictures appear in place, the text you're reading doesn't jump when a picture above it loads, and keys stay responsive. Lowest Lua heap free in the dev log while scrolling, not only at the end: ______ (above 1 MB). On a long page, the worst hitch when a picture arrives: ______ ms. Enter on a picture opens it full screen.
 23. Settings → Font: Sans (the default), then Serif. Open the Wikipedia fixture article in each: time to the first screen ______ s / ______ s (target under 5 s, as with Scientifica). Read through a long article: no clipped letters, no line running past the right edge, code blocks in Scientifica. Then System (6x8): 28 lines a screen, no letters cut off at the top or bottom of a row, and the selected link's band covers its line.
 
+24. Small web, on a firmware with `tcp:peerFingerprint()`:
+    - Open the Gemini project starter bookmark. Time from Enter to the first screen: ______ s (expect 2-5 s).
+    - `/data/net.picodeck.picosurf/known_hosts.json` now has `geminiprotocol.net:1965`; its `fp` equals `openssl s_client -connect geminiprotocol.net:1965 -servername geminiprotocol.net </dev/null | openssl x509 -noout -fingerprint -sha256` (lowercase, colons removed).
+    - Follow a few links, then Back: pages come from the cache without a second handshake.
+    - Open Floodgap Gopher, then a text file: prose is reflowed, art stays monospace.
+    - F5 on a gemlog from Cosmos subscribes; F5 on the Feeds tab refreshes it.
+    - F1, type `picocalc`: TLGS results open.
+
 Report any missed target as-is; don't round it.
diff --git a/docs/superpowers/specs/2026-10-15-picosurf-design.md b/docs/superpowers/specs/2026-10-15-picosurf-design.md
index 5e5b995..14c62a4 100644
--- a/docs/superpowers/specs/2026-10-15-picosurf-design.md
+++ b/docs/superpowers/specs/2026-10-15-picosurf-design.md
@@ -8,8 +8,8 @@ Status: draft, awaiting review
 Read the ordinary web (news, blogs, documentation) on a PicoCalc running
 PicoDeck. The device cannot run a web engine, so a proxy fetches each page,
 extracts the readable part with Mozilla Readability, and returns it as gemtext,
-which the device renders. Gemini and Gopher are later additions that reuse
-the same renderer.
+which the device renders. Gemini and Gopher are read natively, with no proxy,
+through the same renderer (`2026-10-17-picosurf-small-web-design.md`).
 
 The proxy is self-hosted: the author runs one, and anyone else can deploy
 their own. A public shared instance is not part of v1, but nothing in v1 rules
@@ -27,9 +27,12 @@ it out (section 9).
   `2026-10-16-picosurf-inline-images-design.md`); proportional reading fonts,
   Sans and Serif (`2026-10-16-picosurf-proportional-fonts-design.md`).
 
-**Later (section 9):** native Gemini (needs a firmware call for TOFU), Gopher,
-Spartan, Nex and Finger, web search, saving pages for offline reading, OPML
-import, a public instance, fonts beyond ASCII.
+**Since v1:** native Gemini and Gopher, with certificate pinning, search from
+Go, starter bookmarks and gemlog feeds; the proxy is optional (small web
+design).
+
+**Later (section 9):** Spartan, Nex and Finger, saving pages for offline
+reading, OPML import, a public instance, fonts beyond ASCII.
 
 **Non-goals:** JavaScript, logins, cookies, POST forms, web apps.
 
@@ -316,9 +319,10 @@ Deployment:
 - The body is drained while it arrives, with progress shown via
   `getProgress()`. The device gives up past 512 KB. The read timeout is 20 s.
   Esc cancels by closing the connection.
-- Scheme dispatch: `http` and `https` go to the proxy transport. Any other
-  scheme gets the toast `<scheme>:// links aren't supported yet`. Gemini and
-  Gopher transports slot in here later.
+- Scheme dispatch (small web design 2.1): `http` and `https` go to the proxy
+  transport, `gemini` and `gopher` to the native ones. Without a proxy, a web
+  link gets the toast `Web pages need a proxy - set one in Settings`. Any
+  other scheme gets the toast `<scheme>:// links aren't supported yet`.
 
 ### 6.2 Screens
 
@@ -329,7 +333,10 @@ Deployment:
 - **Loading:** spinner, host, bytes received; Esc cancels.
 - **Error:** status and the proxy's reason; Enter retries, Esc/Backspace goes back.
 - **Image:** the JPEG centred on black; Esc/Backspace goes back.
-- **Settings** (system menu): Proxy URL, Token, Font, Images, Test connection.
+- **Settings** (system menu): Proxy URL, Token, Font, Images, Search, Test
+  connection.
+- **Certificate changed:** a pinned Gemini certificate changed; Enter trusts
+  the new one, Esc goes back (small web design 6).
 
 ### 6.3 Layout and drawing
 
@@ -380,11 +387,11 @@ as below.
 | Enter | open the selected link (does nothing when none is selected) |
 | 0-9 | build a link number, shown in the footer (`Link: 12_`); Enter opens `[n]`; Backspace deletes a digit; Esc clears the number |
 | Backspace / Esc (no number being typed) | Back; on the first page in the stack, go Home; on Home, Esc exits |
-| F1 | Go: `ui.textInput("Go to:")`; `https://` added when there's no scheme; input with spaces → toast `Not a URL (search isn't supported yet)` |
+| F1 | Go: `ui.textInput("Go to:")`; a host gets `https://` with a proxy, `gemini://` without; other text is searched for (small web design 9.2) |
 | F2 | Home |
 | F3 | add or remove a bookmark (toast) |
-| F4 | switch reader / full and reload |
-| F5 | on a page with `X-Feed-Url` or a feed list: Subscribe; on the Feeds tab: refresh all |
+| F4 | switch reader / full and reload; on a Gemini or Gopher page, toast `Reader mode is for web pages` |
+| F5 | on a page with `X-Feed-Url`, a feed list or a Gemini page: Subscribe; on a Gopher page, toast `Feeds aren't supported for Gopher`; on the Feeds tab: refresh all |
 
 System menu items (`sys.addMenuItem`): Reload, Edit URL (pre-filled when the
 URL is 128 characters or less, otherwise a toast), Mark all read (in a feed),
@@ -407,7 +414,8 @@ Files live in `/data/net.picodeck.picosurf/`.
 
 | File | Contents | Cap |
 |---|---|---|
-| `config.json` (`picocalc.config`) | `proxy_url`, `token`, `font` (`sans`, `serif`, `scientifica`, `8x12` or `system`), `images` | — |
+| `config.json` (`picocalc.config`) | `proxy_url`, `token`, `font` (`sans`, `serif`, `scientifica`, `8x12` or `system`), `images`, `search` (a URL, or `off`), `starters` | — |
+| `known_hosts.json` | `{"host:port": {fp, first, seen}}`, pinned Gemini certificates (small web design 6) | 500 |
 | `bookmarks.json` | `[{url, title}]`, newest first | 200 |
 | `history.json` | `[{url, title}]`, newest first, revisits move to the top | 100 |
 | `feeds/index.json` | `{next_id, feeds: [{id, url, title, fetched_at, unread}]}` | 50 feeds |
@@ -424,7 +432,8 @@ Files live in `/data/net.picodeck.picosurf/`.
 
 - **Subscribe:** F5 sends `as=feed` with the current URL. The proxy finds the
   feed if the URL is a homepage. The feed is stored under its `X-Final-Url`
-  and `X-Title`. All of its items start unread.
+  and `X-Title`. All of its items start unread. A Gemini page is its own
+  feed: its dated links, fetched natively (small web design 9.6).
 - **Refresh one feed:** replace `items` with the latest list (up to 50),
   prune `seen` to URLs still in `items`, recompute `unread`, update
   `fetched_at`.
@@ -443,8 +452,9 @@ Files live in `/data/net.picodeck.picosurf/`.
 
 ### 6.8 Settings and first run
 
-- **First run:** with no `proxy_url`, open Settings with a short explanation
-  that points to the repo's proxy setup section.
+- **First run:** Home, with the starter bookmarks (small web design 9.1, 9.4).
+  While no proxy is set, Settings explains that web pages need one and points
+  to the repo's proxy setup section.
 - **Fields:** Proxy URL and Token use `ui.textInput`, so each is at most 128
   characters. Font steps through Scientifica, 8×12, Sans and Serif (Sans by
   default). Images switches between Links (the default) and Inline.
@@ -459,7 +469,8 @@ Files live in `/data/net.picodeck.picosurf/`.
 | Situation | Behaviour |
 |---|---|
 | WiFi not connected | "Connecting to WiFi..." screen; Esc goes Home (saved feeds, bookmarks and history still usable) |
-| Clock not set (the TLS error starts with `clock not set`) | "Waiting for time sync...", retries every 3 s |
+| Clock not set (the TLS error starts with `clock not set`) | "Waiting for time sync...", retries every 3 s; proxy requests only (Gemini does not check certificate dates) |
+| Gemini or Gopher failures | small web design 11 |
 | Proxy error status | error screen with status and reason; a 401 shows `Proxy rejected the token - check Settings` |
 | No response in 20 s | error screen `Proxy did not respond` |
 | Out of memory while parsing or laying out (`pcall`) | clear the cached page bodies, `collectgarbage()`, retry once, then show `Page too large for memory` |
@@ -545,19 +556,11 @@ This default list can be swapped for the author's own reading:
 
 ## 9. Later phases
 
-1. **Native Gemini.**
-   - Add a `gemini.lua` transport on `picocalc.tcp` (port 1965).
-   - Firmware: add `tcp:peerFingerprint()`, the SHA-256 of the peer
-     certificate after the handshake on insecure TLS sockets, for TOFU.
-     `MBEDTLS_SSL_KEEP_PEER_CERTIFICATE` is already enabled in
-     `src/mbedtls_config.h`.
-   - Pinned fingerprints go in `/data/<id>/known_hosts.json`.
-   - Known gaps: the firmware has TLS 1.2 only, and mbedTLS cannot do
-     Ed25519. Before committing, measure handshake success against a sample
-     of real Gemini servers.
-   - Device-side ASCII folding for content that doesn't come through the proxy.
-2. **Gopher, Spartan, Nex, Finger:** more transports that convert to the
-   typed-line model.
+1. **Native Gemini:** done, `2026-10-17-picosurf-small-web-design.md`. The
+   handshake survey is `docs/research/2026-10-16-gemini-tls-survey.md`; TLS
+   1.3 in the firmware would add 1.5 points of reach.
+2. **Gopher:** done, the same design. **Spartan, Nex, Finger:** more
+   transports on the same `tcpfetch` layer.
 3. **Public instance:** per-device tokens, rate limits, abuse handling; the
    app's default proxy URL changes.
 4. **Web search** through a configurable backend.
````

- [ ] **Step 2: Check nothing else changed**

Run: `make test`
Expected: `328 passed, 0 failed` under both.

- [ ] **Step 3: Commit**

```bash
git add README.md docs/superpowers/specs/2026-10-15-picosurf-design.md docs/hardware-pass.md
git commit -m "docs: Gemini and Gopher in the README, main spec and hardware pass"
```

---

## After the final review

Merge per superpowers:finishing-a-development-branch, at the user's choice. Pushing the app to the device (with `known_hosts.json` starting empty) and running hardware-pass item 24 wait for the user's go-ahead; pinning on the device also needs the firmware plan flashed.
