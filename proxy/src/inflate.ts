// A zlib (RFC 1950/1951) inflater that allocates nothing as it goes: it
// decodes into a fixed 64 KiB window and hands the output to a sink 16 KiB at
// a time, stopping as soon as the sink has enough. Memory is the window and
// three small code tables, however far the data expands, and the same on
// every runtime: nothing is left for the garbage collector.
//
// Written for png-stream.ts, which has the whole compressed stream in memory,
// so input is pulled a segment at a time and never needs to be resumed.
// Neither DecompressionStream (workerd inflates each write in full, with no
// backpressure) nor fflate (a fresh output buffer and a 32 KiB window copy per
// push, left to the garbage collector) keeps memory to the window.
//
// Like libpng it never reads the Adler-32 or anything after the final block.

/** Output is handed to the sink in stretches of at most this much (plus one match). */
export const INFLATE_FLUSH = 16 * 1024;

const WSIZE = 1 << 16; // twice the deflate window, so unflushed output is never overwritten
const WMASK = WSIZE - 1;
/** Codes up to this long decode with one table lookup; longer ones (rare by construction) walk the canonical code. */
const ROOT = 10;
const MAXBITS = 15;

const LBASE = Uint16Array.of(3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258);
const LEXT = Uint8Array.of(0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0);
const DBASE = Uint16Array.of(
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
);
const DEXT = Uint8Array.of(0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13);
/** The order code length code lengths are sent in. */
const CLORDER = Uint8Array.of(16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15);

/** Bit-reversed bytes. */
const REV8 = Uint8Array.from({ length: 256 }, (_, i) => {
  let r = 0;
  for (let b = 0; b < 8; b++) r |= ((i >> b) & 1) << (7 - b);
  return r;
});

/** A canonical Huffman code: a lookup table for codes up to ROOT bits, and the counts and sorted symbols for the rest. */
class Code {
  /** symbol << 4 | length, indexed by the next ROOT input bits; 0 for longer or unused codes. */
  readonly root = new Uint16Array(1 << ROOT);
  readonly count = new Uint16Array(MAXBITS + 1);
  readonly symbols: Uint16Array;
  private readonly offsets = new Uint16Array(MAXBITS + 2);

  constructor(size: number) {
    this.symbols = new Uint16Array(size);
  }

  /**
   * Builds the code from `n` code lengths starting at `lengths[at]`, refusing
   * what zlib refuses: an over-subscribed code, or an incomplete one, except a
   * literal/length or distance code of one 1-bit code (`single` allows it).
   * A code with no codes at all builds, and fails only if a block uses it.
   */
  build(lengths: Uint8Array, at: number, n: number, single = true): void {
    const { root, count, symbols, offsets } = this;
    count.fill(0);
    for (let i = 0; i < n; i++) count[lengths[at + i]]++;
    count[0] = 0;
    let left = 1;
    let longest = 0;
    for (let len = 1; len <= MAXBITS; len++) {
      left = (left << 1) - count[len];
      if (left < 0) throw new Error("zlib data is corrupt: over-subscribed Huffman code");
      if (count[len]) longest = len;
    }
    if (left > 0 && longest > 0 && !(single && longest === 1)) throw new Error("zlib data is corrupt: incomplete Huffman code");
    offsets[1] = 0;
    for (let len = 1; len <= MAXBITS; len++) offsets[len + 1] = offsets[len] + count[len];
    for (let sym = 0; sym < n; sym++) {
      const len = lengths[at + sym];
      if (len) symbols[offsets[len]++] = sym;
    }
    root.fill(0);
    for (let len = 1, code = 0, i = 0; len <= ROOT; len++, code <<= 1) {
      for (let k = 0; k < count[len]; k++, code++, i++) {
        const rev = ((REV8[code & 0xff] << 8) | REV8[code >> 8]) >> (16 - len);
        const entry = (symbols[i] << 4) | len;
        for (let j = rev; j < 1 << ROOT; j += 1 << len) root[j] = entry;
      }
    }
  }
}

/** The fixed codes of block type 1. */
const FIXED_LITERAL = new Code(288);
const FIXED_DISTANCE = new Code(32);
{
  const lengths = new Uint8Array(288 + 32);
  lengths.fill(8, 0, 144).fill(9, 144, 256).fill(7, 256, 280).fill(8, 280, 288).fill(5, 288);
  FIXED_LITERAL.build(lengths, 0, 288);
  FIXED_DISTANCE.build(lengths, 288, 32);
}

/**
 * Inflates the zlib stream whose bytes `next` returns a segment at a time
 * (null at the end), handing the output to `sink` as `window[from..to)`; the
 * sink returns true to stop. Returns when the sink stops or the final block
 * ends; throws on a bad header, corrupt data or input that ends too soon.
 */
export function inflate(next: () => Uint8Array | null, sink: (window: Uint8Array, from: number, to: number) => boolean): void {
  new Inflater(next, sink).run();
}

class Inflater {
  private segment: Uint8Array = new Uint8Array(0);
  private pos = 0;
  private bitBuf = 0;
  private bitCnt = 0;
  /** Zero bytes added past the end of the input, so a lookup near the end can peek. Consuming them is an error. */
  private padding = 0;
  private readonly window = new Uint8Array(WSIZE);
  /** Bytes output, and bytes handed to the sink. */
  private out = 0;
  private flushed = 0;
  private readonly literal = new Code(288);
  private readonly distance = new Code(32);
  private readonly lengthCode = new Code(19);
  private readonly lengths = new Uint8Array(288 + 32);

  constructor(
    private readonly next: () => Uint8Array | null,
    private readonly sink: (window: Uint8Array, from: number, to: number) => boolean,
  ) {}

