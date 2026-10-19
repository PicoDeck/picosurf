-- Settings: proxy URL, token, font, images, search and a connection test
-- (spec 6.8, small web spec 9.3).
local wrap = require("src.wrap")
local theme = require("src.theme")
local fonts = require("src.fonts")

local S = {}
local ITEMS = { "proxy", "token", "font", "images", "search", "test" }

function S.enter(app)
    app.set = { sel = 1 }
end

local function label(app, item)
    local c = app.cfg
    if item == "proxy" then return "Proxy URL: " .. (c.proxyUrl ~= "" and c.proxyUrl or "(not set)") end
    if item == "token" then return "Token: " .. (c.token ~= "" and ("****" .. c.token:sub(-4)) or "(not set)") end
    if item == "font" then return "Font: " .. fonts.LABELS[c.font] end
    if item == "images" then return "Images: " .. (c.images == "inline" and "Inline" or "Links") end
    if item == "search" then return "Search: " .. (c.search ~= "" and (c.search:gsub("^%a[%w+.%-]*://", "")) or "(off)") end
    return "Test connection"
end

function S.draw(app)
    local th, d, set = app.theme, app.disp, app.set
    app.ui.drawHeader("PicoSurf Settings")
    for i, item in ipairs(ITEMS) do
        app.ui.drawListItem(0, 30 + (i - 1) * 16, 320, label(app, item), i == set.sel, true)
    end
    local notes = {}
    if app.cfg.proxyUrl == "" then
        notes[1] = "Web pages need a PicoSurf proxy (setup: github.com/PicoDeck/picosurf). "
            .. "Gemini and Gopher work without one."
    end
    if app.cfg.proxyUrl:lower():match("^http://") then
        notes[#notes + 1] = "Warning: http:// sends the token unencrypted."
    end
    if app.baseErr then notes[#notes + 1] = app.baseErr end
    -- The notes start 16 px below the last item.
    local cols, y = theme.uiCols(th), 30 + #ITEMS * 16 + 16
    for _, n in ipairs(notes) do
        local s, e = wrap.wrap(n, cols)
        for k = 1, #s do
            d.drawText(th.margin, y, n:sub(s[k], e[k]), th.dim, false)
            y = y + th.uiRowH
        end
    end
    app.ui.drawFooter("Enter edit  Esc done", "")
end

local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

function S.key(app, action)
    local set = app.set
    if action == "up" then
        set.sel = (set.sel - 2) % #ITEMS + 1
    elseif action == "down" then
        set.sel = set.sel % #ITEMS + 1
    elseif action == "enter" then
        local item = ITEMS[set.sel]
        if item == "proxy" then
            local v = app.ui.textInput("Proxy URL:", app.cfg.proxyUrl)
            app.input.clearState()
            if v then app:saveConfig("proxy_url", trim(v)) end
        elseif item == "token" then
            local v = app.ui.textInput("Token:", "")
            app.input.clearState()
            if v and trim(v) ~= "" then app:saveConfig("token", trim(v)) end
        elseif item == "font" then
            app:saveConfig("font", fonts.nextChoice(app.cfg.font)) -- lays the page out again
        elseif item == "images" then
            app:setImages(app.cfg.images == "inline" and "links" or "inline")
        elseif item == "search" then
            local v = app.ui.textInput("Search URL:", app.cfg.search)
            app.input.clearState()
            if v then
                v = trim(v)
                app:savePref("search", v == "" and "off" or v)
            end
        else
            app:ping()
        end
    elseif action == "esc" or action == "backspace" then
        -- Opened from any screen: back to the page if there is one.
        return app:show(app.page and "page" or "home")
    end
    app.dirty = true
end

return S
