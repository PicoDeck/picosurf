"""Gemini and Gopher in the simulator (small web spec 12.2), against local
servers: pages and relative links, input, a changed certificate, Gopher menus
and text, and a gemlog subscription. Needs a simulator whose TLS sockets honour
setInsecure and report tcp:peerFingerprint() (PicoDeck's
feat/tcp-peer-fingerprint, in develop)."""
import json
import time

import pytest

from small_servers import GeminiServer, GopherServer, fingerprint, CERTS
from test_app import act, no_lua_errors, open_first_history, seed_history, start_app, wait


@pytest.fixture
def gemini():
    server = GeminiServer().start()
    yield server
    server.stop()


@pytest.fixture
def gopher():
    server = GopherServer().start()
    yield server
    server.stop()


def test_gemini_page_and_relative_link(picosurf, gemini):
    sim, _, data = picosurf()
    gemini.routes[gemini.base] = "20 text/gemini\r\n# Capsule\n=> sub.gmi Sub page\n"
    gemini.routes[gemini.base + "sub.gmi"] = "20 text/gemini\r\n# Sub\n"
    seed_history(data, gemini.base)
    wait(sim, r"picosurf: screen home", start_app(sim))
    wait(sim, rf"picosurf: loaded {gemini.base} mode=native", open_first_history(sim))
    wait(sim, rf"picosurf: loaded {gemini.base}sub\.gmi", act(sim, "enter"))
    hosts = json.loads((data / "known_hosts.json").read_text())
    assert hosts[f"127.0.0.1:{gemini.port}"]["fp"] == fingerprint(CERTS / "a.pem")
    no_lua_errors(sim)


def test_gemini_input(picosurf, gemini):
    sim, _, data = picosurf()
    gemini.routes[gemini.base] = "20 text/gemini\r\n# Capsule\n=> search Search\n"
    gemini.routes[gemini.base + "search"] = "10 Search for\r\n"
    gemini.routes[gemini.base + "search?cats"] = "20 text/gemini\r\n# Cats\n"
    seed_history(data, gemini.base)
    wait(sim, r"picosurf: screen home", start_app(sim))
    wait(sim, rf"picosurf: loaded {gemini.base}", open_first_history(sim))
    m = act(sim, "enter")
    wait(sim, r"picosurf: prompt input", m)
    time.sleep(0.5)  # the text box opens after the log line
    for c in "cats":
        sim.keypress(c)
    sim.keypress("\n")
    wait(sim, rf"picosurf: loaded {gemini.base}search\?cats", m)
    no_lua_errors(sim)


def test_changed_certificate_is_reviewed(picosurf, gemini):
    sim, _, data = picosurf()
    gemini.routes[gemini.base] = "20 text/gemini\r\n# Capsule\n=> sub.gmi Sub page\n"
    gemini.routes[gemini.base + "sub.gmi"] = "20 text/gemini\r\n# Sub\n"
    seed_history(data, gemini.base)
    wait(sim, r"picosurf: screen home", start_app(sim))
    wait(sim, rf"picosurf: loaded {gemini.base} ", open_first_history(sim))
    gemini.use_cert("b.pem")
    wait(sim, r"picosurf: screen cert", act(sim, "enter"))
    assert gemini.base + "sub.gmi" not in gemini.requests, "the request waited for the review"
    m = act(sim, "enter")
    wait(sim, rf"picosurf: cert accepted 127\.0\.0\.1:{gemini.port}", m)
    wait(sim, rf"picosurf: loaded {gemini.base}sub\.gmi", m)
    hosts = json.loads((data / "known_hosts.json").read_text())
    assert hosts[f"127.0.0.1:{gemini.port}"]["fp"] == fingerprint(CERTS / "b.pem")
    no_lua_errors(sim)


def test_gopher_menu_and_text(picosurf, gopher):
    sim, _, data = picosurf()
    gopher.routes[""] = "iWelcome\t\t127.0.0.1\t1\r\n" + gopher.item("0", "About", "/about") + ".\r\n"
    gopher.routes["/about"] = "About this hole.\r\n.\r\n"
    seed_history(data, gopher.base)
    wait(sim, r"picosurf: screen home", start_app(sim))
    wait(sim, rf"picosurf: loaded {gopher.base} mode=native", open_first_history(sim))
    wait(sim, rf"picosurf: loaded {gopher.base}0/about", act(sim, "enter"))
    no_lua_errors(sim)


def test_gemlog_subscription(picosurf, gemini):
    sim, _, data = picosurf()
    log = gemini.base + "log.gmi"
    gemini.routes[log] = "20 text/gemini\r\n# Log\n=> 2.gmi 2026-10-02 Two\n=> 1.gmi 2026-10-01 One\n"
    seed_history(data, log)
    wait(sim, r"picosurf: screen home", start_app(sim))
    wait(sim, rf"picosurf: loaded {log}", open_first_history(sim))
    wait(sim, rf"picosurf: subscribed 1 {log} unread=2", act(sim, "f5"))
    no_lua_errors(sim)
