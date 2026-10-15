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
    return setmetatable({ net = net, base = base, idle = {}, active = 0 }, Pool)
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

-- GET path. done(ok, status, bodyOrError, headers) runs exactly once unless
-- the request is cancelled. Returns a handle {cancel(), received()}, or nil and
-- "busy" when MAX_ACTIVE requests are running.
function Pool:get(path, headers, done)
    if self.active >= M.MAX_ACTIVE then return nil, "busy" end
    self.active = self.active + 1
    local handle = {}
    local state = { finished = false, total = 0 }
    self:send(path, headers, done, handle, state, true)
    return handle
end

function Pool:send(path, headers, done, handle, state, mayRetry)
    local pool = self
    local conn = table.remove(self.idle)
    local reused = conn ~= nil
    if not conn then
        local err
        conn, err = connect(self)
        if not conn then
            state.finished = true
            pool.active = pool.active - 1
            done(false, nil, err or "No connection available")
            return
        end
    end
    local parts, n = {}, 0

    local function finish(keep)
        state.finished = true
        pool.active = pool.active - 1
        if keep then pool.idle[#pool.idle + 1] = conn else conn:close() end
    end

    local function drain()
        while not state.finished and conn:getBytesAvailable() > 0 do
            local d = conn:read(READ_CHUNK)
            if not d then break end
            state.total = state.total + #d
            if state.total > M.MAX_BODY then
                finish(false)
                done(false, nil, "Page too large (over 512 KB)")
                return
            end
            n = n + 1
            parts[n] = d
        end
    end

    conn:setRequestCallback(drain)
    conn:setRequestCompleteCallback(function()
        if state.finished then return end
        drain()
        if state.finished then return end
        local status, hdrs = conn:getResponseStatus(), conn:getResponseHeaders()
        finish(true)
        done(true, status, table.concat(parts), hdrs or {})
    end)
    conn:setConnectionClosedCallback(function()
        if state.finished then return end
        -- The firmware has released the connection. A kept-alive connection the
        -- server closed while idle fails before any data: try once more, fresh.
        if reused and mayRetry and state.total == 0 then
            return pool:send(path, headers, done, handle, state, false)
        end
        state.finished = true
        pool.active = pool.active - 1
        done(false, nil, conn:getError() or "Connection closed")
    end)

    handle.cancel = function()
        if not state.finished then finish(false) end
    end
    handle.received = function() return state.total end

    local ok, sent, err = pcall(conn.get, conn, path, headers)
    if ok and sent then return end
    if not ok and reused and mayRetry then
        -- get() raises on a connection the firmware already released.
        return pool:send(path, headers, done, handle, state, false)
    end
    finish(false)
    done(false, nil, (ok and err) or "Request failed")
end

function Pool:closeAll()
    for _, c in ipairs(self.idle) do c:close() end
    self.idle = {}
end

return M
