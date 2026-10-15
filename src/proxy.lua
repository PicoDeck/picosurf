-- The PicoSurf proxy protocol on the device side (spec 5.1-5.3, 6.1). Pure:
-- request paths and headers, and what a response means.
local url = require("src.url")

local M = {}

function M.getPath(base, target, as)
    local p = base.prefix .. "/v1/get?url=" .. url.encode(target)
    if as then p = p .. "&as=" .. as end
    return p
end

function M.pingPath(base)
    return base.prefix .. "/v1/ping"
end

function M.headers(token)
    return { Authorization = "Bearer " .. token }
end

local function firstLine(s)
    return ((s or ""):match("^%s*([^\r\n]*)") or ""):sub(1, 120)
end

local KINDS = { ["text/gemini"] = "gemini", ["text/plain"] = "text", ["image/jpeg"] = "image" }

-- The media type alone: no parameters, lower case.
local function mimeOf(headers)
    return ((headers["content-type"] or ""):match("^%s*([^;%s]+)") or ""):lower()
end

-- Any server that is not a PicoSurf proxy. The status is an integer: "404", never "404.0".
local function notProxy(status)
    return "That URL is not a PicoSurf proxy (HTTP " .. tostring(math.tointeger(status) or status) .. ")"
end

-- ok, status, bodyOrError, headers: as delivered by an http.lua callback.
function M.interpret(ok, status, body, headers)
    if not ok then
        local msg = body or "Request failed"
        if msg:find("clock not set", 1, true) then return { kind = "clock", message = "Waiting for time sync..." } end
        if msg:find("timeout", 1, true) then return { kind = "error", message = "Proxy did not respond" } end
        return { kind = "error", message = msg }
    end
    headers = headers or {}
    local mime = mimeOf(headers)
    if status == 200 then
        local kind = KINDS[mime]
        if not kind then
            return { kind = "error", status = status, message = "Unexpected response: " .. (mime ~= "" and mime or "no type") }
        end
        return {
            kind = kind, body = body, finalUrl = headers["x-final-url"], title = headers["x-title"],
            mode = headers["x-mode"], feedUrl = headers["x-feed-url"], truncated = headers["x-truncated"] == "1",
        }
    end
    -- The proxy's errors are a status plus a one-line text/plain reason. Anything else
    -- is not the proxy speaking (a site's HTML error page, say), so its markup is never shown.
    if mime == "text/plain" then
        if status == 401 then
            return { kind = "error", status = 401, message = "Proxy rejected the token - check Settings" }
        end
        local line = firstLine(body)
        if line ~= "" then return { kind = "error", status = status, message = line } end
    end
    return { kind = "error", status = status, message = notProxy(status) }
end

function M.interpretPing(ok, status, body, headers)
    if ok and status == 200 then
        if (body or ""):find("^picosurf%-proxy") then return { ok = true } end
        return { ok = false, message = notProxy(status) }
    end
    return { ok = false, message = M.interpret(ok, status, body, headers).message }
end

return M
