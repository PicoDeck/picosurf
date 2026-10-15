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
    "::ffff:127.0.0.1", "::ffff:10.0.0.1", "64:ff9b::a00:1", "2002:a00:1::1", "::7f00:1", "::a00:1", "::808:808", "not-an-ip",
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
  it.each(["http://2130706433/", "http://0x7f.1/", "http://0177.0.0.1/", "http://127.1/", "http://[::ffff:127.0.0.1]/", "http://[::127.0.0.1]/"])(
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
