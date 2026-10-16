// Streams an 8-bit, non-interlaced PNG through the platform's
// DecompressionStream and unfilters it one row at a time into a BoxScaler, so
// memory is the PNG bytes, two rows and the small output whatever the image's
// pixel count (spec 5.8). Other PNGs (16-bit, under 8 bits, interlaced) go to
// the WASM decoder (img-wasm.ts).

import { BoxScaler, type Rgba } from "./boxscale";
import { MAX_SIDE, fitWithin } from "./img";

const SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
/**
 * The widest PNG this decoder takes. Its buffers grow with the width (about
 * 16 bytes a pixel of one row), so this keeps them under 2 MB; wider ones go
 * to the WASM decoder and its pixel cap.
 */
export const PNG_STREAM_MAX_WIDTH = 100_000;

/** Bytes per pixel of each colour type this decoder takes, at 8 bits a sample. */
const CHANNELS: Partial<Record<number, number>> = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 };

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
  idat: Uint8Array[];
}

function readHeader(b: Uint8Array): Header | null {
  if (b.length < 33 || SIGNATURE.some((v, i) => b[i] !== v)) return null;
  if (u32(b, 8) !== 13 || name(b, 12) !== "IHDR") return null;
  return { width: u32(b, 16), height: u32(b, 20), bitDepth: b[24], colorType: b[25], compression: b[26], filter: b[27], interlace: b[28] };
}

/**
 * Whether `streamPng` takes this PNG: 8 bits a sample, not interlaced, colour
 * type 0, 2, 3, 4 or 6, at most PNG_STREAM_MAX_WIDTH wide. Reads only the header.
 */
export function canStreamPng(b: Uint8Array): boolean {
  const h = readHeader(b);
  return h !== null && streamable(h);
}

function streamable(h: Header): boolean {
  return (
    h.bitDepth === 8 &&
    h.interlace === 0 &&
    CHANNELS[h.colorType] !== undefined &&
    h.compression === 0 &&
    h.filter === 0 &&
    h.width <= PNG_STREAM_MAX_WIDTH
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
  await inflate(png.idat, (chunk) => {
    rows.push(chunk);
    return rows.done;
  });
  if (!rows.done) throw new Error("PNG image data ends early");
  return scaler.finish();
}

function parse(b: Uint8Array): Png {
  const h = readHeader(b);
  if (!h) throw new Error("Not a PNG");
  if (!streamable(h)) throw new Error("PNG format is not streamable");
  if (h.width === 0 || h.height === 0) throw new Error("PNG has a zero dimension");
  const png: Png = { ...h, palette: null, trns: null, idat: [] };
  let ended = false;
  for (let p = 8; !ended; ) {
    if (p + 12 > b.length) throw new Error("PNG is truncated");
    const length = u32(b, p);
    const end = p + 12 + length;
    if (end > b.length) throw new Error("PNG is truncated");
    const type = name(b, p + 4);
    // Like libpng: a bad CRC on a critical chunk (upper-case first letter) is fatal; on others it is ignored.
    if ((b[p + 4] & 0x20) === 0 && crc32(b.subarray(p + 4, end - 4)) !== u32(b, end - 4)) throw new Error(`PNG ${type} chunk is corrupt`);
    const data = b.subarray(p + 8, end - 4);
    if (type === "PLTE") {
      if (length === 0 || length % 3 !== 0 || length > 768) throw new Error("PNG palette is malformed");
      png.palette = data;
    } else if (type === "tRNS") {
      png.trns = data;
    } else if (type === "IDAT") {
      png.idat.push(data);
    } else if (type === "IEND") {
      ended = true;
    }
    p = end;
  }
  if (png.idat.length === 0) throw new Error("PNG has no image data");
  if (h.colorType === 3 && !png.palette) throw new Error("PNG has no palette");
  return png;
}

/** Feeds the inflated IDAT stream to `onData` until it returns true or the stream ends. */
async function inflate(parts: Uint8Array[], onData: (chunk: Uint8Array) => boolean): Promise<void> {
  const stream = new DecompressionStream("deflate");
  const writer = stream.writable.getWriter();
  const writing = (async () => {
    // The parts are views of the fetched body, never of a SharedArrayBuffer.
    for (const part of parts) await writer.write(part as Uint8Array<ArrayBuffer>);
    await writer.close();
  })();
  // A write fails only when the stream has failed or been cancelled; the reader reports that.
  writing.catch(() => {});
  const reader = stream.readable.getReader();
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done || onData(value)) return;
    }
  } finally {
    // Stops inflating whatever follows the last row, and frees the stream after an error.
    reader.cancel().catch(() => {});
  }
}

