/** A JPEG marker segment: its marker byte, and where it starts and ends (a scan's entropy-coded data included). */
export interface Segment {
  marker: number;
  at: number;
  end: number;
}

/** Splits a JPEG into its marker segments, up to and including EOI. */
export function segments(b: Uint8Array): Segment[] {
  const out: Segment[] = [];
  for (let i = 2; i + 1 < b.length; ) {
    const marker = b[i + 1];
    if (marker === 0xd9) {
      out.push({ marker, at: i, end: i + 2 });
      break;
    }
    let end = i + 2 + ((b[i + 2] << 8) | b[i + 3]);
    if (marker === 0xda) while (!(b[end] === 0xff && b[end + 1] !== 0 && !(b[end + 1] >= 0xd0 && b[end + 1] <= 0xd7))) end++;
    out.push({ marker, at: i, end });
    i = end;
  }
  return out;
}

/** The JPEG with its last scan (and the DHT segments just before it) repeated `times` more times before EOI. */
export function withRepeatedScan(b: Uint8Array, times: number): Uint8Array {
  const segs = segments(b);
  let last = segs.length - 1;
  while (last >= 0 && segs[last].marker !== 0xda) last--;
  let from = last;
  while (from > 0 && segs[from - 1].marker === 0xc4) from--;
  const unit = b.subarray(segs[from].at, segs[last].end);
  const eoi = segs[segs.length - 1].at;
  const out = new Uint8Array(eoi + unit.length * times + 2);
  out.set(b.subarray(0, eoi));
  for (let k = 0; k < times; k++) out.set(unit, eoi + k * unit.length);
  out.set([0xff, 0xd9], out.length - 2);
  return out;
}

/** The JPEG with its last scan naming a component the frame lacks: mozjpeg gives up (exit()) partway through decoding. */
export function withBrokenLastScan(b: Uint8Array): Uint8Array {
  const out = b.slice();
  const last = segments(out).filter((s) => s.marker === 0xda).pop();
  if (!last) throw new Error("no scan");
  out[last.at + 5] = 0x77; // the scan's first component selector
  return out;
}
