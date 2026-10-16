# PicoSurf design

Date: 2026-10-15
Status: draft, awaiting review

## 1. Goal

Read the ordinary web (news, blogs, documentation) on a PicoCalc running
PicoDeck. The device cannot run a web engine, so a proxy fetches each page,
extracts the readable part with Mozilla Readability, and returns it as gemtext,
which the device renders. Gemini and Gopher are later additions that reuse
the same renderer.

The proxy is self-hosted: the author runs one, and anyone else can deploy
their own. A public shared instance is not part of v1, but nothing in v1 rules
it out (section 9).

## 2. Scope

**v1**
- Proxy: one fetch endpoint that converts HTML (reader mode, with a
  full-page fallback), RSS/Atom feeds and images; token auth; SSRF guard.
  Runs as a Cloudflare Worker or under Node in Docker.
- App: type a URL, read the page, follow links, go back; bookmarks;
  history; feed subscriptions with unread tracking; images opened full
  screen on demand.

**Later (section 9):** native Gemini (needs a firmware call for TOFU), Gopher,
Spartan, Nex and Finger, web search, saving pages for offline reading, OPML
import, inline images, a public instance, fonts beyond ASCII.

**Non-goals:** JavaScript, logins, cookies, POST forms, web apps.

## 3. Device facts that shape the design

