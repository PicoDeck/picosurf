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

  it.each(["https://user:pass@example.com/", "https://user@example.com/", "https://:pass@example.com/"])(
    "refuses %s with 400 before fetching",
    async (url) => {
      const f = fakeFetch({});
      await expect(safeFetch(url, opts(f))).rejects.toMatchObject({ status: 400, message: "URLs with credentials are not supported" });
      expect(f.calls).toHaveLength(0);
    },
  );

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
