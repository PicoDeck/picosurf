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

-- One link per row (a feed list): rows 1-30 are links [1]..[30].
local function list()
    local parts = {}
    for i = 1, 30 do parts[i] = "=> https://a.test/" .. i .. " item " .. i end
    return pagestate.new(layout.build(g.parse(table.concat(parts, "\n")), 40), 10)
end

-- Text with links on rows 2 and 5 and nothing else until row 40.
local function sparse()
    local parts = {}
    for i = 1, 40 do parts[i] = "line " .. i end
    parts[2] = "=> https://a.test/1 one"
    parts[5] = "=> https://a.test/2 two"
    return pagestate.new(layout.build(g.parse(table.concat(parts, "\n")), 40), 10)
end

return {
    arrows_walk_a_list_link_by_link = function()
        local ps = list()
        T.eq(ps.sel, 1)
        for _ = 1, 9 do ps:step(1) end
        T.eq(ps.sel, 10); T.eq(ps.top, 1, "all on the first screen: no scrolling")
        ps:step(1)
        T.eq(ps.sel, 11); T.eq(ps.top, 2, "the next item is scrolled into view")
        for _ = 1, 9 do ps:step(-1) end
        T.eq(ps.sel, 2); T.eq(ps.top, 2)
        ps:step(-1)
        T.eq(ps.sel, 1); T.eq(ps.top, 1, "the previous item is scrolled into view")
        T.eq(ps:step(-1), false, "nothing above the first item")
    end,
    arrows_scroll_text_and_pick_up_links_both_ways = function()
        local ps = sparse()
        T.eq(ps.sel, 1)
        ps:step(1); T.eq(ps.sel, 2); T.eq(ps.top, 1)
        ps:step(1); T.eq(ps.sel, 2); T.eq(ps.top, 2, "no link below: scroll a row")
        for _ = 1, 18 do ps:step(1) end
        T.eq(ps.top, 20); T.eq(ps.sel, nil, "the links scrolled away")
        while ps.sel == nil do ps:step(-1) end
        T.eq(ps.sel, 2, "scrolling back up selects the last link as it comes near")
        T.eq(ps.top, 5, "and shows it")
        ps:step(-1); T.eq(ps.sel, 1); T.eq(ps.top, 2)
        ps:step(-1); T.eq(ps.sel, 1); T.eq(ps.top, 1, "then scrolls to the top")
    end,
    arrows_reach_the_first_link_after_scrolling = function()
        local ps = list()
        ps:page(1); ps:page(1) -- rows 19-28
        T.eq(ps.sel, 19)
        for _ = 1, 18 do ps:step(-1) end
        T.eq(ps.sel, 1); T.eq(ps.top, 1)
    end,
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
    opening_selects_the_topmost_visible_link = function()
        T.eq(page().sel, 1, "[1] on row 2 is the first link on screen")
        local none = pagestate.new(layout.build(g.parse("one\ntwo"), 40), 10)
        T.eq(none.sel, nil, "no links, no selection")
    end,
    next_link_selects_among_visible_links_and_wraps = function()
        local ps = page()
        T.eq(ps:nextLink(1), true); T.eq(ps.sel, 1, "only [1] is visible on rows 1-10")
        ps:scroll(5) -- rows 6-15
        T.eq(ps.sel, 2, "[1] scrolled off the top, so the topmost visible link is chosen")
        ps:scroll(2) -- rows 8-17: [2] is still on screen
        T.eq(ps.sel, 2)
        ps:scroll(-7) -- rows 1-10
        T.eq(ps.sel, 1, "[2] scrolled off the bottom, so the topmost visible link is chosen")
        ps:scroll(2) -- rows 3-12: no links
        T.eq(ps.sel, nil)
        T.eq(ps:nextLink(1), false)
        ps:scroll(4) -- rows 7-16: [2] comes into view
        T.eq(ps.sel, 2, "a link scrolled into view is selected")
    end,
    scrolling_up_past_the_selection_picks_the_topmost_link = function()
        local parts = {}
        for i = 1, 30 do parts[i] = "line " .. i end
        parts[2] = "=> https://a.test/1 [1] one"
        parts[8] = "=> https://a.test/2 [2] two"
        parts[15] = "=> https://a.test/3 [3] three"
        local ps = pagestate.new(layout.build(g.parse(table.concat(parts, "\n")), 40), 10)
        ps:scroll(7) -- rows 8-17: [2] and [3]
        T.eq(ps.sel, 2)
        ps:nextLink(1); T.eq(ps.sel, 3, "Tab moves on from the selected link")
        ps:scroll(-7) -- rows 1-10: [3] is gone; [1] and [2] are on screen
        T.eq(ps.sel, 1, "the topmost, not the nearest")
    end,
    a_link_that_starts_on_screen_beats_a_tail = function()
        local long = "=> https://a.test/1 " .. string.rep("word ", 20) -- wraps to 3 rows at 40
        local L = layout.build(g.parse(long .. "\nx\n=> https://a.test/2 two\n" .. string.rep("y\n", 20)), 40)
        T.eq(L.links[1].first, 1); T.eq(L.links[1].last, 3)
        local ps = pagestate.new(L, 10)
        ps:restore(3, nil) -- row 3 is [1]'s last row
        T.eq(ps.sel, 2, "[2] starts on screen; only [1]'s tail shows")
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
        T.eq(ps.sel, 3, "[1] is off screen, so the topmost visible link is chosen")
        ps:restore(1, nil)
        T.eq(ps.sel, 1, "no saved selection: the topmost visible link")
        ps:restore(3, 1) -- rows 3-12: no links
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
