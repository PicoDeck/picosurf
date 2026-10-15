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
