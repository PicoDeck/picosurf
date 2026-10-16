import { describe, expect, it, vi } from "vitest";
import sharp, { type Sharp } from "sharp";
import { fitWithin } from "../src/img";
import { deflateSync, inflateSync } from "node:zlib";
import { INFLATE_FLUSH } from "../src/inflate";
import { PNG_MAX_SIDE, canStreamPng, streamPng } from "../src/png-stream";
import { meanAbsError, sharpReference } from "./helpers/pixels";
import { CHANNELS, type ColorType, type RawPng, SIGNATURE, chunk, concat, encodePng, ihdr, imageData, photo, samples } from "./helpers/png";

/** A ramp palette: neighbouring indexes have neighbouring colours. */
const PALETTE = Uint8Array.from({ length: 256 * 3 }, (_, i) => [Math.floor(i / 3), 255 - Math.floor(i / 3), (Math.floor(i / 3) * 3) & 0xff][i % 3]);

function raw(width: number, height: number, colorType: ColorType, extra: Partial<RawPng> = {}): RawPng {
  const pixels = colorType === 3 ? photo(width, height, 1) : photo(width, height, CHANNELS[colorType]);
  return { width, height, colorType, pixels, ...extra };
}

/** What streamPng's inflater was given and gave back, through a pass-through mock. */
const inflated = vi.hoisted(() => ({ segments: [] as Uint8Array[], delivered: 0 }));
vi.mock("../src/inflate", async (importOriginal) => {
  const orig = await importOriginal<typeof import("../src/inflate")>();
  return {
    ...orig,
    inflate: (next: () => Uint8Array | null, sink: (w: Uint8Array, from: number, to: number) => boolean) =>
      orig.inflate(
        () => {
          const segment = next();
          if (segment) inflated.segments.push(segment);
          return segment;
        },
        (w, from, to) => {
          inflated.delivered += to - from;
          return sink(w, from, to);
        },
      ),
  };
});
const recordInflate = () => {
  inflated.segments = [];
  inflated.delivered = 0;
  return inflated;
};

/** The inflater stopped within one delivery of the end of the last row. */
function expectStoppedAtLastRow(delivered: number, needed: number) {
  expect(delivered).toBeGreaterThanOrEqual(needed);
  expect(delivered).toBeLessThan(needed + INFLATE_FLUSH + 258);
}

const flipLast = (z: Uint8Array) => {
  const out = z.slice();
  out[out.length - 1] ^= 0xff;
  return out;
};

/** 200 MiB of zeros, deflated (about 200 KB). */
let bomb: Uint8Array | undefined;
const BOMB = () => (bomb ??= new Uint8Array(deflateSync(new Uint8Array(200 * 1024 * 1024), { level: 9 })));

/** What `p` looks like over white, worked out from its samples directly. */
function expectedRgba(p: RawPng): number[] {
  const depth = p.bitDepth ?? 8;
  const to8 = (v: number) => (depth === 16 ? v >> 8 : depth === 8 ? v : (v * 255) / ((1 << depth) - 1));
  const key = (i: number) => (p.trns ? (p.trns[i] << 8) | p.trns[i + 1] : -1); // in sample units
  const px = p.pixels;
  const out: number[] = [];
  for (let i = 0; i < p.width * p.height; i++) {
    let rgba: number[];
    if (p.colorType === 0) {
      const g = px[i];
      rgba = [to8(g), to8(g), to8(g), g === key(0) ? 0 : 255];
    } else if (p.colorType === 2) {
      const [r, g, b] = [px[i * 3], px[i * 3 + 1], px[i * 3 + 2]];
      rgba = [to8(r), to8(g), to8(b), r === key(0) && g === key(2) && b === key(4) ? 0 : 255];
    } else if (p.colorType === 3) {
      const n = px[i];
      rgba = [...(p.palette as Uint8Array).subarray(n * 3, n * 3 + 3), p.trns && n < p.trns.length ? p.trns[n] : 255];
    } else if (p.colorType === 4) {
      rgba = [to8(px[i * 2]), to8(px[i * 2]), to8(px[i * 2]), to8(px[i * 2 + 1])];
    } else {
      rgba = [0, 1, 2, 3].map((c) => to8(px[i * 4 + c]));
    }
    const a = rgba[3];
    out.push(...rgba.slice(0, 3).map((c) => (c * a) / 255 + 255 - a), 255);
  }
  return out;
}

