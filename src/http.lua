-- HTTP transport to the proxy (spec 6.1): keep-alive connections, body
-- draining, a 512 KB cap and cancellation. The firmware runs the callbacks
-- inside its service pass, between any two Lua statements, so callers must
-- only record results in `done`.
local M = {}
M.MAX_BODY = 512 * 1024
M.MAX_ACTIVE = 2
M.CONNECT_TIMEOUT, M.READ_TIMEOUT = 15, 20
local READ_CHUNK = 16384

local Pool = {}
Pool.__index = Pool

-- net: picocalc.network; base: {host, port, tls} from url.parseBase.
function M.pool(net, base)
    return setmetatable({ net = net, base = base, idle = {}, active = 0, reqs = {} }, Pool)
end

local function connect(self)
    local conn, err = self.net.http.new(self.base.host, self.base.port, self.base.tls)
    if not conn then return nil, err end
    conn:setKeepAlive(true)
    conn:setConnectTimeout(M.CONNECT_TIMEOUT)
    conn:setReadTimeout(M.READ_TIMEOUT)
    if not conn:setReadBufferSize(65536) then conn:setReadBufferSize(32768) end
    return conn
end

-- Ends a request: marks it finished first (so late firmware callbacks do
-- nothing), frees its slot, and returns or closes its connection.
function Pool:finish(state, keep)
    if state.finished then return end
    state.finished = true
    self.active = self.active - 1
    self.reqs[state] = nil
    local conn = state.conn
    if conn then
        if keep then self.idle[#self.idle + 1] = conn else conn:close() end
    end
end

function Pool:dropIdle()
    for _, c in ipairs(self.idle) do c:close() end
    self.idle = {}
end

-- GET path. done(ok, status, bodyOrError, headers) runs exactly once unless
-- the request is cancelled. Returns a handle {cancel(), received()}, or nil and
-- "busy" when MAX_ACTIVE requests are running.
function Pool:get(path, headers, done)
    if self.active >= M.MAX_ACTIVE then return nil, "busy" end
    self.active = self.active + 1
    local state = { finished = false, total = 0, done = done }
    self.reqs[state] = true
    local handle = {
        cancel = function() self:finish(state, false) end,
        received = function() return state.total end,
    }
    self:send(path, headers, state, true, false)
    return handle
end

function Pool:send(path, headers, state, mayRetry, fresh)
    local pool = self
    if fresh then pool:dropIdle() end
    local conn = table.remove(self.idle)
    local reused = conn ~= nil
    if not conn then
        local err
        conn, err = connect(self)
        if not conn then
            pool:finish(state, false)
            state.done(false, nil, err or "No connection available")
            return
        end
    end
    state.conn = conn
    local parts, n = {}, 0

    local function drain()
        while not state.finished and conn:getBytesAvailable() > 0 do
            local d = conn:read(READ_CHUNK)
            if not d then break end
            state.total = state.total + #d
            if state.total > M.MAX_BODY then
                pool:finish(state, false)
                state.done(false, nil, "Page too large (over 512 KB)")
                return
            end
            n = n + 1
            parts[n] = d
        end
    end

    -- A reused connection that failed before any data: retry once on a fresh
    -- connection, discarding every idle one (they are likely all dead).
    local function retry()
        conn:close()
        return pool:send(path, headers, state, false, true)
    end

    conn:setRequestCallback(drain)
    conn:setRequestCompleteCallback(function()
        if state.finished then return end
        drain()
        if state.finished then return end
        local status, hdrs = conn:getResponseStatus(), conn:getResponseHeaders() or {}
        local c = hdrs["connection"]
        pool:finish(state, not (c and c:lower():find("close", 1, true)))
        state.done(true, status, table.concat(parts), hdrs)
    end)
    conn:setConnectionClosedCallback(function()
        if state.finished then return end
        if reused and mayRetry and state.total == 0 then return retry() end
        local err = conn:getError() or "Connection closed"
        state.conn = nil -- the firmware already released it
        pool:finish(state, false)
        state.done(false, nil, err)
    end)

    local ok, sent, err = pcall(conn.get, conn, path, headers)
    if ok and sent then return end
    if not ok and reused and mayRetry then
        -- get() raises on a connection the firmware already released.
        return retry()
    end
    pool:finish(state, false)
    state.done(false, nil, (ok and err) or "Request failed")
end

function Pool:closeAll()
    self:dropIdle()
    local list = {}
    for st in pairs(self.reqs) do list[#list + 1] = st end
    for _, st in ipairs(list) do
        self:finish(st, false)
        st.done(false, nil, "Connection closed")
    end
    self.active = 0
end

return M
