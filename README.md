# PicoSurf

Read the web and RSS/Atom feeds on a [PicoDeck](https://picodeck.net) PicoCalc. Pages come through your own **PicoSurf proxy**, which does the heavy lifting:
- fetches the page
- extracts the article with Mozilla Readability
- turns it into plain-ASCII gemtext the PicoCalc can draw
- shrinks images to fit the screen

## Set up
1. Deploy the proxy: see [proxy/README.md](proxy/README.md), for Cloudflare Workers or Docker.
2. Install PicoSurf from the PicoDeck App Store.
3. On first launch, PicoSurf opens Settings. Enter the proxy URL and token there, then choose **Test connection**. You can also put the URL and token in `/data/net.picodeck.picosurf/config.json` from a computer, as `{"proxy_url": "...", "token": "..."}`.

## Keys
| Key | On a page | On Home |
|---|---|---|
| Up / Down | scroll a row | move in the list |
| Left / Right | page up / down | switch tab |
| Space | page down | |
| Tab / Shift+Tab | select the next / previous link on screen (the topmost link on screen is selected as you scroll) | |
| Enter | open the selected link | open |
| digits, then Enter | open link `[n]` (Backspace deletes a digit, Esc clears the number) | |
| Backspace / Esc | back (on the first page: Home) | Esc: quit, or stop a refresh |
| F1 | go to a URL | go to a URL |
| F2 | Home | |
| F3 | bookmark / remove bookmark | |
| F4 | reader / full page | |
| F5 | subscribe to the page's feed (the footer shows `F5 feed` when the page names one) | refresh all feeds (Feeds tab) |
| Del | | remove the selected entry |

While a page loads, only Esc cancels it. On an error, Enter retries and Esc or Backspace goes back; on an image, Esc or Backspace goes back.

The system menu has Reload, Edit URL, Mark all read and Settings.

## Development
- `make test`: Lua unit tests under stock Lua and under `lua32`, which has the device's 32-bit numbers. Building `lua32` needs a PicoDeck checkout; set `PICODECK_ROOT`.
- `make e2e`: runs the smoke tests locally in the PicoDeck simulator, against a fake proxy. They need a PicoDeck checkout, set by `PICODECK_ROOT` (default `~/Projects/PicoDeck/picodeck`). Run `make simulator` in that checkout first. The F1 "Go to" test types Enter's `\n` through the simulator's control channel, which needs a simulator built with PicoDeck's `fix/sim-enter-char` (JSON strings unescaped); an older one fails that test with a message saying so.
- The proxy has its own tests: `cd proxy && npm test`.
- Releases: bump `version` in `app.json`, then tag `v<version>`. CI builds the store ZIP, `picosurf-<version>.zip`.

## Later
- Native Gemini and Gopher. Gemini needs a firmware call that returns the server certificate's fingerprint, for trust-on-first-use (TOFU).
- A longer `ui.textInput` limit, so "Edit URL" works on article URLs over 127 characters.
- Simulator fixes for end-to-end tests: Shift+Tab (key 0xD2) and HTTP back-pressure should behave as on the device.
- Web search, saving pages offline, OPML import, inline images, non-Latin fonts.
