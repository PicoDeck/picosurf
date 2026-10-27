# PicoSurf

Read Gemini and Gopher, the web and RSS/Atom feeds on a [PicoDeck](https://picodeck.net) PicoCalc. Gemini and Gopher pages are fetched by the PicoCalc itself. Web pages come through your own **PicoSurf proxy**, which does the heavy lifting:
- fetches the page
- extracts the article with Mozilla Readability
- turns it into plain-ASCII gemtext the PicoCalc can draw
- shrinks images to fit the screen

## Set up
1. Install PicoSurf from the PicoDeck App Store. It opens on Home with a few starter bookmarks for Gemini and Gopher, which need nothing else.
2. For web pages, deploy the proxy: see [proxy/README.md](proxy/README.md), for Cloudflare Workers or Docker.
3. Open Settings from the system menu, enter the proxy URL and token, then choose **Test connection**. You can also put the URL and token in `/data/net.picodeck.picosurf/config.json` from a computer, as `{"proxy_url": "...", "token": "..."}`.

## Keys
| Key | On a page | On Home |
|---|---|---|
| Up / Down | select the previous / next link when one is on screen or just past its edge; otherwise scroll a row | move in the list |
| Left / Right | page up / down | switch tab |
| Space | page down | |
| Tab / Shift+Tab | select the next / previous link on screen, wrapping round | |
| Enter | open the selected link | open |
| digits, then Enter | open link `[n]` (Backspace deletes a digit, Esc clears the number) | |
| Backspace / Esc | back (on the first page: Home) | Esc: quit, or stop a refresh |
| F1 | go to a URL, or search: the box starts with this page's URL (Del clears it) | go to a URL, or search |
| F2 | Home | |
| F3 | bookmark / remove bookmark | |
| F4 | reader / full page (web pages) | |
| F5 | subscribe to the page's feed (the footer shows `F5 feed` when the page names one); on a Gemini page, to its dated posts | refresh all feeds (Feeds tab) |
| Del | | remove the selected entry |

While a page loads, only Esc cancels it. On an error, Enter retries and Esc or Backspace goes back; on an image, Esc or Backspace goes back.

The system menu has Reload, Edit URL, Mark all read and Settings.

**Images** in Settings switches between Links (an `[IMG]` line; Enter opens the picture full screen) and Inline (pictures in the page, loaded as you read; Enter still opens one full screen). Inline needs a proxy from the same version or later: redeploy the proxy when you update.

## Gemini and Gopher
Type a `gemini://` or `gopher://` URL in Go (F1), or follow a link to one. A bare host like `geminiprotocol.net` opens as `https://` when a proxy is set and as `gemini://` when not. Anything else you type is a search: **Search** in Settings holds the search URL (TLGS by default; `%s` in it is replaced by your words, and a `gopher://` search URL gets them as a Gopher search). Leave it empty to turn search off.

PicoSurf pins each Gemini site's certificate on your first visit, in `known_hosts.json`. If it later changes, you see **Certificate changed**: Enter trusts the new one, Esc goes back. Sites change certificates when they renew, but it can also mean someone is intercepting the connection. Pinning needs a PicoDeck firmware with `tcp:peerFingerprint()`; older firmware loads pages without it.

Limits: the firmware speaks TLS 1.2 only and cannot read Ed25519 certificates, so about 5% of Gemini sites won't open (`docs/research/2026-10-16-gemini-tls-survey.md`). A Gemini "sensitive input" prompt shows what you type. Gopher text is reflowed into your reading font, except blocks that look like ASCII art or tables. Pictures from Gemini and Gopher open full screen, shrunk to fit.

**Font** in Settings steps through Scientifica, 8x12, Sans, Serif and System (6x8). Sans is the default: a proportional font that fits about 57 characters a line. System is the smallest: 28 lines a screen. Code blocks always use a monospace font.

## Credits
The Sans and Serif reading fonts are converted from X.Org's Adobe bitmap fonts by `tools/build-fonts.py`; [fonts/LICENSE](fonts/LICENSE) has their licences.
- Sans: Helvetica 12. Copyright 1984-1989, 1994 Adobe Systems Incorporated. Copyright 1988, 1994 Digital Equipment Corporation. Helvetica is a trademark of Linotype-Hell AG and/or its subsidiaries.
- Serif: Utopia 10. Copyright (c) 1989 Adobe Systems Incorporated. Utopia (R) is a registered trademark of Adobe Systems Incorporated.

## Development
- `make test`: Lua unit tests under stock Lua and under `lua32`, which has the device's 32-bit numbers. Building `lua32` needs a PicoDeck checkout; set `PICODECK_ROOT`.
- `make e2e`: runs the smoke tests locally in the PicoDeck simulator, against a fake proxy and local Gemini and Gopher servers. They need a PicoDeck checkout, set by `PICODECK_ROOT` (default `~/Projects/PicoDeck/picodeck`). Run `make simulator` in that checkout first. The F1 "Go to" test types Enter's `\n` through the simulator's control channel, which needs a simulator built with PicoDeck's `fix/sim-enter-char` (JSON strings unescaped); an older one fails that test with a message saying so. The Gemini tests need a simulator whose TLS sockets honour `setInsecure` and report `peerFingerprint()` (PicoDeck's `feat/tcp-peer-fingerprint`).
- The proxy has its own tests: `cd proxy && npm test`.
- Releases: bump `version` in `app.json`, then tag `v<version>`. CI builds the store ZIP, `picosurf-<version>.zip`.

## Later
- Spartan, Nex and Finger. TLS 1.3 in the PicoDeck firmware, for the Gemini sites that need it.
- A longer `ui.textInput` limit, so "Edit URL" works on article URLs over 127 characters.
- Simulator fixes for end-to-end tests: Shift+Tab (key 0xD2) and HTTP back-pressure should behave as on the device.
- Web search, saving pages offline, OPML import, non-Latin fonts.
