// HeapDecoder: one long-lived emscripten decoder whose pixels are scaled
// straight from its heap. The fake codec below behaves like jSquash's embind
// code: it looks Uint8ClampedArray and ImageData up on globalThis at its first
// decode and keeps them.

import { setFlagsFromString } from "node:v8";
import { runInNewContext } from "node:vm";
import { describe, expect, it } from "vitest";
import sharp, { type Sharp } from "sharp";
import { boxScale } from "../src/boxscale";
import { fitWithin } from "../src/img";
import { ProxyError } from "../src/errors";
import { HeapDecoder, createWasmResizer } from "../src/img-wasm";
import { photo } from "./helpers/png";
import { wasmModules } from "./helpers/wasm";

/** Runs a full garbage collection (vitest gives no --expose-gc) and lets weak references clear. */
async function collectGarbage(): Promise<void> {
  setFlagsFromString("--expose-gc");
  const gc = runInNewContext("gc") as () => void;
  for (let i = 0; i < 3; i++) {
    await new Promise((r) => setTimeout(r, 0));
    gc();
  }
}

const EMPTY = new WebAssembly.Module(Uint8Array.of(0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00));
type Ctor = new (...args: unknown[]) => { length?: number };

/** A fake emscripten decoder factory; `image()` gives the pixels each decode returns as a view. */
function fakeCodec(image: () => { view: Uint8Array; width: number; height: number }) {
  const seen = { instances: 0, boundArray: undefined as Ctor | undefined, returnedArray: undefined as { length?: number } | undefined };
  const factory = async () => {
    seen.instances++;
    let U8C: Ctor | undefined;
    let ID: Ctor | undefined;
    return {
      decode(_bytes: Uint8Array) {
        const g = globalThis as unknown as Record<string, Ctor>;
        U8C ??= g.Uint8ClampedArray;
        ID ??= g.ImageData;
        seen.boundArray = U8C;
        const { view, width, height } = image();
        const array = new U8C(view);
        seen.returnedArray = array;
        return new ID(array, width, height);
      },
    };
  };
  return { factory, seen };
}

const pixels = (width: number, height: number) => ({ view: Uint8Array.from(photo(width, height, 4)), width, height });

