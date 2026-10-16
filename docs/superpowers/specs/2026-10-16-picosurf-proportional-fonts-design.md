# PicoSurf proportional reading fonts

Date: 2026-10-16. Status: design, for review.

This amends the main spec, `2026-10-15-picosurf-design.md`, and the inline
images design, `2026-10-16-picosurf-inline-images-design.md`. Section 10
lists the sections that change.

## 1. Goal

Two proportional reading fonts next to today's monospace ones, so articles
read like set type rather than terminal text.

- **Settings → Font** steps through **Scientifica**, **8×12**, **Sans** and
  **Serif**.
- **The new fonts:**
  - **Sans** is X11 Adobe Helvetica 12 with its bold, on 14 px rows (20 rows
    a screen).
  - **Serif** is X11 Adobe Utopia 10 with its bold, on 13 px rows (21 rows).
  - The UI says Sans and Serif, not the typeface names, because Helvetica is a
    trademark.
- **Default:** Sans becomes the default font. A device that never saved a
  font, such as the author's, switches to it.
- **Success:**
  - Sans and Serif pages wrap by measured width, with no letter clipped and no
    line wider than the page.
  - Scientifica and 8×12 lay out exactly as they do today.
  - Code blocks stay monospace.
  - Inline pictures keep working across a font change.
- **Chosen by:** the author, after an on-device preview of 13 candidates.
  The converter bugs met on the way are PicoDeck issue #74.
- **Not in scope:**
  - accented or other non-ASCII glyphs (the proxy folds text to ASCII);
  - anti-aliasing (the firmware's fonts are 1-bit);
  - user-supplied fonts;
  - kerning;
  - a font size setting.

## 2. Fonts and files

| File (app folder `fonts/`) | Source | Line height |
|---|---|---|
| `sans.pfn`, `sans-bold.pfn` | `helvR12.bdf`, `helvB12.bdf` from X.Org `font-adobe-75dpi` 1.0.4 | 13 px |
| `serif.pfn`, `serif-bold.pfn` | `UTRG__10.bdf`, `UTB___10.bdf` from X.Org `font-adobe-utopia-75dpi` 1.0.5 | 10 px |
| `LICENSE` | Both COPYING texts, verbatim | — |

- The four `.pfn` files total about 9 KB and cover ASCII 0x20-0x7E.
- **The conversion is reproducible:** `tools/build-fonts.py` takes the two X.Org
  tarballs and checks their SHA-256. It then pre-processes the BDFs:
  - ASCII only, with a tight bounding box;
  - DWIDTH widened where ink overhangs the advance;
  - over-padded rows truncated.

  Finally it runs PicoDeck's `tools/mkfont.py` (found through `PICODECK_ROOT`,
  as `make test` already does) and writes the four files and `fonts/LICENSE`.
  The generated files are committed, so building the app needs neither the
  tarballs nor PicoDeck.
- **Licences:**
  - Helvetica carries the Adobe/DEC permission notice: copy, modify and
    distribute freely, with the copyright notice kept.
  - Utopia carries Adobe's notice, which also requires "Copyright (c) 1989
    Adobe Systems Incorporated" and "Utopia (R) is a registered trademark of
    Adobe Systems Incorporated" in the credits.
  - `fonts/LICENSE` holds both texts. The README gets a Credits section with
    both copyright lines and the Utopia trademark line.
- **Packaging:** the store ZIP (`.github/workflows/release.yml`) and the
  simulator tests' staging (`tests/e2e/conftest.py` `APP_FILES`) add `fonts`.

## 3. Loading and measuring (`src/fonts.lua`, new)

```lua
fonts.CHOICES = { "scientifica", "8x12", "sans", "serif" }
spec, err = fonts.load(disp, appDir, name)   -- never raises
fonts.unload(disp, spec)
```

`spec` is everything the theme needs about the reading font:

```lua
{
  name = "sans",
  font = id, bold = id,           -- display font ids (built-in or loaded)
  rowH = 14,                      -- row pitch in px
  adv = {[byte] = px},            -- advance of every byte 0x20-0x7E, regular
  boldAdv = {[byte] = px},        -- the same for bold (= adv when no bold)
  indent = 12,                    -- list and quote indent in px
  pre = { font = id, cw = 6 },    -- monospace font for preformatted lines
  loaded = { id, ... },           -- ids to unload
}
```

- **Built-ins:**
  - Scientifica uses `FONT_SCIENTIFICA` and `FONT_SCIENTIFICA_BOLD`, with 13 px
    rows and a 12 px indent; its code blocks use Scientifica.
  - 8×12 uses `FONT_8X12` for both regular and bold, with 13 px rows and a
    16 px indent; its code blocks use 8×12.
