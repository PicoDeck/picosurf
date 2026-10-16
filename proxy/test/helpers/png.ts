import { crc32, deflateSync } from "node:zlib";

export type ColorType = 0 | 2 | 3 | 4 | 6;
export const CHANNELS: Record<ColorType, number> = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 };

export interface RawPng {
  width: number;
  height: number;
  colorType: ColorType;
  /** Bits a sample: 1, 2, 4, 8 (the default) or 16. */
  bitDepth?: number;
  /** Adam7 interlacing. */
  interlaced?: boolean;
  /** Unfiltered samples at bitDepth bits, row after row (16-bit ones in a Uint16Array). */
  pixels: Uint8Array | Uint16Array;
  /** RGB triples, for colour type 3. */
  palette?: Uint8Array;
  trns?: Uint8Array;
}

/** Each Adam7 pass: first column, first row, column step, row step. */
export const ADAM7 = [
  [0, 0, 8, 8],
  [4, 0, 8, 8],
  [0, 4, 4, 8],
  [2, 0, 4, 4],
  [0, 2, 2, 4],
  [1, 0, 2, 2],
  [0, 1, 1, 2],
] as const;

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
  return concatAll(parts);
}

function concatAll(parts: Uint8Array[]): Uint8Array {
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

/**
 * The filtered scanlines of `p`, each Adam7 pass in turn when interlaced; the
 * r-th scanline is filtered with filter type r % 5, so every type is used.
 */
export function scanlines(p: RawPng): Uint8Array {
  const depth = p.bitDepth ?? 8;
  const channels = CHANNELS[p.colorType];
  const bits = depth * channels;
  const bpp = Math.max(1, bits >> 3);
  const out: Uint8Array[] = [];
  let r = 0;
  for (const [x0, y0, dx, dy] of p.interlaced ? ADAM7 : ([[0, 0, 1, 1]] as const)) {
    const pw = Math.ceil((p.width - x0) / dx);
    const ph = Math.ceil((p.height - y0) / dy);
    if (pw <= 0 || ph <= 0) continue;
    const stride = Math.ceil((pw * bits) / 8);
    let prior = new Uint8Array(stride);
    for (let j = 0; j < ph; j++, r++) {
      const row = new Uint8Array(stride);
      for (let i = 0; i < pw; i++) {
        for (let c = 0; c < channels; c++) {
          const v = p.pixels[((y0 + j * dy) * p.width + x0 + i * dx) * channels + c];
          const k = i * channels + c;
          if (depth === 16) {
            row[k * 2] = v >> 8;
            row[k * 2 + 1] = v & 0xff;
          } else if (depth === 8) row[k] = v;
          else row[(k * depth) >> 3] |= v << (8 - depth - ((k * depth) & 7));
        }
      }
      const filter = r % 5;
      const line = new Uint8Array(stride + 1);
      line[0] = filter;
      for (let x = 0; x < stride; x++) {
        const a = x >= bpp ? row[x - bpp] : 0;
        const b = prior[x];
        const c = x >= bpp ? prior[x - bpp] : 0;
        const predictor = [0, a, b, (a + b) >> 1, paeth(a, b, c)][filter];
        line[1 + x] = (row[x] - predictor) & 0xff;
      }
      out.push(line);
      prior = row;
    }
  }
  return concatAll(out);
}

/** The zlib stream of `p`'s scanlines. */
export function imageData(p: RawPng): Uint8Array {
  return new Uint8Array(deflateSync(scanlines(p)));
}

/** A PNG of `p`, with the image data split over IDAT chunks of `idatSize` bytes. */
export function encodePng(p: RawPng, idatSize = 8192): Uint8Array {
  const z = imageData(p);
  const idats: Uint8Array[] = [];
  for (let i = 0; i < z.length; i += idatSize) idats.push(chunk("IDAT", z.subarray(i, i + idatSize)));
  return concatAll([
    SIGNATURE,
    ihdr(p.width, p.height, p.colorType, p.bitDepth ?? 8, p.interlaced ? 1 : 0),
    ...(p.palette ? [chunk("PLTE", p.palette)] : []),
    ...(p.trns ? [chunk("tRNS", p.trns)] : []),
  ].concat(idats, [chunk("IEND")]));
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

/**
 * Photo-like samples for any colour type and bit depth: photo()'s 8-bit ones,
 * quantised for depths under 8 (palette indexes for colour type 3), or with a
 * varying low byte for 16 (the high byte stays photo()'s).
 */
export function samples(width: number, height: number, colorType: ColorType, depth: number, seed = 1): Uint8Array | Uint16Array {
  const eight = photo(width, height, CHANNELS[colorType], seed);
  if (depth === 8) return eight;
  if (depth === 16) return Uint16Array.from(eight, (v, i) => v * 256 + ((i * 37) & 0xff));
  return Uint8Array.from(eight, (v) => v >> (8 - depth));
}
