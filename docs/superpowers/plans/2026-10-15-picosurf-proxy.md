# PicoSurf Proxy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the stateless PicoSurf proxy. It fetches a URL and returns ASCII gemtext for HTML (Readability reader mode with a full-page fallback) and for RSS/Atom feeds, and a baseline JPEG no larger than 320×320 for images. It runs as a Cloudflare Worker or under Node in Docker.

**Architecture:** One platform-neutral handler, `handleRequest(Request, Env, Deps) → Response`. Two thin entry points supply the platform pieces:
- `worker.ts`: the global `fetch` and a WASM image resizer.
- `node.ts`: an undici `fetch` whose DNS lookup refuses private addresses, and a sharp image resizer.

The handler's pipeline is: `safefetch` (SSRF guard, redirects, caps, timeout) → `content` (content kind, charset) → `page` (Readability, then `html2gmi`), `feed` or `img`. ASCII folding happens once, on the way out.

**Tech Stack:** TypeScript 7, vitest 5, wrangler 4 (the same as `PicoDeck/store`), linkedom, @mozilla/readability, fast-xml-parser, ipaddr.js, jSquash (WASM codecs), omggif, sharp, undici, tsx. Node ≥ 22.

**Spec:** `docs/superpowers/specs/2026-10-15-picosurf-design.md`, sections 3, 5, 7.1, 8 and 10. The app is covered by a separate plan.

**Working directories:** run `npm`, `npx` and test commands from `picosurf/proxy/`, and `git` commands from `picosurf/`.

## Global Constraints

- Endpoints: `GET /v1/ping` returns `200 text/plain` `picosurf-proxy 1`. `GET /v1/get?url=<absolute URL>[&as=reader|full|feed]`. Both require `Authorization: Bearer <token>`. The paths match by suffix, so the proxy can be deployed under a subpath.
- Gemtext responses: `Content-Type: text/gemini; charset=us-ascii`. Plain text: `text/plain; charset=us-ascii`. Images: `image/jpeg`.
- Every body and every response header is printable ASCII: 0x20-0x7E plus tab and newline.
- Response headers: `X-Final-Url`, `X-Title`, `X-Mode` (`reader`, `full` or `feed`), `X-Feed-Url`, `X-Truncated: 1`. On a 502 from an upstream error: `X-Upstream-Status`.
- Caps:
  - 5 MB of HTML or feed; 10 MB of image (and of anything whose type has to be sniffed).
  - 256 KB of text output, ending in `(Page truncated)`.
  - Images over 16,000,000 pixels are refused with a 413.
  - Upstream timeout 10 s (covering connect, every redirect and the body); at most 5 redirects.
  - 50 feed items.
  - Reader-mode threshold: 500 characters of article text.
- Images come out as baseline JPEG (SOF0), fitting within 320×320, never enlarged, quality 75, with transparency flattened onto white.
- Upstream `User-Agent`: `PicoSurfProxy/1 (+https://github.com/PicoDeck/picosurf)`, overridable with the `USER_AGENT` environment variable.
- `PROXY_TOKEN` must be set: without it every request gets `500`. Tokens are compared in constant time.
- No state, no cookies, no JavaScript execution.
- Error bodies are one line of `text/plain`, so the device can show them as is.

### Deviations from the spec (decided while planning)

- **Worker runtime tests (spec 7.1):** `@cloudflare/vitest-pool-workers` needs vitest 4, and the store uses vitest 5. Following the store's pattern, tests call the handler directly in Node, and Task 13 checks the real Worker with `wrangler dev`.
- **Single-label host names** (`http://router/`) are blocked as well as the names listed in 5.4.
- **Links with no text** are labelled from `aria-label` or `title` before falling back to host and path.
- **Other `text/*` types** (markdown, CSV) are served as plain text like `text/plain`, rather than refused.
- **windows-1252 and ISO-8859-1** are decoded in-house. Workers' `TextDecoder` may only support UTF-8, according to jSquash's README.

## Review Focus

These are the inputs the spec implies but doesn't spell out, most likely to bite first. Each has a test in the task that owns the code:

1. A page served in windows-1252 or ISO-8859-1 should show curly quotes and accented letters as their ASCII equivalents, not as `?`. Tests in Task 5 and Task 11.
2. A page truncated in the middle of a preformatted block should close the fence before the `(Page truncated)` line. Otherwise the notice renders as code and the fence never closes. Test in Task 11.
3. Page text that starts like gemtext syntax (`# hashtag`, `> quote`, `=>`, `* `, a fence) should render as text, not become a heading, link or quote. Test in Task 6.
4. An image whose `Content-Type` is wrong or missing (WebP labelled `image/jpeg`, no type at all) should be decoded by its sniffed type. Test in Task 11.
5. Feed XML that declares DOCTYPE entities (a billion-laughs attack), or that has HTML markup and entities in its titles, should parse quickly and give clean titles. Test in Task 7.

---

## File Structure

```
.gitignore                           repo root: node_modules, .wrangler, .dev.vars, dist, spike
.github/workflows/ci.yml             proxy job (the app plan adds the Lua job)
proxy/package.json, package-lock.json, tsconfig.json, vitest.config.ts
proxy/wrangler.toml                  Worker config
proxy/Dockerfile, proxy/.dockerignore
proxy/README.md                      API, deploy, configuration
proxy/src/ascii.ts                   foldAscii: Unicode → printable ASCII (spec 5.6)
proxy/src/errors.ts                  ProxyError, BlockedAddressError, textResponse
proxy/src/addr.ts                    isPublicIp, checkHost (spec 5.4)
proxy/src/safefetch.ts               safeFetch: guarded fetch, redirects, caps, timeout
proxy/src/content.ts                 content kind, image type sniffing, charset decoding
proxy/src/text.ts                    collapse, hostPath
proxy/src/html2gmi.ts                DOM → gemtext rules (spec 5.5)
proxy/src/feed.ts                    RSS/Atom/RDF → Feed → gemtext; feed discovery (spec 5.7)
proxy/src/page.ts                    Readability or full page → gemtext with header
proxy/src/imgsize.ts                 image dimensions from headers; JPEG SOF type
proxy/src/img.ts                     Resizer interface, fitWithin, flattenOnWhite, constants
proxy/src/img-sharp.ts               Node resizer (sharp)
proxy/src/img-wasm.ts                Workers resizer (jSquash + omggif)
proxy/src/handler.ts                 routing, auth, dispatch, output cap, folding
proxy/src/lookup.ts                  guardedLookup: DNS-time address check (Node)
proxy/src/node.ts                    nodeDeps, createServer (Node adapter)
proxy/src/serve.ts                   Node entry point
proxy/src/worker.ts                  Workers entry point
proxy/src/wasm.d.ts                  `*.wasm` module type
proxy/scripts/fetch-fixtures.sh      downloads the committed page fixtures
proxy/scripts/make-image-fixtures.ts generates the committed image fixtures
proxy/scripts/smoke.ts               live smoke run over real sites
proxy/test/**                        vitest tests, helpers, fixtures
```

---

### Task 1: Scaffold the proxy package and check the libraries

This task sets up the package and **checks the two assumptions the design depends on** (spec section 10): Readability works on linkedom, and jSquash runs inside the Workers runtime. If either check fails, stop and report back rather than working around it.

**Files:**
- Create: `.gitignore`, `proxy/package.json`, `proxy/tsconfig.json`, `proxy/vitest.config.ts`
- Create: `proxy/scripts/fetch-fixtures.sh`, `proxy/test/fixtures/pages/SOURCES.md`, `proxy/test/fixtures/pages/*.html` (downloaded)
- Test: `proxy/test/libs.test.ts`
- Temporary, never committed: `proxy/spike/worker.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: the package, scripts `test`, `typecheck`, `dev`, `deploy`, `start`, `smoke`, `fixtures:pages` and `fixtures:images`, and the fixtures `test/fixtures/pages/{wikipedia-gemini,mdn-http-status,picodeck-api-tcp}.html`.

- [ ] **Step 1: Create the repo `.gitignore`**

`.gitignore` (repo root):
```
node_modules/
.wrangler/
.dev.vars
dist/
spike/
```

- [ ] **Step 2: Create `proxy/package.json`**

```json
{
  "name": "picosurf-proxy",
  "private": true,
  "type": "module",
  "engines": { "node": ">=22" },
  "scripts": {
    "dev": "wrangler dev",
    "deploy": "wrangler deploy",
    "start": "tsx src/serve.ts",
    "test": "vitest run",
    "typecheck": "tsc --noEmit",
    "smoke": "tsx scripts/smoke.ts",
    "fixtures:pages": "sh scripts/fetch-fixtures.sh",
    "fixtures:images": "tsx scripts/make-image-fixtures.ts"
  }
}
```

- [ ] **Step 3: Install pinned dependencies**

Run (in `proxy/`):
```bash
npm install --save-exact @mozilla/readability@0.6.0 linkedom@0.18.13 fast-xml-parser@5.11.2 ipaddr.js@2.5.0 omggif@1.0.10 @jsquash/jpeg@1.6.0 @jsquash/png@3.1.1 @jsquash/webp@1.5.0 @jsquash/resize@2.1.1 sharp@0.35.5 undici@7.30.0 tsx@4.23.15
npm install --save-dev --save-exact typescript@7.0.2 vitest@5.0.4 wrangler@4.151.0 @types/node@22 @types/omggif@1.0.5
```
Expected: `package-lock.json` is created and there are no `ERR!` lines. tsx stays a runtime dependency because the Docker image runs the TypeScript directly.

- [ ] **Step 4: Create `proxy/tsconfig.json` and `proxy/vitest.config.ts`**

`proxy/tsconfig.json`:
```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ES2022",
    "moduleResolution": "Bundler",
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "types": ["node"],
    "strict": true,
    "noEmit": true,
    "skipLibCheck": true
  },
  "include": ["src", "test", "scripts"]
}
```

`proxy/vitest.config.ts`:
```ts
import { defineConfig } from "vitest/config";

export default defineConfig({ test: { include: ["test/**/*.test.ts"], testTimeout: 30_000 } });
```

- [ ] **Step 5: Create the page-fixture download script and its sources note**

`proxy/scripts/fetch-fixtures.sh`:
```sh
#!/bin/sh
# Downloads the committed page fixtures. Only permissively licensed pages are
# committed (spec 7.1); see test/fixtures/pages/SOURCES.md.
set -eu
dir="$(dirname "$0")/../test/fixtures/pages"
mkdir -p "$dir"
cd "$dir"
UA="PicoSurfProxy/1 (+https://github.com/PicoDeck/picosurf)"
curl -fsSL -A "$UA" -o wikipedia-gemini.html "https://en.wikipedia.org/wiki/Gemini_(protocol)"
curl -fsSL -A "$UA" -o mdn-http-status.html "https://developer.mozilla.org/en-US/docs/Web/HTTP/Status"
curl -fsSL -A "$UA" -o picodeck-api-tcp.html "https://picodeck.net/docs/api-tcp/"
ls -l
```

`proxy/test/fixtures/pages/SOURCES.md`:
```markdown
# Page fixtures

Downloaded with `npm run fixtures:pages`. Re-running it changes the snapshots in `test/__snapshots__/`.

| File | Source | Licence |
|---|---|---|
| wikipedia-gemini.html | https://en.wikipedia.org/wiki/Gemini_(protocol) | CC BY-SA 4.0 |
| mdn-http-status.html | https://developer.mozilla.org/en-US/docs/Web/HTTP/Status | CC BY-SA 2.5 |
| picodeck-api-tcp.html | https://picodeck.net/docs/api-tcp/ | PicoDeck project |
```

Run: `npm run fixtures:pages`
Expected: three `.html` files, each larger than 20 KB.

- [ ] **Step 6: Write the library check test**

`proxy/test/libs.test.ts`:
```ts
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { parseHTML } from "linkedom";
import { Readability } from "@mozilla/readability";

const fixture = (name: string) => readFileSync(new URL(`./fixtures/pages/${name}`, import.meta.url), "utf8");

describe("library assumptions the design rests on", () => {
  it("Readability extracts the Wikipedia article from a linkedom document", () => {
    const { document } = parseHTML(fixture("wikipedia-gemini.html"));
    const article = new Readability(document as unknown as Document).parse();
    expect(article?.title).toBe("Gemini (protocol)");
    expect((article?.textContent ?? "").length).toBeGreaterThan(5000);
  });

  it("Readability mutates the document it parses, so page.ts re-parses for the full-page fallback", () => {
    const { document } = parseHTML(fixture("wikipedia-gemini.html"));
    const before = document.querySelectorAll("*").length;
    new Readability(document as unknown as Document).parse();
    expect(document.querySelectorAll("*").length).not.toBe(before);
  });
});
```

- [ ] **Step 7: Run it**

Run: `npx vitest run test/libs.test.ts`
Expected: 2 passed. **If the first test fails, stop and report** the title and length Readability returned.

- [ ] **Step 8: Check jSquash and Readability inside the Workers runtime (temporary spike)**

Create `proxy/spike/worker.ts`. It's gitignored and deleted in Step 10.
```ts
import { parseHTML } from "linkedom";
import { Readability } from "@mozilla/readability";
import decodeJpeg, { init as initJpegDec } from "@jsquash/jpeg/decode";
import encodeJpeg, { init as initJpegEnc } from "@jsquash/jpeg/encode";
import resize, { initResize } from "@jsquash/resize";
// @ts-expect-error wrangler bundles .wasm imports as WebAssembly.Module
import JPEG_DEC from "../node_modules/@jsquash/jpeg/codec/dec/mozjpeg_dec.wasm";
// @ts-expect-error see above
import JPEG_ENC from "../node_modules/@jsquash/jpeg/codec/enc/mozjpeg_enc.wasm";
// @ts-expect-error see above
import RESIZE from "../node_modules/@jsquash/resize/lib/resize/pkg/squoosh_resize_bg.wasm";

type Init = (m: WebAssembly.Module) => Promise<unknown>;

export default {
  async fetch(req: Request): Promise<Response> {
    const u = new URL(req.url);
    const res = await fetch(u.searchParams.get("url")!);
    if (u.pathname === "/page") {
      const { document } = parseHTML(await res.text());
      const article = new Readability(document as unknown as Document).parse();
      return new Response(`title=${article?.title} chars=${article?.textContent?.length}\n`);
    }
    const hadImageData = typeof (globalThis as { ImageData?: unknown }).ImageData !== "undefined";
    await (initJpegDec as unknown as Init)(JPEG_DEC);
    await (initJpegEnc as unknown as Init)(JPEG_ENC);
    await (initResize as unknown as Init)(RESIZE);
    const image = await decodeJpeg(await res.arrayBuffer());
    const small = await resize(image, { width: 160, height: 120 });
    const out = await encodeJpeg(small, { quality: 75, baseline: true, progressive: false });
    return new Response(out, { headers: { "Content-Type": "image/jpeg", "X-Had-ImageData": String(hadImageData) } });
  },
};
```

Run in one terminal:
```bash
npx wrangler dev spike/worker.ts --port 8787 --compatibility-date 2026-09-01 --compatibility-flags nodejs_compat
```
Run in another:
```bash
curl -s 'http://localhost:8787/page?url=https://en.wikipedia.org/wiki/Gemini_(protocol)'
curl -s -D - 'http://localhost:8787/img?url=https://picsum.photos/800/600.jpg' -o spike/out.jpg | grep -i x-had-imagedata
file spike/out.jpg
```
Expected:
- The first line reads `title=Gemini (protocol) chars=<more than 5000>`.
- `file` reports `JPEG image data, baseline, … 160x120`.
- The `X-Had-ImageData` value says whether Workers provides `ImageData`. Task 10 installs a shim either way.

If the image request fails with `ImageData is not defined`, add this as the spike's first statement and retry:
```ts
(globalThis as { ImageData?: unknown }).ImageData ??= class { constructor(public data: Uint8ClampedArray, public width: number, public height: number) {} };
```
**If it still fails, stop and report the error.**

- [ ] **Step 9: Typecheck the scaffold**

Run: `npm run typecheck`
Expected: no errors. `spike/` is outside `include`.

- [ ] **Step 10: Remove the spike and commit**

```bash
rm -rf proxy/spike
git add .gitignore proxy/package.json proxy/package-lock.json proxy/tsconfig.json proxy/vitest.config.ts proxy/scripts/fetch-fixtures.sh proxy/test/fixtures/pages proxy/test/libs.test.ts
git commit -m "chore(proxy): scaffold package; check Readability on linkedom and jSquash on Workers"
```
Put the spike's two results in the commit body: the Readability output and whether `ImageData` was present.

---

### Task 2: Fold text to ASCII

**Files:**
- Create: `proxy/src/ascii.ts`
- Test: `proxy/test/ascii.test.ts`

**Interfaces:**
- Produces: `foldAscii(input: string): string`. The output contains only 0x20-0x7E, tab and newline.

- [ ] **Step 1: Write the failing test**

`proxy/test/ascii.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import { foldAscii } from "../src/ascii";

describe("foldAscii", () => {
  it.each([
    ["“Hello” — it’s… fine", "\"Hello\" -- it's... fine"],
    ["café naïve façade", "cafe naive facade"],
    ["é", "e"],
    ["ﬁne ①", "fine 1"],
    ["Straße Œuvre Łódź", "Strasse OEuvre Lodz"],
    ["a b c　d", "a b c d"],
    ["20°C ½ €5 ™ © × → ≤", "20 degC 1/2 EUR5 (TM) (c) x -> <="],
    ["• item · dot", "* item * dot"],
    ["x² Ａ", "x2 A"],
    ["ok \u{1f44d}\u{1f3fd} \u{1f1ec}\u{1f1e7} \u{1f468}‍\u{1f469}‍\u{1f467} 1️⃣", "ok    1"],
    ["日本語 текст", "??? ?????"],
    ["tab\tnew\nline\r\u0007bell\u0085­", "tab\tnew\nlinebell"],
    ["plain ASCII ~!@#$%^&*()", "plain ASCII ~!@#$%^&*()"],
  ])("%j → %j", (input, expected) => {
    expect(foldAscii(input)).toBe(expected);
  });

  it("only ever outputs printable ASCII, tab and newline", () => {
    let all = "";
    for (let cp = 0; cp < 0x3000; cp++) all += String.fromCodePoint(cp);
    expect(foldAscii(all)).toMatch(/^[\t\n\x20-\x7e]*$/);
  });
});
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `npx vitest run test/ascii.test.ts`
Expected: FAIL, because `../src/ascii` cannot be resolved.

- [ ] **Step 3: Implement**

