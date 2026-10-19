# Spinner Redesign Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the SDK's rotating-line spinner with a pixel-glyph block-chase animation, and center picosurf's loading message and byte counter beneath it.

**Architecture:** Two repos. `picodeck` holds the SDK spinner (`ui_draw_spinner` in `src/os/ui.c`) — the C function is rewritten in place with its signature unchanged, so all callers (picosurf, store, updater, widgets) keep working. `picosurf` holds the loading screen layout (`src/screens/loading.lua`), which moves its two text lines from left-aligned at the margin to horizontally centered under the spinner using `display.textWidth`.

**Tech Stack:** C (PicoDeck firmware, `display_fill_rect`/`COLOR_*` primitives), Lua (picosurf app + host test suite via `tests/run.lua`, fake `picocalc` in `tests/fakepc.lua`).

**Design doc:** `docs/superpowers/plans/2026-10-20-spinner-redesign-design.md` (committed). Approved mock-ups: `/tmp/opencode/spinner_mockups/C-pixel-glyph-centered.{gif,png}`.

**Repos:**
- SDK: `/home/keith/Projects/PicoDeck/picodeck`
- App: `/home/keith/Projects/PicoDeck/picosurf`

---

### Task 1: SDK spinner rewrite (picodeck)

**Files:**
- Modify: `/home/keith/Projects/PicoDeck/picodeck/src/os/ui.c:551-567` (`ui_draw_spinner`)

**Context:** The current body draws a white rotating diameter line plus a gray trail line. Replace the whole body. Signature and header comment stay — `lua_bridge_ui.c`, `ui.h`, and every Lua caller are untouched. `COLOR_WHITE` and `COLOR_GRAY` are already used in this function, so no new includes are needed.

**Step 1: Rewrite `ui_draw_spinner`**

Replace the function body (and its comment) with:

```c
// ── ui_draw_spinner ───────────────────────────────────────────────────────────
// One frame of a pixel-glyph spinner: a 2x2 block chases itself around the
// corners of a 5x5 glyph (top-left → top-right → bottom-right → bottom-left),
// with a dim pixel trailing at the corner just vacated. Call once per frame
// with an incrementing frame counter. r picks the glyph's pixel scale.
void ui_draw_spinner(int cx, int cy, int r, int frame) {
  static const uint8_t corners[4][2] = { {0, 0}, {3, 0}, {3, 3}, {0, 3} };
  int px = (2 * r + 4) / 5; // glyph roughly fills the old 2r bounding box
  if (px < 2) px = 2;
  int ox = cx - (5 * px) / 2;
  int oy = cy - (5 * px) / 2;
  int f = frame & 3;
  display_fill_rect(ox + corners[f][0] * px, oy + corners[f][1] * px,
                    2 * px, 2 * px, COLOR_WHITE);
  int p = (f + 3) & 3;
  display_fill_rect(ox + corners[p][0] * px, oy + corners[p][1] * px,
                    px, px, COLOR_GRAY);
}
```

Sanity check the math: r=10 → px=4 → 20×20 glyph; r=12 (store/updater) → px=5 → 25×25; r=8 (default) → px=4. All fit the callers' layouts.

**Step 2: Build the simulator (compile check)**

Run: `cd /home/keith/Projects/PicoDeck/picodeck && make simulator`
Expected: build succeeds, no warnings in `ui.c`.

**Step 3: Smoke-test through picosurf's e2e suite**

The e2e suite drives picosurf on the simulator and passes through the loading screen (which calls `drawSpinner` every frame):

Run: `cd /home/keith/Projects/PicoDeck/picosurf && SDL_VIDEODRIVER=dummy python3 -m pytest tests/e2e -v`
Expected: all tests pass (no crash/regression from the new drawing code).

**Step 4: Commit (in the picodeck repo)**

```bash
cd /home/keith/Projects/PicoDeck/picodeck
git add src/os/ui.c
git commit -m "ui: redraw spinner as a pixel-glyph block chase"
```

---

### Task 2: Center the loading text (picosurf, TDD)

**Files:**
- Modify: `/home/keith/Projects/PicoDeck/picosurf/src/screens/loading.lua:65-84` (`S.draw`)
- Test: `/home/keith/Projects/PicoDeck/picosurf/tests/test_app.lua` (add a test at the end of the returned table, after `an_error_screen_uses_the_system_font`)

**Context:** The fake display records every drawn string's x in `F.textXs` (parallel to `F.texts`) and `display.textWidth` measures 6 px/char in the system font — so a host test can assert exact centered positions. With `F.holding = true`, `go()` parks the app on the loading screen. With `F.netStatus = 0`, the loading screen shows "Connecting to WiFi...".

