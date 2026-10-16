# PicoSurf Inline Images Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Settings option, Images: Links / Inline. With Inline, a page's pictures load as you read and appear in place of their `[IMG]` lines, inside boxes of up to 10 rows.

**Architecture:**
- **Proxy:** a `fit=WxH` parameter, so a picture comes back sized for its box.
- **App:**
  - A new pure module, `src/inline.lua`, holds the per-page picture state and decides what to fetch, decode and drop.
  - `layout` gains box rows, built from scratch or spliced in place.
  - `pagestate` gains `shift`, which keeps the view still when rows change above it.
  - `App:stepImages()`, run each step on the page screen, makes one request at a time and decodes one picture per step.

**Tech Stack:**
- App: Lua 5.4 on PicoDeck. Host tests run under stock Lua and `lua32`.
- Proxy: TypeScript (Cloudflare Workers / Node), vitest.
- Simulator e2e: pytest.

**Spec:**
- `docs/superpowers/specs/2026-10-16-picosurf-inline-images-design.md` (the authority for this plan).
- It amends `docs/superpowers/specs/2026-10-15-picosurf-design.md` (the main spec).

## Global Constraints

- **Box size:** pictures fit 312×126; the app sends `fit=312x126`.
  - A box is `ceil((h + 4) / 13)` rows, at most 10.
  - The picture sits 2 px below the top of its band, centred across 320 px.
- **Window:** the screen plus one screen above and one below.
  - Loading order: on screen top to bottom, then below nearest first, then above nearest first.
- **Pacing:** one image request at a time, and at most one decode per step.
- **Byte cap:** compressed bytes are capped at 512 KB per page (`inline.BYTES_CAP`). The least recently used are dropped; the newest is always kept.
- **`fit` parameter:**
  - Must match `^\d{1,3}x\d{1,3}$`, with each side from 1 to 320. Anything else gets `400 Bad fit parameter`.
  - Responses other than images ignore it.
  - Without it the box is 320×320.
- **Config:** key `images`, either `"links"` (the default, and anything other than `"inline"`) or `"inline"`.
  - Settings shows `Images: Links` or `Images: Inline`, placed between Font and Test connection.
- **Old proxy:** the toast reads exactly `Inline images need a newer proxy` and is shown once per app run.
- **Links mode:** no change in behaviour and no extra requests.
- **Failures:** a picture that fails stays an `[IMG]` link line and isn't fetched again until Reload.
- **Tests:**
  - App: `make test` (stock Lua and `lua32`).
  - Proxy: `cd proxy && npm test && npm run typecheck`.
  - Simulator: `make e2e`.
- **Dependencies:** none new, in the app or the proxy.
- **Commits:** follow the repo's style (`feat:`, `fix:`, `test:`, `docs:`, with `(proxy)` for proxy work). Add no attribution lines.
- **Deploying:** don't deploy the proxy or push to the device as part of this plan. Both are outward steps the user approves separately (see "After the plan").

## Review Focus

1. **The same picture linked twice on one page** (a repeated logo or icon): one request and one decoded picture, and both boxes grow. Test: Task 5, `the_same_picture_twice_is_fetched_once`.
2. **A long gallery (40 pictures) scrolled to the end:** every picture loads on the way, and the decoded pictures held stay within the window. Test: Task 5, `a_gallery_keeps_few_pictures_decoded`.
3. **The selected link is a picture that grows past the bottom of the screen:** it stays selected and the view doesn't move. Test: Task 3, `shift_keeps_a_growing_selected_picture_selected`.
4. **Back to a cached page while a picture is in flight:** the old page's request is cancelled and nothing lands on the new page. Test: Task 5, `leaving_for_a_cached_page_cancels_the_picture`.
5. **Inline switched off on a page with pictures:** the page is laid out again with link lines, the same line stays at the top, and no more image requests are made. Test: Task 7, `images_setting_switches_and_applies_to_the_page`.

---

### Task 1: Proxy resizers fit a box

**Files:**
- Modify: `proxy/src/img.ts`, `proxy/src/img-sharp.ts`, `proxy/src/img-wasm.ts`, `proxy/src/png-stream.ts`
- Test: `proxy/test/img.test.ts`, `proxy/test/png-stream.test.ts`, `proxy/test/helpers/resizer-contract.ts`

**Interfaces:**
- Produces:
  - `DEFAULT_BOX: Size` (`{ width: 320, height: 320 }`), exported from `src/img.ts`.
  - `fitWithin(width, height, box: Size = DEFAULT_BOX): Size`.
  - `Resizer.resize(bytes, type, box?: Size)`: implementations default `box` to `DEFAULT_BOX`.
  - `streamPng(bytes, box: Size = DEFAULT_BOX)`.

- [ ] **Step 1: Write the failing tests**

In `proxy/test/img.test.ts`, inside `describe("fitWithin", ...)`, after the existing `it.each`:

```ts
  it.each([
    [800, 600, 168, 126], [600, 800, 95, 126], [200, 100, 200, 100], [1000, 100, 312, 31], [312, 126, 312, 126],
  ])("%dx%d within 312x126 → %dx%d", (w, h, ew, eh) =>
    expect(fitWithin(w, h, { width: 312, height: 126 })).toEqual({ width: ew, height: eh }));
```

In `proxy/test/png-stream.test.ts`, inside `describe("streamPng", ...)`, add:

```ts
  it("fits a non-square box, never enlarging", async () => {
    const wide = encodePng(raw(400, 100, 2));
    expect(await streamPng(wide, { width: 100, height: 50 })).toMatchObject({ width: 100, height: 25 });
    expect(await streamPng(wide, { width: 300, height: 30 })).toMatchObject({ width: 120, height: 30 });
    expect(await streamPng(wide)).toMatchObject({ width: 320, height: 80 });
    expect(await streamPng(encodePng(raw(40, 20, 2)), { width: 312, height: 126 })).toMatchObject({ width: 40, height: 20 });
  });
```

In `proxy/test/helpers/resizer-contract.ts`:
- Below `CASES`, add:

```ts
/** The box PicoSurf asks for inline pictures (fit=312x126). */
const BOX = { width: 312, height: 126 };
const BOX_CASES: [string, ImageType, number, number][] = [
  ["photo.jpg", "jpeg", 168, 126],
  ["photo-progressive.jpg", "jpeg", 168, 126],
  ["photo.png", "png", 168, 126],
  ["photo.webp", "webp", 168, 126],
  ["photo.gif", "gif", 168, 126],
  ["small.png", "png", 200, 100],
];
```

- Inside the `describe` in `resizerContract`, after the `"%s (%s) → baseline JPEG %dx%d"` test, add the test below. It also records how large box-sized JPEGs are, as evidence for the app's 512 KB byte cap.

```ts
    it.each(BOX_CASES)("%s (%s) in a 312x126 box → baseline JPEG %dx%d, under 32 KB", async (file, type, width, height) => {
      const out = await resizer.resize(imageFixture(file), type, BOX);
      const info = jpegInfo(out);
      expect(info?.sof).toBe(0xc0);
      expect(info?.size).toEqual({ width, height });
      expect(out.length).toBeLessThan(32 * 1024); // the app keeps 512 KB of these per page
    });
```

- Update the doc comment to: `/** Every Resizer must pass these: baseline JPEG, within 320x320 or the box given, never enlarged, transparency on white. */`

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd proxy && npx vitest run test/img.test.ts test/png-stream.test.ts test/img-wasm.test.ts`
Expected: FAIL.
- The new `fitWithin` cases come out `NaN` sizes.
- `streamPng` with a box gives 320-wide output.
- The box contract cases give 320×240.

- [ ] **Step 3: Implement**

`proxy/src/img.ts`: replace everything from `export const MAX_SIDE` to the end with:

```ts
export const MAX_SIDE = 320;
/** What an image fits within when the app asks for no other box (spec 5.8). */
export const DEFAULT_BOX: Size = { width: MAX_SIDE, height: MAX_SIDE };
/** The sharp resizer's cap (Node/Docker). The WASM resizer has its own, per format (img-wasm.ts). */
export const MAX_PIXELS = 16_000_000;
export const JPEG_QUALITY = 75;

/** Turns an image into a baseline JPEG within a box, by default 320x320 (spec 5.8). */
export interface Resizer {
  /**
   * The most pixels this resizer takes for this image, which may depend on its
   * format and header. Larger images are refused with 413 before decoding.
   */
  maxPixels(bytes: Uint8Array, type: ImageType): number;
  resize(bytes: Uint8Array, type: ImageType, box?: Size): Promise<Uint8Array>;
}

/** Scales down to fit `box`, keeping the aspect ratio; never enlarges. */
export function fitWithin(width: number, height: number, box: Size = DEFAULT_BOX): Size {
  const scale = Math.min(1, box.width / width, box.height / height);
  return { width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale)) };
}
```

`proxy/src/img-sharp.ts`:
- Import `DEFAULT_BOX` instead of `MAX_SIDE`: `import { DEFAULT_BOX, JPEG_QUALITY, MAX_PIXELS, type Resizer } from "./img";`
- Change the method:

```ts
    async resize(bytes, _type, box = DEFAULT_BOX) {
      const out = await sharp(bytes, { limitInputPixels: MAX_PIXELS, animated: false })
        .rotate() // apply EXIF orientation
        .flatten({ background: "#ffffff" })
        .resize(box.width, box.height, { fit: "inside", withoutEnlargement: true })
        .jpeg({ quality: JPEG_QUALITY, progressive: false, mozjpeg: false })
        .toBuffer();
      return new Uint8Array(out.buffer, out.byteOffset, out.byteLength);
    },
```

`proxy/src/png-stream.ts`:
- Replace `import { MAX_SIDE, fitWithin } from "./img";` with:

```ts
import { DEFAULT_BOX, fitWithin } from "./img";
import type { Size } from "./imgsize";
```

  (If `png-stream.ts` already imports from `./imgsize`, add `type Size` to that import instead.)
- Change `streamPng`'s doc comment and signature:

```ts
/**
 * Decodes a PNG that `canStreamPng` takes and scales it to fit `box`
 * (composited over white, as BoxScaler does). Throws on anything malformed:
 * truncation, a bad CRC on a critical chunk, corrupt image data, too few rows.
 */
