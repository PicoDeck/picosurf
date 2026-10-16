import { describe, expect, it, vi } from "vitest";
import sharp from "sharp";
import { fitWithin } from "../src/img";
import { PNG_STREAM_MAX_WIDTH, canStreamPng, streamPng } from "../src/png-stream";
import { meanAbsError, sharpReference } from "./helpers/pixels";
import { CHANNELS, type ColorType, type RawPng, SIGNATURE, chunk, concat, encodePng, ihdr, imageData, photo } from "./helpers/png";

/** A ramp palette: neighbouring indexes have neighbouring colours. */
const PALETTE = Uint8Array.from({ length: 256 * 3 }, (_, i) => [Math.floor(i / 3), 255 - Math.floor(i / 3), (Math.floor(i / 3) * 3) & 0xff][i % 3]);

function raw(width: number, height: number, colorType: ColorType, extra: Partial<RawPng> = {}): RawPng {
  const pixels = colorType === 3 ? photo(width, height, 1) : photo(width, height, CHANNELS[colorType]);
  return { width, height, colorType, pixels, ...extra };
}

/** What `p` looks like over white, worked out from its samples directly. */
function expectedRgba(p: RawPng): number[] {
  const out: number[] = [];
  const key = (i: number) => (p.trns ? (p.trns[i] << 8) | p.trns[i + 1] : -1);
  for (let i = 0; i < p.width * p.height; i++) {
    let rgba: number[];
    if (p.colorType === 0) {
      const g = p.pixels[i];
      rgba = [g, g, g, g === key(0) ? 0 : 255];
    } else if (p.colorType === 2) {
      const [r, g, b] = p.pixels.subarray(i * 3, i * 3 + 3);
      rgba = [r, g, b, r === key(0) && g === key(2) && b === key(4) ? 0 : 255];
    } else if (p.colorType === 3) {
      const n = p.pixels[i];
      rgba = [...(p.palette as Uint8Array).subarray(n * 3, n * 3 + 3), p.trns && n < p.trns.length ? p.trns[n] : 255];
    } else if (p.colorType === 4) {
      const [g, a] = p.pixels.subarray(i * 2, i * 2 + 2);
      rgba = [g, g, g, a];
    } else {
      rgba = Array.from(p.pixels.subarray(i * 4, i * 4 + 4));
    }
    const a = rgba[3];
    out.push(...rgba.slice(0, 3).map((c) => (c * a) / 255 + 255 - a), 255);
  }
  return out;
}

async function expectLikeSharp(png: Uint8Array, width: number, height: number) {
  const size = fitWithin(width, height);
  const out = await streamPng(png);
  expect({ width: out.width, height: out.height }).toEqual(size);
  expect(out.data.length).toBe(size.width * size.height * 4);
  const ref = await sharpReference(sharp(png), size);
  expect(meanAbsError(out.data, ref)).toBeLessThan(3);
  return out;
}

