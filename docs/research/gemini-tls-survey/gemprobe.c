/* Gemini handshake probe built on mbedTLS with PicoDeck's firmware config.
 * Mirrors Mongoose's client setup: config_defaults(CLIENT, STREAM, DEFAULT),
 * SNI, VERIFY_NONE (setInsecure). IPv4 only, like the device.
 *
 * usage: gemprobe <host> [port]
 * prints one tab-separated line:
 *   host stage ok|err code errtext version suite pk bits sha256 ms header
 */
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "mbedtls/ctr_drbg.h"
#include "mbedtls/entropy.h"
#include "mbedtls/error.h"
#include "mbedtls/net_sockets.h"
#include "mbedtls/sha256.h"
#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"
#ifdef MBEDTLS_PSA_CRYPTO_C
#include "psa/crypto.h"
#endif

static const char *g_host;

static double now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000.0 + t.tv_nsec / 1e6;
}

static void clean(char *s) {
    for (; *s; s++)
        if (*s < 0x20 || *s > 0x7e || *s == '\t') *s = '?';
}

static void out(const char *stage, int code, const char *ver, const char *suite,
                const char *pk, int bits, const char *fp, double ms, const char *hdr) {
    char err[160] = "";
    if (code) mbedtls_strerror(code, err, sizeof err);
    clean(err);
    printf("%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%d\t%s\t%.0f\t%s\n", g_host, stage,
           code ? "err" : "ok", code, err, ver ? ver : "-", suite ? suite : "-",
           pk ? pk : "-", bits, fp ? fp : "-", ms, hdr ? hdr : "-");
}

static int sock_send(void *ctx, const unsigned char *b, size_t n) {
    ssize_t r = send(*(int *)ctx, b, n, MSG_NOSIGNAL);
    if (r < 0) return (errno == EAGAIN || errno == EWOULDBLOCK) ? MBEDTLS_ERR_SSL_TIMEOUT : MBEDTLS_ERR_NET_SEND_FAILED;
    return (int)r;
}

static int sock_recv(void *ctx, unsigned char *b, size_t n) {
    ssize_t r = recv(*(int *)ctx, b, n, 0);
    if (r < 0) return (errno == EAGAIN || errno == EWOULDBLOCK) ? MBEDTLS_ERR_SSL_TIMEOUT : MBEDTLS_ERR_NET_RECV_FAILED;
    return (int)r;
}

static int tcp_connect(const char *host, const char *port, int *fd_out) {
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port, &hints, &res) != 0 || !res) return -1;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    fcntl(fd, F_SETFL, O_NONBLOCK);
    int rc = connect(fd, res->ai_addr, res->ai_addrlen);
    freeaddrinfo(res);
    if (rc < 0 && errno != EINPROGRESS) { close(fd); return -2; }
    struct pollfd p = {fd, POLLOUT, 0};
    if (poll(&p, 1, 8000) != 1) { close(fd); return -2; }
    int soerr = 0;
    socklen_t sl = sizeof soerr;
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl);
    if (soerr) { close(fd); return -2; }
    fcntl(fd, F_SETFL, 0);
    struct timeval tv = {10, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    *fd_out = fd;
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    g_host = argv[1];
    const char *port = argc > 2 ? argv[2] : "1965";
    int fd;
    int c = tcp_connect(g_host, port, &fd);
    if (c == -1) { out("dns", 0, 0, 0, 0, 0, 0, 0, 0); return 0; }
    if (c == -2) { out("connect", 0, 0, 0, 0, 0, 0, 0, 0); return 0; }

    mbedtls_entropy_context ent;
    mbedtls_ctr_drbg_context drbg;
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
#ifdef MBEDTLS_PSA_CRYPTO_C
    psa_crypto_init();
#endif
    mbedtls_entropy_init(&ent);
    mbedtls_ctr_drbg_init(&drbg);
    mbedtls_ssl_init(&ssl);
    mbedtls_ssl_config_init(&conf);
    mbedtls_ctr_drbg_seed(&drbg, mbedtls_entropy_func, &ent, NULL, 0);
    mbedtls_ssl_config_defaults(&conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM,
                                MBEDTLS_SSL_PRESET_DEFAULT);
    mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &drbg);
    mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_NONE);
    mbedtls_ssl_setup(&ssl, &conf);
    mbedtls_ssl_set_hostname(&ssl, g_host);
    mbedtls_ssl_set_bio(&ssl, &fd, sock_send, sock_recv, NULL);

    double t0 = now_ms();
    int rc;
    while ((rc = mbedtls_ssl_handshake(&ssl)) != 0) {
        if (rc != MBEDTLS_ERR_SSL_WANT_READ && rc != MBEDTLS_ERR_SSL_WANT_WRITE) break;
    }
    double ms = now_ms() - t0;
    if (rc != 0) { out("handshake", rc, 0, 0, 0, 0, 0, ms, 0); close(fd); return 0; }

    const char *ver = mbedtls_ssl_get_version(&ssl);
    const char *suite = mbedtls_ssl_get_ciphersuite(&ssl);
    const mbedtls_x509_crt *crt = mbedtls_ssl_get_peer_cert(&ssl);
    const char *pk = "-";
    int bits = 0;
    char fp[65] = "-";
    if (crt) {
        pk = mbedtls_pk_get_name(&crt->pk);
        bits = (int)mbedtls_pk_get_bitlen(&crt->pk);
        unsigned char h[32];
        mbedtls_sha256(crt->raw.p, crt->raw.len, h, 0);
        for (int i = 0; i < 32; i++) sprintf(fp + 2 * i, "%02x", h[i]);
    }

    char req[1100];
    snprintf(req, sizeof req, "gemini://%s/\r\n", g_host);
    rc = mbedtls_ssl_write(&ssl, (const unsigned char *)req, strlen(req));
    if (rc < 0) { out("write", rc, ver, suite, pk, bits, fp, ms, 0); close(fd); return 0; }

    char hdr[1100];
    size_t n = 0;
    while (n < sizeof hdr - 1) {
        rc = mbedtls_ssl_read(&ssl, (unsigned char *)hdr + n, sizeof hdr - 1 - n);
        if (rc == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE) continue;
        if (rc <= 0) break;
        n += rc;
        hdr[n] = 0;
        if (strstr(hdr, "\r\n")) break;
    }
    hdr[n] = 0;
    char *e = strstr(hdr, "\r\n");
    if (e) *e = 0;
    hdr[80] = 0;
    clean(hdr);
    if (n == 0) { out("read", rc < 0 ? rc : 0, ver, suite, pk, bits, fp, ms, 0); close(fd); return 0; }
    out("done", 0, ver, suite, pk, bits, fp, ms, hdr);
    mbedtls_ssl_close_notify(&ssl);
    close(fd);
    return 0;
}
