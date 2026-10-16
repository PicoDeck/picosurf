import { constants, deflateRawSync, deflateSync } from "node:zlib";
import { describe, expect, it } from "vitest";
import { INFLATE_FLUSH, inflate } from "../src/inflate";

/** Deterministic pseudo-random bytes. */
function noise(n: number, seed = 1): Uint8Array {
  let s = seed >>> 0;
  return Uint8Array.from({ length: n }, () => {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    return s >>> 24;
  });
}

/** Text-like data with repeats near and far (up to the 32 KiB window). */
function texty(n: number): Uint8Array {
  const words = ["image ", "proxy ", "deflate ", "window ", "row ", "PicoDeck ", "the ", "a "];
  const out = new Uint8Array(n);
  const r = noise(n, 7);
  for (let i = 0; i < n; ) {
    if (i > 40_000 && r[i] < 40) {
      const back = 1 + ((r[i] << 7) % 32_000);
      const len = Math.min(3 + (r[i + 1] ?? 0), n - i);
      out.set(out.subarray(i - back, i - back + len), i);
      i += len;
    } else for (const c of words[r[i] & 7]) if (i < n) out[i++] = c.charCodeAt(0);
  }
  return out;
}

/** Splits `z` into segments of the given sizes, cycling; 0 makes empty segments. */
function segments(z: Uint8Array, sizes: number[]): () => Uint8Array | null {
  let at = 0;
  let k = 0;
  return () => {
    if (at >= z.length) return null;
    const n = sizes[k++ % sizes.length];
    const seg = z.subarray(at, at + n);
    at += n;
    return seg;
  };
}

/** Inflates everything into one array; `stopAt` makes the sink stop once it has that much. */
function run(next: () => Uint8Array | null, stopAt = Infinity): { out: Uint8Array; delivered: number; calls: number } {
  const parts: Uint8Array[] = [];
  let delivered = 0;
  let calls = 0;
  inflate(next, (window, from, to) => {
    calls++;
    if (to - from > INFLATE_FLUSH + 258) throw new Error(`one delivery of ${to - from} bytes`);
    parts.push(window.slice(from, to));
    delivered += to - from;
    return delivered >= stopAt;
  });
  const out = new Uint8Array(delivered);
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return { out, delivered, calls };
}

const whole = (z: Uint8Array) => segments(z, [z.length]);

describe("inflate", () => {
  const inputs: [string, Uint8Array][] = [
    ["empty", new Uint8Array(0)],
    ["one byte", Uint8Array.of(42)],
    ["noise, 200 KB", noise(200_000)],
    ["text with far repeats, 300 KB", texty(300_000)],
    ["zeros, 1 MB", new Uint8Array(1_000_000)],
  ];
  const settings: [string, object][] = [
    ["level 0 (stored blocks)", { level: 0 }],
    ["level 1", { level: 1 }],
    ["level 9", { level: 9 }],
    ["fixed Huffman codes", { strategy: constants.Z_FIXED }],
    ["Huffman only", { strategy: constants.Z_HUFFMAN_ONLY }],
    ["run-length", { strategy: constants.Z_RLE }],
  ];
  for (const [name, data] of inputs) {
    it.each(settings)(`matches zlib on ${name}, %s`, (_s, options) => {
      const z = new Uint8Array(deflateSync(data, options));
      expect(run(whole(z)).out).toEqual(data);
    });
  }

  it.each([[[1]], [[0, 1, 0, 3]], [[7, 4096, 13]], [[65_536]]])("matches zlib with the input in segments of %j bytes", (sizes) => {
    const data = texty(150_000);
    const z = new Uint8Array(deflateSync(data));
    expect(run(segments(z, sizes)).out).toEqual(data);
  });

  it("hands output over in stretches of at most INFLATE_FLUSH plus one match", () => {
    const data = new Uint8Array(1_000_000);
    const { calls } = run(whole(new Uint8Array(deflateSync(data))));
    expect(calls).toBeGreaterThanOrEqual(1_000_000 / (INFLATE_FLUSH + 258));
  });

  it("stops once the sink has enough, within one stretch: 1000x1000 RGB rows from 200 MiB of zeros", () => {
    const z = new Uint8Array(deflateSync(new Uint8Array(200 * 1024 * 1024), { level: 9 }));
    const wanted = 1000 * (1000 * 3 + 1);
    const { out, delivered } = run(whole(z), wanted);
    expect(delivered).toBeGreaterThanOrEqual(wanted);
    expect(delivered).toBeLessThan(wanted + INFLATE_FLUSH + 258);
    expect(out.every((v) => v === 0)).toBe(true);
  });

  it.each([
    ["a bad Adler-32", (z: Uint8Array) => Uint8Array.from(z, (v, i) => (i === z.length - 1 ? v ^ 0xff : v))],
    ["no Adler-32", (z: Uint8Array) => z.subarray(0, -4)],
    ["bytes after the stream", (z: Uint8Array) => Uint8Array.from([...z, ...new Uint8Array(1000).fill(0xab)])],
  ])("ignores %s, as libpng does", (_name, change) => {
    const data = texty(50_000);
    expect(run(whole(change(new Uint8Array(deflateSync(data))))).out).toEqual(data);
  });

  /** Writes bits LSB first, as deflate does. */
  function bits(fields: [value: number, width: number][]): Uint8Array {
    const out: number[] = [];
    let acc = 0;
    let n = 0;
    for (const [value, width] of fields) {
      for (let b = 0; b < width; b++) {
        acc |= ((value >> b) & 1) << n;
        if (++n === 8) {
          out.push(acc);
          acc = n = 0;
        }
      }
    }
    if (n) out.push(acc);
    return Uint8Array.from(out);
  }
  const zlib = (raw: Uint8Array) => Uint8Array.from([0x78, 0x9c, ...raw]);

  it.each([
    ["a compression method other than deflate", Uint8Array.of(0x79, 0x9c, 3, 0)],
    ["a header check that fails", Uint8Array.of(0x78, 0x9d, 3, 0)],
    ["a preset dictionary", new Uint8Array(deflateSync(texty(1000), { dictionary: texty(500) }))],
    ["block type 3", zlib(bits([[1, 1], [3, 2]]))],
    ["a stored block whose length check fails", zlib(Uint8Array.of(1, 5, 0, 0, 0, 1, 2, 3, 4, 5))],
    ["an over-subscribed code", zlib(bits([[1, 1], [2, 2], [0, 5], [0, 5], [15, 4], ...Array.from({ length: 19 }, (): [number, number] => [1, 3])]))],
    ["a distance before the start", zlib(new Uint8Array(deflateRawSync(texty(1000), { dictionary: texty(1000) })))],
    ["input that ends inside a block", new Uint8Array(deflateSync(texty(50_000))).subarray(0, 2000)],
    ["no input after the header", Uint8Array.of(0x78, 0x9c)],
    ["no input at all", new Uint8Array(0)],
  ])("refuses %s", (_name, z) => {
    expect(() => run(whole(z))).toThrow();
  });

  it("always ends on corrupt input: it throws or finishes, and never runs on", () => {
    const data = texty(60_000);
    const z = new Uint8Array(deflateSync(data));
    const r = noise(2000, 3);
    for (let k = 0; k < 500; k++) {
      const bad = z.slice();
      for (let j = 0; j < 1 + (r[k] & 3); j++) bad[2 + ((r[(k * 7 + j) % r.length] * 251 + k * 31) % (bad.length - 2))] ^= 1 << (k & 7);
      try {
        run(whole(bad), 10_000_000);
      } catch {
        // corrupt data may throw; it must not hang or run past the sink
      }
    }
  });
});
