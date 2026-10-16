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
