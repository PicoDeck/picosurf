local T = require("tests.t")
local fakes = require("tests.fakes")
local store = require("src.store")

local DIR = "/data/net.picodeck.picosurf"

local function make()
    local fs, files = fakes.fs()
    local json = fakes.json()
    return store.new(fs, json, DIR), files, fs, json
end

return {
    bookmarks_toggle_newest_first_and_persist = function()
        local s, files, fs, json = make()
        T.eq(s:toggleBookmark("https://a.test/", "A"), true)
        T.eq(s:toggleBookmark("https://b.test/", "B"), true)
        T.eq(s:bookmarks()[1].url, "https://b.test/")
        T.ok(s:isBookmarked("https://a.test/"))
        T.eq(s:toggleBookmark("https://a.test/", "A"), false)
        T.ok(not s:isBookmarked("https://a.test/"))
        local again = store.new(fs, json, DIR)
        T.eq(#again:bookmarks(), 1)
        T.eq(again:bookmarks()[1].title, "B")
        T.eq(files[DIR .. "/bookmarks.json.tmp"], nil, "no temporary file left behind")
    end,
    bookmarks_are_capped = function()
        local s = make()
        for i = 1, store.MAX_BOOKMARKS + 5 do s:toggleBookmark("https://a.test/" .. i, "A") end
        T.eq(#s:bookmarks(), store.MAX_BOOKMARKS)
        T.eq(s:bookmarks()[1].url, "https://a.test/" .. (store.MAX_BOOKMARKS + 5))
        s:removeBookmark(1)
        T.eq(#s:bookmarks(), store.MAX_BOOKMARKS - 1)
    end,
    history_moves_revisits_to_the_top_and_is_capped = function()
        local s = make()
        s:addHistory("https://a.test/", "A")
        s:addHistory("https://b.test/", "B")
        s:addHistory("https://a.test/", "A again")
        T.eq(#s:history(), 2)
        T.eq(s:history()[1].title, "A again")
        for i = 1, store.MAX_HISTORY + 3 do s:addHistory("https://h.test/" .. i, "H") end
        T.eq(#s:history(), store.MAX_HISTORY)
        s:removeHistory(1)
        T.eq(#s:history(), store.MAX_HISTORY - 1)
    end,
    save_replaces_an_existing_file = function()
        local s, files = make()
        T.eq(s:save("x.json", { 1 }), true)
        T.eq(s:save("x.json", { 2 }), true)
        T.eq(s:load("x.json", {})[1], 2)
        T.eq(files[DIR .. "/x.json.tmp"], nil)
    end,
    recovers_a_save_interrupted_before_the_rename = function() -- Review Focus 3
        local s, files, fs, json = make()
        s:save("x.json", { 7 })
        files[DIR .. "/x.json.tmp"] = files[DIR .. "/x.json"]
        files[DIR .. "/x.json"] = nil
        local again = store.new(fs, json, DIR)
        T.eq(again:load("x.json", {})[1], 7)
        T.ok(files[DIR .. "/x.json"] ~= nil, "the temporary file became the main file")
    end,
    an_unreadable_file_is_set_aside = function()
        local s, files = make()
        files[DIR .. "/history.json"] = "not json"
        T.eq(#s:history(), 0)
        T.eq(files[DIR .. "/history.json.bad"], "not json")
        T.eq(files[DIR .. "/history.json"], nil)
        T.eq(s.notes[1], "history.json was unreadable; started empty")
    end,
    feed_index_and_data_round_trip = function()
        local s, _, fs, json = make()
        local idx = s:feedIndex()
        T.eq(idx.next_id, 1); T.eq(#idx.feeds, 0)
        idx.feeds[1] = { id = 1, url = "https://f.test/", title = "F", fetched_at = 1792000000, unread = 2, newest = "2026-10-13" }
        idx.next_id = 2
        T.eq(s:saveFeedIndex(), true)
        s:saveFeedData(1, { items = { { url = "u", date = "", title = "t" } }, seen = { "u" } })
        local again = store.new(fs, json, DIR)
        T.eq(again:feedIndex().feeds[1].fetched_at, 1792000000)
        T.eq(math.type(again:feedIndex().feeds[1].fetched_at), "integer")
        T.eq(again:feedData(1).seen[1], "u")
        again:deleteFeedData(1)
        T.eq(#again:feedData(1).items, 0, "a missing feed file gives empty data")
    end,
}
