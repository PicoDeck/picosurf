import { crc32, deflateSync } from "node:zlib";

export type ColorType = 0 | 2 | 3 | 4 | 6;
export const CHANNELS: Record<ColorType, number> = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 };

export interface RawPng {
  width: number;
  height: number;
  colorType: ColorType;
  /** Unfiltered 8-bit samples, row after row. */
  pixels: Uint8Array;
  /** RGB triples, for colour type 3. */
  palette?: Uint8Array;
  trns?: Uint8Array;
}

/** One PNG chunk with its length and CRC. */
export function chunk(type: string, data: Uint8Array = new Uint8Array(0)): Uint8Array {
  const out = new Uint8Array(12 + data.length);
  const dv = new DataView(out.buffer);
  dv.setUint32(0, data.length);
  out.set(Array.from(type, (c) => c.charCodeAt(0)), 4);
  out.set(data, 8);
  dv.setUint32(8 + data.length, crc32(out.subarray(4, 8 + data.length)));
  return out;
}

export const SIGNATURE = Uint8Array.of(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a);

export function ihdr(width: number, height: number, colorType: number, bitDepth = 8, interlace = 0): Uint8Array {
  const d = new Uint8Array(13);
  const dv = new DataView(d.buffer);
  dv.setUint32(0, width);
  dv.setUint32(4, height);
  d.set([bitDepth, colorType, 0, 0, interlace], 8);
  return chunk("IHDR", d);
}

export function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

const paeth = (a: number, b: number, c: number) => {
  const p = a + b - c;
  const pa = Math.abs(p - a);
  const pb = Math.abs(p - b);
  const pc = Math.abs(p - c);
  return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
};

/** The zlib stream of `p`'s rows, row y filtered with filter type y % 5 so every filter type is used. */
export function imageData(p: RawPng): Uint8Array {
  const bpp = CHANNELS[p.colorType];
  const stride = p.width * bpp;
  const out = new Uint8Array((stride + 1) * p.height);
  for (let y = 0; y < p.height; y++) {
    const filter = y % 5;
    const row = p.pixels.subarray(y * stride, (y + 1) * stride);
    const prior = y > 0 ? p.pixels.subarray((y - 1) * stride, y * stride) : new Uint8Array(stride);
    const o = y * (stride + 1);
    out[o] = filter;
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? row[x - bpp] : 0;
      const b = prior[x];
      const c = x >= bpp ? prior[x - bpp] : 0;
      const predictor = [0, a, b, (a + b) >> 1, paeth(a, b, c)][filter];
      out[o + 1 + x] = (row[x] - predictor) & 0xff;
    }
  }
  return new Uint8Array(deflateSync(out));
}

/** An 8-bit, non-interlaced PNG, with the image data split over IDAT chunks of `idatSize` bytes. */
export function encodePng(p: RawPng, idatSize = 8192): Uint8Array {
  const z = imageData(p);
  const idats: Uint8Array[] = [];
  for (let i = 0; i < z.length; i += idatSize) idats.push(chunk("IDAT", z.subarray(i, i + idatSize)));
  return concat(
    SIGNATURE,
    ihdr(p.width, p.height, p.colorType),
    ...(p.palette ? [chunk("PLTE", p.palette)] : []),
    ...(p.trns ? [chunk("tRNS", p.trns)] : []),
    ...idats,
    chunk("IEND"),
  );
}

/** Deterministic noise in [0, 1). */
function noise(seed: number): () => number {
  let s = seed >>> 0;
  return () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s / 2 ** 32;
  };
}

/**
 * Photo-like samples: smooth gradients, a few hard-edged boxes and mild noise.
 * With an alpha channel (2 or 4 channels), alpha runs from clear at the left
 * to opaque at the right, with a fully clear hole.
 */
export function photo(width: number, height: number, channels: number, seed = 1): Uint8Array {
  const rand = noise(seed);
  const out = new Uint8Array(width * height * channels);
  const hasAlpha = channels === 2 || channels === 4;
  const colours = hasAlpha ? channels - 1 : channels;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const u = x / width;
      const v = y / height;
      const inBox = (u > 0.2 && u < 0.45 && v > 0.3 && v < 0.6) || (u > 0.6 && u < 0.9 && v > 0.1 && v < 0.25);
      const base = [255 * u, 255 * v, 255 * (1 - u * v)];
      const o = (y * width + x) * channels;
      for (let c = 0; c < colours; c++) {
        const value = inBox ? 255 - base[c] : base[c];
        out[o + c] = Math.max(0, Math.min(255, Math.round(value + (rand() - 0.5) * 12)));
      }
      if (hasAlpha) {
        const hole = Math.hypot(u - 0.75, v - 0.7) < 0.1;
        out[o + channels - 1] = hole ? 0 : Math.round(255 * u);
      }
    }
  }
  return out;
}
