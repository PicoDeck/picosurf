local T = require("tests.t")
local fakepc = require("tests.fakepc")
local App = require("src.app")

local FEED = "# Blog\n\n=> https://blog.test/1 2026-10-13 One\n=> https://blog.test/2 2026-10-12 Two\n=> https://blog.test/3 Undated\n"
local NEWS = "# News\n\n=> https://news.test/1 2026-10-14 Headline\n"
local ROUTES = {
    ["https://blog.test/"] = { title = "Blog", feed = "https://blog.test/feed.xml", body = "# Blog\n\nHello.\n" },
    ["https://blog.test/|feed"] = { title = "Blog", final = "https://blog.test/feed.xml", mode = "feed", body = FEED },
    ["https://blog.test/feed.xml|feed"] = { title = "Blog", mode = "feed", body = FEED },
    ["https://blog.test/1"] = { title = "One", body = "# One\n" },
    ["https://news.test/"] = { title = "News", body = "# News\n" },
    ["https://news.test/|feed"] = { title = "News", final = "https://news.test/rss", mode = "feed", body = NEWS },
    ["https://news.test/rss|feed"] = { title = "News", mode = "feed", body = NEWS },
    ["https://plain.test/"] = { title = "Plain", body = "# Plain\n" },
    ["https://plain.test/|feed"] = { status = 415, type = "text/plain; charset=us-ascii", mode = false, body = "No feed found on this page\n" },
}

local function boot()
    local F = fakepc.new()
    F.config.proxy_url, F.config.token = "https://p.test", "tok"
    F.responder = fakepc.proxy(ROUTES, "tok")
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

local function subscribe(app, F, site)
    go(app, F, site)
    F.press("f5")
    steps(app)
end

