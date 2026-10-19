# PicoSurf on the small web: Gemini and Gopher

Date: 2026-10-17. Status: design, for review.

This amends the main spec, `2026-10-15-picosurf-design.md`, and moves its
section 9 items 1 and 2 (Gemini and Gopher) into scope. Section 14 lists the
sections that change. The measurement behind it is
`docs/research/2026-10-16-gemini-tls-survey.md`.

## 1. Goal

Read Gemini and Gopher natively on the device. The author finds web pages read
through Readability "pretty rough". Gemini pages are written as gemtext, the
format PicoSurf already renders, so they need no conversion. Gopher menus map
onto link lines.

- **What the reader gets:**
  - `gemini://` and `gopher://` URLs open in the page view, typed or followed
    from a link, with Back, history, bookmarks and the cache as for web pages.
  - No proxy is needed for them. The proxy becomes optional, needed only for
    `http(s)`.
  - Certificates are pinned on first use, with a review screen when one
    changes.
  - Search from the Go box, starter bookmarks, and gemlog subscriptions in the
    Feeds tab.
- **Success:**
  - The capsules the survey reached (95% of live ones) open and read cleanly.
  - Gopher menus and text files read well in the reading font, and their ASCII
    art survives.
  - The web path behaves as today when a proxy is set.
- **Not in scope:**
  - Spartan, Nex and Finger. The transport here makes them small later
    additions.
  - Client certificates (Gemini status 6x).
  - TLS 1.3 in the firmware: a separate firmware project. The survey has
    the config and cost.
  - Atom feeds served over Gemini (they need an XML parser on the device).
  - Gopher feeds.
  - Inline pictures on Gemini and Gopher pages: pictures open full screen.
  - Gemini uploads (Titan).

## 2. Units

| Unit | Kind | Job |
|---|---|---|
| `src/tcpfetch.lua` | new, drives sockets | One request over `picocalc.tcp`: connect (plain, or TLS without the CA check), an optional check after connecting and before sending, send, collect until the server closes |
| `src/gemini.lua` | new, pure | Request line, response header, status to result, gemtext post-processing (links made absolute, feed extraction) |
| `src/gopher.lua` | new, pure | Gopher URLs, the request, menus and text files to gemtext |
| `src/textflow.lua` | new, pure | Plain text to gemtext: paragraphs reflowed, art kept monospace (section 8.2) |
| `src/fold.lua` | new, pure | UTF-8 or Latin-1 to ASCII (section 8.1) |
| `src/tofu.lua` | new, store-backed | Pinned certificates in `known_hosts.json` |
| `src/url.lua` | changed | Adds `resolve(base, ref)` (RFC 3986 section 5) and `parts(u)` (scheme, host, port, path, query) |
| `src/app.lua` | changed | Scheme dispatch in `request`, the `input` and `certchanged` results, no-proxy rules, search, starter bookmarks, native images |
| `src/screens/cert.lua` | new screen | The certificate-changed review |
| `src/screens/settings.lua` | changed | The Search row, the no-proxy note |
| firmware `tcp:peerFingerprint()` | new, picodeck repo | Section 10 |

### 2.1 Dispatch

`App:request(target, as, done, fit)` picks the transport by the target's
scheme and keeps its contract:
- it returns a handle `{cancel(), received()}` or nil and a reason;
- it posts exactly one result to the inbox unless cancelled.

