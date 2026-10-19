local T = require("tests.t")
local gemini = require("src.gemini")

local REQ = assert(gemini.request("gemini://g.test/dir/page.gmi"))

local function interpret(data, as) return gemini.interpret(REQ, data, as) end

return {
    request_normalises_the_url = function()
        local r = gemini.request("gemini://G.Test")
        T.eq(r.host, "g.test"); T.eq(r.port, 1965); T.eq(r.url, "gemini://g.test/"); T.eq(r.line, "gemini://g.test/\r\n")
        r = gemini.request("gemini://g.test:1965/a?b#frag")
        T.eq(r.url, "gemini://g.test/a?b")
        r = gemini.request("gemini://g.test:7000/")
        T.eq(r.port, 7000); T.eq(r.url, "gemini://g.test:7000/")
    end,
    request_refuses_bad_urls = function()
        local r, err = gemini.request("gemini://g.test/" .. string.rep("a", 1010))
        T.eq(r, nil); T.eq(err, "URL too long for Gemini")
        T.eq(select(2, gemini.request("https://g.test/")), "Not a Gemini URL")
        T.eq(select(2, gemini.request("gemini:///x")), "Not a Gemini URL")
        T.eq(select(2, gemini.request("gemini://g.test:70000/")), "Not a Gemini URL")
    end,
    header_parsing = function()
        local s, meta, body = gemini.header("20 text/gemini\r\n# Hi\n")
        T.eq(s, 20); T.eq(meta, "text/gemini"); T.eq(body, "# Hi\n")
        s, meta = gemini.header("20 text/plain\nbody")
        T.eq(s, 20); T.eq(meta, "text/plain")
        s, meta, body = gemini.header("20\r\n")
        T.eq(s, 20); T.eq(meta, ""); T.eq(body, "")
        T.eq(gemini.header("20 text/gemini"), nil, "no terminator")
        T.eq(gemini.header("200 OK\r\n"), nil)
        T.eq(gemini.header("HTTP/1.1 200 OK\r\n"), nil)
        T.eq(gemini.header("20 " .. string.rep("x", 1030) .. "\r\n"), nil, "meta over 1024 bytes")
    end,
    success_rewrites_links_and_folds = function()
        local r = interpret("20 text/gemini; charset=utf-8\r\n# Caf\u{00E9}\n=> other.gmi Other \u{2192}\n=> /root\n"
            .. "```\n=> not/a/link\n```\n")
        T.eq(r.kind, "gemini"); T.eq(r.mode, "native"); T.eq(r.finalUrl, "gemini://g.test/dir/page.gmi")
        T.eq(r.body, "# Cafe\n=> gemini://g.test/dir/other.gmi Other ->\n=> gemini://g.test/root gemini://g.test/root\n"
            .. "```\n=> not/a/link\n```\n")
        T.eq(r.title, nil, "the page view takes the title from the first heading")
    end,
    non_ascii_link_urls_are_encoded = function()
        local r = interpret("20 text/gemini\r\n=> caf\u{00E9}.gmi Caf\u{00E9}\n")
        T.eq(r.body, "=> gemini://g.test/dir/caf%C3%A9.gmi Cafe\n")
    end,
    an_empty_meta_means_gemtext = function()
        T.eq(interpret("20\r\n# Hi\n").body, "# Hi\n")
    end,
    latin1_charset = function()
        T.eq(interpret("20 text/gemini; charset=ISO-8859-1\r\ncaf\233\n").body, "cafe\n")
    end,
    other_text_is_reflowed = function()
        local r = interpret("20 text/plain\r\nOne short line\n")
        T.eq(r.kind, "gemini"); T.eq(r.body, "One short line\n"); T.eq(r.title, "g.test")
    end,
    images_and_other_types = function()
        local r = interpret("20 image/png\r\n\137PNG")
        T.eq(r.kind, "image"); T.eq(r.native, true); T.eq(r.body, "\137PNG")
        r = interpret("20 application/pdf\r\n%PDF")
        T.eq(r.kind, "error"); T.eq(r.message, "Can't show application/pdf files")
        T.eq(interpret("20 image/webp\r\nRIFF").message, "Can't show image/webp files")
    end,
    input_statuses = function()
        local r = interpret("10 Search for something\r\n")
        T.eq(r.kind, "input"); T.eq(r.prompt, "Search for something"); T.eq(r.sensitive, false)
        T.eq(r.url, "gemini://g.test/dir/page.gmi")
        T.eq(interpret("11 Password\r\n").sensitive, true)
    end,
    redirects_resolve = function()
        local r = interpret("31 ../moved.gmi\r\n")
        T.eq(r.kind, "redirect"); T.eq(r.url, "gemini://g.test/moved.gmi")
        T.eq(interpret("30 https://w.test/x\r\n").url, "https://w.test/x")
        T.eq(interpret("30 \r\n").message, "Not a Gemini response")
    end,
    failures = function()
        T.eq(interpret("40 Server busy\r\n").message, "Server busy (40)")
        T.eq(interpret("42\r\n").message, "Temporary failure (42)")
        T.eq(interpret("44 30\r\n").message, "Server asks to wait 30 s")
        T.eq(interpret("51 Gone fishing\r\n").message, "Not found")
        T.eq(interpret("59 Bad request\r\n").message, "Bad request (59)")
        T.eq(interpret("52\r\n").message, "Permanent failure (52)")
        T.eq(interpret("60 Need a cert\r\n").message,
            "This page needs a client certificate, which PicoSurf doesn't support")
        T.eq(interpret("70 What\r\n").message, "Not a Gemini response")
        T.eq(interpret("").message, "Not a Gemini response")
    end,
    a_300_kb_line_folds_whole = function() -- Review Focus 1
        local line = string.rep("caf\u{00E9} ", 300 * 1024 // 6)
        local r = interpret("20 text/gemini\r\n" .. line .. "\n")
        T.eq(#r.body, #line - (300 * 1024 // 6) + 1)
        T.ok(not r.body:find("[\128-\255]"))
    end,
    random_bytes_fold_to_printable_text = function() -- Review Focus 2
        local bytes = {}
        local seed = 7
        for i = 1, 4096 do
            seed = (seed * 1103515245 + 12345) % 2147483648
            bytes[i] = string.char(seed // 65536 % 256)
        end
        local r = interpret("20 text/gemini\r\n" .. table.concat(bytes))
        T.eq(r.kind, "gemini")
        T.ok(not r.body:find("[^\t\n\32-\126]"), "only tab, newline and printable ASCII")
    end,
    feed_keeps_dated_links = function()
        local body = "# My gemlog\n=> / Home\n=> 2024-03-02-post.gmi 2024-03-02 - Second post\n"
            .. "=> first.gmi 2024-01-15 First: post\n=> x.gmi 2024-01-01\n```\n=> pre.gmi 2023-01-01 In pre\n```\n"
        local r = interpret("20 text/gemini\r\n" .. body, "feed")
        T.eq(r.kind, "gemini"); T.eq(r.title, "My gemlog")
        T.eq(r.body, "=> gemini://g.test/dir/2024-03-02-post.gmi 2024-03-02 Second post\n"
            .. "=> gemini://g.test/dir/first.gmi 2024-01-15 First: post\n")
    end,
    feed_without_dated_links_fails = function()
        T.eq(interpret("20 text/gemini\r\n# Not a log\n=> a.gmi A\n", "feed").message, "No dated posts here - not a gemlog")
        T.eq(interpret("20 text/plain\r\nhello\n", "feed").message, "No dated posts here - not a gemlog")
    end,
}
