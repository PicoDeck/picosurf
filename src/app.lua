-- The app: config, screens, the main loop, proxy requests and navigation (spec 6).
local url = require("src.url")
local proxy = require("src.proxy")
local http = require("src.http")
local gemtext = require("src.gemtext")
local layout = require("src.layout")
local pagestate = require("src.pagestate")
local store = require("src.store")
local keys = require("src.keys")
local theme = require("src.theme")
local feeds = require("src.feeds")

local App = {}
App.__index = App
App.MAX_BACK, App.MAX_CACHE = 20, 3

local SCREENS = { "home", "page", "image", "settings", "loading", "message" }

-- pc: the picocalc API (a fake in host tests); appId: app.json's id.
function App.new(pc, appId)
    local self = setmetatable({ pc = pc }, App)
    self.disp, self.ui, self.input, self.sys = pc.display, pc.ui, pc.input, pc.sys
    self.store = store.new(pc.fs, pc.json, "/data/" .. appId)
    self.decode = keys.decoder(pc.input)
    self.screens = {}
    for _, name in ipairs(SCREENS) do self.screens[name] = require("src.screens." .. name) end
    self.back, self.cache, self.inbox = {}, {}, {}
    self.dirty = true
    self:loadConfig()
    return self
end

function App:loadConfig()
    local c = self.pc.config
    self.cfg = { proxyUrl = c.get("proxy_url") or "", token = c.get("token") or "", font = c.get("font") or "scientifica" }
    self.theme = theme.new(self.disp, self.cfg.font)
    self:cancelRefresh() -- before closeAll, which would fail its requests
    if self.pool then self.pool:closeAll() end
    self.pool, self.base, self.baseErr = nil, nil, nil
    if self.cfg.proxyUrl ~= "" then
        self.base, self.baseErr = url.parseBase(self.cfg.proxyUrl)
        if self.base then self.pool = http.pool(self.pc.network, self.base) end
    end
end

function App:saveConfig(key, value)
    self.pc.config.set(key, value)
    self.pc.config.save()
    self:loadConfig()
end

function App:log(...)
    local parts = { ... }
    for i = 1, select("#", ...) do parts[i] = tostring(parts[i]) end
    self.sys.log("picosurf: " .. table.concat(parts, " "))
end

-- Toasts are drawn by a flush and last TOAST_MS on the device; queued ones
-- show one after another. step keeps flushing until the last has expired,
-- plus a margin so the final flush comes after the device's toast has gone.
App.TOAST_MS, App.TOAST_MARGIN_MS = 3000, 250
-- The header's clock, battery and WiFi icons are redrawn this often when idle.
App.IDLE_REDRAW_MS = 30000

function App:toast(text, style)
    self.ui.toast(text, style or self.ui.TOAST_INFO)
    self.dirty = true
    local now = self.sys.getTimeMs()
    local base = self.toastEnd
    if not base or now - base > 0 then base = now end
    self.toastEnd = base + App.TOAST_MS
    self.toastUntil = self.toastEnd + App.TOAST_MARGIN_MS
    self.nextToastDraw = self.nextToastDraw or now
end

-- Cancels the active load: its handle, its state and its late response.
function App:cancelLoad()
    local L = self.loading
    if not L then return end
    self.loading = nil
    if L.handle then L.handle.cancel() end
    self:log("cancelled", L.url)
end

function App:show(name, args)
    self:cancelLoad()
    if self.screen and self.screen.leave then self.screen.leave(self) end
    self.screenName = name
    self.screen = self.screens[name]
    self.dirty = true
    self:log("screen", name)
    if self.screen.enter then self.screen.enter(self, args or {}) end
end

function App:start()
    self:addMenuItems()
    if self.cfg.proxyUrl == "" then
        self:show("settings", { firstRun = true })
    else
        self:show("home")
    end
end

