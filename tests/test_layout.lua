local T = require("tests.t")
local wrap = require("src.wrap")
local layout = require("src.layout")
local g = require("src.gemtext")

local function rows(text, width)
    local s, e = wrap.wrap(text, width)
    local out = {}
    for i = 1, #s do out[i] = text:sub(s[i], e[i]) end
    return table.concat(out, "|")
end

-- 10 columns: "intro words" (rows 1-2), a picture whose label "[IMG] A cat
-- photo" wraps (rows 3-4), "after text here" (rows 5-6), link [1] (row 7).
local IMGPAGE = "intro words\n=> https://a.test/c.jpg [IMG] A cat photo\nafter text here\n=> https://a.test/d [1] dee\n"

-- Every row's fields and every link's rows, as one string.
local function snapshot(L)
    local out = {}
    for r = 1, L.count do
        out[r] = table.concat({ L.line[r], L.s[r], L.e[r], L.style[r], L.link[r], tostring(L.cont[r]) }, ",")
    end
    local links = {}
    for k, l in ipairs(L.links) do links[k] = l.first .. "-" .. l.last end
    return L.count .. ": " .. table.concat(out, "|") .. " / " .. table.concat(links, " ")
end

return {
    wrap_breaks_at_spaces_and_splits_long_words = function()
        T.eq(rows("hello world", 5), "hello|world")
        T.eq(rows("hello world", 11), "hello world")
        T.eq(rows("abcde fgh", 5), "abcde|fgh")
        T.eq(rows("aaa bbb ccc", 7), "aaa bbb|ccc")
        T.eq(rows("abcdefghij", 4), "abcd|efgh|ij")
        T.eq(rows("a   b", 2), "a|b")
    end,
    wrap_gives_one_empty_row_for_empty_text = function()
        local s, e = wrap.wrap("", 10)
        T.eq(#s, 1); T.eq(s[1], 1); T.eq(e[1], 0)
    end,
    builds_rows_with_styles_and_indents = function()
        local L = layout.build(g.parse("# Title\nhello world foo\n* item text here\n> quoted words\n\n"), 10)
        local got = {}
        for r = 1, L.count do got[r] = L.style[r] .. ":" .. layout.rowText(L, r) end
        T.eq(table.concat(got, "|"), table.concat({
            layout.H1 .. ":Title",
            layout.TEXT .. ":hello", layout.TEXT .. ":world foo",
            layout.ITEM .. ":item", layout.ITEMC .. ":text", layout.ITEMC .. ":here",
            layout.QUOTE .. ":quoted", layout.QUOTE .. ":words",
            layout.BLANK .. ":",
        }, "|"))
    end,
    preformatted_rows_are_cut_and_marked = function()
        local L = layout.build(g.parse("```\nabcdefghijklm\n\n```\n"), 6)
        T.eq(L.count, 4)
        T.eq(layout.rowText(L, 1), "abcde"); T.eq(L.cont[1], true)
        T.eq(layout.rowText(L, 2), "fghij"); T.eq(L.cont[2], true)
        T.eq(layout.rowText(L, 3), "klm"); T.eq(L.cont[3], false)
        T.eq(layout.rowText(L, 4), ""); T.eq(L.style[4], layout.PRE)
    end,
    links_record_their_rows = function()
        local lines = g.parse("intro\n=> https://a.test/ [1] a long link label\n=> https://a.test/c.jpg [IMG] Cat\n")
        lines[#lines + 1] = { t = "link", url = "https://a.test/r", text = "read one", dim = true }
        local L = layout.build(lines, 10)
        T.eq(#L.links, 3)
        local a = L.links[1]
        -- "[1] a long link label" at 10 columns wraps to "[1] a long" / "link label".
        T.eq(a.url, "https://a.test/"); T.eq(a.n, 1); T.eq(a.first, 2); T.eq(a.last, 3)
        for r = a.first, a.last do T.eq(L.link[r], 1); T.eq(L.style[r], layout.LINK) end
        T.eq(L.link[1], 0)
        T.eq(L.style[L.links[2].first], layout.IMAGE)
        T.eq(L.style[L.links[3].first], layout.READ)
    end,
    lays_out_a_very_long_page = function() -- Review Focus 1
        local parts = {}
        local line = string.rep("word ", 20)
        for i = 1, 5000 do parts[i] = line end
        local started = os.clock()
        local L = layout.build(g.parse(table.concat(parts, "\n")), 52)
        T.eq(L.count, 10000, "100 characters at 52 columns is two rows per line")
        T.ok(os.clock() - started < 3, "layout took under 3 s on the host")
    end,
    boxes_replace_a_picture_label_with_box_rows = function()
        local lines = g.parse(IMGPAGE)
        local L = layout.build(lines, 10, { [1] = 4 })
        local link = L.links[1]
        T.eq(link.first, 3); T.eq(link.last, 6)
        for r = 3, 6 do
            T.eq(L.style[r], layout.BOX); T.eq(L.link[r], 1); T.eq(L.line[r], 2); T.eq(layout.rowText(L, r), "")
        end
        T.eq(L.links[2].first, 9, "the text after it follows")
        T.eq(L.count, 9)
    end,
    boxes_ignore_links_that_are_not_pictures = function()
        local lines = g.parse(IMGPAGE)
        T.eq(snapshot(layout.build(lines, 10, { [2] = 5 })), snapshot(layout.build(lines, 10)))
    end,
    set_box_matches_build_with_the_same_boxes = function()
        -- Pictures at the start (link 1), in the middle with a wrapped label
        -- (link 2) and at the end (link 4); link 3 is not a picture.
        local text = "=> https://a.test/0.jpg [IMG] first\n" .. IMGPAGE
            .. "=> https://a.test/z.jpg [IMG] the last picture on the page\n"
        local lines = g.parse(text)
        for _, case in ipairs({ { 1, 3 }, { 2, 1 }, { 2, 5 }, { 4, 2 }, { 4, 10 } }) do
            local k, rows = case[1], case[2]
            local L = layout.build(lines, 10)
            local before = L.count
            local delta = layout.setBox(L, k, rows)
            local want = layout.build(lines, 10, { [k] = rows })
            T.eq(snapshot(L), snapshot(want), "link " .. k .. " as " .. rows .. " rows")
            T.eq(delta, want.count - before, "delta for link " .. k)
            T.eq(L.line[L.count + 1], nil, "nothing left past the end")
        end
        -- Two boxes, then the first resized again.
        local L = layout.build(lines, 10)
        layout.setBox(L, 2, 6); layout.setBox(L, 4, 3); layout.setBox(L, 2, 2)
        T.eq(snapshot(L), snapshot(layout.build(lines, 10, { [2] = 2, [4] = 3 })))
    end,
}