describe("streamPng", () => {
  it.each([
    ["grey (0)", raw(1013, 517, 0)],
    ["grey with a tRNS key (0)", raw(640, 480, 0, { trns: Uint8Array.of(0, 128) })],
    ["RGB (2)", raw(517, 1013, 2)],
    ["RGB with a tRNS key (2)", raw(800, 600, 2, { trns: Uint8Array.of(0, 30, 0, 120, 0, 200) })],
    ["palette (3)", raw(800, 600, 3, { palette: PALETTE })],
    ["palette with tRNS (3)", raw(997, 613, 3, { palette: PALETTE, trns: Uint8Array.from({ length: 100 }, (_, i) => i * 2) })],
    ["grey and alpha (4)", raw(640, 480, 4)],
    ["RGBA (6)", raw(1000, 333, 6)],
    ["RGBA (6), a long strip", raw(5000, 7, 6)],
  ])("decodes %s like sharp, with every filter type", async (_name, p) => {
    await expectLikeSharp(encodePng(p), p.width, p.height);
  });

  it.each([
    ["grey", 1],
    ["grey and alpha", 2],
    ["RGB", 3],
    ["RGBA", 4],
  ] as const)("decodes sharp's own %s PNG like sharp", async (_name, channels) => {
    const [width, height] = [1200, 700];
    const png = await sharp(photo(width, height, channels), { raw: { width, height, channels } }).png().toBuffer();
    expect(canStreamPng(png)).toBe(true);
    await expectLikeSharp(new Uint8Array(png), width, height);
  });

  it("decodes sharp's palette PNG with transparency like sharp", async () => {
    const [width, height] = [900, 500];
    const png = await sharp(photo(width, height, 4), { raw: { width, height, channels: 4 } }).png({ palette: true, colours: 256 }).toBuffer();
    expect([png[24], png[25]]).toEqual([8, 3]); // 8-bit palette
    await expectLikeSharp(new Uint8Array(png), width, height);
  });

  // Exact, so a slip in any filter shows; the scaled comparisons above average it away.
  it.each([
    ["grey", raw(300, 200, 0, { trns: Uint8Array.of(0, 128) })],
    ["RGB", raw(300, 200, 2, { trns: Uint8Array.of(0, 30, 0, 120, 0, 200) })],
    ["palette", raw(300, 200, 3, { palette: PALETTE, trns: Uint8Array.from({ length: 100 }, (_, i) => i * 2) })],
    ["grey and alpha", raw(300, 200, 4)],
    ["RGBA", raw(300, 200, 6)],
  ])("reproduces every %s pixel at full size", async (_name, p) => {
    const out = await streamPng(encodePng(p));
    const expected = expectedRgba(p);
    let worst = 0;
    for (let i = 0; i < expected.length; i++) worst = Math.max(worst, Math.abs(out.data[i] - expected[i]));
    expect(worst).toBeLessThanOrEqual(1); // rounding of the white composite
  });

  it("returns the pixels as they are when the image needs no scaling", async () => {
    const pixels = photo(200, 100, 3);
    const out = await streamPng(encodePng({ width: 200, height: 100, colorType: 2, pixels }));
    expect(out).toMatchObject({ width: 200, height: 100 });
    const rgba = new Uint8ClampedArray(200 * 100 * 4).fill(255);
    for (let i = 0; i < 200 * 100; i++) rgba.set(pixels.subarray(i * 3, i * 3 + 3), i * 4);
    expect(out.data).toEqual(rgba);
  });

  it("takes image data split into one-byte IDAT chunks", async () => {
    const p = raw(64, 48, 6);
    expect(await streamPng(encodePng(p, 1))).toEqual(await streamPng(encodePng(p)));
  });

  it("gathers tiny IDAT chunks into a few large writes", async () => {
    const p = raw(400, 300, 2);
    const png = encodePng(p, 1); // about 100,000 one-byte IDAT chunks
    const writes = vi.spyOn(WritableStreamDefaultWriter.prototype, "write");
    try {
      expect(await streamPng(png)).toEqual(await streamPng(encodePng(p)));
      expect(writes.mock.calls.length).toBeLessThan(10);
    } finally {
      writes.mockRestore();
    }
  });

  it("decodes a 1x1 image", async () => {
    const out = await streamPng(encodePng({ width: 1, height: 1, colorType: 2, pixels: Uint8Array.of(10, 20, 30) }));
    expect(out).toEqual({ width: 1, height: 1, data: Uint8ClampedArray.of(10, 20, 30, 255) });
  });
});

