# PicoSurf inline images

Date: 2026-10-16. Status: design, for review.

This amends the main spec, `2026-10-15-picosurf-design.md`, which put inline
images among the later phases (section 9). Section 9 of this document lists
the main spec sections that change.

## 1. Goal

An option to see a page's pictures in the text as you read, not only as
`[IMG]` links that open full screen.

- **Settings → Images:** `Links` (today's behaviour, the default) or `Inline`.
- **Success:**
  - With Inline, the text shows as soon as the page loads, and images
    appear in place, usually before you reach them.
  - What you're reading never moves because an image above it loaded.
  - Memory stays bounded however many images a page has.
  - Links mode looks and behaves exactly as now, and makes no extra requests.
- **Not in scope:** animation (GIFs show their first frame, as now); images
  in feed lists (they have none); a size choice (Small/Large); text flowing
  beside images; keeping images when you leave a page.

## 2. What the reader sees

- **Before an image arrives** its line looks as it does now: `[IMG] alt` in
  the image colour, wrapped if the alt text is long.
- **Loading:** images whose lines are on screen or within one screen above
  or below it load one at a time. The order is: on screen (top to bottom),
  then below (nearest first), then above (nearest first). Nothing loads
  further away than that until you scroll.
- **The box:** when an image arrives, its line becomes a box `ceil((h + 4) / 13)`
  rows tall, at most 10 rows (130 px). The proxy has scaled the image to fit
  within 312×126 and never enlarges it. It is centred across the screen, 2 px
  below the top of the box.
- **The view stays put:** when the box starts above the first visible row,
  the view moves down by the rows the box gained, so the text on screen
  doesn't move. A box on or below the first visible row grows downwards, and
  the text after it moves down.
- **The box is a link:**
  - Up/Down, Tab and the selection rules (main spec 6.4) treat it as they
    treated the line, as one link of several rows.
  - The selected box's whole band is filled with the selection colour, so it
    shows as a frame around the picture.
  - Enter opens the full-screen view as now, fetched at 320×320.
- **Partly off screen:** a box only partly in view shows the part of the
  picture that is in view. It never draws over the title bar or the footer.
- **A box whose picture isn't in memory** keeps its size and shows a dim
  outline with the alt text in its first visible row until the picture is
  back. This happens after the picture was dropped (section 6) or after Back
  (section 5.6).
- **An image that can't be loaded** stays a link line, and is not tried again
  while the page is open. Reload tries again.
- **Changing the setting** applies to the page on screen at once.

## 3. Proxy

### 3.1 The `fit` parameter

```
GET /v1/get?url=<image URL>&fit=<W>x<H>
```

- The image is scaled to fit within W×H instead of 320×320, keeping its
  aspect ratio and never enlarged.
- W and H are whole numbers from 1 to 320, matching `^\d{1,3}x\d{1,3}$`.
  Anything else gets `400 Bad fit parameter`.
- `fit` changes only image responses. Pages, feeds and text ignore it.
- Without `fit` the box is 320×320 as now, so apps older than this change get
  what they get today.

### 3.2 Resizer

- `Resizer.resize(bytes, type, box)` takes the box as a `Size`, and
  `fitWithin(width, height, box)` fits within it. The handler passes
  `{width: 320, height: 320}` when there is no `fit`.
- **Workers:**
  - PNGs stream straight into the box (`streamPng(bytes, box)`).
  - JPEG and WebP decoders scale out of their heap to `fitWithin(size, box)`.
  - GIFs scale to the same.
  - The encoder never sees more than 320×320.
- **Node:** sharp resizes `inside` the box, without enlargement.
- **Caps:** the pixel caps stay as they are. They bound the decode, which
  doesn't depend on the output size.

### 3.3 Docs

- `proxy/README.md`: `fit` in the API section, and a note that inline images
  need a proxy from this version or later.
- Main spec: 5.1, 5.2 and 5.8 (section 9).

## 4. App units

| File | Change |
|---|---|
| `src/inline.lua` (new, pure) | Per-page inline image state and policy: which image to fetch next, which to decode, which decoded images to drop, the compressed-bytes cache, and box rows from an image height |
| `src/layout.lua` | Row style `BOX`. `build(lines, cols, boxes)` lays image link `k` out as `boxes[k]` box rows. `setBox(L, k, rows)` turns link `k`'s rows into `rows` box rows in place and returns the change in the row count |
| `src/pagestate.lua` | `ps:shift(row, delta)`: after `delta` rows were added (or removed) at `row`, keeps the view on the same content and keeps a link selected |
| `src/proxy.lua` | `getPath(base, target, as, fit)` appends `&fit=WxH` |
| `src/app.lua` | Config `images`; `page.inline` on pages; `App:stepImages()` and the result handler; boxes carried by Back, Reload and font changes; `App:setImages(mode)` |
| `src/screens/page.lua` | Draws boxes; `update` runs `app:stepImages()`; `leave` cancels the image request in flight |
| `src/screens/settings.lua` | The Images item |
| `tests/fakepc.lua` | The image fake reads its size from the bytes and records draws, with their source rectangles |

Rows stay 13 px with both fonts, so a box has the same number of rows in
either font.

## 5. App behaviour

### 5.1 State (`src/inline.lua`)

```lua
st = {
  boxes = { [k] = rows },  -- image links laid out as boxes (kept across Back, Reload, font)
  byUrl = { [url] = {      -- one entry per image URL; two links to one URL share it
    state = "loading" | "ready" | "failed",
    bytes = jpeg or nil,   -- compressed, in the LRU below
    img = userdata or nil, -- decoded
    w = w, h = h,
  } },
  lru = { url, ... }, bytesTotal = n, -- compressed bytes, least recently used first
  inflight = { url = url, handle = handle } or nil,
  retryAt = ms or nil,     -- after a "clock" result
}
```

- `inline.new(boxes)`
- `inline.rows(h)`: `ceil((h + 4) / 13)`
- `inline.order(L, ps)`: indices of the image links that overlap the window,
  in the loading order of section 2. The window is rows
  `top - visible .. lastVisible + visible`.
- `inline.nextFetch(st, L, ps)`: the first link in that order whose URL has no
  entry and is `http` or `https`; returns `k, url`.
- `inline.nextDecode(st, L, ps)`: the first link in that order whose entry is
  `ready` with bytes but no `img`.
- `inline.drops(st, L, ps)`: URLs with an `img` that no link in the window
  uses.
- `inline.keepBytes(st, url, bytes)`: adds to the LRU and drops the least
  recently used past 512 KB (`inline.BYTES_CAP`). An entry left with neither
  bytes nor `img` is removed, so it is fetched again when it's wanted.

### 5.2 Each step on the page screen (`App:stepImages`)

This runs only when Images is Inline and the page has `page.inline`.

1. **Drop:** for each URL from `drops`, `img = nil`.
2. **Decode:** at most one image per step, from `nextDecode`, under `pcall`.
3. **Fetch:** only when nothing is in flight, WiFi is up, and either the proxy
   isn't TLS or the clock is set. `retryAt` must also have passed.
   - Take `k, url = nextFetch(...)` and send `app:request(url, nil, done, "312x126")`.
   - If the pool is busy, try again next step.
   - The entry becomes `loading` and `inflight` is set.

### 5.3 A result

It is applied in `pump`. It is ignored if `page` is no longer `app.page`,
`page.inline` is no longer `st`, or `st.inflight` is a different request.

- **An image:**
  1. Keep the bytes and decode them under `pcall`.
  2. If the picture is larger than 312×126, the proxy ignored `fit` because
     it predates this change. Treat it as failed and log it, and show the
     toast `Inline images need a newer proxy` once per app run.
  3. Otherwise set `w, h` and `rows = inline.rows(h)`.
  4. For each image link with this URL whose rows differ, call
     `delta = layout.setBox(L, k, rows)` and then
     `ps:shift(L.links[k].first, delta)`, and set `boxes[k] = rows`.
- **`clock`:** remove the entry and set `retryAt` to 3 s from now.
- **Anything else** (a proxy error status, a timeout, a response that isn't an
  image): the entry becomes `failed` and the result is logged.

### 5.4 Layout and selection

- **`build` with `boxes`:** link `k` gets `boxes[k]` rows of style `BOX`.
  Each row has the link's source line, `s = 1, e = 0`, `link = k` and
  `cont = false`. Entries for links that aren't image links are ignored.
- **`setBox`** makes the same rows as `build` would. In place, it:
  - moves the later rows (`table.move` on each row array);
  - shifts the `first`/`last` of every later link;
  - updates `count`.
- **`ps:shift(row, delta)`:**
  - when `row < top`, `top = top + delta`;
  - clamps `top` to `1..maxTop()`;
  - then applies the existing rule that keeps the selection on screen (the
    topmost visible link when it has left).

### 5.5 Drawing (`src/screens/page.lua`)

- **The clip band** is from `th.top` (y 21) to `th.top + visible * rowH`: the
  rows between the title bar and the footer.
- **Box rows** draw no text. The box is drawn once, at its first visible row:
  - Its band starts at `rowY(first) - 1` and is `rows * 13` tall.
  - When the box is selected, its band is filled with `selBg`, clipped to the
    clip band.
  - **With the picture in memory:** `img:draw(x, y, false, src)`, where
    `x = (320 - w) // 2` and `y = rowY(first) + 1` (2 px below the band's
    top). `src` crops to the clip band, so a picture only partly in view
    draws only that part.
  - **Without it:** a dim 1 px outline of the picture's size, and the alt
    text in the box's first visible row.

### 5.6 Back, Reload, font change and the setting

- **Back and Reload:** back entries and Reload's `restore` carry a copy of
  `boxes`. The page is rebuilt with the same rows, so the saved `top` still
  points at the same content. Pictures reload into their boxes without
  moving anything.
  - If the page changed meanwhile and an image has another size, its box
    resizes when it loads, as in 5.3.
  - In Links mode boxes are neither saved nor used.
- **Font change:** `relayout` passes `page.inline.boxes` to `build`.
- **The setting:** `config.json` key `images`, `"links"` (the default) or
  `"inline"`. Settings shows `Images: Links` or `Images: Inline`, and Enter
  switches it. `App:setImages(mode)` saves it, then for the current page:
  - **Links:** cancel the image in flight, set `page.inline = nil`, and lay
    the page out again without boxes.
  - **Inline:** set `page.inline = inline.new({})`; loading starts when the
    page screen is back.
- **Feed lists** get no `page.inline`.

## 6. Budgets

| What | Bound |
|---|---|
| Decoded pictures | Only those overlapping the window, which is three screens of rows (63). A picture costs `w × h × 2` bytes, at most 312 × 126 × 2 = 79 KB. A picture is never larger than its box (`rows × 13` px tall, 312 px wide), so the boxes inside the window hold at most 63 × 13 × 312 × 2 bytes ≈ 0.5 MB of pictures. The two boxes that can cross the window's edges add at most 160 KB, so 0.67 MB in all. |
| Compressed bytes | 512 KB per page, least recently used dropped. That is dozens of pictures of 312×126 at quality 75 (to be measured: section 8). |
| Requests | One image request at a time, over the proxy keep-alive connection pages already use. None while a page is loading, because the loading screen replaces the page screen and its `leave` cancels the request. |
| Decoding | At most one picture per step, each at most 312×126. |

The Lua heap is about 6 MB. The full-screen view adds up to 200 KB on top.

## 7. Errors

| Situation | Behaviour |
|---|---|
| Proxy error status (413, 415, 502, 503...), timeout, a response that isn't an image | Stays a link line; logged; not retried until Reload |
| `clock` (TLS before time sync) | Tried again after 3 s |
| No WiFi | Nothing is fetched until it's back |
| Pool busy | Tried again next step |
| Decode fails under `pcall` (corrupt, out of memory) | Stays a link line (a restored box keeps its outline); logged |
| Picture larger than 312×126 | Failed; logged; toast `Inline images need a newer proxy` once per run |
| Image URL that isn't `http`/`https` | Stays a link line |
| Leaving the page screen (any route) | The request in flight is cancelled and its entry removed, so it is fetched again on return |

## 8. Testing

- **Proxy (vitest):**
  - `fit`: parsing, the 400s, being ignored for pages.
  - Each format comes out within the box, with both resizers.
  - With no `fit` the output is the same as now.
  - `streamPng` with a non-square box.
  - Record the JPEG size of the image fixtures at 312×126, as evidence for
    the byte cap.
- **App, host tests:**
  - `layout.build` with boxes.
  - `setBox` gives exactly the rows and links `build` gives with the same
    boxes, on sample pages with images at the start, middle and end, and
    with wrapped alt text.
  - `ps:shift` with the change above, at and below `top`, with clamping and
    with the selection pushed off screen.
  - `inline`: the order, the window, `nextFetch` and `nextDecode`, `drops`,
    and the LRU cap.
  - App level, with fakepc:
    - Links mode makes no image requests.
    - Inline requests `fit=312x126` in loading order, one at a time.
    - An arrival grows the box and keeps the view, and a failure leaves a
      link line.
    - Leaving the page cancels the request.
    - Back and Reload restore boxes.
    - The setting and a font change keep or drop boxes as in 5.6.
    - A picture larger than the box counts as failed, with the toast once.
- **Simulator e2e:** the fake proxy honours `fit` (Pillow makes a JPEG of
  the right size). Turn on Inline, open a page with an image, wait for the
  log line `inline <k> w=.. h=.. rows=..` and check that the box's region of
  a screenshot has the image's colours.
- **Hardware pass, added:** an article with 10 or more images:
  - the time until the first picture shows;
  - Lua heap free stays above 1 MB while scrolling to the end and back;
  - keys stay responsive while pictures load.

## 9. Changes to the main spec

These are made with the implementation:
- **2 (Scope):** inline images move from later to v1, as an option.
- **5.1:** the `fit` parameter.
- **5.2:** the image row names `fit`.
- **5.8:** output fits the box.
- **6.2:** Settings lists Images.
- **6.3:** box rows.
- **6.4:** a box is a link.
- **6.5:** back entries keep boxes.
- **6.6:** `images` in `config.json`.
- **6.8:** the Images field.
- **6.9:** the rows from section 7.
- **7.1, 7.2:** the tests.
- **9:** drop "inline images".

## 10. Decisions

- **The link line grows into a box once the picture arrives.** The
  alternatives were:
  - A fixed-height box from the start. A 10-row box would surround every
    emoji and icon.
  - Sizing boxes from the HTML `width`/`height` attributes. Many images have
    none, such as WordPress emoji and lazy-loaded images, and adding the size
    to the `[IMG]` line changes a format older apps read.

  Since images load a screen ahead, most grow before they're on screen, and
  growth above the view is cancelled out by moving the view (2, 5.4).
- **The proxy does not look up image sizes when it renders a page.** That
  would add a fetch per image to every page load, in Links mode as well.
- **One image request at a time.** Requests to the proxy share one
  keep-alive connection anyway, and the second pool slot stays free.
- **A picture larger than the box is a failure, not scaled on the device.**
  It only happens with an old proxy. Nearest-neighbour scaling would look
  poor, and would need its own clipping code.
- **Box size 312×126, 10 rows.** That is about half the 21-row screen, so
  text stays in view. A Small/Large choice can come later.
- **Links stays the default** until Inline has been through a hardware pass.
