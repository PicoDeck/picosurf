"""Gemini handshake survey: a normal OpenSSL client vs PicoDeck's mbedTLS config.

usage: python3 -I survey.py <known-hosts.gmi> <gemprobe-binary> <out.tsv> [limit]

One host per domain (last two labels, three under a short second level such as
co.uk), IPv4 only, like the device. Each host gets one request from each
client: gemini://host/ (what any Gemini client sends).
"""
import concurrent.futures as cf
import ipaddress
import re
import socket
import ssl
import subprocess
import sys
import time

HOST_RE = re.compile(r"^=> gemini://([a-z0-9.-]+)(?::(\d+))?/?\s*$", re.I)
SKIP_TLDS = ("i2p", "onion", "loki", "ygg", "local", "lan")


def site_key(host):
    parts = host.split(".")
    if len(parts) >= 3 and len(parts[-2]) <= 3 and len(parts[-1]) == 2:
        return ".".join(parts[-3:])
    return ".".join(parts[-2:])


def pick_hosts(path):
    hosts = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = HOST_RE.match(line.strip())
            if not m:
                continue
            host, port = m.group(1).lower().rstrip("."), m.group(2) or "1965"
            if "." not in host or host.split(".")[-1] in SKIP_TLDS or port != "1965":
                continue
            try:
                if not ipaddress.ip_address(host).is_global:
                    continue
            except ValueError:
                pass
            hosts.append(host)
    groups = {}
    for h in hosts:
        groups.setdefault(site_key(h), []).append(h)
    chosen = []
    for key, hs in groups.items():
        chosen.append(key if key in hs else sorted(hs, key=len)[0])
    return sorted(set(hosts)), sorted(chosen)


def clean(s):
    return "".join(c if 0x20 <= ord(c) < 0x7F and c != "\t" else "?" for c in s)[:80]


def baseline(host):
    """-> (stage, version, cipher, header)"""
    try:
        addr = socket.getaddrinfo(host, 1965, socket.AF_INET, socket.SOCK_STREAM)[0][4]
    except (OSError, UnicodeError):
        try:
            socket.getaddrinfo(host, 1965, socket.AF_INET6, socket.SOCK_STREAM)
            return ("ipv6only", "-", "-", "-")
        except (OSError, UnicodeError):
            return ("dns", "-", "-", "-")
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    try:
        raw = socket.create_connection(addr, timeout=8)
    except OSError:
        return ("connect", "-", "-", "-")
    try:
        raw.settimeout(10)
        try:
            s = ctx.wrap_socket(raw, server_hostname=host)
        except (OSError, ssl.SSLError) as e:
            return ("handshake", "-", "-", clean(str(e)))
        ver, ciph = s.version(), s.cipher()[0]
        try:
            s.sendall(("gemini://%s/\r\n" % host).encode())
            buf = b""
            while b"\r\n" not in buf and len(buf) < 1100:
                b = s.recv(1100)
                if not b:
                    break
                buf += b
        except (OSError, ssl.SSLError) as e:
            return ("read", ver, ciph, clean(str(e)))
        if not buf:
            return ("read", ver, ciph, "-")
        return ("done", ver, ciph, clean(buf.split(b"\r\n")[0].decode("latin-1")))
    finally:
        raw.close()


def probe(binary, host):
    try:
        out = subprocess.run([binary, host], capture_output=True, text=True, timeout=40).stdout.strip()
    except subprocess.TimeoutExpired:
        return [host, "timeout"] + ["-"] * 10
    return out.split("\t") if out else [host, "noout"] + ["-"] * 10


def one(binary, host):
    b = baseline(host)
    time.sleep(0.5)
    p = probe(binary, host)
    return [host] + list(b) + p[1:]


def main():
    src, binary, out = sys.argv[1], sys.argv[2], sys.argv[3]
    limit = int(sys.argv[4]) if len(sys.argv) > 4 else None
    all_hosts, chosen = pick_hosts(src)
    if limit:
        chosen = chosen[:limit]
    print("hosts listed:", len(all_hosts), "domains probed:", len(chosen), flush=True)
    cols = ["host", "b_stage", "b_ver", "b_cipher", "b_header", "m_stage", "m_result", "m_code", "m_err",
            "m_ver", "m_suite", "m_pk", "m_bits", "m_sha256", "m_ms", "m_header"]
    import os
    seen = set()
    if os.path.exists(out):
        with open(out) as f:
            seen = {line.split("\t", 1)[0] for line in f}
    chosen = [h for h in chosen if h not in seen]
    print("resuming, left:", len(chosen), flush=True)
    with open(out, "a") as f, cf.ThreadPoolExecutor(64) as ex:
        if not seen:
            f.write("\t".join(cols) + "\n")
        done = 0
        for row in ex.map(lambda h: one(binary, h), chosen):
            f.write("\t".join(str(x) for x in row) + "\n")
            done += 1
            if done % 200 == 0:
                print("done", done, flush=True)


if __name__ == "__main__":
    main()
