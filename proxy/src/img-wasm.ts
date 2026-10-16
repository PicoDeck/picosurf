// The Workers resizer: jSquash WASM codecs to decode and encode, omggif for
// GIF, a streaming decoder for most PNGs (png-stream.ts), and a box filter in
// JS to scale down (boxscale.ts) (spec 5.8).
// The WASM modules are passed in because Workers can only load them as
// bundled imports (worker.ts); tests compile them from node_modules.

import decodeJpeg, { init as initJpegDec } from "@jsquash/jpeg/decode";
import encodeJpeg, { init as initJpegEnc } from "@jsquash/jpeg/encode";
import decodePng, { init as initPngDec } from "@jsquash/png/decode";
import decodeWebp, { init as initWebpDec } from "@jsquash/webp/decode";
import { GifReader } from "omggif";
import { type Rgba, boxScale } from "./boxscale";
import type { ImageType } from "./content";
import { JPEG_QUALITY, type Resizer, fitWithin } from "./img";
import { canStreamPng, streamPng } from "./png-stream";

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
    ]));

  return {
    maxPixels: WASM_MAX_PIXELS,
    async resize(bytes, type) {
      await init();
      const scaled = await decodeScaled(bytes, type);
      const out = await encodeJpeg(new ImageData(scaled.data, scaled.width, scaled.height), {
        quality: JPEG_QUALITY,
        baseline: true,
        progressive: false,
      });
      return new Uint8Array(out);
    },
  };
}

/** Decodes and scales to fit 320x320: 8-bit PNGs stream, everything else decodes whole first. */
async function decodeScaled(bytes: Uint8Array, type: ImageType): Promise<Rgba> {
  if (type === "png" && canStreamPng(bytes)) return streamPng(bytes);
  const image = await decode(bytes, type);
  return boxScale(image.data, image.width, image.height, fitWithin(image.width, image.height));
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
