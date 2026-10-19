local T = require("tests.t")
local fakes = require("tests.fakes")
local store = require("src.store")
local tofu = require("src.tofu")

local function setup()
    local fs, files = fakes.fs()
    local json = fakes.json()
    local s = store.new(fs, json, "/data/x")
    return tofu.new(s), s, files, json
end

return {
    first_visit_pins_and_saves = function()
        local pins, _, files = setup()
        T.eq(pins:check("g.test", 1965, "aa", 100), "new")
        T.eq(files["/data/x/known_hosts.json"], nil, "nothing written inside the check")
        pins:flush(0)
        T.ok(files["/data/x/known_hosts.json"], "saved by flush")
        T.eq(pins:check("g.test", 1965, "aa", 200), "ok")
        T.eq(pins:hosts()["g.test:1965"].seen, 200); T.eq(pins:hosts()["g.test:1965"].first, 100)
    end,
    a_different_fingerprint_is_a_change = function()
        local pins = setup()
        pins:check("g.test", 1965, "aa", 100)
        local verdict, old = pins:check("g.test", 1965, "bb", 300)
        T.eq(verdict, "changed"); T.eq(old.fp, "aa"); T.eq(old.first, 100)
        T.eq(pins:hosts()["g.test:1965"].fp, "aa", "unchanged until accepted")
        pins:accept("g.test", 1965, "bb", 300)
        T.eq(pins:check("g.test", 1965, "bb", 400), "ok")
        T.eq(pins:check("g.test", 1966, "bb", 400), "new", "ports are pinned separately")
    end,
    no_fingerprint_is_unpinned = function()
        local pins = setup()
        T.eq(pins:check("g.test", 1965, nil, 100), "unpinned")
        T.eq(next(pins:hosts()), nil)
    end,
    seen_alone_saves_at_most_once_a_minute = function()
        local pins, s = setup()
        local saves = 0
        local save = s.save
        s.save = function(...) saves = saves + 1; return save(...) end
        pins:check("g.test", 1965, "aa", 1)
        pins:flush(1000); T.eq(saves, 1)
        pins:check("g.test", 1965, "aa", 2)
        pins:flush(30000); T.eq(saves, 1, "seen changed, under a minute")
        pins:flush(61000); T.eq(saves, 2)
        pins:flush(200000); T.eq(saves, 2, "nothing changed")
    end,
    the_store_keeps_500_hosts = function()
        local pins = setup()
        for i = 1, 501 do pins:check("h" .. i .. ".test", 1965, "fp", i) end
        local n = 0
        for _ in pairs(pins:hosts()) do n = n + 1 end
        T.eq(n, 500); T.eq(pins:hosts()["h1.test:1965"], nil, "the least recently seen goes")
        T.ok(pins:hosts()["h501.test:1965"])
    end,
    a_corrupt_file_starts_empty = function()
        local pins, s, files = setup()
        files["/data/x/known_hosts.json"] = "garbage"
        T.eq(pins:check("g.test", 1965, "aa", 1), "new")
        T.ok(files["/data/x/known_hosts.json.bad"]); T.eq(#s.notes, 1)
    end,
    saved_pins_load_back = function()
        local pins, s = setup()
        pins:check("g.test", 1965, "aa", 5)
        pins:flush(0)
        local again = tofu.new(s)
        T.eq(again:check("g.test", 1965, "aa", 6), "ok")
    end,
    dates_from_epochs = function()
        T.eq(tofu.date(0), nil)
        T.eq(tofu.date(1), "1970-01-01")
        T.eq(tofu.date(951782400), "2000-02-29")
        T.eq(tofu.date(1792000000), "2026-10-14")
        T.eq(tofu.date(2147483647), "2038-01-19")
    end,
    a_hand_edited_date_sets_the_file_aside = function()
        local pins, _, files, json = setup()
        files["/data/x/known_hosts.json"] = json.encode({ ["g.test:1965"] = { fp = "aa", first = "x", seen = 1 } })
        T.eq(next(pins:hosts()), nil, "an entry without numeric dates is not trusted")
        T.ok(files["/data/x/known_hosts.json.bad"], "the file is set aside")
    end,
    a_visit_before_the_clock_is_set_keeps_the_last_seen_time = function()
        local pins = setup()
        pins:check("g.test", 1965, "aa", 100)
        T.eq(pins:check("g.test", 1965, "aa", 0), "ok")
        T.eq(pins:hosts()["g.test:1965"].seen, 100)
    end,
}