/** Every colour type and bit depth PNG allows, with a tRNS chunk where it can have one. */
function formats(width: number, height: number, interlaced: boolean): [string, RawPng][] {
  const out: [string, RawPng][] = [];
  const DEPTHS: [ColorType, number[]][] = [[0, [1, 2, 4, 8, 16]], [2, [8, 16]], [3, [1, 2, 4, 8]], [4, [8, 16]], [6, [8, 16]]];
  for (const [colorType, depths] of DEPTHS) {
    for (const bitDepth of depths) {
      const p: RawPng = { width, height, colorType, bitDepth, interlaced, pixels: samples(width, height, colorType, bitDepth) };
      if (colorType === 3) {
        p.palette = PALETTE.subarray(0, 3 << bitDepth);
        // Alpha ramps up over the first entries (and stays opaque past tRNS's end).
        const n = Math.min(100, 1 << bitDepth);
        p.trns = Uint8Array.from({ length: n }, (_, i) => Math.round((i * 255) / Math.max(1, n - 1)));
      }
      out.push([`colour type ${colorType}, ${bitDepth}-bit`, p]);
      // A transparent key: a sample value that occurs (pixel 0's).
      const k = (c: number) => [p.pixels[c] >> 8, p.pixels[c] & 0xff];
      if (colorType === 0) out.push([`colour type 0, ${bitDepth}-bit, tRNS key`, { ...p, trns: Uint8Array.from(k(0)) }]);
      if (colorType === 2) out.push([`colour type 2, ${bitDepth}-bit, tRNS key`, { ...p, trns: Uint8Array.from([...k(0), ...k(1), ...k(2)]) }]);
    }
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

  it("stops inflating as soon as the last row is complete", async () => {
    const p = raw(400, 300, 2);
    const expected = await streamPng(encodePng(p));
    // One zlib stream holding the rows and then 1 MB more than the image needs.
    const z = deflateSync(concat(inflateSync(imageData(p)), new Uint8Array(1_000_000)));
    const png = concat(SIGNATURE, ihdr(400, 300, 2), chunk("IDAT", z), chunk("IEND"));
    const record = recordInflate();
    expect(await streamPng(png)).toEqual(expected);
    expectStoppedAtLastRow(record.delivered, 300 * (400 * 3 + 1));
  });

  it("hands the inflater IDAT chunk data as views of the PNG, without copying", async () => {
    const png = encodePng(raw(400, 300, 2), 8192);
    const record = recordInflate();
    await streamPng(png);
    expect(record.segments.length).toBeGreaterThan(5);
    for (const segment of record.segments) expect(segment.buffer).toBe(png.buffer);
  });

  it("decodes image data split into about 250,000 one-byte IDAT chunks", async () => {
    const p = raw(400, 300, 2);
    const expected = await streamPng(encodePng(p));
    const record = recordInflate();
    expect(await streamPng(encodePng(p, 1))).toEqual(expected);
    // One segment per byte, up to the end of the deflate data: the Adler-32 is never read (a lookup may peek at its first byte).
    expect(record.segments.length).toBeLessThanOrEqual(imageData(p).length - 3);
  });

  it("decodes a decompression bomb without inflating past the last row: 1000x1000 declared, 200 MiB of zeros", async () => {
    const png = concat(SIGNATURE, ihdr(1000, 1000, 2), chunk("IDAT", BOMB()), chunk("IEND"));
    const record = recordInflate();
    const out = await streamPng(png);
    expect(out).toMatchObject({ width: 320, height: 320 });
    expect(out.data.every((v, i) => v === (i % 4 === 3 ? 255 : 0))).toBe(true);
    expectStoppedAtLastRow(record.delivered, 1000 * (1000 * 3 + 1));
  });

  it("stops at the end of a zlib stream that ends before the last row, and fails", async () => {
    // A complete zlib stream of 100 rows, a header claiming 200, then 1 MiB of junk IDATs.
    const p = raw(300, 100, 2);
    const junk = Array.from({ length: 128 }, () => chunk("IDAT", new Uint8Array(8192).fill(0xab)));
    const png = concat(SIGNATURE, ihdr(300, 200, 2), chunk("IDAT", imageData(p)), ...junk, chunk("IEND"));
    const record = recordInflate();
    await expect(streamPng(png)).rejects.toThrow("PNG image data ends early");
    expect(record.segments).toHaveLength(1);
  });

  it.each([
    ["a bad Adler-32", (z: Uint8Array) => [chunk("IDAT", flipLast(z))]],
    ["a bad Adler-32 in its own IDAT", (z: Uint8Array) => [chunk("IDAT", z.subarray(0, -4)), chunk("IDAT", flipLast(z).subarray(-4))]],
    ["no Adler-32 at all", (z: Uint8Array) => [chunk("IDAT", z.subarray(0, -4))]],
    ["bytes after the zlib stream", (z: Uint8Array) => [chunk("IDAT", concat(z, new Uint8Array(5000).fill(0xab)))]],
    ["bytes after the zlib stream in their own IDAT", (z: Uint8Array) => [chunk("IDAT", z), chunk("IDAT", new Uint8Array(100).fill(0xab))]],
  ])("accepts %s, as libpng and the WASM decoder do", async (_name, idats) => {
    const p = raw(300, 200, 2);
    const png = concat(SIGNATURE, ihdr(300, 200, 2), ...idats(imageData(p)), chunk("IEND"));
    expect(await streamPng(png)).toEqual(await streamPng(encodePng(p)));
  });

  it("ignores an IDAT after IEND", async () => {
    const p = raw(300, 200, 2);
    const good = encodePng(p);
    expect(await streamPng(concat(good, chunk("IDAT", new Uint8Array(1000).fill(7))))).toEqual(await streamPng(good));
  });

  it("draws a palette index past the end of PLTE as black", async () => {
    const palette = Uint8Array.of(255, 0, 0, 0, 255, 0);
    const pixels = Uint8Array.of(0, 1, 2, 200);
    const out = await streamPng(encodePng({ width: 4, height: 1, colorType: 3, pixels, palette }));
    expect(Array.from(out.data)).toEqual([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255]);
  });

  it.each([2, 6] as const)("decodes a real 100000x1 image of colour type %d like sharp", async (colorType) => {
    const p = raw(PNG_MAX_SIDE, 1, colorType);
    await expectLikeSharp(encodePng(p), PNG_MAX_SIDE, 1);
  });

  it("decodes a 1x1 image", async () => {
    const out = await streamPng(encodePng({ width: 1, height: 1, colorType: 2, pixels: Uint8Array.of(10, 20, 30) }));
    expect(out).toEqual({ width: 1, height: 1, data: Uint8ClampedArray.of(10, 20, 30, 255) });
  });
});

