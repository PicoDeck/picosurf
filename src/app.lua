-- The app: config, screens, the main loop, proxy requests and navigation (spec 6).
local url = require("src.url")
local proxy = require("src.proxy")
local http = require("src.http")
local gemtext = require("src.gemtext")
local layout = require("src.layout")
local pagestate = require("src.pagestate")
local store = require("src.store")
local keys = require("src.keys")
local fonts = require("src.fonts")
local theme = require("src.theme")
local feeds = require("src.feeds")
local inline = require("src.inline")
local native = require("src.native")
local tofu = require("src.tofu")
local gopher = require("src.gopher")

local App = {}
App.__index = App
App.MAX_BACK, App.MAX_CACHE = 20, 3
App.NO_PROXY = "Web pages need a proxy - set one in Settings"
App.PROMPT_MAX = 48 -- a Gemini input prompt, cut to ui.textInput's width

-- A copy of a page's inline box heights, for a Back entry or Reload (inline images spec 5.6).
local function copyBoxes(b)
    if not b then return nil end
    local c = {}
    for k, v in pairs(b) do c[k] = v end
    return c
end

local SCREENS = { "home", "page", "image", "settings", "loading", "message", "cert" }

-- pc: the picocalc API (a fake in host tests); appId: app.json's id.
function App.new(pc, appId, appDir)
    local self = setmetatable({ pc = pc, appDir = appDir or "/apps/picosurf" }, App)
    self.disp, self.ui, self.input, self.sys = pc.display, pc.ui, pc.input, pc.sys
    self.store = store.new(pc.fs, pc.json, "/data/" .. appId)
    self.pins = tofu.new(self.store)
    self.decode = keys.decoder(pc.input)
    self.screens = {}
    for _, name in ipairs(SCREENS) do self.screens[name] = require("src.screens." .. name) end
    self.back, self.cache, self.inbox = {}, {}, {}
    self.dirty = true
    self:loadConfig()
    return self
end

-- Returns whether the font in use changed (see loadFont).
function App:loadConfig()
    local c = self.pc.config
    self.cfg = {
        proxyUrl = c.get("proxy_url") or "", token = c.get("token") or "", font = fonts.normalize(c.get("font")),
        images = c.get("images") == "inline" and "inline" or "links",
    }
    local fontChanged = self:loadFont()
    self.oldProxyWarned = nil -- a changed setting, say a newer proxy: pictures are tried again
    self:cancelRefresh() -- before closeAll, which would fail its requests
    if self.pool then self.pool:closeAll() end
    self.pool, self.base, self.baseErr = nil, nil, nil
    if self.cfg.proxyUrl ~= "" then
        self.base, self.baseErr = url.parseBase(self.cfg.proxyUrl)
        if self.base then self.pool = http.pool(self.pc.network, self.base) end
    end
    return fontChanged
end

-- The reading font (proportional fonts spec 3, 4): loaded again when the
-- setting changed, or when the last load fell back to Scientifica. Returns
-- whether the font in use changed: a fallen-back font can load on any saved
-- setting's retry, not just the Font row's.
function App:loadFont()
    local want, old = self.cfg.font, self.fontSpec
    if old and old.name == want then return false end
    if old then fonts.unload(self.disp, old) end
    -- fonts.load raises only out of memory, with the old font already gone:
    -- then Scientifica, built in, which loads no files.
    local ok, spec, err = pcall(fonts.load, self.disp, self.appDir, want)
    if not ok then spec, err = fonts.load(self.disp, self.appDir, "scientifica"), spec end
    self.fontSpec = spec
    self.theme = theme.new(self.disp, spec)
    self:log("font", spec.name)
    if err then
        self:log("error", "-", err)
        self:toast("Font unavailable - using Scientifica", self.ui.TOAST_WARNING)
    end
    return not old or old.name ~= spec.name
end

-- Saves a setting and applies it; when that changed the font, the page on
-- screen is laid out again in it.
function App:saveConfig(key, value)
    self.pc.config.set(key, value)
    self.pc.config.save()
    if self:loadConfig() then self:relayout() end
end