| Scheme | Transport |
|---|---|
| `http`, `https` | The proxy pool, as today. Without a proxy: nil, `Web pages need a proxy - set one in Settings` |
| `gemini` | `tcpfetch` + `gemini.lua` |
| `gopher` | `tcpfetch` + `gopher.lua` |
| anything else | `App:open` keeps today's toast `<scheme>:// links aren't supported yet` |

**Results** are the existing kinds (`gemini`, `text`, `image`, `error`) with
the existing fields (`body`, `finalUrl`, `title`), plus:
- `mode = "native"` on results from these transports;
- `native = true` on images (section 9.7);
- two new kinds:
  - `input`: `{prompt, sensitive, url}`, the server asks for text (section 5);
  - `certchanged`: `{host, port, old, new, firstSeen, url}` (section 6).

The `as` argument:
- `"feed"` asks for the feed extraction of section 9.6;
- `fit` is ignored by the native transports.

## 3. Transport (`tcpfetch.lua`)

```lua
handle, err = tcpfetch.get(tcp, {
  host = "example.org", port = 1965, tls = true,
  request = "gemini://example.org/\r\n",
  check = function(conn) return true end,   -- or false, result: stop before sending
}, done)  -- done(ok, bytesOrError, checkResult)
```

- **Socket:**
  - `tcp.new(host, port, tls)`.
  - For TLS, `setInsecure(true)`: no CA chain and no wait for the clock; the
    certificate is pinned instead.
  - `setConnectTimeout(20)`; the connect timeout covers the handshake, which
    the survey measured at up to 4.5 s.
  - `setReadTimeout(20)`, which the firmware counts from the last data
    received.
- **Connected:** `check(conn)` runs first. Returning `false, r` closes the
  socket without sending anything, and `done` gets `r`. Otherwise the request
  is written.
- **Body:**
  - The read callback drains every available byte into parts.
  - The body ends when the server closes. Data already received stays
    readable after a close, so the close handler drains once more.
- **Cap:** 512 KB, the same as the proxy path. Past it the socket closes and
  the result is `Page too large (over 512 KB)`.
- **Callbacks:** as in `http.lua`, the firmware runs them inside its service
  pass, so they only record. Results go to the app's inbox.
- **`received()`** gives the byte count for the loading screen.
- **`cancel()`** closes the socket; no result follows.
- **No free socket:** the firmware has 4 TCP sockets. When `tcp.new` returns
  nil, the request fails with `Busy: try again`.
- **Failure messages** come from the firmware's reason (section 11).

## 4. Gemini (`gemini.lua`)

- **Request:** the absolute URL, then CRLF.
  - An empty path becomes `/`.
  - The host is lower-cased, and port 1965 is dropped from the URL.
  - A URL over 1024 bytes fails before connecting: `URL too long for Gemini`.
- **Header:**
  - `<two digits><space><meta>` up to the first CRLF. A bare LF is accepted.
  - The meta is at most 1024 bytes.
  - No CRLF within 1029 bytes, or no two-digit status, gives
    `Not a Gemini response`.
- **Statuses:**

| Status | Result |
|---|---|
| 10, 11 | `input`, with the meta as the prompt; `sensitive` for 11 |
| 20 `text/gemini` | `gemini`: body folded and its links made absolute (section 8.3); title from the first `#` heading, else the host |
| 20 other `text/*` | `gemini`: body through `textflow` (section 8.2) |
| 20 `image/jpeg`, `image/png`, `image/gif`, `image/bmp` | `image`, `native = true` |
| 20 anything else | `error`: `Can't show <type> files` |
| 30, 31 | Redirect: the meta is resolved against the current URL and followed (section 4.1) |
| 40-43 | `error`: `<meta> (<status>)`, or `Temporary failure (<status>)` when the meta is empty |
| 44 | `error`: `Server asks to wait <meta> s` |
| 51 | `error`: `Not found` |
| other 5x | `error`: `<meta> (<status>)`, or `Permanent failure (<status>)` |
| 6x | `error`: `This page needs a client certificate, which PicoSurf doesn't support` |
| anything else | `error`: `Not a Gemini response` |

- **Charset:**
  - The `charset` parameter of `text/*` selects the decoding: `utf-8` (the
    default) or `us-ascii`.
  - `iso-8859-1`, `latin1` and `windows-1252` are decoded as Latin-1.
  - Anything else is treated as UTF-8.
  - Invalid UTF-8 falls back to Latin-1 for the whole body.

### 4.1 Redirects

- Up to 5 hops. The sixth gives `error`: `Too many redirects`.
- A redirect to another `gemini://` URL is fetched in place.
- A redirect to any other scheme ends the fetch with a result that names the
  target. `App` then opens it through the normal dispatch: `https` goes to the
  proxy, or to its no-proxy message. The hop count carries over.
- `finalUrl` is the URL after the last hop.

