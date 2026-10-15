import type { ImageType } from "./content";
import type { Size } from "./imgsize";

export const MAX_SIDE = 320;
/** The sharp resizer's cap (Node/Docker). The WASM resizer has its own, lower one. */
export const MAX_PIXELS = 16_000_000;
export const JPEG_QUALITY = 75;

/** Turns an image into a baseline JPEG within MAX_SIDE x MAX_SIDE (spec 5.8). */
export interface Resizer {
  /** Images with more pixels than this are refused with 413 before decoding. */
  readonly maxPixels: number;
  resize(bytes: Uint8Array, type: ImageType): Promise<Uint8Array>;
}

/** Scales down to fit `max` x `max`, keeping the aspect ratio; never enlarges. */
export function fitWithin(width: number, height: number, max = MAX_SIDE): Size {
  const scale = Math.min(1, max / width, max / height);
  return { width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale)) };
}

/** Composites RGBA pixels over white in place, leaving every pixel opaque. */
export function flattenOnWhite(rgba: Uint8ClampedArray): void {
  for (let i = 0; i < rgba.length; i += 4) {
    const a = rgba[i + 3];
    if (a === 255) continue;
    const k = a / 255;
    rgba[i] = rgba[i] * k + 255 * (1 - k);
    rgba[i + 1] = rgba[i + 1] * k + 255 * (1 - k);
    rgba[i + 2] = rgba[i + 2] * k + 255 * (1 - k);
    rgba[i + 3] = 255;
  }
}
