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

Report any missed target as-is; don't round it.
