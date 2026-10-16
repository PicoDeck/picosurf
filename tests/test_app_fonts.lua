local T = require("tests.t")
local fakepc = require("tests.fakepc")
local App = require("src.app")
local layout = require("src.layout")
local theme = require("src.theme")

local function lines(from, to)
    local out = {}
    for i = from, to do out[#out + 1] = "line " .. i end
    return table.concat(out, "\n")
end

-- n link lines, each one row.
local function links(n)
    local out = {}
    for i = 1, n do out[i] = "=> https://b.test/ link " .. i end
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
    ["https://links.test/"] = { title = "Links", body = "# Links\n" .. links(30) },
    ["https://wide.test/"] = { title = "W", body = "# Wide\n" .. string.rep("mmmm wwww ", 40) },
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

-- Settings, then Enter on row n; Esc back.
local function setting(app, F, n)
    F.menu["Settings"](); steps(app, 1)
    for _ = 2, n do F.press("down") end
    F.press("enter"); steps(app, 1)
    F.press("esc"); steps(app, 1)
end

-- The Font row (the third) steps to the next font.
local function nextFont(app, F) setting(app, F, 3) end

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
    the_default_font_is_sans = function()
        local app, F = boot()
        T.eq(app.cfg.font, "sans"); T.eq(app.theme.fontName, "sans"); T.eq(app.theme.rowH, 14)
        T.eq(theme.rows(app.theme), 20)
        T.ok(F.hasLog("picosurf: font sans"))
    end,
    settings_step_through_the_four_fonts = function()
        local app, F = boot({ font = "sans" })
        local LABEL = { serif = "Serif", scientifica = "Scientifica", ["8x12"] = "8x12 (large)", sans = "Sans" }
        local seen = {}
        for _ = 1, 4 do
            F.menu["Settings"](); steps(app, 1)
            F.press("down"); F.press("down"); F.press("enter"); steps(app, 1)
            seen[#seen + 1] = F.config.font
            T.ok(F.screenText():find("Font: " .. LABEL[F.config.font], 1, true), "label for " .. F.config.font)
            T.eq(app.theme.fontName, F.config.font)
            F.press("esc"); steps(app, 1)
        end
        T.eq(table.concat(seen, ","), "serif,scientifica,8x12,sans")
        local loaded = 0
        for _ in pairs(F.fontFiles) do loaded = loaded + 1 end
        T.eq(loaded, 2, "only the current font's two files stay loaded")
    end,
    a_missing_font_file_falls_back_to_scientifica = function() -- Review Focus 4
        local app, F = boot({ font = "serif", missing = "/apps/picosurf/fonts/serif-bold.pfn" })
        T.eq(app.theme.fontName, "scientifica"); T.eq(app.cfg.font, "serif", "the setting keeps its value")
        T.ok(F.hasToast("Font unavailable - using Scientifica"))
        T.ok(F.hasLog("/apps/picosurf/fonts/serif-bold.pfn"))
        T.ok(F.hasLog("picosurf: font scientifica"))
        T.eq(next(F.fontFiles), nil, "nothing left loaded")
    end,
    a_font_change_resizes_picture_boxes_and_keeps_the_line = function() -- Review Focus 3
        local app, F = boot({ font = "scientifica", images = "inline" })
        go(app, F, "pics.test/")
        steps(app, 3)
        T.eq(boxRows(app, 1), 10, "120 px on 13 px rows")
        app.page.ps:scroll(15); app.dirty = true; steps(app, 2)
        local line = app.page.L.line[app.page.ps.top]
        nextFont(app, F); nextFont(app, F) -- scientifica -> 8x12 -> sans
        T.eq(app.cfg.font, "sans")
        T.eq(boxRows(app, 1), 9, "120 px on 14 px rows")
        T.eq(app.page.L.line[app.page.ps.top], line, "the same line at the top")
    end,
    back_across_a_font_change_lands_on_the_same_line = function() -- Review Focus 5
        local app, F = boot({ font = "scientifica", images = "inline" })
        go(app, F, "pics.test/")
        steps(app, 3)
        app.page.ps:scroll(15); app.dirty = true; steps(app, 2)
        local line = app.page.L.line[app.page.ps.top]
        go(app, F, "b.test/")
        nextFont(app, F); nextFont(app, F)
        F.press("backspace"); steps(app, 3)
        T.eq(app.page.url, "https://pics.test/")
        T.eq(app.page.L.line[app.page.ps.top], line, "the same line at the top")
        T.eq(boxRows(app, 1), 9, "the box in Sans rows from the saved height")
    end,
    a_font_loaded_on_a_retry_lays_the_page_out_again = function() -- final review F1
        local app, F = boot({ font = "sans", missing = "/apps/picosurf/fonts/sans.pfn" })
        go(app, F, "wide.test/")
        T.eq(app.theme.fontName, "scientifica")
        F.missingFonts["/apps/picosurf/fonts/sans.pfn"] = nil
        setting(app, F, 4) -- Images: Inline. Any saved setting tries the font again.
        T.eq(app.theme.fontName, "sans")
        T.eq(app.page.ps.visible, theme.rows(app.theme), "20 rows of 14 px")
        assertWithinPage(F)
    end,
    back_across_a_font_change_keeps_the_selected_link = function() -- final review F2
        local app, F = boot({ font = "scientifica" })
        go(app, F, "links.test/")
        local ps = app.page.ps
        local vis = ps:visibleLinks()
        local sel = vis[#vis]
        T.eq(app.page.L.links[sel].first, ps:lastVisible(), "a link on the bottom row")
        ps.sel = sel; app.dirty = true; steps(app, 1)
        go(app, F, "b.test/")
        nextFont(app, F); nextFont(app, F) -- scientifica -> 8x12 -> sans: 21 rows to 20
        F.press("backspace"); steps(app, 3)
        T.eq(app.page.url, "https://links.test/")
        ps = app.page.ps
        T.eq(ps.sel, sel, "the same link selected")
        T.eq(app.page.L.links[sel].last, ps:lastVisible(), "scrolled just far enough to show it")
    end,
}
