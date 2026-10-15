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
        texts = {}, logs = {}, toasts = {}, menu = {}, events = {}, inputs = {}, confirms = {},
        requests = {}, pending = {}, config = {}, conns = 0,
        netStatus = 1, synced = true, epoch = 1792000000, ms = 0,
    }
    local fs, files = fakes.fs()
    F.files = files
    F.responder = function() return 404, {}, "no responder" end

    function F.service()
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
    function display.clear() F.texts = {} end
    function display.setFont() end
    function display.fillRect() end
    function display.drawText(_, _, t) F.texts[#F.texts + 1] = t; return #t * 6 end
    function display.flush() F.frames = (F.frames or 0) + 1; F.service() end

    local ui = { TOAST_INFO = 0, TOAST_SUCCESS = 1, TOAST_WARNING = 2, TOAST_ERROR = 3 }
    function ui.drawHeader(t) F.texts[#F.texts + 1] = "[H] " .. t; return 21 end
    function ui.drawFooter(l, r) F.texts[#F.texts + 1] = "[F] " .. (l or "") .. " | " .. (r or "") end
    function ui.drawTabs(_, tabs, active)
        for i, t in ipairs(tabs) do F.texts[#F.texts + 1] = (i == active and "[T*] " or "[T] ") .. t end
        return active, 21
    end
    function ui.drawListItem(_, _, _, text, selected) F.texts[#F.texts + 1] = (selected and "[>] " or "[ ] ") .. text end
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
        local c = { host = host, port = port, tls = tls, cb = {}, released = false }
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
        local img = {}
        function img:getSize() return 200, 120 end
        function img:draw() end
        return img
    end

    F.pc = {
        display = display, ui = ui, input = input, sys = sys, network = network,
        fs = fs, json = fakes.json(), config = config, graphics = graphics,
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
