-- Throwaway: connect to each Gemini host with setInsecure TLS, send the
-- request line, log the handshake time and response header.
local pc = picocalc
local d, sys = pc.display, pc.sys
local hosts = require("hosts")

local function clean(s)
    return (s:gsub("[^\32-\126]", "?")):sub(1, 70)
end

local function status(i, host, msg)
    d.clear(d.BLACK)
    d.drawText(4, 4, ("Gem Probe %d/%d"):format(i, #hosts), d.WHITE)
    d.drawText(4, 20, host, d.WHITE)
    d.drawText(4, 36, msg or "", d.WHITE)
    d.flush()
end

sys.log("gp\tstart\t" .. #hosts)
local okN = 0
for i, host in ipairs(hosts) do
    status(i, host, "connecting")
    local c, err = pc.tcp.new(host, 1965, true)
    if not c then
        sys.log("gp\t" .. host .. "\tfail\t0\t0\tnew: " .. tostring(err))
    else
        c:setInsecure(true)
        c:setConnectTimeout(20)
        local t0 = sys.getTimeMs()
        local started, cerr = c:connect()
        local ok = started and c:waitConnected(25)
        local tc = sys.getTimeMs() - t0
        if not ok then
            sys.log(("gp\t%s\tfail\t%d\t%d\t%s"):format(host, tc, tc, clean(tostring(cerr or c:error()))))
        else
            c:write("gemini://" .. host .. "/\r\n")
            local buf = ""
            local deadline = sys.getTimeMs() + 15000
            while not buf:find("\r\n", 1, true) and sys.getTimeMs() < deadline and #buf < 1100 do
                if c:waitData(1) then buf = buf .. (c:read(1100) or "") end
                if not c:isConnected() and c:available() == 0 then break end
            end
            local tt = sys.getTimeMs() - t0
            local hdr = buf:match("^([^\r\n]*)") or ""
            if #buf > 0 then okN = okN + 1 end
            sys.log(("gp\t%s\t%s\t%d\t%d\t%s"):format(host, #buf > 0 and "ok" or "noread", tc, tt,
                #buf > 0 and clean(hdr) or clean(tostring(c:error()))))
        end
        c:close()
    end
    sys.sleep(200)
end
sys.log("gp\tend\t" .. okN)
status(#hosts, "done", okN .. " ok")
sys.sleep(3000)
