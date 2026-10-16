"""Launch the hidden dev app gemprobe and collect its gp lines until it ends.

usage: python3 devrun.py <max-seconds> <out-file>
"""
import asyncio
import sys
import time

import os  # noqa: E402

# PicoDeck's tools/ (picodeck_mcp.py): $PICODECK_TOOLS, else a picodeck
# checkout next to picosurf.
sys.path.insert(0, os.environ.get("PICODECK_TOOLS") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "../../../../picodeck/tools"))
import picodeck_mcp as pd  # noqa: E402

pd.HARDWARE_MODE = True


def call(name, **kw):
    fn = getattr(pd, name)
    fn = getattr(fn, "fn", fn)
    return asyncio.run(fn(**kw))


call("get_log_buffer", lines=1)
print(call("launch_app", app_name="gemprobe", hidden="dev"), flush=True)
end = time.time() + float(sys.argv[1])
log = ""
while time.time() < end:
    time.sleep(15)
    log = call("get_log_buffer", lines=5000)
    n = log.count("gp\t")
    print("lines", n, flush=True)
    if "gp\tend" in log:
        break
with open(sys.argv[2], "w") as f:
    f.write(log)