describe("canStreamPng", () => {
  it.each([0, 2, 3, 4, 6] as const)("takes 8-bit colour type %d", (colorType) => {
    expect(canStreamPng(concat(SIGNATURE, ihdr(10, 10, colorType)))).toBe(true);
  });

  it("leaves 16-bit PNGs to the fallback decoder", async () => {
    const png = await sharp(photo(50, 40, 3), { raw: { width: 50, height: 40, channels: 3 } }).toColourspace("rgb16").png().toBuffer();
    expect(png[24]).toBe(16);
    expect(canStreamPng(png)).toBe(false);
  });

  it("leaves interlaced PNGs to the fallback decoder", async () => {
    const png = await sharp(photo(50, 40, 3), { raw: { width: 50, height: 40, channels: 3 } }).png({ progressive: true }).toBuffer();
    expect(png[28]).toBe(1);
    expect(canStreamPng(png)).toBe(false);
  });

  it.each([1, 2, 4])("leaves %d-bit PNGs to the fallback decoder", (bitDepth) => {
    expect(canStreamPng(concat(SIGNATURE, ihdr(10, 10, 3, bitDepth)))).toBe(false);
    expect(canStreamPng(concat(SIGNATURE, ihdr(10, 10, 0, bitDepth)))).toBe(false);
  });

  it("leaves PNGs wider than PNG_STREAM_MAX_WIDTH to the fallback decoder, so rows stay small", () => {
    expect(canStreamPng(concat(SIGNATURE, ihdr(PNG_STREAM_MAX_WIDTH, 1, 6)))).toBe(true);
    expect(canStreamPng(concat(SIGNATURE, ihdr(PNG_STREAM_MAX_WIDTH + 1, 1, 6)))).toBe(false);
  });

  it("refuses what is not a PNG header", () => {
    expect(canStreamPng(Uint8Array.of(0x89, 0x50))).toBe(false);
    expect(canStreamPng(concat(SIGNATURE, chunk("tEXt", new Uint8Array(13))))).toBe(false);
    expect(canStreamPng(concat(SIGNATURE, ihdr(10, 10, 5)))).toBe(false);
  });
});

describe("streamPng refuses broken PNGs", () => {
  const p = raw(300, 200, 2);
  const good = encodePng(p, 4096);
  const idats = imageData(p);
  const end = chunk("IEND");

  /** Changes byte `at` of the first IDAT's data and fixes up its CRC when `fixCrc`. */
  function flipIdatByte(at: number, fixCrc: boolean): Uint8Array {
    const data = idats.slice();
    data[at] ^= 0xff;
    const bad = chunk("IDAT", data);
    if (!fixCrc) bad[bad.length - 1] ^= 0xff;
    return concat(SIGNATURE, ihdr(300, 200, 2), bad, end);
  }

  it.each([
    ["truncated in the image data", good.subarray(0, Math.floor(good.length * 0.6))],
    ["missing IEND", good.subarray(0, good.length - 12)],
    ["an IDAT with a wrong CRC", flipIdatByte(100, false)],
    ["corrupt compressed data", flipIdatByte(2, true)],
    ["fewer rows than the header says", concat(SIGNATURE, ihdr(300, 201, 2), chunk("IDAT", idats), end)],
    ["no image data", concat(SIGNATURE, ihdr(300, 200, 2), end)],
    ["a palette image without PLTE", encodePng({ ...raw(30, 20, 3) })],
    ["a wrong signature", concat(Uint8Array.of(0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0), good.subarray(8))],
  ])("%s", async (_name, png) => {
    await expect(streamPng(png)).rejects.toThrow();
  });

  it("an unknown filter type", async () => {
    const bad = imageData({ ...p, pixels: p.pixels });
    // Re-encode with filter byte 9 on row 5.
    const { inflateSync, deflateSync } = await import("node:zlib");
    const rows = inflateSync(bad);
    rows[5 * (300 * 3 + 1)] = 9;
    await expect(streamPng(concat(SIGNATURE, ihdr(300, 200, 2), chunk("IDAT", deflateSync(rows)), end))).rejects.toThrow();
  });

  it("a bit depth it does not stream", async () => {
    await expect(streamPng(concat(SIGNATURE, ihdr(10, 10, 2, 16), chunk("IDAT", new Uint8Array(4)), end))).rejects.toThrow();
  });

  it("tolerates a bad CRC on an ancillary chunk, as the WASM decoder does", async () => {
    const text = chunk("tEXt", new TextEncoder().encode("Comment\0hello"));
    text[text.length - 1] ^= 0xff;
    const png = concat(good.subarray(0, 33), text, good.subarray(33));
    expect(await streamPng(png)).toEqual(await streamPng(good));
  });
});