`proxy/src/ascii.ts`:
```ts
// Folds text to what PicoDeck's fonts can draw: 0x20-0x7E plus tab and
// newline (spec 5.6). Applied once, by the handler, to everything it sends.

const TABLE: Record<string, string> = {
  "‘": "'", "’": "'", "‚": "'", "‛": "'", "′": "'",
  "“": '"', "”": '"', "„": '"', "‟": '"', "″": '"',
  "«": "<<", "»": ">>", "‹": "<", "›": ">",
  "‐": "-", "‑": "-", "‒": "-", "–": "-", "−": "-",
  "—": "--", "―": "--",
  "…": "...", "•": "*", "·": "*", "‣": "*", "◦": "*",
  "→": "->", "←": "<-", "↔": "<->", "⇒": "=>",
  "≤": "<=", "≥": ">=", "≠": "!=", "≈": "~",
  "×": "x", "÷": "/",
  "©": "(c)", "®": "(R)", "™": "(TM)",
  "€": "EUR", "£": "GBP", "¥": "JPY", "¢": "c",
  "°": " deg",
  "½": "1/2", "¼": "1/4", "¾": "3/4",
  "Æ": "AE", "æ": "ae", "Œ": "OE", "œ": "oe",
  "Ø": "O", "ø": "o", "ß": "ss", "Ł": "L", "ł": "l",
  "Đ": "D", "đ": "d", "Ð": "D", "ð": "d", "Þ": "Th", "þ": "th", "ı": "i",
  "¡": "!", "¿": "?", "§": "S", "¶": "P",
  "†": "+", "‡": "++", "‰": "%o", "ƒ": "f", "ˆ": "^", "˜": "~",
};

const SPACES = /[   -   　]/u;
// Emoji, skin tones, flags, variation selectors, zero-width joiners and spaces, soft hyphen, tag characters.
const REMOVE = /[\p{Extended_Pictographic}\p{Emoji_Modifier}\p{Regional_Indicator}\u{fe00}-\u{fe0f}\u{200b}-\u{200d}\u{2060}\u{feff}\u{00ad}\u{e0020}-\u{e007f}]/u;
const MARKS = /\p{M}/gu;
const PRINTABLE = /^[\x20-\x7e]+$/;

export function foldAscii(input: string): string {
  let out = "";
  for (const ch of input.normalize("NFC")) {
    const cp = ch.codePointAt(0)!;
    if (cp === 0x09 || cp === 0x0a) { out += ch; continue; }
    if (cp < 0x20 || cp === 0x7f || (cp >= 0x80 && cp <= 0x9f)) continue;
    if (cp < 0x80) { out += ch; continue; }
    const mapped = TABLE[ch];
    if (mapped !== undefined) { out += mapped; continue; }
    if (SPACES.test(ch)) { out += " "; continue; }
    if (REMOVE.test(ch)) continue;
    const base = ch.normalize("NFKD").replace(MARKS, "");
    if (base === "") continue; // a lone combining mark
    out += PRINTABLE.test(base) ? base : "?";
  }
  return out;
}
```

- [ ] **Step 4: Run the tests to make sure they pass**

Run: `npx vitest run test/ascii.test.ts`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add proxy/src/ascii.ts proxy/test/ascii.test.ts
git commit -m "feat(proxy): fold text to printable ASCII"
```

---

### Task 3: Errors and address checks

**Files:**
- Create: `proxy/src/errors.ts`, `proxy/src/addr.ts`
- Test: `proxy/test/addr.test.ts`

**Interfaces:**
- Consumes: `foldAscii` (Task 2).
- Produces:
  - `class ProxyError extends Error { status: number; headers: Record<string, string> }`, constructed as `new ProxyError(status, message, headers?)`.
  - `class BlockedAddressError extends Error`.
  - `textResponse(status: number, text: string, headers?: Record<string, string>): Response`: one folded line plus `\n`, with `text/plain; charset=us-ascii` and `Cache-Control: no-store`.
  - `isPublicIp(ip: string): boolean`.
  - `checkHost(hostname: string): void`, which throws `BlockedAddressError`.

- [ ] **Step 1: Write the failing test**

`proxy/test/addr.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import { checkHost, isPublicIp } from "../src/addr";
import { BlockedAddressError, textResponse } from "../src/errors";

describe("isPublicIp", () => {
  it.each(["8.8.8.8", "1.1.1.1", "93.184.216.34", "2606:4700::1111", "2a00:1450:4001:80b::200e"])("%s is public", (ip) => {
    expect(isPublicIp(ip)).toBe(true);
  });
  it.each([
    "127.0.0.1", "10.1.2.3", "172.16.0.1", "192.168.1.1", "169.254.169.254", "100.64.0.1", "0.0.0.0",
    "255.255.255.255", "224.0.0.1", "240.0.0.1", "::1", "::", "fe80::1", "fc00::1", "fd12:3456::1", "ff02::1",
    "::ffff:127.0.0.1", "::ffff:10.0.0.1", "64:ff9b::a00:1", "2002:a00:1::1", "not-an-ip",
  ])("%s is not public", (ip) => {
    expect(isPublicIp(ip)).toBe(false);
  });
});

describe("checkHost", () => {
  it.each(["example.com", "example.com.", "8.8.8.8", "[2606:4700::1111]"])("allows %s", (host) => {
    expect(() => checkHost(host)).not.toThrow();
  });
  it.each(["localhost", "LOCALHOST", "foo.localhost", "printer.local", "db.internal", "router", "127.0.0.1", "[::1]", "[::ffff:7f00:1]"])(
    "blocks %s",
    (host) => {
      expect(() => checkHost(host)).toThrow(BlockedAddressError);
    },
  );
  it.each(["http://2130706433/", "http://0x7f.1/", "http://0177.0.0.1/", "http://127.1/", "http://[::ffff:127.0.0.1]/"])(
    "blocks the URL parser's normalised form of %s",
    (url) => {
      expect(() => checkHost(new URL(url).hostname)).toThrow(BlockedAddressError);
    },
  );
});

describe("textResponse", () => {
  it("sends one folded line of plain text", async () => {
    const res = textResponse(502, "Site returned\n404 “Not Found”", { "X-Upstream-Status": "404" });
    expect(res.status).toBe(502);
    expect(res.headers.get("Content-Type")).toBe("text/plain; charset=us-ascii");
    expect(res.headers.get("Cache-Control")).toBe("no-store");
    expect(res.headers.get("X-Upstream-Status")).toBe("404");
    expect(await res.text()).toBe('Site returned 404 "Not Found"\n');
  });
});
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `npx vitest run test/addr.test.ts`
Expected: FAIL, because the modules cannot be resolved.

- [ ] **Step 3: Implement `errors.ts`**

`proxy/src/errors.ts`:
```ts
import { foldAscii } from "./ascii";

/** An error that becomes an HTTP response: a status and a one-line reason (spec 5.3). */
export class ProxyError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly headers: Record<string, string> = {},
  ) {
    super(message);
    this.name = "ProxyError";
  }
}

/** A host name or address the proxy must not fetch (spec 5.4). */
export class BlockedAddressError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BlockedAddressError";
  }
}

export function textResponse(status: number, text: string, headers: Record<string, string> = {}): Response {
  const line = foldAscii(text).replace(/\s+/g, " ").trim();
  return new Response(line + "\n", {
    status,
    headers: { "Content-Type": "text/plain; charset=us-ascii", "Cache-Control": "no-store", ...headers },
  });
}
```

- [ ] **Step 4: Implement `addr.ts`**

`proxy/src/addr.ts`:
```ts
import ipaddr from "ipaddr.js";
import { BlockedAddressError } from "./errors";

/**
 * True only for globally routable unicast addresses. ipaddr.js names every
 * special range (private, loopback, linkLocal, carrierGradeNat, uniqueLocal,
 * multicast, 6to4, teredo, rfc6052 NAT64, reserved, ...); anything other than
 * "unicast" is refused. IPv4-mapped IPv6 is judged as the IPv4 address.
 */
export function isPublicIp(ip: string): boolean {
  if (!ipaddr.isValid(ip)) return false;
  let addr = ipaddr.parse(ip);
  if (addr.kind() === "ipv6") {
    const v6 = addr as ipaddr.IPv6;
    if (v6.isIPv4MappedAddress()) addr = v6.toIPv4Address();
  }
  return addr.range() === "unicast";
}

const BLOCKED_SUFFIXES = [".localhost", ".local", ".internal"];

/**
 * Throws for host names and IP literals the proxy must not fetch. Pass
 * `new URL(...).hostname`: the WHATWG URL parser has already normalised
 * IPv4 spellings like 2130706433, 0x7f.1 and 0177.0.0.1 to dotted decimal.
 */
export function checkHost(hostname: string): void {
  const host = hostname.toLowerCase().replace(/^\[(.*)\]$/, "$1").replace(/\.$/, "");
  if (ipaddr.isValid(host)) {
    if (!isPublicIp(host)) throw new BlockedAddressError(`Blocked address: ${host}`);
    return;
  }
  if (host === "localhost" || !host.includes(".") || BLOCKED_SUFFIXES.some((s) => host.endsWith(s))) {
    throw new BlockedAddressError(`Blocked host: ${host}`);
  }
}
```

- [ ] **Step 5: Run the tests to make sure they pass**

Run: `npx vitest run test/addr.test.ts`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add proxy/src/errors.ts proxy/src/addr.ts proxy/test/addr.test.ts
git commit -m "feat(proxy): proxy errors and private-address checks"
```

---

### Task 4: safeFetch (redirects, size caps, timeout)

**Files:**
- Create: `proxy/src/safefetch.ts`, `proxy/test/helpers/fakefetch.ts`
- Test: `proxy/test/safefetch.test.ts`

**Interfaces:**
- Consumes: `checkHost` (Task 3), `ProxyError`, `BlockedAddressError` (Task 3).
- Produces:
  ```ts
  type FetchFn = (url: string, init: RequestInit) => Promise<Response>;
  interface SafeFetchOptions { fetch: FetchFn; userAgent: string; timeoutMs?: number }
  interface Upstream {
    finalUrl: string; status: number; statusText: string;
    contentType: string; contentLength: number | null;
    read(limit: number): Promise<Uint8Array>;   // ProxyError 413 past limit
    discard(): void;
  }
  const MAX_REDIRECTS = 5;
  function parseTarget(raw: string): URL;       // ProxyError 400; fragment removed
  function safeFetch(raw: string, opts: SafeFetchOptions): Promise<Upstream>;
  ```
  Non-2xx responses are returned, not thrown. Errors: 400 for a bad URL or scheme, 403 for a blocked host (including through `error.cause`), 413, 502 for unreachable hosts and too many redirects, 504 for timeouts.
  Test helpers: `fakeFetch(routes)`, `html(body, headers?)`, `redirect(to, status?)`.

- [ ] **Step 1: Write the fake-fetch helper**

`proxy/test/helpers/fakefetch.ts`:
```ts
export type Route = Response | ((url: string, init: RequestInit) => Response | Promise<Response>);

/** A fetch that serves fixed routes by exact URL and records every call. */
export function fakeFetch(routes: Record<string, Route>) {
  const calls: { url: string; init: RequestInit }[] = [];
  const fn = async (url: string, init: RequestInit): Promise<Response> => {
    calls.push({ url, init });
    const route = routes[url];
    if (route === undefined) throw new TypeError("fetch failed", { cause: new Error(`no route for ${url}`) });
    return typeof route === "function" ? route(url, init) : route.clone();
  };
  return Object.assign(fn, { calls });
}

export const html = (body: string, headers: Record<string, string> = {}) =>
  new Response(body, { headers: { "Content-Type": "text/html; charset=utf-8", ...headers } });

export const redirect = (to: string, status = 302) => new Response(null, { status, headers: { Location: to } });
```

- [ ] **Step 2: Write the failing test**

`proxy/test/safefetch.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import { BlockedAddressError } from "../src/errors";
import { type FetchFn, safeFetch } from "../src/safefetch";
import { fakeFetch, html, redirect } from "./helpers/fakefetch";

const opts = (fetch: FetchFn, timeoutMs?: number) => ({ fetch, userAgent: "TestUA/1", timeoutMs });
const text = (b: Uint8Array) => new TextDecoder().decode(b);

describe("safeFetch", () => {
  it("returns status, type, length and body, with the fragment removed", async () => {
    const f = fakeFetch({ "https://example.com/a": html("<p>hi</p>", { "Content-Length": "9" }) });
    const up = await safeFetch("https://example.com/a#frag", opts(f));
    expect(up.finalUrl).toBe("https://example.com/a");
    expect(up.status).toBe(200);
    expect(up.contentType).toBe("text/html; charset=utf-8");
    expect(up.contentLength).toBe(9);
    expect(text(await up.read(100))).toBe("<p>hi</p>");
  });

  it("sends the user agent, an Accept header and manual redirects", async () => {
    const f = fakeFetch({ "https://example.com/": html("x") });
    await safeFetch("https://example.com/", opts(f));
    const init = f.calls[0].init;
    expect(init.redirect).toBe("manual");
    expect((init.headers as Record<string, string>)["User-Agent"]).toBe("TestUA/1");
    expect((init.headers as Record<string, string>).Accept).toContain("text/html");
  });

  it("follows relative and absolute redirects", async () => {
    const f = fakeFetch({
      "https://example.com/start": redirect("/next", 301),
      "https://example.com/next": redirect("https://www.example.com/final#x", 308),
      "https://www.example.com/final": html("ok"),
    });
    const up = await safeFetch("https://example.com/start", opts(f));
    expect(up.finalUrl).toBe("https://www.example.com/final");
    expect(text(await up.read(100))).toBe("ok");
    expect(f.calls).toHaveLength(3);
  });

  const chain = (redirects: number) => {
    const routes: Record<string, Response> = {};
    for (let i = 0; i < redirects; i++) routes[`https://example.com/${i}`] = redirect(`/${i + 1}`);
    routes[`https://example.com/${redirects}`] = html("end");
    return fakeFetch(routes);
  };

  it("allows 5 redirects", async () => {
    const up = await safeFetch("https://example.com/0", opts(chain(5)));
    expect(up.finalUrl).toBe("https://example.com/5");
  });

  it("refuses a 6th redirect with 502", async () => {
    await expect(safeFetch("https://example.com/0", opts(chain(6)))).rejects.toMatchObject({ status: 502, message: "Too many redirects" });
  });

  it("refuses a redirect to a blocked address with 403", async () => {
    const f = fakeFetch({ "https://example.com/": redirect("http://169.254.169.254/latest/meta-data") });
    await expect(safeFetch("https://example.com/", opts(f))).rejects.toMatchObject({ status: 403 });
    expect(f.calls).toHaveLength(1);
  });

  it.each(["http://localhost:8080/", "http://[::1]/", "http://10.0.0.1/", "http://router/"])("refuses %s before fetching", async (url) => {
    const f = fakeFetch({});
    await expect(safeFetch(url, opts(f))).rejects.toMatchObject({ status: 403 });
    expect(f.calls).toHaveLength(0);
  });

  it.each(["ftp://example.com/", "gemini://example.com/", "not a url"])("refuses %s with 400", async (url) => {
    await expect(safeFetch(url, opts(fakeFetch({})))).rejects.toMatchObject({ status: 400 });
  });

  it("refuses a body whose Content-Length is over the limit without reading it", async () => {
    const f = fakeFetch({ "https://example.com/": html("x", { "Content-Length": "999999" }) });
    const up = await safeFetch("https://example.com/", opts(f));
    await expect(up.read(1000)).rejects.toMatchObject({ status: 413 });
  });

  it("refuses a streamed body once it passes the limit", async () => {
    const body = new ReadableStream<Uint8Array>({
      start(c) {
        for (let i = 0; i < 3; i++) c.enqueue(new Uint8Array(4));
        c.close();
      },
    });
    const f = fakeFetch({ "https://example.com/": () => new Response(body) });
    const up = await safeFetch("https://example.com/", opts(f));
    await expect(up.read(10)).rejects.toMatchObject({ status: 413 });
  });

  it("times out a hanging connection with 504", async () => {
    const hang = (_u: string, init: RequestInit) =>
      new Promise<Response>((_, reject) => init.signal!.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError"))));
    await expect(safeFetch("https://example.com/", opts(fakeFetch({ "https://example.com/": hang }), 50))).rejects.toMatchObject({ status: 504 });
  });

  it("times out a stalled body with 504", async () => {
    const stall = (_u: string, init: RequestInit) =>
      new Response(
        new ReadableStream<Uint8Array>({
          start(c) {
            c.enqueue(new TextEncoder().encode("<html>"));
            init.signal!.addEventListener("abort", () => c.error(new DOMException("aborted", "AbortError")));
          },
        }),
      );
    const up = await safeFetch("https://example.com/", opts(fakeFetch({ "https://example.com/": stall }), 50));
    await expect(up.read(1000)).rejects.toMatchObject({ status: 504 });
  });

  it("reports an unreachable host with 502 and the underlying reason", async () => {
    const f = fakeFetch({
      "https://nowhere.example/": () => {
        throw new TypeError("fetch failed", { cause: new Error("getaddrinfo ENOTFOUND nowhere.example") });
      },
    });
    await expect(safeFetch("https://nowhere.example/", opts(f))).rejects.toMatchObject({
      status: 502,
      message: "Could not reach nowhere.example: getaddrinfo ENOTFOUND nowhere.example",
    });
  });

  it("turns a BlockedAddressError anywhere in the cause chain into 403", async () => {
    const f = fakeFetch({
      "https://rebind.example/": () => {
        throw new TypeError("fetch failed", { cause: new BlockedAddressError("rebind.example resolves to a blocked address (10.0.0.1)") });
      },
    });
    await expect(safeFetch("https://rebind.example/", opts(f))).rejects.toMatchObject({
      status: 403,
      message: "rebind.example resolves to a blocked address (10.0.0.1)",
    });
  });

  it("returns non-2xx responses for the caller to judge", async () => {
    const f = fakeFetch({ "https://example.com/gone": new Response("no", { status: 404, statusText: "Not Found" }) });
    const up = await safeFetch("https://example.com/gone", opts(f));
    expect(up.status).toBe(404);
    expect(up.statusText).toBe("Not Found");
    up.discard();
  });
});
```

- [ ] **Step 3: Run it to make sure it fails**

Run: `npx vitest run test/safefetch.test.ts`
Expected: FAIL, because `../src/safefetch` cannot be resolved.

- [ ] **Step 4: Implement**

`proxy/src/safefetch.ts`:
```ts
import { checkHost } from "./addr";
import { BlockedAddressError, ProxyError } from "./errors";

export type FetchFn = (url: string, init: RequestInit) => Promise<Response>;

export interface SafeFetchOptions {
  fetch: FetchFn;
  userAgent: string;
  /** Covers connecting, every redirect and reading the body. Default 10 s (spec 5.4). */
  timeoutMs?: number;
}

export interface Upstream {
  finalUrl: string;
  status: number;
  statusText: string;
  contentType: string;
  contentLength: number | null;
  /** Reads the whole body; throws ProxyError 413 past `limit` bytes. */
  read(limit: number): Promise<Uint8Array>;
  /** Drops the body and stops the timer. */
  discard(): void;
}

export const MAX_REDIRECTS = 5;
const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);
const ACCEPT =
  "text/html,application/xhtml+xml,application/rss+xml,application/atom+xml,application/xml;q=0.9,image/*;q=0.8,*/*;q=0.5";

/** Parses a target URL: http or https only, fragment removed. */
export function parseTarget(raw: string): URL {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new ProxyError(400, "Not a valid URL");
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new ProxyError(400, `Unsupported scheme: ${url.protocol.slice(0, -1)}`);
  }
  url.hash = "";
  return url;
}

function guard(url: URL): void {
  try {
    checkHost(url.hostname);
  } catch (e) {
    if (e instanceof BlockedAddressError) throw new ProxyError(403, e.message);
    throw e;
  }
}

function findCause<T extends Error>(e: unknown, type: abstract new (...args: never[]) => T): T | null {
  let cur: unknown = e;
  for (let depth = 0; cur instanceof Error && depth < 6; depth++) {
    if (cur instanceof type) return cur;
    cur = cur.cause;
  }
  return null;
}

