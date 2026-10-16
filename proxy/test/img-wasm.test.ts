import { describe, expect, it } from "vitest";
import sharp, { type Sharp } from "sharp";
import { handleRequest } from "../src/handler";
import { WASM_MAX_PIXELS, createWasmResizer } from "../src/img-wasm";
import { jpegInfo } from "../src/imgsize";
import { canStreamPng } from "../src/png-stream";
import { fakeFetch } from "./helpers/fakefetch";
import { encodePng, photo } from "./helpers/png";
import { resizerContract } from "./helpers/resizer-contract";
import { wasmModules } from "./helpers/wasm";

const make = () => createWasmResizer(wasmModules());

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

const jpegSize = (bytes: Uint8Array) => jpegInfo(bytes)?.size;

describe("wasm resizer PNG paths", () => {
  it.each([
    ["16-bit", (img: Sharp) => img.toColourspace("rgb16").png()],
    ["interlaced", (img: Sharp) => img.png({ progressive: true })],
    ["4-bit palette", (img: Sharp) => img.png({ palette: true, colours: 16 })],
  ])("decodes a %s PNG with the WASM decoder", async (_name, encode) => {
    const png = new Uint8Array(await encode(sharp(photo(800, 600, 3), { raw: { width: 800, height: 600, channels: 3 } })).toBuffer());
    expect(canStreamPng(png)).toBe(false);
    expect(jpegSize(await make().resize(png, "png"))).toEqual({ width: 320, height: 240 });
  });

  it("answers 415 for a truncated PNG, as before streaming", async () => {
    const p = { width: 800, height: 600, colorType: 2 as const, pixels: photo(800, 600, 3) };
    const png = encodePng(p);
    const cut = png.slice(0, Math.floor(png.length * 0.6));
    const res = await handleRequest(
      new Request(`https://proxy.example/v1/get?url=${encodeURIComponent("https://example.com/a.png")}`, { headers: { Authorization: "Bearer t" } }),
      { PROXY_TOKEN: "t" },
      { fetch: fakeFetch({ "https://example.com/a.png": new Response(cut, { headers: { "Content-Type": "image/png" } }) }), resizer: make() },
    );
    expect(res.status).toBe(415);
    expect(await res.text()).toBe("Could not decode the image\n");
  });
});
