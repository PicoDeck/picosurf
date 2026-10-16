# Gemini TLS handshake survey (2026-10-16)

Main spec section 9.1 asks for a measurement before committing to native Gemini: can PicoDeck's firmware TLS reach real Gemini servers? The firmware runs mbedTLS 3.6.2 with TLS 1.2 only and no Ed25519.

**Answer:** yes. Today's firmware config completes a Gemini request on 95.2% of live capsules. Adding TLS 1.3 raises that to 96.7%. Ed25519 certificates (2.9%) are out of reach for mbedTLS.

## Method

- **Host list:** TLGS known-hosts (`gemini://tlgs.one/known-hosts`), 5,545 hosts.
  - Probed one host per domain: 2,615 domains.
  - Skipped private and loopback addresses, .onion and .i2p, and ports other than 1965.
- **Baseline:** Python with OpenSSL, TLS 1.2-1.3, no certificate check, IPv4.
  - A host counts as live if it returned a Gemini response header.
- **Firmware model:** `gemprobe.c`, built against mbedTLS 3.6.2 from the Pico SDK with PicoDeck's `src/mbedtls_config.h` (`host_config.h`).
  - Only the platform hooks change: stdlib malloc and OS entropy.
  - Client setup matches Mongoose's `mg_tls_init`: `PRESET_DEFAULT`, SNI, and `VERIFY_NONE` (`setInsecure`). IPv4 only.
- **Device check:** a throwaway Lua app (`devapp/`) on 37 sample hosts: three per cipher-suite and key combination, plus 10 predicted failures.
  - It connects with `picocalc.tcp.new(host, 1965, true)` and `setInsecure(true)`, sends the request line, and logs the time and the response header.
  - The app was deleted from the device afterwards.

## Results

| | Live capsules OK | Share |
|---|---|---|
| Firmware config today (TLS 1.2) | 849 / 892 | 95.2% (95.3% counting one transient that passed on retry) |
| With TLS 1.3, RSA-PSS and ChaCha20 (`host_config13.h`) | 863 / 892 | 96.7% |

- **Baseline for the 2,615 domains:**
  - 892 live
  - 915 no TCP connection
  - 749 no DNS
  - 41 failed TLS even with OpenSSL
  - 12 IPv6 only
  - 6 no response
- **TLS 1.2 successes:** every one used ECDHE with AES-GCM.
- **Certificates on those successes:**

  | Key | Hosts |
  |---|---|
  | EC P-256 | 506 |
  | RSA-4096 | 151 |
  | RSA-2048 | 146 |
  | EC P-384 | 43 |
  | RSA-3072 | 2 |
  | RSA-1024 | 1 |

### Failures with today's firmware config (43)

- **26 Ed25519 certificates.** mbedTLS 3.6 cannot do Ed25519, so no config change fixes these.
- **14 TLS 1.3-only servers.** They answer a TLS 1.2 ClientHello with a protocol_version alert, or close the connection. All 14 work with the TLS 1.3 build.
- **3 one-offs:**
  - gemini.dluciv.name is flaky and times out.
  - ur.gs failed once and passed on retry.
  - jeffrey.cam sends a CertificateRequest during the handshake, and mbedTLS fails with FEATURE_UNAVAILABLE.

### Device against the laptop model (37 hosts)

- All 10 predicted failures failed on the device: 5 Ed25519, 4 TLS 1.3-only, and jeffrey.cam.
- 25 of the 27 predicted successes worked on the first run. The two that didn't:
  - **gem.hacking.rip:** no reply within 15 s once, then OK on 3 later tries.
  - **touhey.fr (P-384):** "TLS recv error" on 3 of 4 device tries. The laptop also failed it once later, with a read error, so the host is flaky.
- **Time to connect and handshake on the device** (median; includes network round trips):

  | Certificate | Median | Range |
  |---|---|---|
  | EC P-256 | 2.3 s | 1.3-2.6 s |
  | EC P-384 | 3.9 s | 3.1-4.5 s |
  | RSA-2048 | 1.7 s | 1.1-3.7 s |
  | RSA-4096 | 1.7 s | 1.3-2.2 s |
  | RSA-3072 | 1.4 s | |
  | RSA-1024 | 0.8 s | |

  Gemini opens one connection per request, so every page pays this.

### TLS 1.3 in the firmware

- **Config additions** (`host_config13.h`):
  - `MBEDTLS_PSA_CRYPTO_C`
  - `MBEDTLS_HKDF_C`
  - `MBEDTLS_PKCS1_V21`
  - `MBEDTLS_SSL_PROTO_TLS1_3`
  - `MBEDTLS_SSL_TLS1_3_KEY_EXCHANGE_MODE_EPHEMERAL_ENABLED`
  - `MBEDTLS_SSL_TLS1_3_COMPATIBILITY_MODE`
  - `MBEDTLS_CHACHA20_C`, `MBEDTLS_POLY1305_C`, `MBEDTLS_CHACHAPOLY_C`
  - `MBEDTLS_X509_RSASSA_PSS_SUPPORT`

  The code must call `psa_crypto_init()`; Mongoose already does when `MBEDTLS_PSA_CRYPTO_C` is set. `VERIFY_NONE` works with TLS 1.3 clients in 3.6.2.
- **Pitfalls:**
  - Do not add `MBEDTLS_USE_PSA_CRYPTO`. It broke 20 TLS 1.2-only servers with "Hardware acceleration function returned with error".
  - Without RSA-PSS, TLS 1.3 servers with RSA certificates fail.
  - Without ChaCha20, some TLS 1.3 servers fail.
- **Size:** compiling every library object for Cortex-M33 at `-Os` grows `.text` from 111 KB to 156 KB (+45 KB, an upper bound) and `.bss` by 2 KB.
- **Not measured:** RAM per connection, and handshake time on the device.
- **Scope:** TLS 1.3 changes every HTTPS connection the firmware makes, so it needs PicoDeck's own test pass.

## Reproduce

The scripts are in `gemini-tls-survey/`.

1. Build mbedTLS from `$PICO_SDK_PATH/lib/mbedtls` with one of the configs. Compile `library/*.c` with `-DMBEDTLS_CONFIG_FILE='"host_config.h"'` (or `host_config13.h`) into an archive.
2. Build `gemprobe.c` against that archive with the same define.
3. Fetch the host list from `gemini://tlgs.one/known-hosts` with any Gemini client.
4. Run:
   - `python3 -I survey.py known-hosts.gmi ./gemprobe out.tsv`, then `analyse.py out.tsv`.
   - `diag.sh <host>` explains a failure with OpenSSL.
5. **Device:** push `devapp/` with the picodeck MCP `push_app(..., hidden="dev")`, then run `devrun.py 900 device.log`.
