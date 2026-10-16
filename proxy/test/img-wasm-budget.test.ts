// Every JPEG the cap lets through decodes within JPEG_HEAP_MAX, in one
// long-lived decoder, whatever its kind: the heap keeps its high-water mark for
// the isolate's life, so this is what bounds it. Runs on its own (vitest
// isolates files) to see the decoder instance's memory.

import { describe, expect, it } from "vitest";
import sharp, { type JpegOptions } from "sharp";
import { JPEG_HEAP_MAX, createWasmResizer, jpegMaxPixels } from "../src/img-wasm";
import { wasmModules } from "./helpers/wasm";

const mods = wasmModules();
const memories: WebAssembly.Memory[] = [];
WebAssembly.Instance = new Proxy(WebAssembly.Instance, {
  construct(target, args: ConstructorParameters<typeof WebAssembly.Instance>) {
    const instance = new target(...args);
    if (args[0] === mods.jpegDec) for (const v of Object.values(instance.exports)) if (v instanceof WebAssembly.Memory) memories.push(v);
    return instance;
  },
});

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
    for (const [options, grey] of kinds) await resizer.resize(await atCap(options, grey), "jpeg");
    expect(memories).toHaveLength(1);
    expect(memories[0].buffer.byteLength).toBeLessThanOrEqual(JPEG_HEAP_MAX);
  });
});