describe("HeapDecoder", () => {
  it("scales the pixels straight from the decoder's view, without copying them", async () => {
    const img = pixels(800, 600);
    const { factory, seen } = fakeCodec(() => img);
    const out = await new HeapDecoder(factory, EMPTY).decode(new Uint8Array(1), { width: 800, height: 600 });
    expect(out).toEqual(boxScale(img.view, 800, 600, fitWithin(800, 600)));
    expect(seen.boundArray).not.toBe(Uint8ClampedArray);
    expect(seen.returnedArray?.length).toBe(0); // no full-size copy came back
  });

  it("restores Uint8ClampedArray and ImageData after the first decode", async () => {
    const before = [globalThis.Uint8ClampedArray, (globalThis as { ImageData?: unknown }).ImageData];
    await new HeapDecoder(fakeCodec(() => pixels(10, 10)).factory, EMPTY).decode(new Uint8Array(1), { width: 10, height: 10 });
    expect([globalThis.Uint8ClampedArray, (globalThis as { ImageData?: unknown }).ImageData]).toEqual(before);
  });

  it("restores them when the first decode throws", async () => {
    const before = globalThis.Uint8ClampedArray;
    const decoder = new HeapDecoder(
      fakeCodec(() => {
        throw new Error("abort");
      }).factory,
      EMPTY,
    );
    await expect(decoder.decode(new Uint8Array(1), { width: 10, height: 10 })).rejects.toThrow("abort");
    expect(globalThis.Uint8ClampedArray).toBe(before);
  });

  it("keeps using the one instance", async () => {
    const { factory, seen } = fakeCodec(() => pixels(64, 48));
    const decoder = new HeapDecoder(factory, EMPTY);
    for (let i = 0; i < 3; i++) await decoder.decode(new Uint8Array(1), { width: 64, height: 48 });
    expect(seen.instances).toBe(1);
  });

  it("copies and scales the pixels if they are not the size the header gave", async () => {
    const img = pixels(30, 20);
    const out = await new HeapDecoder(fakeCodec(() => img).factory, EMPTY).decode(new Uint8Array(1), { width: 31, height: 20 });
    expect(out).toEqual(boxScale(img.view, 30, 20, fitWithin(30, 20)));
  });

  it("keeps an instance that returned no image (a clean refusal, as libwebp gives on a bad file)", async () => {
    let refuse = true;
    const { factory, seen } = fakeCodec(() => pixels(10, 10));
    const decoder = new HeapDecoder(async () => {
      const codec = (await factory()) as { decode(b: Uint8Array): unknown };
      return { decode: (b: Uint8Array) => (refuse ? null : codec.decode(b)) };
    }, EMPTY);
    await expect(decoder.decode(new Uint8Array(1), { width: 10, height: 10 })).rejects.toThrow("Decoding error");
    refuse = false;
    const out = await decoder.decode(new Uint8Array(1), { width: 10, height: 10 });
    expect(seen.instances).toBe(1);
    // An instance that has not yet looked the constructors up is bound at its next decode.
    expect(seen.boundArray).not.toBe(Uint8ClampedArray);
    expect(out).toEqual(boxScale(pixels(10, 10).view, 10, 10, { width: 10, height: 10 }));
  });

  it("restores Uint8ClampedArray when putting the stand-ins in place fails", async () => {
    const before = globalThis.Uint8ClampedArray;
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, "ImageData");
    Object.defineProperty(globalThis, "ImageData", { value: undefined, writable: false, configurable: true });
    try {
      await expect(new HeapDecoder(fakeCodec(() => pixels(10, 10)).factory, EMPTY).decode(new Uint8Array(1), { width: 10, height: 10 })).rejects.toThrow();
      expect(globalThis.Uint8ClampedArray).toBe(before);
    } finally {
      if (descriptor) Object.defineProperty(globalThis, "ImageData", descriptor);
      else delete (globalThis as { ImageData?: unknown }).ImageData;
    }
  });

  it("refuses with 503 while two dropped instances are uncollected, and decodes again once they are collected", async () => {
    let fail = true;
    const { factory, seen } = fakeCodec(() => {
      // What mozjpeg throws when it calls exit(): emscripten's ExitStatus, which carries no stack.
      if (fail) throw { name: "ExitStatus", message: "Program terminated with exit(1)", status: 1 };
      return pixels(10, 10);
    });
    const decoder = new HeapDecoder(factory, EMPTY);
    for (let i = 0; i < 2; i++) await expect(decoder.decode(new Uint8Array(1), { width: 10, height: 10 })).rejects.toMatchObject({ status: 1 });
    fail = false;
    const busy = await decoder.decode(new Uint8Array(1), { width: 10, height: 10 }).catch((e: unknown) => e);
    expect(busy).toBeInstanceOf(ProxyError);
    expect((busy as ProxyError).status).toBe(503);
    expect(seen.instances).toBe(2); // no third instance while two are uncollected
    await collectGarbage();
    await decoder.decode(new Uint8Array(1), { width: 10, height: 10 });
    expect(seen.instances).toBe(3);
  });

  it("drops an instance whose decode failed, and makes a new one for the next image", async () => {
    let fail = true;
    const { factory, seen } = fakeCodec(() => {
      if (fail) throw new Error("abort");
      return pixels(10, 10);
    });
    const decoder = new HeapDecoder(factory, EMPTY);
    await expect(decoder.decode(new Uint8Array(1), { width: 10, height: 10 })).rejects.toThrow();
    fail = false;
    await decoder.decode(new Uint8Array(1), { width: 10, height: 10 });
    await decoder.decode(new Uint8Array(1), { width: 10, height: 10 });
    expect(seen.instances).toBe(2);
  });
});

describe("the real decoders", () => {
  /** Runs `fn` with globalThis.Uint8ClampedArray counting the arrays of 1 MiB or more made through it. */
  async function bigArraysDuring(fn: () => Promise<unknown>): Promise<number> {
    const Real = Uint8ClampedArray;
    let big = 0;
    // A Proxy, not a subclass, so instanceof checks (embind makes some) still see the real class.
    globalThis.Uint8ClampedArray = new Proxy(Real, {
      construct(target, args, newTarget) {
        const array = Reflect.construct(target, args, newTarget) as Uint8ClampedArray;
        if (array.length >= 1024 * 1024) big++;
        return array;
      },
    });
    try {
      await fn();
    } finally {
      globalThis.Uint8ClampedArray = Real;
    }
    return big;
  }

  it.each([
    ["an 8 MP JPEG", "jpeg", (img: Sharp) => img.jpeg()],
    ["a 2 MP WebP", "webp", (img: Sharp) => img.webp()],
  ] as const)("make no full-size copy of %s's pixels", async (_name, type, encode) => {
    const [w, h] = type === "jpeg" ? [3264, 2448] : [1632, 1224];
    const bytes = new Uint8Array(await encode(sharp(photo(w, h, 3), { raw: { width: w, height: h, channels: 3 } })).toBuffer());
    const resizer = createWasmResizer(wasmModules());
    await resizer.resize(bytes, type); // instantiates the codecs
    expect(await bigArraysDuring(() => resizer.resize(bytes, type))).toBe(0);
  });
});
