import { describe, expect, it } from "vitest";
import { fitWithin } from "../src/img";
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

resizerContract("sharp", async () => createSharpResizer());