## 5. Input

- **Status 10 or 11, on a page open:**
  - The app shows `ui.textInput(prompt)`. The prompt is cut to the dialog's
    width; an empty prompt reads `Input:`.
  - On OK it opens the same URL with its query replaced by the text,
    percent-encoded with `url.encode`.
  - On Esc the screen stays as it was.
- **Sensitive input (11):** `ui.textInput` cannot mask what you type. This is
  a known limitation, noted in the README.
- **Long input:** `ui.textInput` takes at most 128 characters.
- **Feed refresh or subscribe:** an `input` result fails the feed with
  `Feed asks for input`.
- **Gopher searches** produce the same `input` result (section 7), with
  `Search:` as the prompt.

## 6. Certificate pinning (`tofu.lua`)

- **Store:** `known_hosts.json`, a map `"host:port"` → `{fp, first, seen}`.
  - `fp` is the lowercase hex SHA-256 of the certificate.
  - `first` and `seen` are clock epochs (0 before time sync).
  - At most 500 entries; the least recently seen is dropped.
  - It follows the main spec 6.6 safe-write and corrupt-file rules. A
    corrupt file starts empty, so every host is pinned afresh. That is
    logged, with the usual toast.
- **The check, run by `tcpfetch` before sending:**

| Fingerprint | Action |
|---|---|
| nil (firmware without the call, or a simulator build without it) | Continue unpinned. The first time in a session, log `picosurf: pinning unavailable` |
| host not in the store | Pin it (`first` = `seen` = now), continue |
| matches | Update `seen`, continue |
| differs | Stop before sending; result `certchanged` |

  Checking before the request is written means a search query never reaches a
  server whose certificate changed.
- **The review screen (`cert`), shown for a `certchanged` result on a page
  open:**
  - Header `Certificate changed`.
  - Text: `The certificate for <host> has changed since <date first seen>.
    Sites do this when they renew; it can also mean someone is intercepting
    the connection.` The date is `YYYY-MM-DD`, or `your first visit` when
    `first` is 0.
  - The first 16 hex digits of the old and the new fingerprint.
  - Footer `Enter trust new  Esc back`.
  - Enter stores the new fingerprint (`first` = now) and opens the URL again.
  - Esc or Backspace returns to the previous screen.
- **Feed refresh:** never shows the screen. That feed fails with
  `Certificate changed - open it to review`. Opening the feed from the Feeds
  tab, when stale, then shows the screen.
- **Writes:** the store is saved after each new pin or acceptance; `seen`
  alone is saved at most once a minute. Saving is done by the app outside the
  firmware callbacks.

## 7. Gopher (`gopher.lua`)

- **URLs:** `gopher://host[:port]/<type><selector>[%09<search>]`.
  - The port defaults to 70.
  - An empty path is type `1` with an empty selector.
  - The selector and search are percent-decoded for the request.
- **Request:** the selector, a tab and the search when there is one, then
  CRLF, over plain TCP.
- **By the item type in the URL:**

| Type | Result |
|---|---|
| `1`, or none | A menu: `gemini` result (below) |
| `0` | Text: `gemini` result through `textflow`, after dropping a final `.` line |
| `7` without a search | `input` (`Search:`); the app reopens the URL with `%09` and the text |
| `7` with a search | Its reply is a menu |
| `g`, `I`, `p` | `image`, `native = true` |
| `h` with a `URL:` selector | Handled at the link (below); requested directly, it gets the HTML as text |
| anything else | `error`: `Can't open this kind of Gopher item` |

- **Menu lines:** `<type><display>\t<selector>\t<host>\t<port>`, until a line
  that is `.`. Lines with fewer fields are shown as text.

| Item type | Gemtext |
|---|---|
| `i` | Runs of consecutive `i` lines become one ``` block, so banners and art stay monospace |
| `0`, `1` | `=> gopher://host:port/<type><selector> <display>` |
| `7` | The same link, labelled `[?] <display>` |
| `g`, `I`, `p` | The same link, labelled `[IMG] <display>` |
| `h` with `URL:<url>` | `=> <url> <display>` (the URL as given) |
| `9`, `5`, `s`, `d` | The same link, labelled `[BIN] <display>`; following it toasts `Can't open binary files` |
| `8`, `T` | The same link, labelled `[TEL] <display>`; following it toasts `Telnet isn't supported` |
| `3` | The display string as a text line |
| any other | The display string as a text line |

  - Port 70 is dropped from generated URLs.
  - Selector bytes outside unreserved ASCII are percent-encoded.
