local T = require("tests.t")
local layout = require("src.layout")
local pagestate = require("src.pagestate")
local g = require("src.gemtext")

-- 30 rows: link [1] on row 2, [2] on row 15, [3] on row 29.
local function page()
    local parts = {}
    for i = 1, 30 do parts[i] = "line " .. i end
    parts[2] = "=> https://a.test/1 [1] one"
    parts[15] = "=> https://a.test/2 [2] two"
    parts[29] = "=> https://a.test/3 [3] three"
    return pagestate.new(layout.build(g.parse(table.concat(parts, "\n")), 40), 10)
end

return {
    scrolling_is_clamped = function()
        local ps = page()
        T.eq(ps:maxTop(), 21)
        T.eq(ps:scroll(-1), false)
        T.eq(ps:scroll(5), true); T.eq(ps.top, 6)
        ps:scroll(100); T.eq(ps.top, 21); T.eq(ps:lastVisible(), 30)
        ps:page(-1); T.eq(ps.top, 12)
    end,
    percent_runs_from_0_to_100 = function()
        local ps = page()
        T.eq(ps:percent(), 0)
        ps:scroll(10); T.eq(ps:percent(), 50)
        ps:scroll(100); T.eq(ps:percent(), 100)
        local short = pagestate.new(layout.build(g.parse("one\ntwo"), 40), 10)
        T.eq(short:percent(), 100)
    end,
    next_link_selects_among_visible_links_and_wraps = function()
        local ps = page()
        T.eq(ps:nextLink(1), true); T.eq(ps.sel, 1)
        ps:nextLink(1); T.eq(ps.sel, 1, "only [1] is visible on rows 1-10")
        ps:scroll(5) -- rows 6-15
        T.eq(ps.sel, 2, "[1] scrolled off the top, so the first visible link is chosen")
        ps:scroll(-5) -- rows 1-10
        T.eq(ps.sel, 1, "[2] scrolled off the bottom, so the last visible link is chosen")
        ps:scroll(2) -- rows 3-12: no links
        T.eq(ps.sel, nil)
        T.eq(ps:nextLink(1), false)
    end,
    previous_link_starts_from_the_last_visible = function()
        local ps = page()
        ps:scroll(14) -- rows 15-24
        ps:nextLink(-1)
        T.eq(ps:selected().url, "https://a.test/2")
    end,
    typed_numbers_find_links_anywhere_on_the_page = function() -- Review Focus 4
        local ps = page()
        ps:typeDigit("3")
        T.eq(ps.digits, "3")
        local link = ps:takeNumbered()
        T.eq(link.url, "https://a.test/3")
        T.eq(ps.digits, "")
        ps:typeDigit("9"); ps:typeDigit("9")
        local missing, n = ps:takeNumbered()
        T.eq(missing, nil); T.eq(n, 99)
        T.eq(ps:takeNumbered(), nil, "no digits")
    end,
    digits_are_capped_and_editable = function()
        local ps = page()
        for _, d in ipairs({ "1", "2", "3", "4", "5" }) do ps:typeDigit(d) end
        T.eq(ps.digits, "1234")
        ps:eraseDigit(); T.eq(ps.digits, "123")
        ps:clearDigits(); T.eq(ps.digits, "")
    end,
    restore_clamps_and_drops_hidden_selection = function()
        local ps = page()
        ps:restore(500, 1)
        T.eq(ps.top, 21)
        T.eq(ps.sel, 3, "[1] is off screen, so the nearest visible link is chosen")
        ps:restore(1, nil)
        T.eq(ps.sel, nil)
    end,
    scrolls_to_the_end_of_a_very_long_page = function() -- Review Focus 1
        local parts = {}
        for i = 1, 5000 do parts[i] = "line " .. i end
        local ps = pagestate.new(layout.build(g.parse(table.concat(parts, "\n")), 52), 21)
        while ps:page(1) do end
        T.eq(ps:percent(), 100)
        T.eq(ps:lastVisible(), 5000)
    end,
}
