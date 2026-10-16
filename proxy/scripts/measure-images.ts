// Measures the memory the Workers resizer (src/img-wasm.ts) uses, in Node or
// in workerd, the runtime Workers run on: the numbers behind the pixel caps.
// Not a test. Linux only (it reads /proc). Nothing forces garbage collection,
// so the figures include whatever the runtime leaves uncollected.
//
//   npx tsx scripts/measure-images.ts [node|workerd] [png] [jpeg] [mixed]
//
// png    each case in a fresh runtime: photo PNGs of 2 and 3.5 MP (5 and 9
//        MiB), a 12 MP screenshot, a 2 MP 16-bit interlaced PNG, a 100 MP flat
//        image, and decompression bombs declaring 1000x1000 (200 MiB and
//        1 GiB of zeros).
// jpeg   one runtime: ten 8 MP photo JPEGs in a row, ten 4 MP, then ten of
//        the noisiest baseline JPEG and ten progressive 4:4:4 JPEGs that
//        their caps let through (the most heap a JPEG can take).
// mixed  one runtime: an image of each kind at its cap, twice over, so every
//        codec reaches its high-water mark: a warm isolate's steady state.
// failures  one runtime: a valid progressive JPEG at its cap, eight 8 MP CMYK
//        JPEGs (refused before decoding), eight broken progressive JPEGs at
//        their cap (mozjpeg gives up partway, costing the decoder), then a
//        valid 8 MP JPEG. The status column shows 415 and 503 refusals.
//
// Images over their cap (resizer.maxPixels) are marked: the handler would
// refuse them with 413.
//
// Each group also runs a control: the same inputs, received but not resized.
// The runtime holds each request body for a while, and that alone grows it;
// the decoders' share is the difference.
//
// Each runtime first resizes a small image; that is the warm baseline. For
// each resize the script prints the peak resident memory during it (VmHWM,
// reset before each resize through /proc/<pid>/clear_refs) and the resident
// memory after it, both less the warm baseline, and the WASM memory of every
// live codec instance.

