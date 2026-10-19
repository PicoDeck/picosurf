-- A pinned certificate changed (small web spec 6): Enter trusts the new one
-- and loads the page, Esc or Backspace goes back.
local wrap = require("src.wrap")
local theme = require("src.theme")
local tofu = require("src.tofu")

local S = {}

-- args: change (a certchanged result), retry (opens the page again).
function S.enter(app, args)
    app.cert = args
end

function S.draw(app)
    local c, th, d = app.cert.change, app.theme, app.disp
    app.ui.drawHeader("Certificate changed")
    local paras = {
        "The certificate for " .. c.host .. " has changed since " .. (tofu.date(c.firstSeen) or "your first visit")
            .. ". Sites do this when they renew; it can also mean someone is intercepting the connection.",
        "",
        "Old: " .. c.old:sub(1, 16),
        "New: " .. c.new:sub(1, 16),
    }
    local cols, y = theme.uiCols(th), th.top + 20
    for _, text in ipairs(paras) do
        local s, e = wrap.wrap(text, cols)
        if #s == 0 then y = y + th.uiRowH end
        for i = 1, #s do
            d.drawText(th.margin, y, text:sub(s[i], e[i]), th.fg, false)
            y = y + th.uiRowH
        end
    end
    app.ui.drawFooter("Enter trust new  Esc back", "")
end

function S.key(app, action)
    local c = app.cert
    if action == "enter" then
        app.cert = nil
        return app:acceptCert(c.change, c.retry)
    end
    if action == "esc" or action == "backspace" then
        app.cert = nil
        app:show(app.page and "page" or "home")
    end
end

return S
