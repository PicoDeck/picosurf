# Hardware pass (spec 7.2)

Run this on a real PicoCalc with PicoDeck 0.5.0 or later, against the deployed Worker. Record the results in the release notes.

1. Fresh install: PicoSurf opens Home with the six starter bookmarks. Open Settings from the system menu, enter the proxy URL and token. **Test connection** shows "Proxy OK".
2. F1 `en.wikipedia.org/wiki/Gemini_(protocol)`. Time from Enter to the first screen: ______ s (target under 5 s on home WiFi).
3. On that page: scroll to the end with Right, check the footer reaches 100%, then follow a link by number and by Tab, and go Back.
4. Every page on the proxy's smoke list (`proxy/scripts/smoke.ts`) opens without a Lua error.
5. F3 bookmark, F2 Home, open it from Bookmarks. F4 switches reader and full mode.
6. Open an article with images. An `[IMG]` link opens the picture centred, and Esc returns.
7. F5 on jvns.ca subscribes. Subscribe to 9 more feeds (the smoke list's feeds, plus others).
8. On the Feeds tab, F5 refreshes all 10. Time: ______ s (target under 20 s). Opening an article lowers its unread count.
9. Memory: after the largest page, the dev console's memory figure shows more than 1 MB of Lua heap free: ______.
10. With WiFi off, opening a page shows "Connecting to WiFi..." and Esc goes Home. Feeds, bookmarks and history still list.
11. Reboot: bookmarks, history, feeds and read marks are all still there.
12. Shift+Tab (key 0xD2) selects the previous link.
13. F1, type a URL, Enter on the real keyboard: the page loads. The simulator test types Enter's `\n` char; only the device checks the physical key.
14. A toast clears from the panel within about 3 s, without a keypress.
15. Held keys: Down scrolls repeatedly. F3 held toggles the bookmark once. Esc held while a page loads cancels once.
16. With an https proxy URL, the first load succeeds over TLS.
17. Open a large `[IMG]` image, then check the heap in the dev log: ______.
18. WiFi from cold: power on, then open a page at once. It shows "Connecting to WiFi..." and then loads.
19. Press Esc on 20 loads in a row, then check the heap in the dev log hasn't grown (HTTP callbacks are released): before ______, after ______.
20. Leave it idle for more than 5 minutes, then follow a link. The stale keep-alive connection is retried and the page loads.
21. With WiFi off, open a feed last fetched more than 30 minutes ago. It shows the saved items and the toast "Offline - showing saved items".
22. Settings → Images: Inline. Open an article with 10 or more images. Time until the first picture shows: ______ s. Scroll to the end and back with Right and Left: pictures appear in place, the text you're reading doesn't jump when a picture above it loads, and keys stay responsive. Lowest Lua heap free in the dev log while scrolling, not only at the end: ______ (above 1 MB). On a long page, the worst hitch when a picture arrives: ______ ms. Enter on a picture opens it full screen.
23. Settings → Font: Sans (the default), then Serif. Open the Wikipedia fixture article in each: time to the first screen ______ s / ______ s (target under 5 s, as with Scientifica). Read through a long article: no clipped letters, no line running past the right edge, code blocks in Scientifica. Then System (6x8): 28 lines a screen, no letters cut off at the top or bottom of a row, and the selected link's band covers its line.

24. Small web, on a firmware with `tcp:peerFingerprint()`:
    - Open the Gemini project starter bookmark. Time from Enter to the first screen: ______ s (expect 2-5 s).
    - `/data/net.picodeck.picosurf/known_hosts.json` now has `geminiprotocol.net:1965`; its `fp` equals `openssl s_client -connect geminiprotocol.net:1965 -servername geminiprotocol.net </dev/null | openssl x509 -noout -fingerprint -sha256` (lowercase, colons removed).
    - Follow a few links, then Back: pages come from the cache without a second handshake.
    - Open Floodgap Gopher, then a text file: prose is reflowed, art stays monospace.
    - Open a Gopher or Gemini text of 100 KB or more and scroll to the end: it ends where the file does (compare with a laptop client). A page cut short with no error is a firmware bug (data lost at the server's close); `Connection to <host> was lost` means the app fell 32 KB behind the network.
    - F5 on a gemlog from Cosmos subscribes; F5 on the Feeds tab refreshes it.
    - F1, type `picocalc`: TLGS results open.

Report any missed target as-is; don't round it.
