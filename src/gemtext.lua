-- Gemtext into typed lines (spec 6.1-6.3). Pure.
--   {t = "text"|"h1"|"h2"|"h3"|"item"|"quote"|"pre"|"blank"|"link", text = string}
-- Links also carry url, n (the number of a "[n] label", or nil) and image
-- (true when the label starts "[IMG]").
local M = {}

local function eachLine(body)
    if body:sub(-1) ~= "\n" then body = body .. "\n" end
    return body:gmatch("([^\n]*)\n")
end

-- Fonts draw a box for tabs and control bytes.
local function clean(raw)
    return (raw:gsub("\r$", ""):gsub("\t", "    "))
end

function M.line(raw)
    if raw:sub(1, 2) == "=>" then
        local u, label = raw:match("^=>%s*(%S+)%s*(.-)%s*$")
        if u then
            local num = label:match("^%[(%d+)%]")
            return {
                t = "link", url = u, text = label ~= "" and label or u,
                n = num and math.tointeger(tonumber(num)) or nil,
                image = label:sub(1, 5) == "[IMG]",
            }
        end
        return { t = "text", text = raw }
    end
    local hashes, rest = raw:match("^(#+)%s*(.-)%s*$")
    if hashes then return { t = "h" .. math.min(#hashes, 3), text = rest } end
    if raw:sub(1, 2) == "* " then return { t = "item", text = raw:sub(3) } end
    if raw:sub(1, 1) == ">" then return { t = "quote", text = (raw:sub(2):gsub("^ ", "")) } end
    if raw:match("^%s*$") then return { t = "blank", text = "" } end
    return { t = "text", text = raw }
end

function M.parse(body)
    local lines, pre = {}, false
    for raw in eachLine(body) do
        raw = clean(raw)
        if raw:sub(1, 3) == "```" then
            pre = not pre
        elseif pre then
            lines[#lines + 1] = { t = "pre", text = raw }
        else
            lines[#lines + 1] = M.line(raw)
        end
    end
    return lines
end

function M.fromPlain(body)
    local lines = {}
    for raw in eachLine(body) do
        raw = clean(raw)
        lines[#lines + 1] = raw:match("^%s*$") and { t = "blank", text = "" } or { t = "text", text = raw }
    end
    return lines
end

function M.title(lines)
    for _, l in ipairs(lines) do
        if l.t == "h1" then return l.text end
    end
    return nil
end

-- The link lines of a proxy feed list: "=> url YYYY-MM-DD title" or "=> url title".
function M.feedItems(lines)
    local items = {}
    for _, l in ipairs(lines) do
        if l.t == "link" then
            local date, title = l.text:match("^(%d%d%d%d%-%d%d%-%d%d)%s+(.*)$")
            items[#items + 1] = { url = l.url, date = date, title = date and title or l.text }
        end
    end
    return items
end

return M