| Fact | Consequence |
|---|---|
| 320×320 display; fonts cover ASCII 0x20-0x7E only, and other bytes draw as hollow boxes | The proxy folds all text to ASCII (5.6) |
| 6 MB Lua heap; `lua_Integer` is 32-bit, `lua_Number` is a single-precision float | Pages capped at 256 KB; timestamps kept as integers, never floats (a float epoch is accurate only to about 2 minutes) |
| `picocalc.network.http` client, receive ring of up to 2 MiB, custom headers, response headers readable | The device talks to the proxy over HTTPS with a bearer token |
| CA bundle of 11 roots, including ISRG X1/X2 (Let's Encrypt), GTS R1/R4 and SSL.com (Cloudflare) | A `workers.dev` proxy, or one behind Let's Encrypt, verifies without firmware changes |
| JPEGDEC decodes baseline JPEG | The proxy emits baseline JPEG only |
| `graphics.image.loadFromBuffer` | Images go straight from memory to the screen, with no temp file |
| `ui.textInput` takes at most 128 characters | Typed URLs, the proxy URL and the token must fit in 128 characters |
| `sys.getClock().epoch` (UTC, synced by SNTP; TLS waits for it) | Feed staleness survives restarts |
| Store rules: `app.json` at the repo root; a release has exactly one ZIP whose root holds `app.json` and `main.lua` | The app lives at the repo root, the proxy in `proxy/`, and the release ZIP leaves `proxy/` out |

## 4. Architecture

```
 PicoCalc (Lua app)                          Proxy (Worker, or Node in Docker)
 ┌──────────────────┐   HTTPS + token   ┌──────────────────────────────────┐
 │ screens / input  │ ────────────────▶ │ GET /v1/get?url=…                │──▶ web
 │ view (scroll,    │ ◀── text/gemini ─ │   HTML  → Readability → gemtext  │
 │   link select)   │ ◀── image/jpeg ── │   feed  → dated link list        │
 │ layout (wrap)    │                   │   image → ≤320×320 baseline JPEG │
 │ gemtext parser   │                   │ safefetch: SSRF guard, caps      │
 │ fetch layer      │                   └──────────────────────────────────┘
 └──────────────────┘
   /data/net.picodeck.picosurf/  config · bookmarks · history · feeds
```

The proxy stores nothing. Everything specific to the user is on the device.

### Repo layout (`PicoDeck/picosurf`, topic `picodeck-app`)

```
app.json                 id net.picodeck.picosurf, requirements ["http"], min_firmware 0.5.0
main.lua                 entry: screen state machine and input loop
src/url.lua              URL helpers: proxy base parsing, query encoding, scheme checks
src/fetch.lua            URL → {status, mime, headers, body} or error; dispatches by scheme
src/gemtext.lua          body → typed lines; feed-item extraction (pure)
src/layout.lua           typed lines → screen rows; wrap function injected (pure)
src/view.lua             draws rows, scroll position, link selection
src/store.lua            JSON files with safe writes; bookmarks, history
src/feeds.lua            refresh, unread calculation, pruning (pure core)
src/screens/home.lua     Feeds / Bookmarks / History tabs
src/screens/page.lua     page, loading and error views
src/screens/image.lua    full-screen image
src/screens/settings.lua proxy URL, token, font, test connection
tests/                   host Lua and lua32 unit tests; pytest simulator E2E
proxy/                   TypeScript proxy (5.9); left out of the release ZIP
.github/workflows/       CI (proxy tests, Lua tests), release ZIP
```

## 5. Proxy

### 5.1 API

```
GET /v1/ping                         → 200 text/plain "picosurf-proxy 1"
GET /v1/get?url=<absolute URL>[&as=reader|full|feed]
Authorization: Bearer <token>        (required on both endpoints)
```

`/v1/ping` needs the token, so "Test connection" checks the URL and the token
together. The `/v1/` prefix lets an incompatible API run alongside the
current one later.

### 5.2 Responses, chosen by what the site sends

| Upstream content | Response |
|---|---|
| HTML | `200 text/gemini; charset=us-ascii`: reader mode, falling back to the full page (5.5). `as=full` forces the full page. |
| RSS 2.0 / Atom | `200 text/gemini`: the feed list (5.7) |
| HTML with `as=feed` | Look for `<link rel="alternate" type="application/rss+xml\|application/atom+xml">`, fetch it and return the feed list; none found → `415 No feed found on this page` |
| `image/jpeg`, `png`, `webp`, `gif` | `200 image/jpeg`, baseline, fit within 320×320 (5.8) |
| `text/plain` | `200 text/plain; charset=us-ascii`, ASCII-folded |
| anything else, SVG included | `415` with a reason, e.g. `Unsupported: application/pdf (2.3 MB)` |

Response headers:
- `X-Final-Url`: URL after redirects (history and bookmarks use it)
- `X-Title`: page or feed title, ASCII-folded
- `X-Mode`: `reader`, `full` or `feed`
- `X-Feed-Url`: present when an HTML page advertises a feed (the app offers Subscribe)
- `X-Truncated: 1`: output hit the 256 KB cap

Every link in a response is absolute (`new URL(href, base).href`, fragment
removed).

### 5.3 Errors

Each error is a status code plus a one-line `text/plain` reason, which the app
shows as is.

| Status | When |
|---|---|
| 400 | missing or malformed `url`, or a scheme other than http/https |
| 401 | missing or wrong token (compared in constant time) |
| 403 | the target resolves to a blocked address |
| 413 | upstream body over the cap, an image over its pixel cap (5.8), or a page with more than 200,000 elements (`Page is too large to read (over 200,000 elements)`; counted with the parser before any DOM is built) |
| 415 | unsupported content type, no feed found, or an image that cannot be decoded (on Workers also a CMYK JPEG, or one of over 100 scans) |
| 500 | `PROXY_TOKEN` not configured (fail closed; no request is served) |
| 502 | upstream error, with the upstream status in `X-Upstream-Status`, e.g. `Site returned 404 Not Found` |
| 503 | Workers only: two of a format's decoders gave up on broken images and are not yet freed; that format's images wait (`Retry-After: 60`), see 5.8 |
| 504 | upstream timeout |

### 5.4 safefetch

- http and https only; any port.
- Up to 5 redirects, followed by hand, with every hop checked again.
- 10 s upstream timeout. Body caps: 5 MB for HTML and feeds, 10 MB for images,
  enforced while streaming.
- Output cap: 256 KB of gemtext. Past the cap the output ends with the text
  line `(Page truncated)` and sets `X-Truncated: 1`.
- No cookies; no JavaScript.
- Upstream `User-Agent`: `PicoSurfProxy/1 (+https://github.com/PicoDeck/picosurf)`,
  overridable with `USER_AGENT`.
- **Blocked addresses:** loopback, private (RFC 1918), link-local,
  CGNAT 100.64/10, unique local fc00::/7, IPv4-mapped IPv6 forms of all of
  these, unspecified addresses and multicast. Host names `localhost`,
  `*.localhost`, `*.local`, `*.internal`. IP literals are normalised before
  checking, so `2130706433`, `0x7f.1` and `0177.0.0.1` are caught.
  - **Node:** the check runs in the connection's DNS lookup hook (undici
    `Agent` `connect.lookup`), so the checked address is the one connected
    to, which closes the DNS-rebinding gap.
  - **Workers:** Workers cannot reach private networks, so the host name and
    IP literal checks are enough.

