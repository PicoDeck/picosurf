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

/** The box PicoSurf asks for inline pictures (fit=312x126). */
const BOX = { width: 312, height: 126 };
const BOX_CASES: [string, ImageType, number, number][] = [
  ["photo.jpg", "jpeg", 168, 126],
  ["photo-progressive.jpg", "jpeg", 168, 126],
  ["photo.png", "png", 168, 126],
  ["photo.webp", "webp", 168, 126],
  ["photo.gif", "gif", 168, 126],
  ["small.png", "png", 200, 100],
];

/** Every Resizer must pass these: baseline JPEG, within 320x320 or the box given, never enlarged, transparency on white. */
export function resizerContract(name: string, make: () => Promise<Resizer>): void {
  describe(`${name} resizer`, () => {
    let resizer: Resizer;
    beforeAll(async () => {
      resizer = await make();
    });

    it.each(CASES)("declares a pixel cap for %s that lets it through", (file, type, _w, _h) => {
      expect(resizer.maxPixels(imageFixture(file), type)).toBeGreaterThanOrEqual(800 * 600);
    });

    it.each(CASES)("%s (%s) → baseline JPEG %dx%d", async (file, type, width, height) => {
      const out = await resizer.resize(imageFixture(file), type);
      const info = jpegInfo(out);
      expect(info?.sof).toBe(0xc0);
      expect(info?.size).toEqual({ width, height });
    });

    it.each(BOX_CASES)("%s (%s) in a 312x126 box → baseline JPEG %dx%d, under 32 KB", async (file, type, width, height) => {
      const out = await resizer.resize(imageFixture(file), type, BOX);
      const info = jpegInfo(out);
      expect(info?.sof).toBe(0xc0);
      expect(info?.size).toEqual({ width, height });
      // Measured: each fixture comes out at 400 B with sharp and 402 B with wasm
      // (small.png: 406 and 408 B). The fixtures are flat colour, so that's a
      // floor; the noisy photo() of helpers/png.ts at 800x600 (a quality 80 JPEG)
      // comes out at 1,796 and 1,759 B.
      expect(out.length).toBeLessThan(32 * 1024); // the app keeps 512 KB of these per page
    });

    it.each(["photo.png", "photo-alpha.webp"] as const)("flattens transparency in %s onto white", async (file) => {
      const out = await resizer.resize(imageFixture(file), file.endsWith(".png") ? "png" : "webp");
      const { data } = await sharp(out).raw().toBuffer({ resolveWithObject: true });
      expect(data[0]).toBeGreaterThan(100); // red: about 142 on white, about 15 on black
      expect(data[2]).toBeGreaterThan(200); // blue
    });
  });
}
