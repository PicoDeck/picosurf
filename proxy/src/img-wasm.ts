// The Workers resizer: jSquash WASM codecs plus omggif for GIF (spec 5.8).
// The WASM modules are passed in because Workers can only load them as
// bundled imports (worker.ts); tests compile them from node_modules.

import decodeJpeg, { init as initJpegDec } from "@jsquash/jpeg/decode";
import encodeJpeg, { init as initJpegEnc } from "@jsquash/jpeg/encode";
import decodePng, { init as initPngDec } from "@jsquash/png/decode";
import resize, { initResize } from "@jsquash/resize";
import decodeWebp, { init as initWebpDec } from "@jsquash/webp/decode";
import { GifReader } from "omggif";
import type { ImageType } from "./content";
import { JPEG_QUALITY, type Resizer, fitWithin, flattenOnWhite } from "./img";

/** Minimal ImageData for runtimes without one (Node, and possibly Workers); jSquash constructs it. */
class ImageDataShim {
  readonly colorSpace = "srgb";
  readonly data: Uint8ClampedArray;
  readonly width: number;
  readonly height: number;
  constructor(a: Uint8ClampedArray | number, b: number, c?: number) {
    if (typeof a === "number") {
      this.width = a;
      this.height = b;
      this.data = new Uint8ClampedArray(a * b * 4);
    } else {
      this.data = a;
      this.width = b;
      this.height = c ?? a.length / 4 / b;
    }
  }
}
(globalThis as { ImageData?: unknown }).ImageData ??= ImageDataShim;

/**
 * The Workers pixel cap. A Worker has 128 MB, and the WASM codecs use about
 * 30 MiB per megapixel. Peak RSS growth of one resize() of a noise JPEG in a
 * fresh Node process (node --expose-gc, 3 runs, 2026-10-15), module
 * instantiation included: 2 MP 64-67 MiB, 3 MP 95-99 MiB, 4 MP 122-131 MiB.
 * With the modules already instantiated: 2 MP 48, 3 MP 78, 4 MP 110 MiB.
 * The cap is the largest of 4, 3 or 2 MP whose growth in a fresh process stays
 * under 90 MiB.
 */
export const WASM_MAX_PIXELS = 2_000_000;

export interface WasmModules {
  jpegDec: WebAssembly.Module;
  jpegEnc: WebAssembly.Module;
  pngDec: WebAssembly.Module;
  webpDec: WebAssembly.Module;
  resize: WebAssembly.Module;
}

// The emscripten codecs accept (module, options?) at runtime, though their
// .d.ts declares only options.
type Init = (module: WebAssembly.Module) => Promise<unknown>;

export function createWasmResizer(mods: WasmModules): Resizer {
  let ready: Promise<unknown> | null = null;
  const init = () =>
    (ready ??= Promise.all([
      (initJpegDec as unknown as Init)(mods.jpegDec),
      (initJpegEnc as unknown as Init)(mods.jpegEnc),
      (initPngDec as unknown as Init)(mods.pngDec),
      (initWebpDec as unknown as Init)(mods.webpDec),
      (initResize as unknown as Init)(mods.resize),
    ]));

  return {
    maxPixels: WASM_MAX_PIXELS,
    async resize(bytes, type) {
      await init();
      const source = await decode(bytes, type);
      const { width, height } = fitWithin(source.width, source.height);
      const scaled = width === source.width && height === source.height ? source : await resize(source, { width, height });
      flattenOnWhite(scaled.data);
      const out = await encodeJpeg(scaled, { quality: JPEG_QUALITY, baseline: true, progressive: false });
      return new Uint8Array(out);
    },
  };
}

async function decode(bytes: Uint8Array, type: ImageType): Promise<ImageData> {
  const buffer = bytes.slice().buffer;
  switch (type) {
    case "jpeg":
      return decodeJpeg(buffer);
    case "png":
      return decodePng(buffer);
    case "webp":
      return decodeWebp(buffer);
    case "gif": {
      const reader = new GifReader(bytes);
      // omggif allocates for the frame descriptor's size, which the handler's
      // check of the logical screen size never saw.
      const frame = reader.frameInfo(0);
      if (frame.x + frame.width > reader.width || frame.y + frame.height > reader.height) {
        throw new Error("GIF frame lies outside the logical screen");
      }
      if (reader.width * reader.height > WASM_MAX_PIXELS) throw new Error("GIF is too large");
      const data = new Uint8ClampedArray(reader.width * reader.height * 4);
      reader.decodeAndBlitFrameRGBA(0, data);
      return new ImageData(data, reader.width, reader.height);
    }
  }
}