  run(): void {
    const cmf = this.bits(8);
    const flg = this.bits(8);
    if ((cmf & 15) !== 8 || cmf >> 4 > 7 || ((cmf << 8) | flg) % 31 !== 0) throw new Error("zlib header is invalid");
    if (flg & 0x20) throw new Error("zlib stream needs a preset dictionary");
    for (;;) {
      const final = this.bits(1);
      const type = this.bits(2);
      let stopped: boolean;
      if (type === 0) stopped = this.stored();
      else if (type === 1) stopped = this.codes(FIXED_LITERAL, FIXED_DISTANCE);
      else if (type === 2) {
        this.dynamic();
        stopped = this.codes(this.literal, this.distance);
      } else throw new Error("zlib data is corrupt: invalid block type");
      if (stopped || this.flush()) return;
      if (final) return;
    }
  }

  /** Hands everything not yet flushed to the sink; true if the sink says stop. */
  private flush(): boolean {
    while (this.flushed < this.out) {
      const from = this.flushed & WMASK;
      const to = Math.min(from + (this.out - this.flushed), WSIZE);
      this.flushed += to - from;
      if (this.sink(this.window, from, to)) return true;
    }
    return false;
  }

  private byte(): number {
    while (this.pos >= this.segment.length) {
      const next = this.padding ? null : this.next();
      if (!next) {
        this.padding++;
        return 0;
      }
      this.segment = next;
      this.pos = 0;
    }
    return this.segment[this.pos++];
  }

  /** Ensures at least n (at most 16) bits are buffered, padding with zeros past the end of the input. */
  private need(n: number): void {
    while (this.bitCnt < n) {
      this.bitBuf |= this.byte() << this.bitCnt;
      this.bitCnt += 8;
    }
  }

  private consume(n: number): void {
    this.bitBuf >>>= n;
    this.bitCnt -= n;
    if (this.padding && this.bitCnt < this.padding * 8) throw new Error("zlib data ends early");
  }

  private bits(n: number): number {
    this.need(n);
    const v = this.bitBuf & ((1 << n) - 1);
    this.consume(n);
    return v;
  }

  private symbol(code: Code): number {
    this.need(ROOT);
    const entry = code.root[this.bitBuf & ((1 << ROOT) - 1)];
    if (entry) {
      this.consume(entry & 15);
      return entry >> 4;
    }
    // A longer code: walk the canonical code a bit at a time.
    this.need(MAXBITS);
    let bits = this.bitBuf;
    for (let len = 1, code_ = 0, first = 0, index = 0; len <= MAXBITS; len++) {
      code_ |= bits & 1;
      bits >>>= 1;
      const count = code.count[len];
      if (code_ - first < count) {
        this.consume(len);
        return code.symbols[index + code_ - first];
      }
      index += count;
      first = (first + count) << 1;
      code_ <<= 1;
    }
    throw new Error("zlib data is corrupt: invalid Huffman code");
  }

  private stored(): boolean {
    this.consume(this.bitCnt & 7); // to a byte boundary
    const len = this.bits(16);
    if ((this.bits(16) ^ 0xffff) !== len) throw new Error("zlib data is corrupt: stored block length");
    for (let i = 0; i < len; i++) {
      if (this.out - this.flushed >= INFLATE_FLUSH && this.flush()) return true;
      this.window[this.out++ & WMASK] = this.bits(8);
    }
    return false;
  }

  private dynamic(): void {
    const nlit = this.bits(5) + 257;
    const ndist = this.bits(5) + 1;
    const nlen = this.bits(4) + 4;
    if (nlit > 286 || ndist > 30) throw new Error("zlib data is corrupt: too many codes");
    const lengths = this.lengths;
    lengths.fill(0, 0, 19);
    for (let i = 0; i < nlen; i++) lengths[CLORDER[i]] = this.bits(3);
    this.lengthCode.build(lengths, 0, 19, false);
    for (let i = 0; i < nlit + ndist; ) {
      const sym = this.symbol(this.lengthCode);
      if (sym < 16) {
        lengths[i++] = sym;
        continue;
      }
      let value = 0;
      let repeat: number;
      if (sym === 16) {
        if (i === 0) throw new Error("zlib data is corrupt: repeat with no length");
        value = lengths[i - 1];
        repeat = 3 + this.bits(2);
      } else repeat = sym === 17 ? 3 + this.bits(3) : 11 + this.bits(7);
      if (i + repeat > nlit + ndist) throw new Error("zlib data is corrupt: too many lengths");
      lengths.fill(value, i, i + repeat);
      i += repeat;
    }
    if (lengths[256] === 0) throw new Error("zlib data is corrupt: no end-of-block code");
    this.literal.build(lengths, 0, nlit);
    this.distance.build(lengths, nlit, ndist);
  }

  /** Decodes one block's literals and matches; true if the sink said stop. */
  private codes(literal: Code, distance: Code): boolean {
    const window = this.window;
    for (;;) {
      if (this.out - this.flushed >= INFLATE_FLUSH && this.flush()) return true;
      const sym = this.symbol(literal);
      if (sym < 256) {
        window[this.out++ & WMASK] = sym;
        continue;
      }
      if (sym === 256) return false;
      const li = sym - 257;
      if (li >= 29) throw new Error("zlib data is corrupt: invalid length code");
      const length = LBASE[li] + this.bits(LEXT[li]);
      const ds = this.symbol(distance);
      if (ds >= 30) throw new Error("zlib data is corrupt: invalid distance code");
      const dist = DBASE[ds] + this.bits(DEXT[ds]);
      if (dist > this.out) throw new Error("zlib data is corrupt: distance too far back");
      let out = this.out;
      for (const end = out + length; out < end; out++) window[out & WMASK] = window[(out - dist) & WMASK];
      this.out = out;
    }
  }
}
