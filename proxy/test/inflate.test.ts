import { constants, deflateRawSync, deflateSync, inflateRawSync } from "node:zlib";
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

/** inflate()'s result for a raw deflate stream (given a zlib header): the output, or "error". */
function mine(raw: Uint8Array): Uint8Array | "error" {
  try {
    return run(whole(Uint8Array.from([0x78, 0x9c, ...raw]))).out;
  } catch {
    return "error";
  }
}

/** zlib's: the output, or "error". */
function theirs(raw: Uint8Array): Uint8Array | "error" {
  try {
    return new Uint8Array(inflateRawSync(raw));
  } catch {
    return "error";
  }
}

/** Writes deflate's bit fields (LSB first) and Huffman codes (MSB first). */
class Bits {
  private readonly out: number[] = [];
  private acc = 0;
  private n = 0;
  field(value: number, width: number): this {
    for (let b = 0; b < width; b++) this.bit((value >> b) & 1);
    return this;
  }
  code(code: number, length: number): this {
    for (let b = length - 1; b >= 0; b--) this.bit((code >> b) & 1);
    return this;
  }
  private bit(v: number): void {
    this.acc |= v << this.n;
    if (++this.n === 8) {
      this.out.push(this.acc);
      this.acc = this.n = 0;
    }
  }
  bytes(): Uint8Array {
    return Uint8Array.from(this.n ? [...this.out, this.acc] : this.out);
  }
}

const CL_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

/**
 * A final dynamic block. `cl` gives the code-length code (symbol -> length),
 * `lengths` the literal/length lengths then the distance lengths (written with
 * code-length symbols 0-15 and 18 for runs of zeros), `data` the codes after.
 */
function dynamic(cl: Record<number, number>, lit: Record<number, number>, ndist: number, dist: Record<number, number>, data: (w: Bits, lit: Map<number, [number, number]>) => void): Uint8Array {
  const canonical = (lens: Record<number, number>) => {
    const syms = Object.entries(lens).map(([s, l]) => [Number(s), l] as const).filter(([, l]) => l > 0).sort((a, b) => a[1] - b[1] || a[0] - b[0]);
    const codes = new Map<number, [number, number]>();
    let code = 0;
    let len = 0;
    for (const [s, l] of syms) {
      code <<= l - len;
      len = l;
      codes.set(s, [code++, l]);
    }
    return codes;
  };
  const w = new Bits().field(1, 1).field(2, 2).field(0, 5).field(ndist - 1, 5).field(15, 4);
  for (const s of CL_ORDER) w.field(cl[s] ?? 0, 3);
  const clCodes = canonical(cl);
  const sym = (s: number) => {
    const c = clCodes.get(s);
    if (!c) throw new Error(`no code-length code for ${s}`);
    w.code(c[0], c[1]);
  };
  const all = [...Array.from({ length: 257 }, (_, i) => lit[i] ?? 0), ...Array.from({ length: ndist }, (_, i) => dist[i] ?? 0)];
  for (let i = 0; i < all.length; ) {
    let run = 0;
    while (all[i + run] === 0 && run < 138 && i + run < all.length) run++;
    if (run >= 11) {
      sym(18);
      w.field(run - 11, 7);
      i += run;
    } else {
      sym(all[i]);
      i++;
    }
  }
  data(w, canonical(lit));
  return w.bytes();
}

const A_THEN_END = (w: Bits, lit: Map<number, [number, number]>) => {
  for (const s of [65, 256]) {
    const c = lit.get(s);
    if (c) w.code(c[0], c[1]);
  }
};

describe("Huffman codes, as zlib takes them", () => {
  it.each([
    ["an incomplete literal/length code", dynamic({ 0: 2, 1: 2, 2: 2, 18: 2 }, { 65: 2, 256: 2 }, 1, { 0: 1 }, A_THEN_END), "error"],
    ["an incomplete code-length code", dynamic({ 0: 2, 1: 2, 18: 2 }, { 65: 1, 256: 1 }, 1, { 0: 1 }, A_THEN_END), "error"],
    ["a single distance code of length 1 (incomplete, as zlib allows)", dynamic({ 18: 1, 0: 2, 1: 2 }, { 65: 1, 256: 1 }, 1, { 0: 1 }, A_THEN_END), "A"],
    ["no distance codes at all, in a block with no matches", dynamic({ 18: 1, 0: 2, 1: 2 }, { 65: 1, 256: 1 }, 1, {}, A_THEN_END), "A"],
  ])("%s", (_name, raw, expected) => {
    const want = expected === "error" ? "error" : new TextEncoder().encode(expected);
    expect(theirs(raw)).toEqual(want);
    expect(mine(raw)).toEqual(want);
  });
});

describe("inflate against zlib", () => {
  it("agrees on 6000 seeded streams, intact and corrupted: the same bytes, or both refuse", () => {
    let s = 2026;
    const rand = () => {
      s ^= s << 13;
      s ^= s >>> 17;
      s ^= s << 5;
      return (s >>> 0) / 2 ** 32;
    };
    const ri = (n: number) => Math.floor(rand() * n);
    const data = (): Uint8Array => {
      const n = [0, 1, 7, 100, 600, 2500][ri(6)] + ri(100);
      const out = new Uint8Array(n);
      const kind = ri(5);
      for (let i = 0; i < n; ) {
        if (kind === 0) out[i++] = ri(256);
        else if (kind === 1) out[i++] = 97 + ri(3);
        else if (kind === 2) for (let v = ri(256), r = 1 + ri(300); r > 0 && i < n; r--) out[i++] = v;
        else if (kind === 3 && i > 4 && rand() < 0.4) for (let back = 1 + ri(i), r = 3 + ri(258); r > 0 && i < n; r--, i++) out[i] = out[i - back];
        else out[i++] = (i * 7 + ri(4)) & 0xff;
      }
      return out;
    };
    const mutate = (raw: Uint8Array): Uint8Array => {
      const m = raw.slice();
      switch (ri(6)) {
        case 0:
        case 1:
          return m;
        case 2:
          for (let k = 1 + ri(3); k > 0 && m.length; k--) m[ri(m.length)] ^= 1 << ri(8);
          return m;
        case 3:
          return m.subarray(0, ri(m.length + 1));
        case 4:
          for (let at = ri(m.length + 1), k = 1 + ri(8); k > 0 && at < m.length; k--, at++) m[at] = ri(256);
          return m;
        default:
          return Uint8Array.from([...m, ...Array.from({ length: 1 + ri(20) }, () => ri(256))]);
      }
    };
    const disagreements: string[] = [];
    let refused = 0;
    for (let k = 0; k < 6000; k++) {
      const options = { level: ri(10), strategy: ri(5), memLevel: 1 + ri(9) };
      const raw = mutate(new Uint8Array(deflateRawSync(data(), options)));
      const [a, b] = [mine(raw), theirs(raw)];
      if (b === "error") refused++;
      const same = a === "error" || b === "error" ? a === b : a.length === b.length && a.every((v, i) => v === b[i]);
      if (!same) disagreements.push(`#${k}: inflate ${a === "error" ? a : `${a.length} bytes`}, zlib ${b === "error" ? b : `${b.length} bytes`}`);
    }
    expect(disagreements).toEqual([]);
    expect(refused).toBeGreaterThan(600); // the corruption did reach the error paths
  });
});

