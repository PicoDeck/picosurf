// Area-average (box filter) downscaling in plain JS, fed one source row at a
// time, so a decoder can stream into it and nothing holds a second full-size
// copy of the image (spec 5.8).

import type { Size } from "./imgsize";

/**
 * Uint8ClampedArray as it was at load: img-wasm.ts briefly puts a stand-in in
 * its place on globalThis while a decoder calls back into this file.
 */
const Clamped = Uint8ClampedArray;

/** RGBA pixels, the shape the JPEG encoder takes. */
export interface Rgba {
  data: Uint8ClampedArray<ArrayBuffer>;
  width: number;
  height: number;
}

/**
 * Each output pixel is the exact area average of the source pixels under it;
 * a source pixel that straddles two output pixels is split between them by
 * area. Pixels are composited over white as they arrive, so the output is
 * opaque. Never enlarges: `out` must be no bigger than the source.
 */
export class BoxScaler {
  readonly width: number;
  readonly height: number;
  /** Output column of each source column, and the share of it that falls there (the rest goes to the next column). */
  private readonly col: Uint16Array;
  private readonly colShare: Float32Array;
  private readonly row = new Float64Array(0);
  private readonly sums: Float64Array;
  private y = 0;

  constructor(
    readonly srcWidth: number,
    readonly srcHeight: number,
    out: Size,
  ) {
    const { width, height } = out;
    if (width < 1 || height < 1 || width > srcWidth || height > srcHeight || width > 65535) {
      throw new RangeError(`Cannot box-scale ${srcWidth}x${srcHeight} to ${width}x${height}`);
    }
    this.width = width;
    this.height = height;
    this.col = new Uint16Array(srcWidth);
    this.colShare = new Float32Array(srcWidth);
    for (let x = 0; x < srcWidth; x++) [this.col[x], this.colShare[x]] = split(x, srcWidth, width);
    // One spare output column and row, so a share of 1 needs no bounds check.
    this.row = new Float64Array((width + 1) * 3);
    this.sums = new Float64Array(width * (height + 1) * 3);
  }

  /** Adds the next source row: `srcWidth` RGBA pixels starting at `offset`. */
  addRow(rgba: Uint8Array | Uint8ClampedArray, offset = 0): void {
    if (this.y >= this.srcHeight) throw new RangeError("More rows than the image has");
    if (offset + this.srcWidth * 4 > rgba.length) throw new RangeError("Row runs past the end of the buffer");
    const { row, col, colShare } = this;
    row.fill(0);
    for (let x = 0, i = offset; x < this.srcWidth; x++, i += 4) {
      let r = rgba[i];
      let g = rgba[i + 1];
      let b = rgba[i + 2];
      const a = rgba[i + 3];
      if (a !== 255) {
        // Over white: c * a/255 + 255 * (1 - a/255).
        const k = a / 255;
        r = r * k + 255 - a;
        g = g * k + 255 - a;
        b = b * k + 255 - a;
      }
      const o = col[x] * 3;
      const s = colShare[x];
      row[o] += r * s;
      row[o + 1] += g * s;
      row[o + 2] += b * s;
      if (s !== 1) {
        const t = 1 - s;
        row[o + 3] += r * t;
        row[o + 4] += g * t;
        row[o + 5] += b * t;
      }
    }
    const [oy, share] = split(this.y, this.srcHeight, this.height);
    const n = this.width * 3;
    const top = oy * n;
    for (let j = 0; j < n; j++) this.sums[top + j] += row[j] * share;
    if (share !== 1) for (let j = 0, rest = 1 - share; j < n; j++) this.sums[top + n + j] += row[j] * rest;
    this.y++;
  }

  /** The scaled image. Throws unless every source row has been added. */
  finish(): Rgba {
    if (this.y !== this.srcHeight) throw new RangeError(`Got ${this.y} of ${this.srcHeight} rows`);
    const { width, height, sums } = this;
    // Every output pixel covers the same source area.
    const perArea = (width * height) / (this.srcWidth * this.srcHeight);
    const data = new Clamped(width * height * 4);
    for (let p = 0, s = 0; p < data.length; p += 4, s += 3) {
      data[p] = sums[s] * perArea;
      data[p + 1] = sums[s + 1] * perArea;
      data[p + 2] = sums[s + 2] * perArea;
      data[p + 3] = 255;
    }
    return { data, width, height };
  }
}

/** Scales a whole RGBA image held in memory. */
export function boxScale(rgba: Uint8Array | Uint8ClampedArray, width: number, height: number, out: Size): Rgba {
  const scaler = new BoxScaler(width, height, out);
  for (let y = 0; y < height; y++) scaler.addRow(rgba, y * width * 4);
  return scaler.finish();
}

/**
 * Source pixel `i` of `n` covers [i, i+1); output pixel `o` of `m` covers
 * [o*n/m, (o+1)*n/m). Returns the output pixel that `i` starts in and the
 * share of `i` inside it; with m <= n the rest lies in o+1. Integer maths
 * scaled by m keeps the boundaries exact.
 */
function split(i: number, n: number, m: number): [number, number] {
  const o = Math.floor((i * m) / n);
  const end = (o + 1) * n; // end of output pixel o, scaled by m
  const share = (i + 1) * m <= end ? 1 : (end - i * m) / m;
  return [o, share];
}
