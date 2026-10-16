// Measures the memory the Workers (WASM) resizer uses, the numbers behind the
// pixel caps in src/img-wasm.ts. Not a test: run it after changing the image
// pipeline and update the caps' comments and README.md.
//
//   npx tsx scripts/measure-images.ts [kinds] [megapixels]
//   npx tsx scripts/measure-images.ts jpeg,png 2,4,8,12
//
// Kinds: jpeg (photo-like), jpeg-noise (worst case for the decoder heap: the
// biggest input for its size), png (photo-like, streams), png-screenshot
// (streams), png-interlaced (the WASM fallback). The images are made first,
// then each size runs in a fresh Node process (--expose-gc) that reads the
// file and resizes it twice, printing after each step the WASM memory of every
// live codec instance and process.memoryUsage(), in MiB. "grew" is RSS now
// less RSS before the first resize. "step peak" is the highest RSS during the
// step less RSS at its start: the process's maximum RSS when the step raised
// it, else the highest of RSS samples taken every millisecond (which run only
// while the resize awaits, as streaming does between chunks). Resize #1 pays
// one-time costs (the encoder instance, compiling the code); resize #2's step
// peak is what each further image costs a warm isolate.

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ImageType } from "../src/content";

const MiB = 1024 * 1024;
const mib = (n: number) => (n / MiB).toFixed(1);
const KINDS = ["jpeg", "jpeg-noise", "png", "png-screenshot", "png-interlaced"] as const;
type Kind = (typeof KINDS)[number];

if (process.argv[2] === "--child") await child(process.argv[3] as Kind, process.argv[4]);
else await parent();

