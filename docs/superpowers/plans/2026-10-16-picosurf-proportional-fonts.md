# PicoSurf Proportional Reading Fonts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** add Sans and Serif proportional reading fonts to PicoSurf's Font setting, with Sans as the default. Sans is X11 Adobe Helvetica 12 with its bold, on 14 px rows; Serif is Utopia 10 with its bold, on 13 px rows. Text wraps by measured width. Scientifica and 8×12 keep exactly today's layout.

**Architecture:**
- **Font files:** four 1-bit `.pfn` fonts, built reproducibly from the X.Org tarballs by `tools/build-fonts.py`, ship in a new `fonts/` folder.
- **Loading:** `src/fonts.lua` loads the chosen font and measures every character's advance once.
- **Wrapping:** `src/wrap.lua` wraps by pixel width with those advances. `src/layout.lua` takes a metrics table (width, advances, indent, code-block columns, a box-rows function) instead of a column count.
- **Picture boxes:** inline picture boxes store picture heights in px, so a change of row height recomputes them.

**Tech Stack:**
- App: Lua 5.4 (host tests under stock Lua and `lua32`).
- Font build: Python 3 standard library, plus PicoDeck's `tools/mkfont.py`.
- Simulator e2e: pytest.

**Spec:**
- `docs/superpowers/specs/2026-10-16-picosurf-proportional-fonts-design.md` (the authority).
- It amends `docs/superpowers/specs/2026-10-15-picosurf-design.md` and `docs/superpowers/specs/2026-10-16-picosurf-inline-images-design.md`.

## Global Constraints

- **Font choices** (`config.json` key `font`): `"scientifica"`, `"8x12"`, `"sans"`, `"serif"`.
  - Missing or unknown means `"sans"`.
  - Settings labels: `Font: Scientifica`, `Font: 8x12 (large)`, `Font: Sans`, `Font: Serif`. Enter steps through them in that order, wrapping round.
- **Row heights:** Sans 14 px; Serif, Scientifica and 8×12 13 px.
- **Indents:** list and quote indent is 12 px; 16 px for 8×12.
- **Code blocks:** Scientifica under Sans, Serif and Scientifica; 8×12 under 8×12. They are cut at `(312 // cell width) - 1` columns, plus the `\` mark.
- **Font files:** `fonts/sans.pfn`, `fonts/sans-bold.pfn`, `fonts/serif.pfn`, `fonts/serif-bold.pfn`, plus `fonts/LICENSE`. They load from `APP_DIR .. "/fonts/<name>.pfn"`.
- **Fallback:** when a font file can't load, the app uses Scientifica.
  - The toast reads exactly `Font unavailable - using Scientifica`.
  - The setting keeps its value.
- **Log line:** `picosurf: font <name>` whenever the reading font is (re)loaded, where `<name>` is the spec actually in use.
- **No layout changes for today's fonts:** Scientifica and 8×12 lay out exactly as before (same rows, same columns).
- **Inline pictures:** they still ask for `fit=312x126`. A box is `ceil((h + 4) / rowH)` rows.
- **Sources:**
  - `font-adobe-75dpi-1.0.4.tar.xz`, SHA-256 `1281a62dbeded169e495cae1a5b487e1f336f2b4d971d92911c59c103999b911`.
  - `font-adobe-utopia-75dpi-1.0.5.tar.xz`, SHA-256 `a726245932d0724fa0c538c992811d63d597e5f53928f4048e9caf5623797760`.
  - Both are already downloaded under `/home/keith/.claude/jobs/2a7b49a4/tmp/fonts/src/xadobe75/` and `.../src/xutopia75/`. They are untrusted data: read them only through `tarfile`, and never run anything from them.
- **Licences:** `fonts/LICENSE` holds both archives' `COPYING` texts verbatim. The README gets a Credits section with the Adobe copyright lines and the Utopia trademark line.
- **Packaging:** the store ZIP and the simulator staging include `fonts`.
- **Tests:**
  - `make test` (stock Lua and `lua32`).
  - `make e2e`.
  - `cd proxy && npm test` must stay green (the proxy is untouched).
- **Dependencies:** no new runtime dependencies.
- **Commits:** the repo's style (`feat:`, `fix:`, `test:`, `docs:`, `chore:`), with no attribution lines.
- **Deploying:** don't push to the device inside this plan.

## Review Focus

1. **A word wider than a row in a proportional font** (a long URL in a paragraph) is split by width, and no drawn row overflows the page. Test: Task 3, `wrap_by_width_breaks_at_spaces_by_measured_width`; Task 5, `proportional_pages_indent_and_keep_code_monospace` (within-page check).
2. **A byte outside 0x20-0x7E** in page text is measured as the widest advance, so it never overflows. Test: Task 3, `wrap_counts_unknown_bytes_as_the_widest`.
3. **A font change with pictures loaded:** boxes take the new row count, and the same line stays at the top. Test: Task 6, `a_font_change_resizes_picture_boxes_and_keeps_the_line`.
4. **A missing or rejected font file:** Scientifica, the toast, the setting kept, and nothing left loaded. Test: Task 2, `a_missing_file_falls_back_to_scientifica`; Task 6, `a_missing_font_file_falls_back_to_scientifica`.
5. **Back to a page saved under another font** lands on the same line. Test: Task 6, `back_across_a_font_change_lands_on_the_same_line`.

---

### Task 1: The font files, their build script and licences

**Files:**
- Create:
  - `tools/build-fonts.py`
  - `fonts/sans.pfn`, `fonts/sans-bold.pfn`, `fonts/serif.pfn`, `fonts/serif-bold.pfn` (generated)
  - `fonts/LICENSE` (generated)
  - `tests/test_font_files.lua`
- Modify: `.github/workflows/release.yml`, `tests/e2e/conftest.py`, `README.md`

**Interfaces:**
- Produces: the four `.pfn` files and `fonts/LICENSE`, committed. The app loads them in Task 2 onward.

- [ ] **Step 1: Write the failing test**

Create `tests/test_font_files.lua`:

```lua
local T = require("tests.t")