export async function safeFetch(raw: string, opts: SafeFetchOptions): Promise<Upstream> {
  let url = parseTarget(raw);
  guard(url);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), opts.timeoutMs ?? 10_000);

  const fail = (e: unknown): never => {
    clearTimeout(timer);
    if (e instanceof ProxyError) throw e;
    if (controller.signal.aborted) throw new ProxyError(504, `${url.host} took too long to respond`);
    const blocked = findCause(e, BlockedAddressError);
    if (blocked) throw new ProxyError(403, blocked.message);
    const reason = e instanceof Error ? (findCause(e.cause, Error)?.message ?? e.message) : String(e);
    throw new ProxyError(502, `Could not reach ${url.host}: ${reason}`);
  };

  const hop = async (target: URL): Promise<Response> => {
    try {
      return await opts.fetch(target.href, {
        method: "GET",
        redirect: "manual",
        signal: controller.signal,
        headers: { "User-Agent": opts.userAgent, Accept: ACCEPT, "Accept-Language": "en;q=0.9, *;q=0.5" },
      });
    } catch (e) {
      return fail(e);
    }
  };

  let res = await hop(url);
  for (let hops = 0; REDIRECT_STATUSES.has(res.status) && res.headers.has("location"); hops++) {
    await res.body?.cancel().catch(() => {});
    if (hops === MAX_REDIRECTS) fail(new ProxyError(502, "Too many redirects"));
    try {
      url = parseTarget(new URL(res.headers.get("location")!, url).href);
      guard(url);
    } catch (e) {
      fail(e);
    }
    res = await hop(url);
  }

  const body = res.body;
  const lengthHeader = res.headers.get("content-length");
  const contentLength = lengthHeader !== null && /^\d+$/.test(lengthHeader) ? Number(lengthHeader) : null;
  const tooLarge = (limit: number) => new ProxyError(413, `Response is larger than ${limit / 1048576} MB`);

  return {
    finalUrl: url.href,
    status: res.status,
    statusText: res.statusText,
    contentType: res.headers.get("content-type") ?? "",
    contentLength,
    async read(limit: number): Promise<Uint8Array> {
      if (contentLength !== null && contentLength > limit) {
        await body?.cancel().catch(() => {});
        return fail(tooLarge(limit));
      }
      if (!body) {
        clearTimeout(timer);
        return new Uint8Array(0);
      }
      const chunks: Uint8Array[] = [];
      let total = 0;
      try {
        const reader = body.getReader();
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          total += value.byteLength;
          if (total > limit) {
            await reader.cancel().catch(() => {});
            throw tooLarge(limit);
          }
          chunks.push(value);
        }
      } catch (e) {
        return fail(e);
      }
      clearTimeout(timer);
      const out = new Uint8Array(total);
      let offset = 0;
      for (const c of chunks) {
        out.set(c, offset);
        offset += c.byteLength;
      }
      return out;
    },
    discard(): void {
      clearTimeout(timer);
      body?.cancel().catch(() => {});
    },
  };
}
```

- [ ] **Step 5: Run the tests to make sure they pass**

Run: `npx vitest run test/safefetch.test.ts`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add proxy/src/safefetch.ts proxy/test/helpers/fakefetch.ts proxy/test/safefetch.test.ts
git commit -m "feat(proxy): safeFetch with redirect, size and time limits"
```

---

### Task 5: Content kind and charset decoding

**Files:**
- Create: `proxy/src/content.ts`
- Test: `proxy/test/content.test.ts`

**Interfaces:**
- Produces:
  ```ts
  type Kind = "html" | "feed" | "image" | "text" | "unsupported";
  type ImageType = "jpeg" | "png" | "webp" | "gif";
  function mimeOf(contentType: string): string;                 // lower-cased essence
  function charsetOf(contentType: string): string | null;
  function kindFromMime(mime: string): Kind | "sniff";          // decided before reading the body
  function sniffKind(bytes: Uint8Array): Kind;                  // after reading, for "sniff"
  function sniffImageType(bytes: Uint8Array): ImageType | null;
  function imageTypeFromMime(mime: string): ImageType | null;
  function decodeText(bytes: Uint8Array, contentType: string): string;
  ```

- [ ] **Step 1: Write the failing test**

`proxy/test/content.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import { charsetOf, decodeText, imageTypeFromMime, kindFromMime, mimeOf, sniffImageType, sniffKind } from "../src/content";

const enc = (s: string) => new TextEncoder().encode(s);
const latin = (s: string) => Uint8Array.from(s, (c) => c.charCodeAt(0));

describe("mimeOf / charsetOf", () => {
  it("parses the essence and charset", () => {
    expect(mimeOf("Text/HTML; Charset=\"UTF-8\"")).toBe("text/html");
    expect(charsetOf("Text/HTML; Charset=\"UTF-8\"")).toBe("utf-8");
    expect(charsetOf("text/html")).toBeNull();
  });
});

describe("kindFromMime", () => {
  it.each([
    ["text/html", "html"], ["application/xhtml+xml", "html"],
    ["application/rss+xml", "feed"], ["application/atom+xml", "feed"], ["application/rdf+xml", "feed"],
    ["image/jpeg", "image"], ["image/jpg", "image"], ["image/png", "image"], ["image/webp", "image"], ["image/gif", "image"],
    ["image/svg+xml", "unsupported"], ["image/avif", "unsupported"], ["application/pdf", "unsupported"],
    ["text/plain", "text"], ["text/markdown", "text"],
    ["text/xml", "sniff"], ["application/xml", "sniff"], ["", "sniff"], ["application/octet-stream", "sniff"],
  ])("%j → %s", (mime, kind) => expect(kindFromMime(mime)).toBe(kind));
});

describe("sniffing", () => {
  const webp = latin("RIFF\0\0\0\0WEBPVP8 ");
  it.each([
    [Uint8Array.of(0xff, 0xd8, 0xff, 0xe0), "jpeg"],
    [Uint8Array.of(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a), "png"],
    [latin("GIF89a"), "gif"],
    [latin("GIF87a"), "gif"],
    [webp, "webp"],
    [enc("hello"), null],
  ])("image type of %#", (bytes, type) => expect(sniffImageType(bytes)).toBe(type));

  it.each([
    [Uint8Array.of(0xff, 0xd8, 0xff, 0xe0), "image"],
    [enc('﻿<?xml version="1.0"?>\n<!-- c -->\n<rss version="2.0"><channel>'), "feed"],
    [enc('<?xml version="1.0" encoding="utf-8"?><feed xmlns="http://www.w3.org/2005/Atom">'), "feed"],
    [enc('<?xml version="1.0"?><rdf:RDF xmlns:rdf="x">'), "feed"],
    [enc("<!DOCTYPE html><html><head>"), "html"],
    [enc("  <!-- generated -->\n<html lang=en>"), "html"],
    [enc("hello world"), "unsupported"],
  ])("kind of %#", (bytes, kind) => expect(sniffKind(bytes)).toBe(kind));

  it("maps image MIME types", () => {
    expect(imageTypeFromMime("image/pjpeg")).toBe("jpeg");
    expect(imageTypeFromMime("image/svg+xml")).toBeNull();
  });
});

describe("decodeText", () => {
  it("defaults to UTF-8 and strips a BOM", () => {
    expect(decodeText(enc("﻿café"), "text/html")).toBe("café");
  });
  it("decodes ISO-8859-1 named in the header", () => {
    expect(decodeText(latin("caf\xe9"), "text/html; charset=ISO-8859-1")).toBe("café");
  });
  it("decodes windows-1252 curly quotes and the euro sign", () => {
    expect(decodeText(latin("\x93hi\x94 \x80"), "text/html; charset=windows-1252")).toBe("“hi” €");
  });
  it("finds the charset in a meta tag", () => {
    const page = latin('<html><head><meta charset="windows-1252"></head><body>\x93q\x94</body></html>');
    expect(decodeText(page, "text/html")).toContain("“q”");
  });
  it("finds the charset in an http-equiv meta tag", () => {
    const page = latin('<meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1"><p>\xe9</p>');
    expect(decodeText(page, "text/html")).toContain("é");
  });
  it("finds the encoding in an XML declaration", () => {
    expect(decodeText(latin('<?xml version="1.0" encoding="ISO-8859-1"?><rss>\xe9</rss>'), "text/xml")).toContain("é");
  });
  it("falls back to UTF-8 for an unknown charset", () => {
    expect(decodeText(enc("ok"), "text/html; charset=x-bogus")).toBe("ok");
  });
});
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `npx vitest run test/content.test.ts`
Expected: FAIL, because `../src/content` cannot be resolved.

- [ ] **Step 3: Implement**

`proxy/src/content.ts`:
```ts
// What the upstream sent (spec 5.2), and how to turn its bytes into text.

export type Kind = "html" | "feed" | "image" | "text" | "unsupported";
export type ImageType = "jpeg" | "png" | "webp" | "gif";

const IMAGE_MIMES: Record<string, ImageType> = {
  "image/jpeg": "jpeg", "image/jpg": "jpeg", "image/pjpeg": "jpeg",
  "image/png": "png", "image/webp": "webp", "image/gif": "gif",
};
const FEED_MIMES = new Set(["application/rss+xml", "application/atom+xml", "application/rdf+xml"]);
const SNIFF_MIMES = new Set(["text/xml", "application/xml", "", "application/octet-stream", "binary/octet-stream"]);

export function mimeOf(contentType: string): string {
  return contentType.split(";")[0].trim().toLowerCase();
}

export function charsetOf(contentType: string): string | null {
  const m = /;\s*charset\s*=\s*"?([^";\s]+)"?/i.exec(contentType);
  return m ? m[1].toLowerCase() : null;
}

/** Decides from the header alone; "sniff" means read the body first and call sniffKind. */
export function kindFromMime(mime: string): Kind | "sniff" {
  if (mime === "text/html" || mime === "application/xhtml+xml") return "html";
  if (FEED_MIMES.has(mime)) return "feed";
  if (mime in IMAGE_MIMES) return "image";
  if (SNIFF_MIMES.has(mime)) return "sniff";
  if (mime.startsWith("text/")) return "text";
  return "unsupported";
}

export function imageTypeFromMime(mime: string): ImageType | null {
  return IMAGE_MIMES[mime] ?? null;
}

export function sniffImageType(b: Uint8Array): ImageType | null {
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "jpeg";
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return "png";
  const head = latin1(b.subarray(0, 16));
  if (head.startsWith("GIF87a") || head.startsWith("GIF89a")) return "gif";
  if (head.startsWith("RIFF") && head.slice(8, 12) === "WEBP") return "webp";
  return null;
}

export function sniffKind(bytes: Uint8Array): Kind {
  if (sniffImageType(bytes)) return "image";
  return sniffMarkup(bytes) ?? "unsupported";
}

function sniffMarkup(bytes: Uint8Array): "html" | "feed" | null {
  let head = latin1(bytes.subarray(0, 2048)).replace(/^ï»¿/, "");
  for (;;) {
    const before = head;
    head = head.replace(/^\s+/, "").replace(/^<\?[\s\S]*?\?>/, "").replace(/^<!--[\s\S]*?-->/, "");
    if (/^<!doctype\s+html/i.test(head)) return "html";
    head = head.replace(/^<!doctype[^>]*>/i, "");
    if (head === before) break;
  }
  if (/^<(rss|feed|rdf:rdf)[\s>]/i.test(head)) return "feed";
  if (/^<(html|head|body)[\s>]/i.test(head)) return "html";
  return null;
}

export function decodeText(bytes: Uint8Array, contentType: string): string {
  if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) return utf8(bytes.subarray(3));
  const label = charsetOf(contentType) ?? sniffCharset(bytes) ?? "utf-8";
  if (label === "utf-8" || label === "utf8") return utf8(bytes);
  if (CP1252_LABELS.has(label)) return cp1252(bytes);
  try {
    return new TextDecoder(label).decode(bytes);
  } catch {
    return utf8(bytes);
  }
}

