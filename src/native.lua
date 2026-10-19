-- Gemini and Gopher requests for App:request (small web spec 2.1, 4-7): one
-- tcpfetch per hop, Gemini redirects followed, certificates pinned, and
-- transport failures as the messages of spec 11.
local url = require("src.url")
local gemini = require("src.gemini")
local gopher = require("src.gopher")
local tcpfetch = require("src.tcpfetch")

local M = {}
M.MAX_HOPS = 5

local function fail(message)
    return { kind = "error", message = message }
end

-- What to send for target: {scheme, host, port, tls, line, url, req}; or
-- {search = true, url} for a Gopher search without its terms; or nil and a
-- reason.
function M.prepare(target)
    local scheme = url.scheme(target)
    if scheme == "gemini" then
        local req, err = gemini.request(target)
        if not req then return nil, err end
        return { scheme = scheme, host = req.host, port = req.port, tls = true, line = req.line, url = req.url, req = req }
    end
    if scheme == "gopher" then
        if gopher.needsSearch(target) then return { search = true, url = target } end
        local req, err = gopher.parse(target)
        if not req then return nil, err end
        return { scheme = scheme, host = req.host, port = req.port, tls = false, line = gopher.request(req),
            url = target, req = req }
    end
    return nil, (scheme or "That") .. ":// links aren't supported yet"
end

-- A transport failure (a tcpfetch result) as the message a reader sees.
function M.failure(host, res)
    local e = res.err or ""
    if res.tooLarge or e == "Page too large for memory" then return fail(e) end
    if not res.connected then
        if e:find("timeout", 1, true) then return fail(host .. " did not respond") end
        if e:find("TLS", 1, true) or e:find("SSL", 1, true) or e:find("handshake", 1, true) then
            return fail("Secure connection to " .. host .. " failed (it may need TLS 1.3 or an Ed25519 certificate)")
        end
        return fail("Could not connect to " .. host)
    end
    if e:find("timeout", 1, true) then return fail(host .. " stopped responding") end
    return fail("Connection to " .. host .. " was lost")
end

-- The pin check, run by tcpfetch after the handshake and before sending.
function M.check(env, spec, conn)
    local fp = conn.peerFingerprint and conn:peerFingerprint() or nil
    if fp == nil and not env.pins.unavailableLogged then
        env.pins.unavailableLogged = true
        env.log("pinning unavailable")
    end
    local verdict, old = env.pins:check(spec.host, spec.port, fp, env.now())
    if verdict ~= "changed" then return true end
    return false, { kind = "certchanged", host = spec.host, port = spec.port, old = old.fp, new = fp,
        firstSeen = old.first, url = spec.url }
end

-- Fetches target (gemini:// or gopher://). env: {tcp = picocalc.tcp, pins =
-- a tofu, now() -> clock epoch, post(fn) runs fn from the main loop, log(...)}.
-- done(result) runs from the main loop, once, unless cancelled. A redirect to
-- another scheme ends with {kind = "redirect", url} for the app to dispatch.
-- Returns a handle {cancel(), received()}.
function M.get(env, target, as, done)
    local h = { cancelled = false }
    local function finish(r)
        if not h.cancelled then done(r) end
    end
    local hop
    local function onReply(spec, res, n)
        if h.cancelled then return end
        h.cur = nil
        if res.stopped then return finish(res.stopped) end
        if not res.ok then
            env.log("error", "-", spec.host, res.err)
            return finish(M.failure(spec.host, res))
        end
        local proto = spec.scheme == "gemini" and gemini or gopher
        -- Reading a large reply can run out of memory: collect and try once
        -- more, then end with spec 11's message (as App:withMemoryRetry).
        local ok, r = pcall(proto.interpret, spec.req, res.body, as)
        if not ok then
            env.log("error", "-", spec.host, tostring(r))
            collectgarbage()
            ok, r = pcall(proto.interpret, spec.req, res.body, as)
            if not ok then
                env.log("error", "-", spec.host, tostring(r))
                return finish(fail("Page too large for memory"))
            end
        end
        if r.kind == "redirect" then
            if n >= M.MAX_HOPS then return finish(fail("Too many redirects")) end
            if url.scheme(r.url) == "gemini" then return hop(r.url, n + 1) end
        end
        finish(r)
    end
    hop = function(u, n)
        local spec, err = M.prepare(u)
        if not spec then return env.post(function() finish(fail(err)) end) end
        if spec.search then
            return env.post(function() finish({ kind = "input", prompt = "Search:", sensitive = false, url = u }) end)
        end
        local cur, ferr = tcpfetch.get(env.tcp, {
            host = spec.host, port = spec.port, tls = spec.tls, request = spec.line,
            check = spec.tls and function(conn) return M.check(env, spec, conn) end or nil,
        }, function(res) env.post(function() onReply(spec, res, n) end) end)
        if not cur then
            return env.post(function() finish(fail(ferr == "busy" and "Busy: try again" or ferr)) end)
        end
        h.cur = cur
    end
    hop(target, 0)
    return {
        cancel = function()
            h.cancelled = true
            if h.cur then h.cur.cancel() end
            h.cur = nil
        end,
        received = function() return h.cur and h.cur.received() or 0 end,
    }
end

return M