async function parent(): Promise<void> {
  const kinds = (process.argv[2] ?? "jpeg,jpeg-noise,png,png-screenshot").split(",") as Kind[];
  const sizes = (process.argv[3] ?? "2,4,8,12").split(",").map(Number);
  for (const k of kinds) if (!KINDS.includes(k)) throw new Error(`unknown kind ${k}; one of ${KINDS.join(", ")}`);
  const dir = mkdtempSync(join(tmpdir(), "measure-images-"));
  const script = fileURLToPath(import.meta.url);
  console.log(`node ${process.version}, ${new Date().toISOString()}`);
  try {
    for (const kind of kinds) {
      for (const mp of sizes) {
        const file = join(dir, `${kind}-${mp}.img`);
        writeFileSync(file, await makeImage(kind, mp));
        const run = spawnSync(process.execPath, [...process.execArgv, "--expose-gc", script, "--child", kind, file], { encoding: "utf8" });
        process.stdout.write(run.stdout);
        if (run.status !== 0) process.stdout.write(`child failed (${run.status}): ${run.stderr.slice(-2000)}\n`);
        rmSync(file);
      }
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

/** Width and height for at most `mp` megapixels at 4:3. */
function dims(mp: number): [number, number] {
  const width = Math.floor(Math.sqrt((mp * 1e6 * 4) / 3));
  return [width, Math.floor((width * 3) / 4)];
}

async function makeImage(kind: Kind, mp: number): Promise<Uint8Array> {
  const { default: sharp } = await import("sharp");
  const [width, height] = dims(mp);
  const raw = Buffer.alloc(width * height * 3);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 3;
      if (kind === "jpeg-noise") {
        raw[i] = Math.random() * 256;
        raw[i + 1] = Math.random() * 256;
        raw[i + 2] = Math.random() * 256;
      } else if (kind === "png-screenshot") {
        // White page, lines of dark "text", a coloured panel.
        const text = y % 40 < 14 && x % 9 < 6 && x < width * 0.7;
        const panel = x > width * 0.75 && y % 300 < 120;
        raw.fill(text ? 30 : 255, i, i + 3);
        if (panel) raw.set([40, 110, 200], i);
      } else {
        // Photo-like: smooth gradients and mild noise.
        raw[i] = (x * 255) / width + Math.random() * 12;
        raw[i + 1] = (y * 255) / height + Math.random() * 12;
        raw[i + 2] = (x + y) & 255;
      }
    }
  }
  const img = sharp(raw, { raw: { width, height, channels: 3 } });
  const out = kind.startsWith("jpeg") ? img.jpeg({ quality: 85 }) : img.png({ progressive: kind === "png-interlaced" });
  return new Uint8Array(await out.toBuffer());
}

async function child(kind: Kind, file: string): Promise<void> {
  const gc = (globalThis as { gc?: () => void }).gc;
  if (!gc) throw new Error("run with --expose-gc");

  // Record each codec instance's memory, weakly, so freed instances drop out.
  const names = new Map<WebAssembly.Module, string>();
  const live: { name: string; memory: WeakRef<WebAssembly.Memory> }[] = [];
  const record = (module: WebAssembly.Module, instance: WebAssembly.Instance) => {
    for (const value of Object.values(instance.exports)) {
      if (value instanceof WebAssembly.Memory) live.push({ name: names.get(module) ?? "?", memory: new WeakRef(value) });
    }
  };
  WebAssembly.Instance = new Proxy(WebAssembly.Instance, {
    construct(target, args: ConstructorParameters<typeof WebAssembly.Instance>) {
      const instance = new target(...args);
      record(args[0], instance);
      return instance;
    },
  });
  const instantiate = WebAssembly.instantiate.bind(WebAssembly);
  WebAssembly.instantiate = (async (source: WebAssembly.Module, imports?: WebAssembly.Imports) => {
    const result = await instantiate(source, imports);
    if (source instanceof WebAssembly.Module) record(source, result);
    return result;
  }) as typeof WebAssembly.instantiate;

  const { createWasmResizer } = await import("../src/img-wasm");
  const { imageSize } = await import("../src/imgsize");
  const mod = (path: string, name: string) => {
    const m = new WebAssembly.Module(readFileSync(new URL(`../node_modules/${path}`, import.meta.url)));
    names.set(m, name);
    return m;
  };
  const resizer = createWasmResizer({
    jpegDec: mod("@jsquash/jpeg/codec/dec/mozjpeg_dec.wasm", "jpegDec"),
    jpegEnc: mod("@jsquash/jpeg/codec/enc/mozjpeg_enc.wasm", "jpegEnc"),
    pngDec: mod("@jsquash/png/codec/pkg/squoosh_png_bg.wasm", "pngDec"),
    webpDec: mod("@jsquash/webp/codec/dec/webp_dec.wasm", "webpDec"),
  });
  const type: ImageType = kind.startsWith("jpeg") ? "jpeg" : "png";
  const bytes = new Uint8Array(readFileSync(file));
  const size = imageSize(bytes, type);
  if (!size) throw new Error("unreadable image");
  const cap = resizer.maxPixels(bytes, type);
  const pixels = size.width * size.height;

  const settle = () => new Promise((r) => setImmediate(r));
  const collect = async () => {
    for (let i = 0; i < 3; i++) {
      await settle();
      gc();
    }
  };
  await collect();
  const rss0 = process.memoryUsage().rss;
  const maxRss = () => process.resourceUsage().maxRSS * 1024;
  let stepPeak = rss0;
  /** Runs `fn`, tracking the highest RSS while it runs in stepPeak. */
  const tracked = async <T>(fn: () => Promise<T>): Promise<T> => {
    const maxBefore = maxRss();
    let sampled = process.memoryUsage.rss();
    const timer = setInterval(() => (sampled = Math.max(sampled, process.memoryUsage.rss())), 1);
    try {
      return await fn();
    } finally {
      clearInterval(timer);
      const maxAfter = maxRss();
      stepPeak = Math.max(maxAfter > maxBefore ? maxAfter : 0, sampled, process.memoryUsage.rss());
    }
  };
  let stepStart = rss0;
  const report = (step: string, ms?: number) => {
    const wasm = live
      .map(({ name, memory }) => [name, memory.deref()?.buffer.byteLength] as const)
      .filter((e): e is readonly [string, number] => e[1] !== undefined);
    const u = process.memoryUsage();
    const peak = Math.max(stepPeak, u.rss) - stepStart;
    stepPeak = 0;
    stepStart = u.rss;
    const time = ms === undefined ? "" : `${ms.toFixed(0)} ms`;
    console.log(
      `  ${step.padEnd(10)}${time.padStart(8)}  wasm [${wasm.map(([n, b]) => `${n} ${mib(b)}`).join(", ") || "none"}] = ${mib(wasm.reduce((s, [, b]) => s + b, 0))}` +
        `  rss ${mib(u.rss)} heap ${mib(u.heapUsed)} external ${mib(u.external)} arrayBuffers ${mib(u.arrayBuffers)}` +
        `  grew ${mib(u.rss - rss0)} step peak ${mib(peak)}`,
    );
  };

  console.log(
    `--- ${kind} ${size.width}x${size.height} (${(pixels / 1e6).toFixed(1)} MP), input ${mib(bytes.length)} MiB, cap ${cap / 1e6} MP${pixels > cap ? " (over the cap: the handler refuses it)" : ""}`,
  );
  report("start");
  for (const run of [1, 2]) {
    const started = performance.now();
    const out = await tracked(() => resizer.resize(bytes, type));
    report(`resize #${run}`, performance.now() - started);
    if (out.length < 100) throw new Error("no JPEG");
    await collect();
    report("gc");
  }
}
