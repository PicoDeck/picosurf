-- Colours, fonts and row geometry (spec 6.3).
local inline = require("src.inline")

local M = {}

-- spec: a reading font from fonts.load. font/bold: the reading font, for page
-- text only; adv/boldAdv: their advances; indent: list and quote indent in
-- px; pre: the monospace font for preformatted lines, whose cell width is
-- cw. ui/uiCw: the system font (6x8), for everything else: the firmware
-- draws the title bar, footer, tabs, list rows, toasts, text boxes and the
-- system menu in whatever font is current, laid out for 6x8. uiRowH: the
-- pitch of system-font lines outside the page view (hints, notes, messages),
-- the same whatever the reading font's rowH.
function M.new(disp, spec)
    local rgb = disp.rgb
    return {
        fontName = spec.name, font = spec.font, bold = spec.bold, adv = spec.adv, boldAdv = spec.boldAdv,
        indent = spec.indent, pre = spec.pre,
        ui = disp.FONT_6X8, uiCw = 6, uiRowH = 13,
        cw = spec.pre.cw, rowH = spec.rowH, top = 21, bottom = 302, margin = 4,
        bg = disp.BLACK, fg = disp.WHITE, dim = rgb(120, 120, 120),
        h1 = rgb(255, 210, 80), h2 = rgb(120, 200, 255), h3 = rgb(160, 230, 160),
        link = rgb(100, 170, 255), image = rgb(220, 140, 255), read = rgb(110, 130, 160),
        selBg = rgb(40, 70, 130), quote = rgb(170, 170, 170), preColor = rgb(150, 220, 150),
        bar = rgb(90, 90, 90), error = rgb(255, 110, 110),
    }
end

-- Columns of a preformatted row: the code font's columns less one for the
-- continuation mark.
function M.preCols(th)
    return (320 - 2 * th.margin) // th.pre.cw - 1
end

-- Layout metrics for this reading font (proportional fonts spec 5.2).
function M.metrics(th)
    return {
        width = 320 - 2 * th.margin, adv = th.adv, boldAdv = th.boldAdv, indent = th.indent,
        preCols = M.preCols(th), boxRows = function(h) return inline.rows(h, th.rowH) end,
    }
end

-- Columns of system-font text (hints, notes, messages).
function M.uiCols(th)
    return (320 - 2 * th.margin) // th.uiCw
end

function M.rows(th)
    return (th.bottom - th.top) // th.rowH
end

return M