- **Encoding:** UTF-8 when the whole reply is valid UTF-8, else Latin-1, then
  folded (section 8.1).
- **Title:** `host` plus the selector, cut to 60 characters, for example
  `gopher.floodgap.com/v2`.
- **Empty reply:** `error`: `Empty response from <host>`.
- **Gopher+** attributes are ignored.

## 8. Text

### 8.1 ASCII folding (`fold.lua`)

The device's fonts are ASCII only. The proxy folds web text (main spec 5.6);
native text is folded on the device.

- **Input:** valid UTF-8, or Latin-1 when the caller says so (section 4, 7).
  A body with no byte of 0x80 or above is returned unchanged.
- **Replacements:**
  - The proxy's table from main spec 5.6 step 1.
  - Latin-1 Supplement and Latin Extended-A letters fold to their base
    letters: `é` → `e`, `ß` → `ss`, `æ` → `ae`, `Œ` → `OE`, `ø` → `o`,
    `ł` → `l`. This replaces the proxy's NFKD step, which Lua cannot do.
  - Box drawing (U+2500-257F) folds by shape: horizontals → `-`, verticals →
    `|`, corners and joins → `+`. Block elements (U+2580-259F) → `#`.
- **Removed:**
  - combining marks (U+0300-036F);
  - variation selectors (U+FE00-FE0F);
  - zero-width joiners and spaces (U+200B-200D, U+2060, U+FEFF);
  - pictographs (U+1F000-1FAFF, U+2600-27BF);
  - control characters other than tab and newline. A CR before a newline
    stays for the gemtext parser.
- **Everything else:** `?`.

### 8.2 Plain text to gemtext (`textflow.lua`)

Used for Gopher text files and Gemini `text/*` other than `text/gemini`.

- The text splits into blocks at blank lines (lines of spaces only count as
  blank).
- A block is **art** when any of its lines:
  - has a run of 3 or more spaces after its first non-space character;
  - has a run of 4 or more of the same non-alphanumeric, non-space character
    (`----`, `====`, `....`);
  - had box-drawing or block characters before folding;

  or when every line starts with a space or tab. Art blocks become ```
  blocks, unchanged.
- A block where every line is under 45 characters is **short lines**: each
  line becomes its own text line. This covers poems, addresses and lists.
- Any other block is **prose**: its lines are joined with single spaces into
  one text line. A line starting with `* `, `- `, `+ `, or a number then `. `
  starts a new text line.
- Blank lines between blocks become one blank line.
- Tabs become 4 spaces (as `gemtext.lua` does today).

### 8.3 Links in native gemtext

- Each `=>` line's URL is resolved against `finalUrl` with `url.resolve`.
- Bytes of 0x80 or above in the URL are percent-encoded; the label is
  folded.
- An empty label gets the URL.
- The rewritten body is what the cache, history and Back see, so a page's
  links are absolute everywhere downstream.

## 9. App behaviour

### 9.1 Without a proxy

- **First run:** with no `proxy_url`, PicoSurf opens Home instead of
  Settings.
- **Settings note** while no proxy is set: `Web pages need a PicoSurf proxy
  (setup: github.com/PicoDeck/picosurf). Gemini and Gopher work without one.`
  This replaces the first-run note.
- **An `http(s)` page, link or Go:** the toast `Web pages need a proxy - set
  one in Settings`.
- **Feeds of websites** fail their refresh with the same reason.
- **The loading screen's clock wait** (main spec 6.9) applies only to proxy
  requests over `https`. Native TLS does not check dates, so it never waits.

### 9.2 Go (F1) and search

`url.normalize(text, opts)` decides what was typed, in this order:

1. **Contains `://`:** the URL as typed.
2. **No spaces and contains a dot:** a host. Prefix `https://` when a proxy is
   set, otherwise `gemini://`.
