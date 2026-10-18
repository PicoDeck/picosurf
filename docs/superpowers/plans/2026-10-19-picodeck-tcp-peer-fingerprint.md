# PicoDeck `tcp:peerFingerprint()` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lua TLS sockets report the SHA-256 of the server's certificate (`tcp:peerFingerprint()`), so PicoSurf can pin Gemini certificates; and the simulator's TLS sockets honour `setInsecure`, as the device's do, so a self-signed test server is reachable.

**Architecture:** On the device, Core 1 hashes the peer certificate at `MG_EV_TLS_HS`, before the CONNECTED store, into a new `tcp_conn_t.fingerprint` field; the Lua bridge reads the field once `tcp_get_state()` says CONNECTED or CLOSED, so no new `tcp_*` function is needed (web-sim stubs every one). The simulator fills the same field from curl's `CURLINFO_CERTINFO` with its host mbedTLS.

**Tech Stack:** C (pico-sdk 2.2, Mongoose, mbedTLS 3.6.2), the Lua 5.4 bridge, the SDL simulator (libcurl), pytest e2e with the picotest Lua kit.

**Spec:** `/home/keith/Projects/PicoDeck/picosurf/docs/superpowers/specs/2026-10-17-picosurf-small-web-design.md`, section 10. It sits in the PicoSurf repo because PicoSurf is the first user; this plan changes only the PicoDeck repo (`/home/keith/Projects/PicoDeck/picodeck`).

**Verified before writing:** every change below was built and run in a throwaway worktree of `develop` (9418a24): the firmware (`picodeck.uf2`), `make simulator` and `make simulator-net` build with no warnings in the changed files; `tests/e2e/test_tcp_tls.py` passes, fails when the expected fingerprint is altered, and passed 15 of 15 parallel runs (`-n 6`) alongside `test_network.py` and `test_metatables.py`.

## Global Constraints

