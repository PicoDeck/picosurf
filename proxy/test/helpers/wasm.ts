import { readFileSync } from "node:fs";
import type { WasmModules } from "../../src/img-wasm";

const mod = (path: string) => new WebAssembly.Module(readFileSync(new URL(`../../node_modules/${path}`, import.meta.url)));

/** The codec modules worker.ts bundles, compiled from node_modules. */
export const wasmModules = (): WasmModules => ({
  jpegDec: mod("@jsquash/jpeg/codec/dec/mozjpeg_dec.wasm"),
  jpegEnc: mod("@jsquash/jpeg/codec/enc/mozjpeg_enc.wasm"),
  webpDec: mod("@jsquash/webp/codec/dec/webp_dec.wasm"),
});
