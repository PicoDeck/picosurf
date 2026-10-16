// The Workers resizer (spec 5.8): PNGs stream through png-stream.ts; JPEG and
// WebP decode in long-lived jSquash WASM decoders that scale straight from
// their heaps (HeapDecoder); GIFs decode in JS (omggif); a box filter in JS
// scales down (boxscale.ts) and mozjpeg (WASM) encodes.
// The WASM modules are passed in because Workers can only load them as
// bundled imports (worker.ts); tests compile them from node_modules.

import mozjpegDec from "@jsquash/jpeg/codec/dec/mozjpeg_dec.js";
import mozjpegEnc from "@jsquash/jpeg/codec/enc/mozjpeg_enc.js";
import { defaultOptions as JPEG_ENCODER_DEFAULTS } from "@jsquash/jpeg/meta.js";
import webpDec from "@jsquash/webp/codec/dec/webp_dec.js";
import { GifReader } from "omggif";
import { type Rgba, boxScale } from "./boxscale";
import type { ImageType } from "./content";
import { ProxyError } from "./errors";
import { JPEG_QUALITY, type Resizer, fitWithin } from "./img";
import { type Size, imageSize, jpegInfo, jpegScans } from "./imgsize";
import { Mutex } from "./mutex";
import { PNG_MAX_SIDE, streamPng } from "./png-stream";

// The Workers caps. A Worker isolate has 128 MB in all. The JPEG and WebP
// decoders and the encoder each keep a WASM heap for the isolate's life (16
// MiB each to start), so the caps bound how far those heaps can grow, and
// everything else an image needs is freed with it (scripts/measure-images.ts
// measures this in workerd).

const MiB = 1024 * 1024;

/** The most pixels a JPEG may have, however little heap its decode needs. Lower this to trade large photos for headroom. */
export const JPEG_MAX_PIXELS = 8_000_000;

/**
 * The most the JPEG decoder's WASM heap may grow to. It keeps its high-water
 * mark for the life of the isolate (see HeapDecoder), so this, rather than a
 * pixel count, is what bounds JPEG memory: each JPEG may have as many pixels
 * as fit (jpegMaxPixels).
 */
export const JPEG_HEAP_MAX = 48 * MiB;

/**
 * The most scans a JPEG may have. mozjpeg decodes every scan in full, and a
 * JPEG can repeat one as often as it likes (50,000 repeats took 5.8 s of CPU,
 * so a 10 MiB file would run past the 30 s limit). Real progressive JPEGs
 * have about 10.
 */
export const JPEG_MAX_SCANS = 100;

/**
 * Refuses, before decoding, a JPEG the decoder should not see: CMYK or YCCK
 * (4 components), which mozjpeg cannot convert to RGB and gives up on with
 * exit(), costing the instance; and one with too many scans.
 */
function refuseJpeg(bytes: Uint8Array): void {
  if (jpegInfo(bytes)?.components.length === 4) throw new ProxyError(415, "CMYK JPEGs are not supported");
  if (jpegScans(bytes) > JPEG_MAX_SCANS) throw new ProxyError(415, `JPEG has too many scans (over ${JPEG_MAX_SCANS})`);
}

/** SOF markers of progressive JPEGs. */
const PROGRESSIVE = new Set([0xc2, 0xc6, 0xca, 0xce]);

/**
 * The most pixels this JPEG may have for its decode to stay within
 * JPEG_HEAP_MAX, and never more than JPEG_MAX_PIXELS. mozjpeg's heap holds the
 * file twice, the RGBA pixels (4 bytes each) and, when the JPEG is
 * progressive or has more than one scan, every DCT coefficient (2 bytes each:
 * 3 a pixel at 4:2:0, 6 at 4:4:4); measured to within 1%. A heap reused
 * across images needs up to a quarter more than the largest image alone
 * (emscripten grows a heap by at least a fifth, and the free space left by
 * one image does not always fit the next), hence the 1.3.
 */
