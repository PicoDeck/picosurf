-- Home: Bookmarks and History lists (spec 6.2).
local S = {}
local TABS = { "Bookmarks", "History" }
local LIST_TOP, ROW_H = 43, 13
local VISIBLE = (302 - LIST_TOP) // ROW_H

local function items(app, tab)
    if TABS[tab] == "Bookmarks" then return app.store:bookmarks() end
    return app.store:history()
end

function S.enter(app)
    app.home = app.home or { tab = 1, sel = {}, top = {} }
end

function S.draw(app)
    local h, th = app.home, app.theme
    app.ui.drawHeader("PicoSurf")
    app.ui.drawTabs(21, TABS, h.tab)
    local list = items(app, h.tab)
    local sel, top = h.sel[h.tab] or 1, h.top[h.tab] or 1
    if #list == 0 then
        app.disp.setFont(th.font)
        local hint = TABS[h.tab] == "Bookmarks" and "No bookmarks yet. F3 on a page adds one."
            or "Nothing visited yet. F1 opens a URL."
        app.disp.drawText(th.margin, LIST_TOP + 20, hint, th.dim, false)
    end
    for i = top, math.min(#list, top + VISIBLE - 1) do
        local e = list[i]
        app.ui.drawListItem(0, LIST_TOP + (i - top) * ROW_H, 320, e.title or e.url, i == sel, true)
    end
    app.ui.drawFooter("F1 go  Del remove  Esc quit", "")
end

function S.key(app, action)
    local h = app.home
    local list = items(app, h.tab)
    local sel = h.sel[h.tab] or 1
    if action == "left" or action == "right" then
        h.tab = (h.tab + (action == "right" and 1 or -1) - 1) % #TABS + 1
        app:log("tab", TABS[h.tab])
    elseif action == "up" or action == "down" then
        sel = math.max(1, math.min(#list, sel + (action == "down" and 1 or -1)))
        h.sel[h.tab] = sel
        local top = h.top[h.tab] or 1
        if sel < top then top = sel elseif sel >= top + VISIBLE then top = sel - VISIBLE + 1 end
        h.top[h.tab] = top
    elseif action == "enter" then
        local e = list[sel]
        if e then return app:open(e.url) end
    elseif action == "del" then
        if list[sel] then
            if TABS[h.tab] == "Bookmarks" then app.store:removeBookmark(sel) else app.store:removeHistory(sel) end
            h.sel[h.tab] = math.max(1, math.min(sel, #items(app, h.tab)))
        end
    elseif action == "f1" then
        return app:promptGo()
    elseif action == "esc" then
        app.quit = true
    end
    app.dirty = true
end

return S
