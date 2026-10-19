local T = require("tests.t")
local fakepc = require("tests.fakepc")
local App = require("src.app")

local HOME = "# Capsule\n=> sub/page.gmi A page\n=> /search Search\n=> /pic.jpg Picture\n=> /big.jpg Big picture\n"
    .. "=> /away Away\n=> gopher://h.test/ Gopher\n"
local GEMINI = {
    ["gemini://g.test/"] = "20 text/gemini\r\n" .. HOME,
    ["gemini://g.test/sub/page.gmi"] = "20 text/gemini\r\n# Page\n",
    ["gemini://g.test/search"] = "10 Search for\r\n",
    ["gemini://g.test/search?two%20words"] = "20 text/gemini\r\n# Results\n",
    ["gemini://g.test/pic.jpg"] = "20 image/jpeg\r\nJPEG:200x100",
    ["gemini://g.test/big.jpg"] = "20 image/jpeg\r\nJPEG:1600x800",
    ["gemini://g.test/bad.jpg"] = "20 image/jpeg\r\nnope",
    ["gemini://g.test/away"] = "31 https://w.test/\r\n",
    ["gemini://g.test/log/"] = "20 text/gemini\r\n# My log\n=> 2.gmi 2024-02-02 - Second\n=> 1.gmi 2024-01-01 First\n"
        .. "=> / Home\n",
}
local GOPHER = table.concat({
    "iWelcome\t\th.test\t1", "0About\t/about\th.test\t70", "9Archive\t/a.zip\th.test\t70",
    "8BBS\t\th.test\t23", "7Find\t/find\th.test\t70", ".",
}, "\r\n") .. "\r\n"

-- F.routes: this test's copy of GEMINI, which a test may change.
local function boot(opts)
    opts = opts or {}
    local F = fakepc.new()
    F.routes = {}
    for k, v in pairs(GEMINI) do F.routes[k] = v end
    if opts.proxy ~= false then F.config.proxy_url, F.config.token = "https://p.test", "tok" end
    F.config.font = "scientifica"
    F.responder = fakepc.proxy({ ["https://w.test/"] = { title = "W", body = "# W\n" } }, "tok")
    F.tcpServers["g.test:1965"] = { fp = "aa" .. string.rep("0", 62), reply = function(req)
        return F.routes[req:gsub("\r\n$", "")] or "51 Not found\r\n"
    end }
    F.tcpServers["h.test:70"] = { reply = function(req)
        if req == "/about\r\n" then return "About this hole.\r\n.\r\n" end
        if req == "/find\tcats\r\n" then return "0Cats\t/cats\th.test\t70\r\n.\r\n" end
        return GOPHER
    end }
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

-- Enter on link n of the page (by the link number keys).
local function follow(app, F, n)
    app.page.ps.sel = n
    F.press("enter")
    steps(app)
end