- **Sans and Serif:**
  - Each loads its two files with `display.loadFont(appDir .. "/fonts/<name>.pfn")`
    and `<name>-bold.pfn`.
  - Their code blocks use Scientifica, so code is the same size as before.
  - Indent is 12 px.
- **Measuring:** each byte's advance is read once per load. The loader sets the
  font and calls `display.textWidth` on each character, 2 × 95 calls. Built-ins
  are measured the same way, so there is one wrapping path for every font.
- **On failure:** if a file is missing or rejected (`loadFont` returns nil), the
  loader unloads anything it loaded and returns the Scientifica spec. The
  error is returned as the second result. The app logs it and shows the toast
  `Font unavailable - using Scientifica`.
- **Font slots:** at most two fonts are loaded at once, of the firmware's eight
  slots.

## 4. Theme

`theme.new(disp, spec)` takes the loaded spec instead of a font name:
- `font`, `bold` and `rowH` come from the spec. `cw` stays as the monospace
  cell of the code-block font.
- `theme.rows(th)` already divides by `rowH`, so it gives 20 rows for Sans.
- `theme.cols` is no longer used for page text.

`App:loadConfig` runs on every saved setting. It now:
1. unloads the previous theme's fonts;
2. loads the configured font (default `"sans"`);
3. builds the theme.

A font change still calls `App:relayout`.

## 5. Layout

### 5.1 Wrapping by width (`src/wrap.lua`)

`wrap.wrap(text, width, adv)`:
- With `adv` (a byte → px table), `width` is in pixels. A row ends at the last
  space whose text still fits; a word wider than a row is split. Spaces at a
  break are dropped, as today.
- Without `adv`, every byte is 1 wide, so `wrap.wrap(text, cols)` behaves as it
  does now. The Home hints, message screen and Settings notes keep calling it
  that way in the system font.
- Bytes missing from `adv` count as the widest advance in the table, so
  out-of-range bytes can never overflow a row.

### 5.2 Layout metrics (`src/layout.lua`)

`layout.build(lines, m, boxes)` takes a metrics table in place of `cols`:

```lua
m = { width = 312, adv = ..., boldAdv = ..., indent = 12,
      preCols = 51, boxRows = function(h) ... end }
```

- Text, links, list items and quotes wrap with `wrap.wrap(text, width - offset, adv)`:
  - list items and quotes use `width - indent`;
  - headings use `boldAdv`.
- Preformatted lines are cut by count at `preCols`, the code-block font's
  columns less one for the `\` mark, as today.
- Boxes: `boxes[k]` is now a picture **height in px**, not a row count (5.3).
  Build lays link k out as `m.boxRows(boxes[k])` box rows.
- `layout.mono(cols)` returns metrics with every byte 1 wide, `width = cols`,
  `indent = 2` and `preCols = cols - 1`. These are today's semantics, for tests
  and for laying out with any monospace font.
- The theme builds `m` from the spec: `width = 320 - 2 * margin`;
  `preCols = width // pre.cw - 1`; `boxRows(h) = ceil((h + 4) / rowH)`.

With Scientifica, `width = 312` px at 6 px a byte is the same 52 columns as
today, so rows, links and saved scroll positions are unchanged.

### 5.3 Inline picture boxes

Box height in rows now depends on the font's row height, so:
- `st.boxes[k]` holds the picture's height in px. Back entries and Reload carry
  heights, which keeps them valid across a font change.
- `inline.rows(h, rowH)` replaces `inline.rows(h)`. `inline.ROW_H` goes.
- `FIT_W`, `FIT_H` and `FIT` stay at 312×126, so the proxy request doesn't
  change.
- A box is at most `ceil(130 / rowH)` rows: 10 at 13 px or 14 px.
- `App:decodeInline` compares the link's current rows with
  `boxRows(h)` and calls `layout.setBox` when they differ.
- `relayout` and `buildPage` pass the heights through, so a font change
  recomputes every box.

## 6. Drawing (`src/screens/page.lua`)

- **Rows:** start at `th.top + 1 + (r - top) * rowH`, as now. The selection band
  and the quote bar are `rowH` tall, so a 13 px Sans glyph sits in a 14 px band
  with 1 px of leading.
- **Indents:** list continuation rows and quotes start at `margin + indent`.
  The list bullet `*` stays at the margin in the reading font.
