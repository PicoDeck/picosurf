-- The Gopher protocol (small web spec 7): URLs, the request, and menus and
-- text files as gemtext. Pure.
local fold = require("src.fold")
local textflow = require("src.textflow")

local M = {}
M.PORT, M.TITLE_MAX = 70, 60

local LINKS = { ["0"] = "", ["1"] = "", ["7"] = "[?] ", g = "[IMG] ", I = "[IMG] ", p = "[IMG] ",
    ["9"] = "[BIN] ", ["5"] = "[BIN] ", s = "[BIN] ", d = "[BIN] ", ["8"] = "[TEL] ", T = "[TEL] " }
local IMAGES = { g = true, I = true, p = true }
local BINARY = { ["9"] = true, ["5"] = true, s = true, d = true }
local TELNET = { ["8"] = true, T = true }

local function decode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- Selector bytes outside unreserved ASCII and "/" percent-encoded.
local function encode(s)
    return (s:gsub("[^%w%-%._~/]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- {host, port, type, selector, search, url} for a gopher:// URL, or nil and
-- a reason. selector and search are decoded; search is nil when absent.
function M.parse(target)
    local host, port, path = target:match("^[Gg][Oo][Pp][Hh][Ee][Rr]://([^/:]+):?(%d*)(.*)$")
    if not host then return nil, "Not a Gopher URL" end
    port = port ~= "" and math.tointeger(tonumber(port)) or M.PORT
    if port < 1 or port > 65535 then return nil, "Not a Gopher URL" end
    local itemType, selector = "1", ""
    if #path > 1 then itemType, selector = path:sub(2, 2), decode(path:sub(3)) end
    local search
    local tab = selector:find("\t", 1, true)
    if tab then selector, search = selector:sub(1, tab - 1), selector:sub(tab + 1) end
    return { host = host:lower(), port = port, type = itemType, selector = selector, search = search, url = target }
end

function M.request(req)
    return req.selector .. (req.search and ("\t" .. req.search) or "") .. "\r\n"
end

-- A gopher:// URL for a menu item.
function M.url(host, port, itemType, selector)
    return "gopher://" .. host .. (port ~= M.PORT and (":" .. port) or "") .. "/" .. itemType .. encode(selector)
end

-- The toast for a link PicoSurf won't request (binary files, telnet), or nil.
function M.blocked(target)
    local req = M.parse(target)
    if not req then return nil end
    if BINARY[req.type] then return "Can't open binary files" end
    if TELNET[req.type] then return "Telnet isn't supported" end
    return nil
end

-- Whether opening target first needs search terms: a type 7 URL without one.
function M.needsSearch(target)
    local req = M.parse(target)
    return req ~= nil and req.type == "7" and req.search == nil
end

local function lines(text)
    local out = {}
    if text:sub(-1) ~= "\n" then text = text .. "\n" end
    for l in text:gmatch("([^\n]*)\n") do out[#out + 1] = (l:gsub("\r$", "")) end
    return out
end

local function split(s)
    local f = {}
    for v in (s .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = v end
    return f
end

-- A text line gemtext reads as text (as textflow does for plain text).
local function textLine(l)
    if l:find("^=>") or l:find("^#") or l:find("^>") or l:find("^```") then return " " .. l end
    return l
end

-- A menu (the server's bytes) as gemtext: info lines in preformatted blocks,
-- items as links labelled by kind (small web spec 7). Only the text shown is
-- decoded, so a Latin-1 selector goes back to the server as it came.
function M.menu(text)
    local out, art = {}, {}
    local function flushArt()
        if #art == 0 then return end
        out[#out + 1] = "```"
        for _, l in ipairs(art) do out[#out + 1] = l end
        out[#out + 1] = "```"
        art = {}
    end
    for _, line in ipairs(lines(text)) do
        if line == "." then break end
        local t = line:sub(1, 1)
        local f = split(line:sub(2))
        local display = fold.line(fold.decode(f[1] or ""))
        if t == "i" then
            art[#art + 1] = display:find("^```") and (" " .. display) or display
        elseif line ~= "" and not line:find("\t", 1, true) then
            flushArt()
            out[#out + 1] = textLine(fold.line(fold.decode(line)))
        elseif line ~= "" then
            flushArt()
            local selector, host, port = f[2], f[3], math.tointeger(tonumber(f[4] or ""))
            local web = t == "h" and selector and selector:match("^/?URL:(.+)$")
            if web then
                local u = fold.url(web)
                out[#out + 1] = "=> " .. u .. " " .. (display ~= "" and display or u)
            elseif LINKS[t] and selector and host and host ~= "" and port then
                local u = fold.url(M.url(host:lower(), port, t, selector))
                out[#out + 1] = "=> " .. u .. " " .. LINKS[t] .. (display ~= "" and display or u)
            else
                out[#out + 1] = textLine(display)
            end
        end
    end
    flushArt()
    return table.concat(out, "\n") .. "\n"
end

-- The reply `data` to `req` as a result: gemini (finalUrl, title, mode
-- "native"), image (native) or error.
function M.interpret(req, data, as)
    if as == "feed" then return { kind = "error", message = "Feeds aren't supported for Gopher" } end
    if data == "" then return { kind = "error", message = "Empty response from " .. req.host } end
    local sel = req.selector
    if sel ~= "" and sel:sub(1, 1) ~= "/" then sel = "/" .. sel end
    local title = fold.line(fold.decode(req.host .. sel)):sub(1, M.TITLE_MAX)
    local r = { kind = "gemini", finalUrl = req.url, title = title, mode = "native" }
    if req.type == "1" or req.type == "7" then
        r.body = M.menu(data)
    elseif req.type == "0" or req.type == "h" then
        local text = fold.decode(data):gsub("\r?\n%.%s*$", "\n")
        r.body = textflow.convert(text)
    elseif IMAGES[req.type] then
        return { kind = "image", body = data, native = true, finalUrl = req.url }
    else
        return { kind = "error", message = "Can't open this kind of Gopher item" }
    end
    return r
end

return M
