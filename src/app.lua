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
-- show one after another. step keeps flushing until the last has expired.
App.TOAST_MS = 3000

function App:toast(text, style)
    self.ui.toast(text, style or self.ui.TOAST_INFO)
    self.dirty = true
    local now = self.sys.getTimeMs()
    local base = self.toastUntil
    if not base or now - base > 0 then base = now end
    self.toastUntil = base + App.TOAST_MS
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
    self.screenName = name
    self.screen = self.screens[name]
    self.dirty = true
    self:log("screen", name)
    if self.screen.enter then self.screen.enter(self, args or {}) end
end

function App:addMenuItems()
    self.sys.addMenuItem("Reload", function() self:reload() end)
    self.sys.addMenuItem("Edit URL", function() self:editUrl() end)
    self.sys.addMenuItem("Settings", function() self:show("settings", { from = self.screenName }) end)
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
    if self.toastUntil then
        local now = self.sys.getTimeMs()
        if now - self.nextToastDraw >= 0 then
            self.dirty = true
            self.nextToastDraw = now + 250
            if now - self.toastUntil >= 0 then self.toastUntil, self.nextToastDraw = nil, nil end
        end
    end
    if self.dirty then
        self.dirty = false
        self.disp.clear(self.theme.bg)
        self.screen.draw(self)
        self.disp.flush()
    end
end

function App:run()
    self:start()
    while not self.quit do
        self:step()
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

-- Opens a URL in the page view. opts: mode ("reader"|"full"|"feed"),
-- push (false replaces the current page instead of stacking it), restore ({top, sel}).
function App:open(target, opts)
    opts = opts or {}
    local scheme = url.scheme(target)
    if scheme ~= "http" and scheme ~= "https" then
        return self:toast((scheme or "That") .. ":// links aren't supported yet", self.ui.TOAST_WARNING)
    end
    local mode = opts.mode or "reader"
    local cached = self:cacheGet(target, mode)
    if cached then return self:showResult(target, mode, cached, opts) end
    self:show("loading", {
        url = target, as = mode,
        onResult = function(r) self:showResult(target, mode, r, opts) end,
        onCancel = function() self:show(self.page and "page" or "home") end,
    })
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
    self:fail(r.message, function() self:open(target, opts) end)
end

-- Parses and lays out a page; on a memory error drops the cache and tries once more.
function App:buildPage(finalUrl, mode, r, restore)
    local cols = theme.cols(self.theme)
    local function parse()
        local lines = r.kind == "text" and gemtext.fromPlain(r.body) or gemtext.parse(r.body)
        return lines, layout.build(lines, cols)
    end
    local ok, lines, L = pcall(parse)
    if not ok then
        self:log("layout-error", lines)
        self.cache = {}
        collectgarbage()
        ok, lines, L = pcall(parse)
        if not ok then return nil, "Page too large for memory" end
    end
    local page = {
        url = finalUrl, want = mode, mode = r.mode or (r.kind == "text" and "full" or mode),
        title = r.title or gemtext.title(lines) or url.host(finalUrl), feedUrl = r.feedUrl, lines = lines, L = L,
    }
    page.ps = pagestate.new(L, theme.rows(self.theme))
    if restore then page.ps:restore(restore.top, restore.sel) end
    return page
end

-- After a font change: lay the current page out again for the new width.
function App:relayout()
    local p = self.page
    if not p then return end
    p.L = layout.build(p.lines, theme.cols(self.theme))
    p.ps = pagestate.new(p.L, theme.rows(self.theme))
end

function App:fail(message, retry)
    self:show("message", { title = "Error", text = message or "Something went wrong", retry = retry })
end

function App:pushBack()
    local p = self.page
    self.back[#self.back + 1] = { url = p.url, want = p.want, top = p.ps.top, sel = p.ps.sel }
    while #self.back > App.MAX_BACK do table.remove(self.back, 1) end
end

function App:goBack()
    local e = self.back[#self.back]
    if not e then return self:goHome() end
    self:open(e.url, { mode = e.want, push = false, back = true, restore = { top = e.top, sel = e.sel } })
end

function App:goHome()
    self.page, self.back = nil, {}
    self:show("home")
end

function App:followLink(link)
    self:log("follow", link.url)
    self:open(link.url)
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

function App:reload()
    local p = self.page
    if not p or self.screenName ~= "page" then return self:toast("Nothing to reload") end
    self:cacheDrop(p.url, p.want)
    self:open(p.url, { mode = p.want, push = false, restore = { top = p.ps.top, sel = p.ps.sel } })
end

function App:editUrl()
    local p = self.page
    if not p or self.screenName ~= "page" then return self:promptGo() end
    if #p.url > 127 then return self:toast("URL too long to edit", self.ui.TOAST_WARNING) end
    self:promptGo(p.url)
end

return App
