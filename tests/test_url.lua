local T = require("tests.t")
local url = require("src.url")

return {
    encode_keeps_unreserved_and_escapes_the_rest = function()
        T.eq(url.encode("https://a.b/c?d=e f&g~_-"), "https%3A%2F%2Fa.b%2Fc%3Fd%3De%20f%26g~_-")
    end,
    scheme_is_lower_case_or_nil = function()
        T.eq(url.scheme("HTTPS://x.org/"), "https")
        T.eq(url.scheme("gemini://g.test/"), "gemini")
        T.eq(url.scheme("example.com"), nil)
    end,
    host_strips_scheme_port_and_path = function()
        T.eq(url.host("https://example.com:8080/a?b"), "example.com")
        T.eq(url.host("not a url"), "not a url")
    end,
    normalize_keeps_urls_and_trims = function()
        T.eq(url.normalize("  http://x.org/a  "), "http://x.org/a")
        T.eq(url.normalize("gemini://g.test/a b"), "gemini://g.test/a b")
        T.eq(select(2, url.normalize("   ")), "Type a URL")
    end,
    normalize_hosts_take_https_with_a_proxy_else_gemini = function()
        T.eq(url.normalize("example.com/a", { proxy = true }), "https://example.com/a")
        T.eq(url.normalize("example.com/a"), "gemini://example.com/a")
    end,
    normalize_searches_everything_else = function()
        local s = { search = "gemini://tlgs.one/search" }
        T.eq(url.normalize("two words", s), "gemini://tlgs.one/search?two%20words")
        T.eq(url.normalize("localhost", s), "gemini://tlgs.one/search?localhost")
        T.eq(url.normalize("cats", { search = "https://html.duckduckgo.com/html/?q=%s" }),
            "https://html.duckduckgo.com/html/?q=cats")
        T.eq(url.normalize("100% cats", { search = "https://s.test/?q=%s" }), "https://s.test/?q=100%25%20cats")
        T.eq(url.normalize("cats", { search = "gopher://gopher.floodgap.com/7/v2/vs" }),
            "gopher://gopher.floodgap.com/7/v2/vs%09cats")
        local u, err = url.normalize("two words", { search = "" })
        T.eq(u, nil); T.eq(err, "Not a URL")
    end,
    parse_base_variants = function() -- Review Focus 5
        local b = url.parseBase("https://p.example.com")
        T.eq(b.host, "p.example.com"); T.eq(b.port, 443); T.eq(b.tls, true); T.eq(b.prefix, "")
        b = url.parseBase("https://p.example.com/")
        T.eq(b.prefix, "")
        b = url.parseBase("http://192.168.1.5:8080/picosurf/")
        T.eq(b.host, "192.168.1.5"); T.eq(b.port, 8080); T.eq(b.tls, false); T.eq(b.prefix, "/picosurf")
        b = url.parseBase("HTTPS://P.example.com/x")
        T.eq(b.tls, true); T.eq(b.host, "P.example.com"); T.eq(b.prefix, "/x")
        T.eq(math.type(url.parseBase("http://h:81").port), "integer")
    end,
    parse_base_refuses_bad_input = function()
        local b, err = url.parseBase("ftp://x.org")
        T.eq(b, nil); T.eq(err, "Proxy URL must start with https:// or http://")
        b, err = url.parseBase("https://")
        T.eq(err, "Proxy URL has no host")
        b, err = url.parseBase("https://h:99999")
        T.eq(err, "Proxy URL has a bad port")
    end,
    parse_base_refuses_an_empty_or_non_numeric_port = function() -- T1
        local b, err = url.parseBase("https://host:")
        T.eq(b, nil); T.eq(err, "Proxy URL has a bad port")
        b, err = url.parseBase("https://host:abc/x")
        T.eq(b, nil); T.eq(err, "Proxy URL has a bad port")
        b, err = url.parseBase("http://host:/")
        T.eq(b, nil); T.eq(err, "Proxy URL has a bad port")
    end,
}
