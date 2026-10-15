-- Feed bookkeeping (spec 6.7). Pure: works on the tables store.lua loads and saves.
local M = {}
M.MAX_FEEDS, M.MAX_ITEMS, M.STALE_SECONDS = 50, 50, 1800

function M.subscribe(index, u, title)
    for _, f in ipairs(index.feeds) do
        if f.url == u then return f, false end
    end
    if #index.feeds >= M.MAX_FEEDS then return nil, "Feed limit reached (" .. M.MAX_FEEDS .. ")" end
    local f = { id = index.next_id, url = u, title = title or u, fetched_at = 0, unread = 0, newest = "" }
    index.next_id = index.next_id + 1
    index.feeds[#index.feeds + 1] = f
    return f, true
end

function M.unsubscribe(index, id)
    for i, f in ipairs(index.feeds) do
        if f.id == id then
            table.remove(index.feeds, i)
            return true
        end
    end
    return false
end

local function seenSet(data)
    local set = {}
    for _, u in ipairs(data.seen) do set[u] = true end
    return set
end

function M.unreadCount(data)
    local set, n = seenSet(data), 0
    for _, it in ipairs(data.items) do
        if not set[it.url] then n = n + 1 end
    end
    return n
end

-- Replaces the items with the freshly fetched ones and forgets read marks for
-- items no longer listed, so `seen` never grows past MAX_ITEMS.
function M.merge(data, items)
    local kept, present = {}, {}
    for i = 1, math.min(#items, M.MAX_ITEMS) do
        local it = items[i]
        kept[i] = { url = it.url, date = it.date or "", title = it.title }
        present[it.url] = true
    end
    local seen = {}
    for _, u in ipairs(data.seen) do
        if present[u] then seen[#seen + 1] = u end
    end
    data.items, data.seen = kept, seen
    return data
end

function M.summarize(feed, data, now)
    feed.unread = M.unreadCount(data)
    local newest = ""
    for _, it in ipairs(data.items) do
        local date = it.date or ""
        if date > newest then newest = date end
    end
    feed.newest = newest
    if now then feed.fetched_at = now end
end

function M.markRead(data, u)
    for _, s in ipairs(data.seen) do
        if s == u then return false end
    end
    for _, it in ipairs(data.items) do
        if it.url == u then
            data.seen[#data.seen + 1] = u
            return true
        end
    end
    return false
end

function M.markAllRead(data)
    local seen = {}
    for i, it in ipairs(data.items) do seen[i] = it.url end
    data.seen = seen
end

-- A feed never fetched is stale. Without the clock (now = 0) nothing else is,
-- so opening a feed offline shows what is stored.
function M.isStale(feed, now)
    local at = feed.fetched_at or 0
    if at <= 0 then return true end
    if not now or now <= 0 then return false end
    return now - at >= M.STALE_SECONDS
end

function M.sorted(index)
    local list = {}
    for i, f in ipairs(index.feeds) do list[i] = f end
    table.sort(list, function(a, b)
        local an, bn = a.newest or "", b.newest or ""
        if an ~= bn then return an > bn end
        return (a.title or ""):lower() < (b.title or ""):lower()
    end)
    return list
end

function M.lines(feed, data)
    local set = seenSet(data)
    local lines = { { t = "h1", text = feed.title or feed.url or "" }, { t = "blank", text = "" } }
    if #data.items == 0 then
        lines[#lines + 1] = { t = "text", text = "No articles yet. F5 on the Feeds tab refreshes." }
    end
    for _, it in ipairs(data.items) do
        local read = set[it.url] == true
        local date = it.date or ""
        local label = (read and "  " or "* ") .. (date ~= "" and (date .. " ") or "") .. (it.title or "")
        lines[#lines + 1] = { t = "link", url = it.url, text = label, dim = read }
    end
    return lines
end

return M
