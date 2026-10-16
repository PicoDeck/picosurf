// Which decoder the WASM resizer picks, seen through pass-through spies.
// vi.mock is per file, so these live apart from img-wasm.test.ts.

import { beforeEach, describe, expect, it, vi } from "vitest";
import sharp from "sharp";
import { createWasmResizer } from "../src/img-wasm";
import { jpegInfo } from "../src/imgsize";
import { streamPng } from "../src/png-stream";
import { encodePng, photo } from "./helpers/png";
import { imageFixture } from "./helpers/resizer-contract";
import { wasmModules } from "./helpers/wasm";

/** How many streamPng calls are running now, and the most at once. */
const flight = vi.hoisted(() => ({ now: 0, most: 0 }));
vi.mock("../src/png-stream", async (importOriginal) => {
  const orig = await importOriginal<typeof import("../src/png-stream")>();
  const streamPng = async (...args: Parameters<typeof orig.streamPng>) => {
    flight.most = Math.max(flight.most, ++flight.now);
    try {
      return await orig.streamPng(...args);
    } finally {
      flight.now--;
    }
  };
  return { ...orig, streamPng: vi.fn(streamPng) };
});

const resizer = createWasmResizer(wasmModules());

beforeEach(() => {
  vi.mocked(streamPng).mockClear();
});

describe("wasm resizer decoder choice", () => {
  it.each(["photo.png", "small.png"])("streams %s", async (file) => {
    expect(jpegInfo(await resizer.resize(imageFixture(file), "png"))?.sof).toBe(0xc0);
    expect(streamPng).toHaveBeenCalledTimes(1);
  });

  it("streams a 16-bit PNG too", async () => {
    const png = await sharp(photo(400, 300, 3), { raw: { width: 400, height: 300, channels: 3 } }).toColourspace("rgb16").png().toBuffer();
    await resizer.resize(new Uint8Array(png), "png");
    expect(streamPng).toHaveBeenCalledTimes(1);
  });
});

describe("wasm resizer jobs", () => {
  it("runs two concurrent resizes one after the other", async () => {
    // Big enough that inflating takes many reads, so unserialised jobs would interleave.
    const png = encodePng({ width: 2000, height: 1500, colorType: 2, pixels: photo(2000, 1500, 3) });
    flight.most = 0;
    const [a, b] = await Promise.all([resizer.resize(png, "png"), resizer.resize(png, "png")]);
    expect(jpegInfo(a)?.size).toEqual({ width: 320, height: 240 });
    expect(b).toEqual(a);
    expect(streamPng).toHaveBeenCalledTimes(2);
    expect(flight.most).toBe(1);
  });
});
