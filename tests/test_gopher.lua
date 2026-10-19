local T = require("tests.t")
local gopher = require("src.gopher")

local MENU = table.concat({
    "iWelcome to the hole\t\terror.host\t1",
    "i  ___   art\tfake\t(NULL)\t0",
    "1Phlog\t/phlog\tg.test\t70",
    "0About me\t/about.txt\tg.test\t70",
    "7Search\t/search\tOther.Test\t7070",
    "IA cat\t/cat.jpg\tg.test\t70",
    "9Archive\t/a.zip\tg.test\t70",
    "8Old BBS\t\tbbs.test\t23",
    "hWeb page\tURL:https://w.test/x\tg.test\t70",
    "3Something broke\t\terror.host\t1",
    "XUnknown thing\t/x\tg.test\t70",
    "a line without tabs",
    "iCaf\u{00E9}\t\terror.host\t1",
    ".",
    "1After the end\t/z\tg.test\t70",
}, "\r\n") .. "\r\n"

return {
    parse_urls = function()
        local r = gopher.parse("gopher://G.Test")
        T.eq(r.host, "g.test"); T.eq(r.port, 70); T.eq(r.type, "1"); T.eq(r.selector, ""); T.eq(r.search, nil)
        r = gopher.parse("gopher://g.test:7070/0/docs/a%20b.txt")
        T.eq(r.port, 7070); T.eq(r.type, "0"); T.eq(r.selector, "/docs/a b.txt")
        r = gopher.parse("gopher://g.test/7/v2/vs%09cats and dogs")
        T.eq(r.type, "7"); T.eq(r.selector, "/v2/vs"); T.eq(r.search, "cats and dogs")
        T.eq(gopher.parse("gopher://g.test/").type, "1")
        T.eq(select(2, gopher.parse("gemini://g.test/")), "Not a Gopher URL")
        T.eq(select(2, gopher.parse("gopher://g.test:99999/")), "Not a Gopher URL")
    end,
    request_lines = function()
        T.eq(gopher.request(gopher.parse("gopher://g.test/1/phlog")), "/phlog\r\n")
        T.eq(gopher.request(gopher.parse("gopher://g.test/7/s%09two words")), "/s\ttwo words\r\n")
        T.eq(gopher.request(gopher.parse("gopher://g.test")), "\r\n")
    end,
    item_urls = function()
        T.eq(gopher.url("g.test", 70, "1", "/a b?c"), "gopher://g.test/1/a%20b%3Fc")
        T.eq(gopher.url("g.test", 7070, "0", ""), "gopher://g.test:7070/0")
    end,
    blocked_and_search_links = function()
        T.eq(gopher.blocked("gopher://g.test/9/a.zip"), "Can't open binary files")
        T.eq(gopher.blocked("gopher://g.test/8"), "Telnet isn't supported")
        T.eq(gopher.blocked("gopher://g.test/1/"), nil)
        T.eq(gopher.needsSearch("gopher://g.test/7/s"), true)
        T.eq(gopher.needsSearch("gopher://g.test/7/s%09q"), false)
        T.eq(gopher.needsSearch("gopher://g.test/1/s"), false)
    end,
    menus_become_gemtext = function()
        local body = gopher.menu(MENU)
        T.eq(body, table.concat({
            "```", "Welcome to the hole", "  ___   art", "```",
            "=> gopher://g.test/1/phlog Phlog",
            "=> gopher://g.test/0/about.txt About me",
            "=> gopher://other.test:7070/7/search [?] Search",
            "=> gopher://g.test/I/cat.jpg [IMG] A cat",
            "=> gopher://g.test/9/a.zip [BIN] Archive",
            "=> gopher://bbs.test:23/8 [TEL] Old BBS",
            "=> https://w.test/x Web page",
            "Something broke",
            "Unknown thing",
            "a line without tabs",
            "```", "Cafe", "```",
        }, "\n") .. "\n")
    end,
    menu_lines_with_bare_lf_and_no_terminator = function()
        local crlf = gopher.menu("1A\t/a\tg.test\t70\r\n.\r\n")
        T.eq(gopher.menu("1A\t/a\tg.test\t70\n"), crlf)
        T.eq(crlf, "=> gopher://g.test/1/a A\n")
    end,
    info_lines_cannot_toggle_preformatting = function()
        T.eq(gopher.menu("i```\t\tx\t1\r\n"), "```\n ```\n```\n")
    end,
    interpret_by_type = function()
        local menu = gopher.interpret(gopher.parse("gopher://g.test/1/phlog"), "1A\t/a\tg.test\t70\r\n.\r\n")
        T.eq(menu.kind, "gemini"); T.eq(menu.mode, "native"); T.eq(menu.title, "g.test/phlog")
        T.eq(menu.finalUrl, "gopher://g.test/1/phlog"); T.eq(menu.body, "=> gopher://g.test/1/a A\n")
        local text = gopher.interpret(gopher.parse("gopher://g.test/0about"), "Hello there\r\nfriend\r\n.\r\n")
        T.eq(text.body, "Hello there\nfriend\n"); T.eq(text.title, "g.test/about")
        local img = gopher.interpret(gopher.parse("gopher://g.test/I/c.jpg"), "\255\216")
        T.eq(img.kind, "image"); T.eq(img.native, true)
        T.eq(gopher.interpret(gopher.parse("gopher://g.test/1/"), "").message, "Empty response from g.test")
        T.eq(gopher.interpret(gopher.parse("gopher://g.test/5/x"), "x").message, "Can't open this kind of Gopher item")
        T.eq(gopher.interpret(gopher.parse("gopher://g.test/1/"), "x", "feed").message, "Feeds aren't supported for Gopher")
    end,
    latin1_menus = function()
        T.eq(gopher.menu(require("src.fold").decode("iCaf\233\t\tx\t1\r\n")), "```\nCafe\n```\n")
    end,
}
