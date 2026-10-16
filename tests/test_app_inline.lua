local T = require("tests.t")
local fakepc = require("tests.fakepc")
local App = require("src.app")
local layout = require("src.layout")

local function lines(from, to)
    local out = {}
    for i = from, to do out[#out + 1] = "line " .. i end
    return table.concat(out, "\n")
end

-- Rows at 52 columns: 1 title, 2 intro, 3 picture one, 4-33 text, 34 picture
-- two, 35-64 text, 65 picture three. 21 rows show, so at the top the window
-- (rows -20 to 42) holds pictures one and two.
local PICS = table.concat({
    "# Pics", "intro", "=> https://img.test/1.jpg [IMG] one", lines(1, 30),
    "=> https://img.test/2.jpg [IMG] two", lines(31, 60), "=> https://img.test/3.jpg [IMG] three",
}, "\n")

local function gallery()
    local parts = { "# Gallery" }
    for i = 1, 40 do parts[#parts + 1] = "=> https://img.test/g" .. i .. ".jpg [IMG] picture " .. i end
    return table.concat(parts, "\n")
end

local function jpeg(w, h)
    return { type = "image/jpeg", mode = false, body = "JPEG:" .. w .. "x" .. h }
end

local ROUTES = {
    ["https://pics.test/"] = { title = "Pics", body = PICS },
    ["https://img.test/1.jpg"] = jpeg(200, 100), -- 8 rows
    ["https://img.test/2.jpg"] = jpeg(312, 126), -- 10 rows
    ["https://img.test/3.jpg"] = jpeg(100, 50), -- 5 rows
    ["https://b.test/"] = { title = "B", body = "# B\n\nBack page.\n" },
    ["https://fail.test/"] = {
        title = "F",
        body = "# F\n=> https://img.test/missing.jpg [IMG] gone\n=> https://img.test/bad.jpg [IMG] broken\n"
            .. "=> gemini://g.test/x.jpg [IMG] elsewhere\n",
    },
    ["https://img.test/bad.jpg"] = { type = "image/jpeg", mode = false, body = "nope" },
    ["https://twice.test/"] = {
        title = "T", body = "# T\n=> https://img.test/1.jpg [IMG] one\ntext\n=> https://img.test/1.jpg [IMG] one again\n",
    },
    ["https://old.test/"] = {
        title = "O", body = "# O\n=> https://img.test/big1.jpg [IMG] one\n=> https://img.test/big2.jpg [IMG] two\n",
    },
    ["https://img.test/big1.jpg"] = jpeg(320, 240),
    ["https://img.test/big2.jpg"] = jpeg(320, 240),
    ["https://gallery.test/"] = { title = "Gallery", body = gallery() },
}
for i = 1, 40 do ROUTES["https://img.test/g" .. i .. ".jpg"] = jpeg(200, 100) end

local function boot(opts)
    opts = opts or {}
    local F = fakepc.new()
    F.config.proxy_url, F.config.token = "https://p.test", "tok"
    F.config.images, F.config.font = opts.images, opts.font or "scientifica"
    F.responder = fakepc.proxy(ROUTES, "tok")
    local app = App.new(F.pc, "net.picodeck.picosurf")
    app:start()
    app:step()
    return app, F
end

local function steps(app, n)
    for _ = 1, n or 3 do app:step() end
end

local function go(app, F, text)
    F.inputs[#F.inputs + 1] = text
    F.press("f1")
    steps(app)
end

-- Opens a page, holding every response after the page's own: the first
-- picture's request is left waiting.
local function openHolding(app, F, text)
    F.inputs[#F.inputs + 1] = text
    F.press("f1")
    app:step()
    F.holding = true
    app:step()
end

-- The paths of the picture requests so far, in order.
local function pictureRequests(F)
    local out = {}
    for _, r in ipairs(F.requests) do
        if r.path:find("&fit=", 1, true) then out[#out + 1] = r.path end
    end
    return out
end

-- Link k's rows when it is laid out as a box, else 0.
local function boxRows(app, k)
    local L = app.page.L
    local link = L.links[k]
    if L.style[link.first] ~= layout.BOX then return 0 end
    return link.last - link.first + 1
end

local function decodedNow(app)
    local n = 0
    for _, e in pairs(app.page.inline.byUrl) do
        if e.img then n = n + 1 end
    end
    return n
end

local function hasText(F, text)
    for _, t in ipairs(F.texts) do
        if t == text then return true end
    end
    return false
end

-- The last frame's draw of the picture whose fake bytes are `data`.
local function drawOf(F, data)
    for _, d in ipairs(F.imageDraws) do
        if d.data == data then return d end
    end
    return nil
end

local function hasRect(F, x, y, w, h)
    for _, r in ipairs(F.rects) do
        if r.x == x and r.y == y and r.w == w and r.h == h then return true end
    end
    return false
end

-- Settings, then the Images row (the fourth): switches it; Esc back to the page.
local function toggleImages(app, F)
    F.menu["Settings"](); steps(app, 1)
    F.press("down"); F.press("down"); F.press("down"); F.press("enter"); steps(app, 1)
end

-- Runs fn with the global collectgarbage recording its calls (and still
-- collecting): returns the calls, each a list of its arguments. The global is
-- put back even when fn fails.
local function gcCalls(fn)
    local real, calls = collectgarbage, {}
    collectgarbage = function(...)
        calls[#calls + 1] = { ... }
        return real(...)
    end
    local ok, err = pcall(fn)
    collectgarbage = real
    if not ok then error(err, 0) end
    return calls
end

-- Whether calls holds collectgarbage(opt, arg); a full collection is opt "collect" or no arguments.
local function called(calls, opt, arg)
    for _, c in ipairs(calls) do
        if (c[1] or "collect") == opt and c[2] == arg then return true end
    end
    return false
end

return {
    pictures_load_in_order_and_grow_their_boxes = function()
        local app, F = boot({ images = "inline" })
        go(app, F, "pics.test/")
        steps(app, 4)
        local reqs = pictureRequests(F)
        T.eq(#reqs, 2, "the third picture is beyond the window")
        T.eq(reqs[1], "/v1/get?url=https%3A%2F%2Fimg.test%2F1.jpg&fit=312x126")
        T.ok(reqs[2]:find("2.jpg", 1, true))
        T.eq(boxRows(app, 1), 8); T.eq(boxRows(app, 2), 10); T.eq(boxRows(app, 3), 0)
        T.ok(F.hasLog("picosurf: inline 1 w=200 h=100 rows=8"))
        T.ok(F.hasLog("picosurf: inline 2 w=312 h=126 rows=10"))
        T.eq(app.page.ps.top, 1, "growing below the top leaves the view")
    end,
    one_picture_at_a_time = function()
        local app, F = boot({ images = "inline" })
        openHolding(app, F, "pics.test/")
        steps(app, 2)
        T.eq(app.screenName, "page")
        T.eq(#pictureRequests(F), 1)
        F.holding = false
        steps(app, 2)
        T.eq(#pictureRequests(F), 2)
    end,
    a_picture_above_the_view_grows_without_moving_it = function()
        local app, F = boot({ images = "inline" })
        openHolding(app, F, "pics.test/")
        F.press("right"); F.press("right"); steps(app, 1)
        local ps = app.page.ps
        T.eq(ps.top, 41)
        local line = app.page.L.line[41]
        F.holding = false
        steps(app, 8)
        -- One grows by 7 rows and two by 9, both above the view; three by 4, below it.
        T.eq(#pictureRequests(F), 3)
        T.eq(app.page.ps.top, 57); T.eq(app.page.L.line[57], line, "the same line is at the top")
    end,
    links_mode_fetches_no_pictures = function()
        local app, F = boot()
        go(app, F, "pics.test/")
        steps(app, 4)
        T.eq(#pictureRequests(F), 0)
        T.eq(app.page.inline, nil)
        T.eq(app.page.L.style[3], layout.IMAGE)
    end,
    failed_pictures_stay_link_lines = function()
        local app, F = boot({ images = "inline" })
        go(app, F, "fail.test/")
        steps(app, 4)
        T.eq(#pictureRequests(F), 2, "the gemini picture is not fetched")
        T.ok(F.hasLog("picosurf: inline failed https://img.test/missing.jpg 502 Site returned 404 Not Found"))
        T.ok(F.hasLog("picosurf: inline failed https://img.test/bad.jpg decode"))
        for k = 1, 3 do T.eq(boxRows(app, k), 0, "link " .. k .. " stays a line") end
        app.page.inline.wake = true
        steps(app, 2)
        T.eq(#pictureRequests(F), 2, "not tried again")
        F.menu["Reload"](); steps(app, 6)
        T.eq(#pictureRequests(F), 4, "Reload tries again")
    end,
    leaving_the_page_cancels_the_picture_in_flight = function()
        local app, F = boot({ images = "inline" })
        openHolding(app, F, "pics.test/")
        T.eq(#pictureRequests(F), 1)
        F.menu["Settings"](); steps(app, 1)
        T.ok(F.hasLog("picosurf: inline cancelled https://img.test/1.jpg"))
        T.eq(app.page.inline.inflight, nil)
        T.eq(app.page.inline.byUrl["https://img.test/1.jpg"], nil)
        F.holding = false
        F.press("esc"); steps(app, 4)
        T.eq(app.screenName, "page")
        T.eq(#pictureRequests(F), 3, "fetched again on return, then the next")
        T.eq(boxRows(app, 1), 8)
    end,
    leaving_for_a_cached_page_cancels_the_picture = function() -- Review Focus 4
        local app, F = boot({ images = "inline" })
        go(app, F, "b.test/")
        openHolding(app, F, "pics.test/")
        T.eq(app.page.url, "https://pics.test/")
        F.press("backspace"); steps(app, 1)
        T.eq(app.page.url, "https://b.test/")
        T.ok(F.hasLog("picosurf: inline cancelled https://img.test/1.jpg"))
        F.holding = false
        steps(app, 3)
        T.eq(app.screenName, "page"); T.eq(app.page.url, "https://b.test/")
        T.eq(#pictureRequests(F), 1)
    end,
    the_same_picture_twice_is_fetched_once = function() -- Review Focus 1
        local app, F = boot({ images = "inline" })
        go(app, F, "twice.test/")
        steps(app, 3)
        T.eq(#pictureRequests(F), 1)
        T.eq(#F.decoded, 1)
        T.eq(boxRows(app, 1), 8); T.eq(boxRows(app, 2), 8)
    end,
    a_gallery_keeps_few_pictures_decoded = function() -- Review Focus 2
        local app, F = boot({ images = "inline" })
        go(app, F, "gallery.test/")
        local most = 0
        for _ = 1, 60 do
            F.press("right"); steps(app, 3)
            most = math.max(most, decodedNow(app))
        end
        T.eq(app.page.ps.top, app.page.ps:maxTop(), "scrolled to the end")
        T.eq(boxRows(app, 40), 8, "the last picture loaded")
        -- The window's 63 rows overlap at most 9 boxes of 8 rows; one more may
        -- be decoded in the step before the next pass drops it.
        T.ok(most <= 10, "decoded pictures stay within the window: " .. most)
    end,
    waits_for_wifi = function()
        local app, F = boot({ images = "inline" })
        F.inputs[#F.inputs + 1] = "pics.test/"
        F.press("f1")
        app:step()
        F.netStatus = 0
        steps(app, 3)
        T.eq(app.screenName, "page")
        T.eq(#pictureRequests(F), 0, "no WiFi")
        F.netStatus = 1
        steps(app, 2)
        T.eq(#pictureRequests(F), 0, "looks again after 3 s")
        F.ms = F.ms + 3000
        steps(app, 1)
        T.eq(#pictureRequests(F), 1)
    end,
    clock_not_set_waits_and_tries_again = function()
        local app, F = boot({ images = "inline" })
        local respond, fails = F.responder, 0
        F.responder = function(path, headers)
            -- Twice: the pool retries a reused connection once on a fresh one.
            if path:find("1.jpg", 1, true) and fails < 2 then
                fails = fails + 1
                return nil, "clock not set"
            end
            return respond(path, headers)
        end
        go(app, F, "pics.test/")
        steps(app, 2)
        T.eq(boxRows(app, 1), 0)
        T.eq(app.page.inline.byUrl["https://img.test/1.jpg"], nil)
        T.ok(app.page.inline.retryAt)
        F.ms = F.ms + 3000
        steps(app, 3)
        T.eq(boxRows(app, 1), 8)
    end,
    an_old_proxy_ignores_fit = function()
        local app, F = boot({ images = "inline" })
        go(app, F, "old.test/")
        steps(app, 3)
        T.ok(F.hasLog("picosurf: inline failed https://img.test/big1.jpg larger than 312x126"))
        T.eq(#pictureRequests(F), 1, "after the toast, no more pictures are fetched")
        F.ms = F.ms + 3000
        steps(app, 3)
        T.eq(#pictureRequests(F), 1, "nor after the retry time")
        local n = 0
        for _, t in ipairs(F.toasts) do
            if t == "Inline images need a newer proxy" then n = n + 1 end
        end
        T.eq(n, 1, "one toast")
        T.eq(boxRows(app, 1), 0); T.eq(boxRows(app, 2), 0)
        app:saveConfig("proxy_url", "https://p.test") -- say, a newer proxy
        F.ms = F.ms + 3000
        steps(app, 3)
        T.eq(#pictureRequests(F), 2, "a changed setting lets it try again")
    end,
    one_decode_per_step = function()
        local app, F = boot({ images = "inline" })
        openHolding(app, F, "pics.test/")
        -- Picture two waits with its bytes but no decoded picture, as after it left the window and came back.
        local st, two = app.page.inline, "https://img.test/2.jpg"
        st.byUrl[two] = { state = "ready" }
        st:keepBytes(two, "JPEG:312x126")
        F.holding = false
        local before = #F.decoded
        app:step() -- picture one arrives and is decoded
        T.eq(#F.decoded, before + 1, "only the arrival's decode")
        app:step()
        T.eq(#F.decoded, before + 2, "picture two the step after")
        T.eq(boxRows(app, 2), 10)
    end,
    decoded_pictures_are_counted_by_the_collector = function()
        local app, F = boot({ images = "inline" })
        local calls = gcCalls(function()
            go(app, F, "pics.test/")
            steps(app, 3)
        end)
        T.eq(boxRows(app, 2), 10)
        -- A decoded picture's pixels (2 bytes each) live outside the Lua heap.
        T.ok(called(calls, "step", 39), "a step for picture one's 200x100 pixels")
        T.ok(called(calls, "step", 76), "and for picture two's 312x126")
        calls = gcCalls(function() toggleImages(app, F) end)
        T.eq(app.page.inline, nil)
        T.ok(called(calls, "collect"), "Links: a full collection lets the pictures go")
    end,
    draws_a_picture_in_its_box = function()
        local app, F = boot({ images = "inline" })
        go(app, F, "pics.test/")
        steps(app, 3)
        -- Picture one (200x100) on rows 3-10: its band starts at y 21 + 2 * 13 = 47,
        -- the picture 2 px lower, centred.
        local d = drawOf(F, "JPEG:200x100")
        T.ok(d, "picture one is drawn")
        T.eq(d.x, 60); T.eq(d.y, 49)
        T.eq(d.src.x, 0); T.eq(d.src.y, 0); T.eq(d.src.w, 200); T.eq(d.src.h, 100)
        T.eq(app.page.ps.sel, 1)
        T.ok(hasRect(F, 0, 47, 320, 104), "selected: the whole band in the selection colour")
        T.ok(not F.screenText():find("[IMG] one", 1, true), "no label while the picture shows")
    end,
    crops_pictures_to_the_rows_between_title_bar_and_footer = function()
        local app, F = boot({ images = "inline" })
        go(app, F, "pics.test/")
        steps(app, 3)
        local ps = app.page.ps
        ps:scroll(4); app.dirty = true; steps(app, 1)
        -- Top 5: picture one's band starts 2 rows above the screen (y -5), the picture at y -3.
        local d = drawOf(F, "JPEG:200x100")
        T.eq(d.y, 21); T.eq(d.src.y, 24); T.eq(d.src.h, 76)
        T.ok(hasRect(F, 0, 21, 320, 78), "the selection band is cropped too")
        ps:scroll(16); app.dirty = true; steps(app, 1)
        -- Top 21: picture two (312x126, rows 41-50) starts on the last row, its band at y 281.
        d = drawOf(F, "JPEG:312x126")
        T.eq(d.x, 4); T.eq(d.y, 283); T.eq(d.src.y, 0); T.eq(d.src.h, 11)
    end,
    page_drawing_stays_between_title_bar_and_footer = function()
        local app, F = boot({ images = "inline" })
        go(app, F, "pics.test/")
        for _ = 1, 4 do F.press("right"); steps(app, 3) end
        T.eq(boxRows(app, 3), 5, "all three pictures loaded")
        local p = app.page
        local L, ps, st = p.L, p.ps, p.inline
        -- Every scroll position with every link selected (and none): each fill
        -- and picture lies within y 21 to 294, the page's 21 rows. Returns how
        -- many fills and pictures were drawn.
        local function sweep(what)
            local rects, pictures = 0, 0
            for top = 1, ps:maxTop() do
                for sel = 0, #L.links do
                    ps.top, ps.sel = top, sel > 0 and sel or nil
                    app.disp.clear(app.theme.bg)
                    app.screen.draw(app)
                    local at = what .. ", top " .. top .. ", sel " .. sel
                    for _, r in ipairs(F.rects) do
                        T.ok(r.h > 0 and r.y >= 21 and r.y + r.h <= 294,
                            "rect at y " .. r.y .. " h " .. r.h .. ": " .. at)
                    end
                    for _, d in ipairs(F.imageDraws) do
                        T.ok(d.src.h > 0 and d.y >= 21 and d.y + d.src.h <= 294,
                            "picture at y " .. d.y .. " h " .. d.src.h .. ": " .. at)
                    end
                    rects, pictures = rects + #F.rects, pictures + #F.imageDraws
                end
            end
            return rects, pictures
        end
        for _, e in pairs(st.byUrl) do e.img = e.img or F.pc.graphics.image.loadFromBuffer(e.bytes) end
        local rects, pictures = sweep("in memory")
        T.ok(rects > 0 and pictures > 0)
        for _, e in pairs(st.byUrl) do e.img = nil end -- dropped: outlines of the pictures' sizes
        rects, pictures = sweep("dropped")
        T.ok(rects > 0); T.eq(pictures, 0)
        st.byUrl = {} -- not fetched yet, as after Back: outlines of the boxes
        rects, pictures = sweep("not fetched")
        T.ok(rects > 0); T.eq(pictures, 0)
    end,
    a_picture_not_in_memory_shows_an_outline_and_its_label = function()
        local app, F = boot({ images = "inline" })
        go(app, F, "pics.test/")
        steps(app, 3)
        local st = app.page.inline
        st.byUrl["https://img.test/1.jpg"].img = nil -- as after it left the window
        st.wake = false
        app.dirty = true; steps(app, 1)
        T.eq(drawOf(F, "JPEG:200x100"), nil)
        T.ok(hasText(F, "[IMG] one"), "the label in the box's first row")
        T.ok(hasRect(F, 60, 49, 200, 1), "the top of a 200x100 outline")
        T.ok(hasRect(F, 60, 49, 1, 100), "its left side")
    end,
    images_setting_switches_and_applies_to_the_page = function() -- Review Focus 5
        local app, F = boot()
        go(app, F, "pics.test/")
        T.eq(#pictureRequests(F), 0)
        F.menu["Settings"](); steps(app, 1)
        T.ok(F.screenText():find("Images: Links", 1, true))
        F.press("esc"); steps(app, 1)
        toggleImages(app, F)
        T.eq(F.config.images, "inline")
        T.ok(F.screenText():find("Images: Inline", 1, true))
        F.press("esc"); steps(app, 4)
        T.eq(boxRows(app, 1), 8, "the page on screen gets its pictures")
        app.page.ps:scroll(10); app.dirty = true; steps(app, 1)
        local line = app.page.L.line[app.page.ps.top]
        toggleImages(app, F)
        T.eq(F.config.images, "links")
        F.press("esc"); steps(app, 3)
        T.eq(app.page.inline, nil)
        T.eq(boxRows(app, 1), 0); T.eq(app.page.L.count, 65, "laid out again without boxes")
        T.eq(app.page.L.line[app.page.ps.top], line, "the same line at the top")
        local before = #pictureRequests(F)
        steps(app, 3)
        T.eq(#pictureRequests(F), before, "no more picture requests")
    end,
    back_and_reload_keep_the_boxes = function()
        local app, F = boot({ images = "inline" })
        go(app, F, "pics.test/")
        steps(app, 3)
        app.page.ps:scroll(30); app.dirty = true; steps(app, 4)
        local top, count = app.page.ps.top, app.page.L.count
        local line = app.page.L.line[top]
        T.eq(top, 31); T.eq(count, 81)
        go(app, F, "b.test/")
        F.press("backspace"); steps(app, 1)
        T.eq(app.page.url, "https://pics.test/")
        T.eq(app.page.L.count, count, "the same rows"); T.eq(app.page.ps.top, top)
        T.eq(app.page.L.line[top], line)
        T.eq(boxRows(app, 1), 8); T.eq(boxRows(app, 2), 10)
        steps(app, 6)
        T.eq(app.page.ps.top, top, "pictures come back without moving the view")
        T.eq(app.page.L.count, count)
        F.menu["Reload"](); steps(app, 6)
        T.eq(app.page.ps.top, top); T.eq(app.page.L.line[top], line)
        T.eq(boxRows(app, 2), 10)
    end,
    back_after_switching_to_links_keeps_the_line_at_the_top = function()
        local app, F = boot({ images = "inline" })
        go(app, F, "pics.test/")
        steps(app, 3)
        app.page.ps:scroll(30); app.dirty = true; steps(app, 4)
        T.eq(app.page.L.count, 81, "two boxes")
        local line = app.page.L.line[app.page.ps.top]
        go(app, F, "b.test/")
        toggleImages(app, F)
        T.eq(F.config.images, "links")
        F.press("esc"); steps(app, 1)
        F.press("backspace"); steps(app, 1)
        T.eq(app.page.url, "https://pics.test/")
        T.eq(app.page.L.count, 65, "no boxes")
        T.eq(app.page.L.line[app.page.ps.top], line, "the same line at the top")
    end,
    a_font_change_keeps_the_boxes = function()
        local app, F = boot({ images = "inline" })
        go(app, F, "pics.test/")
        steps(app, 3)
        F.menu["Settings"](); steps(app, 1)
        F.press("down"); F.press("down"); F.press("enter"); steps(app, 1)
        F.press("esc"); steps(app, 1)
        T.eq(app.theme.cw, 8)
        T.eq(boxRows(app, 1), 8); T.eq(boxRows(app, 2), 10)
    end,
}
