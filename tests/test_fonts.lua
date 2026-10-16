local T = require("tests.t")
local fakepc = require("tests.fakepc")
local fonts = require("src.fonts")
local theme = require("src.theme")

local DIR = "/apps/picosurf"
local function b(c) return c:byte() end

return {
    builtin_fonts_measure_fixed_widths = function()
        local F = fakepc.new()
        local d = F.pc.display
        local s, err = fonts.load(d, DIR, "scientifica")
        T.eq(err, nil)
        T.eq(s.name, "scientifica"); T.eq(s.font, d.FONT_SCIENTIFICA); T.eq(s.bold, d.FONT_SCIENTIFICA_BOLD)
        T.eq(s.rowH, 13); T.eq(s.indent, 12); T.eq(s.pre.font, d.FONT_SCIENTIFICA); T.eq(s.pre.cw, 6)
        T.eq(s.adv[b("A")], 6); T.eq(s.adv.uniform, 6); T.eq(s.adv.widest, 6); T.eq(#s.loaded, 0)
        local l = fonts.load(d, DIR, "8x12")
        T.eq(l.name, "8x12"); T.eq(l.font, d.FONT_8X12); T.eq(l.bold, d.FONT_8X12)
        T.eq(l.indent, 16); T.eq(l.pre.font, d.FONT_8X12); T.eq(l.pre.cw, 8); T.eq(l.adv.uniform, 8)
    end,
    sans_and_serif_load_their_files_and_measure_them = function()
        local F = fakepc.new()
        local d = F.pc.display
        local s, err = fonts.load(d, DIR, "sans")
        T.eq(err, nil); T.eq(s.name, "sans"); T.eq(s.rowH, 14); T.eq(s.indent, 12)
        T.eq(F.fontFiles[s.font], DIR .. "/fonts/sans.pfn")
        T.eq(F.fontFiles[s.bold], DIR .. "/fonts/sans-bold.pfn")
        T.eq(s.pre.font, d.FONT_SCIENTIFICA); T.eq(s.pre.cw, 6)
        T.eq(s.adv[b("i")], 3); T.eq(s.adv[b("m")], 9); T.eq(s.adv[b("a")], 6)
        T.eq(s.boldAdv[b("a")], 7); T.eq(s.adv.widest, 9); T.eq(s.boldAdv.widest, 10)
        T.eq(s.adv.uniform, nil); T.eq(#s.loaded, 2)
        local r = fonts.load(d, DIR, "serif")
        T.eq(r.name, "serif"); T.eq(r.rowH, 13)
        T.eq(F.fontFiles[r.font], DIR .. "/fonts/serif.pfn")
        T.eq(F.fontFiles[r.bold], DIR .. "/fonts/serif-bold.pfn")
    end,
    measuring_leaves_the_current_font = function()
        local F = fakepc.new()
        local d = F.pc.display
        d.setFont(d.FONT_6X8)
        fonts.load(d, DIR, "sans")
        T.eq(F.font, d.FONT_6X8)
    end,
    a_missing_file_falls_back_to_scientifica = function() -- Review Focus 4
        local F = fakepc.new()
        local d = F.pc.display
        F.missingFonts[DIR .. "/fonts/sans-bold.pfn"] = true
        local s, err = fonts.load(d, DIR, "sans")
        T.eq(s.name, "scientifica"); T.eq(s.font, d.FONT_SCIENTIFICA); T.eq(s.adv.uniform, 6)
        T.ok(err and err:find(DIR .. "/fonts/sans-bold.pfn", 1, true), "the error names the file: " .. tostring(err))
        T.eq(next(F.fontFiles), nil, "the regular font it did load is unloaded")
    end,
    unload_frees_loaded_fonts = function()
        local F = fakepc.new()
        local d = F.pc.display
        local s = fonts.load(d, DIR, "serif")
        fonts.unload(d, s)
        T.eq(next(F.fontFiles), nil); T.eq(#s.loaded, 0)
    end,
    choices_cycle_and_unknown_names_mean_sans = function()
        T.eq(fonts.normalize(nil), "sans"); T.eq(fonts.normalize("comic"), "sans"); T.eq(fonts.normalize("8x12"), "8x12")
        T.eq(fonts.nextChoice("scientifica"), "8x12"); T.eq(fonts.nextChoice("8x12"), "sans")
        T.eq(fonts.nextChoice("sans"), "serif"); T.eq(fonts.nextChoice("serif"), "scientifica")
        T.eq(fonts.LABELS.scientifica, "Scientifica"); T.eq(fonts.LABELS["8x12"], "8x12 (large)")
        T.eq(fonts.LABELS.sans, "Sans"); T.eq(fonts.LABELS.serif, "Serif")
    end,
    theme_metrics_come_from_the_font = function()
        local F = fakepc.new()
        local d = F.pc.display
        local sci = theme.metrics(theme.new(d, fonts.load(d, DIR, "scientifica")))
        T.eq(sci.width, 312); T.eq(sci.preCols, 51); T.eq(sci.indent, 12); T.eq(sci.boxRows(120), 10)
        local th = theme.new(d, fonts.load(d, DIR, "sans"))
        T.eq(th.fontName, "sans"); T.eq(th.rowH, 14); T.eq(th.cw, 6); T.eq(theme.rows(th), 20)
        local m = theme.metrics(th)
        T.eq(m.preCols, 51); T.eq(m.boxRows(120), 9); T.eq(m.adv, th.adv); T.eq(m.boldAdv, th.boldAdv)
    end,
}
