-- The reading fonts (proportional fonts spec 3): a Font choice's display
-- fonts, row height and indent, and every character's advance, measured once
-- so layout can wrap by width.
local M = {}

M.CHOICES = { "scientifica", "8x12", "sans", "serif" }
M.DEFAULT = "sans"
M.LABELS = { scientifica = "Scientifica", ["8x12"] = "8x12 (large)", sans = "Sans", serif = "Serif" }

-- The proportional fonts: their files in the app's fonts/ folder, and row height.
local FILES = {
    sans = { regular = "sans", bold = "sans-bold", rowH = 14 },
    serif = { regular = "serif", bold = "serif-bold", rowH = 13 },
}
local FIRST, LAST = 0x20, 0x7E

-- A choice by name; anything else, nil included, is the default.
function M.normalize(name)
    for _, c in ipairs(M.CHOICES) do
        if c == name then return name end
    end
    return M.DEFAULT
end

-- The choice after `name`, wrapping round.
function M.nextChoice(name)
    for i, c in ipairs(M.CHOICES) do
        if c == name then return M.CHOICES[i % #M.CHOICES + 1] end
    end
    return M.DEFAULT
end

-- Each character's advance in font `id`. widest: the largest; uniform: the
-- advance when they are all equal (a monospace font), else nil.
local function measure(disp, id)
    disp.setFont(id)
    local adv, widest, uniform = {}, 0, nil
    for c = FIRST, LAST do
        local w = disp.textWidth(string.char(c))
        adv[c] = w
        if w > widest then widest = w end
        if c == FIRST then uniform = w elseif uniform ~= w then uniform = false end
    end
    adv.widest, adv.uniform = widest, uniform or nil
    return adv
end

-- Scientifica or 8x12: built into the firmware, and their own code-block font.
local function builtin(disp, name)
    local large = name == "8x12"
    local font = large and disp.FONT_8X12 or disp.FONT_SCIENTIFICA
    local cw = large and 8 or 6
    return {
        name = large and "8x12" or "scientifica", font = font,
        bold = large and disp.FONT_8X12 or disp.FONT_SCIENTIFICA_BOLD,
        rowH = 13, indent = 2 * cw, pre = { font = font, cw = cw }, loaded = {},
    }
end

-- Loads choice `name` (one of CHOICES). Never raises: when a font file can't
-- be loaded, unloads what it did load and returns the Scientifica spec and
-- an error naming the file. The current font is left as it was.
function M.load(disp, appDir, name)
    local spec, err
    local f = FILES[name]
    if f then
        local ids = {}
        for _, file in ipairs({ f.regular, f.bold }) do
            local path = appDir .. "/fonts/" .. file .. ".pfn"
            local id, why = disp.loadFont(path)
            if not id then
                err = path .. ": " .. (why or "cannot load")
                break
            end
            ids[#ids + 1] = id
        end
        if err then
            for _, id in ipairs(ids) do disp.unloadFont(id) end
        else
            spec = {
                name = name, font = ids[1], bold = ids[2], rowH = f.rowH, indent = 12,
                pre = { font = disp.FONT_SCIENTIFICA, cw = 6 }, loaded = ids,
            }
        end
    end
    spec = spec or builtin(disp, err and "scientifica" or name)
    local current = disp.getFont()
    spec.adv, spec.boldAdv = measure(disp, spec.font), measure(disp, spec.bold)
    disp.setFont(current)
    return spec, err
end

function M.unload(disp, spec)
    for _, id in ipairs(spec.loaded) do disp.unloadFont(id) end
    spec.loaded = {}
end

return M
