import { describe, expect, it } from "vitest";
import { fitWithin } from "../src/img";
import { createSharpResizer } from "../src/img-sharp";
import sharp, { type JpegOptions } from "sharp";
import { imageSize, jpegInfo, jpegScans } from "../src/imgsize";
import { photo } from "./helpers/png";
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

describe("jpegInfo and jpegScans", () => {
  const jpeg = async (options: JpegOptions, grey = false) => {
    const img = sharp(photo(64, 48, 3), { raw: { width: 64, height: 48, channels: 3 } });
    return new Uint8Array(await (grey ? img.toColourspace("b-w") : img).jpeg(options).toBuffer());
  };

  it.each([
    ["4:2:0", { chromaSubsampling: "4:2:0" }, [[2, 2], [1, 1], [1, 1]]],
    ["4:4:4", { chromaSubsampling: "4:4:4" }, [[1, 1], [1, 1], [1, 1]]],
  ] as const)("reads each component's sampling factors, %s", async (_name, options, factors) => {
    expect(jpegInfo(await jpeg(options))?.components).toEqual(factors);
  });

  it("reads a greyscale JPEG's one component", async () => {
    expect(jpegInfo(await jpeg({}, true))?.components).toEqual([[1, 1]]);
  });

  it("counts the scans: one in a baseline JPEG, several in a progressive one", async () => {
    expect(jpegScans(await jpeg({}))).toBe(1);
    expect(jpegScans(await jpeg({ progressive: true }))).toBeGreaterThan(1);
  });

  it("stops counting at a truncated scan", () => {
    expect(jpegScans(Uint8Array.of(0xff, 0xd8, 0xff, 0xda, 0, 8, 1, 1, 0, 0, 63, 0, 0x12, 0x34))).toBe(1);
  });
});

describe("fitWithin", () => {
  it.each([
    [800, 600, 320, 240], [600, 800, 240, 320], [200, 100, 200, 100], [5000, 10, 320, 1], [320, 320, 320, 320],
  ])("%dx%d → %dx%d", (w, h, ew, eh) => expect(fitWithin(w, h)).toEqual({ width: ew, height: eh }));
});

resizerContract("sharp", async () => createSharpResizer());