3. **Anything else:** a search.
   - With the Search setting empty, the toast `Not a URL` (as today).
   - Otherwise the query is the text percent-encoded, and the search URL is:
     - the Search URL with `%s` replaced by the query, when it contains `%s`;
     - the Search URL plus `%09` and the query, for `gopher://`;
     - the Search URL plus `?` and the query, otherwise.

### 9.3 Settings

- **Rows:** Proxy URL, Token, Font, Images, Search, Test connection.
- **Search:**
  - The label reads `Search: <url without scheme>`, or `Search: (off)`.
  - Enter edits it with `ui.textInput("Search URL:", current)`. An empty
    answer turns search off.
  - Config key `search`. Missing means `gemini://tlgs.one/search`.
- **Test connection** without a proxy toasts `Set the proxy URL first`, as
  today.

### 9.4 Starter bookmarks

- **When:** once, when `prefs.json` has no `starters` (nor config, where an
  older version kept it). Then it is set, so a device that already has
  bookmarks gets them too, exactly once.
- **Where:** appended after the existing bookmarks, skipping any URL already
  there, within the 200 cap.

| Title | URL |
|---|---|
| Gemini project | `gemini://geminiprotocol.net/` |
| Cosmos (gemlogs) | `gemini://cosmos.skyjake.fi/` |
| CAPCOM (gemlogs) | `gemini://gemini.circumlunar.space/capcom/` |
| TLGS search | `gemini://tlgs.one/` |
| Floodgap Gopher | `gopher://gopher.floodgap.com/` |
| Veronica-2 search | `gopher://gopher.floodgap.com/7/v2/vs` |

All six answered on 2026-10-16.

### 9.5 Pages

- **Footer:** native pages show no mode letter. Web pages keep `R`, `F` and
  `L`.
- **F4:** on a native page, toasts `Reader mode is for web pages`.
- **F5:**
  - On a Gemini page: subscribe (section 9.6).
  - On a Gopher page: toasts `Feeds aren't supported for Gopher`.
- **Cache, Back, history and bookmarks:** unchanged. A cached native page
  opens with no handshake.
- **Following links:**
  - `[BIN]` and `[TEL]` Gopher links give their toasts without a request.
  - Any other link opens through `App:open`.
- **The loading screen** shows `Loading <host>` and the bytes received, as
  today.

### 9.6 Gemlog feeds

- **Extraction:** a Gemini request with `as = "feed"` keeps only link lines
  whose label starts with a date `YYYY-MM-DD` followed by a space. It
  returns them as `=> <absolute url> <date> <title>`, with any leading `- `,
  `: ` or `– ` stripped from the title. That is the list `gemtext.feedItems`
  already reads from the proxy, so the feed store, unread tracking and Feeds
  tab are unchanged.
- **Title:** the page's first `#` heading.
- **No dated link:** `error`: `No dated posts here - not a gemlog`.
- **Subscribe** (F5) uses the page's URL. **Refresh** goes through the same
  dispatch, so gemlogs refresh with no proxy.
- **Other failures:** an `input` or `certchanged` result fails the feed as
  in sections 5 and 6.

### 9.7 Native images

Pictures from Gemini and Gopher come at full size, not shrunk by the proxy.

- **Loading:**
  1. The body is written to `/data/net.picodeck.picosurf/image.tmp`.
  2. `graphics.image.getInfo` reads its size.
  3. An image of 320×320 or smaller loads with `loadFromBuffer`. A larger
     one loads with `loadScaled` to fit 320×320, keeping its aspect.
  4. The file is deleted afterwards.
- **Failure:** any failure gives `Image too large to show (<w>×<h>)`, or
  `Could not decode the image` when the size is unknown.
- **Screen:** the image screen draws it centred, as today.

## 10. Firmware: `tcp:peerFingerprint()` (picodeck repo)

- **API:** `tcp:peerFingerprint()` returns the lowercase hex SHA-256 of the
  server's certificate (DER), or nil:
  - for a plain TCP socket;
  - before the handshake completes;
  - when the server sent no certificate.

  It works with and without `setInsecure`. Documented in `docs/API-TCP.md`
  in the same commit.
