local T = require("tests.t")
local fakes = require("tests.fakes")
local store = require("src.store")

local DIR = "/data/net.picodeck.picosurf"

local function make()
    local fs, files = fakes.fs()
    local json = fakes.json()
    return store.new(fs, json, DIR), files, fs, json
end

-- A store holding x.json = { 1 }: the state every failed save must leave alone.
local function withOriginal()
    local s, files, fs, json = make()
    T.eq(s:save("x.json", { 1 }), true)
    return s, files, fs, json
end

-- A failed save of { 2 } leaves { 1 } in place, leaves no .tmp, and reports it.
local function assertFailedSaveKeepsOriginal(s, files, label)
    T.eq(s:save("x.json", { 2 }), false, label .. ": save reports failure")
    T.eq(s:load("x.json", {})[1], 1, label .. ": original content unchanged")
    T.eq(files[DIR .. "/x.json.tmp"], nil, label .. ": no temporary file left")
    T.eq(s.notes[1], "Couldn't save x.json", label .. ": failure reported")
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
    write_returning_minus_one_keeps_the_original = function()
        local s, files, fs = withOriginal()
        fs.failWrite = true
        assertFailedSaveKeepsOriginal(s, files, "write -1")
    end,
    open_returning_nil_keeps_the_original = function()
        local s, files, fs = withOriginal()
        fs.failOpen = true
        assertFailedSaveKeepsOriginal(s, files, "open nil")
    end,
    size_mismatch_after_close_keeps_the_original = function()
        local s, files, fs = withOriginal()
        fs.shortClose = true
        assertFailedSaveKeepsOriginal(s, files, "size mismatch")
    end,
    json_encode_raising_keeps_the_original = function()
        local s, files, _, json = withOriginal()
        json.failEncode = true
        assertFailedSaveKeepsOriginal(s, files, "encode raises")
    end,
    failed_rename_reports_and_the_new_value_is_recovered = function()
        local s, _, fs = withOriginal()
        fs.failRename = true
        T.eq(s:save("x.json", { 2 }), false)
        T.eq(s.notes[1], "Couldn't save x.json")
        T.eq(s:load("x.json", {})[1], 2, "the .tmp holds the new value")
    end,
    recovery_reads_the_tmp_when_its_rename_fails = function()
        local s, files, fs, json = make()
        files[DIR .. "/x.json.tmp"] = json.encode({ 7 })
        fs.failRename = true
        T.eq(s:load("x.json", {})[1], 7)
        T.ok(files[DIR .. "/x.json.tmp"] ~= nil, "the only good copy is kept")
    end,
    wrong_shape_bookmarks_are_set_aside = function()
        local s, files, _, json = make()
        files[DIR .. "/bookmarks.json"] = json.encode({ 1, 2 })
        T.eq(#s:bookmarks(), 0)
        T.ok(files[DIR .. "/bookmarks.json.bad"] ~= nil, "kept as .bad")
        T.eq(files[DIR .. "/bookmarks.json"], nil)
        T.eq(s.notes[1], "bookmarks.json was unreadable; started empty")
        T.eq(s:toggleBookmark("https://a.test/", "A"), true, "the list works after the reset")
    end,
    wrong_shape_feed_index_is_set_aside = function()
        local s, files, _, json = make()
        files[DIR .. "/feeds/index.json"] = json.encode({ k = 1 })
        T.eq(s:feedIndex().next_id, 1)
        T.eq(#s:feedIndex().feeds, 0)
        T.ok(files[DIR .. "/feeds/index.json.bad"] ~= nil, "kept as .bad")
        T.eq(files[DIR .. "/feeds/index.json"], nil)
        T.eq(s.notes[1], "feeds/index.json was unreadable; started empty")
    end,
    wrong_shape_feed_data_is_set_aside = function()
        local s, files, _, json = make()
        files[DIR .. "/feeds/1.json"] = json.encode({ items = "x" })
        T.eq(#s:feedData(1).items, 0)
        T.ok(files[DIR .. "/feeds/1.json.bad"] ~= nil, "kept as .bad")
        T.eq(files[DIR .. "/feeds/1.json"], nil)
        T.eq(s.notes[1], "feeds/1.json was unreadable; started empty")
    end,
    removing_a_missing_entry_does_nothing = function()
        local s, files = make()
        s:removeBookmark(1)
        s:removeHistory(1)
        T.eq(files[DIR .. "/bookmarks.json"], nil, "no save")
        T.eq(files[DIR .. "/history.json"], nil, "no save")
        T.eq(#s.notes, 0)
    end,
    a_file_that_exists_but_cannot_be_read_is_set_aside = function() -- M6
        local s, files, fs, json = make()
        files[DIR .. "/history.json"] = json.encode({ { url = "https://a.test/" } })
        fs.failRead = true
        T.eq(#s:history(), 0)
        T.ok(files[DIR .. "/history.json.bad"] ~= nil, "kept as .bad")
        T.eq(files[DIR .. "/history.json"], nil)
        T.eq(s.notes[1], "history.json was unreadable; started empty")
        fs.failRead = false
        s:addHistory("https://b.test/", "B")
        T.ok(files[DIR .. "/history.json.bad"] ~= nil, "the next save leaves it alone")
    end,
    a_failed_save_names_the_file_as_given = function() -- T7
        local s, _, fs = make()
        fs.failOpen = true
        T.eq(s:saveFeedData(3, { items = {}, seen = {} }), false)
        T.eq(s.notes[1], "Couldn't save feeds/3.json")
    end,
    feed_index_entries_with_wrong_field_types_are_set_aside = function() -- T8
        local bad = {
            { url = "u" }, { id = "1", url = "u" }, { id = 1.5, url = "u" }, { id = 1 },
            { id = 1, url = 5 }, { id = 1, url = "u", title = 3 }, { id = 1, url = "u", newest = 20261013 },
        }
        for i, f in ipairs(bad) do
            local s, files, _, json = make()
            files[DIR .. "/feeds/index.json"] = json.encode({ next_id = 2, feeds = { f } })
            T.eq(#s:feedIndex().feeds, 0, "entry " .. i)
            T.ok(files[DIR .. "/feeds/index.json.bad"] ~= nil, "entry " .. i .. " kept as .bad")
        end
    end,
    a_feed_without_title_or_newest_is_kept = function() -- T8
        local s, files, _, json = make()
        files[DIR .. "/feeds/index.json"] = json.encode({ next_id = 2, feeds = { { id = 1, url = "u" } } })
        T.eq(#s:feedIndex().feeds, 1)
        T.eq(#s.notes, 0)
    end,
    feed_items_with_wrong_field_types_are_set_aside = function() -- T8
        local bad = {
            { "x" }, { { title = "t" } }, { { url = 1 } }, { { url = "u", date = 5 } }, { { url = "u", title = false } },
        }
        for i, items in ipairs(bad) do
            local s, files, _, json = make()
            files[DIR .. "/feeds/1.json"] = json.encode({ items = items, seen = {} })
            T.eq(#s:feedData(1).items, 0, "items " .. i)
            T.ok(files[DIR .. "/feeds/1.json.bad"] ~= nil, "items " .. i .. " kept as .bad")
        end
        local s, files, _, json = make()
        files[DIR .. "/feeds/1.json"] = json.encode({ items = { { url = "u" } }, seen = {} })
        T.eq(#s:feedData(1).items, 1, "url alone is enough")
    end,
}
