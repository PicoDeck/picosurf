-- An error with its reason; Enter retries when possible, Esc goes back (spec 6.9).
local wrap = require("src.wrap")
local theme = require("src.theme")

local S = {}

function S.enter(app, args)
    app.msg = args
end

function S.draw(app)
    local m, th, d = app.msg, app.theme, app.disp
    app.ui.drawHeader(m.title or "PicoSurf")
    local text = m.text or ""
    local s, e = wrap.wrap(text, theme.uiCols(th))
    for i = 1, math.min(#s, 16) do
        d.drawText(th.margin, th.top + 20 + (i - 1) * th.rowH, text:sub(s[i], e[i]), th.error, false)
    end
    app.ui.drawFooter(m.retry and "Enter retry  Esc back" or "Esc back", "")
end

function S.key(app, action)
    local m = app.msg
    if action == "enter" and m.retry then
        app.msg = nil
        return m.retry()
    end
    if action == "esc" or action == "backspace" then
        app.msg = nil
        app:show(app.page and "page" or "home")
    end
end

return S
