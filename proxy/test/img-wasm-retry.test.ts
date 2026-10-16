// A codec whose instantiation fails is tried again for the next image rather
// than failing the isolate for good. Codec state is per process, so this file
// runs on its own (vitest isolates files), and order matters within it.

import { describe, expect, it } from "vitest";
import sharp from "sharp";
import { createWasmResizer } from "../src/img-wasm";
import { jpegInfo } from "../src/imgsize";
import { photo } from "./helpers/png";
import { imageFixture } from "./helpers/resizer-contract";
import { wasmModules } from "./helpers/wasm";

/** A module importing x.y, which no codec's imports provide: instantiating it throws a LinkError. */
const UNLINKABLE = new WebAssembly.Module(
  Uint8Array.of(0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x04, 0x01, 0x60, 0x00, 0x00, 0x02, 0x07, 0x01, 0x01, 0x78, 0x01, 0x79, 0x00, 0x00),
);

let attempts = 0;
const RealInstance = WebAssembly.Instance;
WebAssembly.Instance = new Proxy(RealInstance, {
  construct(target, args: ConstructorParameters<typeof WebAssembly.Instance>) {
    if (args[0] === UNLINKABLE) attempts++;
    return new target(...args);
  },
});
const realInstantiate = WebAssembly.instantiate.bind(WebAssembly);
WebAssembly.instantiate = ((source: unknown, imports?: WebAssembly.Imports) => {
  if (source === UNLINKABLE) attempts++;
  return realInstantiate(source as WebAssembly.Module, imports);
}) as typeof WebAssembly.instantiate;

describe("a codec that fails to instantiate", () => {
  it("is the WASM PNG decoder, tried again, and a working one then decodes", async () => {
    const png = new Uint8Array(await sharp(photo(80, 60, 3), { raw: { width: 80, height: 60, channels: 3 } }).png({ progressive: true }).toBuffer());
    const broken = createWasmResizer({ ...wasmModules(), pngDec: UNLINKABLE });
    attempts = 0;
    await expect(broken.resize(png, "png")).rejects.toThrow();
    await expect(broken.resize(png, "png")).rejects.toThrow();
    expect(attempts).toBe(2);
    const out = await createWasmResizer(wasmModules()).resize(png, "png");
    expect(jpegInfo(out)?.size).toEqual({ width: 80, height: 60 });
  });

  it("is the JPEG encoder, tried again for the next image", async () => {
    const broken = createWasmResizer({ ...wasmModules(), jpegEnc: UNLINKABLE });
    attempts = 0;
    await expect(broken.resize(imageFixture("photo.jpg"), "jpeg")).rejects.toThrow();
    await expect(broken.resize(imageFixture("photo.jpg"), "jpeg")).rejects.toThrow();
    expect(attempts).toBe(2);
    expect(jpegInfo(await createWasmResizer(wasmModules()).resize(imageFixture("photo.jpg"), "jpeg"))?.sof).toBe(0xc0);
  });
});