import { type ChildProcess, spawn } from "node:child_process";
import { copyFileSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { crc32, deflateSync } from "node:zlib";
import type { ImageType } from "../src/content";

const MiB = 1024 * 1024;
const mib = (n: number) => (n / MiB).toFixed(1);
const PROXY = fileURLToPath(new URL("..", import.meta.url));
const CODECS = {
  jpegDec: "@jsquash/jpeg/codec/dec/mozjpeg_dec.wasm",
  jpegEnc: "@jsquash/jpeg/codec/enc/mozjpeg_enc.wasm",
  webpDec: "@jsquash/webp/codec/dec/webp_dec.wasm",
};

interface Step {
  label: string;
  type: ImageType;
  file: string;
  /** Its size and file size, printed with the first resize. */
  detail?: string;
}
interface Result {
  status: number;
  ms: number;
  wasm: string;
}
/** A process with a resizer in it. */
interface Runtime {
  pid: number;
  resize(step: Step): Promise<Result>;
  close(): Promise<void>;
}

// ---- the parent: makes the images, starts runtimes, measures them ----

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const runtime = args[0] === "workerd" ? "workerd" : "node";
  const groups = args.filter((a) => a !== "node" && a !== "workerd");
  const want = (g: string) => groups.length === 0 || groups.includes(g);
  const dir = mkdtempSync(join(tmpdir(), "measure-images-"));
  const start = runtime === "workerd" ? await workerdRuntime(dir) : () => nodeRuntime();
  const images = new Images(dir);
  console.log(`${runtime}, node ${process.version}, ${new Date().toISOString()}; MiB over the warm baseline`);
  try {
    const warmJpeg = await images.jpeg("warm-up 400x300 JPEG", 400, 300);
    if (want("png")) {
      const warmPng = await images.png("warm-up 400x300 PNG", "photo", 400, 300);
      const cases = [
        await images.png("2 MP photo PNG", "photo", ...dims(2)),
        await images.png("3.5 MP photo PNG", "photo", ...dims(3.5)),
        await images.png("12 MP screenshot PNG", "screenshot", ...dims(12)),
        await images.png("2 MP 16-bit interlaced PNG", "interlaced16", ...dims(2)),
        await images.png("100 MP flat PNG", "flat", 10_000, 10_000),
        await images.bomb("bomb: 1000x1000, 200 MiB of zeros", 200),
        await images.bomb("bomb: 1000x1000, 1 GiB of zeros", 1024),
      ];
      for (const c of cases) await measure(start, c.label, [warmJpeg, warmPng], [bodyOnly(c), c]);
    }
    if (want("jpeg")) {
      const photo8 = await images.jpeg("8 MP photo JPEG", ...dims(8));
      const photo4 = await images.jpeg("4 MP photo JPEG", ...dims(4));
      const noisiest = await images.jpegAtCap("noisiest baseline JPEG", {});
      const progressive = await images.jpegAtCap("progressive 4:4:4 JPEG", { progressive: true, chromaSubsampling: "4:4:4", quality: 95 });
      const steps = [...times(10, photo8), ...times(10, photo4), ...times(10, noisiest), ...times(10, progressive)];
      await measure(start, "JPEGs in a row", [warmJpeg], steps);
      await measure(start, "control: the same inputs, received but not resized", [warmJpeg], steps.map(bodyOnly));
    }
    if (want("failures")) {
      const valid = await images.jpegAtCap("progressive JPEG", { progressive: true });
      const cmyk = await images.jpeg("8 MP CMYK JPEG", ...dims(8), "photo", true);
      const broken = await images.broken(valid, "broken progressive JPEG at its cap");
      const photo8 = await images.jpeg("8 MP photo JPEG", ...dims(8));
      const steps = [valid, ...times(8, cmyk), ...times(8, broken), photo8];
      await measure(start, "failing JPEGs", [warmJpeg], steps);
      await measure(start, "control: the same inputs, received but not resized", [warmJpeg], steps.map(bodyOnly));
    }
    if (want("mixed")) {
      const all = [
        await images.jpegAtCap("noisiest baseline JPEG", {}),
        await images.jpegAtCap("progressive 4:4:4 JPEG", { progressive: true, chromaSubsampling: "4:4:4", quality: 95 }),
        await images.webpAtCap("lossless noise WebP"),
        await images.png("2 MP 16-bit interlaced PNG", "interlaced16", ...dims(2)),
        await images.png("3.5 MP photo PNG", "photo", ...dims(3.5)),
        await images.png("12 MP screenshot PNG", "screenshot", ...dims(12)),
        await images.gif("2 MP GIF", ...dims(2)),
      ];
      await measure(start, "one of each, twice", [warmJpeg], [...all, ...all]);
      await measure(start, "control: the same inputs, received but not resized", [warmJpeg], [...all, ...all].map(bodyOnly));
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

/** Receives the image without resizing it: what the input alone costs. */
function bodyOnly(step: Step): Step {
  return { label: `  ${step.label}, received only`.slice(0, 38), type: "none" as ImageType, file: step.file };
}

function times(n: number, step: Step): Step[] {
  return Array.from({ length: n }, (_, i) => ({ ...step, label: `${step.label} #${i + 1}` }));
}

async function measure(start: () => Promise<Runtime>, title: string, warm: Step[], steps: Step[]): Promise<void> {
  const rt = await start();
  try {
    for (const w of warm) await rt.resize(w);
    const base = proc(rt.pid, "VmRSS");
    console.log(`--- ${title} (warm baseline ${mib(base)} MiB)`);
    const described = new Set<string>();
    for (const step of steps) {
      if (step.detail && !described.has(step.file)) {
        described.add(step.file);
        console.log(`  (${step.label.replace(/ #\d+$/, "")}:${step.detail})`);
      }
      writeFileSync(`/proc/${rt.pid}/clear_refs`, "5"); // resets VmHWM to VmRSS
      const r = await rt.resize(step);
      const peak = proc(rt.pid, "VmHWM") - base;
      const now = proc(rt.pid, "VmRSS") - base;
      console.log(
        `  ${step.label.padEnd(36)} ${r.status} ${String(r.ms).padStart(5)} ms  peak ${sign(peak)}  now ${sign(now)}  wasm ${r.wasm || "none"}`,
      );
    }
  } finally {
    await rt.close();
  }
}

const sign = (n: number) => `${n < 0 ? "-" : "+"}${mib(Math.abs(n)).padStart(5)}`;

/** A field of /proc/<pid>/status, in bytes. */
function proc(pid: number, key: string): number {
  const m = new RegExp(`${key}:\\s+(\\d+) kB`).exec(readFileSync(`/proc/${pid}/status`, "utf8"));
  if (!m) throw new Error(`no ${key} for ${pid}`);
  return Number(m[1]) * 1024;
}

/** Makes test images as files. */
class Images {
  private n = 0;
  constructor(private readonly dir: string) {}

  private async save(label: string, type: ImageType, bytes: Uint8Array): Promise<Step> {
    const file = join(this.dir, `${this.n++}.img`);
    writeFileSync(file, bytes);
    const { createWasmResizer } = await import("../src/img-wasm");
    const { imageSize } = await import("../src/imgsize");
    const size = imageSize(bytes, type);
    const cap = createWasmResizer({} as never).maxPixels(bytes, type);
    const over = !size || size.width * size.height > cap || bytes.length > 10 * MiB;
    const mp = size ? ` ${size.width}x${size.height}` : "";
    return { label: `${label}${over ? " (over its cap)" : ""}`, type, file, detail: `${mp}, ${mib(bytes.length)} MiB` };
  }

  /** The largest 4:3 JPEG of noise with these options that its cap lets through: the most heap such a JPEG takes. */
  async jpegAtCap(label: string, options: object): Promise<Step> {
    const { jpegMaxPixels } = await import("../src/img-wasm");
    let mp = 8;
    for (;;) {
      const [width, height] = dims(mp);
      const bytes = new Uint8Array(await (await this.sharp(width, height, "noise")).jpeg({ quality: 85, ...options }).toBuffer());
      const cap = bytes.length > 10 * MiB ? 0 : jpegMaxPixels(bytes);
      if (width * height <= cap) return this.save(`${label} at its cap`, "jpeg", bytes);
      mp = cap > 0 ? (cap / 1e6) * 0.99 : mp / 2;
    }
  }

  /** The largest 4:3 lossless WebP of noise (with alpha) that its cap lets through. */
  async webpAtCap(label: string): Promise<Step> {
    const { webpMaxPixels } = await import("../src/img-wasm");
    const { default: sharp } = await import("sharp");
    let mp = 2;
    for (;;) {
      const [width, height] = dims(mp);
      const raw = Buffer.alloc(width * height * 4);
      for (let i = 0; i < raw.length; i++) raw[i] = Math.random() * 256;
      const bytes = new Uint8Array(await sharp(raw, { raw: { width, height, channels: 4 } }).webp({ lossless: true }).toBuffer());
      const cap = webpMaxPixels(bytes);
      if (width * height <= cap) return this.save(`${label} at its cap`, "webp", bytes);
      mp = (cap / 1e6) * 0.99;
    }
  }

  private async sharp(width: number, height: number, kind: "photo" | "noise" | "screenshot") {
    const { default: sharp } = await import("sharp");
    const raw = Buffer.alloc(width * height * 3);
    for (let y = 0; y < height; y++) {
      for (let x = 0; x < width; x++) {
        const i = (y * width + x) * 3;
        if (kind === "noise") {
          raw[i] = Math.random() * 256;
          raw[i + 1] = Math.random() * 256;
          raw[i + 2] = Math.random() * 256;
        } else if (kind === "screenshot") {
          // White page, lines of dark "text", a coloured panel.
          const text = y % 40 < 14 && x % 9 < 6 && x < width * 0.7;
          raw.fill(text ? 30 : 255, i, i + 3);
          if (x > width * 0.75 && y % 300 < 120) raw.set([40, 110, 200], i);
        } else {
          // Photo-like: smooth gradients and mild noise.
          raw[i] = (x * 255) / width + Math.random() * 12;
          raw[i + 1] = (y * 255) / height + Math.random() * 12;
          raw[i + 2] = (x + y) & 255;
        }
      }
    }
    return sharp(raw, { raw: { width, height, channels: 3 } });
  }

  async jpeg(label: string, width: number, height: number, kind: "photo" | "noise" = "photo", cmyk = false): Promise<Step> {
    const img = await this.sharp(width, height, kind);
    return this.save(`${label}`, "jpeg", await (cmyk ? img.toColourspace("cmyk") : img).jpeg({ quality: 85 }).toBuffer());
  }

  /** The JPEG with its last scan naming a component the frame lacks: mozjpeg gives up (exit()) partway through. */
  async broken(step: Step, label: string): Promise<Step> {
    const b = new Uint8Array(readFileSync(step.file));
    let last = -1;
    for (let i = 2; i + 1 < b.length; i++) if (b[i] === 0xff && b[i + 1] === 0xda) last = i;
    b[last + 5] = 0x77; // the scan's first component selector
    return this.save(label, "jpeg", b);
  }

  async png(label: string, kind: "photo" | "screenshot" | "flat" | "interlaced16", width: number, height: number): Promise<Step> {
    if (kind === "flat") {
      const { default: sharp } = await import("sharp");
      const png = await sharp({ create: { width, height, channels: 3, background: "#3366cc" } }).png().toBuffer();
      return this.save(label, "png", png);
    }
    const img = await this.sharp(width, height, kind === "interlaced16" ? "photo" : kind);
    const png = kind === "interlaced16" ? img.toColourspace("rgb16").png({ progressive: true }) : img.png();
    return this.save(label, "png", await png.toBuffer());
  }

  async gif(label: string, width: number, height: number): Promise<Step> {
    const img = await this.sharp(width, height, "photo");
    return this.save(label, "gif", await img.gif().toBuffer());
  }

  /** An 8-bit RGB PNG declaring 1000x1000 whose one IDAT inflates to `mib` MiB of zeros. */
  bomb(label: string, mib: number): Promise<Step> {
    const chunk = (type: string, data: Uint8Array) => {
      const out = Buffer.alloc(12 + data.length);
      out.writeUInt32BE(data.length, 0);
      out.write(type, 4, "latin1");
      out.set(data, 8);
      out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
      return out;
    };
    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(1000, 0);
    ihdr.writeUInt32BE(1000, 4);
    ihdr.set([8, 2, 0, 0, 0], 8);
    const zeros = deflateSync(Buffer.alloc(mib * MiB), { level: 9 });
    const signature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    return this.save(label, "png", Buffer.concat([signature, chunk("IHDR", ihdr), chunk("IDAT", zeros), chunk("IEND", new Uint8Array(0))]));
  }
}

// ---- runtimes ----

/** This script again, with --serve: a Node process with a resizer, driven over stdin and stdout. */
async function nodeRuntime(): Promise<Runtime> {
  const script = fileURLToPath(import.meta.url);
  const child = spawn(process.execPath, [...process.execArgv, script, "--serve"], { stdio: ["pipe", "pipe", "inherit"] });
  const lines = createInterface({ input: child.stdout! })[Symbol.asyncIterator]();
  return {
    pid: child.pid!,
    async resize(step) {
      child.stdin!.write(`${step.type} ${step.file}\n`);
      const line = await lines.next();
      if (line.done) throw new Error("the Node runtime exited");
      return JSON.parse(line.value) as Result;
    },
    close: () => stop(child),
  };
}

/** A workerd process (the binary wrangler uses) running the resizer as a Worker; starts one per call. */
async function workerdRuntime(dir: string): Promise<() => Promise<Runtime>> {
  const require = createRequire(import.meta.url);
  const binary = (require("workerd") as { default: string }).default;
  const { build } = await import("esbuild");
  for (const [name, path] of Object.entries(CODECS)) copyFileSync(require.resolve(path), join(dir, `${name}.wasm`));
  writeFileSync(join(dir, "worker.ts"), WORKER(join(PROXY, "src/img-wasm.ts")));
  await build({
    entryPoints: [join(dir, "worker.ts")],
    bundle: true,
    format: "esm",
    outfile: join(dir, "worker.mjs"),
    platform: "neutral",
    external: ["*.wasm"],
    conditions: ["worker", "browser"],
    mainFields: ["module", "main"],
    logLevel: "error",
  });
  let port = 18_700 + Math.floor(Math.random() * 1000);
  return async () => {
    port++;
    writeFileSync(join(dir, "worker.capnp"), CONFIG(port));
    const child = spawn(binary, ["serve", join(dir, "worker.capnp")], { stdio: ["ignore", "ignore", "inherit"] });
    const resize = async (step: Step): Promise<Result> => {
      const res = await fetch(`http://127.0.0.1:${port}/?type=${step.type}`, { method: "POST", body: readFileSync(step.file) });
      await res.arrayBuffer();
      return { status: res.status, ms: Number(res.headers.get("x-ms")), wasm: res.headers.get("x-wasm") ?? "" };
    };
    for (let i = 0; ; i++) {
      try {
        await fetch(`http://127.0.0.1:${port}/ping`);
        break;
      } catch (e) {
        if (i > 200) throw e;
        await new Promise((r) => setTimeout(r, 50));
      }
    }
    return { pid: child.pid!, resize, close: () => stop(child) };
  };
}

async function stop(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null) return;
  child.kill();
  await new Promise((r) => child.once("exit", r));
}

const CONFIG = (port: number) => `using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
  services = [ (name = "main", worker = .w) ],
  sockets = [ (name = "http", address = "127.0.0.1:${port}", http = (), service = "main") ],
);
const w :Workerd.Worker = (
  modules = [
    (name = "worker", esModule = embed "worker.mjs"),
${Object.keys(CODECS)
  .map((n) => `    (name = "${n}.wasm", wasm = embed "${n}.wasm"),`)
  .join("\n")}
  ],
  compatibilityDate = "2026-09-01",
);
`;

/** The Worker workerd runs: the resizer, plus a record of each codec instance's memory. */
const WORKER = (imgWasm: string) => `
${Object.keys(CODECS)
  .map((n) => `import ${n} from "./${n}.wasm";`)
  .join("\n")}
const names = new Map([${Object.keys(CODECS)
  .map((n) => `[${n}, "${n}"]`)
  .join(", ")}]);
${TRACK_INSTANCES}
const { createWasmResizer } = await import(${JSON.stringify(imgWasm)});
const resizer = createWasmResizer({ ${Object.keys(CODECS).join(", ")} });
export default {
  async fetch(req) {
    const type = new URL(req.url).searchParams.get("type");
    if (!type) return new Response("pong");
    const body = new Uint8Array(await req.arrayBuffer());
    if (type === "none") return new Response(null, { headers: { "x-ms": "0", "x-wasm": wasmSizes() } });
    const t0 = Date.now();
    let status = 200;
    try {
      await resizer.resize(body, type);
    } catch (e) {
      status = typeof e?.status === "number" && e.status >= 400 ? e.status : 415; // a ProxyError's own, as the handler does
    }
    return new Response(null, { status, headers: { "x-ms": String(Date.now() - t0), "x-wasm": wasmSizes() } });
  },
};
`;

/** Wraps WebAssembly.Instance and instantiate to keep a weak reference to each codec's memory; defines wasmSizes(). */
const TRACK_INSTANCES = `
const live = [];
const track = (module, instance) => {
  for (const v of Object.values(instance.exports)) if (v instanceof WebAssembly.Memory) live.push([names.get(module) ?? "?", new WeakRef(v)]);
};
WebAssembly.Instance = new Proxy(WebAssembly.Instance, {
  construct(target, args) {
    const instance = new target(...args);
    track(args[0], instance);
    return instance;
  },
});
const instantiate = WebAssembly.instantiate.bind(WebAssembly);
WebAssembly.instantiate = async (source, imports) => {
  const result = await instantiate(source, imports);
  if (source instanceof WebAssembly.Module) track(source, result);
  return result;
};
const wasmSizes = () => group(live.map(([n, ref]) => [n, ref.deref()?.buffer.byteLength]).filter(([, b]) => b !== undefined).map(([n, b]) => n + " " + (b / ${MiB}).toFixed(1)));
${group.toString()}
`;

/** "a, a, b" -> "a x2, b": instances of the same size, counted. */
function group(entries: string[]): string {
  const counts = new Map<string, number>();
  for (const e of entries) counts.set(e, (counts.get(e) ?? 0) + 1);
  return [...counts].map(([e, n]) => (n > 1 ? `${e} x${n}` : e)).join(", ");
}

// ---- the Node runtime's process ----

async function serve(): Promise<void> {
  const require = createRequire(import.meta.url);
  const modules = Object.fromEntries(
    Object.entries(CODECS).map(([name, path]) => [name, new WebAssembly.Module(readFileSync(require.resolve(path)))]),
  ) as Record<keyof typeof CODECS, WebAssembly.Module>;
  const names = new Map(Object.entries(modules).map(([n, m]) => [m, n]));
  // The same tracking as in the Worker.
  const live: [string, WeakRef<WebAssembly.Memory>][] = [];
  const track = (module: WebAssembly.Module, instance: WebAssembly.Instance) => {
    for (const v of Object.values(instance.exports)) if (v instanceof WebAssembly.Memory) live.push([names.get(module) ?? "?", new WeakRef(v)]);
  };
  WebAssembly.Instance = new Proxy(WebAssembly.Instance, {
    construct(target, args: ConstructorParameters<typeof WebAssembly.Instance>) {
      const instance = new target(...args);
      track(args[0], instance);
      return instance;
    },
  });
  const instantiate = WebAssembly.instantiate.bind(WebAssembly);
  WebAssembly.instantiate = (async (source: WebAssembly.Module, imports?: WebAssembly.Imports) => {
    const result = await instantiate(source, imports);
    if (source instanceof WebAssembly.Module) track(source, result);
    return result;
  }) as typeof WebAssembly.instantiate;
  const wasmSizes = () =>
    group(
      live
        .map(([n, ref]) => [n, ref.deref()?.buffer.byteLength] as const)
        .filter((e): e is readonly [string, number] => e[1] !== undefined)
        .map(([n, b]) => `${n} ${mib(b)}`),
    );

  const { createWasmResizer } = await import("../src/img-wasm");
  const resizer = createWasmResizer(modules);
  for await (const line of createInterface({ input: process.stdin })) {
    const [type, file] = line.split(" ");
    const bytes = readFileSync(file); // a Buffer is a Uint8Array: no second copy
    if (type === "none") {
      process.stdout.write(`${JSON.stringify({ status: 200, ms: 0, wasm: wasmSizes() })}\n`);
      continue;
    }
    const t0 = Date.now();
    let status = 200;
    try {
      await resizer.resize(bytes, type as ImageType);
    } catch (e) {
      const own = (e as { status?: unknown })?.status;
      status = typeof own === "number" && own >= 400 ? own : 415; // a ProxyError's own, as the handler does
    }
    process.stdout.write(`${JSON.stringify({ status, ms: Date.now() - t0, wasm: wasmSizes() })}\n`);
  }
}

if (process.argv[2] === "--serve") await serve();
else await main();
