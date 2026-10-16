import sharp from "sharp";
import { DEFAULT_BOX, JPEG_QUALITY, MAX_PIXELS, type Resizer } from "./img";

/** The Node resizer. sharp handles every input type the handler accepts. */
export function createSharpResizer(): Resizer {
  return {
    maxPixels: () => MAX_PIXELS,
    async resize(bytes, _type, box = DEFAULT_BOX) {
      const out = await sharp(bytes, { limitInputPixels: MAX_PIXELS, animated: false })
        .rotate() // apply EXIF orientation
        .flatten({ background: "#ffffff" })
        .resize(box.width, box.height, { fit: "inside", withoutEnlargement: true })
        .jpeg({ quality: JPEG_QUALITY, progressive: false, mozjpeg: false })
        .toBuffer();
      return new Uint8Array(out.buffer, out.byteOffset, out.byteLength);
    },
  };
}
