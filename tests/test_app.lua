local T = require("tests.t")
local fakepc = require("tests.fakepc")
local App = require("src.app")

local A = "# A\n\nSee the docs [1] and more [2].\n=> https://b.test/ [1] the docs\n=> gemini://g.test/ [2] more\n=> https://a.test/cat.jpg [IMG] Cat\n"
local function longBody()
    local parts = { "# Long" }
    for i = 1, 100 do parts[#parts + 1] = "line " .. i end
    return table.concat(parts, "\n")
end
local ROUTES = {
    ["https://a.test/"] = { title = "A", body = A },
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

return {
    first_run_opens_settings = function()
        local app, F = boot({ config = false })
        T.eq(app.screenName, "settings")
        T.ok(F.screenText():find("PicoSurf proxy", 1, true))
        T.ok(F.hasLog("picosurf: screen settings"))
    end,
    settings_save_url_and_token_and_warn_on_http = function() -- Review Focus 5
        local app, F = boot({ config = false })
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
        F.press("down"); F.press("down"); F.press("down"); F.press("enter"); steps(app)
        T.ok(F.hasToast("Proxy OK")); T.ok(F.hasLog("picosurf: ping ok"))
        local app2, F2 = boot({ token = "other" })
        F2.menu["Settings"](); steps(app2, 1)
        F2.press("down"); F2.press("down"); F2.press("down"); F2.press("enter"); steps(app2)
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
    refuses_text_with_spaces = function()
        local app, F = boot()
        go(app, F, "two words")
        T.ok(F.hasToast("Not a URL (search isn't supported yet)"))
        T.eq(app.screenName, "home")
    end,
    follows_the_selected_link_and_comes_back_from_the_cache = function()
        local app, F = boot()
        go(app, F, "a.test/")
        F.press("tab"); steps(app, 1)
        T.eq(app.page.ps.sel, 1)
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
        T.ok(F.hasToast("gemini:// links aren't supported yet"))
        T.eq(app.screenName, "page")
    end,
    opens_and_closes_an_image = function()
        local app, F = boot()
        go(app, F, "a.test/")
        F.press("tab"); F.press("tab"); F.press("tab"); F.press("enter"); steps(app)
        T.eq(app.screenName, "image")
        T.ok(F.hasLog("picosurf: image w=200 h=120"))
        F.press("esc"); steps(app, 1)
        T.eq(app.screenName, "page"); T.eq(app.page.url, "https://a.test/")
    end,
    an_undecodable_image_shows_an_error = function()
        local app, F = boot()
        go(app, F, "a.test/bad.jpg")
        T.eq(app.screenName, "message")
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
        F.press("tab"); F.press("enter"); steps(app)
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
        F.press("tab"); F.press("enter"); steps(app)
        app.cache = {}
        F.responder = fakepc.proxy({}, "tok")
        F.press("backspace"); steps(app)
        T.eq(app.screenName, "message")
        T.eq(#app.back, 1)
    end,
    back_does_not_rerecord_history = function()
        local app, F = boot()
        go(app, F, "a.test/")
        F.press("tab"); F.press("enter"); steps(app)
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
        T.ok(F.frames > n, "flush after expiry")
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
}