- Work on branch `feat/tcp-peer-fingerprint`, off `develop`, in the worktree `/home/keith/Projects/PicoDeck/picodeck/.worktrees/tcp-fingerprint`. Never commit to `develop` or `docs/update-2026-10` directly.
- Core 0 never calls `mg_*` functions; the certificate is hashed on Core 1.
- No new `tcp_*` driver function (web-sim's `platform/web_net_stubs.c` stubs every `http_*`/`tcp_*` the core calls).
- Lua only: the native `PicoCalcAPI` is unchanged and `g_api.version` is not bumped.
- An API change lands in `docs/API-*.md` in the same commit as the behaviour (PicoDeck `CLAUDE.md`).
- Commits use the user's git config, with no attribution lines. Do not push. Do not flash the device.
- Commit messages follow the repo's style: `feat(tcp): ...`, `test(e2e): ...`, `docs(tcp): ...`.

## Review Focus

1. A TLS connect that fails (verification on, self-signed server): `peerFingerprint()` is nil, never a stale value from an earlier connect. Pinned by the `verified_tls_refuses_a_self_signed_server` case.
2. A closed socket object: `peerFingerprint()` returns nil rather than raising. Pinned by the `after close` check in `insecure_tls_reports_the_fingerprint`.
3. A plain socket: nil. Pinned by `plain_sockets_have_no_fingerprint`.
4. A loaded machine (parallel simulators) taking seconds over a handshake: the fixture waits for a settled socket (connected, or failed with an error) for up to 20 s, never a fixed short time. A first draft with `waitConnected(6)` failed 1 run in ~5 under `-n 6`.
5. The device path (`tcp.c`, `wifi.c`) is not reachable from the simulator: the firmware must build, and the device check is PicoSurf's hardware-pass item 24 (the pinned fingerprint equals `openssl x509 -fingerprint -sha256`).

---

## Setup (once, before Task 1)

```bash
cd /home/keith/Projects/PicoDeck/picodeck
git worktree add .worktrees/tcp-fingerprint -b feat/tcp-peer-fingerprint develop
cd .worktrees/tcp-fingerprint
# The repo's worktrees hold copies of the main checkout's third-party code
# (submodules and downloaded sources such as third_party/fatfs/ff.c):
cp -rn ../../third_party/. third_party/
cp -rn ../../apps/gbc/RP2350-GBC/. apps/gbc/RP2350-GBC/
make simulator
SDL_VIDEODRIVER=dummy python3 -m pytest tests/e2e/test_network.py -q
```

Expected: the simulator builds into `build_sim/`; `test_network.py` passes. Run every later command from the worktree root.

---

### Task 1: Simulator TLS sockets: `setInsecure`, and `peerFingerprint()` from curl

**Files:**
- Modify: `src/drivers/tcp.h` (the `fingerprint` field)
- Modify: `src/os/lua_bridge_tcp.c` (`tcp:peerFingerprint()`)
- Modify: `simulator/sim_tcp.c` (honour `insecure`, no ALPN, fill the fingerprint)
- Modify: `simulator/CMakeLists.txt` (link the host mbedTLS into `sim_network`)
- Create: `tests/e2e/certs/selfsigned.pem` (generated)
- Create: `tests/e2e/tcp_tls/main.lua`
- Create: `tests/e2e/test_tcp_tls.py`

**Interfaces:**
- Produces: Lua `tcp:peerFingerprint()` → 64 lowercase hex digits or nil (spec 10). `tcp_conn_t.fingerprint` (`char[65]`, "" when none), cleared by `tcp_connect`, written before the CONNECTED store.

- [ ] **Step 1: Generate the test certificate**

```bash
mkdir -p tests/e2e/certs
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 36500 \
  -subj "/CN=localhost" -keyout /tmp/tcp_tls_key.pem -out /tmp/tcp_tls_cert.pem
cat /tmp/tcp_tls_cert.pem /tmp/tcp_tls_key.pem > tests/e2e/certs/selfsigned.pem
rm /tmp/tcp_tls_key.pem /tmp/tcp_tls_cert.pem
```

The test computes the expected fingerprint from this file, so any certificate generated this way works.

- [ ] **Step 2: Write the Lua fixture**

Create `tests/e2e/tcp_tls/main.lua`:

```lua
-- TLS sockets against a local self-signed server (tests/e2e/test_tcp_tls.py):
-- setInsecure connects, the default refuses, and tcp:peerFingerprint() is
-- the server certificate's SHA-256. The harness writes
-- /data/<APP_ID>/servers.json: {"tls": port, "plain": port, "fingerprint": hex}.
local pc = picocalc
local T = pc.sys.loadlib("picotest")
local cfg = pc.json.decode(pc.fs.readFile("/data/" .. APP_ID .. "/servers.json"))
local HOST = "127.0.0.1"

-- A socket and whether it connected, once it has settled: connected, or
-- failed with an error. A loaded machine (parallel simulators) can take
-- seconds over a handshake, so this waits for the outcome, not a fixed time.
local function connect(port, tls, insecure)
    local s = T.ok(pc.tcp.new(HOST, port, tls), "tcp.new")
    if insecure then s:setInsecure(true) end
    s:setConnectTimeout(15)
    T.ok(s:connect(), "connect refused")
    local deadline = pc.sys.getTimeMs() + 20000
    while not s:isConnected() and not s:error() and pc.sys.getTimeMs() < deadline do
        pc.sys.sleep(20)
    end
    return s, s:isConnected()
end

T.case("insecure_tls_reports_the_fingerprint", function()
    local s, ok = connect(cfg.tls, true, true)
    T.ok(ok, "not connected: " .. tostring(s:error()))
    T.eq(s:peerFingerprint(), cfg.fingerprint)
    s:close()
    T.eq(s:peerFingerprint(), nil, "after close")
end)

T.case("verified_tls_refuses_a_self_signed_server", function()
    local s, ok = connect(cfg.tls, true, false)
    T.ok(not ok, "connected to a self-signed server with verification on")
    T.ok(s:error(), "no error")
    T.eq(s:peerFingerprint(), nil)
    s:close()
end)

T.case("plain_sockets_have_no_fingerprint", function()
    local s, ok = connect(cfg.plain, false, false)
    T.ok(ok, "not connected: " .. tostring(s:error()))
    T.eq(s:peerFingerprint(), nil)
    s:close()
end)

T.case("no_fingerprint_before_connecting", function()
    local s = T.ok(pc.tcp.new(HOST, cfg.tls, true), "tcp.new")
    T.eq(s:peerFingerprint(), nil)
    s:close()
end)

T.done()
```

- [ ] **Step 3: Write the test**

Create `tests/e2e/test_tcp_tls.py`:

```python
"""TLS TCP sockets against a local self-signed server: setInsecure,
verification refusing it, and tcp:peerFingerprint() (the SHA-256 of the
server's certificate, for apps that pin certificates). The certificate in
certs/selfsigned.pem is a fixed EC P-256 test certificate (CN=localhost)."""

import hashlib
import json
import socket
import ssl
import threading
from pathlib import Path

from helpers import E2E_DIR, run_lua_app, stage_lua_app
from net_servers import TcpEchoServer

APP = "tcp_tls"
APP_ID = "com.test.tcp_tls"
APP_SRC = E2E_DIR / "tcp_tls" / "main.lua"
CERT = E2E_DIR / "certs" / "selfsigned.pem"
CASES = ["insecure_tls_reports_the_fingerprint", "verified_tls_refuses_a_self_signed_server",
         "plain_sockets_have_no_fingerprint", "no_fingerprint_before_connecting"]


class TlsEchoServer:
    """Accepts TLS connections with `certfile` on 127.0.0.1 and echoes."""

    def __init__(self, certfile: Path):
        self.ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.ctx.load_cert_chain(str(certfile))
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

    def _handle(self, conn):
        try:
            with self.ctx.wrap_socket(conn, server_side=True) as s:
                s.settimeout(5)
                while data := s.recv(4096):
                    s.sendall(data)
        except (OSError, ssl.SSLError):
            pass

    def stop(self):
        self.sock.close()


def fingerprint(pem_path: Path) -> str:
    """The SHA-256 of the certificate in a PEM file, lowercase hex."""
    pem = pem_path.read_text()
    begin = pem.index("-----BEGIN CERTIFICATE-----")
    end = pem.index("-----END CERTIFICATE-----") + len("-----END CERTIFICATE-----")
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem[begin:end])).hexdigest()


def test_tls_sockets_and_fingerprint(simulator):
    tls = TlsEchoServer(CERT).start()
    plain = TcpEchoServer().start()
    try:
        sd = Path(simulator.sd_card_path)
        stage_lua_app(sd, APP, APP_SRC.read_text(), requirements=["http"], id=APP_ID)
        data = sd / "data" / APP_ID
        data.mkdir(parents=True, exist_ok=True)
        (data / "servers.json").write_text(json.dumps(
            {"tls": tls.port, "plain": plain.port, "fingerprint": fingerprint(CERT)}))
        run = run_lua_app(simulator, APP, timeout=40)
        run.assert_all_passed(CASES)
    finally:
        tls.stop()
        plain.stop()
```

- [ ] **Step 4: Run it to see it fail**

Run: `SDL_VIDEODRIVER=dummy python3 -m pytest tests/e2e/test_tcp_tls.py -q`
Expected: FAIL. `insecure_tls_reports_the_fingerprint` fails with "attempt to call a nil value (method 'peerFingerprint')", or earlier with "not connected" (the simulator verifies every TLS socket today).

- [ ] **Step 5: Apply the change**

Apply this patch from the worktree root (`git apply` reads it from standard input):

````diff
diff --git a/simulator/CMakeLists.txt b/simulator/CMakeLists.txt
index f5962c9..7ae5309 100644
--- a/simulator/CMakeLists.txt
+++ b/simulator/CMakeLists.txt
@@ -323,6 +323,8 @@ else()
         sim_http.c
         sim_tcp.c
     )
