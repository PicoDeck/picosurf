local T = require("tests.t")
local fakepc = require("tests.fakepc")
local fakes = require("tests.fakes")
local store = require("src.store")
local tofu = require("src.tofu")
local native = require("src.native")

-- A fake device, env and a get() that runs the main loop's posts.
local function setup()
    local F = fakepc.new()
    local posts, logs = {}, {}
    local pins = tofu.new(store.new(fakes.fs(), fakes.json(), "/data/x"))
    local env = {
        tcp = F.pc.tcp, pins = pins, now = function() return 1000 end,
        post = function(fn) posts[#posts + 1] = fn end,
        log = function(...) logs[#logs + 1] = table.concat({ ... }, " ") end,
    }
    -- The firmware's passes and the main loop, until both are quiet.
    local function pump()
        for _ = 1, 20 do
            F.service()
            local p = posts
            posts = {}
            for _, fn in ipairs(p) do fn() end
        end
    end
    local function get(target, as)
        local results = {}
        local h = native.get(env, target, as, function(r) results[#results + 1] = r end)
        pump()
        return results, h
    end
    return F, get, env, logs, pump
end

local function gemini(F, hostport, fp, routes)
    F.tcpServers[hostport] = { fp = fp, reply = function(req)
        local u = req:gsub("\r\n$", "")
        return routes[u] or "51 Not found\r\n"
    end }
end

return {
    prepare_by_scheme = function()
        local s = native.prepare("gemini://G.test/a")
        T.eq(s.tls, true); T.eq(s.port, 1965); T.eq(s.line, "gemini://g.test/a\r\n"); T.eq(s.url, "gemini://g.test/a")
        s = native.prepare("gopher://h.test/1/x")
        T.eq(s.tls, false); T.eq(s.port, 70); T.eq(s.line, "/x\r\n")
        T.eq(native.prepare("gopher://h.test/7/s").search, true)
        T.eq(select(2, native.prepare("spartan://s.test/")), "spartan:// links aren't supported yet")
    end,
    a_gemini_page = function()
        local F, get = setup()
        gemini(F, "g.test:1965", "aa", { ["gemini://g.test/"] = "20 text/gemini\r\n# Hi\n=> a.gmi A\n" })
        local results = get("gemini://g.test/")
        T.eq(#results, 1); T.eq(results[1].kind, "gemini"); T.eq(results[1].body, "# Hi\n=> gemini://g.test/a.gmi A\n")
    end,
    redirects_are_followed_up_to_five_hops = function()
        local F, get = setup()
        gemini(F, "g.test:1965", "aa", {
            ["gemini://g.test/a"] = "31 /b\r\n", ["gemini://g.test/b"] = "30 c\r\n",
            ["gemini://g.test/c"] = "20 text/gemini\r\nC\n", ["gemini://g.test/loop"] = "31 /loop\r\n",
        })
        local results = get("gemini://g.test/a")
        T.eq(results[1].finalUrl, "gemini://g.test/c"); T.eq(#F.tcpMade, 3)
        results = get("gemini://g.test/loop")
        T.eq(results[1].message, "Too many redirects"); T.eq(#F.tcpMade, 3 + 6, "the first try and five hops")
    end,
    a_redirect_to_another_scheme_is_handed_back = function()
        local F, get = setup()
        gemini(F, "g.test:1965", "aa", { ["gemini://g.test/"] = "31 https://w.test/x\r\n" })
        local results = get("gemini://g.test/")
        T.eq(results[1].kind, "redirect"); T.eq(results[1].url, "https://w.test/x")
    end,
    pins_are_kept_and_changes_stop_the_request = function()
        local F, get, env = setup()
        gemini(F, "g.test:1965", "aa", { ["gemini://g.test/q?x"] = "20 text/gemini\r\nok\n" })
        T.eq(get("gemini://g.test/q?x")[1].kind, "gemini")
        T.eq(env.pins:hosts()["g.test:1965"].fp, "aa")
        F.tcpServers["g.test:1965"].fp = "bb"
        local r = get("gemini://g.test/q?x")[1]
        T.eq(r.kind, "certchanged"); T.eq(r.old, "aa"); T.eq(r.new, "bb"); T.eq(r.host, "g.test"); T.eq(r.port, 1965)
        T.eq(r.url, "gemini://g.test/q?x"); T.eq(r.firstSeen, 1000)
        T.eq(#F.tcpMade[2].writes, 0, "the query was never sent")
    end,
    old_firmware_loads_unpinned_and_logs_once = function()
        local F, get, env, logs = setup()
        F.tcpOldFirmware = true
        gemini(F, "g.test:1965", nil, { ["gemini://g.test/"] = "20 text/gemini\r\nok\n" })
        T.eq(get("gemini://g.test/")[1].kind, "gemini")
        get("gemini://g.test/")
        T.eq(next(env.pins:hosts()), nil)
        local n = 0
        for _, l in ipairs(logs) do if l == "pinning unavailable" then n = n + 1 end end
        T.eq(n, 1)
    end,
    gopher_menus_and_searches = function()
        local F, get = setup()
        F.tcpServers["h.test:70"] = { reply = function(req)
            if req == "/s\tcats\r\n" then return "1Cat\t/cat\th.test\t70\r\n.\r\n" end
            return "iHello\t\th\t1\r\n.\r\n"
        end }
        T.eq(get("gopher://h.test/")[1].body, "```\nHello\n```\n")
        local r = get("gopher://h.test/7/s")[1]
        T.eq(r.kind, "input"); T.eq(r.prompt, "Search:"); T.eq(#F.tcpMade, 1, "no request without terms")
        T.eq(get("gopher://h.test/7/s%09cats")[1].body, "=> gopher://h.test/1/cat Cat\n")
    end,
    transport_failures_read_plainly = function()
        local F, get, _, logs = setup()
        F.tcpServers["g.test:1965"] = { connectErr = "Mongoose error: TLS handshake failed" }
        T.eq(get("gemini://g.test/")[1].message,
            "Secure connection to g.test failed (it may need TLS 1.3 or an Ed25519 certificate)")
        T.ok(logs[#logs]:find("TLS handshake failed", 1, true), "the firmware's reason is logged")
        T.eq(get("gemini://nobody.test/")[1].message, "nobody.test did not respond")
        F.tcpServers["r.test:1965"] = { connectErr = "DNS: Name or service not known" }
        T.eq(get("gemini://r.test/")[1].message, "Could not connect to r.test")
        F.tcpServers["s.test:1965"] = { reply = function() return { err = "read timeout (20000ms)" } end }
        T.eq(get("gemini://s.test/")[1].message, "s.test stopped responding")
        F.tcpServers["l.test:1965"] = { reply = function() return { chunks = { "20 t" }, err = "Mongoose error: reset" } end }
        T.eq(get("gemini://l.test/")[1].message, "Connection to l.test was lost")
        F.tcpServers["e.test:1965"] = { reply = function() return "" end }
        T.eq(get("gemini://e.test/")[1].message, "Not a Gemini response")
        F.tcpServers["e.test:70"] = { reply = function() return "" end }
        T.eq(get("gopher://e.test/")[1].message, "Empty response from e.test")
    end,
    no_free_socket_is_busy = function()
        local F, get = setup()
        F.tcpFull = true
        T.eq(get("gemini://g.test/")[1].message, "Busy: try again")
    end,
    bad_urls_fail_without_a_socket = function()
        local F, get = setup()
        T.eq(get("gemini://g.test/" .. string.rep("a", 1100))[1].message, "URL too long for Gemini")
        T.eq(#F.tcpMade, 0)
    end,
    cancel_drops_the_result = function()
        local F, _, env, _, pump = setup()
        gemini(F, "g.test:1965", "aa", { ["gemini://g.test/"] = "20 text/gemini\r\nok\n" })
        local got = 0
        local h = native.get(env, "gemini://g.test/", nil, function() got = got + 1 end)
        h.cancel()
        pump()
        T.eq(got, 0); T.eq(F.tcpMade[1].state, "released")
        -- Cancelled after the reply arrived but before the main loop ran it.
        h = native.get(env, "gemini://g.test/", nil, function() got = got + 1 end)
        F.service()
        h.cancel()
        pump()
        T.eq(got, 0)
    end,
}
