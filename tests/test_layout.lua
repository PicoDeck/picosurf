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
}