+    # sim_tcp.c: the TLS peer certificate's SHA-256 (tcp:peerFingerprint).
+    target_link_libraries(sim_network PRIVATE picodeck_host_mbedtls)
 endif()
 target_include_directories(sim_network PUBLIC
     ${CMAKE_CURRENT_SOURCE_DIR}
diff --git a/simulator/sim_tcp.c b/simulator/sim_tcp.c
index 545f1be..7ec8d47 100644
--- a/simulator/sim_tcp.c
+++ b/simulator/sim_tcp.c
@@ -6,6 +6,8 @@
 #include "os.h"
 
 #include <curl/curl.h>
+#include "mbedtls/base64.h"
+#include "mbedtls/sha256.h"
 #include <stdio.h>
 #include <stdlib.h>
 #include <string.h>
@@ -65,6 +67,39 @@ static void rx_write(tcp_conn_t *c, const uint8_t *data, uint32_t len) {
     c->rx_count += len;
 }
 
+// The lowercase hex SHA-256 of the peer certificate curl saw (CERTINFO's PEM
+// "Cert:" field, decoded), as tcp.c computes it on the device; "" when curl
+// gives none.
+static void sim_peer_fingerprint(CURL *easy, char *out, size_t n) {
+    if (n < 65) return;
+    out[0] = '\0';
+    struct curl_certinfo *ci = NULL;
+    if (curl_easy_getinfo(easy, CURLINFO_CERTINFO, &ci) != CURLE_OK || !ci || ci->num_of_certs < 1)
+        return;
+    for (struct curl_slist *s = ci->certinfo[0]; s; s = s->next) {
+        if (strncmp(s->data, "Cert:", 5) != 0) continue;
+        const char *begin = strstr(s->data, "-----BEGIN CERTIFICATE-----");
+        const char *end = begin ? strstr(begin, "-----END CERTIFICATE-----") : NULL;
+        if (!end) return;
+        begin += strlen("-----BEGIN CERTIFICATE-----");
+        size_t cap = (size_t)(end - begin);
+        unsigned char *b64 = malloc(cap + 1), *der = malloc(cap);
+        size_t len = 0, der_len = 0;
+        if (b64 && der) {
+            for (const char *p = begin; p < end; p++)
+                if (*p != '\n' && *p != '\r' && *p != ' ') b64[len++] = (unsigned char)*p;
+            unsigned char h[32];
+            if (mbedtls_base64_decode(der, cap, &der_len, b64, len) == 0 &&
+                mbedtls_sha256(der, der_len, h, 0) == 0) {
+                for (int i = 0; i < 32; i++) snprintf(out + 2 * i, 3, "%02x", h[i]);
+            }
+        }
+        free(b64);
+        free(der);
+        return;
+    }
+}
+
 // ── Pool management ─────────────────────────────────────────────────────────
 
 void tcp_init(void) {
@@ -118,6 +153,7 @@ bool tcp_connect(tcp_conn_t *c, const char *host, uint16_t port, bool use_ssl) {
     c->pending = 0;
     c->rx_head = c->rx_tail = c->rx_count = 0;
     c->err[0] = '\0';
+    c->fingerprint[0] = '\0';
 
     conn_req_t req = {.type = CONN_REQ_TCP_CONNECT, .conn = (http_conn_t *)c};
     return wifi_req_push(&req);
@@ -247,8 +283,12 @@ void sim_tcp_start_connect(tcp_conn_t *c) {
         snprintf(url, sizeof(url), "https://%s:%u", c->host, (unsigned)c->port);
         curl_easy_setopt(easy, CURLOPT_URL, url);
         curl_easy_setopt(easy, CURLOPT_CONNECT_ONLY, 1L);
-        curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, 1L);
-        curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, 2L);
+        // setInsecure skips the certificate check, as on the device. No ALPN:
+        // the device's Mongoose offers none, and this is a raw TLS socket.
+        curl_easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, c->insecure ? 0L : 1L);
+        curl_easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, c->insecure ? 0L : 2L);
+        curl_easy_setopt(easy, CURLOPT_SSL_ENABLE_ALPN, 0L);
+        curl_easy_setopt(easy, CURLOPT_CERTINFO, 1L);
         curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT, 10L);
 
         // Blocking perform on Core 1 — OK since it's a background thread