### 5.5 HTML to gemtext

Pipeline:
1. Parse with linkedom.
2. Run `@mozilla/readability`. Use the full page when `as=full`, when
   Readability returns null, or when the article's `textContent` is under 500
   characters.
3. Full-page mode removes `script`, `style`, `noscript`, `svg`, `template`,
   `iframe`, `canvas`, `video`, `audio`, `[hidden]` and `[aria-hidden=true]`,
   and keeps `header`, `nav` and `footer`.
4. Walk the DOM and write gemtext, with one blank line between blocks (not
   between consecutive list items or consecutive link lines).

Page header:
```
# <title>
<siteName> - <byline> - <YYYY-MM-DD>     (only the parts Readability found; line left out if none)
```

| HTML | Gemtext |
|---|---|
| `h1`-`h3` | `#`, `##`, `###` |
| `h4`-`h6` | `###` |
| a heading whose text equals the title | dropped |
| `p`, other text blocks | one text line per paragraph, whitespace collapsed; `br` starts a new text line |
| `ul` items | `* item` |
| `ol` items | `* 1. item` |
| nested lists | flattened |
| `blockquote` | `> ` before each paragraph |
| `pre` | ```` ``` ```` fence, alt text from `class="language-x"`, tabs → 4 spaces, contents verbatim apart from ASCII folding |
| inline `code` | text kept in backticks |
| `em`, `strong`, other inline formatting | text only |
| `table` | one text line per row, cells joined with ` \| ` |
| a `<time>` after a link that follows an earlier `<time>` in the same text block | starts a new text line (sites lay out dated lists with CSS: time, link, time, link); times with no link between them (ranges, published/updated pairs) stay on one line; a `<time>` directly followed by an element gets a space after it |
| `img` | `=> <absolute src> [IMG] <alt or "image">`; from `srcset`, the candidate closest to 640w |
| `figcaption` | a text line after the image line |
| inline `a` | link text stays in the block, followed by ` [n]`; after the block, one `=> <url> [n] <link text>` line per link. `n` is unique across the page; repeated URLs within a page reuse their number. |
| a block whose whole text is a single link | a plain `=> <url> <link text>` line, no marker |
| an image inside a link | the image line, then a link line if the link points somewhere other than the image |
| `href` of `#…`, `javascript:`, `mailto:`, `tel:` | link dropped, text kept |
| empty link text | label is the URL's host and path, cut to 60 characters |
| `hr`, embeds, forms | dropped |

### 5.6 ASCII folding (`ascii.ts`)

Applied to all text, titles and link labels. URLs are already ASCII.

1. Replacement table: `‘ ’ ‚ ‛` → `'`, `“ ” „` → `"`, `–` → `-`, `—` → `--`,
   `…` → `...`, `•` and `·` → `*`, `→` → `->`, `←` → `<-`, `≤` → `<=`,
   `≥` → `>=`, `≠` → `!=`, `×` → `x`, `÷` → `/`, `©` → `(c)`, `®` → `(R)`,
   `™` → `(TM)`, `€` → `EUR`, `£` → `GBP`, `¥` → `JPY`, `°` → ` deg`,
   `½ ¼ ¾` → `1/2 1/4 3/4`, non-breaking and other Unicode spaces → space.
2. NFKD normalisation, then strip combining marks (`é` → `e`, `ﬁ` → `fi`).
3. Remove `\p{Extended_Pictographic}`, variation selectors and ZWJ.
4. Remove control characters other than tab and newline.
5. Anything else becomes `?`.

Known v1 limitation: non-Latin scripts render as `?`.

### 5.7 Feeds

- Parse RSS 2.0 and Atom with `fast-xml-parser`.
- Output: `# <feed title>`, then up to 50 items, newest first:
  `=> <absolute item URL> YYYY-MM-DD <item title>`. This matches Gemini's
  convention for subscribable pages.
- Item date: `pubDate`, `published`, `updated` or `dc:date`, as UTC.
  Undated items have no date on the line and keep feed order, after dated
  items.
- Item URL: Atom `link[rel=alternate]` or the first `link`; RSS `link`, else
  `guid` when `isPermaLink` is not false. Items without a URL are skipped.

### 5.8 Images

