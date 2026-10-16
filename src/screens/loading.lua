-- Loading: waits for WiFi and the clock, runs one proxy request and shows its
-- progress; Esc cancels (spec 6.2, 6.9).
local url = require("src.url")
local theme = require("src.theme")

local S = {}
local RETRY_MS = 3000

function S.enter(app, args)
    app.loading = {
        url = args.url, as = args.as, onResult = args.onResult, onCancel = args.onCancel,
        state = "start", frame = 0, nextFrame = app.sys.getTimeMs(),
    }
end

local function begin(app, L)
    local status = app.pc.network.getStatus()
    if status == 2 then
        app.loading = nil
        return L.onResult({ kind = "error", message = "WiFi not available" })
    end
    if status ~= 1 then
        L.state = "wifi"
        return
    end
    if app.base and app.base.tls and not app.sys.getClock().synced then
        L.state, L.retryAt = "clock", app.sys.getTimeMs() + RETRY_MS
        return
    end
    local handle, err = app:request(L.url, L.as, function(r)
        if app.loading ~= L then return end -- cancelled
        if r.kind == "clock" then
            L.state, L.retryAt, L.handle = "clock", app.sys.getTimeMs() + RETRY_MS, nil
            return
        end
        app.loading = nil
        L.onResult(r)
    end)
    if not handle then
        app.loading = nil
        return L.onResult({ kind = "error", message = err or "Request failed" })
    end
    L.state, L.handle = "fetching", handle
end

function S.update(app)
    local L = app.loading
    if not L then return end
    local now = app.sys.getTimeMs()
    if L.state == "start" then
        begin(app, L)
    elseif L.state == "wifi" and app.pc.network.getStatus() ~= 0 then
        L.state = "start"
    elseif L.state == "clock" and now - L.retryAt >= 0 then
        L.state = "start"
    end
    if now - L.nextFrame >= 0 then
        L.frame, L.nextFrame = L.frame + 1, now + 150
        app.dirty = true
    end
end

function S.draw(app)
    local L, th, d = app.loading, app.theme, app.disp
    app.ui.drawHeader("PicoSurf")
    local msg, sub = "Loading", ""
    if L then
        msg = "Loading " .. url.host(L.url)
        if L.state == "wifi" then
            msg = "Connecting to WiFi..."
        elseif L.state == "clock" then
            msg = "Waiting for time sync..."
        elseif L.handle and L.handle.received then
            local bytes = L.handle.received()
            if bytes > 0 then sub = (bytes // 1024) .. " KB" end
        end
        app.ui.drawSpinner(160, 120, 10, L.frame)
    end
    d.drawText(th.margin, 150, msg:sub(1, theme.uiCols(th)), th.fg, false)
    d.drawText(th.margin, 166, sub, th.dim, false)
    app.ui.drawFooter("Esc cancel", "")
end

-- Only Esc cancels (spec 6.2): Backspace is Back elsewhere, easy to press twice.
function S.key(app, action)
    if action ~= "esc" then return end
    local L = app.loading
    if not L then return end
    local waitingWifi = L.state == "wifi"
    app:cancelLoad()
    if waitingWifi then return app:goHome() end -- spec 6.9
    L.onCancel()
end

return S
