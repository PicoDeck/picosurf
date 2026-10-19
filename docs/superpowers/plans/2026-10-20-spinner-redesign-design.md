# Spinner Redesign — Pixel Glyph + Centered Loading Text

Date: 2026-10-20
Status: Approved (mock-ups reviewed)

## Summary

Replace the SDK's rotating-line spinner with a retro pixel-glyph animation
(a 2×2 block chasing itself around the corners of a 5×5 glyph, with a dim
trailing pixel), and center the loading message and byte counter beneath the
spinner on picosurf's loading screen.

## Motivation

The current `picocalc.ui.drawSpinner` draws a white diameter line rotating
through 8 orientations plus a gray trail line (`picodeck/src/os/ui.c`,
`ui_draw_spinner`). It reads as generic and its motion is hard to perceive at
the app's 150 ms frame cadence. The pixel-glyph design has more personality,
is cheaper to render (no floating point), and its motion is unambiguous even
at coarse frame steps.

## Design

### SDK spinner (`picodeck/src/os/ui.c` — `ui_draw_spinner`)

- Keep the signature `ui_draw_spinner(int cx, int cy, int r, int frame)`
  unchanged. All callers (`picosurf`, `apps/store`, `apps/updater`,
  `system/lib/widgets.lua`) keep working without modification. `r` is ignored
  beyond selecting the glyph's pixel scale (see below).
- The glyph is a 5×5 bitmap. Each animation frame draws a bright (white) 2×2
  block in one corner — top-left → top-right → bottom-right → bottom-left —
  advancing one corner per frame, plus a single dim-gray pixel at the corner
  just vacated (motion trail). Four frames, looping.
- Pixel scale derives from `r`: `px = max(2, (2*r + 4) / 5)` so the glyph
  roughly fills the old 2r bounding box (r=10 → 4 px cells → 20×20 glyph;
  r=8 → 4 px; small r → 2 px minimum).
- Rendering: `display_fill_rect` per set pixel (10 fill_rect calls per frame
  worst case). No lines, no trig, no static state — fully determined by
  `frame`, like the current implementation.
- Frame cadence is the caller's responsibility, as today (picosurf advances
  `frame` every 150 ms).

### Loading screen layout (`picosurf/src/screens/loading.lua`)

- Spinner stays centered at (160, 120).
- `msg` ("Loading <host>" / "Connecting to WiFi..." / "Waiting for time
  sync...") is drawn horizontally centered at y = 140.
- `sub` (byte counter, e.g. "12 KB") is drawn horizontally centered at
  y = 156, in the theme's dim colour.
- Centering uses `app.disp.textWidth(s)`: `x = (320 - w) // 2`. The system
  font (6×8) is active for these draws, so measurement is exact.
- Long hosts: keep the existing `msg:sub(1, theme.uiCols(th))` truncation
  before measuring so text never wraps or clips the screen edges.
- Header ("PicoSurf") and footer ("Esc cancel") are unchanged.

### Mock-up reference

Approved previews live in `/tmp/opencode/spinner_mockups/` (regenerate with
`render_spinners.py` in the same directory):

- `C-pixel-glyph-centered.gif` — animated, full-screen context
- `C-pixel-glyph-centered-strip.png` — 8-frame zoomed strip
- `C-pixel-glyph-centered-screen.png` — full-screen still

Rejected alternatives (rendered and reviewed): A — comet dots (8 filled
circles with brightness-decay trail); B — arc sweep on a dim track ring.

## Testing

- SDK side: the firmware has no unit-test harness for `ui.c`; verification is
  visual — run picosurf on device/simulator and confirm the glyph animates,
  plus spot-check `apps/store` and `apps/updater` spinners (they pass r=12)
  for sensible scaling.
- picosurf side: `tests/` drives screens through `fakepc.lua`. Add/adjust a
  test that enters the loading screen and asserts `drawText` is called with
  centered x positions for `msg`/`sub` (fake `textWidth` = 6 × #text).
  `fakepc.lua`'s `ui.drawSpinner` stub needs no change (signature unchanged).

## Out of scope

- Changing the drawSpinner API or adding style/label parameters.
- Updating SDK docs (`docs/API-UI.md`) beyond noting the new visual; the
  documented signature and semantics are unchanged.
- The other two mock-up designs (A, B).
