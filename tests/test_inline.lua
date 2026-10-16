local T = require("tests.t")
local inline = require("src.inline")
local layout = require("src.layout")
local pagestate = require("src.pagestate")
local g = require("src.gemtext")

-- 70 lines at 40 columns, 10 rows on screen, scrolled to rows 30-39, so the
-- window is rows 20-49. Pictures on rows 15, 22, 26, 31, 41, 48 and 55 (links
-- 1, 2, 3, 4, 7, 8, 9), a plain link on row 33 (5), and a gemini picture on
-- row 37 (6).
local function page()
    local parts = {}
    for i = 1, 70 do parts[i] = "line " .. i end
    for _, i in ipairs({ 15, 22, 26, 31, 41, 48, 55 }) do
        parts[i] = "=> https://img.test/" .. i .. ".jpg [IMG] p" .. i
    end
    parts[33] = "=> https://a.test/x a link"
    parts[37] = "=> gemini://g.test/37.jpg [IMG] elsewhere"
    local L = layout.build(g.parse(table.concat(parts, "\n")), layout.mono(40))
    local ps = pagestate.new(L, 10)
    ps:scroll(29)
    return L, ps
end

local function u(row) return "https://img.test/" .. row .. ".jpg" end

return {
    a_box_fits_its_picture_and_its_padding = function()
        T.eq(inline.FIT, "312x126")
        T.eq(inline.rows(126, 13), 10); T.eq(inline.rows(100, 13), 8); T.eq(inline.rows(50, 13), 5)
        T.eq(inline.rows(9, 13), 1); T.eq(inline.rows(10, 13), 2); T.eq(inline.rows(1, 13), 1)
        T.eq(inline.rows(126, 14), 10); T.eq(inline.rows(120, 13), 10); T.eq(inline.rows(120, 14), 9)
        T.eq(inline.rows(100, 14), 8)
    end,
    orders_the_window_on_screen_then_below_then_above = function()
        local L, ps = page()
        T.eq(ps.top, 30)
        T.eq(table.concat(inline.order(L, ps), ","), "4,6,7,8,3,2")
    end,
    fetches_web_pictures_without_an_entry = function()
        local L, ps = page()
        local st, order = inline.new(), inline.order(L, ps)
        local k, url = st:nextFetch(L, order)
        T.eq(k, 4); T.eq(url, u(31))
        st.byUrl[url] = { state = "loading" }
        k, url = st:nextFetch(L, order)
        T.eq(k, 7, "the gemini picture is skipped"); T.eq(url, u(41))
        st.byUrl[url] = { state = "failed" }
        T.eq(st:nextFetch(L, order), 8, "a failed picture is not fetched again")
    end,
    decodes_pictures_with_bytes_and_no_picture = function()
        local L, ps = page()
        local st, order = inline.new(), inline.order(L, ps)
        T.eq(st:nextDecode(L, order), nil)
        st.byUrl[u(41)] = { state = "ready", bytes = "x" }
        T.eq(st:nextDecode(L, order), 7)
        st.byUrl[u(41)].img = {}
        T.eq(st:nextDecode(L, order), nil)
    end,
    drops_decoded_pictures_outside_the_window = function()
        local L, ps = page()
        local st, order = inline.new(), inline.order(L, ps)
        st.byUrl[u(15)] = { state = "ready", img = {} }               -- outside, no bytes
        st.byUrl[u(55)] = { state = "ready", img = {}, bytes = "x" } -- outside, bytes kept
        st.byUrl[u(31)] = { state = "ready", img = {} }               -- inside
        local drops = st:drops(L, order)
        T.eq(table.concat(drops, " "), u(15) .. " " .. u(55))
        for _, url in ipairs(drops) do st:drop(url) end
        T.eq(st.byUrl[u(15)], nil, "nothing left: removed, so it is fetched again")
        T.eq(st.byUrl[u(55)].img, nil); T.eq(st.byUrl[u(55)].bytes, "x")
        T.ok(st.byUrl[u(31)].img)
    end,
    keeps_compressed_bytes_up_to_the_cap = function()
        local st, big = inline.new(), string.rep("x", 200 * 1024)
        for _, name in ipairs({ "a", "b", "c", "d", "e" }) do st.byUrl[name] = { state = "ready" } end
        st.byUrl.b.img = {}
        st:keepBytes("a", big); st:keepBytes("b", big)
        T.eq(st.bytesTotal, 400 * 1024)
        st:keepBytes("c", big)
        T.eq(st.byUrl.a, nil, "the oldest went, and with nothing left its entry")
        T.eq(st.bytesTotal, 400 * 1024)
        st:touch("b")
        st:keepBytes("d", big)
        T.eq(st.byUrl.c, nil, "b was used more recently than c"); T.eq(st.byUrl.b.bytes, big)
        st:keepBytes("e", big)
        T.eq(st.byUrl.b.bytes, nil); T.ok(st.byUrl.b.img, "b is decoded: its entry stays")
        st:fail("d")
        T.eq(st.byUrl.d.state, "failed"); T.eq(st.byUrl.d.bytes, nil)
        T.eq(st.bytesTotal, 200 * 1024); T.eq(table.concat(st.lru, ","), "e")
        local one = inline.new()
        one.byUrl.z = { state = "ready" }
        one:keepBytes("z", string.rep("x", 600 * 1024))
        T.ok(one.byUrl.z.bytes, "the newest is kept even over the cap")
    end,
}
