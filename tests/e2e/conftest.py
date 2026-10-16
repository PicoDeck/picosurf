"""PicoSurf in the PicoDeck simulator, talking to a fake proxy.

Uses PicoDeck's E2E harness from $PICODECK_ROOT (default
~/Projects/PicoDeck/picodeck); the simulator binary is $PICODECK_SIM_BINARY or
that checkout's build_sim/picodeck_simulator (make simulator there)."""
import json
import os
import shutil
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
PICODECK = Path(os.environ.get("PICODECK_ROOT", Path.home() / "Projects" / "PicoDeck" / "picodeck"))
sys.path.insert(0, str(PICODECK / "tests" / "e2e"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from picodeck_simulator import PicodeckSimulator  # noqa: E402
from fake_proxy import FakeProxy  # noqa: E402

APP, APP_ID = "picosurf", "net.picodeck.picosurf"
APP_FILES = ("app.json", "main.lua", "src", "fonts")


def stage_app(dest: Path):
    dest.mkdir(parents=True, exist_ok=True)
    for name in APP_FILES:
        src = REPO / name
        if src.is_dir():
            shutil.copytree(src, dest / name, dirs_exist_ok=True)
        else:
            shutil.copy(src, dest / name)


@pytest.fixture
def picosurf(tmp_path):
    """start(config=True, settings=None) -> (sim, proxy, data_dir). settings:
    more config.json keys, e.g. {"images": "inline"}. With config, the app's
    config.json points at a fresh FakeProxy; routes can be added after start
    (they are looked up per request)."""
    started = []

    def start(config=True, settings=None):
        proxy = FakeProxy().start()
        sd = tmp_path / f"sd{len(started)}"
        stage_app(sd / "apps" / APP)
        data = sd / "data" / APP_ID
        (data / "feeds").mkdir(parents=True, exist_ok=True)
        if config:
            cfg = {"proxy_url": proxy.url, "token": proxy.token, **(settings or {})}
            (data / "config.json").write_text(json.dumps(cfg))
        sim = PicodeckSimulator(binary_path=os.environ.get("PICODECK_SIM_BINARY"),
                                sd_card_path=str(sd), test_mode=True)
        sim.start()
        started.append((sim, proxy))
        return sim, proxy, data

    yield start
    for sim, proxy in started:
        sim.stop()
        proxy.stop()
