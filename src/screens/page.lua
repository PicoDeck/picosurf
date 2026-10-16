-- The page view: draws rows, handles scrolling, links and page keys (spec 6.2-6.4).
local layout = require("src.layout")
local theme = require("src.theme")
local url = require("src.url")
local inline = require("src.inline")
local wrap = require("src.wrap")

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
    if st == layout.PRE then return th.preColor end
    return th.fg
end

-- A 1 px rectangle, cropped to the rows between clipTop and clipBottom.
local function outline(d, x, y, w, h, color, clipTop, clipBottom)
    local y0, y1 = math.max(y, clipTop), math.min(y + h, clipBottom)
    if y1 <= y0 then return end
    d.fillRect(x, y0, 1, y1 - y0, color)
    d.fillRect(x + w - 1, y0, 1, y1 - y0, color)
    if y >= clipTop then d.fillRect(x, y, w, 1, color) end
    if y + h <= clipBottom then d.fillRect(x, y + h - 1, w, 1, color) end
end

-- Inline picture k's box (inline images spec 5.5), drawn from its first
-- visible row and cropped to the rows between the title bar and the footer:
-- the selection band, then the picture, or a dim outline and the label while
-- the picture isn't in memory.
local function drawBox(app, k)
    local th, d, p = app.theme, app.disp, app.page
    local L, ps = p.L, p.ps
    local link = L.links[k]
    local clipTop, clipBottom = th.top, th.top + ps.visible * th.rowH
    local bandTop = th.top + (link.first - ps.top) * th.rowH
    local bandH = (link.last - link.first + 1) * th.rowH
    if k == ps.sel then
        local y0, y1 = math.max(bandTop, clipTop), math.min(bandTop + bandH, clipBottom)
        d.fillRect(0, y0, 320, y1 - y0, th.selBg)
    end
    local e = p.inline and p.inline.byUrl[link.url]
    local w = e and e.w or inline.FIT_W
    local h = e and e.h or (bandH - 2 * inline.PAD)
    local x, y = (320 - w) // 2, bandTop + inline.PAD
    if e and e.img then
        local cut = math.max(0, clipTop - y)
        local shown = math.min(h, clipBottom - y) - cut
        if shown > 0 then e.img:draw(x, y + cut, false, { x = 0, y = cut, w = w, h = shown }) end
        return
    end
    outline(d, x, y, w, h, th.dim, clipTop, clipBottom)
    d.setFont(th.font)
    local row = math.max(link.first, ps.top)
    local label = wrap.fit(link.label, 320 - 2 * th.margin - 2 * th.pre.cw, th.adv)
    d.drawText(th.margin + th.pre.cw, th.top + 1 + (row - ps.top) * th.rowH, label, th.dim, false)
end

function S.draw(app)
    local th, d, p = app.theme, app.disp, app.page
    local L, ps = p.L, p.ps
    -- The header and footer draw in the current font: the system font, as in
    -- other apps. The title keeps to 220 px, clear of the clock and icons.
    d.setFont(th.ui)
    app.ui.drawHeader(p.title:sub(1, 220 // th.uiCw))
    local preCols = theme.preCols(th)
    for r = ps.top, ps:lastVisible() do
        local y = th.top + 1 + (r - ps.top) * th.rowH
        local st = L.style[r]
        if st == layout.BOX then
            local k = L.link[r]
            if r == L.links[k].first or r == ps.top then drawBox(app, k) end
        else
            local x = th.margin
            if L.link[r] ~= 0 and L.link[r] == ps.sel then d.fillRect(0, y - 1, 320, th.rowH, th.selBg) end
            local heading = st == layout.H1 or st == layout.H2 or st == layout.H3
            d.setFont(st == layout.PRE and th.pre.font or (heading and th.bold or th.font))
            if st == layout.ITEM then
                d.drawText(x, y, "*", th.dim, false)
                x = x + th.indent
            elseif st == layout.ITEMC then
                x = x + th.indent
            elseif st == layout.QUOTE then
                d.fillRect(x, y - 1, 2, th.rowH, th.bar)
                x = x + th.indent
            end
            d.drawText(x, y, layout.rowText(L, r), rowColor(th, st), false)
            if L.cont[r] then d.drawText(th.margin + preCols * th.pre.cw, y, "\\", th.dim, false) end
        end
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