export function jpegMaxPixels(bytes: Uint8Array): number {
  const info = jpegInfo(bytes);
  if (!info || info.components.length === 0) return JPEG_MAX_PIXELS; // unreadable: the decode will fail
  const hmax = Math.max(...info.components.map(([h]) => h));
  const vmax = Math.max(...info.components.map(([, v]) => v));
  const coefficients =
    hmax > 0 && vmax > 0 ? info.components.reduce((n, [h, v]) => n + (h * v) / (hmax * vmax), 0) : info.components.length;
  const buffered = PROGRESSIVE.has(info.sof) || jpegScans(bytes) > 1;
  const perPixel = 4 + (buffered ? 2 * coefficients : 0);
  const room = JPEG_HEAP_MAX / 1.3 - MiB - 2 * bytes.length;
  return Math.max(0, Math.min(JPEG_MAX_PIXELS, Math.floor(room / perPixel)));
}

/**
 * The most pixels a PNG may have. A PNG streams (png-stream.ts) through a
 * 64 KiB window and two rows, so memory does not bound it (in workerd a PNG
 * costs 2 to 10 MiB beyond its own bytes, a 1 GiB decompression bomb
 * included). CPU does: about 15 ns a pixel, 20 at 16 bits, so 100 MP takes
 * 1.3 to 2 s. The 10 MiB body cap does not bound it: deflate packs flat colour
 * about 1000:1, so a 10 MiB PNG can declare billions of pixels and would run
 * past the 30 s CPU limit instead of getting a clear 413. PNG_MAX_SIDE also
 * bounds each side.
 */
export const PNG_STREAM_MAX_PIXELS = 100_000_000;

/** The most pixels a WebP or GIF may have. GIFs decode whole in JS (omggif). */
export const WASM_MAX_PIXELS = 2_000_000;

/**
 * The most the WebP decoder's WASM heap may grow to, which it keeps for the
 * life of the isolate, like the JPEG decoder's: each WebP may have as many
 * pixels as fit (webpMaxPixels).
 */
export const WEBP_HEAP_MAX = 32 * MiB;

/**
 * The most pixels this WebP may have for its decode to stay within
 * WEBP_HEAP_MAX, and never more than WASM_MAX_PIXELS. libwebp's heap holds the
 * file twice and 8 bytes a pixel (the RGBA out, and its own buffers), lossy
 * or lossless; measured to within 2%. A heap reused across WebPs needed up to
 * half as much again as the largest alone, hence the 1.5.
 */
export function webpMaxPixels(bytes: Uint8Array): number {
  const room = WEBP_HEAP_MAX / 1.5 - MiB - 2 * bytes.length;
  return Math.max(0, Math.min(WASM_MAX_PIXELS, Math.floor(room / 8)));
}

export interface WasmModules {
  jpegDec: WebAssembly.Module;
  jpegEnc: WebAssembly.Module;
  webpDec: WebAssembly.Module;
}

/**
 * How long an image job waits for the one before it to finish before going
 * ahead anyway (see Mutex). The slowest job the caps allow, a 100 MP PNG of
 * 16-bit RGBA, takes about 2 s of CPU (2026-10-16, Node on a desktop); a
 * JPEG or WebP well under 1 s.
 *
 * The cost: if a request's job, or its wait for the lock, is cancelled (the
 * client went away) and its promises are dropped, it never releases the
 * lock, and the next image in the isolate waits the full 10 s before going
 * ahead. Each image after that waits only for the one before it.
 */
const JOB_MAX_WAIT_MS = 10_000;

/**
 * Image jobs in this isolate, one at a time: two large images decoding at
 * once would each hold their pixels and could together pass 128 MB. Module
 * scope, because the codecs' own state is per isolate too.
 */
const jobs = new Mutex(JOB_MAX_WAIT_MS);

/** The parts of an emscripten codec factory this file uses. */
type EmscriptenFactory = (options: {
  noInitialRun: boolean;
  instantiateWasm: (imports: WebAssembly.Imports, done: (instance: WebAssembly.Instance) => void) => WebAssembly.Exports;
}) => Promise<unknown>;

/** An emscripten codec instance, made from its compiled module on first use, and made again after a failure. */
class Emscripten<T> {
  private instance: Promise<T> | null = null;

  constructor(
    private readonly factory: unknown,
    private readonly module: WebAssembly.Module,
  ) {}

  get(): Promise<T> {
    return (this.instance ??= this.make().catch((e) => {
      this.instance = null;
      throw e;
    }));
  }