function sniffCharset(bytes: Uint8Array): string | null {
  const head = latin1(bytes.subarray(0, 1024));
  const m = /<meta[^>]+charset\s*=\s*["']?([\w-]+)/i.exec(head) ?? /<\?xml[^>]+encoding\s*=\s*["']([\w-]+)/i.exec(head);
  return m ? m[1].toLowerCase() : null;
}

const utf8 = (b: Uint8Array) => new TextDecoder("utf-8").decode(b);

// WHATWG maps the ISO-8859-1 and ASCII labels to windows-1252 too.
const CP1252_LABELS = new Set(["windows-1252", "cp1252", "x-cp1252", "iso-8859-1", "iso8859-1", "iso_8859-1", "latin1", "l1", "us-ascii", "ascii"]);
const CP1252_HIGH = [
  0x20ac, 0x81, 0x201a, 0x192, 0x201e, 0x2026, 0x2020, 0x2021, 0x2c6, 0x2030, 0x160, 0x2039, 0x152, 0x8d, 0x17d, 0x8f,
  0x90, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014, 0x2dc, 0x2122, 0x161, 0x203a, 0x153, 0x9d, 0x17e, 0x178,
];

function cp1252(bytes: Uint8Array): string {
  const parts: string[] = [];
  for (let i = 0; i < bytes.length; i += 8192) {
    const codes = Array.from(bytes.subarray(i, i + 8192), (b) => (b >= 0x80 && b <= 0x9f ? CP1252_HIGH[b - 0x80] : b));
    parts.push(String.fromCharCode(...codes));
  }
  return parts.join("");
}

function latin1(bytes: Uint8Array): string {
  const parts: string[] = [];
  for (let i = 0; i < bytes.length; i += 8192) parts.push(String.fromCharCode(...bytes.subarray(i, i + 8192)));
  return parts.join("");
}
```

- [ ] **Step 4: Run the tests to make sure they pass**

Run: `npx vitest run test/content.test.ts`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add proxy/src/content.ts proxy/test/content.test.ts
git commit -m "feat(proxy): content-kind sniffing and charset decoding"
```

---

### Task 6: Convert HTML to gemtext

**Files:**
- Create: `proxy/src/text.ts`, `proxy/src/html2gmi.ts`
- Test: `proxy/test/html2gmi.test.ts`

**Interfaces:**
- Produces:
  ```ts
  // text.ts
  function collapse(s: string): string;       // whitespace runs → one space, trimmed
  function hostPath(url: string): string;     // "host/path", at most 60 chars
  // html2gmi.ts
  interface ConvertOptions { base: string; dropHeading?: string }
  function toGemtext(root: Element, opts: ConvertOptions): string;   // "" or lines ending "\n"; not ASCII-folded
  function pickFromSrcset(srcset: string, target?: number): string | null;
  ```

- [ ] **Step 1: Write the failing tests**

`proxy/test/html2gmi.test.ts`:
````ts
import { describe, expect, it } from "vitest";
import { parseHTML } from "linkedom";
import { type ConvertOptions, pickFromSrcset, toGemtext } from "../src/html2gmi";

const gmi = (body: string, opts: Partial<ConvertOptions> = {}) => {
  const { document } = parseHTML(`<!doctype html><html><head></head><body>${body}</body></html>`);
  return toGemtext(document.body as unknown as Element, { base: "https://example.com/dir/page.html", ...opts });
};

describe("block structure", () => {
  it("maps headings, capping at three levels", () => {
    expect(gmi("<h1>One</h1><h2>Two</h2><h3>Three</h3><h4>Four</h4><h6>Six</h6>")).toBe(
      "# One\n\n## Two\n\n### Three\n\n### Four\n\n### Six\n",
    );
  });

  it("collapses whitespace and splits paragraphs at <br>", () => {
    expect(gmi("<p>Hello   <b>bold</b>\n world</p><p>a<br>b</p>")).toBe("Hello bold world\n\na\nb\n");
  });

  it("drops the first heading that repeats the title", () => {
    expect(gmi("<h1>My  title</h1><p>x</p><h2>My Title</h2>", { dropHeading: "My Title" })).toBe("x\n\n## My Title\n");
  });

  it("flattens lists, numbers ordered ones from start, and separates lists", () => {
    expect(gmi('<ul><li>a</li><li>b <ul><li>c</li></ul></li></ul><ol start="3"><li>x</li><li>y</li></ol>')).toBe(
      "* a\n* b\n* c\n\n* 3. x\n* 4. y\n",
    );
  });

  it("joins paragraphs inside a list item", () => {
    expect(gmi("<ul><li><p>One</p><p>Two</p></li></ul>")).toBe("* One Two\n");
  });

  it("quotes every paragraph of a blockquote", () => {
    expect(gmi("<blockquote><p>q1</p><p>q2 <i>it</i></p></blockquote><p>after</p>")).toBe("> q1\n> q2 it\n\nafter\n");
  });

  it("fences preformatted text with its language, expands tabs and escapes inner fences", () => {
    expect(gmi('<pre><code class="language-lua">local x = 1\n\tif x then\n```nope\nend\n</code></pre>')).toBe(
      "```lua\nlocal x = 1\n    if x then\n ```nope\nend\n```\n",
    );
  });

  it("keeps inline code in backticks", () => {
    expect(gmi("<p>Use <code>a  b</code> now</p>")).toBe("Use `a b` now\n");
  });

  it("writes table rows as cells joined with |, after the caption", () => {
    expect(gmi("<table><caption>Cap</caption><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>")).toBe(
      "Cap\n\nA | B\n1 | 2\n",
    );
  });

  it("walks layout tables (tables containing tables) as containers", () => {
    expect(gmi("<table><tr><td><table><tr><td>a</td><td>b</td></tr></table></td></tr></table>")).toBe("a | b\n");
  });

  it("skips scripts, styles, forms, rules and hidden elements", () => {
    expect(
      gmi(
        '<p>keep</p><script>x</script><style>y</style><nav hidden><p>gone</p></nav><div aria-hidden="true">gone</div>' +
          '<p style="display: none">gone</p><form><p>gone</p></form><hr><p>end</p>',
      ),
    ).toBe("keep\n\nend\n");
  });

  it("makes text lines that look like gemtext syntax plain text (Review Focus 3)", () => {
    expect(gmi("<p># not heading</p><p>=&gt; not link</p><p>* not item</p><p>&gt; not quote</p><p>``` not fence</p>")).toBe(
      " # not heading\n\n => not link\n\n * not item\n\n > not quote\n\n ``` not fence\n",
    );
  });

  it("turns inline runs inside mixed containers into paragraphs", () => {
    expect(gmi("<div>intro <b>text</b><p>para</p>tail</div>")).toBe("intro text\n\npara\n\ntail\n");
  });
});

describe("links and images", () => {
  it("numbers inline links across the page and lists them after each block", () => {
    expect(gmi('<p>See <a href="/a">the docs</a> and <a href="https://x.org/b#frag">B</a>.</p><p>Again <a href="/a">docs</a></p>')).toBe(
      "See the docs [1] and B [2].\n=> https://example.com/a [1] the docs\n=> https://x.org/b [2] B\n\n" +
        "Again docs [1]\n=> https://example.com/a [1] docs\n",
    );
  });

  it("turns blocks that are a single link into plain link lines", () => {
    expect(gmi('<ul><li><a href="/home">Home</a></li><li><a href="about">About</a></li></ul><p><a href="/more">Read more</a></p>')).toBe(
      "=> https://example.com/home Home\n=> https://example.com/dir/about About\n\n=> https://example.com/more Read more\n",
    );
  });

  it("turns a heading that is a single link into a link line", () => {
    expect(gmi('<h2><a href="/p1">Post one</a></h2><p>Summary</p>')).toBe("=> https://example.com/p1 Post one\n\nSummary\n");
  });

  it("drops anchor, javascript, mailto and tel links but keeps their text", () => {
    expect(
      gmi('<p><a href="#top">Top</a> <a href="javascript:void(0)">JS</a> <a href="mailto:a@b.c">Mail</a> <a href="tel:123">Call</a> text</p>'),
    ).toBe("Top JS Mail Call text\n");
  });

  it("labels links without text by aria-label, else host and path", () => {
    expect(gmi('<p>x <a href="https://example.com/rss/feed.xml"><svg></svg></a></p>')).toBe(
      "x\n=> https://example.com/rss/feed.xml example.com/rss/feed.xml\n",
    );
    expect(gmi('<p>x <a href="/share" aria-label="Share this"></a></p>')).toBe("x\n=> https://example.com/share Share this\n");
  });

  it("writes images as [IMG] links, picking the srcset entry nearest 640w", () => {
    expect(
      gmi(
        '<p><img src="/i/a.png" alt="A cat"></p>' +
          '<figure><img srcset="s.jpg 320w, m.jpg 640w, l.jpg 1280w" src="l.jpg"><figcaption>Cap</figcaption></figure>',
      ),
    ).toBe("=> https://example.com/i/a.png [IMG] A cat\n=> https://example.com/dir/m.jpg [IMG] image\n\nCap\n");
  });

  it("uses lazy-load attributes when src is a data: placeholder, and drops data: images", () => {
    expect(gmi('<p><img src="data:image/gif;base64,R0l" data-src="/real.jpg" alt="Lazy"></p><p><img src="data:image/png;base64,xx"></p>')).toBe(
      "=> https://example.com/real.jpg [IMG] Lazy\n",
    );
  });

  it("follows an image inside a link with the link, unless they point to the same place", () => {
    expect(
      gmi(
        '<p><a href="/big.jpg"><img src="/small.jpg" alt="Photo"></a></p>' +
          '<p><a href="/post"><img src="/thumb.jpg" alt="Post"></a></p>' +
          '<p><a href="/same.jpg"><img src="/same.jpg" alt="S"></a></p>',
      ),
    ).toBe(
      "=> https://example.com/small.jpg [IMG] Photo\n=> https://example.com/big.jpg Photo\n" +
        "=> https://example.com/thumb.jpg [IMG] Post\n=> https://example.com/post Post\n" +
        "=> https://example.com/same.jpg [IMG] S\n",
    );
  });

  it("puts a block's images after its text and link lines", () => {
    expect(gmi('<p>Look <img src="/x.png" alt="X"> here <a href="/l">link</a></p>')).toBe(
      "Look here link [1]\n=> https://example.com/l [1] link\n=> https://example.com/x.png [IMG] X\n",
    );
  });

  it("numbers links in table rows", () => {
    expect(gmi('<table><tr><td>1.</td><td><a href="/s">Story</a> (x.org)</td></tr></table>')).toBe(
      "1. | Story [1] (x.org)\n=> https://example.com/s [1] Story\n",
    );
  });

  it("numbers links inside quotes", () => {
    expect(gmi('<blockquote><p>As <a href="/s">source</a> says</p></blockquote>')).toBe(
      "> As source [1] says\n=> https://example.com/s [1] source\n",
    );
  });
});

describe("pickFromSrcset", () => {
  it("prefers the width nearest the target", () => expect(pickFromSrcset("u.jpg 300w,v.jpg 700w")).toBe("v.jpg"));
  it("takes the 1x density candidate", () => expect(pickFromSrcset("a.jpg 1x,b.jpg 2x")).toBe("a.jpg"));
  it("keeps commas inside URLs", () =>
    expect(pickFromSrcset("https://c.com/w_640,h_480/x.jpg 640w, https://c.com/w_1280,h_960/x.jpg 1280w")).toBe(
      "https://c.com/w_640,h_480/x.jpg",
    ));
  it("returns null for an empty srcset", () => expect(pickFromSrcset("  ")).toBeNull());
});
````

- [ ] **Step 2: Run them to make sure they fail**

Run: `npx vitest run test/html2gmi.test.ts`
Expected: FAIL, because `../src/html2gmi` cannot be resolved.

- [ ] **Step 3: Implement `text.ts`**

`proxy/src/text.ts`:
```ts
export function collapse(s: string): string {
  return s.replace(/\s+/g, " ").trim();
}

/** "host/path" for labelling a URL, at most 60 characters. */
export function hostPath(url: string): string {
  try {
    const u = new URL(url);
    return (u.host + (u.pathname === "/" ? "" : u.pathname)).slice(0, 60);
  } catch {
    return url.slice(0, 60);
  }
}
```

- [ ] **Step 4: Implement `html2gmi.ts`**

`proxy/src/html2gmi.ts`:
````ts
// DOM → gemtext (spec 5.5). Works on linkedom documents. Output is not
// ASCII-folded; the handler folds everything once on the way out.

import { collapse, hostPath } from "./text";

export interface ConvertOptions {
  /** Absolute URL that relative links resolve against. */
  base: string;
  /** The first heading whose text equals this (ignoring case) is dropped: it repeats the page title. */
  dropHeading?: string;
}

type Kind = "heading" | "para" | "item" | "quote" | "pre" | "table" | "link" | "image";
interface Block { kind: Kind; lines: string[]; group: number }
interface LinkRef { url: string; label: string }
interface Image { src: string; alt: string; href: string | null }
interface Inline { parts: Array<string | LinkRef>; images: Image[]; bare: LinkRef[] }

const ELEMENT = 1;
const TEXT = 3;
/** Marks a <br> in collected text: private use, so whitespace collapsing keeps it. */
const BR = "";
/** Consecutive blocks of these kinds in the same group get no blank line between them. */
const NO_GAP = new Set<Kind>(["item", "link", "quote", "image"]);
const SKIP = new Set([
  "script", "style", "noscript", "svg", "template", "iframe", "canvas", "video", "audio", "object", "embed",
  "form", "button", "input", "select", "textarea", "hr", "map", "head", "title", "meta", "link",
]);
const BLOCK = new Set([
  "address", "article", "aside", "blockquote", "body", "caption", "center", "dd", "details", "dialog", "div", "dl", "dt",
  "fieldset", "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "html", "li",
  "main", "menu", "nav", "ol", "p", "pre", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
]);
/** Children of <li> that stay their own blocks after the item instead of joining its text. */
const STRUCTURAL = new Set(["ul", "ol", "menu", "pre", "table", "blockquote"]);
const DROPPED_SCHEMES = /^(javascript|mailto|tel|sms|data):/i;
const GEMTEXT_PREFIX = /^(=>|#|\* |>|```)/;

export function toGemtext(root: Element, opts: ConvertOptions): string {
  const converter = new Converter(opts);
  converter.container(root, false);
  return converter.render();
}

const tagOf = (el: Element) => el.tagName.toLowerCase();
const isElement = (n: Node): n is Element => n.nodeType === ELEMENT;
const isRef = (p: string | LinkRef): p is LinkRef => typeof p !== "string";
const emptyInline = (): Inline => ({ parts: [], images: [], bare: [] });

function isHidden(el: Element): boolean {
  return (
    el.hasAttribute("hidden") ||
    el.getAttribute("aria-hidden") === "true" ||
    /display\s*:\s*none/i.test(el.getAttribute("style") ?? "")
  );
}

const skipped = (el: Element) => SKIP.has(tagOf(el)) || isHidden(el);

function plainOf(inl: Inline): string {
  return collapse(inl.parts.map((p) => (typeof p === "string" ? p : p.label)).join("").split(BR).join(" "));
}

/** Picks the srcset candidate whose width is nearest `target`, else the 1x one, else the first. */
export function pickFromSrcset(srcset: string, target = 640): string | null {
  const candidates = srcset
    .split(/,\s+|(?<=\d[wx]),/)
    .map((s) => s.trim().split(/\s+/))
    .filter((p) => p[0])
    .map(([url, d = ""]) => ({ url, w: d.endsWith("w") ? parseInt(d, 10) : null, x: d.endsWith("x") ? parseFloat(d) : 1 }));
  const widths = candidates.filter((c) => c.w !== null);
  if (widths.length) return widths.reduce((a, b) => (Math.abs(b.w! - target) < Math.abs(a.w! - target) ? b : a)).url;
  return (candidates.find((c) => c.x === 1) ?? candidates[0])?.url ?? null;
}

function pickSrc(el: Element): string | null {
  const srcset = el.getAttribute("srcset") ?? el.getAttribute("data-srcset");
  if (srcset) {
    const best = pickFromSrcset(srcset);
    if (best) return best;
  }
  for (const attr of ["src", "data-src", "data-lazy-src", "data-original"]) {
    const value = el.getAttribute(attr)?.trim();
    if (value && !value.startsWith("data:")) return value;
  }
  return null;
}

class Converter {
  private blocks: Block[] = [];
  private numbers = new Map<string, number>();
  private nextNumber = 1;
  private dropHeading: string | null;
  private listDepth = 0;
  private listGroup = 0;

  constructor(private readonly opts: ConvertOptions) {
    this.dropHeading = opts.dropHeading ? collapse(opts.dropHeading).toLowerCase() : null;
  }

  render(): string {
    const out: string[] = [];
    let prev: Block | null = null;
    for (const b of this.blocks) {
      if (prev && !(prev.kind === b.kind && prev.group === b.group && NO_GAP.has(b.kind))) out.push("");
      out.push(...b.lines);
      prev = b;
    }
    return out.length ? out.join("\n") + "\n" : "";
  }

  /** Walks a block container: runs of inline nodes become paragraphs (or quote lines). */
  container(el: Element, quote: boolean): void {
    let run: Node[] = [];
    const flush = () => {
      if (run.length) this.add(this.lines(quote ? "quote" : "para", "", this.inline(run)));
      run = [];
    };
    for (const node of Array.from(el.childNodes)) {
      if (node.nodeType === TEXT) {
        run.push(node);
        continue;
      }
      if (!isElement(node) || skipped(node)) continue;
      if (!BLOCK.has(tagOf(node))) {
        run.push(node);
        continue;
      }
      flush();
      this.block(node, quote);
    }
    flush();
  }

  private block(el: Element, quote: boolean): void {
    const tag = tagOf(el);
    if (/^h[1-6]$/.test(tag)) return this.heading(el, Number(tag[1]));
    if (tag === "ul" || tag === "menu") return this.list(el, false);
    if (tag === "ol") return this.list(el, true);
    if (tag === "blockquote") return this.container(el, true);
    if (tag === "pre") return this.pre(el);
    if (tag === "table") return this.table(el);
    this.container(el, quote);
  }

  private heading(el: Element, level: number): void {
    const inl = this.inline(Array.from(el.childNodes));
    if (this.dropHeading !== null && plainOf(inl).toLowerCase() === this.dropHeading) {
      this.dropHeading = null;
      return;
    }
    this.add(this.lines("heading", "#".repeat(Math.min(level, 3)) + " ", inl));
  }

  private list(el: Element, ordered: boolean): void {
    if (this.listDepth === 0) this.listGroup++;
    this.listDepth++;
    let n = ordered ? (parseInt(el.getAttribute("start") ?? "1", 10) || 1) - 1 : 0;
    for (const child of Array.from(el.children)) {
      if (skipped(child)) continue;
      if (tagOf(child) !== "li") {
        this.block(child, false);
        continue;
      }
      n++;
      const textNodes: Node[] = [];
      const nested: Element[] = [];
      for (const node of Array.from(child.childNodes)) {
        if (isElement(node) && STRUCTURAL.has(tagOf(node))) {
          if (!skipped(node)) nested.push(node);
        } else {
          textNodes.push(node);
        }
      }
      this.add(this.lines("item", ordered ? `* ${n}. ` : "* ", this.inline(textNodes)));
      for (const el2 of nested) this.block(el2, false);
    }
    this.listDepth--;
  }

  private pre(el: Element): void {
    const code = el.querySelector("code");
    const classes = `${el.getAttribute("class") ?? ""} ${code?.getAttribute("class") ?? ""}`;
    const lang = /(?:^|\s)(?:language|lang)-([\w+#.-]+)/.exec(classes)?.[1] ?? "";
    const lines = (el.textContent ?? "")
      .replace(/\r\n?/g, "\n")
      .replace(/\t/g, "    ")
      .split("\n")
      .map((l) => l.replace(/\s+$/, ""));
    while (lines.length && lines[0] === "") lines.shift();
    while (lines.length && lines[lines.length - 1] === "") lines.pop();
    if (!lines.length) return;
    this.add({ kind: "pre", lines: ["```" + lang, ...lines.map((l) => (l.startsWith("```") ? " " + l : l)), "```"] });
  }

  private table(el: Element): void {
    if (el.querySelector("table")) return this.container(el, false); // a layout table
    const caption = el.querySelector("caption");
    if (caption) this.add(this.lines("para", "", this.inline(Array.from(caption.childNodes))));
    const lines: string[] = [];
    for (const tr of Array.from(el.querySelectorAll("tr"))) {
      const inl = emptyInline();
      const cells = Array.from(tr.children).filter((c) => /^t[hd]$/.test(tagOf(c)) && !skipped(c));
      cells.forEach((cell, i) => {
        if (i > 0) inl.parts.push(" | ");
        this.inline(Array.from(cell.childNodes), inl);
      });
      const row = this.lines("para", "", inl);
      if (row) lines.push(...row.lines);
    }
    if (lines.length) this.add({ kind: "table", lines });
  }

  /** Collects inline content: text, links (as LinkRefs), images and <br> markers. */
  private inline(nodes: Node[], into: Inline = emptyInline(), href: string | null = null): Inline {
    for (const node of nodes) {
      if (node.nodeType === TEXT) {
        into.parts.push(node.textContent ?? "");
        continue;
      }
      if (!isElement(node) || skipped(node)) continue;
      const tag = tagOf(node);
      if (tag === "br") into.parts.push(BR);
      else if (tag === "img") {
        const img = this.image(node, href);
        if (img) into.images.push(img);
      } else if (tag === "code" && href === null) into.parts.push("`" + collapse(node.textContent ?? "") + "`");
      else if (tag === "a" && href === null) this.anchor(node, into);
      else {
        const block = BLOCK.has(tag);
        if (block) into.parts.push(" ");
        this.inline(Array.from(node.childNodes), into, href);
        if (block) into.parts.push(" ");
      }
    }
    return into;
  }

  private anchor(a: Element, into: Inline): void {
    const url = this.resolveLink(a.getAttribute("href"));
    if (url === null) {
      this.inline(Array.from(a.childNodes), into);
      return;
    }
    const inner = this.inline(Array.from(a.childNodes), emptyInline(), url);
    into.images.push(...inner.images);
    const label = plainOf(inner);
    if (label) into.parts.push({ url, label });
    else if (inner.images.length === 0) {
      const named = collapse(a.getAttribute("aria-label") || a.getAttribute("title") || "");
      into.bare.push({ url, label: named || hostPath(url) });
    }
  }

  private image(el: Element, href: string | null): Image | null {
    const raw = pickSrc(el);
    const src = raw === null ? null : this.resolve(raw);
    if (src === null || !/^https?:/i.test(src)) return null;
    return { src, alt: collapse(el.getAttribute("alt") ?? ""), href };
  }

  private resolveLink(href: string | null): string | null {
    const h = href?.trim() ?? "";
    if (h === "" || h.startsWith("#") || DROPPED_SCHEMES.test(h)) return null;
    return this.resolve(h);
  }

  private resolve(href: string): string | null {
    try {
      const u = new URL(href, this.opts.base);
      u.hash = "";
      return u.href;
    } catch {
      return null;
    }
  }

  private numberFor(url: string): number {
    let n = this.numbers.get(url);
    if (n === undefined) {
      n = this.nextNumber++;
      this.numbers.set(url, n);
    }
    return n;
  }

  /** Renders collected inline content as a block: text line(s), link lines, then image lines. */
  private lines(kind: Kind, marker: string, inl: Inline): { kind: Kind; lines: string[] } | null {
    const out: string[] = [];
    const plain = plainOf(inl);
    const refs = inl.parts.filter(isRef);
    let outKind = kind;
    if (refs.length === 1 && plain === refs[0].label) {
      out.push(`=> ${refs[0].url} ${refs[0].label}`);
      outKind = "link";
    } else if (plain !== "") {
      const used = new Map<string, { n: number; label: string }>();
      const marked = inl.parts
        .map((p) => {
          if (typeof p === "string") return p;
          const n = this.numberFor(p.url);
          if (!used.has(p.url)) used.set(p.url, { n, label: p.label });
          return `${p.label} [${n}]`;
        })
        .join("");
      const text = marked.split(BR).map(collapse).filter(Boolean);
      if (kind === "para") out.push(...text.map((l) => (GEMTEXT_PREFIX.test(l) ? " " + l : l)));
      else if (kind === "quote") out.push(...text.map((l) => `> ${l}`));
      else out.push(marker + text.join(" "));
      for (const [url, { n, label }] of used) out.push(`=> ${url} [${n}] ${label}`);
    }
    for (const b of inl.bare) out.push(`=> ${b.url} ${b.label}`);
    for (const img of inl.images) {
      out.push(`=> ${img.src} [IMG] ${img.alt || "image"}`);
      if (img.href && img.href !== img.src) out.push(`=> ${img.href} ${img.alt || hostPath(img.href)}`);
    }
    if (out.length === 0) return null;
    if (plain === "" && inl.bare.length === 0) outKind = "image";
    return { kind: outKind, lines: out };
  }

  private add(b: { kind: Kind; lines: string[] } | null): void {
    if (b) this.blocks.push({ ...b, group: this.listDepth > 0 ? this.listGroup : 0 });
  }
}
````

- [ ] **Step 5: Run the tests to make sure they pass**

Run: `npx vitest run test/html2gmi.test.ts`
Expected: all pass. If one fails, compare the output line by line with the rule in spec 5.5. Fix the converter, not the expectation, unless the expectation contradicts the spec.

- [ ] **Step 6: Commit**

```bash
git add proxy/src/text.ts proxy/src/html2gmi.ts proxy/test/html2gmi.test.ts
git commit -m "feat(proxy): convert HTML to gemtext"
```

---

### Task 7: Feeds

**Files:**
- Create: `proxy/src/feed.ts`
- Test: `proxy/test/feed.test.ts`

**Interfaces:**
- Consumes: `collapse`, `hostPath` (Task 6).
- Produces:
  ```ts
  interface FeedItem { url: string; title: string; time: number | null }   // time: ms since epoch
  interface Feed { title: string; items: FeedItem[] }                      // ≤ 50, dated newest first, then undated in feed order
  const MAX_ITEMS = 50;
  function parseFeed(xml: string, base: string): Feed | null;              // RSS 2.0, Atom, RSS 1.0 (RDF)
  function feedToGemtext(feed: Feed): string;                              // "# title\n\n=> url YYYY-MM-DD title\n..."
  function findFeedLink(doc: Document, base: string): string | null;
  ```

- [ ] **Step 1: Write the failing test**

`proxy/test/feed.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import { parseHTML } from "linkedom";
import { MAX_ITEMS, feedToGemtext, findFeedLink, parseFeed } from "../src/feed";

const BASE = "https://blog.example.com/feed.xml";

describe("parseFeed", () => {
  it("reads RSS 2.0: dates, guid permalinks, relative links, entities and markup in titles", () => {
    const xml = `<?xml version="1.0"?><rss version="2.0"><channel><title>My &amp; Blog</title>
      <item><title>Older</title><link>/older</link><pubDate>Mon, 12 Oct 2026 08:00:00 GMT</pubDate></item>
      <item><title><![CDATA[<b>Newer</b>&nbsp;post]]></title><link>https://blog.example.com/newer#c</link><pubDate>Tue, 13 Oct 2026 09:30:00 +0000</pubDate></item>
      <item><title>No date</title><guid>https://blog.example.com/undated</guid></item>
      <item><title>Not a permalink</title><guid isPermaLink="false">tag:x,1</guid></item>
    </channel></rss>`;
    const feed = parseFeed(xml, BASE)!;
    expect(feed.title).toBe("My & Blog");
    expect(feed.items.map((i) => [i.url, i.title])).toEqual([
      ["https://blog.example.com/newer", "Newer post"],
      ["https://blog.example.com/older", "Older"],
      ["https://blog.example.com/undated", "No date"],
    ]);
    expect(feed.items[2].time).toBeNull();
  });

  it("reads Atom: alternate links over self, updated when there is no published date, HTML titles", () => {
    const xml = `<feed xmlns="http://www.w3.org/2005/Atom"><title type="html">Atom &lt;i&gt;Site&lt;/i&gt;</title>
      <entry><title>First</title><link rel="self" href="https://a.example/self"/><link rel="alternate" type="text/html" href="/posts/1"/>
        <published>2026-10-01T10:00:00Z</published></entry>
      <entry><title>Second</title><link href="https://a.example/posts/2"/><updated>2026-10-05T10:00:00Z</updated></entry>
    </feed>`;
    const feed = parseFeed(xml, "https://a.example/atom.xml")!;
    expect(feed.title).toBe("Atom Site");
    expect(feed.items.map((i) => i.url)).toEqual(["https://a.example/posts/2", "https://a.example/posts/1"]);
  });

  it("reads RSS 1.0 (RDF) with dc:date", () => {
    const xml = `<?xml version="1.0"?><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/">
      <channel><title>RDF Site</title></channel>
      <item><title>R1</title><link>https://r.example/1</link><dc:date>2026-10-02T00:00:00Z</dc:date></item>
    </rdf:RDF>`;
    const feed = parseFeed(xml, "https://r.example/rss")!;
    expect(feed.title).toBe("RDF Site");
    expect(feed.items).toEqual([{ url: "https://r.example/1", title: "R1", time: Date.parse("2026-10-02T00:00:00Z") }]);
  });

  it("does not expand DOCTYPE entities (Review Focus 5)", () => {
    const bomb = `<?xml version="1.0"?><!DOCTYPE rss [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;"><!ENTITY c "&b;&b;&b;&b;&b;&b;&b;&b;&b;&b;">]>
      <rss version="2.0"><channel><title>T &c;</title><item><title>i</title><link>https://e.example/1</link></item></channel></rss>`;
    // Whether the parser keeps or rejects the now-undefined &c; doesn't matter; it must never expand.
    expect(parseFeed(bomb, "https://e.example/feed")?.title ?? "").not.toContain("aaaa");
  });

  it("keeps the newest 50 items", () => {
    const items = Array.from(
      { length: 60 },
      (_, i) => `<item><title>P${i}</title><link>https://e.example/${i}</link><pubDate>${new Date(Date.UTC(2026, 0, 1 + i)).toUTCString()}</pubDate></item>`,
    ).join("");
    const feed = parseFeed(`<rss><channel><title>T</title>${items}</channel></rss>`, "https://e.example/f")!;
    expect(feed.items).toHaveLength(MAX_ITEMS);
    expect(feed.items[0].title).toBe("P59");
  });

  it("falls back to the host for a missing title and (untitled) for items", () => {
    const feed = parseFeed("<rss><channel><item><link>https://e.example/x</link></item></channel></rss>", "https://e.example/feed")!;
    expect(feed.title).toBe("e.example/feed");
    expect(feed.items[0].title).toBe("(untitled)");
  });

  it.each(["hello", "<html><body>no</body></html>"])("returns null for %j", (xml) => {
    expect(parseFeed(xml, BASE)).toBeNull();
  });
});

describe("feedToGemtext", () => {
  it("writes a title and dated link lines", () => {
    const text = feedToGemtext({
      title: "Blog",
      items: [
        { url: "https://b.example/2", title: "Two", time: Date.parse("2026-10-13T09:30:00Z") },
        { url: "https://b.example/u", title: "Undated", time: null },
      ],
    });
    expect(text).toBe("# Blog\n\n=> https://b.example/2 2026-10-13 Two\n=> https://b.example/u Undated\n");
  });
});

describe("findFeedLink", () => {
  it("returns the first RSS or Atom alternate link, resolved", () => {
    const { document } = parseHTML(`<html><head>
      <link rel="stylesheet" href="/s.css"><link rel="alternate" type="application/json" href="/feed.json">
      <link rel="alternate" type="application/atom+xml" href="/atom.xml"><link rel="alternate" type="application/rss+xml" href="/rss.xml">
      </head><body></body></html>`);
    expect(findFeedLink(document as unknown as Document, "https://b.example/post/1")).toBe("https://b.example/atom.xml");
  });
  it("returns null without one", () => {
    const { document } = parseHTML("<html><head></head><body></body></html>");
    expect(findFeedLink(document as unknown as Document, "https://b.example/")).toBeNull();
  });
});
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `npx vitest run test/feed.test.ts`
Expected: FAIL, because `../src/feed` cannot be resolved.

- [ ] **Step 3: Implement**

`proxy/src/feed.ts`:
```ts
// RSS 2.0 / Atom / RSS 1.0 → a list of dated links (spec 5.7).

import { XMLParser } from "fast-xml-parser";
import { collapse, hostPath } from "./text";

export interface FeedItem { url: string; title: string; time: number | null }
export interface Feed { title: string; items: FeedItem[] }

export const MAX_ITEMS = 50;

const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "@_",
  textNodeName: "#text",
  parseTagValue: false,
  parseAttributeValue: false,
  trimValues: true,
  processEntities: true,
  htmlEntities: true,
  isArray: (name: string) => name === "item" || name === "entry" || name === "link",
});

// fast-xml-parser returns loosely typed trees; `X` marks those values.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type X = any;

export function parseFeed(xml: string, base: string): Feed | null {
  let doc: X;
  try {
    // Drop the DOCTYPE so no declared entity is ever expanded.
    doc = parser.parse(xml.replace(/<!DOCTYPE[^>[]*(\[[\s\S]*?\])?\s*>/i, ""));
  } catch {
    return null;
  }
  if (doc?.rss?.channel) return rss(doc.rss.channel, base);
  if (doc?.feed) return atom(doc.feed, base);
  const rdf = doc?.["rdf:RDF"];
  if (rdf) return rss({ ...(rdf.channel ?? {}), item: rdf.item }, base);
  return null;
}

function rss(channel: X, base: string): Feed {
  const items = asArray(channel.item).map((it: X) => ({
    url: resolve(textOf(it.link) || permalink(it.guid), base),
    title: cleanTitle(textOf(it.title)),
    time: parseDate(textOf(it.pubDate) || textOf(it["dc:date"])),
  }));
  return finish(cleanTitle(textOf(channel.title)) || hostPath(base), items);
}

function atom(feed: X, base: string): Feed {
  const items = asArray(feed.entry).map((e: X) => ({
    url: resolve(atomLink(e.link), base),
    title: cleanTitle(textOf(e.title)),
    time: parseDate(textOf(e.published) || textOf(e.updated)),
  }));
  return finish(cleanTitle(textOf(feed.title)) || hostPath(base), items);
}

function atomLink(links: X): string {
  const list = asArray(links);
  const rel = (l: X) => (typeof l === "object" && l["@_rel"]) || "alternate";
  const type = (l: X) => (typeof l === "object" && l["@_type"]) || "";
  const pick =
    list.find((l: X) => rel(l) === "alternate" && (!type(l) || /html/.test(type(l)))) ??
    list.find((l: X) => rel(l) === "alternate") ??
    list[0];
  if (pick === undefined) return "";
  return typeof pick === "object" ? (pick["@_href"] ?? textOf(pick)) : String(pick);
}

function permalink(guid: X): string {
  if (guid === undefined) return "";
  if (typeof guid === "object" && guid["@_isPermaLink"] === "false") return "";
  const value = textOf(guid);
  return /^https?:\/\//i.test(value) ? value : "";
}

function finish(title: string, raw: FeedItem[]): Feed {
  const items = raw.filter((i) => i.url !== "").map((i) => ({ ...i, title: i.title || "(untitled)" }));
  const dated = items.filter((i) => i.time !== null).sort((a, b) => b.time! - a.time!);
  const undated = items.filter((i) => i.time === null);
  return { title, items: [...dated, ...undated].slice(0, MAX_ITEMS) };
}

function asArray(v: X): X[] {
  return v === undefined || v === null ? [] : Array.isArray(v) ? v : [v];
}

function textOf(v: X): string {
  if (v === undefined || v === null) return "";
  if (typeof v === "string" || typeof v === "number") return String(v);
  if (Array.isArray(v)) return textOf(v[0]);
  if (typeof v === "object" && "#text" in v) return String(v["#text"]);
  return "";
}

const NAMED_ENTITIES: Record<string, string> = {
  amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ",
  mdash: "—", ndash: "–", hellip: "…", lsquo: "‘", rsquo: "’", ldquo: "“", rdquo: "”",
};

/** Decodes HTML entities left in titles (CDATA sections and double-escaped feeds keep them). */
function decodeEntities(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (whole, e: string) => {
    if (e[0] === "#") {
      const cp = e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return cp > 0 && cp <= 0x10ffff ? String.fromCodePoint(cp) : whole;
    }
    return NAMED_ENTITIES[e.toLowerCase()] ?? whole;
  });
}

/** Strips markup that HTML-typed titles carry, decodes entities, collapses whitespace. */
function cleanTitle(s: string): string {
  return collapse(decodeEntities(s.replace(/<[^>]*>/g, " ")));
}

function parseDate(s: string): number | null {
  if (!s) return null;
  const t = Date.parse(s.trim());
  return Number.isNaN(t) ? null : t;
}

function resolve(link: string, base: string): string {
  if (!link.trim()) return "";
  try {
    const u = new URL(link.trim(), base);
    u.hash = "";
    return u.href;
  } catch {
    return "";
  }
}

export function feedToGemtext(feed: Feed): string {
  const lines = [`# ${feed.title}`, ""];
  for (const item of feed.items) {
    const date = item.time === null ? "" : new Date(item.time).toISOString().slice(0, 10) + " ";
    lines.push(`=> ${item.url} ${date}${item.title}`);
  }
  return lines.join("\n") + "\n";
}