-- Settings -> Images (inline images spec 5.6): saves the choice and applies it
-- to the page on screen. Off, the page is laid out again with link lines, and
-- a full collection frees the dropped pictures' pixels (see decodeInline).
function App:setImages(mode)
    self:saveConfig("images", mode)
    local p = self.page
    if not p or p.isFeedList then return end
    if mode == "inline" then
        p.inline = p.inline or inline.new()
    elseif p.inline then
        self:cancelInline(p)
        p.inline = nil
        self:relayout()
        collectgarbage()
    end
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
        -- Screens draw in the system font; only page text switches to the
        -- reading font. Back to the system font before the flush, as the
        -- toasts, text boxes and system menu use whatever font is current.
        self.disp.setFont(self.theme.ui)
        self.screen.draw(self)
        self.disp.setFont(self.theme.ui)
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
    self.pins:flush(self.sys.getTimeMs())
    local notes = self.store.notes
    while #notes > 0 do self:toast(table.remove(notes, 1), self.ui.TOAST_WARNING) end
end

-- What native.get needs from the app. The pins are loaded here, in the
-- main loop, so the check inside the firmware's callbacks reads no file.
function App:nativeEnv()
    self.pins:hosts()
    return {
        tcp = self.pc.tcp, pins = self.pins, now = function() return self:now() end,
        post = function(fn) self.inbox[#self.inbox + 1] = { done = fn } end,
        log = function(...) self:log(...) end,
    }
end

-- Starts a request by the target's scheme (small web spec 2.1): Gemini and
-- Gopher natively, http(s) through the proxy. done(result) runs from the
-- main loop. fit: "WxH" for an inline picture (nil for pages and full-screen
-- images). Returns a handle {cancel(), received()}, or nil and a reason.
function App:request(target, as, done, fit)
    local scheme = url.scheme(target)
    if scheme == "gemini" or scheme == "gopher" then
        local outer = {}
        outer.cur = native.get(self:nativeEnv(), target, as, function(r)
            if r.kind ~= "redirect" then return done(r) end
            -- A Gemini redirect to another scheme goes through this dispatch.
            local h, err = self:request(r.url, as, done, fit)
            if not h then return done({ kind = "error", message = err }) end
            outer.cur = h
        end)
        return {
            cancel = function() outer.cur.cancel() end,
            received = function() return outer.cur.received() end,
        }
    end
    if scheme ~= "http" and scheme ~= "https" then
        return nil, (scheme or "That") .. ":// links aren't supported yet"
    end
    if not self.pool then return nil, self.baseErr or App.NO_PROXY end
    local handle, err = self.pool:get(proxy.getPath(self.base, target, as, fit), proxy.headers(self.cfg.token),
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
    if r.kind == "input" then return self:askInput(r, opts) end
    if r.kind == "certchanged" then
        return self:show("cert", { change = r, retry = function() self:open(target, opts) end })
    end
    if r.kind == "gemini" or r.kind == "text" then
        local finalUrl = r.finalUrl or target
        local page, err = self:buildPage(finalUrl, mode, r, opts.restore)
        if not page then return self:fail(err) end
        if opts.back then table.remove(self.back) end
        if opts.push ~= false and self.page then self:pushBack() end
        self:cancelInline(self.page)
        self.page = page
        self:cachePut(finalUrl, mode, r)
        if not opts.back then self.store:addHistory(finalUrl, page.title) end
        self:log("loaded", finalUrl, "mode=" .. page.mode, "links=" .. #page.L.links, "rows=" .. page.L.count)
        if r.truncated then self:toast("Page truncated by the proxy", self.ui.TOAST_WARNING) end
        return self:show("page")
    end
    if r.kind == "image" then
        local where = r.finalUrl or target
        if r.native then
            local img, err = self:loadNativeImage(r.body)
            if not img then
                self:log("error", "-", err .. " " .. where)
                return self:fail(err)
            end
            if opts.back then table.remove(self.back) end
            return self:show("image", { url = where, image = img })
        end
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

-- A server asked for text (small web spec 5): back to the screen the load
-- started from, ask, and open the URL again with the answer.
function App:askInput(r, opts)
    self:show(self.page and "page" or "home")
    local prompt = r.prompt ~= "" and r.prompt or "Input:"
    self:log("prompt", "input")
    local text = self.ui.textInput(prompt:sub(1, App.PROMPT_MAX))
    self.input.clearState()
    self.dirty = true
    if not text then return end
    self:open(url.withInput(r.url, text), opts)
end

-- The certificate review's Enter (small web spec 6): trust the new
-- certificate and load the page again.
function App:acceptCert(change, retry)
    self.pins:accept(change.host, change.port, change.new, self:now())
    self.pins:flush(self.sys.getTimeMs())
    self:log("cert", "accepted", change.host .. ":" .. change.port)
    retry()
end

-- A full-size picture from Gemini or Gopher (small web spec 9.7), through a
-- temporary file so a large one loads scaled to fit 320x320. Returns the
-- image, or nil and the reason.
function App:loadNativeImage(body)
    local fs, g = self.pc.fs, self.pc.graphics.image
    local path = self.store:path("image.tmp")
    local f = fs.open(path, "w")
    if not f then return nil, "Could not decode the image" end
    fs.write(f, body)
    fs.close(f)
    local okInfo, info = pcall(g.getInfo, path)
    local w, h = okInfo and info and info.width, okInfo and info and info.height
    local ok, img = false, nil
    if w and h and w > 0 and h > 0 then
        if w <= 320 and h <= 320 then
            ok, img = pcall(g.loadFromBuffer, body)
        elseif w >= h then
            ok, img = pcall(g.loadScaled, path, 320, math.max(1, h * 320 // w))
        else
            ok, img = pcall(g.loadScaled, path, math.max(1, w * 320 // h), 320)
        end
    end
    fs.delete(path)
    if ok and img then return img end
    if w and h then return nil, "Image too large to show (" .. w .. "x" .. h .. ")" end
    return nil, "Could not decode the image"
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

-- The first row of source line `li` (or of the first line after it).
local function firstRowOf(L, li)
    local lo, hi = 1, L.count
    while lo < hi do
        local mid = (lo + hi) // 2
        if L.line[mid] < li then lo = mid + 1 else hi = mid end
    end
    return lo
end

-- The top row of a page laid out again: source line `line` at the top, unless
-- longer rows pushed selected link `sel` below the screen of `visible` rows,
-- when it scrolls just far enough to show it.
local function relaidTop(L, line, sel, visible)
    local top = line and firstRowOf(L, line) or 1
    local link = sel and L.links[sel]
    if link and link.first > top + visible - 1 then
        top = math.min(link.first, link.last - visible + 1)
    end
    return top
end

-- The top row to restore: the saved row, unless those rows were counted in
-- another layout (another font, or picture boxes now gone), when the saved
-- source line goes back to the top instead, keeping the selected link on
-- screen (proportional fonts spec 5.3).
local function restoreTop(L, restore, fontName, boxesGone, visible)
    local relaid = restore.font ~= fontName or boxesGone
    if relaid and restore.line then return relaidTop(L, restore.line, restore.sel, visible) end
    return restore.top
end

-- Parses and lays out a page. With Images set to Inline, a page restored by
-- Back or Reload gets its boxes back, so the saved scroll position points at
-- the same content (inline images spec 5.6). With Images now Links, or after
-- a font change, the saved rows were counted in another layout: the saved
-- source line goes back to the top instead.
function App:buildPage(finalUrl, mode, r, restore)
    local boxes = self.cfg.images == "inline" and restore and copyBoxes(restore.boxes) or nil
    local lines, L = self:withMemoryRetry(function()
        local lines = r.kind == "text" and gemtext.fromPlain(r.body) or gemtext.parse(r.body)
        return lines, layout.build(lines, theme.metrics(self.theme), boxes)
    end)
    if not lines then return nil, L end
    local page = {
        url = finalUrl, want = mode, mode = r.mode or (r.kind == "text" and "full" or mode),
        title = r.title or gemtext.title(lines) or url.host(finalUrl), feedUrl = r.feedUrl, lines = lines, L = L,
    }
    page.ps = pagestate.new(L, theme.rows(self.theme))
    if restore then
        local top = restoreTop(L, restore, self.theme.fontName, restore.boxes and not boxes, page.ps.visible)
        page.ps:restore(top, restore.sel)
    end
    if self.cfg.images == "inline" then page.inline = inline.new(boxes) end
    return page
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
    local L, err = self:withMemoryRetry(function()
        return layout.build(p.lines, theme.metrics(self.theme), p.inline and p.inline.boxes)
    end)
    if not L then
        self.page, self.back = nil, {}
        return self:fail(err)
    end
    p.L = L
    p.ps = pagestate.new(L, theme.rows(self.theme))
    p.ps:restore(relaidTop(L, line, sel, p.ps.visible), sel)
end

-- Whether a picture can be fetched now: a proxy, WiFi, and for TLS a set clock.
-- Not after a proxy older than fit was found, until the settings change.
function App:canFetchImages()
    if self.oldProxyWarned then return false end
    if not self.pool or self.pc.network.getStatus() ~= 1 then return false end
    return not (self.base.tls and not self.sys.getClock().synced)
end

-- Inline pictures, each step on the page screen (inline images spec 5.2): drop
-- the decoded pictures that left the window, decode one, and start the next
-- fetch. A pass runs only when something may have changed: the view moved, a
-- picture arrived or was decoded, or the retry time passed.
function App:stepImages()
    local p = self.page
    local st = p and p.inline
    if not st then return end
    local ps, now = p.ps, self.sys.getTimeMs()
    if ps.top ~= st.seenTop then st.seenTop, st.wake = ps.top, true end
    if st.retryAt and now - st.retryAt >= 0 then st.retryAt, st.wake = nil, true end
    if not st.wake then return end
    st.wake = false
    local L = p.L
    local order = inline.order(L, ps)
    for _, u in ipairs(st:drops(L, order)) do st:drop(u) end
    -- The budget is one decode per step (inline images spec 6).
    if st.decodedOnArrival then
        st.decodedOnArrival = nil -- this step's one decode was the arrival's
        st.wake = true -- decode the next one next step
    else
        local k = st:nextDecode(L, order)
        if k then
            self:decodeInline(p, L.links[k].url)
            st.wake = true
        end
    end
    if st.inflight or st.retryAt then return end
    local fk, u = st:nextFetch(L, order)
    if not fk then return end
    if not self:canFetchImages() then
        st.retryAt = now + inline.RETRY_MS
        return
    end
    self:fetchInline(p, u)
    st.wake = true -- the next picture, or the pool was busy: look again next step
end

function App:fetchInline(p, u)
    local st = p.inline
    local req = { url = u }
    req.handle = self:request(u, nil, function(r) self:inlineArrived(p, req, r) end, inline.FIT)
    if not req.handle then return end -- the pool is busy
    st.byUrl[u] = { state = "loading" }
    st.inflight = req
    self:log("inline", "fetch", u)
end

-- A picture's response, from pump. Ignored when its page or request has gone.
function App:inlineArrived(p, req, r)
    local st = p.inline
    if self.page ~= p or not st or st.inflight ~= req then return end
    st.inflight, st.wake = nil, true
    local u = req.url
    if r.kind == "clock" then
        st.byUrl[u] = nil
        st.retryAt = self.sys.getTimeMs() + inline.RETRY_MS
        return
    end
    if r.kind ~= "image" then
        st.byUrl[u].state = "failed"
        return self:log("inline", "failed", u, r.status or "-", r.message or r.kind)
    end
    st.byUrl[u].state = "ready"
    st:keepBytes(u, r.body)
    self:decodeInline(p, u)
    st.decodedOnArrival = true
end

-- Decodes u's bytes and lays every image link to u out as a box of its
-- picture's rows, keeping the view on the same content (inline images 5.3).
function App:decodeInline(p, u)
    local st = p.inline
    local ok, img = pcall(self.pc.graphics.image.loadFromBuffer, st.byUrl[u].bytes)
    if not ok or not img then
        st:fail(u)
        return self:log("inline", "failed", u, "decode", tostring(img))
    end
    local w, h = img:getSize()
    if w > inline.FIT_W or h > inline.FIT_H then
        -- A proxy older than fit sent a 320x320 picture.
        st:fail(u)
        self:log("inline", "failed", u, "larger than " .. inline.FIT)
        if not self.oldProxyWarned then
            self.oldProxyWarned = true
            self:toast("Inline images need a newer proxy", self.ui.TOAST_WARNING)
        end
        return
    end
    -- The pixels (2 bytes each) live outside the Lua heap, freed only by the
    -- picture's finaliser: tell the collector about them as if Lua had
    -- allocated them, so dropped pictures are collected while scrolling.
    collectgarbage("step", (w * h * 2) // 1024)
    local e = st.byUrl[u]
    e.img, e.w, e.h = img, w, h
    st:touch(u)
    local rows = inline.rows(h, self.theme.rowH)
    for k, link in ipairs(p.L.links) do
        if link.image and link.url == u then
            if p.L.style[link.first] ~= layout.BOX or link.last - link.first + 1 ~= rows then
                p.ps:shift(link.first, layout.setBox(p.L, k, rows))
            end
            st.boxes[k] = h -- heights, so a font with other rows recomputes them
            self:log("inline", k, "w=" .. w, "h=" .. h, "rows=" .. rows)
        end
    end
    self.dirty = true
end

-- Cancels page p's picture in flight and forgets it, so it is fetched again
-- when the page is back on screen.
function App:cancelInline(p)
    local st = p and p.inline
    if not st then return end
    st.wake = true
    local req = st.inflight
    if not req then return end
    st.inflight = nil
    st.byUrl[req.url] = nil
    req.handle.cancel()
    self:log("inline", "cancelled", req.url)
end

-- The message screen titled "Error", or "Error <status>" for a proxy status.
function App:fail(message, retry, status)
    local title = status and ("Error " .. (math.tointeger(status) or status)) or "Error"
    self:show("message", { title = title, text = message or "Something went wrong", retry = retry })
end

function App:goHome()
    self:cancelInline(self.page)
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
    if p.mode == "native" then return self:toast("Reader mode is for web pages") end
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
-- push (false replaces the current page instead of stacking it), restore ({top, sel, boxes, line}),
-- back (set by goBack: the Back entry is removed only when the load succeeds).
function App:open(target, opts)
    opts = opts or {}
    local scheme = url.scheme(target)
    local web = scheme == "http" or scheme == "https"
    if not web and scheme ~= "gemini" and scheme ~= "gopher" then
        return self:toast((scheme or "That") .. ":// links aren't supported yet", self.ui.TOAST_WARNING)
    end
    if web and not self.pool then return self:toast(self.baseErr or App.NO_PROXY, self.ui.TOAST_WARNING) end
    local blocked = scheme == "gopher" and gopher.blocked(target)
    if blocked then return self:toast(blocked, self.ui.TOAST_WARNING) end
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
        boxes = p.inline and copyBoxes(p.inline.boxes) or nil, line = p.L.line[p.ps.top], font = self.theme.fontName,
    }
    while #self.back > App.MAX_BACK do table.remove(self.back, 1) end
end

function App:goBack()
    local e = self.back[#self.back]
    if not e then return self:goHome() end
    local restore = { top = e.top, sel = e.sel, boxes = e.boxes, line = e.line, font = e.font }
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
    self:open(p.url, { mode = p.want, push = false, restore = {
        top = p.ps.top, sel = p.ps.sel, boxes = p.inline and copyBoxes(p.inline.boxes) or nil,
        line = p.L.line[p.ps.top], font = self.theme.fontName,
    } })
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
    local L = layout.build(lines, theme.metrics(self.theme))
    local page = {
        url = feed.url, want = "feed", mode = "feed", title = feed.title or feed.url, lines = lines, L = L,
        isFeedList = true, feedId = feed.id,
    }
    page.ps = pagestate.new(L, theme.rows(self.theme))
    if opts.restore then
        page.ps:restore(restoreTop(L, opts.restore, self.theme.fontName, false, page.ps.visible), opts.restore.sel)
    end
    if opts.push ~= false and self.page then self:pushBack() end
    self:cancelInline(self.page)
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
