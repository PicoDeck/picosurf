local T = require("tests.t")
local fakepc = require("tests.fakepc")
local App = require("src.app")

local A = "# A\n\nSee the docs [1] and more [2].\n=> https://b.test/ [1] the docs\n=> spartan://s.test/ [2] more\n=> https://a.test/cat.jpg [IMG] Cat\n"
local function longBody()
    local parts = { "# Long" }
    for i = 1, 100 do parts[#parts + 1] = "line " .. i end
    return table.concat(parts, "\n")
end
-- Paragraphs that wrap (2 rows at 52 columns, 3 at 39), each followed by a link.
local function wideBody()
    local parts = { "# Wide" }
    for i = 1, 40 do
        parts[#parts + 1] = "Paragraph " .. i .. " " .. string.rep("lorem ", 12)
        parts[#parts + 1] = "=> https://w.test/" .. i .. " Link " .. i
    end
    return table.concat(parts, "\n")
end
local ROUTES = {
    ["https://a.test/"] = { title = "A", body = A },
    ["https://wide.test/"] = { title = "Wide", body = wideBody() },
    ["https://title.test/"] = { title = string.rep("T", 60), body = "# T\n" },
    ["https://blog.test/"] = { title = "Blog", feed = "https://blog.test/feed.xml", body = "# Blog\n" },
    ["https://b.test/"] = { title = "B", body = "# B\n\nBack page.\n" },
    ["https://a.test/cat.jpg"] = { type = "image/jpeg", mode = false, body = "JPEG-DATA" },
    ["https://a.test/bad.jpg"] = { type = "image/jpeg", mode = false, body = "nope" },
    ["https://long.test/"] = { title = "Long", body = longBody() },
    ["https://cut.test/"] = { title = "Cut", body = "# Cut\n", truncated = true },
    ["https://plain.test/"] = { type = "text/plain; charset=us-ascii", mode = false, body = "just text\n" },
}

local function boot(opts)
    opts = opts or {}
    local F = fakepc.new()
    if opts.config ~= false then
        F.config.proxy_url = opts.proxy or "https://p.test"
        F.config.token = "tok"
    end
    F.config.font = opts.font or "scientifica"
    F.responder = fakepc.proxy(ROUTES, opts.token or "tok")
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

local function hasText(F, text)
    for _, t in ipairs(F.texts) do
        if t == text then return true end
    end
    return false
end

-- Screens other than the page draw everything in the system font (6x8), so
-- the reading font never reaches them: every string (header, footer, tabs,
-- list rows, plain text) is in that font, and plain text fits its 52 columns.
local function assertSystemText(F, label)
    for i, t in ipairs(F.texts) do
        T.eq(F.textFonts[i], F.pc.display.FONT_6X8, label .. ": not in the system font: " .. t)
        if t:sub(1, 1) ~= "[" then T.ok(#t <= 52, label .. ": too wide: " .. t) end
    end
end

-- Settings, then the Font row: switches the font and lays the page out again.
local function toggleFont(app, F)
    F.menu["Settings"](); steps(app, 1)
    F.press("down"); F.press("down"); F.press("enter"); steps(app, 1)
    F.press("esc"); steps(app, 1)
end

-- Runs fn with layout.build raising an out-of-memory error.
local function withoutMemory(fn)
    local layout = require("src.layout")
    local build = layout.build
    layout.build = function() error("not enough memory") end
    local ok, err = pcall(fn)
    layout.build = build
    if not ok then error(err, 0) end
end

return {
    first_run_opens_home_with_starter_bookmarks = function()
        local app, F = boot({ config = false })
        T.eq(app.screenName, "home"); T.ok(F.hasLog("picosurf: starters 6"))
        local b = app.store:bookmarks()
        T.eq(#b, 6); T.eq(b[1].url, "gemini://geminiprotocol.net/"); T.eq(b[6].url, "gopher://gopher.floodgap.com/7/v2/vs")
        T.eq(app.prefs.starters, true); T.ok(F.files["/data/net.picodeck.picosurf/prefs.json"], "prefs.json saved")
        F.menu["Settings"](); steps(app, 1)
        T.ok(F.screenText():find("work without one", 1, true))
    end,
    starters_are_added_once_after_existing_bookmarks = function()
        local F = fakepc.new()
        F.config.proxy_url, F.config.token = "https://p.test", "tok"
        local first = App.new(F.pc, "net.picodeck.picosurf")
        first.store:toggleBookmark("https://mine.test/", "Mine")
        first.store:toggleBookmark("gemini://tlgs.one/", "TLGS")
        first:start()
        local b = first.store:bookmarks()
        T.eq(#b, 7, "two of mine and five starters"); T.eq(b[1].url, "gemini://tlgs.one/"); T.eq(b[2].url, "https://mine.test/")
        first.store:removeBookmark(3)
        local again = App.new(F.pc, "net.picodeck.picosurf")
        again:start()
        T.eq(#again.store:bookmarks(), 6, "a deleted starter stays deleted")
    end,
    starters_and_search_survive_a_full_config = function() -- the device keeps 4 config keys
        local F = fakepc.new()
        F.config.proxy_url, F.config.token, F.config.font, F.config.images = "https://p.test", "tok", "sans", "inline"
        local first = App.new(F.pc, "net.picodeck.picosurf")
        first:start()
        T.eq(#first.store:bookmarks(), 6, "the starters")
        first.store:removeBookmark(1)
        first:savePref("search", "gopher://gopher.floodgap.com/7/v2/vs")
        local again = App.new(F.pc, "net.picodeck.picosurf")
        again:start()
        T.eq(#again.store:bookmarks(), 5, "a deleted starter stays deleted")
        T.eq(again.cfg.search, "gopher://gopher.floodgap.com/7/v2/vs")
        T.eq(F.config.starters, nil); T.eq(F.config.search, nil)
    end,
    settings_saved_in_config_by_an_older_version_still_count = function()
        local F = fakepc.new()
        F.config.proxy_url, F.config.starters, F.config.search = "https://p.test", "1", "off"
        local app = App.new(F.pc, "net.picodeck.picosurf")
        app:start()
        T.eq(#app.store:bookmarks(), 0, "starters were already offered")
        T.eq(app.cfg.search, "")
    end,
    settings_save_url_and_token_and_warn_on_http = function() -- Review Focus 5
        local app, F = boot({ config = false })
        F.menu["Settings"](); steps(app, 1)
        F.inputs = { "http://192.168.1.5:8080/x/" }
        F.press("enter"); steps(app, 1)
        T.eq(F.config.proxy_url, "http://192.168.1.5:8080/x/")
        T.eq(app.base.port, 8080); T.eq(app.base.prefix, "/x")
        T.ok(F.screenText():find("Warning: http:// sends the token unencrypted.", 1, true))
        F.inputs = { "tok" }
        F.press("down"); F.press("enter"); steps(app, 1)
        T.eq(F.config.token, "tok")
        F.press("esc"); steps(app, 1)
        T.eq(app.screenName, "home")
    end,
    test_connection_reports_ok_and_token_errors = function()
        local app, F = boot()
        F.menu["Settings"](); steps(app, 1)
        for _ = 1, 5 do F.press("down") end
        F.press("enter"); steps(app)
        T.ok(F.hasToast("Proxy OK")); T.ok(F.hasLog("picosurf: ping ok"))
        local app2, F2 = boot({ token = "other" })
        F2.menu["Settings"](); steps(app2, 1)
        for _ = 1, 5 do F2.press("down") end
        F2.press("enter"); steps(app2)
        T.ok(F2.hasToast("Proxy rejected the token - check Settings"))
    end,
    font_setting_switches_to_8x12 = function()
        local app, F = boot()
        F.menu["Settings"](); steps(app, 1)
        F.press("down"); F.press("down"); F.press("enter"); steps(app, 1)
        T.eq(F.config.font, "8x12"); T.eq(app.theme.cw, 8)
    end,
    opens_a_typed_url = function()
        local app, F = boot()
        go(app, F, "a.test/")
        T.eq(app.screenName, "page")
        T.ok(F.hasLog("picosurf: loaded https://a.test/ mode=reader links=3"))
        T.ok(F.screenText():find("[H] A", 1, true))
        T.eq(app.store:history()[1].url, "https://a.test/")
    end,
    searches_text_that_is_not_a_url = function()
        local app, F = boot()
        F.tcpServers["tlgs.one:1965"] = { fp = "ff", reply = function() return "20 text/gemini\r\n# Results\n" end }
        go(app, F, "two words")
        T.eq(app.page.title, "Results")
        T.eq(F.tcpMade[1].host, "tlgs.one")
        T.eq(F.tcpMade[1].writes[1], "gemini://tlgs.one/search?two%20words\r\n")
    end,
    the_search_setting_changes_and_turns_off = function()
        local app, F = boot()
        F.menu["Settings"](); steps(app, 1)
        T.ok(F.screenText():find("Search: tlgs.one/search", 1, true))
        for _ = 1, 4 do F.press("down") end
        F.inputs = { "gopher://gopher.floodgap.com/7/v2/vs" }
        F.press("enter"); steps(app, 1)
        T.eq(F.lastPrompt, "Search URL:"); T.eq(app.prefs.search, "gopher://gopher.floodgap.com/7/v2/vs")
        T.ok(F.screenText():find("Search: gopher.floodgap.com/7/v2/vs", 1, true))
        F.inputs = { "  " }
        F.press("enter"); steps(app, 1)
        T.eq(app.prefs.search, "off"); T.eq(app.cfg.search, "")
        T.ok(F.screenText():find("Search: (off)", 1, true))
        F.press("esc"); steps(app, 1)
        go(app, F, "two words")
        T.ok(F.hasToast("Not a URL")); T.eq(#F.tcpMade, 0)
    end,
    follows_the_selected_link_and_comes_back_from_the_cache = function()
        local app, F = boot()
        go(app, F, "a.test/")
        T.eq(app.page.ps.sel, 1, "the first link on screen starts selected")
        F.press("enter"); steps(app)
        T.ok(F.hasLog("picosurf: follow https://b.test/"))
        T.eq(app.page.url, "https://b.test/")
        local before = #F.requests
        F.press("backspace"); steps(app)
        T.eq(app.page.url, "https://a.test/")
        T.eq(#F.requests, before, "back used the cache")
        T.eq(app.page.ps.sel, 1, "selection restored")
        F.press("esc"); steps(app, 1)
        T.eq(app.screenName, "home", "Esc on the first page goes home")
    end,
    opens_links_by_number = function()
        local app, F = boot()
        go(app, F, "a.test/")
        F.type("1"); steps(app, 1)
        T.ok(F.screenText():find("Link: 1_", 1, true))
        F.press("enter"); steps(app)
        T.eq(app.page.url, "https://b.test/")
    end,
    an_unknown_link_number_shows_a_toast = function() -- Review Focus 4
        local app, F = boot()
        go(app, F, "a.test/")
        F.type("9"); F.press("enter"); steps(app, 1)
        T.ok(F.hasToast("No link [9] on this page"))
        T.eq(app.page.url, "https://a.test/")
        F.type("12"); F.press("backspace"); steps(app, 1)
        T.eq(app.page.ps.digits, "1")
        F.press("esc"); steps(app, 1)
        T.eq(app.page.ps.digits, ""); T.eq(app.screenName, "page", "Esc first clears the number")
    end,
    other_schemes_show_a_toast = function()
        local app, F = boot()
        go(app, F, "a.test/")
        F.type("2"); F.press("enter"); steps(app, 1)
        T.ok(F.hasToast("spartan:// links aren't supported yet"))
        T.eq(app.screenName, "page")
    end,
    opens_and_closes_an_image = function()
        local app, F = boot()
        go(app, F, "a.test/")
        F.press("tab"); F.press("tab"); F.press("enter"); steps(app)
        T.eq(app.screenName, "image")
        T.ok(F.hasLog("picosurf: image w=200 h=120"))
        F.press("esc"); steps(app, 1)
        T.eq(app.screenName, "page"); T.eq(app.page.url, "https://a.test/")
    end,
    an_undecodable_image_shows_an_error = function()
        local app, F = boot()
        go(app, F, "a.test/bad.jpg")
        T.eq(app.screenName, "message")
        T.ok(hasText(F, "[H] Error"), "no status, plain title")
        T.ok(F.screenText():find("Could not decode the image", 1, true))
    end,
    esc_cancels_loading_and_ignores_the_late_answer = function() -- Review Focus 2
        local app, F = boot()
        F.holding = true
        go(app, F, "b.test/")
        T.eq(app.screenName, "loading")
        F.press("esc"); steps(app, 1)
        T.eq(app.screenName, "home")
        T.ok(F.hasLog("picosurf: cancelled https://b.test/"))
        F.holding = false
        steps(app)
        T.eq(app.screenName, "home")
        T.ok(not F.hasLog("loaded https://b.test/"))
    end,
    proxy_errors_show_a_message_that_can_retry = function()
        local app, F = boot()
        go(app, F, "missing.test/")
        T.eq(app.screenName, "message")
        T.ok(F.screenText():find("Site returned 404 Not Found", 1, true))
        T.ok(F.hasLog("picosurf: error 502 Site returned 404 Not Found"))
        T.ok(hasText(F, "[H] Error 502"), "the title has the status")
        local before = #F.requests
        F.press("enter"); steps(app)
        T.eq(#F.requests, before + 1)
        F.press("esc"); steps(app, 1)
        T.eq(app.screenName, "home")
    end,
    a_wrong_token_says_so = function()
        local app, F = boot({ token = "other" })
        go(app, F, "a.test/")
        T.ok(F.screenText():find("Proxy rejected the token - check Settings", 1, true))
    end,
    waits_for_the_clock_before_tls = function()
        local app, F = boot()
        F.synced = false
        go(app, F, "a.test/")
        T.eq(app.screenName, "loading")
        T.ok(F.screenText():find("Waiting for time sync...", 1, true))
        T.eq(#F.requests, 0)
        F.synced = true
        F.ms = F.ms + 3000
        steps(app)
        T.eq(app.screenName, "page")
    end,
    waits_for_wifi_and_reports_missing_wifi = function()
        local app, F = boot()
        F.netStatus = 0
        go(app, F, "a.test/")
        T.ok(F.screenText():find("Connecting to WiFi...", 1, true))
        F.netStatus = 1
        steps(app)
        T.eq(app.screenName, "page")
        local app2, F2 = boot()
        F2.netStatus = 2
        go(app2, F2, "a.test/")
        T.ok(F2.screenText():find("WiFi not available", 1, true))
    end,
    bookmarks_toggle_and_list_on_home = function()
        local app, F = boot()
        go(app, F, "a.test/")
        F.press("f3"); steps(app, 1)
        T.ok(F.hasToast("Bookmarked")); T.ok(app.store:isBookmarked("https://a.test/"))
        T.ok(F.hasLog("picosurf: bookmark add https://a.test/"))
        F.press("f2"); F.press("right"); steps(app, 1)
        T.eq(app.screenName, "home")
        T.ok(F.screenText():find("[>] A", 1, true))
        F.press("enter"); steps(app)
        T.eq(app.page.url, "https://a.test/")
        F.press("f3"); steps(app, 1)
        T.ok(F.hasToast("Bookmark removed"))
    end,
    home_tabs_history_and_delete = function()
        local app, F = boot()
        go(app, F, "a.test/")
        F.press("f2"); F.press("right"); F.press("right"); steps(app, 1)
        T.ok(F.hasLog("picosurf: tab History"))
        T.ok(F.screenText():find("[>] A", 1, true))
        F.press("del"); steps(app, 1)
        T.eq(#app.store:history(), 0)
        F.press("esc"); steps(app, 1)
        T.eq(app.quit, true)
    end,
    f4_switches_reader_and_full = function()
        local app, F = boot()
        go(app, F, "a.test/")
        F.press("f4"); steps(app)
        T.ok(F.requests[#F.requests].path:find("as=full", 1, true))
        T.eq(app.page.mode, "full")
        T.ok(F.screenText():find("% F", 1, true))
    end,
    menu_reload_and_edit_url = function()
        local app, F = boot()
        go(app, F, "a.test/")
        local before = #F.requests
        F.menu["Reload"](); steps(app)
        T.eq(#F.requests, before + 1, "reload skips the cache")
        T.eq(app.page.url, "https://a.test/")
        F.inputs = { "b.test/" }
        F.menu["Edit URL"](); steps(app)
        T.eq(app.page.url, "https://b.test/")
    end,
    scrolls_and_shows_the_position = function()
        local app, F = boot()
        go(app, F, "long.test/")
        F.press("down"); steps(app, 1)
        T.eq(app.page.ps.top, 2)
        F.press("right"); steps(app, 1)
        T.eq(app.page.ps.top, 22)
        F.press("left"); F.type(" "); steps(app, 1)
        T.eq(app.page.ps.top, 22)
        T.ok(F.screenText():find("% R", 1, true))
    end,
    cancelled_back_keeps_the_entry = function()
        local app, F = boot()
        go(app, F, "a.test/")
        F.press("enter"); steps(app)
        T.eq(app.page.url, "https://b.test/")
        app.cache = {}
        F.holding = true
        F.press("backspace"); steps(app, 1)
        T.eq(app.screenName, "loading")
        F.press("esc"); steps(app, 1)
        T.eq(#app.back, 1)
        F.holding = false; steps(app)
        F.press("backspace"); steps(app)
        T.eq(app.page.url, "https://a.test/")
        T.eq(#app.back, 0, "a successful uncached Back pops exactly one")
    end,
    failed_back_keeps_the_entry = function()
        local app, F = boot()
        go(app, F, "a.test/")
        F.press("enter"); steps(app)
        app.cache = {}
        F.responder = fakepc.proxy({}, "tok")
        F.press("backspace"); steps(app)
        T.eq(app.screenName, "message")
        T.eq(#app.back, 1)
    end,
    back_does_not_rerecord_history = function()
        local app, F = boot()
        go(app, F, "a.test/")
        F.press("enter"); steps(app)
        F.press("backspace"); steps(app)
        T.eq(app.page.url, "https://a.test/")
        T.eq(app.store:history()[1].url, "https://b.test/")
        T.eq(#app.store:history(), 2)
    end,
    a_toast_is_redrawn_until_it_expires = function()
        local app, F = boot()
        app:toast("hi"); steps(app, 1)
        local n = F.frames
        F.pc.sys.sleep(3100); steps(app, 1)
        T.ok(F.frames > n, "flush after the toast's 3 s")
        n = F.frames
        F.pc.sys.sleep(250); steps(app, 1)
        T.ok(F.frames > n, "one more flush after the 250 ms margin")
        n = F.frames
        F.pc.sys.sleep(500); steps(app, 3)
        T.eq(F.frames, n, "idle again")
    end,
    leaving_loading_cancels_the_load = function()
        local app, F = boot()
        F.holding = true
        go(app, F, "b.test/")
        T.eq(app.screenName, "loading")
        F.menu["Settings"]()
        F.holding = false
        steps(app)
        T.eq(app.screenName, "settings")
        T.ok(F.hasLog("picosurf: cancelled https://b.test/"))
        T.eq(app.page, nil)
    end,
    esc_while_waiting_for_wifi_goes_home = function()
        local app, F = boot()
        go(app, F, "a.test/")
        F.netStatus = 0
        go(app, F, "b.test/")
        T.ok(F.screenText():find("Connecting to WiFi...", 1, true))
        F.press("esc"); steps(app, 1)
        T.eq(app.screenName, "home")
    end,
    warns_about_truncated_pages_and_shows_plain_text = function()
        local app, F = boot()
        go(app, F, "cut.test/")
        T.ok(F.hasToast("Page truncated by the proxy"))
        go(app, F, "plain.test/")
        T.eq(app.page.mode, "full")
        T.ok(F.screenText():find("just text", 1, true))
    end,
    a_font_change_keeps_the_top_line = function() -- M1
        local app, F = boot()
        go(app, F, "wide.test/")
        F.press("right"); F.press("down"); steps(app, 1)
        local ps = app.page.ps
        local line = app.page.L.line[ps.top]
        T.ok(line > 2, "scrolled into the page")
        F.press("tab"); steps(app, 1)
        local sel = app.page.ps.sel
        T.ok(sel, "a link is selected")
        toggleFont(app, F)
        T.eq(app.theme.cw, 8)
        ps = app.page.ps
        local L = app.page.L
        T.eq(L.line[ps.top], line, "the same source line is at the top")
        T.ok(ps.top == 1 or L.line[ps.top - 1] ~= line, "from its first row")
        T.eq(ps.sel, sel, "the same link is selected")
    end,
    a_font_change_keeps_a_selected_link_on_screen = function() -- M1
        local app, F = boot()
        go(app, F, "wide.test/")
        F.press("right"); steps(app, 1)
        local line = app.page.L.line[app.page.ps.top]
        app.page.ps:nextLink(-1) -- the last visible link
        local sel = app.page.ps.sel
        toggleFont(app, F)
        local ps, L = app.page.ps, app.page.L
        T.eq(ps.sel, sel, "the same link is selected")
        T.ok(L.links[sel].first <= ps:lastVisible() and L.links[sel].last >= ps.top, "and on screen")
        T.ok(L.line[ps.top] >= line, "the top moved down only")
        T.ok(L.links[sel].first - ps.top < ps.visible, "as far as needed")
    end,
    a_font_change_out_of_memory_says_so = function() -- M1, M13
        local app, F = boot()
        go(app, F, "wide.test/")
        withoutMemory(function()
            F.menu["Settings"](); steps(app, 1)
            F.press("down"); F.press("down"); F.press("enter"); steps(app, 1)
        end)
        T.eq(app.screenName, "message")
        T.ok(F.screenText():find("Page too large for memory", 1, true))
        T.ok(F.hasLog("picosurf: error - Page too large for memory"))
    end,
    a_page_too_large_for_memory_logs_errors = function() -- M13
        local app, F = boot()
        withoutMemory(function() go(app, F, "a.test/") end)
        T.eq(app.screenName, "message")
        T.ok(F.screenText():find("Page too large for memory", 1, true))
        T.ok(F.hasLog("not enough memory"), "the first error is logged")
        T.ok(F.hasLog("picosurf: error - Page too large for memory"))
        T.ok(not F.hasLog("layout-error"))
    end,
    backspace_does_not_cancel_a_load = function() -- M2
        local app, F = boot()
        F.holding = true
        go(app, F, "b.test/")
        F.press("backspace"); steps(app, 1)
        T.eq(app.screenName, "loading")
        T.ok(not F.hasLog("cancelled"))
        F.holding = false
        steps(app)
        T.eq(app.page.url, "https://b.test/")
    end,
    a_lua_error_shows_a_message_and_the_app_keeps_running = function() -- M3
        local app, F = boot()
        app.screens.boom = { draw = function() error("boom") end }
        app:show("boom")
        T.raises(function() app:step() end, "boom", "step itself is unguarded")
        app:show("boom")
        app:guardedStep()
        T.eq(app.screenName, "message")
        T.ok(F.hasLog("picosurf: error - "), "logged")
        T.ok(F.hasLog("boom"))
        app:guardedStep()
        T.ok(hasText(F, "[H] Something went wrong"))
        T.ok(F.screenText():find("boom", 1, true))
        F.press("esc"); app:guardedStep()
        T.eq(app.screenName, "home")
    end,
    a_non_string_error_passes_through_the_guard = function() -- M3
        local app = boot()
        local sentinel = {}
        app.screens.boom = { draw = function() error(sentinel) end }
        app:show("boom")
        local ok, err = pcall(app.guardedStep, app)
        T.eq(ok, false); T.eq(err, sentinel)
    end,
    the_header_is_redrawn_every_30_seconds_while_idle = function() -- M8
        local app, F = boot()
        steps(app)
        local n = F.frames
        F.pc.sys.sleep(29000); steps(app, 3)
        T.eq(F.frames, n, "no flush before 30 s")
        F.pc.sys.sleep(1000); steps(app, 3)
        T.eq(F.frames, n + 1, "one flush at 30 s")
    end,
    a_long_title_is_cut_beside_the_header_icons = function() -- M9
        local app, F = boot()
        go(app, F, "title.test/")
        T.ok(hasText(F, "[H] " .. string.rep("T", 220 // 6)))
        local app2, F2 = boot({ font = "8x12" })
        go(app2, F2, "title.test/")
        T.ok(hasText(F2, "[H] " .. string.rep("T", 220 // 6)), "the title bar keeps the system font")
    end,
    settings_return_to_the_page_from_loading = function() -- M12
        local app, F = boot()
        go(app, F, "a.test/")
        F.holding = true
        go(app, F, "b.test/")
        T.eq(app.screenName, "loading")
        F.menu["Settings"](); steps(app, 1)
        F.press("esc"); steps(app, 1)
        T.eq(app.screenName, "page"); T.eq(app.page.url, "https://a.test/")
    end,
    settings_return_to_the_page_from_an_error = function() -- M12
        local app, F = boot()
        go(app, F, "a.test/")
        go(app, F, "missing.test/")
        T.eq(app.screenName, "message")
        F.menu["Settings"](); steps(app, 1)
        F.press("backspace"); steps(app, 1)
        T.eq(app.screenName, "page"); T.eq(app.page.url, "https://a.test/")
    end,
    leaving_an_image_by_the_menu_frees_it = function() -- M12
        local app, F = boot()
        go(app, F, "a.test/")
        F.press("tab"); F.press("tab"); F.press("enter"); steps(app)
        T.eq(app.screenName, "image")
        F.menu["Settings"](); steps(app, 1)
        T.eq(app.image, nil)
        F.press("esc"); steps(app, 1)
        T.eq(app.screenName, "page")
    end,
    a_page_with_a_feed_hints_f5_and_subscribes_to_that_feed = function() -- M11
        local app, F = boot()
        go(app, F, "a.test/")
        T.ok(not F.screenText():find("F5 feed", 1, true))
        go(app, F, "blog.test/")
        T.ok(F.screenText():find("F5 feed", 1, true))
        F.press("f5"); steps(app)
        local path = F.requests[#F.requests].path
        T.ok(path:find("url=https%3A%2F%2Fblog.test%2Ffeed.xml&as=feed", 1, true), path)
    end,
    fixed_texts_use_the_system_font = function() -- M16; the reading font is for pages only
        local app, F = boot({ config = false, font = "8x12" })
        F.menu["Settings"](); steps(app, 1)
        F.inputs = { "ftp://x" }
        F.press("enter"); steps(app, 1)
        T.ok(app.baseErr)
        assertSystemText(F, "settings, bad URL")
        F.inputs = { "http://192.168.1.5:8080/x/" }
        F.press("enter"); steps(app, 1)
        T.ok(F.screenText():find("Warning", 1, true))
        assertSystemText(F, "settings, http warning")
        F.press("esc"); steps(app, 1)
        for _ = 1, 3 do
            F.press("right"); steps(app, 1)
            assertSystemText(F, "home")
        end
        F.holding = true
        go(app, F, "a-rather-long-host-name-for-the-loading-screen.test/")
        T.eq(app.screenName, "loading")
        assertSystemText(F, "loading")
        T.eq(F.flushFont, F.pc.display.FONT_6X8, "the system font when the frame is shown")
    end,
    the_reading_font_is_only_for_page_text = function()
        local app, F = boot({ font = "8x12" })
        go(app, F, "a.test/")
        T.eq(app.screenName, "page")
        local D = F.pc.display
        T.eq(F.fontOf("[H] "), D.FONT_6X8, "the title bar")
        T.eq(F.fontOf("[F] "), D.FONT_6X8, "the footer")
        T.eq(F.fontOf("See the docs"), D.FONT_8X12, "the page text")
        -- The system menu, toasts and text boxes run between frames in
        -- whatever font is current: the frame ends in the system font.
        T.eq(F.flushFont, D.FONT_6X8)
        T.eq(F.font, D.FONT_6X8)
    end,
    an_error_screen_uses_the_system_font = function()
        local app, F = boot({ font = "8x12" })
        go(app, F, "missing.test/")
        T.eq(app.screenName, "message")
        assertSystemText(F, "error")
    end,
    the_loading_text_is_centered = function()
        local app, F = boot()
        local d = F.pc.display
        F.holding = true
        go(app, F, "a-rather-long-host-name-for-the-loading-screen.test/")
        T.eq(app.screenName, "loading")
        local found = 0
        for i, t in ipairs(F.texts) do
            if t:sub(1, 8) == "Loading " then
                found = found + 1
                T.eq(F.textXs[i], (320 - d.textWidth(t)) // 2, "loading message x")
            end
        end
        T.eq(found, 1, "one loading message drawn")
        -- The WiFi wait message is centered too.
        local app2, F2 = boot()
        F2.netStatus = 0
        F2.holding = true
        go(app2, F2, "a.test/")
        T.eq(app2.screenName, "loading")
        for i, t in ipairs(F2.texts) do
            if t == "Connecting to WiFi..." then
                T.eq(F2.textXs[i], (320 - F2.pc.display.textWidth(t)) // 2, "wifi message x")
            end
        end
    end,
}
