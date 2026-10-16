// Decodes a PNG a row at a time: inflate.ts hands the image data over 16 KiB
// at a time from a fixed window, each row is unfiltered against the one before
// and goes into a BoxScaler. Memory is the PNG bytes, the 64 KiB window, two
// rows and the small output, whatever the image's pixel count or how far its
// data expands, and nothing is left for the garbage collector (spec 5.8).
// Every PNG format: colour types 0, 2, 3, 4 and 6 at each bit depth PNG allows
// them, with tRNS, interlaced (Adam7) or not.

import { BoxScaler, type Rgba } from "./boxscale";
import { MAX_SIDE, fitWithin } from "./img";
import { inflate } from "./inflate";

const SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
/**
 * The most pixels a PNG may have each way. Buffers grow with the width (about
 * 20 bytes a pixel of one row: under 2 MB) and the work with the number of
 * rows, which, at about 90 ns a row on top of the pixels, this keeps to
 * milliseconds.
 */
export const PNG_MAX_SIDE = 100_000;

/** Samples a pixel, and the bit depths PNG allows, for each colour type. */
const FORMATS: Partial<Record<number, { channels: number; depths: number[] }>> = {
  0: { channels: 1, depths: [1, 2, 4, 8, 16] },
  2: { channels: 3, depths: [8, 16] },
  3: { channels: 1, depths: [1, 2, 4, 8] },
  4: { channels: 2, depths: [8, 16] },
  6: { channels: 4, depths: [8, 16] },
};

/** Each Adam7 pass: first column, first row, column step, row step. */
const ADAM7 = [
  [0, 0, 8, 8],
  [4, 0, 8, 8],
  [0, 4, 4, 8],
  [2, 0, 4, 4],
  [0, 2, 2, 4],
  [1, 0, 2, 2],
  [0, 1, 1, 2],
] as const;

const u16 = (b: Uint8Array, i: number) => (b[i] << 8) | b[i + 1];
const u32 = (b: Uint8Array, i: number) => ((b[i] << 24) >>> 0) + (b[i + 1] << 16) + (b[i + 2] << 8) + b[i + 3];
const name = (b: Uint8Array, i: number) => String.fromCharCode(b[i], b[i + 1], b[i + 2], b[i + 3]);

interface Header {
  width: number;
  height: number;
  bitDepth: number;
  colorType: number;
  compression: number;
  filter: number;
  interlace: number;
}

interface Png extends Header {
  palette: Uint8Array | null;
  trns: Uint8Array | null;
  /** Where the first IDAT chunk starts. */
  idatAt: number;
}

const IDAT = 0x49444154;
const IEND = 0x49454e44;

function readHeader(b: Uint8Array): Header | null {
  if (b.length < 33 || SIGNATURE.some((v, i) => b[i] !== v)) return null;
  if (u32(b, 8) !== 13 || name(b, 12) !== "IHDR") return null;
  return { width: u32(b, 16), height: u32(b, 20), bitDepth: b[24], colorType: b[25], compression: b[26], filter: b[27], interlace: b[28] };
}

/**
 * Whether `streamPng` takes this PNG: a colour type and bit depth PNG allows,
 * Adam7 or no interlacing, at most PNG_MAX_SIDE each way. Reads only the header.
 */
export function canStreamPng(b: Uint8Array): boolean {
  const h = readHeader(b);
  return h !== null && supported(h);
}

function supported(h: Header): boolean {
  return (
    (FORMATS[h.colorType]?.depths.includes(h.bitDepth) ?? false) &&
    h.compression === 0 &&
    h.filter === 0 &&
    (h.interlace === 0 || h.interlace === 1) &&
    h.width <= PNG_MAX_SIDE &&
    h.height <= PNG_MAX_SIDE
  );
}

/**
 * Decodes a PNG that `canStreamPng` takes and scales it to fit `max` x `max`
 * (composited over white, as BoxScaler does). Throws on anything malformed:
 * truncation, a bad CRC on a critical chunk, corrupt image data, too few rows.
 */
export async function streamPng(bytes: Uint8Array, max = MAX_SIDE): Promise<Rgba> {
  const png = parse(bytes);
  const scaler = new BoxScaler(png.width, png.height, fitWithin(png.width, png.height, max));
  const rows = new Rows(png, scaler);
  // Stops at the last row, or at the end of the zlib stream: like libpng, a
  // bad Adler-32 or anything after the stream is ignored.
  inflate(idatData(bytes, png.idatAt), (window, from, to) => rows.push(window, from, to));
  if (!rows.done) throw new Error("PNG image data ends early");
  return scaler.finish();
}