/** Collects the inflated stream into rows, unfilters each against the one before and hands it to the scaler as RGBA. */
class Rows {
  private readonly width: number;
  private readonly height: number;
  private readonly bpp: number;
  private readonly stride: number;
  private prev: Uint8Array;
  private cur: Uint8Array;
  /** The row as RGBA; colour type 6 rows already are. */
  private readonly rgba: Uint8Array;
  private readonly rgba32: Uint32Array;
  /** RGBA for each grey level or palette index (colour types 0 and 3). */
  private readonly lut: Uint32Array | null = null;
  /** The transparent colour of an RGB image (tRNS), if it has one. */
  private readonly key: [number, number, number] | null = null;
  private filter = -1;
  private pos = 0;
  private y = 0;

  constructor(
    private readonly png: Png,
    private readonly scaler: BoxScaler,
  ) {
    this.width = png.width;
    this.height = png.height;
    this.bpp = CHANNELS[png.colorType] ?? 0;
    this.stride = this.width * this.bpp;
    this.prev = new Uint8Array(this.stride);
    this.cur = new Uint8Array(this.stride);
    this.rgba = png.colorType === 6 ? new Uint8Array(0) : new Uint8Array(this.width * 4);
    this.rgba32 = new Uint32Array(this.rgba.buffer);
    const trns = png.trns;
    if (png.colorType === 0 || png.colorType === 3) {
      const lut = new Uint8Array(256 * 4);
      for (let i = 0; i < 256; i++) {
        if (png.colorType === 0) {
          lut.set([i, i, i, trns && trns.length >= 2 && u16(trns, 0) === i ? 0 : 255], i * 4);
        } else {
          // An index past the palette's end is black, as in libpng.
          const pal = png.palette as Uint8Array;
          const rgb = i * 3 < pal.length ? pal.subarray(i * 3, i * 3 + 3) : [0, 0, 0];
          lut.set([rgb[0], rgb[1], rgb[2], trns && i < trns.length ? trns[i] : 255], i * 4);
        }
      }
      this.lut = new Uint32Array(lut.buffer);
    } else if (png.colorType === 2 && trns && trns.length >= 6) {
      this.key = [u16(trns, 0), u16(trns, 2), u16(trns, 4)];
    }
  }

  get done(): boolean {
    return this.y === this.height;
  }

  push(chunk: Uint8Array): void {
    let i = 0;
    while (i < chunk.length && this.y < this.height) {
      if (this.filter < 0) {
        this.filter = chunk[i++];
        if (this.filter > 4) throw new Error(`Unknown PNG filter type ${this.filter}`);
        continue;
      }
      const n = Math.min(this.stride - this.pos, chunk.length - i);
      this.cur.set(chunk.subarray(i, i + n), this.pos);
      this.pos += n;
      i += n;
      if (this.pos === this.stride) this.endRow();
    }
  }

  private endRow(): void {
    unfilter(this.filter, this.cur, this.prev, this.bpp);
    this.scaler.addRow(this.toRgba(this.cur));
    [this.prev, this.cur] = [this.cur, this.prev];
    this.filter = -1;
    this.pos = 0;
    this.y++;
  }

  private toRgba(row: Uint8Array): Uint8Array {
    const { rgba, width } = this;
    switch (this.png.colorType) {
      case 6:
        return row;
      case 0:
      case 3: {
        const lut = this.lut as Uint32Array;
        for (let x = 0; x < width; x++) this.rgba32[x] = lut[row[x]];
        return rgba;
      }
      case 4:
        for (let x = 0, i = 0, o = 0; x < width; x++, i += 2, o += 4) {
          rgba[o] = rgba[o + 1] = rgba[o + 2] = row[i];
          rgba[o + 3] = row[i + 1];
        }
        return rgba;
      default: {
        const key = this.key;
        for (let x = 0, i = 0, o = 0; x < width; x++, i += 3, o += 4) {
          const r = row[i];
          const g = row[i + 1];
          const b = row[i + 2];
          rgba[o] = r;
          rgba[o + 1] = g;
          rgba[o + 2] = b;
          rgba[o + 3] = key && r === key[0] && g === key[1] && b === key[2] ? 0 : 255;
        }
        return rgba;
      }
    }
  }
}

/** Reverses a PNG filter in place; `cur` holds the filtered bytes, `prev` the previous row (zeros for the first). */
function unfilter(filter: number, cur: Uint8Array, prev: Uint8Array, bpp: number): void {
  const n = cur.length;
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
