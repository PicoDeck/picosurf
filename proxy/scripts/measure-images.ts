// Measures the memory the Workers resizer (src/img-wasm.ts) uses, in Node or
// in workerd, the runtime Workers run on: the numbers behind the pixel caps.
// Not a test. Linux only (it reads /proc). Nothing forces garbage collection,
// so the figures include whatever the runtime leaves uncollected.
//
//   npx tsx scripts/measure-images.ts [node|workerd] [png] [jpeg] [mixed]
//
// png    each case in a fresh runtime: photo PNGs of 2, 8 and 12 MP, a 12 MP
//        screenshot, a 100 MP flat image, and decompression bombs declaring
//        1000x1000 (200 MiB and 1 GiB of zeros).
// jpeg   one runtime: ten 8 MP photo JPEGs in a row, ten of the noisiest
//        (the largest input for the size), then ten 4 MP photos.
// mixed  one runtime: an image of each kind at its cap, twice over, so every
//        codec reaches its high-water mark: a warm isolate's steady state.
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
        await images.png("8 MP photo PNG", "photo", ...dims(8)),
        await images.png("12 MP photo PNG", "photo", ...dims(12)),
        await images.png("12 MP screenshot PNG", "screenshot", ...dims(12)),
        await images.png("100 MP flat PNG", "flat", 10_000, 10_000),
        images.bomb("bomb: 1000x1000, 200 MiB of zeros", 200),
        images.bomb("bomb: 1000x1000, 1 GiB of zeros", 1024),
      ];
      for (const c of cases) await measure(start, c.label, [warmJpeg, warmPng], [bodyOnly(c), c]);
    }
    if (want("jpeg")) {
      const photo8 = await images.jpeg("8 MP photo JPEG", ...dims(8));
      const noise8 = await images.jpeg("8 MP noisiest JPEG", ...dims(8), "noise");
      const photo4 = await images.jpeg("4 MP photo JPEG", ...dims(4));
      const steps = [...times(10, photo8), ...times(10, noise8), ...times(10, photo4)];
      await measure(start, "JPEGs in a row", [warmJpeg], steps);
    }
    if (want("mixed")) {
      const all = [
        await images.jpeg("8 MP noisiest JPEG", ...dims(8), "noise"),
        await images.webp("2 MP WebP (lossless noise)", ...dims(2)),
        await images.png("2 MP interlaced PNG", "interlaced", ...dims(2)),
        await images.png("12 MP photo PNG (streams)", "photo", ...dims(12)),
        await images.gif("2 MP GIF", ...dims(2)),
      ];
      await measure(start, "one of each, twice", [warmJpeg], [...all, ...all]);
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
  return { label: "  (receiving the input only)", type: "none" as ImageType, file: step.file };
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
    for (const step of steps) {
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

  private save(label: string, type: ImageType, bytes: Uint8Array): Step {
    const file = join(this.dir, `${this.n++}.img`);
    writeFileSync(file, bytes);
    return { label, type, file };
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

  async jpeg(label: string, width: number, height: number, kind: "photo" | "noise" = "photo"): Promise<Step> {
    const img = await this.sharp(width, height, kind);
    return this.save(`${label}`, "jpeg", await img.jpeg({ quality: 85 }).toBuffer());
  }

  async png(label: string, kind: "photo" | "screenshot" | "flat" | "interlaced", width: number, height: number): Promise<Step> {
    if (kind === "flat") {
      const { default: sharp } = await import("sharp");
      const png = await sharp({ create: { width, height, channels: 3, background: "#3366cc" } }).png().toBuffer();
      return this.save(label, "png", png);
    }
    const img = await this.sharp(width, height, kind === "interlaced" ? "photo" : kind);
    return this.save(label, "png", await img.png({ progressive: kind === "interlaced" }).toBuffer());
  }

  async webp(label: string, width: number, height: number): Promise<Step> {
    const img = await this.sharp(width, height, "noise");
    return this.save(label, "webp", await img.webp({ lossless: true }).toBuffer());
  }

  async gif(label: string, width: number, height: number): Promise<Step> {
    const img = await this.sharp(width, height, "photo");
    return this.save(label, "gif", await img.gif().toBuffer());
  }

  /** An 8-bit RGB PNG declaring 1000x1000 whose one IDAT inflates to `mib` MiB of zeros. */
  bomb(label: string, mib: number): Step {
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
    } catch {
      status = 415;
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
    } catch {
      status = 415;
    }
    process.stdout.write(`${JSON.stringify({ status, ms: Date.now() - t0, wasm: wasmSizes() })}\n`);
  }
}

if (process.argv[2] === "--serve") await serve();
else await main();
