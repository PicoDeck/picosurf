local T = require("tests.t")
local g = require("src.gemtext")

return {
    parses_every_line_type = function()
        local lines = g.parse("# One\n## Two\n### Three\n#### Four\ntext\n* item\n> quote\n>bare\n\n=> https://a.test/ [3] the docs\n")
        local want = {
            { "h1", "One" }, { "h2", "Two" }, { "h3", "Three" }, { "h3", "Four" }, { "text", "text" },
            { "item", "item" }, { "quote", "quote" }, { "quote", "bare" }, { "blank", "" }, { "link", "[3] the docs" },
        }
        T.eq(#lines, #want)
        for i, w in ipairs(want) do
            T.eq(lines[i].t, w[1], "type " .. i)
            T.eq(lines[i].text, w[2], "text " .. i)
        end
        T.eq(lines[10].url, "https://a.test/")
        T.eq(lines[10].n, 3)
        T.eq(math.type(lines[10].n), "integer")
        T.eq(lines[10].image, false)
    end,
    links_without_a_label_show_the_url_and_images_are_flagged = function()
        local lines = g.parse("=> https://a.test/x\n=>https://a.test/c.jpg [IMG] A cat\n=>\n")
        T.eq(lines[1].text, "https://a.test/x")
        T.eq(lines[1].n, nil)
        T.eq(lines[2].image, true)
        T.eq(lines[2].url, "https://a.test/c.jpg")
        T.eq(lines[3].t, "text", "a bare => is text")
    end,
    preformatted_blocks_keep_their_lines = function()
        local lines = g.parse("before\n```lua\n=> not a link\n# not a heading\n\tx\n```\nafter")
        T.eq(#lines, 5)
        T.eq(lines[2].t, "pre"); T.eq(lines[2].text, "=> not a link")
        T.eq(lines[3].t, "pre"); T.eq(lines[3].text, "# not a heading")
        T.eq(lines[4].text, "    x", "tab expanded")
        T.eq(lines[5].text, "after")
    end,
    escaped_text_stays_text_and_crlf_is_removed = function()
        local lines = g.parse(" # not heading\r\n => not link\r\n")
        T.eq(lines[1].t, "text"); T.eq(lines[1].text, " # not heading")
        T.eq(lines[2].t, "text"); T.eq(lines[2].text, " => not link")
    end,
    plain_text_becomes_text_and_blank_lines = function()
        local lines = g.fromPlain("a\tb\n\n# c\n")
        T.eq(#lines, 3)
        T.eq(lines[1].text, "a    b")
        T.eq(lines[2].t, "blank")
        T.eq(lines[3].t, "text"); T.eq(lines[3].text, "# c")
    end,
    title_is_the_first_heading = function()
        T.eq(g.title(g.parse("text\n## Sub\n# Main\n# Later\n")), "Main")
        T.eq(g.title(g.parse("no heading\n")), nil)
    end,
    feed_items_split_dates_from_titles = function()
        local items = g.feedItems(g.parse("# Blog\n\n=> https://b.test/2 2026-10-13 Two\n=> https://b.test/u Undated\n"))
        T.eq(#items, 2)
        T.eq(items[1].url, "https://b.test/2"); T.eq(items[1].date, "2026-10-13"); T.eq(items[1].title, "Two")
        T.eq(items[2].date, nil); T.eq(items[2].title, "Undated")
    end,
}