  /** Forgets the instance (after it failed); the next get() makes a new one. */
  drop(): void {
    this.instance = null;
  }

  private make(): Promise<T> {
    const module = this.module;
    return (this.factory as EmscriptenFactory)({
      noInitialRun: true,
      instantiateWasm(imports, done) {
        const instance = new WebAssembly.Instance(module, imports);
        done(instance);
        return instance.exports;
      },
    }) as Promise<T>;
  }
}

interface JpegEncoder {
  encode(data: Uint8ClampedArray, width: number, height: number, options: typeof JPEG_ENCODER_DEFAULTS): Uint8Array;
}
const ENCODE = { ...JPEG_ENCODER_DEFAULTS, quality: JPEG_QUALITY, baseline: true, progressive: false };

export function createWasmResizer(mods: WasmModules): Resizer {
  // Made on first use; the encoder only ever sees 320x320 images.
  const encoder = new Emscripten<JpegEncoder>(mozjpegEnc, mods.jpegEnc);
  const decoders: Decoders = {
    jpeg: new HeapDecoder(mozjpegDec, mods.jpegDec, false), // false: ignore EXIF orientation, as jSquash does
    webp: new HeapDecoder(webpDec, mods.webpDec),
  };

  return {
    maxPixels(bytes, type) {
      if (type === "jpeg") return jpegMaxPixels(bytes);
      if (type === "webp") return webpMaxPixels(bytes);
      if (type === "png") {
        const size = imageSize(bytes, "png");
        return size && Math.max(size.width, size.height) > PNG_MAX_SIDE ? 0 : PNG_STREAM_MAX_PIXELS;
      }
      return WASM_MAX_PIXELS;
    },
    async resize(bytes, type) {
      if (type === "jpeg") refuseJpeg(bytes);
      return jobs.run(async () => {
        const scaled = await decodeScaled(bytes, type, decoders);
        const jpeg = await encoder.get();
        try {
          return jpeg.encode(scaled.data, scaled.width, scaled.height, ENCODE);
        } catch (e) {
          encoder.drop();
          throw e;
        }
      });
    },
  };
}

interface Decoders {
  jpeg: HeapDecoder;
  webp: HeapDecoder;
}

const RealUint8ClampedArray = Uint8ClampedArray;

/** What the current HeapDecoder.decode() expects, and what its PixelSink made of the pixels. */
let pending: { size: Size; scaled: Rgba | null } | null = null;

/**
 * Stands in for Uint8ClampedArray inside the emscripten decoders, which call
 * it once per decode with a view of the decoded RGBA pixels in their heap.
 * While a HeapDecoder is waiting for pixels of the expected size, it scales
 * them there and then, while the view is valid, and returns an empty array;
 * otherwise it copies, as Uint8ClampedArray would.
 */
function PixelSink(this: unknown, view: Uint8Array): Uint8ClampedArray {
  const p = pending;
  if (p && !p.scaled && view.length === p.size.width * p.size.height * 4) {
    p.scaled = boxScale(view, p.size.width, p.size.height, fitWithin(p.size.width, p.size.height));
    return new RealUint8ClampedArray(0);
  }
  return new RealUint8ClampedArray(view);
}

/** Stands in for ImageData inside the emscripten decoders. */
class DecodedImage {
  constructor(
    readonly data: Uint8ClampedArray,
    readonly width: number,
    readonly height: number,
  ) {}
}

/**
 * Instances that kept PixelSink and DecodedImage: embind looked them up at the
 * instance's first decode that produced an image. Per instance, so a new one
 * is always bound, whatever happened to the one before.
 */
const bound = new WeakSet<object>();

/**
 * Dropped instances an isolate may hold uncollected, per codec, before that
 * codec refuses images with 503. Each holds its heap (16 MiB or more) until
 * the garbage collector reaches it, which workerd may not do for a long
 * while: eight dropped JPEG decoders left 144-184 MiB.
 */
export const MAX_DROPPED_DECODERS = 2;

