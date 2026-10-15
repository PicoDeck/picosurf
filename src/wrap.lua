-- Word wrap for fixed-width text (spec 6.3). Pure. Rows are 1-based inclusive
-- byte ranges; text has no newlines (one gemtext line at a time).
local M = {}

-- Returns starts, ends: row k is text:sub(starts[k], ends[k]). Breaks at the last
-- space that fits, splits words longer than width, and drops the spaces at a
-- break. Empty text gives one empty row.
function M.wrap(text, width)
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

return M
