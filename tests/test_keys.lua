local T = require("tests.t")
local keys = require("src.keys")

local I = {
    BTN_UP = 1, BTN_DOWN = 2, BTN_LEFT = 4, BTN_RIGHT = 8, BTN_ENTER = 16, BTN_ESC = 32,
    BTN_F1 = 128, BTN_F2 = 256, BTN_F3 = 512, BTN_F4 = 1024, BTN_F5 = 2048,
    BTN_BACKSPACE = 65536, BTN_TAB = 131072, BTN_DEL = 262144, BTN_SHIFT = 524288,
}
local decode = keys.decoder(I)
local function down(key, button, mods, rep)
    return decode({ type = "down", key = key, button = button, mods = mods or 0, ["repeat"] = rep })
end

return {
    buttons_map_to_actions = function()
        T.eq(down(0xB5, I.BTN_UP), "up"); T.eq(down(0xB6, I.BTN_DOWN), "down")
        T.eq(down(0xB4, I.BTN_LEFT), "left"); T.eq(down(0xB7, I.BTN_RIGHT), "right")
        T.eq(down(0x0A, I.BTN_ENTER), "enter"); T.eq(down(0xB1, I.BTN_ESC), "esc")
        T.eq(down(0x08, I.BTN_BACKSPACE), "backspace"); T.eq(down(0xD4, I.BTN_DEL), "del")
        T.eq(down(0x81, I.BTN_F1), "f1"); T.eq(down(0x85, I.BTN_F5), "f5")
    end,
    tab_and_both_shift_tab_forms = function()
        T.eq(down(0x09, I.BTN_TAB), "nextlink")
        T.eq(down(0xD2, nil), "prevlink", "the device sends Shift+Tab as key 0xD2")
        T.eq(down(0x09, I.BTN_TAB, I.BTN_SHIFT), "prevlink", "the simulator sends Tab with Shift")
    end,
    chars_give_digits_and_space_only = function()
        local a, d = decode({ type = "char", key = 0x37, char = "7", mods = 0 })
        T.eq(a, "digit"); T.eq(d, "7")
        T.eq(decode({ type = "char", key = 0x20, char = " ", mods = 0 }), "space")
        T.eq(decode({ type = "char", key = 0x61, char = "a", mods = 0 }), nil)
        T.eq(decode({ type = "char", key = 0x0A, char = "\n", mods = 0 }), nil)
    end,
    key_releases_and_repeated_function_keys_are_ignored = function()
        T.eq(decode({ type = "up", key = 0xB5, button = I.BTN_UP, mods = 0 }), nil)
        T.eq(down(0x83, I.BTN_F3, 0, true), nil)
        T.eq(down(0xB1, I.BTN_ESC, 0, true), nil)
        T.eq(down(0xB6, I.BTN_DOWN, 0, true), "down", "arrows keep repeating")
    end,
    unknown_keys_give_nothing = function()
        T.eq(down(0xD6, nil), nil)
    end,
}
