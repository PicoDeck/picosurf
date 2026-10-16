// Which WASM codec instances the resizer creates, and when. Codec instances
// are per process, so this file must run on its own (vitest isolates files).

import { beforeEach, describe, expect, it } from "vitest";
import sharp from "sharp";
import { createWasmResizer } from "../src/img-wasm";
import { photo } from "./helpers/png";
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
  pngDec: created.filter((m) => m === mods.pngDec).length,
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

  it("gives every JPEG a fresh decoder, and creates the encoder once", async () => {
    await resizer.resize(imageFixture("photo.jpg"), "jpeg");
    await resizer.resize(imageFixture("photo-progressive.jpg"), "jpeg");
    expect(count()).toEqual({ jpegDec: 2, jpegEnc: 1, pngDec: 0, webpDec: 0 });
  });

  it("streams an 8-bit PNG with no decoder instance", async () => {
    await resizer.resize(imageFixture("photo.png"), "png");
    expect(count()).toEqual({ jpegDec: 0, jpegEnc: 0, pngDec: 0, webpDec: 0 });
  });

  it("creates the WebP decoder only for WebP, fresh for each image", async () => {
    await resizer.resize(imageFixture("photo.webp"), "webp");
    await resizer.resize(imageFixture("photo-alpha.webp"), "webp");
    expect(count()).toEqual({ jpegDec: 0, jpegEnc: 0, pngDec: 0, webpDec: 2 });
  });

  it("creates the WASM PNG decoder only for a PNG that cannot stream", async () => {
    const png = await sharp(photo(400, 300, 3), { raw: { width: 400, height: 300, channels: 3 } }).png({ progressive: true }).toBuffer();
    await resizer.resize(new Uint8Array(png), "png");
    await resizer.resize(new Uint8Array(png), "png");
    expect(count()).toEqual({ jpegDec: 0, jpegEnc: 0, pngDec: 1, webpDec: 0 });
  });
});
