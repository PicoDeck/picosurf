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
