local T = require("tests.t")
local url = require("src.url")

-- Seconds fn(n) takes (tests only: the device's Lua has no os).
local function timed(fn, n)
    local started = os.clock()
    fn(n)
    return os.clock() - started
end

local BASE = "http://a/b/c/d;p?q"
-- RFC 3986 5.4.1 and 5.4.2 (strict).
local CASES = {
    { "g:h", "g:h" }, { "g", "http://a/b/c/g" }, { "./g", "http://a/b/c/g" }, { "g/", "http://a/b/c/g/" },
    { "/g", "http://a/g" }, { "//g", "http://g" }, { "?y", "http://a/b/c/d;p?y" }, { "g?y", "http://a/b/c/g?y" },
    { "#s", "http://a/b/c/d;p?q#s" }, { "g#s", "http://a/b/c/g#s" }, { "g?y#s", "http://a/b/c/g?y#s" },
    { ";x", "http://a/b/c/;x" }, { "g;x", "http://a/b/c/g;x" }, { "g;x?y#s", "http://a/b/c/g;x?y#s" },
    { "", "http://a/b/c/d;p?q" }, { ".", "http://a/b/c/" }, { "./", "http://a/b/c/" }, { "..", "http://a/b/" },
    { "../", "http://a/b/" }, { "../g", "http://a/b/g" }, { "../..", "http://a/" }, { "../../", "http://a/" },
    { "../../g", "http://a/g" },
    { "../../../g", "http://a/g" }, { "../../../../g", "http://a/g" }, { "/./g", "http://a/g" },
    { "/../g", "http://a/g" }, { "g.", "http://a/b/c/g." }, { ".g", "http://a/b/c/.g" }, { "g..", "http://a/b/c/g.." },
    { "..g", "http://a/b/c/..g" }, { "./../g", "http://a/b/g" }, { "./g/.", "http://a/b/c/g/" },
    { "g/./h", "http://a/b/c/g/h" }, { "g/../h", "http://a/b/c/h" }, { "g;x=1/./y", "http://a/b/c/g;x=1/y" },
    { "g;x=1/../y", "http://a/b/c/y" }, { "g?y/./x", "http://a/b/c/g?y/./x" }, { "g?y/../x", "http://a/b/c/g?y/../x" },
    { "g#s/./x", "http://a/b/c/g#s/./x" }, { "g#s/../x", "http://a/b/c/g#s/../x" }, { "http:g", "http:g" },
}

return {
    resolve_follows_rfc_3986_examples = function()
        for _, c in ipairs(CASES) do T.eq(url.resolve(BASE, c[1]), c[2], c[1]) end
    end,
    resolve_against_gemini_bases = function()
        T.eq(url.resolve("gemini://g.test", "a.gmi"), "gemini://g.test/a.gmi")
        T.eq(url.resolve("gemini://g.test/log/", "2024/post.gmi"), "gemini://g.test/log/2024/post.gmi")
        T.eq(url.resolve("gemini://g.test/a/b.gmi", "/c"), "gemini://g.test/c")
        T.eq(url.resolve("gemini://g.test/a/", "gopher://h.test/1/x"), "gopher://h.test/1/x")
        T.eq(url.resolve("not a url", "x"), nil)
    end,
    parts_split_host_and_port = function()
        local p = url.parts("gemini://User@G.Test:1966/a/b?q=1#f")
        T.eq(p.scheme, "gemini"); T.eq(p.host, "g.test"); T.eq(p.port, 1966); T.eq(math.type(p.port), "integer")
        T.eq(p.path, "/a/b"); T.eq(p.query, "q=1"); T.eq(p.fragment, "f")
        p = url.parts("gemini://g.test")
        T.eq(p.host, "g.test"); T.eq(p.port, nil); T.eq(p.path, ""); T.eq(p.query, nil)
        T.eq(url.parts("g.test/a"), nil)
    end,
    with_input_sets_the_query_or_search = function()
        T.eq(url.withInput("gemini://g.test/search", "two words"), "gemini://g.test/search?two%20words")
        T.eq(url.withInput("gemini://g.test/s?old#x", "new"), "gemini://g.test/s?new")
        T.eq(url.withInput("gopher://h.test/7/v2/vs", "cats"), "gopher://h.test/7/v2/vs%09cats")
        T.eq(url.withInput("gopher://h.test/7/v2/vs%09dogs", "cats"), "gopher://h.test/7/v2/vs%09cats")
    end,
    long_paths_resolve_in_linear_time = function()
        local path = string.rep("/a", 100000)
        T.eq(url.resolve("gemini://g.test/", path), "gemini://g.test" .. path)
        T.eq(url.resolve("gemini://g.test/", string.rep("/a/..", 50000)), "gemini://g.test/")
        local function resolve(n) return url.resolve("gemini://g.test/", string.rep("/a", n)) end
        resolve(12500) -- warm up
        local small, big = timed(resolve, 12500), timed(resolve, 100000)
        T.ok(big < small * 16, string.format("8x the path took %.1fx the time (linear: about 8x)", big / small))
    end,
}
