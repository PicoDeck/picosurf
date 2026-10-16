-- Typed lines into screen rows (spec 6.3). Pure. Rows are parallel integer
-- arrays pointing into the lines' text, so a 256 KB page doesn't copy its text.
local wrap = require("src.wrap")

local M = {}
M.TEXT, M.H1, M.H2, M.H3, M.ITEM, M.ITEMC = 1, 2, 3, 4, 5, 6
M.QUOTE, M.PRE, M.LINK, M.IMAGE, M.BLANK, M.READ, M.BOX = 7, 8, 9, 10, 11, 12, 13

local HEADINGS = { h1 = M.H1, h2 = M.H2, h3 = M.H3 }

-- m: layout metrics (proportional fonts spec 5.2): width, and adv and
-- boldAdv (byte -> advance, see fonts.lua; nil: every byte 1 wide), all in
-- the same units; indent (list items and quotes), preCols (columns of a
-- preformatted line) and boxRows(h) (the rows of an inline picture box h px
-- tall). boxes: optional {[k] = picture height}: image link k is laid out as
-- m.boxRows(boxes[k]) BOX rows (inline images spec 5.4) instead of its label.
function M.build(lines, m, boxes)
    local L = { count = 0, line = {}, s = {}, e = {}, style = {}, link = {}, cont = {}, text = {}, links = {} }
    local function add(li, s, e, style, link, cont)
        local n = L.count + 1
        L.count = n
        L.line[n], L.s[n], L.e[n], L.style[n], L.link[n], L.cont[n] = li, s, e, style, link, cont
    end
    for li, ln in ipairs(lines) do
        local t = ln.t
        L.text[li] = ln.text
        if t == "blank" then
            add(li, 1, 0, M.BLANK, 0, false)
        elseif t == "pre" then
            local text, w = ln.text, m.preCols
            if #text == 0 then add(li, 1, 0, M.PRE, 0, false) end
            local i = 1
            while i <= #text do
                local j = math.min(i + w - 1, #text)
                add(li, i, j, M.PRE, 0, j < #text)
                i = j + 1
            end
        else
            local style, width, adv, link = HEADINGS[t] or M.TEXT, m.width, m.adv, 0
            if HEADINGS[t] then
                adv = m.boldAdv
            elseif t == "item" then
                style, width = M.ITEM, m.width - m.indent
            elseif t == "quote" then
                style, width = M.QUOTE, m.width - m.indent
            elseif t == "link" then
                style = ln.image and M.IMAGE or (ln.dim and M.READ or M.LINK)
                L.links[#L.links + 1] = { url = ln.url, label = ln.text, n = ln.n, image = ln.image,
                                          line = li, first = L.count + 1, last = 0 }
                link = #L.links
            end
            local h = boxes and ln.image and boxes[link]
            if h then
                for _ = 1, m.boxRows(h) do add(li, 1, 0, M.BOX, link, false) end
            else
                local s, e = wrap.wrap(ln.text, width, adv)
                for k = 1, #s do
                    add(li, s[k], e[k], (style == M.ITEM and k > 1) and M.ITEMC or style, link, false)
                end
            end
            if link > 0 then L.links[link].last = L.count end
        end
    end
    return L
end

-- Metrics for a layout counted in columns: every byte one wide, a two-column
-- indent. Boxes are given in rows (boxRows passes them on), as tests do.
function M.mono(cols)
    return { width = cols, indent = 2, preCols = cols - 1, boxRows = function(rows) return rows end }
end

local ROW_FIELDS = { "line", "s", "e", "style", "link", "cont" }

-- Lays link k out as `rows` BOX rows in place, as build would with
-- boxes[k] = rows: the rows after it move, later links' rows shift and the
-- count changes. Returns that change (negative when the box shrank).
function M.setBox(L, k, rows)
    local link = L.links[k]
    local first, last, count = link.first, link.last, L.count
    local delta = rows - (last - first + 1)
    if delta ~= 0 then
        for _, f in ipairs(ROW_FIELDS) do
            local a = L[f]
            table.move(a, last + 1, count, last + 1 + delta)
            for r = count + delta + 1, count do a[r] = nil end -- only when it shrank
        end
        L.count = count + delta
        for j = k + 1, #L.links do
            local o = L.links[j]
            o.first, o.last = o.first + delta, o.last + delta
        end
        link.last = last + delta
    end
    local li = L.line[first]
    for r = first, link.last do
        L.line[r], L.s[r], L.e[r], L.style[r], L.link[r], L.cont[r] = li, 1, 0, M.BOX, k, false
    end
    return delta
end

function M.rowText(L, r)
    return L.text[L.line[r]]:sub(L.s[r], L.e[r])
end

return M
