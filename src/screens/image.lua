-- An image, centred on black (spec 6.2). The proxy has already shrunk it to
-- fit 320x320 as a baseline JPEG.
local S = {}

function S.enter(app, args)
    app.image, app.imageUrl = args.image, args.url
    local w, h = args.image:getSize()
    app.imageSize = { w, h }
    app:log("image", "w=" .. w, "h=" .. h)
end

function S.draw(app)
    app.disp.clear(app.disp.BLACK)
    local w, h = app.imageSize[1], app.imageSize[2]
    app.image:draw((320 - w) // 2, (320 - h) // 2)
end

function S.key(app, action)
    if action == "esc" or action == "backspace" then
        app.image = nil
        collectgarbage()
        app:show(app.page and "page" or "home")
    end
end

return S
