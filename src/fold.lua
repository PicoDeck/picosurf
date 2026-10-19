-- Text to ASCII for the device's fonts (small web spec 8.1): UTF-8 or
-- Latin-1 in, 0x20-0x7E plus tab out. The proxy folds web pages (main spec
-- 5.6); Gemini and Gopher text is folded here, line by line. Pure.
local M = {}

-- The proxy's table (ascii.ts), by code point.
local PUNCT = {
    [0x2018] = "'", [0x2019] = "'", [0x201A] = "'", [0x201B] = "'", [0x2032] = "'",
    [0x201C] = '"', [0x201D] = '"', [0x201E] = '"', [0x201F] = '"', [0x2033] = '"',
    [0xAB] = "<<", [0xBB] = ">>", [0x2039] = "<", [0x203A] = ">",
    [0x2010] = "-", [0x2011] = "-", [0x2012] = "-", [0x2013] = "-", [0x2212] = "-",
    [0x2014] = "--", [0x2015] = "--",
    [0x2026] = "...", [0x2022] = "*", [0xB7] = "*", [0x2023] = "*", [0x25E6] = "*",
    [0x2192] = "->", [0x2190] = "<-", [0x2194] = "<->", [0x21D2] = "=>", [0x2191] = "^", [0x2193] = "v",
    [0x2264] = "<=", [0x2265] = ">=", [0x2260] = "!=", [0x2248] = "~",
    [0xD7] = "x", [0xF7] = "/",
    [0xA9] = "(c)", [0xAE] = "(R)", [0x2122] = "(TM)",
    [0x20AC] = "EUR", [0xA3] = "GBP", [0xA5] = "JPY", [0xA2] = "c",
    [0xB0] = " deg",
    [0xBD] = "1/2", [0xBC] = "1/4", [0xBE] = "3/4",
    [0xA1] = "!", [0xBF] = "?", [0xA7] = "S", [0xB6] = "P",
    [0x2020] = "+", [0x2021] = "++", [0x2030] = "%o", [0x192] = "f", [0x2C6] = "^", [0x2DC] = "~",
}

-- Latin-1 Supplement and Latin Extended-A letters, and the Latin ligatures:
-- the proxy's NFKD-and-strip-marks result, which Lua cannot compute.
local LETTERS = {
    [0xC0] = "A", [0xC1] = "A", [0xC2] = "A", [0xC3] = "A", [0xC4] = "A", [0xC5] = "A", [0xC6] = "AE", [0xC7] = "C",
    [0xC8] = "E", [0xC9] = "E", [0xCA] = "E", [0xCB] = "E", [0xCC] = "I", [0xCD] = "I", [0xCE] = "I", [0xCF] = "I",
    [0xD0] = "D", [0xD1] = "N", [0xD2] = "O", [0xD3] = "O", [0xD4] = "O", [0xD5] = "O", [0xD6] = "O", [0xD8] = "O",
    [0xD9] = "U", [0xDA] = "U", [0xDB] = "U", [0xDC] = "U", [0xDD] = "Y", [0xDE] = "Th", [0xDF] = "ss", [0xE0] = "a",
    [0xE1] = "a", [0xE2] = "a", [0xE3] = "a", [0xE4] = "a", [0xE5] = "a", [0xE6] = "ae", [0xE7] = "c", [0xE8] = "e",
    [0xE9] = "e", [0xEA] = "e", [0xEB] = "e", [0xEC] = "i", [0xED] = "i", [0xEE] = "i", [0xEF] = "i", [0xF0] = "d",
    [0xF1] = "n", [0xF2] = "o", [0xF3] = "o", [0xF4] = "o", [0xF5] = "o", [0xF6] = "o", [0xF8] = "o", [0xF9] = "u",
    [0xFA] = "u", [0xFB] = "u", [0xFC] = "u", [0xFD] = "y", [0xFE] = "th", [0xFF] = "y", [0x100] = "A", [0x101] = "a",
    [0x102] = "A", [0x103] = "a", [0x104] = "A", [0x105] = "a", [0x106] = "C", [0x107] = "c", [0x108] = "C", [0x109] = "c",
    [0x10A] = "C", [0x10B] = "c", [0x10C] = "C", [0x10D] = "c", [0x10E] = "D", [0x10F] = "d", [0x110] = "D", [0x111] = "d",
    [0x112] = "E", [0x113] = "e", [0x114] = "E", [0x115] = "e", [0x116] = "E", [0x117] = "e", [0x118] = "E", [0x119] = "e",
    [0x11A] = "E", [0x11B] = "e", [0x11C] = "G", [0x11D] = "g", [0x11E] = "G", [0x11F] = "g", [0x120] = "G", [0x121] = "g",
    [0x122] = "G", [0x123] = "g", [0x124] = "H", [0x125] = "h", [0x128] = "I", [0x129] = "i", [0x12A] = "I", [0x12B] = "i",
    [0x12C] = "I", [0x12D] = "i", [0x12E] = "I", [0x12F] = "i", [0x130] = "I", [0x131] = "i", [0x132] = "IJ", [0x133] = "ij",
    [0x134] = "J", [0x135] = "j", [0x136] = "K", [0x137] = "k", [0x139] = "L", [0x13A] = "l", [0x13B] = "L", [0x13C] = "l",
    [0x13D] = "L", [0x13E] = "l", [0x141] = "L", [0x142] = "l", [0x143] = "N", [0x144] = "n", [0x145] = "N", [0x146] = "n",
    [0x147] = "N", [0x148] = "n", [0x14C] = "O", [0x14D] = "o", [0x14E] = "O", [0x14F] = "o", [0x150] = "O", [0x151] = "o",
    [0x152] = "OE", [0x153] = "oe", [0x154] = "R", [0x155] = "r", [0x156] = "R", [0x157] = "r", [0x158] = "R", [0x159] = "r",
    [0x15A] = "S", [0x15B] = "s", [0x15C] = "S", [0x15D] = "s", [0x15E] = "S", [0x15F] = "s", [0x160] = "S", [0x161] = "s",
    [0x162] = "T", [0x163] = "t", [0x164] = "T", [0x165] = "t", [0x168] = "U", [0x169] = "u", [0x16A] = "U", [0x16B] = "u",
    [0x16C] = "U", [0x16D] = "u", [0x16E] = "U", [0x16F] = "u", [0x170] = "U", [0x171] = "u", [0x172] = "U", [0x173] = "u",
    [0x174] = "W", [0x175] = "w", [0x176] = "Y", [0x177] = "y", [0x178] = "Y", [0x179] = "Z", [0x17A] = "z", [0x17B] = "Z",
    [0x17C] = "z", [0x17D] = "Z", [0x17E] = "z", [0x17F] = "s", [0xFB00] = "ff", [0xFB01] = "fi", [0xFB02] = "fl", [0xFB03] = "ffi",
    [0xFB04] = "ffl", [0xFB05] = "st", [0xFB06] = "st",
    [0x126] = "H", [0x127] = "h", [0x138] = "k", [0x13F] = "L", [0x140] = "l", [0x149] = "'n", [0x14A] = "N", [0x14B] = "n",
    [0x166] = "T", [0x167] = "t",
}

