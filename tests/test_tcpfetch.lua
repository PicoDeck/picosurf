local T = require("tests.t")
local fakepc = require("tests.fakepc")
local tcpfetch = require("src.tcpfetch")

-- Starts a fetch to g.test:1965 against `server`; returns the results list,
-- the handle and the fake.
local function fetch(server, spec)
    local F = fakepc.new()
    F.tcpServers["g.test:1965"] = server
    local results = {}
    spec = spec or {}
    spec.host, spec.port = "g.test", 1965
    spec.tls = spec.tls ~= false
    spec.request = spec.request or "gemini://g.test/\r\n"
    local h, err = tcpfetch.get(F.pc.tcp, spec, function(res) results[#results + 1] = res end)
    return results, h, F, err
end

return {
    a_reply_arrives_whole = function()
        local results, h, F = fetch({ fp = "aa", reply = function(req) return "20 ok\r\n" .. req end })
        T.eq(#results, 0, "nothing before the firmware's pass")
        F.service()
        T.eq(#results, 1); T.eq(results[1].ok, true); T.eq(results[1].body, "20 ok\r\ngemini://g.test/\r\n")
        local c = F.tcpMade[1]
        T.eq(c.tls, true); T.eq(c.insecure, true); T.eq(c.connectTimeout, 20); T.eq(c.readTimeout, 20)
        T.eq(c.state, "released", "closed after the reply"); T.eq(h.received(), 25)
    end,
    plain_sockets_skip_insecure = function()
        local _, _, F = fetch({ reply = function() return "x" end }, { tls = false })
        F.service()
        T.eq(F.tcpMade[1].tls, false); T.eq(F.tcpMade[1].insecure, nil)
    end,
    the_body_can_come_in_parts = function()
        local results, _, F = fetch({ reply = function() return { chunks = { "ab", "cd", "ef" } } end })
        F.service()
        T.eq(results[1].body, "abcdef")
    end,
    the_check_runs_before_anything_is_sent = function()
        local saw
        local results, _, F = fetch({ fp = "aa", reply = function() error("must not send") end }, {
            check = function(conn)
                saw = conn:peerFingerprint()
                return false, { kind = "certchanged" }
            end,
        })
        F.service()
        T.eq(saw, "aa"); T.eq(#F.tcpMade[1].writes, 0)
        T.eq(results[1].stopped.kind, "certchanged"); T.eq(F.tcpMade[1].state, "released")
    end,
    connect_failures_report_the_firmware_reason = function()
        local results, _, F = fetch({ connectErr = "Mongoose error: TLS handshake failed" })
        F.service()
        T.eq(results[1].ok, false); T.eq(results[1].connected, false)
        T.eq(results[1].err, "Mongoose error: TLS handshake failed")
        results, _, F = fetch(nil)
        F.service()
        T.eq(results[1].err, "connect timeout (20000ms)")
    end,
    errors_after_connecting = function()
        local results, _, F = fetch({ reply = function() return { chunks = { "20 x\r\n" }, err = "read timeout (20000ms)" } end })
        F.service()
        T.eq(results[1].ok, false); T.eq(results[1].connected, true); T.eq(results[1].err, "read timeout (20000ms)")
    end,
    bodies_over_512_kb_stop = function()
        local big = string.rep("x", 300 * 1024)
        local results, _, F = fetch({ reply = function() return { chunks = { big, big } } end })
        F.service()
        T.eq(#results, 1); T.eq(results[1].tooLarge, true); T.eq(results[1].err, "Page too large (over 512 KB)")
        T.eq(F.tcpMade[1].state, "released")
    end,
    cancel_closes_and_reports_nothing = function()
        local results, h, F = fetch({ reply = function() return "x" end })
        h.cancel()
        F.service()
        T.eq(#results, 0); T.eq(F.tcpMade[1].state, "released")
    end,
    no_free_socket = function()
        local F = fakepc.new()
        F.tcpFull = true
        local h, err = tcpfetch.get(F.pc.tcp, { host = "g.test", port = 1965, request = "" }, function() end)
        T.eq(h, nil); T.eq(err, "busy")
    end,
    no_wifi_refuses_at_once = function()
        local F = fakepc.new()
        F.netStatus = 0
        local h, err = tcpfetch.get(F.pc.tcp, { host = "g.test", port = 1965, request = "" }, function() end)
        T.eq(h, nil); T.eq(err, "WiFi not available"); T.eq(F.tcpMade[1].state, "released")
    end,
    a_server_that_never_closes_waits = function() -- the firmware's read timeout ends it
        local results, _, F = fetch({ reply = function() return { chunks = { "20 x\r\n" }, hang = true } end })
        F.service()
        T.eq(#results, 0)
    end,
}