A `Resizer` interface, `resize(bytes, type) → jpegBytes`, with two
implementations:
- **Workers:** PNGs (every colour type, bit depth and interlacing) stream:
  a zlib inflater in JS writes into a fixed 64 KiB window and each row is
  unfiltered as it arrives, so memory does not depend on the image's size or
  how far its data expands. JPEG and WebP decode with jSquash WASM codecs,
  one long-lived instance each, scaling straight from the decoder's heap with
  no full-size copy; WASM memory never shrinks and is freed only when the
  garbage collector gets to it, so a fresh instance per image would pile up.
  A decode that throws (mozjpeg calls exit() on a broken JPEG) costs the
  instance: the next image gets a new one, and while two dropped instances
  of a codec wait for the garbage collector, that codec's images get 503.
  CMYK and YCCK JPEGs and JPEGs of over 100 scans are refused (415) before
  decoding. GIF uses `omggif` (first frame). A box filter in JS scales the
  image down, and MozJPEG (WASM) encodes it with progressive off. An isolate
  runs one image at a time. Needs no other Cloudflare product.
- **Node:** sharp (`.jpeg({ progressive: false })`).

Output fits within 320×320, keeps the aspect ratio, is never enlarged, and is
quality 75. Images over the resizer's pixel cap are refused (413) before
decoding. The cap is 16 megapixels with sharp. On Workers, to stay inside
the 128 MB isolate, it bounds each long-lived decoder heap: a JPEG may have
as many pixels as its decode fits in 48 MiB (at most 8 megapixels; less for
progressive JPEGs), a WebP as many as fit in 32 MiB (at most 2). PNGs may
have 100 megapixels, at most 100,000 pixels each way, which caps CPU time
rather than memory. GIFs may have 2 megapixels (`proxy/README.md`).

Cloudflare Image Transformations (`fetch(url, { cf: { image } })`) would save
Worker CPU but need the product enabled on a domain you own. It's a possible
later option, not v1.

### 5.9 Proxy code and deployment

```
proxy/
  package.json  tsconfig.json  vitest.config.ts  wrangler.toml  Dockerfile
  src/handler.ts      routing, auth, error responses: fetch(Request, env, deps) → Response
  src/worker.ts       Workers entry; WASM resizer; host-name address check
  src/node.ts         node:http adapter; sharp resizer; DNS-hook address check
  src/safefetch.ts    validation, redirect loop, caps; address check injected
  src/page.ts         Readability, full-page fallback
  src/html2gmi.ts     DOM → gemtext (5.5)
  src/ascii.ts        folding (5.6)
  src/feed.ts         RSS/Atom → feed list; feed discovery
  src/img.ts          Resizer interface; img-wasm.ts, img-sharp.ts
  src/png-stream.ts   row-by-row PNG decoder (Workers); src/inflate.ts its zlib inflater
  src/boxscale.ts     box-filter downscale (Workers)
  scripts/smoke.ts    live smoke run (7.1)
  scripts/measure-images.ts  memory of the Workers resizer, behind its caps
  test/
```

Configuration (environment variables):
- `PROXY_TOKEN` (required, Worker secret): suggest `openssl rand -hex 16`.
- `USER_AGENT` (optional).

Deployment:
- **Workers:** `wrangler secret put PROXY_TOKEN`, then `wrangler deploy`.
  Plan on Workers Paid: the free plan's 10 ms CPU per request will not cover
  Readability on a large page or image resizing. The first implementation
  task measures CPU per fixture page to confirm this.
