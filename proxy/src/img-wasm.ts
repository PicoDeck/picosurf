// The Workers resizer: jSquash WASM codecs to decode and encode, omggif for
// GIF, a streaming decoder for most PNGs (png-stream.ts), and a box filter in
// JS to scale down (boxscale.ts) (spec 5.8).
// The WASM modules are passed in because Workers can only load them as
// bundled imports (worker.ts); tests compile them from node_modules.

import mozjpegDec from "@jsquash/jpeg/codec/dec/mozjpeg_dec.js";
import encodeJpeg, { init as initJpegEnc } from "@jsquash/jpeg/encode";
import decodePng, { init as initPngDec } from "@jsquash/png/decode";
import webpDec from "@jsquash/webp/codec/dec/webp_dec.js";
import { GifReader } from "omggif";
import { type Rgba, boxScale } from "./boxscale";
import type { ImageType } from "./content";
import { JPEG_QUALITY, type Resizer, fitWithin } from "./img";
import { Mutex } from "./mutex";
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

// The Workers pixel caps, per decoder; a Worker isolate has 128 MB in all.
// The figures are RSS growth of a fresh Node process from
// scripts/measure-images.ts (2026-10-16): "cold" includes instantiating the
// encoder, "warm" is each further image.

/**
 * JPEGs decode whole in WASM: a fresh decoder whose heap holds the input and
 * the RGBA pixels, then jSquash's JS copy of those pixels, so about 8 MiB a
 * megapixel. An 8 MP photo grows 77 MiB cold and 67 warm (the noisiest
 * 8 MP JPEG 85 and 71); 4 MP 43 and 37. Lower this to trade large photos
 * for headroom.
 */
export const JPEG_MAX_PIXELS = 8_000_000;

/**
 * PNGs that stream (png-stream.ts) hold a few rows, so memory does not bound
 * them (photos up to 12 MP grow under 7 MiB warm; screenshots up to 16, the
 * inflated chunks waiting for collection). CPU does: about 15 ns a pixel,
 * though a one-pixel-wide strip costs about 90 (each row has its overhead),
 * so 100 MP takes 1.5 to 9 s. The 10 MiB body cap does not bound it: deflate
 * packs flat colour about 1000:1, so a 10 MiB PNG can declare billions of
 * pixels and would run past the 30 s CPU limit instead of getting a clear 413.
 */
export const PNG_STREAM_MAX_PIXELS = 100_000_000;

/**
 * Everything else decodes whole: PNGs that cannot stream (16-bit, under 8
 * bits, interlaced) in the WASM PNG decoder, whose heap keeps its high-water
 * mark (24 MiB after a 2 MP PNG; 47 MiB growth cold), WebP in a fresh WASM
 * decoder, and GIF in JS (omggif).
 */
export const WASM_MAX_PIXELS = 2_000_000;

export interface WasmModules {
  jpegDec: WebAssembly.Module;
  jpegEnc: WebAssembly.Module;
  pngDec: WebAssembly.Module;
  webpDec: WebAssembly.Module;
}

/**
 * How long an image job waits for the one before it to finish before going
 * ahead anyway (see Mutex). Legitimate jobs take at most a second or two.
 */
const JOB_MAX_WAIT_MS = 10_000;

/**
 * Image jobs in this isolate, one at a time: two large images decoding at
 * once would each hold their pixels and could together pass 128 MB. Module
 * scope, because the codecs' own state is per isolate too.
 */
const jobs = new Mutex(JOB_MAX_WAIT_MS);

// jSquash's init functions accept (module, options?) at runtime, though their
// .d.ts declares only options.
type Init = (module: WebAssembly.Module) => Promise<unknown>;

/** The parts of an emscripten codec factory this file uses. */
type EmscriptenFactory = (options: {
  noInitialRun: boolean;
  instantiateWasm: (imports: WebAssembly.Imports, done: (instance: WebAssembly.Instance) => void) => WebAssembly.Exports;
}) => Promise<{ decode(data: Uint8Array, ...options: unknown[]): ImageData | null }>;

interface Decoders {
  jpeg(bytes: Uint8Array): Promise<ImageData>;
  png(bytes: Uint8Array): Promise<ImageData>;
  webp(bytes: Uint8Array): Promise<ImageData>;
}

export function createWasmResizer(mods: WasmModules): Resizer {
  // Instantiated on first use. The encoder only ever sees 320x320 images, and
  // the WASM PNG decoder only PNGs that cannot stream, under WASM_MAX_PIXELS.
  let encoder: Promise<unknown> | null = null;
  let pngDecoder: Promise<unknown> | null = null;
  const decoders: Decoders = {
    jpeg: (bytes) => decodeFresh(mozjpegDec, mods.jpegDec, bytes, false), // false: ignore EXIF orientation, as jSquash does
    webp: (bytes) => decodeFresh(webpDec, mods.webpDec, bytes),
    async png(bytes) {
      await (pngDecoder ??= (initPngDec as unknown as Init)(mods.pngDec));
      return decodePng(bytes.slice().buffer);
    },
  };

  return {
    maxPixels(bytes, type) {
      if (type === "jpeg") return JPEG_MAX_PIXELS;
      if (type === "png" && canStreamPng(bytes)) return PNG_STREAM_MAX_PIXELS;
      return WASM_MAX_PIXELS;
    },
    resize: (bytes, type) =>
      jobs.run(async () => {
        const scaled = await decodeScaled(bytes, type, decoders);
        await (encoder ??= (initJpegEnc as unknown as Init)(mods.jpegEnc));
        const out = await encodeJpeg(new ImageData(scaled.data, scaled.width, scaled.height), {
          quality: JPEG_QUALITY,
          baseline: true,
          progressive: false,
        });
        return new Uint8Array(out);
      }),
  };
}

/**
 * Decodes with a fresh instance of an emscripten decoder. WASM memory never
 * shrinks, so a long-lived decoder would hold on to the largest image's heap
 * for the life of the isolate; a fresh one is garbage as soon as this returns.
 */
async function decodeFresh(factory: unknown, module: WebAssembly.Module, bytes: Uint8Array, ...options: unknown[]): Promise<ImageData> {
  const codec = await (factory as EmscriptenFactory)({
    noInitialRun: true,
    instantiateWasm(imports, done) {
      const instance = new WebAssembly.Instance(module, imports);
      done(instance);
      return instance.exports;
    },
  });
  const image = codec.decode(bytes, ...options);
  if (!image) throw new Error("Decoding error");
  return image;
}

/** Decodes and scales to fit 320x320: 8-bit PNGs stream, everything else decodes whole first. */
async function decodeScaled(bytes: Uint8Array, type: ImageType, decoders: Decoders): Promise<Rgba> {
  if (type === "png" && canStreamPng(bytes)) return streamPng(bytes);
  const image = await decode(bytes, type, decoders);
  return boxScale(image.data, image.width, image.height, fitWithin(image.width, image.height));
}

async function decode(bytes: Uint8Array, type: ImageType, decoders: Decoders): Promise<ImageData> {
  switch (type) {
    case "jpeg":
      return decoders.jpeg(bytes);
    case "png":
      return decoders.png(bytes);
    case "webp":
      return decoders.webp(bytes);
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
