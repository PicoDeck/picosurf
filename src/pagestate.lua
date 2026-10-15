-- Scroll position, link selection and the typed link number of one page
-- (spec 6.4). Pure.
local M = {}
M.__index = M

local keepSelectionVisible

-- L: a layout (layout.build); visible: how many rows fit on screen. The
-- topmost visible link starts selected, so Enter opens it and Tab moves on.
function M.new(L, visible)
    local ps = setmetatable({ L = L, visible = visible, top = 1, sel = nil, digits = "" }, M)
    keepSelectionVisible(ps)
    return ps
end

function M:maxTop()
    return math.max(1, self.L.count - self.visible + 1)
end

function M:lastVisible()
    return math.min(self.L.count, self.top + self.visible - 1)
end

local function isVisible(self, k)
    local link = self.L.links[k]
    return link.last >= self.top and link.first <= self:lastVisible()
end

function M:visibleLinks()
    local out = {}
    for k = 1, #self.L.links do
        if isVisible(self, k) then out[#out + 1] = k end
    end
    return out
end

-- Keeps a link selected while one is on screen: when nothing is selected, or
-- the selected link has scrolled off (either way), the topmost visible link is
-- chosen, preferring one that starts on screen over the tail of a wrapped
-- link above it. With no link on screen, nothing is selected.
function keepSelectionVisible(self)
    if self.sel and isVisible(self, self.sel) then return end
    local vis = self:visibleLinks()
    self.sel = vis[1]
    for _, k in ipairs(vis) do
        if self.L.links[k].first >= self.top then
            self.sel = k
            break
        end
    end
end

function M:scroll(n)
    local t = math.max(1, math.min(self:maxTop(), self.top + n))
    if t == self.top then return false end
    self.top = t
    keepSelectionVisible(self)
    return true
end

function M:page(dir)
    return self:scroll(dir * math.max(1, self.visible - 1))
end

function M:nextLink(dir)
    local vis = self:visibleLinks()
    if #vis == 0 then return false end
    if not self.sel then
        self.sel = dir > 0 and vis[1] or vis[#vis]
        return true
    end
    for i, k in ipairs(vis) do
        if k == self.sel then
            local j = i + dir
            if j < 1 then j = #vis elseif j > #vis then j = 1 end
            self.sel = vis[j]
            return true
        end
    end
    self.sel = vis[1]
    return true
end

function M:selected()
    return self.sel and self.L.links[self.sel] or nil
end

function M:typeDigit(c)
    if #self.digits < 4 then self.digits = self.digits .. c end
end

function M:eraseDigit()
    self.digits = self.digits:sub(1, -2)
end

function M:clearDigits()
    self.digits = ""
end

-- The link labelled [n] for the typed number, or nil and n. Clears the digits.
function M:takeNumbered()
    local n = math.tointeger(tonumber(self.digits))
    self.digits = ""
    if not n then return nil end
    for _, link in ipairs(self.L.links) do
        if link.n == n then return link end
    end
    return nil, n
end

function M:percent()
    local m = self:maxTop()
    if m <= 1 then return 100 end
    return ((self.top - 1) * 100) // (m - 1)
end

function M:restore(top, sel)
    self.top = math.max(1, math.min(self:maxTop(), top or 1))
    self.sel = (sel and self.L.links[sel]) and sel or nil
    keepSelectionVisible(self)
end

return M
