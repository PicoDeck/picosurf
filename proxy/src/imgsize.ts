// Image dimensions from headers alone, so oversized images are refused before
// decoding (spec 5.8), plus the JPEG frame type for the baseline check.

import type { ImageType } from "./content";

export interface Size { width: number; height: number }
export interface JpegInfo { size: Size; sof: number }

const u16be = (b: Uint8Array, i: number) => (b[i] << 8) | b[i + 1];
const u16le = (b: Uint8Array, i: number) => b[i] | (b[i + 1] << 8);
const u24le = (b: Uint8Array, i: number) => b[i] | (b[i + 1] << 8) | (b[i + 2] << 16);
const u32be = (b: Uint8Array, i: number) => ((b[i] << 24) >>> 0) + (b[i + 1] << 16) + (b[i + 2] << 8) + b[i + 3];

export function imageSize(b: Uint8Array, type: ImageType): Size | null {
  switch (type) {
    case "png":
      return b.length >= 24 ? { width: u32be(b, 16), height: u32be(b, 20) } : null;
    case "gif":
      return b.length >= 10 ? { width: u16le(b, 6), height: u16le(b, 8) } : null;
    case "webp":
      return webpSize(b);
    case "jpeg":
      return jpegInfo(b)?.size ?? null;
  }
}

function webpSize(b: Uint8Array): Size | null {
  if (b.length < 30) return null;
  const chunk = String.fromCharCode(b[12], b[13], b[14], b[15]);
  if (chunk === "VP8 ") return { width: u16le(b, 26) & 0x3fff, height: u16le(b, 28) & 0x3fff };
  if (chunk === "VP8L") {
    const bits = (b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24)) >>> 0;
    return { width: (bits & 0x3fff) + 1, height: ((bits >>> 14) & 0x3fff) + 1 };
  }
  if (chunk === "VP8X") return { width: u24le(b, 24) + 1, height: u24le(b, 27) + 1 };
  return null;
}

/** Walks JPEG markers to the first start-of-frame. */
export function jpegInfo(b: Uint8Array): JpegInfo | null {
  let i = 2;
  while (i + 9 < b.length) {
    if (b[i] !== 0xff) {
      i++;
      continue;
    }
    const marker = b[i + 1];
    if (marker === 0xff) {
      i++;
      continue;
    }
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      i += 2;
      continue;
    }
    if (marker === 0xd9 || marker === 0xda) return null; // end of image or scan before any frame
    if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
      return { sof: marker, size: { height: u16be(b, i + 5), width: u16be(b, i + 7) } };
    }
    i += 2 + u16be(b, i + 2);
  }
  return null;
}
