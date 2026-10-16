import { describe, expect, it } from "vitest";
import sharp, { type JpegOptions, type Sharp } from "sharp";
import { handleRequest } from "../src/handler";
import { JPEG_HEAP_MAX, JPEG_MAX_PIXELS, PNG_STREAM_MAX_PIXELS, WASM_MAX_PIXELS, createWasmResizer, jpegMaxPixels } from "../src/img-wasm";
import { jpegInfo } from "../src/imgsize";
import { PNG_MAX_SIDE } from "../src/png-stream";
import { fakeFetch } from "./helpers/fakefetch";
import { SIGNATURE, concat, encodePng, ihdr, photo } from "./helpers/png";
import { imageFixture, resizerContract } from "./helpers/resizer-contract";
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
  ])("resizes a %s PNG", async (_name, encode) => {
    const png = new Uint8Array(await encode(sharp(photo(800, 600, 3), { raw: { width: 800, height: 600, channels: 3 } })).toBuffer());
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

/** GET `url` through the handler with the WASM resizer, the upstream serving `body` as `contentType`. */
function viaHandler(body: Uint8Array, contentType: string): Promise<Response> {
  const url = "https://example.com/image";
  return handleRequest(
    new Request(`https://proxy.example/v1/get?url=${encodeURIComponent(url)}`, { headers: { Authorization: "Bearer t" } }),
    { PROXY_TOKEN: "t" },
    { fetch: fakeFetch({ [url]: new Response(body.slice(), { headers: { "Content-Type": contentType } }) }), resizer: make() },
  );
}

const jpegOf = async (width: number, height: number) =>
  new Uint8Array(await sharp(photo(width, height, 3), { raw: { width, height, channels: 3 } }).jpeg({ quality: 85 }).toBuffer());

describe("jpegMaxPixels", () => {
  const MiB = 1024 * 1024;
  const jpeg = async (options: JpegOptions) =>
    new Uint8Array(await sharp(photo(400, 300, 3), { raw: { width: 400, height: 300, channels: 3 } }).jpeg(options).toBuffer());
  /** The model: the heap holds the input twice, 4 bytes a pixel, and 2 a DCT coefficient when the decode buffers them all; 30% slack for reuse. */
  const model = (bytes: Uint8Array, perPixel: number) => Math.min(JPEG_MAX_PIXELS, Math.floor((JPEG_HEAP_MAX / 1.3 - MiB - 2 * bytes.length) / perPixel));

  it("allows JPEG_MAX_PIXELS for a small baseline JPEG", async () => {
    const b = await jpeg({});
    expect(model(b, 4)).toBe(JPEG_MAX_PIXELS);
    expect(jpegMaxPixels(b)).toBe(JPEG_MAX_PIXELS);
  });

  it.each([
    ["progressive 4:2:0", { progressive: true }, 4 + 2 * 1.5],
    ["progressive 4:4:4", { progressive: true, chromaSubsampling: "4:4:4" }, 4 + 2 * 3],
  ] as const)("allows fewer pixels for a %s JPEG, whose decode keeps every coefficient", async (_name, options, perPixel) => {
    const b = await jpeg(options);
    expect(jpegMaxPixels(b)).toBe(model(b, perPixel));
    expect(jpegMaxPixels(b)).toBeLessThan(JPEG_MAX_PIXELS);
  });

  it("allows fewer pixels for a bigger file, which the heap holds twice", async () => {
    const small = await jpeg({});
    const big = concat(small, new Uint8Array(9 * MiB)); // bytes after the end of the image still go into the heap
    expect(jpegMaxPixels(big)).toBe(model(big, 4));
    expect(jpegMaxPixels(big)).toBeLessThan(JPEG_MAX_PIXELS);
  });
});

describe("wasm resizer pixel caps", () => {
  it("caps each kind of image by how its decoder uses memory", async () => {
    const resizer = make();
    const interlaced = await sharp(photo(50, 40, 3), { raw: { width: 50, height: 40, channels: 3 } }).png({ progressive: true }).toBuffer();
    expect(resizer.maxPixels(imageFixture("photo.jpg"), "jpeg")).toBe(JPEG_MAX_PIXELS);
    expect(resizer.maxPixels(imageFixture("photo-progressive.jpg"), "jpeg")).toBe(jpegMaxPixels(imageFixture("photo-progressive.jpg")));
    expect(resizer.maxPixels(imageFixture("photo.png"), "png")).toBe(PNG_STREAM_MAX_PIXELS);
    expect(resizer.maxPixels(new Uint8Array(interlaced), "png")).toBe(PNG_STREAM_MAX_PIXELS);
    expect(resizer.maxPixels(concat(SIGNATURE, ihdr(PNG_MAX_SIDE + 1, 1, 2)), "png")).toBe(0);
    expect(resizer.maxPixels(imageFixture("photo.webp"), "webp")).toBe(WASM_MAX_PIXELS);
    expect(resizer.maxPixels(imageFixture("photo.gif"), "gif")).toBe(WASM_MAX_PIXELS);
    expect([JPEG_MAX_PIXELS, WASM_MAX_PIXELS, PNG_STREAM_MAX_PIXELS]).toEqual([8_000_000, 2_000_000, 100_000_000]);
  });

  it("resizes an 8-megapixel JPEG", async () => {
    const res = await viaHandler(await jpegOf(4000, 2000), "image/jpeg");
    expect(res.status).toBe(200);
    expect(jpegSize(new Uint8Array(await res.arrayBuffer()))).toEqual({ width: 320, height: 160 });
  });

  it("refuses a 9-megapixel JPEG with 413", async () => {
    const res = await viaHandler(await jpegOf(4000, 2250), "image/jpeg");
    expect(res.status).toBe(413);
    expect(await res.text()).toBe("Image too large (4000x2250)\n");
  });

  it("resizes a 4000x3000 screenshot-like PNG by streaming it", async () => {
    const [width, height] = [4000, 3000];
    const pixels = new Uint8Array(width * height * 3).fill(255);
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) if (y % 40 < 14 && x % 9 < 6) pixels.fill(40, (y * width + x) * 3, (y * width + x) * 3 + 3);
    const png = new Uint8Array(await sharp(pixels, { raw: { width, height, channels: 3 } }).png().toBuffer());
    const res = await viaHandler(png, "image/png");
    expect(res.status).toBe(200);
    expect(jpegSize(new Uint8Array(await res.arrayBuffer()))).toEqual({ width: 320, height: 240 });
  });

  it.each([
    ["a streamable PNG over PNG_STREAM_MAX_PIXELS", concat(SIGNATURE, ihdr(10_001, 10_000, 2)), "10001x10000"],
    ["an interlaced 16-bit PNG over PNG_STREAM_MAX_PIXELS", concat(SIGNATURE, ihdr(10_001, 10_000, 2, 16, 1)), "10001x10000"],
    ["a PNG wider than PNG_MAX_SIDE", concat(SIGNATURE, ihdr(PNG_MAX_SIDE + 1, 1, 2)), "100001x1"],
    ["a PNG taller than PNG_MAX_SIDE", concat(SIGNATURE, ihdr(1, PNG_MAX_SIDE + 1, 0, 1)), "1x100001"],
  ])("refuses %s with 413", async (_name, png, size) => {
    const res = await viaHandler(png, "image/png");
    expect(res.status).toBe(413);
    expect(await res.text()).toBe(`Image too large (${size})\n`);
  });

  it("refuses a WebP over WASM_MAX_PIXELS with 413", async () => {
    const webp = await sharp({ create: { width: 2001, height: 1000, channels: 3, background: "#808080" } }).webp().toBuffer();
    expect((await viaHandler(new Uint8Array(webp), "image/webp")).status).toBe(413);
  });

  it("answers 415 for a CMYK JPEG, and the next JPEG still resizes", async () => {
    const cmyk = await sharp(photo(400, 300, 3), { raw: { width: 400, height: 300, channels: 3 } }).toColourspace("cmyk").jpeg().toBuffer();
    const res = await viaHandler(new Uint8Array(cmyk), "image/jpeg");
    expect(res.status).toBe(415);
    expect(await res.text()).toBe("Could not decode the image\n");
    expect((await viaHandler(imageFixture("photo.jpg"), "image/jpeg")).status).toBe(200);
  });
});
