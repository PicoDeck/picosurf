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

/** Every Resizer must pass these: baseline JPEG, within 320x320, never enlarged, transparency on white. */
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

    it.each(["photo.png", "photo-alpha.webp"] as const)("flattens transparency in %s onto white", async (file) => {
      const out = await resizer.resize(imageFixture(file), file.endsWith(".png") ? "png" : "webp");
      const { data } = await sharp(out).raw().toBuffer({ resolveWithObject: true });
      expect(data[0]).toBeGreaterThan(100); // red: about 142 on white, about 15 on black
      expect(data[2]).toBeGreaterThan(200); // blue
    });
  });
}