function parse(b: Uint8Array): Png {
  const h = readHeader(b);
  if (!h) throw new Error("Not a PNG");
  if (!supported(h)) throw new Error("PNG format is not supported, or the image is too large");
  if (h.width === 0 || h.height === 0) throw new Error("PNG has a zero dimension");
  const png: Png = { ...h, palette: null, trns: null, idatAt: -1 };
  let ended = false;
  for (let p = 8; !ended; ) {
    if (p + 12 > b.length) throw new Error("PNG is truncated");
    const length = u32(b, p);
    const end = p + 12 + length;
    if (end > b.length) throw new Error("PNG is truncated");
    const type = name(b, p + 4);
    // Like libpng: a bad CRC on a critical chunk (upper-case first letter) is fatal; on others it is ignored.
    if ((b[p + 4] & 0x20) === 0 && crc32(b.subarray(p + 4, end - 4)) !== u32(b, end - 4)) throw new Error(`PNG ${type} chunk is corrupt`);
    if (type === "PLTE") {
      if (length === 0 || length % 3 !== 0 || length > 768) throw new Error("PNG palette is malformed");
      png.palette = b.subarray(p + 8, end - 4);
    } else if (type === "tRNS") {
      png.trns = b.subarray(p + 8, end - 4);
    } else if (type === "IDAT") {
      if (png.idatAt < 0) png.idatAt = p;
    } else if (type === "IEND") {
      ended = true;
    }
    p = end;
  }
  if (png.idatAt < 0) throw new Error("PNG has no image data");
  if (h.colorType === 3 && !png.palette) throw new Error("PNG has no palette");
  return png;
}

/** Returns the data of each IDAT chunk from `at` to IEND in turn, then null; parse() has checked the chunks. */
function idatData(b: Uint8Array, at: number): () => Uint8Array | null {
  let p = at;
  return () => {
    for (;;) {
      const length = u32(b, p);
      const type = u32(b, p + 4);
      if (type === IEND) return null;
      const start = p + 8;
      p += 12 + length;
      if (type === IDAT) return b.subarray(start, start + length);
    }
  };
}

/** One Adam7 pass (or the whole image): where its pixels sit, and its size in pixels and in bytes a row. */
interface Pass {
  x0: number;
  y0: number;
  dx: number;
  dy: number;
  width: number;
  rows: number;
  stride: number;
}

/**
 * Collects the inflated stream into rows, pass by pass when interlaced,
 * unfilters each against the one before and hands it to the scaler as RGBA.
 */
class Rows {
  private readonly depth: number;
  /** Bytes a pixel, for the filters: at least 1. */
  private readonly bpp: number;
  private readonly passes: Pass[] = [];
  private pass = 0;
  private row = 0;
  private prev: Uint8Array;
  private cur: Uint8Array;
  private readonly rgba: Uint8Array;
  private readonly rgba32: Uint32Array;
  /** RGBA for each grey level or palette index (colour type 3, and 0 at up to 8 bits). */
  private readonly lut: Uint32Array | null = null;
  /** The transparent grey (colour type 0 at 16 bits) or RGB (colour type 2) of tRNS, in sample units. */
  private readonly key: number[] | null = null;
  private filter = -1;
  private pos = 0;

  constructor(
    private readonly png: Png,
    private readonly scaler: BoxScaler,
  ) {
    this.depth = png.bitDepth;
    const bits = this.depth * (FORMATS[png.colorType]?.channels ?? 0);
    this.bpp = Math.max(1, bits >> 3);
    for (const [x0, y0, dx, dy] of png.interlace ? ADAM7 : ([[0, 0, 1, 1]] as const)) {
      const width = Math.ceil((png.width - x0) / dx);
      const rows = Math.ceil((png.height - y0) / dy);
      if (width > 0 && rows > 0) this.passes.push({ x0, y0, dx, dy, width, rows, stride: Math.ceil((width * bits) / 8) });
    }
    const stride = Math.ceil((png.width * bits) / 8);
    this.prev = new Uint8Array(stride);
    this.cur = new Uint8Array(stride);
    this.rgba = new Uint8Array(png.width * 4);
    this.rgba32 = new Uint32Array(this.rgba.buffer);
    const trns = png.trns;
    if (png.colorType === 3 || (png.colorType === 0 && this.depth <= 8)) {
      const levels = 1 << this.depth;
      const lut = new Uint8Array(256 * 4);
      for (let v = 0; v < levels; v++) {
        if (png.colorType === 0) {
          const g = (v * 255) / (levels - 1);
          lut.set([g, g, g, trns && trns.length >= 2 && u16(trns, 0) === v ? 0 : 255], v * 4);
        } else {
          // An index past the palette's end is black, as in libpng.
          const pal = png.palette as Uint8Array;
          const rgb = v * 3 < pal.length ? pal.subarray(v * 3, v * 3 + 3) : [0, 0, 0];
          lut.set([rgb[0], rgb[1], rgb[2], trns && v < trns.length ? trns[v] : 255], v * 4);
        }
      }
      this.lut = new Uint32Array(lut.buffer);
    } else if (png.colorType === 0 && trns && trns.length >= 2) {
      this.key = [u16(trns, 0)];
    } else if (png.colorType === 2 && trns && trns.length >= 6) {
      this.key = [u16(trns, 0), u16(trns, 2), u16(trns, 4)];
    }
  }

  get done(): boolean {
    return this.pass === this.passes.length;
  }