- **Docker:** `docker run -e PROXY_TOKEN=… -p 8080:8080 picosurf-proxy`,
  behind an HTTPS reverse proxy (for example Caddy with Let's Encrypt) so the
  device can use TLS.

## 6. Device app

### 6.1 Fetch layer (`fetch.lua`, `url.lua`)

- The proxy base URL may include a path (`https://host/picosurf/`). It's
  parsed once into host, port, TLS flag and path prefix.
- Requests reuse one keep-alive connection to the proxy; feed refresh opens
  a second.
- `Authorization: Bearer <token>`; `url=` is percent-encoded.
- The body is drained while it arrives, with progress shown via
  `getProgress()`. The device gives up past 512 KB. The read timeout is 20 s.
  Esc cancels by closing the connection.
- Scheme dispatch: `http` and `https` go to the proxy transport. Any other
  scheme gets the toast `<scheme>:// links aren't supported yet`. Gemini and
  Gopher transports slot in here later.

### 6.2 Screens

- **Home:** tabs (`ui.drawTabs`) Feeds, Bookmarks, History. Each is a list;
  Enter opens the item, Del removes it (feeds after `ui.confirm`).
- **Page:** `ui.drawHeader(title)`, the content, and a footer with the host,
  scroll percentage and the mode (`R` reader, `F` full, `L` feed list).
- **Loading:** spinner, host, bytes received; Esc cancels.
- **Error:** status and the proxy's reason; Enter retries, Esc/Backspace goes back.
- **Image:** the JPEG centred on black; Esc/Backspace goes back.
- **Settings** (system menu): Proxy URL, Token, Font, Test connection.

### 6.3 Layout and drawing

- **Fonts:** body `FONT_SCIENTIFICA` (6×12), headings
  `FONT_SCIENTIFICA_BOLD`; rows 13 px apart. Optional large text:
  `FONT_8X12`, with headings marked by colour only since 8×12 has no bold.
  Columns and rows come from the font metrics and the measured header and
  footer heights at runtime (about 52 × 22 with Scientifica). The Font setting
  is the reading font: it applies to page text only. Everything else (title
  bar, footer, tabs, lists, Settings, loading and error screens) uses the
  system font `FONT_6X8`, and each frame ends with it current, because the
  firmware draws toasts, text boxes and the system menu in the current font.
- **Line styles:**
  - Headings use an accent colour, a different one per level.
  - List items get a bullet with a hanging indent.
  - Quotes get a two-column indent with a bar on the left.
  - Links use a link colour; `[IMG]` links have their own colour.
  - Preformatted lines are cut at the right edge and continued on the next
    row after a dim `\`.
- **Wrapping:** `layout.lua` wraps once per page load or font change, using
  an injected wrap function (`ui.wrapText` on the device, a Lua version in
  tests). Rows are stored as parallel integer arrays (source line, start
  byte, end byte, style, link index), not copied strings.
- **Drawing:** redraw only when state changes. The idle loop calls
  `input.update()` and sleeps about 16 ms.

### 6.4 Keys

These keys apply on the Page screen unless a row says otherwise. Home lists
use Up/Down, Enter and Del (6.2), Left/Right switch tabs, and F1 and F5 work
as below.

| Key | Action |
|---|---|
| Up / Down | select the previous / next link (in page order) if it is on screen or within 3 rows of the screen's edge, scrolling just enough to show it whole; otherwise scroll one row. A list is walked link by link, text scrolls, and a link coming into view is picked up on the way, in either direction. A selection scrolled off screen this way is dropped |
| Left / Right, Space | page up / page down; when the selection leaves the screen, the topmost visible link is selected, preferring one that starts on screen over the tail of a wrapped link |
| Tab / Shift+Tab | select the next / previous link among visible rows, wrapping round; a wrapped link highlights all its rows. A page opens with its topmost visible link selected |
| Enter | open the selected link (does nothing when none is selected) |
| 0-9 | build a link number, shown in the footer (`Link: 12_`); Enter opens `[n]`; Backspace deletes a digit; Esc clears the number |
| Backspace / Esc (no number being typed) | Back; on the first page in the stack, go Home; on Home, Esc exits |
| F1 | Go: `ui.textInput("Go to:")`; `https://` added when there's no scheme; input with spaces → toast `Not a URL (search isn't supported yet)` |
| F2 | Home |
| F3 | add or remove a bookmark (toast) |
| F4 | switch reader / full and reload |
| F5 | on a page with `X-Feed-Url` or a feed list: Subscribe; on the Feeds tab: refresh all |

System menu items (`sys.addMenuItem`): Reload, Edit URL (pre-filled when the
URL is 128 characters or less, otherwise a toast), Mark all read (in a feed),
Settings.

### 6.5 Navigation and history

- **Back stack:** up to 20 entries of `{url, mode, scroll, selected}`. The
  bodies of the 3 most recent pages stay in memory; older entries are
  fetched again on Back.
- **History tab:** each successful load records `X-Final-Url` and `X-Title`.

### 6.6 Storage

Files live in `/data/net.picodeck.picosurf/`.

| File | Contents | Cap |
|---|---|---|
| `config.json` (`picocalc.config`) | `proxy_url`, `token`, `font` | — |
| `bookmarks.json` | `[{url, title}]`, newest first | 200 |
| `history.json` | `[{url, title}]`, newest first, revisits move to the top | 100 |
| `feeds/index.json` | `{next_id, feeds: [{id, url, title, fetched_at, unread}]}` | 50 feeds |
| `feeds/<id>.json` | `{items: [{url, date, title}], seen: [url…]}` | 50 items |

- **Safe writes:** write `<name>.tmp`, delete `<name>`, rename `<name>.tmp`
  to `<name>`. When loading, a missing `<name>` with a `<name>.tmp` present
  uses the `.tmp`.
- **Corrupt JSON:** rename the file to `<name>.bad`, start empty, show a toast.
- **Timestamps:** `fetched_at` is `getClock().epoch`, stored and compared as
  an integer.

### 6.7 Feeds and unread tracking

- **Subscribe:** F5 sends `as=feed` with the current URL. The proxy finds the
  feed if the URL is a homepage. The feed is stored under its `X-Final-Url`
  and `X-Title`. All of its items start unread.
- **Refresh one feed:** replace `items` with the latest list (up to 50),
  prune `seen` to URLs still in `items`, recompute `unread`, update
  `fetched_at`.
- **Unread:** an item whose URL is not in `seen`. Opening an article from a
  feed's list marks it read. Mark all read is in the system menu.
- **When feeds refresh:**
  - Opening the Feeds tab shows saved state immediately, offline included.
  - F5 refreshes all feeds, two requests at a time, with progress in the
    footer; Esc cancels the rest.
  - Opening a single feed refreshes it if `fetched_at` is more than 30
    minutes old.
- **Display:**
  - Feeds are sorted by their newest item date and shown as `Title (unread)`.
  - Inside a feed, unread items are marked `*` and read items are dimmed.
  - Articles open in reader mode.

### 6.8 Settings and first run

- **First run:** with no `proxy_url`, open Settings with a short explanation
  that points to the repo's proxy setup section.
- **Fields:** Proxy URL and Token use `ui.textInput`, so each is at most 128
  characters. Font switches between Scientifica and 8×12.
- **Test connection:** calls `/v1/ping` and shows the result.
- **Plain `http://` proxy URLs** are allowed for local development, with a
  warning that the token is sent unencrypted.
- **Config file:** the token can also be set by editing `config.json` on a
  computer.

### 6.9 Errors

| Situation | Behaviour |
|---|---|
| WiFi not connected | "Connecting to WiFi..." screen; Esc goes Home (saved feeds, bookmarks and history still usable) |
| Clock not set (the TLS error starts with `clock not set`) | "Waiting for time sync...", retries every 3 s |
| Proxy error status | error screen with status and reason; a 401 shows `Proxy rejected the token - check Settings` |
| No response in 20 s | error screen `Proxy did not respond` |
| Out of memory while parsing or laying out (`pcall`) | clear the cached page bodies, `collectgarbage()`, retry once, then show `Page too large for memory` |
| Image decode fails | error screen with the image URL |
| Corrupt storage file | 6.6 |

## 7. Testing

### 7.1 Proxy (vitest; the Workers runtime through `@cloudflare/vitest-pool-workers` for `worker.ts`)

**Unit tests:**
- `html2gmi`: one hand-written HTML file per rule in 5.5, with the expected
  gemtext.
- `ascii`: every entry in the replacement table; NFKD cases; emoji removal;
  the `?` fallback.
- `feed`: RSS 2.0, Atom, mixed and malformed dates, missing links, discovery
  from HTML.
- `safefetch`: every blocked range in IPv4 and IPv6; IPv4-mapped IPv6;
  decimal, hex and octal IP spellings; redirect to a blocked address;
  redirect limit; body caps while streaming; the Node lookup hook rejecting
  a host name that resolves to a private address.
- `handler`: missing token, wrong token, unset `PROXY_TOKEN`, bad `url`, each
  error status in 5.3.
- `img`: each input format gives a baseline JPEG within 320×320; over the
  resizer's pixel cap gives 413.

**Snapshot fixtures** (committed, permissive licences only), page HTML saved
with the expected gemtext:
- `https://en.wikipedia.org/wiki/Gemini_(protocol)` (CC BY-SA): long
  article, tables, references
- `https://developer.mozilla.org/en-US/docs/Web/HTTP/Status` (CC BY-SA):
  docs, tables, code
- `https://picodeck.net/docs/api-tcp/`: our own content (Starlight-generated)

**Live smoke list** (`npm run smoke`): pages are fetched through a local
proxy, and for each one the script reports the mode, output size, link
count and time. Nothing is committed, because these pages are copyrighted.
This default list can be swapped for the author's own reading:
- Pages: `https://news.ycombinator.com/`, `https://lobste.rs/`,
  `https://www.bbc.com/news` plus one current article, one current
  `https://arstechnica.com/` article, `https://jvns.ca/` plus one post,
  `https://github.com/PicoDeck/picodeck`,
  `https://en.wikipedia.org/wiki/Special:Random`
- Feeds: `https://hnrss.org/frontpage`, `https://lobste.rs/rss`,
  `https://jvns.ca/atom.xml`, `https://feeds.bbci.co.uk/news/rss.xml`

### 7.2 App

- **Unit:** `gemtext`, `layout`, `feeds` (pruning, unread counts, sorting)
  and `url` under host Lua and under `lua32` (the device's integer and float
  types), using nova-rail's `tests/run.lua` pattern and Makefile targets.
- **Simulator E2E** (pytest against PicoDeck's simulator, nova-rail's
  pattern). The simulator's networking is libcurl, so tests point the app at
  the Node proxy on `http://localhost`, which fetches fixture HTML served
  locally. They cover:
  - first run opening Settings
  - loading a page; following a link by Tab and by number; Back
  - bookmark add and remove
  - subscribing from a homepage; unread counts going down as articles are opened
  - an image opening full screen
  - proxy error screens (401, 502)
- **Hardware pass** (manual) against the deployed Worker:
  - Open every page and feed on the smoke list.
  - Measure the time to the first screen of the Wikipedia fixture article
    (target under 5 s on home WiFi) and a 10-feed refresh (target under
    20 s).
  - Check that Lua heap free stays above 1 MB after loading the largest page.
  - Missed targets are reported, not hidden.

## 8. Release and distribution

- A GitHub Actions workflow runs the proxy tests and Lua tests on every push.
- A tag builds `picosurf-<version>.zip` from `app.json`, `main.lua`, `src/`
  and the icon (no `proxy/`, no `tests/`) and attaches it to a Release. That
  meets the store's one-ZIP rule.
- The proxy Docker image is built from `proxy/Dockerfile`; publishing it is
  outside v1.

## 9. Later phases

1. **Native Gemini.**
   - Add a `gemini.lua` transport on `picocalc.tcp` (port 1965).
   - Firmware: add `tcp:peerFingerprint()`, the SHA-256 of the peer
     certificate after the handshake on insecure TLS sockets, for TOFU.
     `MBEDTLS_SSL_KEEP_PEER_CERTIFICATE` is already enabled in
     `src/mbedtls_config.h`.
   - Pinned fingerprints go in `/data/<id>/known_hosts.json`.
   - Known gaps: the firmware has TLS 1.2 only, and mbedTLS cannot do
     Ed25519. Before committing, measure handshake success against a sample
     of real Gemini servers.
   - Device-side ASCII folding for content that doesn't come through the proxy.
2. **Gopher, Spartan, Nex, Finger:** more transports that convert to the
   typed-line model.
3. **Public instance:** per-device tokens, rate limits, abuse handling; the
   app's default proxy URL changes.
4. **Web search** through a configurable backend.
5. **Offline save, OPML import, inline images, fonts beyond ASCII, a richer
   format than gemtext** if inline links prove too noisy.

## 10. Risks

| Risk | Mitigation |
|---|---|
| Readability or jSquash misbehaves on linkedom or the Workers runtime | First implementation task is a spike that runs both on the snapshot fixtures under `wrangler dev` and records CPU per page |
| Worker CPU over plan limits | Workers Paid; the Docker build has no CPU limit |
| Sites block the proxy (bot challenges, consent walls, paywalls) | `USER_AGENT` override; smoke list tracks which sites fail |
| JavaScript-built pages come back nearly empty | Out of scope for v1; the full-page toggle at least shows what the HTML has |
| `picocalc.json` turns large integers into floats | Unit test under `lua32` that round-trips an epoch through `json.encode`/`decode`; if it fails, store timestamps as strings |
| Long pages are slow to wrap in Lua | 256 KB cap; time the wrap of the largest fixture in the hardware pass |
