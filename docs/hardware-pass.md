# Hardware pass (spec 7.2)

Run this on a real PicoCalc with PicoDeck 0.5.0 or later, against the deployed Worker. Record the results in the release notes.

1. Fresh install: PicoSurf opens Settings. Enter the proxy URL and token. **Test connection** shows "Proxy OK".
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

Report any missed target as-is; don't round it.