- **Code blocks:** preformatted rows draw in `pre.font`. The `\` continuation
  mark sits at `margin + preCols * pre.cw`.
- **Headings:** H1-H3 draw in `bold`.
- **Box labels:** a box's placeholder alt text is cut to fit
  `width - 2 * pre.cw` px with the reading font's advances, not by character
  count.
- **The rest:** the title bar, footer and other screens are unchanged, and
  draw in the system font.

## 7. Settings and config

- `config.json` key `font`: `"scientifica"`, `"8x12"`, `"sans"` or `"serif"`.
  Missing or unknown means `"sans"`.
- Settings shows `Font: Scientifica`, `Font: 8x12 (large)`, `Font: Sans` or
  `Font: Serif`. Enter steps to the next one, wrapping round.

## 8. Errors

| Situation | Behaviour |
|---|---|
| Font file missing, unreadable or rejected | Scientifica; toast `Font unavailable - using Scientifica`; logged. The setting keeps its value, so a later app version with the file uses it |
| All 8 firmware font slots in use | Same as above (`loadFont` returns nil) |
| A byte outside 0x20-0x7E in page text | Measured as the widest advance, so it never overflows a row; drawn as the firmware's box glyph, as today |
| Out of memory while laying out | Unchanged: main spec 6.9 |

## 9. Testing

- **Host unit tests:**
  - **`wrap`:**
    - width wrapping with an `adv` table: break at spaces, split long words,
      drop spaces at breaks;
    - unknown bytes counted as the widest;
    - every old count-based case unchanged when `adv` is nil.
  - **`layout`:**
    - `layout.mono` gives today's rows for the existing cases;
    - proportional metrics wrap headings with `boldAdv` and indent items;
    - code blocks are cut by `preCols`;
    - box heights in px turn into rows by `boxRows`.
  - **`fonts`, with fakepc:**
    - fakepc gains `display.loadFont`, with failure injectable per path, and a
      per-font `textWidth` with a fake proportional table;
    - checks: the advance tables, the four choices' specs, the fallback on a
      missing file, and unloading.
  - **`inline`:** `rows(h, rowH)` at 13 and 14 px.
- **App tests:**
  - Settings cycles the four fonts and saves them.
  - The default is Sans.
  - A missing font file gives Scientifica and the toast.
  - A font change keeps the top line and the selected link, and resizes
    inline boxes. Back across a font change lands on the same line.
  - Existing tests that assume Scientifica's 52 columns set `font =
    "scientifica"` explicitly.
- **Font build:** a host test that reads each committed `.pfn` header and
  width table and checks four things: the `PFNT` magic, the range
  0x20-0x7E, a height no taller than the font's row, and every width at
  least 1. The real firmware check is the simulator test.
  `tools/build-fonts.py` is run once in the plan and its output committed;
  it records the source tarballs' SHA-256 (font-adobe-75dpi 1.0.4:
  `1281a62d…b911`; font-adobe-utopia-75dpi 1.0.5: `a7262459…7760`).
- **Simulator e2e:**
  - The default font is now Sans. A test opens a page and checks the log line
    `picosurf: font sans` and that a row of text is drawn.
  - The inline picture test still passes; its pixel check stays inside the
    picture at the new 14 px rows.
- **Hardware pass, added:**
  - time to the first screen of the Wikipedia fixture article in Sans against
    Scientifica (target under 5 s, as now);
  - Sans and Serif read cleanly, with no clipped letters, through a long
    article.

## 10. Changes to other specs

These are made with the implementation:
- **Main spec:**
  - 2: v1 has proportional reading fonts.
  - 6.3:
    - fonts: four choices, row height per font, Sans the default;
    - wrapping by measured width;
    - code blocks monospace.
  - 6.6: `font` values.
  - 6.8: the Font field.
  - 6.9: the font-unavailable row.
  - 7.2: the tests.
- **Inline images design:**
  - 5.1: `boxes` holds heights in px.
  - 5.3: rows from `rowH`.
  - 5.6: Back carries heights.
- **README:** the Font setting, and a Credits section with the font notices.

## 11. Decisions

- **Measure each glyph once, wrap in Lua, rather than measure per line or add
  a firmware wrap call.**
  - Measuring per line means thousands of `textWidth` calls on a long page, and
    it can't run in host tests.
  - A firmware call would tie the app to new firmware.
  - If the hardware pass shows Lua wrapping is slow on 256 KB pages, a firmware
    call that returns break offsets is the fallback.
- **One wrapping path for all fonts**, with the built-ins measured too, so
  Scientifica keeps today's layout through the same code.
- **Boxes store picture heights, not rows**, so a font change and Back stay
  correct with different row heights.
- **Code blocks stay in Scientifica** under Sans and Serif. Code needs
  columns, and Scientifica is the monospace font the reader already knows.
- **A pre-processing script inside PicoSurf** until PicoDeck issue #74 is fixed
  in `mkfont.py`; the committed `.pfn` files mean neither is needed to build
  the app.
- **Sans is the default**, because the author chose it after the on-device
  preview.