-- Box drawing (U+2500-257F) by shape; the rest of the block are joins.
local HORIZONTAL = {
    [0x2500] = true, [0x2501] = true, [0x2504] = true, [0x2505] = true, [0x2508] = true, [0x2509] = true,
    [0x254C] = true, [0x254D] = true, [0x2550] = true, [0x2574] = true, [0x2576] = true, [0x2578] = true,
    [0x257A] = true, [0x257C] = true, [0x257E] = true,
}
local VERTICAL = {
    [0x2502] = true, [0x2503] = true, [0x2506] = true, [0x2507] = true, [0x250A] = true, [0x250B] = true,
    [0x254E] = true, [0x254F] = true, [0x2551] = true, [0x2575] = true, [0x2577] = true, [0x2579] = true,
    [0x257B] = true, [0x257D] = true, [0x257F] = true,
}
local DIAGONAL = { [0x2571] = "/", [0x2572] = "\\", [0x2573] = "X" }

-- Windows-1252's printable 0x80-0x9F, which Latin-1 text from Gopher often is.
local CP1252 = {
    [0x80] = 0x20AC, [0x82] = 0x201A, [0x84] = 0x201E, [0x85] = 0x2026, [0x86] = 0x2020, [0x87] = 0x2021,
    [0x89] = 0x2030, [0x8B] = 0x2039, [0x91] = 0x2018, [0x92] = 0x2019, [0x93] = 0x201C, [0x94] = 0x201D,
    [0x95] = 0x2022, [0x96] = 0x2013, [0x97] = 0x2014, [0x99] = 0x2122, [0x9B] = 0x203A,
}

local LATIN1 = {
    ["iso-8859-1"] = true, ["iso_8859-1"] = true, ["latin1"] = true, ["latin-1"] = true,
    ["windows-1252"] = true, ["cp1252"] = true,
}

local function space(cp)
    return cp == 0xA0 or cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200A) or cp == 0x202F or cp == 0x205F
        or cp == 0x3000
end

-- Combining marks, C1 controls, the soft hyphen, zero-width characters,
-- variation selectors, tags, and emoji and other pictographs.
local function removed(cp)
    return (cp >= 0x80 and cp <= 0x9F) or cp == 0xAD or (cp >= 0x300 and cp <= 0x36F)
        or (cp >= 0x200B and cp <= 0x200D) or cp == 0x2060 or cp == 0xFEFF or (cp >= 0xFE00 and cp <= 0xFE0F)
        or (cp >= 0x2600 and cp <= 0x27BF) or (cp >= 0x1F000 and cp <= 0x1FAFF)
        or (cp >= 0xE0020 and cp <= 0xE007F)
end

local function fold(cp)
    local s = PUNCT[cp] or LETTERS[cp]
    if s then return s end
    if space(cp) then return " " end
    if removed(cp) then return "" end
    if cp >= 0x2500 and cp <= 0x257F then
        if HORIZONTAL[cp] then return "-" end
        if VERTICAL[cp] then return "|" end
        return DIAGONAL[cp] or "+"
    end
    if cp >= 0x2580 and cp <= 0x259F then return "#" end
    return "?"
end

-- s as UTF-8: unchanged when it is valid UTF-8 and charset (a MIME charset
-- name, or nil) is not a Latin-1 one; otherwise every byte is read as
-- Windows-1252/Latin-1.
function M.decode(s, charset)
    if not s:find("[\128-\255]") then return s end
    if not LATIN1[(charset or ""):lower()] and utf8.len(s) then return s end
    return (s:gsub("[\128-\255]", function(c)
        local b = c:byte()
        return utf8.char(CP1252[b] or b)
    end))
end

-- One line of valid UTF-8 (from decode) folded to ASCII. Tabs stay; other
-- control characters, a CR included, go.
function M.line(s)
    s = s:gsub("[\0-\8\11-\31\127]", "")
    if not s:find("[\128-\255]") then return s end
    return (s:gsub("[\192-\247][\128-\191]*", function(ch) return fold(utf8.codepoint(ch)) end))
end

-- A URL with its non-ASCII bytes, spaces and control characters
-- percent-encoded, so it can be requested.
function M.url(s)
    return (s:gsub("[%c%s\128-\255]", function(c) return string.format("%%%02X", c:byte()) end))
end

return M