describe("every PNG format", () => {
  it.each(formats(700, 540, false))("decodes %s like sharp", async (_name, p) => {
    await expectLikeSharp(encodePng(p), p.width, p.height);
  });

  it.each(formats(700, 540, true))("decodes %s, interlaced, like sharp", async (_name, p) => {
    await expectLikeSharp(encodePng(p), p.width, p.height);
  });

  it.each([...formats(37, 23, false), ...formats(37, 23, true).map(([n, p]): [string, RawPng] => [`${n}, interlaced`, p])])(
    "reproduces every pixel of %s at full size",
    async (_name, p) => {
      const out = await streamPng(encodePng(p));
      const expected = expectedRgba(p);
      let worst = 0;
      for (let i = 0; i < expected.length; i++) worst = Math.max(worst, Math.abs(out.data[i] - expected[i]));
      expect(worst).toBeLessThanOrEqual(1);
    },
  );

  // Adam7 passes are empty for images this small, and the decoder must skip them.
  it.each([
    [1, 1], [2, 1], [1, 2], [3, 3], [5, 9], [9, 5], [8, 8],
  ])("decodes a %dx%d interlaced image exactly", async (width, height) => {
    for (const colorType of [0, 2, 3, 4, 6] as const) {
      const p: RawPng = { width, height, colorType, interlaced: true, pixels: samples(width, height, colorType, 8), ...(colorType === 3 ? { palette: PALETTE } : {}) };
      const out = await streamPng(encodePng(p));
      expect(Array.from(out.data).map((v, i) => Math.abs(v - expectedRgba(p)[i]) <= 1)).not.toContain(false);
    }
  });

  it.each([
    ["16-bit RGB", (img: Sharp) => img.toColourspace("rgb16").png()],
    ["16-bit grey", (img: Sharp) => img.toColourspace("grey16").png()],
    ["interlaced RGB", (img: Sharp) => img.png({ progressive: true })],
    ["4-bit palette", (img: Sharp) => img.png({ palette: true, colours: 16 })],
    ["1-bit palette", (img: Sharp) => img.png({ palette: true, colours: 2 })],
    ["interlaced 2-bit palette", (img: Sharp) => img.png({ palette: true, colours: 4, progressive: true })],
  ])("decodes sharp's %s PNG like sharp", async (_name, encode) => {
    const [width, height] = [700, 500];
    const png = new Uint8Array(await encode(sharp(photo(width, height, 3), { raw: { width, height, channels: 3 } })).toBuffer());
    await expectLikeSharp(png, width, height);
  });

  it.each([
    [2, 4], [2, 1], [3, 16], [4, 4], [6, 1], [0, 3], [0, 32],
  ])("refuses colour type %d at %d bits, which PNG does not allow", async (colorType, bitDepth) => {
    const png = concat(SIGNATURE, ihdr(10, 10, colorType, bitDepth), chunk("IDAT", deflateSync(new Uint8Array(200))), chunk("IEND"));
    expect(canStreamPng(png)).toBe(false);
    await expect(streamPng(png)).rejects.toThrow();
  });

  it("refuses an interlace method other than Adam7", async () => {
    expect(canStreamPng(concat(SIGNATURE, ihdr(10, 10, 2, 8, 2)))).toBe(false);
  });

  it("takes up to PNG_MAX_SIDE pixels each way, so rows and row counts stay bounded", () => {
    expect(canStreamPng(concat(SIGNATURE, ihdr(PNG_MAX_SIDE, 1, 6)))).toBe(true);
    expect(canStreamPng(concat(SIGNATURE, ihdr(1, PNG_MAX_SIDE, 6)))).toBe(true);
    expect(canStreamPng(concat(SIGNATURE, ihdr(PNG_MAX_SIDE + 1, 1, 6)))).toBe(false);
    expect(canStreamPng(concat(SIGNATURE, ihdr(1, PNG_MAX_SIDE + 1, 6)))).toBe(false);
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
    const rows = inflateSync(bad);
    rows[5 * (300 * 3 + 1)] = 9;
    await expect(streamPng(concat(SIGNATURE, ihdr(300, 200, 2), chunk("IDAT", deflateSync(rows)), end))).rejects.toThrow();
  });


  it("tolerates a bad CRC on an ancillary chunk, as the WASM decoder does", async () => {
    const text = chunk("tEXt", new TextEncoder().encode("Comment\0hello"));
    text[text.length - 1] ^= 0xff;
    const png = concat(good.subarray(0, 33), text, good.subarray(33));
    expect(await streamPng(png)).toEqual(await streamPng(good));
  });
});
