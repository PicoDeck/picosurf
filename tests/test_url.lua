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
    normalize_adds_https_and_trims = function()
        T.eq(url.normalize("example.com/a"), "https://example.com/a")
        T.eq(url.normalize("  http://x.org/a  "), "http://x.org/a")
    end,
    normalize_refuses_spaces_and_empty_text = function()
        local u, err = url.normalize("two words")
        T.eq(u, nil)
        T.eq(err, "Not a URL (search isn't supported yet)")
        T.eq(url.normalize("   "), nil)
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
