import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { WASM_MAX_PIXELS, createWasmResizer } from "../src/img-wasm";
import { resizerContract } from "./helpers/resizer-contract";

const mod = (path: string) => new WebAssembly.Module(readFileSync(new URL(`../node_modules/${path}`, import.meta.url)));
const make = () =>
  createWasmResizer({
    jpegDec: mod("@jsquash/jpeg/codec/dec/mozjpeg_dec.wasm"),
    jpegEnc: mod("@jsquash/jpeg/codec/enc/mozjpeg_enc.wasm"),
    pngDec: mod("@jsquash/png/codec/pkg/squoosh_png_bg.wasm"),
    webpDec: mod("@jsquash/webp/codec/dec/webp_dec.wasm"),
  });

resizerContract("wasm", async () => make());

/** A one-frame GIF: logical screen `sw`x`sh`, frame `fw`x`fh` at (x, y), one black pixel of image data. */
function gif(sw: number, sh: number, fw: number, fh: number, x = 0, y = 0): Uint8Array {
  const u16 = (n: number) => [n & 0xff, n >> 8];
  return Uint8Array.from([
    0x47, 0x49, 0x46, 0x38, 0x39, 0x61, // GIF89a
    ...u16(sw), ...u16(sh), 0x80, 0, 0, // global palette of 2 colours
    0, 0, 0, 255, 255, 255,
    0x2c, ...u16(x), ...u16(y), ...u16(fw), ...u16(fh), 0, // image descriptor
    0x02, 0x02, 0x44, 0x01, 0x00, // LZW: clear, 0, end
    0x3b,
  ]);
}

describe("wasm resizer GIF guard", () => {
  const resizer = make();

  it("decodes the hand-made GIF when its frame fits the screen", async () => {
    await expect(resizer.resize(gif(1, 1, 1, 1), "gif")).resolves.toBeInstanceOf(Uint8Array);
  });

  it.each([
    ["a 12000x12000 frame on a 1x1 screen", gif(1, 1, 12000, 12000)],
    ["a frame that runs off the right of the screen", gif(10, 10, 10, 10, 5, 0)],
    ["a frame that runs off the bottom of the screen", gif(10, 10, 10, 10, 0, 5)],
    ["a screen over WASM_MAX_PIXELS", gif(WASM_MAX_PIXELS / 1000 + 1, 1000, 1, 1)],
  ])("refuses %s before decoding", async (_name, bytes) => {
    await expect(resizer.resize(bytes, "gif")).rejects.toThrow();
  });
});