-- One pass of the main loop: input, finished requests, the screen's own
-- work, and a redraw only when something changed.
function App:step()
    self.input.update()
    while true do
        local ev = self.input.pollEvent()
        if not ev then break end
        local action, arg = self.decode(ev)
        if action and self.screen.key then self.screen.key(self, action, arg) end
    end
    self:pump()
    if self.screen.update then self.screen.update(self) end
    local now = self.sys.getTimeMs()
    if self.toastUntil then
        if now - self.nextToastDraw >= 0 then
            self.dirty = true
            self.nextToastDraw = now + 250
            if now - self.toastUntil >= 0 then self.toastUntil, self.nextToastDraw = nil, nil end
        end
    end
    if self.lastDraw and now - self.lastDraw >= App.IDLE_REDRAW_MS then self.dirty = true end
    if self.dirty then
        self.dirty = false
        self.lastDraw = now
        self.disp.clear(self.theme.bg)
        self.screen.draw(self)
        self.disp.flush()
    end
end

-- step, with a Lua error (a string) logged and shown instead of ending the
-- app. Anything else, such as the firmware's exit sentinel, is raised again.
-- step itself stays unguarded so host tests see errors.
function App:guardedStep()
    local ok, err = pcall(self.step, self)
    if ok then return end
    if type(err) ~= "string" then error(err, 0) end
    self:log("error", "-", err)
    self:show("message", { title = "Something went wrong", text = err })
end

function App:run()
    self:start()
    while not self.quit do
        self:guardedStep()
        self.sys.sleep(16)
    end
    if self.pool then self.pool:closeAll() end
end

-- Results arrive inside the firmware's service pass; they are applied here,
-- between steps, never in the middle of a draw.
function App:pump()
    while #self.inbox > 0 do
        local m = table.remove(self.inbox, 1)
        m.done(m.result)
        self.dirty = true
    end
    local notes = self.store.notes
    while #notes > 0 do self:toast(table.remove(notes, 1), self.ui.TOAST_WARNING) end
end