@@ -261,6 +301,7 @@ void sim_tcp_start_connect(tcp_conn_t *c) {
             return;
         }
 
+        sim_peer_fingerprint(easy, c->fingerprint, sizeof(c->fingerprint));
         c->pcb = easy;
         s_is_tls[idx] = true;
         c->state = TCP_STATE_CONNECTED;
diff --git a/src/drivers/tcp.h b/src/drivers/tcp.h
index 041c8b9..f2ef0b0 100644
--- a/src/drivers/tcp.h
+++ b/src/drivers/tcp.h
@@ -62,6 +62,10 @@ typedef struct {
     bool     insecure;  // TLS without certificate checks (opt-in, set before connect)
 
     char err[TCP_ERR_MAX];      // written before the FAILED/CLOSED store
+    // Lowercase hex SHA-256 of the TLS peer certificate (DER), "" when none.
+    // Cleared by tcp_connect; written by Core 1 before the CONNECTED store,
+    // so Core 0 reads it once tcp_get_state() returns CONNECTED or later.
+    char fingerprint[65];
     uint32_t pending;  // TCP_CB_* flags (pool lock)
 
     uint8_t *rx_buf;
diff --git a/src/os/lua_bridge_tcp.c b/src/os/lua_bridge_tcp.c
index e880520..6c74e99 100644
--- a/src/os/lua_bridge_tcp.c
+++ b/src/os/lua_bridge_tcp.c
@@ -223,6 +223,22 @@ static int l_tcp_setInsecure(lua_State *L) {
     return 0;
 }
 
+// tcp:peerFingerprint() — the lowercase hex SHA-256 of the TLS server's
+// certificate (DER), or nil: a plain socket, before the handshake, or no
+// certificate. Core 1 writes it before the CONNECTED store (tcp.h).
+static int l_tcp_peerFingerprint(lua_State *L) {
+    tcp_ud_t *ud = check_tcp(L, 1);
+    tcp_conn_t *c = ud->conn;
+    tcp_conn_state_t st = c ? tcp_get_state(c) : TCP_STATE_IDLE;
+    if (!c || !c->use_ssl || (st != TCP_STATE_CONNECTED && st != TCP_STATE_CLOSED) ||
+        c->fingerprint[0] == '\0') {
+        lua_pushnil(L);
+        return 1;
+    }
+    lua_pushstring(L, c->fingerprint);
+    return 1;
+}
+
 // sock:setReadTimeout(seconds) — fail a connected socket that receives
 // nothing for that long; 0 turns it off (the default).
 static int l_tcp_setReadTimeout(lua_State *L) {
@@ -308,6 +324,7 @@ static const luaL_Reg l_tcp_methods[] = {
     {"isConnected", l_tcp_isConnected},
     {"setConnectTimeout", l_tcp_setConnectTimeout},
     {"setInsecure", l_tcp_setInsecure},
+    {"peerFingerprint", l_tcp_peerFingerprint},
     {"setReadTimeout", l_tcp_setReadTimeout},
     {"setConnectCallback", l_tcp_setConnectCallback},
     {"setReadCallback", l_tcp_setReadCallback},
````

What it does: `tcp.h` adds the field; the bridge's `peerFingerprint` returns it only for a TLS socket in CONNECTED or CLOSED; `sim_tcp.c` clears it in `tcp_connect`, sets `CURLOPT_SSL_VERIFYPEER`/`VERIFYHOST` from `c->insecure`, turns ALPN off (the device's Mongoose offers none), asks for `CURLOPT_CERTINFO`, and after the handshake decodes the leaf certificate's PEM and hashes it with the host mbedTLS (`picodeck_host_mbedtls`, which already has `MBEDTLS_BASE64_C` and `MBEDTLS_SHA256_C`).

- [ ] **Step 6: Build and run the tests**

```bash
make simulator
SDL_VIDEODRIVER=dummy python3 -m pytest tests/e2e/test_tcp_tls.py -q
SDL_VIDEODRIVER=dummy python3 -m pytest tests/e2e/test_network.py tests/e2e/test_tcp_tls.py tests/e2e/test_metatables.py -q -n 6
```

Expected: all pass. Run the last command three times; every run passes (Review Focus 4).

- [ ] **Step 7: Commit**

```bash
git add src/drivers/tcp.h src/os/lua_bridge_tcp.c simulator/sim_tcp.c simulator/CMakeLists.txt \
  tests/e2e/certs/selfsigned.pem tests/e2e/tcp_tls/main.lua tests/e2e/test_tcp_tls.py
git commit -m "feat(tcp): tcp:peerFingerprint(); the simulator honours setInsecure on TLS sockets"
```

---

### Task 2: Device: hash the certificate at the end of the handshake; docs

**Files:**
- Modify: `src/drivers/tcp.c` (clear the field in `tcp_connect`; fill it at `MG_EV_TLS_HS`)
- Modify: `src/drivers/wifi.h`, `src/drivers/wifi.c` (`wifi_tls_peer_fingerprint`, and its stub for `SIM_FIRMWARE_NET`)
- Modify: `docs/API-TCP.md` (`conn:peerFingerprint()`, `setInsecure`'s wording)
- Modify: `src/drivers/CLAUDE.md` (TLS policy and TCP sockets notes)

**Interfaces:**
- Consumes: `tcp_conn_t.fingerprint` and `l_tcp_peerFingerprint` from Task 1.
- Produces: `bool wifi_tls_peer_fingerprint(struct mg_connection *nc, char *out, size_t n)` (Core 1, after `MG_EV_TLS_HS`).

- [ ] **Step 1: Apply the change**

````diff
diff --git a/docs/API-TCP.md b/docs/API-TCP.md
index a02899f..375cbd4 100644
--- a/docs/API-TCP.md
+++ b/docs/API-TCP.md
@@ -40,8 +40,29 @@ Completion: `isConnected()`, `waitConnected()`, the connect callback or
 ---
 
 #### `conn:setInsecure(flag)`
-Before `connect()`: TLS without certificate verification or the clock check
-(self-signed development servers only). Default `false`.
+Before `connect()`: TLS without certificate verification or the clock check,
+for self-signed servers: development servers, or servers whose certificate the
+app pins itself with `peerFingerprint()`. Default `false`.
+
+---
+
+#### `conn:peerFingerprint()`
+The SHA-256 of the TLS server's certificate, for apps that pin certificates
+themselves (trust on first use, as Gemini clients do). Works with and without
+`setInsecure`.
+
+- **Returns:** (string or nil) 64 lowercase hex digits once connected, still
+  there after the server closes; `nil` for a plain socket, before the
+  handshake completes, or when the server sent no certificate.
+
+```lua
+local conn = picocalc.tcp.new("example.org", 1965, true)
+conn:setInsecure(true)      -- self-signed: compare the fingerprint instead
+conn:connect()
+if conn:waitConnected(20) and conn:peerFingerprint() ~= pinned then
+    conn:close()            -- not the certificate seen before
+end
+```
 
 ---
 
diff --git a/src/drivers/CLAUDE.md b/src/drivers/CLAUDE.md
index ae78d2f..4aede25 100644
--- a/src/drivers/CLAUDE.md
+++ b/src/drivers/CLAUDE.md
@@ -39,7 +39,7 @@ Subsystem notes for the firmware drivers. The root `CLAUDE.md` holds the cross-c
 ## TLS policy (`wifi.c`, `ca_bundle.c`, `rng.c`)
 - **Verification on by default.** Every HTTPS and `tls://` TCP connection verifies the server certificate (chain to a root in `ca_bundle.c`, validity dates, host name via SNI). Failures reach Lua as `"TLS: certificate not trusted …"` / `"… expired"` / `"… does not match the host name"`.
 - **SNTP gate.** Validity dates need the wall clock, so a verifying connection is refused until SNTP has set it (`clock_is_set()`), with an error starting `"clock not set"` (`WIFI_TLS_ERR_CLOCK`); if SNTP had given up, the refusal restarts it, so a retry a few seconds later works.
-- **Opt-out, per connection:** Lua `conn:setInsecure(true)` (HTTP, before `get`/`post`) or `tcp:setInsecure(true)` (before `connect`); native `http->setInsecure(c, true)` or `tcp->connectEx(host, port, PCTCP_TLS | PCTCP_TLS_INSECURE)`. Skips verification and the clock gate; logs `[TLS] <host>: certificate verification DISABLED`. For self-signed dev servers only.
+- **Opt-out, per connection:** Lua `conn:setInsecure(true)` (HTTP, before `get`/`post`) or `tcp:setInsecure(true)` (before `connect`); native `http->setInsecure(c, true)` or `tcp->connectEx(host, port, PCTCP_TLS | PCTCP_TLS_INSECURE)`. Skips verification and the clock gate; logs `[TLS] <host>: certificate verification DISABLED`. For self-signed servers only: development servers, or apps that pin the certificate themselves (`tcp:peerFingerprint()`, below).
 - **TCP TLS sockets** report connected (`TCP_CB_CONNECT`, writable) only after the handshake (`MG_EV_TLS_HS`); the connect timeout covers the handshake.
 - **CA bundle**: 11 roots chosen from the chains of `store.picodeck.net`, `github.com` and `*.githubusercontent.com`, parsed once at boot (`wifi_tls_init`, on the OS stack) into one chain every verifying connection shares. `tests/unit/test_ca_bundle.c` checks it parses whole and that captured chains verify against it. The root list (with the reason for each) and the add/refresh/check workflow are in `tools/gen_ca_bundle.py` (`ROOTS` and the docstring).
 - **Randomness** (`rng.c`): RP2350 TRNG (von Neumann + CRNGT + autocorrelation health tests; software-reset after every use so pico_rand never meets a halted block) → mbedTLS entropy pool → one CTR_DRBG per core, seeded only at shallow points (Core 0 on the OS stack before `wifi_init`, Core 1 at the top of `core1_entry`); Core 1 draws come from a 512-byte pool that `wifi_poll` refills. Mongoose's `mg_random` (`MG_ENABLE_CUSTOM_RANDOM`) and `picocalc.crypto` use it; `MBEDTLS_ENTROPY_HARDWARE_ALT` (get_rand_64) is off. It fails closed: no seeded/working DRBG → `mg_random` returns false with zeros (no get_rand fallback), TLS is refused, Lua `crypto.randomBytes` raises and native `randomBytes` returns false with the buffer zeroed. The `stack` dev command reports `core1_peak` (Core 1 stack painted at boot) alongside `msp_peak`.
@@ -54,6 +54,7 @@ Subsystem notes for the firmware drivers. The root `CLAUDE.md` holds the cross-c
 - Raw TCP/TLS client on Core 1; pool of 4 (`TCP_MAX_CONNECTIONS`); non-blocking, Core 0 requests, Core 1 handles.
 - Lua callbacks (`setConnectCallback` / `setReadCallback` / `setCloseCallback`) get the socket and fire from `tcp_lua_fire_pending`; events without a callback stay for `getEvents()`. `setConnectTimeout` (next `connect`, default 15 s) and `setReadTimeout` (default off) reach the connection.
 - Data left in Mongoose while the ring was full moves on every poll; buffered data stays readable after the peer closes. A failed `mg_send` fails the socket. Native `tcp->close` releases the slot (the handle is invalid afterwards).
+- `tcp:peerFingerprint()` (Lua only): at `MG_EV_TLS_HS`, before the CONNECTED store, Core 1 hashes the peer certificate (`wifi_tls_peer_fingerprint`: `mbedtls_ssl_get_peer_cert`, kept by `MBEDTLS_SSL_KEEP_PEER_CERTIFICATE`) into `tcp_conn_t.fingerprint`; the bridge reads the field only once `tcp_get_state()` says CONNECTED or CLOSED, so it needs no new `tcp_*` function (web-sim stubs every one). The simulator (`sim_tcp.c`) fills it from curl's `CURLINFO_CERTINFO` with the host mbedTLS, and honours `setInsecure` (it used to verify every TLS socket); `tests/e2e/test_tcp_tls.py` checks both against a local self-signed server.
 
 ## Audio (`audio.c`, `audio_mix.c`, `sound.c`, `wav.c`, `qoa.c`, `fileplayer.c`, `mod_player.c`, `mp3_player.c`, `pcm_stage.h`)
 - PWM output on GP26 (L) / GP27 (R). **One mixer** (`audio_mix.c`, which the simulator shares) sums every source per 44.1 kHz frame: the sample players (`sound.c`), the PCM stream ring (`audio_ring.h`: fileplayer, MOD, the native/Lua stream API) and the square-wave tone. It then applies the master volume and clips (in that order: turned down, a sum over full scale comes out undistorted). `audio.c` is only the output: PWM fed by a DMA channel whose completion interrupt (DMA_IRQ_0, registered on Core 1 by `audio_stream_poll`) renders the next 128 frames with `audio_mix_render`. The output starts with the first sound (`audio_output_ensure_running`, silent buffers first) and runs, silent between sounds, until the app's teardown stops it (`audio_output_stop`). Starting or stopping the stream touches neither the output nor the other sources. While the stream is stopped, pushes are dropped and `audio_ring_free()` reports 0, so the producers that pace on it (fileplayer, MOD) wait rather than race through their data. A started stream goes live (the render takes frames, and an empty ring counts as an underrun) at the first render chunk that finds data, unless it is **held**: `audio_start_stream_held` (the fileplayer's `play()`) and `audio_stream_hold` (its `pause()`, which keeps the ring) take pushes but play nothing until `audio_stream_release`. `audio_stream_drain` (a finished fileplayer) releases it and stops counting: the ring running dry is then the end, not an underrun. `audio_stream_mark_loop` notes a producer's loop point for `audiostat`. #34: started on an empty ring, the fileplayer's stream ran dry whenever Core 0 took the SD card right after `play()` (Nova Rail loads its engine sample then: tens of ms per race); held until the ring is full, the start is covered like any other moment. `audio_apply_clock()` (in `launcher_apply_clock`) re-derives the PWM divider after a clock change such as the video player's 300 MHz boost; the wrap (`OUT_PWM_WRAP` 1511, 1512 counts a frame) gives an exact 8.4 divider at every supported clock, 44,091.7 Hz (-0.02%) at each. Each source has its own lock against the render: `sound.c`'s `s_mix_cs` for the sample players, `audio_mix.c`'s `s_src_cs` for both the stream (starting/stopping: the ring clear, the rate, `s_stream_on`; held/live/ended; the underrun diagnostics) and the tone (all of its state), `mp3_player.c`'s `s_stage_cs` for the MP3 stage — striped spin locks, never nested, never held across SD, PSRAM copies, printf or umm. The MP3 player (`mp3_player.c`) is a source too.
diff --git a/src/drivers/tcp.c b/src/drivers/tcp.c
index 3738f9e..240d710 100644
--- a/src/drivers/tcp.c
+++ b/src/drivers/tcp.c
@@ -182,6 +182,7 @@ bool tcp_connect(tcp_conn_t *c, const char *host, uint16_t port, bool use_ssl) {
     c->port = port;
     c->use_ssl = use_ssl;
     c->err[0] = '\0';
+    c->fingerprint[0] = '\0';
 
     uint32_t save = spin_lock_blocking(s_lock);
     c->pending = 0;
@@ -434,6 +435,10 @@ void tcp_ev_fn(struct mg_connection *nc, int ev, void *ev_data) {
     // timeout keeps running, so a stalled handshake fails like a stalled
     // connect.  Plain TCP is CONNECTED at MG_EV_CONNECT.
     if ((ev == MG_EV_CONNECT && !nc->is_tls) || ev == MG_EV_TLS_HS) {
+        // The peer certificate's fingerprint, before the CONNECTED store
+        // publishes it (lua_bridge_tcp.c reads it only after that store).
+        if (ev == MG_EV_TLS_HS && st_get(c) == TCP_STATE_CONNECTING)
+            wifi_tls_peer_fingerprint(nc, c->fingerprint, sizeof(c->fingerprint));
         uint32_t save = spin_lock_blocking(s_lock);
         if (st_get(c) == TCP_STATE_CONNECTING) {
             c->deadline_connect = 0;
diff --git a/src/drivers/wifi.c b/src/drivers/wifi.c
index 25ef291..8e02fc8 100644
--- a/src/drivers/wifi.c
+++ b/src/drivers/wifi.c
@@ -308,6 +308,7 @@ static bool tls_clock_ready(void) {
 // (Guard: the simulator's SIM_FIRMWARE_NET build runs this file on Mongoose
 // MG_ARCH_UNIX with TLS compiled out, so there is no mbedTLS here; the #else
 // branch below refuses TLS instead.)
+#include "mbedtls/sha256.h"
 
 // The root bundle, parsed ONCE (wifi_tls_init, at boot) into one chain that
 // every connection shares read-only, instead of Mongoose re-parsing ~15 KB
@@ -374,6 +375,18 @@ static bool tls_start(struct mg_connection *nc, const char *host,
   return true;
 }
 
+bool wifi_tls_peer_fingerprint(struct mg_connection *nc, char *out, size_t n) {
+  if (n > 0) out[0] = '\0';
+  if (!nc || !nc->tls || n < 65) return false;
+  struct mg_tls *tls = (struct mg_tls *)nc->tls;
+  const mbedtls_x509_crt *crt = mbedtls_ssl_get_peer_cert(&tls->ssl);
+  if (!crt || !crt->raw.p || crt->raw.len == 0) return false;
+  unsigned char h[32];
+  if (mbedtls_sha256(crt->raw.p, crt->raw.len, h, 0) != 0) return false;
+  for (int i = 0; i < 32; i++) snprintf(out + 2 * i, 3, "%02x", h[i]);
+  return true;
+}
+
 bool wifi_tls_verify_error(struct mg_connection *nc, char *out, size_t n) {
   if (!nc || !nc->tls) return false;
   struct mg_tls *tls = (struct mg_tls *)nc->tls;
@@ -415,6 +428,12 @@ bool wifi_tls_verify_error(struct mg_connection *nc, char *out, size_t n) {
   return false;
 }
 
+bool wifi_tls_peer_fingerprint(struct mg_connection *nc, char *out, size_t n) {
+  (void)nc;
+  if (n > 0) out[0] = '\0';
+  return false;
+}
+
 #endif  // PICODECK_SIM_FIRMWARE_NET
 
 // ── Core 1 request drainer
diff --git a/src/drivers/wifi.h b/src/drivers/wifi.h
index 792c4f1..53fb94e 100644
--- a/src/drivers/wifi.h
+++ b/src/drivers/wifi.h
@@ -166,6 +166,11 @@ bool wifi_tls_init(void);
 struct mg_connection;
 bool wifi_tls_verify_error(struct mg_connection *nc, char *out, size_t n);
 
+// Write the lowercase hex SHA-256 of nc's peer certificate (DER, 64 chars +
+// NUL) to out and return true; "" and false when there is none or n < 65.
+// Core 1, once the handshake is done (MG_EV_TLS_HS).
+bool wifi_tls_peer_fingerprint(struct mg_connection *nc, char *out, size_t n);
+
 // Doorbell number used for Core 0 → Core 1 IPC wake-up.
 // Claimed in wifi_init(); Core 1 registers the ISR in core1_entry().
 #define WIFI_IPC_DOORBELL 0
````

The hash runs before the pool lock is taken (Core 1 is the only writer; Core 0 reads only after the CONNECTED store, which is a release under the lock). `mbedtls_ssl_get_peer_cert` works because `src/mbedtls_config.h` already defines `MBEDTLS_SSL_KEEP_PEER_CERTIFICATE`.

- [ ] **Step 2: Build the firmware**

```bash
mkdir -p build && cd build && cmake .. -DPICO_BOARD=pimoroni_pico_plus2_w_rp2350 && make -j8 2>&1 | tee ../fw-make.log | tail -3; cd ..
grep -n "warning" fw-make.log | grep -c "drivers/wifi.c\|drivers/tcp.c\|lua_bridge_tcp.c"
rm fw-make.log
```

Expected: `build/picodeck.uf2` is produced; the count is `0`.

- [ ] **Step 3: Build the firmware-network simulator**

Run: `make simulator-net 2>&1 | grep -n "error\|warning" | grep "tcp.c\|wifi.c"`
Expected: no output (the build compiles `tcp.c` and `wifi.c`'s `SIM_FIRMWARE_NET` stub).

- [ ] **Step 4: Re-run the simulator tests**

```bash
make simulator
SDL_VIDEODRIVER=dummy python3 -m pytest tests/e2e/test_tcp_tls.py tests/e2e/test_network.py -q -n 4
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/drivers/tcp.c src/drivers/wifi.h src/drivers/wifi.c docs/API-TCP.md src/drivers/CLAUDE.md
git commit -m "feat(tcp): hash the peer certificate at the end of the TLS handshake"
```

---

## Delivery (after the final review)

Per spec 10, this branch is merged into `develop` and into the user's `docs/update-2026-10` (as the system-UI font fix was), through superpowers:finishing-a-development-branch, at the user's choice. Then rebuild the user's simulator in the main checkout (`make simulator` on `docs/update-2026-10`) so PicoSurf's e2e Gemini tests can use it. Flashing the device and pushing to GitHub wait for the user's go-ahead.