-- The committed reading fonts (proportional fonts spec 2): each .pfn must be
-- one the firmware accepts (font_from_blob in PicoDeck's src/fonts/font.c)
-- and cover ASCII 0x20-0x7E within its font's row.
local ROW = { sans = 14, ["sans-bold"] = 14, serif = 13, ["serif-bold"] = 13 }

local function read(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("a")
    f:close()
    return data
end

return {
    committed_fonts_are_valid_and_cover_ascii = function()
        for name, rowH in pairs(ROW) do
            local label = name .. ".pfn"
            local data = read("fonts/" .. label)
            local magic, ver, flags, first, last, height, maxw, stride = string.unpack("<c4BBBBBBB", data)
            T.eq(magic, "PFNT", label); T.eq(ver, 1, label)
            T.ok(flags & 1 == 1, label .. ": proportional")
            T.eq(first, 0x20, label); T.eq(last, 0x7E, label)
            T.ok(height >= 1 and height <= rowH, label .. ": height " .. height .. " fits a " .. rowH .. " px row")
            T.eq(stride, (maxw + 7) // 8, label .. ": stride")
            local count = last - first + 1
            T.eq(#data, 12 + count + count * height * stride, label .. ": size")
            for i = 1, count do
                local w = data:byte(12 + i)
                T.ok(w >= 1 and w <= maxw, label .. ": width of glyph " .. (first + i - 1))
            end
        end
    end,
    the_font_licences_ship_with_them = function()
        local text = read("fonts/LICENSE")
        T.ok(text:find("Copyright 1984-1989, 1994 Adobe Systems Incorporated.", 1, true))
        T.ok(text:find("Digital Equipment Corporation", 1, true))
        T.ok(text:find("Utopia is a registered trademark of Adobe Systems Incorporated", 1, true))
    end,
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `lua tests/run.lua tests/test_font_files.lua`
Expected: FAIL, because `fonts/sans.pfn` and `fonts/LICENSE` don't exist (`assert` from `io.open`).

- [ ] **Step 3: Write the build script**

Create `tools/build-fonts.py` and make it executable (`chmod +x tools/build-fonts.py`):

```python
#!/usr/bin/env python3
"""Rebuild PicoSurf's reading fonts, fonts/*.pfn and fonts/LICENSE, from the
X.Org bitmap font releases (proportional fonts spec, section 2).

usage: tools/build-fonts.py ADOBE_75DPI UTOPIA_75DPI

  ADOBE_75DPI   font-adobe-75dpi-1.0.4.tar.xz
  UTOPIA_75DPI  font-adobe-utopia-75dpi-1.0.5.tar.xz
                (both from https://www.x.org/releases/individual/font/)

PicoDeck's tools/mkfont.py does the conversion (PICODECK_ROOT, default
~/Projects/PicoDeck/picodeck). The archives are only read: their BDFs are
parsed as text, and nothing in them is run. Before mkfont.py, each BDF is
cut to ASCII with a tight bounding box, glyphs whose ink overhangs their
advance get a wider advance, and over-padded bitmap rows are trimmed;
mkfont.py gets all three wrong (PicoDeck issue #74).
"""
import hashlib
import os
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "fonts"
FIRST, LAST = 0x20, 0x7E

# Archive: (top-level directory, SHA-256).
ARCHIVES = {
    "adobe": ("font-adobe-75dpi-1.0.4", "1281a62dbeded169e495cae1a5b487e1f336f2b4d971d92911c59c103999b911"),
    "utopia": ("font-adobe-utopia-75dpi-1.0.5", "a726245932d0724fa0c538c992811d63d597e5f53928f4048e9caf5623797760"),
}
# Output font: (archive, BDF file in it).
FONTS = {
    "sans": ("adobe", "helvR12.bdf"),
    "sans-bold": ("adobe", "helvB12.bdf"),
    "serif": ("utopia", "UTRG__10.bdf"),
    "serif-bold": ("utopia", "UTB___10.bdf"),
}
LICENSE_PARTS = [
    ("adobe", "sans.pfn and sans-bold.pfn: Helvetica 12 and Helvetica Bold 12\n"
              "(helvR12, helvB12) from X.Org font-adobe-75dpi 1.0.4."),
    ("utopia", "serif.pfn and serif-bold.pfn: Utopia Regular 10 and Utopia Bold 10\n"
               "(UTRG__10, UTB___10) from X.Org font-adobe-utopia-75dpi 1.0.5."),
]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def member_text(tar, top, name):
    f = tar.extractfile(f"{top}/{name}")
    if f is None:
        raise SystemExit(f"{top}/{name}: not a file in the archive")
    return f.read().decode("latin-1")


def fix_glyph(block, adjusted):
    """Move a negative left bearing to 0 and widen DWIDTH so all ink lies in
    [0, advance): the firmware draws only `advance` columns of a glyph. Trim
    bitmap rows to ceil(width / 8) bytes; the trimmed padding must be zero."""
    block = list(block)
    ib = next(i for i, l in enumerate(block) if l.startswith("BBX"))
    idw = next(i for i, l in enumerate(block) if l.startswith("DWIDTH"))
    w, h, xo, yo = map(int, block[ib].split()[1:5])
    dw = int(block[idw].split()[1])
    if xo < 0 or xo + w > dw:
        new_xo = max(xo, 0)
        block[ib] = f"BBX {w} {h} {new_xo} {yo}"
        block[idw] = f"DWIDTH {max(dw + (new_xo - xo), new_xo + w)} 0"
        adjusted.append(block[0].split()[1])
    digits = (w + 7) // 8 * 2
    start = block.index("BITMAP")
    for i in range(start + 1, len(block) - 1):
        row = block[i].strip()
        if len(row) > digits:
            if int(row[digits:], 16) != 0:
                raise SystemExit(f"{block[0]}: bitmap padding is not zero")
            row = row[:digits]
        block[i] = row.ljust(digits, "0")
    return block


def ascii_bdf(text):
    """The ASCII glyphs only, fixed as above, under a FONTBOUNDINGBOX tight
    around their ink, so mkfont.py takes the text's real height."""
    lines = [l.rstrip() for l in text.splitlines()]
    glyphs, adjusted = {}, []
    i = 0
    while i < len(lines):
        if lines[i].startswith("STARTCHAR"):
            j = i
            while not lines[j].startswith("ENDCHAR"):
                j += 1
            block = lines[i:j + 1]
            enc = next(int(l.split()[1]) for l in block if l.startswith("ENCODING"))
            if FIRST <= enc <= LAST:
                glyphs[enc] = fix_glyph(block, adjusted)
            i = j
        i += 1
    missing = "".join(chr(c) for c in range(FIRST, LAST + 1) if c not in glyphs)
    if missing:
        raise SystemExit(f"missing glyphs: {missing}")
    top = bottom = right = None
    for block in glyphs.values():
        w, h, xo, yo = map(int, next(l for l in block if l.startswith("BBX")).split()[1:5])
        start = block.index("BITMAP")
        if not any(int(r, 16) for r in block[start + 1:-1] if r):
            continue  # no ink (the space)
        dw = int(next(l for l in block if l.startswith("DWIDTH")).split()[1])
        top = yo + h if top is None else max(top, yo + h)
        bottom = yo if bottom is None else min(bottom, yo)
        right = max(xo + w, dw) if right is None else max(right, xo + w, dw)
    out = ["STARTFONT 2.1", "FONT picosurf-ascii", "SIZE 1 75 75",
           f"FONTBOUNDINGBOX {right} {top - bottom} 0 {bottom}", f"CHARS {len(glyphs)}"]
    for enc in sorted(glyphs):
        out += glyphs[enc]
    out.append("ENDFONT")
    return "\n".join(out) + "\n", adjusted


def main(argv):
    if len(argv) != 3:
        raise SystemExit(__doc__)
    paths = {"adobe": Path(argv[1]), "utopia": Path(argv[2])}
    for key, (top, digest) in ARCHIVES.items():
        if sha256(paths[key]) != digest:
            raise SystemExit(f"{paths[key]}: SHA-256 does not match {top}")
    root = Path(os.environ.get("PICODECK_ROOT", Path.home() / "Projects/PicoDeck/picodeck"))
    mkfont = root / "tools" / "mkfont.py"
    if not mkfont.is_file():
        raise SystemExit(f"{mkfont}: not found (set PICODECK_ROOT)")
    OUT.mkdir(exist_ok=True)
    licences = {}
    with tempfile.TemporaryDirectory() as tmp:
        for key, path in paths.items():
            top = ARCHIVES[key][0]
            with tarfile.open(path, "r:xz") as tar:
                licences[key] = member_text(tar, top, "COPYING")
                for name, (archive, bdf) in FONTS.items():
                    if archive != key:
                        continue
                    text, adjusted = ascii_bdf(member_text(tar, top, bdf))
                    src = Path(tmp) / f"{name}.bdf"
                    src.write_text(text)
                    out = OUT / f"{name}.pfn"
                    subprocess.run([sys.executable, "-I", str(mkfont), str(src), str(out),
                                    "--range", "0x20-0x7E"], check=True)
                    print(f"{out.relative_to(REPO)}: from {bdf}; advance widened for: "
                          f"{' '.join(adjusted) or 'none'}")
    parts = ["PicoSurf's Sans and Serif reading fonts are converted from X.Org's bitmap\n"
             "font releases (tools/build-fonts.py). Their licences follow, unchanged.\n"]
    for key, intro in LICENSE_PARTS:
        parts.append("=" * 72 + "\n" + intro + "\n\n" + licences[key].rstrip() + "\n")
    (OUT / "LICENSE").write_text("\n".join(parts))
    print("fonts/LICENSE written")


if __name__ == "__main__":
    main(sys.argv)
```

- [ ] **Step 4: Build the fonts**

Run (from the repo root):

```bash
python3 -I tools/build-fonts.py /home/keith/.claude/jobs/2a7b49a4/tmp/fonts/src/xadobe75/font-adobe-75dpi-1.0.4.tar.xz /home/keith/.claude/jobs/2a7b49a4/tmp/fonts/src/xutopia75/font-adobe-utopia-75dpi-1.0.5.tar.xz
```

Expected:
- mkfont's summary line for each font.
- `advance widened for:` lines:
  - `f` (sans);
  - `j` (sans-bold);
  - nine glyphs in serif (`numbersign J V W Y b j p t`, by glyph name);
  - three in serif-bold (`five Y f`).
- `fonts/LICENSE written`.

Cross-check that the output matches the research conversion byte for byte:

```bash
cmp fonts/sans.pfn /home/keith/.claude/jobs/2a7b49a4/tmp/fonts/pfn/helv12.pfn && cmp fonts/sans-bold.pfn /home/keith/.claude/jobs/2a7b49a4/tmp/fonts/pfn/helv12-bold.pfn && cmp fonts/serif.pfn /home/keith/.claude/jobs/2a7b49a4/tmp/fonts/pfn/utopia10.pfn && cmp fonts/serif-bold.pfn /home/keith/.claude/jobs/2a7b49a4/tmp/fonts/pfn/utopia10-bold.pfn && echo identical
```

Expected: `identical`. If one differs, compare the two pipelines before going on: the research scripts are `bdf_ascii.py` and `build_pfn.py` in the same `tmp/fonts/scripts/` folder. Report the difference rather than accepting either side blindly.

- [ ] **Step 5: Package and credit the fonts**

- `.github/workflows/release.yml`: change the zip line to `run: zip -9 -r "picosurf-${GITHUB_REF_NAME#v}.zip" app.json main.lua src fonts`
- `tests/e2e/conftest.py`: `APP_FILES = ("app.json", "main.lua", "src", "fonts")`
- `README.md`: add before `## Development`:

```markdown
## Credits
The Sans and Serif reading fonts are converted from X.Org's Adobe bitmap fonts by `tools/build-fonts.py`; [fonts/LICENSE](fonts/LICENSE) has their licences.
- Sans: Helvetica 12. Copyright 1984-1989, 1994 Adobe Systems Incorporated. Copyright 1988, 1994 Digital Equipment Corporation.
- Serif: Utopia 10. Copyright (c) 1989 Adobe Systems Incorporated. Utopia (R) is a registered trademark of Adobe Systems Incorporated.
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `lua tests/run.lua tests/test_font_files.lua && make test`
Expected: all pass under both Luas.

- [ ] **Step 7: Commit**

```bash
git add tools/build-fonts.py fonts tests/test_font_files.lua .github/workflows/release.yml tests/e2e/conftest.py README.md
git commit -m "feat: Sans and Serif reading fonts (X11 Adobe Helvetica 12, Utopia 10) with their build script and licences"
```

---

### Task 2: Loading and measuring fonts (`src/fonts.lua`)

**Files:**
- Create: `src/fonts.lua`, `tests/test_fonts.lua`
- Modify: `tests/fakepc.lua`

**Interfaces:**
- Produces:
  - **Data:** `fonts.CHOICES = {"scientifica", "8x12", "sans", "serif"}`, `fonts.DEFAULT = "sans"`, and `fonts.LABELS[name]`.
  - **Choice helpers:** `fonts.normalize(name) -> name` (unknown or nil means `"sans"`) and `fonts.nextChoice(name) -> name`.
  - **Loading:** `fonts.load(disp, appDir, name) -> spec, err`, which never raises. `fonts.unload(disp, spec)`.
  - **`spec` fields:**
    - `name`, `font`, `bold`, `rowH`, `indent`, `loaded` (ids);
    - `pre = {font, cw}`;
    - `adv` and `boldAdv`: tables from byte (0x20-0x7E) to px, plus `adv.widest`, and `adv.uniform` (the common advance of a monospace font, else nil).
  - **fakepc additions:**
    - `display.textWidth`, `display.loadFont`, `display.unloadFont`;
    - `F.fontFiles` (loaded id → path), `F.missingFonts` (path → true makes `loadFont` fail), `F.textWidthIn(id, text)`.
    - Fake advances: built-in fonts are 6 px a byte (8×12 is 8). Loaded fonts are proportional: `i l . , : ; ' ! |` are 3 px, `m w M W` are 9, everything else is 6, and each is 1 px wider in a font whose path contains `-bold`.

- [ ] **Step 1: Extend the fake device**

In `tests/fakepc.lua`:
- Add `fontFiles = {}, missingFonts = {}, nextFontId = 4` to the initial `F` table.
- After the `display` table is defined (after `display.rgb`), add:

```lua
    -- Fake advances: built-in fonts are fixed-width (6 px, 8 for 8x12); a
    -- loaded font is proportional: narrow characters 3 px, wide ones 9, the
    -- rest 6, and one wider each in a font whose file name has "-bold".
    local NARROW, WIDE = "il.,:;'!|", "mwMW"
    local function advance(id, c)
        if id == display.FONT_8X12 then return 8 end
        if id < 4 then return 6 end
        local a = NARROW:find(c, 1, true) and 3 or (WIDE:find(c, 1, true) and 9 or 6)
        if F.fontFiles[id]:find("-bold", 1, true) then a = a + 1 end
        return a
    end
    function F.textWidthIn(id, t)
        local w = 0
        for c in t:gmatch(".") do w = w + advance(id, c) end
        return w
    end
    function display.textWidth(t) return F.textWidthIn(F.font, t) end
    function display.loadFont(path)
        if F.missingFonts[path] then return nil, "cannot read file" end
        local id = F.nextFontId
        F.nextFontId = id + 1
        F.fontFiles[id] = path
        return id
    end
    function display.unloadFont(id)
        if F.font == id then F.font = display.FONT_6X8 end
        F.fontFiles[id] = nil
    end
```

- Change `display.drawText` to return the measured width: `function display.drawText(_, _, t) record(t); return display.textWidth(t) end`. It is defined before `advance`, but it only calls `display.textWidth` when it runs, so the order is fine.

- [ ] **Step 2: Write the failing tests**

Create `tests/test_fonts.lua`:

```lua
local T = require("tests.t")
local fakepc = require("tests.fakepc")
local fonts = require("src.fonts")

local DIR = "/apps/picosurf"
local function b(c) return c:byte() end

return {
    builtin_fonts_measure_fixed_widths = function()
        local F = fakepc.new()
        local d = F.pc.display
        local s, err = fonts.load(d, DIR, "scientifica")
        T.eq(err, nil)
        T.eq(s.name, "scientifica"); T.eq(s.font, d.FONT_SCIENTIFICA); T.eq(s.bold, d.FONT_SCIENTIFICA_BOLD)
        T.eq(s.rowH, 13); T.eq(s.indent, 12); T.eq(s.pre.font, d.FONT_SCIENTIFICA); T.eq(s.pre.cw, 6)
        T.eq(s.adv[b("A")], 6); T.eq(s.adv.uniform, 6); T.eq(s.adv.widest, 6); T.eq(#s.loaded, 0)
        local l = fonts.load(d, DIR, "8x12")
        T.eq(l.name, "8x12"); T.eq(l.font, d.FONT_8X12); T.eq(l.bold, d.FONT_8X12)
        T.eq(l.indent, 16); T.eq(l.pre.font, d.FONT_8X12); T.eq(l.pre.cw, 8); T.eq(l.adv.uniform, 8)
    end,
    sans_and_serif_load_their_files_and_measure_them = function()
        local F = fakepc.new()
        local d = F.pc.display
        local s, err = fonts.load(d, DIR, "sans")
        T.eq(err, nil); T.eq(s.name, "sans"); T.eq(s.rowH, 14); T.eq(s.indent, 12)
        T.eq(F.fontFiles[s.font], DIR .. "/fonts/sans.pfn")
        T.eq(F.fontFiles[s.bold], DIR .. "/fonts/sans-bold.pfn")
        T.eq(s.pre.font, d.FONT_SCIENTIFICA); T.eq(s.pre.cw, 6)
        T.eq(s.adv[b("i")], 3); T.eq(s.adv[b("m")], 9); T.eq(s.adv[b("a")], 6)
        T.eq(s.boldAdv[b("a")], 7); T.eq(s.adv.widest, 9); T.eq(s.boldAdv.widest, 10)
        T.eq(s.adv.uniform, nil); T.eq(#s.loaded, 2)
        local r = fonts.load(d, DIR, "serif")
        T.eq(r.name, "serif"); T.eq(r.rowH, 13)
        T.eq(F.fontFiles[r.font], DIR .. "/fonts/serif.pfn")
        T.eq(F.fontFiles[r.bold], DIR .. "/fonts/serif-bold.pfn")
    end,
    measuring_leaves_the_current_font = function()
        local F = fakepc.new()
        local d = F.pc.display
        d.setFont(d.FONT_6X8)
        fonts.load(d, DIR, "sans")
        T.eq(F.font, d.FONT_6X8)
    end,
    a_missing_file_falls_back_to_scientifica = function() -- Review Focus 4
        local F = fakepc.new()
        local d = F.pc.display
        F.missingFonts[DIR .. "/fonts/sans-bold.pfn"] = true
        local s, err = fonts.load(d, DIR, "sans")
        T.eq(s.name, "scientifica"); T.eq(s.font, d.FONT_SCIENTIFICA); T.eq(s.adv.uniform, 6)
        T.ok(err and err:find(DIR .. "/fonts/sans-bold.pfn", 1, true), "the error names the file: " .. tostring(err))
        T.eq(next(F.fontFiles), nil, "the regular font it did load is unloaded")
    end,
    unload_frees_loaded_fonts = function()
        local F = fakepc.new()
        local d = F.pc.display
        local s = fonts.load(d, DIR, "serif")
        fonts.unload(d, s)
        T.eq(next(F.fontFiles), nil); T.eq(#s.loaded, 0)
    end,
    choices_cycle_and_unknown_names_mean_sans = function()
        T.eq(fonts.normalize(nil), "sans"); T.eq(fonts.normalize("comic"), "sans"); T.eq(fonts.normalize("8x12"), "8x12")
        T.eq(fonts.nextChoice("scientifica"), "8x12"); T.eq(fonts.nextChoice("8x12"), "sans")
        T.eq(fonts.nextChoice("sans"), "serif"); T.eq(fonts.nextChoice("serif"), "scientifica")
        T.eq(fonts.LABELS.scientifica, "Scientifica"); T.eq(fonts.LABELS["8x12"], "8x12 (large)")
        T.eq(fonts.LABELS.sans, "Sans"); T.eq(fonts.LABELS.serif, "Serif")
    end,
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `lua tests/run.lua tests/test_fonts.lua`
Expected: FAIL with `module 'src.fonts' not found`.

- [ ] **Step 4: Implement**

Create `src/fonts.lua`:

```lua
-- The reading fonts (proportional fonts spec 3): a Font choice's display
-- fonts, row height and indent, and every character's advance, measured once
-- so layout can wrap by width.
local M = {}

M.CHOICES = { "scientifica", "8x12", "sans", "serif" }
M.DEFAULT = "sans"
M.LABELS = { scientifica = "Scientifica", ["8x12"] = "8x12 (large)", sans = "Sans", serif = "Serif" }

-- The proportional fonts: their files in the app's fonts/ folder, and row height.
local FILES = {
    sans = { regular = "sans", bold = "sans-bold", rowH = 14 },
    serif = { regular = "serif", bold = "serif-bold", rowH = 13 },
}
local FIRST, LAST = 0x20, 0x7E

-- A choice by name; anything else, nil included, is the default.
function M.normalize(name)
    for _, c in ipairs(M.CHOICES) do
        if c == name then return name end
    end
    return M.DEFAULT
end

-- The choice after `name`, wrapping round.
function M.nextChoice(name)
    for i, c in ipairs(M.CHOICES) do
        if c == name then return M.CHOICES[i % #M.CHOICES + 1] end
    end
    return M.DEFAULT
end

-- Each character's advance in font `id`. widest: the largest; uniform: the
-- advance when they are all equal (a monospace font), else nil.
local function measure(disp, id)
    disp.setFont(id)
    local adv, widest, uniform = {}, 0, nil
    for c = FIRST, LAST do
        local w = disp.textWidth(string.char(c))
        adv[c] = w
        if w > widest then widest = w end
        if c == FIRST then uniform = w elseif uniform ~= w then uniform = false end
    end
    adv.widest, adv.uniform = widest, uniform or nil
    return adv
end

-- Scientifica or 8x12: built into the firmware, and their own code-block font.
local function builtin(disp, name)
    local large = name == "8x12"
    local font = large and disp.FONT_8X12 or disp.FONT_SCIENTIFICA
    local cw = large and 8 or 6
    return {
        name = large and "8x12" or "scientifica", font = font,
        bold = large and disp.FONT_8X12 or disp.FONT_SCIENTIFICA_BOLD,
        rowH = 13, indent = 2 * cw, pre = { font = font, cw = cw }, loaded = {},
    }
end

-- Loads choice `name` (one of CHOICES). Never raises: when a font file can't
-- be loaded, unloads what it did load and returns the Scientifica spec and
-- an error naming the file. The current font is left as it was.
function M.load(disp, appDir, name)
    local spec, err
    local f = FILES[name]
    if f then
        local ids = {}
        for _, file in ipairs({ f.regular, f.bold }) do
            local path = appDir .. "/fonts/" .. file .. ".pfn"
            local id, why = disp.loadFont(path)
            if not id then
                err = path .. ": " .. (why or "cannot load")
                break
            end
            ids[#ids + 1] = id
        end
        if err then
            for _, id in ipairs(ids) do disp.unloadFont(id) end
        else
            spec = {
                name = name, font = ids[1], bold = ids[2], rowH = f.rowH, indent = 12,
                pre = { font = disp.FONT_SCIENTIFICA, cw = 6 }, loaded = ids,
            }
        end
    end
    spec = spec or builtin(disp, err and "scientifica" or name)
    local current = disp.getFont()
    spec.adv, spec.boldAdv = measure(disp, spec.font), measure(disp, spec.bold)
    disp.setFont(current)
    return spec, err
end

function M.unload(disp, spec)
    for _, id in ipairs(spec.loaded) do disp.unloadFont(id) end
    spec.loaded = {}
end

return M
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `lua tests/run.lua tests/test_fonts.lua && make test`
Expected: all pass under both Luas. Every existing test must still pass with the fake's new `drawText` return value.

- [ ] **Step 6: Commit**

```bash
git add src/fonts.lua tests/test_fonts.lua tests/fakepc.lua
git commit -m "feat: load the reading fonts and measure their advances"
```

---

### Task 3: Wrapping by measured width (`src/wrap.lua`)

**Files:**
- Modify: `src/wrap.lua`
- Test: `tests/test_layout.lua` (where the wrap tests live)

**Interfaces:**
- Consumes: the advance tables from Task 2 (`adv[byte]`, `adv.widest`, `adv.uniform`).
- Produces:
  - `wrap.wrap(text, width, adv)`. Without `adv` it behaves exactly as today, counting columns. With `adv`, `width` is in px; a `uniform` table wraps by columns of `width // uniform`.
  - `wrap.fit(text, px, adv) -> prefix`: the longest prefix no wider than `px`.

- [ ] **Step 1: Write the failing tests**

In `tests/test_layout.lua`, add above `return {`:

```lua
-- Advances for width tests: 'i' 3 px, 'm' 9, everything else 6.
local function propAdv()
    local adv = { widest = 9 }
    for c = 32, 126 do adv[c] = 6 end
    adv[("i"):byte()], adv[("m"):byte()] = 3, 9
    return adv
end

local function prows(text, width, adv)
    local s, e = wrap.wrap(text, width, adv)
    local out = {}
    for i = 1, #s do out[i] = text:sub(s[i], e[i]) end
    return table.concat(out, "|")
end
```

and these entries to the returned table:

```lua
    wrap_by_width_breaks_at_spaces_by_measured_width = function() -- Review Focus 1
        local adv = propAdv()
        T.eq(prows("iiii iiii", 30, adv), "iiii iiii", "30 px exactly")
        T.eq(prows("iiii iiii", 29, adv), "iiii|iiii")
        T.eq(prows("mm mm", 24, adv), "mm|mm")
        T.eq(prows("mmmm", 20, adv), "mm|mm", "a word wider than the row is split by width")
        T.eq(prows("ab", 2, adv), "a|b", "narrower than any glyph: one byte a row")
        T.eq(prows("ab   cd", 18, adv), "ab|cd", "spaces at a break are dropped")
        T.eq(prows("", 18, adv), "")
    end,
    wrap_counts_unknown_bytes_as_the_widest = function() -- Review Focus 2
        local adv = propAdv()
        local text = "a" .. string.char(200) .. "b" -- 6 + 9 + 6 = 21 px
        T.eq(#wrap.wrap(text, 21, adv), 1)
        T.eq(prows(text, 20, adv), "a" .. string.char(200) .. "|b")
    end,
    wrap_of_a_monospace_font_counts_columns = function()
        local uni = { uniform = 6, widest = 6 }
        for c = 32, 126 do uni[c] = 6 end
        T.eq(prows("hello world", 30, uni), rows("hello world", 5))
        T.eq(prows("hello world", 66, uni), rows("hello world", 11))
        T.eq(prows("ab", 4, uni), "a|b", "narrower than a cell: one column")
    end,
    fit_keeps_the_longest_prefix_that_fits = function()
        local adv = propAdv()
        T.eq(wrap.fit("aamm", 21, adv), "aam")
        T.eq(wrap.fit("aamm", 20, adv), "aa")
        T.eq(wrap.fit("ab", 100, adv), "ab")
        T.eq(wrap.fit("m", 5, adv), "")
    end,
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `lua tests/run.lua tests/test_layout.lua`
Expected: FAIL. `wrap` ignores `adv` (`"iiii iiii"` at 29 comes back as one row, or the rows are wrong), and `wrap.fit` is nil.

- [ ] **Step 3: Implement**

Replace `src/wrap.lua` with:

```lua
-- Word wrap (spec 6.3, proportional fonts spec 5.1). Pure. Rows are 1-based
-- inclusive byte ranges; text has no newlines (one gemtext line at a time).
local M = {}

-- Rows of at most `width` bytes.
local function columns(text, width)
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

-- Rows of at most `width` px, each byte measured by adv (bytes it lacks as
-- adv.widest), so nothing can overflow a row.
local function proportional(text, width, adv)
    local s, e = {}, {}
    local n, i = #text, 1
    if n == 0 then return { 1 }, { 0 } end
    local byte, wide = string.byte, adv.widest or 1
    while i <= n do
        local w, j = 0, i
        while j <= n do
            local a = adv[byte(text, j)] or wide
            if w + a > width then break end
            w, j = w + a, j + 1
        end
        if j > n then
            s[#s + 1], e[#e + 1] = i, n
            break
        end
        -- text[i..j-1] fits and text[j] doesn't: break at the last space.
        local cut
        for k = j, i + 1, -1 do
            if byte(text, k) == 32 then cut = k; break end
        end
        if cut then
            local k = cut - 1
            while k > i and byte(text, k) == 32 do k = k - 1 end
            s[#s + 1], e[#e + 1] = i, k
            i = cut + 1
            while i <= n and byte(text, i) == 32 do i = i + 1 end
        else
            local last = math.max(j - 1, i) -- at least one byte a row, however narrow
            s[#s + 1], e[#e + 1] = i, last
            i = last + 1
        end
    end
    return s, e
end

-- Returns starts, ends: row k is text:sub(starts[k], ends[k]). Breaks at the
-- last space that fits, splits words longer than a row, and drops the spaces
-- at a break. Empty text gives one empty row. adv: optional byte -> advance
-- table (fonts.lua), and width is then in px; without it every byte is one
-- column. A monospace font (adv.uniform) wraps by columns of that width.
function M.wrap(text, width, adv)
    if not adv then return columns(text, width) end
    if adv.uniform then return columns(text, math.max(1, width // adv.uniform)) end
    return proportional(text, width, adv)
end

-- The longest prefix of text no wider than px, cut anywhere (one-line labels).
function M.fit(text, px, adv)
    local w, wide = 0, adv.widest or 1
    for i = 1, #text do
        w = w + (adv[text:byte(i)] or wide)
        if w > px then return text:sub(1, i - 1) end
    end
    return text
end

return M
```

The `columns` body is the old `M.wrap` unchanged; only its name moved.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `lua tests/run.lua tests/test_layout.lua && make test`
Expected: all pass under both Luas.

- [ ] **Step 5: Commit**

```bash
git add src/wrap.lua tests/test_layout.lua
git commit -m "feat: wrap text by measured width, and fit one-line labels"
```

---

### Task 4: Layout by metrics, the theme from a font spec, and picture boxes in px

**Files:**
- Modify:
  - `src/layout.lua`, `src/theme.lua`, `src/inline.lua`, `src/app.lua`, `main.lua`
  - `tests/test_layout.lua`, `tests/test_pagestate.lua`, `tests/test_inline.lua`, `tests/test_fonts.lua`

**Interfaces:**
- Consumes:
  - `fonts.load`, `fonts.unload` and `fonts.normalize` (Task 2);
  - `wrap.wrap(text, width, adv)` (Task 3).
- Produces:
  - **`layout.build(lines, m, boxes)`.** The metrics `m` are:
    - `width`, `indent`, `preCols`;
    - `adv` and `boldAdv` (optional);
    - `boxRows(h)`.

    `boxes[k]` is a picture height. `layout.mono(cols)` gives today's column semantics, with `boxRows` passing values through as rows.
  - **Theme:**
    - `theme.new(disp, spec)` adds the fields `fontName`, `adv`, `boldAdv`, `indent` and `pre`. `cw` is the code-block cell width.
    - `theme.preCols(th)` and `theme.metrics(th)`.
  - **`inline.rows(h, rowH)`;** `inline.ROW_H` is gone. `st.boxes[k]` is the picture height in px.
  - **App:**
    - `App.new(pc, appId, appDir)`, where `appDir` defaults to `"/apps/picosurf"`;
    - `app.fontSpec`;
    - `App:loadFont()`;
    - the log line `picosurf: font <name>`.

    The default font is still Scientifica here; Task 6 changes it.

- [ ] **Step 1: Write the failing tests**

In `tests/test_layout.lua`:
- Add these requires at the top: `local fakepc = require("tests.fakepc")`, `local fonts = require("src.fonts")`, `local theme = require("src.theme")`.
- Change every `layout.build(<lines>, <number>[, <boxes>])` call so its second argument is `layout.mono(<number>)`, e.g. `layout.build(lines, 10)` → `layout.build(lines, layout.mono(10))`, `layout.build(lines, 10, { [1] = 4 })` → `layout.build(lines, layout.mono(10), { [1] = 4 })`. The calls are at the lines `grep -n "layout.build" tests/test_layout.lua` lists.
- Do the same in `tests/test_pagestate.lua` (every `layout.build(..., 40)` and the one `..., 52)`) and `tests/test_inline.lua` (`layout.build(..., 40)`).
- With `layout.mono`, box values are still rows, so the existing box tests keep their numbers.

Add above `return {` in `tests/test_layout.lua`:

```lua
-- Proportional metrics: 'i' 3 px, 'm' 9, bold one px wider, the rest 6;
-- 14 px rows for boxes.
local function propMetrics(width)
    local adv, bold = { widest = 9 }, { widest = 10 }
    for c = 32, 126 do adv[c], bold[c] = 6, 7 end
    adv[("i"):byte()], adv[("m"):byte()] = 3, 9
    bold[("i"):byte()], bold[("m"):byte()] = 4, 10
    return { width = width, adv = adv, boldAdv = bold, indent = 12, preCols = 5,
             boxRows = function(h) return (h + 4 + 13) // 14 end }
end

local SAMPLE = "# A heading that wraps on the narrow screen\nsome text that goes on long enough to wrap twice or more on screen\n"
    .. "* a list item long enough to wrap onto a second row\n> a quote long enough to wrap onto a second row\n"
    .. "```\n" .. string.rep("code ", 14) .. "\n```\n=> https://a.test/ [1] a link label that wraps on the screen\n"
```

and these entries to the returned table:

```lua
    lays_out_by_measured_width = function()
        local L = layout.build(g.parse("aaaa aaaa\n# aaaa aaaa\n* aaaa aaaa\n```\nabcdefgh\n```\n"), propMetrics(54))
        local got = {}
        for r = 1, L.count do got[r] = L.style[r] .. ":" .. layout.rowText(L, r) end
        T.eq(table.concat(got, "|"), table.concat({
            layout.TEXT .. ":aaaa aaaa", -- 54 px exactly
            layout.H1 .. ":aaaa", layout.H1 .. ":aaaa", -- 63 px in bold: too wide
            layout.ITEM .. ":aaaa", layout.ITEMC .. ":aaaa", -- 54 - 12 = 42 px for items
            layout.PRE .. ":abcde", layout.PRE .. ":fgh", -- cut at preCols, not by width
        }, "|"))
    end,
    boxes_are_picture_heights_turned_into_rows = function()
        local lines = g.parse(IMGPAGE)
        local L = layout.build(lines, propMetrics(60), { [1] = 120 })
        T.eq(L.links[1].last - L.links[1].first + 1, 9, "120 px on 14 px rows")
    end,
    scientifica_and_8x12_lay_out_as_columns_did = function()
        local F = fakepc.new()
        local d = F.pc.display
        local lines = g.parse(SAMPLE)
        local sci = theme.new(d, fonts.load(d, "/apps/picosurf", "scientifica"))
        T.eq(snapshot(layout.build(lines, theme.metrics(sci))), snapshot(layout.build(lines, layout.mono(52))))
        local big = theme.new(d, fonts.load(d, "/apps/picosurf", "8x12"))
        T.eq(snapshot(layout.build(lines, theme.metrics(big))), snapshot(layout.build(lines, layout.mono(39))))
    end,
```

`IMGPAGE` and `snapshot` already exist in `tests/test_layout.lua`.

In `tests/test_inline.lua`, replace the `a_box_fits_its_picture_and_its_padding` test body with:

```lua
        T.eq(inline.FIT, "312x126")
        T.eq(inline.rows(126, 13), 10); T.eq(inline.rows(100, 13), 8); T.eq(inline.rows(50, 13), 5)
        T.eq(inline.rows(9, 13), 1); T.eq(inline.rows(10, 13), 2); T.eq(inline.rows(1, 13), 1)
        T.eq(inline.rows(126, 14), 10); T.eq(inline.rows(120, 13), 10); T.eq(inline.rows(120, 14), 9)
        T.eq(inline.rows(100, 14), 8)
```

Add to `tests/test_fonts.lua`'s returned table (and `local theme = require("src.theme")` at the top):

```lua
    theme_metrics_come_from_the_font = function()
        local F = fakepc.new()
        local d = F.pc.display
        local sci = theme.metrics(theme.new(d, fonts.load(d, DIR, "scientifica")))
        T.eq(sci.width, 312); T.eq(sci.preCols, 51); T.eq(sci.indent, 12); T.eq(sci.boxRows(120), 10)
        local th = theme.new(d, fonts.load(d, DIR, "sans"))
        T.eq(th.fontName, "sans"); T.eq(th.rowH, 14); T.eq(th.cw, 6); T.eq(theme.rows(th), 20)
        local m = theme.metrics(th)
        T.eq(m.preCols, 51); T.eq(m.boxRows(120), 9); T.eq(m.adv, th.adv); T.eq(m.boldAdv, th.boldAdv)
    end,
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `lua tests/run.lua tests/test_layout.lua tests/test_inline.lua tests/test_fonts.lua`
Expected: FAIL with `attempt to call a nil value (field 'mono')`, `(field 'metrics')`, or wrong `inline.rows` results.

- [ ] **Step 3: Implement**

`src/layout.lua`:
- Delete `local INDENT = 2`.
- Replace the comment above `M.build` and `M.build` itself with:

```lua
-- m: layout metrics (proportional fonts spec 5.2): width, and adv and
-- boldAdv (byte -> advance, see fonts.lua; nil: every byte 1 wide), all in
-- the same units; indent (list items and quotes), preCols (columns of a
-- preformatted line) and boxRows(h) (the rows of an inline picture box h px
-- tall). boxes: optional {[k] = picture height}: image link k is laid out as
-- m.boxRows(boxes[k]) BOX rows (inline images spec 5.4) instead of its label.
function M.build(lines, m, boxes)
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
            local text, w = ln.text, m.preCols
            if #text == 0 then add(li, 1, 0, M.PRE, 0, false) end
            local i = 1
            while i <= #text do
                local j = math.min(i + w - 1, #text)
                add(li, i, j, M.PRE, 0, j < #text)
                i = j + 1
            end
        else
            local style, width, adv, link = HEADINGS[t] or M.TEXT, m.width, m.adv, 0
            if HEADINGS[t] then
                adv = m.boldAdv
            elseif t == "item" then
                style, width = M.ITEM, m.width - m.indent
            elseif t == "quote" then
                style, width = M.QUOTE, m.width - m.indent
            elseif t == "link" then
                style = ln.image and M.IMAGE or (ln.dim and M.READ or M.LINK)
                L.links[#L.links + 1] = { url = ln.url, label = ln.text, n = ln.n, image = ln.image,
                                          line = li, first = L.count + 1, last = 0 }
                link = #L.links
            end
            local h = boxes and ln.image and boxes[link]
            if h then
                for _ = 1, m.boxRows(h) do add(li, 1, 0, M.BOX, link, false) end
            else
                local s, e = wrap.wrap(ln.text, width, adv)
                for k = 1, #s do
                    add(li, s[k], e[k], (style == M.ITEM and k > 1) and M.ITEMC or style, link, false)
                end
            end
            if link > 0 then L.links[link].last = L.count end
        end
    end
    return L
end

-- Metrics for a layout counted in columns: every byte one wide, a two-column
-- indent. Boxes are given in rows (boxRows passes them on), as tests do.
function M.mono(cols)
    return { width = cols, indent = 2, preCols = cols - 1, boxRows = function(rows) return rows end }
end
```

`src/theme.lua`: replace the comment above `M.new` and `M.new` itself, and add `M.preCols` and `M.metrics` (keep `M.cols`, `M.uiCols` and `M.rows`). Add `local inline = require("src.inline")` at the top.

```lua
-- spec: a reading font from fonts.load. font/bold: the reading font, for page
-- text only; adv/boldAdv: their advances; indent: list and quote indent in
-- px; pre: the monospace font for preformatted lines, whose cell width is
-- cw. ui/uiCw: the system font (6x8), for everything else: the firmware
-- draws the title bar, footer, tabs, list rows, toasts, text boxes and the
-- system menu in whatever font is current, laid out for 6x8.
function M.new(disp, spec)
    local rgb = disp.rgb
    return {
        fontName = spec.name, font = spec.font, bold = spec.bold, adv = spec.adv, boldAdv = spec.boldAdv,
        indent = spec.indent, pre = spec.pre,
        ui = disp.FONT_6X8, uiCw = 6,
        cw = spec.pre.cw, rowH = spec.rowH, top = 21, bottom = 302, margin = 4,
        bg = disp.BLACK, fg = disp.WHITE, dim = rgb(120, 120, 120),
        h1 = rgb(255, 210, 80), h2 = rgb(120, 200, 255), h3 = rgb(160, 230, 160),
        link = rgb(100, 170, 255), image = rgb(220, 140, 255), read = rgb(110, 130, 160),
        selBg = rgb(40, 70, 130), quote = rgb(170, 170, 170), preColor = rgb(150, 220, 150),
        bar = rgb(90, 90, 90), error = rgb(255, 110, 110),
    }
end

-- Columns of a preformatted row: the code font's columns less one for the
-- continuation mark.
function M.preCols(th)
    return (320 - 2 * th.margin) // th.pre.cw - 1
end

-- Layout metrics for this reading font (proportional fonts spec 5.2).
function M.metrics(th)
    return {
        width = 320 - 2 * th.margin, adv = th.adv, boldAdv = th.boldAdv, indent = th.indent,
        preCols = M.preCols(th), boxRows = function(h) return inline.rows(h, th.rowH) end,
    }
end
```

The theme's colour for preformatted lines was the field `pre`; it is now `preColor` (as in the code above), because `th.pre` is the code font table. Update `rowColor` in `src/screens/page.lua` to `if st == layout.PRE then return th.preColor end`, and check nothing else reads the colour: run `grep -rn "\.pre\b" src` and confirm every remaining hit means the code font.

`src/inline.lua`:
- Replace the constant block and `M.rows`:

```lua
-- A box is at most ROWS rows; its picture has PAD px above and below it and
-- fits FIT_W (the page width less its margins) by FIT_H: ten 13 px rows less
-- the padding. On 14 px rows (Sans) the same pictures take at most 10 rows.
M.ROWS, M.PAD = 10, 2
M.FIT_W, M.FIT_H = 312, 126
```

```lua
-- The rows of a box for a picture h px tall, on rows rowH px apart.
function M.rows(h, rowH)
    return (h + 2 * M.PAD + rowH - 1) // rowH
end
```

- Change the comment on `M.new` to `-- boxes: {[k] = picture height in px} for image links already laid out as boxes (Back, Reload), or nil. wake: something may have changed since the last pass.`

`src/app.lua`:
- Add `local fonts = require("src.fonts")` with the other requires.
- `App.new(pc, appId, appDir)`: set `appDir = appDir or "/apps/picosurf"` in the table passed to `setmetatable`, i.e. `local self = setmetatable({ pc = pc, appDir = appDir or "/apps/picosurf" }, App)`.
- In `loadConfig`, set `font = fonts.normalize(c.get("font") or "scientifica")` in `self.cfg`. Replace the `self.theme = theme.new(self.disp, self.cfg.font)` line with `self:loadFont()`.
- Add after `loadConfig`:

```lua
-- The reading font (proportional fonts spec 3, 4): loaded again when the
-- setting changed, or when the last load fell back to Scientifica.
function App:loadFont()
    local want = self.cfg.font
    if self.fontSpec and self.fontSpec.name == want then return end
    if self.fontSpec then fonts.unload(self.disp, self.fontSpec) end
    local spec, err = fonts.load(self.disp, self.appDir, want)
    self.fontSpec = spec
    self.theme = theme.new(self.disp, spec)
    self:log("font", spec.name)
    if err then self:log("error", "-", err) end
end
```

- In `buildPage`, `relayout` and `showFeed`, use `theme.metrics(self.theme)` in place of `theme.cols(self.theme)` / `cols` as `layout.build`'s second argument. Remove the now-unused `local cols` in `buildPage`.
- In `App:decodeInline`, replace from `local rows = inline.rows(h)` to the end of the links loop with:

```lua
    local rows = inline.rows(h, self.theme.rowH)
    for k, link in ipairs(p.L.links) do
        if link.image and link.url == u then
            if p.L.style[link.first] ~= layout.BOX or link.last - link.first + 1 ~= rows then
                p.ps:shift(link.first, layout.setBox(p.L, k, rows))
            end
            st.boxes[k] = h -- heights, so a font with other rows recomputes them
            self:log("inline", k, "w=" .. w, "h=" .. h, "rows=" .. rows)
        end
    end
```

- Change the comment on `copyBoxes` to say "box heights".

`main.lua`: `App.new(picocalc, APP_ID, APP_DIR):run()`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `lua tests/run.lua tests/test_layout.lua tests/test_pagestate.lua tests/test_inline.lua tests/test_fonts.lua && make test`
Expected: all pass under both Luas.
- `tests/test_app.lua`, `tests/test_app_inline.lua` and `tests/test_app_feeds.lua` pass unchanged: the default is still Scientifica, and its layout is identical.
- If an inline test asserts a `st.boxes` value, it now holds the picture's height. Update that assertion only, and say so in the report.

- [ ] **Step 5: Commit**

```bash
git add src/layout.lua src/theme.lua src/inline.lua src/app.lua src/screens/page.lua main.lua tests/test_layout.lua tests/test_pagestate.lua tests/test_inline.lua tests/test_fonts.lua
git commit -m "feat: lay pages out by font metrics; picture boxes keep their heights"
```

---

### Task 5: Drawing proportional pages

**Files:**
- Modify: `src/screens/page.lua`, `src/theme.lua` (remove `M.cols`), `tests/fakepc.lua`
- Create: `tests/test_app_fonts.lua`

**Interfaces:**
- Consumes:
  - `th.indent`, `th.pre = {font, cw}`, `th.adv`;
  - `theme.preCols(th)` (Task 4);
  - `wrap.fit` (Task 3);
  - fakepc `F.textWidthIn`, `F.fontFiles` (Task 2).
- Produces:
  - The page draws indents in px, code blocks in the code font, the `\` mark after `preCols` columns, and box labels cut by width.
  - fakepc records each `drawText`'s x in `F.textXs`, parallel to `F.texts`.

- [ ] **Step 1: Write the failing tests**

In `tests/fakepc.lua`:
- Add `textXs = {}` to the initial `F` table.
- Change `display.clear` to also reset it: `function display.clear() F.texts, F.textFonts, F.rects, F.imageDraws, F.textXs = {}, {}, {}, {}, {} end`.
- Change `display.drawText` to `function display.drawText(x, _, t) record(t); F.textXs[#F.texts] = x; return display.textWidth(t) end`.

Create `tests/test_app_fonts.lua`:

```lua
local T = require("tests.t")
local fakepc = require("tests.fakepc")
local App = require("src.app")
local layout = require("src.layout")

local function lines(from, to)
    local out = {}
    for i = from, to do out[#out + 1] = "line " .. i end
    return table.concat(out, "\n")
end

local FONTS_PAGE = table.concat({
    "# Reading fonts",
    "* " .. string.rep("item words ", 8),
    "> " .. string.rep("quoted words ", 6),
    "```",
    string.rep("x", 60),
    "```",
    string.rep("mmmm iiii ", 12),
    "https://example.com/" .. string.rep("averylongpath", 6),
}, "\n")

local LABEL = "[IMG] " .. string.rep("mmmm ", 19) .. "mmmm"

local function jpeg(w, h)
    return { type = "image/jpeg", mode = false, body = "JPEG:" .. w .. "x" .. h }
end

local ROUTES = {
    ["https://fonts.test/"] = { title = "F", body = FONTS_PAGE },
    ["https://label.test/"] = { title = "L", body = "# L\n=> https://img.test/p.jpg " .. LABEL .. "\n" },
    ["https://pics.test/"] = {
        title = "Pics",
        body = table.concat({ "# Pics", "intro", "=> https://img.test/1.jpg [IMG] one", lines(1, 40) }, "\n"),
    },
    ["https://b.test/"] = { title = "B", body = "# B\n\nBack page.\n" },
    ["https://img.test/p.jpg"] = jpeg(200, 120),
    ["https://img.test/1.jpg"] = jpeg(200, 120), -- 10 rows of 13 px, 9 of 14 px
}

-- opts.font: saved Font setting (nil: none saved); opts.missing: a font path that fails to load.
local function boot(opts)
    opts = opts or {}
    local F = fakepc.new()
    F.config.proxy_url, F.config.token = "https://p.test", "tok"
    if opts.font then F.config.font = opts.font end
    F.config.images = opts.images
    if opts.missing then F.missingFonts[opts.missing] = true end
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

-- The x of the first page text drawn in the last frame that starts with `prefix`.
local function xOf(F, prefix)
    for i, t in ipairs(F.texts) do
        if F.textXs[i] and t:sub(1, #prefix) == prefix then return F.textXs[i] end
    end
    return nil
end

-- No page text drawn in the last frame runs past the page's right margin.
local function assertWithinPage(F)
    local n = 0
    for i, t in ipairs(F.texts) do
        local x = F.textXs[i]
        if x then
            n = n + 1
            T.ok(x + F.textWidthIn(F.textFonts[i], t) <= 316, "overflows the page: " .. t)
        end
    end
    T.ok(n > 5, "page text was drawn")
end

local function boxRows(app, k)
    local L = app.page.L
    local link = L.links[k]
    if L.style[link.first] ~= layout.BOX then return 0 end
    return link.last - link.first + 1
end

return {
    proportional_pages_indent_and_keep_code_monospace = function() -- Review Focus 1
        local app, F = boot({ font = "sans" })
        go(app, F, "fonts.test/")
        local D = F.pc.display
        T.eq(app.theme.fontName, "sans")
        T.eq(F.fontFiles[F.fontOf("Reading fonts")], "/apps/picosurf/fonts/sans-bold.pfn", "headings in bold")
        T.eq(F.fontFiles[F.fontOf("mmmm iiii")], "/apps/picosurf/fonts/sans.pfn", "text in Sans")
        T.eq(F.fontOf(string.rep("x", 51)), D.FONT_SCIENTIFICA, "code in Scientifica")
        T.eq(xOf(F, string.rep("x", 51)), 4)
        T.eq(xOf(F, "\\"), 4 + 51 * 6, "the continuation mark after 51 columns")
        T.eq(xOf(F, "*"), 4, "the bullet at the margin")
        T.eq(xOf(F, "item words"), 16, "item text after the 12 px indent")
        T.eq(xOf(F, "quoted words"), 16, "quotes after the indent")
        T.eq(xOf(F, "mmmm iiii"), 4)
        assertWithinPage(F)
    end,
    a_picture_label_is_cut_to_fit_by_width = function()
        local app, F = boot({ font = "sans", images = "inline" })
        go(app, F, "label.test/")
        steps(app, 3)
        local st = app.page.inline
        st.byUrl["https://img.test/p.jpg"].img = nil -- as after it left the window
        st.wake = false
        app.dirty = true
        steps(app, 1)
        local found
        for i, t in ipairs(F.texts) do
            if F.textXs[i] and #t > 5 and LABEL:sub(1, #t) == t then found = i end
        end
        T.ok(found, "the label is drawn")
        local font, shown = F.textFonts[found], F.texts[found]
        T.ok(F.textWidthIn(font, shown) <= 300, "within the box")
        T.ok(F.textWidthIn(font, LABEL:sub(1, #shown + 1)) > 300, "as much as fits")
    end,
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `lua tests/run.lua tests/test_app_fonts.lua`
Expected: FAIL, because the page still draws code in the reading font (`code in Scientifica`) and still cuts labels by character count.

- [ ] **Step 3: Implement**

`src/screens/page.lua`:
- Add `local wrap = require("src.wrap")` with the other requires.
- In `drawBox`:
  - Drop the `cols` parameter: `local function drawBox(app, k)`.
  - Replace its last three lines (from `d.setFont(th.font)`) with:

```lua
    d.setFont(th.font)
    local row = math.max(link.first, ps.top)
    local label = wrap.fit(link.label, 320 - 2 * th.margin - 2 * th.pre.cw, th.adv)
    d.drawText(th.margin + th.pre.cw, th.top + 1 + (row - ps.top) * th.rowH, label, th.dim, false)
```

- In `S.draw`:
  - Replace `local cols = theme.cols(th)` with `local preCols = theme.preCols(th)`.
  - Change the box call to `drawBox(app, k)`.
  - Replace the `else` branch of the row loop with:

```lua
        else
            local x = th.margin
            if L.link[r] ~= 0 and L.link[r] == ps.sel then d.fillRect(0, y - 1, 320, th.rowH, th.selBg) end
            local heading = st == layout.H1 or st == layout.H2 or st == layout.H3
            d.setFont(st == layout.PRE and th.pre.font or (heading and th.bold or th.font))
            if st == layout.ITEM then
                d.drawText(x, y, "*", th.dim, false)
                x = x + th.indent
            elseif st == layout.ITEMC then
                x = x + th.indent
            elseif st == layout.QUOTE then
                d.fillRect(x, y - 1, 2, th.rowH, th.bar)
                x = x + th.indent
            end
            d.drawText(x, y, layout.rowText(L, r), rowColor(th, st), false)
            if L.cont[r] then d.drawText(th.margin + preCols * th.pre.cw, y, "\\", th.dim, false) end
        end
```

`src/theme.lua`: delete `M.cols`, which nothing uses any more (check with `grep -rn "theme.cols" src tests`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `lua tests/run.lua tests/test_app_fonts.lua && make test`
Expected: all pass under both Luas. Scientifica and 8×12 pages draw at the same x positions as before: indent 12 (or 16) px, code in their own font, the mark at `(cols - 1) * cw`.

- [ ] **Step 5: Commit**

```bash
git add src/screens/page.lua src/theme.lua tests/fakepc.lua tests/test_app_fonts.lua
git commit -m "feat: draw proportional pages: px indents, monospace code, labels cut by width"
```

---

### Task 6: Sans and Serif in Settings, Sans by default, the fallback, and fonts across Back

**Files:**
- Modify: `src/app.lua`, `src/screens/settings.lua`, `tests/test_app.lua`, `tests/test_app_inline.lua`, `tests/test_app_feeds.lua`
- Test: `tests/test_app_fonts.lua`

**Interfaces:**
- Consumes: `fonts.normalize`, `fonts.nextChoice` and `fonts.LABELS` (Task 2); `App:loadFont` (Task 4).
- Produces:
  - **Default:** `font` unset means Sans.
  - **Settings:** cycles the four choices.
  - **Fallback:** the toast `Font unavailable - using Scientifica`.
  - **Back:** back entries and Reload carry `font` (the font name in use), and `buildPage` restores by line when the font differs.

- [ ] **Step 1: Write the failing tests**

Pin today's tests to Scientifica: their row and column numbers assume it.
- `tests/test_app.lua` `boot`: `F.config.font = opts.font or "scientifica"`.
- `tests/test_app_inline.lua` `boot`: `F.config.images, F.config.font = opts.images, opts.font or "scientifica"`.
- `tests/test_app_feeds.lua` `boot`: add `F.config.font = "scientifica"` after the token line.

Add to `tests/test_app_fonts.lua` above `return {`:

```lua
-- Settings, then the Font row (the third): steps to the next font; Esc back.
local function nextFont(app, F)
    F.menu["Settings"](); steps(app, 1)
    F.press("down"); F.press("down"); F.press("enter"); steps(app, 1)
    F.press("esc"); steps(app, 1)
end
```

and these entries to the returned table:

```lua
    the_default_font_is_sans = function()
        local app, F = boot()
        T.eq(app.cfg.font, "sans"); T.eq(app.theme.fontName, "sans"); T.eq(app.theme.rowH, 14)
        T.eq(require("src.theme").rows(app.theme), 20)
        T.ok(F.hasLog("picosurf: font sans"))
    end,
    settings_step_through_the_four_fonts = function()
        local app, F = boot({ font = "sans" })
        local LABEL = { serif = "Serif", scientifica = "Scientifica", ["8x12"] = "8x12 (large)", sans = "Sans" }
        local seen = {}
        for _ = 1, 4 do
            F.menu["Settings"](); steps(app, 1)
            F.press("down"); F.press("down"); F.press("enter"); steps(app, 1)
            seen[#seen + 1] = F.config.font
            T.ok(F.screenText():find("Font: " .. LABEL[F.config.font], 1, true), "label for " .. F.config.font)
            T.eq(app.theme.fontName, F.config.font)
            F.press("esc"); steps(app, 1)
        end
        T.eq(table.concat(seen, ","), "serif,scientifica,8x12,sans")
        local loaded = 0
        for _ in pairs(F.fontFiles) do loaded = loaded + 1 end
        T.eq(loaded, 2, "only the current font's two files stay loaded")
    end,
    a_missing_font_file_falls_back_to_scientifica = function() -- Review Focus 4
        local app, F = boot({ font = "serif", missing = "/apps/picosurf/fonts/serif-bold.pfn" })
        T.eq(app.theme.fontName, "scientifica"); T.eq(app.cfg.font, "serif", "the setting keeps its value")
        T.ok(F.hasToast("Font unavailable - using Scientifica"))
        T.ok(F.hasLog("/apps/picosurf/fonts/serif-bold.pfn"))
        T.ok(F.hasLog("picosurf: font scientifica"))
        T.eq(next(F.fontFiles), nil, "nothing left loaded")
    end,
    a_font_change_resizes_picture_boxes_and_keeps_the_line = function() -- Review Focus 3
        local app, F = boot({ font = "scientifica", images = "inline" })
        go(app, F, "pics.test/")
        steps(app, 3)
        T.eq(boxRows(app, 1), 10, "120 px on 13 px rows")
        app.page.ps:scroll(15); app.dirty = true; steps(app, 2)
        local line = app.page.L.line[app.page.ps.top]
        nextFont(app, F); nextFont(app, F) -- scientifica -> 8x12 -> sans
        T.eq(app.cfg.font, "sans")
        T.eq(boxRows(app, 1), 9, "120 px on 14 px rows")
        T.eq(app.page.L.line[app.page.ps.top], line, "the same line at the top")
    end,
    back_across_a_font_change_lands_on_the_same_line = function() -- Review Focus 5
        local app, F = boot({ font = "scientifica", images = "inline" })
        go(app, F, "pics.test/")
        steps(app, 3)
        app.page.ps:scroll(15); app.dirty = true; steps(app, 2)
        local line = app.page.L.line[app.page.ps.top]
        go(app, F, "b.test/")
        nextFont(app, F); nextFont(app, F)
        F.press("backspace"); steps(app, 3)
        T.eq(app.page.url, "https://pics.test/")
        T.eq(app.page.L.line[app.page.ps.top], line, "the same line at the top")
        T.eq(boxRows(app, 1), 9, "the box in Sans rows from the saved height")
    end,
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `lua tests/run.lua tests/test_app_fonts.lua tests/test_app.lua tests/test_app_inline.lua tests/test_app_feeds.lua`
Expected: FAIL.
- The default is Scientifica.
- Settings toggles between only two fonts.
- There's no toast.
- Back lands on a different line.

The pinned old tests still pass.

- [ ] **Step 3: Implement**

`src/app.lua`:
- In `loadConfig`: `font = fonts.normalize(c.get("font"))`.
- In `App:loadFont`, replace `if err then self:log("error", "-", err) end` with:

```lua
    if err then
        self:log("error", "-", err)
        self:toast("Font unavailable - using Scientifica", self.ui.TOAST_WARNING)
    end
```

- In `pushBack`'s entry, add `font = self.theme.fontName,`. In `goBack`: `local restore = { top = e.top, sel = e.sel, boxes = e.boxes, line = e.line, font = e.font }`. In `reload`'s `restore`, add `font = self.theme.fontName,`.
- In `buildPage`, change the restore block to:

```lua
    if restore then
        local top = restore.top
        -- The saved rows were counted in another layout (other font, or boxes
        -- now gone): the saved source line goes back to the top instead.
        local relaid = restore.font ~= self.theme.fontName or (restore.boxes and not boxes)
        if relaid and restore.line then top = firstRowOf(L, restore.line) end
        page.ps:restore(top, restore.sel)
    end
```

  Update the comment above `buildPage` to mention a font change.

`src/screens/settings.lua`:
- Add `local fonts = require("src.fonts")`.
- Label: `if item == "font" then return "Font: " .. fonts.LABELS[c.font] end`.
- Enter on `font`: `app:saveConfig("font", fonts.nextChoice(app.cfg.font))` followed by the existing `app:relayout()`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `lua tests/run.lua tests/test_app_fonts.lua && make test`
Expected: all pass under both Luas.

- [ ] **Step 5: Commit**

```bash
git add src/app.lua src/screens/settings.lua tests/test_app.lua tests/test_app_inline.lua tests/test_app_feeds.lua tests/test_app_fonts.lua
git commit -m "feat: Sans and Serif in Settings, Sans by default, a Scientifica fallback, and Back across a font change"
```

---

### Task 7: Simulator test and docs

**Files:**
- Modify:
  - `tests/e2e/test_app.py`
  - `docs/superpowers/specs/2026-10-15-picosurf-design.md`, `docs/superpowers/specs/2026-10-16-picosurf-inline-images-design.md`
  - `README.md`, `docs/hardware-pass.md`

**Interfaces:**
- Consumes:
  - the log line `picosurf: font <name>`;
  - the staged `fonts` folder (Task 1);
  - the default Sans (Task 6).

- [ ] **Step 1: Write the simulator test**

Add to `tests/e2e/test_app.py` after `test_inline_picture`:

```python
def test_default_font_is_sans(picosurf):
    sim, proxy, data = picosurf()
    seed_history(data, "https://a.test/")
    proxy.add("https://a.test/", A, title="A")
    wait(sim, r"picosurf: font sans", start_app(sim))
    wait(sim, r"picosurf: loaded https://a\.test/", open_first_history(sim))
    time.sleep(0.5)  # the frame drawn after the log line
    img = sim.screenshot_pil().convert("RGB")
    # Row 3 ("See B [1].") on 14 px rows starts at y 22 + 2 * 14 = 50.
    lit = sum(1 for x in range(4, 120) for y in range(50, 63) if sum(img.getpixel((x, y))) > 300)
    assert lit > 20, lit
    errors = [l["text"] for l in sim.get_log_lines() if "/fonts/" in l.get("text", "")]
    assert not errors, errors
    no_lua_errors(sim)
```

- [ ] **Step 2: Run the simulator tests**

Run: `make e2e`
Expected: 8 passed.
- The new test proves the real firmware loads the committed `.pfn` files and draws page text with them.
- `test_inline_picture` still passes on 14 px rows. Its picture band starts at y 21 + 4 × 14 = 77, and the pixel it checks, (160, 138), is still inside the picture.

If `test_default_font_is_sans` fails, read the simulator log for `picosurf: error` before changing anything.

- [ ] **Step 3: Update the docs**

Main spec `docs/superpowers/specs/2026-10-15-picosurf-design.md`:
- **2 (v1, the App bullet):** after `screen on demand, or shown in the page (Settings → Images; see\n  \`2026-10-16-picosurf-inline-images-design.md\`)` add `; proportional reading fonts, Sans and Serif (\`2026-10-16-picosurf-proportional-fonts-design.md\`)`. Keep the wrap.
- **6.3:** replace the **Fonts** bullet's first five lines, from `- **Fonts:** body` to `footer heights at runtime (about 52 × 22 with Scientifica).`, with:

```
- **Fonts:** four reading fonts, chosen in Settings (proportional fonts
  design): Sans (X11 Adobe Helvetica 12 and its bold, 14 px rows, the
  default), Serif (Utopia 10 and its bold, 13 px rows), Scientifica (6×12 and
  its bold, 13 px rows) and 8×12 (13 px rows, headings marked by colour only).
  Sans and Serif load from the app's `fonts/` folder; if that fails the app
  uses Scientifica. Rows come from the font's row height and the header and
  footer heights (20 rows with Sans, 21 otherwise).
```

  Keep the rest of the bullet (`The Font setting is the reading font: ...`).
- **6.3, Line styles:** change `Quotes get a two-column indent with a bar on the left.` to `Quotes get a 12 px indent (16 px with 8×12) with a bar on the left.` and `List items get a bullet with a hanging indent.` to `List items get a bullet with a hanging indent of the same width.`
- **6.3, Wrapping:** replace its first three lines, from `- **Wrapping:** \`layout.lua\` wraps` to `tests).`, with:

```
- **Wrapping:** `layout.lua` wraps once per page load or font change, by
  measured width: each character's advance is measured once when the font
  loads, and headings use the bold font's advances. Preformatted lines stay
  monospace (Scientifica under Sans and Serif) and are cut by column count.
```

  Keep its last sentence (`Rows are stored as parallel integer arrays ...`).
- **6.3, Inline pictures:** change `\`ceil((h + 4) / 13)\` rows` to `\`ceil((h + 4) / rowH)\` rows (rowH: the font's row height)`.
- **6.6:** change the config row's cell `` `proxy_url`, `token`, `font`, `images` `` to `` `proxy_url`, `token`, `font` (`sans`, `serif`, `scientifica` or `8x12`), `images` ``.
- **6.8:** change `Font switches between Scientifica and 8×12.` to `Font steps through Scientifica, 8×12, Sans and Serif (Sans by default).` Rewrap the paragraph if needed.
- **6.9:** add before `| Corrupt storage file | 6.6 |`:

```
| Reading font file missing or rejected | Scientifica; toast `Font unavailable - using Scientifica`; the setting keeps its value |
```

- **7.2:** in the simulator list, after `- an inline picture drawn in its box (Images: Inline)`, add `- the default Sans font loading and drawing page text`.

Inline images design `docs/superpowers/specs/2026-10-16-picosurf-inline-images-design.md`:
- In 5.1's state block, change `boxes = { [k] = rows },` and its comment to `boxes = { [k] = h },     -- picture heights in px of image links laid out as boxes (kept across Back, Reload, font)`.
- Change `- \`inline.rows(h)\`: \`ceil((h + 4) / 13)\`` to `- \`inline.rows(h, rowH)\`: \`ceil((h + 4) / rowH)\`, rowH being the font's row height (proportional fonts design 5.3)`.
- In 5.3 change `rows = inline.rows(h)` to `rows = inline.rows(h, rowH)` and `set \`boxes[k] = rows\`` to `set \`boxes[k] = h\``.
- In 5.4 change ``**`build` with `boxes`:** link `k` gets `boxes[k]` rows`` to ``**`build` with `boxes`:** link `k` gets `boxRows(boxes[k])` rows``.

`README.md`: after the `**Images** in Settings ...` paragraph add:

```
**Font** in Settings steps through Scientifica, 8x12, Sans and Serif. Sans is the default: a proportional font that fits about 57 characters a line. Code blocks always use a monospace font.
```

`docs/hardware-pass.md`: add after item 22 (no blank line between items):

```
23. Settings → Font: Sans (the default), then Serif. Open the Wikipedia fixture article in each: time to the first screen ______ s / ______ s (target under 5 s, as with Scientifica). Read through a long article: no clipped letters, no line running past the right edge, code blocks in Scientifica.
```

- [ ] **Step 4: Run everything**

Run: `make test && make e2e && (cd proxy && npm test)`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add tests/e2e/test_app.py docs/superpowers/specs/2026-10-15-picosurf-design.md docs/superpowers/specs/2026-10-16-picosurf-inline-images-design.md README.md docs/hardware-pass.md
git commit -m "test: default Sans font in the simulator; docs: the four reading fonts"
```

---

## After the plan (ask the user first)

- Push the app to the device, including its `fonts/` folder; the device staging folder must copy `fonts` as well as `app.json`, `main.lua` and `src`. Then run hardware-pass item 23.
- Remove the throwaway preview app at `/apps/.dev/fontpreview` on the device.
