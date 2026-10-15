-- In-memory stand-ins for picocalc.fs and picocalc.json (host tests).
local M = {}

-- Keeps the device semantics that matter: rename fails when the destination
-- exists; mkdir succeeds when the directory is already there.
function M.fs()
    local files, dirs = {}, {}
    local fs = {}
    function fs.mkdir(p) dirs[p] = true; return true end
    function fs.exists(p) return files[p] ~= nil or dirs[p] == true end
    function fs.readFile(p) return files[p] end
    function fs.delete(p)
        if files[p] == nil then return false, "delete failed" end
        files[p] = nil
        return true
    end
    function fs.rename(a, b)
        if files[a] == nil or files[b] ~= nil then return false, "rename failed" end
        files[b], files[a] = files[a], nil
        return true
    end
    function fs.open(p, mode)
        if mode ~= "w" then return nil, "cannot open file" end
        return { path = p, parts = {} }
    end
    function fs.write(h, s) h.parts[#h.parts + 1] = s; return #s end
    function fs.close(h) files[h.path] = table.concat(h.parts) end
    return fs, files
end

-- A json that keeps deep copies of values behind handle strings ("#3"), so tests
-- check what was saved without a JSON parser. Decoding anything else fails.
function M.json()
    local blobs = {}
    local function copy(v)
        if type(v) ~= "table" then return v end
        local t = {}
        for k, x in pairs(v) do t[k] = copy(x) end
        return t
    end
    local json = {}
    function json.encode(v)
        blobs[#blobs + 1] = copy(v)
        return "#" .. #blobs
    end
    function json.decode(s)
        local i = s:match("^#(%d+)$")
        local v = i and blobs[math.tointeger(tonumber(i))]
        if v == nil then return nil, "json.decode: invalid" end
        return copy(v)
    end
    return json
end

return M
