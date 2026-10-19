-- A fake `picocalc` for host tests of the app: records drawing, scripts input,
-- serves HTTP from a responder function, and keeps files in memory.
local fakes = require("tests.fakes")

local M = {}

local BTN = {
    UP = 1, DOWN = 2, LEFT = 4, RIGHT = 8, ENTER = 16, ESC = 32, MENU = 64,
    F1 = 128, F2 = 256, F3 = 512, F4 = 1024, F5 = 2048, F6 = 4096, F7 = 8192, F8 = 16384, F9 = 32768,
    BACKSPACE = 65536, TAB = 131072, DEL = 262144, SHIFT = 524288, CTRL = 1048576, ALT = 2097152, FN = 4194304,
}
local KEYCODE = {
    up = 0xB5, down = 0xB6, left = 0xB4, right = 0xB7, enter = 0x0A, esc = 0xB1, backspace = 0x08,
    tab = 0x09, del = 0xD4, f1 = 0x81, f2 = 0x82, f3 = 0x83, f4 = 0x84, f5 = 0x85,
}

function M.new()
    local F = {
        texts = {}, textFonts = {}, textXs = {}, logs = {}, toasts = {}, menu = {}, events = {}, inputs = {}, confirms = {},
        requests = {}, pending = {}, config = {}, conns = 0, made = {}, decoded = {}, scaled = {},
        rects = {}, imageDraws = {}, fontFiles = {}, missingFonts = {}, nextFontId = 4,
        netStatus = 1, synced = true, epoch = 1792000000, ms = 0,
    }
    local fs, files = fakes.fs()
    F.files = files
    F.responder = function() return 404, {}, "no responder" end

    function F.service()
        if F.tcpService and not F.tcpHolding then F.tcpService() end
        if F.holding then return end
        local pending = F.pending
        F.pending = {}
        for _, p in ipairs(pending) do
            local c = p.conn
            if not c.released then
                local status, headers, body = F.responder(p.path, p.headers)
                if status == nil then
                    c.err, c.released = headers or "connection failed", true
                    if c.cb.closed then c.cb.closed() end
                else
                    c.status, c.headers, c.body, c.pos = status, headers or {}, body or "", 1
                    if c.cb.req then c.cb.req() end
                    if c.cb.done then c.cb.done() end
                end
            end
        end
    end

    local display = {
        BLACK = 0, WHITE = 0xFFFF, GRAY = 0x8410, RED = 0xF800, GREEN = 0x07E0, BLUE = 0x001F,
        YELLOW = 0xFFE0, CYAN = 0x07FF,
        FONT_6X8 = 0, FONT_8X12 = 1, FONT_SCIENTIFICA = 2, FONT_SCIENTIFICA_BOLD = 3,
    }
    function display.rgb(r, g, b) return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3) end
    -- Fake advances: built-in fonts are fixed-width (6 px, 8 for 8x12); a
    -- loaded font is proportional: narrow characters 3 px, wide ones 9, the
    -- rest 6, and one wider each in a font whose file name has "-bold".
    local NARROW, WIDE = "il.,:;'!|", "mwMW"
    local function advance(id, c)
        if id == display.FONT_8X12 then return 8 end
        if id < 4 then return 6 end
        local a = NARROW:find(c, 1, true) and 3 or (WIDE:find(c, 1, true) and 9 or 6)
        if F.fontFiles[id]:find("-bold", 1, true) then a = a + 1 end
        return a
    end
    function F.textWidthIn(id, t)
        local w = 0
        for c in t:gmatch(".") do w = w + advance(id, c) end
        return w
    end
    function display.textWidth(t) return F.textWidthIn(F.font, t) end
    function display.loadFont(path)
        if F.missingFonts[path] then return nil, "cannot read file" end
        local id = F.nextFontId
        F.nextFontId = id + 1
        F.fontFiles[id] = path
        return id
    end
    function display.unloadFont(id)
        if F.font == id then F.font = display.FONT_6X8 end
        F.fontFiles[id] = nil
    end
    -- Every drawn string is recorded with the font current when it was drawn
    -- (F.textFonts parallels F.texts), as the firmware draws text, the header,
    -- footer, tabs and list items in the current font.
    F.font = display.FONT_6X8
    local function record(t)
        F.texts[#F.texts + 1] = t
        F.textFonts[#F.texts] = F.font
    end
    function display.clear() F.texts, F.textFonts, F.rects, F.imageDraws, F.textXs = {}, {}, {}, {}, {} end
    function display.setFont(id) F.font = id end
    function display.getFont() return F.font end
    function display.fillRect(x, y, w, h, c) F.rects[#F.rects + 1] = { x = x, y = y, w = w, h = h, c = c } end
    function display.drawText(x, _, t) record(t); F.textXs[#F.texts] = x; return display.textWidth(t) end
    -- The OS draws toasts and the system menu at a flush in the current font.
    function display.flush() F.frames = (F.frames or 0) + 1; F.flushFont = F.font; F.service() end

    local ui = { TOAST_INFO = 0, TOAST_SUCCESS = 1, TOAST_WARNING = 2, TOAST_ERROR = 3 }
    function ui.drawHeader(t) record("[H] " .. t); return 21 end
    function ui.drawFooter(l, r) record("[F] " .. (l or "") .. " | " .. (r or "")) end
    function ui.drawTabs(_, tabs, active)
        for i, t in ipairs(tabs) do record((i == active and "[T*] " or "[T] ") .. t) end
        return active, 21
    end
    function ui.drawListItem(_, _, _, text, selected) record((selected and "[>] " or "[ ] ") .. text) end
    function ui.drawSpinner() end
    function ui.textInput(prompt) F.lastPrompt = prompt; return table.remove(F.inputs, 1) or nil end
    function ui.confirm(msg)
        F.lastConfirm = msg
        local v = table.remove(F.confirms, 1)
        if v == nil then return true end
        return v
    end
    function ui.toast(text) F.toasts[#F.toasts + 1] = text end

    local input = {}
    for name, v in pairs(BTN) do input["BTN_" .. name] = v end
    function input.update() F.service() end
    function input.pollEvent() return table.remove(F.events, 1) end
    function input.clearState() end

    local sys = {}
    function sys.log(m) F.logs[#F.logs + 1] = m end
    function sys.getTimeMs() return F.ms end
    function sys.getClock() return { synced = F.synced, epoch = F.synced and F.epoch or 0, hour = 0, min = 0, sec = 0 } end
    function sys.sleep(ms) F.ms = F.ms + ms; F.service() end
    function sys.addMenuItem(label, fn) F.menu[label] = fn end

    local network = { kStatusNotConnected = 0, kStatusConnected = 1, kStatusNotAvailable = 2, http = {} }
    function network.getStatus() return F.netStatus end
    function network.http.new(host, port, tls)
        if F.poolFull then return nil, "HTTP connection pool full or out of memory" end
        F.conns = F.conns + 1
        -- c.cb holds the three callbacks (req, done, closed); setting nil clears one.
        local c = { host = host, port = port, tls = tls, cb = {}, released = false }
        F.made[#F.made + 1] = c
        function c:setKeepAlive(v) self.keep = v end
        function c:setConnectTimeout() end
        function c:setReadTimeout() end
        function c:setReadBufferSize() return true end
        function c:setRequestCallback(fn) self.cb.req = fn end
        function c:setRequestCompleteCallback(fn) self.cb.done = fn end
        function c:setConnectionClosedCallback(fn) self.cb.closed = fn end
        function c:get(path, headers)
            if self.released then error("http: connection is closed") end
            F.requests[#F.requests + 1] = { path = path, headers = headers }
            F.pending[#F.pending + 1] = { conn = self, path = path, headers = headers }
            return true
        end
        function c:getBytesAvailable() return self.body and (#self.body - self.pos + 1) or 0 end
        function c:read(n)
            if not self.body or self.pos > #self.body then return nil end
            local s = self.body:sub(self.pos, self.pos + (n or 131072) - 1)
            self.pos = self.pos + #s
            return s
        end
        function c:getResponseStatus() return self.status end
        function c:getResponseHeaders() return self.headers end
        function c:getError() return self.err end
        function c:close() self.released = true end
        return c
    end

    -- picocalc.tcp. F.tcpServers["host:port"] = server: server.fp is the
    -- certificate fingerprint a TLS socket reports, server.connectErr fails
    -- the connect with that error, and server.reply(request, conn) returns
    -- the bytes to send before closing, or {chunks = {...}, err = "...",
    -- hang = true}. A socket to no server fails with a connect timeout.
    -- Callbacks run in F.service, as the firmware runs them in its service
    -- pass. F.tcpOldFirmware: sockets have no peerFingerprint method.
    -- F.tcpFull: tcp.new returns nil.
    F.tcpServers, F.tcpMade, F.tcpQueue = {}, {}, {}
    local tcp = {}
    function tcp.new(host, port, tls)
        if F.tcpFull then return nil, "TCP connection pool full or out of memory" end
        local c = { host = host, port = port, tls = tls or false, cb = {}, buf = "", pos = 1, state = "idle", writes = {} }
        F.tcpMade[#F.tcpMade + 1] = c
        local function open()
            if c.state == "released" then error("tcp: connection is closed") end
        end
        function c:setInsecure(v) open(); self.insecure = v end
        function c:setConnectTimeout(s) self.connectTimeout = s end
        function c:setReadTimeout(s) self.readTimeout = s end
        function c:setConnectCallback(fn) self.cb.connect = fn end
        function c:setReadCallback(fn) self.cb.read = fn end
        function c:setCloseCallback(fn) self.cb.close = fn end
        function c:connect()
            open()
            if F.netStatus ~= 1 then return false, "WiFi not available" end
            self.state = "connecting"
            F.tcpQueue[#F.tcpQueue + 1] = { conn = self, step = "connect" }
            return true
        end
        function c:write(data)
            open()
            if self.state ~= "connected" then return -1 end
            self.writes[#self.writes + 1] = data
            F.tcpQueue[#F.tcpQueue + 1] = { conn = self, step = "reply" }
            return #data
        end
        function c:read(n)
            open()
            if self.pos > #self.buf then return nil end
            local s = self.buf:sub(self.pos, self.pos + (n or 4096) - 1)
            self.pos = self.pos + #s
            return s
        end
        function c:available() return #self.buf - self.pos + 1 end
        function c:error() return self.err end
        function c:isConnected() return self.state == "connected" end
        if not F.tcpOldFirmware then
            function c:peerFingerprint()
                if self.tls and (self.state == "connected" or self.state == "closed") then return self.fp end
                return nil
            end
        end
        function c:close() self.state = "released" end
        return c
    end
    local function fire(c, name)
        if c.state ~= "released" and c.cb[name] then c.cb[name](c) end
    end
    -- Runs until nothing is queued: one pass delivers a whole exchange.
    function F.tcpService()
        while #F.tcpQueue > 0 do
            local item = table.remove(F.tcpQueue, 1)
            local c = item.conn
            local server = F.tcpServers[c.host .. ":" .. c.port]
            if c.state == "released" then
                -- closed by the app meanwhile
            elseif item.step == "connect" then
                if not server or server.connectErr then
                    c.err = server and server.connectErr or "connect timeout (20000ms)"
                    c.state = "failed"
                    fire(c, "close")
                else
                    c.state, c.fp = "connected", server.fp
                    fire(c, "connect")
                end
            else
                local r = server.reply(table.concat(c.writes), c)
                if type(r) == "string" then r = { chunks = { r } } end
                for _, chunk in ipairs(r.chunks or {}) do
                    c.buf = c.buf .. chunk
                    fire(c, "read")
                end
                if not r.hang and c.state ~= "released" then
                    c.err = r.err
                    c.state = r.err and "failed" or "closed"
                    fire(c, "close")
                end
            end
        end
    end

    local config = {}
    function config.get(k, d)
        local v = F.config[k]
        if v == nil then return d end
        return v
    end
    function config.set(k, v)
        if v == nil or v == "" then F.config[k] = nil else F.config[k] = v end
    end
    function config.save() return true end

    local graphics = { image = {} }
    function graphics.image.loadFromBuffer(data)
        if data:sub(1, 4) ~= "JPEG" then error("JPEG decoding failed") end
        -- "JPEG:<w>x<h>" decodes to that size; any other JPEG body to 200x120.
        local w, h = data:match("^JPEG:(%d+)x(%d+)")
        w, h = math.tointeger(tonumber(w)) or 200, math.tointeger(tonumber(h)) or 120
        F.decoded[#F.decoded + 1] = data
        local img = {}
        function img:getSize() return w, h end
        function img:draw(x, y, _, src)
            F.imageDraws[#F.imageDraws + 1] = { data = data, x = x, y = y, src = src }
        end
        return img
    end

    -- getInfo and loadScaled read a file the app wrote, "JPEG:<w>x<h>...".
    -- F.failScaled makes loadScaled raise, as out of memory.
    function graphics.image.getInfo(path)
        local w, h = (F.files[path] or ""):match("^JPEG:(%d+)x(%d+)")
        if not w then error("not a recognized image") end
        return { width = math.tointeger(tonumber(w)), height = math.tointeger(tonumber(h)), format = "jpeg" }
    end
    function graphics.image.loadScaled(path, w, h)
        if F.failScaled then error("out of memory") end
        F.scaled[#F.scaled + 1] = { path = path, w = w, h = h }
        local img = {}
        function img:getSize() return w, h end
        function img:draw(x, y) F.imageDraws[#F.imageDraws + 1] = { data = "scaled", x = x, y = y } end
        return img
    end

    F.pc = {
        display = display, ui = ui, input = input, sys = sys, network = network,
        fs = fs, json = fakes.json(), config = config, graphics = graphics, tcp = tcp,
    }

    function F.press(name, mods)
        local button = name:upper()
        F.events[#F.events + 1] = { type = "down", key = KEYCODE[name], button = BTN[button], mods = mods or 0 }
    end
    function F.type(chars)
        for c in chars:gmatch(".") do
            F.events[#F.events + 1] = { type = "char", key = c:byte(), char = c, mods = 0 }
        end
    end
    function F.screenText() return table.concat(F.texts, "\n") end
    local function has(list, text)
        for _, v in ipairs(list) do
            if v:find(text, 1, true) then return true end
        end
        return false
    end
    function F.hasLog(text) return has(F.logs, text) end
    function F.hasToast(text) return has(F.toasts, text) end
    -- The font the first drawn string containing `text` was drawn in, or nil.
    function F.fontOf(text)
        for i, v in ipairs(F.texts) do
            if v:find(text, 1, true) then return F.textFonts[i] end
        end
        return nil
    end
    return F
end

-- A responder that behaves like the PicoSurf proxy for the given routes.
function M.proxy(routes, token)
    local plain = { ["content-type"] = "text/plain; charset=us-ascii" }
    return function(path, headers)
        if (headers or {}).Authorization ~= "Bearer " .. (token or "tok") then
            return 401, plain, "Missing or wrong token\n"
        end
        if path:find("/v1/ping", 1, true) then return 200, plain, "picosurf-proxy 1\n" end
        local enc = path:match("[?&]url=([^&]*)")
        local target = enc and (enc:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) or ""
        local as = path:match("[?&]as=([^&]*)") or "reader"
        local r = routes[target .. "|" .. as] or routes[target]
        if not r then
            return 502, { ["content-type"] = plain["content-type"], ["x-upstream-status"] = "404" }, "Site returned 404 Not Found\n"
        end
        local h = { ["content-type"] = r.type or "text/gemini; charset=us-ascii", ["x-final-url"] = r.final or target }
        if r.mode ~= false then h["x-mode"] = r.mode or as end
        if r.title then h["x-title"] = r.title end
        if r.feed then h["x-feed-url"] = r.feed end
        if r.truncated then h["x-truncated"] = "1" end
        return r.status or 200, h, r.body
    end
end

return M
