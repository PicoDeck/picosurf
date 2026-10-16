local T = require("tests.t")
local fakepc = require("tests.fakepc")
local App = require("src.app")
local layout = require("src.layout")

local function lines(from, to)
    local out = {}
    for i = from, to do out[#out + 1] = "line " .. i end
    return table.concat(out, "\n")
end

local FONTS_PAGE = table.concat({
    "# Reading fonts",
    "* " .. string.rep("item words ", 8),
    "> " .. string.rep("quoted words ", 6),
    "```",
    string.rep("x", 60),
    "```",
    string.rep("mmmm iiii ", 12),
    "https://example.com/" .. string.rep("averylongpath", 6),
}, "\n")

local LABEL = "[IMG] " .. string.rep("mmmm ", 19) .. "mmmm"

local function jpeg(w, h)
    return { type = "image/jpeg", mode = false, body = "JPEG:" .. w .. "x" .. h }
end

local ROUTES = {
    ["https://fonts.test/"] = { title = "F", body = FONTS_PAGE },
    ["https://label.test/"] = { title = "L", body = "# L\n=> https://img.test/p.jpg " .. LABEL .. "\n" },
    ["https://pics.test/"] = {
        title = "Pics",
        body = table.concat({ "# Pics", "intro", "=> https://img.test/1.jpg [IMG] one", lines(1, 40) }, "\n"),
    },
    ["https://b.test/"] = { title = "B", body = "# B\n\nBack page.\n" },
    ["https://img.test/p.jpg"] = jpeg(200, 120),
    ["https://img.test/1.jpg"] = jpeg(200, 120), -- 10 rows of 13 px, 9 of 14 px
}

-- opts.font: saved Font setting (nil: none saved); opts.missing: a font path that fails to load.
local function boot(opts)
    opts = opts or {}
    local F = fakepc.new()
    F.config.proxy_url, F.config.token = "https://p.test", "tok"
    if opts.font then F.config.font = opts.font end
    F.config.images = opts.images
    if opts.missing then F.missingFonts[opts.missing] = true end
    F.responder = fakepc.proxy(ROUTES, "tok")
    local app = App.new(F.pc, "net.picodeck.picosurf")
    app:start()
    app:step()
    return app, F
end

local function steps(app, n)
    for _ = 1, n or 3 do app:step() end
end

local function go(app, F, text)
    F.inputs[#F.inputs + 1] = text
    F.press("f1")
    steps(app)
end

-- The x of the first page text drawn in the last frame that starts with `prefix`.
local function xOf(F, prefix)
    for i, t in ipairs(F.texts) do
        if F.textXs[i] and t:sub(1, #prefix) == prefix then return F.textXs[i] end
    end
    return nil
end

-- No page text drawn in the last frame runs past the page's right margin.
local function assertWithinPage(F)
    local n = 0
    for i, t in ipairs(F.texts) do
        local x = F.textXs[i]
        if x then
            n = n + 1
            T.ok(x + F.textWidthIn(F.textFonts[i], t) <= 316, "overflows the page: " .. t)
        end
    end
    T.ok(n > 5, "page text was drawn")
end

local function boxRows(app, k)
    local L = app.page.L
    local link = L.links[k]
    if L.style[link.first] ~= layout.BOX then return 0 end
    return link.last - link.first + 1
end

return {
    proportional_pages_indent_and_keep_code_monospace = function() -- Review Focus 1
        local app, F = boot({ font = "sans" })
        go(app, F, "fonts.test/")
        local D = F.pc.display
        T.eq(app.theme.fontName, "sans")
        T.eq(F.fontFiles[F.fontOf("Reading fonts")], "/apps/picosurf/fonts/sans-bold.pfn", "headings in bold")
        T.eq(F.fontFiles[F.fontOf("mmmm iiii")], "/apps/picosurf/fonts/sans.pfn", "text in Sans")
        T.eq(F.fontOf(string.rep("x", 51)), D.FONT_SCIENTIFICA, "code in Scientifica")
        T.eq(xOf(F, string.rep("x", 51)), 4)
        T.eq(xOf(F, "\\"), 4 + 51 * 6, "the continuation mark after 51 columns")
        T.eq(xOf(F, "*"), 4, "the bullet at the margin")
        T.eq(xOf(F, "item words"), 16, "item text after the 12 px indent")
        T.eq(xOf(F, "quoted words"), 16, "quotes after the indent")
        T.eq(xOf(F, "mmmm iiii"), 4)
        assertWithinPage(F)
    end,
    a_picture_label_is_cut_to_fit_by_width = function()
        local app, F = boot({ font = "sans", images = "inline" })
        go(app, F, "label.test/")
        steps(app, 3)
        local st = app.page.inline
        st.byUrl["https://img.test/p.jpg"].img = nil -- as after it left the window
        st.wake = false
        app.dirty = true
        steps(app, 1)
        local found
        for i, t in ipairs(F.texts) do
            if F.textXs[i] and #t > 5 and LABEL:sub(1, #t) == t then found = i end
        end
        T.ok(found, "the label is drawn")
        local font, shown = F.textFonts[found], F.texts[found]
        T.ok(F.textWidthIn(font, shown) <= 300, "within the box")
        T.ok(F.textWidthIn(font, LABEL:sub(1, #shown + 1)) > 300, "as much as fits")
    end,
}
