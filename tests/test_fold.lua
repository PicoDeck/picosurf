local T = require("tests.t")
local fold = require("src.fold")

local function f(s, charset) return fold.line(fold.decode(s, charset)) end

return {
    ascii_passes_through_and_controls_go = function()
        T.eq(f("plain text"), "plain text")
        T.eq(f("a\tb\rc\0d\27e\127"), "a\tbcde")
    end,
    punctuation_follows_the_proxy_table = function()
        T.eq(f("\u{201C}Hi\u{201D} \u{2018}x\u{2019}"), "\"Hi\" 'x'")
        T.eq(f("a\u{2014}b \u{2013} c\u{2026}"), "a--b - c...")
        T.eq(f("\u{2022} 5\u{00D7}3 \u{2192} \u{00A9} \u{20AC}"), "* 5x3 -> (c) EUR")
        T.eq(f("x\u{00A0}y\u{2009}z"), "x y z")
    end,
    accented_letters_lose_their_marks = function()
        T.eq(f("Caf\u{00E9} Stra\u{00DF}e \u{0152}uvre \u{0141}\u{00F3}d\u{017A}"), "Cafe Strasse OEuvre Lodz")
        T.eq(f("e\u{0301}"), "e") -- a combining accent
        T.eq(f("\u{FB01}ne"), "fine")
    end,
    box_drawing_keeps_its_shape = function()
        T.eq(f("\u{250C}\u{2500}\u{2500}\u{2510}"), "+--+")
        T.eq(f("\u{2502} x \u{2551}"), "| x |")
        T.eq(f("\u{2571}\u{2572}\u{2573}"), "/\\X")
        T.eq(f("\u{2588}\u{2593}\u{2591}"), "###")
    end,
    emoji_and_joiners_are_removed = function()
        T.eq(f("hi \u{1F600}!"), "hi !")
        T.eq(f("\u{1F468}\u{200D}\u{1F469} \u{2764}\u{FE0F}"), " ")
        T.eq(f("soft\u{00AD}hyphen"), "softhyphen")
    end,
    other_scripts_become_question_marks = function()
        T.eq(f("\u{65E5}\u{672C} \u{03B1}\u{03B2}"), "?? ??")
    end,
    invalid_utf8_reads_as_latin1 = function()
        T.eq(fold.decode("caf\233"), "caf\u{00E9}")
        T.eq(f("caf\233 \147q\148"), "cafe \"q\"") -- Windows-1252 quotes
        T.eq(f("\195\169"), "e") -- valid UTF-8 stays UTF-8
    end,
    a_latin1_charset_reads_every_byte_as_latin1 = function()
        T.eq(fold.decode("\195\169", "ISO-8859-1"), "\u{00C3}\u{00A9}")
        T.eq(fold.decode("ascii only", "latin1"), "ascii only")
    end,
    url_percent_encodes_what_cannot_be_sent = function()
        T.eq(fold.url("gemini://x.test/caf\195\169 b"), "gemini://x.test/caf%C3%A9%20b")
        T.eq(fold.url("gemini://x.test/a?b=c"), "gemini://x.test/a?b=c")
    end,
}