- **Device:**
  - `tcp_conn_t` gains `char fingerprint[65]`, cleared by `tcp_connect`.
  - On Core 1, in the `MG_EV_TLS_HS` branch of `tcp.c`, before the
    connected state is stored, the certificate from
    `mbedtls_ssl_get_peer_cert` is hashed with `mbedtls_sha256`.
    `MBEDTLS_SSL_KEEP_PEER_CERTIFICATE` is already on.
  - The Lua bridge reads the field once it sees the socket connected, the
    same ordering `err` uses.
  - No new `tcp_*` function, so the browser demo (web-sim) needs no stub.
  - Lua only: the native `PicoCalcAPI` is unchanged.
- **Simulator (`sim_tcp.c`):**
  - Honour `setInsecure`. Today it always verifies, which makes a self-signed
    test server unreachable.
  - Fill the fingerprint from curl's certificate info (`CURLOPT_CERTINFO`)
    with a host SHA-256. The plan chooses the source.
  - A libcurl without certificate info leaves it nil.
- **Tests:** a picodeck simulator e2e test against a local self-signed TLS
  server:
  - the fingerprint equals OpenSSL's `x509 -fingerprint -sha256`;
  - nil on a plain socket;
  - `setInsecure` connects to a self-signed server.
- **Delivery:**
  - A branch off `develop`, merged into `develop` and the author's
    `docs/update-2026-10` branch, as with the system-UI font fix.
  - Flashing the device and pushing to GitHub wait for the author's go-ahead.
  - The app works without it, unpinned (section 6).

## 11. Errors

| Situation | Behaviour |
|---|---|
| DNS failure, refused, unreachable | `Could not connect to <host>`; the firmware's reason is logged |
| No connection or handshake within 20 s | `<host> did not respond` |
| TLS handshake fails | `Secure connection to <host> failed (it may need TLS 1.3 or an Ed25519 certificate)` |
| No data for 20 s after connecting | `<host> stopped responding` |
| Server closes before a Gemini header, or a bad header | `Not a Gemini response` |
| Empty Gopher reply | `Empty response from <host>` |
| Body over 512 KB | `Page too large (over 512 KB)` |
| More than 5 redirects | `Too many redirects` |
| No free TCP socket | `Busy: try again` |
| Certificate changed | The review screen (section 6); in a feed refresh, that feed fails |
| Input asked in a feed refresh or subscribe | That feed fails: `Feed asks for input` |
| `known_hosts.json` corrupt | Main spec 6.6: renamed `.bad`, start empty, toast |
| `[BIN]` or `[TEL]` Gopher link | Toast, no request |
| `http(s)` without a proxy | Toast `Web pages need a proxy - set one in Settings` |
| Out of memory while parsing or laying out | Main spec 6.9: collect and retry once |
| Esc while loading | Cancels by closing the socket |

All errors on a page open use the existing error screen (Enter retries, Esc
or Backspace goes back) and are logged.

## 12. Testing

### 12.1 Host tests (`make test`, both Luas)

- **`gemini`:**
  - header parsing: CRLF, bare LF, no terminator, long meta;
  - every status row of section 4;
  - redirect chains, the 6th hop, a redirect to itself, cross-scheme;
  - charset selection;
  - link rewriting;
  - feed extraction: dated and undated links, separators, none.
- **`gopher`:**
  - URL parsing with ports, types, `%09` searches and percent-encoding;
  - every menu item type;
  - the `.` terminator, and lines with missing fields;
  - Latin-1 replies.
- **`textflow`:** each block rule; a prose paragraph with a bullet; mixed
  art and prose; tabs.
- **`fold`:** the table, accented letters, box drawing, removals, invalid
  UTF-8 with the Latin-1 fallback, ASCII fast path, a link line's URL.
- **`url.resolve`:** the RFC 3986 section 5.4 normal and abnormal examples,
  and `gemini://` and `gopher://` bases.
