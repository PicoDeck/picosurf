-- The Gemini protocol (small web spec 4): request lines, response headers,
-- and responses as the app's results. Pure.
local url = require("src.url")
local fold = require("src.fold")
local textflow = require("src.textflow")

local M = {}
M.PORT, M.MAX_URL, M.MAX_HEADER = 1965, 1024, 1029

local IMAGES = { ["image/jpeg"] = true, ["image/png"] = true, ["image/gif"] = true, ["image/bmp"] = true }

local function fail(message)
    return { kind = "error", message = message }
end

-- The request for target: {host, port, url, line}, or nil and a reason.
-- The host is lower-cased, an empty path becomes "/", the default port and
-- any fragment are dropped.
function M.request(target)
    local p = url.parts(target)
    if not p or p.scheme ~= "gemini" or p.host == "" then return nil, "Not a Gemini URL" end
    local port = p.port or M.PORT
    if port < 1 or port > 65535 then return nil, "Not a Gemini URL" end
    local u = "gemini://" .. p.host .. (port ~= M.PORT and (":" .. port) or "")
        .. (p.path ~= "" and p.path or "/") .. (p.query and ("?" .. p.query) or "")
    if #u > M.MAX_URL then return nil, "URL too long for Gemini" end
    return { host = p.host, port = port, url = u, line = u .. "\r\n" }
end

-- status (integer), meta and the body, or nil for a malformed header.
function M.header(data)
    local nl = data:find("\n", 1, true)
    if not nl or nl > M.MAX_HEADER then return nil end
    local line = data:sub(1, nl - 1):gsub("\r$", "")
    local status, rest = line:match("^(%d%d)(.*)$")
    if not status or (rest ~= "" and rest:sub(1, 1) ~= " ") then return nil end
    return math.tointeger(tonumber(status)), rest:sub(2), data:sub(nl + 1)
end

-- "text/gemini; charset=UTF-8" -> "text/gemini", "utf-8".
local function mediaType(meta)
    local mime = (meta:match("^%s*([^;%s]+)") or ""):lower()
    local charset = meta:lower():match("charset%s*=%s*\"?([%w%-_]+)")
    return mime, charset
end

local function eachLine(text)
    if text:sub(-1) ~= "\n" then text = text .. "\n" end
    return text:gmatch("([^\n]*)\n")
end

local function linkParts(line)
    return line:match("^=>%s*(%S+)%s*(.-)%s*$")
end

-- Gemtext with every link absolute and requestable and the text folded
-- (small web spec 8.3). Lines inside preformatted blocks are only folded.
function M.rewrite(text, base)
    local out, pre = {}, false
    for raw in eachLine(text) do
        local line = fold.line(raw)
        if line:sub(1, 3) == "```" then
            pre = not pre
        elseif not pre and raw:sub(1, 2) == "=>" then
            local u, label = linkParts(raw)
            if u then
                local abs = fold.url(url.resolve(base, u) or u)
                label = fold.line(label)
                line = "=> " .. abs .. " " .. (label ~= "" and label or abs)
            end
        end
        out[#out + 1] = line
    end
    return table.concat(out, "\n") .. "\n"
end

-- The first level-1 heading of folded gemtext, outside preformatted blocks,
-- or nil.
local function firstHeading(text)
    local pre = false
    for line in eachLine(text) do
        if line:sub(1, 3) == "```" then
            pre = not pre
        elseif not pre and line:sub(1, 1) == "#" and line:sub(2, 2) ~= "#" then
            local h = line:match("^#%s*(.-)%s*$")
            if h ~= "" then return h end
        end
    end
    return nil
end

-- A gemlog as the feed list the proxy sends for web feeds (small web spec
-- 9.6): only links labelled with a date, absolute, "=> url date title".
-- Returns the list and the page's first heading, or nil when no link has a
-- date.
function M.feed(text, base)
    local page = M.rewrite(text, base)
    local out, pre = {}, false
    for line in eachLine(page) do
        if line:sub(1, 3) == "```" then
            pre = not pre
        elseif not pre and line:sub(1, 2) == "=>" then
            local u, label = linkParts(line)
            local date, title = (label or ""):match("^(%d%d%d%d%-%d%d%-%d%d) (.*)$")
            if date then
                title = title:gsub("^%s*[%-:]+%s*", "")
                out[#out + 1] = "=> " .. u .. " " .. date .. " " .. (title ~= "" and title or date)
            end
        end
    end
    if #out == 0 then return nil end
    return table.concat(out, "\n") .. "\n", firstHeading(page)
end

-- The response `data` to request `req` as a result (small web spec 4):
-- gemini (with finalUrl, title, mode "native"), image (native), input,
-- redirect ({url}) or error. as: "feed" for the gemlog list.
function M.interpret(req, data, as)
    local status, meta, body = M.header(data)
    if not status then return fail("Not a Gemini response") end
    local class = status // 10
    if class == 1 then return { kind = "input", prompt = fold.line(meta), sensitive = status == 11, url = req.url } end
    if class == 3 then
        local to = url.resolve(req.url, meta)
        if not to or meta == "" then return fail("Not a Gemini response") end
        return { kind = "redirect", url = fold.url(to) }
    end
    if class == 4 then
        if status == 44 then return fail("Server asks to wait " .. fold.line(meta) .. " s") end
        return fail((meta ~= "" and fold.line(meta) or "Temporary failure") .. " (" .. status .. ")")
    end
    if class == 5 then
        if status == 51 then return fail("Not found") end
        return fail((meta ~= "" and fold.line(meta) or "Permanent failure") .. " (" .. status .. ")")
    end
    if class == 6 then return fail("This page needs a client certificate, which PicoSurf doesn't support") end
    if class ~= 2 then return fail("Not a Gemini response") end
    local mime, charset = mediaType(meta)
    if mime == "" then mime = "text/gemini" end
    local r = { kind = "gemini", finalUrl = req.url, mode = "native" }
    if mime == "text/gemini" then
        local text = fold.decode(body, charset)
        if as == "feed" then
            local list, title = M.feed(text, req.url)
            if not list then return fail("No dated posts here - not a gemlog") end
            r.body, r.title = list, title
            return r
        end
        r.body = M.rewrite(text, req.url)
        return r
    end
    if as == "feed" then return fail("No dated posts here - not a gemlog") end
    if mime:sub(1, 5) == "text/" then
        r.body, r.title = textflow.convert(fold.decode(body, charset)), req.host
        return r
    end
    if IMAGES[mime] then return { kind = "image", body = body, native = true, finalUrl = req.url } end
    return fail("Can't show " .. fold.line(mime) .. " files")
end

return M
