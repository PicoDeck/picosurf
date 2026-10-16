import type { Sharp } from "sharp";
import type { Size } from "../../src/imgsize";

/** What sharp makes of an image at `size`: flattened onto white, RGB. */
export async function sharpReference(img: Sharp, size: Size): Promise<Uint8Array> {
  const { data, info } = await img
    .flatten({ background: "#ffffff" })
    .resize(size.width, size.height, { fit: "fill" })
    .raw()
    .toBuffer({ resolveWithObject: true });
  if (info.channels !== 3) throw new Error(`expected RGB from sharp, got ${info.channels} channels`);
  return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
}

/** The largest of the per-channel mean absolute differences between RGBA `rgba` and RGB `rgb`. */
export function meanAbsError(rgba: Uint8ClampedArray, rgb: Uint8Array): number {
  const n = rgba.length / 4;
  if (rgb.length !== n * 3) throw new Error(`size mismatch: ${n} vs ${rgb.length / 3} pixels`);
  const sums = [0, 0, 0];
  for (let i = 0; i < n; i++) for (let c = 0; c < 3; c++) sums[c] += Math.abs(rgba[i * 4 + c] - rgb[i * 3 + c]);
  return Math.max(...sums) / n;
}
