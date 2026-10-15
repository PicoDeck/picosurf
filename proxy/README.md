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

Response headers: `X-Final-Url`, `X-Title`, `X-Mode`, `X-Feed-Url`, `X-Truncated`. Errors are one line of plain text with a status code: 400, 401, 403, 413, 415, 500, 502 or 504.

## Deploy on Cloudflare Workers

1. `cd proxy && npm ci`
2. `npx wrangler login`
3. Make a token with `openssl rand -hex 16`, then run `npx wrangler secret put PROXY_TOKEN` and paste it.
4. Run `npx wrangler deploy`. It prints `https://picosurf-proxy.<account>.workers.dev`. Put that URL and the token into PicoSurf's Settings.

Use the **Workers Paid** plan. The free plan allows 10 ms of CPU per request, which isn't enough for reader mode on large pages or for image resizing.

## Run with Docker

```bash
docker build -t picosurf-proxy proxy
docker run -d --name picosurf --restart unless-stopped -e PROXY_TOKEN=<token> -p 8080:8080 picosurf-proxy
```

Put it behind HTTPS with a certificate from a public CA. For example, with Caddy:

```
picosurf.example.com {
  reverse_proxy localhost:8080
}
```

The device trusts Let's Encrypt, Google Trust Services, SSL.com, DigiCert and Sectigo roots.

## Configuration

| Variable | Required | Meaning |
|---|---|---|
| `PROXY_TOKEN` | yes | Shared secret, at most 128 characters (the device's text input limit). Without it every request gets 500. |
| `USER_AGENT` | no | Overrides `PicoSurfProxy/1 (+https://github.com/PicoDeck/picosurf)` for sites that block unknown agents. |
| `PORT` | no | Node/Docker only; default 8080. |

## Development

- `npm test`: unit tests
- `npm run typecheck`
- `npm run dev`: wrangler dev, which reads `.dev.vars`
- `npm start`: the Node server
- `npm run smoke`: fetches the live smoke list through the handler
- `npm run fixtures:pages` / `npm run fixtures:images`: regenerate test fixtures