**Step 1: Write the failing test**

Add to the table in `tests/test_app.lua`:

```lua
    the_loading_text_is_centered = function()
        local app, F = boot()
        local d = F.pc.display
        F.holding = true
        go(app, F, "a-rather-long-host-name-for-the-loading-screen.test/")
        T.eq(app.screenName, "loading")
        local found = 0
        for i, t in ipairs(F.texts) do
            if t:sub(1, 8) == "Loading " then
                found = found + 1
                T.eq(F.textXs[i], (320 - d.textWidth(t)) // 2, "loading message x")
            end
        end
        T.eq(found, 1, "one loading message drawn")
        -- The WiFi wait message is centered too.
        local app2, F2 = boot()
        F2.netStatus = 0
        F2.holding = true
        go(app2, F2, "a.test/")
        T.eq(app2.screenName, "loading")
        for i, t in ipairs(F2.texts) do
            if t == "Connecting to WiFi..." then
                T.eq(F2.textXs[i], (320 - F2.pc.display.textWidth(t)) // 2, "wifi message x")
            end
        end
    end,
```

**Step 2: Run the test to verify it fails**

Run: `cd /home/keith/Projects/PicoDeck/picosurf && make test-host 2>&1 | grep -A2 "the_loading_text_is_centered"`
Expected: FAIL — the current x is `th.margin` (4), but the truncated 52-char message's centered x happens to also be 4… so the FIRST assertion may pass by coincidence; the `Connecting to WiFi...` assertion fails (drawn at x=4, centered x is (320 − 25×6)/2 = 85). Confirm the failure is on the wifi message.

**Step 3: Implement centered drawing**

In `src/screens/loading.lua`, replace the tail of `S.draw` — these two lines:

```lua
    d.drawText(th.margin, 150, msg:sub(1, theme.uiCols(th)), th.fg, false)
    d.drawText(th.margin, 166, sub, th.dim, false)
```

with:

```lua
    -- Centered under the spinner (design 2026-10-20).
    msg = msg:sub(1, theme.uiCols(th))
    d.drawText((320 - d.textWidth(msg)) // 2, 140, msg, th.fg, false)
    d.drawText((320 - d.textWidth(sub)) // 2, 156, sub, th.dim, false)
```

Note `sub` is drawn even when empty — `textWidth("")` is 0, so it lands at x=160 and draws nothing; harmless, and keeps the code branch-free.

**Step 4: Run the full suite to verify it passes**

Run: `cd /home/keith/Projects/PicoDeck/picosurf && make test`
Expected: PASS under both the system Lua and `lua32`.

**Step 5: Commit (in the picosurf repo)**

```bash
cd /home/keith/Projects/PicoDeck/picosurf
git add src/screens/loading.lua tests/test_app.lua
git commit -m "loading: center the message and byte counter under the spinner"
```

---

### Task 3: SDK doc note (picodeck)

**Files:**
- Modify: `/home/keith/Projects/PicoDeck/picodeck/docs/API-UI.md:289-290`

**Step 1: Update the one-line description**

Change:

```markdown
#### `picocalc.ui.drawSpinner(cx, cy, [radius], [frame])`
Draw an animated loading spinner.
```

to:

```markdown
#### `picocalc.ui.drawSpinner(cx, cy, [radius], [frame])`
Draw an animated loading spinner — a 2×2 pixel block chasing itself around the
corners of a small glyph, with a dim trail pixel. `radius` sets the glyph's scale.
```

**Step 2: Commit (in the picodeck repo)**

```bash
cd /home/keith/Projects/PicoDeck/picodeck
git add docs/API-UI.md
git commit -m "docs: describe the glyph spinner in drawSpinner"
```

---

### Task 4: Visual verification on the simulator

**Step 1: Run picosurf on the simulator and eyeball one load**

Run the simulator with picosurf installed (see picodeck `make simulator-run` / picosurf README for the exact invocation), open any URL, and confirm against the approved mock-up `/tmp/opencode/spinner_mockups/C-pixel-glyph-centered.gif`:

- glyph block rotates through the four corners at ~150 ms per step
- dim trail pixel follows one corner behind
- "Loading <host>" and the KB counter are centered below the glyph

**Step 2: Spot-check the other SDK callers**

In the simulator, open the store app and the updater long enough to see their spinners (r=12 → 25 px glyph): the glyph should be intact, not clipped, and centered where the old spinner was.
