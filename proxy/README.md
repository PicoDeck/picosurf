# PicoSurf proxy

Fetches web pages for the PicoSurf app on PicoDeck. It returns:
- articles as ASCII gemtext (reader mode, via Mozilla Readability)
- feeds as dated link lists
- images as baseline JPEGs that fit within 320×320

It keeps no state, and every request needs your token.

## API

```
GET /v1/ping                                          → 200 "picosurf-proxy 1"
GET /v1/get?url=<absolute URL>[&as=reader|full|feed]
Authorization: Bearer <token>
```

Response headers: `X-Final-Url`, `X-Title`, `X-Mode`, `X-Feed-Url`, `X-Truncated`, `X-Coverage`. Errors are one line of plain text with a status code: 400, 401, 403, 404 (unknown path), 405 (anything but GET), 413, 415, 500, 502 or 504. A 502 caused by the upstream site also carries `X-Upstream-Status`.

Reader mode needs an article of at least 500 characters. An article under 3000 characters must also cover at least a quarter of the page's visible text; otherwise the proxy returns the full page. `X-Coverage` reports that share with two decimals, for example `0.94`. It is sent only in reader mode, and only when the share was measured, which is for articles under 3000 characters.

## Image limits

The two platforms resize images with different code, so their limits differ. An image over its limit gets 413 before it is decoded, as does any image over 10 MiB.
- **Workers** has 128 MB per isolate. The JPEG and WebP decoders and the JPEG encoder each keep a WASM heap for the life of the isolate (16 MiB each to start), so the limits cap how far those heaps can grow:
  - **JPEG:** as many pixels as fit a decoder heap of 48 MiB (`JPEG_HEAP_MAX`), and never more than 8,000,000 (`JPEG_MAX_PIXELS`). The heap holds the file twice and 4 bytes a pixel, plus 2 bytes a DCT coefficient for progressive JPEGs (3 a pixel at 4:2:0, 6 at 4:4:4). So a typical 8 MP baseline photo is allowed, while progressive JPEGs top out at about 5 MP (4:2:0) or 3.5 MP (4:4:4).
  - **WebP:** as many pixels as fit a decoder heap of 32 MiB (`WEBP_HEAP_MAX`), and never more than 2,000,000. The heap holds the file twice and 8 bytes a pixel. A typical lossy WebP gets the full 2 MP.
  - **PNG**, any kind: 100,000,000 pixels (`PNG_STREAM_MAX_PIXELS`), and at most 100,000 pixels each way (`PNG_MAX_SIDE`). PNGs are decoded and scaled one row at a time from a 64 KiB window, so a PNG needs a few MiB beyond its own bytes, however large it is or however far its data expands. The caps limit CPU time, to about 2 s at most.
  - **GIF:** 2,000,000 pixels (`WASM_MAX_PIXELS`).
- **Docker/Node** accepts images up to 16,000,000 pixels.

The limits are in `src/img-wasm.ts` and `src/png-stream.ts`, with the measurements behind them. To measure again in workerd (the runtime Workers use) after changing the image code, run `npx tsx scripts/measure-images.ts workerd` (Linux).

Image jobs in a Worker isolate run one at a time. If a request is cancelled while its image is being resized or waiting its turn (the client went away), the next image waits up to 10 s before going ahead.

Workers also can't decode CMYK or YCCK JPEGs: the WASM build of mozjpeg can't convert them to RGB, so they get 415. Docker/Node decodes them.

## Deploy on Cloudflare Workers

1. `cd proxy && npm ci`
2. `npx wrangler login`
3. Make a token with `openssl rand -hex 16`, then run `npx wrangler secret put PROXY_TOKEN` and paste it.
4. Run `npx wrangler deploy`. It prints `https://picosurf-proxy.<account>.workers.dev`. Put that URL and the token into PicoSurf's Settings.

Use the **Workers Paid** plan. The free plan allows 10 ms of CPU per request, which isn't enough for reader mode on large pages or for image resizing.

## Run with Docker

```bash
docker build -t picosurf-proxy proxy
docker run -d --name picosurf --restart unless-stopped -e PROXY_TOKEN=<token> -p 127.0.0.1:8080:8080 picosurf-proxy
```

The port is published on `127.0.0.1` only. Caddy (below) runs on the same host and reaches it there, and the plain-HTTP port, which would carry the token unencrypted, should not be exposed to the network.

Put it behind HTTPS with a certificate from a public CA. For example, with Caddy:

```
picosurf.example.com {
  reverse_proxy localhost:8080
}
```

The device verifies TLS against a bundle of 11 roots:
- ISRG Root X1
- ISRG Root X2
- GTS Root R1
- GTS Root R4
- SSL.com TLS ECC Root CA 2022
- SSL.com TLS RSA Root CA 2022
- DigiCert Global Root G2
- Sectigo Public Server Authentication Root E46
- Sectigo Public Server Authentication Root R46
- USERTrust ECC Certification Authority
- USERTrust RSA Certification Authority

A certificate from Let's Encrypt, Google Trust Services (Cloudflare) or SSL.com works. For any other CA, check that its chain ends at one of these roots.

## Configuration

| Variable | Required | Meaning |
|---|---|---|
| `PROXY_TOKEN` | yes | Shared secret, at most 128 characters (the device's text input limit). Without it every request gets 500. |
| `USER_AGENT` | no | Overrides `PicoSurfProxy/1 (+https://github.com/PicoDeck/picosurf)` for sites that block unknown agents. |
| `PORT` | no | Node/Docker only; default 8080. |

## Development

The npm commands need Node 22 or newer. `npm run dev` reads `PROXY_TOKEN` from a gitignored `proxy/.dev.vars` file, for example `PROXY_TOKEN=dev-token`.

- `npm test`: unit tests
- `npm run typecheck`
- `npm run dev`: wrangler dev, which reads `.dev.vars`
- `npm start`: the Node server
- `npm run smoke`: fetches the live smoke list through the handler
- `npm run fixtures:pages` / `npm run fixtures:images`: regenerate test fixtures
- `patches/htmlparser2+10.1.0.patch` keeps htmlparser2's tag stack linear (its own is quadratic in nesting depth). `npm ci` applies it and fails if it no longer applies. When bumping htmlparser2 or linkedom, port the change to the new `dist/*/Parser.js`, run `npx patch-package htmlparser2`, and keep `test/parse-linear.test.ts` green.
