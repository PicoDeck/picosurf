local T = require("tests.t")
local feeds = require("src.feeds")

local function items(n, start)
    local out = {}
    for i = 1, n do out[i] = { url = "https://f.test/" .. (start or 0) + i, date = "2026-10-01", title = "T" .. i } end
    return out
end

return {
    subscribe_adds_once_and_respects_the_limit = function()
        local idx = { next_id = 1, feeds = {} }
        local f, new = feeds.subscribe(idx, "https://f.test/feed", "F")
        T.eq(new, true); T.eq(f.id, 1); T.eq(f.fetched_at, 0); T.eq(idx.next_id, 2)
        local again, isNew = feeds.subscribe(idx, "https://f.test/feed", "F")
        T.eq(again, f); T.eq(isNew, false)
        for i = 2, feeds.MAX_FEEDS do feeds.subscribe(idx, "https://f.test/" .. i, "F") end
        local none, msg = feeds.subscribe(idx, "https://f.test/full", "F")
        T.eq(none, nil); T.eq(msg, "Feed limit reached (50)")
        T.eq(feeds.unsubscribe(idx, 1), true)
        T.eq(feeds.unsubscribe(idx, 1), false)
    end,
    merge_caps_items_and_prunes_seen = function()
        local data = { items = {}, seen = { "https://f.test/1", "https://f.test/gone" } }
        local fetched = items(60)
        fetched[2].date = nil
        feeds.merge(data, fetched)
        T.eq(#data.items, feeds.MAX_ITEMS)
        T.eq(data.items[2].date, "")
        T.eq(#data.seen, 1)
        T.eq(data.seen[1], "https://f.test/1")
        T.eq(feeds.unreadCount(data), feeds.MAX_ITEMS - 1)
    end,
    mark_read_and_mark_all_read = function()
        local data = feeds.merge({ items = {}, seen = {} }, items(3))
        T.eq(feeds.markRead(data, "https://f.test/2"), true)
        T.eq(feeds.markRead(data, "https://f.test/2"), false, "already read")
        T.eq(feeds.markRead(data, "https://elsewhere.test/"), false, "not in this feed")
        T.eq(feeds.unreadCount(data), 2)
        feeds.markAllRead(data)
        T.eq(feeds.unreadCount(data), 0)
    end,
    summarize_counts_and_dates = function()
        local data = feeds.merge({ items = {}, seen = {} }, {
            { url = "a", date = "2026-10-12", title = "A" }, { url = "b", date = "2026-10-14", title = "B" },
            { url = "c", title = "C" },
        })
        local f = { fetched_at = 5 }
        feeds.summarize(f, data)
        T.eq(f.unread, 3); T.eq(f.newest, "2026-10-14"); T.eq(f.fetched_at, 5)
        feeds.summarize(f, data, 1792000000)
        T.eq(f.fetched_at, 1792000000)
    end,
    staleness = function()
        T.eq(feeds.isStale({ fetched_at = 0 }, 1792000000), true, "never fetched")
        T.eq(feeds.isStale({ fetched_at = 0 }, 0), true, "never fetched, clock not set")
        T.eq(feeds.isStale({ fetched_at = 1792000000 }, 1792001799), false)
        T.eq(feeds.isStale({ fetched_at = 1792000000 }, 1792001800), true)
        T.eq(feeds.isStale({ fetched_at = 1792000000 }, 0), false, "clock not set: keep what we have")
    end,
    sorted_newest_first_then_undated_by_title = function()
        local idx = { feeds = {
            { title = "beta", newest = "" }, { title = "Old", newest = "2026-01-01" },
            { title = "alpha", newest = "" }, { title = "New", newest = "2026-10-13" },
        } }
        local got = {}
        for i, f in ipairs(feeds.sorted(idx)) do got[i] = f.title end
        T.eq(table.concat(got, ","), "New,Old,alpha,beta")
        T.eq(idx.feeds[1].title, "beta", "the index itself is not reordered")
    end,
    lines_mark_unread_and_dim_read = function()
        local data = feeds.merge({ items = {}, seen = {} }, {
            { url = "https://f.test/1", date = "2026-10-13", title = "One" }, { url = "https://f.test/2", title = "Two" },
        })
        feeds.markRead(data, "https://f.test/2")
        local lines = feeds.lines({ title = "Blog" }, data)
        T.eq(lines[1].t, "h1"); T.eq(lines[1].text, "Blog")
        T.eq(lines[3].text, "* 2026-10-13 One"); T.eq(lines[3].dim, false)
        T.eq(lines[4].text, "  Two"); T.eq(lines[4].dim, true); T.eq(lines[4].url, "https://f.test/2")
        local empty = feeds.lines({ title = "E" }, { items = {}, seen = {} })
        T.eq(empty[3].t, "text")
    end,
}
