local T = require("tests.t")
local wrap = require("src.wrap")
local layout = require("src.layout")
local g = require("src.gemtext")
local fakepc = require("tests.fakepc")
local fonts = require("src.fonts")
local theme = require("src.theme")

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

-- Advances for width tests: 'i' 3 px, 'm' 9, everything else 6.
local function propAdv()
    local adv = { widest = 9 }
    for c = 32, 126 do adv[c] = 6 end
    adv[("i"):byte()], adv[("m"):byte()] = 3, 9
    return adv
end

local function prows(text, width, adv)
    local s, e = wrap.wrap(text, width, adv)
    local out = {}
    for i = 1, #s do out[i] = text:sub(s[i], e[i]) end
    return table.concat(out, "|")
end

-- Proportional metrics: 'i' 3 px, 'm' 9, bold one px wider, the rest 6;
-- 14 px rows for boxes.
local function propMetrics(width)
    local adv, bold = { widest = 9 }, { widest = 10 }
    for c = 32, 126 do adv[c], bold[c] = 6, 7 end
    adv[("i"):byte()], adv[("m"):byte()] = 3, 9
    bold[("i"):byte()], bold[("m"):byte()] = 4, 10
    return { width = width, adv = adv, boldAdv = bold, indent = 12, preCols = 5,
             boxRows = function(h) return (h + 4 + 13) // 14 end }
end

local SAMPLE = "# A heading that wraps on the narrow screen\nsome text that goes on long enough to wrap twice or more on screen\n"
    .. "* a list item long enough to wrap onto a second row\n> a quote long enough to wrap onto a second row\n"
    .. "```\n" .. string.rep("code ", 14) .. "\n```\n=> https://a.test/ [1] a link label that wraps on the screen\n"

return {
    lays_out_by_measured_width = function()
        local L = layout.build(g.parse("aaaa aaaa\n# aaaa aaaa\n* aaaa aaaa\n```\nabcdefgh\n```\n"), propMetrics(54))
        local got = {}
        for r = 1, L.count do got[r] = L.style[r] .. ":" .. layout.rowText(L, r) end
        T.eq(table.concat(got, "|"), table.concat({
            layout.TEXT .. ":aaaa aaaa", -- 54 px exactly
            layout.H1 .. ":aaaa", layout.H1 .. ":aaaa", -- 63 px in bold: too wide
            layout.ITEM .. ":aaaa", layout.ITEMC .. ":aaaa", -- 54 - 12 = 42 px for items
            layout.PRE .. ":abcde", layout.PRE .. ":fgh", -- cut at preCols, not by width
        }, "|"))
    end,
    boxes_are_picture_heights_turned_into_rows = function()
        local lines = g.parse(IMGPAGE)
        local L = layout.build(lines, propMetrics(60), { [1] = 120 })
        T.eq(L.links[1].last - L.links[1].first + 1, 9, "120 px on 14 px rows")
    end,
    scientifica_and_8x12_lay_out_as_columns_did = function()
        local F = fakepc.new()
        local d = F.pc.display
        local lines = g.parse(SAMPLE)
        local sci = theme.new(d, fonts.load(d, "/apps/picosurf", "scientifica"))
        T.eq(snapshot(layout.build(lines, theme.metrics(sci))), snapshot(layout.build(lines, layout.mono(52))))
        local big = theme.new(d, fonts.load(d, "/apps/picosurf", "8x12"))
        T.eq(snapshot(layout.build(lines, theme.metrics(big))), snapshot(layout.build(lines, layout.mono(39))))
    end,
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
        local L = layout.build(g.parse("# Title\nhello world foo\n* item text here\n> quoted words\n\n"), layout.mono(10))
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
        local L = layout.build(g.parse("```\nabcdefghijklm\n\n```\n"), layout.mono(6))
        T.eq(L.count, 4)
        T.eq(layout.rowText(L, 1), "abcde"); T.eq(L.cont[1], true)
        T.eq(layout.rowText(L, 2), "fghij"); T.eq(L.cont[2], true)
        T.eq(layout.rowText(L, 3), "klm"); T.eq(L.cont[3], false)
        T.eq(layout.rowText(L, 4), ""); T.eq(L.style[4], layout.PRE)
    end,
    links_record_their_rows = function()
        local lines = g.parse("intro\n=> https://a.test/ [1] a long link label\n=> https://a.test/c.jpg [IMG] Cat\n")
        lines[#lines + 1] = { t = "link", url = "https://a.test/r", text = "read one", dim = true }
        local L = layout.build(lines, layout.mono(10))
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
        local L = layout.build(g.parse(table.concat(parts, "\n")), layout.mono(52))
        T.eq(L.count, 10000, "100 characters at 52 columns is two rows per line")
        T.ok(os.clock() - started < 3, "layout took under 3 s on the host")
    end,
    boxes_replace_a_picture_label_with_box_rows = function()
        local lines = g.parse(IMGPAGE)
        local L = layout.build(lines, layout.mono(10), { [1] = 4 })
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
        T.eq(snapshot(layout.build(lines, layout.mono(10), { [2] = 5 })), snapshot(layout.build(lines, layout.mono(10))))
    end,
    set_box_matches_build_with_the_same_boxes = function()
        -- Pictures at the start (link 1), in the middle with a wrapped label
        -- (link 2) and at the end (link 4); link 3 is not a picture.
        local text = "=> https://a.test/0.jpg [IMG] first\n" .. IMGPAGE
            .. "=> https://a.test/z.jpg [IMG] the last picture on the page\n"
        local lines = g.parse(text)
        for _, case in ipairs({ { 1, 3 }, { 2, 1 }, { 2, 5 }, { 4, 2 }, { 4, 10 } }) do
            local k, rows = case[1], case[2]
            local L = layout.build(lines, layout.mono(10))
            local before = L.count
            local delta = layout.setBox(L, k, rows)
            local want = layout.build(lines, layout.mono(10), { [k] = rows })
            T.eq(snapshot(L), snapshot(want), "link " .. k .. " as " .. rows .. " rows")
            T.eq(delta, want.count - before, "delta for link " .. k)
            T.eq(L.line[L.count + 1], nil, "nothing left past the end")
        end
        -- Two boxes, then the first resized again.
        local L = layout.build(lines, layout.mono(10))
        layout.setBox(L, 2, 6); layout.setBox(L, 4, 3); layout.setBox(L, 2, 2)
        T.eq(snapshot(L), snapshot(layout.build(lines, layout.mono(10), { [2] = 2, [4] = 3 })))
    end,
    wrap_by_width_breaks_at_spaces_by_measured_width = function() -- Review Focus 1
        local adv = propAdv()
        T.eq(prows("iiii iiii", 30, adv), "iiii iiii", "30 px exactly")
        T.eq(prows("iiii iiii", 29, adv), "iiii|iiii")
        T.eq(prows("mm mm", 24, adv), "mm|mm")
        T.eq(prows("mmmm", 20, adv), "mm|mm", "a word wider than the row is split by width")
        T.eq(prows("ab", 2, adv), "a|b", "narrower than any glyph: one byte a row")
        T.eq(prows("ab   cd", 18, adv), "ab|cd", "spaces at a break are dropped")
        T.eq(prows("", 18, adv), "")
    end,
    wrap_counts_unknown_bytes_as_the_widest = function() -- Review Focus 2
        local adv = propAdv()
        local text = "a" .. string.char(200) .. "b" -- 6 + 9 + 6 = 21 px
        T.eq(#wrap.wrap(text, 21, adv), 1)
        T.eq(prows(text, 20, adv), "a" .. string.char(200) .. "|b")
    end,
    wrap_of_a_monospace_font_counts_columns = function()
        local uni = { uniform = 6, widest = 6 }
        for c = 32, 126 do uni[c] = 6 end
        T.eq(prows("hello world", 30, uni), rows("hello world", 5))
        T.eq(prows("hello world", 66, uni), rows("hello world", 11))
        T.eq(prows("ab", 4, uni), "a|b", "narrower than a cell: one column")
    end,
    fit_keeps_the_longest_prefix_that_fits = function()
        local adv = propAdv()
        T.eq(wrap.fit("aamm", 21, adv), "aam")
        T.eq(wrap.fit("aamm", 20, adv), "aa")
        T.eq(wrap.fit("ab", 100, adv), "ab")
        T.eq(wrap.fit("m", 5, adv), "")
    end,
}
