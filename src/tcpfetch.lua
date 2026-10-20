-- One request over picocalc.tcp (small web spec 3): connect, an optional
-- check before anything is sent, the request, then everything the server
-- sends until it closes. The firmware runs the callbacks inside its service
-- pass, so `done` must only record.
local M = {}
M.MAX_BODY, M.CONNECT_TIMEOUT, M.READ_TIMEOUT = 512 * 1024, 20, 20
local READ_CHUNK = 16384

-- tcp: picocalc.tcp. spec: {host, port, tls, request, check}; check(conn),
-- when given, runs once connected and returns true, or false and a value
-- that ends the request unsent. done(res) runs once unless cancelled:
--   {ok = true, body = s}
--   {ok = false, err = s, connected = bool, tooLarge = bool}
--   {stopped = value}
-- Returns a handle {cancel(), received()}, or nil and a reason (no free
-- socket: "busy"; or the firmware's refusal to connect).
function M.get(tcp, spec, done)
    local conn = tcp.new(spec.host, spec.port, spec.tls)
    if not conn then return nil, "busy" end
    local st = { parts = {}, n = 0, total = 0, finished = false, connected = false }

    local function finish(res)
        if st.finished then return end
        st.finished = true
        st.parts = nil
        conn:setConnectCallback(nil)
        conn:setReadCallback(nil)
        conn:setCloseCallback(nil)
        conn:close()
        if res then done(res) end
    end

    local function drain()
        while not st.finished do
            local d = conn:read(READ_CHUNK)
            if not d or d == "" then return end
            st.total = st.total + #d
            if st.total > M.MAX_BODY then
                return finish({ ok = false, err = "Page too large (over 512 KB)", connected = true, tooLarge = true })
            end
            st.n = st.n + 1
            st.parts[st.n] = d
        end
    end

    if spec.tls then conn:setInsecure(true) end
    conn:setConnectTimeout(M.CONNECT_TIMEOUT)
    conn:setReadTimeout(M.READ_TIMEOUT)
    conn:setConnectCallback(function()
        if st.finished then return end
        st.connected = true
        if spec.check then
            -- A check that raises must not escape into the firmware's
            -- callback: finish() would never run, leaking the socket and
            -- hanging the request.
            local pok, ok, stop = pcall(spec.check, conn)
            if not pok then
                return finish({ ok = false, err = "check failed: " .. tostring(ok), connected = true })
            end
            if not ok then return finish({ stopped = stop }) end
        end
        if conn:write(spec.request) < 0 then
            finish({ ok = false, err = conn:error() or "write failed", connected = true })
        end
    end)
    conn:setReadCallback(drain)
    conn:setCloseCallback(function()
        if st.finished then return end
        drain()
        if st.finished then return end
        local err = conn:error()
        if err then return finish({ ok = false, err = err, connected = st.connected }) end
        local ok, body = pcall(table.concat, st.parts)
        if not ok then return finish({ ok = false, err = "Page too large for memory", connected = true }) end
        finish({ ok = true, body = body })
    end)
    local started, err = conn:connect()
    if not started then
        finish(nil)
        return nil, err or "Could not connect"
    end
    return {
        cancel = function() finish(nil) end,
        received = function() return st.total end,
    }
end

return M
