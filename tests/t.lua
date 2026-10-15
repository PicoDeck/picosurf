-- Assertions for the host tests.
local T = {}

function T.ok(v, msg)
    if not v then error(msg or "expected a true value", 2) end
end

function T.eq(got, want, msg)
    if got ~= want then
        error(string.format("%s: got %s, want %s", msg or "eq", tostring(got), tostring(want)), 2)
    end
end

function T.near(got, want, eps, msg)
    if type(got) ~= "number" or math.abs(got - want) > eps then
        error(string.format("%s: got %s, want %s +- %s", msg or "near", tostring(got),
            tostring(want), tostring(eps)), 2)
    end
end

-- fn must raise an error whose message contains `pattern` (plain text).
function T.raises(fn, pattern, msg)
    local ok, err = pcall(fn)
    if ok then error((msg or "raises") .. ": no error raised", 2) end
    if not string.find(tostring(err), pattern, 1, true) then
        error(string.format("%s: error %q lacks %q", msg or "raises", tostring(err), pattern), 2)
    end
end

return T
