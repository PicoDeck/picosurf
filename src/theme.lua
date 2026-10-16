-- Colours, fonts and row geometry (spec 6.3).
local M = {}

-- font/bold/cw: the reading font, for page text only. ui/uiCw: the system
-- font (6x8), for everything else: the firmware draws the title bar, footer,
-- tabs, list rows, toasts, text boxes and the system menu in whatever font is
-- current, laid out for 6x8.
function M.new(disp, fontName)
    local rgb = disp.rgb
    local large = fontName == "8x12"
    return {
        font = large and disp.FONT_8X12 or disp.FONT_SCIENTIFICA,
        bold = large and disp.FONT_8X12 or disp.FONT_SCIENTIFICA_BOLD,
        ui = disp.FONT_6X8, uiCw = 6,
        cw = large and 8 or 6, rowH = 13, top = 21, bottom = 302, margin = 4,
        bg = disp.BLACK, fg = disp.WHITE, dim = rgb(120, 120, 120),
        h1 = rgb(255, 210, 80), h2 = rgb(120, 200, 255), h3 = rgb(160, 230, 160),
        link = rgb(100, 170, 255), image = rgb(220, 140, 255), read = rgb(110, 130, 160),
        selBg = rgb(40, 70, 130), quote = rgb(170, 170, 170), pre = rgb(150, 220, 150),
        bar = rgb(90, 90, 90), error = rgb(255, 110, 110),
    }
end

function M.cols(th)
    return (320 - 2 * th.margin) // th.cw
end

-- Columns of system-font text (hints, notes, messages).
function M.uiCols(th)
    return (320 - 2 * th.margin) // th.uiCw
end

function M.rows(th)
    return (th.bottom - th.top) // th.rowH
end

return M
