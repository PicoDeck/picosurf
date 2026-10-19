-- Plain text to gemtext (small web spec 8.2): prose is reflowed into the
-- reading font, art and tables stay monospace. In: UTF-8 (fold.decode).
-- Out: folded ASCII gemtext. Pure.
local fold = require("src.fold")

local M = {}
M.SHORT = 45 -- a block whose lines are all shorter keeps its line breaks

-- Lines without their CR, trailing spaces or tabs (4 spaces each).
local function splitLines(text)
    local out = {}
    if text:sub(-1) ~= "\n" then text = text .. "\n" end
    for l in text:gmatch("([^\n]*)\n") do
        out[#out + 1] = (l:gsub("\t", "    "):gsub("%s+$", ""))
    end
    return out
end

-- Box drawing, block elements or geometric shapes (U+2500-25BF), before folding.
local function hasBox(l)
    return l:find("\226[\148-\150]") ~= nil
end

local function isArt(block)
    local allIndented = true
    for _, l in ipairs(block) do
        if hasBox(l) then return true end
        local first = l:find("%S")
        if first and l:find("   ", first, true) then return true end
        if l:find("([^%w%s])%1%1%1") then return true end
        if not l:find("^%s") then allIndented = false end
    end
    return allIndented
end

local function isShort(block)
    for _, l in ipairs(block) do
        if (utf8.len(l) or #l) >= M.SHORT then return false end
    end
    return true
end

-- A folded text line that gemtext reads as text: lines that would be a link,
-- heading, quote or preformatting toggle get a leading space.
local function textLine(l)
    l = fold.line(l)
    if l:find("^=>") or l:find("^#") or l:find("^>") or l:find("^```") then return " " .. l end
    return l
end

local function addBlock(out, block)
    if isArt(block) then
        out[#out + 1] = "```"
        for _, l in ipairs(block) do
            l = fold.line(l)
            out[#out + 1] = l:find("^```") and (" " .. l) or l
        end
        out[#out + 1] = "```"
    elseif isShort(block) then
        for _, l in ipairs(block) do out[#out + 1] = textLine(l:match("^%s*(.*)$")) end
    else
        local cur
        for _, l in ipairs(block) do
            local t = l:match("^%s*(.*)$")
            if cur and not t:find("^[%*%-%+] ") and not t:find("^%d+%. ") then
                cur = cur .. " " .. t
            else
                if cur then out[#out + 1] = textLine(cur) end
                cur = t
            end
        end
        if cur then out[#out + 1] = textLine(cur) end
    end
end

function M.convert(text)
    local out, block = {}, {}
    local function flush()
        if #block == 0 then return end
        if #out > 0 then out[#out + 1] = "" end
        addBlock(out, block)
        block = {}
    end
    for _, l in ipairs(splitLines(text)) do
        if l:find("%S") then block[#block + 1] = l else flush() end
    end
    flush()
    return table.concat(out, "\n") .. "\n"
end

return M
