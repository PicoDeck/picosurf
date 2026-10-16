import { describe, expect, it } from "vitest";
import sharp from "sharp";
import { BoxScaler, boxScale } from "../src/boxscale";
import { fitWithin } from "../src/img";
import { meanAbsError, sharpReference } from "./helpers/pixels";
import { ADAM7 } from "./helpers/png";

/** A width x height RGBA image from a per-pixel function. */
function image(width: number, height: number, px: (x: number, y: number) => [number, number, number, number]): Uint8ClampedArray {
  const data = new Uint8ClampedArray(width * height * 4);
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) data.set(px(x, y), (y * width + x) * 4);
  return data;
}

const gradient = (w: number, h: number) => image(w, h, (x, y) => [(x * 255) / w, (y * 255) / h, ((x + y) * 255) / (w + h), 255]);
const checkerboard = (cell: number) => (w: number, h: number) =>
  image(w, h, (x, y) => ((Math.floor(x / cell) + Math.floor(y / cell)) & 1 ? [255, 255, 255, 255] : [0, 0, 0, 255]));

describe("boxScale", () => {
  it("averages each 2x2 block exactly at half size", () => {
    const src = image(4, 2, (x) => [x * 10, x * 20, 100, 255]);
    const out = boxScale(src, 4, 2, { width: 2, height: 1 });
    expect(out).toMatchObject({ width: 2, height: 1 });
    expect(Array.from(out.data)).toEqual([5, 10, 100, 255, 25, 50, 100, 255]);
  });

  it("splits a pixel that straddles two output pixels by area", () => {
    // 3 pixels into 2: the middle one is half in each.
    const out = boxScale(Uint8ClampedArray.of(0, 0, 0, 255, 90, 90, 90, 255, 180, 180, 180, 255), 3, 1, { width: 2, height: 1 });
    expect(Array.from(out.data)).toEqual([30, 30, 30, 255, 150, 150, 150, 255]);
  });

  it("keeps the mean of the image at a non-integer ratio", () => {
    const [w, h] = [997, 613];
    const src = gradient(w, h);
    const out = boxScale(src, w, h, fitWithin(w, h));
    const mean = (d: Uint8ClampedArray, c: number) => d.filter((_, i) => i % 4 === c).reduce((s, v) => s + v, 0) / (d.length / 4);
    for (const c of [0, 1, 2]) expect(mean(out.data, c)).toBeCloseTo(mean(src, c), 0);
  });

  it("composites transparent pixels over white", () => {
    const src = image(2, 2, (x) => (x === 0 ? [0, 0, 0, 0] : [200, 0, 0, 128]));
    expect(Array.from(boxScale(src, 2, 2, { width: 2, height: 2 }).data)).toEqual([
      255, 255, 255, 255, 227, 127, 127, 255, 255, 255, 255, 255, 227, 127, 127, 255,
    ]);
  });

  it("copies an image that needs no scaling", () => {
    const src = gradient(200, 100);
    expect(boxScale(src, 200, 100, { width: 200, height: 100 }).data).toEqual(src);
  });

  it.each([
    ["a gradient", 1000, 750, gradient],
    ["a gradient, portrait", 613, 997, gradient],
    ["a checkerboard of 100-pixel squares", 1000, 750, checkerboard(100)],
    ["a checkerboard of 100-pixel squares at an odd ratio", 1013, 517, checkerboard(100)],
  ])("matches sharp on %s (%dx%d)", async (_name, w, h, make) => {
    const src = make(w, h);
    const size = fitWithin(w, h);
    const out = boxScale(src, w, h, size);
    expect(out).toMatchObject(size);
    const ref = await sharpReference(sharp(src, { raw: { width: w, height: h, channels: 4 } }), size);
    expect(meanAbsError(out.data, ref)).toBeLessThan(3);
  });

  // Point sampling would turn this into black and white squares. A box filter
  // leaves up to about 10 levels of ripple at a ratio of about 3 (sharp's
  // lanczos3 about 4), so the bound against sharp is a little looser.
  it.each([
    [1000, 750],
    [1013, 517],
  ])("averages a one-pixel checkerboard to grey (%dx%d)", async (w, h) => {
    const src = checkerboard(1)(w, h);
    const size = fitWithin(w, h);
    const out = boxScale(src, w, h, size);
    for (let i = 0; i < out.data.length; i += 4) expect(Math.abs(out.data[i] - 127.5)).toBeLessThan(16);
    const ref = await sharpReference(sharp(src, { raw: { width: w, height: h, channels: 4 } }), size);
    expect(meanAbsError(out.data, ref)).toBeLessThan(4);
  });
});

describe("BoxScaler", () => {
  it("takes rows at an offset into a larger buffer", () => {
    const src = gradient(64, 48);
    const scaler = new BoxScaler(64, 48, { width: 20, height: 15 });
    for (let y = 0; y < 48; y++) scaler.addRow(src, y * 64 * 4);
    expect(scaler.finish().data).toEqual(boxScale(src, 64, 48, { width: 20, height: 15 }).data);
  });

  it("takes rows in any order and every few pixels, as an interlaced PNG's passes come", () => {
    const [w, h] = [997, 613];
    const src = gradient(w, h);
    const size = fitWithin(w, h);
    const scaler = new BoxScaler(w, h, size);
    const row = new Uint8Array(w * 4);
    for (const [x0, y0, dx, dy] of ADAM7) {
      for (let y = y0; y < h; y += dy) {
        let n = 0;
        for (let x = x0; x < w; x += dx, n++) row.set(src.subarray((y * w + x) * 4, (y * w + x) * 4 + 4), n * 4);
        if (n > 0) scaler.addPixels(y, row, x0, dx, n);
      }
    }
    const out = scaler.finish().data;
    const expected = boxScale(src, w, h, size).data;
    let worst = 0;
    for (let i = 0; i < out.length; i++) worst = Math.max(worst, Math.abs(out[i] - expected[i]));
    expect(worst).toBeLessThanOrEqual(1); // the sums add up in another order
  });

  it("refuses pixels outside the image", () => {
    const scaler = new BoxScaler(8, 8, { width: 4, height: 4 });
    expect(() => scaler.addPixels(8, new Uint8Array(32), 0, 1, 8)).toThrow();
    expect(() => scaler.addPixels(0, new Uint8Array(32), 1, 2, 5)).toThrow();
  });

  it("refuses to finish before every row has arrived", () => {
    const scaler = new BoxScaler(4, 4, { width: 2, height: 2 });
    scaler.addRow(new Uint8ClampedArray(16));
    expect(() => scaler.finish()).toThrow();
  });

  it("refuses more rows than the image has", () => {
    const scaler = new BoxScaler(4, 1, { width: 2, height: 1 });
    scaler.addRow(new Uint8ClampedArray(16));
    expect(() => scaler.addRow(new Uint8ClampedArray(16))).toThrow();
  });
});