return {
    a_gemini_page_opens_and_links_resolve = function()
        local app, F = boot()
        go(app, F, "gemini://g.test/")
        T.eq(app.screenName, "page"); T.eq(app.page.url, "gemini://g.test/"); T.eq(app.page.title, "Capsule")
        T.eq(app.page.mode, "native")
        T.ok(F.hasLog("picosurf: loaded gemini://g.test/ mode=native"))
        T.eq(F.tcpMade[1].insecure, true)
        follow(app, F, 1)
        T.eq(app.page.url, "gemini://g.test/sub/page.gmi")
        T.eq(app.store:history()[1].url, "gemini://g.test/sub/page.gmi")
    end,
    the_footer_has_no_mode_letter = function()
        local app, F = boot()
        go(app, F, "gemini://g.test/")
        local footer
        for _, t in ipairs(F.texts) do if t:find("^%[F%]") then footer = t end end
        T.ok(footer and footer:find("%%$"), "footer ends at the percentage: " .. tostring(footer))
    end,
    back_uses_the_cache = function()
        local app, F = boot()
        go(app, F, "gemini://g.test/")
        follow(app, F, 1)
        F.press("backspace"); steps(app)
        T.eq(app.page.url, "gemini://g.test/"); T.eq(#F.tcpMade, 2, "no third request")
    end,
    pins_are_saved = function()
        local app, F = boot()
        go(app, F, "gemini://g.test/")
        T.ok(F.files["/data/net.picodeck.picosurf/known_hosts.json"], "known_hosts.json written")
        T.eq(app.pins:hosts()["g.test:1965"].fp, "aa" .. string.rep("0", 62))
    end,
    input_prompts_and_reopens_with_the_answer = function()
        local app, F = boot()
        go(app, F, "gemini://g.test/")
        F.inputs[#F.inputs + 1] = "two words"
        follow(app, F, 2)
        T.eq(F.lastPrompt, "Search for"); T.ok(F.hasLog("picosurf: prompt input"))
        T.eq(app.page.url, "gemini://g.test/search?two%20words"); T.eq(app.page.title, "Results")
    end,
    cancelled_input_stays_put = function()
        local app, F = boot()
        go(app, F, "gemini://g.test/")
        follow(app, F, 2)
        T.eq(app.screenName, "page"); T.eq(app.page.url, "gemini://g.test/")
    end,
    a_changed_certificate_is_reviewed = function()
        local app, F = boot()
        go(app, F, "gemini://g.test/")
        F.tcpServers["g.test:1965"].fp = "bb" .. string.rep("1", 62)
        follow(app, F, 1)
        T.eq(app.screenName, "cert")
        local text = F.screenText()
        T.ok(text:find("Certificate changed", 1, true)); T.ok(text:find("g.test", 1, true))
        T.ok(text:find("Old: aa00000000000000", 1, true)); T.ok(text:find("New: bb11111111111111", 1, true))
        T.ok(text:find("Enter trust new", 1, true))
        T.eq(#F.tcpMade[2].writes, 0, "nothing was sent")
        F.press("esc"); steps(app)
        T.eq(app.screenName, "page"); T.eq(app.page.url, "gemini://g.test/")
        follow(app, F, 1)
        F.press("enter"); steps(app)
        T.eq(app.page.url, "gemini://g.test/sub/page.gmi")
        T.eq(app.pins:hosts()["g.test:1965"].fp, "bb" .. string.rep("1", 62))
        T.ok(F.hasLog("picosurf: cert accepted g.test:1965"))
    end,
    old_firmware_loads_unpinned = function()
        local app, F = boot()
        F.tcpOldFirmware = true
        go(app, F, "gemini://g.test/")
        T.eq(app.page.url, "gemini://g.test/"); T.ok(F.hasLog("picosurf: pinning unavailable"))
        T.eq(next(app.pins:hosts()), nil)
    end,
    a_redirect_to_the_web_uses_the_proxy = function()
        local app, F = boot()
        go(app, F, "gemini://g.test/")
        follow(app, F, 5)
        T.eq(app.page.url, "https://w.test/"); T.eq(app.page.title, "W")
    end,
    gopher_menus_text_and_blocked_links = function()
        local app, F = boot()
        go(app, F, "gopher://h.test/")
        T.eq(app.page.mode, "native"); T.eq(app.page.title, "h.test")
        follow(app, F, 2) -- [BIN] Archive
        T.ok(F.hasToast("Can't open binary files")); T.eq(#F.tcpMade, 1)
        follow(app, F, 3) -- [TEL] BBS
        T.ok(F.hasToast("Telnet isn't supported"))
        F.inputs[#F.inputs + 1] = "cats"
        follow(app, F, 4) -- [?] Find
        T.eq(F.lastPrompt, "Search:"); T.eq(app.page.url, "gopher://h.test/7/find%09cats")
        follow(app, F, 1)
        T.eq(app.page.url, "gopher://h.test/0/cats")
    end,
    f4_on_a_native_page_explains = function()
        local app, F = boot()
        go(app, F, "gemini://g.test/")
        F.press("f4"); steps(app)
        T.ok(F.hasToast("Reader mode is for web pages")); T.eq(#F.tcpMade, 1)
    end,
    the_web_needs_a_proxy = function()
        local app, F = boot({ proxy = false })
        app:open("https://w.test/")
        T.ok(F.hasToast("Web pages need a proxy - set one in Settings"))
        app:open("gemini://g.test/")
        steps(app)
        T.eq(app.page.url, "gemini://g.test/")
    end,
    gemini_never_waits_for_the_clock = function()
        local app, F = boot()
        F.synced = false
        go(app, F, "gemini://g.test/")
        T.eq(app.screenName, "page")
    end,
    native_images_open_full_screen = function()
        local app, F = boot()
        go(app, F, "gemini://g.test/")
        follow(app, F, 3)
        T.eq(app.screenName, "image"); T.eq(F.decoded[#F.decoded], "JPEG:200x100"); T.eq(#F.scaled, 0)
        T.eq(F.files["/data/net.picodeck.picosurf/image.tmp"], nil, "the temporary file is deleted")
        F.press("esc"); steps(app)
        follow(app, F, 4)
        T.eq(app.screenName, "image"); T.eq(F.scaled[1].w, 320); T.eq(F.scaled[1].h, 160)
    end,
    a_gemini_page_is_its_own_feed = function()
        local app, F = boot()
        go(app, F, "gemini://g.test/log/")
        F.press("f5"); steps(app)
        T.ok(F.hasLog("picosurf: subscribed 1 gemini://g.test/log/ unread=2"))
        T.eq(app.store:feedIndex().feeds[1].title, "My log")
        local items = app.store:feedData(1).items
        T.eq(#items, 2); T.eq(items[1].url, "gemini://g.test/log/2.gmi"); T.eq(items[1].date, "2024-02-02")
        T.eq(items[1].title, "Second")
    end,
    gemlogs_refresh_without_a_proxy_or_the_clock = function()
        local app, F = boot({ proxy = false })
        go(app, F, "gemini://g.test/log/")
        F.press("f5"); steps(app)
        F.routes["gemini://g.test/log/"] = "20 text/gemini\r\n=> 3.gmi 2024-03-03 Third\n=> 2.gmi 2024-02-02 Second\n"
        F.synced = false
        app:refreshAll(); steps(app)
        T.ok(F.hasToast("Feeds refreshed")); T.eq(app.store:feedIndex().feeds[1].unread, 2)
    end,
    a_web_feed_without_a_proxy_fails_its_refresh = function()
        local app, F = boot({ proxy = false })
        require("src.feeds").subscribe(app.store:feedIndex(), "https://w.test/feed.xml", "W")
        app:refreshAll(); steps(app)
        T.ok(F.hasToast("1 feed failed to refresh: Web pages need a proxy - set one in Settings"))
    end,
    feed_failures_from_native_servers = function()
        local app, F = boot()
        go(app, F, "gemini://g.test/log/")
        F.press("f5"); steps(app)
        F.tcpServers["g.test:1965"].fp = "cc"
        app:refreshAll(); steps(app)
        T.ok(F.hasToast("1 feed failed to refresh: Certificate changed - open it to review"))
        local feed = app.store:feedIndex().feeds[1]
        feed.fetched_at = 0
        app:openFeed(feed); steps(app)
        T.eq(app.screenName, "cert")
        F.press("enter"); steps(app)
        T.eq(app.screenName, "page"); T.eq(app.page.isFeedList, true)
        F.routes["gemini://g.test/log/"] = "10 Who are you\r\n"
        app:refreshAll(); steps(app)
        T.ok(F.hasToast("1 feed failed to refresh: Feed asks for input"))
    end,
    f5_on_gopher_explains = function()
        local app, F = boot()
        go(app, F, "gopher://h.test/")
        F.press("f5"); steps(app)
        T.ok(F.hasToast("Feeds aren't supported for Gopher"))
    end,
    native_images_that_fail = function()
        local app, F = boot()
        F.failScaled = true
        go(app, F, "gemini://g.test/")
        follow(app, F, 4)
        T.eq(app.screenName, "message"); T.ok(F.screenText():find("Image too large to show (1600x800)", 1, true))
        app:open("gemini://g.test/bad.jpg")
        steps(app)
        T.ok(F.screenText():find("Could not decode the image", 1, true))
    end,
}