/** The first <link rel="alternate"> to an RSS or Atom feed, resolved against `base`. */
export function findFeedLink(doc: Document, base: string): string | null {
  for (const el of Array.from(doc.querySelectorAll("link[rel][href]"))) {
    const rel = (el.getAttribute("rel") ?? "").toLowerCase().split(/\s+/);
    const type = (el.getAttribute("type") ?? "").toLowerCase();
    if (!rel.includes("alternate") || (type !== "application/rss+xml" && type !== "application/atom+xml")) continue;
    const href = resolve(el.getAttribute("href") ?? "", base);
    if (href) return href;
  }
  return null;
}
```
There's no linter (see Global Constraints), so the `eslint-disable` comment is only documentation. Delete it if you'd rather not have it.

- [ ] **Step 4: Run the tests to make sure they pass**

Run: `npx vitest run test/feed.test.ts`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add proxy/src/feed.ts proxy/test/feed.test.ts
git commit -m "feat(proxy): parse RSS, Atom and RDF feeds into dated link lists"
```

---

### Task 8: Pages (reader mode, fallback, header)

**Files:**
- Create: `proxy/src/page.ts`, `proxy/test/helpers/pages.ts`
- Test: `proxy/test/page.test.ts`, snapshots in `proxy/test/__snapshots__/*.gmi` (generated)

**Interfaces:**
- Consumes: `toGemtext` (Task 6), `findFeedLink` (Task 7), `collapse`, `hostPath` (Task 6).
- Produces:
  ```ts
  type PageMode = "reader" | "full";
  interface Page { title: string; mode: PageMode; gemtext: string; feedUrl: string | null }   // not ASCII-folded
  const MIN_ARTICLE_CHARS = 500;
  function renderPage(html: string, finalUrl: string, want: PageMode): Page;
  function discoverFeed(html: string, finalUrl: string): string | null;
  ```
  Test helper: `articleHtml(): string`, a page that reader mode accepts, with nav, footer, metadata and a feed link.

- [ ] **Step 1: Write the test helper page**

`proxy/test/helpers/pages.ts`:
```ts
const LOREM =
  "PicoSurf renders the readable part of a web page on a 320 pixel screen. " +
  "This paragraph is long enough that Readability treats the article as real content rather than boilerplate, " +
  "and it repeats a little so that the total comfortably passes the five hundred character threshold. ";

/** An article page with navigation, a footer, metadata and a feed link. */
export function articleHtml(): string {
  return `<!doctype html><html><head><title>Test Article</title>
<meta property="og:site_name" content="Example Site">
<meta name="author" content="Jane Doe">
<meta property="article:published_time" content="2026-10-12T08:00:00Z">
<link rel="alternate" type="application/rss+xml" href="/feed.xml">
</head><body>
<nav><ul><li><a href="/">Home</a></li><li><a href="/about">About</a></li></ul></nav>
<article><h1>Test Article</h1>
<p>${LOREM}</p>
<p>${LOREM} See the <a href="/ref">reference</a> for details.</p>
<p>${LOREM}</p>
</article>
<footer><p>Copyright footer text</p></footer>
</body></html>`;
}
```

- [ ] **Step 2: Write the failing test**

`proxy/test/page.test.ts`:
```ts
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { discoverFeed, renderPage } from "../src/page";
import { articleHtml } from "./helpers/pages";

const URL_ = "https://example.com/dir/page.html";

describe("renderPage", () => {
  it("uses reader mode for an article: header with byline, nav and footer gone, title heading not repeated", () => {
    const page = renderPage(articleHtml(), URL_, "reader");
    expect(page.mode).toBe("reader");
    expect(page.title).toBe("Test Article");
    expect(page.feedUrl).toBe("https://example.com/feed.xml");
    expect(page.gemtext.startsWith("# Test Article\nExample Site - Jane Doe - 2026-10-12\n\n")).toBe(true);
    expect(page.gemtext.split("# Test Article").length - 1).toBe(1);
    expect(page.gemtext).toContain("See the reference [1] for details.");
    expect(page.gemtext).toContain("=> https://example.com/ref [1] reference");
    expect(page.gemtext).not.toContain("Copyright footer");
    expect(page.gemtext).not.toContain("https://example.com/about");
  });

  it("falls back to the full page when there is too little article text", () => {
    const html = '<html><head><title>Links</title></head><body><nav><a href="/a">A</a></nav><p>Short.</p></body></html>';
    const page = renderPage(html, URL_, "reader");
    expect(page.mode).toBe("full");
    expect(page.gemtext).toBe("# Links\n\n=> https://example.com/a A\n\nShort.\n");
  });

  it("returns the full page, navigation included, when asked", () => {
    const page = renderPage(articleHtml(), URL_, "full");
    expect(page.mode).toBe("full");
    expect(page.gemtext).toContain("=> https://example.com/about About");
    expect(page.gemtext).toContain("Copyright footer text");
  });

  it("resolves links against <base href>", () => {
    const html = '<html><head><base href="https://cdn.example.org/sub/"><title>T</title></head><body><p><a href="x">X</a> text</p></body></html>';
    expect(renderPage(html, URL_, "full").gemtext).toContain("=> https://cdn.example.org/sub/x [1] X");
  });

  it("titles a page from <title>, then og:title, then host and path", () => {
    const og = '<html><head><meta property="og:title" content="OG Title"></head><body><p>x</p></body></html>';
    expect(renderPage(og, URL_, "full").title).toBe("OG Title");
    expect(renderPage("<html><body><p>x</p></body></html>", URL_, "full").title).toBe("example.com/dir/page.html");
  });
});

describe("discoverFeed", () => {
  it("finds the advertised feed", () => {
    expect(discoverFeed(articleHtml(), URL_)).toBe("https://example.com/feed.xml");
  });
});

describe("real pages (committed fixtures)", () => {
  const fixture = (name: string) => readFileSync(new URL(`./fixtures/pages/${name}.html`, import.meta.url), "utf8");
  const cases: [string, string, boolean][] = [
    ["wikipedia-gemini", "https://en.wikipedia.org/wiki/Gemini_(protocol)", true],
    ["mdn-http-status", "https://developer.mozilla.org/en-US/docs/Web/HTTP/Status", true],
    ["picodeck-api-tcp", "https://picodeck.net/docs/api-tcp/", false],
  ];
  it.each(cases)("%s matches its snapshot", async (name, url, mustBeReader) => {
    const page = renderPage(fixture(name), url, "reader");
    if (mustBeReader) expect(page.mode).toBe("reader");
    await expect(page.gemtext).toMatchFileSnapshot(`./__snapshots__/${name}.gmi`);
  });
  it("titles the Wikipedia article", () => {
    expect(renderPage(fixture("wikipedia-gemini"), cases[0][1], "reader").title).toBe("Gemini (protocol)");
  });
});
```

- [ ] **Step 3: Run it to make sure it fails**

Run: `npx vitest run test/page.test.ts`
Expected: FAIL, because `../src/page` cannot be resolved.

- [ ] **Step 4: Implement**

`proxy/src/page.ts`:
```ts
// HTML page → gemtext with a header: reader mode via Readability, falling back
// to the whole page (spec 5.5). Output is not ASCII-folded; the handler does that.

import { Readability } from "@mozilla/readability";
import { parseHTML } from "linkedom";
import { findFeedLink } from "./feed";
import { toGemtext } from "./html2gmi";
import { collapse, hostPath } from "./text";

export type PageMode = "reader" | "full";
export interface Page { title: string; mode: PageMode; gemtext: string; feedUrl: string | null }

/** Below this much article text, reader mode gives way to the full page. */
export const MIN_ARTICLE_CHARS = 500;
const JUNK = "script, style, noscript, svg, template, iframe, canvas, video, audio, [hidden], [aria-hidden=true]";

const parse = (html: string) => parseHTML(html).document as unknown as Document;

export function renderPage(html: string, finalUrl: string, want: PageMode): Page {
  const doc = parse(html);
  const base = baseOf(doc, finalUrl);
  const feedUrl = findFeedLink(doc, base);
  const docTitle = titleOf(doc);

  if (want === "reader") {
    const article = new Readability(doc, { keepClasses: true }).parse();
    if (article?.content && collapse(article.textContent ?? "").length >= MIN_ARTICLE_CHARS) {
      const title = collapse(article.title ?? "") || docTitle || hostPath(finalUrl);
      const body = parse(`<!doctype html><html><body>${article.content}</body></html>`).body;
      const byline = [article.siteName, article.byline, isoDate(article.publishedTime)]
        .map((s) => collapse(s ?? ""))
        .filter(Boolean)
        .join(" - ");
      return { title, mode: "reader", feedUrl, gemtext: header(title, byline) + toGemtext(body, { base, dropHeading: title }) };
    }
  }

  const full = want === "full" ? doc : parse(html); // Readability mutated `doc`
  for (const el of Array.from(full.querySelectorAll(JUNK))) el.remove();
  const title = docTitle || hostPath(finalUrl);
  const root = full.body ?? full.documentElement;
  return { title, mode: "full", feedUrl, gemtext: header(title, "") + toGemtext(root, { base, dropHeading: title }) };
}

export function discoverFeed(html: string, finalUrl: string): string | null {
  const doc = parse(html);
  return findFeedLink(doc, baseOf(doc, finalUrl));
}

function header(title: string, byline: string): string {
  return `# ${title}\n` + (byline ? `${byline}\n` : "") + "\n";
}

