local T = require("tests.t")
local fakepc = require("tests.fakepc")
local http = require("src.http")

local BASE = { host = "p.test", port = 443, tls = true }

local function setup(responder)
    local F = fakepc.new()
    F.responder = responder
    return F, http.pool(F.pc.network, BASE)
end

local function ok200(body)
    return function() return 200, { ["content-type"] = "text/gemini" }, body or "hello" end
end

-- Every connection the fake made has dropped its three callbacks, except
-- `busy`, which an in-flight request is using. On the device, close() keeps
-- the callbacks (and the body parts they capture) referenced.
local function assertDetached(F, label, busy)
    T.ok(#F.made > 0, label .. ": a connection was made")
    for i, c in ipairs(F.made) do
        if c ~= busy then
            local where = label .. ": connection " .. i
            T.eq(c.cb.req, nil, where .. " request callback")
            T.eq(c.cb.done, nil, where .. " complete callback")
            T.eq(c.cb.closed, nil, where .. " closed callback")
        end
    end
end

return {
    delivers_status_body_and_headers = function()
        local F, pool = setup(ok200("hello"))
        local got
        local h = pool:get("/v1/ping", { Authorization = "Bearer t" }, function(...) got = table.pack(...) end)
        F.service()
        T.eq(got[1], true); T.eq(got[2], 200); T.eq(got[3], "hello"); T.eq(got[4]["content-type"], "text/gemini")
        T.eq(F.requests[1].path, "/v1/ping"); T.eq(F.requests[1].headers.Authorization, "Bearer t")
        T.eq(h.received(), 5)
    end,
    reuses_an_idle_connection = function()
        local F, pool = setup(ok200())
        pool:get("/a", {}, function() end); F.service()
        pool:get("/b", {}, function() end); F.service()
        T.eq(F.conns, 1)
    end,
    retries_once_when_a_reused_connection_fails_before_any_data = function()
        local calls = 0
        local F, pool = setup(function()
            calls = calls + 1
            if calls == 2 then return nil, "connection closed before the response headers" end
            return 200, {}, "body " .. calls
        end)
        pool:get("/a", {}, function() end); F.service()
        local got
        pool:get("/b", {}, function(...) got = table.pack(...) end)
        F.service(); F.service()
        T.eq(got[1], true); T.eq(got[3], "body 3")
        T.eq(F.conns, 2)
    end,
    reports_transport_failures = function()
        local F, pool = setup(function() return nil, "connect timeout (15000ms)" end)
        local got
        pool:get("/a", {}, function(...) got = table.pack(...) end)
        F.service()
        T.eq(got[1], false); T.eq(got[3], "connect timeout (15000ms)")
        T.eq(pool.active, 0)
    end,
    refuses_bodies_over_512_kb = function()
        local F, pool = setup(ok200(string.rep("x", 600 * 1024)))
        local got
        pool:get("/a", {}, function(...) got = table.pack(...) end)
        F.service()
        T.eq(got[1], false); T.eq(got[3], "Page too large (over 512 KB)")
        T.eq(pool.active, 0); T.eq(#pool.idle, 0)
    end,
    cancelled_requests_never_call_back = function()
        local F, pool = setup(ok200())
        local called = false
        local h = pool:get("/a", {}, function() called = true end)
        h.cancel()
        F.service()
        T.eq(called, false); T.eq(pool.active, 0)
    end,
    allows_two_requests_at_a_time = function()
        local _, pool = setup(ok200())
        T.ok(pool:get("/a", {}, function() end))
        T.ok(pool:get("/b", {}, function() end))
        local h, err = pool:get("/c", {}, function() end)
        T.eq(h, nil); T.eq(err, "busy")
    end,
    reports_when_no_connection_can_be_made = function()
        local F, pool = setup(ok200())
        F.poolFull = true
        local got
        local h = pool:get("/a", {}, function(...) got = table.pack(...) end)
        T.ok(h, "a handle is still returned")
        T.eq(got[1], false); T.eq(got[3], "HTTP connection pool full or out of memory")
        T.eq(pool.active, 0)
    end,
    retry_skips_every_dead_idle_connection = function()
        local F, pool = setup(ok200())
        pool:get("/a", {}, function() end); pool:get("/b", {}, function() end)
        F.service()
        T.eq(#pool.idle, 2)
        for _, c in ipairs(pool.idle) do c:close() end
        local got
        pool:get("/c", {}, function(...) got = table.pack(...) end)
        F.service()
        T.eq(got[1], true); T.eq(got[3], "hello")
        T.eq(F.conns, 3)
    end,
    handle_is_complete_after_a_synchronous_failure = function()
        local F, pool = setup(ok200())
        F.poolFull = true
        local n, ok = 0, nil
        local h = pool:get("/a", {}, function(o) n = n + 1; ok = o end)
        h.cancel()
        T.eq(h.received(), 0); T.eq(n, 1); T.eq(ok, false); T.eq(pool.active, 0)
    end,
    close_all_fails_active_requests_once = function()
        local F, pool = setup(ok200())
        F.holding = true
        local calls = {}
        pool:get("/a", {}, function(...) calls[#calls + 1] = table.pack(...) end)
        local cancelled = false
        local h = pool:get("/b", {}, function() cancelled = true end)
        h.cancel()
        pool:closeAll()
        T.eq(#calls, 1)
        T.eq(calls[1][1], false); T.eq(calls[1][2], nil); T.eq(calls[1][3], "Connection closed")
        T.eq(pool.active, 0)
        F.holding = false; F.service()
        T.eq(#calls, 1); T.eq(cancelled, false); T.eq(#pool.idle, 0)
    end,
    cancel_mid_response_neither_calls_back_nor_goes_idle = function()
        local h
        local F, pool = setup(function() h.cancel(); return 200, {}, "body" end)
        local called = false
        h = pool:get("/a", {}, function() called = true end)
        F.service()
        T.eq(called, false); T.eq(#pool.idle, 0); T.eq(pool.active, 0)
    end,
    connection_close_responses_are_not_reused = function()
        local F, pool = setup(function() return 200, { connection = "Close" }, "x" end)
        pool:get("/a", {}, function() end); F.service()
        T.eq(#pool.idle, 0)
        pool:get("/b", {}, function() end); F.service()
        T.eq(F.conns, 2)
    end,
    a_parked_connection_keeps_no_callbacks = function()
        local F, pool = setup(ok200())
        pool:get("/a", {}, function() end); F.service()
        T.eq(#pool.idle, 1)
        assertDetached(F, "parked")
        F.holding = true
        pool:get("/b", {}, function() end)
        local busy = F.made[1]
        T.ok(busy.cb.req and busy.cb.done and busy.cb.closed, "the in-flight request has its callbacks")
        assertDetached(F, "in flight", busy)
        F.holding = false; F.service()
        assertDetached(F, "parked again")
    end,
    cancel_drops_the_callbacks = function()
        local F, pool = setup(ok200())
        F.holding = true
        pool:get("/a", {}, function() end).cancel()
        assertDetached(F, "cancel")
    end,
    an_oversized_body_drops_the_callbacks = function()
        local F, pool = setup(ok200(string.rep("x", 600 * 1024)))
        pool:get("/a", {}, function() end); F.service()
        assertDetached(F, "overflow")
    end,
    close_all_drops_the_callbacks = function()
        local F, pool = setup(ok200())
        pool:get("/a", {}, function() end); F.service()
        F.holding = true
        pool:get("/b", {}, function() end); pool:get("/c", {}, function() end)
        pool:closeAll()
        T.eq(#F.made, 2)
        assertDetached(F, "closeAll")
    end,
    a_retry_after_get_raises_drops_the_callbacks = function()
        local F, pool = setup(ok200())
        pool:get("/a", {}, function() end); F.service()
        pool.idle[1]:close()
        local got
        pool:get("/b", {}, function(...) got = table.pack(...) end); F.service()
        T.eq(got[1], true); T.eq(F.conns, 2)
        assertDetached(F, "retry after get raised")
    end,
    a_retry_from_the_closed_callback_drops_the_callbacks = function()
        local calls = 0
        local F, pool = setup(function()
            calls = calls + 1
            if calls == 2 then return nil, "connection closed before the response headers" end
            return 200, {}, "body " .. calls
        end)
        pool:get("/a", {}, function() end); F.service()
        local got
        pool:get("/b", {}, function(...) got = table.pack(...) end)
        F.service()
        T.eq(got, nil, "the retry is in flight")
        T.eq(F.conns, 2)
        assertDetached(F, "retry in flight", F.made[2])
        F.service()
        T.eq(got[1], true); T.eq(got[3], "body 3")
        assertDetached(F, "retry from the closed callback")
    end,
    a_connection_close_response_drops_the_callbacks = function()
        local F, pool = setup(function() return 200, { connection = "close" }, "x" end)
        pool:get("/a", {}, function() end); F.service()
        assertDetached(F, "connection: close")
    end,
    a_transport_failure_drops_the_callbacks = function()
        local F, pool = setup(function() return nil, "connect timeout (15000ms)" end)
        pool:get("/a", {}, function() end); F.service()
        assertDetached(F, "transport failure")
    end,
    a_body_too_big_for_memory_fails_once = function()
        local F, pool = setup(ok200("hello"))
        local calls = {}
        pool:get("/a", {}, function(...) calls[#calls + 1] = table.pack(...) end)
        local concat = table.concat
        table.concat = function() error("not enough memory") end
        local ok, err = pcall(F.service)
        table.concat = concat
        T.ok(ok, tostring(err))
        T.eq(#calls, 1)
        T.eq(calls[1][1], false); T.eq(calls[1][2], nil); T.eq(calls[1][3], "Page too large for memory")
        T.eq(pool.active, 0)
        assertDetached(F, "out of memory")
    end,
}