- **`tofu`:** pin, match, mismatch, the 500-entry cap, the `seen` write rate,
  a corrupt file, a nil fingerprint.
- **`tcpfetch`, against a fake `picocalc.tcp` in `tests/fakepc.lua`:**
  - the check runs before anything is written;
  - a body that arrives in parts, and data read after the close;
  - the 512 KB cap, cancel, connect and read failures;
  - no free socket.
- **App:**
  - first run without a proxy goes Home;
  - `http(s)` without a proxy;
  - every F1 rule and the three search URL forms;
  - an input prompt and its reopened URL;
  - certificate changed: trust and back;
  - gemlog subscribe and refresh;
  - starter bookmarks added once, never twice, and skipping duplicates;
  - the F4, F5, `[BIN]` and `[TEL]` toasts;
  - the native image path, small and large;
  - Settings' Search row.

### 12.2 Simulator e2e (`make e2e`)

Local servers in `tests/e2e`: a Python Gemini server with a self-signed
certificate, and a Gopher server.

- open a Gemini page and follow a relative link;
- answer an input prompt;
- restart the server with a new certificate and get the review screen;
- a Gopher menu and a text file;
- subscribe to a gemlog.

The pinning tests skip when the simulator returns no fingerprint (a
simulator without section 10).

### 12.3 Review focus

Inputs the spec implies that nothing else exercises:

| Input | Expected |
|---|---|
| A 300 KB gemtext line | Folds and wraps, or `Page too large for memory` through the retry rule; no hang |
| A body of random bytes | Folded, shown as text with `?`; no error |
| A server that never closes | `<host> stopped responding` after 20 s idle, or the cap |
| A Gopher menu with CRLF, bare LF and no `.` | All three read the same |
| A redirect to the same URL | `Too many redirects` after 5 hops |

### 12.4 Hardware pass (`docs/hardware-pass.md`)

New items:
- time to the first screen of a Gemini page (expect 2-5 s);
- `known_hosts.json` gains the host;
- a Gopher menu and a text file;
- gemlog subscribe and refresh;
- F1 search;
- the starter bookmarks appear once.

## 13. Budgets

- **Sockets:** the firmware's 4 TCP sockets. A page load uses one, a feed
  refresh up to two.
- **Bodies:** at most 512 KB, as on the proxy path. Folding and link
  rewriting make one copy, line by line.
- **`known_hosts.json`:** 500 entries, about 60 KB.
- **Image temp file:** at most 512 KB, deleted after decoding.

## 14. Changes to other specs

- **Main spec:**
  - Section 1 and section 2: Gemini and Gopher are in scope, and the proxy
    is optional.
  - 6.1: the scheme dispatch of section 2.1.
  - 6.2: the Settings rows and the `cert` screen.
  - 6.4: F1 rules (section 9.2); F4 and F5 on native pages.
  - 6.6: `known_hosts.json`, and `prefs.json` (`search`, `starters`).
  - 6.7: gemlog feeds.
  - 6.8: no forced first-run Settings.
  - 6.9: the clock wait only for proxy requests.
  - Section 9: items 1 and 2 are done except Spartan, Nex and Finger.
- **README:**
  - Gemini and Gopher without a proxy;
  - search, starter bookmarks and pinning;
  - the sensitive-input limitation.

## 15. Decisions

| Decision | Chosen by |
|---|---|
| Native transports on the device, not through the proxy | Author, from the approaches |
| Pin certificates, with a new firmware call and a review screen; unpinned on firmware without it | Author |
| Proxy optional; Gemini and Gopher need none | Author |
| Starter bookmarks, F1 search, and a Search setting | Author |
| Gemlog subscriptions in this project | Author |
| Gopher text: reflow prose, keep art monospace; menu info lines monospace | Author |
| Antenna left out of the starters: its domain no longer resolves | Claude, 2026-10-16 check |
| Cross-scheme redirects go through the normal dispatch | Claude |
| Native pages show no footer mode letter | Claude |
| The search URL may contain `%s`; Gopher searches use `%09` | Claude |
| TLS 1.3 stays a separate firmware project | Claude, from the survey (+1.5 points of reach for about 45 KB of code) |
