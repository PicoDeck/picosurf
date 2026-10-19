-- Pinned server certificates for Gemini, trust on first use (small web spec
-- 6), kept in known_hosts.json through store.lua: "host:port" ->
-- {fp, first, seen}. Times are clock epochs (0 before time sync).
local M = {}
M.__index = M
M.FILE, M.MAX, M.SEEN_SAVE_MS = "known_hosts.json", 500, 60000

local function valid(v)
    for k, e in pairs(v) do
        if type(k) ~= "string" or type(e) ~= "table" or type(e.fp) ~= "string" then return false end
    end
    return true
end

-- store: a store.lua store.
function M.new(store)
    return setmetatable({ store = store, dirty = false, seenDirty = false }, M)
end

function M:hosts()
    if not self._hosts then self._hosts = self.store:load(M.FILE, {}, valid) end
    return self._hosts
end

local function key(host, port) return host .. ":" .. port end

-- Drops the least recently seen hosts past MAX.
function M:trim()
    local hosts, n = self:hosts(), 0
    for _ in pairs(hosts) do n = n + 1 end
    while n > M.MAX do
        local oldK, oldSeen
        for k, e in pairs(hosts) do
            local seen = tonumber(e.seen) or 0
            if not oldK or seen < oldSeen or (seen == oldSeen and k < oldK) then oldK, oldSeen = k, seen end
        end
        hosts[oldK] = nil
        n = n - 1
    end
end

-- The verdict for certificate fingerprint fp (hex, or nil when the firmware
-- can't tell): "unpinned", "new" (now pinned), "ok", or "changed" plus the
-- pinned entry. Changes only memory; flush saves.
function M:check(host, port, fp, now)
    if fp == nil then return "unpinned" end
    local hosts, k = self:hosts(), key(host, port)
    local e = hosts[k]
    if not e then
        hosts[k] = { fp = fp, first = now, seen = now }
        self:trim()
        self.dirty = true
        return "new"
    end
    if e.fp == fp then
        e.seen = now
        self.seenDirty = true
        return "ok"
    end
    return "changed", e
end

-- Trusts fp for host:port from now on.
function M:accept(host, port, fp, now)
    self:hosts()[key(host, port)] = { fp = fp, first = now, seen = now }
    self:trim()
    self.dirty = true
end

-- Saves a new pin or acceptance at once, a changed `seen` at most once a
-- minute; ms is sys.getTimeMs().
function M:flush(ms)
    if not self.dirty and not (self.seenDirty and (not self.savedAt or ms - self.savedAt >= M.SEEN_SAVE_MS)) then
        return
    end
    self.store:save(M.FILE, self:hosts())
    self.dirty, self.seenDirty, self.savedAt = false, false, ms
end

-- "YYYY-MM-DD" for a clock epoch, or nil for 0 (days from civil, H. Hinnant).
function M.date(epoch)
    if not epoch or epoch <= 0 then return nil end
    local z = epoch // 86400 + 719468
    local era = z // 146097
    local doe = z - era * 146097
    local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    local mp = (5 * doy + 2) // 153
    local d = doy - (153 * mp + 2) // 5 + 1
    local m = mp < 10 and mp + 3 or mp - 9
    local y = yoe + era * 400 + (m <= 2 and 1 or 0)
    return string.format("%04d-%02d-%02d", y, m, d)
end

return M
