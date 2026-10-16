-- The page view: draws rows, handles scrolling, links and page keys (spec 6.2-6.4).
local layout = require("src.layout")
local theme = require("src.theme")
local url = require("src.url")

local S = {}
local MODE_LETTER = { reader = "R", full = "F", feed = "L" }

local function rowColor(th, st)
    if st == layout.H1 then return th.h1 end
    if st == layout.H2 then return th.h2 end
    if st == layout.H3 then return th.h3 end
    if st == layout.LINK then return th.link end
    if st == layout.IMAGE then return th.image end
    if st == layout.READ then return th.read end
    if st == layout.QUOTE then return th.quote end
    if st == layout.PRE then return th.pre end
    return th.fg
end

function S.draw(app)
    local th, d, p = app.theme, app.disp, app.page
    local L, ps = p.L, p.ps
    -- The header and footer draw in the current font: the system font, as in
    -- other apps. The title keeps to 220 px, clear of the clock and icons.
    d.setFont(th.ui)
    app.ui.drawHeader(p.title:sub(1, 220 // th.uiCw))
    local cols = theme.cols(th)
    for r = ps.top, ps:lastVisible() do
        local y = th.top + 1 + (r - ps.top) * th.rowH
        local st = L.style[r]
        local x = th.margin
        if L.link[r] ~= 0 and L.link[r] == ps.sel then d.fillRect(0, y - 1, 320, th.rowH, th.selBg) end
        local heading = st == layout.H1 or st == layout.H2 or st == layout.H3
        d.setFont(heading and th.bold or th.font)
        if st == layout.ITEM then
            d.drawText(x, y, "*", th.dim, false)
            x = x + 2 * th.cw
        elseif st == layout.ITEMC then
            x = x + 2 * th.cw
        elseif st == layout.QUOTE then
            d.fillRect(x, y - 1, 2, th.rowH, th.bar)
            x = x + 2 * th.cw
        end
        d.drawText(x, y, layout.rowText(L, r), rowColor(th, st), false)
        if L.cont[r] then d.drawText(th.margin + (cols - 1) * th.cw, y, "\\", th.dim, false) end
    end
    local left = url.host(p.url)
    if ps.digits ~= "" then left = "Link: " .. ps.digits .. "_" end
    -- A page that advertises a feed (X-Feed-Url) hints that F5 subscribes.
    local right = (p.feedUrl and "F5 feed  " or "") .. ps:percent() .. "% " .. (MODE_LETTER[p.mode] or "F")
    local room = (320 - 16) // th.uiCw - #right - 1
    d.setFont(th.ui)
    app.ui.drawFooter(left:sub(1, math.min(36, room)), right)
end

-- Inline pictures load while the page is on screen (inline images spec 5.2).
function S.update(app)
    app:stepImages()
end

-- Leaving by any route cancels the picture in flight; it's fetched again on return.
function S.leave(app)
    app:cancelInline(app.page)
end

function S.key(app, action, arg)
    local ps = app.page.ps
    if action == "digit" then
        ps:typeDigit(arg)
    elseif action == "backspace" and ps.digits ~= "" then
        ps:eraseDigit()
    elseif action == "esc" and ps.digits ~= "" then
        ps:clearDigits()
    elseif action == "enter" then
        if ps.digits ~= "" then
            local link, n = ps:takeNumbered()
            if link then return app:followLink(link) end
            if n then app:toast("No link [" .. n .. "] on this page", app.ui.TOAST_WARNING) end
        else
            local link = ps:selected()
            if link then return app:followLink(link) end
        end
    elseif action == "up" then
        ps:step(-1) -- the previous link if one is near, else scroll a row
    elseif action == "down" then
        ps:step(1)
    elseif action == "left" then
        ps:page(-1)
    elseif action == "right" or action == "space" then
        ps:page(1)
    elseif action == "nextlink" then
        ps:nextLink(1)
    elseif action == "prevlink" then
        ps:nextLink(-1)
    elseif action == "backspace" or action == "esc" then
        return app:goBack()
    elseif action == "f1" then
        return app:promptGo()
    elseif action == "f2" then
        return app:goHome()
    elseif action == "f3" then
        return app:toggleBookmark()
    elseif action == "f4" then
        return app:toggleMode()
    elseif action == "f5" then
        return app:subscribe()
    end
    app.dirty = true
end

return S
