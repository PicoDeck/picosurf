local T = require("tests.t")
local textflow = require("src.textflow")

-- Seconds fn(n) takes (tests only: the device's Lua has no os).
local function timed(fn, n)
    local started = os.clock()
    fn(n)
    return os.clock() - started
end

local function lines(s)
    local t = {}
    for l in s:gmatch("([^\n]*)\n") do t[#t + 1] = l end
    return t
end

local PROSE = "The quick brown fox jumps over the lazy dog and keeps\n" ..
    "running far into the evening until it reaches home.\n"

return {
    prose_joins_into_one_line = function()
        T.eq(textflow.convert(PROSE), "The quick brown fox jumps over the lazy dog and keeps running far into "
            .. "the evening until it reaches home.\n")
    end,
    blocks_are_separated_by_one_blank_line = function()
        local out = lines(textflow.convert(PROSE .. "\n\n\n" .. PROSE))
        T.eq(#out, 3); T.eq(out[2], "")
    end,
    bullets_start_new_lines_inside_prose = function()
        local text = "These are the things this long paragraph lists for you today:\n" ..
            "* the first thing, which is long enough to wrap\n" ..
            "  and its second line\n" ..
            "- another thing\n12. a numbered thing\n"
        local out = lines(textflow.convert(text))
        T.eq(out[1], "These are the things this long paragraph lists for you today:")
        T.eq(out[2], "* the first thing, which is long enough to wrap and its second line")
        T.eq(out[3], "- another thing"); T.eq(out[4], "12. a numbered thing")
    end,
    short_lines_keep_their_breaks = function()
        local out = lines(textflow.convert("Roses are red,\nviolets are blue,\n  sugar is sweet\n"))
        T.eq(#out, 3); T.eq(out[1], "Roses are red,"); T.eq(out[3], "sugar is sweet")
    end,
    art_stays_monospace = function()
        local table = "Name        Size   Date\n" .. "file.txt    12 KB  2024-01-01 and more words to make it long\n"
        T.eq(textflow.convert(table), "```\n" .. table .. "```\n")
        local rule = "A heading with a rule under it that is fairly long\n==========\n"
        T.eq(lines(textflow.convert(rule))[1], "```")
        local box = "\u{250C}\u{2500}\u{2510} a box in a line that is more than long enough\n"
        T.eq(textflow.convert(box), "```\n+-+ a box in a line that is more than long enough\n```\n")
        local code = "    for i in range(10):\n        print(i, 'is a number we print out here')\n"
        T.eq(lines(textflow.convert(code))[2], "    for i in range(10):")
    end,
    gemtext_markers_are_escaped = function()
        local out = lines(textflow.convert("# not a heading\n=> not a link\n> not a quote\n"))
        T.eq(out[1], " # not a heading"); T.eq(out[2], " => not a link"); T.eq(out[3], " > not a quote")
        T.eq(lines(textflow.convert("```\n"))[1], " ```")
        T.eq(lines(textflow.convert("````````\n"))[2], " ````````") -- art keeps it, escaped
    end,
    tabs_cr_and_trailing_spaces = function()
        T.eq(textflow.convert("a\tb\r\nc   \r\n"), "```\na    b\nc\n```\n")
        T.eq(textflow.convert("one\r\ntwo\r\n"), "one\ntwo\n")
    end,
    text_is_folded = function()
        T.eq(textflow.convert("Caf\u{00E9} \u{2014} ok\n"), "Cafe -- ok\n")
    end,
    space_runs_take_linear_time = function()
        local line = "a" .. string.rep(" ", 30000) .. "b"
        local started = os.clock()
        local out = textflow.convert(line .. "\n")
        T.ok(os.clock() - started < 1, "a 30,000-space run took under 1 s on the host")
        T.eq(out, "```\n" .. line .. "\n```\n", "art: three or more spaces inside the line")
    end,
    long_prose_takes_linear_time = function()
        local function convert(n)
            return textflow.convert(string.rep("a line of prose that is long enough to be reflowed\n", n))
        end
        T.eq(#convert(15000), 15000 * 50 + 14999 + 1, "one reflowed line")
        convert(2500) -- warm up
        local small, big = timed(convert, 2500), timed(convert, 20000)
        T.ok(big < small * 16, string.format("8x the lines took %.1fx the time (linear: about 8x)", big / small))
    end,
}