  /** Takes inflated bytes `src[from..to)`; anything past the last row is ignored. Returns whether the image is complete. */
  push(src: Uint8Array, from: number, to: number): boolean {
    let i = from;
    while (i < to && this.pass < this.passes.length) {
      if (this.filter < 0) {
        this.filter = src[i++];
        if (this.filter > 4) throw new Error(`Unknown PNG filter type ${this.filter}`);
        continue;
      }
      const stride = this.passes[this.pass].stride;
      const n = Math.min(stride - this.pos, to - i);
      this.cur.set(src.subarray(i, i + n), this.pos);
      this.pos += n;
      i += n;
      if (this.pos === stride) this.endRow();
    }
    return this.done;
  }

  private endRow(): void {
    const p = this.passes[this.pass];
    unfilter(this.filter, this.cur, this.prev, this.bpp, p.stride);
    this.scaler.addPixels(p.y0 + this.row * p.dy, this.toRgba(this.cur, p.width), p.x0, p.dx, p.width);
    [this.prev, this.cur] = [this.cur, this.prev];
    this.filter = -1;
    this.pos = 0;
    if (++this.row === p.rows) {
      // The next pass starts against a row of zeros.
      this.pass++;
      this.row = 0;
      this.prev.fill(0);
    }
  }

  /** The first `n` pixels of an unfiltered row as RGBA. 16-bit samples keep their high byte, as libpng's strip_16 does. */
  private toRgba(row: Uint8Array, n: number): Uint8Array {
    const { rgba, depth, key } = this;
    if (this.lut) {
      const lut = this.lut;
      const out = this.rgba32;
      if (depth === 8) for (let x = 0; x < n; x++) out[x] = lut[row[x]];
      else {
        const mask = (1 << depth) - 1;
        for (let x = 0, bit = 0; x < n; x++, bit += depth) out[x] = lut[(row[bit >> 3] >> (8 - depth - (bit & 7))) & mask];
      }
      return rgba;
    }
    const w = depth >> 3; // bytes a sample: 1 or 2
    switch (this.png.colorType) {
      case 0: // 16-bit grey
        for (let x = 0, i = 0, o = 0; x < n; x++, i += 2, o += 4) {
          rgba[o] = rgba[o + 1] = rgba[o + 2] = row[i];
          rgba[o + 3] = key && u16(row, i) === key[0] ? 0 : 255;
        }
        return rgba;
      case 2:
        for (let x = 0, i = 0, o = 0; x < n; x++, i += 3 * w, o += 4) {
          rgba[o] = row[i];
          rgba[o + 1] = row[i + w];
          rgba[o + 2] = row[i + 2 * w];
          let opaque = true;
          if (key) {
            opaque =
              w === 1
                ? row[i] !== key[0] || row[i + 1] !== key[1] || row[i + 2] !== key[2]
                : u16(row, i) !== key[0] || u16(row, i + 2) !== key[1] || u16(row, i + 4) !== key[2];
          }
          rgba[o + 3] = opaque ? 255 : 0;
        }
        return rgba;
      case 4:
        for (let x = 0, i = 0, o = 0; x < n; x++, i += 2 * w, o += 4) {
          rgba[o] = rgba[o + 1] = rgba[o + 2] = row[i];
          rgba[o + 3] = row[i + w];
        }
        return rgba;
      default: // 6
        if (w === 1) return row;
        for (let x = 0, i = 0, o = 0; x < n; x++, i += 8, o += 4) {
          rgba[o] = row[i];
          rgba[o + 1] = row[i + 2];
          rgba[o + 2] = row[i + 4];
          rgba[o + 3] = row[i + 6];
        }
        return rgba;
    }
  }
}

/** Reverses a PNG filter on the first `n` bytes of `cur` in place; `prev` holds the previous row (zeros for a pass's first). */
function unfilter(filter: number, cur: Uint8Array, prev: Uint8Array, bpp: number, n: number): void {
  switch (filter) {
    case 1: // Sub
      for (let x = bpp; x < n; x++) cur[x] += cur[x - bpp];
      break;
    case 2: // Up
      for (let x = 0; x < n; x++) cur[x] += prev[x];
      break;
    case 3: // Average
      for (let x = 0; x < bpp; x++) cur[x] += prev[x] >> 1;
      for (let x = bpp; x < n; x++) cur[x] += (cur[x - bpp] + prev[x]) >> 1;
      break;
    case 4: // Paeth
      for (let x = 0; x < bpp; x++) cur[x] += prev[x];
      for (let x = bpp; x < n; x++) {
        const a = cur[x - bpp];
        const b = prev[x];
        const c = prev[x - bpp];
        const pa = Math.abs(b - c);
        const pb = Math.abs(a - c);
        const pc = Math.abs(a + b - 2 * c);
        cur[x] += pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
      }
      break;
  }
}

const CRC_TABLE = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();

function crc32(d: Uint8Array): number {
  let c = -1;
  for (let i = 0; i < d.length; i++) c = CRC_TABLE[(c ^ d[i]) & 0xff] ^ (c >>> 8);
  return (c ^ -1) >>> 0;
}
