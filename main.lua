-- PicoSurf: read the web and feeds on PicoDeck through a PicoSurf proxy.
if not require then
    picocalc.ui.splash("PicoSurf needs a newer PicoDeck", "Update the firmware to 0.5.0 or later")
    picocalc.sys.sleep(3000)
    return
end
local App = require("src.app")
App.new(picocalc, APP_ID):run()