return {
    f5_subscribes_from_a_homepage = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        T.ok(F.hasLog("picosurf: subscribed 1 https://blog.test/feed.xml unread=3"))
        T.ok(F.hasToast("Subscribed: Blog"))
        T.eq(app.screenName, "page")
        local feed = app.store:feedIndex().feeds[1]
        T.eq(feed.url, "https://blog.test/feed.xml"); T.eq(feed.fetched_at, F.epoch); T.eq(feed.newest, "2026-10-13")
        F.press("f5"); steps(app)
        T.ok(F.hasToast("Already subscribed"))
    end,
    f5_on_a_page_without_a_feed_says_so = function()
        local app, F = boot()
        subscribe(app, F, "plain.test/")
        T.ok(F.hasToast("No feed found on this page"))
        T.eq(#app.store:feedIndex().feeds, 0)
    end,
    the_feeds_tab_lists_feeds_and_opens_them_without_fetching = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        F.press("f2"); steps(app, 1)
        T.ok(F.screenText():find("[T*] Feeds", 1, true))
        T.ok(F.screenText():find("[>] Blog (3)", 1, true))
        local before = #F.requests
        F.press("enter"); steps(app, 1)
        T.eq(#F.requests, before, "fresh feed: no request")
        T.eq(app.screenName, "page"); T.eq(app.page.isFeedList, true)
        T.ok(F.screenText():find("* 2026-10-13 One", 1, true))
        T.ok(F.hasLog("picosurf: feed 1 unread=3"))
    end,
    opening_an_article_marks_it_read = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        F.press("f2"); F.press("enter"); steps(app, 1)
        F.press("tab"); F.press("enter"); steps(app)
        T.ok(F.hasLog("picosurf: feed 1 unread=2"))
        T.eq(app.page.url, "https://blog.test/1")
        T.eq(app.store:feedIndex().feeds[1].unread, 2)
        F.press("backspace"); steps(app, 1)
        T.eq(app.page.isFeedList, true)
        T.ok(F.screenText():find("  2026-10-13 One", 1, true), "read item shows without the star")
        T.eq(app.page.ps.sel, 1, "selection restored")
    end,
    a_stale_feed_is_fetched_when_opened = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        F.epoch = F.epoch + 1800
        F.press("f2"); F.press("enter"); steps(app)
        T.ok(F.requests[#F.requests].path:find("feed.xml", 1, true))
        T.eq(app.page.isFeedList, true)
        T.eq(app.store:feedIndex().feeds[1].fetched_at, F.epoch)
    end,
    f5_on_the_feeds_tab_refreshes_every_feed = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        subscribe(app, F, "news.test/")
        F.press("f2"); steps(app, 1)
        local before = #F.requests
        F.press("f5"); steps(app)
        T.eq(#F.requests, before + 2)
        T.ok(F.hasLog("picosurf: refresh done ok=2 failed=0"))
        T.ok(F.hasToast("Feeds refreshed"))
    end,
    esc_cancels_a_refresh_instead_of_quitting = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        F.press("f2"); steps(app, 1)
        F.holding = true
        F.press("f5"); steps(app, 1)
        F.press("esc"); steps(app, 1)
        T.ok(F.hasLog("picosurf: refresh cancelled"))
        T.ok(not app.quit)
        F.holding = false
        steps(app)
        T.ok(not F.hasLog("refresh done"))
    end,
    mark_all_read_from_the_menu = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        F.press("f2"); F.press("enter"); steps(app, 1)
        F.menu["Mark all read"](); steps(app, 1)
        T.ok(F.hasLog("picosurf: feed 1 unread=0"))
        T.eq(app.store:feedIndex().feeds[1].unread, 0)
        T.ok(F.screenText():find("  2026-10-12 Two", 1, true))
    end,
    reload_on_a_feed_list_fetches_the_feed = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        F.press("f2"); F.press("enter"); steps(app, 1)
        local before = #F.requests
        F.menu["Reload"](); steps(app)
        T.eq(#F.requests, before + 1)
        T.ok(F.requests[#F.requests].path:find("as=feed", 1, true))
        T.eq(app.page.isFeedList, true)
        T.eq(#app.back, 0, "reload replaced the page instead of stacking it")
    end,
    del_unsubscribes_after_confirming = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        F.press("f2"); steps(app, 1)
        F.confirms = { false }
        F.press("del"); steps(app, 1)
        T.eq(#app.store:feedIndex().feeds, 1)
        F.press("del"); steps(app, 1)
        T.eq(#app.store:feedIndex().feeds, 0)
        T.eq(F.files["/data/net.picodeck.picosurf/feeds/1.json"], nil)
        T.ok(F.hasLog("picosurf: unsubscribed 1"))
    end,
    back_to_an_unsubscribed_feed_list_skips_it = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        F.press("f2"); F.press("enter"); steps(app, 1)
        F.press("tab"); F.press("enter"); steps(app)
        T.eq(app.page.url, "https://blog.test/1")
        T.eq(#app.back, 1)
        table.insert(app.back, 1, { url = "https://blog.test/", want = "reader", top = 1, sel = 1 })
        local feeds = require("src.feeds")
        feeds.unsubscribe(app.store:feedIndex(), 1)
        app.store:deleteFeedData(1)
        app.store:saveFeedIndex()
        F.press("backspace"); steps(app)
        T.eq(app.page.url, "https://blog.test/", "skipped the feed list, landed on the page under it")
        T.eq(#app.back, 0)
        F.press("backspace"); steps(app, 1)
        T.eq(app.screenName, "home")
    end,
    back_to_an_unsubscribed_feed_list_alone_goes_home = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        F.press("f2"); F.press("enter"); steps(app, 1)
        F.press("tab"); F.press("enter"); steps(app)
        local feeds = require("src.feeds")
        feeds.unsubscribe(app.store:feedIndex(), 1)
        app.store:deleteFeedData(1)
        app.store:saveFeedIndex()
        app.back = { app.back[2] }
        F.press("backspace"); steps(app, 1)
        T.eq(app.screenName, "home")
        T.eq(#app.back, 0)
    end,
    deleting_the_last_entry_of_a_scrolled_list_keeps_the_selection_inside = function()
        local app, F = boot()
        for i = 1, 25 do app.store:addHistory("https://h.test/" .. i, "Entry " .. i) end
        F.press("f2"); F.press("right"); F.press("right"); steps(app, 1)
        for _ = 1, 30 do F.press("down") end
        steps(app, 1)
        local n = #app.store:history()
        T.eq(app.home.sel[3], n)
        T.ok(app.home.top[3] > 1, "scrolled")
        for _ = 1, n + 2 do
            F.press("del"); steps(app, 1)
            local m = #app.store:history()
            if m > 0 then
                T.ok(app.home.sel[3] >= 1 and app.home.sel[3] <= m, "sel inside")
                T.ok(app.home.top[3] >= 1 and app.home.top[3] <= app.home.sel[3], "top inside")
                T.ok(F.screenText():find("[>] ", 1, true), "a row is selected")
            end
        end
        T.eq(#app.store:history(), 0)
        T.ok(not F.screenText():find("[>] ", 1, true), "nothing selected when empty")
    end,
    refresh_without_wifi_says_so_and_starts_nothing = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        F.press("f2"); steps(app, 1)
        F.netStatus = 0
        local before = #F.requests
        F.press("f5"); steps(app)
        T.eq(#F.requests, before)
        T.eq(app.refresh, nil)
        T.ok(F.hasToast("No WiFi - can't refresh feeds"))
        T.ok(F.hasLog("picosurf: error - No WiFi"))
    end,
    refresh_before_the_clock_is_set_says_so_and_starts_nothing = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        F.press("f2"); steps(app, 1)
        F.synced = false
        local before = #F.requests
        F.press("f5"); steps(app)
        T.eq(#F.requests, before)
        T.eq(app.refresh, nil)
        T.ok(F.hasToast("Clock not set yet - try again in a moment"))
        T.ok(F.hasLog("picosurf: error - Clock not set"))
    end,
    a_failed_feed_is_logged_and_named_in_the_toast = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        subscribe(app, F, "news.test/")
        local routes = {}
        for k, v in pairs(ROUTES) do routes[k] = v end
        routes["https://news.test/rss|feed"] = nil
        F.responder = fakepc.proxy(routes, "tok")
        F.press("f2"); steps(app, 1)
        F.press("f5"); steps(app)
        T.ok(F.hasLog("picosurf: error 502 Site returned 404 Not Found"))
        T.ok(F.hasLog("picosurf: refresh done ok=1 failed=1"))
        T.ok(F.hasToast("1 feed failed to refresh: Site returned 404 Not Found"))
    end,
    two_failed_feeds_use_the_plural = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        subscribe(app, F, "news.test/")
        F.responder = fakepc.proxy({}, "tok")
        F.press("f2"); steps(app, 1)
        F.press("f5"); steps(app)
        T.ok(F.hasToast("2 feeds failed to refresh: Site returned 404 Not Found"))
    end,
    unsubscribing_during_a_refresh_leaves_no_feed_file = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        F.press("f2"); steps(app, 1)
        F.holding = true
        F.press("f5"); steps(app, 1)
        F.press("del"); steps(app, 1)
        T.eq(#app.store:feedIndex().feeds, 0)
        F.holding = false
        steps(app)
        T.eq(F.files["/data/net.picodeck.picosurf/feeds/1.json"], nil)
        T.eq(#app.store:feedIndex().feeds, 0)
    end,
    saving_a_setting_during_a_refresh_cancels_it = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        subscribe(app, F, "news.test/")
        F.press("f2"); steps(app, 1)
        F.holding = true
        F.press("f5"); steps(app, 1)
        F.menu["Settings"](); steps(app, 1)
        F.press("down"); F.press("down"); F.press("enter"); steps(app, 1)
        T.ok(F.hasLog("picosurf: refresh cancelled"))
        F.holding = false
        steps(app)
        T.ok(not F.hasLog("refresh done"))
        T.ok(not F.hasToast("failed to refresh"))
    end,
    a_stale_feed_opened_offline_shows_its_saved_items = function()
        local app, F = boot()
        subscribe(app, F, "blog.test/")
        F.epoch = F.epoch + 1800
        F.netStatus = 0
        F.press("f2"); steps(app, 1)
        local before = #F.requests
        F.press("enter"); steps(app)
        T.eq(app.screenName, "page")
        T.eq(app.page.isFeedList, true)
        T.ok(F.hasToast("Offline - showing saved items"))
        T.eq(#F.requests, before)
        T.ok(F.screenText():find("* 2026-10-13 One", 1, true))
    end,
}
