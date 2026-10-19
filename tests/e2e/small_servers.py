"""Local Gemini and Gopher servers for PicoSurf's simulator tests. Both
listen on 127.0.0.1 with an OS-assigned port, answer from a routes dict that
a test may change at any time, and record what they were asked. The
certificates in certs/ are fixed self-signed EC P-256 test certificates."""
import hashlib
import socket
import ssl
import threading
from pathlib import Path

CERTS = Path(__file__).resolve().parent / "certs"


def fingerprint(pem_path: Path) -> str:
    """The SHA-256 of the certificate in a PEM file, lowercase hex: what
    tcp:peerFingerprint() reports and known_hosts.json keeps."""
    pem = pem_path.read_text()
    begin = pem.index("-----BEGIN CERTIFICATE-----")
    end = pem.index("-----END CERTIFICATE-----") + len("-----END CERTIFICATE-----")
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem[begin:end])).hexdigest()


class _Server:
    def __init__(self):
        self.routes = {}
        self.requests = []
        self.sock = socket.create_server(("127.0.0.1", 0))
        self.port = self.sock.getsockname()[1]

    def start(self):
        threading.Thread(target=self._serve, daemon=True).start()
        return self

    def _serve(self):
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _request_line(self, s) -> str:
        data = b""
        while b"\n" not in data and len(data) < 2048:
            chunk = s.recv(2048)
            if not chunk:
                break
            data += chunk
        return data.split(b"\r\n")[0].split(b"\n")[0].decode("utf-8", "replace")

    def stop(self):
        self.sock.close()


class GeminiServer(_Server):
    """routes: request URL -> whole response (header and body, str or bytes);
    anything else gets 51. use_cert() swaps the certificate for new
    connections."""

    def __init__(self, cert="a.pem"):
        super().__init__()
        self.use_cert(cert)

    def use_cert(self, name: str):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(str(CERTS / name))
        self.ctx = ctx

    @property
    def base(self) -> str:
        return f"gemini://127.0.0.1:{self.port}/"

    def _handle(self, conn):
        try:
            with self.ctx.wrap_socket(conn, server_side=True) as s:
                s.settimeout(5)
                url = self._request_line(s)
                self.requests.append(url)
                reply = self.routes.get(url, "51 Not found\r\n")
                s.sendall(reply if isinstance(reply, bytes) else reply.encode("utf-8"))
                s.unwrap()  # a TLS close_notify, as every Gemini server sends
        except (OSError, ssl.SSLError):
            pass


class GopherServer(_Server):
    """routes: selector line (search after a tab) -> reply; anything else
    gets an error item."""

    @property
    def base(self) -> str:
        return f"gopher://127.0.0.1:{self.port}/"

    def item(self, kind: str, label: str, selector: str) -> str:
        return f"{kind}{label}\t{selector}\t127.0.0.1\t{self.port}\r\n"

    def _handle(self, conn):
        try:
            with conn:
                conn.settimeout(5)
                selector = self._request_line(conn)
                self.requests.append(selector)
                reply = self.routes.get(selector, "3Not found\t\terror.host\t1\r\n.\r\n")
                conn.sendall(reply if isinstance(reply, bytes) else reply.encode("utf-8"))
        except OSError:
            pass