export async function streamPng(bytes: Uint8Array, box: Size = DEFAULT_BOX): Promise<Rgba> {
  const png = parse(bytes);
  const scaler = new BoxScaler(png.width, png.height, fitWithin(png.width, png.height, box));
```

  The rest of the function is unchanged.

`proxy/src/img-wasm.ts`:
- Import: `import { DEFAULT_BOX, JPEG_QUALITY, type Resizer, fitWithin } from "./img";`
- Encoder comment: `// Made on first use; the encoder only ever sees images within 320x320.`
- In `createWasmResizer`'s returned object:

```ts
    async resize(bytes, type, box = DEFAULT_BOX) {
      if (type === "jpeg") refuseJpeg(bytes);
      return jobs.run(async () => {
        const scaled = await decodeScaled(bytes, type, decoders, box);
```

  The rest of `resize` is unchanged.
- Replace `pending`'s declaration and doc:

```ts
/** What the current HeapDecoder.decode() expects, the box to fit, and what its PixelSink made of the pixels. */
let pending: { size: Size; box: Size; scaled: Rgba | null } | null = null;
```

- In `PixelSink`: `p.scaled = boxScale(view, p.size.width, p.size.height, fitWithin(p.size.width, p.size.height, p.box));`
- `HeapDecoder.decode`:
  - Doc becomes `/** Decodes an image whose header gave `size`, scaled to fit `box`. */`
  - Signature becomes `async decode(bytes: Uint8Array, size: Size, box: Size = DEFAULT_BOX): Promise<Rgba> {`
  - `const wanted = { size, box, scaled: null as Rgba | null };`
  - The last line becomes `return boxScale(image.data, image.width, image.height, fitWithin(image.width, image.height, box));`
- Replace `decodeScaled`:

```ts
/** Decodes and scales to fit `box`: PNGs stream, JPEG and WebP scale in their decoder, GIFs decode whole first. */
async function decodeScaled(bytes: Uint8Array, type: ImageType, decoders: Decoders, box: Size): Promise<Rgba> {
  if (type === "png") return streamPng(bytes, box);
  if (type === "gif") {
    const image = decodeGif(bytes);
    return boxScale(image.data, image.width, image.height, fitWithin(image.width, image.height, box));
  }
  const size = imageSize(bytes, type);
  if (!size) throw new Error("Could not read the image size");
  return decoders[type].decode(bytes, size, box);
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd proxy && npx vitest run test/img.test.ts test/png-stream.test.ts test/img-wasm.test.ts && npm test && npm run typecheck`
Expected: all pass (previously 642 tests, plus the new ones), and typecheck is clean.

- [ ] **Step 5: Commit**

```bash
git add proxy/src/img.ts proxy/src/img-sharp.ts proxy/src/img-wasm.ts proxy/src/png-stream.ts proxy/test/img.test.ts proxy/test/png-stream.test.ts proxy/test/helpers/resizer-contract.ts
git commit -m "feat(proxy): resizers fit a given box (default 320x320)"
```

---

### Task 2: The proxy's `fit` parameter

**Files:**
- Modify: `proxy/src/handler.ts`, `proxy/README.md`, `docs/superpowers/specs/2026-10-15-picosurf-design.md` (sections 5.1, 5.2, 5.3, 5.8, 7.1)
- Test: `proxy/test/handler.test.ts`

**Interfaces:**
- Consumes: `DEFAULT_BOX` and `MAX_SIDE` from `src/img.ts`, and `Resizer.resize(bytes, type, box)` (Task 1).
- Produces: `parseFit(value: string | null): Size`, exported from `src/handler.ts`. `GET /v1/get?...&fit=WxH`.

- [ ] **Step 1: Write the failing tests**

In `proxy/test/handler.test.ts`, inside `describe("images", ...)`, add:

```ts
  const png = () => ({ "https://example.com/a.png": new Response(imageFixture("photo.png"), { headers: { "Content-Type": "image/png" } }) });
  const withFit = (fit: string) => `/v1/get?url=${encodeURIComponent("https://example.com/a.png")}&fit=${encodeURIComponent(fit)}`;

  it("scales into the fit box, and into 320x320 without one", async () => {
    const d = deps(png());
    expect((await call(withFit("312x126"), d.deps)).status).toBe(200);
    expect(d.resizer.resize).toHaveBeenLastCalledWith(imageFixture("photo.png"), "png", { width: 312, height: 126 });
    const d2 = deps(png());
    await get("https://example.com/a.png", d2.deps);
    expect(d2.resizer.resize).toHaveBeenLastCalledWith(imageFixture("photo.png"), "png", { width: 320, height: 320 });
  });

  it.each(["1x1", "320x320", "010x9"])("takes fit=%s", async (fit) => {
    expect((await call(withFit(fit), deps(png()).deps)).status).toBe(200);
  });

  it.each(["0x10", "321x10", "10x321", "10", "10x", "x10", "1e2x10", "abc", "10x10x10", " 10x10", "1000x10", ""])(
    "400s fit=%j before fetching anything",
    async (fit) => {
      const d = deps(png());
      const res = await call(withFit(fit), d.deps);
      expect(res.status).toBe(400);
      expect(await res.text()).toBe("Bad fit parameter\n");
      expect(d.fetch.calls).toHaveLength(0);
    },
  );

  it("ignores fit for pages", async () => {
    const d = deps({ "https://example.com/": html(articleHtml()) });
    const res = await call(`/v1/get?url=${encodeURIComponent("https://example.com/")}&fit=10x10`, d.deps);
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toContain("text/gemini");
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd proxy && npx vitest run test/handler.test.ts`
Expected: FAIL.
- `resize` was called with 2 arguments.
- The bad `fit` values get 200 instead of 400.

- [ ] **Step 3: Implement**

`proxy/src/handler.ts`:
- Imports:

```ts
import { DEFAULT_BOX, MAX_SIDE, type Resizer } from "./img";
import { type Size, imageSize } from "./imgsize";
```

  These replace the existing `import type { Resizer } from "./img";` and `import { imageSize } from "./imgsize";`.
- Add after `handleRequest`:

```ts
/** `fit=WxH`: the box an image is scaled into, each side 1-320 (spec 5.1). Without it, 320x320. */
export function parseFit(value: string | null): Size {
  if (value === null) return DEFAULT_BOX;
  const m = /^(\d{1,3})x(\d{1,3})$/.exec(value);
  const width = m ? Number(m[1]) : 0;
  const height = m ? Number(m[2]) : 0;
  if (width < 1 || width > MAX_SIDE || height < 1 || height > MAX_SIDE) throw new ProxyError(400, "Bad fit parameter");
  return { width, height };
}
```

- In `route`, right after the `as` check: `const box = parseFit(url.searchParams.get("fit"));`
- In the `switch`: `return imageResponse(body, mime, deps.resizer, final, box);`
- `imageResponse` takes the box and passes it on:

```ts
async function imageResponse(bytes: Uint8Array, mime: string, resizer: Resizer, headers: Record<string, string>, box: Size): Promise<Response> {
```

  and inside it: `jpeg = await resizer.resize(bytes, type, box);`

`proxy/README.md`:
- In the API code block, change the second line to:

```
GET /v1/get?url=<absolute URL>[&as=reader|full|feed][&fit=<W>x<H>]
```

- After the paragraph that starts `Response headers:`, add:

```
`fit` scales an image to fit within W×H pixels instead of 320×320. W and H are whole numbers from 1 to 320; anything else gets 400 `Bad fit parameter`. Pages, feeds and text ignore it. PicoSurf's inline pictures (Settings → Images: Inline) ask for `fit=312x126`, so they need a proxy from this version on: redeploy it when you update the app.
```

Main spec `docs/superpowers/specs/2026-10-15-picosurf-design.md`:
- **5.1:** in the code block, change `GET /v1/get?url=<absolute URL>[&as=reader|full|feed]` to `GET /v1/get?url=<absolute URL>[&as=reader|full|feed][&fit=<W>x<H>]`. After the paragraph that ends `checks the URL and the token together. ... alongside the current one later.`, add:

```
`fit` (W and H each 1-320) scales an image to fit W×H instead of 320×320;
pages, feeds and text ignore it. The app asks for `fit=312x126` for inline
pictures (`2026-10-16-picosurf-inline-images-design.md`).
```

- **5.2:** in the table row for images, change `fit within 320×320 (5.8)` to `fit within 320×320, or the \`fit\` box (5.1, 5.8)`.
- **5.3:** change the 400 row to `| 400 | missing or malformed \`url\`, a scheme other than http/https, or a malformed \`fit\` (\`Bad fit parameter\`) |`.
- **5.8:** change `Output fits within 320×320, keeps the aspect ratio, is never enlarged, and is` to `Output fits within 320×320 (or the \`fit\` box, 5.1), keeps the aspect ratio, is never enlarged, and is`.
- **7.1:** change the `handler` bullet's end from `each\n  error status in 5.3.` to `each\n  error status in 5.3, \`fit\` parsing.` Change the `img` bullet to `- \`img\`: each input format gives a baseline JPEG within 320×320, or within a \`fit\` box; over the resizer's pixel cap gives 413.`

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd proxy && npx vitest run test/handler.test.ts && npm test && npm run typecheck`
Expected: all pass; typecheck is clean.

- [ ] **Step 5: Commit**

```bash
git add proxy/src/handler.ts proxy/test/handler.test.ts proxy/README.md docs/superpowers/specs/2026-10-15-picosurf-design.md
git commit -m "feat(proxy): fit=WxH scales an image into the box the app asks for"
```

---

### Task 3: Box rows in the layout, and a view that stays put

**Files:**
- Modify: `src/layout.lua`, `src/pagestate.lua`
- Test: `tests/test_layout.lua`, `tests/test_pagestate.lua`

**Interfaces:**
- Produces:
  - `layout.BOX = 13`, a row style.
  - `layout.build(lines, cols, boxes)`: `boxes` is optional, `{[k] = rows}`. Image link `k` is laid out as `rows` BOX rows (line = the link's source line, `s = 1`, `e = 0`, `link = k`, `cont = false`). Entries for links that aren't images are ignored.
  - `layout.setBox(L, k, rows) -> delta`: does the same to an existing layout in place. Later rows move, later links' `first`/`last` shift, and `L.count` changes by `delta`. Link `k`'s `first` doesn't change.
  - `ps:shift(row, delta)`: if `row < ps.top`, then `ps.top = ps.top + delta`. It then clamps to `1..maxTop()` and keeps a link selected as scrolling does.

- [ ] **Step 1: Write the failing tests**

In `tests/test_layout.lua`, add above `return {`:

```lua
-- 10 columns: "intro words" (rows 1-2), a picture whose label "[IMG] A cat
-- photo" wraps (rows 3-4), "after text here" (rows 5-6), link [1] (row 7).
local IMGPAGE = "intro words\n=> https://a.test/c.jpg [IMG] A cat photo\nafter text here\n=> https://a.test/d [1] dee\n"

-- Every row's fields and every link's rows, as one string.
local function snapshot(L)
    local out = {}
    for r = 1, L.count do
        out[r] = table.concat({ L.line[r], L.s[r], L.e[r], L.style[r], L.link[r], tostring(L.cont[r]) }, ",")
    end
    local links = {}
    for k, l in ipairs(L.links) do links[k] = l.first .. "-" .. l.last end
    return L.count .. ": " .. table.concat(out, "|") .. " / " .. table.concat(links, " ")
end
```

and these entries to the returned table:

```lua
    boxes_replace_a_picture_label_with_box_rows = function()
        local lines = g.parse(IMGPAGE)
        local L = layout.build(lines, 10, { [1] = 4 })
        local link = L.links[1]
        T.eq(link.first, 3); T.eq(link.last, 6)
        for r = 3, 6 do
            T.eq(L.style[r], layout.BOX); T.eq(L.link[r], 1); T.eq(L.line[r], 2); T.eq(layout.rowText(L, r), "")
        end
        T.eq(L.links[2].first, 9, "the text after it follows")
        T.eq(L.count, 9)
    end,
    boxes_ignore_links_that_are_not_pictures = function()
        local lines = g.parse(IMGPAGE)
        T.eq(snapshot(layout.build(lines, 10, { [2] = 5 })), snapshot(layout.build(lines, 10)))
    end,
    set_box_matches_build_with_the_same_boxes = function()
        -- Pictures at the start (link 1), in the middle with a wrapped label
        -- (link 2) and at the end (link 4); link 3 is not a picture.
        local text = "=> https://a.test/0.jpg [IMG] first\n" .. IMGPAGE
            .. "=> https://a.test/z.jpg [IMG] the last picture on the page\n"
        local lines = g.parse(text)
        for _, case in ipairs({ { 1, 3 }, { 2, 1 }, { 2, 5 }, { 4, 2 }, { 4, 10 } }) do
            local k, rows = case[1], case[2]
            local L = layout.build(lines, 10)
            local before = L.count
            local delta = layout.setBox(L, k, rows)
            local want = layout.build(lines, 10, { [k] = rows })
            T.eq(snapshot(L), snapshot(want), "link " .. k .. " as " .. rows .. " rows")
            T.eq(delta, want.count - before, "delta for link " .. k)
            T.eq(L.line[L.count + 1], nil, "nothing left past the end")
        end
        -- Two boxes, then the first resized again.
        local L = layout.build(lines, 10)
        layout.setBox(L, 2, 6); layout.setBox(L, 4, 3); layout.setBox(L, 2, 2)
        T.eq(snapshot(L), snapshot(layout.build(lines, 10, { [2] = 2, [4] = 3 })))
    end,
```

In `tests/test_pagestate.lua`, add above `return {`:

```lua
-- 40 lines: pictures on rows 3, 14 and 38 (links 1, 2, 5), links on rows 20 and 25 (3, 4).
local function pictures()
    local parts = {}
    for i = 1, 40 do parts[i] = "line " .. i end
    parts[3] = "=> https://a.test/p.jpg [IMG] picture"
    parts[14] = "=> https://a.test/q.jpg [IMG] picture"
    parts[20] = "=> https://a.test/1 one"
    parts[25] = "=> https://a.test/2 two"
    parts[38] = "=> https://a.test/r.jpg [IMG] picture"
    local L = layout.build(g.parse(table.concat(parts, "\n")), 40)
    return pagestate.new(L, 10), L
end
```

and these entries to the returned table:

```lua
    shift_keeps_the_view_when_rows_change_above_it = function()
        local ps, L = pictures()
        ps:scroll(14)
        T.eq(ps.top, 15); T.eq(ps.sel, 3)
        ps:shift(L.links[1].first, layout.setBox(L, 1, 6))
        T.eq(ps.top, 20); T.eq(L.line[ps.top], 15, "the same line is at the top")
        T.eq(ps.sel, 3)
    end,
    shift_on_or_below_the_top_leaves_the_view = function()
        local ps, L = pictures()
        ps:shift(L.links[1].first, layout.setBox(L, 1, 6))
        T.eq(ps.top, 1); T.eq(ps.sel, 1)
    end,
    shift_keeps_a_growing_selected_picture_selected = function() -- Review Focus 3
        local ps, L = pictures()
        T.eq(ps.sel, 1)
        ps:shift(L.links[1].first, layout.setBox(L, 1, 10)) -- rows 3-12, past the bottom (row 10)
        T.eq(ps.top, 1, "the view doesn't move"); T.eq(ps.sel, 1, "still selected")
    end,
    shift_reselects_when_the_selection_is_pushed_off = function()
        local ps, L = pictures()
        ps:scroll(11)
        ps:nextLink(1)
        T.eq(ps.top, 12); T.eq(ps.sel, 3)
        ps:shift(L.links[2].first, layout.setBox(L, 2, 10)) -- link 3 moves to row 29
        T.eq(ps.top, 12); T.eq(ps.sel, 2, "the topmost visible link, as after scrolling")
    end,
    shift_clamps_the_view_to_the_new_end = function()
        local ps, L = pictures()
        ps:shift(L.links[5].first, layout.setBox(L, 5, 5)) -- 44 rows
        ps:scroll(100)
        T.eq(ps.top, 35); T.eq(ps.sel, 5)
        ps:shift(L.links[5].first, layout.setBox(L, 5, 1)) -- 40 rows again
        T.eq(ps.top, 31, "clamped to the new last screen"); T.eq(ps.sel, 5)
    end,
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `lua tests/run.lua tests/test_layout.lua tests/test_pagestate.lua`
Expected: FAIL.
- `boxes_replace...` gets `link.last` 4 instead of 6, since `boxes` is ignored.
- The other new tests fail on `attempt to call a nil value (field 'setBox')` or `(method 'shift')`.

- [ ] **Step 3: Implement**

`src/layout.lua`:
- Change the style line to:

```lua
M.QUOTE, M.PRE, M.LINK, M.IMAGE, M.BLANK, M.READ, M.BOX = 7, 8, 9, 10, 11, 12, 13
```

- Replace `function M.build(lines, cols)` and its body up to its `return L` / `end` with the code below. Only the box branch is new.

```lua
-- boxes: optional {[k] = rows}. Image link k is laid out as that many BOX rows
-- (an inline picture's box, inline images spec 5.4) instead of its label.
function M.build(lines, cols, boxes)
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
            local box = boxes and ln.image and boxes[link]
            if box then
                for _ = 1, box do add(li, 1, 0, M.BOX, link, false) end
            else
                local s, e = wrap.wrap(ln.text, width)
                for k = 1, #s do
                    add(li, s[k], e[k], (style == M.ITEM and k > 1) and M.ITEMC or style, link, false)
                end
            end
            if link > 0 then L.links[link].last = L.count end
        end
    end
    return L
end

local ROW_FIELDS = { "line", "s", "e", "style", "link", "cont" }

-- Lays link k out as `rows` BOX rows in place, as build would with
-- boxes[k] = rows: the rows after it move, later links' rows shift and the
-- count changes. Returns that change (negative when the box shrank).
function M.setBox(L, k, rows)
    local link = L.links[k]
    local first, last, count = link.first, link.last, L.count
    local delta = rows - (last - first + 1)
    if delta ~= 0 then
        for _, f in ipairs(ROW_FIELDS) do
            local a = L[f]
            table.move(a, last + 1, count, last + 1 + delta)
            for r = count + delta + 1, count do a[r] = nil end -- only when it shrank
        end
        L.count = count + delta
        for j = k + 1, #L.links do
            local o = L.links[j]
            o.first, o.last = o.first + delta, o.last + delta
        end
        link.last = last + delta
    end
    local li = L.line[first]
    for r = first, link.last do
        L.line[r], L.s[r], L.e[r], L.style[r], L.link[r], L.cont[r] = li, 1, 0, M.BOX, k, false
    end
    return delta
end
```

`src/pagestate.lua`: add after `function M:page(dir) ... end`:

```lua
-- After `delta` rows were added (removed, when negative) at `row`, an inline
-- picture's box growing say: when they were above the screen, the view moves
-- by as many rows, so the rows on screen stay the same (inline images spec
-- 5.4). Then a link is kept selected, as when scrolling.
function M:shift(row, delta)
    if row < self.top then self.top = self.top + delta end
    self.top = math.max(1, math.min(self:maxTop(), self.top))
    keepSelectionVisible(self)
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `lua tests/run.lua tests/test_layout.lua tests/test_pagestate.lua && make test`
Expected: all pass under both Luas.

- [ ] **Step 5: Commit**

```bash
git add src/layout.lua src/pagestate.lua tests/test_layout.lua tests/test_pagestate.lua
git commit -m "feat: box rows for inline pictures, and a view that stays put when rows change above it"
```

---

### Task 4: Inline picture state and policy (`src/inline.lua`)

**Files:**
- Create: `src/inline.lua`
- Test: `tests/test_inline.lua`

**Interfaces:**
- Consumes: `layout.build` and the link fields `first`, `last`, `url` and `image`. `ps.top`, `ps.visible` and `ps:lastVisible()`. `url.scheme`.
- Produces:
  - **Constants:** `inline.ROWS = 10`, `inline.ROW_H = 13`, `inline.PAD = 2`, `inline.FIT_W = 312`, `inline.FIT_H = 126`, `inline.FIT = "312x126"`, `inline.BYTES_CAP = 524288`, `inline.RETRY_MS = 3000`.
  - `inline.new(boxes)` returns a state: `{boxes, byUrl, lru, bytesTotal, wake = true, inflight = nil, retryAt = nil, seenTop = nil}`.
  - `inline.rows(h)`: `ceil((h + 4) / 13)`.
  - `inline.order(L, ps)` returns a list of link indices.
  - Methods that take that list (computed once per pass, rather than `(L, ps)` as in spec 5.1, so the window is walked once):
    - `st:nextFetch(L, order)` returns `k, url` or nil.
    - `st:nextDecode(L, order)` returns `k` or nil.
    - `st:drops(L, order)` returns sorted URLs.
  - `st:drop(u)`, `st:keepBytes(u, bytes)`, `st:touch(u)`, `st:fail(u)`.
  - **Entries:** `byUrl[u] = {state = "loading"|"ready"|"failed", bytes, img, w, h}`.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_inline.lua`:

```lua
local T = require("tests.t")
local inline = require("src.inline")
local layout = require("src.layout")
local pagestate = require("src.pagestate")
local g = require("src.gemtext")

-- 70 lines at 40 columns, 10 rows on screen, scrolled to rows 30-39, so the
-- window is rows 20-49. Pictures on rows 15, 22, 26, 31, 41, 48 and 55 (links
-- 1, 2, 3, 4, 7, 8, 9), a plain link on row 33 (5), and a gemini picture on
-- row 37 (6).
local function page()
    local parts = {}
    for i = 1, 70 do parts[i] = "line " .. i end
    for _, i in ipairs({ 15, 22, 26, 31, 41, 48, 55 }) do
        parts[i] = "=> https://img.test/" .. i .. ".jpg [IMG] p" .. i
    end
    parts[33] = "=> https://a.test/x a link"
    parts[37] = "=> gemini://g.test/37.jpg [IMG] elsewhere"
    local L = layout.build(g.parse(table.concat(parts, "\n")), 40)
    local ps = pagestate.new(L, 10)
    ps:scroll(29)
    return L, ps
end

local function u(row) return "https://img.test/" .. row .. ".jpg" end

return {
    a_box_fits_its_picture_and_its_padding = function()
        T.eq(inline.FIT, "312x126")
        T.eq(inline.rows(126), 10); T.eq(inline.rows(100), 8); T.eq(inline.rows(50), 5)
        T.eq(inline.rows(9), 1); T.eq(inline.rows(10), 2); T.eq(inline.rows(1), 1)
    end,
    orders_the_window_on_screen_then_below_then_above = function()
        local L, ps = page()
        T.eq(ps.top, 30)
        T.eq(table.concat(inline.order(L, ps), ","), "4,6,7,8,3,2")
    end,
    fetches_web_pictures_without_an_entry = function()
        local L, ps = page()
        local st, order = inline.new(), inline.order(L, ps)
        local k, url = st:nextFetch(L, order)
        T.eq(k, 4); T.eq(url, u(31))
        st.byUrl[url] = { state = "loading" }
        k, url = st:nextFetch(L, order)
        T.eq(k, 7, "the gemini picture is skipped"); T.eq(url, u(41))
        st.byUrl[url] = { state = "failed" }
        T.eq(st:nextFetch(L, order), 8, "a failed picture is not fetched again")
    end,
    decodes_pictures_with_bytes_and_no_picture = function()
        local L, ps = page()
        local st, order = inline.new(), inline.order(L, ps)
        T.eq(st:nextDecode(L, order), nil)
        st.byUrl[u(41)] = { state = "ready", bytes = "x" }
        T.eq(st:nextDecode(L, order), 7)
        st.byUrl[u(41)].img = {}
        T.eq(st:nextDecode(L, order), nil)
    end,
    drops_decoded_pictures_outside_the_window = function()
        local L, ps = page()
        local st, order = inline.new(), inline.order(L, ps)
        st.byUrl[u(15)] = { state = "ready", img = {} }               -- outside, no bytes
        st.byUrl[u(55)] = { state = "ready", img = {}, bytes = "x" } -- outside, bytes kept
        st.byUrl[u(31)] = { state = "ready", img = {} }               -- inside
        local drops = st:drops(L, order)
        T.eq(table.concat(drops, " "), u(15) .. " " .. u(55))
        for _, url in ipairs(drops) do st:drop(url) end
        T.eq(st.byUrl[u(15)], nil, "nothing left: removed, so it is fetched again")
        T.eq(st.byUrl[u(55)].img, nil); T.eq(st.byUrl[u(55)].bytes, "x")
        T.ok(st.byUrl[u(31)].img)
    end,
    keeps_compressed_bytes_up_to_the_cap = function()
        local st, big = inline.new(), string.rep("x", 200 * 1024)
        for _, name in ipairs({ "a", "b", "c", "d", "e" }) do st.byUrl[name] = { state = "ready" } end
        st.byUrl.b.img = {}
        st:keepBytes("a", big); st:keepBytes("b", big)
        T.eq(st.bytesTotal, 400 * 1024)
        st:keepBytes("c", big)
        T.eq(st.byUrl.a, nil, "the oldest went, and with nothing left its entry")
        T.eq(st.bytesTotal, 400 * 1024)
        st:touch("b")
        st:keepBytes("d", big)
        T.eq(st.byUrl.c, nil, "b was used more recently than c"); T.eq(st.byUrl.b.bytes, big)
        st:keepBytes("e", big)
        T.eq(st.byUrl.b.bytes, nil); T.ok(st.byUrl.b.img, "b is decoded: its entry stays")
        st:fail("d")
        T.eq(st.byUrl.d.state, "failed"); T.eq(st.byUrl.d.bytes, nil)
        T.eq(st.bytesTotal, 200 * 1024); T.eq(table.concat(st.lru, ","), "e")
        local one = inline.new()
        one.byUrl.z = { state = "ready" }
        one:keepBytes("z", string.rep("x", 600 * 1024))
        T.ok(one.byUrl.z.bytes, "the newest is kept even over the cap")
    end,
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `lua tests/run.lua tests/test_inline.lua`
Expected: FAIL with `module 'src.inline' not found`.

- [ ] **Step 3: Implement**

Create `src/inline.lua`:

```lua
-- Inline pictures on one page (inline images spec 5.1): which picture to
-- fetch or decode next, which decoded ones to drop, the compressed bytes kept,
-- and a box's rows from a picture's height. Pure: the app makes the requests
-- and decodes.
local url = require("src.url")

local M = {}
M.__index = M

-- A box is at most ROWS rows of ROW_H px (page rows are 13 px in both fonts),
-- with PAD px above and below its picture; pictures fit FIT_W (the page width
-- less its margins) by FIT_H.
M.ROWS, M.ROW_H, M.PAD = 10, 13, 2
M.FIT_W = 312
M.FIT_H = M.ROWS * M.ROW_H - 2 * M.PAD
M.FIT = M.FIT_W .. "x" .. M.FIT_H
M.BYTES_CAP = 512 * 1024
M.RETRY_MS = 3000

-- boxes: {[k] = rows} for image links already laid out as boxes (Back,
-- Reload), or nil. wake: something may have changed since the last pass.
function M.new(boxes)
    return setmetatable({ boxes = boxes or {}, byUrl = {}, lru = {}, bytesTotal = 0, wake = true }, M)
end

-- The rows of a box for a picture h px tall.
function M.rows(h)
    return (h + 2 * M.PAD + M.ROW_H - 1) // M.ROW_H
end

-- The image links overlapping the window, which is the screen and one screen
-- above and below it, in loading order: on screen top to bottom, then below
-- nearest first, then above nearest first.
function M.order(L, ps)
    local top, bottom = ps.top, ps:lastVisible()
    local lo, hi = top - ps.visible, bottom + ps.visible
    local out, below, above = {}, {}, {}
    for k, link in ipairs(L.links) do
        if link.first > hi then break end
        if link.image and link.last >= lo then
            if link.first > bottom then
                below[#below + 1] = k
            elseif link.last < top then
                above[#above + 1] = k
            else
                out[#out + 1] = k
            end
        end
    end
    for _, k in ipairs(below) do out[#out + 1] = k end
    for i = #above, 1, -1 do out[#out + 1] = above[i] end
    return out
end

-- The first link in order whose picture was never tried and is on the web.
function M:nextFetch(L, order)
    for _, k in ipairs(order) do
        local u = L.links[k].url
        local scheme = url.scheme(u)
        if not self.byUrl[u] and (scheme == "http" or scheme == "https") then return k, u end
    end
    return nil
end

-- The first link in order whose picture has bytes but isn't decoded.
function M:nextDecode(L, order)
    for _, k in ipairs(order) do
        local e = self.byUrl[L.links[k].url]
        if e and e.state == "ready" and e.bytes and not e.img then return k end
    end
    return nil
end

-- Decoded pictures that no link in the window shows, sorted.
function M:drops(L, order)
    local used = {}
    for _, k in ipairs(order) do used[L.links[k].url] = true end
    local out = {}
    for u, e in pairs(self.byUrl) do
        if e.img and not used[u] then out[#out + 1] = u end
    end
    table.sort(out)
    return out
end

-- Lets a decoded picture go. An entry left with nothing is removed, so the
-- picture is fetched again when it's wanted.
function M:drop(u)
    local e = self.byUrl[u]
    e.img = nil
    if not e.bytes then self.byUrl[u] = nil end
end

local function unlist(self, u)
    for i, v in ipairs(self.lru) do
        if v == u then
            table.remove(self.lru, i)
            return true
        end
    end
    return false
end

-- Marks u's bytes as the most recently used.
function M:touch(u)
    if unlist(self, u) then self.lru[#self.lru + 1] = u end
end

-- Keeps a picture's compressed bytes, dropping the least recently used past
-- BYTES_CAP (never the newest). An entry left with nothing is removed.
function M:keepBytes(u, bytes)
    self.byUrl[u].bytes = bytes
    self.lru[#self.lru + 1] = u
    self.bytesTotal = self.bytesTotal + #bytes
    while self.bytesTotal > M.BYTES_CAP and #self.lru > 1 do
        local old = table.remove(self.lru, 1)
        local o = self.byUrl[old]
        self.bytesTotal = self.bytesTotal - #o.bytes
        o.bytes = nil
        if not o.img then self.byUrl[old] = nil end
    end
end

-- A picture that can't be shown: kept as failed, so it isn't fetched again
-- (until Reload), and its bytes go.
function M:fail(u)
    local e = self.byUrl[u]
    if e.bytes and unlist(self, u) then self.bytesTotal = self.bytesTotal - #e.bytes end
    e.state, e.bytes, e.img = "failed", nil, nil
end

return M
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `lua tests/run.lua tests/test_inline.lua && make test`
Expected: all pass under both Luas.

- [ ] **Step 5: Commit**

```bash
git add src/inline.lua tests/test_inline.lua
git commit -m "feat: inline picture state: loading order, decode and drop choices, a byte cap"
```

---

### Task 5: Fetching pictures and growing their boxes

**Files:**
- Modify: `src/proxy.lua`, `src/app.lua`, `src/screens/page.lua`, `tests/fakepc.lua`, `tests/test_proxy.lua`
- Create: `tests/test_app_inline.lua`

**Interfaces:**
- Consumes: Task 3 (`layout.setBox`, `layout.BOX`, `ps:shift`) and Task 4 (all of `inline`).
- Produces:
  - `proxy.getPath(base, target, as, fit)`.
  - `App:request(target, as, done, fit)`.
  - `app.cfg.images`, either `"links"` or `"inline"`.
  - `page.inline`: an `inline` state, on pages built by `buildPage` when Images is Inline.
  - `App:stepImages()`, `App:canFetchImages()`, `App:fetchInline(p, u)`, `App:inlineArrived(p, req, r)`, `App:decodeInline(p, u)`, `App:cancelInline(p)`.
  - Log lines:
    - `picosurf: inline fetch <url>`
    - `picosurf: inline <k> w=<w> h=<h> rows=<rows>`
    - `picosurf: inline failed <url> <status or -> <reason>`
    - `picosurf: inline failed <url> decode <error>`
    - `picosurf: inline failed <url> larger than 312x126`
    - `picosurf: inline cancelled <url>`
  - Fake image bodies `"JPEG:<w>x<h>"` decode to that size, and `F.decoded` lists the decoded bodies.

- [ ] **Step 1: Write the failing tests**

In `tests/test_proxy.lua`, add to `builds_paths_and_headers`:

```lua
        T.eq(proxy.getPath({ prefix = "" }, "https://a.test/c.jpg", nil, "312x126"), "/v1/get?url=https%3A%2F%2Fa.test%2Fc.jpg&fit=312x126")
```

In `tests/fakepc.lua`:
- Add `decoded = {}` to the initial `F` table.
- Replace `graphics.image.loadFromBuffer` with:

```lua
    function graphics.image.loadFromBuffer(data)
        if data:sub(1, 4) ~= "JPEG" then error("JPEG decoding failed") end
        -- "JPEG:<w>x<h>" decodes to that size; any other JPEG body to 200x120.
        local w, h = data:match("^JPEG:(%d+)x(%d+)")
        w, h = math.tointeger(tonumber(w)) or 200, math.tointeger(tonumber(h)) or 120
        F.decoded[#F.decoded + 1] = data
        local img = {}
        function img:getSize() return w, h end
        function img:draw() end
        return img
    end
```

Create `tests/test_app_inline.lua`:

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

-- Rows at 52 columns: 1 title, 2 intro, 3 picture one, 4-33 text, 34 picture
-- two, 35-64 text, 65 picture three. 21 rows show, so at the top the window
-- (rows -20 to 42) holds pictures one and two.
local PICS = table.concat({
    "# Pics", "intro", "=> https://img.test/1.jpg [IMG] one", lines(1, 30),
    "=> https://img.test/2.jpg [IMG] two", lines(31, 60), "=> https://img.test/3.jpg [IMG] three",
}, "\n")

local function gallery()
    local parts = { "# Gallery" }
    for i = 1, 40 do parts[#parts + 1] = "=> https://img.test/g" .. i .. ".jpg [IMG] picture " .. i end
    return table.concat(parts, "\n")
end

local function jpeg(w, h)
    return { type = "image/jpeg", mode = false, body = "JPEG:" .. w .. "x" .. h }
end

local ROUTES = {
    ["https://pics.test/"] = { title = "Pics", body = PICS },
    ["https://img.test/1.jpg"] = jpeg(200, 100), -- 8 rows
    ["https://img.test/2.jpg"] = jpeg(312, 126), -- 10 rows
    ["https://img.test/3.jpg"] = jpeg(100, 50), -- 5 rows
    ["https://b.test/"] = { title = "B", body = "# B\n\nBack page.\n" },
    ["https://fail.test/"] = {
        title = "F",
        body = "# F\n=> https://img.test/missing.jpg [IMG] gone\n=> https://img.test/bad.jpg [IMG] broken\n"
            .. "=> gemini://g.test/x.jpg [IMG] elsewhere\n",
    },
    ["https://img.test/bad.jpg"] = { type = "image/jpeg", mode = false, body = "nope" },
    ["https://twice.test/"] = {
        title = "T", body = "# T\n=> https://img.test/1.jpg [IMG] one\ntext\n=> https://img.test/1.jpg [IMG] one again\n",
    },
    ["https://old.test/"] = {
        title = "O", body = "# O\n=> https://img.test/big1.jpg [IMG] one\n=> https://img.test/big2.jpg [IMG] two\n",
    },
    ["https://img.test/big1.jpg"] = jpeg(320, 240),
    ["https://img.test/big2.jpg"] = jpeg(320, 240),
    ["https://gallery.test/"] = { title = "Gallery", body = gallery() },
}
for i = 1, 40 do ROUTES["https://img.test/g" .. i .. ".jpg"] = jpeg(200, 100) end

local function boot(opts)
    opts = opts or {}
    local F = fakepc.new()
    F.config.proxy_url, F.config.token = "https://p.test", "tok"
    F.config.images, F.config.font = opts.images, opts.font
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

-- Opens a page, holding every response after the page's own: the first
-- picture's request is left waiting.
local function openHolding(app, F, text)
    F.inputs[#F.inputs + 1] = text
    F.press("f1")
    app:step()
    F.holding = true
    app:step()
end

-- The paths of the picture requests so far, in order.
local function pictureRequests(F)
    local out = {}
    for _, r in ipairs(F.requests) do
        if r.path:find("&fit=", 1, true) then out[#out + 1] = r.path end
    end
    return out
end

-- Link k's rows when it is laid out as a box, else 0.
local function boxRows(app, k)
    local L = app.page.L
    local link = L.links[k]
    if L.style[link.first] ~= layout.BOX then return 0 end
    return link.last - link.first + 1
end

local function decodedNow(app)
    local n = 0
    for _, e in pairs(app.page.inline.byUrl) do
        if e.img then n = n + 1 end
    end
    return n
end

return {
    pictures_load_in_order_and_grow_their_boxes = function()
        local app, F = boot({ images = "inline" })
        go(app, F, "pics.test/")
        steps(app, 4)
        local reqs = pictureRequests(F)
        T.eq(#reqs, 2, "the third picture is beyond the window")
        T.eq(reqs[1], "/v1/get?url=https%3A%2F%2Fimg.test%2F1.jpg&fit=312x126")
        T.ok(reqs[2]:find("2.jpg", 1, true))
        T.eq(boxRows(app, 1), 8); T.eq(boxRows(app, 2), 10); T.eq(boxRows(app, 3), 0)
        T.ok(F.hasLog("picosurf: inline 1 w=200 h=100 rows=8"))
        T.ok(F.hasLog("picosurf: inline 2 w=312 h=126 rows=10"))
        T.eq(app.page.ps.top, 1, "growing below the top leaves the view")
    end,
    one_picture_at_a_time = function()
        local app, F = boot({ images = "inline" })
        openHolding(app, F, "pics.test/")
        steps(app, 2)
        T.eq(app.screenName, "page")
        T.eq(#pictureRequests(F), 1)
        F.holding = false
        steps(app, 2)
        T.eq(#pictureRequests(F), 2)
    end,
    a_picture_above_the_view_grows_without_moving_it = function()
        local app, F = boot({ images = "inline" })
        openHolding(app, F, "pics.test/")
        F.press("right"); F.press("right"); steps(app, 1)
        local ps = app.page.ps
        T.eq(ps.top, 41)
        local line = app.page.L.line[41]
        F.holding = false
        steps(app, 8)
        -- One grows by 7 rows and two by 9, both above the view; three by 4, below it.
        T.eq(#pictureRequests(F), 3)
        T.eq(app.page.ps.top, 57); T.eq(app.page.L.line[57], line, "the same line is at the top")
    end,
    links_mode_fetches_no_pictures = function()
        local app, F = boot()
        go(app, F, "pics.test/")
        steps(app, 4)
        T.eq(#pictureRequests(F), 0)
        T.eq(app.page.inline, nil)
        T.eq(app.page.L.style[3], layout.IMAGE)
    end,
    failed_pictures_stay_link_lines = function()
        local app, F = boot({ images = "inline" })
        go(app, F, "fail.test/")
        steps(app, 4)
        T.eq(#pictureRequests(F), 2, "the gemini picture is not fetched")
        T.ok(F.hasLog("picosurf: inline failed https://img.test/missing.jpg 502 Site returned 404 Not Found"))
        T.ok(F.hasLog("picosurf: inline failed https://img.test/bad.jpg decode"))
        for k = 1, 3 do T.eq(boxRows(app, k), 0, "link " .. k .. " stays a line") end
        app.page.inline.wake = true
        steps(app, 2)
        T.eq(#pictureRequests(F), 2, "not tried again")
        F.menu["Reload"](); steps(app, 6)
        T.eq(#pictureRequests(F), 4, "Reload tries again")
    end,
    leaving_the_page_cancels_the_picture_in_flight = function()
        local app, F = boot({ images = "inline" })
        openHolding(app, F, "pics.test/")
        T.eq(#pictureRequests(F), 1)
        F.menu["Settings"](); steps(app, 1)
        T.ok(F.hasLog("picosurf: inline cancelled https://img.test/1.jpg"))
        T.eq(app.page.inline.inflight, nil)
        T.eq(app.page.inline.byUrl["https://img.test/1.jpg"], nil)
        F.holding = false
        F.press("esc"); steps(app, 4)
        T.eq(app.screenName, "page")
        T.eq(#pictureRequests(F), 3, "fetched again on return, then the next")
        T.eq(boxRows(app, 1), 8)
    end,
    leaving_for_a_cached_page_cancels_the_picture = function() -- Review Focus 4
        local app, F = boot({ images = "inline" })
        go(app, F, "b.test/")
        openHolding(app, F, "pics.test/")
        T.eq(app.page.url, "https://pics.test/")
        F.press("backspace"); steps(app, 1)
        T.eq(app.page.url, "https://b.test/")
        T.ok(F.hasLog("picosurf: inline cancelled https://img.test/1.jpg"))
        F.holding = false
        steps(app, 3)
        T.eq(app.screenName, "page"); T.eq(app.page.url, "https://b.test/")
        T.eq(#pictureRequests(F), 1)
    end,
    the_same_picture_twice_is_fetched_once = function() -- Review Focus 1
        local app, F = boot({ images = "inline" })
        go(app, F, "twice.test/")
        steps(app, 3)
        T.eq(#pictureRequests(F), 1)
        T.eq(#F.decoded, 1)
        T.eq(boxRows(app, 1), 8); T.eq(boxRows(app, 2), 8)
    end,
    a_gallery_keeps_few_pictures_decoded = function() -- Review Focus 2
        local app, F = boot({ images = "inline" })
        go(app, F, "gallery.test/")
        local most = 0
        for _ = 1, 60 do
            F.press("right"); steps(app, 3)
            most = math.max(most, decodedNow(app))
        end
        T.eq(app.page.ps.top, app.page.ps:maxTop(), "scrolled to the end")
        T.eq(boxRows(app, 40), 8, "the last picture loaded")
        -- The window's 63 rows overlap at most 9 boxes of 8 rows; one more may
        -- be decoded in the step before the next pass drops it.
        T.ok(most <= 10, "decoded pictures stay within the window: " .. most)
    end,
    waits_for_wifi = function()
        local app, F = boot({ images = "inline" })
        F.inputs[#F.inputs + 1] = "pics.test/"
        F.press("f1")
        app:step()
        F.netStatus = 0
        steps(app, 3)
        T.eq(app.screenName, "page")
        T.eq(#pictureRequests(F), 0, "no WiFi")
        F.netStatus = 1
        steps(app, 2)
        T.eq(#pictureRequests(F), 0, "looks again after 3 s")
        F.ms = F.ms + 3000
        steps(app, 2)
        T.eq(#pictureRequests(F), 1)
    end,
    clock_not_set_waits_and_tries_again = function()
        local app, F = boot({ images = "inline" })
        local respond, fails = F.responder, 0
        F.responder = function(path, headers)
            -- Twice: the pool retries a reused connection once on a fresh one.
            if path:find("1.jpg", 1, true) and fails < 2 then
                fails = fails + 1
                return nil, "clock not set"
            end
            return respond(path, headers)
        end
        go(app, F, "pics.test/")
        steps(app, 2)
        T.eq(boxRows(app, 1), 0)
        T.eq(app.page.inline.byUrl["https://img.test/1.jpg"], nil)
        T.ok(app.page.inline.retryAt)
        F.ms = F.ms + 3000
        steps(app, 3)
        T.eq(boxRows(app, 1), 8)
    end,
    an_old_proxy_ignores_fit = function()
        local app, F = boot({ images = "inline" })
        go(app, F, "old.test/")
        steps(app, 3)
        T.eq(#pictureRequests(F), 2)
        T.ok(F.hasLog("picosurf: inline failed https://img.test/big1.jpg larger than 312x126"))
        local n = 0
        for _, t in ipairs(F.toasts) do
            if t == "Inline images need a newer proxy" then n = n + 1 end
        end
        T.eq(n, 1, "one toast")
        T.eq(boxRows(app, 1), 0); T.eq(boxRows(app, 2), 0)
    end,
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `lua tests/run.lua tests/test_proxy.lua tests/test_app_inline.lua`
Expected: FAIL.
- `getPath` has no `&fit=`.
- The inline tests get 0 picture requests, or index `page.inline`, which is nil.

- [ ] **Step 3: Implement**

`src/proxy.lua`: replace `getPath`:

```lua
-- fit: "WxH" for an inline picture's box (inline images spec 3.1), or nil.
function M.getPath(base, target, as, fit)
    local p = base.prefix .. "/v1/get?url=" .. url.encode(target)
    if as then p = p .. "&as=" .. as end
    if fit then p = p .. "&fit=" .. fit end
    return p
end
```

`src/app.lua`:
- Add `local inline = require("src.inline")` after `local feeds = require("src.feeds")`.
- In `loadConfig`, replace the `self.cfg = ...` line with:

```lua
    self.cfg = {
        proxyUrl = c.get("proxy_url") or "", token = c.get("token") or "", font = c.get("font") or "scientifica",
        images = c.get("images") == "inline" and "inline" or "links",
    }
```

- Replace `App:request`:

```lua
-- Starts a proxy request; done(result) runs from the main loop. fit: "WxH"
-- for an inline picture (nil for pages and full-screen images).
function App:request(target, as, done, fit)
    if not self.pool then return nil, self.baseErr or "Set the proxy URL in Settings" end
    local handle, err = self.pool:get(proxy.getPath(self.base, target, as, fit), proxy.headers(self.cfg.token),
        function(ok, status, body, headers)
            self.inbox[#self.inbox + 1] = { done = done, result = proxy.interpret(ok, status, body, headers) }
        end)
    if not handle then return nil, err == "busy" and "Busy: try again" or err end
    return handle
end
```

- In `showResult`, put `self:cancelInline(self.page)` on the line before `self.page = page`.
- In `buildPage`, after `if restore then page.ps:restore(restore.top, restore.sel) end`:

```lua
    if self.cfg.images == "inline" then page.inline = inline.new() end -- inline images spec 5.1
```

- In `goHome`, make the first line `self:cancelInline(self.page)`.
- In `showFeed`, put `self:cancelInline(self.page)` on the line before `self.page = page`.
- Add after `App:relayout` (before `App:fail`):

```lua
-- Whether a picture can be fetched now: a proxy, WiFi, and for TLS a set clock.
function App:canFetchImages()
    if not self.pool or self.pc.network.getStatus() ~= 1 then return false end
    return not (self.base.tls and not self.sys.getClock().synced)
end

-- Inline pictures, each step on the page screen (inline images spec 5.2): drop
-- the decoded pictures that left the window, decode one, and start the next
-- fetch. A pass runs only when something may have changed: the view moved, a
-- picture arrived or was decoded, or the retry time passed.
function App:stepImages()
    local p = self.page
    local st = p and p.inline
    if not st then return end
    local ps, now = p.ps, self.sys.getTimeMs()
    if ps.top ~= st.seenTop then st.seenTop, st.wake = ps.top, true end
    if st.retryAt and now - st.retryAt >= 0 then st.retryAt, st.wake = nil, true end
    if not st.wake then return end
    st.wake = false
    local L = p.L
    local order = inline.order(L, ps)
    for _, u in ipairs(st:drops(L, order)) do st:drop(u) end
    local k = st:nextDecode(L, order)
    if k then
        self:decodeInline(p, L.links[k].url)
        st.wake = true
    end
    if st.inflight or st.retryAt then return end
    local fk, u = st:nextFetch(L, order)
    if not fk then return end
    if not self:canFetchImages() then
        st.retryAt = now + inline.RETRY_MS
        return
    end
    self:fetchInline(p, u)
    st.wake = true -- the next picture, or the pool was busy: look again next step
end

function App:fetchInline(p, u)
    local st = p.inline
    local req = { url = u }
    req.handle = self:request(u, nil, function(r) self:inlineArrived(p, req, r) end, inline.FIT)
    if not req.handle then return end -- the pool is busy
    st.byUrl[u] = { state = "loading" }
    st.inflight = req
    self:log("inline", "fetch", u)
end

-- A picture's response, from pump. Ignored when its page or request has gone.
function App:inlineArrived(p, req, r)
    local st = p.inline
    if self.page ~= p or not st or st.inflight ~= req then return end
    st.inflight, st.wake = nil, true
    local u = req.url
    if r.kind == "clock" then
        st.byUrl[u] = nil
        st.retryAt = self.sys.getTimeMs() + inline.RETRY_MS
        return
    end
    if r.kind ~= "image" then
        st.byUrl[u].state = "failed"
        return self:log("inline", "failed", u, r.status or "-", r.message or r.kind)
    end
    st.byUrl[u].state = "ready"
    st:keepBytes(u, r.body)
    self:decodeInline(p, u)
end

-- Decodes u's bytes and lays every image link to u out as a box of its
-- picture's rows, keeping the view on the same content (inline images 5.3).
function App:decodeInline(p, u)
    local st = p.inline
    local ok, img = pcall(self.pc.graphics.image.loadFromBuffer, st.byUrl[u].bytes)
    if not ok or not img then
        st:fail(u)
        return self:log("inline", "failed", u, "decode", tostring(img))
    end
    local w, h = img:getSize()
    if w > inline.FIT_W or h > inline.FIT_H then
        -- A proxy older than fit sent a 320x320 picture.
        st:fail(u)
        self:log("inline", "failed", u, "larger than " .. inline.FIT)
        if not self.oldProxyWarned then
            self.oldProxyWarned = true
            self:toast("Inline images need a newer proxy", self.ui.TOAST_WARNING)
        end
        return
    end
    local e = st.byUrl[u]
    e.img, e.w, e.h = img, w, h
    st:touch(u)
    local rows = inline.rows(h)
    for k, link in ipairs(p.L.links) do
        if link.image and link.url == u then
            if st.boxes[k] ~= rows or p.L.style[link.first] ~= layout.BOX then
                local first = link.first
                p.ps:shift(first, layout.setBox(p.L, k, rows))
                st.boxes[k] = rows
            end
            self:log("inline", k, "w=" .. w, "h=" .. h, "rows=" .. rows)
        end
    end
    self.dirty = true
end

-- Cancels page p's picture in flight and forgets it, so it is fetched again
-- when the page is back on screen.
function App:cancelInline(p)
    local st = p and p.inline
    if not st then return end
    st.wake = true
    local req = st.inflight
    if not req then return end
    st.inflight = nil
    st.byUrl[req.url] = nil
    req.handle.cancel()
    self:log("inline", "cancelled", req.url)
end
```

`src/screens/page.lua`: add before `function S.key(app, action, arg)`:

```lua
-- Inline pictures load while the page is on screen (inline images spec 5.2).
function S.update(app)
    app:stepImages()
end

-- Leaving by any route cancels the picture in flight; it's fetched again on return.
function S.leave(app)
    app:cancelInline(app.page)
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `lua tests/run.lua tests/test_proxy.lua tests/test_app_inline.lua && make test`
Expected: all pass under both Luas, including the existing `tests/test_app.lua`. Links mode must be unchanged.

- [ ] **Step 5: Commit**

```bash
git add src/proxy.lua src/app.lua src/screens/page.lua tests/fakepc.lua tests/test_proxy.lua tests/test_app_inline.lua
git commit -m "feat: fetch inline pictures one at a time around the view and grow their boxes"
```

---

### Task 6: Drawing boxes

**Files:**
- Modify: `src/screens/page.lua`, `tests/fakepc.lua`
- Test: `tests/test_app_inline.lua`

**Interfaces:**
- Consumes:
  - `page.inline.byUrl[url]` entries `{img, w, h}` (Task 5).
  - `layout.BOX` (Task 3).
  - `inline.FIT_W` and `inline.PAD` (Task 4).
- Produces:
  - The page draws boxes.
  - `fakepc` records `F.rects` (`{x, y, w, h, c}`, one per `fillRect`) and `F.imageDraws` (`{data, x, y, src}`, one per `img:draw`). Both reset on `display.clear`.

- [ ] **Step 1: Write the failing tests**

In `tests/fakepc.lua`:
- Add `rects = {}, imageDraws = {}` to the initial `F` table.
- Replace `display.clear` and `display.fillRect`:

```lua
    function display.clear() F.texts, F.textFonts, F.rects, F.imageDraws = {}, {}, {}, {} end
    function display.fillRect(x, y, w, h, c) F.rects[#F.rects + 1] = { x = x, y = y, w = w, h = h, c = c } end
```

- In `loadFromBuffer`, replace `function img:draw() end` with:

```lua
        function img:draw(x, y, _, src)
            F.imageDraws[#F.imageDraws + 1] = { data = data, x = x, y = y, src = src }
        end
```

In `tests/test_app_inline.lua`, add these helpers above `return {`:

```lua
local function hasText(F, text)
    for _, t in ipairs(F.texts) do
        if t == text then return true end
    end
    return false
end

-- The last frame's draw of the picture whose fake bytes are `data`.
local function drawOf(F, data)
    for _, d in ipairs(F.imageDraws) do
        if d.data == data then return d end
    end
    return nil
end

local function hasRect(F, x, y, w, h)
    for _, r in ipairs(F.rects) do
        if r.x == x and r.y == y and r.w == w and r.h == h then return true end
    end
    return false
end
```

and these entries to the returned table:

```lua
    draws_a_picture_in_its_box = function()
        local app, F = boot({ images = "inline" })
        go(app, F, "pics.test/")
        steps(app, 3)
        -- Picture one (200x100) on rows 3-10: its band starts at y 21 + 2 * 13 = 47,
        -- the picture 2 px lower, centred.
        local d = drawOf(F, "JPEG:200x100")
        T.ok(d, "picture one is drawn")
        T.eq(d.x, 60); T.eq(d.y, 49)
        T.eq(d.src.x, 0); T.eq(d.src.y, 0); T.eq(d.src.w, 200); T.eq(d.src.h, 100)
        T.eq(app.page.ps.sel, 1)
        T.ok(hasRect(F, 0, 47, 320, 104), "selected: the whole band in the selection colour")
        T.ok(not F.screenText():find("[IMG] one", 1, true), "no label while the picture shows")
    end,
    crops_pictures_to_the_rows_between_title_bar_and_footer = function()
        local app, F = boot({ images = "inline" })
        go(app, F, "pics.test/")
        steps(app, 3)
        local ps = app.page.ps
        ps:scroll(4); app.dirty = true; steps(app, 1)
        -- Top 5: picture one's band starts 2 rows above the screen (y -5), the picture at y -3.
        local d = drawOf(F, "JPEG:200x100")
        T.eq(d.y, 21); T.eq(d.src.y, 24); T.eq(d.src.h, 76)
        T.ok(hasRect(F, 0, 21, 320, 78), "the selection band is cropped too")
        ps:scroll(16); app.dirty = true; steps(app, 1)
        -- Top 21: picture two (312x126, rows 41-50) starts on the last row, its band at y 281.
        d = drawOf(F, "JPEG:312x126")
        T.eq(d.x, 4); T.eq(d.y, 283); T.eq(d.src.y, 0); T.eq(d.src.h, 11)
    end,
    a_picture_not_in_memory_shows_an_outline_and_its_label = function()
        local app, F = boot({ images = "inline" })
        go(app, F, "pics.test/")
        steps(app, 3)
        local st = app.page.inline
        st.byUrl["https://img.test/1.jpg"].img = nil -- as after it left the window
        st.wake = false
        app.dirty = true; steps(app, 1)
        T.eq(drawOf(F, "JPEG:200x100"), nil)
        T.ok(hasText(F, "[IMG] one"), "the label in the box's first row")
        T.ok(hasRect(F, 60, 49, 200, 1), "the top of a 200x100 outline")
        T.ok(hasRect(F, 60, 49, 1, 100), "its left side")
    end,
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `lua tests/run.lua tests/test_app_inline.lua`
Expected: FAIL. `drawOf` returns nil because nothing draws boxes yet: box rows draw as empty text.

- [ ] **Step 3: Implement**

`src/screens/page.lua`:
- Add `local inline = require("src.inline")` after the other requires.
- Add above `function S.draw(app)`:

```lua
-- A 1 px rectangle, cropped to the rows between clipTop and clipBottom.
local function outline(d, x, y, w, h, color, clipTop, clipBottom)
    local y0, y1 = math.max(y, clipTop), math.min(y + h, clipBottom)
    if y1 <= y0 then return end
    d.fillRect(x, y0, 1, y1 - y0, color)
    d.fillRect(x + w - 1, y0, 1, y1 - y0, color)
    if y >= clipTop then d.fillRect(x, y, w, 1, color) end
    if y + h <= clipBottom then d.fillRect(x, y + h - 1, w, 1, color) end
end

-- Inline picture k's box (inline images spec 5.5), drawn from its first
-- visible row and cropped to the rows between the title bar and the footer:
-- the selection band, then the picture, or a dim outline and the label while
-- the picture isn't in memory.
local function drawBox(app, k, cols)
    local th, d, p = app.theme, app.disp, app.page
    local L, ps = p.L, p.ps
    local link = L.links[k]
    local clipTop, clipBottom = th.top, th.top + ps.visible * th.rowH
    local bandTop = th.top + (link.first - ps.top) * th.rowH
    local bandH = (link.last - link.first + 1) * th.rowH
    if k == ps.sel then
        local y0, y1 = math.max(bandTop, clipTop), math.min(bandTop + bandH, clipBottom)
        d.fillRect(0, y0, 320, y1 - y0, th.selBg)
    end
    local e = p.inline and p.inline.byUrl[link.url]
    local w = e and e.w or inline.FIT_W
    local h = e and e.h or (bandH - 2 * inline.PAD)
    local x, y = (320 - w) // 2, bandTop + inline.PAD
    if e and e.img then
        local cut = math.max(0, clipTop - y)
        local shown = math.min(h, clipBottom - y) - cut
        if shown > 0 then e.img:draw(x, y + cut, false, { x = 0, y = cut, w = w, h = shown }) end
        return
    end
    outline(d, x, y, w, h, th.dim, clipTop, clipBottom)
    d.setFont(th.font)
    local row = math.max(link.first, ps.top)
    d.drawText(th.margin + th.cw, th.top + 1 + (row - ps.top) * th.rowH, link.label:sub(1, cols - 2), th.dim, false)
end
```

- In `S.draw`, replace the `for r = ps.top, ps:lastVisible() do ... end` loop with the version below. The `else` branch is the old loop body, unchanged.

```lua
    for r = ps.top, ps:lastVisible() do
        local y = th.top + 1 + (r - ps.top) * th.rowH
        local st = L.style[r]
        if st == layout.BOX then
            local k = L.link[r]
            if r == L.links[k].first or r == ps.top then drawBox(app, k, cols) end
        else
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
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `lua tests/run.lua tests/test_app_inline.lua && make test`
Expected: all pass under both Luas.

- [ ] **Step 5: Commit**

```bash
git add src/screens/page.lua tests/fakepc.lua tests/test_app_inline.lua
git commit -m "feat: draw inline pictures in their boxes, cropped to the page area"
```

---

### Task 7: The Images setting, and boxes kept across Back, Reload and font changes

**Files:**
- Modify: `src/app.lua`, `src/screens/settings.lua`, `tests/test_app.lua` (the Test connection test)
- Test: `tests/test_app_inline.lua`

**Interfaces:**
- Consumes: `inline.new(boxes)`, `layout.build(lines, cols, boxes)`, `App:cancelInline(p)`, and `page.inline`.
- Produces:
  - `App:setImages(mode)`.
  - Settings items in the order `proxy, token, font, images, test`.
  - Back entries and Reload's restore carry `boxes`.
  - `buildPage` and `relayout` lay pages out with the page's boxes.

- [ ] **Step 1: Write the failing tests**

In `tests/test_app.lua`, in `test_connection_reports_ok_and_token_errors`, change both `F.press("down"); F.press("down"); F.press("down"); F.press("enter")` and `F2.press(...)` sequences to four presses of `"down"`. Test connection moves to the fifth item:

```lua
        F.press("down"); F.press("down"); F.press("down"); F.press("down"); F.press("enter"); steps(app)
```

```lua
        F2.press("down"); F2.press("down"); F2.press("down"); F2.press("down"); F2.press("enter"); steps(app2)
```

In `tests/test_app_inline.lua`, add this helper above `return {`:

```lua
-- Settings, then the Images row (the fourth): switches it; Esc back to the page.
local function toggleImages(app, F)
    F.menu["Settings"](); steps(app, 1)
    F.press("down"); F.press("down"); F.press("down"); F.press("enter"); steps(app, 1)
end
```

and these entries to the returned table:

```lua
    images_setting_switches_and_applies_to_the_page = function() -- Review Focus 5
        local app, F = boot()
        go(app, F, "pics.test/")
        T.eq(#pictureRequests(F), 0)
        F.menu["Settings"](); steps(app, 1)
        T.ok(F.screenText():find("Images: Links", 1, true))
        F.press("esc"); steps(app, 1)
        toggleImages(app, F)
        T.eq(F.config.images, "inline")
        T.ok(F.screenText():find("Images: Inline", 1, true))
        F.press("esc"); steps(app, 4)
        T.eq(boxRows(app, 1), 8, "the page on screen gets its pictures")
        app.page.ps:scroll(10); app.dirty = true; steps(app, 1)
        local line = app.page.L.line[app.page.ps.top]
        toggleImages(app, F)
        T.eq(F.config.images, "links")
        F.press("esc"); steps(app, 3)
        T.eq(app.page.inline, nil)
        T.eq(boxRows(app, 1), 0); T.eq(app.page.L.count, 65, "laid out again without boxes")
        T.eq(app.page.L.line[app.page.ps.top], line, "the same line at the top")
        local before = #pictureRequests(F)
        steps(app, 3)
        T.eq(#pictureRequests(F), before, "no more picture requests")
    end,
    back_and_reload_keep_the_boxes = function()
        local app, F = boot({ images = "inline" })
        go(app, F, "pics.test/")
        steps(app, 3)
        app.page.ps:scroll(30); app.dirty = true; steps(app, 4)
        local top, count = app.page.ps.top, app.page.L.count
        local line = app.page.L.line[top]
        T.eq(top, 31); T.eq(count, 81)
        go(app, F, "b.test/")
        F.press("backspace"); steps(app, 1)
        T.eq(app.page.url, "https://pics.test/")
        T.eq(app.page.L.count, count, "the same rows"); T.eq(app.page.ps.top, top)
        T.eq(app.page.L.line[top], line)
        T.eq(boxRows(app, 1), 8); T.eq(boxRows(app, 2), 10)
        steps(app, 6)
        T.eq(app.page.ps.top, top, "pictures come back without moving the view")
        T.eq(app.page.L.count, count)
        F.menu["Reload"](); steps(app, 6)
        T.eq(app.page.ps.top, top); T.eq(app.page.L.line[top], line)
        T.eq(boxRows(app, 2), 10)
    end,
    a_font_change_keeps_the_boxes = function()
        local app, F = boot({ images = "inline" })
        go(app, F, "pics.test/")
        steps(app, 3)
        F.menu["Settings"](); steps(app, 1)
        F.press("down"); F.press("down"); F.press("enter"); steps(app, 1)
        F.press("esc"); steps(app, 1)
        T.eq(app.theme.cw, 8)
        T.eq(boxRows(app, 1), 8); T.eq(boxRows(app, 2), 10)
    end,
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `lua tests/run.lua tests/test_app.lua tests/test_app_inline.lua`
Expected: FAIL.
- `test_connection...` presses Enter on the Images row, which doesn't exist yet: no "Proxy OK" toast.
- `images_setting...` finds no `Images:` label.
- `back_and_reload...` gets a different row count after Back.
- `a_font_change...` gets `boxRows` 0.

- [ ] **Step 3: Implement**

`src/screens/settings.lua`:
- `local ITEMS = { "proxy", "token", "font", "images", "test" }`
- In `label`, before `return "Test connection"`:

```lua
    if item == "images" then return "Images: " .. (c.images == "inline" and "Inline" or "Links") end
```

- In `S.key`, add a branch after the `font` branch:

```lua
        elseif item == "images" then
            app:setImages(app.cfg.images == "inline" and "links" or "inline")
```

`src/app.lua`:
- Add after `App.MAX_BACK, App.MAX_CACHE = 20, 3`:

```lua
-- A copy of a page's inline box rows, for a Back entry or Reload (inline images spec 5.6).
local function copyBoxes(b)
    if not b then return nil end
    local c = {}
    for k, v in pairs(b) do c[k] = v end
    return c
end
```

- Replace `App:buildPage`:

```lua
-- Parses and lays out a page. With Images set to Inline, a page restored by
-- Back or Reload gets its boxes back, so the saved scroll position points at
-- the same content (inline images spec 5.6).
function App:buildPage(finalUrl, mode, r, restore)
    local cols = theme.cols(self.theme)
    local boxes = self.cfg.images == "inline" and restore and copyBoxes(restore.boxes) or nil
    local lines, L = self:withMemoryRetry(function()
        local lines = r.kind == "text" and gemtext.fromPlain(r.body) or gemtext.parse(r.body)
        return lines, layout.build(lines, cols, boxes)
    end)
    if not lines then return nil, L end
    local page = {
        url = finalUrl, want = mode, mode = r.mode or (r.kind == "text" and "full" or mode),
        title = r.title or gemtext.title(lines) or url.host(finalUrl), feedUrl = r.feedUrl, lines = lines, L = L,
    }
    page.ps = pagestate.new(L, theme.rows(self.theme))
    if restore then page.ps:restore(restore.top, restore.sel) end
    if self.cfg.images == "inline" then page.inline = inline.new(boxes) end
    return page
end
```

- In `App:relayout`, change the build call to:

```lua
    local L, err = self:withMemoryRetry(function()
        return layout.build(p.lines, theme.cols(self.theme), p.inline and p.inline.boxes)
    end)
```

- In `App:pushBack`, change the entry to:

```lua
    self.back[#self.back + 1] = {
        url = p.url, want = p.want, top = p.ps.top, sel = p.ps.sel, feedId = p.isFeedList and p.feedId or nil,
        boxes = p.inline and copyBoxes(p.inline.boxes) or nil,
    }
```

- In `App:goBack`: `local restore = { top = e.top, sel = e.sel, boxes = e.boxes }`
- In `App:reload`, change the last line to:

```lua
    self:open(p.url, { mode = p.want, push = false, restore = {
        top = p.ps.top, sel = p.ps.sel, boxes = p.inline and copyBoxes(p.inline.boxes) or nil,
    } })
```

- Add after `App:saveConfig`:

```lua
-- Settings → Images (inline images spec 5.6): saves the choice and applies it
-- to the page on screen. Off, the page is laid out again with link lines.
function App:setImages(mode)
    self:saveConfig("images", mode)
    local p = self.page
    if not p or p.isFeedList then return end
    if mode == "inline" then
        p.inline = p.inline or inline.new()
    elseif p.inline then
        self:cancelInline(p)
        p.inline = nil
        self:relayout()
    end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `lua tests/run.lua tests/test_app.lua tests/test_app_inline.lua && make test`
Expected: all pass under both Luas.

- [ ] **Step 5: Commit**

```bash
git add src/app.lua src/screens/settings.lua tests/test_app.lua tests/test_app_inline.lua
git commit -m "feat: Images setting (Links or Inline); boxes survive Back, Reload and font changes"
```

---

### Task 8: Simulator test and docs

**Files:**
- Modify:
  - `tests/e2e/fake_proxy.py`, `tests/e2e/conftest.py`, `tests/e2e/test_app.py`
  - `README.md`, `docs/hardware-pass.md`
  - `docs/superpowers/specs/2026-10-15-picosurf-design.md` (sections 2, 6.2, 6.3, 6.4, 6.5, 6.6, 6.8, 6.9, 7.2, 9)

**Interfaces:**
- Consumes:
  - The `picosurf: inline <k> w=.. h=.. rows=..` log line (Task 5).
  - The `fit=312x126` request parameter (Task 5).
  - Drawing (Task 6).

- [ ] **Step 1: Write the failing test**

`tests/e2e/fake_proxy.py`:
- In `do_GET`, replace the last line, `self._send(r["status"], r["ctype"], r["body"], extra)`, with:

```python
                body = r["body"]
                if r["ctype"] == "image/jpeg" and "fit" in q:
                    body = fit_jpeg(body, q["fit"])
                self._send(r["status"], r["ctype"], body, extra)
```

- Add at the end of the file:

```python
def fit_jpeg(data, fit):
    """Scales a JPEG to fit within WxH, never enlarging, as the proxy's fit
    parameter does."""
    from PIL import Image
    w, h = (int(v) for v in fit.split("x"))
    img = Image.open(io.BytesIO(data))
    img.thumbnail((w, h))
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=80, progressive=False)
    return buf.getvalue()
```

`tests/e2e/conftest.py`:
- Change `def start(config=True):` to `def start(config=True, settings=None):`.
- Replace the config write with:

```python
        if config:
            cfg = {"proxy_url": proxy.url, "token": proxy.token, **(settings or {})}
            (data / "config.json").write_text(json.dumps(cfg))
```

- Extend the fixture docstring's first line to `"""start(config=True, settings=None) -> (sim, proxy, data_dir). settings: more config.json keys, e.g. {"images": "inline"}. With config, ...` (keep the rest of the docstring).

`tests/e2e/test_app.py`: add after `test_image_opens_full_screen`:

```python
def test_inline_picture(picosurf):
    sim, proxy, data = picosurf(settings={"images": "inline"})
    seed_history(data, "https://a.test/")
    proxy.add("https://a.test/", A, title="A")
    proxy.add("https://a.test/cat.jpg", jpeg_bytes(640, 480), ctype="image/jpeg")
    wait(sim, r"picosurf: screen home", start_app(sim))
    # 640x480 in the 312x126 box is 168x126: 10 rows.
    wait(sim, r"picosurf: inline 2 w=168 h=126 rows=10", open_first_history(sim))
    assert any(q.get("fit") == "312x126" for _, q in proxy.requests)
    time.sleep(0.5)  # the frame drawn after the log line
    # A's rows: title, blank, text, the B link, then the picture's box from
    # row 5. Its band starts at y 21 + 4 * 13 = 73; the picture is 2 px lower
    # and centred, so (160, 138) is inside it.
    r, g, b = sim.screenshot_pil().convert("RGB").getpixel((160, 138))
    assert abs(r - 30) <= 24 and abs(g - 120) <= 24 and abs(b - 200) <= 24, (r, g, b)
    no_lua_errors(sim)
```

- [ ] **Step 2: Run the e2e tests**

Run: `make e2e`
Expected: all pass (7 tests). This runs after Tasks 5-6, so the new test passes straight away, which proves the device API path works in the simulator: `img:draw` with a source rectangle, decode and layout. If it fails, check the log for `picosurf: inline failed` before changing anything.

- [ ] **Step 3: Update the docs**

`README.md`:
- After the line `The system menu has Reload, Edit URL, Mark all read and Settings.`, add:

```
**Images** in Settings switches between Links (an `[IMG]` line; Enter opens the picture full screen) and Inline (pictures in the page, loaded as you read; Enter still opens one full screen). Inline needs a proxy from the same version or later: redeploy the proxy when you update.
```

- In `## Later`, change the last bullet to `- Web search, saving pages offline, OPML import, non-Latin fonts.`

`docs/hardware-pass.md`: add before the line `Report any missed target as-is; don't round it.`:

```
22. Settings → Images: Inline. Open an article with 10 or more images. Time until the first picture shows: ______ s. Scroll to the end and back with Right and Left: pictures appear in place, the text you're reading doesn't jump when a picture above it loads, and keys stay responsive. Heap free in the dev log at the end: ______ (above 1 MB). Enter on a picture opens it full screen.
```

Main spec `docs/superpowers/specs/2026-10-15-picosurf-design.md`:
- **2:** change `history; feed subscriptions with unread tracking; images opened full\n  screen on demand.` to `history; feed subscriptions with unread tracking; images opened full\n  screen on demand, or shown in the page (Settings → Images; see\n  \`2026-10-16-picosurf-inline-images-design.md\`).` In **Later**, remove `inline images, ` from `import, inline images, a public instance, fonts beyond ASCII.`
- **6.2:** change `- **Settings** (system menu): Proxy URL, Token, Font, Test connection.` to `- **Settings** (system menu): Proxy URL, Token, Font, Images, Test connection.`
- **6.3:** add a bullet after **Drawing**:

```
- **Inline pictures** (Images: Inline): an image link's rows become a box of
  `ceil((h + 4) / 13)` rows, at most 10, once its picture arrives; pictures
  within a screen of the view load one at a time. See the inline images
  design (`2026-10-16-picosurf-inline-images-design.md`), sections 2 and 5.
```

- **6.4:** after the paragraph that starts `System menu items`, add: `An inline picture's box is one link: Up/Down, Tab and Enter treat it like a link line, and Enter opens the picture full screen.`
- **6.5:** change `up to 20 entries of \`{url, mode, scroll, selected}\`.` to `up to 20 entries of \`{url, mode, scroll, selected, boxes}\` (boxes: inline picture box sizes, so Back returns to the same rows).`
- **6.6:** change the config row's contents from `` `proxy_url`, `token`, `font` `` to `` `proxy_url`, `token`, `font`, `images` ``.
- **6.8:** change `characters. Font switches between Scientifica and 8×12.` to `characters. Font switches between Scientifica and 8×12. Images switches\n  between Links (the default) and Inline.`
- **6.9:** add two rows before `| Corrupt storage file | 6.6 |`:

```
| Inline picture fails (proxy error, timeout, decode) | the line stays an `[IMG]` link; Reload tries again |
| Inline picture larger than its box (a proxy without `fit`) | stays a link; toast `Inline images need a newer proxy`, once per run |
```

- **7.2:** in the simulator E2E list, after `- an image opening full screen`, add `- an inline picture drawn in its box (Images: Inline)`.
- **9:** change `5. **Offline save, OPML import, inline images, fonts beyond ASCII, a richer` to `5. **Offline save, OPML import, fonts beyond ASCII, a richer`.

- [ ] **Step 4: Run everything**

Run: `make test && make e2e && (cd proxy && npm test && npm run typecheck)`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add tests/e2e/fake_proxy.py tests/e2e/conftest.py tests/e2e/test_app.py README.md docs/hardware-pass.md docs/superpowers/specs/2026-10-15-picosurf-design.md
git commit -m "test: inline picture in the simulator; docs: the Images setting"
```

---

## After the plan (ask the user first)

These are outward steps. Each needs the user's go-ahead.
1. **Deploy the proxy:** `cd proxy && npx wrangler deploy --env picodeck`. Then check that `fit` works against https://proxy.picodeck.net (a 400 for `fit=0x0`, and a 200 JPEG within 312×126 for a real image).
2. **Push the app to the device**, set Images: Inline, and run hardware-pass item 22.
