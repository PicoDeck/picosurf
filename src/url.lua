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

-- What the user typed, as a URL, or nil and a reason. No scheme means https.
function M.normalize(text)
    local t = text:match("^%s*(.-)%s*$")
    if t == "" then return nil, "Type a URL" end
    if t:find("%s") then return nil, "Not a URL (search isn't supported yet)" end
    if not t:find("://", 1, true) then t = "https://" .. t end
    return t
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
    local host, port = hostport:match("^(.-):(%d+)$")
    host = host or hostport
    if host == "" then return nil, "Proxy URL has no host" end
    if port then
        port = math.tointeger(tonumber(port))
        if not port or port < 1 or port > 65535 then return nil, "Proxy URL has a bad port" end
    else
        port = scheme == "https" and 443 or 80
    end
    return { host = host, port = port, tls = scheme == "https", prefix = (path:gsub("/+$", "")) }
end

return M
