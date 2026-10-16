-- Home: Feeds, Bookmarks and History lists (spec 6.2, 6.7).
local feeds = require("src.feeds")
local wrap = require("src.wrap")
local theme = require("src.theme")

local S = {}
local TABS = { "Feeds", "Bookmarks", "History" }
local LIST_TOP, ROW_H = 43, 13
local VISIBLE = (302 - LIST_TOP) // ROW_H

local function items(app, tab)
    local name = TABS[tab]
    if name == "Feeds" then
        local out = {}
        for i, f in ipairs(feeds.sorted(app.store:feedIndex())) do
            out[i] = { title = (f.title or f.url) .. " (" .. (f.unread or 0) .. ")", feed = f }
        end
        return out
    end
    if name == "Bookmarks" then return app.store:bookmarks() end
    return app.store:history()
end

local HINTS = {
    Feeds = "No feeds yet. F5 on a page subscribes.",
    Bookmarks = "No bookmarks yet. F3 on a page adds one.",
    History = "Nothing visited yet. F1 opens a URL.",
}

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
        local hint = HINTS[TABS[h.tab]]
        local s, e = wrap.wrap(hint, theme.uiCols(th))
        for k = 1, #s do
            app.disp.drawText(th.margin, LIST_TOP + 20 + (k - 1) * th.uiRowH, hint:sub(s[k], e[k]), th.dim, false)
        end
    end
    for i = top, math.min(#list, top + VISIBLE - 1) do
        local e = list[i]
        app.ui.drawListItem(0, LIST_TOP + (i - top) * ROW_H, 320, e.title or e.url, i == sel, true)
    end
    local R = app.refresh
    if R then
        app.ui.drawFooter("Refreshing " .. R.done .. "/" .. #R.list .. "  Esc stop", "")
    elseif TABS[h.tab] == "Feeds" then
        app.ui.drawFooter("F5 refresh  Del remove  Esc quit", "")
    else
        app.ui.drawFooter("F1 go  Del remove  Esc quit", "")
    end
end

local function remove(app, h, entry, sel)
    local name = TABS[h.tab]
    if name == "Feeds" then
        local f = entry.feed
        if not app.ui.confirm("Unsubscribe from " .. (f.title or f.url):sub(1, 30) .. "?") then return end
        app.input.clearState()
        feeds.unsubscribe(app.store:feedIndex(), f.id)
        app.store:deleteFeedData(f.id)
        app.store:saveFeedIndex()
        app:log("unsubscribed", f.id)
    elseif name == "Bookmarks" then
        app.store:removeBookmark(sel)
    else
        app.store:removeHistory(sel)
    end
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
        if e and e.feed then return app:openFeed(e.feed) end
        if e then return app:open(e.url) end
    elseif action == "del" then
        if list[sel] then
            remove(app, h, list[sel], sel)
            local n = #items(app, h.tab)
            local nsel = math.max(1, math.min(sel, n))
            local top = h.top[h.tab] or 1
            -- Keep the window inside the shortened list, filled when possible.
            top = math.max(1, math.min(top, n - VISIBLE + 1))
            if nsel < top then top = nsel end
            h.sel[h.tab], h.top[h.tab] = nsel, top
        end
    elseif action == "f1" then
        app:cancelRefresh()
        return app:promptGo()
    elseif action == "f5" and TABS[h.tab] == "Feeds" then
        app:refreshAll()
    elseif action == "esc" then
        if app.refresh then app:cancelRefresh() else app.quit = true end
    end
    app.dirty = true
end

return S
