local T = require("tests.t")
local proxy = require("src.proxy")

local BASE = { host = "p.test", port = 443, tls = true, prefix = "/ps" }

return {
    builds_paths_and_headers = function()
        T.eq(proxy.getPath(BASE, "https://a.test/x?y=1", "full"), "/ps/v1/get?url=https%3A%2F%2Fa.test%2Fx%3Fy%3D1&as=full")
        T.eq(proxy.getPath({ prefix = "" }, "https://a.test/", nil), "/v1/get?url=https%3A%2F%2Fa.test%2F")
        T.eq(proxy.pingPath(BASE), "/ps/v1/ping")
        T.eq(proxy.headers("tok").Authorization, "Bearer tok")
    end,
    reads_gemtext_with_headers = function()
        local r = proxy.interpret(true, 200, "# Hi\n", {
            ["content-type"] = "text/gemini; charset=us-ascii", ["x-final-url"] = "https://a.test/f",
            ["x-title"] = "Hi", ["x-mode"] = "reader", ["x-feed-url"] = "https://a.test/feed", ["x-truncated"] = "1",
        })
        T.eq(r.kind, "gemini"); T.eq(r.body, "# Hi\n"); T.eq(r.finalUrl, "https://a.test/f")
        T.eq(r.title, "Hi"); T.eq(r.mode, "reader"); T.eq(r.feedUrl, "https://a.test/feed"); T.eq(r.truncated, true)
    end,
    reads_text_and_images = function()
        T.eq(proxy.interpret(true, 200, "x", { ["content-type"] = "text/plain; charset=us-ascii" }).kind, "text")
        T.eq(proxy.interpret(true, 200, "x", { ["content-type"] = "image/jpeg" }).kind, "image")
        local r = proxy.interpret(true, 200, "x", { ["content-type"] = "application/pdf" })
        T.eq(r.kind, "error"); T.eq(r.message, "Unexpected response: application/pdf")
    end,
    turns_statuses_into_messages = function()
        T.eq(proxy.interpret(true, 401, "Missing or wrong token\n", {}).message, "Proxy rejected the token - check Settings")
        local r = proxy.interpret(true, 502, "Site returned 404 Not Found\n", { ["x-upstream-status"] = "404" })
        T.eq(r.kind, "error"); T.eq(r.status, 502); T.eq(r.message, "Site returned 404 Not Found")
        T.eq(proxy.interpret(true, 500, "", {}).message, "Proxy error 500")
    end,
    turns_transport_failures_into_messages = function()
        T.eq(proxy.interpret(false, nil, "clock not set: TLS needs the time from SNTP", nil).kind, "clock")
        T.eq(proxy.interpret(false, nil, "read timeout (20000ms)", nil).message, "Proxy did not respond")
        T.eq(proxy.interpret(false, nil, "connect timeout (15000ms)", nil).message, "Proxy did not respond")
        T.eq(proxy.interpret(false, nil, "Page too large (over 512 KB)", nil).message, "Page too large (over 512 KB)")
    end,
    interprets_ping = function()
        T.eq(proxy.interpretPing(true, 200, "picosurf-proxy 1\n", {}).ok, true)
        T.eq(proxy.interpretPing(true, 200, "<html>", {}).message, "That URL is not a PicoSurf proxy")
        T.eq(proxy.interpretPing(true, 401, "Missing or wrong token\n", {}).message, "Proxy rejected the token - check Settings")
        T.eq(proxy.interpretPing(false, nil, "connect timeout (15000ms)", nil).message, "Proxy did not respond")
    end,
}