/**
 * An emscripten decoder (mozjpeg, libwebp) kept for the life of the isolate,
 * which scales each image straight out of its WASM heap.
 *
 * One instance, reused: WASM memory never shrinks and is freed only when the
 * garbage collector gets to the instance, which workerd may not do for many
 * requests (ten 8 MP JPEGs with a fresh instance each left 600 MiB). The one
 * heap stays at its high-water mark instead, which the pixel cap bounds.
 *
 * A decode that throws (mozjpeg calls exit() on a fatal error, leaving its
 * stack and heap as they were) costs the instance: the next image gets a new
 * one. The dropped ones are counted until collected, and while
 * MAX_DROPPED_DECODERS are, images of this codec get 503. A decoder that
 * returns no image (libwebp on a broken file) refused cleanly and is kept.
 *
 * No copy of the pixels: jSquash's C++ returns
 * `ImageData(Uint8ClampedArray(typed_memory_view(pixels)), w, h)`, a full RGBA
 * copy out of the heap. embind looks both names up on globalThis when an
 * instance first gets that far and keeps what it finds, so until then each
 * decode runs with PixelSink and DecodedImage in their place.
 */
export class HeapDecoder {
  private readonly codec: Emscripten<{ decode(data: Uint8Array, ...options: unknown[]): unknown }>;
  private readonly options: unknown[];
  /**
   * Instances dropped after a failed decode, until the garbage collector frees
   * them. WeakRefs rather than a FinalizationRegistry: they clear with the
   * collection itself, while workerd need not run finalization callbacks.
   */
  private dropped: { deref(): object | undefined }[] = [];

  constructor(factory: unknown, module: WebAssembly.Module, ...options: unknown[]) {
    this.codec = new Emscripten(factory, module);
    this.options = options;
  }

  /** Decodes an image whose header gave `size`, scaled to fit 320x320. */
  async decode(bytes: Uint8Array, size: Size): Promise<Rgba> {
    this.dropped = this.dropped.filter((ref) => ref.deref() !== undefined);
    if (this.dropped.length >= MAX_DROPPED_DECODERS) {
      throw new ProxyError(503, "Busy after broken images, try again in a minute", { "Retry-After": "60" });
    }
    const codec = await this.codec.get();
    const wanted = { size, scaled: null as Rgba | null };
    let image: DecodedImage | null;
    pending = wanted;
    try {
      const decode = () => codec.decode(bytes, ...this.options) as DecodedImage | null;
      image = bound.has(codec) ? decode() : this.bind(codec, decode);
    } catch (e) {
      this.codec.drop();
      // Without WeakRef (never on Workers or Node 22) a dropped instance counts for good.
      this.dropped.push(typeof WeakRef === "function" ? new WeakRef(codec) : { deref: () => codec });
      throw e;
    } finally {
      pending = null;
    }
    if (!image) throw new Error("Decoding error");
    if (wanted.scaled) return wanted.scaled;
    // Not the size the header gave: PixelSink copied them, so scale the copy.
    return boxScale(image.data, image.width, image.height, fitWithin(image.width, image.height));
  }

  /** Runs a decode with PixelSink and DecodedImage in place of the globals, and notes whether the instance kept them. */
  private bind<T>(codec: object, decode: () => T): T {
    const g = globalThis as Record<string, unknown>;
    const hadImageData = "ImageData" in g;
    const saved = [g.Uint8ClampedArray, g.ImageData];
    try {
      g.Uint8ClampedArray = PixelSink;
      g.ImageData = DecodedImage;
      const image = decode();
      if (image instanceof DecodedImage) bound.add(codec);
      return image;
    } finally {
      g.Uint8ClampedArray = saved[0];
      if (hadImageData) g.ImageData = saved[1];
      else delete g.ImageData;
    }
  }
}

/** Decodes and scales to fit 320x320: PNGs stream, JPEG and WebP scale in their decoder, GIFs decode whole first. */
async function decodeScaled(bytes: Uint8Array, type: ImageType, decoders: Decoders): Promise<Rgba> {
  if (type === "png") return streamPng(bytes);
  if (type === "gif") {
    const image = decodeGif(bytes);
    return boxScale(image.data, image.width, image.height, fitWithin(image.width, image.height));
  }
  const size = imageSize(bytes, type);
  if (!size) throw new Error("Could not read the image size");
  return decoders[type].decode(bytes, size);
}

/** The first frame of a GIF, whole. */
function decodeGif(bytes: Uint8Array): Rgba {
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
  return { data, width: reader.width, height: reader.height };
}
