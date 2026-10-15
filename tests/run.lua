-- Host test runner. From the repo root: lua tests/run.lua [file ...]
-- Runs every tests/test_*.lua (or the files given); each returns a table
-- of test functions.
package.path = "./?.lua;" .. package.path

local function discover()
    local files = {}
    local p = assert(io.popen("ls tests/test_*.lua 2>/dev/null"))
    for line in p:lines() do files[#files + 1] = line end
    p:close()
    return files
end

local files = #arg > 0 and arg or discover()
local passed, failed = 0, 0
for _, path in ipairs(files) do
    local cases = assert(loadfile(path))()
    local names = {}
    for name in pairs(cases) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local ok, err = xpcall(cases[name], debug.traceback)
        if ok then
            passed = passed + 1
        else
            failed = failed + 1
            print("FAIL " .. path .. " " .. name .. "\n" .. err)
        end
    end
end
print(string.format("%d passed, %d failed (%s, %s numbers)", passed, failed, _VERSION,
    math.maxinteger == 2147483647 and "32-bit" or "64-bit"))
os.exit(failed == 0 and 0 or 1)
