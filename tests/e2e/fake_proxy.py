"""A stand-in PicoSurf proxy for simulator tests: canned gemtext, feeds and
images for chosen URLs, the token check, and a record of requests. The real
proxy refuses localhost sites (its SSRF guard), and the app is what is under
test here."""
import io
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

PLAIN = "text/plain; charset=us-ascii"


class FakeProxy:
    def __init__(self, token="test-token"):
        self.token = token
        self.routes = {}
        self.requests = []
        self._server = None

    def add(self, url, body, *, as_=None, ctype="text/gemini; charset=us-ascii", title=None,
            mode=None, final=None, feed=None, status=200, delay=0.0):
        data = body if isinstance(body, bytes) else body.encode("ascii")
        self.routes[(url, as_)] = dict(body=data, ctype=ctype, title=title, mode=mode, final=final,
                                       feed=feed, status=status, delay=delay)

    def start(self):
        proxy = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _send(self, status, ctype, body, extra=None):
                self.send_response(status)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                for k, v in (extra or {}).items():
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                parts = urlsplit(self.path)
                q = {k: v[0] for k, v in parse_qs(parts.query).items()}
                proxy.requests.append((parts.path, q))
                if self.headers.get("Authorization") != f"Bearer {proxy.token}":
                    return self._send(401, PLAIN, b"Missing or wrong token\n")
                if parts.path.endswith("/v1/ping"):
                    return self._send(200, PLAIN, b"picosurf-proxy 1\n")
                if not parts.path.endswith("/v1/get"):
                    return self._send(404, PLAIN, b"Not found\n")
                url, as_ = q.get("url", ""), q.get("as")
                r = proxy.routes.get((url, as_)) or proxy.routes.get((url, None))
                if r is None:
                    return self._send(502, PLAIN, b"Site returned 404 Not Found\n", {"X-Upstream-Status": "404"})
                if r["delay"]:
                    time.sleep(r["delay"])
                extra = {"X-Final-Url": r["final"] or url}
                if r["ctype"].startswith("text/gemini"):
                    extra["X-Mode"] = r["mode"] or (as_ or "reader")
                if r["title"]:
                    extra["X-Title"] = r["title"]
                if r["feed"]:
                    extra["X-Feed-Url"] = r["feed"]
                body = r["body"]
                if r["ctype"] == "image/jpeg" and "fit" in q:
                    body = fit_jpeg(body, q["fit"])
                self._send(r["status"], r["ctype"], body, extra)

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        return self

    @property
    def url(self):
        return f"http://127.0.0.1:{self._server.server_address[1]}"

    def stop(self):
        self._server.shutdown()
        self._server.server_close()


def jpeg_bytes(w=200, h=120):
    """A baseline JPEG, as the real proxy sends."""
    from PIL import Image
    buf = io.BytesIO()
    Image.new("RGB", (w, h), (30, 120, 200)).save(buf, "JPEG", quality=80, progressive=False)
    return buf.getvalue()


def fit_jpeg(data, fit):
    """Scales a JPEG to fit within WxH, never enlarging, as the proxy's fit
    parameter does."""
    from PIL import Image
    w, h = (int(v) for v in fit.split("x"))
    img = Image.open(io.BytesIO(data))
    img.thumbnail((w, h))
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=80, progressive=False)
    return buf.getvalue()
