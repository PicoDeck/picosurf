-- URL helpers: what the user typed, schemes and hosts, query encoding, and the
-- proxy's base URL (spec 6.1). Pure.
local M = {}

function M.encode(s)
    return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

function M.scheme(u)
    local s = u:match("^(%a[%w+.%-]*):")
    return s and s:lower() or nil
end

function M.host(u)
    return u:match("^%a[%w+.%-]*://([^/?#:]+)") or u
end

-- What the user typed in Go, as a URL, or nil and a reason (small web spec
-- 9.2). opts.proxy: a proxy is set, so a bare host means https:// rather
-- than gemini://. opts.search: the search URL ("" for none); text that is not
-- a URL or a host is searched for: %s in it replaced by the query, else the
-- query after "%09" (gopher://) or "?".
function M.normalize(text, opts)
    opts = opts or {}
    local t = text:match("^%s*(.-)%s*$")
    if t == "" then return nil, "Type a URL" end
    if t:find("://", 1, true) then return t end
    if not t:find("%s") and t:find(".", 1, true) then return (opts.proxy and "https://" or "gemini://") .. t end
    local s = opts.search or ""
    if s == "" then return nil, "Not a URL" end
    local q = M.encode(t)
    if s:find("%s", 1, true) then return (s:gsub("%%s", function() return q end)) end
    if M.scheme(s) == "gopher" then return s .. "%09" .. q end
    return s .. "?" .. q
end

-- The proxy's base URL: {host, port, tls, prefix} or nil and a reason.
-- prefix is the path the proxy is served under, without a trailing slash.
function M.parseBase(base)
    local scheme, rest = base:match("^%s*(%a+)://(.-)%s*$")
    scheme = scheme and scheme:lower()
    if scheme ~= "http" and scheme ~= "https" then
        return nil, "Proxy URL must start with https:// or http://"
    end
    local hostport, path = rest:match("^([^/]*)(.*)$")
    -- The port follows the last colon; a colon inside [...] is not one.
    local host, port = hostport:match("^(.*):([^:%]]*)$")
    host = host or hostport
    if host == "" then return nil, "Proxy URL has no host" end
    if port then
        port = port:match("^%d+$") and math.tointeger(tonumber(port))
        if not port or port < 1 or port > 65535 then return nil, "Proxy URL has a bad port" end
    else
        port = scheme == "https" and 443 or 80
    end
    return { host = host, port = port, tls = scheme == "https", prefix = (path:gsub("/+$", "")) }
end

-- RFC 3986 appendix B: scheme (lower case), authority, path, query and
-- fragment of a URL or relative reference. Absent parts are nil; path is
-- always a string.
local function split(u)
    local scheme, rest = u:match("^(%a[%w+.%-]*):(.*)$")
    if not scheme then rest = u end
    local fragment, query, authority
    local a, f = rest:match("^([^#]*)#(.*)$")
    if a then rest, fragment = a, f end
    a, f = rest:match("^([^?]*)%?(.*)$")
    if a then rest, query = a, f end
    local path = rest
    if rest:sub(1, 2) == "//" then authority, path = rest:match("^//([^/]*)(.*)$") end
    return { scheme = scheme and scheme:lower(), authority = authority, path = path, query = query, fragment = fragment }
end

-- RFC 3986 5.2.4.
local function removeDots(input)
    local out = {}
    while input ~= "" do
        if input:sub(1, 3) == "../" then
            input = input:sub(4)
        elseif input:sub(1, 2) == "./" then
            input = input:sub(3)
        elseif input:sub(1, 3) == "/./" then
            input = input:sub(3)
        elseif input == "/." then
            input = "/"
        elseif input:sub(1, 4) == "/../" then
            input = input:sub(4)
            table.remove(out)
        elseif input == "/.." then
            input = "/"
            table.remove(out)
        elseif input == "." or input == ".." then
            input = ""
        else
            local seg = input:match("^/?[^/]*")
            out[#out + 1] = seg
            input = input:sub(#seg + 1)
        end
    end
    return table.concat(out)
end

-- The parts of an absolute URL with an authority, plus host (lower case,
-- without user info) and port (an integer, or nil when absent); nil otherwise.
function M.parts(u)
    local p = split(u)
    if not p.scheme or not p.authority then return nil end
    local auth = p.authority:gsub("^.*@", "")
    local host, port = auth:match("^(.-):(%d*)$")
    p.host = (host or auth):lower()
    p.port = port and port ~= "" and math.tointeger(tonumber(port)) or nil
    return p
end

-- ref resolved against the absolute URL base (RFC 3986 5.2), or nil when base
-- has no scheme.
function M.resolve(base, ref)
    local B, R = split(base), split(ref)
    if not B.scheme then return nil end
    local t = { scheme = B.scheme, authority = B.authority, fragment = R.fragment }
    if R.scheme then
        t.scheme, t.authority, t.path, t.query = R.scheme, R.authority, removeDots(R.path), R.query
    elseif R.authority then
        t.authority, t.path, t.query = R.authority, removeDots(R.path), R.query
    elseif R.path == "" then
        t.path, t.query = B.path, R.query or B.query
    else
        if R.path:sub(1, 1) == "/" then
            t.path = removeDots(R.path)
        elseif B.authority and B.path == "" then
            t.path = removeDots("/" .. R.path)
        else
            t.path = removeDots((B.path:match("^(.*/)") or "") .. R.path)
        end
        t.query = R.query
    end
    return t.scheme .. ":" .. (t.authority and ("//" .. t.authority) or "") .. t.path
        .. (t.query and ("?" .. t.query) or "") .. (t.fragment and ("#" .. t.fragment) or "")
end

-- u asking again with the text a server asked for (small web spec 5): a
-- Gemini URL's query replaced, a Gopher URL's search (after %09) replaced.
function M.withInput(u, text)
    local q = M.encode(text)
    if M.scheme(u) == "gopher" then return (u:gsub("%%09.*$", "")) .. "%09" .. q end
    local base = u:gsub("#.*$", ""):gsub("%?.*$", "")
    return base .. "?" .. q
end

return M
