-- Inline pictures on one page (inline images spec 5.1): which picture to
-- fetch or decode next, which decoded ones to drop, the compressed bytes kept,
-- and a box's rows from a picture's height. Pure: the app makes the requests
-- and decodes.
local url = require("src.url")

local M = {}
M.__index = M

-- A box is at most ROWS rows; its picture has PAD px above and below it and
-- fits FIT_W (the page width less its margins) by FIT_H: ten 13 px rows less
-- the padding. On 14 px rows (Sans) the same pictures take at most 10 rows.
M.ROWS, M.PAD = 10, 2
M.FIT_W, M.FIT_H = 312, 126
M.FIT = M.FIT_W .. "x" .. M.FIT_H
M.BYTES_CAP = 512 * 1024
M.RETRY_MS = 3000

-- boxes: {[k] = picture height in px} for image links already laid out as boxes (Back, Reload), or nil. wake: something may have changed since the last pass.
function M.new(boxes)
    return setmetatable({ boxes = boxes or {}, byUrl = {}, lru = {}, bytesTotal = 0, wake = true }, M)
end

-- The rows of a box for a picture h px tall, on rows rowH px apart.
function M.rows(h, rowH)
    return (h + 2 * M.PAD + rowH - 1) // rowH
end

-- The image links overlapping the window, which is the screen and one screen
-- above and below it, in loading order: on screen top to bottom, then below
-- nearest first, then above nearest first.
function M.order(L, ps)
    local top, bottom = ps.top, ps:lastVisible()
    local lo, hi = top - ps.visible, bottom + ps.visible
    local out, below, above = {}, {}, {}
    for k, link in ipairs(L.links) do
        if link.first > hi then break end
        if link.image and link.last >= lo then
            if link.first > bottom then
                below[#below + 1] = k
            elseif link.last < top then
                above[#above + 1] = k
            else
                out[#out + 1] = k
            end
        end
    end
    for _, k in ipairs(below) do out[#out + 1] = k end
    for i = #above, 1, -1 do out[#out + 1] = above[i] end
    return out
end

-- The first link in order whose picture was never tried and is on the web.
function M:nextFetch(L, order)
    for _, k in ipairs(order) do
        local u = L.links[k].url
        local scheme = url.scheme(u)
        if not self.byUrl[u] and (scheme == "http" or scheme == "https") then return k, u end
    end
    return nil
end

-- The first link in order whose picture has bytes but isn't decoded.
function M:nextDecode(L, order)
    for _, k in ipairs(order) do
        local e = self.byUrl[L.links[k].url]
        if e and e.state == "ready" and e.bytes and not e.img then return k end
    end
    return nil
end

-- Decoded pictures that no link in the window shows, sorted.
function M:drops(L, order)
    local used = {}
    for _, k in ipairs(order) do used[L.links[k].url] = true end
    local out = {}
    for u, e in pairs(self.byUrl) do
        if e.img and not used[u] then out[#out + 1] = u end
    end
    table.sort(out)
    return out
end

-- Lets a decoded picture go. An entry left with nothing is removed, so the
-- picture is fetched again when it's wanted.
function M:drop(u)
    local e = self.byUrl[u]
    e.img = nil
    if not e.bytes then self.byUrl[u] = nil end
end

local function unlist(self, u)
    for i, v in ipairs(self.lru) do
        if v == u then
            table.remove(self.lru, i)
            return true
        end
    end
    return false
end

-- Marks u's bytes as the most recently used.
function M:touch(u)
    if unlist(self, u) then self.lru[#self.lru + 1] = u end
end

-- Keeps a picture's compressed bytes, dropping the least recently used past
-- BYTES_CAP (never the newest). An entry left with nothing is removed.
function M:keepBytes(u, bytes)
    self.byUrl[u].bytes = bytes
    self.lru[#self.lru + 1] = u
    self.bytesTotal = self.bytesTotal + #bytes
    while self.bytesTotal > M.BYTES_CAP and #self.lru > 1 do
        local old = table.remove(self.lru, 1)
        local o = self.byUrl[old]
        self.bytesTotal = self.bytesTotal - #o.bytes
        o.bytes = nil
        if not o.img then self.byUrl[old] = nil end
    end
end

-- A picture that can't be shown: kept as failed, so it isn't fetched again
-- (until Reload), and its bytes go.
function M:fail(u)
    local e = self.byUrl[u]
    if e.bytes and unlist(self, u) then self.bytesTotal = self.bytesTotal - #e.bytes end
    e.state, e.bytes, e.img = "failed", nil, nil
end

return M