function baseOf(doc: Document, finalUrl: string): string {
  const href = doc.querySelector("base[href]")?.getAttribute("href");
  if (href) {
    try {
      return new URL(href, finalUrl).href;
    } catch {
      /* fall through to the page URL */
    }
  }
  return finalUrl;
}

function titleOf(doc: Document): string {
  return (
    collapse(doc.querySelector("title")?.textContent ?? "") ||
    collapse(doc.querySelector('meta[property="og:title"]')?.getAttribute("content") ?? "")
  );
}

function isoDate(s: string | null | undefined): string {
  if (!s) return "";
  const t = Date.parse(s);
  return Number.isNaN(t) ? "" : new Date(t).toISOString().slice(0, 10);
}
```

- [ ] **Step 5: Run the tests, then review the generated snapshots**

Run: `npx vitest run test/page.test.ts`
Expected: all pass. On this first run vitest writes `test/__snapshots__/{wikipedia-gemini,mdn-http-status,picodeck-api-tcp}.gmi`.

Open the three `.gmi` files and check them against spec 5.5:
- The `#` title line comes first, then the byline (Wikipedia and MDN have one).
- Headings use `##`/`###`, and inline links are numbered with `=>` lines after their paragraph.
- Tables come out as ` | ` rows, and code as fenced blocks.
- There is no navigation chrome in reader mode.

If a snapshot shows a converter bug, fix `html2gmi.ts`, add a focused test for the bug to `test/html2gmi.test.ts`, then regenerate the snapshot with `npx vitest run test/page.test.ts -u`.

- [ ] **Step 6: Commit**

```bash
git add proxy/src/page.ts proxy/test/helpers/pages.ts proxy/test/page.test.ts proxy/test/__snapshots__
git commit -m "feat(proxy): render pages in reader mode with full-page fallback"
```

---

### Task 9: Image sizes and the sharp resizer

**Files:**
- Create: `proxy/src/imgsize.ts`, `proxy/src/img.ts`, `proxy/src/img-sharp.ts`, `proxy/scripts/make-image-fixtures.ts`
- Create (generated, committed): `proxy/test/fixtures/images/*`
- Create: `proxy/test/helpers/resizer-contract.ts`
- Test: `proxy/test/img.test.ts`

**Interfaces:**
- Consumes: `ImageType` (Task 5).
- Produces:
  ```ts
  // imgsize.ts
  interface Size { width: number; height: number }
  interface JpegInfo { size: Size; sof: number }            // sof 0xc0 = baseline, 0xc2 = progressive
  function imageSize(bytes: Uint8Array, type: ImageType): Size | null;
  function jpegInfo(bytes: Uint8Array): JpegInfo | null;
  // img.ts
  const MAX_SIDE = 320, MAX_PIXELS = 16_000_000, JPEG_QUALITY = 75;
  interface Resizer { resize(bytes: Uint8Array, type: ImageType): Promise<Uint8Array> }
  function fitWithin(width: number, height: number, max?: number): Size;
  function flattenOnWhite(rgba: Uint8ClampedArray): void;
  // img-sharp.ts
  function createSharpResizer(): Resizer;
  // test/helpers/resizer-contract.ts
  function resizerContract(name: string, make: () => Promise<Resizer>): void;
  ```

- [ ] **Step 1: Write the fixture generator and run it**

`proxy/scripts/make-image-fixtures.ts`:
```ts
// Generates the committed image fixtures. Re-run only to change them.
import { mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

const dir = fileURLToPath(new URL("../test/fixtures/images/", import.meta.url));
mkdirSync(dir, { recursive: true });

const rgba = () => sharp({ create: { width: 800, height: 600, channels: 4, background: { r: 30, g: 120, b: 200, alpha: 0.5 } } });
const rgb = () => sharp({ create: { width: 800, height: 600, channels: 3, background: { r: 30, g: 120, b: 200 } } });

await rgba().png().toFile(dir + "photo.png"); // transparent
await rgb().jpeg({ quality: 80, progressive: false }).toFile(dir + "photo.jpg");
await rgb().jpeg({ quality: 80, progressive: true }).toFile(dir + "photo-progressive.jpg");
await rgb().webp({ quality: 80 }).toFile(dir + "photo.webp"); // VP8
await rgb().webp({ lossless: true }).toFile(dir + "photo-lossless.webp"); // VP8L
await rgba().webp({ quality: 80 }).toFile(dir + "photo-alpha.webp"); // VP8X
await rgb().gif().toFile(dir + "photo.gif");
await sharp({ create: { width: 200, height: 100, channels: 3, background: "#ff0000" } }).png().toFile(dir + "small.png");
console.log("wrote", dir);
```

Run: `npm run fixtures:images`
Expected: eight files in `test/fixtures/images/`, each under 50 KB.

- [ ] **Step 2: Write the shared resizer contract**

`proxy/test/helpers/resizer-contract.ts`:
```ts
import { readFileSync } from "node:fs";
import { beforeAll, describe, expect, it } from "vitest";
import sharp from "sharp";
import type { ImageType } from "../../src/content";
import type { Resizer } from "../../src/img";
import { jpegInfo } from "../../src/imgsize";

export const imageFixture = (name: string) => new Uint8Array(readFileSync(new URL(`../fixtures/images/${name}`, import.meta.url)));

const CASES: [string, ImageType, number, number][] = [
  ["photo.jpg", "jpeg", 320, 240],
  ["photo-progressive.jpg", "jpeg", 320, 240],
  ["photo.png", "png", 320, 240],
  ["photo.webp", "webp", 320, 240],
  ["photo-lossless.webp", "webp", 320, 240],
  ["photo-alpha.webp", "webp", 320, 240],
  ["photo.gif", "gif", 320, 240],
  ["small.png", "png", 200, 100],
];

/** Every Resizer must pass these: baseline JPEG, within 320x320, never enlarged, transparency on white. */
export function resizerContract(name: string, make: () => Promise<Resizer>): void {
  describe(`${name} resizer`, () => {
    let resizer: Resizer;
    beforeAll(async () => {
      resizer = await make();
    });

    it.each(CASES)("%s → baseline JPEG %dx%d", async (file, type, width, height) => {
      const out = await resizer.resize(imageFixture(file), type);
      const info = jpegInfo(out);
      expect(info?.sof).toBe(0xc0);
      expect(info?.size).toEqual({ width, height });
    });

    it.each(["photo.png", "photo-alpha.webp"] as const)("flattens transparency in %s onto white", async (file) => {
      const out = await resizer.resize(imageFixture(file), file.endsWith(".png") ? "png" : "webp");
      const { data } = await sharp(out).raw().toBuffer({ resolveWithObject: true });
      expect(data[0]).toBeGreaterThan(100); // red: about 142 on white, about 15 on black
      expect(data[2]).toBeGreaterThan(200); // blue
    });
  });
}
```

- [ ] **Step 3: Write the failing test**

`proxy/test/img.test.ts`:
```ts
import { describe, expect, it } from "vitest";
import { fitWithin, flattenOnWhite } from "../src/img";
import { createSharpResizer } from "../src/img-sharp";
import { imageSize, jpegInfo } from "../src/imgsize";
import { imageFixture, resizerContract } from "./helpers/resizer-contract";

describe("imageSize", () => {
  it.each([
    ["photo.jpg", "jpeg"], ["photo-progressive.jpg", "jpeg"], ["photo.png", "png"], ["photo.gif", "gif"],
    ["photo.webp", "webp"], ["photo-lossless.webp", "webp"], ["photo-alpha.webp", "webp"],
  ] as const)("reads 800x600 from the %s header", (file, type) => {
    expect(imageSize(imageFixture(file), type)).toEqual({ width: 800, height: 600 });
  });
  it("tells baseline from progressive JPEG", () => {
    expect(jpegInfo(imageFixture("photo.jpg"))?.sof).toBe(0xc0);
    expect(jpegInfo(imageFixture("photo-progressive.jpg"))?.sof).toBe(0xc2);
  });
  it("returns null for truncated data", () => {
    expect(imageSize(Uint8Array.of(0x89, 0x50), "png")).toBeNull();
    expect(jpegInfo(Uint8Array.of(0xff, 0xd8, 0xff))).toBeNull();
  });
});

describe("fitWithin", () => {
  it.each([
    [800, 600, 320, 240], [600, 800, 240, 320], [200, 100, 200, 100], [5000, 10, 320, 1], [320, 320, 320, 320],
  ])("%dx%d → %dx%d", (w, h, ew, eh) => expect(fitWithin(w, h)).toEqual({ width: ew, height: eh }));
});

describe("flattenOnWhite", () => {
  it("composites over white and makes every pixel opaque", () => {
    const px = Uint8ClampedArray.of(0, 0, 0, 0, 0, 0, 0, 255, 200, 0, 0, 128);
    flattenOnWhite(px);
    expect(Array.from(px)).toEqual([255, 255, 255, 255, 0, 0, 0, 255, 227, 127, 127, 255]);
  });
});

resizerContract("sharp", async () => createSharpResizer());
```

- [ ] **Step 4: Run it to make sure it fails**

Run: `npx vitest run test/img.test.ts`
Expected: FAIL, because `../src/img` cannot be resolved.

- [ ] **Step 5: Implement `imgsize.ts`**

`proxy/src/imgsize.ts`:
```ts
// Image dimensions from headers alone, so oversized images are refused before
// decoding (spec 5.8), plus the JPEG frame type for the baseline check.

import type { ImageType } from "./content";

export interface Size { width: number; height: number }
export interface JpegInfo { size: Size; sof: number }

const u16be = (b: Uint8Array, i: number) => (b[i] << 8) | b[i + 1];
const u16le = (b: Uint8Array, i: number) => b[i] | (b[i + 1] << 8);
const u24le = (b: Uint8Array, i: number) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16);
const u32be = (b: Uint8Array, i: number) => ((b[i] << 24) >>> 0) + (b[i + 1] << 16) + (b[i + 2] << 8) + b[i + 3];

export function imageSize(b: Uint8Array, type: ImageType): Size | null {
  switch (type) {
    case "png":
      return b.length >= 24 ? { width: u32be(b, 16), height: u32be(b, 20) } : null;
    case "gif":
      return b.length >= 10 ? { width: u16le(b, 6), height: u16le(b, 8) } : null;
    case "webp":
      return webpSize(b);
    case "jpeg":
      return jpegInfo(b)?.size ?? null;
  }
}

function webpSize(b: Uint8Array): Size | null {
  if (b.length < 30) return null;
  const chunk = String.fromCharCode(b[12], b[13], b[14], b[15]);
  if (chunk === "VP8 ") return { width: u16le(b, 26) & 0x3fff, height: u16le(b, 28) & 0x3fff };
  if (chunk === "VP8L") {
    const bits = (b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24)) >>> 0;
    return { width: (bits & 0x3fff) + 1, height: ((bits >>> 14) & 0x3fff) + 1 };
  }
  if (chunk === "VP8X") return { width: u24le(b, 24) + 1, height: u24le(b, 27) + 1 };
  return null;
}

/** Walks JPEG markers to the first start-of-frame. */
export function jpegInfo(b: Uint8Array): JpegInfo | null {
  let i = 2;
  while (i + 9 < b.length) {
    if (b[i] !== 0xff) {
      i++;
      continue;
    }
    const marker = b[i + 1];
    if (marker === 0xff) {
      i++;
      continue;
    }
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      i += 2;
      continue;
    }
    if (marker === 0xd9 || marker === 0xda) return null; // end of image or scan before any frame
    if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
      return { sof: marker, size: { height: u16be(b, i + 5), width: u16be(b, i + 7) } };
    }
    i += 2 + u16be(b, i + 2);
  }
  return null;
}
```

- [ ] **Step 6: Implement `img.ts` and `img-sharp.ts`**

`proxy/src/img.ts`:
```ts
import type { ImageType } from "./content";
import type { Size } from "./imgsize";

export const MAX_SIDE = 320;
export const MAX_PIXELS = 16_000_000;
export const JPEG_QUALITY = 75;

/** Turns an image into a baseline JPEG within MAX_SIDE x MAX_SIDE (spec 5.8). */
export interface Resizer {
  resize(bytes: Uint8Array, type: ImageType): Promise<Uint8Array>;
}

/** Scales down to fit `max` x `max`, keeping the aspect ratio; never enlarges. */
export function fitWithin(width: number, height: number, max = MAX_SIDE): Size {
  const scale = Math.min(1, max / width, max / height);
  return { width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale)) };
}

/** Composites RGBA pixels over white in place, leaving every pixel opaque. */
export function flattenOnWhite(rgba: Uint8ClampedArray): void {
  for (let i = 0; i < rgba.length; i += 4) {
    const a = rgba[i + 3];
    if (a === 255) continue;
    const k = a / 255;
    rgba[i] = rgba[i] * k + 255 * (1 - k);
    rgba[i + 1] = rgba[i + 1] * k + 255 * (1 - k);
    rgba[i + 2] = rgba[i + 2] * k + 255 * (1 - k);
    rgba[i + 3] = 255;
  }
}
```

`proxy/src/img-sharp.ts`:
```ts
import sharp from "sharp";
import { JPEG_QUALITY, MAX_PIXELS, MAX_SIDE, type Resizer } from "./img";

/** The Node resizer. sharp handles every input type the handler accepts. */
export function createSharpResizer(): Resizer {
  return {
    async resize(bytes) {
      const out = await sharp(bytes, { limitInputPixels: MAX_PIXELS, animated: false })
        .rotate() // apply EXIF orientation
        .flatten({ background: "#ffffff" })
        .resize(MAX_SIDE, MAX_SIDE, { fit: "inside", withoutEnlargement: true })
        .jpeg({ quality: JPEG_QUALITY, progressive: false, mozjpeg: false })
        .toBuffer();
      return new Uint8Array(out.buffer, out.byteOffset, out.byteLength);
    },
  };
}
```

- [ ] **Step 7: Run the tests to make sure they pass**

Run: `npx vitest run test/img.test.ts`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add proxy/src/imgsize.ts proxy/src/img.ts proxy/src/img-sharp.ts proxy/scripts/make-image-fixtures.ts proxy/test/fixtures/images proxy/test/helpers/resizer-contract.ts proxy/test/img.test.ts
git commit -m "feat(proxy): image size checks and the sharp resizer"
```

---

### Task 10: The WASM resizer for Workers

**Files:**
- Create: `proxy/src/img-wasm.ts`
- Test: `proxy/test/img-wasm.test.ts`

**Interfaces:**
- Consumes: `Resizer`, `fitWithin`, `flattenOnWhite`, `JPEG_QUALITY` (Task 9), `ImageType` (Task 5), `resizerContract` (Task 9).
- Produces:
  ```ts
  interface WasmModules { jpegDec: WebAssembly.Module; jpegEnc: WebAssembly.Module; pngDec: WebAssembly.Module; webpDec: WebAssembly.Module; resize: WebAssembly.Module }
  function createWasmResizer(mods: WasmModules): Resizer;
  ```
  Importing the module installs a global `ImageData` shim if the runtime has none.

- [ ] **Step 1: Write the failing test**

`proxy/test/img-wasm.test.ts`:
```ts
import { readFileSync } from "node:fs";
import { createWasmResizer } from "../src/img-wasm";
import { resizerContract } from "./helpers/resizer-contract";

const mod = (path: string) => new WebAssembly.Module(readFileSync(new URL(`../node_modules/${path}`, import.meta.url)));

resizerContract("wasm", async () =>
  createWasmResizer({
    jpegDec: mod("@jsquash/jpeg/codec/dec/mozjpeg_dec.wasm"),
    jpegEnc: mod("@jsquash/jpeg/codec/enc/mozjpeg_enc.wasm"),
    pngDec: mod("@jsquash/png/codec/pkg/squoosh_png_bg.wasm"),
    webpDec: mod("@jsquash/webp/codec/dec/webp_dec.wasm"),
    resize: mod("@jsquash/resize/lib/resize/pkg/squoosh_resize_bg.wasm"),
  }),
);
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `npx vitest run test/img-wasm.test.ts`
Expected: FAIL, because `../src/img-wasm` cannot be resolved.

- [ ] **Step 3: Implement**

`proxy/src/img-wasm.ts`:
```ts
// The Workers resizer: jSquash WASM codecs plus omggif for GIF (spec 5.8).
// The WASM modules are passed in because Workers can only load them as
// bundled imports (worker.ts); tests compile them from node_modules.

import decodeJpeg, { init as initJpegDec } from "@jsquash/jpeg/decode";
import encodeJpeg, { init as initJpegEnc } from "@jsquash/jpeg/encode";
import decodePng, { init as initPngDec } from "@jsquash/png/decode";
import resize, { initResize } from "@jsquash/resize";
import decodeWebp, { init as initWebpDec } from "@jsquash/webp/decode";
import { GifReader } from "omggif";
import type { ImageType } from "./content";
import { JPEG_QUALITY, type Resizer, fitWithin, flattenOnWhite } from "./img";

/** Minimal ImageData for runtimes without one (Node, and possibly Workers); jSquash constructs it. */
class ImageDataShim {
  readonly colorSpace = "srgb";
  readonly data: Uint8ClampedArray;
  readonly width: number;
  readonly height: number;
  constructor(a: Uint8ClampedArray | number, b: number, c?: number) {
    if (typeof a === "number") {
      this.width = a;
      this.height = b;
      this.data = new Uint8ClampedArray(a * b * 4);
    } else {
      this.data = a;
      this.width = b;
      this.height = c ?? a.length / 4 / b;
    }
  }
}
(globalThis as { ImageData?: unknown }).ImageData ??= ImageDataShim;

export interface WasmModules {
  jpegDec: WebAssembly.Module;
  jpegEnc: WebAssembly.Module;
  pngDec: WebAssembly.Module;
  webpDec: WebAssembly.Module;
  resize: WebAssembly.Module;
}

// The emscripten codecs accept (module, options?) at runtime, though their
// .d.ts declares only options.
type Init = (module: WebAssembly.Module) => Promise<unknown>;

export function createWasmResizer(mods: WasmModules): Resizer {
  let ready: Promise<unknown> | null = null;
  const init = () =>
    (ready ??= Promise.all([
      (initJpegDec as unknown as Init)(mods.jpegDec),
      (initJpegEnc as unknown as Init)(mods.jpegEnc),
      (initPngDec as unknown as Init)(mods.pngDec),
      (initWebpDec as unknown as Init)(mods.webpDec),
      (initResize as unknown as Init)(mods.resize),
    ]));

  return {
    async resize(bytes, type) {
      await init();
      const source = await decode(bytes, type);
      const { width, height } = fitWithin(source.width, source.height);
      const scaled = width === source.width && height === source.height ? source : await resize(source, { width, height });
      flattenOnWhite(scaled.data);
      const out = await encodeJpeg(scaled, { quality: JPEG_QUALITY, baseline: true, progressive: false });
      return new Uint8Array(out);
    },
  };
}

async function decode(bytes: Uint8Array, type: ImageType): Promise<ImageData> {
  const buffer = bytes.slice().buffer;
  switch (type) {
    case "jpeg":
      return decodeJpeg(buffer);
    case "png":
      return decodePng(buffer);
    case "webp":
      return decodeWebp(buffer);
    case "gif": {
      const reader = new GifReader(bytes);
      const data = new Uint8ClampedArray(reader.width * reader.height * 4);
      reader.decodeAndBlitFrameRGBA(0, data);
      return new ImageData(data, reader.width, reader.height);
    }
  }
}
```

