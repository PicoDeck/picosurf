import { describe, expect, it, vi } from "vitest";
import { ProxyError } from "../src/errors";
import { type Deps, OUTPUT_CAP, handleRequest } from "../src/handler";
import type { Resizer } from "../src/img";
import { fakeFetch, html, redirect } from "./helpers/fakefetch";
import { articleHtml } from "./helpers/pages";
import { imageFixture } from "./helpers/resizer-contract";

const TOKEN = "secret-token";
const env = { PROXY_TOKEN: TOKEN };
const JPEG_OUT = Uint8Array.of(0xff, 0xd8, 0xff, 0xd9);

function deps(routes: Parameters<typeof fakeFetch>[0] = {}, maxPixels = 16_000_000) {
  const fetch = fakeFetch(routes);
  const resizer = { maxPixels: vi.fn<Resizer["maxPixels"]>(() => maxPixels), resize: vi.fn<Resizer["resize"]>(async () => JPEG_OUT) };
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
  it("sends X-Coverage with two decimals in reader mode only", async () => {
    const d = deps({ "https://example.com/": html(articleHtml()) });
    expect((await get("https://example.com/", d.deps)).headers.get("X-Coverage")).toMatch(/^[01]\.\d\d$/);
    expect((await get("https://example.com/", d.deps, "full")).headers.get("X-Coverage")).toBeNull();
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
  it("refuses images over the resizer's own pixel cap", async () => {
    const png = new Uint8Array(33);
    png.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);
    new DataView(png.buffer).setUint32(16, 2000);
    new DataView(png.buffer).setUint32(20, 1000);
    const d = deps({ "https://example.com/big.png": new Response(png, { headers: { "Content-Type": "image/png" } }) }, 1_000_000);
    const res = await get("https://example.com/big.png", d.deps);
    expect(res.status).toBe(413);
    expect(await res.text()).toBe("Image too large (2000x1000)\n");
    expect(d.resizer.resize).not.toHaveBeenCalled();
  });
  it("asks the resizer for the cap of this image", async () => {
    const d = deps({ "https://example.com/a.png": new Response(imageFixture("photo.png"), { headers: { "Content-Type": "image/png" } }) });
    await get("https://example.com/a.png", d.deps);
    expect(d.resizer.maxPixels).toHaveBeenCalledWith(imageFixture("photo.png"), "png");
  });
  it("lets through an image of exactly the cap", async () => {
    const d = deps({ "https://example.com/a.png": new Response(imageFixture("photo.png"), { headers: { "Content-Type": "image/png" } }) }, 800 * 600);
    expect((await get("https://example.com/a.png", d.deps)).status).toBe(200);
  });
  it("415s an image with a zero dimension without decoding it", async () => {
    const png = new Uint8Array(33);
    png.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);
    new DataView(png.buffer).setUint32(16, 0);
    new DataView(png.buffer).setUint32(20, 100);
    const d = deps({ "https://example.com/zero.png": new Response(png, { headers: { "Content-Type": "image/png" } }) });
    const res = await get("https://example.com/zero.png", d.deps);
    expect(res.status).toBe(415);
    expect(await res.text()).toBe("Could not read the image size\n");
    expect(d.resizer.resize).not.toHaveBeenCalled();
  });
  it("passes a resizer's own refusal through: its status, reason and headers", async () => {
    const d = deps({ "https://example.com/a.jpg": new Response(imageFixture("photo.jpg"), { headers: { "Content-Type": "image/jpeg" } }) });
    d.resizer.resize.mockRejectedValueOnce(new ProxyError(503, "Busy, try again shortly", { "Retry-After": "30" }));
    const res = await get("https://example.com/a.jpg", d.deps);
    expect(res.status).toBe(503);
    expect(res.headers.get("Retry-After")).toBe("30");
    expect(await res.text()).toBe("Busy, try again shortly\n");
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
  it("hard-cuts long output that has no line break", async () => {
    const line = "z".repeat(300 * 1024);
    const d = deps({ "https://example.com/t.txt": new Response(line, { headers: { "Content-Type": "text/plain" } }) });
    const res = await get("https://example.com/t.txt", d.deps);
    const body = await res.text();
    expect(res.headers.get("X-Truncated")).toBe("1");
    expect(body).toBe(line.slice(0, OUTPUT_CAP - 32) + "\n(Page truncated)\n");
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
