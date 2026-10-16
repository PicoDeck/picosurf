// Every JPEG and WebP their caps let through decode within JPEG_HEAP_MAX and
// WEBP_HEAP_MAX, in one long-lived decoder each, whatever their kind and
// order: the heaps keep their high-water marks for the isolate's life, so this
// is what bounds them. Runs on its own (vitest isolates files) to see the
// decoder instances' memory.

import { describe, expect, it } from "vitest";
import sharp, { type JpegOptions } from "sharp";
import { JPEG_HEAP_MAX, WEBP_HEAP_MAX, createWasmResizer, jpegMaxPixels, webpMaxPixels } from "../src/img-wasm";
import { wasmModules } from "./helpers/wasm";

const mods = wasmModules();
const memories = new Map<WebAssembly.Module, WebAssembly.Memory[]>([
  [mods.jpegDec, []],
  [mods.webpDec, []],
]);
WebAssembly.Instance = new Proxy(WebAssembly.Instance, {
  construct(target, args: ConstructorParameters<typeof WebAssembly.Instance>) {
    const instance = new target(...args);
    for (const v of Object.values(instance.exports)) if (v instanceof WebAssembly.Memory) memories.get(args[0])?.push(v);
    return instance;
  },
});

const shuffled = <T>(xs: T[]) => xs.map((x) => [Math.random(), x] as const).sort((a, b) => a[0] - b[0]).map(([, x]) => x);

/** Random pixels: the biggest file, and so the most heap, for a size. */
function noise(width: number, height: number): Buffer {
  const raw = Buffer.alloc(width * height * 3);
  for (let i = 0; i < raw.length; i++) raw[i] = Math.random() * 256;
  return raw;
}

/** The largest 4:3 JPEG of this kind that its cap lets through. */
async function atCap(options: JpegOptions, grey = false): Promise<Uint8Array> {
  let mp = 8;
  for (;;) {
    const width = Math.floor(Math.sqrt((mp * 1e6 * 4) / 3));
    const height = Math.floor((width * 3) / 4);
    let img = sharp(noise(width, height), { raw: { width, height, channels: 3 } });
    if (grey) img = img.toColourspace("b-w");
    const bytes = new Uint8Array(await img.jpeg(options).toBuffer());
    const cap = bytes.length > 10 * 1024 * 1024 ? 0 : jpegMaxPixels(bytes); // the handler refuses bodies over 10 MiB
    if (width * height <= cap) return bytes;
    // Too big: a smaller image has a smaller file, so its cap is a little higher.
    mp = cap > 0 ? (cap / 1e6) * 0.98 : mp / 2;
  }
}

describe("JPEGs at their caps", () => {
  it("decode within JPEG_HEAP_MAX, one after another in one decoder", async () => {
    const resizer = createWasmResizer(mods);
    const kinds: [JpegOptions, boolean][] = [
      [{ quality: 90 }, false],
      [{ quality: 95, chromaSubsampling: "4:4:4" }, false],
      [{ quality: 90, progressive: true }, false],
      [{ quality: 95, progressive: true, chromaSubsampling: "4:4:4" }, false],
      [{ quality: 95, progressive: true }, true],
    ];
    const files: Uint8Array[] = [];
    for (const [options, grey] of kinds) files.push(await atCap(options, grey));
    for (const file of [...shuffled(files), ...shuffled(files)]) await resizer.resize(file, "jpeg");
    const heaps = memories.get(mods.jpegDec) ?? [];
    expect(heaps).toHaveLength(1);
    expect(heaps[0].buffer.byteLength).toBeLessThanOrEqual(JPEG_HEAP_MAX);
  });
});

describe("WebPs at their caps", () => {
  /** The largest WebP of this kind and aspect ratio that its cap lets through. */
  async function webpAtCap(channels: 3 | 4, lossless: boolean, aspect: number): Promise<Uint8Array> {
    let mp = 2;
    for (;;) {
      const width = Math.floor(Math.sqrt(mp * 1e6 * aspect));
      const height = Math.floor((mp * 1e6) / width);
      const raw = Buffer.alloc(width * height * channels);
      for (let i = 0; i < raw.length; i++) raw[i] = Math.random() * 256;
      const bytes = new Uint8Array(await sharp(raw, { raw: { width, height, channels } }).webp(lossless ? { lossless } : { quality: 100 }).toBuffer());
      const cap = webpMaxPixels(bytes);
      if (width * height <= cap) return bytes;
      mp = (cap / 1e6) * 0.98;
    }
  }

  it("decode within WEBP_HEAP_MAX, one after another in one decoder", async () => {
    const resizer = createWasmResizer(mods);
    const files: Uint8Array[] = [];
    for (const aspect of [4 / 3, 1, 4]) for (const [channels, lossless] of [[3, true], [4, true], [4, false]] as const) files.push(await webpAtCap(channels, lossless, aspect));
    for (const file of [...shuffled(files), ...shuffled(files), ...shuffled(files)]) await resizer.resize(file, "webp");
    const heaps = memories.get(mods.webpDec) ?? [];
    expect(heaps).toHaveLength(1);
    expect(heaps[0].buffer.byteLength).toBeLessThanOrEqual(WEBP_HEAP_MAX);
  });
});