-- Starts a proxy request; done(result) runs from the main loop.
function App:request(target, as, done)
    if not self.pool then return nil, self.baseErr or "Set the proxy URL in Settings" end
    local handle, err = self.pool:get(proxy.getPath(self.base, target, as), proxy.headers(self.cfg.token),
        function(ok, status, body, headers)
            self.inbox[#self.inbox + 1] = { done = done, result = proxy.interpret(ok, status, body, headers) }
        end)
    if not handle then return nil, err == "busy" and "Busy: try again" or err end
    return handle
end

function App:ping()
    if not self.pool then
        return self:toast(self.baseErr or "Set the proxy URL first", self.ui.TOAST_WARNING)
    end
    local handle = self.pool:get(proxy.pingPath(self.base), proxy.headers(self.cfg.token),
        function(ok, status, body, headers)
            self.inbox[#self.inbox + 1] = {
                result = proxy.interpretPing(ok, status, body, headers),
                done = function(r)
                    if r.ok then
                        self:log("ping", "ok")
                        self:toast("Proxy OK", self.ui.TOAST_SUCCESS)
                    else
                        self:log("ping", "failed", r.message)
                        self:toast(r.message, self.ui.TOAST_ERROR)
                    end
                end,
            }
        end)
    if not handle then self:toast("Busy: try again", self.ui.TOAST_WARNING) end
end

function App:cacheKey(u, mode)
    return u .. "\n" .. mode
end

function App:cacheGet(u, mode)
    local k = self:cacheKey(u, mode)
    for i, e in ipairs(self.cache) do
        if e.key == k then
            table.remove(self.cache, i)
            self.cache[#self.cache + 1] = e
            return e.result
        end
    end
    return nil
end

function App:cacheDrop(u, mode)
    local k = self:cacheKey(u, mode)
    for i, e in ipairs(self.cache) do
        if e.key == k then
            table.remove(self.cache, i)
            return
        end
    end
end

function App:cachePut(u, mode, result)
    self:cacheDrop(u, mode)
    self.cache[#self.cache + 1] = { key = self:cacheKey(u, mode), result = result }
    while #self.cache > App.MAX_CACHE do table.remove(self.cache, 1) end
end

function App:showResult(target, mode, r, opts)
    opts = opts or {}
    if r.kind == "gemini" or r.kind == "text" then
        local finalUrl = r.finalUrl or target
        local page, err = self:buildPage(finalUrl, mode, r, opts.restore)
        if not page then return self:fail(err) end
        if opts.back then table.remove(self.back) end
        if opts.push ~= false and self.page then self:pushBack() end
        self.page = page
        self:cachePut(finalUrl, mode, r)
        if not opts.back then self.store:addHistory(finalUrl, page.title) end
        self:log("loaded", finalUrl, "mode=" .. page.mode, "links=" .. #page.L.links, "rows=" .. page.L.count)
        if r.truncated then self:toast("Page truncated by the proxy", self.ui.TOAST_WARNING) end
        return self:show("page")
    end
    if r.kind == "image" then
        local where = r.finalUrl or target
        local ok, img = pcall(self.pc.graphics.image.loadFromBuffer, r.body)
        if not ok or not img then
            self:log("error", "-", "image decode failed " .. where)
            return self:fail("Could not decode the image: " .. where)
        end
        if opts.back then table.remove(self.back) end
        return self:show("image", { url = where, image = img })
    end
    self:log("error", r.status or "-", r.message)
    self:fail(r.message, function() self:open(target, opts) end, r.status)
end

-- Runs fn (parsing or layout) under pcall. On an error, most likely out of
-- memory, logs it, drops the cached bodies, collects and tries once more
-- (spec 6.9). Returns fn's two results, or nil and "Page too large for memory".
function App:withMemoryRetry(fn)
    local ok, a, b = pcall(fn)
    if ok then return a, b end
    self:log("error", "-", a)
    self.cache = {}
    collectgarbage()
    ok, a, b = pcall(fn)
    if ok then return a, b end
    local msg = "Page too large for memory"
    self:log("error", "-", msg)
    return nil, msg
end

-- Parses and lays out a page.
function App:buildPage(finalUrl, mode, r, restore)
    local cols = theme.cols(self.theme)
    local lines, L = self:withMemoryRetry(function()
        local lines = r.kind == "text" and gemtext.fromPlain(r.body) or gemtext.parse(r.body)
        return lines, layout.build(lines, cols)
    end)
    if not lines then return nil, L end
    local page = {
        url = finalUrl, want = mode, mode = r.mode or (r.kind == "text" and "full" or mode),
        title = r.title or gemtext.title(lines) or url.host(finalUrl), feedUrl = r.feedUrl, lines = lines, L = L,
    }
    page.ps = pagestate.new(L, theme.rows(self.theme))
    if restore then page.ps:restore(restore.top, restore.sel) end
    return page
end

-- The first row of source line `li` (or of the first line after it).
local function firstRowOf(L, li)
    local lo, hi = 1, L.count
    while lo < hi do
        local mid = (lo + hi) // 2
        if L.line[mid] < li then lo = mid + 1 else hi = mid end
    end
    return lo
end

-- After a font change: lay the current page out again for the new width,
-- keeping the source line at the top and the selected link. Links are
-- numbered in source order, so the index holds across widths. Back entries
-- keep their old rows; restore() clamps them.
function App:relayout()
    local p = self.page
    if not p then return end
    local old = p.ps
    local line, sel = p.L.line[old.top], old.sel
    local L, err = self:withMemoryRetry(function() return layout.build(p.lines, theme.cols(self.theme)) end)
    if not L then
        self.page, self.back = nil, {}
        return self:fail(err)
    end
    p.L = L
    p.ps = pagestate.new(L, theme.rows(self.theme))
    local top = line and firstRowOf(L, line) or 1
    local link = sel and L.links[sel]
    if link and link.first > top + p.ps.visible - 1 then
        -- Longer rows pushed the link below the screen: scroll just far enough.
        top = math.min(link.first, link.last - p.ps.visible + 1)
    end
    p.ps:restore(top, sel)
end

-- The message screen titled "Error", or "Error <status>" for a proxy status.
function App:fail(message, retry, status)
    local title = status and ("Error " .. (math.tointeger(status) or status)) or "Error"
    self:show("message", { title = title, text = message or "Something went wrong", retry = retry })
end

function App:goHome()
    self.page, self.back = nil, {}
    self:show("home")
end

-- F1: ask for a URL. ui.textInput draws over the screen already shown. The log
-- line tells simulator tests the text box is open before they type.
function App:promptGo(default)
    self:log("prompt", "go")
    local text = self.ui.textInput("Go to:", default)
    self.input.clearState()
    self.dirty = true
    if not text then return end
    local target, err = url.normalize(text)
    if not target then return self:toast(err, self.ui.TOAST_WARNING) end
    self:open(target)
end

function App:toggleBookmark()
    local p = self.page
    if not p then return end
    local added = self.store:toggleBookmark(p.url, p.title)
    self:log("bookmark", added and "add" or "remove", p.url)
    self:toast(added and "Bookmarked" or "Bookmark removed", self.ui.TOAST_SUCCESS)
end

function App:toggleMode()
    local p = self.page
    -- A feed's article list has no reader or full mode.
    if not p or p.isFeedList then return end
    self:open(p.url, { mode = p.mode == "full" and "reader" or "full", push = false })
end

function App:editUrl()
    local p = self.page
    if not p or self.screenName ~= "page" then return self:promptGo() end
    if #p.url > 127 then return self:toast("URL too long to edit", self.ui.TOAST_WARNING) end
    self:promptGo(p.url)
end

function App:addMenuItems()
    self.sys.addMenuItem("Reload", function() self:reload() end)
    self.sys.addMenuItem("Edit URL", function() self:editUrl() end)
    self.sys.addMenuItem("Mark all read", function() self:markAllRead() end)
    self.sys.addMenuItem("Settings", function() self:show("settings") end)
end

-- Opens a URL in the page view. opts: mode ("reader"|"full"|"feed"),
-- push (false replaces the current page instead of stacking it), restore ({top, sel}),
-- back (set by goBack: the Back entry is removed only when the load succeeds).
function App:open(target, opts)
    opts = opts or {}
    local scheme = url.scheme(target)
    if scheme ~= "http" and scheme ~= "https" then
        return self:toast((scheme or "That") .. ":// links aren't supported yet", self.ui.TOAST_WARNING)
    end
    self:cancelRefresh() -- frees the connections a refresh holds
    local mode = opts.mode or "reader"
    local cached = self:cacheGet(target, mode)
    if cached then return self:showResult(target, mode, cached, opts) end
    self:show("loading", {
        url = target, as = mode,
        onResult = function(r) self:showResult(target, mode, r, opts) end,
        onCancel = function() self:show(self.page and "page" or "home") end,
    })
end

function App:pushBack()
    local p = self.page
    self.back[#self.back + 1] = {
        url = p.url, want = p.want, top = p.ps.top, sel = p.ps.sel, feedId = p.isFeedList and p.feedId or nil,
    }
    while #self.back > App.MAX_BACK do table.remove(self.back, 1) end
end

function App:goBack()
    local e = self.back[#self.back]
    if not e then return self:goHome() end
    local restore = { top = e.top, sel = e.sel }
    if e.feedId then
        -- A feed list needs no network and cannot fail, so its entry goes now.
        table.remove(self.back)
        local feed = self:feedById(e.feedId)
        if feed then return self:showFeed(feed, { push = false, restore = restore }) end
        return self:goBack() -- unsubscribed meanwhile
    end
    self:open(e.url, { mode = e.want, push = false, restore = restore, back = true })
end

function App:followLink(link)
    local p = self.page
    if p and p.isFeedList then
        local feed = self:feedById(p.feedId)
        local data = self.store:feedData(p.feedId)
        if feed and feeds.markRead(data, link.url) then
            self.store:saveFeedData(feed.id, data)
            feeds.summarize(feed, data)
            self.store:saveFeedIndex()
            self:log("feed", feed.id, "unread=" .. feed.unread)
        end
    end
    self:log("follow", link.url)
    self:open(link.url)
end

function App:reload()
    local p = self.page
    if not p or self.screenName ~= "page" then return self:toast("Nothing to reload") end
    if p.isFeedList then
        local feed = self:feedById(p.feedId)
        if feed then
            feed.fetched_at = 0
            return self:openFeed(feed, { push = false, restore = { top = p.ps.top, sel = p.ps.sel } })
        end
        return
    end
    self:cacheDrop(p.url, p.want)
    self:open(p.url, { mode = p.want, push = false, restore = { top = p.ps.top, sel = p.ps.sel } })
end

function App:now()
    local c = self.sys.getClock()
    return c.synced and c.epoch or 0
end

function App:feedById(id)
    for _, f in ipairs(self.store:feedIndex().feeds) do
        if f.id == id then return f end
    end
    return nil
end

-- Stores a fetched feed list (r: a gemini result from as=feed).
function App:applyFeed(feed, r)
    local items = gemtext.feedItems(gemtext.parse(r.body))
    local data = feeds.merge(self.store:feedData(feed.id), items)
    if r.title and r.title ~= "" then feed.title = r.title end
    feeds.summarize(feed, data, self:now())
    self.store:saveFeedData(feed.id, data)
    self.store:saveFeedIndex()
    return data
end

-- F5 on a page: subscribe to the feed it advertises (X-Feed-Url), or let the
-- proxy look for one from the page's URL.
function App:subscribe()
    local p = self.page
    if not p then return end
    if p.isFeedList then return self:toast("Already subscribed") end
    self:show("loading", {
        url = p.feedUrl or p.url, as = "feed",
        onCancel = function() self:show("page") end,
        onResult = function(r)
            self:show("page")
            if r.kind ~= "gemini" then
                self:log("error", r.status or "-", r.message)
                return self:toast(r.message or "Not a feed", self.ui.TOAST_ERROR)
            end
            local index = self.store:feedIndex()
            local feed, isNew = feeds.subscribe(index, r.finalUrl or p.url, (r.title ~= "" and r.title) or nil)
            if not feed then return self:toast(isNew, self.ui.TOAST_ERROR) end
            if not isNew then return self:toast("Already subscribed") end
            self:applyFeed(feed, r)
            self:log("subscribed", feed.id, feed.url, "unread=" .. feed.unread)
            self:toast("Subscribed: " .. feed.title, self.ui.TOAST_SUCCESS)
        end,
    })
end

-- Opens a feed's article list, fetching it first when stale.
function App:openFeed(feed, opts)
    opts = opts or {}
    self:cancelRefresh()
    if not feeds.isStale(feed, self:now()) then return self:showFeed(feed, opts) end
    if self.pc.network.getStatus() ~= 1 then -- spec 6.7, 6.9: saved feeds work offline
        self:showFeed(feed, opts)
        return self:toast("Offline - showing saved items", self.ui.TOAST_WARNING)
    end
    self:show("loading", {
        url = feed.url, as = "feed",
        onCancel = function() self:show(self.page and "page" or "home") end,
        onResult = function(r)
            if r.kind == "gemini" then
                self:applyFeed(feed, r)
            else
                self:log("error", r.status or "-", r.message)
                self:toast(r.message or "Refresh failed", self.ui.TOAST_ERROR)
            end
            self:showFeed(feed, opts)
        end,
    })
end

function App:showFeed(feed, opts)
    opts = opts or {}
    local lines = feeds.lines(feed, self.store:feedData(feed.id))
    local L = layout.build(lines, theme.cols(self.theme))
    local page = {
        url = feed.url, want = "feed", mode = "feed", title = feed.title, lines = lines, L = L,
        isFeedList = true, feedId = feed.id,
    }
    page.ps = pagestate.new(L, theme.rows(self.theme))
    if opts.restore then page.ps:restore(opts.restore.top, opts.restore.sel) end
    if opts.push ~= false and self.page then self:pushBack() end
    self.page = page
    self:log("feed", feed.id, "unread=" .. feed.unread)
    self:show("page")
end

-- F5 on the Feeds tab: refresh every feed, two requests at a time. Without
-- WiFi, or before the clock is set for TLS, it doesn't start: the loading
-- screen's waits would hold the Feeds tab.
function App:refreshAll()
    if self.refresh then return end
    local list = feeds.sorted(self.store:feedIndex())
    if #list == 0 then return self:toast("No feeds to refresh") end
    if self.pc.network.getStatus() ~= 1 then
        self:log("error", "-", "No WiFi")
        return self:toast("No WiFi - can't refresh feeds", self.ui.TOAST_WARNING)
    end
    if self.base and self.base.tls and not self.sys.getClock().synced then
        self:log("error", "-", "Clock not set")
        return self:toast("Clock not set yet - try again in a moment", self.ui.TOAST_WARNING)
    end
    self.refresh = { list = list, nextIndex = 1, active = 0, done = 0, ok = 0, failed = 0, handles = {} }
    self:pumpRefresh()
end

-- Counts one failed feed and keeps the first reason for the summary.
local function refreshFailed(self, R, status, message)
    message = message or "Request failed"
    self:log("error", status or "-", message)
    R.failed = R.failed + 1
    R.firstError = R.firstError or message
end

function App:pumpRefresh()
    local R = self.refresh
    if not R then return end
    while self.refresh == R and R.active < 2 and R.nextIndex <= #R.list do
        local feed = R.list[R.nextIndex]
        R.nextIndex = R.nextIndex + 1
        R.active = R.active + 1
        local handle, err = self:request(feed.url, "feed", function(r)
            if self.refresh ~= R then return end
            R.active, R.done = R.active - 1, R.done + 1
            if r.kind == "gemini" then
                -- Unsubscribed meanwhile: saving would recreate its file.
                if self:feedById(feed.id) then self:applyFeed(feed, r) end
                R.ok = R.ok + 1
            else
                refreshFailed(self, R, r.status, r.message) -- a "clock" result too
            end
            self:pumpRefresh()
        end)
        if handle then
            R.handles[#R.handles + 1] = handle
        else
            R.active, R.done = R.active - 1, R.done + 1
            refreshFailed(self, R, nil, err)
        end
    end
    if self.refresh == R and R.done >= #R.list then
        self.refresh = nil
        self:log("refresh", "done", "ok=" .. R.ok, "failed=" .. R.failed)
        if R.failed == 0 then
            self:toast("Feeds refreshed", self.ui.TOAST_SUCCESS)
        else
            self:toast(R.failed .. (R.failed == 1 and " feed" or " feeds") .. " failed to refresh: " .. R.firstError,
                self.ui.TOAST_WARNING)
        end
    end
    self.dirty = true
end

function App:cancelRefresh()
    local R = self.refresh
    if not R then return end
    self.refresh = nil
    for _, h in ipairs(R.handles) do h.cancel() end
    self:log("refresh", "cancelled")
end

function App:markAllRead()
    local p = self.page
    if not p or not p.isFeedList or self.screenName ~= "page" then return self:toast("Open a feed first") end
    local feed = self:feedById(p.feedId)
    if not feed then return end
    local data = self.store:feedData(feed.id)
    feeds.markAllRead(data)
    self.store:saveFeedData(feed.id, data)
    feeds.summarize(feed, data)
    self.store:saveFeedIndex()
    self:showFeed(feed, { push = false, restore = { top = p.ps.top, sel = p.ps.sel } })
end

return App
