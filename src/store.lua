-- Bookmarks, history and feeds on the SD card (spec 6.6). fs and json are
-- passed in so tests can fake them.
local M = {}
M.__index = M
M.MAX_BOOKMARKS, M.MAX_HISTORY = 200, 100

function M.new(fs, json, dir)
    local s = setmetatable({ fs = fs, json = json, dir = dir, notes = {} }, M)
    fs.mkdir(dir)
    fs.mkdir(dir .. "/feeds")
    return s
end

function M:path(name)
    return self.dir .. "/" .. name
end

-- A missing file gives `default`. A save interrupted before its rename left
-- only <name>.tmp: that becomes the file. An unreadable file is renamed
-- <name>.bad and reported in self.notes.
function M:load(name, default)
    local fs, p = self.fs, self:path(name)
    if not fs.exists(p) and fs.exists(p .. ".tmp") then fs.rename(p .. ".tmp", p) end
    local text = fs.readFile(p)
    if text == nil then return default end
    local value = self.json.decode(text)
    if type(value) ~= "table" then
        fs.delete(p .. ".bad")
        fs.rename(p, p .. ".bad")
        self.notes[#self.notes + 1] = name .. " was unreadable; started empty"
        return default
    end
    return value
end

-- Writes <name>.tmp, deletes <name>, renames: the device's rename fails when
-- the destination exists, and a power cut leaves either the old file or the
-- .tmp that load() recovers.
function M:save(name, value)
    local fs, p = self.fs, self:path(name)
    local ok, text = pcall(self.json.encode, value)
    if not ok then return false end
    local f = fs.open(p .. ".tmp", "w")
    if not f then return false end
    local written = fs.write(f, text)
    fs.close(f)
    if written ~= #text then
        fs.delete(p .. ".tmp")
        return false
    end
    fs.delete(p)
    return fs.rename(p .. ".tmp", p) == true
end

local function indexOf(list, u)
    for i, v in ipairs(list) do
        if v.url == u then return i end
    end
    return nil
end

function M:bookmarks()
    if not self._bookmarks then self._bookmarks = self:load("bookmarks.json", {}) end
    return self._bookmarks
end

function M:isBookmarked(u)
    return indexOf(self:bookmarks(), u) ~= nil
end

-- Adds the page, or removes it when already bookmarked. Returns true when added.
function M:toggleBookmark(u, title)
    local list = self:bookmarks()
    local i = indexOf(list, u)
    if i then
        table.remove(list, i)
        self:save("bookmarks.json", list)
        return false
    end
    table.insert(list, 1, { url = u, title = title or u })
    while #list > M.MAX_BOOKMARKS do table.remove(list) end
    self:save("bookmarks.json", list)
    return true
end

function M:removeBookmark(i)
    table.remove(self:bookmarks(), i)
    self:save("bookmarks.json", self:bookmarks())
end

function M:history()
    if not self._history then self._history = self:load("history.json", {}) end
    return self._history
end

function M:addHistory(u, title)
    local list = self:history()
    local i = indexOf(list, u)
    if i then table.remove(list, i) end
    table.insert(list, 1, { url = u, title = title or u })
    while #list > M.MAX_HISTORY do table.remove(list) end
    self:save("history.json", list)
end

function M:removeHistory(i)
    table.remove(self:history(), i)
    self:save("history.json", self:history())
end

function M:feedIndex()
    if not self._feedIndex then self._feedIndex = self:load("feeds/index.json", { next_id = 1, feeds = {} }) end
    return self._feedIndex
end

function M:saveFeedIndex()
    return self:save("feeds/index.json", self:feedIndex())
end

function M:feedData(id)
    local data = self:load("feeds/" .. id .. ".json", nil) or {}
    data.items, data.seen = data.items or {}, data.seen or {}
    return data
end

function M:saveFeedData(id, data)
    return self:save("feeds/" .. id .. ".json", data)
end

function M:deleteFeedData(id)
    self.fs.delete(self:path("feeds/" .. id .. ".json"))
end

return M
