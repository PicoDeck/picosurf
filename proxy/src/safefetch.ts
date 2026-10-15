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
