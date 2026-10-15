-- Keyboard events into actions (spec 6.4). Pure: the input constants are passed in.
-- On the device Shift+Tab arrives as key 0xD2; the simulator sends Tab with Shift.
local M = {}
local KEY_TAB, KEY_SHIFT_TAB = 0x09, 0xD2

function M.decoder(I)
    local byButton = {
        [I.BTN_UP] = "up", [I.BTN_DOWN] = "down", [I.BTN_LEFT] = "left", [I.BTN_RIGHT] = "right",
        [I.BTN_ENTER] = "enter", [I.BTN_ESC] = "esc", [I.BTN_BACKSPACE] = "backspace", [I.BTN_DEL] = "del",
        [I.BTN_F1] = "f1", [I.BTN_F2] = "f2", [I.BTN_F3] = "f3", [I.BTN_F4] = "f4", [I.BTN_F5] = "f5",
    }
    -- Held F-keys and Esc report repeats; acting on them would run an action twice.
    local noRepeat = { f1 = true, f2 = true, f3 = true, f4 = true, f5 = true, esc = true }
    return function(ev)
        if ev.type == "char" then
            local c = ev.char
            if c and c:match("^%d$") then return "digit", c end
            if c == " " then return "space" end
            return nil
        end
        if ev.type ~= "down" then return nil end
        local shift = ((ev.mods or 0) & I.BTN_SHIFT) ~= 0
        if ev.key == KEY_SHIFT_TAB or (ev.key == KEY_TAB and shift) then return "prevlink" end
        if ev.key == KEY_TAB then return "nextlink" end
        local action = ev.button and byButton[ev.button]
        if action and noRepeat[action] and ev["repeat"] then return nil end
        return action
    end
end

return M
