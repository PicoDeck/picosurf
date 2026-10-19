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
-- only <name>.tmp: that becomes the file, or, if that rename fails, the .tmp
-- is read in place. A file that exists but can't be read or decoded, or that
-- fails valid(value), is renamed <name>.bad (so the next save can't replace
-- it) and reported in self.notes.
function M:load(name, default, valid)
    local fs, p = self.fs, self:path(name)
    local tmp = p .. ".tmp"
    local src = p
    if not fs.exists(p) and fs.exists(tmp) then
        if not fs.rename(tmp, p) then src = tmp end
    end
    local text = fs.readFile(src)
    if text == nil and not fs.exists(src) then return default end
    local value = text and self.json.decode(text)
    if type(value) ~= "table" or (valid ~= nil and not valid(value)) then
        fs.delete(p .. ".bad")
        fs.rename(src, p .. ".bad")
        self.notes[#self.notes + 1] = name .. " was unreadable; started empty"
        return default
    end
    return value
end

-- Writes <name>.tmp and checks its size, then deletes <name> and renames.
-- The device's rename fails when the destination exists, and a power cut
-- leaves either the old file or the .tmp that load() recovers. Every failure
-- before the delete leaves the original untouched; every failure is reported
-- in self.notes.
function M:save(name, value)
    local fs, p = self.fs, self:path(name)
    local tmp = p .. ".tmp"
    local ok, text = pcall(self.json.encode, value)
    if not ok then return self:saveFailed(name) end
    local f = fs.open(tmp, "w")
    if not f then return self:saveFailed(name) end
    local written = fs.write(f, text)
    fs.close(f)
    -- The device's fs.close returns nothing, so a flush that failed on a full
    -- card shows only as a size that disagrees with what was written.
    if written ~= #text or fs.size(tmp) ~= #text then
        fs.delete(tmp)
        return self:saveFailed(name)
    end
    fs.delete(p)
    if fs.rename(tmp, p) == true then return true end
    return self:saveFailed(name)
end

function M:saveFailed(name)
    self.notes[#self.notes + 1] = "Couldn't save " .. name
    return false
end

local function indexOf(list, u)
    for i, v in ipairs(list) do
        if v.url == u then return i end
    end
    return nil
end

-- A list of entries, each a table with a string url.
local function validEntries(list)
    for _, v in ipairs(list) do
        if type(v) ~= "table" or type(v.url) ~= "string" then return false end
    end
    return true
end

local function optString(v)
    return v == nil or type(v) == "string"
end

-- The fields the UI relies on: an integer id, a url, and an optional title
-- and newest date.
local function validIndex(v)
    if math.tointeger(v.next_id) == nil or type(v.feeds) ~= "table" then return false end
    for _, f in ipairs(v.feeds) do
        if type(f) ~= "table" or type(f.id) ~= "number" or math.tointeger(f.id) == nil
            or type(f.url) ~= "string" or not optString(f.title) or not optString(f.newest) then
            return false
        end
    end
    return true
end

-- Items each need a url; date and title are optional strings.
local function validFeedData(v)
    if type(v.items) ~= "table" or (v.seen ~= nil and type(v.seen) ~= "table") then return false end
    for _, it in ipairs(v.items) do
        if type(it) ~= "table" or type(it.url) ~= "string" or not optString(it.date) or not optString(it.title) then
            return false
        end
    end
    return true
end

function M:bookmarks()
    if not self._bookmarks then self._bookmarks = self:load("bookmarks.json", {}, validEntries) end
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

-- Appends the entries ({url, title}) not already bookmarked, within the cap.
-- Returns how many were added.
function M:appendBookmarks(entries)
    local list, n = self:bookmarks(), 0
    for _, e in ipairs(entries) do
        if #list >= M.MAX_BOOKMARKS then break end
        if not indexOf(list, e.url) then
            list[#list + 1] = { url = e.url, title = e.title }
            n = n + 1
        end
    end
    if n > 0 then self:save("bookmarks.json", list) end
    return n
end

function M:removeBookmark(i)
    local list = self:bookmarks()
    if list[i] == nil then return end
    table.remove(list, i)
    self:save("bookmarks.json", list)
end

function M:history()
    if not self._history then self._history = self:load("history.json", {}, validEntries) end
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
    local list = self:history()
    if list[i] == nil then return end
    table.remove(list, i)
    self:save("history.json", list)
end

function M:feedIndex()
    if not self._feedIndex then
        self._feedIndex = self:load("feeds/index.json", { next_id = 1, feeds = {} }, validIndex)
    end
    return self._feedIndex
end

function M:saveFeedIndex()
    return self:save("feeds/index.json", self:feedIndex())
end

function M:feedData(id)
    local data = self:load("feeds/" .. id .. ".json", nil, validFeedData) or {}
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
