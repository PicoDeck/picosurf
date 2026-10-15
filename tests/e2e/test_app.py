"""PicoSurf smoke flows in the simulator against a fake proxy: the real
picocalc API under the app's own logic (which the host tests cover in depth)."""
import json
import re
import time

import pytest

from conftest import APP
from fake_proxy import jpeg_bytes

A = "# A\n\nSee B [1].\n=> https://b.test/ [1] B\n=> https://a.test/cat.jpg [IMG] Cat\n"
FEED = "# Blog\n\n=> https://blog.test/1 2026-10-13 One\n=> https://blog.test/2 2026-10-12 Two\n"


def mark(sim):
    """The sequence number after the newest log line: wait() from here sees
    only what the next action causes, never an older line that matches."""
    lines = sim.get_log_lines()
    return (lines[-1]["seq"] + 1) if lines else 0


def wait(sim, pattern, since=0, timeout=15):
    return sim.wait_for_log(pattern, timeout=timeout, since_seq=since, src="lua")


def no_lua_errors(sim):
    errors = [l["text"] for l in sim.get_log_lines() if l.get("src") == "err"]
    assert not errors, errors


def press(sim, key):
    """One key, then a pause: the simulator holds an injected button for about
    80 ms, and clicks sent faster than that merge into one press."""
    sim.keypress(key)
    time.sleep(0.2)


def act(sim, *keys):
    """Press keys; returns the log mark taken before them."""
    m = mark(sim)
    for k in keys:
        press(sim, k)
    return m


def go(sim, text):
    """F1, wait until the text box is open, type, Enter. Returns the mark
    taken before F1. The simulator cannot press Enter in ui.textInput (see
    test_go_prompt_accepts_url), so only that test uses this."""
    m = act(sim, "f1")
    wait(sim, r"picosurf: prompt go", m)
    # The app logs before ui.textInput runs, and the modal discards keys queued
    # before it opens (kbd_clear_state, after drawing its chrome). The simulator
    # has no signal for "modal open", so give it a moment.
    time.sleep(0.5)
    for c in text:
        sim.keypress(c)
    sim.keypress("enter")
    return m


def seed_history(data, *urls):
    """Pre-load History (newest first) so a test can open a URL from the Home
    list with plain key presses, which the simulator can do."""
    (data / "history.json").write_text(json.dumps([{"url": u, "title": u} for u in urls]))


def open_first_history(sim):
    """Home -> History tab -> Enter on the first entry. Returns the mark."""
    return act(sim, "right", "right", "enter")


def start_app(sim):
    m = mark(sim)
    sim.launch_app(APP)
    return m


def test_first_run_opens_settings(picosurf):
    sim, _, _ = picosurf(config=False)
    wait(sim, r"picosurf: screen settings", start_app(sim))
    no_lua_errors(sim)


def test_open_follow_back_and_bookmark(picosurf):
    sim, proxy, data = picosurf()
    seed_history(data, "https://a.test/")
    proxy.add("https://a.test/", A, title="A")
    proxy.add("https://b.test/", "# B\n", title="B")
    wait(sim, r"picosurf: screen home", start_app(sim))
    wait(sim, r"picosurf: loaded https://a\.test/ mode=reader links=2", open_first_history(sim))
    wait(sim, r"picosurf: loaded https://b\.test/", act(sim, "tab", "enter"))
    wait(sim, r"picosurf: loaded https://a\.test/", act(sim, "backspace"))
    assert sum(1 for path, q in proxy.requests if q.get("url") == "https://a.test/") == 1, "back used the cache"
    wait(sim, r"picosurf: bookmark add https://a\.test/", act(sim, "f3"))
    bookmarks = json.loads((data / "bookmarks.json").read_text())
    assert bookmarks[0]["url"] == "https://a.test/"
    no_lua_errors(sim)


def test_image_opens_full_screen(picosurf):
    sim, proxy, data = picosurf()
    seed_history(data, "https://a.test/")
    proxy.add("https://a.test/", A, title="A")
    proxy.add("https://a.test/cat.jpg", jpeg_bytes(200, 120), ctype="image/jpeg")
    wait(sim, r"picosurf: screen home", start_app(sim))
    wait(sim, r"picosurf: loaded https://a\.test/", open_first_history(sim))
    wait(sim, r"picosurf: image w=200 h=120", act(sim, "tab", "tab", "enter"))
    wait(sim, r"picosurf: screen page", act(sim, "esc"))
    no_lua_errors(sim)


def test_subscribe_and_read(picosurf):
    sim, proxy, data = picosurf()
    seed_history(data, "https://blog.test/")
    proxy.add("https://blog.test/", "# Blog\n", title="Blog", feed="https://blog.test/feed.xml")
    # The page advertises its feed (X-Feed-Url), so F5 asks for that URL.
    proxy.add("https://blog.test/feed.xml", FEED, as_="feed", title="Blog", mode="feed")
    proxy.add("https://blog.test/1", "# One\n", title="One")
    wait(sim, r"picosurf: screen home", start_app(sim))
    wait(sim, r"picosurf: loaded https://blog\.test/", open_first_history(sim))
    wait(sim, r"picosurf: subscribed 1 https://blog\.test/feed\.xml unread=2", act(sim, "f5"))
    wait(sim, r"picosurf: screen home", act(sim, "f2"))
    # Home keeps the tab it was left on (History, where the page was opened from).
    wait(sim, r"picosurf: tab Feeds", act(sim, "left", "left"))
    wait(sim, r"picosurf: feed 1 unread=2", act(sim, "enter"))
    wait(sim, r"picosurf: feed 1 unread=1", act(sim, "tab", "enter"))
    index = json.loads((data / "feeds" / "index.json").read_text())
    assert index["feeds"][0]["unread"] == 1
    no_lua_errors(sim)


def test_proxy_errors_show(picosurf):
    sim, _, data = picosurf()
    seed_history(data, "https://missing.test/")
    wait(sim, r"picosurf: screen home", start_app(sim))
    line = wait(sim, r"picosurf: error 502 ", open_first_history(sim))
    assert re.search(r"Site returned 404 Not Found", line)
    no_lua_errors(sim)


@pytest.mark.skip(reason="simulator gap: inject_button enter sends BTN_ENTER but no '\\n' char, and inject_char "
                         "cannot carry a newline (its JSON parser does not unescape), so Enter never accepts "
                         "ui.textInput, which accepts only on the '\\n' char")
def test_go_prompt_accepts_url(picosurf):
    sim, proxy, _ = picosurf()
    proxy.add("https://a.test/", A, title="A")
    wait(sim, r"picosurf: screen home", start_app(sim))
    wait(sim, r"picosurf: loaded https://a\.test/", go(sim, "a.test/"))
    no_lua_errors(sim)