- [ ] **Step 4: Run the tests to make sure they pass**

Run: `npx vitest run test/img-wasm.test.ts`
Expected: all pass. If the jSquash JPEG encoder writes a SOF other than `0xc0`, check that `progressive: false` and `baseline: true` reached it. Don't loosen the contract test.

- [ ] **Step 5: Commit**

```bash
git add proxy/src/img-wasm.ts proxy/test/img-wasm.test.ts
git commit -m "feat(proxy): WASM image resizer for Workers"
```

---

### Task 11: The request handler

**Files:**
- Create: `proxy/src/handler.ts`
- Test: `proxy/test/handler.test.ts`

**Interfaces:**
- Consumes: `safeFetch`, `FetchFn`, `Upstream` (Task 4); `ProxyError`, `textResponse` (Task 3); `foldAscii` (Task 2); `kindFromMime`, `sniffKind`, `mimeOf`, `decodeText`, `sniffImageType`, `imageTypeFromMime` (Task 5); `renderPage`, `discoverFeed` (Task 8); `parseFeed`, `feedToGemtext` (Task 7); `imageSize` (Task 9); `Resizer`, `MAX_PIXELS` (Task 9); `articleHtml`, `imageFixture`, `fakeFetch`, `html`, `redirect` (test helpers).
- Produces:
  ```ts
  interface Env { PROXY_TOKEN?: string; USER_AGENT?: string }
  interface Deps { fetch: FetchFn; resizer: Resizer }
  const DEFAULT_UA = "PicoSurfProxy/1 (+https://github.com/PicoDeck/picosurf)";
  const OUTPUT_CAP = 256 * 1024;
  function handleRequest(req: Request, env: Env, deps: Deps): Promise<Response>;
  ```

- [ ] **Step 1: Write the failing test**

`proxy/test/handler.test.ts`:
````ts
import { describe, expect, it, vi } from "vitest";
import { type Deps, OUTPUT_CAP, handleRequest } from "../src/handler";
import type { Resizer } from "../src/img";
import { fakeFetch, html, redirect } from "./helpers/fakefetch";
import { articleHtml } from "./helpers/pages";
import { imageFixture } from "./helpers/resizer-contract";

const TOKEN = "secret-token";
const env = { PROXY_TOKEN: TOKEN };
const JPEG_OUT = Uint8Array.of(0xff, 0xd8, 0xff, 0xd9);

function deps(routes: Parameters<typeof fakeFetch>[0] = {}) {
  const fetch = fakeFetch(routes);
  const resizer = { resize: vi.fn<Resizer["resize"]>(async () => JPEG_OUT) };
  return { fetch, resizer, deps: { fetch, resizer } satisfies Deps };
}

const call = (path: string, d: Deps, token: string | null = TOKEN, init: RequestInit = {}) =>
  handleRequest(
    new Request(`https://proxy.example${path}`, { ...init, headers: token === null ? {} : { Authorization: `Bearer ${token}` } }),
    env,
    d,
  );
const get = (url: string, d: Deps, as?: string) =>
  call(`/v1/get?url=${encodeURIComponent(url)}${as ? `&as=${as}` : ""}`, d);
const ASCII = /^[\t\n\x20-\x7e]*$/;

describe("routing and auth", () => {
  it("answers ping with the token", async () => {
    const res = await call("/v1/ping", deps().deps);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("picosurf-proxy 1\n");
  });
  it("answers under a subpath", async () => {
    expect((await call("/picosurf/v1/ping", deps().deps)).status).toBe(200);
  });
  it.each([null, "wrong"])("refuses token %j with 401", async (token) => {
    const res = await call("/v1/ping", deps().deps, token);
    expect(res.status).toBe(401);
    expect(await res.text()).toBe("Missing or wrong token\n");
  });
  it("fails closed with 500 when PROXY_TOKEN is not set", async () => {
    const res = await handleRequest(new Request("https://p.example/v1/ping"), {}, deps().deps);
    expect(res.status).toBe(500);
  });
  it("404s unknown paths and 405s other methods", async () => {
    expect((await call("/nope", deps().deps)).status).toBe(404);
    expect((await call("/v1/ping", deps().deps, TOKEN, { method: "POST" })).status).toBe(405);
  });
  it.each([
    ["/v1/get", 400],
    ["/v1/get?url=https%3A%2F%2Fexample.com%2F&as=raw", 400],
    ["/v1/get?url=ftp%3A%2F%2Fexample.com%2F", 400],
    ["/v1/get?url=http%3A%2F%2F127.0.0.1%2F", 403],
  ])("%s → %d without fetching", async (path, status) => {
    const d = deps();
    expect((await call(path, d.deps)).status).toBe(status);
    expect(d.fetch.calls).toHaveLength(0);
  });
});

describe("pages", () => {
  it("returns reader-mode gemtext with headers, after redirects", async () => {
    const d = deps({ "https://example.com/start": redirect("/dir/page.html"), "https://example.com/dir/page.html": html(articleHtml()) });
    const res = await get("https://example.com/start", d.deps);
    expect(res.status).toBe(200);
    expect(res.headers.get("Content-Type")).toBe("text/gemini; charset=us-ascii");
    expect(res.headers.get("X-Final-Url")).toBe("https://example.com/dir/page.html");
    expect(res.headers.get("X-Mode")).toBe("reader");
    expect(res.headers.get("X-Title")).toBe("Test Article");
    expect(res.headers.get("X-Feed-Url")).toBe("https://example.com/feed.xml");
    const body = await res.text();
    expect(body.startsWith("# Test Article\n")).toBe(true);
    expect(body).toMatch(ASCII);
  });
  it("returns the full page for as=full", async () => {
    const d = deps({ "https://example.com/": html(articleHtml()) });
    const res = await get("https://example.com/", d.deps, "full");
    expect(res.headers.get("X-Mode")).toBe("full");
  });
  it("decodes windows-1252 pages (Review Focus 1)", async () => {
    const bytes = Uint8Array.from("<html><head><title>Q</title></head><body><p>He said \x93hi\x94 caf\xe9</p></body></html>", (c) => c.charCodeAt(0));
    const d = deps({ "https://example.com/": new Response(bytes, { headers: { "Content-Type": "text/html; charset=windows-1252" } }) });
    expect(await (await get("https://example.com/", d.deps)).text()).toContain('He said "hi" cafe');
  });
  it("folds the title header to ASCII", async () => {
    const d = deps({ "https://example.com/": html("<html><head><title>Café — news</title></head><body><p>x</p></body></html>") });
    expect((await get("https://example.com/", d.deps)).headers.get("X-Title")).toBe("Cafe -- news");
  });
  it("truncates long output at a line boundary", async () => {
    const paras = Array.from({ length: 4000 }, (_, i) => `<p>Paragraph ${i} ${"x".repeat(90)}</p>`).join("");
    const d = deps({ "https://example.com/": html(`<html><head><title>Long</title></head><body>${paras}</body></html>`) });
    const res = await get("https://example.com/", d.deps, "full");
    const body = await res.text();
    expect(res.headers.get("X-Truncated")).toBe("1");
    expect(body.length).toBeLessThanOrEqual(OUTPUT_CAP);
    expect(body.endsWith("\n(Page truncated)\n")).toBe(true);
  });
  it("closes an open preformatted block before the truncation notice (Review Focus 2)", async () => {
    const code = Array.from({ length: 6000 }, (_, i) => `line ${i} ${"y".repeat(50)}`).join("\n");
    const d = deps({ "https://example.com/": html(`<html><head><title>Code</title></head><body><pre>${code}</pre></body></html>`) });
    const body = await (await get("https://example.com/", d.deps, "full")).text();
    expect(body.endsWith("\n```\n(Page truncated)\n")).toBe(true);
  });
});

describe("feeds", () => {
  const rss = `<rss version="2.0"><channel><title>Feed</title><item><title>One</title><link>https://example.com/1</link><pubDate>Tue, 13 Oct 2026 09:30:00 GMT</pubDate></item></channel></rss>`;
  it("returns a feed list for an RSS response", async () => {
    const d = deps({ "https://example.com/feed.xml": new Response(rss, { headers: { "Content-Type": "application/rss+xml" } }) });
    const res = await get("https://example.com/feed.xml", d.deps);
    expect(res.headers.get("X-Mode")).toBe("feed");
    expect(res.headers.get("X-Title")).toBe("Feed");
    expect(await res.text()).toBe("# Feed\n\n=> https://example.com/1 2026-10-13 One\n");
  });
  it("sniffs a feed served as text/xml", async () => {
    const d = deps({ "https://example.com/f": new Response(`<?xml version="1.0"?>${rss}`, { headers: { "Content-Type": "text/xml" } }) });
    expect((await get("https://example.com/f", d.deps)).headers.get("X-Mode")).toBe("feed");
  });
  it("follows a homepage's feed link for as=feed", async () => {
    const d = deps({
      "https://example.com/": html(articleHtml()),
      "https://example.com/feed.xml": new Response(rss, { headers: { "Content-Type": "application/rss+xml" } }),
    });
    const res = await get("https://example.com/", d.deps, "feed");
    expect(res.headers.get("X-Mode")).toBe("feed");
    expect(res.headers.get("X-Final-Url")).toBe("https://example.com/feed.xml");
  });
  it("415s as=feed on a page without a feed", async () => {
    const d = deps({ "https://example.com/": html("<html><body><p>x</p></body></html>") });
    const res = await get("https://example.com/", d.deps, "feed");
    expect(res.status).toBe(415);
    expect(await res.text()).toBe("No feed found on this page\n");
  });
});

describe("images", () => {
  it("resizes an image to JPEG", async () => {
    const d = deps({ "https://example.com/a.png": new Response(imageFixture("photo.png"), { headers: { "Content-Type": "image/png" } }) });
    const res = await get("https://example.com/a.png", d.deps);
    expect(res.headers.get("Content-Type")).toBe("image/jpeg");
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(JPEG_OUT);
    expect(d.resizer.resize).toHaveBeenCalledWith(expect.any(Uint8Array), "png");
  });
  it("trusts the bytes over a wrong or missing Content-Type (Review Focus 4)", async () => {
    const d = deps({
      "https://example.com/lie.jpg": new Response(imageFixture("photo.webp"), { headers: { "Content-Type": "image/jpeg" } }),
      "https://example.com/none": new Response(imageFixture("photo.gif")),
    });
    await get("https://example.com/lie.jpg", d.deps);
    await get("https://example.com/none", d.deps);
    expect(d.resizer.resize.mock.calls.map((c) => c[1])).toEqual(["webp", "gif"]);
  });
  it("refuses images over 16 megapixels without decoding them", async () => {
    const png = new Uint8Array(33);
    png.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);
    new DataView(png.buffer).setUint32(16, 5000);
    new DataView(png.buffer).setUint32(20, 4000);
    const d = deps({ "https://example.com/huge.png": new Response(png, { headers: { "Content-Type": "image/png" } }) });
    const res = await get("https://example.com/huge.png", d.deps);
    expect(res.status).toBe(413);
    expect(await res.text()).toBe("Image too large (5000x4000)\n");
    expect(d.resizer.resize).not.toHaveBeenCalled();
  });
  it("415s an image the resizer cannot decode", async () => {
    const d = deps({ "https://example.com/a.jpg": new Response(imageFixture("photo.jpg"), { headers: { "Content-Type": "image/jpeg" } }) });
    d.resizer.resize.mockRejectedValueOnce(new Error("corrupt"));
    expect((await get("https://example.com/a.jpg", d.deps)).status).toBe(415);
  });
});

describe("other content and upstream errors", () => {
  it("folds plain text", async () => {
    const d = deps({ "https://example.com/t.txt": new Response("café “x”", { headers: { "Content-Type": "text/plain; charset=utf-8" } }) });
    const res = await get("https://example.com/t.txt", d.deps);
    expect(res.headers.get("Content-Type")).toBe("text/plain; charset=us-ascii");
    expect(await res.text()).toBe('cafe "x"');
  });
  it("415s unsupported types with their size", async () => {
    const d = deps({
      "https://example.com/a.pdf": new Response("%PDF", { headers: { "Content-Type": "application/pdf", "Content-Length": "2411724" } }),
    });
    const res = await get("https://example.com/a.pdf", d.deps);
    expect(res.status).toBe(415);
    expect(await res.text()).toBe("Unsupported: application/pdf (2.3 MB)\n");
  });
  it("415s SVG", async () => {
    const d = deps({ "https://example.com/a.svg": new Response("<svg/>", { headers: { "Content-Type": "image/svg+xml" } }) });
    expect((await get("https://example.com/a.svg", d.deps)).status).toBe(415);
  });
  it("turns an upstream error status into 502 with X-Upstream-Status", async () => {
    const d = deps({ "https://example.com/gone": new Response("no", { status: 404, statusText: "Not Found" }) });
    const res = await get("https://example.com/gone", d.deps);
    expect(res.status).toBe(502);
    expect(res.headers.get("X-Upstream-Status")).toBe("404");
    expect(await res.text()).toBe("Site returned 404 Not Found\n");
  });
});
````

- [ ] **Step 2: Run it to make sure it fails**

Run: `npx vitest run test/handler.test.ts`
Expected: FAIL, because `../src/handler` cannot be resolved.

- [ ] **Step 3: Implement**

`proxy/src/handler.ts`:
````ts
// Routing, auth and dispatch by content kind (spec 5.1-5.3). Platform-neutral:
// worker.ts and node.ts supply `fetch` and the image resizer.

import { foldAscii } from "./ascii";
import { decodeText, imageTypeFromMime, kindFromMime, mimeOf, sniffImageType, sniffKind } from "./content";
import { ProxyError, textResponse } from "./errors";
import { feedToGemtext, parseFeed } from "./feed";
import { MAX_PIXELS, type Resizer } from "./img";
import { imageSize } from "./imgsize";
import { discoverFeed, renderPage } from "./page";
import { type FetchFn, type SafeFetchOptions, type Upstream, safeFetch } from "./safefetch";

export interface Env {
  PROXY_TOKEN?: string;
  USER_AGENT?: string;
}

export interface Deps {
  fetch: FetchFn;
  resizer: Resizer;
}

export const DEFAULT_UA = "PicoSurfProxy/1 (+https://github.com/PicoDeck/picosurf)";
export const OUTPUT_CAP = 256 * 1024;
const TEXT_LIMIT = 5 * 1024 * 1024;
const IMAGE_LIMIT = 10 * 1024 * 1024;
const NO_STORE = { "Cache-Control": "no-store" };

export async function handleRequest(req: Request, env: Env, deps: Deps): Promise<Response> {
  try {
    return await route(req, env, deps);
  } catch (e) {
    if (e instanceof ProxyError) return textResponse(e.status, e.message, e.headers);
    console.error(e);
    return textResponse(500, "Internal error");
  }
}

async function route(req: Request, env: Env, deps: Deps): Promise<Response> {
  const url = new URL(req.url);
  const isPing = url.pathname.endsWith("/v1/ping");
  const isGet = url.pathname.endsWith("/v1/get");
  if (!isPing && !isGet) throw new ProxyError(404, "Not found");
  if (req.method !== "GET") throw new ProxyError(405, "Method not allowed");
  await authorize(req, env);
  if (isPing) return new Response("picosurf-proxy 1\n", { headers: { "Content-Type": "text/plain; charset=us-ascii", ...NO_STORE } });

  const target = url.searchParams.get("url");
  if (!target) throw new ProxyError(400, "Missing url parameter");
  const as = url.searchParams.get("as") ?? "reader";
  if (as !== "reader" && as !== "full" && as !== "feed") throw new ProxyError(400, `Unknown as=${as}`);

  const opts: SafeFetchOptions = { fetch: deps.fetch, userAgent: env.USER_AGENT || DEFAULT_UA };
  const up = await safeFetch(target, opts);
  checkStatus(up);
  const mime = mimeOf(up.contentType);
  let kind = kindFromMime(mime);
  if (kind === "unsupported") {
    up.discard();
    throw unsupported(mime, up.contentLength);
  }
  const body = await up.read(kind === "html" || kind === "feed" || kind === "text" ? TEXT_LIMIT : IMAGE_LIMIT);
  if (kind === "sniff") kind = sniffKind(body);
  const final = { "X-Final-Url": up.finalUrl };

  switch (kind) {
    case "html": {
      const text = decodeText(body, up.contentType);
      if (as === "feed") return feedFromPage(text, up.finalUrl, opts);
      const page = renderPage(text, up.finalUrl, as === "full" ? "full" : "reader");
      return gemtext(page.gemtext, {
        ...final,
        "X-Mode": page.mode,
        "X-Title": headerValue(page.title),
        ...(page.feedUrl ? { "X-Feed-Url": page.feedUrl } : {}),
      });
    }
    case "feed":
      return feedResponse(decodeText(body, up.contentType), up.finalUrl);
    case "image":
      return imageResponse(body, mime, deps.resizer, final);
    case "text":
      return plainText(decodeText(body, up.contentType), final);
    default:
      throw unsupported(mime, body.length);
  }
}

async function authorize(req: Request, env: Env): Promise<void> {
  if (!env.PROXY_TOKEN) throw new ProxyError(500, "PROXY_TOKEN is not configured");
  const m = /^Bearer\s+(.+)$/i.exec(req.headers.get("authorization") ?? "");
  if (!m || !(await sameSecret(m[1].trim(), env.PROXY_TOKEN))) throw new ProxyError(401, "Missing or wrong token");
}

/** Compares SHA-256 digests in constant time, so neither content nor length leaks. */
async function sameSecret(a: string, b: string): Promise<boolean> {
  const enc = new TextEncoder();
  const [x, y] = await Promise.all([crypto.subtle.digest("SHA-256", enc.encode(a)), crypto.subtle.digest("SHA-256", enc.encode(b))]);
  const u = new Uint8Array(x);
  const v = new Uint8Array(y);
  let diff = 0;
  for (let i = 0; i < u.length; i++) diff |= u[i] ^ v[i];
  return diff === 0;
}

function checkStatus(up: Upstream): void {
  if (up.status >= 200 && up.status <= 299) return;
  up.discard();
  throw new ProxyError(502, `Site returned ${up.status} ${up.statusText}`.trim(), { "X-Upstream-Status": String(up.status) });
}

async function feedFromPage(html: string, finalUrl: string, opts: SafeFetchOptions): Promise<Response> {
  const feedUrl = discoverFeed(html, finalUrl);
  if (!feedUrl) throw new ProxyError(415, "No feed found on this page");
  const up = await safeFetch(feedUrl, opts);
  checkStatus(up);
  const body = await up.read(TEXT_LIMIT);
  const kind = kindFromMime(mimeOf(up.contentType));
  const isFeed = kind === "feed" || (kind === "sniff" && sniffKind(body) === "feed");
  if (!isFeed) throw new ProxyError(415, "The advertised feed is not RSS or Atom");
  return feedResponse(decodeText(body, up.contentType), up.finalUrl);
}

function feedResponse(xml: string, finalUrl: string): Response {
  const feed = parseFeed(xml, finalUrl);
  if (!feed) throw new ProxyError(415, "Not a readable feed");
  return gemtext(feedToGemtext(feed), { "X-Final-Url": finalUrl, "X-Mode": "feed", "X-Title": headerValue(feed.title) });
}

