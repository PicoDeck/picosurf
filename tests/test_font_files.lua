local T = require("tests.t")

-- The committed reading fonts (proportional fonts spec 2): each .pfn must be
-- one the firmware accepts (font_from_blob in PicoDeck's src/fonts/font.c)
-- and cover ASCII 0x20-0x7E within its font's row.
local ROW = { sans = 14, ["sans-bold"] = 14, serif = 13, ["serif-bold"] = 13 }

local function read(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("a")
    f:close()
    return data
end

return {
    committed_fonts_are_valid_and_cover_ascii = function()
        for name, rowH in pairs(ROW) do
            local label = name .. ".pfn"
            local data = read("fonts/" .. label)
            local magic, ver, flags, first, last, height, maxw, stride = string.unpack("<c4BBBBBBB", data)
            T.eq(magic, "PFNT", label); T.eq(ver, 1, label)
            T.ok(flags & 1 == 1, label .. ": proportional")
            T.eq(first, 0x20, label); T.eq(last, 0x7E, label)
            T.ok(height >= 1 and height <= rowH, label .. ": height " .. height .. " fits a " .. rowH .. " px row")
            T.eq(stride, (maxw + 7) // 8, label .. ": stride")
            local count = last - first + 1
            T.eq(#data, 12 + count + count * height * stride, label .. ": size")
            for i = 1, count do
                local w = data:byte(12 + i)
                T.ok(w >= 1 and w <= maxw, label .. ": width of glyph " .. (first + i - 1))
            end
        end
    end,
    the_font_licences_ship_with_them = function()
        local text = read("fonts/LICENSE")
        T.ok(text:find("Copyright 1984-1989, 1994 Adobe Systems Incorporated.", 1, true))
        T.ok(text:find("Digital Equipment Corporation", 1, true))
        T.ok(text:find("Utopia is a registered trademark of Adobe Systems Incorporated", 1, true))
    end,
}
