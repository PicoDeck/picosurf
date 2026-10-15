// Routing, auth and dispatch by content kind (spec 5.1-5.3). Platform-neutral:
// worker.ts and node.ts supply `fetch` and the image resizer.

import { foldAscii } from "./ascii";
import { decodeText, imageTypeFromMime, kindFromMime, mimeOf, sniffImageType, sniffKind } from "./content";
import { ProxyError, textResponse } from "./errors";
import { feedToGemtext, parseFeed } from "./feed";
import type { Resizer } from "./img";
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
        ...(page.coverage !== null ? { "X-Coverage": page.coverage.toFixed(2) } : {}),
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
  // A zero dimension is unreadable: 0 pixels would slip past the pixel cap.
  if (!size || size.width <= 0 || size.height <= 0) throw new ProxyError(415, "Could not read the image size");
  if (size.width * size.height > resizer.maxPixels) throw new ProxyError(413, `Image too large (${size.width}x${size.height})`);
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

/**
 * Folds to ASCII and cuts at a line boundary under OUTPUT_CAP (mid-line when
 * there is none), closing an open fence first.
 */
function capped(raw: string, contentType: string, headers: Record<string, string>): Response {
  let body = foldAscii(raw);
  const extra: Record<string, string> = {};
  if (body.length > OUTPUT_CAP) {
    const cut = body.lastIndexOf("\n", OUTPUT_CAP - 32);
    body = cut === -1 ? body.slice(0, OUTPUT_CAP - 32) + "\n" : body.slice(0, cut + 1);
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