async function imageResponse(bytes: Uint8Array, mime: string, resizer: Resizer, headers: Record<string, string>): Promise<Response> {
  const type = sniffImageType(bytes) ?? imageTypeFromMime(mime);
  if (!type) throw new ProxyError(415, `Unsupported image: ${mime || "unknown type"}`);
  const size = imageSize(bytes, type);
  if (!size) throw new ProxyError(415, "Could not read the image size");
  if (size.width * size.height > MAX_PIXELS) throw new ProxyError(413, `Image too large (${size.width}x${size.height})`);
  let jpeg: Uint8Array;
  try {
    jpeg = await resizer.resize(bytes, type);
  } catch {
    throw new ProxyError(415, "Could not decode the image");
  }
  return new Response(jpeg.slice().buffer, { headers: { "Content-Type": "image/jpeg", ...NO_STORE, ...headers } });
}

function gemtext(text: string, headers: Record<string, string>): Response {
  return capped(text, "text/gemini; charset=us-ascii", headers);
}

function plainText(text: string, headers: Record<string, string>): Response {
  return capped(text, "text/plain; charset=us-ascii", headers);
}

/** Folds to ASCII and cuts at a line boundary under OUTPUT_CAP, closing an open fence first. */
function capped(raw: string, contentType: string, headers: Record<string, string>): Response {
  let body = foldAscii(raw);
  const extra: Record<string, string> = {};
  if (body.length > OUTPUT_CAP) {
    body = body.slice(0, body.lastIndexOf("\n", OUTPUT_CAP - 32) + 1);
    if ((body.match(/^```/gm)?.length ?? 0) % 2 === 1) body += "```\n";
    body += "(Page truncated)\n";
    extra["X-Truncated"] = "1";
  }
  return new Response(body, { headers: { "Content-Type": contentType, ...NO_STORE, ...headers, ...extra } });
}

function headerValue(s: string): string {
  return foldAscii(s).replace(/\s+/g, " ").trim().slice(0, 200);
}

function unsupported(mime: string, bytes: number | null): ProxyError {
  const size = bytes === null ? "" : ` (${bytes >= 1048576 ? `${(bytes / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(bytes / 1024))} KB`})`;
  return new ProxyError(415, `Unsupported: ${mime || "unknown type"}${size}`);
}
````

- [ ] **Step 4: Run the tests to make sure they pass**

Run: `npx vitest run test/handler.test.ts`
Expected: all pass.

- [ ] **Step 5: Run everything and typecheck**

Run: `npm test && npm run typecheck`
Expected: all tests pass and there are no type errors.

- [ ] **Step 6: Commit**

```bash
git add proxy/src/handler.ts proxy/test/handler.test.ts
git commit -m "feat(proxy): request handler with auth, dispatch and output cap"
```

---

### Task 12: The Node adapter, DNS guard and Docker image

**Files:**
- Create: `proxy/src/lookup.ts`, `proxy/src/node.ts`, `proxy/src/serve.ts`, `proxy/Dockerfile`, `proxy/.dockerignore`
- Test: `proxy/test/node.test.ts`

**Interfaces:**
- Consumes: `isPublicIp` (Task 3), `BlockedAddressError` (Task 3), `handleRequest`, `Env`, `Deps` (Task 11), `createSharpResizer` (Task 9), `safeFetch` (Task 4).
- Produces:
  ```ts
  // lookup.ts
  type Address = { address: string; family: number };
  type Resolver = (hostname: string, options: { all: true; family?: number }, cb: (err: Error | null, addresses: Address[]) => void) => void;
  function guardedLookup(resolve?: Resolver): (hostname: string, options: { all?: boolean; family?: number } | number, cb: Function) => void;
  // node.ts
  function nodeDeps(resolve?: Resolver): Deps;
  function createServer(env: Env, deps: Deps): http.Server;
  ```

- [ ] **Step 1: Write the failing test**

`proxy/test/node.test.ts`:
```ts
import type { AddressInfo } from "node:net";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { BlockedAddressError } from "../src/errors";
import { type Address, type Resolver, guardedLookup } from "../src/lookup";
import { createServer, nodeDeps } from "../src/node";
import { safeFetch } from "../src/safefetch";

const fixed = (addresses: Address[]): Resolver => (_h, _o, cb) => cb(null, addresses);

function lookup(resolve: Resolver, options: { all?: boolean }) {
  return new Promise<{ err: Error | null; address?: unknown; family?: number }>((done) =>
    guardedLookup(resolve)("site.example", options, (err: Error | null, address?: unknown, family?: number) => done({ err, address, family })),
  );
}

describe("guardedLookup", () => {
  it("passes public addresses through in both callback shapes", async () => {
    const r = fixed([{ address: "93.184.216.34", family: 4 }]);
    expect(await lookup(r, {})).toEqual({ err: null, address: "93.184.216.34", family: 4 });
    expect((await lookup(r, { all: true })).address).toEqual([{ address: "93.184.216.34", family: 4 }]);
  });
  it.each([
    [[{ address: "10.0.0.5", family: 4 }]],
    [[{ address: "93.184.216.34", family: 4 }, { address: "::1", family: 6 }]],
    [[]],
  ])("refuses %j", async (addresses) => {
    expect((await lookup(fixed(addresses), {})).err).toBeInstanceOf(BlockedAddressError);
  });
  it("passes resolver errors through", async () => {
    const failing: Resolver = (_h, _o, cb) => cb(new Error("ENOTFOUND"), []);
    expect((await lookup(failing, {})).err?.message).toBe("ENOTFOUND");
  });
});

describe("nodeDeps", () => {
  it("refuses at connect time a name that resolves to a private address (403)", async () => {
    const { fetch } = nodeDeps(fixed([{ address: "127.0.0.1", family: 4 }]));
    await expect(safeFetch("http://rebind.example/", { fetch, userAgent: "t" })).rejects.toMatchObject({ status: 403 });
  });
});

describe("createServer", () => {
  const server = createServer({ PROXY_TOKEN: "tok" }, nodeDeps());
  let base = "";
  beforeAll(async () => {
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
    base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });
  afterAll(() => new Promise<void>((r) => server.close(() => r())));

  it("serves the handler over HTTP", async () => {
    const res = await fetch(`${base}/v1/ping`, { headers: { Authorization: "Bearer tok" } });
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("picosurf-proxy 1\n");
  });
  it("passes status and headers through", async () => {
    const res = await fetch(`${base}/v1/get?url=${encodeURIComponent("http://10.0.0.1/")}`, { headers: { Authorization: "Bearer tok" } });
    expect(res.status).toBe(403);
    expect(res.headers.get("content-type")).toBe("text/plain; charset=us-ascii");
  });
});
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `npx vitest run test/node.test.ts`
Expected: FAIL, because `../src/lookup` cannot be resolved.

- [ ] **Step 3: Implement `lookup.ts`**

`proxy/src/lookup.ts`:
```ts
import dns from "node:dns";
import { isPublicIp } from "./addr";
import { BlockedAddressError } from "./errors";

export type Address = { address: string; family: number };
export type Resolver = (
  hostname: string,
  options: { all: true; family?: number },
  cb: (err: Error | null, addresses: Address[]) => void,
) => void;
type Callback = (err: Error | null, address?: string | Address[], family?: number) => void;

const systemResolve: Resolver = (hostname, options, cb) =>
  dns.lookup(hostname, options, (err, addresses) => cb(err, (addresses ?? []) as Address[]));

/**
 * A `lookup` for net/tls.connect that refuses any non-public address, so the
 * address checked is the one connected to: no DNS-rebinding gap (spec 5.4).
 * Handles both callback shapes: Node asks for `all: true` when it races
 * address families.
 */
export function guardedLookup(resolve: Resolver = systemResolve) {
  return (hostname: string, options: { all?: boolean; family?: number } | number, callback: Callback): void => {
    const opts = typeof options === "number" ? { family: options } : options;
    resolve(hostname, { all: true, family: opts.family }, (err, addresses) => {
      if (err) return callback(err);
      const bad = addresses.find((a) => !isPublicIp(a.address));
      if (bad || addresses.length === 0) {
        return callback(new BlockedAddressError(`${hostname} resolves to a blocked address${bad ? ` (${bad.address})` : ""}`));
      }
      if (opts.all) callback(null, addresses);
      else callback(null, addresses[0].address, addresses[0].family);
    });
  };
}
```

- [ ] **Step 4: Implement `node.ts` and `serve.ts`**

`proxy/src/node.ts`:
```ts
import http from "node:http";
import { Agent, fetch as undiciFetch } from "undici";
import { type Deps, type Env, handleRequest } from "./handler";
import { createSharpResizer } from "./img-sharp";
import { type Resolver, guardedLookup } from "./lookup";

/** Node platform pieces: undici fetch whose DNS lookup refuses private addresses, and sharp. */
export function nodeDeps(resolve?: Resolver): Deps {
  const agent = new Agent({ connect: { lookup: guardedLookup(resolve) as never } });
  return {
    fetch: (url, init) =>
      undiciFetch(url, { ...init, dispatcher: agent } as Parameters<typeof undiciFetch>[1]) as unknown as Promise<Response>,
    resizer: createSharpResizer(),
  };
}

const HOP_BY_HOP = new Set(["host", "connection", "keep-alive", "transfer-encoding", "upgrade"]);

export function createServer(env: Env, deps: Deps): http.Server {
  return http.createServer(async (req, res) => {
    try {
      const headers = new Headers();
      for (const [name, value] of Object.entries(req.headers)) {
        if (HOP_BY_HOP.has(name) || value === undefined) continue;
        for (const v of Array.isArray(value) ? value : [value]) headers.append(name, v);
      }
      const request = new Request(`http://${req.headers.host ?? "localhost"}${req.url ?? "/"}`, { method: req.method, headers });
      const response = await handleRequest(request, env, deps);
      res.writeHead(response.status, Object.fromEntries(response.headers));
      res.end(Buffer.from(await response.arrayBuffer()));
    } catch (e) {
      console.error(e);
      res.writeHead(500, { "Content-Type": "text/plain; charset=us-ascii" });
      res.end("Internal error\n");
    }
  });
}
```

`proxy/src/serve.ts`:
```ts
import { createServer, nodeDeps } from "./node";

const port = Number(process.env.PORT ?? 8080);
const env = { PROXY_TOKEN: process.env.PROXY_TOKEN, USER_AGENT: process.env.USER_AGENT };
if (!env.PROXY_TOKEN) console.warn("PROXY_TOKEN is not set: every request will get 500");
createServer(env, nodeDeps()).listen(port, () => console.log(`picosurf-proxy listening on :${port}`));
```

- [ ] **Step 5: Run the tests to make sure they pass**

Run: `npx vitest run test/node.test.ts`
Expected: all pass.

- [ ] **Step 6: Add the Docker image**

`proxy/Dockerfile`:
```dockerfile
FROM node:22-slim
WORKDIR /app
ENV NODE_ENV=production PORT=8080
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY tsconfig.json ./
COPY src ./src
USER node
EXPOSE 8080
CMD ["npx", "tsx", "src/serve.ts"]
```

`proxy/.dockerignore`:
```
node_modules
test
scripts
.wrangler
.dev.vars
dist
```

- [ ] **Step 7: Check the server by hand**

Run: `PROXY_TOKEN=dev-token PORT=8080 npm start`. In another terminal:
```bash
curl -s -H 'Authorization: Bearer dev-token' http://localhost:8080/v1/ping
curl -s -D - -H 'Authorization: Bearer dev-token' 'http://localhost:8080/v1/get?url=https%3A%2F%2Fen.wikipedia.org%2Fwiki%2FGemini_(protocol)' | head -20
```
Expected: `picosurf-proxy 1`, then headers with `X-Mode: reader`, then `# Gemini (protocol)`.

If `docker` or `podman` is installed, also run:
```bash
docker build -t picosurf-proxy proxy
docker run --rm -e PROXY_TOKEN=dev-token -p 8080:8080 picosurf-proxy
```
Then repeat the first curl. If neither tool is installed, note that in the commit body.

- [ ] **Step 8: Commit**

```bash
git add proxy/src/lookup.ts proxy/src/node.ts proxy/src/serve.ts proxy/Dockerfile proxy/.dockerignore proxy/test/node.test.ts
git commit -m "feat(proxy): Node server with DNS-time address guard; Docker image"
```

---

### Task 13: The Workers entry point and deploy docs

**Files:**
- Create: `proxy/src/worker.ts`, `proxy/src/wasm.d.ts`, `proxy/wrangler.toml`, `proxy/README.md`

**Interfaces:**
- Consumes: `handleRequest`, `Env` (Task 11), `createWasmResizer` (Task 10).
- Produces: the Worker's default export, `{ fetch(request, env) }`.

- [ ] **Step 1: Write the Worker files**

`proxy/src/wasm.d.ts`:
```ts
// wrangler bundles .wasm imports as compiled modules.
declare module "*.wasm" {
  const module: WebAssembly.Module;
  export default module;
}
```

`proxy/src/worker.ts`:
```ts
import { type Env, handleRequest } from "./handler";
import { createWasmResizer } from "./img-wasm";
import JPEG_DEC from "../node_modules/@jsquash/jpeg/codec/dec/mozjpeg_dec.wasm";
import JPEG_ENC from "../node_modules/@jsquash/jpeg/codec/enc/mozjpeg_enc.wasm";
import PNG_DEC from "../node_modules/@jsquash/png/codec/pkg/squoosh_png_bg.wasm";
import WEBP_DEC from "../node_modules/@jsquash/webp/codec/dec/webp_dec.wasm";
import RESIZE from "../node_modules/@jsquash/resize/lib/resize/pkg/squoosh_resize_bg.wasm";

const resizer = createWasmResizer({ jpegDec: JPEG_DEC, jpegEnc: JPEG_ENC, pngDec: PNG_DEC, webpDec: WEBP_DEC, resize: RESIZE });

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return handleRequest(request, env, { fetch: (url, init) => fetch(url, init), resizer });
  },
};
```

`proxy/wrangler.toml`:
```toml
name = "picosurf-proxy"
main = "src/worker.ts"
compatibility_date = "2026-09-01"
compatibility_flags = ["nodejs_compat"]
workers_dev = true

[observability]
enabled = true
```

- [ ] **Step 2: Typecheck**

Run: `npm run typecheck`
Expected: no errors.

- [ ] **Step 3: Check the Worker under `wrangler dev`**

```bash
printf 'PROXY_TOKEN=dev-token\n' > .dev.vars
npx wrangler dev --port 8787
```
In another terminal:
```bash
H='Authorization: Bearer dev-token'
curl -s -H "$H" http://localhost:8787/v1/ping
curl -s -D - -H "$H" 'http://localhost:8787/v1/get?url=https%3A%2F%2Fen.wikipedia.org%2Fwiki%2FGemini_(protocol)' | head -20
curl -s -H "$H" 'http://localhost:8787/v1/get?url=https%3A%2F%2Fhnrss.org%2Ffrontpage' | head -5
curl -s -H "$H" 'http://localhost:8787/v1/get?url=https%3A%2F%2Fpicsum.photos%2F800%2F600.jpg' -o /dev/stdout | file -
curl -s -o /dev/null -w '%{http_code}\n' -H "$H" 'http://localhost:8787/v1/get?url=http%3A%2F%2F127.0.0.1%2F'
```
Expected, in order:
1. `picosurf-proxy 1`
2. `X-Mode: reader` and `# Gemini (protocol)`
3. a `# ` feed title, then dated `=>` lines
4. `JPEG image data, baseline, … 320x240`
5. `403`

- [ ] **Step 4: Check the bundle builds**

Run: `npx wrangler deploy --dry-run --outdir dist`
Expected: a successful build with a total upload size printed under 3 MB gzip. Record the size in the commit body.

- [ ] **Step 5: Write the proxy README**

`proxy/README.md`:
````markdown
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
````

- [ ] **Step 6: Commit**

```bash
rm -rf dist
git add proxy/src/worker.ts proxy/src/wasm.d.ts proxy/wrangler.toml proxy/README.md
git commit -m "feat(proxy): Cloudflare Worker entry and deploy docs"
```

---

### Task 14: Smoke script and CI

**Files:**
- Create: `proxy/scripts/smoke.ts`, `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `handleRequest` (Task 11), `nodeDeps` (Task 12).
- Produces: `npm run smoke [file]`. The optional file lists one URL per line; a line starting `feed ` is fetched with `as=feed`.

- [ ] **Step 1: Write the smoke script**

`proxy/scripts/smoke.ts`:
```ts
// Fetches real sites through the handler in-process and reports what came back
// (spec 7.1). Nothing is saved. Usage: npm run smoke [urls.txt]
// A line in urls.txt is a URL, or "feed <URL>" to fetch it with as=feed.
import { readFileSync } from "node:fs";
import { handleRequest } from "../src/handler";
import { nodeDeps } from "../src/node";

const DEFAULT = [
  "https://news.ycombinator.com/",
  "https://lobste.rs/",
  "https://www.bbc.com/news",
  "https://arstechnica.com/",
  "https://jvns.ca/",
  "https://github.com/PicoDeck/picodeck",
  "https://en.wikipedia.org/wiki/Special:Random",
  "feed https://hnrss.org/frontpage",
  "feed https://lobste.rs/rss",
  "feed https://jvns.ca/atom.xml",
  "feed https://feeds.bbci.co.uk/news/rss.xml",
];

const lines = process.argv[2] ? readFileSync(process.argv[2], "utf8").split("\n") : DEFAULT;
const deps = nodeDeps();
const env = { PROXY_TOKEN: "smoke" };

console.log(["status", "mode", "KB", "links", "wall ms", "cpu ms", "url"].join("\t"));
for (const line of lines.map((l) => l.trim()).filter(Boolean)) {
  const [as, url] = line.startsWith("feed ") ? ["feed", line.slice(5).trim()] : ["reader", line];
  const started = performance.now();
  const cpu = process.cpuUsage();
  const res = await handleRequest(
    new Request(`http://smoke/v1/get?url=${encodeURIComponent(url)}&as=${as}`, { headers: { Authorization: "Bearer smoke" } }),
    env,
    deps,
  );
  const body = await res.text();
  const used = process.cpuUsage(cpu);
  const links = body.split("\n").filter((l) => l.startsWith("=> ")).length;
  const mode = res.headers.get("X-Mode") ?? (res.ok ? "-" : body.trim());
  console.log(
    [res.status, mode, (body.length / 1024).toFixed(1), links, Math.round(performance.now() - started), Math.round((used.user + used.system) / 1000), url].join("\t"),
  );
}
```

- [ ] **Step 2: Run it**

Run: `npm run smoke`
Expected:
- One row per URL.
- Pages return `200` with mode `reader` or `full` and more than 1 KB.
- Feeds return `200 feed` with more than 5 links.

A site that blocks the proxy (`403` or `502`) is a real finding: **record it in the commit body** rather than working around it. The `cpu ms` column roughly estimates Worker CPU per request, which shows whether the Workers Paid plan is really needed (spec 5.9).

- [ ] **Step 3: Add CI**

`.github/workflows/ci.yml`:
```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
jobs:
  proxy:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: proxy
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm
          cache-dependency-path: proxy/package-lock.json
      - run: npm ci
      - run: npm run typecheck
      - run: npm test
```

- [ ] **Step 4: Run the whole suite as CI would**

Run: `CI=true npm test && npm run typecheck`
Expected: everything passes. Under `CI=true`, vitest refuses to write new snapshots, which confirms the committed ones are complete.

- [ ] **Step 5: Commit**

```bash
git add proxy/scripts/smoke.ts .github/workflows/ci.yml
git commit -m "chore(proxy): live smoke script and CI"
```
Paste the smoke table into the commit body.
