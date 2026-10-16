-- Word wrap (spec 6.3, proportional fonts spec 5.1). Pure. Rows are 1-based
-- inclusive byte ranges; text has no newlines (one gemtext line at a time).
local M = {}

-- Rows of at most `width` bytes.
local function columns(text, width)
    local s, e = {}, {}
    local n, i = #text, 1
    if n == 0 then return { 1 }, { 0 } end
    while i <= n do
        if n - i + 1 <= width then
            s[#s + 1], e[#e + 1] = i, n
            break
        end
        local cut
        for j = i + width, i + 1, -1 do
            if text:byte(j) == 32 then cut = j; break end
        end
        if cut then
            local k = cut - 1
            while k > i and text:byte(k) == 32 do k = k - 1 end
            s[#s + 1], e[#e + 1] = i, k
            i = cut + 1
            while i <= n and text:byte(i) == 32 do i = i + 1 end
        else
            s[#s + 1], e[#e + 1] = i, i + width - 1
            i = i + width
        end
    end
    return s, e
end

-- Rows of at most `width` px, each byte measured by adv (bytes it lacks as
-- adv.widest), so nothing can overflow a row.
local function proportional(text, width, adv)
    local s, e = {}, {}
    local n, i = #text, 1
    if n == 0 then return { 1 }, { 0 } end
    local byte, wide = string.byte, adv.widest or 1
    while i <= n do
        local w, j = 0, i
        while j <= n do
            local a = adv[byte(text, j)] or wide
            if w + a > width then break end
            w, j = w + a, j + 1
        end
        if j > n then
            s[#s + 1], e[#e + 1] = i, n
            break
        end
        -- text[i..j-1] fits and text[j] doesn't: break at the last space.
        local cut
        for k = j, i + 1, -1 do
            if byte(text, k) == 32 then cut = k; break end
        end
        if cut then
            local k = cut - 1
            while k > i and byte(text, k) == 32 do k = k - 1 end
            s[#s + 1], e[#e + 1] = i, k
            i = cut + 1
            while i <= n and byte(text, i) == 32 do i = i + 1 end
        else
            local last = math.max(j - 1, i) -- at least one byte a row, however narrow
            s[#s + 1], e[#e + 1] = i, last
            i = last + 1
        end
    end
    return s, e
end

-- Returns starts, ends: row k is text:sub(starts[k], ends[k]). Breaks at the
-- last space that fits, splits words longer than a row, and drops the spaces
-- at a break. Empty text gives one empty row. adv: optional byte -> advance
-- table (fonts.lua), and width is then in px; without it every byte is one
-- column. A monospace font (adv.uniform) wraps by columns of that width.
function M.wrap(text, width, adv)
    if not adv then return columns(text, width) end
    if adv.uniform then return columns(text, math.max(1, width // adv.uniform)) end
    return proportional(text, width, adv)
end

-- The longest prefix of text no wider than px, cut anywhere (one-line labels).
function M.fit(text, px, adv)
    local w, wide = 0, adv.widest or 1
    for i = 1, #text do
        w = w + (adv[text:byte(i)] or wide)
        if w > px then return text:sub(1, i - 1) end
    end
    return text
end

return M
