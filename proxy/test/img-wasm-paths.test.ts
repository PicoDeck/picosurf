// Which decoder the WASM resizer picks, seen through pass-through spies.
// vi.mock is per file, so these live apart from img-wasm.test.ts.

import { beforeEach, describe, expect, it, vi } from "vitest";
import sharp from "sharp";
import decodePng from "@jsquash/png/decode";
import { createWasmResizer } from "../src/img-wasm";
import { jpegInfo } from "../src/imgsize";
import { streamPng } from "../src/png-stream";
import { photo } from "./helpers/png";
import { imageFixture } from "./helpers/resizer-contract";
import { wasmModules } from "./helpers/wasm";

vi.mock("@jsquash/png/decode", async (importOriginal) => {
  const orig = await importOriginal<typeof import("@jsquash/png/decode")>();
  return { ...orig, default: vi.fn(orig.default) };
});
vi.mock("../src/png-stream", async (importOriginal) => {
  const orig = await importOriginal<typeof import("../src/png-stream")>();
  return { ...orig, streamPng: vi.fn(orig.streamPng) };
});

const resizer = createWasmResizer(wasmModules());

beforeEach(() => {
  vi.mocked(decodePng).mockClear();
  vi.mocked(streamPng).mockClear();
});

describe("wasm resizer decoder choice", () => {
  it.each(["photo.png", "small.png"])("streams the 8-bit %s and never calls the WASM PNG decoder", async (file) => {
    expect(jpegInfo(await resizer.resize(imageFixture(file), "png"))?.sof).toBe(0xc0);
    expect(streamPng).toHaveBeenCalledTimes(1);
    expect(decodePng).not.toHaveBeenCalled();
  });

  it("sends a 16-bit PNG to the WASM PNG decoder", async () => {
    const png = await sharp(photo(400, 300, 3), { raw: { width: 400, height: 300, channels: 3 } }).toColourspace("rgb16").png().toBuffer();
    await resizer.resize(new Uint8Array(png), "png");
    expect(decodePng).toHaveBeenCalledTimes(1);
    expect(streamPng).not.toHaveBeenCalled();
  });
});
