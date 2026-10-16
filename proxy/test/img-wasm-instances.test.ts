// Which WASM codec instances the resizer creates, and when. Codec instances
// are per process, so this file must run on its own (vitest isolates files).

import { beforeEach, describe, expect, it } from "vitest";
import sharp from "sharp";
import { createWasmResizer } from "../src/img-wasm";
import { photo } from "./helpers/png";
import { withBrokenLastScan } from "./helpers/jpeg";
import { imageFixture } from "./helpers/resizer-contract";
import { wasmModules } from "./helpers/wasm";

const created: WebAssembly.Module[] = [];
const RealInstance = WebAssembly.Instance;
WebAssembly.Instance = new Proxy(RealInstance, {
  construct(target, args: ConstructorParameters<typeof WebAssembly.Instance>) {
    created.push(args[0]);
    return new target(...args);
  },
});
const realInstantiate = WebAssembly.instantiate.bind(WebAssembly);
WebAssembly.instantiate = ((source: unknown, imports?: WebAssembly.Imports) => {
  if (source instanceof WebAssembly.Module) created.push(source);
  return realInstantiate(source as WebAssembly.Module, imports);
}) as typeof WebAssembly.instantiate;

const mods = wasmModules();
const resizer = createWasmResizer(mods);
const count = () => ({
  jpegDec: created.filter((m) => m === mods.jpegDec).length,
  jpegEnc: created.filter((m) => m === mods.jpegEnc).length,
  webpDec: created.filter((m) => m === mods.webpDec).length,
});

beforeEach(() => {
  created.length = 0;
});

describe("wasm resizer codec instances", () => {
  it("creates none until there is an image", () => {
    createWasmResizer(wasmModules());
    expect(created).toEqual([]);
  });

  it("creates one JPEG decoder and one encoder, and reuses them", async () => {
    await resizer.resize(imageFixture("photo.jpg"), "jpeg");
    await resizer.resize(imageFixture("photo-progressive.jpg"), "jpeg");
    await resizer.resize(imageFixture("photo.jpg"), "jpeg");
    expect(count()).toEqual({ jpegDec: 1, jpegEnc: 1, webpDec: 0 });
  });

  it("refuses a CMYK JPEG before decoding it: the decoder is kept", async () => {
    const cmyk = await sharp(photo(80, 60, 3), { raw: { width: 80, height: 60, channels: 3 } }).toColourspace("cmyk").jpeg().toBuffer();
    await resizer.resize(imageFixture("photo.jpg"), "jpeg");
    created.length = 0;
    await expect(resizer.resize(new Uint8Array(cmyk), "jpeg")).rejects.toThrow("CMYK");
    await resizer.resize(imageFixture("photo.jpg"), "jpeg");
    expect(count().jpegDec).toBe(0);
  });

  it("replaces the JPEG decoder after mozjpeg gives up partway through a decode", async () => {
    await expect(resizer.resize(withBrokenLastScan(imageFixture("photo-progressive.jpg")), "jpeg")).rejects.toThrow();
    await resizer.resize(imageFixture("photo.jpg"), "jpeg");
    await resizer.resize(imageFixture("photo.jpg"), "jpeg");
    expect(count().jpegDec).toBe(1);
  });

  it("streams PNGs, 8-bit, 16-bit or interlaced, with no decoder instance", async () => {
    const img = () => sharp(photo(400, 300, 3), { raw: { width: 400, height: 300, channels: 3 } });
    await resizer.resize(imageFixture("photo.png"), "png");
    await resizer.resize(new Uint8Array(await img().toColourspace("rgb16").png().toBuffer()), "png");
    await resizer.resize(new Uint8Array(await img().png({ progressive: true }).toBuffer()), "png");
    expect(created).toEqual([]);
  });

  it("creates the WebP decoder only for WebP, once", async () => {
    await resizer.resize(imageFixture("photo.webp"), "webp");
    await resizer.resize(imageFixture("photo-alpha.webp"), "webp");
    expect(count()).toEqual({ jpegDec: 0, jpegEnc: 0, webpDec: 1 });
  });
});
